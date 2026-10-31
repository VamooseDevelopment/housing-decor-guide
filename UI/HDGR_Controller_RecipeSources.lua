-- HDG.RecipeSourcesController
-- ============================================================================
-- Recipe Sources tab: Wire() for the list panel's controls, and two row factories
-- (selectors shape every row in HDGR_Selectors_RecipeSources.lua; these paint
-- through Theme / Palette and wire clicks off the row's own envelope):
--   recipeSourcesListRow   -- profHeader / recipe (By Recipe), expHeader / teacher (By Teacher)
--   recipeSourcesDetailRow -- the detail's flattened cards: info, section, reagents,
--                             cardHead, line, place, teach, blank
-- Click and tooltip handlers are module-level and read what the paint stamped on
-- the frame (row._ed, button._place ...): rows repaint on every scroll, and a
-- closure per paint was garbage each time.

HDG = HDG or {}
HDG.RecipeSourcesController = HDG.RecipeSourcesController or {}

local Controller = HDG.RecipeSourcesController
local CH = HDG.ControllerHelpers
local VIEW = "recipeSources"

local function L(key) return HDG.Locale:Get(key) end

-- ===== Shared paint ========================================================

-- Source kind -> its Palette swatch (Constants.SOURCE_TYPE_COLOR names).
local KIND_TOKEN = {
    vendor = "VENDOR", trainer = "PROFESSION", drop = "DROP", quest = "QUEST",
    discovery = "LEARNED", treasure = "TREASURE", event = "EVENT", fishing = "GATHERING",
    auction = "GOLD_ONLY", profession = "CRAFTED", none = "UNKNOWN",
}

local function _chipText(kind, label)
    return HDG.Palette:ColorCode("source." .. KIND_TOKEN[kind]) .. "[" .. label .. "]|r"
end

-- Learned state -> its Theme text state. An alt's state names the alts, each in its class
-- color; every piece is closed on its own, so no color code nests inside another.
local KNOWN = { you = "known_self", alt = "known_alt", none = "error" }
local function _altWord(text) return HDG.Theme:StateLabel(KNOWN.alt, text) end

-- A row's state: "Known" / "Not learned", or the first alt and how many more ("Ann +1").
local function _knownText(ed, text)
    if not ed.alts then return HDG.Theme:StateLabel(KNOWN[ed.known], text) end
    local first = HDG.Theme:ClassName(ed.alts[1].name, ed.alts[1].classFile)
    if #ed.alts == 1 then return first end
    return first .. " " .. _altWord(L("RS_KNOWN_ALT_MORE"):format(#ed.alts - 1))
end

-- The detail's state line: "Known by Ann, Bob" when alts know it.
local function _knownLine(ed)
    if ed.known ~= "alt" then return HDG.Theme:StateLabel(KNOWN[ed.known], ed.stateText) end
    local names = {}
    for i, a in ipairs(ed.alts) do names[i] = HDG.Theme:ClassName(a.name, a.classFile) end
    return _altWord(L("RS_STATE_ALT")) .. " " .. table.concat(names, _altWord(", "))
end

-- A line's tone -> its color code (Theme for state colors, Palette for source swatches).
local TONE = {
    text  = function() return HDG.Theme:ColorCode("text.primary") end,
    dim   = function() return HDG.Theme:ColorCode("text.dim") end,
    met   = function() return HDG.Theme:GetTextStateColorToken("collected") end,
    miss  = function() return HDG.Theme:ColorCode("semantic.error") end,
    rep   = function() return HDG.Palette:ColorCode("source.REP") end,
    quest = function() return HDG.Palette:ColorCode("source.QUEST") end,
}

-- A line naming characters (the selector's `parts`): strings in the tone's color, each
-- character in its class color, every piece closed on its own.
local function _partsText(parts, tone)
    local out = {}
    for i, p in ipairs(parts) do
        out[i] = type(p) == "string" and (TONE[tone]() .. p .. "|r") or HDG.Theme:ClassName(p.name, p.classFile)
    end
    return table.concat(out)
end

-- Faction badge: the side's letter or word in its brand color (Palette faction.*), and
-- for both sides "A/H" with each letter in its own color and the slash dim.
local SIDE_TOKEN = { A = "faction.Alliance", H = "faction.Horde" }
local SIDE_LONG  = { A = "RS_SIDE_ALLIANCE", H = "RS_SIDE_HORDE" }
local function _sideText(side, short)
    return HDG.Palette:ColorCode(SIDE_TOKEN[side]) .. (short and side or L(SIDE_LONG[side])) .. "|r"
end

local function _paintBadge(fs, side, short)
    if not side then return end   -- exception(optional): drops and the like stand on no side
    HDG.Theme:Register(fs, "TextDim")
    if side == "N" then
        fs:SetText(_sideText("A", true) .. "/" .. _sideText("H", true))
        return
    end
    fs:SetText(_sideText(side, short))
end

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

-- ===== Waypoint / Map on a place ===========================================
-- The place is stamped on the buttons; VendorNavTip names it, or says why the
-- buttons are greyed (no location yet).

local function _onWaypoint(self)
    local p = self._place
    HDG.Waypoints:Set(p.mapID, p.x, p.y, p.name, p.side)
end
local function _onShowOnMap(self)
    local p = self._place
    HDG.Waypoints:ShowOnMap(p.mapID, p.x, p.y, p.name)
end
local function _wayTip(self) return HDG.TooltipRecipes.VendorNavTip(self._place, "VENDOR_WAY_TIP") end
local function _mapTip(self) return HDG.TooltipRecipes.VendorNavTip(self._place, "VENDOR_MAP_TIP") end

local function _placeButton(b, p, label, width, onClick, tip)
    b._place = p
    b:SetSize(width, 18)
    b:SetText(L(label))
    HDG.UI.SetEnabledLook(b, p.mappable)
    HDG.TooltipEngine:Attach(b, tip)
    b:SetScript("OnClick", onClick)
    b:Show()
end

local function _wirePlaceButtons(row, p)
    _placeButton(row._btnB, p, "RS_MAP", 36, _onShowOnMap, _mapTip)
    row._btnB:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    _placeButton(row._btnA, p, "RS_WAYPOINT", 62, _onWaypoint, _wayTip)
    row._btnA:SetPoint("RIGHT", row._btnB, "LEFT", -4, 0)
end

-- ===== List rows ===========================================================

local LIST_HEIGHT = { profHeader = 24, expHeader = 24, recipe = 34, teacher = 34 }
local TEACHER_EXTRA_HEIGHT = 48   -- a trainer with alts needing training gets a third line
local LIST_TEXTS = { "_caret", "_name", "_state", "_badge", "_chip", "_where", "_cost", "_extra" }

local function _listRowHeight(_index, ed)
    if ed.kind == "teacher" and ed.extra then return TEACHER_EXTRA_HEIGHT end
    return LIST_HEIGHT[ed.kind]
end

local function _layoutListRow(row)
    row._icon  = HDG.UI.MakeCellIcon(row, 16)
    row._caret = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
    row._name  = HDG.UI.RowText(row, "body", "Text", "LEFT")
    row._state = HDG.UI.RowText(row, "caption", "Text", "RIGHT")
    row._badge = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    row._chip  = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    row._where = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    row._cost  = HDG.UI.RowText(row, "caption", "Text", "RIGHT")
    row._extra = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
end

local function _resetListRow(row)
    _resetTexts(row, LIST_TEXTS)
    row._icon:Hide()
    row._icon:ClearAllPoints()
    row._ed = nil
end

local function _paintGroupHeader(row, ed, title, count)
    HDG.Theme:Register(row, "RowChrome", { header = true })
    row._caret:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._caret:SetText(HDG.UI.CollapsePrefix(ed.collapsed))
    row._state:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._state:SetText(HDG.Theme:ColorCode("text.dim") .. count .. "|r")
    row._name:SetText(title)
end

local function _paintProfHeader(row, ed)
    _paintGroupHeader(row, ed, HDG.Theme:ColorCode("semantic.accent") .. ed.profession .. "|r",
        L("RS_GROUP_COUNT"):format(ed.shown, ed.known, ed.total))
    row._icon:SetPoint("LEFT", row._caret, "RIGHT", 4, 0)
    HDG.UI.PaintIcon(row._icon, ed.atlas, nil, HDG.Constants.PLACEHOLDER_ICON)
    row._icon:Show()
    row._name:SetPoint("LEFT", row._icon, "RIGHT", 6, 0)
end

local function _paintExpHeader(row, ed)
    local color = ed.color or HDG.Theme:ColorCode("semantic.accent")   -- exception(optional): the drops group has no expansion color
    _paintGroupHeader(row, ed, color .. ed.label .. "|r", ed.count)
    row._name:SetPoint("LEFT", row._caret, "RIGHT", 4, 0)
end

-- Line 1: name ... state; line 2: chip, where ... cost.
local function _anchorLines(row)
    row._state:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
    row._chip:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -19)
    row._cost:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -19)
    row._where:SetPoint("TOPLEFT", row._chip, "TOPRIGHT", 6, 0)
    row._where:SetPoint("TOPRIGHT", row._cost, "TOPLEFT", -6, 0)
end

local function _paintRecipe(row, ed)
    HDG.UI.PaintRowChrome(row, ed.selected)
    _anchorLines(row)
    row._name:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
    row._name:SetPoint("TOPRIGHT", row._state, "TOPLEFT", -6, 0)
    row._name:SetText(ed.name)
    row._state:SetText(_knownText(ed, ed.stateShort))
    row._chip:SetText(_chipText(ed.chipKind, ed.chipLabel))
    row._where:SetText(ed.where)
    row._cost:SetText(ed.cost)
end

-- A trainer listed for a skill line alone teaches no decor recipe: nothing to learn or
-- to have learned, so no state.
local function _teacherState(ed)
    if ed.skillOnly then return "" end
    if ed.toLearn > 0 then return HDG.Theme:StateLabel("error", L("RS_TO_LEARN"):format(ed.toLearn)) end
    return HDG.Theme:StateLabel("known_self", L("RS_ALL_LEARNED"))
end

local function _teacherWhere(ed)
    if not ed.missing then return ed.zone end
    return ed.zone .. "  " .. HDG.Theme:StateLabel("error", L("RS_NO_LOCATION_SHORT"))
end

local function _paintTeacher(row, ed)
    HDG.UI.PaintRowChrome(row, ed.selected)
    _anchorLines(row)
    row._name:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
    row._badge:SetPoint("LEFT", row._name, "RIGHT", 6, 0)
    row._name:SetText(ed.who)
    _paintBadge(row._badge, ed.side, false)
    row._state:SetText(_teacherState(ed))
    row._chip:SetText(_chipText(ed.chipKind, ed.chipLabel))
    row._where:SetText(_teacherWhere(ed))
    row._cost:SetText(ed.teachesText)
    if not ed.extra then return end
    row._extra:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -33)
    row._extra:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -33)
    row._extra:SetText(_partsText(ed.extraParts, "dim"))
