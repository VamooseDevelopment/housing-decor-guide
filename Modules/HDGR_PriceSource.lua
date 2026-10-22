-- HDG.PriceSource
-- ============================================================================
-- Price-source facade. Wraps TSM_API / Auctionator.API.v1 / a direct AH
-- browse scan / vendor-sell prices from HDGR_ReagentsDB.
--
-- Source priority (when state.account.config.preferredPriceAddon == nil):
--   1. TSM            (DBMinBuyout | DBMarket | DBRegionSaleAvg, per tsmPriceMode)
--   2. Auctionator    (Auctionator.API.v1.GetAuctionPriceByItemID)
--   3. Direct cache   (C_AuctionHouse browse scan into account.prices.directCache)
--   4. Vendor         (HDGR_ReagentsDB "Vendor:N" entries)
--
-- Pinned source ("TSM" / "Auctionator" / "Direct") is tried first; Vendor
-- is always the final fallback. We never silently return a Vendor floor
-- when the user explicitly wants AH.
--
-- All cache mutations flow through Store actions (PRICES_DIRECT_SCAN_*);
-- writes go via Dispatch -> reducer so persistence middleware marks the
-- bucket dirty and SavedVariables write follows.

HDG.Log:RegisterTags({ prices_scan = { user = false, level = "warn" } })

HDG = HDG or {}
HDG.PriceSource = HDG.PriceSource or {}
local P = HDG.PriceSource

-- Lazy-built vendor price cache from HDGR_ReagentsDB.
-- A reagent source of "Vendor:1500" yields a vendor copper price.
local _vendorPriceCache

local function buildVendorPriceCache()
    if _vendorPriceCache then return _vendorPriceCache end
    _vendorPriceCache = {}
    local Reagents = HDG.StaticData.Reagents
    for itemID in pairs(Reagents:GetAll()) do
        local copper = Reagents:Get(itemID):match("^Vendor:(%d+)$")
        if copper then
            _vendorPriceCache[itemID] = tonumber(copper)
        end
    end
    return _vendorPriceCache
end

local function getVendorPrice(itemID)
    return buildVendorPriceCache()[itemID]
end

-- Mock-TSM: debug toggle (/hdgr mocktsm or Advanced settings checkbox).
-- Makes IsTSMAvailable()=true and every TSM lookup return a flat 100g so
-- the TSM code path can be exercised without TSM installed. Config-backed
-- (account.config.mockTSM) -- single source of truth for both surfaces.
function P:IsMockTSM()
    return HDG.Store:GetState().account.config.mockTSM == true
end

-- Flat copper price returned for every TSM lookup while Mock TSM is on.
local MOCK_TSM_COPPER = 100 * 100 * 100   -- 100g

-- Source detectors. Call into globals; return false before detected addons load.
function P:IsTSMAvailable()
    if self:IsMockTSM() then return true end
    return _G.TSM_API and _G.TSM_API.GetCustomPriceValue and true or false
end

function P:IsAuctionatorAvailable()
    return _G.Auctionator and _G.Auctionator.API
       and _G.Auctionator.API.v1
       and _G.Auctionator.API.v1.GetAuctionPriceByItemID and true or false
end

-- ===== Per-source price lookups ============================================

local function getTSMPrice(itemID)
    if not P:IsTSMAvailable() then return nil end
    if P:IsMockTSM() then return MOCK_TSM_COPPER end
    local state = HDG.Store:GetState()
    local mode  = state.account.config.tsmPriceMode
    local key
    if     mode == "market" then key = "DBMarket"
    elseif mode == "region" then key = "DBRegionSaleAvg"
    else                         key = "DBMinBuyout"
    end
    local price = _G.TSM_API.GetCustomPriceValue(key, "i:" .. tostring(itemID))
    if type(price) == "number" and price > 0 then return price end
    return nil
end

local function getAuctionatorPrice(itemID)
    if not P:IsAuctionatorAvailable() then return nil end
    local price = _G.Auctionator.API.v1.GetAuctionPriceByItemID("HDG", itemID)
    if type(price) == "number" and price > 0 then return price end
    return nil
end

local function getDirectPrice(itemID)
    local state = HDG.Store:GetState()
    local p = state.account.prices.directCache[itemID]
    if type(p) == "number" and p > 0 then return p end
    return nil
