-- HDG.HousingObserver
-- ============================================================================
-- The single boundary that owns all `C_Housing` + `C_NeighborhoodInitiative`
-- async-event impurity. Subscribes to housing-domain Blizzard events,
-- captures the event payloads, and dispatches Store actions. Selectors
-- never call these APIs directly -- they read from the state slots this
-- module writes into.
--
-- Domains owned (per ADR-022, observer consolidated by Blizzard API
-- namespace, not by event family):
--
--   1. Placed decor (account.styles.placedDecor):
--        HOUSE_EDITOR_MODE_CHANGED       -> topology capture only (does NOT clear)
--        HOUSING_DECOR_CUSTOMIZATION_CHANGED  -> per-decor observe (queued + batched; own house/plot gated)
--        HOUSING_DECOR_REMOVED           -> remove
--        PLAYER_ENTERING_WORLD           -> clear when leaving a house context
--
--   2. House meta (session.house.ownedHouses, keyed by houseGUID):
--        PLAYER_HOUSE_LIST_UPDATED       -> dispatch HOUSE_LIST_UPDATED
--        HOUSE_LEVEL_FAVOR_UPDATED       -> dispatch HOUSE_LEVEL_UPDATED
--
-- Initial fetch (kicks the async chain) happens at onEnable.
-- C_Housing.GetPlayerOwnedHouses is async (fires PLAYER_HOUSE_LIST_UPDATED),
-- spammy (3-5 fires on login -- 0.3s debounce on the handler).
-- C_Housing.GetCurrentHouseLevelFavor is async per house (fires
-- HOUSE_LEVEL_FAVOR_UPDATED) and the event fires for ALL houses, not just
-- the requested one -- payload includes houseGUID so the reducer can
-- target the right entry.
--
-- Placed-decor enumeration: C_HousingDecor.GetAllPlacedDecor is declared
-- HasRestrictions = true (Blizzard_APIDocumentationGenerated/HousingDecorUIDocumentation.lua:
-- "Placed Decor List APIs currently restricted due to being potentially very expensive
-- operations, may be reworked & opened up in the future"). It is a POLICY gate, not taint --
-- an addon call returns ADDON_ACTION_FORBIDDEN. Re-test each patch; Blizzard flagged it as
-- temporary. Until then the CUSTOMIZATION_CHANGED burst is the only enumeration available,
-- and it is complete (verified 21/21 vs Blizzard's own panel, 2026-07-26).

HDG = HDG or {}
HDG.HousingObserver = HDG.HousingObserver or {}
local HO = HDG.HousingObserver

-- Log tag for C_Housing / C_NeighborhoodInitiative boundary failures.
-- Surfaces SECRET-value returns + invalid-GUID throws + cold-cache nil.
HDG.Log:RegisterTags({ housing_api = { user = false, level = "warn" } })

-- =============================================================================
-- Placed-decor channel.
-- =============================================================================

local function _resolveItemID(decorID)
    -- Map decorID -> itemID via catalog observer. Catalog may not be ready on
    -- first edit-mode entry; dispatch carries decorID as fallback.
    local row = HDG.HousingCatalogObserver.byDecorID[decorID]
    return row and row.itemID
end

-- Pending batch queue. Drained on the next frame by a single dispatch.
local _queue = {}
local _flushScheduled = false

local function _flushQueue()
    _flushScheduled = false
    local entries = _queue
    _queue = {}
    local n = #entries
    if n == 0 then return end
    -- ownedContext: the reducer will not let a burst retarget
    -- session.styles.currentArea when this is false. Read through the same
    -- predicate that gates capture -- it used to be IsInsideOwnedHouse, which is
    -- false on your own plot outdoors, so the exterior burst could never point
    -- the Placed list at the exterior. HO owns C_Housing, so the read lives here.
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.STYLES_PLACED_DECOR_OBSERVED_BATCH,
        payload = { entries = entries, ownedContext = HO:InOwnHouseContext() },
    })
end

-- Own house context: inside a house you own OR on a plot you own. The two
-- halves are distinct signals -- IsInsideOwnedHouse is the only one that
-- answers indoors and plot ownership the only one outdoors (measured 2026-08-12)
-- -- and IsInsideOwnedHouseOrPlot is Blizzard's own union of them on 12.1.
-- "Owned" is account-scoped: an alt's house reads as yours. This one predicate
-- gates the placed-decor capture, stamps the batch's ownedContext, and defines
-- "leaving" for the clear, so the map, the gate and the stamp cannot disagree.
function HO:InOwnHouseContext()
    return C_Housing.IsInsideOwnedHouseOrPlot()
end

-- The interior room the player is standing in (nil if not in one). HO owns
-- C_HousingLayout; the Blueprint tab reads this to save a Room blueprint.
function HO:GetCurrentRoomGUID()
    return C_HousingLayout and C_HousingLayout.GetRoomPlayerIsIn and C_HousingLayout.GetRoomPlayerIsIn()  -- exception(boundary): C_HousingLayout Blizzard API; returns nothing outside a room
end

function HO:Observe(decorGUID)
    if type(decorGUID) ~= "string" then return end
    -- decorID from GUID "Housing-1-<plotID>-<decorID>-<hash>".
    -- exception(boundary): GetDecorInstanceInfoForGUID returns nil for freshly-enumerated GUIDs during
    -- the editor-entry burst; parse the GUID directly instead. Instance-info = optional name enrichment.
    local info = (C_HousingDecor and C_HousingDecor.GetDecorInstanceInfoForGUID
                  and C_HousingDecor.GetDecorInstanceInfoForGUID(decorGUID)) or nil  -- exception(boundary): nil during editor-entry burst
    local decorID = tonumber(decorGUID:match("^Housing%-1%-%d+%-(%d+)%-")) or (info and info.decorID)
    if not decorID then return end
    -- Area segment of the GUID. An AREA is indoors vs outdoors, NOT a room -- every
    -- interior room shares one area. This is what scopes the Placed list, matching
    -- Blizzard's panel -- verified 21/21 against it (2026-07-26).
    local areaID = tonumber(decorGUID:match("^Housing%-1%-(%d+)%-"))
    local name = (info and info.name)
              or (C_HousingDecor and C_HousingDecor.GetDecorName and C_HousingDecor.GetDecorName(decorID))  -- exception(boundary): housing C_API nil off-house-context
    _queue[#_queue + 1] = {
        decorGUID = decorGUID,
        decorID   = decorID,
        areaID    = areaID,
        itemID    = _resolveItemID(decorID),
        name      = name,
    }
    if not _flushScheduled then
        _flushScheduled = true
        C_Timer.After(0, _flushQueue)
    end
end

function HO:RemovePlaced(decorGUID)
    if type(decorGUID) ~= "string" then return end
    -- Parse decorID from GUID so pre-existing decor (never in placedDecor) is attributed.
    -- Reducer prefers live placedDecor entry's itemID + falls back to this.
    local decorID = tonumber(decorGUID:match("^Housing%-1%-%d+%-(%d+)%-"))
    local itemID  = decorID and _resolveItemID(decorID)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.STYLES_PLACED_DECOR_REMOVED,
        payload = { decorGUID = decorGUID, itemID = itemID },
    })
end

-- Stash the pending itemID here; OnDecorPlaceSuccess commits on actual world-click.
-- A cancelled pick (ESC, no PLACE_SUCCESS) records nothing.
--
-- ...but only if the pick actually EXPIRES. It used to be written here and cleared
-- nowhere else, so an ESC left it set indefinitely and the next unrelated commit
-- consumed it. Stamp the pick and treat an old one as abandoned; PLACE_FAILURE
-- clears it outright.
local PENDING_PLACE_TTL = 60   -- seconds; a pick not committed by then was abandoned

function HO:SetPendingPlacement(itemID)
    HO._pendingPlaceItemID = itemID
    HO._pendingPlaceAt     = _G.GetTime and _G.GetTime() or 0  -- exception(boundary): GetTime absent headless
end

function HO:ClearPendingPlacement()
    HO._pendingPlaceItemID = nil
    HO._pendingPlaceAt     = nil
end

-- nil when there is no live pick, or the pick has gone stale.
function HO:TakePendingPlacement()
    local itemID, at = HO._pendingPlaceItemID, HO._pendingPlaceAt
    HO:ClearPendingPlacement()
    if not itemID then return nil end  -- exception(nullable): no pick in flight
    local now = _G.GetTime and _G.GetTime() or 0  -- exception(boundary): GetTime absent headless
    if at and (now - at) > PENDING_PLACE_TTL then return nil end
    return itemID
end

function HO:ClearPlaced()
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_PLACED_DECOR_CLEAR })
end

-- =============================================================================
-- House meta channel.
-- =============================================================================

-- Faction derivation: HouseInfo struct lacks faction; derived from
-- C_Housing.DoesFactionMatchNeighborhood + the player's own faction.
local function _deriveFaction(neighborhoodGUID)
    if not (C_Housing and C_Housing.DoesFactionMatchNeighborhood and neighborhoodGUID) then
        return nil
    end
    -- Strict: sync bool getter (MCP-verified, "safe to call inline"). The pcall
    -- that used to wrap this caught nothing and would have turned a rename into
    -- a quiet nil instead of an error -- the 12.1 IsInsideOwnHouse lesson.
    local matches = C_Housing.DoesFactionMatchNeighborhood(neighborhoodGUID)
    local pFaction = UnitFactionGroup and UnitFactionGroup("player")
    if pFaction == "Alliance" then return matches and "Alliance" or "Horde"
    elseif pFaction == "Horde"  then return matches and "Horde"    or "Alliance" end
    return nil
end

