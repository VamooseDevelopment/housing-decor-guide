-- HDG.Log
-- ============================================================================
-- Single structured logging surface. One producer API, multiple consumers (status rail, debug tab, chat).
-- See ADR-013. tag.user=true is the ONLY routing rule for the status rail.
-- Producers: Log:Push / :Debug / :Info / :Warn / :Error / :Success / :Notify

HDG = HDG or {}
HDG.Log = HDG.Log or {
    _tags = {},       -- [tagName] = { user, level?, duration? }
}

local Log = HDG.Log

-- ===== Tag registry ======================================================

-- RegisterTags(map) -- called at engine init and by Modules:Phase1 for module logTags.
-- Duplicate tag names error loudly (closed-set taxonomy, same as action types).
function Log:RegisterTags(map)
    if type(map) ~= "table" then return end
    for name, def in pairs(map) do
        if type(name) ~= "string" or name == "" then
            error("HDG.Log:RegisterTags: tag name must be non-empty string", 2)
        end
        if self._tags[name] then
            error(("HDG.Log: duplicate log tag %q"):format(name), 2)
        end
        if type(def) ~= "table" then
            error(("HDG.Log: tag %q definition must be a table"):format(name), 2)
        end
        if def.user == nil then
            error(("HDG.Log: tag %q missing required `user` flag"):format(name), 2)
        end
        self._tags[name] = def
    end
end

function Log:GetTag(name) return self._tags[name] end
function Log:HasTag(name) return self._tags[name] ~= nil end

-- Auto-register the three standard tab toast tags (*_action / *_save / *_error).
function Log:RegisterTabTags(tab)
    if type(tab) ~= "string" or tab == "" then
        error("HDG.Log:RegisterTabTags: tab name must be non-empty string", 2)
    end
    self:RegisterTags({
        [tab .. "_action"] = { user = true, level = "info",    duration = 2  },
        [tab .. "_save"]   = { user = true, level = "success", duration = 3  },
        [tab .. "_error"]  = { user = true, level = "error",   duration = nil },
    })
end

-- Fast check for hot-path callers; skip Push when no trace is active (zero cost in production).
function Log:IsTraceActive(name)
    if not HDG.Store or not HDG.Store.GetState then return false end
    local state = HDG.Store:GetState()
    if not (state and state.session and state.session.log
            and state.session.log.activeTraces) then return false end
    return state.session.log.activeTraces[name] == true
end

-- Backward-compat alias (HDG.Log.TAGS == HDG.Log._tags after init).
Log.TAGS = Log._tags

-- ===== Push API ==========================================================

local function nowTime()
    return _G.GetTime and _G.GetTime() or 0  -- exception(boundary): GetTime absent in test environments
end

-- Internal: validate tag + build the dispatch payload
local function buildEntry(self, args)
    if type(args) ~= "table" then
        error("HDG.Log:Push expects a table", 3)
    end
    local tag = args.tag
    if type(tag) ~= "string" or tag == "" then
        error("HDG.Log:Push requires a non-empty `tag`", 3)
    end
    local tagDef = self._tags[tag]
    if not tagDef then
        error(("HDG.Log:Push: unknown tag %q -- register it via module logTags or HDG.Log:RegisterTags"):format(tag), 3)
    end
    return {
        tag       = tag,
        level     = args.level or tagDef.level or "info",
        text      = args.text or "",
        timestamp = args.timestamp or nowTime(),
        duration  = args.duration ~= nil and args.duration or tagDef.duration,
        metadata  = args.metadata,
    }
end

-- Internal: dispatch through Store. Store is available by first Push (after OnInitialize).
local function dispatchPush(payload)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.LOG_PUSH,
        payload = payload,
    })
end

function Log:Push(args)
    dispatchPush(buildEntry(self, args))
end

function Log:Debug(tag, text, metadata)
    dispatchPush(buildEntry(self, { tag = tag, level = "debug", text = text, metadata = metadata }))
end

function Log:Info(tag, text, metadata)
    dispatchPush(buildEntry(self, { tag = tag, level = "info", text = text, metadata = metadata }))
end

