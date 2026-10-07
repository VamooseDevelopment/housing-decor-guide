-- HDG MainFrame
--
-- Shell. Owns the outer frame and orchestrates the layout pipeline:
--   1. Layout:BuildAll          -- spec-driven widget construction
--   2. Controllers:WireAll      -- attach event handlers to spec'd widgets
--   3. EventBus                 -- HDGR_STATE_CHANGED triggers Refresh
--   4. Refresh                  -- Layout:Compute -> Layout:Apply ->
--                                  Controllers:RefreshAll

HDG = HDG or {}

-- No log tag of its own: a pipeline stage error throws out of the Store
-- subscriber that runs RefreshMainWindow, and Store's _callSubscriber logs it
-- to the "error" rail before re-raising.

-- (VFN's GetSelectedSet / GetSetTitle helpers dropped -- HDG has no
-- libraries/sets concept. Tab-driven view selection is in PrepareContext.)

-- Combat-deferred first build. CreateMainWindow refuses to build in combat, so
-- the build waits for COMBAT_EXIT -- dispatched by CombatMiddleware on
-- PLAYER_REGEN_ENABLED, the same transition that replays the refreshes
-- RefreshMainWindow held. It builds only if the window is still wanted (opened
-- and closed again inside the fight builds nothing); the build ends with
-- RefreshMainWindow, which shows it. Every refused build in one fight shares one
-- subscriber, which removes itself at combat end.
local function _buildAfterCombat(self)
    if self._mainWindowBuildDeferred then return end
    local function onAction(actionType)
        if actionType ~= HDG.Constants.ACTIONS.COMBAT_EXIT then return end
        HDG.Store:Unsubscribe(onAction)
        self._mainWindowBuildDeferred = nil
        if HDG.Store:GetState().account.ui.mainWindowShown then
            self:CreateMainWindow()
        end
    end
    self._mainWindowBuildDeferred = true
    HDG.Store:Subscribe(onAction)
end

