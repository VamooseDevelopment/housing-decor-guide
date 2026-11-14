-- HDGR_BlueprintObserver.lua
-- ============================================================================
-- Sole owner of C_HousingBlueprint (one-namespace-per-module). Requests + sync
-- wrappers out, events in as plain-data dispatches, plus the pending-elapsed
-- ticker (timers live at the module layer, never in UI).

HDG = HDG or {}
HDG.BlueprintObserver = HDG.BlueprintObserver or {}
local BP = HDG.BlueprintObserver
local A  = HDG.Constants.ACTIONS

-- ===== Sync wrappers (controllers must not touch the namespace) ==============

function BP:IsShareCodeValid(code)
    return _G.C_HousingBlueprint.IsShareCodeValid(code)
end

function BP:GetBlueprintTypeForCode(code)
    return _G.C_HousingBlueprint.GetBlueprintTypeForCode(code)
end

-- Renamed on 68629: Is{Export,Import}Available -> Get{Export,Import}Availability,
-- returning a HousingResult (0 = Success = available; else the reason).
function BP:GetExportAvailability()
    return _G.C_HousingBlueprint.GetExportAvailability()
end

-- Rename an OWNED saved blueprint in Blizzard's catalog (blueprintID, not code).
function BP:Rename(blueprintID, newName)
    _G.C_HousingBlueprint.RenameBlueprint(blueprintID, newName)
end

-- Chat-linkable hyperlink for a share code (players link builds in chat).
function BP:GetHyperlink(shareCode)
    return _G.C_HousingBlueprint.GetBlueprintHyperlink(shareCode)
end

-- Open Blizzard's Import dialog prefilled with a code (its preview + confirm
-- own the destructive apply). Global util; self-loads Blizzard_HousingBlueprint.
function BP:OpenImport(shareCode)
    if _G.HousingFramesUtil and _G.HousingFramesUtil.ShowBlueprintImport then  -- exception(boundary): Blizzard UI util
        _G.HousingFramesUtil.ShowBlueprintImport(shareCode)
    end
end

-- Delete an OWNED saved blueprint from the catalog (blueprintID, not code).
function BP:Delete(blueprintID)
    _G.C_HousingBlueprint.DeleteBlueprint(blueprintID)
end

-- ===== Requests ==============================================================

function BP:RequestCollection()
    _G.C_HousingBlueprint.RequestBlueprintCollection()
end

-- houseGUID nil = bare request; the server then defaults the target to the
-- player's current house (verified 12.1.0.68629 -- no count-only path for
-- house owners). Responses arrive on the CONTENTS events below; big manifests
-- take 5-10s, hence the pending ticker.
function BP:RequestContents(shareCode, houseGUID)
    HDG.Store:Dispatch({ type = A.BLUEPRINT_CONTENTS_REQUESTED,
        payload = { shareCode = shareCode, requestedAt = GetTime() } })
    self:_EnsureTicker()
    if houseGUID then
        _G.C_HousingBlueprint.RequestBlueprintContentsForContext(shareCode, houseGUID)
    else
        _G.C_HousingBlueprint.RequestBlueprintContents(shareCode)
    end
end

