-- HDGR_MerchantOverlay.lua
-- ============================================================================
-- Marks Blizzard merchant (vendor) item buttons that sell housing decor with a
-- small corner icon: a green check on decor you've COLLECTED, a plus on decor
-- you still NEED. Non-decor items get nothing. Companion to the tooltip
-- decorator -- the tooltip flags decor on hover; this flags it at a glance.
--
-- A vendor is a MIXED list (decor + reagents + junk), so "no marker" can't mean
-- "uncollected" the way it does in the all-decor Zone view -- uncollected decor
-- needs a POSITIVE marker (the plus), or it looks identical to non-decor.
--
-- Surface: the default merchant frame. Hooks MerchantFrame_Update (the one
-- canonical Blizzard merchant repaint) and reads collected state from the
-- catalog observer (the same GetRow facade the tooltip uses). Gated by the
-- MERCHANT_DECOR_OVERLAY config (Helpers section).
--
-- Krowi's Extended Vendor UI hides Blizzard's MerchantItem1-10 on the merchant tab
-- and draws its own slots (KrowiEVU_MerchantItem<N>, built from the same
-- MerchantItemTemplate), so the marks reach those through its plugin API instead
-- (KrowiEVU.PluginsApi, Api/PluginsApi.lua in that addon).

HDG = HDG or {}

local MO = {}
HDG.MerchantOverlay = MO

local MARK_SIZE    = 14
local ATLAS_OWNED  = "common-icon-checkmark"   -- collected
local ATLAS_NEEDED = "common-icon-plus"         -- uncollected / needed

local function enabled()
    return HDG.Config:Get("MERCHANT_DECOR_OVERLAY") == true
end

-- Pure decision: itemID -> "collected" | "needed" | nil (non-decor / empty slot).
-- GetRow returns nil while the catalog is still loading (ADR-008/022), so an
-- unwarmed catalog yields NO marker rather than a wrong one.
local function _decideMarker(itemID)
    if not itemID then return nil end
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    if not row then return nil end
    return row.isOwned and "collected" or "needed"
end
MO._decideMarker = _decideMarker   -- exposed for tests

-- Lazy per-button overlay texture, cached on the button. Sublevel 7 sits above
-- the icon/border/count so it never hides behind the stack-count text.
local function _ensureMark(button)
    local mark = button._hdgrMerchantMark
    if not mark then
        mark = button:CreateTexture(nil, "OVERLAY", nil, 7)
        mark:SetSize(MARK_SIZE, MARK_SIZE)
        mark:SetPoint("TOPRIGHT", button, "TOPRIGHT", 1, 1)
        button._hdgrMerchantMark = mark
    end
    return mark
end

local function _hideMark(button)
    if button._hdgrMerchantMark then button._hdgrMerchantMark:Hide() end
end

-- One item button, from the itemID it sells: the check or the plus, or no mark.
local function _paintMark(button, itemID)
    local marker = _decideMarker(itemID)
    if not marker then return _hideMark(button) end
    local mark = _ensureMark(button)
    if marker == "collected" then
        mark:SetAtlas(ATLAS_OWNED, false)
        mark:SetVertexColor(1, 1, 1)           -- natural (the checkmark atlas is green)
    else
        mark:SetAtlas(ATLAS_NEEDED, false)
        mark:SetVertexColor(1, 0.10, 0.10)     -- red: the gold plus tints to red and pops vs the gold UI
    end
    mark:Show()
end

local function _paintButton(i)
    local index = ((MerchantFrame.page - 1) * MERCHANT_ITEMS_PER_PAGE) + i
    _paintMark(_G["MerchantItem" .. i .. "ItemButton"], GetMerchantItemID(index))
end

-- Krowi's slots seen so far, for the repaints Krowi doesn't drive (catalog ready, a collect).
local _krowiSlots = {}

-- Krowi sets hasItem and SetID(vendor index) on a drawn slot's button, as Blizzard does on
-- MerchantItemN; an empty slot has hasItem nil and its button hidden.
local function _paintKrowiSlot(slot)
    local button = slot.ItemButton
    local itemID = enabled() and button.hasItem and GetMerchantItemID(button:GetID()) or nil
    _paintMark(button, itemID)