end

local function _toggleGroup(ed)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.RS_TOGGLE_GROUP, payload = { key = ed.key } })
end
local function _selectRecipe(ed)
    -- Shift-click links the crafted decor in chat, as the other item lists do.
    if IsShiftKeyDown() then HDG.UI.LinkItem(ed.itemID) return end
    CH.Mechanics.SetUITransientView(VIEW, "selectedItemID", ed.itemID)
end
local function _selectTeacher(ed)
    CH.Mechanics.SetUITransientView(VIEW, "selectedTeacherKey", ed.key)
end

local LIST_PAINT = { profHeader = _paintProfHeader, expHeader = _paintExpHeader,
                     recipe = _paintRecipe, teacher = _paintTeacher }
local LIST_CLICK = { profHeader = _toggleGroup, expHeader = _toggleGroup,
                     recipe = _selectRecipe, teacher = _selectTeacher }

local function _onListRowClick(self)
    LIST_CLICK[self._ed.kind](self._ed)
end

local function _wireListRow(row, ed)
    row._ed = ed
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", _onListRowClick)
end

local function _listRowFactory(_template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_rsListLaidOut", _layoutListRow)
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

HDG.Rows:Register("recipeSourcesListRow", {
    font    = "body",
    height  = _listRowHeight,
    factory = _listRowFactory,
    key     = function(ed)
        if ed.kind == "recipe" then return "r:" .. ed.itemID end
        return ed.key   -- headers "P:"/"T:", teachers "npc:"/"at:"
    end,
})

-- ===== Detail rows =========================================================

local DETAIL_HEIGHT = { info = 62, section = 24, reagents = 40, cardHead = 26, place = 24, teach = 36, blank = 60 }
local LINE_HEIGHT, LINE_PAD = 14, 6
local DETAIL_TEXTS = { "_chip", "_badge", "_main", "_sub", "_third", "_right", "_main2", "_sub2" }
local INFO_ICON, REAGENT_ICON, TEACH_ICON = 52, 30, 18   -- the info icon fills the 62px info row
local INFO_BUTTON_W, CART_BUTTON_W = 100, 130
local REAGENT_COL2_X = 222   -- the second reagent column, half the detail list's width
local REAGENT_NAME_W = 180

local function _detailRowHeight(_index, ed)
    if ed.kind == "line" then return LINE_PAD + LINE_HEIGHT * ed.lines end
    return DETAIL_HEIGHT[ed.kind]
end

local function _layoutDetailRow(row)
    row._icon  = HDG.UI.MakeCellIcon(row, INFO_ICON)
    row._icon2 = HDG.UI.MakeCellIcon(row, REAGENT_ICON)
    row._chip  = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    row._badge = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    row._main  = HDG.UI.RowText(row, "body", "Text", "LEFT")
    row._sub   = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    row._third = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    row._right = HDG.UI.RowText(row, "caption", "Text", "RIGHT")
    row._main2 = HDG.UI.RowText(row, "body", "Text", "LEFT")
    row._sub2  = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    row._btnA  = HDG.UI.RowButton(row, "")
    row._btnB  = HDG.UI.RowButton(row, "")
end

local function _resetButton(b)
    b:Hide()
    b:ClearAllPoints()
    b:SetScript("OnClick", nil)
    HDG.UI.SetEnabledLook(b, true)
end

local function _resetDetailRow(row)
    _resetTexts(row, DETAIL_TEXTS)
    HDG.UI.applyFontRole(row._main, "body")
    row._main:SetJustifyH("LEFT")   -- the blank row centres it
    row._icon:Hide()
    row._icon:ClearAllPoints()
    row._icon2:Hide()
    row._icon2:ClearAllPoints()
    _resetButton(row._btnA)
    _resetButton(row._btnB)
    row:SetAlpha(1)
    row._ed = nil
end

local function _showIcon(tex, size, atlas, texture)
    tex:SetSize(size, size)
    HDG.UI.PaintIcon(tex, atlas, texture, HDG.Constants.PLACEHOLDER_ICON)
    if not atlas then tex:SetTexCoord(unpack(HDG.Constants.ICON_CROP)) end
    tex:Show()
end

-- ----- info -----

local OPEN_TIP, WOWHEAD_TIP, CART_TIP = { recipe = "RsOpenInRecipes" }, { recipe = "WowheadLink" }, { recipe = "RecipesAddAllToAH" }

local function _onOpenInRecipes(self) CH.Mechanics.JumpToRecipe(self._itemID) end
local function _onWowhead(self)
    ---@diagnostic disable-next-line: undefined-field
    HDG.UI:UrlCopyPopup():ShowAt(self, self._url)   -- the popup frame carries ShowAt (Components.lua)
end

local function _wireInfoButtons(row, ed)
    local open, wowhead = row._btnA, row._btnB
    open._itemID, wowhead._url = ed.itemID, ed.wowheadUrl
    open:SetSize(INFO_BUTTON_W, 18)
    open:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -4)
    open:SetText(L("RS_OPEN_IN_RECIPES"))
    open:SetScript("OnClick", _onOpenInRecipes)
    HDG.TooltipEngine:Attach(open, OPEN_TIP)
    wowhead:SetSize(INFO_BUTTON_W, 18)
    wowhead:SetPoint("TOPRIGHT", open, "BOTTOMRIGHT", 0, -4)
    wowhead:SetText(L("RS_WOWHEAD"))
    wowhead:SetScript("OnClick", _onWowhead)
    HDG.TooltipEngine:Attach(wowhead, WOWHEAD_TIP)
    open:Show()
    wowhead:Show()
