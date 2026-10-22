-- HDG.NavController
-- ============================================================================
-- Sidebar nav (per ADR-025). treeList bound to nav.tree; click payload dispatches:
--   view -> setView | action -> setView + Dispatch | transient -> setView + SetUITransientView
--   launcher -> Dispatch only | toggleGroup -> NAV_TOGGLE_GROUP (fold a group)

HDG = HDG or {}
HDG.NavController = HDG.NavController or {}

local NavController = HDG.NavController

local function setView(view)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.UI_SET_PERSISTENT,
        payload = { key = "view", value = view },
    })
end

-- Dispatch a node's click payload. Returns nothing; safe to call from OnClick.
local function dispatchClick(click)
    if not click then return end
    local k = click.kind
    if k == "view" then
        setView(click.view)
    elseif k == "action" then
        setView(click.view)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS[click.action], payload = click.payload })
    elseif k == "transient" then
        setView(click.view)
        local t = click.transient
        HDG.ControllerHelpers.Mechanics.SetUITransientView(t.view, t.key, t.value)
    elseif k == "launcher" then
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS[click.action] })
    elseif k == "toggleGroup" then
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.NAV_TOGGLE_GROUP, payload = { view = click.view } })
    end
end

-- Exposed for the controller-wire smoke test.
NavController._dispatchClick = dispatchClick

-- Paint nav icon from file path or atlas. GetAtlasInfo-guards bad names (hide, no error). nil -> hide.
local function _paintNavAtlas(tex, ic)
    if not tex then return end
    if ic and ic:find("[/\\]") then
        tex:SetTexture(ic); tex:Show()
    -- exception(boundary): C_Texture is a Blizzard global (absent in headless tests); when present,
    -- GetAtlasInfo validates the atlas so a bad name hides the icon instead of erroring.
    elseif ic and (not (C_Texture and C_Texture.GetAtlasInfo) or C_Texture.GetAtlasInfo(ic) ~= nil) then
        tex:SetAtlas(ic); tex:Show()
    else
        tex:Hide()
    end
end

-- Tooltip for the fold chevron. Reads per-init stamps on the chevron button
-- (stable module-level def + stamps -> safe with idempotent TooltipEngine:Attach).
local function _navFoldTipDef(self_)
    if not self_._hubView then return nil end
    return { title = (self_._navTipCollapsed and "Expand " or "Collapse ")
                     .. (self_._navTipLabel or "group") }
end

-- Fold chevron glyph: ">" folded / "v" open -- the text-chevron idiom the Styles
-- and Trainers category rows already use.
local function _foldGlyph(collapsed)
    return collapsed and ">" or "v"
end

