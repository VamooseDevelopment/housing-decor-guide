-- HDGR_MerchantObserver.lua -- session.merchant snapshot for the vendor-buying
-- surface (spec docs/HDGR_VENDOR_BUYING_SPEC.md). Owns C_MerchantFrame + the
-- MERCHANT_* events. READ side only: scans the open merchant and dispatches the
-- snapshot. The BUY side (paced queue) lives in HDGR_BuyQueue.lua and consumes
-- this state; the right-click override (Task 6) also installs from here.
HDG = HDG or {}
HDG.MerchantObserver = HDG.MerchantObserver or {}
local MO = HDG.MerchantObserver
local A   -- ACTIONS alias, bound lazily in handlers (Constants loads before Modules)

-- NB: no merchant npcID. UnitGUID("npc") is a SECRET string at instanced vendors
-- (e.g. MOTHER in the Chamber of Heart) and throws on :match under addon taint
-- (Reference/MIDNIGHT_SECRET_VALUES.md). The scan keys everything off itemID, so
-- npcID was never read -- don't reintroduce the GUID parse.

-- ===== Prices: every slot's cost as components ===============================
-- HDG buys with anything a vendor charges -- gold, any currency, items taken as
-- payment, or a mix (the shape is in Core/HDGR_MerchantWallet.lua). It used to
-- take gold and, from 2026-08-12, Community Coupons only.
--
-- Classified the way Blizzard's merchant does (MerchantFrame.lua,
-- MerchantFrame_UpdateAltCurrency and the shift-click split):
-- GetMerchantItemCostInfo(index) is how many components the slot has, and
-- GetMerchantItemCostItem(index, i) -> texture, value, link, currencyName over
-- i = 1..MAX_ITEM_COST, skipping empty components. A component with a
-- currencyName is a currency; a link without one is an item paid as currency.
--
-- A component that is there but not readable yet -- no link or no value while
-- the slot streams in -- makes the WHOLE price unreadable: costs comes back
-- empty, nothing buys the slot, and the next MERCHANT_UPDATE rescans it.
local W = HDG.MerchantWallet

local function _currencyCost(value, link, currencyName, texture)
    local id = HDG.HouseAggregator:CurrencyIDFromLink(link)
    if not id then return nil end   -- exception(boundary): currency link not resolvable yet
    return { kind = "currency", key = "currency:" .. id, id = id, amount = value,
             name = currencyName, icon = texture }
end

local function _itemCost(value, link, texture)
    local id   = tonumber(link:match("item:(%d+)"))
    local name = link:match("|h%[(.-)%]|h")
    if not (id and name) then return nil end   -- exception(boundary): item link not fully streamed in
    return { kind = "item", key = "item:" .. id, id = id, amount = value, name = name, icon = texture }
end

-- One extended-cost component: a cost table, false for an empty component, or
-- nil for one that is there but not readable yet.
local function _costComponent(index, i)
    local texture, value, link, currencyName = GetMerchantItemCostItem(index, i)  -- exception(boundary): classic non-namespaced merchant global
    if not texture then return false end   -- empty component: Blizzard skips these too
    if not (link and value and value > 0) then return nil end   -- exception(boundary): slot still streaming in
    if currencyName then return _currencyCost(value, link, currencyName, texture) end
    return _itemCost(value, link, texture)
end

