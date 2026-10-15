-- HDG.DecorController
-- ============================================================================
-- Decor browser: filter strip (top chips, toggles, search, tag slots),
-- decorRow factory, note editbox, variant swatches, wishlist + destroy dialog.

HDG = HDG or {}
HDG.DecorController = HDG.DecorController or {}

local DecorController = HDG.DecorController
local CH = HDG.ControllerHelpers

-- ===== Row factory ==========================================================
-- [fav 14x14] [name] ... [dye dots] [collected 12x12] [owned-count 22w (craftable star underlaid top-right)]
-- MakeRowFactory row: layout builds texture children; paint writes per-paint values.

local ATLAS_FAV_FILLED   = "delves-scenario-heart-icon"        -- ships pre-tinted red
local ATLAS_CHECK        = "common-icon-checkmark"
local ATLAS_CRAFT_STAR   = "auctionhouse-icon-favorite-off"    -- outline variant; accepts SetVertexColor (filled = baked gold)

-- ===== decorRowFactory primitives ============================================

local function _layoutDecorRow(row)
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.DecorRow)

    local fav = row:CreateTexture(nil, "OVERLAY")
    fav:SetSize(14, 14)
    fav:SetPoint("LEFT", row, "LEFT", 4, 0)
    fav:SetAtlas(ATLAS_FAV_FILLED)
    row._favStar = fav

    -- Owned-count column: always-on, hard right, right-aligned + tabular so digits line
    -- up down the list. The craftable star underlays its top-right corner (below).
    local storedFs = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(storedFs, "small")
    HDG.Theme:Register(storedFs, "Text")
    storedFs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    storedFs:SetWidth(22)
    storedFs:SetJustifyH("RIGHT")
    storedFs:SetDrawLayer("OVERLAY", 3)   -- ON TOP of the underlaid craftable star (sublevel 1)
    storedFs:SetShadowColor(0, 0, 0, 1)   -- dark halo keeps digits legible over the star
    storedFs:SetShadowOffset(1, -1)
    row._storedCountFs = storedFs

    local name = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(name, "subheading")
    HDG.Theme:Register(name, "Text")
    name:SetPoint("LEFT",  fav, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -44, 0)
    name:SetJustifyH("LEFT")
    row._nameFs = name

    -- Collected check (just left of the count column)
    local check = row:CreateTexture(nil, "OVERLAY")
    check:SetSize(12, 12)
    check:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    check:SetAtlas(ATLAS_CHECK)
    row._checkIcon = check

    -- Craftable star: small, tucked into the count column's top-right corner so it no
    -- longer eats its own slot -- the count number reads below-left of it.
    local star = row:CreateTexture(nil, "OVERLAY")
    star:SetSize(9, 9)
    -- Top-LEFT of the count column: a right-aligned number leaves the left side empty
    -- (esp. 1-2 digits), so the star tucks up there clear of the digits. Count column
    -- left edge is row-right -26 (RIGHT -4, width 22); star's right edge sits at -17.
    star:SetPoint("TOPRIGHT", row, "TOPRIGHT", -17, -1)
    star:SetDrawLayer("OVERLAY", 1)                       -- behind the count number, for wide (3-digit) counts
    star:SetAtlas(ATLAS_CRAFT_STAR)
    row._craftStar = star

    -- Dye droplets (up to 3): NOT Theme:Register'd (the dye color IS the color; a skinner would clobber it).
    row._droplets = {}
    for i = 1, 3 do
        local d = row:CreateTexture(nil, "OVERLAY")
        d:SetSize(8, 10)
        d:SetAtlas("dye-drop_32")
        d:Hide()
        row._droplets[i] = d
    end
end

-- Favourite heart (left edge) + owned-count (right column) -- now independent. The count
-- shows for any owned copies in EVERY mode, so browsing shows "how many" too, not just
-- Destroy mode. A blank count means 0 in storage, not "unowned" (the check covers ownership).
local function _paintFavAndCount(row, ed)
    if row._favStar then
        if ed.isFavorite then row._favStar:Show() else row._favStar:Hide() end
    end
    if row._storedCountFs then
        local c = ed.destroyableCount or 0  -- exception(boundary): sparse decor struct field
        if c > 0 then
            row._storedCountFs:SetText(tostring(c))
            row._storedCountFs:Show()
        else
            row._storedCountFs:Hide()
        end
    end
end

-- Collected checkmark from ed.isCollected (canonical predicate via decor.isCollected).
local function _paintCheckmark(row, ed)
    if not row._checkIcon then return end
    if ed.isCollected then row._checkIcon:Show() else row._checkIcon:Hide() end
end

-- Name: uncollected -> accent, collected -> normal text. ed.name stays raw for search/toasts.
local function _paintName(row, ed)
    if not row._nameFs then return end
    row._nameFs:SetText(HDG.Theme:CollectionLabel(ed.isCollected, ed.name))
end

