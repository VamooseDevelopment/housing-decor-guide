-- HDG.LayoutsController
-- ============================================================================
-- Layouts tab: browse / preview / share build layouts (house versions).
-- Replaces the retired Shipping Crates surface.
--
-- Left scrollbox (projects.layoutListRows -> projectsLayoutGroupRow): flat
-- projection of layoutGroups; header rows for each house, version rows per
-- version. Selection -> UI_SET_TRANSIENT.
-- Right panel:
--   header  (bound label: projects.layoutDetailHeader)
--   preview (layoutPreview widget kind, bound: projects.layoutPreviewModel)
--   stats   (bound label: projects.layoutDetailStats)
--   buttons (wired here; delete disabled on live version)

HDG = HDG or {}
HDG.LayoutsController = HDG.LayoutsController or {}
local LC = HDG.LayoutsController

local A = HDG.Constants.ACTIONS

-- Stash for the delete button frame (set at Wire time so Refresh can enable/disable).
local _deleteBtn

-- ===== helpers =============================================================

local function _selectVersion(vid)
    HDG.ControllerHelpers.Mechanics.SetUITransientView("projects", "layoutSelectedVersionID", vid)
end

-- Find the live default version: the first isLive row in the sorted group list.
-- Returns nil when there are no versions at all.
local function _defaultVersionID()
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local groups = HDG.Selectors:Call("projects.layoutGroups", state, {})
    for _, g in ipairs(groups) do
        for _, row in ipairs(g.rows) do
            if row.isLive then return row.versionID end
        end
    end
    -- Fallback: first version of any house.
    for _, g in ipairs(groups) do
        if g.rows[1] then return g.rows[1].versionID end
    end
    return nil
end

-- Ensure there is a valid layoutSelectedVersionID.
local function _ensureSelection()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local sel   = state.session.ui.projects.layoutSelectedVersionID
    if sel and state.account.projects.layouts[sel] then return end
    local fallback = _defaultVersionID()
    if fallback then _selectVersion(fallback) end
end

-- ===== Row factory: projectsLayoutGroupRow ==================================
-- Two shapes inside a single row kind (dispatches on ed.kind):
--   "header"  -> house faction label (non-interactive, TextStatus = semantic.accent)
--   "version" -> version name (left) + LIVE/wif tag (right), selectable

local function _layoutGroupRow(row)
    HDG.UI:EnsureRowChrome(row)   -- zebra + selected-state textures (RowChrome reads them)
    local headerFs = HDG.UI.RowText(row, "caption", "TextStatus", "LEFT")   -- TextStatus = semantic.accent
    headerFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    headerFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._headerFs = headerFs

    local nameFs = HDG.UI.RowText(row, "body", "Text", "LEFT")
    nameFs:SetPoint("LEFT", row, "LEFT", 16, 0)
    row._nameFs = nameFs

    local tagFs = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    tagFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    nameFs:SetPoint("RIGHT", tagFs, "LEFT", -4, 0)
    row._tagFs = tagFs

    row._laidOut = true
end

local function _paintGroupRow(row, ed)
    if ed.kind == "header" then
        row._headerFs:Show()
        row._nameFs:Hide()
        row._tagFs:Hide()
        local label = ed.houseLabel or ed.label or ""
        if ed.level and ed.level > 0 then
            label = label .. " (Lv " .. tostring(ed.level) .. ")"
        end
        row._headerFs:SetText(label)
        HDG.Theme:Register(row, "RowChrome", { header = true })
    else
        row._headerFs:Hide()
        row._nameFs:Show()
        row._tagFs:Show()
        row._nameFs:SetText(ed.name or "")
        if ed.isLive then
            row._tagFs:SetText("LIVE")
            HDG.Theme:Register(row._nameFs, "TextSuccess")
            HDG.Theme:Register(row._tagFs, "TextSuccess")
        else
            row._tagFs:SetText("wif")
            HDG.Theme:Register(row._nameFs, "Text")
            HDG.Theme:Register(row._tagFs, "TextDim")
        end
        HDG.Theme:Register(row, "RowChrome", { selected = ed.isSelected })
    end
    row._edKind  = ed.kind
    row._vid     = ed.versionID
    row._houseID = ed.houseID
