-- HDGR_LayoutConfig_Companion.lua
-- ============================================================================
-- In-editor HouseEditor companion -- declarative satellite window, laid out
-- like Blizzard's own decor catalog (owner ruling 2026-11-07: this REPLACES the
-- old chips + sidebar look). Lab: docs/mockups/hdgr-companion-redesign.html.
--
-- `lazy` + `parent` resolver -> frame nests under HouseEditorFrame; editor-only
-- visibility falls out of the parent cascade for free.
--
--   +------------------------------------------------------------+
--   | [icon] Housing Decor Guide     [$] [Inside 132 / 200]  [X]  |  header slot
--   +------------------------------------------------------------+
--   | [search.............................] [< # L >] [< ||| 4 >] |  toolbar
--   +------+-----------------------------------------------------+
--   | rail | [<] [ Beds & Bedding                  v ] [>] 12 decor|  grid heading
--   | [..] | +------------------+                                 |
--   | [..] | | picker (flyout,  |  decor grid (cardGrid, exactly   |  grid body (fill:
--   | [..] | | pooled list)     |  `columns` tiles, centred)       |   grid + flyout
--   | [..] | +------------------+                                 |   overlay)
--   +======+=====================================================+
--   | Recent placements                                          |   companionRecentPanel
--   | <[#][#][#][#][#][#][#][#] horizontal filmstrip, newest <-- |
--   +------------------------------------------------------------+
--
-- Width follows the tile size + columns settings (companion.viewColumns),
-- never under Blizzard's 415px storage frame.
--
-- Selectors (UI/HDGR_Selectors_Companion.lua):
--   companion.windowShown / windowPosition     -- reconciler visibility + position
--   companion.viewColumns                      -- window width
--   companion.isMode_<key>                     -- rail active state
--   companion.showCost / locChip               -- header controls
--   companion.search / tileSize / columnsText / can*  -- toolbar
--   companion.pickedRow / pickerOpen / hasLists / hasListSteps / gridTotal -- grid heading
--   companion.sidebarRows / gridItems / tilePx / columns / recentStrip     -- lists
-- Row/cell kinds:
--   companionSidebarRow  -- HDGR_Controller_Companion.lua (the picker's rows)
--   companionGridCell    -- Modules/HDGR_HouseEditorCompanion.lua (placement click)
-- Widget kinds companionRailButton / companionSprite / companionPicker live in
-- HDGR_Controller_Companion.lua.

HDG = HDG or {}
local LC   = HDG.LayoutConfig
local COMP = HDG.Constants.COMPANION

-- ===== View ==================================================================

LC.window.views.companion = {
    controllers = { "companion" },
    standalone = true,            -- HDG.Window floating frame; not a main-window tab
    width      = "auto",          -- from the one column track (companion.viewColumns)
    height     = "auto",
    columns    = { 525 },         -- static fallback; the dynamic track always answers
    dynamicColumns = "companion.viewColumns",
    rows       = { 560, 92 },     -- main body panel, then the recent-placements panel (Blizzard's frame is 651 tall)
    cells      = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        recent = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
-- Body panel: window chrome in the header slot; toolbar + rail|grid split in the body.
LC.panels.companionPanel = {
    kind = "panel",
    cell = { companion = "body" },
    visibleInViews = { "companion" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================
-- companion.viewColumns adds these up: body padding "md" each side, the rail,
-- the split gap "sm", the grid well. Change one here, change it there.

LC.sections["companion.body"] = {
    ["in"]  = "companionPanel",
    layout  = "vertical",
    padding = "md",
    gap     = "sm",
    order   = 10,
}
-- Toolbar: search (flexes) + the tile size and columns steppers.
LC.sections["companion.toolbar"] = {
    ["in"]  = "companion.body",
    layout  = "horizontal",
    height  = 24,
    gap     = "sm",
    order   = 10,
}
LC.sections["companion.sizeStepper"] = {
    ["in"]  = "companion.toolbar",
    layout  = "horizontal",
    width   = 66, height = 22,
    padding = { top = 4, right = 2, bottom = 4, left = 2 },
    gap     = "xs",
    chrome  = "inset",
    order   = 70,
}
LC.sections["companion.colsStepper"] = {
    ["in"]  = "companion.toolbar",
    layout  = "horizontal",
    width   = 66, height = 22,
    padding = { top = 4, right = 2, bottom = 4, left = 2 },
    gap     = "xs",
    chrome  = "inset",
    order   = 80,
}
-- Body split: the mode rail + the grid column (fills).
LC.sections["companion.split"] = {
    ["in"]  = "companion.body",
    layout  = "horizontal",
    gap     = "sm",
    order   = 20,
}
LC.sections["companion.rail"] = {
    ["in"]  = "companion.split",
    layout  = "vertical",
    width   = COMP.RAIL_WIDTH,
    padding = { top = 5, right = 6, bottom = 5, left = 5 },   -- 64px buttons centred in 75
    gap     = "sm",
    chrome  = "inset",
    order   = 10,
}
LC.sections["companion.gridCol"] = {
    ["in"]  = "companion.split",
    layout  = "vertical",
    width   = "fill",
    gap     = "xs",
    order   = 20,
}
-- Heading: prev / picker / next, then the decor count.
LC.sections["companion.gridHead"] = {
    ["in"]  = "companion.gridCol",
    layout  = "horizontal",
    height  = 24,
    gap     = "sm",
    order   = 10,
}
-- Grid body is an overlay: the grid well, and the picker flyout over its left side.
LC.sections["companion.gridBody"] = {
    ["in"]  = "companion.gridCol",
    layout  = "fill",
    order   = 20,
}
LC.sections["companion.gridWell"] = {
    ["in"]  = "companion.gridBody",
    layout  = "fill",
    chrome  = "inset",
    order   = 10,
}
LC.sections["companion.flyoutRow"] = {
    ["in"]  = "companion.gridBody",
    layout  = "horizontal",
    padding = { top = 0, right = 0, bottom = "md", left = "md" },
    order   = 20,
}
-- The picker: a pooled ScrollBox (some players have hundreds of categories), its
-- height capped by the grid body -- never a frame per list, never growing with the count.
LC.sections["companion.flyout"] = {
    ["in"]    = "companion.flyoutRow",
    layout    = "fill",
    width     = COMP.FLYOUT_WIDTH,
    padding   = "xs",
    chrome    = "popover",
    visible   = "companion.pickerOpen",
    order     = 10,
}
-- ===== Recent placements -- own panel (distinct surface) ====================
-- Horizontal filmstrip: newest-left, mouse-wheel scroll.
LC.panels.companionRecentPanel = {
    kind = "panel",
    cell = { companion = "recent" },
    visibleInViews = { "companion" },
}
LC.sections["companionRecent.body"] = {
    ["in"]   = "companionRecentPanel",
    layout   = "vertical",
    padding  = "sm",
    gap      = "xs",
    order    = 10,
}
LC.sections["companionRecent.labelRow"] = {
    ["in"]   = "companionRecent.body",
    layout   = "horizontal",
    height   = 12,
    order    = 10,
}
LC.sections["companionRecent.strip"] = {
    ["in"]   = "companionRecent.body",
    layout   = "fill",
    height   = 62,
    order    = 20,
    chrome   = "inset",
}

-- ===== Widgets -- header slot (window chrome) ================================

LC.widgets["companionPanel.icon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "companionPanel", slot = "header",
    texture = "Interface/AddOns/HousingDecorGuide/textures/Vamoose_HDG_400_trans",
    width = 20, height = 20, order = 5,
}
LC.widgets["companionPanel.title"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "companionPanel", slot = "header",
    text = "locale:COMP_ADDON_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["companionPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "companionPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
-- Cost-badge toggle: the placement-cost budget atlas, full-tinted when cost is
-- shown (active) and dimmed when hidden (HDG parity). Click -> COMPANION_TOGGLE_COST
-- + the "Show/Hide placement cost" tooltip are wired in CompanionController.
LC.widgets["companionPanel.costToggle"] = {
    tooltip = false,
    kind = "iconToggle", ["in"] = "companionPanel", slot = "header",
    glyph = "house-decor-budget-icon", size = 18,
    width = 18, height = 18, order = 20,
    binding = { active = "companion.showCost" },
}
-- Where you stand + that budget (Inside 132 / 200). Status, not a control; the
-- controller attaches the budget tooltip.
LC.widgets["companionPanel.locChip"] = {
    tooltip = false,
    kind = "button", ["in"] = "companionPanel", slot = "header", font = "small",
    text = "", width = "auto", height = 22, order = 25, variant = "chip",
    binding = { text = "companion.locChip" },
}
LC.widgets["companionPanel.close"] = {
    tooltip = { recipe = "Close" },
    kind = "button", ["in"] = "companionPanel", slot = "header",
    width = 22, height = 22, order = 95,
    close = true, size = 22, iconSize = 14,
}

-- ===== Widgets -- toolbar (search + steppers) ================================

LC.widgets["companionPanel.search"] = {
    search = true,   -- magnifier + clear "x", as Recipe Sources (Vamoose, 2026-10-26)
    tooltip = false,
    kind = "editbox", ["in"] = "companion.toolbar", font = "small",
    height = 22, width = "fill", order = 60,
    placeholder = "locale:COMP_SEARCH_PLACEHOLDER",
    binding = { text = "companion.search" },
}

-- One stepper: < glyph value >. The arrows dim at either end (active = can step).
local STEP_ARROW = "wowlabs-spectatecycling-arrowleft"   -- points left; turned for the right arrow
local function _stepper(section, prefix, glyphCell, valueBinding, down, up)
    LC.widgets["companionPanel." .. prefix .. "Down"] = {
        tooltip = { recipe = down.recipe },
        kind = "iconToggle", ["in"] = section, glyph = STEP_ARROW, size = 14,
        width = 14, height = 14, order = 10,
        binding = { active = down.can },
    }
    LC.widgets["companionPanel." .. prefix .. "Glyph"] = {
        tooltip = false,
        kind = "companionSprite", ["in"] = section, spriteCell = glyphCell, tone = "text.muted",
        width = 11, height = 11, order = 20,
    }
    LC.widgets["companionPanel." .. prefix .. "Value"] = {
        tooltip = false,
        kind = "label", role = "Text", ["in"] = section, font = "small",
        text = "", justifyH = "CENTER",
        width = "fill", height = 14, order = 30,
        binding = { text = valueBinding },
    }
    LC.widgets["companionPanel." .. prefix .. "Up"] = {
        tooltip = { recipe = up.recipe },
        kind = "iconToggle", ["in"] = section, glyph = STEP_ARROW, size = 14,
        rotateActive = math.pi, rotateInactive = math.pi,
        width = 14, height = 14, order = 40,
        binding = { active = up.can },
    }
end
_stepper("companion.sizeStepper", "size", "tileSize", "companion.tileSize",
    { recipe = "CompanionTileSmaller", can = "companion.canShrinkTile" },
    { recipe = "CompanionTileBigger",  can = "companion.canGrowTile" })
_stepper("companion.colsStepper", "cols", "columns", "companion.columnsText",
    { recipe = "CompanionColsFewer", can = "companion.canFewerColumns" },
    { recipe = "CompanionColsMore",  can = "companion.canMoreColumns" })

-- ===== Widgets -- mode rail ==================================================
-- Each button binds active to companion.isMode_<key>. Clicks -> COMPANION_SET_MODE.
local RAIL = {
    { value = "catalog",     label = "Categories",  recipe = "CompanionCatalog" },   -- top of the rail; "Categories", not Blizzard's shop word "Catalog" (owner 11-08)
    { value = "styles",      label = "Styles",      recipe = "CompanionStyles" },
    { value = "rooms",       label = "Designs",     recipe = "CompanionRooms" },
    { value = "snapshots",   label = "Placed",      recipe = "CompanionSnapshots" },
    { value = "themes",      label = "Themes",      recipe = "CompanionThemes" },
    { value = "collections", label = "Collections", recipe = "CompanionCollections" },
    { value = "recent",      label = "Recent",      recipe = "CompanionRecent" },
}
for i, m in ipairs(RAIL) do
    LC.widgets["companionPanel.rail_" .. m.value] = {
        tooltip = { recipe = m.recipe },
        kind = "companionRailButton", ["in"] = "companion.rail",
        spriteCell = m.value, label = m.label,
        width = COMP.RAIL_BUTTON, height = COMP.RAIL_BUTTON_H, order = i,
        binding = { active = "companion.isMode_" .. m.value },
    }
end

-- ===== Widgets -- grid heading ===============================================

LC.widgets["companionPanel.listPrev"] = {
    tooltip = { recipe = "CompanionListPrev" },
    kind = "iconToggle", ["in"] = "companion.gridHead", glyph = STEP_ARROW, size = 16,
    width = 16, height = 16, order = 10,
    visible = "companion.hasListSteps",
    binding = { active = "companion.hasListSteps" },
}
LC.widgets["companionPanel.picker"] = {
    tooltip = { recipe = "CompanionPicker" },
    kind = "companionPicker", ["in"] = "companion.gridHead",
    width = "fill", height = 22, order = 20,
    binding = { row = "companion.pickedRow", open = "companion.pickerOpen", hasLists = "companion.hasLists" },
}
LC.widgets["companionPanel.listNext"] = {
    tooltip = { recipe = "CompanionListNext" },
    kind = "iconToggle", ["in"] = "companion.gridHead", glyph = STEP_ARROW, size = 16,
    rotateActive = math.pi, rotateInactive = math.pi,
    width = 16, height = 16, order = 30,
    visible = "companion.hasListSteps",
    binding = { active = "companion.hasListSteps" },
}
LC.widgets["companionPanel.gridTotal"] = {
    tooltip = false,
    kind = "label", role = "Text", ["in"] = "companion.gridHead", font = "small",
    text = "", justifyH = "RIGHT",
    width = COMP.TOTAL_WIDTH, height = 14, order = 40,
    binding = { text = "companion.gridTotal" },
}

-- ===== Widgets -- grid body ==================================================
-- Decor grid: companionGridCell click -> C_HousingBasicMode.StartPlacingNewDecor.
-- Tile size and column count are live bindings (saved settings).
LC.widgets["companionPanel.grid"] = {
    tooltip = false,
    kind = "cardGrid", ["in"] = "companion.gridWell",
    binding = { items = "companion.gridItems", cellSize = "companion.tilePx", columns = "companion.columns" },
    cellKind    = "companionGridCell",
    fixedGutter = true,               -- exact columns: the bar must never change the grid's width
    cellSize    = COMP.TILE_PX.L,     -- replaced by the tilePx binding on the first push
    cellSpacing = COMP.TILE_GAP,
    rowSpacing  = COMP.TILE_GAP,
    iconInset   = COMP.ICON_INSET,
    order = 10,
}
-- The picker's list: Blizzard's categories / collections / cost buckets / recent sessions. Store is the
-- selection SSoT (no SelectionBehavior); picking a row closes the picker.
LC.widgets["companionPanel.sidebar"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "companion.flyout",
    binding = "companion.sidebarRows",
    rowKind = "companionSidebarRow",
    spacing = 1,
    order = 10,
}

-- ===== Widgets -- recent-placements panel ===================================
-- Label + horizontal filmstrip (newest-left).
LC.widgets["companionRecentPanel.label"] = {
    tooltip = false,
    kind = "label", role = "TextMuted", ["in"] = "companionRecent.labelRow", font = "small",
    text = "locale:COMP_RECENT_PLACEMENTS_LABEL", justifyH = "LEFT",
    width = "fill", height = 12, order = 10,
}
LC.widgets["companionRecentPanel.strip"] = {
    tooltip = false,
    kind = "filmstrip", ["in"] = "companionRecent.strip",
    binding = "companion.recentStrip",
    cellKind    = "companionGridCell",
    cellSize    = 56,
    cellSpacing = 5,
    iconInset   = COMP.ICON_INSET,
    order = 10,
}

-- ===== Satellite window (HDG-ADR-025 step 5) ===============================
-- `lazy` -> CreateAll skips it; module calls EnsureCreated on editor open.
-- `parent` -> nests under HouseEditorFrame (cascade show/hide).
-- `shown` -> COMPANION_TOGGLE; position persists via COMPANION_SET_POSITION.
LC.windows.companion = {
    lazy   = true,
    parent = function() return _G.HouseEditorFrame end,
    slots  = { fill = "companion" },
    shown  = "companion.windowShown",
    position = {
        binding   = "companion.windowPosition",
        setAction = "COMPANION_SET_POSITION",
        default   = { x = 80, y = -120 },
        movable   = true,
    },
}
