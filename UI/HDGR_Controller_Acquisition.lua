-- HDG.AcquisitionController
-- ============================================================================
-- Acquisition tab: search + filter wire-up, vendor/item row kinds, map pins.
-- Refresh auto-selects first vendor when selection falls outside filtered set;
-- _autoSelectPending guards re-entrancy across flush cycles.
-- Click and tooltip handlers are module-level and read what the paint stamped on
-- the frame (row._ed, a button's _vendor): rows repaint on every scroll, and a
-- closure per paint was garbage each time.

HDG = HDG or {}
HDG.AcquisitionController = HDG.AcquisitionController or {}

local AcquisitionController = HDG.AcquisitionController
local CH = HDG.ControllerHelpers

-- Re-entrancy guard: set true before auto-select dispatch; cleared on the next valid Refresh.
local _autoSelectPending = false


-- itemRow: item name + profession/expansion meta. Click selects the primary vendor.
--
-- Ranked rather than vendors[1]: catalog parse order puts Blizzard's synthetic
-- "World Vendors" grouping ahead of a named merchant often enough that clicking
-- a boulder selected a vendor with no location instead of the one standing in
-- Founder's Point. No neighborhood preference here -- that is the shopping
-- list's travel aid, and this is "show me who sells it".
local function FindFirstVendorForItem(itemID)
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    local v = HDG.VendorRank.Pick(row, nil)
    if not v then return nil end  -- exception(nullable): drops/quests/achievements have no vendor
    return HDG.StaticData.VendorAugment:ResolveName(v.name, v.zone)
end

-- ===== Shared row helpers: chip palette, shift-link, envelope ===============
local _gateChips = HDG.UI.GateChips

-- Shift-click links the item in chat (active editbox, or opens chat), as on the
-- Decor browser's rows; true when it did, and the click does nothing else.
local function _linkedOnShift(itemID)
    if not IsShiftKeyDown() then return false end
    HDG.UI.LinkItem(itemID)
    return true
end

-- A pooled row keeps no envelope once released.
local function _clearRowEd(row) row._ed = nil end

-- itemRow factory: canonical layout/paint/wire split.
local function _layoutItemRow(row)
    -- Single chips FontString carries all visible chips (one per applicable
    -- source type). Cheaper than per-chip FontStrings and lets the helper
    -- handle the chip palette without chain-anchoring shenanigans.
    local chips = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(chips, "caption")
    chips:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    chips:SetJustifyH("RIGHT")
    row._chipsFs = chips

    local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", 4, 0)
    row._nameFs = name

    local meta = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    row._metaFs = meta
end

-- The right-hand caption (meta / cost) sits left of the chips strip, or at the
-- row's edge when no chip shows.
local function _anchorLeftOfChips(row, fs)
    fs:ClearAllPoints()
    if row._chipsFs:GetText() and row._chipsFs:GetText() ~= "" then
        fs:SetPoint("RIGHT", row._chipsFs, "LEFT", -8, 0)
    else
        fs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    end
end

local function _paintItemRow(row, ed)
    row._nameFs:SetText(HDG.Theme:CollectionLabel(ed.isCollected, ed.name))
    -- Meta: expansion + profession when present ("Midnight Inscription").
    -- Profession populates for items in HDGR_DecorDB (StaticData.Recipes).
    local meta = (ed.expansion and ed.expansion ~= "?") and ed.expansion or ""
    if ed.profession and ed.profession ~= "" then
        meta = (meta ~= "") and (meta .. " " .. ed.profession) or ed.profession
    end
    row._metaFs:SetText(meta)
    row._chipsFs:SetText(_gateChips(ed.itemID, ed.questDone, ed.achEarned, ed.repMet))

    -- Re-anchor: chips right-edge fixed; meta sits left of chips, name fills the rest.
    _anchorLeftOfChips(row, row._metaFs)
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT",  row,         "LEFT",  4, 0)
    row._nameFs:SetPoint("RIGHT", row._metaFs, "LEFT",  -8, 0)
end

-- A plain click selects the item and its primary vendor.
local function _onItemRowClick(self)
    local itemID = self._ed.itemID
    if _linkedOnShift(itemID) then return end
    CH.Mechanics.SetUITransientView("acquisition", "selectedItemID", itemID)
    local npcID = FindFirstVendorForItem(itemID)
    if npcID then
        CH.Mechanics.SetUITransientView("acquisition", "selectedNpcID", npcID)
    end
end

local function _wireItemRow(row, ed)
    row._ed = ed
    row:SetScript("OnClick", _onItemRowClick)
end

HDG.Rows:Register("itemRow", {
    font    = "body",
    height  = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutItemRow,
        paint      = _paintItemRow,
        laidOutTag = "_itemRowLaidOut",
        selectable = true,
        wire       = _wireItemRow,
        resetText  = { "_nameFs", "_metaFs" },
        reset      = _clearRowEd,
    }),
    key     = function(ed) return tostring(ed.itemID) end,   -- acq.items keeps one row per item
})