function HDG:CreateMainWindow()
    if self.mainFrame then return self.mainFrame end
    if not CreateFrame then return nil end   -- exception(boundary): no frame environment (headless)
    -- Never built in combat. SetPropagateKeyboardInput below is a restricted call
    -- (SimpleFrameAPI HasRestrictions; protected in combat for addon frames, Aegis
    -- TEST 147), and the window cannot show before combat ends anyway.
    if InCombatLockdown() then   -- exception(boundary): Blizzard combat lockdown; the build waits for COMBAT_EXIT
        _buildAfterCombat(self)
        return nil
    end

    local config = HDG.LayoutConfig
    local window = config.window
    local parent = _G and _G.UIParent or nil
    local frame = CreateFrame("Frame", "HDGR_MainFrame", parent, "BackdropTemplate")

    -- Frame strata (mirrors VDS_MainFrame): MEDIUM so HDG is a peer to the
    -- character sheet / housing editor / other addon windows -- it layers
    -- normally instead of always covering them. SetToplevel still pops HDG to
    -- the top of its strata on click for normal focus UX. SetClampedToScreen
    -- keeps it draggable but on-screen. boundary: Blizzard frame API.
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    -- Allow dragging well off-screen on left/right/bottom (500px) while the top edge stays
    -- clamped so the title bar is always grabbable. No saved position -> /reload re-centres.
    frame:SetClampRectInsets(500, -500, 0, 500)

    -- Initial size = the default view's natural dimensions (window composition,
    -- HDG-ADR-025: the window hugs its `fill` view). "auto" width/height resolve
    -- via GetViewDimensions. The first Refresh re-sizes to the active view via
    -- ComposeWindowDimensions.
    local w, h = HDG.Layout:GetViewDimensions(config, window.defaultView)
    frame:SetSize(w, h)
    frame:SetPoint("CENTER")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    -- Escape closes the window (HDG parity, HDG_VendorShoppingList.lua pattern).
    -- Dispatch MAIN_WINDOW_TOGGLE rather than Hide() so account.ui.mainWindowShown
    -- stays the SSoT -- a raw Hide() would desync and the FrameVisibility stage
    -- would re-show the window. SetPropagateKeyboardInput lets every non-Escape
    -- key fall through, so gameplay keybinds + editbox typing are unaffected (a
    -- focused EditBox consumes Escape itself, clearing focus before this fires).
    frame:EnableKeyboard(true)
    frame:SetPropagateKeyboardInput(true)
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MAIN_WINDOW_TOGGLE })
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- Canvas (surface.sunken) backdrop so the content panels (surface.panel)
    -- float above it + the inter-panel gap reads as a sunken seam (rule 1 of
    -- the surface ramp). The chrome/nav/status slots paint over their edges.
    HDG.Theme:Register(frame, "Canvas")
    frame:Hide()
    self.mainFrame = frame
    self:BuildMainWindow(frame)

    -- Decorative window-frame overlay (Housing Decor Guide theme only). A child
    -- frame ABOVE the content panels so the carved-wood border atlas draws over
    -- everything; the WindowFrameBorder Skinner shows + paints it when the active
    -- scheme declares chrome.windowBorder, and hides it on every other scheme.
    -- EnableMouse(false) so the full-cover overlay never intercepts content clicks.
    HDG.UI.AttachWindowFrameBorder(frame)

    -- Apply initial scale from account.config.scale (default 1.0). The
    -- account.config.scale subscriber below picks up runtime changes; this
    -- handles first-paint when the saved value differs from the factory default.
    local initialScale = HDG.Store:GetState().account.config.scale
    frame:SetScale(initialScale)   -- scale is seeded (NewConfig default 1.0)

    -- Subscribe to Store changes. Redux-style: every dispatch wakes us up
    -- and we re-derive from current state. Pipeline's FrameVisibility stage
    -- short-circuits the rest when the frame is hidden, so calling
    -- RefreshMainWindow on every action is cheap when the window is closed.
    --
    -- Receive the invalidation set as second arg and forward it
    -- to RefreshMainWindow. The Bind stage uses it to filter widget refreshes
    -- by which selectors actually read the changed state paths.
    HDG.Store:Subscribe(function(actionType, invalidation)
        HDG:RefreshMainWindow(invalidation, actionType)
    end)

    -- Scale subscriber: forward account.config.scale changes to MainFrame:SetScale.
    -- HDG-window-only scale (NOT the global UI scale CVar). Config tab's
    -- Appearance section dispatches CONFIG_SET { key="scale", value=N }; the
    -- generic UI_SET_PERSISTENT path doesn't carry the scale (config lives
    -- under account.config not account.ui). HDG.Paths.MatchesAny does prefix
    -- matching so "account.config.scale" matches "account.config" parent too.
    HDG.Store:Subscribe(function(_actionType, invalidation)
        if HDG.Paths.MatchesAny({"account.config.scale"}, invalidation) then
            local scale = HDG.Store:GetState().account.config.scale
            frame:SetScale(scale)
        end
    end)

    -- Auto-hide on combat (HIDE_IN_COMBAT): drop the main window the instant we
    -- enter combat so it isn't blocking the screen. FrameVisibility can't do this
    -- itself -- RefreshMainWindow DEFERS the whole pipeline while InCombatLockdown()
    -- is true, and PLAYER_REGEN_DISABLED fires with lockdown already active. Direct
    -- Hide() is taint-safe (HDG's UI carries no secure templates). Restoration needs
    -- no code here: COMBAT_EXIT runs RefreshMainWindow (lockdown clear) and
    -- FrameVisibility re-shows the frame from mainWindowShown -- the SSoT we never touched.
    HDG.Store:Subscribe(function(actionType)
        if actionType == HDG.Constants.ACTIONS.COMBAT_ENTER
           and HDG.Config:Get("HIDE_IN_COMBAT") == true
           and frame:IsShown() then
            frame:Hide()
        end
    end)

    return frame
end

function HDG:ToggleMainWindow()
    -- nil in combat (the first build waits for combat end). The toggle still
    -- dispatches, so that deferred build finds the window wanted.
    local frame = self.mainFrame or self:CreateMainWindow()
    -- SSoT: window shown-state lives in state.account.ui.mainWindowShown.
    -- Dispatching MAIN_WINDOW_TOGGLE flips it; the Store subscription
    -- triggers RefreshMainWindow, whose first stage (FrameVisibility) is
    -- the SOLE owner of Show/Hide reconciliation. Slash, minimap, and any
    -- future surface all converge on the same pipeline.
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MAIN_WINDOW_TOGGLE })
    return frame
