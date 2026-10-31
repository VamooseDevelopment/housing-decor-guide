-- HDG.LumberObserver
-- ============================================================================
-- Sole boundary for lumber-related Blizzard API impurity. Watches bag
-- mutations, detects per-lumber-type gain deltas, captures the player's
-- current map coords at the harvest moment, and dispatches LUMBER_HARVESTED.
--
-- Four responsibilities:
--   1. Bag-delta detection (per lumber ID)
--      Cache the last-known total per lumber ID; on every BAG_UPDATE,
--      diff against the live BAG count via BagObserver:GetBagCount. Positive
--      delta -> harvest event(s); negative delta -> consumed (no event,
--      just refresh the cache). SUPPRESSED while a transfer UI (mail /
--      bank / merchant / trade) is open -- lumber gained that way is not a
--      harvest. See the transfer gate above Scan.
--   2. Session bookkeeping (auto-start)
--      First harvest in N_IDLE_SECONDS dispatches LUMBER_SESSION_START so
--      the per-char session record is created with the bag total at
--      session start. Subsequent harvests just dispatch HARVESTED; the
--      reducer updates the active session's lastHarvestAt.
--   3. Blip GC ticker (self-terminating)
--      Armed by a harvest that appends a blip; dispatches LUMBER_BLIP_GC
--      every GC_INTERVAL so the reducer drops blips older than
--      BLIP_TTL_SECONDS (1 hr). Cancels itself once the last blip ages out
--      -- an idle radar produces no dispatch and no C_Timer churn.
--   4. Live heartbeat ticker (self-terminating)
--      Armed on SESSION_START; bumps session.lumber.tick every 1s so the
--      counter panel's duration + rate texts update between harvests.
--      Cancels itself the tick after activeFarmingID clears.
--   5. Warband auto-deposit (opt-in, Helpers > Lumber)
--      On a banker open, if autoDepositLumber is set, moves all bag lumber into
--      the Warband Bank via C_Container.UseContainerItem (command side; no dispatch).
--
-- ownsBlizzardNamespaces = { "C_Map.GetPlayerMapPosition" } -- sub-API claim;
-- ZoneObserver owns GetBestMapForUnit (zone probe). C_Map calls are safe in open-world.

HDG = HDG or {}
HDG.LumberObserver = HDG.LumberObserver or {}
local L = HDG.LumberObserver

-- ===== Tunables ==============================================================
local IDLE_SECONDS    = 15 * 60   -- 15 min idle = new session next harvest
-- BLIP_TTL_SECONDS = 1 hr (matches HDG DECAY.OLD). Distinct from RESPAWN_SECONDS (color cycle);
-- conflating the two dropped blips before their color cycle completed.
local BLIP_TTL_SECONDS = 60 * 60
local GC_INTERVAL      = 60

L.IDLE_SECONDS    = IDLE_SECONDS
L.RESPAWN_SECONDS = BLIP_TTL_SECONDS  -- kept under the old name for back-compat with reducer + tests; semantics widened
L.GC_INTERVAL     = GC_INTERVAL

-- Per-lumber-id last-known bag total. First sweep is conservative (unknown->known = no harvest).
L._lastTotals    = L._lastTotals    or {}
L._lastTotalsAll = L._lastTotalsAll or {}  -- per-id all-storage total (bags+bank+warband); gates harvest vs withdraw
L._initialized   = L._initialized   or false
L._lumberIDSet   = L._lumberIDSet   or nil  -- built lazily from Constants.LUMBER_DATA
L._gcTicker      = L._gcTicker      or nil   -- C_Timer handle; nil when no blips to sweep (self-terminating)
L._liveTicker    = L._liveTicker    or nil   -- C_Timer handle; nil when no active farming session
L._autoDepositDone = L._autoDepositDone or false -- guard: auto-deposit runs once per bank-open

-- Build + cache the lumber-ID set (avoids iterating LUMBER_DATA every BAG_UPDATE).
local function _ensureLumberIDSet()
    if L._lumberIDSet then return L._lumberIDSet end
    local set = {}
    for _, row in ipairs(HDG.Constants.LUMBER_DATA) do
        set[row.id] = true
    end
    L._lumberIDSet = set
    return set
