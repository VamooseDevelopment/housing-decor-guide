-- HDG.Store
-- ============================================================================
-- Single Source of Truth for refactor state. Pure-dispatch architecture (no
-- imperative setters -- everything flows through Dispatch -> reducer).
--
-- State shape:
--   account.* -- persisted to HDG_DB. PersistenceMiddleware writes on every
--                dispatch whose action declares `persists = true` in
--                Core/HDGR_Init's BuildActionMeta.
--   session.* -- transient. Reset on every /reload.
--
-- Pure-dispatch architecture (no imperative setters -- everything flows
-- through Dispatch -> reducer). See HDGR_ARCHITECTURE.md for ADRs.

HDG = HDG or {}

-- ===== State constructors =====================================================

-- Canonical deep copy lives in HDG.TableUtils (cycle-aware, metatable-
-- preserving); the private clone this file carried was a strict subset
-- (hygiene review A'2). TOC loads TableUtils first.
local DeepCopy = HDG.TableUtils.DeepCopy

local function NewConfig()
    return {
        debug              = false,
        mockTSM            = false,   -- debug: mock TSM as the price source (flat 100g)
        -- showMinimapButton: show/hide the LibDBIcon minimap button. Toggled by BOTH
        -- the Settings-panel checkbox and /hdgr minimap; subscriber in
        -- HDGR_MinimapButton forwards to LibDBIcon. (Single flag -- the old separate
        -- showMinimap flag was an oversight; collapsed 2026-06-07.)
        showMinimapButton  = true,
        scheme             = HDG.Constants.DEFAULT_SCHEME,
        -- decorPreviewBg: 3D-preview background for the decor browser. "default" =
        -- the dark bgTile backdrop (no atlas); other values are housing-bg atlas names.
        decorPreviewBg     = "default",
        -- UI scale: HDG window only (NOT the global UI scale CVar).
        -- Subscriber in HDGR_Window forwards account.config.scale changes
        -- to MainFrame:SetScale. Range 0.5 -- 1.5 (clamped at write).
        scale              = 1.0,
        -- fontFamily: addon-text font face. "default" = the client's per-locale
        -- STANDARD_TEXT_FONT (glyph-complete everywhere); "arialn" = Arial Narrow
        -- (crisper sub-12px, also carries Cyrillic). Both are glyph-safe on every
        -- locale -- Theme:BuildFontObjects resolves the face, subscriber re-applies live.
        fontFamily         = "default",
        -- Locale follows the same generic CONFIG_SET { key, value } dispatch
        -- pattern as scheme. HDGR_Locale subscribes to invalidation on this
        -- path and forwards to Locale:SetLocale + RefreshMainWindow.
        -- Default sentinel "" means "use GetLocale() at first read"; a
        -- player picking a locale from the Config dropdown stamps a real
        -- value here that survives /reload.
        locale             = "",
        -- Price source preference.
        -- preferredPriceAddon: nil | "TSM" | "Auctionator" | "Direct"
        --   nil  -- fall back chain: TSM > Auctionator > Direct cache > Vendor
        --   "X"  -- force a specific source (with vendor fallback at the end)
        -- tsmPriceMode: "min" | "market" | "region"
        --   "min"     -> DBMinBuyout       (cheapest current)
        --   "market"  -> DBMarket          (TSM-derived market)
        --   "region"  -> DBRegionSaleAvg   (cross-realm sale average)
        preferredPriceAddon = nil,
        tsmPriceMode        = "min",
        -- Zone Scanner config. Master toggle gates the alert engine entirely;
        -- the sub-flags fan out which surfaces fire on a hit.
        zoneScannerEnabled = true,
        zoneScannerPopup   = false,
        zoneScannerPopupShopping = false,   -- popup for shopping-list items specifically
        zoneScannerChat    = true,
        zoneScannerSound   = false,
        -- tooltipDecorTag: show the HDG catalog line on item tooltips.
        tooltipDecorTag        = true,
        -- catalogTooltip: append HDG's decor-sourcing block to the Housing
        -- catalog hover tooltip (HDG.CatalogTooltip). Surfaced under Helpers.
        catalogTooltip         = true,
        -- bagBadge: mark decor-reagent bag slots with the HDG logo (Helpers).
        bagBadge               = true,
        -- merchantDecorOverlay: mark vendor decor with collected/needed icons (Helpers > Vendors).
        merchantDecorOverlay   = true,
        -- merchantQtyPicker: right-click decor at a vendor -> quantity picker (Helpers > Vendors).
        -- Ships OFF (opt-in): the picker changes right-click behaviour on every vendor decor row.
        merchantQtyPicker      = false,
        -- materialTooltipItemData: render Blizzard's item tooltip above HDG's stock
        -- roster on material rows, which also lets other addons' item-data processors
        -- add their lines there. Ships OFF -- it makes every material hover much
        -- taller, the reason those rows were title-only to begin with.
        materialTooltipItemData = false,
        -- catalogDecorOverlay: red plus on uncollected decor in Blizzard's catalog (Helpers > Catalog).
        catalogDecorOverlay    = true,
        -- autoDepositLumber: on a banker open with Warband Bank access, move all
        -- lumber from bags into the Warband Bank (Helpers > Lumber). Opt-in default
        -- OFF -- it moves the player's items.
        autoDepositLumber      = false,
        -- hideInCombat: auto-hide all HDG windows on entering combat (restore on exit).
        hideInCombat           = true,
        -- showCompartment: gate the AddonCompartment click/enter handlers.
        -- NOTE: the TOC AddonCompartmentFunc directive always registers the
        -- icon in Blizzard's compartment drawer; this flag only disables the
        -- click and tooltip handlers. Users who want the icon removed must
        -- use Blizzard's own Edit Mode. Documented limitation.
        showCompartment        = true,
        -- showProfessionButtons: inject "Decor Guide" + "Filter Decor"
        -- buttons into ProfessionsFrame. Subscriber in HDGR_ProfessionButtons.
        showProfessionButtons  = true,
        -- waypointProvider: "auto" | "tomtom" | "blizzard"
        --   "auto"     -> TomTom if loaded, else Blizzard (existing behaviour)
        --   "tomtom"   -> TomTom if available; warns and falls back to Blizzard
        --   "blizzard" -> always Blizzard, TomTom ignored
        waypointProvider       = "auto",
        -- minimapPos: LibDBIcon's own db table (position angle + .hide flag).
        -- Seeded here so MinimapButton hands LibDBIcon a stable, HDG_DB-
        -- persisted table with no lazy `or {}` guard. LibDBIcon writes
        -- .minimapPos on drag and reads .hide on login -- external boundary;
        -- HDG only syncs .hide for visibility (the one write it makes).
        minimapPos             = {},
    }
end

local function NewAccountUI()
    return {
        mainWindowShown = false,
        -- Active tab. Matches a window.views[X] key in LayoutConfig. Persists
        -- across /reload so the user reopens to the same tab. nil falls
        -- back to window.defaultView in MainFrame's PrepareContext stage.
        view            = "decor",
        -- Shopping list widget visibility (parallel slot to mainWindowShown).
        -- Flipped by SHOPPING_WIDGET_TOGGLE; the MainFrame reconciler
        -- subscriber overrides `view` to "shoppingList" when this is true.
        shoppingWidgetShown = false,
        -- Which housing neighborhood the shopping list should send you to when
        -- BOTH sell the same decor. "" = follow this character's faction; the
        -- player's own pick ("alliance"/"horde") persists over it. Both
        -- neighborhoods are shoppable by either faction, so this is travel
        -- convenience -- it reorders vendors, it never hides one.
        shoppingNeighborhood = "",
        -- Zone Scanner popup visibility (parallel slot to shoppingWidgetShown).
        -- Flipped by ZONE_POPUP_TOGGLE; also set true by HDGR_ZoneAlertEngine
        -- when a zone-entry alert fires AND zoneScannerPopup is true. Persists
        -- across /reload so users who keep it open get it back automatically.
        zonePopupShown = false,
        -- Per-tab persistent UI bits. Promoted from session.ui when the
        -- user's expectation is that the setting survives /reload.
        acquisition     = {
            -- itemsViewMode persisted: player's grid/list preference for
            -- the vendor's items area. Survives /reload.
            itemsViewMode = "grid",
        },
        -- Recipes tab persistent filter SETs keyed by display name / profession name.
        -- Empty = "all". Persist across /reload.
        recipes         = {
            expansionFilter  = {},
            -- Profession filter is PER CHARACTER (keyed by charKey -> set). A nil
            -- entry = pristine -> selector defaults to that char's professions.
            professionFilterByChar = {},
        },
        -- Sidebar nav: collapsed parent groups, keyed by hub view -> true.
        -- Persisted so a collapsed group stays collapsed across /reload.
        nav             = {
            collapsedGroups = {},
        },
        -- Blueprints picker: which of the two list sections ("pasted" | "catalog")
        -- are folded. Sparse set, persisted, like nav.collapsedGroups.
        blueprints      = {
            collapsedSections = {},
            -- Library: leave the game's automatic saves out of the All list. On by
            -- default -- four "Automatic Save" rows buried the owner's own list on
            -- first use; the Backups chip still shows them on request.
            hideBackups = true,
        },
        -- Styles tab Browse list: which sections and which categories are open.
        -- Persisted so the tree survives /reload; a category that has never been
        -- toggled is absent = collapsed, which is the "collapsed on first render"
        -- ruling with no code. "loose" is the fold of styles not in a category.
        styles          = {
            landing = {
                expandedSections   = { style = true },
                expandedCategories = {},
            },
        },
    }
end

-- Per-tab session.ui sub-view shapes. Pre-seeded by NewSessionUI so
-- selectors can read state.session.ui.<view>.<key> directly. Shape is
-- guaranteed; selectors fail loudly on typos (strict reads, ADR-005).

-- Forward-declared; real definition further down (SSoT shared with DECOR_FILTER_RESET).
local NewDecorFilters

-- Forward-declared; defined alongside the shopping factories further down.
local NewShoppingSessionUI

local function NewDecorSessionUI()
    return {
        searchQuery     = "",
        selectedItemID  = nil,
        -- Pets browser selection. Lives in the DECOR bucket because Pets is a
        -- top-filter mode of the decor view, not a view of its own (invariant 16).
        selectedSpeciesID = nil,
        filters         = NewDecorFilters(),
        -- { [variantKey] = stored count } the Destroy decor list sorts by once the
        -- player destroys from it (DECOR_PIN_STORED_SORT); nil = sort by live counts.
        pinnedSortCounts = nil,
    }
end

local function NewAcquisitionSessionUI()
    return {
        searchQuery         = "",
        selectedNpcID       = nil,
        selectedItemID      = nil,
        -- expandedVendors moved to account.ui.acquisition.expandedVendors
        -- (persistent across /reload) -- see NewAccountUI.
        viewMode            = "vendor",
        -- itemsViewMode persisted at account.ui.acquisition.itemsViewMode --
        -- the player's grid/list preference survives /reload.
        advancedFiltersOpen = false,
        preset              = nil,     -- source axis (achievement|reputation|endeavor|quest)
        missingOnly         = false,   -- collection axis -- ANDs with preset (orthogonal toggle)
        -- Advanced filters are multi-select SETs (empty = "All"). ACQ_TOGGLE_* flip membership.
        factionFilter       = {},
        expansionFilter     = {},
        zoneFilter          = {},
        repFilter           = {},
        sourceFilter        = {},
    }
end

-- Recipes tab session UI. Filters block shared with RECIPES_FILTER_RESET (ADR-018).
local function NewRecipesFilters()
    return {
        expansionFilter = "all",   -- string|"all"
        knownOnly       = false,
        uncollectedOnly = false,
        searchReagents  = false,
    }
end

local function NewRecipesSessionUI()
    return {
        searchQuery        = "",
        selectedRecipeID   = nil,
        -- Queue-row selection: when set, the queue row for this recipeID
        -- is highlighted AND the materials list filters down to only
        -- THIS recipe's mats (overrides the queue-wide aggregation
        -- normally driven by recipes.materials.* selectors via
        -- effectiveQueue). Toggle on second click via Deselectable flag
        -- on the queue scrollbox + RECIPES_TOGGLE_QUEUE_SELECTION action.
        queueSelectedRecipeID = nil,
        -- focusedItemID: set by clicking a recipe or queue row. Last click wins.
        focusedItemID      = nil,
        expandedSections   = {},        -- [sectionKey] = true (open) / nil (closed)
        materialsGrouping  = "totals",  -- "totals"|"byRecipe"  (organization axis)
        materialsDepth     = "direct",  -- "direct"|"raw"       (expansion-depth axis)
        -- expansionFilter + professionFilter live in account.ui.recipes (persisted SETs).
        listFilter         = "all",     -- "all"|"known"|"ready"
        -- Real wrapped height of the active-filter chip strip, published by the
        -- chipStrip widget after FlowContainer layout (via UI_SET_TRANSIENT).
        -- recipes.gridRows reads it to size the strip cell EXACTLY to the chips
        -- (no estimate, no clip, no slack). 0 until the first measurement.
        runHeight          = 0,
        filters            = NewRecipesFilters(),
    }
end

-- Warehouse view session state.
local function NewWarehouseSessionUI()
    return {
        selectedMaterialID = nil,   -- All Materials panel selection
        matSearch          = "",    -- All Materials search
    }
end

-- "Your Data" tab session UI. Holds collapse overrides for the three
-- achievement groups (decor / coupon / lumber). Tri-state per group key
-- "collapse_<group>":
--   absent (nil) -> AUTO: collapse a fully-earned group on first open
--   true         -> user collapsed
--   false        -> user expanded
-- Keys are deliberately ABSENT at seed time so the auto-collapse default
-- applies until the user clicks a group header (UI_SET_TRANSIENT writes
-- session.ui.data.collapse_<group>). data.achievementsData reads this bucket.
local function NewDataSessionUI()
    return {}
end

-- Item name cache. Resolved names are written into `names` by the
-- ITEM_INFO_RESOLVED reducer (which receives entries from
-- ItemNameResolver:Drain). Consumers (selectors / row factories) read via
-- ItemNameResolver:ResolveName which Peeks this cache before re-querying
-- Blizzard -- avoids redundant GetItemInfo calls on the hot path and
-- survives Blizzard cache eviction across long sessions. Species B
-- (state-resident, reducer-written): consumers declare the DATA PATH
-- (session.itemNames.names) in reads -- the batched dispatch invalidates it
-- directly, which is identical in power to the tick this cache used to
-- carry (dissolved 2026-06-11; see TICK_REVALIDATION). The facade contract
-- lives in Resolver:RegisterFacadeReads("ItemNameResolver") below.
local function NewItemNamesSession()
    return {
        names = {},  -- [itemID] = "resolved name"; written by reducer, Peeked by ResolveName
    }
end

-- Price-source session state. PriceSource is a stateful module (external
-- TSM/Auctionator facades + scan progress); its A-side re-pull signal is
-- session.resolvers.prices.tick (Resolver:Register("prices") at this file's
-- EOF) and its B-side data is account.prices.* -- price-consuming selectors
-- declare BOTH. This bucket keeps only the plain session-transient fields.
local function NewPricesSession()
    return {
        -- Live scan progress (transient -- not persisted). Drives the
        -- Config sub-tab's progress strip.
        scanning  = false,
        scanFound = 0,
        scanTotal = 0,
        -- Snapshot of price-addon availability, refreshed on every
        -- MAIN_WINDOW_OPENING by PriceSource:RefreshAddonAvailability.
        -- Selectors read these directly so they stay pure (no _G probes).
        tsmLoaded         = false,
        auctionatorLoaded = false,
    }
end

-- Alts tab session UI. Account Summary always renders;
-- Characters section is a single panel with two pill buttons in the
-- header that toggle which population is shown. `charsPopulation` =
-- "active" (default) or "hidden" -- the latter includes both manually-
-- hidden chars and chars that have never been profession-scanned.
local function NewAltsSessionUI()
    return {
        charsPopulation = "active",
    }
end

-- Mogul tab session UI. Three dimensions drive the plan builder,
-- plus a sub-view switcher (13.F.2) that splits the tab into three panels:
--   "mogul"  -- craft optimizer plan + lumber tracker (the original view)
--   "goblin" -- per-decor profit table with AH/TSM integration
--   "config" -- price source preferences, AH scan controls, cache stats
-- 13.F.3.b: goblin sub-view filter dimensions. "All" sentinel skips the
-- filter. Profession matches PROFESSION_DATA[i].name verbatim.
local function NewMogulSessionUI()
    return {
        mode       = "profit",       -- profit | collection
        viewMode   = "char",         -- char | account
        optimizeBy = "lumberOnly",   -- lumberOnly | lumberPlusMats
        subView    = "goblin",       -- goblin | mogul (Goblin is the default sub-view)
        -- Supply Impact: market-pressure model for the planner.
        -- mode: "off" = original greedy; "smooth" = per-unit decay; "cap" = hard ceiling N.
        supplyImpact = {
            mode      = "off",   -- "off" | "smooth" | "cap"
            smoothPct = 7,       -- decay % per craft (7 = 7% decay)
            capN      = 10,      -- max crafts per recipe in cap mode
        },
        -- Frugal mode: biases planner toward low-lumber crafts by re-ranking as
        -- `effProfit / bindingLumberQty^1.5` (dampens high-lumber recipes).
        frugal = false,
        goblin     = {
            profession   = "All",    -- "All" | PROFESSION_DATA[i].name
            expansion    = "",       -- "" (no filter) | EXPANSION_DATA[i].display; toggle-clear, composes with profession
            search       = "",       -- substring filter on item name (case-insensitive)
            knowledge    = "all",    -- all | known (char) | alt (account-known)
            queue        = "all",    -- all | only (queued only) | hide (hide queued)
            auctionsOnly = false,    -- true: only show items with active player AH listings
            haveLumber   = false,    -- true: hide crafts whose lumber need exceeds held minus queued (lumber-only)
            sortCol         = "profit", -- name | lumber | perLum | cost | sell | tsmMin | tsmMarket | tsmRegion | tsmPct | profit | pct
            sortDir         = "desc",   -- "asc" | "desc"
            expandedItemID  = nil,      -- itemID of the row whose detail panel is showing (nil = collapsed)
        },
    }
end

-- Styles tab session UI. 14.0 scaffold only seeds the
-- top-level view discriminator + sub-slot scaffolding; per-surface
-- session state (landing filters, curator selectedItems set, smartset
-- draft, etc.) lands as each surface is wired in 14.1-14.6.
local function NewStylesSessionUI()
    return {
        view       = "landing",   -- "landing" | "detail" | "curator" | "smartset" | "import" | "export"
        selectedID = nil,         -- collectionID currently viewed in Detail
        landing    = { filter = "all", search = "" },   -- expandedSections moved to account.ui.styles.landing (spec 6.2)
        detail     = {
            selectedItemID = nil,
            search         = "",
            viewMode       = "cards",   -- "list"|"cards"|"split" -- 14.2.b
            sourceFilter   = "all",     -- "all"|<sourceType> -- 14.2.b filter chips
            subcatFilter   = "all",     -- "all"|<subcategoryID> -- 14.2.b for Room Concepts
        },
        curator    = {
            sourceMode        = "all",          -- "unassigned" | "all" | "style:<id>" (default: browse everything)
            -- Blizzard category-nav focus (icon rail). nil = "All". Drives the icon
            -- strip + the grid filter (sourceItems) via row.categoryID / subcategoryID.
            focusedCategoryID    = nil,
            focusedSubcategoryID = nil,
            selectedItems     = {},             -- set: [itemID] = true
            selectedCount     = 0,              -- cached count of selectedItems
            selectedTargetID  = nil,            -- highlighted FILE INTO target
            searchQuery       = "",             -- case-insensitive substring filter on the card grid
            recentUndo        = {},             -- LIFO stack of move/copy records
            hoverItemID       = nil,
        },
        -- 14.4 Smart Set Builder draft state. `draft` holds the working
        -- collection record (id, displayName, description). `rules` is a
        -- nested map [axis][tag] = severity ("signature"|"accent"|"clashing").
        -- `activeAxis` drives the middle-column tag list; `activeSeverity`
        -- drives the preview's severity-tab filter. `dirty` flags unsaved
        -- changes so SAVE/CANCEL can no-op the no-edit case.
        smartset   = {
            draftKey       = nil,    -- existing collectionID if editing, nil for new
            draft          = { id = nil, displayName = "", description = "", type = "smartset", descAuto = true },
            activeAxis     = "room", -- current facet axis being edited
            activeSeverity = "all",  -- "all" | "signature" | "accent" | "versatile" | "clashing"
            rules          = {},     -- { [axis] = { [tag] = severity } }
            dirty          = false,
        },
        import     = { urlText = "", parseError = nil, previewItems = nil, destination = "style" },
        export     = { selectedKey = nil, format = "hdg", search = "" },  -- format: "hdg"|"dd2"
    }
end

-- Smart Set auto-description: title-cased signature-tag names, sorted + comma-joined
-- (mirrors HDG BuildAutoDescription). Pure; used by the SMARTSET reducer cases.
local function _prettyTag(tag)
    tag = tag:gsub("%-", " ")
    return (tag:gsub("(%a)([%w']*)", function(h, t) return h:upper() .. t end))
end

local function _buildSmartsetAutoDesc(rules)
    local parts = {}
    for _, tags in pairs(rules or {}) do
        for tag, sev in pairs(tags) do
            if sev == "signature" then parts[#parts + 1] = _prettyTag(tag) end
        end
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

-- Default "<Char> Style <N>" name for a fresh smart-set draft -- N is the
-- monotonic account.collectionSeq+1 (the same N the SAVE id will mint).
local function _seededSmartsetName(account)
    local charName = (UnitName and UnitName("player")) or "My"  -- exception(boundary): player name for default label
    return charName .. " Style " .. ((account.collectionSeq or 0) + 1)  -- exception(boundary): pre-counter saved accounts lack collectionSeq
end

-- Trainers tab session UI.
local function NewTrainersSessionUI()
    return {
        searchQuery         = "",
        expandedProfessions = {},     -- [profName] = true (open) / nil (closed); default = all collapsed
        midnightExpanded    = false,  -- separate boolean for Midnight Recipe Sources section
        selectedNpcID       = nil,    -- highlighted trainer (for TreeList row selection)
    }
end

-- HouseEditor companion session UI. Standalone window (launcher click while HouseEditor open).
local function NewCompanionSessionUI()
    return {
        windowShown      = false,    -- launcher click toggles this
        mode             = "styles", -- "styles"|"shopping"|"snapshots"|"themes"|"collections"|"recent"
        search           = "",
        selectedItemID   = nil,      -- highlighted collection in sidebar (varies by mode)
        showCost         = true,     -- cost-badge visibility toggle (header budget button)
        ioFilter         = "all",    -- "all"|"indoor"|"outdoor" -- 3-state grid filter
    }
end

-- Companion account UI: window position persists across sessions. Default
-- nil means "use HouseEditorFrame anchor"; the user dragging the window
-- records position via COMPANION_SET_POSITION.
local function NewCompanionAccountUI()
    return {
        window   = { x = nil, y = nil },   -- nil = default-anchor; numeric = user-positioned
        launcher = { x = nil, y = nil },   -- in-editor launcher button position (nil = default top-left)
        -- Your Styles sidebar group folds. Sparse: present = FOLDED, so a group
        -- the user has never touched is open -- a picker has to show everything
        -- until the user says otherwise. Deliberately NOT Browse's set (which is
        -- present = OPEN): the two lists fold independently.
        collapsedGroups = {},   -- [groupKey] = true; keys "loose" | "cat:<n>" | "smartsets"
    }
end

-- HouseTab session UI. Picker drawer + design-mode editor are transient.
local function NewHouseTabSessionUI()
    return {
        pickerOpen = false,
        designMode = false,
    }
end

-- HouseTab account-side persistence: per-widget customizations.
local function NewHouseTabAccountUI()
    return {
        enabled         = {},   -- [widgetID] = bool (nil = use default)
        order           = {},   -- [widgetID] = number (nil = use default)
        width           = {},   -- [widgetID] = "third"|"twoThirds"|"full"
        layoutOverrides = {},   -- [widgetID] = { height = N } per-widget size overrides
    }
end

-- HouseTab live snapshot session slot. Aggregator dispatches HOUSE_SNAPSHOT_
-- UPDATED with the precomputed snapshot table. snapshotChangeSeq bumps on every
-- dispatch; selectors derived from the snapshot declare reads = {
-- "session.house.snapshotChangeSeq" } to invalidate together.
--
-- ownedHouses: { [houseGUID] = { name, faction, level, favor, maxLevel,
-- thresholds } }. Populated by HousingObserver via HOUSE_LIST_UPDATED
-- (identity fields) + HOUSE_LEVEL_UPDATED (level/favor/thresholds).
-- Reducer preserves level/favor across re-fires of the house-list event.
local function NewHouseSession()
    return {
        snapshot               = {},   -- empty until first aggregator run
        snapshotChangeSeq           = 0,
        ownedHouses            = {},   -- keyed by houseGUID
        activeNeighborhoodGUID = nil,  -- WOWGUID from C_NeighborhoodInitiative.GetActiveNeighborhood
        -- rewardsByLevel[level] = { rewards = {...} } -- per-level reward
        -- cache populated by RECEIVED_HOUSE_LEVEL_REWARDS via
        -- HOUSE_REWARDS_RECEIVED dispatch. Aggregator reads this to
        -- build the nextRewards snapshot field.
        rewardsByLevel         = {},
        -- Live decor spend bumped by PROJECTS_HOUSE_TICK. Placement caps are
        -- reward-derived; the live cap API is editor-state-dependent.
        budget                 = { decorSpent = 0, decorCount = 0 },
        numFloors              = 0,
        editorActive           = false,
        -- Live room catalog snapshotted by HousingCatalogObserver on HOUSING_STORAGE_UPDATED.
        -- byShapeID[shapeID] = entry; entries = full list.
        -- entry = { recordID, shapeID, name, iconAtlas, iconTexture, placementCost,
        --           numStored, numPlaced, quantity, owned, isAllowedIndoors,
        --           isAllowedOutdoors, isPrefab, quality }.
        roomCatalog            = { changeSeq = 0, byShapeID = {}, entries = {} },
        -- Blizzard category/subcategory nav tree (CATALOG_CATEGORY_TREE_UPDATED),
        -- snapshotted from C_HousingCatalog by HousingCatalogObserver. Shared by the
        -- Style Curator + Projects decor picker. iconBase = atlas with Blizzard's baked
        -- state suffix stripped (selectors append _active/_inactive/_active-parent).
        -- byID[catID]       = { id, name, iconBase, orderIndex, subcategoryIDs, anyStoredEntries }
        -- subcatByID[subID] = { id, name, iconBase, orderIndex, parentCategoryID, anyStoredEntries }
        -- rootIDs = top-level catIDs ordered by orderIndex; selectors filter storedOnly.
        categoryTree           = { changeSeq = 0, byID = {}, subcatByID = {}, rootIDs = {} },
    }
end


-- Zone Scanner session UI -- expand-per-vendor, search text, show-collected
-- toggle, all transient (don't survive /reload by design; the popup itself
-- and the master config flags ARE persistent in account.config / account.ui).
local function NewZoneScannerSessionUI()
    return {
        expanded       = {},      -- [npcID] = true when expanded; absent = collapsed
        searchQuery    = "",
        showCollected  = false,
    }
end

