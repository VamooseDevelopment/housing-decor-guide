-- HDG.ItemNameResolver
-- ============================================================================
-- Catalog items resolve from HousingCatalogObserver.byItemID (fast path).
-- This resolver handles non-catalog items: recipe reagents, lumber, mogul materials.
-- GetItemInfo/GetItemInfoInstant return nil on first call for uncached items;
-- async ItemEventListener + batch dispatch handles the cold-load race.
--
-- Async: Blizzard's ItemEventListener (AsyncCallbackSystemMixin) wraps the
-- RequestLoadItemDataByID + ITEM_DATA_LOAD_RESULT pair. One callback per itemID;
-- coalesced into one ITEM_INFO_RESOLVED dispatch per BATCH_WINDOW (avoids 50 fan-outs
-- on cold load). `_pending` = deduped batch; `_callbacks` = in-flight guards.

HDG = HDG or {}
HDG.ItemNameResolver = HDG.ItemNameResolver or {}
local R = HDG.ItemNameResolver

R._pending          = R._pending          or {}     -- [itemID] = true (deduped batch)
R._callbacks        = R._callbacks        or {}     -- [itemID] = true while ItemEventListener cb in flight
R._tick             = R._tick             or 0  -- exception(false-positive): idempotent module-load init
R._timerScheduled   = R._timerScheduled   or false  -- one drain timer pending

R.BATCH_WINDOW = 0.5

-- Cache-miss: register a per-itemID ItemEventListener callback if not already in flight.
-- Fires once on success; listener clears on failure without firing.
function R:_Request(itemID)
    if not itemID then return end
    if self._callbacks[itemID] then return end
    if not (_G.ItemEventListener and _G.ItemEventListener.AddCallback) then return end
    self._callbacks[itemID] = true
    _G.ItemEventListener:AddCallback(itemID, function()
        self._callbacks[itemID] = nil
        self:OnItemInfoReceived(itemID, true)
    end)
    -- Trigger the async load: AddCallback only subscribes, doesn't initiate.
    -- Without RequestLoadItemDataByID, callbacks only fire if another path queries the same itemID.
    -- Idempotent: already-cached items trigger GET_ITEM_INFO_RECEIVED synchronously next frame.
    if _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
        _G.C_Item.RequestLoadItemDataByID(itemID)  -- exception(boundary): C_Item nil for uncached / invalid item
    end
end

function R:GetTick()    return self._tick    end
function R:GetPending() return self._pending end

-- ResolveName: locale-correct sources first. The C_HousingCatalog row name is BOTH localized
-- (like every Blizzard *.name field) AND synchronous/always-populated, so it's the trusted #1
-- source -- it's what makes decor names "always work". For non-catalog items (reagents, lumber,
-- mats) the catalog has no entry, so we fall to live GetItemInfo (also locale-correct), ranked
-- ABOVE the baked English DB. The baked name was wrongly above GetItemInfo before -> reagents
-- showed English; it's now just the cold-load placeholder. (old HDG's GetLocalizedName likewise
-- "prefers WoW API over hardcoded DB name.") Returns (name, resolved); resolved=false = placeholder.
function R:ResolveName(itemID)
    if not itemID then return "?", false end
    -- 1. Catalog row: locale-correct AND sync/always-on -- the reliable source for decor.
    local obs = HDG.HousingCatalogObserver
    local row = obs and obs.byItemID and obs.byItemID[itemID]
    if row and row.name then return row.name, true end
    -- 2. State cache: async-resolved locale-correct name (survives Blizzard cache eviction).
    local cached = HDG.Store:GetState().session.itemNames.names[itemID]
    if cached then return cached, true end
    -- 3. Blizzard live cache: locale-correct name for non-catalog items (reagents/mats). Beats baked English.
    if _G.C_Item and _G.C_Item.GetItemInfo then
        local name = _G.C_Item.GetItemInfo(itemID)
        if name then return name, true end
    end
    -- 4. Cold cache: kick async load; baked English DB name is the placeholder until step 2 fills in.
    self:_Request(itemID)
    local _, baked = HDG.StaticData.Reagents:Get(itemID)  -- exception(nullable): not every item is a reagent
    if baked then return baked, false end
    return "item " .. tostring(itemID), false
