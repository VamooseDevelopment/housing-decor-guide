-- HDG.Selectors -- Recipe Sources tab
-- ============================================================================
-- Every decor recipe (HDGR_DecorDB) and where it is learned (StaticData.RecipeSources),
-- shaped like Find Decor: filters and a list on the left, the detail on the right.
-- One filtered set feeds two lists (session.ui.recipeSources.viewMode):
--   By Recipe  -- grouped by profession (recipeSources.recipeRows)
--   By Teacher -- every place a recipe's sources send you: the NPCs grouped by the
--                 newest expansion they serve, drops / treasures / discoveries in a
--                 group of their own at the bottom (recipeSources.teacherRows)
-- A generic trainer source ("any Classic Alchemy trainer") resolves to TrainersDB's
-- NPCs for the player's faction (session.identity.factionGroup) here, at selector
-- time. Rows carry kinds and plain text; the row factories own every color.

HDG = HDG or {}
local Selectors = HDG.Selectors

local UI_PATH = "session.ui.recipeSources"

-- Source kinds the augment ships (build_recipe_sources.lua header), in menu order.
-- "none" stands for a recipe the harvest has no text for.
local KIND_ORDER = { "trainer", "vendor", "drop", "quest", "discovery", "treasure",
                     "fishing", "auction", "event", "profession", "none" }
-- session.identity.factionGroup is already the data's side code (SessionIdentity stamps
-- "A" / "H" / "N"); only A and H have another faction to dim.
local SIDE_CODE = { A = "A", H = "H" }
local OTHER_GROUP = "other"   -- By Teacher's group for places with no one to visit

local function _kindLabel(kind)
    return HDG.Locale:Get("RS_KIND_" .. kind:upper())
end