end

local function _paintInfo(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._icon:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -5)
    _showIcon(row._icon, INFO_ICON, nil, ed.icon)
    _wireInfoButtons(row, ed)
    HDG.UI.applyFontRole(row._main, "subheading")
    row._main:SetPoint("TOPLEFT", row._icon, "TOPRIGHT", 8, 0)
    row._main:SetPoint("TOPRIGHT", row, "TOPRIGHT", -(INFO_BUTTON_W + 12), -4)
    row._sub:SetPoint("TOPLEFT", row._main, "BOTTOMLEFT", 0, -3)
    row._sub:SetPoint("TOPRIGHT", row._main, "BOTTOMRIGHT", 0, -3)
    row._third:SetPoint("TOPLEFT", row._sub, "BOTTOMLEFT", 0, -3)
    row._main:SetText(ed.name)
    row._sub:SetText(ed.meta)
    row._third:SetText(_knownLine(ed))
end

-- ----- section -----

local function _onAddMissing(self)
    local n, present = HDG.UI.SendReagentsToAuctionator("HDG Recipe Sources", self._missing)
    if not present then return HDG.Log:Info("queue", L("RS_AUCTIONATOR_MISSING")) end
    if n == 0 then return HDG.Log:Info("queue", L("RS_AUCTIONATOR_NONE")) end
    HDG.Log:Info("queue", L("RS_AUCTIONATOR_SENT"):format(n))
