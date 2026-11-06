-- HDG.Selectors -- Status / Log / Config / Chrome
-- ============================================================================
-- Cross-cutting selectors:
--   status.current  -- bottom-of-window status rail entry
--   log.*           -- structured logging surface
--   config.*        -- settings tab + slash-command queries
--   chrome.*        -- tab strip active state + sidebar nav tree

HDG = HDG or {}
local Selectors = HDG.Selectors

-- ============================================================================
-- Status rail + log selectors
-- ============================================================================
-- Status rail: most-recent user-visible log entry still within its duration window.
-- Widget polls duration check via OnUpdate; no state dispatch needed for dismissal.

Selectors:Register("status.current", {
    reads = {"session.log.entries"},
    fn = function(state, ctx)
        local entries = state.session.log.entries
        if not entries then return nil end
        local now = _G.GetTime()  -- exception(boundary): wall-clock for duration-based dismissal
        -- Walk newest-first: first user-visible entry is THE candidate;
        -- show if within duration, otherwise show nothing.
        for i = #entries, 1, -1 do
            local e = entries[i]
            local tagDef = HDG.Log:GetTag(e.tag)
            if tagDef and tagDef.user then
                if not e.duration or (now - (e.timestamp or 0)) < e.duration then
                    return e
                end
                return nil
            end
        end
        return nil
    end,
})

-- Filtered log entries for the debug tab (200-entry ring buffer at most).
local LEVEL_RANK = { debug = 1, info = 2, warn = 3, error = 4, success = 2 }

local function passesLevelFilter(entry, levelFilter)
    if not levelFilter or levelFilter == "all" then return true end
    -- "warn+" means warn or higher; same pattern for other levels
    local plus = levelFilter:match("^(%a+)%+$")
    if plus then
        local minRank = LEVEL_RANK[plus] or 1  -- exception(boundary): unknown level defaults to 1
        local entryRank = LEVEL_RANK[entry.level] or 1  -- exception(boundary): unknown level defaults to 1
        return entryRank >= minRank
    end
    return entry.level == levelFilter
end

