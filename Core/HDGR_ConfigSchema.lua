-- HDG.ConfigSchema
-- ============================================================================


HDG = HDG or {}

local Scope = HDG.Constants.ConfigScope

HDG.ConfigSchema = {
    ByOption = {}, -- OPTION_NAME -> "sv_key"  (Config:Get / Config:Set sites)
    Defaults = {}, -- "sv_key" -> default value  (ImportDefaultsToProfile)
    ScopeBy  = {}, -- "sv_key" -> Scope constant  (Config:_GetSourceForScope)
}
local C = HDG.ConfigSchema

-- Register one setting -- called once per option, the same one-call-per-setting
-- shape as Settings.RegisterAddOnSetting(category, name, variableKey, ...).
local function setting(optionName, key, default, scope)
    C.ByOption[optionName] = key
    C.Defaults[key]        = default
    C.ScopeBy[key]         = scope
end

-- ===== Appearance ==========================================================
setting("THEME", "scheme", HDG.Constants.DEFAULT_SCHEME, Scope.Profile)
setting("DECOR_PREVIEW_BG", "decorPreviewBg", "default", Scope.Profile)
setting("SCALE", "scale", 1.0, Scope.Profile)
setting("FONT", "fontFamily", "default", Scope.Profile)
setting("LOCALE", "locale", "", Scope.Profile)

-- ===== Debug ===============================================================
setting("DEBUG", "debug", false, Scope.Profile)
setting("MOCK_TSM", "mockTSM", false, Scope.Profile)
-- ===== Minimap / AddonCompartment / Interface ==============================
setting("SHOW_MINIMAP_BUTTON", "showMinimapButton", true, Scope.Profile)
setting("SHOW_COMPARTMENT", "showCompartment", true, Scope.Profile)
setting("SHOW_PROFESSION_BUTTONS", "showProfessionButtons", true, Scope.Profile)
setting("TOOLTIP_DECOR_TAG", "tooltipDecorTag", true, Scope.Profile)
setting("CATALOG_TOOLTIP", "catalogTooltip", true, Scope.Profile)
setting("BAG_BADGE", "bagBadge", true, Scope.Profile)
setting("MERCHANT_DECOR_OVERLAY", "merchantDecorOverlay", true, Scope.Profile)
setting("MERCHANT_QTY_PICKER", "merchantQtyPicker", false, Scope.Profile)
setting("MERCHANT_QTY_PICKER_AUTO_CLOSE", "merchantQtyPickerAutoClose", false, Scope.Profile)
-- Off by default: SetItemByID on a material row pulls in Blizzard's whole item
-- block plus every other addon's TooltipDataProcessor lines, which is the
-- visibility problem the title-only material tooltip was chosen to avoid.
setting("MATERIAL_TOOLTIP_ITEM_DATA", "materialTooltipItemData", false, Scope.Profile)
setting("CATALOG_DECOR_OVERLAY", "catalogDecorOverlay", true, Scope.Profile)
setting("AUTO_DEPOSIT_LUMBER", "autoDepositLumber", false, Scope.Profile)
setting("HIDE_IN_COMBAT", "hideInCombat", true, Scope.Profile)
setting("PREFERRED_PRICE_ADDON", "preferredPriceAddon", nil, Scope.Profile)
setting("TSM_PRICE_MODE", "tsmPriceMode", "min", Scope.Profile)

-- ===== Zone Scanner ========================================================
setting("ZONE_SCANNER_ENABLED", "zoneScannerEnabled", true, Scope.Profile)
setting("ZONE_SCANNER_POPUP", "zoneScannerPopup", false, Scope.Profile)
setting("ZONE_SCANNER_POPUP_SHOPPING", "zoneScannerPopupShopping", false, Scope.Profile)
setting("ZONE_SCANNER_CHAT", "zoneScannerChat", true, Scope.Profile)
setting("ZONE_SCANNER_SOUND", "zoneScannerSound", false, Scope.Profile)
setting("ZONE_SCANNER_TRACK_SHOPPING", "zoneScannerTrackShopping", true, Scope.Profile)

-- ===== Waypoint provider ===================================================
setting("WAYPOINT_PROVIDER", "waypointProvider", "auto", Scope.Profile)

-- ===== One-time migration flags ============================================
-- Each migration sets its flag true after running so it doesn't repeat.
-- See HDGR_Config:_runMigrations.
setting("MIGRATED_LEGACY_CONFIG_TO_PROFILE", "migrated_legacyConfig", false, Scope.Account)
