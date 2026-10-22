-- HDG.Selectors -- Recipes tab + Warehouse sub-view
-- ============================================================================
-- recipes.*: master list, queue, materials projections (Direct/Raw/Grouped).
-- warehouse.*: lumber stocks, all materials, used-in panel.

HDG = HDG or {}
local Selectors = HDG.Selectors

-- Selectors are pure (ADR-003). Recipe DB reads use the ADR-003a
-- deterministic-module-read carve-out (post-init, idempotent, non-Blizzard-API).

-- Forward declarations so closures bind deterministically regardless of registration order.
local reagentInfo, reagentName, expansionShort

-- Locale-correct display name: ItemNameResolver (live C_Item.GetItemInfo first) wins; the baked
-- English name is the cold-load placeholder. Matches old HDG's GetLocalizedName "prefer WoW API
-- over hardcoded DB name." Every selector calling this MUST read "session.itemNames.names" so the
-- async resolve (ITEM_INFO_RESOLVED) re-fires it (sweep resolver-facade contract enforces this).
local _localName = HDG.Format.LocalItemName  -- hygiene A16

-- ---------- Resolved recipe DB (seed <- runtime capture) ---------------------
-- Convert a captured reagent set { [rid] = qty } into the DecorDB reagent shape
-- { [rid] = { qty, name } }. Carries the seed's reagent name when the id is
-- unchanged; a genuinely new reagent id (12.1 swap) resolves its name at display
-- via _localName, so a nil name here is fine.
local function _overlayReagents(captured, seedReagents)
    local out = {}
    for rid, qty in pairs(captured) do
        local sr = seedReagents and seedReagents[rid]  -- exception(nullable): new reagent id absent from seed
        out[rid] = { qty = qty, name = sr and sr.name }
    end
    return out
end

-- The single read seam for recipe REAGENTS: the shipped seed (StaticData.Recipes)
-- with runtime-captured reagents + profession overlaid per crafted-decor itemID
-- (account.recipeCapture, filled by ProfessionScanner:CaptureRecipeData). This is
-- how 12.1's reduced-lumber costs reach the UI without a seed reship -- the scan
-- overrides whatever the seed shipped. Identity fields (name/spellID/decorID/
-- category) stay seed-owned; only reagents + profession are corrected, and only
-- on entries the seed already knows (new-recipe materialization is a later stage).
-- Memoized on account.recipeCapture: rebuilds only when a scan changes capture.
-- Keyed by crafted-decor itemID to match StaticData.Recipes:Get -- consumers that
-- did :Get(itemID) index this by the same key. (GetAll's raw table is keyed by the
-- DecorDB synthetic build-ID instead, so we re-key here; iteration consumers read
-- entry.itemID either way.)
-- The scanner captures C_TradeSkillUI.GetBaseProfessionInfo().professionName, which is
-- LOCALIZED ("Alchemie" on deDE). Stamping that over the seed's English value breaks
-- every join against the curated English data -- HDGR_Profession.lua's own header calls
-- this out and names captured recipes specifically. Map it back through the alias index
-- here rather than at capture, so SavedVariables already written by a non-enUS client are
-- repaired on read too. An unmapped name is kept as-is: that means PROFESSION_DATA is
-- missing an alias, which is a data gap to fix, not something to silently drop.
local function _canonProfession(name)
    if not name then return nil end   -- exception(nullable): pre-walk captures have no profession yet
    local entry = HDG.Profession.GetByName(name)
    return entry and entry.name or name
end

-- True when a capture says what the seed entry already says: the seed ships from
-- scans, so most captures match it (321 of 346 on one account, 2026-10-21), and a
-- copy of each was most of this selector's 749 KB a build.
local function _captureMatchesSeed(ov, entry)
    if _canonProfession(ov.profession) ~= entry.profession then return false end
    local seedReagents = entry.reagents
    if not seedReagents then return next(ov.reagents) == nil end  -- exception(optional): a seed entry may ship without reagents
    for rid, qty in pairs(ov.reagents) do
        local sr = seedReagents[rid]  -- exception(nullable): a reagent the seed does not list
        if not (sr and sr.qty == qty) then return false end
    end
    for rid in pairs(seedReagents) do
        if ov.reagents[rid] == nil then return false end
    end
    return true
end

Selectors:Register("recipes.db", {
    reads    = { "account.recipeCapture", "session.resolvers.staticData.tick" },  -- staticData.tick: ADR-003c GetAll facade contract
    memoized = true,
    fn = function(state)
        local seed = HDG.StaticData.Recipes:GetAll()
        local cap  = state.account.recipeCapture
        local merged = {}
        for _, entry in pairs(seed) do
            if entry.itemID then
                local ov = cap[entry.itemID]  -- exception(nullable): most entries have no override
                if ov and _captureMatchesSeed(ov, entry) then
                    merged[entry.itemID] = entry   -- the capture agrees: share the seed ref
                elseif ov then
                    local m = {}
                    for k, v in pairs(entry) do m[k] = v end
                    m.profession = _canonProfession(ov.profession)
                    m.reagents   = _overlayReagents(ov.reagents, entry.reagents)
                    merged[entry.itemID] = m
                else
                    merged[entry.itemID] = entry   -- unchanged: share the seed ref
                end
            end
        end
        -- Materialize captured recipes the seed doesn't ship (new 12.1 recipes): the scan is
        -- the source of truth, seed a shrinking fallback. category is the decor constant;
        -- name/decorID resolve downstream from the catalog + itemID; expansion is the captured
        -- skill-line from the profession book's category-tree walk (nil on pre-walk captures
        -- until the next scan backfills -> uncategorized rather than not-at-all).
        for itemID, ov in pairs(cap) do
            if not merged[itemID] then
                merged[itemID] = {
                    itemID     = itemID,
                    spellID    = ov.spellID,
                    profession = _canonProfession(ov.profession),
                    category   = "House Decor",
                    expansion  = ov.expansion,
                    name       = ov.name,
                    reagents   = _overlayReagents(ov.reagents, nil),
                }
            end
        end
        return merged
    end,
})

-- The craft graph PowerCrafter walks (ADR-013 explicit-parameter): the shipped
-- ProfessionsDB closure (fallback) overlaid with runtime capture -- sub-recipe
-- records first, decor records last (capture wins; decor can't collide with a
-- sub but the order makes it deterministic). Captured records synthesize the
-- ProfessionsDB slot shape from their {id=qty} reagent map so VisitBasicSlots
-- reads both identically; the seed's name carries over when known (PowerCrafter
-- falls back to slot.name/itemID otherwise). Keyed by output itemID -- same as
-- ProfessionsDB, so queue recipeIDs (crafted-decor itemIDs) index directly.
-- Seed records decode on first lookup and stay in the graph: readers only ever
-- index it (a queued recipe and the reagents under it), and decoding all ~1,600
-- up front was most of a first Recipes visit (3.5 MB, 2026-10-20 profile).
local function _seedRecord(graph, itemID)
    local rec = HDG.StaticData.Professions:Get(itemID)  -- exception(nullable): gathered and vendor reagents have no producer
    if rec then rawset(graph, itemID, rec) end
    return rec
end
local SEED_GRAPH_META = { __index = _seedRecord }

-- What a captured record keeps of the one it replaces: an earlier overlay's
-- record, else the seed's header (no slots decoded).
local function _priorFields(graph, itemID)
    local prior = rawget(graph, itemID)  -- exception(nullable): only a sub-recipe capture lands first
    if prior then return prior.name, prior.categoryName, prior.outputQtyMin end
    return HDG.StaticData.Professions:GetHeader(itemID)
end