local function NewProjectsSessionUI()
    -- Transient nav for the Projects tab (reset to landing on /reload, per decision).
    return {
        activeView      = "landing",   -- "landing" | "architect"
        selectedFloor   = 1,
        canvasMode      = "plan",      -- "plan" (top-down floor) | "section" (isometric whole-house)
        selectedRoomID  = nil,
        selectedCrateID = nil,
        -- Layouts tab: the version whose floors the preview/detail show (NOT the
        -- Architect's activeVersionID -- the Layouts preview is independent of editing).
        layoutSelectedVersionID = nil,
        -- (activeMode removed with the Reflect/Plan reshape -- the canvas always renders
        -- the active version; arrangement is by drag / Auto-fill, not a mode toggle.)
        -- Decor picker: crate being added to + search/selection.
        pickerCrateID        = nil,    -- non-nil while the picker is open (the target local set)
        pickerSearch         = "",     -- catalog name filter
        pickerSource         = "all",  -- "all" | "style:<collID>" | "shop:<listID>" (the source axis)
        pickerReturn         = "projectsArchitect",  -- view the picker's Back returns to
        furnCollapsed        = {},     -- [setID] = true -> folded in the room detail (session-only)
        landingRoomID        = nil,    -- landing Rooms-box selection (drives its action rail)
        landingSetID         = nil,    -- landing Sets-box selection (drives its action rail)
        pickerSelectedItemID = nil,    -- drives the modelPreview right pane (hover-driven)
        -- Blizzard category-nav focus (vertical rail in the decor picker). nil = "All".
        focusedCategoryID    = nil,
        focusedSubcategoryID = nil,
        -- Ambiguous recapture matches awaiting manual remap (E8, forward-declared).
        -- Seeded empty so projects.ambiguousMatches strict-reads; the recapture
        -- observer overwrites via UI_SET_TRANSIENT{key="ambiguous"} when E8 lands.
        ambiguous            = {},
        -- Help workspace (the workflow cycle diagram): selected stage + the
        -- view the Back button returns to (Help! opens from landing AND architect).
        helpStage            = 1,
        helpReturn           = "projectsLanding",
    }
end

local function NewRemovalistSessionUI()
    -- Transient for the Removalist plot-move planner (its OWN per-view bucket --
    -- deliberately NOT under session.ui.projects). faction toggle + plot selection.
    return {
        faction      = "alliance",   -- "alliance" | "horde"
        sourcePlot   = nil,          -- selected source plot number (Phase 3)
        targetPlot   = nil,          -- selected target plot number (Phase 3)
        letterFilter = nil,          -- nil = all; "A"|"B"|"C"|"D" filters the plot list
    }
end

-- Blueprints tab (12.1). Server-derived except selection/target pointers; none
-- of this persists. account.blueprints.labels (EnsureStateShape) is the only
-- persisted blueprint state. manifests[code] = {status, reasonCode?, requestedAt?, raw?}.
local function NewBlueprintsSession()
    return {
        -- false at mint on ALL builds (keeps golden-state build-independent);
        -- BlueprintObserver dispatches BLUEPRINT_AVAILABLE_SET(true) at enable on 12.1.
        available       = false,
        -- used/max is the 50-slot catalog budget. An import's automatic save
        -- lands in a separate "Backups" group that does NOT spend a catalog
        -- slot, so it needs its own pair. All four arrive from
        -- COLLECTION_RECEIVED, which replaces this table wholesale -- the
        -- observer has to send all four or the backup pair reads nil.
        slots           = { used = 0, max = 0 },
        groups          = {},                      -- HousingBlueprintInfo rows, grouped
        manifests       = {},                      -- [shareCode] = { status, reasonCode?, requestedAt?, raw? }
        selectedCode    = nil,
        targetHouseGUID = nil,                     -- nil = server defaults to current house
        pendingNow      = 0,                       -- last BLUEPRINT_PENDING_TICK now (elapsed compose)
    }
end

-- The Menagerie (House > Pets). ALL transient; UI_SET_TRANSIENT(view="menagerie")
-- is the only writer -- zero feature-specific actions by design
-- (HDGR_MENAGERIE_LATTICE_PLAN_2026-08-24 section 3).
--
-- One mode, By Pet. The room mode and its captured roomQuery were removed
-- 2026-08-27: the game enumerates placed decor per AREA, and indoors is ONE
-- area, so a capture could only ever describe the whole interior while calling
-- itself a room. See the closing section of docs/HDGR_BY_ROOM_SPEC_2026-08-25.md.
local function NewMenagerieSessionUI()
    return {
        axis = "clade", axval = "all", -- the two-row identity filter
        -- Search reaches the KIND tail that no chip row can hold: 712 kinds, 509
        -- of them with four pets or fewer. Typing "squirrel" is the surface that
        -- scales where a nested axis did not (the drill was reverted 2026-08-25).
        search = "",
        scene = { decorID = nil, withYou = false },
        selectedSpeciesID = nil,
    }
end

local function NewBlueprintsSessionUI()
    -- exportNeighborhood: which neighborhood the COPIED requirements list names
    -- its vendors for. "" = follow the shopping preference, which is only the
    -- opening position; the copy window's own switch moves it from there.
    --
    -- SESSION, not account, and it deliberately does not write back to the
    -- shopping preference. Choosing who a shared list is written for is a
    -- decision about that export, and it must not quietly change where your own
    -- shopping list sends you.
    --
    -- Library mode (design 2026-09-11, D5-D7): the sub-view, the filter text,
    -- the source chip and the table sort are all session-only; a reload lands
    -- on the picker. subView / libraryQuery / libraryChip are written by
    -- UI_SET_TRANSIENT; the sort has its own action because a header click
    -- flips or resets, which is reducer logic.
    --
    -- librarySelectedKey: the ENTRY key of the Library row last clicked (nil =
    -- resolve the detail strip by code alone). The selected CODE is shared with
    -- the picker, but one code can render two Library rows -- an own blueprint
    -- pasted back in -- and only the clicked row's source says whether "remove"
    -- means Forget or Delete.
    return { missingOnly = false, collapsedGroups = {}, pasteError = false,
             exportNeighborhood = "",
             subView = "inspect", libraryQuery = "", libraryChip = "all",
             librarySortCol = "date", librarySortDir = "desc",
             librarySelectedKey = nil }
end

local function NewSessionUI()
    return {
        decor        = NewDecorSessionUI(),
        acquisition  = NewAcquisitionSessionUI(),
        recipes      = NewRecipesSessionUI(),
        warehouse    = NewWarehouseSessionUI(),
        alts         = NewAltsSessionUI(),
        mogul        = NewMogulSessionUI(),
        styles       = NewStylesSessionUI(),
        trainers     = NewTrainersSessionUI(),
        companion    = NewCompanionSessionUI(),
        houseTab     = NewHouseTabSessionUI(),
        shoppingList = NewShoppingSessionUI(),
        zoneScanner  = NewZoneScannerSessionUI(),
        projects     = NewProjectsSessionUI(),
        removalist   = NewRemovalistSessionUI(),    -- Removalist plot-move planner
        data         = NewDataSessionUI(),         -- Your Data tab: achievement-group collapse
        catalogIntro = { phase = "hidden" },        -- initial-load overlay: "hidden"|"loading"|"success"
        blueprints   = NewBlueprintsSessionUI(),    -- Blueprints tab transients (12.1)
        menagerie    = NewMenagerieSessionUI(),     -- House > Pets (the Menagerie)
    }
end

-- Zone state: current mapID (stamped by ZONE_CHANGED; 0 = not yet probed).
-- Lives at session.zone, not session.ui.*, as it's the canonical player-location fact.
local function NewZoneState()
    return { currentMapID = 0, currentZoneName = "" }
end

-- Lumber Tracker state layout:
-- account.lumber.{config, sessions} (persistent); session.lumber.{activeFarmingID, blips, tick} (transient).
--
-- account.lumber.config: user prefs + drag position (survives /reload).
-- account.lumber.sessions: { [charKey] = { [lumberID] = { startedAt, startCount,
--   lastHarvestAt, finalizedAt? } } } -- finalizedAt set on LUMBER_SESSION_END.
-- session.lumber.activeFarmingID: current lumberID; nil = idle.
-- session.lumber.blips: recent gather events; GC-swept by LUMBER_BLIP_GC.
-- session.lumber.tick: species-E CLOCK (TICK_REVALIDATION) -- bumped by the
-- 1s LUMBER_TICK heartbeat while farming and on blip appends so elapsed/rate
-- displays re-render. A render heartbeat, NOT a change signal: it stays a
-- plain tick, outside the resolver registry, and is the sanctioned narrow
-- exception to the no-UI-timers rule (data-display clock, not a state transition).
local function NewLumberConfig()
    return {
        windowVisible    = false,            -- LUMBER_WINDOW_TOGGLE writes
        position         = { x = 100, y = -150 },  -- TOPLEFT offset
        radarCollapsed   = false,            -- header chevron writes
        listCollapsed    = false,            -- session-only mode: header list-toggle writes (effective only while farming)
        radarScale       = 1.0,              -- 0.5..2.0 (settings slider)
        autoShowOnHarvest = true,            -- opt-out; suppressed for current
                                              -- session when user closes window
        lumberGoal       = "decor",          -- row denominator: "decor" = all uncollected-decor need (default); "queue" = queued-craft need
    }
end

local function NewLumberSession()
    return {
        activeFarmingID = nil,   -- lumberID currently being farmed
        blips           = {},    -- recent gather events (ring buffer)
        tick            = 0,     -- species-E clock; see comment above
    }
end

-- StyleEngine cache invalidation tick (bumped on STYLES_INVALIDATE_CACHE).
-- placedDecor: live map keyed by decorGUID (only stable handle Blizzard exposes).
-- currentArea: area segment of the most recent CUSTOMIZATION_CHANGED burst. An
-- AREA is indoors vs outdoors, NOT a single room -- all interior rooms share one.
-- The Placed list scopes to it, matching Blizzard's own panel (GetAllPlacedDecor
-- is itself area-scoped).
local function NewStylesSession()
    return { changeSeq = 0, placedDecor = {}, currentArea = nil }
end

-- Session log: ring buffer (per ADR-013). dispatchCap sub-caps the "dispatch"
-- tag so user-tagged history isn't drowned by the dispatch firehose.
local function NewSessionLog()
    return {
        entries      = {},
        nextID       = 0,
        cap          = 200,
        dispatchCap  = 50,
        tabFilter    = { tag = "all", level = "all", autoScroll = true },
        activeTraces = {},
    }
end

local function NewSessionCatalog()
    return {
        status          = "idle",   -- "idle" | "loading" | "ready"
        loadedAt        = 0,        -- epoch of last completed load
        itemCount       = 0,
        vendorCount     = 0,
        refreshPending  = false,    -- true after a catalog/storage event; clears on next tab open
        variantsLoaded  = false,    -- true once GetAllVariantInfosForEntry has been batched
    }
end

-- Vendor buying (spec HDGR_VENDOR_BUYING_SPEC.md): MERCHANT_SHOW..CLOSED window.
-- byItemID is the scanned merchant stock; buying carries the paced-queue progress.
local function NewSessionMerchant()
    return {
        open     = false,
        byItemID = {},    -- [itemID] = { index, price, name, numAvailable }
        buying   = nil,   -- { total, done } while HDGR_BuyQueue runs; nil otherwise
    }
end

-- identity: canonical player tuple. Stamped once by SESSION_IDENTITY_SET.
-- Stable for the session; selectors read these instead of calling UnitName/etc.
-- Empty defaults allow strict reads during the brief boot window (per ADR-005).
local function NewIdentitySession()
    return {
        charKey      = "",
        name         = "",
        realm        = "",
        class        = "",     -- localized class name (e.g. "Warrior")
        classFile    = "",     -- enUS class token (e.g. "WARRIOR")
        factionGroup = "",     -- "A" / "H" / "N" -- matches HDGR_VendorDB row[6]
    }
end

local function NewDefaultSession()
    return {
        ui             = NewSessionUI(),
        combat         = { inLockdown = false, queued = {} },
        log            = NewSessionLog(),
        -- Facade-poll re-pull signals, one slot per registered resolver
        -- (species A + D; see Core/HDGR_Resolvers.lua + the Resolvers
        -- section at the end of this file).
        resolvers      = HDG.Resolver:MintSlots(),
        itemNames      = NewItemNamesSession(),
        prices         = NewPricesSession(),
        styles         = NewStylesSession(),
        zone           = NewZoneState(),
        catalog        = NewSessionCatalog(),
        merchant       = NewSessionMerchant(),
        destroying     = nil,   -- { total, done, name, waiting } while HDGR_DestroyQueue runs; nil otherwise
        lumber         = NewLumberSession(),
        identity       = NewIdentitySession(),
        daily          = { bestowed = nil, orcQuote = nil },  -- seeded here; EnsureSession no longer needs or-guard
        house          = NewHouseSession(),  -- seeded here; EnsureSession no longer needs or-guard
        -- Furnishings (v7): reducer-minted ID echoes (controllers read the id
        -- of what they just created) + derived reverse indexes (rebuilt on
        -- hydrate, maintained by the FURN_*/LAYOUT_* reducer cases).
        furn           = { lastSetID = nil, lastRoomID = nil, changeSeq = 0 },
        furnIndex      = { setRooms = {}, roomLayouts = {} },  -- [setID]={[roomID]=true} / [roomID]={[layoutID]=true}
        blueprints     = NewBlueprintsSession(),  -- Blueprints tab server-derived slice (12.1)
    }
end

-- account.prices: persistent AH price cache. directCache survives /reload;
-- ownedAuctions cached on AH open so Goblin can mark "already listed" offline.
local function NewPrices()
    return {
        directCache     = {},   -- [itemID] = copper (0 = scanned, not listed)
        directQtyCache  = {},   -- [itemID] = units currently listed (0 = scanned, none listed; nil = unscanned)
        directCacheTime = nil,  -- unix ts of last full scan
        ownedAuctions   = {},   -- [itemID] = { qty, buyout } from C_AuctionHouse
    }
end

-- account.collection: reconciler-owned ownership cache (per ADR-012).
-- Selectors depend on individual sub-paths to avoid full-bucket invalidation.
local function NewCollection()
    return {
        ownedDecorIDs         = {},   -- [decorID] = true (ownership set; persisted SavedVariables warm-start seam)
    }
end

-- Favorites: keyed by itemID (stable across catalog rebuilds; decorIDs are not).
local function NewFavorites()
    return {}   -- [itemID] = true
end

-- User notes per item. Keyed by itemID; LRU-pruned at 500 in NOTE_SET reducer.
local function NewUserNotes()
    return {}   -- [itemID] = { text = string, ts = number }
end

-- Multi-list shopping system. shoppingListSeq is monotonic -> collision-free IDs ("L1","L2",...).
-- EnsureShopping reseeds past existing IDs so creates can't collide with deleted slots.
local function NewVendorShoppingLists()
    return {}   -- [listID] = { name, items = {{itemID, npcID?, qty, addedAt}, ...}, meta, createdAt }
end

local function NewActiveShoppingListId()
    return ""   -- "" = no list active (first CREATE auto-activates)
end

local function NewShoppingListSeq()
    return 0    -- counter -- IDs are "L" .. (++seq)
end

-- Shopping list view's session-only UI bucket. Holds expand/collapse state
-- for the 3-level grouped scrollbox (zone -> vendor -> items + wishlist).
-- Per-session: cleared on /reload by design; remembering which zones are
-- expanded across sessions has no value -- users open the list, glance,
-- close. Forward-declared above (above NewSessionUI which composes this in).
NewShoppingSessionUI = function()
    return {
        expanded = {
            zones    = {},   -- [zoneName] = true means COLLAPSED
            vendors  = {},   -- [npcID]    = true means COLLAPSED
            wishList = false, -- true means COLLAPSED
            ahList   = false, -- Auction House (crafted/BoE) section; true means COLLAPSED
        },
    }
end

-- Vendor notes. Keyed by npcID; LRU-pruned at 100 in VENDOR_NOTE_SET reducer.
local function NewVendorNotes()
    return {}   -- [npcID] = { text = string, ts = number }
end

-- Recipe knowledge: keyed by itemID for O(1) lookup. selfKnown populated by RecipeKnowledgeScanner.
local function NewRecipes()
    return {}   -- [itemID] = { spellID, selfKnown, altKnown }
end

-- Crafting queue + history. Queue rows persist via SavedVariables; history is a ring buffer
-- (cap = HDG.Constants.CRAFT_HISTORY_CAP). sessionKey disambiguates cross-reload entries.
--
-- Shape:
--   queue   = { [1..n] = { recipeID, itemID, requested, remaining,
--                          source = "tradeskill"|"manual",
--                          ts, sessionKey } }
--   history = { entries = { { id, recipeID, itemID, qty, ts } },
--               nextID  = 0 }
local function NewCraft()
    return {
        queue   = {},
        history = { entries = {}, nextID = 0 },
    }
end

-- Per-character roster. Empty until the first scan dispatches a
-- CHARACTER_PROFESSION_UPDATED. Schema for each entry (keyed by charKey =
-- "Name-Realm"):
--   { name, realm, class, classFile, hidden, lastSeen,
--     essenceStock = { bag, bank },   -- Essence of Lumber snapshot (soulbound; no warband)
--     reagentStock = { bag = {[itemID]=n}, bank = {[itemID]=n}, bagAt, bankAt },
--                                     -- decor reagents; sparse, nonzero only.
--                                     -- NO warband slot: shared stash, counted
--                                     -- once live rather than per character.
--                                     -- bagAt/bankAt are separate because bank
--                                     -- counts only refresh once a bank opens.
--     professions = { [profName] = {          -- keyed by LOCALIZED name (back-compat)
--         professionID = <TradeSkillLineID>,  -- stable, locale-invariant join key
--         skillLines   = { [expName] = { current, max } },
--         knownRecipes = { [recipeID] = true },
--     } } }
local function NewCharacters()
    return {}
end

-- Defaults for session.ui.decor.filters. Single source of truth referenced
-- by NewDecorSessionUI (above; forward-declared so NewDecorSessionUI's
-- body can call it), by DECOR_FILTER_RESET (atomic write), and by
-- ensureDecorFilters (lazy init inside reducer cases).
NewDecorFilters = function()
    return {
        topFilter        = "all",
        activeTag        = nil,
        onlyUncollected  = false,
        onlyStored       = false,
    }
end

-- Accessor for session.ui.decor.filters from inside a reducer case. session.*
-- is rebuilt fresh from NewDefaultState every boot and never rehydrated from
-- SV (Store:LoadFromSavedVariables adopts only account.*), so decor.filters is
-- guaranteed seeded by NewDecorSessionUI -- strict read, no lazy-init guard
-- (ADR-005). Returns the table so the case can read-modify-write; mutation
-- stays reducer-owned (invoked from _RawDispatch only).
local function ensureDecorFilters(state)
    return state.session.ui.decor.filters
end

-- A house VERSION: one design variant (the CURRENT version mirrors reality; what-if
-- versions branch from it). Rooms live HERE (house -> version -> room), keyed by stable
-- roomID; `cell` is a per-room attribute so dragging updates `.cell` while the id (and
-- its crate FK) survive. See docs/HDGR_PROJECTS_PIVOT.md "Layouts = house VERSIONS".
local function NewVersion(houseID, name, createdAt)
    return {
        houseID   = houseID,
        name      = name or "Live",
        createdAt = createdAt,
        basedOn   = nil,       -- parent versionID when branched (what-if); nil for the live version
        numFloors = nil,       -- what-if floor override (1..3); nil = derive from rooms or session
        rooms     = {},        -- [roomID] = RoomRecord { cell = { x, y, rotation, locked }, shape, ... }
    }
end

-- Monotonic version-ID minting. The counter lives in state (account.projects.versionSeq),
-- so the reducer stays a pure function of (state, action): deterministic, collision-free,
-- replayable -- unlike the old random namespacedID("version") which made the reducer
-- non-deterministic. `or 0` is the one legitimate read: a boundary for saved accounts
-- created before the counter existed.
local function _nextVersionID(p)
    p.versionSeq = (p.versionSeq or 0) + 1   -- exception(boundary): pre-counter saved accounts have no versionSeq
    return "version:" .. p.versionSeq
end

-- Placements for a new what-if layout: copy the source's (tags ride as roomID;
-- rooms are shared by reference, never copied), or seed a from-scratch design
-- with just the centre-canvas Entry anchor. Returns placements, slotSeq. (D1)
local function _copyOrSeedLayoutPlacements(srcLayout)
    if srcLayout then
        local placements = {}
        for key, pl in pairs(srcLayout.placements) do
            placements[key] = { floor = pl.floor, x = pl.x, y = pl.y,
                                rotation = pl.rotation, shape = pl.shape, floors = pl.floors,
                                roomID = pl.roomID,   -- v8: tags copy; rooms shared by reference
                                capturedID = pl.capturedID, capturedName = pl.capturedName }
        end
        return placements, srcLayout.slotSeq or 0
    end
    -- From-scratch: exactly one Entry (the anchor; palette never offers it),
    -- centre-canvas so building starts from the door.
    return { ["slot:1"] = { floor = 1, x = 10, y = 10, rotation = 0, shape = "entry" } }, 1
end

-- Reverse index of roomID TAG -> layouts it appears in. _reindex adds every
-- tag in `placements` to layout `lid` (+1 per copy); _deindex (version delete)
-- drops them. Keyed by TAG, not placement key (review 17: the key form was a
-- silent no-op against account.rooms). (D1)
local function _reindexRoomLayouts(idx, placements, lid)
    for _, pl in pairs(placements) do
        if pl.roomID then
            idx.roomLayouts[pl.roomID] = idx.roomLayouts[pl.roomID] or {}
            idx.roomLayouts[pl.roomID][lid] = (idx.roomLayouts[pl.roomID][lid] or 0) + 1
        end
    end
end

local function _deindexRoomLayouts(idx, placements, lid)
    for _, pl in pairs(placements) do
        if pl.roomID and idx.roomLayouts[pl.roomID] then idx.roomLayouts[pl.roomID][lid] = nil end
    end
end

-- Resolve (lazily minting on first sight) a house's CURRENT version; returns its
-- versionID. The capture path + the 1->2 migration both funnel reality into the
-- current version. Mints house.currentVersionID/activeVersionID + the version record
-- the first time a never-seen house needs one.
local function _ensureHouseVersion(p, houseID, createdAt)
    local house = p.houses[houseID]
    if not house then house = {}; p.houses[houseID] = house end
    if not house.currentVersionID then
        local vid = _nextVersionID(p)
        house.currentVersionID = vid
        house.activeVersionID  = house.activeVersionID or vid
        p.versions[vid] = NewVersion(houseID, "Live", createdAt)
    end
    return house.currentVersionID
end

local function NewProjectsState()
    -- Persisted house topology (account-shared). v7: layouts hold placements;
    -- persistent rooms live in account.rooms, furnishing sets in
    -- account.furnishingSets (Core/HDGR_StoreFurnishings.lua).
    return {
        schemaVersion = 2,
        versionSeq  = 0,    -- monotonic layout-ID counter (reducer-pure, collision-free minting)
        houseFocusSeq = 0,  -- monotonic focus counter: the house with the highest house.focusSeq is the one the Architect shows
        houses      = {},   -- [houseID]   = { name, plotID, neighborhoodName, lastCapturedAt, currentVersionID, activeVersionID, focusSeq }
        layouts     = {},   -- [layoutID]  = { houseID, name, createdAt, basedOn, slotSeq, placements = { [slot:N] = { floor, x, y, rotation, floors?, shape?, capturedID?, capturedName? } } }
        -- (connectivity is DERIVED from cell-adjacency at render -- not stored)
    }
end

-- ===== Recent Activity (HDG parity) =========================================
-- Persisted per-house edit-session history. Keyed by the STABLE faction house
-- id (makeHouseID) -- NOT the process-scoped C_Housing houseGUID, which changes
-- across reloads. Shape:
--   recentActivity = {
--     lastHouseKey = "house:alliance",        -- house the Recent tab shows
--     houses = { [houseKey] = {
--       sessionOrder = { sid, ... },          -- newest-first
--       sessions = { [sid] = {
--         sessionID, startedAt, endedAt?,     -- endedAt nil => active ("Now")
--         eventCount,                         -- total placed+removed events
--         events = { [itemID] = { itemID, placed, removed, lastTs } },
--       } },
--     } },
--   }
local RECENT_SESSION_CAP = 20   -- keep N most-recent sessions per house
local RECENT_ACTION_CAP  = 40   -- keep N most-recent place/remove ACTIONS per session (strip feed)
local function NewRecentActivity()
    return { houses = {}, lastHouseKey = nil }
end

-- Append a placed/removed event to the active session for houseKey, lazily
-- opening a session if none is active (a placement/removal before an explicit
-- RECENT_SESSION_START). Aggregates by itemID. `kind` is "placed" or "removed".
-- Open a fresh RecentActivity session for `house`, sealing the previous one and
-- evicting past the cap. An active session that recorded NO events is reused so
-- opening/closing the editor without placing anything doesn't spam empty
-- sessions. Sibling of _recentAppend ("open a session" vs "append an event"). (D3)
local function _openNewRecentSession(house)
    local newestID = house.sessionOrder[1]
    local newest   = newestID and house.sessions[newestID]
    if newest and not newest.endedAt and (newest.eventCount or 0) == 0 then return end  -- reuse the empty active one
    if newest and not newest.endedAt then newest.endedAt = _G.time() end  -- exception(boundary): wall-clock stamp
    local sid = _G.time()  -- exception(boundary): wall-clock session key (single-player surface; collision accepted, owner call 2026-07-17)
    if house.sessions[sid] then sid = sid + 1 end  -- collision-safe within one second
    house.sessions[sid] = { sessionID = sid, startedAt = sid, endedAt = nil,
                            eventCount = 0, events = {}, actions = {} }
    table.insert(house.sessionOrder, 1, sid)
    while #house.sessionOrder > RECENT_SESSION_CAP do
        house.sessions[table.remove(house.sessionOrder)] = nil
    end
end

local function _recentAppend(state, houseKey, itemID, kind)
    if not (houseKey and itemID) then return end
    local ra = state.account.recentActivity
    local house = ra.houses[houseKey]
    if not house then
        house = { sessionOrder = {}, sessions = {} }
        ra.houses[houseKey] = house
        ra.lastHouseKey = ra.lastHouseKey or houseKey
    end
    local sid     = house.sessionOrder[1]
    local session = sid and house.sessions[sid]
    if not (session and not session.endedAt) then
        sid = (_G.time and _G.time()) or 0   -- exception(boundary): session id = wall-clock stamp
        if house.sessions[sid] then sid = sid + 1 end
        session = { sessionID = sid, startedAt = sid, endedAt = nil, eventCount = 0, events = {}, actions = {} }
        house.sessions[sid] = session
        table.insert(house.sessionOrder, 1, sid)
    end
    local ev = session.events[itemID]
    if not ev then
        ev = { itemID = itemID, placed = 0, removed = 0, lastTs = 0 }
        session.events[itemID] = ev
    end
    ev[kind]          = (ev[kind] or 0) + 1
    ev.lastTs         = (_G.time and _G.time()) or 0   -- exception(boundary): last-event wall-clock stamp
    session.eventCount = (session.eventCount or 0) + 1
    -- Per-ACTION log for the recent STRIP (1 card = 1 place/remove action), newest
    -- first, capped. The `events` aggregate above still powers the recent-MODE grid
    -- (per-item multiples). actions seeded on new sessions; or-{} covers pre-existing
    -- persisted sessions (SV migration boundary).
    session.actions = session.actions or {}
    table.insert(session.actions, 1, { itemID = itemID, kind = kind, ts = ev.lastTs })
    for i = #session.actions, RECENT_ACTION_CAP + 1, -1 do session.actions[i] = nil end
end

-- Patch-vintage tracking: snapshot = every itemID ever seen in the live
-- catalog (account-wide, persisted); newIds = the batch that appeared under
-- the current client build -- drives the decor browser's "New in <patch>"
-- chip. First-ever sweep seeds the snapshot silently (no batch), so existing
-- collections don't read as 100% new on install.
local function NewCatalogVintage()
    return { snapshot = {}, snapshotBuild = 0, newIds = {}, newBuild = 0, newBuildLabel = "" }
end

local function NewDefaultState()
    return {
        account = {
            schemaVersion        = HDG.Constants.SCHEMA_VERSION,
            config               = NewConfig(),
            ui                   = NewAccountUI(),
            collection           = NewCollection(),
            catalogVintage       = NewCatalogVintage(),
            favorites            = NewFavorites(),   -- G2
            userNotes            = NewUserNotes(),    -- G3
            vendorNotes          = NewVendorNotes(),
            recipes              = NewRecipes(),      -- partial; alt scanner fills altKnown on character scan
            craft                = NewCraft(),        -- queue + history
            characters           = NewCharacters(),   -- alts roster
            prices               = NewPrices(),       -- price cache
            collections          = {},                -- Styles / Snapshots / Shopping / etc., keyed by "<type>:<id>" (crates retired in v7)
            collectionSeq        = 0,                 -- monotonic counter -> collision-free smartset ids + "<Char> Style N" labels
            styleCategories      = {},                -- [categoryID] = { id, seq, name, createdAt } -- My Styles groupings (spec 2.1)
            styleCategorySeq     = 0,                 -- monotonic counter -> "cat:<n>" ids; never name-derived, never random
            -- Furnishings model (v7, docs/crate-redesign/10-FINAL-MODEL.md):
            -- free-standing quantified sets + persistent rooms; layouts hold placements.
            furnishingSets       = {},                -- [setID "set:N"] = { id, name, items = {{id,count},...}, isLocal, ownerRoom, createdAt }
            furnishingSetSeq     = 0,                 -- monotonic set-ID counter
            rooms                = {},                -- [roomID "room:N"] = { id, name, shape, furnishingSetIDs = {...}, legacyID?, createdAt }
            roomSeq              = 0,                 -- monotonic room-ID counter
            projects             = NewProjectsState(),
            questCompletions      = {},                -- account-wide quest completions: [questID] = { name, class } (first char to record wins; QUEST_COMPLETION_RECORDED)
                vendorShoppingLists  = NewVendorShoppingLists(),
            activeShoppingListId = NewActiveShoppingListId(),
            shoppingListSeq      = NewShoppingListSeq(),
            lumber               = { config = NewLumberConfig(), sessions = {}, history = { entries = {}, nextID = 0 } },
            -- Recent Activity: persisted per-house edit-session history (HDG parity).
            recentActivity       = NewRecentActivity(),
            -- Last-known decor storage {owned,max}; overwritten by HOUSE_CAPACITY_CACHED
            -- on each snapshot, read as the buy-picker fallback. false = never captured.
            houseCapacityCache   = false,
        },
        session = NewDefaultSession(),
    }
end

-- ===== Shape ensurance ========================================================

local function EnsureConfig(account)
    local defaults = NewConfig()
    account.config = account.config or {}
    for key, value in pairs(defaults) do
        if account.config[key] == nil then account.config[key] = value end
    end
end

local function EnsureUI(account)
    local defaults = NewAccountUI()
    account.ui = account.ui or {}
    for key, value in pairs(defaults) do
        if account.ui[key] == nil then account.ui[key] = DeepCopy(value) end
    end
end

local function EnsureCollection(account)
    local defaults = NewCollection()
    account.collection = account.collection or {}
    for key, value in pairs(defaults) do
        if account.collection[key] == nil then account.collection[key] = DeepCopy(value) end
    end
    -- SV migration: nil out legacy catalog mirrors (now owned by observer).
    local col = account.collection
    col.decorCatalog         = nil
    col.catalogByItem        = nil
    col.liveDecorIDs         = nil
    col.lastSweep            = nil
    col.clientVer            = nil
    col.catalogSchemaVersion = nil
end

-- Key-by-key merge from NewCraft -- matches EnsureConfig/EnsureUI pattern so
-- new sub-fields added to NewCraft() flow to existing users on next load.
-- History.entries + nextID also default-merged.
local function EnsureCraft(account)
    account.craft = account.craft or {}
    local defaults = NewCraft()
    for key, value in pairs(defaults) do
        if account.craft[key] == nil then account.craft[key] = DeepCopy(value) end
    end
    account.craft.history = account.craft.history or {}
    for key, value in pairs(defaults.history) do
        if account.craft.history[key] == nil then account.craft.history[key] = DeepCopy(value) end
    end
end

-- Shopping list shape ensurance. Reseeds the monotonic counter past any
-- existing list ID so a partial DB (deleted entries followed by reload)
-- doesn't risk colliding with a previously-used slot. ID format: "L<n>".
local function EnsureShopping(account)
    if type(account.vendorShoppingLists) ~= "table" then
        account.vendorShoppingLists = NewVendorShoppingLists()
    end
    if type(account.activeShoppingListId) ~= "string" then
        account.activeShoppingListId = NewActiveShoppingListId()
    end
    if type(account.shoppingListSeq) ~= "number" then
        local maxN = 0
        for id in pairs(account.vendorShoppingLists) do
            local n = tonumber(string.match(id, "^L(%d+)$"))
            if n and n > maxN then maxN = n end
        end
        account.shoppingListSeq = maxN
    end
    -- Seed a default list when the account has none, so "Add to Cart" works out
    -- of the box. Covers brand-new accounts AND any account that deleted its last
    -- list (both land at vendorShoppingLists = {} + activeShoppingListId = "" ->
    -- the "No active shopping list" dead-end). Runs after the seq reseed above so
    -- the new ID can't collide with a previously-used slot. Mirrors the
    -- SHOPPING_LIST_CREATE reducer's record shape + auto-activate.
    if next(account.vendorShoppingLists) == nil and account.activeShoppingListId == "" then
        account.shoppingListSeq = account.shoppingListSeq + 1
        local id = "L" .. tostring(account.shoppingListSeq)
        account.vendorShoppingLists[id] = {
            name      = "Shopping List",
            items     = {},
            meta      = {},
            createdAt = _G.time(),  -- exception(boundary): wall-clock stamp
        }
        account.activeShoppingListId = id
    end
end

local function EnsureSession(state)
    state.session         = state.session         or NewDefaultSession()
    state.session.ui      = state.session.ui      or NewSessionUI()
    state.session.ui.projects = state.session.ui.projects or NewProjectsSessionUI()
    state.session.ui.recipes = state.session.ui.recipes or NewRecipesSessionUI()
    state.session.ui.warehouse = state.session.ui.warehouse or NewWarehouseSessionUI()
    state.session.combat  = state.session.combat  or { inLockdown = false, queued = {} }
    state.session.log     = state.session.log     or NewSessionLog()
    -- Top-up, not or-guard: the file-load placeholder state mints BEFORE the
    -- Resolver:Register blocks at this file's EOF run, so hydrate re-mints any
    -- slots registered since (see Resolver:EnsureSlots).
    state.session.resolvers = HDG.Resolver:EnsureSlots(state.session.resolvers or {})
    state.session.itemNames  = state.session.itemNames  or NewItemNamesSession()
    state.session.identity = state.session.identity or NewIdentitySession()
    state.session.prices     = state.session.prices     or NewPricesSession()
    state.session.styles    = state.session.styles    or NewStylesSession()
    state.session.ui.styles = state.session.ui.styles or NewStylesSessionUI()
    state.session.ui.houseTab = state.session.ui.houseTab or NewHouseTabSessionUI()
    state.session.ui.data = state.session.ui.data or NewDataSessionUI()  -- Your Data collapse bucket
    state.session.ui.catalogIntro = state.session.ui.catalogIntro or { phase = "hidden" }  -- exception(boundary): session-shape backfill
    state.session.ui.shoppingList = state.session.ui.shoppingList or NewShoppingSessionUI()
    state.session.ui.zoneScanner  = state.session.ui.zoneScanner  or NewZoneScannerSessionUI()
    state.session.ui.removalist    = state.session.ui.removalist    or NewRemovalistSessionUI()
    state.session.zone      = state.session.zone      or NewZoneState()
    state.session.catalog   = state.session.catalog   or NewSessionCatalog()
    state.session.lumber    = state.session.lumber    or NewLumberSession()
    -- Guild recipe harvest choreography state (Scan Guild button on the Recipes title).
    state.session.recipeHarvest = state.session.recipeHarvest
        or { phase = "idle", active = false, done = 0, total = 0, name = "" }
    state.session.blueprints    = state.session.blueprints    or NewBlueprintsSession()
    state.session.ui.blueprints = state.session.ui.blueprints or NewBlueprintsSessionUI()
    state.session.ui.menagerie  = state.session.ui.menagerie  or NewMenagerieSessionUI()
    -- session.house + session.daily are seeded by NewDefaultSession; EnsureSession
    -- does not need or-guards for them (strict reads from here forward).
