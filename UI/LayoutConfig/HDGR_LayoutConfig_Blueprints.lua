-- HDGR_LayoutConfig_Blueprints.lua
-- ============================================================================
-- Blueprints tab (Projects child): master-detail. Left = paste field +
-- collection browser; right = inspector (name/code header, house picker,
-- budget meters, fit verdict, missing filter, content groups, action row,
-- guidance strip). Mirrors the projectsLayouts master-detail idiom.

local LC = HDG.LayoutConfig

-- Master-detail: left browser 280 | right inspector 560.
LC.window.views.projectsBlueprints = {
    controllers = { "blueprints" },
    width    = "auto",
    height   = "auto",
    columns  = { 280, 560 },
    rows     = { 600 },
    cells    = {
        list    = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        detail  = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
        -- Library mode spans both columns; the two panels above hide while it
        -- shows (design 2026-09-11, D2).
        library = { col = 1, row = 1, colSpan = 2, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

LC.panels.blueprintsListPanel = {
    kind = "panel",
    cell = { projectsBlueprints = "list" },
    visibleInViews = { "projectsBlueprints" },
    visible = "blueprints.isSubView_inspect",
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" },
            chrome = "PanelHeader",
        },
        body = { layout = "vertical", gap = "sm", padding = "lg" },
    },
}

LC.panels.blueprintsDetailPanel = {
    kind = "panel",
    cell = { projectsBlueprints = "detail" },
    visibleInViews = { "projectsBlueprints" },
    visible = "blueprints.isSubView_inspect",
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" },
            chrome = "PanelHeader",
        },
        body = { layout = "vertical", gap = "sm", padding = "lg" },
    },
}

-- ===== Left: paste + collection browser =====================================

LC.widgets["blueprintsListPanel.titleIcon"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsListPanel", slot = "header",
    text = "|A:common-icons-blueprints:18:18|a", font = "heading", height = 18, width = "auto", order = 3,
}
LC.widgets["blueprintsListPanel.title"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsListPanel", slot = "header",
    text = "locale:BP_TITLE", font = "heading", height = 18, width = "auto", order = 5,
}
LC.widgets["blueprintsListPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "blueprintsListPanel", slot = "header",
    width = "fill", height = 14, order = 8,
}
-- Library: the management mode (design 2026-09-11). The header's only button
-- now that Save moved under the list, so it gets the full right-hand slack.
LC.widgets["blueprintsListPanel.libraryBtn"] = {
    tooltip = { recipe = "BlueprintLibrary" }, kind = "button", ["in"] = "blueprintsListPanel", slot = "header",
    font = "body", text = "locale:BP_LIBRARY", width = 64, height = 22, order = 9,
}

LC.sections["blueprintsListPanel.pasteRow"] = {
    ["in"] = "blueprintsListPanel", layout = "horizontal", height = 22, gap = "sm", order = 5,
}
LC.widgets["blueprintsListPanel.pasteBox"] = {
    tooltip = false, kind = "editbox", ["in"] = "blueprintsListPanel.pasteRow", font = "body",
    height = 22, width = "fill", order = 5, multiline = false,
    placeholder = "locale:BP_PASTE_PLACEHOLDER",
}
LC.widgets["blueprintsListPanel.inspectBtn"] = {
    tooltip = { recipe = "BlueprintInspect" }, kind = "button", ["in"] = "blueprintsListPanel.pasteRow",
    font = "body", text = "locale:BP_INSPECT", width = 64, height = 22, order = 10,
}

-- Collection: pasted & shared first, then the player's saved groups.
LC.widgets["blueprintsListPanel.list"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "blueprintsListPanel",
    binding = "blueprints.collectionRows", rowKind = "blueprintCollectionRow",
    spacing = 1, width = "fill", height = "fill", order = 20,
}