-- Stable order-independent digest for deduping PLAYER_HOUSE_LIST_UPDATED re-fires.
-- Control-byte separators (US/RS, ASCII 31/30) don't occur in GUIDs/names.
local function _houseListSignature(houseInfoList)
    local parts = {}
    for _, h in ipairs(houseInfoList) do
        parts[#parts + 1] = table.concat({
            tostring(h.houseGUID), tostring(h.neighborhoodGUID),
            tostring(h.neighborhoodName), tostring(h.houseName),
            tostring(h.plotID),
        }, "\31")
    end
    table.sort(parts)
    return table.concat(parts, "\30")
end

-- Gate for the REWARD fetch only (GetHouseLevelRewardsForLevel). That call fires
-- RECEIVED_HOUSE_LEVEL_REWARDS, which Blizzard's housing dashboard rebuilds its reward track
-- on every time -- blanking the level nodes to "0" with no repaint. HDG's reward data only
-- feeds the House + Projects/Architect tabs, so we only request it while one of those is the
-- active view AND the window is shown. (Favor/level fetching stays ungated -- it drives the
-- ring and is harmless to the dashboard.) account.ui.view persists across closes, hence the
-- mainWindowShown half. Mirrors the CATALOG_CONSUMING_TAB_VIEWS gate.
-- Shared with HouseAggregator, whose dashboard build is gated on the same views.
function HO.HouseLevelViewActive(state)
    local ui = state.account.ui
    return ui.mainWindowShown == true and HDG.Constants.HOUSE_LEVEL_VIEWS[ui.view] == true
end

-- PLAYER_HOUSE_LIST_UPDATED: { houseGUID, neighborhoodGUID, neighborhoodName,
-- houseName, plotID, ... }. Faction derived here; reducer preserves level/favor on re-fire.
function HO:OnHouseList(houseInfoList)
    if type(houseInfoList) ~= "table" then return end
    -- Dedup: PLAYER_HOUSE_LIST_UPDATED re-fires 3-5 times on login with identical data.
    local sig = _houseListSignature(houseInfoList)
    if sig == HO._lastHouseListSig then return end
    HO._lastHouseListSig = sig

    local enriched = {}
    for i, h in ipairs(houseInfoList) do
        enriched[i] = {
            houseGUID        = h.houseGUID,
            neighborhoodGUID = h.neighborhoodGUID,
            neighborhoodName = h.neighborhoodName,
            houseName        = h.houseName,
            plotID           = h.plotID,
            faction          = _deriveFaction(h.neighborhoodGUID),
        }
    end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.HOUSE_LIST_UPDATED,
        payload = { houses = enriched },
    })
    -- Kick per-house favor fetch; each fires HOUSE_LEVEL_FAVOR_UPDATED async.
    -- Ungated: favor drives the house-level ring (always needed), and HOUSE_LEVEL_FAVOR_UPDATED
    -- does NOT disturb Blizzard's dashboard -- only the reward fetch does (see RequestRewardsForLevel).
    if C_Housing and C_Housing.GetCurrentHouseLevelFavor then
        for _, h in ipairs(houseInfoList) do
            if h.houseGUID then
                -- exception(fire-forget): ASYNC request, returns NOTHING (MCP-verified);
                -- the answer arrives on HOUSE_LEVEL_FAVOR_UPDATED. Unlike the sync
                -- getters above, there is no value to strict-read -- the pcall guards
                -- the REQUEST against a bad GUID, and the Warn keeps it visible.
                local ok, err = pcall(C_Housing.GetCurrentHouseLevelFavor, h.houseGUID)
                if not ok then HDG.Log:Warn("housing_api",
                    "GetCurrentHouseLevelFavor(" .. tostring(h.houseGUID) .. ") failed: " .. tostring(err)) end
            end
        end
    end
end

-- GetActiveNeighborhood is sync but cached info "invalidates immediately" (boundary:
-- stale/nil right after set). Blizzard re-fires NEIGHBORHOOD_INITIATIVE_UPDATED every
-- second; dedup against last-dispatched GUID prevents no-op churn.
function HO:OnActiveNeighborhood()
    local guid
    if C_NeighborhoodInitiative and C_NeighborhoodInitiative.GetActiveNeighborhood then
        guid = C_NeighborhoodInitiative.GetActiveNeighborhood()
    end
    if guid == HO._lastActiveNeighborhoodGUID then return end
    HO._lastActiveNeighborhoodGUID = guid
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.ACTIVE_NEIGHBORHOOD_UPDATED,
        payload = { neighborhoodGUID = guid },
    })
end

-- HOUSE_LEVEL_FAVOR_UPDATED fires with HouseLevelFavor =
-- { houseGUID, houseLevel, houseFavor }. Fires for ALL owned houses on
-- each request, not just the one we asked about -- the houseGUID lets
-- the reducer target the right entry.
--
-- Thresholds (favor-to-reach-each-level) come from sync API
-- C_Housing.GetHouseLevelFavorForLevel; we compute them once per dispatch
-- and ship in the payload. Fallback table covers headless tests + the
-- 12.0.5 edge where the API returns 0 for unreachable levels.
local FALLBACK_HOUSE_LEVEL_XP = {
    [1] = 0,    [2] = 250,   [3] = 750,   [4] = 1500,  [5] = 2500,
    [6] = 4000, [7] = 6000,  [8] = 9000,  [9] = 12900,
}

local function _buildThresholds()
    local maxLevel = 50
    if C_Housing and C_Housing.GetMaxHouseLevel then
        local max = C_Housing.GetMaxHouseLevel()
        if max then maxLevel = max end
    end
    -- Sparse fallback: trailing nils -> "0 favor needed" (visible cue to extend the table).
    local thresholds = {}
    if C_Housing and C_Housing.GetHouseLevelFavorForLevel then
        for i = 1, maxLevel do
            -- Strict: sync, returns the favor threshold directly (MCP-verified).
            local val = C_Housing.GetHouseLevelFavorForLevel(i)
            thresholds[i] = (val and val > 0) and val
                            or FALLBACK_HOUSE_LEVEL_XP[i] or 0  -- exception(boundary): sparse fallback
        end
    else
        for i = 1, maxLevel do
            thresholds[i] = FALLBACK_HOUSE_LEVEL_XP[i] or 0  -- exception(boundary): sparse fallback
        end
    end
    return maxLevel, thresholds
end

function HO:OnHouseLevelFavor(houseLevelFavor)
    if type(houseLevelFavor) ~= "table" then return end
    -- Capture only: dispatches the house level (drives the ring + My Homes). It does NOT kick a
    -- reward fetch -- rewards are pulled lazily when a House/Projects view is shown (see onEnable),
    -- matching Blizzard's fetch-once-on-open instead of re-fetching on every favor tick.
    local guid = houseLevelFavor.houseGUID
    if type(guid) ~= "string" then return end
    -- Blizz struct; fields may be omitted for brand-new houses.
    local level = houseLevelFavor.houseLevel or 1   -- exception(boundary): Blizz struct
    local favor = houseLevelFavor.houseFavor or 0   -- exception(boundary): Blizz struct
    -- Dedup per-GUID: HOUSE_LEVEL_FAVOR_UPDATED bursts on login with identical payloads.
    -- Skips _buildThresholds + rewards re-fetch on no-op path.
    HO._lastLevelFavor = HO._lastLevelFavor or {}
    local sig = level .. ":" .. favor
    if HO._lastLevelFavor[guid] == sig then return end
    HO._lastLevelFavor[guid] = sig

    local maxLevel, thresholds = _buildThresholds()
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.HOUSE_LEVEL_UPDATED,
        payload = {
            houseGUID  = guid,
            level      = level,
            favor      = favor,
            maxLevel   = maxLevel,
            thresholds = thresholds,
        },
    })
end

-- Lazy reward pull -- the ONLY initiator of reward fetches (the favor handler no longer kicks
-- them). Called when a House/Projects view is shown; fetches each owned house's next-level
-- rewards, once per level (RequestRewardsForLevel dedups on the cache). Self-gates on the view so
-- it stays off Blizzard's dashboard reward track whenever HDG isn't actually displaying rewards.
function HO:RequestRewardsForOwnedHouses()
    if not HO.HouseLevelViewActive(HDG.Store:GetState()) then return end
    for _, h in pairs(HDG.Store:GetState().session.house.ownedHouses) do
        if h.level and h.maxLevel then
            local target = (h.level < h.maxLevel) and (h.level + 1) or h.maxLevel
            HO:RequestRewardsForLevel(target)
        end
    end
end

-- =============================================================================
-- Level rewards channel.
-- =============================================================================

-- GetHouseLevelRewardsForLevel is AllowedWhenUntainted; can throw when tainted -> pcall.
function HO:RequestRewardsForLevel(level)
    if type(level) ~= "number" then return end
    -- Once per level, ever: rewards are level-based + immutable, so a cached level never needs
    -- re-fetching (the HOUSE_REWARDS_RECEIVED reducer comment anticipates exactly this dedup).
    -- Skipping the redundant fetch is also what keeps us off Blizzard's dashboard reward track --
    -- each GetHouseLevelRewardsForLevel fires RECEIVED_HOUSE_LEVEL_REWARDS, which re-inits + blanks it.
    if HDG.Store:GetState().session.house.rewardsByLevel[level] then return end
    if not (C_Housing and C_Housing.GetHouseLevelRewardsForLevel) then return end
    -- exception(fire-forget): ASYNC request, returns NOTHING (MCP-verified); the
    -- rewards arrive on RECEIVED_HOUSE_LEVEL_REWARDS. Nothing to strict-read here.
    local ok, err = pcall(C_Housing.GetHouseLevelRewardsForLevel, level)
    if not ok then HDG.Log:Warn("housing_api",
        "GetHouseLevelRewardsForLevel(" .. tostring(level) .. ") failed: " .. tostring(err)) end
end

