-- HDGR_Selectors_Blueprints.lua
-- ============================================================================
-- Pure selectors for the Blueprints tab.
--
-- NOTE the near-collision: `session.blueprints.available` is a SERVER-derived
-- fact (BLUEPRINT_AVAILABLE_SET) about whether the blueprint system is usable.
-- The retired `blueprints.available` SELECTOR was something else entirely -- a
-- client-build capability gate for the nav child, which HDG no longer needs now
-- that the TOC is 12.1-only. Do not resurrect the name for either job.

local Selectors = HDG.Selectors

local CT_LABEL = { [1] = "House", [2] = "Room", [3] = "Decor", [4] = "Dye", [5] = "Fixture" }

-- Per-entry acquisition resolve. Plain local helper -- Selectors:Call passes
-- NO extra args, so per-item lookups never route through the registry. Catalog
-- access is the sanctioned live-facade pattern (ADR-003a); reactivity comes
-- from the session.resolvers.catalog.tick read on the registered selector.
-- Returns: itemID?, srcKind? (SOURCE_KINDS key for Format.SourceChip), srcName?
-- The recordID -> itemID join lives on the CATALOG (ItemIDForEntry), because a
-- second caller appeared for it -- the public API another Vamoose addon routes
-- a shopping list through. Two copies of a join is how the two quietly start
-- disagreeing about what a manifest entry means.
--
-- What stays here is the part the chips need and the API does not: which SOURCE
-- the row came from, and what to call it.
-- preferredMapID (optional): re-pick the VENDOR line for one neighborhood
-- instead of using the baked one. The bake is preference-free by necessity --
-- one row serves every player -- so an export written for a particular
-- neighborhood has to ask again here. Every other source kind is
-- neighborhood-independent and comes straight off the row.
local function _resolveAcq(entry, preferredMapID)
    local itemID = HDG.HousingCatalogObserver:ItemIDForEntry(entry)  -- exception(nullable): structural entry, or a catalog miss
    if not itemID then return nil, nil, nil end
    local row = entry.contentType == 4
        and HDG.HousingCatalogObserver:GetRow(entry.recordID)     -- exception(nullable): dyes may not be catalog rows
        or HDG.HousingCatalogObserver.byDecorID[entry.recordID]   -- exception(nullable): catalog lookup can miss
    -- A dye with no catalog row still routes -- its recordID IS the item ID --
    -- but there is nothing to hang a source chip on.
    if not row then return itemID, nil, nil end
    local kind = HDG.Constants.SOURCE_KIND_BY_DONOR[row.sourceType]  -- exception(nullable): source may be unbaked
    if preferredMapID and kind and kind.key == "VENDOR" then
        local v = HDG.VendorRank.Pick(row, preferredMapID)
        if v then return itemID, "VENDOR", v.name or "" end  -- exception(nullable): row had vendors to bake a VENDOR kind, so this holds
    end
    return itemID, kind and kind.key or nil, row.sourceName
end

-- Manifest entries arrive in SERVER order, which on a 201-decor blueprint is
-- unscannable -- the dye group alone reads Purple, Red, Blue, Black, White,
-- Brown, Green. Sorted by name for reading (asked for by madaileinhatter,
-- 2026-08-20).
--
-- recordID breaks ties so the order is TOTAL: table.sort is not stable, and two
-- entries can share a name (dyed variants), so without the tie-break their
-- relative order could differ between repaints and churn the scrollbox keys.
--
-- Returns a COPY. Sorting m.raw.contentGroups in place would have a selector
-- mutating stored state.
local function _byName(entries)
    local out = {}
    for i = 1, #entries do out[i] = entries[i] end
    table.sort(out, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.recordID < b.recordID
    end)
    return out
end

-- have / need for one manifest entry. Decor takes the server's figures.
--
-- DYES DO NOT. The server's numMissing for a dye only covers decor the target
-- house already has, and counts only dyes in your bags, so it climbs as the
-- build's decor is bought: 35 orange became 75 after 40 undyed pillars
-- (Windgrace90, Reddit 2026-09-19). Live-probed the same day: a 792-piece gap
-- read Red 141 total / 61 need with 1 in bags. The manifest never says which
-- dye goes on which piece, so the one figure that holds still is the build's
-- total against what you HOLD, across bags and every bank. `have` is capped at
-- the total so the pair reads as coverage, the way decor's does.
-- Known overstatement: dyes already on decor placed in the target house are
-- inside the total too, so re-inspecting a build that is already up can ask
-- for dyes it does not need. The row tooltip says so.
-- Returns have, need, and for dyes held + the bag share of it: the row tooltip
-- sets HDG's reading beside the server's, and the bag share is the one number
-- an import can actually spend.
local function _haveNeed(ct, e)
    if ct ~= 4 then return e.total - e.numMissing, e.numMissing end
    local bags, bank, warband = HDG.BagObserver:GetSplit(HDG.HousingCatalogObserver:ItemIDForEntry(e))
    local held = bags + bank + warband
    local have = math.min(held, e.total)
    return have, e.total - have, held, bags
end

-- The inspector envelope: manifest -> rendered groups with acquisition joins.
-- nil when nothing is selected; a groupless envelope while pending/failed.
-- missingCount counts ACQUIRABLE entries (Decor=3/Dye=4) with need>0 --
-- fixtures/rooms/house types can't be routed or bought, so the number the
-- verdict shows matches what Route to Shopping actually adds (UX review #5).
-- missingTotal is the PIECE sum of need over that same set: a blueprint
-- with six planters missing is one entry but six pieces, and the headline the
-- player reads as "how much do I still have to get" has to be the pieces
-- (Soul, Discord 2026-09-10). Per-group header counts still cover every type.
-- Missing only hides owned rows of that same set and no others: the house
-- type, rooms and fixtures are what the build needs, and a player told "rooms
-- not unlocked" lost the very list of rooms under the filter
-- (CombatWombatt23, Discord 2026-11-01).
Selectors:Register("blueprints.inspector", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests",
              "session.ui.blueprints.missingOnly", "session.ui.blueprints.collapsedGroups",
              "session.resolvers.catalog.tick", "session.resolvers.bag.tick",
              "account.config.locale" },
    fn = function(state)
        local sb = state.session.blueprints
        local code = sb.selectedCode
        if not code then return nil end                      -- exception(nullable): empty state pre-selection
        local m = sb.manifests[code]
        if not m or m.status ~= "received" then
            return { shareCode = code, status = m and m.status or "idle", groups = {},
                     entryCount = 0, missingCount = 0, missingTotal = 0 }
        end
        local ui = state.session.ui.blueprints
        local groups, missing, missingPieces, entryCount = {}, 0, 0, 0
        for _, g in ipairs(m.raw.contentGroups) do
            local items = {}
            local acquirable = g.contentType == 3 or g.contentType == 4
            for _, e in ipairs(_byName(g.entries)) do
                entryCount = entryCount + 1   -- every entry, before the display filter
                local have, need, held, inBags = _haveNeed(g.contentType, e)
                if need > 0 and acquirable then
                    missing = missing + 1
                    missingPieces = missingPieces + need
                end
                if need > 0 or not acquirable or not ui.missingOnly then
                    local itemID, srcKind, srcName = _resolveAcq(e, nil)
                    items[#items + 1] = {
                        name = e.name, total = e.total, have = have, need = need,
                        held = held, inBags = inBags, serverNeed = e.numMissing,
                        invalid = e.invalid, serverTip = e.tooltip,
                        itemID = itemID, srcKind = srcKind, srcName = srcName,
                    }
                end
            end
            if #items > 0 then
                groups[#groups + 1] = {
                    ct = g.contentType, ctLabel = CT_LABEL[g.contentType],
                    collapsed = ui.collapsedGroups[g.contentType] == true,
                    items = items,
                }
            end
        end
        return { shareCode = code, status = "received", groups = groups,
                 entryCount = entryCount, missingCount = missing, missingTotal = missingPieces,
                 shownMissingOnly = ui.missingOnly }
    end,
})

