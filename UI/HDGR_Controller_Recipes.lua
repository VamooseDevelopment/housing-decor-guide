-- HDG.RecipesController
-- ============================================================================
-- Recipes tab behaviour layer. Registers two row kinds, wires
-- the search editbox + reset + queue Add/Clear buttons.
--
-- Element schemas (selectors emit these):
--   { kind = "profHeader", profession, label }   -- profession group header
--   { kind = "recipeRow",  recipeID, itemID, name, profession, expansion,
--                          icon, isKnown, isSelected }
--   { kind = "matRow",     itemID, name, qty }
--
-- The list scrollbox uses one rowKind "recipeRow"; the factory dispatches
-- per `ed.kind`. Materials use rowKind "matRow" with its own factory.

HDG = HDG or {}
HDG.RecipesController = HDG.RecipesController or {}

local RecipesController = HDG.RecipesController

-- Register at file-load; craft handlers may fire before Wire() runs.
if not HDG.Log:HasTag("craft") then
    HDG.Log:RegisterTags({
        craft = { user = true, level = "info", duration = 3 },
    })
end

-- Human-readable filter chain for the status rail. Reads post-dispatch state.
-- Example: "Filter: Decor -> The War Within -> Alchemy+Cooking -> Known".
local function _joinSet(set)
    local parts = {}
    for k in pairs(set) do parts[#parts + 1] = k end
    table.sort(parts)
    return table.concat(parts, "+")
end
local function buildFilterChain(state)
    local s = state.session.ui.recipes
    local a = state.account.ui.recipes
    local parts = {}
    if next(a.expansionFilter)  then parts[#parts + 1] = _joinSet(a.expansionFilter)  end
    local profSet = HDG.Selectors:Call("recipes.professionFilter", state, {})
    if next(profSet) then parts[#parts + 1] = _joinSet(profSet) end
    if s.listFilter and s.listFilter ~= "all" then
        if s.listFilter == "known" then parts[#parts + 1] = "Known"
        elseif s.listFilter == "ready" then parts[#parts + 1] = "Ready to Craft"
        elseif s.listFilter == "unknown" then parts[#parts + 1] = "Unknown"
        elseif s.listFilter == "decorUncollected" then parts[#parts + 1] = "Decor not collected"
        end
    end
    return "Filter: " .. table.concat(parts, " -> ")
end

local function pushFilterToast()
    -- Wire runs post-init; HDG.Log always present.
    HDG.Log:Info("filter", buildFilterChain(HDG.Store:GetState()))  -- exception(false-positive): top-level controller method (not a row factory)
end

local function pushQueueToast(msg)
    HDG.Log:Info("queue", msg)
end

-- ===== Active-filter run: chip cell kind ====================================
-- One kind renders BOTH expansion + profession chips (distinguished by
-- item.kind). Clicking removes that filter. binder + sizer share
-- _filterChipLabel so measured width matches the rendered label.
local function _filterChipLabel(item)
    if item.kind == "profession" then
        return "|A:" .. (item.atlas or "") .. ":12:12|a " .. (item.label or "")
    end
    -- Expansion chip: per-expansion brand color (same EXPANSION_DATA.color the
    -- Palette "expansion.*" namespace exposes) as the distinguishing tell.
    return HDG.Expansion.GetColorHex(item.id) .. (item.label or "") .. "|r"
end
HDG.ChipStrip:RegisterCellKind("recipesFilterChip", {
    constructor = function(parent, cfg)
        return HDG.ChipStrip:DefaultChipConstructor(parent, cfg)
    end,
    binder = function(chip, item, cfg)
        if not item then
            chip:Hide()
            chip:SetScript("OnClick", nil)
            return
        end
        HDG.UI:EnsureChipChrome(chip)
        chip:Show()
        chip:SetText(_filterChipLabel(item))
        HDG.Theme:Register(chip, "Button", { variant = "chip", active = false })
        if chip.SetScript then  -- exception(false-positive): chip is a Button frame; SetScript guaranteed; mock-fidelity guard
            chip:RegisterForClicks("LeftButtonUp")
            local isProf = item.kind == "profession"
            local id     = item.id
            chip:SetScript("OnClick", function()
                HDG.Store:Dispatch({
                    type    = isProf and HDG.Constants.ACTIONS.RECIPES_TOGGLE_PROFESSION
                                     or  HDG.Constants.ACTIONS.RECIPES_TOGGLE_EXPANSION,
                    payload = isProf and { profession = id } or { expansion = id },
                })
            end)
        end
    end,
    sizer = function(item, cfg)
        return HDG.ChipStrip:DefaultChipSizer({ label = _filterChipLabel(item) }, cfg)
    end,
})


-- ===== Craft dialog (StaticPopupDialogs) =====================================
-- Shown on queue-row craft click. Two paths: Craft 1 / Craft Max.
-- exception(boundary): StaticPopupDialogs is a Blizzard global, always present.
local _craftPendingSpellID, _craftPendingMax = nil, nil

StaticPopupDialogs["HDGR_CRAFT_RECIPE"] = {
    text         = "Craft %s",
    button1      = "Craft 1",
    button2      = "Craft Max (%d)",
    button3      = "Cancel",
    OnShow       = function(self, data)
        -- Adjust "Craft Max" button label to reflect maxCraftable.
        local maxBtn = _G[self:GetName() .. "Button2"]
        if maxBtn then
            maxBtn:SetFormattedText("Craft Max (%d)", _craftPendingMax or 1)
        end
    end,
    OnAccept     = function()  -- Craft 1
        if not _craftPendingSpellID then return end
        -- exception(boundary): IsTradeSkillReady gates whether the profession window is open
        if not C_TradeSkillUI.IsTradeSkillReady() then
            HDG.Log:Warn("craft", "Profession window not open -- use Open button first")
            return
        end
        C_TradeSkillUI.CraftRecipe(_craftPendingSpellID, 1, {})
    end,
    OnAlt        = function()  -- Craft Max
        if not _craftPendingSpellID then return end
        if not C_TradeSkillUI.IsTradeSkillReady() then
            HDG.Log:Warn("craft", "Profession window not open -- use Open button first")
            return
        end
        C_TradeSkillUI.CraftRecipe(_craftPendingSpellID, _craftPendingMax or 1, {})
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    showAlert    = false,
    noCancelOnReuse = false,
}

local function _showCraftDialog(spellID, name, maxCraftable)
    _craftPendingSpellID = spellID
    _craftPendingMax     = maxCraftable
    StaticPopup_Show("HDGR_CRAFT_RECIPE", name)
end

-- ===== Row factories ========================================================

-- ============================================================================
-- _recipeRowFactory primitives.
-- Heterogeneous row: header rows ("Inscription (12)") OR recipe rows.
-- ============================================================================

local function _layoutRecipeRow(row)
    HDG.UI:EnsureRowChrome(row)

    local name = HDG.UI.RowText(row, "caption", "Text", "LEFT")  -- smaller; fits more
    name:SetPoint("LEFT",  row, "LEFT",  4, 0)
    name:SetWordWrap(false)
    row._nameFs = name

    -- Quantity stepper: fixed zone at right edge. plus always visible;
    -- minus + qty appear only when queued. Button frames capture their own
    -- clicks so +/- don't trigger the row-body select.
    HDG.UI.WireStepperCluster(row, { qtyWidth = 18 })

    -- Meta column (readiness % in Ready mode; empty otherwise), anchored left of
    -- the stepper zone. Recipe-knowledge state reads from the name color + the
    -- Unknown filter -- no per-row star (was redundant).
    local meta = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    meta:SetPoint("RIGHT", row, "RIGHT", -62, 0)
    meta:SetWordWrap(false)
    row._metaFs = meta

    name:SetPoint("RIGHT", meta, "LEFT", -8, 0)

    -- R4 tooltip: attached once per pooled row (idempotent). Reads row._itemID /
    -- row._recipeID stamped per Configure; cleared on header rows (no tooltip).
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.RecipeRow)

    row._recipeLaidOut = true
end

-- Header row (e.g. "Inscription (12)"). Two shapes:
--   * bucketLabel + count -> "Inscription (12)" (readiness buckets)
--   * profession only     -> "Inscription"      (plain profession grouping)
-- ADR-024: row carries structured data; composition happens here.
local function _paintProfHeader(row, ed)
    row._itemID, row._recipeID, row._name = nil, nil, nil   -- shared pool: headers carry no R4 tooltip
    local headerText = (ed.bucketLabel and ed.count)
        and string.format("%s (%d)", ed.bucketLabel, ed.count)
        or  (ed.profession or "?")
    row._nameFs:SetText(HDG.Theme:ColorCode("semantic.accent") .. headerText .. "|r")
    row._metaFs:SetText("")
    -- Shared row pool: headers must hide the stepper a recipe row may have left.
    if row._plusBtn  then row._plusBtn:Hide()  end
    if row._minusBtn then row._minusBtn:Hide() end
    if row._qtyFs    then row._qtyFs:SetText("") end
    row:SetScript("OnClick", nil)
end

-- Recipe name colored by precedence:
--   isDecorCollected -> success (matches HDG "done" paint)
--   not isKnown      -> dim (recipe not learned)
--   otherwise        -> normal
-- Name color precedence: UNLEARNED (recipe not known by self or any alt) dims first
-- -- regardless of whether the decor is owned. Learned recipes show the collected
-- role if the decor is owned, else normal text.
local function _recipeNameColored(ed)
    local nm = ed.name or "?"
    if not ed.isKnown then
        return HDG.Theme:ColorCode("text.dim") .. nm .. "|r"
    end
    if ed.isDecorCollected then
        return HDG.Theme:StateLabel("collected", nm)
    end
    return nm
end

-- Readiness state by percentage. Three-tier color: error / warning / success.
local function _readinessState(pct)
    if pct >= 75 then return "success" end
    if pct >= 50 then return "warning" end
    return "error"
end

-- Meta line composition. Empty outside Ready mode; Ready mode shows a color-coded
-- readiness %. (Expansion dropped from the row -- it's filterable + redundant.)
local function _recipeMetaLine(ed)
    if not ed.readinessPercent then return "" end
    return string.format("%s%d%%|r",
        HDG.Theme:GetTextStateColorToken(_readinessState(ed.readinessPercent)),
        ed.readinessPercent)
end

local function _paintRecipeRow(row, ed)
    -- Stamp for the R4 tooltip recipe (attached once in _layoutRecipeRow).
    row._itemID, row._recipeID, row._name = ed.itemID, ed.recipeID, ed.name
    row._nameFs:SetText(_recipeNameColored(ed))
    row._metaFs:SetText(_recipeMetaLine(ed))

    -- Quantity stepper: + adds, - decrements. minus + qty shown only
    -- when queued. The Button frames capture their own clicks, so +/- never
    -- trigger the row-body select below.
    local qn = ed.queuedQty
    row._plusBtn:Show()
    row._plusBtn:SetScript("OnClick", function()
        HDG.UI.QueueRecipe(ed.recipeID, ed.itemID, ed.name)
    end)
    if qn > 0 then
        row._qtyFs:SetText(tostring(qn))
        row._minusBtn:Show()
        row._minusBtn:SetScript("OnClick", function()
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.CRAFT_QUEUE_DECREMENT,
                payload = { recipeID = ed.recipeID, qty = 1 },
            })
        end)
    else
        row._qtyFs:SetText("")
        row._minusBtn:Hide()
    end

    -- Row-body click: shift-click queues the recipe (1 per click); a plain click
    -- selects it + sets the unified focus (drives the queue model preview).
    -- Last click wins.
    row:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            HDG.UI.QueueRecipe(ed.recipeID, ed.itemID, ed.name)
            return
        end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.RECIPES_SELECT_RECIPE,
            payload = { recipeID = ed.recipeID },
        })
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.UI_SET_TRANSIENT,
            payload = { view = "recipes", key = "focusedItemID", value = ed.itemID },
        })
    end)