-- Dye droplets: ed.dyeColorIDs is the flat channel-ordered list (sparse 0/1/2, bake-collapsed).
-- Tinted via swatchColorStart; name right bound tightened to reserve the droplet zone.
local function _paintDroplets(row, ed)
    local ids = ed.dyeColorIDs
    local n   = (ids and #ids) or 0
    for i = 1, 3 do
        local d = row._droplets[i]
        local dyeColorID = ids and ids[i]
        if dyeColorID then
            d:ClearAllPoints()
            d:SetPoint("RIGHT", row, "RIGHT", -44 - (i - 1) * 9, 0)
            local info = HDG.HousingCatalogObserver:GetDyeColorInfo(dyeColorID)
            if info and info.swatchColorStart then
                HDG.UI._TintTexture(d, info.swatchColorStart); d:SetAlpha(1)  -- data: the dye's actual swatch color (runtime)
            else
                HDG.UI._TintTexture(d, { r = 1, g = 1, b = 1 }); d:SetAlpha(0.2)  -- data: no dye -> blank swatch
            end
            d:Show()
        else
            d:Hide()
        end
    end
    -- Reserve name space when droplets present (-34 default; -34 each paint is
    -- a harmless no-op for the common non-variant row).
    row._nameFs:SetPoint("RIGHT", row, "RIGHT", n > 0 and (-44 - n * 9 - 2) or -44, 0)
end

-- Left = select, right = favorite toggle. Toast reads state BEFORE dispatch (sync Store; order matters).
local function _wireDecorClicks(row, ed)
    local itemID = ed.itemID
    if not itemID then
        HDG.UI.WireLeftRightClick(row, nil, nil)
        return
    end
    local variantKey = ed.variantKey
    HDG.UI.WireLeftRightClick(row,
        function()
            -- Ctrl-click queues the item's recipe (decor rows carry no recipeID,
            -- so resolve it via the Professions reverse index); non-craftable
            -- decor toasts a "no recipe" note instead. Shift-click links the item
            -- in chat (active editbox, or opens chat). A plain click selects.
            -- Ctrl-Shift-click destroys one stored copy of THIS row's variant with
            -- no dialog (Soul, Discord 2026-09-19: "hover, hold ctrl+shift and
            -- brrrr"). Checked first: it is also a Ctrl-click.
            if IsControlKeyDown() and IsShiftKeyDown() then
                DecorController:_DestroyOneFromRow(itemID, variantKey, ed.name)
                return
            end
            if IsControlKeyDown() then
                local rid = HDG.StaticData.Recipes:Get(itemID) and itemID
                if rid then
                    HDG.UI.QueueRecipe(rid, itemID, ed.name)
                else
                    HDG.Log:Info("queue", ed.name .. " has no recipe")
                end
                return
            end
            if IsShiftKeyDown() then
                HDG.UI.LinkItem(itemID)
                return
            end
            -- selectedItemID drives the detail pane (base item data); the
            -- separate selectedVariantKey drives the list highlight + the dyed
            -- model preview (which specific owned variant was clicked).
            CH.Mechanics.SetUITransientView("decor", "selectedItemID", itemID)
            CH.Mechanics.SetUITransientView("decor", "selectedVariantKey", variantKey)
        end,
        function()
            local wasFav = HDG.Store:GetState().account.favorites[itemID]  -- exception(false-positive): top-level controller read
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.FAVORITE_TOGGLE,
                payload = { itemID = itemID },
            })
            HDG.Log:Info("decor_action",
                (wasFav and "Unfavorited: " or "Favorited: ") .. ((ed and ed.name) or "item"))
        end)
end

local function _paintDecorRow(row, ed)
    row._itemID, row._name = ed.itemID, ed.name   -- R2 tooltip stamps
    _paintName(row, ed)
    _paintDroplets(row, ed)
    _paintFavAndCount(row, ed)
    _paintCheckmark(row, ed)
    if row._craftStar then
        HDG.UI:PaintCraftStar(row._craftStar, ed.craftableState,
            HDG.Constants.RECIPE_STATE.NotARecipe)
    end
end

HDG.Rows:Register("decorRow", {
    font    = "body",
    height  = 24,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutDecorRow,
        paint      = _paintDecorRow,
        laidOutTag = "_decorLaidOut",
        selectable = true,
        wire       = _wireDecorClicks,
        resetText  = { "_nameFs" },
        reset      = function(row)
            row._itemID, row._name = nil, nil  -- clear R2 tooltip stamps
            if row._favStar   then row._favStar:Hide()   end
            if row._checkIcon then row._checkIcon:Hide() end
            if row._craftStar then row._craftStar:Hide() end
            -- pre-layout: _droplets nil until _layoutDecorRow runs on a fresh slot.
            if row._droplets then for i = 1, 3 do row._droplets[i]:Hide() end end
        end,
    }),
    -- variantKey = itemID:<variant>|base (stamped by decor.items); itemID alone collides for variant rows.
    key     = function(ed) return ed.variantKey end,
})

