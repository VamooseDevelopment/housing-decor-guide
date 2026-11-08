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
-- Layout (Blizzard catalog shape, 2026-11-07): a mode rail, a full-width decor
-- grid, and the mode's lists in a picker on the grid heading.
-- Picker rows = companion.sidebarRows (collections matching the current mode,
-- or recent sessions for "recent"). Picking one sets
-- session.ui.companion.selectedItemID; the grid shows that list's decor.
-- Tile size + column count are saved per account and size the window.
--
-- Reuses existing data sources (Styles/Collections StaticData, account.collections,
-- session.styles.placedDecor) -- companion is a different view onto Styles-tab data.

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors
local COMP = HDG.Constants.COMPANION

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
Selectors:DefinePath("companion.showCost", "account.ui.companion.showCost")

-- Per-mode active-state selectors for the mode rail (companion.isMode_<key>).
Selectors:DefineEnum("companion.isMode", "session.ui.companion.mode",
    { "catalog", "styles", "rooms", "snapshots", "themes", "collections", "recent" })

Selectors:DefinePath("companion.pickerOpen", "session.ui.companion.pickerOpen")

-- ============================================================================
-- Tile size + columns (search-row steppers) and the window width they set
-- ============================================================================

Selectors:DefinePath("companion.tileSize", "account.ui.companion.tileSize")

local function _tileSizeIndex(size)
    for i, s in ipairs(COMP.TILE_SIZES) do
        if s == size then return i end
    end
    error(("companion: unknown tile size %q"):format(tostring(size)))
end

Selectors:Register("companion.tilePx", {
    reads = {"account.ui.companion.tileSize"},
    fn = function(state) return COMP.TILE_PX[state.account.ui.companion.tileSize] end,
})

Selectors:Register("companion.columns", {
    reads = {"account.ui.companion.columns"},
    fn = function(state) return state.account.ui.companion.columns end,
})

Selectors:Register("companion.columnsText", {
    reads = {"account.ui.companion.columns"},
    fn = function(state) return tostring(state.account.ui.companion.columns) end,
})

-- Stepper arrows: lit while a step is possible, dimmed at either end.
Selectors:Register("companion.canShrinkTile", {
    reads = {"account.ui.companion.tileSize"},
    fn = function(state) return _tileSizeIndex(state.account.ui.companion.tileSize) > 1 end,
})
Selectors:Register("companion.canGrowTile", {
    reads = {"account.ui.companion.tileSize"},
    fn = function(state) return _tileSizeIndex(state.account.ui.companion.tileSize) < #COMP.TILE_SIZES end,
})
Selectors:Register("companion.canFewerColumns", {
    reads = {"account.ui.companion.columns"},
    fn = function(state) return state.account.ui.companion.columns > COMP.COLUMNS_MIN end,
})
Selectors:Register("companion.canMoreColumns", {
    reads = {"account.ui.companion.columns"},
    fn = function(state) return state.account.ui.companion.columns < COMP.COLUMNS_MAX end,
})

