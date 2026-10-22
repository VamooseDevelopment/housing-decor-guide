-- HDGR_Selectors_Catalog.lua
-- Catalog lifecycle selectors. Per Lattice ADR-022, selectors stay pure
-- and just project state.session.catalog into convenience views.

local Selectors = HDG.Selectors

Selectors:Register("catalog.loadingStatus", {
    reads = { "session.catalog.status" },
    fn = function(state)
        return state.session.catalog.status
    end,
})

Selectors:Register("catalog.refreshPending", {
    reads = { "session.catalog.refreshPending" },
    fn = function(state)
        return state.session.catalog.refreshPending == true
    end,
})

Selectors:Register("catalog.resolverTick", {
    reads = { "session.resolvers.catalog.tick" },
    fn = function(state)
        return state.session.resolvers.catalog.tick
    end,
})

Selectors:Register("catalog.variantsLoaded", {
    reads = { "session.catalog.variantsLoaded" },
    fn = function(state)
        return state.session.catalog.variantsLoaded == true
    end,
})

-- Boolean gates for layout-level loading/content panel split.
-- `decorLoadingPanel.visible = "catalog.isLoading"` shows during idle/loading;
-- `decorPanel.visible = "catalog.isReady"` reveals content once sweep completes.
Selectors:Register("catalog.isLoading", {
    reads = { "session.catalog.status" },
    fn = function(state)
        local s = state.session.catalog.status
        return s == "idle" or s == "loading"
    end,
})

Selectors:Register("catalog.isReady", {
    reads = { "session.catalog.status" },
    fn = function(state)
        return state.session.catalog.status == "ready"
    end,
})

-- Error / not-ready: a sweep aborted (C_HousingCatalog unavailable, searcher
-- nil). Drives the "Catalog not loaded" data-state panel instead of a stuck
-- loading spinner.
Selectors:Register("catalog.isError", {
    reads = { "session.catalog.status" },
    fn = function(state)
        return state.session.catalog.status == "error"
    end,
})

