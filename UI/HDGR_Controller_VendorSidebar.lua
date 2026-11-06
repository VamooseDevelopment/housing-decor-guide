-- HDG.VendorSidebarController
-- ============================================================================
-- The vendor sidebar beside Blizzard's merchant window (layout:
-- UI/LayoutConfig/HDGR_LayoutConfig_VendorSidebar.lua; selectors: the merchant.sidebar*
-- block of UI/HDGR_Selectors_Shopping.lua).
--
-- Rows:
--   vendorSidebarListRow  accent edge | list name | "N here" pill. Click makes the
--                         list active (SHOPPING_LIST_ACTIVATE), as the Shopping
--                         List's switcher does.
--   vendorSidebarItemRow  icon | name over "Want N x <unit cost>" | line cost. Click
--                         opens the quantity picker; a locked item has no click.
-- Wire: the X (hide for this visit) and Buy All (shared with the Shopping List).

HDG = HDG or {}
HDG.VendorSidebarController = HDG.VendorSidebarController or {}
local VendorSidebarController = HDG.VendorSidebarController

local LIST_EDGE_W   = 3    -- the accent edge on a list with items here
local PILL_PAD_X    = 6    -- pill background past its text, each side
local PILL_H        = 16
local ITEM_ICON     = 28
local ITEM_COST_W   = 84   -- right column: up to three payments, one per line

-- ===== List row ==============================================================

local function _layoutListRow(row)
    local edge = row:CreateTexture(nil, "ARTWORK", nil, 2)
    edge:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    edge:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    edge:SetWidth(LIST_EDGE_W)
    HDG.Theme:Register(edge, "AccentBar")
    row._edge = edge

    local pill = HDG.UI.RowText(row, "small", "TextStatus", "RIGHT")
    pill:SetPoint("RIGHT", row, "RIGHT", -(PILL_PAD_X + 4), 0)
    row._pillFs = pill
    local pillBg = row:CreateTexture(nil, "ARTWORK", nil, 1)
    pillBg:SetHeight(PILL_H)
    pillBg:SetPoint("LEFT", pill, "LEFT", -PILL_PAD_X, 0)
    pillBg:SetPoint("RIGHT", pill, "RIGHT", PILL_PAD_X, 0)
    HDG.Theme:Register(pillBg, "AccentBg")
    row._pillBg = pillBg

    local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", LIST_EDGE_W + 6, 0)
    name:SetPoint("RIGHT", pill, "LEFT", -(PILL_PAD_X + 6), 0)
    name:SetWordWrap(false)
    row._nameFs = name

    HDG.TooltipEngine:Attach(row, function(self)
        return { title = self._ed.name, body = HDG.Locale:Get("VSIDE_LIST_CLICK") }
    end)
end

local function _paintListRow(row, ed)
    row._ed = ed
    local here = ed.here > 0
    row._edge:SetShown(here)
    row._pillBg:SetShown(here)
    row._pillFs:SetText(here and HDG.Locale:Get("VSIDE_HERE"):format(ed.here) or "")
    -- The active list reads in the heading face; its row is also the selected one.
    HDG.UI.applyFontRole(row._nameFs, ed.active and "body_strong" or "body")
    HDG.Theme:Register(row._nameFs, here and "TextHeading" or "Text")
    row._nameFs:SetText(ed.name)
end

local function _wireListRow(row, ed)
    local id = ed.id
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_LIST_ACTIVATE, payload = { id = id } })
    end)
end

local function _resetListRow(row)
    row._edge:Hide()
    row._pillBg:Hide()
end

HDG.Rows:Register("vendorSidebarListRow", {
    font    = "body",
    height  = 24,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutListRow,
        paint      = _paintListRow,
        wire       = _wireListRow,
        laidOutTag = "_vendorSidebarListLaidOut",
        selectedFn = function(ed) return ed.active end,
        clicks     = "LeftButtonUp",
        resetText  = { "_nameFs", "_pillFs" },
        reset      = _resetListRow,
    }),
    key     = function(ed) return "vsl:" .. ed.id end,
})

-- ===== Item row ==============================================================

local function _layoutItemRow(row)
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)
    icon:SetSize(ITEM_ICON, ITEM_ICON)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    icon:SetTexCoord(unpack(HDG.Constants.ICON_CROP))
    row._iconTex = icon

    local cost = HDG.UI.RowText(row, "small", "Text", "RIGHT")
    cost:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    cost:SetWidth(ITEM_COST_W)
    row._costFs = cost

    local name = HDG.UI.RowText(row, "body", "TextHeading", "LEFT")
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -1)
    name:SetPoint("RIGHT", cost, "LEFT", -6, 0)
    name:SetWordWrap(false)
    row._nameFs = name

    local sub = HDG.UI.RowText(row, "small", "Text", "LEFT")
    sub:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 1)
    sub:SetPoint("RIGHT", cost, "LEFT", -6, 0)
    sub:SetWordWrap(false)
    row._subFs = sub

    -- The item's own tooltip, then what a click does here.
    HDG.TooltipEngine:Attach(row, function(self)
        local ed = self._ed
        return { itemID = ed.itemID,
                 body = HDG.Locale:Get(ed.buyable and "VSIDE_ITEM_CLICK" or "VSIDE_ITEM_LOCKED_TIP") }
    end)
end

local function _paintItemRow(row, ed)
    row._ed = ed
    row._iconTex:SetTexture(ed.icon)
    row._nameFs:SetText(ed.name)
    -- A locked item's "Can't buy yet" reads in the warning colour; a buyable one's
    -- costs carry their own colours.
    HDG.Theme:Register(row._subFs, ed.buyable and "Text" or "TextWarning")
    row._subFs:SetText(ed.sub)
    row._costFs:SetText(ed.cost)
end

local function _wireItemRow(row, ed)
    if not ed.buyable then return end   -- the vendor won't sell it: nothing to pick
    local itemID = ed.itemID
    row:SetScript("OnClick", function() HDG.QuantityPicker:Open(itemID) end)
end

local function _resetItemRow(row)
    row._iconTex:SetTexture(nil)
end

HDG.Rows:Register("vendorSidebarItemRow", {
    font    = "body",
    height  = 38,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutItemRow,
        paint      = _paintItemRow,
        wire       = _wireItemRow,
        laidOutTag = "_vendorSidebarItemLaidOut",
        clicks     = "LeftButtonUp",
        resetText  = { "_nameFs", "_subFs", "_costFs" },
        reset      = _resetItemRow,
    }),
    -- An item can sit on a list twice, under two vendors: npcID keeps them apart.
    key     = function(ed) return "vsi:" .. ed.itemID .. ":" .. tostring(ed.npcID) end,
})

-- ===== Controller lifecycle ==================================================

function VendorSidebarController:Wire(rootFrame)
    -- The window registry enables the mouse only on movable windows; without it a
    -- click on the sidebar's gaps falls through to the world behind it.
    rootFrame:EnableMouse(true)

    HDG.UI.OnClick(rootFrame, "vendorSidebarHeaderPanel.settings", function()
        HDG.SettingsPanel.OpenToSection("vendors")
    end)
    HDG.UI.OnClick(rootFrame, "vendorSidebarHeaderPanel.close", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MERCHANT_SIDEBAR_DISMISS })
    end)
    HDG.UI.OnClick(rootFrame, "vendorSidebarPanel.buyAllBtn", HDG.ControllerHelpers.Mechanics.BuyAllOrStop)
end

function VendorSidebarController:Refresh(_rootFrame, _ctx)
    -- Bindings and the row factories paint everything.
end

HDG.Controllers:Register("vendorSidebar", VendorSidebarController)
