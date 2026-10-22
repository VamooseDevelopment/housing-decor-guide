-- HDG.PowerCrafter
-- ============================================================================
-- Pure-function DAG resolver for the Recipes tab.
--
-- The "PowerCrafter" name follows the VPC heritage -- it's the engine that
-- turns a queue snapshot into:
--   * a direct material list (one entry per slot, per queue row)
--   * a raw-DAG-expanded leaf list (intermediate crafted reagents recurse
--     down to their root materials, one craft's reagents per outputQtyMin made)
--   * a per-queue-entry rollup (no cross-row merging)
--   * a "Craft These First" list (subsidiary recipes the queue depends on)
--
-- Architecture rules (locked in):
--   * Pure functions. Inputs: (graph, queue, knownRecipeItemIDs). No Store
--     reads, no Blizzard API. Selectors handle state-snapshotting -- this
--     module just transforms data. (ADR-013 explicit-parameter substitution.)
--   * `graph` is the craft graph: [outputItemID] = recipe record with
--     .slots / .categoryName / .recipeID -- the recipes.craftGraph selector's
--     merge of the shipped ProfessionsDB (fallback) with the runtime capture
--     (account.recipeCapture + account.subRecipeCapture; capture wins).
--     Passing it explicitly (Goblin:BuildProfitData pattern) keeps this
--     module pure AND capture-reactive; the seed-DB read moved to the
--     selector. A graph producer is NECESSARY for a reagent to count as a
--     crafted intermediate but not sufficient: ReagentsDB must not classify
--     the output as a raw material (Gathering / Vendor / Drop / ...). Alchemy
--     transmutes, disenchants and shatters all "produce" raw items from other
--     raw items -- the four Midnight motes form a transmute ring, each 10x the
--     previous -- and walking through them multiplied by 10 per hop until the
--     cycle guard tripped (160k Mote of Light for 36 crafts; KevinW,
--     CurseForge 2026-09-07). See _intermediateRecipe. A reagent ReagentsDB
--     does not know still expands, so a freshly captured intermediate never
--     waits for a data regen. ACCEPTED divergence: GetCraftingOrder used to
--     list a ReagentsDB-"Crafted" intermediate as a placeholder row even with
--     no producing recipe on file; such a reagent is omitted until a scan
--     captures its recipe.
--   * knownRecipeItemIDs is a set: `{ [itemID] = true }`. The CALLER decides
--     whether to filter by selfKnown, altKnown, or both -- PowerCrafter
--     just applies the set as the "auto-expand intermediate" gate.
--
-- Output schemas:
--   CalculateRawMaterials(graph, queue) ->
--     { [itemID] = qty }
--   AggregateByRecipe(graph, queue) ->
--     { [position] = { recipeID, materials = { [itemID] = qty } } }   (direct)
--   AggregateByRecipeRaw(graph, queue) -> same shape, raw-expanded (known-agnostic)
--   GetSubsidiaryRecipes(graph, recipeID, knownRecipeItemIDs) ->
--     { [itemID] = recipeID }   -- itemID is the intermediate; recipeID its
--                                  producing recipe (spell), for the UI panel

HDG = HDG or {}
HDG.PowerCrafter = HDG.PowerCrafter or {}
local PC = HDG.PowerCrafter

PC.MAX_DEPTH = 6   -- depth cap for DAG recursion (safety net for cycles + deep chains)

-- Required slots: type=="basic" with itemID+qty (modifying/finishing/automatic are optional embellishments).
local function basicSlots(recipe)
    local out = {}
    HDG.StaticData.Professions:VisitBasicSlots(recipe, function(slot)
        if slot.itemID and slot.qty then out[#out + 1] = slot end
    end)
    return out
end

-- ===== Per-queue-entry direct materials =====================================

-- Direct mode: one entry per basic slot, qty = slot.qty * queueRow.remaining.
-- Returns { [itemID] = qty } keyed by reagent itemID.
function PC:_DirectMaterialsForRow(graph, recipeID, qty)
    local recipe = graph[recipeID]
    local out = {}
    for _, slot in ipairs(basicSlots(recipe)) do
        out[slot.itemID] = (out[slot.itemID] or 0) + slot.qty * qty
    end
    return out
end

-- ===== Public API ===========================================================

-- AggregateByRecipe: per-position rollup, no cross-row merging, direct depth (no expansion).
function PC:AggregateByRecipe(graph, queue)
    local out = {}
    if type(queue) ~= "table" then return out end
    for pos, row in ipairs(queue) do
        if row.recipeID and (row.remaining or 0) > 0 then  -- exception(boundary): queue row from SVars may lack remaining
            out[pos] = {
                recipeID  = row.recipeID,
                itemID    = row.itemID,
                materials = self:_DirectMaterialsForRow(graph, row.recipeID, row.remaining),
            }
        end
    end
    return out
end

-- AggregateByRecipeRaw: per-position rollup DAG-expanded to base mats (By-Recipe + Raw).
function PC:AggregateByRecipeRaw(graph, queue)
    local out = {}
    if type(queue) ~= "table" then return out end
    for pos, row in ipairs(queue) do
        if row.recipeID and (row.remaining or 0) > 0 then  -- exception(boundary): queue row from SVars may lack remaining
            out[pos] = {
                recipeID  = row.recipeID,
                itemID    = row.itemID,
                materials = self:_RawMaterialsForRow(graph, row.recipeID, row.remaining),
            }
        end
    end
    return out
end

-- Milling/prospecting convert raw mats in BULK with RNG output -- there's no fixed
-- yield to divide by, and the products (pigments / gems) are AH-buyable. The raw DAG
-- STOPS at them: expanding to herbs/ore over-counts wildly (one decor needing 145
-- pigment would otherwise demand ~2900 Yseralline Seeds).
local RNG_BULK_CATEGORY = { ["Mass Milling"] = true, ["Mass Prospecting"] = true }

-- The producing recipe of a reagent the walkers may craft-expand, or nil when the
-- reagent is a LEAF: no producer; an RNG bulk conversion (above); or a RAW material
-- that merely has a conversion recipe. ReagentsDB is that last test: anything it
-- classifies other than Crafted (Gathering, Vendor, Drop, Quest, Other) is obtained
-- raw, and the transmute / disenchant / shatter that can also make it is not how
-- you source it. Walking those multiplied the Midnight mote ring by 10 per hop.
-- A reagent ReagentsDB does not know keeps expanding: a freshly captured
-- intermediate must not wait for a data regen to show its materials.
local function _intermediateRecipe(graph, itemID)
    local sub = graph[itemID]  -- exception(nullable): gathered/vendor reagents have no producer
    if not sub then return nil end
    if RNG_BULK_CATEGORY[sub.categoryName] then return nil end
    local source = HDG.StaticData.Reagents:Get(itemID)  -- exception(nullable): reagent outside ReagentsDB
    if source and not source:match("^Crafted") then return nil end
    return sub
end

-- Crafts needed to make `q` units of a producer's output. outputQtyMin is the
-- per-craft yield the seed carries for multi-output recipes (Imbued Silkweave
-- makes 10; bolts and bars make 2) and the scanner captures from the schematic.
local function _craftsFor(sub, q)
    local yield = sub.outputQtyMin or 1  -- exception(optional): sparse -- only multi-output recipes carry it; absent = one per craft
    return math.ceil(q / yield)
end

-- _RawMaterialsForRow: DAG-walk to base mats. Crafted intermediates (see
-- _intermediateRecipe) recurse, known-agnostic, one craft's reagents per
-- outputQtyMin made. Cycle defense: per-branch visited set + MAX_DEPTH cap.
function PC:_RawMaterialsForRow(graph, recipeID, qty)
    local out = {}
    local function expand(itemID, q, depth, visited)
        if depth > PC.MAX_DEPTH then  -- depth cap: treat as leaf
            out[itemID] = (out[itemID] or 0) + q; return
        end
        if visited[itemID] then       -- cycle: treat as leaf
            out[itemID] = (out[itemID] or 0) + q; return
        end
        local subRecipe = _intermediateRecipe(graph, itemID)
        if not subRecipe then          -- leaf: raw material, or no recipe on file
            out[itemID] = (out[itemID] or 0) + q; return
        end
        -- Intermediate: expand slots. Mark visited per-branch (siblings with
        -- shared upstream intermediates stay unblocked).
        visited[itemID] = true
        local crafts = _craftsFor(subRecipe, q)
        for _, slot in ipairs(basicSlots(subRecipe)) do
            expand(slot.itemID, slot.qty * crafts, depth + 1, visited)
        end
        visited[itemID] = nil
    end
    local recipe = graph[recipeID]
    for _, slot in ipairs(basicSlots(recipe)) do
        expand(slot.itemID, slot.qty * qty, 1, {})
    end
    return out
end

-- CalculateRawMaterials: queue-wide sum of every row's raw materials.
function PC:CalculateRawMaterials(graph, queue)
    local out = {}
    if type(queue) ~= "table" then return out end
    for _, row in ipairs(queue) do
        if row.recipeID and (row.remaining or 0) > 0 then  -- exception(boundary): queue row from SVars may lack remaining
            local rowMats = self:_RawMaterialsForRow(graph, row.recipeID, row.remaining)
            for itemID, q in pairs(rowMats) do
                out[itemID] = (out[itemID] or 0) + q
            end
        end
    end
    return out
end

-- GetSubsidiaryRecipes: intermediates the player can craft (knownRecipeItemIDs gate).
function PC:GetSubsidiaryRecipes(graph, recipeID, knownRecipeItemIDs)
    local out = {}
    local recipe = graph[recipeID]
    if not recipe then return out end
    local knownSet = knownRecipeItemIDs or {}
    for _, slot in ipairs(basicSlots(recipe)) do
        if knownSet[slot.itemID] then
            local sub = _intermediateRecipe(graph, slot.itemID)
            if sub then out[slot.itemID] = sub.recipeID end
        end
    end
    return out
end

-- GetCraftingOrder: consolidated crafted sub-recipes across the queue (informational;
-- knownRecipeItemIDs gate is OPTIONAL). Output: { itemID, recipeID, name, qty } summed.
-- _addOrMergeSlotOrder: O(1) merge via `index` table.
local function _addOrMergeSlotOrder(out, index, slot, addQty, subRecipe)
    local existing = index[slot.itemID]
    if existing then
        out[existing].qty = out[existing].qty + addQty
        return
    end
    out[#out + 1] = {
        itemID   = slot.itemID,
        recipeID = subRecipe and subRecipe.recipeID,
        name     = (subRecipe and subRecipe.name)
                or slot.name
                or ("item " .. tostring(slot.itemID)),
        qty      = addQty,
    }
    index[slot.itemID] = #out
end

-- Collect craftable-basic slots into the order, weighted by multiplier.
-- Craftable = a crafted intermediate per _intermediateRecipe; a producer alone
-- is not enough (a mote with a transmute is gathered, not crafted first).
function PC:_collectCraftSlots(graph, recipe, multiplier, out, index)
    HDG.StaticData.Professions:VisitBasicSlots(recipe, function(slot)
        if not (slot.itemID and slot.qty) then return end
        local subRecipe = _intermediateRecipe(graph, slot.itemID)
        if not subRecipe then return end
        _addOrMergeSlotOrder(out, index, slot, slot.qty * multiplier, subRecipe)
    end)
end

function PC:GetCraftingOrder(graph, queue, _knownRecipeItemIDs)
    local out, index = {}, {}    -- index[itemID] = position in out (dedupe)
    if type(queue) ~= "table" then return out end
    for _, row in ipairs(queue) do
        if row.recipeID and (row.remaining or 0) > 0 then  -- exception(boundary): queue row from SVars may lack remaining
            local recipe = graph[row.recipeID]
            self:_collectCraftSlots(graph, recipe, row.remaining or 1, out, index)  -- exception(boundary): queue row from SVars may lack remaining
        end
    end
    return out
end

-- GetCraftReadiness: 0..1 materials coverage ratio (drives the "Ready" filter bucket).
function PC:GetCraftReadiness(graph, recipeID, bagCounts)
    local recipe = graph[recipeID]
    bagCounts = bagCounts or {}
    local totalNeed, totalHave = 0, 0
    HDG.StaticData.Professions:VisitBasicSlots(recipe, function(slot)
        if not (slot.itemID and slot.qty) then return end
        local have = bagCounts[slot.itemID] or 0  -- exception(boundary): sparse bag map
        if have > slot.qty then have = slot.qty end
        totalNeed = totalNeed + slot.qty
        totalHave = totalHave + have
    end)
    if totalNeed == 0 then return 0 end
    return totalHave / totalNeed
end

-- GetRecipeShortage: coverage ratio + bottleneck reagent (largest absolute shortage).
-- qty multiplies every slot. Returns { pct, bottleneckItemID, missingQty }.
function PC:GetRecipeShortage(graph, recipeID, qty, bagCounts)
    local recipe = graph[recipeID]
    qty       = qty or 1   -- exception(boundary): caller may omit qty for single-craft shortage check
    bagCounts = bagCounts or {}
    local totalNeed, totalHave = 0, 0
    local worstShortageItem, worstShortageQty = nil, 0
    HDG.StaticData.Professions:VisitBasicSlots(recipe, function(slot)
        if not (slot.itemID and slot.qty) then return end
        local need = slot.qty * qty
        local have = bagCounts[slot.itemID] or 0  -- exception(boundary): sparse bag map
        local cappedHave = have
        if cappedHave > need then cappedHave = need end
        totalNeed = totalNeed + need
        totalHave = totalHave + cappedHave
        local shortage = need - have
        if shortage > worstShortageQty then
            worstShortageQty  = shortage
            worstShortageItem = slot.itemID
        end
    end)
    local pct = 0
    if totalNeed > 0 then pct = totalHave / totalNeed end
    return {
        pct              = pct,
        bottleneckItemID = worstShortageItem,
        missingQty       = worstShortageQty,
    }
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "PowerCrafter",
    dependencies = {},  -- pure stateless transform; no event subscriptions
})