end

-- Projects schemaVersion 1 -> 2: the flat `account.projects.rooms[roomID]` map becomes
-- `versions[versionID].rooms[roomID]` (house -> version -> room). Per house, seed a
-- current version; move each flat room (keyed by its parsed houseID) into that version;
-- stamp each crate's versionID from its parent room's house current version; drop the
-- flat `rooms`. boundary: legitimate SV migration -- runs once at LoadFromSavedVariables
-- (ADDON_LOADED), where HDG.Projects.IDs is loaded. Pre-release + cheap (no live users).
local function MigrateProjectsToVersions(state)
    local p = state.account.projects
    if (p.schemaVersion or 1) >= 2 then
        p.rooms = nil   -- guarantee the legacy flat map is gone even on an already-migrated DB
        return
    end
    -- Seed the (pre-v7) versions container ONLY while actually migrating --
    -- post-v7 it stays retired (MigrateToFurnishings consumes + removes it).
    p.versions = p.versions or {}
    local nowTS = (time and time()) or 0   -- exception(boundary): createdAt stamp for seeded versions
    -- Seed a current version for every known house first, then fold each flat room into
    -- its house's current version (minting the house on demand if a room references a
    -- house that was never UPSERT'd -- parsePath gives a well-formed houseID).
    for houseID in pairs(p.houses) do
        local house = p.houses[houseID]
        _ensureHouseVersion(p, houseID, house.lastCapturedAt or nowTS)
    end
    for roomID, room in pairs(p.rooms or {}) do
        local parsed  = HDG.Projects.IDs.parsePath(roomID)
        local houseID = parsed and parsed.houseID
        if houseID then
            local vid = _ensureHouseVersion(p, houseID, nowTS)
            room.cell = room.cell or { x = 0, y = 0, rotation = 0, locked = false }
            room.plannedOnly = nil   -- the captured/planned split is now WHICH version, not a flag
            p.versions[vid].rooms[roomID] = room
        end
    end
    for _, coll in pairs(state.account.collections) do
        if coll.type == "crate" and coll.parent and not coll.versionID then
            local parsed  = HDG.Projects.IDs.parsePath(coll.parent)
            local houseID = parsed and parsed.houseID
            local house   = houseID and p.houses[houseID]
            if house and house.currentVersionID then coll.versionID = house.currentVersionID end
        end
    end
    p.rooms = nil
    p.schemaVersion = 2
end

local function EnsureStateShape(state)
    state.account = state.account or {}
    state.account.schemaVersion = state.account.schemaVersion or HDG.Constants.SCHEMA_VERSION
    EnsureConfig(state.account)
    EnsureUI(state.account)
    EnsureCollection(state.account)
    state.account.catalogVintage = state.account.catalogVintage or NewCatalogVintage()   -- exception(boundary): SV migration -- vintage tracking added post-3.3.0
    state.account.favorites   = state.account.favorites   or NewFavorites()
    state.account.userNotes   = state.account.userNotes   or NewUserNotes()
    state.account.vendorNotes = state.account.vendorNotes or NewVendorNotes()
    state.account.recipes     = state.account.recipes     or NewRecipes()
    EnsureCraft(state.account)
    EnsureShopping(state.account)
    state.account.characters  = state.account.characters  or NewCharacters()
    -- Backfill professionID onto pre-existing profession records (SV migration):
    -- records predating ID-stamping are keyed by the localized profession name and
    -- carry no .professionID. Recover it from the English name so the Alts summary
    -- (which joins by ID) keeps working with no rescan on enUS accounts; a localized
    -- (non-enUS) key won't match PROFESSION_DATA and heals on the next profession scan.
    for _, char in pairs(state.account.characters) do
        if type(char.professions) == "table" then   -- exception(boundary): SV migration -- record may be malformed
            for name, prof in pairs(char.professions) do
                if type(prof) == "table" and not prof.professionID then
                    local entry = HDG.Profession.GetByName(name)   -- exception(nullable): localized (non-enUS) key won't match
                    if entry then prof.professionID = entry.id end
                end
            end
        end
    end
    -- Runtime decor-recipe override (itemID -> { reagents = {[id]=qty}, profession }); unions
    -- across alts + guild scans, overrides the seed DB. Plain map; capture-wins per itemID.
    state.account.recipeCapture = state.account.recipeCapture or {}
    -- Sub-recipe craft graph (intermediates decor recipes need, walked to roots) --
    -- PowerCrafter's captured override of the shipped ProfessionsDB closure.
    state.account.subRecipeCapture = state.account.subRecipeCapture or {}
    -- Reagent quality groups ([memberID] = sibling ids): ANY tier satisfies a slot,
    -- so bag counting sums across the group. Captured live; overrides the seed's
    -- frozen variant data (GetQualityVariants reads this first).
    state.account.reagentVariants = state.account.reagentVariants or {}
    state.account.prices      = state.account.prices      or NewPrices()
    state.account.prices.directCache    = state.account.prices.directCache    or {}
    state.account.prices.directQtyCache = state.account.prices.directQtyCache or {}
    state.account.prices.ownedAuctions  = state.account.prices.ownedAuctions  or {}
    state.account.collections = state.account.collections or {}   -- exception(boundary): SavedVariables migration for Styles tab + Crates
    state.account.styleCategories  = state.account.styleCategories  or {}  -- exception(boundary): SV migration -- style categories added post-3.31
    state.account.styleCategorySeq = state.account.styleCategorySeq or 0   -- exception(boundary): pre-counter saved accounts lack styleCategorySeq
    -- Projects topology: re-ensure sub-fields so saves predating a field get it backfilled (SV migration).
    state.account.projects = state.account.projects or NewProjectsState()
    state.account.projects.houses      = state.account.projects.houses      or {}
    state.account.projects.versionSeq  = state.account.projects.versionSeq  or 0
    state.account.projects.houseFocusSeq = state.account.projects.houseFocusSeq or 0
    MigrateProjectsToVersions(state)   -- schemaVersion 1->2: flat rooms -> versions[current].rooms
    HDG.StoreFurnishings.EnsureShape(state)   -- furnishings shape + v6->7 migration (domain store file)
    -- Backfill floors=2 onto PLANNER-placed stair rooms (SV migration, sections
    -- model 2026-08-10): the stair shapes' GetFloors default dropped 2 -> 1
    -- (captured sections own one floor each), so planner records predating the
    -- change -- which carried no explicit .floors -- would silently shrink a
    -- storey. capturedID separates planner rooms (nil) from captured sections.
    for _, layout in pairs(state.account.projects.layouts) do
        if type(layout.placements) == "table" then   -- exception(boundary): SV migration -- record may be malformed
            for _, pl in pairs(layout.placements) do
                if pl.floors == nil and pl.capturedID == nil
                   and HDG.Projects.ShapeAtlas.IsStairShape(pl.shape) then
                    pl.floors = 2
                end
            end
        end
    end
    state.account.questCompletions = state.account.questCompletions or {}   -- exception(boundary): SV migration
    state.account.houseCapacityCache = state.account.houseCapacityCache or false   -- exception(boundary): SV migration -- buy-picker storage fallback added post-3.12
    -- Lumber tracker config + per-char sessions. Config key-by-key from NewLumberConfig
    -- so new defaults flow to existing users (SV migration).
    state.account.lumber          = state.account.lumber          or {}
    state.account.lumber.config   = state.account.lumber.config   or {}
    state.account.lumber.sessions = state.account.lumber.sessions or {}
    -- exception(boundary): SV migration -- farming history ring buffer added post-initial-release.
    state.account.lumber.history = state.account.lumber.history or {}
    state.account.lumber.history.entries = state.account.lumber.history.entries or {}
    state.account.lumber.history.nextID  = state.account.lumber.history.nextID  or 0
    local lumberDefaults = NewLumberConfig()
    for key, value in pairs(lumberDefaults) do
        if state.account.lumber.config[key] == nil then
            state.account.lumber.config[key] = DeepCopy(value)
        end
    end
    state.account.ui.companion = state.account.ui.companion or NewCompanionAccountUI()
    state.account.ui.companion.window = state.account.ui.companion.window or { x = nil, y = nil }
    state.account.ui.companion.launcher = state.account.ui.companion.launcher or { x = nil, y = nil }
    state.account.ui.companion.collapsedGroups = state.account.ui.companion.collapsedGroups or {}  -- exception(boundary): SV migration -- companion group folds added post-3.31
    -- Recent Activity (HDG parity). boundary: SV migration -- guarantees the
    -- slice for saves created before edit-session history existed.
    state.account.recentActivity = state.account.recentActivity or NewRecentActivity()
    -- Blueprints (12.1): the pasted-code LIBRARY persists (codes + their type
    -- tags + player labels, keyed by shareCode). Manifests stay session -- they
    -- re-fetch from the server on demand.
    state.account.blueprints = state.account.blueprints or { labels = {} }  -- exception(boundary): SV migration, versioned data
    state.account.blueprints.labels      = state.account.blueprints.labels      or {}  -- exception(boundary): SV migration
    state.account.blueprints.pasted      = state.account.blueprints.pasted      or {}  -- exception(boundary): SV migration
    state.account.blueprints.pastedTypes = state.account.blueprints.pastedTypes or {}  -- exception(boundary): SV migration
    state.account.blueprints.factions    = state.account.blueprints.factions    or {}  -- exception(boundary): SV migration (shareCode -> "Alliance"|"Horde")
    state.account.blueprints.pastedAt    = state.account.blueprints.pastedAt    or {}  -- exception(boundary): SV migration (shareCode -> time())
    state.account.blueprints.notes       = state.account.blueprints.notes       or {}  -- exception(boundary): SV migration (shareCode -> note text)
    -- 3.33.0 shipped an `applied` slice for an apply-history ledger that was
    -- cancelled before anything wrote to it. Drop the orphan rather than carry
    -- an empty table in every SavedVariables file forever.
    state.account.blueprints.applied     = nil  -- exception(boundary): SV migration, removes a dead 3.33.0 slice
    state.account.ui.blueprints = state.account.ui.blueprints or { collapsedSections = {} }  -- exception(boundary): SV migration
    state.account.ui.blueprints.collapsedSections = state.account.ui.blueprints.collapsedSections or {}  -- exception(boundary): SV migration
    if state.account.ui.blueprints.hideBackups == nil then state.account.ui.blueprints.hideBackups = true end  -- exception(boundary): SV migration (false is a real value)
    state.account.recentActivity.houses = state.account.recentActivity.houses or {}
    state.account.ui.houseTab = state.account.ui.houseTab or NewHouseTabAccountUI()
    state.account.ui.houseTab.enabled         = state.account.ui.houseTab.enabled         or {}
    state.account.ui.houseTab.order           = state.account.ui.houseTab.order           or {}
    state.account.ui.houseTab.width           = state.account.ui.houseTab.width           or {}
    state.account.ui.houseTab.layoutOverrides = state.account.ui.houseTab.layoutOverrides or {}
    -- Recipes persisted filters (SETs; empty = all). boundary: SV migration --
    -- guarantees the tables for saves created before these fields existed.
    state.account.ui.recipes = state.account.ui.recipes or {}
    state.account.ui.recipes.expansionFilter        = state.account.ui.recipes.expansionFilter        or {}
    state.account.ui.recipes.professionFilterByChar  = state.account.ui.recipes.professionFilterByChar or {}
    EnsureSession(state)
end

-- ===== Store object ===========================================================

HDG.Store = {
    state = NewDefaultState(),
    _subscribers = {},
    _pendingNotifications = nil,
    _flushScheduled = false,
    _loggedSubscriberErrors = {},   -- message -> true; _callSubscriber logs each once per session
    _saveTimer = nil,
    _saveDelay = 1,   -- seconds to coalesce saves
}

-- Public accessor for the action-meta table stamped by HDGR_Init.lua at
-- boot. Encapsulates _actionMeta so external readers (Components dispatcher,
-- tests) don't reach into the underscore-prefixed field. Returns nil for
-- unknown action types -- callers should treat nil as "no meta declared,
-- use defaults" (matches the per-field reads in dispatch hot paths).
function HDG.Store:GetActionMeta(actionType)
    return self._actionMeta and self._actionMeta[actionType] or nil
end

function HDG.Store:GetState()
    return self.state
end

function HDG.Store:GetConfig(key)
    -- Strict read of the canonical path. Loud failure (Lua error) if state
    -- hasn't been initialized -- callers must run after Store:LoadFromSavedVariables.
    return self.state.account.config[key]
end

-- Returns a fresh table of the canonical NewConfig() defaults. Used by the
-- Blizzard Settings panel's "Reset all settings" button: iterate the keys
-- on the panel and dispatch CONFIG_SET per key with defaults[key] as the
-- value. NewConfig is the single source of truth for default values.
function HDG.Store:GetDefaultConfig()
    return NewConfig()
end

-- ===== Subscribe / Notify =====================================================

function HDG.Store:Subscribe(fn)
    if type(fn) ~= "function" then return nil end
    self._subscribers[fn] = true
    return fn
end

function HDG.Store:Unsubscribe(fn)
    self._subscribers[fn] = nil
end

-- One subscriber call: an error is logged AND re-raised (the HDGR_Modules.lua
-- onInitialize shape). The flush runs outside ErrorBoundaryMiddleware, so before
-- this a subscriber error reached only geterrorhandler() -- silent for a player
-- without BugSack ("window won't open, no errors showing", Discord 2026-10-08,
-- docs/WINDOW_WONT_OPEN_2026-10-08.md). The re-raise keeps ADR-042: nothing is
-- swallowed and the rest of the flush still aborts. Logged once per distinct
-- message: Log:Error dispatches LOG_PUSH, which schedules the next flush, so a
-- subscriber that throws on every action would otherwise log itself every frame.
-- The Log entry lands on the status rail and Debug tab, both inside the main
-- window this failure can keep shut, so the same message also goes straight to
-- chat (PrintDirect: not through the flush that is failing) for the player to report.
local function _callSubscriber(store, fn, n)
    local ok, err = pcall(fn, n.type, n.invalidation, n.action)
    if ok then return end
    local msg = tostring(err)
    if not store._loggedSubscriberErrors[msg] then
        store._loggedSubscriberErrors[msg] = true
        HDG.Log:PrintDirect("error", "Hit an error -- please screenshot this line and report it on Discord: " .. msg)
        HDG.Log:Error("error", ("subscriber error (action=%s): %s"):format(tostring(n.type), msg))
    end
    error(err, 0)   -- level 0: err already carries the subscriber's file:line
end

-- Deferred notification: C_Timer.After(0) batches multiple dispatches in the
-- same frame, fanning each accumulated action out to every subscriber on
-- the next frame. Prevents re-entrant-flush corruption (a subscriber that
-- dispatches back into the store cannot perturb the in-progress loop).
--
-- Each notification carries an `invalidation` value (a list of
-- state paths OR the sentinel "*") so subscribers can filter their work
-- by what actually changed. Subscribers that only consume actionType
-- continue to work -- the second arg is additive.
function HDG.Store:_Notify(actionType, invalidation, action)
    invalidation = invalidation or "*"
    self._pendingNotifications = self._pendingNotifications or {}
    self._pendingNotifications[#self._pendingNotifications + 1] = {
        type        = actionType,
        invalidation = invalidation,
        action      = action,
    }
    if self._flushScheduled then return end
    self._flushScheduled = true

    local function flush()
        local pending = self._pendingNotifications
        self._pendingNotifications = nil
        self._flushScheduled = false
        if not pending then return end
        local snapshot = {}
        for fn in pairs(self._subscribers) do snapshot[#snapshot + 1] = fn end
        -- No swallowing pcall (ADR-042): real bugs must surface loudly. NOTE: this
        -- flush runs on a deferred C_Timer, OUTSIDE the dispatch chain -- so
        -- ErrorBoundaryMiddleware does NOT cover it. _callSubscriber reports a raising
        -- subscriber (chat line + Debug tab + status rail), then re-raises it, which aborts
        -- the remaining subscribers for this flush; that loss is deliberate (the
        -- alternative silently runs downstream subscribers against state the
        -- failed one never processed).
        -- exception(boundary): Perf instrumentation is optional, may be absent in early boot / tests.
        local perf = HDG.Perf
        local timed = perf and perf:Enabled()
        local t0, k0
        if timed then t0, k0 = perf:Open() end

        for _, n in ipairs(pending) do
            for _, fn in ipairs(snapshot) do
                _callSubscriber(self, fn, n)
            end
        end

        if timed then
            perf:RecordFlush(pending, t0, k0, #snapshot)
        end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, flush)
    else
        flush()
    end
end

-- Synchronous flush. Used at PLAYER_LOGOUT where the deferred C_Timer.After
-- callback won't fire before the client unloads -- subscribers registered
-- on SESSION_END would be silently dropped otherwise. Drains the same
-- pending queue the deferred flush would, with identical fan-out shape.
function HDG.Store:FlushNotifications()
    if not self._pendingNotifications then return end
    local pending = self._pendingNotifications
    self._pendingNotifications = nil
    self._flushScheduled = false
    local snapshot = {}
    for fn in pairs(self._subscribers) do snapshot[#snapshot + 1] = fn end
    -- Same log-and-re-raise as the deferred flush path.
    for _, n in ipairs(pending) do
        for _, fn in ipairs(snapshot) do
            _callSubscriber(self, fn, n)
        end
    end
end

-- ===== Reducer (pure, no side effects) =======================================
-- Every state mutation in HDG lives here. The middleware chain wraps this
-- call so Logger / Combat / Persistence layers fire at the right edges
-- without the reducer caring.

-- Shared reducer micro-idioms (hygiene review A'1): the boolean flip and the
-- sparse-set membership flip that ~25 toggle reducers hand-rolled inline.
local function _toggleBool(t, field)
    t[field] = not (t[field] == true)
end
local function _toggleSetMember(set, key)
    set[key] = not (set[key] == true) and true or nil
end

-- Multi-select filter-set toggle: value=="all" clears the set (-> "All"); else
-- flip membership. Shared by the ACQ_TOGGLE_* cases and RECIPES_TOGGLE_EXPANSION
-- (empty set = all).
local function _acqToggleFilter(set, value)
    if value == "all" then
        wipe(set)
    else
        _toggleSetMember(set, value)
    end
end

function HDG.Store:_RawDispatch(action)
    if type(action) ~= "table" or not action.type then
        error("HDG.Store:_RawDispatch requires {type=..., payload=?}", 2)
    end
    local payload = action.payload or {}
    -- EnsureStateShape deliberately NOT called here (engine-review 2026-06-07,
    -- removed 2026-07-17): it's a boot/migration guard and runs in
    -- LoadFromSavedVariables. Per-dispatch re-minting cost allocations + ~80
    -- field checks on EVERY action and, worse, silently healed shape drift a
    -- reducer bug should surface loudly. HARD_RESET re-mints from
    -- NewDefaultState(); PROFILE_SWITCH imports schema defaults before
    -- rehydrating -- neither depends on this.

    -- Resolve the invalidation set BEFORE running the reducer.
    -- Action meta declares `invalidates` as a static list, a function
    -- (payload-dependent), or "*". Actions without meta or without an
    -- `invalidates` field implicitly default to "*" (refresh-all).
    local invalidation = "*"
    local meta = self._actionMeta and self._actionMeta[action.type]
    if meta then
        local inv = meta.invalidates
        if type(inv) == "function" then
            -- Strict call (ADR-042): invalidates fns are registered internal
            -- code -- a throw aborts the dispatch and surfaces via the outer
            -- ErrorBoundary instead of degrading to refresh-all behind a Warn.
            -- nil return stays the documented refresh-all default.
            invalidation = inv(action) or "*"
        elseif inv ~= nil then
            invalidation = inv
        end
    end

    -- Every action is a self-registered block (HDG.Actions): reduce +
    -- invalidates + flags declared in one place, dispatched by lookup.
    -- Closed taxonomy: an unregistered type is a typo; fail loud.
    local entry = HDG.Actions._entries[action.type]
    if not entry then
        error(("HDG.Store:_RawDispatch: unknown action type %q"):format(
            tostring(action.type)), 2)
    end
    entry.reduce(self.state, payload)

    -- Invalidate memos BEFORE _Notify so subscribers re-resolve selectors with fresh values.
    HDG.Selectors:InvalidateMemos(invalidation)
    self:_Notify(action.type, invalidation, action)
end

-- Public Dispatch defaults to _RawDispatch when no middleware chain has
-- been installed. Middleware.Apply (Core/HDGR_Init) wraps this with the
-- Logger / Combat / Persistence layers.
function HDG.Store:Dispatch(action)
    return self:_RawDispatch(action)
end

-- ===== SavedVariables I/O ====================================================

function HDG.Store:LoadFromSavedVariables()
    _G.HDG_DB = _G.HDG_DB or {}
    -- Run in-place migration BEFORE adopting account. For existing HDG users,
    -- HDG_DB is actually the old HDG_DB (same table after the P2 rename);
    -- HDG.Migration:Run transforms flat HDG keys -> HDG account.* shape.
    -- No-op when DB is already at HDG schema or when Migration module is absent.
    if HDG.Migration and HDG.Migration.Run then  -- exception(boundary): module absent in early-boot tests that load only Store
        -- Stash the result so the one-time upgrade notice can fire at OnEnable.
        HDG.Migration.lastResult = HDG.Migration:Run(_G.HDG_DB)
    end
    self.state = NewDefaultState()
    if _G.HDG_DB.account then
        -- Adopt persisted account verbatim, then merge defaults so newly
        -- added keys land for upgraded users (schema migration runs here).
        self.state.account = _G.HDG_DB.account
    end
    EnsureStateShape(self.state)
    HDG.StoreFurnishings.ScrubFossilPlacements(self.state)   -- hydrate-only: drop pre-v8 room-keyed placements (shape-gated, not version-gated)
    HDG.StoreFurnishings.RebuildIndexes(self.state)   -- hydrate-only: session-derived; reducer cases maintain incrementally
end

-- Coalesced save: dispatches within a frame share one write.
function HDG.Store:QueueSave()
    if self._saveTimer then return end
    if not (C_Timer and C_Timer.NewTimer) then
        -- Outside WoW (tests). Flush immediately.
        self:Flush()
        return
    end
    self._saveTimer = C_Timer.NewTimer(self._saveDelay, function()
        self._saveTimer = nil
        self:Flush()
    end)
end

-- Flush: by-reference write -- state.account IS HDG_DB.account (no DeepCopy).
-- WoW serializes whatever HDG_DB points at on logout; re-link is a cheap safety check.
function HDG.Store:Flush()
    _G.HDG_DB = _G.HDG_DB or {}
    _G.HDG_DB.account = self.state.account
end

-- ===== Self-registered actions (SELFREG conversion; bodies verbatim from
-- the former _RawDispatch chain, self.state -> state) ======================
local P = HDG.Paths   -- payload-keyed invalidates fns (moved from BuildActionMeta scope)

HDG.Actions:Register{ name = "CONFIG_SET",
    persists = true,  combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.config", action.payload and action.payload.key) } end,
    reduce = function(state, payload)
        if payload.key ~= nil then
            -- Dual-write: SV slot (profile / character / account, routed
            -- by HDG.Config) AND the in-memory mirror at
            -- state.account.config. Mirror keeps existing selectors with
            -- `reads = { "account.config.X" }` working unchanged.
            -- Scope resolution: explicit payload.scope wins; otherwise
            -- look it up from the schema. Keys absent from both are a
            -- schema-drift bug -- we crash loudly rather than silently
            -- mis-route the write.
            local scope = payload.scope or HDG.ConfigSchema.ScopeBy[payload.key]
            local src = HDG.Config:_GetSourceForScope(scope)
            src[payload.key] = payload.value
            -- Account-scoped settings (one-time migration flags) live at
            -- the top of HDG_DB and don't belong in the per-profile mirror.
            if scope ~= HDG.Constants.ConfigScope.Account then
                state.account.config[payload.key] = payload.value
            end
        end
    end }

HDG.Actions:Register{ name = "CONFIG_SCALE_STEP",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.config.scale" },
    reduce = function(state, payload)
        -- Step the UI scale by +/-0.1 within [0.5, 1.5] (bounds mirror the Config controller's
        -- SCALE_MIN/MAX/STEP). Reducer owns the clamp; the view dispatches only a direction.
        -- Same dual-write as CONFIG_SET (SV source + in-memory mirror); scale is profile-scoped.
        local cur = state.account.config.scale
        local nxt = cur + (payload.direction == "inc" and 0.1 or -0.1)
        nxt = (payload.direction == "inc") and math.min(1.5, nxt) or math.max(0.5, nxt)
        nxt = math.floor(nxt * 10 + 0.5) / 10
        local scope = HDG.ConfigSchema.ScopeBy["scale"]
        HDG.Config:_GetSourceForScope(scope)["scale"] = nxt
        if scope ~= HDG.Constants.ConfigScope.Account then
            state.account.config.scale = nxt
        end
    end }

HDG.Actions:Register{ name = "PROFILE_CREATE",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.profileList" },
    reduce = function(state, payload)
        local name = payload.name
        if type(name) == "string" and name ~= "" and not HDG_DB.profiles[name] then
            HDG_DB.profiles[name] = {}
            if payload.cloneFrom and HDG_DB.profiles[payload.cloneFrom] then
                for k, v in pairs(HDG_DB.profiles[payload.cloneFrom]) do
                    HDG_DB.profiles[name][k] = v
                end
            end
        end
    end }

-- PROFILE_* reducers: ACCEPTED Invariant-6 deviation (engine-review 2026-06-07,
-- dispositioned 2026-07-17). HDG_DB.profiles IS the persistence root for
-- per-profile config -- deliberately outside state.account; nothing reads it but
-- the hydration path, and the reducer is the natural transaction point (import
-- defaults THEN hydrate mirror, synchronously, before the deferred subscriber
-- flush repaints). A middleware move = same code, new ordering risk, no payoff.
HDG.Actions:Register{ name = "PROFILE_SWITCH",
    persists = true,  combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        local name = payload.name
        if type(name) == "string" and HDG_DB.profiles[name] then
            HDG_DB_CURRENT_PROFILE = name
            HDG.Config._activeProfile = name
            HDG.Config:_ImportDefaultsToActiveProfile()
            HDG.Config:_HydrateMirror()
        end
    end }

HDG.Actions:Register{ name = "PROFILE_DELETE",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.profileList" },
    reduce = function(state, payload)
        local name = payload.name
        if type(name) == "string" and name ~= "DEFAULT" and name ~= HDG.Config._activeProfile then
            HDG_DB.profiles[name] = nil
        end
    end }

HDG.Actions:Register{ name = "UI_SET_PERSISTENT",
    persists = true,  combatUnsafe = false,
            invalidates = function(action)
                local key = action.payload and action.payload.key
                local paths = { HDG.Paths.Join("account.ui", key) }
                -- A tab switch is the one moment every "leave this tab" passes through.
                if key == "view" then paths[2] = "session.ui.decor.pinnedSortCounts" end
                return paths
            end,
    reduce = function(state, payload)
        if payload.key ~= nil then state.account.ui[payload.key] = payload.value end
        -- Leaving the Decor tab lets the Destroy decor list re-sort when the
        -- player comes back (the pin only holds it still while they are on it).
        if payload.key == "view" then state.session.ui.decor.pinnedSortCounts = nil end
    end }

HDG.Actions:Register{ name = "UI_SET_TRANSIENT",
    persists = false, combatUnsafe = false,
            invalidates = function(action)
                local p = action.payload or {}
                if p.view then
                    return { P.Join("session.ui", p.view, p.key) }
                end
                return { P.Join("session.ui", p.key) }
            end,
    reduce = function(state, payload)
        if payload.view then
            state.session.ui[payload.view] = state.session.ui[payload.view] or {}
            if payload.key ~= nil then
                state.session.ui[payload.view][payload.key] = payload.value
            end
        else
            if payload.key ~= nil then
                state.session.ui[payload.key] = payload.value
            end
        end
    end }

HDG.Actions:Register{ name = "REMOVALIST_PICK_PLOT",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.removalist.sourcePlot", "session.ui.removalist.targetPlot" },
    reduce = function(state, payload)
        -- Two-click cycle: 1st pick -> source, 2nd (distinct) -> target, else restart.
        local r    = state.session.ui.removalist
        local plot = payload.plot
        if not r.sourcePlot then
            r.sourcePlot = plot
        elseif not r.targetPlot and plot ~= r.sourcePlot then
            r.targetPlot = plot
        else
            r.sourcePlot, r.targetPlot = plot, nil
        end
    end }

HDG.Actions:Register{ name = "REMOVALIST_SWAP",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.removalist.sourcePlot", "session.ui.removalist.targetPlot" },
    reduce = function(state, payload)
        local r = state.session.ui.removalist
        r.sourcePlot, r.targetPlot = r.targetPlot, r.sourcePlot
    end }

HDG.Actions:Register{ name = "REMOVALIST_CLEAR",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.removalist.sourcePlot", "session.ui.removalist.targetPlot" },
    reduce = function(state, payload)
        local r = state.session.ui.removalist
        r.sourcePlot, r.targetPlot = nil, nil
    end }

HDG.Actions:Register{ name = "REMOVALIST_SET_LETTER_FILTER",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.removalist.letterFilter" },
    reduce = function(state, payload)
        -- nil payload (refresh) or re-clicking the active letter clears; else set.
        local r = state.session.ui.removalist
        local l = payload.letter
        if l == nil or r.letterFilter == l then r.letterFilter = nil else r.letterFilter = l end
    end }

HDG.Actions:Register{ name = "REMOVALIST_SET_PLOT",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.removalist.sourcePlot", "session.ui.removalist.targetPlot" },
    reduce = function(state, payload)
        -- Map-click selection: the Source map sets source, the Target map sets target.
        local r = state.session.ui.removalist
        if payload.role == "source" then r.sourcePlot = payload.plot
        elseif payload.role == "target" then r.targetPlot = payload.plot end
    end }

HDG.Actions:Register{ name = "MAIN_WINDOW_TOGGLE",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.ui.mainWindowShown" },
    reduce = function(state, payload)
        _toggleBool(state.account.ui, "mainWindowShown")
    end }

HDG.Actions:Register{ name = "NAV_TOGGLE_GROUP",
    persists = true,  combatUnsafe = false,
    -- A fold changes one node's isCollapsed and nothing else, so the treeList
    -- widget can mutate the live provider in place instead of rebuilding every
    -- TreeNode (HDG.TreeList:SetItems honours this flag; it falls back to a full
    -- rebuild if the root count changed). The path existed and no action ever
    -- declared the flag, so every fold paid the rebuild (2026-09-13 audit).
    treeCollapseOnly = true,
            invalidates = { "account.ui.nav.collapsedGroups" },
    reduce = function(state, payload)
        -- Flip a sidebar parent group's collapsed state (keyed by hub view).
        -- nil-clear when expanding so the set stays sparse (only collapsed groups present).
        local groups = state.account.ui.nav.collapsedGroups
        local v = payload.view
        groups[v] = (not groups[v]) and true or nil
    end }

HDG.Actions:Register{ name = "SESSION_END",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.ui.mainWindowShown",
                            "account.ui.shoppingWidgetShown",
                            "account.ui.zonePopupShown",
                            "account.lumber.config.windowVisible" },
    reduce = function(state, payload)
        -- Force all addon windows closed at logout (don't auto-reopen on /reload).
        -- Zone auto-popup fires on ZONE_CHANGED independently (not from these flags).
        state.account.ui.mainWindowShown        = false
        state.account.ui.shoppingWidgetShown    = false
        state.account.ui.zonePopupShown         = false
        state.account.lumber.config.windowVisible = false
    end }

HDG.Actions:Register{ name = "HARD_RESET",
    persists = true,  combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        -- In-place account reset. state.account is shared BY REFERENCE (Store.state
        -- + HDG_DB.account via Flush): rebinding a local here resets nothing, and
        -- this action's own persists=true Flush re-links the old table right back
        -- over a bare `HDG_DB = {}` wipe before any /reload can serialize it.
        local fresh = NewDefaultState().account
        for k in pairs(state.account) do state.account[k] = nil end
        for k, v in pairs(fresh) do state.account[k] = v end
        -- NewDefaultState is INCOMPLETE by design debt: post-release slots
        -- (houseTab, lumber, blueprints, recipeCapture, ...) live only as
        -- EnsureStateShape backfills. Run it here so the reset shape is whole --
        -- surfaced 2026-07-17 when the per-dispatch Ensure (which silently healed
        -- this) was removed. Folding backfills into the factories is the real fix
        -- (see TODO: factory completeness).
        EnsureStateShape(state)
        -- Fresh SV root: drops profiles + characterSpecific too ("wipes ALL HDG
        -- data"). Seed the active/default profile buckets and the char bucket so
        -- Config reads stay valid until the /reload the reset UX already requires.
        local active = _G.HDG_DB_CURRENT_PROFILE or "DEFAULT"  -- exception(boundary): per-char SV, absent on first boot
        _G.HDG_DB = { account = state.account,
                      profiles = { [active] = {}, DEFAULT = {} },
                      characterSpecific = {} }
        _G.HDG_DB_CURRENT_PROFILE = nil
    end }

HDG.Actions:Register{ name = "COLLECTION_RESET",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.collection" },
    reduce = function(state, payload)
        -- Wipe the ownership cache so the next reconciler sweep rebuilds from
        -- scratch. The catalog mirror (decorCatalog/catalogByItem/liveDecorIDs)
        -- HousingCatalogObserver owns the row store and clears it on COLLECTION_RESET.
        state.account.collection.ownedDecorIDs = {}
    end }

HDG.Actions:Register{ name = "COMBAT_ENTER",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.combat.inLockdown" },
    reduce = function(state, payload)
        state.session.combat.inLockdown = true
    end }

HDG.Actions:Register{ name = "COMBAT_EXIT",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.combat.inLockdown", "session.combat.queued" },
    reduce = function(state, payload)
        state.session.combat.inLockdown = false
        -- Reducer empties the queue here so middleware never mutates state
        -- directly. CombatMiddleware snapshots the queue BEFORE dispatching
        -- COMBAT_EXIT and re-dispatches the snapshot through the chain.
        state.session.combat.queued = {}
    end }

HDG.Actions:Register{ name = "ACQ_SET_ITEMS_VIEW_MODE",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.ui.acquisition.itemsViewMode" },
    reduce = function(state, payload)
        local mode = payload.mode
        if mode == "grid" or mode == "list" then
            -- account.ui.acquisition seeded by EnsureUI on every dispatch (ADR-005)
            state.account.ui.acquisition.itemsViewMode = mode
        end
    end }

HDG.Actions:Register{ name = "ACQ_TOGGLE_ADVANCED_FILTERS",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.advancedFiltersOpen" },
    reduce = function(state, payload)
        local a = state.session.ui.acquisition
        _toggleBool(a, "advancedFiltersOpen")
    end }

HDG.Actions:Register{ name = "ACQ_SET_PRESET",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.preset" },
    reduce = function(state, payload)
        -- Single-select preset chip; toggling the active value clears it.
        -- Note: Lua 5.1 `(cond) and nil or v` trap -- must use a real branch when value is nil.
        local v = payload.value
        if state.session.ui.acquisition.preset == v then
            state.session.ui.acquisition.preset = nil
        else
            state.session.ui.acquisition.preset = v
        end
    end }

HDG.Actions:Register{ name = "ACQ_TOGGLE_MISSING",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.missingOnly" },
    reduce = function(state, payload)
        -- Collection-state toggle, orthogonal to the source preset. Flips so
        -- the Missing checkbox ANDs with whatever source chip is lit.
        state.session.ui.acquisition.missingOnly =
            not state.session.ui.acquisition.missingOnly

    -- Advanced-filter multi-select set toggles. payload.<axis> == "all" clears the
    -- set (master "All X" -> show every value); else flip membership. Empty = all.
    -- Clone of RECIPES_TOGGLE_EXPANSION; session-scoped (no persistence).
    end }

HDG.Actions:Register{ name = "ACQ_TOGGLE_EXPANSION",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.expansionFilter" },
    reduce = function(state, payload)
        _acqToggleFilter(state.session.ui.acquisition.expansionFilter, payload.expansion)
    end }

HDG.Actions:Register{ name = "ACQ_TOGGLE_ZONE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.zoneFilter" },
    reduce = function(state, payload)
        _acqToggleFilter(state.session.ui.acquisition.zoneFilter, payload.zone)
    end }

HDG.Actions:Register{ name = "ACQ_TOGGLE_REP",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.repFilter" },
    reduce = function(state, payload)
        _acqToggleFilter(state.session.ui.acquisition.repFilter, payload.rep)
    end }

HDG.Actions:Register{ name = "ACQ_TOGGLE_SOURCE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.sourceFilter" },
    reduce = function(state, payload)
        _acqToggleFilter(state.session.ui.acquisition.sourceFilter, payload.source)
    end }

HDG.Actions:Register{ name = "ACQ_TOGGLE_FACTION",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.acquisition.factionFilter" },
    reduce = function(state, payload)
        _acqToggleFilter(state.session.ui.acquisition.factionFilter, payload.faction)
    end }

HDG.Actions:Register{ name = "MAIN_WINDOW_OPENING",
    persists = false, combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        -- Lifecycle signal; no mutation. Subscribers handle catch-up.
    end }

HDG.Actions:Register{ name = "LOG_PUSH",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.log.entries" },
    reduce = function(state, payload)
        -- Pure append + cap. entry.id is a raw integer (no "log_" prefix needed).
        local log = state.session.log
        log.nextID = (log.nextID or 0) + 1
        local entry = {
            id        = log.nextID,
            tag       = payload.tag,
            level     = payload.level,
            text      = payload.text,
            timestamp = payload.timestamp,
            duration  = payload.duration,
            metadata  = payload.metadata,
        }
        log.entries[#log.entries + 1] = entry
        -- Per-tag sub-cap for the "dispatch" tag; removes oldest first. Running
        -- count (log.dispatchN) replaces the old per-push O(n) rescan; the ring
        -- cap below keeps it honest when it evicts a dispatch entry.
        if entry.tag == "dispatch" then
            log.dispatchN = (log.dispatchN or 0) + 1
            while log.dispatchN > log.dispatchCap do
                for i, e in ipairs(log.entries) do
                    if e.tag == "dispatch" then
                        table.remove(log.entries, i)
                        log.dispatchN = log.dispatchN - 1
                        break
                    end
                end
            end
        end
        -- Overall ring buffer cap.
        local cap = log.cap
        while #log.entries > cap do
            local evicted = table.remove(log.entries, 1)
            if evicted.tag == "dispatch" then
                log.dispatchN = (log.dispatchN or 1) - 1
            end
        end
    end }

HDG.Actions:Register{ name = "LOG_CLEAR",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.log.entries" },
    reduce = function(state, payload)
        local log = state.session.log
        if payload.tag and payload.tag ~= "all" and payload.tag ~= "*" then
            local entries = log.entries
            for i = #entries, 1, -1 do
                if entries[i].tag == payload.tag then
                    if entries[i].tag == "dispatch" then
                        log.dispatchN = (log.dispatchN or 1) - 1
                    end
                    table.remove(entries, i)
                end
            end
            if payload.tag == "dispatch" then log.dispatchN = 0 end
        else
            log.entries = {}
            log.dispatchN = 0   -- keep the running dispatch-cap counter honest
        end
    end }

HDG.Actions:Register{ name = "LOG_SET_FILTER",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.log.tabFilter" },
    reduce = function(state, payload)
        local f = state.session.log.tabFilter
        if payload.tag        ~= nil then f.tag        = payload.tag        end
        if payload.level      ~= nil then f.level      = payload.level      end
        if payload.autoScroll ~= nil then f.autoScroll = payload.autoScroll end
    end }

HDG.Actions:Register{ name = "LOG_TOGGLE_AUTOSCROLL",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.log.tabFilter" },
    reduce = function(state, payload)
        local f = state.session.log.tabFilter
        _toggleBool(f, "autoScroll")
    end }

HDG.Actions:Register{ name = "COLLECTION_BULK_LOAD",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.collection" },
    reduce = function(state, payload)
        -- Wholesale ownership replace. Catalog mirrors are observer-local;
        -- only ownedDecorIDs persists (warm-start seam: HousingCatalogObserver's
        -- _priorOwnership reads it before the session's first build commits).
        state.account.collection.ownedDecorIDs = payload.owned
    end }

HDG.Actions:Register{ name = "COLLECTION_ITEM_LEARNED",
    persists = true,  combatUnsafe = false,
    retainsScroll = true,  -- one piece changed in place; a grid that resets to the top loses the player's place mid-placement (Discord 2026-09-06)
            invalidates = { "account.collection.ownedDecorIDs" },
    reduce = function(state, payload)
        if payload.decorID then
            state.account.collection.ownedDecorIDs[payload.decorID] = true
        end
    end }

HDG.Actions:Register{ name = "COLLECTION_ITEM_REMOVED",
    persists = true,  combatUnsafe = false,
    retainsScroll = true,  -- one piece changed in place; a grid that resets to the top loses the player's place mid-placement (Discord 2026-09-06)
            invalidates = { "account.collection.ownedDecorIDs" },
    reduce = function(state, payload)
        if payload.decorID then
            state.account.collection.ownedDecorIDs[payload.decorID] = nil
        end
    end }

HDG.Actions:Register{ name = "CATALOG_VINTAGE_UPDATE",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.catalogVintage" },
    reduce = function(state, payload)
        -- Observer snapshot diff (see HousingCatalogObserver:_UpdateVintage).
        -- Seed: first-ever sweep populates the snapshot only -- no batch.
        -- Diff: ids join the snapshot AND the current-build "new" batch; a
        -- build change retires the previous patch's batch first. Same-build
        -- ids (mid-patch hotfix additions) merge into the running batch.
        -- Label stamps on EVERY non-seed dispatch (build + label travel
        -- together in the payload; refreshing only on build change let a
        -- same-build merge keep a stale label).
        local cv = state.account.catalogVintage
        if not payload.isSeed then
            if payload.build ~= cv.newBuild then
                cv.newIds, cv.newBuild = {}, payload.build
            end
            cv.newBuildLabel = payload.label
        end
        for _, itemID in ipairs(payload.ids) do
            cv.snapshot[itemID] = true
            if not payload.isSeed then cv.newIds[itemID] = true end
        end
        cv.snapshotBuild = payload.build
    end }

HDG.Actions:Register{ name = "LOG_TRACE_TOGGLE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.log.activeTraces" },
    reduce = function(state, payload)
        if payload.tag == "*" or payload.tag == "all" then
            -- Wipe all traces (used by /hdgr trace off)
            state.session.log.activeTraces = {}
        elseif payload.tag then
            local on = payload.on
            if on == nil then
                -- Toggle if `on` not provided
                on = not state.session.log.activeTraces[payload.tag]
            end
            state.session.log.activeTraces[payload.tag] = on or nil
        end

    -- ===== Filter actions ============================================
    -- ensureDecorFilters keeps defaults in NewDecorFilters (SSoT); helpers run only inside _RawDispatch.
    end }

HDG.Actions:Register{ name = "DECOR_SET_TOP_FILTER",
    persists = false, combatUnsafe = false, 
    invalidates = {
                "session.ui.decor.filters.topFilter",
                "session.ui.decor.filters.activeTag",
            },
    reduce = function(state, payload)
        local f = ensureDecorFilters(state)
        local v = payload.value
        -- Validate against HDG.Constants.TOP_FILTERS so the reducer rejects
        -- typo'd values from any caller. Single SSoT for the bucket set.
        local valid = false
        for _, entry in ipairs(HDG.Constants.TOP_FILTERS or {}) do
            if entry.value == v then valid = true; break end
        end
        if valid then
            f.topFilter = v
            -- Switching top filter always clears the active tag (ADR-018).
            f.activeTag = nil
        end
    end }

HDG.Actions:Register{ name = "DECOR_SET_TAG",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.decor.filters.activeTag" },
    reduce = function(state, payload)
        local f = ensureDecorFilters(state)
        if payload.tag == nil or type(payload.tag) == "string" then
            f.activeTag = payload.tag
        end
    end }

HDG.Actions:Register{ name = "DECOR_TOGGLE_ONLY_UNCOLLECTED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.decor.filters.onlyUncollected" },
    reduce = function(state, payload)
        local f = ensureDecorFilters(state)
        f.onlyUncollected = not f.onlyUncollected
    end }

HDG.Actions:Register{ name = "DECOR_TOGGLE_ONLY_STORED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.decor.filters.onlyStored", "session.ui.decor.pinnedSortCounts" },
    reduce = function(state, payload)
        local f = ensureDecorFilters(state)
        f.onlyStored = not f.onlyStored
        state.session.ui.decor.pinnedSortCounts = nil   -- the list comes back freshly sorted
    end }

HDG.Actions:Register{ name = "DECOR_SET_SEARCH",
    persists = false, combatUnsafe = false, noisy = true,
    invalidates = { "session.ui.decor.searchQuery" },
    reduce = function(state, payload)
        state.session.ui.decor.searchQuery = tostring(payload.query)

    -- ===== Favorites (G2) ====================================================
    end }

HDG.Actions:Register{ name = "FAVORITE_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.favorites" },
    reduce = function(state, payload)
        if payload.itemID then
            local fav = state.account.favorites
            if fav[payload.itemID] then
                fav[payload.itemID] = nil
            else
                fav[payload.itemID] = true
            end
        end

    -- ===== User notes (G3) ===================================================
    end }

