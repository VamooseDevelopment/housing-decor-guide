-- HDG.Window
-- ============================================================================
-- Satellite floating-window reconciler (per ADR-025). Each satellite
-- (Lumber Tracker, Shopping List, Zone Scanner, Companion) is a top-level
-- CreateFrame declared in HDG.LayoutConfig.windows with a `shown` field.
-- `main` has no `shown` and is skipped.
--
-- windows entry shape (satellites):
--   slots    = { fill = "<contentView>" }
--   shown    = "<selector>"        bool selector -> Show/Hide
--   position = {
--     default   = { x, y }        first-open TOPLEFT offset (y negative = top-down)
--     movable   = true
--     binding   = "<selector>"    (optional) { x, y } saved position
--     setAction = "<ACTIONS key>" (optional) dispatched on drag-stop
--   }
--
-- Lifecycle:
--   1. Satellite LayoutConfig files declare LC.windows.<name> at file-load.
--   2. HDG.Window:CreateAll() at OnEnable creates one frame per satellite.
--   3. Store subscriber reconciles visibility + position (interest-gated).

HDG = HDG or {}
HDG.Window = HDG.Window or {}
local W = HDG.Window

-- frames:       name -> Frame    (created once at CreateAll)
-- interestSets: name -> reads-closure (reconciler skips when invalidation misses)
-- subscribed:   bool
W._frames       = W._frames       or {}
W._interestSets = W._interestSets or {}
W._subscribed   = W._subscribed   or false

-- Iterate satellite windows (LC.windows entries with a `shown` field; `main` is skipped).
local function _eachSatellite(fn)
    local windows = HDG.LayoutConfig.windows or {}
    for name, win in pairs(windows) do
        if win.shown then fn(name, win) end
    end
end

