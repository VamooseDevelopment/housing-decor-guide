-- HDGR_LayoutConfig_DecorQuestTracker.lua
-- ============================================================================
-- The Quest Tracker: a floating window (HDG.Window) that follows what Track picked on the
-- Decor Quests tab (a decor, a campaign chapter or a campaign). Layout (the Full mockup, owner
-- 10-30): header (title, next steps, close) / body (the step to head for with its one button,
-- then under a rule the progress strip; rows from decorQuests.trackerRows) / buttons
-- (Details, Stop tracking; Close once it has ended). Compact (a Settings choice): the header
-- with its count, the step to head for and its place line, no buttons bar. dynamicRows sizes the header to its
-- title's lines and the body to its rows; while nothing is tracked only Details shows (review
-- G6: an empty tracker was a dead end).
-- Rows: HDGR_Controller_DecorQuestTracker.lua; selectors: HDGR_Selectors_DecorQuests.lua.

HDG = HDG or {}
local LC = HDG.LayoutConfig

LC.window.views.decorQuestTrackerWindow = {
    controllers = { "decorQuestTracker" },
    standalone  = true,
    width       = "auto",
    height      = "auto",
    columns     = { 320 },   -- 300 squeezed Stop tracking past its edge in game (10-28): three buttons sized to their text
    rows        = { 28, 120, 30 },
    dynamicRows = "decorQuests.trackerDynamicRows",
    cells       = {
        header  = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        body    = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
        buttons = { col = 1, row = 3, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.decorQuestTrackerPanel = {
    kind = "panel",
    cell = { decorQuestTrackerWindow = "header" },
    visibleInViews = { "decorQuestTrackerWindow" },
    -- The body slot, not a header slot: a header slot's height is fixed, and the title wraps to
    -- two lines for a long name (dynamicRows sizes the cell).
    slots = {
        body = {
            layout = "horizontal", gap = HDG.Constants.DQ_TRACKER.gap,   -- the selectors measure the title by it
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}

LC.panels.decorQuestTrackerBodyPanel = {
    kind = "panel",
    cell = { decorQuestTrackerWindow = "body" },
    visibleInViews = { "decorQuestTrackerWindow" },
}

LC.panels.decorQuestTrackerButtonPanel = {
    kind = "panel",
    cell = { decorQuestTrackerWindow = "buttons" },
    visibleInViews = { "decorQuestTrackerWindow" },
}

-- ===== Sections ==============================================================
LC.sections["decorQuestTracker.body"] = {
    ["in"] = "decorQuestTrackerBodyPanel",
    layout = "vertical",
    padding = { top = 4, right = "md", bottom = 4, left = "md" },
    gap = "xs",
    order = 10,
}

LC.sections["decorQuestTracker.buttons"] = {
    ["in"] = "decorQuestTrackerButtonPanel",
    layout = "horizontal",
    padding = { top = 4, right = "md", bottom = 4, left = "md" },
    gap = "sm",
    order = 10,
}

-- ===== Header ================================================================
-- No height: it fills the header, which is as tall as the lines its text wraps to.
LC.widgets["decorQuestTrackerPanel.title"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "decorQuestTrackerPanel", slot = "body",
    text = "", font = "subheading", wrap = true, justifyV = "MIDDLE", width = "fill", order = 10,
    binding = "decorQuests.trackerTitle",
}
-- Next steps: the arrow points down while they show, right while they don't (the
-- Lumber Tracker's glyph and turns).
LC.widgets["decorQuestTrackerPanel.expand"] = {
    tooltip = { recipe = "DqTrackerExpand" },
    kind = "iconToggle", ["in"] = "decorQuestTrackerPanel", slot = "body",
    glyph = "wowlabs-spectatecycling-arrowleft",
    size = 20,
    dimWhenInactive = false,
    rotateActive    =  math.pi / 2,    -- next steps shown -> DOWN
    rotateInactive  =  math.pi,        -- hidden           -> RIGHT
    width = HDG.Constants.DQ_TRACKER.arrowW, height = 20, order = 85,
    binding = { active = "decorQuests.trackerExpanded" },
    visible = "decorQuests.trackerArrow",   -- next steps to list, or Compact's Full to open
}
-- Settings cog (owner 2026-11-02, as the vendor sidebar's): Interface > Quest Tracker.
-- Its width is DQ_TRACKER.cogW: the title is measured past it.
LC.widgets["decorQuestTrackerPanel.settings"] = {
    tooltip = { recipe = "SettingsCogTracker" },
    kind = "button", ["in"] = "decorQuestTrackerPanel", slot = "body",
    normalAtlas = "GM-icon-settings", highlightAtlas = "GM-icon-settings-hover",
    width = HDG.Constants.DQ_TRACKER.cogW, height = 20, size = 20, order = 90,
}
LC.widgets["decorQuestTrackerPanel.close"] = {
    tooltip = { recipe = "DqTrackerClose" },
    kind = "button", ["in"] = "decorQuestTrackerPanel", slot = "body", font = "button",
    text = "X",
    width = HDG.Constants.DQ_TRACKER.closeW, height = 20, order = 95, variant = "tertiary",
    textTone = "error",
}

-- ===== Body ==================================================================
LC.widgets["decorQuestTrackerBodyPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "decorQuestTracker.body",
    binding = "decorQuests.trackerRows",
    rowKind = "decorQuestTrackerRow",
    spacing = 0,
    order = 10,
}

-- ===== Buttons ===============================================================
-- The buttons share the bar (the Full mockup). Close and Stop tracking both stop tracking:
-- Close once it has ended, the call to action then.
LC.widgets["decorQuestTrackerButtonPanel.done"] = {
    tooltip = { recipe = "DqTrackerDone" },
    kind = "button", ["in"] = "decorQuestTracker.buttons", font = "small",
    text = "locale:DQ_TRK_CLOSE", width = "fill", height = 20, order = 5, variant = "primary",
    visible = "decorQuests.trackerEnded",
}
LC.widgets["decorQuestTrackerButtonPanel.open"] = {
    tooltip = { recipe = "DqTrackerOpen" },
    kind = "button", ["in"] = "decorQuestTracker.buttons", font = "small",
    text = "locale:DQ_TRK_OPEN", width = "fill", height = 20, order = 20, variant = "tertiary",
    visible = "decorQuests.trackerFull",   -- Compact has no buttons bar (its row is 0 tall)
}
LC.widgets["decorQuestTrackerButtonPanel.stop"] = {
    tooltip = { recipe = "DqTrackerStop" },
    kind = "button", ["in"] = "decorQuestTracker.buttons", font = "small",
    text = "locale:DQ_TRK_STOP", width = "fill", height = 20, order = 30, variant = "tertiary",
    visible = "decorQuests.trackerStopShown",
}

-- ===== Window ================================================================
LC.windows.decorQuestTracker = {
    slots    = { fill = "decorQuestTrackerWindow" },
    shown    = "decorQuests.trackerShown",
    position = {
        binding   = "decorQuests.trackerPosition",
        setAction = "DQ_TRACKER_POSITION_SET",
        default   = { x = 100, y = -200 },
        movable   = true,
    },
}
