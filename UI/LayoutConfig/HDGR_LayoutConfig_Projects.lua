-- HDGR_LayoutConfig_Projects.lua
-- ============================================================================
-- Per-tab LayoutConfig for the Projects feature.
--   projectsLanding   -- dashboard (capture CTA or house summary + room lists)
--   projectsArchitect -- blueprint canvas (budget strip + floor tabs + canvas + detail rail)
--   projectsLayouts   -- browse / preview / share saved build layouts (versions)
--   projectsPicker    -- decor picker (category rail + list + 3D preview)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== Views =================================================================

LC.window.views.projectsLanding = {
    controllers = { "projects" },
    width    = "auto",
    height   = "auto",
    columns  = { 760 },
    rows     = { 600 },
    cells    = { body = { col = 1, row = 1, colSpan = 1, rowSpan = 1 } },
}

-- Architect: picker | canvas | detail (col 3 dropped when no room selected, HouseTab pattern).
LC.window.views.projectsArchitect = {
    controllers = { "projects" },
    width          = "auto",
    height         = "auto",
    columns        = { 170, 620 },         -- fallback; projects.architectColumns takes over
    dynamicColumns = "projects.architectColumns",
    rows           = { 30, 28, 542 },
    cells    = {
        bar    = { col = 1, row = 1, colSpan = 3, rowSpan = 1 },
        nav    = { col = 1, row = 2, colSpan = 3, rowSpan = 1 },
        picker = { col = 1, row = 3, colSpan = 1, rowSpan = 1 },
        canvas = { col = 2, row = 3, colSpan = 1, rowSpan = 1 },
        detail = { col = 3, row = 3, colSpan = 1, rowSpan = 1 },
    },
}