-- Room blueprints save via a DIFFERENT call that needs the specific room GUID
-- (ExportBlueprint(Room, ...) reports RoomNotFound). The room the player stands
-- in comes from HousingObserver, which owns C_HousingLayout.
function BP:Export(typeEnum, name)
    -- Stash the requested name: EXPORT_SUCCESS only carries the shareCode, and
    -- the collection round-trip takes seconds -- the optimistic label keeps the
    -- header showing the typed name instead of a code flash (UX review #8).
    self._pendingExportName = name
    if typeEnum == Enum.HousingBlueprintType.Room then  -- exception(boundary): Blizzard enum
        local roomGUID = HDG.HousingObserver:GetCurrentRoomGUID()
        if not roomGUID then  -- exception(nullable): player not standing in a room
            HDG.Log:Warn("blueprints", "Go inside the room you want to save, then try again")
            return
        end
        _G.C_HousingBlueprint.ExportRoomBlueprint(name, roomGUID)
    else
        _G.C_HousingBlueprint.ExportBlueprint(typeEnum, name)
    end
end

-- ===== Pending ticker =========================================================
-- Dispatches BLUEPRINT_PENDING_TICK once a second while any request is
-- pending; the pendingText selector composes "Waiting... (Ns)" from state.
-- Each tick first sweeps timeouts: some requests are silently dropped
-- server-side (no RECEIVED or FAILURE ever fires -- verified 2026-07-12 for
-- certain foreign codes), and without the sweep those manifests stay pending
-- forever and the ticker never cancels (review finding).

function BP:_AnyPending()
    for _, m in pairs(HDG.Store:GetState().session.blueprints.manifests) do
        if m.status == "pending" then return true end
    end
    return false
end

function BP:_SweepTimeouts(now)
    for code, m in pairs(HDG.Store:GetState().session.blueprints.manifests) do
        if m.status == "pending" and (now - m.requestedAt) > HDG.Constants.BLUEPRINT_REQUEST_TIMEOUT then
            HDG.Store:Dispatch({ type = A.BLUEPRINT_CONTENTS_FAILED,
                payload = { shareCode = code, timedOut = true } })
        end
    end
end

function BP:_EnsureTicker()
    if self._ticker then return end
    self._ticker = C_Timer.NewTicker(1, function()
        local now = GetTime()
        BP:_SweepTimeouts(now)
        if BP:_AnyPending() then
            HDG.Store:Dispatch({ type = A.BLUEPRINT_PENDING_TICK, payload = { now = now } })
        else
            BP._ticker:Cancel()
            BP._ticker = nil
        end
    end)
end

-- ===== Event handlers (wired declaratively in the Declare below) =============

function BP:OnCollectionReceived(coll)
    local groups, used = coll.groups or {}, 0  -- exception(boundary): server payload
    -- Auto-saves (the "Backups" group) do NOT count against the manual cap --
    -- Blizzard's dashboard excludes them (11/50 vs our old 20/50). They have a
    -- cap of their own, which Blizzard's UI surfaces nowhere.
    for _, g in ipairs(groups) do
        for _, e in ipairs(g.entries or {}) do  -- exception(boundary): server payload
            if not e.isAutoSave then used = used + 1 end
        end
    end
    -- The cap comes from the game, not a literal: Blizzard's collection panel
    -- reads HOUSING_BLUEPRINTS_MAX_PER_BNET_ACCOUNT at render time. The field is
    -- live on 12.1 but absent from the LS stubs (pinned at 12.0.7), hence the
    -- suppression -- delete it when the stub set regenerates.
    ---@diagnostic disable-next-line: undefined-field
    local consts = _G.Constants.HousingConsts  -- exception(boundary): Blizzard constants table
    HDG.Store:Dispatch({ type = A.BLUEPRINT_COLLECTION_RECEIVED,
        payload = { groups = groups, slots = {
            used = used, max = consts.HOUSING_BLUEPRINTS_MAX_PER_BNET_ACCOUNT } } })
end

function BP:OnCollectionFailure(reasonCode)
    -- The blueprint LIST failed to load (server error / feature toggling). Surface
    -- Blizzard's reason as a status toast instead of leaving the browser silently
    -- empty -- same shape as the export/rename/delete failure handlers.
    local map = _G.HousingResultToErrorText  -- exception(boundary): Blizzard global map
    HDG.Log:Warn("blueprints", (map and map[reasonCode]) or "Couldn't load your blueprints")  -- exception(boundary): not every value mapped
end

-- Derive a blueprint's ABSOLUTE faction from the inspected manifest. Only
-- House/Exterior blueprints carry an exterior faction; the server sets the
-- MismatchedExteriorFaction bit (32) when the blueprint differs from the
-- TARGET HOUSE's neighborhood -- so the reference is the target house's
-- faction (session.house.ownedHouses), NOT the player character's (an
-- Alliance char inspecting against a Horde house gets the flag on ALLIANCE
-- blueprints; a player-faction reference inverts every result -- PTR-caught).
-- Faction is NOT in the share code (proven), so inspection is the only source.
local FACTION_MISMATCH_BIT = 32
function BP:_DeriveFaction(info)
    local t = self:GetBlueprintTypeForCode(info.shareCode)
    if t ~= Enum.HousingBlueprintType.House and t ~= Enum.HousingBlueprintType.Exterior then
        return nil  -- exception(nullable): interiors/rooms are faction-neutral
    end
    local house = HDG.Store:GetState().session.house.ownedHouses[info.targetHouseGUID]  -- exception(nullable): unknown/foreign target
    local ref = house and house.faction
    if ref ~= "Alliance" and ref ~= "Horde" then return nil end  -- exception(nullable): faction unresolved for that house
    local blocking = info.blockingRequirementFlags or 0  -- exception(boundary): server payload, nil pre-target
    local mismatch = blocking % (FACTION_MISMATCH_BIT * 2) >= FACTION_MISMATCH_BIT
    if mismatch then return (ref == "Alliance") and "Horde" or "Alliance" end
    return ref
