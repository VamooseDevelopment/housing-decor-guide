-- HDGR_LayoutConfig_HouseTab.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- 2-column view. Picker panel (col 2) visible = "houseTab.pickerOpen";
-- closing it collapses col 2 and the window narrows. Opening widens the window.
--   houseTabPanel       (col 1) -- dashboard (picker + design btns + scrollbox)
--   houseTabPickerPanel (col 2) -- conditional picker side panel

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ================================================================
-- dynamicColumns = house.viewColumns: removes col 2 entirely when picker closes
-- (visible-bound panel alone doesn't shrink the window -- colSpan=2 chrome keeps it live).

LC.window.views.houseTab = {
    controllers = { "houseTab" },
    width          = "auto",
    height         = "auto",
    columns        = { 900 },              -- fallback; the dynamic selector takes over at layout time
    dynamicColumns = "house.viewColumns",
    rows           = { 600 },              -- chrome/status rows removed (HDG-ADR-025 slots)
    cells          = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        picker = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ==============================================================

LC.panels.houseTabPanel = {
    kind = "panel",
    cell = { houseTab = "body" },
    visibleInViews = { "houseTab" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- Picker side panel. visible-bound; panelVisible resolver collapses col 2 when hidden.

LC.panels.houseTabPickerPanel = {
    kind = "panel",
    cell = { houseTab = "picker" },
    visibleInViews = { "houseTab" },
    visible = "houseTab.pickerOpen",
    slots = {
        header = {
            height = 28, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Widgets =============================================================

LC.widgets["houseTabPanel.pickerBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "houseTabPanel", slot = "header",
    binding = "house.pickerButtonLabel",
    font = "body",
    width = 100, height = 22, order = 10,
}

-- Design Mode hidden for the 3.0 launch -- deferred to 3.0.1+ (see TODO_HousingDecorGuide.md).
-- Kept (not deleted) + binding intact so restoring it is a one-line `visible` flip.
LC.widgets["houseTabPanel.designBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "houseTabPanel", slot = "header",
    binding = "house.designButtonLabel",
    font = "body",
    width = 100, height = 22, order = 20,
    visible = false,
}

-- Blank state: shown while no dashboard widget has data to render (fresh
-- install / house not captured yet). Same icon+label shape as decorBlankPanel.
LC.widgets["houseTabPanel.blankIcon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "houseTabPanel",
    visible = "house.isBlank",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 5,
}
LC.widgets["houseTabPanel.blankLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "houseTabPanel",
    visible = "house.isBlank",
    role = "TextDim",
    text = "locale:HT_BLANK_DASHBOARD",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 6,
}

-- Dashboard scrollbox: spacing=1 matches the row factory's CELL_GAP for uniform whitespace.
LC.widgets["houseTabPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "houseTabPanel",
    binding = "house.widgetRows",
    rowKind   = "houseTabWidgetRow",
    spacing   = 1,
    selection = { deselectable = true },
    order = 10,
}

LC.widgets["houseTabPickerPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "houseTabPickerPanel", slot = "header",
    text = "locale:HT_PICKER_TITLE",
    font = "heading",
    width = "fill", height = 22, order = 10,
}
-- Mouse hint: drag-to-reorder has no visual cue; hint surfaces the gesture.
LC.widgets["houseTabPickerPanel.clickHints"] = {
    tooltip = false, kind = "clickHints", ["in"] = "houseTabPickerPanel", slot = "header",
    dragText = "Reorder the dashboard widgets.",
    title    = "locale:HT_PICKER_TITLE",
    width = 16, height = 16, order = 20,
}

LC.widgets["houseTabPickerPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "houseTabPickerPanel",
    binding = "house.pickerRows",
    rowKind   = "houseTabPickerRow",
    spacing   = 1,
    selection = { deselectable = true },
    order = 10,
}
