-- HDGR_QuantityPicker.lua -- combination-lock quantity dialog for buying decor
-- at a vendor (spec s5). Right-click a decor merchant row -> three 0-9 wheels
-- (no carry), a live total vs gold + decor-storage headroom, and a Buy button
-- that enqueues the paced BuyQueue. Bespoke frame (AcqMapWidget precedent);
-- built once on first Open and reused.
HDG = HDG or {}
HDG.QuantityPicker = HDG.QuantityPicker or {}
local QP = HDG.QuantityPicker

-- ===== Pure math (headless-tested) ==========================================
function QP.Digits(n)
    n = math.max(0, math.min(999, math.floor(n or 0)))
    return { math.floor(n / 100) % 10, math.floor(n / 10) % 10, n % 10 }
end

function QP.FromDigits(h, t, o) return h * 100 + t * 10 + o end

-- The quantity a freshly-opened dialog starts on. One, so Buy is live on open.
function QP.DEFAULT_DIGITS() return QP.Digits(1) end

-- Returns (ok, reasonString). cap = math.huge means "storage data unavailable".
-- `wallet` is whichever balance this item is bought from -- copper for a gold
-- price, Community Coupons for a coupon price -- so one comparison serves both;
-- only the refusal wording differs, and the caller names the currency.
function QP.Validate(price, qty, wallet, owned, cap, currencyLabel)
    if qty <= 0 then return false, "Pick a quantity" end
    if price * qty > wallet then return false, "Not enough " .. (currencyLabel or "gold") end
    if owned + qty > cap then return false, "Not enough decor storage" end
    return true, nil
end

-- ===== Dialog =================================================================
local WHEEL_COUNT = 3   -- 100s / 10s / 1s

local function _digitColumn(parent, onStep, index)
    local col = CreateFrame("Frame", nil, parent)
    col:SetSize(44, 80)
    col:EnableMouseWheel(true)
    col:SetScript("OnMouseWheel", function(_, dir) onStep(index, dir) end)

    local up = HDG.UI:Button(col, "+", "body")
    up:SetSize(30, 20); up:SetPoint("TOP")
    up:SetScript("OnClick", function() onStep(index, 1) end)

    local num = HDG.UI:Label(col, "0", "heading", "CENTER", { role = "Text" })
    num:SetPoint("CENTER")

    local down = HDG.UI:Button(col, "-", "body")
    down:SetSize(30, 20); down:SetPoint("BOTTOM")
    down:SetScript("OnClick", function() onStep(index, -1) end)

    return col, num
end

