-- HDG.Layout
--
-- Pure layout engine. Reads HDG.LayoutConfig + a ctx state table, produces a
-- flat placement map keyed by panel/section/widget id. Also builds the frame
-- tree by walking the same spec data via HDG.WidgetTypes.
--
-- Concepts (in order of containment):
--   window           outer frame; rendered in modes (collapsed | expanded)
--   panel            top-level container with an optional chrome (slots)
--   slot             named region inside a panel: "header" | "body" | "footer"
--   section          virtual layout box. Stacks (vertical | horizontal | fill)
--                    its children. May contain other sections or widgets.
--   widget           leaf node. kind names a registered WidgetType (HDG.WidgetTypes).
--
-- Routing: a section / widget declares
--     in   = "<parentPanelOrSectionId>"
--     slot = "header" | "body" | "footer"   (default "body"; ignored when
--                                            the parent is a section, not a panel)
-- which tells the engine where it lives. Slots only exist on panels.
--
-- Public API:
--   Layout:Compute(config, ctx)          -> placements
--   Layout:Apply(rootFrame, placements)
--   Layout:BuildAll(rootFrame, config)
--   Layout:Validate(config)              -> { errors }

HDG = HDG or {}
HDG.Layout = HDG.Layout or {}

local Layout = HDG.Layout

local DEFAULT_HEADER_HEIGHT = 34
local DEFAULT_FOOTER_HEIGHT = 28

-- Templates for chromed sections. Sections opt in via spec.chrome = "<name>".
--   card    -> Tooltip-style NineSlice border (matches InputScrollFrameTemplate)
--   inset   -> Flat sunken sub-panel, NO Blizzard template chrome. Just a
--              themed bg texture (surface.sunken) + 1px border drawn by us.
--              We avoid InsetFrameTemplate here because its NineSlice fights
--              custom bg tints and leaves a brown/lit edge no matter what.
--   tooltip -> Same as card, alias
-- A `false` value means "create a plain Frame with no inheritsFrom" and rely
-- on the bg-tint texture + optional border textures for visuals.
local CHROME_TEMPLATES = {
    -- card: flat detail box. `false` = plain Frame;
    -- _attachChromeBgTint paints the fill + accent bar.
    card       = false,
    -- cardBorder: same fill as card, but a 1px border.default edge all round and NO
    -- accent stripe -- a self-contained bordered card.
    cardBorder = false,
    inset      = false,
    tooltip    = "TooltipBorderedFrameTemplate",
}
Layout.CHROME_TEMPLATES = CHROME_TEMPLATES

-- Helpers --------------------------------------------------------------------

local function clamp(value)
    if not value or value < 0 then return 0 end
    return value
end

local function rect(x, y, w, h)
    return { x = x, y = y, width = clamp(w), height = clamp(h) }
end

-- Resolve a spacing value to a number. Accepts:
--   number          -> returned as-is (one-off geometry escape hatch)
--   "lg" / "md"...  -> looked up via Theme:GetMetric("spacing.<name>")
--   nil             -> 0
-- Unknown tokens fail loud so a typo doesn't silently render zero.
local function resolveSpacing(value)
    if value == nil then return 0 end
    if type(value) == "number" then return value end
    if type(value) == "string" then
        local n = HDG.Theme:GetMetric("spacing." .. value) or nil
        if not n then
            error(("Layout: unknown spacing token %q (expected one of: xs/sm/md/lg/xl/xxl/huge)"):format(value), 3)
        end
        return n
    end
    return 0
end
Layout._resolveSpacing = resolveSpacing  -- exported for tests

-- Sum padding along one axis. Pad shape is the normalized
-- { top, right, bottom, left } table from normalizePadding.
local function _padHorizontal(pad) return pad.left + pad.right end
local function _padVertical(pad)   return pad.top  + pad.bottom end

