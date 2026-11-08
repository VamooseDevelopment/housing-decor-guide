-- HDG.CompanionController
-- ============================================================================
-- Companion satellite: click/search wiring, the companionSidebarRow factory
-- (the picker's rows), and the companion's own widget kinds: the mode rail
-- button, a sprite glyph, and the list picker on the grid heading.
-- Placement lifecycle lives in Modules/HDGR_HouseEditorCompanion.lua.

HDG = HDG or {}
HDG.CompanionController = HDG.CompanionController or {}
local CompanionController = HDG.CompanionController

local A    = HDG.Constants.ACTIONS
local COMP = HDG.Constants.COMPANION

-- Rail order. Drives the click wiring here; the matching companion.isMode_<key>
-- active bindings live in Selectors, the buttons in LayoutConfig.
local MODE_KEYS = { "catalog", "styles", "rooms", "snapshots", "themes", "collections", "recent" }

-- ===== Sidebar row factory ==================================================

-- Relative-time label for a recent session row (impure -- needs time(); not a selector).
local function _formatSessionLabel(ed)
    local n = ed.eventCount or 0  -- exception(boundary): session may lack eventCount
    if ed.isActive then return "Now (" .. n .. ")" end
    local ts      = ed.endedAt or ed.startedAt or 0  -- exception(nullable): timestamp fallback chain
    local elapsed = math.max(0, _G.time() - ts)  -- exception(boundary): time() is impure
    if elapsed < 60        then return "Just now (" .. n .. ")" end
    if elapsed < 3600      then return _G.string.format("%dm ago (%d)", math.floor(elapsed / 60), n) end
    if elapsed < 86400     then return _G.string.format("%dh ago (%d)", math.floor(elapsed / 3600), n) end
    if elapsed < 7 * 86400 then return _G.date("%a", ts) .. " (" .. n .. ")" end
    return _G.date("%b %d", ts) .. " (" .. n .. ")"
end

-- One-time chrome: optional icon + label (left) + count (right).
local function _layoutSidebarRow(row)
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)   -- a room's blueprint tile, or a Catalog category icon
    icon:SetSize(18, 18)
    icon:Hide()
    row._iconTex = icon

    local fs = HDG.UI.RowText(row, "body", "Text", "LEFT")
    fs:SetPoint("LEFT", row, "LEFT", 6, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -34, 0)   -- leave room for the count
    fs:SetWordWrap(false)   -- long names (e.g. shopping lists) truncate, not wrap into the next row
    row._labelFs = fs

    local cfs = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    cfs:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._countFs = cfs

    -- Hairline divider (vertically centred), shown only for isDivider rows. Themed
    -- via the Divider skinner so it repaints on scheme switch.
    local div = row:CreateTexture(nil, "ARTWORK", nil, 2)
    div:SetHeight(1)
    div:SetPoint("LEFT", row, "LEFT", 6, 0)
    div:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    HDG.Theme:Register(div, "Divider")
    div:Hide()
    row._dividerTex = div
end

-- The icon (rooms and Catalog rows) and where it and the label start, set on
-- every paint: the picker reuses rows across lists, so a row keeps whatever the
-- last list left. indent = a Catalog subcategory, set in under its category.
local SUB_INDENT = 16
local function _placeLabel(row, iconAtlas, indent)
    local left = indent and SUB_INDENT or 0
    row._labelFs:ClearAllPoints()
    row._iconTex:ClearAllPoints()
    row._iconTex:SetPoint("LEFT", row, "LEFT", 4 + left, 0)
    if iconAtlas then
        row._iconTex:SetAtlas(iconAtlas, false); row._iconTex:Show()
        row._labelFs:SetPoint("LEFT", row._iconTex, "RIGHT", 4, 0)
    else
        row._iconTex:Hide()
        row._labelFs:SetPoint("LEFT", row, "LEFT", 6 + left, 0)
    end
    row._labelFs:SetPoint("RIGHT", row, "RIGHT", -34, 0)
end

-- Divider row: a centred hairline, no label, non-interactive.
local function _paintDividerRow(row)
    _placeLabel(row, nil)
    row._labelFs:SetText("")
    row._countFs:SetText("")
    row._dividerTex:Show()
    HDG.Theme:Register(row, "RowChrome", { selected = false })
    row:SetScript("OnClick", nil)
    row:EnableMouse(false)
end

