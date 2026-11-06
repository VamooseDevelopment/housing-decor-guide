-- HDGR_LayoutConfig_VendorSidebar.lua
-- The vendor sidebar: a satellite window (HDG.Window) beside Blizzard's merchant
-- window, the height of it, shown when the vendor sells something on any
-- shopping list (merchant.sidebarShown). Mockup docs/mockups/vendor_sidebar.html.
--
-- View: vendorSidebar
--   columns: { 292 }       4 + 292 + 4 = 300 wide
--   rows:    { 28, 404 }   4 + 28 + 4 + 404 + 4 = 444, MerchantFrame's height
--   cells:   header / body
--
-- Body, top to bottom: every list (scrolls on its own), "<list> at this vendor",
-- the active list's items here (or the empty note), and the footer -- what the
-- run spends of each payment, or its progress while it buys, over Buy All.
-- Rows + Wire: HDGR_Controller_VendorSidebar.lua; selectors: HDGR_Selectors_Shopping.lua.

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.vendorSidebar = {
    controllers = { "vendorSidebar" },
    standalone  = true,
    width       = "auto",
    height      = "auto",
    columns     = { 292 },
    rows        = { 28, 404 },
    cells       = {
        header = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        body   = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

LC.panels.vendorSidebarHeaderPanel = {
    kind = "panel",
    cell = { vendorSidebar = "header" },
    visibleInViews = { "vendorSidebar" },
    slots = {
        header = {
            height = 28, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}

LC.panels.vendorSidebarPanel = {
    kind = "panel",
    cell = { vendorSidebar = "body" },
    visibleInViews = { "vendorSidebar" },
}

-- ===== Sections ==============================================================

LC.sections["vendorSidebar.body"] = {
    ["in"]  = "vendorSidebarPanel",
    layout  = "vertical",
    padding = "sm",
    gap     = "xs",
    order   = 10,
}

-- Four list rows and a sliver of the fifth, so a longer list reads as scrolling.
LC.sections["vendorSidebar.lists"] = {
    ["in"]  = "vendorSidebar.body",
    layout  = "fill",
    height  = 100,
    order   = 10,
    chrome  = "inset",
}

LC.sections["vendorSidebar.headingRow"] = {
    ["in"]  = "vendorSidebar.body",
    layout  = "horizontal",
    height  = 18,
    padding = { top = 0, right = "xs", bottom = 0, left = "xs" },
    order   = 20,
}

-- The items and the empty note share the slack; only one shows.
LC.sections["vendorSidebar.items"] = {
    ["in"]   = "vendorSidebar.body",
    layout   = "fill",
    height   = "fill",
    order    = 30,
    chrome   = "inset",
    visible  = "merchant.sidebarHasItems",
}

LC.sections["vendorSidebar.empty"] = {
    ["in"]   = "vendorSidebar.body",
    layout   = "fill",
    height   = "fill",
    padding  = "md",
    order    = 31,
    chrome   = "inset",
    visible  = "merchant.sidebarEmpty",
}

-- Room for every footer widget at once (the over-spec check lays them all out):
-- 4 + four wallet lines 56 + progress 14 + bar 8 + Buy All 22 + 5 gaps of 2
-- (the busy dots and the spacer are the two fill children) = 114.
LC.sections["vendorSidebar.footer"] = {
    ["in"]   = "vendorSidebar.body",
    layout   = "vertical",
    height   = 114,
    gap      = "xs",
    padding  = { top = "sm", right = "xs", bottom = 0, left = "xs" },
    order    = 40,
}

-- ===== Widgets -- header =====================================================

LC.widgets["vendorSidebarHeaderPanel.icon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "vendorSidebarHeaderPanel", slot = "header",
    atlas = HDG.Constants.SHOPPING_LIST_ICON_ATLAS,
    width = 16, height = 16, order = 5,
}
LC.widgets["vendorSidebarHeaderPanel.title"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "vendorSidebarHeaderPanel", slot = "header",
    text = "locale:VSIDE_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["vendorSidebarHeaderPanel.spacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "vendorSidebarHeaderPanel", slot = "header",
    width = "fill", height = 18, order = 15,
}
-- Opens HDG's Helpers settings at its Vendors section: the sidebar's own switch,
-- the vendor marks and the quantity picker (owner 2026-11-02). Blizzard's
-- raid-frame cog, whose hover art is the same name with "-hover".
LC.widgets["vendorSidebarHeaderPanel.settings"] = {
    tooltip = { recipe = "VendorSidebarSettings" },
    kind = "button", ["in"] = "vendorSidebarHeaderPanel", slot = "header",
    normalAtlas = "GM-icon-settings", highlightAtlas = "GM-icon-settings-hover",
    width = 22, height = 22, size = 22, order = 90,   -- the X's size (18 read small in game)
}
-- Hides the sidebar for this visit (MERCHANT_SIDEBAR_DISMISS); the next vendor
-- opening brings it back. The setting turns it off for good.
LC.widgets["vendorSidebarHeaderPanel.close"] = {
    tooltip = { recipe = "VendorSidebarClose" },
    kind = "button", ["in"] = "vendorSidebarHeaderPanel", slot = "header",
    width = 22, height = 22, order = 95,
    close = true,
    size = 22,
    iconSize = 14,
}

-- ===== Widgets -- lists, heading, items ======================================

LC.widgets["vendorSidebarPanel.lists"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "vendorSidebar.lists",
    binding = "merchant.sidebarLists",
    rowKind = "vendorSidebarListRow",
    spacing = 0,
    order   = 10,
}

LC.widgets["vendorSidebarPanel.heading"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "vendorSidebar.headingRow",
    text = "", font = "body", justifyH = "LEFT",
    width = "fill", height = 16, order = 10,
    binding = "merchant.sidebarHeading",
}

LC.widgets["vendorSidebarPanel.items"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "vendorSidebar.items",
    binding = "merchant.sidebarItems",
    rowKind = "vendorSidebarItemRow",
    spacing = 1,
    order   = 10,
}

LC.widgets["vendorSidebarPanel.empty"] = {
    tooltip = false,
    kind = "label", role = "Text", ["in"] = "vendorSidebar.empty",
    text = "", font = "body", justifyH = "LEFT", justifyV = "TOP", wrap = true,
    width = "fill", height = "fill", order = 10,
    binding = "merchant.sidebarEmptyText",
}

-- ===== Widgets -- footer =====================================================

-- Idle: one line per payment the run spends, against what you hold. Four lines:
-- gold and three other payments, more than a decor vendor charges in one run.
LC.widgets["vendorSidebarPanel.wallet"] = {
    tooltip = false,
    kind = "label", role = "Text", ["in"] = "vendorSidebar.footer",
    text = "", font = "small", justifyH = "LEFT", justifyV = "TOP", wrap = true,
    width = "fill", height = 56, order = 10,
    binding = "merchant.sidebarWalletText",
    visible = "merchant.notBuying",
}
-- Buying: "Bought 4 of 18" over a bar.
LC.widgets["vendorSidebarPanel.progressText"] = {
    tooltip = false,
    kind = "label", role = "Text", ["in"] = "vendorSidebar.footer",
    text = "", font = "small", justifyH = "LEFT",
    width = "fill", height = 14, order = 20,
    binding = "merchant.sidebarProgressText",
    visible = "merchant.isBuying",
}
LC.widgets["vendorSidebarPanel.progressBar"] = {
    tooltip = false,
    kind = "progressbar", ["in"] = "vendorSidebar.footer",
    width = "fill", height = 8, order = 30,
    binding = { progress = "merchant.sidebarProgress" },
    visible = "merchant.isBuying",
}
-- While buying, the room the wallet lines leave: the busy dots, centred in it
-- (owner 2026-11-02, Aegis's calendar-refresh dots).
LC.widgets["vendorSidebarPanel.busyDots"] = {
    tooltip = false,
    kind = "busydots", ["in"] = "vendorSidebar.footer",
    width = "fill", height = "fill", order = 35,
    visible = "merchant.isBuying",
}
-- Otherwise it holds Buy All to the bottom under the wallet lines.
LC.widgets["vendorSidebarPanel.footerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "vendorSidebar.footer",
    width = "fill", height = "fill", order = 40,
    visible = "merchant.notBuying",
}
LC.widgets["vendorSidebarPanel.buyAllBtn"] = {
    tooltip = { recipe = "BuyAll" },
    kind = "button", ["in"] = "vendorSidebar.footer",
    font = "body", text = "locale:SHOP_BUY_ALL", width = "fill", height = 22,
    order = 50, variant = "primary",
    binding = { text = "merchant.sidebarBuyLabel", enabled = "merchant.buyAllEnabled" },
}

-- ===== Satellite window ======================================================
-- Parented to MerchantFrame: it hides with the vendor window and moves with it,
-- and sits against its right edge (anchored to its TOPRIGHT, so a vendor window
-- another addon widens still has the sidebar beside it, not over it), top
-- aligned. Not movable -- it belongs to the vendor window. lazy = "shown": the
-- registry builds it the first time merchant.sidebarShown is true -- including
-- mid-visit, when an item goes on a list or the setting is turned on at the
-- vendor -- so a session that never opens a vendor never builds it.
LC.windows.vendorSidebar = {
    lazy     = "shown",
    parent   = function() return _G.MerchantFrame end,
    slots    = { fill = "vendorSidebar" },
    shown    = "merchant.sidebarShown",
    position = {
        default = { relPoint = "TOPRIGHT", x = HDG.Constants.VENDOR_SIDEBAR_GAP, y = 0 },
        movable = false,
    },
}