end

-- ===== Public API ===========================================================
-- GetItemPrice(itemID [, forceSource])
--   forceSource: optional override ("TSM" | "Auctionator" | "Direct" | "Vendor")
-- Returns: copper, source ("TSM" | "Auctionator" | "Direct" | "Vendor" | nil)
function P:GetItemPrice(itemID, forceSource)
    if not itemID then return nil, nil end
    local preferred = forceSource
    if not preferred then
        preferred = HDG.Store:GetState().account.config.preferredPriceAddon
    end

    if     preferred == "TSM" then
        local p = getTSMPrice(itemID); if p then return p, "TSM" end
    elseif preferred == "Auctionator" then
        local p = getAuctionatorPrice(itemID); if p then return p, "Auctionator" end
    elseif preferred == "Direct" then
        local p = getDirectPrice(itemID); if p then return p, "Direct" end
    elseif preferred == "Vendor" then
        local p = getVendorPrice(itemID); if p then return p, "Vendor" end
    else
        -- Default fall-back chain: TSM > Auctionator > Direct > Vendor.
        local p = getTSMPrice(itemID); if p then return p, "TSM" end
        p = getAuctionatorPrice(itemID); if p then return p, "Auctionator" end
        p = getDirectPrice(itemID);      if p then return p, "Direct" end
    end

    -- Vendor floor is always the last resort regardless of pinned source.
    local v = getVendorPrice(itemID)
    if v then return v, "Vendor" end
    return nil, nil
end

-- Direct accessors for each TSM mode -- bypasses the preferredPriceAddon
-- chain so the Goblin tab can show all 3 TSM-mode columns side by side
-- regardless of which mode the user picked for Profit calc. Honors the
-- mock toggle (returns a flat 100g for every key when Mock TSM is on).
local function getTSMByKey(itemID, key)
    if not (itemID and P:IsTSMAvailable()) then return nil end
    if P:IsMockTSM() then return MOCK_TSM_COPPER end
    local price = _G.TSM_API.GetCustomPriceValue(key, "i:" .. tostring(itemID))
    if type(price) == "number" and price > 0 then return price end
    return nil
end

function P:GetTSMMinBuyout(itemID)   return getTSMByKey(itemID, "DBMinBuyout")     end
function P:GetTSMMarket(itemID)       return getTSMByKey(itemID, "DBMarket")        end
function P:GetRegionSaleAvg(itemID)   return getTSMByKey(itemID, "DBRegionSaleAvg") end

-- Region sale-velocity metrics. Both need TSM's region AuctionDB data (the TSM Desktop App
-- must be exporting AppData) or return nil. BOTH are sub-1 fractions for slow decor
-- (verified vs a live tooltip -- Animated Sin'dorei Hammer: SaleRate 0.032, AvgDailySold
-- 0.096), and GetCustomPriceValue rounds to a whole number -- so the bare source collapses
-- them to 0. We multiply inside the price string to keep precision past the round:
--   SaleRate   -> "1000 * DBRegionSaleRate" = rate x1000 (per-mille). Sale rate IS a
--                 percentage by definition (the % of postings that sell, always 0..1), so
--                 the row renders rate/10 as a 1-decimal % (0.032 -> 32 -> "3.2%").
--   SoldPerDay -> "1000 * DBRegionSoldPerDay" /1000 = real units/realm/day (0.096 -> "0.10").
function P:GetRegionSaleRate(itemID)
    local v = getTSMByKey(itemID, "1000 * DBRegionSaleRate")
    return v   -- per-mille; the row divides by 10 to show a 1-decimal percent
end
function P:GetRegionSoldPerDay(itemID)
    local v = getTSMByKey(itemID, "1000 * DBRegionSoldPerDay")
    return v and v / 1000 or nil
end

-- Units currently listed on the AH for this item, from the live Direct browse scan
-- (info.totalQuantity). nil = not yet scanned; 0 = scanned, none listed.
function P:GetDirectQty(itemID)
    if not itemID then return nil end
    return HDG.Store:GetState().account.prices.directQtyCache[itemID]
end