-- ===== Vendor row factory: name + zone/faction/expansion meta =================
-- acqVendorRow factory: canonical layout/paint/wire split.
local function _layoutAcqVendorRow(row)
    HDG.UI.LayoutNameMetaRow(row, { leftInset = 4, rightInset = -4, gap = 8 })  -- hygiene A10
end

local function _paintAcqVendorRow(row, ed)
    row._nameFs:SetText(HDG.Theme:CollectionLabel(ed.allCollected, ed.name))

    local parts = {}
    if ed.zone      and ed.zone      ~= "" then parts[#parts+1] = ed.zone end
    if ed.faction   and ed.faction   ~= "" then parts[#parts+1] = ed.faction end
    if ed.expansion and ed.expansion ~= "" then parts[#parts+1] = ed.expansion end
    row._metaFs:SetText(table.concat(parts, "  -  "))
end

local function _onAcqVendorRowClick(self)
    local ed = self._ed
    CH.Mechanics.SelectVendor(ed.npcID, ed.name, ed.catalogZone)   -- catalogZone is byVendor key; display zone may differ
end

local function _wireAcqVendorRow(row, ed)
    row._ed = ed
    row:SetScript("OnClick", _onAcqVendorRowClick)
end

HDG.Rows:Register("acqVendorRow", {
    font    = "body",
    height  = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutAcqVendorRow,
        paint      = _paintAcqVendorRow,
        laidOutTag = "_acqVendorLaidOut",
        selectable = true,
        clicks     = "LeftButtonUp",
        wire       = _wireAcqVendorRow,
        resetText  = { "_nameFs", "_metaFs" },
        reset      = _clearRowEd,
    }),
    -- npcID alone is not unique (~9 vendors appear in multiple zones; one npcID per
    -- zone pair), so the catalog's zone joins it: one row per byVendor (name, zone).
    key     = function(ed)
        if ed.npcID then return "avr_" .. ed.npcID .. "_" .. ed.catalogZone end
        -- exception(nullable): meta-groupings ("Draenor World Vendors") and names VendorAugment cannot resolve have no npcID
        return "avr_name_" .. ed.name .. "_" .. ed.catalogZone
    end,
})

-- ===== Cost / placement / chip helpers ===================================
local function _placementLabel(ed)
    if ed.isAllowedIndoors and ed.isAllowedOutdoors then return "Indoor / Outdoor" end
    if ed.isAllowedIndoors then return "Indoor" end
    if ed.isAllowedOutdoors then return "Outdoor" end
    return ""
end

-- ===== Vendor-items list row: icon | name + collected tick | cost ===========
-- acqVendorItemListRow factory: canonical layout/paint/wire split.
local function _layoutAcqItemRow(row)
    HDG.UI:EnsureRowChrome(row)
    -- ARTWORK: above EnsureRowChrome's BACKGROUND fills (zebra/selectedBg).
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    icon:SetTexCoord(unpack(HDG.Constants.ICON_CROP))
    row._iconTex = icon

    -- Single chips strip at the right edge -- mirrors the left-list-row
    -- pattern; the helper handles which chips apply per ed.
    local chips = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(chips, "caption")
    chips:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    chips:SetJustifyH("RIGHT")
    row._chipsFs = chips

    local cost = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    row._costFs = cost

    local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    row._nameFs = name
end

-- Vendor-items list rows: cost left of the chips, the name between icon and cost.
local function _anchorCostAndName(row)
    _anchorLeftOfChips(row, row._costFs)
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT",  row._iconTex, "RIGHT", 6, 0)
    row._nameFs:SetPoint("RIGHT", row._costFs,  "LEFT",  -8, 0)
end

-- The item's texture, else its atlas, else the "?" placeholder.
local function _paintItemIcon(tex, ed)
    if ed.iconTexture then
        tex:SetTexture(ed.iconTexture)
    elseif ed.iconAtlas then
        tex:SetAtlas(ed.iconAtlas)
    else
        tex:SetTexture(HDG.Constants.PLACEHOLDER_ICON)
    end
end

local function _paintAcqItemRow(row, ed)
    row._chipsFs:SetText(_gateChips(ed.itemID, ed.questDone, ed.achEarned, ed.repMet))
    _anchorCostAndName(row)
    _paintItemIcon(row._iconTex, ed)
    row._nameFs:SetText(HDG.Theme:CollectionLabel(ed.isCollected, ed.name))

    -- The price, gold and currencies alike, from the catalog's cost line: a
    -- multi-option item (coupons OR gold) carries this row's own option in
    -- costLineVariant (listRows expanded it), any other item its one costLine.
    row._costFs:SetText(ed.costLineVariant or ed.costLine)
end

-- A plain click selects the item; a recipe row selects its recipe too.
local function _onAcqItemRowClick(self)
    local ed = self._ed
    local itemID = ed.itemID
    if _linkedOnShift(itemID) then return end
    CH.Mechanics.SetUITransientView("acquisition", "selectedItemID", itemID)
    CH.Mechanics.SetUITransientView("acquisition", "selectedRecipeItemID",
        ed.kind == "recipe" and itemID or nil)
end

local function _wireAcqItemRow(row, ed)
    row._ed = ed
    row:SetScript("OnClick", _onAcqItemRowClick)
end

-- Recipe rows are interleaved into the vendor item LIST (ed.kind == "recipe"),
-- reusing the item row's layout: profession atlas | "Recipe: <name>" (dim until
-- known) | cost. Chips are blanked and cost re-anchors to the row edge.
local function _paintRecipeListRow(row, ed)
    local atlas = ed.professionAtlas  -- resolved in acq.selected.recipes, not at paint
    if atlas then
        row._iconTex:SetAtlas(atlas)
    else
        row._iconTex:SetTexture(HDG.Constants.PLACEHOLDER_ICON)
    end
    row._chipsFs:SetText("")
    _anchorCostAndName(row)
    row._nameFs:SetText(HDG.Theme:CollectionLabel(ed.isKnown, ed.name))
    row._costFs:SetText(ed.costText)
