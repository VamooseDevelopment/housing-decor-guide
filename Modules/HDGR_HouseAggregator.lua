-- HDG.HouseAggregator
-- ============================================================================
-- Single-pass scan producing the snapshot consumed by HouseTab dashboard
-- widgets. Runs debounced (100ms) on Store dispatches that mutate its inputs.
-- BOUNDARY MODULE: may call Blizzard APIs (pcall-wrapped); selectors that
-- derive from the snapshot are pure functions of state.

HDG = HDG or {}
HDG.HouseAggregator = HDG.HouseAggregator or {}
local HA = HDG.HouseAggregator

HA.DEBOUNCE_SECONDS = 0.1
HA._scheduled = HA._scheduled or false
HA._dirty     = HA._dirty or false   -- a trigger landed while no consuming view was showing

-- Log tag for Blizzard API boundary failures inside this module's pcalls.
-- Surfaces silent SECRET-value / cold-cache / API-unavailable cases.

-- ===== BuildSnapshot primitives =============================================

-- Capacity: 3 sync C_HousingCatalog APIs. pcall-wrapped: namespace absent in headless tests.
local function _capacitySnapshot()
    if not _G.C_HousingCatalog then return nil end
    local C = _G.C_HousingCatalog
    if not (C.GetDecorTotalOwnedCount and C.GetDecorMaxOwnedCount) then return nil end
    local owned, exempt = C.GetDecorTotalOwnedCount()
    local maxOwn = C.GetDecorMaxOwnedCount()
    -- API can return nil on cold cache; coerce to 0 so arithmetic stays well-typed.
    owned, exempt, maxOwn = owned or 0, exempt or 0, maxOwn or 0  -- exception(boundary): housing owned-count getters nil on cold cache
    local pct = (maxOwn > 0) and (owned / maxOwn) or 0
    local tier = "healthy"
    if pct >= 0.95 then tier = "full"
    elseif pct >= 0.80 then tier = "warn" end
    return { owned = owned, max = maxOwn, exempt = exempt, pct = pct, tier = tier }
end

-- Velocity: count "learned" entries in the last 30 days from craft history,
-- extrapolate per-day / per-week, project ETA to next title tier.
local function _velocitySnapshot(craftEntries, currentTier, collectedAll)
    if type(craftEntries) ~= "table" or #craftEntries == 0 then return nil end
    local now = (_G.time and _G.time()) or 0
    local windowStart = now - (30 * 24 * 60 * 60)
    local learned = 0
    for _, e in ipairs(craftEntries) do
        if e.eventType == "learned" and (e.timestamp or 0) >= windowStart then
            learned = learned + 1
        end
    end
    if learned == 0 then return nil end
    local perDay = learned / 30
    local out = { perDay = perDay, perWeek = perDay * 7 }
    if currentTier and currentTier.next then
        local remaining = (currentTier.next.threshold or 0) - (collectedAll or 0)
        if remaining > 0 and perDay > 0 then
            out.daysToNextTier  = math.ceil(remaining / perDay)
            out.nextTierName    = currentTier.next.name
        end
    end
    return out
end