-- Save Blueprint sits under the list, not in the header: the 280px header could
-- not hold title + Library + Save without the buttons over-running, and saving
-- is an action on the list, not on the tab.
LC.sections["blueprintsListPanel.footerRow"] = {
    ["in"] = "blueprintsListPanel", layout = "horizontal", height = 22, gap = "sm", order = 30,
}
-- Link in chat lives bottom-left, opposite Save (owner ruling 2026-09-15): it
-- acts on the selected entry like Save does, and the code row was over-full
-- once Refresh joined it.
LC.widgets["blueprintsListPanel.linkBtn"] = {
    tooltip = { recipe = "BlueprintLink" }, kind = "button", ["in"] = "blueprintsListPanel.footerRow",
    font = "body", text = "locale:BP_LINK_LONG", width = 96, height = 22, order = 3,
    binding = { enabled = "blueprints.hasSelection" },
}
LC.widgets["blueprintsListPanel.footerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "blueprintsListPanel.footerRow", width = "fill", height = 14, order = 5,
}
LC.widgets["blueprintsListPanel.saveBtn"] = {
    tooltip = { recipe = "BlueprintSave" }, kind = "button", ["in"] = "blueprintsListPanel.footerRow",
    font = "body", text = "locale:BP_SAVE", width = 118, height = 22, order = 10,
}

-- ===== Right: inspector ======================================================

-- Header: display name (label; inline rename lands via the name editbox next
-- to it), house picker on the right.
LC.widgets["blueprintsDetailPanel.name"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel", slot = "header",
    binding = "blueprints.displayName", font = "heading", height = 18, width = "fill", order = 5,
}
LC.widgets["blueprintsDetailPanel.housePicker"] = {
    tooltip = { recipe = "BlueprintTargetHouse" }, kind = "dropdown", ["in"] = "blueprintsDetailPanel", slot = "header",
    width = 190, height = 22, order = 10, minWidth = 160,
    placeholder = "locale:BP_PICK_HOUSE",
    binding = { menu = "blueprints.houseMenuItems", current = "blueprints.targetHouse" },
    dispatch = { type = "BLUEPRINT_SET_TARGET_HOUSE", payloadKey = "houseGUID" },
}

-- Code row: the share code verbatim in a quiet read-only editbox (click ->
-- select-all -> Ctrl+C; the standard WoW share-code pattern) + rename box.
LC.sections["blueprintsDetailPanel.codeRow"] = {
    ["in"] = "blueprintsDetailPanel", layout = "horizontal", height = 22, gap = "sm", order = 4,
}
LC.widgets["blueprintsDetailPanel.codeBox"] = {
    tooltip = { recipe = "BlueprintCopyCode" }, kind = "editbox", ["in"] = "blueprintsDetailPanel.codeRow",
    font = "small", height = 20, width = 200, order = 5, multiline = false,
}
-- Refresh: dim while the manifest is current; lit and reworded the moment
-- decor storage changes under it, so a player working through several codes
-- sees "out of date" before they buy off it. Rides the code row (the rename
-- box is the fill slot and gives up the width) rather than its own row.
LC.widgets["blueprintsDetailPanel.refreshBtn"] = {
    tooltip = { recipe = "BlueprintRefresh" }, kind = "button", ["in"] = "blueprintsDetailPanel.codeRow",
    variant = "tertiary", font = "small", width = "auto", height = 20, order = 8,
    binding = { text = "blueprints.refreshText", enabled = "blueprints.manifestStale" },
}
LC.widgets["blueprintsDetailPanel.renameLabel"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.codeRow",
    text = "locale:BP_RENAME_LABEL", font = "small", role = "TextDim",
    width = "auto", height = 14, order = 9,
}
LC.widgets["blueprintsDetailPanel.nameBox"] = {
    tooltip = { recipe = "BlueprintRename" }, kind = "editbox", ["in"] = "blueprintsDetailPanel.codeRow",
    font = "small", height = 20, width = "fill", order = 10, multiline = false,
    placeholder = "locale:BP_NAME_PLACEHOLDER",
}