end

function HDG:BuildMainWindow(parent)
    if not parent then return end

    -- 0. Validate the spec; loud failures are better than silent typos.
    local errors = HDG.Layout:Validate(HDG.LayoutConfig)
    if errors and #errors > 0 then
        HDG.Log:Notify("error", "LayoutConfig validation errors:")
        for _, msg in ipairs(errors) do HDG.Log:Notify("error", "  - " .. tostring(msg)) end
    end

    -- 1. Build the entire frame tree from LayoutConfig. Pass env so
    -- Theme:Register can extract env.scheme (per spec 9.2); seam for
    -- sub-tree previews without touching Theme.currentScheme.
    local env = HDG.Environment._current or nil
    -- excludeStandalone: skip panels whose cell map exclusively targets
    -- standalone views (e.g. lumberWindow). Those panels are built by
    -- HDG.Window into their own floating frame instead -- if we built
    -- them here too they'd render twice + steal click focus from the
    -- standalone window.
    HDG.Layout:BuildAll(parent, HDG.LayoutConfig, env, { excludeStandalone = true })

    -- 1a. Chrome/status slot-views: standalone so the main BuildAll skipped them.
    -- Build into the SAME frame; ComposeWindow positions via top/bottom slots.
    HDG.Layout:BuildAll(parent, HDG.LayoutConfig, env, { viewFilter = "chrome" })
    HDG.Layout:BuildAll(parent, HDG.LayoutConfig, env, { viewFilter = "status" })

    -- 1b. Sidebar nav: standalone treeList, skipped by main BuildAll.
    -- Build into the main frame; ComposeWindow places via slots.left = "nav".
    HDG.Layout:BuildAll(parent, HDG.LayoutConfig, env, { viewFilter = "nav" })

    -- 2. Wire the close button. Dispatches MAIN_WINDOW_TOGGLE (SSoT = mainWindowShown);
    --    a direct Hide() would desync and FrameVisibility would re-show the window.
    local closeButton = parent.widgets and parent.widgets["streamPanel.closeButton"]
    if closeButton and closeButton.SetScript then
        closeButton:SetScript("OnClick", function()
            HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MAIN_WINDOW_TOGGLE })
        end)
    end

    -- 3. Controllers wire behaviour to spec'd widgets.
    HDG.Controllers:WireAll(parent)

    -- 4. Tag bound widgets so the binding engine can push values during Refresh.
    HDG.BindingEngine:Build(parent, HDG.LayoutConfig)

    self:RefreshMainWindow()
end

-- ===== Pipeline stages per UI_WIDGET_TAXONOMY.md section 6 ================
-- Refresh is a sequential stage runner. Each stage receives a shared `ctx`
-- table; stages mutate ctx fields they own and read fields prior stages
-- populated. The runner walks PIPELINE_STAGES in declaration order; if any
-- stage's `predicate` returns false, that stage skips and the chain proceeds.

local PIPELINE_STAGES = {}

-- Predicate for stages that PAINT the main window. Runs only when the window is
-- visible AND the action isn't the MAIN_WINDOW_OPENING module-wake signal -- the open
-- transition's own pass already did the full catch-up repaint (FrameVisibility escalates
-- its invalidation to "*"), so MAIN_WINDOW_OPENING's pass is a no-op for the main window.
-- Collapses the prior two-full-pipeline-passes-per-open into one, and keeps all of
-- PrepareContext/ResizeFrame/Bind/ControllerRefresh/Layout off a hidden window.
local function _paintsMainWindow(ctx)
    return ctx.windowVisible
       and ctx.actionType ~= HDG.Constants.ACTIONS.MAIN_WINDOW_OPENING
end

