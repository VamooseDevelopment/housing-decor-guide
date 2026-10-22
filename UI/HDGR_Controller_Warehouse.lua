-- HDG.WarehouseController -- row factories + wiring for the Warehouse view.
-- Three row kinds:
--   lumberRow        7-column lumber-stock table (bag/bank/warband/need/stock)
--   warehouseMatRow  distinct basic reagent (name + have/need), click-to-select
--   usedInRow        recipes that use the selected material (click re-selects)
--
-- Selectors live in HDGR_Selectors_Recipes.lua (warehouse.* IDs); LayoutConfig
-- in HDGR_LayoutConfig_Warehouse.lua. Material selection writes
-- session.ui.warehouse.selectedMaterialID (RECIPES_SELECT_MATERIAL).

HDG = HDG or {}
HDG.WarehouseController = HDG.WarehouseController or {}
local WarehouseController = HDG.WarehouseController

local A = HDG.Constants.ACTIONS

-- ===== Lumber stocks row =====================================================
-- 7 fixed-width columns; widths must match warehouse.lumberHeader in LayoutConfig.
local LUMBER_COLS = {
    { key = "name",    width = 90,  align = "LEFT"  },
    { key = "exp",     width = 44,  align = "LEFT"  },   -- room for WotLK / Mists etc. acronyms
    { key = "bag",     width = 36,  align = "RIGHT" },
    { key = "bank",    width = 36,  align = "RIGHT" },
    { key = "warband", width = 44,  align = "RIGHT" },
    { key = "needed",  width = 42,  align = "RIGHT" },
    { key = "stock",   width = 64,  align = "RIGHT" },
}
local LUMBER_COL_GAP = 2

-- The lumber row hover (milestone achievement + the other characters holding this
-- lumber) is HDG.TooltipRecipes.LumberStock, alongside its MaterialStock sibling.
-- It reads the stamped _tip* fields live, so the def is pool-safe.

local function _layoutLumberStockRow(row)
    row._cols = {}
    local x = 4
    for _, col in ipairs(LUMBER_COLS) do
        local fs = HDG.UI.RowText(row, "body", "Text")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(col.width)
        fs:SetJustifyH(col.align)
        fs:SetWordWrap(false)
        row._cols[col.key] = fs
        x = x + col.width + LUMBER_COL_GAP
    end
    -- Hover -> milestone achievement + other characters' stock (shared recipe,
    -- reads the stamped _tip* fields live). EnableMouse so the static stock row
    -- receives hover; Attach is pool-safe (re-attach guard).
    row:EnableMouse(true)
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.LumberStock)
end

