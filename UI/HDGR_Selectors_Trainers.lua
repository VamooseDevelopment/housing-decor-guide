-- HDG.Selectors -- Trainers tab
-- ============================================================================
-- Profession trainer NPCs grouped by profession + expansion. Flat row list:
--   profHeader    -- collapsible profession bar (chars-needing-training + top crafter)
--   expSection    -- expansion divider under expanded profession
--   trainerRow    -- single NPC row (location, faction badge, waypoint button)
--   midnightHeader -- collapsible "Midnight Recipe Sources" section
--   midnightRow   -- recipe sourcing row (recipe / source / npc / zone / cost)
--
-- Search: trainer name OR enUS zone name (case-insensitive substring).
-- Headers are not filtered; only trainer rows inside each profession.

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors

-- currentCharKey via HDG.SessionIdentity.GetCharKey (populated at onEnable).

-- ============================================================================
-- Bare-path selectors (chrome state for binding)
-- ============================================================================

Selectors:Register("trainers.searchQuery", {
    reads = {"session.ui.trainers.searchQuery"},
    fn    = function(state) return state.session.ui.trainers.searchQuery end,
})


Selectors:Register("trainers.midnightExpanded", {
    reads = {"session.ui.trainers.midnightExpanded"},
    fn    = function(state) return state.session.ui.trainers.midnightExpanded == true end,
})

Selectors:Register("trainers.selectedNpcID", {
    reads = {"session.ui.trainers.selectedNpcID"},
    fn    = function(state) return state.session.ui.trainers.selectedNpcID end,
})

-- ============================================================================
-- Profession ordering: known-by-current-char first, then unknown.
-- ============================================================================

