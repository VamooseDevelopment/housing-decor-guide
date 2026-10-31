-- HDG.StyleEngine
-- ============================================================================
-- Style/collection engine (scaffold). Public API surface matches Styles
-- LayoutConfig + Selectors; internals are stubs pending surface wiring.
--
-- Architecture:
--   MembershipResolver -- type in {style, shopping, snapshot, collection}.
--   RuleResolver       -- type in {smartset, concept}; items derive from
--                         scoring the rules table against facetStore.
--
-- All caches initialize empty; BuildCache is reentry-safe (cacheBuilt / cacheBuilding).

HDG = HDG or {}
HDG.StyleEngine = HDG.StyleEngine or {}
local SE = HDG.StyleEngine

-- ===== File-local caches ====================================================

local vocab            = {}    -- [facetKey] = vocab table
local facetStore       = {}    -- [itemID]  = decoded facets
local reverseIndex     = {}    -- [facetName] = [value] = [itemID...]   (lazy)
local styleItemCache   = {}    -- [collectionID] = bucket tables
local compatCache      = {}    -- [decorID] = [collectionID] = score    (lazy)
local roomCache        = {}    -- [itemID] = ["bedroom", ...]
local itemToDecor      = {}    -- [itemID]  = decorID
local itemCache        = {}    -- [itemID]  = view-row reference into catalog
local allCollectionDefs = {}   -- [collectionID] = def (curated + custom merged)
local _styleItemView   = nil   -- [itemID] = derived flags (isUnreleased / hasRepReq / costsEndeavor / isCraftable)

local cacheBuilt    = false
local cacheBuilding = false

-- ===== Build ================================================================

-- Reentry-safe. Caches fleshed out as surfaces consume data; currently
-- marks ready without populating so the engine is a safe no-op at boot.
function SE:BuildCache()
    if cacheBuilt or cacheBuilding then return end
    cacheBuilding = true
    cacheBuilt    = true
    cacheBuilding = false
end

function SE:InvalidateCache()
    vocab            = {}
    facetStore       = {}
    reverseIndex     = {}
    styleItemCache   = {}
    compatCache      = {}
    roomCache        = {}
    itemToDecor      = {}
    itemCache        = {}
    allCollectionDefs = {}
    _styleItemView   = nil
    cacheBuilt    = false
    cacheBuilding = false
end

function SE:IsCacheReady()
    return cacheBuilt
end

-- ===== Public API (membership + rule unified) ==============================

-- GetCollectionItems(id) -> array of decorID (stub; returns empty)
function SE:GetCollectionItems(collectionID)
    if not cacheBuilt then self:BuildCache() end
    return {}
end

-- GetCollectionStats(id) -> { owned, total, pct, byTier? } (stub)
function SE:GetCollectionStats(collectionID)
    if not cacheBuilt then self:BuildCache() end
    return { owned = 0, total = 0, pct = 0 }
end

-- GetCompatibility(id, decorID) -> score; 0 for membership types (stub)
function SE:GetCompatibility(collectionID, decorID)
    if not cacheBuilt then self:BuildCache() end
    return 0
end

-- GetMemberships(decorID) -> [collectionID...] (stub)
function SE:GetMemberships(decorID)
    if not cacheBuilt then self:BuildCache() end
    return {}
end

-- IsUnassigned: true when decor belongs to no user style (stub; always true)
function SE:IsUnassigned(decorID)
    if not cacheBuilt then self:BuildCache() end
    return true
end

-- GetSubcategory(id, itemID) -> subcatKey or nil; Room Concepts only (stub)
function SE:GetSubcategory(collectionID, itemID)
    if not cacheBuilt then self:BuildCache() end
    return nil
end

-- AddItemToCollection / RemoveItemFromCollection -- mutate via Store action.
function SE:AddItemToCollection(collectionID, itemID)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.COLLECTION_STYLE_ITEM_ADDED,
        payload = { collectionID = collectionID, itemID = itemID },
    })
end

function SE:RemoveItemFromCollection(collectionID, itemID)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.COLLECTION_STYLE_ITEM_REMOVED,
        payload = { collectionID = collectionID, itemID = itemID },
    })
end

-- ===== Per-item view overlay ===============================================
-- Derived flags: isUnreleased, hasRepReq, costsEndeavor, isCraftable.
-- Built once on first request; cleared on InvalidateCache.

function SE:GetItemView(itemID)
    if not _styleItemView then
        _styleItemView = {}  -- stub; callers get nil for any flag without an exception
    end
    return _styleItemView[itemID] or {}
end

-- ===== Module registration =================================================
HDG.Modules:Declare({
    name = "StyleEngine",
    dependencies = {},
    -- Cache build is JIT (every public method checks cacheBuilt).
})