-- Stage 0: FrameVisibility -- reconcile the main frame's Show/Hide with
-- state.account.ui.mainWindowShown (SSoT for whether the addon UI is open).
-- This replaces the standalone _ReconcileMainWindowVisibility helper so the
-- spec section 6 pipeline owns the Show/Hide transition. FrameVisibility always
-- runs (it publishes ctx.windowVisible); ALL the paint stages (PrepareContext /
-- ResizeFrame / Bind / ControllerRefresh / Layout) gate on _paintsMainWindow
-- (windowVisible + not the MAIN_WINDOW_OPENING signal). Rationale:
-- profiling a fresh login showed the pipeline ran ~126ms of Layout on a
-- HIDDEN window during the boot house-data flurry (16s before the window
-- opened). The old "cost is only the layout math, negligible at our scale"
-- assumption was false -- Layout is the #1 cost in the addon. This extends
-- Engine:Apply's per-widget hidden-skip (LATTICE ADR) up to the FRAME level
-- (a hidden frame's children still report IsShown()=true, so the per-widget
-- skip can't catch them). MAIN_WINDOW_OPENING invalidates "*" so the catch-up
-- paint on open is complete -- closes the ADR-documented "hidden-at-boot never
-- got first paint -> stale defaults" trap.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "FrameVisibility",
    run  = function(ctx)
        local frame = ctx.frame
        local s = HDG.Store:GetState()
        -- Main window visibility follows ONLY mainWindowShown. Shopping/Zone/
        -- Lumber are independent HDG.Window satellites (LC.windows entries) --
        -- the windows reconciler manages their Show/Hide via their `shown`
        -- selector, not this stage.
        local desired = s.account.ui.mainWindowShown == true
        local isShown = frame:IsShown()
        if desired and not isShown then
            -- Every bound widget's OnShow push stays silent for this Show: the "*"
            -- Bind below paints all of them once (see Engine:ShowForPipeline).
            HDG.BindingEngine:ShowForPipeline(frame)
            -- Widgets are born hidden and Layout below is what shows the active
            -- view's, pushing each bound one as it reveals it (PushIfStale).
            -- Anything else a stage skipped because its widget was still hidden (a
            -- controller's imperative paint) is caught by one coalesced wildcard
            -- pass next frame.
            HDG:RequestReflow()
            -- Open transition: THIS pass does the full catch-up repaint. Escalate the
            -- narrow MAIN_WINDOW_TOGGLE invalidation ({mainWindowShown}) to "*" so Bind
            -- paints everything now. MAIN_WINDOW_OPENING below is then purely a module-wake
            -- signal -- its own pipeline pass is skipped by _paintsMainWindow, so opening
            -- costs ONE full pass instead of two.
            ctx.invalidation = "*"
            -- Gated modules (CollectionReconciler, BagObserver, etc.) slept while the
            -- addon was closed. Dispatch a single MAIN_WINDOW_OPENING so they catch up
            -- via Subscribe (they react to actionType, not invalidation).
            HDG.Store:Dispatch({
                type = HDG.Constants.ACTIONS.MAIN_WINDOW_OPENING,
            })
        elseif not desired and isShown then
            frame:Hide()
        end
        -- Publish post-reconcile visibility so Bind/Layout can skip when the
        -- window is hidden (frame-level extension of Engine:Apply's per-widget
        -- hidden-skip). Read AFTER the Show/Hide above so it reflects the
        -- just-applied desired state, not the pre-reconcile state.
        ctx.windowVisible = frame:IsShown()
    end,
}

-- Stage 1: PrepareContext -- derive active view from state.account.ui.view
-- (HDG's tab model: each tab is a view; user clicks tab -> dispatch sets
-- state.account.ui.view -> Refresh sees the new view here). Falls back to
-- the LayoutConfig's defaultView when state is unset or names a missing view.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "PrepareContext",
    predicate = _paintsMainWindow,   -- don't derive view / size a hidden window
    run  = function(ctx)
        local config = HDG.LayoutConfig
        local state  = HDG.Store:GetState()

        local activeView = state.account.ui.view
        if not (activeView and config.window.views[activeView]) then
            activeView = config.window.defaultView
        end
        -- Shopping and Zone are now independent HDG.Window floating frames.
        -- No view-override needed here; the main window always shows the
        -- user's saved tab (activeView). Both standalone views are flagged
        -- standalone=true so BuildAll(excludeStandalone=true) skips them.

        ctx.config     = config
        ctx.state      = state
        ctx.view       = activeView
        ctx.viewSpec   = config.window.views[activeView]
        -- Window size = the active view's natural dimensions. Window
        -- composition (HDG-ADR-025): the `main` window hugs its `fill` view,
        -- no nav strip added (nav returns as a `left` slot in step 4).
        -- ComposeWindowDimensions resolves the @view fill -> GetViewDimensions,
        -- so "auto" width/height are handled uniformly.
        ctx.targetWidth, ctx.targetHeight =
            HDG.Layout:ComposeWindowDimensions(config, "main", state)
    end,
}