-- ===== Controller lifecycle ==================================================

-- ===== Destroy stored-copies dialog =========================================
-- Custom modal with a stepper from 1 to every stored copy:
-- -100 / -10 / - / qty / + / +10 / +100. Asked for on Discord (2026-09-19):
-- clearing 49 copies was 48 clicks, and Soul has 3000 small tiles to clear. The
-- old 99 ceiling went with it -- a 3000-copy stack could never be emptied.
-- DestroyEntry's destroyAll flag is documented as "deletes all entries within the
-- stack", but Blizzard's own storage menu labels it "Destroy (5)"
-- (Blizzard_HousingCatalogEntry.lua bulkDestroyAmount) -- unverified which, so
-- every copy is its own call. The run belongs to Modules/HDGR_DestroyQueue.lua,
-- which paces the calls and counts a copy only when the item's owned total
-- confirms it (a 101-copy burst once kept 22 while the client counted all 101).
-- The dialog stays open on the confirmed done/total counter, with Cancel turned
-- into Stop, until the run ends.
-- Destruction is irreversible; layered guards:
--   1. Show: refuse without valid entryID + count.
--   2. Show: max = destroyableInstanceCount (the per-variant stored copies).
--   3. Steps: clamp into 1..max before mutating qty.
--   4. Render: refreshDestroyDialog re-clamps qty each paint.
--   5. Click: snapshot entryID/name/q into locals (HOUSING_STORAGE_ENTRY_UPDATED
--      dispatches synchronously inside DestroyEntry -- can't read stale state).
--   6. Click: type-validate q; math.floor.
--   7. Click: re-resolve live destroyable count; clamp DOWN only.
--   8. Click: disable Destroy button for the run (double-click guard).
--   9. Run: pcall each DestroyEntry; the first error stops sending (DestroyQueue).
--  10. Hide: stops a run in progress, then clears entryID + name.

local _destroyDialog
local _destroyState = { qty = 1, max = 1, entryID = nil, name = nil, itemID = nil, variantKey = nil }

-- Snapshot destroy params; returns nil on any invalid input (destruction must not proceed ambiguously).
local function validateDestroyArgs(entryID, q, max)
    if entryID == nil then return nil end
    if type(q)   ~= "number" or q ~= q then return nil end   -- nil / NaN
    if type(max) ~= "number" or max < 1 then return nil end
    q = math.floor(q)
    if q < 1 then return nil end
    if q > max then q = max end
    return q
end

-- One stepper button, placed by its offset from the quantity in the middle.
local function _stepperButton(row, label, font, width, xOffset)
    local b = HDG.UI:Button(row, label, font)
    b._hdgrVariant = "tertiary"
    HDG.Theme:Register(b, "Button")
    b:SetSize(width, 32)
    b:ClearAllPoints()
    b:SetPoint("CENTER", row, "CENTER", xOffset, 0)
    return b
end

local function buildDestroyDialog()
    local f = CreateFrame("Frame", "HDGR_DestroyConfirmDialog", _G.UIParent, "BackdropTemplate")   -- exception(boundary): UIParent strata; global name for WoW frame-stacking
    f:SetSize(440, 320)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- The Frame skinner paints surface.panel + border.default via
    -- setBackdrop (Theme.lua:253). HDG.UI:CopyDialog uses the same.
    -- There is no "Panel" skinner registered -- that silently no-ops.
    HDG.Theme:Register(f, "Frame")
    f:Hide()

    f.titleFs = f:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(f.titleFs, "heading")
    HDG.Theme:Register(f.titleFs, "Text")
    f.titleFs:SetPoint("TOP", 0, -18)
    f.titleFs:SetWidth(400)
    f.titleFs:SetJustifyH("CENTER")
    f.titleFs:SetSpacing(2)

    f.bigWarnFs = f:CreateFontString(nil, "OVERLAY")   -- semantic.error; destructive-action emphasis
    HDG.UI.applyFontRole(f.bigWarnFs, "subheading")
    HDG.Theme:Register(f.bigWarnFs, "Text")
    f.bigWarnFs:SetPoint("TOP", f.titleFs, "BOTTOM", 0, -16)
    f.bigWarnFs:SetWidth(400)
    f.bigWarnFs:SetJustifyH("CENTER")

    -- Sub note: friendly elaboration on the irreversibility.
    f.subNoteFs = f:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(f.subNoteFs, "body")
    HDG.Theme:Register(f.subNoteFs, "TextDim")
    f.subNoteFs:SetPoint("TOP", f.bigWarnFs, "BOTTOM", 0, -6)
    f.subNoteFs:SetWidth(400)
    f.subNoteFs:SetJustifyH("CENTER")
    f.subNoteFs:SetSpacing(2)

    -- Stepper row: anchored from BOTTOM so position is fixed regardless of warning text wrap.
    local stepperRow = CreateFrame("Frame", nil, f)
    stepperRow:SetSize(380, 32)
    stepperRow:SetPoint("BOTTOM", 0, 76)
    f.stepperRow = stepperRow

    f.minus100Btn = _stepperButton(stepperRow, "-100", "body", 50, -162)
    f.minus10Btn  = _stepperButton(stepperRow, "-10",  "body", 44, -106)
    f.minusBtn    = _stepperButton(stepperRow, "-",    "heading", 32, -56)

    f.qtyFs = stepperRow:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(f.qtyFs, "heading")
    HDG.Theme:Register(f.qtyFs, "Text")
    f.qtyFs:SetPoint("CENTER", stepperRow, "CENTER", 0, 0)
    f.qtyFs:SetWidth(200)   -- wide enough for a run's "3000/3000" counter
    f.qtyFs:SetJustifyH("CENTER")

    f.plusBtn    = _stepperButton(stepperRow, "+",    "heading", 32, 56)
    f.plus10Btn  = _stepperButton(stepperRow, "+10",  "body", 44, 106)
    f.plus100Btn = _stepperButton(stepperRow, "+100", "body", 50, 162)

    f.stepperMaxFs = f:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(f.stepperMaxFs, "small")
    HDG.Theme:Register(f.stepperMaxFs, "TextDim")
    f.stepperMaxFs:SetPoint("TOP", stepperRow, "BOTTOM", 0, -4)
    f.stepperMaxFs:SetWidth(400)
    f.stepperMaxFs:SetJustifyH("CENTER")

    f.destroyBtn = HDG.UI:Button(f, "Destroy", "body")
    f.destroyBtn._hdgrVariant = "tertiary"
    f.destroyBtn._textTone = "error"
    HDG.Theme:Register(f.destroyBtn, "Button")
    f.destroyBtn:SetSize(140, 30)
    f.destroyBtn:SetPoint("BOTTOMLEFT", 50, 24)

    f.cancelBtn = HDG.UI:Button(f, "Cancel", "body")
    f.cancelBtn._hdgrVariant = "tertiary"
    HDG.Theme:Register(f.cancelBtn, "Button")
    f.cancelBtn:SetSize(140, 30)
    f.cancelBtn:SetPoint("BOTTOMRIGHT", -50, 24)
    -- Hiding stops a run (OnHide below), so Cancel and Stop are the same click.
    f.cancelBtn:SetScript("OnClick", function() f:Hide() end)

    -- OnHide: stop any run in progress, then clear state + re-enable Destroy
    -- (prevents stale reuse by a future Show). A dialog hidden by anything --
    -- Cancel/Stop, or the whole UI toggled off -- must not keep destroying out
    -- of sight with no Stop button on screen.
    f:SetScript("OnHide", function()
        HDG.DestroyQueue:Stop()
        _destroyState.itemID     = nil
        _destroyState.variantKey = nil
        _destroyState.entryID    = nil
        _destroyState.name    = nil
        _destroyState.qty     = 1
        if f.destroyBtn and f.destroyBtn.SetEnabled then
            f.destroyBtn:SetEnabled(true)
        end
    end)

    return f
end

-- The six step buttons, shown for choosing and hidden while a run counts.
local function _stepButtons(f)
    return { f.minus100Btn, f.minus10Btn, f.minusBtn, f.plusBtn, f.plus10Btn, f.plus100Btn }
end

-- Choosing: "Destroy N copies of <Name>?" over the stepper.
local function _paintDestroyStepper(f, st)
    -- Coerce garbage state: shouldn't happen via Show/+/- paths but guards future callers.
    if type(st.qty) ~= "number" then st.qty = 1 end
    if type(st.max) ~= "number" or st.max < 1 then st.max = 1 end
    if st.qty < 1       then st.qty = 1       end
    if st.qty > st.max  then st.qty = st.max  end
    f.titleFs:SetText(string.format("Destroy %d %s of\n%s%s|r?",
        st.qty, st.qty == 1 and "copy" or "copies",
        HDG.Theme:ColorCode("semantic.accent"), st.name or "this decor"))
    f.subNoteFs:SetText(
        "Destroyed decor is gone permanently.\n" ..
        "If this was a mistake, Vamoose is very sorry -- there is nothing he can do.")
    f.qtyFs:SetText(tostring(st.qty))
    f.stepperMaxFs:SetText(string.format("of %d stored %s", st.max, st.max == 1 and "copy" or "copies"))
    local canDown, canUp = st.qty > 1, st.qty < st.max
    for i, b in ipairs(_stepButtons(f)) do   -- first three step down, last three up
        b:Show()
        if i <= 3 then b:SetEnabled(canDown) else b:SetEnabled(canUp) end
    end
    f.destroyBtn:Show()
    f.cancelBtn:SetText("Cancel")
end

-- Running: the counter replaces the stepper, Destroy goes, and Cancel becomes
-- Stop. While the server has paused taking destroys the note says so -- a
-- counter standing still for seconds otherwise reads as stuck.
local function _paintDestroyProgress(f, run)
    f.titleFs:SetText(string.format("Destroying %d %s of\n%s%s|r",
        run.total, run.total == 1 and "copy" or "copies",
        HDG.Theme:ColorCode("semantic.accent"), run.name))
    if run.waiting then
        f.subNoteFs:SetText(HDG.Theme:ColorCode("semantic.warning") ..
            "The game has paused destroys for a moment.|r\nHDG keeps trying every few seconds -- Stop ends the run.")
    else
        f.subNoteFs:SetText("Stop ends the run. Copies already destroyed stay destroyed.")
    end
    f.qtyFs:SetText(string.format("%d/%d", run.done, run.total))
    f.stepperMaxFs:SetText("destroyed so far")
    for _, b in ipairs(_stepButtons(f)) do b:Hide() end
    f.destroyBtn:Hide()
    f.cancelBtn:SetText("Stop")
end

local function refreshDestroyDialog()
    if not _destroyDialog then return end
    local f = _destroyDialog
    -- The warning is coloured error so the hierarchy reads loud-then-quiet.
    f.bigWarnFs:SetText(HDG.Theme:ColorCode("semantic.error") .. "WARNING: This cannot be undone.|r")
    local run = HDG.Selectors:Call("decor.destroyProgress", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read, not a row factory
    if run then
        _paintDestroyProgress(f, run)
    else
        _paintDestroyStepper(f, _destroyState)
    end
end

-- ===== Destroy runs (Modules/HDGR_DestroyQueue.lua) =========================
-- The queue sends and confirms. This controller starts runs, paints the dialog
-- from session.destroying, and when a run ends clears a selection it emptied and
-- closes the dialog. DecorController._destroyTarget = the row the running
-- destroy belongs to, for that selection rule.

-- Did the run empty the very row that is selected? Only then does the
-- selection go: an emptied row drops out of the Stored list, and the row taking
-- its place would read as selected. Another item, another variant of the same
-- item, or copies left over (a Ctrl-Shift-click taking one of five) are the
-- player's selection to keep -- and a run outlasts the click by seconds.
local function _emptiedSelectedRow(target)
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller read, not a row factory
    if HDG.Selectors:Call("decor.selectedItemID", state, {}) ~= target.itemID then return false end
    if HDG.Selectors:Call("decor.selectedVariantKey", state, {}) ~= target.variantKey then return false end
    local _, left = HDG.Selectors:Call("decor.destroyTarget", state, {})(target.itemID, target.variantKey)
    return (left or 0) == 0  -- exception(nullable): no catalog row left = nothing left
end

-- Hold the Destroy decor list still from its first destroy on: it sorts by
-- stored count, and a re-sort after each destroy slides a different row under
-- the cursor. Pins the counts the list is sorted by right now, before this
-- destroy moves them; leaving the tab lets it re-sort (DECOR_PIN_STORED_SORT).
local function _pinStoredSort()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller read, not a row factory
    if HDG.Selectors:Call("decor.pinnedSortCounts", state, {}) then return end   -- pinned since the player came to the tab
    local counts = {}
    for _, row in ipairs(HDG.Selectors:Call("decor.items", state, {})) do
        counts[row.variantKey] = row.destroyableCount
    end
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.DECOR_PIN_STORED_SORT, payload = { counts = counts } })
end