-- Header row: dimmed section divider, non-interactive.
local function _paintHeaderRow(row, ed)
    row._dividerTex:Hide()
    _placeLabel(row, nil)
    row._labelFs:SetText(ed.displayName)
    HDG.Theme:Register(row._labelFs, "TextDim")
    row._countFs:SetText("")
    HDG.Theme:Register(row, "RowChrome", { selected = false })
    row:SetScript("OnClick", nil)
    row:EnableMouse(false)
end

-- The two literal groups name themselves from Locale; a category row carries its
-- own name. Resolved at paint, not in the selector: a selector that baked the
-- string in would keep serving the old language after a locale switch.
local GROUP_LABEL_KEY = {
    loose     = "STY_LANDING_LOOSE",          -- shared with the Browse fold: same fold, same words
    smartsets = "COMP_GROUP_FILTERED_SETS",
}
local function _groupLabel(ed)
    local key = GROUP_LABEL_KEY[ed.groupKey]
    if key then return HDG.Locale:Get(key) end
    return ed.displayName
end

-- Group row (a category, the loose fold, or Filtered Sets): header band, text
-- chevron, member count, click folds. Unlike the plain header row it takes mouse.
local function _paintGroupRow(row, ed)
    row._dividerTex:Hide()
    _placeLabel(row, nil)
    HDG.Theme:Register(row._labelFs, "Text")
    row._labelFs:SetText((ed.collapsed and "> " or "v ") .. _groupLabel(ed))
    if ed.matchCount then
        row._countFs:SetText(string.format(HDG.Locale:Get("COMP_GROUP_MATCH_FMT"), ed.matchCount, ed.count))
    else
        row._countFs:SetText(tostring(ed.count))
    end
    HDG.Theme:Register(row, "RowChrome", { header = true })
    row:EnableMouse(true)
    local groupKey, forcedOpen = ed.groupKey, ed.forcedOpen
    row:SetScript("OnClick", function()
        -- Search force-opens this row; toggling then would write a flag the user
        -- never sees flip. No-op until the search clears.
        if forcedOpen then return end
        HDG.Store:Dispatch({ type = A.COMPANION_TOGGLE_GROUP, payload = { key = groupKey } })
    end)
end

-- Catalog's "All" is Blizzard's own word for it, in the client's language.
local function _catalogAllLabel()
    return _G.HOUSING_CATALOG_CATEGORIES_ALL   -- exception(boundary): Blizzard GlobalStrings, the client's term
end

-- A row's name and count text. A Catalog category that opens carries the group
-- rows' text caret after its count.
local function _rowTexts(ed)
    if ed.isRecentSession then return _formatSessionLabel(ed), "" end   -- count baked into the label
    local name  = ed.isAll and _catalogAllLabel() or ed.displayName or ed.id
    local count = ed.count and tostring(ed.count) or ""
    if ed.hasSubs then count = count .. (ed.isOpen and "  v" or "  >") end
    return name, count
end

-- Selectable row: name + count (or time label for recent sessions). Click
-- dispatches COMPANION_SELECT_ITEM; a Catalog category with subcategories keeps
-- the picker open on them.
local function _paintSelectableRow(row, ed)
    row._dividerTex:Hide()
    row:EnableMouse(true)
    HDG.Theme:Register(row._labelFs, "Text")
    local name, count = _rowTexts(ed)
    row._labelFs:SetText(name)
    row._countFs:SetText(count)
    _placeLabel(row, ed.iconAtlas, ed.isSub)   -- a room's blueprint tile, or a Catalog category icon
    HDG.Theme:Register(row, "RowChrome", { selected = ed.isSelected == true })
    local id, keepOpen = ed.id, ed.hasSubs == true
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = A.COMPANION_SELECT_ITEM, payload = { itemID = id, keepOpen = keepOpen } })
    end)
end

local function _companionRowFactory(_def)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_companionLaidOut", function()
                _layoutSidebarRow(row)
            end)
            row:RegisterForClicks("LeftButtonUp")
            if ed.isDivider then
                _paintDividerRow(row)
            elseif ed.isGroup then
                -- Before isHeader: a group row IS a header row that also folds.
                _paintGroupRow(row, ed)
            elseif ed.isHeader then
                _paintHeaderRow(row, ed)
            else
                _paintSelectableRow(row, ed)
            end
        end,
        Reset = function(row)
            if row._labelFs    then row._labelFs:SetText("") end
            if row._countFs    then row._countFs:SetText("") end
            if row._dividerTex then row._dividerTex:Hide()   end
            row:SetScript("OnClick", nil)
        end,
    }