-- ===== Import as Set source ==================================================
-- Every decor entry at its FULL blueprint quantity, resolved to an itemID, plus
-- the count that could not be resolved. Reads the raw manifest, NOT the
-- inspector: the inspector's groups honour the Missing-only filter, and a
-- furnishing set built from the filtered view silently dropped every piece the
-- player already owned (found 2026-09-11).
Selectors:Register("blueprints.setDecor", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests",
              "session.resolvers.catalog.tick" },
    fn = function(state)
        local sb = state.session.blueprints
        local m = sb.selectedCode and sb.manifests[sb.selectedCode]
        if not m or m.status ~= "received" then return nil end  -- exception(nullable): nothing inspected yet
        local decor, skipped = {}, 0
        for _, g in ipairs(m.raw.contentGroups) do
            if g.contentType == 3 then
                for _, e in ipairs(_byName(g.entries)) do
                    local itemID = _resolveAcq(e, nil)
                    if itemID then
                        decor[#decor + 1] = { id = itemID, count = e.total }
                    else
                        skipped = skipped + 1
                    end
                end
            end
        end
        return { decor = decor, skipped = skipped }
    end,
})

-- ===== Cost to build =========================================================
-- "Can I afford this blueprint?", beside "does it fit?". Asked for by
-- Madailein Hatter (Discord 2026-08-04): people pass up a share code because the
-- commitment is invisible until they are already committed.
--
-- Prices the ACQUISITION GAP, not the whole build -- what you still need, at
-- need each. Only Decor(3)/Dye(4) can be bought; rooms and fixtures are
-- structural, which is the same set blueprints.inspector counts as missing.
--
-- A CURRENCY summary, not a gold total (owner ruling): housing decor is sold for
-- several currencies and some item tokens, so each keeps its own running total
-- and gold is just another line. Costs come from the catalog's baked
-- row.costEntries (currency or item-token entries, grouped by Format.CostKey)
-- -- no vendor-DB join needed.
--
-- unpricedCount is carried, not swallowed. A total that silently drops the
-- entries it could not price reads as authoritative while being wrong; one that
-- says "12 of 47 unpriced" is honest about what it knows.
--
-- KNOWN LIMIT: row.costEntries is the FIRST vendor block's cost. Components
-- within it are ANDed (100g + 5 coupons) and summing them is right, but where an
-- item is sold "30 coupons OR 500g" the alternatives live in separate vendor
-- blocks (row.costVariants) and this counts whichever vendor is listed first.
-- So the badge is "a price to build", not "the cheapest price to build".
local ACQUIRABLE_CT = { [3] = true, [4] = true }