-- target = { entryID, name, itemID, variantKey }. Starts a run, or adds to the
-- running one for the same row. False, with a message, while another row's runs.
function DecorController:_StartDestroy(target, count)
    _pinStoredSort()
    if not HDG.DestroyQueue:Start(target, count) then
        HDG.Log:Info("decor_action", "Another destroy is still running -- let it finish or Stop it")
        return false
    end
    self._destroyTarget = target
    return true
end

-- The run ended (session.destroying went nil): clear a selection it emptied and
-- close the dialog. Hiding the dialog re-enters OnHide -> DestroyQueue:Stop,
-- which finds no run and does nothing.
function DecorController:_OnDestroyEnded()
    local target = self._destroyTarget
    self._destroyTarget = nil
    if target and _emptiedSelectedRow(target) then
        CH.Mechanics.SetUITransientView("decor", "selectedItemID", nil)
        CH.Mechanics.SetUITransientView("decor", "selectedVariantKey", nil)
    end
    if _destroyDialog then _destroyDialog:Hide() end
end

-- DECOR_DESTROY_PROGRESS: repaint while the run goes; tidy up once it ends. A
-- frame later, because tidying up dispatches, and a dispatch may not run nested
-- inside another action's subscriber.
function DecorController:_OnDestroyProgress(payload)
    if payload.total then return refreshDestroyDialog() end
    C_Timer.After(0, function() DecorController:_OnDestroyEnded() end)
