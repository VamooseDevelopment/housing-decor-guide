-- HDGR_BuyQueue.lua -- paced merchant purchase queue (spec s6). The ONE buy
-- path: both Buy All and the quantity picker enqueue here. Pacing is mandatory --
-- a tight loop blows the server burst cap (~13-15) AND strands items in real bag
-- slots; paced buys go straight to decor storage (spec s2.1/s2.2 live probes).
--
-- Default pacing is EVENT-DRIVEN (MERCHANT_BUY_TICK_SECS == 0): buy one unit, then
-- buy the next only when the previous LANDS -- in the House Chest (neighbourhood
-- gold vendors) or in the bags (most other vendors; owner, 2026-11-06). Landing is
-- COUNTED, not signalled: every signal that might mean an arrival -- the catalog's
-- COLLECTION_CATALOG_ROW_COUNTS_UPDATED, a sweep's DECOR_CATALOG_READY, BAG_UPDATE
-- -- only prompts a recount of this run's items in the chest and the bags
-- (_LandedCount). Only ever one buy in flight, so it can't outrun the server
-- (burst cap) or strand items in bags, and it wastes no fixed delay.
-- A stall WATCHDOG (MERCHANT_BUY_TIMEOUT_SECS) only guards against a genuinely dropped
-- landed signal hanging the picker: if nothing lands for that long it STOPS the batch
-- (it never advances -- advancing with a buy in flight is what stranded items in bags).
-- Set MERCHANT_BUY_TICK_SECS > 0 to fall back to the legacy fixed-interval ticker.
-- C_Timer here is a functional throttle, not a UI transition (allowed).
--
-- Scope: anything with a READABLE price -- gold, any currency, items taken as
-- payment, or a mix (Core/HDGR_MerchantWallet.lua). A slot whose price could not
-- be read (still streaming in) is refused rather than bought blind, and so is a
-- run any wallet cannot cover. It was gold and Community Coupons only until the
-- vendor sidebar (2026-11-02).
HDG = HDG or {}
HDG.BuyQueue = HDG.BuyQueue or {}
local Q = HDG.BuyQueue
local W = HDG.MerchantWallet

local function _dispatchProgress(total, done)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MERCHANT_BUY_PROGRESS,
                         payload = total and { total = total, done = done } or {} })
end

function Q:IsRunning() return self._running == true end

-- Why the last run stopped, or nil if it finished. The picker shows this: the
-- dialog is what the player is looking at, and leaving the reason only in the
-- chat log meant a stopped run read as a miscount.
function Q:LastStopReason() return self._stopReason end

-- The run's final tally, readable after it ends. The picker used to accumulate
-- this from progress dispatches and read its own cache when the run finished --
-- so a dispatch it missed was lost for good, and a 5-of-5 run displayed 4 while
-- the queue had counted correctly (owner, in-game 2026-08-21). Asking the queue
-- cannot drift: there is one number and it is the queue's.
function Q:LastResult() return self._landed or 0, self._total or 0 end

local function _stop(self)
    self._running      = false
    self._awaitingLand = false
    self._stopping     = nil
    if self._ticker  then self._ticker:Cancel();  self._ticker  = nil end
    if self._timeout then self._timeout:Cancel(); self._timeout = nil end
end

-- The one way a run ends: reason nil means everything asked for arrived.
local function _end(self, reason)
    _stop(self)
    self._stopReason = reason
    _dispatchProgress(nil)
    if reason then
        HDG.Log:Warn("merchant_buy", ("Buying stopped (%s) -- %d of %d bought")
            :format(reason, self._landed, self._total))
    else
        HDG.Log:Success("merchant_buy", ("Bought %d item(s)"):format(self._total))
    end
end

-- Stop buying. Nothing more is sent, but a unit already sent is still on its
-- way, and the picker's "buy the rest" reads LastResult: ending at once left
-- that unit out of the tally, so Stop then Buy bought one more than the player
-- asked for. The run ends when that unit lands, or when the watchdog gives up
-- on it -- the destroy queue drains the same way. A closed vendor ends the run
-- at once, a run already waiting included: no dialog is left to read the tally,
-- and the next vendor opened must not inherit the run. The first reason stands.
function Q:Cancel(reason)
    if not self._running then return end
    self._stopping = self._stopping or reason   -- exception(nullable): set by the first stop only
    if self._awaitingLand and HDG.Store:GetState().session.merchant.open then return end
    _end(self, self._stopping)
