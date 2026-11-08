-- HDG.HouseEditorCompanion
-- ============================================================================
-- Launcher button + decor PLACEMENT for the in-editor companion window.
-- The companion WINDOW itself is a declarative HDG.Window satellite
-- (LC.windows.companion). This module owns only the imperative pieces:
--   * launcher button (toggles companion.windowShown)
--   * companionGridCell cardGrid cell kind (decor placement click)
--   * recent-session history tracking (StartPlacingNewDecor hook)
--   * injection lifecycle (create launcher + EnsureCreated on editor-open)
-- Sidebar rows + toolbar wiring live in UI/HDGR_Controller_Companion.lua.
--
-- TAINT-SAFE INJECTION (see reference_storagepanel_taint.md):
--   The launcher + the satellite frame parent to HouseEditorFrame for the
--   visibility cascade only. We do NOT participate in StoragePanel's TabSystem
--   -- no AddNamedTab, no SetTabCallback, no hooksecurefunc on protected panels.
--   HookScript on HouseEditorFrame:OnShow is safe (additive, not replacement).
--   12.0.5 productInfo-nil race is avoided by zero contact with the storage panel.
--
-- LIFECYCLE:
--   ADDON_LOADED (filter Blizzard_HouseEditor) -> InjectShell()
--   HOUSE_EDITOR_MODE_CHANGED -> InjectShell() fallback if not yet injected.
--   OnEnable: if Blizzard_HouseEditor already loaded, InjectShell.
--   InjectShell -> create launcher + install placement hook + HookScript OnShow
--     + HDG.Window:EnsureCreated("companion") (lazy satellite, now that its
--     parent HouseEditorFrame exists). The reconciler owns visibility/position.
--   Parent cascade -> closing HouseEditor hides the launcher + the satellite.

HDG = HDG or {}
HDG.HouseEditorCompanion = HDG.HouseEditorCompanion or {}
local H = HDG.HouseEditorCompanion

H._injected = false
H._launcher = nil

local COMP = HDG.Constants.COMPANION

local CreateLauncher

-- ============================================================================
-- Grid-cell click -> place decor in the house editor.
-- ============================================================================
-- Module-scope handler (no per-cell closure allocation): reads the placement
-- payload stamped onto the cell in initFunc, validates ownership + indoor/
-- outdoor rules, then fires the housing-editor placement API. Dyed-variant
-- cells carry the variant entryID, so this places the dyed copy directly.

-- Place decor mirroring Blizzard's HousingCatalogDecorEntryMixin:TypeSpecificOnInteract.
-- 1. If not in BasicDecor mode: activate it + defer one frame (mode switch needs to settle).
-- 2. In BasicDecor: set commitNewDecorOnMouseUp=FALSE so the click attaches to cursor
--    rather than immediately committing (without this, selecting also commits -- "places immediately").
-- Editor-mode access routes through HousingObserver (owner of C_HouseEditor);
-- C_HousingBasicMode is OWNED here.
local function _placeDecor(entryID)
    local BasicDecor = _G.Enum.HouseEditorMode.BasicDecor
    if not HDG.HousingObserver:IsHouseEditorModeActive(BasicDecor) then
        HDG.HousingObserver:ActivateHouseEditorMode(BasicDecor)
        _G.RunNextFrame(function() _G.C_HousingBasicMode.StartPlacingNewDecor(entryID) end)
        return
    end
    local modeFrame = _G.HouseEditorFrame:GetActiveModeFrame()
    if modeFrame then modeFrame.commitNewDecorOnMouseUp = false end  -- click, not drag
    _G.C_HousingBasicMode.StartPlacingNewDecor(entryID)
end

-- Right-click = straight to the shopping wishlist (no menu, owner call
-- 2026-06-12; craft-queue dropped for now). Module-level so every tab's
-- grid + the recent strip share one handler.
local function _addToShopping(self)
    local itemID = self._placeItemID
    if not itemID then return end           -- room/collection cards carry no item
    local name = self._placeName or "this decor"
    if HDG.Store:GetState().account.activeShoppingListId == "" then
        HDG.Log:Notify("warn", "No active shopping list -- open the Shopping tab to create one.")
        return
    end
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_ITEM_ADD,
        payload = { itemID = itemID, qty = 1 } })
    HDG.Log:Notify("success", ('"%s" added to your shopping list.'):format(name))
end