end

-- Subscribed at file load, like the quantity picker's: a Ctrl-Shift-click run
-- has no dialog, and its end still has to be handled whether or not the main
-- window was ever built.
HDG.Store:Subscribe(function(actionType, _, action)
    if actionType == HDG.Constants.ACTIONS.DECOR_DESTROY_PROGRESS then
        DecorController:_OnDestroyProgress(action.payload)
    end
end)

-- The browser's Ctrl-Shift-click: one copy of the clicked row's own variant, no
-- dialog. Same gate as the Destroy button (Stored filter on), the same target
-- rule (decor.destroyTarget) and the same queue, so it logs and confirms the same
-- way. Clicking faster than the game confirms adds to the running destroy for
-- that row; another row's run refuses it.
function DecorController:_DestroyOneFromRow(itemID, variantKey, name)
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    if HDG.Selectors:Call("decor.onlyStored", state, {}) ~= true then
        HDG.Log:Info("decor_action", "Turn on the Destroy decor filter to destroy from the list")
        return
    end
    if not HDG.Selectors:Call("decor.isStored", state, {})(itemID) then return end   -- nothing stored, or a unique trophy
    local entryID, count = HDG.Selectors:Call("decor.destroyTarget", state, {})(itemID, variantKey)
    if not entryID or count < 1 then return end   -- exception(nullable): this variant has no stored copy
    self:_StartDestroy({ entryID = entryID, name = name, itemID = itemID, variantKey = variantKey }, 1)
