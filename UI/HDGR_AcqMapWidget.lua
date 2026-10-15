-- HDG.AcqMapWidget
--
-- Custom widget kind "vendorMap" -- renders a zone map into the host frame
-- with a vendor pin at the selected vendor's coordinates and (optionally) a
-- player pin if the player is currently on the same map.
--
-- Binding: { mapPoint = "acq.selected.mapPoint" }. mapPoint shape:
--   { mapID, x, y, name, zone }    or    nil  (no vendor selected)
--
-- Map rendering delegates to HDG.MapRenderer (ported from VFN). Pin click:
--   left  -> HDG.Waypoints:Set       (the Waypoint button's action)
--   right -> HDG.Waypoints:ShowOnMap (the Map button's action)
-- Through the shared facade like every other Map/Waypoint control: it guards combat,
-- checks the zone takes waypoints, honours the TomTom setting and says what happened.
--
-- Single pin per widget; no pooling. Player pin is a second pin appended
-- when GetPlayerMapPosition returns coordinates on the same map.

HDG                = HDG or {}
HDG.AcqMapWidget   = HDG.AcqMapWidget or {}

local PIN_SIZE_PX  = 20                                      -- matches "housing-decor-vendor_32" atlas detail
local PIN_HIT_PX   = 24
local VENDOR_COLOR = { r = 1.00, g = 0.82, b = 0.00, a = 1 } -- amber/warning
local PLAYER_COLOR = { r = 0.38, g = 0.85, b = 0.50, a = 1 } -- success green

-- Build a pin. Atlas path renders a Blizzard atlas; fallback = colored dot + white ring.
-- Mutable bits (_label / _onLeftClick / _onRightClick) hang off the pin for reuse.
local function buildPin(parent, color, label, onLeftClick, onRightClick, atlas)
    local pin = CreateFrame("Button", nil, parent)
    pin:SetSize(PIN_HIT_PX, PIN_HIT_PX)
    pin:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    pin._label        = label
    pin._onLeftClick  = onLeftClick
    pin._onRightClick = onRightClick

    if atlas then
        local dot = pin:CreateTexture(nil, "OVERLAY", nil, 2)
        dot:SetSize(PIN_SIZE_PX, PIN_SIZE_PX)
        dot:SetPoint("CENTER")
        dot:SetAtlas(atlas)
        pin._dot = dot
    else
        local outline = pin:CreateTexture(nil, "OVERLAY", nil, 1)
        outline:SetSize(PIN_SIZE_PX + 4, PIN_SIZE_PX + 4)
        outline:SetPoint("CENTER")
        outline:SetColorTexture(1, 1, 1, 0.9)
        pin._outline = outline

        local dot = pin:CreateTexture(nil, "OVERLAY", nil, 2)
        dot:SetSize(PIN_SIZE_PX, PIN_SIZE_PX)
        dot:SetPoint("CENTER")
        dot:SetColorTexture(color.r, color.g, color.b, 1)
        pin._dot = dot
    end

    pin:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and self._onLeftClick then self._onLeftClick() end
        if button == "RightButton" and self._onRightClick then self._onRightClick() end
    end)
    local function _pinTooltipDef(self)
        if not self._label or self._label == "" then return nil end
        local extras = {}
        if self._onLeftClick then extras[#extras + 1] = { text = "Left-click", right = "Set waypoint" } end
        if self._onRightClick then extras[#extras + 1] = { text = "Right-click", right = "Show on map" } end
        return { title = self._label, extraLines = extras }
    end
    HDG.TooltipEngine:Attach(pin, _pinTooltipDef)

    return pin
end

-- Place a pin at canvas-fraction (x, y). Scale-corrects for the canvas SetScale.
local function placePin(pin, canvas, x, y)
    local cw = canvas.GetWidth and canvas:GetWidth() or 0      -- exception(boundary): frame geometry nil before first layout
    local ch = canvas.GetHeight and canvas:GetHeight() or
    0                                                          -- exception(boundary): frame geometry nil before first layout
    local scale = (canvas.GetScale and canvas:GetScale()) or
    1                                                          -- exception(boundary): frame geometry nil before first layout
    if scale <= 0 then scale = 1 end

    pin:SetParent(canvas)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", canvas, "TOPLEFT", x * cw, -(y * ch))
    pin:SetSize(PIN_HIT_PX / scale, PIN_HIT_PX / scale)
    if pin._dot then
        pin._dot:SetSize(PIN_SIZE_PX / scale, PIN_SIZE_PX / scale)
    end
    if pin._outline then
        pin._outline:SetSize((PIN_SIZE_PX + 4) / scale, (PIN_SIZE_PX + 4) / scale)
    end
    pin:Show()
end

-- ===== Widget lifecycle ====================================================

local function buildVendorMap(parent, spec)
    local frame = CreateFrame("Frame", nil, parent)
    -- Sized by the layout engine before dispatch; MapRenderer reads geometry at paint time.

    -- Empty-state label. Centered in the host; hidden when a map is drawn.
    local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("CENTER")
    empty:SetText("Select a vendor to see its zone")
    frame._emptyLabel = empty

    return frame
end

local function dispatchVendorMap(widget, values)
    local point = values and values.mapPoint
    local renderer = HDG.MapRenderer

    if not point then
        renderer:Clear(widget)
        if widget._vendorPin then widget._vendorPin:Hide() end
        if widget._playerPin then widget._playerPin:Hide() end
        if widget._emptyLabel then widget._emptyLabel:Show() end
        return
    end

    if widget._emptyLabel then widget._emptyLabel:Hide() end

    local canvas, artMapID = renderer:Render(widget, point.mapID)
    if not canvas then
        if widget._vendorPin then widget._vendorPin:Hide() end
        if widget._playerPin then widget._playerPin:Hide() end
        if widget._emptyLabel then
            widget._emptyLabel:SetText("Map unavailable for " .. (point.zone or "this zone"))
            widget._emptyLabel:Show()
        end
        return
    end

    -- Only place vendor pin when artMapID matches point's mapID (MapRenderer may walk up to
    -- a parent zone; child-map coords would land wrong on the parent art).
    -- noPin points (zone resolved from the catalog's zone string, no coords)
    -- draw the map art only -- no pin, no waypoint click.
    if not point.noPin and artMapID == point.mapID then
        -- Stash current point so click closures (built once, reused) read live coords.
        widget._currentPoint = point
        widget._vendorPin = widget._vendorPin or buildPin(canvas, VENDOR_COLOR, point.name,
            -- the point is 0-1 map space; the facade takes zone-pct
            function()
                local p = widget._currentPoint
                HDG.Waypoints:Set(p.mapID, p.x * 100, p.y * 100, p.name)
            end,
            function()
                local p = widget._currentPoint
                HDG.Waypoints:ShowOnMap(p.mapID, p.x * 100, p.y * 100, p.name)
            end,
            "housing-decor-vendor_32"         -- native Blizzard housing-vendor pin atlas
        )
        widget._vendorPin._label = point.name -- rebind; closure captured the original name
        placePin(widget._vendorPin, canvas, point.x, point.y)
    elseif widget._vendorPin then
        widget._vendorPin:Hide()
    end

    -- Player pin -- only when the player is on the same artMapID.
    local playerMapID = C_Map.GetBestMapForUnit("player")
    if playerMapID == artMapID then
        local pos = C_Map.GetPlayerMapPosition(playerMapID, "player")
        if pos then
            local px, py = pos:GetXY()
            if px and py and px > 0 and py > 0 then
                widget._playerPin = widget._playerPin or buildPin(canvas, PLAYER_COLOR, "You", nil, nil, "AncientMana")
                placePin(widget._playerPin, canvas, px, py)
            elseif widget._playerPin then
                widget._playerPin:Hide()
            end
        elseif widget._playerPin then
            widget._playerPin:Hide()
        end
    elseif widget._playerPin then
        widget._playerPin:Hide()
    end
end

HDG.WidgetTypes:Register("vendorMap", {
    build        = buildVendorMap,
    dispatch     = { fields = { "mapPoint" }, push = dispatchVendorMap },
    requiresFont = function() return false end,
    specFields   = {}, -- mapPoint flows via binding; no kind-specific fields
})
