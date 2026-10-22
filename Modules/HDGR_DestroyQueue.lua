-- HDGR_DestroyQueue.lua -- the ONE destroy path for stored decor copies. The
-- Decor tab's destroy dialog and the browser's Ctrl-Shift-click both run here.
--
-- WHY THE TOTAL (live 12.1, 2026-09-19). The client takes every destroy off its
-- stored count at once, kept or not, until /reload, and nothing in the API
-- reports a refusal. What does tell is the item's owned TOTAL (stored + placed +
-- redeemable): the client holds it at the server's figure and papers the gap
-- with a temporary rise in "placed" (HousingCatalogObserver:OwnedTotal). So a
-- copy counts as destroyed only when the total falls, and the on-screen count is
-- always what the server took.
--
-- THE SERVER PAUSES. It takes a burst of destroys, then drops the rest without a
-- word (live 12.1, 2026-09-19: three paced runs of 101 each stopped landing at
-- 26-28). Dropped destroys never land -- each next run started from exactly the
-- total the last one reported. So when nothing lands for DESTROY_DROP_SECS the
-- run writes off what was in flight, waits DESTROY_RETRY_SECS, and sends one
-- destroy at a time until the server takes one again, then goes back to full
-- pace. DESTROY_RETRY_LIMIT tries in a row with nothing landing ends the run.
--
-- PACING: at most DESTROY_IN_FLIGHT_MAX destroys wait on the server at once; the
-- next goes out when the total confirms one.
--
-- STOP drains: nothing new is sent, but destroys already on their way can still
-- land, so the run waits for them (or DESTROY_DROP_SECS) before it reports. A
-- call that throws winds the run down the same way.
--
-- The run's own bookkeeping lives here, like HDGR_BuyQueue's; the Store gets
-- the part the UI shows (DECOR_DESTROY_PROGRESS -> session.destroying).

HDG = HDG or {}
HDG.DestroyQueue = HDG.DestroyQueue or {}
local Q = HDG.DestroyQueue

local function _debug(fmt, ...) HDG.Log:Debug("decor_destroy", fmt:format(...)) end

-- session.destroying = { total, done, name, waiting } while a run is going; nil after.
local function _publish(run)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.DECOR_DESTROY_PROGRESS,
        payload = run and { total = run.total, done = run.confirmed, name = run.name,
                            waiting = run.waiting } or {} })
end

-- Copies the server has taken: how far the owned total has fallen since the
-- start, never more than were sent.
local function _confirmed(run)
    local fallen = run.startTotal - HDG.HousingCatalogObserver:OwnedTotal(run.itemID)
    return math.max(0, math.min(run.sent, fallen))
end

-- Sent, and neither landed nor written off as dropped.
local function _inFlight(run) return run.sent - run.dropped - run.confirmed end

-- Why a run that is winding down ended: a call that threw, or the player's Stop.
local function _stopReason(run) return run.err and "error" or "stopped" end

-- Fires when nothing has landed for DESTROY_DROP_SECS since the last send.
local function _armWatchdog(run)
    if run.watchdog then run.watchdog:Cancel() end
    run.watchdog = C_Timer.NewTimer(HDG.Constants.DESTROY_DROP_SECS, function()
        if Q._run ~= run then return end   -- this run already ended; a newer one is not ours to end
        Q:_OnSilence()
    end)
end

-- The chat line a finished run leaves. reason: nil = every copy confirmed,
-- "stopped" = the player stopped it, "unconfirmed" = the server stopped taking
-- them for good, "error" = a DestroyEntry call threw.
local function _summary(run, reason)
    local noun = run.total == 1 and "copy" or "copies"
    local of = string.format("%d of %d %s of %s", run.confirmed, run.total, noun, run.name)
    if reason == "stopped" then return "Stopped: destroyed " .. of end
    if reason == "unconfirmed" then return "The game stopped taking destroys: destroyed " .. of end
    if reason == "error" then return "Destroy failed: destroyed " .. of end
    return string.format("Destroyed %d %s of %s", run.confirmed, noun, run.name)
end

function Q:IsRunning() return self._run ~= nil end

-- Keep destroys waiting on the server: DESTROY_IN_FLIGHT_MAX at full pace, one
-- at a time while the server is paused.
function Q:_Fill()
    local run = self._run
    local window = run.waiting and 1 or HDG.Constants.DESTROY_IN_FLIGHT_MAX
    while not run.stopping and run.confirmed + _inFlight(run) < run.total and _inFlight(run) < window do
        local ok, err = HDG.HousingCatalogObserver:DestroyEntry(run.entryID)
        if not ok then
            run.err = err
            _debug("DestroyEntry threw after %d sent: %s", run.sent, tostring(err))
            return self:_Drain()
        end
        run.sent = run.sent + 1
        _debug("sent %d (confirmed %d/%d, in flight %d) %s", run.sent, run.confirmed, run.total,
            _inFlight(run), run.name)
    end
    _armWatchdog(run)
end

