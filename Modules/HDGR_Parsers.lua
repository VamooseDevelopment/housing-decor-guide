-- HDG.Parsers
-- ============================================================================
-- Format dispatch for both INPUT (Parse) and OUTPUT (Format) sides of the
-- Import / Export flows. Naming convention: the registries handle pluggable
-- per-format codecs; HDG.Codec holds the shared Base64 / envelope primitives.
--
-- Each parser inspects raw pasted text and either:
--   - returns nil  (this parser doesn't recognize the input; try the next)
--   - returns { ok = true, items = {...}, displayName? = string,
--               source? = string, parserName = string }
--   - returns { ok = false, error = "<reason>" }   (definitively rejected)
--
-- The registry tries parsers in declared order; the first non-nil result
-- wins. The fallback "digits" parser matches anything containing digits,
-- so it always sits LAST.
--
-- Adding a new parser:
--   table.insert(HDG.Parsers._parsers, N, {
--       name = "myparser",
--       parse = function(text) ... end,
--   })
-- where N is its priority (lower = earlier).
--
-- Export side:
--   HDG.Parsers._formatters[name] = function(payload) -> string
--   HDG.Parsers:Format(name, payload) -> string | nil, err
-- "smartSet" is the one formatter: a Smart Set's tag code (StyleResolve.ShareCode).
--
-- Result fields:
--   items       array of itemIDs (or decorIDs for snapshot blobs)
--   displayName optional pretty name; controller / reducer uses for the
--               imported collection's displayName when committed
--   source      optional source descriptor (URL / "snapshot" / "smartset")
--   smartSet    a Smart Set code only (HDGSS:1: or the old HDG:1:):
--               { rules, tagCount, dropped, description? }
--               (items is then empty; the import commits a Smart Set)

HDG = HDG or {}
HDG.Parsers = HDG.Parsers or {}
local Parsers = HDG.Parsers

Parsers._parsers    = Parsers._parsers    or {}
Parsers._formatters = Parsers._formatters or {}

-- ===== Helpers ============================================================

local function _dedupe(items)
    local seen, out = {}, {}
    for _, id in ipairs(items or {}) do
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

-- ===== Smart Set codes: one reading for both ==============================
-- Two codes carry a Smart Set's tag rules and no decor: HDGSS:1: (parser 2c,
-- what Export writes now) and the old HDG:1: style code (parser 1). Both read
-- into one set and one result, so the importer's own catalog picks the decor.
-- Tags are checked against the shipped facet vocabulary: a tag, axis or
-- severity this version doesn't know is dropped and counted, never kept.
local SMARTSET_SEVERITIES = { signature = true, accent = true, clashing = true }   -- rule severities; "versatile" is a band

-- [axis] = { [tag] = true } over the shipped vocabulary.
local function _vocabSets()
    local sets = {}
    for axis, tags in pairs(HDG.StaticData.Facets:GetVocab()) do
        local set = {}
        for _, tag in pairs(tags) do set[tag] = true end
        sets[axis] = set
    end
    return sets
end

local function _newSmartSet()
    return { meta = {}, rules = {}, tagCount = 0, dropped = 0 }
end

-- Keeps one rule, or counts it dropped when this version can't use it. A tag's
-- first severity wins: an old code lists signature, accent, clashing in that
-- order, the ranking the old importer gave them.
local function _addSmartSetRule(set, vocabSets, axis, tag, sev)
    if not (vocabSets[axis] and vocabSets[axis][tag] and SMARTSET_SEVERITIES[sev]) then
        set.dropped = set.dropped + 1
        return
    end
    local axisRules = set.rules[axis]
    if not axisRules then axisRules = {}; set.rules[axis] = axisRules end
    if axisRules[tag] then return end
    axisRules[tag] = sev
    set.tagCount = set.tagCount + 1
end

-- A read set -> the parse result; refused when no tag survived.
local function _smartSetResult(set, parserName)
    if set.tagCount == 0 then
        return { ok = false, error = HDG.Locale:Get("STY_IMPORT_SMARTSET_NO_TAGS"):format(set.dropped) }
    end
    local name, desc = set.meta.name, set.meta.desc
    return {
        ok          = true,
        items       = {},
        displayName = name ~= "" and name or nil,   -- exception(boundary): a pasted code may carry no name; the commit seeds one
        source      = "smartset",
        smartSet    = { rules = set.rules, tagCount = set.tagCount, dropped = set.dropped,
                        description = desc ~= "" and desc or nil },   -- exception(boundary): a pasted code may carry no description; the commit writes one
        parserName  = parserName,
    }
end

local function _badSmartSetCode()
    return { ok = false, error = HDG.Locale:Get("STY_IMPORT_SMARTSET_BAD") }
end

-- ===== Parser 1: HDG:1:<base64> old style code ============================
-- What HDG 3.x's Export wrote for a style or Smart Set. It imports as a Smart
-- Set, the same as an HDGSS:1: code (owner 2026-11-01). The body is one line of
-- pipe-separated fields:
--   name|icon|color|description|query|boost|anti
-- icon and color were always placeholders. query, boost and anti are tag maps,
--   axis=tag,tag;axis=tag
-- read as signature, accent and clashing rules, as the old importer ranked them.
-- A 3.x Smart Set exported its name only, so its code holds no tags.
local LEGACY_TAG_FIELD    = 5   -- query's field; the old importer refused a code that stops before it
local LEGACY_TAG_SEVERITY = { "signature", "accent", "clashing" }   -- query, boost, anti

