-- HDGR_BagBadge.lua
-- ============================================================================
-- Marks bag slots that hold a decor reagent with a small HDG logo in the
-- TOP-RIGHT corner of the item icon. Companion to the tooltip decorator: the
-- tooltip flags reagents on hover; this flags them at a glance.
--
-- One provider is active, chosen by which bag UI is loaded:
--   * Baganator -> Baganator.API.RegisterCornerWidget (native corner widget;
--     user-repositionable in Baganator's own settings).
--   * otherwise -> hooksecurefunc("SetItemButtonTexture"): the GLOBAL icon-paint
--     helper that BOTH Blizzard's default bags AND Bagnon (BagBrother item
--     slots, verified 12.0.14 / BagBrother 2026-06) route through. One hook
--     covers both without reaching into either framework's internals.
--
-- Blizzard's bank (character AND Warband tabs, one BankPanel) paints its icon with
-- self.icon:SetTexture inside BankPanelItemButtonMixin:Refresh, bypassing the helper
-- above, so it gets its own post-hook on that Refresh.
--
-- Gated by the BAG_BADGE config (Helpers section). Reagent membership is static
-- data, so it's memoised to a per-itemID boolean -> the per-slot check is O(1).

HDG = HDG or {}

local BB = {}

local BADGE_TEX  = "Interface\\AddOns\\HousingDecorGuide\\textures\\Vamoose_HDG_400_trans"
local BADGE_SIZE = 16

-- ===== Reagent membership (cached) ==========================================
local _reagentCache = {}

local function isDecorReagent(itemID)
    if not itemID then return false end
    local cached = _reagentCache[itemID]
    if cached ~= nil then return cached end
    -- Strict read: the providers only install at module-enable (post-load), so
    -- StaticData.Recipes is always present by the time a bag slot paints.
    local R = HDG.StaticData.Recipes
    local result = false
    local users = R:RecipesUsingReagent(itemID)
    if users and #users > 0 then
        result = true
    else
        -- Tiered reagents: recipes list one quality tier, the player may hold
        -- another -- union across the quality group (same as the tooltip line).
        local variants = HDG.StaticData.Professions:GetQualityVariants(itemID)
        if variants then
            for _, v in ipairs(variants) do
                local vu = R:RecipesUsingReagent(v)
                if vu and #vu > 0 then result = true; break end
            end
        end
    end
    _reagentCache[itemID] = result
    return result
end

local function enabled()
    return HDG.Config:Get("BAG_BADGE") == true
end

-- ===== SetItemButtonTexture provider (Blizzard default bags + Bagnon) ========
local function ensureBadge(button)
    local badge = button._hdgrDecorBadge
    if not badge then
        badge = button:CreateTexture(nil, "OVERLAY", nil, 7)   -- above icon/border/count
        badge:SetSize(BADGE_SIZE, BADGE_SIZE)
        badge:SetPoint("TOPRIGHT", button, "TOPRIGHT", 1, -1)
        badge:SetTexture(BADGE_TEX)
        -- Dark outline: a black silhouette of the emblem, a hair larger, drawn under
        -- it (sublevel 6 < 7) so the gold reads over bright icons + the gold slot frame.
        local outline = button:CreateTexture(nil, "OVERLAY", nil, 6)
        outline:SetSize(BADGE_SIZE + 3, BADGE_SIZE + 3)
        outline:SetPoint("CENTER", badge, "CENTER")
        outline:SetTexture(BADGE_TEX)
        outline:SetVertexColor(0, 0, 0, 0.9)
        badge._outline = outline
        button._hdgrDecorBadge = badge
    end
    return badge
end

-- Resolve the bag itemID for a generic item button. Returns nil for non-bag
-- buttons (character sheet, merchant, etc.) so the badge only lands in bags.
local function bagItemID(button)
    local info = button.info
    if type(info) == "table" then
        -- exception(boundary): BagBrother (Bagnon) slot -- .info is refreshed before every
        -- paint and is authoritative for what the slot DISPLAYS (live, cached alt view,
        -- guild bank). nil itemID = empty slot; MUST NOT fall through to a live container
        -- read: its (bag, slot) answers for the wrong universe in cached/guild views.
        return info.itemID
    end
    if button.GetBagID then
        -- exception(boundary): GetBagID lives on the BASE ItemButtonMixin (returns
        -- self.bagID) -- EVERY ItemButton has it, and it returns nil outside real
        -- container frames (e.g. Adventure Guide Monthly Activities rewards). The
        -- method's presence is NOT a container duck-type; nil bagID is.
        local bag = button:GetBagID()
        if bag == nil then return nil end
        local ci = C_Container.GetContainerItemInfo(bag, button:GetID())   -- exception(boundary): nil = empty slot
        return ci and ci.itemID
    end
    return nil
end