Selectors:Register("blueprints.acquisitionCost", {
    calls = { "blueprints.inspector" },
    reads = { "session.resolvers.catalog.tick" },
    fn = function(state, ctx)
        local insp = Selectors:Call("blueprints.inspector", state, ctx)
        local out = { currencies = {}, pricedCount = 0, unpricedCount = 0, missingCount = 0 }
        if not insp or insp.status ~= "received" then return out end  -- exception(nullable): nothing inspected yet
        local byCurrency, order = {}, {}
        for _, g in ipairs(insp.groups) do
            if ACQUIRABLE_CT[g.ct] then
                for _, it in ipairs(g.items) do
                    if it.need > 0 then
                        out.missingCount = out.missingCount + 1
                        local row = it.itemID and HDG.HousingCatalogObserver:GetRow(it.itemID)  -- exception(nullable): uncatalogued entry
                        local entries = row and row.costEntries
                        if entries and #entries > 0 then
                            out.pricedCount = out.pricedCount + 1
                            for _, e in ipairs(entries) do
                                local key = HDG.Format.CostKey(e)
                                local cur = byCurrency[key]
                                if not cur then
                                    cur = { key = key, currencyID = e.currencyID, itemID = e.itemID, total = 0, icon = e.icon }
                                    byCurrency[key] = cur
                                    order[#order + 1] = cur
                                end
                                cur.total = cur.total + (e.amount or 0) * it.need  -- exception(boundary): baked catalog cost may omit an amount
                            end
                        else
                            out.unpricedCount = out.unpricedCount + 1
                        end
                    end
                end
            end
        end
        -- Gold first, then currencies, then item tokens, by CostKey. NOT by
        -- magnitude: 4,200 of a token and 1,550 gold are different units, so
        -- ranking them against each other implies a comparison that does not
        -- exist -- and it put a token above gold purely for having a bigger
        -- number. Sorting by key instead is arbitrary but honest, and it is
        -- total, so the badge cannot reshuffle between repaints. CURRENCY_GOLD
        -- is the -1 sentinel, so "currency:-1" sorts first on its own.
        table.sort(order, function(a, b) return a.key < b.key end)
        out.currencies = order
        return out
    end,
})

-- Badge text: the first BLUEPRINT_COST_BADGE_MAX currencies, gold first, then
-- "+N more" for the rest -- the badge's hover tooltip (BlueprintCost) lists every
-- currency, so the inline line only has to fit the band, not be complete. Empty
-- when there is nothing left to buy -- the band already says "you have
-- everything" and a "0" badge beside it reads like a price, not an absence.
Selectors:Register("blueprints.costBadge", {
    calls = { "blueprints.acquisitionCost" },
    fn = function(state, ctx)
        local cost = Selectors:Call("blueprints.acquisitionCost", state, ctx)
        local n = #cost.currencies
        if n == 0 then return "" end
        local max = HDG.Constants.BLUEPRINT_COST_BADGE_MAX
        local parts = {}
        for i = 1, math.min(n, max) do
            local c = cost.currencies[i]
            parts[#parts + 1] = HDG.Format.FormatCost(c.total, c)
        end
        if n > max then
            parts[#parts + 1] = HDG.Theme:ColorCode("text.dim") .. ("+%d more|r"):format(n - max)
        end
        return table.concat(parts, "  ")
    end,
})

Selectors:Register("blueprints.hasCostBadge", {
    calls = { "blueprints.costBadge" },
    fn = function(state, ctx)
        return Selectors:Call("blueprints.costBadge", state, ctx) ~= ""
    end,
})

-- ===== Budget fit ============================================================
-- Room-type blueprints ADD to spent; House/Interior/Exterior REPLACE (verified
-- 68629), so meters compare the blueprint's COST against the target house MAX.
-- A cost of 0 means the blueprint doesn't touch that budget ("na"). The fit
-- verdict comes from blockingRequirementFlags (server-computed).

local function _meterState(cost, max)
    if cost <= 0 then return "na" end
    if cost > max then return "over" end
    if cost == max then return "full" end
    return "fit"
end

local METER_CAPTION = {
    na = "not used by this blueprint", fit = "fits", full = "fits exactly", over = "over budget",
}

-- Blueprint type for a code, from STATE only (selector-pure): the own-collection
-- entry's blueprintType, else the type stamped at paste time. Callers declare
-- reads on session.blueprints.groups + account.blueprints.pastedTypes.
local function _codeType(state, code)
    for _, g in ipairs(state.session.blueprints.groups) do
        for _, e in ipairs(g.entries or {}) do  -- exception(boundary): server payload shape
            if e.shareCode == code and e.blueprintType then return e.blueprintType end
        end
    end
    return state.account.blueprints.pastedTypes[code]  -- exception(nullable): pre-stamp pastes have no type
end

-- HousingBlueprintUnmetRequirementFlags bit -> Blizzard's shipped reason string.
-- Bits + globals verified 12.1.68629 (enum key != global suffix -- e.g.
-- MissingRoom=2 -> ERR_..._ROOM, InsufficientBudget=1 -> ERR_..._BUDGETS -- so
-- the map is explicit). The English `alt` only shows headless/pre-12.1, where
-- this path never renders (blueprints are 12.1-only).
local BLOCK_FLAGS = {
    { bit = 1,   g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_BUDGETS",          alt = "not enough placement budget" },
    { bit = 2,   g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_ROOM",             alt = "rooms not unlocked" },
    { bit = 4,   g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_FIXTURE",          alt = "fixtures not unlocked" },
    { bit = 8,   g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_DECOR",            alt = "missing decor" },
    { bit = 16,  g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_DYE",              alt = "missing dyes" },
    { bit = 32,  g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_EXTERIOR_FACTION", alt = "wrong faction for this house type" },
    { bit = 64,  g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_HOUSE_TYPE",       alt = "house type not unlocked" },
    { bit = 128, g = "ERR_HOUSING_BLUEPRINT_REQUIREMENT_HOUSE_SIZE",       alt = "house size not unlocked" },
}

-- Blizzard's reason for each unmet requirement the server flags, in flag order.
-- Kept as a list: joined, they are several sentences that run off the verdict's
-- one line, so the line's hover lists them one per line.
local function _blockingReasons(flags)
    local reasons = {}
    for _, f in ipairs(BLOCK_FLAGS) do
        if flags % (f.bit * 2) >= f.bit then
            reasons[#reasons + 1] = _G[f.g] or f.alt  -- exception(boundary): Blizzard string, nil headless/pre-12.1
        end
    end
    return reasons
end

Selectors:Register("blueprints.budgetFit", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests",
              "session.blueprints.groups", "account.blueprints.pastedTypes" },
    fn = function(state)
        local sb = state.session.blueprints
        local m = sb.selectedCode and sb.manifests[sb.selectedCode]
        if not m or m.status ~= "received" then return { meters = {}, fits = false, blockingReasons = {} } end  -- exception(nullable): no manifest yet
        local raw = m.raw
        -- 12.1 (68675) reshaped the blueprint contents budget (verified in-game
        -- 2026-07-15). `budgetInfo` now holds `interiorBudgets` + `exteriorBudgets`,
        -- each a map keyed by HousingBudgetType (0 = RoomPlacement, 1 = DecorPlacement,
        -- 2 = PetDecor) -> { max, current, cost }. The old flat targetHouseBudgetInfo /
        -- raw.*BudgetCost fields are gone. Rooms are interior-only; decor splits
        -- interior/exterior; PetDecor (2) feeds the interiorPet/exteriorPet meters below.
        local bi = raw.budgetInfo or {}  -- exception(boundary): nilable for houseless players
        local inter, exter = bi.interiorBudgets or {}, bi.exteriorBudgets or {}
        local room, intDecor, extDecor = inter[0] or {}, inter[1] or {}, exter[1] or {}  -- exception(boundary): reshaped/nilable budget map
        local intPet, extPet = inter[2] or {}, exter[2] or {}  -- PetDecor = budgetType 2; exception(boundary): reshaped/nilable
        local meters = {
            { key = "room",        name = "Rooms",          cost = room.cost     or 0, max = room.max     or 0, cur = room.current     or 0 },
            { key = "interior",    name = "Interior decor", cost = intDecor.cost or 0, max = intDecor.max or 0, cur = intDecor.current or 0 },
            { key = "exterior",    name = "Exterior decor", cost = extDecor.cost or 0, max = extDecor.max or 0, cur = extDecor.current or 0 },
            { key = "interiorPet", name = "Interior pets",  cost = intPet.cost   or 0, max = intPet.max   or 0, cur = intPet.current   or 0 },
            { key = "exteriorPet", name = "Exterior pets",  cost = extPet.cost   or 0, max = extPet.max   or 0, cur = extPet.current   or 0 },
        }
        -- Room blueprints ADD to the target's spent budget (House/Interior/
        -- Exterior REPLACE -- verified 68629), so a Room's headroom is what's
        -- LEFT (max - current), not the full max (review finding: meters could
        -- show green while the server verdict said over-budget).
        local isRoomAdd = _codeType(state, sb.selectedCode) == 2
        for _, mt in ipairs(meters) do
            local avail = isRoomAdd and (mt.max - mt.cur) or mt.max
            mt.used    = mt.cost > 0
            mt.state   = _meterState(mt.cost, avail)
            -- 12.1 uses cost = -1 (was 0) for a budget the blueprint doesn't touch;
            -- _meterState already maps cost<=0 -> "na", so clamp the DISPLAY so the
            -- label reads "0 / N" (not "-1 / N"). Caption still says "not used".
            mt.label   = math.max(mt.cost, 0) .. " / " .. avail
            mt.caption = METER_CAPTION[mt.state]
        end
        local blocking = raw.blockingRequirementFlags
        return { meters = meters, fits = (blocking == 0), blocking = blocking,
                 blockingReasons = _blockingReasons(blocking) }
    end,
})

-- ===== Naming ================================================================
-- The manifest has NO top-level name (verified 68629). Display-name resolution:
-- own collection name -> player label (account.blueprints.labels) -> the
-- house-type entry name from the manifest -> the short code. Plain local
-- helper shared with collectionRows (Selectors:Call passes no extra args).

local function _houseTypeName(manifest)
    if not manifest or not manifest.raw then return nil end
    for _, g in ipairs(manifest.raw.contentGroups) do
        if g.contentType == 1 and g.entries[1] then return g.entries[1].name end
    end
    return nil
end

local function _displayName(state, shareCode)
    for _, g in ipairs(state.session.blueprints.groups) do
        for _, e in ipairs(g.entries or {}) do  -- exception(boundary): server payload shape
            if e.shareCode == shareCode and e.name then return e.name end  -- own saved: Blizzard name wins
        end
    end
    local label = state.account.blueprints.labels[shareCode]
    if label then return label end
    return _houseTypeName(state.session.blueprints.manifests[shareCode])
        or (shareCode:sub(1, 10) .. "...")
end

-- Display name for the SELECTED code (the inspector header binding).
Selectors:Register("blueprints.displayName", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.groups",
              "session.blueprints.manifests", "account.blueprints.labels" },
    fn = function(state)
        local code = state.session.blueprints.selectedCode
        if not code then return nil end  -- exception(nullable): empty state pre-selection
        return _displayName(state, code)
    end,
})

local BP_TYPE_LABEL = { [1] = "House", [2] = "Room", [3] = "Interior", [4] = "Exterior" }

-- ===== Normalised entries (both populations) ================================
-- ONE list the picker and the Library both project: pasted codes (HDG's own
-- store) first, then Blizzard's catalog entries (manual + auto-backups), each
-- with a source tag. Pasted and catalog rows keep DISTINCT keys because the
-- same code can legitimately appear in both (an own blueprint pasted back in --
-- PTR key-collision 2026-07-12).
--
-- The word the Source column prints. Separate from `src` (the state tag the row
-- factory themes by) so the displayed text stays selector-owned and can change
-- without touching a paint path -- cookbook 04, selectors compose display text.
local SRC_LABEL = { pasted = "pasted", mine = "mine", backup = "auto" }

Selectors:Register("blueprints.entries", {
    -- perf: one Library click wakes ~15 bound widgets and every one of them
    -- calls this selector, so unmemoized the normaliser rebuilds ~1,200 entry
    -- tables per click on a 50-code catalog plus 30 pasted codes. Invalidation
    -- is path-driven off the reads below, so a paste, a rename or a collection
    -- refresh still rebuilds. The entry tables are therefore SHARED: consumers
    -- project them into fresh rows and never stamp a field on one.
    memoized = true,
    reads = { "session.blueprints.groups", "session.blueprints.selectedCode",
              "session.blueprints.manifests", "account.blueprints.pasted",
              "account.blueprints.pastedTypes", "account.blueprints.labels",
              "account.blueprints.factions", "account.blueprints.pastedAt",
              "account.blueprints.notes" },
    fn = function(state)
        local sb, ab, out = state.session.blueprints, state.account.blueprints, {}
        for _, code in ipairs(ab.pasted) do
            out[#out + 1] = {
                key = "bpPasted:" .. code, shareCode = code,
                src = "pasted", srcLabel = SRC_LABEL.pasted,
                name = _displayName(state, code), hasLabel = ab.labels[code] ~= nil,
                blueprintType = ab.pastedTypes[code],           -- exception(nullable): pre-stamp pastes have no type
                typeLabel = BP_TYPE_LABEL[ab.pastedTypes[code]], -- exception(nullable): same
                isAuto = false,
                faction = ab.factions[code],  -- exception(nullable): only House/Exterior, only after inspect
                date = ab.pastedAt[code],     -- exception(nullable): codes pasted before the stamp existed sort last
                note = ab.notes[code] or "",  -- exception(nullable): no note yet
                isSelected = (code == sb.selectedCode),
            }
        end
        for _, g in ipairs(sb.groups) do
            local groupName = g.name or "My blueprints"  -- exception(boundary): server payload
            for _, e in ipairs(g.entries or {}) do  -- exception(boundary): server payload shape
                local isAuto = e.isAutoSave == true
                local src = isAuto and "backup" or "mine"
                out[#out + 1] = {
                    key = "bpColl:" .. tostring(e.blueprintID or e.shareCode),  -- exception(nullable): blueprintID nil on pre-68569 rows
                    shareCode = e.shareCode, src = src, srcLabel = SRC_LABEL[src],
                    name = _displayName(state, e.shareCode), hasLabel = true,
                    blueprintID = e.blueprintID, blueprintType = e.blueprintType,
                    typeLabel = BP_TYPE_LABEL[e.blueprintType], isAuto = isAuto,
                    groupName = groupName,
                    faction = ab.factions[e.shareCode],  -- exception(nullable): only House/Exterior, only after inspect
                    date = e.creationTime,
                    note = ab.notes[e.shareCode] or "",  -- exception(nullable): no note yet
                    isSelected = (e.shareCode == sb.selectedCode),
                }
            end
        end
        return out
    end,
})

-- ===== Picker projection ====================================================
-- Two FOLD sections ("Pasted codes", "Your catalog") with counts + cap text,
-- the catalog's server groups as sub-headers, then rows. Folds persist in
-- account.ui.blueprints.collapsedSections (design D3). The old footer slots
-- label is gone: its numbers live on the fold rows now.
local BP_CAP_WARN_FREE = 5

Selectors:Register("blueprints.collectionRows", {
    reads = { "account.ui.blueprints.collapsedSections", "session.blueprints.slots" },
    calls = { "blueprints.entries" },
    fn = function(state, ctx)
        local entries = Selectors:Call("blueprints.entries", state, ctx)
        local folded  = state.account.ui.blueprints.collapsedSections
        local slots   = state.session.blueprints.slots
        local rows, pasted, catalog = {}, {}, {}
        for _, e in ipairs(entries) do
            if e.src == "pasted" then pasted[#pasted + 1] = e else catalog[#catalog + 1] = e end
        end
        local function row(e)
            rows[#rows + 1] = { kind = "row", shareCode = e.shareCode, blueprintID = e.blueprintID,
                name = e.name, typeLabel = e.typeLabel, faction = e.faction, isAuto = e.isAuto,
                isPasted = e.src == "pasted", isSelected = e.isSelected }
        end
        rows[#rows + 1] = { kind = "fold", section = "pasted", label = "Pasted codes", count = #pasted,
                            capText = "no limit", capWarn = false, collapsed = folded.pasted == true }
        if not folded.pasted then
            for _, e in ipairs(pasted) do row(e) end
        end
        local free = slots.max - slots.used
        -- `count` is slots.used, not #catalog: this fold reports the MANUAL slot cap,
        -- and auto-backups spend a separate one (shown on the Backups group header),
        -- so it can read "2 / 50" above three rows.
        -- countMax nil until the collection lands: slots mint 0 / 0 before the
        -- round-trip (and a collection that FAILS never fills them), and the row
        -- factory renders a bare count when countMax is nil -- "0" reads as
        -- nothing saved yet, where "0 / 0" reads as a broken cap.
        rows[#rows + 1] = { kind = "fold", section = "catalog", label = "Your catalog",
                            count = slots.used, countMax = slots.max > 0 and slots.max or nil,
                            capText = slots.max > 0 and (free .. " slots free") or "",
                            capWarn = slots.max > 0 and free <= BP_CAP_WARN_FREE,
                            collapsed = folded.catalog == true }
        if not folded.catalog then
            local lastGroup
            for _, e in ipairs(catalog) do
                if e.groupName ~= lastGroup then
                    lastGroup = e.groupName
                    -- The server names its own groups; HDG adds nothing. The
                    -- auto-saves carry no slot budget here: the game declares a
                    -- backup maximum but never surfaces or enforces one a player
                    -- can act on, and they cannot be deleted anyway, so counting
                    -- them against a cap invented a chore (owner, 2026-09-11).
                    rows[#rows + 1] = { kind = "header", label = e.groupName }
                end
                row(e)
            end
        end
        return rows
    end,
})

-- ===== Library mode (design 2026-09-11) =====================================

Selectors:DefineEnum("blueprints.isSubView", "session.ui.blueprints.subView", { "inspect", "library" })

local SRC_ORDER = { pasted = 1, mine = 2, backup = 3 }

-- Sort keys per column. Undated entries (codes pasted before the stamp existed)
-- sort as 0, i.e. last under the default newest-first order.
local LIB_SORT_KEY = {
    name    = function(e) return e.name:lower() end,
    source  = function(e) return SRC_ORDER[e.src] end,
    type    = function(e) return e.typeLabel or "" end,  -- exception(nullable): pre-stamp pastes have no type
    date    = function(e) return e.date or 0 end,        -- exception(nullable): undated pastes
    -- Sorting by note means "show me the ones I annotated": the "0"/"1" prefix
    -- groups noted rows ahead of bare ones, then alphabetically within each.
    note    = function(e) return (e.note == "" and "1" or "0") .. e.note:lower() end,
}

-- The table: entries filtered by chip + query, sorted by the header state.
-- `out` is this selector's OWN array of references, so sorting it never
-- reorders anything stored (the _byName rule). The entry tables inside it are
-- shared with every other consumer of the memoized blueprints.entries and are
-- read-only here -- every displayed field, srcLabel included, is stamped at the
-- one place that mints them.
Selectors:Register("blueprints.libraryRows", {
    reads = { "session.ui.blueprints.libraryQuery", "session.ui.blueprints.libraryChip",
              "session.ui.blueprints.librarySortCol", "session.ui.blueprints.librarySortDir",
              "account.ui.blueprints.hideBackups" },
    calls = { "blueprints.entries" },
    fn = function(state, ctx)
        local ui = state.session.ui.blueprints
        local hideBackups = state.account.ui.blueprints.hideBackups
        local q = ui.libraryQuery:lower()
        local out = {}
        for _, e in ipairs(Selectors:Call("blueprints.entries", state, ctx)) do
            local chipOK = ui.libraryChip == "all" or e.src == ui.libraryChip
            -- The preference hides backups from the All list only: picking the
            -- Backups chip is an explicit ask and overrides it.
            local hideOK = not (hideBackups and ui.libraryChip == "all" and e.src == "backup")
            local qOK = q == "" or e.name:lower():find(q, 1, true) ~= nil
                or e.shareCode:lower():find(q, 1, true) ~= nil or e.note:lower():find(q, 1, true) ~= nil
            if chipOK and hideOK and qOK then
                out[#out + 1] = e
            end
        end
        local keyOf, asc = LIB_SORT_KEY[ui.librarySortCol], ui.librarySortDir == "asc"
        table.sort(out, function(a, b)
            local ka, kb = keyOf(a), keyOf(b)
            if ka ~= kb then
                if asc then return ka < kb end
                return ka > kb
            end
            return a.key < b.key   -- total order: table.sort is not stable
        end)
        return out
    end,
})

Selectors:Register("blueprints.libraryChipCounts", {
    calls = { "blueprints.entries" },
    fn = function(state, ctx)
        local c = { all = 0, pasted = 0, mine = 0, backup = 0 }
        for _, e in ipairs(Selectors:Call("blueprints.entries", state, ctx)) do
            c.all = c.all + 1
            c[e.src] = c[e.src] + 1
        end
        return c
    end,
})
-- The tick box beside the chips. Orthogonal to them: it only bites on "all".
Selectors:Register("blueprints.libraryHideBackups", {
    reads = { "account.ui.blueprints.hideBackups" },
    fn = function(state) return state.account.ui.blueprints.hideBackups == true end,
})
for _, chip in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_CHIPS) do
    local value, label = chip.value, chip.label
    Selectors:Register("blueprints.libraryChipText_" .. value, {
        calls = { "blueprints.libraryChipCounts" },
        fn = function(state, ctx)
            return ("%s (%d)"):format(label, Selectors:Call("blueprints.libraryChipCounts", state, ctx)[value])
        end,
    })
    Selectors:Register("blueprints.libraryChipActive_" .. value, {
        reads = { "session.ui.blueprints.libraryChip" },
        fn = function(state) return state.session.ui.blueprints.libraryChip == value end,
    })
end
for _, c in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_COLUMNS) do
    local col, label = c.col, c.label
    Selectors:Register("blueprints.librarySortHeader_" .. col, {
        reads = { "session.ui.blueprints.librarySortCol", "session.ui.blueprints.librarySortDir" },
        fn = function(state)
            local ui = state.session.ui.blueprints
            if ui.librarySortCol ~= col then return label end
            return label .. (ui.librarySortDir == "asc" and " ^" or " v")
        end,
    })
    Selectors:Register("blueprints.librarySortActive_" .. col, {
        reads = { "session.ui.blueprints.librarySortCol" },
        fn = function(state) return state.session.ui.blueprints.librarySortCol == col end,
    })
end

-- Detail strip: the selected entry. A CLICKED Library row wins outright (its
-- key is pinned in session state), because a code present in both populations
-- renders two rows and the strip's remove verb differs between them. With no
-- clicked row -- the picker selected the code, or the clicked row is gone --
-- the catalog row wins: rename and delete need its blueprintID.
Selectors:Register("blueprints.libraryDetail", {
    reads = { "session.blueprints.selectedCode", "session.ui.blueprints.librarySelectedKey" },
    calls = { "blueprints.entries" },
    fn = function(state, ctx)
        local code = state.session.blueprints.selectedCode
        if not code then return nil end  -- exception(nullable): nothing selected yet
        local clickedKey = state.session.ui.blueprints.librarySelectedKey  -- exception(nullable): no Library row clicked this session
        local found
        for _, e in ipairs(Selectors:Call("blueprints.entries", state, ctx)) do
            if e.shareCode == code then
                if e.key == clickedKey then return e end
                if not found or e.src ~= "pasted" then found = e end
            end
        end
        return found  -- exception(nullable): a selected code with no entry (forgotten mid-session) shows no strip
    end,
})
local function _detail(state, ctx) return Selectors:Call("blueprints.libraryDetail", state, ctx) end
Selectors:Register("blueprints.libraryHasDetail", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx) return _detail(state, ctx) ~= nil end })
Selectors:Register("blueprints.libraryDetailCode", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx) local d = _detail(state, ctx); return d and d.shareCode or "" end })  -- exception(nullable): no selection
Selectors:Register("blueprints.libraryDetailNote", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx) local d = _detail(state, ctx); return d and d.note or "" end })  -- exception(nullable): no selection
Selectors:Register("blueprints.libraryDetailNameEditable", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx) local d = _detail(state, ctx); return d ~= nil and d.src ~= "backup" end })
-- Removable = a pasted code (forget) or an own catalog blueprint that has an id
-- to delete BY. Backups are read-only, and a catalog row with no id has no
-- removal at all -- its only one would be DeleteBlueprint(nil).
Selectors:Register("blueprints.libraryCanRemove", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx)
        local d = _detail(state, ctx)
        if d == nil then return false end  -- exception(nullable): no selection
        return d.src == "pasted" or (d.src == "mine" and d.blueprintID ~= nil)  -- exception(nullable): blueprintID nil on pre-68569 catalog rows
    end })
