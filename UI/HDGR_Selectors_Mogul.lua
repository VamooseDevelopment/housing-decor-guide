-- HDG.Selectors -- Mogul tab
-- ============================================================================
-- Wraps HDG.Mogul:BuildPlan. plan-rows is the single heavy producer;
-- smaller selectors (title, totals, button booleans) compose cheaply.

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors

-- Locale-correct display name: resolver (catalog/live API) wins; baked English is the fallback.
-- Callers MUST read "session.itemNames.names" so the async resolve re-fires them.
local _localName = HDG.Format.LocalItemName  -- hygiene A16

-- Mogul tab grows to 950px when Goblin sub-view is active AND TSM is the effective
-- price source. source preference + prices tick so Config changes trigger resize.
local function effectiveSourceIsTSM(state)
    local pref = state.account.config.preferredPriceAddon
    if pref == "TSM" then return true end
    if pref == nil then return HDG.PriceSource:IsTSMAvailable() end
    return false
end

Selectors:Register("goblin.isTSMActive", {
    reads = {"account.config.preferredPriceAddon", "session.resolvers.prices.tick"},
    fn = effectiveSourceIsTSM,
})

Selectors:Register("mogul.dynamicColumns", {
    reads = {"session.ui.mogul.subView",
             "account.config.preferredPriceAddon", "session.resolvers.prices.tick"},
    fn = function(state)
        local subView = state.session.ui.mogul.subView
        if subView == "goblin" then
            -- #AH (40) always shown + wider Lumber column (need/held) -> base 785.
            -- TSM active adds Server/Market/Region/TSM% (260) + Rate/+Day (100) + gaps -> ~1175.
            if effectiveSourceIsTSM(state) then return { 1175 } end
            return { 785 }
        end
        return { 700 }   -- mogul craft-optimizer subview
    end,
})

-- Row-click detail expansion: view grows by 150px for the material-breakdown panel.
-- Body row only (chrome + status via window slots per HDG-ADR-025).
Selectors:Register("mogul.dynamicRows", {
    reads = {"session.ui.mogul.subView", "session.ui.mogul.goblin.expandedItemID"},
    fn = function(state)
        local subView  = state.session.ui.mogul.subView
        local expanded = state.session.ui.mogul.goblin.expandedItemID
        -- Body row only -- chrome + status come from the window's slots now
        -- (HDG-ADR-025). body row is index 1 (was index 2 under chrome).
        if subView == "goblin" and expanded then
            return { 650 }   -- +150 for the goblin detail panel
        end
        return { 600 }
    end,
})

Selectors:Register("goblin.isDetailVisible", {
    reads = {"session.ui.mogul.subView", "session.ui.mogul.goblin.expandedItemID"},
    fn = function(state)
        return state.session.ui.mogul.subView == "goblin"
           and state.session.ui.mogul.goblin.expandedItemID ~= nil
    end,
})

-- ADR-003a inside-closure read: StaticData's lazy O(1) itemID -> DecorDB entry index.
local function expandedRecipe(state)
    local id = state.session.ui.mogul.goblin.expandedItemID
    if not id then return nil end  -- exception(nullable): no row expanded
    return HDG.StaticData.Recipes:Get(id)
end

Selectors:Register("goblin.detailTitle", {
    reads = {"session.ui.mogul.goblin.expandedItemID", "session.itemNames.names"},
    fn = function(state)
        local r = expandedRecipe(state)
        if not r then return "" end
        return string.format("Materials for %s", _localName(r.itemID, r.name))
    end,
})

-- One reagent of the expanded recipe. An unpriced reagent's cost is unknown (nil, a
-- "?" on the row), never 0: a zero reads as a real price.
local function _detailRow(reagentID, info)
    local price = HDG.PriceSource:GetItemPrice(reagentID)  -- exception(nullable): no price source knows this reagent
    local owned = HDG.BagObserver:GetCounts()[reagentID]   -- held, as Materials and the plan count it
    return {
        kind       = "goblinDetailRow",
        itemID     = reagentID,
        name       = _localName(reagentID, info.name),
        qty        = info.qty,
        owned      = owned,
        price      = price,
        totalCost  = price and price * info.qty,
        sufficient = owned >= info.qty,
    }
end

-- Dearest first; an unpriced reagent can't claim a place by cost, so it sorts last.
-- Ties (unpriced ones included) by itemID, so the order is the same every paint.
local function _byDetailCostDesc(a, b)
    if a.totalCost == b.totalCost then return a.itemID < b.itemID end
    if a.totalCost == nil or b.totalCost == nil then return b.totalCost == nil end
    return a.totalCost > b.totalCost
end