-- All trainer DB profession names in canonical PROFESSION_DATA order.
Selectors:Register("trainers.allProfessions", {
    reads    = {"session.resolvers.staticData.tick"},
    memoized = true,
    fn = function()
        local out, seen = {}, {}
        local trainers = HDG.StaticData.Trainers:GetAll()
        if HDG.Constants.PROFESSION_DATA then
            for _, p in ipairs(HDG.Constants.PROFESSION_DATA) do
                if trainers[p.name] and not seen[p.name] then
                    out[#out + 1] = p.name
                    seen[p.name] = true
                end
            end
        end
        for profName in pairs(trainers) do
            if not seen[profName] then
                out[#out + 1] = profName
                seen[profName] = true
            end
        end
        return out
    end,
})

-- Profession names the current character has skillLines for.
Selectors:Register("trainers.currentCharKnownProfessions", {
    reads = {"account.characters", "session.identity"},
    fn = function(state)
        local out = {}
        local key = HDG.SessionIdentity.GetCharKey(state)
        if not key then return out end   -- exception(boundary): pre-SESSION_IDENTITY_SET boot window
        local char = state.account.characters[key]
        if not (char and char.professions) then return out end
        for profName, prof in pairs(char.professions) do
            if prof.skillLines and next(prof.skillLines) then
                out[profName] = true
            end
        end
        return out
    end,
})

-- Sorted profession list: current-char-known first (alphabetical within each group).
Selectors:Register("trainers.profSectionsOrdered", {
    reads = {"session.resolvers.staticData.tick", "account.characters"},
    calls = {"trainers.allProfessions", "trainers.currentCharKnownProfessions"},
    fn = function(state, ctx)
        local all   = Selectors:Call("trainers.allProfessions", state, ctx)
        local known = Selectors:Call("trainers.currentCharKnownProfessions", state, ctx)
        local knownList, unknownList = {}, {}
        for _, p in ipairs(all) do
            if known[p] then knownList[#knownList + 1] = p
            else unknownList[#unknownList + 1] = p end
        end
        table.sort(knownList)
        table.sort(unknownList)
        local out = {}
        for _, p in ipairs(knownList)   do out[#out + 1] = { profName = p, knownByCurrent = true  } end
        for _, p in ipairs(unknownList) do out[#out + 1] = { profName = p, knownByCurrent = false } end
        return out
    end,
})

-- ============================================================================
-- Per-profession aggregates (precomputed, memoized).
-- ============================================================================

-- Trainer count per profession: [profName] = N.
Selectors:Register("trainers.trainerCountsByProf", {
    reads    = {"session.resolvers.staticData.tick"},
    memoized = true,
    fn = function()
        local out = {}
        local trainers = HDG.StaticData.Trainers:GetAll() or {}
        for profName, profData in pairs(trainers) do
            local n = 0
            for _, expData in pairs(profData) do
                for _, factionData in pairs(expData) do
                    if factionData.npcID then
                        n = n + 1   -- single trainer record
                    else
                        n = n + #factionData   -- array of trainers
                    end
                end
            end
            out[profName] = n
        end
        return out
    end,
})

-- Top decor crafter per profession: [profName] = { charName, knownCount, totalCount } or nil.
-- Reuses alts.decorRecipeIndex (built once per session, shared with Alts tab).
local function _sumProfBucketTotal(profBucket)
    local total = 0
    for _, cell in pairs(profBucket) do total = total + (cell.total or 0) end
    return total
end

-- Known recipes for one (char, prof) pair across the profBucket cells. 0 if no recipe data.
local function _countCharKnownInProfBucket(char, profName, profBucket)
    local prof = char.professions and char.professions[profName]
    if not (prof and prof.knownRecipes) then return 0 end
    local known = 0
    for recipeID in pairs(prof.knownRecipes) do
        for _, cell in pairs(profBucket) do
            if cell.recipeSet and cell.recipeSet[recipeID] then
                known = known + 1
                break
            end
        end
    end
    return known
end

-- Char with the highest known-recipe count for a profession. (name, knownCount).
local function _findTopCrafterForProf(chars, profName, profBucket)
    local bestName, bestKnown = nil, -1
    for charKey, char in pairs(chars) do
        local known = _countCharKnownInProfBucket(char, profName, profBucket)
        if known > bestKnown then
            bestKnown = known
            bestName  = char.name or charKey
        end
    end
    return bestName, bestKnown
end

Selectors:Register("trainers.topDecorCrafterByProf", {
    reads = {"account.characters", "session.resolvers.staticData.tick"},
    calls = {"alts.decorRecipeIndex"},
    fn = function(state, ctx)
        local out = {}
        local index = Selectors:Call("alts.decorRecipeIndex", state, ctx)
        if not index then return out end
        local chars = state.account.characters
        for profName, profBucket in pairs(index) do
            local total = _sumProfBucketTotal(profBucket)
            if total > 0 then
                local bestName, bestKnown = _findTopCrafterForProf(chars, profName, profBucket)
                if bestName and bestKnown > 0 then
                    out[profName] = {
                        charName   = bestName,
                        knownCount = bestKnown,
                        totalCount = total,
                    }
                end
            end
        end
        return out
    end,
})

-- Read a char's skill-line: normalized alias first (recipes-DB), then raw expansion name.
local function _charSkillLine(char, profName, expAlias, expName)
    local prof = char.professions and char.professions[profName]
    if not (prof and prof.skillLines) then return nil end
    return prof.skillLines[expAlias] or prof.skillLines[expName]
end

-- "undertrained" = progressed past 0 but not yet capped.
local function _isCharUndertrained(sl)
    return sl and sl.current and sl.max
        and sl.current > 0 and sl.current < sl.max
end

-- Undertrained chars for one (profession, expansion): { charName, current, max }[].
local function _collectUndertrainedChars(chars, profName, expName)
    local list = {}
    local expAlias = HDG.Expansion.NormalizeAlias(expName) or expName
    for charKey, char in pairs(chars) do
        local sl = _charSkillLine(char, profName, expAlias, expName)
        if _isCharUndertrained(sl) then
            list[#list + 1] = {
                charName = char.name or charKey,
                current  = sl.current,
                max      = sl.max,
            }
        end
    end
    return list
end

-- Chars needing training per (profession, expansion): [profName][expName] = [{charName, current, max}].
Selectors:Register("trainers.charsNeedingByProfExp", {
    reads = {"account.characters", "session.resolvers.staticData.tick"},
    fn = function(state)
        local out      = {}
        local trainers = HDG.StaticData.Trainers:GetAll() or {}
        local chars    = state.account.characters
        for profName, profData in pairs(trainers) do
            local byExp = {}
            for expName in pairs(profData) do
                local list = _collectUndertrainedChars(chars, profName, expName)
                if #list > 0 then byExp[expName] = list end
            end
            if next(byExp) then out[profName] = byExp end
        end
        return out
    end,
})

-- ============================================================================
-- Trainer row helpers
-- ============================================================================

-- Parse "Zone Name [x.x, y.y]" -> (zoneNameEnUS, x, y). Returns (loc, nil, nil) when no coords.
local function parseLocation(loc)
    if not loc or loc == "" then return nil, nil, nil end
    local zone, x, y = loc:match("^(.-)%s*%[(.-),%s*(.-)%]%s*$")
    if not (zone and x and y) then return loc, nil, nil end
    local xn, yn = tonumber(x), tonumber(y)
    return zone, xn, yn
end

local function expansionDisplayOrder()
    local out = {}
    if HDG.Constants.EXPANSION_DATA then
        for _, e in ipairs(HDG.Constants.EXPANSION_DATA) do
            out[#out + 1] = e.display
        end
    end
    return out
end

-- ============================================================================
-- Main TreeList feed: trainers.sectionRows
-- ============================================================================
-- factionData is irregular: single-trainer = {npcID,...}; multi = list. Normalize to list.
local function _normalizeFactionTrainers(factionData)
    if factionData.npcID then return { factionData } end
    return factionData
end

-- Search filter: empty = all; otherwise case-insensitive substring on name + location.
local function _trainerMatchesQuery(trainer, query)
    if query == "" then return true end
    local nameMatch = trainer.name and trainer.name:lower():find(query, 1, true)
    local zoneEnUS  = trainer.location and trainer.location:lower()
    local zoneMatch = zoneEnUS and zoneEnUS:find(query, 1, true)
    return (nameMatch ~= nil) or (zoneMatch ~= nil)
end

-- Build one trainerRow envelope from the raw trainer record.
local function _buildTrainerRow(trainer, profName, expName, faction)
    local zone, x, y = parseLocation(trainer.location)
    return {
        kind     = "trainerRow",
        profName = profName,
        expName  = expName,
        faction  = faction,
        npcID    = trainer.npcID,
        dbName   = trainer.name,
        note     = trainer.note,
        zoneEnUS = zone,
        -- resolved here, not at click: the Map button shows only when it can map
        mapID    = zone and HDG.ZoneNameResolver.ZONE_MAP_IDS[zone],  -- exception(nullable): curated table; a zone it lacks maps nowhere
        x        = x,
        y        = y,
    }
end

-- Walk one expansion's faction map, collecting trainerRow envelopes for
-- every trainer matching the search query.
local function _collectTrainerRowsForExp(expData, query, profName, expName)
    local rows = {}
    for faction, factionData in pairs(expData) do
        for _, trainer in ipairs(_normalizeFactionTrainers(factionData)) do
            if _trainerMatchesQuery(trainer, query) then
                rows[#rows + 1] = _buildTrainerRow(trainer, profName, expName, faction)
            end
        end
    end
    return rows
end

-- Append expSection header + trainer rows. Empty expansions shown when query is empty
-- (user expects the structure to be visible even for empty buckets).
local function _appendExpSection(out, profName, expName, expData, query, profNeeds)
    local trainerRows = _collectTrainerRowsForExp(expData, query, profName, expName)
    if #trainerRows == 0 and query ~= "" then return end
    out[#out + 1] = {
        kind         = "expSection",
        profName     = profName,
        expName      = expName,
        charsNeeding = profNeeds[expName],
    }
    for _, row in ipairs(trainerRows) do out[#out + 1] = row end
end

-- Build one profHeader row envelope.
local function _buildProfHeaderRow(profEntry, counts, topByProf, expanded)
    local profName = profEntry.profName
    return {
        kind           = "profHeader",
        profName       = profName,
        knownByCurrent = profEntry.knownByCurrent,
        trainerCount   = counts[profName] or 0,  -- exception(boundary): sparse map
        topCrafter     = topByProf[profName],
        expanded       = expanded[profName] == true,
    }
end

-- Walk all expansions for one expanded profession, appending expSection + trainerRow envelopes.
local function _appendProfExpansions(out, profName, query, expOrder, profNeeds)
    local profData = HDG.StaticData.Trainers:GetByProfession(profName) or {}
    for _, expName in ipairs(expOrder) do
        local expData = profData[expName]
        if expData then
            _appendExpSection(out, profName, expName, expData, query, profNeeds)
        end
    end
end

Selectors:Register("trainers.sectionRows", {
    reads = {
        "session.resolvers.staticData.tick",
        "session.ui.trainers.searchQuery",
        "session.ui.trainers.expandedProfessions",
        "account.characters",
    },
    calls = {
        "trainers.profSectionsOrdered",
        "trainers.topDecorCrafterByProf",
        "trainers.charsNeedingByProfExp",
        "trainers.trainerCountsByProf",
    },
    fn = function(state, ctx)
        local profs     = Selectors:Call("trainers.profSectionsOrdered", state, ctx)
        local topByProf = Selectors:Call("trainers.topDecorCrafterByProf", state, ctx)
        local needsBy   = Selectors:Call("trainers.charsNeedingByProfExp", state, ctx)
        local counts    = Selectors:Call("trainers.trainerCountsByProf", state, ctx)
        local expanded  = state.session.ui.trainers.expandedProfessions
        local query     = state.session.ui.trainers.searchQuery:lower()
        local expOrder  = expansionDisplayOrder()
        local out = {}
        for _, profEntry in ipairs(profs) do
            local profName = profEntry.profName
            out[#out + 1] = _buildProfHeaderRow(profEntry, counts, topByProf, expanded)
            if expanded[profName] then
                _appendProfExpansions(out, profName, query, expOrder, needsBy[profName] or {})
            end
        end
        return out
    end,
})

-- ============================================================================
-- Midnight Recipe Sources sub-section.
-- ============================================================================
-- Vendor recipes: NPC name/zone/coords from VendorAugment (vendors[1].npcID).
-- Non-vendor: flat recipeSource fields. Source-column color applied in controller.
--
-- Which flat field names the teacher, per type: a trainer entry stores the NPC in
-- `npc` (and its fee in `cost`), a discovery its `method`, a quest its `quest`, and
-- drop/event entries `source`. Reading `source` for all of them left every trainer,
-- discovery and quest Midnight recipe showing "--" (2026-10-15).
local ORIGIN_FIELD = { trainer = "npc", discovery = "method", quest = "quest" }

local function _buildMidnightRow(itemID, entry)
    local rs  = entry.recipeSource
    local row = {
        kind       = "midnightRow",
        itemID     = itemID,
        recipeName = entry.name or ("recipe " .. itemID),
        sourceType = rs.type or "?",
        npcOrigin  = "--",
        zone       = "--",
        costLine   = "",
    }
    if rs.type == "vendor" then
        local v    = rs.vendors[1]
        local meta = HDG.StaticData.VendorAugment:Get(v.npcID)  -- exception(boundary): generated augment
        if meta then
            row.npcOrigin           = meta.name
            row.zone                = meta.zone
            row.mapID, row.x, row.y = meta.mapID, meta.x, meta.y
        end
        -- Missing meta keeps the "--" placeholders; the VendorAugment gap is
        -- warned once by HDG.StaticData's recipe-index cross-check.
        row.costLine = HDG.Format.FormatVendorCost(v.cost)
    else
        -- Drop / discovery / quest / trainer / event: flat recipeSource fields.
        row.npcOrigin = rs[ORIGIN_FIELD[rs.type] or "source"] or "--"  -- exception(nullable): ORIGIN_FIELD lists only the types that differ; the origin itself is optional
        row.zone      = rs.zone   or "--"
        -- A trainer's fee is a curated string ("60g training fee"); no other flat type has one.
        if rs.type == "trainer" then row.costLine = rs.cost end
    end
    return row
end

Selectors:Register("trainers.midnightRecipeRows", {
    reads = {"session.resolvers.staticData.tick", "session.ui.trainers.midnightExpanded"},
    fn = function(state)
        -- Read staticData.tick unconditionally so the declaration exercises on the collapsed path.
        local _ = state.session.resolvers.staticData.tick
        local rows = {}
        rows[#rows + 1] = {
            kind     = "midnightHeader",
            expanded = state.session.ui.trainers.midnightExpanded == true,
        }
        if not state.session.ui.trainers.midnightExpanded then return rows end

        -- Group Midnight recipes by profession.
        local decorDB = HDG.StaticData.Recipes:GetAll()
        local byProf  = {}
        for itemID, entry in pairs(decorDB) do
            if entry.expansion and entry.expansion:find("^Midnight") and entry.recipeSource then
                local prof = entry.profession or "?"
                byProf[prof] = byProf[prof] or {}
                local list = byProf[prof]
                list[#list + 1] = { itemID = itemID, entry = entry }
            end
        end

        local profOrder = {}
        for prof in pairs(byProf) do profOrder[#profOrder + 1] = prof end
        table.sort(profOrder)

        -- Per profession: sub-header + column header + recipe rows.
        for _, prof in ipairs(profOrder) do
            local list = byProf[prof]
            table.sort(list, function(a, b)
                local sa = a.entry.recipeSource.skill or 0
                local sb = b.entry.recipeSource.skill or 0
                if sa ~= sb then return sa < sb end
                return (a.entry.name or "") < (b.entry.name or "")
            end)
            rows[#rows + 1] = { kind = "midnightProfHeader",   profName = prof }
            rows[#rows + 1] = { kind = "midnightColumnHeader", profName = prof }
            for _, m in ipairs(list) do
                rows[#rows + 1] = _buildMidnightRow(m.itemID, m.entry)
            end
        end
        return rows
    end,
})

-- Composite feed: sectionRows + midnightRecipeRows.
Selectors:Register("trainers.allRows", {
    reads = {
        "session.resolvers.staticData.tick",
        "session.ui.trainers.searchQuery",
        "session.ui.trainers.expandedProfessions",
        "session.ui.trainers.midnightExpanded",
        "account.characters",
    },
    calls = {"trainers.sectionRows", "trainers.midnightRecipeRows"},
    fn = function(state, ctx)
        local out = {}
        for _, row in ipairs(Selectors:Call("trainers.sectionRows", state, ctx)) do
            out[#out + 1] = row
        end
        for _, row in ipairs(Selectors:Call("trainers.midnightRecipeRows", state, ctx)) do
            out[#out + 1] = row
        end
        return out
    end,
})
