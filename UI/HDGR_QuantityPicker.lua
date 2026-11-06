-- HDGR_QuantityPicker.lua -- combination-lock quantity dialog for buying decor
-- at a vendor (spec s5). Right-click a decor merchant row -> three 0-9 wheels
-- (no carry), what the quantity costs against what you hold, the House Chest
-- before and after the buy, and a Buy button that runs the paced BuyQueue with
-- its progress and time left. Bespoke frame (AcqMapWidget precedent); built once
-- on first Open and reused. Layout: docs/mockups/qty_picker_storage.html,
-- layout E (owner, 2026-11-06).
HDG = HDG or {}
HDG.QuantityPicker = HDG.QuantityPicker or {}
local QP = HDG.QuantityPicker

-- ===== Pure math (headless-tested) ==========================================
function QP.Digits(n)
    n = math.max(0, math.min(HDG.Constants.QTYPICKER_MAX_QTY, math.floor(n or 0)))
    return { math.floor(n / 100) % 10, math.floor(n / 10) % 10, n % 10 }
end

function QP.FromDigits(h, t, o) return h * 100 + t * 10 + o end

-- The quantity a freshly-opened dialog starts on when the active list doesn't
-- want this item. One, so Buy is live on open.
function QP.DEFAULT_DIGITS() return QP.Digits(1) end

-- What `qty` of a slot spends from each wallet, assessed against the balances:
-- the MerchantWallet spend list (have / short / pct / flagged per wallet).
function QP.Spend(costs, qty, wallet)
    local W = HDG.MerchantWallet
    return W.Assess(W.Spend({ { costs = costs, qty = qty } }), wallet)
end

-- Returns (ok, reasonString). `spend` is QP.Spend's list, so every currency the
-- slot charges -- gold, any currency, items taken as payment, or a mix -- is
-- checked the same way, and the refusal names the wallet that is short.
-- Decor storage is NOT checked here: see ResolveCapacity.
function QP.Validate(qty, spend)
    if qty <= 0 then return false, "Pick a quantity" end
    local short = HDG.MerchantWallet.FirstShort(spend)
    if short then return false, "Not enough " .. HDG.MerchantWallet.Name(short) end
    return true, nil
end

-- How many of this item the active list still wants here: the sum over its
-- entries for the item (merchant.stockedFromList rows), as far as the wheels go.
-- 0 when the list doesn't want it.
function QP.ListWant(rows, itemID)
    local n = 0
    for _, s in ipairs(rows) do
        if s.entry.itemID == itemID then n = n + s.entry.qty end
    end
    return math.min(n, HDG.Constants.QTYPICKER_MAX_QTY)
end

-- The Max chip: the most the wallet covers, as far as the wheels go.
function QP.MaxQty(affordable)
    return math.min(affordable, HDG.Constants.QTYPICKER_MAX_QTY)
end