-- Status line (pending count-up / friendly failure), then fit verdict.
LC.widgets["blueprintsDetailPanel.status"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel",
    binding = "blueprints.statusLine", font = "caption", height = 14, width = "fill", order = 6,
}
-- Fit verdict as a card badge (mockup pill): accent bar + washed fill; the
-- label's text role tones success/blocked in Refresh. Hidden with no verdict.
LC.sections["blueprintsDetailPanel.verdictBand"] = {
    ["in"] = "blueprintsDetailPanel", layout = "horizontal", chrome = "card",
    padding = { top = 2, right = "sm", bottom = 2, left = "sm" },
    height = 22, order = 8, visible = "blueprints.hasVerdict",
}
LC.widgets["blueprintsDetailPanel.verdict"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.verdictBand",
    binding = "blueprints.fitVerdict", font = "body", height = 16, width = "fill", order = 5,
}
-- Cost to build, trailing the verdict: "does it fit?" and "can I afford it?" are
-- the same decision, so they share a band. width="auto" so it takes only what the
-- currencies need and the verdict keeps the slack -- which is why the selector
-- caps how many it shows inline (BLUEPRINT_COST_BADGE_MAX) and the tooltip
-- carries the full list: an uncapped auto-width label walked off the panel edge.
-- Hidden when nothing is left to buy, since a "0" next to "you have everything"
-- reads as a price.
LC.widgets["blueprintsDetailPanel.costBadge"] = {
    tooltip = { recipe = "BlueprintCost" }, kind = "label", ["in"] = "blueprintsDetailPanel.verdictBand",
    binding = "blueprints.costBadge", font = "body", height = 16, width = "auto", order = 10,
    visible = "blueprints.hasCostBadge",
}

-- Budget meters: three text+bar pairs on one row.
LC.sections["blueprintsDetailPanel.meters"] = {
    ["in"] = "blueprintsDetailPanel", layout = "horizontal", height = 34, gap = "lg", order = 10,
}
LC.sections["blueprintsDetailPanel.meterRoomCol"] = {
    ["in"] = "blueprintsDetailPanel.meters", layout = "vertical", width = "fill", gap = "xs", order = 5,
}
LC.widgets["blueprintsDetailPanel.meterRoomText"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.meterRoomCol",
    binding = "blueprints.meterTextRoom", font = "caption", height = 14, width = "fill", order = 5,
}
LC.widgets["blueprintsDetailPanel.meterRoomBar"] = {
    tooltip = { recipe = "BlueprintMeterRoom" }, kind = "progressbar", ["in"] = "blueprintsDetailPanel.meterRoomCol",
    binding = { progress = "blueprints.meterFracRoom" }, width = "fill", height = 8, order = 10,
}
LC.sections["blueprintsDetailPanel.meterIntCol"] = {
    ["in"] = "blueprintsDetailPanel.meters", layout = "vertical", width = "fill", gap = "xs", order = 10,
}
LC.widgets["blueprintsDetailPanel.meterIntText"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.meterIntCol",
    binding = "blueprints.meterTextInterior", font = "caption", height = 14, width = "fill", order = 5,
}
LC.widgets["blueprintsDetailPanel.meterIntBar"] = {
    tooltip = { recipe = "BlueprintMeterInterior" }, kind = "progressbar", ["in"] = "blueprintsDetailPanel.meterIntCol",
    binding = { progress = "blueprints.meterFracInterior" }, width = "fill", height = 8, order = 10,
}
LC.sections["blueprintsDetailPanel.meterExtCol"] = {
    ["in"] = "blueprintsDetailPanel.meters", layout = "vertical", width = "fill", gap = "xs", order = 15,
}
LC.widgets["blueprintsDetailPanel.meterExtText"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.meterExtCol",
    binding = "blueprints.meterTextExterior", font = "caption", height = 14, width = "fill", order = 5,
}
LC.widgets["blueprintsDetailPanel.meterExtBar"] = {
    tooltip = { recipe = "BlueprintMeterExterior" }, kind = "progressbar", ["in"] = "blueprintsDetailPanel.meterExtCol",
    binding = { progress = "blueprints.meterFracExterior" }, width = "fill", height = 8, order = 10,
}
-- Pet decor budgets (12.1): interior + exterior. Narrower than the three main
-- meters (fixed width vs "fill") -- pet budgets are secondary. Sized to fit the
-- widest label "100 / 100": the 12.1 caps rose to 100 interior / 25 exterior, so
-- the old 56px clipped the 3-digit interior value to "0 / 1...".
LC.sections["blueprintsDetailPanel.meterIntPetCol"] = {
    ["in"] = "blueprintsDetailPanel.meters", layout = "vertical", width = 76, gap = "xs", order = 20,
}
LC.widgets["blueprintsDetailPanel.meterIntPetText"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.meterIntPetCol",
    binding = "blueprints.meterTextInteriorPet", font = "caption", height = 14, width = "fill", order = 5,
}
LC.widgets["blueprintsDetailPanel.meterIntPetBar"] = {
    tooltip = { recipe = "BlueprintMeterInteriorPet" }, kind = "progressbar", ["in"] = "blueprintsDetailPanel.meterIntPetCol",
    binding = { progress = "blueprints.meterFracInteriorPet" }, width = "fill", height = 8, order = 10,
}
LC.sections["blueprintsDetailPanel.meterExtPetCol"] = {
    ["in"] = "blueprintsDetailPanel.meters", layout = "vertical", width = 76, gap = "xs", order = 25,
}
LC.widgets["blueprintsDetailPanel.meterExtPetText"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.meterExtPetCol",
    binding = "blueprints.meterTextExteriorPet", font = "caption", height = 14, width = "fill", order = 5,
}
LC.widgets["blueprintsDetailPanel.meterExtPetBar"] = {
    tooltip = { recipe = "BlueprintMeterExteriorPet" }, kind = "progressbar", ["in"] = "blueprintsDetailPanel.meterExtPetCol",
    binding = { progress = "blueprints.meterFracExteriorPet" }, width = "fill", height = 8, order = 10,
}

