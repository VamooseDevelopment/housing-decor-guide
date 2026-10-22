-- HDG.QuestNameResolver
-- ============================================================================
-- Quest COMPLETION surface (sole owner of C_QuestLog, ADR-011). Quest TITLES
-- come from baked catalog data; the async title-resolution apparatus this
-- module once mirrored from ItemNameResolver was never consumed by any
-- selector and was removed in the 2026-07-13 hygiene review (git remembers).
--
-- IsComplete answers "has the player finished this quest (or any variant)?";
-- QUEST_TURNED_IN bumps session.resolvers.questStatus.tick so [QUST] chips
-- repaint live, then RecordCompletions persists newly-completed decor quests.

HDG = HDG or {}
HDG.QuestNameResolver = HDG.QuestNameResolver or {}
local R = HDG.QuestNameResolver

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
    },
    OnQuestTurnedIn = function(self, questID)
        R:OnQuestTurnedIn(questID)
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
