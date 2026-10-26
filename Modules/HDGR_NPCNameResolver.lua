-- HDG.NPCNameResolver
-- ============================================================================
-- An NPC's name in the client's language, by npcID: Recipe Sources' trainers and
-- vendors (the shipped data names them in English). C_TooltipInfo.GetHyperlink on a
-- creature link answers from the client's creature cache, so a cached NPC resolves at
-- once and an uncached one comes back empty while the client asks the server.
--
-- Async like ItemNameResolver: a miss returns the English name and queues the npcID;
-- a drain every BATCH_WINDOW probes the queue again and dispatches what it got in one
-- NPC_NAMES_RESOLVED, which writes session.npcNames.names. Callers read that path
-- (Store's RegisterFacadeReads contract), so the dispatch re-runs them. A name can come
-- in drains later than the first, so a miss stays queued for the next drain, up to
-- MAX_DRAINS misses; after that the NPC keeps its English name for the session. While
-- an NPC waits on a drain, or has been given up on, a caller's rebuild doesn't probe it.
--
-- Secret strings: under taint a creature link's name line can come back secret
-- (12.0.5). canaccesstable / canaccessvalue say so before any read that would throw,
-- and a secret name counts as a miss.

HDG = HDG or {}
HDG.NPCNameResolver = HDG.NPCNameResolver or {}
local R = HDG.NPCNameResolver

HDG.Log:RegisterTags({ npc_resolver = { user = false, level = "debug" } })

R._cache          = R._cache          or {}      -- [npcID] = name a probe returned this session
R._pending        = R._pending        or {}      -- [npcID] = drains that have missed it so far; probed again at the next
R._gaveUp         = R._gaveUp         or {}      -- [npcID] = true after MAX_DRAINS misses: English for the session
R._timerScheduled = R._timerScheduled or false   -- one drain timer pending

R.BATCH_WINDOW = 0.5
R.MAX_DRAINS   = 6   -- 3 s of retries

-- The client's placeholder while it asks the server, in the client's language. In game
-- (2026-10-26) an uncached creature came back with no name line at all, and named on a
-- later call; the 12.0.5 gotcha saw a "Retrieving..." line, so a line holding the global
-- still counts as a miss.
local function _isPlaceholder(text)
    return text == "" or text:find(_G.RETRIEVING_DATA, 1, true) ~= nil
        or text:find(_G.RETRIEVING_ITEM_INFO, 1, true) ~= nil
end

-- The name line of a creature link, or nil when the client has no name to share yet.
local function _probe(npcID)
    -- The creature ID is the GUID's sixth field: "Creature-0-0-0-0-<id>-0" names the NPC,
    -- "...-0-<id>" puts it in the spawn field and gets nil (in game, 2026-10-26).
    local data = C_TooltipInfo.GetHyperlink("unit:Creature-0-0-0-0-" .. npcID .. "-0")
    if not (data and canaccesstable(data)) then return nil end   -- exception(boundary): nil for a creature the client can't link; a secret table under taint
    local line = data.lines and data.lines[1]   -- exception(boundary): an empty tooltip has no lines
    if not (line and canaccesstable(line)) then return nil end   -- exception(boundary): a secret line under taint
    local text = line.leftText
    if not (text and canaccessvalue(text)) or _isPlaceholder(text) then return nil end   -- exception(boundary): no name yet, or a secret one
    return text
end

function R:_Queue(npcID, misses)
    self._pending[npcID] = misses
    if self._timerScheduled then return end
    self._timerScheduled = true
    C_Timer.After(self.BATCH_WINDOW, function() R:Drain() end)
end

-- A drain missed it: queue it for the next drain, or give up after MAX_DRAINS misses.
function R:_Retry(npcID, misses)
    if misses >= self.MAX_DRAINS then
        self._gaveUp[npcID] = true
        return
    end
    self:_Queue(npcID, misses)
end

-- ResolveName: (name, resolved). The reducer's cache, then this session's probes, then
-- a fresh probe; a miss queues the npcID and answers the English fallback.
function R:ResolveName(npcID, fallbackName)
    local stored = HDG.Store:GetState().session.npcNames.names[npcID]
    if stored then return stored, true end
    if self._cache[npcID] then return self._cache[npcID], true end
    if self._pending[npcID] or self._gaveUp[npcID] then return fallbackName, false end   -- exception(nullable): only NPCs waiting on a drain or given up on
    local name = _probe(npcID)
    if name then
        self._cache[npcID] = name
        return name, true
    end
    self:_Queue(npcID, 0)
    return fallbackName, false
end

-- Drain: probe the queue once more and dispatch every name that came in.
function R:Drain()
    self._timerScheduled = false
    local batch = self._pending
    self._pending = {}
    local entries, missed = {}, 0
    for npcID, misses in pairs(batch) do
        local name = _probe(npcID)
        if name then
            entries[#entries + 1] = { npcID = npcID, name = name }
        else
            missed = missed + 1
            self:_Retry(npcID, misses + 1)
        end
    end
    -- /hdgr trace npc_resolver: how names arrive, drain by drain.
    if HDG.Log:IsTraceActive("npc_resolver") then
        HDG.Log:Debug("npc_resolver", ("NPC names: %d resolved, %d not yet"):format(#entries, missed))
    end
    if #entries > 0 then
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.NPC_NAMES_RESOLVED, payload = { entries = entries } })
    end
    return entries
end

-- No blizzardEvents: a miss schedules its own drain.
HDG.Modules:Declare({
    name = "NPCNameResolver",
    dependencies = {},
    ownsBlizzardNamespaces = { "C_TooltipInfo.GetHyperlink" },
})
