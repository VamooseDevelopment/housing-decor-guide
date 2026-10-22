-- HDG.StoreFurnishings -- the Furnishings domain of the Store (v7 model:
-- docs/crate-redesign/10-FINAL-MODEL.md).
-- ============================================================================
-- Domain-store file: owns the v6->7 migration, the furnishings shape ensures,
-- the session reverse indexes, the FURN_*/LAYOUT_* reducer cases (delegated
-- via HDG.Actions:Register blocks -- still the single dispatch
-- path; this is the same reducer, in its own file), and the v7 halves of the
-- capture/clear cases. Loaded BEFORE HDGR_Store.lua in the TOC; the Store
-- calls in strictly (load-order-guaranteed singleton).
--
-- Why a separate file: the Store was already the largest file in the addon
-- (~4k lines) before the Furnishings build; cohesive domains get their own
-- store file from now on rather than growing the monolith.

HDG = HDG or {}
HDG.StoreFurnishings = {}
local SF = HDG.StoreFurnishings

-- The reducer warns on refused placements (LAYOUT_PLACE of a shapeless
-- design). Projects tab tags normally register at first Wire -- guarantee
-- them here so a pre-UI dispatch can't hit Log:Push's unknown-tag error.
if HDG.Log and not HDG.Log:HasTag("projects_save") then HDG.Log:RegisterTabTags("projects") end  -- exception(boundary): Log absent in partial test harnesses

-- ===== Layout mint ==========================================================
-- Layouts share the legacy versionSeq counter + "version:N" format so IDs stay
-- collision-free with pre-v7 records (Store._nextVersionID is the twin).
local function _ensureHouseLayout(p, houseID, createdAt)
    local house = p.houses[houseID]
    if not house then house = {}; p.houses[houseID] = house end
    local lid = house.currentVersionID
    if not lid or not p.layouts[lid] then
        if not lid then
            p.versionSeq = (p.versionSeq or 0) + 1   -- exception(boundary): pre-counter saved accounts have no versionSeq
            lid = "version:" .. p.versionSeq
            house.currentVersionID = lid
        end
        p.layouts[lid] = { houseID = houseID, name = "Live",
                           createdAt = createdAt or 0, placements = {} }
    end
    -- Backfill outside the mint: migrated v6 houses carry currentVersionID only.
    house.activeVersionID = house.activeVersionID or lid
    return lid
end

-- ===== Migration: account schemaVersion 6 -> 7 ==============================
-- Crates become furnishing sets (counts verbatim, 1:1); version rooms become
-- PERSISTENT account.rooms with clean room:N IDs (legacy floor-encoded IDs
-- kept only as .legacyID lineage for this transform + the what-if dedup rule
-- + capture re-matching); versions become layouts holding placements. Gen-1
-- fossil collections at the SV ROOT (HDG_DB.collections) are never read here;
-- Store clears them at load with the rest of 2.x's top-level keys
-- (RETIRED_ROOT_KEYS). boundary: legitimate SV migration -- runs once per DB at
-- LoadFromSavedVariables (EnsureStateShape re-runs are version-gated no-ops).
-- v7 -> v8 fossil scrub (pre-release test DBs only -- v7 never shipped).
-- A v7 DB carries ROOM-KEYED placements with no shape/capturedID; under v8
-- LayoutView they render as shapeless unassigned records and crash shape-
-- indexed selectors (planDiff). Drop them (a recapture re-mints v8 slots for
-- every physical room) and strip the retired room.legacyID field. Rooms,
-- sets, equips, and any already-minted v8 slot placements all survive.
-- Gate on the DATA SHAPE, not schemaVersion: a live DB was found stamped 8
-- with fossils intact (2026-06-11 -- fresh-DB version stamp + carried-along
-- fossil layouts), so version gating is unreliable. Runs once per hydrate
-- from LoadFromSavedVariables; v8 reducers only ever mint slot:N keys, so a
-- clean DB pays one O(placements) key scan per login.
function SF.ScrubFossilPlacements(state)
    local acct = state.account
    for _, layout in pairs(acct.projects.layouts) do
        for key in pairs(layout.placements) do
            if not key:match("^slot:%d+$") then layout.placements[key] = nil end
        end
    end
    for _, room in pairs(acct.rooms) do room.legacyID = nil end
    if (acct.schemaVersion or 1) == 7 then acct.schemaVersion = 8 end
end

local function _sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

local function _mintRoom(acct, rec)
    acct.roomSeq = acct.roomSeq + 1
    local id = "room:" .. acct.roomSeq
    acct.rooms[id] = {
        id = id, name = rec.name, shape = rec.shape,
        furnishingSetIDs = {},   -- v8: lineage lives on placements, not rooms
        createdAt = rec.createdAt or 0,
    }
    return id
end

local function _mintSet(acct, name, decor, isLocal, ownerRoom, createdAt)
    acct.furnishingSetSeq = acct.furnishingSetSeq + 1
    local id = "set:" .. acct.furnishingSetSeq
    local items = {}
    for i, d in ipairs(decor or {}) do items[i] = { id = d.id, count = d.count or 1 } end
    acct.furnishingSets[id] = {
        id = id, name = name, items = items,
        isLocal = isLocal or nil, ownerRoom = ownerRoom,
        createdAt = createdAt or 0,
    }
    return id
