-- HDGR_LayoutConfig_Config.lua
-- ============================================================================
-- Per-tab LayoutConfig file. Mutates HDG.LayoutConfig at file-load time
-- after the main UI/HDGR_LayoutConfig.lua has assembled the base table.
--
-- Config tab layout: settings (left) + theme preview (right).
--   configPanel         (col 1) -- Appearance, Auction, About, Danger Zone
--   themeInspectorPanel (col 2) -- player-facing theme preview
--
-- Widget substitutions (kind not registered):
--   scaleSlider  -> +/- button pair dispatching CONFIG_SET{key="scale"}
--   pillGroup    -> individual kind="button" per pill

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View ==================================================================

LC.window.views.config = {
    controllers = { "config" },
    width    = "auto",       -- 4 + 600 + 4 + 320 + 4 = 932
    height   = "auto",
    columns  = { 600, 320 },  -- settings (left) + single-column Theme Preview (right)
    -- Body row sized for the Theme Preview column (the taller of the two):
    -- panel header (34) + lg padding (16) + content [5 group headers @16 + 17
    -- sample rows @14 + 2 button rows @26 = 370, + 23 sm gaps @4 = 92 -> 462] = 512.
    -- Adjust if rows/categories change.
    rows     = { 516 },      -- chrome/status rows removed (HDG-ADR-025 slots)
    cells    = {
        body      = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        inspector = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================
LC.panels.configPanel = {
    kind = "panel",
    cell = { config = "body" },
    visibleInViews = { "config" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- Theme preview panel: right column.
LC.panels.themeInspectorPanel = {
    kind = "panel",
    cell = { config = "inspector" },
    visibleInViews = { "config" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections -- configPanel body ==========================================
LC.sections["config.body"] = {
    ["in"]  = "configPanel",
    layout  = "vertical",
    padding = "lg",
    gap     = "sm",
    order   = 10,
}

-- ---- Appearance section header + content ------------------------------------

LC.sections["config.appearanceHeader"] = {
    ["in"] = "config.body", layout = "horizontal",
    height = 20, gap = "md", order = 10,
}
LC.sections["config.appearance"] = {
    ["in"] = "config.body", layout = "vertical",
    height = "content",   -- prevent flex distribution (Layout.lua:509)
    gap = 8, order = 11,
}
-- Theme row inside appearance
LC.sections["config.themeRow"] = {
    ["in"] = "config.appearance", layout = "horizontal",
    height = 24, gap = "md", order = 10,
}
-- Scale row inside appearance
LC.sections["config.scaleRow"] = {
    ["in"] = "config.appearance", layout = "horizontal",
    height = 24, gap = "md", order = 20,
}

-- ---- Lumber Tracker section header + content --------------------------------

LC.sections["config.lumberHeader"] = {
    ["in"] = "config.body", layout = "horizontal",
    height = 20, gap = "md", order = 20,
}
LC.sections["config.lumber"] = {
    ["in"] = "config.body", layout = "vertical",
    height = "content",   -- prevent flex distribution
    gap = 8, order = 21,
}
LC.sections["config.lumberAutoShowRow"] = {
    ["in"] = "config.lumber", layout = "horizontal",
    height = 24, gap = "md", order = 10,
}

-- ---- Auction / Shopping section: REMOVED (moved to Goblin header/footer) -----
-- See the widget-section note below; no auction sections remain on Config.

-- ---- About section header + content -----------------------------------------

LC.sections["config.aboutHeader"] = {
    ["in"] = "config.body", layout = "horizontal",
    height = 20, gap = "md", order = 30,
}
LC.sections["config.about"] = {
    ["in"] = "config.body", layout = "vertical",
    height = "content",   -- prevent flex distribution
    gap = 8, order = 31,
}
LC.sections["config.discordRow"] = {
    ["in"] = "config.about", layout = "horizontal",
    height = 28, gap = "sm", order = 10,
}
LC.sections["config.coffeeRow"] = {
    ["in"] = "config.about", layout = "horizontal",
    height = 28, gap = "sm", order = 20,
}
-- (config.otherSettingsRow removed: the button moved to the Config title bar.)

-- ---- Danger Zone section header + content -----------------------------------

LC.sections["config.dangerHeader"] = {
    ["in"] = "config.body", layout = "horizontal",
    height = 20, gap = "md", order = 40,
}
LC.sections["config.danger"] = {
    ["in"] = "config.body", layout = "vertical",
    height = "content",   -- prevent flex distribution
    gap = 8, order = 41,
}
LC.sections["config.collectionResetRow"] = {
    ["in"] = "config.danger", layout = "horizontal",
    height = 28, gap = "md", order = 10,
}
LC.sections["config.hardResetRow"] = {
    ["in"] = "config.danger", layout = "horizontal",
    height = 28, gap = "md", order = 20,
}

-- ---- Special Thanks section header + scrollbox ------------------------------
-- Scrollbox absorbs remaining vertical space in config.body (height="fill").
-- Content scrolls when contributor list exceeds available height.

LC.sections["config.creditsHeader"] = {
    ["in"] = "config.body", layout = "horizontal",
    height = 20, gap = "md", order = 50,
}
LC.sections["config.credits"] = {
    ["in"] = "config.body", layout = "vertical",
    height = "fill",   -- absorbs remaining space after content sections
    gap = 0, order = 51,
}

-- ===== Widgets ===============================================================

LC.widgets["configPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "configPanel", slot = "header",
    text = "locale:CFG_PANEL_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
-- Spacer: title (left) -> Main Settings button (right).
LC.widgets["configPanel.headerSpacer"] = {
    tooltip = false,
    kind = "spacer", ["in"] = "configPanel", slot = "header",
    width = "fill", height = 22, order = 15,
}
-- Main Settings: opens HDG's category in the Blizzard Settings menu.
-- Lives in the title bar (right). Wired in ConfigController (same widget name).
LC.widgets["configPanel.otherSettingsBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "configPanel", slot = "header", font = "small",
    text = "locale:CFG_MAIN_SETTINGS_BTN", width = "auto", height = 22, order = 20, variant = "tertiary",
}

-- ---- Appearance section ------------------------------------------------------

LC.widgets["configPanel.appearanceSectionLabel"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "config.appearanceHeader",
    text = "locale:CFG_APPEARANCE_SECTION", font = "small",
    width = "fill", height = 16, order = 10,
}

-- Theme row: label + dropdown. Dispatches CONFIG_SET{key="scheme"}.
LC.widgets["configPanel.themeLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "config.themeRow", font = "body",
    text = "locale:CFG_THEME_LABEL", width = 120, height = 22, order = 10,
}
LC.widgets["configPanel.themeDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "config.themeRow",
    -- height=25: WowStyle2DropdownTemplate native height; shrinking misaligns the Background atlas.
    width = 240, height = 25, order = 20,
    placeholder = "locale:CFG_THEME_PLACEHOLDER",
    binding   = { menu = "config.themeMenuItems", current = "config.theme" },
    setConfig = { key = "scheme" },
}

-- (Font picker lives in Blizzard Settings -> Advanced, below Language.)

-- Scale row: label + +/- pair. Quick-access surface; same CONFIG_SET{key="scale"} as Blizzard Settings.
LC.widgets["configPanel.scaleLabel"] = {
    tooltip = false,
    kind = "label", ["in"] = "config.scaleRow", font = "body",
    text = "locale:CFG_SCALE_LABEL", width = 120, height = 22, order = 10,
}
LC.widgets["configPanel.scaleDecBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "config.scaleRow", font = "small",
    text = "-", width = 24, height = 22, order = 20, variant = "tertiary",
}
LC.widgets["configPanel.scaleValue"] = {
    tooltip = false,
    kind = "label", ["in"] = "config.scaleRow", font = "body",
    text = "1.0", width = 40, height = 22, order = 30,
    binding = "config.scale",
}
LC.widgets["configPanel.scaleIncBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "config.scaleRow", font = "small",
    text = "+", width = 24, height = 22, order = 40, variant = "tertiary",
}

-- ---- Lumber Tracker section --------------------------------------------------
-- Auto-open toggle. Mirrors the Warehouse-tab toggle: same selector
-- (warehouse.autoShowLumber) + same action (LUMBER_AUTOSHOW_TOGGLE), so the two
-- stay in sync automatically via the binding engine.
LC.widgets["configPanel.lumberSectionLabel"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "config.lumberHeader",
    text = "locale:CFG_LUMBER_SECTION", font = "small",
    width = "fill", height = 16, order = 10,
}
LC.widgets["configPanel.lumberAutoShowToggle"] = {
    tooltip = { recipe = "LumberAutoShow" },
    kind = "checkbox", ["in"] = "config.lumberAutoShowRow", font = "body",
    text = "locale:WARE_AUTOSHOW_TOGGLE", width = 240, height = 22, order = 10,
    binding = { checked = "warehouse.autoShowLumber" },
}

-- ---- Auction / Shopping ------------------------------------------------------
-- Relocated 2026-06: the price-source selector + "Refresh from AH" now live in the
-- Goblin (Mogul) header, and the direct-cache freshness line sits in the Goblin
-- footer beside the item count. The TSM-mode pills were retired (TSM_PRICE_MODE
-- still defaults via config). Nothing auction-related remains on the Config tab.

-- ---- About section ----------------------------------------------------------

LC.widgets["configPanel.aboutSectionLabel"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "config.aboutHeader",
    text = "locale:CFG_ABOUT_SECTION", font = "small",
    width = "fill", height = 16, order = 10,
}

-- Discord link.
LC.widgets["configPanel.discordLink"] = {
    tooltip = { recipe = "Discord" },
    kind = "linkRow", ["in"] = "config.discordRow",
    icon  = HDG.Constants.DISCORD_TEXTURE,
    label = "locale:CFG_DISCORD_LABEL",
    url   = HDG.Constants.DISCORD_URL,
    width = "fill", height = 24, order = 10,
}

-- Coffee link.
LC.widgets["configPanel.coffeeLink"] = {
    tooltip = { recipe = "Coffee" },
    kind = "linkRow", ["in"] = "config.coffeeRow",
    iconAtlas = "auctionhouse-icon-coin",
    label = "locale:CFG_COFFEE_LABEL",
    url   = HDG.Constants.COFFEE_URL,
    width = "fill", height = 24, order = 10,
}

-- (Other Settings button moved to the Config title bar as "Main Settings".)

-- ---- Danger Zone section ----------------------------------------------------

LC.widgets["configPanel.dangerSectionLabel"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "config.dangerHeader",
    text = "locale:CFG_DANGER_SECTION", font = "small",
    width = "fill", height = 16, order = 10,
}

-- Collection reset: single click dispatches COLLECTION_RESET + ReconcileFull.
LC.widgets["configPanel.collectionResetBtn"] = {
    tooltip = { recipe = "ConfigCollectionReset" },
    kind = "button", ["in"] = "config.collectionResetRow", font = "body",
    text = "locale:CFG_COLLECTION_RESET_BTN", width = 200, height = 24, order = 10,
    variant = "tertiary",
}
LC.widgets["configPanel.collectionResetHint"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "config.collectionResetRow", font = "caption",
    text = "locale:CFG_COLLECTION_RESET_HINT",
    width = "fill", height = 14, order = 20,
}

-- Hard reset (click-again confirm).
LC.widgets["configPanel.hardReset"] = {
    tooltip = { recipe = "WarnHardReset" },
    kind = "button", ["in"] = "config.hardResetRow", font = "body",
    text = "locale:CFG_HARD_RESET_BTN", width = 160, height = 24, order = 10,
    textTone = "error",
}
LC.widgets["configPanel.hardResetHint"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "config.hardResetRow", font = "caption",
    text = "locale:CFG_HARD_RESET_HINT",
    width = "fill", height = 14, order = 20,
}

-- ---- Special Thanks section -------------------------------------------------

LC.widgets["configPanel.creditsSectionLabel"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "config.creditsHeader",
    text = "locale:CFG_CREDITS_SECTION", font = "small",
    width = "fill", height = 16, order = 10,
}

-- Credits scrollbox: static row list from config.creditsRows selector.
-- height="fill" absorbed by config.credits section; scrolls when list overflows.
LC.widgets["configPanel.creditsScroll"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "config.credits",
    binding = "config.creditsRows",
    rowKind = "configCreditRow",
    spacing = 2,
    width = "fill", height = "fill", order = 10,
}

-- ===== Theme Preview (right column) ==========================================
-- Player-facing preview: Text / Items / Status / Surfaces groups.
-- Dev-only tokens (inverse, link_hover, ghost/tertiary) are excluded.
-- Widget key convention:
--   text rows  : themeInspectorPanel.sample_<token>   (Theme:GetColor("text." .. token))
--   ui rows    : themeInspectorPanel.uisample_<safe>  (Theme:GetColor(row.token))

-- inspector.body: single vertical column holding the curated preview.
LC.sections["inspector.body"] = {
    ["in"]  = "themeInspectorPanel",
    layout  = "vertical",
    padding = "lg",
    gap     = "sm",
    order   = 10,
}

-- Helper: text-color sample row (painted via Theme:GetColor("text." .. tokenKey)).
local function addTextSample(sectionID, tokenKey, friendlyLabel, order)
    LC.sections[sectionID] = {
        ["in"] = "inspector.body", layout = "horizontal",
        height = 14, gap = "md", order = order,
    }
    LC.widgets["themeInspectorPanel.label_" .. tokenKey] = {
        tooltip = false,
        kind = "label", role = "TextDim", ["in"] = sectionID,
        text = friendlyLabel, font = "caption",
        width = 130, height = 14, order = 10,
    }
    LC.widgets["themeInspectorPanel.sample_" .. tokenKey] = {
        tooltip = false,
        kind = "label", role = "Text", ["in"] = sectionID,
        text = "AaBbCc 1234567", font = "body",
        width = "fill", height = 14, order = 20,
    }
end

-- Helper: UI-token sample row. "fg" paints text; "bg" builds a SetColorTexture swatch.
local function addUISample(sectionID, dottedToken, friendlyLabel, fgOrBg, order)
    local safe = dottedToken:gsub("%.", "_")
    LC.sections[sectionID] = {
        ["in"] = "inspector.body", layout = "horizontal",
        height = 14, gap = "md", order = order,
    }
    LC.widgets["themeInspectorPanel.uilabel_" .. safe] = {
        tooltip = false,
        kind = "label", role = "TextDim", ["in"] = sectionID,
        text = friendlyLabel, font = "caption",
        width = 130, height = 14, order = 10,
    }
    LC.widgets["themeInspectorPanel.uisample_" .. safe] = {
        tooltip = false,
        kind = "label", role = "Text", ["in"] = sectionID,
        text = (fgOrBg == "bg") and "" or "AaBbCc 1234567",
        font = "body",
        width = "fill", height = 14, order = 20,
    }
end

-- Helper: group header inside the inspector column.
local function addGroupHeader(sectionID, widgetKey, headerText, order)
    LC.sections[sectionID] = {
        ["in"] = "inspector.body", layout = "horizontal",
        height = 16, order = order,
    }
    LC.widgets["themeInspectorPanel." .. widgetKey] = {
        tooltip = false,
        kind = "label", role = "TextHeading", ["in"] = sectionID,
        text = headerText, font = "small",
        width = "fill", height = 14, order = 10,
    }
end

-- ----- Group: Text ----------------------------------------------------------
addGroupHeader("inspector.textHeader", "textGroupHeader", "Text", 5)
addTextSample("inspector.row_heading",  "heading",  "Headings",      11)
addTextSample("inspector.row_primary",  "primary",  "Body text",     12)
addTextSample("inspector.row_muted",    "muted",    "Muted text",    13)
addTextSample("inspector.row_disabled", "disabled", "Disabled text", 14)
addTextSample("inspector.row_link",     "link",     "Links",         15)
addTextSample("inspector.row_numeric",  "numeric",  "Numbers",       16)

-- ----- Group: Items ---------------------------------------------------------
addGroupHeader("inspector.itemsHeader", "itemsGroupHeader", "Items", 20)
addTextSample("inspector.row_collected",   "collected",   "Collected",         21)
addTextSample("inspector.row_uncollected", "uncollected", "Not yet collected", 22)

-- ----- Group: Status --------------------------------------------------------
addGroupHeader("inspector.diagHeader", "diagGroupHeader", "Status", 30)
addUISample("inspector.uirow_diag_error", "diag.error", "Errors",   "fg", 31)
addUISample("inspector.uirow_diag_warn",  "diag.warn",  "Warnings", "fg", 32)
addUISample("inspector.uirow_diag_info",  "diag.info",  "Info",     "fg", 33)
addUISample("inspector.uirow_diag_hint",  "diag.hint",  "Hints",    "fg", 34)

-- ----- Group: Surfaces ------------------------------------------------------
addGroupHeader("inspector.surfaceHeader", "surfaceGroupHeader", "Surfaces", 40)
addUISample("inspector.uirow_tab_active_bg",      "tab.active.bg",      "Active tab",     "bg", 41)
addUISample("inspector.uirow_surface_statusline", "surface.statusline", "Status bar",     "bg", 42)
addUISample("inspector.uirow_popup_selected_bg",  "popup.selected.bg",  "Selected menu",  "bg", 43)
addUISample("inspector.uirow_float_bg",           "float.bg",           "Tooltip",        "bg", 44)
addUISample("inspector.uirow_float_border",       "float.border",       "Tooltip border", "fg", 45)


LC.widgets["themeInspectorPanel.title"] = {
    tooltip = false,
    kind = "label", role = "TextHeading", ["in"] = "themeInspectorPanel", slot = "header",
    text = "locale:CFG_THEME_PREVIEW_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
