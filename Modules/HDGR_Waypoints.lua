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

-- Every line the player reads is a WPT_* locale key, looked up when it prints: the
-- language can change mid-session. The plain `waypoints` tag stays English (Debug tab).
local function L(key) return HDG.Locale:Get(key) end

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

-- Point (x, y, map fractions) of uiMapID carried onto the parent map `onMap` through the
-- world: the point's world position measured against onMap's corners (a map's x runs along
-- the world's y and its y along the world's x, as VSS's Boundary.PositionOn). Not
-- GetMapRectOnMap: that is where uiMapID is DRAWN on onMap, and Dalaran (125) is drawn on
-- Crystalsong (127) away from where it floats -- the waypoint sat by the Violet Citadel, not
-- at the cooking trainer; through the world it landed on her (in game 10-29). nil when either
-- map has no world position, they are on different continents, or the point is off onMap.
local function _pointOn(uiMapID, onMap, x, y)
    if onMap == uiMapID then return x, y end
    local c, w = C_Map.GetWorldPosFromMapPos(uiMapID, CreateVector2D(x, y))
    local c0, w0 = C_Map.GetWorldPosFromMapPos(onMap, CreateVector2D(0, 0))
    local _, w1 = C_Map.GetWorldPosFromMapPos(onMap, CreateVector2D(1, 1))
    if not (w and w0) or c ~= c0 then return nil end   -- exception(boundary): an instanced map has no world position (MCP gotcha); a parent on another continent
    local px, py = (w.y - w0.y) / (w1.y - w0.y), (w.x - w0.x) / (w1.x - w0.x)
    if px < 0 or px > 1 or py < 0 or py > 1 then return nil end   -- off onMap: a map further up takes it
    return px, py
end

-- The map a Blizzard waypoint goes on and the point there: uiMapID where the game allows
-- waypoints, else the nearest parent map that does, the point carried onto it. A garrison's
-- own map refuses them (Lunarfall 582: CanSetUserWaypointOnMap false; its zone, Shadowmoon
-- Valley 539, takes the same spot -- in game 10-27). nil when no map up the chain does.
local function _waypointMap(uiMapID, x, y)
    local map = uiMapID
    while map ~= 0 do
        if C_Map.CanSetUserWaypointOnMap(map) then
            local px, py = _pointOn(uiMapID, map, x, y)
            if px then return map, px, py end
        end
        map = C_Map.GetMapInfo(map).parentMapID
    end
    return nil
end

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
                    title = title or L("WPT_PIN_VENDOR"),
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
    -- that is the Map button's job. A spot no map up the chain takes a waypoint on says so.
    local onMap, wx, wy = _waypointMap(uiMapID, mapX, mapY)
    if not onMap then return false, "unsupported_map" end
    -- SetUserWaypoint answers wasSet (Blizzard's own /mappin and waypoint links check it): a
    -- map that passes CanSet can still refuse the point, and must not read as "set".
    if not C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(onMap, wx, wy)) then return false, "not_set" end
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

-- Blizzard's own arrow on a quest in the log (the Quest Tracker's Quest arrow): the game
-- knows where its objectives are. SetSuperTrackedQuestID takes 0 to clear, never nil.
function HDG.Waypoints:SuperTrackQuest(questID, title)
    if InCombatLockdown() then
        self:PrintResult(false, "combat", title)
        return
    end
    C_SuperTrack.SetSuperTrackedQuestID(questID)
    successLine(L("WPT_ARROW_SET"):format(title))
end

-- A Decor Quests Waypoint (the tracker's, a detail's): Blizzard's arrow on a quest in the
-- log, else a waypoint at the step's start or the vendor's spot. spec = { title, questID |
-- map + x + y (map percent) [+ side] }.
function HDG.Waypoints:FollowQuestStep(spec)
    if spec.questID then
        self:SuperTrackQuest(spec.questID, spec.title)
        return
    end
    self:Set(spec.map, spec.x, spec.y, spec.title, spec.side)
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
-- stepNum: a Decor Quests step's pin, a disc with its number; nil pins a vendor.
function HDG.Waypoints:ShowOnMap(mapID, pctX, pctY, title, stepNum)
    local ok, reason = self:_doShowOnMap(mapID, pctX, pctY, title, stepNum)
    if ok then
        successLine(L("WPT_SHOWING"):format(title or L("WPT_NAME_VENDOR")))
    else
        self:PrintResult(false, reason)
    end
    return ok, reason
end

