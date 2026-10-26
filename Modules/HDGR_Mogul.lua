-- HDG.Mogul
-- ============================================================================
-- Pure-function craft optimizer engine. Stateless. Unit-testable.
-- Adapted from HDG_Mogul.lua to HDG's data model:
--   * Recipes from HDGR_ProfessionsDB (keyed by recipeID, .slots = list of
--     {type, itemID, qty} with type == "basic" for raw reagents)
--   * Lumber set from HDG.Constants.LUMBER_DATA
--   * Known recipes from recipes.knowledge (mine / alts), derived from
--     account.characters[K].professions[P].knownRecipes (recipeID -> true)
--   * Owned decor from account.collection.ownedDecorIDs (for Collection mode)
--
-- Two modes:
--   profit     -- rank by gold-per-lumber (vendor sell price); pick highest
--                 expected revenue per bottleneck lumber unit
--   collection -- prioritize crafts producing UNCOLLECTED decor items; ignore
--                 gold value; round-robin within tier to diversify
--
-- Two views (drives which chars contribute the candidate-recipe set):
--   char       -- current char's knownRecipes only
--   account    -- union of all non-hidden chars' knownRecipes (and mark the
--                 best alt per recipe so the UI can hint "log into Slamz")

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
    local data = HDG.Constants.LUMBER_DATA
    if type(data) == "table" then
        for _, l in ipairs(data) do
            if l.id then out[l.id] = true end
        end
    end
    return out
end

-- Resolve a vendor sell price for an item via the WoW client cache.
-- Vendor sell-price via ItemNameResolver boundary (ADR-003b: no direct GetItemInfo in selectors).
-- mogul.plan declares session.itemNames.names; resolver bumps tick on drain -> re-ranking.
-- Returns 0 when uncached (mogul treats 0 as "ineligible").
local function vendorSellPrice(itemID)
    return HDG.ItemNameResolver:GetSellPrice(itemID)
end

-- Sale price: PriceSource (AH/TSM) first, then vendor floor fallback.
local function resolveSalePrice(itemID, override)
    if override and override > 0 then return override end
    local p = HDG.PriceSource:GetItemPrice(itemID)
    if p and p > 0 then return p end
    return vendorSellPrice(itemID)
end

-- Material price via PriceSource (no vendor fallback; Vendor:N in ReagentsDB handled by GetItemPrice).
local function resolveMatPrice(itemID, override)
    if override and override > 0 then return override end
    local p = HDG.PriceSource:GetItemPrice(itemID)
    if p and p > 0 then return p end
    return 0
end

-- Max crafts by the strictest per-tier lumber cap. `remainingLumber` is a sparse map
-- (missing key = 0 held) -- `t[k] or 0` is the canonical idiom, not a defensive guard.
local function lumberCap(score, remainingLumber)
    if #score.lumberReagents == 0 then return math.huge end
    local cap = math.huge
    for _, lr in ipairs(score.lumberReagents) do
        if lr.qty > 0 then
            local have = remainingLumber[lr.id] or 0  -- exception(boundary): sparse map
            local k = math.floor(have / lr.qty)
            if k < cap then cap = k end
        end
    end
    return cap
end

local function deductLumber(score, K, remainingLumber)
    for _, lr in ipairs(score.lumberReagents) do
        local have = remainingLumber[lr.id] or 0      -- exception(boundary): sparse map
        remainingLumber[lr.id] = have - K * lr.qty
    end
end

local function totalLumberRemaining(remainingLumber)
    local sum = 0
    for _, n in pairs(remainingLumber) do sum = sum + n end
    return sum
end

local function craftableWithOwned(score, remainingMats)
    if #score.nonLumberMats == 0 then return math.huge end
    local cap = math.huge
    for _, m in ipairs(score.nonLumberMats) do
        if m.qty > 0 then
            local owned = remainingMats[m.id] or 0  -- exception(boundary): sparse map
            local k = math.floor(owned / m.qty)
            if k < cap then cap = k end
        end
    end
    return cap
end

local function marginalMatCost(score, remainingMats, matPrices)
    local cost = 0
    for _, m in ipairs(score.nonLumberMats) do
        local owned = remainingMats[m.id] or 0      -- exception(boundary): sparse map
        local needToBuy = m.qty - owned
        if needToBuy > 0 then
            cost = cost + needToBuy * (matPrices[m.id] or 0)
        end
    end
    return cost
