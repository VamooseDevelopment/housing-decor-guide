-- HDG.Selectors -- Shopping list (multi-list per-account).
--
-- Selector graph:
--   shopping.activeList          -> active list record or nil
--   shopping.activeListId        -> primitive id ("" or "Lnnn")
--   shopping.activeListMenuItems -> dropdown menu items for the switcher
--   shopping.summary             -> { itemCount, vendorCount, wishCount, ahCount, goldCost }
--   shopping.summaryText         -> display text for header
--   shopping.attribution         -> { source, url, desc, date, author } from list.meta
--   shopping.hasAttribution      -> bool (visibility gate for banner)
--   shopping.attributionText     -> display text for banner
--   shopping.activeListEntries   -> flat list enriched with vendor info
--   shopping.entriesByZone       -> tree-via-flat-projection for scrollbox
--
-- Vendor coords from VendorAugment:Get(npcID). All selectors strict-read.

HDG = HDG or {}
local Selectors = HDG.Selectors

-- Window visibility (account.ui.shoppingWidgetShown, flipped by SHOPPING_WIDGET_TOGGLE).
Selectors:Register("shopping.windowVisible", {
    reads = { "account.ui.shoppingWidgetShown" },
    fn = function(state)
        return state.account.ui.shoppingWidgetShown == true
    end,
})

-- Which housing neighborhood to prefer when BOTH sell the same decor, as a
-- faction key ("alliance"/"horde"), or nil for no preference.
--
-- "" is the stored "never picked a side", where this character's own faction is
-- the sensible opening position -- so a player who never opens the toggle still
-- gets sent to their own neighborhood. SessionIdentity is the ONLY source for
-- that faction ("A"/"H"/"N"); selectors are pure and must never reach for
-- UnitFactionGroup themselves.
--
-- "N" (a Pandaren who has not chosen) returns nil, and nil means "leave the
-- catalog's own order alone" rather than a guess at a neighborhood they have
-- no claim on yet.
Selectors:Register("shopping.neighborhood", {
    reads = { "account.ui.shoppingNeighborhood", "session.identity.factionGroup" },
    fn = function(state)
        local pick = state.account.ui.shoppingNeighborhood
        if pick ~= "" then return pick end
        local fg = state.session.identity.factionGroup
        if fg == "A" then return "alliance" end
        if fg == "H" then return "horde"    end
        return nil
    end,
})

-- The word beside the toggle. The switch carries the choice in colour, which
-- is exactly what a colour-blind player cannot read -- so the side is also
-- named. account.config.locale is declared because this sits on the shopping
-- SATELLITE window, which RefreshMainWindow does not repaint on a locale swap
-- (same reason merchant.buyAllLabel declares it).
Selectors:Register("shopping.neighborhoodLabel", {
    calls = { "shopping.neighborhood" },
    reads = { "account.config.locale" },
    fn = function(state, ctx)
        local faction = Selectors:Call("shopping.neighborhood", state, ctx)
        if faction == "alliance" then return HDG.Locale:Get("SHOP_NBHD_ALLIANCE") end
        if faction == "horde"    then return HDG.Locale:Get("SHOP_NBHD_HORDE")    end
        return HDG.Locale:Get("SHOP_NBHD_NONE")
    end,
})

-- Active list record or nil when no list active.
Selectors:Register("shopping.activeList", {
    reads = { "account.vendorShoppingLists", "account.activeShoppingListId" },
    fn = function(state)
        local id = state.account.activeShoppingListId
        if id == "" then return nil end
        return state.account.vendorShoppingLists[id]
    end,
})

-- Active list ID as bare primitive for dropdown binding.current.
Selectors:Register("shopping.activeListId", {
    reads = { "account.activeShoppingListId" },
    fn = function(state) return state.account.activeShoppingListId end,
})

-- True when the account has >1 shopping list -> gates the Delete-List button
-- (you can't delete your only list, which keeps activeShoppingListId non-empty
-- so "Add to Cart" never dead-ends).
Selectors:Register("shopping.hasMultipleLists", {
    reads = { "account.vendorShoppingLists" },
    fn = function(state)
        local n = 0
        for _ in pairs(state.account.vendorShoppingLists) do
            n = n + 1
            if n > 1 then return true end
        end
        return false
    end,
})

