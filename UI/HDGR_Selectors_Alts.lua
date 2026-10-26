-- HDG.Selectors -- Alts tab
-- ============================================================================
-- Three sections, top to bottom:
--   1. Account Summary     -- always rendered. All 12 professions in canonical
--                             order (PROFESSION_DATA), best-skill across roster.
--   2. Character Details   -- collapsible; one block per scanned + visible char.
--   3. Hidden Characters   -- collapsed by default. Stash for chars that
--                             aren't (or shouldn't be) in Character Details.
--                             Two populations share this section:
--                               (a) char.hidden = true (eye-clicked away)
--                               (b) no profession data scanned yet
--
-- Each section maps to its own scrollbox/section in LayoutConfig. The
-- Characters section is single-list: pill buttons in the header switch
-- between Active and Hidden populations via the alts.charsRows selector,
-- driven by session.ui.alts.charsPopulation.
--
-- Element kinds:
--   altsProfRow          -- 13-column grid row (profession name + 12 skill cells)
--   altsGridHeaderRow    -- column header: Profession + 12 expansion shorts
--   altsCharHeaderRow    -- char name + realm + N professions
--   altsSummaryDivider   -- thin horizontal rule between crafting + gathering

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}
local Selectors = HDG.Selectors

-- currentCharKey resolves via HDG.SessionIdentity.GetCharKey (single
-- canonical accessor for the session.identity tuple populated at onEnable).

local function expansionColumns()
    local out = {}
    for _, e in HDG.Expansion.Each() do
        out[#out + 1] = { short = e.short, display = e.display, api = e.api }
    end
    return out
end

-- alias-name -> column index lookup. Wraps HDG.Expansion.NormalizeAlias +
-- GetIndex so caller can pass any alias / api / display / apiTag string.
local function aliasIndex(name)
    local canonical = HDG.Expansion.NormalizeAlias(name)
    return canonical and HDG.Expansion.GetIndex(canonical) or nil
end

-- Per-(profession, expansion) decor recipe index. Built directly from
-- HDGR_DecorDB (the curated 305-entry craftable-decor list -- every
-- entry is a decor recipe by construction). Registered as a memoized
-- selector with empty reads -- the framework's MatchesAny treats
-- reads={} as "effectively a constant; never invalidates from any
-- dispatch" (Paths.lua:48), so the index builds once on first call
-- and persists for the session. Cross-file consumers (Controller_Alts
-- tooltip handler) call via Selectors:Call same as in-file users.
--
-- Returned shape: out[profName][expDisplay] = { recipeSet, total }.
-- recipeSet is keyed by spellID (which matches char.knownRecipes keys).
--
-- DecorDB's `expansion` field is "<api> <profession>" (e.g. "Outland
-- Alchemy") rather than the bare api name. Strip the trailing profession
-- suffix and map api -> display via HDG.Expansion.GetByApi so the index
-- can be queried with the same display names the EXPANSION_DATA columns
-- use ("The Burning Crusade" rather than "Outland").
Selectors:Register("alts.decorRecipeIndex", {
    reads    = {"session.resolvers.staticData.tick"},
    memoized = true,
    fn = function()
        local out = {}
        local decorDB = HDG.StaticData.Recipes:GetAll()
        if type(decorDB) ~= "table" then return out end
        for _, r in pairs(decorDB) do
            if r.profession and r.expansion and r.spellID then
                local apiName = r.expansion:gsub("%s+" .. r.profession .. "$", "")
                local exp = HDG.Expansion.GetByApi and HDG.Expansion.GetByApi(apiName) or nil
                local displayName = exp and exp.display or apiName
                local profBucket = out[r.profession] or {}
                local cell = profBucket[displayName]
                if not cell then
                    cell = { recipeSet = {}, total = 0 }
                    profBucket[displayName] = cell
                end
                cell.recipeSet[r.spellID] = true
                cell.total = cell.total + 1
                out[r.profession] = profBucket
            end
        end
        return out
    end,
})

-- Convenience getter used by both this file's cell builders and the
-- Alts controller's hover tooltip. Returns the per-(prof, exp) bucket
-- or an empty stub. Dispatches through the selector so the cache is
-- shared and lazily-built once.
local function getDecorBucket(profName, expDisplay)
    if not (profName and expDisplay) then return { recipeSet = {}, total = 0 } end
    local state = HDG.Store:GetState()  -- exception(false-positive): selector-local cache helper, not a row factory; reads via Selectors:Call
    local index = state and Selectors:Call("alts.decorRecipeIndex", state, {})
    local profBucket = index and index[profName]
    return (profBucket and profBucket[expDisplay]) or { recipeSet = {}, total = 0 }
end

-- Per-cell decor recipe data: total decor recipes for (prof, exp) + the
-- char's known count + the min skill threshold for that (prof, exp)
-- from HDGR_ProfessionThresholds. Returned as { total, known, threshold }
-- so formatCell can branch the color:
--   known >= total > 0 -> success (all known)
--   current >= threshold -> accent (skill sufficient for THIS bucket)
--   else -> warning
local function decorDataFor(profName, expIdx, knownRecipes)
    if not (profName and expIdx) then return 0, 0, nil end
    local exp = HDG.Constants.EXPANSION_DATA[expIdx]
    if not exp then return 0, 0, nil end
    local data = getDecorBucket(profName, exp.display)
    local total = data.total
    -- HDGR_ProfessionThresholds[profession][expansion.display] -> { threshold, max }
    local threshold
    local td = HDG.StaticData.Professions:GetThresholds()
    if td and td[profName] and td[profName][exp.display] then
        threshold = td[profName][exp.display].threshold
    end
    if total == 0 or not knownRecipes then return total, 0, threshold end
    local known = 0
    for recipeID in pairs(knownRecipes) do
        if data.recipeSet[recipeID] then known = known + 1 end
    end
    return total, known, threshold
end

-- prof = the char's profession record; profName = its canonical English name (for
-- the decor + threshold seed lookups). Caller resolves both from the professionID.
local function buildCells(prof, profName)
    if not prof or not prof.skillLines then return {} end
    local cells = {}
    for key, sl in pairs(prof.skillLines) do
        local idx = aliasIndex(key)
        if idx then
            local total, known, threshold = decorDataFor(profName, idx, prof.knownRecipes)
            cells[idx] = {
                current        = sl.current,
                max            = sl.max,
                decorTotal     = total,
                decorKnown     = known,
                decorThreshold = threshold,
            }
        end
    end
    return cells