end

-- Order-insensitive decor equality (crates dedupe by itemID by construction).
local function _decorEqual(a, b)
    local m = {}
    for _, d in ipairs(a or {}) do m[d.id] = d.count or 1 end
    for _, d in ipairs(b or {}) do
        if m[d.id] ~= (d.count or 1) then return false end
        m[d.id] = nil
    end
    return next(m) == nil
end

local function _placementFor(legacyID, rec, roomID)
    local parsed = HDG.Projects.IDs.parsePath(legacyID)
    local cell   = rec.cell or {}   -- exception(boundary): pre-cell SV rooms (v1-era)
    return {
        floor    = (parsed and parsed.floor) or 1,
        x        = cell.x or 0,
        y        = cell.y or 0,
        rotation = cell.rotation or 0,
        shape      = rec.shape,   -- v8: every placement is slot-keyed and self-describing
        capturedID = legacyID,
        roomID     = roomID,
    }
end

-- Phase: index crates (versionID -> legacy roomID -> crate) + orphans. A crate
-- whose version record is GONE (partial v1->v2 migration, hand-edited SV) would
-- fall through the version sweep and be purged silently -- route it to the
-- orphan path instead (release-18 audit #1). Duplicate parent keeps both (#10).
local function _indexCrates(acct, p)
    local cratesByVid, orphanCrates = {}, {}
    for _, cid in ipairs(_sortedKeys(acct.collections)) do
        local coll = acct.collections[cid]
        if coll.type == "crate" then
            if coll.parent and coll.versionID and (p.versions or {})[coll.versionID] then
                cratesByVid[coll.versionID] = cratesByVid[coll.versionID] or {}
                if cratesByVid[coll.versionID][coll.parent] then
                    orphanCrates[#orphanCrates + 1] = coll
                else
                    cratesByVid[coll.versionID][coll.parent] = coll
                end
            else
                orphanCrates[#orphanCrates + 1] = coll
            end
        end
    end
    return cratesByVid, orphanCrates
end

-- Phase: Live versions are canonical for room identity (10-FINAL-MODEL Migration).
local function _computeLiveVids(p)
    local liveVids = {}
    for _, houseID in ipairs(_sortedKeys(p.houses)) do
        local h = p.houses[houseID]
        if h.currentVersionID then liveVids[h.currentVersionID] = true end
    end
    return liveVids
end

-- Phase: orphan crates -> unequipped LIBRARY sets named from provenance.
local function _migrateOrphanCrates(acct, orphanCrates)
    for _, crate in ipairs(orphanCrates) do
        local name = crate.name
        if not name or name == "" or name == "Crate" or name == "New crate" then
            name = crate.lastKnownRoomName or "Saved Furnishings"
        end
        _mintSet(acct, name, crate.decor, false, nil, crate.createdAt)
    end
end

-- Phase: retire crate records (styles etc. untouched) + the version container.
local function _retireCrateRecords(acct, p)
    for cid, coll in pairs(acct.collections) do
        if coll.type == "crate" then acct.collections[cid] = nil end
    end
    p.versions = nil
end

local function MigrateToFurnishings(state)
    local acct = state.account
    if (acct.schemaVersion or 1) >= 7 then return end   -- v7 fossils handled shape-based by ScrubFossilPlacements at hydrate
    local p = acct.projects

    acct.rooms            = acct.rooms            or {}
    acct.roomSeq          = acct.roomSeq          or 0
    acct.furnishingSets   = acct.furnishingSets   or {}
    acct.furnishingSetSeq = acct.furnishingSetSeq or 0
    p.layouts             = p.layouts             or {}

    local cratesByVid, orphanCrates = _indexCrates(acct, p)
    local liveVids = _computeLiveVids(p)

    local roomByLegacy      = {}   -- legacyID -> canonical persistent roomID (legacy IDs embed houseID -> globally unique)
    local liveDecorByLegacy = {}   -- legacyID -> the Live crate's decor (what-if dedup evidence)

    local function attachLocalSet(roomID, crate)
        local sid = _mintSet(acct, crate.name or "Crate", crate.decor, true, roomID, crate.createdAt)
        table.insert(acct.rooms[roomID].furnishingSetIDs, sid)
    end

    local function migrateVersion(vid)
        local v      = p.versions[vid]
        local isLive = liveVids[vid] == true
        local layout = { houseID = v.houseID, name = v.name, createdAt = v.createdAt,
                         basedOn = v.basedOn, placements = {}, slotSeq = 0 }
        local crates = cratesByVid[vid] or {}
        for _, legacyID in ipairs(_sortedKeys(v.rooms)) do
            local rec, crate = v.rooms[legacyID], crates[legacyID]
            local roomID
            if isLive or not roomByLegacy[legacyID] then
                -- Canonical mint (Live first; what-if rooms with no Live
                -- counterpart -- e.g. what-if-only designs -- mint normally).
                roomID = _mintRoom(acct, rec)
                roomByLegacy[legacyID] = roomID
                if crate then
                    attachLocalSet(roomID, crate)
                    if isLive then liveDecorByLegacy[legacyID] = crate.decor end
                end
            else
                local canonical = roomByLegacy[legacyID]
                if crate and not _decorEqual(crate.decor, liveDecorByLegacy[legacyID]) then
                    -- Furnishings differ from Live -> room VARIANT carrying its own local set.
                    roomID = _mintRoom(acct, rec)
                    acct.rooms[roomID].name =
                        ((rec.name and rec.name ~= "" and rec.name) or "Design") .. " (What-if variant)"
                    attachLocalSet(roomID, crate)
                else
                    roomID = canonical   -- shared by reference (identical or no furnishings)
                end
            end
            -- v8: slot-keyed; the room rides as a TAG.
            layout.slotSeq = layout.slotSeq + 1
            layout.placements["slot:" .. layout.slotSeq] = _placementFor(legacyID, rec, roomID)
        end
        p.layouts[vid] = layout
    end

    -- Live versions first (canonical identity), then the rest.
    local allVids = _sortedKeys(p.versions)
    for _, vid in ipairs(allVids) do if liveVids[vid] then migrateVersion(vid) end end
    for _, vid in ipairs(allVids) do if not liveVids[vid] then migrateVersion(vid) end end

    _migrateOrphanCrates(acct, orphanCrates)
    _retireCrateRecords(acct, p)

    acct.schemaVersion = 8   -- v8: slot-keyed placements; assignment is a tag
end

-- ===== Shape ensures (called from Store's EnsureStateShape, per dispatch) ===

function SF.EnsureShape(state)
    state.account.rooms            = state.account.rooms            or {}   -- exception(boundary): SV migration
    state.account.roomSeq          = state.account.roomSeq          or 0    -- exception(boundary): SV migration
    state.account.furnishingSets   = state.account.furnishingSets   or {}   -- exception(boundary): SV migration
    state.account.furnishingSetSeq = state.account.furnishingSetSeq or 0    -- exception(boundary): SV migration
    state.account.projects.layouts = state.account.projects.layouts or {}   -- exception(boundary): SV migration
    -- exception(boundary): the ONE place data preservation trumps fail-loud.
    -- The v6->v8 migration is one-way over 1M users' crate data; a throw on
    -- a weird shape would persist partial state and RE-RUN on every later
    -- login, compounding it (release-18 audit #11). On failure: stamp v8 to
    -- halt re-runs -- the un-migrated crates stay untouched in
    -- account.collections for a fixed build to convert.
    local ok, err = pcall(MigrateToFurnishings, state)
    if not ok then
        state.account.schemaVersion = 8
        if HDG.Log then   -- exception(boundary): Log absent in partial test harnesses
            HDG.Log:Error("projects_error",
                "Furnishings migration failed -- your crate data is untouched; please report this: " .. tostring(err))
        end
    end
end

-- ===== Reverse indexes (session-derived; 10-FINAL-MODEL §Schema) ============
-- set -> rooms equipping it, room -> layouts placing it. Rebuilt on hydrate;
-- incrementally maintained by the reducer cases below.

function SF.RebuildIndexes(state)
    local idx = state.session.furnIndex
    idx.setRooms, idx.roomLayouts = {}, {}
    for roomID, room in pairs(state.account.rooms) do
        for _, sid in ipairs(room.furnishingSetIDs) do
            idx.setRooms[sid] = idx.setRooms[sid] or {}
            idx.setRooms[sid][roomID] = true
        end
    end
    -- v8: roomLayouts[roomID][layoutID] = SPOT COUNT (a room can tag many
    -- placements per layout; truthiness still works for layout membership).
    for lid, layout in pairs(state.account.projects.layouts) do
        for _, pl in pairs(layout.placements) do
            if pl.roomID and state.account.rooms[pl.roomID] then   -- exception(nullable): stale tag repaired by read-side fallbacks
                idx.roomLayouts[pl.roomID] = idx.roomLayouts[pl.roomID] or {}
                idx.roomLayouts[pl.roomID][lid] = (idx.roomLayouts[pl.roomID][lid] or 0) + 1
            end
        end
    end
    -- Dangling-ref repair (hydrate-only): live SVs carry activeVersionIDs the
    -- pre-v7 version-delete never cleared. Reset to the Live layout.
    local layouts = state.account.projects.layouts
    for _, house in pairs(state.account.projects.houses) do
        if house.activeVersionID and not layouts[house.activeVersionID] then
            house.activeVersionID = house.currentVersionID
        end
    end
end

-- ===== Capture (the reducer halves of CAPTURE_COMMIT / CLEAR_HOUSE) =========
-- INVARIANT (12-final-stress, data-critical): capture writes PLACEMENTS
-- ONLY. It can never touch account.rooms' furnishing fields -- rooms and
-- their sets are structurally out of capture's reach. v8 matching: captured
-- IDs are deterministic (floor + capture order) and live ON the placement
-- (pl.capturedID); a recapture re-finds the placement 1:1 and updates its
-- geometry in place, so the roomID tag survives. Never-seen IDs arrive as
-- unassigned slots, lazily curated (LAYOUT_ASSIGN / create-in-place tag the
-- slot; its capturedID keeps re-matching on every later recapture).

function SF.ApplyCapture(state, payload)
    local p      = state.account.projects
    local lid    = _ensureHouseLayout(p, payload.houseID, payload.lastCapturedAt or 0)
    local layout = p.layouts[lid]
    local acct   = state.account
    -- v8: lineage lives ON the placement. Index existing placements by
    -- capturedID; a re-found slot updates geometry IN PLACE so its roomID
    -- tag survives recapture. Direct 1:1 match -- no shape disambiguation.
    local byCaptured = {}
    for key, pl in pairs(layout.placements) do
        if pl.capturedID then byCaptured[pl.capturedID] = key end
    end
    local matched, slots = 0, 0
    for capturedID, record in pairs(payload.rooms or {}) do
        local cell   = record.cell or { x = 0, y = 0, rotation = 0 }   -- exception(boundary): capture payload from observer
        local parsed = HDG.Projects.IDs.parsePath(capturedID)
        local key    = byCaptured[capturedID]
        if not key then
            layout.slotSeq = (layout.slotSeq or 0) + 1
            key = "slot:" .. layout.slotSeq
            layout.placements[key] = {}
        end
        local pl = layout.placements[key]
        pl.floor, pl.x, pl.y = (parsed and parsed.floor) or 1, cell.x or 0, cell.y or 0
        pl.rotation = cell.rotation or 0
        -- floors PRESERVES an existing override -- the old unconditional copy
        -- silently wiped "Expand Stairwell up" plans on every recapture
        -- (2026-08-10 review critical #2).
        pl.floors = record.floors or pl.floors   -- exception(optional): capture records NEVER carry floors (stripped pre-dispatch); the `or` keeps the planner/expand override, it is not a nil-guard
        pl.shape, pl.capturedID, pl.capturedName = record.shape, capturedID, record.name
        -- Carried for the selector layer: roomDetail.isBase + the "Hallway 1-2"
        -- room-number labels (both were dead while these fields were dropped here).
        -- placementIndex = immutable per-house identity from the roomGUID counter;
        -- the vertical-pinning signal for stair sections (solver spec SS10).
        pl.isBase, pl.captureIndex, pl.placementIndex = record.isBase, record.captureIndex, record.placementIndex
        if pl.roomID then
            -- Tag survives; captured name fills a blank room name, never overwrites.
            local room = acct.rooms[pl.roomID]   -- exception(nullable): stale tag (room deleted) -> falls back to slot
            if room then
                if not room.name or room.name == "" then room.name = record.name end
                matched = matched + 1
            else
                pl.roomID = nil
                slots = slots + 1
            end
        else
            slots = slots + 1
        end
    end
    -- A freshly-captured stair section MATERIALIZES a pending "Expand up" plan on
    -- the section below it: once a real same-shape section sits directly above,
    -- the override's projection would double-claim that floor and pin-conflict
    -- the next capture -- clear it (2026-08-10 review #2, owner-approved heal).
    local SA = HDG.Projects.ShapeAtlas
    for _, below in pairs(layout.placements) do
        if below.floors and below.capturedID and SA.IsStairShape(below.shape) then
            for _, above in pairs(layout.placements) do
                if above.capturedID and above.shape == below.shape
                   and above.floor == below.floor + 1
                   and above.x == below.x and above.y == below.y then
                    below.floors = nil
                    break
                end
            end
        end
    end

    local removed = 0
    for _, capturedID in ipairs(payload.deleteRoomIDs or {}) do
        -- Partial-capture removal: drop the placement; tagged ROOMS (and
        -- their furnishings) persist in the library untouched.
        local key = byCaptured[capturedID]
        if key and layout.placements[key] then
            if layout.placements[key].roomID then removed = removed + 1 end
            layout.placements[key] = nil
        end
    end
    SF.RebuildIndexes(state)   -- spot counts shifted; cheap (placement scan)
    -- Capture summary echo (per-floor cumulative) -- drives the rail ack.
    local cap = state.session.furn.lastCapture or { matched = 0, slots = 0, removed = 0 }
    cap.matched, cap.slots = cap.matched + matched, cap.slots + slots
    cap.removed = (cap.removed or 0) + removed
    cap.houseID, cap.layoutID = payload.houseID, lid
    state.session.furn.lastCapture = cap
    state.session.furn.changeSeq = state.session.furn.changeSeq + 1
end

-- Prep the current LAYOUT for a recapture sweep. v8: placements PERSIST --
-- ApplyCapture matches them by capturedID and updates geometry in place, so
-- roomID tags survive the sweep. The only clearing left is pruning
-- capture-owned placements ABOVE the house's current floor count (a deleted
-- floor never gets swept, so its per-floor diff would never remove them).
-- User doodles (no capturedID) are never touched. Resets the capture echo.
function SF.ClearLayout(state, payload)
    local p      = state.account.projects
    local house  = p.houses[payload.houseID]
    local lid    = house and house.currentVersionID
    local layout = lid and p.layouts[lid]   -- exception(boundary): first capture fires CLEAR before the layout exists
    local removed = 0
    if layout and payload.maxFloor then   -- exception(optional): maxFloor rides only the sweep's dispatch
        local pruned = 0
        for key, pl in pairs(layout.placements) do
            if pl.capturedID and pl.floor > payload.maxFloor then
                if pl.roomID then removed = removed + 1 end
                layout.placements[key] = nil
                pruned = pruned + 1
            end
        end
        if pruned > 0 then SF.RebuildIndexes(state) end
    end
    state.session.furn.lastCapture = { matched = 0, slots = 0, removed = removed }
end

-- ===== Layout view (the spatial pipeline's read shape) ======================
-- Materializes a layout into the record map FloorMap / canvas / selectors
-- consume: [key] = { shape, name, floor, cell = {x,y,rotation}, roomID?,
-- slotKey?, unassigned?, isBase?, captureIndex? }. Keys are v7 placement keys
-- (room:N / slot:N); records CARRY floor (FloorMap reads record.floor -- v7
-- keys don't encode it).

function SF.LayoutView(state, layoutID)
    local layout = layoutID and state.account.projects.layouts[layoutID]   -- exception(nullable): stale UI layout id
    if not layout then return {} end
    local out = {}
    for key, pl in pairs(layout.placements) do
        -- v8: keys are ALWAYS slot keys; the room rides as a tag.
        local room = pl.roomID and state.account.rooms[pl.roomID]   -- exception(nullable): stale tag reads as unassigned
        out[key] = {
            shape      = pl.shape or (room and room.shape),
            name       = (room and room.name) or pl.capturedName,
            floor      = pl.floor,
            floors     = pl.floors,   -- multi-floor span override (stairwell push-up)
            cell       = { x = pl.x, y = pl.y, rotation = pl.rotation },
            roomID     = room and pl.roomID or nil,
            slotKey    = key,
            unassigned = (not room) or nil,
            isBase       = pl.isBase,
            captureIndex = pl.captureIndex,
        }
    end
    return out
end

-- ===== Action blocks (self-registered; Store dispatches via HDG.Actions) ====
-- IDs counter-minted (echoed via session.furn for the dispatching controller);
-- reverse indexes maintained in place. Same single-dispatch-path reducer --
-- just housed with its domain.


-- ===== Self-registered actions (SELFREG_RESOLVER_DESIGN, first domain) =====
-- One block per action: reduce + invalidates + flags in ONE place (meta
-- moved here from Init.BuildActionMeta; merged back at boot with a
-- duplicate-source error). Bodies are the former SF.Reduce branches,
-- verbatim -- the golden dispatch-equivalence corpus pins that claim.
-- All persist (account.* writes); session.furn carries minted-ID echoes
-- + the changeSeq; session.furnIndex is the maintained reverse index.

HDG.Actions:Register{ name = "FURN_SET_CREATE",
    invalidates = { "account.furnishingSets", "session.furn",
                    "account.furnishingSetSeq" },
    reduce = function(state, payload)
        local acct = state.account
        acct.furnishingSetSeq = acct.furnishingSetSeq + 1
        local id, items = "set:" .. acct.furnishingSetSeq, {}
        for i, d in ipairs(payload.items or {}) do items[i] = { id = d.id, count = d.count or 1 } end
        acct.furnishingSets[id] = {
            id = id, name = payload.name or "New Set", items = items,
            isLocal = payload.isLocal or nil, ownerRoom = payload.ownerRoom,
            createdAt = payload.ts or 0,
        }
        state.session.furn.lastSetID = id
        state.session.furn.changeSeq = state.session.furn.changeSeq + 1
    end }

HDG.Actions:Register{ name = "FURN_SET_RENAME",
    invalidates = { "account.furnishingSets" },
    reduce = function(state, payload)
        local set = payload.setID and state.account.furnishingSets[payload.setID]   -- exception(nullable): lookup can miss on stale UI
        if set and payload.name and payload.name ~= "" then set.name = payload.name end
    end }

HDG.Actions:Register{ name = "FURN_SET_DELETE",
    invalidates = { "account.furnishingSets", "account.rooms", "session.furnIndex", "session.furn" },
    reduce = function(state, payload)
        local acct, idx = state.account, state.session.furnIndex
        local sid = payload.setID
        if sid and acct.furnishingSets[sid] then
            for roomID in pairs(idx.setRooms[sid] or {}) do   -- exception(nullable): unequipped sets have no index entry
                local room = acct.rooms[roomID]
                for i = #room.furnishingSetIDs, 1, -1 do
                    if room.furnishingSetIDs[i] == sid then table.remove(room.furnishingSetIDs, i) end
                end
            end
            idx.setRooms[sid] = nil
            acct.furnishingSets[sid] = nil
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

HDG.Actions:Register{ name = "FURN_SET_ITEM_ADD",
    invalidates = { "account.furnishingSets" },
    reduce = function(state, payload)
        local set = payload.setID and state.account.furnishingSets[payload.setID]   -- exception(nullable): lookup can miss on stale UI
        if set and payload.itemID then
            local found
            for _, it in ipairs(set.items) do
                if it.id == payload.itemID then found = it break end
            end
            if found then
                -- Explicit count SETS (set-quantity gesture); absent INCREMENTS (card click).
                found.count = payload.count or ((found.count or 1) + 1)
                if found.count <= 0 then
                    for i, it in ipairs(set.items) do
                        if it.id == payload.itemID then table.remove(set.items, i) break end
                    end
                end
            elseif (payload.count or 1) > 0 then
                set.items[#set.items + 1] = { id = payload.itemID, count = payload.count or 1 }
            end
        end
    end }

HDG.Actions:Register{ name = "FURN_SET_ITEM_REMOVE",
    invalidates = { "account.furnishingSets" },
    reduce = function(state, payload)
        local set = payload.setID and state.account.furnishingSets[payload.setID]   -- exception(nullable): lookup can miss on stale UI
        if set and payload.itemID then
            for i, it in ipairs(set.items) do
                if it.id == payload.itemID then
                    local n = (it.count or 1) - 1
                    if payload.all or n <= 0 then table.remove(set.items, i)
                    else it.count = n end
                    break
                end
            end
        end
    end }

HDG.Actions:Register{ name = "FURN_SET_PROMOTE",
    invalidates = { "account.furnishingSets", "session.furn" },
    reduce = function(state, payload)
        local set = payload.setID and state.account.furnishingSets[payload.setID]   -- exception(nullable): lookup can miss on stale UI
        if set then
            set.isLocal, set.ownerRoom = nil, nil
            if payload.name and payload.name ~= "" then set.name = payload.name end
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

HDG.Actions:Register{ name = "FURN_ROOM_CREATE",
    invalidates = { "account.rooms", "account.projects.layouts", "session.furn", "session.furnIndex",
                    "account.roomSeq" },
    reduce = function(state, payload)
        local acct = state.account
        acct.roomSeq = acct.roomSeq + 1
        local id = "room:" .. acct.roomSeq
        acct.rooms[id] = {
            id = id, name = payload.name, shape = payload.shape,
            furnishingSetIDs = {}, createdAt = payload.ts or 0,
        }
        state.session.furn.lastRoomID = id
        state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        -- Create-in-place from an unassigned slot: TAG the slot (v8 -- the
        -- placement key is stable; lineage stays on the placement).
        local layout = payload.layoutID and acct.projects.layouts[payload.layoutID]   -- exception(nullable): create can be slot-less (Rooms list "+ New Room")
        local slot = layout and payload.slotKey and layout.placements[payload.slotKey]
        if slot then
            local prev = slot.roomID   -- retag: the old design loses this spot
            slot.roomID = id
            if not acct.rooms[id].shape then acct.rooms[id].shape = slot.shape end
            if (not payload.name) and slot.capturedName then acct.rooms[id].name = slot.capturedName end
            local idx = state.session.furnIndex
            if prev and idx.roomLayouts[prev] and idx.roomLayouts[prev][payload.layoutID] then
                local n = idx.roomLayouts[prev][payload.layoutID] - 1
                idx.roomLayouts[prev][payload.layoutID] = n > 0 and n or nil
            end
            idx.roomLayouts[id] = { [payload.layoutID] = 1 }
        end
    end }

HDG.Actions:Register{ name = "FURN_ROOM_RENAME",
    invalidates = { "account.rooms" },
    reduce = function(state, payload)
        local room = payload.roomID and state.account.rooms[payload.roomID]   -- exception(nullable): lookup can miss on stale UI
        if room and payload.name and payload.name ~= "" then room.name = payload.name end
    end }

HDG.Actions:Register{ name = "FURN_ROOM_DELETE",
    invalidates = { "account.rooms", "account.furnishingSets", "account.projects.layouts", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        local acct, idx = state.account, state.session.furnIndex
        local room = payload.roomID and acct.rooms[payload.roomID]   -- exception(nullable): lookup can miss on stale UI
        if room then
            -- v8: UNTAG across ALL layouts -- the spots survive as bare
            -- unassigned shapes (no geometry vanishes on demolish).
            for _, layout in pairs(acct.projects.layouts) do
                for _, pl in pairs(layout.placements) do
                    if pl.roomID == payload.roomID then pl.roomID = nil end
                end
            end
            -- Local sets demote to library ("nothing user-made is destroyed implicitly").
            for _, sid in ipairs(room.furnishingSetIDs) do
                local set = acct.furnishingSets[sid]
                if set and set.isLocal and set.ownerRoom == payload.roomID then
                    set.isLocal, set.ownerRoom = nil, nil
                    set.name = ((room.name and room.name ~= "" and room.name) or "Design") .. " -- saved pieces"
                end
                if idx.setRooms[sid] then idx.setRooms[sid][payload.roomID] = nil end
            end
            idx.roomLayouts[payload.roomID] = nil
            acct.rooms[payload.roomID] = nil
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

HDG.Actions:Register{ name = "FURN_ROOM_EQUIP",
    invalidates = { "account.rooms", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        local acct = state.account
        local room = payload.roomID and acct.rooms[payload.roomID]   -- exception(nullable): lookup can miss on stale UI
        if room and payload.setID and acct.furnishingSets[payload.setID] then
            local present
            for _, sid in ipairs(room.furnishingSetIDs) do
                if sid == payload.setID then present = true break end
            end
            if not present then
                room.furnishingSetIDs[#room.furnishingSetIDs + 1] = payload.setID
                local idx = state.session.furnIndex
                idx.setRooms[payload.setID] = idx.setRooms[payload.setID] or {}
                idx.setRooms[payload.setID][payload.roomID] = true
                state.session.furn.changeSeq = state.session.furn.changeSeq + 1
            end
        end
    end }

HDG.Actions:Register{ name = "FURN_ROOM_UNEQUIP",
    invalidates = { "account.rooms", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        local room = payload.roomID and state.account.rooms[payload.roomID]   -- exception(nullable): lookup can miss on stale UI
        if room and payload.setID then
            for i = #room.furnishingSetIDs, 1, -1 do
                if room.furnishingSetIDs[i] == payload.setID then table.remove(room.furnishingSetIDs, i) end
            end
            local idx = state.session.furnIndex
            if idx.setRooms[payload.setID] then idx.setRooms[payload.setID][payload.roomID] = nil end
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

HDG.Actions:Register{ name = "FURN_ROOM_DUPLICATE",
    invalidates = { "account.rooms", "account.furnishingSets", "account.projects.layouts", "session.furn", "session.furnIndex",
                    "account.furnishingSetSeq",
                    "account.roomSeq" },
    reduce = function(state, payload)
        -- Variant for what-if work: library sets are SHARED (edit propagates by
        -- design), the local set is CLONED (the variant owns its own pieces).
        -- Lineage (legacyID) is NOT copied -- recapture keeps matching the source.
        local acct, idx = state.account, state.session.furnIndex
        local src = payload.roomID and acct.rooms[payload.roomID]   -- exception(nullable): lookup can miss on stale UI
        if src then
            acct.roomSeq = acct.roomSeq + 1
            local id   = "room:" .. acct.roomSeq
            -- Default copy name: strip any existing "(copy)"/"(copy N)" suffix
            -- so forks of forks number cleanly ("Revile (copy 2)") instead of
            -- stacking ("Revile (copy) (copy)" -- owner 2026-06-11). Numbered
            -- against existing design names; deterministic (state-derived).
            local name = payload.name and payload.name ~= "" and payload.name
            if not name then
                local base = ((src.name and src.name ~= "" and src.name) or "Design")
                    :gsub(" %(copy%)$", ""):gsub(" %(copy %d+%)$", "")
                local taken = {}
                for _, r in pairs(acct.rooms) do
                    if r.name then taken[r.name] = true end
                end
                name = base .. " (copy)"
                local n2 = 2
                while taken[name] do
                    name = base .. " (copy " .. n2 .. ")"
                    n2 = n2 + 1
                end
            end
            local copy = { id = id, shape = src.shape, name = name,
                           furnishingSetIDs = {}, createdAt = payload.ts or 0 }
            acct.rooms[id] = copy
            for _, sid in ipairs(src.furnishingSetIDs) do
                local set = acct.furnishingSets[sid]
                if set and set.isLocal and set.ownerRoom == payload.roomID then
                    acct.furnishingSetSeq = acct.furnishingSetSeq + 1
                    local nsid, items = "set:" .. acct.furnishingSetSeq, {}
                    for i, it in ipairs(set.items) do items[i] = { id = it.id, count = it.count } end
                    acct.furnishingSets[nsid] = { id = nsid, name = set.name, items = items,
                                                  isLocal = true, ownerRoom = id, createdAt = payload.ts or 0 }
                    copy.furnishingSetIDs[#copy.furnishingSetIDs + 1] = nsid
                    idx.setRooms[nsid] = { [id] = true }
                elseif set then
                    copy.furnishingSetIDs[#copy.furnishingSetIDs + 1] = sid
                    idx.setRooms[sid] = idx.setRooms[sid] or {}
                    idx.setRooms[sid][id] = true
                end
            end
            -- Optional swap: the copy takes the source's spots in ONE layout
            -- (v8: a retag across every placement the source held there).
            local layout = payload.layoutID and acct.projects.layouts[payload.layoutID]   -- exception(nullable): swap is optional
            if layout and payload.swap then
                local n = 0
                for _, pl in pairs(layout.placements) do
                    if pl.roomID == payload.roomID then pl.roomID = id; n = n + 1 end
                end
                if n > 0 then
                    if idx.roomLayouts[payload.roomID] then idx.roomLayouts[payload.roomID][payload.layoutID] = nil end
                    idx.roomLayouts[id] = { [payload.layoutID] = n }
                end
            end
            state.session.furn.lastRoomID = id
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

HDG.Actions:Register{ name = "LAYOUT_SWAP_ROOM",
    invalidates = { "account.projects.layouts", "account.rooms", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        -- The placement changes hands in ONE layout; both rooms persist.
        local acct = state.account
        -- v8: retag every spot the outgoing room holds in this layout.
        local layout = payload.layoutID and acct.projects.layouts[payload.layoutID]   -- exception(nullable): lookup can miss on stale UI
        local to     = payload.toRoomID and acct.rooms[payload.toRoomID]
        if layout and to and payload.fromRoomID then
            local n, shape = 0, nil
            for _, pl in pairs(layout.placements) do
                if pl.roomID == payload.fromRoomID then
                    pl.roomID = payload.toRoomID
                    shape = shape or pl.shape
                    n = n + 1
                end
            end
            if n > 0 then
                -- A shapeless ("+ New Room") incomer adopts the spots' shape.
                if not to.shape then to.shape = shape end
                SF.RebuildIndexes(state)
                state.session.furn.changeSeq = state.session.furn.changeSeq + 1
            end
        end
    end }

HDG.Actions:Register{ name = "LAYOUT_PLACE",
    invalidates = { "account.projects.layouts", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        local acct = state.account
        local layout = payload.layoutID and acct.projects.layouts[payload.layoutID]   -- exception(nullable): lookup can miss on stale UI
        if layout then
            local rec = { floor = payload.floor or 1, x = payload.x or 0,
                          y = payload.y or 0, rotation = payload.rotation or 0,
                          floors = payload.floors }
            if payload.roomID and acct.rooms[payload.roomID]
               and not acct.rooms[payload.roomID].shape then
                -- v8 invariant: shape lives on EVERY placement. A shapeless
                -- design can't be placed directly -- it gains a shape via
                -- assignment/swap (slot-shape adoption). Refuse LOUDLY rather
                -- than minting a shape=nil record (the planDiff crash class).
                HDG.Log:Warn("projects_save",
                    "Place refused: that design has no shape yet -- assign it to a room instead")
            elseif payload.roomID and acct.rooms[payload.roomID] then
                -- v8: a TAGGED slot -- a room may hold any number of spots.
                layout.slotSeq = (layout.slotSeq or 0) + 1
                rec.shape, rec.roomID = acct.rooms[payload.roomID].shape, payload.roomID
                layout.placements["slot:" .. layout.slotSeq] = rec
                local idx = state.session.furnIndex
                idx.roomLayouts[payload.roomID] = idx.roomLayouts[payload.roomID] or {}
                idx.roomLayouts[payload.roomID][payload.layoutID] =
                    (idx.roomLayouts[payload.roomID][payload.layoutID] or 0) + 1
                state.session.furn.changeSeq = state.session.furn.changeSeq + 1
            elseif payload.shape then
                -- Unassigned slot (doodle) -- persists, lazily curated via LAYOUT_ASSIGN.
                layout.slotSeq = (layout.slotSeq or 0) + 1
                rec.shape = payload.shape
                layout.placements["slot:" .. layout.slotSeq] = rec
            end
        end
    end }

HDG.Actions:Register{ name = "LAYOUT_MOVE",
    invalidates = { "account.projects.layouts" },
    reduce = function(state, payload)
        local layout = payload.layoutID and state.account.projects.layouts[payload.layoutID]   -- exception(nullable): lookup can miss on stale UI
        local pl = layout and payload.key and layout.placements[payload.key]
        if pl then
            if payload.floor    ~= nil then pl.floor    = payload.floor    end
            if payload.x        ~= nil then pl.x        = payload.x        end
            if payload.y        ~= nil then pl.y        = payload.y        end
            if payload.rotation ~= nil then pl.rotation = payload.rotation end
            if payload.floors   ~= nil then pl.floors   = payload.floors   end   -- span override
        end
    end }

HDG.Actions:Register{ name = "LAYOUT_REMOVE_PLACEMENT",
    invalidates = { "account.projects.layouts", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        local layout = payload.layoutID and state.account.projects.layouts[payload.layoutID]   -- exception(nullable): lookup can miss on stale UI
        if layout and payload.key and layout.placements[payload.key] then
            local rid = layout.placements[payload.key].roomID
            layout.placements[payload.key] = nil
            local idx = state.session.furnIndex
            if rid and idx.roomLayouts[rid] and idx.roomLayouts[rid][payload.layoutID] then
                local n = idx.roomLayouts[rid][payload.layoutID] - 1
                idx.roomLayouts[rid][payload.layoutID] = n > 0 and n or nil
            end
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

HDG.Actions:Register{ name = "LAYOUT_ASSIGN",
    invalidates = { "account.projects.layouts", "account.rooms", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        -- v8: assignment is a TAG -- the slot keeps its key, the room may
        -- already hold other spots here (multi-assign is the point).
        local acct = state.account
        local layout = payload.layoutID and acct.projects.layouts[payload.layoutID]   -- exception(nullable): lookup can miss on stale UI
        local slot = layout and payload.slotKey and layout.placements[payload.slotKey]
        if slot and payload.roomID and acct.rooms[payload.roomID] then
            local prev = slot.roomID
            slot.roomID = payload.roomID
            -- A room created off-canvas ("+ New Room") has no shape yet --
            -- it takes the slot's shape on first assignment.
            if not acct.rooms[payload.roomID].shape then
                acct.rooms[payload.roomID].shape = slot.shape
            end
            local idx = state.session.furnIndex
            if prev and idx.roomLayouts[prev] and idx.roomLayouts[prev][payload.layoutID] then
                local n = idx.roomLayouts[prev][payload.layoutID] - 1
                idx.roomLayouts[prev][payload.layoutID] = n > 0 and n or nil
            end
            idx.roomLayouts[payload.roomID] = idx.roomLayouts[payload.roomID] or {}
            idx.roomLayouts[payload.roomID][payload.layoutID] =
                (idx.roomLayouts[payload.roomID][payload.layoutID] or 0) + 1
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

HDG.Actions:Register{ name = "LAYOUT_UNASSIGN",
    invalidates = { "account.projects.layouts", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        -- Clear the tag: the spot reverts to a bare unassigned shape; the
        -- room (and its furnishings) persists untouched.
        local layout = payload.layoutID and state.account.projects.layouts[payload.layoutID]   -- exception(nullable): lookup can miss on stale UI
        local pl = layout and payload.key and layout.placements[payload.key]
        if pl and pl.roomID then
            local rid = pl.roomID
            pl.roomID = nil
            local idx = state.session.furnIndex
            if idx.roomLayouts[rid] and idx.roomLayouts[rid][payload.layoutID] then
                local n = idx.roomLayouts[rid][payload.layoutID] - 1
                idx.roomLayouts[rid][payload.layoutID] = n > 0 and n or nil
            end
            state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        end
    end }

