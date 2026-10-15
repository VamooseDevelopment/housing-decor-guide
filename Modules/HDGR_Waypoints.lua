local addonName, privateDB = ...
local HDG = _G.HDG

-- ============================================================================
-- HDGR_Waypoints.lua -- Waypoint facade (TomTom optional, Blizzard native fallback)
-- ============================================================================

HDG.Waypoints = {}

-- Log tags registered at file-load (no Modules:Declare block;
-- tags must exist before the first Warn call; HDGR_Log.lua loads first in TOC).
--   waypoints      -- internal diagnostics (debug tab only)
--   waypoints_user -- player-facing waypoint acks (status rail)
HDG.Log:RegisterTags({
    waypoints      = { level = "warn", user = false },
    waypoints_user = { level = "info", user = true, duration = 3 },
})

-- ============================================================================
-- PROVIDER SELECTION
-- ============================================================================

local _tomtomWarnedOnce = false   -- rate-limits the "TomTom not found" log

local function GetWaypointPref()
    -- Strict read: state is guaranteed initialized by onEnable ordering.
    return HDG.Config:Get("WAYPOINT_PROVIDER")
end

local function ShouldUseTomTom()
    local pref = GetWaypointPref()
    if pref == "blizzard" then return false end           -- explicit Blizzard override
    if pref == "tomtom" then
        if TomTom and TomTom.AddWaypoint then return true end
        -- User chose TomTom but it isn't loaded: warn once, fall back.
        if not _tomtomWarnedOnce then
            _tomtomWarnedOnce = true
            HDG.Log:Warn("waypoints", "waypointProvider='tomtom' but TomTom is not installed; falling back to Blizzard waypoints.")
        end
        return false
    end
    -- "auto": TomTom if loaded, else Blizzard.
    return TomTom and TomTom.AddWaypoint and true or false
end

-- ============================================================================
-- COORDINATE NORMALIZATION
-- Converts zone-percent coords (0-100) to WoW map fractions (0-1).
-- Validates mapID and range; returns nil when coords are unusable.
-- ============================================================================

function HDG.Waypoints.ZonePctToMap(mapID, pctX, pctY)
    if not mapID or mapID == 0 then return nil end
    if not C_Map.GetMapInfo(mapID) then return nil end  -- exception(boundary): Blizzard API
    if not pctX or not pctY or (pctX == 0 and pctY == 0) then return nil end
    if pctX < -5 or pctX > 105 or pctY < -5 or pctY > 105 then return nil end
    local mapX = math.max(0, math.min(1, pctX / 100))
    local mapY = math.max(0, math.min(1, pctY / 100))
    return mapID, mapX, mapY
end

-- ============================================================================
-- FEEDBACK LINES (ahead of every caller: they are file locals)
-- ============================================================================

-- Failure feedback: Log:Warn on the user tag -> status rail toast, AND the Log
-- engine auto-chats warn-level entries (shouldTrace), so failures stay visible
-- even with the window closed. No direct print needed.
local function warnLine(msg)
    HDG.Log:Warn("waypoints_user", msg)
end

-- Success feedback: status rail toast. Chat ONLY when the main window (which
-- hosts the rail) is hidden -- waypoints can be set from the standalone zone
-- scanner / shopping windows / map pins, and feedback must not be lost there.
-- Chat stays quiet whenever the rail can show the ack.
local function successLine(msg)
    HDG.Log:Success("waypoints_user", msg)
    if not HDG.Store:GetState().account.ui.mainWindowShown then
        print(HDG.Theme:GetTextStateColorToken("success") .. "[HDG]|r " .. msg)  -- exception(boundary): rail not visible; chat is the only feedback surface
    end
end

-- ============================================================================
-- SINGLE WAYPOINT
-- ============================================================================

