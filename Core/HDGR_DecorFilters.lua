-- HDG.DecorFilters -- what the Decor tab's filter menus ask and what a decor answers
-- ============================================================================
-- The menus are HDG.Constants.DECOR_FILTER_MENUS; each holds one or more GROUPS
-- (DECOR_FILTER_GROUPS). A TICK is one value of one group, written "group:value":
--
--   "color:dark-red"     a FacetDB value (our vision pass)
--   "bstyle:143"         one of the game's own tags, by tagID (its name is localized)
--   "status:favorites"   a collection flag
--   "cost:3"  "where:indoor"  "source:QUEST"  "prof:Tailoring"   a catalog row field
--
-- What the ticks of a group ask depends on the group (Constants):
--   each     every ticked value is a filter of its own: a decor carries several
--            colours, and Brown + Gold asks for both
--   allOf    one filter that every ticked value has to pass (Collection)
--   neither  one filter that ANY ticked value passes (a decor has one size)
-- Kind and Object are one any-of filter (the Type menu): a decor passes it on a
-- ticked kind OR a ticked object. Every filter lists the decor that pass every
-- filter; Best first scores them.
--
-- In Core, not beside the selectors: the filter reducers flip ticks through it
-- (DECOR_TOGGLE_FILTER, DECOR_CLEAR_FILTERS).
-- Pure: static data and the catalog observer's rows in, tables and functions out.
-- What a catalog row does not carry comes from the selectors as `known`, a table
-- with either field or neither:
--   known.flags    { [value] = fn(itemID) }: the player's collection flags
--   known.recipes  recipes.db: the shipped recipes plus the ones captured off a
--                  profession window. A decor a captured recipe makes is crafted
--                  before HDG ships that recipe (owner ruling 2026-10-31).

HDG = HDG or {}
HDG.DecorFilters = HDG.DecorFilters or {}
local DF = HDG.DecorFilters

local byte = string.byte

local GROUPS = HDG.Constants.DECOR_FILTER_GROUPS
local MENUS  = HDG.Constants.DECOR_FILTER_MENUS

-- The filter Kind and Object make together, and the pseudo-kind holding the
-- objects no kind claims.
local TYPE_UNIT  = "type"
local OTHER_KIND = "other"
DF.TYPE_UNIT, DF.OTHER_KIND = TYPE_UNIT, OTHER_KIND

-- ===== Static indexes ========================================================

DF.GroupByID   = {}   -- group id -> its DECOR_FILTER_GROUPS entry
DF.MenuByID    = {}   -- menu id  -> its DECOR_FILTER_MENUS entry
DF.MenuOfGroup = {}   -- group id -> the menu that holds it
local GROUP_OF_CAT = {}   -- HDG.TagData category -> group id
local FLAG_VALUES         -- the Collection group's values, in menu order

for _, group in ipairs(GROUPS) do
    DF.GroupByID[group.id] = group
    if group.from == "tag" then
        for cat in pairs(group.cats) do GROUP_OF_CAT[cat] = group.id end
    elseif group.from == "flag" then
        FLAG_VALUES = group.fixed
    end
end
for _, menu in ipairs(MENUS) do
    DF.MenuByID[menu.id] = menu
    for _, gid in ipairs(menu.groups) do DF.MenuOfGroup[gid] = menu end
end

-- ===== Ticks =================================================================

-- One string per (group, value), made once: the list walks ask for the same few
-- hundred ticks thousands of times.
local _tickOf = {}
local function _tick(gid, value)
    local byValue = _tickOf[gid]
    if not byValue then
        byValue = {}
        _tickOf[gid] = byValue
    end
    local tick = byValue[value]
    if not tick then
        tick = gid .. ":" .. tostring(value)
        byValue[value] = tick
    end
    return tick
end
DF.Tick = _tick

-- "group:value" -> group id, value (a string: a tag group's is its tagID's digits).
function DF.Split(tick)
    return tick:match("^([^:]+):(.+)$")
end

-- The filter a group belongs to: Kind and Object are one, every other group its own.
local function _unitOf(gid)
    if gid == "category" or gid == "subject" then return TYPE_UNIT end
    return gid
