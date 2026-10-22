-- HDGR_LayoutConfig_Trainers.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Trainers tab: search header + flat scrollbox (trainers.allRows).
-- Row factory dispatches on ed.kind (profHeader / expSection / trainerRow / midnightRow).

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.trainers = {
    controllers = { "trainers" },
    width    = "auto",       -- 4 + 760 + 4 = 768
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 760 },
    rows     = { 600 },      -- chrome/status rows removed (HDG-ADR-025 slots)
    cells    = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.trainersPanel = {
    kind = "panel",
    cell = { trainers = "body" },
    visibleInViews = { "trainers" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}
-- Note: widgets were mis-keyed inside `panels` originally and silently dropped.

-- ===== Widgets ===============================================================

-- Title left + fill spacer + search right. Header slot height (34) unchanged.
LC.widgets["trainersPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "trainersPanel", slot = "header",
    text = "locale:TRN_TITLE", font = "heading",
    height = 18, width = "auto", order = 5,
}
LC.widgets["trainersPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "trainersPanel", slot = "header",
    width = "fill", height = 14, order = 8,
}
LC.widgets["trainersPanel.searchBox"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "trainersPanel", slot = "header",
    binding = "trainers.searchQuery",
    font = "body",
    width = 220, height = 22, order = 10,
    placeholder = "locale:TRN_SEARCH_PLACEHOLDER",
}
LC.widgets["trainersPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "trainersPanel",
    binding = "trainers.allRows",
    rowKind   = "trainersRow",
    spacing   = 1,
    selection = { deselectable = true },
    order = 10,
}
