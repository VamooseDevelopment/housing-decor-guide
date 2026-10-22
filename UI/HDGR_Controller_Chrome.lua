-- HDG.ChromeController
-- ============================================================================
-- Wires chrome-level controls: close button (X).
-- Tab/view navigation lives in NavController (sidebar nav).

HDG = HDG or {}
HDG.ChromeController = HDG.ChromeController or {}

local ChromeController = HDG.ChromeController

-- Essence of Lumber badge: account-wide count painted onto the glyph, greyed
-- when none owned. The count FontString is created once, lazily, on the glyph;
-- the per-alt breakdown lives in the EssenceBadge tooltip recipe. Refresh
-- only fires while the main window paints, so the glyph is always present here.
local function _paintEssence(rootFrame, state)
    local btn = HDG.UI.W(rootFrame, "chromePanel.essence")
    local sel = HDG.Selectors:Call("chrome.essenceBadge", state, {})
    if not btn._essenceReady then
        -- A game item icon is an opaque square, so it reads as a dark tile next
        -- to the transparent atlas glyphs. Crop the icon border, then round it
        -- with a circular mask (HouseTab CircleMaskScalable precedent) so it
        -- sits as a token in the glyph cluster.
        local tex = btn:GetNormalTexture()
        tex:SetTexCoord(unpack(HDG.Constants.ICON_CROP))
        HDG.UI.CircleMask(tex)
        local badge = HDG.UI:Label(btn, "", "caption", "RIGHT", { role = "Text" })
        badge:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, -1)
        btn._essenceBadge = badge
        btn._essenceReady = true
    end
    btn._essenceBadge:SetText(sel.owned and tostring(sel.total) or "")
    btn:GetNormalTexture():SetDesaturated(not sel.owned)
end

function ChromeController:Wire(rootFrame)
    -- Close [X]: dispatches MAIN_WINDOW_TOGGLE. Shopping + Zone satellites own their own close.
    HDG.UI.OnClick(rootFrame, "chromePanel.close", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.MAIN_WINDOW_TOGGLE })
    end)

    -- Lumber glyph: toggles the floating Lumber Tracker. No `visible` payload --
    -- the reducer flips windowVisible itself (HDGR_Store LUMBER_WINDOW_TOGGLE).
    HDG.UI.OnClick(rootFrame, "chromePanel.lumberToggle", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.LUMBER_WINDOW_TOGGLE })
    end)

    -- Cart glyph: toggles the floating Shopping List window (SHOPPING_WIDGET_TOGGLE flips it).
    HDG.UI.OnClick(rootFrame, "chromePanel.shoppingToggle", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_WIDGET_TOGGLE })
    end)
end

function ChromeController:Refresh(rootFrame, ctx)
    -- The essence badge is imperative (count + desaturation). Tab/view
    -- navigation state lives in NavController (sidebar), not here.
    _paintEssence(rootFrame, ctx.state)
end

HDG.Controllers:Register("chrome", ChromeController)