Selectors:Register("log.filteredEntries", {
    reads = {"session.log.entries", "session.log.tabFilter"},
    fn = function(state, ctx)
        local log = state.session.log
        if not log.entries then return {} end
        local filter = log.tabFilter or {}
        local tagF = filter.tag
        local lvlF = filter.level
        local out = {}
        for _, e in ipairs(log.entries) do
            local tagOK = (not tagF or tagF == "all" or e.tag == tagF)
            local lvlOK = passesLevelFilter(e, lvlF)
            if tagOK and lvlOK then out[#out + 1] = e end
        end
        return out
    end,
})

-- Formatted text for the debug tab's scrollingTextBox. One line per entry.
-- reads = {} required so the transitive closure walks `calls` instead of
-- short-circuiting to "*" (which would defeat selective Apply).
Selectors:Register("log.formattedText", {
    reads = {},  -- pure: Format.LogLine uses the fixed level palette (no Theme)
    calls = {"log.filteredEntries"},
    fn = function(state, ctx)
        local entries = Selectors:Call("log.filteredEntries", state, ctx)
        local lines = {}
        for _, e in ipairs(entries) do
            local ts = e.timestamp or 0  -- migration (legacy log entries may lack ts)
            local hh = math.floor(ts / 3600) % 24
            local mm = math.floor(ts / 60) % 60
            local ss = ts % 60
            -- Muted timestamp + Format.LogLine; same shape as chat so both surfaces stay in sync.
            lines[#lines + 1] = string.format("|cff666666%02d:%02d:%06.3f|r ", hh, mm, ss)
                .. HDG.Format.LogLine(e)
        end
        return table.concat(lines, "\n")
    end,
})

Selectors:Register("log.entryCount", {
    calls = {"log.filteredEntries"},
    reads = {"session.log.entries"},
    fn = function(state, ctx)
        local matched = #(Selectors:Call("log.filteredEntries", state, ctx))
        local total   = #state.session.log.entries
        if matched == total then
            return string.format("%d entries", total)
        end
        return string.format("%d of %d entries", matched, total)
    end,
})

-- Debug tab filter state (tabFilter always set by NewLog / LOG_SET_FILTER; strict reads).
Selectors:Register("log.filterTag", {
    reads = {"session.log.tabFilter"},
    fn = function(state, ctx)
        return state.session.log.tabFilter.tag
    end,
})
Selectors:Register("log.filterLevel", {
    reads = {"session.log.tabFilter"},
    fn = function(state, ctx)
        return state.session.log.tabFilter.level
    end,
})
Selectors:Register("log.filterAutoScroll", {
    reads = {"session.log.tabFilter"},
    fn = function(state, ctx)
        return state.session.log.tabFilter.autoScroll
    end,
})

-- Tag menu items not memoized: late modules may add tags after boot.
Selectors:Register("log.tagMenuItems", {
    reads = {},
    fn = function(state, ctx)
        local out = { { value = "all", text = "All tags" } }
        local names = {}
        for name in pairs(HDG.Log.TAGS) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            out[#out + 1] = { value = name, text = name }
        end
        return out
    end,
})
Selectors:Register("log.levelMenuItems", {
    reads    = {},
    memoized = true,
    fn = function(state, ctx)
        return {
            { value = "all",     text = "All levels"  },
            { value = "info+",   text = "Info or higher"  },
            { value = "warn+",   text = "Warn or higher"  },
            { value = "error+",  text = "Errors only"     },
            { value = "debug",   text = "Debug only"      },
            { value = "info",    text = "Info only"       },
            { value = "warn",    text = "Warn only"       },
            { value = "error",   text = "Error only"      },
            { value = "success", text = "Success only"    },
        }
    end,
})

-- ============================================================================
-- Config tab selectors
-- ============================================================================

Selectors:Register("config.debug", {
    reads = {"account.config.debug"},
    fn = function(state, ctx)
        return state.account.config.debug == true
    end,
})


Selectors:Register("config.theme", {
    reads = {"account.config.scheme"},
    fn = function(state, ctx)
        return state.account.config.scheme
    end,
})

-- Theme decorations checkbox (Config > Appearance, under the theme picker).
Selectors:Register("config.themeDecorations", {
    reads = {"account.config.themeDecorations"},
    fn = function(state)
        return state.account.config.themeDecorations
    end,
})

-- The Winter Veil theme offer (UI/HDGR_Controller_WinterVeilOffer.lua): the start
-- year of the Feast of Winter Veil to offer the theme for now, or nil -- the main
-- window is closed (the offer comes with opening it, never at login), none is on,
-- this profile already answered this one, or it is already on the theme.
Selectors:Register("holiday.winterVeilOfferDue", {
    reads = {"account.ui.mainWindowShown", "session.holiday.winterVeil",
             "account.config.winterVeilOffered", "account.config.scheme"},
    fn = function(state)
        local year, config = state.session.holiday.winterVeil, state.account.config
        if not state.account.ui.mainWindowShown or year == 0
            or config.winterVeilOffered == year or config.scheme == "WinterVeil" then
            return nil  -- exception(nullable): no offer due is the usual answer
        end
        return year
    end,
})

-- (Font picker lives in Blizzard Settings -> Advanced, wired via BindSetting -- no
-- selector needed. The font face itself is resolved in Theme:BuildFontObjects from
-- account.config.fontFamily.)

-- Decor 3D-preview background picker (config-theme dropdown pattern). current =
-- the chosen atlas name, or "default" = the dark bgTile backdrop (no atlas override).
Selectors:Register("decor.previewBg", {
    reads = {"account.config.decorPreviewBg"},
    fn = function(state, ctx)
        return state.account.config.decorPreviewBg
    end,
})
Selectors:Register("decor.previewBgMenuItems", {
    reads = {},
    fn = function(state, ctx)
        return {
            { value = "default",                                text = "Default" },
            { value = "black",                                  text = "Black" },
            { value = "logo",                                   text = "Madailein" },
            { value = "housing-basic-panel--stone-background",   text = "Stone" },
            { value = "housing-dashboard-bg-empty",              text = "Welcome" },
            { value = "housing-dashboard-bg-durotar",            text = "Durotar" },
            { value = "housing-dashboard-bg-elwynn",             text = "Elwynn" },
            { value = "house-drawing-stone-bg",                  text = "Sketch" },
        }
    end,
})

-- Scale as formatted string for the label widget.
-- HDGR_MainFrame.lua subscriber forwards account.config.scale -> frame SetScale.
Selectors:Register("config.scale", {
    reads = {"account.config.scale"},
    fn = function(state)
        return string.format("%.1f", state.account.config.scale)
    end,
})

-- (config.themeLabel retired: kind="dropdown" auto-renders selected radio's text.)

-- Theme menu items from HDGR_SchemeMeta.order.
Selectors:Register("config.themeMenuItems", {
    reads = {"session.resolvers.staticData.tick"},
    fn = function(state, ctx)
        local meta = HDG.StaticData.Schemes:GetMeta()
        local out = {}
        if not meta or not meta.order then return out end
        -- Featured: the "Housing Decor Guide" theme renders in its own signature
        -- gold so it stands out as the addon's namesake. The gold is the Housing
        -- scheme's OWN accent (a fixed brand cue here -- NOT the active scheme's
        -- accent, which would change as you preview other themes). nullable: if
        -- the scheme is somehow absent we just skip the tint (never crash the picker).
        local FEATURED = "Housing"
        local goldCode
        local housing = HDG.StaticData.Schemes:Get(FEATURED)
        if housing then
            local a = housing.semantic.accent
            goldCode = ("|cff%02x%02x%02x"):format(
                math.floor(a.r * 255 + 0.5), math.floor(a.g * 255 + 0.5), math.floor(a.b * 255 + 0.5))
        end
        for _, name in ipairs(meta.order) do
            local label = meta.labels and meta.labels[name] or name
            if name == FEATURED and goldCode then
                label = goldCode .. label .. "|r"
            end
            out[#out + 1] = { value = name, text = label }
        end
        return out
    end,
})



-- ============================================================================
-- Chrome (tab strip) selectors
-- ============================================================================

Selectors:Register("chrome.activeTab", {
    reads = {"account.ui.view"},
    fn = function(state, ctx)
        local v = state.account.ui.view
        if v and HDG.LayoutConfig.window.views[v] then return v end
        return HDG.LayoutConfig.window.defaultView or "decor"
    end,
})

-- A character's name as the cross-character hovers show it: with the realm when
-- another of your characters has the same name (owner ruling 2026-10-31), so two
-- Alices read Alice-Proudmoore and Alice-Stormrage. Counted over the whole account,
-- so a name reads the same in every hover, whoever holds the item.
local function _nameCounts(characters)
    local counts = {}
    for _, c in pairs(characters) do
        if c.name then counts[c.name] = (counts[c.name] or 0) + 1 end  -- exception(nullable): legacy record may predate name capture
    end
    return counts
end

local function _shownName(charKey, c, nameCounts)
    if not c.name then return charKey end   -- exception(nullable): legacy record may predate name capture
    if nameCounts[c.name] > 1 then return charKey end   -- charKey is Name-Realm
    return c.name
end

-- Essence of Lumber tracker (chrome badge + cross-character hover). Sums the
-- per-char snapshots into an account-wide total -- soulbound means it can't be
-- pooled, so the whole-warband number is the useful glance. perChar is sorted
-- count-desc for the hover; the current char is flagged (its snapshot is live,
-- alts are last-login). Snapshots land via Modules/HDGR_EssenceObserver.lua.
-- Deliberately ignores char.hidden: the Alts eye means "keep this char out of
-- my professions grid", not "exclude it from account-wide totals" -- filtering
-- on it here silently under-counted essence for anyone who hides junk alts.
Selectors:Register("chrome.essenceBadge", {
    reads = {"account.characters", "session.identity.charKey"},
    fn = function(state, ctx)
        local current = state.session.identity.charKey
        local nameCounts = _nameCounts(state.account.characters)
        local total, perChar = 0, {}
        for charKey, c in pairs(state.account.characters) do
            local stock = c.essenceStock   -- exception(nullable): unset until this char is first scanned
            local count = stock and (stock.bag + stock.bank) or 0
            if count > 0 then
                total = total + count
                perChar[#perChar + 1] = {
                    name      = _shownName(charKey, c, nameCounts),
                    classFile = c.classFile,
                    count     = count,
                    bag       = stock.bag,
                    bank      = stock.bank,
                    isCurrent = charKey == current,
                    lastSeen  = c.lastSeen or 0,
                }
            end
        end
        table.sort(perChar, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.name < b.name
        end)
        return { total = total, owned = total > 0, perChar = perChar }
    end,
})

-- ============================================================================
-- Cross-character decor reagent stock
-- ============================================================================
-- Folds every character's persisted reagentStock into one itemID -> roster map.
-- A MAP rather than a per-item lookup because `memoized` caches a single value
-- and ignores ctx (see Selectors:Call) -- a ctx-keyed variant could not memoize
-- and would rebuild on every tooltip hover.
--
-- Deliberately ignores char.hidden, the same ruling chrome.essenceBadge carries:
-- the Alts eye means "keep this char out of my professions grid", not "exclude
-- it from account-wide totals".
--
-- Warband is absent by construction -- it is a shared stash read live from
-- BagObserver at the render site, and a selector must not call a Blizzard API.

-- One character's contribution to the map: fold its bag + bank maps into `acc`.
local function _foldCharacterStock(acc, charKey, c, currentKey, shownName)
    local stock = c.reagentStock   -- exception(nullable): unset until this char is first swept
    if not stock then return end
    local perItem = {}
    for itemID, n in pairs(stock.bag or {}) do    -- exception(nullable): bag map absent until the first bag sweep
        perItem[itemID] = (perItem[itemID] or 0) + n
    end
    for itemID, n in pairs(stock.bank or {}) do   -- exception(nullable): bank map absent until the bank is first opened
        perItem[itemID] = (perItem[itemID] or 0) + n
    end
    for itemID, count in pairs(perItem) do
        local e = acc[itemID] or { total = 0, perChar = {} }
        e.total = e.total + count
        e.perChar[#e.perChar + 1] = {
            charKey   = charKey,             -- who this is: two realms can each have an Alice
            name      = shownName,
            classFile = c.classFile,
            count     = count,
            bag       = (stock.bag and stock.bag[itemID]) or 0,
            bank      = (stock.bank and stock.bank[itemID]) or 0,
            bagAt     = stock.bagAt,
            bankAt    = stock.bankAt,
            isCurrent = charKey == currentKey,
        }
        acc[itemID] = e
    end
end

-- Current character first (its numbers are live), then count-desc, then name.
local function _rosterOrder(a, b)
    if a.isCurrent ~= b.isCurrent then return a.isCurrent end
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
end

Selectors:Register("characters.reagentStock", {
    reads    = {"account.characters", "session.identity.charKey"},
    memoized = true,
    fn = function(state)
        local currentKey = state.session.identity.charKey
        local nameCounts = _nameCounts(state.account.characters)
        local out = {}
        for charKey, c in pairs(state.account.characters) do
            _foldCharacterStock(out, charKey, c, currentKey, _shownName(charKey, c, nameCounts))
        end
        for _, entry in pairs(out) do
            table.sort(entry.perChar, _rosterOrder)
        end
        return out
    end,
})

-- ============================================================================
-- Sidebar nav selectors
-- ============================================================================
-- Parent highlight: one per view, aliasing chrome.activeTab equality.
for _, tab in ipairs(HDG.Constants.TABS or {}) do
    local captured = tab.view
    Selectors:Register("nav.isActive_" .. captured, {
        calls = {"chrome.activeTab"},
        fn = function(state, ctx)
            return Selectors:Call("chrome.activeTab", state, ctx) == captured
        end,
    })
end

-- Leaf highlight: hub view active AND hub's mode state at activePath equals activeValue.
-- activePath is a dotted state path; segment traversal returns nil for missing keys.
local function traversePath(tbl, path)
    local cur = tbl
    for seg in path:gmatch("([^%.]+)") do
        if type(cur) ~= "table" then return nil end
        cur = cur[seg]
    end
    return cur
end

for _, node in ipairs(HDG.Constants.NAV_TREE or {}) do
    if node.kind == "parent" and node.children then
        local hubView = node.view
        for _, child in ipairs(node.children) do
            if child.activePath then  -- mode-leaf (has activePath + activeValue; action OR transient)
                local path  = child.activePath
                local value = child.activeValue
                local id    = "nav.isLeafActive_" .. hubView .. "_" .. tostring(value)
                Selectors:Register(id, {
                    reads = { "account.ui.view", path },
                    fn = function(state, ctx)
                        if state.account.ui.view ~= hubView then return false end
                        return traversePath(state, path) == value
                    end,
                })
            end
        end
    end
end

-- ============================================================================
-- nav.tree (sidebar TreeListView consumer -- per ADR-025)
-- ============================================================================
-- Projects NAV_TREE into root nodes for the treeList widget.
-- active declared in `calls` so view/mode changes re-run nav.tree.
-- Dividers skipped (uniform row height); "Tools" header kept as navHeader.
local _navTreeCalls = {}
do
    local seen = {}
    local function addCall(id) if id and not seen[id] then seen[id] = true; _navTreeCalls[#_navTreeCalls + 1] = id end end
    for _, node in ipairs(HDG.Constants.NAV_TREE or {}) do
        if node.view and (node.kind == "home" or node.kind == "config" or node.kind == "parent") then
            addCall("nav.isActive_" .. node.view)
        end
        if node.children then   -- any node with children (parent hubs + the House home node)
            for _, child in ipairs(node.children) do
                if child.activePath then
                    addCall("nav.isLeafActive_" .. node.view .. "_" .. tostring(child.activeValue))
                elseif child.view then
                    addCall("nav.isActive_" .. child.view)
                end
                if child.gatedBy then addCall(child.gatedBy) end   -- gated child (Debug under Tools)
            end
        end
        if node.gatedBy then addCall(node.gatedBy) end   -- e.g. config.debug gates a gated parent row
    end
end

local function _navLeafNode(hubView, child, state, ctx)
    -- Gated child (e.g. Debug under Tools): omit the leaf when the gate is false.
    if child.gatedBy and not Selectors:Call(child.gatedBy, state, ctx) then return nil end
    -- Launcher child (Shopping/Zone under Tools): dispatch-only, never active-lit.
    if child.launcher then
        return {
            kind = "navNode", tier = "leaf", label = child.label, active = false,
            click = { kind = "launcher", action = child.launcher },
            key = "leaf_launch_" .. child.launcher,
        }
    end
    if child.activePath then
        local value = tostring(child.activeValue)
        return {
            kind   = "navNode",
            tier   = "leaf",
            label  = child.label,
            active = Selectors:Call("nav.isLeafActive_" .. hubView .. "_" .. value, state, ctx),
            click  = child.action
                and { kind = "action",    view = hubView, action = child.action, payload = child.payload }
                or  { kind = "transient",  view = hubView, transient = child.transient },
            key    = "leaf_" .. hubView .. "_" .. value,
        }
    end
    return {
        kind   = "navNode",
        tier   = "leaf",
        label  = child.label,
        active = Selectors:Call("nav.isActive_" .. child.view, state, ctx),
        click  = { kind = "view", view = child.view },
        key    = "leaf_" .. child.view,
    }
end

-- ===== Per-kind root-node builders ==========================================
-- One builder per NAV_TREE node kind; nav.tree fn stays a flat walk.
-- nav.isActive_* calls inside fn's execution (reads-closure preserved via _navTreeCalls).
local function _navHeaderNode(node)
    return { kind = "navNode", tier = "header", isHeader = true, label = node.label,
             key = "hdr_" .. node.label }
end

local function _navHomeNode(node, state, ctx)
    local homeActive = Selectors:Call("nav.isActive_" .. node.view, state, ctx)
    local home = { kind = "navNode", tier = "home", isHome = true, icon = node.icon, label = node.label,
                   active = homeActive, click = { kind = "view", view = node.view }, key = "home" }
    -- 12.1: House carries sub-nav (Blueprints) as indented leaves. The accent
    -- spine stacks House->child when the section (House view OR a child) is active.
    if node.children and #node.children > 0 then
        local sectionActive = homeActive
        for _, child in ipairs(node.children) do
            if child.view and Selectors:Call("nav.isActive_" .. child.view, state, ctx) then
                sectionActive = true
            end
        end
        -- Folds like a hub, keyed by the view (NAV_TOGGLE_GROUP + account.ui.nav):
        -- a collapsed House keeps its row + spine and hides the leaves.
        local collapsed = state.account.ui.nav.collapsedGroups[node.view] == true
        local children = {}
        if not collapsed then
            for _, child in ipairs(node.children) do
                local leaf = _navLeafNode(node.view, child, state, ctx)
                if leaf then   -- nil when a child is gated out
                    leaf.spine = sectionActive or nil
                    children[#children + 1] = leaf
                end
            end
        end
        home.children = children
        home.spine = sectionActive or nil
        home.isCollapsed = collapsed
        home.groupKey = node.view
    end
    return home
end

local function _navConfigNode(node, state, ctx)
    return { kind = "navNode", tier = "config", icon = node.icon,
             iconActive = node.iconActive, iconPressed = node.iconPressed, label = node.label,
             active = Selectors:Call("nav.isActive_" .. node.view, state, ctx),
             click = { kind = "view", view = node.view }, key = "cfg_" .. node.view }
end

local function _navLauncherNode(node)
    return { kind = "navNode", tier = "launcher", icon = node.icon, label = node.label, active = false,
             click = { kind = "launcher", action = node.action }, key = "launch_" .. node.view }
end

-- A hub lights when its own view is active OR any VIEW-leaf child is active.
-- Mode-leaf children share the hub's view (scan is a no-op for those).
local function _hubIsActive(node, state, ctx)
    if node.view and Selectors:Call("nav.isActive_" .. node.view, state, ctx) then return true end
    for _, child in ipairs(node.children or {}) do
        if child.view and Selectors:Call("nav.isActive_" .. child.view, state, ctx) then
            return true
        end
    end
    return false
end

local function _navParentNode(node, state, ctx)
    local hub = node.view
    local hubActive = _hubIsActive(node, state, ctx)
    if not (node.children and #node.children > 0) then
        return { kind = "navNode", tier = "parent", icon = node.icon,
                 iconActive = node.iconActive, iconPressed = node.iconPressed, label = node.label,
                 active = hubActive, click = { kind = "view", view = hub }, key = "item_" .. hub }
    end
    -- Collapse-state key: the hub's view, or collapseKey for a no-view group (Tools).
    local groupKey = node.view or node.collapseKey
    -- Collapsed groups omit their children (honored even when the group is the
    -- active section -- the hub stays highlighted, children just hide). Toggled
    -- by the row's fold chevron (NAV_TOGGLE_GROUP); persisted in account.ui.nav.
    local collapsed = state.account.ui.nav.collapsedGroups[groupKey] == true
    -- Active-section spine: flag hub + every child so the accent bar stacks
    -- into one continuous parent->child spine.
    local children = {}
    if not collapsed then
        for _, child in ipairs(node.children) do
            local leaf = _navLeafNode(hub, child, state, ctx)
            if leaf then   -- nil when a child is gated out (e.g. Debug off debug mode)
                leaf.spine = hubActive or nil
                children[#children + 1] = leaf
            end
        end
    end
    return { kind = "navNode", tier = "hub", isHub = true, icon = node.icon,
             iconActive = node.iconActive, iconPressed = node.iconPressed, label = node.label,
             active = hubActive, spine = hubActive or nil, isCollapsed = collapsed,
             groupKey = groupKey,
             -- noNavigate hubs (Tools) have no view -> the whole row toggles the fold
             -- instead of navigating (the chevron does the same on every group row).
             click = (not node.noNavigate) and { kind = "view", view = hub }
                 or { kind = "toggleGroup", view = groupKey },
             children = children, key = "hub_" .. groupKey }
end

-- kind -> builder. No-builder nodes ("divider", "__gated") are skipped.
local _navBuilders = {
    header   = _navHeaderNode,
    home     = _navHomeNode,
    config   = _navConfigNode,
    launcher = _navLauncherNode,
    parent   = _navParentNode,
}

Selectors:Register("nav.tree", {
    -- Memoized: the sidebar is bound in every view, so every dispatch that
    -- reached the pipeline re-pushed it and every call rebuilt all ~33 nodes
    -- (26 KB a call, 42 calls in one scenario -- 2026-09-13 allocation audit).
    -- The closure is complete: collapsedGroups plus the machine-built call
    -- list below, which names every isActive / isLeafActive / gate selector
    -- the builders can reach. Nothing here reads ctx, _G or the clock.
    memoized = true,
    reads = { "account.ui.nav.collapsedGroups" },   -- _navParentNode + _navHomeNode read it for collapse
    calls = _navTreeCalls,
    fn = function(state, ctx)
        local roots = {}
        for _, node in ipairs(HDG.Constants.NAV_TREE or {}) do
                -- Gated nodes (gatedBy predicate false) collapse to "__gated" -> omitted.
            local k = (node.gatedBy and not Selectors:Call(node.gatedBy, state, ctx))
                and "__gated" or node.kind
            local builder = _navBuilders[k]
            if builder then roots[#roots + 1] = builder(node, state, ctx) end
        end
        return roots
    end,
})

-- ============================================================================
-- Status rail persistent widgets
-- ============================================================================

-- Left label: "Vamoose says: <quote>". Nil until first dispatch (before onEnable).
Selectors:Register("status.quoteText", {
    reads = {"session.daily.orcQuote"},
    fn = function(state)
        local q = state.session.daily.orcQuote
        if not q then return nil end
        return "Vamoose says: " .. q
    end,
})

-- Right label: "House Lv N   favor / threshold XP".
-- Active-house resolution mirrors house.decoratorProfileData (same fallback-to-first logic).
-- thresholds[level+1] = cumulative XP to next level; favor = current cumulative XP.
Selectors:Register("status.houseInfo", {
    reads = {
        "session.house.ownedHouses",
        "session.house.activeNeighborhoodGUID",
    },
    fn = function(state)
        local owned    = state.session.house.ownedHouses
        local activeGUID = state.session.house.activeNeighborhoodGUID
        local h
        if activeGUID then
            for _, entry in pairs(owned) do
                if entry.neighborhoodGUID == activeGUID then h = entry; break end
            end
        end
        if not h then
            for _, entry in pairs(owned) do h = entry; break end
        end
        if not h or not h.level then return nil end

        local level      = h.level
        local favor      = h.favor or 0
        local maxLevel   = h.maxLevel or 50
        local thresholds = h.thresholds

        if level >= maxLevel then
            return string.format("House Lv %d (Max)", level)
        end
        local nextThreshold = thresholds and thresholds[level + 1]
        local function fmt(n) return (n and n > 0) and HDG.Format.FormatAmount(n) or "0" end
        if nextThreshold and nextThreshold > 0 then
            return string.format("House Lv %d   %s / %s XP",
                level, fmt(favor), fmt(nextThreshold))
        end
        return string.format("House Lv %d   %s XP", level, fmt(favor))
    end,
})

-- (chrome.effectiveView / isCompactMode / isDefaultMode / titleText deleted:
--  Shopping + Zone are independent HDG.Window floating frames; no compact mode.)