HDG.Actions:Register{ name = "NOTE_SET",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.userNotes", action.payload and action.payload.itemID) } end,
    reduce = function(state, payload)
        if payload.itemID and payload.text ~= nil then
            state.account.userNotes[payload.itemID] = {
                text = payload.text,
                ts   = payload.ts or (_G.GetTime and _G.GetTime() or 0),  -- exception(boundary): GetTime/time absent in headless harness
            }
            -- LRU cap at 500. Iterate to find oldest; cheap at this size.
            local MAX_NOTES = 500
            local notes = state.account.userNotes
            local count = 0
            for _ in pairs(notes) do count = count + 1 end
            if count > MAX_NOTES then
                -- `n.ts or 0`: tolerates pre-1.0 savedvar entries that
                -- shipped without timestamps. Treats them as oldest so
                -- they evict first when over cap. Mark boundary so the
                -- sweep recognises the migration intent.
                local oldest_id, oldest_ts = nil, math.huge
                for id, n in pairs(notes) do
                    local ts = n.ts or 0  -- migration
                    if ts < oldest_ts then oldest_ts = ts; oldest_id = id end
                end
                if oldest_id then notes[oldest_id] = nil end
            end
        end
    end }

HDG.Actions:Register{ name = "NOTE_CLEAR",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.userNotes", action.payload and action.payload.itemID) } end,
    reduce = function(state, payload)
        if payload.itemID then
            state.account.userNotes[payload.itemID] = nil
        end

    -- ===== Vendor notes ======================================================
    end }

HDG.Actions:Register{ name = "VENDOR_NOTE_SET",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.vendorNotes", action.payload and action.payload.npcID) } end,
    reduce = function(state, payload)
        if payload.npcID and payload.text ~= nil then
            state.account.vendorNotes[payload.npcID] = {
                text = payload.text,
                ts   = payload.ts or (_G.GetTime and _G.GetTime() or 0),  -- exception(boundary): GetTime/time absent in headless harness
            }
            -- LRU cap at 100 (vendor count is much smaller than item count).
            local MAX_VENDOR_NOTES = 100
            local notes = state.account.vendorNotes
            local count = 0
            for _ in pairs(notes) do count = count + 1 end
            if count > MAX_VENDOR_NOTES then
                -- See item-note LRU comment above: `n.ts or 0` covers
                -- pre-1.0 savedvar entries without timestamps. Migration.
                local oldest_id, oldest_ts = nil, math.huge
                for id, n in pairs(notes) do
                    local ts = n.ts or 0  -- migration
                    if ts < oldest_ts then oldest_ts = ts; oldest_id = id end
                end
                if oldest_id then notes[oldest_id] = nil end
            end
        end
    end }

HDG.Actions:Register{ name = "VENDOR_NOTE_CLEAR",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.vendorNotes", action.payload and action.payload.npcID) } end,
    reduce = function(state, payload)
        if payload.npcID then
            state.account.vendorNotes[payload.npcID] = nil
        end

    -- ===== Recipe knowledge ==================================================
    end }

HDG.Actions:Register{ name = "RECIPE_KNOWLEDGE_UPDATED",
    persists = true, combatUnsafe = false,
            invalidates = { "account.recipes" },
    reduce = function(state, payload)
        -- Bulk replace: RecipeKnowledgeScanner emits the full per-itemID map.
        state.account.recipes = payload.entries

    -- ===== Crafting queue + history ==============================
    end }

HDG.Actions:Register{ name = "CRAFT_QUEUE_ADD",
    persists = true, combatUnsafe = false,
            invalidates = { "account.craft.queue" },
    reduce = function(state, payload)
        local q   = state.account.craft.queue
        local qty = payload.qty or 1   -- exception(boundary): slash-command dispatcher may omit qty for default-1 add
        -- Coalesce into an existing row with the same recipeID so repeated
        -- Add clicks accumulate qty instead of producing duplicate rows.
        -- Matches HDG's queue semantics + keeps the byRecipe materials view
        -- from showing the same recipe twice. Same recipeID = same craft;
        -- sessionKey is a tiebreaker for cross-reload disambiguation only.
        local merged = false
        for _, row in ipairs(q) do
            if row.recipeID == payload.recipeID then
                row.requested = (row.requested or 0) + qty  -- exception(false-positive): requested accumulator lazy-init
                row.remaining = (row.remaining or 0) + qty  -- exception(boundary): queue row from SVars may lack remaining
                merged = true
                break
            end
        end
        if not merged then
            q[#q + 1] = {
                recipeID   = payload.recipeID,
                itemID     = payload.itemID,
                requested  = qty,
                remaining  = qty,
                source     = payload.source,
                ts         = (_G.time and _G.time()) or 0,
                sessionKey = payload.sessionKey,   -- reviewer C8: cross-reload disambiguator
            }
        end
    end }

HDG.Actions:Register{ name = "CRAFT_QUEUE_REMOVE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.craft.queue" },
    reduce = function(state, payload)
        local q = state.account.craft.queue
        if payload.position and q[payload.position] then
            table.remove(q, payload.position)
        end
    end }

HDG.Actions:Register{ name = "CRAFT_QUEUE_CLEAR",
    persists = true, combatUnsafe = false,
            invalidates = { "account.craft.queue" },
    reduce = function(state, payload)
        state.account.craft.queue = {}
    end }

HDG.Actions:Register{ name = "CRAFT_QUEUE_DECREMENT",
    persists = true, combatUnsafe = false,
            invalidates = { "account.craft.queue" },
    reduce = function(state, payload)
        -- Match by (position, recipeID) -- reviewer C2/C4: position alone
        -- isn't unique across a queue mutation, recipeID alone isn't unique
        -- because the same item can come from multiple recipes.
        -- List-side steppers dispatch WITHOUT a position -- fall back to the first matching row.
        local q = state.account.craft.queue
        local pos = payload.position
        if not pos then
            for i, r in ipairs(q) do
                if r.recipeID == payload.recipeID then pos = i; break end
            end
        end
        local row = pos and q[pos]
        if row and row.recipeID == payload.recipeID then
            row.remaining = (row.remaining or 0) - (payload.qty or 1)  -- exception(boundary): queue row from SVars may lack remaining
            if row.remaining <= 0 then
                table.remove(q, pos)
            end
        end
    end }

HDG.Actions:Register{ name = "CRAFT_HISTORY_PUSH",
    persists = true, combatUnsafe = false,
            invalidates = { "account.craft.history.entries", "session.styles.changeSeq" },
    reduce = function(state, payload)
        -- Reviewer C2: `completed` flag defends against phantom history
        -- entries when the matching DECREMENT was a no-op (post-removal
        -- events 5..N of a multi-craft batch).
        -- Field names: eventType + timestamp (HouseAggregator contract).
        if payload.completed or payload.eventType == "learned" then
            local hist = state.account.craft.history
            hist.nextID = hist.nextID + 1
            hist.entries[#hist.entries + 1] = {
                id        = hist.nextID,
                eventType = payload.eventType,
                recipeID  = payload.recipeID,
                itemID    = payload.itemID,
                qty       = payload.qty,
                timestamp = payload.timestamp or (_G.time and _G.time()) or 0,
            }
            local cap = HDG.Constants.CRAFT_HISTORY_CAP
            while #hist.entries > cap do
                table.remove(hist.entries, 1)
            end
            -- A learned decor changes the "Recently Learned" collection -> bump the
            -- styles changeSeq so its resolver + every changeSeq-bound selector (Styles
            -- tab + companion grid) refresh. Completed crafts don't affect it.
            if payload.eventType == "learned" then
                state.session.styles.changeSeq =
                    (state.session.styles.changeSeq or 0) + 1
            end
        end

    -- ===== Per-character roster (alts) ============================
    end }

HDG.Actions:Register{ name = "RECIPE_DATA_CAPTURED",
    persists = true, combatUnsafe = false,
    invalidates = function(action)
        local paths = { "account.recipeCapture" }
        if action.payload and action.payload.subRecipes then
            paths[#paths + 1] = "account.subRecipeCapture"
        end
        if action.payload and action.payload.reagentVariants then
            paths[#paths + 1] = "account.reagentVariants"
        end
        return paths
    end,
    reduce = function(state, payload)
        -- Merge a scanned profession's decor recipes into the account-wide override store
        -- (unions across alts + guild scans). Capture-wins per itemID -- reagents are the
        -- live game's truth. Whole-record replace; no field-level merge needed.
        local store = state.account.recipeCapture
        for itemID, rec in pairs(payload.recipes) do
            store[itemID] = rec
        end
        -- Sub-recipe closure records (optional): PowerCrafter's captured craft graph.
        if payload.subRecipes then
            local subStore = state.account.subRecipeCapture
            for itemID, rec in pairs(payload.subRecipes) do
                subStore[itemID] = rec
            end
        end
        -- Reagent quality groups (optional): any tier satisfies a slot.
        if payload.reagentVariants then
            local vStore = state.account.reagentVariants
            for id, sibs in pairs(payload.reagentVariants) do
                vStore[id] = sibs
            end
        end
    end }

HDG.Actions:Register{ name = "RECIPE_HARVEST_PROGRESS",
    persists = false, combatUnsafe = false,
    invalidates = function() return { "session.recipeHarvest" } end,
    reduce = function(state, payload)
        -- Guild-harvest choreography state (ProfessionScanner:StartGuildHarvest).
        -- phase machine: idle -> headers -> profession(xN) -> complete|error|cancelled.
        local h = state.session.recipeHarvest
        h.phase  = payload.phase
        h.active = payload.phase == "headers" or payload.phase == "profession"
        h.done   = payload.done or 0    -- exception(optional): only "profession"/"complete" phases carry done/total/name
        h.total  = payload.total or 0   -- exception(optional): phase-dependent payload
        h.name   = payload.name or ""   -- exception(optional): phase-dependent payload
    end }

-- Upsert the roster record for a character-scoped snapshot action and return it.
-- Every such action carries the same identity fields, so the create-then-refresh
-- block lives here once instead of being copied per action. Identity is refreshed
-- on every call because a rename or a faction-change class swap has to land
-- somewhere, and the scan that notices it is whichever one runs first.
local function _upsertCharacter(state, payload)
    local chars = state.account.characters
    chars[payload.charKey] = chars[payload.charKey] or {
        name        = payload.name,
        realm       = payload.realm,
        class       = payload.class,
        classFile   = payload.classFile,
        hidden      = false,
        lastSeen    = 0,
        professions = {},
    }
    local c = chars[payload.charKey]
    c.name      = payload.name      or c.name
    c.realm     = payload.realm     or c.realm
    c.class     = payload.class     or c.class
    c.classFile = payload.classFile or c.classFile
    c.lastSeen  = (_G.time and _G.time()) or c.lastSeen or 0  -- exception(boundary): time() absent in headless tests
    return c
end

HDG.Actions:Register{ name = "CHARACTER_PROFESSION_UPDATED",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.characters", action.payload and action.payload.charKey) } end,
    reduce = function(state, payload)
        -- Upsert the character entry, then replace this profession's data
        -- in full (skill ladder + known recipes). Other professions on the
        -- same char survive untouched -- each profession scan only carries
        -- its own data.
        if payload.charKey then
            local c = _upsertCharacter(state, payload)
            -- Char-level knowsFindLumber: scanner captures via C_SpellBook
            -- on every prof scan. Tracks per-char awareness of Find Lumber
            -- (the achievement-gated find-spell), surfaced as a cyan
            -- indicator in the Alts char header.
            if payload.knowsFindLumber ~= nil then
                c.knowsFindLumber = payload.knowsFindLumber and true or false
            end
            if payload.profName then
                c.professions[payload.profName] = {
                    professionID = payload.professionID,   -- stable TradeSkillLineID; locale-invariant join key (name key stays for back-compat)
                    skillLines   = payload.skillLines,
                    knownRecipes = payload.knownRecipes,
                }
            end
        end
    end }

-- Essence of Lumber per-character snapshot. Upserts the char record (creating
-- identity if this alt was never scanned) and replaces the essenceStock split.
-- Only ever the currently-logged-in char is live; alts stay at their last-login
-- snapshot (WoW can't read another character's bags). Soulbound -> no warband.
HDG.Actions:Register{ name = "CHARACTER_ESSENCE_UPDATED",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.characters", action.payload and action.payload.charKey) } end,
    reduce = function(state, payload)
        if payload.charKey then
            _upsertCharacter(state, payload).essenceStock =
                { bag = payload.bag or 0, bank = payload.bank or 0 }
        end
    end }

-- Decor-reagent stock, per character, per stash. `counts` REPLACES the slot
-- wholesale so an item spent to zero disappears instead of lingering at its old
-- figure. Only the logged-in character is ever live; alts sit at their last-login
-- snapshot, because WoW cannot read another character's bags.
--
-- No warband slot, deliberately: that stash is shared across the account, so a
-- per-character copy would report one pile once per character.
local function _reduceReagentStock(state, payload, slot, stamp)
    if not payload.charKey then return end
    local c = _upsertCharacter(state, payload)
    c.reagentStock = c.reagentStock or {}   -- exception(nullable): absent on every record predating this feature
    c.reagentStock[slot]  = payload.counts
    c.reagentStock[stamp] = payload.at
end

HDG.Actions:Register{ name = "CHARACTER_REAGENT_BAGS_UPDATED",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.characters", action.payload and action.payload.charKey) } end,
    reduce = function(state, payload)
        _reduceReagentStock(state, payload, "bag", "bagAt")
    end }

-- Dispatched ONLY after a BANKFRAME_OPENED this session -- see
-- Modules/HDGR_ReagentStockObserver.lua. Blizzard's bank counts come from a cache
-- that is empty until the bank frame opens, so an ungated sweep would overwrite a
-- good bank map with zeros every time an alt logged in without visiting a bank.
HDG.Actions:Register{ name = "CHARACTER_REAGENT_BANK_UPDATED",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.characters", action.payload and action.payload.charKey) } end,
    reduce = function(state, payload)
        _reduceReagentStock(state, payload, "bank", "bankAt")
    end }

HDG.Actions:Register{ name = "CHARACTER_DELETED",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.characters", action.payload and action.payload.charKey) } end,
    reduce = function(state, payload)
        if payload.charKey then
            state.account.characters[payload.charKey] = nil
        end
    end }

HDG.Actions:Register{ name = "CHARACTER_HIDDEN",
    persists = true, combatUnsafe = false,
            invalidates = function(action)
                local key = action.payload and action.payload.charKey
                if key then
                    return { P.Join("account.characters", tostring(key), "hidden") }
                end
                return { "account.characters" }
            end,
    reduce = function(state, payload)
        local c = state.account.characters[payload.charKey]
        if c then c.hidden = payload.hidden and true or false end
    end }

HDG.Actions:Register{ name = "CHARACTER_HIDDEN_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = function(action)
                local key = action.payload and action.payload.charKey
                if key then
                    return { P.Join("account.characters", tostring(key), "hidden") }
                end
                return { "account.characters" }
            end,
    reduce = function(state, payload)
        local c = state.account.characters[payload.charKey]
        if c then _toggleBool(c, "hidden") end
    end }

HDG.Actions:Register{ name = "COMPANION_TOGGLE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.companion.windowShown" },
    reduce = function(state, payload)
        state.session.ui.companion.windowShown =
            not state.session.ui.companion.windowShown
    end }

HDG.Actions:Register{ name = "COMPANION_SET_MODE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.companion.mode", "session.ui.companion.selectedItemID" },
    reduce = function(state, payload)
        local m = payload.mode
        if m then
            state.session.ui.companion.mode = m
            -- Clear selection when switching modes (different collection sets).
            state.session.ui.companion.selectedItemID = nil
        end
    end }

HDG.Actions:Register{ name = "COMPANION_SELECT_ITEM",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.companion.selectedItemID" },
    reduce = function(state, payload)
        state.session.ui.companion.selectedItemID = payload.itemID
    end }

HDG.Actions:Register{ name = "COMPANION_TOGGLE_COST",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.companion.showCost" },
    reduce = function(state, payload)
        state.session.ui.companion.showCost =
            not state.session.ui.companion.showCost
    end }

HDG.Actions:Register{ name = "COMPANION_CYCLE_IO",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.companion.ioFilter" },
    reduce = function(state, payload)
        -- 3-state cycle: all -> indoor -> outdoor -> all.
        local cur = state.session.ui.companion.ioFilter
        state.session.ui.companion.ioFilter =
            (cur == "all" and "indoor") or (cur == "indoor" and "outdoor") or "all"
    end }

HDG.Actions:Register{ name = "COMPANION_SET_POSITION",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.companion.window" },
    reduce = function(state, payload)
        state.account.ui.companion.window.x = payload.x
        state.account.ui.companion.window.y = payload.y
    end }