end

local function _acqItemListRowFactory(template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_acqItemListLaidOut", function() _layoutAcqItemRow(row) end)
            HDG.Theme:Register(row, "RowChrome", { selected = ed.selected and true or false })
            if ed.kind == "recipe" then
                _paintRecipeListRow(row, ed)
            else
                _paintAcqItemRow(row, ed)
            end
            _wireAcqItemRow(row, ed)
        end,
        Reset = function(row)
            HDG.UI.ClearRowText(row, "_nameFs", "_costFs")
            row:SetScript("OnClick", nil)
            _clearRowEd(row)
        end,
    }
end
HDG.Rows:Register("acqVendorItemListRow", {
    font    = "body",
    height  = 22,
    factory = _acqItemListRowFactory,
    -- variantIndex disambiguates multi-payment-option items (same itemID, distinct rows).
    key     = function(ed)
        if ed.variantIndex then return "vil_" .. ed.itemID .. "_" .. ed.variantIndex end
        -- exception(nullable): only acq.selected.listRows' per-option copies carry variantIndex
        return "vil_" .. ed.itemID
    end,
})

-- ===== Item-view vendor row: name | zone/faction/cost | [Map] [Wpt] =========
-- acqItemVendorRow factory: canonical layout/paint/wire split.

-- First-paint laydown: chrome + Wpt/Map buttons + name/meta.
local function _layoutItemVendorRow(row)
    local wptBtn = HDG.UI.RowButton(row, "Wpt")
    wptBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row._wptBtn = wptBtn

    local mapBtn = HDG.UI.RowButton(row, "Map")
    mapBtn:SetPoint("RIGHT", wptBtn, "LEFT", -4, 0)
    row._mapBtn = mapBtn

    local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", 4, 0)
    row._nameFs = name

    local meta = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    meta:SetPoint("RIGHT", mapBtn, "LEFT", -8, 0)
    row._metaFs = meta

    name:SetPoint("RIGHT", meta, "LEFT", -8, 0)
end

