-- HDG.ZoneObserver
-- ============================================================================
-- Watches ZONE_CHANGED_NEW_AREA / ZONE_CHANGED / ZONE_CHANGED_INDOORS /
-- PLAYER_ENTERING_WORLD. Resolves current UI map via GetBestMapForUnit("player")
-- and dispatches ZONE_CHANGED.
--
-- Debounce 0.5s: mounted travel fires 3-5 ZONE_CHANGED_NEW_AREA in a row.
-- C_Map partitioned at sub-API; rest goes to LumberObserver / ZoneNameResolver.
-- Consumers read state.session.zone.currentMapID instead of calling C_Map.

HDG = HDG or {}
HDG.ZoneObserver = HDG.ZoneObserver or {}
local Z = HDG.ZoneObserver

Z._lastDispatched = Z._lastDispatched or 0  -- exception(false-positive): idempotent module-load init

HDG.Modules:Declare({
    name = "ZoneObserver",
    dependencies = {},
    -- per ADR-011: sole owner of C_Map.GetBestMapForUnit.
    ownsBlizzardNamespaces = { "C_Map.GetBestMapForUnit" },
    blizzardEvents = {
        -- Initial stamp on login (ZONE_CHANGED_NEW_AREA doesn't fire on login).
        PLAYER_ENTERING_WORLD   = { handler = "OnZoneChanged" },
        -- 0.5s debounce: mounted travel fires 3-5 in succession.
        ZONE_CHANGED_NEW_AREA   = { handler = "OnZoneChanged", debounce = 0.5 },
        -- Indoor/outdoor transitions can change the BEST map ID (microdungeon
        -- maps differ from their parent zone's mapID).
        ZONE_CHANGED            = { handler = "OnZoneChanged", debounce = 0.5 },
        ZONE_CHANGED_INDOORS    = { handler = "OnZoneChanged", debounce = 0.5 },
    },
    OnZoneChanged = function(self)
        Z:Probe()
    end,
    onEnable = function(self)
        -- One initial probe in case PLAYER_ENTERING_WORLD fired before the
        -- module enabled (e.g. user reloads mid-zone after bootstrap drain).
        Z:Probe()
    end,
    onShutdown = function(self)
        Z._lastDispatched = 0
    end,
})

-- The zone the player's map sits in, which is what the Zone Scanner names. The best
-- map can be an indoor or micro map below its zone; Blizzard's walk-up finds the
-- zone-type map at or above it. A map with no zone above it (a continent, or a map
-- that stands alone) is named as itself.
function Z:_ZoneLevelName(mapID, mapName)
    local zone = _G.MapUtil.GetMapParentInfo(mapID, _G.Enum.UIMapType.Zone)
    if zone then return zone.name end   -- exception(nullable): no zone-type map above a continent or a standalone map
    return mapName
end

-- Resolve current map and dispatch ZONE_CHANGED when map ID changes.
function Z:Probe()
    local mapID = _G.C_Map and _G.C_Map.GetBestMapForUnit
        and _G.C_Map.GetBestMapForUnit("player") or 0  -- exception(boundary): C_Map nil off-map / no zone
    if type(mapID) ~= "number" then mapID = 0 end
    -- Dedup: indoor transitions can produce same-ID probes from different events.
    if mapID == self._lastDispatched then return end
    self._lastDispatched = mapID
    -- Resolve human-readable zone name. Sub-zones return their own name
    -- (e.g. "The Slag Pit"); Lumber Tracker reads this directly.
    local mapName, zoneName = "", ""
    if mapID ~= 0 and _G.C_Map and _G.C_Map.GetMapInfo then
        local info = _G.C_Map.GetMapInfo(mapID)  -- exception(boundary): C_Map nil off-map / no zone
        if info and info.name then mapName = info.name end
        zoneName = self:_ZoneLevelName(mapID, mapName)
    end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.ZONE_CHANGED,
        payload = { mapID = mapID, mapName = mapName, zoneName = zoneName },
    })
end