HDG.Actions:Register{ name = "COMPANION_SET_LAUNCHER_POSITION",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.companion.launcher" },
    reduce = function(state, payload)
        state.account.ui.companion.launcher.x = payload.x
        state.account.ui.companion.launcher.y = payload.y
    end }

HDG.Actions:Register{ name = "COMPANION_TOGGLE_GROUP",
    persists = true,  combatUnsafe = false,  -- writes account.ui -> must QueueSave
    retainsScroll = true,  -- folding a group halfway down must not yank the sidebar to the top
    invalidates = function(action) return { HDG.Paths.Join("account.ui.companion.collapsedGroups", action.payload.key) } end,
    reduce = function(state, payload)
        -- Sparse set, present = folded; the Companion's own set, deliberately not Browse's.
        _toggleSetMember(state.account.ui.companion.collapsedGroups, payload.key)
    end }

-- ===== HouseTab dashboard =====

HDG.Actions:Register{ name = "HOUSE_SNAPSHOT_UPDATED",
    persists = false, combatUnsafe = false,
    invalidates = { "session.house.snapshot", "session.house.snapshotChangeSeq" },
    reduce = function(state, payload)
        state.session.house.snapshot     = payload.snapshot
        state.session.house.snapshotChangeSeq = state.session.house.snapshotChangeSeq + 1
    end }

-- Persisted last-known decor storage. Dispatched alongside each snapshot (so it
-- is overwritten on every load/flush that carries capacity), and read as the
-- buy-picker fallback when no live snapshot exists this session.
HDG.Actions:Register{ name = "HOUSE_CAPACITY_CACHED",
    persists = true, combatUnsafe = false,
    invalidates = { "account.houseCapacityCache" },
    reduce = function(state, payload)
        state.account.houseCapacityCache = { owned = payload.owned, max = payload.max }
    end }

HDG.Actions:Register{ name = "HOUSE_LIST_UPDATED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.house.ownedHouses" },
    reduce = function(state, payload)
        -- Identity-only update: ensure an entry exists per houseGUID with
        -- identity fields populated; preserve any previously-captured
        -- level/favor/thresholds across re-fires of the list event
        -- (Blizzard re-fires 3-5 times on login). Faction is derived by
        -- the observer (HouseInfo struct doesn't carry it directly).
        local owned = state.session.house.ownedHouses
        for _, h in ipairs(payload.houses or {}) do
            local guid = h.houseGUID
            if guid then
                owned[guid] = owned[guid] or {}
                owned[guid].name             = h.neighborhoodName or owned[guid].name
                owned[guid].faction          = h.faction          or owned[guid].faction
                owned[guid].neighborhoodGUID = h.neighborhoodGUID or owned[guid].neighborhoodGUID
                -- exception(boundary): HouseInfo.houseName is 0 (number, truthy) for
                -- unnamed houses -- a bare `or` would overwrite a previously-captured
                -- real name with 0 on re-fires (_SIGNATURES.md HouseInfo gotcha).
                local hn = (type(h.houseName) == "string" and h.houseName ~= "") and h.houseName or nil
                owned[guid].houseName        = hn                 or owned[guid].houseName
                owned[guid].plotID           = h.plotID           or owned[guid].plotID
            end
        end
    end }

HDG.Actions:Register{ name = "ACTIVE_NEIGHBORHOOD_UPDATED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.house.activeNeighborhoodGUID" },
    reduce = function(state, payload)
        -- nil-able: GetActiveNeighborhood returns nil when not in a
        -- neighborhood context. Selector falls back to first owned house.
        state.session.house.activeNeighborhoodGUID = payload.neighborhoodGUID
    end }

HDG.Actions:Register{ name = "DAILY_BESTOWED_UPDATED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.daily.bestowed" },
    reduce = function(state, payload)
        state.session.daily.bestowed = {
            name    = payload.name,
            quote   = payload.quote,
            dateKey = payload.dateKey,
        }
    end }

HDG.Actions:Register{ name = "DAILY_ORC_QUOTE_SET",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.daily.orcQuote" },
    reduce = function(state, payload)
        state.session.daily.orcQuote = payload.quote
    end }

HDG.Actions:Register{ name = "STYLES_EDIT_STYLE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.view",
                                               "session.ui.styles.curator.sourceMode",
                                               "session.ui.styles.curator.selectedItems",
                                               "session.ui.styles.curator.selectedCount",
                                               "session.ui.styles.curator.selectedTargetID" },
    reduce = function(state, payload)
        -- Deep-link into the Style Curator with this style as the source
        -- (HDG ShowEditor + SetSource parity). collectionID is already the
        -- "style:<uuid>" key the curator's sourceMode consumes; selection
        -- clears (selected itemIDs are meaningless across sources).
        state.session.ui.styles.view = "curator"
        state.session.ui.styles.curator.sourceMode = payload.collectionID
        state.session.ui.styles.curator.selectedItems = {}
        state.session.ui.styles.curator.selectedCount = 0
        -- Clear any stale move-target from a prior curator session, else the
        -- Move button would target the wrong style after a landing deep-link.
        state.session.ui.styles.curator.selectedTargetID = nil
    end }

HDG.Actions:Register{ name = "HOUSE_LEVEL_UPDATED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.house.ownedHouses" },
    reduce = function(state, payload)
        -- Per-house favor update. Event fires for ALL owned houses on
        -- each request; we target by houseGUID. Ensure an entry exists
        -- (level event may arrive before list event in some replay paths).
        local owned = state.session.house.ownedHouses
        local guid  = payload.houseGUID
        if guid then
            owned[guid] = owned[guid] or {}
            owned[guid].level      = payload.level
            owned[guid].favor      = payload.favor
            owned[guid].maxLevel   = payload.maxLevel
            owned[guid].thresholds = payload.thresholds
        end
    end }

HDG.Actions:Register{ name = "HOUSE_REWARDS_RECEIVED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.house.rewardsByLevel" },
    reduce = function(state, payload)
        -- Cache the per-level rewards array. RECEIVED_HOUSE_LEVEL_REWARDS
        -- fires once per GetHouseLevelRewardsForLevel(level) call; cache
        -- avoids re-requesting the same level repeatedly.
        local level   = payload.level
        local rewards = payload.rewards
        if type(level) == "number" and type(rewards) == "table" then
            state.session.house.rewardsByLevel[level] = { rewards = rewards }
        end
    end }

HDG.Actions:Register{ name = "HOUSETAB_TOGGLE_WIDGET",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.ui.houseTab.enabled", action.payload and action.payload.widgetID) } end,
    reduce = function(state, payload)
        local id = payload.widgetID
        local ht = state.account.ui.houseTab
        _toggleSetMember(ht.enabled, id)
    end }

HDG.Actions:Register{ name = "HOUSETAB_SET_ORDER",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.ui.houseTab.order", action.payload and action.payload.widgetID) } end,
    reduce = function(state, payload)
        state.account.ui.houseTab.order[payload.widgetID] = payload.order
    end }

HDG.Actions:Register{ name = "HOUSETAB_SET_ORDERS",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.houseTab.order" },
    reduce = function(state, payload)
        state.account.ui.houseTab.order = payload.orders
    end }

HDG.Actions:Register{ name = "HOUSETAB_REORDER_WIDGET",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.houseTab.order" },
    reduce = function(state, payload)
        -- Remove srcID from the supplied ordered list, reinsert at insertIdx, renumber to
        -- contiguous order ints. This transition used to live in the controller's
        -- _computePickerOrders; it belongs here. The controller passes the current ordered ids
        -- (a legit one-shot selector read on drag-stop, not a render path).
        local ids, srcID, insertIdx = payload.orderedIDs, payload.srcID, payload.insertIdx
        if ids and srcID and insertIdx then
            local out = {}
            for _, id in ipairs(ids) do if id ~= srcID then out[#out + 1] = id end end
            if insertIdx < 1 then insertIdx = 1 end
            if insertIdx > #out + 1 then insertIdx = #out + 1 end
            table.insert(out, insertIdx, srcID)
            local order = {}
            for i, id in ipairs(out) do order[id] = i end
            state.account.ui.houseTab.order = order
        end
    end }

HDG.Actions:Register{ name = "HOUSETAB_SET_WIDTH",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.ui.houseTab.width", action.payload and action.payload.widgetID) } end,
    reduce = function(state, payload)
        state.account.ui.houseTab.width[payload.widgetID] = payload.width
    end }

HDG.Actions:Register{ name = "HOUSETAB_RESIZE_WIDGET",
    persists = true, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("account.ui.houseTab.layoutOverrides", action.payload and action.payload.widgetID) } end,
    reduce = function(state, payload)
        local ht = state.account.ui.houseTab
        ht.layoutOverrides[payload.widgetID] = ht.layoutOverrides[payload.widgetID] or {}
        ht.layoutOverrides[payload.widgetID].height = payload.height
    end }

HDG.Actions:Register{ name = "HOUSETAB_RESET_LAYOUT",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.houseTab.enabled", "account.ui.houseTab.order",
                            "account.ui.houseTab.width", "account.ui.houseTab.layoutOverrides" },
    reduce = function(state, payload)
        local ht = state.account.ui.houseTab
        ht.enabled         = {}
        ht.order           = {}
        ht.width           = {}
        ht.layoutOverrides = {}
    end }

HDG.Actions:Register{ name = "HOUSETAB_TOGGLE_PICKER",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.houseTab.pickerOpen" },
    reduce = function(state, payload)
        state.session.ui.houseTab.pickerOpen =
            not state.session.ui.houseTab.pickerOpen
    end }

HDG.Actions:Register{ name = "HOUSETAB_TOGGLE_DESIGN_MODE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.houseTab.designMode" },
    reduce = function(state, payload)
        state.session.ui.houseTab.designMode =
            not state.session.ui.houseTab.designMode
    end }

HDG.Actions:Register{ name = "SESSION_IDENTITY_SET",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.identity" },
    reduce = function(state, payload)
        -- Strict payload reads: SessionIdentity:onEnable already coerces
        -- nil class/classFile to "" before dispatch (single producer; no
        -- defensive `or` defaults at this internal boundary).
        local id = state.session.identity
        id.name         = payload.name
        id.realm        = payload.realm
        id.class        = payload.class
        id.classFile    = payload.classFile
        id.factionGroup = payload.factionGroup or ""  -- exception(boundary): SESSION_IDENTITY_SET payload may omit factionGroup
        id.charKey      = id.name .. "-" .. id.realm
    end }

HDG.Actions:Register{ name = "TRAINERS_TOGGLE_PROFESSION",
    persists = false, combatUnsafe = false, retainsScroll = true,
    invalidates = function(action) return { HDG.Paths.Join("session.ui.trainers.expandedProfessions", action.payload and action.payload.profession) } end,
    reduce = function(state, payload)
        local p = payload.profession
        if p then
            local expanded = state.session.ui.trainers.expandedProfessions
            _toggleSetMember(expanded, p)
        end
    end }

HDG.Actions:Register{ name = "TRAINERS_TOGGLE_MIDNIGHT_SECTION",
    persists = false, combatUnsafe = false, retainsScroll = true,
    invalidates = { "session.ui.trainers.midnightExpanded" },
    reduce = function(state, payload)
        state.session.ui.trainers.midnightExpanded =
            not state.session.ui.trainers.midnightExpanded
    end }

HDG.Actions:Register{ name = "TRAINERS_SELECT_TRAINER",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.trainers.selectedNpcID" },
    reduce = function(state, payload)
        state.session.ui.trainers.selectedNpcID = payload.npcID
    end }

HDG.Actions:Register{ name = "ALTS_SET_CHARS_POPULATION",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.alts.charsPopulation" },
    reduce = function(state, payload)
        -- Validate -- silently coerce unknown values to "active".
        local p = payload.population
        if p ~= "active" and p ~= "hidden" then p = "active" end
        state.session.ui.alts.charsPopulation = p
    end }

HDG.Actions:Register{ name = "MOGUL_SET_MODE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.mode" },
    reduce = function(state, payload)
        state.session.ui.mogul.mode = payload.mode
    end }

HDG.Actions:Register{ name = "MOGUL_SET_VIEW",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.viewMode" },
    reduce = function(state, payload)
        state.session.ui.mogul.viewMode = payload.viewMode
    end }

HDG.Actions:Register{ name = "MOGUL_SET_OPTIMIZE_BY",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.optimizeBy" },
    reduce = function(state, payload)
        state.session.ui.mogul.optimizeBy = payload.optimizeBy
    end }

HDG.Actions:Register{ name = "MOGUL_SET_SUBVIEW",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.subView" },
    reduce = function(state, payload)
        state.session.ui.mogul.subView = payload.subView
    end }

HDG.Actions:Register{ name = "MOGUL_SET_SUPPLY_MODE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.supplyImpact.mode",
                                          "session.ui.mogul.supplyImpact.smoothPct",
                                          "session.ui.mogul.supplyImpact.capN" },
    reduce = function(state, payload)
        local si = state.session.ui.mogul.supplyImpact
        si.mode = payload.mode
    end }

HDG.Actions:Register{ name = "MOGUL_SET_SUPPLY_SMOOTH",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.supplyImpact.smoothPct" },
    reduce = function(state, payload)
        local si = state.session.ui.mogul.supplyImpact
        si.smoothPct = payload.pct
    end }

HDG.Actions:Register{ name = "MOGUL_SET_SUPPLY_CAP",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.supplyImpact.capN" },
    reduce = function(state, payload)
        local si = state.session.ui.mogul.supplyImpact
        si.capN = payload.n
    end }


HDG.Actions:Register{ name = "MOGUL_TOGGLE_FRUGAL",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.frugal" },
    reduce = function(state, payload)
        _toggleBool(state.session.ui.mogul, "frugal")
    end }

HDG.Actions:Register{ name = "GOBLIN_SET_PROFESSION",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.mogul.goblin.profession" },
    reduce = function(state, payload)
        state.session.ui.mogul.goblin.profession = payload.profession
    end }

HDG.Actions:Register{ name = "GOBLIN_SET_EXPANSION",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.mogul.goblin.expansion" },
    reduce = function(state, payload)
        -- Toggle-to-clear: re-clicking the active expansion clears the filter ("").
        local cur = state.session.ui.mogul.goblin.expansion
        state.session.ui.mogul.goblin.expansion = (cur == payload.expansion) and "" or payload.expansion
    end }

HDG.Actions:Register{ name = "GOBLIN_SET_SEARCH",
    persists = false, combatUnsafe = false, noisy = true,
    invalidates = { "session.ui.mogul.goblin.search" },
    reduce = function(state, payload)
        state.session.ui.mogul.goblin.search    = payload.query
    end }

HDG.Actions:Register{ name = "GOBLIN_SET_KNOWLEDGE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.goblin.knowledge" },
    reduce = function(state, payload)
        state.session.ui.mogul.goblin.knowledge = payload.mode
    end }

HDG.Actions:Register{ name = "GOBLIN_SET_QUEUE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.goblin.queue" },
    reduce = function(state, payload)
        state.session.ui.mogul.goblin.queue     = payload.mode
    end }

HDG.Actions:Register{ name = "GOBLIN_TOGGLE_AUCTIONS",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.mogul.goblin.auctionsOnly" },
    reduce = function(state, payload)
        local g = state.session.ui.mogul.goblin
        _toggleBool(g, "auctionsOnly")
    end }

HDG.Actions:Register{ name = "GOBLIN_TOGGLE_HAVE_LUMBER",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.mogul.goblin.haveLumber" },
    reduce = function(state, payload)
        local g = state.session.ui.mogul.goblin
        _toggleBool(g, "haveLumber")
    end }

HDG.Actions:Register{ name = "GOBLIN_TOGGLE_ROW_EXPAND",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.goblin.expandedItemID" },
    reduce = function(state, payload)
        -- Click row: toggle expansion. Same itemID as currently expanded
        -- collapses; different/new itemID switches the detail panel to it.
        local g = state.session.ui.mogul.goblin
        if g.expandedItemID == payload.itemID then
            g.expandedItemID = nil
        else
            g.expandedItemID = payload.itemID
        end
    end }

HDG.Actions:Register{ name = "GOBLIN_SET_SORT",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.mogul.goblin.sortCol",
                            "session.ui.mogul.goblin.sortDir" },
    reduce = function(state, payload)
        -- Click on header: same column flips direction, new column resets
        -- to the column's natural-desc default (most useful first sort).
        -- Name column defaults to ascending (alphabetical reads better).
        local g = state.session.ui.mogul.goblin
        local col = payload.col
        if g.sortCol == col then
            g.sortDir = (g.sortDir == "desc") and "asc" or "desc"
        else
            g.sortCol = col
            g.sortDir = (col == "name" or col == "lumber") and "asc" or "desc"
        end

    -- ===== Recipes tab session UI ================================
    end }

HDG.Actions:Register{ name = "RECIPES_SET_SEARCH",
    persists = false, combatUnsafe = false, noisy = true,
    invalidates = { "session.ui.recipes.searchQuery" },
    reduce = function(state, payload)
        state.session.ui.recipes.searchQuery = payload.query
    end }

HDG.Actions:Register{ name = "RECIPES_SET_SECTION_EXPAND",
    persists = false, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("session.ui.recipes.expandedSections", action.payload and action.payload.key) } end,
    reduce = function(state, payload)
        local sections = state.session.ui.recipes.expandedSections
        if payload.expanded then
            sections[payload.key] = true
        else
            sections[payload.key] = nil
        end
    end }

HDG.Actions:Register{ name = "RECIPES_SET_MATERIALS_DEPTH",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.recipes.materialsDepth" },
    reduce = function(state, payload)
        state.session.ui.recipes.materialsDepth = payload.value
    end }

HDG.Actions:Register{ name = "RECIPES_TOGGLE_MATERIALS_GROUPING",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.recipes.materialsGrouping" },
    reduce = function(state, payload)
        local r = state.session.ui.recipes
        r.materialsGrouping = (r.materialsGrouping == "byRecipe") and "totals" or "byRecipe"
    end }

HDG.Actions:Register{ name = "RECIPES_TOGGLE_FILTER",
    persists = false, combatUnsafe = false,
            invalidates = function(action) return { HDG.Paths.Join("session.ui.recipes.filters", action.payload and action.payload.filter) } end,
    reduce = function(state, payload)
        local filters = state.session.ui.recipes.filters
        local key = payload.filter
        filters[key] = not filters[key]
    end }

HDG.Actions:Register{ name = "RECIPES_SELECT_RECIPE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.recipes.selectedRecipeID", "session.ui.recipes.queueSelectedRecipeID" },
    reduce = function(state, payload)
        state.session.ui.recipes.selectedRecipeID = payload.recipeID
        -- Picking a recipe from the list resets queue scoping: the queue row
        -- deselects + Materials returns to the full-queue aggregate. (Last
        -- selection wins; recipe-list and queue selections are mutually exclusive.)
        state.session.ui.recipes.queueSelectedRecipeID = nil
    end }

HDG.Actions:Register{ name = "RECIPES_TOGGLE_QUEUE_SELECTION",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.recipes.queueSelectedRecipeID" },
    reduce = function(state, payload)
        -- Toggle: click-on-selected clears (so mats list returns to the
        -- full-queue aggregate); click-on-other sets to that recipeID.
        local cur = state.session.ui.recipes.queueSelectedRecipeID
        if cur == payload.recipeID then
            state.session.ui.recipes.queueSelectedRecipeID = nil
        else
            state.session.ui.recipes.queueSelectedRecipeID = payload.recipeID
        end
    end }

HDG.Actions:Register{ name = "RECIPES_TOGGLE_PROFESSION",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.ui.recipes.professionFilterByChar" },
    reduce = function(state, payload)
        -- Per-character multi-select set toggle (persisted in account.ui, keyed by
        -- charKey). payload.profession == "all" stores an empty set (-> show every
        -- profession); == "mine" presets to THIS character's scanned professions;
        -- otherwise flip that profession's membership.
        local charKey = state.session.identity.charKey
        local byChar  = state.account.ui.recipes.professionFilterByChar
        local char    = state.account.characters[charKey]  -- exception(nullable): char record may not exist yet
        local set     = byChar[charKey]
        if not set then
            -- First explicit choice for this char. Materialize the pristine default
            -- (this char's professions) so a single-profession toggle builds on what
            -- was actually shown -- UNLESS the click is "all" (which wants empty).
            set = {}
            if payload.profession ~= "all" and char and type(char.professions) == "table" then
                for profName in pairs(char.professions) do set[profName] = true end
            end
            byChar[charKey] = set
        end
        if payload.profession == "all" then
            wipe(set)
        elseif payload.profession == "mine" then
            wipe(set)
            if char and type(char.professions) == "table" then
                for profName in pairs(char.professions) do set[profName] = true end
            end
        else
            _toggleSetMember(set, payload.profession)
        end
    end }

HDG.Actions:Register{ name = "RECIPES_TOGGLE_EXPANSION",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.ui.recipes.expansionFilter" },
    reduce = function(state, payload)
        -- Multi-select set toggle (persisted in account.ui). payload.expansion
        -- == "all" clears the set (master "All Expansions" toggle -> show every
        -- expansion); otherwise flip that expansion's membership. Empty = all.
        _acqToggleFilter(state.account.ui.recipes.expansionFilter, payload.expansion)
    end }

HDG.Actions:Register{ name = "RECIPES_SET_LIST_FILTER",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.recipes.listFilter" },
    reduce = function(state, payload)
        state.session.ui.recipes.listFilter = payload.filter
    end }

HDG.Actions:Register{ name = "RECIPES_SELECT_MATERIAL",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.warehouse.selectedMaterialID" },
    reduce = function(state, payload)
        state.session.ui.warehouse.selectedMaterialID = payload.itemID
    end }

HDG.Actions:Register{ name = "RECIPES_SET_WH_MAT_SEARCH",
    persists = false, combatUnsafe = false, noisy = true,
    invalidates = { "session.ui.warehouse.matSearch" },
    reduce = function(state, payload)
        state.session.ui.warehouse.matSearch = payload.query

    -- ===== Cross-feature observer dispatches =====================
    end }

HDG.Actions:Register{ name = "ITEM_INFO_RESOLVED",
    persists = false, combatUnsafe = false,
    invalidates = { "session.itemNames.names",
                                     "account.craft.queue" },
    reduce = function(state, payload)
        -- Write resolved names to cache; one batched dispatch (not per entry).
        -- Path invalidation on .names IS the re-pull signal (species B --
        -- consumers read the data path; the redundant tick dissolved 2026-06-11).
        local names = state.session.itemNames.names
        if payload.entries then
            for _, e in ipairs(payload.entries) do
                if e.itemID and e.name then names[e.itemID] = e.name end
            end
        end
    end }

HDG.Actions:Register{ name = "QUEST_COMPLETION_RECORDED",
    persists = true, combatUnsafe = false,
            invalidates = { "account.questCompletions" },
    reduce = function(state, payload)
        -- Merge the scanned completions into the account-wide set. First char to
        -- record a quest wins (stable attribution) -- don't overwrite. payload
        -- entries are { [questID] = { name, class } }.
        local store = state.account.questCompletions
        for questID, rec in pairs(payload.completions or {}) do
            if not store[questID] then store[questID] = rec end
        end
    end }

HDG.Actions:Register{ name = "PRICES_DIRECT_SCAN_STARTED",
    persists = true, combatUnsafe = false,
            invalidates = { "session.prices.scanning", "session.prices.scanTotal",
                            "account.prices.directCache", "account.prices.directQtyCache",
                            "account.prices.directCacheTime" },
    reduce = function(state, payload)
        -- Replace-on-scan: wipe the previous cache so each scan is a fresh snapshot.
        -- B-side: the account.prices path invalidation IS the consumer signal
        -- (price selectors read account.prices; tick bump dissolved 2026-06-11).
        state.account.prices.directCache = {}
        state.account.prices.directQtyCache = {}
        state.account.prices.directCacheTime = nil
        local s = state.session.prices
        s.scanning  = true
        s.scanFound = 0
        s.scanTotal = payload.total
    end }

HDG.Actions:Register{ name = "PRICES_DIRECT_SCAN_PROGRESS",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.prices.scanFound" },
    reduce = function(state, payload)
        local s = state.session.prices
        s.scanFound = payload.found or s.scanFound
        s.scanTotal = payload.total or s.scanTotal
    end }

HDG.Actions:Register{ name = "PRICES_DIRECT_SCAN_BATCH",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.prices.directCache", "account.prices.directQtyCache" },
    reduce = function(state, payload)
        local cache = state.account.prices.directCache
        for itemID, copper in pairs(payload.prices) do
            cache[itemID] = copper
        end
        local qty = state.account.prices.directQtyCache
        for itemID, n in pairs(payload.quantities or {}) do
            qty[itemID] = n
        end
    end }

HDG.Actions:Register{ name = "PRICES_DIRECT_SCAN_COMPLETED",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.prices.directCache", "account.prices.directQtyCache",
                            "account.prices.directCacheTime",
                            "session.prices.scanning" },
    reduce = function(state, payload)
        local cache = state.account.prices.directCache
        local qty   = state.account.prices.directQtyCache
        -- Zero out items we wanted but never saw -- prevents re-scan
        -- attempts every session for items that simply aren't on the AH.
        for itemID in pairs(payload.neededItems) do
            if cache[itemID] == nil then cache[itemID] = 0 end
            if qty[itemID]   == nil then qty[itemID]   = 0 end
        end
        state.account.prices.directCacheTime = payload.now
        local s = state.session.prices
        s.scanning = false
        s.scanFound = 0
        s.scanTotal = 0
    end }

HDG.Actions:Register{ name = "PRICES_DIRECT_CACHE_CLEARED",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.prices.directCache", "account.prices.directQtyCache",
                            "account.prices.directCacheTime" },
    reduce = function(state, payload)
        state.account.prices.directCache     = {}
        state.account.prices.directQtyCache  = {}
        state.account.prices.directCacheTime = nil
    end }

HDG.Actions:Register{ name = "PRICES_OWNED_AUCTIONS_UPDATED",
    persists = true,  combatUnsafe = false,
            invalidates = { "account.prices.ownedAuctions" },
    reduce = function(state, payload)
        state.account.prices.ownedAuctions = payload.auctions

    -- ===== Styles ==================================================
    end }

HDG.Actions:Register{ name = "STYLES_SET_VIEW",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.view",
                                  "session.ui.styles.smartset.draft.displayName" },
    reduce = function(state, payload)
        state.session.ui.styles.view = payload.view
        -- The "Smart Sets" nav leaf opens this view without running BEGIN, so
        -- seed a fresh draft's default name here. Only when truly fresh (no
        -- draftKey, blank name, no rules) so navigating away + back preserves an
        -- in-progress draft; the button path (BEGIN) owns the explicit reset.
        if payload.view == "smartset" then
            local s = state.session.ui.styles.smartset
            local blankName = (s.draft.displayName == nil or s.draft.displayName == "")
            if not s.draftKey and blankName and not next(s.rules) then
                s.draft.displayName = _seededSmartsetName(state.account)
                s.draft.descAuto    = true
            end
        end
    end }

HDG.Actions:Register{ name = "STYLES_LANDING_SET_FILTER",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.landing.filter" },
    reduce = function(state, payload)
        state.session.ui.styles.landing.filter = payload.filter
    end }


HDG.Actions:Register{ name = "STYLES_LANDING_TOGGLE_SECTION",
    persists = true,  combatUnsafe = false,  -- writes account.ui -> must QueueSave
    retainsScroll = true,  -- collapsing a section halfway down must not yank the list to the top
    invalidates = function(action) return { HDG.Paths.Join("account.ui.styles.landing.expandedSections", action.payload.type) } end,
    reduce = function(state, payload)
        -- payload.type comes off a header row the selector emitted a frame earlier.
        _toggleSetMember(state.account.ui.styles.landing.expandedSections, payload.type)
    end }

HDG.Actions:Register{ name = "STYLES_LANDING_TOGGLE_CATEGORY",
    persists = true,  combatUnsafe = false,  -- writes account.ui -> must QueueSave
    retainsScroll = true,  -- a fold is clicked mid-list; yanking to the top loses the user's place
    invalidates = function(action) return { HDG.Paths.Join("account.ui.styles.landing.expandedCategories", action.payload.key) } end,
    reduce = function(state, payload)
        -- key is a categoryID or "loose"; sparse set, present = open.
        _toggleSetMember(state.account.ui.styles.landing.expandedCategories, payload.key)
    end }

HDG.Actions:Register{ name = "STYLES_LANDING_SET_SEARCH",
    persists = false, combatUnsafe = false, noisy = true,   -- per keystroke; stays out of the dispatch log like STYLES_DETAIL_SET_SEARCH
    invalidates = { "session.ui.styles.landing.search" },
    reduce = function(state, payload)
        state.session.ui.styles.landing.search = payload.text
    end }

HDG.Actions:Register{ name = "STYLES_SELECT_COLLECTION",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.selectedID" },
    reduce = function(state, payload)
        state.session.ui.styles.selectedID = payload.collectionID
    end }

HDG.Actions:Register{ name = "STYLES_DETAIL_SELECT_ITEM",
    persists = false, combatUnsafe = false, retainsScroll = true,
    invalidates = { "session.ui.styles.detail.selectedItemID" },
    reduce = function(state, payload)
        state.session.ui.styles.detail.selectedItemID = payload.itemID
    end }






HDG.Actions:Register{ name = "STYLES_DETAIL_SET_SEARCH",
    persists = false, combatUnsafe = false, noisy = true,
    invalidates = { "session.ui.styles.detail.search" },
    reduce = function(state, payload)
        state.session.ui.styles.detail.search = payload.text

    -- ===== 14.3 Curator =====================================================
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_SET_SOURCE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.curator.sourceMode",
                                               "session.ui.styles.curator.selectedItems",
                                               "session.ui.styles.curator.selectedCount" },
    reduce = function(state, payload)
        state.session.ui.styles.curator.sourceMode = payload.mode
        -- Selection clears when the source changes (selected itemIDs are
        -- meaningless in a different source view).
        state.session.ui.styles.curator.selectedItems = {}
        state.session.ui.styles.curator.selectedCount = 0
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_SET_SEARCH",
    persists = false, combatUnsafe = false, noisy = true,
    invalidates = { "session.ui.styles.curator.searchQuery" },
    reduce = function(state, payload)
        state.session.ui.styles.curator.searchQuery = payload.text
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_SET_CATEGORY",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.curator.focusedCategoryID",
                                                "session.ui.styles.curator.focusedSubcategoryID" },
    reduce = function(state, payload)
        -- nil categoryID = the "All" icon (clears the filter). Subcategory always
        -- resets when the major category changes -- its list is derived from the
        -- focused category, so a carried-over value would point at a gone subcat.
        state.session.ui.styles.curator.focusedCategoryID    = payload.categoryID
        state.session.ui.styles.curator.focusedSubcategoryID = nil
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_SET_SUBCATEGORY",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.curator.focusedSubcategoryID" },
    reduce = function(state, payload)
        state.session.ui.styles.curator.focusedSubcategoryID = payload.subcategoryID
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_TOGGLE_SELECT",
    persists = false, combatUnsafe = false, retainsScroll = true,
    invalidates = { "session.ui.styles.curator.selectedItems",
                                                "session.ui.styles.curator.selectedCount" },
    reduce = function(state, payload)
        local id = payload.itemID
        if id then
            local cur = state.session.ui.styles.curator
            if cur.selectedItems[id] then
                cur.selectedItems[id] = nil
                cur.selectedCount = (cur.selectedCount or 1) - 1
            else
                cur.selectedItems[id] = true
                cur.selectedCount = (cur.selectedCount or 0) + 1
            end
        end
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_CLEAR_SELECT",
    persists = false, combatUnsafe = false, retainsScroll = true,
    invalidates = { "session.ui.styles.curator.selectedItems",
                                                "session.ui.styles.curator.selectedCount" },
    reduce = function(state, payload)
        state.session.ui.styles.curator.selectedItems = {}
        state.session.ui.styles.curator.selectedCount = 0
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_HOVER",
    persists = false, combatUnsafe = false,
            noisy = true, retainsScroll = true,
            invalidates = { "session.ui.styles.curator.hoverItemID" },
    reduce = function(state, payload)
        state.session.ui.styles.curator.hoverItemID = payload.itemID
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_SELECT_TARGET",
    persists = false, combatUnsafe = false, retainsScroll = true,
    invalidates = { "session.ui.styles.curator.selectedTargetID" },
    reduce = function(state, payload)
        state.session.ui.styles.curator.selectedTargetID = payload.targetID
    end }

