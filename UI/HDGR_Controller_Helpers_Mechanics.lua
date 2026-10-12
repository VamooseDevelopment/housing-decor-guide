-- HDG.ControllerHelpers.Mechanics
-- State readers + dispatch wrappers. All Store mutation goes through here.
-- No widget access, no paint, no UI workflow.

HDG = HDG or {}
HDG.ControllerHelpers = HDG.ControllerHelpers or {}
HDG.ControllerHelpers.Mechanics = HDG.ControllerHelpers.Mechanics or {}

local Mech = HDG.ControllerHelpers.Mechanics

-- ===== State readers ======================================================

function Mech.GetState()
    return HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
end

-- Per-view scratch state at state.session.ui[view][key].
function Mech.GetUIView(view)
    return Mech.GetState().session.ui[view] or {}
end

function Mech.GetConfigValue(key, fallback)
    local v = Mech.GetState().account.config[key]
    if v == nil then return fallback end
    return v
end

-- ===== Dispatch wrappers + domain actions =================================
-- Wall-clock seconds for stamps (createdAt / lastCapturedAt). One annotated
-- boundary instead of 13 hand-rolled copies (hygiene review A2).
function Mech.Now()
    return (time and time()) or 0  -- exception(boundary): time() is a Lua/WoW global
end

-- Dispatch by ACTION NAME (resolves through the closed taxonomy).
function Mech.DispatchNamed(actionType, payload)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS[actionType], payload = payload })
end

function Mech.Dispatch(actionType, payload)
    HDG.Store:Dispatch({ type = actionType, payload = payload })
end

-- account.ui: persists across /reload. session.ui: cleared on /reload.
-- Bucket choice is at the call site.
function Mech.SetUIPersistent(key, value)
    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.UI_SET_PERSISTENT,
        payload = { key = key, value = value },
    })
end

function Mech.SetUITransient(key, value)
    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.UI_SET_TRANSIENT,
        payload = { key = key, value = value },
    })
end

-- Per-view variant: payload.view picks the sub-bucket.
function Mech.SetUITransientView(view, key, value)
    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.UI_SET_TRANSIENT,
        payload = { view = view, key = key, value = value },
    })
end

-- Select a vendor in the acquisition view: the five-transient sequence every
-- selection path shares (row click, auto-select, cross-window jump). npcID is
-- authoritative; (name, zone) is the npcID-less fallback identity (hygiene A23).
function Mech.SelectVendor(npcID, name, zone)
    Mech.SetUITransientView("acquisition", "selectedNpcID", npcID)
    Mech.SetUITransientView("acquisition", "selectedVendorName", name)
    Mech.SetUITransientView("acquisition", "selectedVendorZone", zone)
    Mech.SetUITransientView("acquisition", "selectedItemID", nil)
    Mech.SetUITransientView("acquisition", "selectedRecipeItemID", nil)
end

-- Delete a design version (a what-if layout), with a confirm. Shared by the
-- Layouts view's Delete button and the Architect's version menu -- one dialog,
-- one wording. A version has no re-import path, so it confirms like every other
-- persisted delete (a mis-click used to remove it outright). Name, ids AND the
-- caller's afterAccept travel in textArg1 + data: UI.Confirm memoizes the dialog
-- per id, so anything the onAccept closure captured at the FIRST call would run
-- for every later one (the two callers pass different follow-ups).
function Mech.ConfirmDeleteVersion(houseID, versionID, name, afterAccept)
    HDG.UI.Confirm({
        id       = "HDGR_PROJECTS_DELETE_VERSION",
        text     = "Delete layout \"%s\"? Its rooms and their furnishings stay in your library; only this arrangement goes.",
        accept   = "Delete", cancel = "Cancel",
        textArg1 = name, data = { houseID = houseID, versionID = versionID, afterAccept = afterAccept },
        onAccept = function(_, d)
            HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.PROJECTS_DELETE_VERSION,
                payload = { houseID = d.houseID, versionID = d.versionID, ts = Mech.Now() } })  -- exception(boundary): time()
            d.afterAccept()
        end,
    })
end

