-- HDG.Perf
-- ============================================================================
-- Engine-internal performance instrumentation: TIME (debugprofilestop, ms) and
-- ALLOCATION (collectgarbage("count"), KB) at the same four seams.
-- FLUSH cost: deferred subscriber fan-out (C_Timer.After(0)), not the reducer.
-- SELECTOR cost: per-selector call time (populated by HDG.Selectors:Call probe).
-- GATE: HDG_DB.perf (raw SV root, NOT Store/Config -- must be readable at boot
-- before Config hydrates; profile-scoped field didn't persist on fresh accounts).
-- Toggle: /hdgr perf on|off. Dump: /hdgr perf. Clear: /hdgr perf reset.

HDG = HDG or {}
HDG.Perf = HDG.Perf or {}
local P = HDG.Perf

-- Probe sites use debugprofilestop() (sub-ms); GetTime() is frame-granular -> 0ms per-frame.

-- Accumulators. Keyed for aggregation across many samples. total/max are ms,
-- kb/maxKB are kilobytes allocated inside the sample.
--   _flush[actionKey] = { count, total, max, kb, maxKB, subs }
--   _sel[name]        = { count, total, max, kb, maxKB }
--   _op[name]         = { count, total, max, kb, maxKB }  -- module ops outside the dispatch path
--   _stage[name]      = { count, total, max, kb, maxKB }  -- per-pipeline-stage cost (runPipeline)
--   _push[key]        = { count, total, max, kb, maxKB }  -- one bound widget's push, "<kind> <id>  data|paint"
--   _layout[key]      = { count, total, max, kb, maxKB }  -- Layout:LayoutWindow laps, "<window>  pass N <step>"
P._flush  = P._flush  or {}
P._sel    = P._sel    or {}
P._op     = P._op     or {}
P._stage  = P._stage  or {}
P._push   = P._push   or {}
P._layout = P._layout or {}
-- What every push cost, outermost pushes only: a layout lap takes what this
-- grew by inside its apply to split the apply into the widgets it revealed,
-- pushed, and the placement itself (the Layout stage carried 8.5 MB with
-- nothing to say how it divides, 2026-10-22 profile).
P._pushTotal = P._pushTotal or { ms = 0, kb = 0 }
-- Allocation since the last Reset, counted once: only OUTERMOST samples add to
-- it (a selector sampled inside a flush is already inside the flush's KB).
-- This is the one number to drive down when the target is the memory PEAK --
-- the peak is allocation rate against collector lag, and the rate is ours.
P._alloc = P._alloc or { kb = 0, samples = 0 }

-- Ordered timeline: chronological list of marks from the boot epoch, so the
-- startup chain (login -> ... -> decor browser visible) reads top-to-bottom.
--   _timeline[i] = { t = ms-since-epoch, label, ms = cost?, kind }
--     kind: "flush" | "op" | "rtt" | "event"
--   ms is the CPU cost of the step (nil for pure event markers); the GAP
--   between consecutive `t` values is wall-clock (includes async/idle waits --
--   NOT necessarily our cost). RTT marks carry ms = the external round-trip.
-- Capped so a long session doesn't grow unbounded; the boot chain is what
-- matters and it's all at the front.
P._timeline    = P._timeline or {}
P._epoch       = P._epoch    -- debugprofilestop() at OnInitialize; nil until set
P.TIMELINE_CAP = 400

-- ===== Gate ================================================================

-- exception(boundary): HDG_DB may be nil in tests / very early boot; missing = disabled (never load-bearing).
function P:Enabled()
    return _G.HDG_DB ~= nil and _G.HDG_DB.perf == true
end

-- ===== Recording ===========================================================

local function _bump(bucket, key, ms, kb, subs)
    local e = bucket[key]
    if not e then
        e = { count = 0, total = 0, max = 0, kb = 0, maxKB = 0 }
        bucket[key] = e
    end
    e.count = e.count + 1
    e.total = e.total + ms
    e.kb    = e.kb + kb
    if ms > e.max   then e.max   = ms end
    if kb > e.maxKB then e.maxKB = kb end
    if subs ~= nil then e.subs = subs end
    return e
end

-- ===== Sampling ============================================================
--
-- collectgarbage("count") reads the HEAP, not allocation. A collection landing
-- inside a sample makes that sample read NEGATIVE, and discarding the negative
-- samples would bias the answer rather than clean it: a window big enough to
-- trigger a collection is exactly a window that allocated a lot, so censoring
-- drops the biggest allocators first. So the collector is HELD for the length
-- of a sample, which makes the delta true allocation rather than net heap
-- movement. Only the OUTERMOST probe holds it: a selector sample nested inside
-- a flush sample must not release it while the flush is still measuring, which
-- is what _depth counts. (Same design as Mingle's MGL_Perf and Blizzard's own
-- BenchmarkUtil.)
--
-- THE TRADE, stated because it is real: if an error escapes a probed call the
-- collector stays held until something restarts it, and memory climbs in a way
-- that reads as a leak. Every slash-command entry point releases it (a human
-- typing a command can never be inside a sample), a /reload resets the Lua
-- state anyway, and the profiler is off by default -- so the exposure is one
-- developer's session with perf on.
--
-- WHILE A SAMPLE RUNS, VITALS READS GROSS ALLOCATION. Nothing is collected for
-- that interval, so an external memory rate looks like a regression and is
-- not one (Aegis lost a measurement to this, 2026-08-08). Read ONE tool at a
-- time: Vitals for the net rate a player pays, this report for attribution.
local _depth = 0
-- Pushes nest when a dispatcher shows a bound child: the child's OnShow hook
-- pushes it from inside the parent's paint. Only the outermost adds to _pushTotal.
local _pushDepth = 0

-- Every probe site takes its opening readings through here rather than inline,
-- so a site cannot take one reading and forget the other -- and so the hold
-- lives in ONE place instead of at four call sites.
function P:Open()
    _depth = _depth + 1
    if _depth == 1 then collectgarbage("stop") end
    return _G.debugprofilestop(), collectgarbage("count")
end

-- Close a sample: returns its ms and KB so a caller that splits the sample
-- further (the catalog sweep's stage laps) reads the SAME totals it recorded.
local function _close(self, bucket, key, t0, k0, subs)
    local ms = _G.debugprofilestop() - t0
    local kb = collectgarbage("count") - k0
    _depth = _depth - 1
    if _depth == 0 then
        collectgarbage("restart")
        self._alloc.kb      = self._alloc.kb + kb
        self._alloc.samples = self._alloc.samples + 1
    end
    _bump(bucket, key, ms, kb, subs)
    return ms, kb
end

-- Safe ONLY from a human-driven call site: releases a collector stranded by an
-- error that escaped a probed call (see THE TRADE above).
function P:_Release()
    _depth = 0
    _pushDepth = 0
    collectgarbage("restart")
end

-- Test seam: the nesting depth, so a test can prove a nested close leaves the
-- hold in place and an outermost close lifts it.
function P:_Depth() return _depth end

-- Record one Store flush. Attributed to distinct action types in the batch ("A+B" when batched).
function P:RecordFlush(pending, t0, k0, subCount)
    local seen, types = {}, {}
    local viewTarget
    for _, n in ipairs(pending) do
        local t = n.type or "?"
        if not seen[t] then
            seen[t] = true
            types[#types + 1] = t
        end
        -- Surface destination tab for view switches so per-tab cost separates.
        local p = n.action and n.action.payload
        if p and p.key == "view" and p.value then
            viewTarget = tostring(p.value)
        end
    end
    table.sort(types)
    local key = table.concat(types, "+")
    if viewTarget then key = key .. "  ->" .. viewTarget end
    local ms, kb = _close(self, self._flush, key, t0, k0, subCount)
    self:Mark(key, ms, "flush", kb)   -- also land it on the chronological boot timeline
end

-- Record one selector call. Called by the HDG.Selectors:Call probe.
function P:RecordSelector(name, t0, k0)
    _close(self, self._sel, name, t0, k0)
end

-- Module op outside dispatch path (catalog sweep, aggregator snapshot, etc).
-- Returns the sample's ms and KB.
function P:RecordOp(name, t0, k0)
    local ms, kb = _close(self, self._op, name, t0, k0)
    self:Mark(name, ms, "op", kb)   -- also land it on the chronological boot timeline
    return ms, kb
end

-- Same accumulator, no timeline entry, and VALUES rather than readings: for the
-- per-stage split of an op that already carries its own sample (the catalog
-- sweep's stage laps), so the boot timeline keeps one line per sweep instead
-- of a dozen at the same instant. Not a sample of its own -- the enclosing
-- RecordOp holds the collector for the whole sweep, laps included.
function P:RecordOpQuiet(name, ms, kb)
    _bump(self._op, name, ms, kb)
end

-- Refresh-pipeline stage (PrepareContext/Bind/Layout/...). Not added to timeline (many-per-flush).
function P:RecordStage(name, t0, k0)
    _close(self, self._stage, name, t0, k0)
end

-- One bound widget's push (BindingEngine pushOne), sampled as two rows: data is
-- its selectors and resolver kicks, paint its dispatcher. A push nested in
-- another's paint is inside the outer paint row as well; the total counts it once.
-- The keys are built before either sample opens, so neither row carries them.
function P:SamplePush(widget, resolveAll, paint, state, ctx)
    local key = widget._hdgrKind .. " " .. widget._hdgrId
    local dataKey, paintKey = key .. "  data", key .. "  paint"
    _pushDepth = _pushDepth + 1
    local t0, k0 = self:Open()
    local resolved = resolveAll(widget, state, ctx)
    local dataMs, dataKB = _close(self, self._push, dataKey, t0, k0)
    t0, k0 = self:Open()
    paint(widget, resolved, ctx)
    local paintMs, paintKB = _close(self, self._push, paintKey, t0, k0)
    _pushDepth = _pushDepth - 1
    if _pushDepth == 0 then
        local pt = self._pushTotal
        pt.ms = pt.ms + dataMs + paintMs
        pt.kb = pt.kb + dataKB + paintKB
    end
end

-- One window's layout passes (Layout:LayoutWindow): a row for the whole and a
-- row per lap, all under one held collector. nil when perf is off; every lap
-- and the close are then a nil-check.
function P:OpenLayoutLaps(windowName)
    if not self:Enabled() then return nil end
    local t0, k0 = self:Open()
    local pt = self._pushTotal
    return { window = windowName, t0 = t0, k0 = k0, t = t0, k = k0, pushMs = pt.ms, pushKB = pt.kb }
end

-- A lap that pushed bound widgets is split into those pushes and the rest. The
-- next lap starts from fresh readings, so the bookkeeping here is in no lap
-- (only in the whole-window row).
function P:LayoutLap(laps, label)
    if not laps then return end
    local ms = _G.debugprofilestop() - laps.t
    local kb = collectgarbage("count") - laps.k
    local pt = self._pushTotal
    local pushMs, pushKB = pt.ms - laps.pushMs, pt.kb - laps.pushKB
    local key = laps.window .. "  " .. label
    if pushMs ~= 0 or pushKB ~= 0 then
        _bump(self._layout, key .. ": reveal pushes", pushMs, pushKB)
        _bump(self._layout, key .. ": placement", ms - pushMs, kb - pushKB)
    else
        _bump(self._layout, key, ms, kb)
    end
    laps.pushMs, laps.pushKB = pt.ms, pt.kb
    laps.t, laps.k = _G.debugprofilestop(), collectgarbage("count")
end

function P:CloseLayoutLaps(laps)
    if not laps then return end
    _close(self, self._layout, laps.window .. "  whole layout", laps.t0, laps.k0)
end

-- SetEpoch: t-zero for the boot timeline. Called once from Init:OnInitialize. Idempotent.
function P:SetEpoch()
    if self._epoch then return end
    self._epoch = _G.debugprofilestop and _G.debugprofilestop() or 0
end

-- Append a chronological mark. No-op until epoch is set. Ring-capped at TIMELINE_CAP.
-- kb is nil on event / rtt marks -- exception(optional): a marker has no cost of its own.
function P:Mark(label, ms, kind, kb)
    if not self._epoch then return end
    local t = (_G.debugprofilestop and _G.debugprofilestop() or 0) - self._epoch
    local tl = self._timeline
    tl[#tl + 1] = { t = t, label = label, ms = ms, kb = kb, kind = kind or "flush" }
    -- Drop the oldest if over cap (boot chain stays -- it's at the front, and
    -- we only trim once well past it).
    if #tl > self.TIMELINE_CAP then
        table.remove(tl, 1)
    end
end

function P:Reset()
    self._flush    = {}
    self._sel      = {}
    self._op       = {}
    self._stage    = {}
    self._push     = {}
    self._layout   = {}
    self._pushTotal = { ms = 0, kb = 0 }
    self._timeline = {}
    self._alloc    = { kb = 0, samples = 0 }
    self:_Release()
    -- epoch NOT cleared: fixed t-zero for the session even after Reset.
end

-- ===== Report ==============================================================

-- Sort a bucket's entries into a list ordered by total time descending.
-- Ordered by KB, ms as the tie-break: allocation is the question this column
-- was added to answer (the memory peak), and a row that is cheap in time and
-- heavy in bytes is exactly the row a ms sort buries.
local function _sortedEntries(bucket)
    local list = {}
    for key, e in pairs(bucket) do
        list[#list + 1] = { key = key, count = e.count, total = e.total,
                            max = e.max, kb = e.kb, maxKB = e.maxKB, subs = e.subs }
    end
    table.sort(list, function(a, b)
        if a.kb ~= b.kb then return a.kb > b.kb end
        return a.total > b.total
    end)
    return list
end

-- floor: optional { ms, kb }; a row under BOTH is hidden as noise, with the
-- hidden count summarised. Under one but not the other stays visible -- a
-- selector that takes no time and allocates plenty is the point of the column.
local function _appendSection(lines, title, bucket, showSubs, floor)
    local entries = _sortedEntries(bucket)
    lines[#lines + 1] = title
    if #entries == 0 then
        lines[#lines + 1] = "  (no samples)"
        return
    end
    -- Header. Columns: total KB, total ms, count, KB per call, max KB, ms per call, [subs], key.
    lines[#lines + 1] = showSubs
        and string.format("  %9s %9s %6s %8s %8s %8s %5s  %s", "KB", "ms", "n", "KB/call", "maxKB", "ms/call", "subs", "action")
        or  string.format("  %9s %9s %6s %8s %8s %8s  %s", "KB", "ms", "n", "KB/call", "maxKB", "ms/call", "name")
    local hidden, hiddenKB, hiddenMs = 0, 0, 0
    for _, e in ipairs(entries) do
        if floor and e.total < floor.ms and e.kb < floor.kb then
            hidden = hidden + 1
            hiddenKB, hiddenMs = hiddenKB + e.kb, hiddenMs + e.total
        else
            local avgMs, avgKB = e.total / e.count, e.kb / e.count
            if showSubs then
                lines[#lines + 1] = string.format("  %9.1f %7.1fms %6d %8.1f %8.1f %6.2fms %5s  %s",
                    e.kb, e.total, e.count, avgKB, e.maxKB, avgMs, tostring(e.subs or "?"), e.key)
            else
                lines[#lines + 1] = string.format("  %9.1f %7.1fms %6d %8.1f %8.1f %6.2fms  %s",
                    e.kb, e.total, e.count, avgKB, e.maxKB, avgMs, e.key)
            end
        end
    end
    if hidden > 0 then
        -- Their sum, because many small rows can add up to one big one (the
        -- per-widget push rows: a hundred labels under the floor each).
        lines[#lines + 1] = string.format("  (+%d more under %.2fms AND %.1fKB total -- hidden; %.1f KB, %.1fms together)",
            hidden, floor.ms, floor.kb, hiddenKB, hiddenMs)
    end
end

-- Boot memory: Lua heap deltas between the readings Init.lua and HDGR_BootMark.lua
-- took. The spans after the files are held only when perf was on at login; the
-- files span is never held (saved variables, the perf flag, load after it). The
-- gap between OnInitialize and OnEnable belongs to other addons and is not shown.
local BOOT_MEMORY_STEPS = {
    { "files0",  "files1",     "files + shipped data (TOC load; never held -- net heap movement, a collection inside it reads low)" },
    { "files1",  "sv",         "saved variables" },
    { "sv",      "init",       "engines (theme, locale, modules, validators)" },
    { "enable0", "mainWindow", "main window frames (0 unless it was open at logout; built on first open)" },
    { "mainWindow", "windows", "satellite windows" },
}
local function _appendBootMemory(lines)
    local h = HDG._bootHeap
    if not (h and h.files0 and h.files1) then return end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Boot memory (KB per step; with perf on at login the steps after the files hold the collector, so they read gross allocation):"
    local total = 0
    for _, step in ipairs(BOOT_MEMORY_STEPS) do
        local a, b = h[step[1]], h[step[2]]
        if a and b then
            total = total + (b - a)
            lines[#lines + 1] = string.format("  %10.1f KB  %s", b - a, step[3])
        end
    end
    lines[#lines + 1] = string.format("  %10.1f KB  total of the steps above", total)
end

-- Boot timeline: t+ = wall-clock since epoch (includes idle/async gaps); [cost] = step CPU.
-- rtt rows show external round-trip. Split lets you distinguish wait vs our processing.
local function _appendTimeline(lines, timeline)
    lines[#lines + 1] = "Boot timeline (epoch = OnInitialize; t+ = wall-clock, [..] = step cost):"
    if #timeline == 0 then
        lines[#lines + 1] = "  (no marks -- enable before login + /reload to capture boot)"
        return
    end
    local prevT = 0
    for _, m in ipairs(timeline) do
        local gap = m.t - prevT
        prevT = m.t
        -- Flag the rows that are mostly external/idle wait (big gap, little cost)
        -- so a 500ms catalog round-trip doesn't read as our cost.
        local costStr = m.ms and string.format("[%7.2fms %8s]", m.ms, m.kb and string.format("%.1fKB", m.kb) or "")
                                 or "[   event          ]"
        local tag = (m.kind == "rtt") and "  <ext RTT>"
                 or ((gap > 50 and (not m.ms or m.ms < gap * 0.25)) and "  <waited>" or "")
        lines[#lines + 1] = string.format("  t+%8.1fms (+%6.1f)  %s  %s%s",
            m.t, gap, costStr, m.label, tag)
    end
    lines[#lines + 1] = string.format("  --- %.1fms total from epoch to last mark ---", prevT)
    _appendBootMemory(lines)
end

-- Build the full perf report as a newline-joined string.
function P:Report()
    local lines = { "HDG Performance Profile",
                    "====================================================================" }
    if not self:Enabled() then
        lines[#lines + 1] = "(perf timing is OFF -- enable with: /hdgr perf on)"
    end
    -- The headline for a peak hunt: one GC-independent number per scenario.
    -- Compare it across builds over the SAME sequence of actions (reset, open
    -- the window, visit each view, type in a search box, close), because the
    -- peak itself moves with collector timing and this does not.
    lines[#lines + 1] = string.format("Allocated since reset: %.1f KB over %d outermost samples (nested samples counted once).",
        self._alloc.kb, self._alloc.samples)
    lines[#lines + 1] = "(The collector is HELD while a sample runs: an external memory rate reads GROSS allocation for that interval.)"
    lines[#lines + 1] = ""
    _appendTimeline(lines, self._timeline)
    lines[#lines + 1] = ""
    _appendSection(lines, "Dispatch flush cost (deferred selector+binding+layout+paint):",
                   self._flush, true)
    lines[#lines + 1] = ""
    -- Floor: under 0.05ms rounds to 0.0ms total and under 0.5KB is a few tables -- noise, hidden.
    _appendSection(lines, "Per-selector cost (HDG.Selectors:Call):", self._sel, false, { ms = 0.05, kb = 0.5 })
    lines[#lines + 1] = ""
    _appendSection(lines, "Module ops (work OUTSIDE the dispatch path -- catalog sweep, etc.):",
                   self._op, false)
    lines[#lines + 1] = ""
    _appendSection(lines, "Refresh pipeline stages (per-stage cost inside runPipeline):",
                   self._stage, false)
    lines[#lines + 1] = ""
    -- Placement includes what a size change sets off: a scroll list re-lays its rows on resize.
    _appendSection(lines, "Layout passes (Layout:LayoutWindow per window; apply = placement + the widgets it revealed, pushed):",
                   self._layout, false)
    lines[#lines + 1] = ""
    _appendSection(lines, "Widget pushes (<kind> <id>: data = its selectors, paint = its dispatcher; a push inside another's paint is in both):",
                   self._push, false, { ms = 0.05, kb = 0.5 })
    return table.concat(lines, "\n")
end

-- ===== Dedicated window ====================================================
-- Large/tall scrollable report (lazy-singleton, themed, draggable, InputScrollFrame).
-- No C_Timer auto-refresh: user clicks Refresh after an action, or Reset + Refresh.

-- Repaint the window's edit box from the current report.
function P:_RepaintWindow()
    local w = self._window
    if w and w._edit then
        w._edit:SetText(self:Report())
        w._edit:SetCursorPosition(0)
    end
end

function P:Window()
    if self._window then return self._window end
    if not (_G.CreateFrame and _G.UIParent) then return nil end  -- exception(boundary): headless tests

    local f = _G.CreateFrame("Frame", "HDGR_PerfWindow", _G.UIParent, "BackdropTemplate")
    f:SetSize(870, 600)   -- large + tall, per request (+150w for long action keys)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    HDG.Theme:Register(f, "Frame")

    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetPoint("TOPLEFT", 12, -10)
    HDG.UI.applyFontRole(title, "heading")
    HDG.Theme:Register(title, "Text")
    title:SetText("HDG Performance Profile")

    local hint = f:CreateFontString(nil, "OVERLAY")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    HDG.UI.applyFontRole(hint, "small")
    hint:SetText("Click something in HDG, then Refresh. Reset zeros the stats. Ctrl+C to copy.")
    HDG.Theme:Register(hint, "TextDim")

    -- Scrollable report body; bottom edge leaves room for button row.
    local sf = _G.CreateFrame("ScrollFrame", nil, f, "InputScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -50)
    sf:SetPoint("BOTTOMRIGHT", -12, 44)
    if sf.CharCount then sf.CharCount:Hide() end  -- exception(boundary): CharCount is an InputScrollFrameTemplate sub-widget; absent in some Blizzard template versions
    HDG.Theme:Register(sf, "EditBox")
    local edit = sf.EditBox
    if edit then
        edit:SetAutoFocus(false)
        edit:SetMultiLine(true)
        edit:SetMaxLetters(0)
        edit:SetJustifyH("LEFT")
        HDG.UI.applyFontRole(edit, "body")
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
    end
    sf:HookScript("OnSizeChanged", function(self_, w)
        if self_.EditBox and self_.EditBox.SetWidth then
            self_.EditBox:SetWidth(math.max(1, (w or 0) - 24))
        end
    end)
    f._edit = edit

    -- Button row: Refresh | Reset | Close (right-aligned).
    local close = HDG.UI:Button(f, "Close", "small")
    close:SetSize(80, 22); close:SetPoint("BOTTOMRIGHT", -12, 12)
    close:SetScript("OnClick", function() f:Hide() end)

    local reset = HDG.UI:Button(f, "Reset", "small")
    reset:SetSize(80, 22); reset:SetPoint("RIGHT", close, "LEFT", -8, 0)
    reset:SetScript("OnClick", function() P:Reset(); P:_RepaintWindow() end)

    local refresh = HDG.UI:Button(f, "Refresh", "small")
    refresh:SetSize(80, 22); refresh:SetPoint("RIGHT", reset, "LEFT", -8, 0)
    refresh:SetScript("OnClick", function() P:_RepaintWindow() end)

    self._window = f
    return f
end

-- Open (or re-open) the perf window, repainting with current stats.
function P:OpenWindow()
    local w = self:Window()
    if not w then return end
    self:_RepaintWindow()
    w:Show()
end

-- ===== Slash command =======================================================
-- /hdgr perf [on|off|reset]. Writes HDG_DB.perf directly (survives /reload).
-- Routed via Init's slash handler.

local function _print(msg)
    if _G.DEFAULT_CHAT_FRAME then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[HDG Perf]|r " .. msg)
    end
end

local function _setPerf(on)
    _G.HDG_DB = _G.HDG_DB or {}  -- exception(boundary): SV lazy-created on fresh accounts
    _G.HDG_DB.perf = on or nil    -- nil when off (no lingering flag)
end

function P:Command(msg)
    -- A typed command can never land inside a sample, so this is the safe place
    -- to release a collector an escaped error may have left held (see Sampling).
    self:_Release()
    local arg = HDG.Format.Trim((msg or ""):lower())
    if arg == "on" then
        _setPerf(true)
        _print("perf ON")
    elseif arg == "off" then
        _setPerf(false)
        _print("perf OFF")
    elseif arg == "reset" then
        P:Reset()
        if P._window and P._window:IsShown() then P:_RepaintWindow() end  -- exception(nullable): P._window is nil until first perf window open
        _print("stats cleared")
    else
        -- Bare /hdgr perf -> open window; chat dump fallback if frames unavailable.
        if _G.CreateFrame then
            P:OpenWindow()
        else
            for line in (P:Report() .. "\n"):gmatch("(.-)\n") do _print(line) end
        end
    end
end
