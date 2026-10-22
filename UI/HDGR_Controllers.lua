-- HDG.Controllers
--
-- Registry of UI controller modules. A controller binds widgets <-> state for
-- a single panel: it attaches event handlers (OnClick, OnTextChanged, ...)
-- and updates widget content from Store state. Controllers do NOT create or
-- position widgets -- the layout engine does that from spec data.
--
-- Each controller self-registers at file load:
--   HDG.Controllers:Register("stream", HDG.StreamController)
--
-- A frame wires the controllers its views list in LayoutConfig
-- (window.views.<view>.controllers) as it builds them, and the main window calls
-- :Refresh(rootFrame, ctx) on the ones its shown views list on every pass.
-- Standard contract:
--
--   controller:Wire(rootFrame)         -- attach event handlers
--   controller:Refresh(rootFrame, ctx) -- update content from state
--
-- ctx is the same shared table passed to every controller; conventional fields:
--   ctx.state          current Store state
--   ctx.mode           layout mode ("collapsed" | "expanded")
--   ctx.hasSelection   bool
--   ctx.set            currently selected set (or nil)
--   ctx.visible        bool (for the drawer in particular)
--   ctx.groupKey       currently selected group key (or nil)
--
-- Adding a new controller never touches MainFrame: self-register, and list it
-- in the `controllers` of the view(s) it wires.

HDG = HDG or {}
HDG.Controllers = HDG.Controllers or { byName = {}, ordered = {} }

local Controllers = HDG.Controllers

function Controllers:Register(name, controller)
    if type(name) ~= "string" or name == "" then return false end
    if type(controller) ~= "table" then return false end
    if not self.byName[name] then
        self.ordered[#self.ordered + 1] = name
    end
    self.byName[name] = controller
    return true
end

function Controllers:Each(fn)
    -- Iterate in registration order so behaviour wiring is deterministic.
    for _, name in ipairs(self.ordered) do
        local controller = self.byName[name]
        if controller then fn(name, controller) end
    end
end

-- The views a frame hosts: the views its built panels are placed in. The main
-- window hosts chrome, status, nav and the tabs visited so far; a floating
-- window, its fill.
local function _hostedViews(rootFrame, config)
    local hosted = {}
    for panelId in pairs(rootFrame.panels) do
        for view in pairs(config.panels[panelId].cell) do hosted[view] = true end
    end
    return hosted
end

-- Wire the controllers the frame's views list (LayoutConfig window.views.<v>.
-- controllers), each once, in registration order. Every controller used to be
-- wired onto every window, so a widget lookup had to pass over the widgets a
-- window does not hold; wired only where its views are, a controller's lookups
-- can be strict (UI.W). The main window builds each tab on its first visit and
-- calls this again then (HDG:EnsureMainWindowView): a controller already wired
-- is left alone, so only the ones the new tab brought wire. The frame keeps the
-- set; RefreshViews refreshes from it.
function Controllers:WireAll(rootFrame)
    local config = HDG.LayoutConfig
    local claimed = {}
    for view in pairs(_hostedViews(rootFrame, config)) do
        for _, name in ipairs(config.window.views[view].controllers) do
            if not self.byName[name] then
                error(("view %q lists controller %q, which is not registered"):format(view, name), 2)
            end
            claimed[name] = true
        end
    end
    local wired = rootFrame._hdgrControllers
    if not wired then   -- the frame's first wire
        wired = {}
        rootFrame._hdgrControllers = wired
    end
    for _, name in ipairs(self.ordered) do
        if claimed[name] and not wired[name] then
            self.byName[name]:Wire(rootFrame)
            wired[name] = true
        end
    end
end

-- Refresh, in registration order, the controllers the given views list: the
-- views the main window shows this pass. Every wired controller used to refresh
-- on every pass, so each Refresh that did work off its own tab had to check the
-- view itself (Layouts' detail read cost 5.2 MB over a first open on Decor
-- before it did). A listed controller the frame has not wired is a build bug:
-- the pass builds the views it shows before it refreshes them.
function Controllers:RefreshViews(rootFrame, ctx, views)
    local config = HDG.LayoutConfig
    local listed = {}
    for _, view in ipairs(views) do
        for _, name in ipairs(config.window.views[view].controllers) do listed[name] = true end
    end
    local wired = rootFrame._hdgrControllers
    for _, name in ipairs(self.ordered) do
        if listed[name] then
            if not wired[name] then
                error(("controller %q is listed by a shown view but not wired on this frame"):format(name), 2)
            end
            self.byName[name]:Refresh(rootFrame, ctx)
        end
    end
end