end

-- ===== Player coords boundary ================================================
-- Returns (x, y, mapID) or nil (mid-loading-screen, sub-map without world origin, etc).
-- nil -> skip the blip portion of the dispatch (returning (0,0,0) would collapse
-- worldCache keys + produce bogus out-of-range blips, as hit with the earlier port).
local function _getPlayerCoords()
    if not (_G.C_Map and _G.C_Map.GetBestMapForUnit and _G.C_Map.GetPlayerMapPosition) then
        return nil  -- exception(boundary): C_Map API missing -- shouldn't happen on retail
    end
    local mapID = _G.C_Map.GetBestMapForUnit("player")
    if not mapID or mapID == 0 then return nil end  -- exception(boundary): mid-load-screen
    local pos = _G.C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end                  -- exception(boundary): sub-map without world origin
    local x, y = pos.x, pos.y
    if not x or not y then return nil end           -- exception(boundary): sparse pos struct
    return x, y, mapID
end
L._GetPlayerCoords = _getPlayerCoords  -- exported for tests

-- ===== Transfer gate =========================================================
-- Lumber gained at a vendor, mailbox, bank or trade window is a TRANSFER, not a
-- harvest. This asks whether one of those is open right now.
--
-- It used to REMEMBER instead: a `_suspended` flag latched by MAIL_SHOW /
-- MERCHANT_SHOW / TRADE_SHOW / BANKFRAME_OPENED and cleared by the matching
-- close event. A close that never arrived -- a disconnect at a mailbox, zoning
-- with the banker up, a handler that errored before the clear -- left it latched
-- for the rest of the session. Scan is the only thing that both detects
-- harvests AND kicks the tracker's bag rescan, so one missed event stopped the
-- tracker focusing the lumber being farmed and froze its numbers until the main
-- window was opened. Reported by pxspin 2026-08-21; /reload was the only cure.
--
-- A question cannot get stuck the way a flag can.
local TRANSFER_INTERACTIONS = {
    "Merchant", "MailInfo", "Banker", "AccountBanker", "CharacterBanker", "GuildBanker",
    -- Auctioneer: commodity buys land straight in the bags with the AH open, so
    -- without this a 200-lumber purchase was recorded as a harvest, blip and all.
    "Auctioneer",
}

-- Trade settles ASYNCHRONOUSLY relative to the frame. Blizzard hides TradeFrame on
-- TRADE_CLOSED while BAG_UPDATE is debounced 0.2s behind it, so by the time Scan runs
-- the question "is a trade open?" answers false and 40 traded Ashwood read as a harvest,
-- blip and all (review 2026-08-23). A short grace window after TRADE_CLOSED absorbs
-- whatever lands, and -- unlike the latch the "ask, don't remember" rewrite removed --
-- it cannot get stuck, because it expires on a clock rather than on an event arriving.
local function _now()
    return _G.GetTime and _G.GetTime() or 0  -- exception(boundary): GetTime/time absent in headless harness
end

local TRADE_SETTLE_GRACE = 3   -- seconds

local function _transferUIOpen()
    local PIT = _G.Enum.PlayerInteractionType
    for _, name in ipairs(TRANSFER_INTERACTIONS) do
        if _G.C_PlayerInteractionManager.IsInteractingWithNpcOfType(PIT[name]) then return true end
    end
    -- Trade is the one source with no PlayerInteractionType member, so its frame
    -- is the only thing that can answer. Nil = its UI never loaded = not open.
    local trade = _G.TradeFrame  -- exception(boundary): Blizzard frame, nil until the Trade UI loads
    if trade ~= nil and trade:IsShown() == true then return true end
    -- ...and for TRADE_SETTLE_GRACE seconds after it closed.
    local until_ = L._tradeSettleUntil
    return until_ ~= nil and _now() < until_
end

-- ===== Harvest detection =====================================================
-- Diff current bag total against last-known. First scan is warm-up (records totals, no HARVESTED).

