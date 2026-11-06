-- HDG.BagObserver
-- ============================================================================
-- Pull-on-demand wrapper around C_Item.GetItemCount (O(1) in Blizzard's client cache).
--   GetTotal(itemID)  -- canonical per-item lookup, all stashes
--   GetSplit(itemID)  -- bag / bank / warband breakdown for Warehouse view
--   GetCounts()       -- proxy table; __index calls GetTotal on-the-fly
--   Scan()            -- bumps tick + dispatches BAG_INVENTORY_UPDATED

HDG = HDG or {}
HDG.BagObserver = HDG.BagObserver or {}

HDG.Log:RegisterTags({ bag_scan = { user = false, level = "debug" } })
local B = HDG.BagObserver

B._tick = B._tick or 0  -- exception(false-positive): idempotent module-load init

function B:GetTick() return self._tick end

-- Canonical per-item total: bag + bank + reagent bank + warband.
function B:GetTotal(itemID)
    if not (itemID and _G.C_Item and _G.C_Item.GetItemCount) then return 0 end  -- exception(boundary): C_Item nil for uncached / invalid item
    return _G.C_Item.GetItemCount(itemID, true, false, true, true) or 0  -- exception(boundary): C_Item nil for uncached / invalid item
end

-- Carried-in-bags count ONLY (no bank / reagent bank / warband). Harvest detection
-- diffs on this: bank/warband totals change async (login load, cross-char deposit,
-- portable-bank sync) with no gating UI, and those are NOT gathers. Only lumber
-- landing in your bags is a harvest.
function B:GetBagCount(itemID)
    if not (itemID and _G.C_Item and _G.C_Item.GetItemCount) then return 0 end  -- exception(boundary): C_Item nil for uncached / invalid item
    return _G.C_Item.GetItemCount(itemID, false, false, false, false) or 0  -- exception(boundary): C_Item nil for uncached / invalid item
end

-- An item a vendor takes as payment, counted the way Blizzard's merchant counts it
-- (MerchantFrame.lua: GetItemCount(link, false, false, true)) -- bags plus the
-- reagent bank, not the bank or the warband bank, which a vendor cannot draw on.
function B:GetVendorPaymentCount(itemID)
    return _G.C_Item.GetItemCount(itemID, false, false, true, false)
end

-- Per-storage breakdown. Derives bank/warband by subtraction across flag combinations.
function B:GetSplit(itemID)
    if not (itemID and _G.C_Item and _G.C_Item.GetItemCount) then return 0, 0, 0 end
    local GIC = _G.C_Item.GetItemCount
    local bagOnly  = GIC(itemID, false, false, false, false) or 0  -- exception(boundary): C_Item nil for uncached / invalid item
    local personal = GIC(itemID, true,  false, true,  false) or 0  -- exception(boundary): C_Item nil for uncached / invalid item
    local total    = GIC(itemID, true,  false, true,  true)  or 0  -- exception(boundary): C_Item nil for uncached / invalid item
    local bank     = personal - bagOnly      -- legacy bank + reagent bank
    local warband  = total    - personal
    if bank < 0    then bank    = 0 end
    if warband < 0 then warband = 0 end
    return bagOnly, bank, warband
end

-- Variant-aware split: sums across base itemID + quality siblings (any quality satisfies a slot).
function B:GetSplitWithVariants(itemID)
    local bag, bank, warband = self:GetSplit(itemID)
    local variants = HDG.StaticData.Professions:GetQualityVariants(itemID)
    if variants then
        for _, v in ipairs(variants) do
            local vbag, vbank, vwarband = self:GetSplit(v)
            bag     = bag     + vbag
            bank    = bank    + vbank
            warband = warband + vwarband
        end
    end
    return bag, bank, warband
end

-- Variant-aware total: base item + quality siblings (tiered reagents have separate itemIDs per quality).
-- Non-tiered items have no siblings -> identical to GetTotal.
function B:GetTotalWithVariants(itemID)
    local total = self:GetTotal(itemID)
    local variants = HDG.StaticData.Professions:GetQualityVariants(itemID)
    if variants then
        for _, v in ipairs(variants) do
            total = total + self:GetTotal(v)
        end
    end
    return total
end

-- Backward-compat proxy: __index calls GetTotalWithVariants. Returns 0 (not nil) for absent items.
local CountsProxy = setmetatable({}, { __index = function(_, itemID)
    return B:GetTotalWithVariants(itemID)
end })
function B:GetCounts() return CountsProxy end

-- Scan: bump tick + dispatch BAG_INVENTORY_UPDATED so selectors invalidate.
-- Per-item totals pulled on demand; no map building, no slot walking.
function B:Scan()
    -- Milestone breadcrumb: a blank-bag-data report is debuggable the same way
    -- catalog_refreshed debugs a blank catalog. Debug level -- zero user noise.
    HDG.Log:Debug("bag_scan", "Bag scan -- tick " .. tostring((self._tick or 0) + 1))
    self._tick = self._tick + 1
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.BAG_INVENTORY_UPDATED,
        payload = { tick = self._tick },
    })
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "BagObserver",
    dependencies = {},
    ownsBlizzardNamespaces = { "C_Item.GetItemCount" },   -- ADR-011: sub-API (other C_Item APIs belong to ItemNameResolver)
    blizzardEvents = {
        -- Counts only matter when the addon is visible; gate behind mainWindowShown.
        BAG_UPDATE              = { handler = "OnBagUpdate", debounce = 0.2,
                                    requiresMainWindow = true },
        BANKFRAME_OPENED        = { handler = "OnBagUpdate",
                                    requiresMainWindow = true },
        PLAYERBANKSLOTS_CHANGED = { handler = "OnBagUpdate", debounce = 0.3,
                                    requiresMainWindow = true },
        BANK_TABS_CHANGED       = { handler = "OnBagUpdate", debounce = 0.3,
                                    requiresMainWindow = true },
    },
    OnBagUpdate = function(self)
        B:Scan()
    end,
    onEnable = function(self)
        -- Catch-up pulse on first window open. Token captured for onShutdown unsubscribe.
        self._storeToken = HDG.Store:Subscribe(function(actionType)
            if actionType == HDG.Constants.ACTIONS.MAIN_WINDOW_OPENING then
                B:Scan()
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
