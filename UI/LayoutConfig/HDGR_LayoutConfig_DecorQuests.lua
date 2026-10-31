-- HDGR_LayoutConfig_DecorQuests.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time after
-- the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Decor Quests (Acquire > Decor Quests): the quest lines that lead to decor, Recipe
-- Sources' two columns (docs/mockups/decor_quests_lab.html is the design).
--   decorQuestsListPanel   (list, col 1)   -- By Decor / By Chain, presets with counts,
--                                            search, Expansion / Kind menus + Reset +
--                                            Hide collected, the view's list grouped
--                                            by expansion
--   decorQuestsDetailPanel (detail, col 2) -- one scrollbox: the decor, its campaign
--                                            card and its chain's ladder (or its one
--                                            quest); a chain's or a campaign's decor
--
-- Dynamic widget blocks (generated at load time):
--   decorQuestsListPanel.preset_<value>  (from HDG.Constants.DQ_PRESETS)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.decorQuests = {
    controllers = { "decorQuests" },
    width    = "auto",       -- 4 + 480 + 4 + 480 + 4 = 972 (Recipe Sources' columns)
    height   = "auto",       -- chrome + status come from the window's slots
    columns  = { 480, 480 },
    rows     = { 650 },
    cells    = {
        list   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        detail = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

-- A fresh header slot per panel (the two panels must not share one table).
local function _headerSlot()
    return {
        height = 34, layout = "horizontal", gap = "md",
        padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
        chrome = "PanelHeader",
    }
end

LC.panels.decorQuestsListPanel = {
    kind = "panel",
    cell = { decorQuests = "list" },
    visibleInViews = { "decorQuests" },
    slots = { header = _headerSlot() },
}
LC.panels.decorQuestsDetailPanel = {
    kind = "panel",
    cell = { decorQuests = "detail" },
    visibleInViews = { "decorQuests" },
    slots = { header = _headerSlot() },
}

-- ===== Sections -- list panel ================================================

LC.sections["decorQuests.listBody"] = {
    ["in"] = "decorQuestsListPanel",
    layout = "vertical", padding = "lg", gap = "sm", order = 10,
}
-- By Decor / By Chain segmented toggle.
LC.sections["decorQuests.viewToggle"] = {
    ["in"] = "decorQuests.listBody",
    layout = "horizontal", height = 24, gap = "xs", order = 3,
}
LC.sections["decorQuests.presetStrip"] = {
    ["in"] = "decorQuests.listBody",
    layout = "horizontal", height = 18, gap = "xs", order = 5,
}
LC.sections["decorQuests.filterBar"] = {
    ["in"] = "decorQuests.listBody",
    layout = "horizontal", height = 22, gap = "md", order = 10,
}
-- Expansion, Kind, Reset; Hide collected at the far end (the layout engine has no wrap,
-- so it rides this row rather than the presets').
LC.sections["decorQuests.dropdownRow"] = {
    ["in"] = "decorQuests.listBody",
    layout = "horizontal", height = 22, gap = "md", order = 12,
}
LC.sections["decorQuests.list"] = {
    ["in"] = "decorQuests.listBody",
    layout = "fill", order = 20, chrome = "inset",
    visible = "decorQuests.hasResults",   -- the blank label takes over on no results
}

-- ===== Sections -- detail panel ==============================================

LC.sections["decorQuests.detailBody"] = {
    ["in"] = "decorQuestsDetailPanel",
    layout = "vertical", padding = "lg", gap = "md", order = 10,
}
LC.sections["decorQuests.detailList"] = {
    ["in"] = "decorQuests.detailBody",
    layout = "fill", height = "fill", order = 10, chrome = "inset",
}

-- ===== Widgets -- list panel header ==========================================

LC.widgets["decorQuestsListPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorQuestsListPanel", slot = "header",
    text = "locale:DQ_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["decorQuestsListPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "decorQuestsListPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
LC.widgets["decorQuestsListPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "decorQuestsListPanel", slot = "header",
    text = "", font = "small", justifyH = "RIGHT",
    width = "auto", height = 14, order = 20,
    binding = "decorQuests.countLabel",
}

-- ===== Widgets -- list panel body ============================================

LC.widgets["decorQuestsListPanel.byDecor"] = {
    tooltip = false,
    kind = "button", ["in"] = "decorQuests.viewToggle", font = "button",
    text = "locale:DQ_BY_DECOR", width = "fill", height = 24, order = 10, variant = "tertiary",
    binding = { active = "decorQuests.isViewMode_decor" },
}
LC.widgets["decorQuestsListPanel.byChain"] = {
    tooltip = false,
    kind = "button", ["in"] = "decorQuests.viewToggle", font = "button",
    text = "locale:DQ_BY_CHAIN", width = "fill", height = 24, order = 20, variant = "tertiary",
    binding = { active = "decorQuests.isViewMode_chain" },
}
LC.widgets["decorQuestsListPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "decorQuests.filterBar", font = "body",
    height = 22, width = "fill", order = 10,
    multiline = false, search = true,   -- magnifier + clear "x", as every HDG search box
    placeholder = "locale:DQ_SEARCH_PLACEHOLDER",
}
-- Clear map pins: the X by Find Decor's and Recipe Sources' search boxes (owner 10-30).
LC.widgets["decorQuestsListPanel.clearPinsBtn"] = {
    tooltip = { recipe = "WarnClearPins" },
    kind = "button", ["in"] = "decorQuests.filterBar", font = "small",
    text = "X", width = "auto", height = 22, order = 20, variant = "tertiary",
}

-- Filter menus: multi-select checkbox dropdowns, each value with its decor count.
LC.widgets["decorQuestsListPanel.expansionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "decorQuests.dropdownRow", variant = "filter", multi = true,
    width = "auto", height = 22, order = 10, minWidth = 130,
    placeholder = "locale:RS_ALL_EXPANSIONS",
    binding  = { menu = "decorQuests.expMenuItems", current = "decorQuests.expFilter" },
    dispatch = { type = "DQ_TOGGLE_FILTER", payloadKey = "exp" },
}
LC.widgets["decorQuestsListPanel.kindDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "decorQuests.dropdownRow", variant = "filter", multi = true,
    width = "auto", height = 22, order = 20, minWidth = 110,
    placeholder = "locale:DQ_ALL_KINDS",
    binding  = { menu = "decorQuests.kindMenuItems", current = "decorQuests.kindFilter" },
    dispatch = { type = "DQ_TOGGLE_FILTER", payloadKey = "kind" },
}
LC.widgets["decorQuestsListPanel.resetFilters"] = {
    tooltip = false,
    kind = "button", ["in"] = "decorQuests.dropdownRow", font = "caption",
    text = "locale:COMMON_RESET", width = "auto", height = 18, order = 30, variant = "chip",
    visible = "decorQuests.anyMenuFilter",
}
LC.widgets["decorQuestsListPanel.dropdownSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "decorQuests.dropdownRow",
    width = "fill", height = 18, order = 40,
}
LC.widgets["decorQuestsListPanel.hideCollected"] = {
    tooltip = { recipe = "DqHideCollected" },
    kind = "button", ["in"] = "decorQuests.dropdownRow", font = "caption",
    text = "locale:DQ_HIDE_COLLECTED", width = "auto", height = 18, order = 50, variant = "chip",
    binding = { active = "decorQuests.hideCollected" },   -- no count: it isn't a preset
}

-- Two lists share the list well; the view mode picks one.
LC.widgets["decorQuestsListPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "decorQuests.list",
    binding = "decorQuests.listRows",
    rowKind = "decorQuestsListRow",
    spacing = 1,
    selection = { deselectable = false },
    order = 10,
    visible = "decorQuests.isViewMode_decor",
}
LC.widgets["decorQuestsListPanel.chainList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "decorQuests.list",
    binding = "decorQuests.chainRows",
    rowKind = "decorQuestsListRow",
    spacing = 1,
    selection = { deselectable = false },
    order = 10,
    visible = "decorQuests.isViewMode_chain",
}
LC.widgets["decorQuestsListPanel.blankIcon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "decorQuests.listBody",
    visible = "decorQuests.isBlank",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 25,
}
LC.widgets["decorQuestsListPanel.blank"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorQuests.listBody",
    visible = "decorQuests.isBlank",
    role = "TextDim", text = "locale:DQ_BLANK", font = "body", justifyH = "CENTER", justifyV = "TOP",
    wrap = true, width = "fill", height = 48, order = 30,   -- a search's sentence runs to three lines
    binding = "decorQuests.blankText",
}

-- ===== Widgets -- detail panel ===============================================

LC.widgets["decorQuestsDetailPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorQuestsDetailPanel", slot = "header",
    text = "locale:DQ_SELECT_DECOR", font = "subheading",
    height = 16, width = "fill", order = 10,   -- fill: long names clip instead of shoving the expansion out
    binding = "decorQuests.detailTitle",
}
LC.widgets["decorQuestsDetailPanel.headerExpansion"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorQuestsDetailPanel", slot = "header",
    text = "", font = "subheading", justifyH = "RIGHT",
    height = 16, width = "auto", order = 20,
    binding = "decorQuests.detailExpansion",
}
LC.widgets["decorQuestsDetailPanel.rows"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "decorQuests.detailList",
    binding = "decorQuests.detailRows",
    rowKind = "decorQuestsDetailRow",
    spacing = 2,
    order = 10,
}

-- ===== Widgets -- dynamic (generated at load time) ===========================

-- The presets, each with its count (the mockup's chips) and what it lists (DqPreset_<value>).
for i, p in ipairs(HDG.Constants.DQ_PRESETS) do
    LC.widgets["decorQuestsListPanel.preset_" .. p.value] = {
        tooltip = { recipe = "DqPreset_" .. p.value },
        kind = "button", ["in"] = "decorQuests.presetStrip", font = "caption",
        text = "locale:" .. p.key, width = "auto", height = 18, order = 10 + i, variant = "chip",
        binding = { text = "decorQuests.presetLabel_" .. p.value, active = "decorQuests.preset.active_" .. p.value },
    }
end