-- Filter row: segmented All / Missing-only pair + item counts right.
LC.sections["blueprintsDetailPanel.filterRow"] = {
    ["in"] = "blueprintsDetailPanel", layout = "horizontal", height = 22, gap = "sm", order = 15,
}
LC.widgets["blueprintsDetailPanel.filterAll"] = {
    tooltip = false, kind = "button", ["in"] = "blueprintsDetailPanel.filterRow", variant = "tertiary",
    font = "small", text = "locale:BP_FILTER_ALL", width = 76, height = 20, order = 5,
    binding = { active = "blueprints.filterAllActive" },
}
LC.widgets["blueprintsDetailPanel.filterMissing"] = {
    tooltip = { recipe = "BlueprintMissingOnly" }, kind = "button", ["in"] = "blueprintsDetailPanel.filterRow", variant = "tertiary",
    font = "small", text = "locale:BP_FILTER_MISSING", width = 92, height = 20, order = 10,
    binding = { active = "blueprints.filterMissingActive" },
}
LC.widgets["blueprintsDetailPanel.filterSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "blueprintsDetailPanel.filterRow",
    width = "fill", height = 14, order = 15,
}
LC.widgets["blueprintsDetailPanel.counts"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel.filterRow",
    binding = "blueprints.itemCountText", font = "caption", height = 14, width = "auto", order = 20,
}

