-- HDGR_Selectors_Menagerie.lua
-- ============================================================================
-- Pure selectors for the Menagerie (House > Pets). Spec: HDGR_PET_TAXONOMY_SPEC
-- rulings 1-14; architecture: HDGR_MENAGERIE_LATTICE_PLAN_2026-08-24.
--
-- Namespaced `menagerie.*` (not `pets.*`) because the shipped Decor-tab pets
-- mode owns those names; the two surfaces converge at plan phase 5.
--
-- The impure edges live in the CONTROLLER by design: playing an animation or a
-- voice (SetAnimation / PlaySound). Selectors here emit ids and data only. PetFacts rides the staticData tick; the journal rides
-- the pets tick.

local Selectors = HDG.Selectors
local M = function() return HDG.Constants.MENAGERIE end

-- ===== small pure helpers (no Selectors:Call inside -- keep `calls` honest) ==

local function _bucketOf(height)
    if not height then return nil end   -- exception(nullable): unmeasured species; card shows "?"
    for _, b in ipairs(M().SIZE_BUCKETS) do
        if height <= b.max then return b end
    end
end

-- The join keys a pet contributes (spec section 5, v1 subset): clade motif +
-- family motif where the family genuinely adds one. Pure data from baked fields.
local function _motifsOf(row)
    local out, meta = {}, row.clade and M().CLADE_META[row.clade]
    if meta then out[#out + 1] = meta.motif end
    local fam = M().FAMILY_MOTIF[row.petType]
    if fam and fam ~= (meta and meta.motif) then out[#out + 1] = fam end
    return out
end

-- The CURATED axes: the ones whose values are hand-written lists of kinds with a
-- weight, rather than a field read off the pet. Room asks what a pet is FOR,
-- Mood asks what it LOOKS like; the machinery is identical, so it is written
-- once and the axis names which table it reads.
local CURATED = { room = "ROOMS", mood = "MOODS" }

-- Entry lookup, indexed once per axis. Pure derivation from Constants -- a
-- lookup table, not state: nothing dispatches it and nothing invalidates it.
-- The index is keyed to the SOURCE table it was built from, so a Constants
-- table that is swapped wholesale (the test seam) rebuilds instead of serving
-- a stale answer -- the same guard StaticData keeps on its pet indexes.
local _curatedIndex, _curatedSource = {}, {}
local function _curatedFor(axis, key)
    local field = CURATED[axis]
    if not field then return nil end   -- exception(nullable): clade / family / size read the pet directly
    local tbl = M()[field]
    if _curatedSource[axis] ~= tbl then
        local idx = {}
        for _, e in ipairs(tbl) do idx[e.key] = e end
        _curatedIndex[axis], _curatedSource[axis] = idx, tbl
    end
    return _curatedIndex[axis][key]   -- exception(nullable): "all", or a key no entry owns
end

-- How well this pet suits that room or mood, or nil for "not on the list". The
-- weight is both the membership test and the sort key -- one number, one
-- curated source, so a list and its order can never disagree.
local function _curatedWeight(row, axis, key)
    local entry = _curatedFor(axis, key)
    if not entry or not row.kind then return nil end  -- exception(nullable): post-build species carries no kind
    return entry.kinds[row.kind]
end

local function _matchesAxis(row, ui)
    if ui.axval == "all" then return true end
    if ui.axis == "clade" then return row.clade == ui.axval end
    if ui.axis == "family" then return row.petType == ui.axval end
    if ui.axis == "size" then
        local b = _bucketOf(row.height)
        return b ~= nil and b.key == ui.axval
    end
    if CURATED[ui.axis] then return _curatedWeight(row, ui.axis, ui.axval) ~= nil end
    return false
end

-- ===== the list =============================================================
-- The row factory paints name + kind ONLY (ruling 13: no size on rows; scale
-- lives in the scene), plus the fit under a ranking axis. Everything it paints is
-- on the row, so it never dives into state mid-paint (cookbook 03).
-- No `selected` stamped here: the list's Intrusive SelectionBehavior writes it
-- onto the row and the controller re-syncs it from the Store after a re-push.
-- Baking it made every click rebuild the whole list to flip one boolean (1 MB a
-- click, 2026-09-13 allocation audit).
--
-- Rows are reused across rebuilds, one per species, the same way and for the
-- same reason as decor.items: a fresh ~0.5 KB envelope per pet cost ~1 MB a
-- build (first Menagerie visit, 2026-10-21), and every search keystroke and
-- axis change builds again. A row holds only what is its own and reads the
-- pet's fields (speciesID, displayName, ...) through to its index entry, so the
-- list's writes land on the row, never on the entry. Safe for the reason
-- decor.items gives: nothing keeps an older result, and the list refills from
-- the new array each compute. Weak values: the rows go when the list lets go.
local _rowsBySpecies = setmetatable({}, { __mode = "v" })
local ROW_META = { __index = function(row, key) return row._pet[key] end }

-- Nil is written only over a field the row HAS: WoW's Lua 5.1 inserts the key of
-- `row.k = nil` when the row lacks it, and a full two-field row doubles to make
-- room. Writing weight/fit/selected unconditionally cost ~300 KB a build
-- (measured 731 KB against ~490 predicted, 2026-10-21).
local function _menagerieRow(pet, weight)
    local kindLabel = pet.kind or "?"   -- exception(nullable): post-build species -- "?" is the honest mark
    local row = _rowsBySpecies[pet.speciesID]
    if row then
        row._pet, row.kindLabel = pet, kindLabel
        if rawget(row, "selected") ~= nil then row.selected = nil end
    else
        row = setmetatable({ _pet = pet, kindLabel = kindLabel }, ROW_META)
        _rowsBySpecies[pet.speciesID] = row
    end
    -- Only a ranking axis (a room or a mood) ranks, so only its rows say how
    -- well they fit. The weight itself never reaches the paint: the player is
    -- owed the judgement ("belongs here"), not the number behind it.
    if weight ~= nil or rawget(row, "weight") ~= nil then
        row.weight = weight
        row.fit    = weight and HDG.Locale:Get(M().ROOM_FIT[weight]) or nil
    end
    return row
end

Selectors:Register("menagerie.items", {
    memoized = true,
    reads = { "session.ui.menagerie.axis", "session.ui.menagerie.axval",
              "session.ui.menagerie.search",
              "session.resolvers.pets.tick", "session.resolvers.staticData.tick" },
    fn = function(state)
        local ui = state.session.ui.menagerie
        local out = {}
        -- Search matches the NAME the player sees OR the row's kind. Matching the
        -- kind is the whole point: "squirrel" is a kind, not a pet name, and the
        -- chip row can never carry all 712 of them. The row already displays its
        -- kind, so what you can read you can also type.
        local needle = ui.search ~= "" and ui.search:lower() or nil
        -- A curated axis RANKS; clade / family / size are plain either-or and
        -- stay in the observer's name order.
        local ranked = CURATED[ui.axis] ~= nil and ui.axval ~= "all"

        for _, row in ipairs(HDG.PetObserver:GetAttachable()) do
            local keep, weight
            if ranked then
                weight = _curatedWeight(row, ui.axis, ui.axval)
                keep = weight ~= nil
            else
                keep = _matchesAxis(row, ui)
            end
            if keep and needle then
                keep = row.displayName:lower():find(needle, 1, true) ~= nil
                    or (row.kind and row.kind:lower():find(needle, 1, true) ~= nil)
            end
            if keep then out[#out + 1] = _menagerieRow(row, weight) end
        end

        if ranked then
            -- Best first, then by name. table.sort is NOT stable in Lua, so the
            -- name tie-break is what makes the order total -- without it two pets
            -- of equal weight swap places between repaints.
            table.sort(out, function(x, y)
                if x.weight ~= y.weight then return x.weight > y.weight end
                return x.displayName < y.displayName
            end)
        end
        return out
    end,
})

Selectors:Register("menagerie.headerLabel", {
    calls = { "menagerie.items" },
    reads = { "session.resolvers.pets.tick" },
    fn = function(state, ctx)
        local shown = #Selectors:Call("menagerie.items", state, ctx)
        local total = #HDG.PetObserver:GetAttachable()
        return string.format("%d of %d", shown, total)
    end,
})

-- ===== the two-row filter ===================================================
-- Kinds and clades are stored lowercase (they come from model-folder stems);
-- the chip is the only place they are ever shown to a player.
local function _titleCase(word)
    return (word:gsub("^%l", string.upper))
end

-- ===== kind suggestions =====================================================
-- The 712-kind vocabulary, reachable by typing. A chip row cannot hold it (the
-- drill tried and drew over the list) but the SEARCH bounds it: suggestions only
-- exist once you type, and only the handful that match.
--
-- PREFIX match, not substring: typing narrows predictably s -> sq -> squ, which
-- is the behaviour being asked for. Substring would keep "sporebat" alive under
-- "bat" and make the row jump around as you type.
--
-- Counted over the PLAYER's attachable pets, so a suggestion never leads to an
-- empty list.
-- SIX, not ten. The row is two chip-lines tall and kind stems run long
-- ("squirrelardenweald"), so a larger cap does not fit more suggestions -- it
-- just wraps them out of the box and over the clade row below, which is the
-- same overflow that killed the drill. Narrow by typing another letter.
local SUGGEST_MAX = 6

Selectors:Register("menagerie.kindSuggestions", {
    memoized = true,
    reads = { "session.ui.menagerie.search", "session.resolvers.pets.tick" },
    fn = function(state)
        local q = state.session.ui.menagerie.search
        if q == "" then return {} end          -- nothing typed, nothing offered
        q = q:lower()
        local counts = {}
        for _, row in ipairs(HDG.PetObserver:GetAttachable()) do
            local k = row.kind
            if k and k:lower():sub(1, #q) == q then counts[k] = (counts[k] or 0) + 1 end
        end
        local keys = {}
        for k in pairs(counts) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if counts[a] ~= counts[b] then return counts[a] > counts[b] end
            return a < b
        end)
        local out = {}
        for i = 1, math.min(#keys, SUGGEST_MAX) do
            local k = keys[i]
            out[i] = { group = "suggest", value = k, label = _titleCase(k),
                       count = counts[k], active = q == k:lower() }
        end
        return out
    end,
})

-- Visibility gate: the row collapses entirely when there is nothing to suggest,
-- so an untouched search box costs the list no height.
Selectors:Register("menagerie.hasKindSuggestions", {
    calls = { "menagerie.kindSuggestions" },
    fn = function(state, ctx)
        return #Selectors:Call("menagerie.kindSuggestions", state, ctx) > 0
    end,
})

Selectors:Register("menagerie.axes", {
    reads = { "session.ui.menagerie.axis" },
    fn = function(state)
        local out = {}
        for _, a in ipairs(M().AXES) do
            out[#out + 1] = { group = "axis", value = a.value, label = a.label,
                              active = a.value == state.session.ui.menagerie.axis }
        end
        return out
    end,
})

-- Row two: the axis's values, full stop.
--
-- Kind briefly lived here as a SECOND LEVEL -- pick a clade, get its kinds --
-- to reach the 712-kind tail that a flat top-N could never show. It was
-- reverted (owner, 2026-08-25): a clade's kind list is not row-sized. Beast
-- carries 438 species across 114 kinds, and chipStrip grows to fit rather than
-- clipping, so the row drew straight over the pet list. Fifteen clades fit;
-- their kinds do not, at any nesting depth, without a different surface than
-- a chip row.
Selectors:Register("menagerie.axisValues", {
    memoized = true,
    reads = { "session.ui.menagerie.axis", "session.ui.menagerie.axval",
              "session.resolvers.pets.tick", "session.resolvers.staticData.tick" },
    fn = function(state)
        local ui  = state.session.ui.menagerie
        local out = {}
        local function add(value, label, n)
            out[#out + 1] = { group = "axval", value = value, label = label,
                              count = n, active = ui.axval == value }
        end
        add("all", "All", nil)
        if ui.axis == "clade" then
            local counts = {}
            for _, row in ipairs(HDG.PetObserver:GetAttachable()) do
                if row.clade then counts[row.clade] = (counts[row.clade] or 0) + 1 end
            end
            local keys = {}
            for k in pairs(counts) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do add(k, _titleCase(k), counts[k]) end
        elseif ui.axis == "family" then
            for i, name in ipairs(HDG.PetObserver:GetFamilies()) do add(i, name, nil) end
        elseif ui.axis == "size" then
            for _, b in ipairs(M().SIZE_BUCKETS) do add(b.key, b.label, nil) end
        elseif CURATED[ui.axis] then
            -- Count YOUR pets per entry, so one that would open empty says so
            -- before the click. One pass over the collection builds the kind
            -- tally; the entries then read it, rather than each of twenty-one
            -- rooms re-walking 1,935 rows.
            local owned = {}
            for _, row in ipairs(HDG.PetObserver:GetAttachable()) do
                if row.kind then owned[row.kind] = (owned[row.kind] or 0) + 1 end
            end
            for _, entry in ipairs(M()[CURATED[ui.axis]]) do
                local n = 0
                for kind in pairs(entry.kinds) do n = n + (owned[kind] or 0) end
                add(entry.key, entry.label, n)
            end
        end
        return out
    end,
})

-- ===== the card =============================================================
Selectors:Register("menagerie.selected", {
    memoized = true,
    reads = { "session.ui.menagerie.selectedSpeciesID",
              "session.resolvers.pets.tick", "session.resolvers.staticData.tick" },
    fn = function(state)
        local sid = state.session.ui.menagerie.selectedSpeciesID
        if not sid then return nil end            -- exception(nullable): nothing picked yet
        local row = HDG.PetObserver:GetBySpecies(sid)
        if not row then return nil end            -- exception(nullable): selection outlived a journal rebuild
        return row
    end,
})

Selectors:Register("menagerie.hasSelection", {
    calls = { "menagerie.selected" },
    fn = function(state, ctx)
        return Selectors:Call("menagerie.selected", state, ctx) ~= nil
    end,
})

-- ===== the shared card family ==============================================
-- ONE registration loop serves BOTH hosts of the card (ruling 9): the
-- Menagerie view and the Decor tab's Pets mode. Everything downstream of a
-- selection -- card facts, behaviour flow, scene spec, chip adapters -- is
-- identical; only the selection lives per host. The scene CHOICES
-- (bed/plinth/You) are deliberately ONE shared transient
-- (session.ui.menagerie.scene): your staging setup follows you across tabs.
local function RegisterCardFamily(NS, SELECTED)

Selectors:Register(NS .. ".card.title", {
    calls = { SELECTED },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return HDG.Locale:Get("MENAGERIE_DETAIL_TITLE") end
        return p.displayName
    end,
})

Selectors:Register(NS .. ".card.family", {
    calls = { SELECTED },
    reads = { "session.resolvers.pets.tick" },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return "" end
        local fam = HDG.PetObserver:GetFamilies()[p.petType]  -- exception(nullable): unknown petType
        return fam and ("Family: " .. fam) or ""
    end,
})

Selectors:Register(NS .. ".card.howBig", {
    calls = { SELECTED },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return "" end
        local b = _bucketOf(p.height)
        if not b then return "?" end   -- unmeasured: the honest mark, never a guess (spec ruling 6)
        -- No "(you are N)" parenthetical. It was a second copy of
        -- PET_CHARACTER_HEIGHT written as a literal, and it overran the Decor
        -- host's 220px facts column -- the one line of the four that did. The
        -- player-sized comparison it was reaching for is what the scene's You
        -- chip IS (ruling 13), and the row tooltip still states it as numbers.
        return string.format("%s -- height %.2f", b.label, p.height)
    end,
})

Selectors:Register(NS .. ".card.needs", {
    calls = { SELECTED },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return "" end
        local meta = p.clade and M().CLADE_META[p.clade]
        return meta and meta.needs or "?"
    end,
})

Selectors:Register(NS .. ".card.matches", {
    calls = { SELECTED },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return "" end
        return table.concat(_motifsOf(p), "  ")
    end,
})

Selectors:Register(NS .. ".card.light", {
    calls = { SELECTED },
    reads = { "session.resolvers.staticData.tick" },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return "" end
        local prof = HDG.StaticData.PetFacts:AnimProfile(p.speciesID)
        local g = prof and prof.glow   -- exception(nullable): 6 unparsed models
        if not g then return "?" end
        if g[1] > 0 then return "carries a light -- it will illuminate its spot" end
        if g[3] > 0 or g[2] >= 3 then return "glows" end
        return "no glow"
    end,
})

-- ===== the behaviour flowchart (ruling 10: THE one behaviour surface) =======
-- Data only. Node labels come from the curated per-model table when eyeballed;
-- otherwise the honest fallback "Stand (variation N)" with unverified = true.
Selectors:Register(NS .. ".flow", {
    memoized = true,
    calls = { SELECTED },
    reads = { "session.resolvers.staticData.tick" },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return nil end   -- exception(nullable): card empty pre-selection
        local PF   = HDG.StaticData.PetFacts
        local prof = PF:AnimProfile(p.speciesID)
        if not prof then return nil end  -- exception(nullable): unparsed model; section hides
        local nodes = {}
        for _, e in ipairs(prof.idle) do
            local id, var, pct, ms = e[1], e[2], e[3], e[4]
            local key   = id .. ":" .. var
            local label = prof.labels and prof.labels[key]
            nodes[#nodes + 1] = {
                animID = id, variation = var, pct = pct, seconds = ms / 1000,
                label = label or (var == 0 and "Stand" or ("Stand (variation " .. var .. ")")),
                unverified = label == nil and var ~= 0,
            }
        end
        local voice = PF:Voice(p.speciesID)
        local voiceNode
        if voice then
            local cadence = voice.delayMin
                and string.format("every %d-%ds", voice.delayMin, voice.delayMax)
                or "now and then"
            -- No word. HDGR_PetVoiceDB's `word` is the CASC folder stem
            -- (sound/creature/<X>/), which is an English creature noun for about
            -- a third of the 286 voices and build debris for the rest
            -- ("bloodfangwidowspider", "revenant2_fire", "fx_grab_aura") -- and
            -- nothing here can tell the two apart. The player is looking at the
            -- pet besides; what they cannot see is that the voice is BORROWED,
            -- so sharedWith is the fact worth spending the line on.
            voiceNode = { cadence = cadence, kits = voice.kits, durs = voice.durs,
                          sharedWith = voice.sharedWith }
        end
        return { nodes = nodes, voice = voiceNode, also = prof.also }
    end,
})

-- ===== the scene ============================================================
Selectors:Register(NS .. ".scene", {
    calls = { SELECTED },
    reads = { "session.ui.menagerie.scene", "session.resolvers.staticData.tick",
              "session.resolvers.pets.tick" },
    fn = function(state, ctx)
        local p = Selectors:Call(SELECTED, state, ctx)
        if not p then return nil end   -- exception(nullable): empty stage pre-selection
        local ui = state.session.ui.menagerie.scene
        local decor
        if ui.decorID then
            local d = HDG.StaticData.PetFacts:SceneDecor()[ui.decorID]
            -- seatZ nil = no eyeballed seat for this decor yet; the stage falls
            -- back to the bounding-box top, which is right only for flat-topped
            -- decor (see Constants.MENAGERIE.SCENE_SEAT_Z).
            decor = { decorID = ui.decorID, file = d.file, name = d.name,
                      seatZ = M().SCENE_SEAT_Z[ui.decorID] }   -- exception(nullable): unmeasured decor keeps bbox-top
        end
        return {
            speciesID    = p.speciesID,
            petDisplayID = HDG.PetObserver:DisplayID(p.speciesID),   -- exception(nullable): a species with no display renders 2D fallback
            petHeight    = p.height,
            petScale     = HDG.StaticData.PetFacts:SceneScale(p.speciesID),
            petLift      = HDG.StaticData.PetFacts:SceneLift(p.speciesID),
            petGirth     = HDG.StaticData.PetFacts:SceneGirth(p.speciesID),
            decor        = decor,
            withYou      = ui.withYou == true,
        }
    end,
})

-- ===== scene strip chips ====================================================
Selectors:Register(NS .. ".sceneChips", {
    reads = { "session.ui.menagerie.scene", "session.resolvers.staticData.tick" },
    fn = function(state)
        local ui = state.session.ui.menagerie.scene
        local out = { { group = "scene", value = "none", label = "--", active = ui.decorID == nil } }
        local decor = HDG.StaticData.PetFacts:SceneDecor()
        for _, did in ipairs(M().SCENE_CHIP_DECOR) do
            out[#out + 1] = { group = "scene", value = did, label = decor[did].name,
                              active = ui.decorID == did }
        end
        out[#out + 1] = { group = "scene", value = "you", label = "You", active = ui.withYou == true }
        return out
    end,
})


-- The flowchart as one chip stream: phases in idle-mix order, then the voice.
Selectors:Register(NS .. ".flowChips", {
    calls = { NS .. ".flow" },
    fn = function(state, ctx)
        local flow = Selectors:Call(NS .. ".flow", state, ctx)
        if not flow then return {} end   -- exception(nullable): empty strip pre-selection
        local out = {}
        for _, n in ipairs(flow.nodes) do
            out[#out + 1] = { nodeType = "phase", label = n.label, pct = n.pct,
                              seconds = n.seconds, unverified = n.unverified,
                              animID = n.animID, variation = n.variation }
        end
        if flow.voice then
            -- durs travels WITH kits: the controller's sound bar fills over
            -- durs[i] for the kit it just played, so a chip carrying kits but
            -- no durations leaves the bar permanently at length zero.
            out[#out + 1] = { nodeType = "voice",
                              cadence = flow.voice.cadence, kits = flow.voice.kits,
                              durs = flow.voice.durs,
                              sharedWith = flow.voice.sharedWith }
        end
        return out
    end,
})

Selectors:Register(NS .. ".alsoChips", {
    calls = { NS .. ".flow" },
    fn = function(state, ctx)
        local flow = Selectors:Call(NS .. ".flow", state, ctx)
        if not flow or not flow.also then return {} end  -- exception(nullable): empty pre-selection
        -- SHOWABLE only: the repertoire carries dozens of combat/movement ids a
        -- player has no reason to click; unfiltered, Pandaren Monk's 40 chips
        -- overflowed the window (in-game smoke, 2026-08-24). Dedupe by verb --
        -- 71 and 100 are both "sleeps"; one chip serves.
        local out, seen = {}, {}
        for _, id in ipairs(flow.also) do
            local verb = M().SHOWABLE_ANIMS[id]
            if verb and not seen[verb] then
                seen[verb] = true
                out[#out + 1] = { group = "also", animID = id, label = verb }
            end
        end
        return out
    end,
})

-- Described ships HIDDEN in v1 (plan ruling): the gate is honest -- it opens when
-- a description DB exists, with no layout change. Today there is none.

end

RegisterCardFamily("menagerie", "menagerie.selected")

-- The Decor host feeds the SAME family off the selection selector it already
-- had (HDGR_Selectors_Pets, loaded first per the TOC). A second registration
-- reading the same decor id through the same observer would be one selector
-- under two names -- two memo caches to keep agreeing, and one of them silently
-- wrong the day the selection source moves.
RegisterCardFamily("pets", "pets.selectedPet")

Selectors:Register("menagerie.hasDescription", {
    reads = { "session.resolvers.staticData.tick" },
    fn = function() return false end,
})