-- ===== Cell kind: navNode =====================================================
-- One cell kind for the whole nav. Single FontString (shared via SetText) avoids
-- cross-kind pool recycling that caused the double-text overlay.
HDG.TreeList:RegisterCellKind("navNode", {
        template = "Button",
        initializer = function(frame, node)
            local data = node:GetData()
            if not frame._navLaidOut and frame.CreateFontString then
                HDG.UI:EnsureRowChrome(frame)
                local icon = frame:CreateTexture(nil, "ARTWORK", nil, 2)
                icon:SetSize(15, 15)
                icon:SetPoint("LEFT", frame, "LEFT", 7, 0)
                icon:Hide()
                frame._navIcon = icon
                -- Fold chevron at the row's RIGHT edge on group rows (hubs + the
                -- House home node). It used to be an unpainted 17px hitbox over the
                -- group icon: it worked, but nothing on screen said the groups fold,
                -- so nobody found it (Soul, Discord 2026-09-10). The row's own
                -- OnClick (icon / label / body) still navigates -- the child button
                -- captures only its region.
                local foldBtn = CreateFrame("Button", nil, frame)
                foldBtn:SetSize(16, 20)
                foldBtn:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
                foldBtn:RegisterForClicks("LeftButtonUp")
                foldBtn:SetScript("OnClick", function(self_)
                    if not self_._hubView then return end
                    HDG.Store:Dispatch({
                        type    = HDG.Constants.ACTIONS.NAV_TOGGLE_GROUP,
                        payload = { view = self_._hubView },
                    })
                end)
                -- Body font + brighten on hover: the same weight and feedback as the
                -- Blueprints row `x`, so the one affordance added to be SEEN is not
                -- the dimmest mark on the row.
                local glyph = HDG.UI.RowText(foldBtn, "body", "TextDim", "CENTER")
                glyph:SetAllPoints()
                foldBtn._glyph = glyph
                foldBtn:SetAlpha(0.6)
                foldBtn:SetScript("OnEnter", function(self_) self_:SetAlpha(1) end)
                foldBtn:SetScript("OnLeave", function(self_) self_:SetAlpha(0.6) end)
                foldBtn:Hide()
                HDG.TooltipEngine:Attach(foldBtn, _navFoldTipDef)
                frame._navFoldBtn = foldBtn
                -- Indent guide: 1px line; flush rows stack into a continuous connector.
                local guide = frame:CreateTexture(nil, "ARTWORK", nil, 1)
                guide:SetTexture("Interface\\Buttons\\WHITE8x8")
                guide:SetWidth(1)
                guide:SetPoint("TOPLEFT",    frame, "TOPLEFT",    22, 0)
                guide:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 0)
                guide:Hide()
                frame._navGuide = guide
                local label = frame:CreateFontString(nil, "OVERLAY")
                label:SetJustifyH("LEFT")
                label:SetWordWrap(false)   -- fixed-height rows never reflow (scroll-gutter reclaim caused 2-line wrap)
                frame._navLabelFs = label
                frame._navLaidOut = true
            end

            -- Tier-based font/role: heading (home/hub/parent/config/launcher), body (leaf), caption (header).
            -- Re-applied each init; a pooled frame may flip tier across recycles.
            local tier = data.tier or (data.isHeader and "header")
                or (data.isHome and "home") or "leaf"
            local isHeader = (tier == "header")
            local fontRole, textRole
            if isHeader then
                fontRole, textRole = "caption", "TextDim"
            elseif tier == "leaf" then
                fontRole = "body"
                textRole = data.active and "Text" or "TextMuted"
            else  -- home / hub / parent / config / launcher
                fontRole = "heading"
                textRole = (data.active or data.spine) and "TextHeading" or "Text"
            end
            HDG.UI.applyFontRole(frame._navLabelFs, fontRole)
            HDG.Theme:Register(frame._navLabelFs, textRole)
            frame._navLabelFs:SetText(isHeader and string.upper(data.label or "")
                or (data.label or ""))

            -- Label X: headers=8, top-level=26 (icon col), leaves=40 (manual indent, tree indent=0).
            -- Group rows stop short of the fold chevron on the right.
            local labelX = isHeader and 8 or (tier == "leaf" and 40 or 26)
            frame._navLabelFs:ClearAllPoints()
            frame._navLabelFs:SetPoint("LEFT",  frame, "LEFT",  labelX, 0)
            frame._navLabelFs:SetPoint("RIGHT", frame, "RIGHT", data.groupKey and -20 or -4, 0)

            -- Category icon: top-level rows. iconActive/iconPressed stashed for pressed handlers.
            if frame._navIcon then
                local isTop = (tier ~= "leaf" and tier ~= "header")
                frame._navIconDefault = isTop and data.icon or nil
                frame._navIconActive  = isTop and data.iconActive or nil
                frame._navIconPressed = isTop and data.iconPressed or nil
                frame._navActive      = data.active and true or false
                _paintNavAtlas(frame._navIcon,
                    (frame._navActive and frame._navIconActive) or frame._navIconDefault)
            end
            -- Fold chevron: paint + stamp on group rows (any node carrying a
            -- groupKey -- hubs and the House home node); hidden elsewhere so
            -- clicks pass to the row.
            if frame._navFoldBtn then
                if data.groupKey then
                    frame._navFoldBtn._hubView         = data.groupKey   -- collapse key (= view, or "tools")
                    frame._navFoldBtn._navTipLabel     = data.label
                    frame._navFoldBtn._navTipCollapsed = data.isCollapsed and true or false
                    frame._navFoldBtn._glyph:SetText(_foldGlyph(data.isCollapsed))
                    frame._navFoldBtn:Show()
                else
                    frame._navFoldBtn._hubView = nil
                    frame._navFoldBtn:Hide()
                end
            end
            -- Indent guide: leaves only.
            if frame._navGuide then
                if tier == "leaf" then frame._navGuide:Show() else frame._navGuide:Hide() end
            end

            -- NavRow paint: tier fill + accent spine (flat, never zebra).
            HDG.Theme:Register(frame, "NavRow", {
                tier   = tier,
                active = data.active and true or false,
                spine  = data.spine  and true or false,
            })
            if frame.EnableMouse then frame:EnableMouse(not isHeader) end  -- exception(false-positive): navNode template = "Button"; EnableMouse + RegisterForClicks are guaranteed; mock-fidelity guard
            if frame.RegisterForClicks then frame:RegisterForClicks("LeftButtonUp") end  -- exception(false-positive): navNode template = "Button"; see above
            if isHeader then
                frame:SetScript("OnClick", nil)
            else
                local click = data.click
                frame:SetScript("OnClick", function() dispatchClick(click) end)
            end
            -- Pressed-state icon swap. Cleared otherwise so pooled frames can't inherit stale handlers.
            if frame._navIconPressed and not isHeader then
                frame:SetScript("OnMouseDown", function(self) _paintNavAtlas(self._navIcon, self._navIconPressed) end)
                frame:SetScript("OnMouseUp", function(self)
                    _paintNavAtlas(self._navIcon, (self._navActive and self._navIconActive) or self._navIconDefault)
                end)
            else
                frame:SetScript("OnMouseDown", nil)
                frame:SetScript("OnMouseUp", nil)
            end
        end,
    })

