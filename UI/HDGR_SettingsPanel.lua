-- HDGR_SettingsPanel.lua
-- ============================================================================
-- Blizzard Settings panel registration. Deferred to PLAYER_LOGIN via
-- HDG.InitSettingsPanel() (Settings infrastructure not ready before that).
--
-- Structure:
--   Housing Decor Guide (main category)
--     Open / Reset buttons (Special Thanks moved to the Config tab)
--   Housing Decor Guide / Interface (subcategory)
--     General: minimap, compartment, profession buttons
--     Zone Scanner: master toggle + popup/chat/sound sub-flags
--   Housing Decor Guide / Helpers: decor sourcing tooltip + reagent-use tooltip
--   Housing Decor Guide / Advanced: debug, mockTSM, scale, waypoint, locale, font
--   Housing Decor Guide / Profiles: active profile dropdown + New/Delete
--
-- All controls have AddSearchTags for Blizzard's settings search.
--
-- Lumber Tracking has its own window (HDGR_Controller_Lumber.lua) + in-window
--   config -- intentionally NOT bound into this panel.
-- TODO Flavour: HDG.Quotes module not yet implemented.

HDG = HDG or {}

-- ===== Mixin (subclass of SettingsExpandableSectionMixin) ====================
-- SettingsInbound.RepairDisplay() is only safe inside a registered Settings panel context.

HDGR_SettingsExpandSectionMixin = CreateFromMixins(SettingsExpandableSectionMixin)

function HDGR_SettingsExpandSectionMixin:Init(initializer)
    SettingsExpandableSectionMixin.Init(self, initializer)
    self.data = initializer.data
end

function HDGR_SettingsExpandSectionMixin:OnExpandedChanged(expanded)
    self:EvaluateVisibility(expanded)
    SettingsInbound.RepairDisplay()
end

function HDGR_SettingsExpandSectionMixin:CalculateHeight()
    return 24
end

-- ===== Checkbox-left settings row mixin (HDGR_SettingsCheckRowTemplate) =====
-- Subclasses SettingsCheckboxControlMixin; re-anchors checkbox to LEFT so the
-- label fills the rest of the row (Delves-Helper layout).
HDGR_SettingsCheckRowMixin = CreateFromMixins(SettingsCheckboxControlMixin)

function HDGR_SettingsCheckRowMixin:Init(initializer)
    SettingsCheckboxControlMixin.Init(self, initializer)
    -- Base Init anchors checkbox at CENTER,-80 (truncates long names). Re-anchor:
    -- checkbox hard-left, label from checkbox's right edge to row edge.
    local indent = self:GetIndent()
    self.Checkbox:ClearAllPoints()
    self.Checkbox:SetPoint("LEFT", self, "LEFT", indent + 8, 0)
    self.Text:ClearAllPoints()
    self.Text:SetPoint("LEFT", self.Checkbox, "RIGHT", 6, 0)
    self.Text:SetPoint("RIGHT", self, "RIGHT", -8, 0)
    self.Text:SetJustifyH("LEFT")
end

-- ===== Slider range constants (same values as HDGR_Controller_Config.lua) ===
-- Both surfaces route through CONFIG_SET { key = "scale" } -> HDGR_MainFrame subscriber.
local SCALE_STEP = 0.1
local SCALE_MIN  = 0.5
local SCALE_MAX  = 1.5

-- ===== Keys reset by "Reset all settings" ====================================
-- Keep in sync with settings registered below. Values pulled from GetDefaultConfig().
local RESETTABLE_KEYS = {
    "showMinimapButton", "showCompartment", "showProfessionButtons", "tooltipDecorTag",
    "catalogTooltip", "bagBadge", "materialTooltipItemData",
    "merchantDecorOverlay", "merchantQtyPicker", "merchantQtyPickerAutoClose", "catalogDecorOverlay", "autoDepositLumber", "hideInCombat", "waypointProvider", "scale",
    "debug", "mockTSM", "locale", "fontFamily",
    "zoneScannerEnabled", "zoneScannerPopup", "zoneScannerPopupShopping",
    "zoneScannerChat", "zoneScannerSound", "zoneScannerTrackShopping",
}

