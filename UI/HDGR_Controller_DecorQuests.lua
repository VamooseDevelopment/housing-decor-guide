-- HDG.DecorQuestsController
-- ============================================================================
-- Decor Quests tab: Wire() for the list panel's controls, and two row factories
-- (selectors shape every row in HDGR_Selectors_DecorQuests.lua; these paint through
-- Theme / Palette and wire clicks off the row's own envelope):
--   decorQuestsListRow   -- group (an expansion, the lone quests, the treasure hunts) /
--                           decor / chain (By Chain: a line, or a campaign)
--   decorQuestsDetailRow -- the detail's flattened rows: info, next (the boxed Next block
--                           under it), note, section, bar,
--                           step (a bar down its left in an any-order box), boxHead
--                           (the box's "Complete these"), fold, quest, blank, and By Chain's decorLine, part,
--                           chapter (a campaign card's), track (an opened chapter's),
--                           missing (quest done: the vendor card, decor owned or not),
--                           alt (a character's progress); info and section rows can
--                           carry a Track button too; next its one Map (or Arrow); a step
--                           not done here and a lone quest their own Wpt (or Arrow)
-- Click handlers are module-level and read what the paint stamped on the frame
-- (row._ed): rows repaint on every scroll, and a closure per paint was garbage each
-- time (Recipe Sources' rule).

HDG = HDG or {}
HDG.DecorQuestsController = HDG.DecorQuestsController or {}

local Controller = HDG.DecorQuestsController
local CH = HDG.ControllerHelpers
local VIEW = "decorQuests"

local CHECK = "|A:common-icon-checkmark:12:12|a"

local function L(key) return HDG.Locale:Get(key) end
local function _dim(text) return HDG.Theme:ColorCode("text.dim") .. text .. "|r" end

-- ===== Shared paint ========================================================

-- Kind chip: a chain and a lone quest in the quest color as the mockup's, a hunt in
-- the treasure color, a repeatable in gold (the repeatables mockup's).
local KIND_COLOR = {
    chain      = function() return HDG.Palette:ColorCode("source.QUEST") end,
    single     = function() return HDG.Theme:ColorCode("text.dim") end,
    treasure   = function() return HDG.Palette:ColorCode("source.TREASURE") end,
    repeatable = function() return HDG.Theme:ColorCode("semantic.warning") end,
}
local function _chipText(kind, label) return KIND_COLOR[kind]() .. "[" .. label .. "]|r" end

-- Progress state -> its text color: done green, under way gold, done but not owned red,
-- the rest dim.
local function _stateText(state, text)
    if state == "done" then return HDG.Theme:StateLabel("success", text) end
    if state == "progress" then return HDG.Theme:StateLabel("warning", text) end
    if state == "missing" then return HDG.Theme:StateLabel("error", text) end
    return _dim(text)
end

-- Faction badge: the side's letter in its brand color (Palette faction.*).
local SIDE_TOKEN = { A = "faction.Alliance", H = "faction.Horde" }
local function _sideText(side) return HDG.Palette:ColorCode(SIDE_TOKEN[side]) .. side .. "|r" end

local function _resetTexts(row, keys)
    for _, k in ipairs(keys) do
        local fs = row[k]
        fs:SetText("")
        fs:ClearAllPoints()
        fs:SetWidth(0)
        fs:SetWordWrap(false)
        fs:SetJustifyV("MIDDLE")
    end
end

local function _showIcon(tex, size, texture)
    tex:SetSize(size, size)
    HDG.UI.PaintIcon(tex, nil, texture, HDG.Constants.PLACEHOLDER_ICON)
    tex:SetTexCoord(unpack(HDG.Constants.ICON_CROP))
    tex:Show()
end

local function _dispatch(action, payload)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS[action], payload = payload })
end

-- A row's hover tip: _tip, set by its paint and cleared by its reset (the mockup's titles).
local function _rowTip(self)
    if self._tip then return { title = self._tip } end
    return nil   -- exception(nullable): most rows have no tip
end

-- ===== List rows ===========================================================

local LIST_HEIGHT = { group = 24, decor = 36, chain = 36 }
local LIST_TEXTS = { "_caret", "_name", "_state", "_chip", "_where" }
local LIST_ICON, LIST_TEXT_X = 28, 40
local LIST_BAR_W, LIST_BAR_H = 64, 5
local CHAIN_ICON = 14   -- a chain row's decor icons, inline
local REWARD_ICON = 12  -- a reward line's decor icon, inline

local function _listRowHeight(_index, ed) return LIST_HEIGHT[ed.kind] end

-- A progress bar: green once done, gold while under way, as the "3/9 steps" beside it
-- (review C3). The bar is the shared HDG.UI:ProgressBar.
local BAR_STATE = { [true] = { variant = "success" }, [false] = { variant = "warning" } }

local function _fillBar(bar, frac)
    bar:SetVariant(BAR_STATE[frac >= 1])
    bar:SetProgress(frac)
    bar:Show()
end

local function _layoutListRow(row)
    row._icon  = HDG.UI.MakeCellIcon(row, LIST_ICON)
    row._caret = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
    row._name  = HDG.UI.RowText(row, "body", "Text", "LEFT")
    row._state = HDG.UI.RowText(row, "caption", "Text", "RIGHT")
    row._chip  = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    row._where = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    row._bar   = HDG.UI:ProgressBar(row)
    row._bar:SetSize(LIST_BAR_W, LIST_BAR_H)
    HDG.TooltipEngine:Attach(row, _rowTip)
end

local function _resetListRow(row)
    _resetTexts(row, LIST_TEXTS)
    row._icon:Hide()
    row._icon:ClearAllPoints()
    row._bar:Hide()
    row._bar:ClearAllPoints()
    row._ed, row._tip = nil, nil
end

local function _paintGroup(row, ed)
    HDG.Theme:Register(row, "RowChrome", { header = true })
    local color = ed.color or HDG.Theme:ColorCode("semantic.accent")   -- exception(optional): Unknown and the hunts have no expansion color
    row._caret:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._caret:SetText(HDG.UI.CollapsePrefix(ed.collapsed))
    row._name:SetPoint("LEFT", row._caret, "RIGHT", 4, 0)
    row._name:SetText(color .. ed.label .. "|r")
    row._state:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._state:SetText(_dim(ed.count))
end

-- Line 2 from x: a lead (the kind chip, a chain's decor icons), where ... and the
-- steps bar at the far end when the row has one.
local function _paintLine2(row, ed, x, lead)
    row._chip:SetPoint("TOPLEFT", row, "TOPLEFT", x, -19)
    row._chip:SetText(lead)
    row._where:SetPoint("TOPLEFT", row._chip, "TOPRIGHT", 6, 0)
    row._where:SetText(ed.where)
    if not ed.frac then   -- exception(optional): a lone quest, and the other faction's decor and chains, carry no bar
        row._where:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -19)
        return
    end
    row._bar:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -23)
    _fillBar(row._bar, ed.frac)
    row._where:SetPoint("TOPRIGHT", row._bar, "TOPLEFT", -6, 4)
