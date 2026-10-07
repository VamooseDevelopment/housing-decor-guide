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
R.byVendor       = R.byVendor       or {}
R.allVendorNames = R.allVendorNames or {}
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

-- ===== Per-sweep index builders ==============================================
-- `acc` = per-sweep accumulator: { byItemID, byDecorID, byVendor, allVendorNames,
-- vendorNamesSeen, owned }. Atomic-assigned onto R at commit; subscribers never
-- see partial state.

-- Index a (name, zone) vendor into acc.byVendor + dedup into allVendorNames.
-- Composite (name, zone) key: ~9 vendor names on 12.0.5 are shared across zones;
-- keying by name alone collapses distinct vendors into one bucket.
local function _indexVendor(acc, name, zone, faction, standing, itemID)
    local vkey = name .. "::" .. (zone or "")
    local ven = acc.byVendor[vkey]
    if not ven then
        local Aug = HDG.StaticData.VendorAugment   -- exception(boundary): absent in headless until StaticData loads
        ven = {
            name = name, items = {}, zone = zone,
            faction = faction or "", standing = standing or "",
            -- Resolved npcID so consumers can look a vendor up by ID (event cards,
            -- waypoints) without name reconciliation. Same resolution _bakeVendors uses.
            npcID = Aug and Aug:ResolveName(name, zone),
            _seenItems = {},
        }
        acc.byVendor[vkey] = ven
        if not acc.vendorNamesSeen[name] then
            acc.vendorNamesSeen[name] = true
            acc.allVendorNames[#acc.allVendorNames + 1] = name
        end
    end
    if not ven._seenItems[itemID] then
        ven._seenItems[itemID] = true
        table.insert(ven.items, itemID)
    end
end

-- Feed a row's vendor sources into _indexVendor. row.vendors is the complete list:
-- _bakeVendors folds CatalogOverride type=5 vendors (hidden/placeholder sellers like
-- Chel the Chip) into it, so no separate row.sources pass is needed here.
local function _indexVendorsFromRow(acc, row)
    if row.vendors then
        for _, v in ipairs(row.vendors) do
            if v.name and v.name ~= "" then
                _indexVendor(acc, v.name, v.zone, v.faction, v.standing, row.itemID)
            end
        end
    end
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
    "entryInfo", "rowTable", "variants", "parseSource", "overrides+augment",
    "tags+category+placement", "vendors", "cost", "recipe+sourceTypes+bonus",
    "variantDyes", "sourceTags", "index",
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
    local row = R:BuildRow(info)   -- laps its own stages
    if t then t, hk = _G.debugprofilestop(), collectgarbage("count") end
    acc.byItemID[row.itemID] = row
    acc.byDecorID[rid]       = row
    if row.isOwned then acc.owned[rid] = true end
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
    local items = searcher:GetCatalogSearchResults()
    if not items then
        -- nil result set: nothing to commit yet. Stay "loading"; the next
        -- storage/catalog event re-kicks (re-applying config) until entries land.
        HDG.Log:Warn("catalog_error", "GetCatalogSearchResults returned nil; sweep not committed (will retry on next storage event)")
        return
    end

    R:_BuildTagIDIndex()  -- must precede the sweep so _bakeTags sees Expansion/Size tags

    -- Build into per-sweep acc; _CommitSweep atomic-assigns in the settle callback.
    local acc = {
        byItemID = {}, byDecorID = {}, byVendor = {},
        allVendorNames = {}, vendorNamesSeen = {}, owned = {},
    }
    -- Perf: catalog-load cost (outside dispatch path; flush probe never sees it). boundary: Perf optional.
    local _perf  = HDG.Perf
    local _timed = _perf and _perf:Enabled()
    local _t0, _k0
    if _timed then _t0, _k0 = _perf:Open() end
    _sweepProf   = _timed and { ms = {}, kb = {}, n = {} } or nil
    for _, entry in ipairs(items) do
        _processEntry(acc, entry)
    end
    if acc.skippedPoisoned then
        HDG.Log:Warn("catalog_error", ("%d searcher row(s) skipped: unreadable entry IDs (secret/poisoned) -- sweep completed without them")
            :format(acc.skippedPoisoned))
    end
    if _timed then
        local totalMs, totalKB = _perf:RecordOp("catalog.indexSweep (" .. #items .. " entries)", _t0, _k0)
        _reportSweepStages(_perf, totalMs, totalKB, #items)
        _sweepProf = nil
    end
    table.sort(acc.allVendorNames)

    local result = {
        byItemID       = acc.byItemID,
        byDecorID      = acc.byDecorID,
        byVendor       = acc.byVendor,
        allVendorNames = acc.allVendorNames,
        owned          = acc.owned,
        sweptAt        = _G.GetTime and _G.GetTime() or 0,  -- exception(boundary): GetTime/time absent in headless harness
        clientVer      = self:GetClientVer(),
    }

    -- Settle 0.5s: coalesces searcher multi-fire bursts (boundary: loading screens / login cascade).
    self:_CancelSettleTimer()
    self._commitPending = true
    self._settleTimer = C_Timer.NewTimer(0.5, function()
        self._commitPending = false
        self._settleTimer = nil
        R:_CommitSweep(result)
        R:_ReplayOwedRekick()
    end)
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

    -- ATOMIC ASSIGN: consumers see either old or new, never mid-build.
    R.byItemID       = result.byItemID
    R.byDecorID      = result.byDecorID
    R.byVendor       = result.byVendor
    R.allVendorNames = result.allVendorNames
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
    -- A sweep in flight builds a private snapshot and swaps it in wholesale at
    -- settle, so a patch made now lands in tables about to be replaced. Park the
    -- event for _CommitSweep to replay, keeping wasOwned from BEFORE the swap so
    -- the learned transition survives a snapshot that already shows it owned.
    -- Park too when nothing can say yet whether the decor was owned (wasOwned
    -- nil): applied now, a nudge of owned decor would read as a learn.
    if R._sweepInFlight or wasOwned == nil then
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
    local counts = {
        quantity                 = info.totalNumStored           or 0,  -- exception(boundary): Blizzard struct field sparse (row.quantity KEEPS its name; source is the 12.0.5 field)
        numPlaced                = info.totalNumPlaced           or 0,  -- exception(boundary): Blizzard struct field sparse
        remainingRedeemable      = info.remainingRedeemable      or 0,  -- exception(boundary): Blizzard struct field sparse
        destroyableInstanceCount = info.destroyableInstanceCount or 0,  -- exception(boundary): Blizzard struct field sparse
        firstAcquisitionBonus    = info.firstAcquisitionBonus
                                     or row.firstAcquisitionBonus or 0,  -- exception(boundary): Blizzard struct field sparse
    }
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

-- BuildRow: transforms one catalog info table into the enriched row shape.
-- NOT pure: makes boundary calls (dye variants, category names, VendorAugment).
-- Snapshots live state at sweep time; stale until next sweep/reload.
-- Internal callers must never pass nil (strict read -- will throw on nil info).
function R:BuildRow(info)
    local t, hk
    if _sweepProf then t, hk = _G.debugprofilestop(), collectgarbage("count") end
    local row = {
        -- identity
        itemID    = info.itemID,
        decorID   = info.recordID,
        -- Composed (NOT the shim's backfilled info.entryID): the 12.0.5 entryVariantID
        -- shape. variantIdentifier 0 = base stack -- the destroy identity default;
        -- dyed variants override it from GetAllVariantInfosForEntry (_bakeVariantDyes).
        entryID   = { recordID = info.recordID, entryType = info.entryType, variantIdentifier = 0 },
        entryType = info.entryType,

        -- catalog scalars
        name              = info.name,
        iconTexture       = info.iconTexture,
        iconAtlas         = info.iconAtlas,
        quality           = info.quality,
        size              = info.size,
        placementCost     = info.placementCost,
        -- Catalog struct may omit the allow-flags; default missing -> allowed
        -- (HDG-verified semantics). Normalized to a strict boolean here so every
        -- consumer (placement label, companion placement) reads it direct.
        isAllowedIndoors  = info.isAllowedIndoors  ~= false,  -- exception(boundary): catalog API field nil-able
        isAllowedOutdoors = info.isAllowedOutdoors ~= false,  -- exception(boundary): catalog API field nil-able
        canCustomize      = info.canCustomize,
        isPrefab          = info.isPrefab,
        isUniqueTrophy    = info.isUniqueTrophy,
        asset             = info.asset,
        uiModelSceneID    = info.uiModelSceneID,

        -- categorization
        -- categoryName / subcategoryName resolved at BuildRow time for direct render.
        -- Only the FIRST category / subcategory id is read anywhere; the raw
        -- arrays were kept on the row too and pinned Blizzard's per-sweep tables
        -- for the session (2026-09-13 allocation audit).
        categoryID      = info.categoryIDs    and info.categoryIDs[1],  -- exception(boundary): Blizzard struct optional array field
        subcategoryID   = info.subcategoryIDs and info.subcategoryIDs[1],  -- exception(boundary): Blizzard struct optional array field
        categoryName    = resolveCategoryName(info.categoryIDs    and info.categoryIDs[1]),
        subcategoryName = resolveSubcategoryName(info.subcategoryIDs and info.subcategoryIDs[1]),
        dataTagsByID    = info.dataTagsByID,

        -- Ownership counters. row.quantity / row.numPlaced KEEP their names (20+ readers)
        -- but source from the 12.0.5 fields -- info.quantity/info.numPlaced were
        -- Blizzard_DeprecatedHousingCatalog backfills, gone when the shim goes
        -- (dump-verified 2026-07-16: totalNumStored=3 on a 3-owned entry).
        quantity                 = info.totalNumStored           or 0,  -- exception(boundary): Blizzard struct field sparse
        numPlaced                = info.totalNumPlaced           or 0,  -- exception(boundary): Blizzard struct field sparse
        remainingRedeemable      = info.remainingRedeemable      or 0,  -- exception(boundary): Blizzard struct field sparse
        destroyableInstanceCount = info.destroyableInstanceCount or 0,  -- exception(boundary): Blizzard struct field sparse
        firstAcquisitionBonus    = info.firstAcquisitionBonus    or 0,  -- exception(boundary): Blizzard struct field sparse

        -- customization metadata
    }
    -- isOwned: includes remainingRedeemable (unclaimed tokens count as owned).
    row.isOwned = (row.quantity + row.remainingRedeemable + row.numPlaced) > 0
    if t then t, hk = _lap("rowTable", t, hk) end

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
    -- Order matters: bakes that depend on others (gateLine reads gates,
    -- costLine reads costEntries) come after the producers.
    R:_bakeItemAugmentBackfill(row)  -- row.achievement / row.achievementID from aug.sources type=1
    if t then t, hk = _lap("overrides+augment", t, hk) end
    R:_bakeTags(row)         -- row.expansion, row.sizeLabel, row.tags(+Label), row.dataTags
    R:_bakeCategory(row)     -- row.categoryLabel
    R:_bakePlacement(row)    -- row.placementLabel (budget icon prefixed)
    if t then t, hk = _lap("tags+category+placement", t, hk) end
    R:_bakeVendors(row)      -- per-vendor enrichment + row.vendorLines[]
    if t then t, hk = _lap("vendors", t, hk) end
    R:_bakeCost(row)         -- row.costEntries (unified) + row.costLine
    if t then t, hk = _lap("cost", t, hk) end
    R:_bakeRecipe(row)       -- row.recipe + row.recipeLabel (MUST precede _bakeSourceTypes,
                             -- which reads row.recipe to assign sourceType=6 / CRAFTED)
    R:_bakeSourceTypes(row)  -- row.sourceType / sourceName / sourceDetail (vendor-first)
    R:_bakeBonusXp(row)      -- row.bonusXpLabel (first-acquisition reward chip)
    if t then t, hk = _lap("recipe+sourceTypes+bonus", t, hk) end
    R:_bakeVariantDyes(row, variants)  -- row.dyedVariants[] (per-owned-variant dye derivation)
    if t and row.variants then t, hk = _lap("variantDyes", t, hk) end   -- only rows that had variants to walk
    -- Single canonical source/gate bake. Produces row.sourceTags[] in
    -- SOURCE_KIND_PRIORITY order; entries carry text + extras (factionPrefix,
    -- achievementID, ...) for kinds that have them, nothing for chip-only
    -- kinds (DROP, VENDOR, etc.). row.gateLine + row.primarySourceCode are
    -- thin derivations of sourceTags[1] kept for backward-compat consumers.
    R:_bakeSourceTags(row)
    if t then _lap("sourceTags", t, hk) end

    return row
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

-- _bakeTags: classify dataTagsByID into expansion / size / styles-or-factions / other.
--   row.expansion / expansionLabel, sizeLabel, tags / tagsLabel (Styles+Factions),
--   dataTagsByID (verbatim). Expansion colors are Palette (scheme-invariant).
-- _classifyTag: inner helper extracted from the loop to keep _bakeTags flat.
local function _classifyTag(row, tagID, displayName, descriptive, styleFaction, getCategory)
    local group = R.tagIDToGroup[tagID]   -- tagIDToGroup is init'd to {} at load (line ~47), never nil
    if group == "Expansion" then row.expansion = displayName; return end
    if group == "Size"      then row.sizeLabel = displayName; return end
    descriptive[#descriptive + 1] = displayName
    if getCategory then
        local cat = getCategory(tagID)
        if cat == "Styles" or cat == "Factions" then
            styleFaction[#styleFaction + 1] = displayName
        end
    end
end

function R:_bakeTags(row)
    local descriptive, styleFaction = {}, {}
    local getCategory = HDG.TagData and HDG.TagData.GetCategory  -- exception(false-positive): HDG.TagData is TOC-guaranteed at runtime; headless test mock omits it
    if row.dataTagsByID then
        for tagID, displayName in pairs(row.dataTagsByID) do
            _classifyTag(row, tagID, displayName, descriptive, styleFaction, getCategory)
        end
        table.sort(descriptive)
        table.sort(styleFaction)
    end
    -- (dataTags / dataTagsLabel used to be stamped here too; nothing read them.)
    row.tags          = styleFaction
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
-- canWaypoint) + bake vendorLines[] for direct row-factory use.
-- _resolveVendorNpc: extracted from loop to keep _bakeVendors flat.
local function _resolveVendorNpc(v, Aug)
    local npcID = Aug and Aug:ResolveName(v.name, v.zone)
    v.npcID       = npcID
    v.canWaypoint = npcID ~= nil
    if not npcID then return end
    local meta = Aug:Get(npcID)
    if not meta then return end
    v.mapID   = meta.mapID
    v.x       = meta.x
    v.y       = meta.y
    v.faction = v.faction ~= "" and v.faction or (meta.faction or "N")
    -- VendorAugment is authoritative for vendor location: overwrite the (often
    -- wrong) catalog zone. Vendors not in VendorAugment fall through the early
    -- returns above and keep their catalog zone. This makes the zone filter,
    -- the byVendor index, and the per-item vendor display agree on one zone.
    v.zone    = meta.zone or v.zone
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
    if not row.vendors then row.vendors, row.vendorLines = {}, {}; return end
    _dropNotSoldBy(row)
    local Aug = HDG.StaticData.VendorAugment
    local lines = {}
    for _, v in ipairs(row.vendors) do
        _resolveVendorNpc(v, Aug)
        -- Baked line: "Name - Zone - 44.2, 62.7"
        local parts = { v.name }
        if v.zone and v.zone ~= "" then parts[#parts+1] = v.zone end
        if v.x and v.y and v.x > 0 and v.y > 0 then
            parts[#parts+1] = string.format("%.1f, %.1f", v.x, v.y)
        end
        lines[#lines+1] = table.concat(parts, " - ")
    end
    row.vendorLines = lines
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

-- _bakeCost: unify vendor cost + override source cost into {currencyID, amount} entries
-- + bake costLine. row.costEntries for structured access; row.costLine for direct render.

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
local function _costFromVendor(vendor)
    if not vendor then return nil end  -- exception(nullable): row.vendors[1] on a vendorless row
    if not (vendor.costEntries and #vendor.costEntries > 0) then return nil end  -- exception(nullable): priceless vendor block
    local entries = {}
    for _, e in ipairs(vendor.costEntries) do
        entries[#entries + 1] = { currencyID = e.currencyID, itemID = e.itemID, amount = e.amount, icon = e.icon }
    end
    return entries
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
-- _bakeCost already built (nil when the head vendor carries no price), so the
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

function R:_bakeCost(row)
    local GOLD   = HDG.Constants.CURRENCY_GOLD
    -- Explicit CatalogOverrides `costOverride` wins: Blizzard's catalog sourceText
    -- lags merchant hotfixes (MOTHER's Chamber of Heart items shipped 100000 in the
    -- catalog while the vendor charged 10000). Stamp it onto every vendor so the
    -- vendor list, cost line, and variants all agree. Remove when the catalog is fixed.
    if row.costOverride then
        local oe = _entriesFromCostSpec(row.costOverride, GOLD)
        for _, v in ipairs(row.vendors or {}) do v.costEntries = oe end
        row.costEntries  = oe
        row.costLine     = _formatCostLine(oe)
        row.costVariants = { row.costLine }
        return
    end
    local vendor = row.vendors and row.vendors[1]
    local vendorEntries = _costFromVendor(vendor)
    local entries = vendorEntries or _costFromOverrideSources(row.sources, GOLD)
    row.costEntries = entries or {}
    row.costLine    = _formatCostLine(entries)
    -- Per-option lines (>=1 when any cost). Multi-option drives vendor list to show item once per option.
    -- Only the VENDOR-derived head feeds the variants: an override-sourced cost is
    -- not a vendor option, exactly as before.
    local variants = _costVariants(row, vendorEntries, vendorEntries and row.costLine or nil)
    if #variants == 0 and row.costLine ~= "" then variants = { row.costLine } end
    row.costVariants = variants
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
local function _composeSourceText(rec)
    if not rec then return nil end   -- exception(nullable): row carries only the source kinds it has
    if rec.zone and rec.zone ~= "" then
        return rec.source .. " (" .. rec.zone .. ")"
    end
    return rec.source
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
            row.sourceName = src.name and _composeSourceText({ source = src.name, zone = src.detail }) or ""
        else
            row.sourceType, row.sourceName = 0, ""
        end
    end
end

-- _bakeSourceTags: canonical source/gate bake. Produces:
--   row.sourceTags[] -- SOURCE_KIND_PRIORITY-ordered list of { kind, text?, ... }
--   row.gateLine     -- compact one-liner from sourceTags[1] (for row factories)
--   row.primarySourceCode -- donor code of sourceTags[1].kind (HDG-compat)
-- DROP fallback when no other signal exists (chip rendering always has something).
-- Aug code 11 (PROFESSION) and 3 (WorldQuest->QUEST) handled as edge cases.
-- _repTagEntry: extracts REP entry; static gate only (live progress via RepObserver).
local function _repTagEntry(row, aug)
    local fg = row.factionGate
    if fg and fg.factionName and fg.factionName ~= "" then
        local standing  = fg.standing or ""
        local factionID = (aug and aug.factionID) or _factionIDByName(fg.factionName)
        return {
            text          = (standing ~= "") and (standing .. " with " .. fg.factionName) or fg.factionName,
            factionName   = fg.factionName,
            standing      = standing,
            factionID     = factionID,
            requiredCode  = _standingStringToCode(standing),
            factionPrefix = _factionPrefixFor(factionID),
        }
    end
    if aug and aug.factionName and aug.factionName ~= "" then
        local standing = _repStandingFromMinRep(aug.minRep) or ""
        return {
            text          = (standing ~= "") and (standing .. " with " .. aug.factionName) or aug.factionName,
            factionName   = aug.factionName,
            standing      = standing,
            factionID     = aug.factionID,
            minRep        = aug.minRep,
            requiredCode  = aug.minRep,   -- ItemAugment minRep IS the standing code
            factionPrefix = _factionPrefixFor(aug.factionID),
        }
    end
    if aug and aug.factionID then return {} end   -- chip-only REP
    return nil
end

-- One source kind per row at most; the first contribution wins (catalog signal
-- before augment before override, in call order below). File-local rather than
-- a closure per row: the sweep runs this 2,052 times (2026-09-13 audit).
local function _emitSourceTag(byKind, kind, entry)
    if not kind or byKind[kind] then return end
    entry.kind = kind
    byKind[kind] = entry
end

function R:_bakeSourceTags(row)
    local aug = HDG.StaticData.ItemAugment:Get(row.itemID)
    local byKind = {}     -- {[kind] = entry} -- dedupes per-kind contributions
    local function emit(kind, entry) _emitSourceTag(byKind, kind, entry) end

    local repEntry = _repTagEntry(row, aug)
    if repEntry then emit("REP", repEntry) end

    -- Catalog-derived gates (text-carrying).
    if row.quest and row.quest ~= "" then
        emit("QUEST", { text = row.quest })
    end
    if row.achievement and row.achievement ~= "" then
        emit("ACH", { text = row.achievement, achievementID = row.achievementID })
    end
    if row.recipe and row.recipe.expansion and row.recipe.expansion ~= "" then
        emit("CRAFT", {
            text       = row.recipe.expansion,
            profession = row.recipe.profession,
        })
    elseif row.recipe then
        -- Recipe present but no expansion string -- chip-only CRAFT.
        emit("CRAFT", {})
    end

    -- Non-gating signals: chip-only or "Source (Zone)" when descriptor text exists.
    -- Drop/Treasure/Event come from _ParseSourceText (stamps row.drop/treasure/event).
    if row.vendors and #row.vendors > 0 then emit("VENDOR", {}) end
    if row.drop      then emit("DROP",     { text = _composeSourceText(row.drop)     }) end
    if row.treasure  then emit("TREASURE", { text = _composeSourceText(row.treasure) }) end
    if row.event     then emit("EVENT",    { text = _composeSourceText(row.event)    }) end
    if row.shop      then emit("SHOP",     {}) end   -- catalog bare "Shop"/"In-Game Shop" line
    if row.promo     then emit("PROMO",    {}) end   -- catalog bare "Promotion" line

    -- ItemAugment signals: catalog-undetectable kinds (SHOP/PROMO/TREASURE/DROP/etc).
    -- VENDOR is chip-only. emit() dedupes per kind (catalog signal wins).
    if aug and aug.sources then
        for _, s in ipairs(aug.sources) do
            local kind = _kindForSourceType(s.type)
            local k = kind and kind.key
            if k == "VENDOR" then
                emit(k, {})
            elseif k then
                local txt = (s.name and s.name ~= "")
                    and _composeSourceText({ source = s.name, zone = s.detail }) or nil
                emit(k, { text = txt })
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
                emit(k, {})
            elseif k then
                local txt = s.name and _composeSourceText({ source = s.name, zone = s.detail }) or nil
                emit(k, { text = txt })
            end
        end
    end

    -- No source signal at all -> honest chip-only [UNKN], never [DROP].
    -- Defaulting to DROP masked catalog/data gaps; UNKN surfaces them (and is
    -- filterable). DROP now appears only when the data actually says "Drop:".
    if next(byKind) == nil then emit("UNKN", {}) end

    -- Sort by SOURCE_KIND_PRIORITY; head entry is highest-priority kind (gateLine + primarySourceCode).
    local tags = {}
    for _, key in ipairs(HDG.Constants.SOURCE_KIND_PRIORITY) do
        if byKind[key] then tags[#tags+1] = byKind[key] end
    end
    row.sourceTags = tags

    -- Derived single-value fields for back-compat.
    local head = tags[1]
    if head and head.text then
        -- Compact "[CHIP]  text" with optional faction crest prefix.
        local prefix = head.factionPrefix and (head.factionPrefix .. " ") or ""
        row.gateLine = prefix .. HDG.Format.SourceChip(head.kind) .. "  " .. head.text
    else
        row.gateLine = nil
    end
    row.primarySourceCode = (head and HDG.Constants.SOURCE_KIND_BY_KEY[head.kind].donorCode) or 0
end

-- _bakeBonusXp: first-acquisition XP chip. Baked when bonus > 0; render gated by isOwned at consumer.
function R:_bakeBonusXp(row)
    local fab = row.firstAcquisitionBonus or 0  -- exception(boundary): catalog struct field sparse
    if fab > 0 then
        row.bonusXpLabel = XP_ICON .. " +" .. fab .. " XP"
    end
end

-- _bakeRecipe: cross-join with StaticData.Recipes. row.recipe nil when not crafted;
-- row.recipeLabel = "Profession - Requires Rep" for the detail panel.
function R:_bakeRecipe(row)
    local Recipes = HDG.StaticData.Recipes
    if not Recipes then row.recipe, row.recipeLabel = nil, nil; return end
    local rec = Recipes:Get(row.itemID)
    if not rec then row.recipe, row.recipeLabel = nil, nil; return end
    row.recipe = rec
    local parts = {}
    if rec.profession   and rec.profession   ~= "" then parts[#parts+1] = rec.profession end
    if rec.requiresRep  and rec.requiresRep  ~= "" then parts[#parts+1] = rec.requiresRep end
    row.recipeLabel = table.concat(parts, " - ")
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
local function _flushVendor(vendors, v)
    if not v then return end
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
            local entries = _extractCostEntries(raw)
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
            local entries = _extractCostEntries(raw)
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

function R:GetCategoryForItem(itemID)
    local row = R:GetRow(itemID)
    return row and row.category
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

function R:GetAllVendorNames()
    if not R:IsReady() then return {} end
    return R.allVendorNames
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
    row.isOwned = R:IsOwned(row)
end

function R:ClearStore()
    R.byDecorID = {}
    R.byItemID  = {}
    R.byVendor  = {}
    R.allVendorNames = {}
    R._catalogSchemaVersion = 0
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
                local view = HDG.Store:GetState().account.ui.view
                if view then R:_OnViewChange(view) end
            elseif actionType == A.MAIN_WINDOW_OPENING then
                -- Load unconditionally on first open (most views derive from the catalog).
                -- RequestLoad is idempotent; re-opens are no-ops.
                R:RequestLoad("main-window-opening")
                R:ReconcileRooms()          -- live room catalog (cheap; Layout-mode searcher)
                R:QueueCategoryTreeRebuild()   -- Blizzard category/subcategory nav snapshot
            elseif actionType == A.CATALOG_FORCE_RELOAD then
                R:ReconcileFull("manual-refresh")   -- (parked) catalog-intro Refresh button
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
        if self._storeToken then
            HDG.Store:Unsubscribe(self._storeToken)
            self._storeToken = nil
        end
    end,
})