local NAME_LABEL  = { pasted = "Label (HDG only)", mine = "Name (renames in your catalog)", backup = "Name (read-only backup)" }
local REMOVE_TEXT = { pasted = "Forget code", mine = "Delete blueprint", backup = "" }
Selectors:Register("blueprints.libraryDetailNameLabel", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx) local d = _detail(state, ctx); return d and NAME_LABEL[d.src] or "" end })  -- exception(nullable): no selection
Selectors:Register("blueprints.libraryRemoveText", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx) local d = _detail(state, ctx); return d and REMOVE_TEXT[d.src] or "" end })  -- exception(nullable): no selection
-- "Pasted 09 Sep 2026" for a pasted code, "Saved 09 Sep 2026" for a catalog row.
Selectors:Register("blueprints.libraryDetailMeta", { calls = { "blueprints.libraryDetail" },
    fn = function(state, ctx)
        local d = _detail(state, ctx)
        if not d then return "" end  -- exception(nullable): no selection
        local verb = d.src == "pasted" and "Pasted" or "Saved"
        return d.date and (verb .. " " .. HDG.Format.ShortDate(d.date)) or (verb .. " --")  -- exception(nullable): undated paste
    end })

-- "Manual blueprints 2 / 50 -- Backups 1 / 10 -- Pasted codes 2 (no limit)
--  -- 5 of 5 shown" (design section 5). The two cap clauses drop out entirely
-- until the collection lands: slots mint 0 / 0 before the round-trip, and a
-- footer that says "Manual blueprints 0 / 0" states a cap the player does not
-- have. The pasted count is HDG's own state and is true immediately.
Selectors:Register("blueprints.libraryFooterText", {
    reads = { "session.blueprints.slots" },
    calls = { "blueprints.libraryChipCounts", "blueprints.libraryRows" },
    fn = function(state, ctx)
        local s = state.session.blueprints.slots
        local c = Selectors:Call("blueprints.libraryChipCounts", state, ctx)
        local rows = Selectors:Call("blueprints.libraryRows", state, ctx)
        local parts = {}
        if s.max > 0 then
            parts[#parts + 1] = ("Manual blueprints %d / %d"):format(s.used, s.max)
        end
        -- A count, not a budget: only the manual 50 is a ceiling the player can
        -- hit and manage.
        parts[#parts + 1] = ("Automatic saves %d"):format(c.backup)
        parts[#parts + 1] = ("Pasted codes %d (no limit)"):format(c.pasted)
        parts[#parts + 1] = ("%d of %d shown"):format(#rows, c.all)
        return table.concat(parts, "  --  ")
    end,
})

-- ===== House picker ==========================================================
-- Emits RAW session-scoped houseGUIDs ("Opaque-N") -- exactly what
-- RequestBlueprintContentsForContext needs. Deliberately NOT reusing
-- projects.houseMenuItems: Projects re-hashes name+plotID into its own stable
-- ID space, which is the WRONG token for the blueprint API.

-- Radio menu items for the dropdown kind: { value, text } (kind defaults to
-- radio; picking dispatches { houseGUID = value } via the widget's dispatch spec).
Selectors:Register("blueprints.houseMenuItems", {
    reads = { "session.house.ownedHouses" },
    fn = function(state)
        local items = {}
        for guid, h in pairs(state.session.house.ownedHouses) do
            -- `h.name` is the NEIGHBOURHOOD (ownedHouses stamps neighborhoodName
            -- there); an unnamed house is labelled by where it is and says so,
            -- rather than passing the neighbourhood off as its name.
            items[#items + 1] = {
                value = guid,
                text = h.houseName or (h.name and ("House in " .. h.name)) or guid,  -- exception(boundary): HouseInfo fields nilable (_SIGNATURES gotcha)
            }
        end
        table.sort(items, function(a, b) return a.text < b.text end)
        return items
    end,
})

-- What is currently selected: an OWN saved blueprint (carries blueprintID +
-- Blizzard's real name; rename hits the catalog) or a pasted code (HDG label
-- overlay). Drives the name box's text AND which rename mechanism it commits to.
Selectors:Register("blueprints.selectedEntry", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.groups", "account.blueprints.labels",
              "session.ui.blueprints.librarySelectedKey" },
    fn = function(state)
        local code = state.session.blueprints.selectedCode
        if not code then return nil end  -- exception(nullable): empty pre-selection
        -- A pinned PASTED Library row wins over the catalog: the rest of that
        -- strip (name label, remove verb) already follows the clicked row via
        -- libraryDetail, and the name box must edit the same thing they name --
        -- the HDG label, not a rename of the catalog blueprint behind it.
        -- _CloseLibrary clears the pin, so the picker keeps the catalog rule.
        if state.session.ui.blueprints.librarySelectedKey == "bpPasted:" .. code then
            return { isOwn = false, label = state.account.blueprints.labels[code] }  -- exception(nullable): unlabelled paste
        end
        for _, g in ipairs(state.session.blueprints.groups) do
            for _, e in ipairs(g.entries or {}) do  -- exception(boundary): server payload shape
                if e.shareCode == code then
                    return { isOwn = true, blueprintID = e.blueprintID, name = e.name, isAuto = e.isAutoSave == true }
                end
            end
        end
        return { isOwn = false, label = state.account.blueprints.labels[code] }
    end,
})


-- Architect lays out interior rooms, so it only makes sense for a full House (1)
-- or an Interior (3) -- not a single Room (2) or an Exterior (4).
Selectors:Register("blueprints.selectedIsArchitectable", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.groups", "account.blueprints.pastedTypes" },
    fn = function(state)
        local code = state.session.blueprints.selectedCode
        if not code then return false end  -- exception(nullable): empty pre-selection
        local t = _codeType(state, code)
        return t == 1 or t == 3   -- House / Interior (see BP_TYPE_LABEL)
    end,
})


-- Current picker value (dropdown `current` binding). Until the player picks a
-- house explicitly, fall back to the TARGET the server actually computed the
-- selected manifest against (a no-target request defaults to the current
-- house) -- so the dropdown always names the house the numbers are for
-- (UX review #7). Display-only: dispatching a back-fill would re-trigger the
-- target-change re-fetch and loop.
Selectors:Register("blueprints.targetHouse", {
    reads = { "session.blueprints.targetHouseGUID", "session.blueprints.selectedCode",
              "session.blueprints.manifests" },
    fn = function(state)
        local sb = state.session.blueprints
        if sb.targetHouseGUID then return sb.targetHouseGUID end
        local m = sb.selectedCode and sb.manifests[sb.selectedCode]
        return m and m.raw and m.raw.targetHouseGUID or nil  -- exception(nullable): no manifest / pre-target
    end,
})

-- ===== Failure + pending copy (player-facing text is selector-composed) ======

Selectors:Register("blueprints.failureText", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests" },
    fn = function(state)
        local sb = state.session.blueprints
        local m = sb.selectedCode and sb.manifests[sb.selectedCode]
        if not m or m.status ~= "failed" then return nil end  -- exception(nullable): not in a failed state
        if m.timedOut then
            -- Ticker-swept timeout: the server silently dropped the request
            -- (no RECEIVED or FAILURE ever fires for some foreign codes).
            return "No response from the server -- this code may not be readable from here."
        end
        if m.reasonCode == Enum.HousingResult.DbError then    -- exception(boundary): Blizzard enum (never hardcode values)
            -- Cause-neutral: our only DbError sample was a PTR db-wipe; a live
            -- deleted code may return BlueprintNotFound(8), which the map covers.
            return "This blueprint no longer exists on the server."
        end
        local map = _G.HousingResultToErrorText  -- exception(boundary): Blizzard global map (verified global, 68629)
        return map[m.reasonCode] or _G.ERR_HOUSING_RESULT_BLUEPRINT_GENERIC_CONTENT_ERROR  -- exception(boundary): not every value is mapped
    end,
})

-- Count-up pending copy (big manifests take 5-10s). Escalates at 15s; the
-- observer's ticker sweep flips a dead request to a timedOut failure at
-- BLUEPRINT_REQUEST_TIMEOUT. Pure: elapsed composes from the tick-dispatched
-- pendingNow, never GetTime().
local BP_PENDING_ESCALATE_S = 15

Selectors:Register("blueprints.pendingText", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests",
              "session.blueprints.pendingNow" },
    fn = function(state)
        local sb = state.session.blueprints
        local m = sb.selectedCode and sb.manifests[sb.selectedCode]
        if not m or m.status ~= "pending" then return nil end  -- exception(nullable): not pending
        local elapsed = math.max(0, math.floor(sb.pendingNow - (m.requestedAt or sb.pendingNow)))  -- exception(optional): first render may precede the first tick
        if elapsed >= BP_PENDING_ESCALATE_S then
            return ("Still waiting (%ds) -- some codes never get a reply; this gives up at %ds."):format(
                elapsed, HDG.Constants.BLUEPRINT_REQUEST_TIMEOUT)
        end
        return ("Waiting for the server... (%ds)"):format(elapsed)
    end,
})

