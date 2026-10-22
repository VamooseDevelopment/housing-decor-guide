-- HDG.LayoutConfig -- Warehouse view.
-- Four panes, each its OWN panel with a PanelHeader beam slot (matches the Recipes
-- tab columns): Lumber Stock | Lumber Farming History (top), Materials | Used In (bottom).
-- Selectors: HDGR_Selectors_Warehouse.lua; wiring: HDGR_Controller_Warehouse.lua.

local LC = HDG.LayoutConfig

-- ===== View ==================================================================
-- 2x2 grid. Top row = lumber (stock 392 | history 462), bottom row = materials | used-in.
LC.window.views.warehouse = {
    controllers = { "warehouse" },
    width    = "auto",
    height   = "auto",
    columns  = { 392, 462 },        -- stock | history  (materials | used-in share the split)
    rows     = { 300, 294 },        -- top: lumber (~270 list + beam header) ; bottom: mats/used-in
    cells    = {
        lumberStock   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        lumberHistory = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
        materials     = { col = 1, row = 2, colSpan = 1, rowSpan = 1 },
        usedIn        = { col = 2, row = 2, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels (one per pane; each gets a PanelHeader beam slot) ===============
-- Fresh table per call so each panel owns its slot spec (engine stamps per-slot state).
local function whHeader()
    return {
        header = {
            height = 26, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "lg", bottom = 0, left = "lg" },
            chrome = "PanelHeader",
        },
    }
end
LC.panels.warehouseLumberPanel    = { kind = "panel", cell = { warehouse = "lumberStock" },   visibleInViews = { "warehouse" }, slots = whHeader() }
LC.panels.warehouseHistoryPanel   = { kind = "panel", cell = { warehouse = "lumberHistory" }, visibleInViews = { "warehouse" }, slots = whHeader() }
LC.panels.warehouseMaterialsPanel = { kind = "panel", cell = { warehouse = "materials" },     visibleInViews = { "warehouse" }, slots = whHeader() }
LC.panels.warehouseUsedInPanel    = { kind = "panel", cell = { warehouse = "usedIn" },        visibleInViews = { "warehouse" }, slots = whHeader() }

-- ===== Lumber Stock panel ====================================================
-- Header: title + (right) the auto-open lumber tracker toggle.
LC.widgets["warehouseLumberPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "warehouseLumberPanel", slot = "header",
    text = "locale:WARE_LUMBER_STOCK_HDR", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["warehouseLumberPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "warehouseLumberPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
LC.widgets["warehouseLumberPanel.autoShowToggle"] = {
    tooltip = { recipe = "LumberAutoShow" },
    kind = "checkbox", ["in"] = "warehouseLumberPanel", slot = "header", font = "button",
    text = "locale:WARE_AUTOSHOW_TOGGLE", width = 200, height = 22, order = 20,
    binding = { checked = "warehouse.autoShowLumber" },
}
-- Body: column-header row (widths match LUMBER_COLS) + the stock list.
LC.sections["warehouse.lumberBody"] = {
    ["in"] = "warehouseLumberPanel", layout = "vertical", padding = "sm", gap = "xs", order = 10,
}
LC.sections["warehouse.lumberHeader"] = {
    ["in"] = "warehouse.lumberBody", layout = "horizontal", height = 14, gap = "xs", order = 10,
}
LC.sections["warehouse.lumberList"] = {
    ["in"] = "warehouse.lumberBody", layout = "fill", order = 20, chrome = "inset",
}
LC.widgets["warehouseLumberPanel.hdr.name"]    = { tooltip = false, kind = "label", ["in"] = "warehouse.lumberHeader", font = "caption", text = "locale:WARE_LUMBER_HDR_NAME",    width = 90, height = 12, order = 10 }
LC.widgets["warehouseLumberPanel.hdr.exp"]     = { tooltip = false, kind = "label", ["in"] = "warehouse.lumberHeader", font = "caption", text = "locale:WARE_LUMBER_HDR_EXP",     width = 44, height = 12, order = 15 }
LC.widgets["warehouseLumberPanel.hdr.bag"]     = { tooltip = false, kind = "label", ["in"] = "warehouse.lumberHeader", font = "caption", text = "locale:WARE_LUMBER_HDR_BAG",     justifyH = "RIGHT", width = 36, height = 12, order = 20 }
LC.widgets["warehouseLumberPanel.hdr.bank"]    = { tooltip = false, kind = "label", ["in"] = "warehouse.lumberHeader", font = "caption", text = "locale:WARE_LUMBER_HDR_BANK",    justifyH = "RIGHT", width = 36, height = 12, order = 30 }
LC.widgets["warehouseLumberPanel.hdr.warband"] = { tooltip = false, kind = "label", ["in"] = "warehouse.lumberHeader", font = "caption", text = "locale:WARE_LUMBER_HDR_WARBAND", justifyH = "RIGHT", width = 44, height = 12, order = 40 }
LC.widgets["warehouseLumberPanel.hdr.needed"]  = { tooltip = false, kind = "label", ["in"] = "warehouse.lumberHeader", font = "caption", text = "locale:WARE_LUMBER_HDR_NEED",    justifyH = "RIGHT", width = 42, height = 12, order = 50 }
LC.widgets["warehouseLumberPanel.hdr.stock"]   = { tooltip = false, kind = "label", ["in"] = "warehouse.lumberHeader", font = "caption", text = "locale:WARE_LUMBER_HDR_STOCK",   justifyH = "RIGHT", width = 64, height = 12, order = 60 }
LC.widgets["warehouseLumberPanel.lumberList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "warehouse.lumberList",
    binding = "warehouse.lumberRows", rowKind = "lumberRow", spacing = 1, order = 10,
}

-- ===== Lumber Farming History panel ==========================================
LC.widgets["warehouseHistoryPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "warehouseHistoryPanel", slot = "header",
    text = "locale:WARE_LUMBER_HISTORY_HDR", font = "heading",
    height = 18, width = "fill", order = 10,
}
LC.sections["warehouse.historyBody"] = {
    ["in"] = "warehouseHistoryPanel", layout = "vertical", padding = "sm", order = 10,
}
LC.sections["warehouse.historyList"] = {
    ["in"] = "warehouse.historyBody", layout = "fill", order = 10, chrome = "inset",
}
LC.widgets["warehouseHistoryPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "warehouse.historyList",
    binding = "warehouse.farmingHistoryRows", rowKind = "dataRow", spacing = 1, order = 10,
}

-- ===== Materials panel =======================================================
LC.widgets["warehouseMaterialsPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "warehouseMaterialsPanel", slot = "header",
    text = "locale:WARE_ALL_MATS_HDR", font = "heading",
    height = 18, width = "fill", order = 10,
}
LC.sections["warehouse.materialsBody"] = {
    ["in"] = "warehouseMaterialsPanel", layout = "vertical", padding = "sm", gap = "xs", order = 10,
}
LC.sections["warehouse.matsSearch"] = {
    ["in"] = "warehouse.materialsBody", layout = "horizontal", height = 22, order = 10,
}
LC.sections["warehouse.matsList"] = {
    ["in"] = "warehouse.materialsBody", layout = "fill", order = 20, chrome = "inset",
}
LC.widgets["warehouseMaterialsPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "warehouse.matsSearch", font = "body",
    height = 22, width = "fill", order = 10,
    multiline = false, placeholder = "locale:WARE_MAT_SEARCH_PLACEHOLDER",
    binding = { text = "warehouse.matSearch" },
}
LC.widgets["warehouseMaterialsPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "warehouse.matsList",
    binding = "warehouse.allMaterialsRows", rowKind = "warehouseMatRow", spacing = 1,
    -- SelectionBehavior: highlight via behavior; selectedMaterialID dropped from reads.
    selection = { deselectable = false },
    order = 10,
}

-- ===== Used In panel =========================================================
-- Title is selection-aware ("Used In: X"); clickHints surface left=select / shift=queue.
LC.widgets["warehouseUsedInPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "warehouseUsedInPanel", slot = "header",
    text = "locale:WARE_USED_IN_HDR", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "warehouse.usedInTitle",
}
LC.widgets["warehouseUsedInPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "warehouseUsedInPanel", slot = "header",
    width = "fill", height = 14, order = 15,
}
-- Shift-click-to-queue has no row affordance, so the header hint surfaces it.
-- Shift-only: buildClickHints renders the left-click glyph for shiftText.
LC.widgets["warehouseUsedInPanel.clickHints"] = {
    tooltip = false,   -- self-owned tooltip composed from shiftText
    kind = "clickHints", ["in"] = "warehouseUsedInPanel", slot = "header",
    shiftText = "locale:WARE_USED_IN_HINT_SHIFT",
    width = 16, height = 16, order = 20,
}
LC.sections["warehouse.usedInBody"] = {
    ["in"] = "warehouseUsedInPanel", layout = "vertical", padding = "sm", order = 10,
}
LC.sections["warehouse.usedInList"] = {
    ["in"] = "warehouse.usedInBody", layout = "fill", order = 10, chrome = "inset",
}
LC.widgets["warehouseUsedInPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "warehouse.usedInList",
    binding = "warehouse.usedInRows", rowKind = "usedInRow", spacing = 1, order = 10,
}