end

HDG.Rows:Register("companionSidebarRow", {
    font    = "body",
    height  = 24,
    factory = _companionRowFactory,
    key     = function(ed)
        if ed.isDivider       then return "d:" .. tostring(ed.id or "x") end
        -- Before the header line: two categories can share a display name, and the
        -- header key is by name -- so they need the groupKey to stay distinct rows.
        if ed.isGroup         then return "g:" .. tostring(ed.groupKey) end
        if ed.isHeader        then return "h:" .. tostring(ed.displayName) end
        if ed.isRecentSession then return "s:" .. tostring(ed.id) end
        return "r:" .. tostring(ed.id)
    end,
})

-- ===== Sprite glyphs (rail icons + stepper glyphs share one sheet) ==========

local function _setSpriteCell(tex, cellName)
    local cell = COMP.SPRITE_CELL[cellName]
    if cell == nil then error(("companion sprite: unknown cell %q"):format(tostring(cellName)), 2) end
    local c, r = cell % COMP.SPRITE_COLS, math.floor(cell / COMP.SPRITE_COLS)
    tex:SetTexture(COMP.SPRITE)
    tex:SetTexCoord(c / COMP.SPRITE_COLS, (c + 1) / COMP.SPRITE_COLS,
                    r / COMP.SPRITE_ROWS, (r + 1) / COMP.SPRITE_ROWS)
end

-- A static glyph from the sheet, tinted to a theme token (the stepper glyphs).
HDG.WidgetTypes:Register("companionSprite", {
    build = function(parent, spec)
        local frame = CreateFrame("Frame", nil, parent)
        local tex = frame:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        _setSpriteCell(tex, spec.spriteCell)
        HDG.UI.ToneTexture(tex, spec.tone)
        frame.texture = tex
        return frame
    end,
    requiresFont = function() return false end,
    specFields   = { "spriteCell", "tone" },
})

-- ===== Mode rail button =====================================================
-- Blizzard's catalog rail: a 64px button, icon over a short label. The picked
-- mode gets the raised fill and a bright icon (no accent bar: Vamoose 11-07); the
-- rest keep a muted icon. Labels stay full text colour (no dim text).

local function _setRailActive(btn, active)
    btn._bg:SetShown(active)
    HDG.UI.ToneTexture(btn._icon, active and "text.primary" or "text.muted")
end

local function _buildRailButton(parent, spec)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(COMP.RAIL_BUTTON, COMP.RAIL_BUTTON_H)

    btn._bg = btn:CreateTexture(nil, "BACKGROUND")
    btn._bg:SetAllPoints()
    HDG.Theme:Register(btn._bg, "SectionBgTint", { token = "surface.raised" })

    btn._hover = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
    btn._hover:SetAllPoints()
    HDG.Theme:Register(btn._hover, "SectionBgTint", { token = "surface.hover" })
    btn._hover:Hide()

    btn._icon = btn:CreateTexture(nil, "ARTWORK")
    btn._icon:SetSize(COMP.RAIL_ICON, COMP.RAIL_ICON)
    btn._icon:SetPoint("TOP", btn, "TOP", 0, -8)
    _setSpriteCell(btn._icon, spec.spriteCell)

    local label = HDG.UI.RowText(btn, "caption", "Text", "CENTER")
    label:SetPoint("BOTTOM", btn, "BOTTOM", 0, 7)
    label:SetText(spec.label)

    btn:SetScript("OnEnter", function(self) self._hover:Show() end)
    btn:SetScript("OnLeave", function(self) self._hover:Hide() end)
    _setRailActive(btn, false)   -- until the active binding pushes
    return btn
end

HDG.WidgetTypes:Register("companionRailButton", {
    build        = _buildRailButton,
    dispatch     = { fields = { "active" }, push = function(widget, values)
        if values.active ~= nil then _setRailActive(widget, values.active) end
    end },
    requiresFont = function() return false end,
    specFields   = { "spriteCell", "label", "tooltip" },
})

-- ===== List picker (grid heading) ===========================================
-- Shows the picked list; click opens the picker over the grid. The label is
-- formatted here, not in a selector, because a recent session's label reads
-- the clock (_formatSessionLabel), as its picker row does.

local PICKER_CARET = "housing-floor-arrow-down-default"   -- points down; turned up while open

