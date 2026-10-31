-- HDG.Resolver -- resolver registry: the facade-poll tick convention, owned.
-- ============================================================================
-- Design: Lattice/docs/SELFREG_RESOLVER_DESIGN_2026-06-11.md Part 2; species
-- taxonomy: Lattice/docs/TICK_REVALIDATION_2026-06-11.md.
--
-- A "resolver" is a module facade whose data lives OUTSIDE state (a live
-- Blizzard API or a module-local index) but whose consumers are pure
-- selectors (ADR-031 sanctioned impurity-behind-facade). The registry mints
-- ONE canonical re-pull signal per facade -- session.resolvers.<name>.tick --
-- and registers the action(s) that bump it via HDG.Actions:Register, so the
-- bump convention has a single owner and the reads cross-check
-- (scripts/semantic_sweep.lua rule 4c) extracts a machine-readable
-- facade -> required-reads list straight from these Register calls.
--
-- Species map (TICK_REVALIDATION):
--   A facade-poll   -> Resolver:Register (this registry's home turf)
--   B state-resident -> NO resolver; consumers read the data path directly
--     (a dissolved-B facade keeps a RegisterFacadeReads contract so the
--      sweep still enforces its required data-path reads)
--   C domain changeSeq -> reducer-owned counters, named `changeSeq`
--   D dependency marker -> Resolver:RegisterStatic (tick stays 0 forever)
--   E clocks (LUMBER_TICK) -> outside the registry, explicitly named clocks

HDG = HDG or {}
HDG.Resolver = HDG.Resolver or { _entries = {}, _facadeReads = {} }
local R = HDG.Resolver

local function tickPath(name) return "session.resolvers." .. name .. ".tick" end

-- One bump action -> Actions:Register. `spec` per-action fields:
--   name (ACTIONS key, required), reduce (extra domain writes, runs BEFORE the
--   bump), invalidates (extra paths beyond the tick), noisy, persists
--   (default FALSE -- resolver signals are transient), bump:
--     nil          -> tick = tick + 1 (the default profile)
--     false        -> signal-only: invalidate the tick path WITHOUT writing it
--                     (consumers re-pull on path invalidation; value untouched)
--     function     -> tick = bump(currentTick, payload) (generation stamps)
local function registerBumpAction(resolverName, spec)
    local path = tickPath(resolverName)
    local invalidates = { path }
    for _, p in ipairs(spec.invalidates or {}) do invalidates[#invalidates + 1] = p end
    local extraReduce, bump = spec.reduce, spec.bump
    HDG.Actions:Register{
        name         = spec.name,
        persists     = spec.persists == true,
        combatUnsafe = spec.combatUnsafe == true,
        noisy        = spec.noisy == true or nil,
        -- Card grids consult this per action (Components._shouldRetainScroll);
        -- a resolver-registered row patch is exactly the in-place change that
        -- must not send a grid back to the top.
        retainsScroll = spec.retainsScroll == true or nil,
        invalidates  = invalidates,
        reduce       = function(state, payload)
            if extraReduce then extraReduce(state, payload) end
            if bump ~= false then
                local slot = state.session.resolvers[resolverName]
                if type(bump) == "function" then
                    slot.tick = bump(slot.tick, payload)
                else
                    slot.tick = slot.tick + 1
                end
            end
        end,
    }
end

-- Register one resolver. block:
--   name    -- registry key; mints session.resolvers.<name>.tick
--   facade  -- selector-visible access pattern(s) the sweep enforces the tick
--              read against. String module name, list of module names, or
--              { module=, method= } for method-scoped facades (one module
--              hosting two resolvers, e.g. QuestNameResolver:IsComplete), or a
--              list of those (two methods on one tick: questStatus).
--   requires -- OPTIONAL extra read paths the facade's output depends on
--              (state-resident inputs, e.g. prices' account.prices caches).
--   actions -- list of bump-action specs (see registerBumpAction).
function R:Register(block)
    if type(block) ~= "table" or type(block.name) ~= "string" then
        error("Resolver:Register requires { name = <string>, ... }", 2)
    end
    if self._entries[block.name] then
        error(("Resolver:Register: duplicate resolver %q"):format(block.name), 2)
    end
    if block.facade == nil then
        error(("Resolver:Register(%s): facade required (sweep cross-check key)"):format(block.name), 2)
    end
    if type(block.actions) ~= "table" or #block.actions == 0 then
        error(("Resolver:Register(%s): actions list required (use RegisterStatic for markers)"):format(block.name), 2)
    end
    self._entries[block.name] = block
    for _, spec in ipairs(block.actions) do
        registerBumpAction(block.name, spec)
    end
end

-- Species-D degenerate: a dependency MARKER for immutable TOC-shipped data
-- (ADR-003c). Mints the slot; tick stays 0; no actions; selectors declare the
-- read so shipped-data deps flow through read-tracking like any state path.
function R:RegisterStatic(block)
    if type(block) ~= "table" or type(block.name) ~= "string" then
        error("Resolver:RegisterStatic requires { name = <string>, facade = <string> }", 2)
    end
    if self._entries[block.name] then
        error(("Resolver:RegisterStatic: duplicate resolver %q"):format(block.name), 2)
    end
    if block.facade == nil then
        error(("Resolver:RegisterStatic(%s): facade required"):format(block.name), 2)
    end
    block.static = true
    self._entries[block.name] = block
end

-- Dissolved species-B contract: the facade's data is STATE (consumers read the
-- data path; no tick exists). Recorded so the sweep enforces the required
-- reads on facade callers and the dissolution stays machine-checkable.
function R:RegisterFacadeReads(block)
    if type(block) ~= "table" or block.facade == nil or type(block.requires) ~= "table" then
        error("Resolver:RegisterFacadeReads requires { facade = ..., requires = { paths } }", 2)
    end
    self._facadeReads[#self._facadeReads + 1] = block
end

-- Session factory hook: top up `slots` with one { tick = 0 } per registered
-- resolver (static included). Store's main chunk builds a placeholder state at
-- FILE LOAD (before the Register blocks at its EOF run), so minting must be
-- re-runnable: EnsureSession calls this at hydrate, after every registration,
-- and before any dispatch or selector can touch the slots.
function R:EnsureSlots(slots)
    for name in pairs(self._entries) do
        slots[name] = slots[name] or { tick = 0 }
    end
    return slots
end

function R:MintSlots()
    return self:EnsureSlots({})
end

-- Boot cross-check (called from Init after all selectors register): any
-- selector read under session.resolvers.<X> must name a registered resolver --
-- a typo'd resolver path is a boot error exactly like a typo'd action name.
function R:ValidateSelectorReads(registry)
    local bad = {}
    for selName, def in pairs(registry) do
        local reads = def.reads
        if type(reads) == "table" then
            for _, path in ipairs(reads) do
                local rname = type(path) == "string" and path:match("^session%.resolvers%.([^%.]+)")
                if rname and not self._entries[rname] then
                    bad[#bad + 1] = ("%s reads %s (no resolver %q registered)"):format(selName, path, rname)
                end
            end
        end
    end
    if #bad > 0 then
        error("HDG resolver reads cross-check failed:\n  " .. table.concat(bad, "\n  "))
    end
end

function R:Get(name)
    return self._entries[name]
end

-- Test helper -- wipe between harness cases.
function R:_Reset()
    self._entries = {}
    self._facadeReads = {}
end
