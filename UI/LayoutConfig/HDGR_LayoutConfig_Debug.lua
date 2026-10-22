-- HDGR_LayoutConfig_Debug.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Debug log tab: filter bar + scrollingTextBox + footer (autoscroll + count).
-- 904px wide so formatted log columns align.

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.debug = {
    controllers = { "debug" },
    width    = "auto",       -- 4 + 904 + 4 = 912
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 904 },
    rows     = { 600 },      -- raised 500->600 so the nav column fills (no nav scroll)
    cells    = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.debugPanel = {
    kind = "panel",
    cell = { debug = "body" },
    visibleInViews = { "debug" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================

LC.sections["debug.body"] = {
    ["in"] = "debugPanel",
    layout = "vertical",
    padding = "lg",
    gap = "sm",
    order = 10,
}
LC.sections["debug.filterBar"] = {
    ["in"] = "debug.body",
    layout = "horizontal",
    height = 26,
    gap = "md",
    order = 10,
}
LC.sections["debug.bodyText"] = {
    ["in"] = "debug.body",
    layout = "fill",
    order = 20,
    chrome = "inset",
}
LC.sections["debug.footer"] = {
    ["in"] = "debug.body",
    layout = "horizontal",
    height = 22,
    gap = "md",
    order = 30,
}

-- ===== Widgets ===============================================================

LC.widgets["debugPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "debugPanel", slot = "header",
    text = "locale:DEBUG_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
-- Layout describer: enter a view name + click Describe; output pops in CopyDialog.
LC.widgets["debugPanel.layoutInput"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "debugPanel", slot = "header", font = "body",
    text = "styles", width = 100, height = 22, order = 20,
}
LC.widgets["debugPanel.layoutBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "debugPanel", slot = "header", font = "small",
    text = "locale:DEBUG_DESCRIBE_LAYOUT", width = "auto", height = 22, order = 30,
    variant = "tertiary",
}
-- Memory Profile: GetAddOnMemoryUsage + collectgarbage("count") snapshot -> CopyDialog.
LC.widgets["debugPanel.memBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "debugPanel", slot = "header", font = "small",
    text = "locale:DEBUG_MEM_PROFILE", width = "auto", height = 22, order = 35,
    variant = "tertiary",
}
-- Perf Profile: HDG.Perf:Report() -> CopyDialog. Gate: HDG_DB.perf (/hdgr perf on).
LC.widgets["debugPanel.perfBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "debugPanel", slot = "header", font = "small",
    text = "locale:DEBUG_PERF_PROFILE", width = "auto", height = 22, order = 37,
    variant = "tertiary",
}
LC.widgets["debugPanel.tagFilter"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "debug.filterBar",
    height = 22, width = 140, order = 10,
    placeholder = "locale:DEBUG_TAG_ALL",
    binding  = { menu = "log.tagMenuItems", current = "log.filterTag" },
    dispatch = { type = "LOG_SET_FILTER", payloadKey = "tag" },
}
LC.widgets["debugPanel.levelFilter"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "debug.filterBar",
    height = 22, width = 130, order = 20,
    placeholder = "locale:DEBUG_LEVEL_ALL",
    binding  = { menu = "log.levelMenuItems", current = "log.filterLevel" },
    dispatch = { type = "LOG_SET_FILTER", payloadKey = "level" },
}
LC.widgets["debugPanel.clear"] = {
    tooltip = false,
    kind = "button", ["in"] = "debug.filterBar", font = "caption",
    text = "locale:COMMON_CLEAR", width = 60, height = 22, order = 30,
}
LC.widgets["debugPanel.copy"] = {
    tooltip = false,
    kind = "button", ["in"] = "debug.filterBar", font = "caption",
    text = "locale:COMMON_COPY", width = 60, height = 22, order = 40,
}
-- Spacer right-pushes the autoscroll toggle.
LC.widgets["debugPanel.spacer"] = {
    tooltip = false,
    kind = "label", ["in"] = "debug.filterBar", font = "caption",
    text = "", width = "fill", height = 22, order = 50,
}
LC.widgets["debugPanel.body"] = {
    tooltip = false,
    kind = "scrollingTextBox", ["in"] = "debug.bodyText",
    binding = { text = "log.formattedText" },
    maxLetters = 16384,
    autoScroll = true,
    font = "caption",
    order = 10,
}
LC.widgets["debugPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "debug.footer", font = "caption",
    text = "", width = "fill", height = 14, order = 10,
    binding = "log.entryCount",
}
-- Auto-scroll checkbox: bound to log.filterAutoScroll.
LC.widgets["debugPanel.autoScroll"] = {
    tooltip = false,
    kind = "checkbox", ["in"] = "debug.footer",
    text = "locale:DEBUG_AUTOSCROLL", width = 100, height = 22, order = 20,
    binding = { checked = "log.filterAutoScroll" },
}

