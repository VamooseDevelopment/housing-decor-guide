-- HDG.MogulController
-- ============================================================================
-- Mogul/Goblin chip wiring + mogulRow / goblinRow / mat / lumber row factories.

HDG = HDG or {}
HDG.Rows = HDG.Rows or {}
HDG.MogulController = HDG.MogulController or {}

local MogulController = HDG.MogulController

local dispatch = HDG.ControllerHelpers.Mechanics.DispatchNamed  -- hygiene A13

-- ===== Wire sub-groups ==================================================

-- Supply Impact numeric param editbox (commits on Enter / FocusLost).
function MogulController:_wireSupplyImpact(rootFrame)
    local box = HDG.UI.W(rootFrame, "mogulPanel.supplyParam")
    local function commit()
        local mode = HDG.Store:GetState().session.ui.mogul.supplyImpact.mode  -- exception(false-positive): top-level controller read
        local n = tonumber((box.GetText and box:GetText()) or "")
        if not n then return end
        if mode == "smooth" then
            dispatch("MOGUL_SET_SUPPLY_SMOOTH", { pct = math.max(0, math.min(99, n)) })
        elseif mode == "cap" then
            dispatch("MOGUL_SET_SUPPLY_CAP", { n = math.max(1, math.floor(n)) })
        end
    end
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEditFocusLost", commit)
end

-- Goblin: profession pills, search, auctions toggle, column-header sort.
function MogulController:_wireGoblinControls(rootFrame)
    HDG.UI.OnClick(rootFrame, "mogulPanel.goblinProf_All",
        function() dispatch("GOBLIN_SET_PROFESSION", { profession = "All" }) end)
    for i, p in ipairs(HDG.Constants.PROFESSION_DATA or {}) do  -- exception(boundary): optional data table
        if i <= 9 and p.name then
            local captured = p.name
            HDG.UI.OnClick(rootFrame, "mogulPanel.goblinProf_" .. captured,
                function() dispatch("GOBLIN_SET_PROFESSION", { profession = captured }) end)
        end
    end
    -- Expansion pills: dispatch the display name; the reducer toggles-to-clear on re-click.
    for _, e in ipairs(HDG.Constants.EXPANSION_DATA) do
        local captured = e.display
        HDG.UI.OnClick(rootFrame, "mogulPanel.goblinExp_" .. e.short,
            function() dispatch("GOBLIN_SET_EXPANSION", { expansion = captured }) end)
    end
    HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, "mogulPanel.goblinSearch"), function(text)
        dispatch("GOBLIN_SET_SEARCH", { query = text })
    end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.goblinAuctions",
        function() dispatch("GOBLIN_TOGGLE_AUCTIONS", {}) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.goblinHaveLumber",
        function() dispatch("GOBLIN_TOGGLE_HAVE_LUMBER", {}) end)
    for _, col in ipairs({"name","lumber","perLum","cost","sell",
                          "tsmMin","tsmMarket","tsmRegion","tsmPct","saleRate","soldPerDay","profit","pct"}) do
        local captured = col
        HDG.UI.OnClick(rootFrame, "mogulPanel.goblinCol_" .. col,
            function() dispatch("GOBLIN_SET_SORT", { col = captured }) end)
    end
end

