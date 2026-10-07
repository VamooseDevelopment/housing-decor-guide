-- HDG.Selectors -- HouseEditor Companion
-- ============================================================================
-- Selectors for the companion window content. Six display modes:
--   styles      -- user-created style + smartset collections
--   shopping    -- shopping list collections
--   snapshots   -- "Placed" tab: live area-scoped placed decor + saved snapshots
--   themes      -- pre-authored Room Concepts (StyleDefinitions, tier="thematic")
--   collections -- pre-authored Useful Collections (CollectionDefinitions)
--   recent      -- live placed decor (session.styles.placedDecor)
--
-- Sidebar = collections matching current mode (or recent items flat for "recent").
-- Selecting a sidebar row sets session.ui.companion.selectedItemID.
-- Grid = items in the selected collection (or placedDecor map for "recent").
--
-- Reuses existing data sources (Styles/Collections StaticData, account.collections,
-- session.styles.placedDecor) -- companion is a different view onto Styles-tab data.

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors

-- ============================================================================
-- Bare-path selectors (chrome state for binding / repaint subscriptions)
-- ============================================================================

Selectors:Register("companion.windowShown", {
    reads = {"session.ui.companion.windowShown"},
    fn = function(state) return state.session.ui.companion.windowShown == true end,
})

Selectors:Register("companion.mode", {
    reads = {"session.ui.companion.mode"},
    fn = function(state) return state.session.ui.companion.mode end,
})

Selectors:Register("companion.search", {
    reads = {"session.ui.companion.search"},
    fn = function(state) return state.session.ui.companion.search end,
})

Selectors:Register("companion.selectedItemID", {
    reads = {"session.ui.companion.selectedItemID"},
    fn = function(state) return state.session.ui.companion.selectedItemID end,
})

-- Persistent window position: { x, y }, either field may be nil (-> default anchor).
-- Frame restore-on-show reads this; OnDragStop dispatches COMPANION_SET_POSITION.
Selectors:Register("companion.windowPosition", {
    reads = {"account.ui.companion.window"},
    fn = function(state) return state.account.ui.companion.window end,
})

-- Cost-badge visibility toggle (header chip active-state + grid cell stamp).
Selectors:DefinePath("companion.showCost", "session.ui.companion.showCost")

-- Indoor/Outdoor 3-state filter label (header button text binding).
local IO_LABELS = { all = "Indoor + Outdoor", indoor = "Indoor only", outdoor = "Outdoor only" }
Selectors:Register("companion.ioLabel", {
    reads = {"session.ui.companion.ioFilter"},
    fn = function(state) return IO_LABELS[state.session.ui.companion.ioFilter] end,
})

-- Per-mode active-state selectors for the mode chip strip (companion.isMode_<key>).
Selectors:DefineEnum("companion.isMode", "session.ui.companion.mode",
    { "styles", "rooms", "snapshots", "themes", "collections", "recent" })

-- ============================================================================
-- Mode -> collection-type mapping
-- ============================================================================

local MODE_TO_TYPES = {
    styles      = { style = true, smartset = true },   -- user-created styles + smart sets
    -- "rooms" handled separately -- sourced from account.rooms, not collections
    snapshots   = { snapshot = true },
    themes      = { concept = true },                  -- pre-authored Room Concepts
    collections = { collection = true },               -- pre-authored Useful Collections
    -- "recent" handled separately -- not a collection-type filter
}

