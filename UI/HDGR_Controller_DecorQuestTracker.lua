-- HDG.DecorQuestTrackerController
-- ============================================================================
-- The Quest Tracker window (HDGR_LayoutConfig_DecorQuestTracker.lua): Wire() for its
-- header and buttons, and the decorQuestTrackerRow factory. The selectors shape every
-- row (decorQuests.trackerRows, HDGR_Selectors_DecorQuests.lua):
--   text   a line of text in a tone and a font; it wraps. An expanded tracker's next steps
--          carry their own Wpt (or Arrow, for a quest in the log) at the right
--   pair   what the target belongs to ... how far along it is
--   rule   the line between the step to head for and the progress under it
--   strip  the step discs (the look of Slipstream's tour HUD): done ones a check, the
--          step to head for ringed in the accent, a quest in the log ringed gold, the decor
--          quest its decor's icon, "+k" for steps off either end. An any-order group
--          (ruling G) is one column: a rounded box of smaller discs in two rows, its edge in
--          the accent while the step to head for is in it.
--          A disc click heads for that step (DQ_PICK_STEP, saved with what is tracked).
-- Click handlers are module-level and read what the paint stamped on the frame.

HDG = HDG or {}
HDG.DecorQuestTrackerController = HDG.DecorQuestTrackerController or {}

local Controller = HDG.DecorQuestTrackerController
local CH = HDG.ControllerHelpers

local CHECK = { [26] = "|A:common-icon-checkmark:12:12|a", [20] = "|A:common-icon-checkmark:10:10|a" }   -- by ring
local DISC, RING = 22, 26        -- a disc, and the ring round the step to head for
local GAP = 4                    -- one column to the next; a link runs across it
local BOX_DISC, BOX_RING = 16, 20   -- a disc in an any-order box
local BOX_GAP, BOX_PAD = 2, 3       -- between a box's discs, and round them inside its edge
local BOX_H = 2 * BOX_RING + BOX_GAP + 2 * BOX_PAD   -- two rows: 48, inside the selectors' TRACKER_STRIP_H.boxed
local MORE_W = 26                 -- a "+k" label
local WPT_W, WPT_H = 40, 16       -- a next step's Wpt (the selectors' TRACKER_WPT.h)
local RULE_AT = HDG.Constants.DQ_TRACKER.ruleAt   -- the rule's y in its row
local WHITE = "Interface\\Buttons\\WHITE8X8"
local RING_TONE = { target = "semantic.accent", log = "semantic.warning" }   -- the step to head for; a quest in the log (gold)
-- A disc's fill by state: the step to head for filled in the text colour, its number in the
-- sunken one -- opposite ends of every scheme, so it reads first among the green done discs
-- (review G1).
local FILL_TONE = { done = "semantic.success", target = "text.primary", log = "surface.sunken", ahead = "surface.sunken" }

local function L(key) return HDG.Locale:Get(key) end

local function _dispatch(action, payload)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS[action], payload = payload })
end

-- ===== Text tones ==========================================================

local _toned = HDG.UI.Toned

-- A text row's text: its runs each in their own tone ("Complete these:" dim, the place
-- line's gold "!" and "?", the Next line's quest name), else the whole text in the row's.
local function _rowText(ed)
    if not ed.runs then return _toned(ed.tone, ed.text) end   -- exception(optional): only the Next, box and place lines carry runs
    return HDG.UI.RunsText(ed.runs)
end

-- ===== Discs ===============================================================

local function _onDiscClick(self)
    _dispatch("DQ_PICK_STEP", { key = self._pickKey, quest = self._pick, tracked = true })
end

local function _discTip(self)
    local lines = self._pick and { L("DQ_TRK_DISC_PICK") } or nil
    return { title = self._tip, extraLines = lines }
end

local function _discTexture(disc, layer, sub)
    local tex = disc:CreateTexture(nil, layer, nil, sub)
    tex:SetPoint("CENTER")
    tex:SetTexture(WHITE)
    HDG.UI.CircleMask(tex)
    return tex
end

local function _newDisc(row)
    local disc = CreateFrame("Button", nil, row)
    disc._ring = _discTexture(disc, "BACKGROUND", 1)
    disc._fill = _discTexture(disc, "BORDER", 1)
    disc._icon = _discTexture(disc, "ARTWORK", 1)
    disc._hover = _discTexture(disc, "HIGHLIGHT", 1)   -- shown only on a disc that picks a step (review G5)
    HDG.UI.ToneTexture(disc._hover, "surface.hover")
    disc._label = HDG.UI.RowText(disc, "caption", "Text", "CENTER")
    disc._label:SetPoint("CENTER")
    disc:RegisterForClicks("LeftButtonUp")
    HDG.TooltipEngine:Attach(disc, _discTip)
    return disc