-- Queue All: every plan row -> Recipes craft queue + switch to Recipes.
function MogulController:_wireQueueAll(rootFrame)
    HDG.UI.OnClick(rootFrame, "mogulPanel.queueAll", function()
        local plan = HDG.Selectors:Call("mogul.plan", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller method (not a row factory)
        if not (plan and plan.rows and #plan.rows > 0) then return end
        local A = HDG.Constants.ACTIONS
        local n = 0
        for _, row in ipairs(plan.rows) do
            local r = row.recipe
            if r and r.itemID and row.crafts > 0 then  -- plan row: crafts is planner-stamped numeric
                HDG.Store:Dispatch({ type = A.CRAFT_QUEUE_ADD,
                    payload = { recipeID = r.itemID, itemID = r.itemID, qty = row.crafts, source = "mogul" } })
                n = n + 1
            end
        end
        HDG.Store:Dispatch({ type = A.UI_SET_PERSISTENT, payload = { key = "view", value = "recipes" } })
        HDG.Log:Success("queue", ("Queued %d recipe%s from plan"):format(n, n == 1 and "" or "s"))
    end)
end

-- Export: the table as it is currently filtered and sorted, as CSV, in the
-- shared copy dialog. Restores the HDG classic Goblin-tab export.
function MogulController:_wireGoblinExport(rootFrame)
    HDG.UI.OnClick(rootFrame, "mogulPanel.goblinExport", function()
        -- Hoisted rather than inlined twice: both selectors below must see the
        -- same state, or the count in the title could disagree with the body.
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local rows  = HDG.Selectors:Call("goblin.rows", state, {})
        if #rows == 0 then
            -- Notify, not Warn: this is command feedback the player asked for,
            -- so it belongs in chat rather than only the Debug tab.
            HDG.Log:Notify("warn", HDG.Locale:Get("MOG_EXPORT_EMPTY"))
            return
        end
        local csv = HDG.Selectors:Call("goblin.csv", state, {})
        HDG.UI:CopyDialog():Open(
            HDG.Locale:Get("MOG_EXPORT_TITLE"):format(#rows), csv)
        -- mogul_action, not a new "export" tag: Wire() registers the tab's tags
        -- up front and this is a Mogul-tab action, the same as the price scan.
        HDG.Log:Success("mogul_action", ("Exported %d row%s to CSV"):format(
            #rows, #rows == 1 and "" or "s"))
    end)
end

-- Send to Auctionator: plan.shoppingList (deficit-to-buy) via shared helper.
function MogulController:_wireSendToAH(rootFrame)
    HDG.UI.OnClick(rootFrame, "mogulPanel.sendToAH", function()
        local plan = HDG.Selectors:Call("mogul.plan", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller method (not a row factory)
        if not (plan and plan.shoppingList and #plan.shoppingList > 0) then return end
        HDG.UI.SendReagentsToAuctionator("HDG Mogul Reagents", plan.shoppingList)
        HDG.Log:Success("shopping", ("Sent %d reagent%s to Auctionator"):format(
            #plan.shoppingList, #plan.shoppingList == 1 and "" or "s"))
    end)
end

-- Goblin header: price-source selector pills + Refresh from AH. Shares the
-- config.* selectors/actions the old Config pills used (PRICES_SET_PREFERRED_SOURCE;
-- Auto = nil = clear preference). Refresh kicks a direct AH scan over every recipe
-- item + reagent (PriceSource no-ops it unless the AH window is open).
function MogulController:_wireGoblinSource(rootFrame)
    HDG.UI.OnClick(rootFrame, "mogulPanel.src_Auto",
        function() dispatch("PRICES_SET_PREFERRED_SOURCE", { source = nil }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.src_Auctionator",
        function() dispatch("PRICES_SET_PREFERRED_SOURCE", { source = "Auctionator" }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.src_Direct",
        function() dispatch("PRICES_SET_PREFERRED_SOURCE", { source = "Direct" }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.src_TSM",
        function() dispatch("PRICES_SET_PREFERRED_SOURCE", { source = "TSM" }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.refreshScanBtn", function()
        local seen, ids = {}, {}
        -- Merged, not the raw seed: a 12.1 scan can swap a recipe's reagents
        -- outright, and scanning the seed's list would leave the reagent people
        -- now actually need without a price.
        local rdb = HDG.Selectors:Call("recipes.db", HDG.Store:GetState())  -- exception(false-positive): OnClick handler, not a row factory; Selectors:Call takes state
        for _, recipe in pairs(rdb) do
            if recipe.itemID and not seen[recipe.itemID] then
                seen[recipe.itemID] = true
                ids[#ids + 1] = recipe.itemID
            end
            for reagentID in pairs(recipe.reagents or {}) do
                if not seen[reagentID] then
                    seen[reagentID] = true
                    ids[#ids + 1] = reagentID
                end
            end
        end
        -- force: the explicit button is a REFRESH -- re-scan everything even
        -- when the cache is fully populated (it always is after one scan).
        if HDG.PriceSource:StartDirectScan(ids, true) then
            HDG.Log:Info("mogul_action", "Price scan started...")
        else
            -- Previously a SILENT no-op away from the AH -- worst kind of dead button.
            HDG.Log:Warn("mogul_action", "Price scan needs the Auction House window open.")
        end
    end)
end

function MogulController:Wire(rootFrame)
    if not HDG.Log:HasTag("mogul_action") then
        HDG.Log:RegisterTabTags("mogul")
    end
    HDG.UI.OnClick(rootFrame, "mogulPanel.modeProfit",     function() dispatch("MOGUL_SET_MODE",        { mode = "profit"     }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.modeCollection", function() dispatch("MOGUL_SET_MODE",        { mode = "collection" }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.viewChar",       function() dispatch("MOGUL_SET_VIEW",        { viewMode = "char"    }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.viewAccount",    function() dispatch("MOGUL_SET_VIEW",        { viewMode = "account" }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.optLumber",      function() dispatch("MOGUL_SET_OPTIMIZE_BY", { optimizeBy = "lumberOnly"     }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.optAH",          function() dispatch("MOGUL_SET_OPTIMIZE_BY", { optimizeBy = "lumberPlusMats" }) end)
    HDG.UI.OnClick(rootFrame, "mogulPanel.frugal", function()
        dispatch("MOGUL_TOGGLE_FRUGAL", {})
    end)

    self:_wireSupplyImpact(rootFrame)
    self:_wireGoblinControls(rootFrame)
    self:_wireGoblinSource(rootFrame)    -- header price-source pills + Refresh from AH
    self:_wireQueueAll(rootFrame)        -- Queue All -> Recipes-tab craft queue
    self:_wireSendToAH(rootFrame)        -- Send reagents to Auctionator
    self:_wireGoblinExport(rootFrame)    -- Goblin table -> CSV in the copy dialog
end

function MogulController:Refresh(rootFrame, ctx)
    -- All UI state flows through bindings; nothing imperative.
end

HDG.Controllers:Register("mogul", MogulController)

-- ===== Row factory ==========================================================
-- mogulRow: name | crafts | lumber/ea | revenue (right, gold-formatted).

-- Gold formatter (zero shown as "0 <coin>").
local moneyText = HDG.Format.FormatGoldZero

-- Compact count for the narrow "/Day" column. Spans a huge range: a hot commodity
-- (~156577/day -> "157k") down to slow decor (0.096/day -> "0.10").
local function _compactCount(n)
    if n >= 10000 then return string.format("%.0fk", n / 1000) end
    if n >= 1000  then return string.format("%.1fk", n / 1000) end
    if n >= 10    then return string.format("%d", math.floor(n + 0.5)) end
    if n >= 1     then return string.format("%.1f", n) end
    return string.format("%.2f", n)   -- sub-1/day (slow decor)
end

-- Format "rev / net" gold pair compactly (e.g. "795g / 791g") used in two
-- columns: per-craft (constant per recipe) and total (crafts * per).
local function moneyPair(revenue, net)
    local r = moneyText(revenue or 0)
    local n = moneyText(net or 0)
    if (revenue or 0) == (net or 0) then return r end
    return r .. " / " .. n
end

-- ensureSection: one centered FontString for section headers.
-- ensurePlanRow: star | crafts | name | lumber/ea | rev/net each | rev/net total | exp.
local function ensureSection(row)
    if row._secFs then return end
    local fs = HDG.UI.RowText(row, "heading", "TextDim", "LEFT")
    fs:SetPoint("LEFT", row, "LEFT", 4, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    fs:SetWordWrap(false)
    row._secFs = fs
end

-- Expansion-tinted row bg: 0.20 (plan rows) vs 0.10 (runners-up).
local function _applyMogulRowBg(row, ed)
    local alpha = ed.isRunnerUp and 0.10 or 0.20
    local tint  = HDG.Expansion.GetBgTint(ed.expansion, alpha)
    if tint then
        row._bgTex:SetColorTexture(tint.r, tint.g, tint.b, tint.a)
        row._bgTex:Show()
    else
        row._bgTex:Hide()
    end
end

local function ensurePlanRow(row)
    if row._planLaidOut then return end
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    row._bgTex = bg

    local star = row:CreateTexture(nil, "ARTWORK")   -- exception(false-positive): chrome-less mogul row, no EnsureRowChrome (ARTWORK-0 fine)
    star:SetSize(12, 12)
    star:SetPoint("LEFT", row, "LEFT", 4, 0)
    row._starTex = star

    local crafts = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
    crafts:SetSize(36, 16)
    crafts:SetPoint("LEFT", star, "RIGHT", 4, 0)
    crafts:SetWordWrap(false)
    row._craftsFs = crafts

    local exp = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    exp:SetSize(40, 16)
    exp:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    exp:SetWordWrap(false)
    row._expFs = exp

    local profit = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(profit, "small")
    profit:SetSize(150, 16)
    profit:SetPoint("RIGHT", exp, "LEFT", -8, 0)
    profit:SetJustifyH("RIGHT")
    profit:SetWordWrap(false)
    row._profitFs = profit

    local each = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    each:SetSize(130, 16)
    each:SetPoint("RIGHT", profit, "LEFT", -8, 0)
    each:SetWordWrap(false)
    row._eachFs = each

    local lumber = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    lumber:SetSize(46, 16)
    lumber:SetPoint("RIGHT", each, "LEFT", -8, 0)
    lumber:SetWordWrap(false)
    row._lumberFs = lumber

    local name = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(name, "body")
    name:SetPoint("LEFT", crafts, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", lumber, "LEFT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row._nameFs = name

    row._planLaidOut = true
end

local function hideShape(row, which)
    if which == "section" or which == nil then
        if row._secFs then row._secFs:Hide() end
    end
    if which == "plan" or which == nil then
        if row._starTex  then row._starTex:Hide()  end
        if row._craftsFs then row._craftsFs:Hide() end
        if row._nameFs   then row._nameFs:Hide()   end
        if row._lumberFs then row._lumberFs:Hide() end
        if row._eachFs   then row._eachFs:Hide()   end
        if row._profitFs then row._profitFs:Hide() end
        if row._expFs    then row._expFs:Hide()    end
    end
end

local function showShape(row, which)
    if which == "section" and row._secFs then row._secFs:Show() end
    if which == "plan" then
        if row._starTex  then row._starTex:Show()  end
        if row._craftsFs then row._craftsFs:Show() end
        if row._nameFs   then row._nameFs:Show()   end
        if row._lumberFs then row._lumberFs:Show() end
        if row._eachFs   then row._eachFs:Show()   end
        if row._profitFs then row._profitFs:Show() end
        if row._expFs    then row._expFs:Show()    end
    end
end

-- Section header: heading-colored title, 20px.
local function _paintMogulSection(row, ed)
    row._itemID, row._recipeID, row._name = nil, nil, nil   -- section rows carry no R4 tooltip
    hideShape(row, "plan")
    if row._bgTex then row._bgTex:Hide() end  -- clear pooled expansion bg
    ensureSection(row)
    showShape(row, "section")
    local headingCode = HDG.Theme:ColorCode("text.heading")
    row._secFs:SetText(headingCode .. (ed.title or "") .. "|r")
    row:SetHeight(20)
end


-- Name: state-colored + "(alt: Who)" suffix when sourced from an alt.
local function _paintMogulName(row, ed, state, dim)
    local textColor = HDG.Theme:GetTextStateColorToken(state)
    local name = ed.name or "?"
    if ed.bestAlt then
        local who = ed.bestAlt:match("^([^%-]+)") or ed.bestAlt
        name = name .. "  " .. dim .. "(alt: " .. who .. ")|r"
    end
    row._nameFs:SetText(textColor .. name .. "|r")
end

-- Profit: success > 0, error < 0. Runners-up show per-craft pair; plan shows +total.
local function _paintMogulProfit(row, ed)
    local netForColor = ed.isRunnerUp and ed.netPerCraft or ed.netTotal
    local profitState
    if netForColor and netForColor > 0 then profitState = "success"
    elseif netForColor and netForColor < 0 then profitState = "error" end
    local profitOpen  = profitState
        and HDG.Theme:GetTextStateColorToken(profitState) or ""
    local profitClose = profitState and "|r" or ""
    if ed.isRunnerUp then
        row._profitFs:SetText(profitOpen
            .. moneyPair(ed.revenuePerCraft, ed.netPerCraft) .. profitClose)
    else
        row._profitFs:SetText(profitOpen .. "+"
            .. moneyPair(ed.revenueTotal, ed.netTotal) .. profitClose)
    end
end

-- Dim runners-up to 60% alpha.
local function _applyMogulRowAlpha(row, ed)
    local a = ed.isRunnerUp and 0.6 or 1.0
    for _, fs in ipairs({ row._nameFs, row._craftsFs, row._lumberFs,
                          row._eachFs, row._profitFs, row._expFs }) do
        fs:SetAlpha(a)
    end
    if row._starTex and row._starTex.SetAlpha then row._starTex:SetAlpha(a) end
end

-- Plan/runner-up row: star + name + craft/lumber/each + profit + exp.
local function _paintMogulPlan(row, ed, template)
    hideShape(row, "section")
    ensurePlanRow(row)
    showShape(row, "plan")

    row._itemID, row._recipeID, row._name = ed.itemID, ed.itemID, ed.name   -- R4 tooltip stamps
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.RecipeRow)

    -- Resolve color tokens once per Configure (not 4x inline).
    local dim     = HDG.Theme:ColorCode("text.dim")
    local primary = HDG.Theme:ColorCode("text.primary")
    local heading = HDG.Theme:ColorCode("text.heading")

    local state = ed.knownState or HDG.Constants.RECIPE_STATE.UnknownOnAccount
    HDG.UI:PaintCraftStar(row._starTex, state, HDG.Constants.RECIPE_STATE.UnknownOnAccount)
    _paintMogulName(row, ed, state, dim)

    if ed.isRunnerUp then
        row._craftsFs:SetText(dim .. "-|r")
    else
        row._craftsFs:SetText(string.format("%s%dx|r", primary, ed.crafts))  -- mogul.planRows stamps crafts (numeric)
    end
    row._lumberFs:SetText(string.format("%s%d|r", heading, ed.lumberPerCraft))  -- mogul.planRows stamps lumberPerCraft (coerced)
    row._eachFs:SetText(moneyPair(ed.revenuePerCraft, ed.netPerCraft))

    _paintMogulProfit(row, ed)
    row._expFs:SetText(ed.expShort or "")
    _applyMogulRowAlpha(row, ed)
    _applyMogulRowBg(row, ed)  -- Item 14: expansion-tinted row backdrop

    local h = template.height   -- may be a function (section vs plan heights)
    if type(h) == "function" then h = h(nil, ed) end
    if type(h) == "number" then row:SetHeight(h) end
end

local function _mogulRowFactory(template)
    return {
        Configure = function(row, ed)
            if ed.kind == "mogulSection" then
                _paintMogulSection(row, ed)
            else
                _paintMogulPlan(row, ed, template)
            end
        end,
        Reset = function(row)
            row._itemID, row._recipeID, row._name = nil, nil, nil   -- clear R4 tooltip stamps
            hideShape(row, nil)
        end,
    }
end

-- ===== Lumber tracker row: short-name (expansion-colored) | "have - used" | > | leftover =

-- First-paint chrome: name | "have - used" | ">" | leftover.
local function _layoutMogulLumberRow(row)
    local name = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(name, "small")
    name:SetSize(80, 14)
    name:SetPoint("LEFT", row, "LEFT", 6, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row._nameFs = name

    local left = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(left, "small")
    left:SetSize(74, 14)
    left:SetPoint("CENTER", row, "CENTER", 30, 0)
    left:SetJustifyH("RIGHT")
    left:SetWordWrap(false)
    row._leftFs = left

    local arrow = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(arrow, "small")
    arrow:SetSize(16, 14)
    arrow:SetPoint("LEFT", left, "RIGHT", 4, 0)
    arrow:SetJustifyH("CENTER")
    row._arrowFs = arrow

    local right = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(right, "small")
    right:SetSize(40, 14)
    right:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
    right:SetJustifyH("LEFT")
    right:SetWordWrap(false)
    row._rightFs = right
end

local function _paintMogulLumberRow(row, ed)
    -- Numbers via Theme:Register (success = consumed, dim = otherwise; repaints on scheme switch).
    -- Name = expansion brand color via inline |cFF (no theme role for brand colors).
    local exHex = HDG.Expansion.GetColorHex(ed.expansion)
    row._nameFs:SetText(exHex and (exHex .. (ed.short or "?") .. "|r") or (ed.short or "?"))

    local numRole = ed.isActive and "TextSuccess" or "TextDim"
    HDG.Theme:Register(row._leftFs,  numRole)
    HDG.Theme:Register(row._arrowFs, numRole)
    HDG.Theme:Register(row._rightFs, numRole)
    row._leftFs:SetText(string.format("%d - %d", ed.have, ed.used))  -- mogul.lumberRows stamps have/used (coerced)
    row._arrowFs:SetText(">")
    row._rightFs:SetText(tostring(ed.leftover))
end

-- 2-up lumber row: two items per row (12 types -> 6 rows). right may be nil on odd-count list.
local function _buildLum2xHalf(row, side, anchorParent, anchorSide, offsetX)
    local prefix = "_lum2x_" .. side .. "_"
    local name = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(name, "small")
    name:SetSize(70, 14)
    name:SetPoint("LEFT", anchorParent, anchorSide, offsetX, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row[prefix .. "name"] = name

    local left = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(left, "small")
    left:SetSize(62, 14)
    left:SetPoint("LEFT", name, "RIGHT", 2, 0)
    left:SetJustifyH("RIGHT")
    left:SetWordWrap(false)
    row[prefix .. "left"] = left

    local arrow = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(arrow, "small")
    arrow:SetSize(10, 14)
    arrow:SetPoint("LEFT", left, "RIGHT", 2, 0)
    arrow:SetJustifyH("CENTER")
    row[prefix .. "arrow"] = arrow

    local right = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(right, "small")
    right:SetSize(28, 14)
    right:SetPoint("LEFT", arrow, "RIGHT", 2, 0)
    right:SetJustifyH("LEFT")
    right:SetWordWrap(false)
    row[prefix .. "right"] = right
end

local function _layoutMogulLumberRow2x(row)
    _buildLum2xHalf(row, "L", row, "LEFT",  6)
    -- Right half anchors to row's CENTER+4 so the two halves
    -- split the row's width with a small gutter between.
    _buildLum2xHalf(row, "R", row, "CENTER", 4)
end

local function _paintLum2xHalf(row, side, item)
    local prefix = "_lum2x_" .. side .. "_"
    local nameFs  = row[prefix .. "name"]
    local leftFs  = row[prefix .. "left"]
    local arrowFs = row[prefix .. "arrow"]
    local rightFs = row[prefix .. "right"]
    if not item then
        -- Trailing-odd case: hide the right half entirely.
        if nameFs  then nameFs:SetText("")  end
        if leftFs  then leftFs:SetText("")  end
        if arrowFs then arrowFs:SetText("") end
        if rightFs then rightFs:SetText("") end
        return
    end
    -- Inline |cFF (text rail) for scheme-switch repaints. Name = expansion brand; numbers = plan-state.
    local exHex = HDG.Expansion.GetColorHex(item.expansion)
    nameFs:SetText(exHex and (exHex .. (item.short or "?") .. "|r") or (item.short or "?"))
    local numRole = item.isActive and "TextSuccess" or "TextDim"   -- standard row colors
    HDG.Theme:Register(leftFs,  numRole)
    HDG.Theme:Register(arrowFs, numRole)
    HDG.Theme:Register(rightFs, numRole)
    leftFs:SetText(string.format("%d - %d", item.have, item.used))  -- mogul.lumberRows stamps have/used (coerced)
    arrowFs:SetText(">")
    rightFs:SetText(tostring(item.leftover or 0))
end

local function _paintMogulLumberRow2x(row, ed)
    _paintLum2xHalf(row, "L", ed.left)
    _paintLum2xHalf(row, "R", ed.right)
end

local function _resetMogulLumberRow2x(row)
    _paintLum2xHalf(row, "L", nil)
    _paintLum2xHalf(row, "R", nil)
end

HDG.Rows:Register("mogulLumberRow2x", {
    font    = "small",
    height  = 14,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutMogulLumberRow2x,
        paint      = _paintMogulLumberRow2x,
        laidOutTag = "_lum2xLaidOut",
        reset      = _resetMogulLumberRow2x,
    }),
    key     = function(ed)
        if not ed then return "?" end
        local lid = ed.left and ed.left.id or "?"
        local rid = ed.right and ed.right.id or "-"
        return "lum2x:" .. tostring(lid) .. ":" .. tostring(rid)
    end,
})

HDG.Rows:Register("mogulLumberRow", {
    font    = "small",
    height  = 14,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutMogulLumberRow,
        paint      = _paintMogulLumberRow,
        laidOutTag = "_lumLaidOut",
        resetText  = { "_nameFs", "_leftFs", "_arrowFs", "_rightFs" },
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "lum:" .. tostring(ed.id or "?")
    end,
})

-- ===== Reagents-to-buy row: name (fill) | qty | cost =======================
local function _layoutMogulMatRow(row)
    local name = HDG.UI.RowText(row, "small", "Text", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", 6, 0)
    name:SetWordWrap(false)
    row._nameFs = name

    local cost = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(cost, "small")
    cost:SetSize(80, 14)
    cost:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    cost:SetJustifyH("RIGHT")
    cost:SetWordWrap(false)
    row._costFs = cost

    local qty = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    qty:SetSize(60, 14)
    qty:SetPoint("RIGHT", cost, "LEFT", -8, 0)
    qty:SetWordWrap(false)
    row._qtyFs = qty

    name:SetPoint("RIGHT", qty, "LEFT", -8, 0)
end

local function _paintMogulMatRow(row, ed)
    row._nameFs:SetText(ed.name or "?")
    row._qtyFs:SetText(string.format("0/%d", ed.qty))  -- goblin.materialRows: qty schema-guaranteed
    row._costFs:SetText(moneyText(ed.totalCost))  -- mogul mat: totalCost = qty*unit (numeric)
end

HDG.Rows:Register("mogulMatRow", {
    font    = "small",
    height  = 14,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutMogulMatRow,
        paint      = _paintMogulMatRow,
        laidOutTag = "_matLaidOut",
        resetText  = { "_nameFs", "_qtyFs", "_costFs" },
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "mat:" .. tostring(ed.itemID or "?")
    end,
})

-- ===== Goblin profit table row =============================================
-- 8 columns: name(fill) | lumber(100) | $/Lum(70) | Cost(70) | Sell(70) | Profit(80) | %(40) + TSM.

-- Lumber entry by itemID: built once; exposes shortName + expansion for column tinting.
local _lumberByID
local function lumberByID()
    if _lumberByID then return _lumberByID end
    _lumberByID = {}
    for _, l in ipairs(HDG.Constants.LUMBER_DATA or {}) do
        _lumberByID[l.id] = l
    end
    return _lumberByID
end

-- Resolve item icon: C_Item.GetItemIconByID first, then GetItemInfoInstant 5th return.
local function resolveItemIcon(itemID)
    if not itemID then return HDG.Constants.PLACEHOLDER_ICON end   -- "?" default
    -- exception(boundary): cold cache -> API returns nil; PLACEHOLDER_ICON covers it
    local icon = C_Item.GetItemIconByID(itemID)
    if icon then return icon end
    local _, _, _, _, fallbackIcon = C_Item.GetItemInfoInstant(itemID)
    return fallbackIcon or HDG.Constants.PLACEHOLDER_ICON  -- exception(boundary): GetItemInfoInstant cold cache -> '?' icon
end

-- Profession atlas from PROFESSION_DATA. Goblin row uses profession icon (not item icon).
local _profAtlasByName
local function profAtlasByName(name)
    if not _profAtlasByName then
        _profAtlasByName = {}
        for _, p in ipairs(HDG.Constants.PROFESSION_DATA or {}) do
            if p.name and p.atlas then _profAtlasByName[p.name] = p.atlas end
        end
    end
    return name and _profAtlasByName[name] or nil
end

-- Column cell: fixed width, right-justified. isFirst -> anchors to parent RIGHT; else chains leftward.
local function _addColumnCell(row, width, anchorTo, gap, isFirst)
    local fs = HDG.UI.RowText(row, "small", "Text")
    fs:SetSize(width, 14)
    if isFirst then
        fs:SetPoint("RIGHT", anchorTo, "RIGHT", -gap, 0)
    else
        fs:SetPoint("RIGHT", anchorTo, "LEFT", -gap, 0)
    end
    fs:SetJustifyH("RIGHT")
    fs:SetWordWrap(false)
    return fs
end

-- TSM columns chain RIGHTWARD (opposite of _addColumnCell which chains leftward).
local function _addRightCell(row, width, anchorTo, gap)
    local fs = HDG.UI.RowText(row, "small", "Text", "RIGHT")
    fs:SetSize(width, 14)
    fs:SetPoint("LEFT", anchorTo, "RIGHT", gap, 0)
    fs:SetWordWrap(false)
    return fs
end

-- ===== _goblinRowFactory primitives ==========================================
-- First-paint: icon + 12 cells. pct cell = anchor; 7 columns chain LEFT, 4 TSM chain RIGHT.
local function _layoutGoblinRow(row)
    if row.CreateTexture then  -- exception(false-positive): Frame always has CreateTexture; mock-fidelity guard
        local icon = row:CreateTexture(nil, "OVERLAY")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        icon:SetTexCoord(unpack(HDG.Constants.ICON_CROP))
        row._iconTex = icon
    end
    -- One-time click hook; Configure stamps _currentItemID + _recipeID + _name per paint.
    -- Shift-click queues the recipe (1 per click); a plain click toggles the detail panel.
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if not self._currentItemID then return end
        if IsShiftKeyDown() then
            HDG.UI.QueueRecipe(self._recipeID, self._currentItemID, self._name)
            return
        end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.GOBLIN_TOGGLE_ROW_EXPAND,
            payload = { itemID = self._currentItemID },
        })
    end)
    -- pct fixed at 710px from row.LEFT (core right edge; +40 vs the old 670 for the
    -- wider Lumber column, so the whole chain stays under the headers).
    row._pctFs = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(row._pctFs, "small")
    HDG.Theme:Register(row._pctFs, "Text")
    row._pctFs:SetSize(40, 14)
    row._pctFs:SetPoint("RIGHT", row, "LEFT", 710, 0)
    row._pctFs:SetJustifyH("RIGHT")
    row._pctFs:SetWordWrap(false)
    row._profitFs = _addColumnCell(row, 80,  row._pctFs,    4, false)
    row._sellFs   = _addColumnCell(row, 70,  row._profitFs, 4, false)
    row._costFs   = _addColumnCell(row, 70,  row._sellFs,   4, false)
    row._perLumFs = _addColumnCell(row, 70,  row._costFs,   4, false)
    row._lumberFs = _addColumnCell(row, 140, row._perLumFs, 4, false)
    -- #AH (always shown) chains right off pct; TSM block then chains off #AH.
    row._ahFs        = _addRightCell(row, 40, row._pctFs,       4)
    row._tsmMinFs    = _addRightCell(row, 70, row._ahFs,        4)   -- 70 fits 999,999g (matches Cost/Sell)
    row._tsmMarketFs = _addRightCell(row, 70, row._tsmMinFs,    4)
    row._tsmRegionFs = _addRightCell(row, 70, row._tsmMarketFs, 4)
    row._tsmPctFs    = _addRightCell(row, 50, row._tsmRegionFs, 4)
    row._saleRateFs  = _addRightCell(row, 50, row._tsmPctFs,    4)   -- "Rate" (TSM-gated)
    row._perDayFs    = _addRightCell(row, 50, row._saleRateFs,  4)   -- "/Day" (TSM-gated)
    local name = HDG.UI.RowText(row, "small", "Text")
    if row._iconTex then
        name:SetPoint("LEFT", row._iconTex, "RIGHT", 4, 0)
    else
        name:SetPoint("LEFT", row, "LEFT", 6, 0)
    end
    name:SetPoint("RIGHT", row._lumberFs, "LEFT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row._nameFs = name

    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.RecipeRow)   -- R4 tooltip; stamps per Configure

    row._goblinLaidOut = true
end

-- Profession icon: SetAtlas resets the Texture path; SetTexCoord is ignored once atlas takes over.
local function _paintGoblinIcon(row, ed)
    if not row._iconTex then return end
    local atlas = profAtlasByName(ed.profession)
    if atlas and row._iconTex.SetAtlas then  -- exception(boundary): SetAtlas absent in some Blizzard client builds; fallback to SetTexture
        row._iconTex:SetAtlas(atlas)
    elseif row._iconTex.SetTexture then  -- exception(false-positive): Texture always has SetTexture; mock-fidelity guard
        row._iconTex:SetTexture(resolveItemIcon(ed.itemID))
    end
end

-- Lumber column: expansion-tinted name + owned count (success/uncollected; 0 omitted).
local function _paintLumberColumn(row, ed)
    local lumber = ed.lumberType and lumberByID()[ed.lumberType] or nil
    if not lumber then
        row._lumberFs:SetText("")   -- base color comes from the RowText role (repaints on scheme switch)
        return
    end
    local owned = ed.ownedLumber  -- stamped by goblin.rows selector (ADR-041; no mid-paint API)
    -- Need rolls in the lumber the craft queue already commits for this lumber type, so
    -- held vs need shows whether you can cover this craft on TOP of what's queued.
    local need  = ed.lumberQty + ed.queuedLumber  -- both numeric, stamped by goblin.rows
    local short = lumber.shortName or lumber.name or ""
    -- Inline |cFF (text rail): no SetTextColor to reset; repaints on scheme switch via goblin.rows.
    local hex     = HDG.Expansion.GetColorHex(lumber.expansion)
    local nameHex = hex and (hex .. short .. "|r") or short
    -- "name held/need" (matches the reagent-tooltip order); the held figure turns red when
    -- held can't cover this craft plus the queue -- exactly when "Have lumber" hides it.
    local heldHex = HDG.Theme:GetTextStateColorToken(owned >= need and "success" or "uncollected")
    row._lumberFs:SetText(string.format("%s %s%d|r/%d", nameHex, heldHex, owned, need))
end

-- TSM columns: Show/populate when isTSMActive, else Hide (stamped by goblin.rows selector).
local function _paintTsmColumns(row, ed)
    if not ed.isTSMActive then
        row._tsmMinFs:Hide();    row._tsmMarketFs:Hide()
        row._tsmRegionFs:Hide(); row._tsmPctFs:Hide()
        row._saleRateFs:Hide();  row._perDayFs:Hide()
        return
    end
    row._tsmMinFs:Show();    row._tsmMarketFs:Show()
    row._tsmRegionFs:Show(); row._tsmPctFs:Show()
    row._saleRateFs:Show();  row._perDayFs:Show()
    row._tsmMinFs:SetText(ed.tsmMin       and moneyText(ed.tsmMin)    or "-")
    row._tsmMarketFs:SetText(ed.tsmMarket and moneyText(ed.tsmMarket) or "-")
    row._tsmRegionFs:SetText(ed.tsmRegion and moneyText(ed.tsmRegion) or "-")
    row._tsmPctFs:SetText(ed.tsmPct and string.format("%d%%",
        math.floor(ed.tsmPct + 0.5)) or "-")
    -- Rate = TSM sale rate (% of postings that sell). saleRate is per-mille (rate x1000), so
    -- /10 -> 1-decimal percent (0.032 -> "3.2%"). /Day = real units/realm/day.
    row._saleRateFs:SetText((ed.saleRate and ed.saleRate > 0)
        and string.format("%.1f%%", ed.saleRate / 10) or "-")
    row._perDayFs:SetText((ed.soldPerDay and ed.soldPerDay > 0)
        and _compactCount(ed.soldPerDay) or "-")
end

-- Profit: success (positive), error (negative), "?" when unpriceable.
local function _paintProfitCell(row, ed)
    local prof = ed.profit
    if prof and prof > 0 then
        row._profitFs:SetText(
            HDG.Theme:StateLabel("success", "+" .. moneyText(prof)))
    elseif prof and prof < 0 then
        row._profitFs:SetText(
            HDG.Theme:StateLabel("error", moneyText(prof)))
    elseif prof then
        row._profitFs:SetText(moneyText(prof))
    else
        row._profitFs:SetText("?")
    end
end

local GOBLIN_RESET_FS = {
    "_nameFs","_lumberFs","_perLumFs","_costFs","_sellFs",
    "_ahFs","_tsmMinFs","_tsmMarketFs","_tsmRegionFs","_tsmPctFs",
    "_saleRateFs","_perDayFs",
    "_profitFs","_pctFs",
}
-- Mouse-action hints for goblin row tooltips (R.RecipeRow is shared with the
-- recipe-list / queue rows, which DON'T stamp _clickHints, so only goblin rows
-- surface these). Same wording as the goblin header clickHints.
local GOBLIN_ROW_HINTS = {
    leftText  = "locale:MOG_GOBLIN_HINTS_LEFT",
    shiftText = "locale:MOG_GOBLIN_HINTS_SHIFT",
}

local function _resetGoblinRow(row)
    if row._iconTex and row._iconTex.SetTexture then row._iconTex:SetTexture(nil) end
    row._itemID, row._recipeID, row._name = nil, nil, nil   -- clear R4 tooltip stamps
    row._clickHints = nil
    HDG.UI.ClearRowText(row, unpack(GOBLIN_RESET_FS))
end

local function _goblinRowFactory(template)
    return {
        Configure = function(row, ed)
            if not row._goblinLaidOut then _layoutGoblinRow(row) end
            _paintGoblinIcon(row, ed)
            row._nameFs:SetText(ed.name or "?")
            row._currentItemID = ed.itemID                  -- click target for OnMouseUp
            row._itemID, row._recipeID, row._name = ed.itemID, ed.itemID, ed.name  -- R4 tooltip stamps
            row._clickHints = GOBLIN_ROW_HINTS              -- surfaces mouse actions on the row tooltip
            _paintLumberColumn(row, ed)
            row._perLumFs:SetText(ed.lumberValue  and moneyText(ed.lumberValue)  or "?")
            row._costFs:SetText(  ed.materialCost and moneyText(ed.materialCost) or "?")
            row._sellFs:SetText(  ed.sellPrice    and moneyText(ed.sellPrice)    or "?")
            _paintTsmColumns(row, ed)
            -- #AH: live AH count (Direct scan). nil = unscanned -> "-"; 0 = scanned, none listed.
            -- Green when any listed units are YOURS (Deadi, Discord 2026-06-13):
            -- the "don't craft another one" glance signal. Count source for the
            -- tint is the AH-open ownedAuctions snapshot, not the live scan.
            local ahText = ed.ahQty ~= nil and tostring(ed.ahQty) or "-"
            if ed.myListedQty then
                row._ahFs:SetText(HDG.Theme:StateLabel("success", ahText))
            else
                row._ahFs:SetText(ahText)
            end
            _paintProfitCell(row, ed)
            row._pctFs:SetText(ed.margin and string.format("%d%%",
                math.floor(ed.margin + 0.5)) or "?")
            row:SetHeight(template.height or 16)
        end,
        Reset = _resetGoblinRow,
    }
end

HDG.Rows:Register("goblinRow", {
    font    = "small",
    height  = 18,
    factory = _goblinRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        return "goblin:" .. tostring(ed.itemID or "?")
    end,
})

-- Goblin detail row: name | qty | owned (success >= qty, error otherwise) | cost.
local function _layoutGoblinDetailRow(row)
    row._costFs  = _addColumnCell(row, 80, row,           6, true)
    row._ownedFs = _addColumnCell(row, 60, row._costFs,   6, false)
    row._qtyFs   = _addColumnCell(row, 50, row._ownedFs,  6, false)
    local name = HDG.UI.RowText(row, "small", "Text", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", 8, 0)
    name:SetPoint("RIGHT", row._qtyFs, "LEFT", -8, 0)
    name:SetWordWrap(false)
    row._nameFs = name
    row._detailLaidOut = true
end

local function _paintGoblinDetailRow(row, ed, template)
    row._nameFs:SetText(ed.name or "?")
    row._qtyFs:SetText(tostring(ed.qty))
    -- Owned count: success when sufficient, error when short.
    local ownedColor = HDG.Theme:GetTextStateColorToken(
        ed.sufficient and "success" or "error")
    row._ownedFs:SetText(ownedColor .. tostring(ed.owned) .. "|r")
    row._costFs:SetText(ed.totalCost and ed.totalCost > 0
        and moneyText(ed.totalCost) or "-")
    row:SetHeight(template.height or 14)
end

local function _goblinDetailRowFactory(template)
    return {
        Configure = function(row, ed)
            if not row._detailLaidOut then _layoutGoblinDetailRow(row) end
            _paintGoblinDetailRow(row, ed, template)
        end,
        Reset = function(row)
            HDG.UI.ClearRowText(row, "_nameFs", "_qtyFs", "_ownedFs", "_costFs")
        end,
    }
end

HDG.Rows:Register("goblinDetailRow", {
    font    = "small",
    height  = 14,
    factory = _goblinDetailRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        return "gdetail:" .. tostring(ed.itemID or "?")
    end,
})

HDG.Rows:Register("mogulRow", {
    font    = "body",
    height  = function(_index, ed)
        if not ed then return 22 end
        if ed.kind == "mogulSection" then return 20 end
        return 22
    end,
    factory = _mogulRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        if ed.kind == "mogulSection" then
            return "sec:" .. tostring(ed.title or "?")
        end
        local prefix = ed.isRunnerUp and "ru:" or "pl:"
        return prefix .. tostring(ed.itemID or ed.spellID or "?")
    end,
})