-- Nothing landed for DESTROY_DROP_SECS: the server dropped what is in flight.
-- Write it off, wait, and try again with one -- unless the run is winding down,
-- or DESTROY_RETRY_LIMIT tries in a row have landed nothing.
function Q:_OnSilence()
    local run = self._run
    -- A stopping run sends nothing more, so it can end now; its count may miss
    -- confirmations still parked behind a sweep, which beats a run that waits on
    -- a searcher that may never answer.
    if run.stopping then return self:_Finish(_stopReason(run)) end
    -- Silence while the catalog holds entry events back for a sweep is HDG's, not
    -- the server's: the confirmations land with the commit (DECOR_CATALOG_READY).
    -- Written off now, the retry destroyed a copy more than asked for.
    if HDG.HousingCatalogObserver:IsSweepPending() then return _armWatchdog(run) end
    local lost = _inFlight(run)
    run.dropped = run.dropped + lost
    run.retries = run.retries + 1
    if run.retries > HDG.Constants.DESTROY_RETRY_LIMIT then return self:_Finish("unconfirmed") end
    _debug("nothing landed for %ds: %d written off as dropped (%d in all); try %d in %ds",
        HDG.Constants.DESTROY_DROP_SECS, lost, run.dropped, run.retries, HDG.Constants.DESTROY_RETRY_SECS)
    if not run.waiting then
        run.waiting = true
        _publish(run)
    end
    run.retryTimer = C_Timer.NewTimer(HDG.Constants.DESTROY_RETRY_SECS, function()
        if Q._run ~= run then return end   -- this run already ended; a newer one is not ours to fill
        Q:_Fill()
    end)
end

-- The item's counts changed: see whether the total confirmed more destroys.
function Q:_OnCounts(decorIDs)
    local run = self._run
    if not run then return end
    local ours = false
    for _, id in ipairs(decorIDs) do if id == run.decorID then ours = true end end
    if not ours then return end
    local confirmed = _confirmed(run)
    if confirmed <= run.confirmed then return end
    run.confirmed = confirmed
    run.dropped = math.min(run.dropped, run.sent - confirmed)   -- a written-off destroy landed after all
    _debug("confirmed %d/%d %s (owned total %d)%s", confirmed, run.total, run.name,
        HDG.HousingCatalogObserver:OwnedTotal(run.itemID),
        run.waiting and string.format(" -- server taking them again after %d tries", run.retries) or "")
    run.retries = 0
    run.waiting = false
    _publish(run)
    if run.confirmed >= run.total or (run.stopping and _inFlight(run) == 0) then
        return self:_Finish(run.stopping and _stopReason(run) or nil)
    end
    self:_Fill()
end

function Q:_Finish(reason)
    local run = self._run
    self._run = nil
    if run.watchdog then run.watchdog:Cancel() end   -- exception(nullable): a first send that throws ends the run before any watchdog is armed
    if run.retryTimer then run.retryTimer:Cancel() end   -- exception(nullable): only a run the server paused has one
    run.confirmed = _confirmed(run)   -- last look: a confirmation may have landed with the timeout
    if run.err then HDG.Log:Warn("decor", "DestroyEntry failed: " .. tostring(run.err)) end
    _debug("finished (%s): sent %d, confirmed %d of %d, written off %d", reason or "done",
        run.sent, run.confirmed, run.total, run.dropped)
    HDG.Log:Info("decor_action", _summary(run, reason))
    _publish(nil)
end

-- target = { entryID, itemID, variantKey, name }. A second Start for the SAME row
-- while its run is going adds to that run (Ctrl-Shift-clicking faster than the
-- server confirms); any other row is refused while a run is going.
function Q:Start(target, count)
    local run = self._run
    if run then
        if run.itemID ~= target.itemID or run.variantKey ~= target.variantKey or run.stopping then
            return false
        end
        run.total = run.total + count
        _publish(run)
        self:_Fill()
        return true
    end
    self._run = { entryID = target.entryID, itemID = target.itemID, variantKey = target.variantKey,
        name = target.name, decorID = HDG.HousingCatalogObserver:GetRow(target.itemID).decorID,
        total = count, sent = 0, confirmed = 0, dropped = 0, retries = 0, waiting = false,
        startTotal = HDG.HousingCatalogObserver:OwnedTotal(target.itemID) }
    _debug("start %d x %s (owned total %d)", count, target.name, self._run.startTotal)
    _publish(self._run)
    self:_Fill()
    return true
end

-- Stop sending; let destroys already on their way land (or time out), then report.
function Q:_Drain()
    local run = self._run
    run.stopping = true
    if _inFlight(run) == 0 then return self:_Finish(_stopReason(run)) end
    _armWatchdog(run)
end

function Q:Stop()
    local run = self._run
    if not run or run.stopping then return end
    _debug("stop requested: sent %d, confirmed %d", run.sent, run.confirmed)
    self:_Drain()
end

-- The catalog observer patches rows, then signals COLLECTION_CATALOG_ROW_COUNTS_UPDATED
-- with the decorIDs that moved. A sweep commit (DECOR_CATALOG_READY) moves counts
-- too without that signal: confirmations parked behind the sweep fold into the
-- snapshot, and their replay finds nothing left to move. Re-read a frame later:
-- _OnCounts dispatches and destroys, and neither may run nested inside another
-- action's subscriber.
function Q:_OnAction(actionType, _, action)
    if not self._run then return end
    local A = HDG.Constants.ACTIONS
    if actionType == A.COLLECTION_CATALOG_ROW_COUNTS_UPDATED then
        local ids = action.payload.decorIDs
        C_Timer.After(0, function() Q:_OnCounts(ids) end)
    elseif actionType == A.DECOR_CATALOG_READY then
        local ids = { self._run.decorID }
        C_Timer.After(0, function() Q:_OnCounts(ids) end)
    end
end

HDG.Modules:Declare({
    name = "DestroyQueue",
    dependencies = { "HousingCatalogObserver" },
    -- No ownsBlizzardNamespaces: the destroy call and the counts come through
    -- HousingCatalogObserver, which owns C_HousingCatalog (ADR-011).
    logTags = {
        decor_destroy = { user = false, level = "debug" },
    },
    onEnable = function(self)
        self._storeToken = HDG.Store:Subscribe(function(actionType, invalidation, action)
            Q:_OnAction(actionType, invalidation, action)
        end)
    end,
    onShutdown = function(self)
        if self._storeToken then
            HDG.Store:Unsubscribe(self._storeToken)
            self._storeToken = nil
        end
    end,
})