-- Core single set -- returns (ok, provider/reason); NO messaging (so :Set and
-- :RunBatch can centralize feedback). Internal-only; public callers use :Set.
function HDG.Waypoints:_doSet(mapID, x, y, title)
    if InCombatLockdown() then return false, "combat" end

    local uiMapID, mapX, mapY = HDG.Waypoints.ZonePctToMap(mapID, x, y)
    if not uiMapID then return false, "no_map" end

    -- TomTom path
    if ShouldUseTomTom() then
        if TomTom and TomTom.AddWaypoint then
            local ok, uid = pcall(function()
                return TomTom:AddWaypoint(uiMapID, mapX, mapY, {
                    title = title or "Vendor",
                    persistent = false,
                    from = "HDG",
                })
            end)
            if not ok then
                HDG.Log:Warn("waypoints", "AddWaypoint failed: " .. tostring(uid))
            end
            if ok and uid then
                local okArr, errArr = pcall(function()
                    TomTom:SetCrazyArrow(uid, TomTom.profile.arrow.arrival or 5, title)
                end)
                if not okArr then
                    HDG.Log:Warn("waypoints", "SetCrazyArrow failed: " .. tostring(errArr))
                end
                return true, "tomtom"
            end
        end
        -- Strict TomTom mode but TomTom not available
        local pref = GetWaypointPref()
        if pref == "tomtom" then return false, "no_tomtom" end
    end

    -- Blizzard's own waypoint, super-tracked (what Waypoint UI and the quest arrow show).
    -- A WAYPOINT ONLY (owner 2026-10-15): it neither opens the map nor drops HDG's pin --
    -- that is the Map button's job. A zone Blizzard refuses waypoints in says so.
    if not C_Map.CanSetUserWaypointOnMap(uiMapID) then return false, "unsupported_map" end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapID, mapX, mapY))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    return true, "native"
end

-- Public single set. Routes feedback through the central PrintResult so EVERY
-- waypoint action gets one chat line (success/failure + optional opposite-faction
-- note) -- no per-caller hand-rolling. Inside a :RunBatch the result instead
-- ACCUMULATES, and RunBatch emits ONE consolidated line for the whole batch (so
-- "Waypoint All" of N vendors prints once, not N times). `faction` ("A"/"H"/"N",
-- optional) drives the opposite-faction warning on single sets.
function HDG.Waypoints:Set(mapID, x, y, title, faction)
    local ok, provider = self:_doSet(mapID, x, y, title)
    local b = self._batch
    if b then
        if ok then b.count = b.count + 1; b.provider = provider; b.last = title
        else b.failReason = provider end
    else
        self:PrintResult(ok, provider, title, nil, faction)
    end
    return ok, provider
end

-- Run `fn` (which makes multiple :Set calls) as ONE batch: per-set messages are
-- suppressed and a single consolidated PrintResult is emitted afterward. Returns
-- the successful-set count. pcall guarantees _batch is cleared even if `fn`
-- errors (else a stale batch would silently swallow later single-set messages).
function HDG.Waypoints:RunBatch(fn)
    self._batch = { count = 0, provider = nil, failReason = nil }
    local ok, err = pcall(fn)   -- exception(fire-forget): batch body error -- clear _batch regardless; surfaced below
    local b = self._batch
    self._batch = nil
    if not ok then HDG.Log:Warn("waypoints", "RunBatch body error: " .. tostring(err)) end
    if b.count > 0 then
        self:PrintResult(true, b.provider, b.last, b.count)
    else
        self:PrintResult(false, b.failReason or "no_map", nil, nil)
    end
    return b.count
end

-- ============================================================================
-- SHOW ON MAP
-- The "Map" / "Show on Map" button action (vs :Set, the waypoint). Opens the
-- WorldMap focused on the target zone with our own pin, and nothing else. Shared
-- by every Map button and every "map all" in the main window
-- (audit: docs/MAP_WAYPOINT_AUDIT_2026-10-15.md).
-- ============================================================================

-- One-time OnShow hook (wrong-map fix): ShowUIPanel dispatches async to a
-- secure delegate, then WorldMapMixin:OnShow clobbers any inline SetMapID.
-- Our HookScript runs AFTER Blizzard's and re-applies _pendingMapID.
-- Installed flag set before the WorldMapFrame check to avoid infinite retry.
function HDG.Waypoints:_installMapOpenHook()
    if HDG.Waypoints._mapOpenHookInstalled then return end
    HDG.Waypoints._mapOpenHookInstalled = true
    if not (WorldMapFrame and WorldMapFrame.HookScript) then return end
    WorldMapFrame:HookScript("OnShow", function()
        local pending = HDG.Waypoints._pendingMapID
        if not pending then return end
        HDG.Waypoints._pendingMapID = nil
        if WorldMapFrame:GetMapID() ~= pending then
            WorldMapFrame:SetMapID(pending)
        end
    end)