-- ===== View-composition selectors (LayoutConfig bindings) ====================
-- All thin, pure projections over inspector/budgetFit for the declarative tree.

-- Flat scrollbox projection: header rows + item rows; a collapsed group keeps
-- its header but hides its items.
Selectors:Register("blueprints.contentRows", {
    calls = { "blueprints.inspector" },
    fn = function(state, ctx)
        local insp = Selectors:Call("blueprints.inspector", state, ctx)
        if not insp or insp.status ~= "received" then return {} end
        local rows = {}
        for _, g in ipairs(insp.groups) do
            local gm, gp = 0, 0
            for _, it in ipairs(g.items) do
                if it.need > 0 then gm = gm + 1; gp = gp + it.need end
            end
            rows[#rows + 1] = { kind = "header", ct = g.ct, label = g.ctLabel,
                                count = #g.items, missing = gm, missingPieces = gp, collapsed = g.collapsed }
            if not g.collapsed then
                for _, it in ipairs(g.items) do
                    rows[#rows + 1] = { kind = "item", ct = g.ct, name = it.name, have = it.have,
                        total = it.total, need = it.need, invalid = it.invalid,
                        held = it.held, inBags = it.inBags, serverNeed = it.serverNeed,
                        serverTip = it.serverTip, itemID = it.itemID, srcKind = it.srcKind, srcName = it.srcName }
                end
            end
        end
        return rows
    end,
})

local function _meterByKey(state, ctx, key)
    local b = Selectors:Call("blueprints.budgetFit", state, ctx)
    for _, m in ipairs(b.meters) do
        if m.key == key then return m end
    end
    return nil
end

local function _meterFrac(m)
    if not m or m.max <= 0 or m.cost <= 0 then return 0 end
    local p = m.cost / m.max
    return (p > 1) and 1 or p
end

-- Blizzard's own budget icons (Blizzard_HousingBlueprintContentSummary.xml,
-- ptr): rooms / interior decor / exterior decor. Icon + numbers, like the
-- Import dialog; the bar tooltips carry the full budget names.
local METER_ICON = {
    room        = "house-room-limit-icon",
    interior    = "house-decor-budget-icon",
    exterior    = "house-decor-exteriorbudget-icon",
    interiorPet = "house-decor-pets-icon",
    exteriorPet = "house-decor-pets-icon",
}