end

-- A profession "counts" only if it has REAL skill data (some expansion child
-- with max > 0). Foreign records -- a guild/linked profession viewed in the
-- window and recorded at skill 0 (pre-ownership-gate data, or any future leak)
-- -- have all-0 skillLines, so this filters them out of the roster. Skill-based
-- (locale-independent) and deliberately ignores knownRecipes, which a guild
-- profession view can populate even when the player doesn't own the profession.
local function _profHasSkill(prof)
    if not (prof and prof.skillLines) then return false end
    for _, sl in pairs(prof.skillLines) do
        if (sl.max or 0) > 0 then return true end
    end
    return false
end

-- Char has at least one profession it actually owns (real skill data).
local function _charHasRealProfession(char)
    if not char.professions then return false end
    for _, prof in pairs(char.professions) do
        if _profHasSkill(prof) then return true end
    end
    return false
end

-- Pass-1 worker: stamp best-skill cell for one char (no-op if char is hidden,
-- lacks the profession, or has no skillLines).
local function _visitCharForBestSkill(char, profID, cells)
    if char.hidden then return end
    local prof = HDG.Profession.RecordOf(char, profID)
    if not (prof and prof.skillLines) then return end
    for key, sl in pairs(prof.skillLines) do
        local idx = aliasIndex(key)
        if idx then
            local existing = cells[idx]
            if not existing or sl.current > existing.current then
                cells[idx] = { current = sl.current, max = sl.max }
            end
        end
    end
end