-- One tag map into the set at one severity; a piece with no "=" is dropped.
local function _addLegacyTagMap(set, vocabSets, map, sev)
    for part in map:gmatch("[^;]+") do
        local axis, tags = part:match("^([^=]+)=(.+)$")
        if axis then
            for tag in tags:gmatch("[^,]+") do _addSmartSetRule(set, vocabSets, axis, tag, sev) end
        else
            set.dropped = set.dropped + 1
        end
    end
end

-- payload -> set, or nil when it doesn't have the old field layout.
local function _readLegacyStyle(payload)
    local fields = {}
    for field in (payload .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
    if #fields < LEGACY_TAG_FIELD then return nil end
    local set, vocabSets = _newSmartSet(), _vocabSets()
    set.meta = { name = HDG.Codec.AsciiOnly(fields[1]), desc = HDG.Codec.AsciiOnly(fields[4]) }
    local lastField = math.min(#fields, LEGACY_TAG_FIELD + #LEGACY_TAG_SEVERITY - 1)
    for i = LEGACY_TAG_FIELD, lastField do
        _addLegacyTagMap(set, vocabSets, fields[i], LEGACY_TAG_SEVERITY[i - LEGACY_TAG_FIELD + 1])
    end
    return set
end

table.insert(Parsers._parsers, {
    name = "legacyStyleBlob",
    parse = function(text)
        if not text:match("^HDG:1:") then return nil end
        local payload = HDG.Codec.UnwrapEnvelope(text, "HDG", "1")
        if not payload then return _badSmartSetCode() end
        local set = _readLegacyStyle(payload)
        if not set then return _badSmartSetCode() end
        return _smartSetResult(set, "legacyStyleBlob")
    end,
})

-- ===== Parser 2: HDGVL:1:<base64> shopping list / snapshot blob ===========
-- These are item-bearing blobs and CAN be imported as a shopping list.
table.insert(Parsers._parsers, {
    name = "shoppingListBlob",
    parse = function(text)
        if not (text and text:match("^HDGVL:1:")) then return nil end
        -- Use ShoppingCodec.Decode -- the SAME decoder the Shopping tab import uses and which
        -- handles wowdb builds + HDG exports + decorID resolution.
        if not (HDG.ShoppingCodec and HDG.ShoppingCodec.Decode) then  -- exception(boundary): optional module / not yet built
            return { ok = false, error = "Shopping list importer unavailable" }
        end
        local result = HDG.ShoppingCodec.Decode(text)
        if not result then
            return { ok = false, error = "Shopping list decode failed -- expected HDGVL:1:..." }
        end
        -- result.items = array of { itemID, npcID, qty }; flatten to a deduped itemID array.
        local itemIDs = {}
        for _, e in ipairs(result.items or {}) do
            if e.itemID then itemIDs[#itemIDs + 1] = e.itemID end
        end
        return {
            ok          = true,
            items       = _dedupe(itemIDs),
            displayName = result.name,
            source      = (result.meta and result.meta.source) or "shopping list blob",  -- exception(nullable): meta.source optional
            unmatched   = result.droppedCount,   -- decor IDs not in the live catalog (unreleased etc.)
            parserName  = "shoppingListBlob",
        }
    end,
})

-- ===== Parser 2b: HDGRCRATE:1:<base64> furnishing-set blob ================
-- HDG's furnishing-set share code (Projects "Export Set"). Item-bearing -> importable,
-- so the unified importer handles it too (e.g. when reached from the Projects Import button).
table.insert(Parsers._parsers, {
    name = "crateBlob",
    parse = function(text)
        if not (text and text:match("^HDGRCRATE:1:")) then return nil end
        if not (HDG.Projects and HDG.Projects.CrateCodec and HDG.Projects.CrateCodec.Decode) then  -- exception(boundary): optional module
            return { ok = false, error = "Set importer unavailable" }
        end
        local decoded = HDG.Projects.CrateCodec.Decode(text)
        if not decoded then
            return { ok = false, error = "Set decode failed -- expected HDGRCRATE:1:..." }
        end
        local itemIDs = {}
        for _, d in ipairs(decoded.decor or {}) do
            if d.id then itemIDs[#itemIDs + 1] = d.id end
        end
        return {
            ok          = true,
            items       = _dedupe(itemIDs),
            displayName = decoded.name,
            source      = "furnishing set",
            parserName  = "crateBlob",
        }
    end,
})

-- ===== Parser 2c: HDGSS:1:<base64> Smart Set tag code =====================
-- A Smart Set shares its tag rules, not the decor they match today (owner
-- 2026-10-31). Read through the shared Smart Set section above parser 1. Body:
--   name=<urlencoded>[,desc=<urlencoded>]
--   axis,tag,severity        -- one line per rule, sorted
local SMARTSET_MAGIC, SMARTSET_VERSION = "HDGSS", "1"

local function _smartSetRuleLines(rules)
    local lines = {}
    for axis, tags in pairs(rules) do
        for tag, sev in pairs(tags) do lines[#lines + 1] = axis .. "," .. tag .. "," .. sev end
    end
    table.sort(lines)   -- pairs order varies; the same set always gives the same code
    return lines
end

Parsers._formatters.smartSet = function(record)
    local header = "name=" .. HDG.Codec.urlencode(record.displayName)
    if record.description ~= "" then header = header .. ",desc=" .. HDG.Codec.urlencode(record.description) end
    local lines = _smartSetRuleLines(record.rules)
    table.insert(lines, 1, header)
    return HDG.Codec.WrapEnvelope(SMARTSET_MAGIC, SMARTSET_VERSION, table.concat(lines, "\n"))
end

local function _smartSetHeader(line)
    local meta = {}
    for kv in line:gmatch("[^,]+") do
        local k, v = kv:match("^(%w+)=(.*)$")
        if k then meta[k] = HDG.Codec.AsciiOnly(HDG.Codec.urldecode(v)) end
    end
    return meta
end

-- body -> set (see _newSmartSet).
local function _readSmartSetBody(body)
    local set, vocabSets = _newSmartSet(), _vocabSets()
    for line in body:gmatch("[^\n]+") do
        local axis, tag, sev = line:match("^([%w%-]+),([%w%-]+),(%a+)$")
        if axis then
            _addSmartSetRule(set, vocabSets, axis, tag, sev)
        elseif line:match("^%a+=") then
            set.meta = _smartSetHeader(line)
        else
            set.dropped = set.dropped + 1
        end
    end
    return set
end

table.insert(Parsers._parsers, {
    name = "smartSetBlob",
    parse = function(text)
        if not text:match("^HDGSS:") then return nil end
        local body = HDG.Codec.UnwrapEnvelope(text, SMARTSET_MAGIC, SMARTSET_VERSION)
        if not body then return _badSmartSetCode() end
        return _smartSetResult(_readSmartSetBody(body), "smartSetBlob")
    end,
})

-- ===== Parser 3: Blizzard item chat-link extraction =======================
-- |Hitem:NNNNN:... from shift-clicked items; itemID is first arg after "item:".
table.insert(Parsers._parsers, {
    name = "itemLinks",
    parse = function(text)
        if not text or not text:find("|Hitem:") then return nil end
        local items = {}
        for idStr in text:gmatch("|Hitem:(%d+)") do
            local n = tonumber(idStr)
            if n and n > 0 then items[#items + 1] = n end
        end
        if #items == 0 then return nil end
        return {
            ok         = true,
            items      = _dedupe(items),
            source     = "chat item links",
            parserName = "itemLinks",
        }
    end,
})

-- ===== Parser 4: URL items query param ====================================
-- ?items=NNN,NNN or ?item=NNN. Digits extracted; ignores other URL parts.
table.insert(Parsers._parsers, {
    name = "urlItemsParam",
    parse = function(text)
        if not text then return nil end
        local block = text:match("[%?&]items=([%d,]+)")
                   or text:match("[%?&]item=([%d,]+)")
        if not block then return nil end
        local items = {}
        for idStr in block:gmatch("%d+") do
            local n = tonumber(idStr)
            if n and n > 0 then items[#items + 1] = n end
        end
        if #items == 0 then return nil end
        local source = "url query"
        if text:find("wowhead.com", 1, true) then
            source = "wowhead"
        elseif text:find("housing.wowdb.com", 1, true) then
            source = "housing.wowdb.com"
        end
        return {
            ok         = true,
            items      = _dedupe(items),
            source     = source,
            parserName = "urlItemsParam",
        }
    end,
})

-- ===== Parser 5 (fallback): plain digit run ==============================
-- Accepts any digit run. Bottom of registry; domain-specific parsers always win.
table.insert(Parsers._parsers, {
    name = "digits",
    parse = function(text)
        if not text or text == "" then
            return { ok = false, error = "No item IDs found" }
        end
        local items = {}
        for digits in text:gmatch("%d+") do
            local n = tonumber(digits)
            if n and n > 0 then items[#items + 1] = n end
        end
        if #items == 0 then
            return { ok = false, error = "No item IDs found" }
        end
        return {
            ok         = true,
            items      = _dedupe(items),
            source     = "manual paste",
            parserName = "digits",
        }
    end,
})

-- ===== Public API =========================================================

-- Parse: first parser that recognizes the input wins. Returns result or { ok=false, error }.
function Parsers:Parse(text)
    text = text or ""
    for _, entry in ipairs(self._parsers) do
        local result = entry.parse(text)
        if result ~= nil then return result end
    end
    return { ok = false, error = "No parser matched" }
end

-- Format: emit a string via the named formatter. Reserved for export-side parity.
function Parsers:Format(name, payload)
    local fn = self._formatters[name]
    if not fn then return nil, "No formatter registered for " .. tostring(name) end
    return fn(payload)
end