local function _paintLumberStockRow(row, ed)
    -- Name tinted by the lumber's expansion brand color (scheme-invariant Palette).
    local exHex = HDG.Expansion.GetColorHex(ed.expansion)
    row._cols.name:SetText(exHex and (exHex .. (ed.name or "?") .. "|r") or (ed.name or "?"))
    -- Expansion acronym goes GOLD (TextWarning) once the lumber-farming milestone
    -- achievement is earned, dim otherwise -- completed expansions pop. The row
    -- tooltip (OnEnter) carries the achievement name + progress, then the other
    -- characters holding this lumber.
    row._cols.exp:SetText(ed.expansionShort or "")
    HDG.Theme:Register(row._cols.exp, ed.achEarned and "TextWarning" or "TextDim")
    -- Stamps the hover recipe reads (TooltipRecipes.LumberStock).
    row._tipAchieveID = ed.achieveID
    row._tipItemID    = ed.itemID
    row._cols.bag:SetText(tostring(ed.bag))
    row._cols.bank:SetText(tostring(ed.bank))
    row._cols.warband:SetText(tostring(ed.warband))
    row._cols.needed:SetText(tostring(ed.queueNeed))
    -- Stock column: when requiredTotal==0 (no uncollected decor needs this
    -- lumber -> you're done with it) show the held count in success color;
    -- otherwise stock/required with state color.
    local required = ed.requiredTotal
    if required == 0 then
        local color = HDG.Theme:GetTextStateColorToken("success")
        row._cols.stock:SetText(string.format("%s%d|r", color, ed.stock))
    else
        local st = "error"
        if ed.covered then       st = "success"
        elseif ed.anyStock then  st = "warning" end
        local color = HDG.Theme:GetTextStateColorToken(st)
        row._cols.stock:SetText(string.format("%s%d/%d|r", color, ed.stock, required))
    end
end

HDG.Rows:Register("lumberRow", {
    font    = "body",
    height  = 20,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutLumberStockRow,
        paint      = _paintLumberStockRow,
        laidOutTag = "_lumberLaidOut",
        reset      = function(row)
            if not row._cols then return end
            for _, fs in pairs(row._cols) do fs:SetText("") end
        end,
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "lumber:" .. tostring(ed.itemID or "?")
    end,
})

-- ===== All Materials row =====================================================
-- name (fill) + have/need qty + 3 location chips (bag/bank/warband).
-- Chip atlases mirror HDG_MaterialsList.lua:933-946:
--   warband = "warbands-icon", bank = "Banker", bag = "ParagonReputation_Bag"
local WH_MAT_CHIP_SIZE = 14
local WH_MAT_CHIP_GAP  = 2
-- Total right-edge reservation for 3 chips: 3*(14+2) = 48px, minus trailing gap.
local WH_MAT_CHIPS_W   = 3 * (WH_MAT_CHIP_SIZE + WH_MAT_CHIP_GAP) - WH_MAT_CHIP_GAP

-- Materials-row tooltip ("Your stock" per-stash breakdown) is shared with the Recipes
-- materials pane -- see HDG.TooltipRecipes.MaterialStock. Both stamp the same _tip* fields
-- per-paint (pool-safe) and the def reads them live at hover.

local function _layoutWarehouseMatRow(row)
    local name = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    name:SetPoint("LEFT",  row, "LEFT",  4, 0)
    name:SetWordWrap(false)
    -- 3 icon chips anchored right, stacked right-to-left.
    local chipWarband = row:CreateTexture(nil, "OVERLAY")
    chipWarband:SetSize(WH_MAT_CHIP_SIZE, WH_MAT_CHIP_SIZE)
    chipWarband:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    local chipBank = row:CreateTexture(nil, "OVERLAY")
    chipBank:SetSize(WH_MAT_CHIP_SIZE, WH_MAT_CHIP_SIZE)
    chipBank:SetPoint("RIGHT", chipWarband, "LEFT", -WH_MAT_CHIP_GAP, 0)
    local chipBag = row:CreateTexture(nil, "OVERLAY")
    -- ParagonReputation_Bag fills edge-to-edge (bank/warband carry padding);
    -- size it down to match visual weight.
    chipBag:SetSize(WH_MAT_CHIP_SIZE - 3, WH_MAT_CHIP_SIZE - 3)
    chipBag:SetPoint("RIGHT", chipBank, "LEFT", -WH_MAT_CHIP_GAP, 0)
    row._chipWarband = chipWarband
    row._chipBank    = chipBank
    row._chipBag     = chipBag
    local qty = HDG.UI.RowText(row, "caption", "Text", "RIGHT")
    qty:SetPoint("RIGHT", chipBag, "LEFT", -4, 0)
    qty:SetWordWrap(false)
    name:SetPoint("RIGHT", qty, "LEFT", -8, 0)
    row._nameFs = name
    row._qtyFs  = qty
    -- Hover -> "Your stock" per-stash breakdown (shared TooltipRecipes.MaterialStock,
    -- reads stamped _tip* fields live; Attach is pool-safe). Row is a selectable Button.
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.MaterialStock)
end

local function _paintWarehouseMatRow(row, ed)
    row._nameFs:SetText(ed.name or "?")
    row._qtyFs:SetText(tostring(ed.have) .. "/" .. tostring(ed.need))
    -- Location chips: show only when count > 0 (selector coerces have/need/bag/bank/warband).
    local bag     = ed.bag
    local bank    = ed.bank
    local warband = ed.warband
    if bag > 0 then
        row._chipBag:SetAtlas("ParagonReputation_Bag")
        row._chipBag:Show()
    else
        row._chipBag:Hide()
    end
    if bank > 0 then
        row._chipBank:SetAtlas("Banker")
        row._chipBank:Show()
    else
        row._chipBank:Hide()
    end
    if warband > 0 then
        row._chipWarband:SetAtlas("warbands-icon")
        row._chipWarband:Show()
    else
        row._chipWarband:Hide()
    end
    -- Stamp fields the hover tooltip reads (the chips above show presence only).
    -- bag/bank are NOT stamped: the chips read ed.bag/ed.bank directly, and the
    -- tooltip now shows a per-character roster instead of this char's stash split.
    row._tipName    = ed.name
    row._tipItemID  = ed.itemID
    row._tipWarband = warband
    row._tipNeed    = ed.need
end