Selectors:Register("recipes.craftGraph", {
    reads    = { "account.recipeCapture", "account.subRecipeCapture",
                 "session.resolvers.staticData.tick" },  -- staticData.tick: ADR-003c facade contract
    memoized = true,
    fn = function(state)
        local graph = setmetatable({}, SEED_GRAPH_META)
        local function overlay(store)
            for itemID, rec in pairs(store) do
                -- Sort by itemID. rec.reagents is an {id=qty} MAP, and pairs() order is
                -- not deterministic under LuaJIT -- but this array replaces the seed's
                -- fixed-order slots, and GetRecipeShortage picks worstShortageItem with a
                -- strict `>`, so on a TIE whichever slot happened to be visited first won.
                -- Ties are the normal case for decor recipes (8/8/8/1), which made the
                -- "you're missing X" reagent flip between logins with no state change.
                local slots = {}
                for rid, qty in pairs(rec.reagents) do
                    slots[#slots + 1] = { type = "basic", qty = qty, itemID = rid }
                end
                table.sort(slots, function(a, b) return a.itemID < b.itemID end)
                -- All nil when the seed does not ship the captured recipe.
                local seedName, seedCategory, seedOutput = _priorFields(graph, itemID)
                graph[itemID] = {
                    itemID       = itemID,
                    recipeID     = rec.spellID,
                    profession   = rec.profession,
                    categoryName = rec.categoryName or seedCategory,
                    name         = seedName,
                    slots        = slots,
                    -- Per-craft yield PowerCrafter divides demand by. Capture first; the
                    -- seed's value when the record was scanned before the field existed.
                    outputQtyMin = rec.outputQtyMin or seedOutput,  -- exception(optional): sparse -- only multi-output recipes carry it
                }
            end
        end
        overlay(state.account.subRecipeCapture)
        overlay(state.account.recipeCapture)
        return graph
    end,
})

-- ---------- Filter state mirrors ---------------------------------------------
Selectors:DefinePath("recipes.searchQuery",      "session.ui.recipes.searchQuery")
Selectors:DefinePath("recipes.selectedRecipeID", "session.ui.recipes.selectedRecipeID")
Selectors:DefinePath("recipes.focusedItemID",    "session.ui.recipes.focusedItemID")
Selectors:Register("recipes.hasSelectedRecipe", {
    calls = {"recipes.selectedRecipeID"},
    fn = function(state, ctx)
        return Selectors:Call("recipes.selectedRecipeID", state, ctx) ~= nil
    end,
})
-- Materials controls: grouping (totals | byRecipe) x depth (direct | raw).
Selectors:Register("recipes.materialsGrouping", {
    reads = {"session.ui.recipes.materialsGrouping"},
    fn = function(state) return state.session.ui.recipes.materialsGrouping end,
})
Selectors:Register("recipes.materialsDepth", {
    reads = {"session.ui.recipes.materialsDepth"},
    fn = function(state) return state.session.ui.recipes.materialsDepth end,
})
Selectors:DefineEnumOver("recipes.isGrouping", "recipes.materialsGrouping",
                         { "totals", "byRecipe" })
Selectors:DefineEnumOver("recipes.isDepth", "recipes.materialsDepth",
                         { "direct", "raw" })

-- Toggle-button label: reflects current grouping (click flips it).
Selectors:Register("recipes.materialsGroupingLabel", {
    calls = {"recipes.materialsGrouping"},
    fn = function(state, ctx)
        return Selectors:Call("recipes.materialsGrouping", state, ctx) == "byRecipe"
            and "By Recipe" or "Totals"
    end,
})
-- Depth radio options: {text,value} menu-item shape for radioGroup. Not memoized (2 items, trivial).
Selectors:Register("recipes.materialsDepthOptions", {
    reads    = {},
    fn = function()
        return {
            { text = "Direct", value = "direct" },
            { text = "Raw",    value = "raw"    },
        }
    end,
})

-- (recipes.knownRecipeItemIDs removed: raw walker is known-agnostic, no callers.)
-- (recipes.scope / isScope removed: Recipes view is decor-only; Decor/All toggle gone.)

-- Multi-select profession filter set ({ [name]=true }). Empty = all professions.
-- Stored PER CHARACTER (account.ui.recipes.professionFilterByChar[charKey]) so the
-- filter is meaningful per alt. Until a character has explicitly chosen (its entry
-- is nil), the DEFAULT is that character's own scanned professions -- so opening
-- Recipes lands pre-filtered to what you can actually craft. An explicit "All
-- Professions" click stores an empty {} (distinct from nil), which means all.
local EMPTY_SET = {}
Selectors:Register("recipes.professionFilter", {
    reads = { "account.ui.recipes.professionFilterByChar",
              "session.identity.charKey", "account.characters" },
    fn = function(state)
        local set = state.account.ui.recipes.professionFilterByChar[state.session.identity.charKey]
        if set then return set end   -- explicit choice (incl. empty = all)
        -- Pristine: default to this character's professions.
        local char = state.account.characters[state.session.identity.charKey]   -- exception(nullable): char record may not exist yet
        if not (char and type(char.professions) == "table") then return EMPTY_SET end
        local out = {}
        for profName in pairs(char.professions) do out[profName] = true end
        return out
    end,
})

-- Multi-select expansion filter set ({ [display]=true }). Empty = all expansions.
Selectors:Register("recipes.expansionFilter", {
    reads = {"account.ui.recipes.expansionFilter"},
    fn = function(state) return state.account.ui.recipes.expansionFilter end,
})

Selectors:Register("recipes.listFilter", {
    reads = {"session.ui.recipes.listFilter"},
    fn = function(state) return state.session.ui.recipes.listFilter end,
})
-- Full-width filter dropdown options (single-select). Default "all".
-- "decorUncollected" keeps recipes whose produced decor isn't collected yet
-- (the tooltip's "Decor: Not collected"). Static set; labels from Locale.
Selectors:Register("recipes.listFilterMenuItems", {
    reads = { "account.config.scheme" },   -- dim suffix recolors on theme switch
    fn = function()
        local L   = HDG.Locale
        local dim = HDG.Theme:ColorCode("text.dim")
        -- descKey nil/empty -> label only (no dim suffix).
        local function item(value, labelKey, descKey)
            local label = L:Get(labelKey)
            local desc  = descKey and L:Get(descKey)
            if not desc or desc == "" then return { value = value, text = label } end
            return { value = value, text = label .. "   " .. dim .. desc .. "|r" }
        end
        return {
            item("all",              "REC_FILTER_ALL",              "REC_FILTER_ALL_DESC"),
            item("known",            "REC_FILTER_KNOWN",            "REC_FILTER_KNOWN_DESC"),
            item("ready",            "REC_FILTER_READY",            "REC_FILTER_READY_DESC"),
            item("unknown",          "REC_FILTER_UNKNOWN",          "REC_FILTER_UNKNOWN_DESC"),
            item("decorUncollected", "REC_FILTER_DECOR_UNCOLLECTED", nil),
        }
    end,
})

-- Warehouse material selection + search (extracted from Recipes tab).
Selectors:DefinePath("warehouse.selectedMaterialID", "session.ui.warehouse.selectedMaterialID")
Selectors:DefinePath("warehouse.matSearch",          "session.ui.warehouse.matSearch")

-- Lumber auto-show toggle state (Warehouse title-bar checkbox). Drives whether
-- the lumber tracker pops automatically on harvest (LumberObserver reads it).
Selectors:Register("warehouse.autoShowLumber", {
    reads = {"account.lumber.config.autoShowOnHarvest"},
    fn = function(state) return state.account.lumber.config.autoShowOnHarvest == true end,
})

-- Used In panel header. Reagent name via ReagentsDB (ADR-003a carve-out).
Selectors:Register("warehouse.usedInTitle", {
    calls = {"warehouse.selectedMaterialID"},
    reads = {"session.itemNames.names"},   -- reagentName -> resolver; re-fire when the name localises
    fn = function(state, ctx)
        local id = Selectors:Call("warehouse.selectedMaterialID", state, ctx)
        if not id then return "Used In" end
        -- Accent the reagent name (scheme accent = gold in the Housing theme), matching
        -- the "From Vendor"/"From Gathering" section headers. Theme switch full-re-renders.
        local accent = HDG.Theme:ColorCode("semantic.accent")
        return accent .. reagentName(id) .. "|r is used in recipes:"
    end,
})

-- ============================================================================
-- ===== Warehouse view selectors ==========================================
-- ============================================================================

-- buildLumberRequiredMap: walk recipes.db (DecorDB reagents), accumulate lumber needed
-- across recipes whose produced decor isn't owned. Not cached (COLLECTION_ITEM_LEARNED
-- mutates ownedDecorIDs in-place, so pointer-equality cache misses real ownership
-- changes). Sub-ms in Lua; selector memo de-dupes within a dispatch cycle.

-- {[itemID]=true} set of lumber item IDs for slot filtering.
local function _buildLumberItemSet()
    local set = {}
    for _, l in ipairs(HDG.Constants.LUMBER_DATA) do
        if l.id then set[l.id] = true end
    end
    return set
end

-- Accumulate lumber requirements for one recipe into `out`.
local function _accumulateLumberFromRecipe(recipe, lumberSet, out)
    HDG.StaticData.Recipes:VisitReagents(recipe, function(slot)
        if slot.itemID and slot.qty and lumberSet[slot.itemID] then
            out[slot.itemID] = (out[slot.itemID] or 0) + slot.qty
        end
    end)
end

local function buildLumberRequiredMap(state)
    local owned     = state.account.collection.ownedDecorIDs
    local byItemID  = HDG.HousingCatalogObserver.byItemID
    local lumberSet = _buildLumberItemSet()
    local out       = {}
    local db = Selectors:Call("recipes.db", state)   -- seed <- runtime reagent override
    if type(db) ~= "table" then return out end
    for _, recipe in pairs(db) do
        if recipe.itemID then
            local obsRow  = byItemID[recipe.itemID]
            local decorID = obsRow and obsRow.decorID
            if decorID and not owned[decorID] then
                _accumulateLumberFromRecipe(recipe, lumberSet, out)
            end
        end
    end
    return out
end

-- Queue-derived lumber need (cheap walk, queue is small).
local function buildLumberQueueNeed(state)
    local out = {}
    local q   = state.account.craft.queue
    if #q == 0 then return out end
    local lumberSet = {}
    for _, l in ipairs(HDG.Constants.LUMBER_DATA) do
        if l.id then lumberSet[l.id] = true end
    end
    local db = Selectors:Call("recipes.db", state)   -- seed <- runtime reagent override
    for _, row in ipairs(q) do
        local recipe = db[row.recipeID]
        HDG.StaticData.Recipes:VisitReagents(recipe, function(slot)
            if slot.itemID and slot.qty and lumberSet[slot.itemID] then
                out[slot.itemID] = (out[slot.itemID] or 0)
                    + slot.qty * (row.remaining or 1)  -- exception(boundary): queue row from SVars may lack remaining
            end
        end)
    end
    return out
end

-- Shared algorithm (warehouse "Need" + the Lumber Tracker denominator):
-- lumber required across recipes whose produced decor is NOT collected.
-- Registered so both surfaces call ONE implementation and can never drift
-- (owner call 2026-06-11: tracker showed the all-recipes sum, warehouse
-- showed uncollected-only -- 1438 vs 888 on Thalassian).
Selectors:Register("warehouse.lumberRequired", {
    reads = {
        "account.collection.ownedDecorIDs",
        "session.resolvers.catalog.tick",   -- recipe itemID -> decorID via HousingCatalogObserver.byItemID (warms async)
        "session.resolvers.staticData.tick",
    },
    calls = { "recipes.db" },
    fn = function(state)
        return buildLumberRequiredMap(state)
    end,
})

Selectors:Register("warehouse.lumberRows", {
    reads = {
        "session.resolvers.bag.tick",
        "account.craft.queue",
        "account.collection.ownedDecorIDs",
        "session.resolvers.catalog.tick",
        "session.resolvers.achievementStatus.tick",   -- exp-acronym gold = lumber milestone earned (live IsEarned)
    },
    calls = { "warehouse.lumberRequired", "recipes.db" },
    fn = function(state, ctx)
        local data = HDG.Constants.LUMBER_DATA
        if type(data) ~= "table" then return {} end
        local required = Selectors:Call("warehouse.lumberRequired", state, ctx)
        local queueNeed = buildLumberQueueNeed(state)
        local bo = HDG.BagObserver
        local out = {}
        for _, l in ipairs(data) do
            local bag, bank, warband = bo:GetSplitWithVariants(l.id)
            local stock = bag + bank + warband
            local need  = required[l.id] or 0  -- exception(boundary): sparse map
            out[#out + 1] = {
                kind             = "lumberRow",
                itemID           = l.id,
                name             = l.shortName or l.name,
                expansion        = l.expansion,
                expansionShort   = expansionShort(l.expansion),
                achieveID        = l.achieveID,
                achEarned        = (l.achieveID and HDG.AchievementObserver:IsEarned(l.achieveID)) or false,
                bag              = bag,
                bank             = bank,
                warband          = warband,
                queueNeed        = queueNeed[l.id] or 0,  -- exception(boundary): sparse map
                stock            = stock,
                requiredTotal    = need,
                covered          = (need == 0) or (stock >= need),
                anyStock         = stock > 0,
            }
        end
        return out
    end,
})

-- Collect distinct basic reagents: { [itemID] = displayName }.
-- slot.name preferred; falls back to reagentName(). First-occurrence wins.
local function _collectDistinctBasicReagents(recipes, db)
    local distinct = {}
    for _, r in ipairs(recipes) do
        HDG.StaticData.Recipes:VisitReagents(db[r.recipeID], function(slot)
            if slot.itemID and not distinct[slot.itemID] then
                distinct[slot.itemID] = _localName(slot.itemID, slot.name)
            end
        end)
    end
    return distinct
end

-- Sum needed reagents across the queue: { [itemID] = totalQty }.
local function _buildNeedMapFromQueue(queue, db)
    local need = {}
    if #queue == 0 then return need end
    for _, row in ipairs(queue) do
        HDG.StaticData.Recipes:VisitReagents(db[row.recipeID], function(slot)
            if slot.itemID and slot.qty then
                need[slot.itemID] = (need[slot.itemID] or 0)
                    + slot.qty * (row.remaining or 1)  -- exception(boundary): queue row from SVars may lack remaining
            end
        end)
    end
    return need
end

-- Sort: owned (have > 0) first, then alphabetic, then itemID for stability.
local function _matRowOwnedFirst(a, b)
    local aOwned = (a.have or 0) > 0
    local bOwned = (b.have or 0) > 0
    if aOwned ~= bOwned then return aOwned end
    if a.name  == b.name then return a.itemID < b.itemID end
    return a.name < b.name
end

-- The two bag-independent halves of the All Materials list, memoised so a bag
-- tick (every loot, every vendor buy) re-reads counts against a stable reagent
-- set instead of re-walking every filtered recipe: 20 ms and up to 800 KB a
-- call before (2026-09-13 audit).
Selectors:Register("warehouse.allMaterialsDistinct", {
    memoized = true,
    calls = {"recipes.filteredRecipes", "recipes.db"},
    reads = {"session.itemNames.names"},
    fn = function(state, ctx)
        local recipes = Selectors:Call("recipes.filteredRecipes", state, ctx)
        local rdb     = Selectors:Call("recipes.db", state, ctx)
        return _collectDistinctBasicReagents(recipes, rdb)
    end,
})

Selectors:Register("warehouse.queueNeedByMaterial", {
    memoized = true,
    calls = {"recipes.db"},
    reads = {"account.craft.queue"},
    fn = function(state, ctx)
        local rdb = Selectors:Call("recipes.db", state, ctx)
        return _buildNeedMapFromQueue(state.account.craft.queue, rdb)
    end,
})

-- All Materials: distinct basic reagents from the current filtered recipe set
-- (expansion/profession chips drive what shows). Search applied post-distinct.
Selectors:Register("warehouse.allMaterialsRows", {
    -- selectedMaterialID retired: selection owned by SelectionBehaviorMixin.
    -- Cross-file calls dependency on filteredRecipes is intentional (scoped to recipe filter).
    calls = {"warehouse.allMaterialsDistinct", "warehouse.queueNeedByMaterial",
             "warehouse.matSearch"},
    reads = {"session.resolvers.bag.tick"},
    fn = function(state, ctx)
        local query    = Selectors:Call("warehouse.matSearch",              state, ctx):lower()
        local distinct = Selectors:Call("warehouse.allMaterialsDistinct",   state, ctx)
        local need     = Selectors:Call("warehouse.queueNeedByMaterial",    state, ctx)
        local counts   = HDG.BagObserver:GetCounts()
        local bo       = HDG.BagObserver
        local out = {}
        for itemID, name in pairs(distinct) do
            if query == "" or name:lower():find(query, 1, true) then
                local bag, bank, warband = bo:GetSplitWithVariants(itemID)
                out[#out + 1] = {
                    kind    = "warehouseMatRow",
                    itemID  = itemID,
                    name    = name,
                    have    = counts[itemID] or 0,  -- exception(boundary): sparse bag map
                    need    = need[itemID]   or 0,  -- exception(boundary): sparse map
                    bag     = bag,
                    bank    = bank,
                    warband = warband,
                }
            end
        end
        -- Owned-first sort: inventory leads, then alphabetic.
        table.sort(out, _matRowOwnedFirst)
        return out
    end,
})

-- Used In: recipes whose basic slots include the selected material.
-- Follows the filter chain (expansion + profession + listFilter).
Selectors:Register("warehouse.usedInRows", {
    calls = {"warehouse.selectedMaterialID", "recipes.filteredRecipes", "recipes.db"},
    reads = {"session.resolvers.staticData.tick"},
    fn = function(state, ctx)
        local materialID = Selectors:Call("warehouse.selectedMaterialID", state, ctx)
        if not materialID then
            return { { kind = "usedInEmpty", label = "Click a material -> uses" } }
        end
        local all = Selectors:Call("recipes.filteredRecipes", state, ctx)
        local rdb = Selectors:Call("recipes.db", state, ctx)
        local out = {}
        for _, r in ipairs(all) do
            HDG.StaticData.Recipes:VisitReagents(rdb[r.recipeID], function(slot)
                if slot.itemID == materialID then
                    out[#out + 1] = {
                        kind           = "usedInRow",
                        recipeID       = r.recipeID,
                        name           = r.name,
                        expansionShort = r.expansionShort,
                        profession     = r.profession,
                    }
                    return true   -- stop, only count the recipe once per material
                end
            end)
        end
        table.sort(out, function(a, b)
            if a.profession == b.profession then return a.name < b.name end
            return a.profession < b.profession
        end)
        if #out == 0 then
            return { { kind = "usedInEmpty", label = "Not used in any recipe" } }
        end
        return out
    end,
})

-- Farming history for Warehouse panel. Reuses data.farmingHistoryRows minus the sectionHeader.
Selectors:Register("warehouse.farmingHistoryRows", {
    calls = { "data.farmingHistoryRows" },
    fn = function(state, ctx)
        local out = {}
        for _, r in ipairs(Selectors:Call("data.farmingHistoryRows", state, ctx)) do
            if r.kind ~= "sectionHeader" then out[#out + 1] = r end
        end
        return out
    end,
})

-- (recipes.expansionLabel retired: kind="dropdown" auto-renders trigger text.)

-- Menu options for the expansion dropdown (canonical 12-expansion order).
Selectors:Register("recipes.expansionMenuItems", {
    reads    = {},
    memoized = true,
    fn = function()
        -- Multi-select checkboxes. Master "All Expansions" + one per expansion.
        -- Checked-state evaluated live by the dropdown generator; static list stays memoized.
        local out = { { kind = "checkbox", isAll = true, value = "all", text = "All Expansions" } }
        for _, e in HDG.Expansion.Each() do
            -- Per-expansion brand color from EXPANSION_DATA (same as Palette expansion.* namespace).
            out[#out + 1] = { kind = "checkbox", value = e.display,
                text = HDG.Expansion.GetColorHex(e.display) .. e.display .. "|r" }
        end
        return out
    end,
})

-- Expansion-display -> short-code ("TBC"/"TWW") to avoid crushing the recipe-name column.
expansionShort = function(display)
    return HDG.Expansion.GetShort(display) or display
end

-- ---------- Master list ------------------------------------------------------
-- recipes.allRecipes: flat list joined with known-state + decor-collection state.
-- ProfessionsDB read per ADR-003a carve-out.
Selectors:Register("recipes.allRecipes", {
    memoized = true,  -- perf: ~1050-row walk; called by professionRows/groupedRows/filteredRecipes
    calls = { "recipes.db" },
    reads = {
        "session.itemNames.names",  -- resolver-facade contract (sweep rule 4c)
        "account.recipes",
        "account.collection.ownedDecorIDs",
        "session.resolvers.catalog.tick",
    },
    fn = function(state)
        -- recipes.db = runtime capture (source of truth) UNION the shipped seed (fallback), so
        -- new 12.1 recipes the seed doesn't carry still list. recipeID == produced itemID
        -- (emit r.itemID). expansion is a profession skill-line ("Classic Alchemy") -> normalize
        -- (nil for a not-yet-enriched captured recipe -> uncategorized); icon comes from the item.
        local db = Selectors:Call("recipes.db", state)
        if type(db) ~= "table" then return {} end
        -- EnsureStateShape guarantees account.recipes + account.collection. Strict read.
        local knownByItem = state.account.recipes
        local owned       = state.account.collection.ownedDecorIDs
        local byItemID    = HDG.HousingCatalogObserver.byItemID
        local out = {}
        for _, r in pairs(db) do
            if r.itemID then
                local known   = knownByItem[r.itemID]
                local obsRow  = byItemID[r.itemID]
                local decorID = obsRow and obsRow.decorID
                local exp     = HDG.Expansion.FromSkillLine(r.expansion)
                out[#out + 1] = {
                    recipeID         = r.itemID,
                    itemID           = r.itemID,
                    name             = _localName(r.itemID, r.name or ("recipe " .. r.itemID)),
                    profession       = r.profession or "",
                    expansion        = exp,
                    expansionShort   = expansionShort(exp),
                    icon             = HDG.ItemNameResolver:ResolveIcon(r.itemID),
                    isKnown          = (known and (known.selfKnown or known.altKnown)) and true or false,
                    -- True when the produced decor is owned. Drives green-name treatment.
                    isDecorCollected = (decorID ~= nil) and owned[decorID] and true or false,
                }
            end
        end
        table.sort(out, function(a, b)
            if a.profession == b.profession then return a.name < b.name end
            return a.profession < b.profession
        end)
        return out
    end,
})

-- Decor-itemID set from HousingCatalogObserver (released items only).
-- Rebuilds on sweepGeneration.
Selectors:Register("recipes.decorItemSet", {
    reads    = {"session.resolvers.catalog.tick"},
    memoized = true,
    fn = function()
        local set = {}
        if not HDG.HousingCatalogObserver:IsReady() then return set end
        HDG.HousingCatalogObserver:IterateRows(function(itemID)
            set[itemID] = true
        end)
        return set
    end,
})

-- recipes.filteredRecipes: expansion + profession + search filter on allRecipes.
-- Search matches recipe name OR reagent name; reagents come from HDGR_DecorDB (no slot walk needed).
local function _recipeMatchesSearch(r, query, db)
    if r.name:lower():find(query, 1, true) then return true end
    local entry = db[r.itemID]  -- merged capture-over-seed (recipes.db): live reagents, materialized recipes included
    if not (entry and entry.reagents) then return false end
    for _, reagent in pairs(entry.reagents) do
        if reagent.name and reagent.name:lower():find(query, 1, true) then return true end
    end
    return false
end

-- Data-state gates (catalog Section B). isBlank only triggers once catalog is ready
-- so cold-load doesn't flash premature "no recipes".
Selectors:Register("recipes.hasRecipes", {
    calls = { "recipes.filteredRecipes" },
    fn = function(state, ctx)
        return #Selectors:Call("recipes.filteredRecipes", state, ctx) > 0
    end,
})
-- Show breadcrumb bar only when the filtered list spans 2+ professions.
-- Single-profession: in-list header already names it. Short-circuits at 2.
Selectors:Register("recipes.hasMultipleProfessions", {
    calls = { "recipes.filteredRecipes" },
    fn = function(state, ctx)
        local list = Selectors:Call("recipes.filteredRecipes", state, ctx)
        local seen, n = {}, 0
        for _, r in ipairs(list) do
            local p = r.profession
            if p and p ~= "" and not seen[p] then
                seen[p] = true
                n = n + 1
                if n >= 2 then return true end
            end
        end
        return false
    end,
})
Selectors:Register("recipes.isBlank", {
    calls = { "recipes.filteredRecipes", "catalog.isReady" },
    fn = function(state, ctx)
        if #Selectors:Call("recipes.filteredRecipes", state, ctx) > 0 then return false end
        -- Decor-only: the list is genuinely blank only once the catalog is ready.
        return Selectors:Call("catalog.isReady", state, ctx) and true or false
    end,
})

Selectors:Register("recipes.filteredRecipes", {
    memoized = true,  -- perf: called by hasRecipes/isBlank/groupedRows + more; memo dedupes to ~1/flush
    calls = {"recipes.allRecipes", "recipes.searchQuery", "recipes.db",
             "recipes.professionFilter", "recipes.expansionFilter",
             "recipes.decorItemSet"},
    fn = function(state, ctx)
        local all      = Selectors:Call("recipes.allRecipes", state, ctx)
        local query    = Selectors:Call("recipes.searchQuery", state, ctx):lower()
        local rdb      = Selectors:Call("recipes.db", state, ctx)
        local profSet  = Selectors:Call("recipes.professionFilter", state, ctx)
        local expSet   = Selectors:Call("recipes.expansionFilter", state, ctx)

        -- Decor-only view (the Decor/All toggle is gone).
        local decorSet = Selectors:Call("recipes.decorItemSet", state, ctx)
        local hasQuery = query ~= ""
        local hasExp   = next(expSet) ~= nil    -- empty = all expansions
        local hasProf  = next(profSet) ~= nil   -- empty = all professions

        local out = {}
        for _, r in ipairs(all) do
            local pass = true
            if decorSet and not decorSet[r.itemID]            then pass = false end
            if pass and hasProf  and not profSet[r.profession] then pass = false end
            if pass and hasExp   and not expSet[r.expansion]   then pass = false end
            if pass and hasQuery and not _recipeMatchesSearch(r, query, rdb) then pass = false end
            if pass then out[#out + 1] = r end
        end
        return out
    end,
})

-- ---------- Profession sidebar -----------------------------------------------
-- professionRows: one row per profession with known/total counts (decor-scoped,
-- expansion-aware). isSelected highlights the active filter.
Selectors:Register("recipes.professionRows", {
    memoized = true,  -- perf: called by professionMenuItems + filterResult
    calls = {"recipes.allRecipes", "recipes.professionFilter", "recipes.expansionFilter",
             "recipes.decorItemSet"},
    fn = function(state, ctx)
        local all      = Selectors:Call("recipes.allRecipes", state, ctx)
        local profSet  = Selectors:Call("recipes.professionFilter", state, ctx)
        local expSet   = Selectors:Call("recipes.expansionFilter", state, ctx)
        local decorSet = Selectors:Call("recipes.decorItemSet", state, ctx)
        local hasExp   = next(expSet) ~= nil   -- empty = all expansions
        local stats    = {}    -- [profession] = { known, total }
        local order    = {}
        for _, r in ipairs(all) do
            local passesExp = (not hasExp) or (expSet[r.expansion] == true)
            if decorSet[r.itemID] and passesExp then
                local p = r.profession
                if not stats[p] then
                    stats[p] = { known = 0, total = 0 }
                    order[#order + 1] = p
                end
                stats[p].total = stats[p].total + 1
                if r.isKnown then stats[p].known = stats[p].known + 1 end
            end
        end
        table.sort(order)
        local rows = {}
        -- First row: "All Professions" to clear the filter.
        rows[#rows + 1] = {
            kind        = "profRow",
            profession  = nil,
            label       = "All Professions",
            known       = 0,
            total       = 0,
            isSelected  = next(profSet) == nil,
            isAll       = true,
        }
        for _, p in ipairs(order) do
            local s = stats[p]
            rows[#rows + 1] = {
                kind        = "profRow",
                profession  = p,
                label       = p,
                known       = s.known,
                total       = s.total,
                isSelected  = profSet[p] == true,
                isAll       = false,
            }
        end
        return rows
    end,
})

-- professionMenuItems: static 9-row progress guide + "All Professions" master row.
-- Known/total from professionRows. Icon baked into label (Blizzard Menu can't CreateTexture).
Selectors:Register("recipes.professionMenuItems", {
    reads = { "session.identity.charKey", "account.characters" },
    calls = {"recipes.professionRows"},
    fn = function(state, ctx)
        local rows = Selectors:Call("recipes.professionRows", state, ctx)
        local byProf, aKnown, aTotal = {}, 0, 0
        for _, r in ipairs(rows) do
            if not r.isAll then
                byProf[r.profession] = r
                aKnown = aKnown + r.known
                aTotal = aTotal + r.total
            end
        end
        -- "My Professions" goes FIRST (it is the default filter): the professions
        -- THIS character has scanned, as a one-click preset.
        local out  = {}
        local char = state.account.characters[state.session.identity.charKey]   -- exception(nullable): char record may not exist yet
        if char and type(char.professions) == "table" then
            local mKnown, mTotal, n = 0, 0, 0
            for profName in pairs(char.professions) do
                local r = byProf[profName]
                if r then mKnown = mKnown + r.known; mTotal = mTotal + r.total end
                n = n + 1
            end
            if n > 0 then
                out[#out + 1] = {
                    kind  = "checkbox", isMine = true, value = "mine",
                    text  = "My Professions  " .. mKnown .. "/" .. mTotal,
                    known = mKnown, total = mTotal,
                    pct   = mTotal > 0 and mKnown / mTotal or 0,
                }
            end
        end
        out[#out + 1] = {
            kind  = "checkbox", isAll = true, value = "all",
            text  = "All Professions  " .. aKnown .. "/" .. aTotal,
            known = aKnown, total = aTotal,
            pct   = aTotal > 0 and aKnown / aTotal or 0,
        }
        for i = 1, 9 do
            local p = HDG.Constants.PROFESSION_DATA[i]
            if p and p.name then
                local r     = byProf[p.name]
                local known = r and r.known or 0
                local total = r and r.total or 0
                -- Plain multi-select checkbox: atlas + name + known/total baked into label.
                out[#out + 1] = {
                    kind    = "checkbox",
                    value   = p.name,
                    text    = "|A:" .. (p.atlas or "") .. ":14:14|a " .. p.name
                              .. "  " .. known .. "/" .. total,
                    atlas   = p.atlas,
                    known   = known,
                    total   = total,
                    pct     = total > 0 and known / total or 0,
                    isEmpty = total == 0,
                }
            end
        end
        return out
    end,
})

-- activeFilterChips: ordered token list (expansion first, then profession).
-- Each item { kind, id, label, atlas? }; click dispatches RECIPES_TOGGLE_<DIM>.
Selectors:Register("recipes.activeFilterChips", {
    calls = {"recipes.expansionFilter", "recipes.professionFilter"},
    fn = function(state, ctx)
        local expSet  = Selectors:Call("recipes.expansionFilter", state, ctx)
        local profSet = Selectors:Call("recipes.professionFilter", state, ctx)
        local out = {}
        for _, e in HDG.Expansion.Each() do
            if expSet[e.display] then
                out[#out + 1] = { kind = "expansion", id = e.display, label = e.display }
            end
        end
        for i = 1, 9 do
            local p = HDG.Constants.PROFESSION_DATA[i]
            if p and p.name and profSet[p.name] then
                out[#out + 1] = { kind = "profession", id = p.name,
                                  label = p.name, atlas = p.atlas }
            end
        end
        return out
    end,
})

-- runVisible: shows when any filter is selected; collapses when both sets empty.
Selectors:Register("recipes.runVisible", {
    calls = {"recipes.expansionFilter", "recipes.professionFilter"},
    fn = function(state, ctx)
        return next(Selectors:Call("recipes.expansionFilter", state, ctx)) ~= nil
            or next(Selectors:Call("recipes.professionFilter", state, ctx)) ~= nil
    end,
})

-- filterResult: known/total for the current selection (professionRows is decor-scoped
-- + expansion-aware; gauge = completeness ratio of selection, not matched-of-1050).
Selectors:Register("recipes.filterResult", {
    calls = {"recipes.professionRows", "recipes.professionFilter"},
    fn = function(state, ctx)
        local rows    = Selectors:Call("recipes.professionRows", state, ctx)
        local profSet = Selectors:Call("recipes.professionFilter", state, ctx)
        local hasProf = next(profSet) ~= nil
        local known, total = 0, 0
        for _, r in ipairs(rows) do
            if not r.isAll and (not hasProf or profSet[r.profession]) then
                known = known + r.known
                total = total + r.total
            end
        end
        return { known = known, totalPossible = total,
                 pct = total > 0 and known / total or 0 }
    end,
})

-- (recipes.gaugeLabel / gaugeProgress removed: known/total moved to Recipes header via countLabel.)

-- gridRows: dynamicRows driver. Strip (row 1) sizes to the chip strip's real
-- wrapped height (published to runHeight by FlowContainer); body (row 2) absorbs
-- the rest. runHeight 0 pre-measure -> one-line fallback to avoid clipping.
local GRID_TOTAL_H = 600   -- recipes view fixed total (nav fills); rows sum to this
local TOOLBAR_H    = 30    -- toolbar row (dropdowns) + stack gap
local RUN_PAD      = 6     -- runStrip bottom padding + a hair
Selectors:Register("recipes.gridRows", {
    reads = {"session.ui.recipes.runHeight"},
    calls = {"recipes.runVisible"},
    fn = function(state, ctx)
        if not Selectors:Call("recipes.runVisible", state, ctx) then
            return { TOOLBAR_H, GRID_TOTAL_H - TOOLBAR_H }
        end
        local h = state.session.ui.recipes.runHeight
        if h <= 0 then h = 24 end   -- one-line fallback pre-measure
        local stripH = math.min(TOOLBAR_H + h + RUN_PAD, 240)  -- clamp (don't eat the body)
        return { stripH, GRID_TOTAL_H - stripH }
    end,
})

-- ---------- Queue rows -------------------------------------------------------
-- queueRows: one per queue entry. canCraft/maxCraftable from bag counts.
-- selfKnown gates the craft button (alt-known recipes can't be crafted here).
Selectors:Register("recipes.queueRows", {
    reads = {"session.itemNames.names", "account.craft.queue", "session.resolvers.staticData.tick", "session.resolvers.bag.tick",
             "account.recipes"},
    calls = {"recipes.db", "recipes.craftGraph"},
    fn = function(state)
        local q        = state.account.craft.queue
        local known    = state.account.recipes
        local counts   = HDG.BagObserver:GetCounts()
        local rdb      = Selectors:Call("recipes.db", state)
        local graph    = Selectors:Call("recipes.craftGraph", state)
        local out = {}
        for pos, row in ipairs(q) do
            local recipe     = rdb[row.recipeID]
            -- recipeID == crafted-decor itemID -> resolver localises (catalog/live API); baked name fallback.
            local recipeName = _localName(row.recipeID, (recipe and recipe.name)
                or ("recipe " .. tostring(row.recipeID)))
            local knownRow   = recipe and known[recipe.itemID]
            local spellID    = recipe and recipe.spellID
            local selfKnown  = (knownRow and knownRow.selfKnown) and true or false
            -- pct: 0..1 ratio of materials covered.
            local pct        = (recipe and spellID)
                and HDG.PowerCrafter:GetCraftReadiness(graph, row.recipeID, counts) or 0
            local canCraft   = pct >= 1.0
            -- maxCraftable: floor(min(have/need) over slots). 0 when can't craft.
            local maxCraftable = 0
            if canCraft and recipe then
                maxCraftable = 999999
                HDG.StaticData.Recipes:VisitReagents(recipe, function(slot)
                    if slot.itemID and slot.qty and slot.qty > 0 then
                        local have = counts[slot.itemID] or 0  -- exception(boundary): sparse bag map
                        local possible = math.floor(have / slot.qty)
                        if possible < maxCraftable then maxCraftable = possible end
                    end
                end)
                if maxCraftable == 999999 then maxCraftable = 0 end
            end
            out[#out + 1] = {
                kind         = "queueRow",
                position     = pos,
                recipeID     = row.recipeID,
                itemID       = row.itemID,
                remaining    = row.remaining,
                requested    = row.requested,
                name         = recipeName,
                profession   = recipe and recipe.profession or "",
                icon         = HDG.ItemNameResolver:ResolveIcon(row.recipeID),
                spellID      = spellID,
                selfKnown    = selfKnown,
                canCraft     = canCraft,
                maxCraftable = maxCraftable,
            }
        end
        return out
    end,
})

-- craftOrderRows: aggregate craft order across the queue, numbered + knowledge-stamped.
-- Also drives craftTheseRows (materials panel footer).
Selectors:Register("recipes.craftOrderRows", {
    reads = {"account.craft.queue", "session.resolvers.staticData.tick", "session.itemNames.names"},
    calls = {"decor.craftableState", "recipes.craftGraph"},
    fn = function(state, ctx)
        local craftableState = Selectors:Call("decor.craftableState", state, ctx)
        local entries = HDG.PowerCrafter:GetCraftingOrder(
            Selectors:Call("recipes.craftGraph", state, ctx), state.account.craft.queue)
        local out = {}
        for i, e in ipairs(entries) do
            out[#out + 1] = {
                kind           = "craftOrderRow",
                order          = i,
                itemID         = e.itemID,
                recipeID       = e.recipeID,
                name           = _localName(e.itemID, e.name),   -- localized; baked e.name is English
                qty            = e.qty,
                craftableState = craftableState(e.itemID),
            }
        end
        return out
    end,
})

-- craftTheseRows: same as craftOrderRows, alphabetized without numbering.
Selectors:Register("recipes.craftTheseRows", {
    calls = {"recipes.craftOrderRows"},
    fn = function(state, ctx)
        local list = Selectors:Call("recipes.craftOrderRows", state, ctx)
        local out = {}
        for _, e in ipairs(list) do
            out[#out + 1] = {
                kind           = "craftTheseRow",
                itemID         = e.itemID,
                recipeID       = e.recipeID,
                name           = e.name,
                qty            = e.qty,
                craftableState = e.craftableState,
            }
        end
        table.sort(out, HDG.TableUtils.ByNameThenItemID)
        return out
    end,
})

-- queueTitleLabel: formatted queue title string.
Selectors:Register("recipes.queueTitleLabel", {
    calls = {"recipes.queueCount"},
    fn = function(state, ctx)
        local count = Selectors:Call("recipes.queueCount", state, ctx)
        if count == 0 then return "Queue" end
        return string.format("Queue (%d)", count)
    end,
})

-- queueLumberHeaderLabel: queue footer caption with total lumber needed.
Selectors:Register("recipes.queueLumberHeaderLabel", {
    reads = {"account.craft.queue", "account.collection.ownedDecorIDs"},
    -- buildLumberQueueNeed calls recipes.db, so its closure (account.recipeCapture +
    -- the staticData tick) has to be declared here too -- the sibling warehouse.lumberRows
    -- already does. Without it the footer kept a stale lumber total after a capture.
    calls = {"recipes.db"},
    fn = function(state)
        local need = buildLumberQueueNeed(state)
        local total = 0
        for _, n in pairs(need) do total = total + n end
        if total == 0 then return "Queue" end
        return string.format("Queue: %d lumber", total)
    end,
})

-- queueReadinessRows: per-entry readiness sorted DESC by pct. Drives the queue footer.
Selectors:Register("recipes.queueReadinessRows", {
    reads = {"account.craft.queue", "session.resolvers.bag.tick", "session.itemNames.names", "session.resolvers.staticData.tick"},
    calls = {"decor.craftableState", "recipes.craftGraph", "recipes.db"},
    fn = function(state, ctx)
        local q = state.account.craft.queue
        if not q or #q == 0 then return {} end
        local bagCounts = HDG.BagObserver:GetCounts()
        local craftableState = Selectors:Call("decor.craftableState", state, ctx)
        local graph = Selectors:Call("recipes.craftGraph", state, ctx)
        local rdb   = Selectors:Call("recipes.db", state, ctx)
        local out = {}
        for _, row in ipairs(q) do
            local recipe = rdb[row.recipeID]  -- merged: materialized 12.1 recipes carry their captured name
            local s = HDG.PowerCrafter:GetRecipeShortage(graph,
                row.recipeID, row.remaining or 1, bagCounts)  -- migration: old SVars may lack `remaining`
            out[#out + 1] = {
                kind             = "queueReadinessRow",
                recipeID         = row.recipeID,
                itemID           = row.itemID,
                name             = _localName(row.recipeID, (recipe and recipe.name)
                                   or ("recipe " .. tostring(row.recipeID))),
                pct              = s.pct,
                bottleneckItemID = s.bottleneckItemID,
                missingQty       = s.missingQty,
                craftableState   = craftableState(row.itemID),
            }
        end
        table.sort(out, function(a, b)
            if a.pct == b.pct then return a.name < b.name end
            return a.pct > b.pct
        end)
        return out
    end,
})


-- computeReadiness delegates to PowerCrafter:GetCraftReadiness (shared logic).
local function computeReadiness(graph, recipeID, counts)
    return HDG.PowerCrafter:GetCraftReadiness(graph, recipeID, counts)
end

-- Readiness buckets (higher priority sorts first in "Ready" mode).
local READY_BUCKETS = {
    { id = "complete",  min = 1.00, label = "Ready to Craft",      priority = 10 },
    { id = "most",      min = 0.75, label = "Have Most (75-99%)",  priority = 20 },
    { id = "halfway",   min = 0.50, label = "Halfway (50-74%)",    priority = 30 },
    { id = "started",   min = 0.01, label = "Started (1-49%)",     priority = 40 },
}
local function bucketFor(ratio)
    for _, b in ipairs(READY_BUCKETS) do
        if ratio >= b.min then return b end
    end
    return nil   -- 0% hidden in Ready mode
end

-- groupedRows: profession-grouped (all/known) or bucket-grouped (ready).
-- All rows carry craftableState for the right-edge star.
-- A recipe row holds what this projection adds (kind, craftableState, groupLabel,
-- readiness) and reads the recipe's own fields from its allRecipes row, which is
-- memoized and shared: a copy of those nine fields per row was most of this
-- selector (~350 KB a call, 2026-10-20 profile).
local GROUPED_ROW_META = { __index = function(row, key) return row._recipe[key] end }
Selectors:Register("recipes.groupedRows", {
    memoized = true,  -- perf: sort/group over ~1050 filtered recipes
    -- selectedRecipeID retired: selection owned by SelectionBehaviorMixin;
    -- clicks no longer rebuild the whole grouped list.
    calls = {"recipes.filteredRecipes",
             "decor.craftableState", "recipes.listFilter", "recipes.craftGraph"},
    reads = {"session.resolvers.bag.tick"},
    fn = function(state, ctx)
        local recipes        = Selectors:Call("recipes.filteredRecipes", state, ctx)
        local craftableState = Selectors:Call("decor.craftableState", state, ctx)
        local listFilter     = Selectors:Call("recipes.listFilter", state, ctx)
        local graph          = Selectors:Call("recipes.craftGraph", state, ctx)
        local counts         = HDG.BagObserver:GetCounts()

        -- Known filter: drop rows the current char hasn't learned.
        -- Unknown filter: keep only recipes NO character on the account has learned.
        local pre = recipes
        if listFilter == "known" then
            local kept = {}
            for _, r in ipairs(pre) do
                if r.isKnown then kept[#kept + 1] = r end
            end
            pre = kept
        elseif listFilter == "unknown" then
            local kept, UNKNOWN = {}, HDG.Constants.RECIPE_STATE.UnknownOnAccount
            for _, r in ipairs(pre) do
                if craftableState(r.itemID) == UNKNOWN then kept[#kept + 1] = r end
            end
            pre = kept
        elseif listFilter == "decorUncollected" then
            -- Keep recipes whose produced decor you haven't collected yet
            -- (isDecorCollected is stamped by allRecipes off ownedDecorIDs).
            local kept = {}
            for _, r in ipairs(pre) do
                if not r.isDecorCollected then kept[#kept + 1] = r end
            end
            pre = kept
        end

        -- isSelected retired: SelectionBehavior stamps ed.selected (on the withQty row).
        local function makeRow(r)
            return setmetatable({
                _recipe        = r,
                kind           = "recipeRow",
                craftableState = craftableState(r.itemID),
            }, GROUPED_ROW_META)
        end

        if listFilter == "ready" then
            -- Bucket every recipe by readiness; drop 0% rows entirely.
            local byBucket = {}
            for _, r in ipairs(pre) do
                local ratio  = computeReadiness(graph, r.recipeID, counts)
                local b      = bucketFor(ratio)
                if b then
                    byBucket[b.id] = byBucket[b.id] or {}
                    local row = makeRow(r)
                    row.readiness        = ratio
                    row.readinessPercent = math.floor(ratio * 100 + 0.5)
                    table.insert(byBucket[b.id], row)
                end
            end
            -- Sort within each bucket by readiness desc, then name.
            for _, list in pairs(byBucket) do
                table.sort(list, function(a, b)
                    if a.readiness == b.readiness then return a.name < b.name end
                    return a.readiness > b.readiness
                end)
            end
            local out = {}
            for _, b in ipairs(READY_BUCKETS) do
                local list = byBucket[b.id]
                if list and #list > 0 then
                    -- ADR-024: row carries structured data; factory composes the display string.
                    out[#out + 1] = {
                        kind        = "profHeader",
                        profession  = b.id,           -- doubles as the key
                        bucketLabel = b.label,
                        count       = #list,
                        groupLabel  = b.label,        -- sticky breadcrumb: the bucket, not the recipe's profession
                    }
                    for _, row in ipairs(list) do
                        row.groupLabel = b.label
                        out[#out + 1] = row
                    end
                end
            end
            return out
        end

        -- Default path (all + known + unknown): profession-grouped.
        local out = {}
        local lastProf
        for _, r in ipairs(pre) do
            if r.profession ~= lastProf then
                out[#out + 1] = {
                    kind       = "profHeader",
                    profession = r.profession,
                    label      = r.profession,
                    groupLabel = r.profession,
                }
                lastProf = r.profession
            end
            local row = makeRow(r)
            row.groupLabel = r.profession
            out[#out + 1] = row
        end
        return out
    end,
})

-- queuedQtyMap: { [recipeID] = total remaining }. Separate from groupedRows so a queue
-- change doesn't re-run the expensive sort; withQty folds it in.
Selectors:Register("recipes.queuedQtyMap", {
    reads = {"account.craft.queue"},
    fn = function(state)
        local map = {}
        for _, row in ipairs(state.account.craft.queue) do
            map[row.recipeID] = (map[row.recipeID] or 0) + (row.remaining or 0)  -- exception(boundary): queue row from SVars may lack remaining
        end
        return map
    end,
})

-- groupedRows.withQty: groupedRows + queuedQty stamped (drives +/- steppers).
-- Never writes the grouped rows (Iron Invariant: pure selectors). Headers pass through.
-- A list row holds the queued count and what the list writes (selected), and reads
-- the rest from its grouped row: those are memoized and shared, and a full copy of
-- each (~1,050 rows) was up to 0.7 MB a call (2026-10-20 profile).
local QTY_ROW_META = { __index = function(row, key) return row._row[key] end }

Selectors:Register("recipes.groupedRows.withQty", {
    memoized = true,  -- perf: wraps ~1050 rows; skips re-wrap when queue/grouped unchanged
    calls = {"recipes.groupedRows", "recipes.queuedQtyMap"},
    fn = function(state, ctx)
        local rows = Selectors:Call("recipes.groupedRows",  state, ctx)
        local qty  = Selectors:Call("recipes.queuedQtyMap", state, ctx)
        local out  = {}
        for i, r in ipairs(rows) do
            if r.kind == "recipeRow" then
                out[i] = setmetatable({ _row = r, queuedQty = qty[r.recipeID] or 0 }, QTY_ROW_META)
            else
                out[i] = r
            end
        end
        return out
    end,
})

-- countLabel: "known / total" progress. filterResult is decor-scoped + filter-aware.
Selectors:Register("recipes.countLabel", {
    calls = {"recipes.filterResult"},
    fn = function(state, ctx)
        local g = Selectors:Call("recipes.filterResult", state, ctx)
        return string.format("%d / %d", g.known, g.totalPossible)
    end,
})

-- Scan Guild button label: progress while a harvest runs, else the localized idle text.
Selectors:Register("recipes.scanGuildLabel", {
    reads = { "session.recipeHarvest", "account.config.locale" },
    fn = function(state)
        local h = state.session.recipeHarvest
        if h.active then
            if h.total > 0 then return ("%d/%d %s"):format(h.done, h.total, h.name) end
            return HDG.Locale:Get("REC_SCAN_GUILD_WAIT")
        end
        return HDG.Locale:Get("REC_SCAN_GUILD")
    end,
})

-- ---------- Selected-recipe panel --------------------------------------------
-- ADR-003a: DecorDB read inside closure (deterministic post-init).
Selectors:Register("recipes.selectedRecipe", {
    -- staticData.tick arrives transitively via recipes.db's reads closure.
    calls = {"recipes.selectedRecipeID", "recipes.db"},
    fn = function(state, ctx)
        local rid = Selectors:Call("recipes.selectedRecipeID", state, ctx)
        if not rid then return nil end
        return Selectors:Call("recipes.db", state, ctx)[rid]   -- seed <- runtime reagent override
    end,
})

Selectors:Register("recipes.selected.name", {
    calls = {"recipes.selectedRecipe"},
    fn = function(state, ctx)
        local r = Selectors:Call("recipes.selectedRecipe", state, ctx)
        return (r and r.name) or "Click a recipe"
    end,
})
Selectors:Register("recipes.selected.profession", {
    calls = {"recipes.selectedRecipe"},
    fn = function(state, ctx)
        local r = Selectors:Call("recipes.selectedRecipe", state, ctx)
        return r and r.profession or ""
    end,
})

-- ---------- Queue passthrough + aggregates ------------------------------------
Selectors:DefinePath("recipes.queue", "account.craft.queue")
Selectors:Register("recipes.queueCount", {
    calls = {"recipes.queue"},
    fn = function(state, ctx)
        return #Selectors:Call("recipes.queue", state, ctx)
    end,
})
-- Positive gate for queue list well (Section B empty label takes over when empty).
Selectors:Register("recipes.hasQueue", {
    calls = {"recipes.queueCount"},
    fn = function(state, ctx)
        return Selectors:Call("recipes.queueCount", state, ctx) > 0
    end,
})
Selectors:Register("recipes.queueIsEmpty", {
    calls = {"recipes.queueCount"},
    fn = function(state, ctx)
        return Selectors:Call("recipes.queueCount", state, ctx) == 0
    end,
})
Selectors:Register("recipes.queueHasEntries", {
    calls = {"recipes.queueIsEmpty"},
    fn = function(state, ctx)
        return not Selectors:Call("recipes.queueIsEmpty", state, ctx)
    end,
})
Selectors:Register("recipes.queueLabel", {
    calls = {"recipes.queueCount"},
    fn = function(state, ctx)
        local n = Selectors:Call("recipes.queueCount", state, ctx)
        if n == 0 then return "Queue: empty" end
        return string.format("Queue: %d", n)
    end,
})

-- ---------- Materials projections --------------------------------------------
-- All three modes are PowerCrafter-backed.
-- Direct = selected recipe's basic slots. Raw = DAG-expanded. ByRecipe = per-row grouping.
-- Empty queue -> falls back to the selected recipe so the panel stays useful while browsing.
-- Bag-count stamping (have/need) at the row-emission seam.

-- 1-row-queue from the selected recipe for queue-aware mode fallback.
local function syntheticQueueFromSelection(state, ctx)
    local r = Selectors:Call("recipes.selectedRecipe", state, ctx)
    if not r then return nil end
    return { { recipeID = r.itemID, itemID = r.itemID, remaining = 1 } }
end

-- The queue's rows for one recipe (empty when it isn't queued).
local function queueRowsFor(q, recipeID)
    local filtered = {}
    for _, row in ipairs(q) do
        if row.recipeID == recipeID then filtered[#filtered + 1] = row end
    end
    return filtered
end

-- Effective queue: real queue if non-empty; else selection-derived fallback.
-- queueSelectedRecipeID scopes to a single recipe for the "click a queue row" UX.
-- materialsRecipeID (a recipe opened from another window) comes first: its own
-- queue row when it is queued, so the count is the queue's; one craft when not.
local function effectiveQueue(state, ctx)
    local q = Selectors:Call("recipes.queue", state, ctx)
    local opened = state.session.ui.recipes.materialsRecipeID
    if opened then
        local rows = queueRowsFor(q, opened)
        if #rows > 0 then return rows end
        return { { recipeID = opened, itemID = opened, remaining = 1 } }
    end
    if not (q and #q > 0) then
        return syntheticQueueFromSelection(state, ctx)
    end
    local scoped = state.session.ui.recipes.queueSelectedRecipeID
    if not scoped then return q end
    local filtered = queueRowsFor(q, scoped)
    if #filtered == 0 then return q end   -- recipe removed from queue; fall back to full
    return filtered
end

-- Resolve reagent name + source category from ReagentsDB.
-- Assigned to forward-declared upvalue so filteredRecipes' reagent-search path
-- binds to the same fn. sourceCategory: "Vendor:1234", "Gathering", "Crafted", etc.
reagentInfo = function(itemID)
    local source, baked = HDG.StaticData.Reagents:Get(itemID)
    if source then
        local clean = source:match("^([^:]+)") or source   -- strip ":price" suffix
        -- Name via resolver (locale-correct); the baked name is its cold-load placeholder.
        return _localName(itemID, baked), clean
    end
    return _localName(itemID, nil), "Other"
end

-- Name-only accessor.
reagentName = function(itemID)
    local name = reagentInfo(itemID)
    return name
end

-- Source section ordering: Vendor first (shop now), Gathering, Drop, Crafted, Quest, Other.
local SOURCE_ORDER = {
    Vendor    = 10,
    Gathering = 20,
    Drop      = 30,
    Crafted   = 40,
    Quest     = 50,
    Other     = 90,
}

-- Build sectioned matRow list from PowerCrafter's qty map.
-- Grouped by source category; matSubHeader between sections; single-section = no header.
local function stampBagCounts(qtyMap)
    local counts = HDG.BagObserver:GetCounts()
    local bo     = HDG.BagObserver
    local buckets, seen = {}, {}
    for itemID, need in pairs(qtyMap) do
        local name, source = reagentInfo(itemID)
        local have = counts[itemID] or 0  -- exception(boundary): sparse bag map
        local bag, bank, warband = bo:GetSplitWithVariants(itemID)
        buckets[source] = buckets[source] or {}
        local b = buckets[source]
        b[#b + 1] = {
            kind    = "matRow",
            itemID  = itemID,
            name    = name,
            qty     = need,
            have    = have,
            covered = have >= need,
            source  = source,
            bag     = bag,
            bank    = bank,
            warband = warband,
        }
        seen[source] = true
    end
    for _, b in pairs(buckets) do
        table.sort(b, function(a, c)
            if a.name == c.name then return a.itemID < c.itemID end
            return a.name < c.name
        end)
    end
    local order = {}
    for source in pairs(seen) do order[#order + 1] = source end
    -- Unknown sources fall back to 99 (sorted last).
    table.sort(order, function(a, b)
        local ra = SOURCE_ORDER[a] or 99   -- exception(boundary): unknown source
        local rb = SOURCE_ORDER[b] or 99   -- exception(boundary): unknown source
        if ra == rb then return a < b end
        return ra < rb
    end)
    local out = {}
    local emitHeaders = #order > 1
    for _, source in ipairs(order) do
        if emitHeaders then
            out[#out + 1] = {
                kind   = "matSubHeader",
                label  = "From " .. source,
                source = source,
            }
        end
        for _, row in ipairs(buckets[source]) do
            out[#out + 1] = row
        end
    end
    return out
end

-- Direct mode: sum each queue row's basic slots (qty * remaining) into a flat reagent list.
Selectors:Register("recipes.materials.direct", {
    calls = {"recipes.queue", "recipes.selectedRecipe", "recipes.db"},
    -- queueSelectedRecipeID is read inside effectiveQueue -- the scope
    -- filter narrows the queue to a single recipe. Track here so toggling
    -- it invalidates the materials list.
    reads = {"session.resolvers.bag.tick", "session.ui.recipes.queueSelectedRecipeID", "session.ui.recipes.materialsRecipeID", "session.resolvers.staticData.tick", "session.itemNames.names"},
    fn = function(state, ctx)
        local queue = effectiveQueue(state, ctx)
        if not queue then return {} end
        local rdb    = Selectors:Call("recipes.db", state, ctx)   -- seed <- runtime reagent override
        local qtyMap = {}
        for _, row in ipairs(queue) do
            HDG.StaticData.Recipes:VisitReagents(rdb[row.recipeID], function(slot)
                if slot.itemID and slot.qty then
                    qtyMap[slot.itemID] = (qtyMap[slot.itemID] or 0)
                        + slot.qty * (row.remaining or 1)  -- exception(boundary): queue row from SVars may lack remaining
                end
            end)
        end
        return stampBagCounts(qtyMap)
    end,
})

Selectors:Register("recipes.materials.raw", {
    calls = {"recipes.queue", "recipes.selectedRecipe", "recipes.craftGraph"},
    reads = {"session.resolvers.bag.tick", "session.ui.recipes.queueSelectedRecipeID", "session.ui.recipes.materialsRecipeID", "session.itemNames.names"},
    fn = function(state, ctx)
        local queue = effectiveQueue(state, ctx)
        if not queue then return {} end
        -- Raw expansion is known-agnostic (no account.recipes dependency).
        local qtyMap = HDG.PowerCrafter:CalculateRawMaterials(
            Selectors:Call("recipes.craftGraph", state, ctx), queue)
        return stampBagCounts(qtyMap)
    end,
})

-- ByRecipe family: grouped view with matSubHeader per queue row.
-- byRecipe = direct; byRecipeRaw = DAG-expanded. Row keys include fromPosition
-- so same-itemID-across-recipes doesn't collide in the scrollbox key map.
local function emitByRecipeGroups(queue, groups, db)
    local counts = HDG.BagObserver:GetCounts()
    local bo     = HDG.BagObserver
    local out = {}
    for pos = 1, #queue do
        local group = groups[pos]
        if group and group.materials then
            local row = queue[pos]
            local recipe = db[group.recipeID]  -- merged: materialized 12.1 recipes carry their captured name
            -- recipeID == the crafted-decor itemID (see recipes.allRecipes build) -> resolver localises it.
            local recipeName = _localName(group.recipeID, (recipe and recipe.name)
                or ("recipe " .. tostring(group.recipeID)))
            local remaining = (row and row.remaining) or 1
            -- Recipe header with position so same-recipe queue rows don't merge.
            out[#out + 1] = {
                kind         = "matSubHeader",
                label        = string.format("%dx %s", remaining, recipeName),
                source       = "recipe:" .. tostring(pos),
                fromPosition = pos,
                fromRecipeID = group.recipeID,
            }
            -- Sort by name for stable display.
            local sorted = {}
            for itemID, need in pairs(group.materials) do
                sorted[#sorted + 1] = {
                    itemID = itemID,
                    name   = reagentName(itemID),
                    need   = need,
                }
            end
            table.sort(sorted, HDG.TableUtils.ByNameThenItemID)
            for _, r in ipairs(sorted) do
                local have = counts[r.itemID] or 0  -- exception(boundary): sparse bag map
                local bag, bank, warband = bo:GetSplitWithVariants(r.itemID)
                out[#out + 1] = {
                    kind         = "matRow",
                    itemID       = r.itemID,
                    name         = r.name,
                    qty          = r.need,
                    have         = have,
                    covered      = have >= r.need,
                    bag          = bag,
                    bank         = bank,
                    warband      = warband,
                    fromPosition = pos,
                    fromRecipeID = group.recipeID,
                }
            end
        end
    end
    return out
end

Selectors:Register("recipes.materials.byRecipe", {
    calls = {"recipes.queue", "recipes.selectedRecipe", "recipes.craftGraph", "recipes.db"},
    reads = {"session.resolvers.bag.tick", "session.ui.recipes.queueSelectedRecipeID", "session.ui.recipes.materialsRecipeID", "session.resolvers.staticData.tick", "session.itemNames.names"},
    fn = function(state, ctx)
        local queue = effectiveQueue(state, ctx)
        if not queue then return {} end
        return emitByRecipeGroups(queue, HDG.PowerCrafter:AggregateByRecipe(
            Selectors:Call("recipes.craftGraph", state, ctx), queue),
            Selectors:Call("recipes.db", state, ctx))
    end,
})

Selectors:Register("recipes.materials.byRecipeRaw", {
    calls = {"recipes.queue", "recipes.selectedRecipe", "recipes.craftGraph", "recipes.db"},
    reads = {"session.resolvers.bag.tick", "session.ui.recipes.queueSelectedRecipeID", "session.ui.recipes.materialsRecipeID", "session.resolvers.staticData.tick", "session.itemNames.names"},
    fn = function(state, ctx)
        local queue = effectiveQueue(state, ctx)
        if not queue then return {} end
        return emitByRecipeGroups(queue, HDG.PowerCrafter:AggregateByRecipeRaw(
            Selectors:Call("recipes.craftGraph", state, ctx), queue),
            Selectors:Call("recipes.db", state, ctx))
    end,
})

Selectors:Register("recipes.materials.current", {
    calls = {"recipes.materialsGrouping", "recipes.materialsDepth",
             "recipes.materials.direct", "recipes.materials.raw",
             "recipes.materials.byRecipe", "recipes.materials.byRecipeRaw"},
    fn = function(state, ctx)
        local grouping = Selectors:Call("recipes.materialsGrouping", state, ctx)
        local depth    = Selectors:Call("recipes.materialsDepth", state, ctx)
        if grouping == "byRecipe" then
            if depth == "raw" then return Selectors:Call("recipes.materials.byRecipeRaw", state, ctx) end
            return Selectors:Call("recipes.materials.byRecipe", state, ctx)
        end
        if depth == "raw" then return Selectors:Call("recipes.materials.raw", state, ctx) end
        return Selectors:Call("recipes.materials.direct", state, ctx)
    end,
})

-- materials.cost: missing-only cost estimate. sum(price * max(0, need-have)).
-- Unpriced mats (lumber etc. -- not AH-buyable) are excluded, not flagged.
-- Empty when nothing's missing.
-- PriceSource is the boundary (session.resolvers.prices.tick triggers repaint on scan).
Selectors:Register("recipes.materials.cost", {
    calls = {"recipes.materials.current"},
    reads = {"account.prices", "session.resolvers.prices.tick"},
    fn = function(state, ctx)
        local rows = Selectors:Call("recipes.materials.current", state, ctx)
        local totalCopper, anyMissing = 0, false
        for _, r in ipairs(rows) do
            if r.kind == "matRow" then
                local missing = (r.qty or 0) - (r.have or 0)
                if missing > 0 then
                    anyMissing = true
                    -- Unpriced mats (lumber etc.) just don't add to the estimate.
                    local price = HDG.PriceSource:GetItemPrice(r.itemID)
                    if price then
                        totalCopper = totalCopper + price * missing
                    end
                end
            end
        end
        if not anyMissing then return "" end
        local gold = HDG.Format.FormatGold(totalCopper)
        return "Est. ~" .. (gold ~= "" and gold or "0g")
    end,
})