-- ===== Search tags (synonyms for Blizzard's settings search) =================
local SEARCH_TAGS = {
    showMinimapButton      = { "minimap", "icon", "launcher" },
    showCompartment        = { "compartment", "drawer", "icon" },
    showProfessionButtons  = { "profession", "trade skill", "filter" },
    tooltipDecorTag        = { "tooltip", "reagent", "decor", "crafting", "recipe", "bag" },
    catalogTooltip         = { "tooltip", "decor", "source", "cost", "catalog", "helper" },
    materialTooltipItemData = { "tooltip", "item", "material", "reagent", "warehouse", "altoholic", "auction" },
    bagBadge               = { "bag", "badge", "icon", "reagent", "decor", "marker", "helper" },
    merchantDecorOverlay   = { "vendor", "merchant", "decor", "collected", "marker", "helper" },
    merchantQtyPicker      = { "vendor", "merchant", "buy", "quantity", "picker", "bulk", "purchase" },
    catalogDecorOverlay    = { "catalog", "decor", "uncollected", "marker", "plus", "helper" },
    autoDepositLumber      = { "lumber", "warband", "bank", "deposit", "auto", "helper" },
    hideInCombat           = { "combat", "hide", "auto", "fight", "lockdown" },
    waypointProvider       = { "waypoint", "map", "pin", "tomtom" },
    scale                  = { "scale", "size", "zoom", "ui" },
    debug                  = { "debug", "log", "verbose" },
    mockTSM                = { "tsm", "mock", "price", "auction", "debug" },
    locale                 = { "language", "locale", "translation" },
    fontFamily             = { "font", "arial", "narrow", "typeface", "cyrillic" },
    zoneScannerEnabled     = { "zone", "alert", "scanner", "vendor" },
    zoneScannerPopup       = { "zone", "popup", "alert" },
    zoneScannerPopupShopping = { "zone", "popup", "shopping", "list", "alert" },
    zoneScannerChat        = { "zone", "chat", "alert" },
    zoneScannerSound       = { "zone", "sound", "alert" },
}

local function ApplyTags(initializer, key)
    local tags = SEARCH_TAGS[key]
    if not tags then return end
    initializer:AddSearchTags(unpack(tags))
end

-- ===== BindSetting helper ====================================================
-- Registers an addon setting bound to HDG_DB.account.config[configKey].
-- User change -> CONFIG_SET dispatch. Store change -> pushes into Settings widget
-- so external changes (slash commands, window buttons) reflect in the panel.

local function BindSetting(cat, configKey, settingName, varType)
    local default = HDG.Store:GetConfig(configKey)

    -- Binds to HDG_DB.account.config so Blizzard's serialize path sees the value.
    -- Store is SSoT; both surfaces kept in sync.
    local setting = Settings.RegisterAddOnSetting(
        cat,
        "HDGR_" .. configKey,     -- unique variable identifier
        configKey,                 -- variableKey inside variableTbl
        HDG_DB.account.config,   -- variableTbl: the persisted table
        varType,
        settingName,
        default
    )

    -- User changed value via Settings panel -> dispatch into Store.
    setting:SetValueChangedCallback(function(_, value)
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.CONFIG_SET,
            payload = { key = configKey, value = value },
        })
    end)

    -- Equality short-circuit: Blizzard's SetValue fires SetValueChangedCallback even
    -- when the value hasn't changed, which would cascade into a CONFIG_SET storm on
    -- "*" invalidation (HARD_RESET / PROFILE_SWITCH). Guard with GetValue() != newValue.
    local watchPaths = { "account.config." .. configKey }
    HDG.Store:Subscribe(function(_, invalidation)
        if HDG.Paths.MatchesAny(watchPaths, invalidation) then
            local newValue = HDG.Store:GetConfig(configKey)
            if setting:GetValue() ~= newValue then
                setting:SetValue(newValue)
            end
        end
    end)

    return setting