-- The House Chest after buying `qty`: the raw total (the game's "Total Decor
-- Owned"), the room left under the cap (negative = over), and the game's own
-- count, which leaves exempt decor out. Exempt doesn't move: what a vendor
-- sells counts.
function QP.Storage(owned, exempt, cap, qty)
    local after = owned + qty
    return { after = after, free = cap - after, counter = after - exempt }
end

-- Seconds left in a run, or nil until QTYPICKER_ETA_AFTER units have landed (and
-- once all have). Paced from the FIRST landing, not the click: the first unit
-- lags 2-3s (MERCHANT_BUY_TIMEOUT_SECS) and would inflate every later estimate.
-- Counts down between landings, and holds at 1 while a slow unit is awaited.
function QP.Eta(firstLand, lastLand, landed, total, now)
    if landed < HDG.Constants.QTYPICKER_ETA_AFTER or landed >= total then return nil end
    local perUnit = (lastLand - firstLand) / (landed - 1)
    local left = perUnit * (total - landed) - (now - lastLand)
    return math.max(1, math.ceil(left))
end

-- Resolve current decor storage (owned, exempt, cap) from the capacity cache, which
-- the House aggregator refreshes on every storage, bag and catalog trigger -- while
-- a vendor is open, and everywhere once the HDG window has opened this session
-- (its cold-client gate, docs/COLD_CLIENT_CTD_INVESTIGATION.md). A max of 0 is a
-- cold/uninitialised reading -- treated as UNKNOWN (math.huge: no storage block),
-- NOT a real zero cap. Read on every refresh so a paced buy's landed units
-- (resume) reflect in the numbers.
--
-- owned is the raw total, exempt decor included -- the first return of
-- GetDecorTotalOwnedCount, which the game's House Chest tooltip calls "Total
-- Decor Owned". The game's own count ("Storage") is owned less exempt.
--
-- Storage is SHOWN, never a reason to refuse Buy (owner, 2026-11-06). It used to
-- refuse once the raw total passed the cap, without saying so, and lleucu read the
-- dead Buy button as "not enough gold" (Discord 2026-11-05). HDG can't tell where
-- the game will stop taking decor: its counter lags near the cap, and players
-- find the real limit is the raw total. What it won't take goes to the bags --
-- bought and kept, but it can't be added to storage from there until storage has
-- room. So the dialog warns once the raw total would pass the cap, and buys.
function QP.ResolveCapacity(st)
    local cache = st.account.houseCapacityCache   -- exception(nullable): false until the first capture
    if cache and cache.max > 0 then
        return cache.owned, cache.exempt, cache.max
    end
    return 0, 0, math.huge
end

-- NO STOCK CEILING, deliberately. The merchant scan records numAvailable and it
-- is tempting to cap the wheels with it, but housing decor is UNLIMITED stock --
-- there is no limited-supply decor vendor (owner, 2026-08-21). A cap read from
-- numAvailable would therefore only ever be wrong: the field reads -1 for
-- unlimited, and mistaking that for a quantity clamps every purchase to nothing.
--
-- So a run that stops one short is NOT the vendor running dry. It is a purchase
-- that never confirmed -- the reason is on the status line and in the chat log.
--
-- The real ceiling is the wallet, enforced in Validate. Decor storage is shown
-- and warned about, not enforced (ResolveCapacity).

-- True while the player has X'd the picker away at this vendor. Cleared on
-- MERCHANT_SHOW (MerchantObserver), so it never outlives the visit that set it.
-- It used to be cleared on every snapshot of an open vendor, and the vendor is
-- re-snapshotted on each list update -- a buy, a filter change -- so the X
-- lasted until the next one.
function QP:IsOptedOut() return self._optedOut == true end
function QP:ClearOptOut()  self._optedOut = false end

-- ===== Dialog: build ==========================================================
local WHEEL_COUNT = 3   -- 100s / 10s / 1s
local FRAME_W     = 360
local PAD         = 20
local INNER_W     = FRAME_W - 2 * PAD
-- From the top: header 50, wheels to 138, chips to 164, cost lines to ~206
-- (~220 with "You have" on two lines), the House Chest block to ~290, the run bar
-- to ~306, then the status from ~312, with the busy dots under it while a run
-- goes. Auto-close sits 46-70 above the bottom and the buttons 16-40, so 440
-- leaves the status four lines -- or two and the dots -- before it meets them.
-- Still shorter than the merchant frame (444) it opens beside.
local FRAME_H     = 440
local ICON        = 36
local BAR_H       = 8
local ESC_NAME    = "HDGR_QuantityPickerFrame"   -- UISpecialFrames finds it as _G[name]

local function _label(parent, font, justify, role)
    return HDG.UI:Label(parent, "", font, justify, { role = role })
end

local function _bar(parent, variant)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetHeight(BAR_H)
    HDG.Theme:Register(bar, "progressbar", { variant = variant })
    return bar
end

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

-- Any real hide stops a run: Cancel, the X, ESC, the vendor closing, or another
-- window closing this one (UISpecialFrames) -- a run nobody can see or stop must
-- not carry on. Hiding the whole UI (Alt+Z) fires OnHide too, but leaves the
-- window's own shown flag set; a run carries on through that.
local function _onHide(self)
    if self:IsShown() then return end
    if HDG.BuyQueue:IsRunning() then HDG.BuyQueue:Cancel("picker closed") end
    self:SetScript("OnUpdate", nil)
    self._buying, self._done, self._stopping = false, false, false
end

local function _buildShell()
    local f = HDG.UI:Frame(_G.UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetFrameStrata("DIALOG")   -- over the vendor sidebar, which it may cover (owner, 2026-11-06)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)          -- swallow clicks so the merchant behind doesn't get them
    -- Draggable for the session: it opens beside the vendor, and the thing you
    -- want to read can still be behind it. Unnamed, so the client never saves a
    -- dragged position over the beside-the-vendor anchor.
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:Hide()
    HDG.Theme:Register(f, "Canvas")   -- window-body backdrop, matches the main frame
    f:SetScript("OnHide", _onHide)
    -- ESC closes it, as Cancel does.
    _G[ESC_NAME] = f
    table.insert(_G.UISpecialFrames, ESC_NAME)
    return f
end

-- X = "not at this vendor". Cancel dismisses THIS purchase and the picker comes
-- back on the next right-click; the X stands the picker down until the vendor is
-- reopened, so a player who wants Blizzard's one-at-a-time buying can have it
-- without turning the feature off in Settings. Its tooltip says so: the meaning
-- stays (owner, 2026-11-06), and hovering is where a player can find it.
local function _buildHeader(f)
    local close = HDG.UI:CloseButton(f, 22, 12)
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function()
        QP._optedOut = true
        QP:_Close()
    end)
    HDG.TooltipEngine:Attach(close, { recipe = "QtyPickerClose" })
    f._xButton = close

    -- The item's icon, with its tooltip on hover: what is being bought, at a glance.
    local icon = CreateFrame("Frame", nil, f)
    icon:SetSize(ICON, ICON)
    icon:SetPoint("TOPLEFT", PAD, -14)
    icon:EnableMouse(true)
    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetAllPoints()
    f._icon = icon

    local title = _label(f, "heading", "LEFT", "TextHeading")
    title:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    title:SetWidth(INNER_W - ICON - 10 - 16)   -- clear of the X
    title:SetWordWrap(true)
    title:SetMaxLines(2)
    f._title = title