local function _meterText(m)
    -- No caption: the bar color carries the state (teal fits / amber at-limit /
    -- red over), and any blocking reason is spelled out in the fit-verdict line.
    if not m then return "" end
    return "|A:" .. METER_ICON[m.key] .. ":14:14|a  " .. m.label
end

Selectors:Register("blueprints.meterFracRoom", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterFrac(_meterByKey(state, ctx, "room")) end,
})
Selectors:Register("blueprints.meterTextRoom", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterText(_meterByKey(state, ctx, "room")) end,
})
Selectors:Register("blueprints.meterFracInterior", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterFrac(_meterByKey(state, ctx, "interior")) end,
})
Selectors:Register("blueprints.meterTextInterior", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterText(_meterByKey(state, ctx, "interior")) end,
})
Selectors:Register("blueprints.meterFracExterior", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterFrac(_meterByKey(state, ctx, "exterior")) end,
})
Selectors:Register("blueprints.meterTextExterior", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterText(_meterByKey(state, ctx, "exterior")) end,
})
Selectors:Register("blueprints.meterFracInteriorPet", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterFrac(_meterByKey(state, ctx, "interiorPet")) end,
})
Selectors:Register("blueprints.meterTextInteriorPet", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterText(_meterByKey(state, ctx, "interiorPet")) end,
})
Selectors:Register("blueprints.meterFracExteriorPet", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterFrac(_meterByKey(state, ctx, "exteriorPet")) end,
})
Selectors:Register("blueprints.meterTextExteriorPet", {
    calls = { "blueprints.budgetFit" },
    fn = function(state, ctx) return _meterText(_meterByKey(state, ctx, "exteriorPet")) end,
})