end

-- A strip disc (ring) or a box's (BOX_RING); above the box it may sit in.
local function _sizeDisc(row, disc, ring, size)
    disc:SetSize(ring, ring)
    disc._ring:SetSize(ring, ring)
    disc._hover:SetSize(ring, ring)
    disc._fill:SetSize(size, size)
    disc._icon:SetSize(size - 4, size - 4)
    disc._check = CHECK[ring]
    disc:SetFrameLevel(row:GetFrameLevel() + 2)
end

-- A disc's face: a check once done, the decor's icon on the decor quest, else its number.
local function _paintDiscFace(disc, d)
    disc._icon:Hide()
    if d.state == "done" then
        disc._label:SetText(disc._check)
    elseif d.icon then   -- exception(optional): only the decor quest's disc carries an icon
        HDG.UI.PaintIcon(disc._icon, nil, d.icon, HDG.Constants.PLACEHOLDER_ICON)
        disc._icon:Show()
        disc._label:SetText("")
    else
        disc._label:SetText(_toned(d.state == "target" and "sunken" or "text", tostring(d.num)))
    end
end

local function _paintDisc(disc, d, pickKey)
    HDG.UI.ToneTexture(disc._fill, FILL_TONE[d.state])
    local ringTone = RING_TONE[d.state]   -- exception(nullable): a done or ahead disc has no ring
    disc._ring:SetShown(ringTone ~= nil)
    if ringTone then HDG.UI.ToneTexture(disc._ring, ringTone) end
    _paintDiscFace(disc, d)
    disc._pickKey, disc._pick, disc._tip = pickKey, d.pick, d.tip
    -- Only a disc that picks a step clicks: the ringed one and a done one on an unfinished
    -- chain pick nothing, and a click there would clear the pick.
    disc:SetScript("OnClick", d.pick and _onDiscClick or nil)   -- exception(optional): only a pickable disc carries d.pick
    disc._hover:SetShown(d.pick ~= nil)
    disc:EnableMouse(true)
    disc:Show()
end

local function _discAt(row, i)
    row._discs[i] = row._discs[i] or _newDisc(row)   -- exception(false-positive): lazy pool, made the first time a strip needs this disc
    return row._discs[i]
end

-- The line across the gap, from one column's edge (x1) to the next one's (x2).
local function _link(row, i, x1, x2)
    row._links[i] = row._links[i] or row:CreateTexture(nil, "ARTWORK")   -- exception(false-positive): lazy pool, made the first time a strip needs this link
    local link = row._links[i]
    link:SetSize(x2 - x1, 2)
    link:SetTexture(WHITE)
    HDG.UI.ToneTexture(link, "text.dim")
    link:SetPoint("LEFT", row, "LEFT", x1, 0)
    link:Show()
end

-- ===== Any-order boxes =====================================================

local function _boxTip(self) return { title = self._tip, extraLines = self._tips } end

-- An outline: the rounded fill in the edge's tone, and inside it, 1px in, the face.
local function _newBox(row)
    local box = CreateFrame("Frame", nil, row)
    box._edge = box:CreateTexture(nil, "BACKGROUND", nil, 0)
    box._edge:SetAllPoints()
    HDG.UI.RoundedFill(box._edge)
    box._face = box:CreateTexture(nil, "BACKGROUND", nil, 1)
    box._face:SetPoint("TOPLEFT", 1, -1)
    box._face:SetPoint("BOTTOMRIGHT", -1, 1)
    HDG.UI.RoundedFill(box._face)
    HDG.UI.ToneTexture(box._face, "surface.panel")
    box:EnableMouse(true)
    HDG.TooltipEngine:Attach(box, _boxTip)
    return box
end

local function _boxAt(row, k)
    row._boxes[k] = row._boxes[k] or _newBox(row)   -- exception(false-positive): lazy pool, made the first time a strip needs this box
    return row._boxes[k]
end

local function _paintBox(row, box, col, w)
    box:SetSize(w, BOX_H)
    box:SetFrameLevel(row:GetFrameLevel() + 1)
    HDG.UI.ToneTexture(box._edge, col.on and "semantic.accent" or "border.default")
    box._tip, box._tips = col.tip, col.tips
    box:Show()
end

-- ===== A next step's Wpt ==================================================