end

-- Open WorldMap at uiMapID; if already shown SetMapID directly, else stash
-- in _pendingMapID for the OnShow hook.
function HDG.Waypoints:OpenWorldMapAt(uiMapID)
    if not uiMapID then return end
    if InCombatLockdown() then return end
    HDG.Waypoints:_installMapOpenHook()
    if WorldMapFrame and WorldMapFrame:IsShown() then
        WorldMapFrame:SetMapID(uiMapID)
    else
        HDG.Waypoints._pendingMapID = uiMapID
        pcall(OpenWorldMap, uiMapID)  -- exception(fire-forget): combat-protected; _pendingMapID is the canonical signal
    end
end

-- The Map button, everywhere: open the world map at the place with HDG's pin on it.
-- A MAP ONLY (owner 2026-10-15) -- it leaves your waypoint alone; Set is the waypoint.
-- Coords are zone-pct (0-100). Says what happened either way, so no caller hand-rolls
-- it and none stays silent (combat and a missing location used to be).
function HDG.Waypoints:ShowOnMap(mapID, pctX, pctY, title)
    local ok, reason = self:_doShowOnMap(mapID, pctX, pctY, title)
    if ok then
        successLine("Showing " .. (title or "vendor") .. " on the map.")
    else
        self:PrintResult(false, reason)
    end
    return ok, reason
end

function HDG.Waypoints:_doShowOnMap(mapID, pctX, pctY, title)
    if InCombatLockdown() then return false, "combat" end
    local uiMapID, mapX, mapY = HDG.Waypoints.ZonePctToMap(mapID, pctX, pctY)
    if not uiMapID then return false, "no_map" end
    HDG.Waypoints:AddMapPin(uiMapID, mapX, mapY, title or "Vendor")
    HDG.Waypoints:OpenWorldMapAt(uiMapID)
    return true, "native"
end

-- "Map all" -- ONE meaning for every list that has it (owner 2026-10-15): pin every
-- vendor in `vendors` that has a location, open the map once at the first, touch no
-- waypoint. Vendors records are { mapID, x, y, name } in zone-pct. Returns the count.
function HDG.Waypoints:MapAll(vendors)
    if InCombatLockdown() then
        self:PrintResult(false, "combat")
        return 0
    end
    local placed, firstMapID = self:SetMultiple(vendors)
    if placed == 0 then
        warnLine("No vendor in this list has a known location yet.")
        return 0
    end
    self:OpenWorldMapAt(firstMapID)
    successLine(string.format("Mapped %d vendor%s.", placed, placed == 1 and "" or "s"))
    return placed
end

-- ============================================================================
-- FEEDBACK MESSAGES
-- ============================================================================

-- Failure lines serve every button (Map and Wpt share the reasons; trainers and
-- Shopping too), so they name the obstacle rather than the action or the target.
local FAIL_LINE = {
    combat          = "Can't do that in combat -- try again after the fight.",
    no_tomtom       = "TomTom is not installed. Set Waypoint Provider to Auto or Blizzard in HDG settings.",
    unsupported_map = "The game doesn't allow waypoints in this zone.",
    no_map          = "No known location yet.",
}

function HDG.Waypoints:PrintResult(ok, provider, title, count, vendorFaction)
    if not ok then
        -- Every reason is minted in this file; one without a line is a bug here.
        warnLine(assert(FAIL_LINE[provider], "Waypoints: no FAIL_LINE for " .. tostring(provider)))
        return
    end
    if count and count > 1 then
        if provider == "tomtom" then
            successLine(string.format("Set %d TomTom waypoints.", count))
        else
            -- Blizzard keeps ONE user waypoint: each Set replaced the last. Say which
            -- one is live rather than promise a route through all of them.
            successLine(string.format("Waypoint set for %s -- the game tracks one at a time (%d vendors).",
                title or "the last vendor", count))
        end
    else
        local name = title or "vendor"
        if provider == "tomtom" then
            successLine("TomTom waypoint set for " .. name)
        else
            successLine("Waypoint set for " .. name)
        end
    end
    -- Opposite-faction vendor warning
    if vendorFaction and vendorFaction ~= "N" then
        local playerFaction = UnitFactionGroup("player")
        local vendorIsAlliance = vendorFaction == "A"
        local vendorIsHorde = vendorFaction == "H"
        if (playerFaction == "Alliance" and vendorIsHorde) or (playerFaction == "Horde" and vendorIsAlliance) then
            local label = vendorIsAlliance and "Alliance" or "Horde"
            warnLine("Note: This is a " .. label .. "-only vendor.")
        end
    end
