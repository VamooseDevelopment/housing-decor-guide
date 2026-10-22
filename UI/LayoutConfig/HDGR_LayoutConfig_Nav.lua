-- HDGR_LayoutConfig_Nav.lua
-- ============================================================================
-- Sidebar navigation -- PURE DATA (HDG-ADR-025 step 4). One `treeList` widget
-- bound to nav.tree. standalone=true -> BuildMainWindow builds it separately.
-- navNode / navHeader cell kinds registered by HDG.NavController.

HDG = HDG or {}
local LC = HDG.LayoutConfig
local NAV_WIDTH = LC.NAV_WIDTH   -- 150

-- ===== View ==================================================================
-- height=100 is a placeholder; the `left` slot spans frameH at compose time.
LC.window.views.nav = {
    controllers = { "nav" },
    standalone = true,
    width      = NAV_WIDTH,
    height     = 100,            -- placeholder; left slot spans frameH to body height
    -- Asymmetric padding: right=0 so the single nav<->content seam is 4px not 8px.
    -- columns="fill" (not fixed NAV_WIDTH) so the panel respects these pads.
    padding    = { left = "sm", top = "sm", bottom = "sm", right = 0 },
    columns    = { "fill" },
    rows       = { "fill" },
    cells      = { body = { col = 1, row = 1, colSpan = 1, rowSpan = 1 } },
}

-- ===== Panel / section =======================================================
LC.panels.navPanel = {
    kind = "panel",
    skin = "NavRegion",   -- surface.panel_soft: nav reads as chrome, not a content panel
    cell = { nav = "body" },
    visibleInViews = { "nav" },
}

LC.sections["nav.body"] = {
    ["in"] = "navPanel",
    layout = "fill",
    order = 10,
}

-- ===== Widget: the tree ======================================================
-- indent=0 + rowSpacing=0: the accent spine is each row's left-edge bar.
-- Tree frame-indent would push child bars into the gutter (broken spine);
-- hierarchy comes from per-tier label X in the navNode initializer.
LC.widgets["navPanel.tree"] = {
    tooltip    = false,
    kind       = "treeList",
    ["in"]     = "nav.body",
    binding    = "nav.tree",
    rowHeight  = 26,
    rowSpacing = 0,
    indent     = 0,
    -- noScrollBar: nav is sized so it never scrolls; bar never shows and claimed the 6px gutter.
    noScrollBar = true,
}