-- The extended-cost components, or nil when any is unreadable or fewer were
-- read than the slot declares.
local function _extendedCosts(index, declared)
    local out = {}
    for i = 1, HDG.Constants.MERCHANT_MAX_COST_COMPONENTS do
        local cost = _costComponent(index, i)
        if cost == nil then return nil end
        if cost then out[#out + 1] = cost end
    end
    if #out ~= declared then return nil end   -- exception(boundary): a declared component has not streamed in
    return out
end

local function _readCosts(index, info)
    local declared = GetMerchantItemCostInfo(index) or 0   -- exception(boundary): classic non-namespaced merchant global
    local extended = {}
    if declared > 0 then
        extended = _extendedCosts(index, declared)
        if not extended then return {} end   -- unreadable price: buy nothing
    end
    local costs = {}
    if info.price > 0 then costs[1] = { kind = "gold", key = W.GOLD_KEY, amount = info.price } end
    for _, cost in ipairs(extended) do costs[#costs + 1] = cost end
    return costs
end

-- numAvailable is carried for display only. Do NOT cap a bulk buy with it:
-- housing decor is unlimited stock (see HDGR_QuantityPicker:Open).
local function _scan()
    local byItemID = {}
    for i = 1, GetMerchantNumItems() do
        local itemID = GetMerchantItemID(i)
        local info   = C_MerchantFrame.GetItemInfo(i)
        if itemID and info then   -- exception(boundary): slots stream in; nil rows on an early MERCHANT_UPDATE
            byItemID[itemID] = { index = i, name = info.name, icon = info.texture,
                                 numAvailable = info.numAvailable,
                                 isPurchasable = info.isPurchasable,
                                 costs = _readCosts(i, info) }
        end
    end
    return byItemID
end

-- ===== Wallet: what the player holds of everything this vendor charges ======
-- In state so the selectors (Buy All confirm, sidebar footer, picker) stay pure.
-- Gold always; a currency or payment item for each the vendor's prices name.
-- The reads go through each namespace's owner: C_CurrencyInfo is HouseAggregator's,
-- C_Item.GetItemCount is BagObserver's (ADR-011).
local function _balance(cost)
    if cost.kind == "currency" then return HDG.HouseAggregator:CurrencyQuantity(cost.id) end
    return HDG.BagObserver:GetVendorPaymentCount(cost.id)
end

local function _readWallet(byItemID)
    local wallet = { [W.GOLD_KEY] = GetMoney() }
    for _, stock in pairs(byItemID) do
        for _, cost in ipairs(stock.costs) do
            if wallet[cost.key] == nil then wallet[cost.key] = _balance(cost) end
        end
    end
    return wallet
end

local function _sameWallet(a, b)
    for key, have in pairs(a) do
        if b[key] ~= have then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

function MO:ScanNow()
    A = HDG.Constants.ACTIONS
    local byItemID = _scan()
    HDG.Store:Dispatch({ type = A.MERCHANT_SET_STATE, payload = {
        open = true, byItemID = byItemID, wallet = _readWallet(byItemID),
    }})
end

-- Money, currency or bags changed. Only the open vendor's wallet is kept, and an
-- unchanged one is not re-dispatched: a buy fires several of these per unit.
function MO:RefreshWallet()
    local m = HDG.Store:GetState().session.merchant
    if not m.open then return end
    local wallet = _readWallet(m.byItemID)
    if _sameWallet(wallet, m.wallet) then return end
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MERCHANT_WALLET_SET, payload = { wallet = wallet } })
end

-- ===== Right-click quantity-picker override (spec s5.1) =====================
-- Wrap each merchant item button's OnClick: a right-click on a DECOR slot opens
-- HDG's quantity picker; everything else (left-click pickup, non-decor rows, the
-- Buyback tab) goes to the button's own handler. Restored on close so the frame
-- is never left altered. Gated behind MERCHANT_QTY_PICKER so a patch that
-- re-templates the buttons can be worked around with one toggle.

-- Decor with a readable price on the vendor's own tab, at a vendor the picker
-- was not X'd away from. The Buyback tab reuses the same buttons with GetID()
-- as the buyback index, so a right-click there must buy back, not open the
-- picker for whatever the vendor lists at that number.
local function _pickerTakes(itemID)
    if MerchantFrame.selectedTab ~= 1 then return false end
    local stock = itemID and HDG.Store:GetState().session.merchant.byItemID[itemID]   -- exception(nullable): an empty slot, or one the snapshot has not seen
    return stock and W.IsBuyable(stock) and not HDG.QuantityPicker:IsOptedOut()
        and HDG.HousingCatalogObserver:GetRow(itemID) ~= nil   -- exception(nullable): non-decor rows delegate to Blizzard
end