end

local function _resetRecipeRow(row)
    row:SetScript("OnClick", nil)
    row._itemID, row._recipeID, row._name = nil, nil, nil   -- clear R4 tooltip stamps on recycle
    if row._nameFs    then row._nameFs:SetText("") end
    if row._metaFs    then row._metaFs:SetText("") end
    -- Stepper reset: clear handlers + hide minus/qty (back to unqueued shape).
    if row._plusBtn  then row._plusBtn:SetScript("OnClick", nil);  row._plusBtn:Hide()  end
    if row._minusBtn then row._minusBtn:SetScript("OnClick", nil); row._minusBtn:Hide() end
    if row._qtyFs    then row._qtyFs:SetText("") end
end

local function _recipeRowFactory(template)
    return {
        Configure = function(row, ed)
            if not row._recipeLaidOut then _layoutRecipeRow(row) end
            HDG.Theme:Register(row, "RowChrome", { selected = ed.selected and true or false })
            if ed.kind == "profHeader" then
                _paintProfHeader(row, ed)
            else
                _paintRecipeRow(row, ed)
            end
            row:SetHeight(template.height)
        end,
        Reset = _resetRecipeRow,
    }
end

HDG.Rows:Register("recipeRow", {
    font    = "body",
    height  = 22,
    factory = _recipeRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        if ed.kind == "profHeader" then return "p:" .. tostring(ed.profession) end
        return "r:" .. tostring(ed.recipeID)
    end,
})

