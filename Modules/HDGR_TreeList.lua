-- HDG.TreeList
-- ============================================================================
-- Two-level expandable list backed by CreateScrollBoxListTreeListView. The
-- canonical use case: parent rows (vendor / category) that expand to reveal
-- child rows (items / decor). Framework owns the chevron + indent +
-- collapse state.
--
-- Public API (mirrors HDG.CardGrid + HDG.ChipStrip):
--   HDG.TreeList:Create(parent, cfg) -> scrollBox, scrollBar
--   HDG.TreeList:SetItems(scrollBox, rootNodes)
--   HDG.TreeList:Clear(scrollBox)
--   HDG.TreeList:RegisterCellKind(name, { template, initializer, height })
--
-- Root-node data shape (consumer-defined; constraints below):
--   {
--       kind = "<cellKindName>",
--       isCollapsed = bool,         -- initial state; can be reapplied per refresh
--       children = { childNode, ... },
--       ...consumer fields
--   }
--   Child nodes have the same shape but typically NO children (this module
--   targets the 2-level case -- Acquire-by-vendor, Recipes-by-profession,
--   etc.). Nested children are technically supported by TreeListView but
--   consumers should validate their own depth invariants (e.g. "vendors
--   can never be a child of another vendor" -- enforced in the selector
--   that produces the tree, not here).
--
-- Cell kind shape:
--   { template = "Button" | template-name, initializer = function(frame, node) end,
--     height = number }
--   The initializer gets the TreeNode (call :GetData() for user data,
--   :ToggleCollapsed() to expand/collapse, :IsCollapsed() to read).

HDG = HDG or {}
HDG.TreeList = HDG.TreeList or {}
local M = HDG.TreeList

M._cellKinds = M._cellKinds or {}

local C = HDG.Constants.STYLE.TREE_LIST
local DEFAULT_CFG = {
    indent     = C.INDENT,
    rowHeight  = C.ROW_HEIGHT,
    rowSpacing = C.ROW_SPACING,
    padTop     = 0,
    padBottom  = 0,
    padLeft    = 0,
    padRight   = 0,
}
M.DEFAULT_CFG = DEFAULT_CFG

-- ===== Cell kind registry =================================================
function M:RegisterCellKind(name, def)
    if not (name and def and def.template and def.initializer) then return end
    self._cellKinds[name] = {
        template    = def.template,
        initializer = def.initializer,
        height      = def.height,    -- optional per-kind override
    }
end

function M:GetCellKind(name) return self._cellKinds[name] end