end

local function _buildWheels(f)
    local wheels = CreateFrame("Frame", nil, f)
    wheels:SetSize(WHEEL_COUNT * 44 + (WHEEL_COUNT - 1) * 8, 80)
    wheels:SetPoint("TOP", 0, -(14 + ICON + 8))
    f._digits = QP.DEFAULT_DIGITS()   -- Open() re-stamps this per dialog
    f._numFS  = {}
    local function step(i, dir)
        if f._buying or f._done then return end   -- inert during a buy AND after one completes (button stays "Close")
        local v = f._digits[i] + (dir > 0 and 1 or -1)
        f._digits[i] = (v < 0) and 0 or (v > 9 and 9 or v)   -- clamp 0-9, no carry
        f._refresh()
    end
    for i = 1, WHEEL_COUNT do
        local col, num = _digitColumn(wheels, step, i)
        col:SetPoint("LEFT", (i - 1) * 52, 0)
        f._numFS[i] = num
    end
    f._wheels = wheels
end

-- A chip dials its number into the wheels. Inert while a run goes, like the wheels.
local function _chip(f, setQty)
    local chip = CreateFrame("Button", nil, f)
    HDG.UI:EnsureChipChrome(chip)
    HDG.Theme:Register(chip, "Button", { variant = "chip" })
    chip:SetHeight(20)
    chip:SetScript("OnClick", function()
        if f._buying or f._done then return end
        f._digits = QP.Digits(setQty())
        f._refresh()
    end)
    return chip
end

-- "Max N" (the most the wallet covers) and "List wants N" (the active list's
-- count here, shown only when the list wants this item).
local function _buildChips(f)
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(INNER_W, 20)
    row:SetPoint("TOP", f._wheels, "BOTTOM", 0, -6)
    f._maxChip  = _chip(f, function() return f._maxQty end)
    f._listChip = _chip(f, function() return f._listWant end)
    f._chips = row
end

local function _buildCost(f)
    local total = _label(f, "subheading", "CENTER", "Text")
    total:SetPoint("TOP", f._chips, "BOTTOM", 0, -8)
    total:SetWidth(INNER_W)
    f._total = total

    local have = _label(f, "body", "CENTER", "Text")
    have:SetPoint("TOP", total, "BOTTOM", 0, -4)
    have:SetWidth(INNER_W)
    have:SetWordWrap(true)
    f._have = have
end