-- Fit verdict pill line ("Fits this house -- N pieces to acquire first"). Pieces,
-- not entries: "17 items" read as 17 things to buy when it was 17 kinds with
-- several copies each (Soul, Discord 2026-09-10). The entry count stays on the
-- counts label beside the filter buttons.
Selectors:Register("blueprints.fitVerdict", {
    calls = { "blueprints.budgetFit", "blueprints.inspector" },
    fn = function(state, ctx)
        local insp = Selectors:Call("blueprints.inspector", state, ctx)
        if not insp or insp.status ~= "received" then return "" end
        local b = Selectors:Call("blueprints.budgetFit", state, ctx)
        if not b.fits then return table.concat(b.blockingReasons, " ") end   -- Blizzard's strings are full sentences
        if insp.missingTotal > 0 then
            return ("Fits this house -- %d piece%s to acquire first"):format(
                insp.missingTotal, insp.missingTotal == 1 and "" or "s")
        end
        return "Fits this house -- you have everything"
    end,
})

-- Selection gates: the action row enables only with a selection, and the
-- blank-state hint shows only without one (UX review #1).
Selectors:Register("blueprints.hasSelection", {
    reads = { "session.blueprints.selectedCode" },
    fn = function(state) return state.session.blueprints.selectedCode ~= nil end,
})
-- Enable gate for actions that need CONTENTS, not just a selection: Copy
-- requirements has nothing to render until the server answers, and a live
-- button that copies an empty string reads as a broken button.
Selectors:Register("blueprints.hasManifest", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests" },
    fn = function(state)
        local sb = state.session.blueprints
        local m = sb.selectedCode and sb.manifests[sb.selectedCode]
        return m ~= nil and m.status == "received"
    end,
})
-- Stale = received before the last decor-storage change (BLUEPRINT_MANIFESTS_STALE).
-- Drives the Refresh button: lit and worded as a warning only while the
-- counts on screen are suspect; dim otherwise so it never invites a needless
-- 5-10 s fetch.
Selectors:Register("blueprints.manifestStale", {
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests" },
    fn = function(state)
        local sb = state.session.blueprints
        local m = sb.selectedCode and sb.manifests[sb.selectedCode]
        return m ~= nil and m.status == "received" and m.stale == true
    end,
})
Selectors:Register("blueprints.refreshText", {
    reads = { "account.config.locale" },
    calls = { "blueprints.manifestStale" },
    fn = function(state, ctx)
        local stale = Selectors:Call("blueprints.manifestStale", state, ctx)
        return HDG.Locale:Get(stale and "BP_REFRESH_STALE" or "BP_REFRESH")
    end,
})
Selectors:Register("blueprints.blankDetail", {
    reads = { "session.blueprints.selectedCode" },
    fn = function(state) return state.session.blueprints.selectedCode == nil end,
})
-- Verdict band shows only when there is a verdict to show (card chrome on an
-- empty string reads as a stray stripe).
Selectors:Register("blueprints.hasVerdict", {
    calls = { "blueprints.fitVerdict" },
    fn = function(state, ctx)
        local v = Selectors:Call("blueprints.fitVerdict", state, ctx)
        return v ~= nil and v ~= ""
    end,
})


-- Pending/failure/paste-error line under the header (one label; nil states
-- compose to ""). Paste errors outrank the manifest states -- the player just
-- typed something and needs the answer next to the field.
Selectors:Register("blueprints.statusLine", {
    reads = { "session.ui.blueprints.pasteError" },
    calls = { "blueprints.pendingText", "blueprints.failureText" },
    fn = function(state, ctx)
        if state.session.ui.blueprints.pasteError then
            return "That doesn't look like a share code -- check the paste and try again."
        end
        return Selectors:Call("blueprints.pendingText", state, ctx)
            or Selectors:Call("blueprints.failureText", state, ctx)
            or ""  -- exception(nullable): both are nil outside pending/failed states
    end,
})

-- Segmented filter actives ("All items" / "Missing only").
Selectors:Register("blueprints.filterAllActive", {
    reads = { "session.ui.blueprints.missingOnly" },
    fn = function(state) return state.session.ui.blueprints.missingOnly == false end,
})
Selectors:Register("blueprints.filterMissingActive", {
    reads = { "session.ui.blueprints.missingOnly" },
    fn = function(state) return state.session.ui.blueprints.missingOnly == true end,
})