end

-- Move the quantity by `delta`, clamped into 1..max: a +10 near the top lands on
-- max rather than refusing, so the tens are always one click from either end.
local function _stepDestroyQty(delta)
    local st = _destroyState
    st.qty = math.max(1, math.min(st.max, st.qty + delta))
    refreshDestroyDialog()
end

local function ShowDestroyStepperDialog(sel)
    if type(sel) ~= "table" then return end
    local entryID = sel.entryID
    local name    = sel.name or "this decor"
    -- Guard: nothing destroyable -> refuse. Belt-and-braces with decor.showDestroyButton binding.
    local liveMax = math.floor(sel.destroyableInstanceCount or 0)
    if not entryID or liveMax < 1 then return end

    if not _destroyDialog then _destroyDialog = buildDestroyDialog() end
    local f  = _destroyDialog
    -- A run is going: bring its counter back rather than start a second one.
    -- Paint first: a run started by Ctrl-Shift-click never painted this dialog,
    -- and an old paint shows a live Destroy button whose click would Stop the run.
    if HDG.DestroyQueue:IsRunning() then refreshDestroyDialog(); f:Show(); f:Raise(); return end
    local st = _destroyState
    st.max     = liveMax
    st.qty     = 1
    st.entryID = entryID
    st.name    = name
    st.itemID  = sel.itemID
    -- The dialog destroys the selected row's variant (decor.selectedItem ->
    -- decor.destroyTarget), so the run remembers which row that was.
    st.variantKey = HDG.Selectors:Call("decor.selectedVariantKey", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read, not a row factory

    f.minus100Btn:SetScript("OnClick", function() _stepDestroyQty(-100) end)
    f.minus10Btn:SetScript("OnClick",  function() _stepDestroyQty(-10)  end)
    f.minusBtn:SetScript("OnClick",    function() _stepDestroyQty(-1)   end)
    f.plusBtn:SetScript("OnClick",     function() _stepDestroyQty(1)    end)
    f.plus10Btn:SetScript("OnClick",   function() _stepDestroyQty(10)   end)
    f.plus100Btn:SetScript("OnClick",  function() _stepDestroyQty(100)  end)
    f.destroyBtn:SetScript("OnClick", function()
        local q = validateDestroyArgs(_destroyState.entryID, _destroyState.qty, _destroyState.max)
        if not q then f:Hide(); return end
        -- q is already clamped to the per-variant numStored (max). We deliberately do NOT
        -- re-gate on GetCatalogEntryInfo(entryID).destroyableInstanceCount: on the base/undyed
        -- (vid=0) entry that field is an off-by-one AGGREGATE, which would leave the last undyed
        -- copy undestroyable. Any stale over-count is absorbed by DestroyEntry's graceful no-op.
        f.destroyBtn:SetEnabled(false)   -- guard 8: double-click guard for the run
        -- The run copies what it needs, so the synchronous storage events it fires
        -- cannot read half-updated dialog state.
        DecorController:_StartDestroy({ entryID = _destroyState.entryID, name = _destroyState.name,
            itemID = _destroyState.itemID, variantKey = _destroyState.variantKey }, q)
    end)
    refreshDestroyDialog()
    f:Show(); f:Raise()
end

local function SetTopFilter(value)
    -- per ADR-018: 'all' -> UI_FILTER_RESET (atomic clear); others -> DECOR_SET_TOP_FILTER (preserves toggles + search).
    if value == "all" then
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.UI_FILTER_RESET,
            payload = { tab = "decor" },
        })
    else
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.DECOR_SET_TOP_FILTER,
            payload = { value = value },
        })
    end
end

-- Keyboard nav: host:SelectByArrow handles selection + ScrollToElementData.