end

-- ResolveIcon: mirrors ResolveName's boundary contract for icons.
-- C_Item.GetItemIconByID is sync DBC (always cached, preferred over GetItemInfoInstant).
-- On miss, shares _Request(itemID) with ResolveName (one callback warms both).
function R:ResolveIcon(itemID)
    if not itemID then return nil end
    -- Fast path: catalog rows carry iconTexture (skip API entirely).
    local obs = HDG.HousingCatalogObserver
    local row = obs and obs.byItemID and obs.byItemID[itemID]
    if row and row.iconTexture then return row.iconTexture end
    -- exception(boundary): GetItemIconByID is sync DBC (always cached); any valid itemID returns a fileID.
    -- GetItemInfoInstant can miss for items without full client data (correct for names, wrong for icons).
    if _G.C_Item and _G.C_Item.GetItemIconByID then
        local icon = _G.C_Item.GetItemIconByID(itemID)  -- exception(boundary): sync DBC lookup, always cached
        if icon then return icon end
    end
    -- Fallback: GetItemInfoInstant, then async for deleted/server-only IDs.
    if _G.C_Item and _G.C_Item.GetItemInfoInstant then
        local _id, _type, _subType, _equipLoc, icon = _G.C_Item.GetItemInfoInstant(itemID)
        if icon then return icon end
    end
    self:_Request(itemID)
    return nil
end

-- GetSellPrice: GetItemInfo's 11th return via the resolver boundary (ADR-003b).
-- On cold miss: _Request + return 0; drain bumps tick so mogul.plan re-runs.
-- 0 is the fail-safe (mogul treats 0 as "ineligible").
function R:GetSellPrice(itemID)
    if not itemID then return 0 end
    if _G.C_Item and _G.C_Item.GetItemInfo then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = _G.C_Item.GetItemInfo(itemID)
        if sellPrice then return sellPrice end  -- exception(boundary): sparse tuple on cold cache
    end
    self:_Request(itemID)
    return 0
end

-- OnItemInfoReceived: called from ItemEventListener callback + test seam.
-- Adds itemID to pending batch; schedules drain (explicit boolean: C_Timer.After returns nil).
function R:OnItemInfoReceived(itemID, success)
    if not (itemID and success) then return end
    self._pending[itemID] = true
    if self._timerScheduled then return end
    if not (_G.C_Timer and _G.C_Timer.After) then return end
    self._timerScheduled = true
    _G.C_Timer.After(self.BATCH_WINDOW, function() R:Drain() end)
end

-- Drain: resolve all pending itemIDs (cache warm after ItemEventListener fired) and
-- dispatch one ITEM_INFO_RESOLVED bulk. Reducer writes to session.itemNames.names.
function R:Drain()
    self._timerScheduled = false
    local batch = self._pending
    self._pending = {}
    self._tick = self._tick + 1
    local entries, count = {}, 0
    for itemID in pairs(batch) do
        -- GetItemInfo should be warm (ItemEventListener fired). nil = race or missing; skip.
        local name = _G.C_Item and _G.C_Item.GetItemInfo and _G.C_Item.GetItemInfo(itemID)
        if name then
            count = count + 1
            entries[count] = { itemID = itemID, name = name }
        end
    end
    -- Drain fires post-init; Store + Constants always present.
    if count > 0 then
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.ITEM_INFO_RESOLVED,
            payload = { entries = entries, count = count },
        })
    end
    return batch
end

-- ===== Module registration ===================================================
-- No blizzardEvents: cache misses register ItemEventListener callbacks directly.
HDG.Modules:Declare({
    name = "ItemNameResolver",
    dependencies = {},
})
