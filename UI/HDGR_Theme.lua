-- HDG.Theme
--
-- The chrome contract. Owns colors, fonts, metrics.
-- Surfaces never call SetBackdropColor / SetTextColor / SetFont directly.
--
-- Accessors:
--   :GetColor(path)     "button.primary.bg.hover" -> {r,g,b,a}
--   :GetFont(role)      "heading" -> FontObject
--   :GetMetric(path)    "spacing.md" -> number
--
-- Skin APIs:
--   :Register(widget, kind, state?)   Register + paint. Weak-keyed; Reload repaints all.
--   :Apply(widget, kindOrNil)         Re-apply the skinner.
--   :SetState(widget, updates)        Merge state + re-apply.
--
-- Theme swap: call Theme:Reload() after swapping HDGR_SchemeConstants;
-- every registered widget repaints.

HDG = HDG or {}
HDG.Theme = {
    registry    = setmetatable({}, { __mode = "k" }),  -- weak-keyed; GC releases entries. widget -> LAST role (SetState / Apply target)
    states      = setmetatable({}, { __mode = "k" }),  -- per-widget state (selected/active/etc) -- the last state passed
    roles       = setmetatable({}, { __mode = "k" }),  -- widget -> every role, in order -- only for widgets with two or more
    roleStates  = setmetatable({}, { __mode = "k" }),  -- widget -> { [role] = the state that role was registered with }
    paintGeneration = 0,   -- bumped on every scheme / font-face change; rows painted under an older one re-Configure
    fontObjects = {},  -- role name -> FontObject (created at Initialize)
}

HDG.Theme.BACKDROP_FLAT = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

-- Borderless flat fill: no edge, so the sidebar nav doesn't double-border the window.
HDG.Theme.BACKDROP_NOEDGE = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

-- Path resolution helpers ---------------------------------------------------

local function _walkPath(root, path)
    local cursor = root
    for segment in path:gmatch("[^.]+") do
        if type(cursor) ~= "table" then return nil end
        cursor = cursor[segment]
    end
    return cursor
end

-- A resolved leaf is memoised per (root, path): the scheme tables are static
-- once built and a scheme switch is a new root, so the gmatch iterator each
-- GetColor / GetMetric minted (46 per layout pass, 2026-09-13 audit) is paid
-- once per token. A miss is not cached so a bad path still fails loud upstream.
local _resolveCache = setmetatable({}, { __mode = "k" })
local function resolvePath(root, path)
    if not root or type(path) ~= "string" then return nil end
    local byPath = _resolveCache[root]
    if not byPath then byPath = {}; _resolveCache[root] = byPath end
    local hit = byPath[path]
    if hit ~= nil then return hit end
    local v = _walkPath(root, path)
    if v ~= nil then byPath[path] = v end
    return v
end

local function applyColor(setter, frame, color)
    if frame and setter and color then
        setter(frame, color.r, color.g, color.b, color.a)
    end
end

local function setBackdrop(frame, backdrop)
    if frame and frame.SetBackdrop then frame:SetBackdrop(backdrop) end
end

local function setBackdropColor(frame, color)
    if frame and frame.SetBackdropColor and color then
        frame:SetBackdropColor(color.r, color.g, color.b, color.a)
    end
end

local function setBackdropBorderColor(frame, color)
    if frame and frame.SetBackdropBorderColor and color then
        frame:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
    end
end

local function setTextColor(text, color)
    if not color then return end
    -- For Button widgets, paint the FontString directly (Button:SetTextColor goes through
    -- the state machine and can be reverted by NormalFontObject color on certain events).
    if text and text.GetFontString and text:GetFontString() then
        text:GetFontString():SetTextColor(color.r, color.g, color.b, color.a)
    elseif text and text.Text and text.Text.SetTextColor then
        text.Text:SetTextColor(color.r, color.g, color.b, color.a)
    elseif text and text.SetTextColor then
        text:SetTextColor(color.r, color.g, color.b, color.a)
    end
end

-- Cache + tint a 1px frame-band edge line stashed on the frame under `key`.
-- Full-bleed bands draw over the Canvas border, so each band must restore its
-- outer edges to keep the window outline continuous.
local function bandEdge(frame, key, p1, p2, horiz, color)
    local t = frame[key]
    if not t and frame.CreateTexture then
        t = frame:CreateTexture(nil, "BORDER")
        t:SetPoint(p1, 0, 0)
        t:SetPoint(p2, 0, 0)
        if horiz then t:SetHeight(1) else t:SetWidth(1) end
        frame[key] = t
    end
    if t and t.SetColorTexture and color then
        t:SetColorTexture(color.r, color.g, color.b, color.a)
    end
end

-- Suppress unused-local warnings for helpers we expose to Skinners.
local _ = applyColor

-- Public API ----------------------------------------------------------------

function HDG.Theme:Initialize()
    self.currentScheme = HDGR_SchemeConstants.ColorblindSafe
    self:BuildFontObjects()
    self:_InstallSchemeSubscriber()
end

-- Reacts to CONFIG_SET scheme / fontFamily changes; owns the post-dispatch repaint.
-- Idempotent: duplicate dispatch re-LoadSchemes (cheap; ApplyAll is weak-keyed).
function HDG.Theme:_InstallSchemeSubscriber()
    if self._schemeSubscriberInstalled then return end
    self._schemeSubscriberInstalled = true
    local A = HDG.Constants.ACTIONS
    HDG.Store:Subscribe(function(actionType, invalidation)
        if actionType ~= A.CONFIG_SET then return end
        -- Filter on the invalidation set so we don't repaint on every CONFIG_SET
        -- (debug toggle, price preferences, etc). Both scheme and font-face changes
        -- need the same rebuild-fonts + ApplyAll + full re-render.
        if not HDG.Paths.MatchesAny({ "account.config.scheme", "account.config.fontFamily" }, invalidation) then return end
        self:ApplyConfiguredTheme()
    end)
end