end

-- ===== BindProxyBool helper ==================================================
-- Proxy-backed boolean with checkbox-left template. No backing table; getValue reads
-- Store live, setValue dispatches CONFIG_SET. SettingMixin:ApplyValue only calls setValue
-- when the value actually differs -> no re-dispatch loop; no short-circuit needed.
local function BindProxyBool(sub, layout, configKey, settingName, tooltip)
    local A = HDG.Constants.ACTIONS
    local setting = Settings.RegisterProxySetting(
        sub,
        "HDGR_" .. configKey,
        Settings.VarType.Boolean,
        settingName,
        HDG.Store:GetDefaultConfig()[configKey],   -- true default (Blizzard "Defaults" resets to this)
        function() return HDG.Store:GetConfig(configKey) end,
        function(value)
            HDG.Store:Dispatch({ type = A.CONFIG_SET, payload = { key = configKey, value = value } })
        end
    )
    local init = Settings.CreateControlInitializer("HDGR_SettingsCheckRowTemplate", setting, nil, tooltip)
    layout:AddInitializer(init)
    ApplyTags(init, configKey)
    -- Mirror Store changes (slash command, Reset-all) into an open panel.
    HDG.Store:Subscribe(function(_, invalidation)
        if HDG.Paths.MatchesAny({ "account.config." .. configKey }, invalidation) then
            setting:SetValue(HDG.Store:GetConfig(configKey))
        end
    end)
    return setting, init
end

-- ===== Reset popup ===========================================================
-- Iterates RESETTABLE_KEYS and dispatches CONFIG_SET per key with canonical defaults.
-- All subscribers (BindSetting, scale forwarder, zone alert engine) react normally.

local function RegisterResetPopup()
    if _G.StaticPopupDialogs["HDGR_SETTINGS_RESET"] then return end
    _G.StaticPopupDialogs["HDGR_SETTINGS_RESET"] = {
        text         = "Reset all Housing Decor Guide settings to defaults?\n\nThis cannot be undone.",
        button1      = ACCEPT,
        button2      = CANCEL,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        OnAccept     = function()
            local defaults = HDG.Store:GetDefaultConfig()
            local A = HDG.Constants.ACTIONS
            for _, key in ipairs(RESETTABLE_KEYS) do
                HDG.Store:Dispatch({
                    type    = A.CONFIG_SET,
                    payload = { key = key, value = defaults[key] },
                })
            end
        end,
    }
end

-- ===== Profile management popups ============================================
-- New/Delete fan out through StaticPopups -> HDG.Config (same dispatch path
-- as programmatic NewProfile / DeleteProfile). DEFAULT cannot be deleted;
-- deleting the active profile switches to DEFAULT first.

local function RegisterProfilePopups()
    HDG.UI:RegisterInputDialog("HDGR_PROFILE_NEW", {
        text       = "Create a new profile.\n\nThe new profile starts as a copy of the active profile, then becomes active.",
        maxLetters = 32,
        onAccept   = function(value)
            if value == "" then return end
            if HDG_DB.profiles[value] then
                -- Name collision -- print and bail (popup-from-popup is a rabbit hole).
                HDG.Log:Notify("warn", "profile '" .. value .. "' already exists.")
                return
            end
            HDG.Config:NewProfile(value, true)   -- clone from active
            HDG.Config:SwitchProfile(value)
        end,
    })
    if not _G.StaticPopupDialogs["HDGR_PROFILE_DELETE"] then
        _G.StaticPopupDialogs["HDGR_PROFILE_DELETE"] = {
            text         = "Delete profile '%s'?\n\nIf this is the active profile, you'll be switched to DEFAULT first.\n\nThis cannot be undone.",
            button1      = ACCEPT,
            button2      = CANCEL,
            timeout      = 0,
            whileDead    = true,
            hideOnEscape = true,
            OnAccept     = function(self, data)
                local name = data and data.name
                if not name or name == "DEFAULT" then return end
                if HDG.Config:GetActiveProfile() == name then
                    HDG.Config:SwitchProfile("DEFAULT")
                end
                HDG.Config:DeleteProfile(name)
            end,
        }
    end
