-- HDG.Selectors -- Acquisition tab
-- ============================================================================
-- acq.* selectors: vendor list, item list, filter chain, view toggle, detail
-- panel.

HDG = HDG or {}
local Selectors = HDG.Selectors

-- First account-wide completion record across a row.questID (number OR {ids}
-- variant set). Returns { name, class } or nil. Keyed by individual quest id.
-- Defined early -- used by both acq.items (chip-dim stamp) and the detail
-- source-line selector (completed-by attribution).
local function _recordedCompletion(state, qid)
    local store = state.account.questCompletions
    if type(qid) == "table" then
        for _, id in ipairs(qid) do
            if store[id] then return store[id] end
        end
        return nil
    end
    return store[qid]
end

-- Quest completion via BOTH sources: account-wide recorded completion (any
-- alt) and the current character's live flag. Returns rec, live -- rec is the
-- { name, class } record or nil. The chip-dim stamp wants `rec ~= nil or live`;
-- the detail source line renders the two cases differently (attributed vs bare
-- checkmark). Single definition so the two-source semantics can't diverge.
local function _questCompletion(state, qid)
    local rec = _recordedCompletion(state, qid)
    return rec, HDG.QuestNameResolver:IsComplete(qid) == true
end

-- ============================================================================
-- Acquisition browser selectors
-- ============================================================================
-- Same composition shape as Decor: allVendors -> filterQuery -> vendors,
-- countLabel composes both. Plus master/detail selectors for the right
-- panel: acq.selectedNpcID + acq.selected.* flat selectors per field.

