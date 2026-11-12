-- HDG.StaticData
-- ============================================================================
-- Facade for build-pipeline-generated data tables shipped in TOC-loaded Lua
-- files (immutable within a session). See ADR-003c.
--
-- Rules:
--   1. Selectors call HDG.StaticData.<Domain>:<accessor>() -- never _G.HDGR_*DB directly.
--   2. Selectors declare reads = {"session.resolvers.staticData.tick"} (always 0 today;
--      reserves space for future hot-reload override).
--   3. Tests stub HDG.StaticData.<Domain> to inject fixtures.
--
-- Wrapped tables (all loaded via TOC before this module):
--   HDGR_VendorAugment         -> VendorAugment:Get / ResolveName / GetVendorsByMap
--   HDGR_ItemAugment           -> ItemAugment:Get  (sparse; rep gates + sourceType)
--   HDGR_DecorDB               -> Recipes:Get / GetAll  (recipe-backed subset)
--   HDGR_RecipeSourceAugment   -> RecipeSources:Get / GetAll / GetByNpcID / VendorCounts
--   HDGR_DecorQuestIndex       -> DecorQuests:Line / StepMap / StepStart / ChainOf / SoloStep /
--                                 SoloStart / Gate / Title / Repeat / Build / Campaigns / ChapterOf / ChaptersFor
--                                 (packed lines; decoded on read)
--   HDGR_ProfessionsDB         -> Professions:VisitAll  (packed; decoded on read)
--   HDGR_ProfessionQualityGroups -> Professions:GetQualityVariants
--   HDGR_ReagentsDB            -> Reagents:Get / GetAll
--   HDGR_FacetDB               -> Facets:Get / GetAll
--   HDGR_FacetVocab            -> Facets:GetVocab
--   HDGR_FacetAxes             -> Facets:GetAxes
--   HDGR_DecorSearchDB         -> SearchWords:GetAll
--   HDGR_PetSizeDB             -> PetSizes:Get  (sparse; nil = never measured)
--   HDGR_StyleDefinitions      -> Styles:GetDefinitions
--   HDGR_CollectionDefinitions -> Collections:GetDefinitions
--   HDGR_TrainersDB            -> Trainers:GetAll / GetPlaces
--   HDGR_HouseTab_TitleTiers     -> TitleTiers:GetAll
--   HDGR_HouseTab_WidgetDefaults -> WidgetDefaults:GetAll
--   HDGR_ExpansionData         -> Expansions:GetAll  (also in HDG.Constants)
--   HDGR_SchemeMeta            -> Schemes:GetMeta

HDG = HDG or {}
HDG.StaticData = HDG.StaticData or {}

local S = HDG.StaticData

-- Tiny helper. Fail loud on missing data file (TOC misconfiguration / load
-- order error) rather than returning empty tables that silently produce
-- "vendor not found" / "decor not in catalog" UI states.
local function _table(globalName)
    local t = _G[globalName]
    if type(t) ~= "table" then
        error("HDG.StaticData: _G." .. globalName .. " missing or not a table "
              .. "(got " .. type(t) .. "). Is the data file in <Addon>.toc "
              .. "before HDGR_StaticData.lua?", 2)
    end
    return t
end

-- ============================================================================
-- VendorAugment  (HDGR_VendorAugment)
-- ============================================================================
---@class HDG.StaticData.VendorAugment
S.VendorAugment = S.VendorAugment or {}
-- Built on first use (_EnsureIndexes), not at login: the first reader is the catalog
-- sweep on the first Decor open.
S.VendorAugment._byName = nil
S.VendorAugment._byMapID = nil

function S.VendorAugment:Get(npcID)
    local t = _table("HDGR_VendorAugment")  -- exception(boundary): _table fails loud if HDGR_VendorAugment DB missing
    return t[npcID]
end

function S.VendorAugment:ResolveName(name, zone)
    self:_EnsureIndexes()
    if zone then
        -- Try "Name/Zone" form first, then "Name (Zone)" curator form
        local r = self._byName[name .. "/" .. zone]
                  or self._byName[name .. " (" .. zone .. ")"]
        if r then return r end
    end
    return self._byName[name]
end

function S.VendorAugment:GetVendorsByMap(mapID)
    self:_EnsureIndexes()
    return self._byMapID[mapID]
end