end

-- ============================================================================
-- VENDOR PIN LAYER (taint-safe)
-- Own canvas frame under WorldMapFrame.ScrollContainer.Child + own framepool +
-- EventRegistry MapCanvas.MapSet + hooksecurefunc for resize. Decoupled from
-- Blizzard's MapCanvas pool to avoid pool-contamination taint.
-- ============================================================================

HDGR_VendorPinMixin = HDGR_VendorPinMixin or {}

-- Module-private canvas, pool, and per-frame state.
local _mapFrame
local _pinPool
local _currentMapID
local _pendingPins = {}     -- [mapID] = { {mapID,x,y,title}, ... }
local _mapPinsInitialized = false

local function _getCanvasParent()
    -- Inner scaled canvas (zooms/pans). Pins parented here move with the map.
    local sc = WorldMapFrame.ScrollContainer
    if sc and sc.Child then return sc.Child end
    return WorldMapFrame:GetCanvasContainer()
end

local function _onPinReleased(_, pin)
    pin:OnReleased()
end

function HDGR_VendorPinMixin:OnLoad()
    self:SetFrameStrata("HIGH")  -- must be HIGH; canvas default renders behind Blizzard UI
    self:SetSize(20, 20)
    self:EnableMouse(true)
    -- Frame not Button: Button template is wrong for pool-acquire semantics;
    -- RegisterForClicks is Button-only and crashed on first acquire (removed).
    -- Click routes via OnMouseUp -> self:OnClick (wired in pool createFunc).
    self.icon = self:CreateTexture(nil, "ARTWORK")
    self.icon:SetAllPoints()
    self.icon:SetAtlas("housing-decor-vendor_32")
end

function HDGR_VendorPinMixin:OnAcquired(data)
    self:SetFrameStrata("HIGH")  -- re-stamp on every acquire (recycled pins may have been touched)
    self.data = data
    self._x, self._y = data.x, data.y
    self:ApplyPosition()
    self:Show()
end

function HDGR_VendorPinMixin:OnReleased()
    self:ClearAllPoints()
    self:Hide()
    self.data = nil
    self._x, self._y = nil, nil
end

function HDGR_VendorPinMixin:ApplyPosition()
    local w, h = _mapFrame:GetWidth(), _mapFrame:GetHeight()
    local scale = self:GetScale()
    self:ClearAllPoints()
    self:SetPoint("CENTER", _mapFrame, "TOPLEFT",
        (w * self._x) / scale, -(h * self._y) / scale)
end


-- A pin click is a Waypoint click: the facade owns the combat check, the
-- provider choice and the feedback line. Pins hold map fractions; Set takes
-- zone-pct.
function HDGR_VendorPinMixin:OnClick()
    HDG.Waypoints:Set(self.data.mapID, self._x * 100, self._y * 100, self.data.title)
end

-- ---- Render ---------------------------------------------------------------

local function _renderPinsFor(mapID)
    _pinPool:ReleaseAll()
    local list = _pendingPins[mapID]
    if not list then return end
    for _, data in ipairs(list) do
        local pin = _pinPool:Acquire()
        pin:OnAcquired(data)
    end
end

local function _updatePinScales()
    local invScale = 1.0 / WorldMapFrame:GetCanvasScale()
    for pin in _pinPool:EnumerateActive() do
        pin:SetScale(invScale)
        pin:ApplyPosition()
    end
end