-- Stage 2: ResizeFrame -- apply target size + preserve top-left. Separated
-- from LAYOUT so the frame has its final dimensions before any layout pass.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "ResizeFrame",
    predicate = _paintsMainWindow,   -- don't resize a hidden window (also keeps targetW/H paired with PrepareContext)
    run  = function(ctx)
        local frame = ctx.frame
        local preservedL, preservedT
        if frame.GetLeft and frame.GetTop then
            preservedL, preservedT = frame:GetLeft(), frame:GetTop()
        end
        frame:SetSize(ctx.targetWidth, ctx.targetHeight)
        if preservedL and preservedT and frame.ClearAllPoints and frame.SetPoint and _G.UIParent then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", preservedL, preservedT)
        end
    end,
}

-- Stage 3: BIND -- BindingEngine pushes state values into bound widgets.
-- Must run BEFORE LAYOUT so intrinsics reflect current state, not last frame.
-- Forward ctx.invalidation so BindingEngine filters widgets by
-- which selectors read the changed state paths (selective re-render).
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "Bind",
    -- Gate on window visibility (ctx.windowVisible, set by FrameVisibility):
    -- a hidden frame's child widgets still report IsShown()=true (own flag),
    -- so Engine:Apply's per-widget skip can't catch them. The frame-level gate
    -- is the only place that skips Bind for a closed window.
    predicate = _paintsMainWindow,   -- strict: BindingEngine is load-order-guaranteed
    run = function(ctx)
        HDG.BindingEngine:Apply(ctx.frame, ctx.state, ctx, ctx.invalidation)
    end,
}

-- Stage 3b: NavBind -- REMOVED with the navRegion (HDG-ADR-025 step 2). It
-- re-applied selected/childActive bindings to the hand-rolled nav scrollChild.
-- When nav returns as a `left` slot (step 4) it composes through the normal
-- Bind stage on the main frame -- no dedicated nav-bind stage needed.

-- Stage 4: HeaderText -- header titles aren't bound via BindingEngine; they
-- update from selection state directly.
-- (VFN's HeaderText stage dropped -- it wrote a set title into a panel
-- header. HDG has no equivalent; widget text flows through bindings.)

-- Stage 5: CONTROLLER_REFRESH -- imperative side effects (pin painting,
-- map drawer canvas, etc.) that can't be expressed declaratively. Runs
-- BEFORE Layout per spec section 6: visibility is now declarative (the
-- `visible` field on widget specs, resolved by Layout:Compute), so
-- controllers no longer need to win Show/Hide races against Layout.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "ControllerRefresh",
    -- Skip for LOG_PUSH: a log append repaints the status rail via Bind, but
    -- triggers no imperative controller side effects + moves nothing (perf).
    predicate = function(ctx)
        return _paintsMainWindow(ctx)
           and HDG.Controllers.RefreshAll
           and ctx.actionType ~= HDG.Constants.ACTIONS.LOG_PUSH
    end,
    run = function(ctx)
        HDG.Controllers:RefreshAll(ctx.frame, ctx)
    end,
}

-- Stage 6: LAYOUT -- harvest intrinsics (now reflecting BIND-stage values),
-- compute placements (with declarative visibility resolution), apply to widgets.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "Layout",
    -- Skip the placement walk for LOG_PUSH -- a log append changes no widget
    -- size/visibility, so layout is unchanged (perf: a standalone LOG_PUSH was a
    -- full layout pass for nothing). The status rail still repaints via Bind.
    -- Skip it too when the dispatch touches nothing the composed views' layout
    -- reads (visibility selectors, dynamic tracks, auto-sized bindings): the
    -- same reads gate the satellite windows have always had.
    predicate = function(ctx)
        if not (_paintsMainWindow(ctx) and HDG.Layout ~= nil
                and ctx.actionType ~= HDG.Constants.ACTIONS.LOG_PUSH) then
            return false
        end
        if ctx.invalidation == "*" then return true end
        local interest = HDG.Layout:WindowInterest(ctx.config, "main", ctx.state)
        return HDG.Paths.MatchesAny(interest, ctx.invalidation)
    end,
    run = function(ctx)
        -- Compose the `main` window from its slot map (HDG-ADR-025): the @view
        -- fill (= ctx.view) plus the edge slots. state enables `visible` selector
        -- resolution; intrinsics carry "auto"-sized widget extents. Apply pushes
        -- every bound widget it reveals stale, so a view switch paints the new
        -- view in this pass.
        HDG.Layout:LayoutWindow(ctx.frame, ctx.config, "main", ctx.state)
    end,
}