-- Blank state: first open / nothing selected (UX review #1; Acquisition idiom).
LC.widgets["blueprintsDetailPanel.blankIcon"] = {
    tooltip = false, kind = "atlas", ["in"] = "blueprintsDetailPanel",
    visible = "blueprints.blankDetail",
    atlas = "housing-map-plot-player-house", tone = "text.dim",
    width = 26, height = 26, order = 17,
}
LC.widgets["blueprintsDetailPanel.blank"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel",
    visible = "blueprints.blankDetail", role = "TextDim",
    text = "locale:BP_BLANK", font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 18,
}

-- Content groups (collapsible headers + item rows, flat projection).
LC.widgets["blueprintsDetailPanel.content"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "blueprintsDetailPanel",
    binding = "blueprints.contentRows", rowKind = "blueprintContentRow",
    spacing = 1, width = "fill", height = "fill", order = 20,
}

-- Action row: Route to Shopping | Import as Set | Architect (House/Interior) | Apply to House.
-- All enable only with a selection -- ungated they looked clickable over a blank panel.
LC.sections["blueprintsDetailPanel.actions"] = {
    ["in"] = "blueprintsDetailPanel", layout = "horizontal", height = 22, gap = "sm", order = 30,
}
LC.widgets["blueprintsDetailPanel.routeBtn"] = {
    tooltip = { recipe = "BlueprintRoute" }, kind = "button", ["in"] = "blueprintsDetailPanel.actions",
    font = "body", text = "locale:BP_ROUTE_SHOPPING", width = 120, height = 22, order = 5,
    variant = "primary",   -- the tab's primary CTA (design fact 10; mockup .primary)
    binding = { enabled = "blueprints.hasSelection" },
}
LC.widgets["blueprintsDetailPanel.setBtn"] = {
    tooltip = { recipe = "BlueprintImportSet" }, kind = "button", ["in"] = "blueprintsDetailPanel.actions",
    font = "body", text = "locale:BP_IMPORT_SET", width = 100, height = 22, order = 10,
    binding = { enabled = "blueprints.hasSelection" },
}
LC.widgets["blueprintsDetailPanel.architectBtn"] = {
    tooltip = { recipe = "BlueprintArchitect" }, kind = "button", ["in"] = "blueprintsDetailPanel.actions",
    font = "body", text = "locale:BP_OPEN_ARCHITECT", width = 84, height = 22, order = 15,
    visible = "blueprints.selectedIsArchitectable",  -- interior room layout: House/Interior only
}
-- Rightmost, past the slack absorber: Apply to House is the one button here
-- that changes the player's house, so it sits apart from the four that only
-- read the blueprint.
LC.widgets["blueprintsDetailPanel.importBtn"] = {
    tooltip = { recipe = "BlueprintImportHouse" }, kind = "button", ["in"] = "blueprintsDetailPanel.actions",
    font = "body", text = "locale:BP_IMPORT_HOUSE", width = 108, height = 22, order = 30,
    binding = { enabled = "blueprints.hasSelection" },
}
LC.widgets["blueprintsDetailPanel.actionsSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "blueprintsDetailPanel.actions",
    width = "fill", height = 14, order = 25,
}
-- Gated on hasManifest rather than hasSelection -- there is nothing to copy
-- until the contents arrive.
--
-- Width is load-bearing: at 128 ("Copy requirements") the five buttons needed
-- 560px in a 544px row and the last one hung off the panel whenever Architect
-- was visible. The row has ~36px of slack at this width, which is the margin a
-- longer locale needs.
LC.widgets["blueprintsDetailPanel.copyReqsBtn"] = {
    tooltip = { recipe = "BlueprintCopyReqs" }, kind = "button", ["in"] = "blueprintsDetailPanel.actions",
    font = "body", text = "locale:BP_COPY_REQS", width = 84, height = 22, order = 20,
    binding = { enabled = "blueprints.hasManifest" },
}

-- Guidance strip: ABOVE the action row so the save-after-apply reminder is
-- read before the buttons get clicked (UX review #11).
LC.widgets["blueprintsDetailPanel.guidance"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsDetailPanel",
    text = "locale:BP_GUIDANCE", font = "caption", height = 32, width = "fill", order = 28,
}

-- ===== Library mode ==========================================================
-- Full-width management table over BOTH populations (pasted codes + catalog),
-- opened from the picker header. One normalised list feeds it (blueprints.entries).

LC.panels.blueprintsLibraryPanel = {
    kind = "panel",
    cell = { projectsBlueprints = "library" },
    visibleInViews = { "projectsBlueprints" },
    visible = "blueprints.isSubView_library",
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" },
            chrome = "PanelHeader",
        },
        body = { layout = "vertical", gap = "sm", padding = "lg" },
    },
}