end

-- Why these rows will not start, or nil when they can. The wallet is the state
-- snapshot MerchantObserver keeps -- the same numbers the confirm and the picker
-- showed -- so the refusal and what the player read cannot disagree.
-- Housing dyes are bag items with no catalog row. Every other item a run buys is
-- decor, and its arrival in the chest is counted from its catalog row.
local function _countedInChest(itemID) return not HDG.Constants.HOUSING_DYE_ITEM_IDS[itemID] end

local function _refusal(rows, merchant)
    if not merchant.open then return HDG.Locale:Get("MERCHANT_REFUSE_CLOSED") end
    local total = 0
    for _, r in ipairs(rows) do
        if #r.costs == 0 then
            return HDG.Locale:Get("MERCHANT_REFUSE_UNREAD"):format(r.name or "?")   -- exception(nullable): MerchantItemInfo.name is nilable while a slot streams in
        end
        -- No row, no count to start from: a unit that went to the chest could
        -- never be counted, and the run would stop on it as lost. Buy All lists
        -- items before the catalog has loaded; it loads at the vendor in a moment.
        if _countedInChest(r.itemID) and not HDG.HousingCatalogObserver:GetRow(r.itemID) then   -- exception(nullable): the catalog may still be loading
            return HDG.Locale:Get("MERCHANT_REFUSE_CATALOG")
        end
        total = total + r.qty
    end
    if total == 0 then return HDG.Locale:Get("MERCHANT_REFUSE_NOTHING") end
    local short = W.FirstShort(W.Assess(W.Spend(rows), merchant.wallet))
    if short then return W.ShortLine(short) end
    return nil
end