end

local function _wireCartButton(row, missing)
    local b = row._btnA
    b._missing = missing
    b:SetSize(CART_BUTTON_W, 18)
    b:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    b:SetText(L("RS_ADD_MISSING"))
    b:SetScript("OnClick", _onAddMissing)
    HDG.TooltipEngine:Attach(b, CART_TIP)
    b:Show()
end

local function _paintSection(row, ed)
    HDG.Theme:Register(row, "RowChrome", { header = true })
    row._main:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._main:SetText(HDG.Theme:ColorCode("semantic.accent") .. ed.label .. "|r")
    row._sub:SetPoint("LEFT", row._main, "RIGHT", 8, 0)
    row._sub:SetText(ed.count)
    if ed.missing and #ed.missing > 0 then _wireCartButton(row, ed.missing) end   -- exception(optional): only the reagents header carries a missing list
end

-- ----- reagents -----

local function _paintReagentCell(row, icon, qty, name, cell, x)
    icon:SetPoint("LEFT", row, "LEFT", x, 0)
    _showIcon(icon, REAGENT_ICON, nil, cell.icon)
    local count = cell.have .. "/" .. cell.need
    qty:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -1)
    qty:SetText(cell.short and HDG.Theme:StateLabel("error", count) or count)   -- red when short
    name:SetPoint("TOPLEFT", qty, "BOTTOMLEFT", 0, -2)
    name:SetWidth(REAGENT_NAME_W)
    name:SetText(cell.name)
