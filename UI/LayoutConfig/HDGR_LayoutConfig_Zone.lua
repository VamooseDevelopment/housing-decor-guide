-- HDGR_LayoutConfig_Zone.lua
-- Zone Scanner standalone floating window (HDG.Window, HDG-ADR-025 step 5).
--
-- View: zoneScanner
--   columns: { 320 }
--   rows:    { 28 (header), 500 (body) }
--   cells:   header / body
--
-- Panels:
--   zoneHeaderPanel   -- floating-window chrome: title + close button
--   zonePanel         -- content: filter bar + entries + action bar
--
-- Sections (zone.*):
--   zone.body             vertical container
--   zone.filterBar        search + showCollected toggle row
--   zone.entries          scrollbox container (height = fill)
--   zone.actionBar        bottom action row (Map All + shopping-list cart tick)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View =================================================================

LC.window.views.zoneScanner = {
    controllers = { "zoneScanner" },
    standalone  = true,
    width       = "auto",
    height      = "auto",
    columns     = { 320 },
    rows        = { 28, 500 },           -- static fallback; dynamicRows hugs the list
    dynamicRows = "zone.windowRows",     -- body row auto-sizes to the vendor list (HDG parity)
    cells       = {
        header = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        body   = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ===============================================================
-- Header: HDG icon (opens the main window) + "Zone Scanner: <zone>" title + close.
LC.panels.zoneHeaderPanel = {
    kind = "panel",
    cell = { zoneScanner = "header" },
    visibleInViews = { "zoneScanner" },
    slots = {
        header = {
            height = 28, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}

-- Content panel: filter bar + entries + action bar.
LC.panels.zonePanel = {
    kind = "panel",
    cell = { zoneScanner = "body" },
    visibleInViews = { "zoneScanner" },
}

-- ===== Sections =============================================================

LC.sections["zone.body"] = {
    ["in"]  = "zonePanel",
    layout  = "vertical",
    padding = "lg",
    gap     = "sm",
    order   = 10,
}

LC.sections["zone.filterBar"] = {
    ["in"]   = "zone.body",
    layout   = "horizontal",
    height   = 26,
    gap      = "md",
    order    = 10,
}

LC.sections["zone.entries"] = {
    ["in"]   = "zone.body",
    layout   = "fill",
    height   = "fill",
    order    = 20,
    chrome   = "inset",
}

LC.sections["zone.actionBar"] = {
    ["in"]   = "zone.body",
    layout   = "horizontal",
    height   = 24,
    gap      = "md",
    order    = 30,
}

-- ===== Widgets -- window chrome header =======================================
-- The HDG icon is the way back to the main window from the floating scanner.
LC.widgets["zoneHeaderPanel.icon"] = {
    tooltip = { recipe = "ZoneOpenMain" },
    kind = "button", ["in"] = "zoneHeaderPanel", slot = "header",
    normalTexture = "Interface/AddOns/HousingDecorGuide/textures/Vamoose_HDG_400_trans",
    size = 20, width = 20, height = 20, order = 5,
}
-- Fills the row and never wraps: a long zone name is cut with "..." before the
-- close button.
LC.widgets["zoneHeaderPanel.title"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "zoneHeaderPanel", slot = "header",
    font = "heading", wrap = false,
    height = 18, width = "fill", order = 10,
    binding = "zone.title",
}
LC.widgets["zoneHeaderPanel.close"] = {
    tooltip = { recipe = "Close" },
    kind = "button", ["in"] = "zoneHeaderPanel", slot = "header",
    width = 22, height = 22, order = 95,
    close = true,
    size = 22,
    iconSize = 14,
}

-- ===== Widgets -- filter bar ================================================

LC.widgets["zonePanel.searchBox"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "zone.filterBar",
    font = "body", width = "fill", height = 22, order = 10,
    placeholder = "locale:ZONE_SEARCH_PLACEHOLDER",
    binding = { text = "zone.search" },
}

LC.widgets["zonePanel.showCollectedBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "zone.filterBar",
    font = "small", text = "locale:ZONE_SHOW_COLLECTED", width = "auto", height = 22,
    order = 20, variant = "tertiary",
    binding = { active = "zone.showCollected" },
}

-- ===== Widgets -- entries scrollbox =========================================

LC.widgets["zonePanel.entries"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "zone.entries",
    binding = "zone.entriesByVendor",
    -- Heterogeneous row factory (vendor / item); see HDGR_Controller_Zone.
    rowKind   = "zoneRow",
    spacing   = 1,
    order     = 10,
}

-- ===== Widgets -- action bar =================================================

LC.widgets["zonePanel.mapAllBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "zone.actionBar",
    font = "body", text = "locale:ZONE_MAP_ALL", width = "auto", height = 22,
    order = 10, variant = "tertiary",
}
LC.widgets["zonePanel.actionSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "zone.actionBar",
    width = "fill", height = 22, order = 20,
}
-- Cart tick: off = the scanner stops matching the shopping list (list + alerts).
LC.widgets["zonePanel.trackShoppingToggle"] = {
    tooltip = { recipe = "ZoneTrackShopping" },
    kind = "checkbox", ["in"] = "zone.actionBar", font = "small",
    text = "|A:" .. HDG.Constants.SHOPPING_LIST_ICON_ATLAS .. ":16:16|a",
    width = 48, height = 22, order = 30,
    binding = { checked = "zone.trackShopping" },
}

-- ===== Satellite window (HDG-ADR-025 step 5) ===============================
-- shown = zone.popupShown (ZONE_POPUP_TOGGLE). No position persistence.
LC.windows.zoneWindow = {
    slots    = { fill = "zoneScanner" },
    shown    = "zone.popupShown",
    position = { default = { x = 200, y = -160 }, movable = true },
}