-- One merchant index per unit: stackCount==1 decor -> qty>maxStack is
-- server-REJECTED (spec s2), so every unit is its own BuyMerchantItem(idx, 1).
-- Each unit also keeps the item it is meant to be, which _fireNext checks the
-- slot against, and the run counts how many of each item it asks for, which the
-- bag watch caps at.
local function _flatten(rows)
    local flat, flatItem, asked = {}, {}, {}
    for _, r in ipairs(rows) do
        for _ = 1, r.qty do
            flat[#flat + 1] = r.index
            flatItem[#flatItem + 1] = r.itemID
        end
        asked[r.itemID] = (asked[r.itemID] or 0) + r.qty
    end
    return flat, flatItem, asked
end

-- THE CHEST AND THE BAGS ARE WATCHED FOR EVERY RUN, whatever it was paid with,
-- and for EVERY item in it: how many of each the player owns in the chest (its
-- catalog row's total) and holds in the bags, read once here as the baseline.
--
-- This used to be gated on the item having a coupon price -- inferring WHERE a
-- purchase lands from HOW IT WAS PAID FOR. Dennia Silvertongue sells gold-priced
-- decor that goes straight to the player's bags and never reaches decor storage,
-- so a gold run watched only the storage signal, which could not arrive: the gold
-- was spent, the item was in the bags, and the picker reported "0 items
-- purchased" after its full 8s stall (Alora + owner, in-game 2026-08-31).
-- Payment method is not destination. Both signals mean the same thing -- the
-- purchase arrived -- and accepting either fails safe where accepting one fails
-- shut.
--
-- It also watched only the FIRST row's item. With Buy All taking every currency
-- (2026-11-02) a run of two items that both land in bags became ordinary, and
-- the second item never moved the first one's count: the run stalled after the
-- first item. So each item in the run keeps its own baseline, read once here.
-- The chest's three figures for the trace (stored, placed, redeemable): the
-- total alone cannot say which of them moved.
local function _chestParts(itemID)
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    return ("stored %d placed %d redeemable %d"):format(row.quantity, row.numPlaced, row.remainingRedeemable)
end

local function _watchArrivals(self, asked)
    self._watch = {}
    for itemID, n in pairs(asked) do
        local w = { asked = n, bags0 = HDG.BagObserver:GetBagCount(itemID) }
        local chest = "not counted"
        if _countedInChest(itemID) then
            w.chest0 = HDG.HousingCatalogObserver:OwnedTotal(itemID)
            chest = ("%d (%s)"):format(w.chest0, _chestParts(itemID))
        end
        self._watch[itemID] = w
        HDG.Log:Debug("merchant_buy", ("watching %d: %d asked, bags %d, chest %s")
            :format(itemID, n, w.bags0, chest))
    end
end

-- Send the next unit, or return false when its slot no longer holds its item.
-- An index is only a position on the vendor's list, and the list can change
-- under a run: a filter change, a limited item selling out, or another vendor
-- opened while the last unit was still landing. Buying by a stale index bought
-- whatever sat there now, so the slot is read at the moment of buying.
local function _fireNext(self)
    local n = self._done + 1
    if GetMerchantItemID(self._flat[n]) ~= self._flatItem[n] then return false end
    self._done = n
    BuyMerchantItem(self._flat[n], 1)
    return true
end

-- rows: { {index, itemID, qty, costs, name}, ... }. Returns true, or false + reason.
-- The shopping list is credited elsewhere (MerchantObserver's purchase credit),
-- so a unit only needs what this queue watches for its own landing.
function Q:Enqueue(rows)
    if self._running then return false, HDG.Locale:Get("MERCHANT_REFUSE_RUNNING") end
    local why = _refusal(rows, HDG.Store:GetState().session.merchant)
    if why then return false, why end
    local flat, flatItem, asked = _flatten(rows)
    self._flat, self._flatItem, self._total, self._done = flat, flatItem, #flat, 0
    self._running, self._stopping, self._stopReason = true, nil, nil   -- a fresh run owns its own outcome
    _watchArrivals(self, asked)
    self._landed = 0   -- units CONFIRMED arrived; _done is units SENT
    _dispatchProgress(self._total, 0)
    if HDG.Constants.MERCHANT_BUY_TICK_SECS > 0 then
        self._ticker = C_Timer.NewTicker(HDG.Constants.MERCHANT_BUY_TICK_SECS, function() Q:_TimerTick() end)
    else
        Q:_BuyNext()   -- event-driven: buy one, then wait for the landed signal
    end
    return true
end

-- Event-driven: buy the next unit; wait for its "landed" signal (or the safety
-- timeout) before buying the following one.
function Q:_BuyNext()
    if not self._running then return end
    -- Done when the ITEMS ARE HERE, not when the buys were fired. Keying this on
    -- _done meant a run could end with everything sent and the last arrival still
    -- outstanding -- which is the accounting that reported 18 of 19.
    if self._landed >= self._total then _end(self, nil); return end
    if self._stopping then _end(self, self._stopping); return end
    if not HDG.Store:GetState().session.merchant.open then _end(self, "vendor closed"); return end
    if self._done < self._total and not _fireNext(self) then
        _end(self, HDG.Locale:Get("MERCHANT_SLOT_CHANGED")); return
    end
    -- Waiting either way: for the unit just fired, or -- when everything has been
    -- fired and an arrival is still outstanding -- for that one. Dropping the wait
    -- state in the second case would leave the run hung with no watchdog.
    self._awaitingLand = true
    -- No progress dispatch here. _done is the unit now IN FLIGHT, not a finished
    -- one, and reporting it as done told the picker "1 of 1" the instant a single
    -- buy was fired: the wheels hit 0 remaining while the button still said Stop,
    -- and a stall or a user Stop then satisfied done >= total and was reported as
    -- a completed purchase. Progress is dispatched from _Confirm, on arrival.
    -- Stall watchdog: if NOTHING lands for this long, STOP (never advance -- advancing
    -- with a buy still in flight is what strands items in bags).
    self._timeout = C_Timer.NewTimer(HDG.Constants.MERCHANT_BUY_TIMEOUT_SECS, function()
        self._timeout = nil
        Q:_OnStall()
    end)
end

-- The watchdog fired: nothing confirmed for MERCHANT_BUY_TIMEOUT_SECS.
--
-- LOOK BEFORE GIVING UP. The watchdog used to treat "no confirmation" as "did
-- not happen", and that is not the same thing: a 13-item coupon run spent 26
-- coupons and put 13 items in the player's bags while the picker reported 12,
-- because the last item's BAG_UPDATE never reached us (owner, in-game
-- 2026-08-21). The item was there the whole time -- only the signal was missing,
-- and the bag count says so plainly. So a late confirmation is still a
-- confirmation. Only a unit that really is absent stops the run.
--
-- The stop names both places it looked, unless the player had already pressed
-- Stop: then the run was waiting out its last unit, and their reason stands.
function Q:_OnStall()
    if not (self._running and self._awaitingLand) then return end
    local counted = self:_LandedCount()
    if counted > self._landed then
        HDG.Log:Debug("merchant_buy", "landing signal missed -- counted from the chest and bags instead")
        self:_Confirm(counted)
        return
    end
    _end(self, self._stopping or HDG.Locale:Get("MERCHANT_STALLED"))
end

-- Something may have arrived: a catalog count moved (any decor's -- a placement,
-- another purchase, a second update for the unit already counted), a sweep
-- committed, or the bags changed. Recount, and move on only if this run's count
-- rose. Each of these used to BE an arrival: the chest side took any count signal
-- as the unit landing, so a second signal for the same unit sent the next one while
-- it was still on its way -- two in flight, and the server put one in the bags
-- with the chest half empty, while the picker's count jumped by two (owner,
-- in-game 2026-11-06). The destroy queue counts its confirmations the same way.
--
-- The bags' prompt is MerchantObserver's BAG_UPDATE, not BagObserver's
-- BAG_INVENTORY_UPDATED: BagObserver gates its scan on the main window, and buying
-- at a vendor with the window closed is the normal case. The counts still come
-- from BagObserver, which owns C_Item.GetItemCount (ADR-011).
--
-- A UNIT IN THE BAGS AND THE CHEST AT ONCE IS ON ITS WAY: wait for it to settle.
-- The game shows a chest decor in the bags for a moment while it moves it into the
-- chest, so the chest's count rises with the bag copy still there, and the copy goes
-- about half a second later. Taking that moment at its word booked the unit and sent
-- the next, and the bag update 0.05s later read the same doubled count as the next
-- unit landing -- two in flight, the count a unit ahead (owner's barrel run,
-- 2026-11-06: "counted 2, booked 1, 2 sent -- bags +1 chest +1"). So a count above
-- the units sent, with an item gained in both places, is not read until it settles:
-- the bag copy going fires BAG_UPDATE, which recounts, and the watchdog covers a copy
-- that never goes. Copies looted into the bags alone are only capped, as before:
-- the chest has not moved, so nothing is on its way.
--
-- Every recount is traced with what it READ: the confirms logged nothing before,
-- so the doubled count showed only as the count running ahead of the arrivals.
local function _verdict(self, settling, landed)
    if settling then return ", in the bags and the chest at once -- waiting for it to settle" end
    if landed > self._landed then return ", LANDED" end
    return ""
end

function Q:_Recount(trigger)
    if not (self._running and self._awaitingLand) then return end
    local counted, both = self:_Counted()
    local landed = math.min(counted, self._done)
    local settling = both and counted > self._done
    HDG.Log:Debug("merchant_buy", ("%.2f %s: counted %d, booked %d of %d, %d sent%s -- %s")
        :format(GetTime(), trigger, counted, self._landed, self._total, self._done,
                _verdict(self, settling, landed), self:_Readout()))
    if settling or landed <= self._landed then return end
    self:_Confirm(landed)
end

-- What a recount reads, per item: how far the bags and the chest have moved
-- since the run began, before any cap, and the chest's three figures now.
function Q:_Readout()
    local parts = {}
    for itemID, w in pairs(self._watch) do
        local line = ("%d bags %+d"):format(itemID, HDG.BagObserver:GetBagCount(itemID) - w.bags0)
        if w.chest0 then
            line = line .. (" chest %+d (%s)"):format(
                HDG.HousingCatalogObserver:OwnedTotal(itemID) - w.chest0, _chestParts(itemID))
        end
        parts[#parts + 1] = line
    end
    return table.concat(parts, "; ")
end

-- How many units have arrived: per item, how many more of it the chest and the
-- bags hold than when the run began, capped at what was asked of it (_Counted);
-- never more than the units sent. THE count -- recomputed from scratch, not a tally.
--
-- It used to be a per-unit ledger: each unit captured its own "before" count and
-- was confirmed when that count rose. That lost exactly one item per run, every
-- run -- 19 bought/18 counted, 13/12, 5/4 -- because each _BuyNext re-read the
-- count as the NEXT unit's baseline, so anything arriving between a confirmation
-- and that re-read was absorbed into the baseline and never counted again
-- (owner, in-game 2026-08-21). A count cannot drift like that: a missed,
-- coalesced or doubled event costs nothing, and two items arriving in one
-- window are both seen.
--
-- The two places ADD UP. A unit ends up in one of them -- decor that stays in the
-- bags stays there until it is clicked into storage (spec s2.1) -- and a run can
-- be split between them: neighbourhood gold vendors fill the chest and the rest go
-- to the bags once it is full. A unit going to the chest is seen in both for a
-- moment on its way; _Recount waits that out. The gains are added BEFORE the cap,
-- so a copy the player clicks from the bags into the chest mid-run moves between
-- them and counts once, and copies taken out of the bags offset copies that came in.
-- Also says whether any item has gained in BOTH places, which a unit on its way
-- to the chest does.
function Q:_Counted()
    local n, both = 0, false
    for itemID, w in pairs(self._watch) do
        local bags, chest = HDG.BagObserver:GetBagCount(itemID) - w.bags0, 0
        if w.chest0 then chest = HDG.HousingCatalogObserver:OwnedTotal(itemID) - w.chest0 end
        n = n + math.max(0, math.min(bags + chest, w.asked))
        both = both or (bags > 0 and chest > 0)
    end
    return n, both
end

-- Capped at the units sent, so copies of the item looted mid-run cannot count
-- as purchases that were never made.
function Q:_LandedCount() return math.min((self:_Counted()), self._done) end

-- Book an arrival and move on. Shared by both landing signals and the watchdog,
-- so it is recorded identically however it was noticed. Never moves the count
-- back: copies taken out of the bags mid-run lower the recount, not the units
-- that already arrived. Deferred a frame so the progress dispatch is not nested
-- inside the signalling subscriber's dispatch cycle.
function Q:_Confirm(landed)
    self._awaitingLand = false
    if self._timeout then self._timeout:Cancel(); self._timeout = nil end
    self._landed = math.max(self._landed, landed)
    C_Timer.After(0, function()
        -- Stopped in the frame between: Cancel has already cleared the progress,
        -- and dispatching it again here left the picker stuck on "Stop".
        if not self._running then return end
        _dispatchProgress(self._total, self._landed)
        Q:_BuyNext()
    end)
end

-- The shopping list is NOT touched here. Every buy -- this queue's and
-- Blizzard's own -- is credited to the active list by MerchantObserver's
-- purchase credit when it lands, so a queue-side decrement would count twice.

-- Legacy fixed-interval path (MERCHANT_BUY_TICK_SECS > 0).
function Q:_TimerTick()
    if not HDG.Store:GetState().session.merchant.open then
        _end(self, "vendor closed"); return
    end
    local k = HDG.Constants.MERCHANT_BUY_TICK_QTY
    while k > 0 and self._done < self._total do
        if not _fireNext(self) then _end(self, HDG.Locale:Get("MERCHANT_SLOT_CHANGED")); return end
        k = k - 1
    end
    -- Legacy path gets no landed signal, so initiated is the only count it has.
    self._landed = self._done
    if self._done >= self._total then _end(self, nil)
    else _dispatchProgress(self._total, self._landed) end
end

-- Recount when the catalog's counts move: a patched row (COUNTS_UPDATED) or a
-- sweep's commit, which moves counts without that signal (DECOR_CATALOG_READY,
-- as the destroy queue also watches). React to the ACTIONS -- do NOT re-register
-- HOUSING_STORAGE_ENTRY_UPDATED (the catalog observer owns that namespace). The
-- bags' BAG_UPDATE comes from MerchantObserver. Cheap no-op check when idle.
HDG.Store:Subscribe(function(actionType)
    local A = HDG.Constants.ACTIONS
    if actionType == A.COLLECTION_CATALOG_ROW_COUNTS_UPDATED or actionType == A.DECOR_CATALOG_READY then
        Q:_Recount(actionType)
    end
end)
