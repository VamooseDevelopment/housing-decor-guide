-- HDG.ZoneAlertEngine
-- ============================================================================
-- Subscribes to ZONE_CHANGED dispatches (from HDGR_ZoneObserver) and reads
-- the current zone's vendor data via zone selectors. When a fresh zone has
-- uncollected items OR items on the active shopping list, fires the
-- configured alert surfaces:
--
--   * Chat message  (config.zoneScannerChat)   -- always prints if enabled
--   * Sound cue     (config.zoneScannerSound)  -- PlaySound
--   * Popup show    (config.zoneScannerPopup)  -- dispatches ZONE_POPUP_TOGGLE
--                                                  if popup currently hidden
--
-- Master gate: config.zoneScannerEnabled -- when false, the engine skips the
-- entire check (no selector calls, no dispatch). Combat-safe: in lockdown we
-- skip popup-show too (no protected frame ops).
--
-- HDG parity:
--   * Two alert paths -- uncollected items + shopping-list items. Both
--     check independently; both can fire on the same zone change.
--   * shoppingList alert reuses the chat message but does NOT play the
--     sound twice (avoids stacking).
--   * Skips when the zone has zero qualifying vendors (no noisy "empty zone"
--     alerts).

HDG = HDG or {}
HDG.ZoneAlertEngine = HDG.ZoneAlertEngine or {}
local Z = HDG.ZoneAlertEngine

-- Log tag registration -- file-load so the first ZONE_CHANGED dispatch can
-- log immediately without waiting for the module's onEnable. Matches the
-- pattern in HDGR_Controller_Shopping (`shopping` tag).
-- Chat-link click: open HDG on the Zone tab. hooksecurefunc posthook = taint-safe;
-- unknown addon: links are no-ops for Blizzard, so we only ever ADD behavior.
_G.hooksecurefunc("SetItemRef", function(link)
    if link ~= "addon:HDGZone" then return end
    -- Zone Scanner is the standalone popup (account.ui.zonePopupShown), not a
    -- main-window view -- open it if closed, no-op if already up.
    if not HDG.Store:GetState().account.ui.zonePopupShown then
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ZONE_POPUP_TOGGLE })
    end
end)

if HDG.Log and not HDG.Log:HasTag("zone_scanner") then
    HDG.Log:RegisterTags({
        zone_scanner = { user = true, level = "info", duration = 4 },
    })
end

HDG.Modules:Declare({
    name = "ZoneAlertEngine",
    dependencies = { "ZoneObserver" },
    -- Subscribes to Store, not Blizzard events. No namespace ownership.
    onEnable = function(self)
        Z._loadAfter = _G.GetTime() + HDG.Constants.ZONE_ALERT_LOGIN_DELAY
        self._storeToken = HDG.Store:Subscribe(function(actionType)
            if actionType == HDG.Constants.ACTIONS.ZONE_CHANGED then
                Z._alertedThisZone = false   -- new zone entry -> allow one alert
                Z:CheckAlerts()
            elseif actionType == HDG.Constants.ACTIONS.DECOR_CATALOG_READY then
                -- Catalog finished its async sweep. On /reload (or login) the zone is
                -- set BEFORE the sweep lands, so the ZONE_CHANGED check ran with no
                -- vendor data and bailed. Re-check now that the catalog is ready (the
                -- _alertedThisZone dedup stops a double-alert when both fire in order).
                Z:CheckAlerts()
            end
        end)
    end,
    onShutdown = function(self)
        if self._storeToken and HDG.Store.Unsubscribe then
            HDG.Store:Unsubscribe(self._storeToken)
        end
        self._storeToken = nil
    end,
})

-- The zone alert's catalog load, held until ZONE_ALERT_LOGIN_DELAY after login.
-- Inside the wait it books one timer, which runs the whole check again: by then
-- the player may have left the vendor zone, switched alerts off, or opened HDG
-- (which loads the catalog itself), and each of those is judged afresh.
function Z:_LoadCatalogAfterLogin()
    local wait = Z._loadAfter - _G.GetTime()
    if wait <= 0 then
        HDG.HousingCatalogObserver:RequestLoad("zone-alert")
        return
    end
    if Z._loadTimerBooked then return end
    Z._loadTimerBooked = true
    _G.C_Timer.After(wait, function()
        Z._loadTimerBooked = false
        Z:CheckAlerts()
    end)
end

