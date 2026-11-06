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
    if aug and HDG.VendorRank.HasLocation(aug.mapID, aug.x, aug.y) then
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
--
-- Any price the vendor charges is bought: gold, a currency, items taken as
-- payment, or a mix (Core/HDGR_MerchantWallet.lua). What stays out of Buy All is
-- what the vendor will not sell you yet (isPurchasable false -- reputation and
-- the like) and a slot whose price has not streamed in.
local W = HDG.MerchantWallet

-- The active list's entries this vendor sells, locked or not:
-- { { entry, stock, buyable }, ... } in list order.
Selectors:Register("merchant.stockedFromList", {
    reads = { "session.merchant.open", "session.merchant.byItemID" },
    calls = { "shopping.activeListEntries" },
    fn = function(state, ctx)
        local m = state.session.merchant
        if not m.open then return {} end
        local out = {}
        for _, e in ipairs(Selectors:Call("shopping.activeListEntries", state, ctx)) do
            local stock = m.byItemID[e.itemID]
            if stock then   -- exception(nullable): this vendor doesn't carry it
                out[#out + 1] = { entry = e, stock = stock, buyable = W.IsBuyable(stock) }
            end
        end
        return out
    end,
})

-- What Buy All buys. Field names ARE the BuyQueue:Enqueue contract ({ index,
-- itemID, qty, costs, name }) -- these rows go straight to Enqueue on accept.
-- npcID rides along to identify the source list entry.
Selectors:Register("merchant.purchasableFromList", {
    calls = { "merchant.stockedFromList" },
    fn = function(state, ctx)
        local out = {}
        for _, s in ipairs(Selectors:Call("merchant.stockedFromList", state, ctx)) do
            if s.buyable then
                out[#out + 1] = { itemID = s.entry.itemID, npcID = s.entry.npcID, name = s.stock.name,
                                  qty = s.entry.qty, index = s.stock.index, costs = s.stock.costs }
            end
        end
        return out
    end,
})

-- The whole run, priced against the wallet: what it spends of each payment
-- (spend: MerchantWallet.Assess entries), the first payment it cannot cover
-- (short, or nil), and how many list items here are left out as locked.
Selectors:Register("merchant.buyAllSummary", {
    reads = { "session.merchant.wallet" },
    calls = { "merchant.purchasableFromList", "merchant.stockedFromList" },
    fn = function(state, ctx)
        local rows = Selectors:Call("merchant.purchasableFromList", state, ctx)
        local qty = 0
        for _, r in ipairs(rows) do qty = qty + r.qty end
        local spend = W.Assess(W.Spend(rows), state.session.merchant.wallet)
        return { rowCount = #rows, totalQty = qty, spend = spend, short = W.FirstShort(spend),
                 lockedCount = #Selectors:Call("merchant.stockedFromList", state, ctx) - #rows }
    end,
})

local function _countLine(n, oneKey, manyKey)
    if n == 1 then return HDG.Locale:Get(oneKey) end
    return HDG.Locale:Get(manyKey):format(n)
end

-- The Buy All confirm's body: "Buy 18 items?", what it spends of each payment,
-- every payment it uses more than half of (warning colour), and the locked items
-- it leaves out. account.config.scheme / locale: colour codes and words baked in.
Selectors:Register("merchant.buyAllConfirmText", {
    reads = { "account.config.scheme", "account.config.locale" },
    calls = { "merchant.buyAllSummary" },
    fn = function(state, ctx)
        local s = Selectors:Call("merchant.buyAllSummary", state, ctx)
        local lines = { _countLine(s.totalQty, "MERCHANT_CONFIRM_ONE", "MERCHANT_CONFIRM_MANY"),
                        W.SpendLine(s.spend) }
        local warn = W.WarnLines(s.spend)
        if #warn > 0 then
            lines[#lines + 1] = HDG.Theme:ColorCode("semantic.warning") .. table.concat(warn, "\n") .. "|r"
        end
        if s.lockedCount > 0 then
            lines[#lines + 1] = _countLine(s.lockedCount, "MERCHANT_LOCKED_ONE", "MERCHANT_LOCKED_MANY")
        end
        return table.concat(lines, "\n")
    end,
})

-- Buy All button (shopping window and vendor sidebar): while a run is going it is
-- the Stop button, so it stays live; otherwise it needs something to buy and a
-- wallet that covers all of it -- the sidebar's footer names what's short.
Selectors:Register("merchant.buyAllEnabled", {
    reads = { "session.merchant.open", "session.merchant.buying" },
    calls = { "merchant.buyAllSummary" },
    fn = function(state, ctx)
        local m = state.session.merchant
        if not m.open then return false end
        if m.buying then return true end
        local s = Selectors:Call("merchant.buyAllSummary", state, ctx)
        return s.totalQty > 0 and s.short == nil
    end,
})

-- Shopping window's Buy All label: "Stop (done/total)" while a run goes -- this
-- window has no other progress readout -- else "Buy All (N)", or plain "Buy All"
-- with nothing here to buy.
Selectors:Register("merchant.buyAllLabel", {
    -- account.config.locale: the idle label is localized, and this button lives on
    -- the shopping SATELLITE window, which RefreshMainWindow doesn't repaint on a
    -- locale switch -- so declare the dependency to invalidate the label directly.
    reads = { "session.merchant.buying", "account.config.locale" },
    calls = { "merchant.buyAllSummary" },
    fn = function(state, ctx)
        local b = state.session.merchant.buying
        if b then return HDG.Locale:Get("SHOP_BUY_ALL_STOP"):format(b.done, b.total) end
        local n = Selectors:Call("merchant.buyAllSummary", state, ctx).totalQty
        if n == 0 then return HDG.Locale:Get("SHOP_BUY_ALL") end
        return HDG.Locale:Get("SHOP_BUY_ALL_COUNT"):format(n)
    end,
})

-- ===== Vendor sidebar (UI/HDGR_Controller_VendorSidebar.lua) =================
-- Beside Blizzard's merchant window: every list with how many of its items this
-- vendor sells, the active list's items here with their prices, the run's spend
-- against the wallet, and Buy All. Mockup docs/mockups/vendor_sidebar.html.

-- How many of a list's items this vendor sells -- the same items
-- shopping.activeListEntries keeps (catalog decor and housing dyes), so the
-- active list's count and its item rows agree.
local function _countHere(list, byItemID, sweep)
    local n = 0
    for _, entry in ipairs(list.items) do
        if byItemID[entry.itemID] and _isShoppable(entry.itemID, sweep) then n = n + 1 end
    end
    return n
end

-- Lists with items at this vendor on top (owner 2026-11-02: with many lists the
-- ones that matter here were scrolled out of sight), then the rest; each half
-- keeps the switcher's order.
local function _hereFirst(rows)
    local out = {}
    for _, r in ipairs(rows) do if r.here > 0 then out[#out + 1] = r end end
    for _, r in ipairs(rows) do if r.here == 0 then out[#out + 1] = r end end
    return out
end

-- Every list: { { id, name, here, active }, ... }, those with items here first.
Selectors:Register("merchant.sidebarLists", {
    reads = { "account.vendorShoppingLists", "account.activeShoppingListId", "session.merchant.open",
              "session.merchant.byItemID", "session.resolvers.catalog.tick" },
    calls = { "shopping.activeListMenuItems" },
    fn = function(state, ctx)
        local m = state.session.merchant
        local lists, active = state.account.vendorShoppingLists, state.account.activeShoppingListId
        local sweep = state.session.resolvers.catalog.tick
        local out = {}
        for _, item in ipairs(Selectors:Call("shopping.activeListMenuItems", state, ctx)) do
            out[#out + 1] = { id = item.value, name = item.text, active = item.value == active,
                              here = m.open and _countHere(lists[item.value], m.byItemID, sweep) or 0 }
        end
        return _hereFirst(out)
    end,
})

-- Shown at an open vendor that sells something on any list, unless the setting
-- is off or the X hid it for this visit. Kept up while a run goes: the purchase
-- credit takes bought items off the list, and the last one landing would
-- otherwise pull the sidebar away from under its own progress bar.
Selectors:Register("merchant.sidebarShown", {
    reads = { "session.merchant.open", "session.merchant.sidebarDismissed", "session.merchant.buying",
              "account.config.merchantVendorSidebar" },
    calls = { "merchant.sidebarLists" },
    fn = function(state, ctx)
        local m = state.session.merchant
        if not (m.open and state.account.config.merchantVendorSidebar) or m.sidebarDismissed then return false end
        if m.buying then return true end
        for _, list in ipairs(Selectors:Call("merchant.sidebarLists", state, ctx)) do
            if list.here > 0 then return true end
        end
        return false
    end,
})

local function _activeListName(state, ctx)
    local list = Selectors:Call("shopping.activeList", state, ctx)
    if not list then return HDG.Locale:Get("SHOP_NO_LIST") end   -- exception(nullable): no list is active
    return list.name
end

-- "<list> at this vendor".
Selectors:Register("merchant.sidebarHeading", {
    reads = { "account.config.locale" },
    calls = { "shopping.activeList" },
    fn = function(state, ctx)
        return HDG.Locale:Get("VSIDE_AT_VENDOR"):format(_activeListName(state, ctx))
    end,
})

-- One cost per line, for the item row's right column ("120g" over "20 Undercoin").
local function _costLines(costs, qty)
    local lines = {}
    for _, cost in ipairs(costs) do lines[#lines + 1] = W.FormatAmount(cost, cost.amount * qty) end
    return table.concat(lines, "\n")
end

local function _sidebarItem(s)
    local e, stock = s.entry, s.stock
    local ed = { itemID = e.itemID, npcID = e.npcID, icon = stock.icon, buyable = s.buyable,
                 name = stock.name or "?" }   -- exception(boundary): MerchantItemInfo.name is nilable while a slot streams in
    if s.buyable then
        ed.sub  = HDG.Locale:Get("VSIDE_WANT"):format(e.qty, W.FormatCosts(stock.costs, 1))
        ed.cost = _costLines(stock.costs, e.qty)
    else
        ed.sub  = HDG.Locale:Get("VSIDE_LOCKED")
        ed.cost = HDG.Locale:Get("VSIDE_NOT_IN_BUY_ALL")
    end
    return ed
end

-- The active list's items at this vendor, as row envelopes: { itemID, npcID,
-- icon, name, buyable, sub, cost }. sub/cost carry their colour codes.
Selectors:Register("merchant.sidebarItems", {
    reads = { "account.config.scheme", "account.config.locale" },
    calls = { "merchant.stockedFromList" },
    fn = function(state, ctx)
        local out = {}
        for _, s in ipairs(Selectors:Call("merchant.stockedFromList", state, ctx)) do
            out[#out + 1] = _sidebarItem(s)
        end
        return out
    end,
})

Selectors:Register("merchant.sidebarHasItems", {
    calls = { "merchant.stockedFromList" },
    fn = function(state, ctx) return #Selectors:Call("merchant.stockedFromList", state, ctx) > 0 end,
})

Selectors:Register("merchant.sidebarEmpty", {
    calls = { "merchant.sidebarHasItems" },
    fn = function(state, ctx) return not Selectors:Call("merchant.sidebarHasItems", state, ctx) end,
})

-- "Nothing on <list> is sold here." and where to look instead.
Selectors:Register("merchant.sidebarEmptyText", {
    reads = { "account.config.locale" },
    calls = { "shopping.activeList" },
    fn = function(state, ctx)
        return HDG.Locale:Get("VSIDE_EMPTY"):format(_activeListName(state, ctx))
            .. "\n\n" .. HDG.Locale:Get("VSIDE_EMPTY_HINT")
    end,
})

-- One wallet line: "Undercoin: 320 of 400  .  80%". The amount keeps its
-- payment's colour; a payment the run uses more than half of reads in the
-- warning colour, one it cannot cover in the error colour.
local function _walletLine(e)
    local text = HDG.Locale:Get("VSIDE_WALLET_LINE"):format(W.Name(e), W.FormatAmount(e, e.amount),
                                                         W.PlainAmount(e, e.have))
    if e.short then
        return HDG.Theme:ColorCode("semantic.error") .. HDG.Locale:Get("VSIDE_WALLET_SHORT"):format(text) .. "|r"
    end
    if e.flagged then
        return HDG.Theme:ColorCode("semantic.warning") .. HDG.Locale:Get("VSIDE_WALLET_PCT"):format(text, e.pct) .. "|r"
    end
    return text
end

-- The footer's spend, one line per payment, or "0 items" with nothing to buy.
Selectors:Register("merchant.sidebarWalletText", {
    reads = { "account.config.scheme", "account.config.locale" },
    calls = { "merchant.buyAllSummary" },
    fn = function(state, ctx)
        local spend = Selectors:Call("merchant.buyAllSummary", state, ctx).spend
        if #spend == 0 then return HDG.Locale:Get("VSIDE_ZERO") end
        local lines = {}
        for _, e in ipairs(spend) do lines[#lines + 1] = _walletLine(e) end
        return table.concat(lines, "\n")
    end,
})

Selectors:Register("merchant.isBuying", {
    reads = { "session.merchant.buying" },
    fn = function(state) return state.session.merchant.buying ~= nil end,
})

Selectors:Register("merchant.notBuying", {
    reads = { "session.merchant.buying" },
    fn = function(state) return state.session.merchant.buying == nil end,
})

-- "Bought 4 of 18" while a run goes.
Selectors:Register("merchant.sidebarProgressText", {
    reads = { "session.merchant.buying", "account.config.locale" },
    fn = function(state)
        local b = state.session.merchant.buying
        if not b then return "" end
        return HDG.Locale:Get("VSIDE_BOUGHT"):format(b.done, b.total)
    end,
})

Selectors:Register("merchant.sidebarProgress", {
    reads = { "session.merchant.buying" },
    fn = function(state)
        local b = state.session.merchant.buying
        if not b then return 0 end
        -- total >= 1: the queue refuses a run with nothing to buy.
        return b.done / b.total
    end,
})

-- The sidebar's Buy All: "Stop" while a run goes -- the progress line above it
-- carries the count -- else "Buy All (N)", or plain "Buy All" with nothing here.
Selectors:Register("merchant.sidebarBuyLabel", {
    reads = { "session.merchant.buying", "account.config.locale" },
    calls = { "merchant.buyAllSummary" },
    fn = function(state, ctx)
        if state.session.merchant.buying then return HDG.Locale:Get("MERCHANT_STOP") end
        local n = Selectors:Call("merchant.buyAllSummary", state, ctx).totalQty
        if n == 0 then return HDG.Locale:Get("SHOP_BUY_ALL") end
        return HDG.Locale:Get("SHOP_BUY_ALL_COUNT"):format(n)
    end,
})