local function _companionCellClick(self, button)
    if button == "RightButton" then return _addToShopping(self) end
    local entryID = self._placeEntryID
    if not entryID then return end          -- non-placeable cell (catalog miss)
    local name = self._placeName or "this decor"
    -- Inside/outside (via HousingObserver, owner of C_Housing) decides whether
    -- indoor-only / outdoor-only decor can be placed from where the player stands.
    local inside = HDG.HousingObserver:IsInsideHouse()
    if inside and not self._placeAllowIndoors then
        HDG.Log:Notify("warn", '"' .. name .. '" can only go outside.'); return
    elseif not inside and not self._placeAllowOutdoors then
        HDG.Log:Notify("warn", '"' .. name .. '" can only go inside.'); return
    end
    if (self._placeQty or 0) < 1 then
        HDG.Log:Notify("warn", 'No "' .. name .. '" available to place.'); return
    end
    _placeDecor(entryID)
end

-- ============================================================================
-- "Can't place here" border + tag. ed.cantHere is stamped by the selector from
-- session.house.budget.inside (HousingObserver's house tick). A cell whose decor
-- can't be placed from where the player stands (inside-only while outside, or
-- outside-only while inside) gets a warning border and an "Inside only" /
-- "Outside only" tag. 4 lazy edges in the tag's own warning colour, through the
-- theme so a scheme switch repaints both (block chars don't render -- see
-- reference_wow_color_swatches).
local function _ensurePlaceBorder(cell)
    if cell._placeBorder then return cell._placeBorder end
    local e = {}
    for i = 1, 4 do
        e[i] = cell:CreateTexture(nil, "OVERLAY")
        HDG.Theme:Register(e[i], "SectionBgTint", { token = "semantic.warning" })
    end
    e[1]:SetPoint("TOPLEFT");     e[1]:SetPoint("TOPRIGHT");     e[1]:SetHeight(2)  -- top
    e[2]:SetPoint("BOTTOMLEFT");  e[2]:SetPoint("BOTTOMRIGHT");  e[2]:SetHeight(2)  -- bottom
    e[3]:SetPoint("TOPLEFT");     e[3]:SetPoint("BOTTOMLEFT");   e[3]:SetWidth(2)   -- left
    e[4]:SetPoint("TOPRIGHT");    e[4]:SetPoint("BOTTOMRIGHT");  e[4]:SetWidth(2)   -- right
    cell._placeBorder = e
    return e
end
local function _paintPlaceBorder(cell, blocked)
    if not blocked then
        if cell._placeBorder then for _, t in ipairs(cell._placeBorder) do t:Hide() end end
        return
    end
    for _, t in ipairs(_ensurePlaceBorder(cell)) do t:Show() end
end

-- The tag: an orange pill, top-left (the recent +/- marks own top-right). Words
-- from L tiles up; smaller tiles, and a tile showing the recent marks, get the
-- budget glyph alone -- the words would run past the tile or over the marks.
local function _ensurePlaceTag(cell)
    if cell._placeTag then return cell._placeTag end
    local tag = CreateFrame("Frame", nil, cell)
    tag:SetPoint("TOPLEFT", cell, "TOPLEFT", 3, -3)
    tag:SetHeight(16)
    local bg = tag:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    HDG.Theme:Register(bg, "SectionBgTint", { token = "semantic.warning" })
    -- Dark ink on the orange fill, as the lab's tag: light text on it was unreadable.
    local ink = COMP.TAG_INK
    tag._glyph = tag:CreateTexture(nil, "ARTWORK")
    tag._glyph:SetSize(12, 12)
    tag._glyph:SetPoint("LEFT", tag, "LEFT", 2, 0)
    tag._glyph:SetVertexColor(ink.r, ink.g, ink.b, ink.a)  -- scheme-invariant: TAG_INK reads on every scheme's warning fill
    tag._text = tag:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(tag._text, "small")
    tag._text:SetTextColor(ink.r, ink.g, ink.b, ink.a)  -- scheme-invariant: TAG_INK reads on every scheme's warning fill
    tag._text:SetJustifyH("LEFT")
    tag._text:SetPoint("LEFT", tag._glyph, "RIGHT", 2, 0)
    cell._placeTag = tag
    return tag
end

local function _showsPlaceTag(ed)
    return ed.cantHere and not ed.isActionStrip
end