-- Menu items for the list-switcher dropdown. Alphabetical by name.
Selectors:Register("shopping.activeListMenuItems", {
    reads = { "account.vendorShoppingLists" },
    fn = function(state)
        local items = {}
        local sorted = {}
        for id, list in pairs(state.account.vendorShoppingLists) do
            sorted[#sorted + 1] = { id = id, name = list.name or "Unnamed" }
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)
        for _, entry in ipairs(sorted) do
            items[#items + 1] = { text = entry.name, value = entry.id }
        end
        return items
    end,
})

-- Summary stats for the header. goldCost = 0 (cost integration deferred;
-- VendorDB lookup per item would couple this to the static data tick).
Selectors:Register("shopping.summary", {
    -- Counts from FILTERED entries (decor-only) so header tallies match shown rows.
    -- Raw list.items may carry non-decor stacks from pre-decor-filter imports.
    calls = { "shopping.activeListEntries" },
    fn = function(state, ctx)
        local entries = Selectors:Call("shopping.activeListEntries", state, ctx)
        local out = { itemCount = 0, vendorCount = 0, wishCount = 0, ahCount = 0, goldCost = 0 }
        local vendors = {}
        for _, entry in ipairs(entries) do
            local qty = entry.qty or 1   -- migration: legacy imports may omit qty
            out.itemCount = out.itemCount + qty
            -- Three lanes (mirrors _bucketShoppingEntries): vendor (RESOLVED
            -- vendor) | AH (no resolved vendor + tradeable BoE/crafted) | wishlist.
            -- A bare npcID that isn't a real vendor (imported drop) is NOT a vendor.
            if entry.vendor then
                vendors[entry.npcID] = true
            elseif entry.isTradeable then
                out.ahCount = out.ahCount + qty
            else
                out.wishCount = out.wishCount + qty
            end
        end
        for _ in pairs(vendors) do out.vendorCount = out.vendorCount + 1 end
        return out
    end,
})

-- Display text: "12 items - 3 vendors - 2 AH - 5 wish" or "0 items". Reads scheme for future color.
Selectors:Register("shopping.summaryText", {
    reads = { "account.config.scheme" },
    calls = { "shopping.summary" },
    fn = function(state, ctx)
        local s = Selectors:Call("shopping.summary", state, ctx)
        if s.itemCount == 0 then return "0 items" end
        local parts = { string.format("%d items", s.itemCount) }
        if s.vendorCount > 0 then
            parts[#parts + 1] = string.format("%d vendor%s",
                s.vendorCount, s.vendorCount == 1 and "" or "s")
        end
        -- AH/wish counts intentionally dropped from the header line to make room
        -- for the + New button now living beside the list dropdown.
        return table.concat(parts, "  -  ")
    end,
})

-- Attribution metadata from list.meta: source, url, desc, date, author.
-- Five fields from the HDG-interop format. Open button needs url specifically.
Selectors:Register("shopping.attribution", {
    calls = { "shopping.activeList" },
    fn = function(state, ctx)
        local list = Selectors:Call("shopping.activeList", state, ctx)
        if not list or not list.meta then
            return { source = nil, url = nil, desc = nil, date = nil, author = nil }
        end
        return {
            source = list.meta.source,
            url    = list.meta.url,
            desc   = list.meta.desc,
            date   = list.meta.date,
            author = list.meta.author,
        }
    end,
})

-- "player" lists are author-created and don't show the attribution banner.
Selectors:Register("shopping.hasAttribution", {
    calls = { "shopping.attribution" },
    fn = function(state, ctx)
        local a = Selectors:Call("shopping.attribution", state, ctx)
        return a.source ~= nil and a.source ~= "" and a.source ~= "player"
    end,
})

-- URL gate: Open button hidden when no source URL (banner text still shows).
Selectors:Register("shopping.hasUrl", {
    calls = { "shopping.attribution" },
    fn = function(state, ctx)
        local a = Selectors:Call("shopping.attribution", state, ctx)
        return type(a.url) == "string" and a.url ~= ""
    end,
})

-- Banner text: "Imported from <Source>: <desc>  <date>".
Selectors:Register("shopping.attributionText", {
    calls = { "shopping.attribution" },
    fn = function(state, ctx)
        local a = Selectors:Call("shopping.attribution", state, ctx)
        if not a.source or a.source == "" or a.source == "player" then return "" end
        local sourceName = a.source:sub(1, 1):upper() .. a.source:sub(2)
        local label = "Imported from " .. sourceName
        if a.desc and a.desc ~= "" and a.desc:lower() ~= a.source:lower() then
            label = label .. ": " .. a.desc
        end
        local d = HDG.Format.FriendlyDate(a.date)
        if d then label = label .. "  " .. d end
        return label
    end,
})

-- Per-item enrichment with vendor name/zone/mapID/coords.
-- Wishlist entries (npcID nil) carry vendor = nil.
-- Icon resolved via ItemNameResolver:ResolveIcon (boundary); nil on cache miss
-- queues warm-up; session.itemNames.names bump re-fires this selector.
local function resolveIconID(itemID)
    return HDG.ItemNameResolver:ResolveIcon(itemID)
end

-- (gateFlagsForItem retired: replaced by HousingCatalogObserver._bakeSourceFlags.
--  Chip rendering reads row.sourceFlags via UI.GateChips(itemID).)

-- What a shopping list carries: catalog decor, plus the nine Housing Dyes a
-- blueprint's list needs (they have no catalog row). ADR-003a: byItemID is
-- module-internal, not a Blizzard API call. sweepGeneration == 0 (cold): pass all
-- through to avoid discarding decor pre-load.
local function _isShoppable(itemID, sweepGeneration)
    if sweepGeneration == 0 then return true end  -- cold: pass through until sweep
    return HDG.HousingCatalogObserver.byItemID[itemID] ~= nil
        or HDG.Constants.HOUSING_DYE_ITEM_IDS[itemID] == true
end

-- Display-time vendor resolution for wishlist items (no stored npcID): the live
-- catalog's first vendor + VendorAugment, mirroring FindFirstVendorForItem. Never
-- written to state -- this is a render hint so vendor-buyable wishlist items can
-- show "where to buy" without freezing a (possibly wrong / multi-vendor) npcID.
-- Returns a coords-bearing table, a name/zone-only table, or nil (drop/quest/ach
-- items with no vendor).
local function _resolveWishlistVendor(itemID, preferredMapID)
    local crow = HDG.HousingCatalogObserver:GetRow(itemID)
    local cv = HDG.VendorRank.Pick(crow, preferredMapID)
    if not cv then return nil end  -- exception(nullable): drops/quests/achievements have no vendor
    local npc = HDG.StaticData.VendorAugment:ResolveName(cv.name, cv.zone)
    local aug = npc and HDG.StaticData.VendorAugment:Get(npc)
    if aug and aug.mapID and aug.mapID > 0 then
        -- Coords resolved: mapID present == waypointable (consumers key on it).
        return { npcID = npc, name = aug.name, zone = aug.zone,
                 mapID = aug.mapID, x = aug.x, y = aug.y }
    end
    -- Augment missing / coordless: catalog name+zone only (no mapID -> no waypoint).
    local name = (aug and aug.name) or cv.name
    if name and name ~= "" then return { name = name, zone = (aug and aug.zone) or cv.zone } end
    return nil
end

-- Where clicking the item's row takes the player: its recipe on the Recipes tab
-- when it is crafted (which profession, what materials -- the question a crafted
-- item on the list raises), else its Decor entry. Crafted = the catalog row has
-- a recipe, the same test that puts it in the Crafting / Auction House section
-- (GetBindTypeForItem). "none" for what the catalog lacks (a housing dye, or
-- anything before the catalog loads): the row then has no plain click.
local function _opensTo(itemID)
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    if not row then return "none" end  -- exception(nullable): dyes and pre-load items have no catalog row
    if row.recipe then return "recipe" end
    return "decor"
end

Selectors:Register("shopping.activeListEntries", {
    reads = {"session.resolvers.staticData.tick",  "session.itemNames.names", "session.resolvers.catalog.tick" },
    calls = { "shopping.activeList", "shopping.neighborhood" },
    fn = function(state, ctx)
        local list = Selectors:Call("shopping.activeList", state, ctx)
        if not list then return {} end
        local sweep = state.session.resolvers.catalog.tick
        -- Only the wishlist hint below needs this. Entries that already carry an
        -- npcID render the vendor they were resolved to -- ShoppingController
        -- rewrites those on the store when the preference changes, so the
        -- grouping and this hint stay in step without resolving twice.
        local prefFaction  = Selectors:Call("shopping.neighborhood", state, ctx)
        local preferredMap = prefFaction
            and HDG.Constants.NEIGHBORHOOD_MAP_BY_FACTION[prefFaction] or nil
        local out = {}
        for _, entry in ipairs(list.items) do
            -- Drop non-housing items (reagents, crafting mats) that may have
            -- been imported via Wowdb or pushed from the Recipes materials panel.
            -- The shopping list is decor and housing dyes; anything else is noise.
            -- Cold-start (sweep == 0): pass through until catalog loads.
            if _isShoppable(entry.itemID, sweep) then
                -- Vendor coords from VendorAugment; wishlist (no npcID) meta is nil.
                local meta = entry.npcID and HDG.StaticData.VendorAugment:Get(entry.npcID) or nil
                out[#out + 1] = {
                    itemID      = entry.itemID,
                    npcID       = entry.npcID,
                    qty         = entry.qty or 1,   -- migration (legacy import tolerance)
                    addedAt     = entry.addedAt,
                    iconID      = resolveIconID(entry.itemID),
                    gold        = 0,  -- cost not derivable from catalog alone
                    -- VendorAugment row: name/zone/mapID/x/y/faction per npcID.
                    -- nil when entry is wishlist (no npcID) or npcID not yet in augment.
                    vendor = meta and {
                        name    = meta.name,
                        zone    = meta.zone,
                        mapID   = meta.mapID,
                        x       = meta.x,
                        y       = meta.y,
                        faction = meta.faction,
                    } or nil,
                    -- Wishlist (no npcID) render hint: where the catalog says it sells.
                    availableFrom = (not entry.npcID) and _resolveWishlistVendor(entry.itemID, preferredMap) or nil,
                    -- BoE = crafted (Professions) = the only AH-tradeable decor -> Auction House
                    -- lane. Housing dyes never bind, and the AH is where they are bought.
                    isTradeable = HDG.Constants.HOUSING_DYE_ITEM_IDS[entry.itemID] == true
                        or HDG.HousingCatalogObserver:GetBindTypeForItem(entry.itemID) == "BoE",
                    opens = _opensTo(entry.itemID),
                }
            end
        end
        return out
    end,
})

-- Bucket entries into three lanes: vendor (RESOLVED vendor -> zone>vendor>items),
-- Auction House (no resolved vendor but BoE/crafted), and wishlist (everything else
-- -- non-purchasable drops/quests/achievements). Routing keys on a RESOLVED vendor,
-- not a bare npcID: an imported drop/quest can carry an npcID that ISN'T a real
-- vendor in VendorAugment, and those belong in wishlist, not a bogus "Unknown" zone
-- (you can't buy a world-drop from a vendor). Vendor wins over AH.
local function _bucketShoppingEntries(entries)
    local wish, ah, zones, zoneOrder = {}, {}, {}, {}
    for _, entry in ipairs(entries) do
        if not entry.vendor then
            if entry.isTradeable then ah[#ah + 1] = entry else wish[#wish + 1] = entry end
        else
            local zoneName = entry.vendor and entry.vendor.zone or "Unknown"
            local z = zones[zoneName]
            if not z then
                z = { _vendors = {}, _vendorList = {} }
                zones[zoneName] = z
                zoneOrder[#zoneOrder + 1] = zoneName
            end
            local v = z._vendors[entry.npcID]
            if not v then
                v = { vendor = entry.vendor, items = {} }
                z._vendors[entry.npcID] = v
                z._vendorList[#z._vendorList + 1] = entry.npcID
            end
            v.items[#v.items + 1] = entry
        end
    end
    table.sort(zoneOrder)
    for _, zoneName in ipairs(zoneOrder) do
        local z = zones[zoneName]
        table.sort(z._vendorList, function(a, b)
            local va = z._vendors[a].vendor
            local vb = z._vendors[b].vendor
            return (va and va.name or "") < (vb and vb.name or "")
        end)
    end
    return wish, ah, zones, zoneOrder
end

-- Per-item row envelope. Source chips via GateChips(itemID); no per-source flags in envelope.
local function _buildShoppingItemRow(item, npcID)
    return {
        kind   = "item", itemID = item.itemID, npcID = npcID,
        qty    = item.qty,
        opens  = item.opens,
        iconID = item.iconID,
        gold   = item.gold,
        requiresRep = item.requiresRep,
    }
end

-- Append wishlist header (always) + items (when expanded).
-- Even empty wishlist shows a header so the user knows where items would land.
local function _appendWishSection(rows, wish, wishCollapsed)
    rows[#rows + 1] = { kind = "wishHeader", collapsed = wishCollapsed, count = #wish }
    if wishCollapsed then return end
    for _, w in ipairs(wish) do
        rows[#rows + 1] = {
            kind = "wishItem", itemID = w.itemID, qty = w.qty,
            addedAt = w.addedAt, iconID = w.iconID, opens = w.opens,
            availableFrom = w.availableFrom,   -- catalog "where to buy" hint (display only)
        }
    end
end

-- Append Auction House header + items (when expanded). Crafted/BoE decor: bought
-- off the AH (or crafted). Header omitted entirely when empty (unlike wishlist,
-- which has a manual add button -- the AH lane is purely auto-populated).
local function _appendAhSection(rows, ah, ahCollapsed)
    if #ah == 0 then return end
    rows[#rows + 1] = { kind = "ahHeader", collapsed = ahCollapsed, count = #ah }
    if ahCollapsed then return end
    for _, a in ipairs(ah) do
        rows[#rows + 1] = {
            kind = "ahItem", itemID = a.itemID, qty = a.qty,
            addedAt = a.addedAt, iconID = a.iconID, opens = a.opens,
        }
    end
end

-- Append vendor header + (when expanded) per-item rows for one vendor.
local function _appendVendorSection(rows, npcID, v, zoneName, vendorCollapsed)
    local vCollapsed = vendorCollapsed[npcID] == true
    rows[#rows + 1] = {
        kind = "vendor", npcID = npcID,
        name = v.vendor and v.vendor.name or "?",
        zone = zoneName, collapsed = vCollapsed,
        itemCount = #v.items,
    }
    if vCollapsed then return end
    for _, item in ipairs(v.items) do
        rows[#rows + 1] = _buildShoppingItemRow(item, npcID)
    end
end

-- Append zone header + (when expanded) per-vendor sections for one zone.
local function _appendZoneSection(rows, zoneName, z, zoneCollapsed, vendorCollapsed)
    local zCollapsed = zoneCollapsed[zoneName] == true
    rows[#rows + 1] = {
        kind = "zone", zone = zoneName, collapsed = zCollapsed,
        vendorCount = #z._vendorList,
    }
    if zCollapsed then return end
    for _, npcID in ipairs(z._vendorList) do
        _appendVendorSection(rows, npcID, z._vendors[npcID], zoneName, vendorCollapsed)
    end
end

-- Tree-via-flat-projection: wishHeader -> wishItem* -> zone* -> vendor* -> item*.
-- Collapsed state from session.ui.shoppingList.expanded (zones/vendors map; wishList scalar).
Selectors:Register("shopping.entriesByZone", {
    reads = {
        "session.ui.shoppingList.expanded",
        "session.itemNames.names",
        "session.resolvers.catalog.tick",
    },
    calls = { "shopping.activeListEntries" },
    fn = function(state, ctx)
        local entries  = Selectors:Call("shopping.activeListEntries", state, ctx)
        local expanded = state.session.ui.shoppingList.expanded
        local wishCollapsed   = expanded.wishList == true
        local ahCollapsed     = expanded.ahList   == true
        local zoneCollapsed   = expanded.zones    -- map
        local vendorCollapsed = expanded.vendors  -- map

        local wish, ah, zones, zoneOrder = _bucketShoppingEntries(entries)

        -- Order: Wishlist -> Auction House -> vendor zones.
        local rows = {}
        _appendWishSection(rows, wish, wishCollapsed)
        _appendAhSection(rows, ah, ahCollapsed)
        for _, zoneName in ipairs(zoneOrder) do
            _appendZoneSection(rows, zoneName, zones[zoneName], zoneCollapsed, vendorCollapsed)
        end
        return rows
    end,
})

-- ===== Vendor buying (spec docs/HDGR_VENDOR_BUYING_SPEC.md s4) ===============
-- Join key = "itemID stocked at the OPEN merchant", NOT the list entry's stored
-- npcID, so an equivalent vendor selling the same decor still fulfils the list.
Selectors:Register("merchant.purchasableFromList", {
    reads = { "session.merchant" },
    calls = { "shopping.activeListEntries" },
    fn = function(state, ctx)
        local m = state.session.merchant
        if not m.open then return {} end
        local out = {}
        for _, e in ipairs(Selectors:Call("shopping.activeListEntries", state, ctx)) do
            local stock = m.byItemID[e.itemID]
            -- Only gold-priced decor is bulk-buyable for now; currency/token items
            -- are counted as skipped (buyAllSummary) and left for a normal buy.
            if stock and stock.goldOnly then   -- exception(nullable): vendor doesn't carry this / not gold-only
                -- Field names ARE the BuyQueue:Enqueue contract ({index, qty, price,
                -- name}) -- these rows are passed straight to Enqueue on Buy All.
                -- itemID + npcID identify the source list entry so BuyQueue can
                -- decrement it as each unit lands (ADJUST_QTY matches on both).
                out[#out + 1] = { itemID = e.itemID, npcID = e.npcID, name = stock.name,
                                  qty = e.qty, index = stock.index, price = stock.price,
                                  lineCost = stock.price * e.qty }
            end
        end
        return out
    end,
})

-- Summary for the Buy All confirm. listCoverage counts stocked-vs-total list rows.
Selectors:Register("merchant.buyAllSummary", {
    reads = { "session.merchant" },
    calls = { "merchant.purchasableFromList", "shopping.activeListEntries" },
    fn = function(state, ctx)
        local rows    = Selectors:Call("merchant.purchasableFromList", state, ctx)
        local entries = Selectors:Call("shopping.activeListEntries", state, ctx)
        local m = state.session.merchant
        local qty, cost = 0, 0
        for _, r in ipairs(rows) do qty = qty + r.qty; cost = cost + r.lineCost end
        -- Skipped = list items this vendor stocks that carry a currency/token cost
        -- (hasCost, NOT merely non-gold -- a free item isn't "sold for a currency")
        -- -- surfaced so Buy All isn't silently partial.
        local skipped = 0
        for _, e in ipairs(entries) do
            local stock = m.byItemID[e.itemID]
            if stock and stock.hasCost then skipped = skipped + 1 end
        end
        return { rowCount = #rows, totalQty = qty, totalCost = cost, skippedCount = skipped,
                 listCoverage = ("%d of %d list items sold here"):format(#rows, #entries) }
    end,
})

-- Buy All button: enabled only at an open vendor stocking >=1 list item.
Selectors:Register("merchant.buyAllEnabled", {
    reads = { "session.merchant" },
    calls = { "merchant.purchasableFromList" },
    fn = function(state, ctx)
        return state.session.merchant.open
           and #Selectors:Call("merchant.purchasableFromList", state, ctx) > 0
    end,
})

-- Button label: "Cancel (done/total)" while a buy runs, else the localized "Buy All".
Selectors:Register("merchant.buyAllLabel", {
    -- account.config.locale: the idle label is localized, and this button lives on
    -- the shopping SATELLITE window, which RefreshMainWindow doesn't repaint on a
    -- locale switch -- so declare the dependency to invalidate the label directly.
    reads = { "session.merchant.buying", "account.config.locale" },
    fn = function(state, ctx)
        local b = state.session.merchant.buying
        if b then return ("Cancel (%d/%d)"):format(b.done, b.total) end
        return HDG.Locale:Get("SHOP_BUY_ALL")
    end,
})