local function _refreshAll(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return end
    _currentMapID = mapID
    _renderPinsFor(mapID)
    _updatePinScales()
end

local function _onResize()
    if not _currentMapID then return end
    _updatePinScales()
end

-- ---- Public API ----------------------------------------------------------

function HDG.Waypoints:AddMapPin(mapID, x, y, title)
    _pendingPins[mapID] = _pendingPins[mapID] or {}
    -- Map on the same vendor twice used to stack a second pin on the first.
    for _, p in ipairs(_pendingPins[mapID]) do
        if p.x == x and p.y == y and p.title == title then return end
    end
    table.insert(_pendingPins[mapID], {
        mapID = mapID, x = x, y = y, title = title,
    })
    if _mapFrame and WorldMapFrame and WorldMapFrame:IsShown()
       and WorldMapFrame:GetMapID() == mapID then
        _refreshAll(mapID)
    end
end

-- Drop map pins for a list of vendor records (each: { mapID, x, y, name }).
-- Skips entries ZonePctToMap can't place (no location yet). Returns the count
-- of pins placed and the first one's map.
function HDG.Waypoints:SetMultiple(vendors)
    -- Replace, never append: each Map All click used to add a second copy of
    -- every pin and the pool grew with it for the session.
    wipe(_pendingPins)
    local placed, firstMapID = 0, nil
    for _, v in ipairs(vendors) do
        local uiMapID, mapX, mapY = HDG.Waypoints.ZonePctToMap(v.mapID, v.x, v.y)
        if uiMapID then
            HDG.Waypoints:AddMapPin(uiMapID, mapX, mapY, v.name or "Vendor")
            placed = placed + 1
            firstMapID = firstMapID or uiMapID
        end
    end
    return placed, firstMapID
end

function HDG.Waypoints:ClearAllMapPins()
    wipe(_pendingPins)
    if _pinPool then _pinPool:ReleaseAll() end
end

-- ---- Init ----------------------------------------------------------------

function HDG.Waypoints:InitMapPins()
    if _mapPinsInitialized then return end
    if not WorldMapFrame then return end
    _mapPinsInitialized = true

    local canvas = _getCanvasParent()
    _mapFrame = CreateFrame("Frame", nil, canvas)
    _mapFrame:SetAllPoints(canvas)
    _mapFrame:SetFrameLevel(canvas:GetFrameLevel() + 10)

    -- CreateFramePool's 6th arg is called on EACH newly-created pool frame.
    -- Must configure the pool's own frame in-place (not create a second one --
    -- the pool ignores any return value; second-frame pattern means OnReleased=nil,
    -- ReleaseAll crashes on first pin).
    local _vendorPinTooltipDef = function(self)
        return {
            title      = self.data and self.data.title or "Vendor",
            extraLines = { { text = "Click to navigate", r = 0.78, g = 0.78, b = 0.78 } },
        }
    end

    local frameInitFunc = function(f)
        Mixin(f, HDGR_VendorPinMixin)
        f:OnLoad()
        f:SetScript("OnMouseUp", f.OnClick)
        HDG.TooltipEngine:Attach(f, _vendorPinTooltipDef)
    end
    -- exception(false-positive): CreateFramePool is safe here -- the 12.x taint trap is
    -- SecureActionButtonTemplate DESCENDANTS (protection propagates upward; pool Hide() on
    -- release is combat-locked). Pins are plain insecure frames (texture + OnMouseUp), no
    -- secure children, so CreateUnsecuredRegionPoolInstance is not required.
    _pinPool = CreateFramePool("FRAME", _mapFrame, nil, _onPinReleased, false, frameInitFunc)

    -- MapCanvas.MapSet fires BEFORE canvas geometry settles; poll for non-zero
    -- width before rendering.
    local function _refreshWhenReady(mapID, attempts)
        attempts = attempts or 0
        if _mapFrame:GetWidth() > 0 then
            _refreshAll(mapID)
        elseif attempts < 30 then
            C_Timer.After(0.1, function() _refreshWhenReady(mapID, attempts + 1) end)
        end
    end
    EventRegistry:RegisterCallback("MapCanvas.MapSet", function(_, mapID)
        _refreshWhenReady(mapID)
    end, _mapFrame)

    hooksecurefunc(WorldMapFrame, "OnFrameSizeChanged", _onResize)
    -- Zoom: react to Blizzard's canvas scale-change EVENT (taint-preserving hook),
    -- NOT a per-frame OnUpdate poll. Mirrors MapCanvasPinMixin:OnCanvasScaleChanged --
    -- the canonical map-pin approach; none poll per frame.
    hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", _onResize)

    -- Initial render in case Init runs while a map is already open.
    if WorldMapFrame:IsShown() then _refreshAll() end
end