HDG.Actions:Register{ name = "STYLES_CREATE_STYLE",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections",
                                               "session.ui.styles.curator.selectedTargetID" },
    reduce = function(state, payload)
        -- Create a fresh "style:<slug>" collection in account.collections
        -- and auto-select it as the Curator's active target so the user's
        -- next Move lands there without an extra click.
        local name = payload.displayName
        if not (name and name ~= "" and name:gsub("%s", "") ~= "") then return end
        local slug = name:lower():gsub("[^%w]+", "-")
        if slug == "" or slug == "-" then slug = tostring(_G.time and _G.time() or 0) end
        local id = "style:" .. slug
        -- Disambiguate if a style with this slug already exists.
        local cols = state.account.collections or {}
        if cols[id] then
            local suffix = 2
            while cols[id .. "-" .. suffix] do suffix = suffix + 1 end
            id = id .. "-" .. suffix
        end
        state.account.collections = cols
        cols[id] = {
            id          = id,
            type        = "style",
            displayName = name,
            description = "",
            items       = {},
            createdAt   = (_G.time and _G.time()) or 0,
        }
        state.session.ui.styles.curator.selectedTargetID = id
    end }

HDG.Actions:Register{ name = "STYLES_RENAME_STYLE",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections" },
    reduce = function(state, payload)
        -- Rename the displayName of a "style:<slug>" collection. ID stays
        -- the same so undo history + memberships keep their links.
        local id   = payload.collectionID
        local name = payload.displayName
        if not (id and name and name ~= "" and name:gsub("%s", "") ~= "") then return end
        local coll = state.account.collections and state.account.collections[id]
        if coll and coll.type == "style" then
            coll.displayName = name
        end
    end }

HDG.Actions:Register{ name = "STYLES_DUPLICATE_STYLE",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections",
                                               "session.ui.styles.curator.selectedTargetID" },
    reduce = function(state, payload)
        -- Clone a "style:<slug>" collection. New id is "<src>-copy" with a
        -- numeric suffix if "-copy" is already taken. items[] copied by value.
        local srcID = payload.collectionID
        local cols  = state.account.collections or {}
        local src   = cols[srcID]
        if not (src and src.type == "style") then return end
        local baseID = srcID .. "-copy"
        local newID  = baseID
        local suffix = 2
        while cols[newID] do
            newID = baseID .. "-" .. suffix
            suffix = suffix + 1
        end
        local items = {}
        for i, v in ipairs(src.items or {}) do items[i] = v end
        cols[newID] = {
            id          = newID,
            type        = "style",
            displayName = (src.displayName or srcID) .. " (copy)",
            description = src.description or "",
            categoryID  = src.categoryID,   -- a copy stays beside its source (spec 2.2)
            items       = items,
            createdAt   = (_G.time and _G.time()) or 0,
        }
        state.account.collections = cols
        state.session.ui.styles.curator.selectedTargetID = newID
    end }

HDG.Actions:Register{ name = "STYLES_DELETE_STYLE",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections",
                                               "account.vendorShoppingLists",   -- shopping lists live here; deleted via the "vsl:" id prefix
                                               "session.ui.styles.curator.selectedTargetID" },
    reduce = function(state, payload)
        -- Delete any user-authored collection -- style / smartset / snapshot
        -- live in account.collections; SHOPPING LISTS live in the separate
        -- account.vendorShoppingLists slot, keyed WITHOUT the "vsl:" prefix the
        -- landing card carries. Route by prefix so shopping-list deletes hit the
        -- right slot (the old account.collections-only path silently no-op'd them
        -- -- cols["vsl:L1"] is always nil). Pre-authored concept/collection sets
        -- aren't deletable (canDelete=false), so they never reach here. Clears
        -- selectedTargetID if this was the active target so the controls row hides.
        local id  = payload.collectionID
        local cur = state.session.ui.styles.curator
        local vslID = type(id) == "string" and id:match("^vsl:(.+)$")
        if vslID then
            local lists = state.account.vendorShoppingLists
            if not (lists and lists[vslID]) then return end   -- exception(boundary): missing list
            lists[vslID] = nil
        else
            local cols = state.account.collections
            if not (id and cols and cols[id]) then return end   -- exception(boundary): missing id / pre-first-save
            cols[id] = nil
        end
        if cur and cur.selectedTargetID == id then
            cur.selectedTargetID = nil
        end
    end }

-- ===== Style categories (spec HDGR_STYLE_CATEGORIES_SPEC_2026-09-04 s2.2 / s3.1) =====

-- The ONE code path that writes a style's categoryID. Strict on purpose: every
-- collectionID that reaches it came off a landing row or the loose-styles menu a
-- frame earlier, so a nil index here is a bug to surface, not a boundary.
local function _setStyleCategory(state, collectionID, categoryID)
    state.account.collections[collectionID].categoryID = categoryID
end

-- Case-insensitive name match over the registry. Rename can leave two categories
-- with one name; the lowest seq (= oldest) wins so the same dispatch always lands
-- in the same place (spec 2.4).
local function _findStyleCategoryByName(cats, name)
    local needle, found = name:lower(), nil
    for _, cat in pairs(cats) do
        if cat.name:lower() == needle and (not found or cat.seq < found.seq) then found = cat end
    end
    return found and found.id
end

HDG.Actions:Register{ name = "STYLE_CATEGORY_CREATE",
    persists = true,  combatUnsafe = false,  -- writes account.* -> must QueueSave
    invalidates = { "account.styleCategories", "account.styleCategorySeq",
                    "account.ui.styles.landing.expandedCategories", "account.collections" },
    reduce = function(state, payload)
        local cats = state.account.styleCategories
        local id = _findStyleCategoryByName(cats, payload.name)
        if not id then
            state.account.styleCategorySeq = state.account.styleCategorySeq + 1
            local seq = state.account.styleCategorySeq
            id = "cat:" .. seq
            cats[id] = { id = id, seq = seq, name = payload.name,
                         createdAt = (_G.time and _G.time()) or 0 }  -- exception(boundary): time() absent in headless tests
        end
        -- Born (or re-targeted) expanded so what the user just did is visible.
        state.account.ui.styles.landing.expandedCategories[id] = true
        if payload.fileStyleID then _setStyleCategory(state, payload.fileStyleID, id) end
    end }

HDG.Actions:Register{ name = "STYLE_CATEGORY_RENAME",
    persists = true,  combatUnsafe = false,  -- writes account.* -> must QueueSave
    invalidates = { "account.styleCategories" },
    reduce = function(state, payload)
        -- Members point by id, so they need no touch.
        state.account.styleCategories[payload.categoryID].name = payload.name
    end }

HDG.Actions:Register{ name = "STYLE_CATEGORY_DELETE",
    persists = true,  combatUnsafe = false,  -- writes account.* -> must QueueSave
    invalidates = { "account.styleCategories", "account.collections",
                    "account.ui.styles.landing.expandedCategories",
                    "account.ui.companion.collapsedGroups" },
    reduce = function(state, payload)
        local id = payload.categoryID
        -- Styles are never deleted with their category; they drop back to loose.
        for collID, coll in pairs(state.account.collections) do
            if coll.categoryID == id then _setStyleCategory(state, collID, nil) end
        end
        state.account.styleCategories[id] = nil
        state.account.ui.styles.landing.expandedCategories[id] = nil
        -- The Companion sidebar keeps its OWN fold set, so it needs its own line
        -- here; without it a deleted category leaves an orphan key in SavedVariables
        -- that nothing will ever read or clear again.
        state.account.ui.companion.collapsedGroups[id] = nil
    end }

HDG.Actions:Register{ name = "STYLE_SET_CATEGORY",
    persists = true,  combatUnsafe = false,  -- writes account.* -> must QueueSave
    retainsScroll = true,  -- filed from a row menu; don't yank the list to the top
    invalidates = function(action)
        return { HDG.Paths.Join("account.collections", action.payload.collectionID),
                 "account.ui.styles.landing.expandedCategories" }
    end,
    reduce = function(state, payload)
        _setStyleCategory(state, payload.collectionID, payload.categoryID)
        if payload.categoryID then
            state.account.ui.styles.landing.expandedCategories[payload.categoryID] = true
        end
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_BEGIN",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.smartset" },
    reduce = function(state, payload)
        -- Seed draft from existing collection (when editing) or from scratch.
        -- The view-switch to "smartset" is dispatched separately by the
        -- entry-point CTA / Detail "Edit" button.
        local s = state.session.ui.styles.smartset
        local existingID = payload.id
        local existing = existingID and state.account.collections
                         and state.account.collections[existingID]
        if existing then
            s.draftKey = existingID
            s.draft = {
                id          = existing.id or existingID,
                displayName = existing.displayName or "",
                description = existing.description or "",
                type        = existing.type or "smartset",
                descAuto    = false,   -- editing: preserve the saved description
            }
            -- Deep-copy rules so edits don't mutate the persisted record
            -- until SAVE commits them.
            s.rules = {}
            for axis, tags in pairs(existing.rules or {}) do
                s.rules[axis] = {}
                for tag, sev in pairs(tags) do s.rules[axis][tag] = sev end
            end
        else
            -- New draft: seed "<Char> Style <N>" + descAuto (the description
            -- tracks the signature tags until the player types their own).
            s.draftKey       = nil
            s.draft          = { id = nil, displayName = _seededSmartsetName(state.account),
                                 description = "", type = "smartset", descAuto = true }
            s.rules          = {}
        end
        s.activeAxis     = "room"
        s.activeSeverity = "all"
        s.dirty          = false
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_SET_FIELD",
    persists = false, combatUnsafe = false, 
    invalidates = function(action) return { HDG.Paths.Join("session.ui.styles.smartset.draft", action.payload and action.payload.field) } end,
    reduce = function(state, payload)
        local s = state.session.ui.styles.smartset
        if payload.field then
            s.draft[payload.field] = payload.value
            -- User typed in the description -> stop auto-tracking the signature tags.
            if payload.field == "description" then s.draft.descAuto = false end
            s.dirty = true
        end
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_SET_AXIS",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.smartset.activeAxis" },
    reduce = function(state, payload)
        state.session.ui.styles.smartset.activeAxis = payload.axis
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_SET_SEVERITY_TAB",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.smartset.activeSeverity" },
    reduce = function(state, payload)
        state.session.ui.styles.smartset.activeSeverity = payload.sev
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_TOGGLE_TAG",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.smartset.rules",
                                                   "session.ui.styles.smartset.dirty",
                                                   "session.ui.styles.smartset.draft.description" },
    reduce = function(state, payload)
        -- Toggle a tag's severity within an axis. payload.severity nil =
        -- remove the tag (untoggle); else set to that severity (overwrite
        -- if already present at a different severity).
        local s = state.session.ui.styles.smartset
        local axis, tag, sev = payload.axis, payload.tag, payload.severity
        if axis and tag then
            s.rules[axis] = s.rules[axis] or {}
            if sev == nil or s.rules[axis][tag] == sev then
                s.rules[axis][tag] = nil
                -- Drop empty axis tables for tidiness (saves serialization size).
                local hasAny = false
                for _ in pairs(s.rules[axis]) do hasAny = true; break end
                if not hasAny then s.rules[axis] = nil end
            else
                s.rules[axis][tag] = sev
            end
            if s.draft.descAuto then s.draft.description = _buildSmartsetAutoDesc(s.rules) end
            s.dirty = true
        end
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_CLEAR_ALL",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.smartset.rules",
                                                   "session.ui.styles.smartset.dirty",
                                                   "session.ui.styles.smartset.draft.description" },
    reduce = function(state, payload)
        local s = state.session.ui.styles.smartset
        s.rules = {}
        s.draft.description = ""   -- auto-desc now tracks the (empty) signature set
        s.draft.descAuto    = true
        s.dirty = true
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_SAVE",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections",
                                                   "session.ui.styles.smartset" },
    reduce = function(state, payload)
        -- Commit the draft to account.collections. New drafts get a fresh
        -- "smartset:<sluggedName>" id; edits write through the existing
        -- draftKey. Caller is responsible for view-switching back to
        -- landing post-save (typically via the footer's onClick chain).
        local s = state.session.ui.styles.smartset
        if s.dirty or not s.draftKey then
            local id = s.draftKey
            if not id then
                -- Monotonic, collision-free id (feedback_no_random_ids_use_counters);
                -- shares the counter with the "<Char> Style <N>" name seed.
                state.account.collectionSeq = (state.account.collectionSeq or 0) + 1  -- exception(boundary): pre-counter saved accounts lack collectionSeq
                id = "smartset:" .. state.account.collectionSeq
            end
            state.account.collections = state.account.collections or {}
            state.account.collections[id] = {
                id          = id,
                type        = "smartset",
                displayName = s.draft.displayName or "Untitled",
                description = s.draft.description or "",
                rules       = {},
            }
            for axis, tags in pairs(s.rules or {}) do
                state.account.collections[id].rules[axis] = {}
                for tag, sev in pairs(tags) do
                    state.account.collections[id].rules[axis][tag] = sev
                end
            end
            s.draftKey = id
            s.dirty    = false
        end
    end }

HDG.Actions:Register{ name = "STYLES_SMARTSET_CANCEL",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.smartset" },
    reduce = function(state, payload)
        -- Discard the draft. The view switch back to landing fires
        -- separately so callers can also choose to return to a different
        -- view (e.g. Detail when editing an existing smartset).
        local s = state.session.ui.styles.smartset
        s.draftKey       = nil
        s.draft          = { id = nil, displayName = "", description = "", type = "smartset", descAuto = true }
        s.rules          = {}
        s.activeAxis     = "room"
        s.activeSeverity = "all"
        s.dirty          = false

    -- ===== 14.5 Snapshot + Import =========================================
    end }

HDG.Actions:Register{ name = "STYLES_PLACED_DECOR_OBSERVED",
    persists = false, combatUnsafe = false,
    retainsScroll = true,  -- one piece changed in place; a grid that resets to the top loses the player's place mid-placement (Discord 2026-09-06)
    invalidates = { "session.styles.placedDecor" },
    reduce = function(state, payload)
        local guid = payload.decorGUID
        if guid then
            local now = _G.time()  -- exception(boundary): wall-clock stamp
            local map = state.session.styles.placedDecor
            local existing = map[guid]
            map[guid] = {
                decorGUID = guid,
                decorID   = payload.decorID,
                -- Same area segment the batch path records, so both producers
                -- write the same entry shape and the Placed list can scope on it.
                areaID    = payload.areaID,
                itemID    = payload.itemID,
                name      = payload.name,
                -- placedAt: preserve original on edit re-observe; stamp on first sighting
                placedAt  = (existing and existing.placedAt) or now,
            }
        end
    end }

HDG.Actions:Register{ name = "STYLES_PLACED_DECOR_REMOVED",
    persists = true, combatUnsafe = false,
    retainsScroll = true,  -- one piece changed in place; a grid that resets to the top loses the player's place mid-placement (Discord 2026-09-06)
            invalidates = { "session.styles.placedDecor", "account.recentActivity" },
    reduce = function(state, payload)
        local guid = payload.decorGUID
        if guid then
            -- Record the removal in RecentActivity. itemID comes from the live
            -- placedDecor entry when present (decor placed/edited this session), else
            -- from payload.itemID (parsed from the GUID in the observer) so removing
            -- PRE-EXISTING decor still counts. Attributed to the active house.
            local entry  = state.session.styles.placedDecor[guid]
            local itemID = (entry and entry.itemID) or payload.itemID
            if itemID then
                _recentAppend(state, state.account.recentActivity.lastHouseKey,
                              itemID, "removed")
            end
            state.session.styles.placedDecor[guid] = nil
        end
    end }

HDG.Actions:Register{ name = "STYLES_PLACED_DECOR_CLEAR",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.styles.placedDecor" },
    reduce = function(state, payload)
        state.session.styles.placedDecor = {}
    end }

HDG.Actions:Register{ name = "RECENT_SESSION_START",
    persists = true, combatUnsafe = false,
            invalidates = { "account.recentActivity" },
    reduce = function(state, payload)
        -- Seal the active (newest, unsealed) session, open a fresh one. Keyed
        -- by the stable faction house id. Caps history at RECENT_SESSION_CAP.
        -- An active session that recorded NO events is reused (so opening/
        -- closing the editor without placing anything doesn't spam empty
        -- "Now (0)" sessions).
        local key = payload.houseKey
        if not key then return end
        local ra = state.account.recentActivity
        ra.lastHouseKey = key
        local house = ra.houses[key]
        if not house then house = { sessionOrder = {}, sessions = {} }; ra.houses[key] = house end
        _openNewRecentSession(house)
    end }

HDG.Actions:Register{ name = "RECENT_DECOR_PLACED",
    persists = true, combatUnsafe = false,
    retainsScroll = true,  -- one piece changed in place; a grid that resets to the top loses the player's place mid-placement (Discord 2026-09-06)
            invalidates = { "account.recentActivity" },
    reduce = function(state, payload)
        _recentAppend(state, payload.houseKey, payload.itemID, "placed")
    end }

HDG.Actions:Register{ name = "STYLES_SNAPSHOT_PLACED",
    persists = true, combatUnsafe = false, invalidates = { "account.collections" },
    reduce = function(state, payload)
        -- Account-wide snapshot of everything the player has placed. The controller
        -- scans the catalog (numPlaced>0) and passes distinct itemIDs in payload.items
        -- (reducer stays pure -- no observer call here). This is the only taint-safe
        -- full placed-decor list; a per-house split is impossible (GetAllPlacedDecor
        -- taints, editor-frame hooks taint) -- see docs/HDGR_HOUSE_SNAPSHOTS.md.
        -- takenAt + displayName stamped at the dispatch site (date()/time() boundary).
        local items = payload.items or {}  -- exception(boundary): placed-decor list stamped at dispatch site
        if #items == 0 then return end
        local ts = payload.takenAt or 0  -- exception(boundary): takenAt stamped at dispatch site (time() boundary)
        -- Monotonic id (NOT the timestamp) so two snapshots in the same second can't
        -- collide-overwrite; same counter as smartset ids. takenAt stays for display.
        state.account.collectionSeq = (state.account.collectionSeq or 0) + 1  -- exception(boundary): pre-counter saved accounts lack collectionSeq
        local id = "snapshot:" .. state.account.collectionSeq
        state.account.collections = state.account.collections or {}
        state.account.collections[id] = {
            id          = id,
            type        = "snapshot",
            displayName = payload.displayName or ("Snapshot " .. tostring(ts)),
            description = "",
            items       = items,
            takenAt     = ts,
            iconAtlas   = HDG.Constants.SNAPSHOT_ICON_ATLAS,  -- decorate-mode house glyph
        }
    end }

HDG.Actions:Register{ name = "STYLES_IMPORT_SET_URL",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.import.urlText",
                                                   "session.ui.styles.import.parseDisplayName",
                                                   "session.ui.styles.import.parseSource",
                                                   "session.ui.styles.import.previewItems",
                                                   "session.ui.styles.import.parseUnmatched",
                                                   "session.ui.styles.import.parseError" },
    reduce = function(state, payload)
        state.session.ui.styles.import.urlText = payload.text
        -- Clear stale preview / error / parser hints on text change so the
        -- user sees a fresh state when they re-Parse.
        state.session.ui.styles.import.previewItems      = nil
        state.session.ui.styles.import.parseError        = nil
        state.session.ui.styles.import.parseSource       = nil
        state.session.ui.styles.import.parseDisplayName  = nil
        state.session.ui.styles.import.parseUnmatched    = nil
    end }

HDG.Actions:Register{ name = "STYLES_IMPORT_PARSE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.import.previewItems",
                                                   "session.ui.styles.import.parseError",
                                                   "session.ui.styles.import.parseDisplayName",
                                                   "session.ui.styles.import.parseSource",
                                                   "session.ui.styles.import.parseUnmatched" },
    reduce = function(state, payload)
        -- Delegate to HDG.Parsers (Modules/HDGR_Parsers.lua). Walks the
        -- parser registry; first parser to recognize the pasted text wins.
        -- Supports: style blobs (HDG:1:), shopping list blobs (HDGVL:1:),
        -- Blizzard |Hitem chat links, URL ?items=NNN query params (wowhead
        -- / housing.wowdb.com / generic), and a fallback digit-run parser
        -- for raw CSVs.
        local text   = state.session.ui.styles.import.urlText or ""
        local result = HDG.Parsers and HDG.Parsers:Parse(text)  -- exception(boundary): optional module / not yet built
                       or { ok = false, error = "Parsers unavailable" }
        if result.ok then
            state.session.ui.styles.import.previewItems = result.items
            state.session.ui.styles.import.parseError   = nil
            -- Stash hints so the commit step can pick up a parser-suggested
            -- name + source URL. parseUnmatched = entries the live catalog
            -- couldn't resolve (e.g. unreleased decor IDs); drives the status line.
            state.session.ui.styles.import.parseSource     = result.source
            state.session.ui.styles.import.parseDisplayName = result.displayName
            state.session.ui.styles.import.parseUnmatched   = result.unmatched
        else
            state.session.ui.styles.import.previewItems = nil
            state.session.ui.styles.import.parseError   = result.error or "Parse failed"
            state.session.ui.styles.import.parseUnmatched = nil
        end
    end }

HDG.Actions:Register{ name = "STYLES_IMPORT_COMMIT",
    persists = true,  combatUnsafe = false,  -- writes account.collections -> must QueueSave
    invalidates = { "account.collections",
                                                   "session.ui.styles.import" },
    reduce = function(state, payload)
        local preview = state.session.ui.styles.import.previewItems
        if not (preview and #preview > 0) then return end
        local ts = (_G.time and _G.time()) or 0
        local id = "shopping:" .. tostring(ts)
        local sessionImport = state.session.ui.styles.import
        -- Precedence: explicit payload override > parser-suggested name >
        -- timestamp default.
        local name = payload.displayName
                     or sessionImport.parseDisplayName
                     or ("Shopping List " .. tostring(ts))
        state.account.collections = state.account.collections or {}
        state.account.collections[id] = {
            id          = id,
            type        = "shopping",
            displayName = name,
            description = "",
            items       = preview,
            importedAt  = ts,
            source      = sessionImport.parseSource or sessionImport.urlText,
        }
        -- Reset import session UI after a successful commit so re-entering
        -- the Import view starts clean.
        state.session.ui.styles.import.urlText           = ""
        state.session.ui.styles.import.previewItems      = nil
        state.session.ui.styles.import.parseError        = nil
        state.session.ui.styles.import.parseSource       = nil
        state.session.ui.styles.import.parseDisplayName  = nil
        state.session.ui.styles.import.destination       = "style"
    end }

-- Import destination radio: My Styles (style) | Project Set (set) | Shopping List (shopping).
HDG.Actions:Register{ name = "STYLES_IMPORT_SET_DESTINATION",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.styles.import" },
    reduce = function(state, payload)
        local d = payload.destination
        if d == "style" or d == "set" or d == "shopping" then
            state.session.ui.styles.import.destination = d
        end
    end }

-- Editable import title. The parser seeds parseDisplayName; the player can override
-- it before committing. Empty -> nil so the commit name falls back to a default
-- (never an empty "" name -- Lua treats "" as truthy).
HDG.Actions:Register{ name = "STYLES_IMPORT_SET_TITLE",
    persists = false, combatUnsafe = false, noisy = true,
    invalidates = { "session.ui.styles.import.parseDisplayName" },
    reduce = function(state, payload)
        local t = payload.text
        state.session.ui.styles.import.parseDisplayName = (t and t ~= "" and t) or nil
    end }

-- Commit the parsed preview as a "My Style" -- an editable type=style collection
-- (shows in Browse -> My Styles, openable in the Style Curator).
HDG.Actions:Register{ name = "STYLES_IMPORT_COMMIT_AS_STYLE",
    persists = true,  combatUnsafe = false,  -- writes account.collections -> must QueueSave
    invalidates = { "account.collections", "session.ui.styles.import" },
    reduce = function(state, payload)
        local imp = state.session.ui.styles.import
        local preview = imp.previewItems
        if not (preview and #preview > 0) then return end
        local ts   = (_G.time and _G.time()) or 0
        local id   = "style:import:" .. tostring(ts)
        local name = payload.displayName or imp.parseDisplayName or ("Imported Style " .. tostring(ts))
        local items = {}
        for i, itemID in ipairs(preview) do items[i] = itemID end
        state.account.collections = state.account.collections or {}  -- exception(boundary): lazily-created collections map
        state.account.collections[id] = {
            id          = id,
            type        = "style",
            displayName = name,
            description = "",
            items       = items,
            createdAt   = ts,
            source      = imp.parseSource or imp.urlText,
        }
        imp.urlText, imp.previewItems, imp.parseError    = "", nil, nil
        imp.parseSource, imp.parseDisplayName            = nil, nil
        imp.destination                                  = "style"
    end }

-- Commit the parsed preview as a Project "My Design" -- a furnishing set in Projects.
-- Mirrors FURN_SET_CREATE's record shape (id/name/items/createdAt + session.furn bump).
HDG.Actions:Register{ name = "STYLES_IMPORT_COMMIT_AS_SET",
    persists = true,  combatUnsafe = false,  -- writes account.furnishingSets -> must QueueSave
    invalidates = { "account.furnishingSets", "session.furn", "session.ui.styles.import" },
    reduce = function(state, payload)
        local imp = state.session.ui.styles.import
        local preview = imp.previewItems
        if not (preview and #preview > 0) then return end
        local acct = state.account
        acct.furnishingSetSeq = acct.furnishingSetSeq + 1
        local id, items = "set:" .. acct.furnishingSetSeq, {}
        for i, itemID in ipairs(preview) do items[i] = { id = itemID, count = 1 } end
        local ts = (_G.time and _G.time()) or 0
        acct.furnishingSets[id] = {
            id        = id,
            name      = payload.displayName or imp.parseDisplayName or ("Imported Set " .. tostring(ts)),
            items     = items,
            createdAt = ts,
        }
        state.session.furn.lastSetID = id
        state.session.furn.changeSeq = state.session.furn.changeSeq + 1
        imp.urlText, imp.previewItems, imp.parseError    = "", nil, nil
        imp.parseSource, imp.parseDisplayName            = nil, nil
        imp.destination                                  = "style"
    end }

HDG.Actions:Register{ name = "STYLES_IMPORT_RESET",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.styles.import" },
    reduce = function(state, payload)
        state.session.ui.styles.import.urlText           = ""
        state.session.ui.styles.import.previewItems      = nil
        state.session.ui.styles.import.parseError        = nil
        state.session.ui.styles.import.parseSource       = nil
        state.session.ui.styles.import.parseDisplayName  = nil
        state.session.ui.styles.import.parseUnmatched    = nil
        state.session.ui.styles.import.destination       = "style"
    end }

HDG.Actions:Register{ name = "STYLES_OPEN_IMPORT",
    persists = true,  combatUnsafe = false,
    -- Writes the persistent top-tab (account.ui.view) AND the transient sub-view, so the
    -- Tools > Import launcher (which doesn't go through setView) can land the user in one dispatch.
    invalidates = { "account.ui.view", "session.ui.styles.view", "session.ui.styles.import" },
    reduce = function(state, payload)
        state.account.ui.view = "styles"
        state.session.ui.styles.view = "import"
        local imp = state.session.ui.styles.import
        imp.urlText, imp.previewItems, imp.parseError       = "", nil, nil
        imp.parseSource, imp.parseDisplayName, imp.destination = nil, nil, "style"
        imp.parseUnmatched = nil
    end }

-- Export sub-view. OPEN sets the persistent top-tab + transient sub-view in one
-- dispatch (Tools > Export launcher doesn't go through setView) and resets the
-- selection/format/search. SELECT/SET_FORMAT/SET_SEARCH are transient (no persist).
HDG.Actions:Register{ name = "STYLES_OPEN_EXPORT",
    persists = true,  combatUnsafe = false,
    invalidates = { "account.ui.view", "session.ui.styles.view", "session.ui.styles.export" },
    reduce = function(state, payload)
        state.account.ui.view = "styles"
        state.session.ui.styles.view = "export"
        local exp = state.session.ui.styles.export
        exp.selectedKey, exp.format, exp.search = nil, "hdg", ""
    end }

HDG.Actions:Register{ name = "STYLES_EXPORT_SELECT",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.styles.export" },
    reduce = function(state, payload)
        local exp = state.session.ui.styles.export
        exp.selectedKey = payload.key
        -- DD2 only targets the collection (wowdb's only importer loads ALL your
        -- decor); every other source is HDG-native. Default the format on select.
        exp.format = (payload.key == "collection") and "dd2" or "hdg"
    end }

HDG.Actions:Register{ name = "STYLES_EXPORT_SET_FORMAT",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.styles.export" },
    reduce = function(state, payload) state.session.ui.styles.export.format = payload.format end }

HDG.Actions:Register{ name = "STYLES_EXPORT_SET_SEARCH",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.styles.export" },
    reduce = function(state, payload) state.session.ui.styles.export.search = payload.text end }

HDG.Actions:Register{ name = "STYLES_INVALIDATE_CACHE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.styles.changeSeq" },
    reduce = function(state, payload)
        -- Tick bump; actual cache clear runs via Store subscriber -> StyleEngine:InvalidateCache.
        state.session.styles.changeSeq =
            (state.session.styles.changeSeq or 0) + 1
    end }

HDG.Actions:Register{ name = "COLLECTION_STYLE_ITEM_REMOVED",
    persists = true,  combatUnsafe = false,
            retainsScroll = true,
            invalidates = function(action)
                local id = action.payload and action.payload.collectionID
                if id then
                    return { P.Join("account.collections", id, "items") }
                end
                return { "account.collections" }
            end,
    reduce = function(state, payload)
        local coll = payload.collectionID and state.account.collections
                     and state.account.collections[payload.collectionID]
        if coll and coll.items and payload.itemID then
            for i, id in ipairs(coll.items) do
                if id == payload.itemID then
                    table.remove(coll.items, i)
                    break
                end
            end
        end

    -- =====================================================================
    -- Zone Scanner
    -- =====================================================================
    -- ZONE_CHANGED: stamp new mapID, clear expanded set (scrollbox starts collapsed).
    -- Search query intentionally persists across zone changes for multi-zone workflows.
    end }

HDG.Actions:Register{ name = "ZONE_CHANGED",
    persists = false, combatUnsafe = false,
            invalidates = { "session.zone.currentMapID",
                            "session.zone.currentZoneName",
                            "session.ui.zoneScanner.expanded" },
    reduce = function(state, payload)
        -- ZoneObserver:Probe coerces mapID to a number (0 sentinel on
        -- API miss) and mapName to a string ("" sentinel) before dispatch,
        -- so this reducer reads both strictly. Defensive `or 0` / `or ""`
        -- here would mask producer regressions instead of surfacing them.
        state.session.zone.currentMapID    = payload.mapID
        state.session.zone.currentZoneName = payload.mapName
        state.session.ui.zoneScanner.expanded = {}
    end }

HDG.Actions:Register{ name = "ZONE_POPUP_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.zonePopupShown" },
    reduce = function(state, payload)
        state.account.ui.zonePopupShown =
            not (state.account.ui.zonePopupShown == true)
    end }

HDG.Actions:Register{ name = "ZONE_TOGGLE_VENDOR",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.zoneScanner.expanded" },
    reduce = function(state, payload)
        local npcID = payload.npcID
        if type(npcID) == "number" then
            local exp = state.session.ui.zoneScanner.expanded
            _toggleSetMember(exp, npcID)
        end
    end }

HDG.Actions:Register{ name = "ZONE_SET_SEARCH",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.zoneScanner.searchQuery" },
    reduce = function(state, payload)
        state.session.ui.zoneScanner.searchQuery =
            type(payload.text) == "string" and payload.text or ""
    end }

HDG.Actions:Register{ name = "ZONE_TOGGLE_COLLECTED",
    persists = false, combatUnsafe = false,
            invalidates = { "session.ui.zoneScanner.showCollected" },
    reduce = function(state, payload)
        state.session.ui.zoneScanner.showCollected =
            not (state.session.ui.zoneScanner.showCollected == true)


    -- =====================================================================
    -- Lumber Tracker
    -- =====================================================================
    end }

HDG.Actions:Register{ name = "LUMBER_HARVESTED",
    persists = false, combatUnsafe = false,
            invalidates = { "session.lumber.blips", "session.lumber.tick",
                            "account.lumber.sessions" },
    reduce = function(state, payload)
        -- Append blip + bump tick. Coords nil when observer can't resolve position
        -- (loading screen, sub-map without world origin) -- skip blip, still bump tick.
        local s = state.session.lumber
        if payload.x and payload.y and payload.mapID then
            s.blips[#s.blips + 1] = {
                lumberID = payload.lumberID,
                qty      = payload.qty,
                x        = payload.x,
                y        = payload.y,
                mapID    = payload.mapID,
                ts       = payload.timestamp,
            }
        end
        s.tick = s.tick + 1
        -- Append to the per-char session lastHarvestAt + accumulate count
        -- IF a session is active for this lumberID (otherwise this is a
        -- "between sessions" harvest the observer will start a session on).
        local activeID = s.activeFarmingID
        if activeID == payload.lumberID then
            local charKey = state.session.identity.charKey
            local charSessions = state.account.lumber.sessions[charKey]
            local session = charSessions and charSessions[activeID]
            if session then
                session.lastHarvestAt = payload.timestamp
            end
        end
    end }

HDG.Actions:Register{ name = "LUMBER_SESSION_START",
    persists = true, combatUnsafe = false,
            invalidates = { "session.lumber.activeFarmingID",
                            "account.lumber.sessions" },
    reduce = function(state, payload)
        -- First harvest after idle window; seeds per-char session record (startCount = bag total at start).
        local s = state.session.lumber
        s.activeFarmingID = payload.lumberID
        local charKey = state.session.identity.charKey
        state.account.lumber.sessions[charKey] =
            state.account.lumber.sessions[charKey] or {}
        state.account.lumber.sessions[charKey][payload.lumberID] = {
            startedAt     = payload.timestamp,
            startCount    = payload.startCount,
            lastHarvestAt = payload.timestamp,
            finalizedAt   = nil,
        }
    end }

HDG.Actions:Register{ name = "LUMBER_SESSION_END",
    persists = true, combatUnsafe = false,
            invalidates = { "session.lumber.activeFarmingID",
                            "account.lumber.sessions" },
    reduce = function(state, payload)
        -- Stamps finalizedAt so counter row keeps displaying totals after activeFarmingID clears.
        local s = state.session.lumber
        local activeID = s.activeFarmingID
        if activeID then
            local charKey = state.session.identity.charKey
            local charSessions = state.account.lumber.sessions[charKey]
            local session = charSessions and charSessions[activeID]
            if session then
                session.finalizedAt = payload.timestamp
            end
        end
        s.activeFarmingID = nil
    end }

HDG.Actions:Register{ name = "LUMBER_HISTORY_PUSH",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.history" },
    reduce = function(state, payload)
        -- Per-session summary for the Your Data farming log; ring buffer capped at LUMBER_HISTORY_CAP.
        local hist = state.account.lumber.history
        hist.nextID = hist.nextID + 1
        hist.entries[#hist.entries + 1] = {
            id           = hist.nextID,
            lumberID     = payload.lumberID,
            charKey      = payload.charKey,
            startedAt    = payload.startedAt,
            finalizedAt  = payload.finalizedAt,
            sessionTotal = payload.sessionTotal,
            zone         = payload.zone,
            character    = payload.character,
            realm        = payload.realm,
        }
        local cap = HDG.Constants.LUMBER_HISTORY_CAP
        while #hist.entries > cap do
            table.remove(hist.entries, 1)
        end
    end }

HDG.Actions:Register{ name = "LUMBER_BLIP_GC",
    persists = false, combatUnsafe = false,
            invalidates = { "session.lumber.blips" },
    reduce = function(state, payload)
        -- Drop blips older than 1 hr (RESPAWN_SECONDS; distinct from the 600s radar color-cycle constant).
        local s   = state.session.lumber
        local now = payload.now
        local ttl = 3600  -- mirror of HDG.LumberObserver.RESPAWN_SECONDS
        local kept = {}
        for _, b in ipairs(s.blips) do
            if now - b.ts < ttl then kept[#kept + 1] = b end
        end
        s.blips = kept
    end }

HDG.Actions:Register{ name = "LUMBER_TICK",
    persists = false, combatUnsafe = false,
            noisy = true,  -- 1s heartbeat while farming; would flood the dispatch log otherwise
            invalidates = { "session.lumber.tick" },
    reduce = function(state, payload)
        -- 1s heartbeat while farming; invalidates duration+rate selectors without a bag-delta.
        state.session.lumber.tick = state.session.lumber.tick + 1
    end }

HDG.Actions:Register{ name = "LUMBER_WINDOW_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.config.windowVisible" },
    reduce = function(state, payload)
        local c = state.account.lumber.config
        if payload and payload.visible ~= nil then
            c.windowVisible = payload.visible and true or false
        else
            _toggleBool(c, "windowVisible")
        end
    end }

HDG.Actions:Register{ name = "LUMBER_WINDOW_POSITION_SET",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.config.position" },
    reduce = function(state, payload)
        state.account.lumber.config.position = {
            x = payload.x,
            y = payload.y,
        }
    end }

HDG.Actions:Register{ name = "LUMBER_RADAR_COLLAPSE_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.config.radarCollapsed" },
    reduce = function(state, payload)
        local c = state.account.lumber.config
        _toggleBool(c, "radarCollapsed")
    end }

HDG.Actions:Register{ name = "LUMBER_AUTOSHOW_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.config.autoShowOnHarvest" },
    reduce = function(state, payload)
        local c = state.account.lumber.config
        _toggleBool(c, "autoShowOnHarvest")
    end }

HDG.Actions:Register{ name = "LUMBER_LIST_COLLAPSE_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.config.listCollapsed" },
    reduce = function(state, payload)
        local c = state.account.lumber.config
        _toggleBool(c, "listCollapsed")
    end }