end

-- ===== Subcategory builders ==================================================

-- Main category page: action buttons + credits. Functional settings live in subcategories.
local function _buildMainPage(layout)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Housing Decor Guide"))

    -- Open HDG window via MAIN_WINDOW_TOGGLE (same path as minimap/slash/compartment).
    layout:AddInitializer(CreateSettingsButtonInitializer(
        "",
        "Open Housing Decor Guide",
        function()
            HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MAIN_WINDOW_TOGGLE })
        end,
        "Open the main HDG window. If it's already open, this closes it.",
        true
    ))

    layout:AddInitializer(CreateSettingsButtonInitializer(
        "",
        "Reset all settings to defaults",
        function() _G.StaticPopup_Show("HDGR_SETTINGS_RESET") end,
        "Resets every Housing Decor Guide setting on this panel back to its default value. Asks for confirmation first.",
        true
    ))

    -- Recovery for a lost/stuck minimap button: seeds a known position angle so
    -- LibDBIcon stops falling back to its lower-left default. Fixes the case a
    -- game crash cleared the saved position (SavedVariables never flushed).
    layout:AddInitializer(CreateSettingsButtonInitializer(
        "",
        "Reset minimap button position",
        function() HDG.MinimapButton:ResetPosition() end,
        "Moves the HDG minimap button back to a default spot on the minimap. Use this if the button "
            .. "has gone missing or snaps to the lower-left corner every time you open HDG (this can "
            .. "happen after a game crash clears its saved position).",
        true
    ))

    -- Special Thanks moved to the Config tab's credits scrollbox (see HDGR_LayoutConfig_Config.lua).
end