-- Master vendor list. Reads HousingCatalogObserver; joins with VendorAugment
-- for coords / faction / expansion.
--
-- `faction` and `reps` are DIFFERENT axes:
--   faction = vendor's allegiance (A/H/N) from VendorAugment, or "N" default.
--   reps    = set of rep faction NAMES that gate items this vendor sells.
--             Built from catalog row.factionGate per item -- O(1) at filter
--             time by caching on the vendor record.
--
-- canWaypoint = VendorAugment entry exists (has real coords for TomTom).
-- Vendors known only by name (no augment match) still appear with canWaypoint=false.
-- Reads session.resolvers.catalog.tick so the list rebuilds on each sweep.
local FACTION_LABEL = { A = "Alliance", H = "Horde", N = "Neutral" }
Selectors:Register("acq.allVendors", {
    memoized = true,  -- perf: base vendor walk; called transitively ~1000x/session
    reads = {"session.resolvers.staticData.tick",  "session.resolvers.catalog.tick" },
    fn = function()
        if not HDG.HousingCatalogObserver:IsReady() then return {} end
        -- Iterate byVendor entries directly (one per (name, zone) composite
        -- key). Catalog ships ~9 vendor names that exist in multiple zones --
        -- each emits its own row here so the UI shows them as separate
        -- vendors (e.g., "High Tides" Ren at Founder's Point vs Razorwind
        -- Shores). VendorAugment.ResolveName(name, zone) gives the matching
        -- npcID per row; meta gives coords / faction.
        local list  = {}
        local seen  = {}  -- npcID -> list index (recipeCount stamp + recipe-vendor dedup)
        for _, catalogVendor in pairs(HDG.HousingCatalogObserver.byVendor) do
            -- catalogVendor = { name, zone, items, faction, standing }
            local name = catalogVendor.name
            local zone = catalogVendor.zone
            local npcID = HDG.StaticData.VendorAugment:ResolveName(name, zone)
            local meta  = npcID and HDG.StaticData.VendorAugment:Get(npcID) or nil
            local reps = {}
            for _, itemID in ipairs(catalogVendor.items) do
                local row = HDG.HousingCatalogObserver:GetRow(itemID)
                if row and row.factionGate and row.factionGate.factionName
                   and row.factionGate.factionName ~= "" then
                    reps[row.factionGate.factionName] = true
                end
            end
            local factionRaw = (meta and meta.faction) or "N"
            local metaZone = meta and meta.zone
            local row = {
                npcID      = npcID,
                name       = name,
                -- Two zones: display (curated VendorAugment when known --
                -- e.g., "Dazar'alor" instead of catalog's broader "Zuldazar")
                -- and catalogZone (the authoritative key into byVendor, used
                -- for the click->stamp->lookup round-trip). They diverge for
                -- ~10-20 vendors where VendorAugment lists a sub-zone /
                -- city while catalog ships the parent map.
                zone       = metaZone or zone,
                catalogZone = zone,
                mapID      = meta and meta.mapID,
                x          = meta and meta.x,
                y          = meta and meta.y,
                faction    = FACTION_LABEL[factionRaw] or factionRaw,
                factionRaw = factionRaw,
                expansion  = meta and meta.expansion,
                note       = meta and meta.note,   -- exception(nullable): curated endeavor/vendor note; VendorAugment lookup can miss
                itemCount  = #catalogVendor.items,
                recipeCount = 0,
                reps       = reps,
                canWaypoint = meta ~= nil,
            }
            -- De-dupe by npcID. The catalog sometimes lists ONE vendor under
            -- multiple zone strings (Gina Mudclaw -> "Timeless Isle" + "Valley of
            -- the Four Winds"; only Valley is real) -- both resolve to one npcID,
            -- leaving the bad one as a non-selectable phantom. Keep the row whose
            -- catalogZone matches the resolved location; drop the mislabeled other.
            local prev = npcID and seen[npcID]
            if prev then
                if zone == metaZone and list[prev].catalogZone ~= metaZone then
                    list[prev] = row   -- the correctly-zoned row wins
                end
            else
                list[#list + 1] = row
                if npcID then seen[npcID] = #list end
            end
        end

        -- Union recipe vendors. byVendor only knows DECOR sellers, so recipe-only
        -- quartermasters (Lyrendal, Construct V'anore -- 0 decor) are invisible
        -- above. Stamp recipeCount on catalog vendors that also sell recipes; add
        -- the recipe-only ones from VendorAugment (which now covers them).
        for npcID, count in pairs(HDG.StaticData.Recipes:RecipeVendorCounts()) do
            local idx = seen[npcID]
            if idx then
                list[idx].recipeCount = count
            else
                local meta = HDG.StaticData.VendorAugment:Get(npcID)
                if meta then  -- exception(boundary): recipe vendor must be in (generated) VendorAugment
                    local factionRaw = meta.faction or "N"
                    list[#list + 1] = {
                        npcID = npcID, name = meta.name,
                        zone = meta.zone, catalogZone = meta.zone,
                        mapID = meta.mapID, x = meta.x, y = meta.y,
                        faction = FACTION_LABEL[factionRaw] or factionRaw,
                        factionRaw = factionRaw, expansion = meta.expansion,
                        itemCount = 0, recipeCount = count, reps = {},
                        canWaypoint = true,
                    }
                end
                -- Missing from VendorAugment: skipped. The gap is warned once by
                -- HDG.StaticData's recipe-index cross-check (selectors stay pure).
            end
        end
        -- pairs() yields entries in undefined order -- sort by name then zone
        -- for deterministic display + stable scrollbox row identity.
        table.sort(list, function(a, b)
            if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
            return (a.zone or "") < (b.zone or "")
        end)
        return list
    end,
})

Selectors:Register("acq.filterQuery", {
    reads = {"session.ui.acquisition.searchQuery"},
    fn = function(state)
        return state.session.ui.acquisition.searchQuery
    end,
})

-- View mode ("vendor" | "item"). Determines which list/buttons/count
-- label render. Driven by the two view-toggle buttons at top of the
-- filter column. Defaults to "vendor".
Selectors:Register("acq.viewMode", {
    memoized = true,
    reads = {"session.ui.acquisition.viewMode"},
    fn = function(state)
        local acq = state.session.ui.acquisition
        local v = acq.viewMode
        return (v == "item") and "item" or "vendor"
    end,
})

Selectors:Register("acq.isViewMode_vendor", {
    calls = {"acq.viewMode"},
    fn = function(state, ctx)
        return Selectors:Call("acq.viewMode", state, ctx) == "vendor"
    end,
})
Selectors:Register("acq.isViewMode_item", {
    calls = {"acq.viewMode"},
    fn = function(state, ctx)
        return Selectors:Call("acq.viewMode", state, ctx) == "item"
    end,
})
-- Item-view split by the Recipes preset: it swaps the master list from the decor
-- catalog (itemList -> acq.items) to the flat teaching-scroll list (recipeList ->
-- acq.recipeRows). Two scrollboxes share the acq.list cell; these pick which renders.
Selectors:Register("acq.isViewMode_item_recipes", {
    calls = {"acq.isViewMode_item", "acq.preset"},
    fn = function(state, ctx)
        return Selectors:Call("acq.isViewMode_item", state, ctx)
           and Selectors:Call("acq.preset", state, ctx) == "recipes"
    end,
})
Selectors:Register("acq.isViewMode_item_decor", {
    calls = {"acq.isViewMode_item", "acq.preset"},
    fn = function(state, ctx)
        return Selectors:Call("acq.isViewMode_item", state, ctx)
           and Selectors:Call("acq.preset", state, ctx) ~= "recipes"
    end,
})


-- List panel title flips with viewMode -- "Vendors" or "Search for Decor".
Selectors:Register("acq.listTitle", {
    calls = {"acq.viewMode"},
    fn = function(state, ctx)
        return Selectors:Call("acq.viewMode", state, ctx) == "item" and "Search for Decor" or "Vendors"
    end,
})

-- Detail panel title: vendor/item name + faction icon. Item count + collected
-- count moved to the sibling milestone label (acq.milestoneText) so the
-- title stays a clean identity slot. Title text is the bare name; the
-- panel header lays it out beside the milestone + expansion badge.
local FACTION_ATLAS = {
    -- Atlas keys match HDG's HDG_AcqRows.lua:508-510 -- the
    -- communities-create-button-* set reads cleanly at 14px.
    A = "communities-create-button-wow-alliance",
    H = "communities-create-button-wow-horde",
    -- Neutral has no faction-specific icon; we omit the marker so the
    -- title reads "Vendor Name" without a placeholder glyph.
}
Selectors:Register("acq.detailTitle", {
    -- account.config.scheme: bakes Theme color codes; re-run on scheme swap.
    reads = {"account.config.scheme"},
    calls = {"acq.viewMode", "acq.selectedVendor", "acq.selectedItem"},
    fn = function(state, ctx)
        local mode = Selectors:Call("acq.viewMode", state, ctx)
        if mode == "item" then
            local item = Selectors:Call("acq.selectedItem", state, ctx)
            if not item then return "Select an item" end
            return HDG.Theme:CollectionLabel(item.isCollected, item.name)
        end
        local vendor = Selectors:Call("acq.selectedVendor", state, ctx)
        if not vendor then return "Select a vendor" end
        local icon = FACTION_ATLAS[vendor.factionRaw or "N"]
        local prefix = icon
            and string.format("|A:%s:14:14|a ", icon)
            or  ""
        -- Vendor title colored by whether you've collected everything it sells
        -- (done -> recede; has-missing -> accent) -- matches the vendor rows.
        return prefix .. HDG.Theme:CollectionLabel(vendor.allCollected, vendor.name)
    end,
})

-- Milestone text shown beside the title. "N/M items" when partial (dim),
-- "<check> N/M items" green when all collected, "" when no vendor or no
-- items. Uses the common-icon-checkmark atlas escape (|A:...|a) instead of
-- a raw unicode glyph -- ASCII-clean per CLAUDE.md.
Selectors:Register("acq.milestoneText", {
    reads = {"account.config.scheme"},  -- color codes baked in; re-run on scheme swap
    calls = {"acq.isViewMode_vendor", "acq.hasSelectedNpc",
             "acq.selected.items", "acq.selected.recipes"},
    fn = function(state, ctx)
        -- View-mode gate: "N/M items" is a vendor-view-only summary (how many
        -- of THIS vendor's items the player has collected). In item-view the
        -- selected-vendor state may still be set from a prior vendor-view
        -- session; skip the milestone so it doesn't leak into the item title.
        if not Selectors:Call("acq.isViewMode_vendor", state, ctx) then return "" end
        if not Selectors:Call("acq.hasSelectedNpc", state, ctx) then return "" end
        local items   = Selectors:Call("acq.selected.items", state, ctx)
        local recipes = Selectors:Call("acq.selected.recipes", state, ctx)
        -- Fold recipes into the milestone: total += recipe count, collected +=
        -- known recipes (a known recipe is "done" for this vendor, same as a
        -- collected item). Also gives recipe-only quartermasters a count.
        local total = #items + #recipes
        if total == 0 then return "" end
        local collected = 0
        for _, it in ipairs(items) do
            if it.isCollected then collected = collected + 1 end
        end
        for _, r in ipairs(recipes) do
            if r.isKnown then collected = collected + 1 end
        end
        local text = string.format("%d/%d items", collected, total)
        if collected == total then
            -- All collected: prepend checkmark atlas + wrap in collected color.
            return HDG.Theme:GetTextStateColorToken("collected")
                .. "|A:common-icon-checkmark:12:12|a " .. text .. "|r"
        end
        return text
    end,
})

-- Expansion label for the panel header slot, right-aligned beside the
-- title. Flips per viewMode: item-view -> item.expansion, vendor-view ->
-- vendor.expansion. Lore-colored via HDG.Expansion.GetColorHex (matches
-- decorDetailPanel.headerExpansion).
Selectors:Register("acq.detailExpansion", {
    calls = {"acq.viewMode", "acq.selectedItem", "acq.selectedVendor"},
    fn = function(state, ctx)
        local mode = Selectors:Call("acq.viewMode", state, ctx)
        local exp
        if mode == "item" then
            local item = Selectors:Call("acq.selectedItem", state, ctx)
            exp = item and item.expansion
        else
            local vendor = Selectors:Call("acq.selectedVendor", state, ctx)
            exp = vendor and vendor.expansion
        end
        if not exp or exp == "?" or exp == "" then return "" end
        local hex = HDG.Expansion.GetColorHex(exp)
        if not hex then return exp end
        return hex .. exp .. "|r"
    end,
})

-- Master item list (Find by Item view). All catalog rows are released items
-- so no liveDecorIDs gate is needed.
Selectors:Register("acq.allItems", {
    reads    = {"session.resolvers.staticData.tick", "session.resolvers.catalog.tick"},
    memoized = true,
    fn = function()
        if not HDG.HousingCatalogObserver:IsReady() then return {} end
        local recipes = HDG.StaticData.Recipes:GetAll() or {}

        local items = {}
        HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
            local aug     = HDG.StaticData.ItemAugment:Get(itemID)
            local recipe  = recipes[itemID]
            -- requiresRep: ItemAugment factionID > 0, or catalog factionGate present.
            local requiresRep = (aug and aug.factionID and aug.factionID > 0) == true
                             or row.factionGate ~= nil
            -- sourceType / altSourceType: first 2 entries from aug.sources[].
            -- Sources beyond [2] ignored at this surface.
            local srcType, altSrcType = 0, 0
            if aug and aug.sources then
                srcType    = (aug.sources[1] and aug.sources[1].type) or 0
                altSrcType = (aug.sources[2] and aug.sources[2].type) or 0
            end
            -- expName from catalog expansion tag.
            local exp = HDG.HousingCatalogObserver:GetExpansionForItem(itemID) or "?"
            -- First vendor entry for display (sourceName/sourceDetail in row list).
            local fv = row.vendors and row.vendors[1]
            -- Its own metatable: acq.items rows inherit these fields instead of
            -- copying them (4.8 MB per rebuild before, 2026-09-13).
            local item = {
                itemID        = itemID,
                decorID       = row.decorID,
                name          = row.name or "Unknown",
                expansion     = exp,
                sourceType    = srcType,
                altSourceType = altSrcType,
                sourceName    = (fv and fv.name) or "",
                sourceDetail  = (fv and fv.zone) or "",
                profession    = recipe and recipe.profession or nil,
                requiresRep   = requiresRep,
                -- Quest/achievement gate ids carried for the row-list chip-dim
                -- (acq.items stamps questDone/achEarned; GateChips fades the
                -- [QUST]/[ACH] chip until the gate is met).
                questID       = row.questID,
                achievementID = row.achievementID,
            }
            item.__index = item
            items[#items + 1] = item
        end)
        table.sort(items, HDG.TableUtils.ByNameThenItemID)
        return items
    end,
})

-- Current preset string ("missing" / "achievement" / "reputation" /
-- "crafted" / "quest") or nil.
Selectors:Register("acq.preset", {
    memoized = true,
    reads = {"session.ui.acquisition.preset"},
    fn = function(state)
        local acq = state.session.ui.acquisition
        return acq.preset or nil
    end,
})

-- Per-preset boolean selectors. Drive chip `active` bindings so the
-- currently-selected preset paints highlighted. Generated from
-- HDG.Constants.ACQ_PRESETS.
for _, entry in ipairs(HDG.Constants.ACQ_PRESETS or {}) do
    local captured = entry.value
    Selectors:Register("acq.preset.active_" .. captured, {
        calls = {"acq.preset"},
        fn = function(state, ctx)
            return Selectors:Call("acq.preset", state, ctx) == captured
        end,
    })
end

-- Endeavor currency = Community Coupons (Constants HOUSING_DECOR_CURRENCY_DATA).
local ENDEAVOR_CURRENCY = HDG.Constants.COUPON_CURRENCY_ID
-- Cost-based flags from the catalog row's baked costEntries -- keyed by itemID
-- so BOTH view modes share one path (item mode: item.itemID; vendor mode: the
-- raw itemID via the shared item predicate). Returns (costsEndeavor, isGoldOnly):
--   costsEndeavor = any cost entry is Community Coupons (3363)
--   isGoldOnly    = has cost AND every entry is gold
-- Reads baked costEntries from the observer.
local function _itemCostFlags(itemID)
    local row = itemID and HDG.HousingCatalogObserver:GetRow(itemID)
    local entries = row and row.costEntries
    if not (entries and #entries > 0) then return false, false end
    local GOLD = HDG.Constants.CURRENCY_GOLD
    local endeavor, allGold = false, true
    for _, e in ipairs(entries) do
        if e.currencyID == ENDEAVOR_CURRENCY then endeavor = true end
        if e.currencyID ~= GOLD then allGold = false end
    end
    return endeavor, allGold
end

-- Curried filter: returns a function (envRow) -> bool. Caller composes
-- into acq.items. Source-type presets walk row.sourceTags membership via
-- the catalog row (canonical signal -- covers catalog + ItemAugment + recipe-
-- derived). missing/endeavor resolve cost flags by itemID (so both modes share
-- them) -- they're not source kinds.
local function _matchesFlag(flag)
    return function(envRow)
        if not envRow.itemID then return false end
        local catRow = HDG.HousingCatalogObserver:GetRow(envRow.itemID)
        if not catRow or not catRow.sourceTags then return false end
        for _, t in ipairs(catRow.sourceTags) do
            if t.kind == flag then return true end
        end
        return false
    end
end
local _PRESET_TO_FLAG = {
    achievement = "ACH",
    quest       = "QUEST",
    reputation  = "REP",
    crafted     = "CRAFT",
}
-- SOLD IN A HOUSING NEIGHBORHOOD. The predicate lives on the catalog observer
-- (IsSoldInNeighborhood) because the companion's "Neighborhood Decor" collection
-- asks the same question; this adapts it to an envelope row.
local function _matchesNeighborhood(envRow)
    if not envRow.itemID then return false end
    local catRow = HDG.HousingCatalogObserver:GetRow(envRow.itemID)
    if not catRow then return false end  -- exception(nullable): itemID outside the catalog
    return HDG.HousingCatalogObserver:IsSoldInNeighborhood(catRow)
end

-- NOTHING BETWEEN YOU AND BUYING IT: a vendor sells it, the price is gold, and
-- no reputation, quest or achievement stands in the way.
--
-- THE EXCLUSIONS ARE THE POINT. A gold price alone already had a filter and it
-- was not what anyone wanted -- promotional and shop decor carries gold prices
-- too. Requiring VENDOR and then refusing every gating kind is what turns "you
-- can pay for this" into "you can go and get this".
--
-- KNOWN LIMIT: this reads gating on the ITEM. A vendor who only appears after
-- a questline is not modelled anywhere in the data, so their gold stock still
-- passes. The `neighborhood` filter has no such hole, which is why both ship --
-- one is exact and narrow, this one is broad and honest about its edge.
-- A SET, and walked ONCE. The first cut called _matchesFlag(kind) per blocker
-- per row -- but that is a FACTORY, built once at selector-build time the way
-- acq.matchesSource uses it. Called per row it allocated six closures and did
-- eight catalog lookups for every item, ~2000 items per evaluation. One row
-- fetch and one pass over sourceTags answers all six questions.
local UNGATED_BLOCKERS = { REP = true, QUEST = true, ACH = true,
                           PROMO = true, SHOP = true }

local function _matchesUngated(envRow)
    if not envRow.itemID then return false end
    local catRow = HDG.HousingCatalogObserver:GetRow(envRow.itemID)
    if not catRow then return false end  -- exception(nullable): itemID outside the catalog
    -- The vendor's OWN standing requirement, which is not an item source tag:
    -- an item with no source gate can still sit behind a revered-only merchant.
    if catRow.factionGate then return false end
    -- No source signal at all is not "ungated" -- it is "unknown", and the
    -- UNKN kind exists precisely so those surface rather than defaulting.
    if not catRow.sourceTags then return false end
    local _, gold = _itemCostFlags(envRow.itemID)
    if not gold then return false end
    local vendor = false
    for _, t in ipairs(catRow.sourceTags) do
        if UNGATED_BLOCKERS[t.kind] then return false end
        if t.kind == "VENDOR" then vendor = true end
    end
    return vendor
end

Selectors:Register("acq.matchesPreset", {
    -- SOURCE axis only. "missing" moved to acq.matchesMissing (orthogonal).
    reads = {"session.resolvers.catalog.tick"},
    calls = {"acq.preset"},
    fn = function(state, ctx)
        local preset = Selectors:Call("acq.preset", state, ctx)
        if preset == nil then return function() return true end end
        local flag = _PRESET_TO_FLAG[preset]
        if flag then return _matchesFlag(flag) end
        if preset == "endeavor" then
            -- Endeavor = items costing Community Coupons (3363), read from the
            -- catalog row's baked costEntries by itemID (works in both modes).
            return function(row) return (_itemCostFlags(row.itemID)) == true end
        end
        -- SHARED with the source dropdown, not reimplemented. Both axes ask the
        -- same question of a row; two copies is how the chip and the dropdown
        -- quietly start disagreeing about what "ungated" means.
        if preset == "neighborhood" then return _matchesNeighborhood end
        if preset == "ungated" then return _matchesUngated end
        -- "recipes" is a VENDOR-level filter (recipeCount), applied in acq.vendors;
        -- it doesn't constrain ITEMS, so pass-all here so it composes cleanly.
        if preset == "recipes" then return function() return true end end
        return function() return false end
    end,
})

-- Collection-state axis: the orthogonal "Missing" checkbox toggle. ANDs with
-- the source preset in acq.matchesItemFilters so "missing achieve",
-- "missing rep", etc. compose instead of being mutually exclusive.
Selectors:Register("acq.missingOnly", {
    reads = {"session.ui.acquisition.missingOnly"},
    fn = function(state)
        return state.session.ui.acquisition.missingOnly == true
    end,
})
-- Curried Missing predicate: toggle off -> pass-all; on -> uncollected-only.
-- Mirrors the old matchesPreset "missing" branch (reads owned set live).
Selectors:Register("acq.matchesMissing", {
    reads = {"account.collection.ownedDecorIDs", "session.resolvers.catalog.tick"},
    calls = {"acq.missingOnly", "decor.isCollected"},
    fn = function(state, ctx)
        if not Selectors:Call("acq.missingOnly", state, ctx) then
            return function() return true end
        end
        local isColl = Selectors:Call("decor.isCollected", state, ctx)
        return function(row)
            return not (isColl and isColl(row.itemID))
        end
    end,
})

-- Source dropdown state + label + menu + predicate.
Selectors:Register("acq.sourceFilter", {
    reads = {"session.ui.acquisition.sourceFilter"},
    fn = function(state)
        return state.session.ui.acquisition.sourceFilter
    end,
})
Selectors:Register("acq.sourceMenuItems", {
    reads    = {},
    memoized = true,
    fn = function()
        local items = {}
        for _, opt in ipairs(HDG.Constants.ACQ_SOURCES or {}) do
            items[#items + 1] = { kind = "checkbox", value = opt.value, text = opt.label,
                isAll = opt.value == "all" }
        end
        return items
    end,
})
Selectors:Register("acq.hasSourceFilter", {
    calls = {"acq.sourceFilter"},
    fn = function(state, ctx)
        local set = Selectors:Call("acq.sourceFilter", state, ctx)
        return next(set) ~= nil
    end,
})

-- Source dropdown filter. Reads CANONICAL row.sourceTags via the SOURCE_KINDS
-- master table: SOURCE_KIND_BY_FILTER[v].key -> the kind string to check.
-- One lookup, one source of truth.
Selectors:Register("acq.matchesSource", {
    -- sweepGeneration: endeavor/neighborhood/ungated + _matchesFlag read the
    -- catalog row (costEntries / sourceTags) by itemID -- re-resolve on re-sweep.
    reads = {"session.resolvers.catalog.tick"},
    calls = {"acq.sourceFilter"},
    fn = function(state, ctx)
        local set = Selectors:Call("acq.sourceFilter", state, ctx)
        if next(set) == nil then return function() return true end end
        -- Multi-select: build one matcher per selected source value; a row passes if
        -- ANY matches (OR within the source axis).
        local matchers = {}
        for v in pairs(set) do
            local kind = HDG.Constants.SOURCE_KIND_BY_FILTER[v]
            if kind then
                matchers[#matchers + 1] = _matchesFlag(kind.key)
            elseif v == "endeavor" then
                matchers[#matchers + 1] = function(row) return (_itemCostFlags(row.itemID)) == true end
            elseif v == "neighborhood" then
                matchers[#matchers + 1] = _matchesNeighborhood
            elseif v == "ungated" then
                matchers[#matchers + 1] = _matchesUngated
            end
        end
        if #matchers == 0 then return function() return false end end
        return function(row)
            for _, m in ipairs(matchers) do if m(row) then return true end end
            return false
        end
    end,
})

-- Unified item-intrinsic filter predicate (source + expansion + preset),
-- reused by BOTH view modes: item mode tests it per item.itemID; vendor mode
-- tests "sells >=1 item passing it" (see _vendorSellsMatchingItem). Returns
-- fn(itemID) -> bool, composing the existing matchesSource + matchesPreset
-- closures (which read the catalog row by .itemID) plus an expansion check via
-- the catalog's GetExpansionForItem. sweepGeneration read covers the GetRow /
-- GetExpansionForItem observer-cache lookups; matchesPreset transitively
-- carries decor.isCollected (the "missing" signal).
Selectors:Register("acq.matchesItemFilters", {
    calls = {"acq.matchesSource", "acq.matchesPreset", "acq.matchesMissing", "acq.expansionFilter"},
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local matchSource  = Selectors:Call("acq.matchesSource",   state, ctx)
        local matchPreset  = Selectors:Call("acq.matchesPreset",   state, ctx)
        local matchMissing = Selectors:Call("acq.matchesMissing",  state, ctx)
        local expSet = Selectors:Call("acq.expansionFilter", state, ctx)
        local hasExp = next(expSet) ~= nil
        return function(itemID)
            if not itemID then return false end
            if hasExp and not expSet[HDG.HousingCatalogObserver:GetExpansionForItem(itemID)] then
                return false
            end
            local probe = { itemID = itemID }
            if matchSource  and not matchSource(probe)  then return false end
            if matchPreset  and not matchPreset(probe)  then return false end
            if matchMissing and not matchMissing(probe) then return false end
            return true
        end
    end,
})

-- Needle match across the four searchable item fields.
local function _matchesNeedle(item, needle)
    return (item.name and item.name:lower():find(needle, 1, true))
        or (item.profession and item.profession:lower():find(needle, 1, true))
        or (item.expansion  and item.expansion:lower():find(needle, 1, true))
        or (item.sourceName and item.sourceName:lower():find(needle, 1, true))
end

-- Vendor-axis filters (rep / zone / faction) in ITEM mode, by walking the
-- item's baked row.vendors (the existing item->vendor index -- no new index).
-- Rep is item-intrinsic (catalog factionGate; the vendor "reps" set is DERIVED
-- from it). Zone/faction pass if ANY vendor matches -- display zone +
-- FACTION_LABEL'd faction resolved via the baked npcID, mirroring allVendors.
-- Vendor mode filters the vendor list itself, separately.
local function _passesVendorAxes(item, hasRep, hasZone, hasFaction, repSet, zoneSet, factionSet, Aug)
    local catRow = HDG.HousingCatalogObserver:GetRow(item.itemID)  -- exception(boundary): GetRow nil pre-bake
    if hasRep then
        local fg = catRow and catRow.factionGate
        if not (fg and fg.factionName and repSet[fg.factionName]) then return false end
    end
    if hasZone or hasFaction then
        for _, v in ipairs(catRow and catRow.vendors or {}) do  -- exception(boundary): row.vendors absent pre-bake
            local meta   = v.npcID and Aug:Get(v.npcID)
            local zoneOK = (not hasZone)    or zoneSet[((meta and meta.zone) or v.zone)] == true
            local facOK  = (not hasFaction) or factionSet[(FACTION_LABEL[(meta and meta.faction) or "N"] or "Neutral")] == true
            if zoneOK and facOK then return true end
        end
        return false
    end
    return true
end

-- First REP source tag carrying a live faction + requirement code, or nil.
-- Shared by the row-list chip-dim stamp, the by-vendor item list, and the
-- detail source line. row nil / no sourceTags pre-bake -> nil.
local function _findRepSourceTag(row)
    if not (row and row.sourceTags) then return nil end  -- exception(boundary): GetRow nil + sourceTags absent pre-bake
    for _, t in ipairs(row.sourceTags) do
        if t.kind == "REP" and t.factionID and t.requiredCode then return t end
    end
    return nil
end

-- repMet chip-dim signal from a catalog row's REP gate (live RepObserver
-- progress, gated by rep.tick in the caller's reads). nil when no rep gate.
local function _repMetForRow(row)
    local t = _findRepSourceTag(row)
    if not t then return nil end
    local prog = HDG.RepObserver:GetProgress(t.factionID, t.requiredCode)
    return (prog and prog.met) == true
end

-- Chip-dim stamps (questDone / achEarned / repMet) on a shallow-copied row.
-- questDone is account-wide (any alt's recorded completion) OR the current
-- char's live flag (via _questCompletion -- shared with the detail source
-- line); achEarned is account-wide. GateChips fades the matching chip when
-- false. The impure IsComplete/IsEarned/GetProgress calls are gated by the
-- questStatus/achievementStatus/rep ticks in the calling selector's reads.
local function _stampChipDim(stamped, item, state)
    if item.questID then
        local rec, live = _questCompletion(state, item.questID)
        stamped.questDone = rec ~= nil or live
    end
    if item.achievementID then
        stamped.achEarned = HDG.AchievementObserver:IsEarned(item.achievementID) == true
    end
    if item.requiresRep then
        stamped.repMet = _repMetForRow(HDG.HousingCatalogObserver:GetRow(item.itemID))
    end
end

-- Filtered items: search applies to name + profession + expansion + sourceName;
-- source + expansion + preset compose on top via acq.matchesItemFilters.
Selectors:Register("acq.items", {
    memoized = true,  -- perf: filtered+built item list (~3.8ms walk); shared per flush by the list binding + blankItem + hasResults
    -- acq.selectedItemID retired -- selection owned by SelectionBehaviorMixin
    -- on acquisitionListPanel.itemList. Row factory reads ed.selected.
    calls = {"acq.allItems", "acq.filterQuery", "acq.matchesItemFilters",
             "acq.repFilter", "acq.zoneFilter", "acq.factionFilter", "decor.isCollected"},
    -- Status ticks + account.questCompletions + rep tick: re-stamp questDone/achEarned/
    -- repMet (the row-list chip-dim signals) when completion or rep changes. Gate the
    -- impure IsComplete/IsEarned/GetProgress calls below -- same boundary as the detail line.
    -- sweepGeneration: the rep-axis GetRow(itemID).factionGate lookup below reads the bake.
    reads = {"session.resolvers.questStatus.tick", "session.resolvers.achievementStatus.tick", "account.questCompletions",
             "session.resolvers.rep.tick", "session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local all       = Selectors:Call("acq.allItems",           state, ctx)
        local q         = Selectors:Call("acq.filterQuery",        state, ctx)
        local matchItem = Selectors:Call("acq.matchesItemFilters", state, ctx)
        local isColl    = Selectors:Call("decor.isCollected",      state, ctx)
        local repSet     = Selectors:Call("acq.repFilter",     state, ctx)
        local zoneSet    = Selectors:Call("acq.zoneFilter",    state, ctx)
        local factionSet = Selectors:Call("acq.factionFilter", state, ctx)
        local hasRep     = next(repSet)     ~= nil
        local hasZone    = next(zoneSet)    ~= nil
        local hasFaction = next(factionSet) ~= nil
        local Aug        = HDG.StaticData.VendorAugment
        local needle     = q ~= "" and q:lower() or nil
        local out = {}
        for _, item in ipairs(all) do
            local pass = true
            if needle then
                pass = _matchesNeedle(item, needle) and true or false
            end
            if pass and not matchItem(item.itemID) then pass = false end
            if pass and (hasRep or hasZone or hasFaction) then
                pass = _passesVendorAxes(item, hasRep, hasZone, hasFaction,
                                         repSet, zoneSet, factionSet, Aug)
            end
            if pass then
                -- Inherit + stamp: acq.allItems is memoized, so the stamps land on
                -- a row of their own that reads the item's fields through its
                -- metatable. Source chips: row factories call
                -- UI.GateChips(ed.itemID, questDone, achEarned), which reads
                -- row.sourceTags baked at BuildRow.
                local stamped = setmetatable({}, item)
                stamped.isCollected = isColl and isColl(item.itemID) or false
                _stampChipDim(stamped, item, state)
                out[#out + 1] = stamped
            end
        end
        return out
    end,
})

-- Flat teaching-scroll list for the Find Decor "Recipes" preset. One row per
-- recipe scroll -- the buyable item that adds a recipe to the profession book,
-- NOT the craftable recipe itself (that lives in the Recipes tab). Mirrors the
-- acq.selected.recipes envelope so acqVendorItemListRow paints it identically
-- (icon | "Recipe: <name>" | cost). Cost/rep/source come from the first vendor;
-- non-vendor-sourced recipes (drops/quests) are skipped -- nothing to buy.
Selectors:Register("acq.allRecipes", {
    memoized = true,
    reads = {"session.resolvers.staticData.tick", "account.recipes"},
    fn = function(state)
        local out = {}
        for _, entry in pairs(HDG.StaticData.Recipes:GetAll()) do
            local rs = entry.recipeSource
            local v  = rs and rs.vendors and rs.vendors[1]  -- exception(boundary): recipeSource optional / non-vendor source
            if entry.itemID and v then
                local rk = state.account.recipes[entry.itemID]
                out[#out + 1] = {
                    kind            = "recipe",
                    itemID          = entry.itemID,
                    name            = "Recipe: " .. entry.name,
                    teaches         = entry.name,        -- decor the scroll unlocks (detail "Teaches:")
                    profession      = entry.profession,
                    professionAtlas = HDG.Format.ProfessionAtlas(entry.profession),
                    isKnown         = rk ~= nil and (rk.selfKnown or rk.altKnown) or false,
                    costText        = HDG.Format.FormatVendorCost(v.cost),
                    factionID       = v.factionID,
                    minRep          = v.minRep,
                }
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end,
})

-- acq.allRecipes filtered by the search box + Missing checkbox (Missing -> drop
-- already-known scrolls). The Find Decor recipeList scrollbox binds here.
Selectors:Register("acq.recipeRows", {
    memoized = true,
    calls = {"acq.allRecipes", "acq.filterQuery", "acq.missingOnly"},
    fn = function(state, ctx)
        local all     = Selectors:Call("acq.allRecipes", state, ctx)
        local q       = Selectors:Call("acq.filterQuery", state, ctx)
        local missing = Selectors:Call("acq.missingOnly", state, ctx)
        local needle  = q ~= "" and q:lower() or nil
        if not needle and not missing then return all end
        local out = {}
        for _, r in ipairs(all) do
            local pass = true
            if missing and r.isKnown then pass = false end
            if pass and needle then
                pass = (r.name:lower():find(needle, 1, true))
                    or (r.profession and r.profession:lower():find(needle, 1, true))
                pass = pass and true or false
            end
            if pass then out[#out + 1] = r end
        end
        return out
    end,
})

-- Current faction filter ("all" / "Alliance" / "Horde" / "Neutral").
Selectors:Register("acq.factionFilter", {
    reads = {"session.ui.acquisition.factionFilter", "session.resolvers.staticData.tick"},
    fn = function(state)
        return state.session.ui.acquisition.factionFilter   -- multi-select SET ({} = all)
    end,
})

-- Menu items for the faction dropdown. Static enum; no state reads.
Selectors:Register("acq.factionMenuItems", {
    reads    = {},
    memoized = true,
    fn = function()
        return {
            { kind = "checkbox", isAll = true, value = "all", text = "All factions" },
            { kind = "checkbox", value = "Alliance", text = "Alliance" },
            { kind = "checkbox", value = "Horde",    text = "Horde"    },
            { kind = "checkbox", value = "Neutral",  text = "Neutral"  },
        }
    end,
})

-- ===== Advanced filters: collapsible state + per-axis dropdowns ============
--
-- Each filter axis follows the same triple: filter (current value), label
-- (display text), menuItems (data-derived options). Helper below cuts
-- the boilerplate so adding a new axis is ~10 lines, not 30.

Selectors:Register("acq.advancedFiltersOpen", {
    reads = {"session.ui.acquisition.advancedFiltersOpen"},
    fn = function(state)
        local acq = state.session.ui.acquisition
        return acq.advancedFiltersOpen == true or false
    end,
})

Selectors:Register("acq.advancedFiltersLabel", {
    calls = {"acq.advancedFiltersOpen"},
    fn = function(state, ctx)
        local open = Selectors:Call("acq.advancedFiltersOpen", state, ctx)
        return open and "- Advanced Filters" or "+ Advanced Filters"
    end,
})

-- Per-axis filter registration. Each call adds three selectors:
--   acq.<axis>Filter      -> current value (default "all")
--   acq.<axis>Label       -> display text ("All <Plural>" when default, else value)
--   acq.<axis>MenuItems   -> sorted unique values from data, "all" pinned first
--
-- `getter` extracts the axis value from a single vendor record. `pluralLabel`
-- is the dropdown's default display ("All Zones", "All Reps", ...).
--
-- Menu items deduplicate via acq.axisMenuItems (shared, memoized);
-- one allVendors walk per invalidation cycle.
Selectors:Register("acq.axisMenuItems", {
    calls = { "acq.allVendors" },
    fn = function(state, ctx)
        local all = Selectors:Call("acq.allVendors", state, ctx)

        -- Single walk of allVendors fills every axis bucket simultaneously.
        -- (expansion is NOT here -- its menu enumerates the EXPANSION_DATA
        -- constant via acq.expansionMenuItems, not vendor-derived data.)
        local seen = { zone = {}, rep = {} }
        for _, v in ipairs(all) do
            local zone = v.zone
            if zone and zone ~= "?" and zone ~= "" then seen.zone[zone] = true end
            if type(v.reps) == "table" then
                for rep in pairs(v.reps) do seen.rep[rep] = true end
            end
        end

        local function bucket(name, label)
            local sorted = {}
            for val in pairs(seen[name]) do sorted[#sorted + 1] = val end
            table.sort(sorted)
            local out = { { kind = "checkbox", isAll = true, value = "all", text = label } }
            for _, val in ipairs(sorted) do
                out[#out + 1] = { kind = "checkbox", value = val, text = val }
            end
            return out
        end

        return {
            zone = bucket("zone", "All Zones"),
            rep  = bucket("rep",  "All Reps"),
        }
    end,
})

local function RegisterAxis(axis, pluralLabel)
    local stateKey = axis .. "Filter"
    Selectors:Register("acq." .. stateKey, {
        reads = { HDG.Paths.Join("session.ui.acquisition", stateKey) },
        fn = function(state)
            return state.session.ui.acquisition[stateKey]   -- multi-select SET ({} = all)
        end,
    })
    Selectors:Register("acq." .. axis .. "MenuItems", {
        -- Calls the shared axisMenuItems selector; framework memoization
        -- guarantees one allVendors walk per invalidation cycle.
        calls = { "acq.axisMenuItems" },
        fn = function(state, ctx)
            local buckets = Selectors:Call("acq.axisMenuItems", state, ctx)
            return buckets[axis] or { { value = "all", text = pluralLabel } }
        end,
    })
end

-- Expansion filter state reader (was RegisterAxis-generated; its menu now
-- enumerates the EXPANSION_DATA constant instead of sparse vendor-derived data).
Selectors:Register("acq.expansionFilter", {
    reads = {"session.ui.acquisition.expansionFilter"},
    fn = function(state)
        return state.session.ui.acquisition.expansionFilter   -- multi-select SET ({} = all)
    end,
})
-- Expansion dropdown options: enumerate the canonical EXPANSION_DATA via
-- HDG.Expansion.Each() (12-expansion lore order), "all" sentinel first. Menu
-- text is tinted with the per-expansion BRAND color via HDG.Expansion.
-- GetColorHex -- the same EXPANSION_DATA.color the Palette "expansion.*"
-- namespace wraps, but from the Core Expansion module (matches the
-- acq.detailExpansion precedent + resolves headless; Palette isn't loaded in
-- the test harness). Brand colors are scheme-invariant -> reads={} memoized
-- stays valid. The WowStyle2 trigger auto-renders the selected radio's text
-- (DropdownSelectionTextMixin -> FontString:SetText renders |c..|r markup), so
-- this colors BOTH the menu rows and the trigger. `value` stays the plain
-- display name (the filter key + `current ==` match). "All" sentinel neutral.
Selectors:Register("acq.expansionMenuItems", {
    reads    = {},
    memoized = true,
    fn = function()
        local out = { { kind = "checkbox", isAll = true, value = "all", text = "All Expansions" } }
        for _, e in HDG.Expansion.Each() do
            out[#out + 1] = {
                kind  = "checkbox",
                value = e.display,
                text  = HDG.Expansion.GetColorHex(e.display) .. e.display .. "|r",
            }
        end
        return out
    end,
})
RegisterAxis("zone", "All Zones")

-- Reputation is per-item, not per-vendor (1:N: a vendor can sell items
-- gated by multiple rep factions). RegisterAxis assumes a single per-vendor
-- value, so rep gets its own three selectors that walk vendor.reps sets.
Selectors:Register("acq.repFilter", {
    reads = {"session.ui.acquisition.repFilter"},
    fn = function(state)
        return state.session.ui.acquisition.repFilter   -- multi-select SET ({} = all)
    end,
})
-- Menu items: union of every vendor's reps set. Shares the axisMenuItems
-- selector with expansion + zone; framework memoization ensures one walk
-- per invalidation cycle.
Selectors:Register("acq.repMenuItems", {
    calls = { "acq.axisMenuItems" },
    fn = function(state, ctx)
        local buckets = Selectors:Call("acq.axisMenuItems", state, ctx)
        return buckets.rep or { { value = "all", text = "All Reps" } }
    end,
})

-- ===== Per-axis "is this filter active?" booleans =========================
-- Drive tag visibility + the "Active filters" label. Each returns true
-- when its axis is anything other than the default.
Selectors:Register("acq.hasSearchFilter", {
    calls = {"acq.filterQuery"},
    fn = function(state, ctx) return Selectors:Call("acq.filterQuery", state, ctx) ~= "" end,
})
Selectors:Register("acq.hasFactionFilter", {
    calls = {"acq.factionFilter"},
    fn = function(state, ctx) return next(Selectors:Call("acq.factionFilter", state, ctx)) ~= nil end,
})
Selectors:Register("acq.hasExpansionFilter", {
    calls = {"acq.expansionFilter"},
    fn = function(state, ctx) return next(Selectors:Call("acq.expansionFilter", state, ctx)) ~= nil end,
})
Selectors:Register("acq.hasZoneFilter", {
    calls = {"acq.zoneFilter"},
    fn = function(state, ctx) return next(Selectors:Call("acq.zoneFilter", state, ctx)) ~= nil end,
})
Selectors:Register("acq.hasRepFilter", {
    calls = {"acq.repFilter"},
    fn = function(state, ctx) return next(Selectors:Call("acq.repFilter", state, ctx)) ~= nil end,
})
Selectors:Register("acq.hasPresetFilter", {
    calls = {"acq.preset"},
    fn = function(state, ctx) return Selectors:Call("acq.preset", state, ctx) ~= nil end,
})
Selectors:Register("acq.hasMissingFilter", {
    calls = {"acq.missingOnly"},
    fn = function(state, ctx) return Selectors:Call("acq.missingOnly", state, ctx) end,
})

Selectors:Register("acq.anyFilterActive", {
    calls = {"acq.hasSearchFilter", "acq.hasFactionFilter", "acq.hasExpansionFilter",
             "acq.hasZoneFilter", "acq.hasRepFilter", "acq.hasPresetFilter",
             "acq.hasMissingFilter", "acq.hasSourceFilter"},
    fn = function(state, ctx)
        return Selectors:Call("acq.hasSearchFilter",    state, ctx)
            or Selectors:Call("acq.hasFactionFilter",   state, ctx)
            or Selectors:Call("acq.hasExpansionFilter", state, ctx)
            or Selectors:Call("acq.hasZoneFilter",      state, ctx)
            or Selectors:Call("acq.hasRepFilter",       state, ctx)
            or Selectors:Call("acq.hasPresetFilter",    state, ctx)
            or Selectors:Call("acq.hasMissingFilter",   state, ctx)
            or Selectors:Call("acq.hasSourceFilter",    state, ctx)
    end,
})

Selectors:Register("acq.activeFiltersLabel", {
    calls = {"acq.anyFilterActive"},
    fn = function(state, ctx)
        if Selectors:Call("acq.anyFilterActive", state, ctx) then
            return "Active filters:"
        end
        return "No active filters"
    end,
})

-- Tag display text per axis. "Axis: Value [x]" -- the [x] glyph reads as
-- "click to clear" since the whole tag is the click target. Empty when
-- the filter isn't active so the tag's label widget stays blank when
-- visible=false drops the tag from the layout.
local function tagText(axis, valueLabel)
    return string.format("%s: %s  [x]", axis, valueLabel)
end
-- Join a multi-select filter SET's values for the chip text (sorted, stable).
-- labelMap optionally maps internal value -> display label (source axis).
local function _joinSet(set, labelMap)
    local vals = {}
    for v in pairs(set) do vals[#vals + 1] = labelMap and (labelMap[v] or v) or v end
    table.sort(vals)
    -- Cap the chip text so one many-value axis can't blow out the single-line row
    -- (the Layout engine has no flow/wrap): show up to 3, then "+N".
    local n = #vals
    if n <= 3 then return table.concat(vals, ", ") end
    return table.concat({ vals[1], vals[2], vals[3] }, ", ") .. string.format(" +%d", n - 3)
end
Selectors:Register("acq.tagSearch", {
    calls = {"acq.filterQuery"},
    fn = function(state, ctx)
        return tagText("Search", Selectors:Call("acq.filterQuery", state, ctx))
    end,
})
Selectors:Register("acq.tagFaction", {
    calls = {"acq.factionFilter"},
    fn = function(state, ctx)
        return tagText("Faction", _joinSet(Selectors:Call("acq.factionFilter", state, ctx)))
    end,
})
Selectors:Register("acq.tagExpansion", {
    calls = {"acq.expansionFilter"},
    fn = function(state, ctx)
        return tagText("Expansion", _joinSet(Selectors:Call("acq.expansionFilter", state, ctx)))
    end,
})
Selectors:Register("acq.tagZone", {
    calls = {"acq.zoneFilter"},
    fn = function(state, ctx)
        return tagText("Zone", _joinSet(Selectors:Call("acq.zoneFilter", state, ctx)))
    end,
})
Selectors:Register("acq.tagRep", {
    calls = {"acq.repFilter"},
    fn = function(state, ctx)
        return tagText("Rep", _joinSet(Selectors:Call("acq.repFilter", state, ctx)))
    end,
})
-- Preset + source tags. Display the human-readable label
-- (from ACQ_PRESETS / ACQ_SOURCES) rather than the internal value string.
Selectors:Register("acq.tagPreset", {
    calls = {"acq.preset"},
    fn = function(state, ctx)
        local v = Selectors:Call("acq.preset", state, ctx)
        if not v then return "" end
        for _, opt in ipairs(HDG.Constants.ACQ_PRESETS or {}) do
            if opt.value == v then return tagText("Preset", opt.label) end
        end
        return tagText("Preset", v)
    end,
})
-- Missing is a valueless toggle, so its tag is just "Missing  [x]" (no
-- "Axis: Value" form -- there is no value).
Selectors:Register("acq.tagMissing", {
    calls = {"acq.missingOnly"},
    fn = function(state, ctx)
        if not Selectors:Call("acq.missingOnly", state, ctx) then return "" end
        return "Missing  [x]"
    end,
})
Selectors:Register("acq.tagSource", {
    calls = {"acq.sourceFilter"},
    fn = function(state, ctx)
        local set = Selectors:Call("acq.sourceFilter", state, ctx)
        if next(set) == nil then return "" end
        local labels = {}
        for _, opt in ipairs(HDG.Constants.ACQ_SOURCES or {}) do labels[opt.value] = opt.label end
        return tagText("Source", _joinSet(set, labels))
    end,
})

-- Filtered vendors: AND-join across every axis. Adding a new axis adds
-- one local + one xxxOK guard -- pattern is mechanical, debugging stays
-- legible (one condition per visual filter).
-- Walk catalog items for this vendor; pass if at least one is uncollected.
-- Resolve a vendor record's byVendor entry. byVendor is keyed by the catalog
-- Zone: line (v.catalogZone); v.zone is the curated DISPLAY zone, which diverges
-- for ~10-20 vendors (curated sub-zone vs catalog's parent map). Centralised so
-- NO caller reconstructs the lookup and picks the wrong zone field -- that
-- divergence silently dropped zone-diverged vendors from filters + allCollected.
local function _vendorEntry(v)
    return HDG.HousingCatalogObserver:GetItemsByVendor(v.name, v.catalogZone or v.zone)
end

-- A vendor passes an item-intrinsic filter (source / expansion / preset) if it
-- sells >=1 catalog item matching `itemPred` (acq.matchesItemFilters). The
-- vendor-mode half of the unified filter model -- ONE item predicate, both views.
local function _vendorSellsMatchingItem(v, itemPred)
    local catalogVendor = _vendorEntry(v)
    if not (catalogVendor and catalogVendor.items) then return false end
    for _, itemID in ipairs(catalogVendor.items) do
        if itemPred(itemID) then return true end
    end
    return false
end

-- True when the vendor sells at least one recipe the player doesn't know.
-- Drives "Recipes + Missing" (missing = unknown recipe, not uncollected decor).
-- Reads account.recipes (declared on acq.vendors).
local function _vendorHasUnknownRecipe(state, npcID)
    local entries = HDG.StaticData.Recipes:GetBySourceNpcID(npcID)
    if not entries then return false end
    local known = state.account.recipes
    for _, e in ipairs(entries) do
        local rk = known[e.itemID]
        if not (rk and (rk.selfKnown or rk.altKnown)) then return true end
    end
    return false
end

-- True when the vendor sells at least one rep-gated recipe (factionID > 0).
-- Lets the "Rep" preset surface recipe rep gates -- the catalog only knows
-- rep-gated decor; recipe rep gates live in recipeSource.vendors.
local function _vendorHasRepGatedRecipe(npcID)
    local entries = HDG.StaticData.Recipes:GetBySourceNpcID(npcID)
    if not entries then return false end
    for _, e in ipairs(entries) do
        for _, v in ipairs(e.recipeSource.vendors) do
            if v.npcID == npcID and (v.factionID or 0) > 0 then return true end
        end
    end
    return false
end

-- Multi-field substring match for the search filter. Tests vendor name
-- AND zone (case-insensitive). `needle` is the lowered query.
local function _vendorMatchesSearch(v, needle)
    if v.name:lower():find(needle, 1, true) then return true end
    return v.zone and v.zone:lower():find(needle, 1, true) and true or false
end

Selectors:Register("acq.vendors", {
    memoized = true,  -- perf: filters the vendor walk; memo dedupes per flush
    reads = {"session.resolvers.staticData.tick", "account.recipes"},
    calls = {"acq.allVendors", "acq.filterQuery", "acq.factionFilter",
             "acq.zoneFilter", "acq.repFilter", "acq.sourceFilter",
             "acq.expansionFilter", "acq.preset", "acq.missingOnly",
             "acq.matchesItemFilters"},
    fn = function(state, ctx)
        local all       = Selectors:Call("acq.allVendors",      state, ctx)
        local q         = Selectors:Call("acq.filterQuery",     state, ctx)
        local factionSet = Selectors:Call("acq.factionFilter",   state, ctx)
        local zoneSet    = Selectors:Call("acq.zoneFilter",      state, ctx)
        local repSet     = Selectors:Call("acq.repFilter",       state, ctx)
        local sourceSet  = Selectors:Call("acq.sourceFilter",    state, ctx)
        local expSet     = Selectors:Call("acq.expansionFilter", state, ctx)
        local preset    = Selectors:Call("acq.preset",          state, ctx)
        local missingOnly = Selectors:Call("acq.missingOnly",   state, ctx)
        -- Vendor-intrinsic axes (multi-select SETs) -- checked per-vendor below.
        local hasSearch  = q       ~= ""
        local hasFaction = next(factionSet) ~= nil
        local hasZone    = next(zoneSet)    ~= nil
        local hasRep     = next(repSet)     ~= nil
        -- Item-intrinsic axes (source / expansion / preset) flow through the
        -- shared item predicate: a vendor passes if it sells >=1 catalog item
        -- matching ALL active ones. Makes Sources + Expansion + presets work in
        -- vendor mode with the same logic as Find-by-Item; achievement/quest
        -- presets correctly narrow to empty when no vendor sells such items.
        -- "recipes" preset filters at the VENDOR level (recipeCount), not via the
        -- item-source predicate -- handled separately in the loop below.
        local recipesPreset = (preset == "recipes")
        local hasItemFilter = (next(sourceSet) ~= nil) or (next(expSet) ~= nil)
            or (preset ~= nil and not recipesPreset)
            or (missingOnly and not recipesPreset)
        if not (hasSearch or hasFaction or hasZone or hasRep or hasItemFilter or recipesPreset) then
            return all
        end
        local itemPred = hasItemFilter
            and Selectors:Call("acq.matchesItemFilters", state, ctx) or nil
        local needle = hasSearch and q:lower() or nil

        local out = {}
        for _, v in ipairs(all) do
            local searchOK  = (not hasSearch)  or _vendorMatchesSearch(v, needle)
            local factionOK = (not hasFaction) or factionSet[v.faction] == true
            local zoneOK    = (not hasZone)    or zoneSet[v.zone] == true
            -- Rep set-intersect: vendor passes if its reps set contains ANY picked
            -- rep name (sells at least one item gated by one of the chosen reps).
            local repOK     = not hasRep
            if hasRep and v.reps then
                for r in pairs(repSet) do if v.reps[r] then repOK = true; break end end
            end
            local itemOK    = (not hasItemFilter) or _vendorSellsMatchingItem(v, itemPred)
            -- Rep preset also matches a vendor selling a rep-gated RECIPE (the
            -- catalog only knows rep-gated decor; recipe gates live in recipeSource).
            if not itemOK and preset == "reputation" and _vendorHasRepGatedRecipe(v.npcID) then
                itemOK = true
            end
            -- Recipes preset: "Missing" = sells an UNKNOWN recipe (item-based
            -- missing is bypassed for recipe vendors via hasItemFilter above).
            local recipeOK
            if not recipesPreset then
                recipeOK = true
            elseif missingOnly then
                recipeOK = _vendorHasUnknownRecipe(state, v.npcID)
            else
                recipeOK = v.recipeCount > 0
            end
            if searchOK and factionOK and zoneOK and repOK and itemOK and recipeOK then
                out[#out + 1] = v
            end
        end
        return out
    end,
})

-- Count label: "X vendors" / "X items"; "X of Y" when filtered.
-- Helper below: true only when vendor has >=1 catalog item AND all are collected.
local function vendorAllCollected(v, isColl)
    if not (v.name and isColl) then return false end
    local catalogVendor = _vendorEntry(v)
    if not (catalogVendor and catalogVendor.items and #catalogVendor.items > 0) then
        return false
    end
    for _, itemID in ipairs(catalogVendor.items) do
        if not isColl(itemID) then return false end
    end
    return true
end

-- acq.hasResults, blankVendor, blankItem: data-state gates.
-- Gated on catalog ready so cold load doesn't flash a premature "no match".
Selectors:Register("acq.hasResults", {
    memoized = true,  -- perf: visibility-bound, evaluated every flush
    -- Emptiness counts the filtered acq.vendors (1:1 with vendorRows) -- NOT
    -- acq.vendorRows, which shallow-copies + allCollected-stamps every vendor
    -- purely for presentation. vendorRows is built only by the visible list.
    calls = { "acq.isViewMode_vendor", "acq.vendors", "acq.items" },
    fn = function(state, ctx)
        if Selectors:Call("acq.isViewMode_vendor", state, ctx) then
            return #Selectors:Call("acq.vendors", state, ctx) > 0
        end
        return #Selectors:Call("acq.items", state, ctx) > 0
    end,
})
Selectors:Register("acq.blankVendor", {
    memoized = true,  -- perf: visibility-bound, evaluated every flush
    calls = { "acq.isViewMode_vendor", "acq.vendors", "catalog.isReady" },  -- count vendors, not the presentation rows
    fn = function(state, ctx)
        return Selectors:Call("acq.isViewMode_vendor", state, ctx)
            and Selectors:Call("catalog.isReady", state, ctx)
            and #Selectors:Call("acq.vendors", state, ctx) == 0 or false
    end,
})
Selectors:Register("acq.blankItem", {
    memoized = true,  -- perf: visibility-bound; counts the memoized acq.items
    calls = { "acq.isViewMode_item", "acq.items", "catalog.isReady" },
    fn = function(state, ctx)
        return Selectors:Call("acq.isViewMode_item", state, ctx)
            and Selectors:Call("catalog.isReady", state, ctx)
            and #Selectors:Call("acq.items", state, ctx) == 0 or false
    end,
})

Selectors:Register("acq.vendorRows", {
    memoized = true,  -- perf: 1.4ms walk; called by the list binding + hasResults + blankVendor
    reads = {"session.resolvers.catalog.tick"},
    calls = {"acq.vendors", "decor.isCollected"},
    fn = function(state, ctx)
        local vendors = Selectors:Call("acq.vendors",       state, ctx)
        local isColl  = Selectors:Call("decor.isCollected", state, ctx)
        local out = {}
        for _, v in ipairs(vendors) do
            -- Shallow-copy so we can stamp `allCollected` without
            -- mutating the memoized acq.vendors cache.
            local stamped = {}
            for k, val in pairs(v) do stamped[k] = val end
            stamped.allCollected = vendorAllCollected(v, isColl)
            out[#out + 1] = stamped
        end
        return out
    end,
})


-- "Map N Vendors" button label -- vendor-mode only; shows count of
-- waypointable vendors in the current filtered set.
Selectors:Register("acq.mapAllLabel", {
    calls = {"acq.vendors", "acq.viewMode"},
    fn = function(state, ctx)
        if Selectors:Call("acq.viewMode", state, ctx) ~= "vendor" then return "Map Vendors" end
        local vendors = Selectors:Call("acq.vendors", state, ctx)
        return string.format("Map %d Vendors", #vendors)
    end,
})

Selectors:Register("acq.countLabel", {
    calls = {"acq.viewMode", "acq.allItems", "acq.items", "acq.allVendors", "acq.vendors"},
    fn = function(state, ctx)
        local mode = Selectors:Call("acq.viewMode", state, ctx)
        local unit, total, visible
        if mode == "item" then
            unit    = "item"
            total   = #(Selectors:Call("acq.allItems", state, ctx))
            visible = #(Selectors:Call("acq.items",    state, ctx))
        else
            unit    = "vendor"
            total   = #(Selectors:Call("acq.allVendors", state, ctx))
            visible = #(Selectors:Call("acq.vendors",    state, ctx))
        end
        if total == 0 then return "no " .. unit .. "s" end
        if visible == total then
            return visible == 1 and ("1 " .. unit) or string.format("%d %ss", total, unit)
        end
        return string.format("%d of %d %ss", visible, total, unit)
    end,
})

-- Selected-vendor master selector. Reads npcID from session state,
-- looks up the matching record in allVendors. Returns nil if no
-- selection (or selection points at a missing vendor).
Selectors:Register("acq.selectedNpcID", {
    memoized = true,
    reads = {"session.ui.acquisition.selectedNpcID"},
    fn = function(state)
        local acq = state.session.ui.acquisition
        return acq.selectedNpcID or nil
    end,
})

Selectors:Register("acq.selectedVendor", {
    -- npcID-less vendors (catalog-only NPCs absent from VendorAugment, and
    -- synthetic "World Vendors" groupings) carry no npcID, so they resolve via
    -- the (name, zone) the row click stamps -- mirrors acq.selected.items.
    reads = {
        "session.ui.acquisition.selectedVendorName",
        "session.ui.acquisition.selectedVendorZone",
    },
    calls = {"acq.selectedNpcID", "acq.allVendors", "decor.isCollected"},
    fn = function(state, ctx)
        local id   = Selectors:Call("acq.selectedNpcID", state, ctx)
        local acq  = state.session.ui.acquisition
        local name, zone = acq.selectedVendorName, acq.selectedVendorZone
        if not id and not name then return nil end
        local all = Selectors:Call("acq.allVendors", state, ctx)
        for _, v in ipairs(all) do
            if (id and v.npcID == id)
            or (not id and v.name == name and (v.catalogZone or v.zone) == zone) then
                -- Shallow-copy and stamp allCollected. acq.allVendors is
                -- memoized so we can't mutate the cached row.
                local isColl  = Selectors:Call("decor.isCollected", state, ctx)
                local stamped = {}
                for k, val in pairs(v) do stamped[k] = val end
                stamped.allCollected = vendorAllCollected(v, isColl)
                return stamped
            end
        end
        return nil
    end,
})

-- Visibility gate for the action buttons (Waypoint /
-- Show on Map) -- hide when no vendor is selected so the action row
-- collapses to zero height.
Selectors:Register("acq.hasSelectedNpc", {
    calls = {"acq.selectedNpcID"},
    fn = function(state, ctx)
        return Selectors:Call("acq.selectedNpcID", state, ctx) ~= nil
    end,
})

-- Header wowhead button: the header link is a VENDOR link, so only show it in vendor
-- view. In by-item view the header is the item -- its wowhead lives in the body
-- (itemWowheadBtn); a vendor link there is wrong (esp. drop/quest items).
Selectors:Register("acq.showVendorWowhead", {
    calls = {"acq.isViewMode_vendor", "acq.hasSelectedNpc"},
    fn = function(state, ctx)
        return Selectors:Call("acq.isViewMode_vendor", state, ctx)
           and Selectors:Call("acq.hasSelectedNpc", state, ctx)
    end,
})


-- Header meta line: Zone . Faction . coords. Expansion was removed -- it
-- already lives in the panel header's expansion-badge slot
-- (acq.detailExpansion binding), so duplicating it here was clutter.
-- Coords render without parens for the cleaner look. "?" elided.
Selectors:Register("acq.selected.headerLine", {
    calls = {"acq.selectedVendor"},
    fn = function(state, ctx)
        local v = Selectors:Call("acq.selectedVendor", state, ctx)
        if not v then return "" end
        local parts = {}
        if v.zone    and v.zone    ~= "?" and v.zone    ~= "" then parts[#parts+1] = v.zone end
        if v.faction and v.faction ~= "?" and v.faction ~= "" then parts[#parts+1] = v.faction end
        if v.x and v.y and v.x > 0 and v.y > 0 then
            parts[#parts+1] = string.format("%.1f, %.1f", v.x, v.y)
        end
        if v.note and v.note ~= "" then parts[#parts+1] = v.note end
        return table.concat(parts, "  -  ")
    end,
})

-- Compact detail text for the action-column SELECTED block. Multi-line,
-- narrow-column friendly (action col is 150px wide). Each line projects a
-- single field from the catalog row (baked at BuildRow time) or a DecorFormat
-- helper for state-dependent rendering (collection counts flux at runtime).
-- Returns "" when nothing is selected so the parent visibility-gate collapses.
--
-- Reads account.config.scheme so the dim-wrap color codes refresh on scheme
-- swap. staticData.tick covers ItemAugment lookups inside the row bake (gate
-- factionID resolution).
Selectors:Register("acq.selectedItem.compactDetail", {
    calls = {"acq.selectedItemID", "decor.isCollected", "acq.selectedRecipe"},
    -- quest/ach/rep ticks (+ questCompletions): the gate line is met-aware (green check
    -- when satisfied, dim when not) -- it refreshes when completion or rep changes.
    reads = {"account.config.scheme", "session.resolvers.staticData.tick",
             "session.resolvers.catalog.tick", "session.resolvers.rep.tick",
             "session.resolvers.questStatus.tick", "session.resolvers.achievementStatus.tick", "account.questCompletions"},
    fn = function(state, ctx)
        local dimCC  = HDG.Theme:ColorCode("text.dim")
        local textCC = HDG.Theme:ColorCode("text.primary")

        -- Recipe selection: show the RECIPE facts (known / cost / rep / profession),
        -- NOT the crafted item's "Cost: free / Collected" -- those belong to the
        -- decor item, which is listed separately under the Crafted source.
        local recipe = Selectors:Call("acq.selectedRecipe", state, ctx)
        if recipe then
            local rlines = {}
            if recipe.teaches then
                rlines[#rlines + 1] = dimCC .. "Teaches: |r" .. textCC .. recipe.teaches .. "|r"
            end
            rlines[#rlines + 1] = recipe.isKnown and (textCC .. "Recipe known|r")
                                                  or  (dimCC .. "Recipe not known|r")
            if recipe.costText ~= "" then
                rlines[#rlines + 1] = dimCC .. "Cost: |r" .. recipe.costText
            end
            if recipe.factionID and recipe.factionID > 0 then
                local fac  = HDG.Constants.REP_FACTIONS[recipe.factionID]
                local name = (fac and fac.name) or "this faction"
                local reqStr = name
                if fac and fac.friendship then
                    -- Friendship reps (Silvermoon Court subsidiaries) progress by
                    -- named ranks, not Renown -- don't fabricate a Renown number.
                    reqStr = name .. " reputation"
                elseif recipe.minRep and recipe.minRep >= 9 then
                    reqStr = name .. " Renown " .. (recipe.minRep - 8)
                end
                -- Live met-check via RepObserver (renown + friendship); reads
                -- session.resolvers.rep.tick so it refreshes when the player's rep changes.
                local prog = HDG.RepObserver:GetProgress(recipe.factionID, recipe.minRep)
                if prog and prog.met then
                    rlines[#rlines + 1] = HDG.Theme:GetTextStateColorToken("collected")
                        .. "|A:common-icon-checkmark:12:12|a Requires " .. reqStr .. "|r"
                else
                    rlines[#rlines + 1] = dimCC .. "Requires " .. reqStr .. "|r"
                end
            end
            if recipe.profession then
                rlines[#rlines + 1] = textCC .. recipe.profession .. "|r"
            end
            -- "Where" lives in the reused "Available from" vendor list below
            -- (acq.selectedItem.vendors is recipe-aware) -- with Wpt/Map per vendor.
            return table.concat(rlines, "\n")
        end

        local id = Selectors:Call("acq.selectedItemID", state, ctx)
        if not id then return "" end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row then return "" end

        local F      = HDG.DecorFormat

        local lines = {}
        -- Cost line: show every payment option (an item buyable for 30 coupons
        -- OR 500g shows both). costVariants is >=1 entry when there's any cost.
        local cv   = row.costVariants
        local cost = (cv and #cv > 0) and table.concat(cv, "  or  ")
                  or (row.costLine ~= "" and row.costLine or (dimCC .. "free|r"))
        lines[#lines+1] = dimCC .. "Cost: |r" .. cost
        -- Collection status (counts flux at runtime; helper reads live row).
        lines[#lines+1] = F:Collection(row)
        -- Placement (icon + label both baked).
        if row.placementLabel ~= "" then
            lines[#lines+1] = textCC .. row.placementLabel .. "|r"
        end
        -- Optional gate line -- MET-AWARE for the primary gate (sourceTags[1]): green
        -- checkmark + bright when satisfied, dim when not. Mirrors the recipe path + the
        -- row-list chip dimming. boundary: IsComplete/IsEarned/GetProgress gated by the
        -- quest/ach/rep ticks in this selector's reads.
        if row.gateLine then
            local g, met = row.sourceTags and row.sourceTags[1], nil
            if g then
                if g.kind == "QUEST" and row.questID then
                    met = _recordedCompletion(state, row.questID) ~= nil
                       or HDG.QuestNameResolver:IsComplete(row.questID) == true
                elseif g.kind == "ACH" and row.achievementID then
                    met = HDG.AchievementObserver:IsEarned(row.achievementID) == true
                elseif g.kind == "REP" and g.factionID and g.requiredCode then
                    local prog = HDG.RepObserver:GetProgress(g.factionID, g.requiredCode)
                    met = (prog and prog.met) == true
                end
            end
            if met == true then
                lines[#lines+1] = HDG.Theme:GetTextStateColorToken("collected")
                    .. "|A:common-icon-checkmark:12:12|a " .. row.gateLine .. "|r"
            else
                lines[#lines+1] = dimCC .. row.gateLine .. "|r"
            end
        end
        return table.concat(lines, "\n")
    end,
})


-- Items grid vs list view-mode. Grid (default) = cardGrid icons.
-- List = scrollbox rows showing icon + name + full cost (gold + every
-- currency cost segment). Multi-currency items only render their full
-- cost in list mode.
Selectors:Register("acq.itemsViewMode", {
    reads = {"account.ui.acquisition.itemsViewMode"},
    fn = function(state)
        local ui = state.account.ui.acquisition
        return ui.itemsViewMode or "grid"
    end,
})
Selectors:Register("acq.isItemsView_grid", {
    calls = {"acq.itemsViewMode", "acq.hasRecipes"},
    fn = function(state, ctx)
        -- Recipes render only as rows, so a recipe-selling vendor forces LIST.
        -- Transient override -- the persisted grid/list preference is untouched
        -- and restores when a non-recipe vendor is selected.
        if Selectors:Call("acq.hasRecipes", state, ctx) then return false end
        return Selectors:Call("acq.itemsViewMode", state, ctx) == "grid"
    end,
})
Selectors:Register("acq.isItemsView_list", {
    calls = {"acq.itemsViewMode", "acq.hasRecipes"},
    fn = function(state, ctx)
        if Selectors:Call("acq.hasRecipes", state, ctx) then return true end
        return Selectors:Call("acq.itemsViewMode", state, ctx) == "list"
    end,
})

-- ===== Item-view selectors =====================================
-- Vendors that sell the selected item. Sources: catalog observer (vendor
-- names/zones from sourceText) + VendorAugment (coords/npcID). Cost is a
-- text string from sourceText; integer goldCost not available (VendorDB retired).
-- Recipe-aware: when a recipe scroll is selected (Find Decor recipes view), the
-- "Available from" list shows the vendor(s) that sell the SCROLL -- reusing the
-- decor-item vendor row (name/zone/cost + Wpt/Map) so where + waypoint come for
-- free. Rows carry VendorAugment coords (zone-pct) the Wpt/Map buttons consume.
local function _recipeVendorRows(itemID)
    local entry = HDG.StaticData.Recipes:Get(itemID)
    local rs    = entry and entry.recipeSource
    if not (rs and rs.vendors) then return {} end
    local out = {}
    for _, v in ipairs(rs.vendors) do
        local meta = HDG.StaticData.VendorAugment:Get(v.npcID)  -- exception(boundary): generated augment
        out[#out + 1] = {
            costLine   = HDG.Format.FormatVendorCost(v.cost),
            npcID      = v.npcID,
            name       = (meta and meta.name) or ("NPC " .. tostring(v.npcID)),  -- exception(boundary): augment gap
            zone       = (meta and meta.zone) or "",
            mapID      = meta and meta.mapID,
            x          = meta and meta.x,
            y          = meta and meta.y,
            faction    = (meta and meta.faction) or "",
            factionRaw = (meta and meta.faction) or "",
            expansion  = meta and meta.exp,
            costText   = "",
            goldCost   = 0,
            factionID  = v.factionID or 0,
            minRep     = v.minRep or 0,
            repName    = "",
        }
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

Selectors:Register("acq.selectedItem.vendors", {
    reads = {"session.resolvers.staticData.tick", "session.resolvers.catalog.tick"},
    calls = {"acq.selectedItemID", "acq.selectedRecipe"},
    fn = function(state, ctx)
        -- Recipe scroll selected -> its vendors (reuses the same row shape).
        local recipe = Selectors:Call("acq.selectedRecipe", state, ctx)
        if recipe then return _recipeVendorRows(recipe.itemID) end
        local itemID = Selectors:Call("acq.selectedItemID", state, ctx)
        if not itemID then return {} end
        local row = HDG.HousingCatalogObserver:GetRow(itemID)
        if not (row and row.vendors) then return {} end
        local aug = HDG.StaticData.ItemAugment:Get(itemID)
        local out  = {}
        local seen = {}   -- npcID -> out index (de-dupe multi-zone vendor dups)
        for _, v in ipairs(row.vendors) do
            local npcID = HDG.StaticData.VendorAugment:ResolveName(v.name, v.zone)
            local meta  = npcID and HDG.StaticData.VendorAugment:Get(npcID)
            local factionID = (aug and aug.factionID) or 0
            local minRep    = (aug and aug.minRep) or 0
            local repName   = (aug and aug.factionName)
                           or (row.factionGate and row.factionGate.factionName) or ""
            local newRow = {
                costLine   = row.costLine,  -- baked cost line for the vendor meta row (cost - zone - faction)
                npcID      = npcID,
                name       = v.name,
                zone       = v.zone or (meta and meta.zone) or "",
                mapID      = meta and meta.mapID,
                x          = meta and meta.x,
                y          = meta and meta.y,
                faction    = v.faction or (meta and meta.faction) or "",
                factionRaw = v.faction or "",
                expansion  = meta and meta.exp,
                costText   = v.cost or "",  -- catalog text (no integer gold available)
                goldCost   = 0,
                factionID  = factionID,
                minRep     = minRep,
                repName    = repName,
                currCost   = nil,   -- DEFERRED: CostAugment (no integer cost yet)
                questID    = 0,
                achieveID  = 0,     -- DEFERRED: CostAugment
            }
            -- De-dupe by npcID. The catalog sometimes lists ONE vendor under two
            -- zone strings (e.g. Gina Mudclaw under "Valley of the Four Winds" +
            -- "Timeless Isle"; only Valley is real) -> two rows with the same key
            -- "ivr_<npcID>" -> Bind-stage key collision. Mirrors acq.allVendors:
            -- keep the row whose zone IS the resolved (meta) location, drop the phantom.
            local prev = npcID and seen[npcID]
            if prev then
                local metaZone = meta and meta.zone
                if metaZone and v.zone == metaZone and out[prev].zone ~= metaZone then
                    out[prev] = newRow
                end
            else
                out[#out + 1] = newRow
                if npcID then seen[npcID] = #out end
            end
        end
        table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
        return out
    end,
})

-- Header above the vendor-list scrollbox. PURE vendor count: "Available
-- from (N)" or "" when no vendors (lets the visibility-binding collapse
-- the entire section). Source / gate info lives in the item detail ribbon
-- (shortRibbonText), NOT here -- this header is semantically the vendor
-- list header, not a fallback "where do I get it" label.
Selectors:Register("acq.selectedItem.availableFromLabel", {
    calls = {"acq.selectedItem.vendors"},
    fn = function(state, ctx)
        -- Count off the (recipe-aware) vendor list so recipes + items share one path.
        local vendors = Selectors:Call("acq.selectedItem.vendors", state, ctx)
        if #vendors == 0 then return "" end
        return string.format("Available from (%d)", #vendors)
    end,
})

-- Source-line chip+detail per applicable kind. One line per row.gates entry.
-- Chip color + 4-char label looked up via SOURCE_KIND_BY_KEY[g.kind].
-- Every gate carries .text (baked at BuildRow); [ACH] is the only kind with
-- special render (clickable hdgrach: hyperlink to AchievementFrame via
-- controller hook).
local function _chipText(key)
    -- Delegate to the canonical chip renderer (DRY). Was a duplicate
    -- reimplementation that skipped math.floor on the color bytes -- which
    -- errors under Lua 5.4 (%02x on a float) and drifts by 1 unit otherwise.
    return HDG.Format.SourceChip(key)
end

-- Pure projection of row.sourceTags -- single source of truth for the
-- detail panel's source/gate display. Two render modes share one iteration:
--   * tag has .text -> one line: "[CHIP]  text" (gated kinds: REP, ACH,
--                       QUEST, CRAFT-with-recipe-expansion)
--   * tag has no .text -> chip appended to a single inline strip line
--                       (DROP, VENDOR, PROMO, etc.)
-- The strip line (if any chip-only tags exist) lands at the bottom so
-- gated text-bearing entries stay legible at the top of the widget.
-- [ACH] chip wrapped in a custom hdgrach: hyperlink (payload = itemID; click +
-- hover handlers read achievementID / name off the same row). Earned -> append
-- a live checkmark (AchievementObserver, gated by achievementStatus.tick).
local function _buildAchSourceLine(id, prefix, chip, t, row)
    -- LINK ONLY WHEN THERE IS AN ID TO OPEN. The catalog's "Achievement:" line
    -- gives a NAME and never an achievementID (_bakeItemAugmentBackfill says so:
    -- ItemAugment is the sole ID source), so a row backed only by catalog text
    -- has nothing to click through to. The click handler already returns early
    -- on the missing ID -- silently -- so linking anyway offered a highlight and
    -- a "Click to open Achievement window" tooltip for a click that could never
    -- work (Preyhunter's Terror Effigy, reported 2026-08-31). Unlinked, it is
    -- still named; it just stops promising.
    local body = row.achievementID
        and string.format("|cffffff00|Hhdgrach:%d|h[%s]|h|r", id, t.text)
        or  string.format("[%s]", t.text)
    local line = string.format("%s%s  %s", prefix, chip, body)
    if row.achievementID and HDG.AchievementObserver:IsEarned(row.achievementID) then
        line = line .. "  |A:common-icon-checkmark:14:14|a"
    end
    return line
end

-- Static "<chip>  <requirement>" plus any LIVE suffix:
--   REP   -> "ready/not-ready <standing> (X/Y)" via RepObserver (rep.tick).
--   QUEST -> checkmark + completing character (class-colored) on completion.
--            Account-wide (account.questCompletions, first char wins) so alts
--            see ticks; bare-tick fallback for an un-persisted current-char one.
local function _buildGateSourceLine(state, prefix, chip, t, row)
    local line = prefix .. chip .. "  " .. t.text
    if t.kind == "REP" and t.factionID then
        local suffix = HDG.Format.ComposeRepProgressSuffix(
            HDG.RepObserver:GetProgress(t.factionID, t.requiredCode))
        if suffix then line = line .. "  " .. suffix end
    end
    if t.kind == "QUEST" and row.questID then
        local rec, live = _questCompletion(state, row.questID)
        if rec then
            line = line .. "  |A:common-icon-checkmark:14:14|a "
                .. HDG.Format.ClassColorName(rec.name, rec.class)
        elseif live then
            line = line .. "  |A:common-icon-checkmark:14:14|a"
        end
    end
    return line
end

Selectors:Register("acq.selectedItem.sourceLine", {
    -- session.resolvers.rep.tick: RepObserver bumps it on rep change so the REP gate's
    -- LIVE progress suffix (composed below) re-reads. Static gate text is baked.
    reads = {"session.resolvers.staticData.tick", "session.resolvers.catalog.tick", "session.resolvers.rep.tick", "session.resolvers.questStatus.tick", "session.resolvers.achievementStatus.tick", "account.questCompletions"},
    calls = {"acq.selectedItemID"},
    fn = function(state, ctx)
        local id = Selectors:Call("acq.selectedItemID", state, ctx)
        if not id then return "" end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row or not row.sourceTags then return "" end
        local lines, strip = {}, {}
        for _, t in ipairs(row.sourceTags) do
            local chip   = _chipText(t.kind)
            local prefix = t.factionPrefix and (t.factionPrefix .. " ") or ""
            if t.text and t.kind == "ACH" then
                lines[#lines+1] = _buildAchSourceLine(id, prefix, chip, t, row)
            elseif t.text then
                lines[#lines+1] = _buildGateSourceLine(state, prefix, chip, t, row)
            elseif t.kind ~= "VENDOR" then
                -- VENDOR chip suppressed in the detail panel -- item-view-only,
                -- and the "Available from (N)" vendor list below already names
                -- every vendor, so [VEND] is pure redundancy here. (Row-list
                -- chips keep it -- they render via UI.GateChips, not this selector.)
                strip[#strip+1] = prefix .. chip
            end
        end
        if #strip > 0 then lines[#lines+1] = table.concat(strip, " ") end
        return table.concat(lines, "\n")
    end,
})

-- Item Detail ribbon. Item-level facts only: Cost / Stored-Placed /
-- Placement. Source/gate info lives in the dedicated sourceLine widget
-- which projects row.gates (chips + text) or row.sourceFlags (chips
-- only) -- single render path for every kind. Cost/Placement decoration
-- (coin atlas, budget icon) is baked at BuildRow.
Selectors:Register("acq.selectedItem.shortRibbonText", {
    calls = {"acq.selectedItemID"},
    reads = {"session.resolvers.catalog.tick"},
    fn = function(state, ctx)
        local id = Selectors:Call("acq.selectedItemID", state, ctx)
        if not id then return "" end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row then return "" end
        local cv = row.costVariants
        local costStr = (cv and #cv > 0) and table.concat(cv, "  or  ")
                     or (row.costLine ~= "" and row.costLine or "-")
        return table.concat({
            "Cost: " .. costStr,
            string.format("Stored: %d  -  Placed: %d", row.quantity or 0, row.numPlaced or 0),  -- exception(boundary): catalog struct field sparse
            row.placementLabel,
        }, "\n")
    end,
})

-- Item Wowhead URL (mirrors vendor pattern; utm_source=hdg).
Selectors:Register("acq.selectedItem.wowheadUrl", {
    calls = {"acq.selectedItemID"},
    fn = function(state, ctx)
        local id = Selectors:Call("acq.selectedItemID", state, ctx)
        if not id then return "" end
        return "https://www.wowhead.com/item=" .. tostring(id) .. "?utm_source=hdg"
    end,
})

-- Wowhead URL composition. Matches HDG's WH_BASE + utm_source
-- pattern so referrers track back to the addon family.
Selectors:Register("acq.selected.wowheadUrl", {
    calls = {"acq.selectedNpcID"},
    fn = function(state, ctx)
        local id = Selectors:Call("acq.selectedNpcID", state, ctx)
        if not id then return "" end
        return "https://www.wowhead.com/npc=" .. tostring(id) .. "?utm_source=hdg"
    end,
})

-- CardGrid items: all items sold by the selected vendor, shaped
-- for acqVendorItemTile rendering. Sort puts uncollected tiles first,
-- then collected, alphabetical within each group. Catalog enrichment is
-- best-effort -- when catRow is nil (item not in catalog cache yet), the
-- tile still renders with name+cost; icon falls back to "?" via
-- CardGrid:PaintIcon's missing-texture branch.
--
-- Memoized: 4+ consumers fire on the same dispatch (acq.detailTitle,
-- acq.runSummary.text, items tile/list bindings). Cache invalidates on
-- selectedNpcID change + collection ownership + live-set + catalog
-- updates via the calls-chain reads closure.
-- One by-vendor item row: catalog facts + gate-met chip-dim stamps
-- (questDone/achEarned account-wide; repMet live via the REP sourceTag). Cost
-- is text-only (catalog sourceText; VendorDB retired). Rep name from
-- ItemAugment, supplemented by the catalog factionGate when the augment is
-- silent. exception(boundary): IsComplete/IsEarned/GetProgress gated by the
-- questStatus/achievementStatus/rep ticks in the selector's reads.
local function _buildSelectedVendorItem(state, itemID, catRow, isColl)
    local aug       = HDG.StaticData.ItemAugment:Get(itemID)
    local factionID = aug and aug.factionID or 0
    local minRep    = aug and aug.minRep    or 0
    local repName   = aug and aug.factionName or ""
    local gate = catRow.factionGate
    if gate and gate.factionName and gate.factionName ~= "" and repName == "" then
        repName = gate.factionName
    end
    local iconTex, iconAtl = HDG.Format.CoerceIconPair(catRow.iconTexture, catRow.iconAtlas)
    local firstVendor = catRow.vendors and catRow.vendors[1]  -- exception(nullable): vendors absent on drop-only rows
    local costText = (firstVendor and firstVendor.cost) or ""

    local questDone, achEarned = nil, nil
    if catRow.questID then
        questDone = _recordedCompletion(state, catRow.questID) ~= nil
            or HDG.QuestNameResolver:IsComplete(catRow.questID) == true
    end
    if catRow.achievementID then
        achEarned = HDG.AchievementObserver:IsEarned(catRow.achievementID) == true
    end

    return {
        questDone         = questDone,
        achEarned         = achEarned,
        repMet            = _repMetForRow(catRow),
        kind              = "item",
        itemID            = itemID,
        name              = catRow.name or "Unknown",
        isCollected       = isColl and isColl(itemID) or false,
        numStored         = catRow.quantity or 0,
        numPlaced         = 0,  -- placement count not in catalog
        costText          = costText,  -- text only; integer unavailable
        costLine          = catRow.costLine,  -- baked cost line (icons); single-option fallback for costLineVariant
        costVariants      = catRow.costVariants,  -- per-payment-option lines (listRows expands)
        factionID         = factionID,
        minRep            = minRep,
        repName           = repName,
        currCost          = nil,  -- DEFERRED: CostAugment (no integer cost yet)
        questID           = 0,    -- default; real questIDs flow from ItemAugment sources
        achieveID         = 0,    -- DEFERRED: CostAugment
        iconTexture       = iconTex,
        iconAtlas         = iconAtl,
        isAllowedIndoors  = catRow.isAllowedIndoors,
        isAllowedOutdoors = catRow.isAllowedOutdoors,
    }
end

Selectors:Register("acq.selected.items", {
    memoized = true,
    calls = {"decor.isCollected", "acq.selectedVendor"},
    reads = {
        "session.resolvers.staticData.tick",  -- ADR-003c StaticData marker (sweep rule 4c)
        "session.resolvers.catalog.tick",
        -- gate-met chip-dim signals (questDone/achEarned/repMet stamped per item below)
        "session.resolvers.questStatus.tick", "session.resolvers.achievementStatus.tick",
        "account.questCompletions", "session.resolvers.rep.tick",
    },
    fn = function(state, ctx)
        -- ONE identity rule for the selected vendor: acq.selectedVendor resolves
        -- npcID first, then the (name, zone) a row click stamps for npcID-less
        -- vendors. This selector used to read the stamps directly, so a jump
        -- from another window -- which carries the npcID and no zone -- painted
        -- the vendor's header but an empty goods list until the row was clicked
        -- by hand (Vamoose, 2026-09-11). byVendor is keyed by (name, catalogZone):
        -- the catalog's zone string, which can diverge from VendorAugment.zone
        -- (catalog ships parent map names like "Zuldazar" where VendorAugment
        -- has the city "Dazar'alor"), so the key comes from the resolved record,
        -- never from the augment.
        local vendor = Selectors:Call("acq.selectedVendor", state, ctx)
        if not vendor then return {} end  -- exception(nullable): nothing selected yet
        local vendorEntry = HDG.HousingCatalogObserver:GetItemsByVendor(vendor.name, vendor.catalogZone or vendor.zone)
        if not vendorEntry then return {} end  -- exception(nullable): catalog-only vendor whose bucket the observer has not baked yet
        local isColl = Selectors:Call("decor.isCollected", state, ctx)
        local out = {}
        for _, itemID in ipairs(vendorEntry.items) do
            local catRow = HDG.HousingCatalogObserver.byItemID[itemID]
            -- exception(nullable): byVendor items are added from rows already in
            -- byItemID within the same atomic sweep commit, so a miss is impossible
            -- by construction -- silent skip keeps this selector pure.
            if catRow then
                out[#out + 1] = _buildSelectedVendorItem(state, itemID, catRow, isColl)
            end
        end
        table.sort(out, function(a, b)
            if a.isCollected ~= b.isCollected then
                return not a.isCollected   -- uncollected first
            end
            if a.name == b.name then return a.itemID < b.itemID end
            return a.name < b.name
        end)
        return out
    end,
})

-- Recipes the SELECTED vendor sells (Acquire By-Vendor). The catalog can't
-- surface recipe purchases, so this reads the StaticData reverse index over
-- recipeSource.vendors + account.recipes for known-state. One row per recipe
-- sold by selectedNpcID; cost/rep come from THIS vendor's recipeSource.vendors[]
-- record (a recipe sold by 2 vendors thus appears under each -- the 41-vs-31 split).
Selectors:Register("acq.selected.recipes", {
    memoized = true,
    reads = {
        "session.resolvers.staticData.tick",  -- ADR-003c StaticData marker (sweep rule 4c)
        "session.ui.acquisition.selectedNpcID",
        "account.recipes",
    },
    fn = function(state)
        local npcID = state.session.ui.acquisition.selectedNpcID
        if not npcID then return {} end
        local entries = HDG.StaticData.Recipes:GetBySourceNpcID(npcID)
        if not entries then return {} end
        local out = {}
        for _, entry in ipairs(entries) do
            -- This vendor's own record (cost/rep). Guaranteed present: the index
            -- is built FROM vendors[].npcID, so the matching record always exists.
            local vrec
            for _, v in ipairs(entry.recipeSource.vendors) do
                if v.npcID == npcID then vrec = v; break end
            end
            -- account.recipes is sparse until RecipeKnowledgeScanner runs
            -- (DECOR_CATALOG_READY); absent entry => not-yet-known.
            local rk = state.account.recipes[entry.itemID]
            -- exception(nullable): impossible by construction (the byNpc index is
            -- built FROM vendors[].npcID); the skip stays so a data-export gap can't
            -- crash this memoized selector on FormatVendorCost. Selectors don't log.
            if vrec then
                out[#out + 1] = {
                    kind       = "recipe",
                    itemID     = entry.itemID,
                    name       = "Recipe: " .. entry.name,
                    profession = entry.profession,
                    professionAtlas = HDG.Format.ProfessionAtlas(entry.profession),  -- resolved here, not at paint

                    isKnown    = rk ~= nil and (rk.selfKnown or rk.altKnown) or false,
                    costText   = HDG.Format.FormatVendorCost(vrec.cost),
                    factionID  = vrec.factionID,
                    minRep     = vrec.minRep,
                }
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end,
})

-- Visibility gate for the recipe-rows section (true when the selected vendor
-- sells >= 1 recipe). Composes acq.selected.recipes so it shares its memo.
Selectors:Register("acq.hasRecipes", {
    calls = {"acq.selected.recipes"},
    fn = function(state, ctx)
        return #Selectors:Call("acq.selected.recipes", state, ctx) > 0
    end,
})

-- Vendor detail LIST view: items (kind="item") then recipe rows (kind="recipe").
-- The cardGrid stays items-only (acq.selected.items); only this list interleaves
-- recipes. Each source selector tags its own envelopes with `kind`, so this just
-- concatenates -- no mutation of the memoized source results.
Selectors:Register("acq.selected.listRows", {
    memoized = true,
    calls = {"acq.selected.items", "acq.selected.recipes"},
    fn = function(state, ctx)
        local items   = Selectors:Call("acq.selected.items",   state, ctx)
        local recipes = Selectors:Call("acq.selected.recipes", state, ctx)
        -- An item buyable two ways (30 Community Coupons OR 500g) lists once per
        -- payment option here; the cardGrid stays one-tile-per-item (no cost on
        -- tiles, so a dup tile would be indistinguishable).
        local hasMultiCost = false
        for _, it in ipairs(items) do
            if it.costVariants and #it.costVariants > 1 then hasMultiCost = true break end
        end
        if #recipes == 0 and not hasMultiCost then return items end
        local out = {}
        for _, it in ipairs(items) do
            local variants = it.costVariants
            if variants and #variants > 1 then
                -- Shallow-copy per option (do NOT mutate the memoized source row);
                -- costLineVariant tells the row paint to show THIS option's cost.
                for i, line in ipairs(variants) do
                    local copy = {}
                    for k, v in pairs(it) do copy[k] = v end
                    copy.costLineVariant = line
                    copy.variantIndex    = i  -- keeps scrollbox row keys unique
                    out[#out + 1] = copy
                end
            else
                out[#out + 1] = it
            end
        end
        for _, r in ipairs(recipes) do out[#out + 1] = r end
        return out
    end,
})

-- A recipe row sets selectedRecipeItemID (alongside selectedItemID for the
-- model/name); clicking a decor item clears it. Non-nil => the detail pane
-- shows the RECIPE (known/cost/rep), not the crafted item's collected/free state.
Selectors:Register("acq.selectedRecipeItemID", {
    reads = {"session.ui.acquisition.selectedRecipeItemID"},
    fn = function(state)
        return state.session.ui.acquisition.selectedRecipeItemID
    end,
})

-- The selected recipe's envelope, found in the active vendor's recipe list (so
-- cost/rep are this vendor's). nil unless a recipe row is the active selection.
Selectors:Register("acq.selectedRecipe", {
    calls = {"acq.selectedRecipeItemID", "acq.selected.recipes", "acq.allRecipes",
             "acq.isViewMode_item_recipes"},
    fn = function(state, ctx)
        local id = Selectors:Call("acq.selectedRecipeItemID", state, ctx)
        if not id then return nil end
        for _, r in ipairs(Selectors:Call("acq.selected.recipes", state, ctx)) do
            if r.itemID == id then return r end
        end
        -- Find Decor recipes view (no selected vendor): resolve from the flat
        -- scroll list. Gated to that view so a stale selectedRecipeItemID can't
        -- leak recipe facts onto a decor item picked in the normal item list.
        if Selectors:Call("acq.isViewMode_item_recipes", state, ctx) then
            for _, r in ipairs(Selectors:Call("acq.allRecipes", state, ctx)) do
                if r.itemID == id then return r end
            end
        end
        return nil
    end,
})

-- Map drawer: condensed shape for the vendorMap widget.
-- Returns { mapID, x, y, name, zone } or { mapID, name, zone, noPin } or nil.
-- x/y are 0-1 fractions (VendorDB stores percent 0-100, normalized here).
-- Un-augmented vendors (12.0.7 additions the augment doesn't cover yet) have
-- only the catalog's zone STRING -- resolve it to a uiMapID and draw the zone
-- pinless rather than showing nothing. ZoneNameResolver is a deterministic
-- static facade (Recipes:RecipeVendorCounts precedent).
Selectors:Register("acq.selected.mapPoint", {
    calls = {"acq.selectedVendor"},
    fn = function(state, ctx)
        local v = Selectors:Call("acq.selectedVendor", state, ctx)
        if not v then return nil end  -- exception(nullable): nothing selected
        if v.mapID and v.mapID ~= 0 then
            return {
                mapID = v.mapID,
                x     = (v.x or 0) / 100,
                y     = (v.y or 0) / 100,
                name  = v.name,
                zone  = v.zone,
            }
        end
        local zoneMapID = HDG.ZoneNameResolver:MapIDForName(v.zone)
        if not zoneMapID then return nil end  -- exception(nullable): sub-zone strings have no uiMap
        return { mapID = zoneMapID, name = v.name, zone = v.zone, noPin = true }
    end,
})

-- Visibility gate for the 3D model preview slot. True
-- whenever an item is picked (either via Find by Item, by expanding a
-- vendor row, or by clicking a tile in the Also sells grid). Lets the
-- preview slot show in vendor view too once an item has context.
Selectors:Register("acq.hasSelectedItem", {
    calls = {"acq.selectedItemID"},
    fn = function(state, ctx)
        return Selectors:Call("acq.selectedItemID", state, ctx) ~= nil
    end,
})

-- Vendor note text. Empty string when no note set, so the
-- editbox binding renders the placeholder. Read keyed by the current
-- selectedNpcID, not selectedVendor -- avoids re-resolving allVendors
-- when only the note text changes.
Selectors:Register("acq.selected.note", {
    calls = {"acq.selectedNpcID"},
    reads = {"account.vendorNotes"},
    fn = function(state, ctx)
        local id = Selectors:Call("acq.selectedNpcID", state, ctx)
        if not id then return "" end
        local notes = state.account.vendorNotes
        local n = notes[id]
        return (n and n.text) or ""
    end,
})

-- ===== Item-side detail =====================================================
-- Mirror of the vendor-side selectors but reading from selectedItemID +
-- HDGR_DecorDB. Used by the by-item detail section. Returns placeholders
-- when no item selected (mirrors vendor-side "Click a vendor" pattern).

Selectors:Register("acq.selectedItemID", {
    memoized = true,
    reads = {"session.ui.acquisition.selectedItemID"},
    fn = function(state)
        local acq = state.session.ui.acquisition
        return acq.selectedItemID or nil
    end,
})


Selectors:Register("acq.selectedItem", {
    memoized = true,
    reads = {"session.resolvers.catalog.tick", "session.ui.acquisition.selectedItemID"},
    fn = function(state)
        local id = state.session.ui.acquisition.selectedItemID
        if not id then return nil end
        local row = HDG.HousingCatalogObserver:GetRow(id)
        if not row then return nil end

        -- vendors[] enrichment + rep-gate baked at BuildRow (_bakeVendors
        -- adds npcID/mapID/x/y/canWaypoint; faction normalized to A/H/N).
        -- Rep-gate stamped per-vendor from row.sourceTags (when applicable)
        -- so the envelope mirrors what acq.selected.items would produce.
        local repGate
        if row.sourceTags then
            for _, t in ipairs(row.sourceTags) do
                if t.kind == "REP" then
                    repGate = { factionID   = t.factionID,
                                factionName = t.factionName,
                                standing    = t.standing,
                                minRep      = t.minRep }
                    break
                end
            end
        end
        local vendors = {}
        for _, v in ipairs(row.vendors) do
            vendors[#vendors+1] = {
                name        = v.name,
                zone        = v.zone,
                cost        = v.cost,
                npcID       = v.npcID,
                mapID       = v.mapID,
                x           = v.x, y = v.y,
                faction     = v.faction or "N",
                gate        = repGate,           -- item-level rep gate (shared across vendors)
                canWaypoint = v.canWaypoint,
            }
        end

        return {
            itemID        = id,
            name          = row.name,
            iconTexture   = row.iconTexture,
            expansion     = row.expansion,
            quality       = row.quality,
            placementCost = row.placementCost,
            indoor        = row.isAllowedIndoors,
            outdoor       = row.isAllowedOutdoors,
            -- isOwned via canonical helper; project as both names for
            -- backward-compat with consumers (acq.detailTitle, compactDetail
            -- still read isCollected; row factories still read collected).
            collected     = HDG.HousingCatalogObserver:IsOwned(row),
            isCollected   = HDG.HousingCatalogObserver:IsOwned(row),
            sourceType    = row.sourceType,  -- baked at BuildRow (_bakeSourceTypes)
            sourceName    = row.sourceName,  -- baked at BuildRow (_bakeSourceTypes)
            vendors       = vendors,
        }
    end,
})

-- Selected item's display name. Wraps in the "collected" color token when
-- isCollected so the SELECTED block's name matches the row factory's
-- green-name treatment (rows in the items list use the same wrap). reads
-- account.config.scheme so the baked color refreshes on scheme swap.
Selectors:Register("acq.selectedItem.name", {
    reads = {"account.config.scheme"},
    calls = {"acq.selectedItem", "acq.selectedRecipe"},
    fn = function(state, ctx)
        -- Recipe scroll selected -> "Recipe: <name>" (known -> collected color).
        local recipe = Selectors:Call("acq.selectedRecipe", state, ctx)
        if recipe then return HDG.Theme:CollectionLabel(recipe.isKnown, recipe.name) end
        local v = Selectors:Call("acq.selectedItem", state, ctx)
        if not v then return "Click an item" end
        return HDG.Theme:CollectionLabel(v.isCollected, v.name)
    end,
})

-- (acq.previewInfo removed -- selectors stay pure. The modelPreview
--  widget binds directly to acq.selectedItemID and its dispatcher
--  calls HDG.HousingCatalogObserver:Resolve at refresh time. Side effects
--  live at the UI seam, not in selectors.)


-- ============================================================================
