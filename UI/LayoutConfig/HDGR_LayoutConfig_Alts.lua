-- HDGR_LayoutConfig_Alts.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Alts tab layout: single-column character roster (profession ladders).
--   altsPanel  (body) -- Account Summary + Characters sections

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.alts = {
    controllers = { "alts" },
    width    = "auto",       -- 4 + 600 + 4 = 608
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 600 },
    rows     = { 600 },      -- raised 550->600 so the nav column fills (no nav scroll)
    cells    = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

-- Single panel: header + body scrollbox of heterogeneous rows (charHeaderRow / profHeaderRow / skillLineRow).
LC.panels.altsPanel = {
    kind = "panel",
    cell = { alts = "body" },
    visibleInViews = { "alts" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================
-- summaryGroup: Account Summary (always visible). Legend explains cell/pip colors.
-- charsGroup: Characters, with Active / Hidden population pills.

LC.sections["alts.body"] = {
    ["in"] = "altsPanel",
    layout = "vertical",
    padding = "lg",
    gap = "sm",
    order = 10,
}
-- Account Summary: header + scrollbox. 300px fits all 12 professions without scrolling.
LC.sections["alts.summaryGroup"] = {
    ["in"] = "alts.body",
    layout = "vertical",
    gap = "xs",
    order = 10,
    height = 300,
}
LC.sections["alts.summaryHeader"] = {
    ["in"] = "alts.summaryGroup",
    layout = "horizontal",
    height = 16,
    order = 10,
}
LC.sections["alts.summaryList"] = {
    ["in"] = "alts.summaryGroup",
    layout = "fill",
    order = 20,
    chrome = "inset",
}
-- Legend strip: colored text composed by alts.legendText so palette swaps recolor it.
LC.sections["alts.summaryLegend"] = {
    ["in"] = "alts.summaryGroup",
    layout = "horizontal",
    height = 14,
    order = 30,
}
-- Characters: title label + Active / Hidden population pills + body scrollbox.
LC.sections["alts.charsGroup"] = {
    ["in"] = "alts.body",
    layout = "vertical",
    gap = "xs",
    order = 20,
}
LC.sections["alts.charsHeader"] = {
    ["in"] = "alts.charsGroup",
    layout = "horizontal",
    height = 22,
    order = 10,
    gap = "xs",
}
LC.sections["alts.charsBody"] = {
    ["in"] = "alts.charsGroup",
    layout = "fill",
    order = 20,
    chrome = "inset",
}

-- ===== Widgets ===============================================================

LC.widgets["altsPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "altsPanel", slot = "header",
    text = "locale:ALTS_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "alts.title",
}
-- Account Summary header.
LC.widgets["altsPanel.summaryHeader"] = {
    tooltip = false,
    kind = "label", ["in"] = "alts.summaryHeader",
    text = "locale:ALTS_SUMMARY_HEADING",
    font = "heading", height = 16, width = "fill", order = 10,
    role = "TextStatus",
}
LC.widgets["altsPanel.summaryList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "alts.summaryList",
    binding = "alts.summaryRows",
    rowKind = "altsRow",
    spacing = 1,
    order = 10,
}
-- Legend strip: colored text from selector; palette swaps recolor automatically.
LC.widgets["altsPanel.summaryLegend"] = {
    tooltip = false,
    kind = "label", ["in"] = "alts.summaryLegend",
    font = "caption", width = "fill", height = 14, order = 10,
    role = "TextDim",
    binding = "alts.legendText",
}
-- Characters header: title (left) + Active / Hidden population pills (right, variant="chip").
LC.widgets["altsPanel.charsTitle"] = {
    tooltip = false,
    kind = "label", ["in"] = "alts.charsHeader",
    text = "locale:ALTS_CHARS_TITLE", font = "heading",
    height = 22, width = "auto", order = 10,
}
LC.widgets["altsPanel.charsSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "alts.charsHeader",
    width = "fill", height = 22, order = 20,
}
LC.widgets["altsPanel.charsPill_active"] = {
    tooltip = false,
    kind = "button", ["in"] = "alts.charsHeader", font = "caption",
    text = "locale:ALTS_PILL_ACTIVE", width = "auto", height = 18, order = 30, variant = "chip",
    binding = { text = "alts.activePillLabel", active = "alts.isPopulation_active" },
    population = "active",
}
LC.widgets["altsPanel.charsPill_hidden"] = {
    tooltip = false,
    kind = "button", ["in"] = "alts.charsHeader", font = "caption",
    text = "locale:ALTS_PILL_HIDDEN", width = "auto", height = 18, order = 40, variant = "chip",
    binding = { text = "alts.hiddenPillLabel", active = "alts.isPopulation_hidden" },
    population = "hidden",
}
LC.widgets["altsPanel.charsList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "alts.charsBody",
    binding = "alts.charsRows",
    rowKind = "altsRow",
    spacing = 1,
    order = 10,
}
