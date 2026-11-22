-- HDGR_LayoutConfig_Decor.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Decor tab: full-width filter strip above a 2-column browser/detail body.
--   decorFilterPanel  (filter row, span 2) -- search row + two rows of filter menus
--   decorChipsPanel   (chips row, col 1)   -- the ticks in force; no ticks, no row
--   decorPanel        (body, col 1)        -- browser list
--   decorDetailPanel  (detail, col 2)      -- 3D preview + meta + note cards
--
-- Dynamic widget blocks (generated at load time):
--   decorPanel.filterMenu_<id>   (one per HDG.Constants.DECOR_FILTER_MENUS entry)

HDG = HDG or {}
local LC = HDG.LayoutConfig
local FILTER_BAR_HEIGHT = HDG.Constants.DECOR_FILTER_BAR_HEIGHT   -- 3 rows: search row 25h + two rows of menu buttons 22h
local BODY_HEIGHT       = HDG.Constants.DECOR_BODY_HEIGHT

-- ===== View ==================================================================

LC.window.views.decor = {
    controllers = { "decor", "pets" },
    width    = "auto",       -- 4 + 360 + 4 + 540 + 4 = 912
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 360, 540 },
    -- chrome/status rows removed per HDG-ADR-025 (window slots provide them).
    -- Static fallback; decor.gridRows gives the chips' row its real height, taken
    -- out of the browser's, so the detail column (spanning both) never moves.
    rows        = { FILTER_BAR_HEIGHT, 0, BODY_HEIGHT },
    dynamicRows = "decor.gridRows",
    cells    = {
        filter = { col = 1, row = 1, colSpan = 2, rowSpan = 1 },
        chips  = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
        body   = { col = 1, row = 3, colSpan = 1, rowSpan = 1 },
        detail = { col = 2, row = 2, colSpan = 1, rowSpan = 2 },
    },
}

-- ===== Panels ================================================================

-- Decor filter strip. Full-width: the two rows of menu buttons need the ~900px.
LC.panels.decorFilterPanel = {
    kind = "panel",
    cell = { decor = "filter" },
    visibleInViews = { "decor" },
}

-- The ticks in force, one chip each, above the browser. Its row is zero-height
-- until a menu holds a tick (decor.gridRows).
LC.panels.decorChipsPanel = {
    kind = "panel",
    cell = { decor = "chips" },
    visibleInViews = { "decor" },
    visible = "decor.hasFilterChips",
}