LC.widgets["blueprintsLibraryPanel.titleIcon"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsLibraryPanel", slot = "header",
    text = "|A:common-icons-blueprints:18:18|a", font = "heading", height = 18, width = "auto", order = 3,
}
LC.widgets["blueprintsLibraryPanel.title"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsLibraryPanel", slot = "header",
    text = "locale:BP_LIBRARY_TITLE", font = "heading", height = 18, width = "auto", order = 5,
}
LC.widgets["blueprintsLibraryPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "blueprintsLibraryPanel", slot = "header",
    width = "fill", height = 14, order = 8,
}
LC.widgets["blueprintsLibraryPanel.search"] = {
    tooltip = false, kind = "editbox", ["in"] = "blueprintsLibraryPanel", slot = "header",
    font = "body", height = 22, width = 260, order = 9, multiline = false,
    placeholder = "locale:BP_LIBRARY_SEARCH",
}
LC.widgets["blueprintsLibraryPanel.backBtn"] = {
    tooltip = { recipe = "BlueprintLibraryBack" }, kind = "button", ["in"] = "blueprintsLibraryPanel", slot = "header",
    font = "body", text = "locale:BP_LIBRARY_BACK", width = 124, height = 22, order = 10,
}

-- Source chips: SSoT HDG.Constants.BLUEPRINT_LIBRARY_CHIPS drives widget, selector and click.
LC.sections["blueprintsLibraryPanel.chips"] = {
    ["in"] = "blueprintsLibraryPanel", layout = "horizontal", height = 22, gap = "sm", order = 5,
}
for i, chip in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_CHIPS) do
    LC.widgets["blueprintsLibraryPanel.chip_" .. chip.value] = {
        tooltip = false, kind = "button", ["in"] = "blueprintsLibraryPanel.chips", variant = "tertiary",
        font = "small", width = "auto", height = 20, order = i,
        binding = { text = "blueprints.libraryChipText_" .. chip.value, active = "blueprints.libraryChipActive_" .. chip.value },
    }
end
LC.widgets["blueprintsLibraryPanel.chipsSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "blueprintsLibraryPanel.chips", width = "fill", height = 14, order = 50,
}
LC.widgets["blueprintsLibraryPanel.hideBackups"] = {
    tooltip = { recipe = "BlueprintLibraryHideBackups" }, kind = "checkbox", ["in"] = "blueprintsLibraryPanel.chips",
    font = "small", text = "locale:BP_LIBRARY_HIDE_BACKUPS", width = 150, height = 20, order = 55,
    binding = { checked = "blueprints.libraryHideBackups" },
}
LC.widgets["blueprintsLibraryPanel.chipsHint"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsLibraryPanel.chips", role = "TextDim",
    text = "locale:BP_LIBRARY_SORT_HINT", font = "caption", height = 14, width = "auto", order = 60,
}

-- Column headers: clickable sort buttons (Goblin idiom). Widths are the SSoT
-- for the row factory's anchors.
LC.sections["blueprintsLibraryPanel.columns"] = {
    ["in"] = "blueprintsLibraryPanel", layout = "horizontal", height = 18, gap = "sm", order = 10,
}
for i, c in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_COLUMNS) do
    LC.widgets["blueprintsLibraryPanel.col_" .. c.col] = {
        tooltip = false, kind = "button", ["in"] = "blueprintsLibraryPanel.columns", variant = "tertiary",
        font = "small", width = c.width, height = 16, order = i * 10,
        binding = { text = "blueprints.librarySortHeader_" .. c.col, active = "blueprints.librarySortActive_" .. c.col },
    }
end

LC.widgets["blueprintsLibraryPanel.table"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "blueprintsLibraryPanel",
    binding = "blueprints.libraryRows", rowKind = "blueprintLibraryRow",
    spacing = 1, width = "fill", height = "fill", order = 15,
}