-- Wrap one merchant item button. Called for Blizzard's MerchantItemN buttons on
-- MERCHANT_SHOW, and for every slot Krowi's Extended Vendor UI draws
-- (MerchantOverlay's plugin hook): that addon hides Blizzard's buttons and draws
-- its own from the same template, so wrapping only Blizzard's left right-click
-- buying one at a time wherever its vendor sidebar was on (owner, in-game
-- 2026-11-06).
--
-- Keyed by button, with our wrapper kept beside the handler it wraps. A button
-- whose script was set again since -- the other addon redrawing it -- is wrapped
-- again around the new handler, and restoring puts a handler back only where
-- ours is still the one installed.
function MO:WrapBuyButton(btn)
    if not HDG.Config:Get("MERCHANT_QTY_PICKER") then return end
    MO._wrapped = MO._wrapped or {}
    local orig = btn:GetScript("OnClick")
    local seen = MO._wrapped[btn]
    if seen and orig == seen.wrapper then return end   -- exception(nullable): a button not wrapped yet
    local function wrapper(self, mouseButton, down)
        local itemID = GetMerchantItemID(self:GetID())
        if mouseButton == "RightButton" and _pickerTakes(itemID) then
            HDG.QuantityPicker:Open(itemID)
        elseif orig then   -- exception(nullable): a button with no click handler of its own
            orig(self, mouseButton, down)
        end
    end
    MO._wrapped[btn] = { orig = orig, wrapper = wrapper }
    btn:SetScript("OnClick", wrapper)
end

-- Whether a right-click on this button opens the picker for this item: the
-- button carries our wrapper now, and the picker takes the item. The vendor's
-- item tooltip says so on this (TooltipDecorator), so right-click is not the
-- only place the picker can be found.
function MO:PickerHint(owner, itemID)
    local w = MO._wrapped and MO._wrapped[owner]   -- exception(nullable): nothing wrapped outside a vendor, and most tooltip owners never are
    return w ~= nil and owner:GetScript("OnClick") == w.wrapper and _pickerTakes(itemID)
end

-- DISCOVER the buttons; do not assume how many there are. Blizzard's stock page
-- is MERCHANT_ITEMS_PER_PAGE = 10, but a UI that widens the merchant frame gets
-- MerchantItem11ItemButton and beyond -- and a hardcoded 1..10 left those without
-- the override, so the quantity picker worked on the first ten items of a page
-- and fell through to ordinary buying on every one after them. At Dennia
-- Silvertongue that was the picker opening for slot 1 and not for slot 11 of the
-- same page (owner, in-game 2026-09-01).
--
-- The cap is a runaway guard, not a page size: stop at the first missing button.
local MERCHANT_BUTTON_SCAN_CAP = 60

local function _installClickOverrides()
    for i = 1, MERCHANT_BUTTON_SCAN_CAP do
        local btn = _G["MerchantItem" .. i .. "ItemButton"]
        if not btn then break end   -- exception(boundary): first gap ends the frame's button run
        MO:WrapBuyButton(btn)
    end
end

local function _removeClickOverrides()
    if not MO._wrapped then return end
    for btn, w in pairs(MO._wrapped) do
        if btn:GetScript("OnClick") == w.wrapper then btn:SetScript("OnClick", w.orig) end
    end
    MO._wrapped = nil
end

-- ===== Purchase credit: every buy shrinks the shown shopping list ===========
-- Any merchant purchase takes the item off the ACTIVE shopping list (owner,
-- 2026-09-19). It used to be Buy All only, so a right-click at the vendor, a
-- stack split or a confirm popup left the list claiming pieces already bought.
--
-- One hook on BuyMerchantItem sees every buy path: Blizzard's right-click, stack
-- split and high-cost / token confirmations (MerchantFrame.lua, GameDialogDefs),
-- and HDG's own Buy All and quantity picker, which call it too. The hook records
-- INTENT only. A buy can still fail after the click -- short on gold, bags full
-- -- so the list moves when the item LANDS: a count rise in bags or in decor
-- storage, whichever it reaches. Payment does not decide destination (Dennia's
-- gold-priced decor goes to bags, 2026-08-31).
--
-- Counts, not events: landed = rise in bags + rise in storage since the first
-- click, capped at what was asked. Recomputed from scratch on every signal, so a
-- coalesced or doubled signal costs nothing (the BuyQueue lesson, 2026-08-21),
-- and an item moving from bags into storage nets out rather than counting twice.
-- A claim that never lands lapses after MERCHANT_PURCHASE_CREDIT_SECS.
MO._pending = MO._pending or {}   -- exception(false-positive): idempotent module-load init; itemID -> claim

-- Decor-storage count, or nil when there is none to watch: not decor, or the
-- catalog is still cold. A nil baseline switches the storage side off for that
-- claim -- a cold catalog warming mid-claim would otherwise read as the whole
-- stored count arriving at once.
local function _stored(itemID)
    local row = HDG.HousingCatalogObserver:GetRow(itemID)  -- exception(nullable): not decor, or catalog cold
    return row and row.quantity
end

function MO:_OnBuy(index, quantity)
    local itemID = GetMerchantItemID(index)
    if not itemID then return end   -- exception(boundary): slot emptied between the click and the hook
    -- No quantity = one of the vendor's stacks (MerchantFrame.lua's plain buy).
    local asked = quantity or C_MerchantFrame.GetItemInfo(index).stackCount
    local claim = self._pending[itemID]
    if claim then
        claim.asked, claim.at = claim.asked + asked, GetTime()
        return
    end
    self._pending[itemID] = { asked = asked, credited = 0, at = GetTime(),
        bagStart = HDG.BagObserver:GetBagCount(itemID), storeStart = _stored(itemID) }
end

local function _landed(itemID, claim)
    local fromBags = math.max(0, HDG.BagObserver:GetBagCount(itemID) - claim.bagStart)
    local store = claim.storeStart and _stored(itemID)
    local fromStorage = store and math.max(0, store - claim.storeStart) or 0
    return math.min(claim.asked, fromBags + fromStorage)
end

