-- HDG.ProjectsController
-- ============================================================================
-- Projects views (landing / architect). Registers floor-tab chip +
-- row factories. Canvas renders via HDG.ProjectsCanvasController.

HDG = HDG or {}
HDG.ProjectsController = HDG.ProjectsController or {}
local PC = HDG.ProjectsController

local A = HDG.Constants.ACTIONS

-- ===== helpers =============================================================
-- Projects-scoped shorthand over the shared setter -- 20 call sites earn the
-- alias. It used to dispatch UI_SET_TRANSIENT itself, as did the Layouts
-- controller, which is how two views of one tab start disagreeing about the
-- payload shape.
local function _dispatchTransient(key, value)
    HDG.ControllerHelpers.Mechanics.SetUITransientView("projects", key, value)
end
-- Switch the rendered top-level view. Uses UI_SET_PERSISTENT (same as NavController.setView).
-- UI_SET_VIEW writes session.ui.view which the window does NOT render.
local function _setView(view)
    HDG.Store:Dispatch({ type = A.UI_SET_PERSISTENT, payload = { key = "view", value = view } })
end

-- Active layout from projects.activeVersionID selector. Returns (layoutID, view)
-- where view = the materialized placement map (LayoutView), or nil,nil.
local function _activeVersion()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local lid   = HDG.Selectors:Call("projects.activeVersionID", state, {})
    if not lid then return nil, nil end
    return lid, HDG.StoreFurnishings.LayoutView(state, lid)
end