-- The Quest Tracker's place line: a waypoint at the spot AND the map open on it with HDG's
-- pin, in one click (owner 10-30: the map alone isn't much help there). Every other Map
-- stays map only. One chat line, the waypoint's; a map that can't open says why instead.
-- faction: Set's, for its other-faction warning (a done decor's vendor).
function HDG.Waypoints:SetAndShow(mapID, pctX, pctY, title, stepNum, faction)
    local ok, reason = self:_doShowOnMap(mapID, pctX, pctY, title, stepNum)
    if not ok then
        self:PrintResult(false, reason)
        return ok, reason
    end
    return self:Set(mapID, pctX, pctY, title, faction)
end

function HDG.Waypoints:_doShowOnMap(mapID, pctX, pctY, title, stepNum)
    if InCombatLockdown() then return false, "combat" end
    local uiMapID, mapX, mapY = HDG.Waypoints.ZonePctToMap(mapID, pctX, pctY)
    if not uiMapID then return false, "no_map" end
    HDG.Waypoints:AddMapPin(uiMapID, mapX, mapY, title or L("WPT_PIN_VENDOR"), stepNum)
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
        warnLine(L("WPT_MAP_ALL_NONE"))
        return 0
    end
    self:OpenWorldMapAt(firstMapID)
    successLine(L(placed == 1 and "WPT_MAPPED_ONE" or "WPT_MAPPED"):format(placed))
    return placed
end

-- ============================================================================
-- FEEDBACK MESSAGES
-- ============================================================================

-- Failure lines serve every button (Map and Wpt share the reasons; trainers and
-- Shopping too), so they name the obstacle rather than the action or the target.
-- Values are locale keys, looked up when the line prints.
local FAIL_LINE = {
    combat          = "WPT_FAIL_COMBAT",
    no_tomtom       = "WPT_FAIL_NO_TOMTOM",
    unsupported_map = "WPT_FAIL_UNSUPPORTED_MAP",
    not_set         = "WPT_FAIL_NOT_SET",
    no_map          = "WPT_FAIL_NO_MAP",
}

-- Opposite-faction vendor warning. A whole line per side: the faction's name changes the
-- sentence around it in other languages.
local function _warnOtherFaction(vendorFaction)
    local playerFaction = UnitFactionGroup("player")
    if playerFaction == "Alliance" and vendorFaction == "H" then warnLine(L("WPT_ONLY_HORDE")) end
    if playerFaction == "Horde" and vendorFaction == "A" then warnLine(L("WPT_ONLY_ALLIANCE")) end
end

function HDG.Waypoints:PrintResult(ok, provider, title, count, vendorFaction)
    if not ok then
        -- Every reason is minted in this file; one without a line is a bug here.
        warnLine(L(assert(FAIL_LINE[provider], "Waypoints: no FAIL_LINE for " .. tostring(provider))))
        return
    end
    if count and count > 1 then
        if provider == "tomtom" then
            successLine(L("WPT_SET_TOMTOM_BATCH"):format(count))
        else
            -- Blizzard keeps ONE user waypoint: each Set replaced the last. Say which
            -- one is live rather than promise a route through all of them.
            successLine(L("WPT_SET_BATCH"):format(title or L("WPT_NAME_LAST_VENDOR"), count))
        end
    else
        local name = title or L("WPT_NAME_VENDOR")
        successLine(L(provider == "tomtom" and "WPT_SET_TOMTOM" or "WPT_SET"):format(name))
    end
    if vendorFaction and vendorFaction ~= "N" then _warnOtherFaction(vendorFaction) end
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
local _pendingPins = {}     -- [mapID] = { {mapID,x,y,title,num}, ... }
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