end

-- Line 1: name (and the other faction's letter) ... collected check, state.
local function _paintDecor(row, ed)
    HDG.UI.PaintRowChrome(row, ed.selected)
    row._icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    _showIcon(row._icon, LIST_ICON, ed.icon)
    local got = ed.got and (CHECK .. " ") or ""
    if ed.got then row._tip = L("DQ_GOT_TIP") end
    row._state:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
    row._state:SetText(got .. _stateText(ed.state, ed.stateText))
    row._name:SetPoint("TOPLEFT", row, "TOPLEFT", LIST_TEXT_X, -4)
    row._name:SetPoint("TOPRIGHT", row._state, "TOPLEFT", -6, 0)
    row._name:SetText(ed.badge and (ed.name .. "  " .. _sideText(ed.badge)) or ed.name)   -- exception(optional): only other-faction decor carry a badge
    _paintLine2(row, ed, LIST_TEXT_X, _chipText(ed.chipKind, ed.chipLabel))
end

-- Inline icon markup, cropped as the cell icons are.
local _iconMarkup = HDG.Format.IconMarkup

local function _chainIcons(icons)
    local parts = {}
    for i, icon in ipairs(icons) do parts[i] = _iconMarkup(icon, CHAIN_ICON) end
    return table.concat(parts, " ")
end

-- A chain: name ... state, then its decor's icons, "<n> decor - <where>" ... its bar.
local function _paintChain(row, ed)
    HDG.UI.PaintRowChrome(row, ed.selected)
    row._state:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
    row._state:SetText(_stateText(ed.state, ed.stateText))
    row._name:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
    row._name:SetPoint("TOPRIGHT", row._state, "TOPLEFT", -6, 0)
    row._name:SetText(ed.name)
    _paintLine2(row, ed, 8, _chainIcons(ed.icons))
end

-- A list row's key, which is also what session.ui.decorQuests.selected holds for it.
local function _listKey(ed)
    if ed.kind == "decor" then return "d:" .. ed.decorID end
    return ed.key   -- groups "E:<expansion>" / "C:<expansion>" / "single" / "treasure", chains "L:<lineID>" / "camp:<id>"
end

local function _toggleGroup(ed) _dispatch("DQ_TOGGLE_GROUP", { key = ed.key }) end
local function _selectDecor(ed)
    -- Shift-click links the decor in chat, as the other item lists do.
    if IsShiftKeyDown() then HDG.UI.LinkItem(ed.itemID) return end
    CH.Mechanics.SetUITransientView(VIEW, "selected", _listKey(ed))
end
local function _selectChain(ed) CH.Mechanics.SetUITransientView(VIEW, "selected", ed.key) end

local LIST_PAINT = { group = _paintGroup, decor = _paintDecor, chain = _paintChain }
local LIST_CLICK = { group = _toggleGroup, decor = _selectDecor, chain = _selectChain }

local function _onListRowClick(self) LIST_CLICK[self._ed.kind](self._ed) end

local function _wireListRow(row, ed)
    row._ed = ed
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", _onListRowClick)
end

local function _listRowFactory(_template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_dqListLaidOut", _layoutListRow)
            _resetListRow(row)
            LIST_PAINT[ed.kind](row, ed)
            row:SetHeight(_listRowHeight(nil, ed))
            _wireListRow(row, ed)
        end,
        Reset = function(row)
            row:SetScript("OnClick", nil)
            _resetListRow(row)
        end,
    }
end

HDG.Rows:Register("decorQuestsListRow", {
    font    = "body",
    height  = _listRowHeight,
    factory = _listRowFactory,
    key     = _listKey,
})

-- ===== Detail rows =========================================================

local DETAIL_HEIGHT = { info = 56, section = 24, bar = 12, fold = 20, quest = 64, blank = 60,
                        decorLine = 22, part = 22, chapter = 22, track = 22, alt = 22, boxHead = 18 }
local WAY_W, WPT_W, MAP_W = 84, 44, 44
local TRACK_W = WAY_W   -- Track at the head's top right, as wide as the Next block's button under it (review C9)
-- Every detail button is 16 tall, the height of a who line it sits on.
local BTN_H = 16
local PIN_RIGHT = -(6 + WPT_W / 2 - 7)   -- a step's 14 px waypoint pin, centred in the Arrow's column
local LINE_HEIGHT, LINE_PAD = 14, 6
local STEP_TITLE_H = 16
local DETAIL_TEXTS = { "_num", "_mark", "_main", "_sub", "_third", "_right" }
local INFO_ICON = 44
-- The Next block's text inside its box (the reward box's edge, 2 + 1 in) and padding; its
-- widths are HDG.Constants.DQ_DETAIL_TEXT's, the selectors measure its lines at them.
local NEXT_X, NEXT_TOP, NEXT_GAP = 10, 6, 3
local NEXT_RIGHT = -6   -- "step N of M" and the button end under Track (TRACK_W), however wide the panel is
local DT = HDG.Constants.DQ_DETAIL_TEXT
local STEP_NUM_W, STEP_MARK_X, STEP_TEXT_X = 22, 30, 46   -- number, mark, title columns
local STEP_TIP = { todo = "DQ_STEP_TIP", done = "DQ_STEP_TIP_AGAIN", warband = "DQ_STEP_TIP_WARBAND" }   -- a pickable step's hover, by its cat
local BOX_BAR_X, BOX_BAR_W = 27, 2                          -- an any-order box's bar, between number and mark
local LINE_ICON = 16                                        -- a decorLine's icon
local PIE_SIZE, CHAPTER_TEXT_X = 12, 26                     -- a chapter's mark, then its name

