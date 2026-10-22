-- HDG.WidgetTypes
--
-- Central widget type registry. Architecture spec:
-- Project Documentation/UI_WIDGET_TAXONOMY.md section 3 (contract) + section 5
-- (engines as views) + section 12 (validation).
--
-- Registration is DEFERRED (lazy.nvim / which-key pattern): WidgetTypes:Register
-- enqueues at file-load time; Flush() processes the queue at OnInitialize and
-- runs the validator. This eliminates load-order sensitivity between files
-- that register widget types -- a kind can be registered anywhere in the TOC
-- and the registry is sealed after all modules have loaded.
--
-- The registry is keyed by `kind` (string). Each entry is a WidgetType
-- record: a flat table of optional capability fields per the action
-- taxonomy in section 2. Engines (Layout, Theme, BindingEngine, etc.)
-- read this registry directly -- no query layer.
--
-- See Project Documentation/UI_WIDGET_TAXONOMY.md section 3.7 for the
-- Widget Kind Catalog (Tier A atomic / B composite / C v0.6 new / D
-- specialized / E addon-local).
--
-- Reference patterns:
--   - lazy.nvim deferred queue + spec normalization
--     (LUA_SAMPLES.md section 4)
--   - nvim-cmp duck-typed provider contract
--     (LUA_SAMPLES.md section 5)

HDG = HDG or {}
HDG.WidgetTypes = HDG.WidgetTypes or {
    _queue    = {},                 -- [i] = { kind, def } pre-flush
    _registry = {},                 -- [kind] = normalized def post-flush
    _flushed  = false,
}

local WT = HDG.WidgetTypes

-- ===== Known field set (closed contract, validator-checked) ===============
-- Every key a WidgetType may set. Unknown keys error during validation.
-- Mirrors the contract in spec section 3.

