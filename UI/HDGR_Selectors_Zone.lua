-- HDG.Selectors -- Zone Scanner family
--
-- Pure selectors. Surface:
--   zone.vendorsInZone    -> enriched vendor rows for currentMapID
--   zone.filteredVendors  -> applies search + showCollected
--   zone.entriesByVendor  -> tree-flat projection (vendor headers + item rows)
--   zone.summary          -> "3 vendors -- 12 uncollected" text
--   zone.hasShoppingListItems -> bool

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors

-- ===== Atomic reads ========================================================


Selectors:Register("zone.search", {
    reads = { "session.ui.zoneScanner.searchQuery" },
    fn = function(state, ctx)
        return state.session.ui.zoneScanner.searchQuery
    end,
})

Selectors:Register("zone.showCollected", {
    reads = { "session.ui.zoneScanner.showCollected" },
    fn = function(state, ctx)
        return state.session.ui.zoneScanner.showCollected
    end,
})


-- The cart tick on the Map All row: whether the scanner matches the shopping list.
Selectors:Register("zone.trackShopping", {
    reads = { "account.config.zoneScannerTrackShopping" },
    fn = function(state, ctx)
        return state.account.config.zoneScannerTrackShopping
    end,
})

-- Window title: "Zone Scanner: <zone>", or just "Zone Scanner" before the first
-- zone probe lands.
Selectors:Register("zone.title", {
    reads = { "session.zone.zoneLevelName" },
    fn = function(state, ctx)
        local title = HDG.Locale:Get("ZONE_TITLE")
        local zone  = state.session.zone.zoneLevelName
        if zone == "" then return title end
        return title .. ": " .. zone
    end,
})

Selectors:Register("zone.popupShown", {
    reads = { "account.ui.zonePopupShown" },
    fn = function(state, ctx)
        return state.account.ui.zonePopupShown == true
    end,
})

-- ===== Vendor enumeration ==================================================
-- Vendor metadata from StaticData.VendorAugment; item lists from HousingCatalogObserver.
-- Observer rows are released by construction; no liveDecorIDs gate needed.
-- Faction filter: Neutral + same-faction.

-- O(1) lookup hash: "<npcID>:<itemID>" (vendor) or "w:<itemID>" (wishlist).
-- Wishlist entries match any vendor selling the item.
local function _buildShoppingListHash(vendorShoppingLists, activeListID)
    local hash = {}
    local list = vendorShoppingLists and vendorShoppingLists[activeListID]
    if not (list and list.items) then return hash end
    for _, e in ipairs(list.items) do
        if e.itemID and e.npcID then
            hash[e.npcID .. ":" .. e.itemID] = true
        elseif e.itemID then
            hash["w:" .. e.itemID] = true
        end
    end
    return hash
end

-- Per-item record for one catalog row. Returns (record, isOwned, isOnSL) for tally updates.
local function _buildVendorItemRecord(itemID, row, npcID, shoppingHash)
    local owned = HDG.HousingCatalogObserver:IsOwned(row)
    local onSL  = shoppingHash[npcID .. ":" .. itemID]
                or shoppingHash["w:" .. itemID] or false
    return {
        itemID         = itemID,
        goldCost       = row.goldCost,    -- catalog row field
        collected      = owned,
        onShoppingList = onSL,
    }, owned, onSL
end