-- Decor browser panel: list + header slot. Gated on catalog.isReady; loading/error/blank siblings own other states.
LC.panels.decorPanel = {
    kind = "panel",
    cell = { decor = "body" },
    visibleInViews = { "decor" },
    -- Visible when ready AND non-empty AND not in Pets mode; sibling overlays own
    -- loading/error/blank, and petPanel owns the body cell in pets mode.
    visible = "decor.showDecorBrowser",
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- Loading overlay: same body cell; visible while catalog is idle/loading.
LC.panels.decorLoadingPanel = {
    kind = "panel",
    cell = { decor = "body" },
    visibleInViews = { "decor" },
    visible = "catalog.isLoading",
}

-- Error overlay: catalog status="error" (sweep aborted). Same body cell.
LC.panels.decorErrorPanel = {
    kind = "panel",
    cell = { decor = "body" },
    visibleInViews = { "decor" },
    visible = "catalog.isError",
}

-- Blank overlay: catalog ready but filtered list is empty.
LC.panels.decorBlankPanel = {
    kind = "panel",
    cell = { decor = "body" },
    visibleInViews = { "decor" },
    visible = "decor.isBlank",
}

-- Decor detail panel: 3D preview + meta card + note card (right column).
LC.panels.decorDetailPanel = {
    kind = "panel",
    cell = { decor = "detail" },
    visibleInViews = { "decor" },
    -- Mode alone, NOT showDecorBrowser: this pane keeps standing when the decor
    -- list is empty (its "Click an item" placeholder is the point). Only pets
    -- mode takes the cell away, and petDetailPanel takes it.
    visible = "decor.showDecorDetail",
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================

LC.sections["decor.body"] = {
    ["in"] = "decorPanel",
    layout = "vertical",
    padding = "lg",
    gap = "sm",
    order = 10,
}

-- Filter strip: 3 stacked rows. Top: Decor | Pets, the search box (it fills the
-- row), Clear all, the match switch, Destroy decor. Then the filter menus: "What" (what the piece is and
-- where it goes) and "Looks" (how it looks).
LC.sections["decor.filterRow"] = {
    ["in"] = "decorFilterPanel",
    layout = "vertical",
    padding = "md",
    gap = "sm",
    order = 10,
}
LC.sections["decor.filterRowTop"] = {
    ["in"] = "decor.filterRow",
    layout = "horizontal",
    height = 25,
    gap    = "sm",
    order  = 10,
}
LC.sections["decor.filterRowWhat"] = {
    ["in"]   = "decor.filterRow",
    layout   = "horizontal",
    height   = 22,
    gap      = "xs",
    order    = 20,
}
LC.sections["decor.filterRowLooks"] = {
    ["in"]   = "decor.filterRow",
    layout   = "horizontal",
    height   = 22,
    gap      = "xs",
    order    = 30,
}
LC.sections["decor.chips"] = {
    ["in"] = "decorChipsPanel",
    layout = "vertical",
    padding = { top = "xs", right = "sm", bottom = 0, left = "sm" },
    order = 10,
}
LC.sections["decor.list"] = {
    ["in"] = "decor.body",
    layout = "fill",
    order = 10,
    chrome = "inset",
}
-- Filter-results status rail: ownership ratio + filtered count below the list.
LC.sections["decor.statusRail"] = {
    ["in"] = "decor.body",
    layout = "horizontal",
    height = 16,
    order = 20,
}

-- ===== Decor detail pane sections ============================================

LC.sections["decor.detailBody"] = {
    ["in"] = "decorDetailPanel",
    layout = "vertical",
    padding = "lg",
    gap = "md",
    order = 10,
}
-- 3D preview slot. 382 is what the 600px detail row leaves once the meta card
-- below holds its widest case -- category, profession, recipe source, source,
-- status, tags and the Destroy button all show at once on a crafted, tagged,
-- stored, destroyable piece, 146px of rows in the 118px that 410 left them,
-- so the bottom rows clipped (the over-spec test only saw it on 2026-09-13,
-- once the selectors gating those rows were loaded into its harness).
LC.sections["decor.previewSlot"] = {
    ["in"] = "decor.detailBody",
    layout = "vertical",
    height = 382,
    gap = "xs",
    order = 10,
}
-- Detail row 2: two sibling cards (detailCard=meta left, noteCard=note right).
LC.sections["decor.detailCardRow"] = {
    ["in"]   = "decor.detailBody",
    layout   = "horizontal",
    gap      = "sm",
    order    = 20,
}
LC.sections["decor.detailCard"] = {
    ["in"]    = "decor.detailCardRow",
    layout    = "vertical",
    padding   = "lg",
    gap       = "sm",
    width     = "fill",
    order     = 10,
    chrome    = "inset",   -- flat recessed (surface.sunken), no accent stripe
}
LC.sections["decor.detailMeta"] = {
    ["in"]    = "decor.detailCard",
    layout    = "vertical",
    width     = "fill",
    gap       = "xs",   -- tightened from "sm": covers the stored+craftable+tagged case (Wishlist now lives in the note column)
    order     = 10,
}
LC.sections["decor.noteCard"] = {
    ["in"]    = "decor.detailCardRow",
    layout    = "vertical",
    -- top=0: Wishlist button sits tight to the card top; gap "sm" gives a clean
    -- sm break between the button and the note well below it.
    padding   = { top = 0, right = "sm", bottom = "sm", left = "sm" },
    gap       = "sm",
    width     = 220,
    order     = 20,
    -- No chrome: the editbox IS the recessed well (EditBox skinner -> surface.sunken).
    -- chrome="card" wrongly gave a plain input the flat-detail accent bar.
}
LC.sections["decor.detailNote"] = {
    ["in"]    = "decor.noteCard",
    layout    = "vertical",
    width     = "fill",
    order     = 10,
}
-- Full-width special-widget row under the detail cards. Every child gates on
-- decor.fortune.visible, so the section collapses to nothing for normal items
-- (no chrome/padding). Hosts the Sargle's Fortunes tracker (DecorWidgets special).
LC.sections["decor.fortuneRow"] = {
    ["in"]    = "decor.detailBody",
    layout    = "vertical",
    gap       = "xs",
    height    = 40,   -- FIXED: a height-less section is treated as "fill" (flex) and would
                      -- steal half of detailBody's slack from the detail cards. 40px fits the
                      -- 2-line block (header 14 + cells 18 + gap).
    order     = 25,
    visible   = "decor.fortune.visible",   -- collapses entirely for non-special items
}
-- (Dye variant strip removed: dye variants are already surfaced as the dye-dots
-- on browser rows, and the in-card swatch preview was a non-functional stub.)

-- ===== Widgets -- static =====================================================
LC.widgets["decorLoadingPanel.loadingLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorLoadingPanel",
    text = "locale:DECOR_LOADING",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22,
    order = 10,
}
-- Retry affordance: a wedged sweep (nil/0-entry dead end) only recovers on a
-- re-kick, and a view switch is the retry gesture (_OnViewChange loading arm).
LC.widgets["decorLoadingPanel.retryHint"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "decorLoadingPanel",
    text = "locale:DECOR_LOADING_RETRY",
    font = "small", justifyH = "CENTER",
    width = "fill", height = 14,
    order = 20,
}

-- Error data state: amber blip + headline + sub-line (semantic.warning tone).
LC.widgets["decorErrorPanel.icon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "decorErrorPanel",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "semantic.warning",
    width = 24, height = 24, order = 5,
}
LC.widgets["decorErrorPanel.headline"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorErrorPanel",
    role = "TextWarning",
    text = "locale:DECOR_ERROR_HEADLINE",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 10,
}
LC.widgets["decorErrorPanel.sub"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorErrorPanel",
    role = "TextDim",
    text = "locale:DECOR_ERROR_SUB",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 20,
}

-- No-results data state: dim blip + dim message (low-emphasis, not an error).
LC.widgets["decorBlankPanel.icon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "decorBlankPanel",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 5,
}
LC.widgets["decorBlankPanel.label"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorBlankPanel",
    role = "TextDim",
    text = "locale:DECOR_BLANK",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22,
    order = 10,
}

LC.widgets["decorPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorPanel", slot = "header",
    text = "locale:DECOR_BROWSER_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["decorPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "decorPanel", slot = "header",
    width = "fill", height = 14, order = 50,
}
-- Mouse hints: right-click-to-favorite has no affordance until favorited, so hint surfaces it.
LC.widgets["decorPanel.clickHints"] = {
    tooltip = false,   -- self-owned tooltip composed from leftText/rightText
    kind = "clickHints", ["in"] = "decorPanel", slot = "header",
    leftText  = "locale:DECOR_HINT_LEFT",
    rightText = "locale:DECOR_HINT_RIGHT",
    shiftText = "locale:DECOR_HINT_SHIFT",
    ctrlText  = "locale:DECOR_HINT_CTRL",
    width = 34, height = 16, order = 90,
}
-- Uncollected toggle in the browser header (moved here from the filter row), left
-- of the mouse hints. tertiary so it tints with the active scheme like the rest.
LC.widgets["decorPanel.onlyUncollectedToggle"] = {
    tooltip = false,
    kind = "button", ["in"] = "decorPanel", slot = "header", font = "button",
    text = "locale:DECOR_UNCOLLECTED", width = "auto", height = 20, order = 60, variant = "tertiary",
    binding = { active = "decor.onlyUncollected" },
    toggle = "onlyUncollected",
}
-- Ownership ratio + filtered count, below the list (diag.info tone).
LC.widgets["decorPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "decor.statusRail",
    text = "", font = "small", justifyH = "LEFT",
    width = "fill", height = 14, order = 10,
    binding = "decor.headerLabel",
}
-- Sort, right of the count line: a single-pick menu button.
LC.widgets["decorPanel.sortDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "decor.statusRail", variant = "menu", font = "small",
    width = 110, height = 16, order = 20,
    placeholder     = "locale:DECOR_SORT_NAME",
    selectionPrefix = "locale:DECOR_SORT_PREFIX",
    binding      = { menu = "decor.sortMenuItems", current = "decor.sort" },
    setTransient = { view = "decor", key = "sort" },
}

-- ===== Filter strip, top row ==================================================
-- Decor | Pets: which list the tab shows. Wired in Controller_Decor.
for i, mode in ipairs({ "decor", "pets" }) do
    LC.widgets["decorPanel.mode_" .. mode] = {
        tooltip = false,
        kind = "button", ["in"] = "decor.filterRowTop", font = "button",
        text = "locale:DECOR_MODE_" .. mode:upper(), width = "auto", height = 22, order = i, variant = "tertiary",
        binding = { active = "decor.isMode_" .. mode },
        view = mode,
    }
end
LC.widgets["decorPanel.search"] = {
    search = true,   -- magnifier + clear "x", as Recipe Sources (Vamoose, 2026-10-26)
    tooltip = false,
    -- Fills what the row's buttons leave, so the row cannot outgrow the strip.
    kind = "editbox", ["in"] = "decor.filterRowTop", font = "body",
    height = 22, width = "fill", order = 10,
    multiline = false,
    placeholder = "locale:DECOR_SEARCH_PLACEHOLDER",
    -- Its placeholder names decor, so pets mode swaps in petPanel.search instead.
    -- Both write session.ui.decor.searchQuery, so the query survives the switch.
    -- Bound back from state so a jump from another window (UI_FILTER_RESET)
    -- clears the box it can't reach.
    binding = { text = "decor.filterQuery" },
    visible = "decor.showDecorDetail",
}
-- "?": what the search box reads, with examples. A tooltip, nothing to click.
LC.widgets["decorPanel.searchHelp"] = {
    tooltip = { recipe = "DecorSearchHelp" },
    kind = "button", ["in"] = "decor.filterRowTop", font = "button",
    text = "?", width = 22, height = 22, order = 15, variant = "tertiary",
    visible = "decor.showDecorDetail",
}
-- Clear all: every tick, the search box and the Destroy list. Always visible, the
-- row's one primary button at the row's full height, and lit while there is
-- something to clear (owner 2026-11-22: "more prominent and larger").
-- Wired in Controller_Decor -> UI_FILTER_RESET{tab="decor"}.
LC.widgets["decorPanel.resetFilters"] = {
    tooltip = false,
    kind = "button", ["in"] = "decor.filterRowTop", font = "subheading",
    text = "locale:DECOR_CLEAR_ALL", width = 96, height = 25, order = 20, variant = "primary",
    binding = { active = "decor.filterActive" },
}
-- Match: Every filter | Best first (session.ui.decor.match). Wired in Controller_Decor.
LC.widgets["decorPanel.matchLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.filterRowTop", font = "caption",
    text = "locale:DECOR_MATCH_LABEL", width = "auto", height = 22, order = 30,
    visible = "decor.showDecorDetail",
}
for i, match in ipairs({ "all", "best" }) do
    LC.widgets["decorPanel.match_" .. match] = {
        tooltip = { recipe = "DecorMatch_" .. match },
        kind = "button", ["in"] = "decor.filterRowTop", font = "button",
        text = "locale:DECOR_MATCH_" .. match:upper(), width = "auto", height = 22, order = 30 + i, variant = "tertiary",
        binding = { active = "decor.isMatch_" .. match },
        axis = match,
        visible = "decor.showDecorDetail",
    }
end

-- ===== Filter strip, the two rows of menus ====================================
-- One menu button per Constants.DECOR_FILTER_MENUS entry: any number of ticks in
-- any number of menus. A tick dispatches DECOR_TOGGLE_FILTER; the menu's first
-- row clears it. `scroll = false` on the Type menu: see DECOR_FILTER_MENUS.
local ROW_SECTION = { "decor.filterRowWhat", "decor.filterRowLooks" }
local ROW_LABEL   = { "locale:DECOR_ROW_WHAT", "locale:DECOR_ROW_LOOKS" }
for row, section in ipairs(ROW_SECTION) do
    LC.widgets["decorPanel.filterRowLabel_" .. row] = {
        tooltip = false,
        kind = "label", ["in"] = section, font = "caption",
        text = ROW_LABEL[row], width = 38, height = 22, order = 1,
        visible = "decor.showDecorDetail",
    }
end
for i, menu in ipairs(HDG.Constants.DECOR_FILTER_MENUS) do
    local section = ROW_SECTION[menu.row]
    if menu.gap then
        LC.widgets["decorPanel.filterMenuGap_" .. menu.id] = {
            tooltip = false, kind = "spacer", ["in"] = section,
            width = 6, height = 22, order = i * 10 - 5,
            visible = "decor.showDecorDetail",
        }
    end
    LC.widgets["decorPanel.filterMenu_" .. menu.id] = {
        tooltip = false,
        kind = "dropdown", ["in"] = section, variant = "menu", multi = true, font = "button",
        width = "auto", height = 22, order = i * 10,
        placeholder = "locale:" .. menu.label,
        -- What the menu reads when it opens: named, not bound, so twenty menus'
        -- rows are not built for a tab on which none is open.
        rows     = "decor.filterMenu_" .. menu.id,
        ticks    = "decor.filterTicks",
        counts   = "decor.filterCounts_" .. menu.id,
        scroll   = not menu.tree,
        -- What the closed button shows: how many of its menu's values are ticked.
        binding  = { count = "decor.filterMenuCount_" .. menu.id },
        dispatch = { type = "DECOR_TOGGLE_FILTER", payloadKey = "tick" },
        visible = "decor.showDecorDetail",
    }
end

-- ===== Chips ==================================================================
-- One chip per tick; a click removes it. The strip publishes its wrapped height
-- (Controller_Decor), which sizes its row.
LC.widgets["decorChipsPanel.chips"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "decor.chips",
    cellKind = "decorFilterChip",
    width = "fill", height = "fill", order = 10,
    binding = "decor.filterChips",
}

LC.widgets["decorPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "decor.list",
    binding = "decor.items",
    rowKind  = "decorRow",
    spacing  = 1,
    -- SelectionBehaviorMixin owns highlight (O(2) rows vs O(visible)).
    -- Controller_Decor syncs to Store.selectedItemID after data refreshes.
    selection = { deselectable = false },
    order = 10,
}

-- ===== Decor detail pane widgets =============================================

-- Title: selected item name (falls back to "Click an item").
-- Fills the header, so the background picker and the expansion badge sit at the
-- right and a long name is cut rather than pushed under them.
LC.widgets["decorDetailPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorDetailPanel", slot = "header",
    text = "locale:DECOR_CLICK_AN_ITEM", font = "heading",
    height = 18, width = "fill", order = 10,
    binding = "decor.selectedItem.name",
}
-- Preview-background picker, right above the preview it sets (it sat in the
-- filter strip until the filter menus took the strip). Self-wired dropdown,
-- config-theme pattern.
LC.widgets["decorDetailPanel.previewBgDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "decorDetailPanel", slot = "header",
    width = 150, height = 25, order = 15,   -- 25: the WowStyle2 template's native height
    placeholder     = "locale:DECOR_BG_PLACEHOLDER",
    selectionPrefix = "locale:DECOR_BG_PREFIX",
    binding   = { menu = "decor.previewBgMenuItems", current = "decor.previewBg" },
    setConfig = { key = "decorPreviewBg" },
}
-- Expansion badge (right). Lore colors baked into the selector's returned string.
LC.widgets["decorDetailPanel.headerExpansion"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorDetailPanel", slot = "header",
    text = "", font = "small", justifyH = "RIGHT",
    height = 14, width = "auto", order = 20,
    binding = "decor.selectedItem.headerExpansion",
}
-- 3D model preview. Dispatcher calls HDG.HousingCatalogObserver:Resolve (keeps selectors pure).
LC.widgets["decorDetailPanel.itemPreview"] = {
    tooltip = false,
    kind = "modelPreview", ["in"] = "decor.previewSlot",
    order = 10,
    binding = { itemID = "decor.selectedItemID", variantKey = "decor.selectedVariantKey", bg = "decor.previewBg" },
    showControls = true,
    showCorbels  = false,                            -- corner corbels off (parchment chrome retired)
    showAtlas    = false,                            -- parchment off; bgTile is the backdrop now
    bgTile         = true,                           -- ported VDS dark tiling backdrop (the "default" bg)
    configurableBg = true,                           -- preview-bg dropdown overrides the tile with an atlas
    placeholder  = "locale:DECOR_PREVIEW_PLACEHOLDER",
    -- sceneInsets: declarative budget; build fn has no fallback by design.
    sceneInsets    = { top = 2, right = 2, bottom = 2, left = 2 },
    defaultSceneID = 859,   -- HOUSING_CATALOG_DECOR_MODELSCENEID_DEFAULT (12.0.5)
}
-- Best first: how the selected decor fits the ticked filters ("Fits 3 of 4:
-- misses Colour"). Inside the preview's slot, so it takes its line from the
-- preview while Best first is scoring and nothing from the cards below.
LC.widgets["decorDetailPanel.fitNote"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "decor.previewSlot", font = "small",
    text = "", height = 14, order = 20,
    binding = "decor.selectedItem.fitNote",
    visible = "decor.selectedItem.hasFitNote",
}
-- Detail meta column (left).
LC.widgets["decorDetailPanel.itemCategory"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.detailMeta", font = "small",
    text = "", height = 14, order = 15,
    binding = "decor.selectedItem.categoryLabel",
}
LC.widgets["decorDetailPanel.itemProfession"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.detailMeta", font = "small",
    text = "", height = 14, order = 17,
    binding = "decor.selectedItem.profession",
    visible = "decor.selectedItem.isCrafted",
}
-- Where the RECIPE comes from, directly under the profession that makes it.
-- Wrapped like itemSource below: "Profession Trainer -- Classic Alchemy (25)"
-- plus a zone routinely outruns the ~284px column. Gated on isCrafted so the
-- row does not reserve height on a vendor-bought piece; the selector ALSO
-- returns "" when there is no acquisition text, so a crafted piece the server
-- says nothing about collapses too.
LC.widgets["decorDetailPanel.itemRecipeSource"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.detailMeta", font = "small",
    text = "", wrap = true, height = 28, order = 18,
    binding = "decor.selectedItem.recipeSource",
    visible = "decor.selectedItem.isCrafted",
}
LC.widgets["decorDetailPanel.itemSource"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.detailMeta", font = "small",
    -- wrap + 2-line height: source is the richest meta line (gate chips + vendor
    -- + location) and routinely exceeds the ~284px column. Wrapping shows it in
    -- full instead of truncating the location, and the overflow check skips
    -- wrap-enabled labels. (auto-height isn't supported for wrapped FontStrings.)
    text = "", wrap = true, height = 28, order = 20,
    binding = "decor.selectedItem.sourceLabel",
}
LC.widgets["decorDetailPanel.itemStatus"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.detailMeta", font = "small",
    text = "", height = 14, order = 30,
    binding = "decor.selectedItem.statusLabel",
}
LC.widgets["decorDetailPanel.itemTags"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.detailMeta", font = "small",
    text = "", height = 14, order = 40,
    binding = "decor.selectedItem.tagsLabel",
    visible = "decor.selectedItem.hasTags",
}
-- Destroy button: visible when Stored filter + destroyable item selected.
LC.widgets["decorDetailPanel.destroyBtn"] = {
    tooltip = { recipe = "DecorDestroy" },
    kind = "button", ["in"] = "decor.detailMeta", font = "small",
    text = "locale:DECOR_DESTROY_BTN", width = "auto", height = 22,
    order = 45, variant = "tertiary",
    textTone = "error",
    visible = "decor.showDestroyButton",
}
-- Detail action row (note column, above the note editbox): + Cart / Map / Waypoint sharing
-- the width. Map + Waypoint reuse Shop-by-Vendor's actions against the decor's primary vendor
-- and hide when there's no mappable vendor, leaving + Cart to fill the row.
LC.sections["decor.detailActionRow"] = {
    ["in"]  = "decor.noteCard",
    layout  = "horizontal",
    height  = 22,
    gap     = "xs",
    order   = 5,
}
-- + Cart: adds the selected item with no vendor (npcID=nil), so it lands in the
-- Wishlist section (or Crafting / Auction House when crafted). Wired in HDGR_Controller_Decor.
LC.widgets["decorDetailPanel.cartBtn"] = {
    tooltip = { recipe = "CartAdd" },
    kind = "button", ["in"] = "decor.detailActionRow", font = "small",
    text = "locale:CART_ADD_BTN", width = "fill", height = 22,
    order = 10, variant = "tertiary",
    visible = "decor.hasSelectedItem",
}
-- Show on Map / Waypoint: same actions as Shop by Vendor, on the decor's map vendor
-- (first with a location, your faction first). Shown for any vendor-sold piece; greyed
-- with a why-tooltip when no vendor has a location yet (owner 2026-10-15).
LC.widgets["decorDetailPanel.showOnMapBtn"] = {
    tooltip = { recipe = "DecorVendorMap" },
    kind = "button", ["in"] = "decor.detailActionRow", font = "small",
    text = "locale:DECOR_MAP_BTN", width = "fill", height = 22,
    order = 20, variant = "tertiary",
    visible = "decor.selectedItemHasVendor",
    binding = { enabled = "decor.selectedItemHasVendorWaypoint" },
}
LC.widgets["decorDetailPanel.waypointBtn"] = {
    tooltip = { recipe = "DecorVendorWay" },
    kind = "button", ["in"] = "decor.detailActionRow", font = "small",
    text = "locale:DECOR_WAYPOINT_BTN", width = "fill", height = 22,
    order = 30, variant = "tertiary",
    visible = "decor.selectedItemHasVendor",
    binding = { enabled = "decor.selectedItemHasVendorWaypoint" },
}
-- Quest steps (R4, pick D, owner 10-30): Decor Quests on this decor, its steps on screen. A
-- full-width row of its own under the action row (its three buttons fill the column); only
-- for a decor a quest gives.
LC.widgets["decorDetailPanel.questStepsBtn"] = {
    tooltip = { recipe = "DecorQuestSteps" },
    kind = "button", ["in"] = "decor.noteCard", font = "small",
    text = "locale:DQ_QUEST_STEPS_BTN", width = "fill", height = 22,
    order = 6, variant = "tertiary",
    visible = "decorQuests.decorTabHasSteps",
}
-- Find similar: the selected piece's own words become the filters, the closest
-- fits first (DECOR_FIND_SIMILAR). Wired in HDGR_Controller_Decor.
LC.widgets["decorDetailPanel.findSimilarBtn"] = {
    tooltip = { recipe = "DecorFindSimilar" },
    kind = "button", ["in"] = "decor.noteCard", font = "small",
    text = "locale:DECOR_FIND_SIMILAR", width = "fill", height = 22,
    order = 7, variant = "tertiary",
    visible = "decor.hasSelectedItem",
}
-- Note editbox column (right, 220px; height fills parent).
LC.widgets["decorDetailPanel.note"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "decor.detailNote", font = "body",
    height = "fill", width = "fill", order = 10,
    multiline   = true,
    placeholder = "locale:DECOR_NOTE_PLACEHOLDER",
    binding = { text = "decor.selectedItem.note" },
}

-- Sargle's Fortunes tracker (DecorWidgets special). All three gate on
-- decor.fortune.visible -> the row is empty (collapsed) for normal items.
-- Cells = a single colored label (green owned / dim missing), see decor.fortune.cells.
LC.widgets["decorDetailPanel.fortuneHeader"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.fortuneRow", font = "small",
    text = "", height = 14, order = 10,
    binding = "decor.fortune.header",
    visible = "decor.fortune.visible",
}
LC.widgets["decorDetailPanel.fortuneCells"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.fortuneRow", font = "body",
    text = "", height = 18, order = 20,
    binding = "decor.fortune.cells",
    visible = "decor.fortune.visible",
}

-- "Destroy decor" chip: textTone="error" telegraphs the destructive intent.
-- (The Uncollected toggle moved to the Decor Browser header -- decorPanel.onlyUncollectedToggle.)
LC.widgets["decorPanel.onlyStoredToggle"] = {
    tooltip = { recipe = "DecorStoredFilter" },
    kind = "button", ["in"] = "decor.filterRowTop", font = "button",
    text = "locale:DECOR_DESTROY_TOGGLE", width = "auto", height = 22, order = 70, variant = "tertiary",
    textTone = "error",
    binding = { active = "decor.onlyStored" },
    toggle = "onlyStored",
    -- Lives in the SHARED filter row, so it needs its own gate: destroying has no
    -- meaning for pets, which are collection entries rather than stored copies.
    visible = "decor.showDecorBrowser",
}