-- Per-material breakdown for the expanded recipe (budget driver first).
Selectors:Register("goblin.detailRows", {
    reads = {"account.prices", "session.ui.mogul.goblin.expandedItemID",
             "session.resolvers.prices.tick", "session.resolvers.bag.tick", "session.itemNames.names"},
    fn = function(state)
        local r = expandedRecipe(state)
        if not r then return {} end  -- exception(nullable): nothing expanded, or a recipe the DecorDB doesn't carry
        local out = {}
        for reagentID, info in pairs(r.reagents) do out[#out + 1] = _detailRow(reagentID, info) end
        table.sort(out, _byDetailCostDesc)
        return out
    end,
})

Selectors:DefineEnum("mogul.isMode",    "session.ui.mogul.mode",       { "profit", "collection" })
Selectors:DefineEnum("mogul.isView",    "session.ui.mogul.viewMode",   { "char", "account" })
Selectors:DefineEnum("mogul.isOpt",     "session.ui.mogul.optimizeBy", { "lumberOnly", "lumberPlusMats" })
-- "config" sub-view removed -- moved to Config tab.
Selectors:DefineEnum("mogul.isSubView", "session.ui.mogul.subView",    { "mogul", "goblin" })

-- ===== Supply Impact selectors ==============================================
Selectors:DefineEnum("mogul.isSupplyMode", "session.ui.mogul.supplyImpact.mode",
    { "off", "smooth", "cap" })

-- Frugal toggle: planner re-ranks by dampened lumber cost so low-lumber crafts surface.
Selectors:Register("mogul.frugal", {
    reads = { "session.ui.mogul.frugal" },
    fn = function(state) return state.session.ui.mogul.frugal == true end,
})

-- Scalar current-mode selector for radioGroup `current` binding.
Selectors:Register("mogul.supplyMode", {
    reads = { "session.ui.mogul.supplyImpact.mode" },
    fn    = function(state) return state.session.ui.mogul.supplyImpact.mode end,
})

-- Static menu items for the supply-impact radioGroup. Memoized (constant).
Selectors:Register("mogul.supplyMenuItems", {
    reads    = {},
    memoized = true,
    fn = function()
        return {
            { text = "Off",     value = "off"    },
            { text = "Smooth%", value = "smooth" },
            { text = "Cap",     value = "cap"    },
        }
    end,
})


-- The editable numeric value (smoothPct or capN) shown when the mode is not Off.
Selectors:Register("mogul.supplyParamVisible", {
    reads = { "session.ui.mogul.supplyImpact.mode" },
    fn = function(state)
        return state.session.ui.mogul.supplyImpact.mode ~= "off"
    end,
})

Selectors:Register("mogul.supplyParamText", {
    reads = { "session.ui.mogul.supplyImpact.mode",
              "session.ui.mogul.supplyImpact.smoothPct",
              "session.ui.mogul.supplyImpact.capN" },
    fn = function(state)
        local si = state.session.ui.mogul.supplyImpact
        if si.mode == "smooth" then return tostring(si.smoothPct) end
        if si.mode == "cap"    then return tostring(si.capN)      end
        return ""
    end,
})

-- ===== Plan (the heavy producer) ============================================
-- Rebuilds the plan from current settings + account state (reads cover all
-- Mogul module inputs for correct invalidation).

Selectors:Register("mogul.plan", {
    memoized = true,
    reads = {
        "session.ui.mogul.mode",
        "session.ui.mogul.viewMode",
        "session.ui.mogul.optimizeBy",
        "session.ui.mogul.supplyImpact.mode",
        "session.ui.mogul.supplyImpact.smoothPct",
        "session.ui.mogul.supplyImpact.capN",
        "session.ui.mogul.frugal",
        "account.collection.ownedDecorIDs",
        "session.resolvers.bag.tick",            -- lumber and reagents held (BagObserver)
        "session.resolvers.prices.tick",
        "session.itemNames.names",
    },
    calls = { "recipes.knowledge", "recipes.db" },   -- Mogul:Candidates: the known set, each recipe's reagents
    fn = function(state)
        local m = state.session.ui.mogul
        return HDG.Mogul:BuildPlan({
            mode         = m.mode,
            viewMode     = m.viewMode,
            optimizeBy   = m.optimizeBy,
            frugal       = m.frugal == true,
            supplyImpact = m.supplyImpact,   -- the planner reads mode / smoothPct / capN
        })
    end,
})

-- Plan rows -> scrollbox element list.
local function expansionShort(display) return HDG.Expansion.GetShort(display) end

-- crafts x a per-craft figure; nil when the figure is unknown (an unpriced sale or
-- mat), so the row paints "?" rather than a total built on a missing price.
local function _timesCrafts(crafts, perCraft)
    if perCraft == nil then return nil end
    return crafts * perCraft
end

-- The alt to log into for an account-view row this character can't craft: the first
-- by name of the alts recipes.knowledge lists (the one place "known" is decided).
-- KnownByAlt comes from knowledge.alts, so its altChars list is never empty.
local function _bestAltName(r, knownState, view)
    if view.viewMode ~= "account" or knownState ~= HDG.Constants.RECIPE_STATE.KnownByAlt then
        return nil
    end
    return view.altChars[r.itemID][1].name
end

-- view = { viewMode, craftableState (decor.craftableState's itemID -> RECIPE_STATE),
-- altChars (recipes.knowledge) }.
local function buildPlanRowElement(planRow, isRunnerUp, view)
    local r = planRow.recipe
    local s = planRow.score
    local knownState = view.craftableState(r.itemID)
    return {
        kind         = "mogulRow",
        spellID      = r.spellID,
        itemID       = r.itemID,
        -- Crafted decor itemID -> resolver localises (catalog/live API); baked r.name is the fallback.
        name         = _localName(r.itemID, r.name),
        profession   = r.profession,
        expansion    = r.expansion,
        expShort     = expansionShort(r.expansion) or "",  -- exception(nullable): a captured recipe with no expansion, or one Expansion doesn't list
        crafts       = planRow.crafts,
        lumberPerCraft = s.bindingLumberQty,   -- ScoreRecipe: 0 for a lumberless recipe, never nil
        lumberTotal  = planRow.crafts * s.lumberCost,   -- crafts: the planner's K, or 0 for a runner-up
        salePrice    = s.salePrice,
        revenuePerCraft = s.salePrice,
        netPerCraft     = s.netProfitPerCraft,
        revenueTotal = _timesCrafts(planRow.crafts, s.salePrice),
        netTotal     = _timesCrafts(planRow.crafts, s.netProfitPerCraft),
        knownState   = knownState,
        bestAlt      = _bestAltName(r, knownState, view),
        isRunnerUp   = isRunnerUp,
    }
end

-- The plan always exists (BuildPlan returns rows, totals, shoppingList and candidates,
-- each possibly empty); an empty one says so.
local function _planSectionTitle(plan)
    if #plan.rows == 0 then return "Plan -- no crafts fit current budget" end
    return string.format("Plan -- %d crafts, %d lumber used", plan.totals.crafts, plan.totals.lumberUsed)
end

-- Candidates that scored but weren't planned, in the planner's order.
local function _runnersUp(plan)
    local picked, runners = {}, {}
    for _, row in ipairs(plan.rows) do picked[row.recipe.itemID] = true end
    for _, score in ipairs(plan.candidates) do
        if not picked[score.recipe.itemID] then runners[#runners + 1] = score end
    end
    return runners
end

-- Heterogeneous row stream: mogulSection headers + mogulRow entries.
Selectors:Register("mogul.planRows", {
    reads = { "session.ui.mogul.viewMode" },   -- read directly in fn (also in mogul.plan's closure)
    calls = { "mogul.plan", "decor.craftableState", "recipes.knowledge" },
    fn = function(state, ctx)
        local plan = Selectors:Call("mogul.plan", state, ctx)
        local view = { viewMode       = state.session.ui.mogul.viewMode,
                       craftableState = Selectors:Call("decor.craftableState", state, ctx),
                       altChars       = Selectors:Call("recipes.knowledge", state, ctx).altChars }
        local out = { { kind = "mogulSection", title = _planSectionTitle(plan) } }
        for _, row in ipairs(plan.rows) do out[#out + 1] = buildPlanRowElement(row, false, view) end
        local runners = _runnersUp(plan)
        if #runners == 0 then return out end
        out[#out + 1] = { kind = "mogulSection",
                          title = string.format("Runners-up -- did not fit (%d)", #runners) }
        for _, score in ipairs(runners) do
            -- crafts=0 (didn't make budget); row factory uses per-craft figures.
            out[#out + 1] = buildPlanRowElement({ recipe = score.recipe, crafts = 0, score = score }, true, view)
        end
        return out
    end,
})

Selectors:Register("mogul.title", {
    reads = {"session.ui.mogul.subView"},
    calls = {"mogul.plan"},
    fn = function(state, ctx)
        local subView = state.session.ui.mogul.subView
        if subView == "goblin" then return "Goblin" end
        local plan = Selectors:Call("mogul.plan", state, ctx)
        if #plan.rows == 0 then return "Mogul" end
        return string.format("Mogul (%d crafts planned)", plan.totals.crafts)
    end,
})

-- Source-chip visibility in the Goblin header: shown only in the goblin subview,
-- and only when the addon is installed (Auctionator + TSM are gated; Auto + Direct
-- are always available). The active source is shown by the highlighted chip itself
-- (config.sourceActive_*), which is why the old static goblin.headerLabel is gone.
Selectors:Register("goblin.showSourceAuctionator", {
    calls = { "mogul.isSubView_goblin", "config.auctionatorAvailable" },
    fn = function(state, ctx)
        return Selectors:Call("mogul.isSubView_goblin", state, ctx)
           and Selectors:Call("config.auctionatorAvailable", state, ctx)
    end,
})
Selectors:Register("goblin.showSourceTSM", {
    calls = { "mogul.isSubView_goblin", "config.tsmAvailable" },
    fn = function(state, ctx)
        return Selectors:Call("mogul.isSubView_goblin", state, ctx)
           and Selectors:Call("config.tsmAvailable", state, ctx)
    end,
})

-- Column-aligned gold (zero shown as "0 <coin>"); shared formatter.
local moneyText = HDG.Format.FormatGoldZero

-- Net profit, signed: a plan can lose money once its mats are counted. "?" when a
-- mat the plan buys has no price (shared formatter: every profit and net cell).
local signedMoney = HDG.Format.FormatGoldSigned

-- An amount that holds an unpriced part: "?", never "0 <coin>" (shared formatter).
local moneyOrUnknown = HDG.Format.FormatGoldOrUnknown

Selectors:Register("mogul.totalsLabel", {
    reads = { "session.ui.mogul.mode" },   -- read directly in fn (also in mogul.plan's closure)
    calls = {"mogul.plan"},
    fn = function(state, ctx)
        local t = Selectors:Call("mogul.plan", state, ctx).totals
        if t.crafts == 0 then
            return "No crafts planned -- no lumber, no learned recipes, or filters too tight."
        end
        local mode = state.session.ui.mogul.mode
        if mode == "collection" then
            return string.format("New appearances: %d  |  Mat cost: %s",
                t.uniqueDiscoveries, moneyOrUnknown(t.matSpend))
        end
        -- Plain text: widget applies Theme:ColorCode at render time. Revenue counts
        -- planned crafts only, and the planner never picks one without a sale price.
        return string.format("Revenue (mats free): +%s     Net profit (mats bought): %s",
            moneyText(t.revenue), signedMoney(t.netProfit))
    end,
})

-- ===== Lumber tracker rows =================================================
-- Lumber the plan uses, per type: crafts x each craft's lumber of that type.
local function _lumberUsedByTier(plan)
    local used = {}
    for _, row in ipairs(plan.rows) do
        for _, lr in ipairs(row.score.lumberReagents) do
            used[lr.id] = (used[lr.id] or 0) + row.crafts * lr.qty  -- exception(nullable): accumulator, a type's first use
        end
    end
    return used
end

-- One row per lumber type; isActive marks tiers the plan consumed.
Selectors:Register("mogul.lumberRows", {
    reads = {"session.resolvers.bag.tick"},   -- numbers paint via Theme:Register roles -> ApplyAll repaints on scheme swap
    calls = {"mogul.plan"},
    fn = function(state, ctx)
        local used = _lumberUsedByTier(Selectors:Call("mogul.plan", state, ctx))
        local out = {}
        for _, l in ipairs(HDG.Constants.LUMBER_DATA) do
            local have = HDG.BagObserver:GetTotal(l.id)
            local u = used[l.id] or 0  -- exception(nullable): a lumber type the plan doesn't use
            out[#out + 1] = {
                kind      = "mogulLumberRow",
                id        = l.id,
                short     = l.shortName,
                expansion = l.expansion,
                have      = have,
                used      = u,
                leftover  = have - u,
                isActive  = u > 0,
            }
        end
        return out
    end,
})

-- Lumber section header: "Lumber used in plan: U / H held".
Selectors:Register("mogul.lumberHeaderLabel", {
    calls = { "mogul.lumberRows" },
    fn = function(state, ctx)
        local rows = Selectors:Call("mogul.lumberRows", state, ctx)
        local used, have = 0, 0
        for _, r in ipairs(rows) do
            used = used + r.used
            have = have + r.have
        end
        if used == 0 then
            return string.format("Lumber  -  %d held, none used", have)
        end
        return string.format("Lumber used in plan: %d / %d held", used, have)
    end,
})

-- Paired lumber rows: 2-up shape for the 2-column bottom layout (no scroll).
Selectors:Register("mogul.lumberRowsPaired", {
    calls = { "mogul.lumberRows" },
    fn = function(state, ctx)
        local rows = Selectors:Call("mogul.lumberRows", state, ctx)
        local out  = {}
        local half = math.ceil(#rows / 2)
        for i = 1, half do
            out[#out + 1] = {
                kind  = "mogulLumberRow2x",
                left  = rows[i],
                right = rows[i + half],   -- nil on last row if odd count
            }
        end
        return out
    end,
})

-- ===== Reagents to buy =====================================================
-- Shopping list rows from plan.shoppingList. Reads itemNames.names so
-- ITEM_INFO_RESOLVED repaints names after async cache fills.
Selectors:Register("mogul.matsRows", {
    reads = {"session.itemNames.names", "session.resolvers.prices.tick"},
    calls = {"mogul.plan"},
    fn = function(state, ctx)
        local out = {}
        for _, mat in ipairs(Selectors:Call("mogul.plan", state, ctx).shoppingList) do
            local name = (HDG.ItemNameResolver:ResolveName(mat.id))
            out[#out + 1] = {
                kind      = "mogulMatRow",
                itemID    = mat.id,
                name      = name,
                qty       = mat.qty,
                unitPrice = mat.unitPrice,
                totalCost = mat.totalCost,
            }
        end
        return out
    end,
})

-- ===== Goblin sub-view =====================================================
-- Per-decor profit table with profession/knowledge/queue/auction filters + sortable columns.
-- The scored profit table, memoised on the price inputs alone: goblin.rows used
-- to rescore every recipe (1.4 MB, ~10 ms) on every bag tick, name resolve and
-- filter change while Mogul was open (2026-09-13). Each row is its own
-- metatable so goblin.rows can stamp per-view fields on a light proxy.
Selectors:Register("goblin.profitData", {
    memoized = true,
    calls = { "recipes.db" },
    reads = {
        "account.prices",  -- resolver-facade contract (sweep rule 4c)
        "session.resolvers.prices.tick",
        "account.config.preferredPriceAddon",
    },
    fn = function(state, ctx)
        local data = HDG.Goblin:BuildProfitData(Selectors:Call("recipes.db", state, ctx))
        for _, row in ipairs(data) do row.__index = row end
        return data
    end,
})

Selectors:Register("goblin.rows", {
    memoized = true,
    calls = { "goblin.isTSMActive", "recipes.db", "goblin.profitData", "recipes.knowledge" },
    reads = {
        "account.prices",  -- resolver-facade contract (sweep rule 4c)
        "session.itemNames.names",  -- row.name localised via _localName -> re-fire when names resolve
        "account.config.scheme",   -- lumber column bakes Theme color codes -> re-emit on scheme swap to repaint
        "account.collection.ownedDecorIDs",
        "account.craft.queue",
        "account.prices.ownedAuctions",
        "session.resolvers.prices.tick",
        "session.resolvers.bag.tick",
        "session.ui.mogul.goblin.profession",
        "session.ui.mogul.goblin.expansion",
        "session.ui.mogul.goblin.search",
        "session.ui.mogul.goblin.knowledge",
        "session.ui.mogul.goblin.queue",
        "session.ui.mogul.goblin.auctionsOnly",
        "session.ui.mogul.goblin.haveLumber",
        "session.ui.mogul.goblin.sortCol",
        "session.ui.mogul.goblin.sortDir",
        "account.config.preferredPriceAddon",
    },
    fn = function(state, ctx)
        local g = state.session.ui.mogul.goblin
        local profFilter   = g.profession
        local expFilter    = g.expansion
        local search       = g.search:lower()
        local knowledge    = g.knowledge
        local queue        = g.queue
        local auctionsOnly = g.auctionsOnly == true
        local haveLumber   = g.haveLumber == true
        local sortCol      = g.sortCol
        local sortDir      = g.sortDir
        local isTSMActive  = Selectors:Call("goblin.isTSMActive", state, ctx)

        local known = Selectors:Call("recipes.knowledge", state, ctx)
        -- Pre-build queue/auction sets for O(1) lookup per row.
        local queueSet = {}
        for _, q in ipairs(state.account.craft.queue) do
            if q.itemID then queueSet[q.itemID] = true end
        end
        local auctionSet = state.account.prices.ownedAuctions

        local data = Selectors:Call("goblin.profitData", state, ctx)
        -- Per-lumber-type quantity already committed by the craft queue (each queued
        -- craft's need x remaining). The Lumber column rolls this into each row's need
        -- (held vs need+queued), and the "Have lumber" filter hides what held can't cover.
        local queuedLumber = {}
        do
            local byItem = {}
            for _, r in ipairs(data) do byItem[r.itemID] = r end
            for _, q in ipairs(state.account.craft.queue) do
                local qr = byItem[q.itemID]
                if qr and qr.lumberType then  -- exception(nullable): a queued recipe with no profit row, or one that uses no lumber
                    queuedLumber[qr.lumberType] = (queuedLumber[qr.lumberType] or 0)
                        + qr.lumberQty * (q.remaining or 0)  -- exception(boundary): queue row from SVars may lack remaining
                end
            end
        end
        local out = {}
        for _, base in ipairs(data) do
            -- A proxy per row: every stamp below (name, listing, lumber, kind)
            -- lands here, never on the memoised profit row.
            local row = setmetatable({}, base)
            -- Localise the crafted-item name (catalog/live API; baked stays as cold placeholder).
            -- Done before the filters so search + sort + display all read the client-language name.
            row.name = _localName(base.itemID, base.name)
            local keep = true
            -- Profession filter ("All" passes).
            if keep and profFilter ~= "All" and row.profession ~= profFilter then
                keep = false
            end
            -- Expansion filter ("" passes; composes (AND) with profession).
            if keep and expFilter ~= "" and row.expansion ~= expFilter then
                keep = false
            end
            -- Search filter (substring on name, case-insensitive).
            if keep and search ~= "" then
                if not (row.name and row.name:lower():find(search, 1, true)) then
                    keep = false
                end
            end
            -- Knowledge filter.
            if keep and knowledge ~= "all" then
                if knowledge == "known" then
                    keep = known.mine[row.itemID] == true
                elseif knowledge == "alt" then
                    keep = (known.mine[row.itemID] or known.alts[row.itemID]) == true
                end
            end
            -- Queue filter.
            if keep and queue == "only" then
                keep = queueSet[row.itemID] == true
            elseif keep and queue == "hide" then
                keep = not queueSet[row.itemID]
            end
            -- Auctions filter.
            if keep and auctionsOnly then
                keep = auctionSet[row.itemID] ~= nil
            end
            -- Have-lumber filter (lumber-only): keep crafts you can still cover from held
            -- lumber minus what the queue already commits. Rows with no lumber always pass.
            if keep and haveLumber and row.lumberType then
                local held = HDG.BagObserver:GetTotal(row.lumberType)
                if row.lumberQty > (held - (queuedLumber[row.lumberType] or 0)) then
                    keep = false
                end
            end
            if keep then
                -- ADR-041 ed-projection: own-listings qty rides the row so the
                -- #AH painter stays state-dive-free. Re-stamped every run
                -- (including back to nil) so an emptied AH snapshot clears it.
                local mine = auctionSet[row.itemID]
                row.myListedQty = mine and mine.qty or nil  -- exception(nullable): no own listings for this item
                out[#out + 1] = row
            end
        end

        -- Sort by user column; nil values sink to bottom regardless of direction.
        -- lumber column sorts by the craft's lumber NEED (qty); each craft uses one lumber type.
        local function keyFor(row, col)
            if col == "name"      then return row.name end
            if col == "lumber"    then return row.lumberQty end
            if col == "perLum"    then return row.lumberValue end
            if col == "cost"      then return row.materialCost end
            if col == "sell"      then return row.sellPrice end
            if col == "tsmMin"    then return row.tsmMin end
            if col == "tsmMarket" then return row.tsmMarket end
            if col == "tsmRegion" then return row.tsmRegion end
            if col == "tsmPct"    then return row.tsmPct end
            if col == "saleRate"  then return row.saleRate end
            if col == "soldPerDay" then return row.soldPerDay end
            if col == "ahQty"     then return row.ahQty end
            if col == "profit"    then return row.profit end
            if col == "pct"       then return row.margin end
            return row.profit
        end
        local descMul = (sortDir == "desc") and 1 or -1
        table.sort(out, function(a, b)
            local av, bv = keyFor(a, sortCol), keyFor(b, sortCol)
            if av == nil and bv == nil then
                return (a.name or "") < (b.name or "")
            end
            if av == nil then return false end
            if bv == nil then return true  end
            if type(av) == "string" then
                if av == bv then return (a.name or "") < (b.name or "") end
                if descMul == 1 then return av > bv else return av < bv end
            end
            if av == bv then return (a.name or "") < (b.name or "") end
            if descMul == 1 then return av > bv else return av < bv end
        end)
        for i = 1, #out do
            out[i].kind        = "goblinRow"
            out[i].isTSMActive = isTSMActive
            -- Stamp held + queue-committed lumber so Configure reads ed (not BagObserver mid-paint). per ADR-041.
            out[i].ownedLumber  = HDG.BagObserver:GetTotal(out[i].lumberType)
            out[i].queuedLumber = queuedLumber[out[i].lumberType] or 0  -- exception(nullable): no queued craft uses this row's lumber
        end
        return out
    end,
})

-- ===== CSV export ===========================================================
-- Restores the export HDG classic shipped on the Goblin tab (armaniko,
-- CurseForge 2026-08-12). Donor: archive/HousingDecorGuide_v2.45/UI/Tabs/
-- HDG_GoblinTab.lua GenerateCSV(). The donor's 18 columns keep their names and
-- their order so a sheet built against the old export still lines up; the five
-- columns the rewrite's table gained since are appended AFTER them.

-- Copper -> "g.ss.cc". Deliberately not HDG.Format.Gold: that bakes |cff colour
-- codes, which a spreadsheet imports as literal text.
local function _csvGold(copper)
    if not copper then return "" end  -- exception(nullable): no price known for this item
    -- Split the sign off first. Lua's % takes the sign of the DIVISOR, so on a
    -- negative the floor and the remainder disagree and -123456 formatted as
    -- "-13.65.44" instead of "-12.34.56". profit = sellPrice - materialCost is
    -- unclamped, so every loss-making row -- the ones this export exists to
    -- surface -- was wrong (review 2026-08-23).
    local sign = copper < 0 and "-" or ""
    local c    = math.abs(copper)
    return sign .. ("%d.%02d.%02d"):format(
        math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100)
end

local function _csvPct(v)
    if not v then return "" end  -- exception(nullable): margin needs a sell price
    return ("%.1f"):format(v)
end

-- TSM ships saleRate per-mille (rate x1000); the Rate column divides by 10 to
-- show a percent. Export the percent, so a value in the sheet means the same
-- thing as the value on screen.
local function _csvSaleRate(v)
    if not v then return "" end  -- exception(nullable): needs TSM loaded
    return ("%.1f"):format(v / 10)
end

-- Quote only when the value contains something that would break a field.
-- The donor quoted on comma alone, which emitted malformed CSV for a name
-- carrying a doubled quote; widening it changes nothing for ordinary names.
local function _csvText(s)
    s = tostring(s):gsub('"', '""')
    if s:find('[,"\n]') then return '"' .. s .. '"' end
    return s
end

local _lumberNameByID
local function _lumberName(id)
    if not id then return "" end  -- exception(nullable): recipe uses no lumber
    if not _lumberNameByID then
        _lumberNameByID = {}
        for _, l in ipairs(HDG.Constants.LUMBER_DATA) do _lumberNameByID[l.id] = l.name end
    end
    -- Strict: row.lumberType is only ever set from this same table (Goblin's
    -- _lumberSet), so a miss here is drift we want to see.
    return _lumberNameByID[id]
end

local CSV_HEADER = table.concat({
    "Name", "ItemID", "Profession", "Expansion", "Quality", "LumberType",
    "LumberQty", "LumberValuePer", "LumberValueTotal", "MaterialCost",
    "SellPrice", "Profit", "Margin%", "RegionAvg", "TSMMargin%",
    "KnownByPlayer", "KnownByAlts", "PriceSource",
    -- Added since the donor; the table shows these today.
    "TSMMin", "TSMMarket", "SaleRate", "SoldPerDay", "AHQty",
}, ",")

-- Exports exactly what the table is showing -- filtered and sorted -- because
-- "send this list to someone" is the whole point of the feature.
Selectors:Register("goblin.csv", {
    calls = { "goblin.rows", "recipes.knowledge" },   -- recipes.knowledge: KnownByPlayer / KnownByAlts
    fn = function(state, ctx)
        local rows    = Selectors:Call("goblin.rows", state, ctx)
        local known   = Selectors:Call("recipes.knowledge", state, ctx)
        local out     = { CSV_HEADER }
        for i = 1, #rows do
            local r   = rows[i]
            local lumberTotal = ""
            if r.lumberValue and r.lumberQty then
                lumberTotal = _csvGold(r.lumberValue * r.lumberQty)
            end
            out[#out + 1] = table.concat({
                _csvText(r.name),
                r.itemID,
                _csvText(r.profession),
                _csvText(r.expansion),
                -- Quality: the rewrite carries no quality for a crafted recipe --
                -- not on the row, not in HDGR_DecorDB, not resolved anywhere. The
                -- column holds its place rather than shipping an invented value.
                "",
                _csvText(_lumberName(r.lumberType)),
                r.lumberQty,
                _csvGold(r.lumberValue),
                lumberTotal,
                _csvGold(r.materialCost),
                _csvGold(r.sellPrice),
                _csvGold(r.profit),
                _csvPct(r.margin),
                _csvGold(r.tsmRegion),
                _csvPct(r.tsmPct),
                known.mine[r.itemID] and "Yes" or "No",
                known.alts[r.itemID] and "Yes" or "No",   -- an alt knows it, whether or not you do
                _csvText(r.priceSource or ""),  -- exception(nullable): no price -> no source
                _csvGold(r.tsmMin),
                _csvGold(r.tsmMarket),
                _csvSaleRate(r.saleRate),
                -- Raw units/realm/day: the column compacts big numbers for
                -- width ("1.2k"), which a spreadsheet cannot add up.
                r.soldPerDay or "",  -- exception(nullable): needs TSM loaded
                r.ahQty or "",  -- exception(nullable): no Direct scan for this item
            }, ",")
        end
        return table.concat(out, "\n") .. "\n"
    end,
})

-- Per-profession active-state selectors for pill `active` bindings.
do
    local function activeProf(target)
        return function(state)
            return state.session.ui.mogul.goblin.profession == target
        end
    end
    Selectors:Register("goblin.profActive_All",
        { reads = {"session.ui.mogul.goblin.profession"}, fn = activeProf("All") })
    -- entries 10-12 = gathering; skip
    for i, p in ipairs(HDG.Constants.PROFESSION_DATA or {}) do
        if i <= 9 and p.name then
            Selectors:Register("goblin.profActive_" .. p.name,
                { reads = {"session.ui.mogul.goblin.profession"}, fn = activeProf(p.name) })
        end
    end
end

-- Expansion pill active selectors (one per EXPANSION_DATA entry, keyed by short code).
do
    local function activeExp(target)
        return function(state)
            return state.session.ui.mogul.goblin.expansion == target
        end
    end
    for _, e in ipairs(HDG.Constants.EXPANSION_DATA) do
        Selectors:Register("goblin.expActive_" .. e.short,
            { reads = {"session.ui.mogul.goblin.expansion"}, fn = activeExp(e.display) })
    end
end

-- Knowledge + queue tri-state pill active selectors, auctions toggle.
do
    Selectors:Register("goblin.auctionsActive", {
        reads = {"session.ui.mogul.goblin.auctionsOnly"},
        fn = function(state)
            return state.session.ui.mogul.goblin.auctionsOnly == true
        end,
    })
    Selectors:Register("goblin.haveLumberActive", {
        reads = {"session.ui.mogul.goblin.haveLumber"},
        fn = function(state)
            return state.session.ui.mogul.goblin.haveLumber == true
        end,
    })

    -- Bare-value selectors for the dropdown generator's isSelected computation.
    -- (knowledgeLabel / queueLabel retired: kind="dropdown" auto-renders selection text.)
    Selectors:Register("goblin.knowledge", {
        reads = {"session.ui.mogul.goblin.knowledge"},
        fn    = function(state) return state.session.ui.mogul.goblin.knowledge or "all" end,
    })
    Selectors:Register("goblin.queue", {
        reads = {"session.ui.mogul.goblin.queue"},
        fn    = function(state) return state.session.ui.mogul.goblin.queue or "all" end,
    })
    Selectors:Register("goblin.knowledgeMenuItems", {
        reads    = {},
        memoized = true,
        fn = function()
            return {
                { text = "All",         value = "all"   },
                { text = "Known",       value = "known" },
                { text = "Known + Alt", value = "alt"   },
            }
        end,
    })
    Selectors:Register("goblin.queueMenuItems", {
        reads    = {},
        memoized = true,
        fn = function()
            return {
                { text = "All",  value = "all"  },
                { text = "Only", value = "only" },
                { text = "Hide", value = "hide" },
            }
        end,
    })
end

-- (goblin.tsmPriceType removed: table renders all 3 TSM columns at once now.
--  account.config.tsmPriceMode still feeds the profit calc + TSM % column.)

-- Per-column header text + active-state selectors.
-- Active column gets ASCII arrow suffix (" v" / " ^"); inactive renders plain label.
do
    local labels = {
        name      = "Item Name", lumber    = "Lumber",    perLum    = "$/Lum",
        cost      = "Cost",      sell      = "Sell",
        tsmMin    = "Server",    tsmMarket = "Market",    tsmRegion = "Region",
        tsmPct    = "TSM %",     profit    = "Profit",    pct       = "%",
        ahQty     = "#AH",       saleRate  = "Rate",      soldPerDay = "/Day",
    }
    local function headerFn(col)
        return function(state)
            local g = state.session.ui.mogul.goblin
            local label = labels[col] or col
            if g.sortCol == col then
                return label .. ((g.sortDir == "asc") and " ^" or " v")
            end
            return label
        end
    end
    local function activeFn(col)
        return function(state)
            return state.session.ui.mogul.goblin.sortCol == col
        end
    end
    for col, _ in pairs(labels) do
        Selectors:Register("goblin.sortHeader_" .. col, {
            reads = {"session.ui.mogul.goblin.sortCol", "session.ui.mogul.goblin.sortDir"},
            fn = headerFn(col),
        })
        Selectors:Register("goblin.sortActive_" .. col, {
            reads = {"session.ui.mogul.goblin.sortCol"},
            fn = activeFn(col),
        })
    end
end

-- Footer label: "N items" (post-filter count).
-- Cold-start CTA gate: Direct cache never scanned AND no external price addon
-- to fall back to -> every profit column renders "-" with no guidance. Drives
-- the scan-hint banner above the Goblin list (UX review 2026-06-10 #3).
Selectors:Register("goblin.needsScanHint", {
    reads = { "account.prices.directCacheTime",
              "session.prices.auctionatorLoaded", "session.prices.tsmLoaded" },
    fn = function(state)
        if state.account.prices.directCacheTime then return false end
        if state.session.prices.auctionatorLoaded then return false end
        if state.session.prices.tsmLoaded then return false end
        return true
    end,
})

Selectors:Register("goblin.statusLabel", {
    calls = {"goblin.rows"},
    fn = function(state, ctx)
        local rows = Selectors:Call("goblin.rows", state, ctx)
        return string.format("%d items", #rows)
    end,
})

-- "Queue All" enabled when plan has at least one row.
Selectors:Register("mogul.queueAllEnabled", {
    calls = { "mogul.plan" },
    fn = function(state, ctx)
        return #Selectors:Call("mogul.plan", state, ctx).rows > 0
    end,
})

-- "Send to Auctionator" enabled when Auctionator is loaded AND plan has a shopping list.
Selectors:Register("mogul.auctionatorEnabled", {
    reads = { "session.prices.auctionatorLoaded" },
    calls = { "mogul.plan" },
    fn = function(state, ctx)
        if not state.session.prices.auctionatorLoaded then return false end
        return #Selectors:Call("mogul.plan", state, ctx).shoppingList > 0
    end,
})

Selectors:Register("mogul.matsTitle", {
    calls = {"mogul.plan"},
    fn = function(state, ctx)
        local list = Selectors:Call("mogul.plan", state, ctx).shoppingList
        if #list == 0 then return "Reagents to buy: none" end
        -- One unpriced line makes the total unknown (a sum without it reads as the price).
        local total = 0
        for _, m in ipairs(list) do total = total and m.totalCost and total + m.totalCost end
        return string.format("Reagents to buy: %d items, total %s", #list, moneyOrUnknown(total))
    end,
})
