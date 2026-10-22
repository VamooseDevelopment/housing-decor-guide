-- HDG.HousingCatalogObserver
-- ============================================================================
-- Sole owner of C_HousingCatalog (Iron Invariant §9). One searcher, one owner
-- (see feedback_lua_empty_string_truthy.md for the prior split-owner lesson).
-- All housing catalog work flows through this module:
--   * Cold-sweep (ReconcileFull / _OnSearcherResults atomic-rebuild) + single
--     searcher with full Blizzard config (BasicDecor + all tags/indoor/outdoor)
--   * Incremental updates (ReconcileEntry) on HOUSING_STORAGE_ENTRY_UPDATED
--   * Sync per-item lookup (Resolve(itemID)) for modelPreview + allItems fallback
-- ADR-012: hot UI actions never invalidate the catalog cache.
-- Stability: searcher callbacks can fire with partial data; 500ms settle timer coalesces.

HDG = HDG or {}
HDG.HousingCatalogObserver = HDG.HousingCatalogObserver or {}

local R = HDG.HousingCatalogObserver

-- Reverse indexes (atomic-swapped at the end of each sweep; persist between
-- sweeps because the table references survive on R).
R.byItemID       = R.byItemID       or {}
R.byDecorID      = R.byDecorID      or {}  -- [decorID] = row (built alongside byItemID)
R.byVendor       = R.byVendor       or {}  -- [name::zone] = vendor record (see Vendor records)
R.tagIDToGroup   = R.tagIDToGroup   or {}
-- Storage-entry events that land while a sweep is in flight -- or while nothing
-- can tell whether the decor was already owned -- are parked here and replayed
-- by _DrainParkedEntries (see ReconcileEntry, _priorOwnership).
R._sweepInFlight  = R._sweepInFlight  or false  -- exception(false-positive): idempotent module-load init
R._pendingEntries = R._pendingEntries or {}     -- exception(false-positive): idempotent module-load init
-- True from the moment a BUILT index is handed to the settle timer until that
-- timer commits it. ReconcileFull coalesces a re-kick against this rather than
-- against `_settleTimer`: the flag is set before the timer is armed and cleared
-- inside the callback, so it reads correctly no matter when the timer fires --
-- including in tests, where the mock fires synchronously and leaves a stale
-- handle in `_settleTimer`.
R._commitPending  = R._commitPending  or false  -- exception(false-positive): idempotent module-load init
-- True when a re-kick was coalesced against that pending commit. Coalescing
-- DEFERS the re-kick, it does not drop it: the settle callback replays it once
-- the commit resolves, however many re-kicks it absorbed (_ReplayOwedRekick).
R._rekickOwed     = R._rekickOwed     or false  -- exception(false-positive): idempotent module-load init
-- HOUSING_STORAGE_UPDATED fires counted when the newest build with entries
-- (settling or committed) began reading; -1 before the first. An update at or
-- under it is already in that build (OnHousingStorageUpdated).
R._storageSeen    = R._storageSeen    or -1     -- exception(false-positive): idempotent module-load init
-- Whether the build handed to the settle timer has entries (false: a 0-entry abort).
R._settlingHasEntries = R._settlingHasEntries or false  -- exception(false-positive): idempotent module-load init
-- The catalog-change count the committed rows were built under, or false when they
-- cannot be reused: a build reuses them only while it reads the same count
-- (_stageReuse). False before the first build, after a build without tag groups,
-- and after a clear or a manual reload.
R._rowsStamp = R._rowsStamp or false  -- exception(false-positive): idempotent module-load init

-- ===== Reconciler ============================================================
-- Two entry points:
--   ReconcileFull                  -- cold sweep, atomic-rebuilds all indexes
--   ReconcileEntry(entryVariantID) -- targeted update from HOUSING_STORAGE_ENTRY_UPDATED;
--                                     parked while a sweep is in flight (or prior
--                                     ownership is unknown), replayed at commit
-- Both mutate state via reducer dispatches (per ADR-012).

function R:GetClientVer()
    local v = _G.GetBuildInfo and _G.GetBuildInfo()
    return tostring(v or "unknown")
end

-- True from RunSearch until the commit swaps the snapshot in: storage-entry
-- events park meanwhile (ReconcileEntry) and land with the commit. Readers that
-- count on those events (DestroyQueue) wait for DECOR_CATALOG_READY instead of
-- reading the silence as the server's.
function R:IsSweepPending()
    return R._sweepInFlight or R._commitPending
end

function R:_CancelSettleTimer()
    self._commitPending = false
    if self._settleTimer then
        if self._settleTimer.Cancel then self._settleTimer:Cancel() end  -- exception(boundary): C_Timer.After returns a handle; Cancel is the cancel API but handle shape varies
        self._settleTimer = nil
    end
end

-- Category / subcategory display-name cache (ADR-003: API calls at resolver seam).
-- Stamped onto each row at sweep time. Nil catID = sparse row (only legit nil input).
local _categoryNameCache    = {}
local _subcategoryNameCache = {}
local function resolveCategoryName(catID)
    if not catID then return nil end
    local cached = _categoryNameCache[catID]
    if cached then return cached end
    local info = _G.C_HousingCatalog.GetCatalogCategoryInfo(catID)
    if not info then return nil end  -- exception(boundary): nullable while catalog streams in; Blizzard's OnCategoryUpdated nil-checks the same call. Miss stays uncached so the next sweep retries.
    local name = info.name
    if name then _categoryNameCache[catID] = name end
    return name
end
local function resolveSubcategoryName(subID)
    if not subID then return nil end
    local cached = _subcategoryNameCache[subID]
    if cached then return cached end
    local info = _G.C_HousingCatalog.GetCatalogSubcategoryInfo(subID)
    if not info then return nil end  -- exception(boundary): nullable while catalog streams in; see resolveCategoryName.
    local name = info.name
    if name then _subcategoryNameCache[subID] = name end
    return name
end

-- ============================================================================
-- Catalog searcher: ONE persistent R._searcher (Blizzard HousingCatalogFrameMixin shape).
-- Created + callback-set once; reused for every RunSearch.
-- Guard: namespace + searcher object guarded (CreateCatalogSearcher can fail);
-- all searcher methods called strictly (vanished method = loud fail, never silent skip).
--
-- exception(boundary): GetAllFilterTagGroups() reads 0 then N a moment later (tag metadata streams in at open).
-- We re-apply config on each kick while not "ready" so tag groups land when they exist;
-- storage/catalog events drive re-kicks. Once "ready" just RunSearch.
-- ============================================================================

-- ALL-category focus. nil also means "all categories" to the searcher (Blizzard convention).
-- exception(boundary): Blizzard global table.
local function _allCategoryID()
    local C = _G.Constants and _G.Constants.HousingCatalogConsts
    return C and C.HOUSING_CATALOG_ALL_CATEGORY_ID
end

-- _EnsureSearcher: single persistent searcher, created + held on R._searcher so GC
-- can't reclaim it before the async callback fires. boundary: C_HousingCatalog absent.
function R:_EnsureSearcher()
    if self._searcher then return self._searcher end
    if not (_G.C_HousingCatalog and _G.C_HousingCatalog.CreateCatalogSearcher) then
        return nil
    end
    local s = _G.C_HousingCatalog.CreateCatalogSearcher()
    if not s then return nil end
    self._searcher = s
    -- Set once; fires on the initial RunSearch AND every later re-RunSearch.
    s:SetResultsUpdatedCallback(function() R:_OnSearcherResults(s) end)
    return s
end

-- _ConfigureSearcher: Blizzard's exact config (OneTimeInit + ResetFiltersToDefault + ALL-focus).
function R:_ConfigureSearcher(s)
    s:SetAutoUpdateOnParamChanges(false)
    s:SetStoredOnly(false)
    s:SetBaseVariantOnly(true)
    s:SetEditorModeContext(_G.Enum.HouseEditorMode.BasicDecor)
    s:SetCustomizableOnly(false)
    s:SetAllowedIndoors(true)
    s:SetAllowedOutdoors(true)
    s:SetCollected(true)
    s:SetUncollected(true)
    s:SetFirstAcquisitionBonusOnly(false)
    s:SetFilteredCategoryID(_allCategoryID())
    s:SetFilteredSubcategoryID(nil)
    for _, group in ipairs(_G.C_HousingCatalog.GetAllFilterTagGroups() or {}) do
        s:SetAllInFilterTagGroup(group.groupID, true)
    end
    s:SetAutoUpdateOnParamChanges(true)
end

-- ReconcileFull: kick the search. Re-applies config while not "ready" (tag groups
-- may still be streaming in); RunSearch. Results land async in _OnSearcherResults;
-- 0.5s settle timer coalesces bursts. Storage/catalog events re-kick until loaded.
function R:ReconcileFull(reason)
    local s = self:_EnsureSearcher()
    if not s then
        HDG.Log:Error("catalog_error", "ReconcileFull aborted: C_HousingCatalog unavailable")
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CATALOG_LOAD_FAILED, payload = { reason = "no_api" } })
        return
    end
    -- Do NOT coalesce concurrent ReconcileFull calls. A CATALOG_REFRESH_QUEUED or
    -- view-change re-kick that lands while a sweep is in flight IS the recovery path
    -- for a slow / unresponsive searcher: it re-applies config + re-RunSearch, which
    -- is what makes a slow first response eventually commit. It's the SAME persistent
    -- searcher, so the later RunSearch usually supersedes into ONE commit -- but it's
    -- a race: if the earlier sweep's 0.5s settle expires before the re-kick's results
    -- arrive, both commit (seen in the wild 2026-07-02: generation=1 then =2, 0.5s
    -- apart, identical data). Benign -- each commit is an atomic swap -- so we accept
    -- the occasional double rather than cancel pending settles (discarding a good
    -- pending commit re-opens the hang if the re-kicked search goes silent).
    -- (A coalesce guard once lived here; it left slow-searcher characters stuck on
    -- "Scanning catalog..." forever, because the recovery re-kick was the thing it
    -- suppressed. Removed.)
    -- ...but a re-kick that lands while a BUILT index is SETTLING must not run NOW,
    -- and that is a different case from the one above. The searcher has already
    -- answered, the 95 ms / ~7 MB index exists, and _CommitSweep fires within the
    -- settle window -- yet RunSearch's results would cancel that pending commit
    -- (_CancelSettleTimer in _OnSearcherResults) and rebuild from scratch. Measured
    -- at every login: two full 2044-entry builds 700 ms apart, only the second one
    -- committing (2026-09-13 perf profile, chased down from a "memory leak" report).
    -- The hang the removed coalesce guard caused was the SILENT-searcher case -- no
    -- results, so no settle timer -- and that still falls straight through. Per-entry
    -- ownership changes are unaffected either way: HOUSING_STORAGE_ENTRY_UPDATED goes
    -- to ReconcileEntry, which parks and replays at commit.
    -- Deferred, not dropped: the settle may be a 0-entry abort that is WAITING for
    -- exactly this re-kick, and a commit's CATALOG_LOAD_COMPLETED clears the
    -- refreshPending that would otherwise have remembered it. _ReplayOwedRekick
    -- hands it back to the refresh routing once the commit resolves.
    if self._commitPending then
        self._rekickOwed = true
        HDG.Log:Info("catalog_swept",
            "sweep re-kick deferred (by " .. (reason or "?") .. ") -- a built index is settling; replayed after it resolves")
        return
    end
    if HDG.Store:GetState().session.catalog.status ~= "ready" then
        self:_ConfigureSearcher(s)
    end
    HDG.Log:Info("catalog_swept", "Starting full catalog sweep... (by " .. (reason or "?") .. ")")
    -- Perf RTT: stamp when we fire the external catalog search. The gap to the
    -- first _OnSearcherResults callback is the EXTERNAL round-trip (Blizzard
    -- building/returning the catalog) -- not our CPU. Recorded as an "rtt" mark.
    if HDG.Perf and HDG.Perf.Enabled and HDG.Perf:Enabled() then  -- exception(false-positive): HDG.Perf is TOC-guaranteed at runtime; headless test mock omits it
        self._perfSearchFiredAt = _G.debugprofilestop and _G.debugprofilestop() or nil
    end
    -- From here until _CommitSweep swaps the snapshot in, a targeted patch would
    -- land in tables about to be replaced; ReconcileEntry parks instead.
    self._sweepInFlight = true
    s:RunSearch()
end

-- ===== Vendor records ========================================================
-- One record per vendor (name, zone): name, zone, npcID, mapID, x, y, side,
-- canWaypoint, and the items it sells. byVendor IS the records. A row's vendor
-- entry keeps only the item's price there (cost, costEntries, faction) and reads
-- the vendor's fields through its record, which is the entry's metatable, so
-- v.name / v.zone / v.mapID read as before. A vendor field that differs from the
-- record stays raw on the entry and wins. Before this, every vendor field sat on
-- every entry, again on the index, and again as baked text (memory census
-- 2026-10-19).
local RECORD_FIELDS = { "name", "zone", "npcID", "mapID", "x", "y", "side", "canWaypoint" }
local RECORD_FIELD_SET = {}
for _, f in ipairs(RECORD_FIELDS) do RECORD_FIELD_SET[f] = true end
local DROPPED_VENDOR_FIELDS = { standing = true }   -- nothing reads it

-- The index the running sweep builds; nil between sweeps.
local _sweepRecords = nil
-- The running sweep's cost entries by raw Cost: line; nil between sweeps.
local _sweepCostLines = nil

local function _newRecord(v)
    local rec = { items = {} }
    for _, f in ipairs(RECORD_FIELDS) do rec[f] = v[f] end
    rec.__index = rec   -- the record is its entries' metatable
    return rec
end

-- The record for a resolved vendor entry. A sweep's records join that sweep's
-- index; a row built between sweeps (a decor just collected) shares the live
-- index's record, or gets one of its own the index never lists -- the index has
-- only ever changed at a sweep.
local function _recordFor(v)
    local key = v.name .. "::" .. (v.zone or "")
    local rec = (_sweepRecords or R.byVendor)[key]
    if not rec then
        rec = _newRecord(v)
        if _sweepRecords then _sweepRecords[key] = rec end
    end
    return rec
end

-- An entry that lacks a field its record has would read the record's value, so it
-- stays whole (none in the recorded catalog; the sharing test counts them).
local function _fitsRecord(v, rec)
    for _, f in ipairs(RECORD_FIELDS) do
        if v[f] == nil and rec[f] ~= nil then return false end
    end
    return true
end

-- A resolved vendor entry rebuilt as the item's price at the vendor plus its record.
local function _linkVendor(v)
    local whole = not (v.name and v.name ~= "")
    local rec = not whole and _recordFor(v)
    if rec and not _fitsRecord(v, rec) then rec = nil end
    local entry = {}
    for k, val in pairs(v) do
        if not DROPPED_VENDOR_FIELDS[k] and not (rec and RECORD_FIELD_SET[k] and rec[k] == val) then
            entry[k] = val
        end
    end
    return rec and setmetatable(entry, rec) or entry
end

-- ===== Per-sweep index builders ==============================================
-- `acc` = per-sweep accumulator: { byItemID, byDecorID, byVendor, seenItems, owned,
-- shared }. Atomic-assigned onto R at commit; subscribers never see partial state.

