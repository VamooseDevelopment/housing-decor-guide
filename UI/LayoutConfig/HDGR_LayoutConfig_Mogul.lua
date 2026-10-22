-- HDGR_LayoutConfig_Mogul.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Mogul tab: two sub-views (mogul / goblin).
-- dynamicColumns: 700 default; widens to 950 when TSM active in Goblin.
-- dynamicRows: body row grows 600->650 when a Goblin row is expanded.
--
-- Dynamic widget blocks:
--   mogulPanel.goblinProf_All + mogulPanel.goblinProf_<name>  (PROFESSION_DATA 1-9)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================
-- 700 default; TSM+Goblin widens to 950 for the 4 extra columns.
-- Existing 7 columns stay fixed-anchored so they don't shift between widths.

LC.window.views.mogul = {
    controllers = { "mogul" },
    width    = "auto",       -- 4 + 700 + 4 = 708 (default)
    height   = "auto",
    columns  = { 700 },
    dynamicColumns = "mogul.dynamicColumns",
    rows     = { 600 },      -- 600 baseline (matches mogul.dynamicRows) so the nav fills
    -- Goblin row-expand grows body 600->650 to surface material-breakdown (mogul.dynamicRows).
    dynamicRows = "mogul.dynamicRows",
    cells    = {
        body   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.mogulPanel = {
    kind = "panel",
    cell = { mogul = "body" },
    visibleInViews = { "mogul" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================

LC.sections["mogul.body"] = {
    ["in"] = "mogulPanel",
    layout = "vertical",
    padding = "lg",
    gap = "sm",
    order = 10,
}

-- ===== subView "mogul" (craft optimizer) =====================================

LC.sections["mogul.subView_mogul"] = {
    ["in"] = "mogul.body",
    layout = "vertical",
    gap = "sm",
    order = 10,
    visible = "mogul.isSubView_mogul",
}
-- topRow: buttons column only (76px = 3 control rows at 22 + xs gaps).
LC.sections["mogul.topRow"] = {
    ["in"] = "mogul.subView_mogul",
    layout = "horizontal",
    height = 76,
    gap = "sm",
    order = 10,
}
-- Buttons column: mode/view/optimize/supply chips (vertical stack).
LC.sections["mogul.buttonsCol"] = {
    ["in"] = "mogul.topRow",
    layout = "vertical",
    width = "fill",
    gap = "xs",
    order = 10,
}
LC.sections["mogul.controlsRow1"] = {
    ["in"] = "mogul.buttonsCol",
    layout = "horizontal",
    height = 22, gap = "xs", order = 10,
}
LC.sections["mogul.controlsRow2"] = {
    ["in"] = "mogul.buttonsCol",
    layout = "horizontal",
    height = 22, gap = "xs", order = 12,
}
-- Supply Impact: radio group + optional numeric editbox.
LC.sections["mogul.controlsRow3"] = {
    ["in"] = "mogul.buttonsCol",
    layout = "horizontal",
    height = 22, gap = "xs", order = 14,
}
LC.sections["mogul.totalsRow"] = {
    ["in"] = "mogul.subView_mogul",
    layout = "horizontal",
    height = 16, order = 14,
}
LC.sections["mogul.list"] = {
    ["in"] = "mogul.subView_mogul",
    layout = "fill",
    order = 20,
    chrome = "inset",
}
-- bottomRow: reagents-to-buy (fill, left) + lumber tracker (360px, right). 110px = ~6 rows.
LC.sections["mogul.bottomRow"] = {
    ["in"] = "mogul.subView_mogul",
    layout = "horizontal",
    height = 110, gap = "sm", order = 30,
}
LC.sections["mogul.matsCol"] = {
    ["in"] = "mogul.bottomRow",
    layout = "vertical",
    width = "fill",
    gap = "xs",
    order = 10,
}
LC.sections["mogul.matsHeader"] = {
    ["in"] = "mogul.matsCol",
    layout = "horizontal",
    height = 16, order = 10,
}
LC.sections["mogul.matsList"] = {
    ["in"] = "mogul.matsCol",
    layout = "fill",
    order = 20,
    chrome = "inset",
}
-- Lumber column: header + list. Mirrors matsCol structure.
LC.sections["mogul.lumberCol"] = {
    ["in"] = "mogul.bottomRow",
    layout = "vertical",
    width = 360,
    gap = "xs",
    order = 20,
}
LC.sections["mogul.lumberHeader"] = {
    ["in"] = "mogul.lumberCol",
    layout = "horizontal",
    height = 16, order = 10,
}
LC.sections["mogul.lumberListInset"] = {
    ["in"] = "mogul.lumberCol",
    layout = "fill",
    order = 20,
    chrome = "inset",
}

-- ===== subView "goblin" (per-decor profit analysis) ==========================

LC.sections["mogul.subView_goblin"] = {
    ["in"] = "mogul.body",
    layout = "vertical",
    gap = "xs",
    order = 20,
    visible = "mogul.isSubView_goblin",
}
-- Profession filter: "All" + 9 crafting professions (auto-generated from PROFESSION_DATA).
LC.sections["mogul.goblinProfRow"] = {
    ["in"] = "mogul.subView_goblin",
    layout = "horizontal",
    height = 22, gap = "xs", order = 5,
}
-- Expansion filter: 12 short codes from EXPANSION_DATA (toggle-to-clear, composes with profession).
LC.sections["mogul.goblinExpRow"] = {
    ["in"] = "mogul.subView_goblin",
    layout = "horizontal",
    height = 22, gap = "xs", order = 6,
}
-- Filter row: search + knowledge + queue dropdowns + auctions toggle.
LC.sections["mogul.goblinFilterRow"] = {
    ["in"] = "mogul.subView_goblin",
    layout = "horizontal",
    height = 22, gap = "sm", order = 7,
}
LC.sections["mogul.goblinKnowGroup"] = {
    ["in"] = "mogul.goblinFilterRow",
    layout = "horizontal",
    height = 22, gap = "xs", order = 20,
}
LC.sections["mogul.goblinQueueGroup"] = {
    ["in"] = "mogul.goblinFilterRow",
    layout = "horizontal",
    height = 22, gap = "xs", order = 30,
}
-- TSM price-type group removed: table shows all three TSM columns at once.
-- Profit-calc TSM mode set from Config tab pills.
LC.sections["mogul.goblinColumnHeader"] = {
    ["in"] = "mogul.subView_goblin",
    layout = "horizontal",
    -- gap=sm(4px) matches the row cells' SetPoint -4 chain so header cells align with row data.
    gap = "sm",
    height = 16, order = 10,
}
-- Cold-start scan hint: visible until a Direct scan has run (and no price addon
-- covers the gap). Collapses to zero height once price data exists.
LC.widgets["mogulPanel.goblinScanHint"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.subView_goblin",
    text = "locale:MOG_SCAN_HINT", font = "body", justifyH = "CENTER",
    width = "fill", height = 18, order = 15,
    visible = "goblin.needsScanHint",
}
LC.sections["mogul.goblinList"] = {
    ["in"] = "mogul.subView_goblin",
    layout = "fill",
    order = 20,
    chrome = "inset",
}
LC.sections["mogul.goblinStatusBar"] = {
    ["in"] = "mogul.subView_goblin",
    layout = "horizontal",
    height = 14, order = 30,
}
-- Detail panel: visible when a row is expanded; body row grows via mogul.dynamicRows.
LC.sections["mogul.goblinDetailPanel"] = {
    ["in"] = "mogul.subView_goblin",
    layout = "vertical",
    height = 150,
    gap = "xs",
    order = 40,
    visible = "goblin.isDetailVisible",
    chrome = "inset",
}
LC.sections["mogul.goblinDetailHeader"] = {
    ["in"] = "mogul.goblinDetailPanel",
    layout = "horizontal",
    height = 16, order = 10,
}
LC.sections["mogul.goblinDetailList"] = {
    ["in"] = "mogul.goblinDetailPanel",
    layout = "fill",
    order = 20,
}

-- ===== Widgets ===============================================================

-- Title binding reads session.ui.mogul.subView ("Goblin" / "Mogul (N crafts)").
LC.widgets["mogulPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "mogulPanel", slot = "header",
    text = "locale:MOG_PANEL_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "mogul.title",
}
-- Goblin header: price-source selector + Refresh from AH (goblin subview only),
-- packed just after the title. The highlighted chip = active source; Auctionator
-- + TSM are gated on the addon being installed. Bindings + click actions are the
-- same ones the (former) Config pills used -- wired in MogulController:Wire.
LC.widgets["mogulPanel.src_Auto"] = {
    tooltip = { recipe = "GoblinSrcAuto" },
    kind = "button", ["in"] = "mogulPanel", slot = "header", font = "small",
    text = "locale:MOG_SRC_AUTO", width = "auto", height = 20, order = 11, variant = "tertiary",
    visible = "mogul.isSubView_goblin",
    binding = { active = "config.sourceActive_Auto" },
}
LC.widgets["mogulPanel.src_Auctionator"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogulPanel", slot = "header", font = "small",
    text = "locale:MOG_SRC_AUCTIONATOR", width = "auto", height = 20, order = 12, variant = "tertiary",
    visible = "goblin.showSourceAuctionator",
    binding = { active = "config.sourceActive_Auctionator" },
}
LC.widgets["mogulPanel.src_Direct"] = {
    tooltip = { recipe = "GoblinSrcDirect" },
    kind = "button", ["in"] = "mogulPanel", slot = "header", font = "small",
    text = "locale:MOG_SRC_DIRECT", width = "auto", height = 20, order = 13, variant = "tertiary",
    visible = "mogul.isSubView_goblin",
    binding = { active = "config.sourceActive_Direct" },
}
LC.widgets["mogulPanel.src_TSM"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogulPanel", slot = "header", font = "small",
    text = "locale:MOG_SRC_TSM", width = "auto", height = 20, order = 14, variant = "tertiary",
    visible = "goblin.showSourceTSM",
    binding = { active = "config.sourceActive_TSM" },
}
LC.widgets["mogulPanel.refreshScanBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogulPanel", slot = "header", font = "small",
    text = "locale:MOG_REFRESH_FROM_AH", width = 140, height = 20, order = 20, variant = "tertiary",
    visible = "mogul.isSubView_goblin",
    binding = { text = "config.scanButtonLabel" },
}
-- Spacer: header content (left) -> rest of the bar (fill). Last so all the
-- source/refresh widgets pack tight after the title.
LC.widgets["mogulPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "mogulPanel", slot = "header",
    width = "fill", height = 22, order = 30,
}
-- Mode chips (Profit / Collection)
LC.widgets["mogulPanel.modeProfit"] = {
    tooltip = { recipe = "MogulModeProfit" },
    kind = "button", ["in"] = "mogul.controlsRow1", variant = "tertiary", font = "button",
    text = "locale:MOG_MODE_PROFIT", width = 80, height = 22, order = 10,
    binding = { active = "mogul.isMode_profit" },
}
LC.widgets["mogulPanel.modeCollection"] = {
    tooltip = { recipe = "MogulModeCollection" },
    kind = "button", ["in"] = "mogul.controlsRow1", variant = "tertiary", font = "button",
    text = "locale:MOG_MODE_COLLECTION", width = 100, height = 22, order = 20,
    binding = { active = "mogul.isMode_collection" },
}
-- View chips (Char / Account)
LC.widgets["mogulPanel.viewChar"] = {
    tooltip = { recipe = "MogulViewChar" },
    kind = "button", ["in"] = "mogul.controlsRow1", variant = "tertiary", font = "button",
    text = "locale:MOG_VIEW_CHAR", width = 70, height = 22, order = 30,
    binding = { active = "mogul.isView_char" },
}
LC.widgets["mogulPanel.viewAccount"] = {
    tooltip = { recipe = "MogulViewAccount" },
    kind = "button", ["in"] = "mogul.controlsRow1", variant = "tertiary", font = "button",
    text = "locale:MOG_VIEW_ACCOUNT", width = 80, height = 22, order = 40,
    binding = { active = "mogul.isView_account" },
}
-- OptimizeBy chips
LC.widgets["mogulPanel.optLumber"] = {
    tooltip = { recipe = "MogulOptOwned" },
    kind = "button", ["in"] = "mogul.controlsRow2", variant = "tertiary", font = "button",
    text = "locale:MOG_OPT_USE_OWNED_MATS", width = 130, height = 22, order = 10,
    binding = { active = "mogul.isOpt_lumberOnly" },
}
LC.widgets["mogulPanel.optAH"] = {
    tooltip = { recipe = "MogulOptBuy" },
    kind = "button", ["in"] = "mogul.controlsRow2", variant = "tertiary", font = "button",
    text = "locale:MOG_OPT_BUY_MATS_FROM_AH", width = 150, height = 22, order = 20,
    binding = { active = "mogul.isOpt_lumberPlusMats" },
}
-- Supply impact: "Supply impact:" label + radioGroup (Off/Smooth%/Cap) + optional editbox.
LC.widgets["mogulPanel.supplyLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.controlsRow3",
    text = "locale:MOG_SUPPLY_IMPACT_LABEL", font = "small",
    height = 20, width = "auto", order = 5,
}
-- width=190: Off(~38)+Smooth%(~68)+Cap(~44)+2x spacing(14)=~178px.
-- Governs where supplyParam lands; "auto" falls back to "fill" (radioGroup has no intrinsic).
LC.widgets["mogulPanel.supplyRadio"] = {
    tooltip = { recipe = "MogulSupplyImpact" },
    kind = "radioGroup", ["in"] = "mogul.controlsRow3",
    font = "small", height = 20, width = 190, spacing = 14, order = 10,
    binding  = { menu = "mogul.supplyMenuItems", current = "mogul.supplyMode" },
    dispatch = { type = "MOGUL_SET_SUPPLY_MODE", payloadKey = "mode" },
}
-- `visible` is a TOP-LEVEL spec field -- NOT inside `binding` (editbox dispatcher ignores binding.visible).
LC.widgets["mogulPanel.supplyParam"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "mogul.controlsRow3", font = "small",
    width = 50, height = 20, order = 20,
    visible = "mogul.supplyParamVisible",
    binding = { text = "mogul.supplyParamText" },
}
-- Frugal toggle: tertiary variant so active-state text matches other Mogul controls.
LC.widgets["mogulPanel.frugal"] = {
    tooltip = { recipe = "MogulFrugal" },
    kind = "button", ["in"] = "mogul.controlsRow3", variant = "tertiary", font = "button",
    text = "locale:MOG_FRUGAL", width = 70, height = 22, order = 30,
    binding = { active = "mogul.frugal" },
}
-- Totals line.
LC.widgets["mogulPanel.totals"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "mogul.totalsRow",
    text = "", font = "small", width = "fill", height = 14, order = 10,
    binding = "mogul.totalsLabel",
}
-- Queue All: sends every plan row to the Recipes-tab craft queue.
LC.widgets["mogulPanel.queueAll"] = {
    tooltip = { recipe = "MogulQueueAll" },
    kind = "button", ["in"] = "mogul.totalsRow", font = "small",
    text = "locale:MOG_QUEUE_ALL", width = "auto", height = 14, order = 20, variant = "tertiary",
    binding = { enabled = "mogul.queueAllEnabled" },
}

-- Plan column header. Widths mirror ensurePlanRow (star+crafts+name(fill)+lumber+each+profit+exp).
-- Static labels -- plan columns are not sortable.
LC.sections["mogul.planColumnHeader"] = {
    ["in"] = "mogul.subView_mogul",
    layout = "horizontal",
    height = 14, gap = "xs", order = 18,
}
LC.widgets["mogulPanel.planColSpacer"] = {
    tooltip = false, kind = "spacer",
    ["in"] = "mogul.planColumnHeader",
    -- 58px = star(12)+gap(4)+crafts(36)+gap(6) before the name fill
    width = 58, height = 14, order = 10,
}
LC.widgets["mogulPanel.planColName"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.planColumnHeader",
    text = "locale:MOG_PLAN_COL_RECIPE", font = "caption", width = "fill", height = 14, order = 20,
}
LC.widgets["mogulPanel.planColLumber"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.planColumnHeader",
    -- atlas + "/ea" right-aligned to match the right-anchored row cell
    text = "|A:Lumber_Tracking:14:14|a/ea", font = "caption",
    width = 46, height = 14, order = 30, justifyH = "RIGHT",
}
LC.widgets["mogulPanel.planColEach"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.planColumnHeader",
    text = "gold/|A:Lumber_Tracking:14:14|a", font = "caption",
    width = 130, height = 14, order = 40, justifyH = "RIGHT",
}
LC.widgets["mogulPanel.planColRevNet"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.planColumnHeader",
    text = "locale:MOG_PLAN_COL_REVENUE_NET", font = "caption",
    width = 150, height = 14, order = 50, justifyH = "RIGHT",
}
-- "Exp" header: dim, right-anchored to mirror the row's _expFs cell.
LC.widgets["mogulPanel.planColExp"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.planColumnHeader",
    text = "locale:MOG_PLAN_COL_EXP", font = "caption",
    width = 40, height = 14, order = 60, justifyH = "RIGHT",
}

-- Plan list: heterogeneous rows (section headers + plan rows + runners-up).
LC.widgets["mogulPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "mogul.list",
    binding = "mogul.planRows",
    rowKind = "mogulRow",
    spacing = 1,
    order = 10,
}
-- Lumber section header.
LC.widgets["mogulPanel.lumberTitle"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.lumberHeader",
    text = "locale:MOG_LUMBER_USED_IN_PLAN", font = "small",
    height = 14, width = "fill", order = 10,
    binding = "mogul.lumberHeaderLabel",
}
-- Lumber tracker: 2-up rows so all 12 types fit in 6 rows without scroll.
LC.widgets["mogulPanel.lumberList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "mogul.lumberListInset",
    binding = "mogul.lumberRowsPaired",
    rowKind = "mogulLumberRow2x",
    spacing = 0,
    order = 10,
}
-- Reagents-to-buy header + scrollbox.
LC.widgets["mogulPanel.matsTitle"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.matsHeader",
    text = "locale:MOG_REAGENTS_TO_BUY", font = "small",
    height = 14, width = "fill", order = 10,
    binding = "mogul.matsTitle",
}
-- Send to Auctionator: pushes itemIDs to Auctionator's CreateShoppingList API.
LC.widgets["mogulPanel.sendToAH"] = {
    tooltip = { recipe = "MogulSendToAH" },
    kind = "button", ["in"] = "mogul.matsHeader", font = "small",
    text = "locale:MOG_SEND_TO_AUCTIONATOR", width = "auto", height = 14, order = 20, variant = "tertiary",
    binding = { enabled = "mogul.auctionatorEnabled" },
}
LC.widgets["mogulPanel.matsList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "mogul.matsList",
    binding = "mogul.matsRows",
    rowKind = "mogulMatRow",
    spacing = 0,
    order = 10,
}

-- Goblin column header: clickable sort buttons. Widths match goblinRow factory cell anchors.
LC.widgets["mogulPanel.goblinCol_name"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    -- width=220 so header chain aligns with the row factory's fixed-anchor chain.
    width = 220, height = 16, order = 10,
    binding = { text = "goblin.sortHeader_name", active = "goblin.sortActive_name" },
}
LC.widgets["mogulPanel.goblinCol_lumber"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 140, height = 16, order = 20,
    binding = { text = "goblin.sortHeader_lumber", active = "goblin.sortActive_lumber" },
}
LC.widgets["mogulPanel.goblinCol_perLum"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 70, height = 16, order = 30,
    binding = { text = "goblin.sortHeader_perLum", active = "goblin.sortActive_perLum" },
}
-- Total column dropped (redundant with Profit). 4 TSM columns added (show "-" when TSM absent).
LC.widgets["mogulPanel.goblinCol_cost"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 70, height = 16, order = 50,
    binding = { text = "goblin.sortHeader_cost", active = "goblin.sortActive_cost" },
}
LC.widgets["mogulPanel.goblinCol_sell"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 70, height = 16, order = 60,
    binding = { text = "goblin.sortHeader_sell", active = "goblin.sortActive_sell" },
}
LC.widgets["mogulPanel.goblinCol_profit"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 80, height = 16, order = 70,
    binding = { text = "goblin.sortHeader_profit", active = "goblin.sortActive_profit" },
}
LC.widgets["mogulPanel.goblinCol_pct"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 40, height = 16, order = 80,
    binding = { text = "goblin.sortHeader_pct", active = "goblin.sortActive_pct" },
}
-- #AH: live units-on-AH count (Direct scan). Always shown (source-independent of TSM);
-- reads "-" until "Refresh from AH" runs a scan. Sits just right of the % column.
LC.widgets["mogulPanel.goblinCol_ah"] = {
    tooltip = { recipe = "GoblinAhQty" },
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 40, height = 16, order = 81,
    binding = { text = "goblin.sortHeader_ahQty", active = "goblin.sortActive_ahQty" },
}
-- TSM columns: visible-bound to goblin.isTSMActive; collapse when TSM absent -> window narrows to 745.
LC.widgets["mogulPanel.goblinCol_tsmMin"] = {
    tooltip = { recipe = "GoblinTsmServer" },
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 70, height = 16, order = 82,
    visible = "goblin.isTSMActive",
    binding = { text = "goblin.sortHeader_tsmMin", active = "goblin.sortActive_tsmMin" },
}
LC.widgets["mogulPanel.goblinCol_tsmMarket"] = {
    tooltip = { recipe = "GoblinTsmMarket" },
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 70, height = 16, order = 84,
    visible = "goblin.isTSMActive",
    binding = { text = "goblin.sortHeader_tsmMarket", active = "goblin.sortActive_tsmMarket" },
}
LC.widgets["mogulPanel.goblinCol_tsmRegion"] = {
    tooltip = { recipe = "GoblinTsmRegion" },
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 70, height = 16, order = 86,
    visible = "goblin.isTSMActive",
    binding = { text = "goblin.sortHeader_tsmRegion", active = "goblin.sortActive_tsmRegion" },
}
LC.widgets["mogulPanel.goblinCol_tsmPct"] = {
    tooltip = { recipe = "GoblinTsmPct" },
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 50, height = 16, order = 88,
    visible = "goblin.isTSMActive",
    binding = { text = "goblin.sortHeader_tsmPct", active = "goblin.sortActive_tsmPct" },
}
-- Region velocity (TSM AuctionDB; needs the TSM Desktop App). Same gate as the TSM block.
LC.widgets["mogulPanel.goblinCol_saleRate"] = {
    tooltip = { recipe = "GoblinSaleRate" },
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 50, height = 16, order = 90,
    visible = "goblin.isTSMActive",
    binding = { text = "goblin.sortHeader_saleRate", active = "goblin.sortActive_saleRate" },
}
LC.widgets["mogulPanel.goblinCol_soldPerDay"] = {
    tooltip = { recipe = "GoblinSoldPerDay" },
    kind = "button", ["in"] = "mogul.goblinColumnHeader",
    font = "small", variant = "tertiary",
    width = 50, height = 16, order = 92,
    visible = "goblin.isTSMActive",
    binding = { text = "goblin.sortHeader_soldPerDay", active = "goblin.sortActive_soldPerDay" },
}
-- Filter row.
LC.widgets["mogulPanel.goblinSearch"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "mogul.goblinFilterRow", font = "body",
    height = 22, width = 145, order = 10,
    multiline = false,
    placeholder = "locale:MOG_SEARCH_PLACEHOLDER",
}
-- Mouse hint (sort + row-expand). Spacer right-aligns it.
LC.widgets["mogulPanel.goblinHintsSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "mogul.goblinFilterRow",
    width = "fill", height = 16, order = 88,
}
LC.widgets["mogulPanel.goblinHints"] = {
    tooltip = false, kind = "clickHints", ["in"] = "mogul.goblinFilterRow",
    leftText  = "locale:MOG_GOBLIN_HINTS_LEFT",
    shiftText = "locale:MOG_GOBLIN_HINTS_SHIFT",
    width = 16, height = 16, order = 90,
}
-- Knowledge + Queue dropdowns: selectionPrefix adds axis name ("Knowledge: All" etc).
LC.widgets["mogulPanel.goblinKnowDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "mogul.goblinKnowGroup",
    width = "auto", height = 20, order = 10, minWidth = 130,
    placeholder     = "locale:MOG_KNOWLEDGE_PLACEHOLDER",
    selectionPrefix = "locale:MOG_KNOWLEDGE_PREFIX",
    binding  = { menu = "goblin.knowledgeMenuItems", current = "goblin.knowledge" },
    dispatch = { type = "GOBLIN_SET_KNOWLEDGE", payloadKey = "mode" },
}
LC.widgets["mogulPanel.goblinQueueDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "mogul.goblinQueueGroup",
    width = "auto", height = 20, order = 10, minWidth = 110,
    placeholder     = "locale:MOG_QUEUE_PLACEHOLDER",
    selectionPrefix = "locale:MOG_QUEUE_PREFIX",
    binding  = { menu = "goblin.queueMenuItems", current = "goblin.queue" },
    dispatch = { type = "GOBLIN_SET_QUEUE", payloadKey = "mode" },
}
LC.widgets["mogulPanel.goblinAuctions"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinFilterRow", font = "small",
    text = "locale:MOG_AUCTIONS", width = "auto", height = 20, order = 40, variant = "tertiary",
    binding = { active = "goblin.auctionsActive" },
}
LC.widgets["mogulPanel.goblinHaveLumber"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinFilterRow", font = "small",
    text = "Have lumber", width = "auto", height = 20, order = 45, variant = "tertiary",
    binding = { active = "goblin.haveLumberActive" },
}
-- Export sits after the filters and before the slack absorber, so it lands at
-- the right-hand end of the controls the way the donor's did.
LC.widgets["mogulPanel.goblinExport"] = {
    tooltip = { recipe = "GoblinExport" },
    kind = "button", ["in"] = "mogul.goblinFilterRow", font = "small",
    text = "locale:COMMON_EXPORT", width = "auto", height = 20, order = 50, variant = "tertiary",
}
LC.widgets["mogulPanel.goblinList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "mogul.goblinList",
    binding = "goblin.rows",
    rowKind = "goblinRow",
    spacing = 0,
    order = 10,
}
LC.widgets["mogulPanel.goblinStatus"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.goblinStatusBar",
    text = "", font = "small", width = "auto", height = 14, order = 10,
    binding = "goblin.statusLabel",
}
-- Direct-cache freshness, right-aligned on the same line as the item count.
LC.widgets["mogulPanel.goblinStatusSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "mogul.goblinStatusBar",
    width = "fill", height = 14, order = 15,
}
LC.widgets["mogulPanel.goblinCacheLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.goblinStatusBar",
    text = "", font = "small", width = "auto", height = 14, order = 20,
    binding = "config.cacheFreshnessLabel",
}
-- Detail header: title (fill) + Cost/Owned/Qty dim labels right-aligned.
-- Widths (cost=80, owned=60, qty=50, gap=6) mirror _layoutGoblinDetailRow.
LC.widgets["mogulPanel.goblinDetailTitle"] = {
    tooltip = false,
    kind = "label", ["in"] = "mogul.goblinDetailHeader",
    text = "", font = "small", width = "fill", height = 16, order = 10,
    binding = "goblin.detailTitle",
}
LC.widgets["mogulPanel.goblinDetailColQty"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.goblinDetailHeader",
    text = "locale:MOG_DETAIL_COL_QTY", font = "caption", width = 50, height = 16, order = 70,
}
LC.widgets["mogulPanel.goblinDetailColOwned"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.goblinDetailHeader",
    text = "locale:MOG_DETAIL_COL_OWNED", font = "caption", width = 60, height = 16, order = 80,
}
LC.widgets["mogulPanel.goblinDetailColCost"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.goblinDetailHeader",
    text = "locale:MOG_DETAIL_COL_COST", font = "caption", width = 80, height = 16, order = 90,
}
LC.widgets["mogulPanel.goblinDetailList"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "mogul.goblinDetailList",
    binding = "goblin.detailRows",
    rowKind = "goblinDetailRow",
    spacing = 0,
    order = 10,
}

-- ===== Widgets -- dynamic (generated at load time) ===========================

-- Goblin profession pills: "All" + 9 crafting professions (PROFESSION_DATA 1-9).
LC.widgets["mogulPanel.goblinProfLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.goblinProfRow",
    text = "locale:MOG_PROF_LABEL", font = "caption", width = "auto", height = 20, order = 1,
}
LC.widgets["mogulPanel.goblinProf_All"] = {
    tooltip = false,
    kind = "button", ["in"] = "mogul.goblinProfRow", font = "small",
    text = "locale:COMMON_ALL", width = "auto", height = 20, order = 5, variant = "tertiary",
    binding = { active = "goblin.profActive_All" },
    profession = "All",
}
for i, p in ipairs(HDG.Constants.PROFESSION_DATA or {}) do
    if i <= 9 and p.name then
        -- Atlas icon + 2-letter code via Blizzard's |A:atlas:h:w|a escape.
        local label = "|A:" .. (p.atlas or "") .. ":14:14|a " .. (p.code or p.name)
        LC.widgets["mogulPanel.goblinProf_" .. p.name] = {
    tooltip = false,
            kind = "button", ["in"] = "mogul.goblinProfRow", font = "small",
            text = label,
            width = "auto", height = 20, order = 10 + i, variant = "tertiary",
            binding = { active = "goblin.profActive_" .. p.name },
            profession = p.name,
        }
    end
end

-- Goblin expansion pills: short code per EXPANSION_DATA entry, tinted by its expansion colour.
LC.widgets["mogulPanel.goblinExpLabel"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "mogul.goblinExpRow",
    text = "Exp:", font = "caption", width = "auto", height = 20, order = 1,
}
-- Inline expansion-colour hex (mirrors HDGR_Expansion.buildColorHex) so the pill
-- labels bake at LayoutConfig load with no load-order dependency on HDG.Expansion.
local function _expHex(c)
    return string.format("|cFF%02x%02x%02x",
        math.floor((c[1] or 1) * 255 + 0.5),
        math.floor((c[2] or 1) * 255 + 0.5),
        math.floor((c[3] or 1) * 255 + 0.5))
end
for i, e in ipairs(HDG.Constants.EXPANSION_DATA) do
    LC.widgets["mogulPanel.goblinExp_" .. e.short] = {
        tooltip = false,
        kind = "button", ["in"] = "mogul.goblinExpRow", font = "small",
        text = _expHex(e.color) .. e.short .. "|r",
        width = "auto", height = 20, order = 10 + i, variant = "tertiary",
        binding = { active = "goblin.expActive_" .. e.short },
    }
end