-- Per-paint text: cost - zone - faction (each segment omitted when empty), and
-- "location not known yet" where a vendor without one greys its Wpt/Map.
local function _paintItemVendorRow(row, ed)
    row._nameFs:SetText(ed.name)
    local parts = {}
    local costText = ed.costLine
    if costText ~= "" then parts[#parts+1] = costText end
    if ed.zone    and ed.zone    ~= "?" then parts[#parts+1] = ed.zone end
    if ed.faction and ed.faction ~= "?" then parts[#parts+1] = ed.faction end
    if not ed.mappable then parts[#parts+1] = HDG.Locale:Get("VENDOR_LOC_UNKNOWN") end
    row._metaFs:SetText(table.concat(parts, "  -  "))
end

-- Wpt / Map read the vendor row stamped on them each paint, the row click its _ed:
-- one handler and tip each, not four closures per row per paint. Wpt/Map are greyed
-- (not hidden) without a location, and their tooltip says why: a live-looking button
-- that did nothing was the 2026-10-15 report.
local function _onVendorWaypoint(self) HDG.UI.WaypointToVendor(self._vendor) end
local function _onVendorMap(self) HDG.UI.ShowVendorOnMap(self._vendor) end
local function _vendorWayTip(self) return HDG.TooltipRecipes.VendorNavTip(self._vendor, "VENDOR_WAY_TIP") end
local function _vendorMapTip(self) return HDG.TooltipRecipes.VendorNavTip(self._vendor, "VENDOR_MAP_TIP") end

-- A vendor whose name resolved to no npcID has nothing to select.
local function _onItemVendorRowClick(self)
    local npcID = self._ed.npcID
    if npcID then
        CH.Mechanics.SetUITransientView("acquisition", "selectedNpcID", npcID)
    end
end

local function _wireItemVendorRowClicks(row, ed)
    row._ed, row._wptBtn._vendor, row._mapBtn._vendor = ed, ed, ed
    HDG.UI.SetEnabledLook(row._wptBtn, ed.mappable)
    HDG.UI.SetEnabledLook(row._mapBtn, ed.mappable)
    HDG.TooltipEngine:Attach(row._wptBtn, _vendorWayTip)
    HDG.TooltipEngine:Attach(row._mapBtn, _vendorMapTip)
    row._wptBtn:SetScript("OnClick", _onVendorWaypoint)
    row._mapBtn:SetScript("OnClick", _onVendorMap)
    row:SetScript("OnClick", _onItemVendorRowClick)
end

local function _resetItemVendorRow(row)
    row._wptBtn:SetScript("OnClick", nil)
    row._mapBtn:SetScript("OnClick", nil)
    row._ed, row._wptBtn._vendor, row._mapBtn._vendor = nil, nil, nil
end

HDG.Rows:Register("acqItemVendorRow", {
    font    = "body",
    height  = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutItemVendorRow,
        paint      = _paintItemVendorRow,
        laidOutTag = "_ivLaidOut",
        selectable = true,
        wire       = _wireItemVendorRowClicks,
        resetText  = { "_nameFs", "_metaFs" },
        reset      = _resetItemVendorRow,
    }),
    -- Key by npcID; name@zone when the vendor's name resolved to none (two unresolved
    -- vendors would otherwise share one key).
    key     = function(ed)
        if ed.npcID then return "ivr_" .. ed.npcID end
        -- exception(nullable): a catalog vendor name VendorAugment cannot resolve has no npcID
        return "ivr_" .. ed.name .. "@" .. ed.zone
    end,
})

-- ===== CardGrid cell: acqVendorItemTile =====================================
-- Vendor-detail item tile. Standard anatomy + storage badge + hover tooltip.
-- Click dispatches selectedItemID.
--
-- Tooltip def and click are MODULE-LEVEL and read per-init stamps on the cell
-- (cell._tip*, cell._ed), as the row factories read row._ed: the cell is pooled
-- and re-initialized per item, so a closure per init would be garbage each time.
-- The name in Blizzard's gold, the rest tooltip white (TooltipEngine.COLOR: HDG
-- never re-skins GameTooltip, so a scheme colour could vanish on its background).
local function _acqTileDef(self_)
    local gold  = HDG.TooltipEngine.COLOR.NORMAL
    local lines = { { text = self_._tipName, r = gold.r, g = gold.g, b = gold.b } }
    if self_._tipCost  ~= "" then lines[#lines+1] = "Cost: " .. self_._tipCost end
    if self_._tipPlace ~= "" then lines[#lines+1] = self_._tipPlace end
    lines[#lines+1] = "Stored: " .. self_._tipStored
    lines[#lines+1] = "Placed: " .. self_._tipPlaced
    return { anchor = "ANCHOR_RIGHT", extraLines = lines }
end

-- The tooltip's per-init stamps, read by _acqTileDef.
local function _stampTileTip(cell, ed)
    cell._tipName   = ed.name
    cell._tipCost   = ed.costText
    cell._tipPlace  = _placementLabel(ed)
    cell._tipStored = ed.numStored
    cell._tipPlaced = ed.numPlaced
end

-- Click selects the stamped item; leave drops the hover fill.
local function _onTileClick(self)
    CH.Mechanics.SetUITransientView("acquisition", "selectedItemID", self._ed.itemID)
end
local function _onTileLeave(self)
    self.hoverBg:Hide()
end

HDG.CardGrid:RegisterCellKind("acqVendorItemTile", {
    template = "Button",
    initFunc = function(cell, ed, cfg)
        HDG.CardGrid:EnsureDefaultAnatomy(cell, cfg)
        cell:Show()
        HDG.CardGrid:PaintIcon(cell, ed.iconTexture, ed.iconAtlas)
        HDG.CardGrid:PaintCollected(cell, ed.isCollected == true)

        -- Storage badge: only when stored > 1 (1 is the implicit "I have it"
        -- baseline that the checkmark already conveys).
        if (ed.numStored) > 1 then
            HDG.CardGrid:PaintBadge(cell, "x" .. tostring(ed.numStored), 1, 1, 1)
        else
            HDG.CardGrid:PaintBadge(cell, nil)
        end

        cell.label:Hide()
        cell:RegisterForClicks("LeftButtonUp")
        -- Per-init stamps (read by the module-level _acqTileDef / _onTileClick). MUST
        -- be re-stamped every init: the cell is pooled + TE:Attach hooks OnEnter once.
        cell._ed = ed
        _stampTileTip(cell, ed)
        cell:SetScript("OnClick", _onTileClick)
        cell:SetScript("OnLeave", _onTileLeave)
        HDG.TooltipEngine:Attach(cell, _acqTileDef)
    end,
})

-- ===== Controller lifecycle ==================================================

-- Missing is orthogonal to the source chips (ANDs with them). Its tag shows only
-- while it is on, so the tag clears it with the same toggle.
local function _toggleMissing() CH.Mechanics.DispatchNamed("ACQ_TOGGLE_MISSING") end

-- A multi-select axis tag: the toggle with "all" clears the set (reducer contract).
local function _clearAxis(action, key)
    return function() CH.Mechanics.DispatchNamed(action, { [key] = "all" }) end
end

-- The preset tag: re-dispatching the active preset toggles it off (reducer contract).
local function _clearPreset()
    local current = HDG.Selectors:Call("acq.preset", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller click, not a row factory
    if current then CH.Mechanics.DispatchNamed("ACQ_SET_PRESET", { value = current }) end
end

-- Current zone: the Zone filter, set once to where the player stands. Enabled
-- only when acq.currentZones holds a zone, so the set is never empty here.
local function _filterToCurrentZone()
    local zones = HDG.Selectors:Call("acq.currentZones", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller click, not a row factory
    CH.Mechanics.DispatchNamed("ACQ_SET_ZONE_FILTER", { zones = zones })
end

-- The list's header: active-filter chips overflow horizontally (the layout engine
-- has no flow/wrap), so clip the list panel -- chips cut off at its edge instead of
-- bleeding into the detail panel; dropdown popups are top-level frames, never
-- clipped. Search dispatches every keystroke (acq.filterQuery feeds the lists), as
-- on Decor. Preset chips: SSoT ACQ_PRESETS; the reducer toggles a re-click off.
function AcquisitionController:_wireListChrome(rootFrame)
    rootFrame.panels.acquisitionListPanel:SetClipsChildren(true)
    HDG.UI.WireSearchBox(rootFrame, "acquisitionListPanel.search", "acquisition", "searchQuery")
    for _, p in ipairs(HDG.Constants.ACQ_PRESETS) do
        HDG.UI.OnClick(rootFrame, "acquisitionListPanel.preset_" .. p.value, function()
            CH.Mechanics.DispatchNamed("ACQ_SET_PRESET", { value = p.value })
        end)
    end
end

-- Missing, Current zone, the Advanced filters toggle (its `visible` binding
-- cascades to the children), and Reset: an atomic clear of every filter axis. The
-- search editbox is user-driven, so Reset blanks it explicitly.
function AcquisitionController:_wireFilters(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.missingToggle", _toggleMissing)
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.currentZone", _filterToCurrentZone)
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.advancedToggle", function()
        CH.Mechanics.DispatchNamed("ACQ_TOGGLE_ADVANCED_FILTERS")
    end)
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.resetFilters", function()
        CH.Mechanics.DispatchNamed("UI_FILTER_RESET", { tab = "acquisition" })
        HDG.UI.W(rootFrame, "acquisitionListPanel.search"):SetText("")
    end)
end

-- Filter tag chips: a click clears its axis. The tags are LayoutConfig._activeFilterTags
-- (the SSoT); one without a reset here is an error at Wire, not a dead chip.
function AcquisitionController:_wireFilterTags(rootFrame)
    local searchBox = HDG.UI.W(rootFrame, "acquisitionListPanel.search")
    local TAG_RESETS = {
        search    = function()
            CH.Mechanics.SetUITransientView("acquisition", "searchQuery", "")
            searchBox:SetText("")
        end,
        faction   = _clearAxis("ACQ_TOGGLE_FACTION",   "faction"),
        expansion = _clearAxis("ACQ_TOGGLE_EXPANSION", "expansion"),
        zone      = _clearAxis("ACQ_TOGGLE_ZONE",      "zone"),
        rep       = _clearAxis("ACQ_TOGGLE_REP",       "rep"),
        source    = _clearAxis("ACQ_TOGGLE_SOURCE",    "source"),
        currency  = _clearAxis("ACQ_TOGGLE_CURRENCY",  "currency"),
        preset    = _clearPreset,
        missing   = _toggleMissing,
    }
    for _, tag in ipairs(HDG.LayoutConfig._activeFilterTags) do
        local reset = TAG_RESETS[tag.axis] or error(("_wireFilterTags: no reset for the %q tag"):format(tag.axis))
        HDG.UI.OnClick(rootFrame, "acquisitionListPanel.tag_" .. tag.axis, reset)
    end
end

-- The item and recipe lists highlight selectedItemID; recipe rows also stamp
-- selectedRecipeItemID (the acqVendorItemListRow factory).
local function _isSelectedItem(ed, id) return id ~= nil and ed.itemID == id end

-- Same identity rule as acq.selectedVendor and the auto-select guard in Refresh:
-- npcID when set; for npcID-less vendors (catalog-only NPCs, the synthetic World
-- Vendors groupings) the (name, zone) SelectVendor stamps. A bare `ed.npcID == id`
-- with a nil id matched the FIRST npcID-less row -- a wrong highlight, and a wrong scroll.
local function _isSelectedVendor(ed, id)
    if id ~= nil then return ed.npcID == id end
    local ui = HDG.Store:GetState().session.ui.acquisition  -- exception(false-positive): top-level controller read, not a row factory
    if ui.selectedVendorName == nil then return false end
    return ed.npcID == nil and ed.name == ui.selectedVendorName
        and ed.catalogZone == ui.selectedVendorZone
end

-- Selection highlight follows state on the three scroll lists.
function AcquisitionController:_wireLists(rootFrame)
    HDG.UI.W(rootFrame, "acquisitionListPanel.itemList"):WireStoreSelectionSync(
        "session.ui.acquisition.selectedItemID", _isSelectedItem)
    HDG.UI.W(rootFrame, "acquisitionListPanel.recipeList"):WireStoreSelectionSync(
        "session.ui.acquisition.selectedItemID", _isSelectedItem)
    HDG.UI.W(rootFrame, "acquisitionListPanel.vendorList"):WireStoreSelectionSync(
        "session.ui.acquisition.selectedNpcID", _isSelectedVendor)
end

-- Map All: pin every filtered vendor with a location, open the map once
-- (HDG.Waypoints:MapAll). The X beside it takes every HDG pin off the map.
function AcquisitionController:_wireMapButtons(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.mapAllBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        HDG.Waypoints:MapAll(HDG.Selectors:Call("acq.vendors", state, {}))
    end)
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.clearPinsBtn", function() HDG.Waypoints:ClearAllMapPins() end)
end

local function _selectedVendor()
    return HDG.Selectors:Call("acq.selectedVendor", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller click, not a row factory
end

-- Waypoint and Show on Map for the selected vendor, enabled only with a location
-- (acq.selectedVendorMappable).
function AcquisitionController:_wireVendorNav(rootFrame)
    HDG.UI.WireVendorNav(rootFrame, "acquisitionDetailPanel.waypointBtn",
        "acquisitionDetailPanel.showOnMapBtn", _selectedVendor)
end

-- Wowhead URL: pops the shared slimline copy field under the clicked logo.
local function _copyUrlFrom(selectorName)
    return function(btn)
        local url = HDG.Selectors:Call(selectorName, HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller click, not a row factory
        HDG.UI:UrlCopyPopup():ShowAt(btn, url)
    end
end

function AcquisitionController:_wireWowheadButtons(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.wowheadBtn", _copyUrlFrom("acq.selected.wowheadUrl"))
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemWowheadBtn", _copyUrlFrom("acq.selectedItem.wowheadUrl"))
end

-- Vendor note: per-keystroke dispatch. Race guard: _lastBoundNpcID tracks which vendor's
-- note is displayed (binding-driven SetText runs a frame after npcID flips); OnTextChanged
-- skips when displayed npcID doesn't match selection.
function AcquisitionController:_wireVendorNoteBox(rootFrame)
    HDG.ControllerHelpers.Mechanics.WireNoteBox(
        HDG.UI.W(rootFrame, "acquisitionDetailPanel.vendorNote"),
        function() return HDG.Store:GetState().session.ui.acquisition.selectedNpcID end,  -- exception(false-positive): top-level controller read
        "npcID", "VENDOR_NOTE_CLEAR", "VENDOR_NOTE_SET")
end

-- The vendor's items as a grid or a list (account-persisted).
function AcquisitionController:_wireItemsView(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemsViewGridBtn", function()
        CH.Mechanics.DispatchNamed("ACQ_SET_ITEMS_VIEW_MODE", { mode = "grid" })
    end)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemsViewListBtn", function()
        CH.Mechanics.DispatchNamed("ACQ_SET_ITEMS_VIEW_MODE", { mode = "list" })
    end)
end

-- Add to Cart: the selected item onto the active shopping list. The item view's
-- carries no npcID (the Shopping selector groups those into "(any vendor)"); the
-- vendor view's is vendor-scoped.
local function _addSelectedItemToCart(vendorScoped)
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller click, not a row factory
    local item  = HDG.Selectors:Call("acq.selectedItem", state, {})
    if not item then return end  -- exception(nullable): no item selected, or its catalog row not loaded
    if vendorScoped then
        CH.Mechanics.AddToShoppingList(item.itemID, HDG.Selectors:Call("acq.selectedNpcID", state, {}), "vendor cart")
    else
        CH.Mechanics.AddToShoppingList(item.itemID, nil, "item cart")
    end
end

function AcquisitionController:_wireCart(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemInfoCartBtn", function() _addSelectedItemToCart(false) end)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.selectedAddToCartBtn", function() _addSelectedItemToCart(true) end)
end

-- Item-view Quest steps: Decor Quests on the item (decorQuests.findShow), shown only for a
-- decor a quest gives (decorQuests.findHasSteps).
function AcquisitionController:_wireQuestSteps(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemQuestStepsBtn", function()
        CH.Mechanics.JumpToDecorQuests(HDG.Selectors:Call("decorQuests.findShow", HDG.Store:GetState(), {}))  -- exception(false-positive): top-level controller click, not a row factory
    end)
end

-- |H<kind>:<itemID>|h in a label: the itemID, or nil for any other link.
local function _linkItemID(link, kind)
    local linkKind, payload = strsplit(":", link or "", 2)
    if linkKind ~= kind or not payload or payload == "" then return nil end
    return tonumber(payload)
end

-- |Hhdgrach:<itemID>|h on the source line: the achievement baked on the catalog row
-- (HousingCatalogObserver's _bakeItemAugmentBackfill). No render-time lookup.
local function _achievementForLink(link)
    local itemID = _linkItemID(link, "hdgrach")
    if not itemID then return nil, nil end
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    if not row then return nil, nil end
    return row.achievementID, row.achievement
end

local function _onAchievementLinkClick(_, link)
    local achID = _achievementForLink(link)
    if not achID then return end
    -- ShowUIPanel refuses insecure callers in combat (CheckProtectedFunctionsAllowed)
    -- and blames the addon by name in the red error. Same guard the mapAllBtn uses.
    if InCombatLockdown() then return end
    ShowAchievementFrameForAchievement(achID)  -- canonical Blizzard path (same as SetItemRef)
end

-- The achievement's name in Blizzard's gold, then the click hint the way every HDG
-- tooltip draws one (TooltipEngine.AppendClickHints).
local ACHIEVEMENT_LINK_HINTS = { leftText = "Open the Achievement window" }

local function _onAchievementLinkEnter(self, link)
    local _, achName = _achievementForLink(link)
    if not achName then return end
    local gold  = HDG.TooltipEngine.COLOR.NORMAL
    local lines = { { text = achName, r = gold.r, g = gold.g, b = gold.b } }
    HDG.TooltipEngine.AppendClickHints(lines, ACHIEVEMENT_LINK_HINTS)
    HDG.TooltipEngine:Show(self, { anchor = "ANCHOR_CURSOR", extraLines = lines })
end

function AcquisitionController:_wireAchievementHyperlinks(rootFrame)
    HDG.UI.WireHyperlinkHost(rootFrame, "acquisitionDetailPanel.itemInfoSource",
        _onAchievementLinkClick, _onAchievementLinkEnter)
end

-- |Hhdgrdecor:<itemID>|h on the selected item's name (acq.selectedItem.name):
-- click opens the item's Decor entry, where + Cart, notes and the model live.
local function _onDecorLinkClick(_, link)
    local itemID = _linkItemID(link, "hdgrdecor")
    if not itemID then return end
    CH.Mechanics.JumpToDecor(itemID)
end

local DECOR_LINK_HINTS = { leftText = "locale:ACQ_DECOR_LINK_HINT" }

local function _onDecorLinkEnter(self, link)
    if not _linkItemID(link, "hdgrdecor") then return end
    local lines = {}
    HDG.TooltipEngine.AppendClickHints(lines, DECOR_LINK_HINTS)
    HDG.TooltipEngine:Show(self, { anchor = "ANCHOR_CURSOR", extraLines = lines })
end

function AcquisitionController:_wireDecorHyperlink(rootFrame)
    HDG.UI.WireHyperlinkHost(rootFrame, "acquisitionDetailPanel.selectedName", _onDecorLinkClick, _onDecorLinkEnter)
end

function AcquisitionController:Wire(rootFrame)
    -- List panel
    self:_wireListChrome(rootFrame)
    self:_wireLists(rootFrame)
    self:_wireFilters(rootFrame)
    self:_wireFilterTags(rootFrame)
    self:_wireMapButtons(rootFrame)
    -- Detail panel: vendor view, then item view
    self:_wireVendorNav(rootFrame)
    self:_wireWowheadButtons(rootFrame)
    self:_wireVendorNoteBox(rootFrame)
    self:_wireItemsView(rootFrame)
    self:_wireCart(rootFrame)
    self:_wireQuestSteps(rootFrame)
    self:_wireAchievementHyperlinks(rootFrame)
    self:_wireDecorHyperlink(rootFrame)
end

-- Search box reconcile: state is the SSoT (JumpToVendor clears searchQuery from
-- another window); never clobber mid-typing.
local function _reconcileSearchBox(rootFrame, query)
    local sb = HDG.UI.W(rootFrame, "acquisitionListPanel.search")
    if not sb:HasFocus() and sb:GetText() ~= query then sb:SetText(query) end
end

-- A selection is "still listed" if it matches a listed vendor by npcID
-- (authoritative when set) OR, for npcID-less vendors, by the (name, zone) the row
-- click stamps. Catalog-only NPCs absent from VendorAugment and synthetic "World
-- Vendors" groupings have npcID == nil; matching them on npcID alone never
-- converges -- auto-select would re-stamp nil every pass, re-triggering Refresh ->
-- Notify -> Refresh until "script ran too long".
local function _selectionListed(vendors, acqUI)
    local curID, curName, curZone = acqUI.selectedNpcID, acqUI.selectedVendorName, acqUI.selectedVendorZone
    if not (curID or curName) then return false end
    for _, v in ipairs(vendors) do
        if (curID and v.npcID == curID)
        or (not curID and v.name == curName and v.catalogZone == curZone) then
            return true
        end
    end
    return false
end

function AcquisitionController:Refresh(rootFrame, ctx)
    -- Auto-select first vendor when in vendor mode and selection is nil or stale.
    if _autoSelectPending then
        _autoSelectPending = false
        return
    end
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    local acqUI = state.session.ui.acquisition
    _reconcileSearchBox(rootFrame, acqUI.searchQuery)
    if acqUI.viewMode ~= "vendor" then return end
    local vendors = HDG.Selectors:Call("acq.vendors", state, {})
    if #vendors == 0 or _selectionListed(vendors, acqUI) then return end
    local first = vendors[1]
    _autoSelectPending = true
    CH.Mechanics.SelectVendor(first.npcID, first.name, first.catalogZone)
end

HDG.Controllers:Register("acquisition", AcquisitionController)
