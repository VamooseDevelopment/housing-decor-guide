-- HDG.LumberController
-- ============================================================================
-- Lumber Tracker: lumberCounterRow factory + Wire (End Session / Back / Close / toggles).
-- Row: 16px icon | shortName | held/all-decor-need (right). Active row
-- highlighted. Queue need rides the tooltip (Discord 2026-06-11: the row
-- number is the long-horizon farming goal, not the session queue).

HDG = HDG or {}
HDG.LumberController = HDG.LumberController or {}

-- Icon in lumber.counterRows selector (stamps ed.icon + declares session.itemNames.names read
-- so async ITEM_INFO_RESOLVED re-fires the selector). Row factory just reads ed.icon.

-- First-paint chrome: icon | name (fill) | stock/queue-need (right).
local function _layoutLumberCounterRow(row)
    -- Icon on the far left. ARTWORK: above chrome's BACKGROUND fills.
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row._iconTex = icon

    -- Name (shortName) after icon
    local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    row._nameFs = name

    -- Stock / queue-need, right-aligned ("55/50" when queued, "55" otherwise).
    local held = HDG.UI.RowText(row, "body", "Text", "RIGHT")
    held:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row._heldFs = held

    -- Name fills the remaining gap between icon and held.
    name:SetPoint("RIGHT", held, "LEFT", -8, 0)

    -- Tooltip reads live row fields (one Attach covers all pooled binds).
    HDG.TooltipEngine:Attach(row, function(self)
        if not self._tipName then return nil end
        local lines = { "In bags + bank: " .. tostring(self._tipHeld or 0) }
        if (self._tipDecorNeed or 0) > 0 then
            lines[#lines + 1] = "Uncollected decor needs: " .. self._tipDecorNeed
        end
        if (self._tipQueueNeed or 0) > 0 then
            lines[#lines + 1] = "Queued crafts need: " .. self._tipQueueNeed
        end
        return { title = self._tipName, extraLines = lines }
    end)
end

local function _paintLumberCounterRow(row, ed)
    -- "body_strong" OUTLINE stands out on active rows; reverts to "body" when inactive.
    HDG.UI.applyFontRole(row._nameFs,
        ed.isActive and "body_strong" or "body")

    -- "44/520" against the goal need (all-decor or queued, per the toggle) when
    -- one exists; bare held otherwise.
    local heldText = (ed.displayNeed or 0) > 0
        and string.format("%d/%d", ed.held, ed.displayNeed)
        or tostring(ed.held)

    row._iconTex:SetTexture(ed.icon)
    row._nameFs:SetText(ed.displayName)
    row._heldFs:SetText(heldText)
    row._tipName, row._tipHeld = ed.name, ed.held
    row._tipDecorNeed, row._tipQueueNeed = ed.decorNeed, ed.queueNeed
end

HDG.Rows:Register("lumberCounterRow", {
    font    = "body",
    height  = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutLumberCounterRow,
        paint      = _paintLumberCounterRow,
        laidOutTag = "_lumberCounterLaidOut",
        selectedFn = function(ed) return ed.isActive end,   -- active row highlight (envelope has isActive, not selected)
        resetText  = { "_nameFs", "_heldFs" },
        reset      = function(row)
            if row._iconTex then row._iconTex:SetTexture(nil) end
        end,
    }),
    key     = function(ed)
        return "lumber:" .. tostring(ed and ed.lumberID or "?")
    end,
})

-- Wire: hooks action-bar + header buttons. Window visibility reconciled by HDG.Window
-- from lumber.windowVisible; rootFrame is the floating lumber window (not the main frame).

function HDG.LumberController:Wire(rootFrame)
    if not HDG.Log:HasTag("lumber_action") then
        HDG.Log:RegisterTags({ lumber_action = { user = true, level = "info", duration = 3 } })
    end
    -- End Session: finalizes (stamps finalizedAt) but leaves the window open.
    HDG.UI.OnClick(rootFrame, "lumberActionPanel.endSession", function()
        HDG.LumberObserver:FinalizeSession()
        HDG.Log:Success("lumber_action", "Lumber session finalized")
    end)

    -- Close [X]: hides lumber window only (no main-window side effect).
    HDG.UI.OnClick(rootFrame, "lumberPanel.close", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.LUMBER_WINDOW_TOGGLE,
            payload = { visible = false },
        })
    end)

    -- Zone Map icon: open/close the Blizzard BattlefieldMap (the Shift-M "Zone Map")
    -- for the current area. LoadOnDemand addon -- frame is nil until first loaded,
    -- so load Blizzard's UI, then Toggle (which also closes it on reclick).
    HDG.UI.OnClick(rootFrame, "lumberPanel.zoneMapBtn", function()
        if not BattlefieldMapFrame then BattlefieldMap_LoadUI() end  -- exception(boundary): Blizzard LoD addon, frame nil until loaded
        if BattlefieldMapFrame then BattlefieldMapFrame:Toggle() end  -- exception(boundary): LoadUI no-ops if the LoD addon is user-disabled
    end)

    -- Collapse toggle: flips radar visibility (binding + dynamicRows = 0 shrinks the window).
    HDG.UI.OnClick(rootFrame, "lumberPanel.collapseToggle", function()
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.LUMBER_RADAR_COLLAPSE_TOGGLE,
        })
    end)

    -- List toggle: flips listCollapsed -> collapses counter list + action bar to 0.
    HDG.UI.OnClick(rootFrame, "lumberPanel.listToggle", function()
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.LUMBER_LIST_COLLAPSE_TOGGLE,
        })
    end)

    -- Goal toggle (action bar): flips the row denominator between all-uncollected-decor
    -- need and queued-craft need. Checked = queue; the tooltip explains both states.
    HDG.UI.OnClick(rootFrame, "lumberActionPanel.goalToggle", function()
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.LUMBER_GOAL_TOGGLE,
        })
    end)
end

function HDG.LumberController:Refresh(_rootFrame, _ctx)
    -- All rendering flows through bindings + the row factory; nothing
    -- imperative needs to happen here.
end

HDG.Controllers:Register("lumber", HDG.LumberController)