-- The who line wraps (whoLines, measured by the selectors; 0 with nobody and no zone known).
local function _stepHeight(ed)
    local h = LINE_PAD + STEP_TITLE_H + DT.body * ed.whoLines
    if ed.rewards then h = h + LINE_HEIGHT * #ed.rewards end   -- exception(optional): only a decor quest's step rewards
    return h
end

-- A chapter that ends a decor names it on a second line.
local function _chapterHeight(ed)
    if ed.chips then return DETAIL_HEIGHT.chapter + LINE_HEIGHT + 2 end   -- exception(optional): most chapters end no decor
    return DETAIL_HEIGHT.chapter
end

-- A quest row without a note (a single quest, not a treasure hunt) drops the note's line; its
-- who line keeps one line (the Wpt sits on it) and grows as it wraps.
local function _questHeight(ed)
    local h = DETAIL_HEIGHT.quest + DT.body * math.max(ed.whoLines, 1) - LINE_HEIGHT
    if ed.note then return h end   -- exception(optional): only a treasure hunt carries a note
    return h - LINE_HEIGHT - LINE_PAD
end

-- The box: its Next line, the lines down to the button's (at least the button's height), the
-- rest, each part as many lines as the selectors measured.
local function _nextHeight(ed)
    local h = NEXT_TOP * 2 + DT.subheading * ed.lineLines
    if ed.upperLines > 0 then h = h + NEXT_GAP + math.max(DT.body * ed.upperLines, BTN_H) end
    if ed.lowerLines > 0 then h = h + NEXT_GAP + DT.body * ed.lowerLines end
    return h
end

local function _detailRowHeight(_index, ed)
    if ed.kind == "note" then return LINE_PAD + LINE_HEIGHT * ed.lines end
    if ed.kind == "missing" then return LINE_PAD * 2 + LINE_HEIGHT * (ed.lines + 1) end
    if ed.kind == "step" then return _stepHeight(ed) end
    if ed.kind == "quest" then return _questHeight(ed) end
    if ed.kind == "chapter" then return _chapterHeight(ed) end
    if ed.kind == "next" then return _nextHeight(ed) end
    return DETAIL_HEIGHT[ed.kind]
end

-- A reward step's box (the mockup's): an edge, its face inset a pixel, over the row's zebra
-- (-3) and under its selected wash (1), which still shows over it.
local function _makeRewardBox(row)
    row._rewardEdge = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    row._rewardEdge:SetPoint("TOPLEFT", 2, -1)
    row._rewardEdge:SetPoint("BOTTOMRIGHT", -2, 1)
    HDG.UI.RoundedFill(row._rewardEdge)
    HDG.UI.ToneTexture(row._rewardEdge, "border.default")
    row._rewardFace = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row._rewardFace:SetPoint("TOPLEFT", row._rewardEdge, "TOPLEFT", 1, -1)
    row._rewardFace:SetPoint("BOTTOMRIGHT", row._rewardEdge, "BOTTOMRIGHT", -1, 1)
    HDG.UI.RoundedFill(row._rewardFace)
    HDG.UI.ToneTexture(row._rewardFace, "surface.panel")
end

local function _layoutDetailRow(row)
    row._icon  = HDG.UI.MakeCellIcon(row, INFO_ICON)
    row._num   = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    row._mark  = HDG.UI.RowText(row, "caption", "Text", "CENTER")
    row._main  = HDG.UI.RowText(row, "body", "Text", "LEFT")
    row._sub   = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    row._third = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    row._right = HDG.UI.RowText(row, "caption", "Text", "RIGHT")
    row._bar   = HDG.UI:ProgressBar(row)
    row._pie   = HDG.UI:Pie(row, PIE_SIZE)
    row._track = HDG.UI.RowButton(row, "", TRACK_W, BTN_H)
    row._track:RegisterForClicks("LeftButtonUp")
    row._way = HDG.UI.RowButton(row, "", WAY_W, BTN_H)
    row._way:RegisterForClicks("LeftButtonUp")
    row._wpt = HDG.UI.RowButton(row, "", WPT_W, BTN_H)
    row._wpt:RegisterForClicks("LeftButtonUp")
    row._map = HDG.UI.RowButton(row, L("DQ_MAP"), MAP_W, BTN_H)
    row._map:RegisterForClicks("LeftButtonUp")
    row._pin = HDG.UI.RowPinButton(row)   -- a step's own waypoint, as Zone's and Shopping's rows (review C8)
    row._pin:ClearAllPoints()   -- _paintWpt places it
    HDG.TooltipEngine:Attach(row, _rowTip)
    row._boxBar = row:CreateTexture(nil, "ARTWORK", nil, 2)   -- over the row chrome's ARTWORK
    row._boxBar:SetTexture("Interface\\Buttons\\WHITE8X8")   -- a white base: ToneTexture tints it from the scheme
    row._boxBar:SetWidth(BOX_BAR_W)
    _makeRewardBox(row)
