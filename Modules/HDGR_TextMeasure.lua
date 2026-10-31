-- HDG.TextMeasure
-- ============================================================================
-- How many lines a text takes in a theme font role at a width: a real FontString wraps it
-- and says (GetNumLines), on a frame that is shown but never seen. Word widths from
-- GetUnboundedStringWidthForText ran narrow of the drawn text, so a row could wrap one
-- line more than measured and overlap the next (review B8; owner ruling 10-30: the real
-- count). A read of font metrics, no state: the Quest Tracker's selectors size its wrapped
-- rows with it, as they read names through the resolvers. Callers read
-- session.resolvers.fonts.tick (the fonts resolver in HDGR_Store.lua), which the Theme
-- bumps once it has built new fonts, so a font change in Settings re-measures.

HDG = HDG or {}
HDG.TextMeasure = HDG.TextMeasure or {}
local M = HDG.TextMeasure

-- Shown at alpha 0, as the /dqmeasure probe measured in game: a FontString on a hidden
-- frame may not lay out its text.
local host = CreateFrame("Frame", nil, UIParent)
host:SetSize(1, 1)
host:SetPoint("TOPLEFT")
host:SetAlpha(0)
local _fs = {}   -- [role] = the FontString that measures it

local function _newFontString()
    local fs = host:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("TOPLEFT")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    return fs
end

local function _fontString(role)
    _fs[role] = _fs[role] or _newFontString()   -- exception(false-positive): lazy, one per font role
    local fo = HDG.Theme:GetFont(role)
    assert(fo, "HDG.TextMeasure: unknown font role " .. tostring(role))
    _fs[role]:SetFontObject(fo)   -- every call: a font change in Settings swaps the role's font
    return _fs[role]
end

function M:Lines(role, width, text)
    local fs = _fontString(role)
    fs:SetWidth(width)
    fs:SetText(text)
    return fs:GetNumLines()
end
