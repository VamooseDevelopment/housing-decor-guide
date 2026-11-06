-- HDGR_LayoutConfig_Lumber.lua
-- ============================================================================
-- Lumber Tracker standalone floating window (HDG.Window).
-- Layout: header / radar (200px circular, collapsible) / tracking / counter / action bar.
-- dynamicRows collapses the radar row when radarCollapsed; tracking row when no session.
--
--   lumberPanel + lumberRadarPanel + lumberTrackingPanel +
--   lumberCounterPanel + lumberActionPanel

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================
LC.window.views.lumberWindow = {
    controllers = { "lumber" },
    standalone     = true,                   -- standalone (HDG.Window) view, not main-window tab
    width          = "auto",
    height         = "auto",
    -- 300 holds the header: icon, title, four 20px buttons and the X at md gaps leave
    -- the title 130px, its room before the settings cog joined the row.
    columns        = { 300 },
    -- 5 rows: header / radar(210, collapsible) / tracking(38, hides when no session) / counter / action.
    rows           = { 28, 210, 38, 280, 24 },
    dynamicRows    = "lumber.dynamicRows",
    cells          = {
        header   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        radar    = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
        tracking = { col = 1, row = 3, colSpan = 1, rowSpan = 1 },
        counter  = { col = 1, row = 4, colSpan = 1, rowSpan = 1 },
        action   = { col = 1, row = 5, colSpan = 1, rowSpan = 1 },
    },
}

-- dynamicRows selectors in HDGR_Selectors_Lumber.lua (loads before LayoutConfig files).