-- Recent activity: last 5 "learned" craft-history entries with name+icon joined
-- from the catalog inside the snapshot (so renderers never read Store mid-paint).
-- Every catalog lookup below reads the observer's byItemID instead of building a
-- private itemID index: four such indexes cost 805 KB per snapshot (2026-09-13).
local function _recentActivitySnapshot(state)
    local entries = state.account.craft.history.entries  -- strict: NewCraft seeds history.entries (EnsureCraft migrates)
    if type(entries) ~= "table" then return {} end
    local byItemID = HDG.HousingCatalogObserver.byItemID   -- the observer's own index; the rows are the same tables as byDecorID
    local out = {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e and e.eventType == "learned" and e.itemID then
            local row = byItemID[e.itemID]
            out[#out + 1] = {
                itemID    = e.itemID,
                timestamp = e.timestamp,
                name      = (row and row.name) or ("Item " .. e.itemID),
                iconID    = row and row.iconTexture,
            }
            if #out >= 5 then break end
        end
    end
    return out
end

-- Favorites: walk catalog filtering by state.account.favorites; return
-- top 5 favorited items (collected and uncollected, with isCollected flag).
local function _favoritesSnapshot(catalog, owned, favorites)
    if type(favorites) ~= "table" then return {} end
    local raw = {}
    for decorID, row in pairs(catalog) do
        local itemID = row.itemID
        if itemID and favorites[itemID] == true then
            raw[#raw + 1] = {
                itemID      = itemID,
                name        = row.name or ("Item " .. itemID),
                iconID      = row.iconTexture,
                isCollected = HDG.HousingCatalogObserver:IsOwned(row),
            }
        end
    end
    table.sort(raw, function(a, b) return (a.name or "") < (b.name or "") end)
    local out = {}
    for i = 1, math.min(5, #raw) do out[i] = raw[i] end
    return out
end

-- Tags that are not styles. Size and Expansion have their own widgets: matched
-- by group through the observer's tagIDToGroup, which names each group by its
-- stable groupID. The skiplist this replaces read the group's `name` (Blizzard's
-- field is groupName) and keyed it by the tag table, so it skipped nothing and
-- Top Styles ranked Midnight, Large, Medium (test audit B2, 2026-10-31).
-- Alliance and Horde sit in Blizzard's Style group but topped the list once the
-- rest were out; skipped by tagID (owner ruling 2026-10-31).
local NOT_STYLE_GROUPS = { Size = true, Expansion = true }

local function _isStyleTag(tagID, tagGroup)
    return not NOT_STYLE_GROUPS[tagGroup[tagID]] and not HDG.Constants.FACTION_TAG_IDS[tagID]
end

-- Boundary helper for collection definitions (same rationale as above).
local function _collectionDefsOrNil()
    if type(_G.HDGR_CollectionDefinitions) ~= "table" then return nil end
    return HDG.StaticData.Collections:GetDefinitions()
end

-- Event card snapshot: returns { items[], collected, total, pct } for a single
-- event vendor (npcID). Event vendors are placeholder-hidden in row.vendors and
-- surfaced via override sources; the catalog observer indexes BOTH into byVendor
-- and stamps each entry's resolved npcID -- so we match by ID, no name matching.
-- Add one vendor item to the event-card snapshot, stamping owned/icon/name from
-- the observer's row.
local function _accumulateEventItem(out, itemID)
    local R     = HDG.HousingCatalogObserver
    local row   = R.byItemID[itemID]   -- exception(nullable): a vendor item the catalog has no row for
    local owned = row ~= nil and R:IsOwned(row)
    out.items[#out.items + 1] = {
        itemID = itemID, owned = owned,
        iconID = row and row.iconTexture,
        name   = row and row.name,
    }
    if owned then out.collected = out.collected + 1 end
end

local function _eventCardSnapshot(npcID)
    local out = { items = {}, collected = 0, total = 0, pct = 0 }
    if not npcID then return out end
    local itemIDs = HDG.HousingCatalogObserver:GetItemsByNpc(npcID)  -- exception(nullable): catalog not swept yet, or an event vendor it sells nothing at
    for _, itemID in ipairs(itemIDs or {}) do
        _accumulateEventItem(out, itemID)
    end
    out.total = #out.items
    out.pct   = out.total > 0 and (out.collected / out.total) or 0
    return out
end

-- records snapshot: personal stats from the craft-history log.
--   totalLearned, totalCrafted, firstActivity, houseAgeDays, bestDay, bestDate, longestStreak
local DAY_SECONDS = 86400
local function _recordsSnapshot(state)
    local entries = state.account.craft.history.entries  -- strict: NewCraft seeds history.entries (EnsureCraft migrates)
    local out = {
        totalLearned = 0, totalCrafted = 0,
        firstActivity = nil, houseAgeDays = 0,
        bestDay = 0, bestDate = nil,
        longestStreak = 0,
    }
    if type(entries) ~= "table" or #entries == 0 then return out end

    local perDay = {}
    for _, e in ipairs(entries) do
        -- Pre-1.0 entries may lack `timestamp`; ts=0 filtered below so they don't poison perDay.
        local ts = e.timestamp or 0  -- migration
        if e.eventType == "learned" then out.totalLearned = out.totalLearned + 1 end
        if e.eventType == "crafted" then out.totalCrafted = out.totalCrafted + 1 end
        if ts > 0 then
            if not out.firstActivity or ts < out.firstActivity then
                out.firstActivity = ts
            end
            local key = (_G.date and _G.date("%Y-%m-%d", ts)) or tostring(math.floor(ts / DAY_SECONDS))
            perDay[key] = (perDay[key] or 0) + 1
        end
    end

    local now = (_G.time and _G.time()) or 0
    if out.firstActivity and now > out.firstActivity then
        out.houseAgeDays = math.floor((now - out.firstActivity) / DAY_SECONDS)
    end

    for date, count in pairs(perDay) do
        if count > out.bestDay then
            out.bestDay  = count
            out.bestDate = date
        end
    end

    -- Longest streak: sort active dates ascending, walk for consecutive runs.
    local dates = {}
    for d in pairs(perDay) do dates[#dates + 1] = d end
    table.sort(dates)
    local cur, best, prevT = 0, 0, nil
    for _, d in ipairs(dates) do
        local y, m, dy = d:match("(%d+)-(%d+)-(%d+)")
        local yn, mn, dyn = tonumber(y or ""), tonumber(m or ""), tonumber(dy or "")
        if yn and mn and dyn and _G.time then
            local t = _G.time({ year = yn, month = mn, day = dyn })
            if prevT and (t - prevT) <= (DAY_SECONDS + 60) then
                cur = cur + 1
            else
                cur = 1
            end
            if cur > best then best = cur end
            prevT = t
        end
    end
    out.longestStreak = best

    return out
end

-- craftableNow snapshot: how many known decor recipes can be crafted now (+ >=50% tier).
-- Uses Mogul:Candidates for the known-recipe list; inlines readiness math (PowerCrafter DB shape differs).
-- One recipe's readiness: the share of its reagents (lumber included) held, each
-- capped at what the recipe needs. Every recipe lists at least one reagent.
local function _heldShare(recipe, counts)
    local need, have = 0, 0
    for itemID, req in pairs(recipe.reagents) do
        need = need + req.qty
        have = have + math.min(counts[itemID], req.qty)
    end
    return have / need
end

local function _craftableNowSnapshot()
    local counts = HDG.BagObserver:GetCounts()
    local canNow, almost = 0, 0
    for _, recipe in ipairs(HDG.Mogul:Candidates("char")) do
        local share = _heldShare(recipe, counts)
        if     share >= 1.0 then canNow = canNow + 1
        elseif share >= 0.5 then almost = almost + 1 end
    end
    return { canCraftNow = canNow, almostCraftable = almost }
end

-- goblinTopLumber snapshot: top-5 craftable decor by profit-per-lumber.
local function _goblinTopLumberSnapshot()
    local Goblin = HDG.Goblin
    if not (Goblin and Goblin.BuildProfitData) then return {} end
    -- Goblin is an internal Lattice module; strict call. If it errors,
    -- that's a real bug to surface, not paper over.
    local rows = Goblin:BuildProfitData(HDG.Selectors:Call("recipes.db", HDG.Store:GetState()))
    if type(rows) ~= "table" then return {} end
    local CI = _G.C_Item  -- exception(boundary): sync icon lookup
    local filtered = {}
    for _, r in ipairs(rows) do
        if r.lumberValue and r.lumberValue > 0 then filtered[#filtered + 1] = r end
    end
    table.sort(filtered, function(a, b) return a.lumberValue > b.lumberValue end)
    local out = {}
    for i = 1, math.min(5, #filtered) do
        local r = filtered[i]
        local icon
        if CI and CI.GetItemIconByID and r.itemID then
            icon = CI.GetItemIconByID(r.itemID)
        end
        out[i] = {
            itemID      = r.itemID,
            name        = r.name,
            iconID      = icon,
            lumberValue = r.lumberValue,
            lumberType  = r.lumberType,
            expansion   = r.expansion,
        }
    end
    return out
end

-- nextRewards snapshot: highest-level owned house, reads cached rewards for level+1 (or maxLevel at cap).
-- Returns nil when cache unpopulated (HousingObserver kicks async fetch on HOUSE_LEVEL_UPDATED).
local function _nextRewardsSnapshot(state)
    local owned = state.session.house.ownedHouses
    local level, maxLevel
    for _, h in pairs(owned) do
        if h and h.level and (not level or h.level > level) then
            level    = h.level
            maxLevel = h.maxLevel
        end
    end
    if not level or not maxLevel then return nil end
    local target = (level < maxLevel) and (level + 1) or maxLevel
    local cached = state.session.house.rewardsByLevel
                   and state.session.house.rewardsByLevel[target]
    return {
        level       = level,
        maxLevel    = maxLevel,
        targetLevel = target,
        atMax       = level >= maxLevel,
        rewards     = (cached and cached.rewards) or nil,
    }
end

-- Themed sets: top 4 by completion ratio (incomplete-first, then highest pct).
-- One definition's pattern test. `includes` is OR, `excludes` overrides.
local function _nameMatches(name, includes, excludes)
    local hit = false
    if includes then
        for i = 1, #includes do
            if name:find(includes[i], 1, true) then hit = true; break end
        end
    end
    if not hit then return false end
    if excludes then
        for i = 1, #excludes do
            if name:find(excludes[i], 1, true) then return false end
        end
    end
    return true
end

local function _themedSetsSnapshot(catalog)
    local defs = _collectionDefsOrNil()
    if type(defs) ~= "table" then return {} end
    local R = HDG.HousingCatalogObserver

    -- One accumulator per definition, then a single catalog walk that tests every
    -- row against every definition. The previous shape indexed the catalog into
    -- 2,000 scratch rows and minted two empty tables per test: 385 KB a snapshot.
    local sets = {}
    for key, def in pairs(defs) do
        sets[#sets + 1] = {
            id = key, name = def.displayName or key, icon = def.icon,
            collected = 0, total = 0, pct = 0, def = def,
        }
    end
    for _, row in pairs(catalog) do
        local name = row.name
        if name then
            local owned = R:IsOwned(row)
            for i = 1, #sets do
                local s = sets[i]
                if _nameMatches(name, s.def.namePatterns, s.def.excludePatterns) then
                    s.total = s.total + 1
                    if owned then s.collected = s.collected + 1 end
                end
            end
        end
    end

    local kept = {}
    for i = 1, #sets do
        local s = sets[i]
        if s.total >= 5 then
            s.def = nil
            s.pct = s.collected / s.total
            kept[#kept + 1] = s
        end
    end
    -- Sort: incomplete (pct < 1) first, by gap ascending; then full.
    table.sort(kept, function(a, b)
        local aFull = a.pct >= 1
        local bFull = b.pct >= 1
        if aFull ~= bFull then return not aFull end
        if aFull then return a.pct > b.pct end
        return (a.total - a.collected) < (b.total - b.collected)
    end)
    local out = {}
    for i = 1, math.min(4, #kept) do out[i] = kept[i] end
    return out
end

-- Top vendors: top 3 by uncollected item count.
local function _topVendorsSnapshot(_catalog, _owned)
    local R = HDG.HousingCatalogObserver
    if not R:IsReady() then return {} end
    local rows = {}
    -- byVendor keyed by "<name>::<zone>"; use ven.name for display.
    for _, ven in pairs(R.byVendor) do
        local uncollected = 0
        for _, itemID in ipairs(ven.items) do
            if not R:IsOwned(itemID) then uncollected = uncollected + 1 end
        end
        if uncollected > 0 then
            rows[#rows + 1] = { name = ven.name, zone = ven.zone, uncollected = uncollected }
        end
    end
    table.sort(rows, function(a, b) return a.uncollected > b.uncollected end)
    local out = {}
    for i = 1, math.min(3, #rows) do out[i] = rows[i] end
    return out
end

-- Decor currency cache: ids (iteration order) + expByID (expansion lookup for chip tinting).
-- Cost-side icon->id resolution is in the observer parser (costEntries carries pre-resolved currencyID).
local _decorCurrencyCache = nil
local function _ensureDecorCurrencyCache()
    if _decorCurrencyCache then return _decorCurrencyCache end
    local ids, expByID = {}, {}
    for _, c in ipairs(HDG.Constants.HOUSING_DECOR_CURRENCY_DATA) do
        ids[#ids + 1] = c.id
        expByID[c.id] = c.expansion
    end
    _decorCurrencyCache = { ids = ids, expByID = expByID }
    return _decorCurrencyCache
end

-- Wallet: lumber bag counts + housing currencies via C_CurrencyInfo.
-- housingNeed = vendor-cost aggregation from the catalog walk. Lumber sorted count-desc.
local function _lumberList()
    local Bag = HDG.BagObserver
    local counts = Bag and Bag.GetCounts and Bag:GetCounts() or nil  -- exception(boundary): optional module / not yet built
    if not counts then return {} end
    local lumber = {}
    for _, info in ipairs(HDG.Constants.LUMBER_DATA) do
        local n = counts[info.id] or 0  -- exception(boundary): sparse map
        if n > 0 then
            lumber[#lumber + 1] = {
                id        = info.id,
                name      = info.shortName or info.name,
                count     = n,
                expansion = info.expansion,
            }
        end
    end
    table.sort(lumber, function(a, b) return a.count > b.count end)
    return lumber
end

-- One housing-currency entry, or nil when irrelevant.
local function _currencyEntry(id, cache, housingNeed)
    local info = _G.C_CurrencyInfo.GetCurrencyInfo(id)
    if not info then return nil end
    local have = info.quantity or 0   -- exception(boundary): Blizz struct sparse
    local need = (housingNeed and housingNeed[id]) or 0
    if have <= 0 and need <= 0 then return nil end
    return {
        id        = id,
        name      = info.name or ("Currency " .. id),
        count     = have,
        needed    = need,
        cap       = info.maxQuantity,
        icon      = info.iconFileID,
        expansion = cache.expByID[id],
    }
end

-- Housing-currency list: tracked decor currencies the player has or needs.
local function _housingList(housingNeed)
    local cache = _ensureDecorCurrencyCache()
    local CCI = _G.C_CurrencyInfo
    if not (cache and CCI and CCI.GetCurrencyInfo) then return {} end
    local housing = {}
    for _, id in ipairs(cache.ids) do
        local entry = _currencyEntry(id, cache, housingNeed)
        if entry then housing[#housing + 1] = entry end
    end
    table.sort(housing, function(a, b)
        local aNeed = (a.needed or 0) > 0 and 1 or 0
        local bNeed = (b.needed or 0) > 0 and 1 or 0
        if aNeed ~= bNeed then return aNeed > bNeed end
        return a.count > b.count
    end)
    return housing
end

local function _walletSnapshot(housingNeed)
    return { lumber = _lumberList(), housing = _housingList(housingNeed) }
end

-- ===== C_CurrencyInfo readers for other modules ==============================
-- This module owns C_CurrencyInfo (ADR-011), so a module that needs a currency
-- read asks here rather than calling the namespace itself -- the merchant wallet
-- (MerchantObserver) does.

-- How much of a currency the player holds. 0 for a currency the client has no
-- record of yet (never earned on this character).
function HA:CurrencyQuantity(currencyID)
    local info = _G.C_CurrencyInfo.GetCurrencyInfo(currencyID)
    if not info then return 0 end   -- exception(boundary): nil for a currency this character has never seen
    return info.quantity
end

-- The currency ID inside a currency hyperlink (a vendor's extended cost).
function HA:CurrencyIDFromLink(link)
    return _G.C_CurrencyInfo.GetCurrencyIDFromLink(link)
end

-- Feature picks: deterministic per-calendar-week 4-item rotation across owned items.
local function _featuredSnapshot(catalog, owned)
    local collectedIDs = {}
    for decorID in pairs(owned) do
        local row = catalog[decorID]
        if row and row.itemID then collectedIDs[#collectedIDs + 1] = row.itemID end
    end
    if #collectedIDs == 0 then return {} end
    table.sort(collectedIDs)
    local n = #collectedIDs
    local seed = tonumber((_G.date and _G.date("%Y%W")) or "0") or 0
    local stride = math.max(1, math.floor(n / 4))
    local out = {}
    local byItemID = HDG.HousingCatalogObserver.byItemID
    for i = 0, 3 do
        local idx = ((seed + i * stride) % n) + 1
        local itemID = collectedIDs[idx]
        local row = byItemID[itemID]
        out[i + 1] = {
            itemID = itemID,
            name   = (row and row.name) or ("Item " .. itemID),
            iconID = row and row.iconTexture,
        }
    end
    return out
end

-- deriveSourcePrimary: thin accessor -- reads row.primarySourceCode baked by _bakeSourceTags.
local function deriveSourcePrimary(_itemID, row)
    return (row and row.primarySourceCode) or 0
end

-- ===== BuildSnapshot loop-body primitives ===================================
-- Each helper handles one accumulator concern for the single catalog walk.

-- housingNeed: sum amount per currency across uncollected vendor items.
-- `seen` is shared across a row's vendors so the same currency isn't double-counted.
-- Item-token costs (entries with itemID, no currencyID) are skipped on purpose:
-- housingNeed is a WALLET ledger keyed by currency, and a Mark of Honor is an
-- inventory item, not a wallet row.
local function _accumulateVendorCost(vendor, housingNeed, seen)
    if not vendor.costEntries then return end
    for _, e in ipairs(vendor.costEntries) do
        if e.currencyID and not seen[e.currencyID] then
            seen[e.currencyID] = true
            housingNeed[e.currencyID] = (housingNeed[e.currencyID] or 0) + e.amount
        end
    end
end

local function _accumulateHousingNeed(row, housingNeed)
    if not row.vendors then return end
    local seen = {}
    for _, v in ipairs(row.vendors) do
        _accumulateVendorCost(v, housingNeed, seen)
    end
end

-- Classify row to (srcType, expName). Defaults to (0, "Unknown") when catalog not ready.
local function _classifyRow(itemID)
    local R = HDG.HousingCatalogObserver
    if itemID and R and R:IsReady() then
        local catalogRow = R:GetRow(itemID)
        if catalogRow then
            return deriveSourcePrimary(itemID, catalogRow),
                   R:GetExpansionForItem(itemID) or "Unknown",
                   catalogRow
        end
    end
    return 0, "Unknown", nil
end

-- bySource + byExp counters. Lazy-create bucket on first sight; increment total + collected.
local function _bumpBucket(buckets, key)
    local b = buckets[key]
    if not b then
        b = { total = 0, collected = 0 }
        buckets[key] = b
    end
    return b
end

local function _countInto(b, isOwned)
    b.total = b.total + 1
    if isOwned then b.collected = b.collected + 1 end
end

-- A decor tagged with two expansions counts in both (owner ruling 2026-10-31), so the
-- expansion counts can add up to more than the decor total.
local function _accumulateSourceExp(row, isOwned, srcType, expName, bySource, byExp)
    _countInto(_bumpBucket(bySource, srcType), isOwned)
    for _, name in ipairs(HDG.Expansion.Members(expName)) do
        _countInto(_bumpBucket(byExp, name), isOwned)
    end
end

-- closeCards: composite (catID * 100000 + subID) key for category x subcategory buckets.
local function _accumulateSubBucket(row, isOwned, subBuckets)
    if not (row.categoryID and row.subcategoryID) then return end
    local key = row.categoryID * 100000 + row.subcategoryID
    local b = subBuckets[key]
    if not b then
        b = {
            catID = row.categoryID, subID = row.subcategoryID,
            categoryName    = row.categoryName    or tostring(row.categoryID),
            subcategoryName = row.subcategoryName or tostring(row.subcategoryID),
            total = 0, collected = 0,
        }
        subBuckets[key] = b
    end
    b.total = b.total + 1
    if isOwned then b.collected = b.collected + 1 end
end

-- styleAffinity: aggregate by tag name, skipping the tags that are not styles.
local function _accumulateStyleTags(row, isOwned, styleTagsOwned, styleTagsTotal)
    if not row.dataTagsByID then return end
    local tagGroup = HDG.HousingCatalogObserver.tagIDToGroup
    for tagID, tagName in pairs(row.dataTagsByID) do
        if type(tagName) == "string" and _isStyleTag(tagID, tagGroup) then
            styleTagsTotal[tagName] = (styleTagsTotal[tagName] or 0) + 1
            if isOwned then
                styleTagsOwned[tagName] = (styleTagsOwned[tagName] or 0) + 1
            end
        end
    end
end

-- Trophy detection: isUniqueTrophy flag OR Preyseeker Bust/Effigy by name.
-- Uncollected trophies count toward trophiesTotal but don't surface in the per-cohort lists.
local function _classifyTrophy(row, itemName)
    local isUnique = row.isUniqueTrophy == true
    local isPrey   = itemName:find("Preyseeker", 1, true)
                      and (itemName:find("Bust", 1, true) or itemName:find("Effigy", 1, true))
    return (isUnique or isPrey), isUnique
end

-- hotPicks: top uncollected by firstAcquisitionBonus (catalogRow may be nil in tests).
local function _collectHotPick(row, itemName, catalogRow)
    if row.firstAcquisitionBonus and row.firstAcquisitionBonus > 0 then
        local fv = catalogRow and catalogRow.vendors and catalogRow.vendors[1]
        return {
            itemID     = row.itemID,
            name       = itemName,
            iconID     = row.iconTexture,
            xp         = row.firstAcquisitionBonus,
            sourceName = fv and fv.name,
            zone       = fv and fv.zone,
        }
    end
end

-- Post-walk: stamp pct on every bucket (shared by bySource + byExp).
local function _stampPct(buckets)
    for _, b in pairs(buckets) do
        b.pct = (b.total > 0) and (b.collected / b.total) or 0
    end
end

-- Copy first N entries of an array (used by closestToComplete, topStyles, hotPicks).
local function _takeTopN(arr, n)
    local out = {}
    for i = 1, math.min(n, #arr) do out[i] = arr[i] end
    return out
end

-- Subcategories at 50-99% with >=5 items; top 3 by smallest gap.
local function _deriveClosestToComplete(subBuckets)
    local raw = {}
    for _, b in pairs(subBuckets) do
        if b.total >= 5 then
            local pct = b.collected / b.total
            if pct >= 0.5 and pct < 1.0 then raw[#raw + 1] = b end
        end
    end
    table.sort(raw, function(a, b) return (a.total - a.collected) < (b.total - b.collected) end)
    local out = _takeTopN(raw, 3)
    for i, b in ipairs(out) do
        out[i] = {
            categoryName    = b.categoryName,
            subcategoryName = b.subcategoryName,
            collected       = b.collected,
            total           = b.total,
            gap             = b.total - b.collected,
            pct             = b.collected / b.total,
        }
    end
    return out
end

-- Top-5 style tag names by total items (>=10 in bucket). pct on 0-100 scale.
local function _deriveTopStyles(styleTagsTotal, styleTagsOwned)
    local raw = {}
    for name, total in pairs(styleTagsTotal) do
        if total >= 10 then
            local got = styleTagsOwned[name] or 0  -- exception(boundary): sparse map
            raw[#raw + 1] = { name = name, collected = got, total = total, pct = got / total * 100 }
        end
    end
    table.sort(raw, function(a, b) return a.total > b.total end)
    return _takeTopN(raw, 5)
end

function HA:BuildSnapshot(state)
    local catalog = HDG.HousingCatalogObserver.byDecorID
    local owned   = state.account.collection.ownedDecorIDs
    local favorites = state.account.favorites or {}

    -- housingNeed: sum per currency across uncollected vendor items (per-row dedup).
    local housingNeed = {}

    -- Single-pass walk: produces bySource/byExp/closeBuckets/hotPicksRaw/
    -- topStylesAccum/trophyAccum in one iteration.
    local collectedAll, totalAll = 0, 0
    local trophiesTotal, trophiesCollected = 0, 0
    local uniques, prey = {}, {}
    local bySource, byExp = {}, {}
    local subBuckets = {}         -- composite key catID*100000 + subID
    local hotPicksRaw = {}
    local styleTagsOwned = {}     -- [tagName] = collected count
    local styleTagsTotal = {}     -- [tagName] = total count

    for _, row in pairs(catalog) do
        totalAll = totalAll + 1
        local isOwned = HDG.HousingCatalogObserver:IsOwned(row)
        if isOwned then collectedAll = collectedAll + 1 end

        local itemName = row.name or ""
        local itemID   = row.itemID
        local srcType, expName, catalogRow = _classifyRow(itemID)

        if not isOwned then _accumulateHousingNeed(row, housingNeed) end
        _accumulateSourceExp(row, isOwned, srcType, expName, bySource, byExp)
        _accumulateSubBucket(row, isOwned, subBuckets)
        _accumulateStyleTags(row, isOwned, styleTagsOwned, styleTagsTotal)

        local isTrophy, isUnique = _classifyTrophy(row, itemName)
        if isTrophy then
            trophiesTotal = trophiesTotal + 1
            if isOwned then
                trophiesCollected = trophiesCollected + 1
                local entry = { itemID = row.itemID, iconID = row.iconTexture,
                                name = itemName, isUnique = isUnique }
                if isUnique then uniques[#uniques + 1] = entry
                else             prey[#prey + 1]       = entry end
            end
        end

        if not isOwned then
            local hp = _collectHotPick(row, itemName, catalogRow)
            if hp then hotPicksRaw[#hotPicksRaw + 1] = hp end
        end
    end

    -- Trophy ordering: uniques (alpha) then prey (alpha).
    table.sort(uniques, function(a, b) return (a.name or "") < (b.name or "") end)
    table.sort(prey,    function(a, b) return (a.name or "") < (b.name or "") end)
    local trophies = {}
    for _, t in ipairs(uniques) do trophies[#trophies + 1] = t end
    for _, t in ipairs(prey)    do trophies[#trophies + 1] = t end

    _stampPct(bySource)
    _stampPct(byExp)

    local closestToComplete = _deriveClosestToComplete(subBuckets)
    local topStyles         = _deriveTopStyles(styleTagsTotal, styleTagsOwned)

    -- hotPicks: top 5 uncollected by firstAcquisitionBonus DESC.
    table.sort(hotPicksRaw, function(a, b) return (a.xp or 0) > (b.xp or 0) end)
    local hotPicks = _takeTopN(hotPicksRaw, 5)

    -- Title tier: walk TITLE_TIERS, find highest threshold the player meets.
    local tiers = HDG.StaticData.TitleTiers:GetAll()
    local titleTier = { current = tiers[1], prev = nil, next = tiers[2] }
    for i = 1, #tiers do
        if collectedAll >= tiers[i].threshold then
            titleTier.current = tiers[i]
            titleTier.prev    = tiers[i - 1]
            titleTier.next    = tiers[i + 1]
        end
    end

    -- Persona: dominant style tag (topStyles[1].name) for the subtitle fallback.
    local persona = (topStyles[1] and topStyles[1].name) or ""

    -- Velocity from craft history. nil when no recent activity.
    local craftEntries = state.account.craft.history.entries  -- strict: NewCraft seeds history.entries (EnsureCraft migrates)
    local velocity = _velocitySnapshot(craftEntries, titleTier, collectedAll)

    local wallet = _walletSnapshot(housingNeed)
    local eventNPCs = HDG.Constants.EVENT_VENDOR_NPCS or {}

    return {
        collectedAll      = collectedAll,
        totalAll          = totalAll,
        title             = titleTier.current.name,
        titleTier         = titleTier,
        trophies          = trophies,
        trophiesCollected = trophiesCollected,
        trophiesTotal     = trophiesTotal,
        bySource          = bySource,
        byExp             = byExp,
        closestToComplete = closestToComplete,
        topStyles         = topStyles,
        persona           = persona,
        hotPicks          = hotPicks,
        featured          = _featuredSnapshot(catalog, owned),
        capacity          = _capacitySnapshot(),
        velocity          = velocity,
        favorites         = _favoritesSnapshot(catalog, owned, favorites),
        themedSets        = _themedSetsSnapshot(catalog),
        topVendors        = _topVendorsSnapshot(catalog, owned),
        recentActivity    = _recentActivitySnapshot(state),
        walletLumber      = wallet.lumber,
        walletHousing     = wallet.housing,
        ritualSites       = _eventCardSnapshot(eventNPCs.ritualSites),
        abyssAnglers      = _eventCardSnapshot(eventNPCs.abyssAnglers),
        decorDuels        = _eventCardSnapshot(eventNPCs.decorDuels),
        nextRewards       = _nextRewardsSnapshot(state),
        craftableNow      = _craftableNowSnapshot(),
        goblinTopLumber   = _goblinTopLumberSnapshot(),
        records           = _recordsSnapshot(state),
    }
end

-- ============================================================================
-- Dispatch + Store subscription.
-- ============================================================================

-- The persisted capacity cache is what the buy picker reads, at a merchant, with
-- the HDG window usually closed. It is refreshed on every trigger (three sync API
-- reads) once the window has opened this session, and before that while a vendor
-- is open (OnStoreNotify), and dispatched only when the reading changed, so it
-- stays live while the dashboard build below is gated off by view.
function HA:_RefreshCapacityCache(state)
    local cap = _capacitySnapshot()
    if not (cap and cap.max > 0) then return end   -- max==0 is a cold reading, not a real cap -> don't cache it
    local cache = state.account.houseCapacityCache   -- exception(nullable): false until first capture
    if cache and cache.owned == cap.owned and cache.exempt == cap.exempt and cache.max == cap.max then return end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.HOUSE_CAPACITY_CACHED,
        payload = { owned = cap.owned, exempt = cap.exempt, max = cap.max },
    })
end

-- A dashboard build costs 1.2 to 1.6 MB and only the House and Projects views
-- read the result, so a build runs only while one of them is on screen; a
-- trigger that lands at any other time leaves the snapshot dirty and the next
-- notify that finds a consuming view showing builds once (2026-09-13 audit).
function HA:DispatchSnapshot()
    if self._scheduled then return end
    self._scheduled = true
    _G.C_Timer.After(self.DEBOUNCE_SECONDS, function()
        self._scheduled = false
        local state = HDG.Store:GetState()
        self:_RefreshCapacityCache(state)
        -- A build is owed (dirty) and someone is looking; otherwise the flag waits.
        if not (self._dirty and HDG.HousingObserver.HouseLevelViewActive(state)) then return end
        self._dirty = false
        local snapshot = self:BuildSnapshot(state)
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.HOUSE_SNAPSHOT_UPDATED,
            payload = { snapshot = snapshot },
        })
    end)
end

local SNAPSHOT_TRIGGERING_ACTIONS = {
    COLLECTION_BULK_LOAD                  = true,
    COLLECTION_CATALOG_ROW_ADDED          = true,
    COLLECTION_CATALOG_ROW_COUNTS_UPDATED = true,
    COLLECTION_ITEM_LEARNED               = true,
    COLLECTION_ITEM_REMOVED               = true,
    -- Favorites changes affect the favorites widget snapshot field.
    FAVORITE_TOGGLE                       = true,
    -- Bag count changes affect lumberWallet (and indirectly recentActivity
    -- via craft history when a learn happens).
    BAG_INVENTORY_UPDATED                 = true,
    -- House level + rewards cache power nextRewards.
    HOUSE_LEVEL_UPDATED                   = true,
    HOUSE_REWARDS_RECEIVED                = true,
    HOUSE_LIST_UPDATED                    = true,
    -- The logged-in character's known recipes (recipes.knowledge `mine`) change the
    -- craftableNow set: the spellbook pass and a profession window scan write them.
    CHARACTER_RECIPES_SYNCED              = true,
    CHARACTER_PROFESSION_UPDATED          = true,
    -- Catalog sweep completion: re-derive bySource/byExp from the updated
    -- HousingCatalogObserver (new expansion tags, updated source flags).
    CATALOG_LOAD_COMPLETED                = true,
}

function HA:OnStoreNotify(actionType)
    if not actionType then return end
    local actionConst = actionType:gsub("^HDGR_", "")
    -- First-window-open gate. BuildSnapshot reads C_HousingCatalog (3 sync APIs)
    -- which null-derefs -> client CTD on a COLD client at PLAYER_LOGIN
    -- (the housing/DB2 subsystem isn't initialized until any char enters the world).
    -- The snapshot only feeds the House tab, invisible until the window opens, so defer
    -- every build to the first MAIN_WINDOW_OPENING -- the same proven-safe gate the
    -- catalog sweep uses. SNAPSHOT_TRIGGERING_ACTIONS includes login/PEW-time events
    -- (HOUSE_LIST_UPDATED, BAG_INVENTORY_UPDATED), so gating the explicit onEnable
    -- dispatch alone is not enough -- the gate must cover all builds.
    -- See docs/COLD_CLIENT_CTD_INVESTIGATION.md.
    if actionConst == "MAIN_WINDOW_OPENING" then
        if not self._windowReady then
            self._windowReady = true
            self._dirty = true   -- nothing has been built yet
        end
        self:DispatchSnapshot()
        return
    end
    if not self._windowReady then
        -- The dashboard waits for the window, but at a vendor the buy picker reads
        -- the capacity cache, and most vendor visits never open the window. Waiting
        -- for it left the picker with no storage line at all wherever no reading
        -- had been saved -- a fresh install, or the reset cache from before the
        -- exempt count (owner, in-game 2026-11-06). At a vendor the character is
        -- in the world (the cold-client crash is a read at PLAYER_LOGIN), and the
        -- merchant overlay's catalog load reads C_HousingCatalog at that same
        -- moment. Nothing is owed before the window, so this builds nothing.
        if (actionConst == "MERCHANT_SET_STATE" or SNAPSHOT_TRIGGERING_ACTIONS[actionConst])
           and HDG.Store:GetState().session.merchant.open then
            self:DispatchSnapshot()
        end
        return
    end
    if SNAPSHOT_TRIGGERING_ACTIONS[actionConst] then
        self._dirty = true
        self:DispatchSnapshot()
        return
    end
    -- Any other action can be the view switch or window open that puts a
    -- consuming view on screen while a build is owed.
    if self._dirty and HDG.HousingObserver.HouseLevelViewActive(HDG.Store:GetState()) then
        self:DispatchSnapshot()
    end
end

HDG.Modules:Declare({
    name = "HouseAggregator",
    dependencies = {},
    -- ADR-011: owns C_CurrencyInfo. The C_HousingCatalog capacity reads and
    -- C_Item.GetItemIconByID are stateless shared reads, annotated at site.
    ownsBlizzardNamespaces = { "C_CurrencyInfo" },
    onEnable = function(self)
        self._storeToken = HDG.Store:Subscribe(function(actionType)
            HA:OnStoreNotify(actionType)
        end)
        -- First snapshot deferred to MAIN_WINDOW_OPENING: BuildSnapshot's
        -- C_HousingCatalog reads CTD on a cold client at PLAYER_LOGIN.
    end,
    onShutdown = function(self)
        if self._storeToken then
            HDG.Store:Unsubscribe(self._storeToken)
            self._storeToken = nil
        end
    end,
})