local FRAME_W = 360
local function _build()
    local f = HDG.UI:Frame(_G.UIParent)
    -- 284 tall: room for a two-line decor name AND a two-line stopped-run note
    -- above the auto-close row and the buttons.
    f:SetSize(FRAME_W, 284)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)                     -- swallow clicks so the merchant behind doesn't get them
    -- Draggable: it opens over the merchant frame, and the thing you want to
    -- read is usually behind it.
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:Hide()
    HDG.Theme:Register(f, "Canvas")   -- window-body backdrop, matches the main frame (Raised was the too-light card surface)

    -- X = "not at this vendor". Cancel dismisses THIS purchase and the picker
    -- comes back on the next right-click; the X stands the picker down until the
    -- vendor is reopened, so a player who wants Blizzard's one-at-a-time buying
    -- can have it without turning the feature off in Settings.
    local close = HDG.UI:CloseButton(f, 22, 12)
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function()
        QP._optedOut = true
        QP:_Close(true)
    end)

    local title = HDG.UI:Label(f, "", "heading", "CENTER", { role = "TextHeading" })
    title:SetPoint("TOP", 0, -12)
    title:SetWidth(FRAME_W - 32)   -- constrain + wrap long decor names instead of overflowing
    title:SetWordWrap(true)
    f._title = title

    -- Three digit wheels, centered as a row; anchored below the title so a
    -- wrapped (two-line) name pushes them down instead of overlapping.
    local wheels = CreateFrame("Frame", nil, f)
    wheels:SetSize(WHEEL_COUNT * 44 + (WHEEL_COUNT - 1) * 8, 80)
    wheels:SetPoint("TOP", title, "BOTTOM", 0, -12)
    f._digits = QP.DEFAULT_DIGITS()   -- Open() re-stamps this per dialog
    f._numFS  = {}
    local function step(i, dir)
        if f._buying or f._done then return end   -- wheels inert during a buy AND after one completes (button stays "Close")
        local v = f._digits[i] + (dir > 0 and 1 or -1)
        f._digits[i] = (v < 0) and 0 or (v > 9 and 9 or v)   -- clamp 0-9, no carry
        f._refresh()
    end
    for i = 1, WHEEL_COUNT do
        local col, num = _digitColumn(wheels, step, i)
        col:SetPoint("LEFT", (i - 1) * 52, 0)
        f._numFS[i] = num
    end

    -- Every line under the wheels is capped to the frame and wraps, like the
    -- title: an unconstrained label ran straight past both edges when a stopped
    -- run appended its reason (Vamoose, 2026-09-19).
    local total = HDG.UI:Label(f, "", "body", "CENTER", { role = "Text" })
    total:SetPoint("TOP", wheels, "BOTTOM", 0, -10)
    total:SetWidth(FRAME_W - 32)
    total:SetWordWrap(true)
    f._total = total

    local info = HDG.UI:Label(f, "", "small", "CENTER", { role = "TextInfo" })
    info:SetPoint("TOP", total, "BOTTOM", 0, -4)
    info:SetWidth(FRAME_W - 32)
    info:SetWordWrap(true)
    f._info = info

    -- Live progress line ("N items purchased in T.TTs"); empty until buying.
    local stats = HDG.UI:Label(f, "", "small", "CENTER", { role = "TextDim" })
    stats:SetPoint("TOP", info, "BOTTOM", 0, -4)
    stats:SetWidth(FRAME_W - 32)
    stats:SetWordWrap(true)
    f._stats = stats

    local buy = HDG.UI:Button(f, "", "body")
    buy:SetSize(110, 24); buy:SetPoint("BOTTOMLEFT", 24, 16)
    buy:SetScript("OnClick", function() f._onBuy() end)
    f._buy = buy

    local cancel = HDG.UI:Button(f, _G.CANCEL, "body")
    cancel:SetSize(90, 24); cancel:SetPoint("BOTTOMRIGHT", -24, 16)
    cancel:SetScript("OnClick", function() QP:_Close(true) end)   -- stop any running buy, then close

    -- Auto-close: its own row just above the buttons, below where a stopped-run
    -- note can wrap to. A setting, so it is remembered between vendors and sessions.
    local autoClose = HDG.UI:Checkbox(f, HDG.Locale:Get("QTYPICKER_AUTO_CLOSE"), "small")
    autoClose:SetSize(FRAME_W - 48, 24)
    autoClose:SetPoint("BOTTOMLEFT", 24, 46)
    autoClose:SetScript("OnClick", function()
        HDG.Config:Set("MERCHANT_QTY_PICKER_AUTO_CLOSE", autoClose:GetChecked())
    end)
    HDG.TooltipEngine:Attach(autoClose, { recipe = "QtyPickerAutoClose" })
    f._autoClose = autoClose

    -- Defensive: any hide path stops the timer + clears buying state.
    f:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        self._buying, self._done = false, false
    end)

    QP._frame = f
    return f
end

function QP:_RenderStats()
    local f = self._frame
    if not f then return end
    local t = (f._buyEnd or GetTime()) - (f._buyStart or GetTime())
    local line = ("%d items purchased in %.2fs"):format(f._buyDone or 0, t)
    -- A run that stopped short says so HERE. Without it the dialog showed
    -- "18 items purchased" beside wheels pre-filled with 1, and the only way to
    -- tell a stop from a miscount was to read the chat log or the wheels.
    -- Its own line: the count and the reason read as two facts, and a long
    -- reason wraps inside the frame instead of trailing the count.
    if f._stopReason then line = line .. "\n" .. f._stopReason end
    f._stats:SetText(line)
end

function QP:_Close(cancelQueue)
    local f = self._frame
    if not f then return end
    if cancelQueue and HDG.BuyQueue:IsRunning() then HDG.BuyQueue:Cancel("picker closed") end
    f._buying, f._done = false, false
    f:SetScript("OnUpdate", nil)
    f:Hide()
end

