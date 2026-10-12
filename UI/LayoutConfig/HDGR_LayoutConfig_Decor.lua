-- HDGR_LayoutConfig_Decor.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Decor tab: full-width filter strip above a 2-column browser/detail body.
--   decorFilterPanel  (filter row, span 2) -- search + chips + toggles
--   decorPanel        (body, col 1)        -- browser list
--   decorDetailPanel  (detail, col 2)      -- 3D preview + meta + note cards
--
-- Dynamic widget blocks (generated at load time):
--   decorPanel.topFilter_<value>   (from HDG.Constants.TOP_FILTERS)
--   decorPanel.tagSlot_<slot>      (from HDG.Constants.TAG_SLOT_COUNT)

HDG = HDG or {}
local LC = HDG.LayoutConfig
local FILTER_BAR_HEIGHT  = 89    -- decor filter strip: 3 rows (top chips+BG dropdown 25h, tags row 22h, toggles row 22h)

-- ===== View ==================================================================

LC.window.views.decor = {
    explicit = true,
    width    = "auto",       -- 4 + 360 + 4 + 540 + 4 = 912
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 360, 540 },
    -- chrome/status rows removed per HDG-ADR-025 (window slots provide them).
    rows     = { FILTER_BAR_HEIGHT, 600 },
    cells    = {
        filter = { col = 1, row = 1, colSpan = 2, rowSpan = 1 },
        body   = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
        detail = { col = 2, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

-- Decor filter strip. Full-width so the chip strip has ~900px (360w panel was too narrow).
LC.panels.decorFilterPanel = {
    kind = "panel",
    cell = { decor = "filter" },
    visibleInViews = { "decor" },
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

-- Filter strip: 3 stacked rows (top chips, tags, search+toggles).
-- One-row layout didn't fit (9 chips ~440px + toggles ~210px vs ~360px available).
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
    height = 25,    -- 25 (was 22) to fit the preview-bg dropdown's native WowStyle2 height
    gap    = "md",
    order  = 10,
}
-- Preview-background picker (top-right of the filter strip). Self-wired dropdown,
-- config-theme pattern; the fill topFilterChips (order 20) pushes it to the right edge.
LC.widgets["decorFilterPanel.previewBgDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "decor.filterRowTop",
    width = 170, height = 25, order = 30,
    placeholder     = "locale:DECOR_BG_PLACEHOLDER",
    selectionPrefix = "locale:DECOR_BG_PREFIX",
    binding   = { menu = "decor.previewBgMenuItems", current = "decor.previewBg" },
    setConfig = { key = "decorPreviewBg" },
}
-- "Filter:" label: same fixed width as "Tags:" below for visual alignment.
LC.sections["decor.filterLabel"] = {
    ["in"]   = "decor.filterRowTop",
    layout   = "horizontal",
    height   = 22,
    width    = 38,
    order    = 5,
}
LC.sections["decor.topFilterChips"] = {
    ["in"] = "decor.filterRowTop",
    layout = "horizontal",
    height = 22,
    width  = "fill",
    gap    = "xs",
    order  = 20,
}
-- Tags row: always rendered so the search box below doesn't bounce when no sub-tags exist.
-- Label + chips inside hide via decor.hasTagsRow; row collapses to empty whitespace.
LC.sections["decor.filterRowMiddle"] = {
    ["in"]   = "decor.filterRow",
    layout   = "horizontal",
    height   = 22,
    gap      = "sm",
    order    = 15,
}
LC.sections["decor.tagsLabel"] = {
    ["in"]   = "decor.filterRowMiddle",
    layout   = "horizontal",
    height   = 22,
    width    = 38,    -- enough for "Tags:" caption
    order    = 5,
    visible  = "decor.hasTagsRow",
}
LC.sections["decor.tagsChips"] = {
    ["in"]   = "decor.filterRowMiddle",
    layout   = "horizontal",
    height   = 22,
    width    = "fill",
    gap      = 0,    -- tightened 2px from "xs"(2) per feedback; numeric escape hatch
    order    = 10,
}
-- Bottom row: search (left) + fill spacer + right-aligned toggles.
LC.sections["decor.filterRowBottom"] = {
    ["in"] = "decor.filterRow",
    layout = "horizontal",
    height = 22,
    gap    = "sm",
    order  = 20,
}
LC.sections["decor.filterBottomSpacer"] = {
    ["in"]   = "decor.filterRowBottom",
    layout   = "horizontal",
    height   = 22,
    width    = "fill",
    order    = 20,
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
LC.widgets["decorPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "decor.filterRowBottom", font = "body",
    height = 22, width = 240, order = 10,
    multiline = false,
    placeholder = "locale:DECOR_SEARCH_PLACEHOLDER",
    -- Its placeholder names decor, so pets mode swaps in petPanel.search instead.
    -- Both write session.ui.decor.searchQuery, so the query survives the switch.
    -- Bound back from state so a jump from another window (UI_FILTER_RESET)
    -- clears the box it can't reach.
    binding = { text = "decor.filterQuery" },
    visible = "decor.showDecorDetail",
}
-- Persistent filter reset: always visible. Wired in Controller_Decor -> UI_FILTER_RESET{tab="decor"}.
LC.widgets["decorPanel.resetFilters"] = {
    tooltip = false,
    kind = "button", ["in"] = "decor.filterRowBottom", font = "small",
    text = "locale:COMMON_RESET", width = "auto", height = 22, order = 15, variant = "tertiary",
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
LC.widgets["decorDetailPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "decorDetailPanel", slot = "header",
    text = "locale:DECOR_CLICK_AN_ITEM", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "decor.selectedItem.name",
}
-- Header spacer pushes expansion badge to the right.
LC.widgets["decorDetailPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "decorDetailPanel", slot = "header",
    width = "fill", height = 14, order = 15,
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
-- Show on Map / Waypoint: same actions as Shop by Vendor, on the decor's primary vendor.
LC.widgets["decorDetailPanel.showOnMapBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "decor.detailActionRow", font = "small",
    text = "locale:DECOR_MAP_BTN", width = "fill", height = 22,
    order = 20, variant = "tertiary",
    visible = "decor.selectedItemHasVendorWaypoint",
}
LC.widgets["decorDetailPanel.waypointBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "decor.detailActionRow", font = "small",
    text = "locale:DECOR_WAYPOINT_BTN", width = "fill", height = 22,
    order = 30, variant = "tertiary",
    visible = "decor.selectedItemHasVendorWaypoint",
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

-- ===== Widgets -- dynamic (generated at load time) ===========================

-- Top filter chips: single-select. SSoT in HDG.Constants.TOP_FILTERS.
-- Clicks -> DECOR_SET_TOP_FILTER (or DECOR_FILTER_RESET for 'all').
for i, entry in ipairs(HDG.Constants.TOP_FILTERS or {}) do
    LC.widgets["decorPanel.topFilter_" .. entry.value] = {
    tooltip = false,
        kind = "button", ["in"] = "decor.topFilterChips", font = "button",
        text = entry.label, width = "auto", height = 22, order = i, variant = "tertiary",
        binding = { active = "decor.topFilter.active_" .. entry.value },
        topFilter = entry.value,
    }
end

-- (Dye variant swatches removed with the variant strip.)

-- "Filter:" label (aligns with "Tags:" below).
LC.widgets["decorPanel.filterLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.filterLabel", font = "caption",
    role = "TextDim",
    text = "locale:DECOR_FILTER_LABEL", width = 38, height = 22, order = 10,
}

-- "Tags:" label: dim; hides with its section via decor.hasTagsRow.
LC.widgets["decorPanel.tagsLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "decor.tagsLabel", font = "caption",
    role = "TextDim",
    text = "locale:DECOR_TAGS_LABEL", width = 38, height = 22, order = 10,
}

-- Tag-row chip slots: N pre-allocated, bound to decor.tagSlot.*. Empty slots hidden via visible.
for slot = 1, (HDG.Constants.TAG_SLOT_COUNT or 12) do
    LC.widgets["decorPanel.tagSlot_" .. slot] = {
    tooltip = false,
        kind = "button", ["in"] = "decor.tagsChips", font = "button",
        width = "auto", height = 22, order = slot, variant = "tertiary",
        visible = "decor.tagSlot.visible_" .. slot,
        binding = {
            text   = "decor.tagSlot.text_"   .. slot,
            active = "decor.tagSlot.active_" .. slot,
        },
        tagSlot = slot,
    }
end

-- "Destroy decor" chip: textTone="error" telegraphs the destructive intent.
-- (The Uncollected toggle moved to the Decor Browser header -- decorPanel.onlyUncollectedToggle.)
LC.widgets["decorPanel.onlyStoredToggle"] = {
    tooltip = { recipe = "DecorStoredFilter" },
    kind = "button", ["in"] = "decor.filterRowBottom", font = "button",
    text = "locale:DECOR_DESTROY_TOGGLE", width = "auto", height = 22, order = 50, variant = "tertiary",
    textTone = "error",
    binding = { active = "decor.onlyStored" },
    toggle = "onlyStored",
    -- Lives in the SHARED filter row, so it needs its own gate: destroying has no
    -- meaning for pets, which are collection entries rather than stored copies.
    visible = "decor.showDecorBrowser",
}
