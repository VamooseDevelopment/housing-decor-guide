-- HDGR_LayoutConfig_Recipes.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Recipes tab: full-width profession strip + 3-column body (list | queue | materials).
-- Warehouse extracted to HDGR_LayoutConfig_Warehouse.lua.

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================
-- Re-ordering columns = swap the cells map only.

LC.window.views.recipes = {
    controllers = { "recipes" },
    width    = "auto",       -- 854
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 320, 300, 320 },   -- list / queue / materials (profs moved to the strip)
    rows     = { 30, 570 },         -- static fallback; recipes.gridRows overrides (strip auto-grows w/ wrapped chips, body absorbs)
    dynamicRows = "recipes.gridRows",
    cells    = {
        strip     = { col = 1, row = 1, colSpan = 3, rowSpan = 1 },
        list      = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
        queue     = { col = 2, row = 2, colSpan = 1, rowSpan = 1 },
        materials = { col = 3, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.recipesStripPanel = {
    kind = "panel",
    cell = { recipes = "strip" },
    visibleInViews = { "recipes" },
}
LC.panels.recipesListPanel = {
    kind = "panel",
    cell = { recipes = "list" },
    visibleInViews = { "recipes" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}
LC.panels.recipesQueuePanel = {
    kind = "panel",
    cell = { recipes = "queue" },
    visibleInViews = { "recipes" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}
LC.panels.recipesMaterialsPanel = {
    kind = "panel",
    cell = { recipes = "materials" },
    visibleInViews = { "recipes" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections -- professions panel =========================================

-- Strip stack: toolbar row (dropdowns) + conditional active-filter run below.
LC.sections["recipes.stripStack"] = {
    ["in"] = "recipesStripPanel",
    layout = "vertical",
    gap = "xs",
    order = 10,
}

-- Toolbar row: Expansion + Professions multi-select dropdowns.
LC.sections["recipes.profStrip"] = {
    ["in"] = "recipes.stripStack",
    layout = "horizontal",
    height = 26,
    padding = { top = "xs", bottom = "xs", left = "sm", right = "sm" },
    gap = "sm",
    order = 10,
}

-- Active-filter run: shown when any filter is active (recipes.runVisible).
-- Chips wrap-and-flow; recipes.gridRows auto-fits the strip height.
LC.sections["recipes.runStrip"] = {
    ["in"] = "recipes.stripStack",
    layout = "horizontal",
    height = "fill",   -- fills the dynamic strip cell below the toolbar (recipes.gridRows sizes it)
    padding = { top = 0, bottom = "xs", left = "sm", right = "sm" },
    gap = "sm",
    order = 20,
    visible = "recipes.runVisible",
}

-- ===== Sections -- recipes list panel ========================================
LC.sections["recipes.listBody"] = {
    ["in"] = "recipesListPanel",
    layout = "vertical",
    padding = "md",
    gap = "sm",
    order = 10,
}
-- Recipe-list filter: full-width dropdown (All / Known / Ready / Unknown / Decor
-- not collected). Ready mode drives bucketed grouping; Unknown keeps only recipes
-- no account character has learned; Decor-not-collected keeps uncollected decor.
LC.sections["recipes.listFilterStrip"] = {
    ["in"] = "recipes.listBody",
    layout = "horizontal",
    height = 26,
    gap = "sm",
    order = 7,
}
LC.sections["recipes.filterBar"] = {
    ["in"] = "recipes.listBody",
    layout = "horizontal",
    height = 26,
    gap = "sm",
    order = 10,
}
-- Breadcrumb: profession at top of visible list. Updated imperatively on OnDataRangeChanged
-- (scroll position is ephemeral -- can't be a declarative selector binding).
LC.sections["recipes.breadcrumbBar"] = {
    ["in"] = "recipes.listBody",
    layout = "horizontal",
    height = 22,
    padding = { left = 10, right = 8, top = 0, bottom = 0 },
    order = 15,
    chrome = "inset",
    visible = "recipes.hasMultipleProfessions",   -- hide when only one profession (header already names it)
}
LC.widgets["recipesListPanel.breadcrumb"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipes.breadcrumbBar",
    text = "", font = "body", justifyH = "LEFT",
    width = "fill", height = 22,
    order = 10,
}
LC.sections["recipes.list"] = {
    ["in"] = "recipes.listBody",
    layout = "fill",
    order = 20,
    chrome = "inset",
    visible = "recipes.hasRecipes",   -- hide the well on no-results; blankLabel takes over
}
-- No-results message: sibling of the list well in recipes.listBody.
LC.widgets["recipesListPanel.blankIcon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "recipes.listBody",
    visible = "recipes.isBlank",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 25,
}
LC.widgets["recipesListPanel.blankLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipes.listBody",
    visible = "recipes.isBlank",
    role = "TextDim",
    text = "locale:REC_BLANK_RECIPES",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22,
    order = 30,
}

-- ===== Sections -- queue panel ===============================================

-- Queue body: actions + scrollbox + fixed-height "Craft Order" footer.
LC.sections["recipes.queueBody"] = {
    ["in"] = "recipesQueuePanel",
    layout = "vertical",
    padding = "md",
    gap = "sm",
    order = 10,
}
-- (Add/Clear moved to the title bar -- no body action row.)
-- 3D model preview: fixed height. Bumped +30 to claim the space the action row
-- used to take (so the model grows, not the fill queue list below it).
LC.sections["recipes.queueModel"] = {
    ["in"] = "recipes.queueBody",
    layout = "vertical",
    height = 180,
    order = 15,
}
LC.sections["recipes.queueList"] = {
    ["in"] = "recipes.queueBody",
    layout = "fill",
    order = 20,
    chrome = "inset",
    visible = "recipes.hasQueue",   -- emptyLabel takes over when nothing queued
}
-- Empty-queue message.
LC.widgets["recipesQueuePanel.emptyLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipes.queueBody",
    visible = "recipes.queueIsEmpty",
    text = "locale:REC_QUEUE_EMPTY",   -- short: the narrow queue panel truncates longer copy
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 30,
}
-- Craft Order footer: 14h caption + 80h scrollbox. Hidden when queue is empty.
LC.sections["recipes.queueCraftOrderHeader"] = {
    ["in"] = "recipes.queueBody",
    layout = "horizontal",
    height = 14,
    order = 30,
    visible = "recipes.hasQueue",
}
LC.sections["recipes.queueCraftOrderList"] = {
    ["in"] = "recipes.queueBody",
    layout = "vertical",
    height = 80,
    order = 40,
    chrome = "inset",
    visible = "recipes.hasQueue",
}

-- ===== Sections -- materials panel ===========================================
LC.sections["recipes.materialsBody"] = {
    ["in"] = "recipesMaterialsPanel",
    layout = "vertical",
    padding = "md",
    gap = "sm",
    order = 10,
}
LC.sections["recipes.materialsModeStrip"] = {
    ["in"] = "recipes.materialsBody",
    layout = "horizontal",
    height = 22,
    gap = "sm",
    order = 10,
}
LC.sections["recipes.materialsList"] = {
    ["in"] = "recipes.materialsBody",
    layout = "fill",
    order = 20,
    chrome = "inset",
}
-- Craft These First footer: 14h caption + 80h scrollbox.
LC.sections["recipes.materialsCraftTheseHeader"] = {
    ["in"] = "recipes.materialsBody",
    layout = "horizontal",
    height = 14,
    order = 30,
}
LC.sections["recipes.materialsCraftTheseList"] = {
    ["in"] = "recipes.materialsBody",
    layout = "vertical",
    height = 80,
    order = 40,
    chrome = "inset",
}
-- Cost bar: missing-materials estimate (left) + Add-all-to-Shopping (right).
LC.sections["recipes.materialsCostBar"] = {
    ["in"] = "recipes.materialsBody",
    layout = "horizontal",
    height = 24,
    gap = "sm",
    order = 50,
}

-- ===== Widgets -- professions panel ==========================================

-- Toolbar: Expansion + Profession multi-select dropdowns.
-- Profession menu shows icon + name + known/total per profession
-- (CreateTexture forbidden on menu rows, so no progress bar -- count only).
LC.widgets["recipesStripPanel.expansionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipes.profStrip",
    variant = "filter", multi = true,
    -- width="auto": auto-sizes to selection text; fixed widths under-report and overlap the next dropdown.
    width = "auto", height = 22, order = 5, minWidth = 130,
    placeholder = "locale:ACQ_ALL_EXPANSIONS",
    binding  = { menu = "recipes.expansionMenuItems", current = "recipes.expansionFilter" },
    dispatch = { type = "RECIPES_TOGGLE_EXPANSION", payloadKey = "expansion" },
}
LC.widgets["recipesStripPanel.professionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipes.profStrip",
    variant = "filter", multi = true,
    width = "auto", height = 22, order = 10, minWidth = 140,
    placeholder = "locale:REC_ALL_PROFESSIONS",
    binding  = { menu = "recipes.professionMenuItems", current = "recipes.professionFilter" },
    dispatch = { type = "RECIPES_TOGGLE_PROFESSION", payloadKey = "profession" },
}

-- ===== Widgets -- toolbar right cluster (Clear all) =========================
-- Fill spacer right-pushes "Clear all"; shown when a run is active.
LC.widgets["recipesStripPanel.toolbarSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "recipes.profStrip",
    width = "fill", height = 22, order = 20,
}
LC.widgets["recipesStripPanel.runClear"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipes.profStrip", font = "small",
    text = "locale:REC_CLEAR_ALL", width = "auto", height = 22, order = 30, variant = "tertiary",
    visible = "recipes.runVisible",
}

-- ===== Widgets -- active-filter run (chips only, full width) ==================
-- One chip per active filter token; click removes it. Run section auto-grows as chips wrap.
LC.widgets["recipesStripPanel.runChips"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "recipes.runStrip",
    cellKind = "recipesFilterChip",
    width = "fill", height = "fill", order = 10,
    binding = "recipes.activeFilterChips",
}

-- ===== Widgets -- recipes list panel =========================================

LC.widgets["recipesListPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipesListPanel", slot = "header",
    text = "locale:REC_RECIPES_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
-- Guild recipe scan: harvests decor recipe data (reagents/costs) from every guild
-- profession -- offline guildmates included. Label goes live-progress during a run.
LC.widgets["recipesListPanel.scanGuild"] = {
    tooltip = { recipe = "RecipesScanGuild" },
    kind = "button", ["in"] = "recipesListPanel", slot = "header",
    text = "locale:REC_SCAN_GUILD", font = "small",
    width = "auto", height = 18, order = 12, variant = "tertiary",
    binding = { text = "recipes.scanGuildLabel" },
}
LC.widgets["recipesListPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "recipesListPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
LC.widgets["recipesListPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "recipesListPanel", slot = "header",
    text = "", font = "small", justifyH = "RIGHT",
    width = "auto", height = 14, order = 20,
    binding = "recipes.countLabel",
}
-- Mouse hints: shift-click-to-queue has no affordance on the row, so the hint surfaces it.
LC.widgets["recipesListPanel.clickHints"] = {
    tooltip = false,   -- self-owned tooltip composed from leftText/shiftText
    kind = "clickHints", ["in"] = "recipesListPanel", slot = "header",
    leftText  = "locale:REC_LIST_HINTS_LEFT",
    shiftText = "locale:REC_LIST_HINTS_SHIFT",
    width = 16, height = 16, order = 25,
}
-- Full-width filter dropdown (All / Known / Ready / Unknown / Decor not
-- collected). Self-wires: selecting an option dispatches RECIPES_SET_LIST_FILTER.
-- "Ready" drives bucketed grouping; the others profession-group.
LC.widgets["recipesListPanel.listFilterDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "recipes.listFilterStrip",
    width = "fill", height = 25, order = 10,
    selectionStripSuffix = true,   -- closed trigger shows the label only (rows keep the dim description)
    binding  = { menu = "recipes.listFilterMenuItems", current = "recipes.listFilter" },
    dispatch = { type = "RECIPES_SET_LIST_FILTER", payloadKey = "filter" },
}
LC.widgets["recipesListPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "recipes.filterBar", font = "body",
    height = 22, width = "fill", order = 10,
    multiline   = false,
    placeholder = "locale:REC_SEARCH_PLACEHOLDER",
    binding = { text = "recipes.searchQuery" },
}
LC.widgets["recipesListPanel.resetFilters"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipes.filterBar", font = "small",
    text = "locale:COMMON_RESET", width = "auto", height = 22, order = 20, variant = "tertiary",
}
LC.widgets["recipesListPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipes.list",
    binding = "recipes.groupedRows.withQty",
    rowKind  = "recipeRow",
    spacing  = 1,
    -- SelectionBehavior: highlight via behavior (not selector-stamped isSelected).
    -- Controller_Recipes syncs to session.ui.recipes.selectedRecipeID.
    selection = { deselectable = false },
    order = 10,
}

-- ===== Widgets -- queue panel ================================================

LC.widgets["recipesQueuePanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipesQueuePanel", slot = "header",
    text = "locale:REC_QUEUE_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "recipes.queueTitleLabel",
}
-- Fill spacer right-pushes the mouse-action hints to the header's right edge.
LC.widgets["recipesQueuePanel.hintSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "recipesQueuePanel", slot = "header",
    width = "fill", height = 1, order = 15,
}
LC.widgets["recipesQueuePanel.clickHints"] = {
    tooltip = false,   -- self-owned tooltip, composed from left/right/note text
    kind = "clickHints", ["in"] = "recipesQueuePanel", slot = "header",
    title     = "locale:REC_QUEUE_HINTS_TITLE",
    leftText  = "locale:REC_QUEUE_HINTS_LEFT",
    rightText = "locale:REC_QUEUE_HINTS_RIGHT",
    noteText  = "Number button (shown when ready) crafts -- Craft 1 or Craft Max.",
    width = 34, height = 16, order = 20,
}
-- Add/Clear live in the title bar (after "Queue (N)") so the queue body has no
-- action row -- that height goes to the 3D model below.
LC.widgets["recipesQueuePanel.add"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipesQueuePanel", slot = "header", font = "small",
    text = "locale:COMMON_ADD", width = "auto", height = 22, order = 11, variant = "tertiary",
    visible = "recipes.hasSelectedRecipe",
}
LC.widgets["recipesQueuePanel.clear"] = {
    tooltip = false,
    kind = "button", ["in"] = "recipesQueuePanel", slot = "header", font = "small",
    text = "locale:COMMON_CLEAR", width = "auto", height = 22, order = 12, variant = "tertiary",
    visible = "recipes.queueHasEntries",
}
-- Model preview: explicit insets + defaultSceneID (build fn has no fallback by design).
LC.widgets["recipesQueuePanel.model"] = {
    tooltip = false,
    kind = "modelPreview", ["in"] = "recipes.queueModel",
    order = 10,
    binding = { itemID = "recipes.focusedItemID" },
    showControls = true,
    showCorbels  = false,
    showAtlas    = false,
    bgTile       = true,                             -- ported VDS dark tiling backdrop
    placeholder  = "locale:REC_PREVIEW_PLACEHOLDER",
    sceneInsets    = { top = 8, right = 8, bottom = 8, left = 8 },
    defaultSceneID = 859,   -- HOUSING_CATALOG_DECOR_MODELSCENEID_DEFAULT (12.0.5)
}
LC.widgets["recipesQueuePanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipes.queueList",
    binding = "recipes.queueRows",
    rowKind  = "queueRow",
    spacing  = 1,
    -- Deselectable=true: click-on-selected clears queueSelectedRecipeID -> materials un-scopes.
    selection = { deselectable = true },
    order = 10,
}
LC.widgets["recipesQueuePanel.craftOrderHeader"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipes.queueCraftOrderHeader",
    font = "caption", text = "locale:REC_QUEUE_TITLE",
    width = "fill", height = 12, order = 10,
    binding = "recipes.queueLumberHeaderLabel",
}
LC.widgets["recipesQueuePanel.craftOrderList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipes.queueCraftOrderList",
    binding = "recipes.queueReadinessRows",
    rowKind = "queueReadinessRow",
    spacing = 1,
    order = 10,
}

-- ===== Widgets -- materials panel ============================================

LC.widgets["recipesMaterialsPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipesMaterialsPanel", slot = "header",
    text = "locale:REC_MATERIALS_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
-- Materials controls: grouping toggle (Totals / By Recipe) + depth radio (Direct / Raw).
LC.widgets["recipesMaterialsPanel.groupingToggle"] = {
    tooltip = { recipe = "RecipesGroupingToggle" },
    kind = "button", ["in"] = "recipes.materialsModeStrip",
    variant = "chip", height = 20, order = 10, font = "caption",
    binding = { text = "recipes.materialsGroupingLabel",
                active = "recipes.isGrouping_byRecipe" },
    -- OnClick -> RECIPES_TOGGLE_MATERIALS_GROUPING (wired in the controller)
}
LC.widgets["recipesMaterialsPanel.depthRadio"] = {
    tooltip = { recipe = "RecipesDepth" },
    kind = "radioGroup", ["in"] = "recipes.materialsModeStrip",
    width = 150, height = 20, order = 20, orientation = "horizontal", font = "caption",
    binding  = { menu = "recipes.materialsDepthOptions", current = "recipes.materialsDepth" },
    dispatch = { type = "RECIPES_SET_MATERIALS_DEPTH", payloadKey = "value" },
}
LC.widgets["recipesMaterialsPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipes.materialsList",
    binding = "recipes.materials.current",
    rowKind = "matRow",
    spacing = 1,
    order = 10,
}
LC.widgets["recipesMaterialsPanel.craftTheseHeader"] = {
    tooltip = false,
    kind = "label", ["in"] = "recipes.materialsCraftTheseHeader",
    font = "caption", text = "locale:REC_CRAFT_THESE_FIRST",
    width = "fill", height = 12, order = 10,
}
LC.widgets["recipesMaterialsPanel.craftTheseList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "recipes.materialsCraftTheseList",
    binding = "recipes.craftTheseRows",
    rowKind = "craftTheseRow",
    spacing = 1,
    order = 10,
}
-- Cost bar widgets.
LC.widgets["recipesMaterialsPanel.costLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "recipes.materialsCostBar",
    font = "small", text = "", width = "fill", height = 18, order = 10,
    binding = "recipes.materials.cost",
}
LC.widgets["recipesMaterialsPanel.addAll"] = {
    tooltip = { recipe = "RecipesAddAllToAH" },
    kind = "button", ["in"] = "recipes.materialsCostBar", font = "small",
    text = "locale:REC_BUY_MATS_FROM_AH", width = "auto", height = 22, order = 20,
    variant = "primary",
}