-- ===== Frame creation ========================================================
function W:_CreateOne(name, win)
    -- parent: win.parent() for visibility cascade (e.g. companion -> HouseEditorFrame);
    -- falls back to UIParent when absent.
    local parent = (win.parent and win.parent()) or _G.UIParent
    local frame = CreateFrame("Frame", "HDGR_Window_" .. name, parent, "BackdropTemplate")

    -- MEDIUM strata; SetToplevel pops to front on click; SetClampedToScreen keeps on-screen.
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)

    -- Size from the composed window (fill-only -> the content view's dims).
    local state = HDG.Store:GetState()
    local w, h = HDG.Layout:ComposeWindowDimensions(HDG.LayoutConfig, name, state)
    frame:SetSize(w, h)

    -- Initial position from the entry default; the reconciler overrides it if
    -- a position binding has a saved value.
    local pos = win.position and win.position.default or { x = 200, y = -150 }
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", pos.x, pos.y)

    -- Drag wiring: WoW gives bottom-up GetLeft/GetTop; convert to top-down TOPLEFT y
    -- so the reconciler can restore position symmetrically.
    if not win.position or win.position.movable ~= false then  -- exception(boundary): win.position is SV-backed; movable absent = default-on
        frame:EnableMouse(true)
        frame:SetMovable(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self) self._isDragging = true; self:StartMoving() end)
        local setAction = win.position and win.position.setAction
        frame:SetScript("OnDragStop", function(self)
            self._isDragging = false
            self:StopMovingOrSizing()
            if not setAction then return end
            local left, top = self:GetLeft(), self:GetTop()
            -- GetLeft/GetTop are screen-absolute. Use UIParent:GetHeight() (not self's parent)
            -- so non-UIParent-parented satellites (companion) persist in the right space.
            local screenH = _G.UIParent:GetHeight()
            if left and top and screenH then
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS[setAction],
                    payload = { x = left, y = top - screenH },
                })
            end
        end)
    end

    -- Canvas (surface.sunken) so content panels float above it, matching the main window.
    HDG.Theme:Register(frame, "Canvas")

    -- Build the fill view (viewFilter scopes; main BuildAll uses excludeStandalone
    -- so views don't render twice). Same three-engine sequence as the main window.
    local fillView = win.slots and win.slots.fill
    local env = HDG.Environment._current
    HDG.Layout:BuildAll(frame, HDG.LayoutConfig, env, { viewFilter = fillView })
    HDG.Controllers:WireAll(frame)
    HDG.BindingEngine:Build(frame, HDG.LayoutConfig)

    -- Decorative window-frame overlay (Housing Decor Guide theme only) -- same
    -- pattern as the main window: a child frame above content; WindowFrameBorder
    -- shows + stamps chrome.windowBorder when the scheme declares it, else hides.
    HDG.UI.AttachWindowFrameBorder(frame)

    -- Interest set: shown + position binding + all widget read-closures.
    -- Reconciler short-circuits when invalidation doesn't intersect.
    local interest = HDG.Selectors:GetReads(win.shown)
    if win.position and win.position.binding then
        interest = HDG.Paths.Union(interest, HDG.Selectors:GetReads(win.position.binding))
    end
    if interest ~= "*" and frame.widgets then
        for _, widget in pairs(frame.widgets) do
            if widget._hdgrReadsClosure then
                interest = HDG.Paths.Union(interest, widget._hdgrReadsClosure)
                if interest == "*" then break end
            end
        end
    end
    self._interestSets[name] = interest

    frame:Hide()
    self._frames[name] = frame
    return frame
end

-- ===== Refresh (size + bind + compose/apply) ================================
function W:_RefreshOne(name, invalidation, actionType)
    local frame = self._frames[name]
    if not frame then return end
    if not frame:IsShown() then return end   -- hidden window needs no work
    local state = HDG.Store:GetState()
    local config = HDG.LayoutConfig
    invalidation = invalidation or "*"

    local w, h = HDG.Layout:ComposeWindowDimensions(config, name, state)
    frame:SetSize(w, h)

    -- BIND: push selector values to bound widgets.
    local fillView = config.windows[name].slots.fill
    -- actionType rides along for the same reason the main window forwards it:
    -- card grids read the action's retainsScroll through it. Without it every
    -- satellite re-push reset to the top -- the companion grid jumped on each
    -- placement no matter what the action declared (Discord 2026-09-06).
    local ctx = { frame = frame, invalidation = invalidation, view = fillView, state = state,
                  actionType = actionType }
    HDG.BindingEngine:Apply(frame, state, ctx, invalidation)

    -- LAYOUT: harvest intrinsics, compose, apply (pushes the widgets it reveals).
    HDG.Layout:LayoutWindow(frame, config, name, state)
end

-- ===== Reconcile (visibility + position, then refresh) ======================
function W:_ReconcileOne(name, invalidation, actionType)
    local win   = HDG.LayoutConfig.windows[name]
    local frame = self._frames[name]
    if not (win and frame) then return end
    local state = HDG.Store:GetState()

    -- Interest gate: nil invalidation = initial paint/force; bypass gate.
    local interest = self._interestSets[name]
    if invalidation and interest
       and not HDG.Paths.MatchesAny(interest, invalidation) then
        return
    end

    -- Visibility. HIDE_IN_COMBAT suppresses every satellite while in combat
    -- (the `shown` selector stays the SSoT; combat just gates the actual Show).
    -- Unlike the main window, this reconciler never defers in combat, so the
    -- Hide lands immediately on COMBAT_ENTER and restores on COMBAT_EXIT.
    local wasShown = frame:IsShown()
    local combatHide = state.session.combat.inLockdown == true
                       and HDG.Config:Get("HIDE_IN_COMBAT") == true
    local shouldShow = HDG.Selectors:Call(win.shown, state, {}) and not combatHide
    if shouldShow and not wasShown then
        -- Open transition: _RefreshOne skips a hidden window, so its shown widgets
        -- kept what they showed at close. Bind all of them with "*" in this pass,
        -- as the main window's open does; ShowForPipeline keeps their OnShow
        -- pushes silent so that pass paints each once.
        HDG.BindingEngine:ShowForPipeline(frame)
        invalidation = "*"
    elseif not shouldShow and wasShown then
        frame:Hide()
    end

    -- Position (optional persisted binding). Skip while the user is mid-drag so a periodic
    -- refresh (e.g. the lumber session ticker) can't yank the frame out from under the cursor.
    if win.position and win.position.binding and not frame._isDragging then
        local pos = HDG.Selectors:Call(win.position.binding, state, {})
        if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", pos.x, pos.y)
        end
    end

    if shouldShow then self:_RefreshOne(name, invalidation, actionType) end
end

-- ===== Boot (called from Init.lua OnEnable) ==================================
function W:CreateAll()
    _eachSatellite(function(name, win)
        -- Lazy satellites skipped here (parent frame LoadOnDemand, absent at OnEnable).
        -- Owning module calls EnsureCreated when the parent exists.
        if not win.lazy and not self._frames[name] then self:_CreateOne(name, win) end
    end)
    if not self._subscribed then
        self._subscribed = true
        HDG.Store:Subscribe(function(actionType, invalidation)
            -- Combat enter/exit flips the HIDE_IN_COMBAT visibility gate but doesn't
            -- touch any window's `shown` selector reads, so its invalidation wouldn't
            -- match a window's interest set. Force a full reconcile (nil bypasses the
            -- interest gate) so satellites hide on enter / restore on exit.
            local A = HDG.Constants.ACTIONS
            if actionType == A.COMBAT_ENTER or actionType == A.COMBAT_EXIT then
                invalidation = nil
            end
            for name in pairs(self._frames) do
                self:_ReconcileOne(name, invalidation, actionType)
            end
        end)
    end
    for name in pairs(self._frames) do
        self:_ReconcileOne(name, nil)
    end
end

-- Scheme / font-face change: re-measure and repaint every satellite whatever its
-- interest set (a nil invalidation bypasses the gate) -- none of them reads the
-- theme settings, so the reconcile subscriber skips them. Theme calls this after
-- rebuilding its fonts, so the repaint sees the new face and paint generation.
function W:RepaintAll()
    for name, frame in pairs(self._frames) do
        HDG.UI.RefreshIntrinsicWidths(frame)
        self:_ReconcileOne(name, nil)
    end
end

-- ===== Lazy creation (HouseEditorCompanion) =================================
-- Idempotent: returns the existing frame on second call.
-- CreateAll subscription reconciles the new frame on subsequent dispatches;
-- initial _ReconcileOne here paints it from current state immediately.
function W:EnsureCreated(name)
    local win = HDG.LayoutConfig.windows[name]
    if not (win and win.shown) then return nil end
    if self._frames[name] then return self._frames[name] end
    self:_CreateOne(name, win)
    self:_ReconcileOne(name, nil)
    return self._frames[name]
end

-- Test helpers.
function W:_GetFrame(name) return self._frames[name] end