end

function BP:OnContentsReceived(info)
    HDG.Store:Dispatch({ type = A.BLUEPRINT_CONTENTS_RECEIVED,
        payload = { shareCode = info.shareCode, raw = info, faction = self:_DeriveFaction(info) } })
end

-- `gone` = BlueprintNotFound, the answer for a code its owner deleted (live,
-- 2026-11-15). DbError is NOT counted: the one sample was a PTR database wipe,
-- and a passing server fault must not write "deleted" into a player's note.
function BP:OnContentsFailure(shareCode, reasonCode)
    local R = Enum.HousingResult  -- exception(boundary): Blizzard enum (never hardcode values)
    HDG.Store:Dispatch({ type = A.BLUEPRINT_CONTENTS_FAILED,
        payload = { shareCode = shareCode, reasonCode = reasonCode,
                    gone = reasonCode == R.BlueprintNotFound,
                    goneNote = HDG.Locale:Get("BP_LIBRARY_GONE") } })
end

-- Storage changed under the cached manifests. The counts in a manifest are
-- the server's answer at fetch time, so a purchase since then makes them
-- lie -- Soul bought duplicates off a manifest fetched before the shopping
-- trip (2026-09-15). Mark only; the re-fetch waits for a row select.
function BP:OnStorageUpdated()
    HDG.Store:Dispatch({ type = A.BLUEPRINT_MANIFESTS_STALE })
end

function BP:OnExportSuccess(shareCode)
    HDG.Store:Dispatch({ type = A.BLUEPRINT_EXPORT_SUCCESS,
        payload = { shareCode = shareCode, label = self._pendingExportName } })
    self._pendingExportName = nil
    HDG.Log:Info("blueprints", "Blueprint saved -- code ready to share")
    -- The new blueprint now exists server-side; re-pull the collection so it
    -- appears in the list, and fetch its contents so the auto-selected code
    -- shows a populated inspector instead of an empty one.
    self:RequestCollection()
    self:RequestContents(shareCode, HDG.Store:GetState().session.blueprints.targetHouseGUID)
end

function BP:OnExportFailure(reasonCode)
    -- Save failed (e.g. wrong location for the chosen type). Surface Blizzard's
    -- own reason rather than failing silently.
    local map = _G.HousingResultToErrorText  -- exception(boundary): Blizzard global map
    HDG.Log:Warn("blueprints", (map and map[reasonCode]) or "Couldn't save this blueprint here")  -- exception(boundary): not every value mapped
end

function BP:OnRenameSuccess()
    self:RequestCollection()  -- re-pull so the new name shows in the list
    HDG.Log:Info("blueprints", "Blueprint renamed")
end

function BP:OnRenameFailure(reasonCode)
    local map = _G.HousingResultToErrorText  -- exception(boundary): Blizzard global map
    HDG.Log:Warn("blueprints", (map and map[reasonCode]) or "Couldn't rename this blueprint")  -- exception(boundary): not every value mapped
end