-- Shows the badge when itemID is a decor reagent, else hides one already made: pooled
-- buttons are reused for other slots, so an empty or plain slot clears the last occupant's.
local function paintBadge(button, itemID)
    if itemID and isDecorReagent(itemID) then
        local badge = ensureBadge(button)
        badge._outline:Show()
        badge:Show()
    elseif button._hdgrDecorBadge then
        button._hdgrDecorBadge._outline:Hide()
        button._hdgrDecorBadge:Hide()
    end
end

local function onSetTexture(button)
    if type(button) ~= "table" then return end   -- exception(boundary): SetItemButtonTexture passes the button frame
    if button.BGR then return end   -- exception(boundary): Baganator item-grid button; handled by its corner widget
    paintBadge(button, enabled() and bagItemID(button) or nil)
end

-- ===== Bank provider (Blizzard bank: character + Warband tabs) ===============
local function onBankRefresh(button)
    -- exception(boundary): Blizzard field, filled by RefreshItemInfo inside the Refresh this
    -- follows; nil = empty slot. Read here, not re-fetched, so a tab repaint allocates nothing.
    local info = button.itemInfo
    paintBadge(button, enabled() and info and info.itemID or nil)
end

-- ===== Baganator provider ===================================================
local function installBaganator()
    local Baganator = _G.Baganator   -- exception(boundary): optional third-party addon global
    Baganator.API.RegisterCornerWidget(
        "HDG decor reagent",            -- label (shown in Baganator's corner settings)
        "hdg_decor_reagent",            -- id
        function(_, details)            -- onUpdate -> return true to show
            if not enabled() then return false end
            local id = details.itemID or (details.itemLink and C_Item.GetItemInfoInstant(details.itemLink))
            return isDecorReagent(id) and true or false
        end,
        function(itemButton)            -- onInit -> create the corner frame
            local f = CreateFrame("Frame", nil, itemButton)
            f:SetSize(BADGE_SIZE, BADGE_SIZE)
            f.padding = 0   -- Baganator inset multiplier; 0 = frame flush to the icon's top-right corner
            -- Dark outline silhouette behind the emblem (matches the default-bag provider).
            local outline = f:CreateTexture(nil, "OVERLAY", nil, 0)
            outline:SetPoint("TOPLEFT", f, "TOPLEFT", 2 - 1, 1)
            outline:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2 + 1, -1)
            outline:SetTexture(BADGE_TEX)
            outline:SetVertexColor(0, 0, 0, 0.9)
            local t = f:CreateTexture(nil, "OVERLAY", nil, 1)
            -- Nudge the texture +2px right of the (corner-flush) frame so it sits hard against
            -- the slot's right edge. padding can't push past 0, so offset the texture itself.
            t:SetPoint("TOPLEFT", f, "TOPLEFT", 2, 0)
            t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, 0)
            t:SetTexture(BADGE_TEX)
            return f
        end,
        { corner = "top_right", priority = 1 }
    )
end

-- ===== Install ==============================================================
function BB:Install()
    if self._installed then return end
    self._installed = true
    -- Default Blizzard bags call the ItemButtonMixin METHOD itemButton:SetItemButtonTexture
    -- directly; the global SetItemButtonTexture only DELEGATES to that method, so hooking the
    -- method covers default bags AND Bagnon (BagBrother calls the global -> method). Baganator's
    -- own buttons carry .BGR and are skipped in onSetTexture (its grid is handled by the corner
    -- widget instead -- it paints icons without the mixin helper).
    if ItemButtonMixin and ItemButtonMixin.SetItemButtonTexture then  -- exception(boundary): Blizzard mixin presence
        hooksecurefunc(ItemButtonMixin, "SetItemButtonTexture", onSetTexture)
    end
    -- Bank buttons come from a pool on the first bank open, after this install, so the mixin
    -- copied onto them already carries the hook (there are no static bank button instances).
    if BankPanelItemButtonMixin and BankPanelItemButtonMixin.Refresh then  -- exception(boundary): Blizzard mixin presence
        hooksecurefunc(BankPanelItemButtonMixin, "Refresh", onBankRefresh)
    end
    local baganator = _G.Baganator   -- exception(boundary): optional third-party addon global
    if baganator and baganator.API and baganator.API.RegisterCornerWidget then
        installBaganator()
    end
end

-- ===== Module registration ==================================================
HDG.Modules:Declare({
    name = "BagBadge",
    dependencies = {},
    onEnable = function()
        -- Install at PLAYER_LOGIN (via the shared event engine, not a private frame): by then
        -- the Blizzard ItemButtonMixin and any third-party bag addon are fully loaded, and it is
        -- past WidgetTypes:Flush. Module onEnable runs DURING OnInitialize (pre-Flush), so the
        -- hookup must NOT happen here directly -- mirrors ProfessionButtons' Blizzard-UI injection.
        HDG.BlizzardEvents:_internalSubscribe("PLAYER_LOGIN", function()
            BB:Install()
        end)
    end,
})
