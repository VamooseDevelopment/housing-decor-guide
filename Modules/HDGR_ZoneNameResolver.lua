-- HDG.ZoneNameResolver
-- ============================================================================
-- Zone name -> uiMapID: a curated table of English zone names (HDGR_TrainersDB and
-- the recipe source augment name their places in English), then a one-time
-- C_Map.GetMapInfo scan for client-locale names (catalog zone strings). Localize
-- turns a curated English name into the client's language for display.
-- Silvermoon: mapID 2393 (retail Midnight Silvermoon; avoids the old 110/2393
-- ambiguity where HDG's behavior depended on dict iteration order).

HDG = HDG or {}
HDG.ZoneNameResolver = HDG.ZoneNameResolver or {}
local R = HDG.ZoneNameResolver

R._cache = R._cache or {}   -- [enUSName] = name in the client's language
R._mapNames = R._mapNames or {}   -- [uiMapID] = name, or false when the client has none (MapName)

R.ZONE_MAP_IDS = {
    -- Classic capitals
    ["Stormwind City"]              = 84,
    ["Orgrimmar"]                   = 85,
    ["Ironforge"]                   = 87,
    ["Thunder Bluff"]               = 88,
    ["Darnassus"]                   = 89,
    ["Undercity"]                   = 90,
    ["Silvermoon City"]             = 2393,  -- 12.0 Midnight (was dual 110/2393)
    ["The Exodar"]                  = 103,
    -- Classic / Cataclysm zones used as trainer locations
    ["Elwynn Forest"]               = 37,
    -- TBC
    ["Hellfire Peninsula"]          = 100,
    ["Shattrath City"]              = 111,
    -- Wrath
    ["Dalaran (Northrend)"]         = 125,
    -- MoP
    ["Jade Forest"]                 = 371,
    ["Valley of the Four Winds"]    = 376,
    ["Kun-Lai Summit"]              = 379,
    -- WoD
    ["Stormshield"]                 = 622,
    ["Warspear"]                    = 624,
    -- Legion
    ["Dalaran (Broken Isles)"]      = 627,
    -- BfA
    ["Boralus"]                     = 1161,
    ["Dazar'alor"]                  = 1165,
    -- Shadowlands
    ["Oribos"]                      = 1670,
    -- Dragonflight
    ["Valdrakken"]                  = 2112,
    -- The War Within
    ["Dornogal"]                    = 2339,
    -- Midnight (12.0.7 vendor zones)
    ["Naigtal"]                     = 2600,  -- verified in-game 2026-07-12; NOT 2623 (System=2 variant) or 924 (Legion "Invasion Point: Naigtal")
    -- Midnight trainer locations (TrainersDB). Both names have an older map the scan would find first.
    ["Eversong Woods"]              = 2395,
    ["Zul'Aman"]                    = 2437,
}

-- Zone NAME -> uiMapID. Curated table first (disambiguates duals like
-- Silvermoon), else a lazy one-time C_Map scan index. Catalog zone strings and
-- GetMapInfo names are both client-locale, so the index matches on any locale
-- (unlike the enUS-keyed curated table). First-wins on duplicate names, so
-- old-world maps shadow same-named newer ones -- add a curated entry when a
-- specific dual matters. Used for un-augmented vendors (e.g. 12.0.7 additions):
-- the catalog gives only a zone STRING, this recovers a map to draw.
local SCAN_MAX_UIMAP = 3500   -- 12.x uiMapIDs top out ~2800; headroom for new patches

function R:MapIDForName(zoneName)
    if not zoneName or zoneName == "" then return nil end  -- exception(nullable): vendors can lack a zone string
    local curated = self.ZONE_MAP_IDS[zoneName]
    if curated then return curated end
    if not self._nameIndex then
        local ZONE = Enum.UIMapType and Enum.UIMapType.Zone or 3  -- exception(boundary): headless mock lacks Enum.UIMapType
        local idx, types = {}, {}
        for id = 1, SCAN_MAX_UIMAP do
            local info = C_Map.GetMapInfo(id)  -- exception(boundary): uiMapIDs are sparse; gaps return nil
            if info and info.name and info.name ~= "" then
                -- A real ZONE map always beats a same-named continent/dungeon/
                -- orphan map (duplicate names are common; the lowest ID is often
                -- an old or non-zone variant). Within a type, first-wins.
                local have = idx[info.name]
                if not have or (types[info.name] ~= ZONE and info.mapType == ZONE) then
                    idx[info.name], types[info.name] = id, info.mapType
                end
            end
        end
        self._nameIndex = idx
    end
    return self._nameIndex[zoneName]  -- exception(nullable): sub-zone strings have no uiMap
end

-- An English zone name in the client's language, for display; filters keep the English
-- name. A zone the curated table lacks, or a map the client can't name, stays English.
-- GetMapInfo is synchronous DBC data, so a name never arrives later.
function R:Localize(enUSName)
    local cached = self._cache[enUSName]
    if cached then return cached end
    local mapID = self.ZONE_MAP_IDS[enUSName]
    local info = mapID and C_Map.GetMapInfo(mapID)   -- exception(nullable): a zone the curated table lacks has no map
    local name = (info and info.name ~= nil and info.name ~= "") and info.name or enUSName   -- exception(boundary): GetMapInfo nil or nameless for a retired map
    self._cache[enUSName] = name
    return name
end

-- Maps the game names alike, which Decor Quests lists both of: each is named with its
-- continent, "Dalaran (Northrend)", as the curated names above are (a waypoint to
-- Northrend's from Legion's read as broken, owner 10-29).
R.SAME_NAME_MAPS = { [125] = true, [627] = true }

-- name with the continent of uiMapID, for a map in SAME_NAME_MAPS.
local function _withContinent(name, uiMapID)
    if not (name and R.SAME_NAME_MAPS[uiMapID]) then return name end
    local continent = _G.MapUtil.GetMapParentInfo(uiMapID, _G.Enum.UIMapType.Continent)
    if not continent then return name end   -- exception(boundary): the game places the map on no continent
    return ("%s (%s)"):format(name, continent.name)
end

-- A uiMapID's name in the client's language, or nil when the client has none (an
-- ID it does not know, or a nameless map). Cached: Decor Quests names a zone per
-- quest step, and the same few maps recur across a line.
function R:MapName(uiMapID)
    local cached = self._mapNames[uiMapID]
    if cached ~= nil then return cached or nil end
    local info = C_Map.GetMapInfo(uiMapID)
    local name = info and info.name ~= "" and info.name or false   -- exception(boundary): GetMapInfo nil or nameless for an unknown map
    self._mapNames[uiMapID] = _withContinent(name, uiMapID)
    return self._mapNames[uiMapID] or nil
end

HDG.Modules:Declare({
    name = "ZoneNameResolver",
    dependencies = {},
    -- per ADR-011: sole owner of C_Map.GetMapInfo (MapIDForName's scan, Localize).
    -- C_Map partitioned at sub-API; see ZoneObserver / LumberObserver for the rest.
    ownsBlizzardNamespaces = { "C_Map.GetMapInfo" },
})