function MO:_CreditLanded()
    local now = GetTime()
    for itemID, claim in pairs(self._pending) do
        local fresh = _landed(itemID, claim) - claim.credited
        if fresh > 0 then
            claim.credited = claim.credited + fresh
            HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_ITEM_PURCHASED,
                payload = { itemID = itemID, qty = fresh } })
        end
        if claim.credited >= claim.asked or now - claim.at > HDG.Constants.MERCHANT_PURCHASE_CREDIT_SECS then
            self._pending[itemID] = nil
        end
    end
end

-- A vendor opening re-arms the quantity picker after it was X'd away at the last
-- one. Keyed on the opening, not the close, so a close event that never arrives
-- cannot leave the picker disabled; and on MERCHANT_SHOW, not on the snapshot,
-- because every list update re-snapshots the vendor and undid the X.
function MO:OnMerchantShow()
    HDG.QuantityPicker:ClearOptOut()
    MO:ScanNow()
    _installClickOverrides()
end
function MO:OnMerchantUpdate() if HDG.Store:GetState().session.merchant.open then MO:ScanNow() end end
function MO:OnMerchantClosed()
    _removeClickOverrides()
    A = HDG.Constants.ACTIONS
    HDG.Store:Dispatch({ type = A.MERCHANT_SET_STATE, payload = { open = false } })
    -- A run must not outlive its vendor. It used to carry on until its next
    -- landing, and a vendor opened by then got the next buy at the old slot.
    HDG.BuyQueue:Cancel("vendor closed")
end

HDG.Modules:Declare({
    name = "MerchantObserver",
    ownsBlizzardNamespaces = { "C_MerchantFrame" },
    dependencies = {},
    logTags = {
        -- Declared here so the buy queue (Task 4) can log without its own Declare.
        merchant_buy = { user = true, level = "info", duration = 3 },
    },
    blizzardEvents = {
        MERCHANT_SHOW   = { handler = "OnMerchantShow" },
        MERCHANT_UPDATE = { handler = "OnMerchantUpdate", debounce = 0.3 },   -- filter/page changes fire bursts
        MERCHANT_CLOSED = { handler = "OnMerchantClosed" },
        -- Coupon-bought decor lands in BAGS, not decor storage, so the buy queue
        -- has no storage row to wait on. This is its confirmation signal, and it
        -- lives here rather than on BagObserver because that module gates its bag
        -- scan on requiresMainWindow -- and buying at a vendor with the main
        -- window closed is the normal case. Debounced: a purchase fires a burst.
        -- 0.1s, not BagObserver's 0.2: this debounce is the per-item WAIT in a
        -- coupon buy, so it sets the pace of the whole run. Halving it halves the
        -- run without giving up the confirmation.
        BAG_UPDATE      = { handler = "OnBagUpdate", debounce = 0.1 },
        -- The wallet snapshot (gold, currencies, items paid as currency). Always
        -- subscribed but a no-op unless a vendor is open; debounced because every
        -- unit of a buy fires each of them.
        PLAYER_MONEY            = { handler = "OnWalletChanged", debounce = 0.2 },
        CURRENCY_DISPLAY_UPDATE = { handler = "OnWalletChanged", debounce = 0.3 },
        BAG_UPDATE_DELAYED      = { handler = "OnWalletChanged", debounce = 0.2 },
    },
    OnMerchantShow   = function(self) MO:OnMerchantShow() end,
    OnMerchantUpdate = function(self) MO:OnMerchantUpdate() end,
    OnMerchantClosed = function(self) MO:OnMerchantClosed() end,
    OnBagUpdate      = function(self) HDG.BuyQueue:_Recount("BAG_UPDATE"); MO:_CreditLanded() end,
    OnWalletChanged  = function(self) MO:RefreshWallet() end,
    onEnable = function(self)
        -- A post-hook: it runs after the buy call and never touches its arguments,
        -- so Blizzard's own buying stays untainted.
        hooksecurefunc("BuyMerchantItem", function(index, quantity) MO:_OnBuy(index, quantity) end)
        -- Decor landing in storage arrives as the catalog's counts dispatch. The
        -- credit dispatches too, so it runs a frame later, never nested inside
        -- another action's subscriber (same rule as the buy queue).
        self._storeToken = HDG.Store:Subscribe(function(actionType)
            if actionType == HDG.Constants.ACTIONS.COLLECTION_CATALOG_ROW_COUNTS_UPDATED
               and next(MO._pending) then
                C_Timer.After(0, function() MO:_CreditLanded() end)
            end
        end)
    end,
    onShutdown = function(self)
        if self._storeToken then
            HDG.Store:Unsubscribe(self._storeToken)
            self._storeToken = nil
        end
    end,
})