-- ===== Panels ================================================================
LC.panels.lumberPanel = {
    kind = "panel",
    cell = { lumberWindow = "header" },   -- panel anchors at the top cell; sections fill the rest via cells map below
    visibleInViews = { "lumberWindow" },
    slots = {
        header = {
            height = 28, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}

-- Body cells get own panels for independent rendering.
LC.panels.lumberRadarPanel = {
    kind = "panel",
    cell = { lumberWindow = "radar" },
    visibleInViews = { "lumberWindow" },
    visible = "lumber.radarShouldRender",   -- hides when collapsed
}

LC.panels.lumberTrackingPanel = {
    kind = "panel",
    cell = { lumberWindow = "tracking" },
    visibleInViews = { "lumberWindow" },
}

LC.panels.lumberCounterPanel = {
    kind = "panel",
    cell = { lumberWindow = "counter" },
    visibleInViews = { "lumberWindow" },
}

LC.panels.lumberActionPanel = {
    kind = "panel",
    cell = { lumberWindow = "action" },
    visibleInViews = { "lumberWindow" },
}

-- ===== Sections ==============================================================

LC.sections["lumber.tracking.body"] = {
    ["in"] = "lumberTrackingPanel",
    layout = "vertical",
    padding = { top = 4, right = "md", bottom = 4, left = "md" },
    gap = "xs",
    order = 10,
}

LC.sections["lumber.counter.body"] = {
    ["in"] = "lumberCounterPanel",
    layout = "vertical",
    padding = "sm",
    gap = "xs",
    order = 10,
    chrome = "inset",   -- recessed well for the counter scrollbox
}

LC.sections["lumber.action.bar"] = {
    ["in"] = "lumberActionPanel",
    layout = "horizontal",
    padding = { top = 2, right = "md", bottom = 2, left = "md" },
    gap = "md",
    order = 10,
}

-- ===== Header widgets ========================================================
-- Lumber glyph, left of the title (same atlas the Alts tab uses).
LC.widgets["lumberPanel.titleIcon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "lumberPanel", slot = "header",
    atlas = "Lumber_Tracking",
    width = 18, height = 18, order = 5,
}
-- The title takes the row's slack and cuts with "..." when a translation is longer
-- than that ("Rastreador de Madeira"), so the buttons and the X never leave the window.
LC.widgets["lumberPanel.title"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "lumberPanel", slot = "header",
    text = "locale:LUM_TITLE", font = "heading",
    height = 18, width = "fill", wrap = false, order = 10,
}
-- Zone Map: opens/closes the Blizzard zone map (BattlefieldMap) for the current area.
LC.widgets["lumberPanel.zoneMapBtn"] = {
    tooltip = { recipe = "ZoneMapOpen" },
    kind = "button", ["in"] = "lumberPanel", slot = "header",
    normalAtlas    = "map-icon_bullletinboard-default-minimap",
    highlightAtlas = "map-icon_bullletinboard-highlight-minimap",
    size = 20, width = 20, height = 20, order = 80,
}
-- Minimize toggle: collapses counter + action bar to just the header. Always available
-- while the window is open (not session-gated -- players review totals out of session too).
-- Glyph rotates UP (rows shown) / DOWN (hidden). NOTE: rotation signs assume atlas points left;
-- flip rotateActive/Inactive if up/down read reversed in-game.
LC.widgets["lumberPanel.listToggle"] = {
    tooltip = false,
    kind = "iconToggle", ["in"] = "lumberPanel", slot = "header",
    glyph = "wowlabs-spectatecycling-arrowleft",   -- left-pointing arrow; rotated up (rows shown) / down (hidden)
    size = 20,
    dimWhenInactive = false,
    rotateActive    = -math.pi / 2,   -- rows shown  -> UP   (left-facing rotated CW 90deg)
    rotateInactive  =  math.pi / 2,   -- rows hidden -> DOWN
    width = 20, height = 20, order = 85,
    binding = { active = "lumber.rowsShown" },
}
-- Radar toggle: bright when shown, dimmed when collapsed.
LC.widgets["lumberPanel.collapseToggle"] = {
    tooltip = false,
    kind = "iconToggle", ["in"] = "lumberPanel", slot = "header",
    glyph = "Professions-Specialization-Node-ChoiceGlow",
    size = 20,
    width = 20, height = 20, order = 90,
    binding = { active = "lumber.radarShouldRender" },
}
-- Settings cog (owner 2026-11-02, as the vendor sidebar's): Helpers > Lumber.
LC.widgets["lumberPanel.settings"] = {
    tooltip = { recipe = "SettingsCogLumber" },
    kind = "button", ["in"] = "lumberPanel", slot = "header",
    normalAtlas = "GM-icon-settings", highlightAtlas = "GM-icon-settings-hover",
    width = 20, height = 20, size = 20, order = 92,
}
LC.widgets["lumberPanel.close"] = {
    tooltip = false,
    kind = "button", ["in"] = "lumberPanel", slot = "header", font = "button",
    text = "X",
    width = 24, height = 20, order = 95, variant = "tertiary",
    textTone = "error",
}

-- ===== Tracking panel widgets ================================================
-- Line 1 (lumber+zone) + line 2 (duration+rate+total). Row is 0px when no session.
LC.widgets["lumberTrackingPanel.line1"] = {
    tooltip = false,
    kind = "label", ["in"] = "lumber.tracking.body", font = "subheading",
    text = "", width = "fill", height = 14, order = 10,
    binding = "lumber.trackingPanelLine1",
    visible = "lumber.trackingShouldRender",   -- leave layout when no session (row is 0px then)
}
LC.widgets["lumberTrackingPanel.line2"] = {
    tooltip = false,
    kind = "label", ["in"] = "lumber.tracking.body", font = "small",
    text = "", width = "fill", height = 12, order = 20,
    binding = "lumber.trackingPanelLine2",
    visible = "lumber.trackingShouldRender",   -- leave layout when no session (row is 0px then)
}

-- ===== Counter scrollbox =====================================================
LC.widgets["lumberCounterPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "lumber.counter.body",
    binding = "lumber.counterRows",
    rowKind = "lumberCounterRow",
    spacing = 1,
    order = 10,
}

-- ===== Radar widget ==========================================================
-- Visibility piggybacks on the panel; radar paint stops when collapsed.
LC.widgets["lumberRadarPanel.radar"] = {
    tooltip = false,
    kind = "lumberRadar", ["in"] = "lumberRadarPanel",
    binding = { blips = "lumber.blipsForRadar", scale = "lumber.radarScale" },
    width = 200, height = 200, order = 10,
}

-- ===== Action bar widgets ====================================================
-- Goal toggle (left) + spacer + End Session. End Session finalizes but keeps window open; [X] dismisses.
LC.widgets["lumberActionPanel.goalToggle"] = {
    tooltip = { recipe = "LumberGoal" },
    kind = "checkbox", ["in"] = "lumber.action.bar", font = "small",
    text = "locale:LUM_GOAL_TOGGLE", width = "auto", height = 20, order = 5,
    binding = { checked = "lumber.goalIsQueue" },
}
LC.widgets["lumberActionPanel.spacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "lumber.action.bar",
    width = "fill", height = 18, order = 10,
}
LC.widgets["lumberActionPanel.endSession"] = {
    tooltip = false,
    kind = "button", ["in"] = "lumber.action.bar", font = "small",
    text = "locale:LUM_END_SESSION", width = "auto", height = 20, order = 20, variant = "tertiary",
}

-- ===== Satellite window (HDG-ADR-025 step 5) ============================
-- Floating window. slots.fill=lumberWindow; shown=lumber.windowVisible; position persists.
LC.windows.lumberTracker = {
    slots    = { fill = "lumberWindow" },
    shown    = "lumber.windowVisible",
    position = {
        binding   = "lumber.windowPosition",
        setAction = "LUMBER_WINDOW_POSITION_SET",
        default   = { x = 100, y = -150 },
        movable   = true,
    },
}
