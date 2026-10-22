-- HDGR_LayoutConfig_Shopping.lua
-- Standalone floating window (HDG.Window) for the Shopping List (HDG-ADR-025 step 5).
--
-- View: shoppingList
--   columns: { 480 }
--   rows:    { 28 (header), 650 (body) }
--   cells:   header / body
--
-- Panels:
--   shoppingHeaderPanel  -- floating-window chrome: title + close button
--   shoppingPanel        -- content: list switcher + entries + action bar
--
-- Sections (shopping.*):
--   shopping.body              vertical container (everything below header)
--   shopping.attribution       horizontal banner row (visible: shopping.hasAttribution)
--   shopping.entries           scrollbox container (height = fill)
--   shopping.actionBar         horizontal action row

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.shoppingList = {
    controllers = { "shopping" },
    standalone  = true,        -- HDG.Window floating frame; not in main window
    width       = "auto",      -- 4 + 480 + 4 = 488
    height      = "auto",      -- 4 + 28 + 4 + 650 + 4 = 690
    columns     = { 480 },
    rows        = { 28, 650 },
    cells       = {
        header = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        body   = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.shoppingHeaderPanel = {
    kind = "panel",
    cell = { shoppingList = "header" },
    visibleInViews = { "shoppingList" },
    slots = {
        header = {
            height = 28, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}

-- Content panel: list switcher + body sections.
LC.panels.shoppingPanel = {
    kind = "panel",
    cell = { shoppingList = "body" },
    visibleInViews = { "shoppingList" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================

LC.sections["shopping.body"] = {
    ["in"]  = "shoppingPanel",
    layout  = "vertical",
    padding = "lg",
    gap     = "sm",
    order   = 10,
}

-- Attribution banner: visible when list has meta.source or meta.attribution (external sources).
LC.sections["shopping.attribution"] = {
    ["in"]   = "shopping.body",
    layout   = "horizontal",
    height   = 28,
    gap      = "sm",
    order    = 10,
    chrome   = "card",
    -- Left inset clears the card chrome's accent stripe so "Imported from ..."
    -- doesn't clash with it (right "sm" keeps the Open button off the edge).
    padding  = { top = 0, right = "sm", bottom = 0, left = "md" },
    visible  = "shopping.hasAttribution",
}

LC.sections["shopping.entries"] = {
    ["in"]   = "shopping.body",
    layout   = "fill",
    height   = "fill",
    order    = 20,
    chrome   = "inset",
}

-- Item/vendor counts under the list. Same shape as decor/pets/menagerie, which
-- all carry their count in a 16px rail below the content it describes -- this
-- was the one list view keeping its summary up in the header, where it competed
-- for width with the list controls and truncated to "5 ve...".
--
-- Above the action bar, not below it: the number describes the LIST, so it
-- belongs against the list rather than adrift under a row of buttons.
LC.sections["shopping.statusRail"] = {
    ["in"]   = "shopping.body",
    layout   = "horizontal",
    height   = 16,
    order    = 25,
}

LC.sections["shopping.actionBar"] = {
    ["in"]   = "shopping.body",
    layout   = "horizontal",
    height   = 24,
    gap      = "md",
    order    = 30,
}

-- ===== Widgets -- window chrome header =======================================
-- Icon mirrors NAV_TREE's "Shopping" launcher glyph.
LC.widgets["shoppingHeaderPanel.icon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "shoppingHeaderPanel", slot = "header",
    atlas = HDG.Constants.SHOPPING_LIST_ICON_ATLAS,
    width = 16, height = 16, order = 5,
}
LC.widgets["shoppingHeaderPanel.title"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "shoppingHeaderPanel", slot = "header",
    text = "locale:SHOP_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["shoppingHeaderPanel.spacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "shoppingHeaderPanel", slot = "header",
    width = "fill", height = 18, order = 15,
}
-- Mouse-action hints: right of the slack spacer, just left of [X].
LC.widgets["shoppingHeaderPanel.clickHints"] = {
    tooltip = false,   -- self-owned tooltip, composed from leftText/shiftText/rightText
    kind = "clickHints", ["in"] = "shoppingHeaderPanel", slot = "header",
    leftText  = "locale:SHOP_HINT_LEFT",
    shiftText = "locale:SHOP_HINT_SHIFT",
    rightText = "locale:SHOP_HINT_RIGHT",
    width = 34, height = 16, order = 90,
}
LC.widgets["shoppingHeaderPanel.close"] = {
    tooltip = { recipe = "Close" },
    kind = "button", ["in"] = "shoppingHeaderPanel", slot = "header",
    width = 22, height = 22, order = 95,
    close = true,
    size = 22,
    iconSize = 14,
}

-- ===== Widgets -- content panel header slot ==================================

-- (No panel title: the window titlebar already reads "Shopping List", so a
--  second "Shopping" heading in the content header was redundant.)
-- (The item/vendor summary moved to shopping.statusRail below the list.)

-- Slack absorber. The summary used to be width="fill" and did this job; with it
-- gone the header needs an explicit spacer, or the toggle, + New and the list
-- dropdown all pack against the left edge.
LC.widgets["shoppingPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "shoppingPanel", slot = "header",
    width = "fill", height = 14, order = 16,
}
-- Neighborhood preference: which of the two housing neighborhoods to be sent to
-- when both sell the same decor. Sits with the list controls rather than in the
-- action bar below -- that row is all one-shot verbs (Buy All, Clear, Delete),
-- and a standing preference among them invites a mis-click.
LC.widgets["shoppingPanel.neighborhoodToggle"] = {
    tooltip = { recipe = "ShopNeighborhood" },
    kind = "factionToggle", ["in"] = "shoppingPanel", slot = "header",
    -- height 16 = round7.png's native height (margin 7 + 2px centre + margin 7),
    -- so the capsule is drawn rather than stretched. See FACTION_CAPSULE_HEIGHT.
    width = 26, height = 16, order = 12,
    binding = { current = "shopping.neighborhood" },
}
-- Names the side the colour is showing (see shopping.neighborhoodLabel).
LC.widgets["shoppingPanel.neighborhoodLabel"] = {
    tooltip = { recipe = "ShopNeighborhood" },
    kind = "label", role = "Text", ["in"] = "shoppingPanel", slot = "header",
    text = "", font = "small", justifyH = "LEFT",
    width = 52, height = 14, order = 14,
    binding = "shopping.neighborhoodLabel",
}

-- List switcher dropdown. Dispatches SHOPPING_LIST_ACTIVATE { id = value }.
LC.widgets["shoppingPanel.listSwitcher"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "shoppingPanel", slot = "header",
    -- height=25: WowStyle2DropdownTemplate native height; shrinking misaligns the Background atlas.
    width = 180, height = 25, order = 20, minWidth = 140,
    placeholder = "locale:SHOP_NO_LIST",
    binding  = { menu = "shopping.activeListMenuItems",
                 current = "shopping.activeListId" },
    dispatch = { type = "SHOPPING_LIST_ACTIVATE", payloadKey = "id" },
}

-- ===== Widgets -- attribution banner =========================================

LC.widgets["shoppingPanel.attributionText"] = {
    tooltip = false,
    kind = "label", role = "TextStatus", ["in"] = "shopping.attribution",
    font = "small", text = "", width = "fill", height = 14, order = 10,
    binding = "shopping.attributionText",
}
LC.widgets["shoppingPanel.attributionOpenBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shopping.attribution",
    font = "small", text = "locale:SHOP_OPEN_BTN", width = "auto", height = 20,
    order = 20, variant = "tertiary",
    visible = "shopping.hasUrl",
}

-- ===== Widgets -- status rail ================================================

-- "50 items - 5 vendors". TextInfo tone + a 16px rail, matching decorPanel.count.
LC.widgets["shoppingPanel.summary"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "shopping.statusRail",
    text = "", font = "small", justifyH = "LEFT",
    width = "fill", height = 14, order = 10,
    binding = "shopping.summaryText",
}

-- ===== Widgets -- entries scrollbox ==========================================

LC.widgets["shoppingPanel.entries"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "shopping.entries",
    binding = "shopping.entriesByZone",
    -- Heterogeneous row factory (wishHeader/wishItem/zone/vendor/item).
    rowKind   = "shoppingRow",
    spacing   = 1,
    order     = 10,
}

-- ===== Widgets -- action bar =================================================

-- Buy All: leftmost, primary. Enabled only at a vendor stocking the list; label
-- flips to "Cancel (n/m)" while a buy runs. Both via bindings (Task 3/5 selectors).
LC.widgets["shoppingPanel.buyAllBtn"] = {
    tooltip = { recipe = "BuyAll" },
    kind = "button", ["in"] = "shopping.actionBar",
    font = "body", text = "locale:SHOP_BUY_ALL", width = "auto", height = 22,
    order = 5, variant = "primary",
    binding = { text = "merchant.buyAllLabel", enabled = "merchant.buyAllEnabled" },
}
LC.widgets["shoppingPanel.waypointAllBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shopping.actionBar",
    font = "body", text = "locale:SHOP_WAYPOINT_ALL", width = "auto", height = 22,
    order = 10, variant = "tertiary",
}
LC.widgets["shoppingPanel.clearBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shopping.actionBar",
    font = "body", text = "locale:COMMON_CLEAR", width = "auto", height = 22,
    order = 20, variant = "tertiary",
}
LC.widgets["shoppingPanel.exportBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shopping.actionBar",
    font = "body", text = "locale:COMMON_EXPORT", width = "auto", height = 22,
    order = 30, variant = "tertiary",
}
LC.widgets["shoppingPanel.importBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shopping.actionBar",
    font = "body", text = "locale:COMMON_IMPORT", width = "auto", height = 22,
    order = 40, variant = "tertiary",
}
LC.widgets["shoppingPanel.actionBarSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "shopping.actionBar",
    width = "fill", height = 22, order = 45,
}
-- Delete the active list. Hidden when only one list exists (can't delete your
-- only list -> deleting always leaves >=1, so activeShoppingListId is never "").
LC.widgets["shoppingPanel.deleteListBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shopping.actionBar",
    font = "body", text = "locale:COMMON_DELETE", width = "auto", height = 22,
    order = 48, variant = "tertiary",
    visible = "shopping.hasMultipleLists",
}
-- + New / Rename: the list-management pair, in the header row beside the list
-- they act on, NOT the action bar (which would overflow). headerSpacer is the
-- width="fill" slack absorber, so both buttons and the dropdown (order 20) are
-- pushed right together.
--
-- Delete stays down in the action bar deliberately: it is the destructive one,
-- and it is hidden entirely at one list, so pairing it with these two would put
-- a sometimes-there button between two always-there ones.
LC.widgets["shoppingPanel.newListBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shoppingPanel", slot = "header",
    font = "body", text = "locale:SHOP_NEW_LIST", width = "auto", height = 22,
    order = 18, variant = "tertiary",
}
LC.widgets["shoppingPanel.renameListBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "shoppingPanel", slot = "header",
    font = "body", text = "locale:SHOP_RENAME_LIST", width = "auto", height = 22,
    order = 19, variant = "tertiary",
}

-- ===== Satellite window (HDG-ADR-025 step 5) ===============================
-- shown = shopping.windowVisible (SHOPPING_WIDGET_TOGGLE). No position persistence.
LC.windows.shoppingWindow = {
    slots    = { fill = "shoppingList" },
    shown    = "shopping.windowVisible",
    position = { default = { x = 250, y = -180 }, movable = true },
}