-- "N items -- M missing (P pieces)" (controls-row right). Items = manifest
-- entries, pieces = copies still to acquire. All three numbers describe the
-- BLUEPRINT, not the rows on screen: entryCount is counted before the
-- Missing-only filter, like missingCount / missingTotal, so toggling the filter
-- changes the rows and not the label. One shape always.
Selectors:Register("blueprints.itemCountText", {
    calls = { "blueprints.inspector" },
    fn = function(state, ctx)
        local insp = Selectors:Call("blueprints.inspector", state, ctx)
        if not insp or insp.status ~= "received" then return "" end
        return ("%d items -- %d missing (%d piece%s)"):format(
            insp.entryCount, insp.missingCount, insp.missingTotal, insp.missingTotal == 1 and "" or "s")
    end,
})

-- ===== Plain-text manifest ===================================================
-- A readable requirements list to publish ALONGSIDE the share code -- a Reddit
-- post, a Discord drop, a Wowhead comment. The audience is the READER of
-- someone else's post, which is why nothing here reflects the exporter's own
-- collection: counts are `total`, never numMissing, and there are no budgets
-- and no progress. That is what makes the output publishable rather than
-- personal -- the author owns everything, so their missing count is zero and
-- the reader's is different.
--
-- Spec: docs/HDGR_PLAINTEXT_EXPORT_SPEC_2026-08-20.md
--
-- Deliberately NOT built on blueprints.inspector: that envelope applies the
-- player's missing-only filter, which would silently drop lines from a
-- published list. This reads the manifest.

-- Plural headings are an explicit map, not CT_LABEL .. "S" -- "DECOR" is a mass
-- noun and "DECORS" is not a word.
local CT_HEADING  = { [1] = "HOUSE", [2] = "ROOMS", [3] = "DECOR", [4] = "DYES", [5] = "FIXTURES" }
local PET_HEADING = "PET DECOR"

local EXPORT_FOOTER = "Generated by Vamoose's Housing Decor Guide\n"
    .. "https://www.curseforge.com/wow/addons/housing-decor-guide"

-- " -- " separates the entry from its source: a single hyphen would read as a
-- second bullet beside the leading "- ", and an em-dash is not ASCII.
-- Decor lines carry a source; every other group is name and count. Dyes are
-- crafted or bought at auction, so a source tells the reader nothing, and
-- rooms / fixtures / house types have no acquisition join at all.
local function _textLine(entry, withSource, preferredMapID)
    local line = ("- %s x%d"):format(entry.name, entry.total)
    if not withSource then return line end
    local _, srcKind, srcName = _resolveAcq(entry, preferredMapID)
    -- UNKN is the honest "no signal" fallback the on-screen chip wants so data
    -- gaps surface. A published list is the wrong place for it: it would stamp
    -- "Unknown" on every unbaked line. Bare is better.
    if not (srcKind and srcName) or srcKind == "UNKN" then return line end
    local label = HDG.Constants.SOURCE_KIND_BY_KEY[srcKind].label
    -- Shop / Promotion name nothing beyond themselves, so "-- In-Game Shop"
    -- rather than "-- In-Game Shop: " with an empty half after the colon.
    if srcName == "" then return ("%s -- %s"):format(line, label) end
    return ("%s -- %s: %s"):format(line, label, srcName)
end

-- No column alignment anywhere: Reddit, Discord, forums and Wowhead comments do
-- not all preserve whitespace, but "- name xN" survives every one of them.
-- The header count is the sum of totals, so ROOMS (3) matches x1 + x2 below it.
local function _blockText(heading, entries, withSource, preferredMapID)
    if #entries == 0 then return nil end
    local total, lines = 0, {}
    for _, e in ipairs(entries) do
        total = total + e.total
        lines[#lines + 1] = _textLine(e, withSource, preferredMapID)
    end
    return ("%s (%d)\n%s"):format(heading, total, table.concat(lines, "\n"))
end

-- Pet decor is decor a pet can be placed ON -- beds, plinths, nests. It is
-- furniture, so these are ordinary contentType 3 entries and this is a
-- presentation split, which is why the block renders next to DECOR rather than
-- somewhere else in manifest order.
local function _splitPetDecor(entries)
    local plain, pets = {}, {}
    for _, e in ipairs(entries) do
        local bucket = HDG.Constants.PET_DECOR_BY_DECOR_ID[e.recordID] and pets or plain
        bucket[#bucket + 1] = e
    end
    return plain, pets
end

-- Which neighborhood the copied list names its vendors for. "" = follow the
-- shopping preference; the copy window's switch writes the session value.
-- nil when neither expresses one (a neutral character who has not chosen).
Selectors:Register("blueprints.exportNeighborhood", {
    calls = { "shopping.neighborhood" },
    reads = { "session.ui.blueprints.exportNeighborhood" },
    fn = function(state, ctx)
        local pick = state.session.ui.blueprints.exportNeighborhood
        if pick ~= "" then return pick end
        return Selectors:Call("shopping.neighborhood", state, ctx)
    end,
})

-- The name a reader would recognise, not the internal key.
local EXPORT_NBHD_LABEL = {
    alliance = "Alliance (Founder's Point)",
    horde    = "Horde (Razorwind Shores)",
}

-- A published list names vendors that in some cases exist in BOTH housing
-- neighborhoods under different names, so the list has to say which one it was
-- written for or the reader cannot tell whether it applies to them. This line
-- is what keeps the export shareable while still being written for one side --
-- without it, an Alliance author's list silently sends Horde readers wrong.
local function _headerText(state, ctx, code, exportFaction)
    local name = Selectors:Call("blueprints.displayName", state, ctx)
    local typeLabel = BP_TYPE_LABEL[_codeType(state, code)]  -- exception(nullable): a pasted code may have no type stamp
    local head = ("%s\nShare code: %s"):format(
        typeLabel and ("%s - %s blueprint"):format(name, typeLabel) or name, code)
    local label = exportFaction and EXPORT_NBHD_LABEL[exportFaction]  -- exception(nullable): no preference expressed
    if label then head = head .. ("\nVendors listed for: %s"):format(label) end
    return head
end

-- Every content type, not only the acquirable ones: someone building this needs
-- to know it wants three rooms, not only the furniture inside them. (The
-- Decor/Dye-only filter on blueprints.inspector's missingCount is correct for a
-- shopping list, and a manifest is not a shopping list.)
-- Group order follows the manifest's own contentType order, not an invented one.
Selectors:Register("blueprints.manifestText", {
    calls = { "blueprints.displayName", "blueprints.exportNeighborhood" },
    reads = { "session.blueprints.selectedCode", "session.blueprints.manifests",
              "session.blueprints.groups", "account.blueprints.pastedTypes",
              "session.resolvers.catalog.tick" },
    fn = function(state, ctx)
        local exportFaction = Selectors:Call("blueprints.exportNeighborhood", state, ctx)
        local preferredMap  = exportFaction
            and HDG.Constants.NEIGHBORHOOD_MAP_BY_FACTION[exportFaction] or nil
        local sb = state.session.blueprints
        local code = sb.selectedCode
        if not code then return nil end  -- exception(nullable): nothing selected
        local m = sb.manifests[code]
        if not m or m.status ~= "received" then return nil end  -- exception(nullable): no contents to publish yet
        local blocks = { _headerText(state, ctx, code, exportFaction) }
        for _, g in ipairs(m.raw.contentGroups) do
            if g.contentType == 3 then
                local plain, pets = _splitPetDecor(_byName(g.entries))
                blocks[#blocks + 1] = _blockText(CT_HEADING[3], plain, true, preferredMap)
                blocks[#blocks + 1] = _blockText(PET_HEADING, pets, true, preferredMap)
            else
                blocks[#blocks + 1] = _blockText(CT_HEADING[g.contentType], _byName(g.entries), false, preferredMap)
            end
        end
        blocks[#blocks + 1] = EXPORT_FOOTER
        return table.concat(blocks, "\n\n")
    end,
})