-- Detail strip for the selected row: name/label + code + meta | notes | actions.
LC.sections["blueprintsLibraryPanel.detail"] = {
    ["in"] = "blueprintsLibraryPanel", layout = "horizontal", height = 86, gap = "lg", order = 20,
    chrome = "card", padding = { top = "sm", right = "lg", bottom = "sm", left = "lg" },
    visible = "blueprints.libraryHasDetail",
}
LC.sections["blueprintsLibraryPanel.detailLeft"] = {
    ["in"] = "blueprintsLibraryPanel.detail", layout = "vertical", width = 300, gap = "xs", order = 5,
}
LC.widgets["blueprintsLibraryPanel.nameLabel"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsLibraryPanel.detailLeft", role = "TextDim",
    binding = "blueprints.libraryDetailNameLabel", font = "caption", height = 12, width = "fill", order = 5,
}
-- Backups get no twin read-only label here: nameLabel above already prints
-- "Name (read-only backup)" for them, and the cap is on the footer and the
-- Backups group header. A second 20px widget in this slot would also be counted
-- additively against its sibling by the over-spec widest-case pass, which
-- measures mutually-exclusive WIDGETS as if both showed at once.
LC.widgets["blueprintsLibraryPanel.nameBox"] = {
    tooltip = { recipe = "BlueprintRename" }, kind = "editbox", ["in"] = "blueprintsLibraryPanel.detailLeft",
    font = "small", height = 20, width = "fill", order = 10, multiline = false,
    placeholder = "locale:BP_NAME_PLACEHOLDER", visible = "blueprints.libraryDetailNameEditable",
}
-- The code is a BUTTON, not a label: clicking it copies the share code. Same
-- slot and order as the label it replaces, so the code still reads between the
-- name box and the meta line.
-- An EDITBOX, not a button: there is no addon-callable clipboard API, so the
-- share code is copied the way every WoW addon copies one -- click to select
-- all, Ctrl+C. Read-only in practice; the controller reverts user edits.
LC.widgets["blueprintsLibraryPanel.code"] = {
    tooltip = { recipe = "BlueprintCopyCode" }, kind = "editbox", ["in"] = "blueprintsLibraryPanel.detailLeft",
    binding = { text = "blueprints.libraryDetailCode" }, font = "small", height = 18, width = "fill",
    order = 15, multiline = false,
}
LC.widgets["blueprintsLibraryPanel.meta"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsLibraryPanel.detailLeft",
    binding = "blueprints.libraryDetailMeta", font = "caption", height = 14, width = "fill", order = 20,
}
LC.sections["blueprintsLibraryPanel.detailNotes"] = {
    ["in"] = "blueprintsLibraryPanel.detail", layout = "vertical", width = "fill", gap = "xs", order = 10,
}
LC.widgets["blueprintsLibraryPanel.notesLabel"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsLibraryPanel.detailNotes", role = "TextDim",
    text = "locale:BP_LIBRARY_NOTES", font = "caption", height = 12, width = "fill", order = 5,
}
LC.widgets["blueprintsLibraryPanel.noteBox"] = {
    tooltip = false, kind = "editbox", ["in"] = "blueprintsLibraryPanel.detailNotes",
    font = "body", height = "fill", width = "fill", order = 10, multiline = true,
    placeholder = "locale:BP_LIBRARY_NOTE_PLACEHOLDER",
    binding = { text = "blueprints.libraryDetailNote" },
}
LC.sections["blueprintsLibraryPanel.detailActions"] = {
    ["in"] = "blueprintsLibraryPanel.detail", layout = "vertical", width = 130, gap = "sm", order = 15,
}
LC.widgets["blueprintsLibraryPanel.inspectBtn"] = {
    tooltip = { recipe = "BlueprintLibraryInspect" }, kind = "button", ["in"] = "blueprintsLibraryPanel.detailActions",
    font = "body", text = "locale:BP_LIBRARY_INSPECT", width = "fill", height = 22, order = 5, variant = "primary",
}
LC.widgets["blueprintsLibraryPanel.linkBtn"] = {
    tooltip = { recipe = "BlueprintLink" }, kind = "button", ["in"] = "blueprintsLibraryPanel.detailActions",
    font = "body", text = "locale:BP_LINK_LONG", width = "fill", height = 22, order = 10,
}
LC.widgets["blueprintsLibraryPanel.removeBtn"] = {
    tooltip = false, kind = "button", ["in"] = "blueprintsLibraryPanel.detailActions",
    font = "body", width = "fill", height = 22, order = 15,
    binding = { text = "blueprints.libraryRemoveText" }, visible = "blueprints.libraryCanRemove",
}

LC.widgets["blueprintsLibraryPanel.footer"] = {
    tooltip = false, kind = "label", ["in"] = "blueprintsLibraryPanel",
    binding = "blueprints.libraryFooterText", font = "caption", height = 14, width = "fill", order = 30,
}