-- Layouts: left scrollable version list | right detail (header + preview + stats).
-- Columns {280, 470}; right column rows {34, 490, 110} = header | preview | stats.
LC.window.views.projectsLayouts = {
    controllers = { "layouts" },
    width    = "auto",
    height   = "auto",
    columns  = { 280, 470 },
    rows     = { 600 },
    cells    = {
        list   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        detail = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- Decor picker: category rail | catalog list | 3D preview. Opened from "+ Add decor".
LC.window.views.projectsPicker = {
    controllers = { "projects" },
    width    = "auto",
    height   = "auto",
    columns  = { 44, 440, 320 },   -- category rail | decor list | 3D preview
    rows     = { 600 },
    cells    = {
        rail    = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        list    = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
        preview = { col = 3, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- Help: the workflow cycle diagram + per-stage detail. Opened by the Help!
-- buttons (landing header + architect nav); Back returns via helpReturn.
LC.window.views.projectsHelp = {
    controllers = { "projects" },
    width    = "auto",
    height   = "auto",
    columns  = { 760 },
    rows     = { 600 },
    cells    = { body = { col = 1, row = 1, colSpan = 1, rowSpan = 1 } },
}

-- ===== Panels ================================================================

LC.panels.projectsLandingPanel = {
    kind = "panel",
    cell = { projectsLanding = "body" },
    visibleInViews = { "projectsLanding" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

LC.panels.projectsBarPanel = {
    kind = "panel",
    cell = { projectsArchitect = "bar" },
    visibleInViews = { "projectsArchitect" },
    slots = {
        body = { layout = "horizontal", gap = "md", padding = { top = 2, right = "lg", bottom = 2, left = "lg" } },
    },
}
LC.panels.projectsNavPanel = {
    kind = "panel",
    cell = { projectsArchitect = "nav" },
    visibleInViews = { "projectsArchitect" },
    slots = {
        body = { layout = "horizontal", gap = "sm", padding = { top = 1, right = "lg", bottom = 1, left = "lg" } },
    },
}
-- Picker panel: room palette + plan status footer.
LC.panels.projectsPickerPanel = {
    kind = "panel",
    cell = { projectsArchitect = "picker" },
    visibleInViews = { "projectsArchitect" },
    slots = {
        header = { height = 30, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "md", bottom = 0, left = "md" }, chrome = "PanelHeader" },
        body   = { layout = "vertical", gap = "sm", padding = "md" },
    },
}
LC.panels.projectsCanvasPanel = {
    kind = "panel",
    cell = { projectsArchitect = "canvas" },
    visibleInViews = { "projectsArchitect" },
}
-- Detail (right rail): crate management for the selected room.
LC.panels.projectsDetailPanel = {
    kind = "panel",
    cell = { projectsArchitect = "detail" },
    visibleInViews = { "projectsArchitect" },
    visible = "projects.sidePanelOpen",
    slots = {
        header = { height = 30, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" }, chrome = "PanelHeader" },
        body   = { layout = "vertical", gap = "sm", padding = "lg" },
    },
}

-- Layouts panels.
LC.panels.projectsLayoutsListPanel = {
    kind = "panel",
    cell = { projectsLayouts = "list" },
    visibleInViews = { "projectsLayouts" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" },
            chrome = "PanelHeader",
        },
        body = { layout = "vertical", gap = "sm", padding = "lg" },
    },
}
-- Right detail: inner vertical layout for header strip | preview | stats.
LC.panels.projectsLayoutsDetailPanel = {
    kind = "panel",
    cell = { projectsLayouts = "detail" },
    visibleInViews = { "projectsLayouts" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" },
            chrome = "PanelHeader",
        },
        body   = { layout = "vertical", gap = "sm", padding = "lg" },
    },
}

-- Picker panels.
-- Category rail: skin="Raised" lifts the rail off the surrounding panels so it reads as nav.
LC.panels.projectsPickerRailPanel = {
    kind = "panel",
    skin = "Raised",
    cell = { projectsPicker = "rail" },
    visibleInViews = { "projectsPicker" },
    slots = {
        -- 1px L/R: 42px icons nearly fill the 44px column; buffer preferred over widening.
        body = { layout = "vertical", gap = 0, padding = { top = 4, right = 1, bottom = 4, left = 1 } },
    },
}
LC.panels.projectsPickerListPanel = {
    kind = "panel",
    cell = { projectsPicker = "list" },
    visibleInViews = { "projectsPicker" },
    slots = {
        header = { height = 34, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" }, chrome = "PanelHeader" },
        body   = { layout = "vertical", gap = "sm", padding = "lg" },
    },
}
LC.panels.projectsPickerPreviewPanel = {
    kind = "panel",
    cell = { projectsPicker = "preview" },
    visibleInViews = { "projectsPicker" },
    slots = {
        body = { layout = "vertical", gap = "sm", padding = "md" },
    },
}

LC.panels.projectsHelpPanel = {
    kind = "panel",
    cell = { projectsHelp = "body" },
    visibleInViews = { "projectsHelp" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
        body = { layout = "vertical", gap = "md", padding = "xl" },
    },
}

-- ===== Help widgets ==========================================================

LC.widgets["projectsHelpPanel.title"] = {
    tooltip = false, kind = "label", ["in"] = "projectsHelpPanel", slot = "header",
    text = "locale:PROJ_HELP_TITLE", font = "subheading", width = 300, height = 22, order = 10,
}
LC.widgets["projectsHelpPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "projectsHelpPanel", slot = "header",
    width = "fill", height = 14, order = 20,
}
LC.widgets["projectsHelpPanel.back"] = {
    tooltip = false, kind = "button", ["in"] = "projectsHelpPanel", slot = "header",
    font = "body", text = "locale:COMMON_BACK", width = 90, height = 22, order = 30,
    variant = "tertiary",
}
LC.widgets["projectsHelpPanel.flow"] = {
    tooltip = false, kind = "projectsHelpFlow", ["in"] = "projectsHelpPanel",
    binding = { model = "projects.helpModel" },
    width = "fill", height = 200, order = 10,
}
LC.widgets["projectsHelpPanel.tagline"] = {
    tooltip = false, kind = "label", ["in"] = "projectsHelpPanel",
    text = "locale:PROJ_HELP_TAGLINE", font = "caption", justifyH = "CENTER",
    width = "fill", height = 16, order = 20,
}
LC.widgets["projectsHelpPanel.stageTitle"] = {
    tooltip = false, kind = "label", ["in"] = "projectsHelpPanel",
    binding = "projects.helpStageTitle", font = "subheading", role = "TextHeading",
    width = "fill", height = 22, order = 30,
}
LC.widgets["projectsHelpPanel.stageBody"] = {
    tooltip = false, kind = "label", ["in"] = "projectsHelpPanel",
    binding = "projects.helpStageBody", font = "body", wrap = true,
    justifyH = "LEFT", justifyV = "TOP", width = "fill", height = "fill", order = 40,
}

-- ===== Landing widgets =======================================================

-- (No title label -- the nav already says Projects; header budget is tight.)
-- House switcher (same self-wired dropdown as the Architect bar). Orients the ledger.
LC.widgets["projectsLandingPanel.houseDropdown"] = {
    tooltip = false, kind = "dropdown", ["in"] = "projectsLandingPanel", slot = "header",
    binding   = { menu = "projects.houseMenuItems", current = "projects.activeHouseID" },
    dispatch  = { type = "PROJECTS_FOCUS_HOUSE", payloadKey = "houseID" },
    placeholder = "locale:PROJ_HOUSE_DROPDOWN_PLACEHOLDER", width = 200, height = 24, order = 6,
    visible = "projects.hasRooms",
}
LC.widgets["projectsLandingPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "projectsLandingPanel", slot = "header",
    width = "fill", height = 14, order = 8,
}
LC.widgets["projectsLandingPanel.openArchitect"] = {
    tooltip = false, kind = "button", ["in"] = "projectsLandingPanel", slot = "header",
    font = "body", text = "locale:PROJ_OPEN_ARCHITECT", width = 120, height = 22, order = 10,
    visible = "projects.hasRooms",
}
LC.widgets["projectsLandingPanel.newWhatIf"] = {
    tooltip = false, kind = "button", ["in"] = "projectsLandingPanel", slot = "header",
    font = "body", text = "locale:PROJ_NEW_WHATIF", width = 90, height = 22, order = 12,
    visible = "projects.hasRooms",
}
-- Standalone planning (Phase G): design a layout WITHOUT capturing a house first --
-- mocks up a from-scratch what-if (no live cap; the shopping list is "all to build").
LC.widgets["projectsLandingPanel.newDesign"] = {
    tooltip = false, kind = "button", ["in"] = "projectsLandingPanel", slot = "header",
    font = "body", text = "locale:PROJ_START_DESIGN", width = 120, height = 22, order = 22,
    visible = "projects.canStartDesign",   -- focused house has no layout yet (incl. a second house)
}
-- Help: ALWAYS visible (first-time users need it most -- it's the one header
-- control that isn't gated on having rooms).
LC.widgets["projectsLandingPanel.help"] = {
    tooltip = { recipe = "ProjectsHelp" }, kind = "button", ["in"] = "projectsLandingPanel", slot = "header",
    font = "body", text = "locale:PROJ_HELP_BUTTON", width = 60, height = 22, order = 26,
    variant = "tertiary", textTone = "error",   -- red Help!: if you need it, you're having an error
}
-- First-time CTA (no rooms captured): centered prompt.
LC.widgets["projectsLandingPanel.cta"] = {
    tooltip = false, kind = "label", ["in"] = "projectsLandingPanel",
    text = "locale:PROJ_NO_ROOMS_CTA",
    font = "body", width = "fill", height = 40, order = 10,
    visible = "projects.noRooms",
}
-- Two half-height boxes (fills split evenly), each with a fixed header band
-- ABOVE the box (doesn't scroll away) + its own action rail below.
LC.sections["projectsLandingPanel.roomsHeader"] = {
    ["in"] = "projectsLandingPanel", layout = "horizontal", chrome = "cardBorder",
    padding = { top = 2, right = "sm", bottom = 2, left = "sm" },
    height = 22, order = 18, visible = "projects.hasRooms",
}
LC.widgets["projectsLandingPanel.roomsHeaderLabel"] = {
    tooltip = false, kind = "label", ["in"] = "projectsLandingPanel.roomsHeader",
    binding = "projects.roomsHeaderText", font = "subheading", width = "fill", height = 18, order = 10,
}
-- Rooms: every persistent room. Click selects; the rail acts on the selection.
LC.widgets["projectsLandingPanel.roomsList"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsLandingPanel",
    binding = "projects.roomsRows", rowKind = "projectsLedgerRow",
    spacing = 2, order = 20, width = "fill", height = "fill",
    visible = "projects.hasRooms", selection = { deselectable = true },
}
LC.sections["projectsLandingPanel.roomsRail"] = {
    ["in"] = "projectsLandingPanel", layout = "horizontal",
    height = 24, gap = "sm", order = 22, visible = "projects.hasRooms",
}
LC.widgets["projectsLandingPanel.newRoom"] = {
    tooltip = { recipe = "ProjectsNewRoom" }, kind = "button",
    ["in"] = "projectsLandingPanel.roomsRail",
    font = "body", text = "locale:PROJ_NEW_ROOM", width = 100, height = 22, order = 10,
}
-- Maintenance ops (Rename / Duplicate / Delete) collapse behind a visible
-- overflow button -- one obvious click, never right-click (UI review verdict).
LC.widgets["projectsLandingPanel.roomMore"] = {
    tooltip = { recipe = "ProjectsRoomMore" }, kind = "button",
    ["in"] = "projectsLandingPanel.roomsRail",
    font = "body", text = "...", width = 36, height = 22, order = 20,
}
-- Primary action pinned RIGHT (spacer absorbs the slack).
LC.widgets["projectsLandingPanel.roomsRailSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "projectsLandingPanel.roomsRail",
    width = "fill", height = 4, order = 50,
}
LC.widgets["projectsLandingPanel.roomOpen"] = {
    tooltip = { recipe = "ProjectsOpenArchitect" }, kind = "button", ["in"] = "projectsLandingPanel.roomsRail",
    font = "body", text = "locale:PROJ_OPEN_IN_ARCHITECT", width = 130, height = 22, order = 60,
    binding = { enabled = "projects.landingRoomSelected" },
}
-- Sets: the library. Import is always live (a pasted code becomes a library set).
LC.sections["projectsLandingPanel.setsHeader"] = {
    ["in"] = "projectsLandingPanel", layout = "horizontal", chrome = "cardBorder",
    padding = { top = 2, right = "sm", bottom = 2, left = "sm" },
    height = 22, order = 28, visible = "projects.hasRooms",
}
LC.widgets["projectsLandingPanel.setsHeaderLabel"] = {
    tooltip = false, kind = "label", ["in"] = "projectsLandingPanel.setsHeader",
    binding = "projects.setsHeaderText", font = "subheading", width = "fill", height = 18, order = 10,
}
LC.widgets["projectsLandingPanel.setsList"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsLandingPanel",
    binding = "projects.setsRows", rowKind = "projectsLedgerRow",
    spacing = 2, order = 30, width = "fill", height = "fill",
    visible = "projects.hasRooms", selection = { deselectable = true },
}
LC.sections["projectsLandingPanel.setsRail"] = {
    ["in"] = "projectsLandingPanel", layout = "horizontal",
    height = 24, gap = "sm", order = 32, visible = "projects.hasRooms",
}
LC.widgets["projectsLandingPanel.newSet"] = {
    tooltip = { recipe = "ProjectsNewSet" }, kind = "button",
    ["in"] = "projectsLandingPanel.setsRail",
    font = "body", text = "locale:PROJ_NEW_SET", width = 90, height = 22, order = 5,
}
LC.widgets["projectsLandingPanel.importSet"] = {
    tooltip = { recipe = "ProjectsImportSet" }, kind = "button",
    ["in"] = "projectsLandingPanel.setsRail",
    font = "body", text = "locale:COMMON_IMPORT", width = 80, height = 22, order = 10,
}
-- Cross-section: equip the selected set into the selected room (the landing
-- is the one surface where both selections are visible at once).
LC.widgets["projectsLandingPanel.setEquip"] = {
    tooltip = { recipe = "ProjectsLandingEquip" }, kind = "button",
    ["in"] = "projectsLandingPanel.setsRail",
    font = "body", text = "locale:PROJ_EQUIP_TO_ROOM", width = 120, height = 22, order = 58,
    binding = { enabled = "projects.landingCanEquip" },
}
-- Maintenance ops (Rename / Export / Delete) behind the visible overflow.
LC.widgets["projectsLandingPanel.setMore"] = {
    tooltip = { recipe = "ProjectsSetMore" }, kind = "button",
    ["in"] = "projectsLandingPanel.setsRail",
    font = "body", text = "...", width = 36, height = 22, order = 30,
}
-- Primary action pinned RIGHT (spacer absorbs the slack).
LC.widgets["projectsLandingPanel.setsRailSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "projectsLandingPanel.setsRail",
    width = "fill", height = 4, order = 55,
}
LC.widgets["projectsLandingPanel.setEdit"] = {
    tooltip = false, kind = "button", ["in"] = "projectsLandingPanel.setsRail",
    font = "body", text = "locale:PROJ_EDIT_BTN", width = 90, height = 22, order = 60,
    binding = { enabled = "projects.landingSetSelected" },
}

-- ===== Architect widgets =====================================================

-- Bar: house dropdown (left) + spacer + budget text + progress (right).
-- The dropdown lists ALL owned houses + switches which one the Architect edits
-- (self-wired via the binding + dispatch shortcut, like the Config theme picker).
LC.widgets["projectsBarPanel.houseDropdown"] = {
    tooltip = false, kind = "dropdown", ["in"] = "projectsBarPanel",
    binding   = { menu = "projects.houseMenuItems", current = "projects.activeHouseID" },
    dispatch  = { type = "PROJECTS_FOCUS_HOUSE", payloadKey = "houseID" },
    placeholder = "locale:PROJ_HOUSE_DROPDOWN_PLACEHOLDER", width = 220, height = 25, order = 10,
}
LC.widgets["projectsBarPanel.spacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "projectsBarPanel",
    width = "fill", height = 6, order = 20,
}
-- Room placement budget: planned weight vs live cap. Left of decor budget.
LC.widgets["projectsBarPanel.roomBudgetText"] = {
    tooltip = false, kind = "label", ["in"] = "projectsBarPanel",
    binding = "projects.roomBudgetText", font = "caption", height = 16, width = "auto", order = 24,
}
LC.widgets["projectsBarPanel.roomBudgetBar"] = {
    tooltip = false, kind = "progressbar", ["in"] = "projectsBarPanel",
    binding = { progress = "projects.roomBudgetProgress" }, width = 90, height = 8, order = 26,
}
LC.widgets["projectsBarPanel.budgetText"] = {
    tooltip = false, kind = "label", ["in"] = "projectsBarPanel",
    binding = "projects.budgetText", font = "caption", height = 16, width = "auto", order = 30,
}
LC.widgets["projectsBarPanel.budgetBar"] = {
    tooltip = false, kind = "progressbar", ["in"] = "projectsBarPanel",
    binding = { progress = "projects.budgetProgress" }, width = 120, height = 8, order = 40,
}
-- Mouse-action hints: right of decor budget (breadcrumb | rooms | decor | hints).
LC.widgets["projectsBarPanel.clickHints"] = {
    tooltip = false,   -- self-owned tooltip composed from leftText/rightText
    kind = "clickHints", ["in"] = "projectsBarPanel",
    leftText  = "locale:PROJ_CANVAS_LEFT_HINT",
    rightText = "locale:PROJ_CANVAS_RIGHT_HINT",
    title     = "locale:PROJ_CANVAS_TITLE",
    width = 34, height = 16, order = 50,
}

-- Nav: version switcher + floor tabs + capture-all + dashboard.
-- (House switching lives in the bar dropdown -- projectsBarPanel.houseDropdown.)
-- Version switcher: opens menu to switch / branch / delete house versions.
LC.widgets["projectsNavPanel.versionMenu"] = {
    tooltip = false, kind = "button", ["in"] = "projectsNavPanel",
    font = "body", binding = { text = "projects.activeVersionLabel" },
    width = 150, height = 22, order = 5,
}
LC.widgets["projectsNavPanel.floors"] = {
    tooltip = false, kind = "chipStrip", ["in"] = "projectsNavPanel",
    binding = "projects.floorTabs", cellKind = "projectsFloorChip",
    width = "fill", height = "fill", order = 10,
}
-- What-if floor controls (what-if mode only, max 3 floors). "+ Floor" is the
-- rightmost of the pair (order 18) so it stays put; "- Floor" (order 17) appears
-- to its LEFT when removable, instead of pushing "+ Floor" left.
LC.widgets["projectsNavPanel.addFloor"] = {
    tooltip = false, kind = "button", ["in"] = "projectsNavPanel",
    font = "body", text = "locale:PROJ_ADD_FLOOR", width = 72, height = 22, order = 18,
    visible = "projects.canAddWhatIfFloor",
}
LC.widgets["projectsNavPanel.removeFloor"] = {
    tooltip = false, kind = "button", ["in"] = "projectsNavPanel",
    font = "body", text = "locale:PROJ_REMOVE_FLOOR", width = 72, height = 22, order = 17,
    visible = "projects.canRemoveWhatIfFloor",
}
-- Plan <-> Section toggle. Labelled with the mode it switches TO.
LC.widgets["projectsNavPanel.viewMode"] = {
    tooltip = false, kind = "button", ["in"] = "projectsNavPanel",
    font = "body", binding = { text = "projects.canvasModeToggleLabel" },
    width = 92, height = 22, order = 19,
}
LC.widgets["projectsNavPanel.captureAll"] = {
    tooltip = { recipe = "ProjectsCaptureAll" }, kind = "button", ["in"] = "projectsNavPanel",
    font = "body", text = "locale:PROJ_CAPTURE_ALL_FLOORS", width = 130, height = 22, order = 20,
}
LC.widgets["projectsNavPanel.autoAssign"] = {
    tooltip = { recipe = "ProjectsAutoAssign" }, kind = "button", ["in"] = "projectsNavPanel",
    font = "body", text = "locale:PROJ_AUTO_ASSIGN", width = 92, height = 22, order = 21,
    visible = "projects.hasUnassignedRooms",
}
LC.widgets["projectsNavPanel.help"] = {
    tooltip = { recipe = "ProjectsHelp" }, kind = "button", ["in"] = "projectsNavPanel",
    font = "body", text = "locale:PROJ_HELP_BUTTON", width = 56, height = 22, order = 22,
    variant = "tertiary", textTone = "error",   -- red Help!: if you need it, you're having an error
}
-- (Dashboard button dropped 2026-06-07 -- the "Projects" parent nav node already
--  navigates to projectsLanding, so the button was a redundant second route.)

-- Canvas: blueprint widget (auto-fit tiling in controller).
LC.widgets["projectsCanvasPanel.canvas"] = {
    tooltip = false, kind = "projectsCanvas", ["in"] = "projectsCanvasPanel",
    binding = { model = "projects.canvasModel" }, width = "fill", height = "fill", order = 10,
    visible = "projects.canvasIsPlan",
}
-- Section: the same cell, the whole house at once (isometric, read-only). The
-- visibility cascade drops whichever mode is off before the solver runs, so the
-- two never fight over the cell.
LC.widgets["projectsCanvasPanel.section"] = {
    tooltip = false, kind = "projectsSection", ["in"] = "projectsCanvasPanel",
    binding = { model = "projects.sectionModel" }, width = "fill", height = "fill", order = 10,
    visible = "projects.canvasIsSection",
}

-- Detail panel: selected room title.
LC.widgets["projectsDetailPanel.title"] = {
    tooltip = false, kind = "label", ["in"] = "projectsDetailPanel", slot = "header",
    text = "locale:PROJ_DETAIL_ROOM_TITLE", font = "heading", height = 18, width = "fill", order = 5,
}
-- Picker (left rail): room palette (what-if) or Live-mode CTA (stock).
-- Placing rooms only makes sense on a what-if; editing Live gets wiped on recapture.
LC.widgets["projectsPickerPanel.title"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPanel", slot = "header",
    text = "locale:PROJ_PICKER_ROOMS_TITLE", font = "heading", height = 18, width = "fill", order = 5,
}
LC.widgets["projectsPickerPanel.hint"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPanel",
    text = "locale:PROJ_PICKER_WHATIF_HINT", font = "caption", width = "fill", height = 16, order = 2,
    visible = "projects.isWhatIfMode",
}
-- Stock (Live) mode: palette locked; branch a what-if to redesign.
LC.widgets["projectsPickerPanel.stockHint"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPanel",
    text = "locale:PROJ_PICKER_STOCK_HINT",
    font = "caption", width = "fill", height = 96, order = 3, visible = "projects.isStockMode",
}
LC.widgets["projectsPickerPanel.newWhatIf"] = {
    tooltip = false, kind = "button", ["in"] = "projectsPickerPanel",
    font = "body", text = "locale:PROJ_NEW_WHATIF_PICKER", width = "fill", height = 24, order = 4,
    visible = "projects.isStockMode",
}
LC.widgets["projectsPickerPanel.list"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsPickerPanel",
    binding = "projects.paletteShapes", rowKind = "projectsRoomListRow",
    spacing = 2, width = "fill", height = "fill", order = 10,
    visible = "projects.isWhatIfMode",
}
LC.widgets["projectsPickerPanel.planValidation"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPanel",
    binding = "projects.planValidationSummary", font = "caption", width = "fill", height = 28, order = 20,
}
-- Room shopping list: what-if vs reality delta. Hidden when the active version is Live.
LC.widgets["projectsPickerPanel.shoppingLabel"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPanel",
    text = "locale:PROJ_SHOPPING_LIST_LABEL", font = "caption", width = "fill", height = 16, order = 22,
    visible = "projects.hasShoppingList",
}
LC.widgets["projectsPickerPanel.shoppingList"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsPickerPanel",
    binding = "projects.shoppingListRows", rowKind = "projectsShoppingRow",
    spacing = 1, width = "fill", height = 110, order = 24,
    visible = "projects.hasShoppingList",
}

-- Detail (right rail): two-state curation panel (build plan 2.2).
-- Selected UNASSIGNED slot -> "which room?" offer; selected ASSIGNED room ->
-- furnishings detail. Shared header (name/meta) serves both states.
LC.widgets["projectsDetailPanel.name"] = {
    tooltip = false, kind = "label", ["in"] = "projectsDetailPanel",
    binding = "projects.roomDetailName", font = "subheading", height = 20, width = "fill", order = 10,
    role = "TextHeading",   -- gold accent (same as the Layouts detail header)
}
LC.widgets["projectsDetailPanel.meta"] = {
    tooltip = false, kind = "label", ["in"] = "projectsDetailPanel",
    binding = "projects.roomDetailMeta", font = "caption", height = 16, width = "fill", order = 20,
}
-- Connect-hint is a ROOM-state note (meaningless against a bare slot).
LC.widgets["projectsDetailPanel.note"] = {
    tooltip = false, kind = "label", ["in"] = "projectsDetailPanel",
    text = "locale:PROJ_ROOM_CONNECT_HINT",
    font = "caption", width = "fill", height = 28, order = 30, visible = "projects.roomPanelOpen",
}

-- ----- State U: unassigned slot -> "which room?" -----------------------------
LC.widgets["projectsDetailPanel.assignHint"] = {
    tooltip = false, kind = "label", ["in"] = "projectsDetailPanel",
    text = "locale:PROJ_ASSIGN_HINT", font = "caption", width = "fill", height = 28, order = 34,
    visible = "projects.slotOfferHasRows",
}
LC.widgets["projectsDetailPanel.assignEmpty"] = {
    tooltip = false, kind = "label", ["in"] = "projectsDetailPanel",
    text = "locale:PROJ_ASSIGN_EMPTY", font = "caption", width = "fill", height = 28, order = 35,
    visible = "projects.slotOfferIsEmpty",
}
LC.widgets["projectsDetailPanel.assignList"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsDetailPanel",
    binding = "projects.slotAssignOffer", rowKind = "projectsAssignRow",
    spacing = 2, width = "fill", height = "fill", order = 36,
    visible = "projects.slotPanelOpen", selection = { deselectable = true },
}
LC.widgets["projectsDetailPanel.newRoomHere"] = {
    tooltip = { recipe = "ProjectsNewRoomHere" }, kind = "button", ["in"] = "projectsDetailPanel",
    font = "body", text = "locale:PROJ_NEW_ROOM_HERE", width = "fill", height = 24, order = 38,
    visible = "projects.slotPanelOpen",
}

-- ----- State A: assigned room -> furnishings detail ---------------------------
LC.widgets["projectsDetailPanel.layoutsNotice"] = {
    tooltip = false, kind = "label", ["in"] = "projectsDetailPanel",
    binding = "projects.roomInLayoutsText", font = "caption", width = "fill", height = 24, order = 40,
    visible = "projects.roomPanelOpen",
}
-- Equip + Add decor share one horizontal row (saves 24px for the list fill).
LC.sections["projectsDetailPanel.roomActions"] = {
    ["in"] = "projectsDetailPanel", layout = "horizontal",
    height = 24, gap = "sm", order = 41, visible = "projects.roomPanelOpen",
}
LC.widgets["projectsDetailPanel.equipSet"] = {
    tooltip = { recipe = "ProjectsEquipSet" }, kind = "button", ["in"] = "projectsDetailPanel.roomActions",
    font = "body", text = "locale:PROJ_EQUIP_SET", width = 120, height = 24, order = 10,
    visible = "projects.roomPanelOpen",
}
LC.widgets["projectsDetailPanel.addDecor"] = {
    tooltip = false, kind = "button", ["in"] = "projectsDetailPanel.roomActions",
    font = "body", text = "locale:PROJ_ADD_DECOR", width = 120, height = 24, order = 20,
    visible = "projects.roomPanelOpen",
}
-- Export / Import in the header (fill title pushes them right).
LC.widgets["projectsDetailPanel.exportCrate"] = {
    tooltip = false, kind = "button", ["in"] = "projectsDetailPanel", slot = "header",
    font = "body", text = "locale:PROJ_EXPORT_BTN", width = 62, height = 22, order = 6,
    visible = "projects.crateDetailHasCrate",
}
-- (Import lives on the landing's Sets rail -- it creates a library set.)
-- Effective furnishings, grouped by set with provenance headers (Unequip on
-- library headers; steppers on the room's own pieces).
LC.widgets["projectsDetailPanel.crateList"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsDetailPanel",
    binding = "projects.roomFurnishingsRows", rowKind = "projectsFurnRow",
    spacing = 2, width = "fill", height = "fill", order = 50,
    visible = "projects.roomPanelOpen", selection = { deselectable = true },
}
-- (Swap room removed: remove-placement + the assign offer covers re-pointing
-- a spot, and the picker's "Make a copy" covers divergence. LAYOUT_SWAP_ROOM
-- stays as the engine behind FURN_ROOM_DUPLICATE's swap.)
-- Fork (shared designs only): this room becomes its own design; the other
-- rooms keep the original. Placement-scoped by construction.
LC.widgets["projectsDetailPanel.forkDesign"] = {
    tooltip = { recipe = "ProjectsForkDesign" }, kind = "button", ["in"] = "projectsDetailPanel",
    font = "body", text = "locale:PROJ_FORK_DESIGN", width = "fill", height = 24, order = 54,
    variant = "tertiary", visible = "projects.canForkSelection",
}
-- Unassign: clear this spot's room tag (the bare shape stays; the room persists).
LC.widgets["projectsDetailPanel.unassignRoom"] = {
    tooltip = { recipe = "ProjectsUnassign" }, kind = "button", ["in"] = "projectsDetailPanel",
    font = "body", text = "locale:PROJ_UNASSIGN", width = "fill", height = 24, order = 60,   -- ALWAYS the bottom button (owner call)
    variant = "tertiary", visible = "projects.roomPanelOpen",
}
-- Bottom action: promote the room's own pieces to a named library set.
LC.widgets["projectsDetailPanel.detachCrate"] = {
    tooltip = { recipe = "ProjectsDetachCrate" }, kind = "button", ["in"] = "projectsDetailPanel",
    font = "body", text = "locale:PROJ_DETACH_CRATE", width = "fill", height = 24, order = 56,
    variant = "tertiary", visible = "projects.crateDetailHasCrate",
}

-- ===== Layouts widgets =======================================================

-- Left list panel header: title + spacer + Import button.
LC.widgets["projectsLayoutsListPanel.title"] = {
    tooltip = false, kind = "label", ["in"] = "projectsLayoutsListPanel", slot = "header",
    text = "locale:PROJ_LAYOUTS_TITLE", font = "heading", height = 18, width = "auto", order = 5,
}
LC.widgets["projectsLayoutsListPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "projectsLayoutsListPanel", slot = "header",
    width = "fill", height = 14, order = 8,
}
LC.widgets["projectsLayoutsListPanel.importBtn"] = {
    tooltip = { recipe = "LayoutImport" }, kind = "button", ["in"] = "projectsLayoutsListPanel", slot = "header",
    font = "body", text = "locale:COMMON_IMPORT", width = 72, height = 22, order = 10,
}
-- Version list: house group headers interleaved with version rows (flat projection).
LC.widgets["projectsLayoutsListPanel.list"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsLayoutsListPanel",
    binding = "projects.layoutListRows", rowKind = "projectsLayoutGroupRow",
    spacing = 1, width = "fill", height = "fill", order = 20,
}

-- Right detail header: version name + LIVE/what-if badge (string selector).
-- Name FLEXES (width=fill, no spacer): a long custom layout name truncates
-- instead of over-speccing the header against the fixed-width CTA.
LC.widgets["projectsLayoutsDetailPanel.name"] = {
    tooltip = false, kind = "label", ["in"] = "projectsLayoutsDetailPanel", slot = "header",
    binding = "projects.layoutDetailHeader", font = "heading", height = 18, width = "fill", order = 5,
}
-- The CTA lives in the title bar (owner call, review: "Load in Architect up
-- in title"): selection-scoped primary action, same pattern as the landing
-- header. The bottom rail keeps the secondary verbs.
LC.widgets["projectsLayoutsDetailPanel.loadBtn"] = {
    tooltip = { recipe = "LayoutLoad" }, kind = "button", ["in"] = "projectsLayoutsDetailPanel", slot = "header",
    font = "body", text = "locale:PROJ_LOAD_IN_ARCHITECT", width = 140, height = 22, order = 10,
    visible = "projects.hasLayoutSelection",
}
-- Detail body: preview canvas (controller-managed), stats, action buttons.
-- Preview: a plain Frame the controller renders floors into.
LC.widgets["projectsLayoutsDetailPanel.preview"] = {
    tooltip = false, kind = "layoutPreview", ["in"] = "projectsLayoutsDetailPanel",
    binding = { model = "projects.layoutPreviewModel" },
    -- FLEX height: absorbs whatever's left after the fixed stats + action buttons,
    -- so the controls always sit inside the panel (a fixed 490 overflowed the body
    -- once the selection-gated buttons appeared -- the overspec check can't see
    -- conditionally-visible widgets, so flex is the robust fix).
    width = "fill", height = "fill", order = 10,
}
-- Stats line: Rooms / Floors / Budget (string selector).
LC.widgets["projectsLayoutsDetailPanel.stats"] = {
    tooltip = false, kind = "label", ["in"] = "projectsLayoutsDetailPanel",
    binding = "projects.layoutDetailStats", font = "caption", height = 16, width = "fill", order = 20,
}
-- One action rail (the CTA moved to the title bar): Export pairs with the
-- list header's Import; Rename/Duplicate/Delete follow.
LC.sections["projectsLayoutsDetailPanel.actions2"] = {
    ["in"] = "projectsLayoutsDetailPanel", layout = "horizontal",
    height = 22, gap = "sm", order = 32,
}
LC.widgets["projectsLayoutsDetailPanel.shareBtn"] = {
    tooltip = { recipe = "LayoutShare" }, kind = "button", ["in"] = "projectsLayoutsDetailPanel.actions2",
    font = "body", text = "locale:PROJ_SHARE_CODE", width = 80, height = 22, order = 5,
    visible = "projects.hasLayoutSelection",
}
LC.widgets["projectsLayoutsDetailPanel.renameBtn"] = {
    tooltip = false, kind = "button", ["in"] = "projectsLayoutsDetailPanel.actions2",
    font = "body", text = "locale:PROJ_RENAME_BTN", width = 80, height = 22, order = 10,
    visible = "projects.hasLayoutSelection",
}
LC.widgets["projectsLayoutsDetailPanel.duplicateBtn"] = {
    tooltip = { recipe = "LayoutDuplicate" }, kind = "button", ["in"] = "projectsLayoutsDetailPanel.actions2",
    font = "body", text = "locale:PROJ_DUPLICATE_BTN", width = 90, height = 22, order = 20,
    visible = "projects.hasLayoutSelection",
}
LC.widgets["projectsLayoutsDetailPanel.deleteBtn"] = {
    tooltip = false, kind = "button", ["in"] = "projectsLayoutsDetailPanel.actions2",
    font = "body", text = "locale:COMMON_DELETE", width = 80, height = 22, order = 30,
    visible = "projects.hasLayoutSelection",
}

-- ===== Picker widgets (Furnishings workspace -- Variant A) ===================
-- Source dropdown ("whose list") + search compose with the category rail
-- ("Blizzard's taxonomy"); card grid plans by gesture; right column = hover
-- 3D preview over the room's own pieces.
LC.widgets["projectsPickerListPanel.sourceDropdown"] = {
    tooltip = { recipe = "ProjectsPickerSource" }, kind = "dropdown",
    ["in"] = "projectsPickerListPanel", slot = "header",
    binding  = { menu = "projects.pickerSourceMenuItems", current = "projects.pickerSource" },
    dispatch = { type = "PROJECTS_PICKER_SET_SOURCE", payloadKey = "source" },
    placeholder = "locale:PROJ_PICKER_SOURCE_PLACEHOLDER", width = 220, height = 22, order = 5,
}
LC.widgets["projectsPickerListPanel.search"] = {
    tooltip = false, kind = "editbox", ["in"] = "projectsPickerListPanel", slot = "header",
    font = "body", width = "fill", height = 22, order = 10, multiline = false,
    placeholder = "locale:DECOR_SEARCH_PLACEHOLDER",
}
-- Gesture vocabulary via the click-glyph idiom (same as the Architect bar):
-- mouse-button atlases in the header, full wording on hover.
LC.widgets["projectsPickerListPanel.clickHints"] = {
    tooltip = false,   -- self-owned tooltip composed from leftText/rightText
    kind = "clickHints", ["in"] = "projectsPickerListPanel", slot = "header",
    leftText  = "locale:PROJ_PICKER_HINT_LEFT",
    rightText = "locale:PROJ_PICKER_HINT_RIGHT",
    shiftText = "locale:PROJ_PICKER_HINT_SHIFT",
    title     = "locale:PROJ_PICKER_HINT_TITLE",
    width = 34, height = 16, order = 15,
}
LC.widgets["projectsPickerListPanel.grid"] = {
    tooltip = false, kind = "cardGrid", ["in"] = "projectsPickerListPanel",
    binding = "projects.pickerResults", cellKind = "projectsPickerCard",
    cellSize = 80, order = 30, width = "fill", height = "fill",
}
-- 200px (not the mockup's 260): the room column below needs ~9 stepper rows
-- visible for a typically furnished room (UI review 16, MUST-FIX 1).
LC.widgets["projectsPickerPreviewPanel.preview"] = {
    tooltip = false, kind = "modelPreview", ["in"] = "projectsPickerPreviewPanel",
    binding = { itemID = "projects.pickerSelectedItemID" },
    width = "fill", height = 200, order = 10,
    showControls = true, bgTile = true, placeholder = "locale:DECOR_PREVIEW_PLACEHOLDER",
    sceneInsets = { top = 8, right = 8, bottom = 8, left = 8 },
    defaultSceneID = 859,   -- HOUSING_CATALOG_DECOR_MODELSCENEID_DEFAULT (12.0.5)
}
LC.widgets["projectsPickerPreviewPanel.hoverName"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPreviewPanel",
    binding = "projects.pickerHoverName", font = "subheading", width = "fill", height = 18, order = 12,
}
LC.widgets["projectsPickerPreviewPanel.hoverLine"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPreviewPanel",
    binding = "projects.pickerHoverLine", font = "caption", width = "fill", height = 14, order = 14,
}
-- Acquisition row (hovered UNOWNED decor): plan it, then go get it.
LC.sections["projectsPickerPreviewPanel.acquireRow"] = {
    ["in"] = "projectsPickerPreviewPanel", layout = "horizontal",
    height = 22, gap = "sm", order = 15, visible = "projects.pickerHoverUnowned",
}
LC.widgets["projectsPickerPreviewPanel.queueCraft"] = {
    tooltip = { recipe = "ProjectsQueueCraft" }, kind = "button",
    ["in"] = "projectsPickerPreviewPanel.acquireRow",
    font = "caption", text = "locale:PROJ_QUEUE_CRAFT", width = "fill", height = 20, order = 10,
    variant = "tertiary", visible = "projects.pickerHoverCraftable",
}
LC.widgets["projectsPickerPreviewPanel.addShopping"] = {
    tooltip = { recipe = "ProjectsAddShopping" }, kind = "button",
    ["in"] = "projectsPickerPreviewPanel.acquireRow",
    font = "caption", text = "locale:PROJ_ADD_SHOPPING", width = "fill", height = 20, order = 20,
    variant = "tertiary",
}

-- Shared-room scope indicator (TOP of the column -- review 15 follow-up):
-- visible only when the target room is in 2+ layouts; the copy button swaps
-- a layout-local copy in without leaving the picker.
LC.widgets["projectsPickerPreviewPanel.scopeLine"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPreviewPanel",
    binding = "projects.pickerScopeText", font = "caption", width = "fill", height = 14, order = 16,
    visible = "projects.pickerScopeShared",
}
LC.widgets["projectsPickerPreviewPanel.makeCopyHere"] = {
    tooltip = false, kind = "button", ["in"] = "projectsPickerPreviewPanel",
    font = "body", text = "locale:PROJ_MAKE_COPY_HERE", width = "fill", height = 20, order = 18,
    variant = "tertiary", visible = "projects.pickerScopeShared",
}
-- The right column is the TARGET set (a room's own pieces OR a library set
-- opened via the Rooms-list "Edit"): title + stepper rows + totals.
LC.widgets["projectsPickerPreviewPanel.roomTitle"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPreviewPanel",
    binding = "projects.pickerTargetTitle", font = "caption", width = "fill", height = 18, order = 20,
}
LC.widgets["projectsPickerPreviewPanel.equipSet"] = {
    tooltip = { recipe = "ProjectsEquipSet" }, kind = "button", ["in"] = "projectsPickerPreviewPanel",
    font = "body", text = "locale:PROJ_EQUIP_SET", width = "fill", height = 22, order = 24,
    visible = "projects.pickerTargetIsLocal",
}
LC.widgets["projectsPickerPreviewPanel.pieces"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "projectsPickerPreviewPanel",
    binding = "projects.pickerTargetRows", rowKind = "projectsFurnRow",
    spacing = 2, width = "fill", height = "fill", order = 30, selection = { deselectable = true },
}
LC.widgets["projectsPickerPreviewPanel.totals"] = {
    tooltip = false, kind = "label", ["in"] = "projectsPickerPreviewPanel",
    binding = "projects.pickerTargetTotals", font = "caption", width = "fill", height = 16, order = 40,
}
LC.widgets["projectsPickerPreviewPanel.saveAsSet"] = {
    tooltip = { recipe = "ProjectsSaveAsSet" }, kind = "button", ["in"] = "projectsPickerPreviewPanel",
    font = "body", text = "locale:PROJ_SAVE_AS_SET", width = "fill", height = 24, order = 50,
    visible = "projects.pickerTargetIsLocal",
}
LC.widgets["projectsPickerPreviewPanel.back"] = {
    tooltip = false, kind = "button", ["in"] = "projectsPickerPreviewPanel",
    font = "body", text = "locale:COMMON_BACK", width = "fill", height = 24, order = 60,
    variant = "tertiary",
}
-- Vertical category rail: in-situ category -> subcategory drill-down.
-- chipPadH=0 so 42px icon cells fit the 44px column without overflowing.
LC.widgets["projectsPickerRailPanel.rail"] = {
    tooltip = false, kind = "chipStrip", ["in"] = "projectsPickerRailPanel",
    binding = "projects.pickerRail", cellKind = "projectsRailIcon",
    orientation = "vertical",
    chipHeight = 42, chipMinWidth = 42, chipPadH = 0, horizontalSpacing = 2, verticalSpacing = 2,
    width = "fill", height = "fill", order = 10,
}