-- Materials row: heterogeneous dispatch on ed.kind.
--   matRow       -> name (left) + have/need with color (right). Green when
--                   covered, red when short.
--   matSubHeader -> accent section label, no qty column ("From Vendor", etc.)
-- Lazy chrome: name (fill) + qty (right), both "caption". One-time per row.
local function _layoutMatRow(row)
    local name = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    name:SetPoint("LEFT",  row, "LEFT",  4, 0)
    name:SetWordWrap(false)
    row._nameFs = name

    local qty = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(qty, "caption")
    qty:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    qty:SetJustifyH("RIGHT")
    qty:SetWordWrap(false)
    row._qtyFs = qty

    name:SetPoint("RIGHT", qty, "LEFT", -8, 0)
    -- Hover -> "Your stock" per-stash breakdown, shared with the Warehouse mat rows
    -- (TooltipRecipes.MaterialStock reads stamped _tip* fields live; def is pool-safe).
    -- EnableMouse so the non-selectable row receives hover; matSubHeader rows clear
    -- _tipName so the def renders nothing for section headers.
    row:EnableMouse(true)
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.MaterialStock)
    row._matLaidOut = true
end

-- matSubHeader: accent section label, no qty column ("From Vendor" / "From Gathering"
-- in Totals; the recipe name in By Recipe). Matches the recipe-list profession headers.
local function _paintMatSubHeader(row, ed)
    row._nameFs:SetText(HDG.Theme:ColorCode("semantic.accent") .. (ed.label or "") .. "|r")
    row._qtyFs:SetText("")
    row._tipName   = nil   -- section header: no stock tooltip
    row._tipItemID = nil   -- pooled row: a stale itemID would render a stray item tooltip
