-- HDGR_LayoutConfig_Data.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- "Your Data" tab: 4 KPI statCards + fill scrollbox (data.allRows).
-- KPIs: achievements earned, items acquired, farming sessions, lumber gathered.
--
-- Heterogeneous row kinds: sectionHeader / achieveHeader / achieveRow /
-- lumberAchieveRow / craftHistRow / farmHistRow / emptyRow

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.data = {
    controllers = { "data" },
    width    = "auto",       -- 4 + 760 + 4 = 768
    height   = "auto",       -- chrome + status from window slots (ADR-025)
    columns  = { 760 },
    rows     = { 600 },
    cells    = {
        body = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

LC.panels.dataPanel = {
    kind = "panel",
    cell = { data = "body" },
    visibleInViews = { "data" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================

LC.sections["data.body"] = {
    ["in"]  = "dataPanel",
    layout  = "vertical",
    padding = "md",
    gap     = "sm",
    order   = 10,
}

LC.sections["data.kpiStrip"] = {
    ["in"]  = "data.body",
    layout  = "horizontal",
    height  = 48,
    gap     = "sm",
    order   = 10,
}

LC.sections["data.list"] = {
    ["in"]   = "data.body",
    layout   = "fill",
    height   = "fill",
    order    = 20,
    chrome   = "inset",
}

-- ===== Widgets ===============================================================

LC.widgets["dataPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "dataPanel", slot = "header",
    text = "locale:DATA_PANEL_TITLE", font = "heading",
    height = 18, width = "auto", order = 5,
}

-- ===== Dashboard KPI tiles ===================================================

LC.widgets["dataPanel.kpiAchievements"] = {
    tooltip = false,
    kind = "statCard", ["in"] = "data.kpiStrip",
    label = "locale:DATA_KPI_ACHIEVEMENTS", value = "--",
    width = "fill", height = 48, order = 10,
    binding = { value = "data.kpiAchievements" },
}
LC.widgets["dataPanel.kpiAcquired"] = {
    tooltip = false,
    kind = "statCard", ["in"] = "data.kpiStrip",
    label = "locale:DATA_KPI_ACQUIRED", value = "--",
    width = "fill", height = 48, order = 20,
    binding = { value = "data.kpiAcquired" },
}
LC.widgets["dataPanel.kpiFarmSessions"] = {
    tooltip = false,
    kind = "statCard", ["in"] = "data.kpiStrip",
    label = "locale:DATA_KPI_FARM_SESSIONS", value = "--",
    width = "fill", height = 48, order = 30,
    binding = { value = "data.kpiFarmSessions" },
}
LC.widgets["dataPanel.kpiLumber"] = {
    tooltip = false,
    kind = "statCard", ["in"] = "data.kpiStrip",
    label = "locale:DATA_KPI_LUMBER", value = "--",
    width = "fill", height = 48, order = 40,
    binding = { value = "data.kpiLumber" },
}

LC.widgets["dataPanel.list"] = {
    tooltip = false,
    kind    = "scrollbox", ["in"] = "data.list",
    binding = "data.allRows",
    rowKind = "dataRow",
    spacing = 1,
    order   = 10,
}