-- The view's one column track. The grid well holds exactly `columns` tiles:
-- tiles + gaps + the scrollbar reserve + slack against UI-scale rounding (the
-- same sum the old fixed 309px well used: 5 x 60 + 6 + 3). Beside it sit the
-- rail, the split gap and the body padding (LayoutConfig: companion.body
-- padding "md", companion.split gap "sm"). Never narrower than Blizzard's own
-- storage frame (415 wide incl. the window's "sm" padding); a smaller grid
-- sits centred in the wider well (cardGrid `columns` binding).
Selectors:Register("companion.viewColumns", {
    reads = {"account.ui.companion.tileSize", "account.ui.companion.columns"},
    fn = function(state)
        local ui    = state.account.ui.companion
        local tile  = COMP.TILE_PX[ui.tileSize]
        local cols  = ui.columns
        local md    = HDG.Theme:GetMetric("spacing.md")
        local sm    = HDG.Theme:GetMetric("spacing.sm")
        local well  = cols * tile + (cols - 1) * COMP.TILE_GAP
                    + HDG.Constants.STYLE.SCROLLBAR_RESERVE + COMP.GRID_SLACK
        local track = 2 * md + COMP.RAIL_WIDTH + sm + well
        return { math.max(COMP.MIN_WIDTH - 2 * sm, track) }
    end,
})

-- ============================================================================
-- Where-you-are chip (header): Inside / Outside + that budget, as Blizzard's
-- own editor header counts it. Replaces the old Indoor + Outdoor filter:
-- 2,880 of 2,888 decor go both places (2026-10-31 dump), so the filter hid
-- almost nothing; what changes with where you stand is the budget you spend.
-- ============================================================================

local BUDGET_ATLAS_INSIDE  = "house-decor-budget-icon"
local BUDGET_ATLAS_OUTSIDE = "house-decor-exteriorbudget-icon"

local function _budgetAtlas(budget)
    return budget.inside and BUDGET_ATLAS_INSIDE or BUDGET_ATLAS_OUTSIDE
end

Selectors:Register("companion.locChip", {
    reads = {"session.house.budget"},
    fn = function(state)
        local b = state.session.house.budget
        local spent = tostring(b.decorSpent)
        if b.decorMax - b.decorSpent < COMP.LOW_BUDGET then
            spent = HDG.Theme:ColorCode("semantic.warning") .. spent .. "|r"
        end
        return ("|A:%s:16:16|a %s  %s %s/ %d|r"):format(_budgetAtlas(b),
            b.inside and "Inside" or "Outside", spent,
            HDG.Theme:ColorCode("text.muted"), b.decorMax)
    end,
})

Selectors:Register("companion.locTooltip", {
    reads = {"session.house.budget"},
    fn = function(state)
        local b = state.session.house.budget
        return {
            title = b.inside and "Inside the house" or "Outside on your plot",
            body  = ("Decor placed here spends the %s budget: %d of %d used, %d left.")
                :format(b.inside and "interior" or "exterior",
                        b.decorSpent, b.decorMax, b.decorMax - b.decorSpent),
        }
    end,
})

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
local PLACED_LIVE_ID   = "placed:live"
local PLACED_LIVE_NAME = "Placed Decor"

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
-- category they just created. openAll ignores the folds (the heading's steps).
local function _groupStyleRows(state, typeSet, needle, selected, openAll)
    local rows = _collectionMatches(state, typeSet, nil, selected)
    table.sort(rows, _alphaByDisplayName)
    local cats  = state.account.styleCategories
    local folds = openAll and {} or state.account.ui.companion.collapsedGroups
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

local function _sidebarCollectionRows(state, mode, needle, selected, openAll)
    local typeSet = MODE_TO_TYPES[mode] or {}
    -- Zero categories = the flat alphabetical list this sidebar has always been.
    if mode == "styles" and next(state.account.styleCategories) ~= nil then
        return _groupStyleRows(state, typeSet, needle, selected, openAll)
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
            displayName = PLACED_LIVE_NAME,
            subtitle    = "Indoors or outdoors -- live",
            count       = #_placedInCurrentArea(state),
            isSelected  = selected == PLACED_LIVE_ID,
        })
    end
    return matches
end

-- ===== Categories (mode "catalog": Blizzard's categories; owner 11-08) =======
-- All, then Blizzard's categories in its order (Featured left out: it is the
-- shop), the one holding the pick opened to its subcategories by Blizzard's
-- rule (more than one). Everything shows, owned or not. A catalog row keeps
-- only its FIRST category / subcategory (observer allocation audit), so decor
-- Blizzard files under two subcategories shows under its first one only.
-- All is built without the tree: the editor can open, and pick the mode's
-- first list, before the observer's category snapshot lands.

local CATALOG_ALL_ID = "bcat:all"

-- The pick as (kind, id): "all", "cat" + category id, "sub" + subcategory id.
-- Catalog's pick is always one of its own ids, or nil before the first pick.
local function _catalogPick(selected)
    if selected == nil then return nil end
    if selected == CATALOG_ALL_ID then return "all" end
    local c = selected:match("^bcat:(%d+)$")
    if c then return "cat", tonumber(c) end
    local sub = selected:match("^bsub:(%d+)$")
    if not sub then error(("companion catalog: %q is not a Catalog list"):format(selected), 2) end
    return "sub", tonumber(sub)
