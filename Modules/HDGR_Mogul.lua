-- HDG.Mogul
-- ============================================================================
-- Pure-function craft optimizer engine. Stateless. Unit-testable.
-- Adapted from HDG_Mogul.lua to HDG's data model:
--   * Recipes from recipes.db: the shipped DecorDB with the player's scanned
--     reagents laid over it (reagents = { [itemID] = { name, qty } }, lumber among them)
--   * Lumber set from HDG.Constants.LUMBER_DATA
--   * Known recipes from recipes.knowledge (mine / alts), derived from
--     account.characters[K].professions[P].knownRecipes (recipeID -> true)
--   * Lumber and reagents held from BagObserver (crafts use what you hold first)
--   * Owned decor from HousingCatalogObserver:IsOwned (for Collection mode)
--
-- Two modes:
--   profit     -- rank by gold-per-lumber (market price, then vendor sell);
--                 pick highest expected revenue per bottleneck lumber unit
--   collection -- prioritize crafts producing UNCOLLECTED decor items; ignore
--                 gold value; round-robin within tier to diversify. Its mats,
--                 spend and revenue are counted the same way as profit's.
--
-- Two views (drives which chars contribute the candidate-recipe set):
--   char       -- current char's knownRecipes only
--   account    -- union of all non-hidden chars' knownRecipes (mogul.planRows names
--                 the alt from recipes.knowledge so the UI can hint "log into Slamz")

HDG = HDG or {}
HDG.Mogul = HDG.Mogul or {}
local Mogul = HDG.Mogul

-- ===== Helpers =============================================================

local function copyTable(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- Build a set {[itemID] = true} of lumber item IDs from Constants.
local function lumberSetFromConstants()
    local out = {}
    for _, l in ipairs(HDG.Constants.LUMBER_DATA) do out[l.id] = true end
    return out
end

-- Prices are nil when nobody knows them, and an unknown part makes the whole
-- figure unknown (owner ruling 2026-10-31, test audit B7): a sum that leaves a
-- price out reads as a real price, too low, and the plan showed it as one.
local function addKnown(sum, part)
    if sum == nil or part == nil then return nil end
    return sum + part
end

local function netOf(sale, cost)
    if sale == nil or cost == nil then return nil end
    return sale - cost
end

-- Vendor sell-price via ItemNameResolver boundary (ADR-003b: no direct GetItemInfo in selectors).
-- mogul.plan declares session.itemNames.names; resolver bumps tick on drain -> re-ranking.
-- The resolver answers 0 for a cold cache and for an item vendors won't buy; neither is a price.
local function vendorSellPrice(itemID)
    local copper = HDG.ItemNameResolver:GetSellPrice(itemID)
    if copper > 0 then return copper end
    return nil  -- exception(nullable): cold item cache, or no vendor sell price
end

-- An item's price via PriceSource (TSM/Auctionator/Direct, then the Vendor:N list in
-- ReagentsDB). The one place a mat is priced: cost, marginal cost, mat spend and the
-- shopping list all read the unit _splitReagents stamps from it. nil = unpriced.
local function marketPrice(itemID)
    local p = HDG.PriceSource:GetItemPrice(itemID)
    if p and p > 0 then return p end
    return nil  -- exception(nullable): no price source knows this item
end

-- Sale price: the market first, then the vendor sell floor. nil = unpriced.
local function resolveSalePrice(itemID)
    local p = marketPrice(itemID)
    if p then return p end
    return vendorSellPrice(itemID)
end

-- Max crafts by the strictest per-tier lumber cap. `remainingLumber` holds every
-- lumber type (BuildPlan's budget is keyed by the same lumber set the scores split
-- on), so a lumber reagent always has an entry. Reagent quantities are positive
-- (a DecorDB guarantee test_mogul_plan checks over the shipped file).
local function lumberCap(score, remainingLumber)
    local cap = math.huge
    for _, lr in ipairs(score.lumberReagents) do
        local k = math.floor(remainingLumber[lr.id] / lr.qty)
        if k < cap then cap = k end
    end
    return cap
