-- HDG.ConfigController
-- ============================================================================
-- Config tab: theme dropdown (self-wired), scale +/-, price source/TSM pills,
-- scan button, collection reset, hard reset (2-click confirm), Settings panel button.
-- Theme inspector repainted in Refresh; all other values are binding-driven.

HDG = HDG or {}
HDG.ConfigController = HDG.ConfigController or {}

local ConfigController = HDG.ConfigController

local HARD_RESET_CONFIRM_WINDOW = 5   -- seconds armed before auto-revert

local dispatch = HDG.ControllerHelpers.Mechanics.DispatchNamed  -- hygiene A13

-- Hard reset: first click arms a 5s window; second click fires HARD_RESET.
-- 0.5s OnUpdate auto-reverts on lapse.
local function _wireHardReset(rootFrame)
    local resetBtn = HDG.UI.W(rootFrame, "configPanel.hardReset")
    local armedAt

    local function setLabel(text, colorToken)
        resetBtn:SetText(text)
        local c = HDG.Theme:GetColor(colorToken)
        resetBtn:GetFontString():SetTextColor(c.r, c.g, c.b, c.a)
    end
    local function revert()
        setLabel("Hard Reset", "semantic.error")
        armedAt = nil
    end

    resetBtn:SetScript("OnClick", function()
        local now = GetTime()
        if armedAt and (now - armedAt) < HARD_RESET_CONFIRM_WINDOW then
            revert()
            HDG:HardReset()
        else
            armedAt = now
            setLabel("Click again to confirm", "semantic.error_deep")
        end
    end)

    resetBtn:HookScript("OnUpdate", function(self, elapsed)
        self._tickAccum = (self._tickAccum or 0) + elapsed
        if self._tickAccum < 0.5 then return end
        self._tickAccum = 0
        if armedAt and (GetTime() - armedAt) >= HARD_RESET_CONFIRM_WINDOW then revert() end
    end)
end

-- ===== Credits row factory ===================================================
-- Three row kinds: creditIntro (wrapped body text), credit (name + note line),
-- creditOutro (wrapped body text). All text via Theme:ColorCode tokens; no
-- inline SetTextColor calls.

local function _layoutCreditRow(row)
    -- Wrapped text FontString (intro / outro / credit line).
    local fs = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(fs, "body")
    HDG.Theme:Register(fs, "Text")
    fs:SetPoint("TOPLEFT",     row, "TOPLEFT",     8, 0)
    fs:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 0)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("MIDDLE")
    fs:SetWordWrap(true)
    row._creditFs = fs
end

local function _paintCreditIntro(row, ed)
    row._creditFs:SetText(ed.text)
end

local function _paintCreditLine(row, ed)
    -- "- <name> - <note>" with accent name, dim note, accent dashes.
    -- note is optional; render just "- <name>" when nil.
    local dash = HDG.Theme:ColorCode("semantic.accent") .. "-|r "
    local name = HDG.Theme:ColorCode("semantic.warning") .. ed.name .. "|r"
    if ed.note and ed.note ~= "" then
        local note = HDG.Theme:ColorCode("text.dim") .. "- " .. ed.note .. "|r"
        row._creditFs:SetText(dash .. name .. " " .. note)
    else
        row._creditFs:SetText(dash .. name)
    end
end

local function _paintCreditOutro(row, ed)
    row._creditFs:SetText(ed.text)
end

local function _resetCreditRow(row)
    if row._creditFs then row._creditFs:SetText("") end
end

local function _creditRowFactory(_def)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_creditLaidOut", function()
                _layoutCreditRow(row)
            end)
            _resetCreditRow(row)
            -- RowChrome skinner tints the hover to surface.hover (+ zebra parity) per paint;
            -- without it EnsureRowChrome's hover stays raw WHITE_TEX -> bright white bar on mouseover.
            HDG.Theme:Register(row, "RowChrome", { selected = false })
            if ed.kind == "creditIntro" then
                _paintCreditIntro(row, ed)
            elseif ed.kind == "credit" then
                _paintCreditLine(row, ed)
            elseif ed.kind == "creditOutro" then
                _paintCreditOutro(row, ed)
            end
        end,
        Reset = function(row)
            _resetCreditRow(row)
        end,
    }
end

HDG.Rows:Register("configCreditRow", {
    font    = "body",
    height  = 20,
    factory = _creditRowFactory,
    key     = function(ed)
        if ed.kind == "creditIntro"  then return "intro" end
        if ed.kind == "creditOutro"  then return "outro" end
        if ed.kind == "credit"       then return "c:" .. tostring(ed.name) end
        return "?"
    end,
})