end

local function _wireGroupRow(row)
    row:SetScript("OnClick", function(self)
        if self._edKind ~= "version" or not self._vid then return end
        _selectVersion(self._vid)
    end)
end

local function _resetGroupRow(row)
    HDG.UI.ClearRowText(row, "_headerFs", "_nameFs", "_tagFs")
    row._edKind, row._vid, row._houseID = nil, nil, nil
end

local function _groupRowFactory(_def)
    return {
        Configure = function(rowFrame, ed)
            if not rowFrame._laidOut then _layoutGroupRow(rowFrame) end
            _paintGroupRow(rowFrame, ed)
            _wireGroupRow(rowFrame)
        end,
        Reset = function(rowFrame)
            _resetGroupRow(rowFrame)
        end,
    }
end

HDG.Rows:Register("projectsLayoutGroupRow", {
    font = "body", height = 26,
    factory = _groupRowFactory,
    key = function(ed)
        if not ed then return "layoutRow:?" end
        if ed.kind == "header" then return "layoutHdr:" .. tostring(ed.houseID or "?") end
        return "layoutVer:" .. tostring(ed.versionID or "?")
    end,
})

-- ===== Widget type: layoutPreview ==========================================
-- A plain Frame the controller renders into. Bound to projects.layoutPreviewModel;
-- on push the controller's _RenderPreview is called.

local function _buildLayoutPreview(parent, _spec)
    local host = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    HDG.Theme:Register(host, "Frame")
    local hint = host:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(hint, "caption")
    HDG.Theme:Register(hint, "TextDim")
    hint:SetPoint("CENTER")
    hint:SetText("Select a layout to preview")
    host._hint = hint
    host:SetScript("OnSizeChanged", function(self)
        if self._lastModel then LC:_RenderPreview(self, self._lastModel) end
    end)
    return host
end

HDG.WidgetTypes:Register("layoutPreview", {
    build  = _buildLayoutPreview,
    dispatch = {
        fields = { "model" },
        push = function(widget, values)
            LC:_RenderPreview(widget, values and values.model)
        end,
    },
    requiresFont = function() return false end,
    specFields   = {},
})

-- ===== Preview renderer =====================================================
-- Read-only. No orbs, no drag, no selection outline.
-- Each floor gets an equal-width slot side by side (1/2/3 floors).
-- Per slot rotate-to-fit: if bbox aspect disagrees with slot aspect, rotate 90 deg.
--
-- Rotate-to-fit math:
--   bboxW = maxX - minX + 1, bboxD = maxY - minY + 1  (pre-rotate)
--   slotLandscape = slotW >= slotH
--   bboxLandscape = bboxW >= bboxD
--   if bboxLandscape != slotLandscape: rotate 90 deg
--     -> swap bboxW/bboxD; for each room: (x', y') = (origY - bbox.minY, bbox.maxX - origX)
--        (CCW rotation in 0-based cell space); iconRotation += 1 mod 4
--   scale = min(slotW / bboxW, slotH / bboxD) px-per-cell
--   center offsets: ox = slotX + (slotW - bboxW*scale)/2
--                   oy = (slotH - bboxD*scale)/2   (downward positive in WoW -> negate for SetPoint)

local PREVIEW_CAPTION_H = 16

-- Pool helpers (keyed mark/sweep; same pattern as ProjectsCanvasController).
local _beginPass = HDG.UI.BeginPoolPass   -- hygiene A8: shared keyed mark/sweep pool
local _endPass   = HDG.UI.EndPoolPass
local _acquire   = HDG.UI.AcquirePooled

-- Faint footprint fill (one quad per occupied cell).
local function _previewFillFactory(host)
    return host:CreateTexture(nil, "ARTWORK")
end

-- Crisp room-outline segment (true vector line; cheap, pooled).
local function _previewLineFactory(host)
    local ln = host:CreateLine(nil, "OVERLAY")
    ln:SetThickness(1.5)
    return ln
end

local function _previewDivFactory(host)
    local ln = host:CreateTexture(nil, "ARTWORK")
    ln:SetColorTexture(0, 0, 0, 0.35)
    return ln