end

-- The category a pick sits in (nil for All, or a subcategory the tree lacks).
local function _catalogFocus(tree, kind, id)
    if kind == "cat" then return id end
    if kind ~= "sub" then return nil end
    local s = tree.subcatByID[id]   -- exception(nullable): the tree can lack a subcategory the pick names
    return s and s.parentCategoryID
end

-- One catalog walk: every decor, per first category, per first subcategory.
local function _catalogCounts()
    local all, byCat, bySub = 0, {}, {}
    HDG.HousingCatalogObserver:IterateRows(function(_, row)
        all = all + 1
        local c, s = row.categoryID, row.subcategoryID
        if c then byCat[c] = (byCat[c] or 0) + 1 end   -- exception(boundary): a catalog row can carry no category
        if s then bySub[s] = (bySub[s] or 0) + 1 end   -- exception(boundary): ...or no subcategory
    end)
    return all, byCat, bySub
end

-- The open category's subcategories (Blizzard's "All <Category>" row dropped:
-- the category row above them is that list).
local function _emitCatalogSubs(out, tree, catID, subID, bySub)
    for _, sr in ipairs(HDG.CategoryNav.BuildSubcategories(tree, catID, subID, false)) do
        if not sr.isAll then
            out[#out + 1] = {
                id          = "bsub:" .. sr.id,
                isCatalog   = true,
                isSub       = true,
                displayName = sr.name,
                iconAtlas   = sr.atlas,
                count       = bySub[sr.id] or 0,
                isSelected  = sr.isActive,
            }
        end
    end
end

-- One category row. hasSubs = it opens to its subcategories (the painter's caret,
-- and a pick that keeps the picker open).
local function _catalogCategoryRow(cr, tree, kind, id, byCat)
    return {
        id          = "bcat:" .. cr.id,
        isCatalog   = true,
        displayName = cr.name,
        iconAtlas   = cr.atlas,
        count       = byCat[cr.id] or 0,
        hasSubs     = HDG.CategoryNav.ShowsSubcategories(tree, cr.id, false),
        isSelected  = kind == "cat" and id == cr.id,
    }
end

