-- HDG.Projects selectors
-- ============================================================================
-- Pure read layer over account.projects + account.collections (crates) +
-- session.house (live budget/floor) + session.ui.projects (nav).
-- reads declared; test_selector_reads enforces accuracy by execution.

HDG = HDG or {}
local Selectors = HDG.Selectors

-- ===== Active-layout resolution (v7 Furnishings model) ======================
-- Layouts hold placements; rooms are persistent (account.rooms). The active
-- layout = focused house's activeVersionID (field name kept through the
-- transition; the IDs are layout IDs). Returns nil pre-capture.
local function _activeLayoutContext(state)
    local houses = state.account.projects.houses
    -- The Architect shows the FOCUSED house (highest focusSeq, set by the house
    -- switcher). Ties fall back to most-recently-captured, then the lexicographically
    -- greatest houseID (pairs() order is non-deterministic; memo correctness requires
    -- a stable pick). focusSeq + lastCapturedAt both live under account.projects.houses,
    -- so no new selector reads-path is introduced.
    local houseID, house, bestFocus, bestTS = nil, nil, -1, -1
    for id, h in pairs(houses) do
        local focus, ts = h.focusSeq or 0, h.lastCapturedAt or 0
        if focus > bestFocus
            or (focus == bestFocus and ts > bestTS)
            or (focus == bestFocus and ts == bestTS and houseID and id > houseID) then
            houseID, house, bestFocus, bestTS = id, h, focus, ts
        end
    end
    if not house then return nil end
    -- Active = explicitly chosen (Load in Architect / version switch / import),
    -- else the Live layout. VALIDATE the pointer: live SVs carry dangling
    -- activeVersionIDs (the pre-v7 version-delete never cleared it), and
    -- migrated v6 houses that never switched versions have only currentVersionID.
    local layouts = state.account.projects.layouts
    local lid     = house.activeVersionID
    local layout  = lid and layouts[lid]
    if not layout then
        lid    = house.currentVersionID
        layout = lid and layouts[lid]
    end
    if not layout then return nil end
    return houseID, lid, layout
end

-- Active layout, materialized for the spatial pipeline (or empty): keys are
-- placement keys (room:N / slot:N); records carry shape/name/floor/cell (+
-- unassigned for doodle slots). Callers declare the layout + rooms reads.
local function _activeRooms(state)
    local _, lid = _activeLayoutContext(state)
    return HDG.StoreFurnishings.LayoutView(state, lid)
end

-- v8: canvas selections are SLOT KEYS; the landing may still pass a room id.
-- Resolve the transient to (roomID, room record) whichever form it holds.
local function _selectedRoom(state)
    local key = state.session.ui.projects.selectedRoomID
    if not key then return nil end
    local rec = _activeRooms(state)[key]
    local rid = (rec and rec.roomID) or key
    local room = state.account.rooms[rid]   -- exception(nullable): bare slots / stale selections have no room
    if room then return rid, room end
    return nil
end

-- A room's door cardinals, DERIVED (Phase 2 -- no stored doorCardinals): a stairwell's
-- one door faces its neighbour (FloorMap), everything else is the shape's door slots
-- rotated by the room's cell.rotation. The single source for "where can this connect".
local function _roomDoorCardinals(rooms, roomID)
    local A, room = HDG.Projects.ShapeAtlas, rooms[roomID]
    if not room then return {} end
    -- Single-door rooms (stairwell + garden): one door floats to the nearest neighbour
    -- (any cardinal), derived from the ground-floor connection.
    if room.shape == "staircase" or room.shape == "staircase_mirror" or A.IsCircle(room.shape) then
        return { HDG.Projects.FloorMap.FloatingDoorCardinal(rooms, roomID) }
    end
    local rot, out = (room.cell and room.cell.rotation) or 0, {}
    for _, card in ipairs(A.GetDoors(room.shape)) do
        out[#out + 1] = A.RotateCardinal(card, rot)
    end
    return out
end

-- Any room in the active version? Drives landing <-> architect view switch.
-- Landing content exists: persistent rooms, library sets, or any layout
-- holding placements (slot doodles survive deleting every room) -- only a
-- truly empty Projects shows the first-capture CTA.
local function _hasLandingContent(state)
    if next(state.account.rooms) then return true end
    for _, set in pairs(state.account.furnishingSets) do
        if not set.isLocal then return true end
    end
    for _, layout in pairs(state.account.projects.layouts) do
        if next(layout.placements) then return true end
    end
    return false
end
Selectors:Register("projects.hasRooms", {
    reads = { "account.rooms", "account.furnishingSets", "account.projects.layouts" },
    fn = _hasLandingContent,
})

-- Currently shown/edited versionID (controllers need it since roomID doesn't encode it).
Selectors:Register("projects.activeVersionID", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    fn = function(state)
        local _, vid = _activeLayoutContext(state)
        return vid
    end,
})

-- All versions of the active house, Live first then what-ifs by createdAt.
-- { versionID, houseID, name, isActive, isCurrent }. Empty pre-capture.
Selectors:Register("projects.versionTabs", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    fn = function(state)
        local houseID = _activeLayoutContext(state)
        if not houseID then return {} end
        local house, out = state.account.projects.houses[houseID], {}
        for vid, v in pairs(state.account.projects.layouts) do
            if v.houseID == houseID then
                out[#out + 1] = {
                    versionID = vid, houseID = houseID, name = v.name or "?",
                    isActive  = (vid == house.activeVersionID),
                    isCurrent = (vid == house.currentVersionID),
                    createdAt = v.createdAt or 0,
                }
            end
        end
        table.sort(out, function(a, b)
            if a.isCurrent ~= b.isCurrent then return a.isCurrent end   -- Live first
            return a.createdAt < b.createdAt
        end)
        return out
    end,
})

-- The active layout's label for the switcher button: "Layout: Live" / "Layout: What-if 1".
Selectors:Register("projects.activeVersionLabel", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    fn = function(state)
        local houseID, vid, layout = _activeLayoutContext(state)
        if not layout then return "Layout: -" end
        local isCurrent = (vid == state.account.projects.houses[houseID].currentVersionID)
        return "Layout: " .. (layout.name or "?") .. (isCurrent and " (Live)" or "")
    end,
})

-- House switcher (Architect breadcrumb dropdown). Sourced from ALL the player's
-- owned houses (session.house.ownedHouses) -- not just captured ones -- so both
-- show even before capture; the token is the same digest the capture mints, so
-- picking a captured house focuses it (uncaptured -> a focus stub + empty canvas).
Selectors:Register("projects.houseMenuItems", {
    reads = { "session.house.ownedHouses" },
    fn = function(state)
        local IDs, out = HDG.Projects.IDs, {}
        for _, h in pairs(state.session.house.ownedHouses) do
            if h.name and h.plotID then
                out[#out + 1] = {
                    value = IDs.makeHouseID(IDs.hashToken(h.name .. ":" .. tostring(h.plotID))),
                    text  = h.name,
                }
            end
        end
        table.sort(out, function(a, b)
            if a.text ~= b.text then return a.text < b.text end
            return a.value < b.value
        end)
        return out
    end,
})
-- The focused house token (the dropdown's current value). Picks the highest focusSeq
-- house directly -- works even for a versionless focus stub (unlike _activeLayoutContext,
-- which needs a version), so the dropdown reflects the pick before capture.
Selectors:Register("projects.activeHouseID", {
    reads = { "account.projects.houses" },
    fn = function(state)
        local bestID, bestFocus, bestTS = nil, -1, -1
        for id, h in pairs(state.account.projects.houses) do
            local focus, ts = h.focusSeq or 0, h.lastCapturedAt or 0
            if focus > bestFocus or (focus == bestFocus and ts > bestTS)
               or (focus == bestFocus and ts == bestTS and bestID and id > bestID) then
                bestID, bestFocus, bestTS = id, focus, ts
            end
        end
        return bestID
    end,
})

-- Mode: Stock = active version IS the live/current version (palette locked);
-- what-if = branched (design freely). Both false pre-capture.
-- `visible` bindings don't negate, hence two selectors.
Selectors:Register("projects.isWhatIfMode", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    fn = function(state)
        local houseID, vid, version = _activeLayoutContext(state)
        return (version ~= nil) and (vid ~= state.account.projects.houses[houseID].currentVersionID)
    end,
})
Selectors:Register("projects.isStockMode", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    fn = function(state)
        local houseID, vid, version = _activeLayoutContext(state)
        return (version ~= nil) and (vid == state.account.projects.houses[houseID].currentVersionID)
    end,
})

-- Canvas render layout for the selected floor: rooms in the active version, positioned
-- by explicit room.cell. One layout path (version IS the design; no plannedOnly/AutoLayout).
Selectors:Register("projects.planLayout", {
    memoized = true,
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms", "session.ui.projects.selectedFloor" },
    fn = function(state)
        local IDs, A = HDG.Projects.IDs, HDG.Projects.ShapeAtlas
        local floor = state.session.ui.projects.selectedFloor
        local layout, meta = {}, {}
        for roomID, room in pairs(_activeRooms(state)) do
            if room.floor == floor then
                local rot, cells = room.cell.rotation or 0, A.GetCells(room.shape)
                local rc = A.RotateCells(cells, rot)
                layout[roomID] = {
                    cell = { x = room.cell.x, y = room.cell.y },
                    w = rc[1], d = rc[2], rotation = rot,
                    mask = A.RotateMask(A.GetMask(room.shape), rot, cells[1], cells[2]),
                }
                meta[roomID] = { shape = room.shape, name = room.name }
            end
        end
        return { layout = layout, rooms = meta, connections = {} }
    end,
})

-- Placeable-shape palette: every shape except Entry (anchor room; captured, never placed).
-- Merges live stock from room catalog snapshot. Geometry stays ShapeAtlas; catalog supplies ownership.
Selectors:Register("projects.paletteShapes", {
    reads = { "session.house.roomCatalog" },
    fn = function(state)
        local A, out = HDG.Projects.ShapeAtlas, {}
        local cat = state.session.house.roomCatalog.byShapeID
        for _, shape in ipairs(A.ListShapes()) do
            if shape ~= "entry" then
                local e = cat[shape]
                out[#out + 1] = {
                    shape = shape, label = A.GetLabel(shape),
                    -- Live catalog's blueprint tile when the snapshot has it;
                    -- ShapeAtlas glyph is the pre-snapshot fallback.
                    budget = A.GetBudget(shape),
                    atlas = (e and e.iconAtlas) or A.GetAtlas(shape),
                    owned = (e and e.owned) or false,
                    numStored = (e and e.numStored) or 0,
                    numPlaced = (e and e.numPlaced) or 0,
                }
            end
        end
        return out
    end,
})

-- Live room catalog: snapshotted by the observer on HOUSING_STORAGE_UPDATED.
-- Pure read of state slot (Inv 1: catalog API never runs in a selector).
Selectors:Register("projects.roomCatalog", {
    reads = { "session.house.roomCatalog" },
    fn = function(state) return state.session.house.roomCatalog.entries end,
})