HDG.Actions:Register{ name = "LUMBER_GOAL_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.config.lumberGoal" },
    reduce = function(state, payload)
        local c = state.account.lumber.config
        c.lumberGoal = (c.lumberGoal == "queue") and "decor" or "queue"
    end }

HDG.Actions:Register{ name = "LUMBER_RADAR_SCALE_SET",
    persists = true, combatUnsafe = false,
            invalidates = { "account.lumber.config.radarScale" },
    reduce = function(state, payload)
        local scale = payload.scale
        if type(scale) == "number" and scale > 0 then
            state.account.lumber.config.radarScale = scale
        end

    -- =====================================================================
    -- Shopping list
    -- =====================================================================
    end }

HDG.Actions:Register{ name = "SHOPPING_WIDGET_TOGGLE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.shoppingWidgetShown" },
    reduce = function(state, payload)
        state.account.ui.shoppingWidgetShown =
            not (state.account.ui.shoppingWidgetShown == true)
    end }

HDG.Actions:Register{ name = "SHOPPING_LIST_CREATE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists", "account.activeShoppingListId",
                            "account.shoppingListSeq" },
    reduce = function(state, payload)
        state.account.shoppingListSeq = state.account.shoppingListSeq + 1
        local id = "L" .. tostring(state.account.shoppingListSeq)
        state.account.vendorShoppingLists[id] = {
            name      = type(payload.name) == "string" and payload.name or ("List " .. id),
            items     = {},
            meta      = {},
            createdAt = _G.time(),  -- exception(boundary): wall-clock stamp
        }
        -- Auto-activate the first list created (HDG parity).
        if state.account.activeShoppingListId == "" then
            state.account.activeShoppingListId = id
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_LIST_DELETE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists", "account.activeShoppingListId" },
    reduce = function(state, payload)
        local id = payload.id
        state.account.vendorShoppingLists[id] = nil
        if state.account.activeShoppingListId == id then
            -- Pick any remaining list as new active, or "" if none.
            local nextId = ""
            for other in pairs(state.account.vendorShoppingLists) do
                nextId = other; break
            end
            state.account.activeShoppingListId = nextId
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_LIST_RENAME",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        local list = state.account.vendorShoppingLists[payload.id]
        if list then list.name = tostring(payload.name or list.name) end
    end }

HDG.Actions:Register{ name = "SHOPPING_LIST_DUPLICATE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists", "account.shoppingListSeq" },
    reduce = function(state, payload)
        local src = state.account.vendorShoppingLists[payload.id]
        if src then
            state.account.shoppingListSeq = state.account.shoppingListSeq + 1
            local id = "L" .. tostring(state.account.shoppingListSeq)
            -- Shallow copy each entry (entries are flat tables; per-entry
            -- copy stops the duplicate from sharing entry references with
            -- the source).
            local copyItems = {}
            for i, entry in ipairs(src.items) do
                copyItems[i] = {
                    itemID  = entry.itemID,
                    npcID   = entry.npcID,
                    qty     = entry.qty,
                    addedAt = entry.addedAt,
                }
            end
            state.account.vendorShoppingLists[id] = {
                name      = tostring(payload.name or (src.name .. " (copy)")),
                items     = copyItems,
                meta      = {},   -- duplicates start with fresh meta (no inherited attribution)
                createdAt = _G.time(),  -- exception(boundary): wall-clock stamp
            }
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_LIST_ACTIVATE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.activeShoppingListId" },
    reduce = function(state, payload)
        if state.account.vendorShoppingLists[payload.id] then
            state.account.activeShoppingListId = payload.id
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_LIST_CLEAR",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        local list = state.account.vendorShoppingLists[payload.id]
        if list then list.items = {} end
    end }

HDG.Actions:Register{ name = "SHOPPING_LIST_SET_META",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        local list = state.account.vendorShoppingLists[payload.id]
        if list and type(payload.key) == "string" then
            list.meta = list.meta or {}
            list.meta[payload.key] = payload.value
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_TOGGLE_EXPANDED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.shoppingList.expanded" },
    reduce = function(state, payload)
        -- Flip a collapse flag (true = COLLAPSED). wishList is a scalar; zones/vendors are maps
        -- keyed by zoneName / npcID. Reducer owns the flip; the view dispatches only which bucket
        -- + key. (Replaces the controller's read-clone-flip-write _patchExpanded.)
        local e = state.session.ui.shoppingList.expanded
        if payload.bucket == "wishList" or payload.bucket == "ahList" then
            _toggleBool(e, payload.bucket)
        elseif payload.bucket and payload.key ~= nil then
            local b = e[payload.bucket]
            _toggleSetMember(b, payload.key)
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_ITEM_ADD",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        local listID = payload.listID or state.account.activeShoppingListId
        local list = state.account.vendorShoppingLists[listID]
        if list then
            -- Coalesce: same (itemID, npcID) tuple bumps qty instead of
            -- producing a duplicate row.
            local merged
            for _, entry in ipairs(list.items) do
                if entry.itemID == payload.itemID and entry.npcID == payload.npcID then
                    entry.qty = (entry.qty or 1) + (payload.qty or 1)
                    merged = true
                    break
                end
            end
            if not merged then
                list.items[#list.items + 1] = {
                    itemID  = payload.itemID,
                    npcID   = payload.npcID,   -- nil = wishlist
                    qty     = payload.qty or 1,  -- exception(boundary): Shopping ADD may omit qty default-1
                    addedAt = time(),
                }
            end
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_ITEM_REMOVE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        local listID = payload.listID or state.account.activeShoppingListId
        local list = state.account.vendorShoppingLists[listID]
        if list then
            for i, entry in ipairs(list.items) do
                if entry.itemID == payload.itemID and entry.npcID == payload.npcID then
                    table.remove(list.items, i)
                    break
                end
            end
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_ITEM_SET_QTY",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        local listID = payload.listID or state.account.activeShoppingListId
        local list = state.account.vendorShoppingLists[listID]
        if list then
            for _, entry in ipairs(list.items) do
                if entry.itemID == payload.itemID and entry.npcID == payload.npcID then
                    entry.qty = math.max(1, math.floor(tonumber(payload.qty) or 1))  -- exception(boundary): string-input qty from EditBox
                    break
                end
            end
        end
    end }

HDG.Actions:Register{ name = "SHOPPING_ITEM_ADJUST_QTY",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        -- Relative delta applied to CURRENT state, so rapid +/- clicks accumulate:
        -- the row buttons can't snapshot qty (re-render is deferred a frame, so a
        -- captured absolute qty collides). Remove-at-zero lives here, not the
        -- controller, so the whole transition is atomic.
        local listID = payload.listID or state.account.activeShoppingListId
        local list = state.account.vendorShoppingLists[listID]
        if list then
            for i, entry in ipairs(list.items) do
                if entry.itemID == payload.itemID and entry.npcID == payload.npcID then
                    local nextQty = (entry.qty or 1) + payload.delta  -- exception(boundary): legacy shopping entry pre-qty
                    if nextQty <= 0 then
                        table.remove(list.items, i)
                    else
                        entry.qty = nextQty
                    end
                    break
                end
            end
        end
    end }

-- A merchant purchase LANDED (MerchantObserver's purchase credit): take it off
-- the ACTIVE list -- the one on screen. An item can sit on several lists, and the
-- list being shopped from is the one that was bought against. Entries match on
-- itemID alone: the merchant's npcID is never read (a secret at instanced
-- vendors), and the item may be listed under another vendor or as a wish. List
-- order, until the bought quantity is used up; an entry at 0 is removed.
HDG.Actions:Register{ name = "SHOPPING_ITEM_PURCHASED",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        local list = state.account.vendorShoppingLists[state.account.activeShoppingListId]
        if not list then return end   -- exception(nullable): no list is active
        local left, i = payload.qty, 1
        while left > 0 and i <= #list.items do
            local entry = list.items[i]
            local have = entry.qty or 1   -- exception(boundary): legacy shopping entry pre-qty
            if entry.itemID ~= payload.itemID then
                i = i + 1
            elseif have <= left then
                left = left - have
                table.remove(list.items, i)
            else
                entry.qty = have - left
                left = 0
            end
        end
    end }

-- Resolve one npcID-less wishlist entry to `npc`: merge into an existing
-- (itemID, npcID) vendor row if one exists (coalesce, mirroring ITEM_ADD) and
-- drop the entry, else stamp the npcID onto it. Caller walks high->low so the
-- removed index stays valid.
local function _resolveVendorForEntry(list, i, entry, npc)
    local mergeInto
    for _, other in ipairs(list.items) do
        if other ~= entry and other.itemID == entry.itemID and other.npcID == npc then
            mergeInto = other; break
        end
    end
    if mergeInto then
        mergeInto.qty = (mergeInto.qty or 1) + (entry.qty or 1)
        table.remove(list.items, i)
    else
        entry.npcID = npc
    end
end

HDG.Actions:Register{ name = "SHOPPING_RESOLVE_VENDORS",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists" },
    reduce = function(state, payload)
        -- Persist resolved vendor npcIDs onto wishlist (npcID-less) entries so they
        -- bucket under their vendor + travel with Export. resolutions = {[itemID]=npcID}.
        -- Walk high->low: a resolved row that collides with an existing (itemID, npcID)
        -- vendor row merges its qty in and is removed (coalesce, mirroring ITEM_ADD).
        local list = state.account.vendorShoppingLists[payload.listID]
        if not list then return end
        local res = payload.resolutions
        for i = #list.items, 1, -1 do
            local entry = list.items[i]
            local npc = res[entry.itemID]   -- resolved vendor for this itemID, or nil
            -- Applies to entries that ALREADY carry an npcID, not just blanks:
            -- flipping the neighborhood toggle has to move a list that was
            -- resolved under the old preference, or the setting would only ever
            -- affect the next import. The CALLER decides what is safe to move --
            -- ShoppingController only ever proposes a swap between the two
            -- housing neighborhoods, so a vendor picked anywhere else stands.
            if npc and npc ~= entry.npcID then
                _resolveVendorForEntry(list, i, entry, npc)
            end
        end

    -- =========================================================================
    -- Catalog lifecycle
    -- =========================================================================
    end }

HDG.Actions:Register{ name = "SHOPPING_SET_NEIGHBORHOOD",
    persists = true, combatUnsafe = false,
            invalidates = { "account.ui.shoppingNeighborhood" },
    reduce = function(state, payload)
        -- Preference only. The npcIDs already stored on the lists are rewritten
        -- by ShoppingController's enrich pass, which subscribes to this action --
        -- it needs the catalog and VendorAugment to find the twin vendor, and
        -- neither belongs in a reducer.
        state.account.ui.shoppingNeighborhood = payload.value
    end }

HDG.Actions:Register{ name = "CATALOG_LOAD_REQUESTED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.catalog" },
    reduce = function(state, payload)
        state.session.catalog.status = "loading"
    end }

HDG.Actions:Register{ name = "CATALOG_LOAD_FAILED",
    persists = false, combatUnsafe = false,
    invalidates = { "session.catalog.status" },
    reduce = function(state, payload)
        -- Without this, status stays "loading" -> infinite spinner.
        state.session.catalog.status = "error"
    end }

-- Initial-load overlay phase: "hidden" | "loading" | "success". Driven by the
-- catalogIntro controller (window-open + DECOR_CATALOG_READY + 0.5s success hold).
HDG.Actions:Register{ name = "CATALOG_INTRO_SET_PHASE",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.catalogIntro" },
    reduce = function(state, payload) state.session.ui.catalogIntro.phase = payload.phase end }

-- Signal-only: the loading overlay's Refresh button. The observer reacts (forces a
-- fresh sweep past the in-flight coalesce + idle guard); no state mutation here.
HDG.Actions:Register{ name = "CATALOG_FORCE_RELOAD",
    persists = false, combatUnsafe = false,
    invalidates = {},
    reduce = function() end }

HDG.Actions:Register{ name = "CATALOG_REFRESH_QUEUED",
    persists = false, combatUnsafe = false,
    invalidates = { "session.catalog.refreshPending",
                                            "session.catalog.variantsLoaded" },
    reduce = function(state, payload)
        state.session.catalog.refreshPending = true
        state.session.catalog.variantsLoaded = false   -- ownership may have changed; force Dyed filter re-batch
    end }

-- ===== Vendor buying (spec docs/HDGR_VENDOR_BUYING_SPEC.md) ==================
-- MerchantObserver builds fresh byItemID tables per dispatch, so the reducer
-- adopts the payload table by reference (no copy needed).
HDG.Actions:Register{ name = "MERCHANT_SET_STATE",
    persists = false, combatUnsafe = false,
    invalidates = { "session.merchant" },
    reduce = function(state, payload)
        local m = state.session.merchant
        m.open     = payload.open == true
        m.byItemID = payload.byItemID or {}   -- exception(boundary): two dispatch shapes -- the close dispatch is {open=false} with no byItemID
        if not m.open then m.buying = nil end -- vendor gone -> any in-flight queue state is moot
    end }

HDG.Actions:Register{ name = "MERCHANT_BUY_PROGRESS",
    persists = false, combatUnsafe = false,
    invalidates = { "session.merchant.buying" },
    reduce = function(state, payload)
        if payload.total then
            state.session.merchant.buying = { total = payload.total, done = payload.done }  -- every _dispatchProgress(total, done) passes both -- strict
        else
            state.session.merchant.buying = nil
        end
    end }

-- Destroy queue progress: `done` is copies the SERVER has taken (confirmed by the
-- item's owned total), never copies merely sent; `waiting` = the server has paused
-- taking them and the queue is retrying. Empty payload = the run ended.
HDG.Actions:Register{ name = "DECOR_DESTROY_PROGRESS",
    persists = false, combatUnsafe = false,
    invalidates = { "session.destroying" },
    reduce = function(state, payload)
        if payload.total then
            state.session.destroying = { total = payload.total, done = payload.done, name = payload.name,
                                         waiting = payload.waiting }
        else
            state.session.destroying = nil
        end
    end }

-- The Destroy decor list sorts by stored count, so every destroy would shuffle
-- it and slide another row under the cursor. The first destroy from the list
-- pins the counts it was sorted by; it re-sorts when the player leaves the tab,
-- toggles the filter or resets (those reducers clear the pin).
HDG.Actions:Register{ name = "DECOR_PIN_STORED_SORT",
    persists = false, combatUnsafe = false,
    invalidates = { "session.ui.decor.pinnedSortCounts" },
    reduce = function(state, payload)
        state.session.ui.decor.pinnedSortCounts = payload.counts
    end }

HDG.Actions:Register{ name = "CATALOG_VARIANTS_LOADED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.catalog.variantsLoaded" },
    reduce = function(state, payload)
        state.session.catalog.variantsLoaded = true
    end }

HDG.Actions:Register{ name = "PROJECTS_UPSERT_HOUSE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.projects.houses" },
    reduce = function(state, payload)
        if payload.houseID then
            local p = state.account.projects
            local house = p.houses[payload.houseID] or {}
            for k, v in pairs(payload.fields or {}) do house[k] = v end
            p.houses[payload.houseID] = house
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_CAPTURE_COMMIT",
    persists = true, combatUnsafe = false,
            invalidates = { "account.projects.houses", "account.projects.layouts", "account.rooms",
                            "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        -- Atomic apply of a finalized capture; observer pre-computes matched/new/orphan + connections.
        local p = state.account.projects
        if payload.houseID then
            local house = p.houses[payload.houseID] or {}
            house.lastCapturedAt = payload.lastCapturedAt or house.lastCapturedAt
            if payload.houseName        then house.name             = payload.houseName end
            if payload.plotID           then house.plotID           = payload.plotID end
            if payload.neighborhoodName then house.neighborhoodName  = payload.neighborhoodName end
            p.houses[payload.houseID] = house
        end
        -- CAPTURE path mirrors REALITY -> the house's CURRENT layout (never the
        -- active one). v7 truth lives in StoreFurnishings.ApplyCapture: placements
        -- ONLY -- capture can never touch rooms' furnishing fields.
        if payload.houseID then
            HDG.StoreFurnishings.ApplyCapture(state, payload)
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_HOUSE_TICK",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.house.budget", "session.house.numFloors", "session.house.editorActive" },
    reduce = function(state, payload)
        -- Partial patch from HousingObserver; each event updates the subset it knows.
        local h = state.session.house
        if payload.budget       then h.budget = payload.budget end
        if payload.numFloors    ~= nil then h.numFloors = payload.numFloors end
        if payload.editorActive ~= nil then h.editorActive = payload.editorActive end
    end }

HDG.Actions:Register{ name = "PROJECTS_ROOM_CATALOG_UPDATED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.house.roomCatalog" },
    reduce = function(state, payload)
        -- Atomic replace + tick bump; room-source/stock selectors invalidate together.
        local rc = state.session.house.roomCatalog
        rc.byShapeID = payload.byShapeID or {}  -- exception(boundary): atomic-replace; empty keeps table shape if payload omits
        rc.entries   = payload.entries   or {}  -- exception(boundary): atomic-replace; empty keeps table shape if payload omits
        rc.changeSeq      = rc.changeSeq + 1
    end }

-- ===== Blueprints tab (12.1) ================================================
-- All server-derived except SET_LABEL/FORGET (the persisted labels slice).
-- Reduces are STRICT: the observer is the Blizzard boundary and guards there;
-- payloads here are internally guaranteed.

HDG.Actions:Register{ name = "BLUEPRINT_AVAILABLE_SET", persists = false,
    invalidates = { "session.blueprints.available" },
    reduce = function(state, payload) state.session.blueprints.available = payload.available end }

HDG.Actions:Register{ name = "BLUEPRINT_COLLECTION_RECEIVED", persists = false,
    invalidates = { "session.blueprints.groups", "session.blueprints.slots" },
    reduce = function(state, payload)
        state.session.blueprints.groups = payload.groups
        state.session.blueprints.slots  = payload.slots
    end }

HDG.Actions:Register{ name = "BLUEPRINT_CONTENTS_REQUESTED", persists = false,
    invalidates = { "session.blueprints.manifests" },
    reduce = function(state, payload)
        state.session.blueprints.manifests[payload.shareCode] = { status = "pending", requestedAt = payload.requestedAt }
    end }

HDG.Actions:Register{ name = "BLUEPRINT_CONTENTS_RECEIVED", persists = false,
    invalidates = { "session.blueprints.manifests", "account.blueprints.factions" },
    reduce = function(state, payload)
        -- Stale-target guard: the manifest carries its own targetHouseGUID; if a
        -- target is selected and this response is for a different one, a newer
        -- request is in flight -- drop it (latest-wins without request tokens).
        local sb = state.session.blueprints
        if sb.targetHouseGUID and payload.raw.targetHouseGUID ~= sb.targetHouseGUID then return end
        sb.manifests[payload.shareCode] = { status = "received", raw = payload.raw }
        -- Faction (House/Exterior only) is derived at the observer boundary and
        -- cached persistently, so the list row stays tinted across reloads.
        if payload.faction then
            state.account.blueprints.factions[payload.shareCode] = payload.faction
        end
    end }

HDG.Actions:Register{ name = "BLUEPRINT_CONTENTS_FAILED", persists = false,
    invalidates = { "session.blueprints.manifests" },
    reduce = function(state, payload)
        state.session.blueprints.manifests[payload.shareCode] =
            { status = "failed", reasonCode = payload.reasonCode, timedOut = payload.timedOut }
    end }

-- Decor storage changed (a purchase, a placement, a crate), so every cached
-- manifest's "have/need" counts may now be wrong. Mark, never fetch: a player
-- buying a hundred pieces one at a time fires this a hundred times, and the
-- fetch belongs to the moment someone looks (row select / the Refresh button).
HDG.Actions:Register{ name = "BLUEPRINT_MANIFESTS_STALE", persists = false,
    invalidates = { "session.blueprints.manifests" },
    reduce = function(state)
        for _, m in pairs(state.session.blueprints.manifests) do
            if m.status == "received" then m.stale = true end
        end
    end }

HDG.Actions:Register{ name = "BLUEPRINT_PENDING_TICK", persists = false,
    invalidates = { "session.blueprints.pendingNow" },
    reduce = function(state, payload) state.session.blueprints.pendingNow = payload.now end }

HDG.Actions:Register{ name = "BLUEPRINT_SELECT", persists = false,
    invalidates = { "session.blueprints.selectedCode" },
    reduce = function(state, payload)
        state.session.blueprints.selectedCode = payload.shareCode
    end }

HDG.Actions:Register{ name = "BLUEPRINT_PASTE_ADD", persists = true,
    invalidates = { "account.blueprints.pasted", "account.blueprints.pastedTypes", "account.blueprints.pastedAt" },
    reduce = function(state, payload)
        local ab = state.account.blueprints
        if payload.blueprintType then ab.pastedTypes[payload.shareCode] = payload.blueprintType end
        for i = 1, #ab.pasted do if ab.pasted[i] == payload.shareCode then return end end
        ab.pasted[#ab.pasted + 1] = payload.shareCode
        -- First paste wins the stamp: a re-paste of a known code is a no-op above.
        if payload.pastedAt then ab.pastedAt[payload.shareCode] = payload.pastedAt end  -- exception(optional): callers that predate the stamp (tests, API) omit it
    end }

HDG.Actions:Register{ name = "BLUEPRINT_SET_TARGET_HOUSE", persists = false,
    invalidates = { "session.blueprints.targetHouseGUID" },
    reduce = function(state, payload) state.session.blueprints.targetHouseGUID = payload.houseGUID end }

HDG.Actions:Register{ name = "BLUEPRINT_SET_LABEL", persists = true,
    invalidates = { "account.blueprints.labels" },
    reduce = function(state, payload) state.account.blueprints.labels[payload.shareCode] = payload.label end }

-- SAFETY: HDG-state-only. NEVER calls C_HousingBlueprint.DeleteBlueprint --
-- Blizzard's real blueprint catalog is never touched. The forget `x` renders
-- ONLY on pasted rows (controller), so there is no HDG path to delete a saved blueprint.
HDG.Actions:Register{ name = "BLUEPRINT_FORGET", persists = true,
    invalidates = { "account.blueprints.pasted", "account.blueprints.pastedTypes",
                    "account.blueprints.labels", "account.blueprints.factions",
                    "account.blueprints.pastedAt", "account.blueprints.notes",
                    "session.blueprints.selectedCode", "session.blueprints.manifests" },
    reduce = function(state, payload)
        local ab, sb, np = state.account.blueprints, state.session.blueprints, {}
        for i = 1, #ab.pasted do if ab.pasted[i] ~= payload.shareCode then np[#np + 1] = ab.pasted[i] end end
        ab.pasted = np
        ab.pastedTypes[payload.shareCode] = nil
        ab.labels[payload.shareCode] = nil
        ab.factions[payload.shareCode] = nil
        ab.pastedAt[payload.shareCode] = nil
        ab.notes[payload.shareCode]    = nil
        sb.manifests[payload.shareCode] = nil
        if sb.selectedCode == payload.shareCode then sb.selectedCode = np[1] end  -- exception(nullable): may be no codes left
    end }

-- Picker fold sections ("Pasted codes" / "Your catalog"). Sparse set: only
-- folded sections are present, so a never-toggled section reads open.
HDG.Actions:Register{ name = "BLUEPRINT_TOGGLE_SECTION", persists = true,
    retainsScroll = true,  -- a section header is clicked mid-list; yanking to the top loses the user's place
    invalidates = { "account.ui.blueprints.collapsedSections" },
    reduce = function(state, payload)
        _toggleSetMember(state.account.ui.blueprints.collapsedSections, payload.section)
    end }

-- Library preference: leave automatic saves out of the All list.
HDG.Actions:Register{ name = "BLUEPRINT_SET_HIDE_BACKUPS", persists = true,
    invalidates = { "account.ui.blueprints.hideBackups" },
    reduce = function(state, payload) state.account.ui.blueprints.hideBackups = payload.hide == true end }

-- Library column-header click: same column flips direction, a new column
-- resets to the first sort direction declared for it on
-- HDG.Constants.BLUEPRINT_LIBRARY_COLUMNS (text ascending, dates newest first).
HDG.Actions:Register{ name = "BLUEPRINT_LIBRARY_SET_SORT", persists = false,
    invalidates = { "session.ui.blueprints.librarySortCol", "session.ui.blueprints.librarySortDir" },
    reduce = function(state, payload)
        local ui = state.session.ui.blueprints
        if ui.librarySortCol == payload.col then
            ui.librarySortDir = (ui.librarySortDir == "desc") and "asc" or "desc"
        else
            ui.librarySortCol = payload.col
            -- The column table owns each column's first direction, so this
            -- reducer and the header widgets can never disagree about it.
            for _, c in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_COLUMNS) do
                if c.col == payload.col then ui.librarySortDir = c.firstDir end
            end
        end
    end }