-- ===== Reveal the active row =================================================
-- The sidebar spans the ACTIVE VIEW's body height (ComposeWindow stretches the
-- `left` slot to the fill view's height), and every nav.tree rebuild discards the
-- scroll offset (TreeList:SetItems -> DiscardScrollPosition). So switching to a
-- short view both resets the tree to the top AND cuts it short: Move Planner's
-- 502px body fits 19 of the 30 rows, and "Move Planner" is row 21 -- the
-- destination the user just clicked lands below the fold. Scroll it back.
--
-- Deepest-active, not first-active: a leaf click lights its hub too, and
-- FindElementDataIndexByPredicate returns the FIRST match -- landing on the hub
-- (up to 3 rows above) can leave the leaf itself below the fold. A hub with no
-- active child (clicked directly, or collapsed) is itself the target.
local function _isDeepestActive(node)
    local data = node:GetData()
    if not data.active then return false end
    if data.children then
        for _, child in ipairs(data.children) do
            if child.active then return false end
        end
    end
    return true
end

-- Exposed for the controller-wire smoke test.
NavController._isDeepestActive = _isDeepestActive

-- Two-phase: the tree's post-rebuild hook marks the reveal pending, the NavReveal
-- pipeline stage flushes it. SetItems runs in BIND -- before LAYOUT resizes the
-- sidebar to the new view -- and scrolling against the outgoing height picks the
-- wrong offset (row 21 reads as "already visible" in a 23-row window, then the
-- window shrinks to 19 and drops it again).
function NavController:RevealActive(rootFrame)
    if not self._revealPending then return end
    self._revealPending = false
    local tree = HDG.UI.W(rootFrame, "navPanel.tree")
    -- AlignNearest = shortest hop, and a no-op when the row is already fully in
    -- view. noInterpolation: the nav is chrome, it shouldn't animate under a
    -- window that just resized. Collapsed hubs carry no children in nav.tree, so
    -- the predicate can never match inside one -- PrepareScrollToElementData
    -- never expands a group behind the Store's back.
    tree._scrollBox:ScrollToElementDataByPredicate(
        _isDeepestActive, ScrollBoxConstants.AlignNearest, 0, true)
end

-- Clicks live in cell initializers; active highlight flows via nav.tree's `active` flags.
function NavController:Wire(rootFrame)
    local tree = HDG.UI.W(rootFrame, "navPanel.tree")
    -- Every fill can move the active row (a rebuild discards the scroll offset; an
    -- in-place update moves the highlight), so every fill needs a reveal.
    -- _afterSetItems is TreeList's post-population hook list (the same seam
    -- WireStoreSelectionSync uses).
    tree._afterSetItems = tree._afterSetItems or {}
    tree._afterSetItems[#tree._afterSetItems + 1] = function()
        NavController._revealPending = true
    end
end

function NavController:Refresh(_rootFrame, _ctx) end

HDG.Controllers:Register("nav", NavController)