-- Open the main window on a view, with that view's filters reset so the
-- target is listed (a zone filter left on once hid the jumped-to vendor, and the
-- player landed on someone else's goods).
local function _openViewReset(view)
    if Mech.GetState().account.ui.mainWindowShown ~= true then
        Mech.Dispatch(HDG.Constants.ACTIONS.MAIN_WINDOW_TOGGLE)
    end
    Mech.SetUIPersistent("view", view)
    Mech.Dispatch(HDG.Constants.ACTIONS.UI_FILTER_RESET, { tab = view })
end

-- Vendor deep-link: open the main window on Acquire > Shop by Vendor with this
-- vendor selected. Callable from any window (shopping widget / zone popup vendor
-- rows / the Decor source hyperlink). Resets EVERY acquisition filter, not just
-- the search: a zone / source / faction filter or Missing-only that excludes
-- this vendor leaves it out of acq.vendors, and AcquisitionController:Refresh
-- then auto-selects the first vendor that IS listed -- the player landed on
-- someone else's goods (ReganB, Discord 2026-09-11). The search editbox
-- reconciles from state in acquisition Refresh. npcID is authoritative when
-- set; (name, zone) is the fallback identity for npcID-less vendors (mirrors
-- acq.selectedVendor). The selected row scrolls into view via the selection
-- reveal queue (UI.QueueSelectionReveal).
function Mech.JumpToVendor(npcID, name, zone)
    _openViewReset("acquisition")
    Mech.SetUITransientView("acquisition", "viewMode", "vendor")
    Mech.SelectVendor(npcID, name, zone)
end

-- Recipe deep-link: Crafting > Recipes on this recipe (itemID = the crafted
-- decor, which is how recipes are keyed), its materials in the Materials list.
-- The reset puts the profession filter back to this character's professions,
-- which hides a recipe from any other profession -- so that one profession is
-- added to the filter (a toggle, so only when it is missing; the filter is
-- saved per character, so it stays added). An empty set means all professions.
function Mech.JumpToRecipe(itemID)
    _openViewReset("recipes")
    local state = Mech.GetState()
    local profession = HDG.Selectors:Call("recipes.db", state, {})[itemID].profession
    local shown = HDG.Selectors:Call("recipes.professionFilter", state, {})
    if next(shown) ~= nil and not shown[profession] then
        Mech.Dispatch(HDG.Constants.ACTIONS.RECIPES_TOGGLE_PROFESSION, { profession = profession })
    end
    Mech.Dispatch(HDG.Constants.ACTIONS.RECIPES_SHOW_RECIPE, { recipeID = itemID })
end

-- Decor deep-link: the Decor browser on this item's undyed row. The list
-- selects by variantKey, and the undyed row's key is "<itemID>:base"
-- (decor.items, HDGR_Selectors_Decor.lua); the reset clears the Dyed and
-- Stored filters that could leave that row out.
function Mech.JumpToDecor(itemID)
    _openViewReset("decor")
    Mech.SetUITransientView("decor", "selectedItemID", itemID)
    Mech.SetUITransientView("decor", "selectedVariantKey", tostring(itemID) .. ":base")
end


-- Race-guarded note editbox (hygiene A4 -- Decor item notes + Acquisition
-- vendor notes shared this control flow verbatim). The binding-driven SetText
-- lands a frame AFTER the selected id flips, so a hooksecurefunc stamps which
-- id's note the box is DISPLAYING; OnTextChanged skips when the displayed id
-- no longer matches the selection (else a fast selection switch writes one
-- entity's note onto another). getSelectedID returns the current id;
-- clearAction/setAction are ACTION NAMES; idField keys the payload.
--
-- The stamp lives on the captured `noteBox`, NEVER on the handler's `self`: a
-- multiline box forwards OnTextChanged to its inner EditBox (UI.EditBox), so
-- `self` inside the handler is not the frame SetText was hooked on. Keyed on
-- `self`, the stamp reads nil forever and the guard below never fires.
function Mech.WireNoteBox(noteBox, getSelectedID, idField, clearAction, setAction)
    if not (noteBox and noteBox.SetScript) then return end  -- exception(boundary): widget may be absent in this window
    noteBox._lastBoundNoteID = nil
    if not noteBox._setTextHooked then
        hooksecurefunc(noteBox, "SetText", function()
            noteBox._lastBoundNoteID = getSelectedID()
        end)
        noteBox._setTextHooked = true
    end
    noteBox:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local id = getSelectedID()
        if not id then return end
        if noteBox._lastBoundNoteID ~= nil and noteBox._lastBoundNoteID ~= id then return end  -- selection switch in progress
        local text = (self.GetText and self:GetText()) or ""
        if text == "" then
            Mech.DispatchNamed(clearAction, { [idField] = id })
        else
            Mech.DispatchNamed(setAction, { [idField] = id, text = text })
        end
    end)
end

-- Resolve a Projects target house then invoke onPick(houseID, houseName): the
-- only owned house goes straight through; 2+ show a titled chooser menu (the
-- Alliance/Horde picker) anchored on `owner`. Returns false without calling
-- onPick when there are no houses -- the caller surfaces its own "visit a house
-- first" message (each uses a different channel). Shared by the Layouts importer
-- and the Blueprints "Open in Architect" flow (hygiene A19).
function Mech.PromptHouseTarget(owner, title, onPick)
    local houses = HDG.Selectors:Call("projects.houseMenuItems", Mech.GetState(), {})
    if #houses == 0 then return false end
    if #houses == 1 then onPick(houses[1].value, houses[1].text); return true end
    local menu = { { isTitle = true, text = title } }
    for _, h in ipairs(houses) do
        local hid, hname = h.value, h.text
        menu[#menu + 1] = { text = h.text, callback = function() onPick(hid, hname) end }
    end
    HDG.UI.ShowMenu(owner, menu)
    return true
end