function Log:Warn(tag, text, metadata)
    dispatchPush(buildEntry(self, { tag = tag, level = "warn", text = text, metadata = metadata }))
end

function Log:Error(tag, text, metadata)
    dispatchPush(buildEntry(self, { tag = tag, level = "error", text = text, metadata = metadata }))
end

function Log:Success(tag, text, metadata)
    dispatchPush(buildEntry(self, { tag = tag, level = "success", text = text, metadata = metadata }))
end

-- Single funnel for slash-output / command feedback. Prints to chat + records to Debug tab.
-- Tag is always "notify" (not the status rail).
function Log:Notify(level, text, metadata)
    dispatchPush(buildEntry(self, { tag = "notify", level = level, text = text, metadata = metadata }))
end

-- A notify line printed to chat WITHOUT the Store. Notify's chat print comes from
-- Log:_OnNotify, a Store subscriber, so it starves with the rest of a notification
-- flush that a raising subscriber aborts -- the one failure this exists to report
-- (Store _callSubscriber). Same formatting and next-frame taint-safe print as
-- _RenderEntry; nothing is recorded, so callers that want the Debug tab entry also
-- Log:Error it.
function Log:PrintDirect(level, text)
    self:_RenderEntry(buildEntry(self, { tag = "notify", level = level, text = text }))
end

-- ===== Engine-level tags (always present) ================================
-- Module tags added via Modules:Phase1. `user = true` = only thing that surfaces to the status rail.
-- Both boot-time registration and Log:_Reset read from this table (single source).
local ENGINE_TAGS = {
    -- Developer tags: debug tab only, no status rail
    dispatch      = { user = false, level = "debug" },   -- action stream via LoggerMiddleware
    selector      = { user = false, level = "debug" },   -- selector calls (verbose)
    binding       = { user = false, level = "debug" },   -- binding refresh decisions
    cache         = { user = false, level = "debug" },   -- memo hits/misses
    invalidations = { user = false, level = "debug" },   -- /hdgr trace invalidations: dispatch invalidation sets
    boot           = { user = false, level = "debug" },
    recipe_capture = { user = true, level = "info" },    -- runtime decor-recipe reagent capture (ProfessionScanner)
    layout        = { user = false, level = "warn"  },   -- over-spec rows, anchor inconsistencies (warn-level -> always prints)
    modules       = { user = false, level = "error" },   -- Modules engine lifecycle errors (Phase1/Phase2/Shutdown failures)

    -- Chat notifications (Log:Notify -- slash output, command feedback). Always
    -- chats (shouldTrace) + logged to the Debug tab, but user=false so it does
    -- NOT toast the status rail. The funnel for the ad-hoc print()s.
    notify        = { user = false, level = "info" },

    -- Boundary diagnostic tags (warn-level). Registered centrally so Log:Push accepts them
    -- without per-file boilerplate (cold-path only -- recovery is possible, but worth noting).
    store         = { user = false, level = "warn" },   -- reducer-internal diagnostics (invalidates fn errors etc.)
    tooltip       = { user = false, level = "warn" },   -- TooltipEngine: resolveDef recipe failures
    scroll        = { user = false, level = "warn" },   -- scrollbox ops (ScrollToElementData failed etc.)
    treeList      = { user = false, level = "warn" },   -- TreeList afterSetItems hook errors
    decor         = { user = false, level = "warn" },   -- DecorController: catalog/destroy boundary failures
    -- waypoints registered by HDGR_Waypoints.lua at file-load (no Modules:Declare block).
    settings      = { user = false, level = "warn" },   -- Settings panel not yet registered (PRE-LOGIN race)
    model_preview = { user = false, level = "warn" },   -- 3D model SetModelByFileID failures
    import        = { user = false, level = "warn" },   -- ShoppingCodec: decor IDs that didn't resolve to a catalog item (dropped from import)

    -- User tags: also surface on the status rail
    error     = { user = true,  level = "error",   duration = nil  },  -- sticky
    combat    = { user = true,  level = "info",    duration = nil  },  -- sticky while in lockdown
    theme     = { user = true,  level = "info",    duration = 3    },
    migration = { user = true,  level = "success", duration = 10   },
    debug_tab    = { user = true,  level = "info",    duration = 2    },  -- "Copied to clipboard" toasts
    decor_action = { user = true,  level = "info",    duration = 2    },  -- decor tab "Favorited X" toasts
    queue        = { user = true,  level = "info",    duration = 3    },  -- crafting queue add/remove/clear toasts
    filter       = { user = true,  level = "info",    duration = 3    },  -- recipe filter chain changes
    ui_action    = { user = true,  level = "info",    duration = 2    },  -- chrome-level acks (view switch via slash, etc.)
}
Log:RegisterTags(ENGINE_TAGS)