-- Free-text note per share code, edited in the Library detail pane. An emptied
-- box dispatches CLEAR rather than SET "" (Mech.WireNoteBox), so `notes` only
-- ever holds codes that still carry text.
HDG.Actions:Register{ name = "BLUEPRINT_SET_NOTE", persists = true,
    invalidates = { "account.blueprints.notes" },
    reduce = function(state, payload) state.account.blueprints.notes[payload.shareCode] = payload.text end }

HDG.Actions:Register{ name = "BLUEPRINT_CLEAR_NOTE", persists = true,
    invalidates = { "account.blueprints.notes" },
    reduce = function(state, payload) state.account.blueprints.notes[payload.shareCode] = nil end }

HDG.Actions:Register{ name = "BLUEPRINT_EXPORT_SUCCESS", persists = false,
    invalidates = { "session.blueprints.selectedCode", "account.blueprints.labels" },
    reduce = function(state, payload)
        state.session.blueprints.selectedCode = payload.shareCode
        -- Optimistic label: show the typed name immediately; the catalog name
        -- (which wins display precedence) replaces it when the collection
        -- round-trip returns. Nil-guarded: replayed/legacy events carry no label.
        if payload.label then  -- exception(optional): label only on live exports
            state.account.blueprints.labels[payload.shareCode] = payload.label
        end
    end }

HDG.Actions:Register{ name = "CATALOG_CATEGORY_TREE_UPDATED",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.house.categoryTree" },
    reduce = function(state, payload)
        -- Blizzard category/subcategory nav snapshot from the observer. Atomic replace
        -- + tick bump so the curator + projects nav selectors invalidate together.
        local ct = state.session.house.categoryTree
        ct.byID       = payload.byID       or {}  -- exception(boundary): atomic-replace; empty keeps table shape if payload omits
        ct.subcatByID = payload.subcatByID or {}  -- exception(boundary): atomic-replace; empty keeps table shape if payload omits
        ct.rootIDs    = payload.rootIDs    or {}  -- exception(boundary): atomic-replace; empty keeps table shape if payload omits
        ct.changeSeq       = ct.changeSeq + 1
    end }

HDG.Actions:Register{ name = "PROJECTS_CLEAR_HOUSE",
    persists = true, combatUnsafe = false,
            invalidates = { "account.projects.layouts", "session.furn", "session.furnIndex" },
    reduce = function(state, payload)
        -- Recapture prep. v8: placements persist (ApplyCapture matches by
        -- capturedID in place, so roomID tags survive); only capture-owned
        -- placements above payload.maxFloor are pruned (deleted floors never
        -- get swept). Resets the capture summary echo.
        if payload.houseID then
            HDG.StoreFurnishings.ClearLayout(state, payload)
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_SET_ACTIVE_VERSION",
    persists = true, combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        -- Switch active version for a house. Invalidates "*" (canvas reads two-level keys).
        if payload.houseID and payload.versionID then
            local house = state.account.projects.houses[payload.houseID]
            if house then house.activeVersionID = payload.versionID end
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_CREATE_VERSION",
    persists = true, combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        -- v7: branch a what-if LAYOUT. Placements copy; ROOMS ARE SHARED BY
        -- REFERENCE (vary a room via a room VARIANT, never per-layout copies).
        if not payload.houseID then return end
        local p     = state.account.projects
        local house = p.houses[payload.houseID]
        if not house then return end  -- exception(nullable): stale UI houseID
        local lid       = _nextVersionID(p)
        local srcLayout = payload.basedOn and p.layouts[payload.basedOn]  -- exception(nullable): from-scratch designs have no basis
        local placements, slotSeq = _copyOrSeedLayoutPlacements(srcLayout)
        p.layouts[lid] = {
            houseID   = payload.houseID, name = payload.name or "What-if",  -- exception(boundary): CREATE_VERSION payload may omit name
            createdAt = payload.createdAt, basedOn = payload.basedOn,
            placements = placements, slotSeq = slotSeq,
        }
        house.activeVersionID = lid
        _reindexRoomLayouts(state.session.furnIndex, placements, lid)
    end }

HDG.Actions:Register{ name = "PROJECTS_DELETE_VERSION",
    persists = true, combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        -- v7: remove a what-if LAYOUT (NEVER the live/current one). Rooms and
        -- their furnishings persist by construction -- only references die.
        -- Reverse-index GC prevents phantom "in N layouts" counts (12 #4).
        if payload.houseID and payload.versionID then
            local p     = state.account.projects
            local house = p.houses[payload.houseID]
            local lid   = payload.versionID
            if house and lid ~= house.currentVersionID and p.layouts[lid] then
                _deindexRoomLayouts(state.session.furnIndex, p.layouts[lid].placements, lid)
                p.layouts[lid] = nil
                if house.activeVersionID == lid then
                    house.activeVersionID = house.currentVersionID
                end
                state.session.furn.changeSeq = state.session.furn.changeSeq + 1
            end
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_SET_VERSION_FLOORS",
    persists = true, combatUnsafe = false,
            invalidates = { "account.projects.layouts" },
    reduce = function(state, payload)
        -- Set the floor count on a what-if version (1..3 cap; enforced here too, not just
        -- the controller, so the store never holds an out-of-range value). nil clears the
        -- override -> floorTabs falls back to scanning room IDs + session.house.numFloors.
        if payload.versionID and payload.numFloors ~= nil then
            local layout = state.account.projects.layouts[payload.versionID]   -- exception(nullable): stale UI layout id
            if layout then
                local n = math.max(1, math.min(3, math.floor(payload.numFloors)))
                layout.numFloors = n
            end
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_RENAME_VERSION",
    persists = true, combatUnsafe = false,
            invalidates = { "account.projects.layouts" },
    reduce = function(state, payload)
        -- Rename a version (name only; structural fields stay locked).
        if payload.versionID and payload.name then
            local layout = state.account.projects.layouts[payload.versionID]   -- exception(nullable): stale UI layout id
            if layout then layout.name = payload.name end
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_IMPORT_LAYOUT",
    persists = true, combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        -- Thin (matches PROJECTS_PLACE_STACKED): the CONTROLLER builds the version
        -- record from the decoded layout, re-keying roomIDs to the target house. The
        -- reducer only mints the id (the counter is state-resident, so minting must be
        -- reducer-side) + activates it, so the controller can read the id back.
        if payload.houseID and payload.version then
            local p     = state.account.projects
            local house = p.houses[payload.houseID]
            -- Importing into an owned-but-uncaptured house creates its record.
            if not house then house = {}; p.houses[payload.houseID] = house end
            -- Stamp the display name the chooser carried; a captured name
            -- (richer: plot-prefixed) is never overwritten.
            if payload.houseName and (not house.name or house.name == "") then
                house.name = payload.houseName
            end
            local lid = _nextVersionID(p)
            payload.version.placements = payload.version.placements or {}   -- exception(boundary): controller-built record
            p.layouts[lid] = payload.version
            house.activeVersionID = lid
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_FOCUS_HOUSE",
    persists = true, combatUnsafe = false,
            invalidates = "*",
    reduce = function(state, payload)
        -- Switch which house the Architect/Projects views show. A monotonic focusSeq
        -- bump makes this house win the house pick (no separate "active" pointer + no
        -- new selector reads -- focusSeq lives under the house record). Focusing an
        -- as-yet-uncaptured house (picked from the owned-houses dropdown) creates a
        -- focus STUB so the pick sticks; capturing it later UPSERTs the same token.
        if payload.houseID then
            local p     = state.account.projects
            local house = p.houses[payload.houseID]
            if not house then house = {}; p.houses[payload.houseID] = house end
            p.houseFocusSeq = (p.houseFocusSeq or 0) + 1
            house.focusSeq  = p.houseFocusSeq
        end
    end }

HDG.Actions:Register{ name = "PROJECTS_PICKER_SET_SOURCE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.projects.pickerSource" },
    reduce = function(state, payload)
        -- Picker source axis (dropdown intent; scalar session write).
        state.session.ui.projects.pickerSource = payload.source or "all"
    end }

HDG.Actions:Register{ name = "PROJECTS_FURN_TOGGLE_COLLAPSE",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.projects.furnCollapsed" },
    reduce = function(state, payload)
        -- Fold/unfold one set group in the room detail (reducer-owned flip;
        -- session-only -- the panel is a workspace, not a dashboard).
        if payload.setID then
            local c = state.session.ui.projects.furnCollapsed
            c[payload.setID] = not c[payload.setID] or nil
        end
    end }

HDG.Actions:Register{ name = "SHIPPING_CRATE_PACK",
    persists = true, combatUnsafe = false, invalidates = { "account.collections" },
    reduce = function(state, payload)
        -- DeepCopy: topology.rooms / connections / contents[].decor are live refs; raw storage
        -- would make the "backup" silently track future mutations.
        if payload.shipID and payload.record then
            state.account.collections[payload.shipID] = DeepCopy(payload.record)
        end
    end }

HDG.Actions:Register{ name = "SHIPPING_CRATE_DELETE",
    persists = true, combatUnsafe = false, invalidates = { "account.collections" },
    reduce = function(state, payload)
        if payload.shipID then state.account.collections[payload.shipID] = nil end
    end }

HDG.Actions:Register{ name = "COMBAT_QUEUE_ACTION",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.combat.queued" },
    reduce = function(state, payload)
        -- Append a deferred action to the lockdown queue. Middleware dispatches
        -- this when an inbound combat-unsafe action arrives during lockdown;
        -- the inbound action's payload is wrapped inside payload.action.
        state.session.combat.queued = state.session.combat.queued or {}
        if payload.action then
            table.insert(state.session.combat.queued, payload.action)
        end
    end }

HDG.Actions:Register{ name = "UI_FILTER_RESET",
    persists = false, combatUnsafe = false,
            invalidates = function(action)
                local tab = action.payload and action.payload.tab
                if tab and tab ~= "" then
                    if tab == "recipes" then
                        -- recipes' expansion + profession filters are persisted in
                        -- account.ui, outside the session.ui.recipes subtree --
                        -- invalidate all three so the dropdowns + run repaint
                        -- after a reset.
                        return { "session.ui.recipes",
                                 "account.ui.recipes.expansionFilter",
                                 "account.ui.recipes.professionFilterByChar" }
                    end
                    return { "session.ui." .. tab }
                end
                return { "session.ui" }  -- fallback: no tab payload -> broad invalidate
            end,
    reduce = function(state, payload)
        -- Atomic per-tab filter reset (ADR-018). Tab-specific logic lives in
        -- the dispatch table below; no new action enum needed for additional tabs.
        local tab = payload.tab
        if tab == "decor" then
            state.session.ui.decor.searchQuery = ""
            state.session.ui.decor.filters     = NewDecorFilters()
            state.session.ui.decor.pinnedSortCounts = nil
        elseif tab == "acquisition" then
            local acq = state.session.ui.acquisition
            acq.searchQuery     = ""
            acq.preset          = nil
            acq.missingOnly     = false
            acq.factionFilter   = {}
            acq.expansionFilter = {}
            acq.zoneFilter      = {}
            acq.repFilter       = {}
            acq.sourceFilter    = {}
        elseif tab == "recipes" then
            local r = state.session.ui.recipes
            r.searchQuery         = ""
            r.listFilter          = "all"
            r.filters             = NewRecipesFilters()
            -- expansionFilter is account-wide: clear in-place -> all expansions.
            wipe(state.account.ui.recipes.expansionFilter)
            -- professions are per-character: drop this char's entry so it reverts to
            -- the pristine default (= this character's professions).
            state.account.ui.recipes.professionFilterByChar[state.session.identity.charKey] = nil
        end
    end }


HDG.Actions:Register{ name = "STYLES_CURATOR_MOVE",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections",
                                               "session.ui.styles.curator.selectedItems",
                                               "session.ui.styles.curator.selectedCount",
                                               "session.ui.styles.curator.recentUndo" },
    reduce = function(state, payload)
        -- Move every currently-selected item from the active source to
        -- the named target collection. payload.targetID overrides the
        -- session-selected target so legacy callers (click-target-to-move)
        -- still work; spec-aligned callers (explicit Move button) just
        -- read selectedTargetID. Source-tracking + undo recording happens
        -- here so the undo case can fully reverse without requiring the
        -- controller to thread payload data through.
        local cur = state.session.ui.styles.curator
        local targetID = payload.targetID or cur.selectedTargetID
        local sourceMode = cur.sourceMode
        local isCopy = payload.copy and true or false   -- Copy = add to target, keep in source
        local target = targetID and state.account.collections[targetID]
        if not target then return end
        target.items = target.items or {}

        -- Source collection (when sourceMode is "style:<id>"); nil for
        -- "unassigned" or "all" -- those modes only ADD to the target.
        -- Copy never removes from source either, regardless of mode.
        local sourceID, sourceColl
        if not isCopy and type(sourceMode) == "string" and sourceMode:sub(1, 6) == "style:" then
            sourceID = sourceMode
            sourceColl = state.account.collections[sourceID]
        end

        local movedIDs = {}
        for itemID in pairs(cur.selectedItems) do
            -- Add to target (dedupe).
            local exists = false
            for _, id in ipairs(target.items) do
                if id == itemID then exists = true; break end
            end
            if not exists then
                target.items[#target.items + 1] = itemID
            end
            -- Remove from source if any (move only; copy leaves sourceColl nil).
            if sourceColl and sourceColl.items then
                for i, id in ipairs(sourceColl.items) do
                    if id == itemID then
                        table.remove(sourceColl.items, i)
                        break
                    end
                end
            end
            movedIDs[#movedIDs + 1] = itemID
        end
        -- Record an undo entry (capped to 20; older entries silently drop).
        -- Copy records from=nil so undo only pulls the items back out of the
        -- target (nothing was removed from a source to restore).
        local undo = cur.recentUndo
        undo[#undo + 1] = {
            action   = isCopy and "copy" or "move",
            from     = sourceID,    -- nil for copy, and for Unassigned / All source
            to       = targetID,
            items    = movedIDs,
            ts       = (_G.time and _G.time()) or 0,
        }
        while #undo > 20 do table.remove(undo, 1) end
        -- Clear selection after a successful move.
        cur.selectedItems = {}
        cur.selectedCount = 0
    end }

HDG.Actions:Register{ name = "STYLES_PLACED_DECOR_OBSERVED_BATCH",
    persists = false, combatUnsafe = false,
    retainsScroll = true,  -- one piece changed in place; a grid that resets to the top loses the player's place mid-placement (Discord 2026-09-06)
    invalidates = { "session.styles.placedDecor", "session.styles.currentArea" },
    reduce = function(state, payload)
        -- Bulk variant used by HousingObserver to coalesce the
        -- HOUSING_DECOR_CUSTOMIZATION_CHANGED burst on edit-mode entry
        -- (~N events in one frame). One reducer pass writes all entries,
        -- one invalidation, one subscriber fan-out -- vs N dispatches in
        -- the unbatched path.
        --
        -- Bulk fills (edit-mode entry) re-enumerate already-placed decor;
        -- they shouldn't reset placedAt (these aren't "new" placements).
        -- The dispatcher sets payload.bulkFill=true so we preserve existing
        -- placedAt timestamps; only assign a fresh placedAt for GUIDs we
        -- haven't seen before this session.
        local now = time()
        local map = state.session.styles.placedDecor
        for _, e in ipairs(payload.entries) do
            local guid = e.decorGUID
            if guid then
                local existing = map[guid]
                map[guid] = {
                    decorGUID = guid,
                    decorID   = e.decorID,
                    areaID    = e.areaID,
                    itemID    = e.itemID,
                    name      = e.name,
                    placedAt  = (existing and existing.placedAt) or now,
                }
                -- Last burst wins: entering an area re-bursts that area, so the
                -- final entry of the batch names where the player now is.
                --
                -- CAVEAT (review 2026-08-23, NOT fully closed): batch order is Blizzard's
                -- event order, not a statement about where the player stands, and a burst
                -- can carry decor from several areas including neighbouring plots. The
                -- dispatcher now refuses to retarget while the player is not in an owned
                -- house or on an owned plot (HousingObserver stamps payload.ownedContext),
                -- which stops a neighbour's plot hijacking the view from outside. It does NOT settle the
                -- case where a mixed burst arrives while you ARE inside your own house --
                -- areaID is parsed from the decor GUID and no API answers "which area am I
                -- in", so closing that needs a live probe of what a real burst contains.
                if e.areaID and payload.ownedContext ~= false then
                    state.session.styles.currentArea = e.areaID
                end
            end
        end
    end }

HDG.Actions:Register{ name = "COLLECTION_STYLE_ITEM_ADDED",
    persists = true,  combatUnsafe = false,
            retainsScroll = true,  -- mid-curate item move; don't yank user to top
            invalidates = function(action)
                local id = action.payload and action.payload.collectionID
                if id then
                    return { P.Join("account.collections", id, "items") }
                end
                return { "account.collections" }
            end,
    reduce = function(state, payload)
        -- Membership write -- adds itemID to collection.items if not present.
        -- 14.0 scaffold: writes through to account.collections directly;
        -- 14.3 (Curator) consumes this when the Move action lands.
        local coll = payload.collectionID and state.account.collections
                     and state.account.collections[payload.collectionID]
        if coll and payload.itemID then
            coll.items = coll.items or {}
            local already = false
            for _, id in ipairs(coll.items) do
                if id == payload.itemID then already = true; break end
            end
            if not already then coll.items[#coll.items + 1] = payload.itemID end
        end
    end }

-- Append " (2)" / " (3)" ... to a list name that already exists, so the
-- switcher dropdown never shows two indistinguishable entries.
local function _uniqueShoppingListName(lists, name, exceptID)
    name = (type(name) == "string" and name ~= "" and name) or "Imported list"
    local taken = {}
    for id, list in pairs(lists) do
        if id ~= exceptID and list.name then taken[list.name] = true end
    end
    if not taken[name] then return name end
    local n = 2
    while taken[name .. " (" .. n .. ")"] do n = n + 1 end
    return name .. " (" .. n .. ")"
end

HDG.Actions:Register{ name = "SHOPPING_LIST_IMPORT",
    persists = true, combatUnsafe = false,
            invalidates = { "account.vendorShoppingLists", "account.activeShoppingListId",
                            "account.shoppingListSeq" },
    reduce = function(state, payload)
        -- HDG.ShoppingCodec.Decode returns a sanitized list record or nil
        -- on garbage / format-mismatch / wrong magic header. Strict call --
        -- ShoppingCodec is TOC-load-order guaranteed (Modules/ loads before
        -- any user-driven action fires).
        local decoded = HDG.ShoppingCodec.Decode(payload.encoded)
        if decoded then
            local lists = state.account.vendorShoppingLists
            -- Re-import of the SAME source collection (matched by meta.url) replaces
            -- that list in place -- keeps its id so it stays active/selected -- rather
            -- than stacking an indistinguishable duplicate. A genuinely different list
            -- that happens to share a name is auto-numbered instead.
            local url = decoded.meta and decoded.meta.url
            local existingID
            if url and url ~= "" then
                for id, list in pairs(lists) do
                    if list.meta and list.meta.url == url then existingID = id; break end
                end
            end
            if existingID then
                -- Exclude the list we're replacing from the name-collision check
                -- (its own old name shouldn't force a "(2)"), but still number if
                -- the re-import's name now clashes with a DIFFERENT list.
                decoded.name = _uniqueShoppingListName(lists, decoded.name, existingID)
                lists[existingID] = decoded
                state.account.activeShoppingListId = existingID
            else
                decoded.name = _uniqueShoppingListName(lists, decoded.name)
                state.account.shoppingListSeq = state.account.shoppingListSeq + 1
                local id = "L" .. tostring(state.account.shoppingListSeq)
                lists[id] = decoded
                state.account.activeShoppingListId = id
            end
        end
    end }

HDG.Actions:Register{ name = "UI_SET_VIEW",
    persists = false, combatUnsafe = false, 
    invalidates = { "session.ui.view" },
    reduce = function(state, payload)
        state.session.ui.view = payload.view   -- dispatcher bug if nil; fail loud

    -- ===== Projects: house topology ==========================================
    -- Payload-key guards: missing key no-ops rather than indexing nil (payload is the input boundary).
    end }

-- Curator undo: ONE body, two entry points (the chain's only multi-type
-- branch). UNDO pops the top entry; UNDO_AT pops payload.ord. The old
-- chain's early `return`s skipped notify; block returns no-op-notify
-- instead (benign: no state change, identical repaint).
-- Remove the first occurrence of `value` from array `list` (no-op if absent).
local function _listRemoveValue(list, value)
    for i, v in ipairs(list) do
        if v == value then table.remove(list, i); return end
    end
end

-- Append `value` to array `list` only if not already present.
local function _listAddUnique(list, value)
    for _, v in ipairs(list) do
        if v == value then return end
    end
    list[#list + 1] = value
end

local function _curatorUndoAt(state, ord)
        -- Reverse a single move from the stack.
        -- UNDO     -> pops the topmost entry ("Undo last move" button).
        -- UNDO_AT  -> pops the entry at payload.ord (per-row click in the
        --             RECENT (UNDO) panel).
        -- "from" may be nil (Unassigned source) -- in which case removal
        -- from target is sufficient to put items back in the unassigned set.
        -- Note: undoing an old entry while newer entries above it remain
        -- can leave the moved items in multiple style memberships if the
        -- items were re-moved by those newer entries. That's intentionally
        -- self-recoverable -- the user can resolve via another targeted
        -- undo. The alternative (cascade-undo to clicked row) was felt
        -- to lose user intent ("I clicked ONE row, why did 4 actions undo?").
        local cur = state.session.ui.styles.curator
        local collections = state.account.collections
        if ord < 1 or ord > #cur.recentUndo then return end

        local entry = cur.recentUndo[ord]
        table.remove(cur.recentUndo, ord)
        local target = entry.to and collections[entry.to]
        local source = entry.from and collections[entry.from]
        if target and target.items then
            for _, itemID in ipairs(entry.items or {}) do _listRemoveValue(target.items, itemID) end
        end
        if source then
            source.items = source.items or {}
            for _, itemID in ipairs(entry.items or {}) do _listAddUnique(source.items, itemID) end
        end

    -- ===== 14.4 Smart Set Builder ===========================================
end

HDG.Actions:Register{ name = "STYLES_CURATOR_UNDO",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections",
                                               "session.ui.styles.curator.recentUndo" },
    reduce = function(state, payload)
        _curatorUndoAt(state, #state.session.ui.styles.curator.recentUndo)
    end }

HDG.Actions:Register{ name = "STYLES_CURATOR_UNDO_AT",
    persists = false, combatUnsafe = false, 
    invalidates = { "account.collections",
                                               "session.ui.styles.curator.recentUndo" },
    reduce = function(state, payload)
        local ord = payload and payload.ord
        if type(ord) ~= "number" then return end
        _curatorUndoAt(state, ord)
    end }

-- ===== Resolvers (species A facade-poll + species D markers) ==================
-- Registry: Core/HDGR_Resolvers.lua; taxonomy: Lattice/docs/TICK_REVALIDATION_
-- 2026-06-11.md. Each block mints session.resolvers.<name>.tick and registers
-- the action(s) that signal "the facade's world changed -- re-pull". The
-- facade field is the selector-visible module the sweep cross-checks reads
-- against (scripts/semantic_sweep.lua rule 4c).

-- Bag counts. Data lives in HDG.BagObserver._counts (ADR-003a inside-closure
-- deterministic-module-read carve-out); BagObserver dispatches after each
-- debounced bag scan, passing its own scan counter as the tick value.
HDG.Resolver:Register{ name = "bag", facade = "BagObserver",
    actions = {
        { name = "BAG_INVENTORY_UPDATED",
          bump = function(cur, payload) return payload.tick or (cur + 1) end },
    } }

-- Quest completion. QuestNameResolver:IsComplete reads live quest APIs;
-- bumped on QUEST_TURNED_IN so [QUST] checkmarks repaint live. Method-scoped:
-- IsComplete is the completion facade on the (shared) QuestNameResolver module.
HDG.Resolver:Register{ name = "questStatus",
    facade = { module = "QuestNameResolver", method = "IsComplete" },
    actions = { { name = "QUEST_STATUS_RESOLVED" } } }

-- Achievement earned. HDG.AchievementObserver:IsEarned reads the live API;
-- bumped on ACHIEVEMENT_EARNED so [ACH] checkmarks repaint live. Earned state
-- is dynamic per-character; NOT baked at catalog sweep.
HDG.Resolver:Register{ name = "achievementStatus", facade = "AchievementObserver",
    actions = { { name = "ACHIEVEMENT_STATUS_RESOLVED" } } }

-- Reputation progress. HDG.RepObserver:GetProgress reads live faction APIs;
-- bumped (debounced) on UPDATE_FACTION / renown change.
HDG.Resolver:Register{ name = "rep", facade = "RepObserver",
    actions = {
        { name = "REP_PROGRESS_TICK",
          noisy = true },  -- UPDATE_FACTION fires in bursts (debounced, but still chatty)
    } }

-- Decor-attachable pets. Data lives in HDG.PetObserver's module index, rebuilt
-- from C_PetJournal.GetOwnedPetIDs -- the filter-free enumeration. noisy because
-- PET_JOURNAL_LIST_UPDATE arrives in bursts at login and on every cage/learn;
-- the observer debounces, this just keeps the log quiet about it.
HDG.Resolver:Register{ name = "pets", facade = "PetObserver",
    actions = {
        { name = "PETS_LIST_CHANGED", noisy = true },
        -- Same resolver: the summon state and the pet list are both read through
        -- PetObserver, so one tick covers both. Re-running the row list on a
        -- summon is cheap and keeps a single re-pull signal for the facade.
        { name = "PETS_SUMMONED_CHANGED" },
    } }

-- Housing catalog. Data lives in HDG.HousingCatalogObserver's module index
-- (byItemID + counts, mutated in place by RemoveRow/PatchCounts). The tick
-- VALUE is the observer's sweep generation, stamped by the load/refresh
-- lifecycle actions; the row-patch signals invalidate the path WITHOUT
-- writing it (bump = false -- path invalidation re-runs subscribed selectors;
-- the generation only advances per completed sweep, preserving the
-- pre-registry sweepGeneration semantics).
HDG.Resolver:Register{ name = "catalog", facade = "HousingCatalogObserver",
    actions = {
        { name = "DECOR_CATALOG_READY",                   bump = false },
        -- retainsScroll: a per-row patch re-pushes every grid reading the tick;
        -- resetting them to the top loses the player's place mid-placement.
        { name = "COLLECTION_CATALOG_ROW_ADDED",          bump = false, retainsScroll = true },
        { name = "COLLECTION_CATALOG_ROW_COUNTS_UPDATED", bump = false, retainsScroll = true },
        { name = "COLLECTION_CATALOG_ROW_REMOVED",        bump = false,
          invalidates = { "account.collection.ownedDecorIDs" },
          -- Observer calls RemoveRow on its index; reducer only scrubs
          -- ownedDecorIDs for consistency.
          reduce = function(state, payload)
              if payload.decorID then
                  state.account.collection.ownedDecorIDs[payload.decorID] = nil
              end
          end },
        { name = "CATALOG_LOAD_COMPLETED",
          invalidates = { "session.catalog", "session.catalog.refreshPending" },
          bump = function(cur, payload) return payload.generation end,
          reduce = function(state, payload)
              local c = state.session.catalog
              c.status      = "ready"
              c.loadedAt    = payload.loadedAt   -- dispatcher stamps GetTime() before dispatch
              c.itemCount   = payload.itemCount
              c.vendorCount = payload.vendorCount
              -- Clear pending on any successful sweep; without this, refreshPending
              -- stays true and every tab switch triggers a full re-sweep.
              c.refreshPending = false
          end },
        { name = "CATALOG_REFRESH_COMPLETED",
          invalidates = { "session.catalog" },
          bump = function(cur, payload) return payload.generation or (cur + 1) end,  -- exception(boundary): generation is optional
          reduce = function(state, payload)
              state.session.catalog.refreshPending = false
          end },
    } }

-- Static shipped data (species D -- dependency MARKER, never bumped). The
-- TOC-shipped tables behind HDG.StaticData are IMMUTABLE within a session;
-- selectors declare the read so shipped-data deps flow through read-tracking
-- like any state path (ADR-003c). Reserved for hot-reload / dev-tool override.
-- Recipe acquisition text. ProfessionScanner:GetRecipeSource reads the live
-- (undocumented) C_TradeSkillUI.GetRecipeSourceText and parses it.
--
-- STATIC (species D marker, tick stays 0): the getter is synchronous and answers
-- cold, so the first read already has the answer and nothing arrives later to
-- repaint for. Registering it with a bump action instead meant a dispatch per
-- newly-seen recipe from inside a paint -- the 3.31.0 lag. The marker still
-- exists so selectors declare the dependency and the sweep's facade cross-check
-- keeps working.
HDG.Resolver:RegisterStatic{ name = "recipeSource",
    facade = { module = "ProfessionScanner", method = "GetRecipeSource" } }

HDG.Resolver:RegisterStatic{ name = "staticData", facade = "StaticData" }

-- Prices (the species A+B hybrid, split per TICK_REVALIDATION). A-side: the
-- external TSM/Auctionator facades + which source/mode is preferred -- these
-- four actions change what the facade RETURNS without touching price data,
-- so they bump the resolver tick. B-side: the direct-scan caches + owned
-- auctions are account.prices.* STATE -- those actions invalidate their data
-- paths only, and price-consuming selectors declare account.prices (prefix)
-- alongside this tick. Goblin computes through PriceSource, so both modules
-- carry the same contract.
HDG.Resolver:Register{ name = "prices",
    facade   = { "PriceSource", "Goblin" },
    requires = { "account.prices" },
    actions  = {
        { name = "PRICES_CONFIG_CHANGED" },  -- pure signal; config write rides CONFIG_SET
        { name = "PRICES_SET_PREFERRED_SOURCE", persists = true,
          invalidates = { "account.config.preferredPriceAddon" },
          -- Config write + resolver bump in one pass (two dispatches would
          -- cost two reducer runs).
          reduce = function(state, payload)
              state.account.config.preferredPriceAddon = payload.source
          end },
        { name = "PRICES_SET_TSM_MODE", persists = true,
          invalidates = { "account.config.tsmPriceMode" },
          reduce = function(state, payload)
              state.account.config.tsmPriceMode = payload.mode
          end },
        { name = "PRICES_ADDONS_AVAILABILITY_CHANGED",
          invalidates = { "session.prices.tsmLoaded", "session.prices.auctionatorLoaded" },
          reduce = function(state, payload)
              local s = state.session.prices
              s.tsmLoaded         = payload.tsm         == true
              s.auctionatorLoaded = payload.auctionator == true
          end },
    } }

-- Item names (dissolved species B): the data is STATE -- the reducer-written
-- session.itemNames.names cache -- so there is no resolver tick; consumers
-- read the data path and ITEM_INFO_RESOLVED invalidates it directly. This
-- contract makes the sweep enforce that read on every ItemNameResolver
-- caller (ResolveName Peeks the cache before re-querying Blizzard).
HDG.Resolver:RegisterFacadeReads{ facade = "ItemNameResolver",
    requires = { "session.itemNames.names" } }