-- Pass-2 worker: union one char's known recipes into the running set,
-- filtered to recipes that belong to this cell's expansion bucket.
local function _visitCharForUnionKnown(char, profID, recipeSet, unionSet)
    if char.hidden then return end
    local prof = HDG.Profession.RecordOf(char, profID)
    if not (prof and prof.knownRecipes) then return end
    for recipeID in pairs(prof.knownRecipes) do
        if recipeSet[recipeID] then
            unionSet[recipeID] = true
        end
    end
end

-- Count distinct recipes known by ANYONE in the roster for this prof + bucket.
local function _countUnionKnown(chars, profID, recipeSet)
    local unionSet = {}
    for _, char in pairs(chars) do
        _visitCharForUnionKnown(char, profID, recipeSet, unionSet)
    end
    local n = 0
    for _ in pairs(unionSet) do n = n + 1 end
    return n
end

-- Summary row aggregates across all non-hidden chars: cell shows best
-- skill across the roster, and decorKnown is the UNION of every char's
-- known recipes (i.e. "is this recipe known by ANYONE on the account?").
-- Computed by walking chars per cell -- O(chars * recipes_per_cell), but
-- recipes_per_cell is bounded (~10-50 typical) and cells are bounded (12),
-- so it stays cheap.
-- profID joins the roster's char.professions (locale-invariant); profName is the
-- canonical English name for the decor-bucket + threshold seed lookups.
local function buildSummaryCells(chars, profID, profName)
    local cells = {}
    -- Pass 1: best skill per expansion index.
    for _, char in pairs(chars) do
        _visitCharForBestSkill(char, profID, cells)
    end
    -- Pass 2: per-cell decor total + threshold + UNION known across chars.
    local thresholds = HDG.StaticData.Professions:GetThresholds()
    for idx, cell in pairs(cells) do
        local exp = HDG.Constants.EXPANSION_DATA[idx]
        if exp then
            local data = getDecorBucket(profName, exp.display)
            local profT = thresholds and thresholds[profName]
            local expT  = profT and profT[exp.display]
            cell.decorTotal     = data.total
            cell.decorThreshold = expT and expT.threshold or nil
            cell.decorKnown     = data.total > 0
                and _countUnionKnown(chars, profID, data.recipeSet)
                or 0
        else
            cell.decorTotal = 0
            cell.decorKnown = 0
        end
    end
    return cells
end

-- ============================================================================
-- Selectors
-- ============================================================================

Selectors:Register("alts.title", {
    reads = {"account.characters"},
    fn = function(state)
        local chars = state.account.characters
        local n = 0
        for _, c in pairs(chars) do
            if not c.hidden then n = n + 1 end
        end
        if n == 0 then return "Alts" end
        return string.format("Alts (%d)", n)
    end,
})

-- Population predicates: which bucket does this char fall into?
local function isActive(char)
    return not char.hidden and _charHasRealProfession(char)
end
local function isHidden(char)
    if char.hidden then return true end
    return not _charHasRealProfession(char)
end

-- Counts for the two pill badges. Stored as paths so the Header text
-- selectors can compose "Active (N)" / "Hidden (M)" labels.
Selectors:Register("alts.activeCount", {
    reads = {"account.characters"},
    fn = function(state)
        local chars = state.account.characters
        local n = 0
        for _, c in pairs(chars) do if isActive(c) then n = n + 1 end end
        return n
    end,
})
Selectors:Register("alts.hiddenCount", {
    reads = {"account.characters"},
    fn = function(state)
        local chars = state.account.characters
        local n = 0
        for _, c in pairs(chars) do if isHidden(c) then n = n + 1 end end
        return n
    end,
})

-- Current population string. Defaults to "active" via reducer guard.
Selectors:Register("alts.charsPopulation", {
    reads = {"session.ui.alts.charsPopulation"},
    fn = function(state)
        return state.session.ui.alts.charsPopulation or "active"
    end,
})

