-- HDG.WinterVeilOffer
-- ============================================================================
-- The Winter Veil theme offer. While the Feast of Winter Veil is on, opening the
-- main window on a profile that is not on the theme brings up a pop-up over the
-- window offering it (owner's design, 2026-11-01; mockup
-- docs/mockups/winter_veil_offer.html). When it is due: the selector
-- holiday.winterVeilOfferDue. Once per Winter Veil per profile, the profile the
-- theme belongs to: Switch, No thanks and ESC each close it, and the closing
-- records the year, so it stays away until next Winter Veil. Closing the window
-- under it closes it too, and counts the same. Switch also turns Theme decorations
-- on, since the pop-up promises the snow and lights. Nothing switches back by
-- itself; the pop-up says where the theme setting is.
--
-- It paints in the player's own theme (the theme engine paints everything in the
-- current scheme), with the Winter Veil art over its title strip.

HDG = HDG or {}
HDG.WinterVeilOffer = HDG.WinterVeilOffer or {}
local WVO = HDG.WinterVeilOffer

local OFFER_W   = 400
local BAND_H    = 32
local PAD       = 16
local TITLE_X   = 44   -- the title starts clear of the left-hand holly sprig
local PARA_GAP  = 10
local BUTTON_H  = 26
local BUTTON_GAP = 14  -- above the buttons, and between them (half)
-- What brings the offer up: the window opening, the holiday starting, a record
-- changing. Not the theme, though the selector reads it: a player who switches
-- away from Winter Veil with the window open has just answered the offer, and it
-- popped up at once.
local WATCH = { "account.ui.mainWindowShown", "session.holiday.winterVeil",
                "account.config.winterVeilOffered" }

local function _setConfig(key, value)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CONFIG_SET, payload = { key = key, value = value } })
end

local function _text(parent, key, font, role, wrap)
    return HDG.UI:Label(parent, HDG.Locale:Get(key), font, "LEFT", { role = role, wrap = wrap })
end

local function _button(parent, key, variant, width)
    local b = HDG.UI:Button(parent, HDG.Locale:Get(key), "body")
    b._hdgrVariant = variant
    HDG.Theme:Register(b, "Button")
    b:SetSize(width, BUTTON_H)
    return b
end

-- ESC answers No thanks and leaves the window open; every other key passes on.
-- SetPropagateKeyboardInput is restricted in combat. The pop-up never opens in
-- combat (_show), so keys were set to pass on when it opened; once combat starts
-- they keep passing, and the window's own handler takes ESC (closing the window,
-- which closes this too).
local function _onKey(self, key)
    if InCombatLockdown() then return end  -- exception(boundary): restricted call in combat
    self:SetPropagateKeyboardInput(key ~= "ESCAPE")
    if key == "ESCAPE" then self:Hide() end
end

local function _onShow(self)
    self:SetPropagateKeyboardInput(true)
end

-- Every close is the answer, the window closing under it included. Hiding the
-- window hides this with it but leaves its own shown flag set, so it came back
-- on the next open, already answered: hide it for real. On a frame no longer
-- visible, Hide changes the flag and fires no second OnHide. The flag goes
-- before the record: the record can bring the next offer up (closing the
-- preview lets the real one come), and that one must not be hidden unseen.
local function _onHide(self)
    if self:IsShown() then self:Hide() end
    _setConfig("winterVeilOffered", self._year)
end

-- The frame and its title strip: the window's own title band look, with the art.
local function _buildFrame(main)
    local f = CreateFrame("Frame", nil, main, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetWidth(OFFER_W)
    f:SetPoint("CENTER", main, "CENTER")
    f:EnableMouse(true)
    f:EnableKeyboard(true)
    HDG.Theme:Register(f, "Frame")
    f:Hide()
    local band = CreateFrame("Frame", nil, f)
    band:SetPoint("TOPLEFT")
    band:SetPoint("TOPRIGHT")
    band:SetHeight(BAND_H)
    HDG.Theme:Register(band, "PanelHeaderMain")
    f.title = _text(band, "WV_OFFER_TITLE", "subheading", "TextHeading", false)
    f.title:SetPoint("LEFT", band, "LEFT", TITLE_X, 0)
    return f
end

-- The two paragraphs and the buttons under the strip.
local function _buildBody(f)
    f.body = _text(f, "WV_OFFER_BODY", "body", "Text", true)
    f.body:SetWidth(OFFER_W - 2 * PAD)
    f.body:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(BAND_H + PAD))
    f.how = _text(f, "WV_OFFER_HOW", "body", "Text", true)
    f.how:SetWidth(OFFER_W - 2 * PAD)
    f.how:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -PARA_GAP)
    f.switch = _button(f, "WV_OFFER_SWITCH", "primary", 170)
    f.switch:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
    f.decline = _button(f, "WV_OFFER_NO", "default", 100)
    f.decline:SetPoint("RIGHT", f.switch, "LEFT", -BUTTON_GAP / 2, 0)
end

-- Every way out closes the frame, and the closing is the answer.
local function _wire(f)
    f:SetScript("OnHide", _onHide)
    f:SetScript("OnShow", _onShow)
    f:SetScript("OnKeyDown", _onKey)
    f.decline:SetScript("OnClick", function() f:Hide() end)
    f.switch:SetScript("OnClick", function()
        _setConfig("scheme", "WinterVeil")
        _setConfig("themeDecorations", true)
        f:Hide()
    end)
end

local function _build(main)
    local f = _buildFrame(main)
    _buildBody(f)
    _wire(f)
    HDG.UI.AttachTitleDecorations(f, f.title)
    main._hdgrWinterVeilOffer = f
    return f
end

-- Tall enough for both paragraphs at the pop-up's width (they wrap per locale).
local function _height(f)
    return BAND_H + PAD + f.body:GetStringHeight() + PARA_GAP + f.how:GetStringHeight()
        + BUTTON_GAP + BUTTON_H + PAD
end

-- `year` is what closing it records. Never in combat: EnableKeyboard is protected
-- and SetPropagateKeyboardInput restricted there, and a keyboard frame shown
-- without the propagate set ate every key -- movement included -- until closed.
-- The next window open after combat offers it.
local function _show(main, year)
    if InCombatLockdown() then return end  -- exception(boundary): protected keyboard calls in combat
    local f = main._hdgrWinterVeilOffer or _build(main)
    if f:IsShown() then return end
    f._year = year
    f:SetHeight(_height(f))
    f:Show()
end

local function _maybeOffer(main)
    local year = HDG.Selectors:Call("holiday.winterVeilOfferDue", HDG.Store:GetState(), {})  -- exception(false-positive): top-level subscriber read, not a row factory
    if not year then return end  -- exception(nullable): no offer due
    _show(main, year)
end

-- /hdgr winterveil: the pop-up now, holiday or not, to check how it looks.
-- Closing it records the year already on record, so the real offer still comes.
function WVO.Preview(main)
    _show(main, HDG.Store:GetConfig("winterVeilOffered"))
end

-- Wired once, with the main window (CreateMainWindow). The closing check covers a
-- window built already open, with the holiday already read.
function WVO.Attach(main)
    HDG.Store:Subscribe(function(_, invalidation)
        if HDG.Paths.MatchesAny(WATCH, invalidation) then _maybeOffer(main) end
    end)
    _maybeOffer(main)
end
