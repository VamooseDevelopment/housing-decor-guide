-- HDG.Selectors -- Decor Quests tab (Acquire > Decor Quests)
-- ============================================================================
-- Every catalog decor a quest rewards (HousingCatalogObserver rows carrying a questID)
-- and the quest line that leads to it (StaticData.DecorQuests), shaped like Recipe
-- Sources: presets, search and filter menus over a list grouped by expansion on the
-- left, the selected decor's chain on the right (docs/mockups/decor_quests_lab.html,
-- By Decor and By Chain).
--
-- Done is the WARBAND's (ruling 10-27): a decor reads done once any character finished
-- its decor quest, which unlocks the decor on its vendor for every character. Anything
-- short of that is THIS character's progress -- quests are per character, so an alt
-- walks the chain itself. QuestNameResolver answers done / done on the account / in the
-- log per step, and a step counts only when its gate lets this character take it
-- (session.identity's side, race and class against the step's gate). "Collected" is
-- the account's collection (account.collection.ownedDecorIDs), never a quest flag.
--
-- Two views share the filters (session.ui.decorQuests.viewMode): By Decor lists the
-- decor, By Chain lists the chains -- a line's decor as one row, a campaign's (the
-- Garrison Campaign's 12 chapters) as one -- then the lone quests and the hunts.
--
-- Three layers, so a quest event does not rebuild the models:
--   decorQuests.models    per decor: its steps for this character (catalog + index +
--                         identity; rebuilt per sweep or login)
--   decorQuests.progress  per decor: steps done, the step to head for, the state
--                         (the quest ticks + the player's picks), in flat maps;
--                         decorQuests.chapters the same per campaign chapter line
--   decorQuests.chains    per chain: its decor and its state, over every decor
--   decorQuests.filtered / listRows / chainRows / detailRows on top.
-- A model holds only its own steps' questIDs; the decoded lines stay in StaticData's
-- weak cache, and the detail decodes the selected decor's line again for its ladder.

HDG = HDG or {}
local Selectors = HDG.Selectors

local UI_PATH = "session.ui.decorQuests"
local TREASURE_SOURCE = "Decor Treasure Hunt"   -- ItemAugment's source name for the neighborhood hunts
local TREASURE_GROUP  = "treasure"              -- the list group (and kind) of those hunts
local UNKNOWN_EXP     = "?"                     -- a decor the catalog tags with no expansion
local KIND_ORDER      = { "chain", "single", "treasure" }
local SIDE_NAME       = { A = "RS_SIDE_ALLIANCE", H = "RS_SIDE_HORDE" }

local function L(key) return HDG.Locale:Get(key) end

local function _byName(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.decorID < b.decorID
end

-- Writes v, but never nil over a field the row doesn't have: in WoW's Lua 5.1 that inserts
-- the key (memory playbook, trap 4).
local function _put(row, k, v)
    if v ~= nil or rawget(row, k) ~= nil then row[k] = v end
end

-- ============================================================================
-- State mirrors
-- ============================================================================

for _, key in ipairs({ "viewMode", "preset", "searchQuery", "expFilter", "kindFilter", "hideCollected",
                       "collapsed", "openFolds", "openChapters", "picks", "selected" }) do
    Selectors:DefinePath("decorQuests." .. key, UI_PATH .. "." .. key)
end

for _, mode in ipairs({ "decor", "chain" }) do
    Selectors:Register("decorQuests.isViewMode_" .. mode, {
        calls = { "decorQuests.viewMode" },
        fn = function(state, ctx) return Selectors:Call("decorQuests.viewMode", state, ctx) == mode end,
    })
end

for _, p in ipairs(HDG.Constants.DQ_PRESETS) do
    local value = p.value
    Selectors:Register("decorQuests.preset.active_" .. value, {
        calls = { "decorQuests.preset" },
        fn = function(state, ctx) return Selectors:Call("decorQuests.preset", state, ctx) == value end,
    })
end

-- ============================================================================
-- Who a step is for
-- ============================================================================
-- me = { side ("A" / "H" / "N"), raceID, classID } from session.identity.

local function _passes(code, me)
    if code == "" then return true end
    local g = HDG.StaticData.DecorQuests:Gate(code)
    return not g.removed and (g.side == nil or g.side == me.side)
        and (g.races == nil or g.races[me.raceID] == true)
        and (g.classes == nil or g.classes[me.classID] == true)
end

-- A set of class or race IDs as names, sorted: "Evoker", "Dracthyr / Earthen".
local function _names(set, nameOf)
    local out = {}
    for id in pairs(set) do out[#out + 1] = nameOf(id) or ("#" .. id) end   -- exception(nullable): an ID this client cannot name shows its number
    table.sort(out)
    return table.concat(out, " / ")
end

-- The classes a set leaves out, when it holds most of them (11 of 13 reads better as the 2).
local function _classesLeftOut(set)
    local out, n = {}, 0
    for id = 1, HDG.Constants.DQ_CLASS_ID_MAX do
        if set[id] then n = n + 1 else out[id] = true end
    end
    if n * 2 <= HDG.Constants.DQ_CLASS_ID_MAX then return nil end
    return out
end

-- Who a gate is for, when it is not for this character: the other faction when the
-- gate names it, else its classes, else its races ("Alliance", "Evoker"). A class gate
-- that holds most classes names the ones it leaves out, and says so (second return).
local function _whoFor(code, me)
    local g = HDG.StaticData.DecorQuests:Gate(code)
    if g.side and g.side ~= me.side then return L(SIDE_NAME[g.side]), false end
    if g.classes and not g.classes[me.classID] then
        local out = _classesLeftOut(g.classes)
        return _names(out or g.classes, HDG.SessionIdentity.ClassName), out ~= nil
    end
    return _names(g.races, HDG.SessionIdentity.RaceName), false
end

-- "Alliance only", or "Not for Demon Hunter / Evoker" for a class gate named by what it leaves out.
local function _onlyText(m)
    return L(m.whoNot and "DQ_NOT_FOR" or "DQ_ONLY"):format(m.who)
end

-- ============================================================================
-- Models: one per quest decor, its steps for this character
-- ============================================================================
-- model = { decorID, itemID, name, icon, exps, kind, ids, q, twins, lineID, lineName, at, map,
--           questName, side, steps, bc, other, who, whoNot, whyBefore, search, chainKey }
--   exps       every expansion the catalog tags the decor with, oldest first (display names;
--              UNKNOWN_EXP alone when it tags none); exps[1] is the group it lists under.
--              The Expansion filter and its counts match any of them (owner ruling 2026-10-31).
--              No separate field for the first: one more field doubled the hash part of
--              118 of the 320 models, 45 KB held (perf budget, 2026-10-31)
--   (search and npcIDs only on decorQuests.models' list: the tracker's models leave them out)
--   ids        the catalog row's questID: one ID or { ids } (every faction's copy; the
--              warband has done the decor when it has done any of them)
--   q          the decor quest variant this character can take (else the first)
--   twins      the other variants this character can take, or nil (done if any is)
--   at         the decor quest's step in its line (every decor quest is a step of
--              its own line: test_decor_quests_tab pins it on the real index); 1 for
--              a solo quest
--   steps      questIDs this character takes, in order, ending with q
--   bc         [k] = the quest steps[k] is a breadcrumb to, or nil (most ladders hold none);
--              progress leaves out the ones this character no longer needs (_moot)
--   ahead      [k] = steps[k] is a lead-in to a later step of its own line (true / false), on a
--              ladder with a breadcrumb
--   grp        [questID] = the step's any-order group on its line, or nil (most ladders hold none)
--   other      the decor quest is not for this character, or every step before it
--              is not; who names the gate (whoNot: by the classes it leaves out),
--              whyBefore says which of the two
--   chainKey   its By Chain row: "camp:<id>" for a campaign chapter's decor (a campaign
--              is one row), else "L:<lineID>"; absent on a lone quest and a treasure hunt

local function _indexOf(line, q)
    for i = 1, line.n do
        if line.q[i] == q then return i end
    end
    error(("HDG.DecorQuests: quest %d is not a step of its line %q"):format(q, line.name))
end

-- A decor quest's place in the index: lineID, line, at, map, gate. A solo quest has no
-- line and is step 1 of itself; one the index does not know at all has no map and no gate.
local function _locate(q, side)
    local DQ = HDG.StaticData.DecorQuests
    local lineID = DQ:ChainOf(q, side)
    if lineID then
        local line = DQ:Line(lineID)
        local at = _indexOf(line, q)
        return lineID, line, at, DQ:StepMap(line, at, side), line.gate[at]
    end
    local map, gate = DQ:SoloStep(q, side)
    return nil, nil, 1, map or 0, gate or ""   -- exception(nullable): a catalog quest the index does not ship
end

local function _gateOf(q, side)
    local _, _, _, _, gate = _locate(q, side)
    return gate
end

-- The variant to show and its twins: row.questID is one ID or { ids } (the factions'
-- copies). A foreign twin says nothing about this character, so only passing ones count.
local function _variants(questID, me)
    if type(questID) ~= "table" then return questID, nil end
    local q, twins
    for _, id in ipairs(questID) do
        if _passes(_gateOf(id, me.side), me) then
            if q then twins = twins or {}; twins[#twins + 1] = id else q = id end
        end
    end
    return q or questID[1], twins
end

local function _isTreasure(itemID)
    local aug = HDG.StaticData.ItemAugment:Get(itemID)   -- exception(nullable): most decor carries no augment
    local sources = aug and aug.sources                   -- exception(optional): a rep-gate-only augment lists no sources
    if not sources then return false end
    for _, s in ipairs(sources) do
        if s.name == TREASURE_SOURCE then return true end
    end
    return false
end

-- Any-order groups (ruling G, owner 2026-10-27): quests the game hands out together. Their
-- helpers share one table, the file being at Lua's cap of 200 locals.
local Groups = {}

-- Step i of line's any-order group, under its questID.
function Groups.note(m, line, i)
    local g = line.grp and line.grp[i]   -- exception(optional): few lines hold an any-order group
    if not g then return end
    m.grp = m.grp or {}   -- exception(optional): the first grouped step on this ladder
    m.grp[line.q[i]] = g
end

-- Step i of line as the next of m's steps, its group and the quest it is a breadcrumb to.
local function _addStep(m, steps, line, i)
    steps[#steps + 1] = line.q[i]
    Groups.note(m, line, i)
    local leadsTo = line.bc and line.bc[i]   -- exception(optional): few lines hold a breadcrumb
    if not leadsTo then return end
    m.bc, m.ahead = m.bc or {}, m.ahead or {}   -- exception(optional): the first breadcrumb on this ladder
    m.bc[#steps] = leadsTo
    m.ahead[#steps] = line.ahead ~= nil and line.ahead[i] == true   -- exception(optional): few lines hold a lead-in into themselves
end

-- The steps up to the decor quest that this character can take, then the decor quest.
local function _stepsFor(m, line, gate, me)
    local steps = {}
    if line then
        for i = 1, m.at - 1 do
            if _passes(line.gate[i], me) then _addStep(m, steps, line, i) end
        end
    end
    steps[#steps + 1] = m.q
    if line then Groups.note(m, line, m.at) end
    m.steps = steps
    if not _passes(gate, me) then
        m.other = true
        m.who, m.whoNot = _whoFor(gate, me)
    elseif line and m.at > 1 and #steps == 1 then
        m.other, m.whyBefore = true, true
        m.who, m.whoNot = _whoFor(line.gate[1], me)
    end
end

local function _zoneName(map)
    if map == 0 then return nil end
    return HDG.ZoneNameResolver:MapName(map)
end

-- The search text and the givers it holds (Search); the tracker's strip of discs (Strip) and
-- its place lines, which the detail's Next block and ladder share (Place). Helpers in tables:
-- the file is at Lua's cap of 200 locals.
local Search, Strip, Place = {}, {}, {}

-- Whether step i of line shows this character: its gate passes, or it is step keep (a decor's
-- own quest, shown whatever its gate).
function Search.shows(line, i, keep, me)
    return i == keep or _passes(line.gate[i], me)
end

-- Calls visit(acc, lineID, line, upTo, keep, me) for each run of steps m's chain searches by:
-- its own line up to its quest, then for a campaign decor this character can take every other
-- chapter on this side, whole -- the campaign is one chain (one row in By Chain, its chapters
-- in any order), and the garrison's own NPCs (Bodrick Grey, Nixxie) start chapters that hold
-- no decor. The other faction's campaign decor keep to their own chapter, as a line's do to
-- their gates. A visit that returns true ends the walk (a match found), and so does eachRun.
function Search.eachRun(m, line, me, visit, acc)
    if visit(acc, m.lineID, line, m.at, m.at, me) then return true end
    if m.kind ~= "chain" or m.other or not m.chainKey:find("^camp:") then return false end
    local DQ = HDG.StaticData.DecorQuests
    for _, ch in ipairs(DQ:ChaptersFor(DQ:ChapterOf(m.lineID).campaign, me.side)) do
        local chapter = DQ:Line(ch[1])
        if ch[1] ~= m.lineID and visit(acc, ch[1], chapter, chapter.n, nil, me) then return true end
    end
    return false
end

-- A run's visit: appends who starts each step of it this character can take, as StepGivers
-- gives them (npcID, an object's or item's name, or false).
function Search.addGivers(out, lineID, line, upTo, keep, me)
    local all = HDG.StaticData.DecorQuests:StepGivers(lineID, upTo, me.side)
    for i = 1, upTo do
        if Search.shows(line, i, keep, me) then out[#out + 1] = all[i] end
    end
end

-- Who starts the steps m's chain shows this character, its own quest last (solo: just that
-- one; a campaign decor: every chapter's too).
function Search.giversOf(m, line, me)
    if not line then
        local start = HDG.StaticData.DecorQuests:SoloStart(m.q, me.side)
        if not start then return {} end   -- exception(nullable): a catalog quest the index does not ship
        return { start.npcID or start.object or start.item or false }   -- exception(optional): a solo step may name nobody
    end
    local out = {}
    Search.eachRun(m, line, me, Search.addGivers, out)
    return out
end

-- A run's visit: whether a step of it this character can take is one the search names
-- (hits: decorQuests.titleHits).
function Search.runHit(hits, _, line, upTo, keep, me)
    for i = 1, upTo do
        if hits[line.q[i]] and Search.shows(line, i, keep, me) then return true end
    end
    return false
end

-- Whether the search names a step m's chain shows this character (its quests' enUS names,
-- the index's titles): walked per query, not held in m.search -- Twilight Highlands' 243
-- titles would sit in every one of its decor's.
function Search.stepHit(m, f)
    if not m.lineID or next(f.titleHits) == nil then return false end
    return Search.eachRun(m, HDG.StaticData.DecorQuests:Line(m.lineID), f.me, Search.runHit, f.titleHits)
end

-- The search text: the decor, its chain and quest, the zone, and who starts each step in
-- English, each giver once (decorQuests.npcSearch adds the NPCs' names in the client's
-- language, by m.npcIDs).
function Search.text(m, givers)
    local words = { m.name, m.lineName or "", m.questName or "", _zoneName(m.map) or "" }   -- exception(optional): solo decor have no line, uncatalogued quests no name, maps no zone
    local seen = {}
    m.npcIDs = {}
    for _, g in ipairs(givers) do
        if g and not seen[g] then
            seen[g] = true
            if type(g) == "number" then
                m.npcIDs[#m.npcIDs + 1] = g
                g = HDG.StaticData.DecorQuests:NpcName(g)
            end
            words[#words + 1] = g
        end
    end
    return Search.fold(table.concat(words, " "))
end

local function _chainKey(lineID)
    local at = HDG.StaticData.DecorQuests:ChapterOf(lineID)
    if at then return "camp:" .. at.campaign.id end
    return "L:" .. lineID
end

-- The decor's expansions as display names, oldest first (the model's exps). One
-- shared list per stored value: every model of a rebuild holding its own copy
-- cost 18 KB held (perf budget, 2026-10-31). Read it, never write it.
local UNKNOWN_EXPS = { UNKNOWN_EXP }
local _expsByValue = {}
local function _expsOf(row)
    if not row.expansion then return UNKNOWN_EXPS end   -- exception(nullable): a decor the catalog tags with no expansion
    local out = _expsByValue[row.expansion]
    if out then return out end
    out = {}
    for i, name in ipairs(HDG.Expansion.Members(row.expansion)) do
        out[i] = HDG.Expansion.GetFull(name) or UNKNOWN_EXP   -- exception(nullable): a tag name EXPANSION_DATA does not know
    end
    _expsByValue[row.expansion] = out
    return out
end

local function _buildModel(row, me)
    local q, twins = _variants(row.questID, me)
    local lineID, line, at, map, gate = _locate(q, me.side)
    local m = { decorID = row.decorID, itemID = row.itemID, name = row.name, icon = row.iconTexture,
                exps = _expsOf(row),
                ids = row.questID, q = q, twins = twins, lineID = lineID, at = at, map = map, questName = row.quest, other = false,
                lineName = line and line.name,   -- exception(nullable): a solo quest has no line
                side = HDG.StaticData.DecorQuests:Gate(gate).side }
    m.kind = (_isTreasure(row.itemID) and TREASURE_GROUP) or (lineID and "chain") or "single"
    if m.kind == "chain" then m.chainKey = _chainKey(lineID) end
    m.repeats = HDG.StaticData.DecorQuests:Repeat(q)   -- exception(nullable): most decor quests are done once
    _stepsFor(m, line, gate, me)
    return m, line
end

-- [chainKey] = { models }, in the list's order (by name).
local function _byChain(list)
    local out = {}
    for _, m in ipairs(list) do
        if m.chainKey then
            out[m.chainKey] = out[m.chainKey] or {}
            table.insert(out[m.chainKey], m)
        end
    end
    return out
end

-- Who is looking: the side, race and class a step's gate is read against.
local function _meOf(state)
    local id = state.session.identity
    return { side = id.factionGroup, raceID = id.raceID, classID = id.classID }
end

Selectors:Register("decorQuests.models", {
    memoized = true,
    reads = { "session.resolvers.catalog.tick", "session.resolvers.staticData.tick",
              "session.identity.factionGroup", "session.identity.raceID", "session.identity.classID" },
    fn = function(state)
        local me = _meOf(state)
        local list, byDecor = {}, {}
        for _, row in pairs(HDG.HousingCatalogObserver.byDecorID) do
            if row.questID then
                local m, line = _buildModel(row, me)
                -- Only the list searches and counts copies: the tracker builds its models from
                -- the rows Track saved, without either (review section 5), and its zone list
                -- from the catalog rows that may start there (decorQuests.zoneStarts).
                m.search = Search.text(m, Search.giversOf(m, line, me))
                m.copies = row.quantity + row.remainingRedeemable + row.numPlaced   -- what the catalog counts as owned
                list[#list + 1] = m
                byDecor[m.decorID] = m
            end
        end
        table.sort(list, _byName)
        return { list = list, byDecor = byDecor, byChain = _byChain(list), me = me }
    end,
})

-- ============================================================================
-- Progress, per decor, in flat maps keyed by decorID
-- ============================================================================
-- state[d] = "done" (the warband's, and collected) | "missing" (the warband's, but not in the
-- collection: it counts as To do, ruling 10-26) | "other" | "progress" | "new"; for all but the other
-- faction's decor also here[d] (this character finished it), nDone[d] (this character's
-- steps done), cur[d] (the step to head for: the player's pick, else the step after the
-- last done one; 0 = none, a done decor until a pick) and left[d] (the steps this
-- character has not done, skipped ones too, so nDone + left = all). steps[d] = the steps
-- those count, every decor's: m.steps less the breadcrumbs this character no longer
-- needs (_moot), m.steps itself when none is.

local function _decorDone(m)
    if HDG.QuestNameResolver:IsComplete(m.q) then return true end
    for _, id in ipairs(m.twins or {}) do   -- exception(optional): most decor quests have no twin
        if HDG.QuestNameResolver:IsComplete(id) then return true end
    end
    return false
end

-- Over the steps before the decor quest: how many are done, the last done one, and
-- whether any is in the log.
local function _countSteps(steps)
    local nDone, lastDone, inLog = 0, 0, false
    for i = 1, #steps - 1 do
        local q = steps[i]
        if HDG.QuestNameResolver:IsComplete(q) then
            nDone, lastDone = nDone + 1, i
        elseif HDG.QuestNameResolver:IsOnQuest(q) then
            inLog = true
        end
    end
    return nDone, lastDone, inLog
end

-- A ladder's pick ("d:<decorID>" | "k:<lineID>") is the quest the player marked Next, never
-- its place: the ladder drops lead-ins as they go moot, and a place slid onto the quest
-- after it (review B1, 10-29). Its helpers share one table (the file's 200-local cap).
local Pick = {}

-- The picked quest: the tracker's, saved with what it follows, else this session's; nil = none.
function Pick.of(key, picks, tracked)
    local saved = tracked and tracked.picks[key]   -- exception(nullable): nothing tracked, or no pick on this ladder
    return saved or picks[key]                     -- exception(nullable): most ladders have no pick
end

-- What this character tracks (account.decorQuests.tracked[charKey]), or nil.
Selectors:Register("decorQuests.tracked", {
    reads = { "account.decorQuests.tracked", "session.identity.charKey" },
    fn = function(state)
        local charKey = HDG.SessionIdentity.GetCharKey(state)
        if not charKey then return nil end   -- exception(nullable): identity resolves after the first paint
        return state.account.decorQuests.tracked[charKey]   -- exception(nullable): nothing tracked
    end,
})

local function _newProgress() return { state = {}, here = {}, nDone = {}, cur = {}, left = {}, steps = {} } end

-- A breadcrumb this character no longer needs: not done here, and it is on the quest the
-- breadcrumb leads to or has done it (ruling 10-27), or -- `past`, a lead-in into its own
-- line further on -- it did a step before it on its road (ruling F, 10-27: a way into the
-- line, not a stop on it). It drops out of the ladder and the count; done, it counts like
-- any step.
local function _moot(q, leadsTo, past)
    if not leadsTo or HDG.QuestNameResolver:IsComplete(q) then return false end   -- exception(optional): most steps are no breadcrumb
    return past or HDG.QuestNameResolver:IsComplete(leadsTo) or HDG.QuestNameResolver:IsOnQuest(leadsTo)
end

-- This character did a step before step i of line on its road (a step it takes).
local function _doneBefore(line, i, me)
    for j = 1, i - 1 do
        if _passes(line.gate[j], me) and HDG.QuestNameResolver:IsComplete(line.q[j]) then return true end
    end
    return false
end

-- Step i of a line is one this character takes now: its gate passes, and it is no breadcrumb
-- _moot leaves out.
local function _takes(line, i, me)
    local past = line.ahead ~= nil and line.ahead[i] == true and _doneBefore(line, i, me)   -- exception(optional): few lines hold a lead-in into themselves
    return _passes(line.gate[i], me) and not _moot(line.q[i], line.bc and line.bc[i], past)   -- exception(optional): few lines hold a breadcrumb
end

-- How many of a whole line's steps this character takes.
local function _lineTotal(line, me)
    local n = 0
    for i = 1, line.n do
        if _takes(line, i, me) then n = n + 1 end
    end
    return n
end

-- m's steps for this character now: m.steps without the breadcrumbs _moot leaves out
-- (m.steps are the ones it takes, so `past` = one before k is done).
local function _liveSteps(m)
    if not m.bc then return m.steps end   -- exception(optional): few ladders hold a breadcrumb
    local out, past = {}, false
    for k, q in ipairs(m.steps) do
        if not _moot(q, m.bc[k], past and m.ahead[k]) then out[#out + 1] = q end   -- exception(nullable): bc and ahead are sparse
        past = past or HDG.QuestNameResolver:IsComplete(q)
    end
    return out
end

-- The decor quest is done (by the warband), collected or not.
local function _questDone(s) return s == "done" or s == "missing" end

-- A decor quest the game lets you do again ("daily" | "repeatable", the index's repeats): each
-- turn-in gives another copy, so it is never done (owner 10-29). No quest flags, the character's
-- or the warband's: the copies owned say it all. Its state is "progress" while the quest is in
-- the log, else "new"; never "done" or "missing", so every finished-quest reader passes it by.
-- Helpers in a table: the file is at Lua's 200-local cap.
-- GROUP: the list group (By Decor and By Chain) they all sit in, first. NOTE / TRK: per kind
-- (the index's repeats), the detail's note and the tracker's line with its tone (a plain
-- repeatable has none; a daily warns, the Full mockup).
local Repeats = { GROUP = "repeat",
    NOTE = { daily = "DQ_REPEAT_DAILY_NOTE", missive = "DQ_REPEAT_MISSIVE_NOTE", repeatable = "DQ_REPEAT_NOTE" },
    TRK  = { daily = { "DQ_TRK_DAILY", "warn" }, missive = { "DQ_TRK_MISSIVE", "text" } } }

-- The quest of the decor's in this character's log: its own, or a twin this character can also
-- take (the Trellis's Assault and its missive); nil when neither is.
function Repeats.logged(m)
    if HDG.QuestNameResolver:IsOnQuest(m.q) then return m.q end
    for _, id in ipairs(m.twins or {}) do   -- exception(optional): most decor quests have no twin
        if HDG.QuestNameResolver:IsOnQuest(id) then return id end
    end
    return nil
end

function Repeats.progress(m, P)
    local d = m.decorID
    P.here[d], P.nDone[d], P.cur[d], P.left[d] = false, 0, 1, #P.steps[d]
    P.state[d] = Repeats.logged(m) and "progress" or "new"
end

-- The row's words and tone: in the log, how many copies, or not collected.
function Repeats.stateText(m, P)
    if P.state[m.decorID] == "progress" then return L("DQ_IN_LOG") end
    if m.copies > 0 then return L("DQ_HAVE_N"):format(m.copies) end
    return L("DQ_NOT_COLLECTED")
end

function Repeats.rowState(m, P)
    if P.state[m.decorID] == "progress" then return "progress" end
    return m.copies > 0 and "done" or "new"
end

-- The first step from `from` to n that isDone(subject, i) says this character has not
-- done, or nil.
local function _openFrom(from, n, isDone, subject)
    for i = from, n do
        if not isDone(subject, i) then return i end
    end
    return nil
end

-- sub = { m, steps }: step i of the live steps is done here (the last is the decor quest).
local function _modelStepDone(sub, i)
    if i == #sub.steps then return _decorDone(sub.m) end
    return HDG.QuestNameResolver:IsComplete(sub.steps[i])
end

function Groups.ofModelStep(sub, i)
    return sub.m.grp and sub.m.grp[sub.steps[i]]   -- exception(optional): few ladders hold an any-order group
end

-- Ruling G (owner 2026-10-27): after a step in an any-order group, the group's first other
-- step not done comes next, before anything after the group. nil when step i is in no
-- group, or the rest of it is done: then the step after it. Never i itself: a step just
-- turned in can still read not done (its flag lands after QUEST_TURNED_IN; review B2).
-- groupAt(subject, i) / isDone(subject, i) read step i of the ladder.
function Groups.partner(n, i, groupAt, isDone, subject)
    local g = groupAt(subject, i)
    if not g then return nil end
    for k = 1, n do
        if k ~= i and groupAt(subject, k) == g and not isDone(subject, k) then return k end
    end
    return nil
end

-- Where quest q stands among a ladder's n steps, or nil once it has left the ladder (a
-- lead-in gone moot). ops = { questAt, groupAt, isDone }, each (subject, i) on step i.
function Pick.at(q, n, ops, subject)
    for i = 1, n do
        if ops.questAt(subject, i) == q then return i end
    end
    return nil
end

-- The step a picked quest heads for, or nil (it left the ladder: the natural Next stands).
-- Not done here, it is the pick; on a chain finished here it stands too (a replay: never
-- lock a player out, ruling 10-26). Done on a chain not finished, a finished quest is no
-- step to head for on the way (ruling 10-27): its any-order group's open step comes first
-- (ruling G), else the first step after it not done.
function Pick.headFor(q, n, here, ops, subject)
    local num = Pick.at(q, n, ops, subject)
    if not num or here or not ops.isDone(subject, num) then return num end
    return Groups.partner(n, num, ops.groupAt, ops.isDone, subject) or _openFrom(num + 1, n, ops.isDone, subject)
end

-- A decor's live steps: subject = { m, steps }, steps its quest IDs.
Pick.MODEL = { questAt = function(sub, i) return sub.steps[i] end, groupAt = Groups.ofModelStep, isDone = _modelStepDone }

local function _progressOf(m, pick, P, owned)
    local d, steps = m.decorID, _liveSteps(m)
    local n, warband = #steps, HDG.QuestNameResolver:IsCompleteOnAccount(m.ids)
    P.steps[d] = steps
    if m.other then P.state[d] = warband and "done" or "other"; return end
    if m.repeats then return Repeats.progress(m, P) end
    local here = _decorDone(m)
    local nDone, lastDone, inLog = _countSteps(steps)
    if here then
        nDone, lastDone = nDone + 1, n
    else
        inLog = inLog or HDG.QuestNameResolver:IsOnQuest(m.q)
    end
    local done = here or warband
    local cur = (done and 0)   -- a subject table only for a ladder with a group or a pick: this runs per decor per refresh
        or (m.grp and lastDone > 0 and Groups.partner(n, lastDone, Groups.ofModelStep, _modelStepDone, { m = m, steps = steps }))   -- exception(optional): only ladders with an any-order group carry m.grp
        or (lastDone + 1)
    if pick then cur = Pick.headFor(pick, n, here, Pick.MODEL, { m = m, steps = steps }) or cur end
    P.here[d], P.nDone[d], P.cur[d] = here, nDone, cur
    P.left[d] = n - nDone
    P.state[d] = (done and (owned[d] and "done" or "missing")) or ((nDone > 0 or inLog) and "progress") or "new"
end

Selectors:Register("decorQuests.progress", {
    memoized = true,
    reads = { "session.resolvers.questStatus.tick", "session.resolvers.questLog.tick", UI_PATH .. ".picks",
              "account.collection.ownedDecorIDs" },
    calls = { "decorQuests.models", "decorQuests.tracked" },
    fn = function(state, ctx)
        local picks, tracked = state.session.ui.decorQuests.picks, Selectors:Call("decorQuests.tracked", state, ctx)
        local P, owned = _newProgress(), state.account.collection.ownedDecorIDs
        for _, m in ipairs(Selectors:Call("decorQuests.models", state, ctx).list) do
            _progressOf(m, Pick.of("d:" .. m.decorID, picks, tracked), P, owned)
        end
        return P
    end,
})

-- This character's progress packed for the others' alts block (DQ_ALT_SCANNED):
-- " decorID=d" per decor it finished (skipped steps or not), " decorID=n/N" per decor
-- it has started, " decorID=x" per decor it can't take. nil until the catalog has
-- loaded (no models): a scan then would read as nothing started.
local function _altPart(m, P)
    local d = m.decorID
    if m.other then return d .. "=x" end
    if P.here[d] then return d .. "=d" end
    if P.nDone[d] > 0 then return d .. "=" .. P.nDone[d] .. "/" .. #P.steps[d] end
    return nil
end

Selectors:Register("decorQuests.altProgress", {
    calls = { "decorQuests.models", "decorQuests.progress" },
    fn = function(state, ctx)
        local M = Selectors:Call("decorQuests.models", state, ctx)
        if #M.list == 0 then return nil end   -- exception(nullable): the catalog loads with the main window
        local P, parts = Selectors:Call("decorQuests.progress", state, ctx), {}
        for _, m in ipairs(M.list) do
            local part = _altPart(m, P)
            if part then parts[#parts + 1] = part end
        end
        return " " .. table.concat(parts, " ") .. " "
    end,
})

-- ============================================================================
-- Campaign chapters: this character's progress (quests are per character)
-- ============================================================================
-- [lineID] = { n (steps done), total (steps this character takes), state ("done" |
-- "progress" | "new"), inLog (a step is in the log) } for every chapter line on this character's side, of the
-- campaigns some decor comes from (no decor, no card). A chapter is in progress once a
-- step is done or in the log.

local function _chapterProgress(lineID, me)
    local line, c = HDG.StaticData.DecorQuests:Line(lineID), { n = 0, total = 0 }
    local inLog = false
    for i = 1, line.n do
        if _takes(line, i, me) then
            c.total = c.total + 1
            if HDG.QuestNameResolver:IsComplete(line.q[i]) then
                c.n = c.n + 1
            else
                inLog = inLog or HDG.QuestNameResolver:IsOnQuest(line.q[i])
            end
        end
    end
    c.state = (c.n == c.total and "done") or ((c.n > 0 or inLog) and "progress") or "new"
    c.inLog = inLog
    return c
end

Selectors:Register("decorQuests.chapters", {
    memoized = true,
    reads = { "session.resolvers.questStatus.tick", "session.resolvers.questLog.tick",
              "session.resolvers.staticData.tick" },
    calls = { "decorQuests.models" },
    fn = function(state, ctx)
        local DQ, M, out = HDG.StaticData.DecorQuests, Selectors:Call("decorQuests.models", state, ctx), {}
        for key, ms in pairs(M.byChain) do
            if key:find("^camp:") then
                local c = DQ:ChapterOf(ms[1].lineID).campaign
                for _, ch in ipairs(DQ:ChaptersFor(c, M.me.side)) do out[ch[1]] = _chapterProgress(ch[1], M.me) end
            end
        end
        return out
    end,
})

-- ============================================================================
-- Chains (By Chain): a line's decor, or a campaign's, as one entry
-- ============================================================================
-- [chainKey] = { key, name, ms (every decor of the chain, whatever the filters), exp,
--   icons, state, n, nDone, unit, far (a line's: the decor with the most steps, its bar
--   and ladder), campaign + chapters (a campaign's: its chapter lines on this side) }.
-- The state comes from all the chain's decor, not only the ones the filters let through
-- (the mockup's rule): done once the warband did every one and they are collected, missing
-- (as a decor's) when it did every one but one is not in the collection, other when every
-- one is the other faction's; a line counts steps, a campaign chapters.
local CHAIN_ICONS = 4   -- the decor icons a chain row shows

local function _chainState(ms, P, started)
    local done, got, other = true, true, true
    for _, m in ipairs(ms) do
        done = done and _questDone(P.state[m.decorID])
        got = got and P.state[m.decorID] == "done"
        other = other and m.other
    end
    if done then return got and "done" or "missing" end
    return (other and "other") or (started and "progress") or "new"
end

local function _icons(ms)
    local out = {}
    for i = 1, math.min(#ms, CHAIN_ICONS) do out[i] = ms[i].icon or HDG.Constants.PLACEHOLDER_ICON end   -- exception(nullable): a catalog row the client sent no icon for
    return out
end

-- The decor this character can take with the most steps, else the first.
local function _farthest(ms)
    local far
    for _, m in ipairs(ms) do
        if not m.other and (far == nil or #m.steps > #far.steps) then far = m end
    end
    return far or ms[1]
end

local function _lineEntry(key, ms, P)
    local far, started = _farthest(ms), false
    for _, m in ipairs(ms) do started = started or (not m.other and P.state[m.decorID] ~= "new") end
    return { key = key, name = far.lineName, ms = ms, exps = far.exps, icons = _icons(ms), far = far,
             n = #P.steps[far.decorID], nDone = P.nDone[far.decorID] or 0, unit = "DQ_UNIT_STEPS",   -- exception(nullable): the other faction's decor count no steps
             state = _chainState(ms, P, started) }
end

local function _campaignEntry(key, ms, P, chapters, me)
    local DQ = HDG.StaticData.DecorQuests
    local c = DQ:ChapterOf(ms[1].lineID).campaign
    local list, nDone, started = DQ:ChaptersFor(c, me.side), 0, false
    for _, ch in ipairs(list) do
        local cp = chapters[ch[1]]
        if cp.state == "done" then nDone = nDone + 1 end
        started = started or cp.state ~= "new"
    end
    return { key = key, name = c.name, ms = ms, exps = ms[1].exps, icons = _icons(ms), campaign = c,
             chapters = list, n = #list, nDone = nDone, unit = "DQ_UNIT_CHAPTERS",
             state = _chainState(ms, P, started) }
end

Selectors:Register("decorQuests.chains", {
    memoized = true,
    calls = { "decorQuests.models", "decorQuests.progress", "decorQuests.chapters" },
    fn = function(state, ctx)
        local M, P = Selectors:Call("decorQuests.models", state, ctx), Selectors:Call("decorQuests.progress", state, ctx)
        local chapters, out = Selectors:Call("decorQuests.chapters", state, ctx), {}
        for key, ms in pairs(M.byChain) do
            if key:find("^camp:") then
                out[key] = _campaignEntry(key, ms, P, chapters, M.me)
            else
                out[key] = _lineEntry(key, ms, P)
            end
        end
        return out
    end,
})

-- ============================================================================
-- Filtering, presets, counts
-- ============================================================================

local function _open(s) return s == "new" or s == "progress" end

-- pass(state, here): here is nil for the other faction's decor (never done here).
local PRESET_PASS = {
    todo     = function(s) return _open(s) or s == "missing" end,
    progress = function(s) return s == "progress" end,
    here     = function(s, here) return here == true and s == "done" end,
    done     = function(s) return s == "done" end,
    all      = function() return true end,
}

-- The names a decor's NPC givers go by in the client's language where the game has given one
-- that differs from the English the models search, lowercased; nil when none does (every
-- name on an English client). Only names already in session.npcNames.names: asking the game
-- for every giver of every decor (1,208 NPCs) would be a burst of lookups.
local function _localGiverNames(m, names)
    local words = {}
    for _, npcID in ipairs(m.npcIDs) do
        local shown = names[npcID]   -- exception(nullable): a name the game hasn't been asked for
        if shown and shown ~= HDG.StaticData.DecorQuests:NpcName(npcID) then words[#words + 1] = shown end
    end
    if #words == 0 then return nil end
    return Search.fold(table.concat(words, " "))
end

Selectors:Register("decorQuests.npcSearch", {
    memoized = true,
    reads = { "session.npcNames.names" },
    calls = { "decorQuests.models" },
    fn = function(state, ctx)
        local out, names = {}, state.session.npcNames.names
        for _, m in ipairs(Selectors:Call("decorQuests.models", state, ctx).list) do
            out[m.decorID] = _localGiverNames(m, names)
        end
        return out
    end,
})

-- The search box: the model's English words, then its givers' names in the client's language
-- (decorQuests.npcSearch, nil where none differ), then its steps' names.
local function _queryPass(m, f)
    if f.query == "" or m.search:find(f.query, 1, true) then return true end
    local localNames = f.npcSearch[m.decorID]   -- exception(nullable): no giver of this decor has a name of its own here
    return (localNames ~= nil and localNames:find(f.query, 1, true) ~= nil) or Search.stepHit(m, f)
end

-- Text as the search compares it: lowercased, each run of punctuation and spaces one space,
-- trimmed -- so "wanted hogger" finds WANTED:  "Hogger". %p, not %W: a UTF-8 letter's bytes
-- are not punctuation, so a localized name keeps its letters.
function Search.fold(text)
    return (text:lower():gsub("[%p%s]+", " "):match("^ ?(.-) ?$"))
end

-- The search as typed, folded (Search.fold).
function Search.query(ui)
    return Search.fold(ui.searchQuery)
end

-- The quests whose enUS name holds the search (StaticData DecorQuests:TitleHits): one pass
-- over the index's titles per query, so a step's name finds its decor. Not under
-- DQ_STEP_SEARCH_MIN letters: "a" holds 2,120 titles, near every decor, and walked each
-- decor's quest lines on every keystroke (review 2026-10-31 P4).
Selectors:Register("decorQuests.titleHits", {
    memoized = true,
    reads = { UI_PATH .. ".searchQuery", "session.resolvers.staticData.tick" },
    fn = function(state)
        local query = Search.query(state.session.ui.decorQuests)
        if #query < HDG.Constants.DQ_STEP_SEARCH_MIN then return {} end
        return HDG.StaticData.DecorQuests:TitleHits(query)
    end,
})

local function _anyExp(exps, set)
    for _, exp in ipairs(exps) do
        if set[exp] == true then return true end
    end
    return false
end

local function _shown(m, f, P)
    local d = m.decorID
    return (m.repeats ~= nil or PRESET_PASS[f.preset](P.state[d], P.here[d]))   -- a repeatable under every chip (owner 10-29)
        and not (f.hide and f.owned[d] == true)
        and (next(f.exp) == nil or _anyExp(m.exps, f.exp))
        and (next(f.kind) == nil or f.kind[m.kind] == true)
        and _queryPass(m, f)
end

-- The list's filters as the panel sets them (decorQuests.blankText reruns them on All).
function Search.filter(state, ctx)
    local ui = state.session.ui.decorQuests
    return { preset = ui.preset, hide = ui.hideCollected, owned = state.account.collection.ownedDecorIDs,
             exp = ui.expFilter, kind = ui.kindFilter, query = Search.query(ui),
             npcSearch = Selectors:Call("decorQuests.npcSearch", state, ctx),
             titleHits = Selectors:Call("decorQuests.titleHits", state, ctx),
             me = Selectors:Call("decorQuests.models", state, ctx).me }
end

Selectors:Register("decorQuests.filtered", {
    memoized = true,
    reads = { UI_PATH .. ".preset", UI_PATH .. ".searchQuery", UI_PATH .. ".expFilter",
              UI_PATH .. ".kindFilter", UI_PATH .. ".hideCollected", "account.collection.ownedDecorIDs" },
    calls = { "decorQuests.models", "decorQuests.progress", "decorQuests.npcSearch", "decorQuests.titleHits" },
    fn = function(state, ctx)
        local f = Search.filter(state, ctx)
        local P, out = Selectors:Call("decorQuests.progress", state, ctx), {}
        for _, m in ipairs(Selectors:Call("decorQuests.models", state, ctx).list) do
            if _shown(m, f, P) then out[#out + 1] = m end
        end
        return out
    end,
})

-- Over every quest decor, whatever the filters: each preset's count, and how many of
-- this character's decor are collected (the header).
local function _countPresets(counts, s, here, always)
    for value, pass in pairs(PRESET_PASS) do
        if always or pass(s, here) then counts[value] = counts[value] + 1 end
    end
end

Selectors:Register("decorQuests.counts", {
    memoized = true,
    reads = { "account.collection.ownedDecorIDs" },
    calls = { "decorQuests.models", "decorQuests.progress" },
    fn = function(state, ctx)
        local P, owned = Selectors:Call("decorQuests.progress", state, ctx), state.account.collection.ownedDecorIDs
        local c = { presets = {}, mine = 0, collected = 0 }
        for value in pairs(PRESET_PASS) do c.presets[value] = 0 end
        for _, m in ipairs(Selectors:Call("decorQuests.models", state, ctx).list) do
            _countPresets(c.presets, P.state[m.decorID], P.here[m.decorID], m.repeats ~= nil)
            if not m.other then
                c.mine = c.mine + 1
                if owned[m.decorID] then c.collected = c.collected + 1 end
            end
        end
        return c
    end,
})

for _, p in ipairs(HDG.Constants.DQ_PRESETS) do
    local value, key = p.value, p.key
    Selectors:Register("decorQuests.presetLabel_" .. value, {
        reads = { "account.config.scheme" },   -- the count's dim colour code
        calls = { "decorQuests.counts" },
        fn = function(state, ctx)
            local n = Selectors:Call("decorQuests.counts", state, ctx).presets[value]
            return L("DQ_CHIP_COUNT"):format(L(key), HDG.Theme:ColorCode("text.dim") .. n .. "|r")
        end,
    })
end

-- The header: this character's quest decor collected, the total the chips count too.
Selectors:Register("decorQuests.countLabel", {
    calls = { "decorQuests.counts" },
    fn = function(state, ctx)
        local c = Selectors:Call("decorQuests.counts", state, ctx)
        return L("DQ_COUNT"):format(c.collected, c.mine)
    end,
})

-- The empty list's sentence. A search that finds nothing under the chip says where its matches
-- are: the same search on All with Hide collected off. None there either: the filters' sentence.
function Search.presetName(value)
    for _, p in ipairs(HDG.Constants.DQ_PRESETS) do
        if p.value == value then return L(p.key) end
    end
    error("decorQuests: unknown preset " .. tostring(value))
end

function Search.blankSentence(ui, n)
    local hi = HDG.Theme:ColorCode("text.primary")
    local q = (ui.searchQuery:match("^%s*(.-)%s*$"):gsub("|", "||"))   -- a typed "|" would start an escape
    if ui.preset == "all" then return L("DQ_BLANK_HIDDEN"):format(q, n) end
    local key = ui.hideCollected and "DQ_BLANK_UNDER_ALL_HIDE" or "DQ_BLANK_UNDER_ALL"
    return L(key):format(hi .. Search.presetName(ui.preset) .. "|r", q, n, hi .. L("DQ_PRESET_ALL") .. "|r")
end

Selectors:Register("decorQuests.blankText", {
    reads = { UI_PATH .. ".preset", UI_PATH .. ".searchQuery", UI_PATH .. ".expFilter", UI_PATH .. ".kindFilter",
              UI_PATH .. ".hideCollected", "account.collection.ownedDecorIDs", "account.config.scheme" },
    calls = { "decorQuests.filtered", "decorQuests.models", "decorQuests.progress", "decorQuests.npcSearch",
              "decorQuests.titleHits" },
    fn = function(state, ctx)
        local f = Search.filter(state, ctx)
        if f.query == "" or #Selectors:Call("decorQuests.filtered", state, ctx) > 0 then return L("DQ_BLANK") end
        f.preset, f.hide = "all", false
        local P, n = Selectors:Call("decorQuests.progress", state, ctx), 0
        for _, m in ipairs(Selectors:Call("decorQuests.models", state, ctx).list) do
            if _shown(m, f, P) then n = n + 1 end
        end
        if n == 0 then return L("DQ_BLANK") end
        return Search.blankSentence(state.session.ui.decorQuests, n)
    end,
})

Selectors:Register("decorQuests.hasResults", {
    calls = { "decorQuests.filtered" },
    fn = function(state, ctx) return #Selectors:Call("decorQuests.filtered", state, ctx) > 0 end,
})
Selectors:Register("decorQuests.isBlank", {
    calls = { "decorQuests.hasResults" },
    fn = function(state, ctx) return not Selectors:Call("decorQuests.hasResults", state, ctx) end,
})

-- ============================================================================
-- Filter menus (Expansion, Kind) and Reset
-- ============================================================================

local function _kindLabel(kind) return L("DQ_KIND_" .. kind:upper()) end
local function _expLabel(exp) return exp == UNKNOWN_EXP and L("DQ_EXP_UNKNOWN") or exp end

-- Every expansion of a decor or chain, each in its brand colour, oldest first.
local function _coloredExps(exps)
    local out = {}
    for i, exp in ipairs(exps) do
        out[i] = (HDG.Expansion.GetColorHex(exp) or "") .. _expLabel(exp) .. "|r"   -- exception(nullable): Unknown has no brand color
    end
    return table.concat(out, ", ")
end

Selectors:Register("decorQuests.axisCounts", {
    memoized = true,
    calls = { "decorQuests.models" },
    fn = function(state, ctx)
        local c = { exp = {}, kind = {} }
        for _, m in ipairs(Selectors:Call("decorQuests.models", state, ctx).list) do
            for _, exp in ipairs(m.exps) do
                c.exp[exp] = (c.exp[exp] or 0) + 1      -- exception(nullable): first decor of its expansion
            end
            c.kind[m.kind] = (c.kind[m.kind] or 0) + 1  -- exception(nullable): first decor of its kind
        end
        return c
    end,
})

-- Newest expansion first (the list's group order), Unknown last.
local function _expOrder()
    local out = {}
    for _, e in HDG.Expansion.Each() do table.insert(out, 1, e.display) end
    out[#out + 1] = UNKNOWN_EXP
    return out
end

local function _menuHead(allKey, headKey)
    return {
        { kind = "checkbox", isAll = true, value = "all", text = L(allKey) },
        { kind = "divider" },
        { kind = "title", text = L(headKey), right = L("DQ_HEAD_DECOR") },
    }
end

local function _menuItem(value, text, n)
    return { kind = "checkbox", value = value, text = text, right = tostring(n) }
end

Selectors:Register("decorQuests.expMenuItems", {
    calls = { "decorQuests.axisCounts" },
    fn = function(state, ctx)
        local counts, out = Selectors:Call("decorQuests.axisCounts", state, ctx).exp, _menuHead("RS_ALL_EXPANSIONS", "RS_HEAD_EXP")
        for _, exp in ipairs(_expOrder()) do
            local color = HDG.Expansion.GetColorHex(exp) or ""   -- exception(nullable): Unknown has no brand color
            if counts[exp] then out[#out + 1] = _menuItem(exp, color .. _expLabel(exp) .. "|r", counts[exp]) end
        end
        return out
    end,
})

Selectors:Register("decorQuests.kindMenuItems", {
    calls = { "decorQuests.axisCounts" },
    fn = function(state, ctx)
        local counts, out = Selectors:Call("decorQuests.axisCounts", state, ctx).kind, _menuHead("DQ_ALL_KINDS", "DQ_HEAD_KIND")
        for _, kind in ipairs(KIND_ORDER) do
            if counts[kind] then out[#out + 1] = _menuItem(kind, _kindLabel(kind), counts[kind]) end
        end
        return out
    end,
})

-- Reset clears the two menus (the mockup's), so it shows while either has a value.
Selectors:Register("decorQuests.anyMenuFilter", {
    reads = { UI_PATH .. ".expFilter", UI_PATH .. ".kindFilter" },
    fn = function(state)
        local ui = state.session.ui.decorQuests
        return next(ui.expFilter) ~= nil or next(ui.kindFilter) ~= nil
    end,
})

-- ============================================================================
-- List rows: grouped by expansion, the treasure hunts in a group of their own
-- ============================================================================

local function _groupKey(m)
    if m.repeats then return Repeats.GROUP end
    if m.kind == TREASURE_GROUP then return TREASURE_GROUP end
    return "E:" .. m.exps[1]
end

local GROUP_ORDER = { Repeats.GROUP }   -- first (owner 10-29)
for _, exp in ipairs(_expOrder()) do GROUP_ORDER[#GROUP_ORDER + 1] = "E:" .. exp end
GROUP_ORDER[#GROUP_ORDER + 1] = TREASURE_GROUP

-- [group key] = { done, mine, collected } over every decor this character can do, for
-- the group headers ("x/y done - z collected": the quest done by the warband, collected
-- or not, and collected on its own), whatever the filters.
Selectors:Register("decorQuests.groupStats", {
    memoized = true,
    reads = { "account.collection.ownedDecorIDs" },
    calls = { "decorQuests.models", "decorQuests.progress" },
    fn = function(state, ctx)
        local P, owned, out = Selectors:Call("decorQuests.progress", state, ctx), state.account.collection.ownedDecorIDs, {}
        for _, m in ipairs(Selectors:Call("decorQuests.models", state, ctx).list) do
            local g = out[_groupKey(m)] or { done = 0, mine = 0, collected = 0 }
            out[_groupKey(m)] = g
            if not m.other then
                g.mine = g.mine + 1
                if _questDone(P.state[m.decorID]) then g.done = g.done + 1 end
                if owned[m.decorID] then g.collected = g.collected + 1 end
            end
        end
        return out
    end,
})

-- ----- List row reuse (as Recipe Sources: one table per row key, restamped) -----
Selectors:Register("decorQuests._rowCache", {
    memoized = true,
    reads = {},
    fn = function() return {} end,
})

local function _rowFor(cache, key)
    local row = cache[key]
    if not row then
        row = {}
        cache[key] = row
    end
    _put(row, "selected", nil)
    return row
end

-- A one-quest decor in progress has its quest in the log: there are no steps to count.
local function _stateText(m, P)
    local s, n = P.state[m.decorID], #P.steps[m.decorID]
    if s == "other" then return _onlyText(m) end
    if m.repeats then return Repeats.stateText(m, P) end
    if s == "done" then return L("DQ_STATE_DONE") end
    if s == "missing" then return L("DQ_STATE_MISSING") end
    if n == 1 then return L(s == "progress" and "DQ_IN_LOG" or "DQ_STATE_NOT_DONE") end
    if s == "progress" then return L("DQ_STATE_PROGRESS"):format(P.nDone[m.decorID], n) end
    return L("DQ_STATE_STEPS"):format(n)
end

-- The detail's quest row: in the log, or Repeatable (the info row counts the copies).
function Repeats.questText(m, P)
    if not m.repeats or P.state[m.decorID] == "progress" then return _stateText(m, P) end
    return L("DQ_KIND_REPEATABLE")
end

-- The quest's title in the client's language: the catalog's own "Quest:" line when the
-- row has one, else the game's quest cache, else the index's enUS name (the game can
-- refuse to load any quest, and which ones moves from day to day), else its number.
local function _questTitle(q, catalogName)
    return catalogName or HDG.QuestNameResolver:GetTitle(q) or HDG.StaticData.DecorQuests:Title(q)   -- exception(nullable): uncached until QUEST_TITLES_RESOLVED; a quest the index does not ship has no name
        or L("DQ_QUEST_N"):format(q)
end

-- Line 2: "<line> - <zone>" for a chain, "<quest> - <zone>" for the rest.
local function _whereText(m)
    local what = m.lineName or _questTitle(m.q, m.questName)   -- exception(optional): solo decor have no line
    local zone = _zoneName(m.map)
    if not zone or zone == what then return what end   -- exception(nullable): no map, no zone; a line named after its zone says it once (review C8)
    return what .. " - " .. zone
end

local function _decorRow(cache, m, P, owned)
    local row, d = _rowFor(cache, "d:" .. m.decorID), m.decorID
    row.kind, row.decorID, row.itemID, row.name, row.icon = "decor", d, m.itemID, m.name, m.icon
    row.state, row.stateText, row.chipKind, row.chipLabel = P.state[d], _stateText(m, P), m.kind, _kindLabel(m.kind)
    row.where, row.got, row.other = _whereText(m), owned[d] == true and P.state[d] ~= "done", m.other
    if m.repeats then   -- the copies in the state's place, the Repeatable chip in the kind's
        row.state, row.got, row.chipKind, row.chipLabel = Repeats.rowState(m, P), false, "repeatable", _kindLabel("repeatable")
    end
    _put(row, "badge", m.other and m.side or nil)   -- exception(optional): only other-faction decor carry a badge
    local showBar = not m.other and #P.steps[d] > 1
    _put(row, "frac", showBar and (_questDone(P.state[d]) and 1 or P.nDone[d] / #P.steps[d]) or nil)
    return row
end

local function _groupRow(cache, key, shown, stat, collapsed)
    local row = _rowFor(cache, key)
    row.kind, row.key, row.collapsed = "group", key, collapsed
    local exp = key:match("^E:(.+)$")
    row.label = exp and _expLabel(exp) or L(key == Repeats.GROUP and "DQ_GROUP_REPEATABLE" or "DQ_GROUP_TREASURE")
    _put(row, "color", exp and HDG.Expansion.GetColorHex(exp) or nil)   -- exception(nullable): Unknown, the hunts and the repeatables have no brand color
    if key == Repeats.GROUP then
        row.count = L("DQ_GROUP_REPEAT_COUNT"):format(shown)   -- never done: no done split
    elseif stat.collected == stat.done then
        row.count = L("DQ_GROUP_COUNT_SAME"):format(shown, stat.done, stat.mine)   -- the split only when they differ
    else
        row.count = L("DQ_GROUP_COUNT"):format(shown, stat.done, stat.mine, stat.collected)
    end
    return row
end

-- Other-faction decor last (as other-faction vendors), then by name.
local function _rowOrder(a, b)
    if a.other ~= b.other then return b.other end
    return _byName(a, b)
end

local function _grouped(list)
    local groups = {}
    for _, m in ipairs(list) do
        local g = _groupKey(m)
        groups[g] = groups[g] or {}
        table.insert(groups[g], m)
    end
    for _, ms in pairs(groups) do table.sort(ms, _rowOrder) end
    return groups
end

Selectors:Register("decorQuests.listRows", {
    memoized = true,
    reads = { UI_PATH .. ".collapsed", "account.collection.ownedDecorIDs", "session.resolvers.questTitles.tick" },
    calls = { "decorQuests.filtered", "decorQuests.progress", "decorQuests.groupStats", "decorQuests._rowCache" },
    fn = function(state, ctx)
        local cache, P = Selectors:Call("decorQuests._rowCache", state, ctx), Selectors:Call("decorQuests.progress", state, ctx)
        local stats, owned = Selectors:Call("decorQuests.groupStats", state, ctx), state.account.collection.ownedDecorIDs
        local collapsed, out = state.session.ui.decorQuests.collapsed, {}
        local groups = _grouped(Selectors:Call("decorQuests.filtered", state, ctx))
        for _, key in ipairs(GROUP_ORDER) do
            local ms = groups[key]
            if ms then
                out[#out + 1] = _groupRow(cache, key, #ms, stats[key], collapsed[key] == true)
                if not collapsed[key] then
                    for _, m in ipairs(ms) do out[#out + 1] = _decorRow(cache, m, P, owned) end
                end
            end
        end
        return out
    end,
})

-- ============================================================================
-- List rows, By Chain: chains grouped by expansion, then the lone quests and the
-- treasure hunts as decor rows
-- ============================================================================
-- A chain is listed when any of its decor passes the filters; its row reads all of them.
-- Group keys are the view's own ("C:<expansion>", "single"), so folding one view's group
-- leaves the other's alone; the treasure hunts share theirs.
local SINGLE_GROUP = "single"

local CHAIN_GROUP_ORDER = { Repeats.GROUP }
for _, exp in ipairs(_expOrder()) do CHAIN_GROUP_ORDER[#CHAIN_GROUP_ORDER + 1] = "C:" .. exp end
CHAIN_GROUP_ORDER[#CHAIN_GROUP_ORDER + 1] = SINGLE_GROUP
CHAIN_GROUP_ORDER[#CHAIN_GROUP_ORDER + 1] = TREASURE_GROUP

-- The chain list's own row tables: the lone quests and the hunts sit in both lists, and
-- one table restamped for two scrollboxes would carry one list's selection into the other.
Selectors:Register("decorQuests._chainRowCache", {
    memoized = true,
    reads = {},
    fn = function() return {} end,
})

-- groups[key] = { chain entries } for an expansion group, { models } for the other two.
local function _chainGroups(list, chains)
    local groups, seen = {}, {}
    for _, m in ipairs(list) do
        local g, item = (m.repeats and Repeats.GROUP) or (m.kind == TREASURE_GROUP and TREASURE_GROUP) or SINGLE_GROUP, m
        if m.chainKey then g, item = "C:" .. chains[m.chainKey].exps[1], chains[m.chainKey] end
        if not seen[item] then
            seen[item] = true
            groups[g] = groups[g] or {}
            table.insert(groups[g], item)
        end
    end
    return groups
end

local function _chainOrder(a, b)
    local ao, bo = a.state == "other", b.state == "other"
    if ao ~= bo then return bo end
    return a.name < b.name
end

local function _chainStateText(e)
    if e.state == "done" then return L("DQ_STATE_DONE") end
    if e.state == "missing" then return L("DQ_STATE_MISSING") end
    if e.state == "other" then return _onlyText(e.ms[1]) end
    if e.nDone > 0 then return L("DQ_CHAIN_PROGRESS"):format(e.nDone, e.n, L(e.unit)) end
    return L("DQ_CHAIN_COUNT"):format(e.n, L(e.unit))
end

-- Line 2: "<n> decor - <zone>", a campaign's "<n> decor - campaign".
local function _chainWhere(e)
    local where = e.campaign and L("DQ_WHERE_CAMPAIGN") or _zoneName(e.far.map)
    if not where or where == e.name then return L("DQ_CHAIN_DECOR"):format(#e.ms) end   -- exception(nullable): a decor quest with no map names no zone; a line named after its zone says it once (review C8)
    return L("DQ_CHAIN_WHERE"):format(#e.ms, where)
end

local function _chainRow(cache, e)
    local row = _rowFor(cache, e.key)
    row.kind, row.key, row.name, row.icons = "chain", e.key, e.name, e.icons
    row.state, row.stateText, row.where, row.other = e.state, _chainStateText(e), _chainWhere(e), e.state == "other"
    _put(row, "frac", not row.other and (_questDone(e.state) and 1 or e.nDone / e.n) or nil)   -- exception(optional): the other faction's chains carry no bar
    return row
end

local function _chainGroupRow(cache, key, n, collapsed)
    local row = _rowFor(cache, key)
    row.kind, row.key, row.collapsed = "group", key, collapsed
    local exp = key:match("^C:(.+)$")
    row.label = exp and _expLabel(exp)
        or L((key == SINGLE_GROUP and "DQ_GROUP_SINGLE") or (key == Repeats.GROUP and "DQ_GROUP_REPEATABLE") or "DQ_GROUP_TREASURE")
    _put(row, "color", exp and HDG.Expansion.GetColorHex(exp) or nil)   -- exception(nullable): Unknown and the two quest groups have no brand color
    if exp then
        row.count = n == 1 and L("DQ_GROUP_CHAIN") or L("DQ_GROUP_CHAINS"):format(n)
    elseif key == Repeats.GROUP then
        row.count = L("DQ_GROUP_REPEAT_COUNT"):format(n)
    else
        row.count = L("DQ_GROUP_NO_CHAIN"):format(n)
    end
    return row
end

local function _chainGroupItems(out, cache, key, items, ctx)
    if key:find("^C:") then
        table.sort(items, _chainOrder)
        for _, e in ipairs(items) do out[#out + 1] = _chainRow(cache, e) end
        return
    end
    table.sort(items, _rowOrder)
    for _, m in ipairs(items) do out[#out + 1] = _decorRow(cache, m, ctx.P, ctx.owned) end
end

Selectors:Register("decorQuests.chainRows", {
    memoized = true,
    reads = { UI_PATH .. ".collapsed", "account.collection.ownedDecorIDs", "session.resolvers.questTitles.tick" },
    calls = { "decorQuests.filtered", "decorQuests.progress", "decorQuests.chains", "decorQuests._chainRowCache" },
    fn = function(state, ctx)
        local cache = Selectors:Call("decorQuests._chainRowCache", state, ctx)
        local rctx = { P = Selectors:Call("decorQuests.progress", state, ctx), owned = state.account.collection.ownedDecorIDs }
        local collapsed, out = state.session.ui.decorQuests.collapsed, {}
        local groups = _chainGroups(Selectors:Call("decorQuests.filtered", state, ctx), Selectors:Call("decorQuests.chains", state, ctx))
        for _, key in ipairs(CHAIN_GROUP_ORDER) do
            local items = groups[key]
            if items then
                out[#out + 1] = _chainGroupRow(cache, key, #items, collapsed[key] == true)
                if not collapsed[key] then _chainGroupItems(out, cache, key, items, rctx) end
            end
        end
        return out
    end,
})

-- ============================================================================
-- Detail
-- ============================================================================
-- One key selects in both lists (session.ui.decorQuests.selected): a decor's detail
-- shows in either view, a chain's or a campaign's only By Chain.

Selectors:Register("decorQuests.selected", {
    reads = { UI_PATH .. ".selected" },
    calls = { "decorQuests.models" },
    fn = function(state, ctx)
        local key = state.session.ui.decorQuests.selected
        local id = key and tonumber(key:match("^d:(%d+)$"))   -- exception(nullable): nothing selected, or a chain
        if not id then return nil end
        return Selectors:Call("decorQuests.models", state, ctx).byDecor[id]   -- exception(nullable): a selection the last sweep dropped
    end,
})

Selectors:Register("decorQuests.selectedChain", {
    reads = { UI_PATH .. ".selected" },
    calls = { "decorQuests.viewMode", "decorQuests.chains" },
    fn = function(state, ctx)
        local key = state.session.ui.decorQuests.selected
        if key == nil or Selectors:Call("decorQuests.viewMode", state, ctx) ~= "chain" then return nil end
        return Selectors:Call("decorQuests.chains", state, ctx)[key]   -- exception(nullable): a decor's key, or a chain the last sweep dropped
    end,
})

Selectors:Register("decorQuests.detailTitle", {
    calls = { "decorQuests.selectedChain", "decorQuests.selected", "decorQuests.viewMode" },
    fn = function(state, ctx)
        local e = Selectors:Call("decorQuests.selectedChain", state, ctx)
        if e then return e.name end
        local m = Selectors:Call("decorQuests.selected", state, ctx)
        if m then return m.name end
        return L(Selectors:Call("decorQuests.viewMode", state, ctx) == "chain" and "DQ_SELECT_CHAIN" or "DQ_SELECT_DECOR")
    end,
})

Selectors:Register("decorQuests.detailExpansion", {
    calls = { "decorQuests.selectedChain", "decorQuests.selected" },
    fn = function(state, ctx)
        local sel = Selectors:Call("decorQuests.selectedChain", state, ctx) or Selectors:Call("decorQuests.selected", state, ctx)   -- exception(nullable): a chain, else a decor, else nothing selected
        if not sel then return "" end
        return _coloredExps(sel.exps)
    end,
})

-- Rows: info, note, section, bar, step (box = "mid" / "last" in an any-order box), boxHead,
-- fold, quest, blank, and By Chain's decorLine, part, chapter. A note's `tone` picks its color in the row factory (text / dim / warn);
-- `lines` sizes it for wrapped text.
local NOTE_CHARS_PER_LINE = 72   -- caption characters across the detail panel's width
local NEXT_SHOWN = 4             -- the step to head for and the three after it always show
local FOLD_MIN = 3               -- a run of this many like steps folds to one line

-- An inline icon's markup sizes as two characters. lead: a line in the text colour over the
-- rest (the progress note's status, review C5).
local function _note(key, text, tone, lead)
    local visible = text:gsub("|A.-|a", "  ")
    local lines = math.ceil(#visible / NOTE_CHARS_PER_LINE)
    if lead then lines = lines + math.ceil(#lead / NOTE_CHARS_PER_LINE) end   -- exception(optional): only the progress note leads with its status
    return { kind = "note", key = key, text = text, tone = tone, lead = lead, lines = math.max(1, lines) }
end

-- A daily may not be up today (a giver can offer one of several a day); a missive starts from one
-- bought at the garrison; a repeatable is up as often as you like.
function Repeats.note(m)
    return _note("repeat", L(Repeats.NOTE[m.repeats]), "dim")
end

-- Collected, firstBy = the first character the account recorded finishing the decor quest,
-- under the variant shown or a twin: { name, class (a classFile) }, or nil. (Inline: the
-- file is at Lua's 200-local cap.)
local function _infoRow(m, P, ctx)
    local row = { kind = "info", key = "info", decorID = m.decorID, itemID = m.itemID, icon = m.icon, name = m.name,
                  zone = _zoneName(m.map) or "", chipKind = m.kind, chipLabel = _kindLabel(m.kind),   -- exception(nullable): a quest with no map names no zone
                  state = P.state[m.decorID], stateText = _stateText(m, P),
                  collected = ctx.owned[m.decorID] == true }
    if m.repeats then   -- "You have N" says the copies; its quest flag resets, so no first done by
        row.state, row.collected, row.chipKind, row.chipLabel = Repeats.rowState(m, P), false, "repeatable", _kindLabel("repeatable")
    elseif row.collected then
        row.firstBy = ctx.completions[m.q]
        for _, id in ipairs(m.twins or {}) do row.firstBy = row.firstBy or ctx.completions[id] end   -- exception(optional): most decor quests have no twin
    end
    if not m.repeats and _questDone(row.state) then   -- done: the zone line names the quest that unlocked it (owner 10-30)
        local by = L("DQ_UNLOCKED_BY"):format(_questTitle(m.q, m.questName))
        row.zone = row.zone == "" and by or by .. " - " .. row.zone
    end
    return row
end

local function _otherNote(m)
    local key = (m.whyBefore and "DQ_OTHER_BEFORE" or "DQ_OTHER_QUEST") .. (m.whoNot and "_NOT" or "")
    return _note("other", L(key):format(m.who), "dim")
end

-- ----- The ladder: this character's steps of a line -----
-- Only the steps this character can take (ruling 10-26: respect factions, and the
-- class-only copies), numbered by their place among them; a decor's are pickable (any
-- of them). Runs of FOLD_MIN+ like steps away from the step to head for and the reward
-- steps fold to one line until opened. A ladder's subject:
--   key      fold-key root: the decor's ID, "k<lineID>" for a chapter
--   prefix   step row-key root: "s:" for the one decor ladder a detail shows,
--            "k<lineID>:" for a chapter's (a decor's detail can show both)
--   decor    the decor the ladder heads for: its quest's step reads the warband answer
--            (absent on a chapter's)
--   lineID   the line (the step to head for names its giver)
--   pickKey  what a click picks ("d:<decorID>"; absent on the card's chapters, which
--            pick nothing); tracked = the tracker follows it, so a pick is saved with it;
--            finished = this character did the decor quest (a done step can be picked)
--   last     the last step shown: the decor quest's, a chapter's whole line
--   cur      the step to head for (0 = none)
--   rewards  [questID] = { models }: the decor each step's quest rewards

local function _addReward(rewards, m)
    rewards[m.q] = rewards[m.q] or {}
    table.insert(rewards[m.q], m)
end

local function _decorSubject(m, ctx, rewards)
    local pickKey = "d:" .. m.decorID
    return { key = m.decorID, prefix = "s:", decor = m, lineID = m.lineID, last = m.at, pickKey = pickKey,
             tracked = ctx.tracked ~= nil and ctx.tracked.key == pickKey, finished = ctx.P.here[m.decorID] == true,
             cur = ctx.P.cur[m.decorID] or 0, rewards = rewards }   -- exception(nullable): other-faction decor have no step to head for
end

-- A step's category: "done" (this character), "warband" (only another character of
-- the warband) or "todo". The decor quest reads the progress layer's answer, which
-- counts its twins and every faction's copy.
local function _decorStepCat(m, ctx)
    if ctx.P.here[m.decorID] then return "done" end
    if _questDone(ctx.P.state[m.decorID]) then return "warband" end
    return "todo"
end

local function _stepCat(sub, i, q, ctx)
    if sub.decor and i == sub.decor.at then return _decorStepCat(sub.decor, ctx) end
    if HDG.QuestNameResolver:IsComplete(q) then return "done" end
    if HDG.QuestNameResolver:IsCompleteOnAccount(q) then return "warband" end
    return "todo"
end

-- The steps, in order: i = the step's place in the line (row keys, the reward), num =
-- its place in this character's ladder, leadIn = a breadcrumb (an optional lead-in),
-- grp = its any-order group on the line (nil for most).
local function _ladderSteps(sub, line, ctx)
    local out, at = {}, sub.decor and sub.decor.at   -- exception(optional): a chapter's ladder heads for no decor
    for i = 1, sub.last do
        if i == at or _takes(line, i, ctx.me) then
            local s = { i = i, q = line.q[i], map = HDG.StaticData.DecorQuests:StepMap(line, i, ctx.me.side), num = #out + 1,
                        leadIn = line.bc ~= nil and line.bc[i] ~= nil,   -- exception(optional): few lines hold a breadcrumb
                        grp = line.grp and line.grp[i] }                 -- exception(optional): few lines hold an any-order group
            s.cat = _stepCat(sub, i, s.q, ctx)
            out[s.num] = s
        end
    end
    return out
end

-- Which steps never fold: the last, every reward step, and the NEXT_SHOWN from the step
-- to head for.
local function _keepSet(steps, sub)
    local keep = { [#steps] = true }
    for num, s in ipairs(steps) do
        if sub.rewards[s.q] then keep[num] = true end
    end
    if sub.cur == 0 then return keep end
    for num = sub.cur, math.min(#steps, sub.cur + NEXT_SHOWN - 1) do keep[num] = true end
    return keep
end

-- A reward step names each decor it gives, and which are collected.
local function _rewardTexts(ms, ctx)
    local out = {}
    for i, m in ipairs(ms) do
        local got = ctx.owned[m.decorID] == true
        out[i] = { text = L(got and "DQ_REWARDS_COLLECTED" or "DQ_REWARDS"):format(m.name), got = got,   -- gold until collected (review C2)
                   icon = m.icon or HDG.Constants.PLACEHOLDER_ICON }   -- exception(nullable): a catalog row the client sent no icon for
    end
    return out
end

-- Who starts step q, for the "!" of a who line (Place.who): the NPC once the game has the name
-- (NPCNameResolver; nil until then; "(follows you)" for an escort), the object or item the
-- index names; with nobody, how it starts where Wowhead's comments say (the Scouting Map, on
-- its own), else nil. A missive quest starts from the Scouting Missive its NPC sells (the
-- Full mockup).
local function _giverText(start, q)
    if start.npcID then
        local name = HDG.NPCNameResolver:ResolveName(start.npcID, nil)
        if not name then return nil end   -- exception(nullable): the name is not in yet
        local key = (HDG.StaticData.DecorQuests:Follows(q, "start") and "GIVER_FOLLOWS")
            or (HDG.StaticData.DecorQuests:Repeat(q) == "missive" and "GIVER_MISSIVE") or "GIVER"
        return L("DQ_TRK_" .. key):format(name)
    end
    if start.object then return L("DQ_TRK_STARTS_AT"):format(start.object) end
    if start.item then return L("DQ_TRK_STARTS_ITEM"):format(start.item) end
    local how = HDG.StaticData.DecorQuests:StartHow(q)
    return how and L("DQ_TRK_STARTS_" .. how:upper())   -- exception(nullable): nobody says how it starts
end

-- Where to go for a quest: Blizzard's quest arrow while it is in the log, else a waypoint at
-- the spot it starts at; nil with neither. { text, enabled, title, questID | map + x + y }.
-- Every step's own Wpt, the Next block's button and the tracker's take it from here.
local function _questWay(inLog, q, start, title)
    if inLog then return { text = L("DQ_TRK_WAY_ARROW"), enabled = true, questID = q, title = title } end
    if not (start and start.x) then return nil end   -- exception(nullable): a quest the index does not ship, or a step with no known spot
    return { text = L("DQ_TRK_WAY"), enabled = true, map = start.map, x = start.x, y = start.y, title = title }
end

-- Where a step starts: { map, x, y, npcID }, or nil for a catalog quest the index does not ship.
local function _startOf(lad, s, side)
    if lad.lineID then return HDG.StaticData.DecorQuests:StepStart(lad.lineID, s.i, side) end
    return HDG.StaticData.DecorQuests:SoloStart(s.q, side)
end

-- Any step but the current one is picked -- a done one only once the chain is finished here
-- (_openFrom). Every step's line says who starts it and who takes it back, as the tracker's
-- place line does (Place.ladderWho, Bold B), and one not done here has its own way there
-- (way: the giver's spot, or the quest arrow once it is in the log), in any order.
local function _stepRow(sub, s, ctx)
    local isCur, ms = s.num == sub.cur, sub.rewards[s.q]
    local inLog = s.cat ~= "done" and HDG.QuestNameResolver:IsOnQuest(s.q)
    local row = { kind = "step", key = sub.prefix .. s.i, num = s.num, cat = s.cat, leadIn = s.leadIn,
                  title = _questTitle(s.q, ms and ms[1].questName), isCur = isCur, inLog = inLog,   -- exception(optional): only a decor quest has a catalog name
                  rewards = ms and _rewardTexts(ms, ctx) }   -- exception(optional): most steps reward no decor
    row.who, row.whoLines = Place.ladderWho(sub, s, ctx.me.side, inLog)
    if s.cat ~= "done" then row.way = _questWay(inLog, s.q, _startOf(sub, s, ctx.me.side), row.title) end
    if sub.pickKey and not isCur and (sub.finished or s.cat ~= "done") then
        row.pickKey, row.pick, row.tracked = sub.pickKey, s.q, sub.tracked
    end
    return row
end

local FOLD_TEXT = { done = "DQ_FOLD_DONE", warband = "DQ_FOLD_WARBAND", todo = "DQ_FOLD_TODO" }

local function _foldRow(sub, run, cat)
    local first, last = run[1], run[#run]
    local key = sub.key .. ":" .. first.i
    return { kind = "fold", key = "f:" .. key, foldKey = key, text = L(FOLD_TEXT[cat]):format(first.num, last.num, #run) }
end

-- The run of like, unkept steps starting at i: its steps and the index after it.
local function _runFrom(steps, i, keep)
    local cat, run = steps[i].cat, {}
    local j = i
    while j <= #steps and not keep[j] and steps[j].cat == cat do
        run[#run + 1] = steps[j]
        j = j + 1
    end
    return run, j
end

-- ----- Any-order boxes (ruling G, owner 2026-10-27) -----
-- A box is a group's steps this character takes, two or more: the game hands them out
-- together. The build ships a group only where its steps sit together on the line.

-- [num] = { first, last } for each step of a box in the ladder.
function Groups.boxes(steps)
    local out, at = {}, {}
    for num, s in ipairs(steps) do
        if s.grp then
            local b = at[s.grp] or { first = num }   -- exception(nullable): the group's first step
            b.last, at[s.grp], out[num] = num, b, b
        end
    end
    for num, b in pairs(out) do
        if b.first == b.last then out[num] = nil end
    end
    return out
end

-- A box would split across a fold: one of its steps is kept, or its steps differ in state.
function Groups.splits(keep, steps, b)
    for k = b.first, b.last do
        if keep[k] or steps[k].cat ~= steps[b.first].cat then return true end
    end
    return false
end

-- A box folds whole or not at all.
function Groups.keepWhole(keep, steps, boxes)
    for num, b in pairs(boxes) do
        if num == b.first and Groups.splits(keep, steps, b) then
            for k = b.first, b.last do keep[k] = true end
        end
    end
end

-- A step's row; the first of a box gets the box's head ("Complete these (6-7)") before it.
-- A box is on (accent) only while the step to head for is in it (ruling R6, review C4).
local function _emitStep(out, sub, s, ctx, boxes)
    local b = boxes[s.num]
    local on = b and sub.cur >= b.first and sub.cur <= b.last
    if b and b.first == s.num then
        out[#out + 1] = { kind = "boxHead", key = sub.prefix .. "box" .. s.i, text = L("DQ_BOX_HEAD"):format(b.first, b.last), on = on }
    end
    local row = _stepRow(sub, s, ctx)
    if b then row.box, row.boxOn = (s.num == b.last) and "last" or "mid", on end
    out[#out + 1] = row
end

local function _emitRun(out, sub, run, ctx, boxes)
    local open = ctx.openFolds[sub.key .. ":" .. run[1].i]
    if #run >= FOLD_MIN and not open then
        out[#out + 1] = _foldRow(sub, run, run[1].cat)
        return
    end
    for _, s in ipairs(run) do _emitStep(out, sub, s, ctx, boxes) end
end

local function _ladderRows(out, sub, steps, ctx)
    local keep, boxes, i = _keepSet(steps, sub), Groups.boxes(steps), 1
    Groups.keepWhole(keep, steps, boxes)
    while i <= #steps do
        if keep[i] then
            _emitStep(out, sub, steps[i], ctx, boxes)
            i = i + 1
        else
            local run, j = _runFrom(steps, i, keep)
            _emitRun(out, sub, run, ctx, boxes)
            i = j
        end
    end
end

-- ----- A ladder as the tracker reads it, and the Waypoint to its step -----
-- lad = { pickKey, steps, cur, nDone, done, here, lineID, m, rwAt } (the tracker's, see
-- there). The detail's Next block reads a decor's the same way, so both point at one spot.

-- A decor's ladder: its line's steps up to the decor quest, or the lone quest.
local function _decorTrackLadder(m, ctx)
    local d, steps = m.decorID, nil
    if m.lineID then
        steps = _ladderSteps({ decor = m, last = m.at }, HDG.StaticData.DecorQuests:Line(m.lineID), ctx)
    else
        local q = (m.repeats and Repeats.logged(m)) or m.q   -- a repeatable: the twin in the log, its arrow
        steps = { { i = 1, q = q, map = m.map, num = 1, cat = _decorStepCat(m, ctx) } }
    end
    return { pickKey = "d:" .. d, steps = steps, cur = ctx.P.cur[d], nDone = ctx.P.nDone[d],
             done = _questDone(ctx.P.state[d]), here = ctx.P.here[d], lineID = m.lineID, m = m, rwAt = #steps }
end

local function _stepTitleOf(lad, s)
    return _questTitle(s.q, s.num == lad.rwAt and lad.m.questName or nil)   -- exception(optional): only a decor quest has a catalog name
end

-- The step to head for (_questWay): greyed when no spot is known, its tip saying so (why) --
-- for a step the game hands out, where it does (ruling C). num: the step's, for the Map's pin
-- (the tracker's disc, owner 10-29).
local function _stepWay(lad, side)
    local s = lad.steps[lad.cur]
    local inLog = s.cat ~= "done" and HDG.QuestNameResolver:IsOnQuest(s.q)
    local title, start = _stepTitleOf(lad, s), _startOf(lad, s, side)
    local way = _questWay(inLog, s.q, start, title)
    if not way then   -- exception(nullable): a quest the index does not ship, or a step with no known spot
        local zone = start and HDG.StaticData.DecorQuests:GameGives(start, s.q) and _zoneName(s.map)   -- exception(nullable): a quest the index does not ship; a map with no zone
        local why = zone and L("DQ_TRK_GIVEN_REACH"):format(title, zone) or L("DQ_TRK_NO_SPOT"):format(title)
        return { text = L("DQ_TRK_WAY"), enabled = false, why = why }
    end
    way.num = s.num
    return way
end

-- ----- Track buttons -----
-- A button's { key, quest, on, rows, again }: what Track follows ("d:<decorID>" |
-- "k:<lineID>" | "camp:<id>"), the quest it pins (the step the ladder heads for; the first on
-- a done one, followed again from the start; nil for a campaign, which follows the chapter the
-- player is on), whether it is the tracked one, the decor it saves (_trackRow), and (a
-- decor's) whether its quest is done, so Track follows it again.

-- What Track saves of a decor: the catalog row's fields _buildModel reads, and the vendor
-- the tracker names once the quest is done and the decor is not in the collection. The
-- tracker builds its target from these, so it works before the catalog loads (with the
-- main window; the tracker can be up at login without it).
local function _trackRow(decorID, side)
    local row = HDG.HousingCatalogObserver.byDecorID[decorID]
    local v = row.vendors and HDG.VendorRank.MapVendor(row.vendors, side)   -- exception(optional): a decor no vendor sells
    return { decorID = row.decorID, itemID = row.itemID, name = row.name, iconTexture = row.iconTexture,
             expansion = row.expansion, questID = row.questID, quest = row.quest,
             vendor = v and { name = v.name, zone = v.zone, mapID = v.mapID, x = v.x, y = v.y, side = v.side } }
end

local function _trackButton(key, quest, decorIDs, ctx)
    local rows = {}
    for i, d in ipairs(decorIDs) do rows[i] = _trackRow(d, ctx.me.side) end
    -- Its tooltip: a campaign's says the game picks the chapter, a chapter's that it follows
    -- that one (review F6).
    local tip = key:find("^camp:") and L("DQ_TRACK_CAMP_TIP"):format(ctx.chains[key].name)
                or L(key:find("^k:") and "DQ_TRACK_CHAPTER_TIP" or "DQ_TRACK_TIP")
    return { key = key, quest = quest, on = ctx.tracked ~= nil and ctx.tracked.key == key, rows = rows, tip = tip }
end

-- The decorIDs of the models this character can take.
local function _mineIDs(ms)
    local out = {}
    for _, m in ipairs(ms) do
        if not m.other then out[#out + 1] = m.decorID end
    end
    return out
end

local function _catDone(steps, i) return steps[i].cat == "done" end
function Groups.ofStep(steps, i) return steps[i].grp end

-- A ladder's step records (the tracker's and a chapter's): subject = the steps.
Pick.STEPS = { questAt = function(steps, i) return steps[i].q end, groupAt = Groups.ofStep, isDone = _catDone }

-- The watcher's turn-in heads for the same any-order group's open step (DecorQuestWatcher).
HDG.DecorQuestGroups = {
    PartnerOf = function(steps, i) return Groups.partner(#steps, i, Groups.ofStep, _catDone, steps) end,
}

-- A chapter's steps on this character and the step it heads for: the pick (Pick.headFor),
-- else the open step of the last done one's any-order group (Groups.partner), else the one
-- after the last done -- the first not done when the last is -- else none (0: done).
-- Also nDone and done.
local function _chapterSteps(lineID, ctx)
    local line = HDG.StaticData.DecorQuests:Line(lineID)
    local steps = _ladderSteps({ last = line.n }, line, ctx)
    local n, nDone, lastDone = #steps, 0, 0
    for _, st in ipairs(steps) do
        if st.cat == "done" then nDone, lastDone = nDone + 1, st.num end
    end
    local pick, done = Pick.of("k:" .. lineID, ctx.picks, ctx.tracked), nDone == n
    local cur = done and 0 or (lastDone > 0 and Groups.partner(n, lastDone, Groups.ofStep, _catDone, steps))
        or _openFrom(lastDone < n and lastDone + 1 or 1, n, _catDone, steps)
    if pick then cur = Pick.headFor(pick, n, done, Pick.STEPS, steps) or cur end
    return steps, cur, nDone, done
end

-- ----- A decor's progress: the bar and the note over its ladder -----

local function _progressText(m, cur, P)
    local d = m.decorID
    if _questDone(P.state[d]) and cur == 0 then
        if P.here[d] then return L("DQ_DONE_HERE") end
        return L("DQ_DONE_WARBAND"):format(P.nDone[d], #P.steps[d])
    end
    return L("DQ_PROGRESS_NOTE"):format(P.nDone[d], #P.steps[d], P.left[d])
end

-- Where you stand, then how to use the ladder; and what the warband mark means when the
-- ladder shows one.
local function _progressNote(m, sub, steps, ctx)
    local status, hint = _progressText(m, sub.cur, ctx.P), L("DQ_PICK_HINT")
    for _, s in ipairs(steps) do
        if s.cat == "warband" then
            return _note("progress", hint .. L("DQ_WARBAND_MARK"):format(HDG.Constants.DQ_WARBAND_ICON), "dim", status)
        end
    end
    return _note("progress", hint, "dim", status)
end

-- The bar, the note and the ladder of m's line, rewards marked on their steps.
local function _decorLadder(out, m, line, rewards, ctx)
    local sub = _decorSubject(m, ctx, rewards)
    local steps, d = _ladderSteps(sub, line, ctx), m.decorID
    out[#out + 1] = { kind = "bar", key = "bar", frac = _questDone(ctx.P.state[d]) and 1 or ctx.P.nDone[d] / #ctx.P.steps[d] }
    out[#out + 1] = _progressNote(m, sub, steps, ctx)
    _ladderRows(out, sub, steps, ctx)
end

-- ----- The campaign card: every chapter, so the gate that hides a decor quest shows -----
-- A chapter's pie and n/N are this character's steps; its decor read collected.

local function _campaignCounts(e, ctx)
    local mine, got = 0, 0
    for _, m in ipairs(e.ms) do
        if not m.other then
            mine = mine + 1
            if ctx.owned[m.decorID] then got = got + 1 end
        end
    end
    return mine, got
end

local function _campaignHead(e, mine, got)
    local sub = L("DQ_CAMPAIGN_SHAPE"):format(e.n, #e.ms)
    if mine > 0 then sub = sub .. " - " .. L("DQ_N_COLLECTED"):format(got) end
    return { kind = "section", key = "camp:head", label = e.name, sub = sub }
end

local function _partRow(e)
    local state = (e.nDone == e.n and "done") or (e.nDone > 0 and "progress") or "new"
    return { kind = "part", key = "camp:part", label = L("DQ_CHAPTERS"),
             sub = L(e.campaign.order == "random" and "DQ_ANY_ORDER" or "DQ_IN_ORDER"),
             state = state, stateText = L("DQ_CHAPTERS_DONE"):format(e.nDone, e.n) }
end

-- The decor a chapter ends: the campaign's decor on that chapter's line.
local function _chapterDecor(e, lineID)
    local out = {}
    for _, m in ipairs(e.ms) do
        if m.lineID == lineID then out[#out + 1] = m end
    end
    return out
end

local function _chips(ms, ctx)
    if #ms == 0 then return nil end
    local out = {}
    for i, m in ipairs(ms) do out[i] = { icon = m.icon, name = m.name, got = ctx.owned[m.decorID] == true } end
    return out
end

-- here: the chapter whose line the selected decor's chain is.
local function _chapterRow(e, ch, ctx, hereLine)
    local lineID, cp = ch[1], ctx.chapters[ch[1]]
    return { kind = "chapter", key = "k:" .. lineID, lineID = lineID, name = ch[2], state = cp.state,
             frac = cp.state == "done" and 1 or cp.n / cp.total, value = L("DQ_FRACTION"):format(cp.n, cp.total),
             here = lineID == hereLine, open = ctx.openChapters[lineID] == true,
             chips = _chips(_chapterDecor(e, lineID), ctx) }
end

-- An opened chapter's quests: its whole line, its decor marked, nothing to pick; Next marked
-- on the chapter the tracker heads for (headsFor), so the tab and the tracker agree (owner
-- 10-29). Its Track saves the campaign's decor, so the tracker finds the chapter's own and
-- the campaign.
local function _chapterLadder(out, e, lineID, ctx, headsFor)
    local line, rewards = HDG.StaticData.DecorQuests:Line(lineID), {}
    local ms = _chapterDecor(e, lineID)
    for _, m in ipairs(ms) do _addReward(rewards, m) end
    local steps, cur, _, done = _chapterSteps(lineID, ctx)
    local track = _trackButton("k:" .. lineID, steps[cur > 0 and cur or 1].q, _mineIDs(e.ms), ctx)
    track.again = done   -- its tooltip says it is followed again
    out[#out + 1] = { kind = "track", key = "kt:" .. lineID, label = L("DQ_TRACK_CHAPTER_LABEL"), track = track }
    local sub = { key = "k" .. lineID, prefix = "k" .. lineID .. ":", lineID = lineID, last = line.n,
                  cur = headsFor and cur or 0, rewards = rewards }
    _ladderRows(out, sub, _ladderSteps(sub, line, ctx), ctx)
end

-- The chapter a campaign's tracker follows: one with a quest in the log, else the half-done
-- one with the fewest steps left, else none (the game has none on offer).
local function _currentChapter(chapters)
    local best, bestLeft
    for _, c in ipairs(chapters) do
        local left = c.cp.total - c.cp.n
        if c.cp.state ~= "done" and c.cp.inLog then return c end
        if c.cp.state ~= "done" and c.cp.n > 0 and (best == nil or left < bestLeft) then best, bestLeft = c, left end
    end
    return best
end

-- Whether campaign e still has decor this character has not done (the tracker follows a
-- chapter until then, _campaignTarget).
local function _campaignOpen(e, ctx)
    for _, m in ipairs(e.ms) do
        if not m.other and not ctx.P.here[m.decorID] then return true end
    end
    return false
end

-- The chapter of campaign e the tracker heads for: the one tracked, or, with the campaign
-- tracked, the one its tracker follows (_currentChapter); nil when it follows neither.
function Pick.trackedLine(e, ctx)
    local key = ctx.tracked and ctx.tracked.key   -- exception(nullable): nothing tracked
    if key ~= e.key then return key and tonumber(key:match("^k:(%d+)$")) end   -- exception(nullable): a decor tracked
    if not _campaignOpen(e, ctx) then return nil end
    local chapters = {}
    for i, ch in ipairs(e.chapters) do chapters[i] = { ch = ch, cp = ctx.chapters[ch[1]] } end
    local cur = _currentChapter(chapters)
    return cur and cur.ch[1]   -- exception(nullable): no chapter on offer
end

local function _campaignRows(out, e, ctx, hereLine)
    local mine, got = _campaignCounts(e, ctx)
    out[#out + 1] = _campaignHead(e, mine, got)
    if mine == 0 then
        local only, side = _onlyText(e.ms[1]), SIDE_NAME[ctx.me.side]   -- exception(nullable): an unaligned character has no side's chapters
        local text = side and L("DQ_CAMPAIGN_NONE_SIDE"):format(only, L(side)) or L("DQ_CAMPAIGN_NONE_HERE"):format(only)
        out[#out + 1] = _note("camp:gate", text, "dim")
        return
    end
    out[#out + 1] = _note("camp:gate", L("DQ_CAMPAIGN_GATE_" .. e.campaign.id:upper()), "dim")
    out[#out + 1] = _partRow(e)
    local trackedLine = Pick.trackedLine(e, ctx)
    for _, ch in ipairs(e.chapters) do
        out[#out + 1] = _chapterRow(e, ch, ctx, hereLine)
        if ctx.openChapters[ch[1]] then _chapterLadder(out, e, ch[1], ctx, ch[1] == trackedLine) end
    end
end

-- ----- A decor's chain -----

-- Counts are this character's steps (total: of the whole line), as the ladder's are.
local function _sectionRow(m, line, total, P)
    local sub = L("DQ_STEP_IS_DECOR"):format(#P.steps[m.decorID])
    if line.n > m.at then sub = sub .. " - " .. L("DQ_LINE_GOES_ON"):format(total) end
    return { kind = "section", key = "section", label = line.name, sub = sub }
end

local function _chainRows(out, m, ctx)
    local line = HDG.StaticData.DecorQuests:Line(m.lineID)
    local total = _lineTotal(line, ctx.me)
    out[#out + 1] = _sectionRow(m, line, total, ctx.P)
    -- A whole zone's storyline is the line's shape (every class's copy counts); the number
    -- shown is this character's, as everywhere else.
    if line.n > HDG.Constants.DQ_WHOLE_ZONE_STEPS then
        out[#out + 1] = _note("wholeZone", L("DQ_WHOLE_ZONE"):format(line.name, total), "warn")
    end
    -- The other faction's decor: no bar and no ladder. Its twin's flags would read that
    -- line's steps as this character's progress (the mockup's rule).
    if m.other then return end
    local rewards = {}
    _addReward(rewards, m)
    _decorLadder(out, m, line, rewards, ctx)
end

-- ----- A decor quest in no line -----

-- A lone quest: who starts it and who takes it back, as a ladder step's line (Place.ladderWho);
-- not done yet, its way there (the giver's spot, or the quest arrow once it is in the log).
local function _soloRows(out, m, ctx)
    out[#out + 1] = { kind = "section", key = "section", label = L("DQ_THE_QUEST"), sub = "" }
    local inLog = HDG.QuestNameResolver:IsOnQuest(m.q)
    local row = { kind = "quest", key = "quest", title = _questTitle(m.q, m.questName),
                  state = ctx.P.state[m.decorID], stateText = Repeats.questText(m, ctx.P),
                  note = m.kind == TREASURE_GROUP and L("DQ_TREASURE_NOTE") or nil }   -- exception(optional): only a treasure hunt carries a note
    row.who, row.whoLines = Place.ladderWho({}, { q = m.q, map = m.map }, ctx.me.side, inLog)
    if not _questDone(ctx.P.state[m.decorID]) then
        row.way = _questWay(inLog, m.q, HDG.StaticData.DecorQuests:SoloStart(m.q, ctx.me.side), row.title)
    end
    out[#out + 1] = row
end

local function _provNote(m)
    return _note("prov", L("DQ_PROV_CHAIN"):format(m.lineID, HDG.StaticData.DecorQuests:Build()), "dim")
end

-- A decor's Track: a campaign's decor follow the campaign (the game picks which chapter
-- comes next, so the decor's own may not be on offer); the other faction's has none.
local function _decorTrack(m, ctx)
    if m.other then return nil end
    if m.chainKey and m.chainKey:find("^camp:") then
        return _trackButton(m.chainKey, nil, _mineIDs(ctx.chains[m.chainKey].ms), ctx)
    end
    local cur = ctx.P.cur[m.decorID]
    local b = _trackButton("d:" .. m.decorID, ctx.P.steps[m.decorID][cur > 0 and cur or 1], { m.decorID }, ctx)
    b.again = _questDone(ctx.P.state[m.decorID])   -- its tooltip says it is followed again
    return b
end

-- ----- Your characters: what each did of this decor -----
-- This character live, then the others as their last scan read them (DQ_ALT_SCANNED,
-- when Decor Quests opened on each), newest first, ALTS_SHOWN at most; then one line
-- naming the roster characters never scanned. Hidden ones left out.
local ALTS_SHOWN = 8

-- A scan's packed progress -> what that character did of decor d.
local function _altText(progress, d)
    local v = progress:match(" " .. d .. "=(%S+) ")
    if not v then return L("DQ_ALT_NOT_STARTED") end   -- exception(nullable): only started decor are packed
    if v == "x" then return L("DQ_ALT_CANT") end
    if v == "d" then return L("DQ_STATE_DONE") end
    local n, total = v:match("^(%d+)/(%d+)$")
    if not n then error(("HDG.DecorQuests: alt scan %q for decor %d is not d, x or n/N"):format(v, d)) end
    return L("DQ_STATE_PROGRESS"):format(tonumber(n), tonumber(total))
end

local function _hereText(m, P)
    local d = m.decorID
    if m.other then return L("DQ_ALT_CANT") end
    if P.here[d] then return L("DQ_STATE_DONE") end
    if P.nDone[d] > 0 then return L("DQ_STATE_PROGRESS"):format(P.nDone[d], #P.steps[d]) end
    return L("DQ_ALT_NOT_STARTED")
end

local function _byNewest(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.name < b.name
end

-- The other characters: scanned ones newest first, and the names of the roster's
-- unscanned ones, sorted. (A deleted character's scan goes with it: CHARACTER_DELETED.)
local function _altList(ctx)
    local scanned, unscanned = {}, {}
    for key, alt in pairs(ctx.alts) do
        local c = ctx.characters[key]
        if key ~= ctx.charKey and not (c and c.hidden) then   -- exception(nullable): a scanned character the roster has not met
            scanned[#scanned + 1] = { key = key, name = alt.name, classFile = alt.classFile, at = alt.at, progress = alt.progress }
        end
    end
    for key, c in pairs(ctx.characters) do
        if key ~= ctx.charKey and not c.hidden and not ctx.alts[key] then unscanned[#unscanned + 1] = c.name end
    end
    table.sort(scanned, _byNewest)
    table.sort(unscanned)
    return scanned, unscanned
end

local function _altRow(a, m, now)
    return { kind = "alt", key = "alt:" .. a.key, name = a.name, classFile = a.classFile, text = _altText(a.progress, m.decorID),
             when = L("DQ_ALT_CHECKED"):format(HDG.Format.RelativeTime(now - a.at)) }
end

-- "Not checked yet: A, B and 3 more - open Decor Quests on each."
local function _uncheckedNote(names)
    local shown = {}
    for i = 1, math.min(#names, ALTS_SHOWN) do shown[i] = names[i] end
    local list = table.concat(shown, ", ")
    if #names > ALTS_SHOWN then list = L("DQ_ALTS_AND_MORE"):format(list, #names - ALTS_SHOWN) end
    return _note("alts:unchecked", L("DQ_ALTS_UNCHECKED"):format(list), "dim")
end

local function _altRows(out, m, ctx)
    local me = ctx.identity
    out[#out + 1] = { kind = "section", key = "alts:head", label = L("DQ_ALTS_HEAD"), sub = L("DQ_ALTS_SUB") }
    local d, P = m.decorID, ctx.P
    local n = m.other and 0 or #P.steps[d]   -- the other faction's decor count no steps here
    out[#out + 1] = { kind = "alt", key = "alt:me", name = me.name, classFile = me.classFile, text = _hereText(m, P),
                      when = L("DQ_ALT_NOW"), frac = n > 0 and (P.here[d] and 1 or P.nDone[d] / n) or nil }
    local now = _G.time()   -- exception(boundary): wall clock for "checked 2 days ago"
    local scanned, unscanned = _altList(ctx)
    for i = 1, math.min(#scanned, ALTS_SHOWN) do out[#out + 1] = _altRow(scanned[i], m, now) end
    if #unscanned > 0 then out[#out + 1] = _uncheckedNote(unscanned) end
end

-- ----- Quest done: the vendor card (ruling 10-26) -----
-- Not in the collection: why it may not have come, and who else sells it (the catalog's
-- vendor, one this side can shop at first). Collected: the quest unlocked it on that vendor
-- for the warband, which sells more copies. A Waypoint when it has a spot.
local function _vendorOfDecor(m, ctx)
    local row = HDG.HousingCatalogObserver.byDecorID[m.decorID]
    return row.vendors and (HDG.VendorRank.MapVendor(row.vendors, ctx.me.side) or HDG.VendorRank.Pick(row))   -- exception(optional): a decor no vendor sells
end

local function _vendorCard(key, title, text, tone, v)
    local out = _note(key, text, "text")
    out.kind, out.title, out.titleTone = "missing", title, tone
    if v and v.canWaypoint then out.place = { mapID = v.mapID, x = v.x, y = v.y, name = v.name, side = v.side } end   -- exception(nullable): no vendor sells it
    return out
end

-- Why the decor may never have come (the other faction's copy, a faction change), that the
-- quest can still be played (never lock a player out, 10-26), then who else sells it.
local function _missingRow(m, ctx)
    local v = _vendorOfDecor(m, ctx)
    local text = L("DQ_MISSING_WHY"):format(_questTitle(m.q, m.questName),
        L(ctx.P.here[m.decorID] and "DQ_MISSING_HERE" or "DQ_MISSING_WARBAND"), m.name)
    if v then text = text .. " " .. L("DQ_MISSING_ALSO_SOLD"):format(v.name, v.zone or "?") end   -- exception(nullable): a vendor the augment has no zone for
    return _vendorCard("missing", L("DQ_MISSING_TITLE"), text, "error", v)
end

-- nil when no vendor is known: nothing to add to "Done".
local function _moreRow(m, ctx)
    local v = _vendorOfDecor(m, ctx)
    if not v then return nil end   -- exception(nullable): a decor no vendor sells
    return _vendorCard("more", L("DQ_MORE_TITLE"), L("DQ_MORE_SOLD_BY"):format(v.name, v.zone or "?"), "success", v)   -- exception(nullable): a vendor the augment has no zone for
end

-- Under the head, the Next block (Place.detailNext: the step the ladder heads for, as the
-- tracker shows it). A campaign chapter's decor shows the whole campaign first (the mockup's
-- order). A solo quest has no line, so no provenance either: the header's [Single quest] says
-- it. Every decor then shows what the account's characters did of it, and a chain's decor its
-- provenance last.
local function _detailFor(m, ctx)
    local info = _infoRow(m, ctx.P, ctx)
    info.track = _decorTrack(m, ctx)
    local out = { info }
    local nb = Place.detailNext(m, ctx)
    if nb then out[2] = nb end   -- exception(nullable): no Next block with no step to head for
    local s = ctx.P.state[m.decorID]
    if s == "missing" then out[#out + 1] = _missingRow(m, ctx) end
    if s == "done" then out[#out + 1] = _moreRow(m, ctx) end
    if m.other then out[#out + 1] = _otherNote(m) end
    if not m.lineID then
        _soloRows(out, m, ctx)
    else
        if m.chainKey and m.chainKey:find("^camp:") then _campaignRows(out, ctx.chains[m.chainKey], ctx, m.lineID) end   -- exception(optional): a treasure hunt with a line has no chain row
        _chainRows(out, m, ctx)
    end
    if m.repeats then
        out[#out + 1] = Repeats.note(m)   -- in Your characters' place: their quest flags reset
    else
        _altRows(out, m, ctx)
    end
    if m.lineID then out[#out + 1] = _provNote(m) end   -- last, after Your characters (the lab's; review C9)
    return out
end

-- ----- A chain's detail (By Chain): its decor, then the ladder its Track follows -----

-- A decor in a chain's or a campaign's list: icon, name, and where it stands.
local function _decorLineRow(m, ctx, text)
    local d = m.decorID
    return { kind = "decorLine", key = "dl:" .. d, icon = m.icon, name = m.name, state = ctx.P.state[d],
             stateText = text, got = ctx.owned[d] == true and ctx.P.state[d] ~= "done" }
end

local function _bySteps(a, b)
    if #a.steps ~= #b.steps then return #a.steps < #b.steps end
    return _byName(a, b)
end

local function _chainDecorText(m, ctx)
    if ctx.P.state[m.decorID] == "done" then return L("DQ_STATE_DONE") end
    if ctx.P.state[m.decorID] == "missing" then return L("DQ_STATE_MISSING") end
    if m.other then return _onlyText(m) end
    return L("DQ_STEP_N"):format(#ctx.P.steps[m.decorID])
end

-- A chain's Track follows its nearest decor the warband has not done, else its farthest.
local function _chainTrackTarget(e, ctx)
    local near
    for _, m in ipairs(e.ms) do
        if not m.other and not _questDone(ctx.P.state[m.decorID]) and (near == nil or #m.steps < #near.steps) then near = m end
    end
    return near or e.far
end

-- The ladder shown is the one Track follows, so a step picked here is the tracker's step.
-- Done, the head names the quest that unlocked the chain's last decor, as a decor's header
-- does (owner 10-30).
local function _chainDetail(e, ctx)
    local far, lead, ms, rewards = e.far, _chainTrackTarget(e, ctx), {}, {}
    local sub = _questDone(e.state) and L("DQ_UNLOCKED_BY"):format(_questTitle(far.q, far.questName))
        or L("DQ_CHAIN_LAST_STEP"):format(#ctx.P.steps[far.decorID])
    local out = { { kind = "section", key = "c:head", label = L("DQ_CHAIN_DECOR_HEAD"):format(#e.ms),
                    sub = sub, track = _decorTrack(lead, ctx) } }
    for i, m in ipairs(e.ms) do ms[i] = m end
    table.sort(ms, _bySteps)
    for _, m in ipairs(ms) do
        out[#out + 1] = _decorLineRow(m, ctx, _chainDecorText(m, ctx))
        _addReward(rewards, m)
    end
    if lead.other then
        out[#out + 1] = _otherNote(lead)
    else
        _decorLadder(out, lead, HDG.StaticData.DecorQuests:Line(lead.lineID), rewards, ctx)
    end
    _altRows(out, far, ctx)   -- the chain's longest decor, as the bar above it (the mockup's)
    out[#out + 1] = _provNote(far)   -- last (the lab's; review C9)
    return out
end

-- ----- A campaign's detail (By Chain): its decor, each with its chapter, then the card -----

local function _campaignDecorText(m, ctx)
    if ctx.P.state[m.decorID] == "done" then return L("DQ_STATE_DONE") end
    if ctx.P.state[m.decorID] == "missing" then return L("DQ_STATE_MISSING") end
    if m.other then return _onlyText(m) end
    -- The chapter's own count, as its row on the card reads.
    local at, cp = HDG.StaticData.DecorQuests:ChapterOf(m.lineID), ctx.chapters[m.lineID]
    local chapter = at.campaign.chapters[at.index][at.side][2]
    return L("DQ_CHAPTER_STEPS"):format(chapter, cp.n, cp.total)
end

local function _campaignDetail(e, ctx)
    local mine = _mineIDs(e.ms)
    local out = { { kind = "section", key = "c:head", label = L("DQ_CAMPAIGN_DECOR_HEAD"):format(#e.ms),
                    sub = L("DQ_EACH_ENDS_CHAPTER"),
                    track = #mine > 0 and _trackButton(e.key, nil, mine, ctx) or nil } }   -- exception(optional): the other faction's campaign has nothing to track
    for _, m in ipairs(e.ms) do out[#out + 1] = _decorLineRow(m, ctx, _campaignDecorText(m, ctx)) end
    _campaignRows(out, e, ctx, nil)
    return out
end

local function _detailCtx(state, ctx)
    local ui = state.session.ui.decorQuests
    return { P = Selectors:Call("decorQuests.progress", state, ctx), me = Selectors:Call("decorQuests.models", state, ctx).me,
             owned = state.account.collection.ownedDecorIDs, completions = state.account.questCompletions,
             openFolds = ui.openFolds, openChapters = ui.openChapters, picks = ui.picks,
             tracked = Selectors:Call("decorQuests.tracked", state, ctx),
             alts = state.account.decorQuests.alts, characters = state.account.characters,
             charKey = state.session.identity.charKey, identity = state.session.identity,
             chapters = Selectors:Call("decorQuests.chapters", state, ctx), chains = Selectors:Call("decorQuests.chains", state, ctx) }
end

Selectors:Register("decorQuests.detailRows", {
    memoized = true,
    reads = { UI_PATH .. ".openFolds", UI_PATH .. ".openChapters", UI_PATH .. ".picks", "account.collection.ownedDecorIDs",
              "account.questCompletions", "session.resolvers.questTitles.tick", "session.resolvers.questStatus.tick",
              "session.resolvers.questLog.tick", "session.resolvers.staticData.tick", "session.npcNames.names",
              "session.resolvers.catalog.tick", "session.identity.factionGroup", "account.decorQuests.alts",
              "account.characters.*.hidden", "account.characters.*.name", "account.characters.*.classFile",
              "session.identity.charKey", "session.identity.name", "session.identity.classFile",
              "session.resolvers.fonts.tick" },   -- the who lines' measure
    calls = { "decorQuests.selected", "decorQuests.selectedChain", "decorQuests.viewMode", "decorQuests.models",
              "decorQuests.progress", "decorQuests.chapters", "decorQuests.chains", "decorQuests.tracked" },
    fn = function(state, ctx)
        local e = Selectors:Call("decorQuests.selectedChain", state, ctx)
        if e then
            if e.campaign then return _campaignDetail(e, _detailCtx(state, ctx)) end
            return _chainDetail(e, _detailCtx(state, ctx))
        end
        local m = Selectors:Call("decorQuests.selected", state, ctx)
        if m then return _detailFor(m, _detailCtx(state, ctx)) end
        local chain = Selectors:Call("decorQuests.viewMode", state, ctx) == "chain"
        return { { kind = "blank", key = "blank", text = L(chain and "DQ_PICK_CHAIN" or "DQ_PICK_DECOR") } }
    end,
})

-- ============================================================================
-- The Quest Tracker (a floating window, HDGR_LayoutConfig_DecorQuestTracker.lua)
-- ============================================================================
-- Built from the decor rows Track saved (account.decorQuests.tracked[charKey].rows), not
-- the catalog: that loads with the main window, and the tracker can be up at login
-- without it. What Track follows ("d:<decorID>" | "k:<lineID>" | "camp:<id>") is a
-- ladder, or for a campaign the ladder of the chapter the player is on (none while the
-- game has no chapter on offer). A ladder:
--   pickKey  what a disc click and a turn-in pick, saved with what is tracked
--   steps    this character's steps, as the detail's ladder (i, q, map, num, cat)
--   cur      the step to head for (0 = past the last: the tracker has finished)
--   nDone, done; here (a decor's: this character did its quest)
--   lineID   nil for a lone quest
--   m, rwAt  the decor the ladder ends (nil on a chapter that ends none) and its step

for key, path in pairs({ trackerPosition = "pos", trackerExpanded = "expanded" }) do
    Selectors:DefinePath("decorQuests." .. key, "account.ui.decorQuestTracker." .. path)
end

-- The tracker is up on this character (owner R2, 10-29: per character, as what it follows is).
Selectors:Register("decorQuests.trackerShown", {
    reads = { "account.ui.decorQuestTracker.shown", "session.identity.charKey" },
    fn = function(state)
        local charKey = HDG.SessionIdentity.GetCharKey(state)
        if not charKey then return false end   -- exception(nullable): identity resolves after the first paint
        return state.account.ui.decorQuestTracker.shown[charKey] == true
    end,
})

-- A text row's width: the window's 320 (LayoutConfig_DecorQuestTracker) less its body's padding
-- (spacing.md, 6) each side; a row with a Wpt loses the button (40) and the gap before it,
-- and is at least the button's height (the tracker controller's WPT_H, the tab's 16: review G9).
local TRACKER_TEXT_W, TRACKER_WPT = 308, { w = 44, h = 16 }
local STRIP_MAX              = 7    -- the columns the strip shows (a box is one); the rest count as "+k" steps
local NEXT_TRACKED           = 3    -- the steps after the one to head for the expanded tracker lists
local TRACKER_ICON           = 16
local TRACKER_LINE_H         = { caption = 13, body = 15, subheading = 18 }
-- boxed: a strip with an any-order box, its two rows of discs (the tracker controller's BOX_H).
local TRACKER_STRIP_H        = { plain = 30, boxed = 52 }
-- The rule row and the header's X and arrow: HDG.Constants.DQ_TRACKER, which the tracker
-- controller and LayoutConfig draw them by.
local TRACKER_HEADER_H, TRACKER_BUTTONS_H, TRACKER_BODY_PAD = 28, 30, 8

local function _trackerCtx(state, tracked)
    local me, ms = _meOf(state), {}
    for i, row in ipairs(tracked.rows) do ms[i] = _buildModel(row, me) end
    local ctx = { me = me, ms = ms, P = _newProgress(), tracked = tracked, picks = state.session.ui.decorQuests.picks,
                  owned = state.account.collection.ownedDecorIDs }
    for _, m in ipairs(ms) do _progressOf(m, Pick.of("d:" .. m.decorID, ctx.picks, tracked), ctx.P, ctx.owned) end
    return ctx
end

-- A chapter's ladder: its whole line; the decor it ends (one of the saved rows) marked.
local function _chapterTrackLadder(lineID, ctx)
    local steps, cur, nDone, done = _chapterSteps(lineID, ctx)
    local lad = { pickKey = "k:" .. lineID, steps = steps, cur = cur, nDone = nDone, done = done, here = done, lineID = lineID }
    for _, m in ipairs(ctx.ms) do
        if m.lineID == lineID then lad.m = m end
    end
    if not lad.m then return lad end   -- exception(nullable): most chapters end no decor
    for _, s in ipairs(steps) do
        if s.q == lad.m.q then lad.rwAt = s.num end
    end
    return lad
end

-- A campaign's chapters on this character, each with its progress.
local function _campaignChapters(campaign, me)
    local out = {}
    for i, ch in ipairs(HDG.StaticData.DecorQuests:ChaptersFor(campaign, me.side)) do
        out[i] = { ch = ch, cp = _chapterProgress(ch[1], me) }
    end
    return out
end

local function _allHere(ctx)
    for _, m in ipairs(ctx.ms) do
        if not ctx.P.here[m.decorID] then return false end
    end
    return true
end

local function _chapterName(lineID)
    local at = HDG.StaticData.DecorQuests:ChapterOf(lineID)
    return at.campaign.chapters[at.index][at.side][2], at
end

-- The target: { key, kind, name, icon, sub, count, ladder, ... } (see above).
local function _decorTarget(key, ctx)
    local m = ctx.ms[1]
    return { key = key, kind = "decor", name = m.name, icon = m.icon, sub = m.lineName or _kindLabel(m.kind),   -- exception(nullable): a lone quest has no line
             ladder = _decorTrackLadder(m, ctx) }
end

local function _chapterTarget(key, ctx)
    local lineID = tonumber(key:match("^k:(%d+)$"))
    local name, at = _chapterName(lineID)
    local lad = _chapterTrackLadder(lineID, ctx)
    return { key = key, kind = "chapter", name = name, icon = lad.m and lad.m.icon, sub = at.campaign.name, ladder = lad }   -- exception(nullable): a chapter that ends no decor has no icon
end

local function _campaignTarget(key, ctx)
    local campaign = HDG.StaticData.DecorQuests:ChapterOf(ctx.ms[1].lineID).campaign
    local chapters, nDone = _campaignChapters(campaign, ctx.me), 0
    for _, c in ipairs(chapters) do
        if c.cp.state == "done" then nDone = nDone + 1 end
    end
    local t = { key = key, kind = "campaign", name = campaign.name, chapters = chapters, finished = _allHere(ctx),
                count = L("DQ_TRK_CHAPTERS_OF"):format(nDone, #chapters), icon = ctx.ms[1].icon }
    for _, m in ipairs(ctx.ms) do
        if not ctx.P.here[m.decorID] then t.icon = m.icon; break end
    end
    local cur = not t.finished and _currentChapter(chapters)
    if cur then t.ladder, t.sub = _chapterTrackLadder(cur.ch[1], ctx), cur.ch[2] end
    t.sub = t.sub or (t.finished and "" or L("DQ_TRK_NO_CHAPTER"))
    return t
end

local TRACK_TARGET = { d = _decorTarget, k = _chapterTarget, camp = _campaignTarget }

-- Every decor Track saved is for another faction, race or class now: tracked before a
-- faction or race change, or saved under a name another character took. No ladder.
local function _allOther(ctx)
    for _, m in ipairs(ctx.ms) do
        if not m.other then return false end
    end
    return true
end

local function _otherTarget(key, ctx)
    local m = ctx.ms[1]
    return { key = key, kind = "other", other = true, name = m.name, icon = m.icon, sub = _onlyText(m), count = "" }
end

Selectors:Register("decorQuests.trackerTarget", {
    memoized = true,
    reads = { UI_PATH .. ".picks", "account.collection.ownedDecorIDs", "session.resolvers.questStatus.tick",
              "session.resolvers.questLog.tick", "session.resolvers.staticData.tick",
              "session.identity.factionGroup", "session.identity.raceID", "session.identity.classID" },
    calls = { "decorQuests.tracked" },
    fn = function(state, ctx)
        local tracked = Selectors:Call("decorQuests.tracked", state, ctx)
        if not tracked then return nil end   -- exception(nullable): nothing tracked
        local tctx = _trackerCtx(state, tracked)
        local t = _allOther(tctx) and _otherTarget(tracked.key, tctx)
            or TRACK_TARGET[tracked.key:match("^(%a+):")](tracked.key, tctx)
        t.ctx = tctx
        if not t.count and t.ladder then t.count = L("DQ_TRK_DONE_OF"):format(t.ladder.nDone, #t.ladder.steps) end
        return t
    end,
})

-- ----- The tracker's body: rows, each with its height (the window sizes to them) -----
-- text  { text, tone ("text" | "dim" | "accent" | "success" | "warn" | "error"), font, way,
--         runs = { { tone, text }, ... } (a line in parts: "Complete these:" dim, the place line's
--         gold "!" and "?", the Next line's quest name) }
-- pair  { left, right }: what the target belongs to, and how far along it is
-- strip { discs = { num, state ("target" | "done" | "log" | "ahead"), icon, pick, tip }, before, after, pickKey }

-- way: the row's own Map (a step not in the log: num, its pin's number), Arrow (one in the
-- log) or Track (track: a Collected! card's decor quest in its zone, Place.zoneMore) at its
-- right, which takes TRACKER_WPT.w of each line.
-- The lines are measured in the row's font (an estimate by characters left a blank line
-- under "Next: The Captive Engineer - ready to turn in", 10-27).
local function _textRow(key, text, tone, font, way)
    font = font or "caption"
    local lines = HDG.TextMeasure:Lines(font, TRACKER_TEXT_W - (way and TRACKER_WPT.w or 0), text)
    return { kind = "text", key = key, text = text, tone = tone, font = font, way = way,
             height = math.max(2 + TRACKER_LINE_H[font] * lines, way and TRACKER_WPT.h or 0) }
end

-- A text row in parts, runs = { { tone, text }, ... }: measured as their text joined.
function Place.runsRow(key, runs, font, way)
    local text = {}
    for i, r in ipairs(runs) do text[i] = r[2] end
    local row = _textRow(key, table.concat(text), "text", font, way)
    row.runs = runs
    return row
end

-- The strip's window: STRIP_MAX columns from two before the column to head for.
function Strip.window(n, target)
    if n <= STRIP_MAX then return 1, n end
    local first = math.min(math.max(target - 2, 1), n - STRIP_MAX + 1)
    return first, first + STRIP_MAX - 1
end

-- A disc's state: the step to head for, done, in the log (its own ring: the quests to work on
-- now, owner 10-28), else ahead.
function Strip.disc(lad, s)
    local isCur = s.num == lad.cur
    local d = { num = s.num, state = (isCur and "target") or (s.cat == "done" and "done")
                    or (HDG.QuestNameResolver:IsOnQuest(s.q) and "log") or "ahead",
                tip = L("DQ_TRK_DISC_TIP"):format(s.num, _stepTitleOf(lad, s)) }
    if s.num == lad.rwAt then d.icon = lad.m.icon end
    if not isCur and (lad.here or s.cat ~= "done") then d.pick = s.q end
    return d
end

-- The strip's columns: a step alone, or an any-order box (ruling G) as one, in step order.
function Groups.columns(steps)
    local boxes, cols, num = Groups.boxes(steps), {}, 1
    while num <= #steps do
        local last = boxes[num] and boxes[num].last or num   -- exception(nullable): a step in no box
        cols[#cols + 1] = { first = num, last = last }
        num = last + 1
    end
    return cols
end

function Strip.columnOf(cols, num)
    for k, c in ipairs(cols) do
        if num <= c.last then return k end
    end
    error(("decorQuests: no strip column holds step %d"):format(num))
end

-- A box's column: its discs' range in the strip's discs, its edge in the accent while the step to head for
-- is in it; hovering it lists the box.
function Strip.boxColumn(lad, c, from, discs)
    local tips = {}
    for k = from, #discs do tips[#tips + 1] = discs[k].tip end
    return { from = from, to = #discs, on = lad.cur >= c.first and lad.cur <= c.last,
             tip = L("DQ_TRK_BOX_TIP"), tips = tips }
end

function Strip.addColumn(lad, c, discs, cols)
    local from = #discs + 1
    for num = c.first, c.last do discs[#discs + 1] = Strip.disc(lad, lad.steps[num]) end
    cols[#cols + 1] = c.last > c.first and Strip.boxColumn(lad, c, from, discs) or { from = from, to = from }
end

function Strip.row(lad)
    local all = Groups.columns(lad.steps)
    local first, last = Strip.window(#all, Strip.columnOf(all, lad.cur > 0 and lad.cur or #lad.steps))
    local discs, cols = {}, {}
    for k = first, last do Strip.addColumn(lad, all[k], discs, cols) end
    local boxed = #discs > #cols
    return { kind = "strip", key = "strip", discs = discs, cols = cols, before = all[first].first - 1,
             after = #lad.steps - all[last].last, pickKey = lad.pickKey,
             height = TRACKER_STRIP_H[boxed and "boxed" or "plain"] }
end

local function _endOf(lad, s, side)
    if lad.lineID then return HDG.StaticData.DecorQuests:StepEnd(lad.lineID, s.i, side) end
    return HDG.StaticData.DecorQuests:SoloEnd(s.q, side)
end

-- Who takes finished step q back: "turn in to <NPC>" once the game has the name ("..., who
-- follows you" for an escort), "turn in at <object>"; with nobody, "complete it from your
-- quest tracker" where Wowhead's comments say so, else nil. kp: the strings' prefix, "DQ_"
-- once it is ready to hand in, "DQ_TRK_" for "End: <NPC>" before (owner 10-30).
local function _turnInText(hand, q, kp)
    if not hand then
        local how = HDG.StaticData.DecorQuests:EndHow(q)
        return how and L(kp .. "ENDS_" .. how:upper())   -- exception(nullable): nobody says how it ends
    end
    if hand.object then return L(kp .. "TURN_IN_AT"):format(hand.object) end
    local name = HDG.NPCNameResolver:ResolveName(hand.npcID, nil)
    if not name then return nil end   -- exception(nullable): the name is not in yet
    return L(kp .. (HDG.StaticData.DecorQuests:Follows(q, "end") and "TURN_IN_FOLLOWS" or "TURN_IN_TO")):format(name)
end

-- Who starts step s and who takes it back, as runs { tone, text } after a gold "!" and "?",
-- the quest marks as text (owner 10-30: the game's atlases pad wide): "! <giver>  ? <NPC>",
-- "!? <NPC>" when one does both, the one known; in the log the start is behind you (owner
-- 10-27). A step the game hands out in the zone the line names starts "on arrival" (ruling
-- C). hand: _endOf's. nil while nobody is known.
function Place.trackerWho(lad, s, side, inLog, hand)
    local start
    local from = (not inLog) and _startOf(lad, s, side)   -- exception(nullable): a quest the index does not ship
    if from and _zoneName(s.map) and HDG.StaticData.DecorQuests:GameGives(from, s.q) then start = L("DQ_TRK_START_REACH")
    elseif from then start = _giverText(from, s.q) end
    local finish = _turnInText(hand, s.q, "DQ_TRK_")
    if start and start == finish then return { { "mark", "!?" }, { "text", " " .. start } } end
    local runs = {}
    if start then runs[1], runs[2] = { "mark", "!" }, { "text", " " .. start .. (finish and "  " or "") } end
    local n = #runs
    if finish then runs[n + 1], runs[n + 2] = { "mark", "?" }, { "text", " " .. finish } end
    return runs[1] and runs   -- exception(nullable): nobody known yet
end

-- A box step's name in that line, "(in your log)" after one already taken (the mockup).
function Groups.restName(lad, o)
    local name = _stepTitleOf(lad, o)
    if HDG.QuestNameResolver:IsOnQuest(o.q) then return L("DQ_TRK_REST_IN_LOG"):format(name) end
    return name
end

-- "Complete these:" dim, the quest names in the text colour (the parallel mockup).
function Groups.restRow(rest)
    return Place.runsRow("box", { { "dim", L("DQ_TRK_COMPLETE_THESE") }, { "text", " " .. rest } }, "body")
end

-- The rest of the box the step to head for sits in, not done yet, as "A, B"; nil when it
-- is in none or the rest is done (ruling G, owner 2026-10-27).
function Groups.rest(lad, s)
    if not s.grp then return nil end
    local names = {}
    for _, o in ipairs(lad.steps) do
        if o.grp == s.grp and o ~= s and o.cat ~= "done" then names[#names + 1] = Groups.restName(lad, o) end
    end
    return #names > 0 and table.concat(names, ", ") or nil
end

-- A who line: Place.trackerWho's runs, then " - <zone>" dim, the zone last beside the button that shows
-- it (owner 10-30); the zone alone with nobody known; nil with neither. The tracker's place
-- line, and since Bold B (owner 10-30) every ladder step's line and a lone quest's, so both
-- windows read who and where one way. hand: _endOf's.
function Place.who(lad, s, side, inLog, hand)
    local who, zone = Place.trackerWho(lad, s, side, inLog, hand), _zoneName(s.map)
    if not who then return zone and { { "text", zone } } end   -- exception(nullable): nobody known yet, or a map with no zone
    if zone then who[#who + 1] = { "dim", " - " .. zone } end   -- exception(nullable): a step with no map names no zone
    return who
end

-- Runs' text joined, the lines of them ("\n" between) at width w in font: how many lines it
-- takes (HDG.TextMeasure).
function Place.lines(runsList, font, w)
    local text = {}
    for i, runs in ipairs(runsList) do
        local parts = {}
        for k, r in ipairs(runs) do parts[k] = r[2] end
        text[i] = table.concat(parts)
    end
    if #text == 0 then return 0 end
    return HDG.TextMeasure:Lines(font, w, table.concat(text, "\n"))
end

-- A ladder step's who line (a lone quest's: lad = {}, no line) and how many lines it takes at
-- the step's text width: nil, 0 with nothing known.
function Place.ladderWho(lad, s, side, inLog)
    local who = Place.who(lad, s, side, inLog, _endOf(lad, s, side))
    if not who then return nil, 0 end   -- exception(nullable): nobody and no zone known
    return who, Place.lines({ who }, "body", HDG.Constants.DQ_DETAIL_TEXT.step)
end

-- The place line under the step to head for: its who line, in body like the line above it, as
-- caption read small there (owner 10-30). Once its objectives are done, "turn in to <NPC>"
-- alone in success (ruling A, G2). A line that wraps with the giver and the turn-in apart
-- splits in two, "! giver" over "? NPC - zone" (the Full mockup). way: the step's button, on
-- the last row. fitW: the width the line must fit to stay whole, the detail's Next block's
-- (Place.block measures its rows again); the tracker's judge by their height. Returns the
-- rows: none with nothing known.
function Place.rows(lad, s, side, inLog, ready, way, fitW)
    local hand = _endOf(lad, s, side)
    if ready then
        local text = _turnInText(hand, s.q, "DQ_")
        return { text and _textRow("where", text, "success", "body", way) }   -- exception(nullable): no hand-in known
    end
    local who = Place.who(lad, s, side, inLog, hand)
    if not who then return {} end   -- exception(nullable): nobody and no zone known
    local row = Place.runsRow("where", who, "body", way)
    local whole = (fitW and HDG.TextMeasure:Lines("body", fitW, row.text) == 1)   -- exception(optional): only the detail's Next block passes fitW
        or (not fitW and row.height <= 2 + TRACKER_LINE_H.body)
    if whole or not (who[3] and who[3][1] == "mark") then return { row } end
    return Place.split(who, way)
end

-- "! giver" over "? NPC - zone", the button on the second.
function Place.split(who, way)
    local second = {}
    for i = 3, #who do second[#second + 1] = who[i] end
    local first = { who[1], { "text", (who[2][2]:gsub("%s+$", "")) } }
    return { Place.runsRow("start", first, "body"), Place.runsRow("where", second, "body", way) }
end

-- The step to head for in subheading, its quest's name in the accent, set off from "Next:"
-- (owner 10-30; the Full mockup). key: DQ_TRK_STEP / _IN_LOG / _READY. The title drops a
-- "<campaign>: " the pair row under it already says (review C8).
-- font: subheading; body in the Compact tracker, where it is one of three lines.
function Place.nextLine(lad, s, above, key, way, font)
    local title, prefix = _stepTitleOf(lad, s), above .. ": "
    if title:sub(1, #prefix) == prefix then title = title:sub(#prefix + 1) end
    local pre, post = L(key):match("^(.-)%%s(.*)$")
    return Place.runsRow("line", { { "text", pre }, { "accent", title }, { "text", post } }, font, way)
end

-- The step to head for: its Next line, the place line(s) with the step's one button (Map; the
-- quest arrow once it is in the log; greyed, saying why, with no spot known) -- on the Next
-- line when there is no place line -- then the rest of its any-order box and a repeatable's
-- line (the Full mockup, owner 10-30). above: what the pair row names. inLog, ready: the
-- step's (the detail's Next block passes ready false, see Place.detailNext). compact: the
-- Compact tracker's, the Next line in body and nothing under the place line (the Compact
-- mockup: three lines). fitW: Place.rows'.
function Place.stepRows(out, lad, ctx, above, inLog, ready, compact, fitW)
    local s = lad.steps[lad.cur]
    local way = _stepWay(lad, ctx.me.side)
    local place = Place.rows(lad, s, ctx.me.side, inLog, ready, way, fitW)
    local key = (ready and "DQ_TRK_READY") or (inLog and "DQ_TRK_IN_LOG") or "DQ_TRK_STEP"
    out[#out + 1] = Place.nextLine(lad, s, above, key, (not place[1]) and way or nil, compact and "body" or "subheading")
    for _, row in ipairs(place) do out[#out + 1] = row end
    if compact then return end
    local rest = Groups.rest(lad, s)
    if rest then out[#out + 1] = Groups.restRow(rest) end
    local trk = lad.m and lad.m.repeats and Repeats.TRK[lad.m.repeats]   -- exception(nullable): a chapter that ends no decor, a decor done once, a plain repeatable
    if trk then out[#out + 1] = _textRow("repeat", L(trk[1]), trk[2], "body") end
end

local function _lineRows(out, lad, ctx, above, compact)
    local s = lad.steps[lad.cur]
    local inLog = s.cat ~= "done" and HDG.QuestNameResolver:IsOnQuest(s.q)
    Place.stepRows(out, lad, ctx, above, inLog, inLog and HDG.QuestNameResolver:IsReadyForTurnIn(s.q), compact)
end

-- ----- The detail's Next block (Bold B, owner 10-30) -----
-- The tracker's rows for the step a decor's ladder heads for (Place.stepRows), boxed under the
-- detail's head as one row, "step N of M" beside Next: what's next is the first thing in the
-- detail, as in the tracker, with the same one button (Map: map + pin + waypoint; Arrow once
-- the step is in the log). { line = the Next line's runs, upper = the place lines down to the
-- one the button sits on, lower = the rest (any-order box, a repeatable's line), way, step,
-- and each part's measured lines }. nil for the other faction's decor, or with no step to
-- head for (the missing card carries the vendor's spot). Never "ready to turn in": an
-- objective ticks over and over while you quest and only the tracker re-runs on it (review
-- section 5), so here a step in the log reads "in your log".

-- A row's runs: its own, else its text in its tone.
function Place.runsOf(r)
    return r.runs or { { r.tone, r.text } }
end

function Place.block(rows, lad)
    local K = HDG.Constants.DQ_DETAIL_TEXT
    local b = { kind = "next", key = "next", line = rows[1].runs, way = rows[1].way, upper = {}, lower = {} }
    if #lad.steps > 1 then b.step = L("DQ_NEXT_STEP_OF"):format(lad.cur, #lad.steps) end
    local into = b.way and b.lower or b.upper   -- no place line: the button rides the Next line
    for i = 2, #rows do
        into[#into + 1] = Place.runsOf(rows[i])
        if rows[i].way then b.way, into = rows[i].way, b.lower end
    end
    local lineW = K.next - (b.step and K.stepOf or 0) - (#b.upper == 0 and K.way or 0)
    b.lineW, b.lineLines = lineW, Place.lines({ b.line }, "subheading", lineW)
    b.upperLines = Place.lines(b.upper, "body", K.next - K.way)
    b.lowerLines = Place.lines(b.lower, "body", K.next)
    return b
end

function Place.detailNext(m, ctx)
    if m.other or ctx.P.cur[m.decorID] == 0 then return nil end
    local lad, rows = _decorTrackLadder(m, ctx), {}
    local s = lad.steps[lad.cur]
    local inLog = s.cat ~= "done" and HDG.QuestNameResolver:IsOnQuest(s.q)
    local K = HDG.Constants.DQ_DETAIL_TEXT
    Place.stepRows(rows, lad, ctx, m.lineName or _kindLabel(m.kind), inLog, false, false, K.next - K.way)   -- exception(nullable): a lone quest has no line (the tracker's pair row)
    return Place.block(rows, lad)
end

-- An expanded tracker's next steps: NEXT_TRACKED after the one to head for, then one line
-- that runs on to the decor quest (or the end). Each not done here has its own Wpt.
local function _nextWay(lad, s, side)
    if s.cat == "done" then return nil end
    local way = _questWay(HDG.QuestNameResolver:IsOnQuest(s.q), s.q, _startOf(lad, s, side), _stepTitleOf(lad, s))
    if way then way.num = s.num end   -- exception(nullable): a step with no known spot
    return way
end

local function _nextRow(lad, num, skipped, side)
    local s = lad.steps[num]
    local title = _stepTitleOf(lad, s)
    if skipped > 0 then title = L("DQ_TRK_MORE_THEN"):format(skipped, title) end
    local tag = num == lad.rwAt and lad.m.name or _zoneName(s.map)
    if tag then title = title .. " - " .. tag end   -- exception(nullable): a step with no map names no zone
    return _textRow("n:" .. num, num .. "  " .. title, num == lad.rwAt and "success" or "text", "body", _nextWay(lad, s, side))
end

local function _nextRows(out, lad, side)
    local n = #lad.steps
    local upto = math.min(n, lad.cur + NEXT_TRACKED)
    for num = lad.cur + 1, upto do out[#out + 1] = _nextRow(lad, num, 0, side) end
    local stop = (lad.rwAt and lad.rwAt > upto) and lad.rwAt or n   -- exception(nullable): a chapter that ends no decor runs to its end
    if upto < stop then out[#out + 1] = _nextRow(lad, stop, stop - 1 - upto, side) end
    if lad.cur == lad.rwAt then out[#out + 1] = _textRow("isDecor", L("DQ_TRK_IS_DECOR_QUEST"), "success", "body") end
end

-- The vendor Track saved with a decor (nil: no vendor sells it).
local function _vendorOf(m, ctx)
    for _, row in ipairs(ctx.tracked.rows) do
        if row.decorID == m.decorID then return row.vendor end
    end
    error(("HDG.DecorQuests: tracked decor %d has no saved row"):format(m.decorID))
end

-- A decor not in the collection past its last step: the Map to its vendor's spot (+ side);
-- nil when no vendor sells it or its spot is unknown.
local function _vendorWay(m, ctx)
    local v = _vendorOf(m, ctx)
    if not (v and HDG.VendorRank.HasLocation(v.mapID, v.x, v.y)) then return nil end   -- exception(nullable): no vendor sells it, or it has no spot
    return { enabled = true, vendor = true, map = v.mapID, x = v.x, y = v.y, title = v.name, side = v.side }
end

-- Past the last step: the chapter is done, or the decor is collected, or not yet (and who
-- sells it, with the Map to them). No strip then (the Full mockup).
local function _finRows(out, lad, t, ctx)
    if not lad.m then
        out[#out + 1] = _textRow("fin", L("DQ_TRK_CHAPTER_DONE"), "success", "subheading")
        out[#out + 1] = _textRow("fin2", L("DQ_TRK_CHAPTER_DONE_SUB"):format(t.name), "text", "body")
        return out
    end
    if ctx.owned[lad.m.decorID] then
        out[#out + 1] = _textRow("fin", L("DQ_TRK_COLLECTED"), "success", "subheading")
        out[#out + 1] = _textRow("fin2", L("DQ_TRK_COLLECTED_SUB"):format(lad.m.name), "text", "body")
        return out
    end
    local v, text = _vendorOf(lad.m, ctx), L("DQ_TRK_NOT_OWNED"):format(lad.m.name)
    if v then text = text .. " " .. L("DQ_TRK_SOLD_BY"):format(v.name, v.zone) end   -- exception(nullable): a decor no vendor sells
    out[#out + 1] = _textRow("fin", L("DQ_TRK_QUEST_DONE"), "error", "subheading")
    out[#out + 1] = _textRow("fin2", text, "text", "body", _vendorWay(lad.m, ctx))
    return out
end

-- ----- After Collected!: the decor quests that start in its zone (Bold C, owner 10-30) -----
-- Under a rule, "In <zone>: N more decor quests start here", then each (DQ_ZONE_MORE_MAX at
-- most) with Track. The zone is the collected decor's own: you stand where you turned it in,
-- and the list holds as you fly off. One starts there when its first step on this character's
-- ladder does, not started here, not yours yet. A campaign's decor are left out: the game picks
-- which chapter comes next, so it starts in no one zone. Off the tab's models and progress
-- (review 2026-10-31 P1/P2): decorQuests.zoneStarts makes models of the few catalog rows that
-- may start here, and keeps them while quest objectives, titles, names and fonts move.

-- Whether row's ladder may start in map: a step up to its decor quest is there. A ladder keeps
-- some of those steps, so this never drops one that starts there; no model for the rest.
function Place.mayStartIn(row, me, map)
    local _, line, at, qMap = _locate(_variants(row.questID, me), me.side)
    if not line then return qMap == map end   -- exception(nullable): a solo quest has no line
    for i = 1, at do
        if HDG.StaticData.DecorQuests:StepMap(line, i, me.side) == map then return true end
    end
    return false
end

-- row's ladder when its decor quest starts in map and is new to this character, else nil.
function Place.startsIn(row, zctx, map, doneID)
    local d = row.decorID
    if not row.questID or d == doneID or zctx.owned[d] or not Place.mayStartIn(row, zctx.me, map) then return nil end
    local m = _buildModel(row, zctx.me)
    if m.other or (m.chainKey and m.chainKey:find("^camp:")) then return nil end
    _progressOf(m, Pick.of("d:" .. d, zctx.picks, zctx.tracked), zctx.P, zctx.owned)
    if zctx.P.state[d] ~= "new" then return nil end
    local lad = _decorTrackLadder(m, zctx)
    local s = lad.steps[1]
    return (s ~= nil and s.map == map) and lad or nil   -- exception(nullable): a ladder its gates leave empty
end

function Place.byName(a, b) return _byName(a.m, b.m) end

-- "<icon> <name> - ! <giver>", the giver left off until the game has the name; its Track.
function Place.zoneRow(lad, zctx)
    local m, s = lad.m, lad.steps[1]
    local from = _startOf(lad, s, zctx.me.side)
    local giver = from and _giverText(from, s.q)   -- exception(nullable): a quest the index does not ship
    local runs = { { "text", HDG.Format.IconMarkup(m.icon, TRACKER_ICON) .. " " .. m.name } }
    if giver then runs[1][2], runs[2], runs[3] = runs[1][2] .. " - ", { "mark", "!" }, { "text", " " .. giver } end   -- exception(nullable): nobody known yet
    return Place.runsRow("z:" .. m.decorID, runs, "body", { enabled = true, track = _decorTrack(m, zctx), title = m.name })
end

-- { map, found = { ladder, ... } by name, zctx } for a collected decor's card, else nil.
Selectors:Register("decorQuests.zoneStarts", {
    memoized = true,
    reads = { "session.resolvers.catalog.tick", "account.collection.ownedDecorIDs", UI_PATH .. ".picks",
              "session.resolvers.questStatus.tick", "session.resolvers.questLog.tick", "session.resolvers.staticData.tick",
              "session.identity.factionGroup", "session.identity.raceID", "session.identity.classID" },
    calls = { "decorQuests.trackerTarget", "decorQuests.tracked" },
    fn = function(state, ctx)
        local t = Selectors:Call("decorQuests.trackerTarget", state, ctx)
        local lad = t and t.ladder   -- exception(nullable): nothing tracked, or a campaign waiting for a chapter
        if not (lad and lad.cur == 0 and lad.m and t.ctx.owned[lad.m.decorID]) then return nil end   -- exception(nullable): only a collected decor's card lists more
        local map = lad.steps[lad.rwAt].map
        local zctx = { me = _meOf(state), P = _newProgress(), owned = state.account.collection.ownedDecorIDs,
                       picks = state.session.ui.decorQuests.picks, tracked = Selectors:Call("decorQuests.tracked", state, ctx) }
        local found = {}
        for _, row in pairs(HDG.HousingCatalogObserver.byDecorID) do
            found[#found + 1] = Place.startsIn(row, zctx, map, lad.m.decorID)
        end
        table.sort(found, Place.byName)
        return { map = map, found = found, zctx = zctx }
    end,
})

function Place.zoneMore(out, state, ctx)
    local z = Selectors:Call("decorQuests.zoneStarts", state, ctx)
    if not z then return out end   -- exception(nullable): not a collected decor's card
    local zone, found = _zoneName(z.map), z.found
    if not (zone and found[1]) then return out end   -- exception(nullable): a map with no zone, or none start there
    out[#out + 1] = { kind = "rule", key = "zrule", height = HDG.Constants.DQ_TRACKER.ruleH }
    local head = #found == 1 and L("DQ_TRK_ZONE_MORE_1"):format(zone) or L("DQ_TRK_ZONE_MORE"):format(zone, #found)
    out[#out + 1] = _textRow("zone", head, "text", "body")
    local shown = math.min(#found, HDG.Constants.DQ_ZONE_MORE_MAX)
    for i = 1, shown do out[#out + 1] = Place.zoneRow(found[i], z.zctx) end
    if #found > shown then out[#out + 1] = _textRow("zmore", L("DQ_TRK_ZONE_AND_MORE"):format(#found - shown), "text", "body") end
    return out
end

-- A lone quest's line under the rule: a repeatable's copies ("Daily - you have 2", the count
-- decorQuests.models shows), else what it is. No strip and no count (the Full mockup).
function Strip.lone(t, m)
    if not (m and m.repeats) then return t.sub end   -- exception(nullable): a one-step chapter ends no decor; a decor done once
    local kind = L(m.repeats == "daily" and "DQ_TRK_KIND_DAILY" or "DQ_KIND_REPEATABLE")
    if not HDG.HousingCatalogObserver.byItemID[m.itemID] then return kind end   -- exception(nullable): a catalog lookup misses until it loads (login)
    return L("DQ_TRK_HAVE"):format(kind, HDG.HousingCatalogObserver:OwnedTotal(m.itemID))
end

-- A lone quest's row under the rule: its line, and done on this character the right says so,
-- as "again k/N" does on a ladder (owner 10-30: the tracker said Next on a quest Your
-- characters showed done here).
function Strip.loneRow(t, lad)
    local text = Strip.lone(t, lad.m)
    if not lad.here then return _textRow("sub", text, "text", "body") end
    return { kind = "pair", key = "sub", left = text, right = L("DQ_TRK_DONE_HERE"), height = TRACKER_LINE_H.body + 2 }
end

-- Under a rule, how far along: what it belongs to and the count ("again k/N" on a ladder done
-- before), then the strip; a lone quest just its line (the Full mockup, owner 10-30).
function Strip.progress(out, t)
    out[#out + 1] = { kind = "rule", key = "rule", height = HDG.Constants.DQ_TRACKER.ruleH }
    local lad = t.ladder
    if lad and #lad.steps == 1 then   -- exception(nullable): no ladder while a campaign waits, or for another faction's decor
        out[#out + 1] = Strip.loneRow(t, lad)
        return out
    end
    local right = (lad and lad.done) and L("DQ_TRK_AGAIN_OF"):format(lad.cur, #lad.steps) or t.count   -- exception(nullable): as above
    out[#out + 1] = { kind = "pair", key = "sub", left = t.sub, right = right, height = TRACKER_LINE_H.body + 2 }
    if lad then out[#out + 1] = Strip.row(lad) end   -- exception(nullable): as above
    return out
end

-- A ladder's body: the step to head for first, then under a rule how far along, and expanded,
-- the next steps (the Full mockup, owner 10-30); past the last step, how it ended. A lone
-- quest has no next steps, nor the arrow (trackerCanExpand) to hide them, whatever the saved
-- expanded says.
local function _ladderBody(out, t, lad, expanded)
    if lad.cur == 0 then return _finRows(out, lad, t, t.ctx) end
    _lineRows(out, lad, t.ctx, t.sub)
    Strip.progress(out, t)
    if expanded and #lad.steps > 1 then _nextRows(out, lad, t.ctx.me.side) end
    return out
end

-- A campaign's decor still to come here, each with its chapter and who starts it.
local function _waitPart(m)
    local name, at = _chapterName(m.lineID)
    local text = m.name .. " - " .. name
    local npcID = at.campaign.chapters[at.index][at.side][3]
    local giver = npcID and HDG.NPCNameResolver:ResolveName(npcID, nil)   -- exception(optional): an opener Wowhead names no giver for
    if giver then text = text .. ", " .. L("DQ_GIVER"):format(giver) end   -- exception(nullable): the name is not in yet
    return text
end

-- No chapter on offer: the game picks the next, so name what is still to come.
local function _waitRows(out, t)
    local todo, fresh = {}, 0
    for _, m in ipairs(t.ctx.ms) do
        if not t.ctx.P.here[m.decorID] then todo[#todo + 1] = _waitPart(m) end
    end
    for _, c in ipairs(t.chapters) do
        if c.cp.n == 0 and not c.cp.inLog then fresh = fresh + 1 end
    end
    out[#out + 1] = _textRow("wait", L("DQ_TRK_WAIT"), "text", "body")
    out[#out + 1] = _textRow("wait2", L("DQ_TRK_STILL_TO_COME"):format(table.concat(todo, "; "), fresh), "text", "body")
end

local function _trackerBody(t, expanded)
    local out = {}
    if t.ladder then return _ladderBody(out, t, t.ladder, expanded) end
    if t.finished then
        out[1] = _textRow("fin", L("DQ_TRK_ALL_YOURS"):format(#t.ctx.ms), "success", "subheading")
        return out
    end
    if t.other then
        out[1] = _textRow("other", L("DQ_TRK_OTHER"), "warn", "body")
    else
        _waitRows(out, t)
    end
    return Strip.progress(out, t)
end

-- ----- Compact (Settings > Interface > Quest Tracker, owner 10-30) -----
-- The name and its count in the header, then the step to head for and its place line with the
-- button: no strip, no next steps, no buttons bar (the Compact mockup). Only with a step to
-- head for (an ended, waiting or other faction's tracker reads as Full), and not while
-- expanded: its arrow opens Full, and folds it back.

-- A step to head for.
function Strip.heads(t)
    return t ~= nil and t.ladder ~= nil and t.ladder.cur > 0   -- exception(nullable): nothing tracked, or a campaign waiting for a chapter
end

-- The count after the name: the Full pair row's right ("3/7 done", "again 2/7"); a lone
-- quest a repeatable's copies ("have 2", the Compact mockup), else done here; nil for a lone
-- quest done nowhere.
function Strip.compactCount(t)
    local lad = t.ladder
    if #lad.steps > 1 then return lad.done and L("DQ_TRK_AGAIN_OF"):format(lad.cur, #lad.steps) or t.count end
    local m = lad.m
    if m and m.repeats and HDG.HousingCatalogObserver.byItemID[m.itemID] then   -- exception(nullable): a catalog lookup misses until it loads (login)
        return L("DQ_TRK_HAVE_SHORT"):format(HDG.HousingCatalogObserver:OwnedTotal(m.itemID))
    end
    return lad.here and L("DQ_TRK_DONE_HERE") or nil   -- exception(nullable): a lone quest done nowhere counts nothing
end

Selectors:Register("decorQuests.trackerCompact", {
    reads = { "account.config.decorQuestTrackerStyle", "account.ui.decorQuestTracker.expanded" },
    calls = { "decorQuests.trackerTarget" },
    fn = function(state, ctx)
        if state.account.config.decorQuestTrackerStyle ~= "compact" or state.account.ui.decorQuestTracker.expanded then return false end
        return Strip.heads(Selectors:Call("decorQuests.trackerTarget", state, ctx))
    end,
})

Selectors:Register("decorQuests.trackerFull", {
    calls = { "decorQuests.trackerCompact" },
    fn = function(state, ctx) return not Selectors:Call("decorQuests.trackerCompact", state, ctx) end,
})

Selectors:Register("decorQuests.trackerRows", {
    memoized = true,
    reads = { "account.ui.decorQuestTracker.expanded", "session.resolvers.questTitles.tick", "session.npcNames.names",
              "session.resolvers.fonts.tick", "session.resolvers.questObjectives.tick", "session.resolvers.catalog.tick" },
    calls = { "decorQuests.trackerTarget", "decorQuests.trackerCompact", "decorQuests.zoneStarts" },
    fn = function(state, ctx)
        local t = Selectors:Call("decorQuests.trackerTarget", state, ctx)
        if not t then return { _textRow("empty", L("DQ_TRACKER_EMPTY"), "dim", "body") } end   -- exception(nullable): nothing tracked
        if not Selectors:Call("decorQuests.trackerCompact", state, ctx) then
            return Place.zoneMore(_trackerBody(t, state.account.ui.decorQuestTracker.expanded), state, ctx)
        end
        local out = {}
        _lineRows(out, t.ladder, t.ctx, t.sub, true)
        return out
    end,
})

Selectors:Register("decorQuests.trackerTitle", {
    -- Compact's count: a repeatable's copies, in the scheme's text colour.
    reads = { "session.resolvers.catalog.tick", "account.config.scheme" },
    calls = { "decorQuests.trackerTarget", "decorQuests.trackerCompact" },
    fn = function(state, ctx)
        local t = Selectors:Call("decorQuests.trackerTarget", state, ctx)
        if not t then return L("DQ_TRACKER_TITLE") end   -- exception(nullable): nothing tracked
        local title = t.name
        if t.icon then title = HDG.Format.IconMarkup(t.icon, TRACKER_ICON) .. " " .. title end   -- exception(nullable): a chapter that ends no decor
        local count = Selectors:Call("decorQuests.trackerCompact", state, ctx) and Strip.compactCount(t)
        if not count then return title end   -- exception(nullable): Full, or a lone quest that counts nothing
        return title .. "  " .. HDG.Theme:ColorCode("text.primary") .. count .. "|r"
    end,
})

-- The expand arrow: the tracker heads for a step with steps after it, or for the decor
-- quest itself (expanded, it says so); a lone quest has none (the Full mockup).
Selectors:Register("decorQuests.trackerCanExpand", {
    calls = { "decorQuests.trackerTarget" },
    fn = function(state, ctx)
        local t = Selectors:Call("decorQuests.trackerTarget", state, ctx)
        local lad = t and t.ladder   -- exception(nullable): nothing tracked, or a campaign waiting for a chapter
        return lad ~= nil and lad.cur > 0 and #lad.steps > 1 and (lad.cur < #lad.steps or lad.cur == lad.rwAt)
    end,
})

-- The arrow: next steps to show (trackerCanExpand), or with Compact chosen, Full to open and
-- fold back -- a lone quest's too, which has no next steps.
Selectors:Register("decorQuests.trackerArrow", {
    reads = { "account.config.decorQuestTrackerStyle" },
    calls = { "decorQuests.trackerCanExpand", "decorQuests.trackerTarget" },
    fn = function(state, ctx)
        if Selectors:Call("decorQuests.trackerCanExpand", state, ctx) then return true end
        return state.account.config.decorQuestTrackerStyle == "compact" and Strip.heads(Selectors:Call("decorQuests.trackerTarget", state, ctx))
    end,
})

Selectors:Register("decorQuests.hasTracked", {
    calls = { "decorQuests.tracked" },
    fn = function(state, ctx) return Selectors:Call("decorQuests.tracked", state, ctx) ~= nil end,
})

-- The window: the header (as tall as its title's lines, the Full mockup), the body's rows,
-- the button bar (none in Compact; it stays on an empty tracker, which keeps Details).
Selectors:Register("decorQuests.trackerDynamicRows", {
    memoized = true,   -- the title's real text layout, 3-5 calls a window refresh (review P6)
    calls = { "decorQuests.trackerRows", "decorQuests.trackerTitle", "decorQuests.trackerArrow", "decorQuests.trackerCompact" },
    fn = function(state, ctx)
        local h = TRACKER_BODY_PAD
        for _, row in ipairs(Selectors:Call("decorQuests.trackerRows", state, ctx)) do h = h + row.height end
        -- The title wraps (the Full mockup): a body row's width less the X, the settings cog
        -- and the arrow, each with the header's gap before it.
        local C = HDG.Constants.DQ_TRACKER
        local w = TRACKER_TEXT_W - (C.closeW + C.gap) - (C.cogW + C.gap)
        if Selectors:Call("decorQuests.trackerArrow", state, ctx) then w = w - (C.arrowW + C.gap) end
        local lines = HDG.TextMeasure:Lines("subheading", w, Selectors:Call("decorQuests.trackerTitle", state, ctx))
        local head = math.max(TRACKER_HEADER_H, C.headPad + lines * TRACKER_LINE_H.subheading)
        return { head, h, Selectors:Call("decorQuests.trackerCompact", state, ctx) and 0 or TRACKER_BUTTONS_H }
    end,
})

-- ----- The tracker's buttons -----

-- Ended: past a ladder's last step, or every decor of a campaign collected. Close (it stops
-- tracking) takes Stop tracking's place then (the Full mockup).
Selectors:Register("decorQuests.trackerEnded", {
    calls = { "decorQuests.trackerTarget" },
    fn = function(state, ctx)
        local t = Selectors:Call("decorQuests.trackerTarget", state, ctx)
        if not t then return false end   -- exception(nullable): nothing tracked
        return t.finished == true or (t.ladder ~= nil and t.ladder.cur == 0)   -- exception(nullable): a campaign waiting for a chapter has no ladder
    end,
})

Selectors:Register("decorQuests.trackerLive", {
    calls = { "decorQuests.hasTracked", "decorQuests.trackerEnded" },
    fn = function(state, ctx)
        return Selectors:Call("decorQuests.hasTracked", state, ctx) and not Selectors:Call("decorQuests.trackerEnded", state, ctx)
    end,
})

-- Stop tracking: while it runs, in Full (Compact has no buttons bar).
Selectors:Register("decorQuests.trackerStopShown", {
    calls = { "decorQuests.trackerLive", "decorQuests.trackerCompact" },
    fn = function(state, ctx)
        return Selectors:Call("decorQuests.trackerLive", state, ctx) and not Selectors:Call("decorQuests.trackerCompact", state, ctx)
    end,
})

-- DQ_SHOW's payload and the way in from Decor and Find Decor. Helpers in a table: the file is
-- near Lua's cap of 200 locals.
local Show = {}

-- DQ_SHOW's payload for a decor: By Decor, its row selected, its group unfolded.
function Show.decor(m)
    return { viewMode = "decor", selected = "d:" .. m.decorID, group = _groupKey(m) }
end

-- Details: DQ_SHOW's payload for what is tracked -- the decor in By Decor, else its
-- campaign in By Chain with the chapter open.
Selectors:Register("decorQuests.trackerOpen", {
    calls = { "decorQuests.trackerTarget" },
    fn = function(state, ctx)
        local t = Selectors:Call("decorQuests.trackerTarget", state, ctx)
        if not t then return nil end   -- exception(nullable): nothing tracked
        local m = t.ctx.ms[1]
        if t.key:find("^d:") then return Show.decor(m) end
        return { viewMode = "chain", selected = m.chainKey, group = "C:" .. m.exps[1], chapter = t.ladder and t.ladder.lineID }   -- exception(nullable): a campaign waiting for a chapter opens none
    end,
})

-- ----- The way in from Decor and Find Decor (R4, pick D, owner 10-30) -----
-- Their Quest steps button shows for a decor a quest gives (its catalog row's questID, the
-- test decorQuests.models keeps) and opens Decor Quests on it with Show.decor's payload; a
-- decor two quests give opens on the one this character can take (the model's). Showing the
-- button reads the row alone: the models (about 400 KB) are built on the click, which opens
-- the tab that needs them.

-- The selected item's catalog row when a quest gives it, else nil.
function Show.row(itemID)
    if not itemID then return nil end   -- exception(nullable): nothing selected
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    return row and row.questID and row   -- exception(nullable): the catalog not in yet; a decor no quest gives
end

function Show.item(itemID, state, ctx)
    local row = Show.row(itemID)
    if not row then return nil end   -- exception(nullable): nothing selected, or a decor no quest gives
    return Show.decor(Selectors:Call("decorQuests.models", state, ctx).byDecor[row.decorID])
end

Selectors:Register("decorQuests.decorTabHasSteps", {
    reads = { "session.resolvers.catalog.tick" },
    calls = { "decor.selectedItemID" },
    fn = function(state, ctx) return Show.row(Selectors:Call("decor.selectedItemID", state, ctx)) ~= nil end,
})

Selectors:Register("decorQuests.findHasSteps", {
    reads = { "session.resolvers.catalog.tick" },
    calls = { "acq.selectedItemID" },
    fn = function(state, ctx) return Show.row(Selectors:Call("acq.selectedItemID", state, ctx)) ~= nil end,
})

Selectors:Register("decorQuests.decorTabShow", {
    reads = { "session.resolvers.catalog.tick" },
    calls = { "decor.selectedItemID", "decorQuests.models" },
    fn = function(state, ctx) return Show.item(Selectors:Call("decor.selectedItemID", state, ctx), state, ctx) end,
})

Selectors:Register("decorQuests.findShow", {
    reads = { "session.resolvers.catalog.tick" },
    calls = { "acq.selectedItemID", "decorQuests.models" },
    fn = function(state, ctx) return Show.item(Selectors:Call("acq.selectedItemID", state, ctx), state, ctx) end,
})