-- Rebuild the fonts and repaint every surface for the scheme and font face in
-- config. Runs after a CONFIG_SET that moved either (the subscriber above).
function HDG.Theme:ApplyConfiguredTheme()
    local newScheme = HDG.Store:GetState().account.config.scheme
    if type(newScheme) ~= "string" or newScheme == "" then return end
    local scheme = HDGR_SchemeConstants[newScheme]
    if not scheme then
        HDG.Log:Warn("theme", "scheme " .. newScheme .. " not found in HDGR_SchemeConstants")
        return
    end
    -- Native-button schemes (Panseit's Blizzard UI) build a different button
    -- WIDGET (UIPanelButtonTemplate vs HDG's atlas), which a repaint can't swap.
    -- When that flips, the buttons need a /reload to rebuild -> prompt the user.
    local nativeChanged = (self.currentScheme.nativeButtons or false) ~= (scheme.nativeButtons or false)
    self.currentScheme = scheme
    self:BuildFontObjects()   -- resolves the (possibly newly-overridden) font face
    self:ApplyAll()
    -- ApplyAll only repaints Theme:Register'd widgets. Pooled data rows read
    -- Theme:GetColor at Configure-time and would keep the old scheme until
    -- the next data refresh. Force a full re-render -- and bump the paint
    -- generation first, or a scrollbox handed the same memoized items table
    -- skips SetItems and never re-runs Configure (Components _sameItems).
    -- Auto-sized widgets measured their text in the old face: re-measure.
    -- Satellites too: their interest sets don't read these settings, and
    -- doing it here (not in a Window subscriber) keeps it after this rebuild.
    self.paintGeneration = self.paintGeneration + 1
    if HDG.RefreshMainWindow then  -- exception(boundary): RefreshMainWindow nil in tests / partial load-order
        HDG.UI.RefreshIntrinsicWidths(HDG.mainFrame)
        HDG:RefreshMainWindow("*")
    end
    if HDG.Window then HDG.Window:RepaintAll() end  -- exception(boundary): Window nil in tests / partial load-order
    if nativeChanged and _G.StaticPopup_Show then   -- exception(boundary): StaticPopup_Show nil in tests
        if not _G.StaticPopupDialogs["HDGR_THEME_RELOAD"] then
            _G.StaticPopupDialogs["HDGR_THEME_RELOAD"] = {
                text = "Panseit's Blizzard UI uses native Blizzard buttons. Switching to or from it needs a UI reload to rebuild them. Reload now?",
                button1 = "Reload Now",
                button2 = "Later",
                OnAccept = function() _G.ReloadUI() end,
                timeout = 0, whileDead = true, hideOnEscape = true,
            }
        end
        _G.StaticPopup_Show("HDGR_THEME_RELOAD")
    end
end

function HDG.Theme:GetScheme()
    if not self.currentScheme then self:Initialize() end
    return self.currentScheme
end

-- LoadScheme: swap currentScheme and repaint every registered widget.
-- Pass a scheme name (looked up in HDGR_SchemeConstants) or a scheme table.
-- Rebuilds FontObjects so font role swaps propagate.
function HDG.Theme:LoadScheme(schemeOrName)
    local scheme
    if type(schemeOrName) == "string" then
        scheme = HDGR_SchemeConstants and HDGR_SchemeConstants[schemeOrName]
        if not scheme then
            error(("Theme:LoadScheme: scheme %q not found in HDGR_SchemeConstants"):format(schemeOrName), 2)
        end
    elseif type(schemeOrName) == "table" then
        scheme = schemeOrName
    else
        error("Theme:LoadScheme: expected scheme name (string) or scheme table", 2)
    end
    self.currentScheme = scheme
    self:BuildFontObjects()
    self:ApplyAll()
end

-- :GetColor(path) resolves a dotted path against the active scheme.
function HDG.Theme:GetColor(path)
    local scheme = self:GetScheme()
    if not scheme then return nil end
    return resolvePath(scheme, path)
end

-- :ColorCode(path) -> "|cFFrrggbb" for inline SetText use.
-- Validates the namespace is owned by Theme (not Palette) per ADR-023.
-- All 12 top-level scheme color families (HDGR_SchemeConstants). Kept in sync
-- with that file; Palette.OWNED_NAMESPACES (expansion/faction/source) is disjoint.
HDG.Theme.OWNED_COLOR_NAMESPACES = {
    surface  = true,
    border   = true,
    text     = true,
    semantic = true,
    tab      = true,
    popup    = true,
    float    = true,
    diag     = true,
    button   = true,
    chip     = true,
    pin      = true,
    region   = true,
}

local function _checkThemeNamespace(path)
    local ns = path:match("^([^.]+)")
    if not ns then
        error(("Theme:ColorCode: malformed token %q (expected <namespace>.<key>)"):format(tostring(path)), 3)
    end
    if not HDG.Theme.OWNED_COLOR_NAMESPACES[ns] then
        local hint = ""
        if HDG.Palette and HDG.Palette.OWNED_NAMESPACES  -- exception(boundary): cross-module load-order
           and HDG.Palette.OWNED_NAMESPACES[ns] then
            hint = " -- use HDG.Palette:ColorCode instead"
        end
        error(("Theme:ColorCode: namespace %q not owned by Theme (ADR-023)%s"):format(ns, hint), 3)
    end
end

function HDG.Theme:ColorCode(path)
    _checkThemeNamespace(path)
    local c = self:GetColor(path)
    -- Loud-fail: caller sees the broken path, not an opaque nil index (ADR-006).
    if not c then
        error(("Theme:ColorCode: scheme path %q does not resolve"):format(tostring(path)), 2)
    end
    return string.format("|cFF%02X%02X%02X",
        math.floor(c.r * 255 + 0.5),
        math.floor(c.g * 255 + 0.5),
        math.floor(c.b * 255 + 0.5))
end

-- Text-state -> theme-token map (the addon's single text-state source).
-- (collection, recipe knowledge, semantic severity) for direct lookup.
local TEXT_STATE_COLOR_TOKENS = {
    -- text.collected / text.uncollected: separate tokens so schemes can tune
    -- "I own this" vs "I should care" independently of semantic.success (green).
    collected     = "text.collected",
    uncollected   = "text.uncollected",
    -- Recipe knowledge
    known_self    = "semantic.success",
    known_alt     = "semantic.warning",
    recipe_exists = "text.dim",
    not_a_recipe  = "text.dim",
    -- Semantic severity
    success       = "semantic.success",
    warning       = "semantic.warning",
    error         = "semantic.error",
    error_deep    = "semantic.error_deep",
}

function HDG.Theme:GetTextStateColorToken(state)
    return self:ColorCode(TEXT_STATE_COLOR_TOKENS[state])
end

-- Wrap text in text-state color + reset. Shared across all status-label call sites.
function HDG.Theme:StateLabel(state, text)
    return self:GetTextStateColorToken(state) .. text .. "|r"
end

-- Color an item name by collection state: uncollected = text.uncollected (accent),
-- collected = text.collected (recedes). One place for this token flip.
function HDG.Theme:CollectionLabel(isCollected, text)
    return self:StateLabel(isCollected and "collected" or "uncollected", text)
end

-- :GetMetric("spacing.md") -> number
function HDG.Theme:GetMetric(path)
    local scheme = self:GetScheme()
    return resolvePath(scheme and scheme.metrics, path)
end

-- :GetFont(role) -> FontObject. Falls back to scheme descriptor in tests (no CreateFont).
function HDG.Theme:GetFont(role)
    if not role then return nil end
    local fo = self.fontObjects and self.fontObjects[role]
    if fo then return fo end
    -- Test / no-CreateFont fallback: return the role descriptor; callers can
    -- inspect file/size/flags directly.
    local scheme = self:GetScheme()
    return scheme and scheme.fonts and scheme.fonts[role] or nil
end

-- User font-face override (Config -> Appearance). Only GLYPH-SAFE faces here:
-- "default" = the scheme face (per-locale STANDARD_TEXT_FONT), "arialn" = Arial
-- Narrow (crisper sub-12px, carries Latin + Cyrillic). Never expose a Latin-only
-- face (e.g. raw FRIZQT__) -- that re-introduces tofu on ruRU/CJK.
local FONT_FACE_FILES = { arialn = "Fonts\\ARIALN.TTF" }

-- Resolve the actual font file for a role: the user's override if set + known,
-- else the scheme's own face (size/flags always come from the scheme descriptor).
function HDG.Theme:_FontFileFor(defaultFile)
    local store = HDG.Store
    if not store then return defaultFile end  -- exception(boundary): Theme builds fonts before Store init (early boot / tests)
    local family = store:GetState().account.config.fontFamily
    return FONT_FACE_FILES[family] or defaultFile
end

-- BuildFontObjects: creates real FontObjects from scheme.fonts. Re-callable;
-- second call repoints existing objects to new font files (scheme OR font-face swap).
function HDG.Theme:BuildFontObjects()
    local scheme = self:GetScheme()
    local fonts = scheme and scheme.fonts or {}
    local createFont = _G and _G.CreateFont or nil
    if not createFont then return end

    for role, desc in pairs(fonts) do
        local globalName = "HDGR_Font_" .. role
        local fo = self.fontObjects[role]
        if not fo then
            fo = _G[globalName] or createFont(globalName)
            self.fontObjects[role] = fo
        end
        if not desc or not desc.file or not desc.size then
            error(("Theme:BuildFontObjects: scheme font role %q must declare {file, size, flags}"):format(role), 2)
        end
        if fo and fo.SetFont then
            fo:SetFont(self:_FontFileFor(desc.file), desc.size, desc.flags or "")
        end
    end
end

-- Atlas tint: SetVertexColor multiplies (white border * tint = pure tint;
-- dark interior stays mostly dark). Each state texture tinted independently.
local function tintAtlasButton(button, normalColor, hoverColor, pushedColor, disabledColor)
    local function paint(getter, color)
        if not color then return end
        local t = button[getter] and button[getter](button)
        if t and t.SetVertexColor then
            t:SetVertexColor(color.r, color.g, color.b, color.a)
        end
    end
    paint("GetNormalTexture",    normalColor)
    paint("GetHighlightTexture", hoverColor)
    paint("GetPushedTexture",    pushedColor or normalColor)
    paint("GetDisabledTexture",  disabledColor)
end

-- Canonical decorative-overlay alpha. Single value for all shadow/scrim/darken elements.
-- Foreground / selected / data paint opaque; this is only for things that darken behind content.
HDG.Theme.OVERLAY_ALPHA = 0.45

-- Chrome: atlas-artwork lookup for the active scheme. Returns the atlas name
-- declared under scheme.chrome[key], or nil when the scheme carries no chrome
-- (every theme except "Housing Decor Guide"). The nil IS the signal for the
-- atlas-aware Skinners below to take the solid/watercolor path.
function HDG.Theme:Chrome(key)
    local chrome = self.currentScheme.chrome   -- nullable: nil on non-atlas schemes
    return chrome and chrome[key]
end

-- _applyChromeBg: ensure a full-cover BACKGROUND atlas texture under frame[key],
-- painted from the active scheme's chrome[chromeKey]. Returns true when an atlas
-- is active (caller then suppresses its solid backdrop fill); returns false AND
-- hides the texture when absent -- that hide is the teardown that strips the
-- artwork on switch-away. Idempotent: texture created once, re-shown/hidden per paint.
function HDG.Theme:_applyChromeBg(frame, key, chromeKey, sublevel)
    local atlas = self:Chrome(chromeKey)
    local tex = frame[key]
    if atlas then
        if not tex and frame.CreateTexture then
            tex = frame:CreateTexture(nil, "BACKGROUND", nil, sublevel or -7)
            tex:SetAllPoints(frame)
            frame[key] = tex
        end
        if tex then
            tex:SetAtlas(atlas)
            tex:SetVertexColor(1, 1, 1, 1)   -- atlas true color (no scheme tint)
            tex:Show()
        end
        return true
    end
    if tex then tex:Hide() end   -- teardown: solid scheme, no chrome artwork
    return false
end

-- NavRow paint helpers (file-scope: NavRow lives inside the Skinners literal).
-- Accent spine shows on the active parent + every child in the open group.
local function _paintNavAccentBar(chrome, show)
    if not chrome.accentBar then return end
    if show then
        local accent = HDG.Theme:GetColor("semantic.accent")
        chrome.accentBar:SetVertexColor(accent.r, accent.g, accent.b, 1)
        chrome.accentBar:Show()
    else
        chrome.accentBar:Hide()
    end
end

-- Highlight fill colour for a nav row, or nil (transparent -- panel_soft shows
-- through). home + active hub/parent/config -> panel_header; active leaf -> selected.
local function _navRowFill(tier, active)
    if tier == "home" then
        return HDG.Theme:GetColor("surface.panel_header")
    elseif active and (tier == "hub" or tier == "parent" or tier == "config") then
        return HDG.Theme:GetColor("surface.panel_header")
    elseif active and tier == "leaf" then
        return HDG.Theme:GetColor("surface.selected")
    end
    return nil
end

-- Paint (or clear) the nav row's highlight fill. Highlighted rows get watercolor
-- paper + a vertical gloss for depth; cleared rows hide both.
local function _paintNavRowFill(frame, chrome, fill)
    if not chrome.selectedBg then return end
    if not fill then
        chrome.selectedBg:Hide()
        if frame._navGloss then frame._navGloss:Hide() end
        return
    end
    if not frame._navFillTextured and chrome.selectedBg.SetTexture then
        chrome.selectedBg:SetTexture("Interface\\AddOns\\HousingDecorGuide\\textures\\watercolor")
        frame._navFillTextured = true
    end
    chrome.selectedBg:SetVertexColor(fill.r, fill.g, fill.b, fill.a)
    chrome.selectedBg:Show()
    local gloss = frame._navGloss
    if not gloss and frame.CreateTexture then
        gloss = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
        gloss:SetAllPoints()
        gloss:SetTexture("Interface\\Buttons\\WHITE8x8")
        if gloss.SetGradient and _G.CreateColor then
            gloss:SetGradient("VERTICAL", _G.CreateColor(1, 1, 1, 0), _G.CreateColor(1, 1, 1, 0.10))
        end
        frame._navGloss = gloss
    end
    if gloss then gloss:Show() end
end

-- Skinners: per-widgetType paint functions. New kinds go here; callers never call
-- SetBackdropColor / SetTextColor etc. directly.
HDG.Theme.Skinners = {
    Frame = function(frame, _scheme)
        setBackdrop(frame, HDG.Theme.BACKDROP_FLAT)
        -- Housing: stone panel-background atlas behind container panels (the donor's
        -- panel bg, the layer that floats above the window's dashboard bg); other
        -- schemes paint solid surface.panel. Cards/rails use Raised/ScrimCard (a
        -- different skin), so this stones panel BACKDROPS, not the cards on them.
        if HDG.Theme:_applyChromeBg(frame, "_hdgrFrameBg", "panelBg", -7) then
            setBackdropColor(frame, { r = 0, g = 0, b = 0, a = 0 })
        else
            setBackdropColor(frame, HDG.Theme:GetColor("surface.panel"))
        end
        setBackdropBorderColor(frame, HDG.Theme:GetColor("border.default"))
    end,

    -- Canvas: surface.sunken (deepest ramp step) so Frame panels (surface.panel)
    -- float above it; inter-panel gap reads as a sunken seam.
    -- Housing: a window-bg atlas shows through a transparent backdrop; every
    -- other scheme paints the solid sunken fill (atlas hidden on switch-away).
    Canvas = function(frame, _scheme)
        setBackdrop(frame, HDG.Theme.BACKDROP_FLAT)
        if HDG.Theme:_applyChromeBg(frame, "_hdgrCanvasBg", "windowBg", -7) then
            setBackdropColor(frame, { r = 0, g = 0, b = 0, a = 0 })
        else
            setBackdropColor(frame, HDG.Theme:GetColor("surface.sunken"))
        end
        setBackdropBorderColor(frame, HDG.Theme:GetColor("border.default"))
    end,

    -- WindowFrameBorder: decorative full-window carved-wood frame (Housing Decor
    -- Guide theme only). The overlay frame is created ABOVE content in MainFrame /
    -- Window; this skinner stamps chrome.windowBorder + shows it, and HIDES on every
    -- other scheme (the teardown). Stretched for now -- 9-slice/inset is post-build.
    WindowFrameBorder = function(frame, _scheme)
        if not frame then return end
        local atlas = HDG.Theme:Chrome("windowBorder")
        local tex = frame._borderTex
        if atlas and not tex and frame.CreateTexture then
            tex = frame:CreateTexture(nil, "OVERLAY")
            tex:SetAllPoints(frame)
            frame._borderTex = tex
        end
        if tex and atlas then
            tex:SetAtlas(atlas)
            tex:SetVertexColor(1, 1, 1, 1)
        end
        frame:SetShown(atlas ~= nil)
    end,

    -- Raised: one step above panel so stat cards lift off. Full border.default edge.
    Raised = function(frame, _scheme)
        setBackdrop(frame, HDG.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, HDG.Theme:GetColor("surface.raised"))
        setBackdropBorderColor(frame, HDG.Theme:GetColor("border.default"))
    end,

    -- Shadow: black at OVERLAY_ALPHA. Atlas -> vertex color tint; bare swatch -> SetColorTexture.
    -- Black in every scheme; this skinner enforces the consistent ALPHA.
    Shadow = function(tex, _scheme)
        if not tex then return end
        local a = HDG.Theme.OVERLAY_ALPHA
        if tex.GetAtlas and tex:GetAtlas() then
            tex:SetVertexColor(0, 0, 0, a)
        elseif tex.SetColorTexture then  -- exception(false-positive): Texture always has SetColorTexture; mock-fidelity guard
            tex:SetColorTexture(0, 0, 0, a)
        end
    end,

    -- ScrimCard: translucent-black card backdrop (OVERLAY_ALPHA) with panel border.
    -- Paints colors only (SetBackdrop set at construction); survives scheme switch.
    ScrimCard = function(frame, _scheme)
        setBackdropColor(frame, { r = 0, g = 0, b = 0, a = HDG.Theme.OVERLAY_ALPHA })
        setBackdropBorderColor(frame, HDG.Theme:GetColor("border.default"))
    end,

    -- Button: design-time variant + runtime state.active in one paint pass.
    -- Active wins paint regardless of variant family.
    -- Variants: primary / danger / tertiary / ghost / default
    Button = function(button, _scheme, state)
        -- Native UIPanelButton (BlizzardUI): Blizzard owns the art/font/states; the
        -- HDG skin would only fight it. (_hdgrNative set by HDG.UI:Button.)
        -- _ownedArt: content-icon buttons whose atlas IS the art (minimap glyphs);
        -- skip skinning so the coloured glyph isn't vertex-tinted by the scheme.
        if button._hdgrNative or button._ownedArt then return end
        local variant = button._hdgrVariant or "default"
        local active  = state and state.active and true or false
        -- Atlas-based (SetNormalAtlas) vs backdrop-based (SetBackdrop).
        -- Detect atlas presence, not variant, so dropdowns get the right path automatically.
        local hasAtlas = button.GetNormalTexture and button:GetNormalTexture()
        if not hasAtlas then
            setBackdrop(button, HDG.Theme.BACKDROP_FLAT)
            if active then
                local accent  = HDG.Theme:GetColor("semantic.accent")
                local inverse = HDG.Theme:GetColor("text.inverse")
                setBackdropColor(button, { r = accent.r, g = accent.g, b = accent.b, a = 0.85 })
                setBackdropBorderColor(button, accent)
                setTextColor(button, inverse)
            else
                local bg     = HDG.Theme:GetColor("button.default.bg.normal")
                local border = HDG.Theme:GetColor("button.default.border.normal")
                local text   = HDG.Theme:GetColor("button.default.text.normal")
                setBackdropColor(button, bg)
                setBackdropBorderColor(button, border)
                setTextColor(button, text)
            end
            -- RowButton hover texture: re-tint on every repaint (not Theme:Register'd,
            -- so ApplyAll won't reach it otherwise).
            if button._hoverTex then
                local accent = HDG.Theme:GetColor("semantic.accent")
                button._hoverTex:SetColorTexture(accent.r, accent.g, accent.b, 0.20)
            end
            return
        end
        -- Atlas-button path: tint borders per scheme.
        -- Normal = border color; active = accent; hover = accent; pressed = accent dark.
        -- Dropdown: swap NormalAtlas to -open variant via _activeNormalAtlas when active.
        local accent      = HDG.Theme:GetColor("semantic.accent")
        local accentDark  = HDG.Theme:GetColor("button.primary.bg.active")
        local disabledCol = HDG.Theme:GetColor("text.disabled")
        -- All atlas-path widgets share a fixed dark Blizzard atlas; text must be light.
        -- Anchor to button.tertiary.text.normal (encodes the isLight override).
        -- Active = text.link_hover (brighter accent) for unmistakable selected signal.
        -- _textTone override (e.g. "error" for Hard Reset) beats everything.
        local activeText   = HDG.Theme:GetColor("button.tertiary.text.hover")
                          or HDG.Theme:GetColor("button.tertiary.text.normal")
        local inactiveText = HDG.Theme:GetColor("button.tertiary.text.normal")
        if button._textTone then
            local toneCol = HDG.Theme:GetColor("semantic." .. button._textTone)
            if toneCol then
                activeText   = toneCol
                inactiveText = toneCol
            end
        end
        if active then
            if button._activeNormalAtlas and button.SetNormalAtlas then
                button:SetNormalAtlas(button._activeNormalAtlas)
            end
            if button._activeHighlightAtlas and button.SetHighlightAtlas then
                button:SetHighlightAtlas(button._activeHighlightAtlas)
            end
            tintAtlasButton(button, accent, accent, accentDark, disabledCol)
            setTextColor(button, activeText)
        else
            if button._normalAtlas and button.SetNormalAtlas then
                button:SetNormalAtlas(button._normalAtlas)
            end
            if button._highlightAtlas and button.SetHighlightAtlas then
                button:SetHighlightAtlas(button._highlightAtlas)
            end
            local borderNormal = HDG.Theme:GetColor("button." .. variant .. ".border.normal")
                or HDG.Theme:GetColor("button.default.border.normal")
            tintAtlasButton(button, borderNormal, accent, accentDark, disabledCol)
            setTextColor(button, inactiveText)
        end
        -- Hover text swap: OnEnter/OnLeave handlers repaint text color per state.
        -- Hooked once per button (_hdgrHoverHooked) so scheme repaints don't stack handlers.
        -- Active branch sets its own text color; hover is skipped when active=true.
        -- Text tracks the TERTIARY tokens (matching the steady-state paint above):
        -- every text button renders on the dark tertiary atlas -- variant tints only
        -- the border -- so the label must stay light. Keying hover off the variant flipped
        -- primary/danger buttons to text_inverse (tuned for a light fill) -> invisible on
        -- the dark atlas. _textTone (e.g. Hard Reset = error) overrides in both directions.
        if not button._hdgrHoverHooked and button.HookScript then
            button._hdgrHoverHooked = true
            button:HookScript("OnEnter", function(btn)
                if HDG.Theme.states[btn] and HDG.Theme.states[btn].active then return end
                local c = (btn._textTone and HDG.Theme:GetColor("semantic." .. btn._textTone))
                       or HDG.Theme:GetColor("button.tertiary.text.hover")
                if c then setTextColor(btn, c) end
            end)
            button:HookScript("OnLeave", function(btn)
                if HDG.Theme.states[btn] and HDG.Theme.states[btn].active then return end
                local c = (btn._textTone and HDG.Theme:GetColor("semantic." .. btn._textTone))
                       or HDG.Theme:GetColor("button.tertiary.text.normal")
                if c then setTextColor(btn, c) end
            end)
        end
    end,

    -- SlotButton: scheme-aware tint for UIMenuButtonStretchTemplate 9-slice chrome.
    -- SetVertexColor persists across Blizzard's texture path swaps (mouse-down/up).
    -- state.tone: "default" = native silver; "accent"/"warning"/"success"/"danger" = semantic.*
    SlotButton = function(button, _scheme, state)
        -- Active overrides tone + un-mutes chrome (bright silver IS the accent showcase).
        -- Inactive muted slot recedes; active pops.
        local active = state and state.active == true
        local tone   = active and "accent" or ((state and state.tone) or "default")
        local muted  = (not active) and ((state and state.muted) == true)
        local borderSlices = { "TopLeft", "TopRight", "BottomLeft", "BottomRight",
                               "TopMiddle", "BottomMiddle", "MiddleLeft", "MiddleRight" }
        local interiorSlice = "MiddleMiddle"
        -- Tone tint: default = white (identity = native silver).
        local r, g, b = 1, 1, 1
        if tone ~= "default" then
            local token = (tone == "danger" or tone == "error") and "semantic.error"
                       or ("semantic." .. tone)
            local c = HDG.Theme:GetColor(token)
            if c then r, g, b = c.r, c.g, c.b end
        end
        -- Muted: darken border slices to 55% (kills bright-silver highlights);
        -- interior keeps full tint. Net effect: flush inset slot vs stamped button.
        local borderMul = muted and 0.55 or 1.0
        for _, key in ipairs(borderSlices) do
            local t = button[key]
            if t and t.SetVertexColor then
                t:SetVertexColor(r * borderMul, g * borderMul, b * borderMul)
            end
        end
        local mid = button[interiorSlice]
        if mid and mid.SetVertexColor then mid:SetVertexColor(r, g, b) end
        -- Hover highlight: tint the auto-applied silver swoosh once at paint.
        -- Vertex color persists across mouse-down texture swaps.
        -- All tones use semantic.accent glow (avoids muddy hover colors).
        local hl = button.GetHighlightTexture and button:GetHighlightTexture()
        if hl and hl.SetVertexColor then
            local accent = HDG.Theme:GetColor("semantic.accent")
            if accent then
                hl:SetVertexColor(accent.r, accent.g, accent.b, 1)
            end
        end
        -- Text color: text.primary by default; opt-in tone via state.textTone.
        -- "match" mirrors the chrome tone (textTone="match" + tone="warning" -> amber).
        -- Matters most at small button sizes where chrome tint is harder to read.
        local fs = button.GetFontString and button:GetFontString()
        if fs and fs.SetTextColor then
                -- text.primary is readable on both dark/light schemes.
            -- text.inverse disappeared on dark schemes against accent chrome.
            local tc
            local textTone = state and state.textTone
            if not active and textTone == "match" and tone ~= "default" then
                local token = (tone == "danger" or tone == "error") and "semantic.error"
                           or ("semantic." .. tone)
                tc = HDG.Theme:GetColor(token)
            elseif not active and type(textTone) == "string" and textTone ~= "" then
                local token = (textTone == "danger" or textTone == "error") and "semantic.error"
                           or ("semantic." .. textTone)
                tc = HDG.Theme:GetColor(token)
            end
            tc = tc or HDG.Theme:GetColor("text.primary")
            if tc then fs:SetTextColor(tc.r, tc.g, tc.b, tc.a) end
        end
    end,

    Text = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("text.primary"))
    end,

    TextDim = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("text.dim"))
    end,

    -- LinkRow: URL EditBox. Same backdrop as Frame; text dim (URL isn't primary content).
    LinkRow = function(editbox, _scheme)
        setBackdrop(editbox, HDG.Theme.BACKDROP_FLAT)
        setBackdropColor(editbox, HDG.Theme:GetColor("surface.panel"))
        setBackdropBorderColor(editbox, HDG.Theme:GetColor("border.default"))
        setTextColor(editbox, HDG.Theme:GetColor("text.dim"))
    end,

    -- Status text: accent-colored FontString (capture form status row, etc.).
    TextStatus = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("semantic.accent"))
    end,

    -- TextWarning: semantic.warning (amber) for "not loaded yet" (catalog Section B).
    -- Distinct from diag.error (hard-error Section C); empty/no-results stay dim.
    TextWarning = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("semantic.warning"))
    end,

    -- TextSuccess: semantic.success (green) for positive/active rows.
    TextSuccess = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("semantic.success"))
    end,

    -- TextError: semantic.error (red) for negative/clashing rows.
    TextError = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("semantic.error"))
    end,

    -- Faction tints: fixed Alliance-blue / Horde-red for full-house / exterior
    -- blueprint rows. Scheme-independent -- faction is a game-wide semantic, not
    -- a themed color -- so these hardcode readable values rather than GetColor.
    TextAlliance = function(text, _scheme)
        setTextColor(text, { r = 0.30, g = 0.55, b = 1.00, a = 1 })
    end,
    TextHorde = function(text, _scheme)
        setTextColor(text, { r = 0.92, g = 0.26, b = 0.26, a = 1 })
    end,

    -- TextInfo: diag.info for low-key status lines.
    TextInfo = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("diag.info"))
    end,

    -- ToneTexture: SetVertexColor a white atlas to the token stamped at build.
    -- Token on the texture -> scheme switches re-tint automatically.
    ToneTexture = function(tex, _scheme)
        local c = HDG.Theme:GetColor(tex._hdgrToneToken)
        tex:SetVertexColor(c.r, c.g, c.b, c.a)
    end,

    -- ScrollThumb: tints Begin/Middle/End textures of MinimalScrollBar Thumb.
    -- Vertex color persists across hover/down atlas swaps; paint once per scheme load.
    ScrollThumb = function(thumb, _scheme)
        if not thumb then return end
        local c = HDG.Theme:GetColor("semantic.accent")
        if not c then return end
        local r, g, b = c.r, c.g, c.b
        if thumb.Begin  and thumb.Begin.SetVertexColor  then thumb.Begin:SetVertexColor(r, g, b, 1.0)  end
        if thumb.Middle and thumb.Middle.SetVertexColor then thumb.Middle:SetVertexColor(r, g, b, 1.0) end
        if thumb["End"] and thumb["End"].SetVertexColor then thumb["End"]:SetVertexColor(r, g, b, 1.0) end
    end,

    -- RowChrome: per-row bg + selected-state accents.
    -- Textures created by HDG.UI:EnsureRowChrome; state cached via Register's 3rd arg.
    RowChrome = function(row, _scheme, state)
        if not (row and row._hdgrChrome) then return end
        local chrome = row._hdgrChrome

        -- Zebra: even rows tint to surface.panel_soft; odd rows transparent (sunken shows through).
        -- Header rows get surface.panel_header band (wins over zebra parity).
        if state and state.header then
            local hdr = HDG.Theme:GetColor("surface.panel_header")
            chrome.zebra:SetVertexColor(hdr.r, hdr.g, hdr.b, hdr.a)
            chrome.zebra:Show()
        elseif row._zebraAlt then
            local soft = HDG.Theme:GetColor("surface.panel_soft")
            chrome.zebra:SetVertexColor(soft.r, soft.g, soft.b, soft.a)
            chrome.zebra:Show()
        else
            chrome.zebra:Hide()
        end

        -- Mouseover wash from the scheme (re-tints on Theme:Reload).
        local hover = HDG.Theme:GetColor("surface.hover")
        chrome.hover:SetVertexColor(hover.r, hover.g, hover.b, hover.a)

        -- Selected: accent wash + 3px accent bar layered over parity.
        -- (Watercolor fill removed; if it returns, gate to data rows only via row._zebraAlt.)
        if state and state.selected then
            local accent = HDG.Theme:GetColor("semantic.accent")
            chrome.selectedBg:SetVertexColor(accent.r, accent.g, accent.b, 0.15)
            chrome.selectedBg:Show()
            chrome.accentBar:SetVertexColor(accent.r, accent.g, accent.b, 1)
            chrome.accentBar:Show()
        else
            chrome.selectedBg:Hide()
            chrome.accentBar:Hide()
        end
    end,

    -- (ProjectsRoomTile removed: room tiles are line-drawn outlines; selection via outline color.)

    -- ProjectsOrb: door indicator dot. Glows when connected by placement.
    -- Uses native housing layout-editor orb atlases (scheme-invariant, no tint).
    ProjectsOrb = function(orb, _scheme, state)
        local active = (state and state.connected) and true or false
        if not orb._dot then
            orb._dot = orb:CreateTexture(nil, "OVERLAY")
            orb._dot:SetAllPoints(orb)
        end
        if not orb._glow then
            orb._glow = orb:CreateTexture(nil, "ARTWORK")   -- behind the dot
            orb._glow:SetPoint("TOPLEFT", orb, "TOPLEFT", -5, 5)
            orb._glow:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", 5, -5)
            orb._glow:SetAtlas("housing-layout-room-orb-active-glow")
        end
        orb._dot:SetAtlas(active and "housing-layout-room-orb-active" or "housing-layout-room-orb-default")
        orb._glow:SetShown(active)
    end,

    -- RowWoodBeam: housing-woodsign atlas backdrop, full-width at BACKGROUND.
    -- state.alpha: 0.5 unselected, 0.85 selected (scheme-invariant).
    -- REGISTRY ORDER: register RowWoodBeam FIRST, RowChrome LAST. ApplyAll
    -- only re-runs the last-registered role; scheme-dependent RowChrome must win. per:
    -- reference_lattice_theme_register_last_role_wins.md
    RowWoodBeam = function(row, _scheme, state)
        if not row then return end
        if not row._woodBeamBg then
            row._woodBeamBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
            row._woodBeamBg:SetAllPoints(row)
            row._woodBeamBg:SetAtlas("housing-woodsign")
        end
        -- Strict read: every RowWoodBeam Register must pass explicit { alpha = N }.
        row._woodBeamBg:SetAlpha(state.alpha)
    end,

    -- AccentBg: semantic.accent fill at 8.5% alpha (status banner body, etc).
    AccentBg = function(tex, _scheme)
        if not (tex and tex.SetColorTexture) then return end
        local accent = HDG.Theme:GetColor("semantic.accent")
        tex:SetColorTexture(accent.r, accent.g, accent.b, 0.085)
    end,

    -- ProgressBarFill: semantic.success at full alpha for progress bars.
    -- AccentBg at 0.085 was too dim against the panel background.
    -- state: { variant = "success"|"warning"|"error"|"accent", dim = bool }.
    -- No state = the historical solid success fill (all existing registrations).
    ProgressBarFill = function(tex, _scheme, state)
        if not (tex and tex.SetColorTexture) then return end
        local c = HDG.Theme:GetColor("semantic." .. ((state and state.variant) or "success"))
        tex:SetColorTexture(c.r, c.g, c.b, (state and state.dim) and 0.35 or 1)
    end,

    -- AccentBar: solid accent fill (status banner left bar, selected row bar).
    AccentBar = function(tex, _scheme)
        if not (tex and tex.SetColorTexture) then return end
        local accent = HDG.Theme:GetColor("semantic.accent")
        tex:SetColorTexture(accent.r, accent.g, accent.b, 1)
    end,

    -- ProgressFillTint: vertex-tint an atlas-based progress fill (vs ProgressBarFill's
    -- solid SetColorTexture). state.variant selects the semantic token.
    ProgressFillTint = function(tex, _scheme, state)
        if not (tex and tex.SetVertexColor) then return end
        local c = HDG.Theme:GetColor("semantic." .. ((state and state.variant) or "success"))
        tex:SetVertexColor(c.r, c.g, c.b, 1)
    end,

    -- RoomOutline: room-edge lines. Selected = accent; default = border.default.
    -- Full alpha; replaces hardcoded "blueprint blue" so the canvas follows the scheme.
    RoomOutline = function(line, _scheme, state)
        if not (line and line.SetColorTexture) then return end
        local c = HDG.Theme:GetColor((state and state.selected) and "semantic.accent" or "border.default")
        line:SetColorTexture(c.r, c.g, c.b, c.a)   -- nil alpha -> API defaults to 1
    end,

    -- SectionRoomMuted: a room on a floor you are NOT looking at. The Section view
    -- stacks floors that overlap on screen -- a floor whose rooms sit in one corner
    -- of the house draws over the floors above it -- so the floor in focus has to
    -- read louder than its neighbours or you cannot tell which storey a room is on.
    SectionRoomMuted = function(line, _scheme)
        if not (line and line.SetColorTexture) then return end
        local c = HDG.Theme:GetColor("border.default")
        line:SetColorTexture(c.r, c.g, c.b, 0.42)
    end,

    -- SectionPlate: the Section view's floor-footprint outline. Deliberately
    -- fainter than RoomOutline -- it reads as ground the rooms sit on, and must
    -- never compete with the room edges it frames.
    SectionPlate = function(line, _scheme)
        if not (line and line.SetColorTexture) then return end
        local c = HDG.Theme:GetColor("border.default")
        line:SetColorTexture(c.r, c.g, c.b, 0.28)
    end,

    -- progressbar: Blizzard StatusBar frames. state.variant picks semantic.* fill;
    -- default = "accent". Also paints the unfilled track.
    -- Distinct from ProgressBarFill (texture-tint skinner for WidgetTypes "progressbar").
    progressbar = function(bar, _scheme, state)
        if not bar then return end
        local variant = (state and state.variant) or "accent"
        local fill = HDG.Theme:GetColor("semantic." .. variant)
                     or HDG.Theme:GetColor("semantic.accent")
        bar:SetStatusBarColor(fill.r, fill.g, fill.b, 1)
        -- Track backdrop: surface.sunken tinted at 0.55, cached on the bar (no orphaned children).
        if bar.CreateTexture and bar.GetWidth then
            local track = bar._hdgrTrack
            if not track then
                track = bar:CreateTexture(nil, "BACKGROUND")
                track:SetAllPoints()
                bar._hdgrTrack = track
            end
            if track.SetColorTexture then  -- exception(false-positive): Texture always has SetColorTexture; mock-fidelity guard
                local trackColor = HDG.Theme:GetColor("surface.sunken")
                                   or HDG.Theme:GetColor("surface.panel")
                track:SetColorTexture(trackColor.r, trackColor.g, trackColor.b, 0.55)
            end
        end
    end,

    -- Divider: 1px hairline at border.subtle.
    Divider = function(tex, _scheme)
        if not (tex and tex.SetColorTexture) then return end
        local c = HDG.Theme:GetColor("border.subtle")
        tex:SetColorTexture(c.r, c.g, c.b, c.a)
    end,

    -- SectionBgTint: tinted bg for chromed sections. state.token drives the color.
    SectionBgTint = function(tex, _scheme, state)
        if not (tex and tex.SetColorTexture) then return end
        local token = (state and state.token) or "surface.panel"
        local c = HDG.Theme:GetColor(token)
        tex:SetColorTexture(c.r, c.g, c.b, c.a)
    end,

    -- PinDot: map-pin texture. selected = warning amber; default = accent blue.
    PinDot = function(dot, _scheme, state)
        if not (dot and dot.SetVertexColor) then return end
        local fill
        if state and state.selected then
            fill = HDG.Theme:GetColor("semantic.warning")
        else
            fill = HDG.Theme:GetColor("pin.default.fill")
        end
        dot:SetVertexColor(fill.r, fill.g, fill.b, 1)
    end,

    -- PanelHeaderMain: bg/gloss/edges base for ALL header bars. Used directly by
    -- the main window title bar (its ends carry the wordmark + close button, so
    -- no foliage). Per-view header bars use `PanelHeader` (below) = this + foliage.
    PanelHeaderMain = function(frame, _scheme)
        -- SetBackdrop is unreliable here (stale Backdrop API between reskins).
        -- Direct CreateTexture + watercolor bg + gloss sheen for consistent depth.
        -- One skinner for all panel headers (main title, Decor Browser, tabs).
        local bg = frame._hdgrHeaderBg
        if not bg and frame.CreateTexture then
            bg = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
            bg:SetAllPoints()
            bg:SetTexture("Interface\\AddOns\\HousingDecorGuide\\textures\\watercolor")
            frame._hdgrHeaderBg = bg
        end
        -- Housing: stamp the wood-sign atlas (true color); other schemes keep the
        -- watercolor paper tinted to surface.panel_header. Toggling SetAtlas/SetTexture
        -- on the same texture tears the wood down on switch-away.
        local sign = HDG.Theme:Chrome("headerSign")
        if sign and bg and bg.SetAtlas then
            bg:SetAtlas(sign)
            bg:SetVertexColor(1, 1, 1, 1)
        else
            local bgColor = HDG.Theme:GetColor("surface.panel_header")
            if bg and bg.SetTexture then
                bg:SetTexture("Interface\\AddOns\\HousingDecorGuide\\textures\\watercolor")
                -- Clear atlas texcoords: atlas->file keeps them (wow-api SetAtlas gotcha),
                -- which would render the watercolor cropped on switch-away from Housing.
                if bg.SetTexCoord then bg:SetTexCoord(0, 1, 0, 1) end
            end
            if bg and bg.SetVertexColor and bgColor then
                bg:SetVertexColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a)
            end
        end

        -- Gloss sheen: vertical transparent -> faint white gradient (top-down light falloff).
        local gloss = frame._hdgrHeaderGloss
        if not gloss and frame.CreateTexture then
            gloss = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
            gloss:SetAllPoints()
            gloss:SetTexture("Interface\\Buttons\\WHITE8x8")
            if gloss.SetGradient and _G.CreateColor then
                gloss:SetGradient("VERTICAL", _G.CreateColor(1, 1, 1, 0), _G.CreateColor(1, 1, 1, 0.12))
            end
            frame._hdgrHeaderGloss = gloss
        end

        local edge = frame._hdgrHeaderEdge
        if not edge and frame.CreateTexture then
            edge = frame:CreateTexture(nil, "BORDER")
            if edge.SetPoint then  -- exception(false-positive): Texture always has SetPoint; mock-fidelity guard
                edge:SetPoint("BOTTOMLEFT", 0, 0)
                edge:SetPoint("BOTTOMRIGHT", 0, 0)
            end
            edge:SetHeight(1)
            frame._hdgrHeaderEdge = edge
        end
        local edgeColor = HDG.Theme:GetColor("border.subtle")
        if edge and edge.SetColorTexture and edgeColor then
            edge:SetColorTexture(edgeColor.r, edgeColor.g, edgeColor.b, edgeColor.a)
        end

        -- Outer window edges: band is full-bleed at top, so these complete the Canvas border.
        local frameEdge = HDG.Theme:GetColor("border.default")
        bandEdge(frame, "_hdgrHeaderEdgeTop",   "TOPLEFT",  "TOPRIGHT",    true,  frameEdge)
        bandEdge(frame, "_hdgrHeaderEdgeLeft",  "TOPLEFT",  "BOTTOMLEFT",  false, frameEdge)
        bandEdge(frame, "_hdgrHeaderEdgeRight", "TOPRIGHT", "BOTTOMRIGHT", false, frameEdge)
    end,

    -- PanelHeader: per-view header bars (the chrome="PanelHeader" slot frames).
    -- = PanelHeaderMain (bg/gloss/edges) + Housing foliage bookends at each end.
    -- Foliage shows only when the scheme declares chrome.foliage* (Housing);
    -- SetShown(false) tears it down on switch-away. Experiment.
    PanelHeader = function(frame, scheme)
        HDG.Theme.Skinners.PanelHeaderMain(frame, scheme)
        if not frame then return end
        local folL = HDG.Theme:Chrome("foliageLeft")
        if folL and not frame._hdgrFoliageL and frame.CreateTexture then
            frame._hdgrFoliageL = frame:CreateTexture(nil, "OVERLAY")
            frame._hdgrFoliageL:SetSize(12, 26)
            -- Flush to the bar's left end; nudged up 5px to frame the top edge.
            frame._hdgrFoliageL:SetPoint("LEFT", frame, "LEFT", 0, 5)
        end
        if frame._hdgrFoliageL then
            if folL then frame._hdgrFoliageL:SetAtlas(folL) end
            frame._hdgrFoliageL:SetShown(folL ~= nil)
        end
        local folR = HDG.Theme:Chrome("foliageRight")
        if folR and not frame._hdgrFoliageR and frame.CreateTexture then
            frame._hdgrFoliageR = frame:CreateTexture(nil, "OVERLAY")
            frame._hdgrFoliageR:SetSize(12, 26)
            -- Flush to the bar's right end; nudged up 5px to frame the top edge.
            frame._hdgrFoliageR:SetPoint("RIGHT", frame, "RIGHT", 0, 5)
        end
        if frame._hdgrFoliageR then
            if folR then frame._hdgrFoliageR:SetAtlas(folR) end
            frame._hdgrFoliageR:SetShown(folR ~= nil)
        end
    end,

    -- EditBox: surface.sunken backdrop + focus ring (accent border on focus,
    -- border.default at rest; WoW has no box-shadow so the border IS the ring).
    -- Focus state set by editbox builder OnEditFocusGained/Lost -> Theme:SetState.
    EditBox = function(frame, _scheme)
        setBackdrop(frame, HDG.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, HDG.Theme:GetColor("surface.sunken"))
        local focused = HDG.Theme.states[frame] and HDG.Theme.states[frame].focused
        setBackdropBorderColor(frame, HDG.Theme:GetColor(focused and "border.focus" or "border.default"))
        setTextColor(frame, HDG.Theme:GetColor("text.primary"))
    end,

    PanelFooter = function(frame, _scheme)
        setBackdrop(frame, HDG.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, HDG.Theme:GetColor("surface.panel_footer"))
        setBackdropBorderColor(frame, HDG.Theme:GetColor("border.subtle"))
    end,

    -- StatusRail: window bottom band. Full-bleed watercolor + gloss, matching PanelHeader.
    -- Dark = surface.statusline; light = surface.panel_footer (statusline reads loud on Kanagawa Lotus).
    -- Direct CreateTexture (SetBackdrop unreliable here, same reason as PanelHeader).
    StatusRail = function(frame, _scheme)
        -- Watercolor paper bg tinted to rail color.
        local bg = frame._hdgrRailBg
        if not bg and frame.CreateTexture then
            bg = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
            bg:SetAllPoints()
            bg:SetTexture("Interface\\AddOns\\HousingDecorGuide\\textures\\watercolor")
            frame._hdgrRailBg = bg
        end
        -- Housing: wood-sign atlas along the bottom band; other schemes keep the
        -- watercolor paper tinted to the rail color (teardown via SetTexture).
        local sign = HDG.Theme:Chrome("headerSign")
        if sign and bg and bg.SetAtlas then
            bg:SetAtlas(sign)
            bg:SetVertexColor(1, 1, 1, 1)
        else
            local light = HDG.Theme.currentScheme and HDG.Theme.currentScheme.isLight
            local bgColor = HDG.Theme:GetColor(light and "surface.panel_footer" or "surface.statusline")
            if bg and bg.SetTexture then
                bg:SetTexture("Interface\\AddOns\\HousingDecorGuide\\textures\\watercolor")
                -- Clear atlas texcoords: atlas->file keeps them (wow-api SetAtlas gotcha),
                -- which would render the watercolor cropped on switch-away from Housing.
                if bg.SetTexCoord then bg:SetTexCoord(0, 1, 0, 1) end
            end
            if bg and bg.SetVertexColor and bgColor then
                bg:SetVertexColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a)
            end
        end

        -- Gloss sheen overlay (same vertical gradient as PanelHeader).
        local gloss = frame._hdgrRailGloss
        if not gloss and frame.CreateTexture then
            gloss = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
            gloss:SetAllPoints()
            gloss:SetTexture("Interface\\Buttons\\WHITE8x8")
            if gloss.SetGradient and _G.CreateColor then
                gloss:SetGradient("VERTICAL", _G.CreateColor(1, 1, 1, 0), _G.CreateColor(1, 1, 1, 0.12))
            end
            frame._hdgrRailGloss = gloss
        end

        local edge = frame._hdgrRailEdge
        if not edge and frame.CreateTexture then
            edge = frame:CreateTexture(nil, "BORDER")
            if edge.SetPoint then  -- exception(false-positive): Texture always has SetPoint; mock-fidelity guard
                edge:SetPoint("TOPLEFT", 0, 0)
                edge:SetPoint("TOPRIGHT", 0, 0)
            end
            edge:SetHeight(1)
            frame._hdgrRailEdge = edge
        end
        local edgeColor = HDG.Theme:GetColor("border.subtle")
        if edge and edge.SetColorTexture and edgeColor then
            edge:SetColorTexture(edgeColor.r, edgeColor.g, edgeColor.b, edgeColor.a)
        end

        -- Outer window edges: band is full-bleed at base, so these complete the Canvas border.
        local frameEdge = HDG.Theme:GetColor("border.default")
        bandEdge(frame, "_hdgrRailEdgeBottom", "BOTTOMLEFT", "BOTTOMRIGHT", true,  frameEdge)
        bandEdge(frame, "_hdgrRailEdgeLeft",   "TOPLEFT",    "BOTTOMLEFT",  false, frameEdge)
        bandEdge(frame, "_hdgrRailEdgeRight",  "TOPRIGHT",   "BOTTOMRIGHT", false, frameEdge)
    end,

    Sunken = function(frame, _scheme)
        setBackdrop(frame, HDG.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, HDG.Theme:GetColor("surface.sunken"))
        setBackdropBorderColor(frame, HDG.Theme:GetColor("border.subtle"))
    end,

    -- InsetBg: surface.sunken texture for inset backgrounds (e.g. ProgressBar trough).
    InsetBg = function(tex, _scheme)
        if not (tex and tex.SetColorTexture) then return end
        local c = HDG.Theme:GetColor("surface.sunken")
        tex:SetColorTexture(c.r, c.g, c.b, c.a)
    end,

    TextHeading = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("text.heading"))
    end,

    TextSubheading = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("text.subheading"))
    end,

    TextMuted = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("text.muted"))
    end,

    TextNumeric = function(text, _scheme)
        setTextColor(text, HDG.Theme:GetColor("text.numeric"))
    end,

    -- TextShadow: scheme-driven drop-shadow on a FontString.
    -- Composable: register under BOTH TextShadow + a color role; each Skinner is independent.
    TextShadow = function(text, scheme)
        if not (text and text.SetShadowColor) then return end
        local s = scheme and scheme.text
        local c = s and s.shadow
        local o = s and s.shadowOffset
        if c then
            text:SetShadowColor(c.r, c.g, c.b, c.a)
        end
        if o and text.SetShadowOffset then
            text:SetShadowOffset(o.x, o.y)
        end
    end,

    -- ===== Nav sidebar skinners =============================================
    -- NavRegion: borderless sidebar container (surface.panel_soft; avoids double-border).
    NavRegion = function(frame, _scheme)
        setBackdrop(frame, HDG.Theme.BACKDROP_NOEDGE)
        -- Housing: stone sidebar atlas; other schemes paint the solid panel_soft fill.
        if HDG.Theme:_applyChromeBg(frame, "_hdgrNavBg", "navPanel", -7) then
            setBackdropColor(frame, { r = 0, g = 0, b = 0, a = 0 })
        else
            setBackdropColor(frame, HDG.Theme:GetColor("surface.panel_soft"))
        end
    end,

    -- NavRow: TreeList nav row by tier + active + spine (no zebra).
    -- state: { tier, active, spine }. Uses EnsureRowChrome accentBar + selectedBg.
    NavRow = function(frame, _scheme, state)
        if not (frame and frame._hdgrChrome) then return end
        local chrome = frame._hdgrChrome
        local tier   = state and state.tier
        local active = state and state.active and true or false
        local spine  = state and state.spine  and true or false
        _paintNavAccentBar(chrome, active or spine)
        _paintNavRowFill(frame, chrome, _navRowFill(tier, active))
        -- Mouseover: tint hover texture to surface.hover (defaults to solid white).
        if chrome.hover then
            local h = HDG.Theme:GetColor("surface.hover")
            chrome.hover:SetVertexColor(h.r, h.g, h.b, h.a)
        end
        -- Icon tint: text.dim at rest, accent when active or spine.
        if frame._navIcon then
            local ic = (active or spine) and HDG.Theme:GetColor("semantic.accent")
                or HDG.Theme:GetColor("text.dim")
            frame._navIcon:SetVertexColor(ic.r, ic.g, ic.b, ic.a)
        end
        if frame._navGuide then
            local gd = HDG.Theme:GetColor("border.subtle")
            frame._navGuide:SetVertexColor(gd.r, gd.g, gd.b, gd.a)
        end
        if chrome.zebra then chrome.zebra:Hide() end
    end,

    -- (NavItem / NavHome skinners retired: sidebar nav is a TreeList painted by NavRow.)
}

