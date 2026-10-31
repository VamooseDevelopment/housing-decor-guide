-- HDG.QuestNameResolver
-- ============================================================================
-- The quest surface (sole owner of C_QuestLog, ADR-011): five facades on four
-- resolver ticks (Core/HDGR_Store.lua registers them):
--   IsComplete -> questStatus  "has this character finished the quest (or a variant)?"
--                              QUEST_TURNED_IN bumps it, then RecordCompletions
--                              persists newly-completed decor quests.
--   IsCompleteOnAccount -> questStatus  the same question for any character of the
--                              warband (the game's account flag, the quest log's
--                              "warband completed" mark).
--   IsOnQuest  -> questLog     "is the quest in this character's log?" QUEST_ACCEPTED
--                              and QUEST_REMOVED bump it (debounced).
--   IsReadyForTurnIn -> questObjectives  "are the quest's objectives done?" (the Quest
--                              Tracker's "ready to turn in"); QUEST_WATCH_UPDATE bumps it.
--   GetTitle   -> questTitles  the quest's title in the client's language, or nil
--                              until the game has it. A miss asks the game once
--                              (QuestEventListener); arrivals coalesce into one
--                              QUEST_TITLES_RESOLVED per batch window.
-- Decor Quests is the title consumer: its ladder names every step, most of which no
-- catalog row carries. Titles are not copied into state -- the game keeps them, and
-- the tick tells the selectors to ask again.

HDG = HDG or {}
HDG.QuestNameResolver = HDG.QuestNameResolver or {}
local R = HDG.QuestNameResolver

-- [questID] = true once a title was asked for. A load that fails clears its
-- callbacks without firing (AsyncCallbackSystemMixin), so a quest the game cannot
-- name stays "Quest #<id>" for the session and is never asked for again.
R._titleRequested = R._titleRequested or {}
R._titleDrainScheduled = false
R.TITLE_BATCH_WINDOW = 0.5   -- seconds; one dispatch for a burst of arrivals (as ItemNameResolver)

function R:IsOnQuest(questID)
    return C_QuestLog.IsOnQuest(questID)
end

-- The quest's objectives are done: the read Blizzard's own tracker makes (QuestMixin:IsComplete).
function R:IsReadyForTurnIn(questID)
    return C_QuestLog.IsComplete(questID)
end

-- The title, or nil while the game has not loaded the quest (it answers nil cold).
function R:GetTitle(questID)
    local title = C_QuestLog.GetTitleForQuestID(questID)
    if title and title ~= "" then return title end   -- exception(boundary): GetTitleForQuestID is nil on a cold quest cache
    self:_RequestTitle(questID)
    return nil
end

local function _drainTitles()
    R._titleDrainScheduled = false
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.QUEST_TITLES_RESOLVED })
end

-- Any arrival schedules the one drain: the selectors re-ask for every title they show.
local function _onTitleLoaded()
    if R._titleDrainScheduled then return end
    R._titleDrainScheduled = true
    C_Timer.After(R.TITLE_BATCH_WINDOW, _drainTitles)
end

-- AddCallback calls RequestLoadQuestByID itself for the first callback on an ID.
function R:_RequestTitle(questID)
    if self._titleRequested[questID] then return end
    self._titleRequested[questID] = true
    QuestEventListener:AddCallback(questID, _onTitleLoaded)
end

function R:IsComplete(questID)
    if not questID then return nil end
    if type(questID) == "table" then
        for _, id in ipairs(questID) do
            if C_QuestLog.IsQuestFlaggedCompleted(id) then return true end
        end
        return false
    end
    return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
end

-- Any character of the warband finished the quest (or a variant).
function R:IsCompleteOnAccount(questID)
    if type(questID) ~= "table" then return C_QuestLog.IsQuestFlaggedCompletedOnAccount(questID) end
    for _, id in ipairs(questID) do
        if C_QuestLog.IsQuestFlaggedCompletedOnAccount(id) then return true end
    end
    return false
end

-- Scan quest-sourced decor for completed quests; persist unattributed ones
-- (first char to record wins). Per-character -- builds account-wide set as
-- you log onto alts. row.questID is a number OR {ids} variant set.
function R:RecordCompletions()
    local obs = HDG.HousingCatalogObserver
    if not (obs and obs.byDecorID) then return end
    local state    = HDG.Store:GetState()
    local identity = state.session.identity
    local name     = identity.name               -- session.identity is factory-seeded (strict read)
    if not name or name == "" then return end   -- exception(boundary): empty until SessionIdentity resolves
    local class    = identity.classFile
    local recorded = state.account.questCompletions
    local batch
    local function tryRecord(qid)
        if qid and not recorded[qid] and C_QuestLog.IsQuestFlaggedCompleted(qid) then
            batch = batch or {}
            batch[qid] = { name = name, class = class }
        end
    end
    for _, row in pairs(obs.byDecorID) do
        local qid = row.questID
        if type(qid) == "table" then
            for _, id in ipairs(qid) do tryRecord(id) end
        else
            tryRecord(qid)
        end
    end
    if batch then
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.QUEST_COMPLETION_RECORDED,
            payload = { completions = batch },
        })
    end
end

-- QUEST_TURNED_IN(questID, ...) -> repaint open quest-completion surfaces, then
-- record the (possibly newly-completed) decor quests for this character.
function R:OnQuestTurnedIn(questID)
    if not questID then return end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.QUEST_STATUS_RESOLVED,
        payload = { questID = questID },
    })
    R:RecordCompletions()
end

HDG.Modules:Declare({
    name = "QuestNameResolver",
    dependencies = {},
    ownsBlizzardNamespaces = { "C_QuestLog" },   -- ADR-011: sole owner
    blizzardEvents = {
        -- Not window-gated: a turn-in with HDG closed was dropped, so its decor
        -- quest waited for the next catalog load to be recorded, and satellites
        -- showing [QUST] chips stayed stale. Recording walks the loaded catalog
        -- once per turn-in (cheap; nothing to walk before the first load).
        QUEST_TURNED_IN        = { handler = "OnQuestTurnedIn" },
        -- The log's contents, for Decor Quests' "In your log". Not window-gated either:
        -- a quest taken with the window closed must read in the log when it opens.
        -- Decor Quests reads this tick beside questStatus, so a QUEST_REMOVED after a
        -- turn-in asks IsComplete again, later than QUEST_TURNED_IN does.
        QUEST_ACCEPTED         = { handler = "OnQuestLogChanged", debounce = 0.3 },
        QUEST_REMOVED          = { handler = "OnQuestLogChanged", debounce = 0.3 },
        -- Objective progress, on any quest in the log (Blizzard's quest map auto-watches on
        -- it, so it is not limited to watched quests): the tracker's "ready to turn in". The
        -- debounce lets the log's own QUEST_LOG_UPDATE land before IsComplete is read.
        QUEST_WATCH_UPDATE     = { handler = "OnQuestObjectivesChanged", debounce = 0.3 },
    },
    OnQuestTurnedIn = function(self, questID)
        R:OnQuestTurnedIn(questID)
    end,
    OnQuestLogChanged = function(self)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.QUEST_LOG_CHANGED })
    end,
    OnQuestObjectivesChanged = function(self)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.QUEST_OBJECTIVES_CHANGED })
    end,
    onEnable = function(self)
        -- Scan on catalog-ready, then re-scan on each turn-in.
        -- Together they build the account-wide completion set across alts.
        HDG.Store:Subscribe(function(actionType)
            if actionType == HDG.Constants.ACTIONS.DECOR_CATALOG_READY then
                R:RecordCompletions()
            end
        end)
    end,
})
