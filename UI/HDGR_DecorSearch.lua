-- HDG.DecorSearch -- what a decor search box matches
-- ============================================================================
-- Descriptive search (2026-11). A decor matches when EVERY word of the query is
-- found in at least one of:
--
--   its name           the word anywhere in the name -- what the box always did,
--                      so nothing the name search found is lost
--   its Blizzard tags  a whole word of the game's own tags, in the client's
--                      language ("chair chairs", "Violet / Purple", "Stormwind")
--   its facets         a whole word of its FacetDB values on every packed axis:
--                      "dark-red" answers dark and red, "silk-velvet" answers
--                      velvet, "wall-mounted" answers wall
--   its vision words   HDGR_DecorSearchDB: the free-text tags of the vision pass
--                      ("high back", "iron banded")
--
-- Names match as you type; everything else matches whole words, so "bed" is not
-- every piece that suits a bedroom and "table" is not everything that sits on a
-- tabletop. A plural also asks for its singular ("lamps" finds lamp).
--
-- Pure: Build(query) -> fn(row) -> boolean, over the catalog observer's rows
-- (name, itemID, dataTagsByID). It reads static data only, so a selector that
-- calls it declares the query and nothing more.

HDG = HDG or {}
HDG.DecorSearch = HDG.DecorSearch or {}
local DS = HDG.DecorSearch

local byte = string.byte

-- Facet values that say "nothing here": never an answer to a search.
local EMPTY_VALUES = { ["none"] = true, ["plain-none"] = true, ["generic"] = true, ["misc"] = true }

-- " word word " -- lowercase, every run of spaces and punctuation one space, a
-- space at each end, so a whole word is one plain find of " word ".
local function _words(text)
    return " " .. ((text:lower():gsub("[%s%p]+", " ")):match("^ ?(.-) ?$")) .. " "
end
DS.Words = _words

-- A Blizzard tag's words by tagID. A tag's name never changes in a session, so
-- each is normalised once, the first time a search meets it.
local _tagWords = {}
local function _tagWordsOf(tagID, displayName)
    local words = _tagWords[tagID]
    if not words then
        words = _words(displayName)
        _tagWords[tagID] = words
    end
    return words
end

-- [axis][vocabIndex] = the value's words, or false for a value that says
-- nothing. FacetDB's vocabulary is static: built on the first search.
local _vocabWords
local function _facetVocabWords()
    if not _vocabWords then
        _vocabWords = {}
        for axis, values in pairs(HDG.StaticData.Facets:GetVocab()) do
            local byIndex = {}
            for index, value in pairs(values) do
                byIndex[index] = not EMPTY_VALUES[value] and _words(value)
            end
            _vocabWords[axis] = byIndex
        end
    end
    return _vocabWords
end

-- Does `words` hold the plan's word, or its singular?
local function _holds(words, plan)
    return words:find(plan.whole, 1, true) ~= nil
        or (plan.singularWhole ~= nil and words:find(plan.singularWhole, 1, true) ~= nil)   -- exception(nullable): only a plural has a singular
end

-- [slot] = { [vocabIndex] = true } for every packed-axis value holding the word.
-- Empty for most words: a name fragment or a typo names no facet.
local function _facetHits(plan)
    local vocabWords, hits = _facetVocabWords(), {}
    for slot, axis in ipairs(HDG.StaticData.Facets:GetAxes()) do
        local indexes = {}
        for index, words in pairs(vocabWords[axis]) do
            if words and _holds(words, plan) then indexes[index] = true end   -- exception(nullable): false marks a value that says nothing
        end
        if next(indexes) then hits[slot] = indexes end
    end
    return hits
end

-- One query word, resolved once per query: the forms each source is asked for.
local function _plan(word)
    local plan = { word = word, whole = " " .. word .. " " }
    if #word > 3 and word:sub(-1) == "s" and word:sub(-2) ~= "ss" then
        plan.singular = word:sub(1, -2)
        plan.singularWhole = " " .. plan.singular .. " "
    end
    plan.facetHits = _facetHits(plan)
    return plan
end

local function _inName(lowerName, plan)
    return lowerName:find(plan.word, 1, true) ~= nil
        or (plan.singular ~= nil and lowerName:find(plan.singular, 1, true) ~= nil)   -- exception(nullable): only a plural has a singular
end

local function _inTags(tags, plan)
    for tagID, displayName in pairs(tags) do
        if _holds(_tagWordsOf(tagID, displayName), plan) then return true end
    end
    return false
end

-- A record's bytes: byte k is where axis k's tags start, byte k+1 where they
-- end (exclusive), each tag its vocab index (Facets:GetAxes).
local function _inFacets(rec, hits)
    for slot, indexes in pairs(hits) do
        local first, stop = byte(rec, slot, slot + 1)
        for p = first, stop - 1 do
            if indexes[byte(rec, p)] then return true end
        end
    end
    return false
end

local function _rowHasWord(row, lowerName, plan, facets, visionWords)
    if _inName(lowerName, plan) then return true end
    local tags = row.dataTagsByID
    if tags and _inTags(tags, plan) then return true end   -- exception(boundary): Blizzard struct field optional
    local rec = facets[row.itemID]
    if rec and _inFacets(rec, plan.facetHits) then return true end   -- exception(nullable): FacetDB tags most catalog items, not all
    local words = visionWords[row.itemID]
    return words ~= nil and _holds(words, plan)   -- exception(nullable): only decor with a vision row has words
end

local function _matchAll() return true end

-- fn(row) -> true when the row answers every word of `query`. An empty query
-- matches everything, through one shared function.
function DS.Build(query)
    local plans = {}
    for word in _words(query):gmatch("%S+") do plans[#plans + 1] = _plan(word) end
    if #plans == 0 then return _matchAll end
    local facets      = HDG.StaticData.Facets:GetAll()
    local visionWords = HDG.StaticData.SearchWords:GetAll()
    return function(row)
        local lowerName = row.name:lower()
        for i = 1, #plans do
            if not _rowHasWord(row, lowerName, plans[i], facets, visionWords) then return false end
        end
        return true
    end
end
