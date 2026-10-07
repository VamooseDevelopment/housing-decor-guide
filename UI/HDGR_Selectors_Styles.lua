-- HDG.Selectors -- Styles tab
-- ============================================================================
-- Surfaces:
--   landing.*   -- sections list + card rows
--   detail.*    -- split list + cards + item panel
--   curator.*   -- source/target lists + undo + memberships
--   smartset.*  -- axes / tags / basket / preview (FacetDB)
--   import.*    -- URL parse + preview

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors

-- Forward declaration so Detail surface (defined before 14.4.c) can call the resolver.
local _resolveSmartsetItems

-- View switcher: which Styles sub-surface is active. Drives the visibility
-- cascade in LayoutConfig (each sub-view declares `visible = "styles.isView_X"`).
Selectors:DefinePath("styles.view", "session.ui.styles.view")
Selectors:DefineEnum("styles.isView",  "session.ui.styles.view",
                     { "landing", "detail", "curator", "smartset", "import", "export" })

-- Export sub-view: selection + format + search paths, and a format-radio enum
-- (yields styles.export.isFormat_hdg / _dd2 for the two radio buttons).
Selectors:DefinePath("styles.export.selectedKey", "session.ui.styles.export.selectedKey")
Selectors:DefinePath("styles.export.format",      "session.ui.styles.export.format")
Selectors:DefinePath("styles.export.search",      "session.ui.styles.export.search")
Selectors:DefineEnum("styles.export.isFormat",    "session.ui.styles.export.format", { "hdg", "dd2" })

-- (Per-surface headerRows retired: single dynamic title + back button in panel header.
--  styles.notLanding removed: headerBack now gated on styles.isView_detail.)
Selectors:Register("styles.headerTitle", {
    reads = { "session.ui.styles.view" },
    calls = { "styles.detail.collection" },
    fn = function(state, ctx)
        -- Bare view name (sidebar nav carries the Styles > <leaf> breadcrumb).
        local view = state.session.ui.styles.view or "landing"
        if view == "landing"  then return "Browse Styles" end
        if view == "curator"  then return "Style Curator" end
        if view == "smartset" then return "Smart Set Builder" end
        if view == "import"   then return "Import" end
        if view == "detail" then
            local coll = Selectors:Call("styles.detail.collection", state, ctx)
            return coll and (coll.displayName or coll.name) or "Detail"
        end
        return "Styles"
    end,
})
-- Unified per-view header-count text. Landing uses heroLabel; Curator uses
-- sourceCountLabel; other views fall through to "" until they ship one.
Selectors:Register("styles.headerCount", {
    reads = { "session.ui.styles.view" },
    calls = { "styles.landing.heroLabel", "styles.curator.sourceCountLabel",
              "styles.smartset.matchingCount" },
    fn = function(state, ctx)
        local view = state.session.ui.styles.view or "landing"
        if view == "curator" then
            return Selectors:Call("styles.curator.sourceCountLabel", state, ctx)
        end
        if view == "smartset" then
            return string.format("%d matching",
                Selectors:Call("styles.smartset.matchingCount", state, ctx))
        end
        return Selectors:Call("styles.landing.heroLabel", state, ctx)
    end,
})

-- Selected collection ID for the Detail surface.
Selectors:DefinePath("styles.selectedID", "session.ui.styles.selectedID")

-- Cache invalidation tick. Selectors deriving from StyleEngine declare reads here.
Selectors:DefinePath("styles.changeSeq", "session.styles.changeSeq")

-- Landing filter chip.
Selectors:DefinePath("styles.landing.filter", "session.ui.styles.landing.filter")
Selectors:DefineEnum("styles.landing.isFilter", "session.ui.styles.landing.filter",
                     { "all", "style", "smartset", "shopping", "snapshot", "concept", "collection" })

Selectors:DefinePath("styles.landing.search", "session.ui.styles.landing.search")
Selectors:DefinePath("styles.detail.search",  "session.ui.styles.detail.search")
Selectors:DefinePath("styles.curator.searchQuery", "session.ui.styles.curator.searchQuery")

-- ===== Landing surface ======================================================
-- countSuffix: unit word for the header badge (singular; painter appends "s" for != 1).
local LANDING_SECTIONS = {
    { type = "style",      label = "My Styles",          subtitle = "built with Style Curator",
      countSuffix = "style" },
    { type = "smartset",   label = "Filtered Sets",      subtitle = "built with Smart Set Builder",
      countSuffix = "set" },
    { type = "shopping",   label = "Shopping Lists",     subtitle = "import from wowhead.com or build from Acquire / Preview tab",
      countSuffix = "list" },
    { type = "snapshot",   label = "Snapshots",          subtitle = "everything you've placed -- hit Save Placed Decor to capture",
      countSuffix = "snapshot" },
    { type = "concept",    label = "Room Concepts",      subtitle = "pre-made themes from smart sets",
      countSuffix = "concept" },
    { type = "collection", label = "Useful Collections", subtitle = "prepared sets for use in the house editor",
      countSuffix = "collection" },
}