end

-- matRow: name (left) + have/need, green when covered, red when short.
local function _paintMatRow(row, ed)
    row._nameFs:SetText(ed.name or ("item " .. tostring(ed.itemID or "?")))
    local need = ed.qty   -- recipes.materialRows: qty numeric (selector does have>=need)
    local have = ed.have  -- recipes.materialRows stamps have (counts or 0)
    local color = HDG.Theme:GetTextStateColorToken(ed.covered and "success" or "error")
    row._qtyFs:SetText(string.format("%s%d / %d|r", color, have, need))
    -- Stamp the hover tooltip's fields (read live by TooltipRecipes.MaterialStock).
    row._tipName    = ed.name
    row._tipItemID  = ed.itemID
    row._tipWarband = ed.warband
    row._tipNeed    = need
end

-- Shift-click links the material, which the Auction House picks up as a search
-- when it is open -- the same gesture as the Warehouse materials list. A plain
-- click is a no-op here: this pane is driven by the recipe selection above it.
local function _wireMatRow(row, ed)
    row:SetScript("OnClick", function()
        if IsShiftKeyDown() then HDG.UI.LinkMaterial(ed.itemID, ed.name) end
    end)
end

local function _matRowFactory(template)
    return {
        Configure = function(row, ed)
            if not row._matLaidOut then _layoutMatRow(row) end
            if ed.kind == "matSubHeader" then
                _paintMatSubHeader(row, ed)
                row:SetScript("OnClick", nil)   -- a section header has no item to link
            else
                _paintMatRow(row, ed)
                row:RegisterForClicks("LeftButtonUp")
                _wireMatRow(row, ed)
            end
            row:SetHeight(template.height)
        end,
        Reset = function(row)
            row:SetScript("OnClick", nil)
            HDG.UI.ClearRowText(row, "_nameFs")
            if row._qtyFs  then row._qtyFs:SetText("")  end
            row._tipName = nil   -- no tooltip on a pooled-but-unpainted row
        end,
    }