end

local function _hideAll()
    for i = 1, MERCHANT_ITEMS_PER_PAGE do
        _hideMark(_G["MerchantItem" .. i .. "ItemButton"])
    end
    for slot in pairs(_krowiSlots) do _hideMark(slot.ItemButton) end
end

-- Krowi calls this after drawing each merchant-tab slot: on every page, filter and
-- item-data redraw, never on the Buyback tab (which shows Blizzard's own buttons).
local krowiPlugin = {}
function krowiPlugin:OnItemSlotUpdated(slot)
    _krowiSlots[slot] = true
    _paintKrowiSlot(slot)
end
MO._krowiPlugin = krowiPlugin   -- exposed for tests

-- Post-hook on MerchantFrame_Update. Paints the current merchant page; hides
-- everything on the Buyback tab (selectedTab 2 reuses the same buttons), when
-- disabled, or while the catalog hasn't finished its first scan.
function MO:Refresh()
    if not enabled() then return _hideAll() end
    if MerchantFrame.selectedTab ~= 1 then return _hideAll() end
    if not HDG.HousingCatalogObserver:IsReady() then return _hideAll() end
    for i = 1, MERCHANT_ITEMS_PER_PAGE do
        _paintButton(i)
    end
    for slot in pairs(_krowiSlots) do _paintKrowiSlot(slot) end
end

local function _refresh() MO:Refresh() end

function MO:Install()
    if self._installed then return end
    self._installed = true
    hooksecurefunc("MerchantFrame_Update", _refresh)
    -- The merchant's own first paint can run before this MERCHANT_SHOW handler,
    -- so paint the current page now -- otherwise the first vendor open is blank.
    self:Refresh()
end

HDG.Modules:Declare({
    name = "MerchantOverlay",
    dependencies = {},
    onEnable = function()
        -- Defer the Blizzard hook to first MERCHANT_SHOW (HDGR convention for
        -- Blizzard-UI injection -- mirrors ProfessionButtons' TRADE_SKILL_SHOW).
        -- It also means zero work until a vendor is actually opened.
        HDG.BlizzardEvents:_internalSubscribe("MERCHANT_SHOW", function()
            MO:Install()
            -- HDGR loads the catalog on demand (first catalog-consuming view); a
            -- vendor opened before the main window would otherwise never warm it.
            -- RequestLoad is the idempotent cold-start trigger (no-op unless idle) --
            -- the same call the Shopping List and House Editor companion use. Marks
            -- fill in via the DECOR_CATALOG_READY subscription once results land.
            if enabled() then HDG.HousingCatalogObserver:RequestLoad("merchant-overlay") end
        end)
        -- At PLAYER_LOGIN every addon has loaded, Krowi's included whatever the load order,
        -- and its first draw (on a vendor open) is still ahead.
        HDG.BlizzardEvents:_internalSubscribe("PLAYER_LOGIN", function()
            local krowi = _G.KrowiEVU   -- exception(boundary): optional third-party addon global
            if krowi and krowi.PluginsApi then
                krowi.PluginsApi:RegisterPlugin("HousingDecorGuide", krowiPlugin)
            end
        end)
        -- Live refresh: flip a marker the instant decor is collected while the
        -- vendor is open. PatchCounts sets row.isOwned synchronously before these
        -- dispatches (fan-out deferred via C_Timer.After(0)), so GetRow is fresh
        -- when Refresh runs. DECOR_CATALOG_READY covers a first open while the
        -- catalog is still warming -- GET_ITEM_INFO_RECEIVED does not re-fire
        -- MerchantFrame_Update.
        local A = HDG.Constants.ACTIONS
        MO._storeToken = HDG.Store:Subscribe(function(actionType)
            if not MerchantFrame:IsShown() then return end
            if actionType == A.COLLECTION_CATALOG_ROW_COUNTS_UPDATED
               or actionType == A.DECOR_CATALOG_READY then
                MO:Refresh()
            end
        end)
    end,
    onShutdown = function()
        if MO._storeToken then
            HDG.Store:Unsubscribe(MO._storeToken)
            MO._storeToken = nil
        end
    end,
})
