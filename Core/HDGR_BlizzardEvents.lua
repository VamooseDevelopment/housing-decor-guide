-- HDG.BlizzardEvents
--
-- Single-frame event router. The input boundary of the architecture.
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 15.
--
-- Modules declare event subscriptions in their `blizzardEvents` field at
-- Module:Declare time (see Core/Modules.lua). Init.lua calls
-- BlizzardEvents:Boot BETWEEN `Modules:Topo` and `Modules:Phase1` -- so
-- subscribers are wired before any onInitialize-time event fires, but
-- after the topo order is fixed (Boot needs the order + every module's
-- def in the registry to wire all subscribers in one pass).
--
-- Three subscription modes (declared per event in a module's blizzardEvents):
--   action  = "STORE_ACTION_TYPE"            -> Store.Dispatch on event fire
--   handler = "methodName" | function        -> Call module:methodName(...) or fn(...)
--   thunk   = function(store, env, ...)      -> Conditional dispatch with full Store/env
--
-- Options on each subscription:
--   debounce  = 0.2     -- seconds; coalesces repeated fires within window
--   filter    = fn(...) -- arg predicate; drops fire if returns false
--   once      = true    -- auto-unsubscribe after first fire
--
-- Hook namespace: events with "hook:" prefix install a `hooksecurefunc`
-- instead of RegisterEvent. Same subscription/debounce/filter semantics.
--
-- Reference patterns:
--   hump.signal -- function-as-own-key subscriber list (LUA_SAMPLES.md section 3a)
--   Rodux Store -- middleware-style dispatch (LUA_SAMPLES.md section 1a)
--   Elm Subscriptions / Neovim autocmd -- declarative per-module subscriptions

HDG = HDG or {}
HDG.BlizzardEvents = HDG.BlizzardEvents or {
    _frame       = nil,                   -- single CreateFrame; built in OnInitialize
    _subscribers = {},                    -- [event] = { { module, mode, opts, ... }, ... }
    _debounceTimers = {},                 -- [event .. ":" .. moduleName] = timer
    _hookInstalled = {},                  -- [funcName] = true
    _registeredEvents = {},               -- [event] = true (events frame:RegisterEvent'd)
    _fireCount = {},                      -- [event] = raw fires this session (see FireCount)
    _booted = false,
}

local BE = HDG.BlizzardEvents

-- Debug tag for BlizzardEvents diagnostics -- notably when an event subscription
-- is skipped because the name isn't valid on this client version (see the
-- RegisterEvent boundary guard in addSubscription). user=false: debug log only,
-- not a user-facing status toast.
HDG.Log:RegisterTags({ blizzard_events = { user = false, level = "debug" } })

-- ===== Closed event taxonomy (high-frequency events that REQUIRE debounce) ==
-- Validator enforces: subscribing to any of these without `debounce` errors.
-- Add rows as the monorepo accumulates evidence of new high-freq events.

BE.DEBOUNCE_REQUIRED = {
    BAG_UPDATE                  = 0.2,
    CURRENCY_DISPLAY_UPDATE     = 0.3,
    UNIT_AURA                   = 0.1,
    CHAT_MSG_LOOT               = 0.5,
    ITEM_PUSH                   = 0.5,
    TRANSMOG_COLLECTION_UPDATED = 0.5,
    PLAYER_INVENTORY_CHANGED    = 0.2,
    -- Storage events burst during loading + login; per-entry events stay undebounced (authoritative).
    HOUSING_STORAGE_UPDATED     = 0.5,
}

-- Combat regen events owned by CombatMiddleware; modules cannot subscribe.
-- PLAYER_LOGIN/LOGOUT owned by Init.lua (single-purpose per-session). ADDON_LOADED is NOT
-- forbidden -- modules may subscribe with name filters to wait for other addons.
BE.FORBIDDEN_MODULE_EVENTS = {
    PLAYER_REGEN_DISABLED = "owned by CombatMiddleware (read state.session.combat.inLockdown)",
    PLAYER_REGEN_ENABLED  = "owned by CombatMiddleware (read state.session.combat.inLockdown)",
    PLAYER_LOGIN  = "owned by Init.lua bootstrap (drives OnEnable)",
    PLAYER_LOGOUT = "owned by Init.lua bootstrap (drives Flush)",
}

-- ===== Dispatch helper =====================================================

local function callHandler(mod, handler, ...)
    if type(handler) == "string" then
        local method = mod[handler]
        if type(method) == "function" then
            method(mod, ...)
        else
            error(("blizzardEvents handler %q is not a method on module %q")
                :format(handler, mod.name), 2)
        end
    elseif type(handler) == "function" then
        handler(mod, ...)
    end
end

local function dispatchToSubscriber(sub, event, ...)
    -- _once_fired guards against re-entrant _fire for the same event: the outer
    -- snapshot still holds the once-entry after the inner fire cleaned it.
    if sub._once_fired then return end

    local opts = sub.opts
    if opts.filter and not opts.filter(...) then return end

    -- requiresMainWindow: skip handler when main window is hidden (always-on modules omit this flag).
    if opts.requiresMainWindow then
        local state = HDG.Store:GetState()
        local shown = state.account.ui.mainWindowShown == true
        if not shown then return end
    end

    -- One-shot: mark + detach before firing so re-entrant dispatch doesn't re-fire.
    if opts.once then
        sub._once_fired = true
        local subs = BE._subscribers[event]
        for i, s in ipairs(subs) do
            if s == sub then table.remove(subs, i); break end
        end
    end

    if sub.mode == "action" then
        HDG.Store:Dispatch({ type = opts.action, payload = { ... } })
    elseif sub.mode == "handler" then
        callHandler(sub.module, opts.handler, ...)
    elseif sub.mode == "thunk" then
        local env = HDG.Environment._current or nil
        opts.thunk(HDG.Store, env, ...)
    end
end

-- Coalesce fires within the debounce window. Most-recent args win (Blizzard semantics).
-- At most one timer per (event, module) key; subsequent fires update args in place.
local function debouncedFire(sub, event, ...)
    local key = event .. ":" .. sub.module.name
    local pending = BE._debounceTimers[key]
    if pending then
        -- Timer already scheduled; replace args in place.
        pending.n = select("#", ...)
        for i = 1, pending.n do pending[i] = select(i, ...) end
        return
    end

    local args = { n = select("#", ...) }
    for i = 1, args.n do args[i] = select(i, ...) end
    BE._debounceTimers[key] = args

    -- NewTimer (not After) so _Reset can cancel in-flight timers; otherwise a
    -- reset + same-key resubscribe within the window double-fires the dispatch.
    args.timer = C_Timer.NewTimer(sub.opts.debounce, function()
        local current = BE._debounceTimers[key]
        if not current then return end
        BE._debounceTimers[key] = nil
        dispatchToSubscriber(sub, event, unpack(current, 1, current.n))
    end)
end

-- ===== Registration ========================================================

-- Validate one event subscription spec. Errors loudly with module + event name.
local function validateSub(modName, event, spec)
    if BE.FORBIDDEN_MODULE_EVENTS[event] then
        error(("Module %q cannot subscribe to %q: %s")
            :format(modName, event, BE.FORBIDDEN_MODULE_EVENTS[event]), 2)
    end

    if type(spec) == "string" then  -- shorthand: string = handler methodName
        return { mode = "handler", opts = { handler = spec } }
    end

    if type(spec) ~= "table" then
        error(("Module %q subscription to %q must be a table or handler-name string")
            :format(modName, event), 2)
    end

    local modeCount = 0
    local mode
    if spec.action  ~= nil then modeCount = modeCount + 1; mode = "action" end
    if spec.handler ~= nil then modeCount = modeCount + 1; mode = "handler" end
    if spec.thunk   ~= nil then modeCount = modeCount + 1; mode = "thunk" end

    if modeCount == 0 then
        error(("Module %q subscription to %q must declare one of action / handler / thunk")
            :format(modName, event), 2)
    end
    if modeCount > 1 then
        error(("Module %q subscription to %q declared multiple modes; pick one")
            :format(modName, event), 2)
    end

    -- once + debounce is incoherent (debounced timer can outlive the one-shot);
    -- reject at declaration time.
    if spec.once and spec.debounce then
        error(("Module %q subscription to %q declares both `once` and `debounce`; pick one")
            :format(modName, event), 2)
    end

    -- Validate debounce requirement for high-frequency events
    if BE.DEBOUNCE_REQUIRED[event] and not spec.debounce then
        error(("Module %q subscription to %q requires `debounce` (recommended %.1fs). "
            .. "High-frequency event; see BlizzardEvents.DEBOUNCE_REQUIRED."):format(
            modName, event, BE.DEBOUNCE_REQUIRED[event]), 2)
    end

    if spec.filter ~= nil and type(spec.filter) ~= "function" then
        error(("Module %q subscription to %q: `filter` must be a function"):format(modName, event), 2)
    end

    return { mode = mode, opts = spec }
end

-- Add one event subscription to the registry. Wires RegisterEvent or
-- hooksecurefunc as appropriate. Idempotent on the underlying registration.
local function addSubscription(modDef, event, sub)
    local list = BE._subscribers[event]
    if not list then
        list = {}
        BE._subscribers[event] = list

        local hookPrefix = event:sub(1, 5)
        if hookPrefix == "hook:" then
            local funcName = event:sub(6)
            if not BE._hookInstalled[funcName] then
                BE._hookInstalled[funcName] = true
                hooksecurefunc(funcName, function(...)
                    BE:_fire(event, ...)
                end)
            end
        else
            if BE._frame and not BE._registeredEvents[event] then
                -- exception(boundary): event names drift across client versions (e.g.
                -- HOUSING_LAYOUT_NUM_FLOORS_CHANGED was renamed to
                -- HOUSING_LAYOUT_OCCUPIED_FLOOR_RANGE_CHANGED in 12.1). Skip events not
                -- valid on this client so one unknown name can't throw and abort init.
                if C_EventUtils.IsEventValid(event) then
                    BE._frame:RegisterEvent(event)
                    BE._registeredEvents[event] = true
                else
                    -- Warn, not Debug: the `blizzard_events` tag is debug-level and never
                    -- prints, so a renamed event silently left its handler in _subs to never
                    -- fire. A skipped registration is a real capability loss -- say so.
                    HDG.Log:Warn("blizzard_events", "skipped event not valid on this client: " .. event)
                end
            end
        end
    end
    list[#list + 1] = {
        module = modDef,
        mode   = sub.mode,
        opts   = sub.opts,
    }
end

-- ===== Fire / simulate =====================================================

-- Internal fire: invoked by OnEvent or by tests via _simulate.
function BE:_fire(event, ...)
    self._fireCount[event] = self:FireCount(event) + 1
    -- Internal subs (CombatMiddleware etc.) fire first so combat state is updated before module dispatches.
    local internal = self._internalSubs and self._internalSubs[event]
    if internal then
        for _, cb in ipairs(internal) do cb(...) end
    end

    -- FlowRunner taps every event for saga-style flow.take; short-circuits when no flow is waiting.
    if HDG.FlowRunner and HDG.FlowRunner._onEvent then  -- exception(boundary): optional module / not yet built
        HDG.FlowRunner:_onEvent(event, ...)
    end

    local subs = self._subscribers[event]
    if not subs then return end
    -- Snapshot before iteration so one-shot removals don't perturb the loop.
    local snapshot = {}
    for i, s in ipairs(subs) do snapshot[i] = s end
    for _, sub in ipairs(snapshot) do
        if sub.opts.debounce then
            debouncedFire(sub, event, ...)
        else
            dispatchToSubscriber(sub, event, ...)
        end
    end
end

-- Raw fires of `event` this session, counted before any debounce. A debounced
-- handler runs once per burst and can't tell whether more fired after the burst
-- began; comparing this count with one taken earlier can.
function BE:FireCount(event)
    return self._fireCount[event] or 0  -- exception(nullable): an event that never fired
end

-- Test helper: drive the engine without a real frame event.
function BE:_simulate(event, ...)
    self:_fire(event, ...)
end

-- Internal subscribe: bypasses the module-validator. For sibling engines (CombatMiddleware)
-- that need to listen for forbidden events. Caller owns debouncing/filtering.
function BE:_internalSubscribe(event, callback)
    if not self._frame then self:OnInitialize() end
    local list = self._internalSubs or {}
    self._internalSubs = list
    list[event] = list[event] or {}
    table.insert(list[event], callback)

    if not self._registeredEvents[event] and event:sub(1, 5) ~= "hook:" then
        self._frame:RegisterEvent(event)
        self._registeredEvents[event] = true
    end
end

-- ===== Boot ================================================================

-- Frame eager-inits at TOC load ("one module, one frame, all events").
-- Init.lua routes ADDON_LOADED/PLAYER_LOGIN/PLAYER_LOGOUT through this engine.
local function ensureFrame()
    if BE._frame then return end
    BE._frame = CreateFrame("Frame")
    BE._frame:SetScript("OnEvent", function(_, event, ...) BE:_fire(event, ...) end)
end
ensureFrame()

-- Idempotent no-op; used by tests that call _Reset(); OnInitialize() to restore the frame.
function BE:OnInitialize()
    ensureFrame()
end

-- Resolve the { order, defs } module bundle: caller's bundle, else pull from
-- HDG.Modules, else empty. Always returns both fields as tables so callers can
-- strict-read modules.defs[name] (no `modules.defs and` cascade).
local function _resolveModules(modules)
    if not modules and HDG.Modules then
        local order = HDG.Modules:GetOrder() or {}
        local defs  = {}
        for _, name in ipairs(order) do defs[name] = HDG.Modules:Get(name) end
        return { order = order, defs = defs }
    end
    modules = modules or { order = {}, defs = {} }
    modules.order = modules.order or {}
    modules.defs  = modules.defs  or {}
    return modules
end

-- Validate + install one module's declarative blizzardEvents subscriptions.
-- Validation failures are batched into `errors` and raised fatally by the caller.
local function _subscribeModuleEvents(def, errors)
    for event, spec in pairs(def.blizzardEvents) do
        local ok, subOrErr = pcall(validateSub, def.name, event, spec)  -- exception(fire-forget): errors batched into errors[] and raised as fatal after the loop
        if ok then
            addSubscription(def, event, subOrErr)
        else
            errors[#errors + 1] = tostring(subOrErr)
        end
    end
end

-- Walk modules in topo order, installing each one's subscriptions. Returns the
-- batched validation errors (empty on success).
local function _installModuleSubscriptions(modules)
    local errors = {}
    for _, modName in ipairs(modules.order) do
        local def = modules.defs[modName]   -- strict: _resolveModules guarantees defs is populated
        if def and def.blizzardEvents then
            _subscribeModuleEvents(def, errors)
        end
    end
    return errors
end

-- Boot: called after Modules:Topo() but before Modules:Phase1() so declarative subscriptions
-- are live before any onInitialize fires. Accepts { order, defs } so the engine doesn't reach
-- into HDG.Modules directly. Falls back to HDG.Modules when called without arguments.
function BE:Boot(modules)
    if self._booted then return end
    self._booted = true

    modules = _resolveModules(modules)
    local errors = _installModuleSubscriptions(modules)
    if #errors > 0 then
        error("HDG.BlizzardEvents:Boot validation failures:\n  " ..
            table.concat(errors, "\n  "), 2)
    end
end

-- ===== Test / debug helpers ===============================================

function BE:_Reset()
    if self._frame and self._frame.UnregisterAllEvents then
        self._frame:UnregisterAllEvents()
    end
    self._frame = nil
    self._subscribers = {}
    self._internalSubs = {}
    for _, pending in pairs(self._debounceTimers) do
        if pending.timer then pending.timer:Cancel() end
    end
    self._debounceTimers = {}
    self._hookInstalled = {}
    self._registeredEvents = {}
    self._fireCount = {}
    self._booted = false
end