-- Iterate every collection across four origins:
--   account.collections        -- user styles / smartsets / snapshots / imported lists
--   account.vendorShoppingLists -- vendor-tab lists (synthetic "vsl:<id>" key)
--   HDGR_StyleDefinitions      -- rule-based Room Concepts (type "concept")
--   HDGR_CollectionDefinitions -- pre-authored Useful Collections (type "collection")
-- Yields { id, type, def } per entry.
--
-- _vendorListRecord: shared by iterAllCollections AND StyleResolve.RecordFor so
-- both resolve a "vsl:" id to the same shape.
local function _vendorListRecord(list, listID)
    -- Decor only: a blueprint's list also carries its Housing Dyes, which have no
    -- icon in the catalog and can never count as collected, so a card built from
    -- them showed blank tiles and a collected count stuck below 100%.
    local ids = {}
    for _, e in ipairs(list.items or {}) do
        if e.itemID and not HDG.Constants.HOUSING_DYE_ITEM_IDS[e.itemID] then ids[#ids + 1] = e.itemID end
    end
    local meta      = list.meta or {}
    local isWowhead = meta.source == "wowhead"
    return {
        displayName  = list.name or listID,
        description  = "",
        items        = ids,                  -- flattened so _resolvePreviewIcons + detail.items work
        url          = meta.url,             -- source URL -> drives the detail URL copy box
        -- Browse-row + detail icon: wowhead logo for wowhead-sourced lists; for
        -- everything else leave icon nil so the landing-card resolution falls
        -- through to previewIcons[1] -- the first decor item's icon, matching how
        -- My Styles / the other sections paint their row icon. (No atlas here:
        -- the old "wowcodex-itemicon-bag" was a fake atlas -> silent SetAtlas
        -- no-op that bled the prior pooled texture onto non-wowhead rows.)
        icon         = isWowhead and HDG.Constants.WOWHEAD_TEXTURE or nil,
        isWowhead    = isWowhead,            -- styles.detail.sourceIcon reads this
        isVendorList = true,                 -- Detail surface discriminator
    }
end

local function iterAllCollections(state)
    local out = {}
    for id, def in pairs(state.account.collections) do
        local colonAt = id:find(":")
        local t = colonAt and id:sub(1, colonAt - 1) or "style"
        out[#out + 1] = { id = id, type = t, def = def }
    end
    -- Vendor shopping lists live in account.vendorShoppingLists (not account.collections).
    for listID, list in pairs(state.account.vendorShoppingLists) do
        out[#out + 1] = { id = "vsl:" .. listID, type = "shopping", def = _vendorListRecord(list, listID) }
    end
    -- Pre-authored Room Concepts (rule-based). Styles -> "concept"; Collections -> "collection".
    local sd = HDG.StaticData.Styles:GetDefinitions()
    if type(sd) == "table" then
        for sid, def in pairs(sd) do
            local t = (def.tier == "collection") and "collection" or "concept"
            out[#out + 1] = { id = "concept:" .. sid, type = t, def = def }
        end
    end
    -- Pre-authored Useful Collections (membership/name-pattern).
    -- "collection:<bareID>" prefix lets Detail route to the right normalizer.
    local cd = HDG.StaticData.Collections:GetDefinitions()
    if type(cd) == "table" then
        for cid, def in pairs(cd) do
            out[#out + 1] = { id = "collection:" .. cid, type = "collection", def = def }
        end
    end
    return out
end

-- Count collections per type for section-header badges and chip-strip counts.
Selectors:Register("styles.collectionsByType", {
    -- Six integers that cost a 57 KB walk of every collection per call, 13 calls
    -- a scenario (2026-09-13 audit). staticData.tick: the walk reads the shipped
    -- Styles/Collections definitions (ADR-003c marker).
    memoized = true,
    reads = { "account.collections", "account.vendorShoppingLists", "session.styles.changeSeq",
              "session.resolvers.staticData.tick" },
    fn = function(state)
        local counts = { style = 0, smartset = 0, shopping = 0, snapshot = 0, concept = 0, collection = 0 }
        for _, entry in ipairs(iterAllCollections(state)) do
            counts[entry.type] = (counts[entry.type] or 0) + 1
        end
        return counts
    end,
})

-- Landing rows: heterogeneous (section headers + card rows). Scrollbox binds to this.
-- filter-specific type -> one section shows; "all" shows every section.
-- _resolvePreviewIcons: up to 6 entries per collection; called only when catalog IsReady().
local function _resolvePreviewIcons(itemIDs)
    local out = {}
    for i = 1, math.min(6, #itemIDs) do
        local itemID = itemIDs[i]
        local row    = HDG.HousingCatalogObserver:GetRow(itemID)
        local tex, atl = HDG.Format.CoerceIconPair(
            row and row.iconTexture, row and row.iconAtlas)
        out[i] = {
            itemID      = itemID,
            iconTexture = tex,
            iconAtlas   = atl,
            isOwned     = HDG.HousingCatalogObserver:IsOwned(row or itemID),
        }
    end
    return out
end

-- Compute collected/total from a collection's item list.
-- Returns collected (owned), total (all), pct (0..1).
local function _resolveCollectedCounts(itemIDs)
    local total, collected = #itemIDs, 0
    for _, itemID in ipairs(itemIDs) do
        if HDG.HousingCatalogObserver:IsOwned(itemID) then
            collected = collected + 1
        end
    end
    local pct = (total > 0) and (collected / total) or 0
    return collected, total, pct
end

-- Forward-declared collection item resolvers (defined further below, near the
-- detail normalizer). _resolveCollectionItems is the SINGLE source of truth for
-- "what items does this collection contain" -- used by BOTH the landing card
-- builder and the detail normalizer so previews/counts never drift.
local _resolveNamePatternItems, _resolveSpecialItems
local function _resolveCollectionItems(id, def, t, state)
    -- Priority: explicit items[] > namePatterns > resolver (collections only).
    if type(def.items) == "table" then return def.items end
    if t == "collection" and def.namePatterns then return _resolveNamePatternItems(id, def, state) end
    if t == "collection" and def.resolver     then return _resolveSpecialItems(id, def, state) end
    return {}
end

-- Display name for a collection entry (def.displayName > def.name > id).
local function _entryDisplayName(entry)
    return (entry.def and (entry.def.displayName or entry.def.name)) or entry.id
end

-- Bucket collections by type (O(1) per section at render); each bucket sorted
-- by displayName for stable rendering.
local function _buildSectionBuckets(state)
    local byType = { style = {}, smartset = {}, shopping = {}, snapshot = {}, concept = {}, collection = {} }
    for _, entry in ipairs(iterAllCollections(state)) do
        byType[entry.type] = byType[entry.type] or {}
        byType[entry.type][#byType[entry.type] + 1] = entry
    end
    for _, list in pairs(byType) do
        table.sort(list, function(a, b)
            return tostring(_entryDisplayName(a)):lower() < tostring(_entryDisplayName(b)):lower()
        end)
    end
    return byType
end

-- Card icon resolution. Priority: sample decor item (previewIcons[1]) for
-- collection/style (their def.icon is a generic category glyph -- matches My
-- Styles) > def.iconAtlas > def.icon > first preview. Empty shopping lists
-- have no decor sample -> shopping-cart glyph (matches the Shopping tab
-- header) instead of the red "?" placeholder.
local function _resolveCardIcon(entry, def, previewIcons)
    local preferSample = entry.type == "collection" or entry.type == "style"
    local icon, iconAtlas
    if preferSample and previewIcons[1] then
        icon      = previewIcons[1].iconTexture
        iconAtlas = previewIcons[1].iconAtlas
    elseif def.iconAtlas and def.iconAtlas ~= "" then
        iconAtlas = def.iconAtlas
    elseif def.icon and def.icon ~= "" then
        icon = def.icon
    elseif previewIcons[1] then
        icon      = previewIcons[1].iconTexture
        iconAtlas = previewIcons[1].iconAtlas
    end
    if not icon and not iconAtlas and entry.type == "shopping" then
        iconAtlas = HDG.Constants.SHOPPING_LIST_ICON_ATLAS
    end
    return icon, iconAtlas
end

-- Build one landing card row.
local function _buildCardRow(entry, displayName, state, catalogReady, selectedID)
    local def = entry.def or {}
    -- Useful Collections resolve items by name-pattern/resolver, not a static
    -- items[] -- resolve via the shared helper so they get the same preview
    -- strip + collected count as My Styles.
    local itemList = _resolveCollectionItems(entry.id, def, entry.type, state)
    -- Pre-authored types (collection/concept) come from StaticData, not
    -- account.collections -- edit/export/delete are all dead no-ops there,
    -- so mark read-only (hides all three buttons; not deletable).
    local isReadOnly = def.isReadOnly == true
        or entry.type == "collection" or entry.type == "concept"
    -- preview icons + counts only when catalog is ready
    local previewIcons = {}
    local collected, total, pct = 0, #itemList, 0
    if catalogReady and #itemList > 0 then
        previewIcons = _resolvePreviewIcons(itemList)
        collected, total, pct = _resolveCollectedCounts(itemList)
    end
    local icon, iconAtlas = _resolveCardIcon(entry, def, previewIcons)
    return {
        kind         = "card",
        collectionID = entry.id,
        type         = entry.type,
        categoryID   = def.categoryID,   -- nil = not in a category; A's menu checks the current radio from this
        displayName  = displayName,
        subtitle     = def.description or nil,
        isSelected   = selectedID == entry.id,
        -- HDG-parity detail fields:
        icon         = icon,
        iconAtlas    = iconAtlas,
        hideIcon     = entry.type == "smartset",  -- rule-based: no item to draw
        previewIcons = previewIcons,
        collected    = collected,
        total        = total,
        pct          = pct,
        color        = def.color,
        url          = def.url,
        isSnapshot   = entry.type == "snapshot",
        canEdit      = not isReadOnly and entry.type == "style",
        canExport    = not isReadOnly,
        canDelete    = not isReadOnly,
    }
end

-- ===== My Styles categories (spec HDGR_STYLE_CATEGORIES_SPEC_2026-09-04 s4.1) =====

-- Name (case-insensitive) then seq: a total order even after rename has made
-- two categories share a name (spec 2.4).
local function _sortedStyleCategories(cats)
    local out = {}
    for _, cat in pairs(cats) do out[#out + 1] = cat end
    table.sort(out, function(a, b)
        local an, bn = a.name:lower(), b.name:lower()
        if an ~= bn then return an < bn end
        return a.seq < b.seq
    end)
    return out
end

-- Bucket style entries by categoryID. A categoryID that is not a key of the
-- registry is "not a category any more" -> loose. That is the answer, not a guard.
local function _bucketStylesByCategory(styleEntries, cats)
    local byCat, loose = {}, {}
    for id in pairs(cats) do byCat[id] = {} end
    for _, entry in ipairs(styleEntries) do
        local bucket = byCat[entry.def.categoryID]
        if bucket then bucket[#bucket + 1] = entry else loose[#loose + 1] = entry end
    end
    return byCat, loose
end

local function _entryMatches(entry, needle)
    return not needle or tostring(_entryDisplayName(entry)):lower():find(needle, 1, true) ~= nil
end

-- Emit the cards of one flat list (the pre-category path and the other five sections).
local function _emitCards(out, entries, needle, state, catalogReady, selectedID)
    for _, entry in ipairs(entries) do
        if _entryMatches(entry, needle) then
            out[#out + 1] = _buildCardRow(entry, _entryDisplayName(entry), state, catalogReady, selectedID)
        end
    end
end

-- Emit one group row (category or the loose fold) and, when open, its cards.
-- forceOpen (chip / needle) is a read-only override of the remembered flag.
local function _emitGroup(out, row, members, remembered, needle, forceOpen, state, catalogReady, selectedID)
    local matches = members
    if needle then
        matches = {}
        for _, entry in ipairs(members) do
            if _entryMatches(entry, needle) then matches[#matches + 1] = entry end
        end
        if #matches == 0 then return end
        row.matchCount = #matches
    end
    row.forcedOpen = (needle ~= nil) or forceOpen
    row.expanded   = row.forcedOpen or remembered
    out[#out + 1] = row
    if row.expanded then
        for _, entry in ipairs(matches) do
            local card = _buildCardRow(entry, _entryDisplayName(entry), state, catalogReady, selectedID)
            card.indented = true   -- one indent stop under a category row or the fold (spec 5.1)
            out[#out + 1] = card
        end
    end
end

-- The My Styles body: loose fold first, then categories. Zero categories = the
-- plain card list, byte-identical to 3.31.2.
local function _emitMyStylesBody(out, styleEntries, needle, forceOpen, state, catalogReady, selectedID)
    local cats = state.account.styleCategories
    if next(cats) == nil then
        _emitCards(out, styleEntries, needle, state, catalogReady, selectedID)
        return
    end
    local expandedCats = state.account.ui.styles.landing.expandedCategories
    local byCat, loose = _bucketStylesByCategory(styleEntries, cats)
    if #loose > 0 then
        _emitGroup(out, { kind = "category", categoryID = "loose", isLoose = true, count = #loose, canAdd = false },
                   loose, expandedCats["loose"] == true, needle, forceOpen, state, catalogReady, selectedID)
    end
    for _, cat in ipairs(_sortedStyleCategories(cats)) do
        local members = byCat[cat.id]
        _emitGroup(out, { kind = "category", categoryID = cat.id, isLoose = false, label = cat.name,
                          count = #members, canAdd = #loose > 0 },
                   members, expandedCats[cat.id] == true, needle, forceOpen, state, catalogReady, selectedID)
    end
end

Selectors:Register("styles.landing.rows", {
    reads = {
        "session.ui.styles.landing.filter",
        "session.ui.styles.landing.search",
        "session.ui.styles.selectedID",
        "account.ui.styles.landing.expandedSections",
        "account.ui.styles.landing.expandedCategories",
        "account.styleCategories",
        "account.collections",
        "account.vendorShoppingLists",       -- vendor-tab shopping lists (separate slot)
        "session.styles.changeSeq",
        "session.resolvers.catalog.tick",   -- re-resolves when observer sweep completes
    },
    -- calls: declared so BindingEngine's read-closure includes collectionsByType's reads.
    -- Without this, section-header counts would go stale on account.collections mutations.
    calls = { "styles.collectionsByType" },
    fn = function(state)
        local filter        = state.session.ui.styles.landing.filter   -- seeded "all", always written by SET_FILTER
        local search        = (state.session.ui.styles.landing.search):lower()
        local expanded      = state.account.ui.styles.landing.expandedSections
        local selectedID    = state.session.ui.styles.selectedID
        local counts        = Selectors:Call("styles.collectionsByType", state, {})
        local catalogReady  = HDG.HousingCatalogObserver:IsReady()
        local byType = _buildSectionBuckets(state)
        local needle = search ~= "" and search or nil
        local out = {}
        for _, s in ipairs(LANDING_SECTIONS) do
            if filter == "all" or filter == s.type then
                -- A type chip is the guaranteed path to every card: it force-opens
                -- the section AND, for My Styles, every category and the fold.
                -- Resolved BEFORE the header literal: the chevron and the header's
                -- "+ New Category" both paint from row.expanded, so the header has
                -- to report the state the body is emitted in, not the raw flag --
                -- otherwise the chip hides the only way to make a first category.
                local chipForced      = filter == s.type
                local sectionExpanded = expanded[s.type] == true or chipForced
                out[#out + 1] = {
                    kind        = "header",
                    type        = s.type,
                    label       = s.label,
                    subtitle    = s.subtitle,
                    countSuffix = s.countSuffix or "style",
                    count       = counts[s.type] or 0,  -- exception(boundary): sparse map
                    expanded    = sectionExpanded,
                    -- The chip is the only force on a SECTION (a needle force-opens
                    -- groups inside My Styles, never the section itself), so the wire
                    -- has one flag to read before it writes the remembered one.
                    forcedOpen  = chipForced,
                }
                if sectionExpanded then
                    if s.type == "style" then
                        _emitMyStylesBody(out, byType.style, needle, chipForced, state, catalogReady, selectedID)
                    else
                        _emitCards(out, byType[s.type] or {}, needle, state, catalogReady, selectedID)
                    end
                end
            end
        end
        return out
    end,
})

-- Feeds A's per-style "File into" menu.
Selectors:Register("styles.landing.categoryChoices", {
    reads = { "account.styleCategories" },
    fn = function(state)
        local out = {}
        for _, cat in ipairs(_sortedStyleCategories(state.account.styleCategories)) do
            out[#out + 1] = { id = cat.id, name = cat.name }
        end
        return out
    end,
})

-- Feeds B's "+ Add styles" menu ITEM LIST (fixed at open time). Built from the
-- SAME buckets the landing fold is built from -- _buildSectionBuckets types an
-- entry, _bucketStylesByCategory decides loose -- so the menu and the fold can
-- never disagree about which styles are loose. (Routing on an "style:" id prefix
-- here was a third rule: a colon-less id types as "style" in the fold but failed
-- the prefix test, so it was uncloseable from this menu.)
Selectors:Register("styles.landing.looseStyles", {
    reads = { "account.collections", "account.styleCategories",
              "account.vendorShoppingLists",   -- _buildSectionBuckets walks it too
              "session.styles.changeSeq" },
    fn = function(state)
        local byType = _buildSectionBuckets(state)
        local _, loose = _bucketStylesByCategory(byType.style, state.account.styleCategories)
        local out = {}
        for _, entry in ipairs(loose) do
            out[#out + 1] = { collectionID = entry.id, displayName = _entryDisplayName(entry) }
        end
        table.sort(out, function(a, b) return tostring(a.displayName):lower() < tostring(b.displayName):lower() end)
        return out
    end,
})


-- ===== Export surface =======================================================
-- styles.export.sourceRows: grouped source list for the Export sub-view. Header
-- rows + item rows for the player's shopping lists / My Styles / furnishing
-- sets, plus a static Decor Collection row, filtered by the export search box.
-- PURE: the export CODE is built controller-side (codecs + the catalog observer
-- are non-store singletons), so this selector only enumerates keys + names.
local EXPORT_GROUPS = {
    { group = "shopping", label = "SHOPPING LISTS" },
    { group = "style",    label = "MY STYLES" },
    { group = "set",      label = "FURNISHING SETS" },
}

Selectors:Register("styles.export.sourceRows", {
    reads = {
        "account.vendorShoppingLists",
        "account.collections",
        "account.furnishingSets",
        "session.ui.styles.export.search",
        "session.ui.styles.export.selectedKey",
    },
    fn = function(state)
        local raw      = state.session.ui.styles.export.search:lower()
        local selected = state.session.ui.styles.export.selectedKey
        local needle   = raw ~= "" and raw or nil
        local function match(name) return (not needle) or tostring(name):lower():find(needle, 1, true) ~= nil end

        local items = { shopping = {}, style = {}, set = {} }
        for id, list in pairs(state.account.vendorShoppingLists) do
            -- Count what the card shows: _vendorListRecord leaves a blueprint list's dyes out.
            items.shopping[#items.shopping + 1] = { key = "vsl:" .. id, name = list.name or id,  -- exception(nullable): list.name optional, mirror _vendorListRecord fallback
                countHint = #_vendorListRecord(list, id).items }
        end
        for id, def in pairs(state.account.collections) do
            if id:match("^style:") then
                items.style[#items.style + 1] = { key = id, name = _entryDisplayName({ def = def, id = id }) }
            end
        end
        for key, set in pairs(state.account.furnishingSets) do
            items.set[#items.set + 1] = { key = key, name = set.name, countHint = #set.items }
        end
        for _, g in pairs(items) do
            table.sort(g, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
        end

        local out = {}
        -- Decor Collection FIRST: it's the only thing housing.wowdb.com can import,
        -- so it leads. Always offered; owned count is painted controller-side.
        local collName = "Your owned decor"
        if match(collName) then
            out[#out + 1] = { kind = "header", group = "collection", label = "DECOR COLLECTION (for housing.wowdb.com)", count = 1 }
            out[#out + 1] = { kind = "item",   group = "collection", key = "collection", name = collName,
                              isSelected = selected == "collection" }
        end
        for _, grp in ipairs(EXPORT_GROUPS) do
            local matched = {}
            for _, it in ipairs(items[grp.group]) do
                if match(it.name) then matched[#matched + 1] = it end
            end
            if #matched > 0 then
                out[#out + 1] = { kind = "header", group = grp.group, label = grp.label, count = #matched }
                for _, it in ipairs(matched) do
                    out[#out + 1] = { kind = "item", group = grp.group, key = it.key, name = it.name,
                                      countHint = it.countHint, isSelected = it.key == selected }
                end
            end
        end
        return out
    end,
})

-- Contextual URL for the Export view: the wowdb decor-sync page for a DD2
-- collection export (the only thing wowdb imports), or a shopping list's source
-- URL (wowhead/wowdb import) when it carries one. "" = no URL (row hidden).
local WOWDB_DECOR_SYNC_URL = "https://housing.wowdb.com/tools/decor-sync/sync/"
Selectors:Register("styles.export.url", {
    reads = {
        "session.ui.styles.export.selectedKey",
        "session.ui.styles.export.format",
        "account.vendorShoppingLists",
    },
    fn = function(state)
        local exp = state.session.ui.styles.export
        local key, fmt = exp.selectedKey, exp.format
        if fmt == "dd2" and key == "collection" then return WOWDB_DECOR_SYNC_URL end
        if type(key) ~= "string" or not key:match("^vsl:") then return "" end
        local list = state.account.vendorShoppingLists[key:sub(5)]  -- exception(nullable): stale UI key
        if not list or not list.meta then return "" end  -- exception(nullable): player-authored lists carry no meta
        local url = list.meta.url
        if type(url) == "string" and url ~= "" then return url end
        return ""
    end,
})
Selectors:Register("styles.export.hasUrl", {
    calls = { "styles.export.url" },
    fn = function(state, ctx) return Selectors:Call("styles.export.url", state, ctx) ~= "" end,
})
-- DD2 only targets the collection (wowdb's lone importer loads ALL your decor),
-- so the HDG|DD2 format toggle is shown only when the collection is selected.
Selectors:Register("styles.export.isCollection", {
    reads = { "session.ui.styles.export.selectedKey" },
    fn = function(state) return state.session.ui.styles.export.selectedKey == "collection" end,
})

-- Format radio menu for the Export sub-view (HDG-native vs DD2/wowdb).
Selectors:Register("styles.export.formatItems", {
    reads    = {},
    memoized = true,
    fn = function()
        return {
            { text = "HDG",         value = "hdg" },
            { text = "DD2 (wowdb)", value = "dd2" },
        }
    end,
})

-- ===== Detail surface =======================================================
-- _normalizePreAuthored: converts legacy {query/boost/anti} 3-axis shape into
-- rules[axis][tag]=severity + stamps isReadOnly so Edit/Delete are hidden.
--   query -> "signature", boost -> "accent", anti -> "clashing"
local function _legacyToRules(def)
    local rules = {}
    local axesMap = {
        { src = def.query, severity = "signature" },
        { src = def.boost, severity = "accent"    },
        { src = def.anti,  severity = "clashing"  },
    }
    for _, entry in ipairs(axesMap) do
        if entry.src then
            for axis, tags in pairs(entry.src) do
                rules[axis] = rules[axis] or {}
                if type(tags) == "table" then
                    for _, tag in ipairs(tags) do
                        -- "signature" wins over "accent" wins over "clashing"
                        -- if the same (axis, tag) appears in multiple
                        -- legacy buckets (rare, but defensible).
                        rules[axis][tag] = rules[axis][tag] or entry.severity
                    end
                end
            end
        end
    end
    return rules
end

-- Name-pattern resolver for Useful Collections. Memoized against changeSeq
-- so consecutive reads don't re-walk ~1700 items per tick.
local _collectionItemsCache = {}        -- [collID] = { items = {...}, tick = N }
_resolveNamePatternItems = function(collID, def, state)
    local tick = state.session.styles.changeSeq
    local cached = _collectionItemsCache[collID]
    if cached and cached.tick == tick then return cached.items end
    if not HDG.HousingCatalogObserver:IsReady() then return {} end
    local items = {}
    HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
        local name = row.name or ""
        local matched = false
        for _, pattern in ipairs(def.namePatterns or {}) do
            if name:find(pattern, 1, true) then matched = true; break end
        end
        if matched and def.excludePatterns then
            for _, excl in ipairs(def.excludePatterns) do
                if name:find(excl, 1, true) then matched = false; break end
            end
        end
        if matched then items[#items + 1] = itemID end
    end)
    _collectionItemsCache[collID] = { items = items, tick = tick }
    return items
end

-- Special resolver: "dyeable" = canCustomize; "trophies" = isUniqueTrophy;
-- "neighborhood" = sold in a housing neighborhood (the Acquire filter's predicate);
-- "recently-learned" = decor from account.craft.history learned events, newest first.
-- Memoized against changeSeq (bumped on each learned CRAFT_HISTORY_PUSH, so this cache
-- refreshes the moment a decor is learned).
local _resolverItemsCache = {}          -- [collID] = { items = {...}, tick = N }
_resolveSpecialItems = function(collID, def, state)
    local tick = state.session.styles.changeSeq
    local cached = _resolverItemsCache[collID]
    if cached and cached.tick == tick then return cached.items end
    if not HDG.HousingCatalogObserver:IsReady() then return {} end
    local items = {}
    if def.resolver == "dyeable" then
        -- observer row carries canCustomize (= isDyeable); covers uncollected
        -- dyeables too since IterateRows walks the full catalog.
        HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
            if row.canCustomize then items[#items + 1] = itemID end
        end)
    elseif def.resolver == "trophies" then
        HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
            if row.isUniqueTrophy then items[#items + 1] = itemID end
        end)
    elseif def.resolver == "neighborhood" then
        HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
            if HDG.HousingCatalogObserver:IsSoldInNeighborhood(row) then items[#items + 1] = itemID end
        end)
    elseif def.resolver == "recently-learned" then
        -- Decor most-recently added to the house chest, deduped by item. Entries are
        -- appended at the end (oldest first), so walk backward for newest-first.
        -- craft.history.entries is factory-seeded (NewCraft) -> strict read.
        local entries = state.account.craft.history.entries
        local seen = {}
        for i = #entries, 1, -1 do
            local e = entries[i]
            if e.eventType == "learned" and e.itemID and not seen[e.itemID] then
                seen[e.itemID] = true
                items[#items + 1] = e.itemID
            end
        end
    end
    _resolverItemsCache[collID] = { items = items, tick = tick }
    return items
end

local function _normalizePreAuthored(def, id, state)
    if not def then return nil end
    -- tier "collection" -> "collection"; everything else -> rule-based "concept".
    local t = "concept"
    if def.tier == "collection" then t = "collection" end
    local normalized = {
        id          = id,
        type        = t,
        displayName = def.displayName or def.name or "Untitled",
        description = def.description or "",
        icon        = def.icon,
        color       = def.color,
        minScore    = def.minScore,
        isReadOnly  = true,
    }
    -- Membership: explicit items[] > namePatterns > resolver. Shared helper so the
    -- landing card builder and detail resolve identically (no drift).
    normalized.items = _resolveCollectionItems(id, def, t, state)
    -- Convert legacy query/boost/anti or use rules[] directly.
    if def.query or def.boost or def.anti then normalized.rules = _legacyToRules(def)
    elseif type(def.rules) == "table"      then normalized.rules = def.rules end
    return normalized
end

-- ============================================================================
-- Shared collection resolution (HDG.StyleResolve).
-- ============================================================================
-- Styles tab AND companion both resolve through these so all collection types
-- populate identically on both surfaces.
HDG.StyleResolve = HDG.StyleResolve or {}

-- id -> collection record. User collections returned raw; pre-authored defs normalized.
function HDG.StyleResolve.RecordFor(id, state)
    if not id then return nil end
    local user = state.account.collections and state.account.collections[id]
    if user then return user end
    -- Prefix routes to the right pre-authored source.
    local colonAt = id:find(":")
    local prefix  = colonAt and id:sub(1, colonAt - 1) or nil
    local bare    = colonAt and id:sub(colonAt + 1) or id
    if prefix == "vsl" then
        -- Shopping lists live in their own slot, not account.collections.
        local lists = state.account.vendorShoppingLists
        local list  = lists and lists[bare]
        if list then return _vendorListRecord(list, bare) end
    elseif prefix == "concept" then
        local sd = HDG.StaticData.Styles:GetDefinitions()
        if type(sd) == "table" and sd[bare] then return _normalizePreAuthored(sd[bare], id, state) end
    elseif prefix == "collection" then
        local cd = HDG.StaticData.Collections:GetDefinitions()
        if type(cd) == "table" and cd[bare] then return _normalizePreAuthored(cd[bare], id, state) end
    end
    return nil
end

-- id -> array of member itemIDs. Explicit items[] or scored rules{}
-- (signature+accent kept, clashing dropped). {} for unknown ids.
-- Callers must declare changeSeq + sweepGeneration in their reads.
function HDG.StyleResolve.ItemsFor(id, state)
    local coll = HDG.StyleResolve.RecordFor(id, state)
    if not coll then return {} end
    if type(coll.items) == "table" and #coll.items > 0 then
        return coll.items
    elseif type(coll.rules) == "table" then
        local scored = _resolveSmartsetItems(coll.rules, { liveSet = HDG.HousingCatalogObserver.byItemID })  -- released-index only
        local ids = {}
        for itemID, info in pairs(scored) do
            if (not info.hasClashing) and info.score > 0 then ids[#ids + 1] = itemID end
        end
        return ids
    end
    return {}
end

-- Currently-selected collection record. Delegates to StyleResolve.RecordFor.
Selectors:Register("styles.detail.collection", {
    reads = {
        "session.ui.styles.selectedID",
        "account.collections",
        "account.vendorShoppingLists",   -- shopping lists resolve via "vsl:" prefix in RecordFor
        "session.styles.changeSeq",
        "session.resolvers.catalog.tick",
    },
    fn = function(state)
        return HDG.StyleResolve.RecordFor(state.session.ui.styles.selectedID, state)
    end,
})



-- Description / subtitle from the collection record. Empty string when absent.
Selectors:Register("styles.detail.descriptionLabel", {
    calls = { "styles.detail.collection" },
    fn = function(state, ctx)
        local coll = Selectors:Call("styles.detail.collection", state, ctx)
        return coll and coll.description or ""
    end,
})

-- Source URL from list.meta.url or def.url. Drives the detail URL copy box.
Selectors:Register("styles.detail.sourceUrl", {
    calls = { "styles.detail.collection" },
    fn = function(state, ctx)
        local coll = Selectors:Call("styles.detail.collection", state, ctx)
        return (coll and coll.url) or ""
    end,
})
Selectors:Register("styles.detail.hasSourceUrl", {
    calls = { "styles.detail.sourceUrl" },
    fn = function(state, ctx)
        return Selectors:Call("styles.detail.sourceUrl", state, ctx) ~= ""
    end,
})
-- Source host parsed from URL (e.g. "www.wowhead.com"); "Source" when unparseable.
Selectors:Register("styles.detail.sourceLabel", {
    calls = { "styles.detail.sourceUrl" },
    fn = function(state, ctx)
        local url = Selectors:Call("styles.detail.sourceUrl", state, ctx)
        if url == "" then return "" end
        return url:match("^https?://([^/]+)") or "Source"
    end,
})
-- URL box icon: wowhead logo for wowhead-sourced lists, blank otherwise.
Selectors:Register("styles.detail.sourceIcon", {
    calls = { "styles.detail.collection" },
    fn = function(state, ctx)
        local coll = Selectors:Call("styles.detail.collection", state, ctx)
        return (coll and coll.isWowhead) and HDG.Constants.WOWHEAD_TEXTURE or ""
    end,
})
-- Source copy button label: wowhead logo (when wowhead-sourced) + host. Drives
-- the detail source button text; click pops the shared UrlCopyPopup.
Selectors:Register("styles.detail.sourceButtonText", {
    calls = { "styles.detail.sourceLabel", "styles.detail.sourceIcon" },
    fn = function(state, ctx)
        local host = Selectors:Call("styles.detail.sourceLabel", state, ctx)
        if host == "" then return "" end
        local icon = Selectors:Call("styles.detail.sourceIcon", state, ctx)
        if icon ~= "" then return "|T" .. icon .. ":12:12|t " .. host end
        return host
    end,
})

-- Detail items: membership path (items[]) or rule-based path (rules{}).
-- Rule path: _resolveSmartsetItems; signature + accent surfaced, clashing rejected.
-- Each row: { kind, itemID, name, isSelected, iconTexture, iconAtlas, isOwned, band? }
Selectors:Register("styles.detail.items", {
    calls = { "styles.detail.collection" },
    reads = { "session.ui.styles.detail.selectedItemID",
              "session.ui.styles.detail.search",
              "session.styles.changeSeq",
              "session.resolvers.catalog.tick", },
    fn = function(state, ctx)
        local coll = Selectors:Call("styles.detail.collection", state, ctx)
        if not coll then return {} end
        local selected = state.session.ui.styles.detail.selectedItemID
        local search   = (state.session.ui.styles.detail.search):lower()
        local needle   = search ~= "" and search or nil

        local sourceIDs, bandByID = {}, nil
        if type(coll.items) == "table" and #coll.items > 0 then
            -- Membership path.
            for _, id in ipairs(coll.items) do
                sourceIDs[#sourceIDs + 1] = id
            end
        elseif type(coll.rules) == "table" then
            -- Rule-based: score catalog items; keep signature + accent.
            local scored = _resolveSmartsetItems(coll.rules, { liveSet = HDG.HousingCatalogObserver.byItemID })  -- released-index only
            bandByID = {}
            for itemID, info in pairs(scored) do
                if (not info.hasClashing) and info.score > 0 then
                    sourceIDs[#sourceIDs + 1] = itemID
                    bandByID[itemID] = info.signatureHits > 0
                        and "signature" or "accent"
                end
            end
        end

        local out = {}
        for _, itemID in ipairs(sourceIDs) do
            -- Resolve display name + icon from observer row.
            local row  = HDG.HousingCatalogObserver:GetRow(itemID)
            local name = (row and row.name) or ("Item " .. tostring(itemID))
            if not needle or name:lower():find(needle, 1, true) then
                local iconTex, iconAtl = HDG.Format.CoerceIconPair(
                    row and row.iconTexture, row and row.iconAtlas)
                out[#out + 1] = {
                    itemID      = itemID,
                    name        = name,
                    isSelected  = selected == itemID,
                    iconTexture = iconTex,
                    iconAtlas   = iconAtl,
                    isOwned     = row and row.isOwned == true,
                    band        = bandByID and bandByID[itemID] or nil,
                }
            end
        end
        -- Rule-based: signature-first, then alphabetical. Membership keeps authored order.
        if bandByID then
            table.sort(out, function(a, b)
                if a.band ~= b.band then
                    return a.band == "signature"
                end
                return tostring(a.name):lower() < tostring(b.name):lower()
            end)
        end
        return out
    end,
})







-- ===== Curator =============================================================
-- Reverse index: itemID -> [styleCollectionID, ...].
-- Drives "Unassigned" source mode and the Memberships hover panel.
Selectors:Register("styles.curator.itemMemberships", {
    memoized = true,
    reads = { "account.collections", "session.styles.changeSeq" },
    fn = function(state)
        local out = {}
        for id, coll in pairs(state.account.collections) do
            if coll.type == "style" and coll.items then
                for _, itemID in ipairs(coll.items) do
                    out[itemID] = out[itemID] or {}
                    out[itemID][#out[itemID] + 1] = id
                end
            end
        end
        return out
    end,
})

-- Target list: all "style" collections sorted alphabetically.
-- Zero collections -> single placeholder row (ed.empty = true).
Selectors:Register("styles.curator.targetRows", {
    reads = { "account.collections", "session.ui.styles.curator.selectedTargetID",
              "session.styles.changeSeq" },
    fn = function(state)
        local activeID = state.session.ui.styles.curator.selectedTargetID
        local out = {}
        for id, coll in pairs(state.account.collections) do
            if coll.type == "style" then
                out[#out + 1] = {
                    kind         = "stylesCuratorTargetRow",
                    collectionID = id,
                    displayName  = coll.displayName or id,
                    count        = coll.items and #coll.items or 0,
                    isSelected   = activeID == id,
                }
            end
        end
        table.sort(out, function(a, b)
            return tostring(a.displayName):lower() < tostring(b.displayName):lower()
        end)
        -- Inject action sub-row after the selected target so Rename/Duplicate/Delete
        -- surface inline without a context menu.
        if activeID then
            for i, row in ipairs(out) do
                if row.collectionID == activeID then
                    table.insert(out, i + 1, {
                        kind         = "stylesCuratorTargetActionsRow",
                        collectionID = activeID,
                        displayName  = row.displayName,
                    })
                    break
                end
            end
        end
        if #out == 0 then
            out[1] = {
                kind  = "stylesCuratorTargetRow",
                empty = true,
                label = "No styles yet.\nClick + New Style below.",
            }
        end
        return out
    end,
})

-- has-target predicate. canMove = selectedCount > 0 AND target is selected.
Selectors:Register("styles.curator.hasTargets", {
    reads = { "account.collections" },
    fn = function(state)
        for _, coll in pairs(state.account.collections) do
            if coll.type == "style" then return true end
        end
        return false
    end,
})


-- Copy is valid from ANY source (add membership to target, keep in source).
-- Requires a selection + a chosen FILE-INTO target.
Selectors:Register("styles.curator.canCopy", {
    reads = { "session.ui.styles.curator.selectedTargetID",
              "account.collections" },
    calls = { "styles.curator.selectedCount" },
    fn = function(state, ctx)
        if Selectors:Call("styles.curator.selectedCount", state, ctx) == 0 then return false end
        local target = state.session.ui.styles.curator.selectedTargetID
        return target ~= nil and (state.account.collections)[target] ~= nil
    end,
})

-- Move only applies when the source is a user style (there's a membership to
-- remove). From All Items / Unassigned there's nothing to move out of -> Copy only.
Selectors:Register("styles.curator.moveApplies", {
    reads = { "session.ui.styles.curator.sourceMode" },
    fn = function(state)
        local m = state.session.ui.styles.curator.sourceMode
        return type(m) == "string" and m:sub(1, 6) == "style:"
    end,
})

-- Move = Copy's preconditions AND a user-style source.
Selectors:Register("styles.curator.canMove", {
    reads = { "session.ui.styles.curator.selectedItems",
              "session.ui.styles.curator.selectedTargetID",
              "session.ui.styles.curator.sourceMode",
              "account.collections" },
    calls = { "styles.curator.canCopy", "styles.curator.moveApplies" },
    fn = function(state, ctx)
        return Selectors:Call("styles.curator.canCopy", state, ctx)
           and Selectors:Call("styles.curator.moveApplies", state, ctx)
    end,
})

-- Button labels: "Move to <target>" / "Copy to <target>" (count lives in the
-- separate "N selected" label). No target yet -> bare verb (button disabled).
local function _curatorTargetName(state)
    local targetID = state.session.ui.styles.curator.selectedTargetID
    local target = targetID and (state.account.collections)[targetID]
    return target and target.displayName
end
Selectors:Register("styles.curator.moveButtonLabel", {
    reads = { "session.ui.styles.curator.selectedTargetID", "account.collections" },
    fn = function(state)
        local name = _curatorTargetName(state)
        return name and ("Move to " .. name) or "Move"
    end,
})
Selectors:Register("styles.curator.copyButtonLabel", {
    reads = { "session.ui.styles.curator.selectedTargetID", "account.collections" },
    fn = function(state)
        local name = _curatorTargetName(state)
        return name and ("Copy to " .. name) or "Copy"
    end,
})

-- Raw source itemIDs for the curator center grid by mode: all / unassigned
-- (no style membership) / style:<id> (that style's items). Observer rows are
-- released by construction -- no liveSet filter needed.
local function _curatorSourceIDs(state, mode, memberships)
    local sourceIDs = {}
    if mode == "all" then
        if HDG.HousingCatalogObserver:IsReady() then
            HDG.HousingCatalogObserver:IterateRows(function(itemID)
                sourceIDs[#sourceIDs + 1] = itemID
            end)
        end
    elseif mode == "unassigned" then
        if HDG.HousingCatalogObserver:IsReady() then
            HDG.HousingCatalogObserver:IterateRows(function(itemID)
                if not memberships[itemID] then sourceIDs[#sourceIDs + 1] = itemID end
            end)
        end
    elseif type(mode) == "string" and mode:sub(1, 6) == "style:" then
        local coll = state.account.collections[mode]
        if coll and coll.items then
            for _, itemID in ipairs(coll.items) do sourceIDs[#sourceIDs + 1] = itemID end
        end
    end
    return sourceIDs
end

-- User style-membership count for a curator tile's TOPLEFT badge, excluding the
-- current source style (viewing style:X shouldn't count X itself).
local function _curatorMemberCount(rawMemberships, mode)
    if not rawMemberships then return 0 end
    local sourceStyle = (mode:sub(1, 6) == "style:") and mode or nil
    local n = 0
    for _, sid in ipairs(rawMemberships) do
        if sid ~= sourceStyle then n = n + 1 end
    end
    return n
end

-- One curator source tile. Rich-tooltip fields (numStored/numPlaced/indoor/
-- outdoor) mirror acqVendorItemTile; the selector reads sweepGeneration so they
-- stay reactive.
local function _curatorSourceTile(itemID, row, name, iconTex, iconAtl, isSelected, catID, subID, memberCount)
    return {
        itemID            = itemID,
        name              = name,
        iconTexture       = iconTex,
        iconAtlas         = iconAtl,
        isSelected        = isSelected,
        categoryID        = catID,
        subcategoryID     = subID,
        memberCount       = memberCount,
        nameLower         = name:lower(),   -- sort key, once per tile (the comparator used to lowercase both sides per compare)
        numStored         = (row and row.quantity)  or 0,
        numPlaced         = (row and row.numPlaced) or 0,
        isAllowedIndoors  = row and row.isAllowedIndoors,
        isAllowedOutdoors = row and row.isAllowedOutdoors,
    }
end

-- Source items: center grid content by sourceMode (unassigned / all / style:<id>).
-- Observer rows are released by construction; no extra liveDecorIDs gate needed.
-- Category nav filters by categoryID / subcategoryID (nil = All).
Selectors:Register("styles.curator.sourceItems", {
    memoized = true,
    reads = {
        "session.ui.styles.curator.sourceMode",
        "session.ui.styles.curator.focusedCategoryID",
        "session.ui.styles.curator.focusedSubcategoryID",
        "session.ui.styles.curator.selectedItems",
        "session.ui.styles.curator.searchQuery",
        "account.collections",
        "session.styles.changeSeq",
        "session.resolvers.catalog.tick",
    },
    calls = { "styles.curator.itemMemberships" },
    fn = function(state, ctx)
        local cur      = state.session.ui.styles.curator
        local mode     = cur.sourceMode or "unassigned"
        local catFilt  = cur.focusedCategoryID     -- nil = All
        local subFilt  = cur.focusedSubcategoryID  -- nil = All
        local selected = cur.selectedItems
        local query    = cur.searchQuery:lower()
        -- Reverse index from itemMemberships; drives unassigned source + memberCount badge.
        local memberships = Selectors:Call("styles.curator.itemMemberships", state, ctx)

        -- Curator shows only owned (collected) decor (matches old HDG's editor gate).
        -- Ownership is orthogonal to style-membership; apply it to every mode.
        local ownedIDs = {}
        for _, itemID in ipairs(_curatorSourceIDs(state, mode, memberships)) do
            if HDG.HousingCatalogObserver:IsOwned(itemID) then ownedIDs[#ownedIDs + 1] = itemID end
        end

        -- Filter by numeric categoryID / subcategoryID (0 = synthetic "Uncategorized")
        -- + case-insensitive substring on the (sync, localized) catalog name.
        local out = {}
        for _, itemID in ipairs(ownedIDs) do
            local row   = HDG.HousingCatalogObserver:GetRow(itemID)
            local name  = (row and row.name) or ("Item " .. tostring(itemID))
            local catID = (row and row.categoryID)    or 0
            local subID = (row and row.subcategoryID) or 0
            local catOk  = (catFilt == nil) or (catFilt == catID)
            local subOk  = (subFilt == nil) or (subFilt == subID)
            local nameOk = (query == "") or (name:lower():find(query, 1, true) ~= nil)
            if catOk and subOk and nameOk then
                local iconTex, iconAtl = HDG.Format.CoerceIconPair(row and row.iconTexture, row and row.iconAtlas)
                local memberCount = _curatorMemberCount(memberships[itemID], mode)
                out[#out + 1] = _curatorSourceTile(itemID, row, name, iconTex, iconAtl,
                    selected[itemID] == true, catID, subID, memberCount)
            end
        end
        table.sort(out, function(a, b) return a.nameLower < b.nameLower end)
        return out
    end,
})

-- ===== Category icon nav (Blizzard category/subcategory rail) ===============
-- Icon-driven nav from the observer's category-tree snapshot.
-- storedOnly = true: only surfaces categories you own something in.
Selectors:Register("styles.curator.categoryIcons", {
    memoized = true,
    reads = {
        "session.house.categoryTree",
        "session.ui.styles.curator.focusedCategoryID",
        "session.ui.styles.curator.focusedSubcategoryID",
    },
    fn = function(state)
        local c = state.session.ui.styles.curator
        return HDG.CategoryNav.BuildCategories(
            state.session.house.categoryTree, c.focusedCategoryID, c.focusedSubcategoryID, true)
    end,
})
Selectors:Register("styles.curator.subcategoryChips", {
    memoized = true,
    reads = {
        "session.house.categoryTree",
        "session.ui.styles.curator.focusedCategoryID",
        "session.ui.styles.curator.focusedSubcategoryID",
    },
    fn = function(state)
        local c = state.session.ui.styles.curator
        return HDG.CategoryNav.BuildSubcategories(
            state.session.house.categoryTree, c.focusedCategoryID, c.focusedSubcategoryID, true)
    end,
})

-- (styles.curator.hasSubcategoryRow removed: subcategory strip always renders,
--  self-sizes to 0 when empty; gating caused a one-pass-late intrinsic-height blank.)

-- Coverage: owned items filed into at least one "style" collection.
-- { collectedInStyle, totalCollected, pct } for the coverage bar + footer.
Selectors:Register("styles.curator.coverage", {
    reads = {
        "account.collections",
        "account.collection.ownedDecorIDs",
        "session.styles.changeSeq",
        "session.resolvers.catalog.tick",
    },
    calls = { "styles.curator.itemMemberships" },
    fn = function(state, ctx)
        local memberships = Selectors:Call("styles.curator.itemMemberships", state, ctx)
        local owned       = state.account.collection.ownedDecorIDs
        local byDecorID   = HDG.HousingCatalogObserver.byDecorID
        local total, inStyle = 0, 0
        for decorID in pairs(owned) do
            local row    = byDecorID[decorID]
            local itemID = row and row.itemID
            if itemID then
                total = total + 1
                if memberships[itemID] then
                    inStyle = inStyle + 1
                end
            end
        end
        local pct = (total > 0) and (inStyle / total) or 0
        return { collectedInStyle = inStyle, totalCollected = total, pct = pct }
    end,
})

-- Scalar 0..1 for the ProgressBar binding (engine can't dot-traverse selector results).
Selectors:Register("styles.curator.coveragePct", {
    calls = { "styles.curator.coverage" },
    fn = function(state, ctx)
        local c = Selectors:Call("styles.curator.coverage", state, ctx)
        return (c and c.pct) or 0
    end,
})

-- "Coverage (collected): N of M in 1+ styles (NN%)" text for the footer.
Selectors:Register("styles.curator.coverageLabel", {
    calls = { "styles.curator.coverage" },
    fn = function(state, ctx)
        local c = Selectors:Call("styles.curator.coverage", state, ctx)
        local pct = math.floor((c.pct or 0) * 100 + 0.5)
        return string.format("Coverage (collected): %d of %d in 1+ styles (%d%%)",
            c.collectedInStyle, c.totalCollected, pct)
    end,
})

-- Unassigned count: OWNED items not in any user style (matches the owned-only
-- curator source). Warning-tone footer label.
Selectors:Register("styles.curator.unassignedCount", {
    memoized = true,
    reads = { "account.collections",
              "session.styles.changeSeq",
              "session.resolvers.catalog.tick", },
    calls = { "styles.curator.itemMemberships" },
    fn = function(state, ctx)
        if not HDG.HousingCatalogObserver:IsReady() then return 0 end
        local memberships = Selectors:Call("styles.curator.itemMemberships", state, ctx)
        local n = 0
        HDG.HousingCatalogObserver:IterateRows(function(itemID)
            -- Owned + not in any user style (mirrors the owned-only curator source).
            if not memberships[itemID] and HDG.HousingCatalogObserver:IsOwned(itemID) then
                n = n + 1
            end
        end)
        return n
    end,
})

Selectors:Register("styles.curator.unassignedCountLabel", {
    calls = { "styles.curator.unassignedCount" },
    fn = function(state, ctx)
        local n = Selectors:Call("styles.curator.unassignedCount", state, ctx)
        return string.format("%d unassigned", n)
    end,
})


-- Undo rows: recentUndo LIFO -> "Moved/Copied N items to <Style>". Most-recent first.
Selectors:Register("styles.curator.recentUndoRows", {
    reads = { "session.ui.styles.curator.recentUndo", "account.collections" },
    fn = function(state)
        local stack = state.session.ui.styles.curator.recentUndo
        local collections = state.account.collections
        local out = {}
        for i = #stack, 1, -1 do
            local entry = stack[i]
            local toName = "Unassigned"
            if entry.to and entry.to ~= "unassigned" then
                local coll = collections[entry.to]
                toName = (coll and coll.displayName) or entry.to
            end
            local n = entry.items and #entry.items or 0
            local verb = (entry.action == "copy") and "Copied" or "Moved"
            out[#out + 1] = {
                kind  = "stylesCuratorRecentRow",
                label = string.format("%s %d item%s to %s",
                            verb, n, n == 1 and "" or "s", toName),
                ord   = i,
            }
        end
        return out
    end,
})

-- Memberships hover panel: "style" collections containing the hovered item.
-- Placeholder "(unassigned)" row when item belongs to zero styles.
Selectors:Register("styles.curator.hoverMemberships", {
    reads = { "session.ui.styles.curator.hoverItemID", "account.collections" },
    calls = { "styles.curator.itemMemberships" },
    fn = function(state, ctx)
        local itemID = state.session.ui.styles.curator.hoverItemID
        if not itemID then return {} end
        local memberships = Selectors:Call("styles.curator.itemMemberships", state, ctx)
        local collections = state.account.collections
        local belongs = memberships[itemID]
        if not belongs or #belongs == 0 then
            return { { kind = "stylesCuratorMembershipRow",
                       label = "(unassigned)", isPlaceholder = true } }
        end
        local out = {}
        for _, id in ipairs(belongs) do
            local coll = collections[id]
            out[#out + 1] = {
                kind  = "stylesCuratorMembershipRow",
                label = (coll and coll.displayName) or id,
                collectionID = id,
            }
        end
        table.sort(out, function(a, b)
            return tostring(a.label):lower() < tostring(b.label):lower()
        end)
        return out
    end,
})

-- Bare source mode value for dropdown binding.current.
-- Trigger text auto-renders from the selected radio (DropdownSelectionTextMixin).
Selectors:Register("styles.curator.sourceMode", {
    reads = { "session.ui.styles.curator.sourceMode" },
    fn    = function(state)
        return state.session.ui.styles.curator.sourceMode or "unassigned"
    end,
})

-- Source dropdown menu: title + two radios (Unassigned / All) + divider +
-- per-user-style radios. Values are collectionID strings for STYLES_CURATOR_SET_SOURCE.
Selectors:Register("styles.curator.sourceMenuItems", {
    calls = { "styles.curator.targetRows" },
    fn = function(state, ctx)
        local items = {
            { kind = "title", text = "Source" },
            { text = "Unassigned", value = "unassigned" },
            { text = "All Items",  value = "all"        },
        }
        -- Admit only real collection rows; exclude the empty-state placeholder and
        -- the synthetic stylesCuratorTargetActionsRow (which has no count and
        -- leaked as a phantom duplicate).
        local targets = Selectors:Call("styles.curator.targetRows", state, ctx)
        local realTargets = {}
        for _, row in ipairs(targets) do
            if row.kind == "stylesCuratorTargetRow" and not row.empty then
                realTargets[#realTargets + 1] = row
            end
        end
        if #realTargets > 0 then
            items[#items + 1] = { kind = "divider" }
            items[#items + 1] = { kind = "title", text = "User Styles" }
            for _, row in ipairs(realTargets) do
                items[#items + 1] = {
                    text  = string.format("%s (%d)", row.displayName or row.collectionID, row.count),  -- styles.userCollections stamps count (coerced)
                    value = row.collectionID,
                }
            end
        end
        return items
    end,
})


-- "N selected" text for the multi-select indicator; blank when nothing is
-- selected (multi-select is just click-multiple, so no hint needed).
Selectors:Register("styles.curator.selectedCountLabel", {
    calls = { "styles.curator.selectedCount" },
    fn = function(state, ctx)
        local n = Selectors:Call("styles.curator.selectedCount", state, ctx)
        if n == 0 then return "" end
        return string.format("%d selected", n)
    end,
})

-- ===== Smart Set Builder ====================================================
-- Draft-field passthroughs for editbox bindings (engine can't dot-traverse results).
Selectors:DefinePath("styles.smartset.draft.displayName",
                     "session.ui.styles.smartset.draft.displayName")
Selectors:DefinePath("styles.smartset.draft.description",
                     "session.ui.styles.smartset.draft.description")
Selectors:DefinePath("styles.smartset.activeAxis",
                     "session.ui.styles.smartset.activeAxis")
Selectors:DefinePath("styles.smartset.activeSeverity",
                     "session.ui.styles.smartset.activeSeverity")
Selectors:DefinePath("styles.smartset.rules",
                     "session.ui.styles.smartset.rules")
Selectors:DefinePath("styles.smartset.dirty",
                     "session.ui.styles.smartset.dirty")

-- Severity tab chip active-state selectors.
-- "all" = UI-only filter (everything except clashing); not a band value.
Selectors:DefineEnum("styles.smartset.isSeverity",
                     "session.ui.styles.smartset.activeSeverity",
                     { "all", "signature", "accent", "versatile", "clashing" })

-- Fixed facet-axis taxonomy (display order). Freeform removed (no FacetDB taxonomy).
local SMARTSET_AXES = {
    "room", "category", "subject", "mood", "material", "color", "culture",
    "motif", "formality", "condition", "light", "palette", "seasonal",
}

-- axisRows: 14-axis list with isActive flags + per-axis touched-tag count.
Selectors:Register("styles.smartset.axisRows", {
    reads = {
        "session.ui.styles.smartset.activeAxis",
        "session.ui.styles.smartset.rules",
    },
    fn = function(state)
        local active = state.session.ui.styles.smartset.activeAxis or "room"
        local rules  = state.session.ui.styles.smartset.rules
        local out = {}
        for i, axis in ipairs(SMARTSET_AXES) do
            local n = 0
            for _ in pairs(rules[axis] or {}) do n = n + 1 end
            out[i] = {
                kind     = "stylesAxisRow",
                axis     = axis,
                label    = axis:sub(1, 1):upper() .. axis:sub(2),
                isActive = active == axis,
                tagCount = n,
            }
        end
        return out
    end,
})

-- ===== Tag taxonomy + per-axis counts ======================================
-- FacetDB encoding keys: axis name -> per-item encoding field.
local FACETDB_ENC_KEYS = {
    room     = "rm",  category = "cat", subject   = "sub", mood     = "mod",
    material = "mat", color    = "col", culture   = "cul", motif    = "mot",
    formality= "frm", condition= "con", light     = "lit", palette  = "pal",
    seasonal = "sea",
}

-- Walk FacetDB: visitorFn(axisName, tagStr, itemID) per (axis x tag x item).
-- rec[encKey] is a table of vocab indices (multi-tag) or a single number index.
-- _visitRecordTags extracted so the outer loop is a flat axis x item double-loop.
local function _visitRecordTags(axisVocab, axisName, itemID, v, visitorFn)
    if type(v) == "table" then
        for _, idx in ipairs(v) do
            local tagStr = axisVocab[idx]
            if tagStr then visitorFn(axisName, tagStr, itemID) end
        end
    elseif type(v) == "number" then
        local tagStr = axisVocab[v]
        if tagStr then visitorFn(axisName, tagStr, itemID) end
    end
end

local function _walkFacetDB(visitorFn)
    local vocab = HDG.StaticData.Facets:GetVocab()
    local db    = HDG.StaticData.Facets:GetAll()
    if not (vocab and db) then return false end
    for axisName, encKey in pairs(FACETDB_ENC_KEYS) do
        local axisVocab = vocab[axisName]
        if axisVocab then
            for itemID, rec in pairs(db) do
                _visitRecordTags(axisVocab, axisName, itemID, rec[encKey], visitorFn)
            end
        end
    end
    return true
end

-- Reverse facet index built in ONE FacetDB walk. Lazy, keyed on changeSeq
-- (ADR-003a carve-out). Tag tallies from #_reverseIndex[axis][tag]. The
-- scorer reads each item's ENCODED record straight from FacetDB (rules are
-- translated to vocab indices once per resolve); a decoded per-item copy of
-- every facet used to sit beside this index for the session, 23,000 tables
-- duplicating the shipped data (2026-09-13 audit).
local _reverseIndex   = {}     -- [axis] = { [tagStr] = { itemID, ... } }
local _facetIdxTick   = nil
local _EMPTY          = {}

local function _ensureFacetIndexes()
    local tick = HDG.Store:GetState().session.styles.changeSeq  -- seeded by NewStylesSession
    if _facetIdxTick == tick and next(_reverseIndex) then return end
    _reverseIndex, _facetIdxTick = {}, tick
    _walkFacetDB(function(axisName, tagStr, itemID)
        local ax = _reverseIndex[axisName]
        if not ax then ax = {}; _reverseIndex[axisName] = ax end
        local list = ax[tagStr]
        if not list then list = {}; ax[tagStr] = list end
        list[#list + 1] = itemID
    end)
end

-- [axis][tagStr] = vocab index, the inverse of HDGR_FacetVocab, built once per
-- vocab table (static shipped data).
local _tagIndexVocab, _tagIndexMap = nil, nil
local function _tagIndexOf(vocab)
    if _tagIndexVocab == vocab then return _tagIndexMap end
    local map = {}
    for axis, list in pairs(vocab) do
        local m = {}
        for idx, tagStr in pairs(list) do m[tagStr] = idx end
        map[axis] = m
    end
    _tagIndexVocab, _tagIndexMap = vocab, map
    return map
end

-- Does this FacetDB record carry at least one tag the vocab knows? Items that
-- carry none are not scored (they were never indexed before either).
local function _hasAnyFacet(rec, vocab)
    for axisName, encKey in pairs(FACETDB_ENC_KEYS) do
        local v, axisVocab = rec[encKey], vocab[axisName]
        if axisVocab then
            if type(v) == "table" then
                for i = 1, #v do if axisVocab[v[i]] then return true end end
            elseif type(v) == "number" and axisVocab[v] then
                return true
            end
        end
    end
    return false
end

-- Number of vocab-known tags an item carries on one axis, or nil when it has none.
local function _axisTagCount(v, axisVocab)
    if type(v) == "table" then
        local n = 0
        for i = 1, #v do if axisVocab[v[i]] then n = n + 1 end end
        return n > 0 and n or nil
    elseif type(v) == "number" and axisVocab[v] then
        return 1
    end
    return nil
end

-- activeAxisTags: tag rows for the middle column.
-- { kind, tag, label, count, severity, affinityPct, _axis } per tag.
-- severity = "signature" | "accent" | "clashing" (nil = untouched).
-- affinityPct = co-occurrence % vs current signature set.
Selectors:Register("styles.smartset.activeAxisTags", {
    reads = {
        "session.resolvers.staticData.tick",  -- ADR-003c StaticData marker (sweep rule 4c)
        "session.ui.styles.smartset.activeAxis",
        "session.ui.styles.smartset.rules",
        "session.styles.changeSeq",
    },
    calls = { "styles.smartset.affinity" },
    fn = function(state, ctx)
        local axis  = state.session.ui.styles.smartset.activeAxis or "room"
        local rules = state.session.ui.styles.smartset.rules
        local axisRules = rules[axis] or {}

        local vocab = HDG.StaticData.Facets:GetVocab()
        local axisVocab = vocab and vocab[axis]
        if not axisVocab then return {} end

        _ensureFacetIndexes()
        local axisIndex = _reverseIndex[axis] or _EMPTY
        local affinity  = Selectors:Call("styles.smartset.affinity", state, ctx)

        local out = {}
        for _, tagStr in pairs(axisVocab) do
            out[#out + 1] = {
                kind        = "stylesTagRow",
                tag         = tagStr,
                label       = tagStr,
                count       = #(axisIndex[tagStr] or _EMPTY),
                severity    = axisRules[tagStr],
                affinityPct = affinity[tagStr],   -- nil when no co-occurrence data
                _axis       = axis,
            }
        end
        -- Sort: rules-touched first (alphabetical within), then untouched by desc count.
        table.sort(out, function(a, b)
            local aSet = a.severity ~= nil
            local bSet = b.severity ~= nil
            if aSet ~= bSet then return aSet end
            if aSet then return a.label < b.label end
            if a.count ~= b.count then return a.count > b.count end
            return a.label < b.label
        end)
        return out
    end,
})

-- ===== Statistical scorer ===================================================
-- Scores the whole catalog against the query. Items penalized for conflicting
-- values in queried axes. Tiers: score>=1 -> signature; >0 -> accent; <0 ->
-- clashing; ==0 -> no band. boost/anti scored too (pre-authored Room Concepts).
local QUERY_WEIGHT, BOOST_WEIGHT, ANTI_WEIGHT = 1.0, 0.15, -0.3
local TIER_FIRST, TIER_SECOND = 1.0, 0.5   -- TIER_NEUTRAL = 0.0 (implicit clashing floor)

-- Convert rules[axis][tag]=severity -> {query/boost/anti} def shape for _scoreItem,
-- with every tag as its VOCAB INDEX so the scorer compares against the encoded
-- record directly. A tag the vocab does not know becomes index 0: it still
-- counts toward the query's size and can never match, as before.
local _SEV_FIELD = { signature = "query", accent = "boost", clashing = "anti" }
local function _rulesToDef(rules, tagIndex)
    local def = {}
    for axis, tagRules in pairs(rules or {}) do
        local axisTags = tagIndex[axis] or _EMPTY
        for tag, sev in pairs(tagRules) do
            local field = _SEV_FIELD[sev]
            if field then
                local f = def[field]; if not f then f = {}; def[field] = f end
                local list = f[axis]; if not list then list = {}; f[axis] = list end
                list[#list + 1] = axisTags[tag] or 0
            end
        end
    end
    return def
end

-- Does the encoded axis value (one index or a list) carry `idx`?
local function _hasIdx(v, idx)
    if type(v) == "table" then
        for i = 1, #v do if v[i] == idx then return true end end
        return false
    end
    return v == idx
end

-- Boolean intersection for boost/anti predicates.
local function _intersects(v, idxs)
    for i = 1, #idxs do
        if _hasIdx(v, idxs[i]) then return true end
    end
    return false
end

-- Count query matches for one axis: hits, total (#qidxs), itemCount (tags the item carries).
local function _intersectCount(v, qidxs, itemCount)
    if not itemCount then return 0, #qidxs, 0 end
    local hits = 0
    for i = 1, #qidxs do
        if _hasIdx(v, qidxs[i]) then hits = hits + 1 end
    end
    return hits, #qidxs, itemCount
end

-- Score one FacetDB record against a def. query = linear proportion x specificity;
-- non-matching value in a queried axis scores ANTI_WEIGHT.
-- Normalized by query-facet count so tiers stay stable as facets are added.
local function _scoreItem(rec, def, vocab)
    local score, queryHits, queryTotal = 0, 0, 0
    if def.query then
        for axis, qvals in pairs(def.query) do
            queryTotal = queryTotal + 1
            local fvals = rec[FACETDB_ENC_KEYS[axis]]
            local hits, total, itemCount = _intersectCount(fvals, qvals, _axisTagCount(fvals, vocab[axis] or _EMPTY))
            if hits > 0 then
                if hits == total then
                    local spec = math.min(1, total * 2 / itemCount)
                    score = score + QUERY_WEIGHT * spec
                    if spec >= 1 then queryHits = queryHits + 1 end  -- full focused match
                else
                    score = score + QUERY_WEIGHT * (hits / total) * math.min(1, total / itemCount)
                end
            elseif itemCount > 0 then
                score = score + ANTI_WEIGHT
            end
        end
    end
    if def.boost then
        for axis, bvals in pairs(def.boost) do
            if _intersects(rec[FACETDB_ENC_KEYS[axis]], bvals) then score = score + BOOST_WEIGHT end
        end
    end
    if def.anti then
        for axis, avals in pairs(def.anti) do
            if _intersects(rec[FACETDB_ENC_KEYS[axis]], avals) then score = score + ANTI_WEIGHT end
        end
    end
    if queryTotal > 0 then score = score / queryTotal end
    return score, queryHits
end

-- Band classification (four bands, nothing excluded):
--   signature: score >= TIER_FIRST
--   clashing:  score < 0
--   accent:    queryHits > 0 OR score >= TIER_SECOND
--   versatile: the rest (lacks the queried facet; neither match nor clash)
local function _bandFor(score, queryHits)
    if score >= TIER_FIRST then return "signature" end
    if score < 0           then return "clashing"  end
    if queryHits > 0 or score >= TIER_SECOND then return "accent" end
    return "versatile"
end

-- Resolve rules -> scored[itemID] = { score, band, hasClashing, signatureHits }.
-- opts.liveSet restricts to released catalog items. Empty when no rules are set.
_resolveSmartsetItems = function(rules, opts)
    local liveSet = opts and opts.liveSet
    local scored  = {}
    local stats   = { signature = 0, accent = 0, versatile = 0, clashing = 0, total = 0 }
    local vocab = HDG.StaticData.Facets:GetVocab()
    local db    = HDG.StaticData.Facets:GetAll()
    if not (vocab and db) then return scored, stats end
    local def = _rulesToDef(rules, _tagIndexOf(vocab))
    if not (def.query or def.boost or def.anti) then return scored, stats end

    for itemID, rec in pairs(db) do
        if (not liveSet or liveSet[itemID]) and _hasAnyFacet(rec, vocab) then
            local score, queryHits = _scoreItem(rec, def, vocab)
            local band = _bandFor(score, queryHits)
            scored[itemID] = {
                score = score, band = band,
                hasClashing   = (band == "clashing"),
                signatureHits = (band == "signature") and 1 or 0,
            }
            stats[band] = stats[band] + 1
        end
    end
    -- "matching" = signature + accent (positive matches); versatile = neutral; clashing = reject.
    stats.total = stats.signature + stats.accent
    return scored, stats
end

-- Co-occurrence affinity: each tag's % in the current signature match set.
-- Nil when match set < 5 (too few for a meaningful read).
local function _addItems(set, items)
    local added = 0
    for _, itemID in ipairs(items) do
        if not set[itemID] then set[itemID] = true; added = added + 1 end
    end
    return added
end

local function _unionSignatureItems(rules)
    local set, count = {}, 0
    for raxis, tagRules in pairs(rules or {}) do
        local axisIndex = _reverseIndex[raxis]
        for tag, sev in pairs(tagRules) do
            local items = sev == "signature" and axisIndex and axisIndex[tag]
            if items then count = count + _addItems(set, items) end
        end
    end
    return set, count
end

local function _computeTagAffinity(rules, axis)
    local matchSet, matchCount = _unionSignatureItems(rules)
    if matchCount < 5 then return nil end
    local freq = {}
    local db        = HDG.StaticData.Facets:GetAll()
    local axisVocab = HDG.StaticData.Facets:GetVocab()[axis] or _EMPTY
    local encKey    = FACETDB_ENC_KEYS[axis]
    for itemID in pairs(matchSet) do
        local rec = db[itemID]
        local v = rec and rec[encKey]   -- exception(nullable): the reverse index only names FacetDB items, but a nil record is a legal miss
        if type(v) == "table" then
            for i = 1, #v do
                local tag = axisVocab[v[i]]
                if tag then freq[tag] = (freq[tag] or 0) + 1 end
            end
        elseif type(v) == "number" then
            local tag = axisVocab[v]
            if tag then freq[tag] = (freq[tag] or 0) + 1 end
        end
    end
    local pct = {}
    for tag, c in pairs(freq) do pct[tag] = math.floor(c / matchCount * 100 + 0.5) end
    return pct
end

-- Memoized resolver: Store invalidates on reads; this avoids re-running across consumers.
-- liveSet pushed into _resolveSmartsetItems so unreleased items are excluded once.
Selectors:Register("styles.smartset._resolved", {
    memoized = true,
    reads = {
        "session.ui.styles.smartset.rules",
        "session.styles.changeSeq",
        "session.resolvers.catalog.tick",   -- liveSet (observer byItemID) changes on sweep
    },
    fn = function(state, ctx)
        local rules = state.session.ui.styles.smartset.rules
        -- liveSet = observer.byItemID (released-by-construction).
        -- FacetDB carries data-mined unreleased items; filtering here keeps band counts consistent.
        local scored, stats = _resolveSmartsetItems(rules, {
            liveSet = HDG.HousingCatalogObserver.byItemID,
        })
        return { scored = scored, stats = stats }
    end,
})

-- One preview row per itemID with name + icon from the observer.
local function _itemRow(itemID, state, scoreInfo)
    local row  = HDG.HousingCatalogObserver:GetRow(itemID)
    local name = (row and row.name) or ("Item " .. tostring(itemID))
    local iconTex, iconAtl = HDG.Format.CoerceIconPair(
        row and row.iconTexture, row and row.iconAtlas)
    return {
        itemID      = itemID,
        name        = name,
        iconTexture = iconTex,
        iconAtlas   = iconAtl,
        score       = scoreInfo.score,
        band        = scoreInfo.band,
    }
end

-- previewItems: rows for the center preview grid filtered by activeSeverity.
-- "all" = signature + accent; "clashing" = items excluded by clashing rules.
Selectors:Register("styles.smartset.previewItems", {
    reads = {
        "session.ui.styles.smartset.activeSeverity",
        "session.resolvers.catalog.tick",
    },
    calls = { "styles.smartset._resolved" },
    fn = function(state, ctx)
        local tab = state.session.ui.styles.smartset.activeSeverity or "all"
        local resolved = Selectors:Call("styles.smartset._resolved", state, ctx)
        local scored = resolved.scored
        local out = {}
        for itemID, info in pairs(scored) do
            local inBand
            if tab == "all" then
                inBand = info.band ~= "clashing"   -- signature + accent + versatile (all non-clashing)
            else
                inBand = info.band == tab
            end
            if inBand then
                out[#out + 1] = _itemRow(itemID, state, info)
            end
        end
        -- Sort: signature first, then by descending score, then by name.
        table.sort(out, function(a, b)
            if a.band ~= b.band then
                if a.band == "signature" then return true  end
                if b.band == "signature" then return false end
                if a.band == "accent"    then return true  end
                if b.band == "accent"    then return false end
            end
            if a.score ~= b.score then return a.score > b.score end
            return tostring(a.name):lower() < tostring(b.name):lower()
        end)
        return out
    end,
})

Selectors:Register("styles.smartset.matchingCount", {
    calls = { "styles.smartset._resolved" },
    fn = function(state, ctx)
        return Selectors:Call("styles.smartset._resolved", state, ctx).stats.total
    end,
})

-- Per-band tab labels: "Signature (68)" etc. One selector per band.
local _BAND_LABELS = { signature = "Signature", accent = "Accent",
                       versatile = "Versatile", clashing = "Clashing" }
for band, pretty in pairs(_BAND_LABELS) do
    Selectors:Register("styles.smartset.bandLabel_" .. band, {
        calls = { "styles.smartset._resolved" },
        fn = function(state, ctx)
            local stats = Selectors:Call("styles.smartset._resolved", state, ctx).stats
            return string.format("%s (%d)", pretty, stats[band])
        end,
    })
end

-- Co-occurrence affinity { [tag] = pct } for the tag column hints (green >= 40%, red <= 5%).
Selectors:Register("styles.smartset.affinity", {
    memoized = true,
    reads = {
        "session.ui.styles.smartset.rules",
        "session.ui.styles.smartset.activeAxis",
        "session.styles.changeSeq",
    },
    fn = function(state)
        _ensureFacetIndexes()
        local axis = state.session.ui.styles.smartset.activeAxis or "room"
        return _computeTagAffinity(state.session.ui.styles.smartset.rules, axis) or _EMPTY
    end,
})

-- ===== Snapshot + Import selectors ========================================
-- placedCount: distinct catalog items with numPlaced > 0. Drives Save button enable.
-- Re-runs on sweepGeneration (button enables once catalog loads).
Selectors:Register("styles.snapshot.placedCount", {
    reads = { "session.resolvers.catalog.tick" },
    fn = function(state)
        local _ = state.session.resolvers.catalog.tick   -- force re-run on catalog sweep
        if not HDG.HousingCatalogObserver:IsReady() then return 0 end
        local n = 0
        HDG.HousingCatalogObserver:IterateRows(function(_, row)
            if (row.numPlaced or 0) > 0 then n = n + 1 end  -- exception(boundary): catalog struct field sparse
        end)
        return n
    end,
})

Selectors:Register("styles.snapshot.canSave", {
    calls = { "styles.snapshot.placedCount" },
    fn = function(state, ctx)
        return (Selectors:Call("styles.snapshot.placedCount", state, ctx)) > 0
    end,
})

-- Import passthroughs.
Selectors:DefinePath("styles.import.urlText",     "session.ui.styles.import.urlText")
Selectors:DefinePath("styles.import.parseError",  "session.ui.styles.import.parseError")
Selectors:DefinePath("styles.import.previewItems","session.ui.styles.import.previewItems")
-- Editable title editbox value. Coalesce nil -> "" so the box clears on reset
-- (dispatchEditbox skips a nil value, which would leave stale text).
Selectors:Register("styles.import.title", {
    reads = { "session.ui.styles.import.parseDisplayName" },
    fn = function(state)
        return state.session.ui.styles.import.parseDisplayName or ""  -- exception(nullable): parseDisplayName cleared to nil on reset/commit; coalesce so the editbox clears
    end,
})
-- Destination radio: which surface Import lands in. Default "style" (My Styles).
Selectors:DefinePath("styles.import.destination", "session.ui.styles.import.destination")
Selectors:Register("styles.import.destinationItems", {
    reads    = {},
    memoized = true,
    fn = function()
        return {
            { text = "My Styles",     value = "style" },
            { text = "Project Set",   value = "set" },
            { text = "Shopping List", value = "shopping" },
        }
    end,
})

-- previewRows: previewItems int-array -> scrollbox rows with name/icon from catalog.
Selectors:Register("styles.import.previewRows", {
    reads = {
        "session.ui.styles.import.previewItems",
        "session.resolvers.catalog.tick",
    },
    fn = function(state)
        local items = state.session.ui.styles.import.previewItems
        if not (items and #items > 0) then return {} end
        local out = {}
        for _, itemID in ipairs(items) do
            local row     = HDG.HousingCatalogObserver:GetRow(itemID)
            local iconTex, iconAtl = HDG.Format.CoerceIconPair(
                row and row.iconTexture, row and row.iconAtlas)
            out[#out + 1] = {
                kind        = "stylesImportPreviewRow",
                itemID      = itemID,
                name        = (row and row.name) or ("Item " .. tostring(itemID)),
                iconTexture = iconTex,
                iconAtlas   = iconAtl,
                isKnown     = row ~= nil,
            }
        end
        return out
    end,
})

Selectors:Register("styles.import.canCommit", {
    reads = { "session.ui.styles.import.previewItems" },
    fn = function(state)
        local items = state.session.ui.styles.import.previewItems
        return items and #items > 0 or false
    end,
})

-- statusLabel: shows the current parse state ("No items yet" / "N items
-- parsed" / "Error: <text>"). Drives the import.statusRow binding.
Selectors:Register("styles.import.statusLabel", {
    reads = {
        "session.ui.styles.import.previewItems",
        "session.ui.styles.import.parseError",
        "session.ui.styles.import.parseUnmatched",
        "session.ui.styles.import.urlText",
    },
    fn = function(state)
        local s = state.session.ui.styles.import
        if s.parseError then return "Error: " .. tostring(s.parseError) end
        if s.previewItems and #s.previewItems > 0 then
            local matched   = #s.previewItems
            local unmatched = s.parseUnmatched or 0
            if unmatched > 0 then
                -- N of M matched; the rest aren't in the live catalog (e.g. unreleased decor).
                return string.format("%d of %d matched -- %d not in live catalog, may be unreleased items",
                                      matched, matched + unmatched, unmatched)
            end
            return string.format("%d item%s parsed", matched, matched == 1 and "" or "s")
        end
        if s.urlText and s.urlText ~= "" then return "Reading..." end
        return ""
    end,
})

-- canSave: draft needs a name + at least one rule.
Selectors:Register("styles.smartset.canSave", {
    reads = {
        "session.ui.styles.smartset.draft.displayName",
        "session.ui.styles.smartset.rules",
        "session.ui.styles.smartset.dirty",
    },
    fn = function(state)
        local s = state.session.ui.styles.smartset
        local name = (s.draft and s.draft.displayName) or ""
        if name:gsub("%s", "") == "" then return false end
        local hasRules = false
        for _, tags in pairs(s.rules or {}) do
            for _ in pairs(tags) do hasRules = true; break end
            if hasRules then break end
        end
        return hasRules
    end,
})

-- isEmpty: no rules set yet.
Selectors:Register("styles.smartset.isEmpty", {
    reads = { "session.ui.styles.smartset.rules" },
    fn = function(state)
        local rules = state.session.ui.styles.smartset.rules
        for _, tags in pairs(rules) do
            for _ in pairs(tags) do return false end
        end
        return true
    end,
})

Selectors:Register("styles.smartset.hintLabel", {
    calls = { "styles.smartset.isEmpty", "styles.smartset.matchingCount" },
    fn = function(state, ctx)
        if Selectors:Call("styles.smartset.isEmpty", state, ctx) then
            return "Select tags to see preview"
        end
        local n = Selectors:Call("styles.smartset.matchingCount", state, ctx)
        return string.format("%d matching", n)
    end,
})

-- "N selected" count for the Move button.
Selectors:Register("styles.curator.selectedCount", {
    reads = { "session.ui.styles.curator.selectedCount" },
    fn = function(state)
        return state.session.ui.styles.curator.selectedCount
    end,
})

-- Undo button enabled state.
Selectors:Register("styles.curator.canUndo", {
    reads = { "session.ui.styles.curator.recentUndo" },
    fn = function(state)
        local r = state.session.ui.styles.curator.recentUndo
        return r and #r > 0 or false
    end,
})

-- "N shown" tail for the source-items header.
Selectors:Register("styles.curator.sourceCountLabel", {
    calls = { "styles.curator.sourceItems" },
    fn = function(state, ctx)
        local items = Selectors:Call("styles.curator.sourceItems", state, ctx)
        local n = #items
        return string.format("%d shown", n)
    end,
})

-- Hero header label: collection count placeholder (future: per-collection stats).
Selectors:Register("styles.landing.heroLabel", {
    reads = { "session.styles.changeSeq", "account.collections" },
    calls = { "styles.collectionsByType" },   -- transitively reads account.vendorShoppingLists
    fn = function(state)
        local counts = Selectors:Call("styles.collectionsByType", state, {})
        local total = 0
        for _, n in pairs(counts) do total = total + n end
        return string.format("%d collection%s", total, total == 1 and "" or "s")
    end,
})

-- Total-styles-shown label ("67 styles"). Updates as filter changes.
Selectors:Register("styles.landing.totalStylesLabel", {
    reads = {
        "session.ui.styles.landing.filter",
        "account.collections",
        "session.styles.changeSeq",
    },
    calls = { "styles.collectionsByType" },   -- transitively reads account.vendorShoppingLists
    fn = function(state)
        local filter = state.session.ui.styles.landing.filter or "all"
        local counts = Selectors:Call("styles.collectionsByType", state, {})
        local n
        if filter == "all" then
            n = 0
            for _, c in pairs(counts) do n = n + c end
        else
            n = counts[filter] or 0  -- exception(boundary): sparse map
        end
        return string.format("%d %s", n, n == 1 and "style" or "styles")
    end,
})