-- Stage 6b: NAV_REVEAL -- keep the current destination on screen. The sidebar is
-- sized to the active view's body height, so switching to a shorter view can cut
-- the tree above the row the user just clicked (Move Planner: 19 rows fit, it is
-- row 21). Runs AFTER Layout because Apply sizes the nav scrollbox there, and
-- ScrollBox:OnSizeChanged runs a synchronous FullUpdate -- so the visible extent
-- the reveal math reads is already the NEW one. No-op unless a nav.tree rebuild
-- marked it pending.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "NavReveal",
    predicate = _paintsMainWindow,
    run = function(ctx)
        HDG.NavController:RevealActive(ctx.frame)
    end,
}

-- Stage 6c: SELECTION_REVEAL -- scroll a Store-selected row into view, for every
-- WireStoreSelectionSync list (vendor / item / recipe / decor / material lists).
-- Same two-phase shape as NavReveal: the selection sync runs in Bind (SetItems)
-- or from a Store subscriber, both before Layout has sized the list, so it only
-- queues; this flushes against the final extent. This is the same-frame fast
-- path -- the queue also drains itself next frame (UI.QueueSelectionReveal), so a
-- pass that skips this stage (combat, MAIN_WINDOW_OPENING, subscriber order)
-- cannot leave a reveal behind. Skips LOG_PUSH like Layout does: nothing was laid
-- out on that pass. A vendor jumped to from the zone scanner, the shopping list
-- or a decor source landed highlighted but off screen (ReganB, Discord 2026-09-11).
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "SelectionReveal",
    predicate = function(ctx)
        return _paintsMainWindow(ctx)
           and ctx.actionType ~= HDG.Constants.ACTIONS.LOG_PUSH
    end,
    run = function(_ctx)
        HDG.UI.FlushSelectionReveals()
    end,
}

-- Stage 7: THEME -- terminal paint stage per spec section 6. Paint is
-- event-driven today (Theme:Register at build, Theme:SetState during Bind),
-- so this stage is a documented no-op until a paint-dirty queue exists.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "Theme",
    predicate = function() return false end,
    run = function(_ctx) end,
}

-- Pipeline runner. Iterates stages in spec section 6 order. Each stage is
-- pcall-wrapped per spec audit finding C2 so a crash in (e.g.) Bind doesn't
-- silently skip Layout / ControllerRefresh and leave the UI half-refreshed.
--
-- `invalidation` is threaded into ctx so the Bind stage can
-- forward it to BindingEngine:Apply for selective widget refresh.
local function runPipeline(frame, invalidation, actionType)
    -- actionType propagated through ctx so per-widget dispatchers (Bind
    -- stage) can read HDG.Store._actionMeta[actionType] for scroll-retain
    -- decisions etc. -- the action that triggered the refresh is the only
    -- reliable signal for "is this a same-dataset tweak or a dataset
    -- swap?"
    local ctx = { frame = frame, invalidation = invalidation or "*",
                  actionType = actionType }
    -- Perf: time each stage so we SEE which one owns the pipeline cost (Layout
    -- vs ControllerRefresh vs Bind) instead of inferring it. One boolean when off.
    local perf  = HDG.Perf
    local timed = perf and perf:Enabled()
    for _, stage in ipairs(PIPELINE_STAGES) do
        if not stage.predicate or stage.predicate(ctx) then
            local t0, k0
            if timed then t0, k0 = perf:Open() end
            -- Strict call (ADR-042): the per-stage pcall was the isolation
            -- class -- a Bind-stage throw used to leave LATER stages running
            -- on a half-bound frame (deterministic-but-wrong paint). A throw
            -- now aborts the pipeline. RefreshMainWindow is mostly reached from a
            -- Store subscriber, outside ErrorBoundary; there Store's
            -- _callSubscriber logs the throw before re-raising it.
            stage.run(ctx)
            if timed then perf:RecordStage(stage.name, t0, k0) end
        end
    end