-- RECEIVED_HOUSE_LEVEL_REWARDS fires with (level, rewards) per the global
-- event signature. Reducer caches by level.
function HO:OnHouseLevelRewards(level, rewards)
    if type(level) ~= "number" or type(rewards) ~= "table" then return end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.HOUSE_REWARDS_RECEIVED,
        payload = { level = level, rewards = rewards },
    })
end

-- =============================================================================
-- Projects topology capture channel. Reads LIVE pin frames (impure boundary);
-- pure transforms in HDG.Projects.{Capture,AutoLayout}. One atomic PROJECTS_CAPTURE_COMMIT.
-- =============================================================================

-- Static localizedName -> shapeID FALLBACK (English only, cold-catalog safety net).
-- PRIMARY resolution is the live room catalog (_buildCatalogNameToShape below), which
-- is locale-correct in every client. Kept in sync with ShapeAtlas IDs.
local NAME_TO_SHAPE = {
    ["Closet"]                  = "closet_xs",
    ["Square Room (Tiny)"]      = "square_xs",
    ["Square Room (Small)"]     = "square_s",
    ["Square Room (Medium)"]    = "square_m",
    ["Square Room (Large)"]     = "square_l",
    ["Octagon Room (Small)"]    = "octagon_s",
    ["Octagon Room (Medium)"]   = "octagon_m",
    ["Octagon Room (Large)"]    = "octagon_l",
    ["L-Shaped Room"]           = "l_shape",
    ["T-Shaped Room"]           = "t_shape",
    ["Cross-Shaped Room"]       = "cross_shape",
    ["Hallway"]                 = "hallway",
    ["Entry"]                   = "entry",
    ["Evening Circle Room"]     = "circle_evening",
    ["Daylight Circle Room"]    = "circle_daylight",
    ["Stairwell (Left)"]        = "staircase",
    ["Stairwell (Right)"]       = "staircase_mirror",
    ["Stairwell Room (Empty)"]  = "tall_room",
    -- Themed rooms (12.1). Same cold-catalog safety net as above: English only,
    -- the live catalog is the locale-correct primary. Geometry + the one-door
    -- model live in Core/HDGR_ProjectsShapeAtlas.lua; floor spans are unverified.
    ["Orgrimmar Stone Pit Room"]  = "org_stonepitroom",
    ["Stormwind Kitchen"]         = "stormwind_kitchen",
    ["Stormwind Display Room"]    = "stormwind_displayroom",
    ["Silvermoon Display Room"]   = "silvermoon_displayroom",
    ["Bel'ameth Theater"]         = "belameth_theater",
    ["Bel'ameth Nestled Bedroom"] = "belameth_bedroom",
    ["Orgrimmar Display Room"]    = "org_displayroom",
    ["Silvermoon Small Study"]    = "silvermoon_smallstudy",
    ["Stormwind Armory"]          = "stormwind_armory",
    ["Silvermoon Armory"]         = "silvermoon_armory",
    ["Bel'ameth Meeting Room"]    = "belameth_meetingroom",
    ["Orgrimmar Theater"]         = "org_theaterroom",
    ["Orgrimmar Council Room"]    = "org_councilroom",
    ["Stormwind Grand Hall"]      = "stormwind_grandhall",
    ["Silvermoon Lofty Study"]    = "silvermoon_loftystudy",
    ["Bel'ameth Temple Room"]     = "belameth_templeroom",
    ["Autumnal Westfall Barn"]    = "westfall_barn_autumnal",
    ["Springtime Westfall Barn"]  = "westfall_barn_springtime",
}

-- Entry = the base room. pin:CanRemove() reports the IsBaseRoom restriction for it (and
-- only it) -- a locale-independent signal read synchronously off the pin. Resolved at load;
-- the headless harness stubs Enum, so fall back to the known enum value there.
local ENTRY_RESTRICTION = (Enum and Enum.HousingLayoutRestriction and Enum.HousingLayoutRestriction.IsBaseRoom) or 4  -- exception(boundary): Enum.HousingLayoutRestriction absent in headless harness

-- localizedName -> shapeID, built fresh per capture from the LIVE room catalog
-- (session.house.roomCatalog). The catalog's localized name is byte-identical to
-- pinFrame:GetRoomName() (same DB2 field -- verified enUS; the recordID->shapeID bridge
-- is locale-independent by construction), so capture resolves shapes in EVERY locale,
-- not just English. Prefab rooms carry nil shapeID -> skipped (catalog iconAtlas renders them).
local function _buildCatalogNameToShape()
    local map = {}
    for _, e in ipairs(HDG.Store:GetState().session.house.roomCatalog.entries) do
        if e.shapeID then map[e.name] = e.shapeID end
    end
    return map
end

-- Pure: resolve a captured room's shapeID. The base room is the Entry anchor -- isBase comes
-- from the pin's IsBaseRoom removal restriction (locale-independent) and Entry is NOT a catalog
-- room, so neither name map can cover it. Then the live-catalog map (locale-correct), then the
-- static English fallback (cold catalog), then the raw name (unknown -> ShapeAtlas renders a
-- generic cell; never crashes).
function HO.ResolveShape(name, isBase, catalogNameToShape)
    if isBase then return "entry" end
    return catalogNameToShape[name] or NAME_TO_SHAPE[name] or name
end

local _capture     -- transient capture buffer for one Layout-mode floor session
local _activeSweep -- active "capture all floors" sweep state (timer-driven)

local function _layoutMode()   return (Enum and Enum.HouseEditorMode and Enum.HouseEditorMode.Layout)   or 3 end  -- exception(boundary): Enum.HouseEditorMode absent in headless harness
-- BasicDecor, not Decorate: 12.1 split the single decorate mode into BasicDecor(1) /
-- ExpertDecor(2), and `Decorate` is not a field on the enum at all -- it read nil and
-- rode the `or 1` fallback, correct only by the accident that 1 == BasicDecor.
local function _decorateMode() return (Enum and Enum.HouseEditorMode and Enum.HouseEditorMode.BasicDecor) or 1 end  -- exception(boundary): Enum.HouseEditorMode absent in headless harness

-- Stable houseID for the house the player is currently inside: a digest of the
-- neighborhoodName + plotID (the PLOT's identity), NOT the character's faction --
-- so a Horde house captured on an Alliance char keys correctly, and two houses
-- captured on one character don't collide. Name+plot is used (not the neighborhood
-- GUID) because the name is provably stable across sessions; the GUID's cross-session
-- stability is unverified. nil when not inside an owned house.
local function _currentHouseID()
    if not (C_Housing and C_Housing.GetCurrentHouseInfo) then return nil end   -- exception(boundary): C_Housing absent (headless / pre-login)
    -- Ownership, so the "nil when not inside an owned house" promise above is true.
    -- GetCurrentHouseInfo answers for whatever house you are standing in, neighbour's
    -- included, so without this the identity digest below would key a neighbour's plot.
    -- Only asserted when the predicate is actually present -- absent means headless.
    if C_Housing.IsInsideOwnedHouse and not C_Housing.IsInsideOwnedHouse() then return nil end
    local info = C_Housing.GetCurrentHouseInfo()
    if not (info and info.plotID and info.neighborhoodName) then return nil end -- exception(boundary): nil outside an owned house
    local key = info.neighborhoodName .. ":" .. tostring(info.plotID)
    return HDG.Projects.IDs.makeHouseID(HDG.Projects.IDs.hashToken(key))
end

-- Public accessor -- other modules must NOT re-derive house identity (HO owns C_Housing).
function HO:CurrentHouseID() return _currentHouseID() end

function HO:IsCapturing() return _capture and _capture.active or false end

