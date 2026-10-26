-- HDGR_LayoutConfig_RecipeSources.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time after
-- the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Recipe Sources: where every decor recipe is learned, Find Decor's two columns
-- (docs/mockups/recipe_sources_lab.html is the signed-off design).
--   recipeSourcesListPanel   (list, col 1)   -- By Recipe / By Teacher, presets,
--                                              search + Map N places, filter menus,
--                                              active-filter tags, the list
--   recipeSourcesDetailPanel (detail, col 2) -- one scrollbox of flattened cards,
--                                              the vendorMap under it
--
-- Dynamic widget blocks (generated at load time):
--   recipeSourcesListPanel.preset_<value>  (from HDG.Constants.RS_PRESETS)
--   recipeSourcesListPanel.tag_<axis>      (from HDG.Constants.RS_FILTER_AXES)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.recipeSources = {
    controllers = { "recipeSources" },
    width    = "auto",       -- 4 + 480 + 4 + 480 + 4 = 972 (Find Decor's columns)
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

LC.panels.recipeSourcesListPanel = {
    kind = "panel",
    cell = { recipeSources = "list" },
    visibleInViews = { "recipeSources" },
    slots = { header = _headerSlot() },
}
LC.panels.recipeSourcesDetailPanel = {
    kind = "panel",
    cell = { recipeSources = "detail" },
    visibleInViews = { "recipeSources" },
    slots = { header = _headerSlot() },
}

-- ===== Sections -- list panel ================================================

LC.sections["recipeSources.listBody"] = {
    ["in"] = "recipeSourcesListPanel",
    layout = "vertical", padding = "lg", gap = "sm", order = 10,
}
-- By Recipe / By Teacher segmented toggle.
LC.sections["recipeSources.viewToggle"] = {
    ["in"] = "recipeSources.listBody",
    layout = "horizontal", height = 24, gap = "xs", order = 5,
}
LC.sections["recipeSources.presetStrip"] = {
    ["in"] = "recipeSources.listBody",
    layout = "horizontal", height = 22, gap = "sm", order = 7,
}
LC.sections["recipeSources.filterBar"] = {
    ["in"] = "recipeSources.listBody",
    layout = "horizontal", height = 26, gap = "md", order = 10,
}
-- Six filter menus over two rows (the layout engine has no wrap), Here closing row 2.
LC.sections["recipeSources.dropdownRow1"] = {
    ["in"] = "recipeSources.listBody",
    layout = "horizontal", height = 22, gap = "md", order = 12,
}
LC.sections["recipeSources.dropdownRow2"] = {
    ["in"] = "recipeSources.listBody",
    layout = "horizontal", height = 22, gap = "md", order = 13,
}
LC.sections["recipeSources.activeFiltersRow"] = {
    ["in"] = "recipeSources.listBody",
    layout = "horizontal", height = 20, gap = "sm", order = 16,
}
LC.sections["recipeSources.list"] = {
    ["in"] = "recipeSources.listBody",
    layout = "fill", order = 20, chrome = "inset",
    visible = "recipeSources.hasResults",   -- the blank label takes over on no results
}

-- ===== Sections -- detail panel ==============================================

LC.sections["recipeSources.detailBody"] = {
    ["in"] = "recipeSourcesDetailPanel",
    layout = "vertical", padding = "lg", gap = "md", order = 10,
}
LC.sections["recipeSources.detailList"] = {
    ["in"] = "recipeSources.detailBody",
    layout = "fill", height = "fill", order = 10, chrome = "inset",
}
-- The map of the first place; hidden when the selection has no place to draw.
LC.sections["recipeSources.mapBox"] = {
    ["in"] = "recipeSources.detailBody",
    layout = "vertical", height = 170, order = 20, chrome = "inset",
    visible = "recipeSources.hasMapPoint",
}

-- ===== Widgets -- list panel header ==========================================

LC.widgets["recipeSourcesListPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipeSourcesListPanel", slot = "header",
    text = "locale:RS_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["recipeSourcesListPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "recipeSourcesListPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
LC.widgets["recipeSourcesListPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "recipeSourcesListPanel", slot = "header",
    text = "", font = "small", justifyH = "RIGHT",
    width = "auto", height = 14, order = 20,
    binding = "recipeSources.countLabel",
}

-- ===== Widgets -- list panel body ============================================

LC.widgets["recipeSourcesListPanel.byRecipe"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipeSources.viewToggle", font = "button",
    text = "locale:RS_BY_RECIPE", width = "fill", height = 24, order = 10, variant = "tertiary",
    binding = { active = "recipeSources.isViewMode_recipe" },
}
LC.widgets["recipeSourcesListPanel.byTeacher"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipeSources.viewToggle", font = "button",
    text = "locale:RS_BY_TEACHER", width = "fill", height = 24, order = 20, variant = "tertiary",
    binding = { active = "recipeSources.isViewMode_teacher" },
}
LC.widgets["recipeSourcesListPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "recipeSources.filterBar", font = "body",
    height = 22, width = "fill", order = 10,
    multiline = false, search = true,   -- magnifier + clear "x" (Vamoose, 2026-10-26)
    placeholder = "locale:RS_SEARCH_PLACEHOLDER",
}
LC.widgets["recipeSourcesListPanel.mapAllBtn"] = {
    tooltip = { recipe = "RsMapAll" },
    kind = "button", ["in"] = "recipeSources.filterBar", font = "small",
    text = "locale:RS_MAP_PLACES", width = "auto", height = 22, order = 20, variant = "tertiary",
    binding = { text = "recipeSources.mapAllLabel" },
}
LC.widgets["recipeSourcesListPanel.clearPinsBtn"] = {
    tooltip = { recipe = "WarnClearPins" },
    kind = "button", ["in"] = "recipeSources.filterBar", font = "small",
    text = "X", width = "auto", height = 22, order = 30, variant = "tertiary",
}

-- Filter menus: multi-select checkbox dropdowns. Profession is the Recipes tab's
-- menu (My Professions / All / the nine, each learned/total) over this tab's set.
LC.widgets["recipeSourcesListPanel.professionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipeSources.dropdownRow1", variant = "filter", multi = true,
    width = "fill", height = 22, order = 10, minWidth = 130,
    placeholder = "locale:REC_ALL_PROFESSIONS",
    binding  = { menu = "recipes.professionMenuItems", current = "recipeSources.profFilter" },
    dispatch = { type = "RS_TOGGLE_FILTER", payloadKey = "prof" },
}
LC.widgets["recipeSourcesListPanel.expansionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipeSources.dropdownRow1", variant = "filter", multi = true,
    width = "fill", height = 22, order = 20, minWidth = 130,
    placeholder = "locale:RS_ALL_EXPANSIONS",
    binding  = { menu = "recipeSources.expMenuItems", current = "recipeSources.expFilter" },
    dispatch = { type = "RS_TOGGLE_FILTER", payloadKey = "exp" },
}
LC.widgets["recipeSourcesListPanel.sourceDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipeSources.dropdownRow1", variant = "filter", multi = true,
    width = "fill", height = 22, order = 30, minWidth = 110,
    placeholder = "locale:RS_ALL_SOURCES",
    binding  = { menu = "recipeSources.srcMenuItems", current = "recipeSources.srcFilter" },
    dispatch = { type = "RS_TOGGLE_FILTER", payloadKey = "src" },
}
LC.widgets["recipeSourcesListPanel.zoneDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipeSources.dropdownRow2", variant = "filter", multi = true,
    width = "fill", height = 22, order = 10, minWidth = 100,
    placeholder = "locale:RS_ALL_ZONES",
    binding  = { menu = "recipeSources.zoneMenuItems", current = "recipeSources.zoneFilter" },
    dispatch = { type = "RS_TOGGLE_FILTER", payloadKey = "zone" },
}
LC.widgets["recipeSourcesListPanel.repDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipeSources.dropdownRow2", variant = "filter", multi = true,
    width = "fill", height = 22, order = 20, minWidth = 100,
    placeholder = "locale:RS_ALL_REPS",
    binding  = { menu = "recipeSources.repMenuItems", current = "recipeSources.repFilter" },
    dispatch = { type = "RS_TOGGLE_FILTER", payloadKey = "rep" },
}
LC.widgets["recipeSourcesListPanel.currencyDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipeSources.dropdownRow2", variant = "filter", multi = true,
    width = "fill", height = 22, order = 30, minWidth = 100,
    placeholder = "locale:RS_ALL_CURRENCIES",
    binding  = { menu = "recipeSources.curMenuItems", current = "recipeSources.curFilter" },
    dispatch = { type = "RS_TOGGLE_FILTER", payloadKey = "cur" },
}
-- Here: the Zone filter set once to where the player stands; greyed where no recipe lists it.
LC.widgets["recipeSourcesListPanel.here"] = {
    tooltip = { recipe = "RsHere" },
    kind = "button", ["in"] = "recipeSources.dropdownRow2", font = "button",
    text = "locale:RS_HERE", width = "auto", height = 22, order = 40, variant = "tertiary",
    binding = { enabled = "recipeSources.hasCurrentZones" },
}

LC.widgets["recipeSourcesListPanel.activeFiltersLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "recipeSources.activeFiltersRow",
    font = "small", text = "locale:RS_NO_FILTERS", height = 14, width = "auto", order = 10,
    binding = "recipeSources.activeFiltersLabel",
}
-- Reset sits right after the label, before the tags: the row has no wrap, and the
-- tags can run past the panel edge where Reset would be clipped.
LC.widgets["recipeSourcesListPanel.resetFilters"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipeSources.activeFiltersRow", font = "caption",
    text = "locale:COMMON_RESET", width = "auto", height = 16, order = 15, variant = "chip",
    visible = "recipeSources.anyFilter",
}

-- Two lists share the list well; the view mode picks one.
LC.widgets["recipeSourcesListPanel.recipeList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipeSources.list",
    binding = "recipeSources.recipeRows",
    rowKind = "recipeSourcesListRow",
    spacing = 1,
    selection = { deselectable = false },
    order = 10,
    visible = "recipeSources.isViewMode_recipe",
}
LC.widgets["recipeSourcesListPanel.teacherList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipeSources.list",
    binding = "recipeSources.teacherRows",
    rowKind = "recipeSourcesListRow",
    spacing = 1,
    selection = { deselectable = false },
    order = 10,
    visible = "recipeSources.isViewMode_teacher",
}
LC.widgets["recipeSourcesListPanel.blankIcon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "recipeSources.listBody",
    visible = "recipeSources.isBlank",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 25,
}
LC.widgets["recipeSourcesListPanel.blank"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipeSources.listBody",
    visible = "recipeSources.isBlank",
    role = "TextDim", text = "", font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 30,
    binding = "recipeSources.blankText",
}

-- ===== Widgets -- detail panel ===============================================

LC.widgets["recipeSourcesDetailPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipeSourcesDetailPanel", slot = "header",
    text = "locale:RS_SELECT_RECIPE", font = "subheading",
    height = 16, width = "fill", order = 10,   -- fill: long names clip instead of shoving the badge out
    binding = "recipeSources.detailTitle",
}
LC.widgets["recipeSourcesDetailPanel.headerExpansion"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipeSourcesDetailPanel", slot = "header",
    text = "", font = "subheading", justifyH = "RIGHT",
    height = 16, width = "auto", order = 20,
    binding = "recipeSources.detailExpansion",
}
LC.widgets["recipeSourcesDetailPanel.rows"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipeSources.detailList",
    binding = "recipeSources.detailRows",
    rowKind = "recipeSourcesDetailRow",
    spacing = 2,
    order = 10,
}
LC.widgets["recipeSourcesDetailPanel.map"] = {
    tooltip = false,
    kind = "vendorMap", ["in"] = "recipeSources.mapBox",
    order = 10,
    binding = { mapPoint = "recipeSources.selected.mapPoint" },
}

-- ===== Widgets -- dynamic (generated at load time) ===========================

for i, p in ipairs(HDG.Constants.RS_PRESETS) do
    LC.widgets["recipeSourcesListPanel.preset_" .. p.value] = {
        tooltip = false,
        kind = "button", ["in"] = "recipeSources.presetStrip", font = "small",
        text = "locale:" .. p.key, width = "auto", height = 22, order = 10 + i, variant = "tertiary",
        binding = { active = "recipeSources.preset.active_" .. p.value },
    }
end

-- The preset's tag, first: shown while the preset is not All; a click sets it to All.
LC.widgets["recipeSourcesListPanel.tag_preset"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipeSources.activeFiltersRow", font = "caption",
    text = "", width = "auto", height = 16, order = 20, variant = "chip",
    binding = { text = "recipeSources.tag_preset" },
    visible = "recipeSources.has_preset",
}

-- One tag per filter axis, shown while the axis has values; a click clears it.
for i, a in ipairs(HDG.Constants.RS_FILTER_AXES) do
    LC.widgets["recipeSourcesListPanel.tag_" .. a.axis] = {
        tooltip = false,
        kind = "button", ["in"] = "recipeSources.activeFiltersRow", font = "caption",
        text = "", width = "auto", height = 16, order = 20 + i, variant = "chip",
        binding = { text = "recipeSources.tag_" .. a.axis },
        visible = "recipeSources.has_" .. a.axis,
        axis = a.axis,
    }
end