function BP:OnDeleteSuccess()
    self:RequestCollection()  -- re-pull so the deleted one drops from the list
    HDG.Log:Info("blueprints", "Blueprint deleted")
end

function BP:OnDeleteFailure(reasonCode)
    local map = _G.HousingResultToErrorText  -- exception(boundary): Blizzard global map
    HDG.Log:Warn("blueprints", (map and map[reasonCode]) or "Couldn't delete this blueprint")  -- exception(boundary): not every value mapped
end

HDG.Modules:Declare({
    name         = "BlueprintObserver",
    dependencies = {},
    ownsBlizzardNamespaces = { "C_HousingBlueprint" },
    logTags = {
        -- user-visible: seam confirmations (route/set/export) toast on the status rail.
        blueprints = { user = true, level = "info", duration = 4 },
    },
    blizzardEvents = {
        HOUSING_BLUEPRINT_COLLECTION_RECEIVED = { handler = "OnCollectionReceived" },
        HOUSING_BLUEPRINT_COLLECTION_FAILURE  = { handler = "OnCollectionFailure" },
        HOUSING_BLUEPRINT_CONTENTS_RECEIVED   = { handler = "OnContentsReceived" },
        HOUSING_BLUEPRINT_CONTENTS_FAILURE    = { handler = "OnContentsFailure" },
        HOUSING_BLUEPRINT_EXPORT_SUCCESS      = { handler = "OnExportSuccess" },
        HOUSING_BLUEPRINT_EXPORT_FAILURE      = { handler = "OnExportFailure" },
        HOUSING_BLUEPRINT_RENAME_SUCCESS      = { handler = "OnRenameSuccess" },
        HOUSING_BLUEPRINT_RENAME_FAILURE      = { handler = "OnRenameFailure" },
        HOUSING_BLUEPRINT_DELETE_SUCCESS      = { handler = "OnDeleteSuccess" },
        HOUSING_BLUEPRINT_DELETE_FAILURE      = { handler = "OnDeleteFailure" },
        -- Not C_HousingBlueprint events; the catalog observer owns the sweeps
        -- they trigger, these subscriptions only flag cached manifests stale.
        -- BOTH are needed: a single purchase or learn-from-bag arrives ONLY as
        -- the per-entry event (live 2026-09-15 -- the bulk event stayed silent
        -- and the button never lit). Debounced because the handler ignores
        -- its args, so a burst of a hundred entries is one mark.
        HOUSING_STORAGE_UPDATED               = { handler = "OnStorageUpdated", debounce = 0.5 },
        HOUSING_STORAGE_ENTRY_UPDATED         = { handler = "OnStorageUpdated", debounce = 0.5 },
    },
    -- BlizzardEvents resolves handlers ON THIS DEF TABLE (module = the def);
    -- delegate to the BP singleton, forwarding the event args (MerchantObserver idiom).
    OnCollectionReceived = function(_, ...) BP:OnCollectionReceived(...) end,
    OnCollectionFailure  = function(_, ...) BP:OnCollectionFailure(...) end,
    OnContentsReceived   = function(_, ...) BP:OnContentsReceived(...) end,
    OnContentsFailure    = function(_, ...) BP:OnContentsFailure(...) end,
    OnExportSuccess      = function(_, ...) BP:OnExportSuccess(...) end,
    OnExportFailure      = function(_, ...) BP:OnExportFailure(...) end,
    OnRenameSuccess      = function(_, ...) BP:OnRenameSuccess(...) end,
    OnRenameFailure      = function(_, ...) BP:OnRenameFailure(...) end,
    OnDeleteSuccess      = function(_, ...) BP:OnDeleteSuccess(...) end,
    OnDeleteFailure      = function(_, ...) BP:OnDeleteFailure(...) end,
    OnStorageUpdated     = function() BP:OnStorageUpdated() end,
    onEnable = function()
        -- available=false at state mint on all builds (golden-state stays
        -- build-independent); flip it here, where only a 12.1 client runs.
        HDG.Store:Dispatch({ type = A.BLUEPRINT_AVAILABLE_SET, payload = { available = true } })
    end,
})
