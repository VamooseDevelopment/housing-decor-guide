-- HDG.StaticData
-- ============================================================================
-- Facade for build-pipeline-generated data tables shipped in TOC-loaded Lua
-- files (immutable within a session). See ADR-003c.
--
-- Rules:
--   1. Selectors call HDG.StaticData.<Domain>:<accessor>() -- never _G.HDGR_*DB directly.
--   2. Selectors declare reads = {"session.resolvers.staticData.tick"} (always 0 today;
--      reserves space for future hot-reload override).
--   3. Tests stub HDG.StaticData.<Domain> to inject fixtures.
--
-- Wrapped tables (all loaded via TOC before this module):
--   HDGR_VendorAugment         -> VendorAugment:Get / ResolveName / GetVendorsByMap
--   HDGR_ItemAugment           -> ItemAugment:Get  (sparse; rep gates + sourceType)
--   HDGR_DecorDB               -> Recipes:Get / GetAll  (recipe-backed subset)
--   HDGR_ProfessionsDB         -> Professions:VisitAll  (packed; decoded on read)
--   HDGR_ProfessionQualityGroups -> Professions:GetQualityVariants
--   HDGR_ProfessionThresholds  -> Professions:GetThresholds
--   HDGR_ReagentsDB            -> Reagents:Get / GetAll
--   HDGR_FacetDB               -> Facets:Get / GetAll
--   HDGR_FacetVocab            -> Facets:GetVocab
--   HDGR_FacetAxes             -> Facets:GetAxes
--   HDGR_PetSizeDB             -> PetSizes:Get  (sparse; nil = never measured)
--   HDGR_StyleDefinitions      -> Styles:GetDefinitions
--   HDGR_CollectionDefinitions -> Collections:GetDefinitions
--   HDGR_TrainersDB            -> Trainers:GetAll / GetByProfession / GetByProfessionAndExpansion
--   HDGR_HouseTab_TitleTiers     -> TitleTiers:GetAll
--   HDGR_HouseTab_WidgetDefaults -> WidgetDefaults:GetAll
--   HDGR_ExpansionData         -> Expansions:GetAll  (also in HDG.Constants)
--   HDGR_SchemeMeta            -> Schemes:GetMeta

HDG = HDG or {}
HDG.StaticData = HDG.StaticData or {}

local S = HDG.StaticData

-- Tiny helper. Fail loud on missing data file (TOC misconfiguration / load
-- order error) rather than returning empty tables that silently produce
-- "vendor not found" / "decor not in catalog" UI states.
local function _table(globalName)
    local t = _G[globalName]
    if type(t) ~= "table" then
        error("HDG.StaticData: _G." .. globalName .. " missing or not a table "
              .. "(got " .. type(t) .. "). Is the data file in <Addon>.toc "
              .. "before HDGR_StaticData.lua?", 2)
    end
    return t
end

-- ============================================================================
-- VendorAugment  (HDGR_VendorAugment)
-- ============================================================================
---@class HDG.StaticData.VendorAugment
S.VendorAugment = S.VendorAugment or {}
-- Built on first use (_EnsureIndexes), not at login: the first reader is the catalog
-- sweep on the first Decor open.
S.VendorAugment._byName = nil
S.VendorAugment._byMapID = nil

function S.VendorAugment:Get(npcID)
    local t = _table("HDGR_VendorAugment")  -- exception(boundary): _table fails loud if HDGR_VendorAugment DB missing
    return t[npcID]
end

function S.VendorAugment:ResolveName(name, zone)
    self:_EnsureIndexes()
    if zone then
        -- Try "Name/Zone" form first, then "Name (Zone)" curator form
        local r = self._byName[name .. "/" .. zone]
                  or self._byName[name .. " (" .. zone .. ")"]
        if r then return r end
    end
    return self._byName[name]
end

function S.VendorAugment:GetVendorsByMap(mapID)
    self:_EnsureIndexes()
    return self._byMapID[mapID]
end

