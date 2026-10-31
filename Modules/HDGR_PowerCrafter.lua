-- HDG.PowerCrafter
-- ============================================================================
-- Pure-function DAG resolver for the Recipes tab.
--
-- The "PowerCrafter" name follows the VPC heritage -- it's the engine that
-- turns a queue snapshot into:
--   * a direct material list (one entry per slot, per queue row)
--   * a raw-DAG-expanded leaf list (intermediate crafted reagents expand down
--     to their root materials; the queue's whole demand on an intermediate is
--     added up, then divided by its outputQtyMin and rounded up once)
--   * a per-queue-entry rollup, direct or raw (no cross-row merging)
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
--     whether to filter by recipes.knowledge mine, alts, or both -- PowerCrafter
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

PC.MAX_DEPTH = 6   -- raw walk depth cap (safety net for deep chains; the seed's deepest is 5)

-- Required slots: type=="basic" with itemID+qty (modifying/finishing/automatic are optional embellishments).
local function basicSlots(recipe)
    local out = {}
    HDG.StaticData.Professions:VisitBasicSlots(recipe, function(slot)
        if slot.itemID and slot.qty then out[#out + 1] = slot end
    end)
    return out
end

-- ===== Per-queue-entry direct materials =====================================

-- Adds `qty` crafts of a recipe's basic slots to `into` ({ [itemID] = qty }).
-- The direct list and the raw walk's starting demand are both this sum.
local function _addRecipeDemand(graph, into, recipeID, qty)
    for _, slot in ipairs(basicSlots(graph[recipeID])) do
        into[slot.itemID] = (into[slot.itemID] or 0) + slot.qty * qty
    end
end

-- Direct mode: one entry per basic slot, qty = slot.qty * queueRow.remaining.
-- Returns { [itemID] = qty } keyed by reagent itemID.
function PC:_DirectMaterialsForRow(graph, recipeID, qty)
    local out = {}
    _addRecipeDemand(graph, out, recipeID, qty)
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

-- ===== Raw walk: pooled demand, rounded once per intermediate ===============
-- Owner ruling 2026-10-31: an intermediate is crafted for ALL the demand on it --
-- every queue row and every branch that needs it -- and the crafts are rounded up
-- once. Rounding per branch over-counted multi-yield reagents: Blazing Ink and
-- Flourishing Ink each need one Draconic Vial, a craft makes 5, and Raw asked for
-- the materials of two crafts. Pooling needs an intermediate's demand complete
-- before it is crafted, so every consumer is settled before what it consumes.

-- Depth-first post-order: an intermediate is appended after everything it
-- consumes, so walking `order` backwards settles consumers first. Marking on
-- entry skips an edge back to an intermediate still being visited: that edge
-- closes a cycle, its demand arrives after its target is settled, and it stays
-- a leaf (the cycle guard).
local function _appendPostOrder(graph, itemID, mark, order)
    if mark[itemID] or not _intermediateRecipe(graph, itemID) then return end
    mark[itemID] = true
    for _, slot in ipairs(basicSlots(graph[itemID])) do
        _appendPostOrder(graph, slot.itemID, mark, order)
    end
    order[#order + 1] = itemID
end

local function _postOrder(graph, demand)
    local roots, mark, order = {}, {}, {}
    for itemID in pairs(demand) do roots[#roots + 1] = itemID end
    table.sort(roots)   -- where a cycle is cut must not depend on pairs() order
    for _, itemID in ipairs(roots) do _appendPostOrder(graph, itemID, mark, order) end
    return order
end

-- Craft one intermediate's pooled demand: crafts rounded up once, its reagents'
-- demand raised. depth[x] is x's longest path from the queued recipe (its own
-- reagents are 1); past MAX_DEPTH an intermediate stays a leaf.
local function _settle(graph, itemID, demand, depth)
    local sub = graph[itemID]
    local crafts = _craftsFor(sub, demand[itemID])
    demand[itemID] = nil
    for _, slot in ipairs(basicSlots(sub)) do
        local id = slot.itemID
        demand[id] = (demand[id] or 0) + slot.qty * crafts
        depth[id] = math.max(depth[id] or 0, depth[itemID] + 1)  -- exception(nullable): first consumer to reach id
    end
end

-- Raw-expands `demand` ({ [itemID] = qty }) in place and returns it. Whatever is
-- not crafted stays: raw materials, intermediates past the depth cap, and demand
-- that reaches an intermediate already settled (a cycle).
local function _expandDemand(graph, demand)
    local depth = {}
    for itemID in pairs(demand) do depth[itemID] = 1 end
    local order = _postOrder(graph, demand)
    for i = #order, 1, -1 do
        local itemID = order[i]
        if demand[itemID] and depth[itemID] <= PC.MAX_DEPTH then
            _settle(graph, itemID, demand, depth)
        end
    end
    return demand
end

-- _RawMaterialsForRow: one row raw-expanded (By-Recipe + Raw). Known-agnostic.
function PC:_RawMaterialsForRow(graph, recipeID, qty)
    local demand = {}
    _addRecipeDemand(graph, demand, recipeID, qty)
    return _expandDemand(graph, demand)
end

-- CalculateRawMaterials: the whole queue raw-expanded as ONE demand, so an
-- intermediate two rows share is crafted (and rounded) once.
function PC:CalculateRawMaterials(graph, queue)
    local demand = {}
    if type(queue) ~= "table" then return demand end
    for _, row in ipairs(queue) do
        if row.recipeID and (row.remaining or 0) > 0 then  -- exception(boundary): queue row from SVars may lack remaining
            _addRecipeDemand(graph, demand, row.recipeID, row.remaining)
        end
    end
    return _expandDemand(graph, demand)
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