end

local function deductLumber(score, K, remainingLumber)
    for _, lr in ipairs(score.lumberReagents) do
        remainingLumber[lr.id] = remainingLumber[lr.id] - K * lr.qty
    end
end

local function totalLumberRemaining(remainingLumber)
    local sum = 0
    for _, n in pairs(remainingLumber) do sum = sum + n end
    return sum
end

-- `remainingMats` is the reagents still held: one entry per non-lumber reagent of
-- every candidate (BuildPlan's _ownedMats), so a scored mat always has one.
local function craftableWithOwned(score, remainingMats)
    local cap = math.huge
    for _, m in ipairs(score.nonLumberMats) do
        local k = math.floor(remainingMats[m.id] / m.qty)
        if k < cap then cap = k end
    end
    return cap
end

-- What the mats still to buy cost: the priced ones' sum, and whether every one has
-- a price. When one has none the sum is a floor (a price is never below 0).
local function marginalMatCost(score, remainingMats)
    local cost, allPriced = 0, true
    for _, m in ipairs(score.nonLumberMats) do
        local needToBuy = m.qty - remainingMats[m.id]
        if needToBuy > 0 and m.unit then
            cost = cost + needToBuy * m.unit
        elseif needToBuy > 0 then
            allPriced = false
        end
    end
    return cost, allPriced
end

-- ===== ScoreRecipe ==========================================================
-- Split slots into lumber/non-lumber; compute mat cost + ranking fields.
-- Lumberless recipes: lumberCost=0 (callers filter; Mogul is the lumber optimizer).

-- reagents = { [itemID] = { name, qty } } -- pairs, not ipairs. Each mat carries
-- its unit price (nil = unpriced); matCost is nil when any mat is unpriced.
local function _splitReagents(recipe, lumberSet)
    local split = { lumberCost = 0, bindingLumberQty = 0, lumberReagents = {},
                    matCost = 0, mats = {} }
    for itemID, info in pairs(recipe.reagents) do
        local qty = info.qty
        if lumberSet[itemID] then
            split.lumberCost = split.lumberCost + qty
            if qty > split.bindingLumberQty then split.bindingLumberQty = qty end
            split.lumberReagents[#split.lumberReagents + 1] = { id = itemID, qty = qty, name = info.name }
        else
            local unit = marketPrice(itemID)
            split.mats[#split.mats + 1] = { id = itemID, qty = qty, name = info.name, unit = unit }
            split.matCost = addKnown(split.matCost, unit and unit * qty)
        end
    end
    return split
end

-- recipe: a DecorDB entry (Candidates hands over only those); ctx.lumberSet: the
-- lumber IDs BuildPlan budgeted.
function Mogul:ScoreRecipe(recipe, ctx)
    local split = _splitReagents(recipe, ctx.lumberSet)
    local salePrice = resolveSalePrice(recipe.itemID)
    return {
        recipe            = recipe,
        lumberCost        = split.lumberCost,
        bindingLumberQty  = split.bindingLumberQty,
        lumberReagents    = split.lumberReagents,
        nonLumberMatCost  = split.matCost,
        nonLumberMats     = split.mats,
        salePrice         = salePrice,
        revenuePerCraft   = salePrice,
        netProfitPerCraft = netOf(salePrice, split.matCost),
    }
end

-- ===== BuildProfitPlan ======================================================
-- Greedy per-lumber profit picker. Supply Impact modes:
--   "off"    -- highest $/lumber wins, K crafts at once
--   "smooth" -- per-unit decay (1-decay)^(N-1); K forced to 1
--   "cap"    -- hard ceiling capN per recipe

-- Frugal K exponent: rank by effProfit / bindingLumberQty^3 so low-lumber crafts win.
-- K=3 means 10x-lumber needs ~1000x more profit (K=1.5 was too gentle).
local FRUGAL_K = 3

-- What one more craft earns under the optimizer setting, and whether that is known.
-- Lumber only: the sale. Lumber plus mats: the sale less the mats still to buy.
-- When one of those has no price the net is unknown: the recipe is still planned,
-- ranked by its sale (what is known) after every known net -- never as 0, never as
-- best (owner ruling 2026-10-31). nil = never planned: no sale price, or a loss
-- (known, or certain because the priced mats alone eat the sale).
local function _rankValue(s, planner)
    if s.salePrice == nil then return nil end  -- exception(nullable): no sale price, a runner-up
    if planner.optimizeBy == "lumberOnly" then return s.salePrice, true end
    local cost, allPriced = marginalMatCost(s, planner.remainingMats)
    if s.salePrice - cost <= 0 then return nil end
    if allPriced then return s.salePrice - cost, true end
    return s.salePrice, false
end

-- Per-lumber score for candidate s, and whether its net is known. nil =
-- disqualified (cap reached, no budget, never planned per _rankValue).
local function _scoreCandidate(s, planner)
    local already = planner.craftedSoFar[s.recipe.itemID] or 0  -- exception(nullable): sparse craft count, a miss = none yet
    if planner.siMode == "cap" and already >= planner.siCap then return nil end
    if lumberCap(s, planner.remainingLumber) < 1 then return nil end

    local value, known = _rankValue(s, planner)
    if value == nil then return nil end

    local lumberQty = math.max(1, s.bindingLumberQty)
    local divisor   = planner.frugal and (lumberQty ^ FRUGAL_K) or lumberQty
    local perLumber = value / divisor
    -- Smooth mode: discount by (1-decay)^already so each successive craft
    -- of the same recipe scores lower in the ranking.
    if planner.siMode == "smooth" and planner.siDecay > 0 then
        perLumber = perLumber * ((1 - planner.siDecay) ^ already)
    end
    return perLumber, known
end

-- A known net beats an unknown one whatever the scores; within a tier the higher
-- score wins, and a tie keeps the earlier (lower itemID) candidate.
local function _beats(score, known, bestScore, bestKnown)
    if known ~= bestKnown then return known end
    return score > bestScore
end

-- Return the highest-scoring candidate, or nil when none qualifies.
local function _pickBestCandidate(planner)
    local best, bestScore, bestKnown = nil, -math.huge, false
    for _, s in ipairs(planner.scored) do
        local perLumber, known = _scoreCandidate(s, planner)
        if perLumber and _beats(perLumber, known, bestScore, bestKnown) then
            best, bestScore, bestKnown = s, perLumber, known
        end
    end
    return best
end

-- Resolve K: clamp by craftable-with-owned + lumber budget + SI mode. nil when K<1.
local function _resolveCraftCount(best, planner)
    local craftWithOwned = craftableWithOwned(best, planner.remainingMats)
    local lc = lumberCap(best, planner.remainingLumber)
    local K  = math.min(math.max(craftWithOwned, 1), lc)
    if planner.siMode == "cap" then
        local already  = planner.craftedSoFar[best.recipe.itemID] or 0  -- exception(nullable): sparse craft count, a miss = none yet
        local headroom = planner.siCap - already
        if headroom < K then K = headroom end
    end
    if planner.siMode == "smooth" and K > 1 then K = 1 end
    if K < 1 then return nil end
    return K
end

-- One shopping line per bought mat, priced at the unit its score carries (the same
-- price the cost and the ranking used). An unpriced buy makes the spend unknown.
local function _recordBuy(ledger, m, buy)
    local line = ledger.bought[m.id]
    if not line then
        line = { id = m.id, qty = 0, unitPrice = m.unit }
        ledger.bought[m.id] = line
    end
    line.qty = line.qty + buy
    ledger.actualMatSpend = addKnown(ledger.actualMatSpend, m.unit and buy * m.unit)
end

-- Take K crafts' non-lumber mats from the reagents held first; buy only the shortfall.
local function _applyMatPurchase(best, K, ledger)
    for _, m in ipairs(best.nonLumberMats) do
        local need = K * m.qty
        local owned = ledger.remainingMats[m.id]
        local fromOwned = math.min(owned, need)
        ledger.remainingMats[m.id] = owned - fromOwned
        local buy = need - fromOwned
        if buy > 0 then _recordBuy(ledger, m, buy) end
    end
end

-- Merge K crafts of `best` into rows; same recipe coalesces (summed crafts).
local function _mergeIntoPlan(best, K, ledger)
    local itemID = best.recipe.itemID
    if ledger.merged[itemID] then
        ledger.rows[ledger.merged[itemID]].crafts =
            ledger.rows[ledger.merged[itemID]].crafts + K
    else
        ledger.rows[#ledger.rows + 1] = { recipe = best.recipe, crafts = K, score = best }
        ledger.merged[itemID] = #ledger.rows
    end
    ledger.craftedSoFar[itemID] = (ledger.craftedSoFar[itemID] or 0) + K  -- exception(nullable): sparse craft count, a miss = none yet
end

-- Commit K crafts of s, the one path both planners take: the lumber comes off the
-- budget, the mats it lacks are bought, the row is merged.
local function _commitCrafts(s, K, ledger)
    deductLumber(s, K, ledger.remainingLumber)
    _applyMatPurchase(s, K, ledger)
    _mergeIntoPlan(s, K, ledger)
end

-- The candidates arrive in table order (the known-recipe set is a hash), and the
-- planners break ties by list position, so they sort first: the same bags give the
-- same plan. itemID is the last key: unique, always present (a captured recipe can
-- lack a name) and the same in every locale.
local function _byItemID(a, b) return a.recipe.itemID < b.recipe.itemID end

-- Score every candidate; only lumber recipes enter the plan.
local function _scoreLumberRecipes(candidates, lumberSet)
    local scored = {}
    for _, recipe in ipairs(candidates) do
        local s = Mogul:ScoreRecipe(recipe, { lumberSet = lumberSet })
        if s.lumberCost > 0 then scored[#scored + 1] = s end
    end
    table.sort(scored, _byItemID)
    return scored
end

-- What both planners fill: the lumber and reagents left, the rows and the mats
-- bought. Crafts use the reagents held first, so the shopping list (and the spend)
-- is only the shortfall.
local function _newLedger(opts)
    return {
        remainingLumber = copyTable(opts.lumberBudgets),
        remainingMats   = copyTable(opts.ownedMats),      -- [itemID] = still held
        bought          = {},                             -- [itemID] = shopping line
        actualMatSpend  = 0,
        rows            = {},
        merged          = {},                             -- [itemID] = index into rows
        craftedSoFar    = {},                             -- [itemID] = total crafts (cap/smooth tracking)
    }
end

-- Profit planner: the ledger plus the candidates and the optimizer settings, all
-- from session.ui.mogul (supplyImpact's mode/smoothPct/capN always hold values:
-- the store seeds them and the editbox commits only a parsed number).
local function _newPlanner(opts, scored)
    local si = opts.supplyImpact
    local planner = _newLedger(opts)
    planner.scored     = scored
    planner.optimizeBy = opts.optimizeBy
    planner.frugal     = opts.frugal
    planner.siMode     = si.mode
    planner.siDecay    = si.smoothPct / 100
    planner.siCap      = si.capN
    return planner
end

-- Revenue is each planned craft at its sale price. Profit mode never plans an
-- unpriced sale, so there it is always known; collection mode plans by appearance,
-- and one unpriced decor makes its revenue unknown. The net is as known as both.
local function _planTotals(ledger, initialTotal)
    local revenue, crafts = 0, 0
    for _, row in ipairs(ledger.rows) do
        local sale = row.score.salePrice
        revenue = addKnown(revenue, sale and row.crafts * sale)
        crafts  = crafts + row.crafts
    end
    return {
        revenue      = revenue,
        netProfit    = netOf(revenue, ledger.actualMatSpend),
        lumberUsed   = initialTotal - totalLumberRemaining(ledger.remainingLumber),
        lumberBudget = initialTotal,
        crafts       = crafts,
        matSpend     = ledger.actualMatSpend,
    }
end

-- Dearest first; an unpriced line can't claim a place by cost, so it sorts last.
-- Ties (and unpriced lines) by itemID, so the order is the same every run.
local function _byTotalCostDesc(a, b)
    if a.totalCost == b.totalCost then return a.id < b.id end
    if a.totalCost == nil or b.totalCost == nil then return b.totalCost == nil end
    return a.totalCost > b.totalCost
end

local function _shoppingList(ledger)
    local list = {}
    for _, line in pairs(ledger.bought) do
        line.totalCost = line.unitPrice and line.qty * line.unitPrice
        list[#list + 1] = line
    end
    table.sort(list, _byTotalCostDesc)
    return list
end

local function _byRevenueDesc(a, b)
    local ra, rb = a.crafts * a.score.salePrice, b.crafts * b.score.salePrice
    if ra == rb then return a.recipe.itemID < b.recipe.itemID end
    return ra > rb
end

local function BuildProfitPlan(opts)
    local planner = _newPlanner(opts, _scoreLumberRecipes(opts.candidates, opts.lumberSet))
    local initialTotal = totalLumberRemaining(planner.remainingLumber)

    while true do
        local best = _pickBestCandidate(planner)
        if not best then break end
        local K = _resolveCraftCount(best, planner)
        if not K then break end
        _commitCrafts(best, K, planner)
    end

    local totals = _planTotals(planner, initialTotal)
    table.sort(planner.rows, _byRevenueDesc)
    return { rows = planner.rows, totals = totals, shoppingList = _shoppingList(planner),
             candidates = planner.scored }
end

-- ===== BuildCollectionPlan ==================================================
-- Prioritize uncollected decor crafts. Round-robin within tier (1 craft per pick, re-evaluate)
-- so the player discovers more unique items rather than maxing one recipe.

-- Collection order: cheapest lumber first, so a tight budget reaches the most new
-- appearances (one craft each, smallest costs first, fits the most recipes), then
-- itemID (see _byItemID).
local function _byLumberCostThenItemID(a, b)
    if a.lumberCost == b.lumberCost then return a.recipe.itemID < b.recipe.itemID end
    return a.lumberCost < b.lumberCost
end

-- Score uncollected recipes only. Skips zero-lumber + already-owned.
local function _scoreUncollectedRecipes(candidates, lumberSet, byItemID)
    local scored = {}
    for _, recipe in ipairs(candidates) do
        local s = Mogul:ScoreRecipe(recipe, { lumberSet = lumberSet })
        if s.lumberCost > 0 then
            local obsRow = byItemID[recipe.itemID]
            if not HDG.HousingCatalogObserver:IsOwned(obsRow) then
                s.uncollected = true
                scored[#scored + 1] = s
            end
        end
    end
    table.sort(scored, _byLumberCostThenItemID)
    return scored
end

-- Round-robin: one craft per affordable recipe per pass (scored order), each one
-- committed like a profit craft (lumber, mats bought, row). Stops when none fits.
local function _allocateRoundRobin(scored, ledger)
    while true do
        local anyCraft = false
        for _, s in ipairs(scored) do
            if lumberCap(s, ledger.remainingLumber) >= 1 then
                _commitCrafts(s, 1, ledger)
                anyCraft = true
            end
        end
        if not anyCraft then break end
    end
end

-- Display order: by name; a recipe captured without one sorts after the named ones,
-- and equal names by itemID.
local function _byRecipeName(a, b)
    local an, bn = a.recipe.name, b.recipe.name
    if an == bn then return a.recipe.itemID < b.recipe.itemID end
    if an == nil or bn == nil then return bn == nil end  -- exception(nullable): a capture saved without a name
    return an < bn
end

local function BuildCollectionPlan(opts)
    local scored = _scoreUncollectedRecipes(opts.candidates, opts.lumberSet,
        HDG.HousingCatalogObserver.byItemID)
    local ledger = _newLedger(opts)
    local initialTotal = totalLumberRemaining(ledger.remainingLumber)
    _allocateRoundRobin(scored, ledger)

    local totals = _planTotals(ledger, initialTotal)
    totals.uniqueDiscoveries = #ledger.rows
    table.sort(ledger.rows, _byRecipeName)
    return { rows = ledger.rows, totals = totals, shoppingList = _shoppingList(ledger),
             candidates = scored }
end

-- ===== Candidate builders ===================================================
-- char: the logged-in character's known recipes. account: those plus every non-hidden
-- alt's. Both come from recipes.knowledge (mine / alts sets of crafted itemIDs, the one
-- place "known" is decided). Each recipe is read from recipes.db, as Materials reads it:
-- the shipped seed with the player's scanned reagents laid over it. knowledge derives
-- its sets from recipes.db, so every known itemID has an entry. mogul.plan declares
-- both calls.
local NOTHING_SKIPPED = {}

-- Append the recipe for each known itemID not in `skip` (the alts pass skips mine).
local function _appendCandidates(out, knownSet, recipes, skip)
    for itemID in pairs(knownSet) do
        if not skip[itemID] then out[#out + 1] = recipes[itemID] end
    end
end

-- viewMode: "char" | "account" (session.ui.mogul.viewMode). Unordered: the planners sort.
function Mogul:Candidates(viewMode)
    local state     = HDG.Store:GetState()
    local knowledge = HDG.Selectors:Call("recipes.knowledge", state)
    local recipes   = HDG.Selectors:Call("recipes.db", state)
    local out = {}
    _appendCandidates(out, knowledge.mine, recipes, NOTHING_SKIPPED)
    if viewMode == "account" then
        _appendCandidates(out, knowledge.alts, recipes, knowledge.mine)
    end
    return out
end

-- ===== BuildPlan (public dispatch) ==========================================

-- Lumber held of every type: bags, bank, reagent bank and warband (GetTotal counts
-- all four; GetCounts would miss bank-only lumber). One key per lumber type, so the
-- planners read the budget strictly.
local function _lumberBudgets(lumberSet)
    local budgets = {}
    for itemID in pairs(lumberSet) do budgets[itemID] = HDG.BagObserver:GetTotal(itemID) end
    return budgets
end

-- The reagents held, counted the way Materials counts them (BagObserver:GetCounts:
-- bags, bank, reagent bank and warband, any quality). One entry per non-lumber
-- reagent of every candidate, so the planners read it strictly.
local function _ownedMats(candidates, lumberSet)
    local counts, owned = HDG.BagObserver:GetCounts(), {}
    for _, recipe in ipairs(candidates) do
        for itemID in pairs(recipe.reagents) do
            if not lumberSet[itemID] then owned[itemID] = counts[itemID] end
        end
    end
    return owned
end

local PLANNERS = { profit = BuildProfitPlan, collection = BuildCollectionPlan }

-- opts: the mogul.plan selector's settings from session.ui.mogul -- mode, viewMode,
-- optimizeBy, frugal, supplyImpact. The known recipes, the lumber and the reagents
-- held are read from live state here. A mode with no planner is a bug: fail loud.
function Mogul:BuildPlan(opts)
    local planner = PLANNERS[opts.mode]
    if not planner then error("Mogul:BuildPlan: no planner for mode " .. tostring(opts.mode), 2) end
    opts.lumberSet     = lumberSetFromConstants()
    opts.lumberBudgets = _lumberBudgets(opts.lumberSet)
    opts.candidates    = self:Candidates(opts.viewMode)
    opts.ownedMats     = _ownedMats(opts.candidates, opts.lumberSet)
    return planner(opts)
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "Mogul",
    dependencies = {},  -- pure stateless transform; no event subscriptions
})