end

HDG.Rows:Register("matRow", {
    font    = "body",
    height  = 20,
    factory = _matRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        if ed.kind == "matSubHeader" then
            -- ByRecipe subheaders carry fromPosition; source already encodes
            -- position via "recipe:N" prefix but keeping the explicit fold
            -- makes the key shape consistent with the matRow path below.
            return "h:" .. tostring(ed.source)
        end
        -- ByRecipe mode lets the same itemID appear in multiple queue rows.
        -- Include fromPosition in the key so the scrollbox doesn't error on
        -- duplicate "m:NNN" keys. Other modes merge by itemID, so plain key
        -- stays unique.
        if ed.fromPosition then
            return "m:" .. tostring(ed.itemID) .. ":p:" .. tostring(ed.fromPosition)
        end
        return "m:" .. tostring(ed.itemID)
    end,
})


-- Queue row: "Nx Recipe Name" left, "x" right.
-- Left click selects in master list; right click removes + toasts.
-- Craft button width fits "99+" + padding.
local CRAFT_BTN_W = 40
local CRAFT_BTN_H = 14

local function _layoutQueueRow(row)
    local name = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    name:SetPoint("LEFT",  row, "LEFT",  4, 0)
    name:SetWordWrap(false)
    row._nameFs = name

    -- Craft button: shown only when selfKnown + canCraft. Fixed RIGHT anchor -- sits at
    -- the edge now (the old "x" marker is gone; removal is right-click, per the queue hints).
    local craftBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    craftBtn:SetSize(CRAFT_BTN_W, CRAFT_BTN_H)
    craftBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    craftBtn:Hide()
    HDG.Theme:Register(craftBtn, "Button", { variant = "accent" })
    local craftFs = craftBtn:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(craftFs, "caption")
    craftFs:SetAllPoints()
    craftFs:SetJustifyH("CENTER")
    craftBtn._fs = craftFs
    row._craftBtn = craftBtn

    name:SetPoint("RIGHT", craftBtn, "LEFT", -4, 0)

    -- R4 tooltip; _qtyMult scales materials by the queued count.
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.RecipeRow)
end

local function _paintQueueRow(row, ed)
    -- R4 tooltip stamps; _qtyMult scales the materials by the queued count.
    row._itemID, row._recipeID, row._name = ed.itemID, ed.recipeID, ed.name
    row._qtyMult = ed.remaining
    row._nameFs:SetText(string.format("%dx %s", ed.remaining or 1, ed.name or "?"))  -- exception(boundary): queue row from SVars may lack remaining
    local btn = row._craftBtn
    if btn then
        if ed.canCraft and ed.selfKnown then
            local maxStr = (ed.maxCraftable) > 99 and "99+" or tostring(ed.maxCraftable)
            btn._fs:SetText(maxStr)
            btn:Show()
        else
            btn:Hide()
        end
    end
end

local function _resetQueueRow(row)
    row._itemID, row._recipeID, row._name, row._qtyMult = nil, nil, nil, nil  -- clear R4 stamps
    if row._craftBtn then
        row._craftBtn:Hide()
        row._craftBtn:SetScript("OnClick", nil)
    end
end