function DecorController:Wire(rootFrame)
    local searchBox = HDG.UI.WireSearchBox(rootFrame, "decorPanel.search", "decor", "searchQuery")

    self:_wireListBox(rootFrame)

    -- Top filter chips (SSoT: HDG.Constants.TOP_FILTERS used by both LayoutConfig and here).
    for _, entry in ipairs(HDG.Constants.TOP_FILTERS or {}) do
        local captured = entry.value
        HDG.UI.OnClick(rootFrame, "decorPanel.topFilter_" .. captured, function()
            SetTopFilter(captured)
        end)
    end

    self:_wireTagSlots(rootFrame)

    -- Right-side toggles
    HDG.UI.OnClick(rootFrame, "decorPanel.onlyUncollectedToggle", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.DECOR_TOGGLE_ONLY_UNCOLLECTED })
    end)
    HDG.UI.OnClick(rootFrame, "decorPanel.onlyStoredToggle", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.DECOR_TOGGLE_ONLY_STORED })
    end)

    -- Reset: atomic clear via UI_FILTER_RESET (mirrors the 'all' chip).
    HDG.UI.OnClick(rootFrame, "decorPanel.resetFilters", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.UI_FILTER_RESET,
            payload = { tab = "decor" },
        })
        if searchBox and searchBox.SetText then searchBox:SetText("") end
    end)

    self:_wireNoteBox(rootFrame)

    -- Destroy button: opens the stepper dialog.
    local destroyBtn = HDG.UI.W(rootFrame, "decorDetailPanel.destroyBtn")
    if destroyBtn and destroyBtn.SetScript then
        destroyBtn:SetScript("OnClick", function()
            local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
            local sel = HDG.Selectors:Call("decor.selectedItem", state, {})
            if not (sel and sel.entryID and (sel.destroyableInstanceCount or 0) > 0) then return end
            ShowDestroyStepperDialog(sel)
        end)
    end

    self:_wireCart(rootFrame)
    self:_wireVendorNav(rootFrame)
    self:_wireVendorHyperlink(rootFrame)
end

-- ===== Wire sub-wirings (extracted from DecorController:Wire) ===============

-- |Hhdgrvendor:<npcID>|h click: route to this vendor in Acquire (vendor view).
-- Closes the #1 cross-tab journey (UX review 2026-06-10): source line -> vendor.
local function _parseVendorLink(link)
    local kind, payload = strsplit(":", link or "", 2)
    if kind ~= "hdgrvendor" or not payload or payload == "" then return nil end
    return tonumber(payload)
end

function DecorController:_wireVendorHyperlink(rootFrame)
    local sourceLabel = HDG.UI.W(rootFrame, "decorDetailPanel.itemSource")
    local hyperHost   = sourceLabel and sourceLabel.GetParent and sourceLabel:GetParent()
    if not (hyperHost and hyperHost.SetHyperlinksEnabled) then return end  -- exception(false-positive): mock-fidelity guard (mirrors acq hdgrach wiring)
    hyperHost:EnableMouse(true)
    hyperHost:SetHyperlinksEnabled(true)
    hyperHost:SetScript("OnHyperlinkClick", function(_, link)
        local npcID = _parseVendorLink(link)
        if not npcID then return end
        -- One code path with the zone scanner + shopping list jumps: filter
        -- reset, vendor mode, the full SelectVendor stamp (this used to set only
        -- selectedNpcID, so the previous vendor's item selection survived the jump).
        CH.Mechanics.JumpToVendor(npcID, nil, nil)
    end)
    hyperHost:SetScript("OnHyperlinkEnter", function(self, link)
        if not _parseVendorLink(link) then return end
        HDG.TooltipEngine:Show(self, {
            anchor     = "ANCHOR_CURSOR",
            extraLines = {
                { text = "Click to view this vendor in Acquire", r = 0.7, g = 0.7, b = 0.7 },
            },
        })
    end)
    hyperHost:SetScript("OnHyperlinkLeave", function() HDG.TooltipEngine:Hide() end)
end

-- List box: arrow-key navigation + SelectionBehaviorMixin store-sync.
function DecorController:_wireListBox(rootFrame)
    local listBox = HDG.UI.W(rootFrame, "decorPanel.list")
    if listBox and listBox.EnableKeyboard then
        listBox:EnableKeyboard(true)
        listBox:SetScript("OnKeyDown", function(self, key)
                if key ~= "UP" and key ~= "DOWN" then
                    self:SetPropagateKeyboardInput(true)
                    return
                end
                self:SetPropagateKeyboardInput(false)
                local ed = self.SelectByArrow and self:SelectByArrow(key)
                if ed and ed.itemID then
                    CH.Mechanics.SetUITransientView("decor", "selectedItemID", ed.itemID)
                    CH.Mechanics.SetUITransientView("decor", "selectedVariantKey", ed.variantKey)
                end
            end)
    end

    -- SelectionBehaviorMixin sync. Highlight syncs on variantKey (variant rows share an itemID).
    if listBox and listBox.WireStoreSelectionSync then
        listBox:WireStoreSelectionSync("session.ui.decor.selectedVariantKey",
            function(ed, key) return key ~= nil and ed.variantKey == key end)
    end
end

-- Tag chip slots: click reads decor.tagsForFilter at click-time (live slot text).
-- Dynamic tag-chip tooltips. Tag slots are pooled (the live sub-tag list maps
-- onto fixed slots), so the def is a FUNCTION resolved live at hover -- it keys
-- off the slot's CURRENT tag. Only tags in TAG_TOOLTIP_RECIPE get a tip.
local TAG_TOOLTIP_RECIPE = { Redeemable = "RedeemableTag" }
local function _makeTagTooltipDef(slot)
    return function()
        -- exception(false-positive): top-level controller def fn (not a row factory)
        -- Strict: decor.tagsForFilter returns a table on every branch.
        local tags = HDG.Selectors:Call("decor.tagsForFilter", HDG.Store:GetState(), {})
        local name = tags[slot] and TAG_TOOLTIP_RECIPE[tags[slot]]
        return name and { recipe = name } or nil
    end
end

function DecorController:_wireTagSlots(rootFrame)
    for slot = 1, (HDG.Constants.TAG_SLOT_COUNT or 12) do
        local captured = slot
        -- Dynamic tooltip: shows the Redeemable explainer when this slot holds it.
        HDG.TooltipEngine:Attach(
            HDG.UI.W(rootFrame, "decorPanel.tagSlot_" .. captured),
            _makeTagTooltipDef(captured))
        HDG.UI.OnClick(rootFrame, "decorPanel.tagSlot_" .. captured, function()
            local tags = HDG.Selectors:Call("decor.tagsForFilter",
                HDG.Store:GetState(), {}) or {}  -- exception(false-positive): top-level controller method (not a row factory)
            local tag = tags[captured]
            if tag then
                -- Real branch, NOT `(current==tag) and nil or tag` -- Lua 5.1 trap returns tag when equal.
                local current = HDG.Selectors:Call("decor.activeTag",
                    HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller method (not a row factory)
                local nextTag = tag
                if current == tag then nextTag = nil end
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.DECOR_SET_TAG,
                    payload = { tag = nextTag },
                })
            end
        end)
    end