-- Add a row's item to each of its vendors' records (byVendor). Composite
-- (name, zone) key: ~9 vendor names on 12.0.5 are shared across zones; keying by
-- name alone collapses distinct vendors into one bucket. row.vendors is the
-- complete list: _bakeVendors folds CatalogOverride type=5 vendors (hidden or
-- placeholder sellers like Chel the Chip) into it.
local function _indexVendorsFromRow(acc, row)
    for _, v in ipairs(row.vendors) do
        if v.name and v.name ~= "" then
            local rec = _recordFor(v)
            local seen = acc.seenItems[rec]
            if not seen then seen = {}; acc.seenItems[rec] = seen end
            if not seen[row.itemID] then
                seen[row.itemID] = true
                rec.items[#rec.items + 1] = row.itemID
            end
        end
    end
end

-- ===== Shared row sub-tables ================================================
-- Many rows carry identical sub-tables: the same vendor at the same price (733
-- distinct of 2,046 vendor entries in the test catalog), the same cost (222 of
-- 1,788 rows), the same source tags (654) and the same tag set (1,080). Once
-- BuildRow returns nothing writes to these -- PatchCounts and _bakeVariantDyes
-- touch only the counts and dyedVariants -- so each row points at one shared copy
-- (memory census 2026-10-19: ~3 MB of the catalog).
-- Each is looked up by what it is built FROM, at the point it is built, so a repeat
-- is neither built nor compared. Signing every finished table by its content
-- afterwards was the sweep's share lap: 54 of its 143 ms, in one frame at the
-- first open (2026-10-22 profile). The interns live for one sweep; a row built
-- between sweeps (a decor just collected) builds its own tables.
local _sweepShared = nil

local function _newShared()
    return {
        vendorEntries = {},   -- [costEntries or NONE][vendor key] = entry
        vendorLists   = {},   -- trie by entry; the list at LEAF
        cost          = {},   -- content key -> cost entries list
        tags          = {},   -- [kind][inputs key] = source tag
        tagLists      = {},   -- trie by tag; the list at LEAF
        tagSets       = {},   -- sorted tag IDs -> Blizzard's tag table
    }
end

-- A nil input's key, and where a trie node keeps its list.
local NONE, LEAF = {}, {}

local function _child(node, key)
    local c = node[key]
    if not c then c = {}; node[key] = c end
    return c
end

-- The one list with these elements in this order. Its elements are shared
-- already, so their identity stands for their content and the trie needs no key.
local function _sharedList(root, list)
    local node = root
    for i = 1, #list do node = _child(node, list[i]) end
    local hit = node[LEAF]
    if hit then return hit end
    node[LEAF] = list
    return list
end

-- Inputs joined into one key. nil is a part of its own, apart from "".
local function _keyPart(v)
    if v == nil then return "\0" end
    return v
end

-- Cost entries by content: lists from different Cost: lines can match. Runs once
-- per distinct line (the raw-line memo answers the repeats), so its cost is small.
-- A field missing from the list would be left out of the key and merge lists
-- that differ, so it is an error.
local COST_FIELDS = { "currencyID", "itemID", "amount", "icon" }
local COST_FIELD_SET = {}
for _, f in ipairs(COST_FIELDS) do COST_FIELD_SET[f] = true end
local _costKeyBuf = {}
local function _sharedCost(list)
    local shared = _sweepShared
    if not shared then return list end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    local n = 0
    for i = 1, #list do
        local e = list[i]
        for k in pairs(e) do
            if not COST_FIELD_SET[k] then
                error(("catalog cost sharing: field %q is not in the cost key"):format(tostring(k)), 2)
            end
        end
        for j = 1, #COST_FIELDS do
            local v = e[COST_FIELDS[j]]
            n = n + 1
            -- Typed: an icon can be a file ID or a path that is all digits.
            _costKeyBuf[n] = v == nil and "-" or (type(v) == "number" and "n" or "s") .. v
        end
    end
    local key = table.concat(_costKeyBuf, "\31", 1, n)
    local hit = shared.cost[key]
    if hit then return hit end
    shared.cost[key] = list
    return list
end

-- Blizzard's tag table, kept as the API gave it, repeats too. It is not built
-- here, so it is looked up by its sorted tag IDs; a hit whose names differ keeps
-- its own table.
local _tagIDBuf = {}
local function _sharedTagSet(tags)
    if not tags then return nil end  -- exception(boundary): Blizzard struct field optional
    local shared = _sweepShared
    if not shared then return tags end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    local n = 0
    for id in pairs(tags) do
        if type(id) ~= "number" then return tags end  -- exception(boundary): Blizzard keys tags by ID; any other key and the table stays as given, unshared
        n = n + 1
        _tagIDBuf[n] = id
    end
    for i = #_tagIDBuf, n + 1, -1 do _tagIDBuf[i] = nil end   -- a longer set's tail from the last use
    table.sort(_tagIDBuf)
    local key = table.concat(_tagIDBuf, ",")
    local hit = shared.tagSets[key]
    if not hit then
        shared.tagSets[key] = tags
        return tags
    end
    for id, name in pairs(tags) do
        if hit[id] ~= name then return tags end
    end
    return hit
end

-- ===== Sweep stage profiling ================================================
-- Splits catalog.indexSweep into its stages WITH CALL COUNTS, so /hdgr perf can
-- say which layer the time is in: the Blizzard entry read, the variant fetch,
-- our parse, each bake group, the index stamp. The owner's 2026-09-03 login
-- profile showed the whole sweep as one 3297 ms op (2045 entries) with nothing
-- to say whether that was Blizzard's calls or ours. Live only during a timed
-- sweep (_sweepProf is set by _OnSearcherResults under HDG.Perf:Enabled());
-- every lap site is a single nil-check when perf is off. A stage's count is
-- its denominator: "variants (225 calls)" reads as 225 fetches, not 2045 rows
-- that did nothing.
-- Every top-level stage is single-sided: entryInfo, variants, variantDyes and
-- parseSource.strip are Blizzard calls; everything else is ours. The stages
-- partition the sweep, and "~unlapped" is what the laps did not cover (the loop
-- itself), so the report proves its own coverage instead of asserting it.
-- "~clock" is the cost of reading the clock, the floor every per-call figure
-- must be read against.
local SWEEP_STAGES = {
    "entryInfo", "reuse", "rowTable", "tagSet", "variants", "parseSource", "overrides+augment",
    "expansion", "vendors", "cost", "recipe+sourceTypes+bonus",
    "variantDyes", "sourceTags", "slim", "index",
}
-- Nested inside parseSource: the C_StringUtil.StripHyperlinks half of the parse,
-- one call per sourceText line. Reported on its own row, not part of the sum.
local STRIP_STAGE = "parseSource.strip"
local CLOCK_PROBE_READS = 1000
local _sweepProf = nil   -- { ms = {stage=ms}, kb = {stage=KB}, n = {stage=count} } during a timed sweep

-- One lap = the clock AND the heap, so every stage answers "how long" and "how
-- much" from the same reading. The heap delta is true allocation, not net heap
-- movement, because the enclosing RecordOp holds the collector for the whole
-- sweep (HDG.Perf, Sampling). Returns both readings so the next lap starts
-- where this one ended.
local function _lap(stage, t0, k0)
    local now, know = _G.debugprofilestop(), collectgarbage("count")
    _sweepProf.ms[stage] = (_sweepProf.ms[stage] or 0) + (now - t0)
    _sweepProf.kb[stage] = (_sweepProf.kb[stage] or 0) + (know - k0)
    _sweepProf.n[stage]  = (_sweepProf.n[stage]  or 0) + 1
    return now, know
end

local function _clockFloorMs()
    local t0 = _G.debugprofilestop()
    for _ = 1, CLOCK_PROBE_READS do _G.debugprofilestop() end
    return _G.debugprofilestop() - t0
end

local function _reportSweepStages(perf, totalMs, totalKB, entries)
    local lappedMs, lappedKB = 0, 0
    for _, stage in ipairs(SWEEP_STAGES) do
        local n = _sweepProf.n[stage]
        if n then
            perf:RecordOpQuiet(("catalog.sweep.%s (%d calls)"):format(stage, n),
                               _sweepProf.ms[stage], _sweepProf.kb[stage])
            lappedMs = lappedMs + _sweepProf.ms[stage]
            lappedKB = lappedKB + _sweepProf.kb[stage]
        end
    end
    local strips = _sweepProf.n[STRIP_STAGE]
    if strips then
        perf:RecordOpQuiet(("catalog.sweep.%s (%d calls, inside parseSource)"):format(STRIP_STAGE, strips),
                           _sweepProf.ms[STRIP_STAGE], _sweepProf.kb[STRIP_STAGE])
    end
    perf:RecordOpQuiet(("catalog.sweep.~unlapped (%d entries)"):format(entries), totalMs - lappedMs, totalKB - lappedKB)
    -- Reading the clock allocates nothing; the row is the ms floor only.
    perf:RecordOpQuiet(("catalog.sweep.~clock (%d reads)"):format(CLOCK_PROBE_READS), _clockFloorMs(), 0)
end

-- Process one searcher entry: build the row, stamp the indexes, feed vendors.
-- entryType must be a REAL member of Enum.HousingCatalogEntryType. Blizzard's
-- argument validator rejects anything else and GetCatalogEntryInfo throws
-- ("bad argument #2 ... Current Field: [entryType]") -- live reports carried
-- entryType 247 (2026-08-05) and 9 (2026-07) against a documented range of
-- 0..2. The guard below already CLAIMED to catch out-of-range entryType; it
-- only ever tested whether the field was secret, so both got through.
--
-- Derived from the live enum rather than a hardcoded 0..2, so a new Blizzard
-- entry type is not silently classified as poison the day it ships. `Invalid`
-- is excluded BY NAME: it is a real enum member and a real sentinel, and it is
-- not something to hand to a lookup.
--
-- exception(boundary): _G.Enum is Blizzard's. If HousingCatalogEntryType is
-- missing entirely the housing API is gone and this whole observer is moot --
-- let that surface loudly rather than quietly treating every row as poison.
local _validEntryType
local function _entryTypeOK(entryType)
    if type(entryType) ~= "number" then return false end
    if not _validEntryType then
        _validEntryType = {}
        for name, value in pairs(_G.Enum.HousingCatalogEntryType) do
            if name ~= "Invalid" then _validEntryType[value] = true end
        end
    end
    return _validEntryType[entryType] == true
end

-- The count scalars a storage change moves, read off an entry's info. A row's own
-- first-acquisition bonus stands when the info leaves it out.
local function _countsOf(info, row)
    return {
        quantity                 = info.totalNumStored           or 0,  -- exception(boundary): Blizzard struct field sparse (row.quantity KEEPS its name; source is the 12.0.5 field)
        numPlaced                = info.totalNumPlaced           or 0,  -- exception(boundary): Blizzard struct field sparse
        remainingRedeemable      = info.remainingRedeemable      or 0,  -- exception(boundary): Blizzard struct field sparse
        destroyableInstanceCount = info.destroyableInstanceCount or 0,  -- exception(boundary): Blizzard struct field sparse
        firstAcquisitionBonus    = info.firstAcquisitionBonus
                                     or row.firstAcquisitionBonus or 0,  -- exception(boundary): Blizzard struct field sparse
    }
end

-- True when the five count scalars an entry event carries already match the row:
-- Blizzard fires HOUSING_STORAGE_ENTRY_UPDATED for every placement nudge, and a
-- signal for an unchanged row rebuilt the whole Decor projection (about 6 MB per
-- event with the Decor view showing, 2026-09-13 audit).
local function _countsMatch(row, counts)
    return row.quantity                 == counts.quantity
       and row.numPlaced                == counts.numPlaced
       and row.remainingRedeemable      == counts.remainingRedeemable
       and row.destroyableInstanceCount == counts.destroyableInstanceCount
       and row.firstAcquisitionBonus    == counts.firstAcquisitionBonus
end

-- The catalog-data events seen so far: a change since a build means its rows may
-- be out of date (R._rowsStamp).
local function _catalogChangeCount()
    local BE = HDG.BlizzardEvents
    return BE:FireCount("HOUSING_CATALOG_CATEGORY_UPDATED")
         + BE:FireCount("HOUSING_CATALOG_SUBCATEGORY_UPDATED")
end

-- A refresh reuses the row the last build made for an entry. Only the counts and
-- the dye stacks change with storage; the rest of a row comes from the entry's
-- catalog fields and HDG's shipped data, and building it was ~24 MB of every
-- 31 MB build (memory plan 2026-10-19 sec 6). Checked inputs: the recipe is the
-- shipped DecorDB (StaticData.Recipes), not the session's recipe scan; category
-- names resolve below; tag groups and catalog hotfixes gate the reuse itself
-- (R._rowsStamp). An override cost's currency icon that C_CurrencyInfo missed
-- stays missing until a reload instead of the next build. What changed waits in acc for the
-- commit, which writes it onto the rows as it swaps the index in, so until then
-- readers see the committed snapshot, as with a fresh build. Returns whether the
-- entry is owned now.
local function _stageReuse(acc, rid, row, info)
    local counts = _countsOf(info, row)
    if not _countsMatch(row, counts) then acc.patches[rid] = counts end
    if row.canCustomize and _G.C_HousingCatalog.GetAllVariantInfosForEntry then  -- exception(boundary): absent in headless fixtures, as in BuildRow
        local variants = _G.C_HousingCatalog.GetAllVariantInfosForEntry({
            recordID = rid, entryType = info.entryType or 1,  -- exception(boundary): Blizzard struct field sparse
        })
        if type(variants) == "table" then acc.variants[rid] = variants end  -- exception(boundary): API returns nil on cold/invalidated cache
    end
    -- A name missed while the catalog streamed in resolves now, as a build would.
    resolveCategoryName(row.categoryID)
    resolveSubcategoryName(row.subcategoryID)
    acc.reused = acc.reused + 1
    return counts.quantity + counts.remainingRedeemable + counts.numPlaced > 0
end

-- Skips non-qualifying entries (non-zero subtype = variant placeholders; no
-- itemID = catalog inconsistency).
local function _processEntry(acc, entry)
    local rid = entry.recordID
    if not rid then return end
    -- exception(boundary): searcher results can carry a poisoned row (secret values /
    -- negative recordID / out-of-range entryType -- seen live on 12.0.7: recordID
    -- -902229712, entryType 9). GetCatalogEntryInfo THROWS on these via the
    -- deprecation shim, and one bad row would abort the whole sweep. Validate the
    -- struct here; count skips for the post-loop warn.
    local secret = _G.issecretvalue
    if (secret and (secret(rid) or secret(entry.entryType) or secret(entry.variantIdentifier)))
        or type(rid) ~= "number" or rid <= 0
        or not _entryTypeOK(entry.entryType) then
        acc.skippedPoisoned = (acc.skippedPoisoned or 0) + 1
        return
    end
    local t, hk
    if _sweepProf then t, hk = _G.debugprofilestop(), collectgarbage("count") end
    local info = _G.C_HousingCatalog.GetCatalogEntryInfo(entry)
    if t then t, hk = _lap("entryInfo", t, hk) end
    if not info then return end
    -- (12.0.5+ searcher rows have no subtypeIdentifier -- the old variant-placeholder
    -- filter is gone with the compound-entryID era.)
    if not info.itemID then return end
    -- info.recordID isn't always populated by the entry-info API; the entry
    -- itself carries it via the searcher result.
    info.recordID = info.recordID or rid
    local row = acc.reuse and R.byDecorID[rid]  -- exception(nullable): an entry the last build did not have
    local owned
    if row and row.itemID == info.itemID then
        owned = _stageReuse(acc, rid, row, info)
        if t then t, hk = _lap("reuse", t, hk) end
    else
        row = R:BuildRow(info)   -- laps its own stages
        if t then t, hk = _G.debugprofilestop(), collectgarbage("count") end
        owned = row.isOwned
    end
    acc.byItemID[row.itemID] = row
    acc.byDecorID[rid]       = row
    if owned then acc.owned[rid] = true end
    _indexVendorsFromRow(acc, row)
    if t then _lap("index", t, hk) end
end

function R:_OnSearcherResults(searcher)
    -- Driven by the persistent searcher's results-updated callback (and the
    -- storage-event re-kicks). Reads GetCatalogSearchResults() -- the FILTERED
    -- set; our ALL-category + all-tags config makes that the full catalog
    -- (mirrors Blizzard's HousingCatalogFrameMixin:UpdateCatalogData read).
    if not (searcher and searcher.GetCatalogSearchResults) then return end
    -- Perf RTT: first callback after RunSearch -> external catalog round-trip.
    -- One-shot (clear the stamp) so multi-fire searcher bursts don't re-mark.
    if self._perfSearchFiredAt and HDG.Perf then
        local rtt = (_G.debugprofilestop and _G.debugprofilestop() or 0) - self._perfSearchFiredAt
        self._perfSearchFiredAt = nil
        HDG.Perf:Mark("catalog searcher RTT (external -- Blizzard built the catalog)", rtt, "rtt")
    end
    -- Taken before a single entry is read: the storage updates this build holds,
    -- and the catalog changes its rows are built under.
    local storageSeen = HDG.BlizzardEvents:FireCount("HOUSING_STORAGE_UPDATED")
    local catalogStamp = _catalogChangeCount()
    local items = searcher:GetCatalogSearchResults()
    if not items then
        -- nil result set: nothing to commit yet. Stay "loading"; the next
        -- storage/catalog event re-kicks (re-applying config) until entries land.
        HDG.Log:Warn("catalog_error", "GetCatalogSearchResults returned nil; sweep not committed (will retry on next storage event)")
        return
    end

    R:_BuildTagIDIndex()  -- must precede the sweep so _bakeExpansion sees Expansion tags

    -- Build into per-sweep acc; _CommitSweep atomic-assigns in the settle callback.
    local acc = {
        byItemID = {}, byDecorID = {}, byVendor = {},
        seenItems = {},   -- [record] = { [itemID] = true }: dedups each vendor's item list
        owned = {},
        shared = _newShared(),   -- what rows share, by what it is built from; dropped with acc
        costLines = {},   -- raw Cost: line -> its entries (_costEntriesOf)
        -- Reuse the committed rows unless a catalog change came after they were built.
        reuse = R._rowsStamp == catalogStamp,
        reused = 0,
        patches = {},     -- [decorID] = counts: reused rows whose counts moved
        variants = {},    -- [decorID] = variants: reused customizable rows, re-baked at commit
    }
    -- Perf: catalog-load cost (outside dispatch path; flush probe never sees it). boundary: Perf optional.
    local _perf  = HDG.Perf
    local _timed = _perf and _perf:Enabled()
    local _t0, _k0
    if _timed then _t0, _k0 = _perf:Open() end
    _sweepProf   = _timed and { ms = {}, kb = {}, n = {} } or nil
    _sweepRecords = acc.byVendor   -- BuildRow links vendor entries into this sweep's records
    _sweepCostLines = acc.costLines
    _sweepShared    = acc.shared
    for _, entry in ipairs(items) do
        _processEntry(acc, entry)
    end
    _sweepRecords, _sweepCostLines, _sweepShared = nil, nil, nil
    if acc.skippedPoisoned then
        HDG.Log:Warn("catalog_error", ("%d searcher row(s) skipped: unreadable entry IDs (secret/poisoned) -- sweep completed without them")
            :format(acc.skippedPoisoned))
    end
    if _timed then
        local label = acc.reuse and ("catalog.indexSweep (%d entries, %d rows reused)"):format(#items, acc.reused)
                                 or ("catalog.indexSweep (%d entries)"):format(#items)
        local totalMs, totalKB = _perf:RecordOp(label, _t0, _k0)
        _reportSweepStages(_perf, totalMs, totalKB, #items)
        _sweepProf = nil
    end
    local result = {
        byItemID       = acc.byItemID,
        byDecorID      = acc.byDecorID,
        byVendor       = acc.byVendor,
        owned          = acc.owned,
        sweptAt        = _G.GetTime and _G.GetTime() or 0,  -- exception(boundary): GetTime/time absent in headless harness
        clientVer      = self:GetClientVer(),
        reused         = acc.reuse and acc.reused,   -- false for a full build
        patches        = acc.patches,
        variants       = acc.variants,
        -- A build's rows can be reused only if the tag groups had landed: rows built
        -- without them carry no expansion or size, and a reuse would keep that.
        rowsStamp      = next(R.tagIDToGroup) ~= nil and catalogStamp or false,
    }

    -- A build with entries is the newest catalog from here, settled or not. A
    -- 0-entry abort holds nothing, so it leaves the stamp and the next storage
    -- update still re-kicks.
    self._settlingHasEntries = next(acc.byDecorID) ~= nil
    if self._settlingHasEntries then self._storageSeen = storageSeen end

    -- Settle 0.5s: coalesces searcher multi-fire bursts (boundary: loading screens / login cascade).
    self:_CancelSettleTimer()
    self._commitPending = true
    self._settleTimer = C_Timer.NewTimer(0.5, function()
        self._commitPending = false
        self._settleTimer = nil
        R:_OnSettled(result)
    end)
end

-- A settled result set: commit it, hand back a re-kick deferred during the
-- settle, then judge the decor arrivals that waited for this commit. Judged
-- last, so a replayed re-kick that starts a new sweep makes them wait again
-- instead of running a second search beside it.
function R:_OnSettled(result)
    R:_CommitSweep(result)
    R:_ReplayOwedRekick()
    R:_JudgeArrivalsAfterCommit()
end

-- A re-kick ReconcileFull deferred during the settle, handed back as the
-- CATALOG_REFRESH_QUEUED it stood for, exactly once. The refresh routing then
-- does what the re-kick would have done had it arrived a moment later: still
-- "loading" (the settle was a 0-entry abort) sweeps now; "ready" leaves
-- refreshPending set, so the rebuild runs straight away with a catalog view
-- showing and on the next one otherwise -- no second full build at a login
-- with the window closed.
function R:_ReplayOwedRekick()
    if not R._rekickOwed then return end
    R._rekickOwed = false
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CATALOG_REFRESH_QUEUED,
                         payload = { event = "deferred-rekick" } })
end

-- Was decorID owned BEFORE the storage event being reconciled? A built index
-- answers from its row (no row: a decor the catalog has not shown us, so not
-- owned). Before this session's first build, the persisted collection answers --
-- the owned set the last commit wrote. nil when neither can: a first-ever load
-- that has not landed, or just after a collection reset. Answering false there
-- read every already-owned decor the player nudged during a failed first load
-- as a fresh learn, and wrote a false "learned" craft-history entry for each.
local function _priorOwnership(decorID)
    if next(R.byDecorID) then
        local row = R.byDecorID[decorID]  -- exception(nullable): entry not yet in the catalog
        return row ~= nil and row.isOwned == true
    end
    local owned = HDG.Store:GetState().account.collection.ownedDecorIDs
    if next(owned) then return owned[decorID] == true end
    return nil
end

-- Replay the storage-entry events ReconcileEntry parked. Both sweep endings
-- drain, for different reasons: a commit drains after the atomic swap (so a
-- patch lands on the new tables), a 0-entry abort drains immediately (nothing
-- was replaced, so the parked patches are still valid). An entry parked while
-- nothing could tell whether it was owned takes its answer here -- after a
-- commit, from the snapshot just swapped in -- and one that still has none (an
-- abort before any build) stays parked for the first commit.
function R:_DrainParkedEntries()
    local parked = R._pendingEntries
    R._pendingEntries = {}
    for _, p in ipairs(parked) do
        if p.wasOwned == nil then p.wasOwned = _priorOwnership(p.decorID) end
        if p.wasOwned == nil then
            R._pendingEntries[#R._pendingEntries + 1] = p
        else
            R:_ApplyEntry(p.entryID, p.decorID, p.wasOwned)
        end
    end
end

-- The counts and dye stacks a refresh read for the rows it reused (_stageReuse).
function R:_WriteReusedCounts(result)
    if not result.reused then return end
    local patched = 0
    for decorID, counts in pairs(result.patches) do
        R:PatchCounts(decorID, counts)
        patched = patched + 1
    end
    for decorID, variants in pairs(result.variants) do
        R:_bakeVariantDyes(R.byDecorID[decorID], variants)
    end
    HDG.Log:Info("catalog_swept", ("catalog refreshed in place -- %d rows reused, %d with new counts")
        :format(result.reused, patched))
end

-- _CommitSweep: atomic index swap + dispatch catalog-ready notifications.
function R:_CommitSweep(result)
    local itemCount = 0
    for _ in pairs(result.byDecorID) do itemCount = itemCount + 1 end
    if itemCount == 0 then
        -- 0 entries = catalog not loaded yet (tag groups still streaming). Don't
        -- commit; storage/catalog events re-kick with the config once entries arrive.
        -- The flag MUST clear on the way out: it is the thing that makes
        -- ReconcileEntry park, so a sweep ending here without clearing it parked
        -- every later storage event for the rest of the session -- an ever-growing
        -- list, and a silently dropped learn on every decor acquired until reload.
        R._sweepInFlight = false
        R:_DrainParkedEntries()
        HDG.Log:Warn("catalog_error",
            "catalog search returned 0 entries; not loaded yet -- awaiting storage-event re-kick")
        return
    end

    -- ATOMIC ASSIGN: consumers see either old or new, never mid-build. A reused
    -- row takes its new counts and dye stacks in the same step.
    R.byItemID       = result.byItemID
    R.byDecorID      = result.byDecorID
    R.byVendor       = result.byVendor
    R:_WriteReusedCounts(result)
    R._rowsStamp     = result.rowsStamp
    R._catalogSchemaVersion = HDG.Constants.CATALOG_SCHEMA_VERSION
    R._sweepInFlight = false

    local vendorCount = 0
    for _ in pairs(result.byVendor) do vendorCount = vendorCount + 1 end
    local generation = (HDG.Store:GetState().session.resolvers.catalog.tick or 0) + 1

    -- COLLECTION_BULK_LOAD = canonical "catalog refreshed" action. Reducer reads
    -- payload.owned to update state.account.collection.ownedDecorIDs (persisted).
    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.COLLECTION_BULK_LOAD,
        payload = {
            owned                = result.owned,
            swept_at             = result.sweptAt,
            clientVer            = result.clientVer,
            catalogSchemaVersion = HDG.Constants.CATALOG_SCHEMA_VERSION,
        },
    })
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.DECOR_CATALOG_READY })
    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.CATALOG_LOAD_COMPLETED,
        payload = {
            loadedAt    = _G.GetTime and _G.GetTime() or 0,
            itemCount   = itemCount,
            vendorCount = vendorCount,
            generation  = generation,
        },
    })

    -- Storage-entry events parked during the sweep (ReconcileEntry) replay now,
    -- against the tables just swapped in and after BULK_LOAD has written the
    -- snapshot's owned set -- so a learn the snapshot predates is re-applied
    -- rather than overwritten. That ordering is why the drain sits HERE and not
    -- earlier in the function.
    R:_DrainParkedEntries()

    -- Rebuild category nav: the MAIN_WINDOW_OPENING build runs before the sweep
    -- completes; this ensures subcategory info (e.g. Furnishings) is populated.
    R:QueueCategoryTreeRebuild()

    R:_UpdateVintage()

    HDG.Log:Success("catalog_refreshed",
        string.format("Catalog ready -- %d items, %d vendors indexed", itemCount, vendorCount))
