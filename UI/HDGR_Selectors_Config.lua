-- HDG.Selectors -- Mogul Config sub-view
-- ============================================================================
-- Price-source control panel: source preference pills, TSM mode pills, cache
-- freshness display, refresh-scan button label, owned-auctions stats.
-- Pure read-only views over state + module state. Price logic lives in HDG.PriceSource.

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors

-- ===== Source preference + availability ====================================
-- Active-state selectors per source. preferredPriceAddon nil = "Auto" fallback
-- chain (TSM > Auctionator > Direct > Vendor); pill highlights when pinned.
do
    local function activeSrc(target)
        return function(state)
            local pref = state.account.config.preferredPriceAddon
            return pref == target
        end
    end
    Selectors:Register("config.sourceActive_Auto", {
        reads = {"account.config.preferredPriceAddon"},
        fn = function(state) return state.account.config.preferredPriceAddon == nil end,
    })
    for _, src in ipairs({"TSM", "Auctionator", "Direct"}) do
        Selectors:Register("config.sourceActive_" .. src,
            { reads = {"account.config.preferredPriceAddon"}, fn = activeSrc(src) })
    end
end

-- TSM + Auctionator pills only show when the addon is loaded.
-- PriceSource:RefreshAddonAvailability snapshots _G probes into session.prices.*
-- on window-open, so these selectors stay pure (no _G probing mid-evaluation).
Selectors:Register("config.tsmAvailable", {
    reads = {"session.prices.tsmLoaded"},
    fn = function(state) return state.session.prices.tsmLoaded end,
})
Selectors:Register("config.auctionatorAvailable", {
    reads = {"session.prices.auctionatorLoaded"},
    fn = function(state) return state.session.prices.auctionatorLoaded end,
})

-- (TSM mode pills retired 2026-06: the Goblin-header source selector replaced the
-- Config auction section, and the per-mode UI was dropped. account.config.tsmPriceMode
-- remains for the price layer's default; nothing sets it any more.)

-- ===== Cache freshness display =============================================
Selectors:Register("config.cacheFreshnessLabel", {
    reads = {"account.prices.directCache", "account.prices.directCacheTime",
             "session.resolvers.prices.tick"},
    fn = function(state)
        local count = 0
        for _ in pairs(state.account.prices.directCache) do count = count + 1 end
        local ts = state.account.prices.directCacheTime
        if not ts then
            return string.format("Direct cache: %d items, never scanned", count)
        end
        local now = _G.time()  -- exception(boundary): wall-clock for "scanned N seconds ago" display
        return string.format("Direct cache: %d items, scanned %s",
            count, HDG.Format.RelativeTime(now - ts))
    end,
})

-- ===== Refresh-scan button label + enabled state ===========================
-- Label flips to "Scanning... N/M" in flight; enabled only when AH window
-- is open (boundary: C_AuctionHouse.SendBrowseQuery requires AH open).
Selectors:Register("config.scanButtonLabel", {
    reads = {"session.prices.scanning", "session.prices.scanFound",
             "session.prices.scanTotal"},
    fn = function(state)
        local s = state.session.prices
        if s.scanning then
            return string.format("Scanning... %d/%d", s.scanFound or 0, s.scanTotal or 0)
        end
        return "Refresh from AH"
    end,
})

-- ===== Special Thanks credits rows ==========================================
-- Static contributor list. No state reads needed; reads={} so the selector
-- memo never invalidates (the list never changes at runtime).
local _CREDITS_INTRO = "This addon wouldn't be possible without the amazing community. " ..
    "Special thanks to these contributors for their feedback, bug reports, and feature suggestions:"
local _CREDITS_OUTRO = "Want to contribute? Join us on Discord or report issues on CurseForge."

-- Alphabetically sorted by name (case-insensitive). Names with no verified
-- note have note=nil; the row factory renders name only in that case.
-- FLAG for Vamoose: Blixie / blue / Rosemaryn / Saffyre / Scubadog have no
-- confirmed notes -- please verify these are real contributors and supply notes.
local _CONTRIBUTORS = {
    { name = "Abased",        note = "Feature requests & testing" },
    { name = "Antrium",       note = "Feature requests (Frugal / sortable views)" },
    { name = "BaronKarza",    note = "Colorblind Safe theme suggestion & testing" },
    { name = "Blixie",        note = nil },
    { name = "Blue",          note = "Plot-facing maps & testing (used in the Move Planner)" },
    { name = "Boggle",        note = "Title-bar logo artwork & feature suggestion" },
    { name = "Castianna",     note = "Bug reports" },
    { name = "Daxxlia",       note = "Testing & feedback" },
    { name = "Discomanco",    note = "Warband grouping debugging & testing" },
    { name = "Edengonedark",  note = "Feature suggestions" },
    { name = "Filurina",      note = "Quality variant bug report" },
    { name = "Fracture93",    note = "Goblin Mode feature suggestion" },
    { name = "GnuclearGnome", note = "Bug reports & UI feedback" },
    { name = "Gravebait",     note = "Feature suggestions" },
    { name = "Hydra",         note = "Bug reports & testing" },
    { name = "JodouKast",     note = "Community support & feature ideas" },
    { name = "Katsmiaou",     note = "Feature suggestions" },
    { name = "KeeperHarvest", note = "Detailed vendor audit & bug reports" },
    { name = "Madailein",     note = "New HDG logo artwork (the house-and-spiral emblem)" },
    { name = "Medivha",       note = "Detailed trainer & vendor data audit" },
    { name = "Nunuman",       note = "Korean localization testing & bug reports" },
    { name = "pxspin",        note = "Found the bugs, dreamed up the features, never stopped testing" },
    { name = "ReganB",        note = nil },
    { name = "Rosemaryn",     note = nil },
    { name = "Rylls",         note = "Bug reports & UX feedback" },
    { name = "Saffyre",       note = nil },
    { name = "Scubadog",      note = nil },
    { name = "Tzunamis",      note = "Trainer NPC ID bug report" },
}

Selectors:Register("config.creditsRows", {
    reads = {},  -- static data; no state dependency
    fn = function(_state)
        local rows = {}
        rows[#rows + 1] = { kind = "creditIntro", text = _CREDITS_INTRO }
        for _, c in ipairs(_CONTRIBUTORS) do
            rows[#rows + 1] = { kind = "credit", name = c.name, note = c.note }
        end
        rows[#rows + 1] = { kind = "creditOutro", text = _CREDITS_OUTRO }
        return rows
    end,
})

