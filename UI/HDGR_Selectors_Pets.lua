-- HDGR_Selectors_Pets.lua
-- ============================================================================
-- Pure selectors for the Pets browser -- a top-filter MODE of the Decor tab, not
-- a view of its own. So its selection lives in the decor session bucket
-- (session.ui.decor.selectedSpeciesID, invariant 16) and its panels borrow the
-- decor view's `body` and `detail` cells rather than declaring a view.
--
-- Every selector that reaches PetObserver declares
--   reads = { "session.resolvers.pets.tick" }
-- That tick is the re-pull signal for the observer's module-local index of
-- decor-attachable pets (Species-A facade-poll, HDGR_Resolvers.lua). The
-- semantic sweep's resolver-facade rule cross-checks facade against required
-- reads, so dropping the tick fails the gate rather than going stale in silence.

local Selectors = HDG.Selectors

-- Pets mode is the "pets" top filter -- ONE source of truth for it, composed by
-- both browser gates and every pets selector.
Selectors:Register("pets.isMode", {
    calls = { "decor.topFilter" },
    fn = function(state, ctx)
        return Selectors:Call("decor.topFilter", state, ctx) == "pets"
    end,
})

Selectors:Register("pets.selectedSpeciesID", {
    memoized = true,
    reads = { "session.ui.decor.selectedSpeciesID" },
    fn = function(state, ctx)
        return state.session.ui.decor.selectedSpeciesID
    end,
})

-- Two decimals is the shipped precision. A nil height renders EMPTY rather than
-- "0.00" or "?": the bind-pose measurement either exists for a species or it
-- does not, and there is nothing honest to put in its place.

-- One index entry -> row envelope. Everything the row factory paints is stamped
-- HERE so it never dives into state or the observer mid-paint (cookbook 03).
-- No `selected` on the row: the list's SelectionBehaviorMixin stamps that onto
-- the element itself, and the controller re-syncs it from the Store after any
-- re-push. Baking it here made every click rebuild all ~1,950 envelopes to flip
-- one boolean (1.9 MB a click, 2026-09-13 allocation audit). Same shape as
-- decor.items and acq.items.
local function _petRow(entry, families)
    return {
        speciesID   = entry.speciesID,
        petID       = entry.petID,
        displayName = entry.displayName,
        icon        = entry.icon,
        familyLabel = families[entry.petType],   -- exception(nullable): an unknown petType has no family string
        height      = entry.height,
    }
end