local KNOWN_FIELDS = {
    -- Identity
    extends = true,
    tags    = true,
    key     = true,

    -- Data
    opts    = true,

    -- Construction (required)
    build   = true,

    -- Capability fields (all optional, all nilable)
    skin       = true,
    dispatch   = true,
    measure    = true,
    input      = true,
    slots      = true,
    list       = true,
    lifecycle  = true,
    animations = true,
    rendering  = true,
    persistAt  = true,
    validity   = true,

    -- v0.6 additions
    tooltip    = true,
    resize     = true,
    hover      = true,
    keyboard   = true,

    -- Pool config + destroy path
    pool    = true,
    destroy = true,

    -- release(widget): drop the data the widget holds while its window is closed;
    -- the next push refills it. BindingEngine:Release calls it on window hide.
    release = true,

    -- initialState(spec) -> table: optional initial Theme.Skinners state.
    -- Called by Layout's buildKind after build; result is passed through
    -- HDG.Theme:Register(widget, kindDef.skin, state). State-bearing kinds
    -- (chip's status) use this to carry per-instance paint state.
    initialState = true,

    -- requiresFont(spec) -> bool: optional predicate. When the WidgetType is
    -- text-bearing in general (button/label/editbox/chip) but specific spec
    -- shapes (icon-only buttons via spec.close / spec.atlas) don't render text,
    -- this predicate suppresses the validator's "missing font" requirement.
    -- Layout's validator consults this predicate instead of inspecting spec
    -- internals directly (spec section 5 -- engines query the registry).
    requiresFont = true,

    -- resolveCellKind(name) -> def|nil: for a kind whose specs name a cell kind
    -- (`cellKind`), the lookup its build uses. Layout's validator calls it, so a
    -- cell-kind typo fails the test gate instead of the tab's first build.
    resolveCellKind = true,

    -- checkSpec(spec) -> message|nil: for a kind whose build checks fields that
    -- name something outside the config (an action, a config key), that check.
    -- The build errors on its message; Layout's validator reports it, so the
    -- test gate sees it before the tab is ever opened.
    checkSpec = true,

    -- specFields = { "fieldName", ... }: closed-schema field allow-list for
    -- THIS kind's widget specs. Validator combines specFields with the
    -- universal field set; any spec field outside the union is rejected as
    -- a typo or retracted pattern. See cookbook 04 + ADR-024 (corrected).
    specFields = true,
}

-- ===== Registration (deferred queue) ======================================

-- Register a widget type. Enqueues for processing at Flush time. The kind
-- name is the canonical lookup key.
function WT:Register(kind, def)
    if self._flushed then
        error(("HDG.WidgetTypes:Register(%q) called after Flush()"):format(tostring(kind)), 2)
    end
    if type(kind) ~= "string" or kind == "" then
        error("HDG.WidgetTypes:Register: kind must be a non-empty string", 2)
    end
    if type(def) ~= "table" then
        error(("HDG.WidgetTypes:Register(%q): def must be a table"):format(kind), 2)
    end
    self._queue[#self._queue + 1] = { kind = kind, def = def }
end

-- ===== Validator ==========================================================

-- ===== Per-field validators ===============================================
-- Each `_validate<Field>(def, err [, registry])` checks ONE field group.
-- All take `err` as a callback so the orchestrator owns the (kind, errors)
-- closure. Early returns + flat shape: each validator is depth 1-3.

local function _validateBuild(def, err)
    if type(def.build) ~= "function" then
        err("missing required field `build` (must be a function)")
    end
end

local function _validateKnownFields(def, err)
    for k in pairs(def) do
        if not KNOWN_FIELDS[k] then
            err(("unknown field %q (not in the contract; see section 3)"):format(k))
        end
    end
end

local function _validateTags(def, err)
    if def.tags == nil then return end
    if type(def.tags) ~= "table" then
        err("`tags` must be a list of strings")
        return
    end
    for i, t in ipairs(def.tags) do
        if type(t) ~= "string" then
            err(("`tags[%d]` must be a string, got %s"):format(i, type(t)))
        end
    end
end

local function _validateKey(def, err)
    if def.key ~= nil and type(def.key) ~= "function" then
        err("`key` must be a function (spec, ctx) -> string")
    end
end

local function _validateDispatch(def, err)
    if def.dispatch == nil then return end
    if type(def.dispatch) ~= "table" then
        err("`dispatch` must be a table { fields, push }")
        return
    end
    if type(def.dispatch.fields) ~= "table" then
        err("`dispatch.fields` must be a list of field names")
    end
    if type(def.dispatch.push) ~= "function" then
        err("`dispatch.push` must be a function")
    end
end

local function _validateLifecycle(def, err)
    if def.lifecycle == nil then return end
    if type(def.lifecycle) ~= "table" then
        err("`lifecycle` must be a table { configure, reset }")
        return
    end
    if type(def.lifecycle.configure) ~= "function" then
        err("`lifecycle.configure` must be a function")
    end
    if type(def.lifecycle.reset) ~= "function" then
        err("`lifecycle.reset` must be a function")
    end
end

local function _validateRelease(def, err)
    if def.release ~= nil and type(def.release) ~= "function" then
        err("`release` must be a function (widget)")
    end
end

local function _validateInputSecure(def, err)
    if not (def.input and def.input.secure) then return end
    local sec = def.input.secure
    if type(sec) ~= "table" then
        err("`input.secure` must be a table { template, attributes }")
        return
    end
    if type(sec.attributes) ~= "table" or #sec.attributes == 0 then
        err("`input.secure.attributes` must be a non-empty list of strings")
        return
    end
    for i, a in ipairs(sec.attributes) do
        if type(a) ~= "string" then
            err(("`input.secure.attributes[%d]` must be a string"):format(i))
        end
    end
end

-- skin: paint role name. Section 3 / research finding (Roact tag strings,
-- CSS classes, nui.nvim highlight groups, Compose Modifier vals share this
-- shape): WidgetType declares the role; paint fn lives in Theme.Skinners.
local function _validateSkin(def, err)
    if def.skin == nil then return end
    if not (HDG.Theme and HDG.Theme.Skinners) then return end  -- exception(boundary): Theme absent in minimal test harnesses
    if type(def.skin) ~= "string" then
        err("`skin` must be a string (paint role name in HDG.Theme.Skinners)")
        return
    end
    if not HDG.Theme.Skinners[def.skin] then
        err(("`skin` references unknown paint role %q (not in HDG.Theme.Skinners)"):format(def.skin))
    end
end

-- initialState: function (spec, ctx) -> state table. Only meaningful when
-- `skin` is declared (state without a skinner has no consumer).
local function _validateInitialState(def, err)
    if def.initialState == nil then return end
    if type(def.initialState) ~= "function" then
        err("`initialState` must be a function (spec, ctx) -> state table")
    elseif def.skin == nil then
        err("`initialState` is declared but `skin` is not -- state has no consumer")
    end
end

-- The hooks Layout's validator calls.
local function _validateValidatorHooks(def, err)
    if def.requiresFont ~= nil and type(def.requiresFont) ~= "function" then
        err("`requiresFont` must be a function(spec) -> bool")
    end
    if def.resolveCellKind ~= nil and type(def.resolveCellKind) ~= "function" then
        err("`resolveCellKind` must be a function(name) -> cell kind def or nil")
    end
    if def.checkSpec ~= nil and type(def.checkSpec) ~= "function" then
        err("`checkSpec` must be a function(spec) -> error message or nil")
    end
end

-- extends: parent kind name. Parent must be registered AND must not itself
-- extend (depth-1 max -- forbids chains).
local function _validateExtends(def, registry, err)
    if def.extends == nil then return end
    if type(def.extends) ~= "string" then
        err("`extends` must be a string (kind name)")
        return
    end
    if not registry[def.extends] then
        err(("`extends` references unregistered kind %q"):format(def.extends))
        return
    end
    if registry[def.extends].extends ~= nil then
        err(("`extends` depth must not exceed 1 (parent %q itself extends %q)")
            :format(def.extends, registry[def.extends].extends))
    end
end

local function _validateValidity(def, err)
    if def.validity ~= nil and type(def.validity) ~= "function" then
        err("`validity` must be a function(state) -> bool")
    end
end

-- destroy: required if widget owns input.events / animations / pool
-- (prevents GC-cycle leaks through C++ frame refs).
local function _validateDestroyRequired(def, err)
    local needsDestroy = (def.input and def.input.events) or def.animations or def.pool
    if needsDestroy and type(def.destroy) ~= "function" then
        err("`destroy` is required when widget declares input.events, animations, or pool "
            .. "(prevents GC-cycle leaks through C++ frame refs)")
    end
end

local _TOOLTIP_FIELDS = {
    title = true, body = true, anchor = true, textFn = true,
    itemID = true, hyperlink = true, extraLines = true,
}

local function _validateTooltip(def, err)
    if def.tooltip == nil then return end
    local t = def.tooltip
    if type(t) ~= "function" and type(t) ~= "table" then
        err("`tooltip` must be a table OR a function(self) -> table")
        return
    end
    if type(t) ~= "table" then return end
    for k in pairs(t) do
        if not _TOOLTIP_FIELDS[k] then
            err(("`tooltip.%s` is not a known sub-field (use title/body/anchor/"
                .. "textFn/itemID/hyperlink/extraLines)"):format(k))
        end
    end
end

-- resize.minSize / maxSize: either a number (uniform across axes) or a
-- { w, h } table (when axes = "both"). Normalizes to { w, h } shape for
-- comparison. Caller-supplied `err` accumulates field-shape errors.
local function _normalizeResizeBound(field, v, err)
    if v == nil then return nil end
    if type(v) == "number" then return { w = v, h = v } end
    if type(v) ~= "table" then
        err(("`resize.%s` must be a number or { w, h } table"):format(field))
        return nil
    end
    if v.w ~= nil and type(v.w) ~= "number" then
        err(("`resize.%s.w` must be a number"):format(field))
    end
    if v.h ~= nil and type(v.h) ~= "number" then
        err(("`resize.%s.h` must be a number"):format(field))
    end
    return { w = v.w, h = v.h }
end

local function _validateResize(def, err)
    if def.resize == nil then return end
    if type(def.resize) ~= "table" then
        err("`resize` must be a table { grip, minSize, maxSize, persistAt, axes }")
        return
    end
    local r = def.resize
    if r.axes ~= nil and r.axes ~= "horizontal" and r.axes ~= "vertical" and r.axes ~= "both" then
        err("`resize.axes` must be 'horizontal', 'vertical', or 'both'")
    end
    -- Spec section 12 v0.6: grip references a sibling/child widget id.
    -- Cross-reference happens at build time in Layout (registry has no
    -- spec tree at flush time); validator only checks string shape here.
    if r.grip ~= nil and type(r.grip) ~= "string" then
        err("`resize.grip` must be a string widget id")
    end
    local minB = _normalizeResizeBound("minSize", r.minSize, err)
    local maxB = _normalizeResizeBound("maxSize", r.maxSize, err)
    if not (minB and maxB) then return end
    if minB.w and maxB.w and minB.w > maxB.w then
        err("`resize.minSize.w` exceeds `resize.maxSize.w`")
    end
    if minB.h and maxB.h and minB.h > maxB.h then
        err("`resize.minSize.h` exceeds `resize.maxSize.h`")
    end
end

local _NAV_KEYS = {
    ESCAPE = true, UP = true, DOWN = true, LEFT = true, RIGHT = true,
    ENTER = true, TAB = true, SPACE = true, HOME = true, END = true,
    PAGEUP = true, PAGEDOWN = true, DELETE = true, BACKSPACE = true,
}

local function _validateKeyboard(def, err)
    if def.keyboard == nil then return end
    if type(def.keyboard) ~= "table" or type(def.keyboard.nav) ~= "table" then
        err("`keyboard` must be a table { nav = { KEY = fn, ... } }")
        return
    end
    for key, handler in pairs(def.keyboard.nav) do
        if type(handler) ~= "function" then
            err(("`keyboard.nav[%q]` must be a function"):format(tostring(key)))
        elseif not _NAV_KEYS[key] then
            err(("`keyboard.nav` key %q is not a valid Blizzard key constant"
                .. " (allowed: ESCAPE/UP/DOWN/LEFT/RIGHT/ENTER/TAB/SPACE/"
                .. "HOME/END/PAGEUP/PAGEDOWN/DELETE/BACKSPACE)"):format(tostring(key)))
        end
    end
end

local function _validateHoverChildren(children, err)
    if type(children) ~= "table" then
        err("`hover.children` must be a list of widget ids")
        return
    end
    for i, child in ipairs(children) do
        if type(child) ~= "string" then
            err(("`hover.children[%d]` must be a string widget id"):format(i))
        end
    end
end

local function _validateHoverFloatingCTA(cta, registry, err)
    if type(cta) ~= "table" or type(cta.widget) ~= "string" then
        err("`hover.floatingCTA` must be a table with `widget` field (kind name)")
        return
    end
    if not registry[cta.widget] then
        err(("`hover.floatingCTA.widget` references unregistered kind %q"):format(cta.widget))
    end
    if cta.combatSafe ~= nil and type(cta.combatSafe) ~= "boolean" then
        err("`hover.floatingCTA.combatSafe` must be a boolean")
    end
end

local function _validateHover(def, registry, err)
    if def.hover == nil then return end
    if type(def.hover) ~= "table" then
        err("`hover` must be a table { children?, floatingCTA? }")
        return
    end
    if def.hover.children ~= nil then
        _validateHoverChildren(def.hover.children, err)
    end
    if def.hover.floatingCTA ~= nil then
        _validateHoverFloatingCTA(def.hover.floatingCTA, registry, err)
    end
end

local function _validatePool(def, err)
    if def.pool ~= nil and type(def.pool) ~= "table" then
        err("`pool` must be a table { preallocate?, versionKey? }")
    end
end

-- specFields: closed-schema field allow-list for this kind's widget specs.
-- Layout's _validateWidgetSpecFields iterates it with ipairs and uses each
-- entry as an allow-key, so a non-list / non-string entry silently widens or
-- narrows the allow-set instead of rejecting the typo. Shape-check it here so
-- a malformed specFields fails loud at registration like every sibling field.
local function _validateSpecFields(def, err)
    if def.specFields == nil then return end
    if type(def.specFields) ~= "table" then
        err("`specFields` must be a list of field-name strings")
        return
    end
    for i, f in ipairs(def.specFields) do
        if type(f) ~= "string" then
            err(("`specFields[%d]` must be a string field name, got %s"):format(i, type(f)))
        end
    end
end

-- NOTE on spec section 12 "v0.6 scroll API checks":
-- The spec requires the validator to forbid the legacy scroll template
-- (CLAUDE.md rule #29) inside `build` functions. Lua closures are opaque
-- at validation time -- we cannot introspect the template name passed
-- to CreateFrame inside a build closure body. Enforcement is therefore
-- tooling-based: a repo-level PreToolUse hook blocks the legacy template
-- literal from being written into ANY .lua file (stronger than a runtime
-- validator check). CLAUDE.md rule #29 + spec section 3.7 reinforce.

-- Per-WidgetType validation. Errors are accumulated and reported together
-- so one bad registration doesn't mask others. Returns an error list
-- (empty on success). Each _validate<X> handler is independent and reports
-- via the err callback -- the orchestrator owns the kind-tagged closure.
local function validateOne(kind, def, registry, errors)
    local function err(msg)
        errors[#errors + 1] = ("[%s] %s"):format(kind, msg)
    end
    _validateBuild(def, err)
    _validateKnownFields(def, err)
    _validateTags(def, err)
    _validateKey(def, err)
    _validateDispatch(def, err)
    _validateLifecycle(def, err)
    _validateRelease(def, err)
    _validateInputSecure(def, err)
    _validateSkin(def, err)
    _validateInitialState(def, err)
    _validateValidatorHooks(def, err)
    _validateExtends(def, registry, err)
    _validateValidity(def, err)
    _validateDestroyRequired(def, err)
    _validateTooltip(def, err)
    _validateResize(def, err)
    _validateKeyboard(def, err)
    _validateHover(def, registry, err)
    _validatePool(def, err)
    _validateSpecFields(def, err)
end

-- ===== Normalization (apply extends inheritance) ==========================

-- Apply `extends` field-merge. Parent's `opts.defaults` deep-merges into
-- child's. Function fields (build, skin, dispatch.push, etc.) wholly replace
-- when the child declares them; otherwise inherit from parent.
local function normalizeWithExtends(def, parent)
    if not parent then return def end

    local result = {}
    -- Copy parent fields first
    for k, v in pairs(parent) do result[k] = v end
    -- Child wins on field-by-field
    for k, v in pairs(def) do
        if k == "opts" and type(v) == "table" and type(parent.opts) == "table" then
            result.opts = HDG.TableUtils.DeepMerge("force", parent.opts, v)
        else
            result[k] = v
        end
    end
    -- Clear `extends` on the normalized child so engines don't see it
    result.extends = nil
    return result
end

-- ===== Flush ==============================================================

-- Process the queue. Called once at OnInitialize. Two-pass:
-- pass 1 stores raw defs (so `extends` references resolve), pass 2 runs
-- the validator and applies `extends` merging.
function WT:Flush()
    if self._flushed then return end
    self._flushed = true

    -- Pass 1: insert raw defs, catch duplicate kinds
    for _, entry in ipairs(self._queue) do
        if self._registry[entry.kind] then
            error(("HDG.WidgetTypes: duplicate registration for kind %q"):format(entry.kind), 2)
        end
        self._registry[entry.kind] = entry.def
    end

    -- Pass 2: validate every def
    local errors = {}
    for kind, def in pairs(self._registry) do
        validateOne(kind, def, self._registry, errors)
    end
    if #errors > 0 then
        error("HDG.WidgetTypes:Flush validation failures:\n  " ..
            table.concat(errors, "\n  "), 2)
    end

    -- Pass 3: apply extends inheritance (after validation so parent existence
    -- is guaranteed). Result is the engine-facing normalized def.
    local normalized = {}
    for kind, def in pairs(self._registry) do
        local parent = def.extends and self._registry[def.extends] or nil
        normalized[kind] = normalizeWithExtends(def, parent)
    end
    self._registry = normalized

    self._queue = nil
end

-- ===== Read API (engines consume this) ====================================

-- Look up a WidgetType by kind. Errors loudly on unknown kind so engine
-- bugs surface immediately rather than silently no-op.
function WT:Get(kind)
    if not self._flushed then
        error(("HDG.WidgetTypes:Get(%q): registry not flushed yet"):format(tostring(kind)), 2)
    end
    local def = self._registry[kind]
    if not def then
        error(("HDG.WidgetTypes:Get(%q): unknown widget kind"):format(tostring(kind)), 2)
    end
    return def
end

-- Soft lookup (no error on unknown). Used by validators / debug tools that
-- need to introspect without throwing.
function WT:TryGet(kind)
    return self._flushed and self._registry[kind] or nil
end

-- Iterate every registered kind. Order is iteration-order of `pairs`, which
-- is implementation-defined; callers that need stable order should sort
-- the returned list.
function WT:GetAll()
    return self._registry
end

-- ===== Test helpers =======================================================

function WT:_Reset()
    self._queue = {}
    self._registry = {}
    self._flushed = false
end