-- One label/value row of the House Chest block: the name under `left`, the
-- value under `right`, one anchor each.
local function _storeRow(store, left, right, labelKey)
    local name = _label(store, "body", "LEFT", "Text")
    name:SetPoint("TOPLEFT", left, "BOTTOMLEFT", 0, -6)
    name:SetText(HDG.Locale:Get(labelKey))
    local value = _label(store, "body", "RIGHT", "TextHeading")
    value:SetPoint("TOPRIGHT", right, "BOTTOMRIGHT", 0, -6)
    return name, value
end

-- Two bars, one track: the back bar fills to the raw total AFTER the buy in the
-- warning colour; the front bar is cut to the width of what is owned NOW and
-- filled, so the stretch between them is this buy.
local function _buildStoreBars(store, anchor)
    local back = _bar(store, "warning")
    back:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    back:SetWidth(INNER_W)
    local front = _bar(store, "accent")
    front:SetPoint("TOPLEFT", back, "TOPLEFT")
    front:SetFrameLevel(back:GetFrameLevel() + 1)
    front:SetMinMaxValues(0, 1); front:SetValue(1)
    return back, front
end

-- The House Chest, named as the game names it: the raw total is its "Total
-- Decor Owned" and the count it shows is "Storage" (owner, 2026-11-06 -- players
-- can match each number to what they see in game).
local function _buildStorage(f)
    local store = CreateFrame("Frame", nil, f)
    store:SetSize(INNER_W, 74)
    store:SetPoint("TOP", f._have, "BOTTOM", 0, -10)
    local rule = store:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1); rule:SetPoint("TOPLEFT"); rule:SetPoint("TOPRIGHT")
    HDG.Theme:Register(rule, "Divider")
    local head = _label(store, "small", "LEFT", "TextHeading")
    head:SetPoint("TOPLEFT", 0, -8)
    head:SetText(HDG.Locale:Get("QTYPICKER_CHEST"))
    f._free = _label(store, "small", "RIGHT", "TextSuccess")
    f._free:SetPoint("TOPRIGHT", 0, -8)
    f._backBar, f._frontBar = _buildStoreBars(store, head)
    local ownedName
    ownedName, f._ownedValue = _storeRow(store, f._backBar, f._backBar, "QTYPICKER_TOTAL_OWNED")
    _, f._counterValue = _storeRow(store, ownedName, f._ownedValue, "QTYPICKER_COUNTED")
    f._store = store
end

-- The run's bar, then one status line: a warning, why Buy is refused, or how the
-- run is going. Text, not TextDim: dim text does not read in game.
local function _buildStatus(f)
    local runBar = _bar(f, "success")
    runBar:SetPoint("TOP", f._store, "BOTTOM", 0, -8)
    runBar:SetWidth(INNER_W)
    runBar:Hide()
    f._runBar = runBar

    local status = _label(f, "small", "CENTER", "Text")
    status:SetPoint("TOP", runBar, "BOTTOM", 0, -6)
    status:SetWidth(INNER_W)
    status:SetWordWrap(true)
    f._status = status

    -- The vendor sidebar's busy dots, under the run's line while it runs: a unit
    -- takes about 3s to arrive and nothing else moves meanwhile -- "Bought 0 of
    -- 21" before the first landing, with no time left yet (owner, 2026-11-06).
    local busy = HDG.UI:BusyDots(f)
    busy:SetSize(INNER_W, 12)
    busy:SetPoint("TOP", status, "BOTTOM", 0, -8)
    busy:Hide()
    f._busy = busy
end

local function _buildFooter(f)
    local buy = HDG.UI:Button(f, "", "body")
    buy._hdgrVariant = "primary"
    HDG.Theme:Register(buy, "Button")
    buy:SetSize(110, 24); buy:SetPoint("BOTTOMLEFT", PAD, 16)
    buy:SetScript("OnClick", function() f._onBuy() end)
    f._buy = buy

    local cancel = HDG.UI:Button(f, _G.CANCEL, "body")
    cancel:SetSize(90, 24); cancel:SetPoint("BOTTOMRIGHT", -PAD, 16)
    cancel:SetScript("OnClick", function() QP:_Close() end)   -- closing stops a running buy (_onHide)

    -- A setting, so it is remembered between vendors and sessions.
    local autoClose = HDG.UI:Checkbox(f, HDG.Locale:Get("QTYPICKER_AUTO_CLOSE"), "small")
    autoClose:SetSize(INNER_W, 24)
    autoClose:SetPoint("BOTTOMLEFT", PAD, 46)
    autoClose:SetScript("OnClick", function()
        HDG.Config:Set("MERCHANT_QTY_PICKER_AUTO_CLOSE", autoClose:GetChecked())
    end)
    HDG.TooltipEngine:Attach(autoClose, { recipe = "QtyPickerAutoClose" })
    f._autoClose = autoClose