-- Left-click toggles queueSelectedRecipeID (scopes materials; re-click clears).
-- Right-click removes from queue + toasts count. Craft button opens StaticPopup.
local function _wireQueueRow(row, ed)
    if row._craftBtn then
        row._craftBtn:SetScript("OnClick", function()
            if not ed.spellID then return end
            -- exception(boundary): IsTradeSkillReady checks profession window open
            if not C_TradeSkillUI.IsTradeSkillReady() then
                C_TradeSkillUI.OpenRecipe(ed.spellID)
                HDG.Log:Info("craft", "Opening profession window for " .. (ed.name or "recipe"))
                return
            end
            _showCraftDialog(ed.spellID, ed.name or "recipe", ed.maxCraftable)
        end)
    end
    HDG.UI.WireLeftRightClick(row,
        function()
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.RECIPES_TOGGLE_QUEUE_SELECTION,
                payload = { recipeID = ed.recipeID },
            })
            -- Unified focus: queue-row click focuses its decor for the model preview.
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.UI_SET_TRANSIENT,
                payload = { view = "recipes", key = "focusedItemID", value = ed.itemID },
            })
        end,
        function()
            local removedName = ed.name or "recipe"
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.CRAFT_QUEUE_REMOVE,
                payload = { position = ed.position },
            })
            local remaining = #HDG.Store:GetState().account.craft.queue  -- exception(false-positive): top-level controller read
            if remaining > 0 then
                pushQueueToast("Removed " .. removedName .. " (queue: " .. remaining .. ")")
            else
                pushQueueToast("Removed " .. removedName .. " (queue empty)")
            end
        end)
end

HDG.Rows:Register("queueRow", {
    font    = "body",
    height  = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutQueueRow,
        paint      = _paintQueueRow,
        laidOutTag = "_queueLaidOut",
        selectable = true,
        wire       = _wireQueueRow,
        resetText  = { "_nameFs" },
        reset      = _resetQueueRow,
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "q:" .. tostring(ed.position) .. ":" .. tostring(ed.recipeID)
    end,
})

-- craftTheseRow: "Name xQty" (alphabetized materials footer).
-- Name color via GetTextStateColorToken (success / warning / dim).
local function _layoutCraftOrderRow(row)
    local name = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    name:SetPoint("LEFT",  row, "LEFT",  4, 0)
    name:SetWordWrap(false)
    local qty = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    qty:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    qty:SetWordWrap(false)
    name:SetPoint("RIGHT", qty, "LEFT", -4, 0)
    row._nameFs = name
    row._qtyFs  = qty
end

local function _paintCraftOrderRow(row, ed)
    local color = HDG.Theme:GetTextStateColorToken(
        ed.craftableState or HDG.Constants.RECIPE_STATE.UnknownOnAccount)
    row._nameFs:SetText(string.format("%s%s|r", color, ed.name or "?"))
    row._qtyFs:SetText("x" .. tostring(ed.qty))
end

HDG.Rows:Register("craftTheseRow", {
    font    = "caption",
    height  = 16,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutCraftOrderRow,
        paint      = _paintCraftOrderRow,
        laidOutTag = "_coLaidOut",
        resetText  = { "_nameFs", "_qtyFs" },
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "ct:" .. tostring(ed.itemID)
    end,
})

