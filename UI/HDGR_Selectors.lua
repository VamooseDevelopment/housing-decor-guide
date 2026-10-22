-- HDG.Selectors
-- ============================================================================
-- Pure functions over state. Registry accepts two registration forms:
--
--   -- Legacy form (default reads = "*", refresh-all invalidation):
--   Selectors:Register("decor.items", function(state, ctx) ... end)
--
--   -- New form with state-path tracking:
--   Selectors:Register("decor.items", {
--       reads     = { "session.ui.decor.searchQuery", "session.ui.decor.activeProfessions" },
--       calls     = { "decor.allItems" },     -- transitively pulls in reads
--       memoized  = false,                     -- opt-in caching for cold-state walks
--       fn        = function(state, ctx) ... end,
--   })
--
-- Transitive closure of `reads` (own reads + every called selector's reads,
-- recursively) is computed lazily at first GetReads call. Cycles fall back
-- to "*" (conservative).

HDG = HDG or {}
HDG.Selectors = HDG.Selectors or {}

local Selectors = HDG.Selectors
local _registry = {}   -- [name] = { fn, reads, calls, memoized, _readsClosure?, _cached? }

-- Normalise the registration argument into a def table.
local function normaliseDef(defOrFn)
    if type(defOrFn) == "function" then
        return { fn = defOrFn, reads = "*", calls = {} }
    end
    if type(defOrFn) ~= "table" then
        error("Selectors:Register expects a function or {fn, reads?, calls?, memoized?, inputs?} table", 3)
    end
    if type(defOrFn.fn) ~= "function" then
        error("Selectors:Register: def.fn must be a function", 3)
    end
    -- Reactive fix: when a selector is registered in the new
    -- table form, omitting `reads` means "I have no DIRECT state reads"
    -- (the closure picks up everything via `calls`). Defaulting `reads`
    -- to "*" would short-circuit the transitive closure and defeat
    -- selective Apply for every selector that composes via `calls`.
    -- Function-form registrations keep "*" for backwards compat (above).
    --
    -- `inputs`: list of (state, ctx) -> value. Enables input-change memoization
    -- (reselect-style). Still participates in path-based InvalidateMemos clearing.
    return {
        fn       = defOrFn.fn,
        reads    = defOrFn.reads or {},
        calls    = defOrFn.calls or {},
        memoized = defOrFn.memoized == true,
        inputs   = defOrFn.inputs,   -- nil or list of (state, ctx) -> value
    }
end

-- Register-time def validation. Errors loudly on shape violations so typos
-- surface at boot rather than as silent-empty UI on first Refresh. Mirrors
-- Blizzard Settings' ErrorIfInvalidSettingArguments pattern -- contract
-- checks at registration, not at call time.
--
-- Validates:
--   * name        -- non-empty string
--   * def.reads   -- "*" OR a list of strings (state paths)
--   * def.calls   -- a list of strings (selector names)
--   * def.memoized -- nil or boolean
--   * def.inputs  -- nil or list of functions
-- (def.fn already checked in normaliseDef.)
local function _validateSelectorDef(name, def)
    if type(name) ~= "string" or name == "" then
        error(("Selectors:Register: name must be a non-empty string, got %s"):format(type(name)), 4)
    end
    if def.reads ~= "*" then
        if type(def.reads) ~= "table" then
            error(("Selectors:Register %q: def.reads must be \"*\" or a list of paths, got %s")
                :format(name, type(def.reads)), 4)
        end
        for i, path in ipairs(def.reads) do
            if type(path) ~= "string" then
                error(("Selectors:Register %q: def.reads[%d] must be a string path, got %s")
                    :format(name, i, type(path)), 4)
            end
        end
    end
    if type(def.calls) ~= "table" then
        error(("Selectors:Register %q: def.calls must be a list of selector names, got %s")
            :format(name, type(def.calls)), 4)
    end
    for i, called in ipairs(def.calls) do
        if type(called) ~= "string" then
            error(("Selectors:Register %q: def.calls[%d] must be a selector name string, got %s")
                :format(name, i, type(called)), 4)
        end
    end
    if def.memoized ~= nil and type(def.memoized) ~= "boolean" then
        error(("Selectors:Register %q: def.memoized must be boolean or nil, got %s")
            :format(name, type(def.memoized)), 4)
    end
    if def.inputs ~= nil then
        if type(def.inputs) ~= "table" then
            error(("Selectors:Register %q: def.inputs must be a list of functions or nil, got %s")
                :format(name, type(def.inputs)), 4)
        end
        for i, inputFn in ipairs(def.inputs) do
            if type(inputFn) ~= "function" then
                error(("Selectors:Register %q: def.inputs[%d] must be a function, got %s")
                    :format(name, i, type(inputFn)), 4)
            end
        end
    end