function L:Scan()
    local Bag = HDG.BagObserver
    -- Source gate. Note this does NOT return: the loop below keeps the baseline
    -- moving while a transfer UI is open, so the purchase or withdrawal is
    -- absorbed as it happens. An early return would leave a stale baseline, and
    -- the first scan after the window closed would read the whole transfer as
    -- one enormous harvest.
    local transferring = _transferUIOpen()
    local lumberSet = _ensureLumberIDSet()
    local firstPass = not self._initialized
    self._initialized = true

    for lumberID, _ in pairs(lumberSet) do
        local cur     = Bag:GetBagCount(lumberID)  -- bags ONLY
        local prev    = self._lastTotals[lumberID] or cur  -- first observation = no delta
        local curAll  = Bag:GetTotal(lumberID)             -- all storage (bags+bank+warband)
        local prevAll = self._lastTotalsAll[lumberID] or curAll
        self._lastTotals[lumberID]    = cur
        self._lastTotalsAll[lumberID] = curAll
        if not firstPass and not transferring and cur > prev then
            -- A harvest raises the player's TOTAL holdings (new lumber from the
            -- world). A Warband-bank WITHDRAW raises bags but only MOVES it from
            -- storage, so total is flat -- count only what the total grew by, so
            -- a withdraw (total delta 0) never starts a phantom session.
            local gained = math.min(cur - prev, curAll - prevAll)
            if gained > 0 then
                self:_HandleHarvest(lumberID, gained, cur)
            end
        end
    end
    -- Satellite-window live totals (Discord report 2026-06-11): BagObserver's
    -- own BAG_UPDATE scan is gated requiresMainWindow -- right for the
    -- warehouse, wrong for the lumber tracker farming with the main window
    -- CLOSED. The tracker rows read Bag:GetTotal + session.resolvers.bag.tick, so the
    -- counts froze until End Session / opening the warehouse. Kick the
    -- owner's scan whenever the tracker is on screen (we already own this
    -- debounced BAG_UPDATE for harvest deltas).
    if HDG.Store:GetState().account.lumber.config.windowVisible == true then
        Bag:Scan()
    end
end

-- Single harvest event: maybe auto-start a session, dispatch HARVESTED.
function L:_HandleHarvest(lumberID, qty, currentTotal)
    local state   = HDG.Store:GetState()
    local lumber  = state.session.lumber
    local active  = lumber.activeFarmingID
    local now     = _now()
    local x, y, mapID = _getPlayerCoords()

    -- Session-start: no active session, different lumber type, or idle > IDLE_SECONDS.
    -- An active lumberID always has its record: LUMBER_SESSION_START writes it in
    -- the reduce that sets activeFarmingID, and nothing deletes one.
    local needSessionStart = active ~= lumberID
    if not needSessionStart then
        local session = state.account.lumber.sessions[state.session.identity.charKey][lumberID]
        needSessionStart = (now - session.lastHarvestAt) > IDLE_SECONDS
    end

    if needSessionStart then
        -- Finalize prior session so it logs to farming history before being superseded.
        if active then
            L:FinalizeSession()
        end
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.LUMBER_SESSION_START,
            payload = {
                lumberID   = lumberID,
                timestamp  = now,
                startCount = currentTotal - qty,  -- bag total BEFORE this harvest
            },
        })
        -- Auto-show the lumber window on session start (unless user has
        -- opted out via autoShowOnHarvest = false).
        if state.account.lumber.config.autoShowOnHarvest then
            HDG.Store:Dispatch({
                type = HDG.Constants.ACTIONS.LUMBER_WINDOW_TOGGLE,
                payload = { visible = true },
            })
        end
    end

    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.LUMBER_HARVESTED,
        payload = {
            lumberID = lumberID, qty = qty,
            x = x, y = y, mapID = mapID,
            timestamp = now,
        },
    })

    -- Arm heartbeat AFTER HARVESTED dispatch (keeps action order SESSION_START -> WINDOW_TOGGLE -> HARVESTED).
    if needSessionStart then
        self:_StartLiveTicker()
    end

    -- Ensure GC sweep running when a blip was appended (self-terminates on last blip).
    if x and y and mapID then
        self:_StartGCTicker()
    end
end

