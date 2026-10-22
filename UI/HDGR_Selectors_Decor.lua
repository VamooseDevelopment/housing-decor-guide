-- HDG.Selectors -- Decor tab
-- ============================================================================
-- decor.* selectors: catalog, filter chain, selection, variants, aggregates.
-- Helpers stay file-local.

HDG = HDG or {}
local Selectors = HDG.Selectors

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

-- (decor.activeProfessions retired -- profession filtering lives in the tag-row
--  system under topFilter='crafted'; state slot + chips had no consumers.)

-- Shown items: allItems through every active filter (AND-composed).
-- Filter axes: search query, top-filter bucket, active tag, onlyUncollected, onlyStored.
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
-- Per-item work split into three pure helpers; `f` bundles resolved predicates
-- + filter scalars so each helper takes one context arg.

-- Filter gate. f.* predicates are closure-returning selectors (always functions).
local function _decorRowPasses(item, f)
    local id = item.itemID
    if f.needle and not item.name:lower():find(f.needle, 1, true) then return false end
    if not f.matchTag(id) then return false end
    if f.onlyUncollected and f.isCollected(id) then return false end
    if f.onlyStored and not f.isStored(id) then return false end
    return true
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

local function _stampDecorRow(item, f)
    local id = item.itemID
    local row = _reuseRow(tostring(id) .. ":base", item)
    row.isFavorite       = f.isFavorite(id)
    row.craftableState   = f.craftableState(id)
    row.isCollected      = f.isCollected(id)
    row.inStoredMode     = f.onlyStored == true
    row.destroyableCount = f.destroyableCount(id)
    return row
end

-- A stored-mode row's sort count: the pinned one, else its live count (nothing
-- pinned yet, or a row that joined the list after the pin -- a new search).
local function _sortCount(row, pinned)
    local c = pinned and pinned[row.variantKey]   -- exception(nullable): no pin, or a row the pin never saw
    if c == nil then c = row.destroyableCount or 0 end   -- exception(boundary): sparse struct field
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
    row.isVariantRow       = true
    row.variantIdentifier  = dv.variantIdentifier
    row.dyeColorIDs        = dv.dyeColorIDs
    row.dyeColorsByChannel = dv.dyeColorsByChannel
    row.numStored          = dv.numStored
    row.destroyableCount   = dv.numStored
    row.entryID            = dv.entryID   -- per-variant destroy identity (else destroy hits the base stack)
    return row
end