function ConfigController:Wire(rootFrame)
    -- ===== Appearance: Scale =============================================
    -- CONFIG_SCALE_STEP reducer owns clamp [0.5,1.5]; view dispatches direction only.
    HDG.UI.OnClick(rootFrame, "configPanel.scaleDecBtn", function()
        dispatch("CONFIG_SCALE_STEP", { direction = "dec" })
    end)
    HDG.UI.OnClick(rootFrame, "configPanel.scaleIncBtn", function()
        dispatch("CONFIG_SCALE_STEP", { direction = "inc" })
    end)

    -- ===== Lumber Tracker: auto-open toggle ==================================
    -- Mirrors the Warehouse-tab toggle (same action + bound selector, so both
    -- checkboxes stay in sync through the binding engine).
    HDG.UI.OnClick(rootFrame, "configPanel.lumberAutoShowToggle", function()
        dispatch("LUMBER_AUTOSHOW_TOGGLE")
    end)

    -- ===== Auction: source pills + TSM mode + Refresh from AH ================
    -- Relocated to the Goblin (Mogul) header/footer; wired in MogulController.

    -- ===== Danger: Collection cache reset (single-click, no confirm) =========
    HDG.UI.OnClick(rootFrame, "configPanel.collectionResetBtn", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.COLLECTION_RESET })
        HDG.HousingCatalogObserver:ReconcileFull("collection-cache-reset")
        HDG.Log:Info("catalog_refreshed", "Collection cache reset; rescanning...")
    end)

    -- ===== Danger: Hard reset (click-again to confirm) =======================
    _wireHardReset(rootFrame)

    -- ===== About: Other Settings (opens Blizzard Settings panel) ============
    HDG.UI.OnClick(rootFrame, "configPanel.otherSettingsBtn", function()
        if HDG.SettingsPanel then  -- exception(nullable): nil until BuildSettingsPanel runs at PLAYER_LOGIN; click can land before that
            HDG.SettingsPanel.OpenToCategory()
        else
            HDG.Log:Warn("settings", "Settings panel not yet registered -- try again after PLAYER_LOGIN.")
        end
    end)
end

-- ===== Theme inspector helpers ===============================================
-- Tokens repainted on every Refresh. Keep in sync with LayoutConfig_Config.lua.
local INSPECTOR_TEXT_TOKENS = {
    "heading", "primary", "muted", "disabled", "link", "numeric",
    "collected", "uncollected",
}

-- UI tokens (Status + Surfaces). Keep in sync with LayoutConfig_Config.lua.
local INSPECTOR_UI_TOKENS = {
    -- Status (diag.*)
    { token = "diag.error",           kind = "fg" },
    { token = "diag.warn",            kind = "fg" },
    { token = "diag.info",            kind = "fg" },
    { token = "diag.hint",            kind = "fg" },
    -- Surfaces (curated)
    { token = "tab.active.bg",        kind = "bg" },
    { token = "surface.statusline",   kind = "bg" },
    { token = "popup.selected.bg",    kind = "bg" },
    { token = "float.bg",             kind = "bg" },
    { token = "float.border",         kind = "fg" },
}

-- Paint one text sample. A missing sample is list/LC drift (UI.W errors); missing color = token absent in scheme.
local function _paintTextToken(rootFrame, key)
    local sample = HDG.UI.W(rootFrame, "themeInspectorPanel.sample_" .. key)
    local c = HDG.Theme:GetColor("text." .. key)
    if c then sample:SetTextColor(c.r, c.g, c.b, c.a) end  -- inspector: previews the token on a sample
end

-- Lazily build the BG swatch texture once; cached on the sample.
local function _ensureBgSwatch(sample)
    local tex = sample._hdgrSwatch
    if tex then return tex end
    tex = sample:GetParent():CreateTexture(nil, "OVERLAY")
    tex:SetPoint("LEFT",   sample, "LEFT",   0, 0)
    tex:SetPoint("RIGHT",  sample, "LEFT",  80, 0)
    tex:SetPoint("TOP",    sample, "TOP",    0, 0)
    tex:SetPoint("BOTTOM", sample, "BOTTOM", 0, 0)
    sample._hdgrSwatch = tex
    return tex
end

-- Paint one UI sample. fg = recolor label; bg = fill swatch. Missing color = leave blank.
local function _paintUIToken(rootFrame, row)
    local sample = HDG.UI.W(rootFrame, "themeInspectorPanel.uisample_" .. row.token:gsub("%.", "_"))
    local c = HDG.Theme:GetColor(row.token)
    if not c then return end
    if row.kind == "fg" then
        sample:SetTextColor(c.r, c.g, c.b, c.a)  -- inspector: previews the token on a sample
    else
        _ensureBgSwatch(sample):SetColorTexture(c.r, c.g, c.b, c.a)  -- inspector: previews the token on a swatch
    end
end

local function PaintInspectorTokens(rootFrame)
    for _, key in ipairs(INSPECTOR_TEXT_TOKENS) do _paintTextToken(rootFrame, key) end
    for _, row in ipairs(INSPECTOR_UI_TOKENS)   do _paintUIToken(rootFrame, row)   end
end

function ConfigController:Refresh(rootFrame, ctx)
    PaintInspectorTokens(rootFrame)
end

HDG.Controllers:Register("config", ConfigController)