-- Walk catalog items for this vendor: build per-item records + tally counts.
local function _collectVendorItems(ve, npcID, shoppingHash)
    local items, uncoll, coll, slCount = {}, 0, 0, 0
    local catalogVendor = HDG.HousingCatalogObserver:GetItemsByVendor(ve.name, ve.zone)
    if not catalogVendor then return items, uncoll, coll, slCount end
    for _, itemID in ipairs(catalogVendor.items) do
        local row = HDG.HousingCatalogObserver:GetRow(itemID)
        if row then
            local record, owned, onSL = _buildVendorItemRecord(itemID, row, npcID, shoppingHash)
            items[#items + 1] = record
            if owned then coll = coll + 1 else uncoll = uncoll + 1 end
            if onSL then slCount = slCount + 1 end
        end
    end
    return items, uncoll, coll, slCount
end

-- Assemble the final zone-vendor envelope row.
local function _buildZoneVendorRecord(ve, npcID, vFaction, items, uncoll, coll, slCount)
    return {
        npcID             = npcID,
        name              = ve.name,
        zone              = ve.zone,
        mapID             = ve.mapID,
        x                 = ve.x,
        y                 = ve.y,
        faction           = vFaction,
        items             = items,
        uncollectedCount  = uncoll,
        collectedCount    = coll,
        shoppingListCount = slCount,
    }
end

Selectors:Register("zone.vendorsInZone", {
    reads = {
        "session.resolvers.staticData.tick",  -- ADR-003c StaticData marker (sweep rule 4c)
        "session.zone.currentMapID",
        "session.identity.factionGroup",
        "session.resolvers.catalog.tick",
        "account.collection.ownedDecorIDs",
        "account.vendorShoppingLists",
        "account.activeShoppingListId",
        "account.config.zoneScannerTrackShopping",
    },
    fn = function(state, ctx)
        local mapID = state.session.zone.currentMapID
        if not mapID or mapID == 0 then return {} end
        if not HDG.HousingCatalogObserver:IsReady() then return {} end

        local npcIDsInZone = HDG.StaticData.VendorAugment:GetVendorsByMap(mapID)
        if not npcIDsInZone then return {} end

        -- Cart tick off: an empty hash matches nothing, so every shopping-list
        -- count, marker and alert downstream reads zero from this one place.
        local shoppingHash = {}
        if state.account.config.zoneScannerTrackShopping then
            shoppingHash = _buildShoppingListHash(
                state.account.vendorShoppingLists, state.account.activeShoppingListId)
        end

        -- Faction tag stamped by SessionIdentity at onEnable.
        -- Empty string (pre-stamp boot race) -> treat as "N" (Neutral = show everything).
        local pTag = state.session.identity.factionGroup
        if pTag == "" then pTag = "N" end

        local out = {}
        for _, npcID in ipairs(npcIDsInZone) do
            local ve = HDG.StaticData.VendorAugment:Get(npcID)
            if ve then
                local vFaction = ve.faction or "N"
                if vFaction == "N" or vFaction == pTag then
                    local items, uncoll, coll, slCount = _collectVendorItems(ve, npcID, shoppingHash)
                    if #items > 0 then
                        out[#out + 1] = _buildZoneVendorRecord(
                            ve, npcID, vFaction, items, uncoll, coll, slCount)
                    end
                end
            end
        end
        table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
        return out
    end,
})

-- ===== Filtered + projected vendors =========================================

Selectors:Register("zone.filteredVendors", {
    calls = { "zone.vendorsInZone", "zone.search", "zone.showCollected" },
    fn = function(state, ctx)
        local vendors = Selectors:Call("zone.vendorsInZone", state, ctx)
        local search  = Selectors:Call("zone.search", state, ctx):lower()
        local showCol = Selectors:Call("zone.showCollected", state, ctx)
        local out = {}
        for _, v in ipairs(vendors) do
            -- showCollected=false hides owned items EXCEPT shopping-list items
            -- (always actionable). Without this exception, the popup fires but shows nothing.
            local visibleItems = {}
            for _, it in ipairs(v.items) do
                if showCol or not it.collected or it.onShoppingList then
                    visibleItems[#visibleItems + 1] = it
                end
            end
            -- Search across vendor name only; item names resolve async -> non-deterministic.
            local nameOK = search == "" or v.name:lower():find(search, 1, true)
            if nameOK and #visibleItems > 0 then
                local copy = {}
                for k, val in pairs(v) do copy[k] = val end
                copy.items = visibleItems
                out[#out + 1] = copy
            end
        end
        return out
    end,
})

-- Tree-via-flat-projection: vendor header + item rows when expanded.
Selectors:Register("zone.entriesByVendor", {
    reads = { "session.ui.zoneScanner.expanded", "session.itemNames.names" },
    calls = { "zone.filteredVendors" },
    fn = function(state, ctx)
        local vendors  = Selectors:Call("zone.filteredVendors", state, ctx)
        local expanded = state.session.ui.zoneScanner.expanded
        local rows = {}
        for _, v in ipairs(vendors) do
            local isExpanded = expanded[v.npcID] == true
            rows[#rows + 1] = {
                kind = "vendor", npcID = v.npcID, name = v.name,
                uncollectedCount = v.uncollectedCount,
                collectedCount   = v.collectedCount,
                shoppingListCount = v.shoppingListCount,
                mapID = v.mapID, x = v.x, y = v.y, zone = v.zone,
                -- the pin greys without a location (owner 2026-10-15); a few
                -- neighborhood vendors have a zone but no coords yet
                mappable = HDG.VendorRank.HasLocation(v.mapID, v.x, v.y),
                collapsed = not isExpanded,
            }
            if isExpanded then
                for _, it in ipairs(v.items) do
                    rows[#rows + 1] = {
                        kind   = "item",
                        itemID = it.itemID,
                        npcID  = v.npcID,
                        goldCost = it.goldCost,
                        collected = it.collected,
                        onShoppingList = it.onShoppingList,
                    }
                end
            end
        end
        return rows
    end,
})

-- zone.windowRows: dynamicRows driver so the floating window auto-sizes.
-- body chrome = 74px; content = N rows * 20 + gaps, clamped (huge zone -> scroll).
local ZONE_ROW_H, ZONE_ROW_GAP = 20, 1
local ZONE_HEADER_H            = 28
local ZONE_BODY_CHROME         = 74
local ZONE_ENTRIES_PAD         = 8     -- entries "inset" border eats a few px -> last row was clipping
local ZONE_MIN_ENTRIES         = 44    -- ~2 rows: no sliver on a 1-vendor zone
local ZONE_MAX_ENTRIES         = 428   -- ~20 rows; beyond this the list scrolls
Selectors:Register("zone.windowRows", {
    calls = { "zone.entriesByVendor" },
    fn = function(state, ctx)
        local rows = Selectors:Call("zone.entriesByVendor", state, ctx)
        local n = #rows
        local raw = (n > 0) and (n * ZONE_ROW_H + (n - 1) * ZONE_ROW_GAP) or ZONE_ROW_H
        local content = math.max(ZONE_MIN_ENTRIES, math.min(ZONE_MAX_ENTRIES, raw + ZONE_ENTRIES_PAD))
        return { ZONE_HEADER_H, ZONE_BODY_CHROME + content }
    end,
})


-- ===== Summary text + alert predicates =====================================

Selectors:Register("zone.summary", {
    calls = { "zone.vendorsInZone" },
    fn = function(state, ctx)
        local vendors = Selectors:Call("zone.vendorsInZone", state, ctx)
        if #vendors == 0 then return "No vendors in this zone" end
        -- Count only vendors you actually need to visit (uncollected OR shopping-list
        -- items) -- NOT every decor vendor in the zone. zone.vendorsInZone returns ALL
        -- zone vendors; `#vendors` over-reports ("4 vendors" when 3 have nothing missing).
        -- Summary is alert-only and fires only when >=1 such vendor exists, so relevant >= 1.
        local relevant, totalUncoll, totalSL = 0, 0, 0
        for _, v in ipairs(vendors) do
            totalUncoll = totalUncoll + v.uncollectedCount
            totalSL     = totalSL     + v.shoppingListCount
            if v.uncollectedCount > 0 or v.shoppingListCount > 0 then
                relevant = relevant + 1
            end
        end
        local parts = { tostring(relevant) .. (relevant == 1 and " vendor" or " vendors") }
        parts[#parts + 1] = tostring(totalUncoll) .. " uncollected"
        if totalSL > 0 then
            parts[#parts + 1] = tostring(totalSL) .. " on shopping list"
        end
        return table.concat(parts, "  -  ")
    end,
})

-- Zone has at least one shopping-list item. Alert engine reads for shopping-list path.
Selectors:Register("zone.hasShoppingListItems", {
    calls = { "zone.vendorsInZone" },
    fn = function(state, ctx)
        local vendors = Selectors:Call("zone.vendorsInZone", state, ctx)
        for _, v in ipairs(vendors) do
            if v.shoppingListCount > 0 then return true end
        end
        return false
    end,
})

-- Zone has at least one uncollected item. Alert engine reads for uncollected path.
Selectors:Register("zone.hasUncollectedItems", {
    calls = { "zone.vendorsInZone" },
    fn = function(state, ctx)
        local vendors = Selectors:Call("zone.vendorsInZone", state, ctx)
        for _, v in ipairs(vendors) do
            if v.uncollectedCount > 0 then return true end
        end
        return false
    end,
})
