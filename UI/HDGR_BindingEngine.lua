-- HDG.BindingEngine
--
-- Declarative state-to-widget data flow. Widget specs in LayoutConfig can
-- declare a `binding` field that names one or more selectors; the engine
-- walks every bound widget on each refresh, calls the selector, and pushes
-- the value through a kind-specific dispatcher.
--
-- Binding shape (per widget spec):
--   binding = "selector.name"                       -- single scalar -> default field
--   binding = "static:Literal text"                 -- string literal, no selector call
--   binding = { value = "x", label = "static:Y" }   -- multi-field, kind-specific names
--
-- Kind-specific field names (the dispatcher routes to widget methods):
--   label / fieldLabel                  -> { text }   (variant via spec.variant)
--   button                              -> { text, enabled, active }
--   editbox                             -> { text }
--   chip                                -> { text, status }
--   statCard                            -> { value, label }
--   scrollbox                           -> { items }
--
-- Rules:
--   - A widget MUST be either fully bound (declarative) OR fully imperative
--     (controller's Refresh pushes its values). Never both -- the engine
--     stamps `_hdgrBound = true` on bound widgets; controllers should never
--     SetText/SetItems on those.
--   - Selectors are pure: `function(state, ctx) -> value`. No side effects.
--   - "static:..." prefix resolves to the literal substring without a
--     selector lookup. Useful for fixed labels (COORDS, MAP, STATUS, etc).

HDG = HDG or {}
HDG.BindingEngine = HDG.BindingEngine or {}

local Engine = HDG.BindingEngine

-- Kind-specific dispatchers live on WidgetType records (HDG.WidgetTypes -> kind.dispatch).
-- See UI/Components.lua registrations; Core/WidgetTypes.lua for the contract.

-- ===== Resolution ==========================================================

-- Resolve one binding value: literal "static:..." OR locale lookup
-- "locale:KEY" OR a registered selector. Locale lookups fall back through
-- HDG.Locale:Get (current locale -> enUS -> key string).
local function resolve(spec, state, ctx)
    if type(spec) ~= "string" then return nil end
    if spec:sub(1, 7) == "static:" then return spec:sub(8) end
    if spec:sub(1, 7) == "locale:" then
        return HDG.Locale:Get(spec:sub(8))
    end
    return HDG.Selectors:Call(spec, state, ctx)
end

-- Normalise a binding into { fieldName = selectorSpec, ... }. Scalar form
-- ("foo.bar") maps to the kind's default field (dispatch.fields[1]); table
-- form is passed through.
local function normaliseBinding(binding, kind, kindDef)
    if type(binding) == "string" then
        local dispatch = kindDef and kindDef.dispatch or nil
        local field = dispatch and dispatch.fields and dispatch.fields[1] or nil
        if not field then
            error(string.format(
                "binding: kind %q does not accept scalar binding %q -- use the table form",
                tostring(kind), tostring(binding)), 2)
        end
        return { [field] = binding }
    end
    if type(binding) == "table" then return binding end
    return nil
end

-- resolveAsync middleware: per-entry, kick the resolver for rows whose idField is set
-- but valueField is nil. Resolvers dedup, so re-kicks across paints are cheap.
-- Per Lattice cookbook 18 + ADR-043.
local function _kickResolverForEntry(entry, rows)
    local idField, valueField, resolver = entry.idField, entry.valueField, entry.resolver
    -- Loud-fail a malformed resolveAsync entry (author wrote a bad spec) rather than
    -- silently no-op'ing it -- the spec is internal-declarative, not a boundary.
    assert(idField and valueField and resolver and resolver.Request,
        "resolveAsync entry needs idField + valueField + resolver:Request")
    for _, row in ipairs(rows) do
        local id = row[idField]
        if id and row[valueField] == nil then
            resolver:Request(id)
        end
    end
end

local function processResolveAsync(widget, resolved)
    local spec = widget._hdgrResolveAsync
    -- Collection widgets bind to "items"; resolved.rows is never emitted.
    if not (spec and resolved.items) then return end
    for _, entry in ipairs(spec) do
        _kickResolverForEntry(entry, resolved.items)
    end
end

-- A push's two halves, apart so the profiler can sample each: the data (the
-- binding's selectors, then the resolver kicks for what they returned) and
-- the paint (the kind's dispatcher).
local function _resolveAll(widget, state, ctx)
    local resolved = {}
    for field, selectorSpec in pairs(widget._hdgrBinding) do
        resolved[field] = resolve(selectorSpec, state, ctx)
    end
    processResolveAsync(widget, resolved)
    return resolved
end

local function _paint(widget, resolved, ctx)
    widget._hdgrDispatcher(widget, resolved, ctx or {})
end

-- Resolve binding, run async middleware, call dispatcher. The one push path:
-- Engine:Apply, the OnShow hook and Engine:PushIfStale all land here, so a
-- completed push always leaves the widget current (not stale).
local function pushOne(widget, state, ctx)
    if not (widget._hdgrBound and widget._hdgrBinding and widget._hdgrDispatcher) then return end
    local perf = HDG.Perf
    if perf:Enabled() then
        perf:SamplePush(widget, _resolveAll, _paint, state, ctx)
    else
        _paint(widget, _resolveAll(widget, state, ctx), ctx)
    end
    widget._hdgrStale = false
end

-- ===== Public API =========================================================

-- Union of bound-selector read-closures. "static:"/"locale:" contribute nothing.
-- Returns "*" early if any read is "*".
local function _computeReadsClosure(binding)
    local readsClosure = {}
    for _, selectorSpec in pairs(binding) do
        if type(selectorSpec) == "string"
           and selectorSpec:sub(1, 7) ~= "static:"
           and selectorSpec:sub(1, 7) ~= "locale:" then
            readsClosure = HDG.Paths.Union(readsClosure, HDG.Selectors:GetReads(selectorSpec))
            if readsClosure == "*" then return "*" end
        end
    end
    return readsClosure
end

-- Bind one widget: stash normalised binding + dispatcher + read-closure,
-- register async kicks, install the OnShow hook.
local function _bindWidget(widget, id, spec)
    local kind       = spec.kind
    local kindDef    = HDG.WidgetTypes:Get(kind)   -- loud-fails on an unknown kind ("unknown widget kind")
    local dispatcher = kindDef.dispatch and kindDef.dispatch.push
    if not dispatcher then
        -- level 3: blame Engine:Build's caller (the config site), as the inline
        -- error(.., 2) did before this was extracted one frame deeper.
        error(string.format("binding: kind %q has no dispatch (widget %q)",
            tostring(kind), tostring(id)), 3)
    end
    local binding = normaliseBinding(spec.binding, kind, kindDef)
    widget._hdgrBinding      = binding
    widget._hdgrDispatcher   = dispatcher
    widget._hdgrBound        = true
    widget._hdgrId           = id   -- diagnostics: lets overflow/paint warns name the exact widget
    widget._hdgrReadsClosure = _computeReadsClosure(binding)
    widget._hdgrAutoSized    = spec.width == "auto" or spec.height == "auto"
    -- Never pushed yet: widgets are born hidden, so the Layout pass that first
    -- places this one pushes it (Engine:PushIfStale).
    widget._hdgrStale        = true

    if spec.resolveAsync then
        widget._hdgrResolveAsync = spec.resolveAsync
    end

    -- OnShow hook: becomes-visible -> push current state (HookScript preserves existing handler).
    -- Auto-sized widgets skipped at boot get a reflow request when their intrinsic changes.
    -- Silent while the pipeline itself is showing the main frame: that pass binds
    -- everything with "*" right after, so the hook's push was a second full paint
    -- of every bound widget in every view (20 MB on each open, 2026-09-13 audit).
    if widget.HookScript then  -- exception(boundary): FontString labels lack HookScript; binding engine handles both frame and label widget types
        widget:HookScript("OnShow", function(self)
            if Engine._showingForPipeline then return end
            local bw, bh = self._intrinsicWidth, self._intrinsicHeight
            pushOne(self, HDG.Store:GetState(), { actionType = "ON_SHOW" })
            if self._hdgrAutoSized and (self._intrinsicWidth ~= bw or self._intrinsicHeight ~= bh) then
                if Engine._revealing then
                    -- Layout is showing it right now: hand the move back through
                    -- PushIfStale so this pass re-solves (any window).
                    self._hdgrRevealMoved = true
                elseif HDG.RequestReflow then  -- exception(nullable): RequestReflow registered at init time; nil in headless mock + early boot
                    HDG:RequestReflow()
                end
            end
        end)
    end
end

-- Show a frame on the pipeline's behalf: the OnShow hooks of every bound
-- descendant stay silent because the same pass paints them all through Apply.
-- Apply clears the flag too, so a handler that throws inside Show cannot
-- leave every later OnShow push disabled for the session.
-- Layout marks the stretch of its Apply that shows widgets. An OnShow push in
-- that stretch reports a moved auto-size through PushIfStale instead of asking
-- for a reflow. Apply clears it too, as it does _showingForPipeline, so a throw
-- mid-reveal cannot leave later OnShow pushes reporting to a pass that is over.
Engine._revealing = false
function Engine:SetRevealing(on)
    self._revealing = on
end

Engine._showingForPipeline = false
function Engine:ShowForPipeline(frame)
    self._showingForPipeline = true
    frame:Show()
    self._showingForPipeline = false
end

-- Layout calls this for every widget it places, right after showing it. A bound
-- widget is stale until its first push, and again whenever Apply skips it while
-- hidden; the pass that reveals it pushes it here instead of waiting for a later
-- reflow. A label is a FontString with no OnShow to hook, so this is its only
-- reveal push; a Frame's OnShow hook has usually pushed it already, leaving
-- nothing to do. Unbound widgets are never stale.
-- Returns true when the push moved an auto-sized widget's intrinsic size: the
-- solve that placed it is out of date (Layout:LayoutWindow re-solves).
local REVEAL_CTX = { actionType = "ON_SHOW" }
function Engine:PushIfStale(widget)
    -- Its OnShow hook pushed it as this reveal showed it, and that push moved its
    -- size. Reported here, the solve that placed it re-runs in this pass; left to
    -- the hook's reflow request, a Frame laid out one frame against its old size
    -- in the main window, and never re-solved in a satellite.
    if widget._hdgrRevealMoved then
        widget._hdgrRevealMoved = nil
        return true
    end
    if not widget._hdgrStale then return false end
    local bw, bh = widget._intrinsicWidth, widget._intrinsicHeight
    pushOne(widget, HDG.Store:GetState(), REVEAL_CTX)
    return widget._hdgrAutoSized and (widget._intrinsicWidth ~= bw or widget._intrinsicHeight ~= bh)
end

-- The window closed: every bound widget whose kind declares `release` (scroll
-- lists, dropdowns) drops the data it holds, and stays stale so the next push
-- refills it. Only bound widgets: nothing else would refill. Lists held 9.4 MB
-- after the window closed (memory census 2026-10-19).
function Engine:Release(rootFrame)
    for _, widget in pairs(rootFrame.widgets) do
        local release = HDG.WidgetTypes:Get(widget._hdgrKind).release
        if release and widget._hdgrBound then
            release(widget)
            widget._hdgrStale = true
        end
    end
end

-- Bind every built widget with a `binding` spec that is not bound yet.
-- Stamps _hdgrBound, normalised binding, dispatcher, and read-closure.
-- Also installs the OnShow hook (per Lattice cookbook 18 + ADR-043).
-- The main window builds each tab on its first visit and calls this again then;
-- binding a widget twice would hook its OnShow twice, so a bound one is skipped.
function Engine:Build(rootFrame, config)
    if not (rootFrame and rootFrame.widgets and config and config.widgets) then return end
    for id, spec in pairs(config.widgets) do
        local widget = rootFrame.widgets[id]
        if widget and spec.binding and not widget._hdgrBound then
            _bindWidget(widget, id, spec)
        end
    end
end

-- Per-widget Apply step. Returns "refreshed" / "skipped" / nil (not bound).
local function _applyWidget(widget, state, invalidation, dispatchCtx)
    if not (widget._hdgrBound and widget._hdgrBinding and widget._hdgrDispatcher) then return nil end
    local readsClosure = widget._hdgrReadsClosure   -- _bindWidget always sets this (strict read)
    if not HDG.Paths.MatchesAny(readsClosure, invalidation) then return "skipped" end
    -- Skip hidden widgets (zero cost) and mark them stale: the Layout pass that
    -- reveals them pushes them (Engine:PushIfStale).
    if widget.IsShown and not widget:IsShown() then  -- exception(boundary): IsShown absent in headless test mock; FrameXML-only
        widget._hdgrStale = true
        return "skipped"
    end
    pushOne(widget, state, dispatchCtx)
    return "refreshed"
end

-- True when `invalidation` is PURELY log-subtree churn (every path under
-- session.log.*). The invalidations trace emits via Log:Debug -> LOG_PUSH ->
-- invalidates session.log.entries -> re-enters Apply; tracing THAT would
-- self-spam at 100s/sec ("refreshed=0 skipped=N" when the Debug tab's log view
-- is hidden). Suppressing log-churn applies from the trace breaks the loop --
-- the log-view widget still refreshes, we just don't emit a trace line for the
-- tracer's own echo. "*" is intentionally NOT treated as log-churn.
local function _isLogChurnInvalidation(invalidation)
    if type(invalidation) ~= "table" then return false end
    for _, p in ipairs(invalidation) do
        if type(p) ~= "string" or p:sub(1, 12) ~= "session.log." then
            return false
        end
    end
    return invalidation[1] ~= nil
end

-- Push state to every bound widget. `invalidation` (path list or "*") scopes
-- the walk; nil defaults to "*".
function Engine:Apply(rootFrame, state, ctx, invalidation)
    self._showingForPipeline = false   -- see ShowForPipeline
    self._revealing = false            -- see SetRevealing
    if not (rootFrame and rootFrame.widgets and state) then return end
    invalidation = invalidation or "*"

    -- Diagnostic trace: count refreshed vs skipped when /hdgr trace invalidations
    -- is on. Suppressed for log-churn applies (the trace's own LOG_PUSH echo) so
    -- it can't drive a self-sustaining 100s/sec spam loop.
    local traceActive = HDG.Log:IsTraceActive("invalidations")
                        and not _isLogChurnInvalidation(invalidation)
    local refreshed, skipped = 0, 0

    -- dispatchCtx.actionType lets scrollbox-style widgets read retainsScroll
    -- (keep vs reset scroll on re-push).
    local dispatchCtx = { actionType = ctx and ctx.actionType }

    for _, widget in pairs(rootFrame.widgets) do
        local outcome = _applyWidget(widget, state, invalidation, dispatchCtx)
        if traceActive and outcome then
            if outcome == "refreshed" then refreshed = refreshed + 1
            else skipped = skipped + 1 end
        end
    end

    if traceActive then
        local invStr
        if invalidation == "*" then
            invStr = "*"
        elseif type(invalidation) == "table" then
            invStr = "{" .. table.concat(invalidation, ", ") .. "}"
        else
            invStr = tostring(invalidation)
        end
        HDG.Log:Debug("invalidations",
            ("apply: invalidation=%s refreshed=%d skipped=%d"):format(
                invStr, refreshed, skipped))
    end
end
