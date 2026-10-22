-- HDGR_Controller_Pets.lua
-- ============================================================================
-- petRow factory + click wiring for the Pets browser mode of the Decor tab.
--
-- Rows are icon + name ONLY (spec ruling 13): scale lives in the shared card's
-- scene, where the pet stands next to real furniture and your own character --
-- a bar against an abstract axis told the same story worse. The height still
-- rides the tooltip as a number.

HDG = HDG or {}
HDG.Controller_Pets = HDG.Controller_Pets or {}
local PetsController = HDG.Controller_Pets

-- ===== Row: layout (first paint only) ========================================
local function _layoutPetRow(row)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 2, 0)
    row._iconTex = icon

    local name = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(name, "body")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetJustifyH("LEFT")
    HDG.Theme:Register(name, "Text")
    row._nameFs = name

    name:SetPoint("RIGHT", -4, 0)

    HDG.TooltipEngine:Attach(row, function(self)
        if not self._tipName then return nil end
        local lines = {}
        if self._tipFamily and self._tipFamily ~= "" then
            lines[#lines + 1] = self._tipFamily
        end
        lines[#lines + 1] = self._tipHeight
            and ("Height %s -- you are %.2f")
                :format(self._tipHeight, HDG.Constants.PET_CHARACTER_HEIGHT)
            or "Size not measured"
        return { title = self._tipName, extraLines = lines }
    end)
end

-- ===== Row: paint (every bind) ===============================================
local function _paintPetRow(row, ed)
    row._iconTex:SetTexture(ed.icon)
    row._nameFs:SetText(ed.displayName)

    row._speciesID = ed.speciesID
    row._tipName   = ed.displayName
    row._tipFamily = ed.familyLabel
    row._tipHeight = ed.height and ("%.2f"):format(ed.height) or nil
end

-- ===== Row: clicks ===========================================================
local function _wirePetRowClicks(row, ed)
    local speciesID = ed.speciesID
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.UI_SET_TRANSIENT,
            payload = { view = "decor", key = "selectedSpeciesID", value = speciesID },
        })
    end)
end

-- ===== Row: reset ============================================================
local function _resetPetRow(row)
    row._speciesID = nil
    row._tipName, row._tipFamily, row._tipHeight = nil, nil, nil
    -- Strict: _layoutPetRow creates the icon unconditionally and every row reaching
    -- Reset has been through it. Guarding would swallow a rename instead of surfacing it.
    row._iconTex:SetTexture(nil)
end

HDG.Rows:Register("petRow", {
    font    = "body",
    height  = 24,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutPetRow,
        paint      = _paintPetRow,
        laidOutTag = "_petLaidOut",
        selectable = true,
        clicks     = "LeftButtonUp",
        wire       = _wirePetRowClicks,
        resetText  = { "_nameFs" },
        reset      = _resetPetRow,
    }),
    -- One row per species: a player can own several of the same pet, but they are
    -- the same size and the same picture, so the list shows one.
    key     = function(ed) return ed.speciesID end,
})

-- ===== Controller ============================================================
-- The contract is Wire AND Refresh: Controllers:RefreshViews calls Refresh on
-- every controller a shown view lists with no guard, so a controller missing
-- either one takes down the whole refresh pass.
--
-- The search box writes the SAME transient the decor search does, so flipping to
-- Pets mid-search keeps what you typed -- which is what you want, because the
-- thing you were looking for is often in both lists.
function PetsController:Wire(rootFrame)
    HDG.UI.WireSearchBox(rootFrame, "petPanel.search", "decor", "searchQuery")

    -- Selection highlight is owned by the list's SelectionBehaviorMixin (the
    -- click stamps ed.selected) and re-applied from the Store after any re-push
    -- here -- the rows selector no longer bakes it, so a search or a pets tick
    -- would otherwise drop the highlight. Same wiring as the Decor list.
    local listBox = HDG.UI.W(rootFrame, "petPanel.list")
    if listBox and listBox.WireStoreSelectionSync then
        listBox:WireStoreSelectionSync("session.ui.decor.selectedSpeciesID",
            function(ed, id) return id ~= nil and ed.speciesID == id end)
    end

    -- Summon / Dismiss. Read the LATCHED summon state, not the live API: after a
    -- summon GetSummonedPetGUID reads nil for up to 1.5s, so deciding here from the
    -- live call would toggle the wrong way. The observer latches on
    -- COMPANION_UPDATE and the selector reports it.
    --
    -- AND NO REFRESH AFTER THE CLICK. COMPANION_UPDATE fires in the same frame
    -- carrying the new state -- VPP measured this with /vppr summonprobe -- so
    -- repainting here would paint the state we are leaving. The dispatch that the
    -- observer raises is what repaints the button.
    HDG.UI.OnClick(rootFrame, "petDetailPanel.summonBtn", function()
        local state = HDG.Store:GetState()
        local petID = HDG.Selectors:Call("pets.selectedPetID", state, {})
        if not petID then return end
        if HDG.Selectors:Call("pets.isSelectedSummoned", state, {}) then
            HDG.PetObserver:Dismiss()
        else
            HDG.PetObserver:Summon(petID)
        end
    end)
end

function PetsController:Refresh(_rootFrame, _ctx)
    -- Bindings handle paint; nothing imperative.
end

HDG.Controllers:Register("pets", PetsController)