-- Drive the countdown wheels + stats line from MERCHANT_BUY_PROGRESS.
function QP:_OnProgress()
    local f = self._frame
    if not (f and f._buying) then return end
    local b = HDG.Store:GetState().session.merchant.buying
    if not b then
        -- Buying ended. Completed -> freeze at 0 with the final tally + Close;
        -- cancelled/interrupted -> stay open with the remainder pre-filled.
        --
        -- The tally comes from the QUEUE, not from f._buyDone. That cache is fed
        -- by progress dispatches, and one missed dispatch was permanent: a run
        -- the queue counted 5 of 5 displayed 4, then took the stopped branch and
        -- offered to buy the item again.
        f:SetScript("OnUpdate", nil)
        f._buyEnd = GetTime()
        f._buyDone, f._buyTotal = HDG.BuyQueue:LastResult()
        if (f._buyDone or 0) >= (f._buyTotal or 0) then
            f._buying, f._done, f._stopReason = false, true, nil
            for i = 1, WHEEL_COUNT do f._numFS[i]:SetText("0") end
            f._buy:SetText(_G.CLOSE or "Close")
            QP:_RenderStats()
            -- Only a run that bought everything closes itself: a stopped one stays
            -- open with the remainder dialled in.
            if HDG.Store:GetState().account.config.merchantQtyPickerAutoClose then QP:_Close(false) end
        else
            -- Stopped/stalled mid-batch: stay open, pre-fill the wheels with the
            -- REMAINING count so one more Buy click continues from here.
            f._buying = false
            f._stopReason = HDG.BuyQueue:LastStopReason()
            f._digits = QP.Digits((f._buyTotal or 0) - (f._buyDone or 0))
            QP:_RenderStats()   -- freeze the partial tally + why it stopped
            f._refresh()        -- wheels -> remaining, button -> "Buy N"
        end
        return
    end
    f._buyDone, f._buyTotal = b.done, b.total
    local d = QP.Digits(b.total - b.done)   -- remaining, counting down
    for i = 1, WHEEL_COUNT do f._numFS[i]:SetText(tostring(d[i])) end
    QP:_RenderStats()
end