-- A row's button: Arrow (Blizzard's quest arrow) for a step in the log, else Map: a waypoint
-- at where the step starts (or a done decor's vendor) and the world map open on it with the
-- step's numbered disc, in one click (owner pick C 10-29, the waypoint 10-30; a next step's
-- waypoint alone landed off the map you had open, so it seemed to do nothing). Greyed when no
-- spot is known, its tip saying why.
local function _onArrow(self) HDG.Waypoints:FollowQuestStep(self._waySpec) end

local function _onMap(self)
    local w = self._waySpec
    HDG.Waypoints:SetAndShow(w.map, w.x, w.y, w.title, w.num, w.side)
end

-- A Collected! card's decor quest in its zone: Track follows it instead (Place.zoneMore).
local function _onTrack(self) CH.Mechanics.TrackDecorQuests(self._waySpec.track) end

local function _wptKeys(w)
    if w.track then return "DQ_TRACK", "DQ_TRACK_TIP" end
    if w.questID then return "DQ_STEP_ARROW", "DQ_ARROW_TIP" end
    return "DQ_MAP", w.vendor and "DQ_TRK_VENDOR_TIP" or "DQ_MAP_TIP"
end

local function _wptTip(self)
    local w = self._waySpec
    if not w.enabled then return { title = w.why } end
    local _, tip = _wptKeys(w)
    return { title = L(tip):format(w.title) }
end

-- At the row's top right; returns the button, for the text to stop short of.
local function _paintWpt(row, way)
    local b = row._wpt
    b._waySpec = way
    b:SetText(L((_wptKeys(way))))
    b:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    b:SetScript("OnClick", (way.track and _onTrack) or (way.questID and _onArrow) or _onMap)
    HDG.UI.SetEnabledLook(b, way.enabled)
    HDG.TooltipEngine:Attach(b, _wptTip)
    b:Show()
    return b
end

-- ===== Rows ================================================================

local function _layoutRow(row)
    row._text  = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    row._right = HDG.UI.RowText(row, "body", "Text", "RIGHT")
    row._before = HDG.UI.RowText(row, "caption", "TextDim", "CENTER")
    row._after  = HDG.UI.RowText(row, "caption", "TextDim", "CENTER")
    row._discs, row._links, row._boxes = {}, {}, {}
    row._wpt = HDG.UI.RowButton(row, "", WPT_W, WPT_H)
    row._wpt:RegisterForClicks("LeftButtonUp")
    row._rule = row:CreateTexture(nil, "ARTWORK")   -- exception(false-positive): HDGR row chrome draws no ARTWORK gloss to sit under
    row._rule:SetHeight(1)
    row._rule:SetTexture(WHITE)
    HDG.UI.ToneTexture(row._rule, "border.default")
    -- No row clicks, so none lights up on hover or holds the mouse: dragging on a row moves
    -- the window. Discs, boxes and the Wpt take the mouse themselves (review G5).
    row:EnableMouse(false)
end

local function _resetRow(row)
    for _, fs in ipairs({ row._text, row._right, row._before, row._after }) do
        fs:SetText("")
        fs:ClearAllPoints()
        fs:SetWordWrap(false)
    end
    HDG.UI.applyFontRole(row._text, "caption")
    for _, disc in ipairs(row._discs) do disc:Hide(); disc:ClearAllPoints() end
    for _, link in ipairs(row._links) do link:Hide(); link:ClearAllPoints() end
    for _, box in pairs(row._boxes) do box:Hide(); box:ClearAllPoints() end   -- pooled by column, so sparse
    row._wpt:Hide()
    row._wpt:ClearAllPoints()
    row._wpt:SetScript("OnClick", nil)
    row._rule:Hide()
    row._rule:ClearAllPoints()
end

local function _paintText(row, ed)
    HDG.UI.applyFontRole(row._text, ed.font)
    row._text:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    if ed.way then   -- exception(optional): only an expanded tracker's next steps carry a way
        row._text:SetPoint("TOPRIGHT", _paintWpt(row, ed.way), "TOPLEFT", -4, -1)
    else
        row._text:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -1)
    end
    row._text:SetWordWrap(true)
    row._text:SetJustifyV("TOP")
    row._text:SetText(_rowText(ed))
end

-- In the text colour, as the rows above it (the Full mockup; no dim text, owner).
local function _paintPair(row, ed)
    HDG.UI.applyFontRole(row._text, "body")
    row._right:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row._right:SetText(_toned("text", ed.right))
    row._text:SetPoint("LEFT", row, "LEFT", 0, 0)
    row._text:SetPoint("RIGHT", row._right, "LEFT", -6, 0)
    row._text:SetText(_toned("text", ed.left))
end