local function _byName(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.itemID < b.itemID
end

local function _coords(x, y)
    return string.format("%.1f, %.1f", x, y)
end

-- ============================================================================
-- State mirrors
-- ============================================================================

for _, key in ipairs({ "viewMode", "preset", "searchQuery", "profFilter", "expFilter",
                       "srcFilter", "zoneFilter", "repFilter", "curFilter", "collapsed",
                       "selectedItemID", "selectedTeacherKey" }) do
    Selectors:DefinePath("recipeSources." .. key, UI_PATH .. "." .. key)
end

Selectors:Register("recipeSources.isViewMode_recipe", {
    calls = { "recipeSources.viewMode" },
    fn = function(state, ctx) return Selectors:Call("recipeSources.viewMode", state, ctx) == "recipe" end,
})
Selectors:Register("recipeSources.isViewMode_teacher", {
    calls = { "recipeSources.viewMode" },
    fn = function(state, ctx) return Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher" end,
})

-- Per-preset booleans for the chips' `active` binding (generated from RS_PRESETS).
for _, p in ipairs(HDG.Constants.RS_PRESETS) do
    local value = p.value
    Selectors:Register("recipeSources.preset.active_" .. value, {
        calls = { "recipeSources.preset" },
        fn = function(state, ctx) return Selectors:Call("recipeSources.preset", state, ctx) == value end,
    })
end

-- ============================================================================
-- Recipe models: one per DecorDB recipe, its sources resolved to places
-- ============================================================================
-- place  = { key, name, nameEn, zone, zoneText, mapID, x, y, side ("A"/"H"/"N"), npcID, note, other }
--          key names the teacher: the NPC when there is one, else name + zone.
--          name / zoneText are what the player reads, in the client's language;
--          nameEn / zone are the data's English, and zone is the filter key.
--          other = a vendor or trainer of the opposite faction (shown dimmed, never visited).
-- source = { kind, label, who, zone, zoneText, side, places, generic, tier, costText,
--            costKeys, factionID, minRep, repName, questID, notes, other }
--          other = a vendor or named trainer whose one place is the opposite faction's;
--          a recipe lists those sources after the ones the player can use.

-- Is a place's side usable by the player? A nil code means no faction to judge by.
local function _isMine(side, code)
    if code == nil then return true end   -- exception(nullable): factionGroup is "" before SESSION_IDENTITY_SET and "Neutral" for an unaligned pandaren
    return side == "N" or side == code
end

local function _placeKey(npcID, name, zone)
    if npcID then return "npc:" .. npcID end
    return "at:" .. name .. "|" .. (zone or "")   -- exception(optional): drop/discovery sources name no zone
end

-- A zone in the client's language, for display (the English name stays the key).
local function _zoneText(zone)
    return zone and HDG.ZoneNameResolver:Localize(zone)   -- exception(optional): a drop names no zone
end

-- An NPC's name in the client's language; English until the client has it.
local function _npcName(npcID, nameEn)
    return (HDG.NPCNameResolver:ResolveName(npcID, nameEn))
end

-- A place's name as the player reads it: an NPC's in the client's language, anything else as
-- the data has it. The models keep English names, so a name arriving rebuilds only what shows
-- names (memory playbook, 2026-10-26: 1,566 KB a name offline). A selector calling this reads
-- session.npcNames.names (NPCNameResolver's facade contract).
local function _placeName(p)
    if p.npcID then return _npcName(p.npcID, p.nameEn) end
    return p.name
end

-- One models build shares its places and place lists across recipes: b = { code (the
-- player's faction code), places, lists, visits }. "Any Classic Alchemy trainer" on 20
-- recipes was 20 copies of every such trainer's place (529 place tables for 177 places;
-- memory playbook, 2026-10-26). Shared tables are read, never written, after the build.
-- Vendor and trainer keys stay apart: one NPC can be both, at two spots.
local function _sharedPlace(b, key, make)
    local place = b.places[key]
    if not place then
        place = make()
        b.places[key] = place
    end
    return place
end

local function _vendorPlace(npcID, b)
    return _sharedPlace(b, "v:" .. npcID, function()
        local v = HDG.StaticData.VendorAugment:Get(npcID)   -- strict: test_recipe_sources pins every vendor source into the augment
        return { key = _placeKey(npcID), name = v.name, nameEn = v.name,
                 zone = v.zone, zoneText = _zoneText(v.zone), mapID = v.mapID,
                 x = v.x, y = v.y, side = v.faction, npcID = npcID, note = v.note, other = not _isMine(v.faction, b.code) }
    end)
end

local function _trainerPlace(p, b)
    return _sharedPlace(b, "t:" .. p.npcID, function()
        return { key = _placeKey(p.npcID), name = p.name, nameEn = p.name,
                 zone = p.zone, zoneText = _zoneText(p.zone), x = p.x, y = p.y,
                 mapID = HDG.ZoneNameResolver.ZONE_MAP_IDS[p.zone],   -- exception(nullable): curated table; a zone it lacks maps nowhere
                 side = p.side, npcID = p.npcID, note = p.note, other = not _isMine(p.side, b.code) }
    end)
end

-- A named trainer's TrainersDB record. The build names trainers out of TrainersDB,
-- so a miss is drift between the two files.
local function _namedTrainer(places, npcID)
    for _, p in ipairs(places) do
        if p.npcID == npcID then return p end
    end
    error(("Recipe Sources: trainer %s is not in TrainersDB for its tier"):format(tostring(npcID)))
end

-- Places or sources, the player's faction's first and the other faction's after, each
-- in data order. Reorders the list in place.
local function _otherLast(items)
    local other, n = {}, 0
    for _, it in ipairs(items) do
        if it.other then other[#other + 1] = it else n = n + 1; items[n] = it end
    end
    for i, it in ipairs(other) do items[n + i] = it end
    return items
end

-- A tier's trainers, your faction's first, then the other faction's (dimmed): one list
-- per (profession, tier) for the build.
local function _anyTrainerPlaces(places, b, listKey)
    local list = b.lists[listKey]
    if list then return list end
    list = {}
    for _, p in ipairs(places) do list[#list + 1] = _trainerPlace(p, b) end
    b.lists[listKey] = _otherLast(list)
    return list
end

-- A shared list's places your faction can visit, filtered once for the build.
local function _visitList(b, list)
    local visit = b.visits[list]
    if visit then return visit end
    visit = {}
    for _, p in ipairs(list) do
        if not p.other then visit[#visit + 1] = p end
    end
    b.visits[list] = visit
    return visit
end

-- A source with one NPC takes that NPC's name, zone and side; its one-place list is shared.
local function _setSinglePlace(s, b, listKey, p)
    local list = b.lists[listKey]
    if not list then
        list = { p }
        b.lists[listKey] = list
    end
    s.places, s.who, s.zone, s.zoneText, s.side, s.other = list, p.name, p.zone, p.zoneText, p.side, p.other
end

local function _resolveTrainer(s, src, prof, b)
    local places = HDG.StaticData.Trainers:GetPlaces(prof, src.tier)
    if src.npcID then
        _setSinglePlace(s, b, "t:" .. src.npcID, _trainerPlace(_namedTrainer(places, src.npcID), b))
        return
    end
    s.generic = true
    s.places = _anyTrainerPlaces(places, b, prof .. "|" .. src.tier)
    s.visit = _visitList(b, s.places)
    s.who = HDG.Locale:Get("RS_ANY_TRAINER"):format(src.tier)
end

local function _resolveOther(s, src)
    s.who  = src.name or s.label   -- exception(optional): an auction-house source carries no name
    s.zone = src.zone              -- exception(optional): most drops name no zone
    s.zoneText = _zoneText(src.zone)
    s.places = { { key = _placeKey(nil, s.who, src.zone), name = s.who, nameEn = s.who,
                   zone = src.zone, zoneText = s.zoneText } }
end

-- Price keys (Format.CostKey) the source charges, for the Currency filter.
local function _costKeys(src)
    local keys = {}
    if src.copper then keys[HDG.Format.CostKey({ currencyID = HDG.Constants.CURRENCY_GOLD })] = true end  -- exception(optional): a source priced only in currencies or items has no copper
    for _, c in ipairs(src.currency or {}) do  -- exception(optional): a gold-only or free source has no currency list
        local e = (c[1] == "i") and { itemID = c[2] } or { currencyID = c[2] }
        keys[HDG.Format.CostKey(e)] = true
    end
    return keys
end

local function _buildSource(src, prof, b)
    local s = { kind = src.kind, label = _kindLabel(src.kind), tier = src.tier,
                costText = HDG.Format.FormatRecipeCost(src), costKeys = _costKeys(src),
                factionID = src.factionID, minRep = src.minRep, questID = src.questID, notes = src.notes }
    if src.factionID then  -- exception(optional): most sources carry no rep gate
        s.repName = HDG.Constants.REP_FACTIONS[src.factionID].name   -- strict: Phase 1 added every augment faction
    end
    if src.kind == "vendor" then
        _setSinglePlace(s, b, "v:" .. src.npcID, _vendorPlace(src.npcID, b))
    elseif src.kind == "trainer" then
        _resolveTrainer(s, src, prof, b)
    else
        _resolveOther(s, src)
    end
    return s
end

-- The places a source sends this player: none for the other faction's vendor or named
-- trainer, a generic trainer's own faction's only (filtered once, at the build). Callers
-- only read the list.
local NO_PLACES = {}
local function _visitPlaces(s)
    if s.other then return NO_PLACES end
    return s.visit or s.places   -- exception(optional): only a generic trainer source carries a visit list
end

-- A source's "who" as shown: a vendor's or named trainer's NPC by _placeName, else its label.
local function _sourceWho(s)
    if not s.generic and s.places[1].npcID then return _placeName(s.places[1]) end
    return s.who
end

-- "you" / "alt" / "none", from recipes.knowledge.
local function _knownState(knowledge, itemID)
    if knowledge.mine[itemID] then return "you" end
    if knowledge.alts[itemID] then return "alt" end
    return "none"
end

-- The state a list row shows for "you" / "none". An alt's state is drawn from the alts
-- themselves (recipes.knowledge's altChars: first name in its class color, "+N"), by the row factory,
-- which owns every color.
local KNOWN_SHORT = { you = "RS_KNOWN_YOU", none = "RS_KNOWN_NONE" }
local function _stateShort(known)
    if known == "alt" then return nil end
    return HDG.Locale:Get(KNOWN_SHORT[known])
end

-- The list row's "where": the first source's place (a generic trainer's first NPC
-- of your faction), plus how many more sources there are.
local function _whereText(m)
    local s = m.sources[1]
    if not s then return HDG.Locale:Get("RS_NO_SOURCE_SHORT") end
    if s.generic then
        local p = _visitPlaces(s)[1]
        if p then return _placeName(p) .. " - " .. p.zoneText end
        return HDG.Locale:Get("RS_TIER_TRAINER"):format(s.tier)
    end
    local extra = (#m.sources > 1) and (" +" .. (#m.sources - 1)) or ""
    local zone = s.zoneText and (" - " .. s.zoneText) or ""   -- exception(optional): a drop names no zone
    return _sourceWho(s) .. extra .. zone
end

-- The row's short price: the first source's first part, "+" when it has more.
local function _shortCost(m)
    local s = m.sources[1]
    if not s then return "" end
    local first = s.costText:match("^(.-)  %+  ")
    if first then return first .. " +" end
    return s.costText
end

local function _indexSource(m, s, words)
    m.kinds[s.kind] = true
    if s.repName then m.reps[s.repName] = true end
    for key in pairs(s.costKeys) do m.curs[key] = true end
    words[#words + 1] = s.who
    -- Search matches the English names here; recipeSources.npcSearch adds the client's.
    for _, p in ipairs(_visitPlaces(s)) do
        if p.zone then
            m.zones[p.zone] = true
            words[#words + 1] = p.zone
            words[#words + 1] = p.zoneText
        end
        words[#words + 1] = p.nameEn
    end
end

local function _indexModel(m)
    m.kinds, m.zones, m.reps, m.curs = {}, {}, {}, {}
    local words = { m.name, m.profession, m.expansion, m.notes or "" }   -- exception(optional): most recipes carry no notes
    for _, s in ipairs(m.sources) do _indexSource(m, s, words) end
    if #m.sources == 0 then m.kinds.none = true end
    m.kind = m.sources[1] and m.sources[1].kind or "none"
    m.shortCost = _shortCost(m)
    m.search = table.concat(words, " "):lower()
end

local function _buildModel(entry, b)
    local aug = HDG.StaticData.RecipeSources:Get(entry.itemID)   -- exception(nullable): a recipe the last harvest did not cover
    local m = { itemID = entry.itemID, spellID = entry.spellID, profession = entry.profession,
                name = HDG.Format.LocalItemName(entry.itemID, entry.name),
                expansion = HDG.Expansion.FromSkillLine(entry.expansion) or "?",   -- exception(nullable): an unrecognised skill line shows "?"
                skillLine = entry.expansion, sources = {} }
    if aug then
        m.skill, m.notes = aug.skill, aug.notes
        for _, src in ipairs(aug.sources) do
            m.sources[#m.sources + 1] = _buildSource(src, entry.profession, b)
        end
        _otherLast(m.sources)
    end
    _indexModel(m)
    return m
end

-- The trainers of the skill line each recipe needs, keyed "<profession>|<tier>": your
-- faction's and both factions', as a generic trainer source lists them in By Teacher.
-- label is the recipe's skill line ("Draenor Tailoring").
local function _tierTrainers(list, b)
    local out = {}
    for _, m in ipairs(list) do
        local key = m.profession .. "|" .. m.expansion
        if not out[key] then
            local places = HDG.StaticData.Trainers:GetPlaces(m.profession, m.expansion) or {}   -- exception(nullable): "?" or a tier TrainersDB lacks has no trainers
            local mine = _visitList(b, _anyTrainerPlaces(places, b, key))
            out[key] = { prof = m.profession, tier = m.expansion, label = m.skillLine, places = mine }
        end
    end
    return out
end

-- { list (by name), byItem, tierTrainers }. Rebuilt when item names or the faction change.
-- NPC names stay English here (_placeName resolves them where they show), and who knows a
-- recipe stays off the models too: the selectors that show it look it up in
-- recipes.knowledge, so learning a recipe no longer rebuilds all 346 (memory playbook: keep
-- the stable part memoized, add the volatile part on top; 1,740 KB a learn offline).
Selectors:Register("recipeSources.models", {
    memoized = true,
    reads = { "session.resolvers.staticData.tick", "session.itemNames.names", "session.identity.factionGroup" },
    fn = function(state)
        local code  = SIDE_CODE[state.session.identity.factionGroup]   -- exception(nullable): "" before identity, "N" unaligned
        local b = { code = code, places = {}, lists = {}, visits = {} }
        local list, byItem = {}, {}
        for _, entry in pairs(HDG.StaticData.Recipes:GetAll()) do
            if entry.itemID then
                local m = _buildModel(entry, b)
                list[#list + 1] = m
                byItem[m.itemID] = m
            end
        end
        table.sort(list, _byName)
        return { list = list, byItem = byItem, tierTrainers = _tierTrainers(list, b) }
    end,
})

-- The names a recipe's NPCs go by in the client's language where they differ from the
-- English ones the models search, lowercased; nil when none differ (every name on an English
-- client). Names arrive after the models are built, so they are searched on top.
local function _localNames(m)
    local words = {}
    for _, s in ipairs(m.sources) do
        for _, p in ipairs(_visitPlaces(s)) do
            local shown = p.npcID and _npcName(p.npcID, p.nameEn)
            if shown and shown ~= p.nameEn then words[#words + 1] = shown end
        end
    end
    if #words == 0 then return nil end
    return table.concat(words, " "):lower()
end

Selectors:Register("recipeSources.npcSearch", {
    memoized = true,
    reads = { "session.npcNames.names" },
    calls = { "recipeSources.models" },
    fn = function(state, ctx)
        local out = {}
        for _, m in ipairs(Selectors:Call("recipeSources.models", state, ctx).list) do out[m.itemID] = _localNames(m) end
        return out
    end,
})

-- ============================================================================
-- Filtering
-- ============================================================================

local function _otherKind(m)
    for kind in pairs(m.kinds) do
        if kind ~= "trainer" and kind ~= "vendor" then return true end
    end
    return false
end

local PRESET_PASS = {
    all       = function() return true end,
    unlearned = function(m, K) return _knownState(K, m.itemID) == "none" end,
    trainer   = function(m) return m.kinds.trainer == true end,
    vendor    = function(m) return m.kinds.vendor == true end,
    other     = _otherKind,
    rep       = function(m) return next(m.reps) ~= nil end,
}

local function _anyIn(set, values)
    if next(set) == nil then return true end
    for v in pairs(values) do
        if set[v] then return true end
    end
    return false
end

-- The player's scanned professions by English name, for the "mine" member of the set.
local function _myProfessions(state)
    local char = state.account.characters[state.session.identity.charKey]   -- exception(nullable): char record may not exist yet
    if not char then return {} end
    return HDG.Profession.NamesOf(char)
end

local function _profPass(m, set, mine)
    if next(set) == nil then return true end
    return set[m.profession] == true or (set.mine == true and mine[m.profession] == true)
end

-- The search box: the model's English words, then the NPC names it goes by in the client's
-- language (recipeSources.npcSearch, nil where none differ).
local function _queryPass(m, f)
    if f.query == "" or m.search:find(f.query, 1, true) then return true end
    local localNames = f.npcSearch[m.itemID]   -- exception(nullable): no NPC of this recipe has a name of its own here
    return localNames ~= nil and localNames:find(f.query, 1, true) ~= nil
end

local function _passes(m, f)
    return f.preset(m, f.known) and _profPass(m, f.prof, f.mine)
        and (next(f.exp) == nil or f.exp[m.expansion] == true)
        and _anyIn(f.src, m.kinds) and _anyIn(f.zone, m.zones)
        and _anyIn(f.rep, m.reps) and _anyIn(f.cur, m.curs)
        and _queryPass(m, f)
end

local function _filterSpec(state, ctx)
    local ui = state.session.ui.recipeSources
    return { preset = PRESET_PASS[ui.preset], known = Selectors:Call("recipes.knowledge", state, ctx),
             npcSearch = Selectors:Call("recipeSources.npcSearch", state, ctx),
             prof = ui.profFilter, mine = _myProfessions(state),
             exp = ui.expFilter, src = ui.srcFilter, zone = ui.zoneFilter, rep = ui.repFilter,
             cur = ui.curFilter, query = ui.searchQuery:lower() }
end

Selectors:Register("recipeSources.filtered", {
    memoized = true,
    reads = { UI_PATH .. ".preset", UI_PATH .. ".searchQuery", UI_PATH .. ".profFilter",
              UI_PATH .. ".expFilter", UI_PATH .. ".srcFilter", UI_PATH .. ".zoneFilter",
              UI_PATH .. ".repFilter", UI_PATH .. ".curFilter",
              "account.characters.*.professions", "session.identity.charKey" },
    calls = { "recipeSources.models", "recipes.knowledge", "recipeSources.npcSearch" },
    fn = function(state, ctx)
        local f, out = _filterSpec(state, ctx), {}
        for _, m in ipairs(Selectors:Call("recipeSources.models", state, ctx).list) do
            if _passes(m, f) then out[#out + 1] = m end
        end
        return out
    end,
})

-- ============================================================================
-- By Recipe rows
-- ============================================================================

-- [profession] = { known, total } over every recipe, for the group headers.
Selectors:Register("recipeSources.profStats", {
    memoized = true,
    calls = { "recipeSources.models", "recipes.knowledge" },
    fn = function(state, ctx)
        local out, K = {}, Selectors:Call("recipes.knowledge", state, ctx)
        for _, m in ipairs(Selectors:Call("recipeSources.models", state, ctx).list) do
            local s = out[m.profession] or { known = 0, total = 0 }
            s.total = s.total + 1
            if _knownState(K, m.itemID) ~= "none" then s.known = s.known + 1 end
            out[m.profession] = s
        end
        return out
    end,
})

local function _groupByProfession(models)
    local groups, order = {}, {}
    for _, m in ipairs(models) do
        if not groups[m.profession] then
            groups[m.profession] = {}
            order[#order + 1] = m.profession
        end
        table.insert(groups[m.profession], m)
    end
    table.sort(order)
    return groups, order
end

-- ----- List row reuse -----
-- List rows are reused across rebuilds, one table per row key: a keystroke or filter click
-- stamped a fresh table for every row (memory playbook, 2026-10-26: 162 KB a push offline).
-- A deliberate exception to selector purity, as Decor's rows: a rebuild restamps the rows
-- the previous result holds. Safe because nothing keeps an older result -- the list refills
-- from the new array, new on every compute, so `_sameItems` still sees the change. The cache
-- is a memo rather than a file-level table: the window's close wipes every memo, so the whole
-- cache goes (a weak file-level table keeps its hash part).
Selectors:Register("recipeSources._rowCache", {
    memoized = true,
    reads = {},
    fn = function() return {} end,
})

-- Writes v, but never nil over a field the row doesn't have: in WoW's Lua 5.1 that inserts
-- the key (memory playbook, trap 4).
local function _put(row, k, v)
    if v ~= nil or rawget(row, k) ~= nil then row[k] = v end
end

-- The cached row for key, cleared of SelectionBehavior's flag (the selection sync sets it
-- again after the refill).
local function _rowFor(cache, key)
    local row = cache[key]
    if not row then
        row = {}
        cache[key] = row
    end
    _put(row, "selected", nil)
    return row
end

local function _recipeRow(cache, m, K)
    local row, known = _rowFor(cache, m.itemID), _knownState(K, m.itemID)
    row.kind, row.itemID, row.name, row.known = "recipe", m.itemID, m.name, known
    _put(row, "stateShort", _stateShort(known))
    _put(row, "alts", K.altChars[m.itemID])   -- exception(nullable): no alt knows it
    row.chipKind, row.chipLabel, row.where, row.cost = m.kind, _kindLabel(m.kind), _whereText(m), m.shortCost
    return row
end

local function _profHeaderRow(cache, prof, shown, stat, collapsed)
    local key = "P:" .. prof
    local row = _rowFor(cache, key)
    row.kind, row.key, row.profession, row.shown = "profHeader", key, prof, shown
    _put(row, "atlas", HDG.Format.ProfessionAtlas(prof))
    row.known, row.total, row.collapsed = stat.known, stat.total, collapsed
    return row
end

Selectors:Register("recipeSources.recipeRows", {
    memoized = true,
    reads = { UI_PATH .. ".collapsed", "session.npcNames.names" },
    calls = { "recipeSources.filtered", "recipeSources.profStats", "recipeSources._rowCache", "recipes.knowledge" },
    fn = function(state, ctx)
        local cache = Selectors:Call("recipeSources._rowCache", state, ctx)
        local K = Selectors:Call("recipes.knowledge", state, ctx)
        local stats = Selectors:Call("recipeSources.profStats", state, ctx)
        local collapsed = state.session.ui.recipeSources.collapsed
        local groups, order = _groupByProfession(Selectors:Call("recipeSources.filtered", state, ctx))
        local out = {}
        for _, prof in ipairs(order) do
            local folded = collapsed["P:" .. prof] == true
            out[#out + 1] = _profHeaderRow(cache, prof, #groups[prof], stats[prof], folded)
            if not folded then
                for _, m in ipairs(groups[prof]) do out[#out + 1] = _recipeRow(cache, m, K) end
            end
        end
        return out
    end,
})

-- ============================================================================
-- Teachers (By Teacher list + teacher detail)
-- ============================================================================
-- teacher = { key, who, zone, mapID, x, y, side, npcID, kind, isNpc, recipes, exps, tiers, skillLines }
--   recipes = { { model, source } } (one per recipe), tiers = the (profession, tier)
--   pairs a trainer serves, for its alts-needing-training line. skillLines = the
--   skill lines a trainer is listed for, for one who teaches no decor recipe.

local function _newTeacher(place, kind)
    return { key = place.key, who = _placeName(place), zone = place.zone, zoneText = place.zoneText, mapID = place.mapID,
             x = place.x, y = place.y, side = place.side, npcID = place.npcID, note = place.note, kind = kind,
             isNpc = kind == "vendor" or kind == "trainer",
             recipes = {}, seen = {}, exps = {}, tiers = {}, skillLines = {} }
end

local function _teacherAt(acc, place, kind)
    local t = acc.byKey[place.key]
    if not t then
        t = _newTeacher(place, kind)
        acc.byKey[place.key] = t
        acc.list[#acc.list + 1] = t
    end
    return t
end

local function _addTeacher(acc, place, s, m)
    local t = _teacherAt(acc, place, s.kind)
    if not t.seen[m.itemID] then
        t.seen[m.itemID] = true
        t.recipes[#t.recipes + 1] = { model = m, source = s }
    end
    t.exps[m.expansion] = true
    if s.kind == "trainer" then t.tiers[m.profession .. "|" .. s.tier] = { prof = m.profession, tier = s.tier } end
end

-- A trainer of a skill line some recipe needs (Vamoose, 2026-10-26): listed even when
-- they teach no decor recipe (the vendor-sold Draenor recipes need Draenor Tailoring).
-- The tier joins their alts-needing-training line; it groups only a trainer listed for
-- the skill line alone, so a decor teacher keeps the group its recipes give it.
local function _addSkillLineTrainer(acc, place, tt)
    local t = _teacherAt(acc, place, "trainer")
    t.tiers[tt.prof .. "|" .. tt.tier] = { prof = tt.prof, tier = tt.tier }
    t.skillLines[tt.label] = tt.tier
end

local function _addSkillLineTrainers(acc, models, tierTrainers)
    local needed = {}
    for _, m in ipairs(models) do needed[m.profession .. "|" .. m.expansion] = true end
    for key in pairs(needed) do
        for _, p in ipairs(tierTrainers[key].places) do _addSkillLineTrainer(acc, p, tierTrainers[key]) end
    end
    for _, t in ipairs(acc.list) do
        if #t.recipes == 0 then
            for _, tier in pairs(t.skillLines) do t.exps[tier] = true end
        end
    end
end

local function _collectTeachers(models, tierTrainers)
    local acc = { list = {}, byKey = {} }
    for _, m in ipairs(models) do
        for _, s in ipairs(m.sources) do
            for _, p in ipairs(_visitPlaces(s)) do _addTeacher(acc, p, s, m) end
        end
    end
    _addSkillLineTrainers(acc, models, tierTrainers)
    return acc
end

-- Every teacher across all recipes: the teacher detail lists all they teach.
Selectors:Register("recipeSources.allTeachers", {
    memoized = true,
    reads = { "session.npcNames.names" },
    calls = { "recipeSources.models" },
    fn = function(state, ctx)
        local models = Selectors:Call("recipeSources.models", state, ctx)
        return _collectTeachers(models.list, models.tierTrainers)
    end,
})

-- The teachers of the filtered recipes (the By Teacher list).
Selectors:Register("recipeSources.teachers", {
    memoized = true,
    reads = { "session.npcNames.names" },
    calls = { "recipeSources.filtered", "recipeSources.models" },
    fn = function(state, ctx)
        return _collectTeachers(Selectors:Call("recipeSources.filtered", state, ctx),
            Selectors:Call("recipeSources.models", state, ctx).tierTrainers)
    end,
})

-- An NPC groups under the newest expansion it serves; places with no one to visit
-- (drops, treasures, discoveries) under OTHER_GROUP.
local function _teacherGroup(t)
    if not t.isNpc then return OTHER_GROUP end
    local best, bestIdx = "?", -1
    for exp in pairs(t.exps) do
        local idx = HDG.Expansion.GetIndex(exp) or 0   -- exception(nullable): "?" has no index
        if idx > bestIdx then best, bestIdx = exp, idx end
    end
    return best
end

local function _groupRank(group)
    if group == OTHER_GROUP then return -1 end
    return HDG.Expansion.GetIndex(group) or 0   -- exception(nullable): "?" has no index
end

local function _toLearn(t, K)
    local n = 0
    for _, r in ipairs(t.recipes) do
        if _knownState(K, r.model.itemID) == "none" then n = n + 1 end
    end
    return n
end

-- ============================================================================
-- Trainer extras: the alts needing training and the top decor crafter
-- ============================================================================

-- A profession's decor recipe count: its cells' totals (alts.decorRecipeIndex) summed.
local function _sumProfBucketTotal(profBucket)
    local total = 0
    for _, cell in pairs(profBucket) do total = total + cell.total end
    return total
end

-- Known decor recipes for one (char, prof) across the profBucket cells.
local function _countCharKnownInProfBucket(char, profID, profBucket)
    local prof = HDG.Profession.RecordOf(char, profID)
    if not (prof and prof.knownRecipes) then return 0 end   -- exception(nullable): a character without this profession, or one with no scanned recipes
    local known = 0
    for recipeID in pairs(prof.knownRecipes) do
        for _, cell in pairs(profBucket) do
            if cell.recipeSet[recipeID] then
                known = known + 1
                break
            end
        end
    end
    return known
end

-- Who the trainer extras count: hidden alts don't; the character being played does even
-- when hidden, as recipes.knowledge counts its recipes (Vamoose, 2026-10-26).
local function _counts(charKey, char, myKey)
    return not char.hidden or charKey == myKey
end

-- The character knowing the most decor recipes of a profession: (name, knownCount).
local function _findTopCrafterForProf(chars, profID, profBucket, myKey)
    local bestName, bestKnown, bestClass = nil, -1, nil
    for charKey, char in pairs(chars) do
        if _counts(charKey, char, myKey) then
            local known = _countCharKnownInProfBucket(char, profID, profBucket)
            if known > bestKnown then
                bestKnown, bestClass = known, char.classFile
                bestName  = char.name or charKey   -- exception(nullable): a record with no name goes by its key
            end
        end
    end
    return bestName, bestKnown, bestClass
end

-- Top decor crafter per profession: [profName] = { charName, classFile, knownCount, totalCount }.
Selectors:Register("recipeSources.topDecorCrafterByProf", {
    -- One field each of the roster: a reagent or essence snapshot keeps the memo.
    reads = { "account.characters.*.professions", "account.characters.*.hidden", "account.characters.*.name",
              "account.characters.*.classFile", "session.identity.charKey", "session.resolvers.staticData.tick" },
    calls = { "alts.decorRecipeIndex" },
    fn = function(state, ctx)
        local out = {}
        local index = Selectors:Call("alts.decorRecipeIndex", state, ctx)
        local chars, myKey = state.account.characters, state.session.identity.charKey
        for profName, profBucket in pairs(index) do
            local total = _sumProfBucketTotal(profBucket)
            local profID = HDG.Profession.GetByName(profName).id
            local bestName, bestKnown, bestClass = _findTopCrafterForProf(chars, profID, profBucket, myKey)
            if total > 0 and bestName and bestKnown > 0 then
                out[profName] = { charName = bestName, classFile = bestClass, knownCount = bestKnown, totalCount = total }
            end
        end
        return out
    end,
})

-- A char's skill line: the normalized alias first (recipes DB), then the raw expansion name.
local function _charSkillLine(char, profID, expAlias, expName)
    local prof = HDG.Profession.RecordOf(char, profID)
    if not (prof and prof.skillLines) then return nil end   -- exception(nullable): a character without this profession, or one never scanned
    return prof.skillLines[expAlias] or prof.skillLines[expName]   -- exception(nullable): either key, or no line for this tier
end

-- Undertrained = progressed past 0 but not yet capped.
local function _isCharUndertrained(sl)
    return sl and sl.current and sl.max   -- exception(nullable): no skill line, or one without a range
        and sl.current > 0 and sl.current < sl.max
end

-- Undertrained chars for one (profession, expansion): { charName, current, max }[].
-- Counted by the top crafter's rule: hidden alts are left out.
local function _collectUndertrainedChars(chars, profID, expName, myKey)
    local list = {}
    local expAlias = HDG.Expansion.NormalizeAlias(expName) or expName   -- exception(nullable): a TrainersDB tier with no alias
    for charKey, char in pairs(chars) do
        local sl = _counts(charKey, char, myKey) and _charSkillLine(char, profID, expAlias, expName)
        if _isCharUndertrained(sl) then
            list[#list + 1] = { charName = char.name or charKey, classFile = char.classFile, current = sl.current, max = sl.max }   -- exception(nullable): a record with no name goes by its key
        end
    end
    return list
end

-- Chars needing training per (profession, TrainersDB tier): [profName][expName] = list.
Selectors:Register("recipeSources.charsNeedingByProfExp", {
    -- One field each of the roster: a reagent or essence snapshot keeps the memo.
    reads = { "account.characters.*.professions", "account.characters.*.hidden", "account.characters.*.name",
              "account.characters.*.classFile", "session.identity.charKey", "session.resolvers.staticData.tick" },
    fn = function(state)
        local out   = {}
        local chars, myKey = state.account.characters, state.session.identity.charKey
        for profName, profData in pairs(HDG.StaticData.Trainers:GetAll()) do
            local profID, byExp = HDG.Profession.GetByName(profName).id, {}
            for expName in pairs(profData) do
                local list = _collectUndertrainedChars(chars, profID, expName, myKey)
                if #list > 0 then byExp[expName] = list end
            end
            if next(byExp) then out[profName] = byExp end
        end
        return out
    end,
})

-- Alts below cap on any (profession, tier) this trainer serves, deduped by name.
local function _charsNeeding(t, needsBy)
    local out, seen = {}, {}
    for _, pt in pairs(t.tiers) do
        local byExp = needsBy[pt.prof]   -- exception(nullable): no alt below cap in this profession
        for _, c in ipairs(byExp and byExp[pt.tier] or {}) do   -- exception(nullable): none below cap at this tier
            if not seen[c.charName] then seen[c.charName] = true; out[#out + 1] = c end
        end
    end
    table.sort(out, function(a, b) return a.charName < b.charName end)
    return out
end

-- A line naming characters: { text, parts }. The Locale string is formatted with NAME
-- where each name goes, then split, so a translation keeps its own word order. `text` is
-- the plain line; `parts` the same line in pieces for the row factory -- a string in the
-- row's color, { name, classFile } in that character's class color.
local NAME = "\1"
local function _named(formatted, who)
    local parts, plain, k = {}, {}, 0
    for piece in (formatted .. NAME):gmatch("(.-)" .. NAME) do
        if piece ~= "" then parts[#parts + 1], plain[#plain + 1] = piece, piece end
        k = k + 1
        if who[k] then parts[#parts + 1], plain[#plain + 1] = who[k], who[k].name end   -- exception(nullable): the piece after the last name
    end
    return { text = table.concat(plain), parts = parts }
end

-- "Needs training: Gyl 40/100, Ann 12/75 +2" -- up to `cap` alts named.
local function _needsText(needs, cap)
    if #needs == 0 then return nil end
    local pieces, who = {}, {}
    for i = 1, math.min(#needs, cap) do
        pieces[i] = NAME .. string.format(" %d/%d", needs[i].current, needs[i].max)
        who[i] = { name = needs[i].charName, classFile = needs[i].classFile }
    end
    local more = (#needs > cap) and (" +" .. (#needs - cap)) or ""
    return _named(HDG.Locale:Get("RS_NEEDS_TRAINING"):format(table.concat(pieces, ", ") .. more), who)
end

local function _topText(t, topByProf)
    for _, pt in pairs(t.tiers) do
        local top = topByProf[pt.prof]   -- exception(nullable): nobody on the account crafts this profession's decor
        if top then
            return _named(HDG.Locale:Get("RS_TOP_CRAFTER"):format(pt.prof, NAME, top.knownCount, top.totalCount),
                { { name = top.charName, classFile = top.classFile } })
        end
    end
    return nil
end

-- A trainer's extras: the alts needing training and the account's top decor
-- crafter. nil for vendors and the rest.
local ROW_NEEDS_CAP = 3   -- alts named on a list row; the detail names them all

local function _trainerExtras(t, needsBy, topByProf, cap)
    if next(t.tiers) == nil then return nil, nil end
    local needs = _charsNeeding(t, needsBy)
    return _needsText(needs, cap or #needs), _topText(t, topByProf)   -- exception(optional): no cap = every alt
end

-- A row shows only the alts needing training. The top crafter counts the whole
-- profession, not this trainer's recipes, so it repeated on every trainer of that
-- profession and read like a count for the trainer (Vamoose, 2026-10-25): it sits in
-- the teacher detail alone.
-- A trainer listed for skill lines alone: "Draenor Tailoring", oldest tier first.
local function _skillLineText(t)
    local labels = {}
    for label in pairs(t.skillLines) do labels[#labels + 1] = label end
    table.sort(labels, function(a, b)
        local ia, ib = HDG.Expansion.GetIndex(t.skillLines[a]), HDG.Expansion.GetIndex(t.skillLines[b])
        if ia ~= ib then return ia < ib end
        return a < b
    end)
    return table.concat(labels, ", ")
end

-- "teaches N" counts decor recipes; a trainer who teaches none names the skill line
-- instead, so the row claims no decor recipe (Vamoose, 2026-10-26).
local function _teachesText(t)
    if #t.recipes > 0 then return HDG.Locale:Get("RS_TEACHES_N"):format(#t.recipes) end
    return HDG.Locale:Get("RS_TEACHES_SKILL"):format(_skillLineText(t))
end

local function _teacherRow(cache, t, needsBy, topByProf, K)
    local needs = _trainerExtras(t, needsBy, topByProf, ROW_NEEDS_CAP)
    local row = _rowFor(cache, "t:" .. t.key)
    row.kind, row.key, row.who, row.toLearn = "teacher", t.key, t.who, _toLearn(t, K)
    _put(row, "side", t.side)
    row.chipKind, row.chipLabel = t.kind, _kindLabel(t.kind)
    row.zone = t.zoneText or HDG.Locale:Get("RS_ANYWHERE")   -- exception(optional): a drop names no zone
    row.missing, row.teaches, row.skillOnly = t.isNpc and not t.x, #t.recipes, #t.recipes == 0
    row.teachesText = _teachesText(t)
    _put(row, "extra", needs and needs.text)
    _put(row, "extraParts", needs and needs.parts)
    return row
end

local function _groupTeachers(list)
    local groups, order = {}, {}
    for _, t in ipairs(list) do
        local g = _teacherGroup(t)
        if not groups[g] then groups[g] = {}; order[#order + 1] = g end
        table.insert(groups[g], t)
    end
    table.sort(order, function(a, b) return _groupRank(a) > _groupRank(b) end)
    for _, g in pairs(groups) do
        table.sort(g, function(a, b)
            if (a.zoneText or "~") ~= (b.zoneText or "~") then return (a.zoneText or "~") < (b.zoneText or "~") end   -- exception(optional): zone-less places sort last
            return a.who < b.who
        end)
    end
    return groups, order
end

local function _groupHeader(cache, g, n, collapsed)
    local row = _rowFor(cache, "T:" .. g)
    row.kind, row.key, row.collapsed = "expHeader", "T:" .. g, collapsed
    row.count = HDG.Locale:Get("RS_N_TEACHERS"):format(n)
    if g == OTHER_GROUP then
        row.label = HDG.Locale:Get("RS_GROUP_OTHER")
        _put(row, "color", nil)
    else
        row.label = g
        _put(row, "color", HDG.Expansion.GetColorHex(g))   -- exception(nullable): "?" has no brand color
    end
    return row
end

Selectors:Register("recipeSources.teacherRows", {
    memoized = true,
    reads = { UI_PATH .. ".collapsed", "session.resolvers.staticData.tick" },
    calls = { "recipeSources.teachers", "recipeSources.charsNeedingByProfExp", "recipeSources.topDecorCrafterByProf",
              "recipeSources._rowCache", "recipes.knowledge" },
    fn = function(state, ctx)
        local cache     = Selectors:Call("recipeSources._rowCache", state, ctx)
        local K         = Selectors:Call("recipes.knowledge", state, ctx)
        local needsBy   = Selectors:Call("recipeSources.charsNeedingByProfExp", state, ctx)
        local topByProf = Selectors:Call("recipeSources.topDecorCrafterByProf", state, ctx)
        local collapsed = state.session.ui.recipeSources.collapsed
        local groups, order = _groupTeachers(Selectors:Call("recipeSources.teachers", state, ctx).list)
        local out = {}
        for _, g in ipairs(order) do
            out[#out + 1] = _groupHeader(cache, g, #groups[g], collapsed["T:" .. g] == true)
            if not collapsed["T:" .. g] then
                for _, t in ipairs(groups[g]) do out[#out + 1] = _teacherRow(cache, t, needsBy, topByProf, K) end
            end
        end
        return out
    end,
})

-- ============================================================================
-- Header: counts, Map N places, blank states
-- ============================================================================

Selectors:Register("recipeSources.countLabel", {
    calls = { "recipeSources.viewMode", "recipeSources.filtered", "recipeSources.models", "recipeSources.teachers" },
    fn = function(state, ctx)
        local n = #Selectors:Call("recipeSources.filtered", state, ctx)
        if Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher" then
            local t = #Selectors:Call("recipeSources.teachers", state, ctx).list
            return HDG.Locale:Get("RS_COUNT_TEACHERS"):format(t, n)
        end
        local total = #Selectors:Call("recipeSources.models", state, ctx).list
        return HDG.Locale:Get("RS_COUNT_RECIPES"):format(n, total)
    end,
})

-- A model's places with a location, each once across the list: visit(mapID, x, y, place).
local function _visitModelPlaces(m, seen, visit)
    for _, s in ipairs(m.sources) do
        for _, p in ipairs(_visitPlaces(s)) do
            if p.mapID and p.x and not seen[p.key] then
                seen[p.key] = true
                visit(p.mapID, p.x, p.y, p)
            end
        end
    end
end

-- Every place the shown list can pin, once each. By Teacher's teachers are one per place
-- already. One walk for the Map button (the records) and its label (a count): the label
-- shows on every filter change, and building a record per place just to count them was
-- 361 KB a By Teacher push offline (memory playbook, 2026-10-26).
local MAPPABLE_CALLS = { "recipeSources.viewMode", "recipeSources.filtered", "recipeSources.teachers" }
local function _eachMappable(state, ctx, visit)
    if Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher" then
        for _, t in ipairs(Selectors:Call("recipeSources.teachers", state, ctx).list) do
            if t.mapID and t.x then visit(t.mapID, t.x, t.y, nil, t.who) end
        end
        return
    end
    local seen = {}
    for _, m in ipairs(Selectors:Call("recipeSources.filtered", state, ctx)) do _visitModelPlaces(m, seen, visit) end
end

-- What "Map N places" pins (the Map button's click): a place's name resolved here, a
-- teacher's already.
Selectors:Register("recipeSources.mapPlaces", {
    reads = { "session.npcNames.names" },
    calls = MAPPABLE_CALLS,
    fn = function(state, ctx)
        local out = {}
        _eachMappable(state, ctx, function(mapID, x, y, place, who)
            out[#out + 1] = { mapID = mapID, x = x, y = y, name = who or _placeName(place) }
        end)
        return out
    end,
})

Selectors:Register("recipeSources.mapAllLabel", {
    calls = MAPPABLE_CALLS,
    fn = function(state, ctx)
        local n = 0
        _eachMappable(state, ctx, function() n = n + 1 end)
        local key = (Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher")
            and "RS_MAP_TEACHERS" or "RS_MAP_PLACES"
        return HDG.Locale:Get(key):format(n)
    end,
})

Selectors:Register("recipeSources.hasResults", {
    calls = { "recipeSources.filtered" },
    fn = function(state, ctx) return #Selectors:Call("recipeSources.filtered", state, ctx) > 0 end,
})
Selectors:Register("recipeSources.isBlank", {
    calls = { "recipeSources.hasResults" },
    fn = function(state, ctx) return not Selectors:Call("recipeSources.hasResults", state, ctx) end,
})
Selectors:Register("recipeSources.blankText", {
    calls = { "recipeSources.viewMode" },
    fn = function(state, ctx)
        local teacher = Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher"
        return HDG.Locale:Get(teacher and "RS_BLANK_TEACHERS" or "RS_BLANK_RECIPES")
    end,
})

-- ============================================================================
-- Filter menus, tags, Here
-- ============================================================================
-- One walk over every recipe counts each axis value (the menus show counts across
-- all recipes, as the mockup does) and names the currency keys.

local function _countInto(counts, values)
    for v in pairs(values) do counts[v] = (counts[v] or 0) + 1 end
end

local function _curName(key)
    local kind, id = key:match("^(%a+):(%-?%d+)$")
    local e = (kind == "item") and { itemID = tonumber(id) } or { currencyID = tonumber(id) }
    return HDG.Format.CostName(e) or ("Currency #" .. id)   -- exception(nullable): a currency neither the curated table nor the client knows shows its id
end

Selectors:Register("recipeSources.axisCounts", {
    memoized = true,
    reads = { "session.itemNames.names" },
    calls = { "recipeSources.models" },
    fn = function(state, ctx)
        local c = { exp = {}, src = {}, zone = {}, rep = {}, cur = {}, curNames = {}, zoneNames = {} }
        for _, m in ipairs(Selectors:Call("recipeSources.models", state, ctx).list) do
            c.exp[m.expansion] = (c.exp[m.expansion] or 0) + 1
            _countInto(c.src, m.kinds)
            _countInto(c.zone, m.zones)
            _countInto(c.rep, m.reps)
            _countInto(c.cur, m.curs)
        end
        for key in pairs(c.cur) do c.curNames[key] = _curName(key) end
        for zone in pairs(c.zone) do c.zoneNames[zone] = HDG.ZoneNameResolver:Localize(zone) end
        return c
    end,
})

-- The count rides in `right`: the dropdown lines it up in a column under the header.
local function _menuItem(value, text, n)
    return { kind = "checkbox", value = value, text = text, right = tostring(n) }
end

local function _sortedMenu(counts, labels)
    local vals = {}
    for v in pairs(counts) do vals[#vals + 1] = v end
    table.sort(vals, function(a, b) return (labels[a] or a) < (labels[b] or b) end)   -- exception(nullable): only currencies and zones carry display labels
    local out = {}
    for _, v in ipairs(vals) do out[#out + 1] = _menuItem(v, labels[v] or v, counts[v]) end   -- exception(nullable): only currencies and zones carry display labels
    return out
end

local function _expMenu(counts)
    local out = {}
    for _, e in HDG.Expansion.Each() do
        local n = counts[e.display]   -- exception(nullable): an expansion with no decor recipe is left out
        if n then out[#out + 1] = _menuItem(e.display, HDG.Expansion.GetColorHex(e.display) .. e.display .. "|r", n) end
    end
    return out
end

local function _srcMenu(counts)
    local out = {}
    for _, kind in ipairs(KIND_ORDER) do
        local n = counts[kind]   -- exception(nullable): a kind no recipe has is left out
        if n then out[#out + 1] = _menuItem(kind, _kindLabel(kind), n) end
    end
    return out
end

local AXIS_MENU = {
    exp  = function(c) return _expMenu(c.exp) end,
    src  = function(c) return _srcMenu(c.src) end,
    zone = function(c) return _sortedMenu(c.zone, c.zoneNames) end,
    rep  = function(c) return _sortedMenu(c.rep, {}) end,
    cur  = function(c) return _sortedMenu(c.cur, c.curNames) end,
}
local AXES = HDG.Constants.RS_FILTER_AXES

for _, a in ipairs(AXES) do
    if a.all then
        Selectors:Register("recipeSources." .. a.axis .. "MenuItems", {
            calls = { "recipeSources.axisCounts" },
            fn = function(state, ctx)
                local out = {
                    { kind = "checkbox", isAll = true, value = "all", text = HDG.Locale:Get(a.all) },
                    { kind = "divider" },
                    { kind = "title", text = HDG.Locale:Get(a.head), right = HDG.Locale:Get("RS_HEAD_RECIPES") },
                }
                for _, item in ipairs(AXIS_MENU[a.axis](Selectors:Call("recipeSources.axisCounts", state, ctx))) do
                    out[#out + 1] = item
                end
                return out
            end,
        })
    end
end

-- A filter value's display label in a tag.
local function _tagValueLabel(axis, v, counts)
    if axis == "prof" and v == "mine" then return HDG.Locale:Get("RS_MY_PROFESSIONS") end
    if axis == "src" then return _kindLabel(v) end
    if axis == "cur" then return counts.curNames[v] or _curName(v) end   -- exception(nullable): a picked currency no recipe still charges
    if axis == "zone" then return HDG.ZoneNameResolver:Localize(v) end
    return v
end

-- "Zone: The Azure Span, Valdrakken  [x]" -- up to three values, then "+N".
local function _tagText(a, set, counts)
    local vals = {}
    for v in pairs(set) do vals[#vals + 1] = _tagValueLabel(a.axis, v, counts) end
    table.sort(vals)
    local shown = { unpack(vals, 1, math.min(#vals, 3)) }
    local more = (#vals > 3) and (" +" .. (#vals - 3)) or ""
    return HDG.Locale:Get(a.tag):format(table.concat(shown, ", ") .. more)
end

for _, a in ipairs(AXES) do
    local stateName = "recipeSources." .. a.set
    Selectors:Register("recipeSources.has_" .. a.axis, {
        calls = { stateName },
        fn = function(state, ctx) return next(Selectors:Call(stateName, state, ctx)) ~= nil end,
    })
    Selectors:Register("recipeSources.tag_" .. a.axis, {
        calls = { stateName, "recipeSources.axisCounts" },
        fn = function(state, ctx)
            local set = Selectors:Call(stateName, state, ctx)
            if next(set) == nil then return "" end
            return _tagText(a, set, Selectors:Call("recipeSources.axisCounts", state, ctx))
        end,
    })
end

-- The preset narrows the list like a filter, so it gets a tag too: with "Not learned"
-- on and everything learned, the list read empty with no tag to say why (Vamoose,
-- 2026-10-25). The click sets it back to All.
local PRESET_LABEL = {}
for _, p in ipairs(HDG.Constants.RS_PRESETS) do PRESET_LABEL[p.value] = p.key end

Selectors:Register("recipeSources.has_preset", {
    calls = { "recipeSources.preset" },
    fn = function(state, ctx) return Selectors:Call("recipeSources.preset", state, ctx) ~= "all" end,
})
Selectors:Register("recipeSources.tag_preset", {
    calls = { "recipeSources.preset" },
    fn = function(state, ctx)
        local preset = Selectors:Call("recipeSources.preset", state, ctx)
        if preset == "all" then return "" end
        return HDG.Locale:Get("RS_TAG_PRESET"):format(HDG.Locale:Get(PRESET_LABEL[preset]))
    end,
})

Selectors:Register("recipeSources.anyFilter", {
    reads = { UI_PATH .. ".preset", UI_PATH .. ".profFilter", UI_PATH .. ".expFilter", UI_PATH .. ".srcFilter",
              UI_PATH .. ".zoneFilter", UI_PATH .. ".repFilter", UI_PATH .. ".curFilter" },
    fn = function(state)
        local ui = state.session.ui.recipeSources
        if ui.preset ~= "all" then return true end
        for _, a in ipairs(AXES) do
            if next(ui[a.set]) ~= nil then return true end
        end
        return false
    end,
})
Selectors:Register("recipeSources.activeFiltersLabel", {
    calls = { "recipeSources.anyFilter" },
    fn = function(state, ctx)
        return HDG.Locale:Get(Selectors:Call("recipeSources.anyFilter", state, ctx)
            and "RS_ACTIVE_FILTERS" or "RS_NO_FILTERS")
    end,
})

-- The Zone filter values for where the player stands: the zone the Zone Scanner
-- names, the map's own name (a city with a map of its own), every listed zone whose
-- curated map is this map, and the zone each vendor standing on this map is filed
-- under. Only zones some recipe lists. The names are the client's language, so they
-- match the English keys on an English client only; the map IDs match on any (all of
-- TrainersDB's zones are curated).
Selectors:Register("recipeSources.currentZones", {
    memoized = true,
    reads = { "session.zone.currentMapID", "session.zone.currentZoneName",
              "session.zone.zoneLevelName", "session.resolvers.staticData.tick" },
    calls = { "recipeSources.axisCounts" },
    fn = function(state, ctx)
        local listed = Selectors:Call("recipeSources.axisCounts", state, ctx).zone
        local zone, out = state.session.zone, {}
        local function add(name) if listed[name] then out[name] = true end end
        add(zone.zoneLevelName)
        add(zone.currentZoneName)
        local mapIDs = HDG.ZoneNameResolver.ZONE_MAP_IDS
        for name in pairs(listed) do
            if mapIDs[name] == zone.currentMapID then out[name] = true end
        end
        local Aug = HDG.StaticData.VendorAugment
        for _, npcID in ipairs(Aug:GetVendorsByMap(zone.currentMapID) or {}) do   -- exception(nullable): a map with no vendors has no bucket
            add(Aug:Get(npcID).zone)
        end
        return out
    end,
})
Selectors:Register("recipeSources.hasCurrentZones", {
    calls = { "recipeSources.currentZones" },
    fn = function(state, ctx) return next(Selectors:Call("recipeSources.currentZones", state, ctx)) ~= nil end,
})

-- ============================================================================
-- Detail: one scrollbox of rows, each card flattened into rows
-- ============================================================================
-- kinds: info, section, reagents, cardHead, line, place, teach, blank.
-- A line's `tone` picks its color in the row factory (text / dim / rep / met / quest /
-- miss) and `lines` sizes it for wrapped text. A cardHead or place carrying map fields
-- shows Waypoint / Map.

local NOTE_CHARS_PER_LINE = 72   -- caption characters across the detail panel's width
-- The detail's state line for "you" / "none"; an alt's ("Known by Ann, Bob", each name
-- in its class color) is drawn from `alts` by the row factory.
local KNOWN_TEXT = { you = "RS_STATE_YOU", none = "RS_STATE_NONE" }
local function _stateText(known)
    if known == "alt" then return nil end
    return HDG.Locale:Get(KNOWN_TEXT[known])
end

local function _lineRow(key, text, tone)
    return { kind = "line", key = key, text = text, tone = tone,
             lines = math.max(1, math.ceil(#text / NOTE_CHARS_PER_LINE)) }
end

-- A line row naming characters ({ text, parts } from _named): the factory paints `parts`.
local function _namedRow(key, named, tone)
    local row = _lineRow(key, named.text, tone)
    row.parts = named.parts
    return row
end

local function _blankRow(textKey)
    return { kind = "blank", key = "blank", text = HDG.Locale:Get(textKey) }
end

local function _sectionRow(key, label, count, missing)
    return { kind = "section", key = key, label = label, count = count, missing = missing }
end

local function _infoRow(m, K)
    local meta, known = { m.profession }, _knownState(K, m.itemID)
    if m.skill then meta[#meta + 1] = HDG.Locale:Get("RS_NEEDS_SKILL"):format(m.skill) end
    return { kind = "info", key = "info", itemID = m.itemID, name = m.name,
             icon = HDG.ItemNameResolver:ResolveIcon(m.itemID), meta = table.concat(meta, " - "),
             known = known, stateText = _stateText(known), alts = K.altChars[m.itemID],   -- exception(nullable): no alt knows it
             -- the recipe's spell page: its "taught by" lists every source
             wowheadUrl = "https://www.wowhead.com/spell=" .. m.spellID .. "?utm_source=hdg" }
end

-- ----- Reagents -----

local function _reagentCell(slot, counts)
    local have = counts[slot.itemID] or 0   -- exception(boundary): sparse bag map
    return { itemID = slot.itemID, icon = HDG.ItemNameResolver:ResolveIcon(slot.itemID),
             name = HDG.Format.LocalItemName(slot.itemID, slot.name),
             have = have, need = slot.qty, short = have < slot.qty }
end

-- The recipe's basic reagents in ProfessionsDB order (the Recipes tab's craft graph:
-- runtime capture laid over the seed) with BagObserver's cached counts.
local function _reagentCells(m, state, ctx)
    local graph = Selectors:Call("recipes.craftGraph", state, ctx)
    local counts, cells = HDG.BagObserver:GetCounts(), {}
    HDG.StaticData.Professions:VisitBasicSlots(graph[m.itemID], function(slot)
        cells[#cells + 1] = _reagentCell(slot, counts)
    end)
    return cells
end

local function _appendReagents(rows, m, state, ctx)
    local cells = _reagentCells(m, state, ctx)
    if #cells == 0 then return end
    local missing = {}
    for _, c in ipairs(cells) do
        if c.short then missing[#missing + 1] = { id = c.itemID, qty = c.need - c.have } end
    end
    local count = (#missing > 0) and HDG.Locale:Get("RS_REAGENTS_SHORT"):format(#missing)
        or HDG.Locale:Get("RS_REAGENTS_ALL")
    rows[#rows + 1] = _sectionRow("sec:reagents", HDG.Locale:Get("RS_REAGENTS"), count, missing)
    for i = 1, #cells, 2 do
        rows[#rows + 1] = { kind = "reagents", key = "rg:" .. i, a = cells[i], b = cells[i + 1] }
    end
end

-- ----- Where to learn it -----

local function _placeDetail(p)
    local parts = {}
    if p.zone then parts[#parts + 1] = p.zoneText end
    if p.x then parts[#parts + 1] = _coords(p.x, p.y) end
    if p.note then parts[#parts + 1] = p.note end
    return table.concat(parts, "  ")
end

local function _placeRow(key, p)
    return { kind = "place", key = key .. ":" .. p.key, name = _placeName(p), side = p.side,
             detail = _placeDetail(p), mappable = p.mapID ~= nil and p.x ~= nil,
             missing = p.x == nil, other = p.other == true,
             mapID = p.mapID, x = p.x, y = p.y, zone = p.zone }
end

-- A one-NPC card's location: the place row's words (zone, coords, the note saying where
-- in a building), or "no location" when the NPC has no coordinates.
local function _locLine(key, p)
    if p.x then return _lineRow(key, _placeDetail(p), "text") end   -- normal text, not dim (Vamoose, 2026-10-26)
    return _lineRow(key, HDG.Locale:Get("RS_NO_LOCATION"):format(p.zoneText), "miss")
end

-- cost = the price shown at the head's right ("" for a card that prices on a line);
-- place = the one NPC whose Waypoint / Map the head carries (nil for a card of many).
local function _headRow(key, s, title, place, cost)
    local row = { kind = "cardHead", key = key .. ":head", chipKind = s.kind, chipLabel = s.label,
                  title = title, cost = cost, place = place }
    if place then row.side = place.side end   -- the badge rides with the head's one NPC
    return row
end

-- "Requires Iskaara Tuskarr Renown 11", with your live standing (RepObserver), as
-- acq.selectedItem.compactDetail words it.
local function _repLine(key, s)
    local req = s.repName
    if HDG.Constants.REP_FACTIONS[s.factionID].friendship then
        req = HDG.Locale:Get("RS_REP_FRIENDSHIP"):format(s.repName)
    elseif s.minRep and s.minRep >= 9 then
        req = HDG.Locale:Get("RS_REP_RENOWN"):format(s.repName, s.minRep - 8)
    end
    local prog = HDG.RepObserver:GetProgress(s.factionID, s.minRep)
    local suffix = HDG.Format.ComposeRepProgressSuffix(prog)
    local text = HDG.Locale:Get("RS_REQUIRES"):format(req)
    if not prog then return _lineRow(key, text, "rep") end   -- exception(nullable): GetProgress answers nil for a faction the client doesn't know
    return _lineRow(key, text .. "  " .. suffix, prog.met and "met" or "rep")
end

-- The cost / rep / quest / notes lines under a one-place card.
local function _cardLines(rows, key, s)
    if s.costText ~= "" then rows[#rows + 1] = _lineRow(key .. ":cost", HDG.Locale:Get("RS_COST"):format(s.costText), "text") end
    if s.factionID then rows[#rows + 1] = _repLine(key .. ":rep", s) end
    if s.questID then rows[#rows + 1] = _lineRow(key .. ":quest", HDG.Locale:Get("RS_QUEST"):format(s.who), "quest") end
    if s.notes then rows[#rows + 1] = _lineRow(key .. ":notes", s.notes, "dim") end
end

-- A vendor or a named trainer: one NPC, Waypoint / Map on the head.
local function _cardSingle(rows, key, s)
    local p = s.places[1]
    rows[#rows + 1] = _headRow(key, s, _sourceWho(s), _placeRow(key, p), "")
    rows[#rows + 1] = _locLine(key .. ":loc", p)
    _cardLines(rows, key, s)
end

-- Vendors sharing a zone, a price and a rep gate: one card, a row per NPC.
local function _cardVendorGroup(rows, key, group)
    local s = group[1]
    rows[#rows + 1] = _headRow(key, s, HDG.Locale:Get("RS_N_VENDORS"):format(#group, s.zoneText), nil, s.costText)
    if s.factionID then rows[#rows + 1] = _repLine(key .. ":rep", s) end
    for _, v in ipairs(group) do rows[#rows + 1] = _placeRow(key, v.places[1]) end
end

-- Any trainer of a tier: TrainersDB's trainers, yours first, the other faction's dimmed.
local function _cardAnyTrainer(rows, key, s)
    rows[#rows + 1] = _headRow(key, s, s.who, nil, s.costText)
    for _, p in ipairs(s.places) do rows[#rows + 1] = _placeRow(key, p) end
end

-- Drop, treasure, fishing, quest, discovery, event, auction: no NPC to visit.
local function _cardOther(rows, key, s)
    rows[#rows + 1] = _headRow(key, s, s.who, nil, "")
    if s.zone then rows[#rows + 1] = _lineRow(key .. ":loc", s.zoneText, "dim") end
    _cardLines(rows, key, s)
end

local function _mergeKey(s)
    return table.concat({ s.zone, s.costText, tostring(s.factionID), tostring(s.minRep) }, "|")
end

-- Sources in order, vendors with the same zone, price and rep gate grouped.
local function _groupSources(sources)
    local groups, byKey = {}, {}
    for _, s in ipairs(sources) do
        local k = (s.kind == "vendor") and _mergeKey(s)
        if k and byKey[k] then
            table.insert(byKey[k], s)
        else
            groups[#groups + 1] = { s }
            if k then byKey[k] = groups[#groups] end
        end
    end
    return groups
end

local function _appendCardRows(rows, key, group)
    local s = group[1]
    if #group > 1 then return _cardVendorGroup(rows, key, group) end
    if s.generic then return _cardAnyTrainer(rows, key, s) end
    if s.kind == "vendor" or s.kind == "trainer" then return _cardSingle(rows, key, s) end
    _cardOther(rows, key, s)
end

-- Whether every NPC on a card is the other faction's.
local function _isOtherCard(group)
    for _, s in ipairs(group) do
        if not s.other then return false end
    end
    return true
end

-- An other-faction card stays, listed after yours, every row dimmed (Vamoose, 2026-10-26).
local function _appendCard(rows, i, group)
    local first = #rows + 1
    _appendCardRows(rows, "c" .. i, group)
    if not _isOtherCard(group) then return end
    for r = first, #rows do rows[r].other = true end
end

local function _kindsSummary(m)
    local seen, labels = {}, {}
    for _, s in ipairs(m.sources) do
        if not seen[s.kind] then seen[s.kind] = true; labels[#labels + 1] = s.label end
    end
    return table.concat(labels, ", ")
end

local function _whereCount(m)
    local n = #m.sources
    if n == 0 then return HDG.Locale:Get("RS_NONE_RECORDED") end
    return HDG.Locale:Get(n == 1 and "RS_N_SOURCE" or "RS_N_SOURCES"):format(n, _kindsSummary(m))
end

local function _appendWhere(rows, m)
    rows[#rows + 1] = _sectionRow("sec:where", HDG.Locale:Get("RS_WHERE"), _whereCount(m))
    if #m.sources == 0 then
        rows[#rows + 1] = _lineRow("nosrc", HDG.Locale:Get("RS_NO_SOURCE"), "dim")
        return
    end
    for i, group in ipairs(_groupSources(m.sources)) do _appendCard(rows, i, group) end
end

local function _appendFooter(rows, m)
    if m.notes then rows[#rows + 1] = _lineRow("notes", HDG.Locale:Get("RS_NOTES"):format(m.notes), "dim") end
end

Selectors:Register("recipeSources.selectedRecipe", {
    reads = { UI_PATH .. ".selectedItemID" },
    calls = { "recipeSources.models" },
    fn = function(state, ctx)
        local id = state.session.ui.recipeSources.selectedItemID
        if not id then return nil end   -- exception(nullable): nothing selected yet
        return Selectors:Call("recipeSources.models", state, ctx).byItem[id]
    end,
})

Selectors:Register("recipeSources.recipeDetailRows", {
    reads = { "session.resolvers.rep.tick", "session.resolvers.bag.tick", "session.itemNames.names",
              "session.npcNames.names", "session.resolvers.staticData.tick" },
    calls = { "recipeSources.selectedRecipe", "recipes.craftGraph", "recipes.knowledge" },
    fn = function(state, ctx)
        local m = Selectors:Call("recipeSources.selectedRecipe", state, ctx)
        if not m then return { _blankRow("RS_PICK_RECIPE") } end
        local rows = { _infoRow(m, Selectors:Call("recipes.knowledge", state, ctx)) }
        _appendReagents(rows, m, state, ctx)
        _appendWhere(rows, m)
        _appendFooter(rows, m)
        return rows
    end,
})

-- ----- Teacher detail -----

local function _teachRow(r, K)
    local m, s = r.model, r.source
    local known = _knownState(K, m.itemID)
    local bits = { m.profession }
    if m.skill then bits[#bits + 1] = HDG.Locale:Get("RS_SKILL"):format(m.skill) end
    if s.repName then bits[#bits + 1] = s.repName end
    return { kind = "teach", key = "t:" .. m.itemID, itemID = m.itemID, name = m.name,
             atlas = HDG.Format.ProfessionAtlas(m.profession), known = known, stateShort = _stateShort(known),
             alts = K.altChars[m.itemID], line2 = table.concat(bits, " - "), cost = s.costText }   -- exception(nullable): no alt knows it
end

-- Not learned first, then by name.
local function _teachOrder(K)
    return function(a, b)
        local an, bn = _knownState(K, a.model.itemID) == "none", _knownState(K, b.model.itemID) == "none"
        if an ~= bn then return an end
        return _byName(a.model, b.model)
    end
end

local function _teacherPlace(t)
    return { key = t.key, name = t.who, zone = t.zone, zoneText = t.zoneText, mapID = t.mapID, x = t.x, y = t.y,
             side = t.side, note = t.note }
end

local function _appendTeacherCard(rows, t, needsBy, topByProf)
    local s = { kind = t.kind, label = _kindLabel(t.kind) }
    local place = _teacherPlace(t)
    rows[#rows + 1] = _headRow("teacher", s, t.who, t.isNpc and _placeRow("teacher", place) or nil, "")
    if t.isNpc then rows[#rows + 1] = _locLine("teacher:loc", place)
    elseif t.zone then rows[#rows + 1] = _lineRow("teacher:loc", t.zoneText, "dim") end
    local needs, top = _trainerExtras(t, needsBy, topByProf)
    if needs then rows[#rows + 1] = _namedRow("teacher:needs", needs, "text") end
    if top then rows[#rows + 1] = _namedRow("teacher:top", top, "dim") end
end

Selectors:Register("recipeSources.selectedTeacher", {
    reads = { UI_PATH .. ".selectedTeacherKey" },
    calls = { "recipeSources.allTeachers" },
    fn = function(state, ctx)
        local key = state.session.ui.recipeSources.selectedTeacherKey
        if not key then return nil end   -- exception(nullable): nothing selected yet
        return Selectors:Call("recipeSources.allTeachers", state, ctx).byKey[key]
    end,
})

-- What a teacher teaches: their decor recipes, not learned first; or, for a trainer
-- listed for a skill line alone, that skill line with no count.
local function _appendTeaches(rows, t, K)
    if #t.recipes == 0 then
        rows[#rows + 1] = _sectionRow("sec:teaches", HDG.Locale:Get("RS_TEACHES_SKILL_HEAD"):format(_skillLineText(t)), "")
        return
    end
    local list = { unpack(t.recipes) }
    table.sort(list, _teachOrder(K))
    rows[#rows + 1] = _sectionRow("sec:teaches", HDG.Locale:Get(#list == 1 and "RS_TEACHES_ONE" or "RS_TEACHES"):format(#list),
        HDG.Locale:Get("RS_N_NOT_LEARNED"):format(_toLearn(t, K)))
    for _, r in ipairs(list) do rows[#rows + 1] = _teachRow(r, K) end
end

Selectors:Register("recipeSources.teacherDetailRows", {
    reads = { "session.resolvers.staticData.tick" },
    calls = { "recipeSources.selectedTeacher", "recipeSources.charsNeedingByProfExp", "recipeSources.topDecorCrafterByProf",
              "recipes.knowledge" },
    fn = function(state, ctx)
        local t = Selectors:Call("recipeSources.selectedTeacher", state, ctx)
        if not t then return { _blankRow("RS_PICK_TEACHER") } end
        local rows = {}
        _appendTeacherCard(rows, t, Selectors:Call("recipeSources.charsNeedingByProfExp", state, ctx),
            Selectors:Call("recipeSources.topDecorCrafterByProf", state, ctx))
        _appendTeaches(rows, t, Selectors:Call("recipes.knowledge", state, ctx))
        return rows
    end,
})

Selectors:Register("recipeSources.detailRows", {
    calls = { "recipeSources.viewMode", "recipeSources.recipeDetailRows", "recipeSources.teacherDetailRows" },
    fn = function(state, ctx)
        if Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher" then
            return Selectors:Call("recipeSources.teacherDetailRows", state, ctx)
        end
        return Selectors:Call("recipeSources.recipeDetailRows", state, ctx)
    end,
})

-- ----- Detail header + map -----

Selectors:Register("recipeSources.detailTitle", {
    calls = { "recipeSources.viewMode", "recipeSources.selectedRecipe", "recipeSources.selectedTeacher" },
    fn = function(state, ctx)
        if Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher" then
            local t = Selectors:Call("recipeSources.selectedTeacher", state, ctx)
            return t and t.who or HDG.Locale:Get("RS_SELECT_TEACHER")   -- exception(nullable): nothing selected yet
        end
        local m = Selectors:Call("recipeSources.selectedRecipe", state, ctx)
        return m and m.name or HDG.Locale:Get("RS_SELECT_RECIPE")   -- exception(nullable): nothing selected yet
    end,
})

-- Right of the title: the recipe's expansion in its brand color, or the teacher's zone.
Selectors:Register("recipeSources.detailExpansion", {
    calls = { "recipeSources.viewMode", "recipeSources.selectedRecipe", "recipeSources.selectedTeacher" },
    fn = function(state, ctx)
        if Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher" then
            local t = Selectors:Call("recipeSources.selectedTeacher", state, ctx)
            return t and t.zoneText or ""   -- exception(nullable): nothing selected, or a place with no zone
        end
        local m = Selectors:Call("recipeSources.selectedRecipe", state, ctx)
        if not m then return "" end
        local hex = HDG.Expansion.GetColorHex(m.expansion)
        if not hex then return m.expansion end   -- exception(nullable): "?" has no brand color
        return hex .. m.expansion .. "|r"
    end,
})

-- The vendorMap point for a place: pinned when it has coords, the zone drawn
-- pinless when only its name resolves to a map (acq.selected.mapPoint's rule).
local function _mapPointFor(p)
    if p.mapID and p.x then
        return { mapID = p.mapID, x = p.x / 100, y = p.y / 100, name = _placeName(p), zone = p.zoneText }
    end
    local mapID = p.zone and HDG.ZoneNameResolver:MapIDForName(p.zone)   -- exception(nullable): a drop names no zone; sub-zones have no uiMap
    if not mapID then return nil end
    return { mapID = mapID, name = _placeName(p), zone = p.zoneText, noPin = true }
end

-- A recipe's first place with coords, else its first place that draws a zone.
local function _recipeMapPoint(m)
    local fallback
    for _, s in ipairs(m.sources) do
        for _, p in ipairs(_visitPlaces(s)) do
            if p.mapID and p.x then return _mapPointFor(p) end
            fallback = fallback or _mapPointFor(p)
        end
    end
    return fallback
end

Selectors:Register("recipeSources.selected.mapPoint", {
    reads = { "session.npcNames.names" },
    calls = { "recipeSources.viewMode", "recipeSources.selectedRecipe", "recipeSources.selectedTeacher" },
    fn = function(state, ctx)
        if Selectors:Call("recipeSources.viewMode", state, ctx) == "teacher" then
            local t = Selectors:Call("recipeSources.selectedTeacher", state, ctx)
            return t and _mapPointFor(_teacherPlace(t))   -- exception(nullable): nothing selected yet
        end
        local m = Selectors:Call("recipeSources.selectedRecipe", state, ctx)
        return m and _recipeMapPoint(m)   -- exception(nullable): nothing selected yet
    end,
})
Selectors:Register("recipeSources.hasMapPoint", {
    calls = { "recipeSources.selected.mapPoint" },
    fn = function(state, ctx) return Selectors:Call("recipeSources.selected.mapPoint", state, ctx) ~= nil end,
})