-- A Catalog heading leads with the category's lit icon (inline atlas markup)
-- and names both levels for a subcategory: "Furnishings | Seating".
local PICKER_ICON = "|A:%s:16:16|a "
local function _catalogPickerText(row)
    local name = row.isAll and _catalogAllLabel() or row.displayName or row.id
    if row.parentName then name = row.parentName .. " | " .. name end
    if row.iconAtlas then name = PICKER_ICON:format(row.iconAtlas) .. name end
    return name
end

local function _pickerText(row, hasLists)
    if row == nil then return hasLists and "Pick a list" or "No lists here yet" end
    if row.isRecentSession then return _formatSessionLabel(row) end
    if row.isCatalog then return _catalogPickerText(row) end
    return row.displayName or row.id
end

local function _paintPicker(widget, values)
    widget._name:SetText(_pickerText(values.row, values.hasLists))
    local open = values.open == true
    HDG.Theme:Register(widget._bg, "SectionBgTint", { token = open and "surface.hover" or "surface.raised" })
    widget._caret:SetRotation(open and math.pi or 0)
end

local function _buildPicker(parent, _spec)
    local btn = CreateFrame("Button", nil, parent)
    btn._bg = btn:CreateTexture(nil, "BACKGROUND")
    btn._bg:SetAllPoints()
    HDG.Theme:Register(btn._bg, "SectionBgTint", { token = "surface.raised" })

    btn._hover = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
    btn._hover:SetAllPoints()
    HDG.Theme:Register(btn._hover, "SectionBgTint", { token = "surface.hover" })
    btn._hover:Hide()

    btn._caret = btn:CreateTexture(nil, "ARTWORK")
    btn._caret:SetSize(12, 12)
    btn._caret:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
    HDG.UI.WarnIfBadAtlas(PICKER_CARET)
    btn._caret:SetAtlas(PICKER_CARET)

    btn._name = HDG.UI.RowText(btn, "body", "TextHeading", "LEFT")
    btn._name:SetPoint("LEFT", btn, "LEFT", 8, 0)
    btn._name:SetPoint("RIGHT", btn._caret, "LEFT", -6, 0)
    btn._name:SetWordWrap(false)

    btn:SetScript("OnEnter", function(self) self._hover:Show() end)
    btn:SetScript("OnLeave", function(self) self._hover:Hide() end)
    return btn
end

HDG.WidgetTypes:Register("companionPicker", {
    build        = _buildPicker,
    dispatch     = { fields = { "row", "open", "hasLists" }, push = _paintPicker },
    requiresFont = function() return false end,
    specFields   = { "tooltip" },
})

-- ===== Picking lists ========================================================
-- The picker's own steps (companion.listSteps) say which list is first, previous
-- and next; these only dispatch the answer.

local function _selectList(id)
    if id == nil then return end   -- a mode with no lists has nothing to pick
    HDG.Store:Dispatch({ type = A.COMPANION_SELECT_ITEM, payload = { itemID = id } })
end

local function _listSteps()
    return HDG.Selectors:Call("companion.listSteps", HDG.Store:GetState(), {})  -- exception(false-positive): click handler, not a row factory
end

-- A mode opens on its first list when nothing it can show is picked: never
-- visited, or the list it remembered has since been deleted. So a rail click
-- never lands on an empty grid. Also run when the editor opens. Recent needs no
-- pick (nothing picked = the newest session): a pick there would pin a session
-- the next edit session leaves behind, so a session that aged out just clears.
function CompanionController:PickFirstListIfNone()
    local state = HDG.Store:GetState()  -- exception(false-positive): click handler, not a row factory
    if HDG.Selectors:Call("companion.pickedRow", state, {}) ~= nil then return end  -- exception(false-positive): click handler, not a row factory
    local ui = state.session.ui.companion
    if ui.mode ~= "recent" then
        _selectList(_listSteps().first)
    elseif ui.selectedItemID ~= nil then
        HDG.Store:Dispatch({ type = A.COMPANION_SELECT_ITEM, payload = { itemID = nil } })
    end
end

-- ===== Steppers =============================================================
-- Clamp here and hand the reducer the value (the arrows dim at the ends, but a
-- click on a dim arrow still arrives).