end

-- Combat-deferral helpers for RefreshMainWindow.
--
-- SetSize / SetPoint / Show / Hide on UIParent-parented frames can taint
-- if any descendant uses a secure template. Combat-time refreshes queue
-- here and replay on COMBAT_EXIT rather than landing mid-combat. Per
-- spec section 15.7, PLAYER_REGEN_* are owned by CombatMiddleware;
-- modules observe state.session.combat transitions via Store:Subscribe.

-- Merge `invalidation` into self._pendingRefresh. "*" sticks; unique paths
-- accumulate deduped. Replays as a path union on COMBAT_EXIT (not "*" --
-- a full wildcard replay rebuilds every binding + scrollbox, even cold ones).
local function _accumulatePendingRefresh(self, invalidation)
    if self._pendingRefresh == "*" then return end                  -- already wildcard
    if invalidation == "*" or invalidation == nil then
        self._pendingRefresh = "*"
        return
    end
    if type(invalidation) ~= "table" then return end
    self._pendingRefresh   = self._pendingRefresh   or {}
    self._pendingPathsSeen = self._pendingPathsSeen or {}
    for _, path in ipairs(invalidation) do
        if not self._pendingPathsSeen[path] then
            self._pendingPathsSeen[path] = true
            self._pendingRefresh[#self._pendingRefresh + 1] = path
        end
    end
end

-- Fold any combat-deferred pending set into THIS refresh's invalidation, then clear it.
-- Combat-queued refreshes thus replay on the FIRST non-combat refresh (the
-- CombatMiddleware-dispatched COMBAT_EXIT) in its own single pipeline pass -- this
-- replaces a dedicated COMBAT_EXIT subscriber that both double-ran the pipeline (one
-- pass for COMBAT_EXIT's own narrow invalidation + one for the replay) AND never
-- unsubscribed. "*" on either side wins; otherwise union the deduped path lists.
local function _drainPendingInto(self, invalidation)
    local pending = self._pendingRefresh
    if not pending then return invalidation end
    self._pendingRefresh   = nil
    self._pendingPathsSeen  = nil
    if pending == "*" or invalidation == "*" or invalidation == nil then return "*" end
    if type(pending) ~= "table" then return invalidation end
    local seen, out = {}, {}
    if type(invalidation) == "table" then
        for _, p in ipairs(invalidation) do if not seen[p] then seen[p] = true; out[#out + 1] = p end end
    end
    for _, p in ipairs(pending) do if not seen[p] then seen[p] = true; out[#out + 1] = p end end
    return out
end

function HDG:RefreshMainWindow(invalidation, actionType)
    local frame = self.mainFrame
    if not frame or not HDG.Layout then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        _accumulatePendingRefresh(self, invalidation)
        return   -- replays on the first non-combat refresh (COMBAT_EXIT) via _drainPendingInto
    end
    -- Fold any combat-deferred pending set into THIS pass -> one catch-up pipeline pass.
    invalidation = _drainPendingInto(self, invalidation)
    runPipeline(frame, invalidation, actionType)
end

-- Coalesced, one-frame-deferred re-solve. The BindingEngine's Phase-0 hidden-skip
-- means a freshly-revealed AUTO-WIDTH widget is skipped during Bind, so the solve
-- runs with no intrinsic and getAlong flexes it to fill its row; the OnShow hook
-- then measures it correctly but AFTER the solve, with nothing re-solving (Decor
-- source-tag buttons over-expanding on first paint, fixed only on re-render).
-- RunNextFrame defers past the in-flight Apply (no re-entrancy) and the flag
-- coalesces N revealed widgets into ONE re-solve; next frame the widgets are
-- already shown so it fires no new OnShow -> no loop. Mirrors the companion's
-- RunNextFrame "let it settle" pattern.
function HDG:RequestReflow()
    if self._reflowScheduled then return end
    if not _G.RunNextFrame then return end   -- exception(boundary): pre-12.0 / headless mock
    self._reflowScheduled = true
    _G.RunNextFrame(function()
        self._reflowScheduled = false
        self:RefreshMainWindow("*")
    end)
end