local function _paintRule(row)
    row._rule:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -RULE_AT)
    row._rule:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -RULE_AT)
    row._rule:Show()
end

-- "+k" off one end of the strip, at x; returns the x after it.
local function _more(fs, row, x, k)
    if k == 0 then return x end
    fs:SetPoint("LEFT", row, "LEFT", x, 0)
    fs:SetWidth(MORE_W)
    fs:SetText("+" .. k)
    return x + MORE_W
end

-- A lone step's disc at x; returns where a link meets it on the left and on the right, and
-- the x after it.
local function _placeDisc(row, ed, col, x)
    local disc, inset = _discAt(row, col.from), (RING - DISC) / 2
    _sizeDisc(row, disc, RING, DISC)
    disc:SetPoint("LEFT", row, "LEFT", x, 0)
    _paintDisc(disc, ed.discs[col.from], ed.pickKey)
    return x + inset, x + RING - inset, x + RING
end

-- A box's disc m (from 0), in its two rows of across, left to right.
local function _placeBoxDisc(row, ed, box, i, m, across)
    local disc, cell = _discAt(row, i), BOX_RING + BOX_GAP
    _sizeDisc(row, disc, BOX_RING, BOX_DISC)
    disc:SetPoint("TOPLEFT", box, "TOPLEFT", BOX_PAD + (m % across) * cell, -(BOX_PAD + math.floor(m / across) * cell))
    _paintDisc(disc, ed.discs[i], ed.pickKey)
end

-- An any-order box (column k) at x: links meet its edges. Returns as _placeDisc.
local function _placeBox(row, ed, col, x, k)
    local n = col.to - col.from + 1
    local across = math.ceil(n / 2)
    local w = across * BOX_RING + (across - 1) * BOX_GAP + 2 * BOX_PAD
    local box = _boxAt(row, k)
    box:SetPoint("LEFT", row, "LEFT", x, 0)
    _paintBox(row, box, col, w)
    for m = 0, n - 1 do _placeBoxDisc(row, ed, box, col.from + m, m, across) end
    return x, x + w, x + w
end

local function _paintStrip(row, ed)
    local x, linkFrom = _more(row._before, row, 0, ed.before), nil
    for k, col in ipairs(ed.cols) do
        local place = col.to > col.from and _placeBox or _placeDisc
        local xIn, xOut, xEnd = place(row, ed, col, x, k)
        if linkFrom then _link(row, k - 1, linkFrom, xIn) end
        linkFrom, x = xOut, xEnd + GAP
    end
    _more(row._after, row, x, ed.after)
end

local PAINT = { text = _paintText, pair = _paintPair, strip = _paintStrip, rule = _paintRule }

local function _rowFactory(_template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_dqTrackerLaidOut", _layoutRow)
            HDG.UI.PaintRowChrome(row, false)
            _resetRow(row)
            PAINT[ed.kind](row, ed)
            row:SetHeight(ed.height)
        end,
        Reset = _resetRow,
    }
end

HDG.Rows:Register("decorQuestTrackerRow", {
    font    = "body",
    height  = function(_index, ed) return ed.height end,
    factory = _rowFactory,
    key     = function(ed) return ed.key end,
})

-- ===== Controller wiring ===================================================

local function _onOpen()
    local show = HDG.Selectors:Call("decorQuests.trackerOpen", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller click, not a row factory
    CH.Mechanics.JumpToDecorQuests(show)
end

function Controller:Wire(rootFrame)
    HDG.UI.OnClick(rootFrame, "decorQuestTrackerPanel.close", function()
        _dispatch("DQ_TRACKER_TOGGLE", { visible = false })
    end)
    HDG.UI.OnClick(rootFrame, "decorQuestTrackerPanel.expand", function() _dispatch("DQ_TRACKER_EXPAND") end)
    HDG.UI.OnClick(rootFrame, "decorQuestTrackerPanel.settings", function()
        HDG.SettingsPanel.OpenToSection("questTracker")
    end)
    HDG.UI.OnClick(rootFrame, "decorQuestTrackerButtonPanel.open", _onOpen)
    HDG.UI.OnClick(rootFrame, "decorQuestTrackerButtonPanel.stop", CH.Mechanics.StopTrackingDecorQuests)
    HDG.UI.OnClick(rootFrame, "decorQuestTrackerButtonPanel.done", CH.Mechanics.StopTrackingDecorQuests)
end

function Controller:Refresh(_rootFrame, _ctx)
    -- Every widget paints through its binding; nothing imperative.
end

HDG.Controllers:Register("decorQuestTracker", Controller)