end

local function _resetDetailRow(row)
    _resetTexts(row, DETAIL_TEXTS)
    HDG.UI.applyFontRole(row._main, "body")
    HDG.UI.applyFontRole(row._sub, "caption")     -- a who line and the Next block paint in body
    HDG.UI.applyFontRole(row._third, "caption")
    row._main:SetJustifyH("LEFT")   -- the blank row centres it
    row._icon:Hide()
    row._icon:ClearAllPoints()
    row._bar:Hide()
    row._bar:ClearAllPoints()
    row._pie:Hide()
    row._pie:ClearAllPoints()
    row._boxBar:Hide()
    row._boxBar:ClearAllPoints()
    row._rewardEdge:Hide()
    row._rewardFace:Hide()
    for _, b in ipairs({ row._track, row._way, row._wpt, row._map, row._pin }) do
        b:Hide()
        b:ClearAllPoints()
        b:SetScript("OnClick", nil)
    end
    HDG.UI.SetEnabledLook(row._way, true)
    HDG.UI.SetEnabledLook(row._map, true)
    row._ed, row._tip = nil, nil
end

-- ----- Track -----
-- A Track button follows its { key, quest, on, rows } in the Quest Tracker; Tracking stops
-- it and closes the tracker, as the tracker's Stop tracking does (one way to stop, R1 10-29).

local function _onTrack(self) CH.Mechanics.TrackDecorQuests(self._trackSpec) end

local function _trackTip(self)
    local t = self._trackSpec
    return { title = (t.on and L("DQ_TRACK_STOP_TIP")) or (t.again and L("DQ_TRACK_AGAIN_TIP")) or t.tip }
end

-- At the row's top right (y down from the top); returns the button, for the text to stop short of.
local function _paintTrack(row, track, y)
    local b = row._track
    b._trackSpec = track
    b:SetText(track.on and HDG.Theme:ColorCode("semantic.accent") .. L("DQ_TRACKING") .. "|r" or L("DQ_TRACK"))
    b:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, y)
    b:SetScript("OnClick", _onTrack)
    HDG.TooltipEngine:Attach(b, _trackTip)
    b:Show()
    return b
end

-- ----- Waypoint -----
-- A step's own way there (decorQuests' _questWay): Blizzard's arrow on a quest in the log,
-- else a waypoint at its start.

local function _onWay(self) HDG.Waypoints:FollowQuestStep(self._waySpec) end

local function _wayTip(self)
    return { title = L(self._waySpec.questID and "DQ_ARROW_TIP" or "DQ_WAY_TIP"):format(self._waySpec.title) }
end

-- ----- The Next block's button -----
-- The tracker's one button for the step to head for (decorQuests' _stepWay), and the
-- tracker's Map: the waypoint and the world map open on it with the step's numbered pin, in
-- one click (HDG.Waypoints:SetAndShow; the tracker's exception, widened to this block, owner
-- 10-30). Arrow for a step in the log; greyed when no spot is known, its tip saying why.

local function _onNextMap(self)
    local w = self._waySpec
    HDG.Waypoints:SetAndShow(w.map, w.x, w.y, w.title, w.num, w.side)
end

local function _nextWayTip(self)
    local w = self._waySpec
    if not w.enabled then return { title = w.why } end
    return { title = L(w.questID and "DQ_ARROW_TIP" or "DQ_MAP_TIP"):format(w.title) }
end

local function _paintNextWay(row, way)
    local b = row._way
    b._waySpec = way
    b:SetText(L(way.questID and "DQ_STEP_ARROW" or "DQ_MAP"))
    if way.enabled then   -- exception(optional): a step with no known spot only explains itself
        b:SetScript("OnClick", way.questID and _onWay or _onNextMap)
    end
    HDG.UI.SetEnabledLook(b, way.enabled)
    HDG.TooltipEngine:Attach(b, _nextWayTip)
    b:Show()
    return b
end

-- A step's or a lone quest's own way there (decorQuests' _questWay): HDG's row waypoint pin
-- at the spot it starts at (review C8), Arrow once it is in the log. At the row's right, y
-- down from the top, the pin centred in the Arrow's column; returns the button, for the text
-- to stop short of, or nil when the row has no way.
local function _paintWpt(row, way, y)
    if not way then return nil end   -- exception(optional): a step done here, or one with no known spot
    local b = way.questID and row._wpt or row._pin
    b._waySpec = way
    if way.questID then
        b:SetText(L("DQ_STEP_ARROW"))
        b:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, y)
    else
        b:SetPoint("TOPRIGHT", row, "TOPRIGHT", PIN_RIGHT, y - 1)
    end
    b:SetScript("OnClick", _onWay)
    HDG.TooltipEngine:Attach(b, _wayTip)
    b:Show()
    return b
end

-- ----- info -----

-- "Done" / "3/12 steps", and once collected "collected, first done by <character>".
local function _infoState(ed)
    local text = _chipText(ed.chipKind, ed.chipLabel) .. "  " .. _stateText(ed.state, ed.stateText)
    if not ed.collected then return text end
    text = text .. "  " .. CHECK .. " " .. HDG.Theme:StateLabel("success", L("DQ_COLLECTED"))
    if not ed.firstBy then return text end   -- exception(optional): no character recorded the quest yet
    return text .. _dim(L("DQ_FIRST_DONE_BY")) .. HDG.Theme:ClassName(ed.firstBy.name, ed.firstBy.class)