local function iterAllCollectionsForCompanion(state)
    local out = {}
    -- User collections (account.collections)
    for id, def in pairs(state.account.collections) do
        local colonAt = id:find(":")
        local t = colonAt and id:sub(1, colonAt - 1) or "style"
        if def.type and def.type ~= "" then t = def.type end
        out[#out + 1] = { id = id, type = t, def = def }
    end
    -- Pre-authored Room Concepts
    local sd = HDG.StaticData.Styles:GetDefinitions()
    if type(sd) == "table" then
        for sid, def in pairs(sd) do
                    -- Runtime type: "concept" or "collection". Data-level `tier` is the
            -- semantic subcategory; runtime type drives the filter enum + LandingSection.
            local t = (def.tier == "collection") and "collection" or "concept"
            out[#out + 1] = { id = "concept:" .. sid, type = t, def = def }
        end
    end
    -- Pre-authored Useful Collections
    local cd = HDG.StaticData.Collections:GetDefinitions()
    if type(cd) == "table" then
        for cid, def in pairs(cd) do
            out[#out + 1] = { id = "collection:" .. cid, type = "collection", def = def }
        end
    end
    return out
end

-- ============================================================================
-- Placement-cost buckets ("By Placement Cost" mode).
-- ~99% of decor sits at 1/3/5; cost 6+ is structural room pieces.
-- Declared above sidebarRows + gridItems (both read it).
-- ============================================================================

local PLACEMENT_COST_BUCKETS = {
    { id = "placementcost:small",  text = "Small (1-2)",  lo = 1, hi = 2  },
    { id = "placementcost:medium", text = "Medium (3-4)", lo = 3, hi = 4  },
    { id = "placementcost:large",  text = "Large (5)",    lo = 5, hi = 5  },
    { id = "placementcost:xlarge", text = "X-Large (6+)", lo = 6, hi = 99 },
}
local PLACEMENT_COST_BUCKET_BY_ID = {}
for _, b in ipairs(PLACEMENT_COST_BUCKETS) do PLACEMENT_COST_BUCKET_BY_ID[b.id] = b end

-- Special (resolver-based) collections pinned to the TOP of the Collections sidebar
-- in this order, with a divider after. Mirrors HDG's collection order.
local SPECIAL_COLLECTION_ORDER = {
    ["collection:recently-learned"] = 1,
    ["collection:dyeable"]          = 2,
    ["collection:trophies"]         = 3,
    ["collection:neighborhood"]     = 4,
}

-- Themes-mode sidebar: concepts grouped by tier into "Room Concepts / Themed / Faction" sections.
local TIER_SECTIONS = {
    { tier = "thematic", label = "Room Concepts" },
    { tier = "themed",   label = "Themed" },
    { tier = "faction",  label = "Faction" },
}

-- Group concept rows by def.tier into header-prefixed sections. Untiered rows
-- fall under "Room Concepts". Each section + its rows alpha-sorted. Rows already
-- carry isSelected (stamped by the caller), so no selection arg needed here.
local function _sectionByTier(matches)
    local byTier = {}
    for _, m in ipairs(matches) do
        local t = m.tier or "thematic"
        byTier[t] = byTier[t] or {}
        byTier[t][#byTier[t] + 1] = m
    end
    local out = {}
    for _, sec in ipairs(TIER_SECTIONS) do
        local group = byTier[sec.tier]
        if group and #group > 0 then
            table.sort(group, function(a, b)
                return tostring(a.displayName):lower() < tostring(b.displayName):lower()
            end)
            out[#out + 1] = { isHeader = true, displayName = sec.label }
            for _, m in ipairs(group) do out[#out + 1] = m end
        end
    end
    return out
end

-- Owned-item count per cost bucket (one catalog walk; mirrors the grid's owned-only filter).
-- sweepGeneration in the consuming selector's reads refreshes counts on each sweep.
local function _bucketCounts()
    local counts = {}
    for _, b in ipairs(PLACEMENT_COST_BUCKETS) do counts[b.id] = 0 end
    if not HDG.HousingCatalogObserver:IsReady() then return counts end
    HDG.HousingCatalogObserver:IterateRows(function(_, row)
        local cost = row.placementCost
        if cost and HDG.HousingCatalogObserver:IsOwned(row) then
            for _, b in ipairs(PLACEMENT_COST_BUCKETS) do
                if cost >= b.lo and cost <= b.hi then
                    counts[b.id] = counts[b.id] + 1
                    break
                end
            end
        end
    end)
    return counts
end

-- ============================================================================
-- Sidebar rows for the current mode.
-- ============================================================================

-- Walk a room's effective furnishing items (across its equipped sets). A set
-- can be deleted out from under the room while the ID lingers (nullable).
-- Shared by the sidebar room-count and the grid room-card builders.
local function _forEachRoomEffectiveItem(state, room, fn)
    for _, sid in ipairs(room.furnishingSetIDs) do
        local set = state.account.furnishingSets[sid]
        if set then   -- exception(nullable): set deleted out from under the room
            for _, it in ipairs(set.items) do fn(it) end
        end
    end
end

local function _alphaByDisplayName(a, b)
    return tostring(a.displayName):lower() < tostring(b.displayName):lower()
end

-- Recent-mode sidebar = persisted edit-session history. Raw session rows; time
-- labels formatted at paint (time() is impure, can't live in a selector).
local function _sidebarRecentRows(state, selected)
    local sessions = HDG.Selectors:Call("companion.recentSessions", state, {})
    local out = {}
    for i, s in ipairs(sessions) do
        out[#out + 1] = {
            id              = s.id,
            isRecentSession = true,
            startedAt       = s.startedAt,
            endedAt         = s.endedAt,
            eventCount      = s.eventCount,
            isActive        = s.isActive,
            isSelected      = (selected == s.id) or (selected == nil and i == 1),
        }
    end
    return out
end

-- One row per persistent Furnishings room; count = effective decor total across
-- its equipped sets + own pieces. Blueprint tile from the live room catalog.
local function _sidebarRoomRows(state, needle, selected)
    local cat = state.session.house.roomCatalog.byShapeID
    local out = {}
    for rid, room in pairs(state.account.rooms) do
        local name = (room.name and room.name ~= "" and room.name)
            or (room.shape and HDG.Projects.ShapeAtlas.GetLabel(room.shape)) or "Room"
        if not needle or name:lower():find(needle, 1, true) then
            local n = 0
            _forEachRoomEffectiveItem(state, room, function(it) n = n + (it.count or 1) end)
            local e = room.shape and cat[room.shape]   -- exception(nullable): shapeless rooms have no tile
            out[#out + 1] = {
                id          = rid,
                type        = "room",
                displayName = name,
                count       = n,
                iconAtlas   = (e and e.iconAtlas)
                    or (room.shape and HDG.Projects.ShapeAtlas.GetAtlas(room.shape)) or nil,
                isSelected  = selected == rid,
            }
        end
    end
    table.sort(out, function(a, b)
        local an, bn = tostring(a.displayName):lower(), tostring(b.displayName):lower()
        if an ~= bn then return an < bn end
        return a.id < b.id
    end)
    return out
end

-- Collections mode: special (resolver-based) collections pinned to the top in a
-- fixed order, a divider, the rest alphabetically, then the placement-cost
-- sub-section (one catalog walk for all four owned counts).
local function _sidebarCollectionsMode(matches, selected)
    local specials, rest = {}, {}
    for _, m in ipairs(matches) do
        if SPECIAL_COLLECTION_ORDER[m.id] then specials[#specials + 1] = m
        else rest[#rest + 1] = m end
    end
    table.sort(specials, function(a, b)
        return SPECIAL_COLLECTION_ORDER[a.id] < SPECIAL_COLLECTION_ORDER[b.id]
    end)
    table.sort(rest, _alphaByDisplayName)
    local out = {}
    for _, m in ipairs(specials) do out[#out + 1] = m end
    if #specials > 0 and #rest > 0 then
        out[#out + 1] = { isDivider = true, id = "specials" }
    end
    for _, m in ipairs(rest) do out[#out + 1] = m end

    out[#out + 1] = { isHeader = true, displayName = "By Placement Cost" }
    local counts = _bucketCounts()
    for _, b in ipairs(PLACEMENT_COST_BUCKETS) do
        out[#out + 1] = {
            id          = b.id,
            type        = "placementcost",
            displayName = b.text,
            count       = counts[b.id],
            isSelected  = selected == b.id,
        }
    end
    return out
end

-- Membership modes (themes / collections / other): name-filtered defs. count
-- only for explicit membership defs (.items); rule-based concepts leave it nil.
-- Synthetic sidebar id for the live list. Not a collection -- it has no account
-- entry, is never persisted, and is rebuilt from the burst every session.
local PLACED_LIVE_ID = "placed:live"

-- Decor in the area the player is standing in -- an AREA is indoors vs outdoors,
-- NOT a single room, so every interior room shares one list. From the
-- CUSTOMIZATION_CHANGED burst the HousingObserver already collects; matching
-- Blizzard's own Placed Decor panel, which is scoped the same way.
local function _placedInCurrentArea(state)
    local area = state.session.styles.currentArea
    local out = {}
    if not area then return out end                 -- exception(nullable): no burst seen yet this session
    for _, entry in pairs(state.session.styles.placedDecor) do
        if entry.areaID == area then out[#out + 1] = entry end
    end
    return out
end

-- Sidebar rows for every collection of the mode's types, name-filtered when a
-- needle is given. Passing needle = nil is what lets the grouped styles path
-- count FULL membership on a group row while showing only the matches under it,
-- off the same builder -- there is no second row shape.
local function _collectionMatches(state, typeSet, needle, selected)
    local matches = {}
    for _, entry in ipairs(iterAllCollectionsForCompanion(state)) do
        if typeSet[entry.type] then
            local def  = entry.def
            local name = (def and (def.displayName or def.name)) or entry.id
            if not needle or tostring(name):lower():find(needle, 1, true) then
                matches[#matches + 1] = {
                    id          = entry.id,
                    type        = entry.type,
                    tier        = def and def.tier,
                    displayName = name,
                    subtitle    = def and def.description or nil,
                    count       = (def and type(def.items) == "table") and #def.items or nil,
                    isSelected  = selected == entry.id,
                }
            end
        end
    end
    return matches
end

-- ===== Your Styles groups (spec HDGR_STYLE_CATEGORIES_SPEC_2026-09-04 s4.1) =====
-- Same grouping rules as the Browse list, its own fold set. Group rows carry no
-- id / type / isSelected, so companion.gridItems can never be handed one.

-- Name (case-insensitive) then seq -- a total order even after a rename has made
-- two categories share a name. Same comparator as Browse's _sortedStyleCategories;
-- deliberately re-stated rather than shared, so neither file's sort can drift the
-- other's list out from under it.
local function _sortedCompanionCategories(cats)
    local out = {}
    for _, cat in pairs(cats) do out[#out + 1] = cat end
    table.sort(out, function(a, b)
        local an, bn = a.name:lower(), b.name:lower()
        if an ~= bn then return an < bn end
        return a.seq < b.seq
    end)
    return out
end

-- Split styles-mode rows into the loose fold, one bucket per registered category,
-- and the smart sets. Buckets are seeded from the registry, so a categoryID that
-- is not a key of it is "not a category any more" -> loose. That is the answer,
-- not a guard. Styles-mode rows are always account.collections records (the two
-- static sources type as concept/collection), so the record read is strict.
local function _bucketStyleRows(rows, cats, collections)
    local byCat, loose, smart = {}, {}, {}
    for id in pairs(cats) do byCat[id] = {} end
    for _, row in ipairs(rows) do
        if row.type == "smartset" then
            smart[#smart + 1] = row
        else
            local bucket = byCat[collections[row.id].categoryID]
            if bucket then bucket[#bucket + 1] = row else loose[#loose + 1] = row end
        end
    end
    return byCat, loose, smart
end

-- One group row plus, when open, its members. A needle filters the members,
-- force-opens the group and drops a group with no match entirely; count stays
-- full membership so the row reads "1 of 4", not "1 of 1". displayName is nil for
-- the two literal groups -- the painter resolves those from Locale.
local function _emitSidebarGroup(out, groupKey, displayName, members, collapsed, needle)
    local shown, matchCount = members, nil
    if needle then
        shown = {}
        for _, m in ipairs(members) do
            if tostring(m.displayName):lower():find(needle, 1, true) then shown[#shown + 1] = m end
        end
        if #shown == 0 then return end
        matchCount = #shown
    end
    local forcedOpen  = needle ~= nil
    local collapsedNow = collapsed and not forcedOpen
    out[#out + 1] = {
        isHeader   = true,
        isGroup    = true,
        groupKey   = groupKey,
        displayName = displayName,
        count      = #members,
        matchCount = matchCount,
        collapsed  = collapsedNow,
        forcedOpen = forcedOpen,
    }
    if collapsedNow then return end
    for _, m in ipairs(shown) do out[#out + 1] = m end
end

-- Loose fold, then categories by name, then the smart sets. The loose fold and
-- the smart-set group are omitted when empty (they name a leftover, not a thing
-- the user made); an empty CATEGORY still shows, or the user could not see the
-- category they just created.
local function _groupStyleRows(state, typeSet, needle, selected)
    local rows = _collectionMatches(state, typeSet, nil, selected)
    table.sort(rows, _alphaByDisplayName)
    local cats  = state.account.styleCategories
    local folds = state.account.ui.companion.collapsedGroups
    local byCat, loose, smart = _bucketStyleRows(rows, cats, state.account.collections)
    local out = {}
    if #loose > 0 then
        _emitSidebarGroup(out, "loose", nil, loose, folds["loose"] == true, needle)
    end
    for _, cat in ipairs(_sortedCompanionCategories(cats)) do
        _emitSidebarGroup(out, cat.id, cat.name, byCat[cat.id], folds[cat.id] == true, needle)
    end
    if #smart > 0 then
        _emitSidebarGroup(out, "smartsets", nil, smart, folds["smartsets"] == true, needle)
    end
    return out
end

local function _sidebarCollectionRows(state, mode, needle, selected)
    local typeSet = MODE_TO_TYPES[mode] or {}
    -- Zero categories = the flat alphabetical list this sidebar has always been.
    if mode == "styles" and next(state.account.styleCategories) ~= nil then
        return _groupStyleRows(state, typeSet, needle, selected)
    end
    local matches = _collectionMatches(state, typeSet, needle, selected)
    if mode == "themes"      then return _sectionByTier(matches) end          -- Room Concepts / Themed / Faction
    if mode == "collections" then return _sidebarCollectionsMode(matches, selected) end
    table.sort(matches, _alphaByDisplayName)
    -- The Placed tab leads with the live list, ABOVE the saved snapshots -- built
    -- after the sort so it stays pinned instead of landing alphabetically among
    -- them. Not search-filtered either: hiding the only live row because the search
    -- box happens not to match its title would read as a bug.
    if mode == "snapshots" then
        table.insert(matches, 1, {
            id          = PLACED_LIVE_ID,
            type        = "placedLive",
            displayName = "Placed Decor",
            subtitle    = "Indoors or outdoors -- live",
            count       = #_placedInCurrentArea(state),
            isSelected  = selected == PLACED_LIVE_ID,
        })
    end
    return matches
end

Selectors:Register("companion.sidebarRows", {
    reads = {
        "session.ui.companion.mode",
        "session.ui.companion.search",
        "session.ui.companion.selectedItemID",
        "account.collections",
        "account.styleCategories",           -- styles-mode sidebar: the groups themselves
        "account.ui.companion.collapsedGroups",   -- ...and this sidebar's own folds
        "account.rooms",                     -- rooms-mode sidebar: one row per room
        "account.furnishingSets",            -- rooms-mode counts
        "session.furn",                      -- rooms-mode change tick
        "session.house.roomCatalog",         -- rooms-mode blueprint tiles
        "session.styles.changeSeq",
        "session.styles.placedDecor",       -- live Placed row count
        "session.styles.currentArea",       -- ...scoped to the current area
        "session.resolvers.staticData.tick",
        "session.resolvers.catalog.tick",   -- cost-bucket owned counts
    },
    calls = { "companion.recentSessions" },  -- recent-mode sidebar (pulls account.recentActivity into the reads-closure)
    fn = function(state)
        local mode     = state.session.ui.companion.mode
        local search   = state.session.ui.companion.search:lower()
        local selected = state.session.ui.companion.selectedItemID
        local needle   = search ~= "" and search or nil
        if mode == "recent" then return _sidebarRecentRows(state, selected) end
        if mode == "rooms"  then return _sidebarRoomRows(state, needle, selected) end
        return _sidebarCollectionRows(state, mode, needle, selected)
    end,
})

-- ============================================================================
-- Grid items for the selected collection (or session events for recent mode).
-- Collection resolution uses HDG.StyleResolve.ItemsFor (shared with Styles tab)
-- so rule-based collections populate too.
-- ============================================================================

-- Emit placement-ready grid cells for one catalog item: base (undyed) + one cell
-- per owned dyed variant. Each cell carries the placement payload (entryID,
-- ownedQty, allowIndoors/allowOutdoors, placementCost, isUniqueTrophy).
-- Dye split: row.quantity is aggregate across variants (12.0.5 catalog API);
-- base undyed = aggregate - sum(dyed numStored). row nil = boundary (catalog not swept).
local function _emitDecorCells(out, itemID, row, needle, ioFilter)
    -- Indoor/Outdoor filter (3-state): skip rows the current filter excludes.
    -- "indoor" keeps indoor-placeable items; "outdoor" keeps outdoor-placeable.
    if row then
        if ioFilter == "indoor"  and row.isAllowedIndoors  == false then return end
        if ioFilter == "outdoor" and row.isAllowedOutdoors == false then return end
    end
    local name = (row and row.name) or ("Item " .. tostring(itemID))
    if needle and not name:lower():find(needle, 1, true) then return end
    local iconTex, iconAtl = HDG.Format.CoerceIconPair(
        row and row.iconTexture, row and row.iconAtlas)
    if not row then
        out[#out + 1] = {
            itemID = itemID, name = name,
            iconTexture = iconTex, iconAtlas = iconAtl,
            isOwned = false, ownedQty = 0,
        }
        return
    end
    local dyed = row.dyedVariants or {}
    local dyedStored = 0
    for _, dv in ipairs(dyed) do dyedStored = dyedStored + (dv.numStored or 0) end
    local baseQty = #dyed > 0 and math.max(0, (row.quantity or 0) - dyedStored)  -- exception(boundary): catalog struct field sparse
                                or (row.quantity or 0)  -- exception(boundary): catalog struct field sparse
    out[#out + 1] = {
        itemID         = itemID,
        name           = #dyed > 0 and (name .. " (Undyed)") or name,
        iconTexture    = iconTex,
        iconAtlas      = iconAtl,
        isOwned        = row.isOwned == true,
        entryID        = row.entryID,
        ownedQty       = baseQty,
        numPlaced      = row.numPlaced,   -- aggregate placed (tooltip "Placed:"); per-variant not exposed
        allowIndoors   = row.isAllowedIndoors,
        allowOutdoors  = row.isAllowedOutdoors,
        placementCost  = row.placementCost,
        isUniqueTrophy = row.isUniqueTrophy == true,
    }
    for _, dv in ipairs(dyed) do
        out[#out + 1] = {
            itemID         = itemID,
            name           = name .. " (" .. (dv.label or "Dyed") .. ")",
            iconTexture    = iconTex,
            iconAtlas      = iconAtl,
            isOwned        = true,
            entryID        = dv.entryID,
            ownedQty       = dv.numStored or 0,
            allowIndoors   = row.isAllowedIndoors,
            allowOutdoors  = row.isAllowedOutdoors,
            placementCost  = row.placementCost,
            isUniqueTrophy = row.isUniqueTrophy == true,
        }
    end
end

-- Stamp the cost-badge toggle onto every grid cell so the factory paints badges
-- as a pure function of ed. gridItems reads session.ui.companion.showCost, so
-- COMPANION_TOGGLE_COST re-pushes the grid and badges flip.
local function _stampShowCost(out, showCost)
    for _, ed in ipairs(out) do ed.showCost = showCost end
    return out
end

-- Recent-mode grid: per-item placed/removed event groups of the selected
-- session (selectedItemID = sessionID; defaults to newest). Cells carry the
-- placement payload so recent items can be re-placed on click.
local function _gridRecentItems(state, needle)
    local out = {}
    local ra    = state.account.recentActivity
    local house = ra.lastHouseKey and ra.houses[ra.lastHouseKey]
    if not house then return out end
    local sid = state.session.ui.companion.selectedItemID
    if type(sid) ~= "number" or not house.sessions[sid] then
        sid = house.sessionOrder[1]
    end
    local session = sid and house.sessions[sid]
    if not session then return out end

    local groups = {}
    for _, ev in pairs(session.events) do groups[#groups + 1] = ev end
    table.sort(groups, function(a, b) return (a.lastTs or 0) > (b.lastTs or 0) end)

    for _, ev in ipairs(groups) do
        local row  = HDG.HousingCatalogObserver:GetRow(ev.itemID)
        local name = (row and row.name) or ("Item " .. tostring(ev.itemID))
        if not needle or name:lower():find(needle, 1, true) then
            local iconTex, iconAtl = HDG.Format.CoerceIconPair(
                row and row.iconTexture, row and row.iconAtlas)
            out[#out + 1] = {
                itemID         = ev.itemID,
                name           = name,
                iconTexture    = iconTex,
                iconAtlas      = iconAtl,
                isOwned        = row and row.isOwned == true,
                placedCount    = ev.placed,
                removedCount   = ev.removed,
                -- exception(boundary): row nil for unswept items -> entryID nil -> click no-ops
                entryID        = row and row.entryID,
                ownedQty       = row and row.quantity,
                numPlaced      = row and row.numPlaced,
                allowIndoors   = row and row.isAllowedIndoors,
                allowOutdoors  = row and row.isAllowedOutdoors,
                placementCost  = row and row.placementCost,
                isUniqueTrophy = row and row.isUniqueTrophy == true,
            }
        end
    end
    return out
end

-- Rooms-mode grid: selected room's EFFECTIVE furnishings (equipped sets + own
-- pieces) as placement cards -- place straight from your plan.
local function _gridRoomItems(state, room, needle, ioFilter)
    local out, seen = {}, {}
    _forEachRoomEffectiveItem(state, room, function(it)
        if not seen[it.id] then
            seen[it.id] = true
            local row = HDG.HousingCatalogObserver:GetRow(it.id)
            _emitDecorCells(out, it.id, row, needle, ioFilter)
        end
    end)
    return out
end

-- Cost-bucket grid: walk the catalog for owned decor in [lo,hi]. IterateRows
-- reads the observer's baked cache (freshness via sweepGeneration).
local function _gridBucketItems(bucket, needle, ioFilter)
    local out = {}
    HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
        local cost = row.placementCost or 0  -- exception(boundary): catalog struct field sparse
        if cost >= bucket.lo and cost <= bucket.hi
           and HDG.HousingCatalogObserver:IsOwned(row) then
            _emitDecorCells(out, itemID, row, needle, ioFilter)
        end
    end)
    table.sort(out, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return out
end

-- Membership/rule-based grid: resolved through StyleResolve.ItemsFor so
-- smartsets, concepts, and name-pattern Useful Collections all populate.
local function _gridCollectionItems(state, needle, ioFilter)
    local out = {}
    local itemIDs = HDG.StyleResolve.ItemsFor(
        state.session.ui.companion.selectedItemID, state)
    for _, itemID in ipairs(itemIDs) do
        local row = HDG.HousingCatalogObserver:GetRow(itemID)
        _emitDecorCells(out, itemID, row, needle, ioFilter)
    end
    return out
end

-- Observer is primary source for name/icon/isOwned + placement payload.
-- Cost-bucket mode walks the whole catalog via IterateRows (tied to sweepGeneration).
-- One cell per placed instance, collapsed to one cell per item with a count --
-- individual instances aren't actionable (SetPlacedDecorEntrySelected carries
-- HasRestrictions, so only Blizzard's own rows may select decor), so a per-instance
-- cell would offer nothing a count doesn't. Search filters on name.
-- Resolve decorID -> itemID HERE rather than trusting entry.itemID. The observer
-- resolves it during the burst, which can land BEFORE the catalog sweep -- a nil
-- frozen into state then survives every later sweep, because state is stored, not
-- re-derived, and the icons stay as "?" forever. Deriving in the selector means the
-- declared read on session.resolvers.catalog.tick actually repairs them on sweep.
local function _resolvePlacedItemID(entry)
    local row = HDG.HousingCatalogObserver.byDecorID[entry.decorID]  -- exception(nullable): catalog may not have swept yet
    return (row and row.itemID) or entry.itemID
end

local function _gridPlacedLiveItems(state, needle, ioFilter)
    local byItem = {}
    for _, entry in ipairs(_placedInCurrentArea(state)) do
        local itemID = _resolvePlacedItemID(entry)
        local key = itemID or entry.decorID
        local cell = byItem[key]
        if cell then
            cell.placedCount = cell.placedCount + 1
        else
            byItem[key] = { itemID = itemID, decorID = entry.decorID,
                            name = entry.name, placedCount = 1 }
        end
    end
    local out = {}
    for _, cell in pairs(byItem) do
        -- Only emit cells the catalog can name. Passing a decorID where an itemID
        -- is expected is what renders the red "?" placeholder; an unresolved cell
        -- reappears on the next sweep because this selector re-derives on the tick.
        local row = cell.itemID and HDG.HousingCatalogObserver:GetRow(cell.itemID)  -- exception(nullable): catalog may not have swept yet
        if row then
            -- _emitDecorCells emits 0..N cells (nothing when the search/IO filter
            -- excludes it; base + one per dyed variant otherwise), so stamp the
            -- range it actually appended rather than assuming out[#out] is ours.
            local before = #out
            _emitDecorCells(out, cell.itemID, row, needle, ioFilter)
            for i = before + 1, #out do
                out[i].placedCount = cell.placedCount
                -- This list is a read-out of what is ALREADY down, not a shop.
                -- Dropping entryID reuses the cell click handler's existing
                -- non-placeable path (`if not entryID then return end`) instead of
                -- adding a branch, and drops "Place" from the tooltip for free.
                out[i].entryID = nil
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

Selectors:Register("companion.gridItems", {
    reads = {
        "session.ui.companion.mode",
        "session.styles.placedDecor",   -- live Placed list
        "session.styles.currentArea",   -- ...scoped to the area (indoors/outdoors)
        "session.ui.companion.selectedItemID",
        "session.ui.companion.search",
        "session.ui.companion.ioFilter",
        "session.ui.companion.showCost",    -- cell cost-badge gate (stamped per cell)
        "account.recentActivity",
        "account.collections",
        "account.rooms",                    -- rooms-mode grid: the selected room
        "account.furnishingSets",           -- rooms-mode grid: its effective furnishings
        "session.styles.changeSeq",
        "session.resolvers.staticData.tick",          -- StyleResolve reads pre-authored defs
        "session.resolvers.catalog.tick",
    },
    fn = function(state)
        local mode     = state.session.ui.companion.mode
        local search   = state.session.ui.companion.search:lower()
        local needle   = search ~= "" and search or nil
        local ioFilter = state.session.ui.companion.ioFilter
        local showCost = state.session.ui.companion.showCost

        local out
        if state.session.ui.companion.selectedItemID == PLACED_LIVE_ID then
            out = _gridPlacedLiveItems(state, needle, ioFilter)
        elseif mode == "recent" then
            out = _gridRecentItems(state, needle)
        elseif mode == "rooms" then
            local room = state.account.rooms[state.session.ui.companion.selectedItemID or ""]   -- exception(nullable): nothing selected yet
            out = room and _gridRoomItems(state, room, needle, ioFilter) or {}
        else
            -- Bucket checked before collection resolution: a bucket id resolves to no collection.
            local bucket = PLACEMENT_COST_BUCKET_BY_ID[state.session.ui.companion.selectedItemID]
            out = bucket and _gridBucketItems(bucket, needle, ioFilter)
                          or _gridCollectionItems(state, needle, ioFilter)
        end
        return _stampShowCost(out, showCost)
    end,
})

-- ============================================================================
-- Bottom strip: most-recently-placed items, newest first (all modes).
-- Horizontal filmstrip, capped at 20. Cells are re-placeable (observer-keyed).
-- ============================================================================
Selectors:Register("companion.recentStrip", {
    reads = {
        "session.styles.placedDecor",
        "session.styles.changeSeq",
        "session.resolvers.catalog.tick",
        "session.ui.companion.showCost",   -- re-placeable cells -> cost badge respects the toggle
        "account.recentActivity",          -- this-session placed/removed -> +/- corner badges
    },
    fn = function(state)
        -- Per-ACTION feed: 1 card = 1 place/remove action, newest first, one direction only.
        -- Built from session.actions (NOT the per-item events aggregate which conflates
        -- place+remove into a single cell). Cells are re-placeable via catalog entryID.
        local ra      = state.account.recentActivity   -- factory-seeded: strict read
        local house   = ra.lastHouseKey and ra.houses[ra.lastHouseKey]
        local sess    = house and house.sessionOrder[1] and house.sessions[house.sessionOrder[1]]
        local actions = (sess and sess.actions) or {}   -- exception(boundary): pre-existing sessions lack actions

        local out = {}
        for i = 1, math.min(20, #actions) do
            local a   = actions[i]   -- { itemID, kind, ts }, newest first
            local row = HDG.HousingCatalogObserver:GetRow(a.itemID)
            local name = (row and row.name) or ("Item " .. tostring(a.itemID))
            local iconTex, iconAtl = HDG.Format.CoerceIconPair(
                row and row.iconTexture, row and row.iconAtlas)
            out[i] = {
                itemID         = a.itemID,
                name           = name,
                iconTexture    = iconTex,
                iconAtlas      = iconAtl,
                isActionStrip  = true,   -- per-action feed: hide qty badge, +/- direction only
                -- exception(boundary): row nil for unswept items -> entryID nil -> click no-ops
                isOwned        = row and row.isOwned == true,
                entryID        = row and row.entryID,
                ownedQty       = row and row.quantity,
                numPlaced      = row and row.numPlaced,
                -- ONE direction per action (+/- corner icon), not a count.
                placedCount    = (a.kind == "placed")  and 1 or 0,
                removedCount   = (a.kind == "removed") and 1 or 0,
                allowIndoors   = row and row.isAllowedIndoors,
                allowOutdoors  = row and row.isAllowedOutdoors,
                placementCost  = row and row.placementCost,
                isUniqueTrophy = row and row.isUniqueTrophy == true,
            }
        end
        return _stampShowCost(out, state.session.ui.companion.showCost)
    end,
})

-- ============================================================================
-- Recent mode sidebar: edit-session history for the active house, newest first.
-- Returns raw session data; time labels formatted by the module (time() is impure).
-- ============================================================================

Selectors:Register("companion.recentSessions", {
    reads = { "account.recentActivity" },
    fn = function(state)
        local ra    = state.account.recentActivity
        local house = ra.lastHouseKey and ra.houses[ra.lastHouseKey]
        if not house then return {} end
        local newestID = house.sessionOrder[1]
        local out = {}
        for _, sid in ipairs(house.sessionOrder) do
            local s = house.sessions[sid]
            if s then
                out[#out + 1] = {
                    id         = sid,
                    startedAt  = s.startedAt,
                    endedAt    = s.endedAt,
                    eventCount = s.eventCount or 0,
                    isActive   = (sid == newestID) and not s.endedAt,
                }
            end
        end
        return out
    end,
})

-- ============================================================================
-- Header label per mode (for the companion window title bar).
-- ============================================================================

local MODE_LABELS = {
    styles       = "Your Styles",
    rooms        = "My Rooms",
    snapshots    = "Snapshots",
    themes       = "Room Concepts",
    collections  = "Useful Collections",
    recent       = "Recent Placements",
}

Selectors:Register("companion.headerLabel", {
    reads = {"session.ui.companion.mode"},
    fn = function(state)
        return MODE_LABELS[state.session.ui.companion.mode]
    end,
})