end

-- (Dye-variant swatch wiring removed with the in-card variant strip. Owned
-- dyed-variant ROWS still select via selectedVariantKey in the row factory above.)

-- Note editbox: per-keystroke dispatch. Race guard: _lastBoundItemID tracks which item
-- is displayed; OnTextChanged skips when displayed item doesn't match selection.
function DecorController:_wireNoteBox(rootFrame)
    HDG.ControllerHelpers.Mechanics.WireNoteBox(
        HDG.UI.W(rootFrame, "decorDetailPanel.note"),
        function() return HDG.Store:GetState().session.ui.decor.selectedItemID end,  -- exception(false-positive): top-level controller read
        "itemID", "NOTE_CLEAR", "NOTE_SET")
end

-- + Cart: adds selected item (npcID nil) to shopping list (surfaces in Wishlist section).
function DecorController:_wireCart(rootFrame)
    HDG.UI.OnClick(rootFrame, "decorDetailPanel.cartBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local item  = HDG.Selectors:Call("decor.selectedItem", state, {})
        if not item then return end
        if state.account.activeShoppingListId == "" then
            HDG.Log:Warn("shopping",
                "No active shopping list -- open the Shopping tab to create one (decor cart)")
            return
        end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.SHOPPING_ITEM_ADD,
            payload = { itemID = item.itemID, qty = 1 },   -- npcID nil = wishlist
        })
        HDG.Log:Success("shopping",
            (item.name or "Item") .. " added to shopping list")
    end)
end

-- Show on Map / Waypoint: reuse the shared Waypoints module against the decor's map
-- vendor -- identical actions to Shop by Vendor. Buttons are ENABLED only with a mapped
-- vendor (decor.selectedItemHasVendorWaypoint), so vendorOf() is non-nil at click time.
function DecorController:_wireVendorNav(rootFrame)
    local function vendorOf()
        return HDG.Selectors:Call("decor.selectedItem", HDG.Store:GetState(), {}).vendor  -- exception(false-positive): top-level controller method (not a row factory)
    end
    HDG.UI.OnClick(rootFrame, "decorDetailPanel.showOnMapBtn", function()
        local v = vendorOf()
        HDG.Waypoints:ShowOnMap(v.mapID, v.x, v.y, v.name)
    end)
    HDG.UI.OnClick(rootFrame, "decorDetailPanel.waypointBtn", function()
        local v = vendorOf()
        HDG.Waypoints:Set(v.mapID, v.x, v.y, v.name, v.side)
    end)
end

function DecorController:Refresh(rootFrame, ctx)
    -- Bindings push values; nothing imperative needed.
end

HDG.Controllers:Register("decor", DecorController)
