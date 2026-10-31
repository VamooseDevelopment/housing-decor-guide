-- HDG.DecorQuestWatcher
-- ============================================================================
-- Two jobs off the Store's actions:
--
-- 1. The alt scan. While Decor Quests is open -- when it opens, when the catalog lands
-- under it, on a turn-in -- what this character has done of each decor is saved
-- (DQ_ALT_SCANNED into account.decorQuests.alts[charKey]) for the other characters'
-- alts block. Only while the tab is open: the models need the catalog, which loads with
-- the main window.
--
-- 2. Moves the Quest Tracker on when the step it heads for is turned in -- the one move it
-- makes on its own (ruling 10-26; a click on a step or a disc is the player's). A turn-in
-- reaches the Store as QUEST_STATUS_RESOLVED { questID } (QuestNameResolver:OnQuestTurnedIn).
-- The turned-in quest itself is never asked about: its completed flag can land after
-- QUEST_TURNED_IN (the ladder still heads for it) or before (the ladder has already moved
-- past it, from the saved pick). Either way it was the step headed for, and the tracker
-- heads for its any-order group's open step (ruling G), else the next step after it not
-- done here, else (a ladder followed again) the next in order, else past the last: the
-- pick is cleared and the ladder's own end shows. A pick is the quest, not its place. The
-- ladder's last step (the decor quest, a chapter's end) always clears it, so a pick made
-- before finishing never comes back as a replay. Any other turn-in leaves the tracker be.

HDG = HDG or {}
HDG.DecorQuestWatcher = HDG.DecorQuestWatcher or {}
local W = HDG.DecorQuestWatcher

-- The step after `from` to head for: its any-order group's open step, else the next not
-- done here, else the next in order.
local function _nextStep(lad, from)
    local partner = HDG.DecorQuestGroups.PartnerOf(lad.steps, from)
    if partner then return partner end
    for num = from + 1, #lad.steps do
        if lad.steps[num].cat ~= "done" then return num end
    end
    if from < #lad.steps then return from + 1 end
    return nil
end

-- Quest questID's step on the ladder, or nil (and for no quest: no pick).
local function _stepOf(lad, questID)
    for num, s in ipairs(lad.steps) do
        if s.q == questID then return num end
    end
    return nil
end

function W:OnTurnIn(questID)
    local t = HDG.Selectors:Call("decorQuests.trackerTarget", HDG.Store:GetState(), {})
    local lad = t and t.ladder   -- exception(nullable): nothing tracked, or a campaign waiting for a chapter
    if not lad then return end
    local num = _stepOf(lad, questID)
    if not num then return end
    local pick = _stepOf(lad, t.ctx.tracked.picks[lad.pickKey])   -- exception(nullable): a ladder the player never picked on, or its quest left it
    local passed = pick ~= nil and pick <= num and num < lad.cur   -- headed for, its flag already in
    if num ~= lad.cur and num ~= #lad.steps and not passed then return end
    local after = _nextStep(lad, num)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.DQ_PICK_STEP,
                         payload = { key = lad.pickKey, quest = after and lad.steps[after].q, tracked = true } })   -- exception(nullable): past the last step clears the pick
end

-- ===== The alt scan ==========================================================

local function _scanTrigger(actionType, action)
    local A = HDG.Constants.ACTIONS
    if actionType == A.UI_SET_PERSISTENT then return action.payload.key == "view" end
    return actionType == A.MAIN_WINDOW_OPENING or actionType == A.DECOR_CATALOG_READY
        or actionType == A.QUEST_STATUS_RESOLVED
end

-- onlyChanged: a quest event rescans only when the packed progress moved (every step
-- turned in fires one, most touch no decor); opening the tab always stamps the time.
function W:ScanAlt(onlyChanged)
    local state = HDG.Store:GetState()
    local ui, charKey = state.account.ui, HDG.SessionIdentity.GetCharKey(state)
    if not (charKey and ui.mainWindowShown and ui.view == "decorQuests") then return end   -- exception(nullable): identity resolves after the first paint
    local progress = HDG.Selectors:Call("decorQuests.altProgress", state, {})
    if not progress then return end   -- exception(nullable): the catalog has not loaded yet
    local last = state.account.decorQuests.alts[charKey]   -- exception(nullable): this character's first scan
    if onlyChanged and last and last.progress == progress then return end
    local id = state.session.identity
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.DQ_ALT_SCANNED,
                         payload = { charKey = charKey, name = id.name, classFile = id.classFile,
                                     at = _G.time(), progress = progress } })   -- exception(boundary): wall clock for "checked 2 days ago"
end

function W:_OnAction(actionType, action)
    local questEvent = actionType == HDG.Constants.ACTIONS.QUEST_STATUS_RESOLVED
    if questEvent then W:OnTurnIn(action.payload.questID) end
    if _scanTrigger(actionType, action) then W:ScanAlt(questEvent) end
end

HDG.Modules:Declare({
    name = "DecorQuestWatcher",
    dependencies = { "QuestNameResolver" },
    -- Subscribes to the Store, not Blizzard events. No namespace ownership.
    onEnable = function(self)
        self._storeToken = HDG.Store:Subscribe(function(actionType, _, action) W:_OnAction(actionType, action) end)
    end,
    onShutdown = function(self)
        HDG.Store:Unsubscribe(self._storeToken)
        self._storeToken = nil
    end,
})