-- openAll opens every category (what the heading's prev / next step through).
local function _catalogRows(state, openAll)
    local tree     = state.session.house.categoryTree
    local kind, id = _catalogPick(state.session.ui.companion.selectedItemID)
    local focus    = _catalogFocus(tree, kind, id)
    local subID    = kind == "sub" and id or nil
    local all, byCat, bySub = _catalogCounts()
    local out = {}
    for _, cr in ipairs(HDG.CategoryNav.BuildCategories(tree, focus, subID, false, nil)) do
        if cr.isAll then
            out[#out + 1] = { id = CATALOG_ALL_ID, isCatalog = true, isAll = true,
                              iconAtlas = cr.atlas, count = all, isSelected = kind == "all" }
        elseif cr.id ~= COMP.FEATURED_CATEGORY_ID then
            local row = _catalogCategoryRow(cr, tree, kind, id, byCat)
            row.isOpen = row.hasSubs and (openAll or cr.id == focus)
            out[#out + 1] = row
            if row.isOpen then _emitCatalogSubs(out, tree, cr.id, subID, bySub) end
        end
    end
    return out
end

-- The heading's row: the lit category icon, and the category's name too for a
-- subcategory (the painter joins them). No counts: the heading shows none.
local function _catalogPickedRow(state)
    local selected = state.session.ui.companion.selectedItemID
    local kind, id = _catalogPick(selected)
    if kind == nil then return nil end
    if kind == "all" then
        return { id = CATALOG_ALL_ID, isCatalog = true, isAll = true, iconAtlas = "category-icons_all_active" }
    end
    local tree = state.session.house.categoryTree
    local node = kind == "cat" and tree.byID[id] or tree.subcatByID[id]
    if not node then return nil end   -- exception(nullable): the tree is not in yet, or the category left the catalog
    local cat = kind == "cat" and node or tree.byID[node.parentCategoryID]
    return {
        id          = selected,
        isCatalog   = true,
        displayName = node.name,
        parentName  = kind == "sub" and cat and cat.name or nil,   -- exception(nullable): a subcategory whose category the tree lacks
        iconAtlas   = cat and cat.iconBase and (cat.iconBase .. "_active") or nil,   -- exception(nullable): API icon field is nilable
    }
end

-- The picker's rows for the mode. openAll = every list, folded groups opened
-- (what the heading's prev / next step through); the picker itself keeps the folds.
local function _sidebarRows(state, openAll)
    local mode     = state.session.ui.companion.mode
    local search   = state.session.ui.companion.search:lower()
    local selected = state.session.ui.companion.selectedItemID
    local needle   = search ~= "" and search or nil
    if mode == "catalog" then return _catalogRows(state, openAll) end
    if mode == "recent" then return _sidebarRecentRows(state, selected) end
    if mode == "rooms"  then return _sidebarRoomRows(state, needle, selected) end
    return _sidebarCollectionRows(state, mode, needle, selected, openAll)
end

-- One reads list for both readers of _sidebarRows.
local function _sidebarReads()
    return {
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
        "session.resolvers.catalog.tick",   -- cost-bucket owned counts + Catalog counts
        "session.house.categoryTree",       -- Catalog: Blizzard's categories
    }
end

Selectors:Register("companion.sidebarRows", {
    reads = _sidebarReads(),
    calls = { "companion.recentSessions" },  -- recent-mode sidebar (pulls account.recentActivity into the reads-closure)
    fn = function(state) return _sidebarRows(state, false) end,
})

-- ============================================================================
-- Picker heading: the picked list, the prev / next steps, the grid total.
-- ============================================================================

local function _findSelected(rows)
    for _, r in ipairs(rows) do
        if r.isSelected then return r end
    end
    return nil
end

-- The picked list's row for the heading. Built by the picker's own row
-- builders but UNFILTERED: a search that hides the list from the picker, or a
-- folded group, must not blank the heading of the list the grid still shows.
-- Recent mode always has one (the newest session when nothing is picked).
local function _pickedRow(state)
    local mode     = state.session.ui.companion.mode
    local selected = state.session.ui.companion.selectedItemID
    if mode == "catalog" then return _catalogPickedRow(state) end
    if mode == "recent" then return _findSelected(_sidebarRecentRows(state, selected)) end
    if selected == nil then return nil end
    if mode == "rooms" then return _findSelected(_sidebarRoomRows(state, nil, selected)) end
    if selected == PLACED_LIVE_ID then return { id = PLACED_LIVE_ID, displayName = PLACED_LIVE_NAME } end
    local bucket = PLACEMENT_COST_BUCKET_BY_ID[selected]
    if bucket then return { id = bucket.id, displayName = bucket.text } end
    return _findSelected(_collectionMatches(state, MODE_TO_TYPES[mode] or {}, nil, selected))
end

Selectors:Register("companion.pickedRow", {
    reads = {
        "session.ui.companion.mode",
        "session.ui.companion.selectedItemID",
        "account.collections",
        "account.rooms",
        "account.furnishingSets",            -- room rows count their furnishings
        "session.furn",
        "session.house.roomCatalog",         -- room rows carry the blueprint tile
        "session.styles.changeSeq",
        "session.resolvers.staticData.tick",
        "session.house.categoryTree",        -- Catalog: the category's name + icon
    },
    calls = { "companion.recentSessions" },
    fn = _pickedRow,
})

-- Rows the picker can pick: everything but headers (group rows included) and dividers.
local function _isPickable(row)
    return not (row.isHeader or row.isDivider)
end

-- Prev / next over every list the picker holds, folded groups included (a
-- player who folds every group still steps through their lists), wrapping at
-- either end (the lab's stepper). With nothing picked, next is the first list and
-- prev the last. `first` is what a mode opens on before the player has picked
-- there. Memoized: the picker, both arrows and the auto-pick all ask per push.
Selectors:Register("companion.listSteps", {
    reads = _sidebarReads(),
    calls = { "companion.recentSessions" },
    memoized = true,
    fn = function(state)
        local ids, at = {}, nil
        for _, r in ipairs(_sidebarRows(state, true)) do
            if _isPickable(r) then
                ids[#ids + 1] = r.id
                if r.isSelected then at = #ids end
            end
        end
        local n = #ids
        if n == 0 then return { count = 0 } end
        return {
            count = n,
            first = ids[1],
            prev  = ids[at and ((at - 2) % n + 1) or n],
            next  = ids[at and (at % n + 1) or 1],
        }
    end,
})

Selectors:Register("companion.hasListSteps", {
    reads = {},
    calls = { "companion.listSteps" },
    fn = function(state, ctx) return Selectors:Call("companion.listSteps", state, ctx).count > 1 end,
})

Selectors:Register("companion.hasLists", {
    reads = {},
    calls = { "companion.listSteps" },
    fn = function(state, ctx) return Selectors:Call("companion.listSteps", state, ctx).count > 0 end,
})

Selectors:Register("companion.gridTotal", {
    reads = {},
    calls = { "companion.gridItems" },
    fn = function(state, ctx)
        return ("%d decor"):format(#Selectors:Call("companion.gridItems", state, ctx))
    end,
})

-- ============================================================================
-- Grid items for the selected collection (or session events for recent mode).
-- Collection resolution uses HDG.StyleResolve.ItemsFor (shared with Styles tab)
-- so rule-based collections populate too.
-- ============================================================================

-- Emit placement-ready grid cells for one catalog item: base (undyed) + one cell
-- per owned dyed variant. Each cell carries the placement payload (entryID,
-- ownedQty, allowIndoors/allowOutdoors, placementCost, isUniqueTrophy) and its
-- dye mark: canCustomize on the undyed cell (palette), the variant's
-- dyeColorIDs on a dyed one (one drop per dye), as Blizzard's tiles.
-- Dye split: row.quantity is aggregate across variants (12.0.5 catalog API);
-- base undyed = aggregate - sum(dyed numStored). row nil = boundary (catalog not swept).
local function _emitDecorCells(out, itemID, row, needle)
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
        canCustomize   = row.canCustomize == true,
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
            dyeColorIDs    = dv.dyeColorIDs,
        }
    end
end

-- Stamp what each tile paints from where the player stands, so the factory
-- stays a pure function of ed: the cost toggle, that place's budget icon,
-- whether the cost is more than the budget has left, and whether the decor may
-- go here at all. gridItems / recentStrip read account showCost and
-- session.house.budget, so the toggle and every placement re-push the tiles.
-- overBudget waits for a known budget (decorMax 0 = no reading yet), or every
-- cost would read as too big. cantHere keeps the old border's rule: an absent
-- allow flag counts as "no"; only placeable cells (entryID) qualify.
local function _stampPlacement(out, state)
    local b        = state.session.house.budget
    local showCost = state.account.ui.companion.showCost
    local left     = b.decorMax - b.decorSpent
    local atlas    = _budgetAtlas(b)
    for _, ed in ipairs(out) do
        ed.showCost   = showCost
        ed.costAtlas  = atlas
        ed.overBudget = b.decorMax > 0 and (ed.placementCost or 0) > left   -- exception(nullable): catalog-miss cells carry no cost
        ed.cantHere   = ed.entryID ~= nil
            and ((b.inside and not ed.allowIndoors) or (not b.inside and not ed.allowOutdoors))
    end
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
                canCustomize   = row and row.canCustomize == true,   -- one cell per decor here, no dyed copies: palette only
            }
        end
    end
    return out
end

-- Rooms-mode grid: selected room's EFFECTIVE furnishings (equipped sets + own
-- pieces) as placement cards -- place straight from your plan.
local function _gridRoomItems(state, room, needle)
    local out, seen = {}, {}
    _forEachRoomEffectiveItem(state, room, function(it)
        if not seen[it.id] then
            seen[it.id] = true
            local row = HDG.HousingCatalogObserver:GetRow(it.id)
            _emitDecorCells(out, it.id, row, needle)
        end
    end)
    return out
end

-- Cost-bucket grid: walk the catalog for owned decor in [lo,hi]. IterateRows
-- reads the observer's baked cache (freshness via sweepGeneration).
local function _gridBucketItems(bucket, needle)
    local out = {}
    HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
        local cost = row.placementCost or 0  -- exception(boundary): catalog struct field sparse
        if cost >= bucket.lo and cost <= bucket.hi
           and HDG.HousingCatalogObserver:IsOwned(row) then
            _emitDecorCells(out, itemID, row, needle)
        end
    end)
    table.sort(out, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return out
end

-- Catalog grid: every decor in the picked category / subcategory (first id, as
-- the counts), owned or not; All = the whole catalog. Decor you don't own shows
-- with no count, and its click says so (the cell's own rule).
local function _gridCatalogItems(state, needle)
    local kind, id = _catalogPick(state.session.ui.companion.selectedItemID)
    local out = {}
    if kind == nil then return out end
    HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
        if kind == "all" or (kind == "cat" and row.categoryID == id)
           or (kind == "sub" and row.subcategoryID == id) then
            _emitDecorCells(out, itemID, row, needle)
        end
    end)
    table.sort(out, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return out
end

-- Membership/rule-based grid: resolved through StyleResolve.ItemsFor so
-- smartsets, concepts, and name-pattern Useful Collections all populate.
local function _gridCollectionItems(state, needle)
    local out = {}
    local itemIDs = HDG.StyleResolve.ItemsFor(
        state.session.ui.companion.selectedItemID, state)
    for _, itemID in ipairs(itemIDs) do
        local row = HDG.HousingCatalogObserver:GetRow(itemID)
        _emitDecorCells(out, itemID, row, needle)
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

local function _gridPlacedLiveItems(state, needle)
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
            -- _emitDecorCells emits 0..N cells (nothing when the search
            -- excludes it; base + one per dyed variant otherwise), so stamp the
            -- range it actually appended rather than assuming out[#out] is ours.
            local before = #out
            _emitDecorCells(out, cell.itemID, row, needle)
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
        "account.ui.companion.showCost",    -- cell cost-badge gate (stamped per cell)
        "session.house.budget",             -- where you stand + budget left (stamped per cell)
        "account.recentActivity",
        "account.collections",
        "account.rooms",                    -- rooms-mode grid: the selected room
        "account.furnishingSets",           -- rooms-mode grid: its effective furnishings
        "session.styles.changeSeq",
        "session.resolvers.staticData.tick",          -- StyleResolve reads pre-authored defs
        "session.resolvers.catalog.tick",
    },
    memoized = true,   -- the grid and the heading's total (companion.gridTotal) share one build per push
    fn = function(state)
        local mode     = state.session.ui.companion.mode
        local search   = state.session.ui.companion.search:lower()
        local needle   = search ~= "" and search or nil

        local out
        if mode == "catalog" then
            out = _gridCatalogItems(state, needle)
        elseif state.session.ui.companion.selectedItemID == PLACED_LIVE_ID then
            out = _gridPlacedLiveItems(state, needle)
        elseif mode == "recent" then
            out = _gridRecentItems(state, needle)
        elseif mode == "rooms" then
            local room = state.account.rooms[state.session.ui.companion.selectedItemID or ""]   -- exception(nullable): nothing selected yet
            out = room and _gridRoomItems(state, room, needle) or {}
        else
            -- Bucket checked before collection resolution: a bucket id resolves to no collection.
            local bucket = PLACEMENT_COST_BUCKET_BY_ID[state.session.ui.companion.selectedItemID]
            out = bucket and _gridBucketItems(bucket, needle)
                          or _gridCollectionItems(state, needle)
        end
        return _stampPlacement(out, state)
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
        "account.ui.companion.showCost",   -- re-placeable cells -> cost badge respects the toggle
        "session.house.budget",            -- ...and paints that place's budget icon
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
                -- One key per action: the session plus the action's place in its
                -- event count. The strip snaps back to the newest card only when
                -- the first key changes (a new action), not on every re-push.
                key            = sess.sessionID .. ":" .. (sess.eventCount - i + 1),
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
        return _stampPlacement(out, state)
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
    catalog      = "Categories",
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