end

function Selectors:Register(name, defOrFn)
    local def = normaliseDef(defOrFn)
    _validateSelectorDef(name, def)
    -- If `inputs` is declared, wrap the selector body in an HDG.Memo so
    -- the input-reference equality check short-circuits re-runs when
    -- nothing the selector depends on actually changed. The Memo's
    -- :Clear() method is invoked by InvalidateMemos for path-based
    -- reactive eviction.
    if def.inputs and HDG.Memo.Memo then
        def.memoized = true   -- implied: an inputs-memo selector is memoized
        def._memo = HDG.Memo.Memo({
            inputs  = def.inputs,
            compute = function(...) return def.fn(...) end,
        })
    end
    _registry[name] = def
end

-- Recursive closure compute. Visiting set guards against cycles -- any cycle
-- collapses the participating selectors to "*" (conservative; same cost as
-- legacy refresh-all behaviour).
local function computeReadsClosure(name, visiting)
    local def = _registry[name]
    if not def then return "*" end
    if def._readsClosure ~= nil then return def._readsClosure end
    visiting = visiting or {}
    if visiting[name] then return "*" end
    visiting[name] = true

    local closure = def.reads
    if closure ~= "*" then
        for _, calledName in ipairs(def.calls) do
            local sub = computeReadsClosure(calledName, visiting)
            closure = HDG.Paths.Union(closure, sub)
            if closure == "*" then break end
        end
    end

    def._readsClosure = closure
    visiting[name] = nil
    return closure
end

function Selectors:GetReads(name)
    return computeReadsClosure(name)
end

-- Resolve a selector's value via its three paths (input-memo / memoized-cache /
-- fresh compute). Split out of Selectors:Call so the perf probe can time ALL
-- paths at one site without threading a timer through each early return.
--
-- Selectors are pure (Iron Invariant 1): (state, ctx) -> value, no
-- Blizzard API calls, no secret values, no taint. The only way a
-- selector can error is a real bug in our state shape or selector
-- composition -- bugs we want to SURFACE via stack trace, not swallow
-- into "return nil" which manifests downstream as silent empty UI.
-- Per Reference/MIDNIGHT_SECRET_VALUES.md, blanket pcall is the
-- anti-pattern; resolvers handle Tier 1 guards at the actual API
-- boundary (resolvers like StaticData.VendorAugment:ResolveName guard
-- there), so internal pcall here catches nothing legitimate. The
-- ErrorBoundaryMiddleware still wraps the dispatch chain at the
-- outer layer for crash-recovery on subscriber fan-out.
-- Dispatch counter for memo aging: InvalidateMemos advances it once per
-- dispatch and drops any memo whose last hit is older than
-- Constants.MEMO_IDLE_DISPATCHES, so a view left behind stops pinning its
-- derived copy of the catalog for the whole session.
local _dispatchSeq = 0
-- While the main window is shown its lists hold the rows these memos built, so
-- an aged-out memo frees nothing and the next view switch rebuilds it (~1.3 MB
-- for Decor). The window's visibility stage holds aging while it is open; closing
-- drops every memo anyway (memory plan 2026-10-19 sec 6, item 8).
local _agingHeld = false

function Selectors:HoldAging(held)
    _agingHeld = held
end

local function _callInner(def, state, ctx)
    -- Input-memo path: handles cache hit/miss via input-reference equality.
    -- Still subject to path-based InvalidateMemos clearing.
    if def._memo then
        def._usedAt = _dispatchSeq
        return def._memo(state, ctx)
    end
    -- Memo hit: return cached result without re-running fn
    if def.memoized and def._cached ~= nil then
        def._usedAt = _dispatchSeq
        return def._cached.value
    end
    local result = def.fn(state, ctx)
    if def.memoized then
        def._cached = { value = result }
        def._usedAt = _dispatchSeq
    end
    return result
end