end

-- Patch-vintage diff: any live itemID absent from the persisted snapshot is
-- NEW -- added by a client patch OR a mid-patch hotfix (so we diff on every
-- full sweep, not on build-number change; the build is the STAMP on the
-- batch, not the tripwire). First-ever sweep seeds the snapshot silently.
-- Later sweeps in the SEED session also absorb silently: the catalog streams
-- in (tag groups / storage re-kicks), so a post-seed sweep can surface
-- late-streaming rows that are seed material, not patch additions. Hotfix
-- batches count from the next session on.
function R:_UpdateVintage()
    local cv = HDG.Store:GetState().account.catalogVintage
    local isSeed = next(cv.snapshot) == nil
    if isSeed then R._vintageSeededSession = true
    elseif R._vintageSeededSession then isSeed = true end
    local fresh = {}
    for itemID in pairs(R.byItemID) do
        if not cv.snapshot[itemID] then fresh[#fresh + 1] = itemID end
    end
    if #fresh == 0 then return end
    local label, build = "?", 0
    if _G.GetBuildInfo then  -- exception(boundary): GetBuildInfo absent in headless harness
        local v, _, _, iface = _G.GetBuildInfo()
        label, build = tostring(v), iface or 0
    end
    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.CATALOG_VINTAGE_UPDATE,
        payload = { ids = fresh, build = build, label = label, isSeed = isSeed },
    })
    if not isSeed then
        HDG.Log:Info("catalog_refreshed",
            string.format("%d new decor detected (build %s)", #fresh, label))
    end
end

-- One COUNTS_UPDATED per frame for a burst of entry events (a parked-entry
-- replay, a bulk destroy): the rows are already patched synchronously by the
-- time the signal goes out, so every reader sees fresh rows whichever frame
-- it runs in, and the projection rebuilds once instead of once per entry.
R._countsPending = R._countsPending or nil   -- exception(false-positive): idempotent module-load init
function R:_SignalCounts(decorID)
    local pending = R._countsPending
    if pending then
        pending[#pending + 1] = decorID
        return
    end
    R._countsPending = { decorID }
    _G.RunNextFrame(function()
        local ids = R._countsPending
        R._countsPending = nil
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.COLLECTION_CATALOG_ROW_COUNTS_UPDATED,
            payload = { decorIDs = ids },
        })
    end)
end

-- Decor arrivals. HOUSE_DECOR_ADDED_TO_CHEST names a decor that just arrived,
-- and the HOUSING_STORAGE_ENTRY_UPDATED in the same burst is what flips its row.
-- That event can read Blizzard's counts before they move: Mysterious Imported
-- Piranha stayed at 0 after a vendor purchase until a fresh catalog search
-- (live 12.1.5, 2026-10-18), so nothing ever corrected the row. Once the burst
-- settles, an arrival whose row is still uncollected gets one re-search -- what
-- Blizzard's own dashboard does -- and the warning shows how often it lags. The
-- search runs whether or not the window is open: the merchant marks and the
-- companion read the same rows, and buying at a vendor is mostly done with HDG
-- closed.
R._arrivals            = R._arrivals or nil   -- exception(false-positive): idempotent module-load init
R._arrivalsAfterCommit = R._arrivalsAfterCommit or nil   -- exception(false-positive): idempotent module-load init
function R:NoteDecorArrival(decorID)
    if R._arrivals then
        R._arrivals[#R._arrivals + 1] = decorID
        return
    end
    R._arrivals = { decorID }
    R._arrivalTimer = C_Timer.NewTimer(HDG.Constants.DECOR_ARRIVAL_CHECK_DELAY, function()
        R._arrivalTimer = nil
        local ids = R._arrivals
        R._arrivals = nil
        R:_JudgeArrivals(ids)
    end)
end

function R:_JudgeArrivals(ids)
    -- Not loaded yet: the first load reads the arrival itself.
    if HDG.Store:GetState().session.catalog.status ~= "ready" then return end
    -- A sweep about to commit swaps in a fresh snapshot and replays the parked
    -- entry events: judge against that, not the tables it replaces (judging now
    -- warned falsely and ran a second full sweep behind the first).
    if R:IsSweepPending() then
        local waiting = R._arrivalsAfterCommit or {}
        for _, decorID in ipairs(ids) do waiting[#waiting + 1] = decorID end
        R._arrivalsAfterCommit = waiting
        return
    end
    local stale = {}
    for _, decorID in ipairs(ids) do
        local row = R.byDecorID[decorID]  -- exception(nullable): a decor the catalog has not shown us
        if not (row and row.isOwned) then stale[#stale + 1] = tostring(decorID) end
    end
    if #stale == 0 then return end
    HDG.Log:Warn("catalog_reconcile", string.format(
        "decor %s still uncollected after arriving; re-searching the catalog", table.concat(stale, ", ")))
    R:Refresh("decor-arrival")
end

function R:_JudgeArrivalsAfterCommit()
    local ids = R._arrivalsAfterCommit
    if not ids then return end
    R._arrivalsAfterCommit = nil
    R:_JudgeArrivals(ids)
end

function R:_CancelArrivalTimer()
    R._arrivals = nil
    R._arrivalsAfterCommit = nil
    if R._arrivalTimer then
        R._arrivalTimer:Cancel()
        R._arrivalTimer = nil
    end
end

-- ReconcileEntry(entryVariantID): targeted update from HOUSING_STORAGE_ENTRY_UPDATED.
-- The payload is a HousingCatalogEntryVariantID {recordID, entryType,
-- variantIdentifier} and its recordID IS the identity. The fetched info carries
-- one too, but that field is nil on a just-acquired entry (Reference:
-- HOUSING_CATALOG_API.md), and taking identity from there silently dropped the
-- one learn that mattered -- the one that just happened. Merchant marks stayed
-- red until a fresh session (Gnuclear Gnome, Discord 2026-09-05).
function R:ReconcileEntry(entryID)
    local decorID = type(entryID) == "table" and entryID.recordID  -- exception(boundary): Blizzard event payload
    if not decorID then
        HDG.Log:Warn("catalog_reconcile", "storage entry event carried no recordID: " .. tostring(entryID))
        return
    end
    local wasOwned = _priorOwnership(decorID)
    -- A sweep builds a private snapshot and swaps it in wholesale at settle, so a
    -- patch made now lands in tables about to be replaced. Park the event for
    -- _CommitSweep to replay, keeping wasOwned from BEFORE the swap so the
    -- learned transition survives a snapshot that already shows it owned. That
    -- holds from RunSearch until the commit: a built snapshot waiting out its
    -- settle (_commitPending) is replaced just the same, and _sweepInFlight alone
    -- missed it once two searches overlapped -- the first commit cleared the flag
    -- while the second result set settled, and its swap undid the learn.
    -- Park too when nothing can say yet whether the decor was owned (wasOwned
    -- nil): applied now, a nudge of owned decor would read as a learn.
    if R:IsSweepPending() or wasOwned == nil then
        R._pendingEntries[#R._pendingEntries + 1] = { entryID = entryID, decorID = decorID, wasOwned = wasOwned }
        return
    end
    R:_ApplyEntry(entryID, decorID, wasOwned)
end

function R:_ApplyEntry(entryID, decorID, wasOwned)
    if not (_G.C_HousingCatalog and _G.C_HousingCatalog.GetCatalogEntryInfo) then return end  -- exception(boundary): C_HousingCatalog absent in headless tests
    local info = _G.C_HousingCatalog.GetCatalogEntryInfo(entryID)
    if type(info) ~= "table" then
        HDG.Log:Warn("catalog_error",
            "GetCatalogEntryInfo returned non-table for entryID: " .. tostring(entryID))
        return
    end

    local A        = HDG.Constants.ACTIONS
    local row      = R.byDecorID[decorID]
    local total    = (info.totalNumStored or 0) + (info.remainingRedeemable or 0) + (info.totalNumPlaced or 0)  -- exception(boundary): Blizzard struct field sparse
    local isOwned  = total > 0

    -- New row path: build + ROW_ADDED immediately (don't defer to next full sweep).
    if not row then
        -- BuildRow keys on info.recordID, nil on a just-acquired entry; the event's identity wins.
        info.recordID = decorID
        local newRow = R:BuildRow(info)
        HDG.Store:Dispatch({
            type = A.COLLECTION_CATALOG_ROW_ADDED,
            payload = { decorID = decorID, entry = newRow },
        })
        -- Update local ref so COUNTS_UPDATED sees the new row (wasOwned stays false).
        row = newRow
    end

    if isOwned and not wasOwned then
        HDG.Store:Dispatch({ type = A.COLLECTION_ITEM_LEARNED, payload = { decorID = decorID } })
        -- Record a "learned" craft-history entry for the Your Data tab.
        HDG.Store:Dispatch({
            type    = A.CRAFT_HISTORY_PUSH,
            payload = {
                eventType = "learned",
                itemID    = row.itemID,
                qty       = 1,
                completed = true,
                timestamp = (_G.time and _G.time()) or 0,
            },
        })
    elseif not isOwned and wasOwned then
        HDG.Store:Dispatch({ type = A.COLLECTION_ITEM_REMOVED, payload = { decorID = decorID } })
    end

    -- Patch the mutable count fields + signal the catalog resolver -- on
    -- ownership TRANSITIONS too, not just the counts-only case (this was an
    -- `elseif` that skipped learn/remove -- the screen-update regression).
    --
    -- CRITICAL ORDERING: PatchCounts the row SYNCHRONOUSLY here, THEN signal the
    -- re-render. Catalog selectors (decor.items "only uncollected" filter, detail
    -- status) re-run on the signal and must see the fresh row, or the just-learned
    -- item stays "uncollected" for that frame (the tooltip reads the row live at
    -- hover, AFTER the patch lands -- which is why it showed owned while the list
    -- didn't). Mutate before signalling -> the row is fresh whenever a reader runs.
    -- COUNTS_UPDATED still invalidates session.resolvers.catalog.tick
    -- (signal-only, bump=false: subscribers re-run without the generation
    -- advancing), the path every catalog-derived selector reads (LEARNED/
    -- REMOVED only touch ownedDecorIDs, which those selectors do NOT read).
    -- `row` is always set (built above).
    local counts = _countsOf(info, row)
    local moved = isOwned ~= wasOwned or not _countsMatch(row, counts)
    R:PatchCounts(decorID, counts)
    -- Re-derive dye variants: destroying/acquiring a specific dyed stack changes
    -- per-variant numStored (and can empty a stack). PatchCounts touches only the
    -- base scalars, so without this the list keeps rendering stale variant rows
    -- after a destroy. Mutate before the signal, same ordering as PatchCounts.
    if row.canCustomize and _G.C_HousingCatalog.GetAllVariantInfosForEntry then
        local entryType = info.entryType or 1  -- exception(boundary): Blizzard struct field sparse
        local variants = _G.C_HousingCatalog.GetAllVariantInfosForEntry({
            recordID = decorID, entryType = entryType,
        })
        if type(variants) == "table" then   -- exception(boundary): API returns nil on cold/invalidated cache
            if R:_bakeVariantDyes(row, variants) then moved = true end
        end
    end
    -- Nothing a reader can see moved: no signal, no projection rebuild.
    if not moved then return end
    R:_SignalCounts(decorID)
end

-- ===== Row builder ===========================================================
-- _BuildTagIDIndex: tagID -> groupName map from GetAllFilterTagGroups. Runs once (idempotent).
function R:_BuildTagIDIndex()
    if next(R.tagIDToGroup) then return end  -- idempotency guard (not a defensive nil-check)
    if not (_G.C_HousingCatalog and _G.C_HousingCatalog.GetAllFilterTagGroups) then return end  -- exception(boundary): C_HousingCatalog nil before catalog load
    local groups = _G.C_HousingCatalog.GetAllFilterTagGroups()  -- exception(boundary): C_HousingCatalog nil before catalog load
    if not groups then return end  -- exception(boundary): API may return nil before housing DB loads
    for _, g in ipairs(groups) do
        -- groupName is a LOCALIZED cstring -> _classifyTag's `== "Expansion"` check misses off enUS.
        -- Use the stable groupID; fall back to expansion tag-value detection if Blizzard renumbers.
        local groupKey = HDG.Constants.FILTER_TAG_GROUP_BY_ID[g.groupID]
                      or (HDG.Expansion.IsExpansionTagGroup(g) and "Expansion")
                      or g.groupName
        for _, tag in pairs(g.tags or {}) do
            if tag.tagID and groupKey then
                R.tagIDToGroup[tag.tagID] = groupKey
            end
        end
    end
end

-- The table every BuildRow fills, then copies the stored fields out of. The bakes
-- grow it past 32 hash slots, and a fresh one per row was ~8 MB of garbage per
-- full build (2026-10-20: 4.2 MB for the table, ~3.6 MB regrowing it as the bakes
-- added fields). Wiped first, so a row that errored mid-bake leaves nothing behind.
-- Nothing a bake writes keeps the table itself: the slim row takes its values.
local _fatRow = {}

-- BuildRow: transforms one catalog info table into the enriched row shape.
-- NOT pure: makes boundary calls (dye variants, category names, VendorAugment).
-- Snapshots live state at sweep time; stale until next sweep/reload.
-- Internal callers must never pass nil (strict read -- will throw on nil info).
function R:BuildRow(info)
    local t, hk
    if _sweepProf then t, hk = _G.debugprofilestop(), collectgarbage("count") end
    local row = wipe(_fatRow)
    -- identity
    row.itemID    = info.itemID
    row.decorID   = info.recordID
    -- entryID is composed from these on read (Row shape), not the shim's
    -- backfilled info.entryID.
    row.entryType = info.entryType

    -- catalog scalars
    row.name              = info.name
    row.iconTexture       = info.iconTexture
    row.iconAtlas         = info.iconAtlas
    row.quality           = info.quality
    row.size              = info.size
    row.placementCost     = info.placementCost
    -- Catalog struct may omit the allow-flags; default missing -> allowed
    -- (HDG-verified semantics). Normalized to a strict boolean here so every
    -- consumer (placement label, companion placement) reads it direct.
    row.isAllowedIndoors  = info.isAllowedIndoors  ~= false  -- exception(boundary): catalog API field nil-able
    row.isAllowedOutdoors = info.isAllowedOutdoors ~= false  -- exception(boundary): catalog API field nil-able
    row.canCustomize      = info.canCustomize
    row.isPrefab          = info.isPrefab
    row.isUniqueTrophy    = info.isUniqueTrophy
    row.asset             = info.asset
    row.uiModelSceneID    = info.uiModelSceneID

    -- categorization
    -- Only the FIRST category / subcategory id is read anywhere; the raw
    -- arrays were kept on the row too and pinned Blizzard's per-sweep tables
    -- for the session (2026-09-13 allocation audit). The names are read from
    -- the caches resolved below (Row shape).
    row.categoryID      = info.categoryIDs    and info.categoryIDs[1]  -- exception(boundary): Blizzard struct optional array field
    row.subcategoryID   = info.subcategoryIDs and info.subcategoryIDs[1]  -- exception(boundary): Blizzard struct optional array field

    -- Ownership counters. row.quantity / row.numPlaced KEEP their names (20+ readers)
    -- but source from the 12.0.5 fields -- info.quantity/info.numPlaced were
    -- Blizzard_DeprecatedHousingCatalog backfills, gone when the shim goes
    -- (dump-verified 2026-07-16: totalNumStored=3 on a 3-owned entry).
    row.quantity                 = info.totalNumStored           or 0  -- exception(boundary): Blizzard struct field sparse
    row.numPlaced                = info.totalNumPlaced           or 0  -- exception(boundary): Blizzard struct field sparse
    row.remainingRedeemable      = info.remainingRedeemable      or 0  -- exception(boundary): Blizzard struct field sparse
    row.destroyableInstanceCount = info.destroyableInstanceCount or 0  -- exception(boundary): Blizzard struct field sparse
    row.firstAcquisitionBonus    = info.firstAcquisitionBonus    or 0  -- exception(boundary): Blizzard struct field sparse

    resolveCategoryName(row.categoryID)        -- warm the caches the row's names read
    resolveSubcategoryName(row.subcategoryID)
    if t then t, hk = _lap("rowTable", t, hk) end
    row.dataTagsByID    = _sharedTagSet(info.dataTagsByID)
    if t then t, hk = _lap("tagSet", t, hk) end

    -- Dye variants for customizable items. API takes {recordID, entryType} table arg
    -- (not positional -- exception(boundary): positional args silently errored under old pcall).
    -- The variant array is consumed by _bakeVariantDyes below and never read
    -- again, so it is passed along rather than stored: kept on the row it
    -- pinned one of Blizzard's per-sweep tables per customizable piece for the
    -- whole session (2026-09-13 allocation audit).
    local variants
    if row.canCustomize and _G.C_HousingCatalog
       and _G.C_HousingCatalog.GetAllVariantInfosForEntry then
        local entryType = info.entryType or 1  -- exception(boundary): Blizzard struct field sparse
        local fetched = _G.C_HousingCatalog.GetAllVariantInfosForEntry({
            recordID  = info.recordID,
            entryType = entryType,
        })
        if type(fetched) == "table" then variants = fetched end
        if t then t, hk = _lap("variants", t, hk) end
    end

    -- Parse sourceText into structured vendor/quest/achievement/category/
    -- factionGate fields. Sets row.vendors[], row.quest, row.achievement,
    -- row.category, row.factionGate. Pure; mutates row in place.
    R:_ParseSourceText(info.sourceText or "", row)
    if t then t, hk = _lap("parseSource", t, hk) end

    -- Apply CatalogOverrides. Sparse: most items have no entry, :Get returns nil.
    -- Transparent to selectors: they see corrected rows directly without knowing
    -- overrides were applied.
    local overrides = HDG.StaticData.CatalogOverrides:Get(row.itemID)
    if overrides then
        for k, v in pairs(overrides) do row[k] = v end
    end

    -- Bake derived/display fields onto the row so every consumer sees the
    -- same canonical shape. Each helper is small + focused + idempotent.
    -- Order matters: bakes that depend on others (sourceTags reads the gates
    -- and vendors, costEntries reads the vendors) come after the producers.
    R:_bakeItemAugmentBackfill(row)  -- row.achievement / row.achievementID from aug.sources type=1
    if t then t, hk = _lap("overrides+augment", t, hk) end
    R:_bakeExpansion(row)    -- row.expansion (the tag labels are built on read)
    if t then t, hk = _lap("expansion", t, hk) end
    R:_bakeVendors(row)      -- per-vendor enrichment + vendor records
    if t then t, hk = _lap("vendors", t, hk) end
    R:_bakeCost(row)         -- row.costEntries (unified)
    if t then t, hk = _lap("cost", t, hk) end
    R:_bakeRecipe(row)       -- row.recipe (MUST precede _bakeSourceTypes, which reads
                             -- row.recipe to assign sourceType=6 / CRAFTED)
    R:_bakeSourceTypes(row)  -- row.sourceType (sourceName / sourceDetail are built on read)
    if t then t, hk = _lap("recipe+sourceTypes+bonus", t, hk) end
    R:_bakeVariantDyes(row, variants)  -- row.dyedVariants[] (per-owned-variant dye derivation)
    if t and row.variants then t, hk = _lap("variantDyes", t, hk) end   -- only rows that had variants to walk
    -- Single canonical source/gate bake. Produces row.sourceTags[] in
    -- SOURCE_KIND_PRIORITY order; entries carry text + extras (factionPrefix,
    -- achievementID, ...) for kinds that have them, nothing for chip-only
    -- kinds (DROP, VENDOR, etc.). row.primarySourceCode is a thin derivation
    -- of sourceTags[1] kept for backward-compat consumers; gateLine is built on read.
    R:_bakeSourceTags(row)
    if t then t, hk = _lap("sourceTags", t, hk) end

    local slim = R:_SlimRow(row)
    if t then _lap("slim", t, hk) end
    return slim
end

-- ===== BuildRow bake helpers =================================================
-- Pure; mutate row in place. Run AFTER override merge so override-corrected fields are bake inputs.

-- _bakeItemAugmentBackfill: fill row.achievement + row.achievementID from ItemAugment
-- type=1 sources. Runs before _bakeSourceTypes so downstream sees consistent ach data.
-- The catalog "Achievement:" line gives a name but NEVER an achievementID; ItemAugment
-- is the sole achievementID source -- without it the [ACH] hyperlink has no ID.
-- ItemAugment is the ONLY achievementID source, and it is complete: on 12.1
-- the catalog names an achievement for 184 items and ItemAugment carries the
-- ID for every one (achievement_id_map.lua resolves the catalog names against
-- the Achievement DB2 at rebuild time). 3.31.1 instead asked the live client
-- to match names -- ~4,000 by-index GetAchievementInfo calls -- inside the
-- first sweep, which the owner's /hdgr perf measured at 3,079 of the sweep's
-- 3,168 ms (2026-09-03): the whole "3 s freeze". Names are matched offline
-- now, never in the client.
function R:_bakeItemAugmentBackfill(row)
    local aug = HDG.StaticData.ItemAugment:Get(row.itemID)
    for _, s in ipairs((aug and aug.sources) or {}) do
        if s.type == 1 and s.name and s.name ~= "" then
            -- Name: catalog parse wins for display; only fill when absent.
            if not (row.achievement and row.achievement ~= "") then
                row.achievement = s.name
            end
            -- ID: ItemAugment is the sole source; always backfill.
            row.achievementID = row.achievementID or s.achievementID
        elseif (s.type == 2 or s.type == 3) and s.questID then
            -- Quest/WQ ID(s). ItemAugment is the sole source (catalog gives name, never ID).
            -- Single number or {ids} variant set (A/H); runtime ORs IsQuestFlaggedCompleted.
            row.questID = row.questID or s.questID
        end
    end
end

-- _bakeExpansion: row.expansion, the one tag field a row stores. The sweep runs this
-- and not _bakeTags, whose labels are display text built on read: the sweep built
-- them for every row and the slim copy dropped them. Every Expansion tag is written
-- in turn, as _classifyTag does, so the two agree.
function R:_bakeExpansion(row)
    if not row.dataTagsByID then return end  -- exception(boundary): Blizzard struct field optional
    for tagID, displayName in pairs(row.dataTagsByID) do
        if R.tagIDToGroup[tagID] == "Expansion" then row.expansion = displayName end
    end
end

-- _bakeTags: the tag labels from dataTagsByID, built on read (_bakeDisplay):
--   expansionLabel, sizeLabel, tagsLabel (Styles+Factions). Expansion colors are
--   Palette (scheme-invariant).
-- _classifyTag: inner helper extracted from the loop to keep _bakeTags flat.
local function _classifyTag(row, tagID, displayName, styleFaction, getCategory)
    local group = R.tagIDToGroup[tagID]   -- tagIDToGroup is init'd to {} at load (line ~47), never nil
    if group == "Expansion" then row.expansion = displayName; return end
    if group == "Size"      then row.sizeLabel = displayName; return end
    if getCategory then
        local cat = getCategory(tagID)
        if cat == "Styles" or cat == "Factions" then
            styleFaction[#styleFaction + 1] = displayName
        end
    end
end

function R:_bakeTags(row)
    local styleFaction = {}
    local getCategory = HDG.TagData and HDG.TagData.GetCategory  -- exception(false-positive): HDG.TagData is TOC-guaranteed at runtime; headless test mock omits it
    if row.dataTagsByID then
        for tagID, displayName in pairs(row.dataTagsByID) do
            _classifyTag(row, tagID, displayName, styleFaction, getCategory)
        end
        table.sort(styleFaction)
    end
    row.tagsLabel     = table.concat(styleFaction, ", ")
    -- Palette-colored expansion label (scheme-invariant; safe to bake).
    if row.expansion and row.expansion ~= "" then
        local hex = HDG.Expansion.GetColorHex(row.expansion)
        row.expansionLabel = hex and (hex .. row.expansion .. "|r") or row.expansion
    end
end

-- _bakeCategory: "Accents > Ornamental" breadcrumb.
function R:_bakeCategory(row)
    if row.categoryName and row.subcategoryName then
        row.categoryLabel = row.categoryName .. " > " .. row.subcategoryName
    elseif row.categoryName then
        row.categoryLabel = row.categoryName
    else
        row.categoryLabel = ""
    end
end

-- Icon escapes baked into row labels so detail panels never write |A:...|a.
-- Standardized at 14:14 across all decor labels for consistent visual weight.
local BUDGET_ICON = "|A:house-decor-budget-icon:14:14|a"
local XP_ICON     = "|A:housing-dashboard-icon-xp:14:14|a"

-- _bakePlacement: "<budget-icon> Indoor + Outdoor (3)" / "<budget-icon> Indoor only" / etc.
function R:_bakePlacement(row)
    local where
    if row.isAllowedIndoors and row.isAllowedOutdoors then
        where = "Indoor + Outdoor"
    elseif row.isAllowedIndoors then
        where = "Indoor only"
    elseif row.isAllowedOutdoors then
        where = "Outdoor only"
    else
        where = ""
    end
    if where == "" then row.placementLabel = ""; return end
    if (row.placementCost or 0) > 0 then  -- exception(boundary): catalog struct field sparse
        row.placementLabel = BUDGET_ICON .. " " .. where .. " (" .. row.placementCost .. ")"
    else
        row.placementLabel = BUDGET_ICON .. " " .. where
    end
end

-- _bakeVendors: enrich each vendor with VendorAugment fields (npcID, mapID, x, y,
-- canWaypoint), then link it to its vendor record.
-- _resolveVendorNpc: extracted from loop to keep _bakeVendors flat. It fills one
-- table reused for every vendor and returns it, for _linkVendor to copy from:
-- written onto the parsed entry, the location fields grew it from 8 slots to 16
-- just before _linkVendor copied it and dropped it.
local _resolving = {}
local function _resolveVendorNpc(parsed, Aug)
    local v = _resolving
    for k in pairs(v) do v[k] = nil end
    for k, val in pairs(parsed) do v[k] = val end
    local npcID = Aug and Aug:ResolveName(v.name, v.zone)
    v.npcID       = npcID
    v.canWaypoint = false   -- true only once a location is known (below): an npcID alone maps nowhere
    if not npcID then return v end
    local meta = Aug:Get(npcID)
    if not meta then return v end
    v.canWaypoint = HDG.VendorRank.HasLocation(meta.mapID, meta.x, meta.y)
    v.mapID   = meta.mapID
    v.x       = meta.x
    v.y       = meta.y
    v.faction = v.faction ~= "" and v.faction or (meta.faction or "N")
    -- Allegiance A/H/N, apart from `faction`: the catalog fills that with a REP name
    -- ("Gilneas Liberation Front") whenever the item is rep-gated, so it cannot say
    -- which side may shop here. Picks the decor card's map vendor + the waypoint's
    -- opposite-faction warning.
    v.side    = meta.faction or "N"
    -- VendorAugment is authoritative for vendor location: overwrite the (often
    -- wrong) catalog zone. Vendors not in VendorAugment fall through the early
    -- returns above and keep their catalog zone. This makes the zone filter,
    -- the byVendor index, and the per-item vendor display agree on one zone.
    v.zone    = meta.zone or v.zone
    return v
end

-- What a resolved vendor carries. Its location fields follow from npcID (the
-- VendorAugment row) and `standing` is dropped from the entry, so the other
-- fields are its key. Keyed after resolution because VendorAugment moves vendors
-- the catalog files under the wrong zone: two catalog zones can make one entry.
-- A field outside the list would be left out of the key and merge entries that
-- differ, so it is an error.
local RESOLVED_VENDOR_FIELDS = {
    name = true, zone = true, faction = true, standing = true, cost = true, costEntries = true,
    npcID = true, canWaypoint = true, mapID = true, x = true, y = true, side = true,
}
local function _vendorKey(v)
    for k in pairs(v) do
        if not RESOLVED_VENDOR_FIELDS[k] then
            error(("catalog vendor sharing: field %q is not in the vendor key"):format(tostring(k)), 3)
        end
    end
    return v.name .. "\31" .. v.zone .. "\31" .. v.faction .. "\31" .. _keyPart(v.cost) .. "\31" .. _keyPart(v.npcID)
end

-- The item's price at a vendor, linked to the vendor's record: built once a sweep
-- per resolved vendor, then shared. costEntries keys by identity, which the
-- raw-line memo and _sharedCost make one list per content.
local function _vendorEntry(parsed, Aug)
    local v = _resolveVendorNpc(parsed, Aug)
    local shared = _sweepShared
    if not shared then return _linkVendor(v) end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    local byKey = _child(shared.vendorEntries, v.costEntries or NONE)  -- exception(optional): a block with no priced line has no costEntries
    local key = _vendorKey(v)
    local entry = byKey[key]
    if not entry then
        entry = _linkVendor(v)
        byKey[key] = entry
    end
    return entry
end

local function _sharedVendors(list)
    local shared = _sweepShared
    if not shared then return list end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    return _sharedList(shared.vendorLists, list)
end

-- _dropNotSoldBy: remove the vendors a CatalogOverride `notSoldBy` names. The
-- catalog's sourceText sometimes lists a merchant who does not stock the piece:
-- Ransa Greyfeather is named FIRST on twelve Highmountain pieces that only Torv
-- Dubstomp, a few steps from her in Thunder Totem, sells (reganart, in-game
-- 2026-09-02; Wowhead's merchant scans of both NPCs agree). Two routable
-- vendors tie in VendorRank and keep the catalog's order, so that phantom name
-- won the decor card, the source line and a Shop by Vendor page of its own.
-- Only REMOVAL is curated: the catalog names the real seller itself. Runs after
-- the override-source fold so it sees the whole list, and matches the catalog's
-- English name the way every name in the overrides file does.
local function _dropNotSoldBy(row)
    if not row.notSoldBy then return end  -- exception(optional): sparse override field; most rows have none
    local drop = {}
    for _, who in ipairs(row.notSoldBy) do drop[who] = true end
    local keep = {}
    for _, v in ipairs(row.vendors) do
        if not drop[v.name] then keep[#keep + 1] = v end
    end
    row.vendors = keep
end

function R:_bakeVendors(row)
    -- Fold CatalogOverride vendors (row.sources type=5) into row.vendors so the whole
    -- pipeline -- the zone/faction filters, the per-item vendor display, AND the byVendor
    -- index -- sees ONE complete vendor list (catalog + override-supplied vendors). The
    -- resolve loop below then stamps their npcID/zone from VendorAugment like any vendor.
    if row.sources then
        for _, s in ipairs(row.sources) do
            if s.type == 5 and s.name and s.name ~= "" then
                row.vendors = row.vendors or {}
                row.vendors[#row.vendors + 1] = { name = s.name, zone = s.detail or "", faction = "", standing = "" }
            end
        end
    end
    if not row.vendors then row.vendors = _sharedVendors({}); return end
    _dropNotSoldBy(row)
    local Aug = HDG.StaticData.VendorAugment
    for i, v in ipairs(row.vendors) do
        row.vendors[i] = _vendorEntry(v, Aug)   -- price here + the vendor's record
    end
    row.vendors = _sharedVendors(row.vendors)
end

-- _bakeVariantDyes: per-owned-dyed-variant display data baked once at sweep time.
-- Emits row.dyedVariants[]: { variantIdentifier, numStored, dyeColorsByChannel (sparse
-- 0/1/2), dyeColorIDs (flat), label, entryID }. entryID is what
-- C_HousingBasicMode.StartPlacingNewDecor takes to place the dyed copy.
-- Same dyed-variant list, entry for entry: identity, stored count and label.
local function _sameDyedVariants(a, b)
    if (a == nil) ~= (b == nil) then return false end
    if a == nil or #a ~= #b then return a == nil end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if x.variantIdentifier ~= y.variantIdentifier or x.numStored ~= y.numStored
           or x.label ~= y.label then
            return false
        end
    end
    return true
end

-- Returns true when the bake changed anything a reader can see (the undyed
-- count or the dyed-variant list), so a storage event that moved nothing
-- can skip the re-render signal.
function R:_bakeVariantDyes(row, variants)
    if not variants then return false end
    local undyedBefore, dyedBefore = row.undyedNumStored, row.dyedVariants
    local dyed = {}
    -- Undyed base variant (variantIdentifier 0) is a first-class tile in Blizzard's
    -- catalog with its OWN numStored -- captured here so the base row reads its real
    -- undyed count, never the aggregate destroyableInstanceCount (off-by-one on the base).
    row.undyedNumStored = 0
    for _, v in ipairs(variants) do
        if v.entryVariantID.variantIdentifier == 0 then
            row.undyedNumStored = v.numStored
        end
        if v.numStored > 0 then
            local byChannel, names = {}, {}
            for _, slot in ipairs(v.dyeSlots) do
                if slot.dyeColorID then
                    byChannel[slot.channel] = slot.dyeColorID
                    local dci = R:GetDyeColorInfo(slot.dyeColorID)
                    if dci and dci.name then names[#names + 1] = dci.name end
                end
            end
            if next(byChannel) then
                local flat = {}
                for ch = 0, 2 do
                    if byChannel[ch] then flat[#flat + 1] = byChannel[ch] end
                end
                dyed[#dyed + 1] = {
                    variantIdentifier  = v.entryVariantID.variantIdentifier,
                    numStored          = v.numStored,
                    dyeColorsByChannel = byChannel,
                    dyeColorIDs        = flat,
                    label              = #names > 0 and table.concat(names, ", ") or "Dyed",
                    entryID            = v.entryVariantID,
                }
            end
        end
    end
    row.dyedVariants = dyed
    return row.undyedNumStored ~= undyedBefore or not _sameDyedVariants(dyedBefore, dyed)
end

-- _bakeCost: unify vendor cost + override source cost into row.costEntries
-- ({currencyID, amount} entries); costLine and costVariants are derived on read.

-- gold(copper) + currency list -> normalized {currencyID, amount} entries.
-- Override-sourced costs carry no icon of their own. Resolve it HERE, at the observer
-- bake, rather than leaving it to the renderer: an icon-less entry made Format.FormatCurrency
-- fall through to a live C_CurrencyInfo call, and blueprints.costBadge is a pure selector
-- with no resolver tick to re-derive it (review 2026-08-23). Format.lua's own header scopes
-- that fallback to "observer bake, not selector" -- this is the bake.
local function _currencyIcon(currencyID)
    local CI = _G.C_CurrencyInfo  -- exception(boundary): absent in headless tests
    if not (CI and CI.GetCurrencyInfo) then return nil end
    local info = CI.GetCurrencyInfo(currencyID)
    return info and info.iconFileID  -- exception(boundary): nil for an unknown currencyID
end

local function _entriesFromCostSpec(cost, GOLD)
    local entries = {}
    if cost.gold and cost.gold > 0 then
        entries[#entries + 1] = { currencyID = GOLD, amount = math.floor(cost.gold / 10000) }
    end
    if cost.currencies then
        for _, c in ipairs(cost.currencies) do
            entries[#entries + 1] = { currencyID = c.id, amount = c.amount, icon = _currencyIcon(c.id) }
        end
    end
    return entries
end

-- Catalog cost: the entries _extractCostEntries lifted from the RAW Cost: line
-- (currency links, item-token links, the gold money icon) -- and nothing else.
-- The bare-digits-means-gold fallback that used to sit here is how 25 item-token
-- prices shipped as gold: StripHyperlinks reduces ANY unknown link to its digits,
-- so "no entries but digits" is an unparsed shape, not a price. It must surface
-- as no cost so the parser gets taught the shape, never as a plausible number.
-- The vendor's own list, not a copy: nothing writes into an entries list once it is
-- built, and the copy was the whole cost stage (759 KB a build, 2026-10-21 profile).
local function _costFromVendor(vendor)
    if not vendor then return nil end  -- exception(nullable): row.vendors[1] on a vendorless row
    if not (vendor.costEntries and #vendor.costEntries > 0) then return nil end  -- exception(nullable): priceless vendor block
    return vendor.costEntries
end

-- Override fallback (only when catalog has no cost). First source with a .cost wins.
local function _costFromOverrideSources(sources, GOLD)
    if not sources then return nil end
    for _, s in ipairs(sources) do
        if s.cost then return _entriesFromCostSpec(s.cost, GOLD) end
    end
    return nil
end

local function _formatCostLine(entries)
    if not (entries and #entries > 0) then return "" end
    local parts = {}
    for _, e in ipairs(entries) do
        local s = HDG.Format.FormatCost(e.amount, e)
        if s ~= "" then parts[#parts + 1] = s end
    end
    return table.concat(parts, "  +  ")
end

-- Order-independent key for a cost-entry set (dedup distinct payment options).
local function _costKey(entries)
    local parts = {}
    for _, e in ipairs(entries) do
        parts[#parts + 1] = HDG.Format.CostKey(e) .. "=" .. tostring(e.amount)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- Distinct cost variants across all vendor blocks (e.g. 30 coupons OR 500g = two options).
-- headEntries / headLine are the head vendor's entries and formatted line that
-- _costVariantsOf already built (nil when the head vendor carries no price), so the
-- head is not copied and formatted a second time just to be hashed; and a row
-- with one vendor can only ever yield that one line, so it skips the dedup pass
-- entirely -- two thirds of the catalog (2026-09-13 allocation audit).
local function _costVariants(row, headEntries, headLine)
    local vendors = row.vendors
    local n = vendors and #vendors or 0
    if n <= 1 then
        if headEntries and #headEntries > 0 then return { headLine } end
        return {}
    end
    local lines, seen = {}, {}
    for i = 1, n do
        local entries = (i == 1) and headEntries or _costFromVendor(vendors[i])
        if entries and #entries > 0 then
            local key = _costKey(entries)
            if not seen[key] then
                seen[key] = true
                lines[#lines + 1] = (i == 1) and headLine or _formatCostLine(entries)
            end
        end
    end
    return lines
end

-- A shared vendor entry with another price: a copy, linked to the same record.
local function _repricedVendor(v, entries)
    local copy = {}
    for k, val in pairs(v) do copy[k] = val end
    copy.costEntries = entries
    return setmetatable(copy, getmetatable(v))
end

function R:_bakeCost(row)
    local GOLD   = HDG.Constants.CURRENCY_GOLD
    -- Explicit CatalogOverrides `costOverride` wins: Blizzard's catalog sourceText
    -- lags merchant hotfixes (MOTHER's Chamber of Heart items shipped 100000 in the
    -- catalog while the vendor charged 10000). Stamp it onto every vendor so the
    -- vendor list, cost line, and variants all agree. Remove when the catalog is fixed.
    -- The vendor entries are shared with other rows, so the price goes on copies.
    if row.costOverride then
        local oe = _sharedCost(_entriesFromCostSpec(row.costOverride, GOLD))
        local priced = {}
        for i, v in ipairs(row.vendors) do priced[i] = _repricedVendor(v, oe) end
        row.vendors = priced
        row.costEntries = oe
        return
    end
    row.costEntries = _costFromVendor(row.vendors[1]) or _sharedCost(_costFromOverrideSources(row.sources, GOLD) or {})
end

-- costLine / costVariants: built on read (see Row shape) from what _bakeCost left.
local function _costLineOf(row)
    return _formatCostLine(row.costEntries)
end

-- Per-option lines (>=1 when any cost); several drive the vendor list to show the
-- item once per option. Only the VENDOR-derived head feeds the variants: an
-- override-sourced cost is not a vendor option.
local function _costVariantsOf(row)
    local line = _formatCostLine(row.costEntries)
    if row.costOverride then return { line } end   -- exception(nullable): sparse override field
    local head = _costFromVendor(row.vendors[1])
    local variants = _costVariants(row, head, head and line or nil)
    if #variants == 0 and line ~= "" then variants = { line } end
    return variants
end

-- Map ItemAugment minRep to display string. Convention: 4=Neutral…8=Exalted, 9+=Renown.
local function _repStandingFromMinRep(minRep)
    if not minRep or minRep <= 0 then return nil end
    if minRep == 4 then return "Neutral"     end
    if minRep == 5 then return "Friendly"    end
    if minRep == 6 then return "Honored"     end
    if minRep == 7 then return "Revered"     end
    if minRep == 8 then return "Exalted"     end
    if minRep >= 9 then return "Renown " .. tostring(minRep - 8) end
    return nil
end

-- Reverse map: standing string -> numeric code. Used when only catalog factionGate.standing
-- is available (no aug.minRep). Built lazily; FACTION_STANDING_LABEL globals are ready by load.
local _STANDING_TO_CODE = nil
local function _standingStringToCode(s)
    if not s or s == "" then return 0 end
    if not _STANDING_TO_CODE then
        _STANDING_TO_CODE = {}
        for i = 1, 8 do
            local lbl = _G["FACTION_STANDING_LABEL" .. i]
            if lbl then _STANDING_TO_CODE[lbl] = i end
        end
        for n = 1, 40 do _STANDING_TO_CODE["Renown " .. n] = 8 + n end
    end
    return _STANDING_TO_CODE[s] or 0
end

-- Rep progress lives in HDG.RepObserver:GetProgress (dynamic state; stale if baked at sweep).

-- factionName -> factionID lookup via the static HDG.Constants.REP_FACTIONS
-- table. Catalog factionGate carries only the localized faction name; this
-- maps it to a factionID the C_Reputation APIs can act on. The constants
-- table was built from a Rep Scan (Alliance + Horde merged) + wago.tools
-- Faction.db2 fill-in. Pure table lookup -- no rep-pane walk, no UI taint.
local function _factionIDByName(name)
    if not name or name == "" then return nil end
    local M = HDG.Constants.REP_FACTION_BY_NAME
    return M[name] or M[string.lower(name)]
end


-- Player-faction crest atlases. Prepended to REP gates whose rep-faction is
-- Alliance- or Horde-only (per HDG.Constants.REP_FACTIONS[factionID].faction)
-- so an Alliance char looking at Honorbound decor sees the Horde crest as a
-- visual "you can't earn this rep" cue. Neutral rep-factions get no prefix.
local _FACTION_ATLAS_ALLIANCE = "|A:communities-create-button-wow-alliance:14:14|a"
local _FACTION_ATLAS_HORDE    = "|A:communities-create-button-wow-horde:14:14|a"
local function _factionPrefixFor(factionID)
    if not factionID then return nil end
    local e = HDG.Constants.REP_FACTIONS[factionID]
    if not e then return nil end
    if e.faction == "A" then return _FACTION_ATLAS_ALLIANCE end
    if e.faction == "H" then return _FACTION_ATLAS_HORDE    end
    return nil
end

-- _composeRepProgressSuffix lives in HDG.Format (live progress via detail-panel selector + RepObserver).

-- "Source (Zone)" for the drop/treasure/event records _ParseSourceText stamps.
-- Module scope because BOTH source bakes want it: _bakeSourceTags for the chip
-- and _bakeSourceTypes for the headline.
local function _sourceWithZone(source, zone)
    if zone and zone ~= "" then return source .. " (" .. zone .. ")" end  -- exception(optional): curated sources and drop records may name no zone
    return source
end

local function _composeSourceText(rec)
    if not rec then return nil end   -- exception(nullable): row carries only the source kinds it has
    return _sourceWithZone(rec.source, rec.zone)
end

-- Curated source type -> SOURCE_KINDS entry, shared by both bakes. WorldQuest
-- (3) chips and headlines as QUEST; Profession (11) belongs to the recipe DB and
-- yields nothing here. Any other code must be a donor code: a curated source
-- carrying one the table does not know is data drift, and errors.
local function _kindForSourceType(code)
    if code == 3  then return HDG.Constants.SOURCE_KIND_BY_KEY.QUEST end
    if code == 11 then return nil end
    local kind = HDG.Constants.SOURCE_KIND_BY_DONOR[code]
    if not kind then
        error(("curated source type %s has no SOURCE_KINDS entry"):format(tostring(code)))
    end
    return kind
end

-- The first curated source that can stand as the headline: CatalogOverrides
-- first (they are the corrections), then ItemAugment. Vendors are skipped
-- because VendorRank already chose among them once _bakeVendors folded the
-- override vendors in, and Craft because _bakeRecipe answers it. Returns the
-- source and its kind, or nothing.
local function _curatedHeadline(row)
    local aug = HDG.StaticData.ItemAugment:Get(row.itemID)
    -- exception(nullable): both stores are sparse; no entry is the common case
    for _, list in ipairs({ row.sources or {}, aug and aug.sources or {} }) do
        for _, src in ipairs(list) do
            local kind = _kindForSourceType(src.type)
            if kind and kind.key ~= "VENDOR" and kind.key ~= "CRAFT" then
                return src, kind
            end
        end
    end
    return nil
end

-- _bakeSourceTypes: the "Source: X" label -- one concrete answer to "where do I
-- get this?". Priority: Vendor > Quest > Ach > Crafted.
--
-- Vendor leads because it is the only one of the four that is still true for the
-- reader. A quest or achievement a piece once came from is spent the moment it
-- is done, and for anyone reading a published blueprint list it may never have
-- been available at all -- but the vendor is standing in a zone they can fly to
-- today. This is the same concrete-primary convention the curated master keeps
-- (HDG_AllDecorDB: vendor primary, quest/ach demoted to `alt`), so the live-
-- catalog bake and the master now agree.
--
-- Distinct from _bakeSourceTags, which stays binding-strength ordered (REP >
-- CRAFT > QUEST > ...) -- gate chips answer "what stops me", not "where is it".
function R:_bakeSourceTypes(row)
    -- nil preference: one baked row serves every player, so the neighborhood
    -- toggle cannot be frozen in here. The pick still demotes the unroutable
    -- groupings, which is what "Vendor: World Vendors" over a named merchant was.
    local bestVendor = HDG.VendorRank.Pick(row, nil)
    if bestVendor then
        -- Vendor: surface the vendor's name (Hesta Forlath) and zone
        -- (Silvermoon City) in the label. Detail-panel renders as
        --   [VEND] Hesta Forlath (Silvermoon City)
        row.sourceType, row.sourceName = 5, bestVendor.name or ""
        row.sourceDetail              = bestVendor.zone or ""
    elseif row.quest then
        row.sourceType, row.sourceName = 2, row.quest
    elseif row.achievement then
        row.sourceType, row.sourceName = 1, row.achievement
    elseif row.recipe then
        row.sourceType, row.sourceName = 6, row.recipe.expansion or ""
    -- Drop/Treasure/Event were parsed and chipped but never made it into the
    -- HEADLINE, so a delve-only piece fell through to UNKN(0) -- and the plain-
    -- text manifest drops UNKN lines rather than stamp "Unknown" on every
    -- unbaked row. That is why Hanging Dawnflower read "[DROP] Midnight Delves"
    -- in Find Decor and carried no source at all into a copied blueprint list.
    elseif row.drop then
        row.sourceType, row.sourceName = 4, _composeSourceText(row.drop)
    elseif row.treasure then
        row.sourceType, row.sourceName = 9, _composeSourceText(row.treasure)
    elseif row.event then
        row.sourceType, row.sourceName = 14, _composeSourceText(row.event)
    -- Shop and Promotion are the catalog's two BARE lines: it says the piece
    -- comes from the in-game shop or a promotion and names nothing further,
    -- so these carry a kind with no name. The label IS the whole answer, which
    -- is why the manifest prints them without a trailing "name" clause.
    elseif row.shop then
        row.sourceType, row.sourceName = 12, ""
    elseif row.promo then
        row.sourceType, row.sourceName = 10, ""
    else
        -- Nothing in the catalog's own text. Only curated VENDORS reached this
        -- label before (through _bakeVendors and VendorRank), so a quest or a
        -- drop the catalog never mentions -- the Elodor Barrel's missive, the
        -- Last Architect's weekly gift -- chipped [QUST] or [DROP] and then named
        -- nothing: in the Decor panel, the catalog tooltip and a copied blueprint
        -- list alike (KevinW on CurseForge, 2026-09-09). The curated source is
        -- the answer the chip was already pointing at.
        local src, kind = _curatedHeadline(row)
        if src then
            row.sourceType = kind.donorCode
            -- exception(optional): a bare curated source carries a kind and no name, like the catalog's Shop/Promotion lines
            row.sourceName = src.name and _sourceWithZone(src.name, src.detail) or ""
        else
            row.sourceType, row.sourceName = 0, ""
        end
    end
end

-- _bakeSourceTags: canonical source/gate bake. Produces:
--   row.sourceTags[] -- SOURCE_KIND_PRIORITY-ordered list of { kind, text?, ... }
--   row.primarySourceCode -- donor code of sourceTags[1].kind (HDG-compat)
-- DROP fallback when no other signal exists (chip rendering always has something).
-- Aug code 11 (PROFESSION) and 3 (WorldQuest->QUEST) handled as edge cases.
-- _repTagEntry: extracts REP entry; static gate only (live progress via RepObserver).
-- The two shapes, each a function of the inputs _sharedRep keys it by.
local function _repFromGate(factionName, standing, factionID)
    return {
        kind          = "REP",
        text          = (standing ~= "") and (standing .. " with " .. factionName) or factionName,
        factionName   = factionName,
        standing      = standing,
        factionID     = factionID,
        requiredCode  = _standingStringToCode(standing),
        factionPrefix = _factionPrefixFor(factionID),
    }
end

local function _repFromAugment(factionName, minRep, factionID)
    local standing = _repStandingFromMinRep(minRep) or ""
    return {
        kind          = "REP",
        text          = (standing ~= "") and (standing .. " with " .. factionName) or factionName,
        factionName   = factionName,
        standing      = standing,
        factionID     = factionID,
        minRep        = minRep,
        requiredCode  = minRep,   -- ItemAugment minRep IS the standing code
        factionPrefix = _factionPrefixFor(factionID),
    }
end

-- Source tags are shared across rows, keyed per kind by what they are built from.
-- `shape` names the builder in the key, so the two REP shapes never meet.
local function _sharedRep(build, shape, factionName, rank, factionID)
    local shared = _sweepShared
    if not shared then return build(factionName, rank, factionID) end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    local byInputs = _child(shared.tags, "REP")
    local key = shape .. "\31" .. factionName .. "\31" .. _keyPart(rank) .. "\31" .. _keyPart(factionID)
    local tag = byInputs[key]
    if not tag then
        tag = build(factionName, rank, factionID)
        byInputs[key] = tag
    end
    return tag
end

-- { kind } plus up to two fields, absent when nil: a nil written in a table
-- constructor still takes a slot in 5.1. A kind always carries the same fields,
-- so the kind and the two values are the key.
local function _newTag(kind, f1, v1, f2, v2)
    local tag = { kind = kind }
    if v1 ~= nil then tag[f1] = v1 end
    if v2 ~= nil then tag[f2] = v2 end
    return tag
end

local function _sharedTag(kind, f1, v1, f2, v2)
    local shared = _sweepShared
    if not shared then return _newTag(kind, f1, v1, f2, v2) end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    local byInputs = _child(shared.tags, kind)
    local key = _keyPart(v1) .. "\31" .. _keyPart(v2)
    local tag = byInputs[key]
    if not tag then
        tag = _newTag(kind, f1, v1, f2, v2)
        byInputs[key] = tag
    end
    return tag
end

local function _repTagEntry(row, aug)
    local fg = row.factionGate
    if fg and fg.factionName and fg.factionName ~= "" then
        local factionID = (aug and aug.factionID) or _factionIDByName(fg.factionName)
        return _sharedRep(_repFromGate, "gate", fg.factionName, fg.standing or "", factionID)
    end
    if aug and aug.factionName and aug.factionName ~= "" then
        return _sharedRep(_repFromAugment, "augment", aug.factionName, aug.minRep, aug.factionID)
    end
    if aug and aug.factionID then return _sharedTag("REP") end   -- chip-only REP
    return nil
end

-- One source kind per row at most; the first contribution wins (catalog signal
-- before augment before override, in call order below). The kinds collect in one
-- table reused for every row, emptied as each bake starts: only the sorted list is
-- kept, and the sweep runs this 2,308 times.
local _tagByKind = {}
local function _emitSourceTag(kind, tag)
    if not kind or _tagByKind[kind] then return end
    _tagByKind[kind] = tag
end

-- The row's tags in SOURCE_KIND_PRIORITY order, and the one shared list for that
-- sequence: walked through the trie first, so a repeat builds no list.
local function _tagListOf(byKind)
    local tags = {}
    for _, key in ipairs(HDG.Constants.SOURCE_KIND_PRIORITY) do
        if byKind[key] then tags[#tags + 1] = byKind[key] end
    end
    return tags
end

local function _sharedTagList(byKind)
    local shared = _sweepShared
    if not shared then return _tagListOf(byKind) end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    local node = shared.tagLists
    for _, key in ipairs(HDG.Constants.SOURCE_KIND_PRIORITY) do
        local tag = byKind[key]
        if tag then node = _child(node, tag) end
    end
    local hit = node[LEAF]
    if not hit then
        hit = _tagListOf(byKind)
        node[LEAF] = hit
    end
    return hit
end

function R:_bakeSourceTags(row)
    local aug = HDG.StaticData.ItemAugment:Get(row.itemID)
    local byKind = _tagByKind   -- {[kind] = entry} -- dedupes per-kind contributions
    for k in pairs(byKind) do byKind[k] = nil end

    local repEntry = _repTagEntry(row, aug)
    if repEntry then _emitSourceTag("REP", repEntry) end

    -- Catalog-derived gates (text-carrying).
    if row.quest and row.quest ~= "" then
        _emitSourceTag("QUEST", _sharedTag("QUEST", "text", row.quest))
    end
    if row.achievement and row.achievement ~= "" then
        _emitSourceTag("ACH", _sharedTag("ACH", "text", row.achievement, "achievementID", row.achievementID))
    end
    if row.recipe and row.recipe.expansion and row.recipe.expansion ~= "" then
        _emitSourceTag("CRAFT", _sharedTag("CRAFT", "text", row.recipe.expansion, "profession", row.recipe.profession))
    elseif row.recipe then
        -- Recipe present but no expansion string -- chip-only CRAFT.
        _emitSourceTag("CRAFT", _sharedTag("CRAFT"))
    end

    -- Non-gating signals: chip-only or "Source (Zone)" when descriptor text exists.
    -- Drop/Treasure/Event come from _ParseSourceText (stamps row.drop/treasure/event).
    if row.vendors and #row.vendors > 0 then _emitSourceTag("VENDOR", _sharedTag("VENDOR")) end
    if row.drop      then _emitSourceTag("DROP",     _sharedTag("DROP",     "text", _composeSourceText(row.drop)))     end
    if row.treasure  then _emitSourceTag("TREASURE", _sharedTag("TREASURE", "text", _composeSourceText(row.treasure))) end
    if row.event     then _emitSourceTag("EVENT",    _sharedTag("EVENT",    "text", _composeSourceText(row.event)))    end
    if row.shop      then _emitSourceTag("SHOP",     _sharedTag("SHOP"))  end   -- catalog bare "Shop"/"In-Game Shop" line
    if row.promo     then _emitSourceTag("PROMO",    _sharedTag("PROMO")) end   -- catalog bare "Promotion" line

    -- ItemAugment signals: catalog-undetectable kinds (SHOP/PROMO/TREASURE/DROP/etc).
    -- VENDOR is chip-only. _emitSourceTag() dedupes per kind (catalog signal wins).
    if aug and aug.sources then
        for _, s in ipairs(aug.sources) do
            local kind = _kindForSourceType(s.type)
            local k = kind and kind.key
            if k == "VENDOR" then
                _emitSourceTag(k, _sharedTag(k))
            elseif k then
                local txt = (s.name and s.name ~= "")
                    and _sourceWithZone(s.name, s.detail) or nil
                _emitSourceTag(k, _sharedTag(k, "text", txt))
            end
        end
    end

    -- CatalogOverrides sources (row.sources): real vendor/source for placeholder
    -- catalog entries (Chel the Chip, Disguised Decor Duel Vendor etc -> else [DROP]).
    -- VENDOR chip-only; other kinds carry the override's name+zone text.
    if row.sources then
        for _, s in ipairs(row.sources) do
            local kind = _kindForSourceType(s.type)
            local k = kind and kind.key
            if k == "VENDOR" then
                _emitSourceTag(k, _sharedTag(k))
            elseif k then
                local txt = s.name and _sourceWithZone(s.name, s.detail) or nil
                _emitSourceTag(k, _sharedTag(k, "text", txt))
            end
        end
    end

    -- No source signal at all -> honest chip-only [UNKN], never [DROP].
    -- Defaulting to DROP masked catalog/data gaps; UNKN surfaces them (and is
    -- filterable). DROP now appears only when the data actually says "Drop:".
    if next(byKind) == nil then _emitSourceTag("UNKN", _sharedTag("UNKN")) end

    -- Sort by SOURCE_KIND_PRIORITY; head entry is highest-priority kind (primarySourceCode, gateLine on read).
    local tags = _sharedTagList(byKind)
    row.sourceTags = tags

    -- Derived single-value field for back-compat.
    local head = tags[1]
    row.primarySourceCode = (head and HDG.Constants.SOURCE_KIND_BY_KEY[head.kind].donorCode) or 0
end

-- Compact "[CHIP]  text" from the head source tag, with the faction crest when it
-- has one; nil for a chip-only head. Display text, so only _bakeDisplay builds it:
-- the sweep built one per row and the slim copy dropped it.
local function _gateLineOf(head)
    if not (head and head.text) then return nil end  -- exception(nullable): a chip-only head carries no text
    local prefix = head.factionPrefix and (head.factionPrefix .. " ") or ""
    return prefix .. HDG.Format.SourceChip(head.kind) .. "  " .. head.text
end


-- _bakeRecipe: cross-join with StaticData.Recipes. row.recipe nil when not crafted.
function R:_bakeRecipe(row)
    local Recipes = HDG.StaticData.Recipes
    if not Recipes then row.recipe = nil; return end
    row.recipe = Recipes:Get(row.itemID)   -- exception(nullable): most decor is not crafted
end

-- ===== Row shape =============================================================
-- A row stores what the hot loops and the in-place writers need. Display text and
-- a few derived values are built when read, through one shared metatable, so a row
-- fits in 32 hash slots instead of 64 (memory census 2026-10-19: rows held 8.7 MB
-- at 2,307 decor). pairs(row) sees the stored fields only.

-- Nothing reads these once the row is built.
local ROW_DROPPED = {
    size = true, isPrefab = true, asset = true, uiModelSceneID = true, category = true,
    tags = true, zone = true, notSoldBy = true, vendorLines = true, recipeLabel = true,
}

-- Built on every read: cheap, or made from values that change (the counts). A derived
-- read must touch stored fields only, or every such read would build display text.
local ROW_DERIVED = {
    -- variantIdentifier 0 = the base stack, the destroy identity default; dyed
    -- variants carry Blizzard's own entryVariantID (_bakeVariantDyes).
    entryID = function(row)
        return { recordID = row.decorID, entryType = row.entryType, variantIdentifier = 0 }
    end,
    isOwned = function(row) return R:IsOwned(row) end,
    -- Cache only: BuildRow resolves the names, and a selector read must not reach
    -- Blizzard. A miss reads nil until a later sweep resolves it, as before.
    categoryName    = function(row) return _categoryNameCache[row.categoryID] end,
    subcategoryName = function(row) return _subcategoryNameCache[row.subcategoryID] end,
    -- First-acquisition XP chip; the consumer gates it on ownership.
    bonusXpLabel = function(row)
        local fab = row.firstAcquisitionBonus
        if fab > 0 then return XP_ICON .. " +" .. fab .. " XP" end
        return nil
    end,
    costLine     = _costLineOf,
    costVariants = _costVariantsOf,
}

-- Built once per row on first read, by the same bakes BuildRow runs, over a view
-- that reads the row's stored and derived fields and keeps the bakes' writes. Only
-- cold readers (detail panels, tooltips) ask, so few rows ever build it. Weak keys:
-- a row from an older sweep takes its text with it; the cached table holds strings
-- only, never the row.
local ROW_DISPLAY = {
    expansionLabel = true, sizeLabel = true, tagsLabel = true, categoryLabel = true,
    placementLabel = true, gateLine = true, sourceName = true, sourceDetail = true,
}
local _display = setmetatable({}, { __mode = "k" })
R._rowDisplay = _display   -- read by the memory census (HDGProbe /hdgmem catalog)

local function _bakeDisplay(row)
    local view = setmetatable({}, { __index = function(_, key)
        local v = rawget(row, key)
        if v ~= nil then return v end
        local derive = ROW_DERIVED[key]
        return derive and derive(row)
    end })
    R:_bakeTags(view)
    R:_bakeCategory(view)
    R:_bakePlacement(view)
    R:_bakeSourceTypes(view)
    view.gateLine = _gateLineOf(row.sourceTags[1])
    local out = {}
    for key in pairs(ROW_DISPLAY) do out[key] = rawget(view, key) end
    return out
end

local ROW_META = {
    __index = function(row, key)
        local derive = ROW_DERIVED[key]
        if derive then return derive(row) end
        if not ROW_DISPLAY[key] then return nil end
        local text = _display[row]
        if not text then
            text = _bakeDisplay(row)
            _display[row] = text
        end
        return text[key]
    end,
    -- Writing a dropped, derived or display field would re-grow the row and hide the
    -- derived value, so it is an error. New stored fields (dye counts) go through.
    __newindex = function(row, key, value)
        if ROW_DROPPED[key] or ROW_DERIVED[key] or ROW_DISPLAY[key] then
            error(("catalog row field %q is derived or retired and cannot be written"):format(tostring(key)), 2)
        end
        rawset(row, key, value)
    end,
}

-- The built row copied into a table holding only stored fields: the fat one is
-- sized for every bake's output, and Lua never shrinks a table.
function R:_SlimRow(fat)
    local row = {}
    for key, value in pairs(fat) do
        if not (ROW_DROPPED[key] or ROW_DERIVED[key] or ROW_DISPLAY[key]) then row[key] = value end
    end
    return setmetatable(row, ROW_META)
end

-- _ParseSourceText: extract Vendor:/Zone:/Faction:/Cost:/Quest:/Achievement:/Category:
-- lines. Multi-vendor items repeat the Vendor/Zone/Faction/Cost block.
-- row.factionGate = first Faction: line; selectors fall back to ItemAugment if absent.
--
-- _extractCostEntries: parse cost entries from the RAW Cost: line --
-- { currencyID, amount, icon } for |Hcurrency: links and the gold money icon,
-- { itemID, amount, icon } for |Hitem: links (Format.CostKey/FormatCost/CostName
-- read the distinction). MUST be raw (not SHL-stripped) -- SHL nukes the |H..|h
-- wrappers, leaving bare digits that say nothing about what they count.
-- The catalog-embedded icon is always correct; avoids a stale hand-curated table
-- and won't drop currencies outside it (boundary: any currency in Cost: IS a decor cost).
-- Runs on every Cost: line of every row at sweep time. Each link shape is
-- looked for with one plain find before its patterns run: a line carrying gold
-- only paid for two link tables and four iterators it could not use, and the
-- gold match copied the whole line to lowercase (2026-09-13 allocation audit).
-- Output is identical; tests/test_catalog_cost_itemtoken.lua and
-- tests/test_acquire_costvariants.lua pin the entry shapes.
local function _extractCostEntries(raw)
    local entries = {}
    if raw:find("|Hcurrency:", 1, true) then
        local iconByID = {}
        for cid, icon in raw:gmatch("|Hcurrency:(%d+)|h|T([^:|]+)") do
            iconByID[tonumber(cid)] = icon
        end
        for amt, cid in raw:gmatch("([%d,]+)%s*|Hcurrency:(%d+)|h") do
            local n  = tonumber((amt:gsub(",", "")))
            local id = tonumber(cid)
            if n and id then
                entries[#entries + 1] = { currencyID = id, amount = n, icon = iconByID[id] }
            end
        end
    end
    -- Item tokens: "1|Hitem:137642|h|T<icon>:0|t|h" (Mark of Honor, Dreamsurge
    -- Coalescence, ...). Same shape as the currency loop with the item's own ID;
    -- an item is not a currency, so the entry carries itemID and no currencyID.
    if raw:find("|Hitem:", 1, true) then
        local itemIconByID = {}
        for iid, icon in raw:gmatch("|Hitem:(%d+)|h|T([^:|]+)") do
            itemIconByID[tonumber(iid)] = icon
        end
        for amt, iid in raw:gmatch("([%d,]+)%s*|Hitem:(%d+)|h") do
            local n  = tonumber((amt:gsub(",", "")))
            local id = tonumber(iid)
            if n and id then
                entries[#entries + 1] = { itemID = id, amount = n, icon = itemIconByID[id] }
            end
        end
    end
    -- Gold is a money texture ("<amt>|TInterface\MoneyFrame\UI-GoldIcon...|t"), NOT a
    -- |Hcurrency: link, so the loop above misses it -- an item can charge a currency AND
    -- gold (e.g. 2000 Order Resources + 1000g). Match the gold icon case-folded in
    -- place and emit a GOLD entry.
    if raw:find("[Mm][Oo][Nn][Ee][Yy][Ff][Rr][Aa][Mm][Ee]") then
        for amt in raw:gmatch("([%d,]+)|[Tt][^|]-[Mm][Oo][Nn][Ee][Yy][Ff][Rr][Aa][Mm][Ee]") do
            local g = tonumber((amt:gsub(",", "")))
            if g and g > 0 then
                entries[#entries + 1] = { currencyID = HDG.Constants.CURRENCY_GOLD, amount = g }
            end
        end
    end
    return entries
end

-- One entries list per distinct Cost: line in a sweep: 222 distinct lines of 1,800
-- in the test catalog. A repeat line is answered here without a parse, and a new
-- line's list is shared by content (_sharedCost). Lists are never written once
-- built, so vendors can hold the same one.
local function _costEntriesOf(raw)
    local memo = _sweepCostLines
    if not memo then return _extractCostEntries(raw) end  -- exception(nullable): nil between sweeps, for a row built for a decor just collected
    local entries = memo[raw]
    if not entries then
        entries = _sharedCost(_extractCostEntries(raw))
        memo[raw] = entries
    end
    return entries
end

-- A vendor block can carry SEVERAL Zone: lines. Blizzard reports ONE Vendor with every
-- zone that vendor stands in:
--     Vendor: Unquestionably Griftah / Zone: Razorwind Shores / Zone: Founder's Point
--     Vendor: Second Chair Pawdo     / Zone: Stormwind City   / Zone: Dornogal
-- Assigning current.zone per line kept only the LAST and silently dropped the rest --
-- 74 of 986 vendor blocks in the recorded catalog, every one of them losing a zone.
-- That is what made a vendor standing in Razorwind Shores list as Founder's Point.
--
-- Emit one vendor record PER zone: byVendor is already keyed (name, zone), and
-- acq.allVendors already emits a UI row per key, so the whole chain wants this shape.
local function _flushVendorZones(vendors, v)
    local zones = v.zones
    v.zones = nil
    if not zones or #zones == 0 then
        vendors[#vendors + 1] = v
        return
    end
    for i = 1, #zones do
        local rec = v
        if i > 1 then                       -- shallow copy per extra zone
            rec = {}
            for k, val in pairs(v) do rec[k] = val end
        end
        rec.zone = zones[i]
        vendors[#vendors + 1] = rec
    end
end

-- A "Vendors:" line (plural) names SEVERAL merchants who share the Zone/Faction/Cost
-- lines that follow -- "Vendors: Selfira Ambergrove, Sylvia Hartshorn / Zone: Val'sharah".
-- Kept whole, the pair became one vendor called "Selfira Ambergrove, Sylvia Hartshorn"
-- that matched no VendorAugment row, so neither could be mapped (2026-10-15). Emit one
-- vendor per name, each with every zone.
local function _flushVendor(vendors, v)
    if not v then return end
    local names = v.names
    v.names = nil
    if not names then return _flushVendorZones(vendors, v) end  -- exception(nullable): only a plural "Vendors:" line sets names
    for _, name in ipairs(names) do
        local rec = {}
        for k, val in pairs(v) do rec[k] = val end
        rec.name = name
        _flushVendorZones(vendors, rec)
    end
end

-- "A, B" -> { "A", "B" }: the merchants on a plural "Vendors:" line.
local function _vendorNames(list)
    local out = {}
    for piece in list:gmatch("[^,]+") do
        local name = piece:match("^%s*(.-)%s*$")
        if name ~= "" then out[#out + 1] = name end
    end
    return out
end

-- Next source-text line at or after `pos`, and the position after it: the
-- catalog separates lines with the "|n" escape or a real newline, both split
-- here, empty segments skipped. Walks the text in place; the old shape first
-- copied the whole text (gsub "|n" -> newline) and then split the copy.
local function _nextSourceLine(s, pos)
    local n = #s
    while pos <= n do
        local a = s:find("|n", pos, true)
        local b = s:find("\n", pos, true)
        local stop = (a and b) and math.min(a, b) or a or b   -- exception(nullable): no separator left = last line
        local finish = stop and (stop - 1) or n
        local width = (stop and stop == a) and 2 or (stop and 1 or 0)
        if finish >= pos then
            return s:sub(pos, finish), finish + 1 + width
        end
        pos = finish + 1 + width
    end
    return nil
end

function R:_ParseSourceText(sourceText, row)
    if sourceText == "" then row.vendors = {}; return end
    local SHL = _G.C_StringUtil.StripHyperlinks
    local SOURCE_TOKENS = HDG.Constants.CATALOG_SOURCE_TOKENS

    local vendors = {}
    local current = nil
    local pendingZoneTarget = nil
    local raw, pos = _nextSourceLine(sourceText, 1)
    while raw do
        local ts, hks
        if _sweepProf then ts, hks = _G.debugprofilestop(), collectgarbage("count") end
        local line = SHL(raw, false, false, false, false, false)
        if ts then _lap(STRIP_STAGE, ts, hks) end
        if line:find("^%s") or line:find("%s$") then   -- trim only a line that needs it (a copy otherwise)
            line = line:match("^%s*(.-)%s*$") or line
        end
        -- One "Key: value" match, then the key decides: eleven per-line pattern
        -- calls before, each a C call with its own pattern walk.
        local key, val = line:match("^(%a+):%s*(.+)")
        local vName    = (key == "Vendor" or key == "Vendors") and val or nil
        local zone     = key == "Zone"        and val or nil
        local fac      = key == "Faction"     and val or nil
        local renown   = key == "Renown"      and val or nil
        local cost     = key == "Cost"        and val or nil
        local quest    = key == "Quest"       and val or nil
        local ach      = key == "Achievement" and val or nil
        local cat      = key == "Category"    and val or nil
        local drop     = key == "Drop"        and val or nil
        local treasure = key == "Treasure"    and val or nil
        local event    = key == "Event"       and val or nil
        local bareKind = SOURCE_TOKENS[line]
        if vName then
            _flushVendor(vendors, current)
            current = { name = vName, zone = "", zones = {}, cost = "", faction = "", standing = "" }
            if key == "Vendors" then
                current.names = _vendorNames(vName)
                current.name  = current.names[1]
            end
            pendingZoneTarget = nil
        elseif drop then
            -- "Drop: <Source>" optional "Zone:" follows via pendingZoneTarget.
            row.drop = { source = drop }
            pendingZoneTarget = row.drop
        elseif treasure then
            row.treasure = { source = treasure }
            pendingZoneTarget = row.treasure
        elseif event then
            row.event = { source = event }
            pendingZoneTarget = row.event
        elseif bareKind == "SHOP" then
            -- Bare "Shop"/"In-Game Shop" line. NOTE: Profession: lines deliberately
            -- not handled here (CRAFT comes from recipe DB; catalog 'prof' false-positives).
            row.shop = true
            pendingZoneTarget = nil
        elseif bareKind == "PROMO" then
            -- Bare "Promotion" line -> promotional source (e.g. Framed Alliance/Horde Pride).
            row.promo = true
            pendingZoneTarget = nil
        elseif zone and current then
            current.zones[#current.zones + 1] = zone
            current.zone = zone   -- last-seen; _flushVendor overwrites per emitted record
        elseif zone and pendingZoneTarget then
            pendingZoneTarget.zone = zone
            pendingZoneTarget = nil
        elseif fac and current then
            local fName, standing = fac:match("(.-)%s*-%s*(.+)")
            current.faction  = fName or fac
            current.standing = standing or ""
            -- row.factionGate: first Faction: wins. Selectors fall back to ItemAugment when absent.
            row.factionGate = row.factionGate or {
                factionName = current.faction,
                standing    = current.standing,
            }
        elseif renown then
            -- "Renown: N" -- standing for the preceding Faction: gate (catalog splits name + level).
            if current then current.standing = renown end
            if row.factionGate and (row.factionGate.standing or "") == "" then
                row.factionGate.standing = renown
            end
            pendingZoneTarget = nil
        elseif cost and current then
            current.cost = cost
            -- Parse currencies from raw line (SHL strips |Hcurrency: wrappers).
            local entries = _costEntriesOf(raw)
            if next(entries) then current.costEntries = entries end
        elseif quest then
            row.quest = quest
        elseif ach then
            row.achievement = ach
        elseif cat then
            row.category = cat
        elseif current and (raw:find("|Hcurrency:", 1, true) or raw:find("|Hitem:", 1, true)) then
            -- Bare cost line (no "Cost:" prefix): achievement-vendor catalog format
            -- (e.g. "800|Hcurrency:3392|h"). Same handling as the Cost: branch.
            current.cost = line
            local entries = _costEntriesOf(raw)
            if next(entries) then current.costEntries = entries end
        end
        raw, pos = _nextSourceLine(sourceText, pos)
    end
    _flushVendor(vendors, current)
    row.vendors = vendors
end

-- ===== Public API ============================================================
-- Methods gate on IsReady(). nil/empty while loading is a CONTRACT (ADR-008/022).

function R:IsReady()
    local s = HDG.Store:GetState().session.catalog
    return s and s.status == "ready"
end

-- C_DyeColor accessor (sole owner; all reads funnel through here). nil on unknown/invalid id.
function R:GetDyeColorInfo(dyeColorID)
    if not dyeColorID then return nil end
    return _G.C_DyeColor.GetDyeColorInfo(dyeColorID)   -- exception(boundary): nil on unknown/invalid id
end

function R:GetRow(itemID)
    if not R:IsReady() then return nil end
    return R.byItemID[itemID]
end

-- ===== Destroying stored copies (HDGR_DestroyQueue) ==========================
-- The observer owns C_HousingCatalog, so the one destroy call lives here.
-- pcall: DestroyEntry can throw on a stale entry; the queue ends the run on the
-- first failure and reports it, so the error is never swallowed.
function R:DestroyEntry(entryID)
    return pcall(_G.C_HousingCatalog.DestroyEntry, entryID, false)  -- exception(fire-forget): the queue logs the error and ends the run
end

-- What the server says you own of this item: stored + placed + redeemable.
-- THE confirmation signal for a destroy. The client takes a copy off `quantity`
-- the instant DestroyEntry is called, kept or not, but it holds this TOTAL at the
-- server's figure and covers the gap with a temporary rise in `numPlaced` (live
-- 12.1, 2026-09-19: 101 sent, 22 kept -- stored fell 101, placed rose 79, total
-- fell 22, and a /reload agreed with the total).
function R:OwnedTotal(itemID)
    local row = R.byItemID[itemID]
    return row.quantity + row.numPlaced + row.remainingRedeemable
end

-- THE ITEM A BLUEPRINT MANIFEST ENTRY REFERS TO, or nil when it is not a thing
-- you can go and get. Blueprint contents name their pieces by `recordID`, and
-- what that ID MEANS depends on the entry's contentType -- which is the join
-- the catalog owns, so it belongs here rather than in each caller.
--
--   Dye (4)     the recordID IS the item ID (verified in-game 68629), and it
--               is the one shopping needs even when the catalog has no dye row
--   Decor (3)   the recordID is a decor ID; byDecorID carries the join
--   1 / 2 / 5   house type, room, fixture -- structural, nothing to acquire
--
-- Two callers now: the blueprints inspector's acquisition chips, and the
-- public API another Vamoose addon routes a shopping list through. Having them
-- resolve it separately is how the two quietly disagree.
-- Built from this observer's own two accessors rather than reaching into
-- byDecorID: it keeps the method short enough to be obviously right, and it is
-- the pair every caller and test already has to hand.
function R:ItemIDForEntry(entry)
    local ct = entry.contentType
    if ct == 4 then
        local row = self:GetRow(entry.recordID)  -- exception(nullable): dyes may not be catalog rows
        return row and row.itemID or entry.recordID
    end
    if ct ~= 3 then return nil end               -- structural: nothing to buy
    return self:GetItemIDByDecorID(entry.recordID)  -- exception(nullable): a miss resolves at the vendor at runtime
end

-- GetVariantDyes: 0/1/2-channel dye map for a dyed variant; nil for base or non-dyed.
-- Drives model preview SetGradientMaskWithDyes from the baked row.dyedVariants.
function R:GetVariantDyes(itemID, variantKey)
    local row = R.byItemID[itemID]
    if not (row and row.dyedVariants) then return nil end
    local vid = tostring(variantKey):match(":(.+)$")
    if not vid or vid == "base" then return nil end
    vid = tonumber(vid)
    for _, dv in ipairs(row.dyedVariants) do
        if dv.variantIdentifier == vid then return dv.dyeColorsByChannel end
    end
    return nil
end

-- IsOwned: canonical ownership predicate. quantity + remainingRedeemable + numPlaced
-- (Blizzard's GetEntryTotalOwned = totalNumStored + remainingRedeemable + totalNumPlaced;
-- quantity/numPlaced mirror the total* fields). totalNumStored/totalNumPlaced and per-variant
-- numStored are ALL live at runtime (dump-verified 2026-07-16) -- earlier "always nil" note
-- was wrong and is what pushed the undyed row onto the aggregate destroyableInstanceCount.
-- Accepts a row table, itemID, or decorID. Returns false for unknown inputs.
function R:IsOwned(rowOrID)
    local row
    if type(rowOrID) == "table" then
        row = rowOrID
    elseif type(rowOrID) == "number" then
        row = R.byItemID[rowOrID] or R.byDecorID[rowOrID]
    end
    if not row then return false end
    return ((row.quantity or 0)  -- exception(boundary): catalog struct field sparse
         + (row.remainingRedeemable or 0)  -- exception(boundary): catalog struct field sparse
         + (row.numPlaced or 0)) > 0  -- exception(boundary): catalog struct field sparse
end

-- Sold by a vendor standing in a housing neighborhood (Founder's Point / Razorwind
-- Shores). row.vendors is always stamped by _bakeVendors (empty list included) and
-- carries each vendor's mapID off VendorAugment. ONE definition, shared by the
-- Acquire tab's Neighborhood filter and the "Neighborhood Decor" collection, so the
-- filter and the collection can't drift apart on what counts.
function R:IsSoldInNeighborhood(row)
    for _, v in ipairs(row.vendors) do
        if v.mapID and HDG.Constants.NEIGHBORHOOD_MAP_IDS[v.mapID] then
            return true
        end
    end
    return false
end

-- decorID -> itemID via byDecorID (used by ShoppingCodec + StyleEngine).
function R:GetItemIDByDecorID(decorID)
    if not decorID then return nil end
    local row = R.byDecorID[decorID]
    return row and row.itemID
end

-- itemID -> decorID (rows carry decorID).
function R:GetDecorIDByItemID(itemID)
    if not itemID then return nil end
    local row = R.byItemID[itemID]
    return row and row.decorID
end

-- Full itemID -> decorID map (StyleSerializer export, useDecorID=true). Built on demand.
function R:GetDecorIDByItemIDMap()
    local out = {}
    for itemID, row in pairs(R.byItemID) do
        if row.decorID then out[itemID] = row.decorID end
    end
    return out
end

function R:GetIcon(itemID)
    local row = R:GetRow(itemID)
    return row and row.iconTexture
end

function R:GetExpansionForItem(itemID)
    local row = R:GetRow(itemID)
    if not (row and row.dataTagsByID) then return nil end
    for tagID, displayName in pairs(row.dataTagsByID) do
        if R.tagIDToGroup[tagID] == "Expansion" then
            return displayName
        end
    end
    return nil
end

function R:GetVendorsForItem(itemID)
    local row = R:GetRow(itemID)
    return row and row.vendors
end

-- Crafted decor -- has a profession recipe (row.recipe -> sourceType 6 / [PROF] chip)
-- -- is the only Bind-on-Equip, hence the only Auction-House-tradeable decor.
-- Everything else (vendor / drop / quest / achievement) is BoP or Warbound.
function R:GetBindTypeForItem(itemID)
    local row = R:GetRow(itemID)
    if not row then return nil end
    return (row.recipe ~= nil) and "BoE" or "BoP"
end

function R:GetItemsByVendor(vendorName, vendorZone)
    if not R:IsReady() then return nil end
        -- byVendor keyed by (name, zone); ~9 display names are shared across zones.
    return R.byVendor[(vendorName or "") .. "::" .. (vendorZone or "")]
end

function R:IterateRows(fn)
    if not R:IsReady() then return end
    for itemID, row in pairs(R.byItemID) do fn(itemID, row) end
end

function R:GetItemCount()
    if not R:IsReady() then return 0 end
    local n = 0
    for _ in pairs(R.byItemID) do n = n + 1 end
    return n
end

-- ===== Synchronous per-item resolver =========================================
-- Resolve() wraps C_HousingCatalog.GetCatalogEntryInfoByRecordID.
-- Failures are silent here; the widget treats nil as "Preview unavailable".
local DECOR_CATALOG_ID = 1   -- Blizzard's housing catalog is catalog 1

function R:Resolve(itemID)
    if type(itemID) ~= "number" then return nil end

    -- Primary: byItemID; falls back to Recipes for recipe-only paths and cold catalog.
    local decorID
    local nameFallback
    local catalogRow = R.byItemID[itemID]
    if catalogRow then
        decorID      = catalogRow.decorID
        nameFallback = catalogRow.name
    else
        local db = HDG.StaticData.Recipes:GetAll()
        local entry = db and db[itemID]
        decorID      = entry and entry.decorID
        nameFallback = entry and entry.name
    end
    if not decorID then return nil end

    local cat = _G.C_HousingCatalog
    if not (cat and cat.GetCatalogEntryInfoByRecordID) then return nil end
    -- exception(boundary): 12.0.5 dropped the 3rd arg (tryGetOwnedInfo); 3-arg throws "bad argument #2".
    local info = cat.GetCatalogEntryInfoByRecordID(DECOR_CATALOG_ID, decorID)
    if type(info) ~= "table" then return nil end

    return {
        asset           = info.asset,
        uiModelSceneID  = info.uiModelSceneID,
        iconTexture     = info.iconTexture,
        iconAtlas       = info.iconAtlas,
        name            = info.name or nameFallback,
    }
end

-- ===== Load-on-demand lifecycle =============================================
-- Sweep fires when a catalog-consuming view first activates (CATALOG_CONSUMING_TAB_VIEWS).

-- RequestLoad: idempotent cold-start trigger (only when status == "idle").
function R:RequestLoad(reason)
    local s = HDG.Store:GetState().session.catalog
    if s.status ~= "idle" then return end
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CATALOG_LOAD_REQUESTED,
                         payload = { requestedBy = reason or "?" } })
    R:_RunSweep(reason)
end

function R:Refresh(reason)    R:_RunSweep(reason) end
function R:_RunSweep(reason)  R:ReconcileFull(reason) end

-- ===== Room catalog =========================================================
-- Second persistent searcher in Layout mode (C_HousingCatalog owned here; one namespace per module).
-- Same lifecycle as the decor searcher; cheap (~20 entries) so no settle timer.
function R:_EnsureRoomSearcher()
    if self._roomSearcher then return self._roomSearcher end
    if not (_G.C_HousingCatalog and _G.C_HousingCatalog.CreateCatalogSearcher) then return nil end
    local s = _G.C_HousingCatalog.CreateCatalogSearcher()
    if not s then return nil end
    self._roomSearcher = s
    s:SetResultsUpdatedCallback(function() R:_OnRoomResults(s) end)
    return s
end

-- Room searcher config: decor config with editorModeContext=Layout + storedOnly=false.
function R:_ConfigureRoomSearcher(s)
    s:SetAutoUpdateOnParamChanges(false)
    s:SetStoredOnly(false)
    s:SetBaseVariantOnly(true)
    s:SetEditorModeContext(_G.Enum.HouseEditorMode.Layout)   -- ROOMS, not decor
    s:SetCustomizableOnly(false)
    s:SetAllowedIndoors(true)
    s:SetAllowedOutdoors(true)
    s:SetCollected(true)
    s:SetUncollected(true)
    s:SetFirstAcquisitionBonusOnly(false)
    s:SetFilteredCategoryID(_allCategoryID())
    s:SetFilteredSubcategoryID(nil)
    for _, group in ipairs(_G.C_HousingCatalog.GetAllFilterTagGroups() or {}) do
        s:SetAllInFilterTagGroup(group.groupID, true)
    end
    s:SetAutoUpdateOnParamChanges(true)
end

-- ReconcileRooms: (re)configure the room searcher + RunSearch.
function R:ReconcileRooms()
    local s = self:_EnsureRoomSearcher()
    if not s then return end   -- exception(boundary): C_HousingCatalog unavailable (decor path logs it)
    self:_ConfigureRoomSearcher(s)
    s:RunSearch()
end

-- _OnRoomResults: snapshot Layout-mode results. Stock = totalNumStored+totalNumPlaced>0;
-- geometry via ShapeAtlas.ShapeForRecordID. byShapeID = palette/stock lookup; entries = full list.
function R:_OnRoomResults(searcher)
    if not (searcher and searcher.GetCatalogSearchResults) then return end
    local items = searcher:GetCatalogSearchResults()
    if not items or #items == 0 then return end   -- exception(boundary): catalog priming / searcher race -> next event re-kicks
    local HC    = _G.C_HousingCatalog
    local Shape = HDG.Projects.ShapeAtlas
    local byShapeID, entries = {}, {}
    for _, ev in ipairs(items) do
        local info = HC.GetCatalogEntryInfo(ev)
        if info then   -- exception(boundary): nil for an uncached entry; it returns on a later sweep
            local stored  = info.totalNumStored or 0   -- exception(boundary): external struct field
            local placed  = info.totalNumPlaced or 0  -- exception(boundary): Blizzard struct field sparse
            local shapeID = Shape.ShapeForRecordID(ev.recordID)
            local entry = {
                recordID          = ev.recordID,
                variantIdentifier = ev.variantIdentifier,
                shapeID           = shapeID,
                name              = info.name,
                iconAtlas         = info.iconAtlas,
                iconTexture       = info.iconTexture,
                placementCost     = info.placementCost,
                numStored         = stored,
                numPlaced         = placed,
                quantity          = info.totalNumStored,  -- exception(boundary): 12.0.5 field; shim-free
                owned             = (stored + placed) > 0,
                isAllowedIndoors  = info.isAllowedIndoors,
                isAllowedOutdoors = info.isAllowedOutdoors,
                isPrefab          = info.isPrefab,
                quality           = info.quality,
            }
            entries[#entries + 1] = entry
            if shapeID then byShapeID[shapeID] = entry end
        end
    end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.PROJECTS_ROOM_CATALOG_UPDATED,
        payload = { byShapeID = byShapeID, entries = entries },
    })
end

-- ===== Category nav tree ====================================================
-- Snapshot of session.house.categoryTree for the Curator + Projects decor picker.
-- Atlas state suffix stripped once here; selectors append at render (Inv 1).

-- Strip atlas state suffix (e.g. "_active"). "_active-parent" tried first (longest-first to avoid half-strip).
local _CAT_ATLAS_MODIFIERS = { "_active%-parent", "_inactive", "_pressed", "_active" }
local function _stripCategoryAtlas(icon)
    if not icon or icon == "" then return nil end   -- exception(boundary): icon is a nilable API field
    for _, mod in ipairs(_CAT_ATLAS_MODIFIERS) do
        local base = icon:gsub(mod, "")
        if base ~= icon then return base end
    end
    return icon
end

-- Full category tree walk + dispatch. rootIDs unfiltered; selectors apply storedOnly via anyStoredEntries.
function R:_RebuildCategoryTree()
    local HC = _G.C_HousingCatalog
    if not (HC and HC.SearchCatalogCategories) then return end   -- exception(boundary): API namespace not present yet
    -- BasicDecor mode: decor categories only; editorModeContext excludes Room.
    local catIDs = HC.SearchCatalogCategories({
        withStoredEntriesOnly   = false,
        includeFeaturedCategory = true,
        editorModeContext       = _G.Enum.HouseEditorMode.BasicDecor,
    })
    if not catIDs or #catIDs == 0 then return end   -- exception(boundary): catalog priming -> next event re-kicks
    local byID, subcatByID, rootIDs = {}, {}, {}
    for _, catID in ipairs(catIDs) do
        local info = HC.GetCatalogCategoryInfo(catID)
        if info then   -- exception(boundary): nil for an uncached category
            local subIDs = info.subcategoryIDs or {}   -- exception(boundary): external struct field
            byID[catID] = {
                id               = catID,
                name             = info.name,                -- nilable per API
                iconBase         = _stripCategoryAtlas(info.icon),
                orderIndex       = info.orderIndex or 0,     -- exception(boundary): external struct field
                subcategoryIDs   = subIDs,
                anyStoredEntries = info.anyStoredEntries,
            }
            rootIDs[#rootIDs + 1] = catID
            for _, subID in ipairs(subIDs) do
                if not subcatByID[subID] then
                    local sub = HC.GetCatalogSubcategoryInfo(subID)
                    if sub then   -- exception(boundary): nil for an uncached subcategory
                        subcatByID[subID] = {
                            id               = subID,
                            name             = sub.name,
                            iconBase         = _stripCategoryAtlas(sub.icon),
                            orderIndex       = sub.orderIndex or 0,  -- exception(boundary): Blizzard struct field sparse
                            parentCategoryID = sub.parentCategoryID,
                            anyStoredEntries = sub.anyStoredEntries,
                        }
                    end
                end
            end
        end
    end
    table.sort(rootIDs, function(a, b) return byID[a].orderIndex < byID[b].orderIndex end)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.CATALOG_CATEGORY_TREE_UPDATED,
        payload = { byID = byID, subcatByID = subcatByID, rootIDs = rootIDs },
    })
end

function R:_CancelCategoryTreeTimer()
    if self._categoryTreeTimer then
        if self._categoryTreeTimer.Cancel then self._categoryTreeTimer:Cancel() end   -- exception(boundary): C_Timer API
        self._categoryTreeTimer = nil
    end
end

-- Coalesce HOUSING_CATALOG_(SUB)CATEGORY_UPDATED bursts. Own timer (no cross-trigger with decor settle).
function R:QueueCategoryTreeRebuild()
    self:_CancelCategoryTreeTimer()
    self._categoryTreeTimer = C_Timer.NewTimer(0.4, function()
        self._categoryTreeTimer = nil
        R:_RebuildCategoryTree()
    end)
end

-- _OnViewChange: routes to RequestLoad (cold) or Refresh (deferred/retry) based on catalog state.
function R:_OnViewChange(view)
    if not HDG.Constants.CATALOG_CONSUMING_TAB_VIEWS[view] then return end
    local s = HDG.Store:GetState().session.catalog
    if s.status == "idle" then
        R:RequestLoad("view-change:" .. tostring(view))
    elseif s.status == "loading" then
        -- Still "loading" on a HUMAN tab switch = the sweep dead-ended (healthy
        -- loads take 0.5-2s, faster than anyone changes views). Re-kick, Blizzard
        -- style: their catalog frames RunSearch on every OnShow. Same persistent
        -- searcher, so a re-kick over a live sweep supersedes it (worst case a
        -- redundant identical commit, see ReconcileFull).
        R:Refresh("view-change-retry:" .. tostring(view))
    elseif s.refreshPending then
        R:Refresh("view-change:" .. tostring(view))
    end
end

-- ===== In-memory row mutations ===============================================
-- Observer owns byDecorID/byItemID. Called from onEnable subscriber on per-entry
-- events (ROW_ADDED / ROW_REMOVED / COUNTS_UPDATED) between full sweeps.

function R:UpsertRow(decorID, entry)
    if not (decorID and entry) then return end
    local row = entry
    R.byDecorID[decorID] = row
    if row.itemID then R.byItemID[row.itemID] = row end
end

function R:RemoveRow(decorID)
    if not decorID then return end
    local row = R.byDecorID[decorID]
    if row and row.itemID then R.byItemID[row.itemID] = nil end
    R.byDecorID[decorID] = nil
end

function R:PatchCounts(decorID, counts)
    if not (decorID and counts) then return end
    local row = R.byDecorID[decorID]
    if not row then return end
    row.quantity                 = counts.quantity                 or 0  -- exception(boundary): Blizzard struct field sparse
    row.numPlaced                = counts.numPlaced                or 0  -- exception(boundary): Blizzard struct field sparse
    row.remainingRedeemable      = counts.remainingRedeemable      or 0  -- exception(boundary): Blizzard struct field sparse
    row.destroyableInstanceCount = counts.destroyableInstanceCount or 0  -- exception(boundary): Blizzard struct field sparse
    row.firstAcquisitionBonus    = counts.firstAcquisitionBonus    or 0  -- exception(boundary): Blizzard struct field sparse
end

function R:ClearStore()
    R.byDecorID = {}
    R.byItemID  = {}
    R.byVendor  = {}
    R._catalogSchemaVersion = 0
    R._storageSeen = -1
    R._rowsStamp = false
end

-- ===== Module registration ====================================================
-- BlizzardEvents resolves handlers via mod[handler]; functions live on the module
-- def table and delegate to singleton R.

HDG.Modules:Declare({
    name = "HousingCatalogObserver",
    ownsBlizzardNamespaces = { "C_HousingCatalog", "C_DyeColor" },
    -- Store is a top-level engine, not a module. No dependencies.
    dependencies = {},
    logTags = {
        catalog_swept     = { user = false, level = "info"    },
        catalog_refreshed = { user = true,  level = "success", duration = 5    },
        catalog_error     = { user = true,  level = "error",   duration = nil  },
        catalog_reconcile = { user = false, level = "warn"    },
    },
    blizzardEvents = {
        -- Queuing model: events dispatch CATALOG_REFRESH_QUEUED regardless of window state.
        -- Actual sweep deferred to next catalog-tab activation (UI_SET_PERSISTENT subscriber).
        HOUSING_STORAGE_UPDATED              = { handler = "OnHousingStorageUpdated", debounce = 0.5 },
        HOUSING_STORAGE_ENTRY_UPDATED        = { handler = "OnHousingStorageEntryUpdated" },
        HOUSE_DECOR_ADDED_TO_CHEST           = { handler = "OnHouseDecorAddedToChest" },
        HOUSING_CATALOG_CATEGORY_UPDATED     = { handler = "OnHousingCatalogCategoryChange" },
        HOUSING_CATALOG_SUBCATEGORY_UPDATED  = { handler = "OnHousingCatalogSubcategoryChange" },
        -- (HOUSING_DECOR_PLACE_SUCCESS/REMOVED/etc. are NOT here: redundant with
        -- the storage signals + their decorGUID is nil -- they can't drive a
        -- targeted update. In-editor place/remove is captured granularly via the
        -- per-entry HOUSING_STORAGE_ENTRY_UPDATED below, exactly as Blizzard's own
        -- HouseEditorStorageFrame does. The earlier full-sweep-per-event approach
        -- stormed the catalog index sweep -- see the perf profile.)
    },
    -- Handlers are pure dispatch sites; sweep deferred to UI_SET_PERSISTENT subscriber.
    -- payload.event = triggering Blizzard event (diagnostic; shows in the dispatch log
    -- so refresh-queued sweeps can be attributed to their source event).
    OnHousingStorageUpdated = function(self)
        -- Searching loads storage, so an update fires as the first search runs, and
        -- the debounce hands it over after the build has read it: that was a second
        -- full build (~30 MB) at every first open (memory plan 2026-10-19 sec 6).
        -- The count says whether any update in the burst came after the build began.
        if HDG.BlizzardEvents:FireCount("HOUSING_STORAGE_UPDATED") <= R._storageSeen then
            HDG.Log:Info("catalog_swept", "storage update already in the catalog build -- no rebuild")
            return
        end
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CATALOG_REFRESH_QUEUED,
                             payload = { event = "HOUSING_STORAGE_UPDATED" } })
    end,
    OnHousingStorageEntryUpdated = function(self, entryID)
        -- Per-entry reconcile: targeted path (Blizzard's HouseEditorStorageFrame pattern).
        -- Only path that emits COLLECTION_ITEM_LEARNED + CRAFT_HISTORY_PUSH for newly-owned decor.
        -- exception(boundary): entry data is already fresh in Blizzard's cache when this event fires.
        if entryID then
            R:ReconcileEntry(entryID)
            return
        end
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CATALOG_REFRESH_QUEUED,
                             payload = { event = "HOUSING_STORAGE_ENTRY_UPDATED" } })
    end,
    -- Fires before Blizzard's counts update, so it never reads them: it only
    -- arms the check that the entry event above did flip the row.
    OnHouseDecorAddedToChest = function(self, _decorGUID, decorID)
        R:NoteDecorArrival(decorID)
    end,
    OnHousingCatalogCategoryChange = function(self)
        -- Rare hotfix events. Same queuing semantics.
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CATALOG_REFRESH_QUEUED,
                             payload = { event = "HOUSING_CATALOG_CATEGORY_UPDATED" } })
    end,
    OnHousingCatalogSubcategoryChange = function(self)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CATALOG_REFRESH_QUEUED,
                             payload = { event = "HOUSING_CATALOG_SUBCATEGORY_UPDATED" } })
    end,
    onEnable = function(self)
        local A = HDG.Constants.ACTIONS
        -- UI_SET_PERSISTENT: load-on-demand trigger (filter on account.ui.view writes).
        -- Also handles row mutations (ROW_ADDED/REMOVED/COUNTS_UPDATED) and COLLECTION_RESET
        -- so byDecorID/byItemID stay consistent (observer = sole writer; reducer = no-op).
        self._storeToken = HDG.Store:Subscribe(function(actionType, invalidation, action)
            if actionType == A.UI_SET_PERSISTENT then
                -- Only proceed when account.ui.view was the written key.
                if type(invalidation) == "table" and invalidation[1] ~= "account.ui.view" then return end
                -- A tab switch brings no data. While a build with entries settles, that
                -- build answers what the switch would re-kick (an update newer than it
                -- is owed on its own), so a re-kick only builds it again. A 0-entry
                -- settle or a silent searcher still falls through to the retry.
                if R._commitPending and R._settlingHasEntries then return end
                local view = HDG.Store:GetState().account.ui.view
                if view then R:_OnViewChange(view) end
            elseif actionType == A.MAIN_WINDOW_OPENING then
                -- Load unconditionally on first open (most views derive from the catalog).
                -- RequestLoad is idempotent; re-opens are no-ops.
                R:RequestLoad("main-window-opening")
                -- A storage event while the window was closed only marked the
                -- catalog stale (refreshPending). A tab switch acts on that mark,
                -- and reopening on the same tab must too, or an arrival seen only
                -- through HOUSING_STORAGE_UPDATED shows late. RequestLoad starts
                -- the first load itself, so this waits for a ready catalog.
                if HDG.Store:GetState().session.catalog.status == "ready" then
                    R:_OnViewChange(HDG.Store:GetState().account.ui.view)
                end
                R:ReconcileRooms()          -- live room catalog (cheap; Layout-mode searcher)
                R:QueueCategoryTreeRebuild()   -- Blizzard category/subcategory nav snapshot
            elseif actionType == A.CATALOG_FORCE_RELOAD then
                R._rowsStamp = false                -- a manual reload rebuilds every row
                R:ReconcileFull("manual-refresh")   -- /hdgr refresh
            elseif actionType == A.MAIN_WINDOW_TOGGLE then
                -- Resume/pause searcher auto-update with window show/hide (Blizzard symmetry).
                if R._searcher then
                    R._searcher:SetAutoUpdateOnParamChanges(
                        HDG.Store:GetState().account.ui.mainWindowShown == true)
                end
            elseif actionType == A.CATALOG_REFRESH_QUEUED then
                -- Drain immediately when window is shown so open views reflect just-collected items.
                -- Still LOADING: re-kick ReconcileFull (tag groups may now be present).
                -- Editor-only (window closed): skip full sweep; HOUSING_STORAGE_ENTRY_UPDATED
                -- captures in-editor changes via ReconcileEntry (targeted; avoids 1673-entry storm).
                -- The still-LOADING re-kick is NOT gated on the main window. The
                -- companion opens standalone in the editor and calls RequestLoad,
                -- which flips status to "loading"; if the re-kick that completes
                -- that sweep only ran for the main window, status stayed "loading"
                -- forever -- and RequestLoad bails unless status == "idle", so the
                -- companion could never recover. Symptom: "?" placeholder icons
                -- until the player opened the main window and switched tabs.
                -- Cheap: this only fires while a sweep is genuinely mid-flight.
                if HDG.Store:GetState().session.catalog.status == "loading" then
                    R:ReconcileFull("refresh-queued:" .. action.payload.event)
                elseif HDG.Store:GetState().account.ui.mainWindowShown then
                    R:_OnViewChange(HDG.Store:GetState().account.ui.view)
                end
                -- The expensive follow-ups stay main-window-only: editor-only opens
                -- get targeted ReconcileEntry from HOUSING_STORAGE_ENTRY_UPDATED
                -- instead, avoiding the 1673-entry storm.
                if HDG.Store:GetState().account.ui.mainWindowShown then
                    R:ReconcileRooms()         -- storage change -> refresh room stock too
                    R:QueueCategoryTreeRebuild()   -- category ownership (anyStoredEntries) may have changed
                end
            elseif actionType == A.COLLECTION_CATALOG_ROW_ADDED then
                if action and action.payload then
                    R:UpsertRow(action.payload.decorID, action.payload.entry)
                end
            elseif actionType == A.COLLECTION_CATALOG_ROW_REMOVED then
                if action and action.payload then
                    R:RemoveRow(action.payload.decorID)
                end
            -- COLLECTION_CATALOG_ROW_COUNTS_UPDATED: the rows were patched
            -- synchronously in _ApplyEntry before the signal; nothing to do here.
            elseif actionType == A.COLLECTION_RESET then
                R:ClearStore()
            -- COLLECTION_BULK_LOAD: handled reducer-side only (writes ownedDecorIDs).
            end
        end)
    end,
    onShutdown = function(self)
        R:_CancelSettleTimer()
        R:_CancelCategoryTreeTimer()
        R:_CancelArrivalTimer()
        if self._storeToken then
            HDG.Store:Unsubscribe(self._storeToken)
            self._storeToken = nil
        end
    end,
})