-- Shift-click links the material -- which lands in the Auction House search bar
-- when the AH is open. A plain click selects it and drives the Used-in-recipes
-- pane, so the AH gesture takes the modifier rather than the other way around.
local function _wireWarehouseMatRow(row, ed)
    row:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            HDG.UI.LinkMaterial(ed.itemID, ed.name)
            return
        end
        HDG.Store:Dispatch({
            type    = A.RECIPES_SELECT_MATERIAL,
            payload = { itemID = ed.itemID },
        })
    end)
end

HDG.Rows:Register("warehouseMatRow", {
    font    = "body",
    height  = 20,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutWarehouseMatRow,
        paint      = _paintWarehouseMatRow,
        laidOutTag = "_whMatLaidOut",
        selectable = true,
        clicks     = "LeftButtonUp",
        wire       = _wireWarehouseMatRow,
        resetText  = { "_nameFs", "_qtyFs" },
        reset      = function(row)
            if row._chipBag     then row._chipBag:Hide()     end
            if row._chipBank    then row._chipBank:Hide()    end
            if row._chipWarband then row._chipWarband:Hide() end
            row._tipName = nil   -- no tooltip on a pooled-but-unpainted row
        end,
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "whm:" .. tostring(ed.itemID or "?")
    end,
})

-- ===== Used In row ===========================================================
-- recipe name (fill) + expansion-short (right); click re-selects the recipe.
local function _layoutUsedInRow(row)
    HDG.UI:EnsureRowChrome(row)
    HDG.UI.LayoutNameMetaRow(row, { nameRole = "caption", nameTheme = "Text", metaRole = "caption", metaTheme = "TextDim", leftInset = 4, rightInset = -4, gap = 8 })
    row._usedInLaidOut = true
end

local function _paintUsedInEmpty(row, ed)
    row._nameFs:SetText(HDG.Theme:ColorCode("text.dim") .. (ed.label or "Click a material") .. "|r")
    row._metaFs:SetText("")
    row:SetScript("OnClick", nil)
end

local function _paintUsedInRow(row, ed)
    row._nameFs:SetText(ed.name or "?")
    row._metaFs:SetText(ed.expansionShort or "")
    row:SetScript("OnClick", function()
        -- Shift-click queues the recipe (1/click). Plain click is intentionally a no-op:
        -- selecting here would clobber the player's recipe-list selection + filters.
        if IsShiftKeyDown() then
            local r = HDG.StaticData.Recipes:Get(ed.recipeID)
            if r then HDG.UI.QueueRecipe(ed.recipeID, r.itemID, ed.name) end
        end
    end)
end

local function _usedInRowFactory(template)
    return {
        Configure = function(row, ed)
            if not row._usedInLaidOut then _layoutUsedInRow(row) end
            HDG.Theme:Register(row, "RowChrome", { selected = false })
            if ed.kind == "usedInEmpty" then
                _paintUsedInEmpty(row, ed)
            else
                _paintUsedInRow(row, ed)
            end
            row:SetHeight(template.height)
        end,
        Reset = function(row)
            row:SetScript("OnClick", nil)
            HDG.UI.ClearRowText(row, "_nameFs", "_metaFs")
        end,
    }
end

HDG.Rows:Register("usedInRow", {
    font    = "body",
    height  = 20,
    factory = _usedInRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        if ed.kind == "usedInEmpty" then return "empty" end
        return "ui:" .. tostring(ed.recipeID or "?")
    end,
})

-- ===== Wire =================================================================

function WarehouseController:Wire(rootFrame)
    local matsList = HDG.UI.W(rootFrame, "warehouseMaterialsPanel.list")

    -- All-materials selection sync. warehouse.allMaterialsRows drops the
    -- selection read so clicks don't rebuild the list.
    if matsList.WireStoreSelectionSync then  -- exception(optional): WireStoreSelectionSync is an optional protocol; not all list widgets implement it
        matsList:WireStoreSelectionSync("session.ui.warehouse.selectedMaterialID",
            function(ed, id) return id ~= nil and ed.itemID == id end)
    end

    -- Auto-show-on-harvest toggle (title bar). Same flag the LumberObserver reads.
    HDG.UI.OnClick(rootFrame, "warehouseLumberPanel.autoShowToggle", function()
        HDG.Store:Dispatch({ type = A.LUMBER_AUTOSHOW_TOGGLE })
    end)

    -- Materials search: filters the All Materials scrollbox.
    HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, "warehouseMaterialsPanel.search"), function(text)
        HDG.Store:Dispatch({ type = A.RECIPES_SET_WH_MAT_SEARCH, payload = { query = text } })
    end)
end

function WarehouseController:Refresh(rootFrame, ctx)
    -- Bindings handle paint; nothing imperative.
end

HDG.Controllers:Register("warehouse", WarehouseController)