-- Per-population active-state booleans driving the two pill widgets'
-- `active` chrome bindings. Same shape as decor.topFilter.active_<value>.
Selectors:Register("alts.isPopulation_active", {
    calls = {"alts.charsPopulation"},
    fn = function(state, ctx)
        return Selectors:Call("alts.charsPopulation", state, ctx) == "active"
    end,
})
Selectors:Register("alts.isPopulation_hidden", {
    calls = {"alts.charsPopulation"},
    fn = function(state, ctx)
        return Selectors:Call("alts.charsPopulation", state, ctx) == "hidden"
    end,
})

-- Pill label texts -- "Active (N)" / "Hidden (M)". Composed in selector
-- so the binding-engine repaints labels when counts change.
Selectors:Register("alts.activePillLabel", {
    calls = {"alts.activeCount"},
    fn = function(state, ctx)
        return ("Active (%d)"):format(Selectors:Call("alts.activeCount", state, ctx))
    end,
})
Selectors:Register("alts.hiddenPillLabel", {
    calls = {"alts.hiddenCount"},
    fn = function(state, ctx)
        return ("Hidden (%d)"):format(Selectors:Call("alts.hiddenCount", state, ctx))
    end,
})

-- Account Summary rows. Always rendered. Iterates PROFESSION_DATA's
-- canonical 12-profession order so every profession shows even if no
-- char has scanned it yet -- empty rows render as dashes.
Selectors:Register("alts.summaryRows", {
    reads = {"account.characters"},
    fn = function(state)
        local chars = state.account.characters
        local exps  = expansionColumns()
        local rows  = {}

        rows[#rows + 1] = {
            kind = "altsGridHeaderRow",
            tag  = "summary",
            exps = exps,
        }
        -- Crafting professions first, then a divider, then the three
        -- gathering professions (Herbalism / Mining / Skinning). The divider
        -- is keyed off prof.name -- if PROFESSION_DATA ever reorders so
        -- a gathering prof sits inside the crafting block, the divider
        -- still lands above the first gathering entry.
        local profData = HDG.Constants.PROFESSION_DATA
        local GATHERING = { Herbalism = true, Mining = true, Skinning = true }
        local dividerPlaced = false
        for _, p in ipairs(profData) do
            if GATHERING[p.name] and not dividerPlaced then
                rows[#rows + 1] = { kind = "altsSummaryDivider", tag = "summary:divider" }
                dividerPlaced = true
            end
            rows[#rows + 1] = {
                kind     = "altsProfRow",
                tag      = "summary:" .. p.name,
                profName = p.name,
                profID   = p.id,
                cells    = buildSummaryCells(chars, p.id, p.name),
            }
        end
        return rows
    end,
})

-- Characters rows. Single selector for the unified Characters section --
-- dispatches on session.ui.alts.charsPopulation = "active" | "hidden".
-- "active" -> chars where !hidden && has profession data (full detail).
-- "hidden" -> manually-hidden chars (full detail, eye un-hides) AND
--             chars with no scanned profs (header-only, eye suppressed).
local function emitFullCharBlock(rows, charKey, char, current, exps, tagPrefix, canUnhide)
    -- Only professions with real skill data -- foreign 0-skill records (a guild/
    -- linked profession that was scanned against this char) are hidden, and the
    -- header count derives from the filtered set (no phantom "+1 profession").
    -- Resolve each localized-name-keyed record to its canonical English PROFESSION_DATA
    -- entry via the stable professionID; a record predating ID-stamping (not yet re-scanned
    -- on a non-enUS client) falls back to its localized key for display and shows no decor.
    local entries = {}
    for name, prof in pairs(char.professions) do
        if _profHasSkill(prof) then
            local pe = prof.professionID and HDG.Profession.GetByID(prof.professionID)  -- exception(nullable): un-backfilled legacy record
            entries[#entries + 1] = {
                prof     = prof,
                profID   = pe and pe.id or nil,
                display  = pe and pe.name or name,   -- English if resolved, else the localized key
                seedName = pe and pe.name or nil,    -- decor lookup needs English; nil -> empty decor (unchanged pre-rescan)
            }
        end
    end
    table.sort(entries, function(a, b) return a.display < b.display end)
    local profCount = #entries
    rows[#rows + 1] = {
        kind            = "altsCharHeaderRow",
        charKey         = charKey,
        name            = char.name,
        realm           = char.realm,
        class           = char.class,
        classFile       = char.classFile,
        profCount       = profCount,
        isCurrent       = (charKey == current),
        knowsFindLumber = char.knowsFindLumber and true or false,
        hidden          = char.hidden and true or false,
        canUnhide       = canUnhide,
    }
    rows[#rows + 1] = {
        kind = "altsGridHeaderRow",
        tag  = tagPrefix .. ":" .. charKey,
        exps = exps,
    }
    for _, e in ipairs(entries) do
        rows[#rows + 1] = {
            kind     = "altsProfRow",
            tag      = tagPrefix .. ":" .. charKey .. ":" .. (e.profID or e.display),
            profName = e.display,
            profID   = e.profID,
            cells    = buildCells(e.prof, e.seedName),
        }
    end
end

Selectors:Register("alts.charsRows", {
    calls = {"alts.charsPopulation"},
    reads = {"account.characters", "session.identity"},
    fn = function(state, ctx)
        local chars = state.account.characters
        local current = HDG.SessionIdentity.GetCharKey(state)
        local exps = expansionColumns()
        local rows = {}
        local pop = Selectors:Call("alts.charsPopulation", state, ctx)

        if pop == "active" then
            local keys = {}
            for k, c in pairs(chars) do
                if isActive(c) then keys[#keys + 1] = k end
            end
            table.sort(keys, function(a, b)
                if a == current then return true  end
                if b == current then return false end
                return a < b
            end)
            for _, charKey in ipairs(keys) do
                emitFullCharBlock(rows, charKey, chars[charKey], current, exps, "active", true)
            end
        else  -- "hidden"
            -- Manually-hidden chars first (full detail; eye un-hides),
            -- then unscanned chars (header-only; eye suppressed).
            local hiddenKeys, unscannedKeys = {}, {}
            for k, c in pairs(chars) do
                if c.hidden and _charHasRealProfession(c) then
                    hiddenKeys[#hiddenKeys + 1] = k
                elseif not _charHasRealProfession(c) then
                    unscannedKeys[#unscannedKeys + 1] = k
                end
            end
            table.sort(hiddenKeys)
            table.sort(unscannedKeys)
            for _, charKey in ipairs(hiddenKeys) do
                emitFullCharBlock(rows, charKey, chars[charKey], current, exps, "hidden", true)
            end
            for _, charKey in ipairs(unscannedKeys) do
                local char = chars[charKey]
                rows[#rows + 1] = {
                    kind            = "altsCharHeaderRow",
                    charKey         = charKey,
                    name            = char.name,
                    realm           = char.realm,
                    class           = char.class,
                    classFile       = char.classFile,
                    profCount       = 0,
                    isCurrent       = (charKey == current),
                    knowsFindLumber = char.knowsFindLumber and true or false,
                    hidden          = false,
                    canUnhide       = false,  -- eye suppressed; trash only
                }
            end
        end
        return rows
    end,
})

-- Legend strip text. Composed in the selector (not the controller) so
-- palette swaps recolor the entire string without a Controller rebuild.
-- Two scales explained in one line:
--   (1) Cell text color  -- skill sufficiency for decor recipes
--   (2) Pip color        -- decor-recipe completeness for that prof+expansion
-- Mirrors the legend in production HDG so screenshots stay legible.
Selectors:Register("alts.legendText", {
    reads = {},   -- composes from Theme only; no state dependency
    fn = function()
        local C  = function(token) return HDG.Theme:ColorCode(token) end
        local R  = "|r"
        local parts = {
            "Decor Recipes:  ",
            C("semantic.accent")  .. "Skill sufficient"     .. R, " / ",
            C("semantic.warning") .. "Insufficient skill"   .. R, " / ",
            C("text.dim")         .. "No recipes"           .. R,
            "    |    ",
            C("semantic.success") .. "All recipes known" .. R, " / ",
            C("semantic.error")   .. "Missing decor recipes"   .. R,
        }
        return table.concat(parts)
    end,
})