-- ===== Periodic GC ticker (self-terminating) =================================
-- Drops expired blips. Armed only when a harvest appends a blip; cancels when
-- blip list is empty (no idle dispatch, no C_Timer churn). Re-armed by next harvest.
function L:_StartGCTicker()
    if self._gcTicker then return end  -- already running
    self._gcTicker = _G.C_Timer.NewTicker(GC_INTERVAL, function()
        if #HDG.Store:GetState().session.lumber.blips == 0 then
            self._gcTicker:Cancel()
            self._gcTicker = nil
            return  -- nothing left to sweep; re-armed by the next harvest
        end
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.LUMBER_BLIP_GC,
            payload = { now = _now() },
        })
    end)
end

-- ===== Live heartbeat ticker (self-terminating) ==============================
-- 1s tick to update duration + rate between harvests. Armed on SESSION_START;
-- cancels when activeFarmingID clears. No idle churn (same shape as GC ticker).
function L:_StartLiveTicker()
    if self._liveTicker then return end  -- already running
    self._liveTicker = _G.C_Timer.NewTicker(1.0, function()
        local state = HDG.Store:GetState()
        local activeID = state.session.lumber.activeFarmingID
        if not activeID then
            self._liveTicker:Cancel()
            self._liveTicker = nil
            return  -- session ended; re-armed by the next SESSION_START
        end
        -- Idle auto-finalize: walk-away session logged + ended before next SESSION_START supersedes.
        local session = state.account.lumber.sessions[state.session.identity.charKey][activeID]
        if (_now() - session.lastHarvestAt) > IDLE_SECONDS then
            L:FinalizeSession()
            return
        end
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.LUMBER_TICK,
            payload = { now = _now() },   -- the clock the duration and blip ages read
        })
    end)
end

-- ===== Session finalization ===================================================
-- FinalizeSession: LUMBER_SESSION_END + LUMBER_HISTORY_PUSH atomic pair.
-- Called by "End Session" button and idle-auto-finalize. No-op if no active session.
function L:FinalizeSession()
    local state    = HDG.Store:GetState()
    local activeID = state.session.lumber.activeFarmingID
    if not activeID then return end  -- exception(boundary): no active session

    local now        = _now()
    local session    = state.account.lumber.sessions[state.session.identity.charKey][activeID]
    local startedAt  = session.startedAt
    local startCount = session.startCount

    -- History needs wall-clock (date() expects Unix epoch); session uses GetTime (client uptime).
    -- Derive: end-wall = time(); start-wall = end - elapsed. Duration preserved.
    local wallNow       = (_G.time and _G.time()) or 0  -- exception(boundary): GetTime/time absent in headless harness
    local startedAtWall = wallNow - math.max(0, now - startedAt)

    -- sessionTotal = current bag count minus startCount. Bag-only to match the
    -- bag-only startCount (harvest detection); bank/warband stock is excluded.
    local total = math.max(0, HDG.BagObserver:GetBagCount(activeID) - startCount)

    -- Zone is best-effort; nil on loading screens.
    local zone = _G.GetRealZoneText and _G.GetRealZoneText() or nil  -- exception(boundary): GetRealZoneText nil between zones

    -- Identity from session (already resolved by SessionIdentity).
    local charName = state.session.identity.name
    local realm    = state.session.identity.realm

    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.LUMBER_SESSION_END,
        payload = { timestamp = now },
    })
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.LUMBER_HISTORY_PUSH,
        payload = {
            lumberID     = activeID,
            charKey      = charKey,
            startedAt    = startedAtWall,
            finalizedAt  = wallNow,
            sessionTotal = total,
            zone         = zone,
            character    = charName,
            realm        = realm,
        },
    })
end

