-- HDGR_LayoutConfig_Companion.lua
-- ============================================================================
-- In-editor HouseEditor companion -- declarative satellite window.
-- Functionally the twin of the Styles tab (collection sidebar + decor card-grid).
--
-- `lazy` + `parent` resolver -> frame nests under HouseEditorFrame; editor-only
-- visibility falls out of the parent cascade for free.
--
--   +------------------------------------------------------------+
--   | [icon] Housing Decor Guide        [$] [I/O]           [X]   |  header slot ($ = budget atlas toggle)
--   +------------------------------------------------------------+
--   | [Your Styles][Shopping]...[Recent]       [search........]  |  toolbar (search flexes)
--   +------------+-----------------------------------------------+
--   | sidebar    |  decor grid (cardGrid, 5 wide)                |  split (fill)   } companionPanel
--   | scrollbox  |                                               |                 } (cell "body")
--   +============================================================+
--   | Recent placements                                          |   companionRecentPanel
--   | <[#][#][#][#][#][#][#][#] horizontal filmstrip, newest <-- |   (cell "recent",
--   +------------------------------------------------------------+    own panel/surface)
--
-- View: companion (standalone)
--   columns: { 720 }   rows: { 472 }   cells: body
--
-- Selectors reused (declared in UI/HDGR_Selectors_Companion.lua):
--   companion.windowShown / windowPosition  -- reconciler visibility + position
--   companion.isMode_<key>                   -- mode chip active state
--   companion.search / showCost / ioLabel    -- toolbar + header controls
--   companion.sidebarRows / gridItems / recentStrip  -- list content
-- Row/cell kinds:
--   companionSidebarRow  -- HDGR_Controller_Companion.lua
--   companionGridCell    -- Modules/HDGR_HouseEditorCompanion.lua (placement click)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.companion = {
    controllers = { "companion" },
    standalone = true,            -- HDG.Window floating frame; not a main-window tab
    width      = "auto",          -- 5 decor cards wide (HDG-like vertical layout; was 8)
    height     = "auto",          -- grid ~2 card-rows taller; recent strip is its own panel below
    columns    = { 525 },
    rows       = { 540, 92 },     -- main body panel, then the recent-placements panel
    cells      = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        recent = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
-- Body panel: window chrome in the header slot; toolbar + sidebar|grid split in the body.
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

LC.sections["companion.body"] = {
    ["in"]  = "companionPanel",
    layout  = "vertical",
    padding = "md",
    gap     = "sm",
    order   = 10,
}
-- Toolbar: mode chips (left) + slack + search (right).
LC.sections["companion.toolbar"] = {
    ["in"]  = "companion.body",
    layout  = "horizontal",
    height  = 24,
    gap     = "sm",
    order   = 10,
}
-- Body split: fill sidebar well + exact-fit grid well. The grid is fixed at
-- its 5-column content width (5 x 60 cards, 0 spacing, +6 scrollbar gutter,
-- +3 slack against UI-scale rounding so the 5th column can't wrap) and the
-- sidebar absorbs the leftover -- a fill grid left ~23 dead px on its right.
LC.sections["companion.split"] = {
    ["in"]  = "companion.body",
    layout  = "horizontal",
    gap     = "sm",
    order   = 20,
}
LC.sections["companion.sidebarWell"] = {
    ["in"]  = "companion.split",
    layout  = "fill",
    width   = "fill",
    order   = 10,
    chrome  = "inset",
}
LC.sections["companion.gridWell"] = {
    ["in"]  = "companion.split",
    layout  = "fill",
    width   = 309,                -- 5*60 + SCROLLBOX_SCROLLBAR_RESERVE(6) + 3
    order   = 20,
    chrome  = "inset",
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
-- Indoor/Outdoor 3-state cycle: label reflects the current filter.
-- Click -> COMPANION_CYCLE_IO (CompanionController).
LC.widgets["companionPanel.ioToggle"] = {
    tooltip = false,
    kind = "button", ["in"] = "companionPanel", slot = "header", font = "small",
    text = "", width = "auto", height = 20, order = 25, variant = "tertiary",
    binding = { text = "companion.ioLabel" },
}
LC.widgets["companionPanel.close"] = {
    tooltip = { recipe = "Close" },
    kind = "button", ["in"] = "companionPanel", slot = "header",
    width = 22, height = 22, order = 95,
    close = true, size = 22, iconSize = 14,
}

-- ===== Widgets -- toolbar (mode chips + search) =============================
-- Mode chips: each binds active to companion.isMode_<key>. Clicks -> COMPANION_SET_MODE.
local MODE_CHIPS = {
    { value = "styles",      label = "Your Styles", recipe = "CompanionStyles" },
    { value = "rooms",       label = "Designs",     recipe = "CompanionRooms" },
    { value = "snapshots",   label = "Placed",      recipe = "CompanionSnapshots" },
    { value = "themes",      label = "Themes",      recipe = "CompanionThemes" },
    { value = "collections", label = "Collections", recipe = "CompanionCollections" },
    { value = "recent",      label = "Recent",      recipe = "CompanionRecent" },
}
for i, c in ipairs(MODE_CHIPS) do
    LC.widgets["companionPanel.mode_" .. c.value] = {
        tooltip = { recipe = c.recipe },
        kind = "button", ["in"] = "companion.toolbar", font = "caption",
        text = c.label, width = "auto", height = 20, order = i, variant = "chip",
        binding = { active = "companion.isMode_" .. c.value },
    }
end
-- Search flexes to fill toolbar slack after the chips.
LC.widgets["companionPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "companion.toolbar", font = "small",
    height = 22, width = "fill", order = 60,
    placeholder = "locale:COMP_SEARCH_PLACEHOLDER",
    binding = { text = "companion.search" },
}

-- ===== Widgets -- body split ================================================
-- Sidebar: collections / cost buckets / recent. Store is selection SSoT (no SelectionBehavior).
LC.widgets["companionPanel.sidebar"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "companion.sidebarWell",
    binding = "companion.sidebarRows",
    rowKind = "companionSidebarRow",
    spacing = 1,
    order = 10,
}
-- Decor grid: companionGridCell click -> C_HousingBasicMode.StartPlacingNewDecor.
LC.widgets["companionPanel.grid"] = {
    tooltip = false,
    kind = "cardGrid", ["in"] = "companion.gridWell",
    binding = "companion.gridItems",
    cellKind    = "companionGridCell",
    cellSize    = 60,
    cellSpacing = 0,              -- cards flush; cell chrome is the separator
    rowSpacing  = 0,
    order = 10,
}

-- ===== Widgets -- recent-placements panel ===================================
-- Dim label + horizontal filmstrip (newest-left, 60px cells).
LC.widgets["companionRecentPanel.label"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "companionRecent.labelRow", font = "small",
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