-- Writes config flag only; the subscriber reacts to account.config.mockTSM
-- invalidation to refresh availability + nudge price selectors (same path as
-- the Advanced checkbox, so both stay in sync).
function P:ToggleMockTSM()
    local new = not self:IsMockTSM()
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.CONFIG_SET,
        payload = { key = "mockTSM", value = new },
    })
    return new
end

-- Snapshot TSM / Auctionator availability into session state. Called on
-- MAIN_WINDOW_OPENING and ToggleMockTSM so Config selectors stay pure
-- (they read the state slot, not _G mid-evaluation).
function P:RefreshAddonAvailability()
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PRICES_ADDONS_AVAILABILITY_CHANGED,
        payload = {
            tsm         = self:IsTSMAvailable(),
            auctionator = self:IsAuctionatorAvailable(),
        },
    })
end

-- ===== Direct AH scan state machine ========================================
-- C_AuctionHouse browse-query pump. All cache writes flow through Store
-- actions; the module orchestrates the AH events.

local scanFrame
local scan = {
    active = false,
    needed = {},      -- [itemID] = true; items we want prices for
    found  = 0,
    total  = 0,
    timeoutTimer = nil,
}

function P:IsAHOpen()
    return _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() and true or false
end

local function processBatch(results)
    if not scan.active or not results then return end
    local batch, qtyBatch = {}, {}
    local n = 0
    for _, info in ipairs(results) do
        local itemID = info.itemKey and info.itemKey.itemID
        if itemID and scan.needed[itemID]
           and info.totalQuantity and info.totalQuantity > 0 then
            batch[itemID]    = info.minPrice
            qtyBatch[itemID] = info.totalQuantity   -- units currently listed (#AH column)
            n = n + 1
        end
    end
    if n > 0 then
        scan.found = scan.found + n
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.PRICES_DIRECT_SCAN_BATCH,
            payload = { prices = batch, quantities = qtyBatch },
        })
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.PRICES_DIRECT_SCAN_PROGRESS,
            payload = { found = scan.found, total = scan.total },
        })
    end
end

local function finalizeScan()
    if not scan.active then return end
    scan.active = false
    if scan.timeoutTimer then scan.timeoutTimer:Cancel() end
    scan.timeoutTimer = nil
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PRICES_DIRECT_SCAN_COMPLETED,
        payload = { neededItems = scan.needed, now = _G.time and _G.time() or 0 },
    })
    scan.needed = {}
end

local function onScanEvent(_, event, ...)
    if not scan.active then return end
    local CA = _G.C_AuctionHouse
    if not CA then return end
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        processBatch(CA.GetBrowseResults())
        if CA.HasFullBrowseResults and CA.HasFullBrowseResults() then  -- exception(boundary): Auctionator optional dependency
            finalizeScan()
        elseif CA.RequestMoreBrowseResults then  -- exception(boundary): RequestMoreBrowseResults is a C_AuctionHouse API that may be absent in some client builds
            CA.RequestMoreBrowseResults()
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        local added = ...
        processBatch(added)
        if CA.HasFullBrowseResults and CA.HasFullBrowseResults() then  -- exception(boundary): Auctionator optional dependency
            finalizeScan()
        elseif CA.RequestMoreBrowseResults then  -- exception(boundary): RequestMoreBrowseResults is a C_AuctionHouse API that may be absent in some client builds
            CA.RequestMoreBrowseResults()
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        scan.active = false
        if scan.timeoutTimer then scan.timeoutTimer:Cancel(); scan.timeoutTimer = nil end
        scan.needed = {}
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.PRICES_DIRECT_SCAN_COMPLETED,
            payload = { neededItems = {}, now = _G.time and _G.time() or 0 },
        })
    end
end