-- The pet list. The observer already sorted by height, so this does NOT re-sort:
-- search narrows on the displayed name, the active tag narrows by family.
Selectors:Register("pets.items", {
    memoized = true,
    reads = { "session.resolvers.pets.tick", "session.ui.decor.searchQuery" },
    calls = { "decor.activeTag" },
    fn = function(state, ctx)
        local entries    = HDG.PetObserver:GetAttachable()
        local families   = HDG.PetObserver:GetFamilies()
        local activeTag  = Selectors:Call("decor.activeTag", state, ctx)
        local q          = state.session.ui.decor.searchQuery
        local needle     = q ~= "" and q:lower() or nil

        local out = {}
        for i = 1, #entries do
            local row = _petRow(entries[i], families)
            local nameOk   = not needle or row.displayName:lower():find(needle, 1, true) ~= nil
            local familyOk = not activeTag or row.familyLabel == activeTag
            if nameOk and familyOk then out[#out + 1] = row end
        end
        return out
    end,
})

Selectors:Register("pets.hasItems", {
    calls = { "pets.items" },
    fn = function(state, ctx)
        return #Selectors:Call("pets.items", state, ctx) > 0
    end,
})

-- Blank state: pets mode is on but search / family matched nothing.
Selectors:Register("pets.isBlank", {
    calls = { "pets.isMode", "pets.hasItems" },
    fn = function(state, ctx)
        return Selectors:Call("pets.isMode", state, ctx)
           and not Selectors:Call("pets.hasItems", state, ctx)
    end,
})

Selectors:Register("pets.headerLabel", {
    memoized = true,
    reads = { "session.resolvers.pets.tick" },
    calls = { "pets.items" },
    fn = function(state, ctx)
        local shown = #Selectors:Call("pets.items", state, ctx)
        local total = #HDG.PetObserver:GetAttachable()
        if shown == total then return HDG.Locale:Get("PETS_COUNT"):format(total) end
        return HDG.Locale:Get("PETS_COUNT_FILTERED"):format(shown, total)
    end,
})

-- ===== Browser gates ========================================================
-- The decor body cell holds both list panels; exactly one may be visible. Composed
-- here rather than inline because a panel's `visible` takes a single selector
-- name, and because decor.hasItems must keep meaning "the decor list is non-empty"
-- rather than quietly absorbing a mode.
Selectors:Register("decor.showPetBrowser", {
    calls = { "pets.isMode", "pets.hasItems" },
    fn = function(state, ctx)
        return Selectors:Call("pets.isMode", state, ctx)
           and Selectors:Call("pets.hasItems", state, ctx)
    end,
})

-- Short-circuits on mode BEFORE asking decor.hasItems, so switching to Pets does
-- not depend on catalog state -- the decor browser goes away even mid-sweep.
Selectors:Register("decor.showDecorBrowser", {
    calls = { "pets.isMode", "decor.hasItems" },
    fn = function(state, ctx)
        if Selectors:Call("pets.isMode", state, ctx) then return false end
        return Selectors:Call("decor.hasItems", state, ctx)
    end,
})

-- The DETAIL column's gate is mode alone, deliberately NOT showDecorBrowser: the
-- decor detail pane must keep standing when the decor list is empty (that is what
-- its "Click an item" placeholder is for). Only pets mode takes the cell away.
Selectors:Register("decor.showDecorDetail", {
    calls = { "pets.isMode" },
    fn = function(state, ctx)
        return not Selectors:Call("pets.isMode", state, ctx)
    end,
})

-- ===== Detail pane ==========================================================
-- Thin projections over the selected species; each returns the finished display
-- string (ADR-022), so no widget formats anything.
Selectors:Register("pets.selectedPet", {
    memoized = true,
    reads = { "session.resolvers.pets.tick" },
    calls = { "pets.selectedSpeciesID" },
    fn = function(state, ctx)
        local id = Selectors:Call("pets.selectedSpeciesID", state, ctx)
        if not id then return nil end
        return HDG.PetObserver:GetBySpecies(id)   -- exception(nullable): a caged pet can vanish between paints
    end,
})

-- The name and family lines are NOT registered here. Both hosts of the shared
-- card read them off the card family (HDGR_Selectors_Menagerie, RegisterCardFamily)
-- so the two panes cannot drift apart a word at a time. `pets.selectedPet` is
-- what this file contributes to that family -- the selection, not its rendering.

-- ===== Summon / Dismiss =====================================================
-- Ported from VPP, whose comments record what it cost to get right. Four rules,
-- each one a bug that shipped there first:
--
--   1. The LABEL comes from the LATCHED guid, never a live GetSummonedPetGUID --
--      that API reads nil for up to 1.5s after a summon, so a paint driven by the
--      click reads the window instead of the result.
--   2. The controller does NOT repaint after clicking. COMPANION_UPDATE fires in
--      the same frame with the new state (measured, not assumed), and repainting
--      on click would read the state being left.
--   3. Dismiss is SummonPetByGUID(sameGUID) -- a toggle, not a second API.
--   4. Summonability is ASKED. The client refuses in a pet battle, on a vehicle,
--      or in a restricted area.

-- Which owned copy the button acts on. The exemplar petID for the selected
-- species -- the same copy the row shows, so the button and the row agree.
Selectors:Register("pets.selectedPetID", {
    calls = { "pets.selectedPet" },
    fn = function(state, ctx)
        local p = Selectors:Call("pets.selectedPet", state, ctx)
        return p and p.petID or nil
    end,
})

Selectors:Register("pets.isSelectedSummoned", {
    memoized = true,
    reads = { "session.resolvers.pets.tick" },
    calls = { "pets.selectedPetID" },
    fn = function(state, ctx)
        local petID = Selectors:Call("pets.selectedPetID", state, ctx)
        if not petID then return false end
        return HDG.PetObserver:GetSummonedGUID() == petID
    end,
})

Selectors:Register("pets.summonLabel", {
    calls = { "pets.isSelectedSummoned" },
    fn = function(state, ctx)
        return HDG.Locale:Get(Selectors:Call("pets.isSelectedSummoned", state, ctx)
               and "PETS_DISMISS" or "PETS_SUMMON")
    end,
})

-- Already-out always allows Dismiss; otherwise the client decides. Live read
-- behind the facade, gated by the tick (ADR-031, as AchievementObserver:IsEarned).
Selectors:Register("pets.summonEnabled", {
    reads = { "session.resolvers.pets.tick" },
    calls = { "pets.selectedPetID", "pets.isSelectedSummoned" },
    fn = function(state, ctx)
        local petID = Selectors:Call("pets.selectedPetID", state, ctx)
        if not petID then return false end
        if Selectors:Call("pets.isSelectedSummoned", state, ctx) then return true end
        return HDG.PetObserver:IsSummonable(petID)
    end,
})

Selectors:Register("pets.hasSelection", {
    calls = { "pets.selectedPetID" },
    fn = function(state, ctx)
        return Selectors:Call("pets.selectedPetID", state, ctx) ~= nil
    end,
})