function S.VendorAugment:_EnsureIndexes()
    if self._byName then return end
    local byName, byMapID = {}, {}
    local t = _table("HDGR_VendorAugment")
    -- Iterate npcIDs in SORTED order, not pairs() order. "First occurrence wins
    -- the unqualified name" is only a meaningful rule if "first" is stable, and
    -- LuaJIT varies pairs() order per PROCESS -- so with 16 names now living in
    -- two housing neighborhoods, an unzoned ResolveName could answer with a
    -- different npcID on each login. Sorting makes the winner the same every
    -- session and keeps byMapID's per-map order stable for the Zone Scanner.
    local ids = {}
    for npcID in pairs(t) do ids[#ids + 1] = npcID end
    table.sort(ids)
    for _, npcID in ipairs(ids) do
        local v = t[npcID]
        -- Name index. EVERY row gets its zone-qualified keys, not just collisions --
        -- the first row used to get the bare name alone, so ResolveName(name, zone)
        -- MISSED for it and fell through to the unqualified fallback, quietly answering
        -- with whichever npcID sorted lowest. With a vendor in both housing
        -- neighborhoods that meant the pane showed the wrong zone AND the wrong coords
        -- to a player standing next to the right one (2026-08-24).
        -- First occurrence still wins the bare name, so the zone-less fallback is
        -- unchanged for the single-zone majority.
        byName[v.name .. "/" .. v.zone]         = byName[v.name .. "/" .. v.zone] or npcID
        byName[v.name .. " (" .. v.zone .. ")"] = byName[v.name .. " (" .. v.zone .. ")"] or npcID
        if not byName[v.name] then byName[v.name] = npcID end
        -- Base-name index: curator names use "Name (Zone)" but the housing
        -- catalog reports the bare in-game name. Key base name by zone so a
        -- bare catalog name resolves to the right npcID (additive, never
        -- overrides an exact-name key).
        local base = v.name:gsub("%s*%b()%s*$", "")
        if base ~= v.name and base ~= "" then
            byName[base .. "/" .. v.zone]         = byName[base .. "/" .. v.zone] or npcID
            byName[base .. " (" .. v.zone .. ")"] = byName[base .. " (" .. v.zone .. ")"] or npcID
            if not byName[base] then byName[base] = npcID end
        end
        -- MapID index: list of vendors per mapID. Not map 0: a vendor with no fixed
        -- map (Celestine of the Harvest rotates) has mapID 0, which is also what the
        -- game reports where it gives no map, and standing there loaded a cold
        -- catalog for a zone alert that could never fire (test audit B4, 2026-10-31).
        if v.mapID and v.mapID ~= 0 then
            byMapID[v.mapID] = byMapID[v.mapID] or {}
            table.insert(byMapID[v.mapID], npcID)
        end
    end
    self._byName = byName
    self._byMapID = byMapID
end

-- ============================================================================
-- StaticData.ItemAugment  (HDGR_ItemAugment)
-- Sparse itemID-keyed augments: rep gates, sourceType, altSourceType.
-- ============================================================================
---@class HDG.StaticData.ItemAugment
S.ItemAugment = S.ItemAugment or {}

function S.ItemAugment:Get(itemID)
    local t = _table("HDGR_ItemAugment")
    return t[itemID]
end

-- ============================================================================
-- StaticData.CatalogOverrides  (HDGR_CatalogOverrides)
-- itemID-keyed field-level overrides applied at BuildRow time; corrects
-- known-wrong catalog fields. Sparse; populated reactively on user reports.
-- ============================================================================
---@class HDG.StaticData.CatalogOverrides
S.CatalogOverrides = S.CatalogOverrides or {}

function S.CatalogOverrides:Get(itemID)
    local t = _table("HDGR_CatalogOverrides")
    return t[itemID]
end

-- ============================================================================
-- Recipes  (HDGR_DecorDB -- recipe-backed decor only; subset of Decor)
-- ============================================================================

---@class HDG.StaticData.Recipes
S.Recipes = S.Recipes or {}

-- HDGR_DecorDB keyed by spell/recipe ID; `itemID` inside each entry.
-- One O(1) reverse index, built lazily on first use (rebuilt when the DB table
-- reference changes):
--   _byItemIDCache  itemID -> entry  (:Get)
-- Where a recipe is learned lives in RecipeSources below, not here.
local _byItemIDCache, _cachedSource
local function _ensureRecipeIndexes()
    local db = _table("HDGR_DecorDB")
    if _cachedSource == db then return end
    _byItemIDCache = {}
    for _, entry in pairs(db) do
        if entry.itemID then _byItemIDCache[entry.itemID] = entry end
    end
    _cachedSource = db
end

function S.Recipes:Get(itemID)
    if not itemID then return nil end
    _ensureRecipeIndexes()
    return _byItemIDCache[itemID]
end

function S.Recipes:GetAll()
    return _table("HDGR_DecorDB")
end

-- Walk a DecorDB entry's direct reagents, mirroring Professions:VisitBasicSlots so the
-- decor recipe path (queue/materials/lumber/tooltip) can read DecorDB instead of
-- ProfessionsDB. visitor({ itemID, qty, name }); a truthy return stops early. DecorDB
-- has no non-basic slots, so there is no `type` filter. Reagents are pairs()-iterated
-- (unordered) -- fine for the commutative accumulators + any-match early-stop consumers.
function S.Recipes:VisitReagents(entry, visitor)
    if not (entry and entry.reagents) then return end
    for itemID, info in pairs(entry.reagents) do
        if visitor({ itemID = itemID, qty = info.qty, name = info.name }) then return end
    end
end

-- ============================================================================
-- RecipeSources  (HDGR_RecipeSourceAugment -- where each decor recipe is learned)
-- ============================================================================
-- Generated by housingdecorguide-tools/recipesource/build_recipe_sources.lua from
-- the game's own "how to learn" text plus our fills. Keyed by the CRAFTED itemID,
-- which HDG's row envelopes call recipeID; the recipe's spellID is a field:
--   [itemID] = { spellID, skill, from, notes, sources = { source, ... } }
--   source   = { kind, npcID, name, zone, tier, copper, factionID, minRep, questID, notes,
--                currency = { {"c", currencyID, n}, {"i", itemID, n} } }
-- minRep is HDG's code (4-8 standing, 9+ = rank + 8, as RepObserver:GetProgress reads it).

---@class HDG.StaticData.RecipeSources
S.RecipeSources = S.RecipeSources or {}

-- Vendor reverse index, built on first use (rebuilt when the table reference changes):
--   _offersByNpc  npcID -> { { itemID, source }, ... }
-- One offer per recipe the vendor sells, carrying THAT vendor's source record: a
-- recipe sold by two vendors has a price and rep gate at each. Only vendor sources
-- are indexed -- a named trainer carries an npcID too, but sells nothing. Every
-- shipped vendor source has an npcID: the build's unresolved ones (name + zone) are
-- backfilled before a harvest ships, and test_recipe_sources pins it.
local _offersByNpc, _offersSource
local function _ensureOffers()
    local db = _table("HDGR_RecipeSourceAugment")
    if _offersSource == db then return end
    _offersByNpc = {}
    for itemID, entry in pairs(db) do
        for _, src in ipairs(entry.sources) do
            if src.kind == "vendor" then
                local list = _offersByNpc[src.npcID] or {}
                list[#list + 1] = { itemID = itemID, source = src }
                _offersByNpc[src.npcID] = list
            end
        end
    end
    _offersSource = db
end

-- itemID -> its entry, or nil for a recipe the last harvest didn't cover.
function S.RecipeSources:Get(itemID)
    return _table("HDGR_RecipeSourceAugment")[itemID]
end

function S.RecipeSources:GetAll()
    return _table("HDGR_RecipeSourceAugment")
end

-- npcID -> the offers above, or nil when the vendor sells no decor recipe.
function S.RecipeSources:GetByNpcID(npcID)
    _ensureOffers()
    return _offersByNpc[npcID]
end

-- npcID -> how many decor recipes the vendor sells. Drives the acq.allVendors union
-- (recipe-only vendors) and the vendor header's recipe count.
function S.RecipeSources:VendorCounts()
    _ensureOffers()
    local out = {}
    for npcID, list in pairs(_offersByNpc) do out[npcID] = #list end
    return out
end

-- Cross-source gap check: recipe vendors absent from VendorAugment lose name, zone
-- and coords downstream (acq.allVendors skips them). PURE -- returns (count,
-- sample-of-8); the caller logs (ProfessionScanner's first spellbook pass). This facade
-- stays log-free so partial test fixtures can load it bare, and selectors stay
-- pure by skipping silently instead of warning per recompute.
function S.RecipeSources:VendorAugmentGaps()
    _ensureOffers()
    local aug = _table("HDGR_VendorAugment")
    local missing, n = {}, 0
    for npcID in pairs(_offersByNpc) do
        if not aug[npcID] then
            n = n + 1
            if n <= 8 then missing[n] = tostring(npcID) end
        end
    end
    return n, missing
end

-- ============================================================================
-- DecorQuests  (HDGR_DecorQuestIndex -- the quest lines that lead to decor quests)
-- ============================================================================
-- Generated by housingdecorguide-tools/decorquests/build_decor_quest_index.py; the
-- grammar is in the data file's header. A line ships as one string of steps
--   questID [ "@" spot [ "~" spot ] ] [ "#" giver ] [ "<" ender ] [ ">" questID ] [ "&" group ] [ ":" gate ]
--   spot = uiMapID [ "/" x "/" y ]
-- (a second spot is the Horde one, where an open quest's giver stands in each
-- faction's own city; the giver starts the quest, "<Alliance's>/<Horde's>" where an open
-- quest's giver differs by faction, and the ender takes it back, two the same way; ">" makes
-- the step a breadcrumb to that quest; "&" puts it in an any-order group, quests the game
-- hands out together) and decodes on read into flat arrays, one slot per step (no table per step):
--   { name, n, q = { questID... }, map = { uiMapID or 0... }, gate = { code or ""... },
--     mapH = { [step] = the Horde uiMapID } only on a line that has one,
--     bc = { [step] = the questID the breadcrumb leads to } only on a line that has one,
--     ahead = { [step] = true } for a breadcrumb to a later step of its own line (a lead-in
--       into the line), only on a line that has one,
--     grp = { [step] = its any-order group's number on the line } only on a line that has one }
-- StepMap picks a character's map. A step's spot (x / y, where it starts on its map)
-- giver and ender are left packed; StepStart / SoloStart and StepEnd / SoloEnd decode
-- them for the one step a caller asks about. Decoded lines are cached weakly, like Professions' records: the selectors
-- hold the ones in use. A line's step tokens are cached weakly too (_tokensOf).
---@class HDG.StaticData.DecorQuests
S.DecorQuests = S.DecorQuests or {}

local _lines, _linesSource
local _tokens, _tokensSource      -- [lineID] = { step token, ... }, cached weakly as the lines are
local _soloMap, _soloMapH, _soloGate, _soloSource   -- [questID] = uiMapID / Horde uiMapID / gate code, read off the solo string
local _gates = {}                 -- [code] = parsed gate; 41 codes ship, kept for the session

-- One step token -> questID, uiMapID (0 = none), gate code ("" = anyone), the Horde
-- uiMapID when the step has a second spot, the quest a breadcrumb leads to and the
-- step's any-order group (else nil).
local function _decodeStep(token)
    local id, rest = token:match("^(%d+)(.*)$")
    assert(id, "HDG.StaticData: malformed HDGR_DecorQuestIndex step " .. token)
    return tonumber(id), tonumber(rest:match("^@(%d+)")) or 0, rest:match(":([%w%.]+)$") or "",   -- exception(optional): the grammar leaves out an absent map and gate
           tonumber(rest:match("~(%d+)")), tonumber(rest:match(">(%d+)")), tonumber(rest:match("&(%d+)"))
end

-- Step n's value in one of a line's sparse tables (mapH, bc, grp): only a line with
-- such a step carries the table.
local function _putSparse(line, key, n, value)
    if value == nil then return end
    line[key] = line[key] or {}   -- exception(optional): the line's first step with one
    line[key][n] = value
end

-- Marks the breadcrumbs that lead to a later step of their own line (walked back to front,
-- `later` holds the steps after n).
local function _markAhead(line)
    if not line.bc then return end   -- exception(optional): most lines hold no breadcrumb
    local later = {}
    for n = line.n, 1, -1 do
        if later[line.bc[n]] then _putSparse(line, "ahead", n, true) end   -- exception(nullable): bc is sparse, a nil key reads nil
        later[line.q[n]] = true
    end
end

local function _decodeLine(rec)
    local line = { name = rec[1], n = 0, q = {}, map = {}, gate = {} }
    for token in rec[2]:gmatch("%S+") do
        local n = line.n + 1
        line.n = n
        local mapH, leadsTo, grp
        line.q[n], line.map[n], line.gate[n], mapH, leadsTo, grp = _decodeStep(token)
        _putSparse(line, "mapH", n, mapH)
        _putSparse(line, "bc", n, leadsTo)
        _putSparse(line, "grp", n, grp)
    end
    _markAhead(line)
    return line
end

-- Step i's map for a character on side ("A" / "H" / "N"): the Horde spot's on Horde
-- where the step has one, else the step's map (0 = none).
function S.DecorQuests:StepMap(line, i, side)
    local mapH = side == "H" and line.mapH and line.mapH[i]   -- exception(nullable): few steps carry a Horde spot
    return mapH or line.map[i]
end

-- lineID -> the decoded line, or nil for an ID the index does not ship.
function S.DecorQuests:Line(lineID)
    local db = _table("HDGR_DecorQuestIndex")
    if _linesSource ~= db then
        _lines, _linesSource = setmetatable({}, { __mode = "v" }), db
    end
    local line = _lines[lineID]
    if line then return line end
    local rec = db.lines[lineID]   -- exception(nullable): a campaign chapter or caller may name a line the index dropped
    if not rec then return nil end
    line = _decodeLine(rec)
    _lines[lineID] = line
    return line
end

-- The line that leads to decor quest questID for a character on side ("A" / "H" / "N"):
-- the side's own where the factions' chains differ, else the other one. nil = no chain.
function S.DecorQuests:ChainOf(questID, side)
    local c = _table("HDGR_DecorQuestIndex").chains[questID]   -- exception(nullable): solo and unindexed decor quests have no chain
    if type(c) ~= "table" then return c end
    if side == "H" then return c.H or c.A end
    return c.A or c.H
end

-- A decor quest in no line -> uiMapID for a character on side (0 = none), gate code;
-- nil when not solo.
function S.DecorQuests:SoloStep(questID, side)
    local db = _table("HDGR_DecorQuestIndex")
    if _soloSource ~= db then
        _soloMap, _soloMapH, _soloGate, _soloSource = {}, {}, {}, db
        for token in db.solo:gmatch("%S+") do
            local q, map, gate, mapH = _decodeStep(token)
            _soloMap[q], _soloMapH[q], _soloGate[q] = map, mapH, gate
        end
    end
    local mapH = side == "H" and _soloMapH[questID]   -- exception(nullable): few solo quests carry a Horde spot
    return mapH or _soloMap[questID], _soloGate[questID]   -- nil, nil: chained and unindexed decor quests are not solo
end

-- ----- Where a step starts (waypoints, the giver line) -----
-- The decoded lines keep only each step's map; a step's spot and giver are read off its
-- token when a caller asks, one step at a time.

-- Line lineID's step tokens, split in one walk: the detail asks every shown step's start and
-- hand-in in turn, and a walk per step cost 8.6 ms and 379 KB on Twilight Highlands' 243
-- steps (review section 5).
local function _tokensOf(lineID)
    local db = _table("HDGR_DecorQuestIndex")
    if _tokensSource ~= db then
        _tokens, _tokensSource = setmetatable({}, { __mode = "v" }), db
    end
    local tokens = _tokens[lineID]
    if tokens then return tokens end
    tokens = {}
    for token in db.lines[lineID][2]:gmatch("%S+") do tokens[#tokens + 1] = token end
    _tokens[lineID] = tokens
    return tokens
end

-- The token of step i of line lineID.
local function _tokenAt(lineID, i)
    local token = _tokensOf(lineID)[i]
    if not token then error(("HDG.StaticData: no step %d in HDGR_DecorQuestIndex line %d"):format(i, lineID)) end
    return token
end

-- "uiMapID[/x/y]" -> map, x, y (map percent, 0-100; nil when the spot has a map only).
local function _decodeSpot(spot)
    local map, x, y = spot:match("^(%d+)/(%d+)/(%d+)$")
    if map then return tonumber(map), tonumber(x) / 10, tonumber(y) / 10 end
    return tonumber(spot), nil, nil
end

-- An object's or item's name ("o<id>" / "i<id>"): the index ships every one a step names.
local function _nameOf(key)
    local name = _table("HDGR_DecorQuestIndex").names[key]
    assert(name, "HDG.StaticData: HDGR_DecorQuestIndex names has no " .. key)
    return name
end

-- A token's giver for a character on side, as shipped ("<npcID>" / "o<id>" / "i<id>"): the
-- Horde one on Horde where an open step's giver differs by faction ("#<Alliance's>/<Horde's>"),
-- else the one; nil when nobody known starts it.
local function _giverKey(token, side)
    local a, h = token:match("#([oi]?%d+)/([oi]?%d+)")
    if a then return side == "H" and h or a end
    return token:match("#([oi]?%d+)")   -- exception(optional): the grammar leaves out an unknown giver
end

-- A token's start for a character on side: { map (0 = none), x, y, npcID | object | item };
-- the Horde spot and giver on Horde where the step has them. npcID when an NPC starts it,
-- object / item (its name) when an object or an item does, none when nobody known does.
local function _decodeStart(token, side)
    local spot = side == "H" and token:match("~([%d/]+)") or token:match("@([%d/]+)")   -- exception(nullable): most steps have no Horde spot; some no spot at all
    local start, key = { map = 0 }, _giverKey(token, side)
    local kind, id = (key or ""):match("^([oi]?)(%d+)$")   -- exception(optional): the grammar leaves out an unknown giver
    if kind == "" then start.npcID = tonumber(id)
    elseif kind then start[kind == "o" and "object" or "item"] = _nameOf(key) end
    if spot then start.map, start.x, start.y = _decodeSpot(spot) end
    return start
end

-- A token's hand-in key for a character on side ("<npcID>" / "o<id>"): the Horde one on
-- Horde where an open step's hand-in differs by faction ("<<Alliance's>/<Horde's>"), else
-- the one; nil when the quest completes in the field (Wowhead names nobody).
local function _enderKey(token, side)
    local a, h = token:match("<(o?%d+)/(o?%d+)")
    if a then return side == "H" and h or a end
    return token:match("<(o?%d+)")   -- exception(optional): the grammar leaves out an unknown hand-in
end

-- A token's hand-in for a character on side: { npcID } or { object = name }; nil when
-- nobody known takes it. No spot: Blizzard's quest arrow finds a finished quest's.
local function _decodeEnd(token, side)
    local key = _enderKey(token, side)
    if not key then return nil end   -- exception(optional): the grammar leaves out an unknown hand-in
    if key:sub(1, 1) == "o" then return { object = _nameOf(key) } end
    return { npcID = tonumber(key) }
end

-- Step i of line lineID for a character on side ("A" / "H" / "N"): { map, x, y, npcID | object | item }.
function S.DecorQuests:StepStart(lineID, i, side)
    return _decodeStart(_tokenAt(lineID, i), side)
end

-- A token's giver for a character on side: its npcID, the object's or item's name, or false
-- when nobody known starts it.
local function _giverOf(token, side)
    local key = _giverKey(token, side)
    if not key then return false end   -- exception(optional): the grammar leaves out an unknown giver
    local kind, id = key:match("^([oi]?)(%d+)$")
    if kind == "" then return tonumber(id) end
    return _nameOf(key)
end

-- Who starts steps 1..upTo of line lineID for a character on side ([i] as _giverOf): the
-- search box wants every step's giver at once.
function S.DecorQuests:StepGivers(lineID, upTo, side)
    local tokens, out = _tokensOf(lineID), {}
    for n = 1, math.min(upTo, #tokens) do out[n] = _giverOf(tokens[n], side) end
    return out
end

-- Step i's hand-in for a character on side ("A" / "H" / "N"): { npcID } or { object }, nil
-- when none is known.
function S.DecorQuests:StepEnd(lineID, i, side)
    return _decodeEnd(_tokenAt(lineID, i), side)
end

-- A decor quest's token in the solo string, or nil for one in no line the index ships.
local function _soloToken(questID)
    for token in _table("HDGR_DecorQuestIndex").solo:gmatch("%S+") do
        if tonumber(token:match("^%d+")) == questID then return token end
    end
    return nil
end

-- A decor quest in no line, the same way; nil for a catalog quest the index does not ship.
function S.DecorQuests:SoloStart(questID, side)
    local token = _soloToken(questID)
    return token and _decodeStart(token, side)   -- exception(nullable): a catalog quest the index does not ship
end

-- A decor quest in no line: its hand-in for a character on side, or nil.
function S.DecorQuests:SoloEnd(questID, side)
    local token = _soloToken(questID)
    return token and _decodeEnd(token, side)   -- exception(nullable): a catalog quest the index does not ship
end

-- A gate code -> { side = "A" | "H" | nil, races = set | nil, classes = set | nil, removed }.
-- removed: "X", a quest no longer in the game -- nobody takes it.
local function _idSet(list)
    if not list then return nil end
    local set = {}
    for id in list:gmatch("%d+") do set[tonumber(id)] = true end
    return set
end

function S.DecorQuests:Gate(code)
    local g = _gates[code]
    if g then return g end
    g = { side = code:match("^([AH])"), races = _idSet(code:match("r([%d%.]+)")),
          classes = _idSet(code:match("c([%d%.]+)")), removed = code == "X" }
    _gates[code] = g
    return g
end

-- "daily" | "repeatable" for a decor quest the game lets you do again (each turn-in another copy),
-- else nil.
function S.DecorQuests:Repeat(questID)
    return _table("HDGR_DecorQuestIndex").repeats[questID]   -- exception(nullable): most decor quests are done once
end

-- How a step nobody gives starts: "map" (picked on a city's Scouting Map) | "own" (offered on
-- its own), else nil. Only where Wowhead's comments say so (owner 2026-10-30).
function S.DecorQuests:StartHow(questID)
    return _table("HDGR_DecorQuestIndex").starts[questID]   -- exception(nullable): most steps have a giver, or nobody says
end

-- Whether the game hands step questID out itself (start: its StepStart / SoloStart): nobody
-- known gives it and Wowhead's comments don't say how it starts (ruling C, owner 10-30).
function S.DecorQuests:GameGives(start, questID)
    return not (start.npcID or start.object or start.item) and _table("HDGR_DecorQuestIndex").starts[questID] == nil   -- StartHow's read
end

-- How a step nobody takes back ends: "tracker" (completed from the quest tracker's popup), else nil.
function S.DecorQuests:EndHow(questID)
    return _table("HDGR_DecorQuestIndex").ends[questID]   -- exception(nullable): most steps have a hand-in, or nobody says
end

-- Whether a step's giver (role "start") or hand-in ("end") walks with you, an escort or a
-- companion with no fixed spot: the index's follows ("start" / "end" / "both"), only where
-- Wowhead's comments say so (owner 2026-10-30).
function S.DecorQuests:Follows(questID, role)
    local how = _table("HDGR_DecorQuestIndex").follows[questID]   -- exception(nullable): most givers and hand-ins stay put
    return how == role or how == "both"
end

-- The enUS name of a shipped quest, for while the game has none for it (the index's titles: one
-- string, "\n<questID>\t<name>" per quest, searched rather than decoded into a table), or nil.
function S.DecorQuests:Title(questID)
    local titles = _table("HDGR_DecorQuestIndex").titles
    local at = titles:find("\n" .. questID .. "\t", 1, true)
    if not at then return nil end   -- exception(nullable): a quest the index does not ship
    local from = at + #tostring(questID) + 2
    return titles:sub(from, titles:find("\n", from, true) - 1)
end

-- The quests whose enUS name (the index's titles) holds query, the search box's folded text
-- (lowercased, each run of punctuation and spaces one space): { [questID] = true }. One pass
-- over the titles string; each letter matches either case and each space a run of punctuation
-- and spaces (not %s: it would cross a newline into the next title), so the titles are never
-- copied lowercased.
function S.DecorQuests:TitleHits(query)
    local text = query:gsub("%W", "%%%0"):gsub("%a", function(c) return "[" .. c .. c:upper() .. "]" end)
                      :gsub("%% ", "[%%p ]+")
    local pattern, hits, at = "\n(%d+)\t[^\n]-" .. text, {}, 1
    local titles = _table("HDGR_DecorQuestIndex").titles
    while true do
        local _, e, q = titles:find(pattern, at)
        if not e then return hits end
        hits[tonumber(q)] = true
        at = e + 1
    end
end

-- The English name of an NPC that starts a step (the index's npcNames), for the search box;
-- the index ships one for every NPC giver.
function S.DecorQuests:NpcName(npcID)
    local name = _table("HDGR_DecorQuestIndex").npcNames[npcID]
    assert(name, "HDG.StaticData: HDGR_DecorQuestIndex npcNames has no " .. tostring(npcID))
    return name
end

-- The game build the index was generated from ("12.1.5.70575"), for the provenance line.
function S.DecorQuests:Build()
    return _table("HDGR_DecorQuestIndex").build
end

-- The campaign cards (Garrison Campaign): { { id, name, order, chapters } }, each chapter
-- one line per faction ({ A = { lineID, name, giverNpcID }, H = ... }).
function S.DecorQuests:Campaigns()
    return _table("HDGR_DecorQuestIndex").campaigns
end

local _chapterAt, _chapterSource   -- [lineID] = { campaign, index, side }, every chapter line of either faction

local function _indexCampaign(c, at)
    for i, ch in ipairs(c.chapters) do
        for side, entry in pairs(ch) do at[entry[1]] = { campaign = c, index = i, side = side } end
    end
end

-- lineID -> { campaign, index (the chapter's place), side (the faction the line is for) },
-- or nil for a line in no campaign.
function S.DecorQuests:ChapterOf(lineID)
    local db = _table("HDGR_DecorQuestIndex")
    if _chapterSource ~= db then
        _chapterAt, _chapterSource = {}, db
        for _, c in ipairs(db.campaigns) do _indexCampaign(c, _chapterAt) end
    end
    return _chapterAt[lineID]   -- exception(nullable): most lines are in no campaign
end

-- A campaign's chapters for a character on side ("A" / "H" / "N"), in the campaign's
-- order: { lineID, name, giverNpcID } each. Unaligned reads the Alliance ones (ChainOf's
-- rule); a chapter one faction lacks is left out.
function S.DecorQuests:ChaptersFor(campaign, side)
    local key, out = side == "H" and "H" or "A", {}
    for _, ch in ipairs(campaign.chapters) do
        if ch[key] then out[#out + 1] = ch[key] end   -- exception(optional): a chapter may be one faction's only
    end
    return out
end

-- ============================================================================
-- Professions  (HDGR_ProfessionsDB by itemID + HDGR_ProfessionQualityGroups)
-- ============================================================================

---@class HDG.StaticData.Professions
S.Professions = S.Professions or {}

-- Each recipe ships as one string (build_pruned_professions.lua; as tables they
-- held 1.7 MB from login, memory plan 2026-10-19 S2):
--   name^recipeID^categoryName^outputQtyMin^slot~slot~...
--   slot = kind,qty,itemID[,name]     kind: b = basic, f = finishing, m = modifying
-- The key is the itemID; an absent field is empty. Decoded records are cached
-- weakly: the craft graph holds the ones in use, and the rest go back to the
-- collector.
local SLOT_TYPE = { b = "basic", f = "finishing", m = "modifying" }
local _records, _recordsSource

local function _decodeSlot(text)
    local kind, qty, itemID, name = text:match("^(%a),(%d+),(%d+),?(.*)$")
    return { type = SLOT_TYPE[kind], qty = tonumber(qty), itemID = tonumber(itemID),
             name = name ~= "" and name or nil }
end

local function _decodeRecord(itemID, packed)
    local name, recipeID, categoryName, outputQtyMin, slotText =
        packed:match("^([^^]*)%^(%d+)%^([^^]*)%^(%d*)%^(.*)$")
    assert(name, "HDG.StaticData: malformed HDGR_ProfessionsDB record " .. tostring(itemID))
    local slots = {}
    for text in slotText:gmatch("[^~]+") do slots[#slots + 1] = _decodeSlot(text) end
    return { name = name, recipeID = tonumber(recipeID), itemID = itemID,
             categoryName = categoryName ~= "" and categoryName or nil,
             outputQtyMin = tonumber(outputQtyMin), slots = slots }
end

-- The decoded record for one packed entry. The cache follows the table so a
-- swapped global (tests) never serves the old one's records.
local function _record(db, itemID, packed)
    if _recordsSource ~= db then
        _records, _recordsSource = setmetatable({}, { __mode = "v" }), db
    end
    local rec = _records[itemID]
    if not rec then
        rec = _decodeRecord(itemID, packed)
        _records[itemID] = rec
    end
    return rec
end

-- visitor(itemID, record) for every recipe, decoded; returning truthy stops the walk.
function S.Professions:VisitAll(visitor)
    local db = _table("HDGR_ProfessionsDB")
    for itemID, packed in pairs(db) do
        if visitor(itemID, _record(db, itemID, packed)) then return end
    end
end

-- The decoded recipe that makes itemID, or nil when nothing in the seed does.
function S.Professions:Get(itemID)
    local db = _table("HDGR_ProfessionsDB")
    local packed = db[itemID]  -- exception(nullable): gathered and vendor reagents have no recipe
    if not packed then return nil end
    return _record(db, itemID, packed)
end

-- name, categoryName, outputQtyMin of the recipe that makes itemID, read off its
-- packed string without decoding the slots; nothing when the seed has no recipe.
-- The craft graph's capture overlay wants only these from the record it replaces.
function S.Professions:GetHeader(itemID)
    local packed = _table("HDGR_ProfessionsDB")[itemID]  -- exception(nullable): a captured recipe the seed does not ship
    if not packed then return nil end
    local name, categoryName, outputQtyMin = packed:match("^([^^]*)%^%d+%^([^^]*)%^(%d*)%^")
    assert(name, "HDG.StaticData: malformed HDGR_ProfessionsDB record " .. tostring(itemID))
    return name, categoryName ~= "" and categoryName or nil, tonumber(outputQtyMin)
end

-- Quality siblings: tiered reagents have separate itemIDs per quality tier, and
-- any tier satisfies a slot, so material counting sums the whole group. Returns
-- { otherSiblingID, ... } or nil. The seed's groups are precomputed by the
-- generator (HDGR_ProfessionQualityGroups): bag counting asks at login, and
-- deriving them from the recipes would decode every one.
function S.Professions:GetQualityVariants(itemID)
    if not itemID then return nil end
    -- Captured quality groups win: the profession-book scan records the LIVE tier
    -- siblings (account.reagentVariants), covering new 12.1 tiered reagents the
    -- seed's frozen groups can't know. DELIBERATE ADR-003c deviation: this one
    -- accessor reads live Store state, so the facade is no longer "immutable within
    -- a session" here (addendum in HDGR_ARCHITECTURE.md; all four consumers are modules).
    local captured = HDG.Store:GetState().account.reagentVariants[itemID]  -- exception(nullable): most reagents aren't tiered
    if captured then return captured end
    return _table("HDGR_ProfessionQualityGroups")[itemID]  -- exception(nullable): most reagents aren't tiered
end

-- Walk basic-typed slots on a recipe. visitor(slot) called per slot;
-- returning truthy stops the walk early. No-op on nil recipe or no slots.
function S.Professions:VisitBasicSlots(recipe, visitor)
    if not (recipe and recipe.slots) then return end
    for _, slot in ipairs(recipe.slots) do
        if slot.type == "basic" then
            if visitor(slot) then return end
        end
    end
end

-- ============================================================================
-- Reagents  (HDGR_ReagentsDB -- crafting reagent metadata)
-- ============================================================================

---@class HDG.StaticData.Reagents
S.Reagents = S.Reagents or {}

-- source, name for a reagent, or nil. source is "Gathering", "Crafted", "Drop",
-- "Vendor" or "Vendor:<copper>"; name is the baked English placeholder. Each entry
-- ships as one "source|name" string (build_reagents.lua; as two-field tables they
-- held ~0.75 MB, memory census 2026-10-19).
function S.Reagents:Get(itemID)
    if not itemID then return nil end
    local packed = _table("HDGR_ReagentsDB")[itemID]  -- exception(nullable): not every item is a reagent
    if not packed then return nil end
    return packed:match("^([^|]*)|(.*)$")
end

-- Every reagent itemID as the keys; read an entry through Get, never the value.
function S.Reagents:GetAll()
    return _table("HDGR_ReagentsDB")
end

-- ============================================================================
-- Facets  (HDGR_FacetDB + HDGR_FacetVocab for styles tab)
-- ============================================================================

---@class HDG.StaticData.Facets
S.Facets = S.Facets or {}

-- A record is a byte string, laid out by HDGR_FacetAxes (see GetAxes).
function S.Facets:Get(itemID)
    if not itemID then return nil end
    return _table("HDGR_FacetDB")[itemID]
end

function S.Facets:GetAll()
    return _table("HDGR_FacetDB")
end

function S.Facets:GetVocab()
    return _table("HDGR_FacetVocab")
end

-- Axis names in record slot order. In a record, byte k is where axis k's tags
-- start and byte k+1 where they end (exclusive); each tag is one byte, its index
-- in GetVocab()[axis]. Layout written by housingdecorguide-tools/facetdb/export_facetdb.py.
function S.Facets:GetAxes()
    return _table("HDGR_FacetAxes")
end

-- ============================================================================
-- SearchWords  (HDGR_DecorSearchDB)
-- ============================================================================
-- The words of a decor's free-text vision tags, for the Decor search
-- (UI/HDGR_DecorSearch.lua): one string per itemID, each word between single
-- spaces. Only decor with a vision row has an entry.

---@class HDG.StaticData.SearchWords
S.SearchWords = S.SearchWords or {}

function S.SearchWords:GetAll()
    return _table("HDGR_DecorSearchDB")
end

-- ============================================================================
-- PetSizes  (HDGR_PetSizeDB)
-- ============================================================================
-- Rendered pet height, for the Decor tab's Pets browser. The runtime has no
-- height to offer: GetActiveBoundingBox and CreatureModelData.GeoBox are the
-- same number and union over ANIMATION TRAVEL, so a jumping model reports the
-- volume it moves through. These come from the M2 vertex array instead.

---@class HDG.StaticData.PetSizes
S.PetSizes = S.PetSizes or {}

-- nil for a species that was never measured. A miss is a VALID answer -- callers
-- render the row without a height rather than substituting one, because there is
-- nothing honest to substitute.
function S.PetSizes:Get(speciesID)
    if not speciesID then return nil end
    return _table("HDGR_PetSizeDB")[speciesID]
end

-- ============================================================================
-- Styles  (HDGR_StyleDefinitions)
-- ============================================================================

---@class HDG.StaticData.Styles
S.Styles = S.Styles or {}

function S.Styles:GetDefinitions()
    return _table("HDGR_StyleDefinitions")
end

-- ============================================================================
-- Collections  (HDGR_CollectionDefinitions)
-- ============================================================================

---@class HDG.StaticData.Collections
S.Collections = S.Collections or {}

function S.Collections:GetDefinitions()
    return _table("HDGR_CollectionDefinitions")
end

-- ============================================================================
-- Trainers  (HDGR_TrainersDB -- profession trainer NPCs by profession + expansion)
-- ============================================================================
--
-- Shape: HDGR_TrainersDB[profName][expName][faction] -> trainerRecord OR
--        HDGR_TrainersDB[profName][expName][faction] -> { trainerRecord, ... }
-- Faction key is one of "Alliance" / "Horde" / "Both".
-- trainerRecord fields: npcID, name, location ("Zone [x, y]"), note? (optional)

---@class HDG.StaticData.Trainers
S.Trainers = S.Trainers or {}

function S.Trainers:GetAll()
    return _table("HDGR_TrainersDB")
end

-- One (profession, expansion) entry as a flat list of trainer places, built once per
-- key: { npcID, name, note, side = "A"|"H"|"N", zone, x, y }. The raw entry is
-- irregular (one record, or a list, under each faction key) and its location a
-- "Zone [x, y]" string; Recipe Sources reads both shapes through this. nil when
-- TrainersDB has no trainers for that tier.
local SIDE_CODE = { Alliance = "A", Horde = "H", Both = "N" }
local _placesByKey, _placesSource = {}, nil

local function _trainerPlace(rec, side)
    local zone, x, y = rec.location:match("^(.-)%s*%[(.-),%s*(.-)%]%s*$")
    return { npcID = rec.npcID, name = rec.name, note = rec.note, side = SIDE_CODE[side],
             zone = zone or rec.location, x = tonumber(x), y = tonumber(y) }  -- exception(nullable): a location without [x, y] is the zone alone
end

local function _buildPlaces(entry)
    local out = {}
    for side, data in pairs(entry) do
        local recs = data.npcID and { data } or data
        for _, rec in ipairs(recs) do out[#out + 1] = _trainerPlace(rec, side) end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function S.Trainers:GetPlaces(profName, expName)
    local db = _table("HDGR_TrainersDB")
    if _placesSource ~= db then _placesByKey, _placesSource = {}, db end
    local key = profName .. "|" .. expName
    if _placesByKey[key] == nil then
        local prof = db[profName]   -- exception(nullable): a profession TrainersDB lacks
        local entry = prof and prof[expName]   -- exception(nullable): a tier TrainersDB lacks
        _placesByKey[key] = entry and _buildPlaces(entry) or false
    end
    local places = _placesByKey[key]
    if places == false then return nil end
    return places
end

-- ============================================================================
-- TitleTiers  (HDGR_HouseTab_TitleTiers -- decorator title ladder)
-- Shape: ordered array of { threshold, name, vamoose? }, ascending threshold.
-- ============================================================================

---@class HDG.StaticData.TitleTiers
S.TitleTiers = S.TitleTiers or {}

function S.TitleTiers:GetAll()
    return _table("HDGR_HouseTab_TitleTiers")
end

-- ============================================================================
-- WidgetDefaults  (HDGR_HouseTab_WidgetDefaults)
-- Shape: ordered array of { id, title, order, width, enabled, defaultHeight }.
-- ============================================================================

---@class HDG.StaticData.WidgetDefaults
S.WidgetDefaults = S.WidgetDefaults or {}

function S.WidgetDefaults:GetAll()
    return _table("HDGR_HouseTab_WidgetDefaults")
end

-- ============================================================================
-- Expansions  (HDGR_ExpansionData -- mirrored in HDG.Constants.EXPANSION_DATA)
-- ============================================================================

---@class HDG.StaticData.Expansions
S.Expansions = S.Expansions or {}

function S.Expansions:GetAll()
    return _table("HDGR_ExpansionData")
end

-- ============================================================================
-- Schemes  (HDGR_SchemeMeta -- theme scheme definitions)
-- ============================================================================

---@class HDG.StaticData.Schemes
S.Schemes = S.Schemes or {}

function S.Schemes:GetMeta()
    return _table("HDGR_SchemeMeta")
end

-- Get a built scheme by name (nil if the name isn't a registered scheme).
function S.Schemes:Get(name)
    return _table("HDGR_SchemeConstants")[name]
end

-- ============================================================================
-- PetFacts  (HDGR_PetTaxonomyDB / PetVoiceDB / PetAnimDB / PetSceneDecorDB / PetSizeDB / PetCantAttachDB)
-- ============================================================================
-- The Menagerie's data facade (HDGR_MENAGERIE_LATTICE_PLAN_2026-08-24 section 1). The
-- raw _G.HDGR_Pet*DB tables are read NOWHERE else; reverse indexes (kind counts,
-- clade counts, voice sharing) build lazily once and rebuild only if the DB
-- table reference changes (test seam -- same idiom as Recipes above).
--
-- Records the Menagerie reads one pet at a time (anim profiles, voices, scene
-- rows) ship as strings and are decoded here on each call, into a fresh table the
-- caller may keep. As nested tables the pet DBs held 4.6 MB (memory census
-- 2026-10-19). Formats: vpp-tools/export_pet_lua.py and build_sizedb.py.

---@class HDG.StaticData.PetFacts
S.PetFacts = S.PetFacts or {}

-- "a,b,c" -> { a, b, c } as numbers; "" -> {}.
local function _numberList(s)
    local out = {}
    for n in s:gmatch("[^,]+") do out[#out + 1] = tonumber(n) end
    return out
end

local _pfKinds, _pfClades, _pfVoiceShare, _pfSource

local function _ensurePetIndexes()
    local db = _table("HDGR_PetTaxonomyDB")
    if _pfSource == db then return end
    _pfKinds, _pfClades, _pfVoiceShare = {}, {}, {}
    for _, row in pairs(db) do
        local kind, clade = row[1], row[2]
        local k = _pfKinds[kind]
        if not k then
            k = { count = 0, clade = clade }
            _pfKinds[kind] = k
        end
        k.count = k.count + 1
        _pfClades[clade] = (_pfClades[clade] or 0) + 1
    end
    for _, voice in pairs(_table("HDGR_PetVoiceDB").species) do
        _pfVoiceShare[voice] = (_pfVoiceShare[voice] or 0) + 1
    end
    _pfSource = db
end

-- kind, clade for a species. nil, nil = species not in the taxonomy (a NEW pet
-- since the last data build) -- a real state the UI shows as "?", never a guess.
function S.PetFacts:Taxonomy(speciesID)
    local row = _table("HDGR_PetTaxonomyDB")[speciesID]  -- exception(nullable): post-build species miss
    if not row then return nil, nil end
    return row[1], row[2]
end

-- Whether a species can ride decor, from DB2 BattlePetSpecies.Flags
-- (CANT_ATTACH_TO_DECOR). The API carries it only on the 20-field pet info
-- table, and reading that once per owned species cost 6.4 MB a first Menagerie
-- visit; the flag matched the API on all 2,999 live species (/petflag,
-- 2026-10-21). nil = a species newer than the data build: ask the game.
function S.PetFacts:CanAttachToDecor(speciesID)
    local db = _table("HDGR_PetCantAttachDB")
    if speciesID > db.maxSpeciesID then return nil end
    return not db.species[speciesID]
end

-- nil = no idle sound recorded (NOT proven-silent; see build_pet_sound.py header).
function S.PetFacts:Voice(speciesID)
    local db = _table("HDGR_PetVoiceDB")
    local voice = db.species[speciesID]  -- exception(nullable): absence means quiet
    if not voice then return nil end
    _ensurePetIndexes()
    local kits, durs = db.voices[voice]:match("^([^|]*)|([^|]*)$")
    local delay = db.delays[speciesID]  -- exception(nullable): only a few voices carry a fidget delay
    -- `word` is deliberately NOT exposed. The DB carries it (the CASC folder
    -- stem the kits came from) but it is a build identifier, not English -- it
    -- reads as "bloodfangwidowspider" as often as "crab", and the UI shipped it
    -- raw once already. Anything that wants to name a voice needs a curated
    -- vocabulary first; the facade not offering it keeps that decision here.
    return { kits = _numberList(kits), durs = durs ~= "" and _numberList(durs) or nil, index = voice,
             delayMin = delay and delay[1], delayMax = delay and delay[2],
             sharedWith = _pfVoiceShare[voice] - 1 }
end

-- The model's behaviour record: { idle = {{animID, variation, pct, ms},...},
-- also = {animID,...}, glow = {lights, particles, additive}, labels? }.
-- Decoded per call. nil = model unparsed (6 of 967).
function S.PetFacts:AnimProfile(speciesID)
    local db = _table("HDGR_PetAnimDB")
    local fdid = db.species[speciesID]  -- exception(nullable): species without a model join
    if not fdid then return nil end
    local packed = db.models[fdid]      -- exception(nullable): parseError models are not emitted
    if not packed then return nil end
    local idleS, alsoS, glowS = packed:match("^([^|]*)|([^|]*)|([^|]*)$")
    local idle = {}
    for var, pct, ms in idleS:gmatch("(%d+):(%d+):(%d+)") do
        idle[#idle + 1] = { 0, tonumber(var), tonumber(pct), tonumber(ms) }
    end
    return { idle = idle, also = _numberList(alsoS), glow = _numberList(glowS),
             labels = db.labels[fdid] }   -- exception(nullable): most models carry no curated labels
end

function S.PetFacts:Height(speciesID)
    return _table("HDGR_PetSizeDB")[speciesID]  -- exception(nullable): PetSizeDB miss for a post-build species
end

-- actorScale, seatLift, girth for a species, or nothing for an unmeasured mesh.
local function _sceneRow(speciesID)
    local row = _table("HDGR_PetSceneScaleDB")[speciesID]  -- exception(nullable): unmeasured mesh
    if not row then return end
    local scale, lift, girth = row:match("^(%S+) (%S+) (%S+)$")
    return tonumber(scale), tonumber(lift), tonumber(girth)
end

function S.PetFacts:SceneScale(speciesID)
    -- SizeDB height / vertex extent: a ModelScene actor renders the RAW vertex
    -- mesh (no DB2 scale factor applies), so this is what SetRequestedScale
    -- needs for the actor to render at the pet's true world height.
    local scale = _sceneRow(speciesID)
    return scale or 1.0  -- exception(optional): unmeasured mesh; emit convention
end

function S.PetFacts:SceneGirth(speciesID)
    -- Larger horizontal mesh span, world units: the camera frames on
    -- max(height, girth) so long bodies (snakes) are not cropped.
    local _, _, girth = _sceneRow(speciesID)
    return girth or 0  -- exception(optional): unmeasured mesh; emit convention
end

function S.PetFacts:SceneLift(speciesID)
    -- -meshLowestZ x sceneScale: added to the seat Z it drops a hovering
    -- mesh's bottom onto the seat (fliers are authored above their origin).
    local _, lift = _sceneRow(speciesID)
    return lift or 0  -- exception(optional): unmeasured mesh; emit convention
end

function S.PetFacts:KindIndex()
    _ensurePetIndexes()
    return _pfKinds
end

function S.PetFacts:CladeIndex()
    _ensurePetIndexes()
    return _pfClades
end

function S.PetFacts:SceneDecor()
    return _table("HDGR_PetSceneDecorDB")
end