-- Interface: minimap, compartment, profession buttons, tooltip, scale, waypoint.
local function _buildInterfaceSubcategory(category)
    local sub, layout = Settings.RegisterVerticalLayoutSubcategory(category, "Interface")

    local interfaceBools = {
        { key = "showMinimapButton",     name = "Show minimap button",
          desc = "Show the HDG launcher button on the minimap." },
        { key = "showCompartment",        name = "Show in addon compartment",
          desc = "Enable click and tooltip handlers in Blizzard's addon compartment drawer. "
              .. "The icon itself always appears (Blizzard limitation); disable it via Edit Mode." },
        { key = "showProfessionButtons",  name = "Show profession window buttons",
          desc = "Inject 'Decor Guide' and 'Filter Decor' buttons into the Professions window." },
        { key = "hideInCombat",           name = "Hide windows in combat",
          desc = "Automatically hide all HDG windows when you enter combat, and "
              .. "restore the ones that were open when combat ends." },
    }
    -- Checkbox-left rows via proxy backing. Slider + dropdown use stock controls.
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("General"))
    for _, entry in ipairs(interfaceBools) do
        BindProxyBool(sub, layout, entry.key, entry.name, entry.desc)
    end

    -- (HDG window scale + Waypoint provider moved to the Advanced subcategory.)

    -- Zone Scanner: master toggle + sub-flags greyed out when master is off
    -- (SetParentInitializer, matching ZoneAlertEngine's short-circuit).
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Zone Scanner"))
    local zoneMasterSetting, zoneMasterInit = BindProxyBool(sub, layout, "zoneScannerEnabled",
        "Enable Zone Scanner",
        "Scan the current zone for missing decor vendors when you enter a new area.")
    local zoneSubFlags = {
        { key = "zoneScannerPopup", name = "Show popup for uncollected decor",
          desc = "Display a popup window when the zone has vendors selling decor you haven't collected." },
        { key = "zoneScannerPopupShopping", name = "Show popup for shopping-list items",
          desc = "Display a popup window when a vendor in the zone sells an item on a shopping list." },
        { key = "zoneScannerChat",  name = "Print chat alert",
          desc = "Print a chat message when a zone alert fires." },
        { key = "zoneScannerSound", name = "Play alert sound",
          desc = "Play a sound when a zone alert fires." },
    }
    for _, entry in ipairs(zoneSubFlags) do
        local _, init = BindProxyBool(sub, layout, entry.key, entry.name, entry.desc)
        init:SetParentInitializer(zoneMasterInit, function() return zoneMasterSetting:GetValue() end)
    end
end

-- Helpers: optional convenience features that ride alongside the catalog/editor.
local function _buildHelpersSubcategory(category)
    local sub, layout = Settings.RegisterVerticalLayoutSubcategory(category, "Helpers")

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Tooltips"))
    BindProxyBool(sub, layout, "catalogTooltip", "Show decor sourcing tooltip",
        "Add HDG's sourcing and cost lines to the Housing catalog tooltip when you hover decor.")
    BindProxyBool(sub, layout, "tooltipDecorTag", "Show reagent use in decor crafting",
        "On a reagent's tooltip, show how many decor recipes use it -- flags useful mats "
        .. "before you've learned the recipe. Also tags decor items in your bags (e.g. dropped "
        .. "decor you haven't learned yet) with their source.")
    BindProxyBool(sub, layout, "materialTooltipItemData", "Full item tooltips on material rows",
        "On the Warehouse and Recipes material lists, show the game's own item tooltip above "
        .. "HDG's stock breakdown. Other addons can then add their lines there too -- "
        .. "per-character counts, auction prices, and so on. Off by default because it makes "
        .. "every material hover considerably taller.")

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Bags"))
    BindProxyBool(sub, layout, "bagBadge", "Mark decor reagents in bags",
        "Show a small HDG icon in the top-right corner of bag items used in decor recipes. "
        .. "Works with the default bags, Bagnon, Baganator, and Ellesmere.")

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Vendors"))
    BindProxyBool(sub, layout, "merchantDecorOverlay", "Mark collected decor at vendors",
        "On a vendor's items, a marker in the icon's top-right corner shows "
        .. _G.CreateAtlasMarkup("common-icon-checkmark", 14, 14)
        .. " on housing decor you've collected and "
        .. _G.CreateAtlasMarkup("common-icon-plus", 14, 14, 0, 0, 255, 26, 26)
        .. " on decor you still need. Default merchant window only.")
    BindProxyBool(sub, layout, "merchantQtyPicker", HDG.Locale:Get("CFG_MERCHANT_QTY_PICKER"),
        "Right-click a housing decor item at a vendor to open a quantity picker: set how "
        .. "many to buy, see the total against your gold and decor storage, and buy in one go. "
        .. "Default merchant window only.")

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Catalog"))
    BindProxyBool(sub, layout, "catalogDecorOverlay", "Mark uncollected decor in the catalog",
        "In Blizzard's Housing catalog, put a red plus on decor you have not collected yet. "
        .. "(The catalog's own number only counts stored copies, so placed decor can look "
        .. "uncollected -- this uses your true collection state.)")

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Lumber"))
    BindProxyBool(sub, layout, "autoDepositLumber", "Auto-deposit lumber to the Warband Bank",
        "When you open a banker with Warband Bank access, automatically move all lumber "
        .. "from your bags into the Warband Bank.")
end

-- Advanced: debug, mockTSM, locale dropdown.
local function _buildAdvancedSubcategory(category)
    local sub, layout = Settings.RegisterVerticalLayoutSubcategory(category, "Advanced")

    -- Checkbox-left + proxy-backed bools (match the Interface page).
    BindProxyBool(sub, layout, "debug", "Debug mode",
        "Print internal events and dispatch log to chat. Noisy; for troubleshooting only.")
    BindProxyBool(sub, layout, "mockTSM", "Mock TSM",
        "Debug: pretend TSM is installed and price every item at a flat 100g, so the TSM "
        .. "price path (Goblin profit columns, Profit calc) can be tested without TSM.")

    -- UI scale slider (same range + dispatch path as the in-window +/- buttons).
    local scaleSetting = BindSetting(sub, "scale", "HDG window scale", Settings.VarType.Number)
    local sliderOpts   = Settings.CreateSliderOptions(SCALE_MIN, SCALE_MAX, SCALE_STEP)
    sliderOpts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    local scaleInit = Settings.CreateSlider(
        sub, scaleSetting, sliderOpts,
        "Scale of the Housing Decor Guide window only. Does NOT affect Blizzard's UI scale."
    )
    ApplyTags(scaleInit, "scale")

    -- Waypoint provider dropdown.
    local waypointSetting = BindSetting(sub, "waypointProvider", "Waypoint provider", Settings.VarType.String)
    local function buildWaypointOptions()
        local container = Settings.CreateControlTextContainer()
        container:Add("auto",     "Auto (TomTom if loaded, else Blizzard)")
        container:Add("tomtom",   "TomTom (falls back to Blizzard if not installed)")
        container:Add("blizzard", "Blizzard")
        return container:GetData()
    end
    local waypointInit = Settings.CreateDropdown(
        sub, waypointSetting, buildWaypointOptions,
        "Choose how HDG sets map waypoints. 'Auto' uses TomTom when loaded."
    )
    ApplyTags(waypointInit, "waypointProvider")

    -- exception(boundary): Locale module presence is load-order-dependent; minimal fallback when absent.
    local localeOptions
    if HDG.Locale and HDG.Locale.GetAvailableLocales then  -- exception(boundary): module optional (load-order)
        localeOptions = {}
        for _, entry in ipairs(HDG.Locale:GetAvailableLocales()) do
            localeOptions[#localeOptions + 1] = { value = entry.key, label = entry.label }
        end
    else
        localeOptions = {
            { value = "",     label = "Auto (client locale)" },
            { value = "enUS", label = "English (US)"        },
        }
    end

    local localeSetting = BindSetting(sub, "locale", "Language", Settings.VarType.String)
    local function buildLocaleOptions()
        local container = Settings.CreateControlTextContainer()
        for _, opt in ipairs(localeOptions) do
            container:Add(opt.value, opt.label)
        end
        return container:GetData()
    end
    local localeInit = Settings.CreateDropdown(
        sub, localeSetting, buildLocaleOptions,
        "Language override. 'Auto' uses your WoW client locale. Changes take effect after /reload."
    )
    ApplyTags(localeInit, "locale")

    -- Font face dropdown (just below Language). Only glyph-safe faces: "Default"
    -- = the client's per-locale font, "Arial Narrow" = crisper + carries Cyrillic.
    -- Applies live; never exposes a Latin-only face (would tofu on ruRU/CJK).
    local fontSetting = BindSetting(sub, "fontFamily", "Font", Settings.VarType.String)
    local function buildFontOptions()
        local container = Settings.CreateControlTextContainer()
        container:Add("default", "Default (locale)")
        container:Add("arialn",  "Arial Narrow")
        return container:GetData()
    end
    local fontInit = Settings.CreateDropdown(
        sub, fontSetting, buildFontOptions,
        "Font for HDG's text. 'Default' uses your client's locale font; 'Arial Narrow' is "
        .. "crisper at small sizes and also covers Cyrillic. Applies immediately."
    )
    ApplyTags(fontInit, "fontFamily")
end

-- (Zone Scanner standalone subcategory removed: merged into Interface under "Zone Scanner" header.)

-- Profiles: active-profile dropdown + New/Delete buttons. Dropdown backed by a transient
-- holder table (RegisterAddOnSetting requires variableTbl/variableKey); holder mirrors
-- Config:GetActiveProfile on each Subscribe tick.
local function _buildProfilesSubcategory(category)
    local sub, subLayout = Settings.RegisterVerticalLayoutSubcategory(category, "Profiles")

    local profileHolder = { active = HDG.Config:GetActiveProfile() }
    local profileSetting = Settings.RegisterAddOnSetting(
        sub,
        "HDGR_ProfilesActive",
        "active",
        profileHolder,
        Settings.VarType.String,
        "Active profile",
        HDG.Config:GetActiveProfile()
    )
    profileSetting:SetValueChangedCallback(function(_, value)
        if value and value ~= HDG.Config:GetActiveProfile() then
            HDG.Config:SwitchProfile(value)
        end
    end)

    local function buildProfileOptions()
        local container = Settings.CreateControlTextContainer()
        for _, name in ipairs(HDG.Config:GetProfileNames()) do
            container:Add(name, name)
        end
        return container:GetData()
    end
    local profileInit = Settings.CreateDropdown(
        sub, profileSetting, buildProfileOptions,
        "Choose the active settings profile. Theme is per-character; everything else follows the profile."
    )
    profileInit:AddSearchTags("profile", "preset", "config", "settings")

    -- Mirror to Store changes (PROFILE_SWITCH / _CREATE / _DELETE).
    HDG.Store:Subscribe(function(_, invalidation)
        if HDG.Paths.MatchesAny({ "account.profileList" }, invalidation) then
            profileSetting:SetValue(HDG.Config:GetActiveProfile())
        end
    end)

    subLayout:AddInitializer(CreateSettingsButtonInitializer(
        "",
        "Create new profile...",
        function() _G.StaticPopup_Show("HDGR_PROFILE_NEW") end,
        "Create a new settings profile as a copy of the active profile, then switch to it.",
        true
    ))

    -- Delete: no-op on DEFAULT (can't be deleted).
    subLayout:AddInitializer(CreateSettingsButtonInitializer(
        "",
        "Delete active profile...",
        function()
            local name = HDG.Config:GetActiveProfile()
            if name == "DEFAULT" then
                HDG.Log:Notify("warn", "DEFAULT profile cannot be deleted. Switch to another profile first.")
                return
            end
            _G.StaticPopup_Show("HDGR_PROFILE_DELETE", name, nil, { name = name })
        end,
        "Delete the currently-active profile. DEFAULT can never be deleted.",
        true
    ))
end

-- ===== Panel builder =========================================================

local function BuildSettingsPanel()
    local category, layout = Settings.RegisterVerticalLayoutCategory("Housing Decor Guide")
    Settings.RegisterAddOnCategory(category)
    HDG.SettingsPanel = {
        category = category,
        layout   = layout,
        -- Public API: open Blizzard's Settings panel to HDG's category.
        OpenToCategory = function()
            Settings.OpenToCategory(category:GetID())
        end,
    }

    RegisterResetPopup()
    RegisterProfilePopups()

    _buildMainPage(layout)
    _buildInterfaceSubcategory(category)
    _buildHelpersSubcategory(category)
    _buildAdvancedSubcategory(category)
    _buildProfilesSubcategory(category)

    -- ===== Deferred ============================================================
    -- (Lumber Tracking is a standalone window, not a settings section -- see header.)
    -- TODO Flavour: HDG.Quotes module not yet implemented.
end

-- ===== Public entry point (called from Init.lua OnEnable) ====================

function HDG.InitSettingsPanel()
    if HDG.SettingsPanel then return end  -- exception(false-positive): self-init idempotency guard, not a missing singleton cascade
    -- exception(boundary): RegisterAddOnSetting binds to HDG_DB.account.config. On first-ever
    -- load HDG_DB.account may not exist yet; link it to the live Store account here
    -- (Config has already hydrated state.account.config by this point).
    HDG_DB = HDG_DB or {}
    HDG_DB.account = HDG_DB.account or HDG.Store:GetState().account
    BuildSettingsPanel()
end