-- Append base row then one row per owned dyed variant. Under "Dyed" tag the
-- undyed base is suppressed. variantKey (itemID:variant) is pool + selection
-- identity. Each variant carries its own dv.numStored (not the aggregate base count).
local function _emitDecorRows(out, item, stamped, activeTag)
    local dyedVariants = stamped.dyedVariants
    local hasDyed = dyedVariants and #dyedVariants > 0
    -- Base row = the undyed (vid=0) variant. In Stored view, suppress it when the item
    -- has dyed stacks but zero undyed copies (Blizzard's showQuantity > 0) -- else the
    -- undyed slot renders a phantom count that can't be destroyed.
    local hideEmptyUndyed = hasDyed and stamped.inStoredMode and (stamped.destroyableCount or 0) <= 0
    if not (activeTag == "Dyed" and hasDyed) and not hideEmptyUndyed then
        out[#out + 1] = stamped
    end
    if not hasDyed then return end
    for _, dv in ipairs(dyedVariants) do
        out[#out + 1] = _stampVariantRow(stamped, item, dv)
    end
end

-- The Decor list's rows in catalog order, before the Stored sort. Apart from
-- decor.items so the Destroy list's sort pin, which every tab switch clears,
-- never reaches the rows: outside Stored mode decor.items hands the list this
-- same table back and the list skips its refill (2,000 rows restamped and
-- refilled on every switch in and out of Decor, memory plan 2026-10-19 sec 6).
Selectors:Register("decor.matchingRows", {
    -- Memoized: decor.headerLabel calls through decor.items for "shown N", which
    -- would double-walk ~2000 items per dispatch without caching.
    memoized = true,
    calls = {
        "decor.allItems",
        "decor.filterQuery",
        "decor.onlyUncollected",
        "decor.onlyStored",
        "decor.matchesTag",
        "decor.isCollected",
        "decor.isStored",
        "decor.activeTag",
        "decor.destroyableCount",
        -- isFavorite + craftableState called directly in fn -> declared here per
        -- accurate-calls invariant. Their paths also reach via matchesTag, but
        -- direct calls must still be declared.
        "decor.isFavorite",
        "decor.craftableState",
        -- decor.selectedItemID retired: selection highlight owned by
        -- SelectionBehaviorMixin; clicks no longer invalidate the items list.
    },
    fn = function(state, ctx)
        local all = Selectors:Call("decor.allItems",   state, ctx)
        local q   = Selectors:Call("decor.filterQuery", state, ctx)
        -- Resolve all per-item predicates once (not per row) and bundle into `f`.
        local f = {
            onlyUncollected  = Selectors:Call("decor.onlyUncollected",  state, ctx),
            onlyStored       = Selectors:Call("decor.onlyStored",       state, ctx),
            matchTag         = Selectors:Call("decor.matchesTag",       state, ctx),
            isCollected      = Selectors:Call("decor.isCollected",      state, ctx),
            isStored         = Selectors:Call("decor.isStored",         state, ctx),
            activeTag        = Selectors:Call("decor.activeTag",        state, ctx),
            isFavorite       = Selectors:Call("decor.isFavorite",       state, ctx),
            craftableState   = Selectors:Call("decor.craftableState",   state, ctx),
            destroyableCount = Selectors:Call("decor.destroyableCount", state, ctx),
            needle           = q ~= "" and q:lower() or nil,
        }

        local out = {}
        for _, item in ipairs(all) do
            if _decorRowPasses(item, f) then
                _emitDecorRows(out, item, _stampDecorRow(item, f), f.activeTag)
            end
        end
        return out
    end,
})

-- The Decor list. Stored mode (the Destroy list) sorts most-cluttering first
-- (destroyable count desc, name asc), by the pinned counts once the player has
-- destroyed from it -- into a copy, because decor.matchingRows' table is memoized.
Selectors:Register("decor.items", {
    memoized = true,
    calls = { "decor.matchingRows", "decor.onlyStored", "decor.pinnedSortCounts" },
    fn = function(state, ctx)
        local rows = Selectors:Call("decor.matchingRows", state, ctx)
        if not Selectors:Call("decor.onlyStored", state, ctx) then return rows end
        local pinned = Selectors:Call("decor.pinnedSortCounts", state, ctx)
        local out = {}
        for i, row in ipairs(rows) do out[i] = row end
        table.sort(out, function(a, b)
            local da, db = _sortCount(a, pinned), _sortCount(b, pinned)
            if da ~= db then return da > db end
            return (a.name or "") < (b.name or "")
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
            return row.entryID, row.undyedNumStored or row.quantity or 0  -- exception(nullable): undyedNumStored nil for non-customizable decor -> all copies undyed
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

-- The vendor + Map / + Way target: the first vendor with a known location, one your
-- faction can shop at first (yours or neutral), else any with a location (owner
-- 2026-10-15). vendors[1] alone left a mappable second vendor unreachable. nil when
-- no vendor has a location -- the buttons grey and the source line says why.
local function _mapVendor(vendors, side)
    local fallback
    for _, v in ipairs(vendors) do
        if v.canWaypoint then
            if v.side == side or v.side == "N" then return v end
            fallback = fallback or v
        end
    end
    return fallback
end

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
        local mapVendor   = row.vendors and _mapVendor(row.vendors, state.session.identity.factionGroup)

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
            numStored     = row.quantity or 0,  -- exception(boundary): catalog struct field sparse
            categoryName             = row.categoryName,
            subcategoryName          = row.subcategoryName,
            isUniqueTrophy           = row.isUniqueTrophy or false,
            isAllowedIndoors         = row.isAllowedIndoors,
            isAllowedOutdoors        = row.isAllowedOutdoors,
            placementCost            = row.placementCost or 0,  -- exception(boundary): catalog struct field sparse
            numPlaced                = row.numPlaced or 0,  -- exception(boundary): catalog struct field sparse
            destroyableInstanceCount = vDestroyable,
            firstAcquisitionBonus    = row.firstAcquisitionBonus or 0,  -- exception(boundary): catalog struct field sparse
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
-- session.resolvers.recipeSource.tick is the facade's declared read: without
-- it, a card opened before the first fill would never repaint with the answer.
Selectors:Register("decor.selectedItem.recipeSource", {
    reads = {"account.config.scheme", "session.resolvers.recipeSource.tick"},
    calls = {"decor.selectedItem"},
    fn = function(state, ctx)
        local v = Selectors:Call("decor.selectedItem", state, ctx)
        if not v or v.sourceType ~= 6 then return "" end   -- 6 = CRAFTED
        local sources = HDG.ProfessionScanner:GetRecipeSourceForItem(v.itemID)
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

Selectors:Register("decor.headerLabel", {
    calls = {"decor.headerDenominator", "decor.ownedCount", "decor.filterActive",
             "decor.items", "decor.isCollected", "decor.activeTag"},
    fn = function(state, ctx)
        local denom = Selectors:Call("decor.headerDenominator", state, ctx)
        if denom == 0 then return "" end
        -- No filter: whole-collection ratio (e.g. "1605/1673 (95%)").
        if not Selectors:Call("decor.filterActive", state, ctx) then
            local owned = Selectors:Call("decor.ownedCount", state, ctx)
            return string.format("%d/%d (%d%%)", owned, denom, math.floor(owned / denom * 100))
        end
        -- Filtered: collected / shown WITHIN the current filter, + the filter name
        -- (e.g. "204/309 (66%)  Quest"). Counts unique base decor -- owned
        -- dyed-variant rows would inflate the ratio every time something is
        -- dyed (VDS says 143 dyeable, the row count said 157). Variant rows
        -- surface as a "+ N dyed" tail instead.
        local items  = Selectors:Call("decor.items", state, ctx)
        local isColl = Selectors:Call("decor.isCollected", state, ctx)
        local shown, collected, dyedRows, seen = 0, 0, 0, {}
        for _, row in ipairs(items) do
            if row.isVariantRow then dyedRows = dyedRows + 1 end
            if not seen[row.itemID] then
                seen[row.itemID] = true
                shown = shown + 1
                if isColl(row.itemID) then collected = collected + 1 end
            end
        end
        local pct = shown > 0 and math.floor(collected / shown * 100) or 0
        local out = string.format("%d/%d (%d%%)", collected, shown, pct)
        local tag = Selectors:Call("decor.activeTag", state, ctx)
        if tag then
            -- Source-kind tags are stored as SOURCE_KINDS.key (e.g. "QUEST"); show the
            -- friendly label. Other tags (Favorites/sizes/styles) are already friendly.
            local kind = HDG.Constants.SOURCE_KIND_BY_KEY[tag]
            out = out .. "  " .. ((kind and kind.label) or tag)
        end
        if dyedRows > 0 then
            out = out .. " + " .. dyedRows .. " dyed"
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
            return (row and (row.quantity or 0) > 0 and not row.isUniqueTrophy) or false  -- exception(boundary): catalog struct field sparse
        end
    end,
})

-- destroyableCount: destroyable copies in storage. Used for row stamping + sort order.
Selectors:Register("decor.destroyableCount", {
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local byItemID = HDG.HousingCatalogObserver.byItemID
        return function(itemID)
            local row = byItemID[itemID]
            if not row then return 0 end
            -- Undyed row count = the vid=0 variant's real numStored (Blizzard's
            -- GetEntryQuantity), plus remainingRedeemable which redemptions grant as the
            -- base variant -- NOT the aggregate destroyableInstanceCount. undyedNumStored is
            -- nil for non-customizable decor (no variant list) -> quantity (all copies undyed).
            local undyed = row.undyedNumStored or row.quantity or 0
            return undyed + (row.remainingRedeemable or 0)
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

-- craftableState: 4-state recipe knowledge enum (HDG.Constants.RECIPE_STATE).
-- known_alt requires account.recipes[itemID].altKnown (populated by alt scanner).
Selectors:Register("decor.craftableState", {
    reads = {"account.recipes"},
    fn = function(state, ctx)
        local recipes = state.account.recipes
        local S = HDG.Constants.RECIPE_STATE
        return function(itemID)
            local r = recipes[itemID]
            if not r then return S.NotARecipe end
            if r.selfKnown then return S.KnownByCharacter end
            if r.altKnown  then return S.KnownByAlt       end
            return S.UnknownOnAccount
        end
    end,
})

-- ===== Filter state surface ===================================================
-- Used by chip `active` bindings and by decor.matchingRows as composed filter inputs.

Selectors:Register("decor.topFilter", {
    reads = {"session.ui.decor.filters.topFilter"},
    fn = function(state, ctx)
        local d = state.session.ui.decor
        return (d.filters and d.filters.topFilter) or "all"
    end,
})

-- Per-top-filter boolean selectors for chip `active` bindings. HDG.Constants.TOP_FILTERS is SSoT.
for _, entry in ipairs(HDG.Constants.TOP_FILTERS or {}) do
    local captured = entry.value
    Selectors:Register("decor.topFilter.active_" .. captured, {
        calls = {"decor.topFilter"},
        fn = function(state, ctx)
            return Selectors:Call("decor.topFilter", state, ctx) == captured
        end,
    })
end

-- ===== Tags-row dynamic slot selectors =======================================
-- One set per tags-row chip (Constants.TAG_SLOT_COUNT). Each slot:
--   decor.tagSlot.text_N    -- tag label or "" when slot empty
--   decor.tagSlot.active_N  -- true when this slot's tag is active
--   decor.tagSlot.visible_N -- true when slot has content
for slot = 1, HDG.Constants.TAG_SLOT_COUNT do
    local n = slot
    Selectors:Register("decor.tagSlot.text_" .. n, {
        calls = {"decor.tagsForFilter", "decor.topFilter"},
        fn = function(state, ctx)
            local tags = Selectors:Call("decor.tagsForFilter", state, ctx)
            local raw  = tags[n]
            if not raw then return "" end
            -- Source kinds arrive as SOURCE_KINDS.key (all caps); show the friendly
            -- label for DISPLAY only. activeTag + matchesTag still use the raw key.
            if Selectors:Call("decor.topFilter", state, ctx) == "sources" then
                local kind = HDG.Constants.SOURCE_KIND_BY_KEY[raw]
                return (kind and kind.label) or raw
            end
            return raw
        end,
    })
    Selectors:Register("decor.tagSlot.active_" .. n, {
        calls = {"decor.tagsForFilter", "decor.activeTag"},
        fn = function(state, ctx)
            local tags = Selectors:Call("decor.tagsForFilter", state, ctx)
            local mine = tags[n]
            local active = Selectors:Call("decor.activeTag", state, ctx)
            return mine ~= nil and active == mine
        end,
    })
    Selectors:Register("decor.tagSlot.visible_" .. n, {
        calls = {"decor.tagsForFilter"},
        fn = function(state, ctx)
            local tags = Selectors:Call("decor.tagsForFilter", state, ctx)
            return tags[n] ~= nil and true or false
        end,
    })
end

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

-- "Tags:" label visibility. Explicit boolean (callers expect false/true, not false/nil).
Selectors:Register("decor.hasTagsRow", {
    calls = {"decor.tagsForFilter"},
    fn = function(state, ctx)
        local tags = Selectors:Call("decor.tagsForFilter", state, ctx)
        return tags[1] ~= nil and true or false
    end,
})

Selectors:Register("decor.activeTag", {
    reads = {"session.ui.decor.filters.activeTag"},
    fn = function(state, ctx)
        local d = state.session.ui.decor
        return d.filters and d.filters.activeTag or nil
    end,
})

Selectors:Register("decor.onlyUncollected", {
    reads = {"session.ui.decor.filters.onlyUncollected"},
    fn = function(state, ctx)
        local d = state.session.ui.decor
        return (d.filters and d.filters.onlyUncollected) == true
    end,
})

Selectors:Register("decor.onlyStored", {
    reads = {"session.ui.decor.filters.onlyStored"},
    fn = function(state, ctx)
        local d = state.session.ui.decor
        return (d.filters and d.filters.onlyStored) == true
    end,
})

-- (decor.onlyDyed / decor.onlyDyeable retired: Dyed/Dyeable moved to sub-tags
--  under topFilter='all'; matchesTag reads isDyed/isDyeable directly.)

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

-- Curried per-item flag for the "New in <patch>" chip. newIds = the batch of
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

-- Any filter active? Drives the 'Clear filters' affordance.
-- decor.activeProfessions (retired) not checked here: legacy state with no UI effect.
Selectors:Register("decor.filterActive", {
    calls = {
        "decor.topFilter",
        "decor.activeTag",
        "decor.onlyUncollected",
        "decor.onlyStored",
        "decor.filterQuery",
    },
    fn = function(state, ctx)
        if Selectors:Call("decor.topFilter",       state, ctx) ~= "all"   then return true end
        if Selectors:Call("decor.activeTag",       state, ctx) ~= nil     then return true end
        if Selectors:Call("decor.onlyUncollected", state, ctx) == true    then return true end
        if Selectors:Call("decor.onlyStored",      state, ctx) == true    then return true end
        if (Selectors:Call("decor.filterQuery", state, ctx)) ~= "" then return true end
        return false
    end,
})

-- ===== Tags row content + bucket/tag matching =================================
-- decor.tagsForFilter -> ordered chip list for the current topFilter.
-- decor.matchesTag -> curried predicate composed into decor.matchingRows.

-- Placement-cost chips under the Size top filter. The budget atlas IS the
-- label ("cost" reads as gold; "weight" is room terminology) -- the same
-- glyph as the card corner badges. ONE format string builds AND parses the
-- chip, so the matcher cannot drift from the builder.
local COST_TAG_FMT = "|A:house-decor-budget-icon:12:12|a %d"
local function _costTagValue(tag)
    if type(tag) ~= "string" then return nil end
    return tonumber(tag:match("^|A:house%-decor%-budget%-icon:%d+:%d+|a (%d+)$"))
end
-- "New in <patch>" chip under 'all'. ONE format string builds AND parses
-- (same discipline as COST_TAG_FMT) -- the label half is the live build
-- version stamped on the batch ("12.0.5"), so the matcher keys on the prefix.
local NEW_TAG_FMT = "New in %s"
local function _isNewTag(tag)
    return type(tag) == "string" and tag:find("^New in ") ~= nil
end
Selectors:Register("decor.tagsForFilter", {
    -- pets.tick: the 'pets' arm reads PetObserver's family list behind its facade
    -- tick, same contract as any other resolver read.
    reads    = {"session.resolvers.catalog.tick", "account.catalogVintage",
                "session.resolvers.pets.tick"},
    calls    = {"decor.topFilter"},
    memoized = true,
    fn = function(state, ctx)
        local top = Selectors:Call("decor.topFilter", state, ctx)
        -- Curated set under 'all'. Dyed/Dyeable moved from Row 3 toggles to
        -- sub-tags (toggle row was crowded; composability with profession sub-tags
        -- under 'crafted' is a niche case and was dropped).
        -- "All Decor" dropped: redundant; top='all' with no activeTag = everything.
        -- per ADR-018: DECOR_FILTER_RESET on the 'All' chip is the canonical reset.
        -- Uncollected stays a Row 3 toggle so it composes with Crafted prof sub-tags.
        if top == "all" then
            -- Structural/status sub-tags. Rep/Quest/Ach dropped: they duplicated
            -- the Sources top-filter. "Placed" = decor currently placed in a house.
            local tags = { "Favorites", "Crafted", "House XP", "Dyed", "Dyeable", "Placed", "Redeemable" }
            -- "New in <patch>" leads when the vintage diff has a current batch.
            local cv = state.account.catalogVintage
            if next(cv.newIds) ~= nil then
                table.insert(tags, 1, NEW_TAG_FMT:format(cv.newBuildLabel))
            end
            return tags
        end
        if top == "crafted" then
            local profs = HDG.Constants.DECOR_PROFESSIONS or {}
            local out = {}
            for i, p in ipairs(profs) do out[i] = p end
            return out
        end
        -- 'pets': the battle-pet families, from PetObserver's per-rebuild snapshot.
        -- Read through the observer rather than _G.BATTLE_PET_NAME_* directly --
        -- a selector may not touch FrameXML globals (invariant 1). The same
        -- activeTag the decor browser uses then narrows the pet list by family,
        -- so the tags row is reused rather than duplicated.
        if top == "pets" then
            return HDG.PetObserver:GetFamilies()
        end
        -- 'sources': derive distinct kind keys from catalog sourceTags.
        if top == "sources" then
            local byDecorID = HDG.HousingCatalogObserver.byDecorID
            local seen = {}
            for _, row in pairs(byDecorID) do
                local st = row.sourceTags
                if type(st) == "table" then
                    for _, entry in ipairs(st) do
                        if entry.kind then seen[entry.kind] = true end
                    end
                end
            end
            local out = {}
            for kind in pairs(seen) do out[#out + 1] = kind end
            table.sort(out)
            return out
        end
        -- sizes/factions/styles/expansions/other: derive labels from live catalog tagIDs.
        local bucket = ({
            sizes      = "Sizes",
            factions   = "Factions",
            styles     = "Styles",
            expansions = "Expansions",
            other      = "Other",
        })[top]
        if not bucket then return {} end
        local TagData = HDG.TagData
        local byDecorID = HDG.HousingCatalogObserver.byDecorID
        local seen = {}
        for _, row in pairs(byDecorID) do
            local ids = row.dataTagsByID
            if type(ids) == "table" then
                for tagID in pairs(ids) do
                    if TagData.GetCategory(tagID) == bucket then
                        local label = TagData.GetShortLabel(tagID)  -- shortens expansions; identity for others
                        if label then seen[label] = true end
                    end
                end
            end
        end
        local out = {}
        for label in pairs(seen) do out[#out + 1] = label end
        if top == "expansions" then
            -- Canonical release order (EXPANSION_DATA via Expansion.GetIndex), not
            -- alphabetical. Short labels (TBC/WotLK/...) resolve through the alias map.
            table.sort(out, function(a, b)
                local ia = HDG.Expansion.GetIndex(a) or math.huge
                local ib = HDG.Expansion.GetIndex(b) or math.huge
                if ia ~= ib then return ia < ib end
                return a < b
            end)
        else
            table.sort(out)
        end
        if top == "sizes" then
            -- Placement-cost chips after the size tags: distinct LIVE catalog
            -- values (1/2/3/5 today; a future tier appears by itself).
            local costs = {}
            for _, row in pairs(byDecorID) do
                local c = row.placementCost
                if c and c > 0 then costs[c] = true end
            end
            local sorted = {}
            for c in pairs(costs) do sorted[#sorted + 1] = c end
            table.sort(sorted)
            for _, c in ipairs(sorted) do out[#out + 1] = COST_TAG_FMT:format(c) end
        end
        return out
    end,
})

-- Pass-through placeholder for future bucket-level filters. No reads/calls
-- since the function is constant. Re-add to decor.matchingRows.calls if a bucket needs it.
Selectors:Register("decor.matchesTopFilter", {
    fn = function(state, ctx)
        return function() return true end
    end,
})

-- Curried (itemID) -> bool for "matches the active tag at the current top filter".
-- nil or "All Decor" activeTag matches everything.
Selectors:Register("decor.matchesTag", {
    reads = {"account.recipes", "account.favorites", "session.resolvers.catalog.tick"},
    calls = {"decor.topFilter", "decor.activeTag",
             "decor.isFavorite", "decor.isCollected",
             "decor.isDyed", "decor.isDyeable", "decor.isNew"},
    fn = function(state, ctx)
        local top = Selectors:Call("decor.topFilter", state, ctx)
        local tag = Selectors:Call("decor.activeTag",  state, ctx)
        -- Crafted is source-restricting: even with no profession sub-tag it must narrow
        -- to crafted decor (handled below), so it skips this pass-all early-out.
        if (tag == nil or tag == "All Decor") and top ~= "crafted" then
            return function() return true end
        end

        -- ===== Sub-tags under 'all' =====
        if top == "all" then
            if tag == "Favorites" then
                local isFav = Selectors:Call("decor.isFavorite", state, ctx)
                return function(itemID) return isFav and isFav(itemID) or false end
            end
            if tag == "Crafted" then
                local recipes = state.account.recipes
                return function(itemID) return recipes[itemID] ~= nil end
            end
            if tag == "House XP" then
                -- Items eligible for first-acquisition House XP AND not yet owned.
                local byItemID = HDG.HousingCatalogObserver.byItemID
                local isColl   = Selectors:Call("decor.isCollected", state, ctx)
                return function(itemID)
                    if isColl and isColl(itemID) then return false end
                    local row = byItemID[itemID]
                    return row and (row.firstAcquisitionBonus or 0) > 0 or false  -- exception(boundary): catalog struct field sparse
                end
            end
            if tag == "Dyed" then
                local isDyed = Selectors:Call("decor.isDyed", state, ctx)
                return function(itemID) return isDyed and isDyed(itemID) or false end
            end
            if tag == "Dyeable" then
                local isDyeable = Selectors:Call("decor.isDyeable", state, ctx)
                return function(itemID) return isDyeable and isDyeable(itemID) or false end
            end
            if _isNewTag(tag) then
                return Selectors:Call("decor.isNew", state, ctx)
            end
            if tag == "Placed" then
                -- Decor currently placed in a house (catalog live numPlaced > 0).
                local byItemID = HDG.HousingCatalogObserver.byItemID
                return function(itemID)
                    local row = byItemID[itemID]
                    return row and (row.numPlaced or 0) > 0 or false  -- exception(boundary): catalog struct field sparse
                end
            end
            if tag == "Redeemable" then
                -- A redeemable token is outstanding AND no copy has been claimed yet
                -- (nothing in storage, nothing placed) -- i.e. still waiting to redeem.
                local byItemID = HDG.HousingCatalogObserver.byItemID
                return function(itemID)
                    local row = byItemID[itemID]
                    if not row then return false end  -- exception(boundary): catalog struct field sparse
                    return (row.remainingRedeemable or 0) > 0
                       and (row.quantity or 0)  == 0
                       and (row.numPlaced or 0) == 0
                end
            end
            -- Unknown sub-tag under 'all' -> no matches.
            return function() return false end
        end

        -- ===== Crafted: items whose canonical source IS the recipe (sourceType==6) =====
        -- row.sourceType is baked by _bakeSourceTypes (priority Vendor>Quest>Ach>Crafted),
        -- so 6 = recipe-backed with no higher source -- the row's craft star. Matches the
        -- curated recipe DB, NOT the player's known recipes. No profession sub-tag selected
        -- -> all crafted; else narrow to that recipe's profession.
        if top == "crafted" then
            local byItemID = HDG.HousingCatalogObserver.byItemID
            if tag == nil or tag == "All Decor" then
                return function(itemID)
                    local row = byItemID[itemID]
                    return row ~= nil and row.sourceType == 6
                end
            end
            return function(itemID)
                local row = byItemID[itemID]
                return row ~= nil and row.sourceType == 6
                   and row.recipe and row.recipe.profession == tag
            end
        end

        -- ===== Source-kind chips under 'sources' =====
        if top == "sources" then
            local byItemID = HDG.HousingCatalogObserver.byItemID
            return function(itemID)
                local row = byItemID[itemID]
                if not (row and row.sourceTags) then return false end
                for _, entry in ipairs(row.sourceTags) do
                    if entry.kind == tag then return true end
                end
                return false
            end
        end

        -- ===== Tag-bucket categories =====
        local bucket = ({
            sizes      = "Sizes",
            factions   = "Factions",
            styles     = "Styles",
            expansions = "Expansions",
            other      = "Other",
        })[top]
        if not bucket then return function() return true end end
        local byItemID = HDG.HousingCatalogObserver.byItemID
        local TagData = HDG.TagData
        -- Placement-cost chip (Size bucket): exact-value match on the live row.
        local cost = _costTagValue(tag)
        if cost then
            return function(itemID)
                local row = byItemID[itemID]
                return row ~= nil and row.placementCost == cost
            end
        end
        -- Compare via GetShortLabel: activeTag uses the short display form,
        -- so long-form comparison would miss shortened expansion tags.
        return function(itemID)
            local row = byItemID[itemID]
            if not (row and row.dataTagsByID) then return false end
            for tagID in pairs(row.dataTagsByID) do
                if TagData.GetCategory(tagID) == bucket
                   and TagData.GetShortLabel(tagID) == tag then
                    return true
                end
            end
            return false
        end
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


