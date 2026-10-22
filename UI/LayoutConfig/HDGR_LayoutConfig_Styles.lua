-- HDGR_LayoutConfig_Styles.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Styles tab: five visibility-gated sub-views (landing / detail / curator / smartset / import).
-- Width 1014 = centerColumn 578 -> 7 cards (7*80+6*1 spacing=566, 6px slack).
--   curator math: 1014 - padding(12) - leftCol+gap(208) - rightPad(8) - rightCol+gap(208) = 578
--
-- Dynamic widget blocks:
--   stylesPanel.filter_<value>            (from STYLES_FILTER_CHIPS)
--   stylesPanel.smartsetSeverity_<value>  (from STYLES_SMARTSET_SEVERITY_CHIPS)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.styles = {
    controllers = { "styles" },
    width    = "auto",       -- 4 + 1014 + 4 = 1022
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 1014 },     -- 998 + 16 margins so 7 cards hold (see header math)
    rows     = { 600 },      -- raised 540->600 so the nav column fills (no nav scroll)
    cells    = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.stylesPanel = {
    kind = "panel",
    cell = { styles = "body" },
    visibleInViews = { "styles" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections -- Landing ===================================================

LC.sections["styles.landing"] = {
    ["in"]   = "stylesPanel",
    layout   = "vertical",
    padding  = "md",
    gap      = "md",
    order    = 10,
    visible  = "styles.isView_landing",
}
LC.sections["styles.landing.heroRow"] = {
    ["in"]   = "styles.landing",
    layout   = "horizontal",
    height   = 22,
    gap      = "md",
    order    = 10,
}
-- Filter chip strip (7 chips).
LC.sections["styles.landing.filterRow"] = {
    ["in"]   = "styles.landing",
    layout   = "horizontal",
    height   = 22,
    gap      = "sm",
    order    = 20,
}
-- Count + search row.
LC.sections["styles.landing.searchRow"] = {
    ["in"]   = "styles.landing",
    layout   = "horizontal",
    height   = 24,
    gap      = "md",
    order    = 30,
}
-- Sections scrollbox.
LC.sections["styles.landing.sectionsList"] = {
    ["in"]    = "styles.landing",
    layout    = "fill",
    order     = 40,
    chrome    = "inset",
}

-- ===== Sections -- Detail ====================================================

LC.sections["styles.detail"] = {
    ["in"]  = "stylesPanel",
    layout  = "vertical",
    padding = "md",
    gap     = "sm",
    order   = 20,
    visible = "styles.isView_detail",
}
-- Source URL copy box: hides when no source URL (zero cost for collections without one).
LC.sections["styles.detail.sourceRow"] = {
    ["in"]   = "styles.detail",
    layout   = "horizontal",
    height   = 28,
    order    = 10,
    visible  = "styles.detail.hasSourceUrl",
}
LC.sections["styles.detail.list"] = {
    ["in"]   = "styles.detail",
    layout   = "fill",
    order    = 30,
    chrome   = "inset",
}

-- ===== Sections -- Curator ===================================================
-- Three-column: left (source dropdown + target list) | center (item grid) | right (recent + memberships).

LC.sections["styles.curator"] = {
    ["in"]   = "stylesPanel",
    layout   = "vertical",
    padding  = "md",
    gap      = "sm",
    order    = 30,
    visible  = "styles.isView_curator",
}
LC.sections["styles.curator.body"] = {
    ["in"]   = "styles.curator",
    layout   = "horizontal",
    gap      = "lg",   -- separates the VIEWING column from the icon strip + grid
    order    = 20,
}
-- rightSide: filterStrip spans (centerColumn + rightColumn); leftColumn gets full body height.
LC.sections["styles.curator.rightSide"] = {
    ["in"]   = "styles.curator.body",
    layout   = "vertical",
    width    = "fill",
    -- right=8 only; left margin comes from body gap_lg (not doubled).
    padding  = { top = 0, right = 8, bottom = 0, left = 0 },
    gap      = "sm",
    order    = 20,
}
-- filterStrip height="content" SUMS chipStrip widget heights
-- ("auto" sections fall through to "fill" since only widgets stamp _intrinsicHeight).
LC.sections["styles.curator.filterStrip"] = {
    ["in"]   = "styles.curator.rightSide",
    layout   = "vertical",
    -- chrome="inset" groups the icon strip visually as a toolbar.
    chrome   = "inset",
    padding  = { top = 4, right = 6, bottom = 4, left = 6 },
    -- "content" (NOT "auto"): "auto" sections fall to "fill" -> splits rightSide 50/50.
    height   = "content",
    gap      = "xs",
    order    = 5,
}
LC.sections["styles.curator.contentRow"] = {
    ["in"]   = "styles.curator.rightSide",
    layout   = "horizontal",
    gap      = "lg",   -- gap between grid and Recent/Memberships column
    order    = 10,
}
-- Left column (200w): VIEWING dropdown + FILE INTO list.
LC.sections["styles.curator.leftColumn"] = {
    ["in"]   = "styles.curator.body",
    layout   = "vertical",
    width    = 200,
    gap      = "sm",
    order    = 10,
}
LC.sections["styles.curator.sourceLabelRow"] = {
    ["in"]   = "styles.curator.leftColumn",
    layout   = "horizontal",
    height   = 14,
    order    = 5,
}
LC.sections["styles.curator.sourceRow"] = {
    ["in"]   = "styles.curator.leftColumn",
    layout   = "horizontal",
    height   = 22,
    order    = 7,
}
LC.sections["styles.curator.leftLabel"] = {
    ["in"]   = "styles.curator.leftColumn",
    layout   = "horizontal",
    height   = 18,
    order    = 10,
}
LC.sections["styles.curator.targetList"] = {
    ["in"]   = "styles.curator.leftColumn",
    layout   = "fill",
    order    = 20,
    chrome   = "inset",
}
LC.sections["styles.curator.newStyleRow"] = {
    ["in"]   = "styles.curator.leftColumn",
    layout   = "horizontal",
    height   = 24,
    order    = 30,
}
-- Center column: control bar + item grid (inside rightSide so filterStrip spans center+right).
LC.sections["styles.curator.centerColumn"] = {
    ["in"]   = "styles.curator.contentRow",
    layout   = "vertical",
    width    = "fill",
    gap      = "sm",
    order    = 20,
}
-- chipStrip widgets placed directly in filterStrip; self-size via _intrinsicHeight.
LC.sections["styles.curator.controls"] = {
    ["in"]   = "styles.curator.centerColumn",
    layout   = "horizontal",
    height   = 24,
    gap      = "md",
    order    = 10,
}
-- Search row: full-width name filter directly above the card grid.
LC.sections["styles.curator.searchRow"] = {
    ["in"]   = "styles.curator.centerColumn",
    layout   = "horizontal",
    height   = 22,
    order    = 15,
}
LC.sections["styles.curator.itemGrid"] = {
    ["in"]   = "styles.curator.centerColumn",
    layout   = "fill",
    order    = 20,
    chrome   = "inset",
}
-- Right column (200w): Recent + Memberships. Top spacer aligns Recent with the item grid.
LC.sections["styles.curator.rightColumn"] = {
    ["in"]   = "styles.curator.contentRow",
    layout   = "vertical",
    width    = 200,
    gap      = "sm",
    order    = 30,
}
LC.sections["styles.curator.rightColumnTopSpacer"] = {
    ["in"]   = "styles.curator.rightColumn",
    layout   = "horizontal",
    -- Aligns RECENT with the grid top: controls(24) + searchRow(22) + 2 gaps (~sm).
    height   = 54,
    order    = 5,
}
LC.sections["styles.curator.recentLabelRow"] = {
    ["in"]  = "styles.curator.rightColumn",
    layout  = "horizontal",
    height  = 18,
    order   = 10,
}
LC.sections["styles.curator.recentList"] = {
    ["in"]   = "styles.curator.rightColumn",
    -- Recent is the frequently-used list -> give it the FILL so it takes the column's
    -- remaining height (Memberships below is fixed, since it's usually only a few rows).
    layout   = "fill",
    order    = 20,
    chrome   = "inset",
}
LC.sections["styles.curator.membershipsLabelRow"] = {
    ["in"]  = "styles.curator.rightColumn",
    layout  = "horizontal",
    height  = 18,
    order   = 30,
}
LC.sections["styles.curator.membershipsList"] = {
    ["in"]   = "styles.curator.rightColumn",
    -- Fixed (was fill): the selected item belongs to only several sets, so a small
    -- scrollbox is enough; Recent above takes the column's remaining height. 100px keeps
    -- fixed+gap (180) under the ~196px the column allots (clears the over-spec).
    layout   = "vertical",
    height   = 100,
    order    = 40,
    chrome   = "inset",
}
-- Footer: coverage label (left) + unassigned count (right) + progress bar (row 2).
LC.sections["styles.curator.footer"] = {
    ["in"]   = "styles.curator",
    layout   = "vertical",
    height   = 36,
    gap      = "xs",
    padding  = "sm",
    order    = 30,
}
LC.sections["styles.curator.footer.labelRow"] = {
    ["in"]   = "styles.curator.footer",
    layout   = "horizontal",
    height   = 14,
    gap      = "md",
    order    = 10,
}

-- ===== Sections -- Smart Set Builder =========================================

LC.sections["styles.smartset"] = {
    ["in"]   = "stylesPanel",
    layout   = "vertical",
    padding  = "md",
    gap      = "sm",
    order    = 40,
    visible  = "styles.isView_smartset",
}
LC.sections["styles.smartset.fieldsRow"] = {
    ["in"]  = "styles.smartset",
    layout  = "horizontal",
    height  = 24,
    gap     = "md",
    order   = 15,
}
LC.sections["styles.smartset.body"] = {
    ["in"]   = "styles.smartset",
    layout   = "horizontal",
    gap      = "sm",
    order    = 20,
}
-- Column 1: axis picker (120w).
LC.sections["styles.smartset.axisColumn"] = {
    ["in"]  = "styles.smartset.body",
    layout  = "vertical",
    width   = 120,
    gap     = "xs",
    order   = 10,
}
LC.sections["styles.smartset.axisLabelRow"] = {
    ["in"]  = "styles.smartset.axisColumn",
    layout  = "horizontal",
    height  = 18,
    order   = 10,
}
LC.sections["styles.smartset.axisList"] = {
    ["in"]    = "styles.smartset.axisColumn",
    layout    = "fill",
    order     = 20,
    chrome    = "inset",
}
-- Column 2: tag list for the active axis (160w).
LC.sections["styles.smartset.tagColumn"] = {
    ["in"]  = "styles.smartset.body",
    layout  = "vertical",
    width   = 160,
    gap     = "xs",
    order   = 20,
}
LC.sections["styles.smartset.tagLabelRow"] = {
    ["in"]  = "styles.smartset.tagColumn",
    layout  = "horizontal",
    height  = 18,
    order   = 10,
}
LC.sections["styles.smartset.tagList"] = {
    ["in"]    = "styles.smartset.tagColumn",
    layout    = "fill",
    order     = 20,
    chrome    = "inset",
}
-- Column 3: severity-banded preview area (fill).
LC.sections["styles.smartset.previewColumn"] = {
    ["in"]  = "styles.smartset.body",
    layout  = "vertical",
    width   = "fill",
    gap     = "xs",
    order   = 30,
}
LC.sections["styles.smartset.severityRow"] = {
    ["in"]  = "styles.smartset.previewColumn",
    layout  = "horizontal",
    height  = 22,
    gap     = "sm",
    order   = 10,
}
LC.sections["styles.smartset.previewArea"] = {
    ["in"]    = "styles.smartset.previewColumn",
    layout    = "fill",
    order     = 20,
    chrome    = "inset",
}
-- Footer: Clear All / Cancel / Save.
LC.sections["styles.smartset.footer"] = {
    ["in"]   = "styles.smartset",
    layout   = "horizontal",
    height   = 26,
    padding  = "sm",
    gap      = "md",
    order    = 30,
}

-- ===== Sections -- Import ====================================================

LC.sections["styles.import"] = {
    ["in"]   = "stylesPanel",
    layout   = "vertical",
    padding  = "md",
    gap      = "sm",
    order    = 50,
    visible  = "styles.isView_import",
}
LC.sections["styles.import.headerRow"] = {
    ["in"]  = "styles.import",
    layout  = "horizontal",
    height  = 28,
    gap     = "md",
    order   = 10,
}
LC.sections["styles.import.intro"] = {
    ["in"]  = "styles.import",
    layout  = "horizontal",
    height  = 36,
    order   = 20,
}
LC.sections["styles.import.pasteRow"] = {
    ["in"]  = "styles.import",
    layout  = "horizontal",
    height  = 26,
    gap     = "sm",
    order   = 30,
}
LC.sections["styles.import.statusRow"] = {
    ["in"]  = "styles.import",
    layout  = "horizontal",
    height  = 18,
    order   = 40,
}
-- Editable title for the import, shown only once a build has parsed (canCommit).
LC.sections["styles.import.titleRow"] = {
    ["in"]    = "styles.import",
    layout    = "horizontal",
    height    = 24,
    gap       = "sm",
    order     = 45,
    visible   = "styles.import.canCommit",
}
LC.sections["styles.import.previewList"] = {
    ["in"]   = "styles.import",
    layout   = "fill",
    order    = 50,
    chrome   = "inset",
}
LC.sections["styles.import.destRow"] = {
    ["in"]  = "styles.import",
    layout  = "horizontal",
    height  = 24,
    gap     = "md",
    order   = 55,
}
LC.sections["styles.import.footer"] = {
    ["in"]   = "styles.import",
    layout   = "horizontal",
    height   = 26,
    padding  = "sm",
    gap      = "md",
    order    = 60,
}

-- ===== Sections -- Export ====================================================
LC.sections["styles.export"] = {
    ["in"]   = "stylesPanel",
    layout   = "vertical",
    padding  = "md",
    gap      = "sm",
    order    = 52,
    visible  = "styles.isView_export",
}
LC.sections["styles.export.headerRow"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 28, gap = "md", order = 10,
}
LC.sections["styles.export.intro"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 30, order = 20,
}
-- Search (right). Format toggle lives in its own gated row (collection only).
LC.sections["styles.export.toolsRow"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 24, gap = "md", order = 30,
}
-- Format toggle: only the collection can export as DD2, so this row shows only
-- when the collection is selected (otherwise format is HDG, no choice to make).
LC.sections["styles.export.formatRow"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 24, gap = "md", order = 45,
    visible = "styles.export.isCollection",
}
LC.sections["styles.export.sourceList"] = {
    ["in"] = "styles.export", layout = "fill", order = 40, chrome = "inset",
}
LC.sections["styles.export.captionRow"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 16, order = 50,
}
-- URL row: shown only when the selection has a link (DD2 collection -> wowdb sync
-- page, or a shopping list's source URL). Selectable editbox so it can be copied.
LC.sections["styles.export.urlRow"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 22, order = 52,
    visible = "styles.export.hasUrl",
}
LC.sections["styles.export.codeRow"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 50, order = 55, chrome = "inset",
}
LC.sections["styles.export.footer"] = {
    ["in"] = "styles.export", layout = "horizontal", height = 26, padding = "sm", gap = "md", order = 60,
}

-- ===== Widgets -- panel header ================================================
-- Back shown only on `detail` (no nav leaf); Browse/Curator/Smart Sets use the nav to go back.

LC.widgets["stylesPanel.headerBack"] = {
    tooltip = false,
    kind = "button", ["in"] = "stylesPanel", slot = "header", font = "small",
    text = "locale:STY_BACK", width = "auto", height = 22, order = 5, variant = "tertiary",
    visible = "styles.isView_detail",
}
LC.widgets["stylesPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "stylesPanel", slot = "header",
    text = "locale:STY_PANEL_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "styles.headerTitle",
}
LC.widgets["stylesPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "stylesPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
-- Mouse hint (smartset only): tag click cycles severity (reads as static text without it).
LC.widgets["stylesPanel.smartsetHints"] = {
    tooltip = false,   -- self-owned tooltip
    kind = "clickHints", ["in"] = "stylesPanel", slot = "header",
    visible = "styles.isView_smartset",
    leftText = "locale:STY_SMARTSET_HINTS_LEFT",
    width = 16, height = 16, order = 25,
}
LC.widgets["stylesPanel.headerCount"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "stylesPanel", slot = "header",
    text = "", font = "small", justifyH = "RIGHT",
    height = 14, width = "auto", order = 20,
    -- Unified per-view count; returns "" for views without one.
    binding = "styles.headerCount",
}

-- ===== Widgets -- landing surface ============================================
LC.widgets["stylesPanel.heroTagline"] = {
    tooltip = false,
    kind = "label", ["in"] = "styles.landing.heroRow", font = "subheading",
    text = "locale:STY_LANDING_TAGLINE",
    height = 22, width = "fill", order = 10,
}
LC.widgets["stylesPanel.saveSnapshot"] = {
    tooltip = { recipe = "StylesSnapshot" },
    kind = "button", ["in"] = "styles.landing.heroRow", font = "small",
    text = "locale:STY_SAVE_PLACED_DECOR", width = "auto", height = 22, order = 17, variant = "tertiary",
    binding = { enabled = "styles.snapshot.canSave" },
}
LC.widgets["stylesPanel.openImport"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.landing.heroRow", font = "small",
    text = "locale:STY_IMPORT_BTN", width = "auto", height = 22, order = 18, variant = "tertiary",
}
LC.widgets["stylesPanel.openExport"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.landing.heroRow", font = "small",
    text = "locale:STY_EXPORT_BTN", width = "auto", height = 22, order = 19, variant = "tertiary",
}
LC.widgets["stylesPanel.totalLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.landing.heroRow", font = "small",
    text = "", height = 14, width = "auto", order = 20,
    binding = "styles.landing.totalStylesLabel",
}
-- Sections scrollbox.
LC.widgets["stylesPanel.sectionsList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.landing.sectionsList",
    binding = "styles.landing.rows",
    rowKind = "stylesLandingRow",
    spacing = 2,
    order = 10,
}
-- Search box (right of count label); filters by displayName substring.
LC.widgets["stylesPanel.landingSearch"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.landing.searchRow", font = "small",
    height = 22, width = 200, order = 20,
    placeholder = "locale:STY_SEARCH_STYLES_PLACEHOLDER",
    binding = { text = "styles.landing.search" },
}

-- ===== Widgets -- detail surface ==============================================

LC.widgets["stylesPanel.detailDescription"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.detail", font = "small",
    text = "", height = 28, width = "fill", order = 15,
    binding = "styles.detail.descriptionLabel",
}
-- Source URL copy button: shows the source host (+ wowhead logo); click pops
-- the shared slimline URL copy field under it (see UrlCopyPopup). Section
-- visibility is gated on hasSourceUrl, so the button only shows when present.
LC.widgets["stylesPanel.detailSourceLink"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.detail.sourceRow",
    text = "", font = "small",
    width = "fill", height = 22, order = 10,
    binding = { text = "styles.detail.sourceButtonText" },
}
-- Detail item search in the panel header (detail view only).
LC.widgets["stylesPanel.detailSearch"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "stylesPanel", slot = "header", font = "small",
    height = 20, width = 200, order = 12,
    placeholder = "locale:STY_SEARCH_ITEMS_PLACEHOLDER",
    visible = "styles.isView_detail",
    binding = { text = "styles.detail.search" },
}
-- Detail items: CardGrid.
LC.widgets["stylesPanel.detailList"] = {
    tooltip = false,
    kind = "cardGrid", ["in"] = "styles.detail.list",
    binding = "styles.detail.items",
    cellKind    = "stylesDetailTile",
    cellsPerRow = 8,
    cellSize    = 80,
    order = 10,
}

-- ===== Widgets -- curator surface ============================================

-- Column 1: VIEWING (SOURCE) label + dropdown picker.
LC.widgets["stylesPanel.curatorSourceColLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.curator.sourceLabelRow", font = "small",
    text = "locale:STY_CURATOR_SOURCE_LABEL", height = 14, width = "fill", order = 10,
}
LC.widgets["stylesPanel.curatorSourceBtn"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "styles.curator.sourceRow",
    height = 22, order = 10, minWidth = 180,
    placeholder = "locale:STY_CURATOR_SOURCE_PLACEHOLDER",
    binding  = { menu = "styles.curator.sourceMenuItems", current = "styles.curator.sourceMode" },
    dispatch = { type = "STYLES_CURATOR_SET_SOURCE", payloadKey = "mode" },
}
LC.widgets["stylesPanel.curatorFileIntoLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.curator.leftLabel", font = "small",
    text = "locale:STY_CURATOR_FILE_INTO_LABEL", height = 14, width = "fill", order = 10,
}
-- + New Style.
LC.widgets["stylesPanel.curatorNewStyle"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.curator.newStyleRow", font = "small",
    text = "locale:STY_CURATOR_NEW_STYLE", width = "fill", height = 22, order = 10, variant = "tertiary",
}
LC.widgets["stylesPanel.curatorTargetList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.curator.targetList",
    binding = "styles.curator.targetRows",
    rowKind = "stylesCuratorTargetRow",
    spacing = 1,
    order = 10,
}
-- Move: requires selectedItems > 0 AND selectedTargetID; label reads "Move (N)".
-- "N selected" (blank when nothing selected). Sits AFTER Copy/Move (order 7,
-- before the fill spacer) so an empty selection leaves no dead gap at the left.
-- FIXED width: the label starts empty at layout, so "auto" would measure 0 and
-- never grow when a selection arrives (the row doesn't re-flow on a text-only
-- binding update).
LC.widgets["stylesPanel.curatorSelectionLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.curator.controls", font = "small",
    text = "", height = 22, width = 92, order = 7,
    binding = { text = "styles.curator.selectedCountLabel" },
}
-- Copy: add to target, keep in source. Valid from any source (All Items / a style).
LC.widgets["stylesPanel.curatorCopy"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.curator.controls", font = "small",
    text = "locale:STY_CURATOR_COPY", width = "auto", height = 22, order = 4, variant = "primary",
    binding = { text = "styles.curator.copyButtonLabel",
                enabled = "styles.curator.canCopy" },
}
-- Move: add to target, remove from source style. Shown ONLY when the source is a
-- user style (moveApplies); from All Items / Unassigned there's nothing to move out of.
LC.widgets["stylesPanel.curatorMove"] = {
    tooltip = { recipe = "CuratorMove" },
    kind = "button", ["in"] = "styles.curator.controls", font = "small",
    text = "locale:STY_CURATOR_MOVE", width = "auto", height = 22, order = 5, variant = "primary",
    visible = "styles.curator.moveApplies",
    binding = { text = "styles.curator.moveButtonLabel",
                enabled = "styles.curator.canMove" },
}
-- Spacer between Move and Clear/Undo.
LC.widgets["stylesPanel.curatorControlsSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "styles.curator.controls",
    width = "fill", height = 14, order = 10,
}
LC.widgets["stylesPanel.curatorClearSelection"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.curator.controls", font = "small",
    text = "locale:STY_CURATOR_CLEAR_SELECTION", width = "auto", height = 22, order = 20, variant = "tertiary",
}
LC.widgets["stylesPanel.curatorUndoBtn"] = {
    tooltip = { recipe = "CuratorUndo" },
    kind = "button", ["in"] = "styles.curator.controls", font = "small",
    text = "locale:STY_CURATOR_UNDO_LAST_MOVE", width = "auto", height = 22, order = 30, variant = "tertiary",
    binding = { enabled = "styles.curator.canUndo" },
}
-- Card-grid name filter. Dedicated action (nested curator.searchQuery slot);
-- wired in Controller_Styles, mirroring the detail-search box.
LC.widgets["stylesPanel.curatorSearch"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.curator.searchRow", font = "small",
    height = 22, width = "fill", order = 10,
    placeholder = "locale:STY_CURATOR_SEARCH_PLACEHOLDER",
    binding = { text = "styles.curator.searchQuery" },
}
-- Card-grid: icon tiles; selection via cell atlas swap.
LC.widgets["stylesPanel.curatorItemGrid"] = {
    tooltip = false,
    kind = "cardGrid", ["in"] = "styles.curator.itemGrid",
    binding = "styles.curator.sourceItems",
    cellKind    = "stylesCuratorTile",
    cellsPerRow = 6,
    cellSize    = 80,
    order = 10,
}

-- Curator right column.
LC.widgets["stylesPanel.curatorRecentLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.curator.recentLabelRow", font = "small",
    text = "locale:STY_CURATOR_RECENT_LABEL", height = 14, width = "fill", order = 10,
}
LC.widgets["stylesPanel.curatorRecentList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.curator.recentList",
    binding = "styles.curator.recentUndoRows",
    rowKind = "stylesCuratorRecentRow",
    spacing = 1,
    order = 10,
}
LC.widgets["stylesPanel.curatorMembershipsLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.curator.membershipsLabelRow", font = "small",
    text = "locale:STY_CURATOR_MEMBERSHIPS_LABEL", height = 14, width = "fill", order = 10,
}
LC.widgets["stylesPanel.curatorMembershipsList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.curator.membershipsList",
    binding = "styles.curator.hoverMemberships",
    rowKind = "stylesCuratorMembershipRow",
    spacing = 1,
    order = 10,
}
-- Curator footer.
LC.widgets["stylesPanel.curatorCoverageLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.curator.footer.labelRow", font = "small",
    text = "", height = 14, width = "fill", order = 10,
    binding = "styles.curator.coverageLabel",
}
LC.widgets["stylesPanel.curatorUnassignedLabel"] = {
    tooltip = false,
    -- "status" = accent; closest attention cue available without a dedicated error-text role.
    kind = "label", role = "TextStatus", ["in"] = "styles.curator.footer.labelRow", font = "small",
    text = "", height = 14, width = "auto", order = 20,
    binding = "styles.curator.unassignedCountLabel",
}
LC.widgets["stylesPanel.curatorCoverageBar"] = {
    tooltip = false,
    kind = "progressbar", ["in"] = "styles.curator.footer", font = "small",
    height = 8, width = "fill", order = 20,
    binding = { progress = "styles.curator.coveragePct" },
}
-- Category + subcategory chipStrip widgets: FlowContainer-backed; chipStrip stamps _intrinsicHeight.
LC.widgets["stylesPanel.curatorCategoryStrip"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "styles.curator.filterStrip",
    binding = "styles.curator.categoryIcons",   -- Blizzard category icon nav (was text categoryRows)
    cellKind = "curatorCategoryIcon",
    chipHeight = 36,
    -- Tight packing: atlas glyphs are self-framed, read fine shoulder-to-shoulder.
    chipMinWidth = 34, chipPadH = 6, horizontalSpacing = 2, verticalSpacing = 2,
    height = "auto",  -- chipStrip widget reports _intrinsicHeight after FlowContainer layout
    order = 5,
}
LC.widgets["stylesPanel.curatorSubcategoryStrip"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "styles.curator.filterStrip",
    binding = "styles.curator.subcategoryChips",   -- tree-based subcats (was item-derived subcategoryRows)
    cellKind = "curatorSubcategoryIcon",           -- subcategories carry icons too (shared sheet)
    chipHeight = 36,
    chipMinWidth = 34, chipPadH = 6, horizontalSpacing = 2, verticalSpacing = 2,
    height = "auto",
    order = 6,
    -- NOT visible-gated: becomes-visible fires AFTER Layout, so intrinsic height lands late
    -- (blank on first paint). Always-rendered -> content push in Bind -> correct height same pass.
    -- Empty subcategory -> returns {} -> 0 height, no gap.
}

-- ===== Widgets -- import surface =============================================

LC.widgets["stylesPanel.importBack"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.import.headerRow", font = "small",
    text = "locale:STY_BACK", width = "auto", height = 22, order = 10, variant = "tertiary",
}
LC.widgets["stylesPanel.importTitle"] = {
    tooltip = false,
    kind = "label", ["in"] = "styles.import.headerRow", font = "heading",
    text = "locale:STY_IMPORT_TITLE", height = 22, width = "fill", order = 20,
}
LC.widgets["stylesPanel.importIntro"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.import.intro", font = "small",
    text = "locale:STY_IMPORT_INTRO",
    height = 32, width = "fill", order = 10,
}
LC.widgets["stylesPanel.importUrlEdit"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.import.pasteRow", font = "small",
    width = "fill", height = 22, order = 10,
    placeholder = "locale:STY_IMPORT_URL_PLACEHOLDER",
    binding = { text = "styles.import.urlText" },
}
LC.widgets["stylesPanel.importStatus"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.import.statusRow", font = "small",
    text = "", height = 14, width = "fill", order = 10,
    binding = "styles.import.statusLabel",
}
LC.widgets["stylesPanel.importTitleLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.import.titleRow", font = "small",
    text = "locale:STY_IMPORT_TITLE_LABEL", height = 22, width = "auto", order = 10,
}
LC.widgets["stylesPanel.importTitleEdit"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.import.titleRow", font = "small",
    width = "fill", height = 22, order = 20,
    placeholder = "locale:STY_IMPORT_TITLE_PLACEHOLDER",
    binding = { text = "styles.import.title" },
}
LC.widgets["stylesPanel.importPreviewList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.import.previewList",
    binding = "styles.import.previewRows",
    rowKind = "stylesImportPreviewRow",
    spacing = 1,
    order = 10,
}
LC.widgets["stylesPanel.importDestLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.import.destRow", font = "small",
    text = "locale:STY_IMPORT_DEST_LABEL", height = 20, width = "auto", order = 10,
}
-- Slack absorber: ordered BEFORE the label so the "Import into:" label AND the
-- radios both ride the right edge of the row.
LC.widgets["stylesPanel.importDestSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "styles.import.destRow", width = "fill", height = 20, order = 5,
}
LC.widgets["stylesPanel.importDestRadio"] = {
    tooltip = false,
    kind = "radioGroup", ["in"] = "styles.import.destRow", font = "small",
    height = 20, width = "auto", spacing = 14, order = 20,
    binding  = { menu = "styles.import.destinationItems", current = "styles.import.destination" },
    dispatch = { type = "STYLES_IMPORT_SET_DESTINATION", payloadKey = "destination" },
}
LC.widgets["stylesPanel.importReset"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.import.footer", font = "small",
    text = "locale:COMMON_RESET", width = "auto", height = 22, order = 10, variant = "tertiary",
}
LC.widgets["stylesPanel.importHint"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.import.footer", font = "small",
    text = "", height = 14, width = "fill", order = 20,
}
LC.widgets["stylesPanel.importCommit"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.import.footer", font = "small",
    text = "locale:STY_IMPORT_COMMIT", width = "auto", height = 22, order = 30, variant = "primary",
    binding = { enabled = "styles.import.canCommit" },
}

-- ===== Widgets -- Export ======================================================
LC.widgets["stylesPanel.exportBack"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.export.headerRow", font = "small",
    text = "locale:STY_BACK", width = "auto", height = 22, order = 10, variant = "tertiary",
}
LC.widgets["stylesPanel.exportTitle"] = {
    tooltip = false,
    kind = "label", ["in"] = "styles.export.headerRow", font = "heading",
    text = "locale:STY_EXPORT_TITLE", height = 22, width = "fill", order = 20,
}
LC.widgets["stylesPanel.exportIntro"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.export.intro", font = "small",
    text = "locale:STY_EXPORT_INTRO", height = 26, width = "fill", order = 10,
}
LC.widgets["stylesPanel.exportFormatLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.export.formatRow", font = "small",
    text = "locale:STY_EXPORT_FORMAT_LABEL", height = 20, width = "auto", order = 5,
}
LC.widgets["stylesPanel.exportFormatRadio"] = {
    tooltip = false,
    kind = "radioGroup", ["in"] = "styles.export.formatRow", font = "small",
    height = 20, width = "auto", spacing = 14, order = 10,
    binding  = { menu = "styles.export.formatItems", current = "styles.export.format" },
    dispatch = { type = "STYLES_EXPORT_SET_FORMAT", payloadKey = "format" },
}
LC.widgets["stylesPanel.exportToolsSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "styles.export.toolsRow", width = "fill", height = 20, order = 5,
}
LC.widgets["stylesPanel.exportSearch"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.export.toolsRow", font = "small",
    height = 22, width = 200, order = 20,
    placeholder = "locale:STY_EXPORT_SEARCH_PLACEHOLDER",
    binding = { text = "styles.export.search" },
}
LC.widgets["stylesPanel.exportSourceList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.export.sourceList",
    binding = "styles.export.sourceRows",
    rowKind = "stylesExportSourceRow",
    spacing = 2,
    order = 10,
}
LC.widgets["stylesPanel.exportCaption"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.export.captionRow", font = "small",
    text = "", height = 14, width = "fill", order = 10,
}
LC.widgets["stylesPanel.exportUrl"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.export.urlRow", font = "small",
    width = "fill", height = 20, order = 10,
    binding = { text = "styles.export.url" },
}
-- Read-only code box. No binding/dispatch: the controller fills the text
-- imperatively (the code is built from codecs + the catalog observer, which are
-- non-store singletons, so it can't come from a selector) and disables length
-- limits so long DD2 strings aren't truncated.
LC.widgets["stylesPanel.exportCode"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.export.codeRow", font = "small",
    multiline = true, width = "fill", height = 42, order = 10,
}
LC.widgets["stylesPanel.exportCopy"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.export.footer", font = "small",
    text = "locale:STY_EXPORT_COPY", width = "auto", height = 22, order = 10, variant = "primary",
}
LC.widgets["stylesPanel.exportFooterHint"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.export.footer", font = "small",
    text = "", height = 14, width = "fill", order = 20,
}

-- ===== Widgets -- Smart Set Builder ==========================================
LC.widgets["stylesPanel.smartsetNameLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.smartset.fieldsRow", font = "small",
    text = "locale:STY_SMARTSET_NAME_LABEL", width = 40, height = 20, order = 10,
}
LC.widgets["stylesPanel.smartsetNameEdit"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.smartset.fieldsRow", font = "small",
    width = 220, height = 22, order = 20,
    placeholder = "locale:STY_SMARTSET_NAME_PLACEHOLDER",
    binding = { text = "styles.smartset.draft.displayName" },
}
LC.widgets["stylesPanel.smartsetDescLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.smartset.fieldsRow", font = "small",
    text = "locale:STY_SMARTSET_DESC_LABEL", width = 70, height = 20, order = 30,
}
LC.widgets["stylesPanel.smartsetDescEdit"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "styles.smartset.fieldsRow", font = "small",
    width = "fill", height = 22, order = 40,
    placeholder = "locale:STY_SMARTSET_DESC_PLACEHOLDER",
    binding = { text = "styles.smartset.draft.description" },
}
-- Column labels (AXIS / TAG).
LC.widgets["stylesPanel.smartsetAxisLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.smartset.axisLabelRow", font = "small",
    text = "locale:STY_SMARTSET_AXIS_LABEL", height = 14, width = "fill", order = 10,
}
LC.widgets["stylesPanel.smartsetTagLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.smartset.tagLabelRow", font = "small",
    text = "locale:STY_SMARTSET_TAG_LABEL", height = 14, width = "fill", order = 10,
}
-- Body scrollboxes.
LC.widgets["stylesPanel.smartsetAxisList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.smartset.axisList",
    binding = "styles.smartset.axisRows",
    rowKind = "stylesAxisRow",
    spacing = 1,
    order = 10,
}
LC.widgets["stylesPanel.smartsetTagList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "styles.smartset.tagList",
    binding = "styles.smartset.activeAxisTags",
    rowKind = "stylesTagRow",
    spacing = 1,
    order = 10,
}
-- SmartSet preview CardGrid: band tabs filter which items show; cellsPerRow=10 (fill column).
LC.widgets["stylesPanel.smartsetPreviewArea"] = {
    tooltip = false,
    kind = "cardGrid", ["in"] = "styles.smartset.previewArea",
    binding = "styles.smartset.previewItems",
    cellKind    = "stylesPreviewTile",
    cellsPerRow = 10,
    cellSize    = 80,
    order = 10,
}
-- Footer.
LC.widgets["stylesPanel.smartsetClear"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.smartset.footer", font = "small",
    text = "locale:STY_SMARTSET_CLEAR_ALL", width = "auto", height = 22, order = 10, variant = "tertiary",
}
LC.widgets["stylesPanel.smartsetHint"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "styles.smartset.footer", font = "small",
    text = "locale:STY_SMARTSET_HINT", height = 14, width = "fill", order = 20,
    binding = "styles.smartset.hintLabel",
}
LC.widgets["stylesPanel.smartsetCancel"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.smartset.footer", font = "small",
    text = "locale:COMMON_CANCEL", width = "auto", height = 22, order = 30, variant = "tertiary",
}
LC.widgets["stylesPanel.smartsetSave"] = {
    tooltip = false,
    kind = "button", ["in"] = "styles.smartset.footer", font = "small",
    text = "locale:COMMON_SAVE", width = "auto", height = 22, order = 40, variant = "primary",
    binding = { enabled = "styles.smartset.canSave" },
}

-- ===== Widgets -- dynamic (generated at load time) ===========================

-- Landing filter chips: 7 chips ("All" + 6 collection types).
local STYLES_FILTER_CHIPS = {
    { value = "all",        label = "All"         },
    { value = "style",      label = "My Styles"   },
    { value = "smartset",   label = "Filtered Sets" },
    { value = "shopping",   label = "Shopping"    },
    { value = "snapshot",   label = "Snapshots"   },
    { value = "concept",    label = "Room Concepts" },
    { value = "collection", label = "Collections" },
}
for i, c in ipairs(STYLES_FILTER_CHIPS) do
    LC.widgets["stylesPanel.filter_" .. c.value] = {
    tooltip = false,
        kind = "button", ["in"] = "styles.landing.filterRow", font = "caption",
        text = c.label, width = "auto", height = 20, order = i, variant = "chip",
        binding = { active = "styles.landing.isFilter_" .. c.value },
    }
end

-- Severity tab chips: All / Signature / Accent / Versatile / Clashing.
local STYLES_SMARTSET_SEVERITY_CHIPS = {
    { value = "all",       label = "All"       },
    { value = "signature", label = "Signature" },
    { value = "accent",    label = "Accent"    },
    { value = "versatile", label = "Versatile" },
    { value = "clashing",  label = "Clashing"  },
}
for i, c in ipairs(STYLES_SMARTSET_SEVERITY_CHIPS) do
    -- Named bands bind label to a count selector ("Signature (68)"); "all" is static.
    local bind = { active = "styles.smartset.isSeverity_" .. c.value }
    if c.value ~= "all" then bind.text = "styles.smartset.bandLabel_" .. c.value end
    LC.widgets["stylesPanel.smartsetSeverity_" .. c.value] = {
        tooltip = { recipe = "StylesSeverity_" .. c.value },
        kind = "button", ["in"] = "styles.smartset.severityRow", font = "caption",
        text = c.label, width = "auto", height = 20, order = i, variant = "chip",
        binding = bind,
    }
end