-- Plan validation: no footprint overlap AND within room budget (roomMax 0 = skip).
-- SPAN-AWARE: a lower floor's projected volume (garden; planner-stamped stair
-- span) occupies this floor too, so a room parked inside it collides -- the old
-- same-floor-only walk reported "Valid" for exactly the overlaps the drag guard
-- forbids (2026-08-10 review #8).
Selectors:Register("projects.planValidation", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.selectedFloor" },
    calls = { "projects.placementCaps" },
    memoized = true,   -- span-aware walk rotates every in-span mask; cache between invalidations
    fn = function(state, ctx)
        local A = HDG.Projects.ShapeAtlas
        local floor = state.session.ui.projects.selectedFloor
        local occ, collide, cost, count = {}, false, 0, 0
        for rid, room in pairs(_activeRooms(state)) do
            local span = room.floors or A.GetFloors(room.shape)
            if room.floor == floor then
                count, cost = count + 1, cost + A.GetBudget(room.shape)
            end
            if room.floor <= floor and floor <= room.floor + span - 1 then
                local rot, cells = room.cell.rotation or 0, A.GetCells(room.shape)
                for _, m in ipairs(A.RotateMask(A.GetMask(room.shape), rot, cells[1], cells[2])) do
                    local k = (room.cell.x + m[1]) .. "," .. (room.cell.y + m[2])
                    if occ[k] then collide = true else occ[k] = true end
                end
            end
        end
        local roomMax    = Selectors:Call("projects.placementCaps", state, ctx).roomMax
        local overBudget = (roomMax > 0) and (cost > roomMax)
        return { collide = collide, overBudget = overBudget, roomCount = count,
                 roomCost = cost, roomMax = roomMax, hardOK = (not collide) and (not overBudget) }
    end,
})
Selectors:Register("projects.planValidationSummary", {
    calls = { "projects.planValidation" },
    fn = function(state, ctx)
        local v = Selectors:Call("projects.planValidation", state, ctx)
        if v.roomCount == 0 then return "Plan empty - click a shape to add a room" end
        local issues = {}
        if v.collide    then issues[#issues + 1] = "rooms overlap" end
        if v.overBudget then issues[#issues + 1] = "over room budget" end
        if #issues == 0 then
            return string.format("Valid - %d rooms, cost %d/%d", v.roomCount, v.roomCost, v.roomMax)
        end
        return "Fix: " .. table.concat(issues, ", ")
    end,
})

-- Room shopping list: active version vs current (reality) version, tallied by shape.
-- delta > 0 = design wants more (build); < 0 = reality has extra (remove).
-- Active == current -> empty diff. Pure; no live API.
Selectors:Register("projects.planDiff", {
    memoized = true,  -- O(rooms) double-walk; shoppingListRows + planDiffSummary bottom out here.
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms", "session.ui.projects.selectedFloor" },
    fn = function(state)
        local floor = state.session.ui.projects.selectedFloor
        local houseID, lid, layout = _activeLayoutContext(state)
        if not layout then return { rows = {}, added = 0, missing = 0 } end
        local house   = state.account.projects.houses[houseID]
        local curView = HDG.StoreFurnishings.LayoutView(state, house.currentVersionID)
        local plan, cap = {}, {}
        for _, room in pairs(_activeRooms(state)) do
            if room.floor == floor then plan[room.shape] = (plan[room.shape] or 0) + 1 end
        end
        for _, room in pairs(curView) do
            if room.floor == floor then cap[room.shape] = (cap[room.shape] or 0) + 1 end
        end
        local shapes = {}
        for sh in pairs(plan) do shapes[sh] = true end
        for sh in pairs(cap)  do shapes[sh] = true end
        local rows, added, missing = {}, 0, 0
        for sh in pairs(shapes) do
            local delta = (plan[sh] or 0) - (cap[sh] or 0)
            if delta ~= 0 then
                rows[#rows + 1] = { shape = sh, label = HDG.Projects.ShapeAtlas.GetLabel(sh), delta = delta }
                if delta > 0 then added = added + delta else missing = missing - delta end
            end
        end
        table.sort(rows, function(a, b) return a.label < b.label end)
        return { rows = rows, added = added, missing = missing }
    end,
})

-- Room shopping list: BUILD rows (design wants more) first, then REMOVE rows.
-- Empty in Stock mode (active == current version).
Selectors:Register("projects.shoppingListRows", {
    calls = { "projects.planDiff" },
    fn = function(state, ctx)
        local d, A, rows = Selectors:Call("projects.planDiff", state, ctx), HDG.Projects.ShapeAtlas, {}
        for _, r in ipairs(d.rows) do
            if r.delta > 0 then
                rows[#rows + 1] = { kind = "build", shape = r.shape, label = r.label, count = r.delta, weight = r.delta * A.GetBudget(r.shape) }
            end
        end
        for _, r in ipairs(d.rows) do
            if r.delta < 0 then
                rows[#rows + 1] = { kind = "remove", shape = r.shape, label = r.label, count = -r.delta, weight = (-r.delta) * A.GetBudget(r.shape) }
            end
        end
        return rows
    end,
})
Selectors:Register("projects.hasShoppingList", {
    calls = { "projects.shoppingListRows" },
    fn = function(state, ctx) return #Selectors:Call("projects.shoppingListRows", state, ctx) > 0 end,
})

-- v7: the selected room's furnishing sets, projected in the legacy panel shape
-- (the Phase-2 UI replaces this surface; orphans no longer exist).
Selectors:Register("projects.crateRows", {
    memoized = true,
    reads = { "account.rooms", "account.furnishingSets", "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local roomID, room = _selectedRoom(state)
        local crates = {}
        if room then
            for _, sid in ipairs(room.furnishingSetIDs) do
                local set = state.account.furnishingSets[sid]
                crates[#crates + 1] = { id = sid, name = set.name, decor = set.items }
            end
        end
        return { crates = crates, orphans = {} }
    end,
})


-- placementCaps: room + decor budgets from level-reward records (NOT the live API).
-- WHY: C_HousingLayout.GetRoomPlacementBudget returns engine defaults until Edit Layout
-- opens; max-level houses never open it -> reads 9 forever. The reward record always
-- carries the true cap. Rooms = valueType 2, InteriorDecor = valueType 0.
-- { roomMax, decorMax } = 0 until rewards async-land; consumers treat 0 as "no cap".
local _E_RT = _G.Enum and _G.Enum.HouseLevelRewardType        -- exception(boundary): absent in headless harness
local _E_VT = _G.Enum and _G.Enum.HouseLevelRewardValueType
local REWARD_VALUE   = (_E_RT and _E_RT.Value)         or 0
local VTYPE_ROOMS    = (_E_VT and _E_VT.Rooms)         or 2
local VTYPE_INTERIOR = (_E_VT and _E_VT.InteriorDecor) or 0
Selectors:Register("projects.placementCaps", {
    reads = { "session.house.snapshot", "session.house.snapshotChangeSeq" },
    fn = function(state)
        local nr = state.session.house.snapshot.nextRewards
        local roomMax, decorMax = 0, 0
        if nr and nr.rewards then
            for _, r in ipairs(nr.rewards) do
                if r.type == REWARD_VALUE then
                    local v = (nr.atMax and r.newValue or r.oldValue) or 0  -- exception(boundary): reward fields optional in schema
                    if     r.valueType == VTYPE_ROOMS    then roomMax  = v
                    elseif r.valueType == VTYPE_INTERIOR then decorMax = v end
                end
            end
        end
        return { roomMax = roomMax, decorMax = decorMax }
    end,
})

-- Room placement budget: planned room weight vs roomMax cap (reward-derived).
-- Whole-house (NOT per-floor like planValidation). over/overBy drive amber "+N over".
Selectors:Register("projects.roomBudget", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    calls = { "projects.placementCaps" },
    fn = function(state, ctx)
        local A, cost = HDG.Projects.ShapeAtlas, 0
        for _, room in pairs(_activeRooms(state)) do
            -- One record per room (a multi-floor room's span is derived, not extra records).
            cost = cost + A.GetBudget(room.shape)
        end
        local max = Selectors:Call("projects.placementCaps", state, ctx).roomMax
        return { cost = cost, max = max, over = (max > 0 and cost > max), overBy = math.max(0, cost - max) }
    end,
})
-- "rooms 59 / 95" with amber "+N over" when over cap (what-if never hard-blocks).
-- ColorCode is a deterministic palette lookup (pure; ADR-022).
Selectors:Register("projects.roomBudgetText", {
    calls = { "projects.roomBudget" },
    fn = function(state, ctx)
        local b = Selectors:Call("projects.roomBudget", state, ctx)
        if b.max <= 0 then return "" end
        -- house-room-limit-icon (Blizzard atlas) prefixes the count as the visual label.
        local txt = "|A:house-room-limit-icon:16:16|a " .. string.format("%d / %d", b.cost, b.max)
        if b.over then
            txt = txt .. "  " .. HDG.Theme:ColorCode("semantic.warning") .. "+" .. b.overBy .. " over|r"
        end
        return txt
    end,
})
-- Room budget as 0-1 fraction for the progressbar (clamped at 1; amber text carries overflow).
Selectors:Register("projects.roomBudgetProgress", {
    calls = { "projects.roomBudget" },
    fn = function(state, ctx)
        local b = Selectors:Call("projects.roomBudget", state, ctx)
        if b.max <= 0 then return 0 end
        local p = b.cost / b.max
        return (p > 1) and 1 or p
    end,
})

-- Architect columns: picker + canvas always; detail column appears when a room is selected
-- (window widens in-place; visible=sidePanelOpen collapses the track when nothing selected).
Selectors:Register("projects.architectColumns", {
    reads = { "session.ui.projects.selectedRoomID" },
    fn = function(state)
        if state.session.ui.projects.selectedRoomID then
            return { 170, 620, 290 }
        end
        return { 170, 620 }
    end,
})

-- Floor tab list: 1..max(live numFloors, version.numFloors, highest room floor).
-- What-if: version.numFloors is the user-controlled count (1..3 cap).
-- How many floors the house HAS: the live capture, the what-if's declared count,
-- and any room sitting above both. ONE rule, because the floor tab strip and the
-- Section view must agree on it -- a floor with a tab but no plate is a bug the
-- player sees before we do.
local function _declaredFloorCount(state)
    local _, _, layout = _activeLayoutContext(state)
    local maxFloor = state.session.house.numFloors
    if layout and layout.numFloors and layout.numFloors > maxFloor then   -- exception(nullable): no active layout in Live mode
        maxFloor = layout.numFloors
    end
    for _, room in pairs(_activeRooms(state)) do
        if room.floor and room.floor > maxFloor then maxFloor = room.floor end
    end
    return maxFloor
end

Selectors:Register("projects.floorTabs", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.house.numFloors", "session.ui.projects.selectedFloor" },
    fn = function(state)
        local maxFloor = _declaredFloorCount(state)
        local active = state.session.ui.projects.selectedFloor
        local tabs = {}
        for f = 1, maxFloor do tabs[#tabs + 1] = { floor = f, isActive = (f == active) } end
        return tabs
    end,
})

-- What-if floor controls: + Floor (whatIf + count < 3) / - Floor (whatIf + count > 1).
local function _whatIfFloorCount(state)
    local _, _, layout = _activeLayoutContext(state)
    if not layout then return 0 end
    if layout.numFloors then return layout.numFloors end
    local maxFloor = 1
    for _, room in pairs(_activeRooms(state)) do
        if room.floor and room.floor > maxFloor then maxFloor = room.floor end
    end
    return maxFloor
end
Selectors:Register("projects.canAddWhatIfFloor", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    calls = { "projects.isWhatIfMode" },
    fn = function(state, ctx)
        if not Selectors:Call("projects.isWhatIfMode", state, ctx) then return false end
        return _whatIfFloorCount(state) < 3
    end,
})
Selectors:Register("projects.canRemoveWhatIfFloor", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    calls = { "projects.isWhatIfMode" },
    fn = function(state, ctx)
        if not Selectors:Call("projects.isWhatIfMode", state, ctx) then return false end
        return _whatIfFloorCount(state) > 1
    end,
})

-- ============================================================================
-- Render layer: canvas model, room detail, breadcrumb, remap, landing.
-- All pure; live API + relative-time formatting at the controller/view boundary.
-- ============================================================================

-- Display label: room name + "<floor>-<captureIndex>" tag ("Hallway 1-2").
-- Distinguishes duplicate shapes across floors.
local function _withRoomNumber(base, room, floor)
    if room.captureIndex and floor then return base .. " " .. floor .. "-" .. room.captureIndex end
    if room.captureIndex then return base .. " " .. room.captureIndex end
    return base
end

-- FULL label (detail panel / breadcrumb / room lists).
local function _roomLabel(room, floor)
    if not room then return "?" end
    return _withRoomNumber(room.name or HDG.Projects.ShapeAtlas.GetLabel(room.shape), room, floor)
end

-- roomID -> "in-progress" for rooms whose furnishings hold any items.
-- Keyed by REAL room ids -- v8 canvas keys are slot keys, so the model
-- resolves through the placement's roomID tag before this lookup.
local function _roomStatusMap(state)
    local out = {}
    for rid, room in pairs(state.account.rooms) do
        for _, sid in ipairs(room.furnishingSetIDs) do
            local set = state.account.furnishingSets[sid]
            if set and #set.items > 0 then out[rid] = "in-progress" break end
        end
    end
    return out
end

local function _extend(bb, x, y)
    if bb.minX == nil or x < bb.minX then bb.minX = x end
    if bb.maxX == nil or x > bb.maxX then bb.maxX = x end
    if bb.minY == nil or y < bb.minY then bb.minY = y end
    if bb.maxY == nil or y > bb.maxY then bb.maxY = y end
end

-- Extend a bbox accumulator by a room's whole footprint (origin + far corner).
local function _extendFootprint(bb, x, y, w, d)
    _extend(bb, x, y)
    _extend(bb, x + w - 1, y + d - 1)
end

-- Door midpoint in CELL-BOUNDARY coords -- the shared geometry lives in
-- ShapeAtlas.DoorMid (the connectivity solver aligns doors with the SAME math,
-- so a solved layout's paired orbs light up as connected here by construction).
local function _doorMid(card, x, y, w, d, mask)
    return HDG.Projects.ShapeAtlas.DoorMid(card, x, y, w, d, mask)
end

-- Floor below the selected one -> dimmed backdrop tiles. Extends bbox for auto-fit.
-- Same active-version rooms, one floor down (cells are explicit).
local function _lowerFloorBackdrop(state, selectedFloor, bb)
    if selectedFloor <= 1 then return {} end
    local A = HDG.Projects.ShapeAtlas
    local below, out = selectedFloor - 1, {}
    for rid, r in pairs(_activeRooms(state)) do
        if r.floor == below then
            local rot, cells = r.cell.rotation or 0, A.GetCells(r.shape)
            local rc = A.RotateCells(cells, rot)
            out[#out + 1] = { shape = r.shape, x = r.cell.x, y = r.cell.y,
                              w = rc[1], d = rc[2], rotation = rot,
                              atlas = A.GetAtlas(r.shape), circle = A.IsCircle(r.shape) }
            _extendFootprint(bb, r.cell.x, r.cell.y, rc[1], rc[2])
        end
    end
    return out
end

-- Canvas render model: rooms (cell + selection + status), door orbs, lower-floor backdrop,
-- and bbox for auto-fit tiling. One layout path (active version IS the design).
-- Canvas card for a placed (real) room. Assigned rooms label by NAME (shape is
-- readable from the outline); slots fall back to shape label + badge at paint.
-- Furnishing status belongs to the TAGGED room (room.roomID), not the slot key.
local function _placedRoomCard(roomID, placed, meta, cell, room, canon, statusMap, selectedRoomID, A)
    return {
        roomID = roomID, shape = meta.shape,
        name = (room and not room.unassigned and room.name and room.name ~= "" and room.name) or nil,
        unassigned = (room and room.unassigned) or nil,
        x = cell.x, y = cell.y, w = placed.w, d = placed.d, rotation = placed.rotation or 0,
        canonW = canon[1], canonD = canon[2],   -- unrotated footprint -> icon rotates without stretch
        atlas = A.GetAtlas(meta.shape), circle = A.IsCircle(meta.shape),
        isSelected = (roomID == selectedRoomID),
        status = (room and room.roomID and statusMap[room.roomID]) or "unconfigured",
    }
end

-- Door orbs from a placed room's SHAPE door slots (every door can connect in a
-- manual layout). Single-door rooms (stairwell / garden circle) float one door
-- to the CLOSEST ground neighbour in world-space (no RotateCardinal); stairwells
-- render that same door on every floor.
local function _emitPlacedDoorOrbs(orbs, roomID, meta, cell, placed, canon, roomsByID, A)
    local rmask = A.RotateMask(A.GetMask(meta.shape), placed.rotation or 0, canon[1], canon[2])
    if meta.shape == "staircase" or meta.shape == "staircase_mirror" or A.IsCircle(meta.shape) then
        local card   = HDG.Projects.FloorMap.FloatingDoorCardinal(roomsByID, roomID)
        local mx, my = _doorMid(card, cell.x, cell.y, placed.w, placed.d, rmask)
        orbs[#orbs + 1] = { roomID = roomID, cardinal = card, midX = mx, midY = my }
    else
        for _, card in ipairs(A.GetDoors(meta.shape)) do
            local rc = A.RotateCardinal(card, placed.rotation or 0)
            local mx, my = _doorMid(rc, cell.x, cell.y, placed.w, placed.d, rmask)
            orbs[#orbs + 1] = { roomID = roomID, cardinal = rc, midX = mx, midY = my }
        end
    end
end

-- Dimmed, non-interactive ghost card for a multi-floor room (garden / stairwell
-- / tall) projected up from a lower floor so its occupancy reads on floors above.
local function _projectedRoomCard(pr, rc, canon, rot, A)
    return {
        roomID = "proj:" .. pr.roomID, shape = pr.shape, name = A.GetLabel(pr.shape),
        x = pr.cell.x, y = pr.cell.y, w = rc[1], d = rc[2], rotation = rot,
        canonW = canon[1], canonD = canon[2],
        atlas = A.GetAtlas(pr.shape), circle = A.IsCircle(pr.shape),
        isSelected = false, status = "unconfigured", projected = true,
    }
end

-- Projected-ghost door orbs. Stairwells inherit their single ground-floor door
-- on every floor; tall multi-door rooms project ALL doors so rooms can connect
-- on any side upstairs. Gardens (circle) are door-less (ground-only) -> skipped.
local function _emitProjectedDoorOrbs(orbs, pr, rc, rot, canon, roomsByID, A)
    if pr.shape == "staircase" or pr.shape == "staircase_mirror" then
        local rmask  = A.RotateMask(A.GetMask(pr.shape), rot, canon[1], canon[2])
        local card   = HDG.Projects.FloorMap.FloatingDoorCardinal(roomsByID, pr.roomID)
        local mx, my = _doorMid(card, pr.cell.x, pr.cell.y, rc[1], rc[2], rmask)
        orbs[#orbs + 1] = { roomID = "proj:" .. pr.roomID, cardinal = card, midX = mx, midY = my }
    elseif not A.IsCircle(pr.shape) then
        local rmask = A.RotateMask(A.GetMask(pr.shape), rot, canon[1], canon[2])
        for _, door in ipairs(A.GetDoors(pr.shape)) do
            local rcard  = A.RotateCardinal(door, rot)
            local mx, my = _doorMid(rcard, pr.cell.x, pr.cell.y, rc[1], rc[2], rmask)
            orbs[#orbs + 1] = { roomID = "proj:" .. pr.roomID, cardinal = rcard, midX = mx, midY = my }
        end
    end
end

-- Connection by PLACEMENT: two opposite-facing doors sharing an edge midpoint
-- are placed against each other -> connected (glowing orb). Purely spatial.
local function _markOrbConnections(orbs)
    local doorMap, OPP = {}, { N = "S", S = "N", E = "W", W = "E" }
    for _, o in ipairs(orbs) do
        local k = o.midX .. "," .. o.midY
        doorMap[k] = doorMap[k] or {}
        doorMap[k][o.cardinal] = true
    end
    for _, o in ipairs(orbs) do
        o.connected = doorMap[o.midX .. "," .. o.midY][OPP[o.cardinal]] == true
    end
end

Selectors:Register("projects.canvasModel", {
    memoized = true,
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "account.furnishingSets", "session.ui.projects.selectedFloor",
              "session.ui.projects.selectedRoomID" },
    calls = { "projects.planLayout" },
    fn = function(state, ctx)
        local nav       = state.session.ui.projects
        local cur       = Selectors:Call("projects.planLayout", state, ctx)
        local roomsByID = _activeRooms(state)
        local statusMap = _roomStatusMap(state)
        local rooms, orbs = {}, {}
        local bb = { minX = nil, maxX = nil, minY = nil, maxY = nil }
        local A = HDG.Projects.ShapeAtlas

        for roomID, placed in pairs(cur.layout) do
            local meta, cell = cur.rooms[roomID] or {}, placed.cell
            local room  = roomsByID[roomID]
            local canon = A.GetCells(meta.shape)
            rooms[#rooms + 1] = _placedRoomCard(roomID, placed, meta, cell, room, canon, statusMap, nav.selectedRoomID, A)
            _extendFootprint(bb, cell.x, cell.y, placed.w, placed.d)
            _emitPlacedDoorOrbs(orbs, roomID, meta, cell, placed, canon, roomsByID, A)
        end

        -- Project multi-floor rooms from lower floors as ghosts (SSoT: same FloorMap).
        for _, pr in ipairs(HDG.Projects.FloorMap.ProjectedRooms(roomsByID, nav.selectedFloor)) do
            local canon = A.GetCells(pr.shape)
            local rot   = pr.cell.rotation or 0
            local rc    = A.RotateCells(canon, rot)
            rooms[#rooms + 1] = _projectedRoomCard(pr, rc, canon, rot, A)
            _extendFootprint(bb, pr.cell.x, pr.cell.y, rc[1], rc[2])
            _emitProjectedDoorOrbs(orbs, pr, rc, rot, canon, roomsByID, A)
        end

        _markOrbConnections(orbs)

        local backdrop = _lowerFloorBackdrop(state, nav.selectedFloor, bb)
        local empty = (#rooms == 0)
        if empty then bb = { minX = 0, maxX = 0, minY = 0, maxY = 0 } end
        return {
            empty = empty, rooms = rooms, orbs = orbs, backdrop = backdrop,
            bbox = { minX = bb.minX, maxX = bb.maxX, minY = bb.minY, maxY = bb.maxY,
                     cols = (bb.maxX - bb.minX) + 1, rows = (bb.maxY - bb.minY) + 1 },
        }
    end,
})

-- ===== Section view (isometric) =============================================
-- The Architect's second view mode: the whole house as ONE drawing instead of a
-- floor at a time. Emits PURE CELL SPACE -- footprint-boundary edges in layout
-- cells, tagged by floor -- because the iso projection and the fit-to-viewport
-- scale depend on host size, which is not state. The controller owns both, the
-- same split the plan canvas already uses for its tiling.
--
-- WHY a whole-house model rather than per-floor: stair alignment and what sits
-- above what are VERTICAL relationships, and a floor-at-a-time view structurally
-- cannot show them.
local function _roomBoundaryEdges(cellX, cellY, mask)
    local occupied = {}
    for _, m in ipairs(mask) do occupied[(cellX + m[1]) .. "," .. (cellY + m[2])] = true end
    local edges = {}
    for _, m in ipairs(mask) do
        local x, y = cellX + m[1], cellY + m[2]
        if not occupied[x .. "," .. (y - 1)] then edges[#edges + 1] = { x, y, x + 1, y } end
        if not occupied[x .. "," .. (y + 1)] then edges[#edges + 1] = { x, y + 1, x + 1, y + 1 } end
        if not occupied[(x - 1) .. "," .. y] then edges[#edges + 1] = { x, y, x, y + 1 } end
        if not occupied[(x + 1) .. "," .. y] then edges[#edges + 1] = { x + 1, y, x + 1, y + 1 } end
    end
    return edges
end

-- Footprint centroid in cell space -- the label anchor and the stair-shaft foot.
local function _maskCentroid(cellX, cellY, mask)
    local sx, sy = 0, 0
    for _, m in ipairs(mask) do
        sx, sy = sx + cellX + m[1] + 0.5, sy + cellY + m[2] + 0.5
    end
    return sx / #mask, sy / #mask
end

Selectors:Register("projects.sectionModel", {
    memoized = true,
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.house.numFloors",
              "session.ui.projects.selectedFloor", "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local A, FM = HDG.Projects.ShapeAtlas, HDG.Projects.FloorMap
        local nav   = state.session.ui.projects
        local byFloor, stairAt = {}, {}
        local minX, maxX, minY, maxY, minF, maxF
        for roomID, room in pairs(_activeRooms(state)) do
            local rot   = room.cell.rotation or 0   -- exception(optional): rotation absent on un-rotated records
            local canon = A.GetCells(room.shape)
            local mask  = A.RotateMask(A.GetMask(room.shape), rot, canon[1], canon[2])
            local cx, cy = _maskCentroid(room.cell.x, room.cell.y, mask)
            local floor = room.floor
            local span  = FM.EffectiveSpan(room)
            byFloor[floor] = byFloor[floor] or {}
            local rooms = byFloor[floor]
            rooms[#rooms + 1] = {
                roomID   = roomID,
                shape    = room.shape,
                name     = room.name,
                edges    = _roomBoundaryEdges(room.cell.x, room.cell.y, mask),
                cx       = cx,
                cy       = cy,
                selected = (roomID == nav.selectedRoomID),
            }
            -- Every floor a stair record reaches gets a marker; a shaft segment is
            -- then any floor pair that BOTH carry one at the same anchor. That covers
            -- planner spans (one record, floors = 2) and captured sections (one
            -- span-1 record per floor) with the same rule.
            if A.IsStairShape(room.shape) then
                for f = floor, floor + span - 1 do
                    stairAt[f] = stairAt[f] or {}
                    stairAt[f][room.cell.x .. "," .. room.cell.y] = { cx = cx, cy = cy }
                end
            end
            for _, m in ipairs(mask) do
                local x, y = room.cell.x + m[1], room.cell.y + m[2]
                if not minX or x < minX then minX = x end
                if not maxX or x > maxX then maxX = x end
                if not minY or y < minY then minY = y end
                if not maxY or y > maxY then maxY = y end
            end
            if not minF or floor < minF then minF = floor end
            local top = floor + span - 1
            if not maxF or top > maxF then maxF = top end
        end

        -- Floors 1..declared, extended by any volume reaching higher: an empty top
        -- floor still earns a plate, exactly as it earns a tab.
        local declared = _declaredFloorCount(state)
        if declared and declared >= 1 then
            minF = 1
            if not maxF or declared > maxF then maxF = declared end
        end

        -- NOTHING TO DRAW: no floor at all, or floors with no rooms in them.
        --
        -- Both have to be tested, because they are set by different loops. The
        -- X/Y bounds come only from the ROOM loop above, while the declared-floor
        -- block just before this sets minF = 1 unconditionally from the LIVE
        -- game's floor count. So a player standing at a house with nothing
        -- captured yet has minF = 1 and no bounds at all -- and guarding on minF
        -- alone let that through to `maxX + 1` on nil (gnucleargnome, in-game
        -- 2026-09-01, opening the window from a zone alert's [View] link).
        --
        -- floorMin/floorMax carry the real range rather than a hardcoded 1, so a
        -- three-storey shell with nothing placed still reports three storeys.
        if not minF or not minX then
            return { empty = true, floors = {}, shafts = {},
                     bbox = { minX = 0, maxX = 0, minY = 0, maxY = 0, cols = 1, rows = 1 },
                     floorMin = minF or 1, floorMax = maxF or 1,
                     selectedFloor = nav.selectedFloor }
        end

        local shafts = {}
        for f = minF, maxF - 1 do
            local here, above = stairAt[f], stairAt[f + 1]
            if here and above then
                for key, anchor in pairs(here) do
                    if above[key] then
                        shafts[#shafts + 1] = { cx = anchor.cx, cy = anchor.cy, floor = f }
                    end
                end
            end
        end

        local floors = {}
        for f = minF, maxF do
            floors[#floors + 1] = { floor = f, rooms = byFloor[f] or {} }
        end
        return {
            empty = false, floors = floors, shafts = shafts,
            bbox = { minX = minX, maxX = maxX + 1, minY = minY, maxY = maxY + 1,
                     cols = (maxX - minX) + 1, rows = (maxY - minY) + 1 },
            floorMin = minF, floorMax = maxF, selectedFloor = nav.selectedFloor,
        }
    end,
})

-- Canvas mode: which of the two Architect views is live. Two selectors rather
-- than one string so LayoutConfig `visible` reads a boolean directly.
Selectors:Register("projects.canvasIsPlan", {
    reads = { "session.ui.projects.canvasMode" },
    fn = function(state) return state.session.ui.projects.canvasMode == "plan" end,
})
Selectors:Register("projects.canvasIsSection", {
    reads = { "session.ui.projects.canvasMode" },
    fn = function(state) return state.session.ui.projects.canvasMode == "section" end,
})
-- The toggle names the mode it switches TO (a button labels its action).
Selectors:Register("projects.canvasModeToggleLabel", {
    reads = { "session.ui.projects.canvasMode" },
    fn = function(state)
        if state.session.ui.projects.canvasMode == "plan" then return HDG.Locale:Get("PROJ_VIEW_SECTION") end
        return HDG.Locale:Get("PROJ_VIEW_PLAN")
    end,
})

-- Side panel open when a room is selected.
Selectors:Register("projects.sidePanelOpen", {
    reads = { "session.ui.projects.selectedRoomID" },
    fn = function(state)
        return state.session.ui.projects.selectedRoomID ~= nil
    end,
})

-- Selected room detail. Returns nil when nothing's selected (panel.visible gates render).
Selectors:Register("projects.roomDetail", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms", "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local roomID = state.session.ui.projects.selectedRoomID
        if not roomID then return nil end
        local room = _activeRooms(state)[roomID]
        if not room then return nil end   -- exception(boundary): stale selection (room demolished)
        return {
            roomID = roomID, shape = room.shape, name = room.name,
            shapeLabel = HDG.Projects.ShapeAtlas.GetLabel(room.shape),
            doors      = _roomDoorCardinals(_activeRooms(state), roomID),   -- derived, not stored
            isBase     = room.isBase,
        }
    end,
})

-- Selected room's crate detail. Name + icon stamped INTO the row envelope (not at paint)
-- per ADR-003b: cold-cache resolve bumps itemNames.names -> selector re-runs -> scrollbox
-- re-configures with real data. Resolving at paint breaks this cycle (the row data
-- wouldn't change on the tick, so cold rows stay on the fallback).
Selectors:Register("projects.crateDetail", {
    memoized = true,
    reads = { "account.rooms", "account.furnishingSets",
              "session.ui.projects.selectedRoomID", "session.itemNames.names" },
    fn = function(state)
        local roomID, room = _selectedRoom(state)
        if not room then return { hasCrate = false } end
        local setID, set
        for _, sid in ipairs(room.furnishingSetIDs) do
            local s = state.account.furnishingSets[sid]
            if s and s.isLocal and s.ownerRoom == roomID then setID, set = sid, s break end
        end
        if not set then return { hasCrate = false } end
        local R, rows, total = HDG.ItemNameResolver, {}, 0
        for _, d in ipairs(set.items) do
            local cnt = d.count or 1
            -- projectsFurnRow envelope (item kind, local -> steppers paint).
            rows[#rows + 1] = { kind = "item", isLocal = true, setID = setID,
                                decorID = d.id, count = cnt,
                                name = R:ResolveName(d.id), icon = R:ResolveIcon(d.id) }
            total = total + cnt
        end
        return { hasCrate = true, crateID = setID, crateName = set.name or "Furnishings",
                 completed = false, decorRows = rows, decorCount = total }
    end,
})

-- Thin composer (declarative widget binding). per ADR-024.
Selectors:Register("projects.crateDetailHasCrate", {
    calls = { "projects.crateDetail" },
    fn = function(state, ctx) return Selectors:Call("projects.crateDetail", state, ctx).hasCrate == true end,
})
-- (crateDetailNeedsCrate retired with the "+ Add Crate" CTA -- the local set
-- is created implicitly by the first add; see _ensureLocalSet.)
-- ===== Two-state curation panel (build plan 2.2) ============================
-- The selected canvas key resolves to either an UNASSIGNED slot ("which
-- room?" offer) or an ASSIGNED room (furnishings detail). One panel, two
-- widget sets, gated by these two selectors.

Selectors:Register("projects.slotPanelOpen", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local key = state.session.ui.projects.selectedRoomID
        local rec = key and _activeRooms(state)[key]   -- exception(nullable): stale selection
        return (rec and rec.unassigned) == true
    end,
})
Selectors:Register("projects.roomPanelOpen", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local key = state.session.ui.projects.selectedRoomID
        local rec = key and _activeRooms(state)[key]   -- exception(nullable): stale selection
        return (rec ~= nil) and not rec.unassigned
    end,
})

-- "Which room is this?" -- candidate rooms for the selected unassigned slot:
-- same shape (or shapeless "+ New Room" creations), rooms already placed in
-- this layout omitted (once-per-layout), ranked by use (most-placed first).
Selectors:Register("projects.slotAssignOffer", {
    memoized = true,
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.furnIndex", "session.furn", "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local key  = state.session.ui.projects.selectedRoomID
        local view = _activeRooms(state)
        local slot = key and view[key]   -- exception(nullable): stale selection
        if not (slot and slot.unassigned) then return {} end
        local _, lid, layout = _activeLayoutContext(state)
        if not layout then return {} end
        -- v8: ALREADY-PLACED rooms stay in the offer (multi-assign is the
        -- point); the spot count is the multiplicity signal (review condition a).
        local idx, out = state.session.furnIndex, {}
        for rid, room in pairs(state.account.rooms) do
            if room.shape == nil or room.shape == slot.shape then
                local hereCount = (idx.roomLayouts[rid] or {})[lid] or 0   -- exception(nullable): room may be placed nowhere
                local layouts = 0
                for _ in pairs(idx.roomLayouts[rid] or {}) do layouts = layouts + 1 end   -- exception(nullable): room may be placed nowhere
                out[#out + 1] = {
                    roomID = rid, slotKey = key, layoutID = lid,
                    hereCount = hereCount, layouts = layouts,
                    name = (room.name and room.name ~= "" and room.name)
                        or (room.shape and HDG.Projects.ShapeAtlas.GetLabel(room.shape)) or "Design",
                    noShape = room.shape == nil,
                }
            end
        end
        table.sort(out, function(a2, b2)
            if a2.name ~= b2.name then return a2.name < b2.name end
            return a2.roomID < b2.roomID
        end)
        return out
    end,
})

-- "Changes apply everywhere" notice for the assigned-room detail.
Selectors:Register("projects.roomInLayoutsText", {
    reads = { "account.rooms", "account.projects.houses", "account.projects.layouts",
              "session.furnIndex", "session.furn",
              "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local roomID, room = _selectedRoom(state)
        if not room then return "" end
        local lids = state.session.furnIndex.roomLayouts[roomID] or {}   -- exception(nullable): design may be placed nowhere
        local layouts = 0
        for _ in pairs(lids) do layouts = layouts + 1 end
        local _, lid = _activeLayoutContext(state)
        local here   = (lid and lids[lid]) or 0   -- exception(nullable): not placed in the active layout
        -- Sharing surprise prevention (owner 2026-06-11: two Reviles, same
        -- contents, no hint): lead with the in-THIS-layout share; fold the
        -- cross-layout count in compactly. One line -- the label doesn't wrap.
        if type(here) == "number" and here > 1 then
            if layouts > 1 then
                return ("Shared -- fills %d rooms here + %d other layout%s; edits affect all.")
                    :format(here, layouts - 1, (layouts - 1) == 1 and "" or "s")
            end
            return ("Shared -- fills %d rooms here; edits affect %s.")
                :format(here, here == 2 and "both" or "all of them")
        end
        if layouts <= 1 then return "" end
        return ("In %d layouts -- changes apply everywhere."):format(layouts)
    end,
})

-- Auto-assign gate: any unassigned SHAPED room in the active layout.
Selectors:Register("projects.hasUnassignedRooms", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    -- Memoized: _activeRooms builds a ~20 KB layout view per call to answer a
    -- boolean, and this is a visibility selector, so it ran on every layout
    -- pass (356 calls, 7 MB in one session -- 2026-09-13 allocation profile).
    memoized = true,
    fn = function(state)
        for _, rec in pairs(_activeRooms(state)) do
            if rec.unassigned and rec.shape then return true end
        end
        return false
    end,
})

-- Empty-offer hint: the slot panel's list can legitimately be empty (every
-- matching room is already placed in this layout, or none exists yet).
Selectors:Register("projects.slotOfferIsEmpty", {
    calls = { "projects.slotPanelOpen", "projects.slotAssignOffer" },
    fn = function(state, ctx)
        return Selectors:Call("projects.slotPanelOpen", state, ctx)
           and #Selectors:Call("projects.slotAssignOffer", state, ctx) == 0
    end,
})
-- The "which room?" prompt shows only when there ARE candidates -- the
-- empty-state line replaces it entirely (the pair read as duplicates).
Selectors:Register("projects.slotOfferHasRows", {
    calls = { "projects.slotPanelOpen", "projects.slotAssignOffer" },
    fn = function(state, ctx)
        return Selectors:Call("projects.slotPanelOpen", state, ctx)
           and #Selectors:Call("projects.slotAssignOffer", state, ctx) > 0
    end,
})

-- Library sets sort alpha (unnamed sink to ""), ties broken by set id.
local function _sortBySetNameThenID(a, b)
    if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
    return a.id < b.id
end

-- Split a room's furnishing sets into the sorted library list + its own local
-- set. A set can be deleted out from under the room while the ID lingers.
local function _partitionFurnishingSets(state, room, roomID)
    local lib, localSet = {}, nil
    for _, sid in ipairs(room.furnishingSetIDs) do
        local set = state.account.furnishingSets[sid]
        if set and set.isLocal and set.ownerRoom == roomID then localSet = set
        elseif set then lib[#lib + 1] = set end   -- exception(nullable): set deleted out from under the room
    end
    table.sort(lib, _sortBySetNameThenID)
    return lib, localSet
end

-- Header + item rows for one set. Library groups fold (click the header); the
-- room's own pieces never do. Name/icon stamped in (ADR-003b async re-render).
local function _emitFurnishingRows(rows, set, isLocal, folded, R)
    local collapsed = (not isLocal) and folded[set.id] == true
    local total = 0
    for _, it in ipairs(set.items) do total = total + (it.count or 1) end
    rows[#rows + 1] = { kind = "setHeader", setID = set.id, isLocal = isLocal,
                        name = isLocal and "This room's pieces" or (set.name or "Set"),
                        count = total, collapsed = collapsed }
    if collapsed then return end
    for _, it in ipairs(set.items) do
        rows[#rows + 1] = { kind = "item", setID = set.id, isLocal = isLocal,
                            decorID = it.id, count = it.count or 1,
                            name = R:ResolveName(it.id), icon = R:ResolveIcon(it.id) }
    end
end

-- Effective furnishings for the selected ASSIGNED room, grouped by set with
-- per-item provenance. Row kinds:
--   setHeader { setID, name, isLocal, count }  (Unequip paints on library sets)
--   item      { setID, isLocal, decorID, count, name, icon }  (steppers on local only)
-- Library sets first (alpha), the room's own pieces last.
Selectors:Register("projects.roomFurnishingsRows", {
    memoized = true,
    reads = { "account.rooms", "account.furnishingSets", "session.ui.projects.furnCollapsed",
              "session.ui.projects.selectedRoomID", "session.itemNames.names", "session.furn" },
    fn = function(state)
        local roomID, room = _selectedRoom(state)
        if not room then return {} end
        local R, folded = HDG.ItemNameResolver, state.session.ui.projects.furnCollapsed
        local lib, localSet = _partitionFurnishingSets(state, room, roomID)
        local rows = {}
        for _, set in ipairs(lib) do _emitFurnishingRows(rows, set, false, folded, R) end
        if localSet then _emitFurnishingRows(rows, localSet, true, folded, R) end
        return rows
    end,
})

-- ============================================================================
-- Decor picker: catalog browse scoped to "add to this crate".
-- {} when picker is closed (pickerCrateID nil). iconTexture/iconAtlas from
-- catalog (NOT GetItemIconByID -- decor previews).
-- ============================================================================
Selectors:Register("projects.pickerResults", {
    memoized = true,
    reads = { "account.furnishingSets", "session.ui.projects.pickerCrateID",
              "session.ui.projects.pickerSearch", "session.ui.projects.pickerSource",
              "session.ui.projects.focusedCategoryID", "session.ui.projects.focusedSubcategoryID",
              "account.collections", "account.vendorShoppingLists", "session.resolvers.staticData.tick",
              "account.collection.ownedDecorIDs", "session.resolvers.catalog.tick" },
    calls = { "decor.allItems" },
    fn = function(state, ctx)
        local crateID = state.session.ui.projects.pickerCrateID
        if not crateID then return {} end   -- picker closed
        local search  = state.session.ui.projects.pickerSearch:lower()
        local catFilt = state.session.ui.projects.focusedCategoryID    -- nil = All (rail)
        local subFilt = state.session.ui.projects.focusedSubcategoryID  -- nil = All within category
        local source  = state.session.ui.projects.pickerSource
        -- Source axis ("whose list is this from"): nil membership table = All Decor;
        -- otherwise only items in the chosen style bin / shopping list. Composes
        -- (AND) with the rail's Blizzard-taxonomy axis, like the Curator.
        local unownedOnly = (source == "unowned")
        local inSource
        if source and source ~= "all" and not unownedOnly then
            inSource = {}
            if source:sub(1, 6) == "style:" then
                local coll = state.account.collections[source]   -- exception(nullable): style deleted since menu render
                for _, itemID in ipairs((coll and coll.items) or {}) do inSource[itemID] = true end
            elseif source:sub(1, 5) == "shop:" then
                local list = state.account.vendorShoppingLists[source:sub(6)]   -- exception(nullable): list deleted since menu render
                for _, rec in ipairs((list and list.items) or {}) do inSource[rec.itemID] = true end
            elseif source:sub(1, 8) == "concept:" then
                -- Pre-authored Room Concepts: rule-based; resolved like the companion grid.
                for _, itemID in ipairs(HDG.StyleResolve.ItemsFor(source, state)) do inSource[itemID] = true end
            end
        end
        local planned = {}   -- itemID -> count in the target set (card badge)
        local set = state.account.furnishingSets[crateID]   -- exception(nullable): stale picker target
        if set then for _, d in ipairs(set.items) do planned[d.id] = d.count or 1 end end
        local rows = {}
        for _, it in ipairs(Selectors:Call("decor.allItems", state, ctx)) do
            -- ALL decor (owner 2026-06-11): plans may hold decor you don't own
            -- yet -- that's what feeds the acquisition stack. Unowned cards
            -- paint dimmed; the hover pane carries Queue craft / Add to
            -- Shopping for them.
            local nameOK = (search == "") or (it.name and it.name:lower():find(search, 1, true) ~= nil)
            -- Category nav filter (Blizzard categoryID; nil = All; 0 = Uncategorized).
            local row    = HDG.HousingCatalogObserver:GetRow(it.itemID)
            local catID  = (row and row.categoryID)    or 0
            local subID  = (row and row.subcategoryID) or 0
            local catOK  = (catFilt == nil) or (catFilt == catID)
            local subOK  = (subFilt == nil) or (subFilt == subID)
            local srcOK  = (inSource == nil) or inSource[it.itemID]
            if unownedOnly and it.isOwned then srcOK = false end
            if nameOK and catOK and subOK and srcOK then
                rows[#rows + 1] = {
                    itemID = it.itemID, decorID = it.decorID, name = it.name,
                    iconTexture = it.iconTexture, iconAtlas = it.iconAtlas,
                    plannedCount = planned[it.itemID] or 0,
                    owned = it.isOwned,
                }
            end
        end
        return rows
    end,
})

-- Hover acquisition gates: the preview pane offers Queue craft / Add to
-- Shopping for the hovered item when it's UNOWNED (that's the acquisition
-- loop: plan with decor you don't have, then click to go get it).
local function _hoverUnowned(state)
    local itemID = state.session.ui.projects.pickerSelectedItemID
    if not itemID then return nil end
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    local decorID = row and row.decorID
    if not decorID then return nil end   -- exception(nullable): catalog warms async
    if state.account.collection.ownedDecorIDs[decorID] then return nil end
    return itemID
end
Selectors:Register("projects.pickerHoverUnowned", {
    reads = { "session.ui.projects.pickerSelectedItemID",
              "account.collection.ownedDecorIDs", "session.resolvers.catalog.tick" },
    fn = function(state) return _hoverUnowned(state) ~= nil end,
})
Selectors:Register("projects.pickerHoverCraftable", {
    reads = { "session.ui.projects.pickerSelectedItemID",
              "account.collection.ownedDecorIDs", "session.resolvers.catalog.tick",
              "session.resolvers.staticData.tick" },
    fn = function(state)
        local itemID = _hoverUnowned(state)
        return itemID ~= nil and HDG.StaticData.Recipes:Get(itemID) ~= nil
    end,
})

-- Source dropdown ("Viewing: ..."): All Decor / style bins / shopping lists,
-- each with counts. Values: "all" | "style:<collID>" | "shop:<listID>".
Selectors:Register("projects.pickerSource", {
    reads = { "session.ui.projects.pickerSource" },
    fn = function(state) return state.session.ui.projects.pickerSource end,
})
Selectors:Register("projects.pickerSourceMenuItems", {
    reads = { "account.collections", "account.vendorShoppingLists", "session.resolvers.staticData.tick" },
    calls = { "decor.allItems" },
    fn = function(state, ctx)
        -- Counts on the catalog entries mirror the style entries' counts.
        local all, unowned = Selectors:Call("decor.allItems", state, ctx), 0
        for _, it in ipairs(all) do
            if not it.isOwned then unowned = unowned + 1 end
        end
        local items = {
            { text = ("All Decor (%d)"):format(#all),      value = "all" },
            { text = ("Unowned decor (%d)"):format(unowned), value = "unowned" },
        }
        local styles = {}
        for id, coll in pairs(state.account.collections) do
            if coll.type == "style" and coll.items and #coll.items > 0 then
                -- User styles store their name in displayName (STYLES_CREATE_STYLE).
                styles[#styles + 1] = { text = (coll.displayName or coll.name or "Style")
                    .. " (" .. #coll.items .. ")", value = id, sort = (coll.displayName or coll.name or "Style") }
            end
        end
        table.sort(styles, function(a2, b2)
            if a2.sort ~= b2.sort then return a2.sort < b2.sort end
            return a2.value < b2.value
        end)
        if #styles > 0 then
            items[#items + 1] = { kind = "title", text = "My Styles" }
            for _, s in ipairs(styles) do items[#items + 1] = { text = s.text, value = s.value } end
        end
        local lists = {}
        for lid, list in pairs(state.account.vendorShoppingLists) do
            if list.items and #list.items > 0 then
                lists[#lists + 1] = { text = (list.name or "List") .. " (" .. #list.items .. ")",
                                      value = "shop:" .. lid, sort = list.name or "List" }
            end
        end
        table.sort(lists, function(a2, b2)
            if a2.sort ~= b2.sort then return a2.sort < b2.sort end
            return a2.value < b2.value
        end)
        if #lists > 0 then
            items[#items + 1] = { kind = "title", text = "Shopping Lists" }
            for _, s in ipairs(lists) do items[#items + 1] = { text = s.text, value = s.value } end
        end
        -- Pre-authored Room Concepts (rule-based -- no cheap count; label only).
        local concepts = {}
        local sd = HDG.StaticData.Styles:GetDefinitions()
        if type(sd) == "table" then
            for sid, def in pairs(sd) do
                if def.tier ~= "collection" then
                    local nm = def.displayName or def.name or sid
                    concepts[#concepts + 1] = { text = nm, value = "concept:" .. sid, sort = nm }
                end
            end
        end
        table.sort(concepts, function(a2, b2)
            if a2.sort ~= b2.sort then return a2.sort < b2.sort end
            return a2.value < b2.value
        end)
        if #concepts > 0 then
            items[#items + 1] = { kind = "title", text = "Room Concepts" }
            for _, s in ipairs(concepts) do items[#items + 1] = { text = s.text, value = s.value } end
        end
        return items
    end,
})

-- Hover-driven info line under the 3D preview: "Owned N -- Planned here M".
Selectors:Register("projects.pickerHoverName", {
    reads = { "session.ui.projects.pickerSelectedItemID", "session.itemNames.names" },
    fn = function(state)
        local itemID = state.session.ui.projects.pickerSelectedItemID
        if not itemID then return "" end
        return HDG.ItemNameResolver:ResolveName(itemID) or ""
    end,
})
Selectors:Register("projects.pickerHoverLine", {
    reads = { "session.ui.projects.pickerSelectedItemID", "session.ui.projects.pickerCrateID",
              "account.furnishingSets", "session.resolvers.catalog.tick" },
    fn = function(state)
        local itemID = state.session.ui.projects.pickerSelectedItemID
        if not itemID then return "" end
        local row    = HDG.HousingCatalogObserver:GetRow(itemID)
        local owned  = (row and ((row.numStored or 0) + (row.numPlaced or 0))) or 0
        local planned = 0
        local set = state.account.furnishingSets[state.session.ui.projects.pickerCrateID]   -- exception(nullable): stale picker target
        if set then
            for _, d in ipairs(set.items) do
                if d.id == itemID then planned = d.count or 1 break end
            end
        end
        return ("Owned %d  --  Planned here %d"):format(owned, planned)
    end,
})

-- ===== Picker TARGET (the set being edited) =================================
-- The picker edits whatever set pickerCrateID points at: a room's own pieces
-- (local) OR a library set (the Rooms-list "Edit" entry). The right column is
-- always the target set -- title, stepper rows, totals.
local function _pickerTarget(state)
    local sid = state.session.ui.projects.pickerCrateID
    return sid, sid and state.account.furnishingSets[sid]   -- exception(nullable): stale picker target
end
Selectors:Register("projects.pickerTargetTitle", {
    reads = { "session.ui.projects.pickerCrateID", "account.furnishingSets",
              "account.rooms", "session.furnIndex", "session.furn" },
    fn = function(state)
        local _, set = _pickerTarget(state)
        if not set then return "" end
        if set.isLocal then
            local room = set.ownerRoom and state.account.rooms[set.ownerRoom]   -- exception(nullable): owner deleted out from under the set
            local name = (room and room.name and room.name ~= "" and room.name)
                or (room and room.shape and HDG.Projects.ShapeAtlas.GetLabel(room.shape)) or "Design"
            return name:upper() .. "  --  THIS DESIGN"
        end
        local n = 0
        for _ in pairs(state.session.furnIndex.setRooms[set.id] or {}) do n = n + 1 end   -- exception(nullable): set may be equipped nowhere
        return (set.name or "Set"):upper() .. "  --  LIBRARY SET"
            .. (n > 0 and ("  (in " .. n .. (n == 1 and " room)" or " rooms)")) or "")
    end,
})
Selectors:Register("projects.pickerTargetRows", {
    memoized = true,
    reads = { "session.ui.projects.pickerCrateID", "account.furnishingSets", "session.itemNames.names" },
    fn = function(state)
        local sid, set = _pickerTarget(state)
        if not set then return {} end
        local R, rows = HDG.ItemNameResolver, {}
        for _, d in ipairs(set.items) do
            -- Always steppers: the picker EDITS the target (library edits
            -- propagate to every room equipping the set -- by design).
            rows[#rows + 1] = { kind = "item", isLocal = true, setID = sid,
                                decorID = d.id, count = d.count or 1,
                                name = R:ResolveName(d.id), icon = R:ResolveIcon(d.id) }
        end
        return rows
    end,
})
Selectors:Register("projects.pickerTargetTotals", {
    reads = { "session.ui.projects.pickerCrateID", "account.furnishingSets" },
    fn = function(state)
        local _, set = _pickerTarget(state)
        if not set or #set.items == 0 then return "No pieces yet -- click a card to add" end
        local kinds, pieces = #set.items, 0
        for _, d in ipairs(set.items) do pieces = pieces + (d.count or 1) end
        return ("%d item%s  -  %d piece%s"):format(
            kinds, kinds == 1 and "" or "s", pieces, pieces == 1 and "" or "s")
    end,
})
-- Gates Save-as-Set + Equip-set (room-context actions; meaningless on a library target).
Selectors:Register("projects.pickerTargetIsLocal", {
    reads = { "session.ui.projects.pickerCrateID", "account.furnishingSets" },
    fn = function(state)
        local _, set = _pickerTarget(state)
        return (set and set.isLocal) == true
    end,
})
-- Scope indicator: editing a LOCAL set whose room is placed in 2+ layouts.
-- Total SPOTS a design fills across every layout (v8: index values are
-- per-layout counts -- multi-assign means spots > layouts is normal).
local function _designSpotCount(state, roomID)
    local spots = 0
    for _, c in pairs(state.session.furnIndex.roomLayouts[roomID] or {}) do   -- exception(nullable): design may be placed nowhere
        spots = spots + (type(c) == "number" and c or 1)
    end
    return spots
end

Selectors:Register("projects.pickerScopeShared", {
    reads = { "session.ui.projects.pickerCrateID", "account.furnishingSets",
              "session.furnIndex", "session.furn" },
    fn = function(state)
        local _, set = _pickerTarget(state)
        if not (set and set.isLocal and set.ownerRoom) then return false end
        -- SPOTS, not layouts (owner 2026-06-11: two octagons in ONE layout
        -- showed no copy affordance -- the gate predated multi-assign).
        return _designSpotCount(state, set.ownerRoom) >= 2
    end,
})
Selectors:Register("projects.pickerScopeText", {
    reads = { "session.ui.projects.pickerCrateID", "account.furnishingSets",
              "session.furnIndex", "session.furn" },
    fn = function(state)
        local _, set = _pickerTarget(state)
        if not (set and set.isLocal and set.ownerRoom) then return "" end
        local spots = _designSpotCount(state, set.ownerRoom)
        if spots < 2 then return "" end
        return ("This design fills %d rooms -- edits apply to all of them."):format(spots)
    end,
})

-- Fork gate: the selected room's design fills 2+ spots (anywhere) -- forking
-- a design that lives only here would just be a rename.
Selectors:Register("projects.canForkSelection", {
    reads = { "account.rooms", "account.projects.houses", "account.projects.layouts",
              "session.furnIndex", "session.furn", "session.ui.projects.selectedRoomID" },
    calls = { "projects.roomPanelOpen" },
    fn = function(state, ctx)
        if not Selectors:Call("projects.roomPanelOpen", state, ctx) then return false end
        local roomID = _selectedRoom(state)
        return roomID ~= nil and _designSpotCount(state, roomID) >= 2
    end,
})

-- Saved Styles importable into the open crate. {} when picker is closed.
-- ===== Decor-picker category rail (Blizzard in-situ drill-down) =============
-- storedOnly = false: picker dims (not hides) categories with no owned items.
Selectors:Register("projects.pickerRail", {
    memoized = true,
    reads = {
        "session.house.categoryTree",
        "session.ui.projects.focusedCategoryID",
        "session.ui.projects.focusedSubcategoryID",
    },
    fn = function(state)
        local p = state.session.ui.projects
        -- storedOnly = false since the picker shows ALL decor (release-18
        -- audit: owned-only rails hid categories whose every item is unowned,
        -- making them unreachable from the Unowned-decor source).
        return HDG.CategoryNav.BuildPickerRail(
            state.session.house.categoryTree, p.focusedCategoryID, p.focusedSubcategoryID, false)
    end,
})

-- modelPreview binds itemID to this (hovered/selected picker item).
Selectors:Register("projects.pickerSelectedItemID", {
    reads = { "session.ui.projects.pickerSelectedItemID" },
    fn = function(state) return state.session.ui.projects.pickerSelectedItemID end,
})

-- Breadcrumb chips: House > Floor N > [Room].
Selectors:Register("projects.breadcrumb", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.selectedFloor", "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local nav, houses = state.session.ui.projects, state.account.projects.houses
        local houseName, n = nil, 0
        for _, h in pairs(houses) do n = n + 1; houseName = h.name end
        local chips = { { id = "house", label = (n == 1 and houseName) or "My House" } }
        chips[#chips + 1] = { id = "floor", label = "Floor " .. nav.selectedFloor }
        if nav.selectedRoomID then
            local room = _activeRooms(state)[nav.selectedRoomID]
            if room then
                chips[#chips + 1] = { id = "room", label = _roomLabel(room, room.floor) }
            end
        end
        return chips
    end,
})

-- Ambiguous recapture matches awaiting manual remap. Empty = nothing pending.
Selectors:Register("projects.ambiguousMatches", {
    reads = { "session.ui.projects.ambiguous" },
    fn = function(state)
        return state.session.ui.projects.ambiguous
    end,
})

-- ===== Rooms list (landing) =================================================

-- Shared room-row comparator: floor ascending, then label.
local function _sortByFloorThenLabel(a, b)
    if a.floor ~= b.floor then return a.floor < b.floor end
    return a.label < b.label
end

-- Rooms placed in the active layout, ordered by floor then label (room-target menus).
Selectors:Register("projects.reclaimTargets", {
    memoized = true,
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms" },
    fn = function(state)
        local out = {}
        local seen = {}
        for _, room in pairs(_activeRooms(state)) do
            if not room.unassigned and room.roomID and not seen[room.roomID] then
                seen[room.roomID] = true
                out[#out + 1] = { roomID = room.roomID, label = _roomLabel(room, room.floor), floor = room.floor }
            end
        end
        table.sort(out, _sortByFloorThenLabel)
        return out
    end,
})

-- v7 Rooms list (landing, top box): EVERY persistent room -- name, shape,
-- equipped library sets, effective decor total, "in N layouts" (furnIndex).
-- A room placed in zero layouts is an ordinary row. Header row leads; click
-- selects (drives the box's action rail).
Selectors:Register("projects.roomsRows", {
    memoized = true,
    reads = { "account.rooms", "account.furnishingSets", "session.furnIndex", "session.furn",
              "session.ui.projects.landingRoomID" },
    fn = function(state)
        local SA  = HDG.Projects.ShapeAtlas
        local idx = state.session.furnIndex
        local sel = state.session.ui.projects.landingRoomID
        local list = {}
        for rid, room in pairs(state.account.rooms) do
            local n, chips = 0, {}
            for _, sid in ipairs(room.furnishingSetIDs) do
                local set = state.account.furnishingSets[sid]
                if set then   -- exception(nullable): set deleted out from under the room (repairable ref)
                    for _, it in ipairs(set.items) do n = n + (it.count or 1) end
                    if not set.isLocal then chips[#chips + 1] = set.name end
                end
            end
            local spots, layoutCount = 0, 0
            for _, n in pairs(idx.roomLayouts[rid] or {}) do   -- exception(nullable): room may be placed nowhere
                layoutCount = layoutCount + 1
                spots = spots + (type(n) == "number" and n or 1)
            end
            list[#list + 1] = {
                kind = "room", roomID = rid, isSelected = sel == rid,
                name = (room.name and room.name ~= "" and room.name)
                    or (room.shape and SA.GetLabel(room.shape)) or "Design",
                shapeLabel = room.shape and SA.GetLabel(room.shape) or "No shape yet",
                setChips = chips, decorCount = n, layoutCount = layoutCount, spots = spots,
            }
        end
        table.sort(list, function(a2, b2)
            if a2.name ~= b2.name then return a2.name < b2.name end
            return a2.roomID < b2.roomID   -- stable tiebreak (memo determinism)
        end)
        return list   -- the header lives OUTSIDE the box (fixed section band)
    end,
})
Selectors:Register("projects.roomsHeaderText", {
    reads = { "account.rooms" },
    fn = function(state)
        local n = 0
        for _ in pairs(state.account.rooms) do n = n + 1 end
        return "MY DESIGNS (" .. n .. ")"
    end,
})

-- The LIBRARY (landing, bottom box): every saved Furnishing Set, with reach.
Selectors:Register("projects.setsRows", {
    memoized = true,
    reads = { "account.furnishingSets", "session.furnIndex", "session.furn",
              "session.ui.projects.landingSetID" },
    fn = function(state)
        local idx, sel = state.session.furnIndex, state.session.ui.projects.landingSetID
        local sets = {}
        for sid, set in pairs(state.account.furnishingSets) do
            if not set.isLocal then
                local roomCount = 0
                for _ in pairs(idx.setRooms[sid] or {}) do roomCount = roomCount + 1 end   -- exception(nullable): set may be equipped nowhere
                local pieces = 0
                for _, it in ipairs(set.items) do pieces = pieces + (it.count or 1) end
                sets[#sets + 1] = { kind = "set", setID = sid, isSelected = sel == sid,
                                    name = set.name or "Set",
                                    pieces = pieces, roomCount = roomCount }
            end
        end
        table.sort(sets, function(a2, b2)
            if a2.name ~= b2.name then return a2.name < b2.name end
            return a2.setID < b2.setID
        end)
        return sets   -- the header lives OUTSIDE the box (fixed section band)
    end,
})
Selectors:Register("projects.setsHeaderText", {
    reads = { "account.furnishingSets" },
    fn = function(state)
        local n = 0
        for _, set in pairs(state.account.furnishingSets) do
            if not set.isLocal then n = n + 1 end
        end
        return "MY FURNISHING SETS (" .. n .. ")"
    end,
})

-- Rail enabled-gates: a row of the matching kind is selected AND still exists.
Selectors:Register("projects.landingRoomSelected", {
    reads = { "account.rooms", "session.ui.projects.landingRoomID" },
    fn = function(state)
        return state.account.rooms[state.session.ui.projects.landingRoomID or ""] ~= nil
    end,
})
Selectors:Register("projects.landingSetSelected", {
    reads = { "account.furnishingSets", "session.ui.projects.landingSetID" },
    fn = function(state)
        local set = state.account.furnishingSets[state.session.ui.projects.landingSetID or ""]
        return (set and not set.isLocal) == true
    end,
})
-- Cross-section action: a room AND a set selected, set not already equipped there.
Selectors:Register("projects.landingCanEquip", {
    reads = { "account.rooms", "account.furnishingSets",
              "session.ui.projects.landingRoomID", "session.ui.projects.landingSetID" },
    fn = function(state)
        local room = state.account.rooms[state.session.ui.projects.landingRoomID or ""]
        local sid  = state.session.ui.projects.landingSetID
        local set  = state.account.furnishingSets[sid or ""]
        if not (room and set and not set.isLocal) then return false end
        for _, equipped in ipairs(room.furnishingSetIDs) do
            if equipped == sid then return false end
        end
        return true
    end,
})

-- ============================================================================
-- Architect/landing view-feed selectors. per ADR-024.
-- ============================================================================

-- Decor budget as 0-1 fraction for the architect progressbar.
Selectors:Register("projects.budgetProgress", {
    reads = { "session.house.budget" },
    calls = { "projects.placementCaps" },
    fn = function(state, ctx)
        local b = state.session.house.budget
        local decorMax = Selectors:Call("projects.placementCaps", state, ctx).decorMax
        if decorMax <= 0 then return 0 end   -- exception(boundary): pre-capture or no cap -> avoid 0/0
        return b.decorSpent / decorMax
    end,
})

-- Decor budget label "128 / 210 decor" for the architect strip.
Selectors:Register("projects.budgetText", {
    reads = { "session.house.budget" },
    calls = { "projects.placementCaps" },
    fn = function(state, ctx)
        local b = state.session.house.budget
        local decorMax = Selectors:Call("projects.placementCaps", state, ctx).decorMax
        -- house-decor-budget-icon (Blizzard atlas) prefixes the count as the visual label.
        return "|A:house-decor-budget-icon:16:16|a " .. string.format("%d / %d", b.decorSpent, decorMax)
    end,
})

-- Breadcrumb string "My House  >  Floor 1  >  Hall" (ASCII separators only).
Selectors:Register("projects.breadcrumbText", {
    calls = { "projects.breadcrumb" },
    fn = function(state, ctx)
        local labels = {}
        for _, c in ipairs(Selectors:Call("projects.breadcrumb", state, ctx)) do
            labels[#labels + 1] = c.label
        end
        return table.concat(labels, "  >  ")
    end,
})

-- No rooms captured. Drives "Capture my house" CTA (visible bindings don't negate).
Selectors:Register("projects.noRooms", {
    reads = { "account.rooms", "account.furnishingSets", "account.projects.layouts" },
    fn = function(state) return not _hasLandingContent(state) end,
})

-- "Start a design" shows whenever the FOCUSED house has no layout yet --
-- a second owned house must be designable without capturing it first.
Selectors:Register("projects.canStartDesign", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.house.ownedHouses" },
    calls = { "projects.activeHouseID" },
    fn = function(state, ctx)
        local focusedID = Selectors:Call("projects.activeHouseID", state, ctx)
        if not focusedID then return true end   -- nothing focused = fresh Projects
        local house = state.account.projects.houses[focusedID]
        local lid   = house and (house.activeVersionID or house.currentVersionID)
        return not (lid and state.account.projects.layouts[lid])
    end,
})

-- Selected room's name for the detail-panel title label binding.
Selectors:Register("projects.roomDetailName", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms", "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local roomID = state.session.ui.projects.selectedRoomID
        local room = roomID and _activeRooms(state)[roomID]
        if not room then return "Select a room" end   -- exception(boundary): stale or nil selection
        -- room.floor direct: v8 keys are slot keys, parsePath never matched them,
        -- so the floor segment of "Hallway 1-2" never rendered (2026-08-10 review #9).
        return _roomLabel(room, room.floor)
    end,
})

-- Selected room meta: "Square M  -  Floor 1  -  doors: N/E".
Selectors:Register("projects.roomDetailMeta", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms", "session.ui.projects.selectedRoomID" },
    fn = function(state)
        local roomID = state.session.ui.projects.selectedRoomID
        local room = roomID and _activeRooms(state)[roomID]
        if not room then return "" end   -- exception(boundary): stale or nil selection
        local doors = table.concat(_roomDoorCardinals(_activeRooms(state), roomID), "/")
        return string.format("%s  -  Floor %d  -  doors: %s",
            HDG.Projects.ShapeAtlas.GetLabel(room.shape), room.floor or 1,
            (doors ~= "" and doors) or "none")
    end,
})

-- ===== Layouts tab ==========================================================
-- The Layouts tab browses/previews/shares saved versions. Its preview/detail read
-- the SELECTED version (session.ui.projects.layoutSelectedVersionID) -- NOT the
-- Architect's activeVersionID -- so browsing never disturbs editing.

-- Fallback label -- houses created by IMPORT (not yet captured) carry no
-- stamped name. Reverse-resolve through the SAME deterministic id the house
-- chooser mints from the owned-houses session list; "House" only when that
-- list hasn't arrived yet.
local function _houseLabel(state, houseID)
    local IDs = HDG.Projects.IDs
    for _, h in pairs(state.session.house.ownedHouses) do
        if h.name and h.plotID
           and IDs.makeHouseID(IDs.hashToken(h.name .. ":" .. tostring(h.plotID))) == houseID then
            return h.name
        end
    end
    return "House"
end

-- Left list: houses -> their versions (Live first, then what-ifs by createdAt), the
-- selected row flagged. Group header carries the faction label + level.
Selectors:Register("projects.layoutGroups", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.layoutSelectedVersionID", "session.house.ownedHouses" },
    fn = function(state)
        local p   = state.account.projects
        local sel = state.session.ui.projects.layoutSelectedVersionID
        local byHouse = {}
        for vid, v in pairs(p.layouts) do
            local g = byHouse[v.houseID]
            if not g then
                local house = p.houses[v.houseID]   -- strict: a version always belongs to a house
                -- Show the real house name (matches the Architect breadcrumb); fall back
                -- to the faction word only if the capture never stamped a name.
                g = { houseID = v.houseID, label = house.name or _houseLabel(state, v.houseID),
                      level = house.level, currentVersionID = house.currentVersionID, rows = {} }
                byHouse[v.houseID] = g
            end
            g.rows[#g.rows + 1] = {
                versionID = vid, name = v.name or "?", createdAt = v.createdAt or 0,
                isLive = (vid == g.currentVersionID), isSelected = (vid == sel),
            }
        end
        local groups = {}
        for _, g in pairs(byHouse) do
            table.sort(g.rows, function(a, b)
                if a.isLive ~= b.isLive then return a.isLive end   -- Live first
                return a.createdAt < b.createdAt
            end)
            groups[#groups + 1] = g
        end
        table.sort(groups, function(a, b) return a.label < b.label end)
        return groups
    end,
})

-- Preview: ALL floors (1..3) of the SELECTED version, each as positioned room
-- footprints + a bbox for fit-to-frame. Floor count = max room floor or
-- version.numFloors, capped at 3. The controller rotates each floor to fit its slot.
Selectors:Register("projects.layoutPreviewModel", {
    reads = { "account.projects.layouts", "account.rooms", "session.ui.projects.layoutSelectedVersionID" },
    -- Read by the preview and by layoutDetail, which six controller sites and two
    -- labels call: each one rebuilt every room's mask (8 x 109 KB on one Layouts
    -- visit, 2026-10-22 profile). Every reader only reads it.
    memoized = true,
    fn = function(state)
        local A   = HDG.Projects.ShapeAtlas
        local sel = state.session.ui.projects.layoutSelectedVersionID
        local layout = sel and state.account.projects.layouts[sel]
        -- exception(nullable): nothing selected, or selection points at a deleted
        -- layout -- the controller (re)selects a default and paints empty meanwhile.
        if not layout then return { floors = {}, floorCount = 0 } end
        local byFloor, maxFloor = {}, 1
        for _, room in pairs(HDG.StoreFurnishings.LayoutView(state, sel)) do
            if room.floor then
                if room.floor > maxFloor then maxFloor = room.floor end
                local rot   = room.cell.rotation or 0
                local cells = A.GetCells(room.shape)
                local rc    = A.RotateCells(cells, rot)
                local fl    = byFloor[room.floor]
                if not fl then fl = { rooms = {}, bb = {} }; byFloor[room.floor] = fl end
                fl.rooms[#fl.rooms + 1] = {
                    shape = room.shape, x = room.cell.x, y = room.cell.y,
                    w = rc[1], d = rc[2], rotation = rot,
                    -- Rotated footprint cells -> the preview draws true-shape vector
                    -- outlines (cross/T/L keep their silhouette; rects/octagons = bbox).
                    mask = A.RotateMask(A.GetMask(room.shape), rot, cells[1], cells[2]),
                    circle = A.IsCircle(room.shape),
                }
                _extendFootprint(fl.bb, room.cell.x, room.cell.y, rc[1], rc[2])
            end
        end
        if layout.numFloors and layout.numFloors > maxFloor then maxFloor = layout.numFloors end
        if maxFloor > 3 then maxFloor = 3 end
        local floors = {}
        for f = 1, maxFloor do
            local fl = byFloor[f] or { rooms = {}, bb = {} }
            floors[#floors + 1] = { floor = f, rooms = fl.rooms, bbox = fl.bb }
        end
        return { floors = floors, floorCount = maxFloor }
    end,
})

-- Bottom detail: name / house label / live-or-what-if / room + floor counts / budget /
-- canDelete (everything except the inviolable live version) for the SELECTED version.
Selectors:Register("projects.layoutDetail", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.layoutSelectedVersionID", "session.house.ownedHouses" },
    calls = { "projects.placementCaps", "projects.layoutPreviewModel" },
    memoized = true,   -- two labels and six controller sites read it in one refresh (6 x 131 KB, 2026-10-22)
    fn = function(state, ctx)
        local A   = HDG.Projects.ShapeAtlas
        local sel = state.session.ui.projects.layoutSelectedVersionID
        local layout = sel and state.account.projects.layouts[sel]
        if not layout then return { hasSelection = false } end   -- exception(nullable): no/deleted selection
        local house  = state.account.projects.houses[layout.houseID]
        local isLive = (sel == house.currentVersionID)
        local cost, roomCount = 0, 0
        for _, room in pairs(HDG.StoreFurnishings.LayoutView(state, sel)) do
            cost = cost + A.GetBudget(room.shape)
            roomCount = roomCount + 1
        end
        local max = Selectors:Call("projects.placementCaps", state, ctx).roomMax
        return {
            hasSelection = true, versionID = sel, houseID = layout.houseID,
            name = layout.name or "?", houseLabel = house.name or _houseLabel(state, layout.houseID),
            isLive = isLive, canDelete = not isLive, roomCount = roomCount,
            floorCount = Selectors:Call("projects.layoutPreviewModel", state, ctx).floorCount,
            budgetText = (max > 0) and string.format("%d / %d", cost, max) or "",
        }
    end,
})

-- Header label string for the right detail panel: "<name>  [LIVE]" or "<name>  [wif]".
Selectors:Register("projects.layoutDetailHeader", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.layoutSelectedVersionID" },
    calls = { "projects.layoutDetail" },
    fn = function(state, ctx)
        local d = Selectors:Call("projects.layoutDetail", state, ctx)
        if not d.hasSelection then return "" end
        -- Layout name only (owner 2026-06-11): the list row beside the title
        -- already carries the house group + wif badge. [LIVE] is the one state
        -- worth repeating -- "this is captured reality, not a sketch" matters
        -- right before Load in Architect.
        return d.name .. (d.isLive and "  [LIVE]" or "")
    end,
})

-- Flat list for the layouts scrollbox: house group headers interleaved with
-- version rows. Derived from layoutGroups. ed.kind="header"|"version".
Selectors:Register("projects.layoutListRows", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.layoutSelectedVersionID" },
    calls = { "projects.layoutGroups" },
    fn = function(state, ctx)
        local groups = Selectors:Call("projects.layoutGroups", state, ctx)
        local out = {}
        for _, g in ipairs(groups) do
            out[#out + 1] = { kind = "header", houseID = g.houseID,
                houseLabel = g.label, level = g.level }
            for _, row in ipairs(g.rows) do
                out[#out + 1] = { kind = "version", versionID = row.versionID,
                    name = row.name, isLive = row.isLive, isSelected = row.isSelected,
                    houseID = g.houseID }
            end
        end
        return out
    end,
})

-- Boolean: true when there is a valid layout selection (used for `visible` bindings).
Selectors:Register("projects.hasLayoutSelection", {
    reads = { "account.projects.layouts", "account.rooms", "session.ui.projects.layoutSelectedVersionID" },
    fn = function(state)
        local sel = state.session.ui.projects.layoutSelectedVersionID
        return sel ~= nil and state.account.projects.layouts[sel] ~= nil
    end,
})

-- Stats string for the right detail panel: "Rooms N  Floors N  Budget N/N".
Selectors:Register("projects.layoutDetailStats", {
    reads = { "account.projects.houses", "account.projects.layouts", "account.rooms",
              "session.ui.projects.layoutSelectedVersionID" },
    calls = { "projects.layoutDetail", "projects.placementCaps" },
    fn = function(state, ctx)
        local d = Selectors:Call("projects.layoutDetail", state, ctx)
        if not d.hasSelection then return "" end
        return string.format("Rooms %d  Floors %d  Budget %s",
            d.roomCount, d.floorCount, d.budgetText)
    end,
})

-- ===== Help workspace (the workflow cycle diagram) ==========================
-- helpStage drives both the diagram's selected card and the detail copy.
-- Locale:Get is an in-memory table read (static data, enUS fallback) -- the
-- locale switch path force-refreshes "*" so these re-evaluate (HDGR_Locale).

Selectors:Register("projects.helpModel", {
    reads = { "session.ui.projects.helpStage" },
    fn = function(state)
        return { stage = state.session.ui.projects.helpStage }
    end,
})

Selectors:Register("projects.helpStageTitle", {
    reads = { "session.ui.projects.helpStage" },
    fn = function(state)
        return HDG.Locale:Get("PROJ_HELP_S" .. state.session.ui.projects.helpStage .. "_TITLE")
    end,
})

Selectors:Register("projects.helpStageBody", {
    reads = { "session.ui.projects.helpStage" },
    fn = function(state)
        return HDG.Locale:Get("PROJ_HELP_S" .. state.session.ui.projects.helpStage .. "_BODY")
    end,
})