-- Queue readiness row: "100%  RecipeName". Sorted desc by pct upstream.
-- Pct colored by readiness (100% = success, partial = dim). Name color
-- follows craftableState. Bottleneck reagent omitted (queue glance is
-- WHICH recipes are close, not what's missing -- see materials panel).
local PCT_COLUMN_WIDTH = 36   -- fits "100%" + breathing room
-- Lazy chrome: fixed-width pct column (names align) + name to its right.
local function _layoutQueueReadinessRow(row)
    local pctFs = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(pctFs, "caption")
    pctFs:SetPoint("LEFT", row, "LEFT", 4, 0)
    pctFs:SetWidth(PCT_COLUMN_WIDTH)
    pctFs:SetJustifyH("RIGHT")
    local name = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    name:SetPoint("LEFT", pctFs, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    name:SetWordWrap(false)
    row._pctFs   = pctFs
    row._nameFs  = name
end

local function _paintQueueReadinessRow(row, ed)
    local pct = math.floor((ed.pct) * 100 + 0.5)
    -- Pct color: 100% in success-green (ready to fire); partial in dim.
    -- Inline color escape so the column reads at a glance.
    local pctColor = (pct >= 100)
        and HDG.Theme:ColorCode("semantic.success")
        or  HDG.Theme:ColorCode("text.dim")
    row._pctFs:SetText(string.format("%s%d%%|r", pctColor, pct))
    local nameColor = HDG.Theme:GetTextStateColorToken(
        ed.craftableState or HDG.Constants.RECIPE_STATE.UnknownOnAccount)
    row._nameFs:SetText(string.format("%s%s|r", nameColor, ed.name or "?"))
end

local function _resetQueueReadinessRow(row)
    row._pctFs:SetText("")
end

HDG.Rows:Register("queueReadinessRow", {
    font    = "caption",
    height  = 16,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutQueueReadinessRow,
        paint      = _paintQueueReadinessRow,
        laidOutTag = "_qrLaidOut",
        resetText  = { "_nameFs" },
        reset      = _resetQueueReadinessRow,
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "qr:" .. tostring(ed.recipeID)
    end,
})

-- ===== Wire =================================================================

function RecipesController:Wire(rootFrame)
    -- SelectionBehaviorMixin sync: recipes.groupedRows doesn't read
    -- selectedRecipeID, so clicks don't rebuild the grouped list.
    local recipeList = HDG.UI.W(rootFrame, "recipesListPanel.list")
    if recipeList and recipeList.WireStoreSelectionSync then
        recipeList:WireStoreSelectionSync("session.ui.recipes.selectedRecipeID",
            function(ed, id) return id ~= nil and ed.recipeID == id end)   -- nil id: profession headers carry no recipeID and must not match
    end

    -- Dynamic group breadcrumb: reflects the GROUP at the TOP of the visible list.
    -- Set imperatively on OnDataRangeChanged (scroll position is ephemeral, not Store
    -- state). Read .groupLabel, NOT .profession -- in Ready mode rows are grouped by
    -- readiness bucket but still carry their real .profession, so groupLabel is the
    -- single field that tracks the active grouping (profession / bucket).
    local breadcrumbFs = HDG.UI.W(rootFrame, "recipesListPanel.breadcrumb")
    local scrollBox    = recipeList and recipeList._scrollBox
    if breadcrumbFs and scrollBox and scrollBox.RegisterCallback and scrollBox.FindElementData then
        local lastGroup
        local function setBreadcrumb(beginIndex)
            -- exception(nullable): closing the window releases the list's data and the
            -- ScrollBox still reports the range change -- a list with no data has no group.
            local ed    = beginIndex and scrollBox:HasDataProvider() and scrollBox:FindElementData(beginIndex)
            local group = ed and ed.groupLabel
            if group == lastGroup then return end   -- skip redundant SetText churn
            lastGroup = group
            breadcrumbFs:SetText(group and (HDG.Theme:ColorCode("semantic.accent") .. group .. "|r") or "")
        end
        scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnDataRangeChanged,
            function(_, beginIndex) setBreadcrumb(beginIndex) end, breadcrumbFs)
        setBreadcrumb(scrollBox.GetDataIndexBegin and scrollBox:GetDataIndexBegin())
    end

    -- Scan Guild: kicks off the guild recipe harvest (ProfessionScanner owns the
    -- choreography; the button label tracks progress via recipes.scanGuildLabel).
    -- Second click mid-run cancels.
    HDG.UI.OnClick(rootFrame, "recipesListPanel.scanGuild", function()
        if HDG.Store:GetState().session.recipeHarvest.active then
            HDG.ProfessionScanner:CancelGuildHarvest()
        else
            HDG.ProfessionScanner:StartGuildHarvest()
        end
    end)

    -- Clear all: empties both persisted filter sets via the "all" sentinel.
    -- Per-chip removal is wired by the recipesFilterChip binder.
    HDG.UI.OnClick(rootFrame, "recipesStripPanel.runClear", function()
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.RECIPES_TOGGLE_EXPANSION,
            payload = { expansion = "all" },
        })
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.RECIPES_TOGGLE_PROFESSION,
            payload = { profession = "all" },
        })
        pushFilterToast()
    end)

    -- The chip strip publishes its real wrapped height to session.ui.recipes.runHeight;
    -- recipes.gridRows reads it to size the strip cell exactly. Deferred + deduped
    -- so the publish -> relayout -> re-measure cycle converges quickly.
    local runChips = HDG.UI.W(rootFrame, "recipesStripPanel.runChips")
    if runChips and runChips._chipStripCfg then
        runChips._chipStripCfg.onMeasure = function(h)
            h = math.ceil(h or 0)
            if h == math.ceil(HDG.Store:GetState().session.ui.recipes.runHeight) then return end  -- exception(false-positive): top-level controller read
            if not _G.RunNextFrame then return end   -- exception(boundary): pre-12.0 / headless
            -- RunNextFrame defers past in-flight FlowContainer layout (no re-entrant
            -- dispatch) then publishes measured height + reflows.
            _G.RunNextFrame(function()
                if h == math.ceil(HDG.Store:GetState().session.ui.recipes.runHeight) then return end  -- exception(false-positive): top-level controller read
                HDG.ControllerHelpers.Mechanics.SetUITransientView("recipes", "runHeight", h)
                if HDG.RefreshMainWindow then HDG:RefreshMainWindow() end  -- exception(false-positive): engine method guard in RunNextFrame callback; RefreshMainWindow is a top-level HDG method
            end)
        end
    end

    -- Queue list selection: highlight follows queueSelectedRecipeID.
    -- The sync subscriber re-scopes materials via effectiveQueue.
    local queueList = HDG.UI.W(rootFrame, "recipesQueuePanel.list")
    if queueList and queueList.WireStoreSelectionSync then
        queueList:WireStoreSelectionSync("session.ui.recipes.queueSelectedRecipeID",
            function(ed, id) return id ~= nil and ed.recipeID == id end)
    end

    -- Search editbox: every keystroke dispatches RECIPES_SET_SEARCH.
    local searchBox = HDG.UI.W(rootFrame, "recipesListPanel.search")
    HDG.UI.WireTextChanged(searchBox, function(text)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.RECIPES_SET_SEARCH, payload = { query = text } })
    end)

    HDG.UI.OnClick(rootFrame, "recipesListPanel.resetFilters", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.UI_FILTER_RESET,
            payload = { tab = "recipes" },
        })
        if searchBox and searchBox.SetText then searchBox:SetText("") end
        pushFilterToast()
    end)

    -- List filter is a full-width dropdown now -- it self-dispatches
    -- RECIPES_SET_LIST_FILTER via its `dispatch` spec (no controller wiring).

    -- Expansion + Materials-mode dropdowns self-wire via kind="dropdown"
    -- (see LayoutConfig_Recipes.lua); they dispatch directly.

    -- Queue Add: enqueues 1 of the currently-selected recipe.
    HDG.UI.OnClick(rootFrame, "recipesQueuePanel.add", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local rid   = state.session.ui.recipes.selectedRecipeID
        if not rid then return end
        local r = HDG.StaticData.Recipes:Get(rid)
        if not r then return end
        HDG.UI.QueueRecipe(rid, r.itemID, r.name, { source = "manual", sessionKey = "ui" })
    end)

    HDG.UI.OnClick(rootFrame, "recipesQueuePanel.clear", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CRAFT_QUEUE_CLEAR })
        pushQueueToast("Queue cleared")
    end)

    -- Send missing materials to Auctionator. Owned mats discounted (deficit only).
    -- Does NOT write HDG's own shopping list.
    HDG.UI.OnClick(rootFrame, "recipesMaterialsPanel.addAll", function()
        local rows = HDG.Selectors:Call("recipes.materials.current", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller method (not a row factory)
        local reagents = {}
        for _, r in ipairs(rows) do
            if r.kind == "matRow" then
                local deficit = (r.qty or 0) - (r.have or 0)
                if deficit > 0 then
                    reagents[#reagents + 1] = { id = r.itemID, qty = deficit }
                end
            end
        end
        local n, present = HDG.UI.SendReagentsToAuctionator("HDG Recipe Materials", reagents)
        local msg
        if not present then
            msg = "Auctionator not installed"
        elseif n > 0 then
            msg = "Sent " .. n .. " materials to Auctionator"
        else
            msg = "No missing materials"
        end
        pushQueueToast(msg)
    end)

    -- Materials grouping toggle: flips Totals <-> By Recipe. The depth radio
    -- self-dispatches via its `dispatch` spec; no controller wiring needed.
    HDG.UI.OnClick(rootFrame, "recipesMaterialsPanel.groupingToggle", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.RECIPES_TOGGLE_MATERIALS_GROUPING })
    end)
end

function RecipesController:Refresh(rootFrame, ctx)
    -- All detail-pane widgets bind through selectors; nothing imperative.
end

HDG.Controllers:Register("recipes", RecipesController)