-- Resolve current decor-storage (owned, cap) from the capacity cache, which the
-- House aggregator refreshes on every storage, bag and catalog trigger whether or
-- not the HDG window is open (the dashboard snapshot itself is only rebuilt while
-- the House or Projects views show, so it is the staler of the two). Persisted, so
-- the last session's reading stands in until the first trigger. A max of 0 is a
-- cold/uninitialised reading -- treated as UNKNOWN (math.huge = no storage gate),
-- NOT a real zero cap (which would block every quantity behind "Not enough decor
-- storage"). Read on every refresh so a paced buy's landed units (resume) reflect
-- in the headroom.
function QP.ResolveCapacity(st)
    local cache = st.account.houseCapacityCache   -- exception(nullable): false until the first capture
    if cache and cache.max > 0 then
        return cache.owned, cache.max
    end
    return 0, math.huge
end

-- NO STOCK CEILING, deliberately. The merchant scan records numAvailable and it
-- is tempting to cap the wheels with it, but housing decor is UNLIMITED stock --
-- there is no limited-supply decor vendor (owner, 2026-08-21). A cap read from
-- numAvailable would therefore only ever be wrong: the field reads -1 for
-- unlimited, and mistaking that for a quantity clamps every purchase to nothing.
--
-- So a run that stops one short is NOT the vendor running dry. It is a purchase
-- that never confirmed -- the reason is on the stats line and in the chat log.
--
-- The real ceilings are decor storage (ResolveCapacity) and the wallet, both
-- enforced in Validate.
-- True while the player has X'd the picker away at this vendor. Cleared when a
-- vendor is opened (MerchantObserver), so it never outlives the visit that set it.
function QP:IsOptedOut() return self._optedOut == true end
function QP:ClearOptOut()  self._optedOut = false end

function QP:Open(itemID)
    if HDG.BuyQueue:IsRunning() then return end   -- a buy is mid-flight; keep its picker
    local st    = HDG.Store:GetState()   -- exception(false-positive): top-level dialog open, not a row factory
    local stock = st.session.merchant.byItemID[itemID]
    if not stock then return end          -- exception(nullable): slot vanished (page change) between right-click and open

    local f = QP._frame or _build()
    f._buying, f._done, f._stopReason = false, false, nil   -- fresh dialog: not in a buy
    f:SetScript("OnUpdate", nil)
    f._stats:SetText("")
    f._autoClose:SetChecked(st.account.config.merchantQtyPickerAutoClose)
    f._title:SetText(stock.name or "?")
    -- Opens on 1, not 0: nobody opens this dialog to buy nothing, and 000 meant
    -- the Buy button read "Buy 0" and sat disabled until you clicked a wheel.
    f._digits = QP.DEFAULT_DIGITS()

    -- Coupon-priced decor buys from the Community Coupons wallet, not gold
    -- (madaileinhatter, Discord 2026-08-12). Everything below reads through
    -- these three so the dialog is currency-agnostic rather than branching.
    local couponPrice = stock.couponPrice or 0   -- exception(optional): gold slots carry no coupon price
    local isCoupon    = couponPrice > 0
    local unitPrice   = isCoupon and couponPrice or stock.price
    local currencyLabel = isCoupon and "Community Coupons" or "gold"
    local function _wallet()
        return isCoupon and HDG.BuyQueue.CouponBalance() or GetMoney()  -- exception(boundary): live wallet at the moment of pick
    end
    local function _fmt(amount)
        return isCoupon and (("%d coupons"):format(amount)) or HDG.Format.FormatGold(amount)
    end

    f._refresh = function()
        for i = 1, WHEEL_COUNT do f._numFS[i]:SetText(tostring(f._digits[i])) end
        local qty   = QP.FromDigits(f._digits[1], f._digits[2], f._digits[3])
        local money = _wallet()
        local owned, cap = QP.ResolveCapacity(HDG.Store:GetState())   -- live: reflects landed units on resume + guards cold max==0
        local ok    = QP.Validate(unitPrice, qty, money, owned, cap, currencyLabel)
        f._total:SetText(("x %d  =  %s"):format(qty, _fmt(unitPrice * qty)))
        HDG.Theme:Register(f._total, ok and "Text" or "TextError")   -- re-skin on validity flip
        -- Show PROJECTED storage (current + this purchase), so it climbs toward
        -- the cap as you dial the wheels -- and reads red-over-cap via the total.
        local storageStr = (cap == math.huge) and ""
            or ("   .   " .. HDG.Locale:Get("QTYPICKER_STORAGE")):format(owned + qty, cap)
        f._info:SetText((HDG.Locale:Get("QTYPICKER_HAVE")):format(_fmt(money)) .. storageStr)
        f._buy:SetText((HDG.Locale:Get("QTYPICKER_BUY")):format(qty))
        f._buy:SetEnabled(ok)
    end

    f._onBuy = function()
        if f._done   then QP:_Close(false); return end                       -- "Close" after a completed buy
        if f._buying then HDG.BuyQueue:Cancel("stopped by user"); return end  -- "Stop" -> halt; picker refills with the remainder
        local qty = QP.FromDigits(f._digits[1], f._digits[2], f._digits[3])
        local owned, cap = QP.ResolveCapacity(HDG.Store:GetState())
        local okv = QP.Validate(unitPrice, qty, _wallet(), owned, cap, currencyLabel)
        if not okv then return end
        -- bagItemID, NOT itemID: a coupon buy arrives in bags and the queue
        -- confirms it by watching that item's bag count rise, but `itemID` is
        -- what _ReflectToList decrements a shopping-list entry by. Picker buys
        -- have never touched the list, and needing the id for counting is no
        -- reason to change that -- an entry with no npcID would have matched.
        local ok, why = HDG.BuyQueue:Enqueue({ { index = stock.index, qty = qty, bagItemID = itemID,
                                                 price = stock.price, couponPrice = stock.couponPrice,
                                                 name = stock.name } })
        if not ok then HDG.Log:Warn("merchant_buy", why); return end   -- reject: stay open to adjust
        -- Buying mode: keep the dialog, wheels count DOWN to remaining, Buy -> Stop.
        f._buying, f._buyTotal, f._buyDone = true, qty, 0
        f._buyStart, f._buyEnd, f._acc = GetTime(), nil, 0
        f._buy:SetText(_G.STOP or "Stop")
        f:SetScript("OnUpdate", function(self, dt)
            self._acc = (self._acc or 0) + dt
            if self._acc >= 0.1 then self._acc = 0; QP:_RenderStats() end
        end)
        QP:_OnProgress()   -- seed the countdown + stats immediately
    end

    f._refresh()
    f:Show()
end

-- React to the buy queue's progress (live countdown/timer) + vendor close (dismiss
-- the picker when the merchant window goes away). Cheap no-op check when hidden.
HDG.Store:Subscribe(function(actionType)
    local A = HDG.Constants.ACTIONS
    -- Opening a vendor re-arms the picker after it was X'd away. Checked BEFORE
    -- the is-shown guard below -- the picker is hidden at exactly this moment,
    -- which is the point. Keyed on the vendor OPENING rather than closing so a
    -- close event that never arrives cannot leave the picker disabled forever.
    if actionType == A.MERCHANT_SET_STATE
       and HDG.Store:GetState().session.merchant.open then
        QP:ClearOptOut()
    end
    local f = QP._frame
    if not (f and f:IsShown()) then return end
    if actionType == A.MERCHANT_BUY_PROGRESS then
        QP:_OnProgress()
    elseif actionType == A.MERCHANT_SET_STATE
       and not HDG.Store:GetState().session.merchant.open then
        QP:_Close(true)
    end
end)