end
DF.UnitOf = _unitOf

-- A tick's filter, remembered: the count walk asks once per value per decor.
local _unitOfTick = {}
function DF.UnitOfTick(tick)
    local unit = _unitOfTick[tick]
    if not unit then
        unit = _unitOf((DF.Split(tick)))
        _unitOfTick[tick] = unit
    end
    return unit
end

-- ===== FacetDB ===============================================================
-- A record's bytes: byte k is where axis k's values start, byte k+1 where they
-- end (exclusive), each value its vocab index (Facets:GetAxes).

local _facets
local function _facetIndex()
    if _facets then return _facets end
    local axes, vocab = HDG.StaticData.Facets:GetAxes(), HDG.StaticData.Facets:GetVocab()
    local slotOfAxis = {}
    for slot, axis in ipairs(axes) do slotOfAxis[axis] = slot end
    -- slots: the packed slots a group reads, in slot order. tickAt[slot][vocabIndex]
    -- = the tick, or false for a value that says nothing ("none", "generic").
    -- indexOf[gid][value] = vocabIndex.
    local index = { slots = {}, tickAt = {}, slotOf = {}, indexOf = {} }
    for _, group in ipairs(GROUPS) do
        if group.from == "facet" then
            local slot, ticks, back = slotOfAxis[group.axis], {}, {}
            for i, value in pairs(vocab[group.axis]) do
                ticks[i] = not HDG.DecorSearch.EMPTY_VALUES[value] and _tick(group.id, value)
                back[value] = i
            end
            index.slots[#index.slots + 1] = slot
            index.tickAt[slot], index.slotOf[group.id], index.indexOf[group.id] = ticks, slot, back
        end
    end
    table.sort(index.slots)
    _facets = index
    return index
end

-- ===== What a decor answers ==================================================
-- A walk of the catalog asks for ONE menu's groups, never all of them: a decor
-- answers some thirty ticks across the menus, and a menu's rows and counts need
-- a handful (the whole-catalog count for every menu at once was 22 ms a tick in
-- game, perf profile 2026-11-22). A PLAN names the answers a walk wants:
--   slots               the FacetDB slots to read
--   tags                { [group id] = true } for the game-tag groups
--   cost / where / source / profession / flag    the row fields and flags
--   units               { [filter id] = true }: the filters its groups belong to

local function _newPlan(groupIDs)
    local index = _facetIndex()
    local plan = { slots = {}, units = {} }
    for _, gid in ipairs(groupIDs) do
        local group = DF.GroupByID[gid]
        plan.units[_unitOf(gid)] = true
        if group.from == "facet" then
            plan.slots[#plan.slots + 1] = index.slotOf[gid]
        elseif group.from == "tag" then
            plan.tags = plan.tags or {}   -- exception(nullable): made by the plan's first tag group
            plan.tags[gid] = true
        else
            plan[group.from] = true
        end
    end
    return plan
end

-- The plan for one menu's groups, made on the menu's first walk.
local _menuPlans = {}
function DF.MenuPlan(menuID)
    local plan = _menuPlans[menuID]
    if not plan then
        plan = _newPlan(DF.MenuByID[menuID].groups)
        _menuPlans[menuID] = plan
    end
    return plan
end

local function _addFacetTicks(row, slots, out, n)
    if #slots == 0 then return n end
    local rec = HDG.StaticData.Facets:Get(row.itemID)
    if not rec then return n end   -- exception(nullable): FacetDB tags most catalog items, not all
    local tickAt = _facetIndex().tickAt
    for i = 1, #slots do
        local slot = slots[i]
        local ticks = tickAt[slot]
        local first, stop = byte(rec, slot, slot + 1)
        for p = first, stop - 1 do
            local tick = ticks[byte(rec, p)]
            if tick then n = n + 1; out[n] = tick end
        end
    end
    return n
end

local function _addTagTicks(row, wanted, out, n)
    local tags = row.dataTagsByID
    if not tags then return n end   -- exception(boundary): Blizzard struct field optional
    for tagID in pairs(tags) do
        local gid = GROUP_OF_CAT[HDG.TagData.GetCategory(tagID)]
        if gid and wanted[gid] then n = n + 1; out[n] = _tick(gid, tagID) end   -- exception(nullable): a tag outside the filter groups asks nothing
    end
    return n
end

-- The recipe that makes a decor: from the recipe book when the caller knows it
-- (shipped + captured), else the shipped one the catalog row carries.
local function _recipeOf(row, known)
    local recipes = known.recipes
    if recipes then return recipes[row.itemID] end   -- exception(nullable): most decor is not crafted
    return row.recipe
end

-- Is `kind` among the first `upTo` source tags? A decor can carry one kind twice
-- (two quests); it answers the Source menu once.
local function _kindSeen(sources, kind, upTo)
    for i = 1, upTo do
        if sources[i].kind == kind then return true end
    end
    return false
end

-- Source kinds and the profession. A decor with a recipe is crafted whether or
-- not the catalog's source text says so.
local function _addSourceTicks(row, known, plan, out, n)
    local sources, crafted = row.sourceTags, false
    if plan.source and sources then   -- exception(nullable): a decor with no source signal has no tags
        for i = 1, #sources do
            local kind = sources[i].kind
            if kind == "CRAFT" then crafted = true end
            if not _kindSeen(sources, kind, i - 1) then n = n + 1; out[n] = _tick("source", kind) end
        end
    end
    local recipe = _recipeOf(row, known)
    if not recipe then return n end
    if plan.source and not crafted then n = n + 1; out[n] = _tick("source", "CRAFT") end
    if plan.profession and recipe.profession then n = n + 1; out[n] = _tick("prof", recipe.profession) end   -- exception(nullable): a capture made before the profession was recorded
    return n
end

local function _addRowFieldTicks(row, plan, out, n)
    local cost = row.placementCost
    if plan.cost and cost and cost > 0 then n = n + 1; out[n] = _tick("cost", cost) end   -- exception(boundary): catalog struct field sparse
    if plan.where then
        if row.isAllowedIndoors  then n = n + 1; out[n] = _tick("where", "indoor")  end
        if row.isAllowedOutdoors then n = n + 1; out[n] = _tick("where", "outdoor") end
    end
    return n
end

-- The ticks `row` answers among the plan's groups, written into `out` (the
-- caller's buffer, reused across rows). Returns how many. `known` (see the file
-- header) adds the collection flags and the captured recipes; without flags the
-- row answers no Collection tick (a menu's own value list does not depend on
-- what the player owns).
function DF.RowTicks(row, known, plan, out)
    local n = _addFacetTicks(row, plan.slots, out, 0)
    if plan.tags then n = _addTagTicks(row, plan.tags, out, n) end   -- exception(nullable): only plans with a game-tag group
    n = _addRowFieldTicks(row, plan, out, n)
    if plan.source or plan.profession then n = _addSourceTicks(row, known, plan, out, n) end
    local flags = plan.flag and known.flags
    if flags then
        local id = row.itemID
        for i = 1, #FLAG_VALUES do
            local value = FLAG_VALUES[i]
            if flags[value](id) then n = n + 1; out[n] = _tick("status", value) end
        end
    end
    return n
end

-- ===== What the ticks ask ====================================================

-- [slot] = { [vocabIndex] = true } for a facet group's ticked values.
local function _facetWants(gid, values)
    local index = _facetIndex()
    local indexOf, wanted = index.indexOf[gid], {}
    for value in pairs(values) do
        local i = indexOf[value]
        if i then wanted[i] = true end   -- exception(nullable): a tick for a value FacetDB no longer carries matches nothing
    end
    return index.slotOf[gid], wanted
end

local function _hasFacet(rec, slot, wanted)
    local first, stop = byte(rec, slot, slot + 1)
    for p = first, stop - 1 do
        if wanted[byte(rec, p)] then return true end
    end
    return false
end

local _passBuilders = {}

function _passBuilders.facet(group, values)
    local slot, wanted = _facetWants(group.id, values)
    local facets = HDG.StaticData.Facets:GetAll()
    return function(row)
        local rec = facets[row.itemID]
        return rec ~= nil and _hasFacet(rec, slot, wanted)   -- exception(nullable): FacetDB tags most catalog items, not all
    end
end

function _passBuilders.tag(_group, values)
    local wanted = {}
    for value in pairs(values) do wanted[tonumber(value)] = true end
    return function(row)
        local tags = row.dataTagsByID
        if not tags then return false end   -- exception(boundary): Blizzard struct field optional
        for tagID in pairs(tags) do
            if wanted[tagID] then return true end
        end
        return false
    end
end

-- Collection: every ticked flag has to hold.
function _passBuilders.flag(_group, values, known)
    local tests = {}
    for value in pairs(values) do tests[#tests + 1] = known.flags[value] end
    return function(row)
        local id = row.itemID
        for i = 1, #tests do
            if not tests[i](id) then return false end
        end
        return true
    end
end

function _passBuilders.cost(_group, values)
    local wanted = {}
    for value in pairs(values) do wanted[tonumber(value)] = true end
    return function(row) return wanted[row.placementCost] == true end
end

function _passBuilders.where(_group, values)
    local indoor, outdoor = values.indoor == true, values.outdoor == true
    return function(row)
        return (indoor and row.isAllowedIndoors) or (outdoor and row.isAllowedOutdoors) or false
    end
end

function _passBuilders.source(_group, values, known)
    local crafted = values.CRAFT == true
    return function(row)
        local sources = row.sourceTags
        if sources then   -- exception(nullable): a decor with no source signal has no tags
            for i = 1, #sources do
                if values[sources[i].kind] then return true end
            end
        end
        return crafted and _recipeOf(row, known) ~= nil
    end
end

function _passBuilders.profession(_group, values, known)
    return function(row)
        local recipe = _recipeOf(row, known)
        return recipe ~= nil and values[recipe.profession] == true   -- exception(nullable): most decor is not crafted
    end
end

-- The Type filter: a ticked kind lists all of it, a ticked object only that.
local function _typePass(kinds, objects)
    local facets = HDG.StaticData.Facets:GetAll()
    local kindSlot, kindWanted, objectSlot, objectWanted
    if kinds   then kindSlot,   kindWanted   = _facetWants("category", kinds)  end   -- exception(nullable): ticks may name objects only
    if objects then objectSlot, objectWanted = _facetWants("subject",  objects) end   -- exception(nullable): ticks may name kinds only
    return function(row)
        local rec = facets[row.itemID]
        if not rec then return false end   -- exception(nullable): FacetDB tags most catalog items, not all
        return (kindWanted ~= nil and _hasFacet(rec, kindSlot, kindWanted))
            or (objectWanted ~= nil and _hasFacet(rec, objectSlot, objectWanted))
    end
end

-- { [group id] = { [value] = true } } for the groups that hold a tick.
local function _valuesByGroup(ticks)
    local byGroup = {}
    for tick in pairs(ticks) do
        local gid, value = DF.Split(tick)
        local values = byGroup[gid]
        if not values then
            values = {}
            byGroup[gid] = values
        end
        values[value] = true
    end
    return byGroup
end

-- One filter per ticked value of an `each` group, in value order so two builds of
-- the same ticks list them alike.
local function _addEachUnits(units, group, values, known)
    local sorted = {}
    for value in pairs(values) do sorted[#sorted + 1] = value end
    table.sort(sorted)
    for _, value in ipairs(sorted) do
        units[#units + 1] = { id = _tick(group.id, value), group = group.id, value = value, hard = false, anyOf = false,
                              pass = _passBuilders[group.from](group, { [value] = true }, known) }
    end
end

-- The filters in force, in menu order: { id, hard, anyOf, pass = fn(row) }.
--   hard    narrows in both match modes (Collection: owning a piece is never a
--           near miss)
--   anyOf   passes on any one of its menu's ticked values, so its own ticks do
--           not shrink its menu's counts (id = the group's, or "type")
-- An `each` group's filters carry `group` and `value`; their id is the tick.
function DF.Units(ticks, known)
    local byGroup, units, typeDone = _valuesByGroup(ticks), {}, false
    for _, group in ipairs(GROUPS) do
        local values, unit = byGroup[group.id], _unitOf(group.id)
        if unit == TYPE_UNIT then
            if not typeDone and (byGroup.category or byGroup.subject) then
                typeDone = true
                units[#units + 1] = { id = TYPE_UNIT, hard = false, anyOf = true,
                                      pass = _typePass(byGroup.category, byGroup.subject) }
            end
        elseif values and group.each then
            _addEachUnits(units, group, values, known)
        elseif values then
            units[#units + 1] = { id = unit, hard = group.allOf == true, anyOf = not group.allOf,
                                  pass = _passBuilders[group.from](group, values, known) }
        end
    end
    return units
end

-- ===== The Type menu's tree ==================================================
-- Each object sits under the kind it most often is ("chair" under seating), so
-- Kind and Object can be one menu. Counted over FacetDB once.

local _tree
local function _tallyRecord(rec, index, tally)
    local kindSlot, objectSlot = index.slotOf.category, index.slotOf.subject
    local kindTicks, objectTicks = index.tickAt[kindSlot], index.tickAt[objectSlot]
    local kFirst, kStop = byte(rec, kindSlot, kindSlot + 1)
    local oFirst, oStop = byte(rec, objectSlot, objectSlot + 1)
    for o = oFirst, oStop - 1 do
        local object = byte(rec, o)
        if objectTicks[object] then
            local counts = tally[object]
            if not counts then
                counts = {}
                tally[object] = counts
            end
            for k = kFirst, kStop - 1 do
                local kind = byte(rec, k)
                if kindTicks[kind] then counts[kind] = (counts[kind] or 0) + 1 end
            end
        end
    end
end

-- The kind an object is most often, by vocab index; ties go to the lower index
-- so the tree is the same on every load.
local function _topKind(counts)
    local best, bestCount
    for kind, count in pairs(counts) do
        if not best or count > bestCount or (count == bestCount and kind < best) then
            best, bestCount = kind, count
        end
    end
    return best
end

-- { kindOf = { [object value] = kind value }, objectsOf = { [kind value] = { object values } } }
function DF.TypeTree()
    if _tree then return _tree end
    local index, vocab = _facetIndex(), HDG.StaticData.Facets:GetVocab()
    local tally = {}
    for _, rec in pairs(HDG.StaticData.Facets:GetAll()) do _tallyRecord(rec, index, tally) end
    local tree = { kindOf = {}, objectsOf = {} }
    for object, counts in pairs(tally) do
        local kindIndex = _topKind(counts)
        local kind  = kindIndex and vocab.category[kindIndex] or OTHER_KIND   -- exception(nullable): an object no kind claims
        local value = vocab.subject[object]
        tree.kindOf[value] = kind
        local list = tree.objectsOf[kind]
        if not list then
            list = {}
            tree.objectsOf[kind] = list
        end
        list[#list + 1] = value
    end
    for _, list in pairs(tree.objectsOf) do table.sort(list) end
    _tree = tree
    return tree
end

-- ===== Reducer helpers =======================================================

-- Flip one tick in `ticks`. The Type menu's rule: a ticked kind is all of it, so
-- ticking a kind unticks the objects under it, and ticking an object unticks its kind.
function DF.Toggle(ticks, tick)
    if ticks[tick] then
        ticks[tick] = nil
        return
    end
    ticks[tick] = true
    local gid, value = DF.Split(tick)
    if gid == "category" then
        for _, object in ipairs(DF.TypeTree().objectsOf[value] or {}) do   -- exception(nullable): a kind with no objects under it
            ticks[_tick("subject", object)] = nil
        end
    elseif gid == "subject" then
        local kind = DF.TypeTree().kindOf[value]
        if kind then ticks[_tick("category", kind)] = nil end   -- exception(nullable): a tick for an object FacetDB no longer carries
    end
end

-- Drop every tick of one menu's groups.
function DF.ClearMenu(ticks, menuID)
    local menu = DF.MenuByID[menuID]
    for tick in pairs(ticks) do
        if DF.MenuOfGroup[(DF.Split(tick))] == menu then ticks[tick] = nil end
    end
end

-- The ticks "Find similar" asks for: the piece's own objects (its kinds when it
-- names none), colours, materials, moods and cultures.
local SIMILAR_GROUPS = { color = true, material = true, mood = true, culture = true }
local _similarPlan
function DF.SimilarTicks(row)
    _similarPlan = _similarPlan or _newPlan({ "category", "subject", "color", "material", "mood", "culture" })
    local buf, ticks, kinds, hasObject = {}, {}, {}, false
    for i = 1, _addFacetTicks(row, _similarPlan.slots, buf, 0) do
        local tick = buf[i]
        local gid = DF.Split(tick)
        if SIMILAR_GROUPS[gid] then
            ticks[tick] = true
        elseif gid == "subject" then
            ticks[tick] = true
            hasObject = true
        elseif gid == "category" then
            kinds[#kinds + 1] = tick
        end
    end
    if not hasObject then
        for _, tick in ipairs(kinds) do ticks[tick] = true end
    end
    return ticks
end

-- ===== Labels ================================================================

-- "dark-red" -> "Dark red": FacetDB's values are lowercase, hyphenated English.
local function _nice(value)
    local text = value:gsub("%-", " ")
    return text:sub(1, 1):upper() .. text:sub(2)
end

local COST_LABEL = "|A:house-decor-budget-icon:12:12|a %d"

-- A locale key per value that is not a word of the game's or of FacetDB's.
local VALUE_LABEL_KEYS = {
    status   = { uncollected = "DECOR_UNCOLLECTED", collected = "DECOR_FV_COLLECTED", favorites = "DECOR_FV_FAVORITES",
                 placed = "DECOR_FV_PLACED", dyeable = "DECOR_FV_DYEABLE", dyed = "DECOR_FV_DYED",
                 housexp = "DECOR_FV_HOUSEXP", redeemable = "DECOR_FV_REDEEMABLE", new = "DECOR_FV_NEW" },
    where    = { indoor = "DECOR_FV_INDOOR", outdoor = "DECOR_FV_OUTDOOR" },
    seasonal = { ["lunar-festival"] = "DECOR_FV_LUNAR", ["noblegarden"] = "DECOR_FV_NOBLEGARDEN",
                 ["midsummer"] = "DECOR_FV_MIDSUMMER", ["pirates-day"] = "DECOR_FV_PIRATES",
                 ["brewfest"] = "DECOR_FV_BREWFEST", ["harvest-festival"] = "DECOR_FV_HARVEST",
                 ["hallows-end"] = "DECOR_FV_HALLOWS", ["day-of-dead"] = "DECOR_FV_DAYOFDEAD",
                 ["winter-veil"] = "DECOR_FV_WINTERVEIL" },
}

local _labelBuilders = {}
function _labelBuilders.facet(value) return _nice(value) end
function _labelBuilders.tag(value) return HDG.TagData.GetLabel(tonumber(value)) or value end   -- exception(boundary): tag names stream in after login
function _labelBuilders.cost(value) return COST_LABEL:format(tonumber(value)) end
function _labelBuilders.source(value) return HDG.Constants.SOURCE_KIND_BY_KEY[value].label end
function _labelBuilders.profession(value) return value end

-- What a tick's value reads as in a menu, on a chip and in the list's count line.
function DF.ValueLabel(gid, value)
    local keys = VALUE_LABEL_KEYS[gid]
    if keys then return HDG.Locale:Get(keys[value]) end
    return _labelBuilders[DF.GroupByID[gid].from](value)
end

function DF.GroupLabel(gid)
    return HDG.Locale:Get(DF.GroupByID[gid].label)
end

-- A filter's name, for "misses ...": the ticked value of an `each` group ("Gray"),
-- the Type menu's for Kind + Object, else its group's ("Size").
function DF.UnitLabel(unit)
    if unit.value then return DF.ValueLabel(unit.group, unit.value) end   -- exception(nullable): only an each group's filters carry a value
    if unit.id == TYPE_UNIT then return HDG.Locale:Get(DF.MenuByID.type.label) end
    return DF.GroupLabel(unit.id)
end