-- ===== Build the scrollbox =================================================
function M:Create(parent, cfg)
    cfg = cfg or {}
    local merged = {}
    for k, v in pairs(DEFAULT_CFG) do merged[k] = v end
    for k, v in pairs(cfg) do merged[k] = v end

    -- fixedGutter: constant-width scrollbar gutter (no reclaim flap) -- for
    -- fixed-width surfaces like the sidebar nav. Default off (content treeLists
    -- want the reclaim). See CreateScrollBoxSkeleton.
    local host, scrollBox, scrollBar = HDG.UI:CreateScrollBoxSkeleton(parent, {
        fixedGutter = merged.fixedGutter,
        noScrollBar = merged.noScrollBar,
    })

    local view = CreateScrollBoxListTreeListView(
        merged.indent,
        merged.padTop, merged.padBottom, merged.padLeft, merged.padRight,
        merged.rowSpacing
    )
    view:SetElementExtent(merged.rowHeight)

    -- Element factory dispatches on node.data.kind -> registered cell kind.
    -- Each registered cell kind supplies a template + initializer; the
    -- framework calls factory(template, initFn) to materialize the row.
    view:SetElementFactory(function(factory, node)
        local data = node:GetData()
        local def  = M:GetCellKind(data.kind)
        if not def then
            error(("treeList: no cell kind registered for %q -- check the selector that built this tree"):format(tostring(data.kind)), 2)
        end
        factory(def.template, function(frame)
            def.initializer(frame, node)
        end)
    end)

    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    host._treeListCfg  = merged
    host._treeListView = view

    -- Optional SelectionBehaviorMixin. Intrusive flag stamps node.selected;
    -- TreeNodeMixin never uses that field (verified: Blizzard_SharedXML/TreeListDataProvider.lua)
    -- so no collision. Cell initializers read node.selected directly.
    if merged.selection and _G.ScrollUtil and _G.ScrollUtil.AddSelectionBehavior then
        local selOpts = type(merged.selection) == "table" and merged.selection or {}
        local Flags   = _G.SelectionBehaviorFlags or {}
        local flagArgs = { Flags.Intrusive }
        if selOpts.deselectable ~= false then flagArgs[#flagArgs+1] = Flags.Deselectable end  -- exception(optional): selOpts.deselectable absent = default-on (Blizzard SelectionBehavior opt)
        if selOpts.multi              then flagArgs[#flagArgs+1] = Flags.MultiSelect end
        host.selectionBehavior = _G.ScrollUtil.AddSelectionBehavior(scrollBox, unpack(flagArgs))

        if _G.SelectionBehaviorMixin and _G.SelectionBehaviorMixin.Event then
            host.selectionBehavior:RegisterCallback(
                _G.SelectionBehaviorMixin.Event.OnSelectionChanged,
                function(_, elementData, _selected)
                    HDG.UI._ReinitSelectionRow(scrollBox, elementData)
                end, host)
        end
    end

    -- Apply a Store-tracked selection. predicate receives the TreeNode wrapper
    -- (call node:GetData() inside). FindElementDataByPredicate respects
    -- ExcludeCollapsed -- collapsed items won't match unless parents are expanded.
    function host:SyncSelection(predicate)
        if not (self.selectionBehavior and self._treeListView and predicate) then return nil end
        -- Initial sync at Wire time runs BEFORE the binding pipeline pushes
        -- data into the view (the binding apply happens during the
        -- Refresh pass that follows controller wiring). FindElementDataByPredicate
        -- on a view with no data provider throws -- guard at this seam.
        if not self._treeListView:GetDataProvider() then return nil end
        local match = self._treeListView:FindElementDataByPredicate(predicate)
        if match then
            self.selectionBehavior:SelectElementData(match)
        else
            self.selectionBehavior:ClearSelections()
        end
        return match
    end

    -- Bind to a Store path: (a) re-sync on invalidation, (b) initial sync at
    -- wire time (tree may already be populated). Multiple callers OK -- last
    -- fired wins (mirrors click semantics: vendor click = npcID, item click = both).
    function host:WireStoreSelectionSync(statePath, matchFn)
        if not (self.selectionBehavior and statePath and matchFn) then return end
        local function read()
            local n = HDG.Store:GetState()
            for seg in statePath:gmatch("[^.]+") do
                n = n and n[seg]
                if n == nil then return nil end
            end
            return n
        end
        local function sync()
            local id = read()
            self:SyncSelection(function(node)
                local data = node and node.GetData and node:GetData()
                return data and matchFn(data, id) or false
            end)
        end
        self._selectionStoreToken = HDG.Store:Subscribe(function(_, invalidation)
            if HDG.Paths.MatchesAny({ statePath }, invalidation) then sync() end
        end)
        -- Re-sync after each M:SetItems rebuild: the behavior's internal
        -- pointer goes stale after a tree rebuild (gc'd nodes).
        self._afterSetItems = self._afterSetItems or {}
        self._afterSetItems[#self._afterSetItems + 1] = sync
        -- Initial sync intentionally deferred: data provider doesn't exist
        -- at Wire time; afterSetItems fires on the first M:SetItems.
    end

    return host, scrollBar
end

-- In-place update when the new tree has the live tree's shape: the same node
-- keys and kinds, with the same children, at every depth. The nav rebuilds its
-- nodes on every view switch only to move the highlight; replacing each node's
-- data and repainting the visible rows keeps the TreeNodes and their frames
-- (memory plan 2026-10-19 sec 6). A fold changes the shape -- a collapsed group
-- carries no children -- so it rebuilds, which also gives an expanded group its
-- children when the tree was built with it folded.
local NO_CHILDREN = {}

local function _sameShape(nodes, datas)
    if #nodes ~= #datas then return false end
    for i, node in ipairs(nodes) do
        local was, data = node:GetData(), datas[i]
        -- A node without a key can't be matched to its old self.
        if data.key == nil or was.key ~= data.key or was.kind ~= data.kind then return false end
        -- exception(optional): leaf nodes carry no children (module header).
        if not _sameShape(node:GetNodes(), data.children or NO_CHILDREN) then return false end
    end
    return true
end

local function _replaceData(nodes, datas)
    for i, node in ipairs(nodes) do
        local data = datas[i]
        node.data = data
        if (data.isCollapsed == true) ~= (node:IsCollapsed() == true) then
            node:SetCollapsed(data.isCollapsed == true)
        end
        _replaceData(node:GetNodes(), data.children or NO_CHILDREN)   -- exception(optional): leaf nodes carry no children
    end
end

local function _repaintFrame(frame, node)
    M:GetCellKind(node:GetData().kind).initializer(frame, node)
end

local function _applyInPlace(widget, newRoots)
    local provider = widget._scrollBox:GetDataProvider()
    -- exception(nullable): the first fill (or one after the window released its data) has no provider.
    if not provider or not _sameShape(provider:GetChildrenNodes(), newRoots) then return false end
    _replaceData(provider:GetChildrenNodes(), newRoots)
    widget._scrollBox:ForEachFrame(_repaintFrame)
    return true
end

local function _insertChildren(parentNode, children)
    if not children then return end
    for _, childData in ipairs(children) do
        local childNode = parentNode:Insert(childData)
        if childData.children and #childData.children > 0 then
            _insertChildren(childNode, childData.children)
        end
    end
end

-- Flatten rootNodes into a new TreeDataProvider; apply isCollapsed at insert time.
local function _rebuild(widget, rootNodes, opts)
    local provider = CreateTreeDataProvider()
    for _, rootData in ipairs(rootNodes or {}) do
        local node = provider:Insert(rootData)
        if rootData.isCollapsed then node:SetCollapsed(true) end
        _insertChildren(node, rootData.children)
    end
    local flag = opts.retainScroll
        and ScrollBoxConstants.RetainScrollPosition
        or  ScrollBoxConstants.DiscardScrollPosition
    widget._scrollBox:SetDataProvider(provider, flag)
    HDG.UI.RestoreListScroll(widget, widget._scrollBox)   -- refilled after the window closed
end

-- SetItems: update the live tree in place when the new one has its shape
-- (_applyInPlace), else rebuild. Design target is 2-level trees.
-- opts (or boolean retainScroll for legacy callers):
--   retainScroll = bool  -- RetainScrollPosition on a rebuild (default Discard)
function M:SetItems(widget, rootNodes, opts)
    -- Legacy: bool 3rd arg = retainScroll only.
    if type(opts) ~= "table" then opts = { retainScroll = opts == true } end
    if not _applyInPlace(widget, rootNodes) then _rebuild(widget, rootNodes, opts) end
    -- Post-population hooks, after either path (WireStoreSelectionSync; the nav's
    -- reveal of its active row, which moves on an in-place update too).
    -- per ADR-042: strict call, no pcall -- a failing hook is a real bug.
    if widget._afterSetItems then
        for _, fn in ipairs(widget._afterSetItems) do fn(widget) end
    end
end

function M:Clear(widget)
    widget._scrollBox:SetDataProvider(CreateTreeDataProvider())
end