end

local function _build()
    local f = _buildShell()
    _buildHeader(f)
    _buildWheels(f)
    _buildChips(f)
    _buildCost(f)
    _buildStorage(f)
    _buildStatus(f)
    _buildFooter(f)
    QP._frame = f
    return f
end

-- ===== Dialog: paint ==========================================================
local function _n(v) return _G.BreakUpLargeNumbers(v) end

-- The wallet as the picker reads it: the snapshot MerchantObserver keeps, the
-- same numbers Buy All's confirm and the vendor sidebar show.
local function _wallet() return HDG.Store:GetState().session.merchant.wallet end

local function _qty(f) return QP.FromDigits(f._digits[1], f._digits[2], f._digits[3]) end

-- The wheels and the cost line, together: during a run both count down what is
-- left. The cost line kept the whole run's price while the wheels counted down,
-- and read "x 3 = 150" beside 002 (owner, in-game 2026-11-06).
local function _showQty(f, n)
    local d = QP.Digits(n)
    for i = 1, WHEEL_COUNT do f._numFS[i]:SetText(tostring(d[i])) end
    f._total:SetText(("x %d  =  %s"):format(n, HDG.MerchantWallet.FormatCosts(f._costs, n)))
end

-- Size a chip to its text; both centred as a pair, or Max alone.
local function _layoutChips(f)
    local chips = { f._maxChip }
    if f._listWant > 0 then chips[2] = f._listChip end
    f._listChip:SetShown(f._listWant > 0)
    local widths, sum = {}, 0
    for i, c in ipairs(chips) do
        widths[i] = math.ceil(c:GetFontString():GetStringWidth()) + 20
        sum = sum + widths[i]
    end
    local x = -(sum + 8 * (#chips - 1)) / 2
    for i, c in ipairs(chips) do
        c:SetWidth(widths[i])
        c:ClearAllPoints()
        c:SetPoint("LEFT", f._chips, "CENTER", x, 0)
        x = x + widths[i] + 8
    end
end

local function _paintChips(f, stock)
    f._maxQty = QP.MaxQty(HDG.MerchantWallet.MaxAffordable(stock.costs, _wallet()))
    f._maxChip:SetText(HDG.Locale:Get("QTYPICKER_MAX"):format(f._maxQty))
    f._listChip:SetText(HDG.Locale:Get("QTYPICKER_LIST_WANTS"):format(f._listWant))
    _layoutChips(f)
end

-- Two bars over one track: back to the total after the buy, front cut to what is
-- owned now. Over the cap the front fills the track and the header says by how much.
local function _paintBars(f, owned, after, cap)
    f._backBar:SetMinMaxValues(0, cap)
    f._backBar:SetValue(math.min(after, cap))
    f._frontBar:SetWidth(math.max(1, INNER_W * math.min(owned, cap) / cap))
    f._frontBar:SetShown(owned > 0)
end

local function _paintStorage(f, qty)
    local owned, exempt, cap = QP.ResolveCapacity(HDG.Store:GetState())   -- live: reflects landed units on resume
    f._store:SetShown(cap ~= math.huge)
    if cap == math.huge then return end
    local L, v = HDG.Locale, QP.Storage(owned, exempt, cap, qty)
    local over = v.free < 0
    f._free:SetText(L:Get(over and "QTYPICKER_OVER" or "QTYPICKER_FREE"):format(_n(math.abs(v.free))))
    HDG.Theme:Register(f._free, over and "TextWarning" or "TextSuccess")
    _paintBars(f, owned, v.after, cap)
    f._ownedValue:SetText(L:Get("QTYPICKER_OF_CAP"):format(_n(v.after), _n(cap)))
    f._counterValue:SetText(L:Get("QTYPICKER_PLUS_EXEMPT"):format(_n(v.counter), _n(exempt)))
end

-- What a pick would do that the player should know before buying: storage
-- overflowing to the bags, then every wallet it spends more than half of.
local function _pickWarnings(f, qty, spend)
    local warn = HDG.MerchantWallet.WarnLines(spend)
    local owned, _, cap = QP.ResolveCapacity(HDG.Store:GetState())
    if owned + qty > cap then table.insert(warn, 1, HDG.Locale:Get("QTYPICKER_STORAGE_FULL")) end
    return warn
end

-- The run's own line: landed so far, then the time left once there is a pace,
-- or that Stop is waiting for the unit already on its way.
local function _runLine(f)
    local L = HDG.Locale
    local line = L:Get("QTYPICKER_BOUGHT_OF"):format(f._buyDone, f._buyTotal)
    if f._stopping then return line .. L:Get("QTYPICKER_STOPPING_NOTE") end
    local eta = f._firstLand and QP.Eta(f._firstLand, f._lastLand, f._buyDone, f._buyTotal, GetTime())   -- exception(nullable): no landing yet
    if eta then return line .. L:Get("QTYPICKER_ETA"):format(eta) end
    return line
end

-- After a run: the whole of it in seconds, or how far it got and why it stopped.
local function _resultLine(f)
    local L = HDG.Locale
    if not f._stopReason then
        local secs = math.max(1, math.floor(f._buyEnd - f._buyStart + 0.5))
        return L:Get("QTYPICKER_BOUGHT_IN"):format(f._buyDone, secs)
    end
    -- Your own Stop, said as such: "then stopped: stopped by user" read the word
    -- twice (owner, in-game 2026-11-06). A Stop's reason stands through the
    -- drain, so a stall while it waited still reads as yours.
    if f._userStopped then return L:Get("QTYPICKER_YOU_STOPPED"):format(f._buyDone, f._buyTotal) end
    return L:Get("QTYPICKER_STOPPED"):format(f._buyDone, f._buyTotal, f._stopReason)
end

-- The status line, one of: the run as it goes; the finished run, with why the
-- remainder can't be bought if it can't; or the pick's warnings and refusal.
-- A refused pick names its reason: a red total and a dead Buy button read as
-- "not enough gold" when the block was storage (lleucu, Discord 2026-11-05).
function QP:_RenderStatus()
    local f = self._frame
    f._runBar:SetShown(f._buying)
    f._busy:SetShown(f._buying)
    if f._buying then f._status:SetText(_runLine(f)); return end
    local lines = {}
    if f._buyStart then lines[1] = _resultLine(f) end
    if #f._warnings > 0 and not f._done then
        lines[#lines + 1] = HDG.Theme:ColorCode("semantic.warning") .. table.concat(f._warnings, "\n") .. "|r"
    end
    if f._refusal then
        lines[#lines + 1] = HDG.Theme:ColorCode("semantic.error") .. f._refusal .. "|r"
    end
    f._status:SetText(table.concat(lines, "\n"))
end

-- "You have" each payment the slot draws on, as the wallet holds it now.
local function _paintHave(f, costs)
    local have = {}
    for _, e in ipairs(QP.Spend(costs, 1, _wallet())) do
        have[#have + 1] = HDG.MerchantWallet.FormatAmount(e, e.have)
    end
    f._have:SetText(HDG.Locale:Get("QTYPICKER_HAVE"):format(table.concat(have, "  ")))
end

local function _refreshPick(f, stock)
    local qty   = _qty(f)
    local spend = QP.Spend(stock.costs, qty, _wallet())
    local ok, why = QP.Validate(qty, spend)
    _showQty(f, qty)
    _paintChips(f, stock)
    HDG.Theme:Register(f._total, ok and "Text" or "TextError")   -- re-skin on validity flip
    _paintHave(f, stock.costs)
    _paintStorage(f, qty)
    f._buy:SetText((HDG.Locale:Get("QTYPICKER_BUY")):format(qty))
    f._buy:SetEnabled(ok)
    f._refusal, f._warnings = why, _pickWarnings(f, qty, spend)
    QP:_RenderStatus()
end

function QP:_Close()
    self._frame:Hide()   -- _onHide stops a running buy
end

-- ===== Dialog: a run ==========================================================
-- Landing times for the ETA, taken when the landed count rises.
local function _noteLanding(f, landed)
    if landed <= f._buyDone then return end
    local now = GetTime()
    f._firstLand = f._firstLand or now   -- exception(nullable): unset until the first landing
    f._lastLand  = now
end

-- Every unit asked for arrived: wheels at 0, the tally, and Close.
local function _finishDone(f)
    f._buying, f._done, f._stopping, f._stopReason = false, true, false, nil
    _showQty(f, 0)
    f._buy:SetText(_G.CLOSE)
    f._buy:SetEnabled(true)
    QP:_RenderStatus()
    -- Only a run that bought everything closes itself: a stopped one stays open
    -- with the remainder dialled in.
    if HDG.Store:GetState().account.config.merchantQtyPickerAutoClose then QP:_Close() end
end

-- Stopped or stalled part-way: stay open with the REMAINING count on the wheels,
-- so one more Buy click continues from here.
local function _finishStopped(f)
    f._buying, f._stopping = false, false
    f._stopReason = HDG.BuyQueue:LastStopReason()
    f._digits = QP.Digits(f._buyTotal - f._buyDone)
    f._refresh()
end

-- Drive the countdown wheels and the status line from MERCHANT_BUY_PROGRESS.
-- When the run ends the tally comes from the QUEUE, not from f._buyDone: that
-- cache is fed by progress dispatches, and one missed dispatch was permanent --
-- a run the queue counted 5 of 5 displayed 4, then offered to buy it again.
function QP:_OnProgress()
    local f = self._frame
    if not f._buying then return end
    local b = HDG.Store:GetState().session.merchant.buying   -- exception(nullable): nil once the run has ended
    if not b then
        f:SetScript("OnUpdate", nil)
        f._buyEnd = GetTime()
        f._buyDone, f._buyTotal = HDG.BuyQueue:LastResult()
        if f._buyDone >= f._buyTotal then _finishDone(f) else _finishStopped(f) end
        return
    end
    _noteLanding(f, b.done)
    f._buyDone, f._buyTotal = b.done, b.total
    f._runBar:SetMinMaxValues(0, b.total)
    f._runBar:SetValue(b.done)
    _showQty(f, b.total - b.done)   -- remaining, counting down
    QP:_RenderStatus()
end

-- Buying mode: keep the dialog, wheels count DOWN to remaining, Buy -> Stop.
-- The status repaints a few times a second so the time left counts down
-- between landings.
local function _enterBuying(f, qty)
    f._buying, f._stopping, f._userStopped, f._buyTotal, f._buyDone = true, false, false, qty, 0
    f._buyStart, f._buyEnd, f._firstLand, f._lastLand, f._acc = GetTime(), nil, nil, nil, 0
    f._buy:SetText(HDG.Locale:Get("MERCHANT_STOP"))   -- the game has no STOP string: _G.STOP is nil and left Stop blank
    f:SetScript("OnUpdate", function(self, dt)
        self._acc = self._acc + dt
        if self._acc >= 0.25 then self._acc = 0; QP:_RenderStatus() end
    end)
    QP:_OnProgress()   -- seed the countdown and status at once
end

-- Stop sends nothing more, but the unit already sent still lands (BuyQueue
-- Cancel), so the run may go on a moment: say so, and take no second click.
local function _stopRun(f)
    f._userStopped = true
    HDG.BuyQueue:Cancel("stopped by user")
    if not HDG.BuyQueue:IsRunning() then return end   -- ended at once; _OnProgress has the result
    f._stopping = true
    f._buy:SetText(HDG.Locale:Get("QTYPICKER_STOPPING"))
    f._buy:SetEnabled(false)
    QP:_RenderStatus()
end

local function _startBuy(f, itemID)
    -- The slot is read now, not when the dialog opened: a filter or page change
    -- while it was open moves the item to another index, and buying by the old
    -- one bought whatever sat there.
    local stock = HDG.Store:GetState().session.merchant.byItemID[itemID]   -- exception(nullable): the item can leave the vendor's list while the dialog is open
    if not stock then
        f._refusal = HDG.Locale:Get("QTYPICKER_GONE")
        f._buy:SetEnabled(false)
        QP:_RenderStatus()
        return
    end
    local qty = _qty(f)
    -- Refused now though Buy was live (the wallet moved since the last repaint):
    -- repaint, which greys Buy and names the reason.
    if not QP.Validate(qty, QP.Spend(stock.costs, qty, _wallet())) then f._refresh(); return end
    -- itemID rides along so the queue can watch this item's bag count rise: decor
    -- can land in bags as well as in decor storage.
    local ok, why = HDG.BuyQueue:Enqueue({ { index = stock.index, itemID = itemID, qty = qty,
                                             costs = stock.costs, name = stock.name } })
    if not ok then HDG.Log:Warn("merchant_buy", why); return end   -- reject: stay open to adjust
    _enterBuying(f, qty)
end

-- ===== Open ===================================================================
-- Beside the vendor, over the vendor sidebar if it is showing (owner,
-- 2026-11-06: the sidebar's room is the better use of the screen). Re-anchored
-- on every open, so a drag lasts while the window is up.
local function _place(f)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", _G.MerchantFrame, "TOPRIGHT", HDG.Constants.VENDOR_SIDEBAR_GAP, 0)
end

local function _paintHeader(f, itemID, stock)
    f._title:SetText(stock.name or "?")   -- exception(nullable): MerchantItemInfo.name is nilable while a slot streams in
    f._icon.tex:SetTexture(stock.icon)
    HDG.TooltipEngine:Attach(f._icon, { itemID = itemID })   -- the def is read live: re-attach per item
end

function QP:Open(itemID)
    if HDG.BuyQueue:IsRunning() then return end   -- a buy is mid-flight; keep its picker
    local st    = HDG.Store:GetState()   -- exception(false-positive): top-level dialog open, not a row factory
    local stock = st.session.merchant.byItemID[itemID]
    if not stock then return end          -- exception(nullable): slot vanished (page change) between right-click and open

    local f = QP._frame or _build()
    f._buying, f._done, f._stopping, f._stopReason = false, false, false, nil   -- fresh dialog: not in a buy
    f._buyStart, f._buyEnd = nil, nil                                          -- no run yet: no tally
    f:SetScript("OnUpdate", nil)
    f._autoClose:SetChecked(st.account.config.merchantQtyPickerAutoClose)
    _paintHeader(f, itemID, stock)
    -- Opens on what the active list still wants here, else on 1: nobody opens
    -- this dialog to buy nothing, and 000 left Buy reading "Buy 0".
    f._listWant = QP.ListWant(HDG.Selectors:Call("merchant.stockedFromList", st, {}), itemID)
    f._digits = f._listWant > 0 and QP.Digits(f._listWant) or QP.DEFAULT_DIGITS()
    -- Any price the vendor charges -- gold, a currency, items taken as payment, or
    -- a mix -- goes through the same spend list, so the dialog never branches on
    -- the currency.
    f._costs   = stock.costs
    f._refresh = function() _refreshPick(f, stock) end
    f._onBuy = function()
        if f._done   then QP:_Close(); return end   -- "Close" after a completed buy
        if f._buying then _stopRun(f); return end   -- "Stop": the picker refills with the remainder
        _startBuy(f, itemID)
    end
    _place(f)
    f._refresh()
    f:Show()
end

-- React to the buy queue's progress and to the vendor closing (dismiss the
-- picker when the merchant window goes away). Cheap no-op check when hidden.
HDG.Store:Subscribe(function(actionType)
    local A = HDG.Constants.ACTIONS
    local f = QP._frame
    if not (f and f:IsShown()) then return end
    if actionType == A.MERCHANT_BUY_PROGRESS then
        QP:_OnProgress()
    elseif actionType == A.MERCHANT_WALLET_SET then
        -- The wallet moved: under an open pick, re-judge what it can afford. During
        -- and after a run only "You have" moves -- it stayed at the run's start
        -- while the vendor window showed the gold going (owner, in-game 2026-11-06).
        if f._buying or f._done then _paintHave(f, f._costs) else f._refresh() end
    elseif actionType == A.HOUSE_CAPACITY_CACHED and not f._buying then
        -- The chest's numbers are read 0.1s after each landing (HouseAggregator
        -- debounce), so a run ends before they count its last unit: the stopped
        -- dialog showed the chest one or two short until a wheel was touched
        -- (owner, in-game 2026-11-06). Frozen during a run, where that lag would
        -- make the total after the buy dip and recover with every unit.
        _paintStorage(f, f._done and 0 or _qty(f))
    elseif actionType == A.MERCHANT_SET_STATE
       and not HDG.Store:GetState().session.merchant.open then
        QP:_Close()
    end
end)