-- Cancel an in-flight "capture all floors" sweep. Flag AND drop: in-flight
-- C_Timer closures check cancelled/nil; leaving _activeSweep set wedges
-- CaptureAllFloors ("already in progress") until reload (review 17 #5). Called
-- from OnEnteringWorld -- a hearth/reload mid-sweep must not wedge the next one.
function HO:CancelSweep()
    if _activeSweep then _activeSweep.cancelled = true; _activeSweep = nil end
end

-- Editor-mode + location accessors for consumers (e.g. HouseEditorCompanion).
-- HO owns C_HouseEditor + C_Housing (invariant 9); boundary: editor C_* exists only while open.
function HO:IsHouseEditorModeActive(mode)
    return (C_HouseEditor and C_HouseEditor.IsHouseEditorModeActive and C_HouseEditor.IsHouseEditorModeActive(mode)) or false  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
end
function HO:ActivateHouseEditorMode(mode)
    if C_HouseEditor and C_HouseEditor.ActivateHouseEditorMode then C_HouseEditor.ActivateHouseEditorMode(mode) end  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
end
function HO:IsInsideHouse()
    return (C_Housing and C_Housing.IsInsideHouse and C_Housing.IsInsideHouse()) or false  -- exception(boundary): C_Housing is a Blizzard API namespace; nil in headless tests
end

function HO:_BeginCapture(floor)
    -- nextIndex stamps capture order per room (surfaced in "Hallway 2" labels).
    _capture = { active = true, floor = floor or 1, rooms = {}, nextIndex = 1 }
    -- The bucket's floor is the SWEEP's counter; the game's viewed floor is the
    -- truth about which floor's pins are about to arrive. Log both: when they
    -- disagree, the rooms land under the wrong floor (owner-observed 2026-08-28 --
    -- capture floor 1 held the house's third storey).
    HDG.Log:Warn("projects_save", ("capture: arm floor %d (viewed=%s)")
        :format(_capture.floor, tostring(C_HousingLayout and C_HousingLayout.GetViewedFloor and C_HousingLayout.GetViewedFloor())))  -- exception(boundary): C_HousingLayout absent headless
    HDG.CaptureTap.OnBegin(_capture.floor)   -- raw-stream tap (inert unless HDG_DB.captureTap)
end

function HO:_EndCapture()
    if not (_capture and _capture.active) then return nil end
    local n = 0
    for _ in pairs(_capture.rooms) do n = n + 1 end
    HDG.Log:Warn("projects_save", ("capture: commit floor %d: %d room(s) (viewed=%s)")
        :format(_capture.floor, n, tostring(C_HousingLayout and C_HousingLayout.GetViewedFloor and C_HousingLayout.GetViewedFloor())))  -- exception(boundary): C_HousingLayout absent headless
    HDG.CaptureTap.OnEnd()
    _capture.active = false
    local snap = _capture
    _capture = nil
    return snap
end

-- _pinPos: diagnostic screen-coord probe (posAdd/posFinal research; not yet driving layout).
-- Gated on HDG_DB.perf so production sweep allocates nothing per pin. The probing
-- itself lives in CaptureTap (shared with the raw-stream tap).
local function _pinPos(pin)
    -- exception(boundary): raw SavedVariable read.
    if not (_G.HDG_DB and _G.HDG_DB.perf) then return nil end
    return HDG.CaptureTap.ProbeGeometry(pin)
end

-- Ingest one live pin frame into the capture buffer (impure boundary read).
local function _ingestPin(pinFrame)
    if not (_capture and pinFrame and pinFrame.GetPinType) then return end
    local pinType  = pinFrame:GetPinType()
    local roomGUID = pinFrame:GetRoomGUID()
    if not roomGUID then return end
    local room = _capture.rooms[roomGUID]
    if not room then
        room = { roomGUID = roomGUID, capturedID = roomGUID, doors = {}, captureIndex = _capture.nextIndex }
        _capture.rooms[roomGUID] = room
        _capture.nextIndex = _capture.nextIndex + 1
    end
    if pinType == 1 then   -- room pin
        -- Entry = the base room: pin:CanRemove() == IsBaseRoom restriction. Read synchronously
        -- off the pin, NOT via C_HousingLayout.IsBaseRoom(guid) (field-reported unreliable).
        -- Locale-independent -- Entry is not a catalog room and GetRoomName is localized.
        room.isBase = pinFrame:CanRemove() == ENTRY_RESTRICTION
        room.name  = pinFrame:GetRoomName()
        _capture.nameToShape = _capture.nameToShape or _buildCatalogNameToShape()   -- locale-correct map; built once per capture
        room.shape = HO.ResolveShape(room.name, room.isBase, _capture.nameToShape)
        room._roomPin = pinFrame   -- temp ref; restriction flags + final pos read at finalize
        room.posAdd   = _pinPos(pinFrame)   -- diagnostic: screen coords at pin-add time
    elseif pinType == 0 then  -- door pin
        local d = pinFrame:GetDoorConnectionInfo()
        if d then
            room.doors[#room.doors + 1] = {
                doorID         = d.doorID,
                connectionType = d.connectionType,
                facing         = d.doorFacing,
                occupied       = pinFrame:IsOccupiedDoor() and true or false,
            }
        end
    end
end

function HO:OnPinFrameAdded(pinFrame)
    HDG.CaptureTap.OnPin(pinFrame)   -- raw stream, pre-filter (tap records nil-roomGUID pins too)
    if _capture and _capture.active then _ingestPin(pinFrame) end
end

-- Every existing room ID on a floor -- compared against a recapture's
-- deterministic IDs to find genuinely-removed rooms (see _FinalizeCapture).
local function _existingRoomIDsForFloor(floorID)
    -- Recapture diffs against the live LAYOUT's placements by their captured
    -- identity: slots carry capturedID directly; matched rooms carry it as the
    -- room record's lineage (legacyID). boundary: a never-captured house has
    -- no layout yet -> nothing existing to diff.
    local IDs    = HDG.Projects.IDs
    local parsed = IDs.parsePath(floorID)
    local state  = HDG.Store:GetState()
    local p      = state.account.projects
    local house  = parsed and parsed.houseID and p.houses[parsed.houseID]
    local layout = house and house.currentVersionID and p.layouts[house.currentVersionID]
    local out = {}
    if not layout then return out end
    -- v8: lineage lives on the placement (capturedID) -- direct read.
    for _, pl in pairs(layout.placements) do
        local rp = pl.capturedID and IDs.parsePath(pl.capturedID)
        if rp and rp.floorID == floorID then out[#out + 1] = pl.capturedID end
    end
    return out
end

-- Build fresh room records from the snapshot with DETERMINISTIC IDs (floor +
-- capture-order) so crates stay attached on recapture; old rooms not reproduced
-- fall to orphaned crates. SECTIONS model (solver spec SS10): every enumerated
-- room IS its own placement -- stair shapes arrive as one section per floor
-- (own roomGUID each, span 1), gardens as one record on their base floor
-- (span 3 via ShapeAtlas). No shape-keyed dedup: the old seenLowerMF/mfSpan
-- machinery collapsed genuinely-distinct stacked rooms and discarded their
-- door data (2026-08-10 review criticals #1/#4/#7/#10).
local function _buildCapturedRooms(snapshot, floorID)
    local IDs, Cap, rooms = HDG.Projects.IDs, HDG.Projects.Capture, {}
    for _, r in pairs(snapshot.rooms) do
        local id = IDs.makeRoomID(floorID, tostring(r.captureIndex))   -- captureIndex always stamped at ingest
        if id then rooms[id] = Cap.buildRoomRecord(r) end
    end
    return rooms
end

-- Existing rooms on this floor not reproduced by the capture -> deleted (their
-- crates fall to the orphan bay, recoverable via the orphan UI).
local function _computeDeletedRoomIDs(rooms, floorID)
    local deleteRoomIDs = {}
    for _, oldID in ipairs(_existingRoomIDsForFloor(floorID)) do
        if not rooms[oldID] then deleteRoomIDs[#deleteRoomIDs + 1] = oldID end
    end
    return deleteRoomIDs
end

-- The house's committed live-layout placements, or nil before the first capture.
local function _committedPlacements(houseID)
    local p      = HDG.Store:GetState().account.projects
    local house  = p.houses[houseID]
    local layout = house and house.currentVersionID and p.layouts[house.currentVersionID]
    return layout and layout.placements or nil   -- exception(nullable): first capture of a house has no committed layout
end

-- Solver seed: cells already occupied on `floor` by OTHER floors' committed
-- multi-span rooms (garden volumes; planner-stamped stair spans) -- FloorMap
-- projects spans, and the solver must not place into them (solver spec SS5.5).
-- Rooms committed on THIS floor are excluded: the capture replaces them.
local function _seedCellsFor(placements, floor)
    if not placements then return nil end
    local SA = HDG.Projects.ShapeAtlas
    local rooms, exclude = {}, {}
    for key, pl in pairs(placements) do
        -- A CAPTURED stair section's `floors` override is a PLAN ("Expand up"),
        -- not reality -- projecting it into the seed would pin-conflict the very
        -- capture that materializes the plan as a real section (review #2).
        local floors = pl.floors
        if floors and pl.capturedID and SA.IsStairShape(pl.shape) then floors = nil end
        rooms[key] = { shape = pl.shape, floor = pl.floor, floors = floors,
                       cell = { x = pl.x, y = pl.y, rotation = pl.rotation } }
        if pl.floor == floor then exclude[key] = true end
    end
    return HDG.Projects.FloorMap.OccupiedCells(rooms, floor, exclude)
end

-- Anchored-from-below (owner-ruled, solver spec SS10): cells on `floor` that
-- have a ROOF under them -- committed rooms one floor down whose span TOPS OUT
-- there. Circle shapes never support (open sky). floor 1 (the lowest) is
-- unconstrained -> nil; an upper floor with nothing committed below returns {}
-- so the solver falls back rather than solving in an unanchored frame.
local function _supportCellsFor(placements, floor)
    if floor <= 1 then return nil end
    local SA, support = HDG.Projects.ShapeAtlas, {}
    for _, pl in pairs(placements or {}) do   -- exception(nullable): no committed floors below yet -> empty support -> fallback
        -- Same rule as _seedCellsFor: a CAPTURED stair section's `floors` override is a
        -- PLAN ("Expand up"), not reality. Reading it raw here made the two functions
        -- disagree about the same field on the same records -- the plan's span pushed the
        -- room's top out of this floor's support, so its footprint vanished from `support`,
        -- the room above failed _fits, and the floor grid-packed on every recapture
        -- (review 2026-08-23).
        local floors = pl.floors
        if floors and pl.capturedID and SA.IsStairShape(pl.shape) then floors = nil end
        local span = floors or SA.GetFloors(pl.shape)
        if (pl.floor + span - 1) == (floor - 1) and not SA.IsCircle(pl.shape) then
            local cells = SA.GetCells(pl.shape)
            for _, m in ipairs(SA.RotateMask(SA.GetMask(pl.shape), pl.rotation or 0, cells[1], cells[2])) do
                support[(pl.x + m[1]) .. "," .. (pl.y + m[2])] = true
            end
        end
    end
    return support
end

-- Vertical pinning (solver spec SS10): a captured stair SECTION on this floor
-- sits directly above its lower-floor mate. Mate preference (owner-refined
-- 2026-08-10, "a diff should help us with placement"):
--   1. CONTINUITY -- the section was committed before (same placementIndex on
--      this floor): its tower is the same-shape section now sitting at its old
--      cell one floor down. Recaptures keep established towers; only sections
--      NEW to this capture run chronology matching.
--   2. Largest counter below its own (subsumes tower-mate adjacency: the
--      directly-preceding counter is the largest possible). Counters can lie
--      after edit churn (lowest-free-slot reuse, spec SS2.2) -- acceptable,
--      continuity shields established towers.
-- Each lower section anchors at most one upper section.
local function _pinsFor(rooms, floor, placements)
    if floor <= 1 or not placements then return nil end
    local SA  = HDG.Projects.ShapeAtlas
    local ids = {}
    for id, rec in pairs(rooms) do
        if SA.IsStairShape(rec.shape) and rec.placementIndex then ids[#ids + 1] = id end
    end
    if #ids == 0 then return nil end
    table.sort(ids, function(a, b) return rooms[a].placementIndex < rooms[b].placementIndex end)

    -- Lower-floor mate candidates + this floor's previous commit (continuity).
    local lower, prevCell, unindexed = {}, {}, false
    for key, pl in pairs(placements) do
        if SA.IsStairShape(pl.shape) then
            if pl.floor == floor - 1 then
                lower[key] = pl
                if not pl.placementIndex then unindexed = true end
            elseif pl.floor == floor and pl.placementIndex then
                prevCell[pl.placementIndex] = { x = pl.x, y = pl.y }
            end
        end
    end

    local pins, used = {}, {}
    for _, id in ipairs(ids) do   -- pass 1: continuity
        local rec = rooms[id]
        local old = prevCell[rec.placementIndex]
        if old then
            for key, pl in pairs(lower) do
                if not used[key] and pl.shape == rec.shape and pl.x == old.x and pl.y == old.y then
                    used[key], pins[id] = true, { x = pl.x, y = pl.y }
                    break
                end
            end
        end
    end
    -- Pass 2a: SIBLING COUNTER. Placing a stairwell mints BOTH of its sections in
    -- one action, so the pair's placement counters are ADJACENT -- |delta| == 1 --
    -- no matter which floor was built first. This is the direction-free test that
    -- pass 2b cannot make: 2b requires the floor BELOW to carry the smaller
    -- counter, which is only true of a house built UPWARD from its entry. Build
    -- downward -- entry on floor 4, cellars dug afterwards -- and the basements
    -- carry the HIGHER counters, so the mate is never found and every floor packs
    -- to its own origin. Measured on the owner's five-floor manor 2026-08-28: all
    -- four shafts were adjacent pairs (3/4, 5/6, 9/10, 21/22) and three of them
    -- failed to pin under the chronological rule alone.
    for _, id in ipairs(ids) do
        if not pins[id] then
            local rec, sibKey = rooms[id], nil
            for key, pl in pairs(lower) do
                if not used[key] and pl.shape == rec.shape and pl.placementIndex
                   and math.abs(pl.placementIndex - rec.placementIndex) == 1
                   and (sibKey == nil or key < sibKey) then
                    sibKey = key
                end
            end
            if sibKey then
                used[sibKey] = true
                pins[id] = { x = placements[sibKey].x, y = placements[sibKey].y }
            end
        end
    end
    -- Pass 2b: chronology, for sections whose sibling counter was lost to the
    -- allocator reusing a freed slot after an edit (spec SS2.2).
    for _, id in ipairs(ids) do
        if not pins[id] then
            local rec, bestKey, bestIdx = rooms[id], nil, nil
            for key, pl in pairs(lower) do
                if not used[key] and pl.shape == rec.shape
                   and pl.placementIndex and pl.placementIndex < rec.placementIndex
                   and (bestIdx == nil or pl.placementIndex > bestIdx
                        or (pl.placementIndex == bestIdx and key < bestKey)) then
                    bestKey, bestIdx = key, pl.placementIndex
                end
            end
            if bestKey then
                used[bestKey] = true
                pins[id] = { x = placements[bestKey].x, y = placements[bestKey].y }
            elseif unindexed then
                -- Pre-upgrade lower placements carry no placementIndex until a
                -- bottom-up recapture -- say so instead of silently not pinning.
                HDG.Log:Info("projects_save", "stairwell pinning skipped: the floor below predates this version -- run Capture All Floors once to heal")
            end
        end
    end
    return next(pins) and pins or nil
end

-- Seam for tests: the pin matcher is the whole reason floors stack rather than
-- float, and it is pure (rooms + floor + placements in, pins out).
HO._TEST_pinsFor = _pinsFor

-- Frame anchor (solver spec SS10): an UNCONSTRAINED re-solve (lowest floor) must
-- not shift the shared frame under committed upper floors -- translate the fresh
-- layout so a previously-known room keeps its old cell.
local function _anchorToPrevious(rooms, packed, placements)
    if not placements then return end
    local prev = {}
    for _, pl in pairs(placements) do
        if pl.capturedID then prev[pl.capturedID] = { x = pl.x, y = pl.y } end
    end
    local anchorID
    for id, rec in pairs(rooms) do
        if prev[id] and packed[id] then
            if not anchorID
               or (rec.placementIndex or math.huge) < (rooms[anchorID].placementIndex or math.huge)
               or ((rec.placementIndex or math.huge) == (rooms[anchorID].placementIndex or math.huge) and id < anchorID) then
                anchorID = id
            end
        end
    end
    if not anchorID then return end
    local dx = prev[anchorID].x - packed[anchorID].cell.x
    local dy = prev[anchorID].y - packed[anchorID].cell.y
    if dx == 0 and dy == 0 then return end
    for _, placed in pairs(packed) do
        placed.cell.x, placed.cell.y = placed.cell.x + dx, placed.cell.y + dy
    end
end

-- AutoLayout stamps each room's cell: connectivity-solved arrangement when the
-- capture carries the transient door data, grid-pack rows otherwise. Baked into
-- stored cells; E4-drag re-positions afterwards.
local function _packRoomCells(rooms, floor, houseID)
    local placements = _committedPlacements(houseID)
    local seed       = _seedCellsFor(placements, floor)
    local support    = _supportCellsFor(placements, floor)
    local pins       = _pinsFor(rooms, floor, placements)
    local packed = HDG.Projects.AutoLayout.compute({
        rooms = rooms, seedCells = seed, supportCells = support, pins = pins,
    }).layout
    -- Unconstrained solves (lowest floor) anchor to the previous capture so the
    -- shared frame never shifts under committed upper floors.
    if not ((seed and next(seed)) or support or pins) then
        _anchorToPrevious(rooms, packed, placements)
    end
    for roomID, placed in pairs(packed) do
        local rec = rooms[roomID]
        if rec then
            rec.cell = { x = placed.cell.x, y = placed.cell.y, rotation = placed.rotation or 0, locked = false }
        end
    end
end

-- Persist ONLY the SSoT fields. doors/recordID fed the solver (capture-time
-- inputs) -- not stored; doors/occupancy derive from cell + shape.
-- placementIndex IS kept: immutable per-house identity (solver spec SS10),
-- the vertical-pinning signal for stair sections on the floor above.
local function _stripToSSoTFields(rooms)
    for id, rec in pairs(rooms) do
        rooms[id] = {
            shape  = rec.shape, name = rec.name, cell = rec.cell,
            isBase = rec.isBase, captureIndex = rec.captureIndex,
            placementIndex = rec.placementIndex,
        }
    end
end

-- House identity for display + the capture-commit dispatch. boundary:
-- C_Housing.GetCurrentHouseInfo() -> { houseName, plotID, neighborhoodName,
-- houseGUID, ownerName }; houseGUID is process-scoped (opaque handle) so we KEY
-- by faction and only LABEL by name.
local function _dispatchCaptureCommit(houseID, rooms, deleteRoomIDs)
    local info = (C_Housing and C_Housing.GetCurrentHouseInfo and C_Housing.GetCurrentHouseInfo()) or nil  -- exception(boundary): C_Housing is a Blizzard API namespace; returns nil in headless tests
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PROJECTS_CAPTURE_COMMIT,
        payload = {
            houseID = houseID,
            rooms = rooms, deleteRoomIDs = deleteRoomIDs,
            lastCapturedAt = (time and time() or 0),  -- exception(boundary): GetTime/time absent in headless harness
            houseName        = info and info.houseName,
            plotID           = info and info.plotID,
            neighborhoodName = info and info.neighborhoodName,
        },
    })
end

-- Finalize a captured floor by REPLACING the live layout. Every existing room deleted
-- (crates fall to orphan bay); captured rooms added with fresh deterministic IDs +
-- grid-packed cells. No fingerprint-merge (matching identical shapes was ambiguous).
function HO:_FinalizeCapture(snapshot, houseID)
    if not (snapshot and houseID) then
        HDG.Log:Warn("projects_save", "capture discarded: missing snapshot or houseID (left the house mid-capture?)")
        return
    end
    local floor   = snapshot.floor or 1
    local floorID = HDG.Projects.IDs.makeFloorID(houseID, floor)
    if not floorID then
        HDG.Log:Warn("projects_save", "capture discarded: bad floor " .. tostring(floor))
        return
    end

    -- Drop the live pin refs (restriction flags + diagnostics no longer persisted -- Phase 4).
    for _, room in pairs(snapshot.rooms) do room._roomPin = nil end

    local rooms         = _buildCapturedRooms(snapshot, floorID)
    local deleteRoomIDs = _computeDeletedRoomIDs(rooms, floorID)
    _packRoomCells(rooms, floor, houseID)
    _stripToSSoTFields(rooms)
    _dispatchCaptureCommit(houseID, rooms, deleteRoomIDs)
end

-- Forward declarations: both live with the sweep below, but the passive capture
-- handlers above need them -- the range start to map a viewed index to a capture
-- floor, and the arrival hook so the floor-changed event can drive an active sweep.
local _floorRangeStart
local _onSweepFloorArrived

-- GetViewedFloor returns the GAME floor INDEX, which starts at the lowest occupied
-- floor (measured 0, basements included). Rebase it onto the 1-based capture floor;
-- fed raw it was doubly wrong: ground-floor passives were silently
-- DISCARDED (makeFloorID rejects 0) and upper-storey passives committed one floor
-- low, replacing the floor below via the recapture diff (solver spec SS2.8).
local function _viewedCaptureFloor()
    local viewed = (C_HousingLayout and C_HousingLayout.GetViewedFloor and C_HousingLayout.GetViewedFloor()) or 0  -- exception(boundary): C_HousingLayout is a Blizzard API namespace; nil in headless tests
    local lo = _floorRangeStart()
    return (viewed - lo) + 1
end

-- Passive capture: begin on Layout entry, finalize on exit. Suppressed during active sweep.
function HO:_OnCaptureModeChanged()
    if _activeSweep then return end
    local active = C_HouseEditor and C_HouseEditor.IsHouseEditorActive and C_HouseEditor.IsHouseEditorActive() or false  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
    local mode   = (C_HouseEditor and C_HouseEditor.GetActiveHouseEditorMode and C_HouseEditor.GetActiveHouseEditorMode()) or 0  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
    if active and mode == _layoutMode() then
        if not self:IsCapturing() then
            self:_BeginCapture(_viewedCaptureFloor())
        end
    elseif self:IsCapturing() then
        local snap, houseID = self:_EndCapture(), _currentHouseID()
        if snap and houseID then self:_FinalizeCapture(snap, houseID) end
    end
end

function HO:OnLayoutFloorChanged()
    -- During a sweep this event is the ARRIVAL signal, not a passive recapture cue.
    if _activeSweep then _onSweepFloorArrived(); return end
    if not self:IsCapturing() then return end
    local snap, houseID = self:_EndCapture(), _currentHouseID()
    if snap and houseID then self:_FinalizeCapture(snap, houseID) end
    self:_BeginCapture(_viewedCaptureFloor())
end

-- Arrival is an EVENT, not a duration. The client does not reach a requested floor
-- synchronously and the trip scales with distance: MEASURED 2026-08-28 (capture
-- diagnostics, 5-floor house), SetViewedFloor(0) issued while showing floor 4 still
-- reported viewed=2 a second and a half later. Against the old fixed settle every
-- bucket opened and closed mid-transit -- floor 1 banked a floor it was merely
-- passing, and the lowest floor was never displayed inside ANY window, so it never
-- captured at all (bottom storey missing, floor 1 holding the third).
--
-- So we wait on HOUSING_LAYOUT_VIEWED_FLOOR_CHANGED rather than on a timer. Two
-- cases a pure event wait would hang on, both handled:
--   * already there -- SetViewedFloor to the current floor emits NO change event,
--     so check before subscribing;
--   * the event never comes -- a backstop fires so a sweep can't stall forever,
--     and says which floor drifted rather than banking it silently.
-- The settle that remains covers only pin EMISSION after arrival, which is what it
-- was always meant to measure.
-- A floor request can be DROPPED. Measured 2026-08-28: the sweep's first
-- SetViewedFloor is issued right after ActivateHouseEditorMode(layout), lands before
-- the mode switch has taken, and is discarded -- the client sat on the player's own
-- floor for the full 5s timeout while every later call arrived within a second. One
-- request is therefore not enough; re-assert it until the client actually moves.
-- (This was the whole bug: with floor 1's request dropped, its bucket banked
-- whichever floor the player happened to be standing on.)
local FLOOR_ARRIVE_TIMEOUT, FLOOR_RETRY = 5, 0.75
local function _viewedFloorNow()
    return C_HousingLayout and C_HousingLayout.GetViewedFloor and C_HousingLayout.GetViewedFloor()  -- exception(boundary): C_HousingLayout absent headless
end

local function _awaitViewedFloor(target, onArrive)
    if not _activeSweep or _activeSweep.cancelled then return end
    if _viewedFloorNow() == target then onArrive(); return end   -- already displayed: no event will fire
    _activeSweep.awaitTarget, _activeSweep.awaitFn = target, onArrive
    local seq = (_activeSweep.awaitSeq or 0) + 1
    _activeSweep.awaitSeq = seq
    local function stillWaiting()
        return _activeSweep and not _activeSweep.cancelled
           and _activeSweep.awaitSeq == seq and _activeSweep.awaitFn ~= nil
    end
    local function reassert()
        if not stillWaiting() then return end
        if C_HousingLayout and C_HousingLayout.SetViewedFloor then C_HousingLayout.SetViewedFloor(target) end
        C_Timer.After(FLOOR_RETRY, reassert)
    end
    C_Timer.After(FLOOR_RETRY, reassert)
    C_Timer.After(FLOOR_ARRIVE_TIMEOUT, function()
        if not _activeSweep or _activeSweep.cancelled then return end
        if _activeSweep.awaitSeq ~= seq or not _activeSweep.awaitFn then return end   -- already arrived
        HDG.Log:Warn("projects_save",
            ("capture: floor %d never displayed (asked index %d, showing %s) -- capturing anyway")
            :format(_activeSweep.floor, target, tostring(_viewedFloorNow())))
        local fn = _activeSweep.awaitFn
        _activeSweep.awaitTarget, _activeSweep.awaitFn = nil, nil
        fn()
    end)
end

-- Called from the floor-changed EVENT while a sweep is running.
_onSweepFloorArrived = function()
    if not (_activeSweep and _activeSweep.awaitFn) then return end
    if _viewedFloorNow() ~= _activeSweep.awaitTarget then return end   -- passing through, not arrived
    local fn = _activeSweep.awaitFn
    _activeSweep.awaitTarget, _activeSweep.awaitFn = nil, nil
    fn()
end

-- Active sweep: Decorate->Layout (re-emits pins), iterate floors with settle delay.
-- SetViewedFloor is 0-INDEXED.
local function _stepSweep()
    if not _activeSweep or _activeSweep.cancelled then return end
    local nextFloor = _activeSweep.floor + 1
    if HO:IsCapturing() then
        local snap, houseID = HO:_EndCapture(), _currentHouseID()
        if snap and houseID then HO:_FinalizeCapture(snap, houseID) end
    end
    if nextFloor > _activeSweep.maxFloor then
        if C_HouseEditor and C_HouseEditor.LeaveHouseEditor then C_HouseEditor.LeaveHouseEditor() end
        local floors = _activeSweep.maxFloor
        _activeSweep = nil
        -- Capture summary off the ApplyCapture echo (matched vs to-assign vs
        -- unplaced rooms). Rooms/furnishings persist by construction -- the
        -- "removed" count is placements only, never lost work.
        local cap   = HDG.Store:GetState().session.furn.lastCapture or {}   -- exception(boundary): echo absent pre-first-commit
        local total = (cap.matched or 0) + (cap.slots or 0)
        local msg   = ("House captured (%d floor%s) -- %d room%s"):format(
            floors, floors == 1 and "" or "s", total, total == 1 and "" or "s")
        local parts = {}
        if (cap.matched or 0) > 0 then parts[#parts + 1] = cap.matched .. " matched" end
        if (cap.slots or 0) > 0 then parts[#parts + 1] = cap.slots .. " to assign (click a * room)" end
        if (cap.removed or 0) > 0 then
            parts[#parts + 1] = cap.removed .. " no longer placed (furnishings safe in My Designs)"
        end
        if #parts > 0 then msg = msg .. ": " .. table.concat(parts, ", ") end
        HDG.Log:Success("projects_save", msg)
        return
    end
    _activeSweep.floor = nextFloor
    local target = _activeSweep.lowest + nextFloor - 1
    if C_HousingLayout and C_HousingLayout.SetViewedFloor then C_HousingLayout.SetViewedFloor(target) end
    -- Arm only once the client is SHOWING the floor: its pins are what belongs in
    -- this bucket, and anything emitted in transit belongs to a floor we are not
    -- capturing.
    _awaitViewedFloor(target, function()
        HO:_BeginCapture(nextFloor)
        C_Timer.After(_activeSweep.settleSeconds, _stepSweep)
    end)
end

-- The occupied floor RANGE. MEASURED in-game 2026-08-28 (/hdgr floors, a 5-floor
-- house with three storeys below its entry):
--     GetNumFloors 5 | lowest 0 | highest 4 | GetBaseRoomFloor 3
--     AnyRoomsOnFloor answers only on 0..4; nothing below 0.
-- So floor INDICES are 0-based from the lowest storey even when the house is built
-- downward -- the 2026-08-10 ruling recorded here is CONFIRMED, not superseded, and
-- basements are NOT negative. (An earlier read of this code inferred negative
-- indexing from the existence of GetLowestOccupiedFloorIndex and the
-- OCCUPIED_FLOOR_RANGE_CHANGED event; the dump disproves it. Don't re-derive it.)
--
-- What the entry's position DOES change is nothing here: GetBaseRoomFloor was 3 on
-- that house while the sweep still starts at index 0, and the floor carrying the
-- Entry room captured as floor 4 = base 3 + 1, exactly as the mapping intends.
--
-- The range API is still what we read, because it states its own start rather than
-- assuming one; it happens to equal 0 today. GetNumFloors survives on live via
-- Blizzard_Deprecated (loadDeprecationFallbacks, default on) as (highest-lowest)+1,
-- so it is a COUNT and cannot tell us where the range begins -- fallback only.
-- exception(boundary): C_HousingLayout is a Blizzard API namespace; nil in headless tests.
local function _floorRange()
    local CL = C_HousingLayout
    if not CL then return nil end
    if CL.GetLowestOccupiedFloorIndex and CL.GetHighestOccupiedFloorIndex then   -- 12.1: the real range
        local lo, hi = CL.GetLowestOccupiedFloorIndex(), CL.GetHighestOccupiedFloorIndex()
        if lo and hi and hi >= lo then return lo, hi end
    end
    if CL.GetNumFloors then                                                      -- 12.0.x: lowest was always 0
        local n = CL.GetNumFloors()
        if n and n >= 1 then return 0, n - 1 end
    end
    return nil
end

_floorRangeStart = function()
    local lo = _floorRange()
    return lo or 0   -- exception(boundary): no range off-house-context; 0 keeps the old mapping
end

local function _numFloors()
    local lo, hi = _floorRange()
    if not lo then return nil end
    return (hi - lo) + 1
end

-- /hdgr floors -- raw Blizzard floor-indexing dump. The capture's floor mapping
-- rests on how the game numbers floors in a house with rooms BELOW the entry, and
-- that has never been read back from a live basement house -- it was RULED from
-- houses whose entry was the ground floor. This prints the ground truth instead of
-- inferring it: the occupied range, the base (entry) floor, and a per-index probe
-- wide enough to catch negative indexing if it exists. Dev tool; prints, mutates
-- nothing.
function HO:FloorDump()
    local CL, CH = C_HousingLayout, C_Housing
    local function fmt(v)
        if v == nil then return "|cff888888nil|r" end
        return "|cffffd200" .. tostring(v) .. "|r"
    end
    local function call(tbl, fn, ...)
        if not (tbl and tbl[fn]) then return nil, "absent" end
        local ok, a, b = pcall(tbl[fn], ...)   -- exception(boundary): probing an undocumented Blizzard surface; a throw is data
        if not ok then return nil, "error" end
        return a, b
    end
    print("|cff66ccffHDGR floor dump|r")
    print("  inside owned house: " .. fmt((call(CH, "IsInsideOwnedHouse"))))
    print("  GetNumFloors():                " .. fmt((call(CL, "GetNumFloors"))))
    print("  GetLowestOccupiedFloorIndex(): " .. fmt((call(CL, "GetLowestOccupiedFloorIndex"))))
    print("  GetHighestOccupiedFloorIndex():" .. fmt((call(CL, "GetHighestOccupiedFloorIndex"))))
    print("  GetViewedFloor():              " .. fmt((call(CL, "GetViewedFloor"))))
    print("  GetBaseRoomFloor():            " .. fmt((call(CL, "GetBaseRoomFloor"))))
    -- The probe: which indices actually hold rooms, and which the game will accept.
    -- If basements are negative, the negative half answers true; if the range is
    -- 0..N-1, it does not. Either way this settles it without a guess.
    local rows = {}
    for i = -6, 10 do
        local any = (call(CL, "AnyRoomsOnFloor", i))
        local can = (call(CL, "CanSetViewedFloor", i))
        if any ~= nil or can ~= nil then
            rows[#rows + 1] = string.format("%d:%s%s", i,
                any and "rooms" or "-", can and "/settable" or "")
        end
    end
    print("  per-index probe (AnyRoomsOnFloor / CanSetViewedFloor):")
    print("    " .. (#rows > 0 and table.concat(rows, "  ") or "|cff888888no index answered|r"))
    print("  |cff888888(run inside your house; Layout mode gives the fullest answer)|r")
end

function HO:CaptureAllFloors()
    if _activeSweep then return false, "already in progress" end
    -- IsInsideOwnedHouse, not IsInsideHouse. The comment here has always said "must be
    -- inside YOUR house", but IsInsideHouse has no ownership component -- so standing in
    -- a neighbour's open house it answered true, the sweep ran, and it wrote a Projects
    -- record keyed to the NEIGHBOUR's plot while driving SetViewedFloor through someone
    -- else's layout (review 2026-08-23). IsInsideOwnedHouse is the only ownership signal
    -- that still answers indoors -- plot owner-type data is not served inside an interior --
    -- and it is ACCOUNT-scoped, so a house owned by another of your characters still
    -- counts, which is what we want.
    if not (C_Housing and C_Housing.IsInsideOwnedHouse and C_Housing.IsInsideOwnedHouse()) then  -- exception(boundary): housing C_API nil off-house-context
        return false, "Enter your own house to capture floors"
    end
    if not (C_HouseEditor and C_HouseEditor.IsHouseEditorStatusAvailable and C_HouseEditor.IsHouseEditorStatusAvailable()) then  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
        return false, "house editor not available -- visit your house first"
    end
    local houseID = _currentHouseID()
    if not houseID then return false, "could not determine faction" end
    if self:IsCapturing() then self:_EndCapture() end

    -- Recapture prep (v8): placements persist so tags survive; CLEAR prunes
    -- only capture-owned placements above the current floor count + resets
    -- the capture echo. Per-floor diffs handle removals on surviving floors.
    -- A nil floor count must ABORT: defaulting to 1 would prune every upper
    -- floor's placements and then never revisit them (2026-08-10 review #6).
    local maxFloor = _numFloors()
    if not maxFloor then
        HDG.Log:Warn("projects_save", "capture aborted: floor count unavailable -- re-enter the house and try again")
        return false, "floor count unavailable -- try re-entering the house"
    end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PROJECTS_CLEAR_HOUSE,
        payload = { houseID = houseID, clearedAt = (time and time() or 0), maxFloor = maxFloor },  -- exception(boundary): GetTime/time absent in headless harness
    })

    if C_HouseEditor.EnterHouseEditor then C_HouseEditor.EnterHouseEditor() end  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
    if C_HouseEditor.ActivateHouseEditorMode then C_HouseEditor.ActivateHouseEditorMode(_decorateMode()) end  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
    local lowest = _floorRange() or 0   -- exception(boundary): no range off-house-context
    _activeSweep = {
        houseID = houseID, floor = 1, lowest = lowest,
        maxFloor = maxFloor,
        settleSeconds = 1.5, cancelled = false,
    }
    C_Timer.After(0.1, function()
        if not _activeSweep or _activeSweep.cancelled then return end
        if C_HouseEditor.ActivateHouseEditorMode then C_HouseEditor.ActivateHouseEditorMode(_layoutMode()) end  -- exception(boundary): C_HouseEditor is a Blizzard API namespace; nil in headless tests
        if C_HousingLayout and C_HousingLayout.SetViewedFloor then C_HousingLayout.SetViewedFloor(_activeSweep.lowest) end
        -- Floor 1 travels furthest (from wherever the player was standing), so it
        -- is the floor that most needs the arrival wait, not least.
        _awaitViewedFloor(_activeSweep.lowest, function()
            if not self:IsCapturing() then self:_BeginCapture(1) end
            C_Timer.After(_activeSweep.settleSeconds, _stepSweep)
        end)
    end)
    return true
end

-- Budget/floor/editor live reads -> PROJECTS_HOUSE_TICK.
function HO:_PushHouseTick()
    local CD, CE = C_HousingDecor, C_HouseEditor
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PROJECTS_HOUSE_TICK,
        payload = {
            -- live decor spend; placement CAPS come from projects.placementCaps (reward-derived).
            -- exception(boundary): live cap API is layout-editor-state-dependent (returns 9/300 until Edit Layout opens).
            budget = {  -- exception(boundary): live C_HousingDecor reads
                decorSpent = (CD and CD.GetSpentPlacementBudget and CD.GetSpentPlacementBudget()) or 0,  -- exception(boundary): CD = C_HousingDecor, Blizzard API namespace
                decorCount = (CD and CD.GetNumDecorPlaced       and CD.GetNumDecorPlaced())       or 0,  -- exception(boundary): CD = C_HousingDecor, Blizzard API namespace
            },
            numFloors    = _numFloors() or 0,  -- exception(boundary): _numFloors nil in headless tests (no C_HousingLayout); 12.1-safe (GetNumFloors undocumented but shimmed; range path covers CVar-off)
            editorActive = (CE and CE.IsHouseEditorActive and CE.IsHouseEditorActive()) or false,  -- exception(boundary): CE = C_HouseEditor, Blizzard API namespace
        },
    })
end

-- =============================================================================
-- Module registration
-- =============================================================================

-- ===== Blizzard Housing Dashboard: DO NOT TOUCH ITS TABLES ==================
-- A repair hook used to live here that wrote HouseDropdown.playerHouseList = {}
-- on dashboard OnShow, to un-strand the House Info pane (Blizzard's forwarder
-- calls InitiativesFrame:OnHouseListUpdated before HouseUpgradeFrame's; the
-- 12.1 InitiativesFrame nil-throw kills the second call, then the dropdown's
-- tCompare guard swallows every identical reply and the pane stays blank).
--
-- REMOVED 2026-08-25: the write is a TAINT BOMB. Blizzard's handler reads the
-- tainted table in tCompare, its execution goes tainted, the reassigned list
-- and every houseInfo derived from it carry the taint, and the dashboard's
-- Teleport Home / Return buttons die in ADDON_ACTION_FORBIDDEN blamed on HDG
-- (replicated on both OnClick branches, owner, 2026-08-25 -- with the "disable
-- this addon" dialog). A sometimes-blank pane is Blizzard's bug and recoverable;
-- a dead protected teleport is not. There is NO taint-free write into Blizzard
-- UI state -- do not reintroduce this in any form.

HDG.Modules:Declare({
    name = "HousingObserver",
    dependencies = {},
    -- ADR-011: this module is the sole owner of the housing C_* namespaces.
    ownsBlizzardNamespaces = {
        "C_Housing", "C_HousingDecor", "C_HouseEditor", "C_NeighborhoodInitiative",
        "C_HousingLayout",   -- Projects topology capture + budget reads
    },
    blizzardEvents = {
        -- Placed-decor channel. CUSTOMIZATION_CHANGED is the enumeration burst,
        -- gated on OWN house or plot only (see OnDecorCustomization): it also
        -- fires for every neighbour's plot streaming into view, which fed nothing.
        -- On your own plot it can still carry neighbouring area IDs, so consumers
        -- scope by the GUID's area segment.
        HOUSE_EDITOR_MODE_CHANGED            = { handler = "OnEditorModeChanged" },
        HOUSING_DECOR_CUSTOMIZATION_CHANGED  = { handler = "OnDecorCustomization" },
        HOUSING_DECOR_REMOVED                = { handler = "OnDecorRemoved" },
        HOUSING_DECOR_PLACE_SUCCESS          = { handler = "OnDecorPlaceSuccess" },
        HOUSING_DECOR_PLACE_FAILURE          = { handler = "OnDecorPlaceFailure" },
        PLAYER_ENTERING_WORLD                = { handler = "OnEnteringWorld" },

        -- House meta channel. Both events spam on login (3-5 fires);
        -- debounce per wow-api MCP gotcha.
        PLAYER_HOUSE_LIST_UPDATED            = { handler = "OnPlayerHouseList",          debounce = 0.3 },
        HOUSE_LEVEL_FAVOR_UPDATED            = { handler = "OnHouseLevelFavor",          debounce = 0.3 },

        -- Active-neighborhood channel. Event fires whenever the
        -- neighborhood initiative cache settles. Handler reads
        -- C_NeighborhoodInitiative.GetActiveNeighborhood (sync) and
        -- dispatches whatever it returns (or nil).
        NEIGHBORHOOD_INITIATIVE_UPDATED      = { handler = "OnActiveNeighborhoodUpdated", debounce = 0.3 },

        -- Async rewards channel. Triggered by GetHouseLevelRewardsForLevel
        -- (called from OnHouseLevelFavor). Fires per-level with rewards.
        RECEIVED_HOUSE_LEVEL_REWARDS         = { handler = "OnHouseLevelRewardsEvent" },

        -- Projects topology capture: pin frames in Layout mode (passive); floor-change finalizes.
        -- Budget events refresh PROJECTS_HOUSE_TICK (debounced: fire per-decor during bulk placement).
        HOUSING_LAYOUT_PIN_FRAME_ADDED       = { handler = "OnPinFrameAddedEvent" },
        HOUSING_LAYOUT_VIEWED_FLOOR_CHANGED  = { handler = "OnLayoutFloorChangedEvent" },
        HOUSING_NUM_DECOR_PLACED_CHANGED     = { handler = "OnHousingBudgetEvent",      debounce = 0.3 },
        HOUSING_LAYOUT_ROOM_RECEIVED         = { handler = "OnHousingBudgetEvent",      debounce = 0.3 },
        HOUSING_LAYOUT_ROOM_REMOVED          = { handler = "OnHousingBudgetEvent",      debounce = 0.3 },
        HOUSING_LAYOUT_OCCUPIED_FLOOR_RANGE_CHANGED = { handler = "OnHousingBudgetEvent", debounce = 0.3 }, -- 12.1 rename of HOUSING_LAYOUT_NUM_FLOORS_CHANGED
    },

    OnEditorModeChanged = function(self)
        -- Deliberately NO ClearPlaced here. This fires on EVERY mode change, not just
        -- editor entry -- switching to Advanced mode to open Blizzard's Placed Decor
        -- list is a mode change -- and the CUSTOMIZATION_CHANGED burst does NOT re-fire
        -- afterwards. Clearing therefore destroyed the enumeration with no way to
        -- rebuild it: the Placed list read 0 the moment the player touched any mode.
        -- The clear was correct under the old semantics (placedDecor = "things I placed
        -- this editor session"); as an enumeration cache it is data loss.
        -- House-context changes still clear it via PLAYER_ENTERING_WORLD, and
        -- HOUSING_DECOR_REMOVED prunes individual entries.
        HO:_OnCaptureModeChanged()   -- begin/finalize passive topology capture
        HO:_PushHouseTick()          -- editorActive + budgets may have changed
    end,

    OnDecorCustomization = function(self, decorGUID)
        -- Gated on OWN HOUSE CONTEXT (your house or your plot), never on the editor. The
        -- editor-active gate dropped the ENTIRE burst because it lands before that
        -- flag flips -- HDG never saw its own enumeration channel until the gate
        -- went (verified 2026-07-26: ungated capture matched Blizzard's Placed
        -- Decor panel 21/21). But the event is not only the editor-entry burst: it
        -- fires for every neighbour's plot that streams into view, so ungated it
        -- collected a whole neighbourhood's decor -- two housing API calls and a
        -- catalog lookup per piece, a dispatch per frame -- into a session map
        -- whose only reader (the companion's Placed list) is scoped to the house
        -- or plot you stand in. Context is a property of where you are, not of
        -- when the burst fires, so this gate cannot repeat the timing miss.
        --
        -- On your own plot the burst can still span neighbouring plots; consumers
        -- scope by the GUID's area segment (session.styles.currentArea). A visited
        -- house is not captured at all.
        --
        -- Safe because this path writes only session.styles.placedDecor (session-only,
        -- never persisted). account.recentActivity is written by the REMOVED handler,
        -- which fires only for the player's own removals.
        if not HO:InOwnHouseContext() then return end
        HO:Observe(decorGUID)
    end,

    OnDecorRemoved = function(self, decorGUID)
        HO:RemovePlaced(decorGUID)
    end,

    -- The placement did not happen: drop the pick so it cannot be consumed later.
    OnDecorPlaceFailure = function(self)
        HO:ClearPendingPlacement()
    end,

    -- Decor committed. Payload is (decorGUID, size, isNew, isPreview); isNew is
    -- Nilable=false and is FALSE when an already-placed piece was merely MOVED, and
    -- isPreview marks a preview placement. Taking no args at all meant a drag of an
    -- existing piece consumed a stale pending itemID and recorded a placement that
    -- never happened (review 2026-08-23). Record from the pending itemID, not the
    -- payload -- PLACE_SUCCESS's decorGUID is not the catalog identity we need.
    OnDecorPlaceSuccess = function(self, decorGUID, size, isNew, isPreview)
        if isPreview then return end
        if isNew == false then return end   -- a move, not a new placement
        local itemID = HO:TakePendingPlacement()
        if not itemID then return end
        local houseID = _currentHouseID()
        if not houseID then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.RECENT_DECOR_PLACED,
            payload = { houseKey = houseID, itemID = itemID },
        })
    end,

    OnEnteringWorld = function(self)
        -- Clear the placed-decor map only when leaving your own house or plot --
        -- the same predicate that gates capture, so the map and the gate agree.
        if not HO:InOwnHouseContext() then
            HO:CancelSweep()   -- hearth//reload mid-sweep must not wedge the next capture
            HO:ClearPlaced()
        end
    end,

    OnPlayerHouseList = function(self, houseInfoList)
        HO:OnHouseList(houseInfoList)
    end,

    OnHouseLevelFavor = function(self, houseLevelFavor)
        HO:OnHouseLevelFavor(houseLevelFavor)
    end,

    OnActiveNeighborhoodUpdated = function(self)
        HO:OnActiveNeighborhood()
    end,

    OnHouseLevelRewardsEvent = function(self, level, rewards)
        HO:OnHouseLevelRewards(level, rewards)
    end,

    OnPinFrameAddedEvent = function(self, pinFrame)
        HO:OnPinFrameAdded(pinFrame)
    end,
    OnLayoutFloorChangedEvent = function(self)
        HO:OnLayoutFloorChanged()
    end,
    OnHousingBudgetEvent = function(self)
        HO:_PushHouseTick()
    end,

    onEnable = function(self)
        -- Defer to MAIN_WINDOW_OPENING: housing C_* null-derefs -> CTD on cold client
        -- at PLAYER_LOGIN. Steady-state events still arrive via blizzardEvents.
        -- See docs/COLD_CLIENT_CTD_INVESTIGATION.md.
        local A = HDG.Constants.ACTIONS
        self._kickToken = HDG.Store:Subscribe(function(actionType, invalidation)
            if actionType == A.MAIN_WINDOW_OPENING then
                if not self._kicked then
                    self._kicked = true
                    -- Kick: GetPlayerOwnedHouses -> PLAYER_HOUSE_LIST_UPDATED. Favor fetch
                    -- downstream is view-gated (OnHouseList loop) so it only fires when a
                    -- house-level view is the one being opened onto.
                    --
                    -- LOAD THE DASHBOARD FIRST: any housing request made while
                    -- Blizzard_HousingDashboard is unloaded warms the client house
                    -- cache, and the dashboard's own eventual first load then gets
                    -- a SYNCHRONOUS reply mid-OnLoad -- its broadcast fires before
                    -- the House Info pane registers and the dashboard strands
                    -- blank for the session (proven via registry dump 2026-08-25).
                    -- Loading it here (first housing touch, post-login, warm
                    -- client) makes its own request run on a cold cache instead.
                    -- Blizzard-signed code runs secure regardless of load caller.
                    if not C_AddOns.IsAddOnLoaded("Blizzard_HousingDashboard") then
                        C_AddOns.LoadAddOn("Blizzard_HousingDashboard")
                    end
                    if C_Housing and C_Housing.GetPlayerOwnedHouses then
                        C_Housing.GetPlayerOwnedHouses()
                    end
                    -- Seed active-neighborhood (sync; may be nil before initiative settles -> next event updates).
                    HO:OnActiveNeighborhood()
                    -- Seed Projects budget/floor slot (same cold-client gate; C_HousingLayout touches housing C_*).
                    HO:_PushHouseTick()
                else
                    -- Reopen: UI_SET_PERSISTENT won't fire (view unchanged), so pull here. Self-gates.
                    HO:RequestRewardsForOwnedHouses()
                end
            elseif actionType == A.UI_SET_PERSISTENT then
                -- Tab switch -> pull rewards (self-gates to house-level views). Filter on the view write.
                if type(invalidation) == "table" and invalidation[1] ~= "account.ui.view" then return end
                HO:RequestRewardsForOwnedHouses()
            elseif actionType == A.HOUSE_LEVEL_UPDATED then
                -- A house's level just became known (favor captured) -> pull its rewards. Covers
                -- first-open, where favor lands after the House tab is already on screen. Self-gates.
                HO:RequestRewardsForOwnedHouses()
            end
        end)
    end,
    onShutdown = function(self)
        if self._kickToken then
            HDG.Store:Unsubscribe(self._kickToken)
            self._kickToken = nil
        end
    end,
})