-- A pin is a vendor's (Blizzard's decor-vendor icon) or a Decor Quests step's: the tracker's
-- disc for the step to head for -- accent ring, filled in the text colour, its number in the
-- sunken one (review G1). Blizzard's quest "!" read as a quest on offer there (owner 10-29).
local PIN_SIZE, PIN_DISC = 20, 16   -- the ring, and the disc in it (the tracker's 26 / 22)
local VENDOR_ATLAS = "housing-decor-vendor_32"

local function _pinDiscTexture(pin, layer, size, token)
    local tex = pin:CreateTexture(nil, layer)
    tex:SetPoint("CENTER")
    tex:SetSize(size, size)
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    HDG.UI.CircleMask(tex)
    HDG.UI.ToneTexture(tex, token)
    return tex
end

function HDGR_VendorPinMixin:OnLoad()
    self:SetFrameStrata("HIGH")  -- must be HIGH; canvas default renders behind Blizzard UI
    self:SetSize(PIN_SIZE, PIN_SIZE)
    self:EnableMouse(true)
    -- Frame not Button: Button template is wrong for pool-acquire semantics;
    -- RegisterForClicks is Button-only and crashed on first acquire (removed).
    -- Click routes via OnMouseUp -> self:OnClick (wired in pool createFunc).
    self.icon = self:CreateTexture(nil, "ARTWORK")
    self.icon:SetAllPoints()
    self.icon:SetAtlas(VENDOR_ATLAS)
    self._ring = _pinDiscTexture(self, "BACKGROUND", PIN_SIZE, "semantic.accent")
    self._fill = _pinDiscTexture(self, "BORDER", PIN_DISC, "text.primary")
    self._num = HDG.UI.RowText(self, "caption", "Text", "CENTER")
    self._num:SetPoint("CENTER")
end

-- The vendor's icon, or a step's disc and number.
function HDGR_VendorPinMixin:PaintFace(num)
    local disc = num ~= nil
    self.icon:SetShown(not disc)
    self._ring:SetShown(disc)
    self._fill:SetShown(disc)
    self._num:SetShown(disc)
    if disc then self._num:SetText(HDG.Theme:ColorCode("surface.sunken") .. num .. "|r") end
end

function HDGR_VendorPinMixin:OnAcquired(data)
    self:SetFrameStrata("HIGH")  -- re-stamp on every acquire (recycled pins may have been touched)
    self.data = data
    self:PaintFace(data.num)
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

-- stepNum: a Decor Quests step's disc (nil for a vendor, every other Map's).
function HDG.Waypoints:AddMapPin(mapID, x, y, title, stepNum)
    _pendingPins[mapID] = _pendingPins[mapID] or {}
    -- Map on the same vendor twice used to stack a second pin on the first.
    for _, p in ipairs(_pendingPins[mapID]) do
        if p.x == x and p.y == y and p.title == title then return end
    end
    table.insert(_pendingPins[mapID], {
        mapID = mapID, x = x, y = y, title = title, num = stepNum,
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
            HDG.Waypoints:AddMapPin(uiMapID, mapX, mapY, v.name or L("WPT_PIN_VENDOR"))
            placed = placed + 1
            firstMapID = firstMapID or uiMapID
        end
    end
    return placed, firstMapID
end

-- The X by Find Decor's, Recipe Sources' and Decor Quests' search boxes.
function HDG.Waypoints:ClearAllMapPins()
    wipe(_pendingPins)
    if _pinPool then _pinPool:ReleaseAll() end
    HDG.Log:Info("waypoints_user", L("WPT_PINS_CLEARED"))
end

-- Drop Decor Quests' step pins (the numbered discs) and keep the vendor pins. Returns how
-- many it dropped.
function HDG.Waypoints:ClearStepPins()
    local dropped = 0
    for mapID, list in pairs(_pendingPins) do
        local keep = {}
        for _, p in ipairs(list) do
            if p.num then dropped = dropped + 1 else keep[#keep + 1] = p end
        end
        _pendingPins[mapID] = keep[1] and keep or nil   -- an existing key: clearing it mid-pairs is allowed
    end
    if dropped > 0 and _mapFrame and WorldMapFrame:IsShown() then _refreshAll() end
    return dropped
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
        local d = self.data
        return {
            title      = d.num and L("WPT_PIN_STEP"):format(d.num, d.title) or d.title,   -- exception(optional): only a step's pin carries num
            extraLines = { { text = L("WPT_PIN_CLICK"), r = 0.78, g = 0.78, b = 0.78 } },
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
    -- Every map canvas fires MapSet (the zone map, the hybrid minimap, the flight map, the
    -- House Finder); only the world map's own one redraws, or another canvas's map wipes our
    -- pins. The world map sets its mapID before it fires, so its own pass this check.
    EventRegistry:RegisterCallback("MapCanvas.MapSet", function(_, mapID)
        if mapID ~= WorldMapFrame:GetMapID() then return end
        _refreshWhenReady(mapID)
    end, _mapFrame)
    -- Reopening on the map it last showed fires no MapSet (SetMapID skips an unchanged map),
    -- so redraw on every open: a Map clicked, or Stop tracking pressed, while it was closed
    -- (checklist b-next-button, 10-30: the waypoint set, no disc). No mapID: the map is read
    -- when it draws, so waiting on the canvas never draws the zone a Map has since moved it off.
    WorldMapFrame:HookScript("OnShow", function() _refreshWhenReady() end)

    hooksecurefunc(WorldMapFrame, "OnFrameSizeChanged", _onResize)
    -- Zoom: react to Blizzard's canvas scale-change EVENT (taint-preserving hook),
    -- NOT a per-frame OnUpdate poll. Mirrors MapCanvasPinMixin:OnCanvasScaleChanged --
    -- the canonical map-pin approach; none poll per frame.
    hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", _onResize)

    -- Initial render in case Init runs while a map is already open.
    if WorldMapFrame:IsShown() then _refreshAll() end
end