end

-- ===== ScoreRecipe ==========================================================
-- Split slots into lumber/non-lumber; compute mat cost + ranking fields.
-- Lumberless recipes: lumberCost=0 (callers filter; Mogul is the lumber optimizer).

function Mogul:ScoreRecipe(recipe, ctx)
    if not (recipe and recipe.reagents) then return nil end
    local lumberSet = ctx.lumberSet or lumberSetFromConstants()
    local matPrices = ctx.matPrices or {}
    local salePrices = ctx.salePrices or {}

    local lumberCost = 0
    local bindingLumberQty = 0
    local lumberReagents = {}
    local nonLumberMatCost = 0
    local nonLumberMats = {}

    -- reagents = { [itemID] = { name, qty } } -- pairs, not ipairs.
    for itemID, info in pairs(recipe.reagents) do
        local qty = info.qty or 0   -- migration (defensive against bad recipe data)
        if qty > 0 then
            if lumberSet[itemID] then
                lumberCost = lumberCost + qty
                if qty > bindingLumberQty then bindingLumberQty = qty end
                lumberReagents[#lumberReagents + 1] = { id = itemID, qty = qty, name = info.name }
            else
                nonLumberMats[#nonLumberMats + 1] = { id = itemID, qty = qty, name = info.name }
                local price = resolveMatPrice(itemID, matPrices[itemID])
                nonLumberMatCost = nonLumberMatCost + price * qty
            end
        end
    end

    local salePrice = resolveSalePrice(recipe.itemID, salePrices[recipe.itemID])
    return {
        recipe            = recipe,
        lumberCost        = lumberCost,
        bindingLumberQty  = bindingLumberQty,
        lumberReagents    = lumberReagents,
        nonLumberMatCost  = nonLumberMatCost,
        nonLumberMats     = nonLumberMats,
        salePrice         = salePrice,
        revenuePerCraft   = salePrice,
        netProfitPerCraft = salePrice - nonLumberMatCost,
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

-- Per-lumber score for candidate s. nil = disqualified (cap reached, no budget, effProfit <= 0).
local function _scoreCandidate(s, planner)
    local already = planner.craftedSoFar[s.recipe.itemID] or 0
    if planner.siMode == "cap" and already >= planner.siCap then return nil end
    if lumberCap(s, planner.remainingLumber) < 1 then return nil end

    local marginal = marginalMatCost(s, planner.remainingMats, planner.matPrices)
    local effProfit = (planner.optimizeBy == "lumberOnly")
        and s.salePrice
        or  (s.salePrice - marginal)
    if effProfit <= 0 then return nil end

    local lumberQty = math.max(1, s.bindingLumberQty)
    local divisor   = planner.frugal and (lumberQty ^ FRUGAL_K) or lumberQty
    local perLumber = effProfit / divisor
    -- Smooth mode: discount by (1-decay)^already so each successive craft
    -- of the same recipe scores lower in the ranking.
    if planner.siMode == "smooth" and planner.siDecay > 0 then
        perLumber = perLumber * ((1 - planner.siDecay) ^ already)
    end
    return perLumber
end

-- Return the highest-scoring candidate, or nil when nothing beats -inf.
local function _pickBestCandidate(planner)
    local bestScore, best = -math.huge, nil
    for _, s in ipairs(planner.scored) do
        local perLumber = _scoreCandidate(s, planner)
        if perLumber and perLumber > bestScore then
            bestScore, best = perLumber, s
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
        local already  = planner.craftedSoFar[best.recipe.itemID] or 0
        local headroom = planner.siCap - already
        if headroom < K then K = headroom end
    end
    if planner.siMode == "smooth" and K > 1 then K = 1 end
    if K < 1 then return nil end
    return K
end

-- Deduct K crafts' non-lumber mats from owned stock; track buys for shortfall.
local function _applyMatPurchase(best, K, planner)
    for _, m in ipairs(best.nonLumberMats) do
        local need = K * m.qty
        local owned = planner.remainingMats[m.id] or 0  -- exception(boundary): sparse map
        local fromOwned = math.min(owned, need)
        planner.remainingMats[m.id] = owned - fromOwned
        local buy = need - fromOwned
        if buy > 0 then
            planner.matsBoughtPerID[m.id] = (planner.matsBoughtPerID[m.id] or 0) + buy
            planner.actualMatSpend = planner.actualMatSpend
                + buy * (planner.matPrices[m.id] or 0)
        end
    end
end

-- Merge K crafts of `best` into rows; same recipe coalesces (summed crafts).
local function _mergeIntoPlan(best, K, planner)
    local itemID = best.recipe.itemID
    if planner.merged[itemID] then
        planner.rows[planner.merged[itemID]].crafts =
            planner.rows[planner.merged[itemID]].crafts + K
    else
        planner.rows[#planner.rows + 1] = { recipe = best.recipe, crafts = K, score = best }
        planner.merged[itemID] = #planner.rows
    end
    planner.craftedSoFar[itemID] = (planner.craftedSoFar[itemID] or 0) + K
end

local function BuildProfitPlan(opts)
    local lumberBudgets = opts.lumberBudgets or {}
    local candidates    = opts.candidates    or {}
    local ownedMats     = opts.ownedMats     or {}
    local matPrices     = opts.matPrices     or {}
    local lumberSet     = opts.lumberSet     or lumberSetFromConstants()
    local salePrices    = opts.salePrices    or {}

    -- Supply Impact settings (defaults = "off" / 7% / cap=10); fields optional.
    local si = opts.supplyImpact or {}                    -- exception(boundary): config defaults

    local scored = {}
    for _, recipe in ipairs(candidates) do
        local s = Mogul:ScoreRecipe(recipe, {
            lumberSet = lumberSet, matPrices = matPrices, salePrices = salePrices
        })
        if s and s.lumberCost > 0 then scored[#scored + 1] = s end
    end

    local remainingLumber = copyTable(lumberBudgets)
    local initialTotal    = totalLumberRemaining(remainingLumber)

    -- Planner state: shared across iteration helpers; mutated by _applyMatPurchase + _mergeIntoPlan.
    local planner = {
        scored          = scored,
        remainingLumber = remainingLumber,
        remainingMats   = copyTable(ownedMats),
        matPrices       = matPrices,
        matsBoughtPerID = {},
        actualMatSpend  = 0,
        rows            = {},
        merged          = {},
        craftedSoFar    = {},                             -- [itemID] = total crafts (cap/smooth tracking)
        optimizeBy      = opts.optimizeBy or "lumberOnly",
        frugal          = opts.frugal == true,
        siMode          = si.mode      or "off",  -- exception(optional): smoothing config field default
        siDecay         = (si.smoothPct or 7) / 100,  -- exception(optional): smoothing config field default
        siCap           = si.capN      or 10,  -- exception(optional): smoothing config field default
    }

    while true do
        local best = _pickBestCandidate(planner)
        if not best then break end
        local K = _resolveCraftCount(best, planner)
        if not K then break end
        deductLumber(best, K, planner.remainingLumber)
        _applyMatPurchase(best, K, planner)
        _mergeIntoPlan(best, K, planner)
    end

    -- Extract post-loop accumulators.
    local matsBoughtPerID = planner.matsBoughtPerID
    local actualMatSpend  = planner.actualMatSpend
    local rows            = planner.rows

    local totalRevenue, totalCrafts = 0, 0
    for _, row in ipairs(rows) do
        totalRevenue = totalRevenue + row.crafts * row.score.salePrice
        totalCrafts  = totalCrafts + row.crafts
    end
    local lumberRemaining = totalLumberRemaining(remainingLumber)
    local totals = {
        revenue      = totalRevenue,
        netProfit    = totalRevenue - actualMatSpend,
        lumberUsed   = initialTotal - lumberRemaining,
        lumberBudget = initialTotal,
        crafts       = totalCrafts,
        matSpend     = actualMatSpend,
    }
    table.sort(rows, function(a, b)
        return a.crafts * a.score.salePrice > b.crafts * b.score.salePrice
    end)

    local shoppingList = {}
    for matID, qty in pairs(matsBoughtPerID) do
        local unit = resolveMatPrice(matID, matPrices[matID])
        shoppingList[#shoppingList + 1] = {
            id = matID, qty = qty,
            unitPrice = unit,
            totalCost = qty * unit,
        }
    end
    table.sort(shoppingList, function(a, b) return a.totalCost > b.totalCost end)

    return { rows = rows, totals = totals, shoppingList = shoppingList, candidates = scored }
end

-- ===== BuildCollectionPlan ==================================================
-- Prioritize uncollected decor crafts. Round-robin within tier (1 craft per pick, re-evaluate)
-- so the player discovers more unique items rather than maxing one recipe.

-- Score uncollected recipes only. Skips zero-lumber + already-owned.
local function _scoreUncollectedRecipes(candidates, lumberSet, byItemID)
    local scored = {}
    for _, recipe in ipairs(candidates) do
        local s = Mogul:ScoreRecipe(recipe, { lumberSet = lumberSet })
        if s and s.lumberCost > 0 then
            local obsRow = byItemID[recipe.itemID]
            if not HDG.HousingCatalogObserver:IsOwned(obsRow) then
                s.uncollected = true
                scored[#scored + 1] = s
            end
        end
    end
    return scored
end

-- Allocate ONE craft if affordable; merge repeats by itemID. Returns true on success.
local function _tryCraftOne(s, rows, merged, remainingLumber)
    if lumberCap(s, remainingLumber) < 1 then return false end
    deductLumber(s, 1, remainingLumber)
    local idx = merged[s.recipe.itemID]
    if idx then
        rows[idx].crafts = rows[idx].crafts + 1
    else
        rows[#rows + 1] = { recipe = s.recipe, crafts = 1, score = s }
        merged[s.recipe.itemID] = #rows
    end
    return true
end

-- Round-robin: one craft per affordable recipe per pass (scored order). Stops when none can craft.
local function _allocateRoundRobin(scored, remainingLumber)
    local rows, merged = {}, {}
    while true do
        local anyCraft = false
        for _, s in ipairs(scored) do
            if _tryCraftOne(s, rows, merged, remainingLumber) then anyCraft = true end
        end
        if not anyCraft then break end
    end
    return rows
end

-- Aggregate plan totals from the allocated rows.
local function _summarizePlan(rows, initialTotal, remainingLumber)
    local totalCrafts, uniqueDiscoveries = 0, 0
    for _, row in ipairs(rows) do
        totalCrafts = totalCrafts + row.crafts
        uniqueDiscoveries = uniqueDiscoveries + 1
    end
    return {
        revenue           = 0,
        netProfit         = 0,
        lumberUsed        = initialTotal - totalLumberRemaining(remainingLumber),
        lumberBudget      = initialTotal,
        crafts            = totalCrafts,
        matSpend          = 0,
        uniqueDiscoveries = uniqueDiscoveries,
    }
end

local function BuildCollectionPlan(opts)
    local lumberBudgets = opts.lumberBudgets or {}
    local candidates    = opts.candidates    or {}
    local lumberSet     = opts.lumberSet     or lumberSetFromConstants()
    -- ownedDecorIDs now via R:IsOwned (canonical helper).
    local byItemID      = HDG.HousingCatalogObserver.byItemID

    local scored          = _scoreUncollectedRecipes(candidates, lumberSet, byItemID)
    local remainingLumber = copyTable(lumberBudgets)
    local initialTotal    = totalLumberRemaining(remainingLumber)
    local rows            = _allocateRoundRobin(scored, remainingLumber)
    local totals          = _summarizePlan(rows, initialTotal, remainingLumber)

    table.sort(rows, function(a, b) return a.recipe.name < b.recipe.name end)
    return { rows = rows, totals = totals, shoppingList = {}, candidates = scored }
end

-- ===== DecorDB reverse indexes =============================================
-- byOutputItemID: output itemID -> decor entry (char-view knowledge join).
-- bySpellID: for alt-knowledge join (char.professions[P].knownRecipes keyed by spellID).
local _decorByOutputItemID
local function decorByOutputItemID()
    if _decorByOutputItemID then return _decorByOutputItemID end
    _decorByOutputItemID = {}
    local db = HDG.StaticData.Recipes:GetAll()
    if type(db) ~= "table" then return _decorByOutputItemID end
    for _, entry in pairs(db) do
        if entry.itemID then _decorByOutputItemID[entry.itemID] = entry end
    end
    return _decorByOutputItemID
end
-- Public accessor: lazy O(1) itemID -> decor-entry (ADR-003a carve-out; called from goblin.* selectors).
function Mogul:GetDecorByOutputItemID() return decorByOutputItemID() end

-- ===== Candidate builders ===================================================
-- char: the logged-in character's known recipes. account: those plus every non-hidden
-- alt's. Both come from recipes.knowledge (mine / alts sets of crafted itemIDs); mogul.plan
-- declares the call.
local NOTHING_SKIPPED = {}

-- Append the decor entry for each known itemID not in `skip` (the alts pass skips mine).
local function _appendCandidates(out, knownSet, idx, skip)
    for itemID in pairs(knownSet) do
        local decor = idx[itemID]
        if decor and decor.spellID and decor.reagents and not skip[itemID] then
            out[#out + 1] = decor
        end
    end
end

function Mogul:Candidates(viewMode)
    viewMode = viewMode or "char"
    local knowledge = HDG.Selectors:Call("recipes.knowledge", HDG.Store:GetState())
    local idx = decorByOutputItemID()
    local out = {}
    _appendCandidates(out, knowledge.mine, idx, NOTHING_SKIPPED)
    if viewMode == "account" then
        _appendCandidates(out, knowledge.alts, idx, knowledge.mine)
    end
    return out
end

-- BestAltForSpellID: first non-hidden alt who knows the recipe. Nil if none.
-- _charKnowsRecipe: true if any of this char's professions lists spellID.
local function _charKnowsRecipe(char, spellID)
    if type(char.professions) ~= "table" then return false end
    for _, prof in pairs(char.professions) do
        if prof.knownRecipes and prof.knownRecipes[spellID] then
            return true
        end
    end
    return false
end

function Mogul:BestAltForSpellID(spellID)
    local state = HDG.Store:GetState()
    local chars = state.account.characters
    local current = HDG.SessionIdentity.GetCharKey(state)
    for charKey, char in pairs(chars) do
        if charKey ~= current and not char.hidden and _charKnowsRecipe(char, spellID) then
            return charKey
        end
    end
    return nil
end

-- All non-current, non-hidden alts who know spellID (sorted display names for tooltip).
function Mogul:AltsKnowingSpellID(spellID)
    local state   = HDG.Store:GetState()
    local current = HDG.SessionIdentity.GetCharKey(state)
    local names   = {}
    for charKey, char in pairs(state.account.characters) do
        if charKey ~= current and not char.hidden and _charKnowsRecipe(char, spellID) then
            names[#names + 1] = char.name or (charKey:match("^([^%-]+)") or charKey)
        end
    end
    table.sort(names)
    return names
end

-- ===== BuildPlan (public dispatch) ==========================================

function Mogul:BuildPlan(opts)
    opts = opts or {}
    local mode = opts.mode or "profit"
    local viewMode = opts.viewMode or "char"
    if not opts.candidates then
        opts.candidates = self:Candidates(viewMode)
    end

    -- Default lumber budget: BagObserver:GetTotal covers bag + bank + reagent bank + warband.
    -- GetCounts() would miss bank-only lumber.
    if not opts.lumberBudgets then
        opts.lumberBudgets = {}
        local lumberSet = lumberSetFromConstants()
        for itemID, _ in pairs(lumberSet) do
            opts.lumberBudgets[itemID] = HDG.BagObserver
                and HDG.BagObserver:GetTotal(itemID) or 0
        end
    end

    if not opts.ownedDecorIDs then
        local state = HDG.Store:GetState()
        opts.ownedDecorIDs = state.account.collection.ownedDecorIDs or {}
    end
    -- Supply Impact: read from state if not provided by caller.
    if not opts.supplyImpact then
        local state = HDG.Store:GetState()
        opts.supplyImpact = state.session.ui.mogul.supplyImpact
            or { mode = "off", smoothPct = 7, capN = 10 }
    end

    -- Frugal: read from state if caller didn't pass it. Default false.
    if opts.frugal == nil then
        local state = HDG.Store:GetState()
        opts.frugal = state.session.ui.mogul.frugal == true
    end

    if mode == "collection" then
        return BuildCollectionPlan(opts)
    end
    return BuildProfitPlan(opts)
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "Mogul",
    dependencies = {},  -- pure stateless transform; no event subscriptions
})
