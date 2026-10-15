-- HDGR_LayoutConfig_Acquisition.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Acquisition tab layout: 2-column master/detail.
--   acquisitionListPanel  (list, col 1) -- vendor/item list with filters
--   acquisitionDetailPanel (detail, col 2) -- vendor or item detail
--
-- Dynamic widget blocks (generated at load time):
--   acquisitionListPanel.tag_<axis>    (from ACTIVE_FILTER_TAGS)
--   acquisitionListPanel.preset_<value> (from HDG.Constants.ACQ_PRESETS)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================
-- 2-column master/detail. Detail panel holds unified info + 3D preview + alsoSells grid.

LC.window.views.acquisition = {
    explicit = true,
    width    = "auto",       -- 4 + 480 + 4 + 480 + 4 = 972
    height   = "auto",       -- chrome + status now come from the window's slots
    columns  = { 480, 480 },
    rows     = { 650 },       -- chrome/status rows removed (HDG-ADR-025 slots)
    cells    = {
        list   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        detail = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

-- Acquisition: master list (left) + detail pane (right).
LC.panels.acquisitionListPanel = {
    kind = "panel",
    cell = { acquisition = "list" },
    visibleInViews = { "acquisition" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}
LC.panels.acquisitionDetailPanel = {
    kind = "panel",
    cell = { acquisition = "detail" },
    visibleInViews = { "acquisition" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections -- list panel ================================================

LC.sections["acq.listBody"] = {
    ["in"] = "acquisitionListPanel",
    layout = "vertical",
    padding = "lg",
    gap = "sm",
    order = 10,
}
-- Preset chip strip: source axis single-select (Achieve/Rep/Endeavor/Quest) +
-- vdivider + orthogonal "Missing" checkbox (ANDs with active source).
LC.sections["acq.presetStrip"] = {
    ["in"] = "acq.listBody",
    layout = "horizontal",
    height = 22,
    gap = "sm",
    order = 7,
}
-- SECOND CHIP ROW: the "what can I just go and buy" axis, kept off row 1 rather
-- than appended to it. Row 1 already carries five chips, a divider and the
-- Missing checkbox and has no room; and the two rows ask different questions --
-- row 1 is how you EARN a thing, row 2 is what needs nothing earned at all.
-- A sibling section, not anchors: the panel owns the flow (cookbook 14).
LC.sections["acq.presetStrip2"] = {
    ["in"] = "acq.listBody",
    layout = "horizontal",
    height = 22,
    gap = "sm",
    order = 8,
}
LC.sections["acq.filterBar"] = {
    ["in"] = "acq.listBody",
    layout = "horizontal",
    height = 26,
    gap = "md",
    order = 10,
}
-- Advanced filters: toggle row (always visible) + collapsible body (reads acq.advancedFiltersOpen).
LC.sections["acq.advancedToggleRow"] = {
    ["in"] = "acq.listBody",
    layout = "horizontal",
    height = 22,
    gap = "sm",
    order = 12,
}
-- Fixed height: 22px*2 rows + gaps + padding ~= 60px. chrome="inset" groups the dropdowns visually.
LC.sections["acq.advancedFilters"] = {
    ["in"] = "acq.listBody",
    layout = "vertical",
    padding = "sm",
    gap = "sm",
    order = 14,
    height = 60,
    chrome = "inset",
    visible = "acq.advancedFiltersOpen",
}
-- Expansion / Zone / Rep dropdowns side by side.
LC.sections["acq.advancedDropdownRow"] = {
    ["in"] = "acq.advancedFilters",
    layout = "horizontal",
    height = 22,
    gap = "md",
    order = 10,
}
-- Second row: Source dropdown.
LC.sections["acq.advancedSourceRow"] = {
    ["in"] = "acq.advancedFilters",
    layout = "horizontal",
    height = 22,
    gap = "md",
    order = 12,
}
-- Active filters row: label + per-axis tag chips (hidden when axis is default).
LC.sections["acq.activeFiltersRow"] = {
    ["in"] = "acq.listBody",
    layout = "horizontal",
    height = 20,
    gap = "sm",
    order = 16,
}
LC.sections["acq.list"] = {
    ["in"] = "acq.listBody",
    layout = "fill",
    order = 20,
    chrome = "inset",
    visible = "acq.hasResults",   -- hide the well on no-results; blank labels take over
}
-- No-results messages: per-mode siblings of the list well; shown when empty.
LC.widgets["acquisitionListPanel.blankVendorIcon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "acq.listBody",
    visible = "acq.blankVendor",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 25,
}
LC.widgets["acquisitionListPanel.blankVendor"] = {
    tooltip = false,
    kind = "label", ["in"] = "acq.listBody",
    visible = "acq.blankVendor",
    role = "TextDim",
    text = "locale:ACQ_BLANK_VENDOR",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 30,
}
LC.widgets["acquisitionListPanel.blankItemIcon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "acq.listBody",
    visible = "acq.blankItem",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 26,
}
LC.widgets["acquisitionListPanel.blankItem"] = {
    tooltip = false,
    kind = "label", ["in"] = "acq.listBody",
    visible = "acq.blankItem",
    role = "TextDim",
    text = "locale:ACQ_BLANK_ITEM",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 31,
}

-- ===== Sections -- detail panel ==============================================

-- Vendor-view + item-view regions stack into acq.detailBody;
-- mutually exclusive via acq.isViewMode_vendor / acq.isViewMode_item.
LC.sections["acq.detailBody"] = {
    ["in"] = "acquisitionDetailPanel",
    layout = "vertical",
    padding = "lg",
    gap = "md",
    order = 10,
}

-- ===== Item-view detail regions ==============================================
-- Vertically stacked: info-box / preview-box / vendor header / vendor list.

LC.sections["acq.itemInfoBox"] = {
    ["in"]   = "acq.detailBody",
    layout   = "vertical",
    padding  = "md",
    gap      = "xs",
    height   = 160,                  -- name(18) + ribbon(50) + source(42) + cart(22) + gaps
    order    = 31,
    chrome   = "inset",              -- flat recessed (surface.sunken), no accent stripe
    visible  = "acq.isViewMode_item",
}
LC.sections["acq.itemInfoCartRow"] = {
    ["in"]   = "acq.itemInfoBox",
    layout   = "horizontal",
    height   = 22,
    order    = 30,
    visible  = "acq.hasSelectedItem",
}
-- Preview box: model render area.
LC.sections["acq.itemPreviewBox"] = {
    ["in"]   = "acq.detailBody",
    layout   = "vertical",
    height   = 330,
    order    = 32,
    chrome   = "inset",
    visible  = "acq.isViewMode_item",
}
LC.sections["acq.itemPreviewSlot"] = {
    ["in"]   = "acq.itemPreviewBox",
    layout   = "vertical",
    width    = "fill",
    height   = "fill",
    order    = 10,
    visible  = "acq.hasSelectedItem",
}
LC.sections["acq.itemVendorHeader"] = {
    ["in"]   = "acq.detailBody",
    layout   = "horizontal",
    height   = 18,                  -- one-line header (count only post-sourceTags unification)
    order    = 34,
    visible  = "acq.isViewMode_item",
}
LC.sections["acq.itemVendorList"] = {
    ["in"]   = "acq.detailBody",
    layout   = "vertical",
    height   = "fill",              -- absorb remaining detailBody space; scrollbox handles overflow
    order    = 36,
    chrome   = "inset",
    visible  = "acq.isViewMode_item",
}

-- ===== Vendor-view detail regions ============================================
-- Stacked top -> bottom in acq.detailBody, all gated by acq.isViewMode_vendor.

LC.sections["acq.vendorNoteRow"] = {
    ["in"]   = "acq.detailBody",
    layout   = "horizontal",
    gap      = "sm",
    height   = 48,                -- 2 lines of body text + padding
    order    = 13,
    visible  = "acq.isViewMode_vendor",
}
LC.sections["acq.itemList"] = {
    ["in"]   = "acq.detailBody",
    layout   = "fill",
    height   = "fill",            -- flex height absorbs slack; without this the
                                  -- scrollbox's intrinsic height (~338px) is
                                  -- counted as fixed -> over-specs detailBody
    order    = 16,
    chrome   = "inset",
    visible  = "acq.isViewMode_vendor",
}
-- 228px: actionCol needs name(42)+detail(72)+cart(20)+3 buttons(66)+gaps ~226px;
-- 200px over-spec'd actionCol (shoved Show on Map into status rail).
LC.sections["acq.mapRow"] = {
    ["in"]   = "acq.detailBody",
    layout   = "horizontal",
    gap      = "xs",
    height   = 228,
    order    = 24,
    visible  = "acq.isViewMode_vendor",
}
LC.sections["acq.mapBody"] = {
    ["in"]    = "acq.mapRow",
    layout    = "vertical",
    width     = 310,              -- matches the current texture render size
    height    = 228,
    order     = 10,
    chrome    = "inset",
}
-- Action column: explicit 150px (panel 464 - map 310 - gap 2 = 152).
-- Explicit width needed: nested fill chains didn't propagate to inner labels -- long names overflowed.
LC.sections["acq.actionCol"] = {
    ["in"]    = "acq.mapRow",
    layout    = "vertical",
    width     = 150,
    height    = 228,
    gap       = "xs",
    order     = 20,
}
-- Selected-item info card. Collapses to 0 when nothing selected;
-- spacer below absorbs slack so action buttons anchor at column bottom.
LC.sections["acq.actionCol.selectedBlock"] = {
    ["in"]    = "acq.actionCol",
    layout    = "vertical",
    padding   = "sm",
    gap       = "xs",
    width     = 150,
    height    = 152,              -- name(42) + detail(72) + cartBtn(20) + padding(8) + gaps(2*3=6)
    order     = 10,
    chrome    = "inset",          -- flat recessed (surface.sunken), no accent stripe
    visible   = "acq.hasSelectedItem",
}
-- Slack absorber: height="fill" keeps action buttons anchored at column bottom.
LC.sections["acq.actionCol.spacer"] = {
    ["in"]    = "acq.actionCol",
    layout    = "vertical",
    width     = 150,
    height    = "fill",
    order     = 15,
}
-- Grid/List view-toggle row: paired horizontally to fit the narrow action column.
LC.sections["acq.actionCol.viewToggles"] = {
    ["in"]    = "acq.actionCol",
    layout    = "horizontal",
    width     = 150,
    height    = 22,
    gap       = "xs",
    order     = 25,
}

-- ===== Widgets -- list panel =================================================

-- Title flips with viewMode ("Vendors" or "Items").
LC.widgets["acquisitionListPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "acquisitionListPanel", slot = "header",
    text = "locale:ACQ_VENDORS_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "acq.listTitle",
}
LC.widgets["acquisitionListPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "acquisitionListPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
LC.widgets["acquisitionListPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "acquisitionListPanel", slot = "header",
    text = "", font = "small", justifyH = "RIGHT",
    width = "auto", height = 14, order = 20,
    binding = "acq.countLabel",
}
LC.widgets["acquisitionListPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "acq.filterBar", font = "body",
    height = 22, width = "fill", order = 10,
    multiline = false,
    placeholder = "locale:ACQ_SEARCH_PLACEHOLDER",
}
LC.widgets["acquisitionListPanel.mapAllBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "acq.filterBar", font = "small",
    text = "locale:ACQ_MAP_VENDORS", width = "auto", height = 22, order = 20, variant = "tertiary",
    binding = { text = "acq.mapAllLabel" },
    visible = "acq.isViewMode_vendor",
}
LC.widgets["acquisitionListPanel.clearPinsBtn"] = {
    tooltip = { recipe = "WarnClearPins" },
    kind = "button", ["in"] = "acq.filterBar", font = "small",
    text = "X", width = "auto", height = 22, order = 30, variant = "tertiary",
    visible = "acq.isViewMode_vendor",
}
-- Faction dropdown: filters vendors by Alliance / Horde / Neutral (sibling of Source dropdown).
LC.widgets["acquisitionListPanel.factionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "acq.advancedSourceRow", variant = "filter", multi = true,
    width = "fill", height = 22, order = 20, minWidth = 130,
    placeholder  = "locale:ACQ_ALL_FACTIONS",
    binding      = { menu = "acq.factionMenuItems", current = "acq.factionFilter" },
    dispatch     = { type = "ACQ_TOGGLE_FACTION", payloadKey = "faction" },
}
-- Advanced-filters toggle: label flips between "+ / - Advanced Filters".
LC.widgets["acquisitionListPanel.advancedToggle"] = {
    tooltip = false,
    kind = "button", ["in"] = "acq.advancedToggleRow", font = "small",
    text = "locale:ACQ_ADVANCED_CLOSED", width = "auto", height = 20, order = 10, variant = "tertiary",
    binding = { text = "acq.advancedFiltersLabel" },
}
-- Reset: clears all filter axes. Wired in Controller_Acquisition.
LC.widgets["acquisitionListPanel.resetFilters"] = {
    tooltip = false,
    kind = "button", ["in"] = "acq.advancedToggleRow", font = "small",
    text = "locale:COMMON_RESET", width = "auto", height = 20, order = 20, variant = "tertiary",
}
-- Per-axis dropdowns: multi-select checkbox menus (clone of Recipes). Each dispatches
-- its ACQ_TOGGLE_* action; the "All X" master entry (isAll) clears the set.
LC.widgets["acquisitionListPanel.expansionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "acq.advancedDropdownRow", variant = "filter", multi = true,
    width = "fill", height = 22, order = 10, minWidth = 130,
    placeholder  = "locale:ACQ_ALL_EXPANSIONS",
    binding      = { menu = "acq.expansionMenuItems", current = "acq.expansionFilter" },
    dispatch     = { type = "ACQ_TOGGLE_EXPANSION", payloadKey = "expansion" },
}
LC.widgets["acquisitionListPanel.zoneDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "acq.advancedDropdownRow", variant = "filter", multi = true,
    width = "fill", height = 22, order = 20, minWidth = 130,
    placeholder  = "locale:ACQ_ALL_ZONES",
    binding      = { menu = "acq.zoneMenuItems", current = "acq.zoneFilter" },
    dispatch     = { type = "ACQ_TOGGLE_ZONE", payloadKey = "zone" },
}
LC.widgets["acquisitionListPanel.repDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "acq.advancedDropdownRow", variant = "filter", multi = true,
    width = "fill", height = 22, order = 30, minWidth = 130,
    placeholder  = "locale:ACQ_ALL_REPS",
    binding      = { menu = "acq.repMenuItems", current = "acq.repFilter" },
    dispatch     = { type = "ACQ_TOGGLE_REP", payloadKey = "rep" },
}
LC.widgets["acquisitionListPanel.sourceDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "acq.advancedSourceRow", variant = "filter", multi = true,
    width = "fill", height = 22, order = 10, minWidth = 130,
    placeholder  = "locale:ACQ_ALL_SOURCES",
    binding      = { menu = "acq.sourceMenuItems", current = "acq.sourceFilter" },
    dispatch     = { type = "ACQ_TOGGLE_SOURCE", payloadKey = "source" },
}
-- Active-filters label: flips between "Active filters:" / "No active filters".
LC.widgets["acquisitionListPanel.activeFiltersLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "acq.activeFiltersRow",
    font = "small", text = "locale:ACQ_NO_ACTIVE_FILTERS", height = 14, order = 10,
    binding = "acq.activeFiltersLabel",
}
-- Two scrollboxes share the same cell (acq.list); Layout's visible resolver picks one.
LC.widgets["acquisitionListPanel.vendorList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "acq.list",
    binding = "acq.vendorRows",
    rowKind   = "acqVendorRow",
    spacing   = 1,
    selection = { deselectable = false },
    order = 10,
    visible = "acq.isViewMode_vendor",
}
LC.widgets["acquisitionListPanel.itemList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "acq.list",
    binding = "acq.items",
    rowKind  = "itemRow",
    spacing  = 1,
    selection = { deselectable = false },
    order = 10,
    visible = "acq.isViewMode_item_decor",
}
-- Find Decor + Recipes preset: flat teaching-scroll list. Reuses the recipe-
-- capable acqVendorItemListRow factory (icon | "Recipe: <name>" | cost). Shares
-- the acq.list cell with itemList/vendorList; the visible gates are exclusive.
LC.widgets["acquisitionListPanel.recipeList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "acq.list",
    binding = "acq.recipeRows",
    rowKind  = "acqVendorItemListRow",
    spacing  = 1,
    selection = { deselectable = false },
    order = 10,
    visible = "acq.isViewMode_item_recipes",
}

-- ===== Widgets -- detail panel ===============================================

-- Panel-header: title (fill, flips per viewMode) + expansion badge (right).
LC.widgets["acquisitionDetailPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "acquisitionDetailPanel", slot = "header",
    text = "locale:ACQ_SELECTED_VENDOR", font = "subheading",
    -- width="fill": title absorbs slack and clips long names gracefully
    -- (auto+headerExpansion overflowed the 460px header on long item names).
    height = 16, width = "fill", order = 10,
    binding = "acq.detailTitle",
}
-- Wowhead button: opens the selected VENDOR on Wowhead. Vendor view only -- in by-item
-- view the header is the item, whose wowhead link lives in the body (itemWowheadBtn);
-- a vendor link there is wrong (drop/quest items have no vendor).
LC.widgets["acquisitionDetailPanel.wowheadBtn"] = {
    tooltip = { recipe = "WowheadLink" },
    kind = "button", ["in"] = "acquisitionDetailPanel", slot = "header", font = "button",
    text = "|TInterface\\AddOns\\HousingDecorGuide\\textures\\wowhead_logo:14:14|t",
    width = 26, height = 22, order = 5, variant = "tertiary",
    visible = "acq.showVendorWowhead",
}
-- Milestone: "N/M items" beside the title, green+checkmark when allCollected.
-- acq.milestoneText composes color/glyph; font="body" pairs with the subheading title.
LC.widgets["acquisitionDetailPanel.milestone"] = {
    tooltip = false,
    kind = "label", ["in"] = "acquisitionDetailPanel", slot = "header",
    text = "", font = "body", justifyH = "LEFT",
    height = 16, width = "auto", order = 12,
    binding = "acq.milestoneText",
}
-- Expansion badge: lore-colored via the selector. width="auto" sizes it to the
-- badge text -- a fixed cap (was 110) wasted ~60px on short names like "Midnight"
-- (right-justified -> empty gap LEFT of the badge), starving the title fill. Auto
-- gives that slack back to the title; long names ("Warlords of Draenor") size full
-- and the title fill clips gracefully instead.
LC.widgets["acquisitionDetailPanel.headerExpansion"] = {
    tooltip = false,
    kind = "label", ["in"] = "acquisitionDetailPanel", slot = "header",
    text = "", font = "subheading", justifyH = "RIGHT",
    height = 16, width = "auto", order = 20,
    binding = "acq.detailExpansion",
}
-- Vendor-action buttons: beside the map in the action column.
-- Greyed, with a why-tooltip, for a vendor with no location yet (owner 2026-10-15).
LC.widgets["acquisitionDetailPanel.waypointBtn"] = {
    tooltip = { recipe = "AcqVendorWay" },
    kind = "button", ["in"] = "acq.actionCol", font = "button",
    text = "locale:ACQ_WAYPOINT", width = "fill", height = 22, order = 20, variant = "tertiary",
    visible = "acq.hasSelectedVendor",
    binding = { enabled = "acq.selectedVendorMappable" },
}
LC.widgets["acquisitionDetailPanel.showOnMapBtn"] = {
    tooltip = { recipe = "AcqVendorMap" },
    kind = "button", ["in"] = "acq.actionCol", font = "button",
    text = "locale:ACQ_SHOW_ON_MAP", width = "fill", height = 22, order = 30, variant = "tertiary",
    visible = "acq.hasSelectedVendor",
    binding = { enabled = "acq.selectedVendorMappable" },
}
-- Vendor note editbox (full row width). Grid/List toggles in acq.actionCol.viewToggles.
LC.widgets["acquisitionDetailPanel.vendorNote"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "acq.vendorNoteRow", font = "body",
    text = "", height = 44, width = "fill", order = 10,
    multiline   = true,
    placeholder = "locale:ACQ_VENDOR_NOTE_PLACEHOLDER",
    binding = { text = "acq.selected.note" },
}
LC.widgets["acquisitionDetailPanel.itemsViewGridBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "acq.actionCol.viewToggles", font = "small",
    text = "locale:ACQ_ITEMS_VIEW_GRID", width = "fill", height = 22, order = 10, variant = "tertiary",
    binding = { active = "acq.isItemsView_grid" },
}
LC.widgets["acquisitionDetailPanel.itemsViewListBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "acq.actionCol.viewToggles", font = "small",
    text = "locale:ACQ_ITEMS_VIEW_LIST", width = "fill", height = 22, order = 20, variant = "tertiary",
    binding = { active = "acq.isItemsView_list" },
}
-- Item-view 3D model preview. Dispatcher resolves itemID via HDG.HousingCatalogObserver.
LC.widgets["acquisitionDetailPanel.itemPreview"] = {
    tooltip = false,
    kind = "modelPreview", ["in"] = "acq.itemPreviewSlot",
    order = 10,
    binding = { itemID = "acq.selectedItemID" },
    showControls = true,
    showCorbels  = false,
    showAtlas    = false,
    bgTile       = true,                             -- ported VDS dark tiling backdrop
    placeholder  = "locale:ACQ_PREVIEW_PLACEHOLDER",
    -- sceneInsets: declarative budget; build fn has no fallback by design.
    sceneInsets    = { top = 8, right = 8, bottom = 8, left = 8 },
    defaultSceneID = 859,   -- HOUSING_CATALOG_DECOR_MODELSCENEID_DEFAULT (12.0.5)
}

-- Item-view info box: name -> ribbon -> gate line -> cart row (Wowhead + Cart+).
LC.widgets["acquisitionDetailPanel.itemInfoName"] = {
    tooltip = false,
    kind = "label", ["in"] = "acq.itemInfoBox", font = "subheading",
    text = "", height = 18, width = "fill", order = 10,
    binding = "acq.selectedItem.name",
}
LC.widgets["acquisitionDetailPanel.itemInfoRibbon"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "acq.itemInfoBox", font = "body",
    text = "", height = 50, width = "fill", order = 20,
    wrap = true,
    justifyV = "TOP",
    binding = "acq.selectedItem.shortRibbonText",
}
-- Gate line: "Gated by: ..." or "Source: ..." acquisition prerequisite (wraps to 2 lines).
LC.widgets["acquisitionDetailPanel.itemInfoSource"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "acq.itemInfoBox", font = "caption",
    text = "", height = 42, width = "fill", order = 25,   -- 3 lines max (REP+QUEST+ACH)
    wrap = true,
    justifyV = "TOP",
    binding = "acq.selectedItem.sourceLine",
}
LC.widgets["acquisitionDetailPanel.itemInfoCartSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "acq.itemInfoCartRow",
    width = "fill", height = 22, order = 5,
}
LC.widgets["acquisitionDetailPanel.itemWowheadBtn"] = {
    tooltip = { recipe = "WowheadLink" },
    kind = "button", ["in"] = "acq.itemInfoCartRow", font = "button",
    text = "|TInterface\\AddOns\\HousingDecorGuide\\textures\\wowhead_logo:14:14|t",
    width = 26, height = 22, order = 8, variant = "tertiary",
    visible = "acq.hasSelectedItem",
}
LC.widgets["acquisitionDetailPanel.itemInfoCartBtn"] = {
    tooltip = { recipe = "CartAdd" },
    kind = "button", ["in"] = "acq.itemInfoCartRow", font = "small",
    text = "locale:CART_ADD_BTN", width = "auto", height = 22, order = 10, variant = "tertiary",
    visible = "acq.hasSelectedItem",
}
-- Vendor list header ("Available from (N)"). Height 18 (was 32) -- phantom space
-- below was pushing the vendor list down; shrunk after sourceTags unification.
LC.widgets["acquisitionDetailPanel.itemVendorHeaderLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "acq.itemVendorHeader", font = "body",
    text = "", height = 18, width = "fill", order = 10,
    justifyV = "TOP",
    binding = "acq.selectedItem.availableFromLabel",
}
-- Vendor list scrollbox (acqItemVendorRow: name + zone + cost + rep chip + Wpt/Map).
LC.widgets["acquisitionDetailPanel.itemVendorListBox"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "acq.itemVendorList",
    binding = "acq.selectedItem.vendors",
    rowKind  = "acqItemVendorRow",
    spacing  = 2,
    order = 10,
}

-- Vendor-view subtitle: zone, faction, coords. role = "Text" explicit --
-- was {"dim"} which was nearly unreadable against the dark panel background.
LC.widgets["acquisitionDetailPanel.headerLine"] = {
    tooltip = false,
    kind = "label", role = "Text", ["in"] = "acq.detailBody", font = "body",
    text = "", height = 16, width = "fill", order = 12,
    binding = "acq.selected.headerLine",
    visible = "acq.isViewMode_vendor",
}
-- Items area: cardGrid (grid mode) or scrollbox (list mode).
LC.widgets["acquisitionDetailPanel.itemTiles"] = {
    tooltip = false,
    kind = "cardGrid", ["in"] = "acq.itemList",
    binding = "acq.selected.items",
    cellKind    = "acqVendorItemTile",
    cellsPerRow = 7,
    cellSize    = 64,
    order = 10,
    visible = "acq.isItemsView_grid",
}
LC.widgets["acquisitionDetailPanel.itemList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "acq.itemList",
    binding = "acq.selected.listRows",   -- items + interleaved recipe rows
    rowKind = "acqVendorItemListRow",
    spacing = 1,
    order = 10,
    visible = "acq.isItemsView_list",
}
-- Vendor-view map widget (left side of acq.mapRow).
LC.widgets["acquisitionDetailPanel.vendorMap"] = {
    tooltip = false,
    kind = "vendorMap", ["in"] = "acq.mapBody",
    order = 10,
    binding = { mapPoint = "acq.selected.mapPoint" },
}
-- SELECTED block: visibility cascades from the section -- child widgets ride the collapse.
LC.widgets["acquisitionDetailPanel.selectedName"] = {
    tooltip = false,
    kind = "label", ["in"] = "acq.actionCol.selectedBlock", font = "body",
    text = "", height = 42, width = 138, order = 10,    -- explicit width (fill didn't
    wrap = true,                                        -- explicit width; fill didn't propagate -> long names overflowed
    justifyV = "TOP",
    binding = "acq.selectedItem.name",
}
LC.widgets["acquisitionDetailPanel.selectedDetail"] = {
    tooltip = false,
    kind = "label", ["in"] = "acq.actionCol.selectedBlock", font = "caption",
    text = "", height = 72, width = 138, order = 20,   -- explicit width (fill didn't propagate);
    wrap = true,                                       -- explicit width; fill didn't propagate
    justifyV = "TOP",
    binding = "acq.selectedItem.compactDetail",
}
-- Cart+: adds selected item to active shopping list. Wired in HDGR_Controller_Acquisition.
LC.widgets["acquisitionDetailPanel.selectedAddToCartBtn"] = {
    tooltip = { recipe = "CartAddVendor" },
    kind = "button", ["in"] = "acq.actionCol.selectedBlock",
    font = "small", text = "locale:CART_ADD_BTN", width = "fill", height = 20,
    order = 30, variant = "tertiary",
}

-- ===== Widgets -- dynamic (generated at load time) ===========================

-- Active-filter tags: one chip per axis, visible when filter is active.
-- ACTIVE_FILTER_TAGS is canonical -- one entry + selector triple + click handler per new axis.
local ACTIVE_FILTER_TAGS = {
    { axis = "search",    visibleSel = "acq.hasSearchFilter",    textSel = "acq.tagSearch"    },
    { axis = "faction",   visibleSel = "acq.hasFactionFilter",   textSel = "acq.tagFaction"   },
    { axis = "expansion", visibleSel = "acq.hasExpansionFilter", textSel = "acq.tagExpansion" },
    { axis = "zone",      visibleSel = "acq.hasZoneFilter",      textSel = "acq.tagZone"      },
    { axis = "rep",       visibleSel = "acq.hasRepFilter",       textSel = "acq.tagRep"       },
    { axis = "preset",    visibleSel = "acq.hasPresetFilter",    textSel = "acq.tagPreset"    },
    { axis = "missing",   visibleSel = "acq.hasMissingFilter",   textSel = "acq.tagMissing"   },
    { axis = "source",    visibleSel = "acq.hasSourceFilter",    textSel = "acq.tagSource"    },
}
for i, tag in ipairs(ACTIVE_FILTER_TAGS) do
    LC.widgets["acquisitionListPanel.tag_" .. tag.axis] = {
    tooltip = false,
        kind = "button", ["in"] = "acq.activeFiltersRow", font = "caption",
        text = "", width = "auto", height = 16, order = 20 + i, variant = "chip",
        binding = { text = tag.textSel },
        visible = tag.visibleSel,
        axis = tag.axis,
    }
end
LC._activeFilterTags = ACTIVE_FILTER_TAGS

-- Acquire preset chips: single-select. Generated from ACQ_PRESETS -- add/remove = one-line edit there.
-- `p.row` picks the strip; absent means row 1, so existing entries are untouched.
for i, p in ipairs(HDG.Constants.ACQ_PRESETS or {}) do
    LC.widgets["acquisitionListPanel.preset_" .. p.value] = {
        tooltip = { recipe = "AcqPreset_" .. p.value },
        kind = "button", font = "button",
        ["in"] = (p.row == 2) and "acq.presetStrip2" or "acq.presetStrip",
        text = p.label, width = "auto", height = 22, order = 10 + i, variant = "tertiary",
        binding = { active = "acq.preset.active_" .. p.value },
    }
end
-- Collection axis: vdivider + "Missing" checkbox (orthogonal to source; order 20+ = right of chips).
LC.widgets["acquisitionListPanel.presetDivider"] = {
    tooltip = false,
    kind = "vdivider", ["in"] = "acq.presetStrip",
    width = 1, height = 16, order = 20,
}
LC.widgets["acquisitionListPanel.missingToggle"] = {
    tooltip = { recipe = "AcqMissingToggle" },
    kind = "checkbox", ["in"] = "acq.presetStrip", font = "button",
    text = "locale:ACQ_MISSING_TOGGLE", width = 86, height = 22, order = 21,
    binding = { checked = "acq.missingOnly" },
}