-- resolveScheme: env.scheme overrides currentScheme when provided (sub-tree previews,
-- test isolation, cross-addon themes per spec section 9.2).

-- Register a widget with a Skinner. state cached weak-keyed so Theme:Reload
-- can re-run with the same state; passing state again replaces the cached entry.
local function resolveScheme(self, env)
    return (env and env.scheme) or self:GetScheme()
end

function HDG.Theme:Register(widget, widgetType, state, env)
    if not widget or not widgetType then
        -- Warn (not error) so one bad widget can't halt a batch repaint.
        -- RegisterKind is the strict-error variant. per ADR-015.
        HDG.Log:Warn("theme",
            ("Register: nil %s -- nothing to paint (build failed or caller bug)")
            :format(not widget and "widget" or "role"))
        return false
    end
    local prev = self.registry[widget]
    self.registry[widget] = widgetType
    -- A widget can carry several roles (RowWoodBeam then RowChrome on a styles
    -- row). The registry keeps only the last, so ApplyAll once re-ran only that
    -- one and every earlier role froze at the old scheme. ApplyAll replays them
    -- all, in order, each with the state it came with. Most widgets carry one
    -- role, which the registry already holds, so the list starts only when a
    -- second role arrives: a list for every widget was ~5,800 tables in a
    -- browsed window (memory census 2026-10-19).
    local roles = self.roles[widget]
    if not roles and prev and prev ~= widgetType then
        roles = { prev }
        self.roles[widget] = roles
        self.roleStates[widget] = { [prev] = self.states[widget] }
    end
    if roles then
        local known = false
        for _, r in ipairs(roles) do if r == widgetType then known = true end end
        if not known then roles[#roles + 1] = widgetType end
        if state ~= nil then self.roleStates[widget][widgetType] = state end
    end
    if state ~= nil then self.states[widget] = state end
    local skin = self.Skinners and self.Skinners[widgetType]
    if skin then
        skin(widget, resolveScheme(self, env), self.states and self.states[widget])
    else
        -- ADR-015: unknown role must FAIL LOUD; silent no-op hides Skinner typos.
        HDG.Log:Warn("theme",
            "Register: no Skinner for role '" .. tostring(widgetType) .. "' -- widget will not paint")
    end
    return true
end

function HDG.Theme:Apply(widget, widgetType, env)
    if not widget then return false end
    local resolvedType = widgetType or self.registry[widget]
    local skin = self.Skinners and self.Skinners[resolvedType]
    if not skin then
        -- ADR-015, same as Register: a role with no Skinner fails loud, not silent.
        HDG.Log:Warn("theme", "Apply: no Skinner for role '" .. tostring(resolvedType) .. "' -- widget will not paint")
        return false
    end
    skin(widget, resolveScheme(self, env), self.states and self.states[widget])
    return true
end

-- Every role of every widget, in registration order -- the order the build
-- painted them. The last role takes the widget's live state (SetState writes
-- it); an earlier one takes the state it was registered with, so RowWoodBeam
-- keeps the alpha it reads strictly.
local function applyRole(self, widget, role, scheme, state)
    local skin = self.Skinners[role]
    if not skin then
        HDG.Log:Warn("theme", "ApplyAll: no Skinner for role '" .. tostring(role) .. "' -- widget will not paint")
        return
    end
    skin(widget, scheme, state)
end

function HDG.Theme:ApplyAll(env)
    local scheme = resolveScheme(self, env)
    for widget, last in pairs(self.registry) do
        local roles = self.roles[widget]
        if roles then
            local byRole = self.roleStates[widget]
            for _, role in ipairs(roles) do
                applyRole(self, widget, role, scheme, (role ~= last and byRole[role]) or self.states[widget])
            end
        else
            applyRole(self, widget, last, scheme, self.states[widget])
        end
    end
end

-- Reload is an alias for ApplyAll. LoadScheme calls ApplyAll on palette swaps;
-- external callers use Reload for a paint refresh without a scheme change.
HDG.Theme.Reload = HDG.Theme.ApplyAll

-- SetState: merge updates into stored state and re-apply the skinner.
-- Field-by-field merge: SetState({ active = true }) preserves other fields.
-- To clear a field: set to false (passing nil has no effect in Lua tables).
function HDG.Theme:SetState(widget, updates)
    if not widget then return end
    local widgetType = self.registry[widget]
    if not widgetType then return end
    local current = self.states[widget] or {}
    if type(updates) == "table" then
        for k, v in pairs(updates) do current[k] = v end
    end
    self.states[widget] = current
    self:Apply(widget, widgetType)
end