local function _paintPlaceTag(cell, ed, tile)
    if not _showsPlaceTag(ed) then
        if cell._placeTag then cell._placeTag:Hide() end
        return
    end
    local tag = _ensurePlaceTag(cell)
    local insideOnly = ed.allowIndoors and not ed.allowOutdoors
    tag._glyph:SetAtlas(insideOnly and "house-decor-budget-icon" or "house-decor-exteriorbudget-icon")
    local marked = (ed.placedCount or 0) > 0 or (ed.removedCount or 0) > 0  -- exception(nullable): only Recent cells carry placed / removed counts
    local words = tile >= COMP.TAG_TEXT_MIN and not marked
    tag._text:SetText(words and (insideOnly and "Inside only" or "Outside only") or "")
    tag._text:SetShown(words)
    tag:SetWidth(words and (tag._text:GetStringWidth() + 20) or 16)
    tag:Show()
end

-- Badge fonts grow with the tile. A tile between sizes (the recent strip's 56px)
-- takes the largest size that fits it.
local function _sizeKeyFor(tile)
    local key = COMP.TILE_SIZES[1]
    for _, k in ipairs(COMP.TILE_SIZES) do
        if COMP.TILE_PX[k] <= tile then key = k end
    end
    return key
end

-- Re-fonted only when the tile size changes (pooled cells keep their last).
local function _sizeBadges(cell, key)
    if cell._badgeKey == key then return end
    cell._badgeKey = key
    local h = COMP.BADGE_GLYPH[key] + 2
    cell.badge:SetFontObject(COMP.BADGE_FONT[key])
    cell.badge:SetHeight(h)
    cell.badge:ClearAllPoints()
    cell.badge:SetPoint("BOTTOMRIGHT", -5, 4)
    cell._costFs:SetFontObject(COMP.BADGE_FONT[key])
    cell._costFs:SetHeight(h)
end

-- Cost badge: top-left, since the dye mark takes Blizzard's bottom-left spot
-- (Vamoose 11-08), and on every grid tile so it never jumps between tiles.
-- Under the "can't go here" tag when that shows (its words fill an L tile's top).
-- The recent strip has no dye marks and keeps it bottom-left.
local function _anchorCost(cell, ed)
    local fs = cell._costFs
    fs:ClearAllPoints()
    if ed.isActionStrip then
        fs:SetPoint("BOTTOMLEFT", 4, 4)
    elseif _showsPlaceTag(ed) then
        fs:SetPoint("TOPLEFT", cell._placeTag, "BOTTOMLEFT", 1, -2)
    else
        fs:SetPoint("TOPLEFT", 4, -4)
    end
end

-- That place's budget icon + the cost, orange when it is more than the budget
-- has left. Gated by ed.showCost (account setting). Paint after the tag.
local function _paintCost(cell, ed, key)
    local cost = ed.placementCost
    if not (ed.showCost and cost and cost > 0) then
        cell._costFs:Hide()
        return
    end
    _anchorCost(cell, ed)
    local g = COMP.COST_GLYPH[key]
    cell._costFs:SetText(("|A:%s:%d:%d|a%d"):format(ed.costAtlas, g, g, cost))
    HDG.Theme:Register(cell._costFs, ed.overBudget and "TextWarning" or "Text")
    cell._costFs:Show()
end

-- Dye mark (bottom-left, Blizzard's art and spot, Vamoose 11-08): a palette on
-- decor you can dye that isn't dyed (ed.canCustomize), one drop per dye on a
-- dyed copy (ed.dyeColorIDs, filled slots only), painted the dye's swatch colour.
-- The palette greys with the icon on a tile you have none of, as Blizzard's.
local function _ensureDyeMark(cell)
    if cell._dyePalette then return end
    cell._dyePalette = cell:CreateTexture(nil, "OVERLAY")
    cell._dyePalette:SetAtlas("housing-dyable-palette-icon")
    cell._dyePalette:SetPoint("BOTTOMLEFT", 4, 4)
    cell._dyeDrops = {}
    for i = 1, 3 do   -- Blizzard's three dye slots
        cell._dyeDrops[i] = cell:CreateTexture(nil, "OVERLAY")
        cell._dyeDrops[i]:SetAtlas("dye-drop_32")
    end
end

local PLAIN_DROP = { r = 1, g = 1, b = 1 }   -- the drop art untinted (white)

local function _hideDyeMark(cell)
    if not cell._dyePalette then return end
    cell._dyePalette:Hide()
    for _, d in ipairs(cell._dyeDrops) do d:Hide() end
end

local function _paintDrop(d, dyeColorID, i, g)
    d:SetSize(g, g)
    d:ClearAllPoints()
    d:SetPoint("BOTTOMLEFT", 4 + (i - 1) * (g - math.floor(g * COMP.DYE_DROP_OVERLAP + 0.5)), 4)
    local info = HDG.HousingCatalogObserver:GetDyeColorInfo(dyeColorID)
    local swatch = info and info.swatchColorStart or PLAIN_DROP   -- exception(boundary): C_DyeColor nil on an id it doesn't know
    HDG.UI._TintTexture(d, swatch)   -- data: the dye's own swatch colour
    d:Show()
end

local function _paintDyeMark(cell, ed, key, greyed)
    local ids = ed.dyeColorIDs
    if not (ed.canCustomize or ids) then   -- exception(nullable): only dyed-copy cells carry dye colours
        _hideDyeMark(cell)
        return
    end
    _ensureDyeMark(cell)
    local g = COMP.BADGE_GLYPH[key]
    cell._dyePalette:SetSize(g, g)
    cell._dyePalette:SetDesaturated(greyed)
    cell._dyePalette:SetShown(ed.canCustomize == true)
    for i, d in ipairs(cell._dyeDrops) do
        if ids and ids[i] then _paintDrop(d, ids[i], i, g) else d:Hide() end
    end
end

-- Recent-activity +/- corner overlays (HDG parity): communities-chat-icon-plus
-- (blue, placed this session) over communities-chat-icon-minus (red, removed),
-- top-right, stacked when both apply. Exact counts live in the tooltip. Driven
-- by ed.placedCount / ed.removedCount (only the recent strip + recent mode set them).
local function _ensureRecentBadges(cell)
    if cell._recentPlus then return end
    cell._recentPlus = cell:CreateTexture(nil, "OVERLAY", nil, 3)
    cell._recentPlus:SetSize(13, 13)
    cell._recentPlus:SetPoint("TOPRIGHT", -1, -1)
    cell._recentPlus:SetAtlas("communities-chat-icon-plus")
    cell._recentMinus = cell:CreateTexture(nil, "OVERLAY", nil, 3)
    cell._recentMinus:SetSize(13, 13)
    cell._recentMinus:SetAtlas("communities-chat-icon-minus")
    -- Count numbers (recent-MODE grid only), left of each +/- icon, accent-colored.
    cell._recentPlusFs = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    cell._recentMinusFs = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
end
-- showCount: recent-MODE grid shows the placed/removed COUNT number (accent); the
-- per-action STRIP passes false -> direction icon only (each card is one action).
local function _paintRecentBadges(cell, placed, removed, showCount)
    placed, removed = placed or 0, removed or 0
    if placed <= 0 and removed <= 0 then
        if cell._recentPlus then
            cell._recentPlus:Hide();   cell._recentMinus:Hide()
            cell._recentPlusFs:Hide(); cell._recentMinusFs:Hide()
        end
        return
    end
    _ensureRecentBadges(cell)
    cell._recentPlus:SetShown(placed > 0)
    if removed > 0 then
        cell._recentMinus:ClearAllPoints()
        cell._recentMinus:SetPoint("TOPRIGHT", -1, placed > 0 and -15 or -1)  -- stack below + when both
        cell._recentMinus:Show()
    else
        cell._recentMinus:Hide()
    end
    if showCount then
        -- Count colored via the TextStatus role (= semantic.accent) through
        -- Theme:Register, so it repaints on scheme switch -- NOT an inline SetTextColor
        -- (which bakes a color the row rails can't track = the row-paint smell).
        cell._recentPlusFs:SetShown(placed > 0)
        if placed > 0 then
            cell._recentPlusFs:SetText(placed)
            HDG.Theme:Register(cell._recentPlusFs, "TextStatus")
            cell._recentPlusFs:ClearAllPoints()
            cell._recentPlusFs:SetPoint("RIGHT", cell._recentPlus, "LEFT", -1, 0)
        end
        cell._recentMinusFs:SetShown(removed > 0)
        if removed > 0 then
            cell._recentMinusFs:SetText(removed)
            HDG.Theme:Register(cell._recentMinusFs, "TextStatus")
            cell._recentMinusFs:ClearAllPoints()
            cell._recentMinusFs:SetPoint("RIGHT", cell._recentMinus, "LEFT", -1, 0)
        end
    else
        cell._recentPlusFs:Hide(); cell._recentMinusFs:Hide()
    end
end

-- ============================================================================
-- Tooltip def for companion grid cells. Function form: reads live cell fields
-- at hover time so it always reflects the current paint pass.
-- ============================================================================

local function _companionCellTooltipDef(self)
    if not self._placeName then return nil end
    local lines = {}
    if (self._recentPlaced or 0) > 0 then
        lines[#lines + 1] = { text = "Placed " .. self._recentPlaced .. " this session", r = 0.55, g = 0.78, b = 0.55 }
    end
    if (self._recentRemoved or 0) > 0 then
        lines[#lines + 1] = { text = "Removed " .. self._recentRemoved .. " this session", r = 0.85, g = 0.55, b = 0.45 }
    end
    if self._placeEntryID then
        local storage = self._placeQty or 0
        local placedN = self._placeNumPlaced
        if placedN ~= nil then
            lines[#lines + 1] = { text = ("Owned: %d (Placed: %d, Storage: %d)"):format(storage + placedN, placedN, storage), r = 0, g = 1, b = 0 }
        elseif storage > 0 then
            lines[#lines + 1] = { text = "In storage: " .. storage, r = 0.4, g = 0.9, b = 0.4 }
        else
            lines[#lines + 1] = { text = "None available to place", r = 0.85, g = 0.45, b = 0.45 }
        end
        if self._placeWhere then
            lines[#lines + 1] = { text = self._placeWhere, r = 0.78, g = 0.78, b = 0.6 }
        end
        if (self._placeCost or 0) > 0 then
            lines[#lines + 1] = { text = "Placement cost: " .. self._placeCost, r = 0.78, g = 0.78, b = 0.6 }
        end
    end
    -- Vendor source (when the catalog baked one): first vendor + overflow count.
    -- Hover-time observer read; byItemID is O(1) (ADR-031 facade).
    if self._placeItemID then
        local row = HDG.HousingCatalogObserver:GetRow(self._placeItemID)
        local vendors = row and row.vendors  -- exception(nullable): unswept item / no vendor source
        if vendors and #vendors > 0 then
            local v = vendors[1]
            local where = (v.zone and v.zone ~= "" and (" -- " .. v.zone)) or ""
            local more  = #vendors > 1 and ("  (+" .. (#vendors - 1) .. " more)") or ""
            lines[#lines + 1] = { text = "Vendor: " .. v.name .. where .. more, r = 0.55, g = 0.78, b = 1 }
        end
    end
    -- Click hints with the housing-hotkey mouse glyphs (same source of truth
    -- as the decor browser rows: TE.ClickHintLines).
    if self._placeEntryID or self._placeItemID then
        HDG.TooltipEngine.AppendClickHints(lines, {
            leftText  = self._placeEntryID and "Place" or nil,
            rightText = self._placeItemID and "Add to shopping list" or nil,
        })
    end
    return { title = self._placeName, extraLines = lines }
end

-- ============================================================================
-- CardGrid cell kind: companion grid items. Used by BOTH the main grid and
-- the recent strip (different cellSize cfg, same renderer).
-- ============================================================================

HDG.CardGrid:RegisterCellKind("companionGridCell", {
    template = "Button",
    initFunc = function(cell, ed, cfg)
        HDG.CardGrid:EnsureDefaultAnatomy(cell, cfg)
        cell:Show()
        HDG.CardGrid:PaintIcon(cell, ed.iconTexture, ed.iconAtlas)
        -- No collected check/X badge -- this is a PLACEMENT grid; the owned-to-
        -- place count badge below carries ownership (matches HDG's cell).
        cell.label:Hide()

        -- Count (bottom-right) + cost (top-left) share one font per tile size.
        if not cell._costFs then
            cell._costFs = cell:CreateFontString(nil, "OVERLAY")   -- anchored per paint (_anchorCost)
        end
        local sizeKey = _sizeKeyFor(cfg.cellSize)
        _sizeBadges(cell, sizeKey)

        -- Owned-to-place count badge; gray the icon when 0 copies free.
        -- per-action STRIP hides it (each card is one action, not a count).
        local qty = ed.ownedQty or 0
        local greyed = not ed.isActionStrip and ed.entryID ~= nil and qty < 1
        if ed.isActionStrip then
            HDG.CardGrid:PaintBadge(cell, nil)
        else
            HDG.CardGrid:PaintBadge(cell, qty > 0 and tostring(qty) or nil)
            if greyed then
                cell.icon:SetDesaturated(true)
                cell.icon:SetAlpha(0.45)
            end
        end
        _paintDyeMark(cell, ed, sizeKey, greyed)

        -- Stamp the placement payload the click handler + tooltip read.
        cell._placeEntryID      = ed.entryID
        cell._placeItemID       = ed.itemID   -- vendor-source tooltip + right-click acquisition menu
        cell._placeName         = ed.name
        cell._placeQty          = qty
        cell._placeAllowIndoors = ed.allowIndoors
        cell._placeAllowOutdoors = ed.allowOutdoors
        cell._placeWhere = (ed.allowIndoors and not ed.allowOutdoors and "Inside only")
            or (ed.allowOutdoors and not ed.allowIndoors and "Outside only") or nil
        cell._placeCost = ed.placementCost
        cell._placeNumPlaced = ed.numPlaced   -- "Placed:" tooltip line (nil for dyed variants -> storage-only)
        -- Recent-mode session activity (nil in other modes).
        cell._recentPlaced  = ed.placedCount
        cell._recentRemoved = ed.removedCount

        -- Recent-activity +/- corner overlays (placed/removed this session). Recent-MODE
        -- grid shows the count number (accent); the per-action strip = direction only.
        _paintRecentBadges(cell, ed.placedCount, ed.removedCount, not ed.isActionStrip)

        -- Orange border + tag when this decor can't be placed from where the
        -- player stands (ed.cantHere). The recent strip shows neither: each of
        -- its cards is a past action, not an offer.
        _paintPlaceBorder(cell, _showsPlaceTag(ed))
        _paintPlaceTag(cell, ed, cfg.cellSize)
        _paintCost(cell, ed, sizeKey)   -- after the tag: the cost sits under it

        cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        cell:SetScript("OnClick", _companionCellClick)
        -- Show the tooltip from WITHIN OnEnter (re-wired every init), NOT via
        -- TooltipEngine:Attach. This cell re-SetScripts OnEnter each init (hover bg),
        -- which clobbers Attach's once-installed HookScript on pooled re-acquire ->
        -- the tooltip vanishes after the first paint. (Same fix as stylesCuratorTile.)
        cell:SetScript("OnEnter", function(self_)
            self_.hoverBg:Show()
            HDG.TooltipEngine:Show(self_, _companionCellTooltipDef)
        end)
        cell:SetScript("OnLeave", function(self_)
            self_.hoverBg:Hide()
            HDG.TooltipEngine:Hide()
        end)
    end,
    resetFunc = function(_pool, cell)
        cell:SetScript("OnClick", nil)
        cell:SetScript("OnEnter", nil)
        cell:SetScript("OnLeave", nil)
        cell.hoverBg:Hide()
        if cell.badge then cell.badge:Hide() end
        if cell._costFs then cell._costFs:Hide() end
        if cell._placeTag then cell._placeTag:Hide() end
        _hideDyeMark(cell)
        _paintPlaceBorder(cell, false)
        _paintRecentBadges(cell, 0, 0)
        if cell.icon then cell.icon:SetDesaturated(false); cell.icon:SetAlpha(1) end
        cell._placeEntryID = nil
        cell._placeName = nil
        cell._placeQty = nil
        cell._placeNumPlaced = nil
        cell._placeAllowIndoors = nil
        cell._placeAllowOutdoors = nil
        cell._placeWhere = nil
        cell._placeCost = nil
        cell._recentPlaced = nil
        cell._recentRemoved = nil
    end,
})

-- ============================================================================
-- Recent Activity: edit-session history tracking.
-- ============================================================================
-- Sessions keyed by stable faction house id (not process-scoped houseGUID).
-- Placements captured by hooking StartPlacingNewDecor; removals reducer-side off STYLES_PLACED_DECOR_REMOVED.

local function _currentHouseKey()
    -- Single source of house identity (HousingObserver owns C_Housing); plot-keyed.
    return HDG.HousingObserver:CurrentHouseID()
end

local function _startRecentSession()
    local key = _currentHouseKey()
    if key then
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.RECENT_SESSION_START,
            payload = { houseKey = key },
        })
    end
end

-- Hook StartPlacingNewDecor once. StartPlacing is INTENT (not a placement yet);
-- only stash the pending itemID here. HousingObserver:OnDecorPlaceSuccess records
-- RECENT_DECOR_PLACED on the actual commit, so a cancelled pick records nothing.
-- entryID is the HousingCatalogEntryID table (.recordID = decorID); resolve to itemID.
local function _installPlacementHook()
    if H._placeHookInstalled then return end
    local function stashPending(entryID)
        local decorID = type(entryID) == "table" and entryID.recordID or nil
        local itemID  = decorID and HDG.HousingCatalogObserver:GetItemIDByDecorID(decorID)
        if itemID then HDG.HousingObserver:SetPendingPlacement(itemID) end
    end
    if _G.C_HousingBasicMode and _G.C_HousingBasicMode.StartPlacingNewDecor then
        hooksecurefunc(_G.C_HousingBasicMode, "StartPlacingNewDecor", stashPending)  -- exception(boundary): housing C_API nil off-house-context
        H._placeHookInstalled = true
    end
    -- No expert-mode hook: C_HousingExpertMode has no StartPlacing* function at all.
    -- Blizzard starts placement only through C_HousingBasicMode.StartPlacingNewDecor,
    -- in expert mode too, so the hook above IS the expert path. The old branch here
    -- tested a function that cannot exist and read as though expert mode had its own.
end

-- Editor became visible. Trigger the load-on-demand catalog sweep (the main window
-- does this on tab-activate; editor-only open never would -> "?" placeholder icons).
-- Sweep is async + idempotent; completion bumps sweepGeneration -> companion re-resolves.
local function _onEditorShown()
    HDG.HousingCatalogObserver:RequestLoad("house-editor")
    -- Search box on Blizzard's own Placed Decor panel (dim-only; see that module
    -- for why it must never touch their DataProvider). Idempotent.
    HDG.PlacedDecorSearch:Install()
    _startRecentSession()   -- new edit session per editor open
    H._launcher:Show()
    -- Idempotent: builds the satellite the first time the editor opens (its
    -- parent HouseEditorFrame now exists); HDG.Window's reconciler -- already
    -- subscribed at OnEnable -- drives visibility/position/content from there.
    HDG.Window:EnsureCreated("companion")
    -- The grid opens on a list, not an empty well, when nothing is picked yet.
    HDG.CompanionController:PickFirstListIfNone()
end

local function InjectShell()
    if H._injected then return end
    if not _G.HouseEditorFrame then return end
    H._injected = true

    H._launcher = CreateLauncher()
    _installPlacementHook()

    _G.HouseEditorFrame:HookScript("OnShow", _onEditorShown)

    if _G.HouseEditorFrame:IsShown() then
        _onEditorShown()
    end
end

-- ============================================================================
-- Launcher button.
-- ============================================================================

function CreateLauncher()
    local btn = CreateFrame("Button", "HDGR_HouseEditorLauncher", _G.HouseEditorFrame)
    btn:SetSize(40, 40)
    btn:SetFrameStrata("MEDIUM")
    btn:SetClampedToScreen(true)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetScript("OnDragStart", btn.StartMoving)
    -- Persist the launcher position (UIParent-TOPLEFT, top-down y) so a dragged
    -- icon stays put across editor re-opens + /reload. Mirrors the companion
    -- window's COMPANION_SET_POSITION convention.
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local left, top, screenH = self:GetLeft(), self:GetTop(), _G.UIParent:GetHeight()
        if left and top and screenH then
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.COMPANION_SET_LAUNCHER_POSITION,
                payload = { x = left, y = top - screenH },
            })
        end
    end)
    btn:Hide()

    -- Restore saved position (UIParent-anchored: fixed screen spot regardless of HouseEditorFrame parent).
    local pos = HDG.Store:GetState().account.ui.companion.launcher
    if type(pos.x) == "number" and type(pos.y) == "number" then
        btn:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", pos.x, pos.y)
    else
        btn:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 0, -30)
    end

    -- The HDG icon (same texture the minimap button uses). Hover brightens it
    -- (additive). Framed with a gold border + an expandable arrow (below).
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface/AddOns/HousingDecorGuide/textures/Vamoose_HDG_400_trans")
    icon:SetAllPoints()

    btn:SetHighlightTexture("Interface/AddOns/HousingDecorGuide/textures/Vamoose_HDG_400_trans")
    local hl = btn:GetHighlightTexture()
    hl:SetAllPoints()
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.25)

    -- Gold frame around the icon (4 thin edges; SetColorTexture per
    -- reference_wow_color_swatches -- block/border chars don't render). OVERLAY so
    -- it sits above the icon's perimeter.
    local BORDER = { 0.85, 0.68, 0.32, 1 }
    local edges = {}
    for i = 1, 4 do
        edges[i] = btn:CreateTexture(nil, "OVERLAY")
        edges[i]:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], BORDER[4])
    end
    edges[1]:SetPoint("TOPLEFT");    edges[1]:SetPoint("TOPRIGHT");    edges[1]:SetHeight(2)  -- top
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(2)  -- bottom
    edges[3]:SetPoint("TOPLEFT");    edges[3]:SetPoint("BOTTOMLEFT");  edges[3]:SetWidth(2)   -- left
    edges[4]:SetPoint("TOPRIGHT");   edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(2)   -- right

    -- Expandable affordance: Blizzard's arrow, just right of the icon. Points RIGHT
    -- when the window is CLOSED (expand), flips to LEFT when OPEN (collapse). It lives
    -- outside the 40x40 icon, so extend the hit rect right to keep it clickable.
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetAtlas("plunderstorm-pickup-arrow")
    arrow:SetSize(14, 20)
    arrow:SetPoint("LEFT", btn, "RIGHT", 2, 0)
    btn:SetHitRectInsets(0, -18, 0, 0)
    -- Capture the 8-value texcoord quad to mirror-flip the arrow without GetAtlasInfo field names.
    local ulx, uly, llx, lly, urx, ury, lrx, lry = arrow:GetTexCoord()
    local arrowOpen
    local function updateArrow()
        local open = HDG.Store:GetState().session.ui.companion.windowShown and true or false
        if open == arrowOpen then return end   -- only on actual open/close transitions
        arrowOpen = open
        if not ulx then return end             -- exception(boundary): atlas unresolved -> keep SetAtlas default
        if open then   -- mirror horizontally: swap the left column (UL,LL) with the right (UR,LR)
            arrow:SetTexCoord(urx, ury, lrx, lry, ulx, uly, llx, lly)
        else
            arrow:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
        end
    end
    updateArrow()
    HDG.Store:Subscribe(updateArrow)

    HDG.TooltipEngine:Attach(btn, {
        title      = "Housing Decor Guide",
        extraLines = {
            { text = "Click to open the Housing Decor Guide chest to place decor.", wrap = true },
            { text = "Drag to move.", r = 0.7, g = 0.7, b = 0.7, wrap = true },
        },
    })

    btn:SetScript("OnClick", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.COMPANION_TOGGLE,
            payload = {},
        })
    end)
    return btn
end

-- ============================================================================
-- Module declare.
-- ============================================================================

local function _OnAddonLoaded(self, addonName)
    if addonName ~= "Blizzard_HouseEditor" then return end
    _G.RunNextFrame(InjectShell)  -- defer: some subframes complete on the next tick
end

local function _OnHouseEditorModeChanged(self)
    if H._injected then return end
    if not _G.HouseEditorFrame then return end
    _G.RunNextFrame(InjectShell)  -- defer: OnShow handlers settle on the next tick
end

HDG.Modules:Declare({
    name = "HouseEditorCompanion",
    dependencies = { "HousingObserver" },   -- consumes HO editor-mode / inside accessors
    -- Owns the placement-mode namespaces: it HOOKS StartPlacingNewDecor on both
    -- (the recent-activity observe rail) AND issues the placement command. C_HouseEditor
    -- + C_Housing are NOT owned here -- they belong to HousingObserver; the companion
    -- consumes them through HO accessors (invariant 9).
    ownsBlizzardNamespaces = { "C_HousingBasicMode", "C_HousingExpertMode" },
    blizzardEvents = {
        ADDON_LOADED              = { handler = "OnAddonLoaded" },
        HOUSE_EDITOR_MODE_CHANGED = { handler = "OnHouseEditorModeChanged" },
    },
    OnAddonLoaded              = _OnAddonLoaded,
    OnHouseEditorModeChanged   = _OnHouseEditorModeChanged,
    -- onEnable: safety net for /reload-with-editor-already-loaded (no defer needed post-PLAYER_LOGIN).
    onEnable = function(self)
        if _G.C_AddOns.IsAddOnLoaded("Blizzard_HouseEditor") then
            InjectShell()
        end
    end,
})