end

local function _paintReagents(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    _paintReagentCell(row, row._icon, row._main, row._sub, ed.a, 4)
    if ed.b then _paintReagentCell(row, row._icon2, row._main2, row._sub2, ed.b, REAGENT_COL2_X) end   -- exception(optional): an odd reagent count leaves the last row half full
end

-- ----- card head, line, place -----

local function _paintCardHead(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._chip:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._chip:SetText(_chipText(ed.chipKind, ed.chipLabel))
    row._main:SetPoint("LEFT", row._chip, "RIGHT", 6, 0)
    row._main:SetText(ed.title)
    if ed.place then
        row._badge:SetPoint("LEFT", row._main, "RIGHT", 6, 0)
        _paintBadge(row._badge, ed.side, false)
        _wirePlaceButtons(row, ed.place)
        return
    end
    row._right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._right:SetText(ed.cost)
    row._main:SetPoint("RIGHT", row._right, "LEFT", -8, 0)
end

local function _paintLine(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    local fs = row._sub
    fs:SetPoint("TOPLEFT", row, "TOPLEFT", 16, -3)
    fs:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -3)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    if ed.parts then fs:SetText(_partsText(ed.parts, ed.tone)) return end   -- exception(optional): only lines naming characters carry parts
    fs:SetText(TONE[ed.tone]() .. ed.text .. "|r")
end

local function _placeText(ed)
    if not ed.missing then return ed.detail end
    return ed.detail .. "  " .. HDG.Theme:StateLabel("error", L("RS_NO_LOCATION_SHORT"))
end

local function _paintPlace(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    _wirePlaceButtons(row, ed)
    row._badge:SetPoint("LEFT", row, "LEFT", 16, 0)
    _paintBadge(row._badge, ed.side, true)
    row._main:SetPoint("LEFT", row._badge, "RIGHT", 6, 0)
    row._main:SetText(ed.name)
    row._sub:SetPoint("LEFT", row._main, "RIGHT", 8, 0)
    row._sub:SetPoint("RIGHT", row._btnA, "LEFT", -6, 0)
    row._sub:SetText(_placeText(ed))
end

-- ----- teach, blank -----

local function _onTeachClick(self)
    CH.Mechanics.SetUITransientView(VIEW, "viewMode", "recipe")
    CH.Mechanics.SetUITransientView(VIEW, "selectedItemID", self._ed.itemID)
end

local function _paintTeach(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    _showIcon(row._icon, TEACH_ICON, ed.atlas, nil)
    row._right:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -4)
    row._right:SetText(_knownText(ed, ed.stateShort))
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", 28, -4)
    row._main:SetPoint("TOPRIGHT", row._right, "TOPLEFT", -6, 0)
    row._main:SetText(ed.name)
    row._third:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -20)
    row._third:SetText(ed.cost)
    row._sub:SetPoint("TOPLEFT", row, "TOPLEFT", 28, -20)
    row._sub:SetPoint("TOPRIGHT", row._third, "TOPLEFT", -6, 0)
    row._sub:SetText(ed.line2)
    row._ed = ed
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", _onTeachClick)
end

local function _paintBlank(row, ed)
    HDG.UI.PaintRowChrome(row, false)
    row._main:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -20)
    row._main:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -20)
    row._main:SetJustifyH("CENTER")
    row._main:SetText(HDG.Theme:ColorCode("text.dim") .. ed.text .. "|r")