end

local function _paintInfo(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._icon:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -5)
    _showIcon(row._icon, INFO_ICON, ed.icon)
    HDG.UI.applyFontRole(row._main, "subheading")
    row._main:SetPoint("TOPLEFT", row._icon, "TOPRIGHT", 8, 0)
    if ed.track then   -- exception(optional): the other faction's decor has no Track
        row._main:SetPoint("TOPRIGHT", _paintTrack(row, ed.track, -4), "TOPLEFT", -6, 0)
    else
        row._main:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -4)
    end
    row._sub:SetPoint("TOPLEFT", row._main, "BOTTOMLEFT", 0, -3)
    row._sub:SetPoint("TOPRIGHT", row._main, "BOTTOMRIGHT", 0, -3)
    row._third:SetPoint("TOPLEFT", row._sub, "BOTTOMLEFT", 0, -3)
    row._third:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._main:SetText(ed.name)
    row._sub:SetText(ed.zone)
    row._third:SetText(_infoState(ed))
end

-- ----- note, section, bar -----

-- A line in parts, runs = { { tone, text }, ... } (the tracker's): each in its tone. Lines
-- of them, "\n" between.
local _runsText = HDG.UI.RunsText

local function _linesText(runsList)
    local out = {}
    for i, runs in ipairs(runsList) do out[i] = _runsText(runs) end
    return table.concat(out, "\n")
end

local function _paintNote(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    local fs = row._sub
    fs:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
    fs:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -3)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    local text = HDG.UI.Toned(ed.tone, ed.text)
    if ed.lead then text = HDG.UI.Toned("text", ed.lead) .. "\n" .. text end   -- exception(optional): only the progress note leads with its status (review C5)
    fs:SetText(text)
end

local function _paintSection(row, ed)
    HDG.Theme:Register(row, "RowChrome", { header = true })
    row._main:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._main:SetText(HDG.Theme:ColorCode("semantic.accent") .. ed.label .. "|r")
    row._sub:SetPoint("LEFT", row._main, "RIGHT", 8, 0)
    if ed.track then   -- exception(optional): only a chain's and a campaign's head carry Track
        row._sub:SetPoint("RIGHT", _paintTrack(row, ed.track, -4), "LEFT", -6, 0)
    else
        row._sub:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    end
    row._sub:SetText(ed.sub)
end

-- An opened chapter's Track, over its quests, labelled: the campaign head has one too (review F6).
local function _paintTrackRow(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._main:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._main:SetPoint("RIGHT", _paintTrack(row, ed.track, -3), "LEFT", -6, 0)
    row._main:SetText(_dim(ed.label))
end

local function _paintBar(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._bar:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
    row._bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 3)
    _fillBar(row._bar, ed.frac)
end

-- ----- next -----
-- The Next block (decorQuests' Place.detailNext), in the reward box: the Next line ("step N of
-- M" at its right), the lines down to the button's, the button beside the last of them (on
-- the Next line when no place line is known), then the rest. Each text as wide as the
-- selectors measured it (DQ_DETAIL_TEXT), so it wraps where they counted; "step N of M" and
-- the button end at the row's right, under Track (in game 10-30 the measured widths left
-- them short of the box's edge, stacked tight).

local function _nextText(fs, above, w, text)
    HDG.UI.applyFontRole(fs, "body")
    fs:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -NEXT_GAP)
    fs:SetWidth(w)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    fs:SetText(text)
end

local function _paintNextLine(row, ed)
    HDG.UI.applyFontRole(row._main, "subheading")
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", NEXT_X, -NEXT_TOP)
    row._main:SetWidth(ed.lineW)
    row._main:SetWordWrap(true)
    row._main:SetJustifyV("TOP")
    row._main:SetText(_runsText(ed.line))
    if not ed.step then return end   -- exception(optional): a lone quest has no step count
    -- Caption, on the subheading's first line; left of the button when the button rides the line.
    local x = NEXT_RIGHT - (ed.upperLines == 0 and DT.way or 0)
    row._right:SetPoint("TOPRIGHT", row, "TOPRIGHT", x, -(NEXT_TOP + 3))
    row._right:SetWidth(DT.stepOf)
    row._right:SetText(HDG.UI.Toned("text", ed.step))
end

-- The button's top: centred on the last place line, or on the Next line when there is none.
local function _nextWayY(ed)
    if ed.upperLines == 0 then return NEXT_TOP + (DT.subheading - BTN_H) / 2 end
    local lastLine = NEXT_TOP + DT.subheading * ed.lineLines + NEXT_GAP + DT.body * (ed.upperLines - 1)
    return lastLine + (DT.body - BTN_H) / 2
end

local function _paintNext(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._rewardEdge:Show()   -- the box: the reward box's edge and face
    row._rewardFace:Show()
    _paintNextLine(row, ed)
    local above = row._main
    if ed.upperLines > 0 then
        _nextText(row._sub, above, DT.next - DT.way, _linesText(ed.upper))
        above = row._sub
    end
    if ed.lowerLines > 0 then _nextText(row._third, above, DT.next, _linesText(ed.lower)) end
    _paintNextWay(row, ed.way):SetPoint("TOPRIGHT", row, "TOPRIGHT", NEXT_RIGHT, -_nextWayY(ed))
end

-- ----- step, fold -----

-- The mark column: done here, done by another character of the warband (the quest log's
-- own mark), the step to head for in accent (the tracker's colour for it, review C1); still
-- to do, an empty pie -- the chapters' and the tracker's circle (review C7).
local function _markText(ed)
    if ed.cat == "done" then return CHECK end
    if ed.cat == "warband" then return HDG.Constants.DQ_WARBAND_ICON end
    if ed.isCur then return HDG.Theme:ColorCode("semantic.accent") .. ">|r" end
    return nil
end

local function _paintStepMark(row, ed)
    local text = _markText(ed)
    if text then   -- exception(nullable): a step still to do draws its pie instead
        row._mark:SetPoint("TOPLEFT", row, "TOPLEFT", STEP_MARK_X, -4)
        row._mark:SetText(text)
        return
    end
    row._pie:SetPoint("TOPLEFT", row, "TOPLEFT", STEP_MARK_X + 2, -5)
    row._pie:SetFraction(0)
    row._pie:Show()
end

-- The title: the accent on the step to head for, dim once anyone in the warband did it.
local function _stepTitle(ed)
    if ed.isCur then return HDG.Theme:ColorCode("semantic.accent") .. ed.title .. "|r" end
    if ed.cat ~= "todo" then return _dim(ed.title) end
    return ed.title
end

-- Its tags, which stay beside the button while a long title gives way (review C6): lead-in,
-- Next (accent), In your log (gold, the tracker's colour for it, review C1).
local function _stepTags(ed)
    local tags = {}
    if ed.leadIn then tags[#tags + 1] = _dim("[" .. L("DQ_LEAD_IN") .. "]") end
    if ed.isCur then tags[#tags + 1] = HDG.Theme:ColorCode("semantic.accent") .. "[" .. L("DQ_NEXT") .. "]|r" end
    if ed.inLog then tags[#tags + 1] = HDG.Theme:ColorCode("semantic.warning") .. "[" .. L("DQ_IN_LOG") .. "]|r" end
    return table.concat(tags, "  ")
end

-- Title and tags on the first line: the tags beside the button (or the row's edge), the
-- title up to them.
local function _paintStepTitle(row, ed, wpt)
    if wpt then
        row._right:SetPoint("RIGHT", wpt, "LEFT", -6, 0)
    else
        row._right:SetPoint("RIGHT", row, "TOPRIGHT", -6, -10)
    end
    local tags = _stepTags(ed)
    row._right:SetText(tags)
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", STEP_TEXT_X, -3)
    row._main:SetPoint("TOPRIGHT", row._right, "TOPLEFT", tags == "" and 0 or -6, 0)
    row._main:SetText(_stepTitle(ed))
end

local function _onPickStep(self)
    local ed = self._ed
    _dispatch("DQ_PICK_STEP", { key = ed.pickKey, quest = ed.pick, tracked = ed.tracked })
end

-- A reward line per decor the step's quest gives, led by the decor's icon (a check read as
-- collected when it was not, 10-28).
local function _rewardLines(rewards)
    local lines = {}
    for i, r in ipairs(rewards) do
        lines[i] = _iconMarkup(r.icon, REWARD_ICON) .. " " .. HDG.Theme:StateLabel(r.got and "success" or "warning", r.text)   -- gold until collected (review C2)
    end
    return table.concat(lines, "\n")
end

-- A who line (the tracker's runs, Bold B: "! giver  ? NPC - zone") under above, in body, as
-- wide as the selectors measured it (DQ_DETAIL_TEXT.step), so it wraps where they counted;
-- empty with nobody and no zone known.
local function _paintWho(row, above, who)
    local fs = row._sub
    HDG.UI.applyFontRole(fs, "body")
    fs:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -2)
    fs:SetWidth(DT.step)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    if who then fs:SetText(_runsText(who)) end   -- exception(optional): nobody and no zone known
    return fs
end

-- Who and reward lines stack under the title, each only when the step has one.
local function _paintStepLines(row, ed)
    local below = ed.who and _paintWho(row, row._main, ed.who) or row._main   -- exception(optional): nobody and no zone known
    if not ed.rewards then return end   -- exception(optional): only a decor quest's step rewards
    row._third:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -2)
    row._third:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._third:SetWordWrap(true)   -- a quest that rewards two decor: a line each
    row._third:SetJustifyV("TOP")
    row._third:SetText(_rewardLines(ed.rewards))
end

-- An any-order box's bar down the rows it holds: from the head's middle, through each step,
-- to just short of the last step's foot. Accent while the step to head for is in the box,
-- else neutral -- the tracker's box edge's rule (ruling R6, review C4).
local BOX_TONE = { [true] = { bar = "semantic.accent", head = "semantic.accent" },
                   [false] = { bar = "border.default", head = "text.dim" } }

local function _paintBoxBar(row, top, bottom, on)
    row._boxBar:SetPoint("TOPLEFT", row, "TOPLEFT", BOX_BAR_X, -top)
    row._boxBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", BOX_BAR_X, bottom)
    HDG.UI.ToneTexture(row._boxBar, BOX_TONE[on].bar)
    row._boxBar:Show()
end

local function _paintBoxHead(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    HDG.UI.applyFontRole(row._main, "caption")
    row._main:SetPoint("LEFT", row, "LEFT", STEP_MARK_X, 0)
    row._main:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._main:SetText(HDG.Theme:ColorCode(BOX_TONE[ed.on].head) .. ed.text .. "|r")
    _paintBoxBar(row, DETAIL_HEIGHT.boxHead / 2, 0, ed.on)
end

local function _paintStep(row, ed)
    HDG.UI.PaintRowChrome(row, ed.isCur)   -- the step to head for reads selected (the mockup's)
    if ed.rewards then   -- exception(optional): only a decor quest's step rewards
        row._rewardEdge:Show()
        row._rewardFace:Show()
    end
    if ed.box then _paintBoxBar(row, 0, ed.box == "last" and 4 or 0, ed.boxOn) end   -- exception(optional): most steps are in no box
    row._num:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
    row._num:SetWidth(STEP_NUM_W)
    row._num:SetText(tostring(ed.num))
    _paintStepMark(row, ed)
    _paintStepTitle(row, ed, _paintWpt(row, ed.way, -2))
    _paintStepLines(row, ed)
    if not ed.pick then return end   -- exception(optional): the step to head for picks nothing
    row._ed, row._tip = ed, L(STEP_TIP[ed.cat])
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", _onPickStep)
end

local function _onOpenFold(self) _dispatch("DQ_OPEN_FOLD", { key = self._ed.foldKey }) end

local function _paintFold(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._main:SetPoint("LEFT", row, "LEFT", STEP_TEXT_X, 0)
    row._main:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._main:SetText(_dim(HDG.UI.CollapsePrefix(true) .. ed.text))
    row._ed = ed
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", _onOpenFold)
end

-- ----- quest, blank -----

local function _paintQuest(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._right:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
    row._right:SetText(_stateText(ed.state, ed.stateText))
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
    row._main:SetPoint("TOPRIGHT", row._right, "TOPLEFT", -6, 0)
    row._main:SetText(ed.title)
    _paintWpt(row, ed.way, -20)   -- on the who line, under the state
    _paintWho(row, row._main, ed.who)
    row._third:SetPoint("TOPLEFT", row._sub, "BOTTOMLEFT", 0, -4)
    row._third:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._third:SetWordWrap(true)
    row._third:SetText(ed.note and _dim(ed.note) or "")   -- exception(optional): only a treasure hunt carries a note
end

local function _paintBlank(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -20)
    row._main:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -20)
    row._main:SetJustifyH("CENTER")
    row._main:SetWordWrap(true)   -- By Chain's prompt runs past one line
    row._main:SetText(_dim(ed.text))
end

-- ----- By Chain: decorLine, part, chapter -----

-- A chain's or a campaign's decor: icon, name ... where it stands (and collected).
local function _paintDecorLine(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    _showIcon(row._icon, LINE_ICON, ed.icon)
    local got = ed.got and (CHECK .. " ") or ""
    row._right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._right:SetText(got .. _stateText(ed.state, ed.stateText))
    row._main:SetPoint("LEFT", row._icon, "RIGHT", 6, 0)
    row._main:SetPoint("RIGHT", row._right, "LEFT", -6, 0)
    row._main:SetText(ed.name)
end

-- A campaign's part: "Chapters  any order" ... how many are done.
local function _paintPart(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._main:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._main:SetText(ed.label)
    row._right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._right:SetText(_stateText(ed.state, ed.stateText))
    row._sub:SetPoint("LEFT", row._main, "RIGHT", 8, 0)
    row._sub:SetPoint("RIGHT", row._right, "LEFT", -6, 0)
    row._sub:SetText(ed.sub)
end

-- The chapter's mark: a check once done, else a pie of its steps done.
local function _paintChapterMark(row, ed)
    if ed.state == "done" then
        row._mark:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
        row._mark:SetText(CHECK)
        return
    end
    row._pie:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -5)
    row._pie:SetFraction(ed.frac)
    row._pie:Show()
end

-- The decor a chapter ends: icon and name, dim until collected.
local function _chipsText(chips)
    local parts = {}
    for i, c in ipairs(chips) do
        local name = c.got and (HDG.Theme:StateLabel("success", c.name) .. " " .. CHECK) or HDG.Theme:StateLabel("warning", c.name)
        parts[i] = _iconMarkup(c.icon, CHAIN_ICON) .. " " .. name
    end
    return table.concat(parts, "   ")
end

local function _onToggleChapter(self) _dispatch("DQ_TOGGLE_CHAPTER", { lineID = self._ed.lineID }) end

-- A chapter: mark, caret and name ... n/N; the decor it ends under. The selected
-- decor's own chapter reads selected; a click opens its quests.
local function _paintChapter(row, ed)
    HDG.UI.PaintRowChrome(row, ed.here)
    _paintChapterMark(row, ed)
    row._right:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
    row._right:SetText(_stateText(ed.state, ed.value))
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", CHAPTER_TEXT_X, -3)
    row._main:SetPoint("TOPRIGHT", row._right, "TOPLEFT", -6, 0)
    row._main:SetText(_dim(HDG.UI.CollapsePrefix(not ed.open)) .. ed.name)
    if ed.chips then   -- exception(optional): most chapters end no decor
        row._sub:SetPoint("TOPLEFT", row._main, "BOTTOMLEFT", 0, -2)
        row._sub:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row._sub:SetText(_chipsText(ed.chips))
    end
    row._ed, row._tip = ed, L(ed.open and "DQ_CHAPTER_HIDE_TIP" or "DQ_CHAPTER_SHOW_TIP")
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", _onToggleChapter)
end

-- ----- missing, alt -----

local function _onMissingWaypoint(self)
    local p = self._place
    HDG.Waypoints:Set(p.mapID, p.x, p.y, p.name, p.side)
end
local function _missingTip(self) return { title = L("DQ_MISSING_WAY_TIP"):format(self._place.name) } end
local function _onMissingMap(self)
    local p = self._place
    HDG.Waypoints:ShowOnMap(p.mapID, p.x, p.y, p.name)
end
local function _missingMapTip(self) return { title = L("VENDOR_MAP_TIP"):format(self._place.name) } end

-- Map beside the card's Waypoint (owner 10-30: a Map beside every Waypoint).
local function _paintMissingMap(row, place, beside)
    local m = row._map
    m._place = place
    m:SetPoint("RIGHT", beside, "LEFT", -4, 0)
    m:SetScript("OnClick", _onMissingMap)
    HDG.TooltipEngine:Attach(m, _missingMapTip)
    m:Show()
    return m
end

-- Quest done: decor not owned (why, and who sells it) or owned (who sells more), with a
-- Waypoint when the vendor has a spot.
local function _paintMissing(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -LINE_PAD)
    row._main:SetText(HDG.Theme:StateLabel(ed.titleTone, ed.title))
    row._sub:SetPoint("TOPLEFT", row._main, "BOTTOMLEFT", 0, -2)
    row._sub:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._sub:SetWordWrap(true)
    row._sub:SetJustifyV("TOP")
    row._sub:SetText(ed.text)
    if not ed.place then return end   -- exception(optional): a vendor with no spot, or none at all
    local b = row._track
    b._place = ed.place
    b:SetText(L("DQ_TRK_WAY"))
    b:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -LINE_PAD + 2)
    b:SetScript("OnClick", _onMissingWaypoint)
    HDG.TooltipEngine:Attach(b, _missingTip)
    b:Show()
    row._main:SetPoint("RIGHT", _paintMissingMap(row, ed.place, b), "LEFT", -6, 0)
end

-- A character: name in its class colour ... what it did of this decor, and when it was read.
local function _paintAlt(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._right:SetText(ed.text .. "  " .. _dim(ed.when))
    local nameEnd = row._right
    if ed.frac then   -- exception(optional): only this character's row draws a bar (the mockup's)
        row._bar:SetSize(LIST_BAR_W, LIST_BAR_H)
        row._bar:SetPoint("RIGHT", row._right, "LEFT", -8, 0)
        _fillBar(row._bar, ed.frac)
        nameEnd = row._bar
    end
    row._main:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._main:SetPoint("RIGHT", nameEnd, "LEFT", -6, 0)
    row._main:SetText(HDG.Theme:ClassName(ed.name, ed.classFile))
end

local DETAIL_PAINT = {
    info = _paintInfo, next = _paintNext, note = _paintNote, section = _paintSection, bar = _paintBar,
    step = _paintStep, fold = _paintFold, quest = _paintQuest, blank = _paintBlank, boxHead = _paintBoxHead,
    decorLine = _paintDecorLine, part = _paintPart, chapter = _paintChapter, track = _paintTrackRow,
    missing = _paintMissing, alt = _paintAlt,
}

local function _detailRowFactory(_template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_dqDetailLaidOut", _layoutDetailRow)
            row:SetScript("OnClick", nil)
            _resetDetailRow(row)
            DETAIL_PAINT[ed.kind](row, ed)
            row:SetHeight(_detailRowHeight(nil, ed))
        end,
        Reset = function(row)
            row:SetScript("OnClick", nil)
            _resetDetailRow(row)
        end,
    }
end

HDG.Rows:Register("decorQuestsDetailRow", {
    font    = "body",
    height  = _detailRowHeight,
    factory = _detailRowFactory,
    key     = function(ed) return ed.key end,
})

-- ===== Controller wiring ===================================================

local function _setView(key, value)
    return function() CH.Mechanics.SetUITransientView(VIEW, key, value) end
end

local function _toggleHideCollected()
    local on = HDG.Selectors:Call("decorQuests.hideCollected", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller click, not a row factory
    CH.Mechanics.SetUITransientView(VIEW, "hideCollected", not on)
end

function Controller:_wireListChrome(rootFrame)
    -- The preset chips and the filter row overflow sideways (no wrap): clip at the panel
    -- edge rather than bleed into the detail panel. Dropdown popups are top-level.
    rootFrame.panels.decorQuestsListPanel:SetClipsChildren(true)
    HDG.UI.OnClick(rootFrame, "decorQuestsListPanel.byDecor", _setView("viewMode", "decor"))
    HDG.UI.OnClick(rootFrame, "decorQuestsListPanel.byChain", _setView("viewMode", "chain"))
    for _, p in ipairs(HDG.Constants.DQ_PRESETS) do
        HDG.UI.OnClick(rootFrame, "decorQuestsListPanel.preset_" .. p.value, _setView("preset", p.value))
    end
    HDG.UI.WireSearchBox(rootFrame, "decorQuestsListPanel.search", VIEW, "searchQuery")
    -- The X: every HDG pin off the world map, as Find Decor's and Recipe Sources' (owner 10-30).
    HDG.UI.OnClick(rootFrame, "decorQuestsListPanel.clearPinsBtn", function() HDG.Waypoints:ClearAllMapPins() end)
end

function Controller:_wireFilters(rootFrame)
    HDG.UI.OnClick(rootFrame, "decorQuestsListPanel.hideCollected", _toggleHideCollected)
    HDG.UI.OnClick(rootFrame, "decorQuestsListPanel.resetFilters", function()
        _dispatch("UI_FILTER_RESET", { tab = VIEW })
    end)
end

-- Selection highlight follows state (selected, one key for both lists); group rows
-- never match.
local function _isSelected(ed, key) return key ~= nil and ed.kind ~= "group" and _listKey(ed) == key end

function Controller:_wireList(rootFrame)
    for _, list in ipairs({ "decorQuestsListPanel.list", "decorQuestsListPanel.chainList" }) do
        HDG.UI.W(rootFrame, list):WireStoreSelectionSync("session.ui.decorQuests.selected", _isSelected)
    end
end

function Controller:Wire(rootFrame)
    self:_wireListChrome(rootFrame)
    self:_wireFilters(rootFrame)
    self:_wireList(rootFrame)
end

function Controller:Refresh(rootFrame, ctx)
    -- Every widget paints through its binding; nothing imperative.
end

HDG.Controllers:Register("decorQuests", Controller)
