-- HDG.Selectors -- Decor tab
-- ============================================================================
-- decor.* selectors: catalog, filter chain, selection, variants, aggregates.
-- Helpers stay file-local.

HDG = HDG or {}
local Selectors = HDG.Selectors
local DF = HDG.DecorFilters

-- ============================================================================
-- Decor browser selectors
-- ============================================================================
-- decor.allItems -> unfiltered sorted list from HousingCatalogObserver
-- decor.filterQuery -> current search query
-- decor.matchingRows -> post-filter rows, catalog order
-- decor.items -> the list (scrollbox binds here): matchingRows, Stored-sorted in Stored mode
-- decor.headerLabel -> "OWNED/TOTAL (PCT%)" + optional "* N shown" tail
--
-- The catalog's own rows, sorted by name. Not copies: the observer patches a row's
-- counts in place when the game moves them, so a count change rebuilds this array
-- of references and nothing else (a copy of every row was ~1.7 MB in WoW on every
-- count change with Decor open, memory plan 2026-10-19 sec 6). Rows are the
-- facade's tables: readers never write to them.
Selectors:Register("decor.allItems", {
    reads    = {"account.collection.ownedDecorIDs", "session.resolvers.catalog.tick"},
    memoized = true,
    fn = function(state, ctx)
        if not HDG.HousingCatalogObserver:IsReady() then return {} end
        local items = {}
        HDG.HousingCatalogObserver:IterateRows(function(_, row) items[#items + 1] = row end)
        table.sort(items, function(a, b)
            if a.name == b.name then return (a.itemID or 0) < (b.itemID or 0) end
            return (a.name or "") < (b.name or "")
        end)
        return items
    end,
})

-- Current search query from session state. Defaults to "" (callers need no nil-guard).
Selectors:Register("decor.filterQuery", {
    reads = {"session.ui.decor.searchQuery"},
    fn = function(state, ctx)
        local decor = state.session.ui.decor
        return decor.searchQuery or ""
    end,
})

-- fn(row) -> true when the row answers every word in the search box: by name,
-- Blizzard tag, facet or vision word (UI/HDGR_DecorSearch.lua). An empty box
-- matches every row.
Selectors:Register("decor.matchesSearch", {
    calls = { "decor.filterQuery" },
    fn = function(state, ctx)
        return HDG.DecorSearch.Build(Selectors:Call("decor.filterQuery", state, ctx))
    end,
})

-- (decor.activeProfessions retired -- profession filtering is the Source menu's
--  "Crafted by" ticks.)

-- Shown items: allItems through the search box (descriptive: decor.matchesSearch),
-- the Destroy list (onlyStored) and the filter menus' ticks (decor.filterUnits) --
-- every one of them, or the closest fits first (decor.match).
-- Data-state gates (catalog Section B):
--   hasItems: catalog ready AND filtered list non-empty -> show list.
--   isBlank:  catalog ready AND filtered list empty     -> "no results".
Selectors:Register("decor.hasItems", {
    calls = { "catalog.isReady", "decor.items" },
    fn = function(state, ctx)
        if not Selectors:Call("catalog.isReady", state, ctx) then return false end
        return #Selectors:Call("decor.items", state, ctx) > 0
    end,
})
Selectors:Register("decor.isBlank", {
    calls = { "catalog.isReady", "decor.items" },
    fn = function(state, ctx)
        if not Selectors:Call("catalog.isReady", state, ctx) then return false end
        return #Selectors:Call("decor.items", state, ctx) == 0
    end,
})

-- ===== decor.matchingRows row helpers =======================================
-- Per-item work split into pure helpers; `f` bundles resolved predicates
-- + filter scalars so each helper takes one context arg.

-- The gates no match mode softens: the search box, the Destroy list (which lists
-- what you own so you can destroy it, hidden PvP decor included) and Hide PvP
-- decor. fn(item) -> boolean.
Selectors:Register("decor.passesBase", {
    calls = { "decor.matchesSearch", "decor.onlyStored", "decor.isStored", "decor.isHiddenPvp" },
    fn = function(state, ctx)
        local matchSearch = Selectors:Call("decor.matchesSearch", state, ctx)
        local onlyStored  = Selectors:Call("decor.onlyStored",    state, ctx)
        local isStored    = Selectors:Call("decor.isStored",      state, ctx)
        local isHiddenPvp = Selectors:Call("decor.isHiddenPvp",   state, ctx)
        return function(item)
            if not matchSearch(item) then return false end
            if onlyStored then return isStored(item.itemID) end
            return not isHiddenPvp(item.itemID)
        end
    end,
})

-- How many of `units` the item fits not, and the last one it missed.
local function _misses(item, units)
    local n, missed = 0, nil
    for i = 1, #units do
        local unit = units[i]
        if not unit.pass(item) then n, missed = n + 1, unit end
    end
    return n, missed
end

-- `units` split into the ones that always narrow and the ones Best first scores.
local function _splitUnits(units)
    local hard, soft = {}, {}
    for _, unit in ipairs(units) do
        local list = unit.hard and hard or soft
        list[#list + 1] = unit
    end
    return hard, soft
end

-- List rows are reused across rebuilds, one table per variantKey: a search keystroke,
-- a favourite or a count change stamped a fresh table for every row that passed
-- (memory plan 2026-10-19 sec 6). A deliberate exception to selector purity: a
-- rebuild overwrites the rows the previous result holds. That is safe because
-- nothing keeps an older result -- the list refills from the new array, which is
-- new on every compute, so `_sameItems` still sees the change. Weak values: the rows
-- go when the window closes (ReleaseListData drops the list's copy, the memo goes
-- with the next invalidation).
local _rowsByKey = setmetatable({}, { __mode = "v" })

-- A list row: the per-view fields, inheriting everything else from its catalog row
-- (`_item`). A row factory's writes land on the list row, never on the catalog row.
local ROW_META = { __index = function(row, key) return row._item[key] end }

-- The row for variantKey, pointed at `item`, holding no flag a fresh row wouldn't:
-- the Intrusive SelectionBehavior writes `selected` onto rows, and the selection
-- sync sets it again after the refill.
local function _reuseRow(variantKey, item)
    local row = _rowsByKey[variantKey]
    if not row then
        row = setmetatable({}, ROW_META)
        _rowsByKey[variantKey] = row
    end
    row._item, row.variantKey, row.selected = item, variantKey, nil
    return row
end

-- `fit` / `fitOf`: Best first's score (how many of the scored filters the decor
-- fits); nil when every listed decor fits them all.
local function _stampDecorRow(item, f, fit, fitOf)
    local id = item.itemID
    local row = _reuseRow(tostring(id) .. ":base", item)
    row.isFavorite       = f.isFavorite(id)
    row.craftableState   = f.craftableState(id)
    row.isCollected      = f.isCollected(id)
    row.inStoredMode     = f.onlyStored == true
    row.destroyableCount = f.destroyableCount(id)
    -- Outside the Stored view, every copy owned (the tooltip's "Owned: N"; owner 10-30: a decor
    -- that is only placed read blank). The Stored view counts storage, all Destroy can act on.
    row.shownCount       = row.inStoredMode and row.destroyableCount or HDG.HousingCatalogObserver:OwnedTotal(id)
    row.fit, row.fitOf   = fit, fitOf
    return row
end

-- A stored-mode row's sort count: the pinned one, else its live count (nothing
-- pinned yet, or a row that joined the list after the pin -- a new search).
local function _sortCount(row, pinned)
    local c = pinned and pinned[row.variantKey]   -- exception(nullable): no pin, or a row the pin never saw
    if c == nil then c = row.destroyableCount end
    return c
end

-- One owned dyed stack's row: the base row's per-view stamps, the stack's own
-- identity and count. Inherits from the catalog row, never from the base list row:
-- the list's Intrusive SelectionBehavior writes `selected` onto the base row, and
-- every variant would read it through.
local function _stampVariantRow(stamped, item, dv)
    local row = _reuseRow(tostring(stamped.itemID) .. ":" .. tostring(dv.variantIdentifier), item)
    row.isFavorite         = stamped.isFavorite
    row.craftableState     = stamped.craftableState
    row.isCollected        = stamped.isCollected
    row.inStoredMode       = stamped.inStoredMode
    row.fit, row.fitOf     = stamped.fit, stamped.fitOf
    row.isVariantRow       = true
    row.variantIdentifier  = dv.variantIdentifier
    row.dyeColorIDs        = dv.dyeColorIDs
    row.dyeColorsByChannel = dv.dyeColorsByChannel
    row.numStored          = dv.numStored
    row.destroyableCount   = dv.numStored
    row.shownCount         = dv.numStored   -- a stack's copies in storage: the catalog doesn't split placed by dye
    row.entryID            = dv.entryID   -- per-variant destroy identity (else destroy hits the base stack)
    return row
end

-- Append base row then one row per owned dyed variant. With Dyed ticked the
-- undyed base is suppressed. variantKey (itemID:variant) is pool + selection
-- identity. Each variant carries its own dv.numStored (not the aggregate base count).
local function _emitDecorRows(out, item, stamped, dyedOnly)
    local dyedVariants = stamped.dyedVariants
    local hasDyed = dyedVariants and #dyedVariants > 0
    -- Base row = the undyed (vid=0) variant. In Stored view, suppress it when the item
    -- has dyed stacks but zero undyed copies (Blizzard's showQuantity > 0) -- else the
    -- undyed slot renders a phantom count that can't be destroyed.
    local hideEmptyUndyed = hasDyed and stamped.inStoredMode and stamped.destroyableCount <= 0
    if not (dyedOnly and hasDyed) and not hideEmptyUndyed then
        out[#out + 1] = stamped
    end
    if not hasDyed then return end
    for _, dv in ipairs(dyedVariants) do
        out[#out + 1] = _stampVariantRow(stamped, item, dv)
    end
end

-- ===== Sort ==================================================================
-- The catalog's rows arrive by name (decor.allItems). Every other order falls
-- back to the name, so two decor that tie stay where the name put them.

local function _byName(a, b)
    local na, nb = a.name or "", b.name or ""   -- exception(boundary): the catalog can answer a row before its name (decor.allItems sorts the same way)
    if na == nb then return a.itemID < b.itemID end
    return na < nb
end

-- A decor's newest expansion: one the game tags with two (Lost Explorers' Mailbox:
-- Battle for Azeroth and Midnight) sorts with the later. 0 = no expansion tag.
local function _expansionRank(item)
    local rank = 0
    if not item.expansion then return rank end   -- exception(nullable): a decor the game tags with no expansion
    for _, name in ipairs(HDG.Expansion.Members(item.expansion)) do
        local index = HDG.Expansion.GetIndex(name)
        if index and index > rank then rank = index end   -- exception(nullable): a tag name EXPANSION_DATA does not know
    end
    return rank
end

-- Each order's sort key, smallest first. The key is worked out once per decor,
-- not once per comparison.
local SORT_KEYS = {
    newest = function(item) return -_expansionRank(item) end,
    cost   = function(item) return item.placementCost or 0 end,   -- exception(boundary): catalog struct field sparse
    owned  = function(item) return -HDG.HousingCatalogObserver:OwnedTotal(item.itemID) end,
}

-- `items` in the chosen order: itself for "name" (how it arrived), a sorted copy otherwise.
local function _sortItems(items, sort)
    local keyOf = SORT_KEYS[sort]
    if not keyOf then return items end   -- exception(nullable): "name" has no key, the catalog order is it
    local out, key = {}, {}
    for i = 1, #items do
        local item = items[i]
        out[i], key[item] = item, keyOf(item)
    end
    table.sort(out, function(a, b)
        if key[a] ~= key[b] then return key[a] < key[b] end
        return _byName(a, b)
    end)
    return out
end

-- ===== The two match modes ===================================================

-- A heading row of the Best first list: "Fits 3 of 4 (11)". No itemID, so the row
-- factory wires no click and the header count skips it. Headings come only with
-- a second band, so "all" is never "all 1".
local function _bandRow(fit, fitOf, count)
    local label
    if fit < fitOf then
        label = HDG.Locale:Get("DECOR_BAND_SOME"):format(fit, fitOf, count)
    else
        label = HDG.Locale:Get("DECOR_BAND_ALL"):format(fitOf, count)
    end
    return { variantKey = "band:" .. fit, isBand = true, name = label, fit = fit, fitOf = fitOf }
end

-- Every filter: a decor is listed when it fits them all.
local function _allRows(all, f)
    local out = {}
    -- By name, the catalog's own order: rows are stamped as the walk finds them.
    -- (A second array of what passed was 37 KB on every search, favourite and
    -- count change with Decor open -- offline harness, 2026-11-22.)
    if not SORT_KEYS[f.sort] then
        for _, item in ipairs(all) do
            if f.passesBase(item) and _misses(item, f.units) == 0 then
                _emitDecorRows(out, item, _stampDecorRow(item, f), f.dyedOnly)
            end
        end
        return out
    end
    local items = {}
    for _, item in ipairs(all) do
        if f.passesBase(item) and _misses(item, f.units) == 0 then items[#items + 1] = item end
    end
    for _, item in ipairs(_sortItems(items, f.sort)) do
        _emitDecorRows(out, item, _stampDecorRow(item, f), f.dyedOnly)
    end
    return out
end

-- Best first: the hard filters narrow as ever; every remaining decor is scored by
-- how many of the other filters it fits, and listed under a heading per score,
-- best first -- down to DECOR_BEST_MATCH_MAX_MISSES misses (half the filters once
-- there are many), and never a decor that fits none.
local function _bestRows(all, f, hard, soft)
    local of = #soft
    -- Two misses at most -- or half, once that is the looser of the two: a dozen
    -- ticks (Find similar) would otherwise list next to nothing.
    local floor = math.max(1, math.min(of - HDG.Constants.DECOR_BEST_MATCH_MAX_MISSES, math.ceil(of / 2)))
    local bands = {}
    for _, item in ipairs(all) do
        if f.passesBase(item) and _misses(item, hard) == 0 then
            local fit = of - _misses(item, soft)
            if fit >= floor then
                local band = bands[fit]
                if not band then
                    band = {}
                    bands[fit] = band
                end
                band[#band + 1] = item
            end
        end
    end
    -- Headings and scores only when some decor falls short. Best first is the
    -- default, so a list in which every decor fits every filter reads as the
    -- plain list it is.
    local short = false
    for fit = of - 1, floor, -1 do
        if bands[fit] then short = true end
    end
    local out = {}
    for fit = of, floor, -1 do
        local band = bands[fit]
        if band then   -- exception(nullable): no decor scored this fit
            if short then out[#out + 1] = _bandRow(fit, of, #band) end
            for _, item in ipairs(_sortItems(band, f.sort)) do
                local stamped = short and _stampDecorRow(item, f, fit, of) or _stampDecorRow(item, f)
                _emitDecorRows(out, item, stamped, f.dyedOnly)
            end
        end
    end
    return out
end

-- The Decor list's rows, before the Stored sort. Apart from decor.items so the
-- Destroy list's sort pin, which every tab switch clears, never reaches the
-- rows: outside Stored mode decor.items hands the list this same table back and
-- the list skips its refill (2,000 rows restamped and refilled on every switch in
-- and out of Decor, memory plan 2026-10-19 sec 6).
Selectors:Register("decor.matchingRows", {
    -- Memoized: decor.headerLabel calls through decor.items for "shown N", which
    -- would double-walk ~2000 items per dispatch without caching.
    memoized = true,
    -- The rows' owned count is the catalog observer's own OwnedTotal (review L1, 10-31).
    reads = { "session.resolvers.catalog.tick" },
    calls = {
        "decor.allItems",
        "decor.passesBase",
        "decor.filterUnits",
        "decor.filterTicks",
        "decor.match",
        "decor.sort",
        "decor.onlyStored",
        "decor.isCollected",
        "decor.destroyableCount",
        "decor.isFavorite",
        "decor.craftableState",
        -- decor.selectedItemID retired: selection highlight owned by
        -- SelectionBehaviorMixin; clicks no longer invalidate the items list.
    },
    fn = function(state, ctx)
        local all = Selectors:Call("decor.allItems", state, ctx)
        -- Resolve all per-item predicates once (not per row) and bundle into `f`.
        local f = {
            passesBase       = Selectors:Call("decor.passesBase",       state, ctx),
            units            = Selectors:Call("decor.filterUnits",      state, ctx),
            sort             = Selectors:Call("decor.sort",             state, ctx),
            onlyStored       = Selectors:Call("decor.onlyStored",       state, ctx),
            isCollected      = Selectors:Call("decor.isCollected",      state, ctx),
            isFavorite       = Selectors:Call("decor.isFavorite",       state, ctx),
            craftableState   = Selectors:Call("decor.craftableState",   state, ctx),
            destroyableCount = Selectors:Call("decor.destroyableCount", state, ctx),
            dyedOnly         = Selectors:Call("decor.filterTicks",      state, ctx)[HDG.DecorFilters.Tick("status", "dyed")] == true,
        }
        if Selectors:Call("decor.match", state, ctx) == "best" then
            local hard, soft = _splitUnits(f.units)
            -- Nothing to score: Best first is Every filter.
            if #soft > 0 then return _bestRows(all, f, hard, soft) end
        end
        return _allRows(all, f)
    end,
})

-- The Decor list. Stored mode (the Destroy list) sorts most-cluttering first
-- (destroyable count desc, name asc), by the pinned counts once the player has
-- destroyed from it -- into a copy, because decor.matchingRows' table is memoized.
-- Best first's headings have nothing to do there: they are dropped.
Selectors:Register("decor.items", {
    memoized = true,
    calls = { "decor.matchingRows", "decor.onlyStored", "decor.pinnedSortCounts" },
    fn = function(state, ctx)
        local rows = Selectors:Call("decor.matchingRows", state, ctx)
        if not Selectors:Call("decor.onlyStored", state, ctx) then return rows end
        local pinned = Selectors:Call("decor.pinnedSortCounts", state, ctx)
        local out = {}
        for _, row in ipairs(rows) do
            if not row.isBand then out[#out + 1] = row end
        end
        table.sort(out, function(a, b)
            local da, db = _sortCount(a, pinned), _sortCount(b, pinned)
            if da ~= db then return da > db end
            local na, nb = a.name or "", b.name or ""   -- exception(boundary): the catalog can answer a row before its name
            if na ~= nb then return na < nb end
            -- Two stacks of one decor, or two decor of one name: without this the
            -- sort is free to swap them between rebuilds.
            return a.variantKey < b.variantKey
        end)
        return out
    end,
})

-- The Destroy decor list's sort order, pinned by the first destroy from it
-- (DECOR_PIN_STORED_SORT) so rows stay put while the player works down it.
Selectors:Register("decor.pinnedSortCounts", {
    reads = {"session.ui.decor.pinnedSortCounts"},
    fn = function(state, ctx)
        return state.session.ui.decor.pinnedSortCounts   -- exception(nullable): nil = not pinned, sort by live counts
    end,
})

-- Decor selection. Detail pane + model preview bind through this chain.
Selectors:Register("decor.selectedItemID", {
    memoized = true,
    reads = {"session.ui.decor.selectedItemID", "session.resolvers.staticData.tick"},
    fn = function(state, ctx)
        local d = state.session.ui.decor
        return d.selectedItemID or nil
    end,
})
-- Which variant row is selected ("itemID:variantIdentifier" or "itemID:base").
-- Drives list highlight + dyed model preview.
Selectors:Register("decor.selectedVariantKey", {
    memoized = true,
    reads = {"session.ui.decor.selectedVariantKey"},
    fn = function(state, ctx)
        return state.session.ui.decor.selectedVariantKey or nil
    end,
})

-- Observer is primary. Returns nil while catalog loads (layout shows loading panel).
-- destroyTarget: what a destroy acts on for one Decor row -- that row's own
-- variant. variantKey "<itemID>:<variantIdentifier>" names a dyed variant;
-- anything else ("<itemID>:base", or nil) is the undyed stack. Returns the
-- entryVariantID DestroyEntry takes and the stored copies of THAT variant: the
-- base entry's aggregate destroyableInstanceCount is off by one, and a destroy
-- through the base entry never touches dyed copies. nil when the catalog has no
-- row. ONE rule for the detail panel's Destroy button and the browser's
-- Ctrl-Shift-click, so the two can never disagree about which copies go.
Selectors:Register("decor.destroyTarget", {
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local byItemID = HDG.HousingCatalogObserver.byItemID
        return function(itemID, variantKey)
            local row = byItemID[itemID]
            if not row then return nil end   -- exception(nullable): catalog lookup can miss
            if variantKey and row.dyedVariants then
                for _, dv in ipairs(row.dyedVariants) do
                    if variantKey == tostring(itemID) .. ":" .. tostring(dv.variantIdentifier) then
                        return dv.entryID, dv.numStored
                    end
                end
            end
            return row.entryID, row.undyedNumStored or row.quantity  -- exception(nullable): undyedNumStored nil for non-customizable decor -> all copies undyed
        end
    end,
})

-- destroyProgress: { total, done, name } while HDGR_DestroyQueue runs, nil
-- otherwise. `done` is copies the server took, never copies merely sent.
Selectors:Register("decor.destroyProgress", {
    reads = {"session.destroying"},
    fn = function(state, ctx)
        return state.session.destroying   -- exception(nullable): nil = no run
    end,
})

Selectors:Register("decor.selectedItem", {
    memoized = true,
    calls = {"decor.selectedItemID", "decor.selectedVariantKey", "decor.destroyTarget"},
    reads = {"session.resolvers.catalog.tick", "session.identity.factionGroup"},
    fn = function(state, ctx)
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        if not id then return nil end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row then return nil end  -- catalog cold or item not in catalog
        -- Primary vendor -- the map/waypoint target and the source-line hyperlink.
        -- NOT a source-priority decision any more: this panel used to recompute
        -- its own vendor-first sourceType while the bake ran quest-first, so the
        -- detail panel and the tooltip for one piece could name different sources.
        local firstVendor = row.vendors and row.vendors[1]
        local mapVendor   = row.vendors and HDG.VendorRank.MapVendor(row.vendors, state.session.identity.factionGroup)

        -- Destroy identity: the selected row's own variant (decor.destroyTarget).
        local vEntryID, vDestroyable = Selectors:Call("decor.destroyTarget", state, ctx)(
            id, Selectors:Call("decor.selectedVariantKey", state, ctx))
        return {
            itemID        = id,
            decorID       = row.decorID,
            name          = row.name or "Unknown",
            profession    = (row.recipe and row.recipe.profession) or "?",
            expansion     = row.expansion or "?",
            sourceType    = row.sourceType,   -- baked vendor-first (_bakeSourceTypes)
            sourceName    = row.sourceName,
            sourceDetail  = row.sourceDetail,  -- exception(nullable): vendor zone only; non-vendor sources have no detail
            sourceNpcID   = firstVendor and firstVendor.npcID or nil,  -- exception(nullable): non-vendor sources have no npc; drives the source-line vendor hyperlink
            -- Sold by a vendor at all: + Map / + Way show (greyed when `vendor` is nil).
            hasVendor     = firstVendor ~= nil,
            -- The Map / Way target (same shape Shop-by-Vendor feeds HDG.Waypoints).
            vendor        = mapVendor
                            and { mapID = mapVendor.mapID, x = mapVendor.x, y = mapVendor.y,
                                  name = mapVendor.name, zone = mapVendor.zone, side = mapVendor.side }
                            or nil,  -- exception(nullable): non-vendor decor / no vendor has a location
            sourceTags    = row.sourceTags,   -- full baked tag list for the detail chip strip
            canCustomize  = row.canCustomize or false,
            isOwned       = row.isOwned or false,
            numStored     = row.quantity,
            categoryName             = row.categoryName,
            subcategoryName          = row.subcategoryName,
            isUniqueTrophy           = row.isUniqueTrophy or false,
            isAllowedIndoors         = row.isAllowedIndoors,
            isAllowedOutdoors        = row.isAllowedOutdoors,
            placementCost            = row.placementCost or 0,  -- exception(boundary): catalog struct field sparse
            numPlaced                = row.numPlaced,
            destroyableInstanceCount = vDestroyable,
            firstAcquisitionBonus    = row.firstAcquisitionBonus,
            dataTagsByID             = row.dataTagsByID,
            entryID                  = vEntryID,
        }
    end,
})

-- True when decor.selectedItem resolves to a non-nil record (e.g. Cart+ button gate).
Selectors:Register("decor.hasSelectedItem", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        return Selectors:Call("decor.selectedItem", state, ctx) ~= nil
    end,
})

-- True when the selected decor is sold by a vendor -> + Map / + Way are shown.
Selectors:Register("decor.selectedItemHasVendor", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local sel = Selectors:Call("decor.selectedItem", state, ctx)
        return sel ~= nil and sel.hasVendor
    end,
})

-- True when one of those vendors has a location -> + Map / + Way are enabled.
Selectors:Register("decor.selectedItemHasVendorWaypoint", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local sel = Selectors:Call("decor.selectedItem", state, ctx)
        return sel ~= nil and sel.vendor ~= nil
    end,
})

Selectors:Register("decor.selectedItem.name", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        return v and v.name or "Click an item"
    end,
})
-- Profession line. Empty string for non-crafted items so the widget collapses.
-- Prefers sourceName (expansion-prefixed, e.g. "Draenor Engineering (80)") over
-- raw recipe profession when present.
Selectors:Register("decor.selectedItem.profession", {
    -- account.config.scheme: this selector bakes Theme color codes into
    -- the returned string, so it must re-run when the scheme switches.
    reads = {"account.config.scheme"},
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        if not v then return "" end
        if v.sourceType ~= 6 then return "" end           -- 6 = CRAFTED
        local profName = (v.sourceName ~= "" and v.sourceName ~= "Crafted") and v.sourceName
                         or (v.profession ~= "?" and v.profession)
        if not profName then return "" end
        local accent = HDG.Theme:ColorCode("semantic.accent")
        local known  = HDG.Theme:GetTextStateColorToken("known_self")
        return string.format("%sProfession:|r %s%s|r", accent, known, profName)
    end,
})
-- Where the RECIPE comes from, for a crafted piece: "Recipe: Profession
-- Trainer -- Classic Alchemy (25)". Distinct from the Profession line above,
-- which says what skill makes it; this says how you get the pattern.
--
-- Reference data, shown whether or not the recipe is known (owner ruling
-- 2026-08-31). Collapses to "" when the piece is not crafted, when the recipe
-- has no acquisition text (about 1 in 20), or before the resolver's first fill
-- -- the same convention decor.selectedItem.profession uses, so an absent
-- answer reads as absent rather than as an empty row.
--
-- "Crafted" is recipes.db's answer: the seed, then the player's own capture for
-- a recipe the seed doesn't ship (owner ruling 2026-10-31). The row's CRAFTED
-- headline can't say it: the catalog bake reads the seed only, so a capture-only
-- piece never gets one. Every seed recipe in the recorded catalog has that
-- headline (305 of 305), so for them the line shows exactly as before.
--
-- session.resolvers.recipeSource.tick is the facade's declared read: without
-- it, a card opened before the first fill would never repaint with the answer.
Selectors:Register("decor.selectedItem.recipeSource", {
    reads = {"account.config.scheme", "session.resolvers.recipeSource.tick"},
    calls = {"decor.selectedItem", "recipes.db"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        if not v then return "" end
        local sources = HDG.ProfessionScanner:GetRecipeSourceForItem(v.itemID, Selectors:Call("recipes.db", state, ctx))
        local best    = HDG.RecipeSourceParse.Best(sources)
        if not best then return "" end
        local where = best.name or ""
        if best.zone and best.zone ~= "" then where = where .. " (" .. best.zone .. ")" end
        -- The kind normally adds the "how" the line's own label cannot say
        -- ("Recipe: Profession Trainer -- Classic Alchemy"). When the game's own
        -- kind IS "Recipe", repeating it reads as a stutter -- "Recipe: Recipe
        -- -- Purchasable on the Auction House" -- so the value stands alone.
        local text = (best.kind == "Recipe") and where
                     or (best.kind .. " -- " .. where)
        local accent = HDG.Theme:ColorCode("semantic.accent")
        local body   = HDG.Theme:GetTextStateColorToken("known_self")
        return string.format("%sRecipe:|r %s%s|r", accent, body, text)
    end,
})

Selectors:Register("decor.selectedItem.expansion", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        if not v or not v.expansion or v.expansion == "?" then return "" end
        return "Expansion: " .. v.expansion
    end,
})
Selectors:Register("decor.selectedItem.itemID", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        return v and ("itemID: " .. tostring(v.itemID)) or ""
    end,
})

-- Source label: chip-style [VEND] / [QST] / [PROF] + name + "(detail)".
-- Consistent with sourceLine rendering across every detail-panel source surface.
Selectors:Register("decor.selectedItem.sourceLabel", {
    reads = {"account.config.scheme"},
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        if not v then return "" end
        -- All source chips from baked sourceTags (same as GateChips in row factories).
        -- Falls back to primary-donor chip for items with no baked tags.
        local chip = HDG.DecorFormat:GateChips(v)
        if chip == "" then
            local kind = HDG.Constants.SOURCE_KIND_BY_DONOR[v.sourceType]
            chip = (kind and HDG.Format.SourceChip(kind.key)) or ""
        end
        local pieces = (chip ~= "") and { chip } or {}
        if v.sourceName and v.sourceName ~= "" then
            if v.sourceNpcID then
                -- Vendor name as a custom hyperlink: click routes to this vendor in
                -- Acquire (wired in DecorController:_wireVendorHyperlink). Same
                -- pattern as the acq detail panel's hdgrach: achievement link.
                pieces[#pieces + 1] = HDG.Theme:ColorCode("semantic.accent")
                    .. "|Hhdgrvendor:" .. v.sourceNpcID .. "|h" .. v.sourceName .. "|h|r"
            else
                pieces[#pieces + 1] = v.sourceName
            end
        end
        if v.sourceDetail and v.sourceDetail ~= "" and v.sourceDetail ~= v.sourceName then
            pieces[#pieces + 1] = "(" .. v.sourceDetail .. ")"
        end
        -- why + Map / + Way are greyed: sold by a vendor, none of them mapped yet
        if v.hasVendor and not v.vendor then
            pieces[#pieces + 1] = HDG.Theme:ColorCode("text.dim") .. "- "
                .. HDG.Locale:Get("VENDOR_LOC_UNKNOWN") .. "|r"
        end
        -- chip alone is fine when no name/detail
        return table.concat(pieces, "  ")
    end,
})

-- Combined Collected / placement status line.
-- Collection segment: DecorFormat:Collection (ownership + stored + placed).
-- Placement segment: row.placementLabel (baked at BuildRow). +XP chip when applicable.
Selectors:Register("decor.selectedItem.statusLabel", {
    reads = {"account.config.scheme", "session.resolvers.catalog.tick"},
    calls = {"decor.selectedItemID"},
    fn = function(state, ctx)
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        if not id then return "" end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row then return "" end
        local F      = HDG.DecorFormat
        local dimCC  = HDG.Theme:ColorCode("text.dim")
        local successCC = HDG.Theme:ColorCode("semantic.success")
        local textCC = HDG.Theme:ColorCode("text.primary")

        local statusSegment = F:Collection(row)
        -- Append +XP chip for not-yet-collected items with a first-acquisition bonus.
        if (not row.isOwned) and row.bonusXpLabel then
            statusSegment = statusSegment .. "  " .. dimCC .. "(|r" ..
                successCC .. row.bonusXpLabel .. "|r" .. dimCC .. ")|r"
        end

        -- Placement segment (baked label includes the budget icon).
        local placementSegment = ""
        if row.placementLabel ~= "" then
            placementSegment = "   " .. textCC .. row.placementLabel .. "|r"
        end

        return statusSegment .. placementSegment
    end,
})

-- Category breadcrumb + size tag + optional trophy marker.
-- Reads row.categoryLabel + row.sizeLabel (baked at BuildRow).
Selectors:Register("decor.selectedItem.categoryLabel", {
    reads = {"account.config.scheme", "session.resolvers.catalog.tick"},
    calls = {"decor.selectedItemID"},
    fn = function(state, ctx)
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        if not id then return "" end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row or not row.categoryLabel or row.categoryLabel == "" then return "" end
        local accentCC  = HDG.Theme:ColorCode("semantic.accent")
        local textCC    = HDG.Theme:ColorCode("text.primary")
        local dimCC     = HDG.Theme:ColorCode("text.dim")
        local warningCC = HDG.Theme:ColorCode("semantic.warning")

        local line = accentCC .. row.categoryLabel .. "|r"
        if row.sizeLabel and row.sizeLabel ~= "" then
            line = line .. dimCC .. "  -  |r" .. textCC .. row.sizeLabel .. "|r"
        end
        if row.isUniqueTrophy then
            line = line .. "  " .. warningCC .. "Trophy|r"
        end
        return line
    end,
})

-- Tags line (Styles + Factions, baked as row.tagsLabel at BuildRow).
Selectors:Register("decor.selectedItem.tagsLabel", {
    reads = {"account.config.scheme", "session.resolvers.catalog.tick"},
    calls = {"decor.selectedItemID"},
    fn = function(state, ctx)
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        if not id then return "" end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row or not row.tagsLabel or row.tagsLabel == "" then return "" end
        local accentCC = HDG.Theme:ColorCode("semantic.accent")
        local knownCC  = HDG.Theme:GetTextStateColorToken("known_self")
        return accentCC .. "Tags:|r " .. knownCC .. row.tagsLabel .. "|r"
    end,
})

-- Expansion label: baked at BuildRow as row.expansionLabel (Palette is scheme-invariant).
Selectors:Register("decor.selectedItem.headerExpansion", {
    reads = {"session.resolvers.catalog.tick"},
    calls = {"decor.selectedItemID"},
    fn = function(state, ctx)
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        if not id then return "" end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        return (row and row.expansionLabel) or ""
    end,
})

-- Destroyable flag for the destroy-button widget (visibility / enabled).
-- True when the catalog row reports at least one destroyable instance.
Selectors:Register("decor.selectedItem.destroyable", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        return v and (v.destroyableInstanceCount or 0) > 0 or false
    end,
})

-- Destroy button: only show when Stored filter is active AND a destroyable item
-- is selected. Destructive action gated behind the intentional Stored toggle.
Selectors:Register("decor.showDestroyButton", {
    calls = {"decor.onlyStored", "decor.selectedItem.destroyable"},
    fn = function(state, ctx)
        local onlyStored  = Selectors:Call("decor.onlyStored", state, ctx)
        local destroyable = Selectors:Call("decor.selectedItem.destroyable", state, ctx)
        return onlyStored == true and destroyable == true
    end,
})

-- Visibility predicates: collapse profession + tags widgets when their selector returns "".
Selectors:Register("decor.selectedItem.isCrafted", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        return v and v.sourceType == 6 or false   -- 6 = CRAFTED
    end,
})
Selectors:Register("decor.selectedItem.hasTags", {
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        if not v or not v.dataTagsByID then return false end
        for tagID in pairs(v.dataTagsByID) do
            local cat = HDG.TagData.GetCategory(tagID)
            if cat == "Styles" or cat == "Factions" then return true end
        end
        return false
    end,
})

-- (Dye-variant swatch selectors removed with the in-card variant strip:
-- decor.selectedItem.variants / selectedVariantIdentifier / variantSlot.* /
-- hasVariants. The owned-dyed-variant ROWS + dye-dots still use row.dyedVariants
-- via decor.items + decor.isDyed -- that system is untouched.)

-- Category line: row.categoryName + row.subcategoryName, pre-resolved at sweep. per ADR-003.
Selectors:Register("decor.selectedItem.category", {
    calls = {"decor.selectedItem"},
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        if not (v and v.decorID) then return "" end
        local row = HDG.HousingCatalogObserver.byDecorID[v.decorID]
        if not row then return "" end
        local cat = row.categoryName
        local sub = row.subcategoryName
        if cat and sub then return cat .. "  >  " .. sub end
        return cat or sub or ""
    end,
})

-- User-note text for the note editbox. Empty string when no note set.
Selectors:Register("decor.selectedItem.note", {
    calls = {"decor.selectedItemID"},
    reads = {"account.userNotes"},
    fn = function(state, ctx)
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        if not id then return "" end
        local notes = state.account.userNotes
        local n = notes[id]
        return (n and n.text) or ""
    end,
})

-- (decor.previewInfo removed: model preview dispatcher resolves selectedItemID
--  -> previewInfo at the UI seam where the Blizzard catalog API call belongs.)

-- (decor.countLabel retired: no widget bound after decorPanel.count -> decor.headerLabel.)

-- Rich header: "1557/1958 (79%)" + "  *  M shown" when any filter is active.
Selectors:Register("decor.headerDenominator", {
    memoized = true,
    calls = {"decor.allItems"},
    fn = function(state, ctx)
        local all = Selectors:Call("decor.allItems", state, ctx)
        return #all
    end,
})

-- What the list holds, for the count line: { shown, collected, dyedRows, full,
-- partial, fitOf }. Read off decor.matchingRows, where a decor's rows sit together
-- (its base row, then its dyed stacks), so a decor is counted where its itemID
-- first appears -- no set of the decor seen. (That set was 74 KB on every update
-- of the count line, perf profile 2026-11-22.) The Destroy list re-sorts the same
-- rows, so the figures are its own too.
--   shown / collected   unique base decor: owned dyed-variant rows would inflate
--                       the ratio every time something is dyed (VDS says 143
--                       dyeable, the row count said 157)
--   dyedRows            the dyed-stack rows, for the "+ N dyed" tail
--   full / partial      Best first: decor fitting every scored filter, and some
Selectors:Register("decor.listSummary", {
    memoized = true,
    calls = {"decor.matchingRows", "decor.isCollected"},
    fn = function(state, ctx)
        local isColl = Selectors:Call("decor.isCollected", state, ctx)
        local sum = { shown = 0, collected = 0, dyedRows = 0, full = 0, partial = 0, fitOf = 0 }
        local last
        for _, row in ipairs(Selectors:Call("decor.matchingRows", state, ctx)) do
            if row.isVariantRow then sum.dyedRows = sum.dyedRows + 1 end
            local id = row.itemID
            if id and id ~= last then   -- exception(nullable): a Best first heading has no itemID
                last = id
                sum.shown = sum.shown + 1
                if isColl(id) then sum.collected = sum.collected + 1 end
                if row.fit then   -- exception(nullable): fit is nil outside Best first
                    sum.fitOf = row.fitOf
                    if row.fit == row.fitOf then sum.full = sum.full + 1 else sum.partial = sum.partial + 1 end
                end
            end
        end
        return sum
    end,
})

Selectors:Register("decor.headerLabel", {
    calls = {"decor.headerDenominator", "decor.ownedCount", "decor.filterActive", "decor.listSummary"},
    fn = function(state, ctx)
        local denom = Selectors:Call("decor.headerDenominator", state, ctx)
        if denom == 0 then return "" end
        -- No filter: whole-collection ratio (e.g. "1605/1673 (95%)").
        if not Selectors:Call("decor.filterActive", state, ctx) then
            local owned = Selectors:Call("decor.ownedCount", state, ctx)
            return string.format("%d/%d (%d%%)", owned, denom, math.floor(owned / denom * 100))
        end
        local sum = Selectors:Call("decor.listSummary", state, ctx)
        -- Best first with decor that fall short: how many fit every scored filter
        -- and how many only some. (None short: the plain line says it.)
        if sum.partial > 0 then
            return HDG.Locale:Get("DECOR_COUNT_BEST"):format(sum.full, sum.fitOf, sum.partial)
        end
        -- Filtered: collected / shown WITHIN the current filters (e.g. "204/309
        -- (66%)"); the chips above the list name them.
        local pct = sum.shown > 0 and math.floor(sum.collected / sum.shown * 100) or 0
        local out = string.format("%d/%d (%d%%)", sum.collected, sum.shown, pct)
        if sum.dyedRows > 0 then
            out = out .. " + " .. sum.dyedRows .. " dyed"
        end
        return out
    end,
})

-- ============================================================================
-- Per-item flag selectors + aggregates
-- ============================================================================
-- Each returns a curried (itemID) -> bool. Closure holds the data lookup;
-- O(1) per item. Hot filter toggles NEVER invalidate these (per ADR-012).

-- isCollected: via Observer:IsOwned (same predicate as BuildRow/PatchCounts/HouseAggregator).
-- Re-fires on the catalog resolver signal (full sweep stamps the generation;
-- incremental PatchCounts invalidates the path signal-only).
Selectors:Register("decor.isCollected", {
    memoized = true,
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        return function(itemID)
            return HDG.HousingCatalogObserver:IsOwned(itemID)
        end
    end,
})

-- isStored: has destroyable stored copies. quantity (= totalNumStored) > 0 and not a unique
-- trophy. (Was destroyableInstanceCount > 0, but that aggregate is off-by-one -- it read 0 for
-- a lone stored copy and wrongly hid single-copy items from the Stored filter. The old gate
-- excluded trophies only as a side effect of their dic being 0; now it's explicit.)
Selectors:Register("decor.isStored", {
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local byItemID = HDG.HousingCatalogObserver.byItemID
        return function(itemID)
            local row = byItemID[itemID]
            -- Stored copies are destroyable (placed ones aren't); unique trophies never are.
            return row.quantity > 0 and not row.isUniqueTrophy
        end
    end,
})

-- destroyableCount: destroyable copies in storage. Used for row stamping + sort order.
-- Called for catalog rows only (the list walks byItemID), whose counts the observer fills.
Selectors:Register("decor.destroyableCount", {
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local byItemID = HDG.HousingCatalogObserver.byItemID
        return function(itemID)
            local row = byItemID[itemID]
            -- Undyed row count = the vid=0 variant's real numStored (Blizzard's
            -- GetEntryQuantity), plus remainingRedeemable which redemptions grant as the
            -- base variant -- NOT the aggregate destroyableInstanceCount.
            local undyed = row.undyedNumStored or row.quantity   -- exception(nullable): undyedNumStored nil for non-customizable decor -> all copies undyed
            return undyed + row.remainingRedeemable
        end
    end,
})

-- isFavorite: account.favorites membership.
Selectors:Register("decor.isFavorite", {
    reads = {"account.favorites"},
    fn = function(state, ctx)
        local favs = state.account.favorites
        return function(itemID) return favs[itemID] == true end
    end,
})

-- craftableState: 4-state recipe knowledge enum (HDG.Constants.RECIPE_STATE). A recipe
-- is any recipes.db entry (seed + capture); who knows it is recipes.knowledge.
Selectors:Register("decor.craftableState", {
    calls = {"recipes.db", "recipes.knowledge"},
    fn = function(state, ctx)
        local db        = Selectors:Call("recipes.db", state, ctx)
        local knowledge = Selectors:Call("recipes.knowledge", state, ctx)
        local mine, alts = knowledge.mine, knowledge.alts
        local S = HDG.Constants.RECIPE_STATE
        return function(itemID)
            if db[itemID] == nil then return S.NotARecipe end
            if mine[itemID] then return S.KnownByCharacter end
            if alts[itemID] then return S.KnownByAlt end
            return S.UnknownOnAccount
        end
    end,
})

-- ===== Filter state surface ===================================================
-- The filter strip's bindings, and the inputs decor.matchingRows composes.

-- "decor" or "pets": which list the tab shows (the Decor | Pets switch).
Selectors:Register("decor.mode", {
    reads = {"session.ui.decor.mode"},
    fn = function(state, ctx)
        return state.session.ui.decor.mode
    end,
})

-- How the list answers the ticks: "all" (a decor has to fit every filter) or
-- "best" (the closest fits first).
Selectors:Register("decor.match", {
    reads = {"session.ui.decor.match"},
    fn = function(state, ctx)
        return state.session.ui.decor.match
    end,
})

-- One boolean per switch position, for the buttons' `active` bindings.
for _, mode in ipairs({ "decor", "pets" }) do
    Selectors:Register("decor.isMode_" .. mode, {
        calls = {"decor.mode"},
        fn = function(state, ctx)
            return Selectors:Call("decor.mode", state, ctx) == mode
        end,
    })
end
for _, match in ipairs({ "all", "best" }) do
    Selectors:Register("decor.isMatch_" .. match, {
        calls = {"decor.match"},
        fn = function(state, ctx)
            return Selectors:Call("decor.match", state, ctx) == match
        end,
    })
end

-- The list's sort order (Constants.DECOR_SORTS).
Selectors:Register("decor.sort", {
    reads = {"session.ui.decor.sort"},
    fn = function(state, ctx)
        return state.session.ui.decor.sort
    end,
})

Selectors:Register("decor.sortMenuItems", {
    fn = function(state, ctx)
        local items = {}
        for i, sort in ipairs(HDG.Constants.DECOR_SORTS) do
            items[i] = { value = sort, text = HDG.Locale:Get("DECOR_SORT_" .. sort:upper()) }
        end
        return items
    end,
})

-- The filter menus' ticks: { ["group:value"] = true } (Core/HDGR_DecorFilters.lua).
Selectors:Register("decor.filterTicks", {
    reads = {"session.ui.decor.filters.ticks"},
    fn = function(state, ctx)
        return state.session.ui.decor.filters.ticks
    end,
})

-- The Decor Browser heading's Uncollected button: the Collection menu's tick.
Selectors:Register("decor.onlyUncollected", {
    calls = {"decor.filterTicks"},
    fn = function(state, ctx)
        return Selectors:Call("decor.filterTicks", state, ctx)[DF.Tick("status", "uncollected")] == true
    end,
})

Selectors:Register("decor.onlyStored", {
    reads = {"session.ui.decor.filters.onlyStored"},
    fn = function(state, ctx)
        local d = state.session.ui.decor
        return d.filters.onlyStored == true
    end,
})

-- (decor.onlyDyed / decor.onlyDyeable retired: Dyed and Dyeable are ticks of the
--  Collection menu.)

-- Curried per-item flag for dyed-or-dyeable filtering. Reads catalog row
-- data populated by ReconcileFull.
Selectors:Register("decor.isDyeable", {
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local byItemID = HDG.HousingCatalogObserver.byItemID
        return function(itemID)
            local row = byItemID[itemID]
            return row and row.canCustomize == true or false
        end
    end,
})
Selectors:Register("decor.isDyed", {
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local byItemID = HDG.HousingCatalogObserver.byItemID
        return function(itemID)
            local row = byItemID[itemID]
            -- row.dyedVariants is baked by the observer (_bakeVariantDyes) =
            -- owned variants (numStored>0) with an applied dye. Single source of
            -- truth, shared with the decor.matchingRows per-variant expansion.
            return (row and row.dyedVariants and #row.dyedVariants > 0) or false
        end
    end,
})

-- Curried per-item flag for the "New in <patch>" tick. newIds = the batch of
-- itemIDs that appeared in the live catalog under the current client build
-- (observer snapshot diff at _CommitSweep; the first-ever sweep seeds the
-- snapshot silently, so a fresh install has no batch).
Selectors:Register("decor.isNew", {
    reads = {"account.catalogVintage"},
    fn = function(state, ctx)
        local newIds = state.account.catalogVintage.newIds
        return function(itemID) return newIds[itemID] == true end
    end,
})

-- The Collection menu's flags: { [value] = fn(itemID) -> boolean }, one per value
-- of the `status` group (Constants.DECOR_FILTER_GROUPS).
Selectors:Register("decor.filterFlags", {
    reads = {"session.resolvers.catalog.tick"},
    calls = {"decor.isCollected", "decor.isFavorite", "decor.isDyed", "decor.isDyeable", "decor.isNew"},
    fn = function(state, ctx)
        local isCollected = Selectors:Call("decor.isCollected", state, ctx)
        local byItemID = HDG.HousingCatalogObserver.byItemID
        return {
            collected   = isCollected,
            uncollected = function(itemID) return not isCollected(itemID) end,
            favorites   = Selectors:Call("decor.isFavorite", state, ctx),
            -- Decor currently placed in a house (catalog live numPlaced > 0).
            placed      = function(itemID) return byItemID[itemID].numPlaced > 0 end,
            dyeable     = Selectors:Call("decor.isDyeable", state, ctx),
            dyed        = Selectors:Call("decor.isDyed", state, ctx),
            -- Eligible for first-acquisition House XP AND not yet owned.
            housexp     = function(itemID)
                if isCollected(itemID) then return false end
                return byItemID[itemID].firstAcquisitionBonus > 0
            end,
            -- A redeemable token is outstanding AND no copy has been claimed yet
            -- (nothing in storage, nothing placed) -- i.e. still waiting to redeem.
            redeemable  = function(itemID)
                local row = byItemID[itemID]
                return row.remainingRedeemable > 0 and row.quantity == 0 and row.numPlaced == 0
            end,
            new         = Selectors:Call("decor.isNew", state, ctx),
        }
    end,
})

-- What a catalog row does not carry, for DecorFilters (`known`): the collection
-- flags, and the recipe book -- shipped plus captured, so a decor whose recipe was
-- read off a profession window is crafted before HDG ships that recipe (owner
-- ruling 2026-10-31, as the old Crafted tag had it).
Selectors:Register("decor.filterKnown", {
    calls = {"decor.filterFlags", "recipes.db"},
    fn = function(state, ctx)
        return { flags   = Selectors:Call("decor.filterFlags", state, ctx),
                 recipes = Selectors:Call("recipes.db", state, ctx) }
    end,
})

-- The filters in force, compiled once per change of the ticks or of what the
-- player owns: { { id, hard, pass = fn(row) }, ... } (DecorFilters.Units).
Selectors:Register("decor.filterUnits", {
    memoized = true,
    calls = {"decor.filterTicks", "decor.filterKnown"},
    fn = function(state, ctx)
        return DF.Units(Selectors:Call("decor.filterTicks", state, ctx),
                        Selectors:Call("decor.filterKnown", state, ctx))
    end,
})

-- Anything narrowing the list? Drives the count line (whole collection, or
-- what the filters leave).
Selectors:Register("decor.filterActive", {
    calls = { "decor.filterTicks", "decor.onlyStored", "decor.filterQuery" },
    fn = function(state, ctx)
        if next(Selectors:Call("decor.filterTicks", state, ctx)) ~= nil then return true end
        if Selectors:Call("decor.onlyStored", state, ctx) == true then return true end
        return Selectors:Call("decor.filterQuery", state, ctx) ~= ""
    end,
})

-- ===== Menu contents ==========================================================

-- A group's values in menu order: the game's Size and Expansion tags and the
-- budget costs by number (the game's own order), names by name, everything else
-- most-used first.
local function _orderValues(group, values, totals)
    if group.order == "id" then
        table.sort(values, function(a, b) return tonumber(a) < tonumber(b) end)
    elseif group.order == "label" then
        local labels = {}
        for _, value in ipairs(values) do labels[value] = DF.ValueLabel(group.id, value) end
        table.sort(values, function(a, b)
            if labels[a] ~= labels[b] then return labels[a] < labels[b] end
            return a < b
        end)
    else
        table.sort(values, function(a, b)
            local ca, cb = totals[DF.Tick(group.id, a)], totals[DF.Tick(group.id, b)]
            if ca ~= cb then return ca > cb end
            return a < b
        end)
    end
end

-- What one menu lists: { [group id] = { value, ... } } for its groups. A `fixed`
-- group lists its own values; every other group the values some decor in the
-- catalog carries, found by one walk that reads this menu's groups alone. Run as
-- the menu opens: nothing keeps it.
local function _menuValues(menu, state, ctx)
    local valuesOf, walk = {}, false
    for _, gid in ipairs(menu.groups) do
        local fixed = DF.GroupByID[gid].fixed
        valuesOf[gid] = fixed or {}
        if not fixed then walk = true end
    end
    if not walk then return valuesOf end
    local totals, buf, plan = {}, {}, DF.MenuPlan(menu.id)
    -- No flags: what a menu lists does not depend on what the player owns.
    local known = { recipes = Selectors:Call("recipes.db", state, ctx) }
    for _, item in ipairs(Selectors:Call("decor.allItems", state, ctx)) do
        for i = 1, DF.RowTicks(item, known, plan, buf) do
            local tick = buf[i]
            totals[tick] = (totals[tick] or 0) + 1
        end
    end
    for tick in pairs(totals) do
        local gid, value = DF.Split(tick)
        if not DF.GroupByID[gid].fixed then
            local values = valuesOf[gid]
            values[#values + 1] = value
        end
    end
    for _, gid in ipairs(menu.groups) do
        local group = DF.GroupByID[gid]
        if not group.fixed then _orderValues(group, valuesOf[gid], totals) end
    end
    return valuesOf
end

-- The "New in <patch>" flag's build, or nil when the catalog diff holds no batch.
local function _newBuildLabel(state)
    local cv = state.account.catalogVintage
    if next(cv.newIds) == nil then return nil end
    return cv.newBuildLabel
end

-- What a value reads as. "New in 12.1.5" carries the live build of the batch.
local function _valueLabel(gid, value, newBuild)
    local label = DF.ValueLabel(gid, value)
    -- "?": the tick outlived its batch (a chip can still name it). Visible, not blank.
    if gid == "status" and value == "new" then return label:format(newBuild or "?") end   -- exception(nullable): no batch under this build
    return label
end

-- The rows that explain themselves on hover. Redeemable: the catalog counts the
-- decor as yours before you have ever placed one, which needs saying.
local function _rowTip(gid, value)
    if gid ~= "status" or value ~= "redeemable" then return nil end
    return { title = HDG.Locale:Get("TIP_REDEEMABLE_TAG_TITLE"), body = HDG.Locale:Get("TIP_REDEEMABLE_TAG_BODY") }
end

-- One tick row. `children`: the rows of the submenu it opens (the Type menu).
local function _tickRow(gid, value, newBuild, children)
    return {
        kind     = "checkbox",
        value    = DF.Tick(gid, value),
        text     = _valueLabel(gid, value, newBuild),
        tip      = _rowTip(gid, value),
        swatch   = gid == "color" and HDG.Constants.DECOR_FILTER_SWATCHES[value] or nil,   -- exception(nullable): only the Colour menu carries squares
        children = children,
    }
end

-- A group's tick rows appended to `items`. No batch -> no "New in" row.
local function _addGroupRows(items, gid, values, newBuild)
    for _, value in ipairs(values) do
        if not (gid == "status" and value == "new" and not newBuild) then
            items[#items + 1] = _tickRow(gid, value, newBuild)
        end
    end
end

-- The Type menu: each kind a tick row that opens its objects beside it, then the
-- objects no kind claims under "Other".
local function _addTypeRows(items, valuesOf)
    local tree, under, other = DF.TypeTree(), {}, {}
    for _, kind in ipairs(valuesOf.category) do under[kind] = {} end
    for _, object in ipairs(valuesOf.subject) do
        -- Other: no kind claims the object, or the kind that does is one no decor
        -- in this catalog carries (so it has no row to sit under).
        local list = under[tree.kindOf[object]] or other   -- exception(nullable): an object outside the listed kinds
        list[#list + 1] = _tickRow("subject", object)
    end
    for _, kind in ipairs(valuesOf.category) do
        local children = under[kind]
        items[#items + 1] = _tickRow("category", kind, nil, #children > 0 and children or nil)
    end
    if #other > 0 then
        items[#items + 1] = { kind = "submenu", text = HDG.Locale:Get("DECOR_FM_OTHER_KIND"), children = other }
    end
end

-- One menu's rows: Clear, then each group's ticks (under its own heading when the
-- menu holds more than one). The rows do not depend on the ticks: their counts
-- are read live from decor.filterCounts as the menu draws.
-- NOT memoized and bound to no widget: a menu button asks for its rows when it
-- opens (the dropdown's `rows`), so a menu nobody opened costs nothing -- bound,
-- all twenty were built when the tab opened and again on every catalog change
-- (+380 KB to open Decor, +250 KB per count change; offline harness, 2026-11-22).
-- Its value list is one walk of the catalog for this menu's groups (_menuValues).
for _, menu in ipairs(HDG.Constants.DECOR_FILTER_MENUS) do
    Selectors:Register("decor.filterMenu_" .. menu.id, {
        reads = {"account.catalogVintage", "session.resolvers.catalog.tick"},
        calls = {"decor.allItems", "recipes.db"},
        fn = function(state, ctx)
            local valuesOf = _menuValues(menu, state, ctx)
            local newBuild = _newBuildLabel(state)
            local items = {
                { kind = "action", text = HDG.Locale:Get("DECOR_FM_CLEAR"):format(HDG.Locale:Get(menu.label)),
                  action = "DECOR_CLEAR_FILTERS", payload = { menu = menu.id } },
                { kind = "divider" },
            }
            if menu.tree then
                _addTypeRows(items, valuesOf)
                return items
            end
            for _, gid in ipairs(menu.groups) do
                if #menu.groups > 1 then
                    items[#items + 1] = { kind = "title", text = DF.GroupLabel(gid) }
                end
                _addGroupRows(items, gid, valuesOf[gid], newBuild)
            end
            return items
        end,
    })
end

-- How many values of each menu are ticked: { [menu id] = n }, for the closed
-- buttons. One walk of the ticks serves all twenty.
Selectors:Register("decor.filterMenuCounts", {
    memoized = true,
    calls = {"decor.filterTicks"},
    fn = function(state, ctx)
        local counts = {}
        for tick in pairs(Selectors:Call("decor.filterTicks", state, ctx)) do
            local id = DF.MenuOfGroup[(DF.Split(tick))].id
            counts[id] = (counts[id] or 0) + 1
        end
        return counts
    end,
})
for _, menu in ipairs(HDG.Constants.DECOR_FILTER_MENUS) do
    Selectors:Register("decor.filterMenuCount_" .. menu.id, {
        calls = {"decor.filterMenuCounts"},
        fn = function(state, ctx)
            return Selectors:Call("decor.filterMenuCounts", state, ctx)[menu.id] or 0   -- exception(nullable): a menu with no tick
        end,
    })
end

-- One menu's counts, for its rows' right column: [tick] = the decor ticking it
-- would list.
--   Every filter: the decor that fit every OTHER filter. Where any one ticked
--                 value passes (Size, Source), a menu's own ticks do not shrink
--                 its own counts. Where every ticked value has to hold (Colour,
--                 Collection), they do: a count is what adding the tick leaves.
--   Best first:   the decor the hard filters leave (the list scores the rest).
-- A decor missing no filter counts for its values in this menu; a decor missing
-- exactly one filter counts only when that is an any-of filter of this menu, for
-- that filter's values. One selector a menu, read live as its rows draw, so only an
-- OPEN menu is ever counted -- and it walks its own groups alone (the count of
-- every menu at once was 22 ms a tick in game, perf profile 2026-11-22).
local function _menuCounts(menuID, state, ctx)
    local passesBase = Selectors:Call("decor.passesBase",  state, ctx)
    local known      = Selectors:Call("decor.filterKnown", state, ctx)
    local units      = Selectors:Call("decor.filterUnits", state, ctx)
    if Selectors:Call("decor.match", state, ctx) == "best" then units = (_splitUnits(units)) end
    local plan, counts, buf = DF.MenuPlan(menuID), {}, {}
    for _, item in ipairs(Selectors:Call("decor.allItems", state, ctx)) do
        if passesBase(item) then
            local misses, missed = _misses(item, units)
            if misses == 0 or (misses == 1 and missed.anyOf and plan.units[missed.id]) then
                local only = missed and missed.id   -- exception(nullable): no miss, every value counts
                for i = 1, DF.RowTicks(item, known, plan, buf) do
                    local tick = buf[i]
                    if not only or DF.UnitOfTick(tick) == only then
                        counts[tick] = (counts[tick] or 0) + 1
                    end
                end
            end
        end
    end
    return counts
end
for _, menu in ipairs(HDG.Constants.DECOR_FILTER_MENUS) do
    Selectors:Register("decor.filterCounts_" .. menu.id, {
        memoized = true,
        calls = {"decor.allItems", "decor.passesBase", "decor.filterUnits", "decor.filterKnown", "decor.match"},
        fn = function(state, ctx) return _menuCounts(menu.id, state, ctx) end,
    })
end

-- ===== Chips: the ticks in force, above the list ==============================

-- A group's ticked values in chip order: its fixed order where it has one, else
-- by what the chip reads.
local function _chipValues(group, values, newBuild)
    if group.fixed then
        local out = {}
        for _, value in ipairs(group.fixed) do
            if values[value] then out[#out + 1] = value end
        end
        return out
    end
    local out, labels = {}, {}
    for value in pairs(values) do
        out[#out + 1] = value
        labels[value] = _valueLabel(group.id, value, newBuild)
    end
    table.sort(out, function(a, b)
        if labels[a] ~= labels[b] then return labels[a] < labels[b] end
        return a < b
    end)
    return out
end

-- One chip per tick, in menu order: { tick, label }; a click removes it. Then
-- the Clear all chip: { clearAll = true, label }. Built from the ticks alone -- not from the menus' value lists, which would then be
-- recounted on every catalog change for a row of chips.
Selectors:Register("decor.filterChips", {
    memoized = true,
    reads = {"account.catalogVintage"},
    calls = {"decor.filterTicks"},
    fn = function(state, ctx)
        local byGroup = {}
        for tick in pairs(Selectors:Call("decor.filterTicks", state, ctx)) do
            local gid, value = DF.Split(tick)
            local values = byGroup[gid]
            if not values then
                values = {}
                byGroup[gid] = values
            end
            values[value] = true
        end
        local newBuild = _newBuildLabel(state)
        local chips = {}
        for _, group in ipairs(HDG.Constants.DECOR_FILTER_GROUPS) do
            local values = byGroup[group.id]
            if values then   -- exception(nullable): a group with no tick
                for _, value in ipairs(_chipValues(group, values, newBuild)) do
                    chips[#chips + 1] = {
                        tick  = DF.Tick(group.id, value),
                        label = HDG.Locale:Get("DECOR_CHIP_FMT"):format(DF.GroupLabel(group.id), _valueLabel(group.id, value, newBuild)),
                    }
                end
            end
        end
        -- Clear all closes the strip, beside the filters it clears (owner
        -- 2026-11-22): the strip's own button is a row away from the chips.
        if #chips > 0 then
            chips[#chips + 1] = { clearAll = true, label = HDG.Locale:Get("DECOR_CLEAR_ALL") }
        end
        return chips
    end,
})

-- Chips show in decor mode once a menu holds a tick.
Selectors:Register("decor.hasFilterChips", {
    calls = {"decor.filterTicks", "decor.mode"},
    fn = function(state, ctx)
        return Selectors:Call("decor.mode", state, ctx) == "decor"
           and next(Selectors:Call("decor.filterTicks", state, ctx)) ~= nil
    end,
})

-- The view's rows: filter strip, chips, browser. The chip row takes the chips'
-- real wrapped height (published to chipsHeight by the strip, as the Recipes
-- run strip does) out of the browser's, so the window keeps its size and only
-- the list gives way -- the preview column spans both rows. No chips: a
-- zero-height row, which the layout gives no gap. The row grows with the chips
-- (owner's lab: "leave it"), down to a browser of BROWSER_MIN.
local CHIPS_ONE_LINE = 22
local CHIPS_PAD      = 6      -- the chips panel's own padding around the strip
local BROWSER_MIN    = 220    -- what the browser keeps however many chips there are (some 16 lines of them)
Selectors:Register("decor.gridRows", {
    reads = {"session.ui.decor.chipsHeight"},
    calls = {"decor.hasFilterChips"},
    fn = function(state, ctx)
        local strip, body = HDG.Constants.DECOR_FILTER_BAR_HEIGHT, HDG.Constants.DECOR_BODY_HEIGHT
        if not Selectors:Call("decor.hasFilterChips", state, ctx) then return { strip, 0, body } end
        local gap = HDG.Layout._resolveSpacing(HDG.LayoutConfig.window.gap)
        local h = state.session.ui.decor.chipsHeight
        if h <= 0 then h = CHIPS_ONE_LINE end   -- not measured yet: one line, so nothing clips
        h = math.min(h + CHIPS_PAD, body - gap - BROWSER_MIN)
        return { strip, h, body - h - gap }
    end,
})

-- ===== Best first: how the selected decor fits =================================

Selectors:Register("decor.selectedItem.hasFitNote", {
    calls = {"decor.selectedItem.fitNote"},
    fn = function(state, ctx)
        return Selectors:Call("decor.selectedItem.fitNote", state, ctx) ~= ""
    end,
})

-- "Fits 3 of 4: misses Colour" under the preview for a decor Best first lists
-- though it falls short; "" for one that fits everything, and in Every filter.
Selectors:Register("decor.selectedItem.fitNote", {
    reads = {"session.resolvers.catalog.tick"},
    calls = {"decor.selectedItemID", "decor.filterUnits", "decor.match"},
    fn = function(state, ctx)
        if Selectors:Call("decor.match", state, ctx) ~= "best" then return "" end
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        local row = id and HDG.HousingCatalogObserver:GetRow(id)
        if not row then return "" end   -- exception(nullable): nothing selected, or the catalog is cold
        local _, soft = _splitUnits(Selectors:Call("decor.filterUnits", state, ctx))
        if #soft == 0 then return "" end
        local missed = {}
        for _, unit in ipairs(soft) do
            if not unit.pass(row) then missed[#missed + 1] = DF.UnitLabel(unit) end
        end
        if #missed == 0 then return "" end
        return HDG.Locale:Get("DECOR_FIT_SOME"):format(#soft - #missed, #soft, table.concat(missed, ", "))
    end,
})

-- ===== Shu'halo fortunes tracker (DecorWidgets special) ======================
-- Renders only when the selected item is the registered "shuhalo_fortunes" special
-- (DecorWidgets gate). Ownership is impure (GetItemCount) so it goes through the
-- BagObserver facade keyed by session.resolvers.bag.tick -- the selectors stay pure.
local FORTUNE_KEY = "shuhalo_fortunes"

-- The registered entry IFF the selected item is the fortunes special, else nil.
Selectors:Register("decor.fortune.entry", {
    calls = {"decor.selectedItemID"},
    fn = function(state, ctx)
        local id = Selectors:Call("decor.selectedItemID", state, ctx)
        if not id then return nil end
        if HDG.DecorWidgets:KeyFor(id) ~= FORTUNE_KEY then return nil end
        return HDG.DecorWidgets:Get(FORTUNE_KEY)
    end,
})

-- Block visibility: every fortune widget gates on this so the block collapses
-- for non-special items.
Selectors:Register("decor.fortune.visible", {
    calls = {"decor.fortune.entry"},
    fn = function(state, ctx)
        return Selectors:Call("decor.fortune.entry", state, ctx) ~= nil
    end,
})

-- "Sargle's Fortunes  X/13  (full set = 999g, else gold cap)" header. Live count
-- via BagObserver; the price hook is folded in (the vendor/zone is already on the
-- source line) to keep the block to two lines in the tight detail pane.
Selectors:Register("decor.fortune.header", {
    calls = {"decor.fortune.entry"},
    reads = {"session.resolvers.bag.tick"},
    fn = function(state, ctx)
        local e = Selectors:Call("decor.fortune.entry", state, ctx)
        if not e then return "" end
        local have = 0
        for _, iid in ipairs(e.items) do
            if HDG.BagObserver:GetTotal(iid) > 0 then have = have + 1 end
        end
        return string.format("%s  %d/%d   (%s)", e.title, have, #e.items, e.note)
    end,
})

-- Numbered cells as a single colored string: green (owned) / dim (missing).
-- Cell N == fortune #N (verified itemID-ascending == in-name #N).
Selectors:Register("decor.fortune.cells", {
    calls = {"decor.fortune.entry"},
    reads = {"session.resolvers.bag.tick"},
    fn = function(state, ctx)
        local e = Selectors:Call("decor.fortune.entry", state, ctx)
        if not e then return "" end
        local ownedCC = HDG.Theme:ColorCode("semantic.success")
        local dimCC   = HDG.Theme:ColorCode("text.dim")
        local pieces = {}
        for i, iid in ipairs(e.items) do
            local cc = (HDG.BagObserver:GetTotal(iid) > 0) and ownedCC or dimCC
            pieces[i] = cc .. i .. "|r"
        end
        return table.concat(pieces, "   ")
    end,
})

-- ===== Aggregates ===========================================================
-- "Owned: N/T" sidebar counter. Memoized; re-runs only on catalog-side mutation.
Selectors:Register("decor.ownedCount", {
    reads    = {"account.collection.ownedDecorIDs"},
    memoized = true,
    fn = function(state, ctx)
        local col   = state.account.collection
        local owned = col.ownedDecorIDs
        local n = 0
        for _ in pairs(owned) do n = n + 1 end
        return n
    end,
})

-- "N stored" sidebar counter. Memoized; re-runs only on catalog sweep.
Selectors:Register("decor.storedCount", {
    reads    = {"session.resolvers.catalog.tick"},
    memoized = true,
    fn = function(state, ctx)
        if not HDG.HousingCatalogObserver:IsReady() then return 0 end
        local n = 0
        for _, row in pairs(HDG.HousingCatalogObserver.byDecorID) do
            if (row.quantity or 0) > 0 then n = n + 1 end  -- exception(boundary): catalog struct field sparse
        end
        return n
    end,
})