-- ===== Version switcher: switch / branch / delete house versions ==============
local function _branchWhatIf(houseID, basedOn)
    if not (houseID and basedOn) then return end
    local tabs, n = HDG.Selectors:Call("projects.versionTabs", HDG.Store:GetState(), {}), 0  -- exception(false-positive): top-level controller helper, not a row factory
    for _, v in ipairs(tabs) do if not v.isCurrent then n = n + 1 end end
    HDG.Store:Dispatch({ type = A.PROJECTS_CREATE_VERSION, payload = {
        houseID = houseID,   -- versionID minted reducer-side from the counter
        name = "What-if " .. (n + 1), basedOn = basedOn, createdAt = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time()
    HDG.Log:Success("projects_save", "What-if " .. (n + 1) .. " created (copy of current)")
end
local function _deleteWhatIf(houseID, versionID, name)
    if not (houseID and versionID) then return end
    HDG.ControllerHelpers.Mechanics.ConfirmDeleteVersion(houseID, versionID, name,
        function() HDG.Log:Info("projects_action", "Design version deleted") end)
end
-- Build + show the version menu: a radio per version (switch on pick), then New / Delete.
local function _openVersionMenu(owner)
    local tabs = HDG.Selectors:Call("projects.versionTabs", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller helper, not a row factory
    if #tabs == 0 then return end   -- no house captured yet
    local houseID = tabs[1].houseID
    local activeVid, activeIsCurrent, activeName
    local items = { { isTitle = true, text = "House version" } }
    for _, v in ipairs(tabs) do
        if v.isActive then activeVid, activeIsCurrent, activeName = v.versionID, v.isCurrent, v.name end
        local vid = v.versionID
        items[#items + 1] = { kind = "radio", text = v.name .. (v.isCurrent and "  (Live)" or ""),
            selected = v.isActive, value = vid,
            callback = function()
                HDG.Store:Dispatch({ type = A.PROJECTS_SET_ACTIVE_VERSION, payload = { houseID = houseID, versionID = vid } })
            end }
    end
    items[#items + 1] = { isDivider = true }
    items[#items + 1] = { text = "New what-if (copy current)", callback = function() _branchWhatIf(houseID, activeVid) end }
    if not activeIsCurrent then
        items[#items + 1] = { text = "Delete this what-if", callback = function() _deleteWhatIf(houseID, activeVid, activeName) end }
    end
    HDG.UI.ShowMenu(owner, items)
end
-- New what-if: branch from live version (designing never touches reality).
local function _newWhatIfFromPicker()
    local tabs = HDG.Selectors:Call("projects.versionTabs", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller helper, not a row factory
    if #tabs == 0 then return end
    local houseID = tabs[1].houseID
    local liveVid
    for _, v in ipairs(tabs) do if v.isCurrent then liveVid = v.versionID end end
    _branchWhatIf(houseID, liveVid)
end

-- What-if floor count: layout.numFloors if set, else scan placement floors.
local function _whatIfFloorCount(lid, view)
    local layout = lid and HDG.Store:GetState().account.projects.layouts[lid]  -- exception(false-positive): top-level controller read
    if layout and layout.numFloors then return layout.numFloors end
    local maxFloor = 1
    for _, room in pairs(view or {}) do
        if room.floor and room.floor > maxFloor then maxFloor = room.floor end
    end
    return maxFloor
end
-- Dispatch a floor-count change for the active what-if layout (clamped 1..3 here too).
local function _setWhatIfFloors(delta)
    local lid, view = _activeVersion()
    if not lid then return end
    local n = math.max(1, math.min(3, _whatIfFloorCount(lid, view) + delta))
    HDG.Store:Dispatch({ type = A.PROJECTS_SET_VERSION_FLOORS, payload = { versionID = lid, numFloors = n } })
end

-- Resolve which house a new design targets WITHOUT requiring you to stand inside it:
--   1. the currently-focused house (if you've already picked one), else
--   2. your current faction's owned house -- identity minted from session.house.ownedHouses
--      using the SAME (neighborhoodName:plotID) hash capture/CurrentHouseID mint, so a
--      pre-capture design unifies with a later capture under one houseID, else
--   3. a synthetic "scratch" house (own no plot yet -> still mock up a layout you don't own).
-- Returns houseID, displayName.
local function _resolveDesignHouse()
    local state = HDG.Store:GetState()
    local focusedID = HDG.Selectors:Call("projects.activeHouseID", state, {})  -- exception(false-positive): top-level controller helper, not a row factory
    if focusedID then
        local h = state.account.projects.houses[focusedID]
        return focusedID, (h and h.name) or "My House"
    end
    local IDs   = HDG.Projects.IDs
    local myFac = _G.UnitFactionGroup and _G.UnitFactionGroup("player") or nil  -- exception(boundary): Blizzard API
    local pick, fallback
    for _, h in pairs(state.session.house.ownedHouses) do
        if h.name and h.plotID then
            fallback = fallback or h
            if myFac and h.faction == myFac then pick = h; break end
        end
    end
    pick = pick or fallback
    if pick then
        return IDs.makeHouseID(IDs.hashToken(pick.name .. ":" .. tostring(pick.plotID))),
               pick.houseName or pick.name or "My House"
    end
    return IDs.makeHouseID(IDs.hashToken("scratch")), "Scratch Design"
end

-- Start new design: target the focused / current-faction house -- NO "be inside" gate.
-- The data model keys houses by a (name:plotID) hash and already supports uncaptured
-- houses (focus stub + empty canvas). FOCUS_HOUSE makes the target the Architect's
-- active house; CREATE_VERSION(basedOn=nil) mints an empty "from scratch" version.
local function _startNewDesign()
    local houseID, houseName = _resolveDesignHouse()
    HDG.Store:Dispatch({ type = A.PROJECTS_UPSERT_HOUSE, payload = { houseID = houseID, fields = { name = houseName } } })
    HDG.Store:Dispatch({ type = A.PROJECTS_FOCUS_HOUSE,  payload = { houseID = houseID } })
    local tabs, n = HDG.Selectors:Call("projects.versionTabs", HDG.Store:GetState(), {}), 0  -- exception(false-positive): top-level controller helper, not a row factory
    for _, v in ipairs(tabs) do if not v.isCurrent then n = n + 1 end end
    HDG.Store:Dispatch({ type = A.PROJECTS_CREATE_VERSION, payload = {
        houseID = houseID,   -- versionID minted reducer-side from the counter
        name = "Design " .. (n + 1), basedOn = nil, createdAt = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time()
    _setView("projectsArchitect")
    HDG.Log:Success("projects_save", "New design started for " .. (houseName or "your house"))
end

-- ===== Place a room: find a collision-free cell, then dispatch LAYOUT_PLACE. ====
-- Occupied cells on a floor -> HDG.Projects.FloorMap (the SSoT collision +
-- projection derivation, shared with the canvas render + drag/move guard).
local function _occupiedCells(rooms, floor) return HDG.Projects.FloorMap.OccupiedCells(rooms, floor) end
-- A room occupies the same x,y on floor .. floor+span-1 (span=1 for single-floor);
-- the footprint must be clear on every floor it spans. nil when the grid is full.
local function _findFreeCellSpanning(rooms, floor, shape, span)
    local mask = HDG.Projects.ShapeAtlas.GetMask(shape)
    local occ = {}
    for i = 0, span - 1 do occ[i] = _occupiedCells(rooms, floor + i) end
    for y = 0, 40 do
        for x = 0, 40 do
            local clear = true
            for _, m in ipairs(mask) do
                local k = (x + m[1]) .. "," .. (y + m[2])
                for i = 0, span - 1 do if occ[i][k] then clear = false; break end end
                if not clear then break end
            end
            if clear then return x, y end
        end
    end
    return nil  -- no free cell across the span -> caller declines to place
end
-- Place a room: ONE record on the selected floor. The PLANNER mirrors the in-game
-- placement ACTION: placing a stair shape creates two storeys at once, so the
-- planned record carries floors = GetPlannedSpan (2 for stairs, 3 for gardens) --
-- while CAPTURED stair rooms arrive as one section per floor with span 1
-- (sections model, solver spec SS10). FloorMap projects the planned span up.
local function _placePlannedRoom(shape)
    if shape == "entry" then return end   -- Entry is the anchor room; never placed
    -- What-if mode only: palette hidden on Live; this is defense-in-depth.
    if not HDG.Selectors:Call("projects.isWhatIfMode", HDG.Store:GetState(), {}) then return end  -- exception(false-positive): top-level controller helper, not a row factory
    local vid, version = _activeVersion()
    if not version then return end
    local SA    = HDG.Projects.ShapeAtlas
    local floor = HDG.Store:GetState().session.ui.projects.selectedFloor  -- exception(false-positive): top-level controller read
    local span  = SA.GetPlannedSpan(shape)
    if floor + span - 1 > 3 then return end   -- the span would exceed the 3-floor cap
    local x, y = _findFreeCellSpanning(version, floor, shape, span)
    if not x then return end   -- exception(nullable): no cell free across the span
    -- v7: placed shapes are unassigned slot placements (doodles); identity
    -- attaches later via the right panel ("which room?").
    HDG.Store:Dispatch({ type = A.LAYOUT_PLACE, payload = {
        layoutID = vid, shape = shape, floor = floor, x = x, y = y, rotation = 0,
        floors = (span > 1) and span or nil,
    } })
end

-- "Expand Stairwell up": grow a stairwell one floor (the in-game push-up). Single
-- record -> just bump its `floors` override (capped at the 3-floor house limit), if
-- the cell directly above is clear. FloorMap projects the new span automatically.
function PC:ExpandStackUp(roomID)
    local vid, view = _activeVersion()
    if not (vid and view) then return end
    local SA   = HDG.Projects.ShapeAtlas
    local room = view[roomID]
    if not room then return end
    local span     = room.floors or SA.GetFloors(room.shape)
    local topFloor = room.floor + span - 1
    if topFloor + 1 > 3 then return end   -- 3-floor cap

    -- Cell directly above must be clear (exclude self).
    local cells = SA.GetCells(room.shape)
    local mask  = SA.RotateMask(SA.GetMask(room.shape), room.cell.rotation or 0, cells[1], cells[2])
    local occ   = HDG.Projects.FloorMap.OccupiedCells(view, topFloor + 1, { [roomID] = true })
    for _, m in ipairs(mask) do
        if occ[(room.cell.x + m[1]) .. "," .. (room.cell.y + m[2])] then return end   -- blocked above
    end

    HDG.Store:Dispatch({ type = A.LAYOUT_MOVE,
        payload = { layoutID = vid, key = roomID, floors = span + 1 } })
end

-- Kick the multi-floor capture sweep; surface its failure reason.
-- Plan <-> Section. Transient (per-view bucket), so it resets to plan on reload:
-- the section view is for reading the house, the plan is for building it.
local function _toggleCanvasMode()
    local mode = HDG.Store:GetState().session.ui.projects.canvasMode  -- exception(false-positive): top-level controller read, not a row factory
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.UI_SET_TRANSIENT,
        payload = { view = "projects", key = "canvasMode",
                    value = (mode == "plan") and "section" or "plan" },
    })
end

local function _captureHouse()
    -- Capture sweeps the house you're STANDING IN -- a mismatched focus would
    -- silently capture the wrong house (or nothing). Fail loud at the click.
    local current = HDG.HousingObserver:CurrentHouseID()
    local focused = HDG.Selectors:Call("projects.activeHouseID", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller helper, not a row factory
    if current and focused and current ~= focused then
        HDG.Log:Warn("projects_action",
            "Capture works on the house you're standing in -- switch the house dropdown back, or travel to the focused house first")
        return
    end
    local ok, err = HDG.HousingObserver:CaptureAllFloors()
    if ok then
        -- Async sweep: completion ack fires from HousingObserver's _stepSweep.
        HDG.Log:Info("projects_action", "Capturing house -- sweeping floors...")
    elseif _G.UIErrorsFrame then
        _G.UIErrorsFrame:AddMessage("Projects: " .. tostring(err), 1, 0.3, 0.3)   -- exception(boundary): Blizzard toast
    end
end


-- ===== Floor-tab chip + category rail ==============================================
HDG.ChipStrip:RegisterCellKind("projectsFloorChip", {
    constructor = function(parent, cfg) return HDG.ChipStrip:DefaultChipConstructor(parent, cfg) end,
    binder = function(chip, item, _cfg)
        if not item then
            chip:Hide(); chip:SetScript("OnClick", nil); return
        end
        HDG.UI:EnsureChipChrome(chip)
        chip:Show()
        chip:SetText("Floor " .. item.floor)
        HDG.Theme:Register(chip, "Button", { variant = "chip", active = item.isActive })
        chip:RegisterForClicks("LeftButtonUp")
        local floor = item.floor
        chip:SetScript("OnClick", function() _dispatchTransient("selectedFloor", floor) end)
    end,
    sizer = function(item, cfg)
        return HDG.ChipStrip:DefaultChipSizer({ label = "Floor " .. (item and item.floor or "?") }, cfg)
    end,
})


-- Decor-picker category rail: bare icon (no button box). Click mirrors OnCategoryClicked:
--   BACK -> clear cat+subcat | subcategory -> set subcat | category -> focus cat + reset subcat.
local function _railCellLabel(item)
    if item.isBack then return "Back" end   -- text (no dedicated back atlas yet)
    return item.atlas and ("|A:" .. item.atlas .. ":42:42|a") or (item.name or "")
end
local function _onRailClick(item)
    if item.isBack then
        _dispatchTransient("focusedCategoryID", nil)
        _dispatchTransient("focusedSubcategoryID", nil)
    elseif item.level == "subcategory" then
        -- Real branch, NOT `isAll and nil or id` -- Lua 5.1 trap returns id when isAll (ALL_ID=0 reads as Uncategorized).
        local subID; if not item.isAll then subID = item.id end
        _dispatchTransient("focusedSubcategoryID", subID)
    else  -- category
        local catID; if not item.isAll then catID = item.id end
        _dispatchTransient("focusedCategoryID", catID)
        _dispatchTransient("focusedSubcategoryID", nil)
    end
end
HDG.ChipStrip:RegisterCellKind("projectsRailIcon", {
    constructor = function(parent, cfg) return HDG.ChipStrip:IconChipConstructor(parent, cfg) end,
    binder = function(chip, item, _cfg)
        if not item then
            chip:Hide()
            chip:SetScript("OnClick", nil)
            -- Do NOT clear OnEnter/OnLeave: the chip is hidden (no hover), and clearing
            -- them clobbers TooltipEngine:Attach's once-installed HookScript -> no tooltip
            -- after the chip is re-shown (pooled re-acquire).
            return
        end
        chip:Show()
        chip:SetText(_railCellLabel(item))
        chip:RegisterForClicks("LeftButtonUp")
        chip:SetScript("OnClick", function() _onRailClick(item) end)
        chip._tooltipName = item.isBack and "Back" or item.name
        HDG.TooltipEngine:Attach(chip, function(self) return { title = self._tooltipName } end)
    end,
    sizer = function(item, cfg)
        return HDG.ChipStrip:DefaultChipSizer({ label = _railCellLabel(item) }, cfg)
    end,
})

-- (Bulk-add + style-import menu retired with the workspace rebuild: the source
-- dropdown scopes the grid to a style/list and multi-click plans quantities.)

-- ===== Rooms list (landing) =================================================
-- One pooled row template, two kinds (roomsHeader/room); per-kind paint
-- shows/hides + re-anchors. Identity CRUD lives here (create/rename/delete);
-- contents = Furnishings workspace; space = Architect.

local function _openRoomInArchitect(roomID)
    if not roomID then return end
    -- Floor: the room's placement in the ACTIVE layout (placed rooms only --
    -- an unplaced room just opens the Architect on the current floor).
    local _, view = _activeVersion()
    local selKey = roomID
    for key, rec in pairs(view or {}) do
        if rec.roomID == roomID then
            selKey = key
            _dispatchTransient("selectedFloor", rec.floor)
            break
        end
    end
    _dispatchTransient("selectedRoomID", selKey)
    _setView("projectsArchitect")
end

-- Delete confirm: %s placeholders baked once; name/count via textArgs, roomID
-- via data (one dialog serves every row -- no stale closure).
local function _confirmRoomDelete(roomID, name, spots, layoutCount)
    -- v8 spec: the warning shows SPOTS and LAYOUTS (multi-assign makes them
    -- different numbers). Composed here; the dialog text keeps one %s.
    local where = (spots or 0) .. ((spots or 0) == 1 and " room" or " rooms")
    if (layoutCount or 0) > 1 then where = where .. " across " .. layoutCount .. " layouts" end
    HDG.UI.Confirm({
        id       = "HDGR_PROJECTS_DELETE_FURN_ROOM",
        text     = "Delete design \"%s\"? It is cleared from %s -- those stay as unassigned shapes, and its own pieces are kept in your library.",
        accept   = "Delete", cancel = "Cancel",
        textArg1 = name or "Design", textArg2 = where, data = roomID,
        onAccept = function(_, data)
            HDG.Store:Dispatch({ type = A.FURN_ROOM_DELETE, payload = { roomID = data } })
            HDG.Log:Success("projects_action", "Room deleted -- its pieces are saved in your library")
        end,
    })
end

local function _promptRenameRoom(roomID, currentName)
    _G.StaticPopup_Show("HDGR_PROJECTS_RENAME_ROOM", nil, nil,
        { prefill = currentName, roomID = roomID })   -- prefill: RegisterInputDialog's OnShow seeds the box from it
end

local function _layoutLedgerRow(row)
    HDG.UI:EnsureRowChrome(row)
    local del = CreateFrame("Button", nil, row)
    del:SetSize(16, 16); del:SetPoint("RIGHT", row, "RIGHT", -6, 0); del:RegisterForClicks("LeftButtonUp")
    local dx = del:CreateFontString(nil, "OVERLAY"); HDG.UI.applyFontRole(dx, "body")
    dx:SetPoint("CENTER"); dx:SetText("x"); HDG.Theme:Register(dx, "TextDim")
    row._delBtn = del
    local action = HDG.UI.RowButton(row, "", 110, 18); action:RegisterForClicks("LeftButtonUp")
    row._actionBtn = action
    row._metaFs = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    row._nameFs = HDG.UI.RowText(row, "body", "Text", "LEFT")
    row._ledgerLaidOut = true
end

-- Hide all optional bits; each kind re-shows + re-anchors what it needs.
local function _ledgerClear(row)
    row._metaFs:SetText(""); row._metaFs:Hide()
    row._actionBtn:Hide(); row._actionBtn:SetScript("OnClick", nil)
    row._delBtn:Hide();    row._delBtn:SetScript("OnClick", nil)
    row:SetScript("OnClick", nil)
    row._roomID = nil
end

local function _nameFull(row)
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    row._nameFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
end

-- Room-row glyph: artisanal room chest = empty, prefab variant = furnished
-- (atlas names verified in-game by Vamoose, 2026-06-10).
local function _roomGlyph(hasFurnishings)
    local atlas = hasFurnishings and "house-chest-room-prefab-icon" or "house-chest-room-artisanal-icon"
    if _G.C_Texture and _G.C_Texture.GetAtlasInfo and not _G.C_Texture.GetAtlasInfo(atlas) then
        return ""   -- exception(boundary): atlas absent on this client build -> plain text beats a broken texture
    end
    return ("|A:%s:14:14|a "):format(atlas)
end

local function _paintRoomRow(row, ed)
    HDG.UI.applyFontRole(row._nameFs, "body")
    row._nameFs:SetText(_roomGlyph(ed.decorCount > 0) .. ed.name)
    -- Meta: shape + short numeric fields (set NAMES overflow the caption --
    -- UI review 16 MUST-FIX 3 -- but the landing has no canvas, so the shape
    -- itself belongs here).
    local parts = { ed.shapeLabel }
    if #ed.setChips > 0 then
        parts[#parts + 1] = #ed.setChips .. (#ed.setChips == 1 and " set" or " sets")
    end
    parts[#parts + 1] = ed.decorCount .. " decor"
    parts[#parts + 1] = (ed.spots == 0 and "unplaced")
        or ("in " .. ed.spots .. (ed.spots == 1 and " room" or " rooms"))
    row._metaFs:SetText(table.concat(parts, "  -  ")); row._metaFs:Show()
    row._metaFs:ClearAllPoints(); row._metaFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    row._nameFs:SetPoint("RIGHT", row._metaFs, "LEFT", -8, 0)
    local roomID = ed.roomID
    row._roomID = roomID
    -- Click = select (drives the Rooms rail; Open in Architect lives there).
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function()
        _dispatchTransient("landingRoomID", roomID)
    end)
end

-- Library set row: name + reach meta; right-click Rename / Export / Delete.
local function _confirmSetDelete(setID, name, roomCount)
    HDG.UI.Confirm({
        id       = "HDGR_PROJECTS_DELETE_FURN_SET",
        text     = "Delete set \"%s\"? It is unequipped from %s room(s); the rooms themselves are untouched.",
        accept   = "Delete", cancel = "Cancel",
        textArg1 = name or "Set", textArg2 = tostring(roomCount or 0), data = setID,
        onAccept = function(_, data)
            if data then
                HDG.Store:Dispatch({ type = A.FURN_SET_DELETE, payload = { setID = data } })
                HDG.Log:Info("projects_action", "Furnishing set deleted")
            end
        end,
    })
end

local function _exportSet(setID)
    local set = HDG.Store:GetState().account.furnishingSets[setID]  -- exception(nullable): stale row
    if not set then return end
    local code = HDG.Projects.CrateCodec.Encode({ name = set.name, decor = set.items })   -- HDGRCRATE: wire format unchanged
    if not code then return end
    local dialog = HDG.UI:CopyDialog()   -- exception(boundary): UI helper may be unbuilt pre-first-open
    if dialog and dialog.Open then dialog:Open("Export set: " .. (set.name or "Furnishings"), code) end
end

-- Open the picker workspace targeting a SET (room-local or library). Back
-- returns to where the picker was opened from (landing by default).
local function _openPickerForSet(setID, returnView)
    if not setID then return end
    _dispatchTransient("pickerReturn", returnView or "projectsLanding")
    _dispatchTransient("pickerCrateID", setID)
    _dispatchTransient("pickerSearch", "")
    _dispatchTransient("pickerSelectedItemID", nil)
    _setView("projectsPicker")
end

local function _paintSetRow(row, ed)
    HDG.UI.applyFontRole(row._nameFs, "body")
    -- Chest glyph differentiates set rows from room rows at a glance.
    row._nameFs:SetText("|A:house-chest-icon:12:12|a " .. ed.name)
    local reach = (ed.roomCount == 0 and "not equipped anywhere")
        or ("in " .. ed.roomCount .. (ed.roomCount == 1 and " room" or " rooms"))
    row._metaFs:SetText(ed.pieces .. (ed.pieces == 1 and " piece" or " pieces") .. "  -  " .. reach)
    row._metaFs:Show()
    row._metaFs:ClearAllPoints(); row._metaFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    row._nameFs:SetPoint("RIGHT", row._metaFs, "LEFT", -8, 0)
    local setID = ed.setID
    -- Click = select (drives the Sets rail; Edit/Rename/Export/Delete live there).
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function()
        _dispatchTransient("landingSetID", setID)
    end)
end

local function _paintLedgerRow(row, ed, template)
    -- (Section headers live OUTSIDE the boxes now -- fixed chrome="card" bands.)
    HDG.Theme:Register(row, "RowChrome", { selected = ed.isSelected == true })
    _ledgerClear(row)
    if ed.kind == "set" then
        _paintSetRow(row, ed)
    else  -- room
        _paintRoomRow(row, ed)
    end
    row:SetHeight(template.height)
end

local function _ledgerRowFactory(template)
    return {
        Configure = function(row, ed)
            if not row._ledgerLaidOut then _layoutLedgerRow(row) end
            _paintLedgerRow(row, ed, template)
        end,
        Reset = function(row)
            HDG.UI.ClearRowText(row, "_nameFs", "_metaFs")
            if row._actionBtn then row._actionBtn:SetScript("OnClick", nil) end
            if row._delBtn then row._delBtn:SetScript("OnClick", nil) end
            if row.SetScript then row:SetScript("OnClick", nil) end  -- exception(false-positive): Frame always has SetScript; mock-fidelity guard
            row._roomID = nil
        end,
    }
end

HDG.Rows:Register("projectsLedgerRow", {
    font = "body", height = 24, factory = _ledgerRowFactory,
    key  = function(ed)
        if not ed then return "ledger:?" end
        return "ledger:" .. tostring(ed.kind) .. ":" .. tostring(ed.setID or ed.roomID or "")
    end,
})

-- Resolve the selection transient to the DESIGN id it denotes. v8 canvas
-- selections are SLOT KEYS (the design rides as the placement's roomID tag);
-- landing flows still pass design ids. Mirrors the selectors' _selectedRoom
-- resolver -- handlers must NEVER treat the raw transient as a design id
-- (Equip set / Add decor / Unequip / copy-here all silently no-opped on
-- canvas selections until review 17's follow-up).
local function _selectedDesignID()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local key = state.session.ui.projects.selectedRoomID
    if not key then return nil end
    local _, view = _activeVersion()
    local rec = view and view[key]
    local rid = (rec and rec.roomID) or key
    if state.account.rooms[rid] then return rid end
    return nil   -- exception(nullable): bare slots / stale selections denote no design
end

-- ===== Equip-a-set menu (Architect detail + workspace) ======================
local function _openEquipMenu(owner)
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local roomID = _selectedDesignID()
    local room   = roomID and state.account.rooms[roomID]   -- exception(nullable): resolver already vetted; belt for stale state
    if not room then return end
    local equipped = {}
    for _, sid in ipairs(room.furnishingSetIDs) do equipped[sid] = true end
    local items = {}
    for sid, set in pairs(state.account.furnishingSets) do
        if not set.isLocal and not equipped[sid] then
            local nm = set.name or "Set"
            items[#items + 1] = { text = nm, callback = function()
                HDG.Store:Dispatch({ type = A.FURN_ROOM_EQUIP,
                    payload = { roomID = roomID, setID = sid } })
                HDG.Log:Success("projects_save", ("\"%s\" equipped -- edits to the set reach every room using it"):format(nm))
            end }
        end
    end
    table.sort(items, function(a2, b2) return a2.text < b2.text end)
    if #items == 0 then
        HDG.Log:Info("projects_action", "No sets to equip -- \"Save as Set\" in the decor picker creates one")
        return
    end
    HDG.UI.ShowMenu(owner, items)
end

-- ===== Effective-furnishings rows (setHeader / item; provenance grouped) ====
-- One pooled template, two kinds. setHeader carries the provenance (set name +
-- total; Unequip on library sets). item rows: steppers ONLY on the room's own
-- pieces -- library contents change via the set, not the room (spec rule 2).
local function _layoutFurnRow(row)
    HDG.UI:EnsureRowChrome(row)
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)
    icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    icon:SetSize(18, 18)
    row._iconTex = icon
    -- Quantity stepper [- nn +] at the right edge. Button frames capture their own
    -- clicks so +/- don't trigger the row select. Defaults: rightInset=-4, size=16.
    HDG.UI.WireStepperCluster(row)
    local unequip = HDG.UI.RowButton(row, "Unequip", 64, 18)
    unequip:SetPoint("RIGHT", row, "RIGHT", -6, 0); unequip:RegisterForClicks("LeftButtonUp")
    row._unequipBtn = unequip
    local cnt = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    cnt:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._cntFs = cnt
    row._nameFs = HDG.UI.RowText(row, "body", "Text", "LEFT")
end

local function _furnRowClear(row)
    row._iconTex:Hide()
    row._plusBtn:Hide();  row._plusBtn:SetScript("OnClick", nil)
    row._minusBtn:Hide(); row._minusBtn:SetScript("OnClick", nil)
    row._qtyFs:SetText("")
    row._unequipBtn:Hide(); row._unequipBtn:SetScript("OnClick", nil)
    row._cntFs:SetText(""); row._cntFs:Hide()
    row:SetScript("OnClick", nil)   -- header rows wire a fold toggle; items must not inherit it
    row._setID, row._decorID = nil, nil
end

local function _paintFurnHeader(row, ed)
    HDG.UI.applyFontRole(row._nameFs, "caption")
    -- Library groups fold on click; the marker telegraphs it.
    local marker = ed.isLocal and "" or HDG.UI.CollapsePrefix(ed.collapsed)
    row._nameFs:SetText(marker .. ed.name .. "  (" .. ed.count .. ")")
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    if ed.isLocal then
        row._nameFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    else
        local setID = ed.setID
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function()
            HDG.Store:Dispatch({ type = A.PROJECTS_FURN_TOGGLE_COLLAPSE,
                payload = { setID = setID } })
        end)
        row._unequipBtn:Show()
        row._nameFs:SetPoint("RIGHT", row._unequipBtn, "LEFT", -8, 0)
        row._unequipBtn:SetScript("OnClick", function()
            local roomID = _selectedDesignID()
            if roomID then
                HDG.Store:Dispatch({ type = A.FURN_ROOM_UNEQUIP,
                    payload = { roomID = roomID, setID = setID } })
                HDG.Log:Info("projects_action", "Set unequipped -- the set itself is untouched in your library")
            end
        end)
    end
end

local function _paintFurnItem(row, ed)
    HDG.UI.applyFontRole(row._nameFs, "body")
    row._nameFs:SetText(ed.name or ("item " .. tostring(ed.decorID)))
    -- ed.icon stamped by the selector (NOT resolved here) so the async-load ->
    -- session.itemNames.names -> selector re-run -> re-bind cycle works.
    if ed.icon then row._iconTex:SetTexture(ed.icon); row._iconTex:Show() end
    row._setID, row._decorID = ed.setID, ed.decorID
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT", row._iconTex, "RIGHT", 6, 0)
    if ed.isLocal then
        -- Stepper: + = +1 (FURN_SET_ITEM_ADD no-count increments); - = -1 (removes at 0).
        row._qtyFs:SetText(tostring(ed.count))
        row._plusBtn:Show(); row._minusBtn:Show()
        row._nameFs:SetPoint("RIGHT", row._minusBtn, "LEFT", -6, 0)
        row._plusBtn:SetScript("OnClick", function()
            if not (row._setID and row._decorID) then return end
            HDG.Store:Dispatch({ type = A.FURN_SET_ITEM_ADD,
                payload = { setID = row._setID, itemID = row._decorID } })
        end)
        row._minusBtn:SetScript("OnClick", function()
            if not (row._setID and row._decorID) then return end
            HDG.Store:Dispatch({ type = A.FURN_SET_ITEM_REMOVE,
                payload = { setID = row._setID, itemID = row._decorID } })
        end)
    else
        row._cntFs:SetText("x" .. tostring(ed.count)); row._cntFs:Show()
        row._nameFs:SetPoint("RIGHT", row._cntFs, "LEFT", -6, 0)
    end
end

HDG.Rows:Register("projectsFurnRow", {
    font = "body", height = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutFurnRow,
        paint      = function(row, ed)
            _furnRowClear(row)
            if ed.kind == "setHeader" then _paintFurnHeader(row, ed)
            else _paintFurnItem(row, ed) end
        end,
        laidOutTag = "_furnLaidOut",
        resetText  = { "_nameFs", "_qtyFs", "_cntFs" },
        reset      = _furnRowClear,
    }),
    key = function(ed)
        if not ed then return "furn:?" end
        return "furn:" .. tostring(ed.kind) .. ":" .. tostring(ed.setID) .. ":" .. tostring(ed.decorID or "")
    end,
})

-- ===== Assign row ("which room?" offer for an unassigned slot) ==============
local function _layoutAssignRow(row)
    HDG.UI:EnsureRowChrome(row)
    HDG.UI.LayoutNameMetaRow(row, { leftInset = 8, gap = 8 })  -- hygiene A10
end

local function _paintAssignRow(row, ed)
    HDG.Theme:Register(row, "RowChrome", { selected = false })
    row._nameFs:SetText(ed.name)
    row._metaFs:SetText(ed.noShape and "new -- takes this shape"
        or (ed.hereCount > 0 and ("already " .. ed.hereCount .. " here"))
        or (ed.layouts == 0 and "unplaced"
        or ("in " .. ed.layouts .. (ed.layouts == 1 and " layout" or " layouts"))))
    local layoutID, slotKey, roomID, name = ed.layoutID, ed.slotKey, ed.roomID, ed.name
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = A.LAYOUT_ASSIGN,
            payload = { layoutID = layoutID, slotKey = slotKey, roomID = roomID } })
        -- v8: the slot key is stable -- keep it selected (panel flips to room state).
        HDG.Log:Success("projects_save", ("Assigned \"%s\" to this room"):format(name))
    end)
end

HDG.Rows:Register("projectsAssignRow", {
    font = "body", height = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutAssignRow,
        paint      = _paintAssignRow,
        laidOutTag = "_assignLaidOut",
        resetText  = { "_nameFs", "_metaFs" },
        reset      = function(row) row:SetScript("OnClick", nil) end,
    }),
    key = function(ed) return "assign:" .. tostring(ed and ed.roomID or "?") end,
})

-- v7: a room's working container is its LOCAL furnishing set -- created
-- implicitly on first use (the "+ Add Crate" ceremony is gone; this helper is
-- the implicit-create seam used by the button AND the picker open).
local function _ensureLocalSet(roomID)
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local room  = roomID and state.account.rooms[roomID]   -- exception(nullable): slot keys / stale selection have no room
    if not room then return nil end
    for _, sid in ipairs(room.furnishingSetIDs) do
        local s = state.account.furnishingSets[sid]
        if s and s.isLocal and s.ownerRoom == roomID then return sid end
    end
    HDG.Store:Dispatch({ type = A.FURN_SET_CREATE, payload = {
        name = ((room.name and room.name ~= "" and room.name) or "Design") .. " furnishings",
        isLocal = true, ownerRoom = roomID, ts = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time()
    local sid = HDG.Store:GetState().session.furn.lastSetID  -- exception(false-positive): top-level controller read
    HDG.Store:Dispatch({ type = A.FURN_ROOM_EQUIP, payload = { roomID = roomID, setID = sid } })
    return sid
end
-- ===== Curation-panel one-clicks (build plan 2.2) ===========================

-- "+ New room here": create-in-place from the selected unassigned slot --
-- the room mints with the slot's shape + placement, assigned immediately.
local function _newRoomHere()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local key   = state.session.ui.projects.selectedRoomID
    local lid, view = _activeVersion()
    local slot  = key and view and view[key]
    if not (slot and slot.unassigned and lid) then return end
    _G.StaticPopup_Show("HDGR_PROJECTS_NEW_ROOM_HERE", nil, nil,
        { layoutID = lid, slotKey = key, shape = slot.shape, name = slot.capturedName })
end

-- Fork: make the SELECTED room its own design. Placement-scoped -- the old
-- duplicate-swap retagged EVERY spot the design held in the layout, which
-- multi-assign made wrong (both octagons flipped together). Library sets
-- stay shared by reference; own pieces clone; only THIS spot retags.
local function _forkSelectedSpot()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local key   = state.session.ui.projects.selectedRoomID
    local lid, view = _activeVersion()
    local rec   = key and view and view[key]
    local srcID = rec and rec.roomID
    if not (srcID and lid) then return nil end
    HDG.Store:Dispatch({ type = A.FURN_ROOM_DUPLICATE,
        payload = { roomID = srcID, ts = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time()
    local copyID = HDG.Store:GetState().session.furn.lastRoomID  -- exception(false-positive): top-level controller read
    if not copyID then return nil end
    HDG.Store:Dispatch({ type = A.LAYOUT_ASSIGN,
        payload = { layoutID = lid, slotKey = key, roomID = copyID } })
    local name = HDG.Store:GetState().account.rooms[copyID].name  -- exception(false-positive): top-level controller read
    HDG.Log:Success("projects_save",
        ('Forked -- this room is now "%s"; the original keeps its other rooms'):format(name))
    return copyID
end

-- Picker "Make a copy just here": fork + retarget the picker to the copy.
local function _editCopyHere()
    return _forkSelectedSpot()
end

-- (Swap-room menu removed with its button: remove-placement + the assign
-- offer covers re-pointing; LAYOUT_SWAP_ROOM remains the duplicate engine.)

-- v7 "Save for Later": promote the room's local set to the library (it stays
-- equipped; the room keeps its furnishings -- the set just becomes reusable).
local function _detachCrate()
    local cd = HDG.Selectors:Call("projects.crateDetail", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller helper, not a row factory
    if cd.hasCrate and cd.crateID then
        HDG.Store:Dispatch({ type = A.FURN_SET_PROMOTE,
            payload = { setID = cd.crateID } })
        HDG.Log:Success("projects_save", "Furnishings saved to the library (still equipped here)")
    end
end

-- ===== Decor picker card (Variant A grid) ===================================
-- Gestures route to the room's local set: hover = 3D preview + info line;
-- left-click = +1; right-click = -1 (0 removes); shift-right-click = remove
-- entirely. The planned-count badge is the only chrome on the card.
local function _pickerCardAdjust(itemID, actionType, all)
    local setID = HDG.Store:GetState().session.ui.projects.pickerCrateID  -- exception(false-positive): top-level handler read
    if setID and itemID then
        HDG.Store:Dispatch({ type = actionType,
            payload = { setID = setID, itemID = itemID, all = all } })
    end
end

HDG.CardGrid:RegisterCellKind("projectsPickerCard", {
    template = "Button",
    initFunc = function(cell, ed, cfg)
        HDG.CardGrid:EnsureDefaultAnatomy(cell, cfg)
        cell:Show()
        HDG.CardGrid:PaintIcon(cell, ed.iconTexture, ed.iconAtlas)
        if cell.icon then   -- unowned reads dimmed; PaintIcon resets both on reuse
            cell.icon:SetDesaturated(not ed.owned)
            cell.icon:SetAlpha(ed.owned and 1 or 0.45)
        end
        HDG.CardGrid:PaintSelected(cell, false)
        -- Planned-count badge (absent at 0).
        HDG.CardGrid:PaintMemberBadge(cell, ed.plannedCount > 0 and ed.plannedCount or nil)
        if cell.label then cell.label:Hide() end   -- name lives in the hover info line
        local itemID = ed.itemID
        cell._hdgrItemID = itemID   -- resetFunc unpins the preview if reclaimed mid-hover
        HDG.UI.WireLeftRightClick(cell, function()
            _pickerCardAdjust(itemID, A.FURN_SET_ITEM_ADD)
        end, function()
            _pickerCardAdjust(itemID, A.FURN_SET_ITEM_REMOVE, _G.IsShiftKeyDown and _G.IsShiftKeyDown() or nil)  -- exception(boundary): IsShiftKeyDown absent in headless harness
        end)
        cell:SetScript("OnEnter", function(self_)
            if self_.hoverBg then self_.hoverBg:Show() end
            _dispatchTransient("pickerSelectedItemID", itemID)
        end)
        cell:SetScript("OnLeave", function(self_)
            if self_.hoverBg then self_.hoverBg:Hide() end
        end)
    end,
    resetFunc = function(_pool, cell)
        cell:SetScript("OnClick", nil)
        cell:SetScript("OnEnter", nil)
        cell:SetScript("OnLeave", nil)
        if cell.hoverBg then cell.hoverBg:Hide() end
        -- Fast scroll can reclaim a hovered cell WITHOUT OnLeave -- don't leave
        -- the info line + 3D preview pinned to a card that scrolled away.
        if cell._hdgrItemID
           and HDG.Store:GetState().session.ui.projects.pickerSelectedItemID == cell._hdgrItemID then  -- exception(false-positive): pool reset callback, not a row factory
            _dispatchTransient("pickerSelectedItemID", nil)
        end
        cell._hdgrItemID = nil
    end,
})

-- ===== Room picker list row: blueprint icon + name + cost; click places =====

-- Tooltip: footprint/height/doors/weight + live budget preview "Rooms: N -> N / max".
-- HookScript on row so one Attach covers all pooled binds (reads live row._shape).
local function _roomRowTooltipDef(row)
    local SA, shape = HDG.Projects.ShapeAtlas, row._shape
    if not shape then return nil end   -- pooled row not bound to a shape -> no tooltip
    local dims, cells, doors = SA.GetDims(shape), SA.GetCells(shape), SA.GetDoors(shape)
    local weight, lines = SA.GetBudget(shape), {}
    if dims and cells then
        lines[#lines + 1] = { text = string.format("%d x %d yd  (%d x %d cells)", dims[1], dims[2], cells[1], cells[2]), r = 0.82, g = 0.82, b = 0.82 }
        lines[#lines + 1] = { text = string.format("%d yd tall", dims[3]), r = 0.68, g = 0.68, b = 0.68 }
    end
    if doors and #doors > 0 then
        lines[#lines + 1] = { text = "Doors: " .. table.concat(doors, " "), r = 0.68, g = 0.68, b = 0.68 }
    end
    lines[#lines + 1] = { text = "Placement weight: " .. weight, r = 0.82, g = 0.82, b = 0.82 }
    local bud = HDG.Selectors:Call("projects.roomBudget", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller helper, not a row factory
    if bud.max > 0 then
        local newCost, over = bud.cost + weight, (bud.cost + weight) > bud.max
        lines[#lines + 1] = { text = string.format("Rooms: %d -> %d / %d", bud.cost, newCost, bud.max),
                              r = over and 0.95 or 0.55, g = over and 0.6 or 0.9, b = 0.45 }
    end
    lines[#lines + 1] = { text = "Click to place", r = 0.55, g = 0.78, b = 1 }
    return { title = SA.GetLabel(shape), extraLines = lines }
end
local function _layoutRoomRow(row)
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)   -- shape blueprint glyph
    icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    icon:SetSize(40, 40)
    row._iconTex = icon
    local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -2)
    name:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._nameFs = name
    local cost = HDG.UI.RowText(row, "caption", "TextDim", "LEFT")
    cost:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
    cost:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._costFs = cost
    HDG.TooltipEngine:Attach(row, _roomRowTooltipDef)   -- once; reads live row._shape
end
-- (Palette rows, NOT the landing ledger rows -- that painter is _paintRoomRow
-- above; this one was shadowing it under the same name until review 17.)
local function _paintPaletteRoomRow(row, ed)
    row._nameFs:SetText(ed.label)
    row._costFs:SetText("cost " .. tostring(ed.budget))
    if ed.atlas then row._iconTex:SetAtlas(ed.atlas, false); row._iconTex:Show() else row._iconTex:Hide() end
    row._shape = ed.shape
end
local function _wireRoomRow(row)
    row:SetScript("OnClick", function(self) _placePlannedRoom(self._shape) end)
end
HDG.Rows:Register("projectsRoomListRow", {
    font = "body", height = 48,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutRoomRow,
        paint      = _paintPaletteRoomRow,
        laidOutTag = "_roomRowLaidOut",
        clicks     = "LeftButtonUp",
        wire       = _wireRoomRow,
        resetText  = { "_nameFs", "_costFs" },
        reset      = function(row)
            row._iconTex:Hide()
            row._shape = nil
        end,
    }),
    key = function(ed) return "room:" .. tostring(ed and ed.shape or "?") end,
})

-- ===== Room shopping-list row: "+N shape wt" (build) / "-N shape wt" (remove) ===
local function _layoutShoppingRow(row)
    local wt = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    wt:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._wtFs = wt
    local name = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", 6, 0)
    name:SetPoint("RIGHT", wt, "LEFT", -4, 0)
    row._nameFs = name
end
local function _paintShoppingRow(row, ed)
    HDG.Theme:Register(row._nameFs, "Text")
    local prefix = (ed.kind == "build") and "+" or "-"
    local cc = HDG.Theme:ColorCode(ed.kind == "build" and "semantic.success" or "semantic.warning")
    row._nameFs:SetText(cc .. prefix .. ed.count .. "  " .. ed.label .. "|r")
    -- Room weight wears the same atlas as the title bar's room budget (90/95),
    -- so the number reads as "costs this much of THAT" without a unit word.
    row._wtFs:SetText("|A:house-room-limit-icon:12:12|a " .. ed.weight)
end
HDG.Rows:Register("projectsShoppingRow", {
    font = "caption", height = 20,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutShoppingRow,
        paint      = _paintShoppingRow,
        laidOutTag = "_shopLaidOut",
        resetText  = { "_nameFs", "_wtFs" },
    }),
    key = function(ed) return "shop:" .. tostring(ed and (ed.kind .. ":" .. ed.shape) or "?") end,
})

-- Open the picker for the selected room's local set; Back closes it.
local function _openPickerFor(roomID)
    local setID = _ensureLocalSet(roomID)   -- implicit: no ceremony
    if not setID then return end
    _openPickerForSet(setID, "projectsArchitect")
end

-- No interrupt (review 15 follow-up): the picker opens immediately; shared
-- rooms get the inline scope indicator + "Make a copy just here" inside the
-- picker right column instead -- the common case pays nothing.
local function _openDecorPicker()
    _openPickerFor(_selectedDesignID())   -- v8: resolve the slot-key selection to its design
end
local function _closeDecorPicker()
    _dispatchTransient("pickerCrateID", nil)
    _setView(HDG.Store:GetState().session.ui.projects.pickerReturn)  -- exception(false-positive): top-level controller read
end

-- ===== Auto-assign (v8 fast-follow; strategy unit 1) ========================
-- One click after a capture: every unassigned room takes the best matching
-- design -- same shape, most decor first (multi-assign makes reuse safe:
-- three closets can all take the one "Basement"). Shapes with no candidate
-- are left alone; the rail ack says exactly what happened.
local function _designDecorCount(state, room)
    local n = 0
    for _, sid in ipairs(room.furnishingSetIDs) do
        local set = state.account.furnishingSets[sid]
        if set then
            for _, it in ipairs(set.items) do n = n + (it.count or 1) end
        end
    end
    return n
end
local function _autoAssign()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller handler
    local lid, view = _activeVersion()
    if not (lid and view) then return end
    -- Best candidate per shape: most decor, then name (deterministic).
    local byShape = {}
    for rid, room in pairs(state.account.rooms) do
        if room.shape then
            local b = byShape[room.shape] or {}
            b[#b + 1] = { rid = rid, n = _designDecorCount(state, room),
                          name = (room.name and room.name ~= "" and room.name) or rid }
            byShape[room.shape] = b
        end
    end
    for _, list in pairs(byShape) do
        table.sort(list, function(a, b2)
            if a.n ~= b2.n then return a.n > b2.n end
            return a.name < b2.name
        end)
    end
    local keys = {}
    for key, rec in pairs(view) do
        if rec.unassigned and rec.shape then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local assigned, skipped, tally = 0, 0, {}
    for _, key in ipairs(keys) do
        local best = byShape[view[key].shape] and byShape[view[key].shape][1]
        if best then
            HDG.Store:Dispatch({ type = A.LAYOUT_ASSIGN,
                payload = { layoutID = lid, slotKey = key, roomID = best.rid } })
            assigned = assigned + 1
            tally[best.name] = (tally[best.name] or 0) + 1
        else
            skipped = skipped + 1
        end
    end
    if assigned == 0 then
        HDG.Log:Info("projects_action", skipped > 0
            and "Auto-assign: no designs match these shapes -- create one and it can fill them all"
            or "Auto-assign: nothing to do -- every room already has a design")
        return
    end
    local parts = {}
    for name, c in pairs(tally) do
        parts[#parts + 1] = c > 1 and (name .. " x" .. c) or name
    end
    table.sort(parts)
    local msg = ("Auto-assigned %d room%s: %s"):format(
        assigned, assigned == 1 and "" or "s", table.concat(parts, ", "))
    if skipped > 0 then msg = msg .. (" -- %d with no matching design"):format(skipped) end
    HDG.Log:Success("projects_save", msg)
end

-- ===== Crate import / export ===============================================
local function _exportCrate()
    local cd = HDG.Selectors:Call("projects.crateDetail", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller helper, not a row factory
    if not cd.hasCrate then return end
    local set  = HDG.Store:GetState().account.furnishingSets[cd.crateID]  -- exception(false-positive): top-level controller read
    local code = HDG.Projects.CrateCodec.Encode({ name = set.name, decor = set.items })   -- HDGRCRATE: wire format unchanged
    if not code then return end
    local dialog = HDG.UI:CopyDialog()   -- exception(boundary): UI helper may be unbuilt pre-first-open
    if dialog and dialog.Open then dialog:Open("Export furnishings: " .. (set.name or "Furnishings"), code) end
end

-- (Merge-into-room import retired: the landing's Import creates a library
-- set, which Equip-to-Room covers without duplicating decor records.)

-- ===== Wire ================================================================
function PC:Wire(rootFrame)
    if not HDG.Log:HasTag("projects_action") then
        HDG.Log:RegisterTabTags("projects")
    end
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.newDesign",      _startNewDesign)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.newWhatIf",      _newWhatIfFromPicker)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.openArchitect",  function() _setView("projectsArchitect") end)
    -- Help workspace: remember where it was opened from; Back returns there.
    local function _openHelp(returnView)
        return function()
            _dispatchTransient("helpReturn", returnView)
            _setView("projectsHelp")
        end
    end
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.help", _openHelp("projectsLanding"))
    HDG.UI.OnClick(rootFrame, "projectsNavPanel.help",     _openHelp("projectsArchitect"))
    HDG.UI.OnClick(rootFrame, "projectsHelpPanel.back", function()
        _setView(HDG.Store:GetState().session.ui.projects.helpReturn)  -- exception(false-positive): top-level controller read
    end)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.newRoom", function()
        _G.StaticPopup_Show("HDGR_PROJECTS_NEW_ROOM")
    end)
    -- Landing rails: act on the box's selected row (buttons gate on selection).
    local function _selLandingRoom()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level handler read
        local rid   = state.session.ui.projects.landingRoomID
        local room  = rid and state.account.rooms[rid]   -- exception(nullable): selection can go stale across deletes
        if not room then return nil end
        local name = (room.name and room.name ~= "" and room.name)
            or (room.shape and HDG.Projects.ShapeAtlas.GetLabel(room.shape)) or "Design"
        local spots, layouts = 0, 0
        for _, c in pairs(state.session.furnIndex.roomLayouts[rid] or {}) do   -- exception(nullable): room may be placed nowhere
            layouts = layouts + 1
            spots   = spots + (type(c) == "number" and c or 1)
        end
        return rid, name, spots, layouts
    end
    local function _selLandingSet()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level handler read
        local sid   = state.session.ui.projects.landingSetID
        local set   = sid and state.account.furnishingSets[sid]   -- exception(nullable): selection can go stale across deletes
        if not (set and not set.isLocal) then return nil end
        local n = 0
        for _ in pairs(state.session.furnIndex.setRooms[sid] or {}) do n = n + 1 end   -- exception(nullable): set may be equipped nowhere
        return sid, set.name or "Set", n
    end
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.roomMore", function(self)
        local rid, name, n, nLayouts = _selLandingRoom()
        if not rid then
            HDG.Log:Info("projects_action", "Select a design first -- click a row above")
            return
        end
        HDG.UI.ShowMenu(self, {
            { text = "Rename",    callback = function() _promptRenameRoom(rid, name) end },
            { text = "Duplicate", callback = function()
                _G.StaticPopup_Show("HDGR_PROJECTS_DUPLICATE_ROOM", nil, nil, { roomID = rid, name = name }) end },
            { text = "Delete",    callback = function() _confirmRoomDelete(rid, name, n, nLayouts) end },
        })
    end)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.roomOpen", function()
        local rid = _selLandingRoom()
        if rid then _openRoomInArchitect(rid) end
    end)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.setEdit", function()
        local sid = _selLandingSet()
        if sid then _openPickerForSet(sid) end
    end)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.newSet", function()
        _G.StaticPopup_Show("HDGR_PROJECTS_NEW_SET")
    end)
    HDG.UI:RegisterInputDialog("HDGR_PROJECTS_NEW_SET", {
        text       = "Name the new furnishing set:",
        accept     = "Create",
        maxLetters = 64,
        onAccept   = function(value)
            if not (value and value ~= "") then return end
            HDG.Store:Dispatch({ type = A.FURN_SET_CREATE, payload = {
                name = value, items = {}, ts = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time absent in headless harness
            local sid = HDG.Store:GetState().session.furn.lastSetID  -- exception(false-positive): top-level handler read
            _dispatchTransient("landingSetID", sid)
            HDG.Log:Success("projects_save", ("Set \"%s\" created -- pick its pieces"):format(value))
            _openPickerForSet(sid)   -- an empty set's next step is always "add pieces"
        end,
    })
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.setEquip", function()
        local sid, setName = _selLandingSet()
        local rid, roomName = _selLandingRoom()
        if not (sid and rid) then return end
        HDG.Store:Dispatch({ type = A.FURN_ROOM_EQUIP, payload = { roomID = rid, setID = sid } })
        HDG.Log:Success("projects_save",
            ("\"%s\" equipped to %s -- edits to the set reach every room using it"):format(setName, roomName))
    end)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.setMore", function(self)
        local sid, name, n = _selLandingSet()
        if not sid then
            HDG.Log:Info("projects_action", "Select a set first -- click a row above")
            return
        end
        HDG.UI.ShowMenu(self, {
            { text = "Rename", callback = function()
                _G.StaticPopup_Show("HDGR_PROJECTS_RENAME_SET", nil, nil, { setID = sid }) end },
            { text = "Export", callback = function() _exportSet(sid) end },
            { text = "Delete", callback = function() _confirmSetDelete(sid, name, n) end },
        })
    end)
    HDG.UI.OnClick(rootFrame, "projectsLandingPanel.importSet", function()
        -- Route to the unified "Import a Build" view (Styles tab) with Project Set preselected.
        -- Handles wowdb/wowhead builds AND HDG set codes (HDGRCRATE:1:); commits as a furnishing set.
        HDG.Store:Dispatch({ type = A.STYLES_IMPORT_RESET })
        HDG.Store:Dispatch({ type = A.STYLES_IMPORT_SET_DESTINATION, payload = { destination = "set" } })
        HDG.Store:Dispatch({ type = A.STYLES_SET_VIEW, payload = { view = "import" } })
        HDG.Store:Dispatch({ type = A.UI_SET_PERSISTENT, payload = { key = "view", value = "styles" } })
    end)
    -- Rooms-list identity dialogs (shared StaticPopups; data carries the roomID).
    HDG.UI:RegisterInputDialog("HDGR_PROJECTS_NEW_ROOM", {
        text       = "Name the new design:",
        accept     = "Create",
        maxLetters = 64,
        onAccept   = function(value)
            if not (value and value ~= "") then return end
            HDG.Store:Dispatch({ type = A.FURN_ROOM_CREATE,
                payload = { name = value, ts = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time absent in headless harness
            HDG.Log:Success("projects_save",
                ("Design \"%s\" created -- it takes a shape when you assign it"):format(value))
        end,
    })
    HDG.UI:RegisterInputDialog("HDGR_PROJECTS_RENAME_ROOM", {
        text       = "Rename design:",
        accept     = "Rename",
        maxLetters = 64,
        onAccept   = function(value, data)
            if not (value and value ~= "" and data and data.roomID) then return end
            HDG.Store:Dispatch({ type = A.FURN_ROOM_RENAME,
                payload = { roomID = data.roomID, name = value } })
        end,
    })
    HDG.UI:RegisterInputDialog("HDGR_PROJECTS_RENAME_SET", {
        text       = "Rename set:",
        accept     = "Rename",
        maxLetters = 64,
        onAccept   = function(value, data)
            if not (value and value ~= "" and data and data.setID) then return end
            HDG.Store:Dispatch({ type = A.FURN_SET_RENAME,
                payload = { setID = data.setID, name = value } })
        end,
    })
    HDG.UI.OnClick(rootFrame, "projectsDetailPanel.equipSet",        function(self) _openEquipMenu(self) end)
    HDG.UI.OnClick(rootFrame, "projectsPickerPreviewPanel.equipSet", function(self) _openEquipMenu(self) end)
    HDG.UI.OnClick(rootFrame, "projectsNavPanel.viewMode",           _toggleCanvasMode)
    HDG.UI.OnClick(rootFrame, "projectsNavPanel.captureAll",         _captureHouse)
    HDG.UI.OnClick(rootFrame, "projectsNavPanel.autoAssign",         _autoAssign)
    HDG.UI.OnClick(rootFrame, "projectsNavPanel.addFloor",           function() _setWhatIfFloors(1) end)
    HDG.UI.OnClick(rootFrame, "projectsNavPanel.removeFloor",        function() _setWhatIfFloors(-1) end)
    HDG.UI.OnClick(rootFrame, "projectsNavPanel.versionMenu",        function(self) _openVersionMenu(self) end)
    HDG.UI.OnClick(rootFrame, "projectsPickerPanel.newWhatIf",       _newWhatIfFromPicker)
    HDG.UI.OnClick(rootFrame, "projectsDetailPanel.detachCrate",     _detachCrate)
    HDG.UI.OnClick(rootFrame, "projectsDetailPanel.addDecor",        _openDecorPicker)
    HDG.UI.OnClick(rootFrame, "projectsDetailPanel.newRoomHere",     _newRoomHere)
    HDG.UI.OnClick(rootFrame, "projectsDetailPanel.forkDesign", _forkSelectedSpot)
    HDG.UI.OnClick(rootFrame, "projectsDetailPanel.unassignRoom", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level handler read
        local key   = state.session.ui.projects.selectedRoomID
        local lid   = HDG.Selectors:Call("projects.activeVersionID", state, {})
        if key and lid then
            HDG.Store:Dispatch({ type = A.LAYOUT_UNASSIGN, payload = { layoutID = lid, key = key } })
            HDG.Log:Info("projects_action", "Design unassigned -- the shape stays, and the design keeps its furnishings")
        end
    end)
    HDG.UI:RegisterInputDialog("HDGR_PROJECTS_DUPLICATE_ROOM", {
        text       = "Name the copy:",
        accept     = "Duplicate",
        maxLetters = 64,
        onAccept   = function(value, data)
            if not (data and data.roomID) then return end
            HDG.Store:Dispatch({ type = A.FURN_ROOM_DUPLICATE, payload = {
                roomID = data.roomID, name = (value ~= "" and value) or nil,
                ts = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time absent in headless harness
            HDG.Log:Success("projects_save", "Design duplicated -- find it in My Designs (unplaced)")
        end,
    })
    HDG.UI:RegisterInputDialog("HDGR_PROJECTS_NEW_ROOM_HERE", {
        text       = "Name the new design:",
        accept     = "Create",
        maxLetters = 64,
        onAccept   = function(value, data)
            if not (data and data.layoutID and data.slotKey) then return end
            local name = (value ~= "" and value) or data.name   -- captured name as the default
            HDG.Store:Dispatch({ type = A.FURN_ROOM_CREATE, payload = {
                name = name, shape = data.shape,
                layoutID = data.layoutID, slotKey = data.slotKey,
                ts = HDG.ControllerHelpers.Mechanics.Now()} })  -- exception(boundary): time absent in headless harness
            -- v8: the slot key is stable -- the selection already points at it.
            HDG.Log:Success("projects_save",
                ("Design \"%s\" created and assigned"):format(tostring(name or "Design")))
        end,
    })
    HDG.UI.OnClick(rootFrame, "projectsDetailPanel.exportCrate",     _exportCrate)
    HDG.UI.OnClick(rootFrame, "projectsPickerPreviewPanel.back",     _closeDecorPicker)
    -- Acquisition one-clicks for the hovered UNOWNED decor (strategy unit 2,
    -- per-item slice): craftable -> craft queue; anything -> shopping wishlist.
    HDG.UI.OnClick(rootFrame, "projectsPickerPreviewPanel.queueCraft", function()
        local state  = HDG.Store:GetState()  -- exception(false-positive): top-level handler read
        local itemID = state.session.ui.projects.pickerSelectedItemID
        if not (itemID and HDG.StaticData.Recipes:Get(itemID)) then return end
        HDG.Store:Dispatch({ type = A.CRAFT_QUEUE_ADD,
            payload = { recipeID = itemID, itemID = itemID, qty = 1 } })   -- recipeID convention: produced itemID
        HDG.Log:Success("projects_save",
            ("%s queued -- reagents land in the Recipes material plan"):format(
                HDG.ItemNameResolver:ResolveName(itemID) or "Item"))
    end)
    HDG.UI.OnClick(rootFrame, "projectsPickerPreviewPanel.addShopping", function()
        local itemID = HDG.Store:GetState().session.ui.projects.pickerSelectedItemID  -- exception(false-positive): top-level handler read
        if not itemID then return end  -- exception(nullable): nothing picked yet
        HDG.ControllerHelpers.Mechanics.AddToShoppingList(itemID, nil, "Projects picker")
    end)
    HDG.UI.OnClick(rootFrame, "projectsPickerPreviewPanel.makeCopyHere", function()
        local copyID = _editCopyHere()
        if copyID then _openPickerFor(copyID) end   -- retarget the picker to the copy's pieces
    end)
    HDG.UI.OnClick(rootFrame, "projectsPickerPreviewPanel.saveAsSet", function()
        local cd = HDG.Selectors:Call("projects.crateDetail", HDG.Store:GetState(), {})  -- exception(false-positive): top-level handler read
        if cd.hasCrate and cd.crateID then
            _G.StaticPopup_Show("HDGR_PROJECTS_SAVE_AS_SET", nil, nil, { setID = cd.crateID })
        end
    end)
    HDG.UI:RegisterInputDialog("HDGR_PROJECTS_SAVE_AS_SET", {
        text       = "Name the furnishing set:",
        accept     = "Save",
        maxLetters = 64,
        onAccept   = function(value, data)
            if not (value and value ~= "" and data and data.setID) then return end
            HDG.Store:Dispatch({ type = A.FURN_SET_PROMOTE,
                payload = { setID = data.setID, name = value } })
            HDG.Log:Success("projects_save",
                ("Saved \"%s\" to your library -- it stays equipped here and can serve other rooms"):format(value))
        end,
    })
    HDG.UI.WireSearchBox(rootFrame, "projectsPickerListPanel.search", "projects", "pickerSearch")
end

function PC:Refresh(_rootFrame, _ctx)
    -- All rendering flows through bindings + the row/chip factories + the canvas
    -- controller; nothing imperative needed here (same shape as LumberController).
end

HDG.Controllers:Register("projects", PC)
