-- HDG.Goblin
-- ============================================================================
-- Per-decor profit analysis engine. Walks HDGR_DecorDB, prices
-- each recipe via HDG.PriceSource, and computes the seven derived metrics
-- the Goblin profit table needs:
--   * sellPrice       -- AH/TSM price of the crafted item
--   * materialCost    -- sum of non-lumber, non-BoP reagent prices * qty
--   * profit          -- sellPrice - materialCost
--   * margin          -- profit / sellPrice * 100  (percentage)
--   * lumberQty       -- total lumber units consumed per craft
--   * lumberType      -- itemID of the dominant lumber for this recipe
--   * lumberValue     -- profit / lumberQty (gold per lumber unit)
-- Plus TSM-gated velocity + live-supply columns:
--   * saleRate        -- TSM sale rate x1000 (per-mille; % of postings that sell; "Rate")
--   * soldPerDay      -- TSM region units/day, real value (fractional for slow decor; "/Day")
--   * ahQty           -- units currently listed (Direct scan; "#AH")
--
-- Pure function: same DB state -> same output. Invalidation at the selector
-- layer (session.resolvers.prices.tick, recipes.knowledge, etc.). No caching: O(n=305)
-- with ~5 PriceSource calls each; profile <8ms fresh boot.

HDG = HDG or {}
HDG.Goblin = HDG.Goblin or {}
local G = HDG.Goblin

-- ===== Lumber lookup table ==================================================
-- Built lazily on first BuildProfitData call. LUMBER_DATA stays here: Goblin-specific reagent-set data.

local _lumberSet           -- [itemID] = LUMBER_DATA entry (for the lumber reagent test)

local function ensureLookups()
    if _lumberSet then return end
    _lumberSet = {}
    for _, l in ipairs(HDG.Constants.LUMBER_DATA or {}) do
        _lumberSet[l.id] = l
    end
end

-- Convert a recipe's "Cataclysm Alchemy" / "Dragon Isles Cooking" string
-- to the canonical display name. Tries HDG.Expansion.NormalizeAlias for
-- exact matches (covers display / api / abbr / short / localized forms),
-- then falls back to a longest-prefix walk over EXPANSION_DATA so a string
-- like "Dragon Isles Cooking" still resolves to "Dragonflight" via the
-- "Dragon Isles" api prefix.
function G:NormalizeExpansion(raw)
    if type(raw) ~= "string" or raw == "" then return "Unknown" end
    local exact = HDG.Expansion.NormalizeAlias(raw)
    if exact then return exact end
    -- Longest-prefix match against api + display names. n=13, trivially
    -- cheap; preserves the multi-word "Dragon Isles" / "Khaz Algar" cases.
    local bestMatch, bestLen = nil, 0
    for _, entry in HDG.Expansion.Each() do
        local api = entry.api
        if api and raw:sub(1, #api) == api and #api > bestLen then
            bestMatch = entry; bestLen = #api
        end
        local display = entry.display
        if display and raw:sub(1, #display) == display and #display > bestLen then
            bestMatch = entry; bestLen = #display
        end
    end
    return bestMatch and bestMatch.display or "Unknown"
end

-- ===== Per-recipe scoring ===================================================
-- Compute the seven profit metrics for a single recipe entry. Returns nil
-- when the recipe is unscoreable (no reagents, no output item, etc.) --
-- caller filters nils. salePrice nil is OK and means "no price source
-- returned a value" (fall back to displaying "?").

function G:ScoreRecipe(recipe)
    if not (recipe and recipe.itemID and recipe.reagents) then return nil end
    ensureLookups()

    -- HDG.PriceSource is load-order-guaranteed by the time Goblin runs
    -- (Modules:Declare lists PriceSource as a dependency). Strict reads.
    local PS = HDG.PriceSource
    local sellPrice, priceSource = PS:GetItemPrice(recipe.itemID)

    local materialCost = 0
    local lumberQty    = 0
    local lumberType   = nil
    local hasAllPrices = true
    for reagentID, info in pairs(recipe.reagents) do
        local qty = info.qty or 1  -- migration (legacy recipe reagents without qty)
        if _lumberSet[reagentID] then
            lumberQty = lumberQty + qty
            -- Pick the highest-qty lumber as the dominant type. Recipes
            -- with mixed lumber are very rare but the engine handles them.
            if not lumberType or qty > (recipe.reagents[lumberType].qty or 0) then
                lumberType = reagentID
            end
        else
            local matPrice = PS:GetItemPrice(reagentID)
            if matPrice and matPrice > 0 then
                materialCost = materialCost + matPrice * qty
            else
                hasAllPrices = false
            end
        end
    end

    local profit, margin, lumberValue
    if sellPrice then
        profit = sellPrice - materialCost
        if sellPrice > 0 then margin = profit / sellPrice * 100 end
        if lumberQty > 0 then lumberValue = profit / lumberQty end
    end

        -- Raw TSM prices (all 3 shown side-by-side when TSM loaded).
    -- tsmPct = margin vs region sale avg (cross-realm value); distinct from `margin` (preferred source).
    local tsmMin, tsmMarket, tsmRegion, tsmPct, saleRate, soldPerDay
    if PS:IsTSMAvailable() then
        tsmMin    = PS:GetTSMMinBuyout(recipe.itemID)
        tsmMarket = PS:GetTSMMarket(recipe.itemID)
        tsmRegion = PS:GetRegionSaleAvg(recipe.itemID)
        if tsmRegion and tsmRegion > 0 then
            tsmPct = (tsmRegion - materialCost) / tsmRegion * 100
        end
        saleRate   = PS:GetRegionSaleRate(recipe.itemID)    -- "Rate" column
        soldPerDay = PS:GetRegionSoldPerDay(recipe.itemID)  -- "/Day" column
    end
    -- #AH column: units currently listed (Direct scan; source-independent of TSM).
    local ahQty = PS:GetDirectQty(recipe.itemID)

    return {
        itemID        = recipe.itemID,
        spellID       = recipe.spellID,
        name          = recipe.name,
        profession    = recipe.profession or "Unknown",
        expansion     = self:NormalizeExpansion(recipe.expansion),
        sellPrice     = sellPrice,
        priceSource   = priceSource,
        materialCost  = materialCost,
        profit        = profit,
        margin        = margin,
        lumberQty     = lumberQty,
        lumberType    = lumberType,
        lumberValue   = lumberValue,
        hasAllPrices  = hasAllPrices,
        tsmMin        = tsmMin,
        tsmMarket     = tsmMarket,
        tsmRegion     = tsmRegion,
        tsmPct        = tsmPct,
        saleRate      = saleRate,
        soldPerDay    = soldPerDay,
        ahQty         = ahQty,
    }
end

-- ===== BuildProfitData ======================================================
-- Walks every recipe in HDGR_DecorDB, scores each one, returns the list.

-- db: the merged recipe DB (seed <- runtime reagent override), itemID-keyed, from
-- the recipes.db selector. Callers (goblin.rows selector, HouseAggregator) pass it so
-- profit reflects 12.1's captured reagents; iterating values ignores the key.
function G:BuildProfitData(db)
    local out = {}
    if type(db) ~= "table" then return out end  -- exception(boundary): public module API, db is caller-supplied
    for _, recipe in pairs(db) do
        local row = self:ScoreRecipe(recipe)
        if row then out[#out + 1] = row end
    end
    return out
end

-- ===== Module registration =================================================
-- No Blizzard events: pure consumer of HDGR_DecorDB + HDG.PriceSource.
HDG.Modules:Declare({
    name = "Goblin",
    dependencies = { "PriceSource" },
})