-- StartDirectScan(itemIDs, force) -- AH must be open.
-- Prices stream in via PRICES_DIRECT_SCAN_BATCH; PRICES_DIRECT_SCAN_COMPLETED
-- finalizes (zeroes unfound items, records cacheTime).
-- force = true scans EVERY id regardless of cache state. Without it, a
-- completed scan makes every id non-nil (COMPLETED zeroes the unfound ones),
-- so the needed-filter goes to 0 and "Refresh from AH" was a forever no-op
-- against a full cache -- the explicit refresh button must force.
-- Returns: true if started (or already scanning), false if AH not open.
function P:StartDirectScan(itemIDs, force)
    if not self:IsAHOpen() then return false end
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.SendBrowseQuery then return false end
    if scan.active then return true end   -- one browse query at a time; the label already shows progress

    if not scanFrame then
        scanFrame = _G.CreateFrame("Frame")
        scanFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        scanFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
        scanFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
        scanFrame:SetScript("OnEvent", onScanEvent)
    end

    local cache = HDG.Store:GetState().account.prices.directCache

    -- Skip already-cached items (0 = "scanned but unlisted"; don't re-scan)
    -- unless forced -- PRICES_DIRECT_SCAN_STARTED wipes the cache anyway
    -- (replace-on-scan), so a forced scan is a fresh snapshot end to end.
    local needed, n = {}, 0
    for _, id in ipairs(itemIDs or {}) do
        if force or cache[id] == nil then needed[id] = true; n = n + 1 end
    end
    if n == 0 then return true end

    scan.active = true
    scan.needed = needed
    scan.found  = 0
    scan.total  = n
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PRICES_DIRECT_SCAN_STARTED,
        payload = { total = n },
    })

    -- Safety timeout (60s for a full browse scan). Fires = the AH browse
    -- stalled; say so -- "prices never load" reports were undiagnosable.
    scan.timeoutTimer = C_Timer.NewTimer(60, function()
        if scan.active then
            HDG.Log:Warn("prices_scan", ("Auction browse scan stalled -- gave up after 60s (%d/%d items priced); prices may be incomplete")
                :format(scan.found or 0, scan.total or 0))
            finalizeScan()
        end
    end)

    _G.C_AuctionHouse.SendBrowseQuery({
        searchString     = "",
        sorts            = {},
        filters          = {},
        itemClassFilters = {},
    })
    return true
end

-- ===== Owned auctions ======================================================
-- Queried on AH open; Goblin tab uses this for "already listed" markers.

function P:QueryOwnedAuctions()
    C_AuctionHouse.QueryOwnedAuctions({})
end

function P:ProcessOwnedAuctions()
    local CA = _G.C_AuctionHouse
    if not (CA and CA.GetOwnedAuctions) then return end
    local list = CA.GetOwnedAuctions() or {}
    local out = {}
    for _, a in ipairs(list) do
        local id = a.itemKey and a.itemKey.itemID
        if id then
            local existing = out[id] or { qty = 0, buyout = 0 }
            existing.qty    = existing.qty + (a.quantity or 1)
            existing.buyout = a.buyoutAmount or existing.buyout
            out[id] = existing
        end
    end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PRICES_OWNED_AUCTIONS_UPDATED,
        payload = { auctions = out },
    })
end

-- ===== Module registration =================================================
HDG.Modules:Declare({
    name = "PriceSource",
    dependencies = {},
    blizzardEvents = {
        -- BROWSE events are consumed by the scan machine's own frame (registered
        -- lazily in StartDirectScan). Only owned-auctions events here.
        -- No requiresMainWindow -- cache helps Goblin tab on next open.
        AUCTION_HOUSE_SHOW    = { handler = "OnAHOpened"   },
        OWNED_AUCTIONS_UPDATED = { handler = "OnOwnedUpdated" },
    },
    OnAHOpened = function(self)
        P:QueryOwnedAuctions()
    end,
    OnOwnedUpdated = function(self)
        P:ProcessOwnedAuctions()
    end,
    onEnable = function(self)
        -- Snapshot addon availability into state on every main-window open.
        -- Subscribe-gated (not eager at load time) so TSM / Auctionator
        -- have loaded their public APIs by the time we probe _G.
        -- Token captured so onShutdown can unsubscribe.
        self._storeToken = HDG.Store:Subscribe(function(actionType, invalidation)
            if actionType == HDG.Constants.ACTIONS.MAIN_WINDOW_OPENING then
                P:RefreshAddonAvailability()
            elseif HDG.Paths.MatchesAny({ "account.config.mockTSM" }, invalidation) then
                -- Re-snapshot so Config tab's tsmLoaded flips + price selectors invalidate.
                P:RefreshAddonAvailability()
                HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.PRICES_CONFIG_CHANGED })
            end
        end)
    end,
    onShutdown = function(self)
        if self._storeToken then
            HDG.Store:Unsubscribe(self._storeToken)
            self._storeToken = nil
        end
    end,
})