function S.VendorAugment:_EnsureIndexes()
    if self._byName then return end
    local byName, byMapID = {}, {}
    local t = _table("HDGR_VendorAugment")
    -- Iterate npcIDs in SORTED order, not pairs() order. "First occurrence wins
    -- the unqualified name" is only a meaningful rule if "first" is stable, and
    -- LuaJIT varies pairs() order per PROCESS -- so with 16 names now living in
    -- two housing neighborhoods, an unzoned ResolveName could answer with a
    -- different npcID on each login. Sorting makes the winner the same every
    -- session and keeps byMapID's per-map order stable for the Zone Scanner.
    local ids = {}
    for npcID in pairs(t) do ids[#ids + 1] = npcID end
    table.sort(ids)
    for _, npcID in ipairs(ids) do
        local v = t[npcID]
        -- Name index. EVERY row gets its zone-qualified keys, not just collisions --
        -- the first row used to get the bare name alone, so ResolveName(name, zone)
        -- MISSED for it and fell through to the unqualified fallback, quietly answering
        -- with whichever npcID sorted lowest. With a vendor in both housing
        -- neighborhoods that meant the pane showed the wrong zone AND the wrong coords
        -- to a player standing next to the right one (2026-08-24).
        -- First occurrence still wins the bare name, so the zone-less fallback is
        -- unchanged for the single-zone majority.
        byName[v.name .. "/" .. v.zone]         = byName[v.name .. "/" .. v.zone] or npcID
        byName[v.name .. " (" .. v.zone .. ")"] = byName[v.name .. " (" .. v.zone .. ")"] or npcID
        if not byName[v.name] then byName[v.name] = npcID end
        -- Base-name index: curator names use "Name (Zone)" but the housing
        -- catalog reports the bare in-game name. Key base name by zone so a
        -- bare catalog name resolves to the right npcID (additive, never
        -- overrides an exact-name key).
        local base = v.name:gsub("%s*%b()%s*$", "")
        if base ~= v.name and base ~= "" then
            byName[base .. "/" .. v.zone]         = byName[base .. "/" .. v.zone] or npcID
            byName[base .. " (" .. v.zone .. ")"] = byName[base .. " (" .. v.zone .. ")"] or npcID
            if not byName[base] then byName[base] = npcID end
        end
        -- MapID index: list of vendors per mapID
        if v.mapID then
            byMapID[v.mapID] = byMapID[v.mapID] or {}
            table.insert(byMapID[v.mapID], npcID)
        end
    end
    self._byName = byName
    self._byMapID = byMapID
end

-- ============================================================================
-- StaticData.ItemAugment  (HDGR_ItemAugment)
-- Sparse itemID-keyed augments: rep gates, sourceType, altSourceType.
-- ============================================================================
---@class HDG.StaticData.ItemAugment
S.ItemAugment = S.ItemAugment or {}

function S.ItemAugment:Get(itemID)
    local t = _table("HDGR_ItemAugment")
    return t[itemID]
end

-- ============================================================================
-- StaticData.CatalogOverrides  (HDGR_CatalogOverrides)
-- itemID-keyed field-level overrides applied at BuildRow time; corrects
-- known-wrong catalog fields. Sparse; populated reactively on user reports.
-- ============================================================================
---@class HDG.StaticData.CatalogOverrides
S.CatalogOverrides = S.CatalogOverrides or {}

function S.CatalogOverrides:Get(itemID)
    local t = _table("HDGR_CatalogOverrides")
    return t[itemID]
end

-- ============================================================================
-- Recipes  (HDGR_DecorDB -- recipe-backed decor only; subset of Decor)
-- ============================================================================

---@class HDG.StaticData.Recipes
S.Recipes = S.Recipes or {}

-- HDGR_DecorDB keyed by spell/recipe ID; `itemID` inside each entry.
-- Two O(1) reverse indexes built lazily on first use (invalidated when the
-- DB table reference changes):
--   _byItemIDCache  itemID -> entry            (:Get)
--   _byNpcCache     npcID  -> { entries sold } (:GetBySourceNpcID, covers recipe-only vendors)
local _byItemIDCache, _byNpcCache, _cachedSource
local function _ensureRecipeIndexes()
    local db = _table("HDGR_DecorDB")
    if _cachedSource == db then return end
    _byItemIDCache, _byNpcCache = {}, {}
    for _, entry in pairs(db) do
        if entry.itemID then _byItemIDCache[entry.itemID] = entry end
        local rs = entry.recipeSource
        if rs and rs.type == "vendor" and rs.vendors then  -- exception(boundary): recipeSource optional + multi-typed
            for _, v in ipairs(rs.vendors) do
                local list = _byNpcCache[v.npcID] or {}
                list[#list + 1] = entry
                _byNpcCache[v.npcID] = list
            end
        end
    end
    _cachedSource = db
end

-- Cross-source gap check: recipe vendors absent from VendorAugment lose
-- name/zone/coords downstream (acq.allVendors skips them; Trainers Midnight
-- rows keep "--" placeholders). PURE -- returns (count, sample-of-8); the
-- caller logs (RecipeKnowledgeScanner post-scan). This facade stays log-free
-- so partial test fixtures can load it bare, and selectors stay pure by
-- skipping silently instead of warning per recompute.
function S.Recipes:VendorAugmentGaps()
    _ensureRecipeIndexes()
    local aug = _table("HDGR_VendorAugment")  -- exception(boundary): fails loud if the DB file is missing
    local missing, n = {}, 0
    for npcID in pairs(_byNpcCache) do
        if not aug[npcID] then
            n = n + 1
            if n <= 8 then missing[n] = tostring(npcID) end
        end
    end
    return n, missing
end

function S.Recipes:Get(itemID)
    if not itemID then return nil end
    _ensureRecipeIndexes()
    return _byItemIDCache[itemID]
end

-- npcID -> array of recipe entries the vendor sells, or nil.
function S.Recipes:GetBySourceNpcID(npcID)
    if not npcID then return nil end
    _ensureRecipeIndexes()
    return _byNpcCache[npcID]
end

-- npcID -> count of recipes the vendor sells. Drives the acq.allVendors union
-- (recipe-only quartermasters) + the vendor header recipe count.
function S.Recipes:RecipeVendorCounts()
    _ensureRecipeIndexes()
    local out = {}
    for npcID, list in pairs(_byNpcCache) do out[npcID] = #list end
    return out
end

function S.Recipes:GetAll()
    return _table("HDGR_DecorDB")
end

-- Reverse index: reagent itemID -> array of decor recipe itemIDs that use it.
-- Powers the "Used in N decor recipes" reagent tooltip line. Lazy; rebuilt when the
-- DB table reference changes (same pattern as _byItemIDCache).
local _reagentUsersCache, _reagentUsersSource
local function _ensureReagentUsers()
    local db = _table("HDGR_DecorDB")
    if _reagentUsersSource == db then return end
    _reagentUsersCache, _reagentUsersSource = {}, db
    for _, entry in pairs(db) do
        if entry.itemID and entry.reagents then
            for rid in pairs(entry.reagents) do
                local list = _reagentUsersCache[rid] or {}
                list[#list + 1] = entry.itemID
                _reagentUsersCache[rid] = list
            end
        end
    end
end

-- Decor recipe itemIDs that use this exact reagent itemID (nil if none). The
-- caller unions across quality-variant siblings (a tiered reagent's recipes list
-- one tier; the player may hold another) -- keeps this facade DecorDB-only.
function S.Recipes:RecipesUsingReagent(reagentItemID)
    if not reagentItemID then return nil end
    _ensureReagentUsers()
    return _reagentUsersCache[reagentItemID]
end

-- Walk a DecorDB entry's direct reagents, mirroring Professions:VisitBasicSlots so the
-- decor recipe path (queue/materials/lumber/tooltip) can read DecorDB instead of
-- ProfessionsDB. visitor({ itemID, qty, name }); a truthy return stops early. DecorDB
-- has no non-basic slots, so there is no `type` filter. Reagents are pairs()-iterated
-- (unordered) -- fine for the commutative accumulators + any-match early-stop consumers.
function S.Recipes:VisitReagents(entry, visitor)
    if not (entry and entry.reagents) then return end
    for itemID, info in pairs(entry.reagents) do
        if visitor({ itemID = itemID, qty = info.qty, name = info.name }) then return end
    end
end

-- ============================================================================
-- Professions  (HDGR_ProfessionsDB by itemID + HDGR_ProfessionQualityGroups +
--               HDGR_ProfessionThresholds)
-- ============================================================================

---@class HDG.StaticData.Professions
S.Professions = S.Professions or {}

-- Each recipe ships as one string (build_pruned_professions.lua; as tables they
-- held 1.7 MB from login, memory plan 2026-10-19 S2):
--   name^recipeID^categoryName^outputQtyMin^slot~slot~...
--   slot = kind,qty,itemID[,name]     kind: b = basic, f = finishing, m = modifying
-- The key is the itemID; an absent field is empty. Decoded records are cached
-- weakly: the craft graph holds the ones in use, and the rest go back to the
-- collector.
local SLOT_TYPE = { b = "basic", f = "finishing", m = "modifying" }
local _records, _recordsSource

local function _decodeSlot(text)
    local kind, qty, itemID, name = text:match("^(%a),(%d+),(%d+),?(.*)$")
    return { type = SLOT_TYPE[kind], qty = tonumber(qty), itemID = tonumber(itemID),
             name = name ~= "" and name or nil }
end

local function _decodeRecord(itemID, packed)
    local name, recipeID, categoryName, outputQtyMin, slotText =
        packed:match("^([^^]*)%^(%d+)%^([^^]*)%^(%d*)%^(.*)$")
    assert(name, "HDG.StaticData: malformed HDGR_ProfessionsDB record " .. tostring(itemID))
    local slots = {}
    for text in slotText:gmatch("[^~]+") do slots[#slots + 1] = _decodeSlot(text) end
    return { name = name, recipeID = tonumber(recipeID), itemID = itemID,
             categoryName = categoryName ~= "" and categoryName or nil,
             outputQtyMin = tonumber(outputQtyMin), slots = slots }
end

-- The decoded record for one packed entry. The cache follows the table so a
-- swapped global (tests) never serves the old one's records.
local function _record(db, itemID, packed)
    if _recordsSource ~= db then
        _records, _recordsSource = setmetatable({}, { __mode = "v" }), db
    end
    local rec = _records[itemID]
    if not rec then
        rec = _decodeRecord(itemID, packed)
        _records[itemID] = rec
    end
    return rec
end

-- visitor(itemID, record) for every recipe, decoded; returning truthy stops the walk.
function S.Professions:VisitAll(visitor)
    local db = _table("HDGR_ProfessionsDB")
    for itemID, packed in pairs(db) do
        if visitor(itemID, _record(db, itemID, packed)) then return end
    end
end

-- The decoded recipe that makes itemID, or nil when nothing in the seed does.
function S.Professions:Get(itemID)
    local db = _table("HDGR_ProfessionsDB")
    local packed = db[itemID]  -- exception(nullable): gathered and vendor reagents have no recipe
    if not packed then return nil end
    return _record(db, itemID, packed)
end

-- name, categoryName, outputQtyMin of the recipe that makes itemID, read off its
-- packed string without decoding the slots; nothing when the seed has no recipe.
-- The craft graph's capture overlay wants only these from the record it replaces.
function S.Professions:GetHeader(itemID)
    local packed = _table("HDGR_ProfessionsDB")[itemID]  -- exception(nullable): a captured recipe the seed does not ship
    if not packed then return nil end
    local name, categoryName, outputQtyMin = packed:match("^([^^]*)%^%d+%^([^^]*)%^(%d*)%^")
    assert(name, "HDG.StaticData: malformed HDGR_ProfessionsDB record " .. tostring(itemID))
    return name, categoryName ~= "" and categoryName or nil, tonumber(outputQtyMin)
end

function S.Professions:GetThresholds()
    return _table("HDGR_ProfessionThresholds")
end

-- Quality siblings: tiered reagents have separate itemIDs per quality tier, and
-- any tier satisfies a slot, so material counting sums the whole group. Returns
-- { otherSiblingID, ... } or nil. The seed's groups are precomputed by the
-- generator (HDGR_ProfessionQualityGroups): bag counting asks at login, and
-- deriving them from the recipes would decode every one.
function S.Professions:GetQualityVariants(itemID)
    if not itemID then return nil end
    -- Captured quality groups win: the profession-book scan records the LIVE tier
    -- siblings (account.reagentVariants), covering new 12.1 tiered reagents the
    -- seed's frozen groups can't know. DELIBERATE ADR-003c deviation: this one
    -- accessor reads live Store state, so the facade is no longer "immutable within
    -- a session" here (addendum in HDGR_ARCHITECTURE.md; all four consumers are modules).
    local captured = HDG.Store:GetState().account.reagentVariants[itemID]  -- exception(nullable): most reagents aren't tiered
    if captured then return captured end
    return _table("HDGR_ProfessionQualityGroups")[itemID]  -- exception(nullable): most reagents aren't tiered
end

-- Walk basic-typed slots on a recipe. visitor(slot) called per slot;
-- returning truthy stops the walk early. No-op on nil recipe or no slots.
function S.Professions:VisitBasicSlots(recipe, visitor)
    if not (recipe and recipe.slots) then return end
    for _, slot in ipairs(recipe.slots) do
        if slot.type == "basic" then
            if visitor(slot) then return end
        end
    end
end

-- ============================================================================
-- Reagents  (HDGR_ReagentsDB -- crafting reagent metadata)
-- ============================================================================

---@class HDG.StaticData.Reagents
S.Reagents = S.Reagents or {}

-- source, name for a reagent, or nil. source is "Gathering", "Crafted", "Drop",
-- "Vendor" or "Vendor:<copper>"; name is the baked English placeholder. Each entry
-- ships as one "source|name" string (build_reagents.lua; as two-field tables they
-- held ~0.75 MB, memory census 2026-10-19).
function S.Reagents:Get(itemID)
    if not itemID then return nil end
    local packed = _table("HDGR_ReagentsDB")[itemID]  -- exception(nullable): not every item is a reagent
    if not packed then return nil end
    return packed:match("^([^|]*)|(.*)$")
end

-- Every reagent itemID as the keys; read an entry through Get, never the value.
function S.Reagents:GetAll()
    return _table("HDGR_ReagentsDB")
end

-- ============================================================================
-- Facets  (HDGR_FacetDB + HDGR_FacetVocab for styles tab)
-- ============================================================================

---@class HDG.StaticData.Facets
S.Facets = S.Facets or {}

-- A record is a byte string, laid out by HDGR_FacetAxes (see GetAxes).
function S.Facets:Get(itemID)
    if not itemID then return nil end
    return _table("HDGR_FacetDB")[itemID]
end

function S.Facets:GetAll()
    return _table("HDGR_FacetDB")
end

function S.Facets:GetVocab()
    return _table("HDGR_FacetVocab")
end

-- Axis names in record slot order. In a record, byte k is where axis k's tags
-- start and byte k+1 where they end (exclusive); each tag is one byte, its index
-- in GetVocab()[axis]. Layout written by housingdecorguide-tools/facetdb/export_facetdb.py.
function S.Facets:GetAxes()
    return _table("HDGR_FacetAxes")
end

-- ============================================================================
-- PetSizes  (HDGR_PetSizeDB)
-- ============================================================================
-- Rendered pet height, for the Decor tab's Pets browser. The runtime has no
-- height to offer: GetActiveBoundingBox and CreatureModelData.GeoBox are the
-- same number and union over ANIMATION TRAVEL, so a jumping model reports the
-- volume it moves through. These come from the M2 vertex array instead.

---@class HDG.StaticData.PetSizes
S.PetSizes = S.PetSizes or {}

-- nil for a species that was never measured. A miss is a VALID answer -- callers
-- render the row without a height rather than substituting one, because there is
-- nothing honest to substitute.
function S.PetSizes:Get(speciesID)
    if not speciesID then return nil end
    return _table("HDGR_PetSizeDB")[speciesID]
end

-- ============================================================================
-- Styles  (HDGR_StyleDefinitions)
-- ============================================================================

---@class HDG.StaticData.Styles
S.Styles = S.Styles or {}

function S.Styles:GetDefinitions()
    return _table("HDGR_StyleDefinitions")
end

-- ============================================================================
-- Collections  (HDGR_CollectionDefinitions)
-- ============================================================================

---@class HDG.StaticData.Collections
S.Collections = S.Collections or {}

function S.Collections:GetDefinitions()
    return _table("HDGR_CollectionDefinitions")
end

-- ============================================================================
-- Trainers  (HDGR_TrainersDB -- profession trainer NPCs by profession + expansion)
-- ============================================================================
--
-- Shape: HDGR_TrainersDB[profName][expName][faction] -> trainerRecord OR
--        HDGR_TrainersDB[profName][expName][faction] -> { trainerRecord, ... }
-- Faction key is one of "Alliance" / "Horde" / "Both".
-- trainerRecord fields: npcID, name, location ("Zone [x, y]"), note? (optional)

---@class HDG.StaticData.Trainers
S.Trainers = S.Trainers or {}

function S.Trainers:GetAll()
    return _table("HDGR_TrainersDB")
end

function S.Trainers:GetByProfession(profName)
    if not profName then return nil end
    return _table("HDGR_TrainersDB")[profName]
end

function S.Trainers:GetByProfessionAndExpansion(profName, expName)
    if not profName or not expName then return nil end
    local p = _table("HDGR_TrainersDB")[profName]
    return p and p[expName] or nil
end

-- ============================================================================
-- TitleTiers  (HDGR_HouseTab_TitleTiers -- decorator title ladder)
-- Shape: ordered array of { threshold, name, vamoose? }, ascending threshold.
-- ============================================================================

---@class HDG.StaticData.TitleTiers
S.TitleTiers = S.TitleTiers or {}

function S.TitleTiers:GetAll()
    return _table("HDGR_HouseTab_TitleTiers")
end

-- ============================================================================
-- WidgetDefaults  (HDGR_HouseTab_WidgetDefaults)
-- Shape: ordered array of { id, title, order, width, enabled, defaultHeight }.
-- ============================================================================

---@class HDG.StaticData.WidgetDefaults
S.WidgetDefaults = S.WidgetDefaults or {}

function S.WidgetDefaults:GetAll()
    return _table("HDGR_HouseTab_WidgetDefaults")
end

-- ============================================================================
-- Expansions  (HDGR_ExpansionData -- mirrored in HDG.Constants.EXPANSION_DATA)
-- ============================================================================

---@class HDG.StaticData.Expansions
S.Expansions = S.Expansions or {}

function S.Expansions:GetAll()
    return _table("HDGR_ExpansionData")
end

-- ============================================================================
-- Schemes  (HDGR_SchemeMeta -- theme scheme definitions)
-- ============================================================================

---@class HDG.StaticData.Schemes
S.Schemes = S.Schemes or {}

function S.Schemes:GetMeta()
    return _table("HDGR_SchemeMeta")
end

-- Get a built scheme by name (nil if the name isn't a registered scheme).
function S.Schemes:Get(name)
    return _table("HDGR_SchemeConstants")[name]
end

-- ============================================================================
-- PetFacts  (HDGR_PetTaxonomyDB / PetVoiceDB / PetAnimDB / PetSceneDecorDB / PetSizeDB / PetCantAttachDB)
-- ============================================================================
-- The Menagerie's data facade (HDGR_MENAGERIE_LATTICE_PLAN_2026-08-24 section 1). The
-- raw _G.HDGR_Pet*DB tables are read NOWHERE else; reverse indexes (kind counts,
-- clade counts, voice sharing) build lazily once and rebuild only if the DB
-- table reference changes (test seam -- same idiom as Recipes above).
--
-- Records the Menagerie reads one pet at a time (anim profiles, voices, scene
-- rows) ship as strings and are decoded here on each call, into a fresh table the
-- caller may keep. As nested tables the pet DBs held 4.6 MB (memory census
-- 2026-10-19). Formats: vpp-tools/export_pet_lua.py and build_sizedb.py.

---@class HDG.StaticData.PetFacts
S.PetFacts = S.PetFacts or {}

-- "a,b,c" -> { a, b, c } as numbers; "" -> {}.
local function _numberList(s)
    local out = {}
    for n in s:gmatch("[^,]+") do out[#out + 1] = tonumber(n) end
    return out
end

local _pfKinds, _pfClades, _pfVoiceShare, _pfSource

local function _ensurePetIndexes()
    local db = _table("HDGR_PetTaxonomyDB")
    if _pfSource == db then return end
    _pfKinds, _pfClades, _pfVoiceShare = {}, {}, {}
    for _, row in pairs(db) do
        local kind, clade = row[1], row[2]
        local k = _pfKinds[kind]
        if not k then
            k = { count = 0, clade = clade }
            _pfKinds[kind] = k
        end
        k.count = k.count + 1
        _pfClades[clade] = (_pfClades[clade] or 0) + 1
    end
    for _, voice in pairs(_table("HDGR_PetVoiceDB").species) do
        _pfVoiceShare[voice] = (_pfVoiceShare[voice] or 0) + 1
    end
    _pfSource = db
end

-- kind, clade for a species. nil, nil = species not in the taxonomy (a NEW pet
-- since the last data build) -- a real state the UI shows as "?", never a guess.
function S.PetFacts:Taxonomy(speciesID)
    local row = _table("HDGR_PetTaxonomyDB")[speciesID]  -- exception(nullable): post-build species miss
    if not row then return nil, nil end
    return row[1], row[2]
end

-- Whether a species can ride decor, from DB2 BattlePetSpecies.Flags
-- (CANT_ATTACH_TO_DECOR). The API carries it only on the 20-field pet info
-- table, and reading that once per owned species cost 6.4 MB a first Menagerie
-- visit; the flag matched the API on all 2,999 live species (/petflag,
-- 2026-10-21). nil = a species newer than the data build: ask the game.
function S.PetFacts:CanAttachToDecor(speciesID)
    local db = _table("HDGR_PetCantAttachDB")
    if speciesID > db.maxSpeciesID then return nil end
    return not db.species[speciesID]
end

-- nil = no idle sound recorded (NOT proven-silent; see build_pet_sound.py header).
function S.PetFacts:Voice(speciesID)
    local db = _table("HDGR_PetVoiceDB")
    local voice = db.species[speciesID]  -- exception(nullable): absence means quiet
    if not voice then return nil end
    _ensurePetIndexes()
    local kits, durs = db.voices[voice]:match("^([^|]*)|([^|]*)$")
    local delay = db.delays[speciesID]  -- exception(nullable): only a few voices carry a fidget delay
    -- `word` is deliberately NOT exposed. The DB carries it (the CASC folder
    -- stem the kits came from) but it is a build identifier, not English -- it
    -- reads as "bloodfangwidowspider" as often as "crab", and the UI shipped it
    -- raw once already. Anything that wants to name a voice needs a curated
    -- vocabulary first; the facade not offering it keeps that decision here.
    return { kits = _numberList(kits), durs = durs ~= "" and _numberList(durs) or nil, index = voice,
             delayMin = delay and delay[1], delayMax = delay and delay[2],
             sharedWith = _pfVoiceShare[voice] - 1 }
end

-- The model's behaviour record: { idle = {{animID, variation, pct, ms},...},
-- also = {animID,...}, glow = {lights, particles, additive}, labels? }.
-- Decoded per call. nil = model unparsed (6 of 967).
function S.PetFacts:AnimProfile(speciesID)
    local db = _table("HDGR_PetAnimDB")
    local fdid = db.species[speciesID]  -- exception(nullable): species without a model join
    if not fdid then return nil end
    local packed = db.models[fdid]      -- exception(nullable): parseError models are not emitted
    if not packed then return nil end
    local idleS, alsoS, glowS = packed:match("^([^|]*)|([^|]*)|([^|]*)$")
    local idle = {}
    for var, pct, ms in idleS:gmatch("(%d+):(%d+):(%d+)") do
        idle[#idle + 1] = { 0, tonumber(var), tonumber(pct), tonumber(ms) }
    end
    return { idle = idle, also = _numberList(alsoS), glow = _numberList(glowS),
             labels = db.labels[fdid] }   -- exception(nullable): most models carry no curated labels
end

function S.PetFacts:Height(speciesID)
    return _table("HDGR_PetSizeDB")[speciesID]  -- exception(nullable): PetSizeDB miss for a post-build species
end

-- actorScale, seatLift, girth for a species, or nothing for an unmeasured mesh.
local function _sceneRow(speciesID)
    local row = _table("HDGR_PetSceneScaleDB")[speciesID]  -- exception(nullable): unmeasured mesh
    if not row then return end
    local scale, lift, girth = row:match("^(%S+) (%S+) (%S+)$")
    return tonumber(scale), tonumber(lift), tonumber(girth)
end

function S.PetFacts:SceneScale(speciesID)
    -- SizeDB height / vertex extent: a ModelScene actor renders the RAW vertex
    -- mesh (no DB2 scale factor applies), so this is what SetRequestedScale
    -- needs for the actor to render at the pet's true world height.
    local scale = _sceneRow(speciesID)
    return scale or 1.0  -- exception(optional): unmeasured mesh; emit convention
end

function S.PetFacts:SceneGirth(speciesID)
    -- Larger horizontal mesh span, world units: the camera frames on
    -- max(height, girth) so long bodies (snakes) are not cropped.
    local _, _, girth = _sceneRow(speciesID)
    return girth or 0  -- exception(optional): unmeasured mesh; emit convention
end

function S.PetFacts:SceneLift(speciesID)
    -- -meshLowestZ x sceneScale: added to the seat Z it drops a hovering
    -- mesh's bottom onto the seat (fliers are authored above their origin).
    local _, lift = _sceneRow(speciesID)
    return lift or 0  -- exception(optional): unmeasured mesh; emit convention
end

function S.PetFacts:KindIndex()
    _ensurePetIndexes()
    return _pfKinds
end

function S.PetFacts:CladeIndex()
    _ensurePetIndexes()
    return _pfClades
end

function S.PetFacts:SceneDecor()
    return _table("HDGR_PetSceneDecorDB")
end