end

local DETAIL_PAINT = {
    info = _paintInfo, section = _paintSection, reagents = _paintReagents,
    cardHead = _paintCardHead, line = _paintLine, place = _paintPlace,
    teach = _paintTeach, blank = _paintBlank,
}

local function _detailRowFactory(_template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_rsDetailLaidOut", _layoutDetailRow)
            row:SetScript("OnClick", nil)
            _resetDetailRow(row)
            DETAIL_PAINT[ed.kind](row, ed)
            -- The other faction's NPCs read dimmed: a generic trainer's place, or a whole card.
            if ed.other then row:SetAlpha(HDG.UI.DISABLED_ALPHA) end   -- exception(optional): only other-faction rows carry it; the reset set 1
            row:SetHeight(_detailRowHeight(nil, ed))
        end,
        Reset = function(row)
            row:SetScript("OnClick", nil)
            _resetDetailRow(row)
        end,
    }
end

HDG.Rows:Register("recipeSourcesDetailRow", {
    font    = "body",
    height  = _detailRowHeight,
    factory = _detailRowFactory,
    key     = function(ed) return ed.key end,
})

-- ===== Controller wiring ===================================================

local function _setView(key, value)
    return function() CH.Mechanics.SetUITransientView(VIEW, key, value) end
end

function Controller:_wireListChrome(rootFrame)
    -- Active-filter tags overflow sideways (no wrap): clip at the panel edge rather
    -- than bleed into the detail panel. Dropdown popups are top-level, never clipped.
    rootFrame.panels.recipeSourcesListPanel:SetClipsChildren(true)
    HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.byRecipe", _setView("viewMode", "recipe"))
    HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.byTeacher", _setView("viewMode", "teacher"))
    for _, p in ipairs(HDG.Constants.RS_PRESETS) do
        HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.preset_" .. p.value, _setView("preset", p.value))
    end
    HDG.UI.WireSearchBox(rootFrame, "recipeSourcesListPanel.search", VIEW, "searchQuery")