function Selectors:Call(name, state, ctx)
    local def = _registry[name]
    if not def then return nil end
    -- Perf probe: time the resolve (memo hit + cache miss + fresh compute all
    -- counted) when the perf sub-gate is on. boundary: HDG.Perf is optional
    -- instrumentation, absent in early boot / headless tests.
    local perf = HDG.Perf
    if perf and perf:Enabled() then
        local t0, k0 = perf:Open()
        local result = _callInner(def, state, ctx)
        perf:RecordSelector(name, t0, k0)
        return result
    end
    return _callInner(def, state, ctx)
end

-- Shorthand for a value-equality enum: register N selectors of the form
--   <prefix>_<value> -> bool   (true when state at `statePath` == value)
-- Pattern recurs heavily for view/mode/subview/scope toggles. Example:
--   Selectors:DefineEnum("mogul.isSubView", "session.ui.mogul.subView",
--                        {"mogul","goblin","config"})
-- ...registers mogul.isSubView_mogul / .isSubView_goblin / .isSubView_config.
function Selectors:DefineEnum(prefix, statePath, values)
    local segments = {}
    for seg in statePath:gmatch("[^.]+") do segments[#segments + 1] = seg end
    for _, value in ipairs(values) do
        local v = value
        self:Register(prefix .. "_" .. v, {
            reads = { statePath },
            fn = function(state)
                local node = state
                for _, seg in ipairs(segments) do
                    if type(node) ~= "table" then return false end
                    node = node[seg]
                end
                return node == v
            end,
        })
    end
end

-- Same shape as DefineEnum but DELEGATES to another selector (`source`)
-- instead of reading state directly. Used when the source selector applies
-- a default (e.g. recipes.listFilter returns "all" when the state
-- slot is nil) -- the enum equalities have to see the defaulted value, not
-- the raw nil.
function Selectors:DefineEnumOver(prefix, source, values)
    for _, value in ipairs(values) do
        local v = value
        self:Register(prefix .. "_" .. v, {
            calls = { source },
            fn = function(state, ctx)
                return self:Call(source, state, ctx) == v
            end,
        })
    end
end

-- Shorthand for the most common selector shape: pure state-path passthrough.
-- 50+ selectors in the codebase do this verbatim
--   { reads = {"session.ui.X.Y"}, fn = function(state) return state.session.ui.X.Y end }
-- Collapses to:
--   Selectors:DefinePath("decor.searchQuery", "session.ui.decor.searchQuery")
-- Returns the value at `path` (dot-traversed) from state, or nil if any segment
-- is missing. The declared `reads` matches the path verbatim so reactive
-- invalidation works the same as a hand-written passthrough.
function Selectors:DefinePath(name, path)
    local segments = {}
    for seg in path:gmatch("[^.]+") do segments[#segments + 1] = seg end
    self:Register(name, {
        reads = { path },
        fn = function(state)
            local node = state
            for _, seg in ipairs(segments) do
                if type(node) ~= "table" then return nil end
                node = node[seg]
            end
            return node
        end,
    })
end

function Selectors:Has(name)
    return _registry[name] ~= nil
end

function Selectors:GetRegistry()
    return _registry
end

-- Memo invalidation. Called synchronously from Store:_RawDispatch
-- right before _Notify so subscribers (BindingEngine) read fresh values.
-- Walks memoized selectors; clears any whose read-closure intersects the
-- invalidation set. Wildcard invalidation wipes all caches.
local function _dropMemo(def)
    def._cached = nil
    if def._memo and def._memo.Clear then def._memo:Clear() end
end

function Selectors:InvalidateMemos(invalidation)
    _dispatchSeq = _dispatchSeq + 1
    if invalidation == "*" then
        for _, def in pairs(_registry) do
            if def.memoized then _dropMemo(def) end
        end
        return
    end
    if type(invalidation) ~= "table" then return end
    local idleLimit = HDG.Constants.MEMO_IDLE_DISPATCHES
    for name, def in pairs(_registry) do
        if def.memoized then
            local closure = computeReadsClosure(name)
            if HDG.Paths.MatchesAny(closure, invalidation)
               or (not _agingHeld and def._usedAt and _dispatchSeq - def._usedAt > idleLimit) then
                _dropMemo(def)
            end
        end
    end
end

-- Test helper -- wipe registry between cases. Production code never calls.
function Selectors:_Reset()
    _registry = {}
end