-- ===== Trace consumer ====================================================
-- Subscribes to LOG_PUSH. Routes to chat via shouldTrace; tracks _lastPrintedID to avoid re-printing.

Log._lastPrintedID = 0

-- ===== Chat line composition ================================================
-- [HDG][Debug][Severity letter][Tag] <body>.
-- [Debug] badge when debug mode is on; severity letter absent for debug-level entries.

-- Severity -> single-letter chip. debug has no letter (the [Debug] badge stands in).
local LEVEL_LETTER = { info = "I", warn = "W", error = "E", success = "S" }

local DEBUG_BADGE = "|cffffffff[Debug]|r"  -- white (same as body); the mode badge
local DIM         = "|cff999999"           -- payload / trailing detail gray
local ACTION_TEAL = "|cff00a896"           -- dispatch action name (teal)

-- The entry's semantic level color as a "|cffRRGGBB" escape. Shared by the
-- severity letter and the [Tag] chip so they read as one colored unit.
local function levelCC(level)
    local r, g, b = HDG.Format.LogColor(level)
    return string.format("|cff%02x%02x%02x",
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

-- Sentence-case a tag for the chat chip: "layout" -> "Layout", "house_api" ->
-- "House_api". (The Debug tab keeps the raw lowercase tag via Format.LogLine.)
local function tagLabel(tag)
    return tag:sub(1, 1):upper() .. tag:sub(2)
end

-- "[HDG][Debug][X]" chrome shared by every formatter. Reads account debug
-- mode for the badge -- the same state shouldTrace consults, so the badge is
-- present exactly when the dispatch firehose is.
local function chatPrefix(entry)
    local out = HDG.Format.BRAND_PREFIX
    if HDG.Store:GetState().account.config.debug then
        out = out .. DEBUG_BADGE
    end
    local letter = LEVEL_LETTER[entry.level]
    if letter then
        out = out .. " " .. levelCC(entry.level) .. "[" .. letter .. "]|r"
    end
    return out
end

Log._formatters = {
    -- dispatch -- LoggerMiddleware action stream. [HDG][Debug][Dispatch] (tag
    -- chip in debug-gray, same shape as the default formatter) + action name in
    -- teal (it IS an action) + dim payload. Always debug-level, so chatPrefix
    -- adds no severity letter.
    dispatch = function(entry)
        local tagChip    = " " .. levelCC(entry.level) .. "[" .. tagLabel(entry.tag) .. "]|r"
        local prefix     = chatPrefix(entry) .. tagChip
        local payloadStr = entry.metadata.payloadStr
        if payloadStr ~= "" then
            return prefix .. " " .. ACTION_TEAL .. entry.text .. "|r " .. DIM .. payloadStr .. "|r"
        end
        return prefix .. " " .. ACTION_TEAL .. entry.text .. "|r"
    end,
}

-- Default formatter: [HDG][Debug][Severity][Tag] + body. [Tag] chip shares severity color.
Log._formatters.default = function(entry)
    local tagChip = " " .. levelCC(entry.level) .. "[" .. tagLabel(entry.tag) .. "]|r"
    local line    = chatPrefix(entry) .. tagChip .. " |cffffffff" .. entry.text .. "|r"
    local meta    = entry.metadata
    if type(meta) == "table" and type(meta.payloadStr) == "string" and meta.payloadStr ~= "" then
        line = line .. " " .. DIM .. meta.payloadStr .. "|r"
    end
    return line
end

-- Should this entry be chat-printed right now?
local function shouldTrace(entry)
    if not HDG.Store or not HDG.Store.GetState then return false end
    local state = HDG.Store:GetState()
    if not (state and state.session and state.session.log) then return false end
    -- notify is user-facing -- always chats (deferred at the sink, _RenderEntry).
    if entry.tag == "notify" then return true end
    -- Diagnostics (warn/error) live in the Debug tab via session.log; they mirror
    -- to chat ONLY in debug mode. Normal sessions keep a quiet chat and the
    -- chat-taint surface shrinks to user-facing notifies (own-surface, option 3).
    if (entry.level == "error" or entry.level == "warn") and state.account.config.debug then
        return true
    end
    -- Active traces (set by /hdgr trace <tag>)
    if state.session.log.activeTraces[entry.tag] then return true end
    -- Legacy: debug flag enables the dispatch firehose.
    if entry.tag == "dispatch" and state.account.config.debug then
        return true
    end
    return false
end

-- Render a single entry to chat. DEFERRED (Tier 4): LOG_PUSH dispatches
-- synchronously, so this is reached in the CALLER's execution -- frequently
-- tainted (Blizzard event handlers, housing-mode hooksecurefunc callbacks). A
-- print() there tags the new chat line's lineID secret, and Blizzard's later
-- FCF_RemoveAllMessagesFromChanSender crashes comparing it ("tainted by
-- HousingDecorGuide"). RunNextFrame re-enters in a clean top-level context so the
-- WHOLE string graph -- formatter included -- is built untainted. The shouldTrace
-- gate stays synchronous (it only reads our own state, no secret ops).
-- See Reference/MIDNIGHT_SECRET_VALUES.md "Case 2".
function Log:_RenderEntry(entry)
    if not entry or not shouldTrace(entry) then return end
    RunNextFrame(function()
        local formatter = self._formatters[entry.tag] or self._formatters.default
        local ok, line = pcall(formatter, entry)  -- exception(fire-forget): deferred render; recursive log would stack-overflow on a broken formatter
        if not ok or type(line) ~= "string" then return end
        local printer = _G and _G.print or function() end
        printer(line)
    end)
end

-- Subscriber callback: walks new entries since the last call.
function Log:_OnNotify(actionType)
    -- Debug-mode flips announce to chat (user request 2026-07-17): compare against
    -- the cached value so only genuine CONFIG_SET debug toggles speak. Seeded on
    -- first notification so boot state never false-announces.
    local dbg = HDG.Store:GetState().account.config.debug == true
    if self._lastDebugMode == nil then
        self._lastDebugMode = dbg
    elseif dbg ~= self._lastDebugMode then
        self._lastDebugMode = dbg
        self:Info("notify", dbg and "Debug mode ON -- dispatches and diagnostics will print to chat"
                             or  "Debug mode OFF -- chat goes quiet (Debug tab keeps recording)")
    end
    if actionType ~= HDG.Constants.ACTIONS.LOG_PUSH then return end
    local state = HDG.Store:GetState()
    local entries = state and state.session and state.session.log
                    and state.session.log.entries or {}
    for _, entry in ipairs(entries) do
        local idNum = entry.id  -- monotonic integer assigned in buildEntry
        if idNum and idNum > self._lastPrintedID then
            self:_RenderEntry(entry)
            self._lastPrintedID = idNum
        end
    end
end

-- Attach to Store at Init time. Idempotent.
function Log:AttachTraceConsumer()
    if self._traceAttached then return end
    if not (HDG.Store.Subscribe) then return end
    self._traceAttached = true
    HDG.Store:Subscribe(function(actionType)
        Log:_OnNotify(actionType)
    end)
end

-- ===== Test/debug helpers ================================================

function Log:_Reset()
    -- Wipe all registered tags AND re-register engine tags from the
    -- ENGINE_TAGS constant above. Used by tests between cases.
    self._tags = {}
    Log.TAGS   = self._tags
    self._lastPrintedID = 0
    self._traceAttached = false
    self:RegisterTags(ENGINE_TAGS)
end