-- Run all alert checks against the current state. Called from the Store
-- subscriber after ZONE_CHANGED lands -- by then session.zone.currentMapID
-- and session.ui.zoneScanner.expanded have been updated by the reducer.
function Z:CheckAlerts()
    local state = HDG.Store:GetState()
    local cfg   = state.account.config
    if not cfg.zoneScannerEnabled then return end
    -- Dedup: one alert per zone entry. Reset on ZONE_CHANGED; this guard stops the
    -- DECOR_CATALOG_READY re-check (and any repeat ZONE_CHANGED) from re-alerting.
    if Z._alertedThisZone then return end
    -- InCombatLockdown read deferred to fire-time: combat-safe gate for
    -- popup-show. boundary -- single Blizzard API call in this module.
    local inCombat = _G.InCombatLockdown and _G.InCombatLockdown() or false

    -- A cold catalog loads here only where decor vendors stand (owner ruling
    -- 2026-10-22). Until then a login never loaded it -- 3.31.1 took out the
    -- July self-warm because every character login swept in one frame, 3297 ms
    -- (/hdgr perf 2026-09-03, themindboggle's 3-4 s freeze) -- so a player who
    -- logged in at a vendor saw no alert and an empty Zone Scanner until HDG
    -- opened. The sweep is ~97 ms now (2026-10-22), and a zone with no decor
    -- vendor still never loads the catalog (~6 MB kept). Bail WITHOUT marking:
    -- the DECOR_CATALOG_READY re-check fires this zone's alert when it lands.
    if not HDG.HousingCatalogObserver:IsReady() then
        if HDG.StaticData.VendorAugment:GetVendorsByMap(state.session.zone.currentMapID) then  -- exception(nullable): most maps have no decor vendor
            Z:_LoadCatalogAfterLogin()
        end
        return
    end
    local hasUnc  = HDG.Selectors:Call("zone.hasUncollectedItems", state, {})
    local hasSL   = HDG.Selectors:Call("zone.hasShoppingListItems", state, {})
    -- Catalog swept but zone has nothing -- bail WITHOUT marking, so a
    -- DECOR_CATALOG_READY re-check (fresh data) can still alert later.
    if not hasUnc and not hasSL then return end
    Z._alertedThisZone = true   -- commit: this zone entry is handled

    local summary = HDG.Selectors:Call("zone.summary", state, {})

    -- Chat alert: direct print to DEFAULT_CHAT_FRAME (Log routes to status rail,
    -- not chat). Also emit via Log:Info so the rail shows it for scrollback.
    if cfg.zoneScannerChat then
        local prefix = hasSL and "shopping list" or "uncollected"
        local line = ("Zone has %s items -- %s"):format(prefix, summary)
        if _G.print then
            -- User-facing alert, dressed up: vendor-pin atlas icon + gold brand +
            -- warm headline + dimmed detail + clickable [View] (|Haddon:...|h link;
            -- SetItemRef posthook below opens the Zone Scanner popup).
            local headline = hasSL and "Shopping-list decor in this zone!"
                                   or  "Uncollected decor in this zone!"
            _G.print(("|A:housing-decor-vendor_32:16:16|a |cffffd700[HDG]|r |cffffe29a%s|r |cffaaaaaa(%s)|r |Haddon:HDGZone|h|cff71d5ff[View]|r|h")
                :format(headline, summary))
        end
        HDG.Log:Info("zone_scanner", line)
    end

    -- Sound: one cue per zone change regardless of which path triggered.
    if cfg.zoneScannerSound and _G.PlaySound and _G.SOUNDKIT then
        _G.PlaySound(_G.SOUNDKIT.IG_MAINMENU_OPEN)
    end

    -- Popup auto-show on zone change.
    --   Window closed -> auto-open to Zone view (popup slot).
    --   Window open   -> no-op (alert is passive).
    -- Combat-safe: skip visibility changes in lockdown (protected-frame ops).
    -- Two independent flags: uncollected vs shopping-list matches.
    local wantPopup = (cfg.zoneScannerPopup and hasUnc)
                   or (cfg.zoneScannerPopupShopping and hasSL)
    if wantPopup and not inCombat then
        local windowOpen = state.account.ui.mainWindowShown == true
                        or state.account.ui.zonePopupShown == true
                        or state.account.ui.shoppingWidgetShown == true
        if not windowOpen then
            -- Window closed: auto-open via the popup slot (PrepareContext
            -- override flips activeView to zoneScanner).
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.ZONE_POPUP_TOGGLE,
                payload = nil,
            })
        end
    end
end