end

function Controller:_wireMapButtons(rootFrame)
    -- Map N places: pin every place of the shown list with a location, open the map once.
    HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.mapAllBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        HDG.Waypoints:MapAll(HDG.Selectors:Call("recipeSources.mapPlaces", state, {}))
    end)
    HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.clearPinsBtn", function() HDG.Waypoints:ClearAllMapPins() end)
end

function Controller:_wireFilters(rootFrame)
    local A = HDG.Constants.ACTIONS
    -- Here: the Zone filter, set to where the player stands. A copy goes into state:
    -- the toggle action mutates the set in place, and this one is a memoized result.
    HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.here", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local zones = {}
        for z in pairs(HDG.Selectors:Call("recipeSources.currentZones", state, {})) do zones[z] = true end
        CH.Mechanics.SetUITransientView(VIEW, "zoneFilter", zones)
    end)
    HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.resetFilters", function()
        HDG.Store:Dispatch({ type = A.UI_FILTER_RESET, payload = { tab = VIEW } })
    end)
    HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.tag_preset", _setView("preset", "all"))
    -- A tag clears its axis ("all" wipes the set).
    for _, a in ipairs(HDG.Constants.RS_FILTER_AXES) do
        local payload = { [a.axis] = "all" }
        HDG.UI.OnClick(rootFrame, "recipeSourcesListPanel.tag_" .. a.axis, function()
            HDG.Store:Dispatch({ type = A.RS_TOGGLE_FILTER, payload = payload })
        end)
    end
end

-- Selection highlight follows state (selectedItemID / selectedTeacherKey); header
-- rows never match.
function Controller:_wireLists(rootFrame)
    HDG.UI.W(rootFrame, "recipeSourcesListPanel.recipeList"):WireStoreSelectionSync(
        "session.ui.recipeSources.selectedItemID",
        function(ed, id) return id ~= nil and ed.kind == "recipe" and ed.itemID == id end)
    HDG.UI.W(rootFrame, "recipeSourcesListPanel.teacherList"):WireStoreSelectionSync(
        "session.ui.recipeSources.selectedTeacherKey",
        function(ed, key) return key ~= nil and ed.kind == "teacher" and ed.key == key end)
end

function Controller:Wire(rootFrame)
    self:_wireListChrome(rootFrame)
    self:_wireMapButtons(rootFrame)
    self:_wireFilters(rootFrame)
    self:_wireLists(rootFrame)
end

function Controller:Refresh(rootFrame, ctx)
    -- Every widget paints through its binding; nothing imperative.
end

HDG.Controllers:Register("recipeSources", Controller)