end

local function _previewCapFactory(host)
    local fs = host:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(fs, "caption")
    HDG.Theme:Register(fs, "TextDim")
    fs:SetJustifyH("CENTER")
    return fs
end

-- Paint one floor into its slot as a vector blueprint: faint per-cell footprint
-- fills + crisp room-outline lines drawn from the rotated mask (cross/T/L keep
-- their true silhouette). Read-only. All coords TOPLEFT-relative (px>=0, py<=0).
-- floorData: { floor, rooms=[{shape,x,y,w,d,rotation,mask,circle}], bbox }
-- poolSuffix: per-slot pool namespace ("1"/"2"/"3"). accent: {r,g,b}.
local function _paintFloor(host, floorData, slotX, slotW, slotH, poolSuffix)
    local bbox  = floorData.bbox
    local rooms = floorData.rooms
    if not bbox or not bbox.minX then return end

    local W0 = bbox.maxX - bbox.minX + 1
    local D0 = bbox.maxY - bbox.minY + 1

    -- Rotate-to-fit by MAXIMISING the fit scale (tie -> no rotate). This keeps a
    -- near-square floor in a near-square slot un-rotated (no vertical-strip artifact).
    local scaleNo  = math.min(slotW / W0, slotH / D0)
    local scaleRot = math.min(slotW / D0, slotH / W0)
    local rotated  = scaleRot > scaleNo
    local W     = rotated and D0 or W0
    local D     = rotated and W0 or D0
    local scale = rotated and scaleRot or scaleNo

    local ox = slotX + (slotW - W * scale) / 2
    local oy = -(slotH - D * scale) / 2

    -- floor-cell (cx,cy) -> render col,row (row increases downward). A quarter-turn
    -- maps unit cells to unit cells, so render space stays axis-aligned (no fractions).
    local function renderCell(cx, cy)
        if rotated then return (cy - bbox.minY), (bbox.maxX - cx) end
        return (cx - bbox.minX), (cy - bbox.minY)
    end

    local fillN, lineN = 0, 0
    local function line(x1, y1, x2, y2)
        lineN = lineN + 1
        local ln = _acquire(host, "_pvLine" .. poolSuffix, lineN, _previewLineFactory)
        HDG.Theme:Register(ln, "AccentBar")   -- solid semantic.accent (theme-reactive)
        ln:ClearAllPoints()
        ln:SetStartPoint("TOPLEFT", host, x1, y1)
        ln:SetEndPoint("TOPLEFT", host, x2, y2)
        ln:Show()
    end

    for _, r in ipairs(rooms) do
        -- Render-cell set for this room's footprint (keyed for the boundary test).
        local S, cellList = {}, {}
        for _, m in ipairs(r.mask) do
            local col, rowi = renderCell(r.x + m[1], r.y + m[2])
            S[col .. "," .. rowi] = true
            cellList[#cellList + 1] = { col, rowi }
        end
        -- Faint fill per cell.
        for _, c in ipairs(cellList) do
            fillN = fillN + 1
            local tex = _acquire(host, "_pvFill" .. poolSuffix, fillN, _previewFillFactory)
            HDG.Theme:Register(tex, "AccentBg")   -- faint semantic.accent footprint tint
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", host, "TOPLEFT", ox + c[1] * scale, oy - c[2] * scale)
            tex:SetSize(math.max(1, scale), math.max(1, scale))
            tex:Show()
        end
        -- Outline: a boundary edge wherever the neighbour cell is outside the room.
        for _, c in ipairs(cellList) do
            local col, rowi = c[1], c[2]
            local px, py = ox + col * scale, oy - rowi * scale
            if not S[col .. "," .. (rowi - 1)] then line(px, py, px + scale, py) end                  -- top
            if not S[col .. "," .. (rowi + 1)] then line(px, py - scale, px + scale, py - scale) end   -- bottom
            if not S[(col - 1) .. "," .. rowi] then line(px, py, px, py - scale) end                  -- left
            if not S[(col + 1) .. "," .. rowi] then line(px + scale, py, px + scale, py - scale) end   -- right
        end
    end
end

function LC:_RenderPreview(host, model)
    host._lastModel = model

    local vw, vh = host:GetWidth(), host:GetHeight()
    if not vw or not vh or vw < 2 or vh < 2 then return end  -- exception(boundary): frame not settled

    _beginPass(host, "_pvDiv")
    _beginPass(host, "_pvCap")

    local empty = not model or not model.floors or model.floorCount == 0
    if empty then
        if host._hint then host._hint:Show() end
        for i = 1, 3 do
            local s = tostring(i)
            _beginPass(host, "_pvFill" .. s); _endPass(host, "_pvFill" .. s)
            _beginPass(host, "_pvLine" .. s); _endPass(host, "_pvLine" .. s)
        end
        _endPass(host, "_pvDiv")
        _endPass(host, "_pvCap")
        return
    end
    if host._hint then host._hint:Hide() end

    local fc    = model.floorCount   -- 1, 2, or 3 (capped by selector)
    local slotW = vw / fc
    local slotH = vh - PREVIEW_CAPTION_H

    for i = 1, fc do
        local s = tostring(i)
        _beginPass(host, "_pvFill" .. s)
        _beginPass(host, "_pvLine" .. s)

        local slotX = (i - 1) * slotW

        -- Floor caption below slot.
        local cap = _acquire(host, "_pvCap", i, _previewCapFactory)
        cap:ClearAllPoints()
        cap:SetPoint("BOTTOM", host, "BOTTOMLEFT", slotX + slotW / 2, 2)
        cap:SetText("Floor " .. i)
        cap:Show()

        -- Vertical divider between slots.
        if i < fc then
            local div = _acquire(host, "_pvDiv", i, _previewDivFactory)
            div:ClearAllPoints()
            div:SetPoint("TOPLEFT", host, "TOPLEFT", i * slotW, 0)
            div:SetSize(1, vh)
            div:Show()
        end

        local fd = model.floors[i]
        if fd and fd.bbox and fd.bbox.minX then
            _paintFloor(host, fd, slotX, slotW, slotH, s)
        end

        _endPass(host, "_pvFill" .. s)
        _endPass(host, "_pvLine" .. s)
    end

    -- Hide unused floor pools when floor count decreased.
    for i = fc + 1, 3 do
        local s = tostring(i)
        _beginPass(host, "_pvFill" .. s); _endPass(host, "_pvFill" .. s)
        _beginPass(host, "_pvLine" .. s); _endPass(host, "_pvLine" .. s)
    end

    _endPass(host, "_pvDiv")
    _endPass(host, "_pvCap")
end

-- ===== Actions =============================================================

local function _loadInArchitect()
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local detail = HDG.Selectors:Call("projects.layoutDetail", state, {})
    if not detail.hasSelection then return end
    -- Version-switch BEFORE view-switch (spec).
    HDG.Store:Dispatch({ type = A.PROJECTS_SET_ACTIVE_VERSION,
        payload = { houseID = detail.houseID, versionID = detail.versionID } })
    -- "projectsArchitect" is the actual view id; "projects" is only the nav-parent
    -- label and isn't renderable -> the engine fell back to the default (decor) view.
    HDG.Store:Dispatch({ type = A.UI_SET_PERSISTENT,
        payload = { key = "view", value = "projectsArchitect" } })
end

local function _shareCode()
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local detail = HDG.Selectors:Call("projects.layoutDetail", state, {})
    if not detail.hasSelection then return end
    local layout = state.account.projects.layouts[detail.versionID]  -- exception(false-positive): top-level controller read
    -- Encode geometry off the materialized view: records carry floor/shape/cell/
    -- floors for rooms AND unassigned slots alike (codec stays key-agnostic).
    local code = HDG.Projects.LayoutCodec.Encode({
        name = layout.name, numFloors = layout.numFloors,
        rooms = HDG.StoreFurnishings.LayoutView(state, detail.versionID),
    })
    if not code then return end
    local dialog = HDG.UI:CopyDialog()   -- exception(boundary): UI helper may be unbuilt pre-first-open
    if dialog and dialog.Open then dialog:Open("Layout code: " .. (layout.name or "Layout"), code) end
end

-- Import the decoded layout as a NEW what-if under `targetHouseID` (chosen by
-- _beginImport: the only house, or the one picked from the >1-house menu).
local function _doImport(text, targetHouseID, targetHouseName)
    if not (text and text ~= "" and targetHouseID) then return end
    local decoded = HDG.Projects.LayoutCodec.Decode(text)
    if not decoded then
        if _G.UIErrorsFrame then   -- exception(boundary): Blizzard toast
            _G.UIErrorsFrame:AddMessage("Projects: unrecognised layout code (expected HDGRLAYOUT:1:...)", 1, 0.3, 0.3)
        end
        return
    end

    -- Build a fresh layout record in the controller (reducer receives it thin).
    -- Each decoded descriptor -> ONE unassigned slot placement (a sanctioned
    -- doodle: shape + cell, no roomID -- the importer curates rooms lazily). A
    -- multi-floor room carries only its `floors` span override; FloorMap derives the rest.
    -- exception(boundary): shared codes are user input -- clamp every decoded
    -- numeric to sane ranges (a hostile/corrupt code could carry floor=99 or
    -- x=32767 verbatim into placements, bypassing the 3-floor cap).
    local function clampN(v, lo, hi, dflt)
        v = tonumber(v) or dflt
        if v < lo then return lo elseif v > hi then return hi end
        return v
    end
    local placements, slotSeq = {}, 0
    for _, d in ipairs(decoded.rooms or {}) do
        slotSeq = slotSeq + 1
        placements["slot:" .. slotSeq] = {
            floor    = clampN(d.floor, 1, 3, 1),
            x        = clampN(d.x, 0, 40, 0),
            y        = clampN(d.y, 0, 40, 0),
            rotation = clampN(d.rotation, 0, 270, 0),
            shape    = d.shape,
            floors   = d.floors and clampN(d.floors, 1, 3, 1) or nil,
        }
    end

    local layout = {
        houseID    = targetHouseID,
        name       = decoded.name or "Imported",
        createdAt  = HDG.ControllerHelpers.Mechanics.Now(),   -- exception(boundary): time()
        basedOn    = nil,
        placements = placements,
        slotSeq    = slotSeq,
        numFloors  = decoded.numFloors,
    }

    HDG.Store:Dispatch({ type = A.PROJECTS_IMPORT_LAYOUT,
        payload = { houseID = targetHouseID, version = layout, houseName = targetHouseName } })

    -- Select the newly-activated version (reducer wrote house.activeVersionID).
    local newState = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local newHouse = newState.account.projects.houses[targetHouseID]
    if newHouse and newHouse.activeVersionID then
        _selectVersion(newHouse.activeVersionID)
    end
end

-- Pop the themed paste dialog targeting a specific house (carried in the closure).
-- houseName rides along so an imported-before-captured house still gets its
-- display name stamped (the chooser knows it; the bare record doesn't).
local function _showImportPopup(houseID, houseName)
    if not houseID then return end
    HDG.UI:PromptInput("Import Layout", {
        hint       = "Paste a layout code, then Import.",
        acceptText = "Import",
        onAccept   = function(value) _doImport(value, houseID, houseName) end,
    })
end

-- Import entry point: pick the target house FIRST (from ALL owned houses -- import
-- creates the house record if it isn't captured yet). One house -> straight to paste;
-- 2+ houses -> a chooser menu (the Alliance/Horde picker), then paste.
local function _beginImport(owner)
    if not HDG.ControllerHelpers.Mechanics.PromptHouseTarget(
            owner, "Import into which house?", _showImportPopup) then
        if _G.UIErrorsFrame then _G.UIErrorsFrame:AddMessage("Projects: no house found -- visit one first", 1, 0.3, 0.3) end  -- exception(boundary): Blizzard toast
    end
end

local function _renameSelected()
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local detail = HDG.Selectors:Call("projects.layoutDetail", state, {})
    if not detail.hasSelection then return end
    _G.StaticPopup_Show("HDGR_LAYOUTS_RENAME", nil, nil, { prefill = detail.name, versionID = detail.versionID })   -- prefill: the box opens on the current name
end

local function _duplicateSelected()
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local detail = HDG.Selectors:Call("projects.layoutDetail", state, {})
    if not detail.hasSelection then return end
    HDG.Store:Dispatch({ type = A.PROJECTS_CREATE_VERSION, payload = {
        houseID   = detail.houseID,
        basedOn   = detail.versionID,
        name      = (detail.name or "Layout") .. " copy",
        createdAt = HDG.ControllerHelpers.Mechanics.Now(),   -- exception(boundary): time()
    }})
    local newState = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local newHouse = newState.account.projects.houses[detail.houseID]
    if newHouse and newHouse.activeVersionID then
        _selectVersion(newHouse.activeVersionID)
    end
end

local function _deleteSelected()
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local detail = HDG.Selectors:Call("projects.layoutDetail", state, {})
    if not detail.hasSelection or not detail.canDelete then return end
    HDG.ControllerHelpers.Mechanics.ConfirmDeleteVersion(detail.houseID, detail.versionID, detail.name,
        function() _ensureSelection() end)
end

-- ===== Wire ================================================================

function LC:Wire(rootFrame)
    HDG.UI.OnClick(rootFrame, "projectsLayoutsListPanel.importBtn",
        function(self) _beginImport(self) end)
    HDG.UI.OnClick(rootFrame, "projectsLayoutsDetailPanel.loadBtn",
        function() _loadInArchitect() end)
    HDG.UI.OnClick(rootFrame, "projectsLayoutsDetailPanel.shareBtn",
        function() _shareCode() end)
    HDG.UI.OnClick(rootFrame, "projectsLayoutsDetailPanel.renameBtn",
        function() _renameSelected() end)
    HDG.UI.OnClick(rootFrame, "projectsLayoutsDetailPanel.duplicateBtn",
        function() _duplicateSelected() end)

    HDG.UI.OnClick(rootFrame, "projectsLayoutsDetailPanel.deleteBtn",
        function() _deleteSelected() end)
    -- Stash for enable/disable in Refresh (frame lookup via rootFrame.widgets).
    _deleteBtn = HDG.UI.W(rootFrame, "projectsLayoutsDetailPanel.deleteBtn")
    -- Dynamic tooltip: the effect when deletable, the reason when not (live version).
    HDG.TooltipEngine:Attach(_deleteBtn, function(self)
        if self:IsEnabled() then
            return { title = "Delete", body = "Delete this what-if layout. This can't be undone." }
        end
        return { title = "Cannot delete the live version -- duplicate it first" }
    end)

    self:_RegisterPopups()
end

function LC:_RegisterPopups()
    -- (Layout import moved off StaticPopup to HDG.UI:PromptInput -- see _showImportPopup.)
    HDG.UI:RegisterInputDialog("HDGR_LAYOUTS_RENAME", {
        text       = "Rename layout:",
        accept     = "Rename",
        maxLetters = 256,
        onAccept   = function(value, data)
            if not (value and value ~= "") then return end
            local vid = data and data.versionID
            if not vid then return end
            HDG.Store:Dispatch({ type = A.PROJECTS_RENAME_VERSION,
                payload = { versionID = vid, name = value } })
        end,
    })
end

-- ===== Refresh =============================================================

function LC:Refresh(_rootFrame, _ctx)
    -- Ensure a valid selection when visiting this tab.
    _ensureSelection()

    -- Enable/disable the Delete button based on whether the selected version is live.
    local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller helper, not a row factory
    local detail = HDG.Selectors:Call("projects.layoutDetail", state, {})
    _deleteBtn:SetEnabled((detail.hasSelection and detail.canDelete) and true or false)

    -- All other rendering flows through bindings:
    --   projects.layoutListRows  -> projectsLayoutsListPanel.list (scrollbox)
    --   projects.layoutDetailHeader -> projectsLayoutsDetailPanel.name (label)
    --   projects.layoutDetailStats  -> projectsLayoutsDetailPanel.stats (label)
    --   projects.layoutPreviewModel -> projectsLayoutsDetailPanel.preview (layoutPreview)
    --   projects.hasLayoutSelection -> visible on all detail-panel widgets
end

HDG.Controllers:Register("layouts", LC)