-- "2 Bamboo, 4 Ironwood" -- per-type breakdown of a deposit, sorted by name.
local function _enumerateDeposit(byType)
    local nameByID = {}
    for _, row in ipairs(HDG.Constants.LUMBER_DATA) do
        nameByID[row.id] = row.shortName or row.name
    end
    local rows = {}
    for id, n in pairs(byType) do
        rows[#rows + 1] = { name = nameByID[id] or ("item " .. id), n = n }
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    local parts = {}
    for _, r in ipairs(rows) do parts[#parts + 1] = r.n .. " " .. r.name end
    return table.concat(parts, ", ")
end

-- ===== Warband auto-deposit (opt-in, Helpers > Lumber) =======================
-- On a banker open, if "Auto-deposit lumber" is on and the Warband Bank is
-- usable, move every lumber stack from bags into the Warband Bank. Pure
-- side-effecting command (no dispatch). Harvest detection is suspended for the
-- bank session and the close handler re-snaps the baseline, so the bag drop
-- never reads as a "consumed" delta.
function L:_MaybeAutoDepositLumber()
    if self._autoDepositDone then return end
    if not HDG.Store:GetConfig("autoDepositLumber") then return end
    local Bank, Container, Enum = _G.C_Bank, _G.C_Container, _G.Enum
    -- exception(boundary): bank/container APIs absent in the headless harness + pre-Midnight clients
    if not (Bank and Container and Enum and Enum.BankType) then return end
    local warband = Enum.BankType.Account
    if not warband then return end  -- exception(boundary): BankType.Account name unverified on older clients
    if not (Bank.CanUseBank and Bank.CanUseBank(warband)) then return end  -- exception(boundary): Warband Bank not reachable at this banker
    self._autoDepositDone = true

    local lumberSet  = _ensureLumberIDSet()
    local lastBag    = (Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5  -- exception(boundary): BagIndex absent in headless
    local byType, moved = {}, 0
    for bag = 0, lastBag do
        for slot = 1, (Container.GetContainerNumSlots(bag) or 0) do
            local id = Container.GetContainerItemID(bag, slot)
            if id and lumberSet[id] then
                local info  = Container.GetContainerItemInfo(bag, slot)
                local count = (info and info.stackCount) or 1
                Container.UseContainerItem(bag, slot, nil, warband)
                byType[id] = (byType[id] or 0) + count
                moved = moved + count
            end
        end
    end
    if moved > 0 then
        HDG.Log:Notify("info", "Deposited " .. _enumerateDeposit(byType) .. " to the Warband Bank.")
    end
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "LumberObserver",
    dependencies = { "BagObserver" },  -- we delegate item-count lookups
    ownsBlizzardNamespaces = { "C_Map.GetPlayerMapPosition", "C_PlayerInteractionManager" },
    blizzardEvents = {
        -- BAG_UPDATE debounced: 5-slot stack split fires 5 events; collapse to one scan.
        BAG_UPDATE = { handler = "OnBagUpdate", debounce = 0.2 },
        -- The transfer gate is a QUESTION asked in Scan, not an event latch, so
        -- the only bank events left here are the auto-deposit hooks.
        -- TRADE_CLOSED opens the settle window; the frame is already hidden by then.
        TRADE_CLOSED = { handler = "OnTradeClosed" },
        BANKFRAME_OPENED = { handler = "OnBankFrameOpen"   },
        BANKFRAME_CLOSED = { handler = "OnTransferUIClose" },
        -- Warband/portable banker fires PLAYER_INTERACTION_MANAGER events, not BANKFRAME_*.
        PLAYER_INTERACTION_MANAGER_FRAME_SHOW = { handler = "OnInteractionOpen"  },
        PLAYER_INTERACTION_MANAGER_FRAME_HIDE = { handler = "OnInteractionClose" },
    },
    OnBagUpdate = function()
        L:Scan()  -- the GC + live tickers self-arm from the harvest path now
    end,
    OnTradeClosed     = function() L._tradeSettleUntil = _now() + TRADE_SETTLE_GRACE end,
    OnBankFrameOpen   = function() L:_MaybeAutoDepositLumber() end,
    OnTransferUIClose = function() L._autoDepositDone = false end,
    OnInteractionOpen = function(_, interactionType)
        local PI = _G.Enum.PlayerInteractionType
        if interactionType == PI.Banker or interactionType == PI.AccountBanker then
            L:_MaybeAutoDepositLumber()
        end
    end,
    OnInteractionClose = function(_, interactionType)
        local PI = _G.Enum.PlayerInteractionType
        if interactionType == PI.Banker or interactionType == PI.AccountBanker then
            L._autoDepositDone = false
        end
    end,
})