-- Normalised padding is memoised per padding value (a number, a spacing token
-- or the spec's own table) for the life of the active scheme: the specs are
-- static config and the tokens resolve through the scheme's metrics, so the
-- answer only changes when the scheme does. Every layout pass used to mint 74
-- of these (2026-09-13 audit). Callers only read the result.
local NO_PADDING = { top = 0, right = 0, bottom = 0, left = 0 }
local _padCache, _padCacheScheme = setmetatable({}, { __mode = "k" }), false

local function _normalizePaddingUncached(p)
    if type(p) == "number" or type(p) == "string" then
        local n = resolveSpacing(p)
        return { top = n, right = n, bottom = n, left = n }
    end
    if type(p) == "table" then
        return {
            top    = resolveSpacing(p.top),
            right  = resolveSpacing(p.right),
            bottom = resolveSpacing(p.bottom),
            left   = resolveSpacing(p.left),
        }
    end
    -- Unexpected type (e.g. `padding = true` typo) -> loud-fail rather than silently
    -- rendering with no padding. nil is already handled by the caller (legit "no padding").
    error(("normalizePadding: unexpected padding type %s (want nil / number / spacing-string / table)"):format(type(p)), 4)
end

local function normalizePadding(p)
    if p == nil then return NO_PADDING end
    local scheme = HDG.Theme:GetScheme()
    if scheme ~= _padCacheScheme then
        _padCache, _padCacheScheme = setmetatable({}, { __mode = "k" }), scheme
    end
    local pad = _padCache[p]
    if not pad then
        pad = _normalizePaddingUncached(p)
        _padCache[p] = pad
    end
    return pad
end

local function specFor(config, id)
    return (config.sections and config.sections[id])
        or (config.widgets and config.widgets[id])
        or (config.panels and config.panels[id])
end

-- getAlong returns the spec's primary-axis size. Three forms:
--   number    -> fixed
--   "fill"    -> flex (shares slack with siblings)
--   "auto"    -> resolve from runtime intrinsics (see Layout._intrinsics);
--                falls back to "fill" if the widget hasn't reported one yet.
--   "content" -> sum descendants (handled in measureContent caller path)
--   nil       -> treated as "fill"
local function getAlong(spec, axis, id)
    local val = (axis == "vertical") and spec.height or spec.width
    if val == "auto" then
        local intrinsics = Layout._intrinsics
        local entry = id and intrinsics and intrinsics[id]
        if entry then
            local v = (axis == "vertical") and entry.height or entry.width
            if type(v) == "number" then return v end
        end
        return "fill"  -- intrinsic not (yet) reported -> behave as flex
    end
    return val
end

local function getCross(spec, axis)
    if axis == "vertical" then return spec.width end
    return spec.height
end

-- Window grid ----------------------------------------------------------------

-- Resolve dynamic columns/rows for a view. A view may declare
-- `dynamicColumns = "selector.name"` (and/or `dynamicRows`) to override the
-- static `columns`/`rows` array based on Store state. Selector returning
-- a table replaces the array; nil/false/non-table falls back to the spec.
-- Used by both GetViewDimensions and computeWindowCells so the dynamic
-- value drives both the window's outer size AND the inner cell layout
-- consistently. Lets a tab grow/shrink based on which sub-view is active
-- (Mogul/Goblin TSM column expansion is the seed use case).
function Layout:ResolveViewTracks(viewSpec, dimName)
    local dynKey
    if dimName == "columns" then dynKey = viewSpec.dynamicColumns
    elseif dimName == "rows" then dynKey = viewSpec.dynamicRows end
    if not dynKey then return viewSpec[dimName] end
    -- Strict reads -- a selector error propagates up through the pipeline
    -- (MainFrame:runPipeline, strict per ADR-042) and aborts the pass loudly.
    -- Earlier this site swallowed the error silently and fell back to static
    -- spec, hiding selector bugs.
    local result = HDG.Selectors:Call(dynKey, HDG.Store:GetState())  -- exception(false-positive): layout engine pipeline, not a row factory
    if type(result) == "table" then return result end
    -- Selector returned non-table (nil or non-array) -- fall back to spec.
    -- Loud fail would error here; the static fallback is part of the
    -- documented contract for dynamicColumns/dynamicRows ("optional
    -- override").
    return viewSpec[dimName]
end

-- Resolve a view's width/height. When the spec value is "auto", sum the
-- numeric column/row tracks + outer padding + inter-track gaps. Otherwise
-- the literal number is used. "fill" tracks are incompatible with "auto"
-- dimensions -- error loudly so the inconsistency surfaces at startup, not
-- as silent off-by-N-px drift.
--
-- Returns (width, height) -- both numeric, never "auto" or "fill".
function Layout:GetViewDimensions(config, view)
    local windowCfg = config.window
    local viewSpec = windowCfg.views[view]
    if not viewSpec then
        error(("Layout:GetViewDimensions: unknown view %q"):format(tostring(view)), 2)
    end
    local pad = clamp(resolveSpacing(windowCfg.padding))
    local gap = clamp(resolveSpacing(windowCfg.gap))
    local cols = self:ResolveViewTracks(viewSpec, "columns")
    local rows = self:ResolveViewTracks(viewSpec, "rows")

    local function sumTracks(tracks, dimName)
        if type(tracks) ~= "table" or #tracks == 0 then return 0, 0 end
        local sum, occupied = 0, 0
        for i, t in ipairs(tracks) do
            local n = tonumber(t)
            if not n then
                error(("Layout:GetViewDimensions: view %q has non-numeric %s[%d] = %q; \"fill\" is incompatible with %s = \"auto\""):format(
                    view, dimName, i, tostring(t), dimName == "columns" and "width" or "height"), 2)
            end
            sum = sum + n
            if n > 0 then occupied = occupied + 1 end   -- 0-size tracks (collapsed dynamic rows/cols) take no space -> no inter-track gap
        end
        return sum, occupied
    end

    local function resolveDim(value, tracks, dimName)
        if value == "auto" then
            local sum, count = sumTracks(tracks, dimName)
            return pad * 2 + sum + math.max(0, count - 1) * gap
        elseif type(value) == "number" then
            return value
        else
            error(("Layout:GetViewDimensions: view %q has invalid width/height %q (expected number or \"auto\")"):format(
                view, tostring(value)), 2)
        end
    end

    local w = resolveDim(viewSpec.width,  cols, "columns")
    local h = resolveDim(viewSpec.height, rows, "rows")
    return w, h
end

-- ===== Window composition (per ADR-025) =====================================
-- A window owns placement via a `slots` map. `fill` resolves to a view via
-- ResolveFillView; edge slots are literal view names. layout.lua never reads
-- the Store; state arrives via the caller (ctx.state).

-- Resolve which view a window's `fill` slot renders.
--   "@view"          -> the active view (state.account.ui.view; defaultView
--                       fallback when unset, naming a retired view, or naming a
--                       standalone one -- chrome or a satellite's content, which
--                       the window does not build. A real boundary: saved state)
--   any other string -> a fixed view name (a satellite's content)
function Layout:ResolveFillView(config, windowName, state)
    config = config or HDG.LayoutConfig
    local win = config.windows and config.windows[windowName]
    if not win then
        error(("Layout:ResolveFillView: no window %q in config.windows"):format(tostring(windowName)), 2)
    end
    local fill = win.slots and win.slots.fill
    if not fill then
        error(("Layout:ResolveFillView: window %q has no fill slot"):format(tostring(windowName)), 2)
    end
    if fill ~= "@view" then
        return fill
    end
    local v = state.account.ui.view   -- strict: caller passes a live state
    local spec = v and config.window.views[v]
    if spec and not spec.standalone then return v end
    return config.window.defaultView   -- exception(boundary): unset / retired / standalone view
end

-- Resolve a window's slot map into view names. Edge slots (top/bottom/left/
-- right/corner) are literal config/view names; `fill` resolves via
-- ResolveFillView (the only @view-capable slot). Returns a table keyed by
-- slot kind; absent slots are nil.
local function resolveWindowSlots(config, windowName, state)
    local win = config.windows and config.windows[windowName]
    if not win then
        error(("Layout: no window %q in config.windows"):format(tostring(windowName)), 2)
    end
    if not win.slots then
        error(("Layout: window %q has no slots"):format(tostring(windowName)), 2)
    end
    local s = win.slots
    return {
        top    = s.top,
        bottom = s.bottom,
        left   = s.left,
        right  = s.right,
        corner = s.corner,
        fill   = Layout:ResolveFillView(config, windowName, state),  -- reads win.slots.fill + state
    }
end

-- A slot-view's natural (w, h) -- 0,0 when the slot is absent.
local function slotDims(config, view)
    if not view then return 0, 0 end
    return Layout:GetViewDimensions(config, view)
end

-- The composed window's natural size from its slot extents:
--   W = left + fill + right     H = top + fill + bottom
-- `fill` drives the body on both axes; edge slots add their fixed extent.
-- `corner` is an overlay (no grid cell), so it doesn't affect the size.
function Layout:ComposeWindowDimensions(config, windowName, state)
    config = config or HDG.LayoutConfig
    local slots = resolveWindowSlots(config, windowName, state)
    local fw, fh = slotDims(config, slots.fill)
    local lw     = (slotDims(config, slots.left))     -- width  (1st return)
    local rw     = (slotDims(config, slots.right))
    local _, th  = slotDims(config, slots.top)        -- height (2nd return)
    local _, bh  = slotDims(config, slots.bottom)
    return lw + fw + rw, th + fh + bh
end

-- The views a window composes right now: its slot views, the fill resolved
-- against state. The main window's pipeline builds, paints and refreshes the
-- controllers of these.
function Layout:WindowViews(config, windowName, state)
    local slots = resolveWindowSlots(config, windowName, state)
    local views = {}
    for _, slot in ipairs({ "top", "bottom", "left", "right", "corner", "fill" }) do
        if slots[slot] then views[#views + 1] = slots[slot] end
    end
    return views
end

-- Compose a window into one merged placements table from its slot map. Each
-- slot is itself a layout config (view); Compute resolves its placements
-- relative to its own origin, and we translate them into the slot's region
-- within the window grid. Slots stack flush (each slot-view carries its own
-- internal padding). `corner` overlays the window's top-right (close button).
-- When only `fill` is present this collapses to a single un-offset Compute --
-- identical to the pre-slot behavior.
function Layout:ComposeWindow(config, windowName, ctx)
    config = config or HDG.LayoutConfig
    ctx = ctx or {}
    local slots = resolveWindowSlots(config, windowName, ctx.state)

    local fw, fh = slotDims(config, slots.fill)
    local lw     = (slotDims(config, slots.left))
    local rw     = (slotDims(config, slots.right))
    local _, th  = slotDims(config, slots.top)
    local _, bh  = slotDims(config, slots.bottom)
    local W      = lw + fw + rw
    local bodyY  = th  -- body row sits below the top slot

    -- (view, originX, originY, spanW, spanH) per grid slot, in paint order.
    -- Edge slots span: top/bottom take the full window width W; left/right
    -- cross-fill the body height fh. fill + corner use their natural size
    -- (spanW/spanH nil). spanW/spanH thread to computeWindowCells via
    -- ctx.frameW/frameH so the slot-view's "fill" tracks stretch to the span.
    local placed = {}
    local function add(view, x, y, spanW, spanH)
        if view then placed[#placed + 1] = { view = view, x = x, y = y, spanW = spanW, spanH = spanH } end
    end
    add(slots.top,    0,           0,            W,   th)
    add(slots.left,   0,           bodyY,        lw,  fh)
    add(slots.fill,   lw,          bodyY,        nil, nil)
    add(slots.right,  lw + fw,     bodyY,        rw,  fh)
    add(slots.bottom, 0,           bodyY + fh,   W,   bh)
    if slots.corner then
        local cw = (slotDims(config, slots.corner))
        add(slots.corner, W - cw, 0, nil, nil)  -- overlay, window top-right
    end

    local placements = {}
    for _, s in ipairs(placed) do
        local sub = {}
        for k, v in pairs(ctx) do sub[k] = v end
        sub.view    = s.view
        sub.frameW  = s.spanW   -- nil -> natural size in computeWindowCells
        sub.frameH  = s.spanH
        sub.originX = s.x       -- offsets the slot's CELLS (panel positions);
        sub.originY = s.y       -- sections/widgets follow via parent-relative coords
        local p = self:Compute(config, sub)
        -- Merge directly -- the origin already moved the panels; offsetting
        -- placements again here would double-shift parent-relative children.
        for id, r in pairs(p) do
            placements[id] = r
        end
    end
    return placements
end

-- ===== computeWindowCells helpers =========================================

-- Resolve the cell-name a panel occupies in the named view. Panels have
-- `cell = { viewA = "cellName", viewB = "otherCell", ... }`. Returns nil
-- if the panel has no cell mapping for that view.
--
-- Named "resolve" (not "panel...") because it's an accessor -- returns a
-- value, not a predicate. Sister helpers _panelTargetsView /
-- _panelIsStandaloneOnly are bool predicates and use the _panel* prefix.
local function _resolvePanelCell(panelSpec, view)
    return panelSpec.cell and panelSpec.cell[view] or nil
end

-- Determine which row + col indices have at least one VISIBLE panel.
-- Spanned tracks must stay live even when neighbors are hidden (a colSpan'd
-- panel must keep its sibling track alive or width collapses).
local function _computeLiveRowsCols(panels, view, viewSpec, ctx)
    local liveRows, liveCols = {}, {}
    for panelId, panelSpec in pairs(panels) do
        local visible = ctx == nil or ctx.panelVisible == nil
            or ctx.panelVisible[panelId] ~= false  -- exception(false-positive): map is fully populated by Compute each pass; false = no cell in this view OR hidden by its own visibility selector
        local cellName = _resolvePanelCell(panelSpec, view)
        local cellSpec = cellName and (viewSpec.cells or {})[cellName] or nil
        if visible and cellSpec then
            local rowStart, rowSpan = cellSpec.row, cellSpec.rowSpan
            local colStart, colSpan = cellSpec.col, cellSpec.colSpan
            for r = rowStart, rowStart + rowSpan - 1 do liveRows[r] = true end
            for c = colStart, colStart + colSpan - 1 do liveCols[c] = true end
        end
    end
    return liveRows, liveCols
end

-- Given a track template (e.g. { 200, "fill", 150 }) + total along-axis
-- length + per-track live-mask, return (sizes[], offsets[]) -- the
-- per-track size and absolute offset from origin. "fill" entries split
-- the remaining slack equally. Dead tracks (not in liveMask) get size=0
-- and the previous offset (zero-width gap; downstream knows to skip).
local function _resolveTracks(template, total, gap, liveMask)
    -- A track contributes an inter-track gap only if it actually takes space:
    -- a "fill" track or a fixed track with size > 0. Fixed 0-size tracks (a
    -- dynamicRows/Columns collapse -- e.g. lumber session-only mode zeros the
    -- counter + action rows) add NO gap, else the window gains phantom padding
    -- where the collapsed track used to be. Must stay in lockstep with
    -- GetViewDimensions:sumTracks (same 0-size-excluded gap count).
    local fixedSum, flex, gapCount = 0, 0, 0
    for i, t in ipairs(template) do
        local live = not liveMask or liveMask[i]
        if live then
            if t == "fill" then
                flex = flex + 1
                gapCount = gapCount + 1
            else
                local n = tonumber(t) or 0
                fixedSum = fixedSum + n
                if n > 0 then gapCount = gapCount + 1 end
            end
        end
    end
    local gapTotal = math.max(0, gapCount - 1) * gap
    local flexSize = flex > 0 and math.max(0, (total - fixedSum - gapTotal) / flex) or 0
    local sizes, offsets = {}, {}
    local cursor = 0
    for i, t in ipairs(template) do
        local live = not liveMask or liveMask[i]
        if live then
            sizes[i]   = (t == "fill") and flexSize or (tonumber(t) or 0)
            offsets[i] = cursor
            cursor = cursor + sizes[i]
            if t == "fill" or sizes[i] > 0 then cursor = cursor + gap end
        else
            sizes[i]   = 0
            offsets[i] = cursor
        end
    end
    return sizes, offsets
end

-- Primitive: sum N consecutive track sizes starting at `start`, including
-- gap separators between consecutive non-zero entries. Skips dead tracks
-- (size 0) without consuming a gap. Returns the total along-axis size
-- for a (start, span) cell into a track array.
--
-- This is the canonical "spanned cell along one axis" math -- replaces
-- the col/row dedup that lived twice inside computeWindowCells.
local function _sumSpannedTracks(start, span, sizes, gap, nTracks)
    local total, hasAny = 0, false
    local stop = math.min(start + span - 1, nTracks)
    for i = start, stop do
        local s = sizes[i]
        if s > 0 then
            if hasAny then total = total + gap end
            total = total + s
            hasAny = true
        end
    end
    return total
end

local function computeWindowCells(config, view, ctx)
    local windowCfg = config.window
    local viewSpec  = windowCfg.views[view]
    -- Per-view padding override (HDG-ADR-025): chrome slot-views (status/chrome)
    -- set padding=0 so their content fills the slot flush -- the window's "sm"
    -- padding would otherwise inset + overflow a fixed-height bar (the rail sat
    -- 4px low and spilled past the window bottom). nil -> the window default.
    local vpad = viewSpec.padding
    if vpad == nil then vpad = windowCfg.padding end
    -- Per-side padding: normalizePadding handles a scalar ("sm" -> all sides
    -- equal, the common case) OR a { left/right/top/bottom } table for
    -- asymmetric insets -- e.g. the nav slot sets right=0 so its seam to the
    -- content is a single gap (the content's own left pad), not a doubled one.
    local pads = normalizePadding(vpad)
    local padL, padR = clamp(pads.left), clamp(pads.right)
    local padT, padB = clamp(pads.top),  clamp(pads.bottom)
    local gap = clamp(resolveSpacing(windowCfg.gap))
    -- Slot composition (HDG-ADR-025): an edge slot (top/bottom/left/right)
    -- spans the window's body extent, not the view's own natural size.
    -- ComposeWindow passes the spanned width/height via ctx.frameW/frameH so
    -- the slot-view's "fill" tracks stretch to the window. nil (every non-slot
    -- caller, and the `fill` slot) -> the view's natural GetViewDimensions size.
    local nw, nh = Layout:GetViewDimensions(config, view)
    local frameW = (ctx and ctx.frameW) or nw
    local frameH = (ctx and ctx.frameH) or nh
    local contentW = clamp(frameW - padL - padR)
    local contentH = clamp(frameH - padT - padB)
    -- Slot composition (HDG-ADR-025): ComposeWindow offsets a slot's CELLS
    -- (panel positions -- the only root-anchored placements) by the slot's
    -- region origin. Sections/widgets are parent-relative, so they inherit the
    -- shift via their moved panel -- offsetting them too would double-count
    -- (the dead-band bug). 0 for every non-slot caller.
    local originX = (ctx and ctx.originX) or 0
    local originY = (ctx and ctx.originY) or 0

    -- Honor dynamic columns/rows override (declared via dynamicColumns /
    -- dynamicRows on the view spec). Dynamic resolution drives both the
    -- outer window dimensions (GetViewDimensions above) and these inner
    -- cell tracks so layout stays internally consistent.
    local cols = Layout:ResolveViewTracks(viewSpec, "columns") or { "fill" }
    local rows = Layout:ResolveViewTracks(viewSpec, "rows")    or { "fill" }

    local liveRows, liveCols = _computeLiveRowsCols(config.panels or {}, view, viewSpec, ctx)
    local colSizes, colOffsets = _resolveTracks(cols, contentW, gap, liveCols)
    local rowSizes, rowOffsets = _resolveTracks(rows, contentH, gap, liveRows)

    -- Runtime track resolution. dynamicColumns/dynamicRows can return
    -- fewer tracks than the static spec declares (e.g. HouseTab's picker
    -- cell sits at col=2, but house.viewColumns drops col 2 when picker
    -- is closed). When the cell's anchor track is out-of-range at the
    -- current runtime resolution, skip rect emission entirely --
    -- panel-iteration in Layout:Compute treats `cells[cellName] == nil`
    -- as hidden.
    local nCols, nRows = #colSizes, #rowSizes
    local cells = {}
    for cellName, cellSpec in pairs(viewSpec.cells or {}) do
        local col, row = cellSpec.col, cellSpec.row
        if col <= nCols and row <= nRows then
            cells[cellName] = rect(
                originX + padL + colOffsets[col],
                originY + padT + rowOffsets[row],
                _sumSpannedTracks(col, cellSpec.colSpan, colSizes, gap, nCols),
                _sumSpannedTracks(row, cellSpec.rowSpan, rowSizes, gap, nRows)
            )
        end
    end

    return cells, frameW, frameH
end

-- Child indexing -- routed by (parentId, slot). Default slot = "body". -------

-- Single visibility gate: combines `visibleInViews` (static view-list) AND
-- `visible` (selector / bool / function) into one yes-or-no. If either says
-- "no", the spec is excluded from the index.
--
-- Cascade falls out for free: a hidden parent doesn't appear in its
-- grandparent's child list, so layoutContainer never recurses into it.
-- Children of a hidden parent may still get index entries (under the
-- hidden parent's id) but no one reaches those entries, so no placements
-- are computed and Apply auto-hides the orphans.
local function shouldRender(spec, view, state, ctx)
    local vv = spec.visibleInViews
    if vv ~= nil then
        local found = false
        for _, m in ipairs(vv) do if m == view then found = true; break end end
        if not found then return false end
    end
    local v = spec.visible
    if v == nil then return true end   -- no `visible` directive at all -> visible
    if type(v) == "boolean" then return v end
    -- Selector / function form: treat both `false` AND `nil` as hidden.
    -- Earlier code only checked `~= false`, so a selector returning `nil`
    -- (common when `a and a.x ~= nil` short-circuits) was treated as
    -- visible. That caused widgets to render when their visible selector
    -- returned nil (no selection) instead of being hidden.
    local result
    if type(v) == "string" then
        -- Selector form. state is required; a nil state here is a caller bug, so let the
        -- selector strict-read + loud-fail rather than silently defaulting to visible
        -- (the old `and state` fell through to `return true` = render-everything).
        result = HDG.Selectors:Call(v, state, ctx)
    elseif type(v) == "function" then
        result = v(state, ctx)
    else
        return true   -- unknown form: default visible (validator should flag instead)
    end
    return result ~= false and result ~= nil
end

local _enclosingPanelOf  -- forward: defined beside findEnclosingPanel, which it walks

-- `live` = the panel map Compute resolved for this pass: true only for a panel
-- that has a cell in this view AND whose own visibility did not hide it. The
-- placement loop only ever descends from live panels, so a section or widget
-- under any other panel was resolved and indexed for nobody -- and that was
-- most of the work: ~1,080 specs across every view of the addon walked per
-- pass, 170 visibility selectors evaluated, ~2.4 MB allocated per dispatch,
-- three quarters of everything the addon allocated in a session (2026-09-13
-- allocation profile). Now a spec is looked at only when its enclosing panel
-- is live. A spec whose in-chain reaches no panel is a validator error, not a
-- layout case; it indexes nowhere either way.
-- A registered spec the map does not know is either an in-chain that reaches
-- no panel (the validator's job, at boot) or a spec registered AFTER the map
-- was built. Both used to index silently under a parent nobody descends from;
-- with the prune they would vanish from the screen silently instead. Say so.
local function _panelOf(enclosing, id)
    local panel = enclosing[id]
    if panel == nil then
        error(("Layout: spec %q has no enclosing panel in the layout map -- registered after the first Compute, or its in-chain reaches no panel"):format(tostring(id)), 2)
    end
    return panel
end

-- parentId -> slot -> { ids = {...}, specs = {...} }, every section and widget
-- under its parent in `order`, built once per config (weak key, like the
-- enclosing-panel map). The order is static config; sorting it on every pass,
-- through a scratch entry per spec, was a third of the engine's own per-pass
-- garbage (2026-09-13 audit).
local _childrenCache = setmetatable({}, { __mode = "k" })
local function _staticChildrenOf(config)
    local map = _childrenCache[config]
    if map then return map end
    map = {}
    local function add(parentId, childId, spec)
        if not parentId then return end
        local slot = spec.slot or "body"
        map[parentId] = map[parentId] or {}
        map[parentId][slot] = map[parentId][slot] or {}
        local bucket = map[parentId][slot]
        bucket[#bucket + 1] = { id = childId, spec = spec, order = spec.order }
    end
    for id, spec in pairs(config.sections or {}) do add(spec["in"], id, spec) end
    for id, spec in pairs(config.widgets  or {}) do add(spec["in"], id, spec) end
    for _, slots in pairs(map) do
        for slotName, entries in pairs(slots) do
            table.sort(entries, function(a, b) return a.order < b.order end)
            local ids, specs = {}, {}
            for i, e in ipairs(entries) do ids[i], specs[i] = e.id, e.spec end
            slots[slotName] = { ids = ids, specs = specs }
        end
    end
    _childrenCache[config] = map
    return map
end

local function buildChildIndex(config, view, state, ctx, live)
    local index = {}
    local enclosing = _enclosingPanelOf(config)
    for parentId, slots in pairs(_staticChildrenOf(config)) do
        for slotName, bucket in pairs(slots) do
            local ids, specs, shown = bucket.ids, bucket.specs, nil
            for i = 1, #ids do
                local id = ids[i]
                if live[_panelOf(enclosing, id)] and shouldRender(specs[i], view, state, ctx) then
                    shown = shown or {}
                    shown[#shown + 1] = id
                end
            end
            if shown then
                index[parentId] = index[parentId] or {}
                index[parentId][slotName] = shown
            end
        end
    end
    return index
end

-- Slots ----------------------------------------------------------------------

-- Resolve the layout direction for a (slotName, declaredLayout) pair.
-- Returns the declared value if set; otherwise header/footer default
-- horizontal (read direction matches "by-row toolbar"), all others
-- default vertical (column of stacked widgets). Shared by getPanelSlots
-- (at build-time, writes resolved value into slot table) and
-- _resolveContainerLayout (at validate-time, reads on demand).
local function _defaultSlotLayout(slotName, declaredLayout)
    return declaredLayout
        or ((slotName == "header" or slotName == "footer") and "horizontal")
        or "vertical"
end

local function getPanelSlots(panelSpec)
    local declared = panelSpec.slots
    if not declared then
        return { body = { layout = panelSpec.bodyLayout or "vertical" } }
    end

    -- Default each slot's layout if missing; default header/footer heights.
    local slots = {}
    for name, slotSpec in pairs(declared) do
        local merged = {}
        for k, v in pairs(slotSpec) do merged[k] = v end
        merged.layout = _defaultSlotLayout(name, merged.layout)
        if name == "header" and not merged.height then merged.height = DEFAULT_HEADER_HEIGHT end
        if name == "footer" and not merged.height then merged.height = DEFAULT_FOOTER_HEIGHT end
        slots[name] = merged
    end
    if not slots.body then
        slots.body = { layout = panelSpec.bodyLayout or "vertical" }
    end
    return slots
end

local function computeSlotRects(panelRect, slots)
    local headerH = slots.header and clamp(slots.header.height) or 0
    local footerH = slots.footer and clamp(slots.footer.height) or 0
    local bodyH = clamp(panelRect.height - headerH - footerH)

    local out = {}
    if slots.header then
        out.header = rect(0, 0, panelRect.width, headerH)
    end
    out.body = rect(0, headerH, panelRect.width, bodyH)
    if slots.footer then
        out.footer = rect(0, headerH + bodyH, panelRect.width, footerH)
    end
    return out
end

-- Stack / fill layout (used by sections AND panel slots) ---------------------

local layoutContainer  -- forward

local function applyPadding(r, paddingSpec)
    local pad = normalizePadding(paddingSpec)
    return rect(r.x + pad.left, r.y + pad.top,
                r.width  - _padHorizontal(pad),
                r.height - _padVertical(pad))
end

-- Pre-pass: sum descendants for "content" sized children. Walks the spec tree
-- (sections + widgets) under the given id, summing fixed sizes and gaps along
-- the parent's axis. Returns nil if any descendant is "fill"/nil (indeterminate).
local function measureContent(id, axis, config, index)
    local spec = specFor(config, id)
    if not spec then return 0 end

    local own = getAlong(spec, axis, id)
    if type(own) == "number" then return own end

    local slots = index[id] or {}
    -- Sections store all children under "body" key (slots only matter on panels).
    local children = slots.body
    if not children or #children == 0 then return 0 end

    local localAxis = spec.layout == "horizontal" and "horizontal"
        or spec.layout == "vertical" and "vertical"
        or axis  -- inherit from parent for "fill" sections
    local total = 0
    for _, childId in ipairs(children) do
        local cspec = specFor(config, childId)
        if not cspec then return nil end
        local s = getAlong(cspec, localAxis, childId)
        if s == "content" then
            s = measureContent(childId, localAxis, config, index)
        end
        if type(s) ~= "number" then return nil end
        total = total + s
    end
    local gap = clamp(resolveSpacing(spec.gap))
    total = total + math.max(0, #children - 1) * gap

    -- Pad contributes to the parent-axis only when the section's own
    -- layout matches that axis (mismatched axes are absorbed by the
    -- recursive measure of the children, not by this padding sum).
    if localAxis == axis then
        local pad = normalizePadding(spec.padding)
        total = total + (axis == "vertical" and _padVertical(pad) or _padHorizontal(pad))
    end
    return total
end

-- Measure children for axis layout. Walks each child once, resolves its
-- along-axis size via spec (number / "fill" / "content"). "content" sizes
-- recurse through measureContent. Returns parallel arrays + totals.
local function _measureStackChildren(children, config, axis, index)
    local sizes = {}
    local fixedSum, flexCount, contentSum = 0, 0, 0
    for _, childId in ipairs(children) do
        local cspec = specFor(config, childId)
        local s = cspec and getAlong(cspec, axis, childId)
        if s == "content" then
            s = measureContent(childId, axis, config, index) or "fill"
        end
        if s == nil or s == "fill" then
            flexCount = flexCount + 1
            sizes[#sizes + 1] = "fill"
        else
            sizes[#sizes + 1] = s
            fixedSum = fixedSum + s
            contentSum = contentSum + s
        end
    end
    return sizes, fixedSum, flexCount, contentSum
end

-- Children's fixed sizes + gap budget exceed the available along-axis
-- length: container will overflow. Dedupe per (containerId, axis, along)
-- so a single bad row only warns once. Routes through Log:Warn so it
-- lands in the debug tab + auto-chat-prints via the trace consumer.
local function _warnOverSpec(containerId, axis, along, fixedSum, gapTotal, flexCount)
    if (fixedSum + gapTotal) <= along + 1 then return end
    Layout._overSpecWarned = Layout._overSpecWarned or {}
    local key = (containerId or "?") .. "|" .. axis .. "|" .. tostring(along)
    if Layout._overSpecWarned[key] then return end
    Layout._overSpecWarned[key] = true
    local text = string.format(
        "over-spec in %q (%s): %dpx available but children need %dpx "
        .. "(fixed=%d, gap=%d, %d flex). Drop a fixed %s or split the container.",
        containerId or "(unknown)", axis, math.floor(along + 0.5),
        math.floor(fixedSum + gapTotal + 0.5), math.floor(fixedSum + 0.5),
        math.floor(gapTotal + 0.5), flexCount,
        axis == "vertical" and "height" or "width")
    HDG.Log:Warn("layout", text)
end

-- Compute one child's rect for stack-axis positioning. Centers across the
-- cross-axis when the child declares a fixed cross-size; otherwise the
-- child fills the cross-axis fully.
local function _computeStackChildRect(axis, inner, cursor, size, crossSize)
    if axis == "vertical" then
        if type(crossSize) == "number" then
            local x = inner.x + (inner.width - crossSize) / 2
            return rect(x, cursor, crossSize, size)
        end
        return rect(inner.x, cursor, inner.width, size)
    end
    -- horizontal
    if type(crossSize) == "number" then
        local y = inner.y + (inner.height - crossSize) / 2
        return rect(cursor, y, size, crossSize)
    end
    return rect(cursor, inner.y, size, inner.height)
end

-- Resolve the starting cursor for an axis layout. Normal layouts start
-- at the inner edge; right-aligned horizontal layouts WITHOUT flex children
-- start past the fixed cluster (flex children absorb slack so the shift
-- would overflow if any are present).
local function _stackStartCursor(specOrSlot, axis, inner, flexCount, contentSum, gapTotal)
    local cursor = (axis == "vertical") and inner.y or inner.x
    if specOrSlot.align == "right" and axis == "horizontal" and flexCount == 0 then
        cursor = inner.x + inner.width - (contentSum + gapTotal)
        -- Overflow (content wider than the container): clamp to the left edge so children
        -- clip INSIDE the container instead of rendering at a negative x off its left.
        -- (_warnOverSpec already fires for this case in layoutStack.)
        if cursor < inner.x then cursor = inner.x end
    end
    return cursor
end

local function layoutStack(specOrSlot, parentRect, children, placements, config, index, containerId)
    local inner = applyPadding(parentRect, specOrSlot.padding)
    local layout = specOrSlot.layout or "vertical"
    local axis = (layout == "horizontal") and "horizontal" or (layout == "fill" and "fill" or "vertical")

    -- Fill axis: every child gets the full inner rect (overlay layout).
    if axis == "fill" then
        for _, childId in ipairs(children) do
            layoutContainer(childId, inner, placements, config, index, false)
        end
        return
    end

    local along    = (axis == "vertical") and inner.height or inner.width
    local gap      = clamp(resolveSpacing(specOrSlot.gap))
    local sizes, fixedSum, flexCount, contentSum = _measureStackChildren(children, config, axis, index)
    local gapTotal = math.max(0, #children - 1) * gap
    local flexAvail = math.max(0, along - fixedSum - gapTotal)
    _warnOverSpec(containerId, axis, along, fixedSum, gapTotal, flexCount)

    local flexSize = flexCount > 0 and (flexAvail / flexCount) or 0
    local cursor = _stackStartCursor(specOrSlot, axis, inner, flexCount, contentSum, gapTotal)

    for i, childId in ipairs(children) do
        local size = sizes[i] == "fill" and flexSize or sizes[i]
        local cspec = specFor(config, childId)
        local crossSize = cspec and getCross(cspec, axis)
        local childRect = _computeStackChildRect(axis, inner, cursor, size, crossSize)
        layoutContainer(childId, childRect, placements, config, index, false)
        cursor = cursor + size + gap
    end
end

-- Container layout -----------------------------------------------------------

-- Lay out one panel: compute slot rects, stamp each slot's placement,
-- delegate each slot's child list to layoutStack.
local function _layoutPanelSlots(id, parentRect, spec, placements, config, index)
    local slots          = getPanelSlots(spec)
    local slotRects      = computeSlotRects(parentRect, slots)
    local panelChildren  = index[id] or {}
    for slotName, slotSpec in pairs(slots) do
        local slotRect = slotRects[slotName]
        if slotRect then
            placements[id .. "." .. slotName] = slotRect
            local children = panelChildren[slotName] or {}
            layoutStack(slotSpec, slotRect, children, placements, config, index,
                        id .. "." .. slotName)
        end
    end
end

-- Lay out one section (non-panel container): stack body children inside
-- parentRect, OR inside a section-local (0,0,w,h) rect when the section
-- declares chrome.
--
-- Chrome detection uses `~= nil` so the `inset` sentinel value
-- (CHROME_TEMPLATES["inset"] = false, meaning "plain Frame, no template
-- inheritance") is still recognised -- otherwise widgets inside an inset
-- section would be section-parented but get panel-relative placements,
-- anchoring them outside the section rect.
local function _layoutSectionChildren(id, parentRect, spec, placements, config, index)
    local slots    = index[id] or {}
    local children = slots.body or {}
    if spec.chrome and CHROME_TEMPLATES[spec.chrome] ~= nil then
        local localRect = rect(0, 0, parentRect.width, parentRect.height)
        layoutStack(spec, localRect, children, placements, config, index, id)
    else
        layoutStack(spec, parentRect, children, placements, config, index, id)
    end
end

layoutContainer = function(id, parentRect, placements, config, index, isPanel)
    placements[id] = parentRect
    local spec = specFor(config, id)
    if not spec then return end
    if isPanel then
        _layoutPanelSlots(id, parentRect, spec, placements, config, index)
    else
        _layoutSectionChildren(id, parentRect, spec, placements, config, index)
    end
end

-- Public API -----------------------------------------------------------------

local _panelVisibleCache = setmetatable({}, { __mode = "k" })
local function _panelVisibleScratch(config, view)
    local byView = _panelVisibleCache[config]
    if not byView then byView = {}; _panelVisibleCache[config] = byView end
    local map = byView[view]
    if not map then map = {}; byView[view] = map end
    return map
end

-- Widget ids whose spec asks for an intrinsic ("auto" width or height), once
-- per config. getAlong reads Layout._intrinsics for these ids and no other.
local _autoSizedCache = setmetatable({}, { __mode = "k" })
local function _autoSizedIds(config)
    local ids = _autoSizedCache[config]
    if ids then return ids end
    ids = {}
    for id, spec in pairs(config.widgets or {}) do
        if spec.width == "auto" or spec.height == "auto" then ids[#ids + 1] = id end
    end
    _autoSizedCache[config] = ids
    return ids
end

-- The intrinsics a Compute reads: id -> { width, height } for each auto-sized
-- widget that has reported one, taken from the widget's _intrinsicWidth/Height
-- (stamped by its dispatcher during Bind). One table per frame, entries reused
-- in place: the previous shape harvested every widget on the frame into fresh
-- tables each pass, 492 of them, 94% for ids no spec ever asked about.
-- nil when the frame has no widget map (nothing built yet).
function Layout:HarvestIntrinsics(frame, config)
    local widgets = frame.widgets
    if not widgets then return nil end
    local out = frame._intrinsics
    if not out then out = {}; frame._intrinsics = out end
    for _, id in ipairs(_autoSizedIds(config)) do
        local w = widgets[id]
        local iw = w and w._intrinsicWidth
        local ih = w and w._intrinsicHeight
        if iw or ih then
            local e = out[id]
            if e then e.width, e.height = iw, ih
            else out[id] = { width = iw, height = ih } end
        else
            out[id] = nil
        end
    end
    return out
end

-- Every state path a layout pass for `view` can depend on: the active view,
-- the view's dynamic track selectors, every `visible` selector of a panel with
-- a cell in the view and of the sections and widgets under those panels, and
-- the bindings of auto-sized widgets (their intrinsics move with their data).
-- "*" when any of those reads "*". Static config, so once per (config, view).
local _viewInterestCache = setmetatable({}, { __mode = "k" })
local function _viewInterest(config, view)
    local byView = _viewInterestCache[config]
    if not byView then byView = {}; _viewInterestCache[config] = byView end
    local interest = byView[view]
    if interest then return interest end

    interest = { "account.ui.view" }
    local function addSelector(sel)
        if interest ~= "*" and type(sel) == "string" then
            interest = HDG.Paths.Union(interest, HDG.Selectors:GetReads(sel))
        end
    end
    local function addBinding(binding)
        if type(binding) == "string" then binding = { binding } end
        if type(binding) ~= "table" then return end
        for _, sel in pairs(binding) do
            if type(sel) == "string" and sel:sub(1, 7) ~= "static:" and sel:sub(1, 7) ~= "locale:" then
                addSelector(sel)
            end
        end
    end

    local viewSpec = config.window.views[view]
    addSelector(viewSpec.dynamicColumns)
    addSelector(viewSpec.dynamicRows)
    local targets = {}
    for panelId, panelSpec in pairs(config.panels or {}) do
        if _resolvePanelCell(panelSpec, view) ~= nil then
            targets[panelId] = true
            addSelector(panelSpec.visible)
        end
    end
    local enclosing = _enclosingPanelOf(config)
    for id, spec in pairs(config.sections or {}) do
        if targets[enclosing[id]] then addSelector(spec.visible) end
    end
    for id, spec in pairs(config.widgets or {}) do
        if targets[enclosing[id]] then
            addSelector(spec.visible)
            if spec.width == "auto" or spec.height == "auto" then addBinding(spec.binding) end
        end
    end
    byView[view] = interest
    return interest
end

-- The interest set of a whole window pass: every slot view it composes. Keyed
-- on the fill view (the edge slots are static per window). The main frame's
-- Layout stage skips Compute when a dispatch touches none of it: before this
-- gate every non-log dispatch ran a full solve, the 260 KB floor of every
-- pipeline pass (2026-09-13 audit, item 5).
local _windowInterestCache = setmetatable({}, { __mode = "k" })
function Layout:WindowInterest(config, windowName, state)
    config = config or HDG.LayoutConfig
    local slots = resolveWindowSlots(config, windowName, state)
    local byFill = _windowInterestCache[config]
    if not byFill then byFill = {}; _windowInterestCache[config] = byFill end
    local key = windowName .. "/" .. tostring(slots.fill)
    local interest = byFill[key]
    if interest then return interest end
    interest = {}
    for _, slot in ipairs({ "top", "bottom", "left", "right", "corner", "fill" }) do
        local view = slots[slot]
        if view then
            interest = HDG.Paths.Union(interest, _viewInterest(config, view))
            if interest == "*" then break end
        end
    end
    byFill[key] = interest
    return interest
end

function Layout:Compute(config, ctx)
    config = config or HDG.LayoutConfig
    if not config then error("Layout:Compute: no config (pass one or set HDG.LayoutConfig)", 2) end
    -- Shallow-copy ctx so Compute doesn't mutate the CALLER's table (purity contract):
    -- it populates panelVisible below + harvests intrinsics. ComposeWindow already passes
    -- a throwaway sub-ctx, but a direct Compute caller shouldn't see injected fields.
    local src = ctx or {}
    ctx = {}
    for k, v in pairs(src) do ctx[k] = v end
    local view = ctx.view or config.window.defaultView

    -- Resolve `visible` selectors on PANELS too. shouldRender
    -- handles sections + widgets already; panels were never evaluated, so
    -- panel.visible bindings (queue/materials/warehouse mode-toggle) were
    -- silently ignored. Populate ctx.panelVisible with the resolved bool
    -- so computeWindowCells + the placement loop both honor it.
    -- The map is fully repopulated below, so one table per (config, view)
    -- serves every pass instead of four fresh 67-entry tables a pass.
    ctx.panelVisible = ctx.panelVisible or _panelVisibleScratch(config, view)
    if config.panels then
        for panelId, panelSpec in pairs(config.panels) do
            -- A panel with no cell in this view cannot render here, so its
            -- visibility selector is not consulted. After this loop the map
            -- reads "live in this pass", which buildChildIndex uses to skip
            -- every subtree the placement loop below would never reach.
            if _resolvePanelCell(panelSpec, view) == nil then
                ctx.panelVisible[panelId] = false
            elseif shouldRender(panelSpec, view, ctx.state, ctx) then
                ctx.panelVisible[panelId] = true
            else
                ctx.panelVisible[panelId] = false
            end
        end
    end

    local cells = computeWindowCells(config, view, ctx)

    local placements = {}
    -- buildChildIndex resolves `visibleInViews` + `visible` for every spec
    -- and excludes hidden entries from the index. layoutContainer then
    -- iterates only visible children, so the flex math allocates the full
    -- slot to siblings of a hidden child without any extra bookkeeping.
    local index = buildChildIndex(config, view, ctx.state, ctx, ctx.panelVisible)

    -- _overSpecWarned dedupe persists across Compute passes (intentional).
    -- Earlier code reset this per-Compute; combined with Log:Warn routing
    -- (which dispatches LOG_PUSH -> Notify -> Refresh -> Compute) it caused
    -- a feedback loop where the layout warning self-triggered indefinitely.
    -- Dedupe key is `(containerId, along)`; geometry changes naturally
    -- introduce new keys and re-fire warnings on real layout-shape shifts.
    -- Intrinsics for `width = "auto"` / `height = "auto"` widgets, harvested
    -- by the caller (MainFrame) from each widget's _intrinsicWidth/Height.
    Layout._intrinsics = ctx.intrinsics

    for panelId, panelSpec in pairs(config.panels or {}) do
        local cellName = _resolvePanelCell(panelSpec, view)
        local visible = ctx.panelVisible == nil or ctx.panelVisible[panelId] ~= false  -- exception(false-positive): map is fully populated by Compute each pass; false = no cell in this view OR hidden by its own visibility selector
        local cellRect = cellName and cells[cellName] or nil
        if cellName and cellRect and visible then
            layoutContainer(panelId, cellRect, placements, config, index, true)
        else
            placements[panelId] = nil
        end
    end

    -- Clear the per-Compute intrinsics scratch (getAlong reads it during the solve above
    -- and nil-checks it). Set fresh each Compute, so no cross-pass leak; threading it
    -- through the solver hot path isn't worth the churn for a non-re-entrant path.
    Layout._intrinsics = nil
    return placements
end

local function rectsEqual(a, b)
    if not a or not b then return false end
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

local function ApplyOne(widget, region)
    if not widget or not region then return end
    -- Diffing stub: skip if the rect is identical to the last applied. Cheap
    -- win for full-Refresh-on-every-state-change patterns; foundation for a
    -- proper reactive-update layer later (compare prev placements -> only
    -- touch widgets whose rects changed). Sound because Layout is the SOLE
    -- writer of widget geometry -- intrinsic measurement reads natural width via
    -- GetUnboundedStringWidth (a pure read, no SetWidth probe), so nothing
    -- mutates a widget's size out of band to invalidate this cache.
    if rectsEqual(widget._lastRect, region) then return end
    local lr = widget._lastRect
    if lr then  -- reuse in place: one table per widget for life, not per geometry change
        lr.x, lr.y, lr.width, lr.height = region.x, region.y, region.width, region.height
    else
        widget._lastRect = { x = region.x, y = region.y, width = region.width, height = region.height }
    end

    if widget.ApplyLayout then widget:ApplyLayout(region); return end  -- exception(optional): ApplyLayout is an optional override protocol (e.g. CardGrid); absent = default anchor path
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", region.x, -region.y)
    widget:SetSize(region.width, region.height)
    -- Hook for animation / transition layer (no-op today). Surfaces or themes
    -- can attach :OnLayoutChanged(rect) to a widget to react to placement.
    if widget.OnLayoutChanged then  -- exception(optional): OnLayoutChanged is an optional extension protocol; absent = no-op
        widget:OnLayoutChanged(region)   -- strict (ADR-042): attached hooks are internal code, fail loud
    end
end

local function SetVisible(widget, visible)
    if not widget then return end   -- placement id with no built widget (engine-maintained)
    if visible then widget:Show() else widget:Hide() end
end

-- Primitive: apply placements to every (id -> widget) pair, hiding any
-- with no placement and showing those that have one. Optional `onApplied`
-- runs per-applied (widget, region) for per-collection extras like the
-- deferred-skinner logic on slot chromes. True when any onApplied returned true.
local function _applyToPlaced(items, placements, onApplied)
    if not items then return false end
    local flagged = false
    for id, widget in pairs(items) do
        local r = placements[id]
        if r then
            ApplyOne(widget, r)
            SetVisible(widget, true)
            if onApplied and onApplied(id, widget, r) then flagged = true end
        else
            SetVisible(widget, false)
        end
    end
    return flagged
end

-- Deferred skinner application -- runs ONCE per slot chrome, the first
-- time the frame has a real rect. See BuildAll's chrome._pendingSkin
-- assignment for why we can't paint at build-time (zero rect means
-- SetAllPoints anchors into a 0x0 box and bg never paints until next
-- refresh -- visible header flicker).
local function _applyPendingSkin(_id, chrome, _region)
    if not chrome._pendingSkin then return end
    HDG.Theme:Register(chrome, chrome._pendingSkin)
    chrome._pendingSkin = nil
end

-- A placed widget whose binding went stale while it was hidden (or was never
-- pushed) is pushed in the pass that reveals it -- after its Show, so a Frame's
-- OnShow hook gets there first and nothing is pushed twice.
local function _pushStaleBinding(_id, widget, _region)
    return HDG.BindingEngine:PushIfStale(widget)
end

-- Returns true when a revealed widget's push moved an auto-sized intrinsic,
-- i.e. these placements were solved against a stale size.
function Layout:Apply(rootFrame, placements)
    if not rootFrame or not placements then return end
    _applyToPlaced(rootFrame.panels,      placements)
    _applyToPlaced(rootFrame.sections,    placements)
    _applyToPlaced(rootFrame.slotChromes, placements, _applyPendingSkin)
    HDG.BindingEngine:SetRevealing(true)
    local moved = _applyToPlaced(rootFrame.widgets, placements, _pushStaleBinding)
    HDG.BindingEngine:SetRevealing(false)
    return moved
end

-- One window's layout pass: harvest intrinsics, compose, apply. When Apply's
-- reveal pushes moved an auto-sized intrinsic, solve once more; the second
-- Apply finds every placed widget current, so this never loops.
-- With perf on, each step of each pass is a lap of its own (HDG.Perf, layout
-- passes); off, every lap is a nil-check.
local PASS_LAPS = {
    { harvest = "pass 1 harvest", compose = "pass 1 compose", apply = "pass 1 apply" },
    { harvest = "pass 2 harvest", compose = "pass 2 compose", apply = "pass 2 apply" },
}
function Layout:LayoutWindow(frame, config, windowName, state)
    local perf = HDG.Perf
    local laps = perf:OpenLayoutLaps(windowName)
    for pass = 1, 2 do
        local lap = PASS_LAPS[pass]
        local intrinsics = self:HarvestIntrinsics(frame, config)
        perf:LayoutLap(laps, lap.harvest)
        local placements = self:ComposeWindow(config, windowName, {
            state      = state,
            intrinsics = intrinsics,
        })
        perf:LayoutLap(laps, lap.compose)
        frame.placements = placements
        local moved = self:Apply(frame, placements)
        perf:LayoutLap(laps, lap.apply)
        if not moved then break end
    end
    perf:CloseLayoutLaps(laps)
end

-- Build phase ----------------------------------------------------------------

local function findEnclosingPanel(id, config)
    local visited = {}
    local cursor = id
    while cursor and not visited[cursor] do
        visited[cursor] = true
        if config.panels and config.panels[cursor] then return cursor end
        local spec = (config.sections and config.sections[cursor])
                  or (config.widgets and config.widgets[cursor])
        cursor = spec and spec["in"] or nil
    end
    return nil
end

-- id -> enclosing panel for every section and widget, built once per config
-- and cached against the config table itself (weak key, so a test that builds
-- a throwaway config does not pin it). LayoutConfig is assembled at file load
-- and nothing writes its tables afterwards, so the map is as static as the
-- specs it describes. Compute reads it every pass; walking the in-chains each
-- pass instead would spend the pointer hops the prune exists to avoid.
local _enclosingCache = setmetatable({}, { __mode = "k" })
_enclosingPanelOf = function(config)
    local map = _enclosingCache[config]
    if map then return map end
    map = {}
    for id in pairs(config.sections or {}) do map[id] = findEnclosingPanel(id, config) end
    for id in pairs(config.widgets  or {}) do map[id] = findEnclosingPanel(id, config) end
    _enclosingCache[config] = map
    return map
end

-- Walks up the in-chain returning the FIRST chromed section (or panel) that
-- encloses the widget. Used to determine widget parent: chromed sections
-- bear a real Frame and become widget parents; ordinary sections are virtual
-- and their child widgets parent through to the enclosing panel.
local function findEnclosingContainer(id, config)
    local visited = {}
    local cursor = (config.widgets and config.widgets[id]) and config.widgets[id]["in"] or nil
    while cursor and not visited[cursor] do
        visited[cursor] = true
        if config.panels and config.panels[cursor] then return cursor, "panel" end
        local sectionSpec = config.sections and config.sections[cursor]
        -- Note: `CHROME_TEMPLATES[chrome]` may be `false` (the `inset` sentinel
        -- meaning "plain Frame, no template inheritance"). Use `~= nil` so we
        -- recognise the section as a valid widget container in that case --
        -- otherwise widgets inside an inset section would walk past it and
        -- end up parented to the enclosing panel with panel-relative coords.
        if sectionSpec and sectionSpec.chrome and CHROME_TEMPLATES[sectionSpec.chrome] ~= nil then
            return cursor, "section"
        end
        cursor = sectionSpec and sectionSpec["in"] or nil
    end
    return nil, nil
end

-- ===== Layout:BuildAll helpers ============================================

-- Theme tinting tokens for section chrome (Blizzard templates ship with
-- brown/wood/slate bgs that we override via SectionBgTint Skinner).
local CHROME_BG_TOKEN = {
    card       = "surface.hover",    -- accent-washed detail fill (~10%) under the 3px accent bar (a contained detail block, not a lone stripe) -- via _attachChromeBgTint
    cardBorder = "surface.hover",    -- same fill as card; border (not stripe) drawn in _attachChromeBgTint
    tooltip    = "surface.panel_soft",
    inset      = "surface.sunken",
}

-- Does this panel's cell map target the named view?
local function _panelTargetsView(panelSpec, viewName)
    return _resolvePanelCell(panelSpec, viewName) ~= nil
end

-- Does this panel target ONLY standalone views? (used by excludeStandalone)
local function _panelIsStandaloneOnly(panelSpec, views)
    if not panelSpec.cell then return false end
    local any = false
    for vName in pairs(panelSpec.cell) do
        any = true
        local v = views[vName]
        if not (v and v.standalone) then return false end
    end
    return any  -- false for cell-less panels (defensive)
end

-- View-scope filter: opts.viewFilter restricts to one view; opts.excludeStandalone
-- skips standalone-only panels. Sections/widgets inherit the enclosing panel's verdict.
local function _makePanelPassesFilter(viewFilter, excludeStandalone, views)
    return function(panelSpec)
        if viewFilter and not _panelTargetsView(panelSpec, viewFilter) then return false end
        if excludeStandalone and _panelIsStandaloneOnly(panelSpec, views) then return false end
        return true
    end
end

-- Build a widget by looking up its WidgetType and calling .build.
-- Returns nil if the kind isn't registered or has no build fn.
--
-- Spec section 5: engines are views over the WidgetTypes registry. After
-- build, this consults the kind's `skin` field (string role name per spec
-- section 22) and registers with the Theme engine. Kinds needing a
-- non-default initial Skinner state (chip's `status`) declare an
-- `initialState(spec)` function on the WidgetType; the result is passed
-- through Theme:Register so the role + state land together.
--
-- Build callbacks NEVER call Theme:Register on the kind's root widget --
-- one source of truth for paint role assignment.
-- Display-string spec fields that may carry a "locale:KEY" prefix. Selector-path
-- fields (binding/visible/setConfig) are deliberately excluded -- the BindingEngine
-- already resolves "locale:" on bindings, and resolving a path field would corrupt it.
local LOCALE_TEXT_FIELDS = {
    "text", "label", "placeholder", "title", "value",
    "leftText", "rightText", "shiftText", "ctrlText", "dragText", "noteText", "selectionPrefix",
}

-- Return a build-ready spec with any "locale:KEY" display fields resolved to text.
-- Plain specs pass through with no allocation. NEVER mutates the shared LayoutConfig
-- table: doing so would bake the first-built locale and stick it across rebuilds.
local function _resolveLocaleSpec(spec)
    if not HDG.Locale then return spec end  -- exception(boundary): Locale load-order partial in headless tests
    local needsCopy = false
    for _, f in ipairs(LOCALE_TEXT_FIELDS) do
        local v = spec[f]
        if type(v) == "string" and v:sub(1, 7) == "locale:" then needsCopy = true; break end
    end
    if not needsCopy then return spec end
    local copy = {}
    for k, v in pairs(spec) do copy[k] = v end
    for _, f in ipairs(LOCALE_TEXT_FIELDS) do
        copy[f] = HDG.Locale:Resolve(copy[f])
    end
    return copy
end

local function _makeBuildKind(env)
    return function(kind, parent, spec)
        local kindDef = HDG.WidgetTypes:Get(kind)  -- errors loudly if missing
        local widget = kindDef.build(parent, _resolveLocaleSpec(spec))
        if not widget then return nil end
        widget._hdgrKind = kind  -- engine introspection (spec section 5)
        -- Per-spec skin override (spec.skin) wins over the kind's default skin --
        -- lets a panel paint a non-Frame role (e.g. navPanel -> NavRegion
        -- panel_soft) without a dedicated kind. Falls back to kindDef.skin.
        local skinRole = spec.skin or kindDef.skin
        if skinRole then
            local state = nil
            if kindDef.initialState then state = kindDef.initialState(spec) end
            HDG.Theme:Register(widget, skinRole, state, env)
        end
        -- Central tooltip wiring: single point of attach for every kind.
        -- TE handles false (no-op), {recipe=…} (registry), and inline shapes.
        -- TE:Attach's _hdgrTooltipAttached guard prevents double-wire.
        -- Tooltips must also show on DISABLED buttons (they often explain WHY
        -- the button is disabled); OnEnter doesn't fire while disabled unless
        -- motion scripts stay on.
        if spec.tooltip and widget.SetMotionScriptsWhileDisabled then  -- exception(false-positive): mock-fidelity (only Buttons carry the method)
            widget:SetMotionScriptsWhileDisabled(true)
        end
        HDG.TooltipEngine:Attach(widget, spec.tooltip)
        return widget
    end
end

-- Build top-level panels. Skips defaultEnabled=false, already-built, or filtered.
local function _buildPanels(config, rootFrame, buildKind, panelPassesFilter)
    for panelId, panelSpec in pairs(config.panels or {}) do
        if panelSpec.defaultEnabled ~= false
           and not rootFrame.panels[panelId]
           and panelPassesFilter(panelSpec)
        then
            local panel = buildKind(panelSpec.kind or "panel", rootFrame, panelSpec)
            if panel then
                panel.id = panelId
                rootFrame.panels[panelId] = panel
            end
        end
    end
end

-- Attach a theme-tinted background texture to a chrome frame so the
-- Blizzard template's bleed (brown wood / slate) is hidden under our
-- palette. SectionBgTint Skinner reads token via Register's stateTable.
local function _attachChromeBgTint(sectionFrame, chrome)
    local bgToken = CHROME_BG_TOKEN[chrome]
    if not (bgToken and sectionFrame.CreateTexture) then return end
    local tint = sectionFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
    if not tint then return end
    tint:SetAllPoints()
    HDG.Theme:Register(tint, "SectionBgTint", { token = bgToken })
    sectionFrame._hdgrBgTint = tint
    -- card: 3px semantic.accent left bar. BORDER layer so it sits above the bg fill.
    if chrome == "card" then
        local bar = sectionFrame:CreateTexture(nil, "BORDER")
        bar:SetPoint("TOPLEFT", 0, 0)
        bar:SetPoint("BOTTOMLEFT", 0, 0)
        bar:SetWidth(3)
        HDG.Theme:Register(bar, "SectionBgTint", { token = "semantic.accent" })
        sectionFrame._hdgrAccentBar = bar
    elseif chrome == "cardBorder" then
        -- 1px border.default edge on all four sides (no accent stripe). Each edge is a
        -- texture registered with the SectionBgTint skinner so it re-tints on theme switch.
        local function _edge(p1, p2, w, h)
            local t = sectionFrame:CreateTexture(nil, "BORDER")
            t:SetPoint(p1, 0, 0); t:SetPoint(p2, 0, 0)
            if w then t:SetWidth(w) end
            if h then t:SetHeight(h) end
            HDG.Theme:Register(t, "SectionBgTint", { token = "border.default" })
            return t
        end
        sectionFrame._hdgrBorder = {
            _edge("TOPLEFT",    "TOPRIGHT",    nil, 1),  -- top
            _edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1),  -- bottom
            _edge("TOPLEFT",    "BOTTOMLEFT",  1,  nil), -- left
            _edge("TOPRIGHT",   "BOTTOMRIGHT", 1,  nil), -- right
        }
    end
end

-- Build one section chrome frame inside its enclosing panel. Returns the
-- created frame or nil if either (a) the section doesn't opt-in to chrome,
-- or (b) the enclosing panel didn't build in this BuildAll call (view-
-- scope filter). `template == false` (vs string) means "create plain
-- Frame, no inheritance" -- used by `inset` so we can paint our own
-- sunken look without fighting Blizzard's NineSlice borders.
local function _buildOneSectionChrome(sectionId, sectionSpec, config, rootFrame, enclosingPanelOK)
    local chrome    = sectionSpec.chrome
    local hasChrome = chrome ~= nil and CHROME_TEMPLATES[chrome] ~= nil
    if not hasChrome then return end
    if rootFrame.sections[sectionId] then return end
    local panelId = _enclosingPanelOf(config)[sectionId]
    if not enclosingPanelOK(panelId) then return end
    local template     = CHROME_TEMPLATES[chrome]
    local inheritsFrom = (type(template) == "string") and template or nil
    local panelFrame   = rootFrame.panels[panelId]
    local sectionFrame = CreateFrame("Frame", nil, panelFrame, inheritsFrom)
    if not sectionFrame then return end
    sectionFrame.id = sectionId
    rootFrame.sections[sectionId] = sectionFrame
    _attachChromeBgTint(sectionFrame, chrome)
end

-- Build chrome frames for sections (chrome = "card"|"inset"|"tooltip"|...).
-- Parents to the enclosing panel; becomes widget parent for the section's children.
-- -- engine-internal
local function _buildSectionChromes(config, rootFrame, enclosingPanelOK)
    if not CreateFrame then return end
    for sectionId, sectionSpec in pairs(config.sections or {}) do
        _buildOneSectionChrome(sectionId, sectionSpec, config, rootFrame, enclosingPanelOK)
    end
end

-- Build one panel-slot chrome frame (pure backdrop, lower frame level so
-- widgets in the slot render on top). Skinner application is DEFERRED via
-- _pendingSkin -- running it pre-Apply at zero size lets CreateTexture-
-- based skinners (PanelHeader) anchor SetAllPoints into 0x0 and the bg
-- never paints until next refresh (visible header flicker).
local function _buildOneSlotChrome(panelId, slotName, slotSpec, panelFrame, rootFrame)
    local skinName = slotSpec.chrome
    local key      = panelId .. "." .. slotName
    if not (skinName and not rootFrame.slotChromes[key]) then return end
    local chrome = CreateFrame("Frame", nil, panelFrame, "BackdropTemplate")
    if not chrome then return end
    if chrome.SetFrameLevel and panelFrame.GetFrameLevel then
        chrome:SetFrameLevel(panelFrame:GetFrameLevel())
    end
    chrome._pendingSkin = skinName
    rootFrame.slotChromes[key] = chrome
end

-- Build chrome frames for panel slots (slot.chrome = skinner key). Widgets
-- still parent to the panel; chrome sits at a lower frame level.
local function _buildSlotChromes(config, rootFrame)
    rootFrame.slotChromes = rootFrame.slotChromes or {}
    if not CreateFrame then return end
    for panelId, panelSpec in pairs(config.panels or {}) do
        local panelFrame = rootFrame.panels[panelId]
        if panelFrame and panelSpec.slots then
            for slotName, slotSpec in pairs(panelSpec.slots) do
                _buildOneSlotChrome(panelId, slotName, slotSpec, panelFrame, rootFrame)
            end
        end
    end
end

-- Resolve the parent frame for a widget. Returns (parent, ok). ok=false
-- means skip this widget (view-scope filter scattered its container into
-- a different BuildAll call's rootFrame).
local function _resolveWidgetParent(widgetId, config, rootFrame, viewFilter, excludeStandalone)
    local containerId, containerKind = findEnclosingContainer(widgetId, config)
    if containerKind == "section" then
        local parent = rootFrame.sections[containerId]
        return parent, parent ~= nil
    end
    if containerId then
        local parent = rootFrame.panels[containerId]
        return parent, parent ~= nil
    end
    -- No enclosing container declared -> top-level widget. Only allowed
    -- when this is an unfiltered build.
    return rootFrame, not (viewFilter or excludeStandalone)
end

-- Build leaf widgets. Skips if parent wasn't built in this rootFrame. A widget
-- whose panel is unbuilt belongs to another pass (the main window builds tab by
-- tab), so it is skipped before its in-chain walk: walked in every pass, the
-- walks were 2 MB of the first open (2026-10-20).
local function _buildWidgets(config, rootFrame, buildKind, viewFilter, excludeStandalone)
    local panelOf = _enclosingPanelOf(config)
    for widgetId, widgetSpec in pairs(config.widgets or {}) do
        local panelId = panelOf[widgetId]
        if widgetSpec.defaultEnabled ~= false and not rootFrame.widgets[widgetId]
           and not (panelId and not rootFrame.panels[panelId]) then
            local parent, ok = _resolveWidgetParent(widgetId, config, rootFrame, viewFilter, excludeStandalone)
            if ok then
                local widget = buildKind(widgetSpec.kind, parent, widgetSpec)
                if widget then
                    widget.id = widgetId
                    rootFrame.widgets[widgetId] = widget
                    -- Born hidden: Layout:Apply shows a widget the moment it has a
                    -- placement, and its OnShow hook paints it then. Born shown, every
                    -- widget of every view answered "shown" to the first open's
                    -- wildcard Bind, which pushed all 769 of them before Layout had
                    -- hidden the 27 views not on screen: 21 MB per open (2026-09-13).
                    widget:Hide()
                end
            end
        end
    end
end

function Layout:BuildAll(rootFrame, config, env, opts)
    if not rootFrame then return end
    config = config or HDG.LayoutConfig or {}
    rootFrame.panels   = rootFrame.panels   or {}
    rootFrame.widgets  = rootFrame.widgets  or {}
    rootFrame.sections = rootFrame.sections or {}

    -- env enables sub-tree previews (alt scheme) without touching
    -- Theme.currentScheme. Callers that skip env get the engine's currentScheme.
    env = env or HDG.Environment._current

    opts = opts or {}
    local viewFilter        = opts.viewFilter
    local excludeStandalone = opts.excludeStandalone == true
    local views             = (config.window and config.window.views) or {}
    local panelPassesFilter = _makePanelPassesFilter(viewFilter, excludeStandalone, views)
    local buildKind         = _makeBuildKind(env)
    local function enclosingPanelOK(panelId)
        return panelId ~= nil and rootFrame.panels[panelId] ~= nil
    end

    _buildPanels(config, rootFrame, buildKind, panelPassesFilter)
    _buildSectionChromes(config, rootFrame, enclosingPanelOK)
    _buildSlotChromes(config, rootFrame)
    _buildWidgets(config, rootFrame, buildKind, viewFilter, excludeStandalone)
end

-- Validation -- catches typos in `in`, `slot`, `kind`, `cell`. --------------

-- Closed-schema field allow-lists. A widget spec may declare ANY field in the
-- universal set PLUS any field its WidgetType registration declares in its
-- `specFields` list. Anything else is a typo (`placholder`) or schema drift
-- (`formatFn`); the validator rejects it loud. Panels + sections have their
-- own field sets -- they're structurally distinct from widgets.
local UNIVERSAL_WIDGET_FIELDS = {
    kind = true, ["in"] = true, slot = true, order = true,
    binding = true, visible = true, defaultEnabled = true,
    width = true, height = true,
    skin = true,  -- per-spec skin override (spec.skin > kind default); honored in _makeBuildKind
    -- Universal-required tooltip declaration. Every widget must declare
    -- tooltip = false (explicit no-tooltip) OR tooltip = { recipe = "Name" }
    -- where Name resolves in HDG.TooltipRecipes. Enforced in Layout:Validate.
    -- Catches "should-have-tooltip-but-doesn't" silently. See VDS migration
    -- (VamoosesDyeStudio/docs/VDS_TOOLTIP_MIGRATION.md) for the design rationale.
    tooltip = true,
    -- ADR-043 per-row async resolver kick ({ idField, valueField, resolver }),
    -- read by BindingEngine at bind time. Undeclared, the validator rejected any
    -- spec that used it, so the middleware could never run (2026-10-18 audit).
    resolveAsync = true,
}
local PANEL_SPEC_FIELDS = {
    kind = true, cell = true, slots = true, frameName = true,
    visible = true, defaultEnabled = true, visibleInViews = true,
    bodyLayout = true, chrome = true,
    padding = true, gap = true,
    skin = true,  -- per-spec skin override (e.g. navPanel -> NavRegion); honored in _makeBuildKind
}
local SECTION_SPEC_FIELDS = {
    ["in"] = true, slot = true, order = true,
    layout = true, padding = true, gap = true, chrome = true,
    visible = true, align = true, visibleInViews = true,   -- buildChildIndex honors it for sections too
    -- Sections accept the same width/height overrides as widgets -- e.g.
    -- a fixed-height column header or a "width = fill" slack absorber row.
    -- The Layout engine reads these in resolveSection. Documented + tested.
    width = true, height = true,
}
Layout._UNIVERSAL_WIDGET_FIELDS = UNIVERSAL_WIDGET_FIELDS  -- exported for tests
Layout._PANEL_SPEC_FIELDS       = PANEL_SPEC_FIELDS
Layout._SECTION_SPEC_FIELDS     = SECTION_SPEC_FIELDS

-- Every other level of the config is closed too, so a field this engine does
-- not read fails Validate instead of sitting in the config doing nothing (25
-- views carried an `explicit` flag nothing ever read). Top level: field ->
-- the type it must have; the size constants are shared by the config files.
local CONFIG_FIELDS = {
    window = "table", windows = "table", panels = "table", sections = "table", widgets = "table",
    CHROME_HEIGHT = "number", STATUS_RAIL_HEIGHT = "number", NAV_WIDTH = "number",
    -- Acquisition's active-filter chips: Controller_Acquisition reads them here.
    _activeFilterTags = "table",
}
local WINDOW_FIELDS = { defaultView = true, padding = true, gap = true, views = true }
local VIEW_SPEC_FIELDS = {
    width = true, height = true, columns = true, rows = true, cells = true,
    dynamicColumns = true, dynamicRows = true, padding = true, standalone = true,
    controllers = true,
}
local CELL_FIELDS = { col = true, row = true, colSpan = true, rowSpan = true }
-- computeSlotRects gives a rect to these three only: a slot of any other name
-- would place none of its children.
local PANEL_SLOT_NAMES  = { header = true, body = true, footer = true }
local PANEL_SLOT_FIELDS = { layout = true, chrome = true, padding = true, gap = true, height = true, align = true }
-- A floating window (HDG.Window) and the slots its frame composes.
local FLOAT_WINDOW_FIELDS = { slots = true, shown = true, position = true, lazy = true, parent = true }
local FLOAT_POSITION_FIELDS = { default = true, movable = true, binding = true, setAction = true }
local WINDOW_SLOT_NAMES = { top = true, bottom = true, left = true, right = true, corner = true, fill = true }
local FLOAT_DEFAULT_FIELDS = { x = true, y = true }
local FILTER_TAG_FIELDS = { axis = true, textSel = true, visibleSel = true }
local TOOLTIP_FIELDS = { recipe = true }
local PADDING_SIDES = { top = true, right = true, bottom = true, left = true }
-- layoutStack stacks "vertical" / "horizontal" and stretches "fill"; it moves
-- children right on "right" and leaves them left otherwise.
local LAYOUTS = { vertical = true, horizontal = true, fill = true }
local ALIGNS  = { left = true, right = true }
-- getAlong's sizes besides a number; any other string fails the stack's sums.
local SIZE_WORDS = { fill = true, auto = true, content = true }

-- ===== Layout:Validate helpers ============================================
-- Each `_validateX` takes `err` (the error-accumulator closure) so the
-- orchestrator owns it; shared helpers (`_validateContainerPlacement`,
-- `_buildContainerIndexes`, etc.) are reused across panel/section/widget
-- validators to kill the parent/slot/order/`in` duplication that was
-- copied across three blocks.

local function _hasKind(kind)
    return HDG.WidgetTypes:TryGet(kind) ~= nil
end

-- Acceptable shape for window view width/height: number OR literal "auto"
-- (M1 derives the size from columns+rows+padding+gap via GetViewDimensions).
local function _validDim(v) return type(v) == "number" or v == "auto" end

-- Closed-schema field check. allowed[] is { fieldName -> true } from the
-- per-level field constant (CONFIG_FIELDS, VIEW_SPEC_FIELDS, PANEL_SPEC_FIELDS,
-- UNIVERSAL_WIDGET_FIELDS + kindDef.specFields for widgets, ...).
local function _validateClosedSchema(entity, id, spec, allowed, label, err)
    for fieldName in pairs(spec) do
        if not allowed[fieldName] then
            err(("%s %q: unknown field %q -- not in %s. Typo? Wrong sub-table?")
                :format(entity, id, tostring(fieldName), label))
        end
    end
end

-- A frame wires the controllers its views list (Controllers:WireAll), so a view
-- that omits the list would leave its widgets unwired. {} = bindings only. The
-- names are checked against the controller registry by test_controller_views,
-- where both are loaded; this engine does not read the registry.
local function _validateViewControllers(viewName, viewSpec, err)
    if type(viewSpec.controllers) ~= "table" then
        err(("config.window.views.%s.controllers is required (the controllers that wire it; {} for none)")
            :format(viewName))
        return
    end
    for i, name in ipairs(viewSpec.controllers) do
        if type(name) ~= "string" or name == "" then
            err(("config.window.views.%s.controllers[%d] must be a controller name"):format(viewName, i))
        end
    end
end

-- A selector-name field: a registered selector, or unset where `required` is not.
local function _checkSelectorName(where, name, err, required)
    if name == nil then
        if required then err(("%s is required (a selector name)"):format(where)) end
    elseif not (type(name) == "string" and HDG.Selectors:Has(name)) then
        err(("%s = %s is not a registered selector"):format(where, tostring(name)))
    end
end

-- resolveSpacing errors on an unknown token, mid-build of the tab, and reads a
-- value of any other type as 0.
local function _checkSpacing(where, value, err)
    if value == nil or type(value) == "number" then return end
    if not (type(value) == "string" and HDG.Theme:GetMetric("spacing." .. value)) then
        err(("%s = %s is not a number or a spacing token"):format(where, tostring(value)))
    end
end

-- normalizePadding takes one spacing value for all four sides, or one per side.
local function _checkPadding(where, value, err)
    if type(value) ~= "table" then
        _checkSpacing(where, value, err)
        return
    end
    _validateClosedSchema("padding", where, value, PADDING_SIDES, "PADDING_SIDES", err)
    for side in pairs(PADDING_SIDES) do _checkSpacing(where .. "." .. side, value[side], err) end
end

local function _checkSpacingFields(where, spec, err)
    _checkPadding(where .. ".padding", spec.padding, err)
    _checkSpacing(where .. ".gap", spec.gap, err)
end

local function _checkSize(entity, id, field, value, err)
    if value ~= nil and type(value) ~= "number" and not SIZE_WORDS[value] then
        err(("%s %q: %s %s is not a number, fill, auto or content"):format(entity, id, field, tostring(value)))
    end
end

-- A track is a number or "fill"; the grid reads any other value as a 0-size
-- track. An "auto" view size sums its tracks, which a "fill" track cannot join.
local function _validateViewTracks(viewName, viewSpec, dimName, sizeField, err)
    local tracks = viewSpec[dimName]
    if type(tracks) ~= "table" then
        err(("config.window.views.%s.%s is required (a list of tracks)"):format(viewName, dimName))
        return
    end
    for i, t in ipairs(tracks) do
        local where = ("config.window.views.%s.%s[%d]"):format(viewName, dimName, i)
        if type(t) ~= "number" and t ~= "fill" then
            err(("%s = %s is not a number or \"fill\""):format(where, tostring(t)))
        elseif t == "fill" and viewSpec[sizeField] == "auto" then
            err(("%s is \"fill\" but %s = \"auto\" sums the tracks"):format(where, sizeField))
        end
    end
end

-- A static grid's cells must lie inside its tracks: _sumSpannedTracks adds
-- start..start+span-1 and a track past the end is nil. A dimension a selector
-- supplies is sized at layout time and cannot be checked here.
local function _validateCellBounds(viewName, cellName, cellSpec, viewSpec, err)
    local colsOK = viewSpec.dynamicColumns ~= nil
        or (cellSpec.col >= 1 and cellSpec.col + cellSpec.colSpan - 1 <= #viewSpec.columns)
    local rowsOK = viewSpec.dynamicRows ~= nil
        or (cellSpec.row >= 1 and cellSpec.row + cellSpec.rowSpan - 1 <= #viewSpec.rows)
    if not (colsOK and rowsOK) then
        err(("config.window.views.%s.cells.%s lies outside the view's %d columns x %d rows")
            :format(viewName, tostring(cellName), #viewSpec.columns, #viewSpec.rows))
    end
end

-- Cells must carry numeric col/row + colSpan/rowSpan -- _sumSpannedTracks and
-- _computeLiveRowsCols do `start + span - 1` arithmetic, so a missing span is a
-- latent runtime nil-crash. Catch it at startup.
local function _validateViewCells(viewName, viewSpec, err)
    for cellName, cellSpec in pairs(viewSpec.cells or {}) do
        local where = ("config.window.views.%s.cells.%s"):format(viewName, tostring(cellName))
        _validateClosedSchema("cell", where, cellSpec, CELL_FIELDS, "CELL_FIELDS", err)
        if type(cellSpec.col) ~= "number" or type(cellSpec.row) ~= "number"
           or type(cellSpec.colSpan) ~= "number" or type(cellSpec.rowSpan) ~= "number" then
            err(("%s needs numeric col/row/colSpan/rowSpan"):format(where))
        elseif type(viewSpec.columns) == "table" and type(viewSpec.rows) == "table" then
            _validateCellBounds(viewName, cellName, cellSpec, viewSpec, err)
        end
    end
end

local function _validateWindowView(viewName, viewSpec, err)
    _validateClosedSchema("view", viewName, viewSpec, VIEW_SPEC_FIELDS, "VIEW_SPEC_FIELDS", err)
    if viewSpec.standalone ~= nil and type(viewSpec.standalone) ~= "boolean" then
        err(("config.window.views.%s.standalone must be true or false"):format(viewName))
    end
    if not _validDim(viewSpec.width) then
        err(("config.window.views.%s.width must be a number or \"auto\""):format(viewName))
    end
    if not _validDim(viewSpec.height) then
        err(("config.window.views.%s.height must be a number or \"auto\""):format(viewName))
    end
    _validateViewTracks(viewName, viewSpec, "columns", "width", err)
    _validateViewTracks(viewName, viewSpec, "rows", "height", err)
    _checkPadding(("config.window.views.%s.padding"):format(viewName), viewSpec.padding, err)
    -- Optional dynamic tracks: ResolveViewTracks calls the selector they name.
    _checkSelectorName(("config.window.views.%s.dynamicColumns"):format(viewName), viewSpec.dynamicColumns, err)
    _checkSelectorName(("config.window.views.%s.dynamicRows"):format(viewName), viewSpec.dynamicRows, err)
    _validateViewCells(viewName, viewSpec, err)
    _validateViewControllers(viewName, viewSpec, err)
end

-- Window shape: missing height/mode/mode.width would silently become 0
-- at runtime without these checks (now that defensive defaults are gone).
-- Catch them at startup instead.
local function _validateWindow(windowCfg, err)
    if not windowCfg then
        err("config.window is missing")
        return
    end
    _validateClosedSchema("window", "config.window", windowCfg, WINDOW_FIELDS, "WINDOW_FIELDS", err)
    _checkSpacingFields("config.window", windowCfg, err)
    if not windowCfg.views or type(windowCfg.views) ~= "table" then
        err("config.window.views must be a table")
        return
    end
    if not windowCfg.defaultView then
        err("config.window.defaultView is required")
    elseif not windowCfg.views[windowCfg.defaultView] then
        err(("config.window.defaultView = %q does not exist in window.views"):format(
            tostring(windowCfg.defaultView)))
    end
    for viewName, viewSpec in pairs(windowCfg.views) do
        _validateWindowView(viewName, viewSpec, err)
    end
end

-- Top level: every key is one the engine or a config file reads, with its type.
local function _validateConfigFields(config, err)
    for key, value in pairs(config) do
        local want = CONFIG_FIELDS[key]
        if not want then
            err(("config.%s: unknown top-level field -- not in CONFIG_FIELDS. Typo?"):format(tostring(key)))
        elseif type(value) ~= want then
            err(("config.%s must be a %s"):format(key, want))
        end
    end
end

-- HDG.Window reads the saved position through `binding` and dispatches
-- `setAction` (an ACTIONS key) when a drag stops.
local function _validateWindowPosition(where, position, err)
    _validateClosedSchema("window position", where, position, FLOAT_POSITION_FIELDS, "FLOAT_POSITION_FIELDS", err)
    _checkSelectorName(where .. ".binding", position.binding, err)
    if position.setAction ~= nil and not HDG.Constants.ACTIONS[position.setAction] then
        err(("%s.setAction = %s is not a key of Constants.ACTIONS"):format(where, tostring(position.setAction)))
    end
    if position.movable ~= nil and type(position.movable) ~= "boolean" then
        err(("%s.movable must be true or false"):format(where))
    end
    local default = position.default
    if default == nil then return end
    _validateClosedSchema("window position", where .. ".default", default, FLOAT_DEFAULT_FIELDS,
        "FLOAT_DEFAULT_FIELDS", err)
    if type(default.x) ~= "number" or type(default.y) ~= "number" then
        err(("%s.default needs numeric x and y"):format(where))
    end
end

-- A window's slots name the views its frame composes. "@view" is the main
-- window's open tab; any other view must be standalone, or the main window
-- would build it as a tab too.
local function _validateWindowSlots(where, slots, views, err)
    for slot, view in pairs(slots) do
        local at = ("%s.slots.%s"):format(where, tostring(slot))
        if not WINDOW_SLOT_NAMES[slot] then
            err(("%s: unknown slot -- not in WINDOW_SLOT_NAMES"):format(at))
        elseif view ~= "@view" and not views[view] then
            err(("%s = %s does not exist in window.views"):format(at, tostring(view)))
        elseif view ~= "@view" and not views[view].standalone then
            err(("%s = %q is not standalone: the main window would also build it as a tab"):format(at, view))
        end
    end
end

local function _validateFloatingWindow(name, win, views, err)
    local where = ("config.windows.%s"):format(tostring(name))
    _validateClosedSchema("window", where, win, FLOAT_WINDOW_FIELDS, "FLOAT_WINDOW_FIELDS", err)
    _checkSelectorName(where .. ".shown", win.shown, err)
    if win.lazy ~= nil and type(win.lazy) ~= "boolean" then err(("%s.lazy must be true or false"):format(where)) end
    if win.parent ~= nil and type(win.parent) ~= "function" then
        err(("%s.parent must be a function returning the parent frame"):format(where))
    end
    if win.position ~= nil then _validateWindowPosition(where .. ".position", win.position, err) end
    if type(win.slots) ~= "table" or win.slots.fill == nil then
        err(("%s.slots.fill is required (the view the window shows)"):format(where))
        return
    end
    _validateWindowSlots(where, win.slots, views, err)
end

-- A standalone view builds only into a window that names it (chrome, status and
-- nav into the main frame, the rest into their own), so one no window names
-- renders nowhere.
local function _validateStandaloneViewsShown(windows, views, err)
    local shown = {}
    for _, win in pairs(windows) do
        for _, view in pairs(win.slots or {}) do shown[view] = true end
    end
    for viewName, viewSpec in pairs(views) do
        if viewSpec.standalone and not shown[viewName] then
            err(("config.window.views.%s is standalone but no config.windows entry shows it"):format(viewName))
        end
    end
end

local function _validateFloatingWindows(config, err)
    local views = config.window and config.window.views
    if type(views) ~= "table" then return end   -- reported by _validateWindow
    for name, win in pairs(config.windows or {}) do
        _validateFloatingWindow(name, win, views, err)
    end
    _validateStandaloneViewsShown(config.windows or {}, views, err)
end

-- Controller_Acquisition paints one chip per entry from these two selectors.
local function _validateFilterTags(tags, err)
    for i, tag in ipairs(tags) do
        local where = ("config._activeFilterTags[%d]"):format(i)
        _validateClosedSchema("filter tag", where, tag, FILTER_TAG_FIELDS, "FILTER_TAG_FIELDS", err)
        _checkSelectorName(where .. ".textSel", tag.textSel, err, true)
        _checkSelectorName(where .. ".visibleSel", tag.visibleSel, err, true)
    end
end

-- Build (containerIds, panelSlots) -- the resolution maps consumed by
-- per-spec parent/slot validators below.
local function _buildContainerIndexes(config)
    local containerIds = {}
    for id in pairs(config.panels or {}) do containerIds[id] = "panel" end
    for id in pairs(config.sections or {}) do containerIds[id] = "section" end
    local panelSlots = {}
    for id, spec in pairs(config.panels or {}) do
        panelSlots[id] = { body = true }
        for slotName in pairs(spec.slots or {}) do
            panelSlots[id][slotName] = true
        end
    end
    return containerIds, panelSlots
end

-- Resolve the layout direction for a container reference (panel.slot,
-- panel body, or section). Returns "vertical" / "horizontal" / "fill",
-- or nil when (parentId, slot) doesn't name a known container.
--
-- The fallback chain for panels: slot.layout > implicit-by-name
-- (header/footer => horizontal) > panel.bodyLayout > "vertical".
-- For sections: section.layout > "vertical".
local function _resolveContainerLayout(config, parentId, slot)
    if not parentId then return nil end
    local panelSpec = config.panels and config.panels[parentId]
    if panelSpec then
        if slot then
            local slotSpec = (panelSpec.slots or {})[slot]
            if slotSpec then return _defaultSlotLayout(slot, slotSpec.layout) end
        end
        return panelSpec.bodyLayout or "vertical"
    end
    local sectionSpec = config.sections and config.sections[parentId]
    if sectionSpec then return sectionSpec.layout or "vertical" end
    return nil
end

-- Returns isStackedContainer(parentId, slot) -> bool closure over config.
-- Stacked containers (vertical/horizontal layout) require explicit `order`
-- on every child -- silent default-to-0 sorts ABOVE explicitly-ordered
-- siblings, which has bitten us before (May 2026 indexHeader-at-bottom).
local function _makeIsStackedContainer(config)
    return function(parentId, slot)
        local layout = _resolveContainerLayout(config, parentId, slot)
        return layout == "vertical" or layout == "horizontal"
    end
end

-- Mis-keying audit: catch widget specs accidentally placed in
-- config.panels (structurally invisible bug class -- see HouseTab/Trainers
-- May 2026 pass). Three rules:
--   config.panels   -> must not have `in` (panels use `cell`)
--                      must not be a leaf widget kind (has dispatch)
--   config.sections -> must not have `kind` (sections are layout, not widget)
--   config.widgets  -> must not have `cell` (cell is panel placement)
local function _validatePanelsMiskeying(panels, err)
    for id, spec in pairs(panels) do
        if spec["in"] then
            err(("panel %q has `in` = %q -- panels are placed via `cell`, not `in`."
                .. " Did you mean to put this in config.widgets or config.sections?")
                :format(id, tostring(spec["in"])))
        end
        -- Heuristic: leaf widgets have a `dispatch` field on their
        -- WidgetType registration (they need refresh on state changes);
        -- containers do not. Validator queries the registry, not the name.
        if spec.kind then
            local kindDef = HDG.WidgetTypes:TryGet(spec.kind)
            if kindDef and kindDef.dispatch then
                err(("panel %q has kind = %q -- that's a leaf widget kind "
                    .. "(has dispatch). Did you mean to put this in config.widgets?")
                    :format(id, spec.kind))
            end
        end
    end
end

local function _validateSectionsMiskeying(sections, err)
    for id, spec in pairs(sections) do
        if spec.kind then
            err(("section %q has `kind` = %q -- sections don't have a kind."
                .. " Did you mean config.widgets?"):format(id, tostring(spec.kind)))
        end
    end
end

local function _validateWidgetsMiskeying(widgets, err)
    for id, spec in pairs(widgets) do
        if spec.cell then
            err(("widget %q has `cell` = %s -- cell is panel placement, not widget."
                .. " Did you mean config.panels?"):format(id, tostring(spec.cell)))
        end
    end
end

local function _validateMiskeying(config, err)
    _validatePanelsMiskeying(config.panels or {}, err)
    _validateSectionsMiskeying(config.sections or {}, err)
    _validateWidgetsMiskeying(config.widgets or {}, err)
end

-- Shared parent/slot/order placement check. Used by BOTH section and
-- widget validators -- DRY'd from the original two near-identical inline
-- blocks. `entity` is "section" or "widget" for the error message; the
-- behavior is otherwise identical.
local function _validateContainerPlacement(entity, id, spec, containerIds, panelSlots, isStackedContainer, err)
    local parent = spec["in"]
    if not parent then
        err(("%s %q: missing `in` field"):format(entity, id))
        return
    end
    if not containerIds[parent] then
        err(("%s %q: `in` = %q does not resolve to a panel or section"):format(entity, id, parent))
        return
    end
    if spec.slot then
        if containerIds[parent] == "panel" and not panelSlots[parent][spec.slot] then
            err(("%s %q: slot %q not declared on panel %q"):format(entity, id, spec.slot, parent))
        elseif containerIds[parent] == "section" then
            err(("%s %q: slot %q is ignored because parent %q is a section, not a panel")
                :format(entity, id, spec.slot, parent))
        end
    end
    if isStackedContainer(parent, spec.slot) and spec.order == nil then
        err(("%s %q: `in` = %q is a stacked container; `order` is required")
            :format(entity, id, tostring(parent)))
    end
end

-- Selector-reference fields: `binding` (widgets) and `visible` (widgets,
-- panels, sections) may name a selector. A string that isn't a static:/locale:
-- literal is a selector name and MUST resolve in HDG.Selectors -- otherwise
-- the typo degrades silently: Selectors:Call returns nil for an unknown name,
-- so a bad `binding` paints an empty widget and a bad `visible` hides the
-- entity outright (resolveVisible treats nil as hidden). Closes the
-- binding/visible -> selector taxonomy the same way kind / rowKind / tooltip
-- recipe are already closed: a loud boot print, not silent-empty UI.
local function _isSelectorRef(v)
    return type(v) == "string"
        and v:sub(1, 7) ~= "static:"
        and v:sub(1, 7) ~= "locale:"
end

local function _validateSelectorRefs(entity, id, spec, err)
    local binding = spec.binding
    if _isSelectorRef(binding) then
        if not HDG.Selectors:Has(binding) then
            err(("%s %q: binding %q is not a registered selector"):format(entity, id, binding))
        end
    elseif type(binding) == "table" then
        for field, ref in pairs(binding) do
            if _isSelectorRef(ref) and not HDG.Selectors:Has(ref) then
                err(("%s %q: binding.%s = %q is not a registered selector")
                    :format(entity, id, tostring(field), ref))
            end
        end
    end
    -- `visible` string form is always a selector name (resolveVisible does no
    -- static:/locale: prefixing); boolean / function forms are non-selector.
    if type(spec.visible) == "string" and not HDG.Selectors:Has(spec.visible) then
        err(("%s %q: visible %q is not a registered selector"):format(entity, id, spec.visible))
    end
end

-- "locale:KEY" resolves in the display fields (_resolveLocaleSpec) and in the
-- binding (BindingEngine). A key enUS lacks shows as the raw key; a locale
-- string in any other field reaches the build unresolved.
local LOCALE_FIELD_SET = {}
for _, f in ipairs(LOCALE_TEXT_FIELDS) do LOCALE_FIELD_SET[f] = true end

local function _isLocaleRef(v) return type(v) == "string" and v:sub(1, 7) == "locale:" end

local function _checkLocaleKey(entity, id, field, value, err)
    if _isLocaleRef(value) and not HDG.Locale:Has(value:sub(8)) then
        err(("%s %q: %s = %q is not a locale key"):format(entity, id, field, value))
    end
end

local function _validateLocaleRefs(entity, id, spec, err)
    for field, value in pairs(spec) do
        if field == "binding" and type(value) == "table" then
            for bf, bv in pairs(value) do _checkLocaleKey(entity, id, "binding." .. tostring(bf), bv, err) end
        elseif LOCALE_FIELD_SET[field] or field == "binding" then
            _checkLocaleKey(entity, id, field, value, err)
        elseif _isLocaleRef(value) then
            err(("%s %q: %s = %q reaches the build unresolved -- not in LOCALE_TEXT_FIELDS or a binding")
                :format(entity, id, tostring(field), value))
        end
    end
end

-- A Theme role named by a spec (a skin, a label's role, a slot chrome): Theme:Register
-- only warns on an unknown one and the frame never paints.
local function _checkSkin(entity, id, field, role, err)
    if role ~= nil and not HDG.Theme.Skinners[role] then
        err(("%s %q: %s %q has no Theme Skinner -- it would not paint"):format(entity, id, field, tostring(role)))
    end
end

-- layout / align values layoutStack acts on; any other value reads as the default.
local function _checkLayoutValues(entity, id, spec, err)
    if spec.layout ~= nil and not LAYOUTS[spec.layout] then
        err(("%s %q: layout %q is not vertical, horizontal or fill"):format(entity, id, tostring(spec.layout)))
    end
    if spec.align ~= nil and not ALIGNS[spec.align] then
        err(("%s %q: align %q is not left or right"):format(entity, id, tostring(spec.align)))
    end
end

local function _validatePanelSlots(id, slots, err)
    for slotName, slotSpec in pairs(slots) do
        local where = ("%s.slots.%s"):format(id, tostring(slotName))
        if not PANEL_SLOT_NAMES[slotName] then
            err(("panel %q: slot %q gets no rect -- only header, body and footer are laid out")
                :format(id, tostring(slotName)))
        end
        _validateClosedSchema("panel slot", where, slotSpec, PANEL_SLOT_FIELDS, "PANEL_SLOT_FIELDS", err)
        _checkSkin("panel slot", where, "chrome", slotSpec.chrome, err)
        _checkLayoutValues("panel slot", where, slotSpec, err)
        _checkSpacingFields(where, slotSpec, err)
        -- computeSlotRects subtracts the header and footer heights from the panel's.
        if slotSpec.height ~= nil and type(slotSpec.height) ~= "number" then
            err(("panel %q: slot %q height must be a number"):format(id, tostring(slotName)))
        end
    end
end

-- visibleInViews (panels, sections) names the views the entity renders in.
local function _validateVisibleInViews(config, err)
    local views = config.window and config.window.views or {}
    for _, entity in ipairs({ "panels", "sections" }) do
        for id, spec in pairs(config[entity] or {}) do
            for _, view in ipairs(spec.visibleInViews or {}) do
                if not views[view] then
                    err(("%s %q: visibleInViews names %q, not in window.views"):format(entity, id, tostring(view)))
                end
            end
        end
    end
end

local function _validatePanel(id, spec, config, err)
    if spec.kind and not _hasKind(spec.kind) then
        err(("panel %q: kind %q is not a registered WidgetType"):format(id, spec.kind))
    end
    _validateClosedSchema("panel", id, spec, PANEL_SPEC_FIELDS, "PANEL_SPEC_FIELDS", err)
    _validateSelectorRefs("panel", id, spec, err)
    _validateLocaleRefs("panel", id, spec, err)
    _validatePanelSlots(id, spec.slots or {}, err)
    _checkSkin("panel", id, "skin", spec.skin, err)
    _checkSpacingFields(id, spec, err)
    if spec.bodyLayout ~= nil and not LAYOUTS[spec.bodyLayout] then
        err(("panel %q: bodyLayout %q is not vertical, horizontal or fill"):format(id, tostring(spec.bodyLayout)))
    end
    -- A panel renders only in the views its cell map names, and the main window
    -- builds tab by tab: a panel naming none would render nowhere and build in no tab.
    if next(spec.cell or {}) == nil then
        err(("panel %q has no cell -- it renders in no view"):format(id))
    end
    for view, cellName in pairs(spec.cell or {}) do
        local viewSpec = (config.window and config.window.views or {})[view]
        if not viewSpec then
            err(("panel %q: cell view %q does not exist in window.views"):format(id, view))
        elseif not (viewSpec.cells and viewSpec.cells[cellName]) then
            err(("panel %q: cell %q does not exist in window.views.%s.cells")
                :format(id, cellName, view))
        end
    end
end

local function _validateSection(id, spec, containerIds, panelSlots, isStackedContainer, err)
    _validateClosedSchema("section", id, spec, SECTION_SPEC_FIELDS, "SECTION_SPEC_FIELDS", err)
    _validateSelectorRefs("section", id, spec, err)
    _validateLocaleRefs("section", id, spec, err)
    _validateContainerPlacement("section", id, spec, containerIds, panelSlots, isStackedContainer, err)
    _checkLayoutValues("section", id, spec, err)
    _checkSpacingFields(id, spec, err)
    _checkSize("section", id, "width", spec.width, err)
    _checkSize("section", id, "height", spec.height, err)
    -- An unknown chrome builds no chrome frame, and the section's widgets, which
    -- parent to it, then build nowhere.
    if spec.chrome ~= nil and CHROME_TEMPLATES[spec.chrome] == nil then
        err(("section %q: chrome %q is not in Layout.CHROME_TEMPLATES"):format(id, tostring(spec.chrome)))
    end
end

-- Kinds whose construction requires a `font` field on the spec.
local _TEXT_BEARING_KINDS = {
    label = true,        -- + role ("TextDim"/"TextStatus") drives paint role
    button = true, editbox = true,
    chip = true,         -- chip has a label
}

-- Per-instance font requirement: text-bearing kinds may declare a
-- `requiresFont(spec) -> bool` predicate on their WidgetType to suppress
-- the font requirement for specific spec shapes (icon-only button variants
-- are the canonical case). Engines query the registry, never peek at
-- the spec internals directly. (Spec section 5.)
local function _specRequiresFont(spec)
    if not _TEXT_BEARING_KINDS[spec.kind] then return false end
    local kindDef = HDG.WidgetTypes:TryGet(spec.kind)
    if kindDef and kindDef.requiresFont then
        return kindDef.requiresFont(spec) == true
    end
    return true
end

-- Closed-schema check for widgets. Allowed set is the union of
-- UNIVERSAL_WIDGET_FIELDS + per-kind specFields. Delegates the actual
-- check to _validateClosedSchema (shared with panel/section).
local function _validateWidgetSpecFields(id, spec, err)
    if not (spec.kind and _hasKind(spec.kind)) then return end
    local kindDef = HDG.WidgetTypes:TryGet(spec.kind)
    if not kindDef.specFields then return end
    local allowed = {}
    for k in pairs(UNIVERSAL_WIDGET_FIELDS) do allowed[k] = true end
    for _, fieldName in ipairs(kindDef.specFields) do allowed[fieldName] = true end
    _validateClosedSchema("widget", id, spec, allowed,
        ("UNIVERSAL_WIDGET_FIELDS or WidgetType[%q].specFields"):format(spec.kind), err)
end

-- Universal-required tooltip declaration. Every widget MUST declare:
--   tooltip = false                  -- explicit no-tooltip
--   tooltip = { recipe = "Name" }    -- name resolves in HDG.TooltipRecipes
-- Catches "should-have-tooltip-but-doesn't" silently. Inline strings,
-- inline tables, inline functions REJECTED at boot -- content lives in
-- the recipe registry only. See VDS migration doc + cookbook.
local function _validateWidgetTooltip(id, spec, err)
    local tip = spec.tooltip
    if tip == nil then
        err(("widget %q (kind %q): missing required `tooltip` field -- "
            .. "declare tooltip = false OR tooltip = { recipe = \"Name\" }")
            :format(id, tostring(spec.kind)))
        return
    end
    if tip == false then return end  -- explicit no-tooltip; valid
    if type(tip) ~= "table" then
        err(("widget %q (kind %q): tooltip must be false OR { recipe = \"Name\" } -- got %s. "
            .. "Inline strings/tables/functions are not allowed; use a named recipe.")
            :format(id, tostring(spec.kind), type(tip)))
        return
    end
    _validateClosedSchema("widget tooltip", id, tip, TOOLTIP_FIELDS, "TOOLTIP_FIELDS", err)
    if type(tip.recipe) ~= "string" then
        err(("widget %q (kind %q): tooltip table must be { recipe = \"Name\" } -- got recipe = %s")
            :format(id, tostring(spec.kind), type(tip.recipe)))
        return
    end
    if HDG.TooltipRecipes[tip.recipe] == nil then
        err(("widget %q (kind %q): tooltip recipe %q not registered in HDG.TooltipRecipes")
            :format(id, tostring(spec.kind), tip.recipe))
    end
end

-- Scrollboxes that reference a rowKind must resolve to a registered
-- HDG.Rows entry. Scrollboxes without rowKind require `rowHeight` inline.
local function _validateWidgetScrollbox(id, spec, err)
    if spec.kind ~= "scrollbox" then return end
    if spec.rowKind then
        if not HDG.Rows:Get(spec.rowKind) then
            err(("widget %q: scrollbox rowKind %q not registered in HDG.Rows")
                :format(id, spec.rowKind))
        end
        return
    end
    if not spec.rowHeight then
        err(("widget %q: scrollbox without rowKind requires `rowHeight` field"):format(id))
    end
end

-- Names a widget's build resolves. An unknown font role or cell kind errors only
-- when the widget's tab is first built; an unknown role or skin only warns.
local function _validateWidgetRefs(id, spec, err)
    if spec.font ~= nil and HDG.Theme:GetFont(spec.font) == nil then
        err(("widget %q: font role %q is not a Theme font"):format(id, tostring(spec.font)))
    end
    _checkSkin("widget", id, "role", spec.role, err)
    _checkSkin("widget", id, "skin", spec.skin, err)
    _checkSize("widget", id, "width", spec.width, err)
    _checkSize("widget", id, "height", spec.height, err)
    if not (spec.kind and _hasKind(spec.kind)) then return end
    local kindDef = HDG.WidgetTypes:TryGet(spec.kind)
    if spec.cellKind ~= nil and not (kindDef.resolveCellKind and kindDef.resolveCellKind(spec.cellKind)) then
        err(("widget %q: cellKind %q is not a registered %s cell kind")
            :format(id, tostring(spec.cellKind), spec.kind))
    end
    local problem = kindDef.checkSpec and kindDef.checkSpec(spec)
    if problem then err(("widget %q (kind %q): %s"):format(id, spec.kind, problem)) end
end

-- resolveAsync: a list of entries BindingEngine asserts on at the first paint.
local RESOLVE_ASYNC_FIELDS = { idField = true, valueField = true, resolver = true }
local function _validateResolveAsync(id, spec, err)
    if spec.resolveAsync == nil then return end
    for i, entry in ipairs(spec.resolveAsync) do
        local where = ("%s.resolveAsync[%d]"):format(id, i)
        _validateClosedSchema("widget", where, entry, RESOLVE_ASYNC_FIELDS, "RESOLVE_ASYNC_FIELDS", err)
        if type(entry.idField) ~= "string" or type(entry.valueField) ~= "string"
           or type(entry.resolver) ~= "table" or type(entry.resolver.Request) ~= "function" then
            err(("widget %q: resolveAsync[%d] needs idField, valueField and a resolver with Request"):format(id, i))
        end
    end
end

-- BindingEngine pushes the fields the kind's dispatch declares (a scalar binding
-- fills the first). On a kind without them the bind errors; a field the kind
-- does not declare is resolved on every push and never painted.
local function _validateWidgetBinding(id, spec, err)
    if spec.binding == nil or not (spec.kind and _hasKind(spec.kind)) then return end
    local dispatch = HDG.WidgetTypes:TryGet(spec.kind).dispatch
    if not (dispatch and dispatch.fields and dispatch.fields[1]) then
        err(("widget %q: kind %q has no dispatch fields to bind"):format(id, spec.kind))
        return
    end
    if type(spec.binding) ~= "table" then return end
    local declared = {}
    for _, field in ipairs(dispatch.fields) do declared[field] = true end
    for field in pairs(spec.binding) do
        if not declared[field] then
            err(("widget %q: binding.%s is not a dispatch field of kind %q"):format(id, tostring(field), spec.kind))
        end
    end
end

local function _validateWidget(id, spec, containerIds, panelSlots, isStackedContainer, err)
    if not spec.kind then
        err(("widget %q: missing `kind` field"):format(id))
    elseif not _hasKind(spec.kind) then
        err(("widget %q: kind %q is not a registered WidgetType"):format(id, spec.kind))
    end
    _validateContainerPlacement("widget", id, spec, containerIds, panelSlots, isStackedContainer, err)
    if spec.kind and _specRequiresFont(spec) and not spec.font then
        err(("widget %q: kind %q is text-bearing and requires a `font` role")
            :format(id, spec.kind))
    end
    _validateWidgetSpecFields(id, spec, err)
    _validateWidgetTooltip(id, spec, err)
    _validateWidgetScrollbox(id, spec, err)
    _validateSelectorRefs("widget", id, spec, err)
    _validateLocaleRefs("widget", id, spec, err)
    _validateWidgetRefs(id, spec, err)
    _validateWidgetBinding(id, spec, err)
    _validateResolveAsync(id, spec, err)
end

-- Every level of the config is checked, and every level is closed: a field no
-- check knows is an error, so the config cannot grow a part Validate skips.
-- Run by tests/test_layout_validate.lua, which deploy and release require; the
-- game does not run it (the spec is fixed at ship time).
function Layout:Validate(config)
    config = config or HDG.LayoutConfig or {}
    local errors = {}
    local function err(msg) errors[#errors + 1] = msg end

    _validateConfigFields(config, err)
    _validateWindow(config.window, err)
    _validateFloatingWindows(config, err)
    _validateFilterTags(config._activeFilterTags or {}, err)
    _validateVisibleInViews(config, err)
    local containerIds, panelSlots = _buildContainerIndexes(config)
    local isStackedContainer = _makeIsStackedContainer(config)
    _validateMiskeying(config, err)

    for id, spec in pairs(config.panels or {}) do
        _validatePanel(id, spec, config, err)
    end
    for id, spec in pairs(config.sections or {}) do
        _validateSection(id, spec, containerIds, panelSlots, isStackedContainer, err)
    end
    for id, spec in pairs(config.widgets or {}) do
        _validateWidget(id, spec, containerIds, panelSlots, isStackedContainer, err)
    end

    return errors
end

-- ===== DescribeView (debug helper) =========================================
-- Returns a multi-line string showing the layout chain for a view:
--   view dimensions -> body padding -> per-panel slot widths -> section
--   widths -> widget widths. Uses HDG.mainFrame.placements (the live
--   resolved values) so the dump matches what's actually rendered.
--
-- Surfaced via the Debug tab's layout input + "Describe" button so a
-- contributor doing card-grid math doesn't have to walk 4 files. Width
-- formula for card grids:
--   cardgrid_inner = N * cellSize + (N-1) * cellSpacing + (chrome inset pad)
--   scrollbox_width = host - HDG.UI.SCROLLBOX_SCROLLBAR_RESERVE
--   host = centerColumn (a `fill` widget gets the slack from contentRow)
-- ===== Layout:DescribeView helpers ========================================

-- Format the placement string for a given id. "(not placed)" when the
-- Layout pipeline hasn't produced a placement (e.g. defaultEnabled=false).
local function _formatPlacement(placements, id)
    local p = placements[id]
    if not p then return "(not placed)" end
    return ("%dx%d"):format(p.width or 0, p.height or 0)
end

-- Build the bracketed "[chrome=card, pad=4, ...]" string for a spec.
-- Returns empty string when no extra fields are present.
local function _formatSpecExtras(spec)
    local extras = {}
    if spec.chrome  then extras[#extras + 1] = "chrome=" .. spec.chrome end
    if spec.padding then extras[#extras + 1] = "pad="    .. tostring(spec.padding) end
    if spec.gap     then extras[#extras + 1] = "gap="    .. tostring(spec.gap)     end
    if spec.layout  then extras[#extras + 1] = "layout=" .. spec.layout end
    if spec.kind    then extras[#extras + 1] = "kind="   .. spec.kind   end
    if #extras == 0 then return "" end
    return "  [" .. table.concat(extras, ", ") .. "]"
end

-- "Unknown view foo -- known: a, b, c" error string.
local function _describeUnknownView(viewName, config)
    local known = {}
    for name in pairs(config.window.views) do known[#known + 1] = name end
    table.sort(known)
    return ("unknown view %q -- known: %s"):format(tostring(viewName), table.concat(known, ", "))
end

-- Build the childrenOf reverse-index: { [parentId] = { {id, kind, spec, order}, ... } }
-- Both sections and widgets contribute. Lists sorted by spec.order for
-- deterministic walk output.
local function _buildChildrenOfIndex(config)
    local childrenOf = {}
    local function addChild(parentId, id, kind, spec)
        if not parentId then return end
        childrenOf[parentId] = childrenOf[parentId] or {}
        childrenOf[parentId][#childrenOf[parentId] + 1] = {
            id = id, kind = kind, spec = spec, order = spec.order
        }
    end
    for id, spec in pairs(config.sections or {}) do
        addChild(spec["in"], id, "section", spec)
    end
    for id, spec in pairs(config.widgets or {}) do
        addChild(spec["in"], id, "widget", spec)
    end
    for _, list in pairs(childrenOf) do
        table.sort(list, function(a, b) return (a.order or 0) < (b.order or 0) end)  -- fill/overlay sections omit order
    end
    return childrenOf
end

-- Recursive child walker. Appends "<indent>section foo: 100x200  (spec 100x200)
-- [chrome=card]" lines to `out` for each descendant of parentId.
local function _walkChildren(parentId, indent, childrenOf, placements, out)
    local list = childrenOf[parentId]
    if not list then return end
    for _, c in ipairs(list) do
        local spec = c.spec
        out[#out + 1] = ("%s%-7s %s: %s  (spec %sx%s)%s"):format(
            indent, c.kind, c.id,
            _formatPlacement(placements, c.id),
            tostring(spec.width or "?"), tostring(spec.height or "?"),
            _formatSpecExtras(spec))
        _walkChildren(c.id, indent .. "  ", childrenOf, placements, out)
    end
end

-- View header section: "view X: 800x600" + columns/rows track lists.
local function _describeViewHeader(out, viewName, viewSpec, vw, vh)
    out[#out + 1] = ("view %s: %dx%d"):format(viewName, vw, vh)
    if viewSpec.columns then
        out[#out + 1] = ("  columns: { %s }"):format(table.concat(viewSpec.columns, ", "))
    end
    if viewSpec.rows then
        local rowStrs = {}
        for _, r in ipairs(viewSpec.rows) do rowStrs[#rowStrs + 1] = tostring(r) end
        out[#out + 1] = ("  rows: { %s }"):format(table.concat(rowStrs, ", "))
    end
end

-- Print one panel header + its slots + recurse into its descendants.
local function _describeOnePanel(out, panelId, panelSpec, viewName, viewSpec, placements, childrenOf)
    local cellName = _resolvePanelCell(panelSpec, viewName)
    if not (cellName and viewSpec.cells and viewSpec.cells[cellName]) then return end
    out[#out + 1] = ("panel  %s [cell=%s]: %s"):format(
        panelId, cellName, _formatPlacement(placements, panelId))
    if panelSpec.slots then
        for slotName in pairs(panelSpec.slots) do
            out[#out + 1] = ("  slot %s"):format(slotName)
        end
    end
    _walkChildren(panelId, "  ", childrenOf, placements, out)
end

-- Iterate panels visible in this view + print each.
local function _describeViewPanels(out, config, viewName, viewSpec, placements, childrenOf)
    for panelId, panelSpec in pairs(config.panels or {}) do
        _describeOnePanel(out, panelId, panelSpec, viewName, viewSpec, placements, childrenOf)
    end
end

-- Footer hint: scrollbar reserve constant for card-grid math debugging.
local function _describeViewFooter(out)
    out[#out + 1] = ""
    out[#out + 1] = ("scrollbox scrollbar reserve: %d px"):format(
        HDG.UI.SCROLLBOX_SCROLLBAR_RESERVE)
end

function Layout:DescribeView(viewName)
    local config = HDG.LayoutConfig
    if not (config and config.window and config.window.views) then
        return "Layout:DescribeView: HDG.LayoutConfig missing"
    end
    local viewSpec = config.window.views[viewName]
    if not viewSpec then return _describeUnknownView(viewName, config) end

    local placements = (HDG.mainFrame and HDG.mainFrame.placements) or {}  -- exception(boundary): optional module / not yet built
    local out = {}
    local vw, vh = self:GetViewDimensions(config, viewName)
    local childrenOf = _buildChildrenOfIndex(config)

    _describeViewHeader(out, viewName, viewSpec, vw, vh)
    _describeViewPanels(out, config, viewName, viewSpec, placements, childrenOf)
    _describeViewFooter(out)

    return table.concat(out, "\n")
end