local function _stepTileSize(delta)
    local cur = HDG.Store:GetState().account.ui.companion.tileSize  -- exception(false-positive): click handler, not a row factory
    local at
    for i, s in ipairs(COMP.TILE_SIZES) do if s == cur then at = i end end
    local nextAt = math.max(1, math.min(#COMP.TILE_SIZES, at + delta))
    if nextAt == at then return end
    HDG.Store:Dispatch({ type = A.COMPANION_SET_TILE_SIZE, payload = { size = COMP.TILE_SIZES[nextAt] } })
end

local function _stepColumns(delta)
    local cur  = HDG.Store:GetState().account.ui.companion.columns  -- exception(false-positive): click handler, not a row factory
    local nextN = math.max(COMP.COLUMNS_MIN, math.min(COMP.COLUMNS_MAX, cur + delta))
    if nextN == cur then return end
    HDG.Store:Dispatch({ type = A.COMPANION_SET_COLUMNS, payload = { columns = nextN } })
end

-- ===== Controller lifecycle =================================================

function CompanionController:Wire(rootFrame)
    -- Mode rail -> COMPANION_SET_MODE { mode }, then the mode's first list if
    -- the player has not picked there yet. OnClick no-ops when the widget isn't
    -- in this frame, so wiring against the main window / other satellites is a
    -- safe no-op (only the companion frame carries these ids).
    for _, key in ipairs(MODE_KEYS) do
        local mode = key
        HDG.UI.OnClick(rootFrame, "companionPanel.rail_" .. key, function()
            HDG.Store:Dispatch({ type = A.COMPANION_SET_MODE, payload = { mode = mode } })
            CompanionController:PickFirstListIfNone()
        end)
    end

    -- Cost-badge toggle: state-dependent tooltip (read fresh on hover; not a static recipe).
    HDG.UI.OnClick(rootFrame, "companionPanel.costToggle", function()
        HDG.Store:Dispatch({ type = A.COMPANION_TOGGLE_COST, payload = {} })
    end)
    local costBtn = HDG.UI.W(rootFrame, "companionPanel.costToggle")
    HDG.TooltipEngine:Attach(costBtn, function()
        local showing = HDG.Store:GetState().account.ui.companion.showCost  -- exception(false-positive): tooltip callback, not a row factory
        return { title = showing and "Hide placement cost" or "Show placement cost" }
    end)

    -- Where-you-are chip: status only; the tooltip spells out the budget.
    HDG.TooltipEngine:Attach(HDG.UI.W(rootFrame, "companionPanel.locChip"), function()
        return HDG.Selectors:Call("companion.locTooltip", HDG.Store:GetState(), {})  -- exception(false-positive): tooltip callback, not a row factory
    end)

    -- Close [X]: HDG.Window reconciler owns Hide() via shown="companion.windowShown" binding.
    HDG.UI.OnClick(rootFrame, "companionPanel.close", function()
        HDG.Store:Dispatch({ type = A.COMPANION_TOGGLE, payload = {} })
    end)

    -- Search: userInput guard inside WireSearchBox prevents binding-push loops.
    HDG.UI.WireSearchBox(rootFrame, "companionPanel.search", "companion", "search")

    -- Tile size + columns steppers.
    HDG.UI.OnClick(rootFrame, "companionPanel.sizeDown", function() _stepTileSize(-1) end)
    HDG.UI.OnClick(rootFrame, "companionPanel.sizeUp",   function() _stepTileSize(1) end)
    HDG.UI.OnClick(rootFrame, "companionPanel.colsDown", function() _stepColumns(-1) end)
    HDG.UI.OnClick(rootFrame, "companionPanel.colsUp",   function() _stepColumns(1) end)

    -- Grid heading: the picker and its prev / next arrows.
    HDG.UI.OnClick(rootFrame, "companionPanel.picker", function()
        HDG.Store:Dispatch({ type = A.COMPANION_TOGGLE_PICKER, payload = {} })
    end)
    HDG.UI.OnClick(rootFrame, "companionPanel.listPrev", function() _selectList(_listSteps().prev) end)
    HDG.UI.OnClick(rootFrame, "companionPanel.listNext", function() _selectList(_listSteps().next) end)

    -- The picker opens OVER the grid: its frame must draw above the tiles, and take
    -- the mouse, so a click on its empty part below a short list can't reach the
    -- tile under it and place that decor.
    -- (WireAll wires this controller only into frames hosting the companion view.)
    local flyout = rootFrame.sections["companion.flyout"]
    flyout:SetFrameLevel(HDG.UI.W(rootFrame, "companionPanel.grid"):GetFrameLevel() + 100)
    flyout:EnableMouse(true)
end

function CompanionController:Refresh(_rootFrame, _ctx)
    -- Bindings handle every paint surface; nothing imperative.
end

HDG.Controllers:Register("companion", CompanionController)
