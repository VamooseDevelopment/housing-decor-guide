-- HDG.AcquisitionController
-- ============================================================================
-- Acquisition tab: search + filter wire-up, vendor/item row kinds, map pins.
-- Refresh auto-selects first vendor when selection falls outside filtered set;
-- _autoSelectPending guards re-entrancy across flush cycles.

HDG = HDG or {}
HDG.AcquisitionController = HDG.AcquisitionController or {}

local AcquisitionController = HDG.AcquisitionController
local CH = HDG.ControllerHelpers

-- Re-entrancy guard: set true before auto-select dispatch; cleared on the next valid Refresh.
local _autoSelectPending = false

-- Thin delegate to HDG.Waypoints:OpenWorldMapAt (shared, owns the OnShow hook).
function AcquisitionController:OpenWorldMapAt(uiMapID)
    HDG.Waypoints:OpenWorldMapAt(uiMapID)
end

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

-- ===== Source-type chip palette + helpers =================================
local _gateChips = HDG.UI.GateChips

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

    -- Re-anchor: chips right-edge fixed; meta sits left of chips (with extra
    -- padding when chips are empty), name fills the rest.
    row._metaFs:ClearAllPoints()
    if row._chipsFs:GetText() and row._chipsFs:GetText() ~= "" then
        row._metaFs:SetPoint("RIGHT", row._chipsFs, "LEFT", -8, 0)
    else
        row._metaFs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    end
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT",  row,         "LEFT",  4, 0)
    row._nameFs:SetPoint("RIGHT", row._metaFs, "LEFT",  -8, 0)
end

local function _wireItemRow(row, ed)
    local itemID = ed.itemID
    row:SetScript("OnClick", function()
        if not itemID then return end
        -- Shift-click links the item in chat (active editbox, or opens chat);
        -- mirrors the Decor browser row. A plain click selects.
        if IsShiftKeyDown() then
            HDG.UI.LinkItem(itemID)
            return
        end
        CH.Mechanics.SetUITransientView("acquisition", "selectedItemID", itemID)
        local npcID = FindFirstVendorForItem(itemID)
        if npcID then
            CH.Mechanics.SetUITransientView("acquisition", "selectedNpcID", npcID)
        end
    end)
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
    }),
    key     = function(ed) return tostring(ed and ed.itemID or "?") end,
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

local function _wireAcqVendorRow(row, ed)
    local npcID = ed.npcID
    local vname, vzone = ed.name, ed.catalogZone or ed.zone   -- catalogZone is byVendor key; display zone may differ
    row:SetScript("OnClick", function()
        CH.Mechanics.SelectVendor(npcID, vname, vzone)
    end)
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
    }),
    key     = function(ed)
        -- npcID alone is not unique (~9 vendors appear in multiple zones; one npcID per zone pair).
        -- Meta-groupings ("Draenor World Vendors") have no npcID; fall back to (name, zone).
        if not ed then return "avr_nil" end
        local zoneKey = tostring(ed.catalogZone or ed.zone or "?")
        if ed.npcID then return "avr_" .. tostring(ed.npcID) .. "_" .. zoneKey end
        return "avr_name_" .. tostring(ed.name or "?") .. "_" .. zoneKey
    end,
})

-- ===== Cost / placement / chip helpers ===================================
local _formatGold = HDG.Format.FormatGold

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

local function _paintAcqItemRow(row, ed)
    row._chipsFs:SetText(_gateChips(ed.itemID, ed.questDone, ed.achEarned, ed.repMet))
    row._costFs:ClearAllPoints()
    if row._chipsFs:GetText() and row._chipsFs:GetText() ~= "" then
        row._costFs:SetPoint("RIGHT", row._chipsFs, "LEFT", -8, 0)
    else
        row._costFs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    end
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT",  row._iconTex, "RIGHT", 6, 0)
    row._nameFs:SetPoint("RIGHT", row._costFs,  "LEFT",  -8, 0)

    if ed.iconTexture and row._iconTex.SetTexture then
        row._iconTex:SetTexture(ed.iconTexture)
    elseif ed.iconAtlas and row._iconTex.SetAtlas then
        row._iconTex:SetAtlas(ed.iconAtlas)
    else
        row._iconTex:SetTexture(HDG.Constants.PLACEHOLDER_ICON)   -- "?" fallback
    end

    row._nameFs:SetText(HDG.Theme:CollectionLabel(ed.isCollected, ed.name))

    local parts = {}
    local goldStr = _formatGold(ed.goldCost)
    if goldStr ~= "" then parts[#parts+1] = goldStr end
    -- Currency cost: a multi-option item (coupons OR gold) carries this row's
    -- specific option in costLineVariant (listRows expanded it); otherwise fall
    -- back to the baked single line (ed.costLine). Both render inline |T:14:14|t icons.
    local currStr = ed.costLineVariant or ed.costLine
    if currStr ~= "" then parts[#parts+1] = currStr end
    row._costFs:SetText(table.concat(parts, " + "))
end

local function _wireAcqItemRow(row, ed)
    local itemID = ed.itemID
    local isRecipe = ed.kind == "recipe"
    row:SetScript("OnClick", function()
        if not itemID then return end
        -- Shift-click links the item in chat, as on Shop by Item's rows.
        if IsShiftKeyDown() then
            HDG.UI.LinkItem(itemID)
            return
        end
        CH.Mechanics.SetUITransientView("acquisition", "selectedItemID", itemID)
        CH.Mechanics.SetUITransientView("acquisition", "selectedRecipeItemID",
            isRecipe and itemID or nil)
    end)
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
    row._costFs:ClearAllPoints()
    row._costFs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row._nameFs:ClearAllPoints()
    row._nameFs:SetPoint("LEFT",  row._iconTex, "RIGHT", 6, 0)
    row._nameFs:SetPoint("RIGHT", row._costFs,  "LEFT",  -8, 0)
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
        end,
    }
end
HDG.Rows:Register("acqVendorItemListRow", {
    font    = "body",
    height  = 22,
    factory = _acqItemListRowFactory,
    -- variantIndex disambiguates multi-payment-option items (same itemID, distinct rows).
    key     = function(ed)
        return "vil_" .. tostring(ed and ed.itemID or "?")
            .. (ed and ed.variantIndex and ("_" .. ed.variantIndex) or "")
    end,
})

-- ===== Item-view vendor row: name | zone/faction/cost | [Map] [Wpt] =========
-- _itemVendorRowFactory: canonical layout/paint/wire split.
local function _buildRowBtn(parent, text)
    return HDG.UI.RowButton(parent, text)
end

-- First-paint laydown: chrome + Wpt/Map buttons + name/meta.
local function _layoutItemVendorRow(row)
    local wptBtn = _buildRowBtn(row, "Wpt")
    wptBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row._wptBtn = wptBtn

    local mapBtn = _buildRowBtn(row, "Map")
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

-- Per-paint text: cost - zone - faction (each segment omitted when empty).
local function _paintItemVendorRow(row, ed)
    row._nameFs:SetText(ed.name)
    local parts = {}
    local costText = ed.costLine
    if costText ~= "" then parts[#parts+1] = costText end
    if ed.zone    and ed.zone    ~= "?" then parts[#parts+1] = ed.zone end
    if ed.faction and ed.faction ~= "?" then parts[#parts+1] = ed.faction end
    row._metaFs:SetText(table.concat(parts, "  -  "))
end

-- Wire Wpt / Map buttons + row click. All close over the per-paint envelope.
local function _wireItemVendorRowClicks(row, ed)
    local vName      = ed.name
    local vMapID     = ed.mapID
    local vX, vY     = ed.x, ed.y
    local factionRaw = ed.factionRaw
    local npcID      = ed.npcID

    row._wptBtn:SetScript("OnClick", function()
        if not (vMapID and vX and vY) then return end
        HDG.Waypoints:Set(vMapID, vX, vY, vName, factionRaw)
    end)
    row._mapBtn:SetScript("OnClick", function()
        if not (vMapID and vX and vY) then return end
        HDG.Waypoints:ShowOnMap(vMapID, vX, vY, vName)  -- hygiene A7: the helper built for this call site
    end)
    row:SetScript("OnClick", function()
        if npcID then
            CH.Mechanics.SetUITransientView("acquisition", "selectedNpcID", npcID)
        end
    end)
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
        reset      = function(row)
            row._wptBtn:SetScript("OnClick", nil)
            row._mapBtn:SetScript("OnClick", nil)
        end,
    }),
    -- Key by npcID; fall back to name@zone when the vendor name didn't resolve to
    -- an npcID (else two distinct unresolved vendors both key "ivr_?" -> collision).
    key     = function(ed)
        if not ed then return "ivr_?" end
        return "ivr_" .. tostring(ed.npcID or ((ed.name or "?") .. "@" .. (ed.zone or "?")))
    end,
})

-- ===== CardGrid cell: acqVendorItemTile =====================================
-- Vendor-detail item tile. Standard anatomy + storage badge + hover tooltip.
-- Click dispatches selectedItemID.
--
-- Tooltip def is MODULE-LEVEL + reads per-init stamps on the cell (cell._tip*).
-- TE:Attach is idempotent on pooled cells (the `_hdgrTooltipAttached` guard hooks
-- OnEnter exactly once, ever), so a per-init CLOSURE captured by Attach would
-- freeze on the FIRST item a pooled cell displayed -- the stale-tooltip-on-
-- vendor-switch bug. Stable def + per-init stamp is the same pattern the row
-- factories use (self._itemID).
local function _acqTileDef(self_)
    if not self_._tipName then return nil end   -- exception(nullable): cell not yet painted
    local th    = HDG.Theme:GetColor("text.heading")
    local td    = HDG.Theme:GetColor("text.dim")
    local money = HDG.Theme:GetColor("semantic.warning")
    local lines = { { text = self_._tipName, r = th.r, g = th.g, b = th.b } }
    if self_._tipCost  ~= "" then lines[#lines+1] = { text = self_._tipCost,  r = money.r, g = money.g, b = money.b } end
    if self_._tipPlace ~= "" then lines[#lines+1] = { text = self_._tipPlace, r = td.r, g = td.g, b = td.b } end
    lines[#lines+1] = { text = "Stored: " .. self_._tipStored, r = td.r, g = td.g, b = td.b }
    lines[#lines+1] = { text = "Placed: " .. self_._tipPlaced, r = td.r, g = td.g, b = td.b }
    return { anchor = "ANCHOR_RIGHT", extraLines = lines }
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

        if cell.label then cell.label:Hide() end
        cell:RegisterForClicks("LeftButtonUp")
        local itemID = ed.itemID
        -- Per-init tooltip stamps (read by the module-level _acqTileDef). MUST be
        -- re-stamped every init: the cell is pooled + TE:Attach hooks OnEnter once.
        cell._tipName   = ed.name
        cell._tipCost   = _formatGold(ed.goldCost)
        cell._tipPlace  = _placementLabel(ed)
        cell._tipStored = ed.numStored      -- exception(boundary): Blizz C_HousingCatalog struct
        cell._tipPlaced = ed.numPlaced or 0  -- exception(boundary): Blizz C_HousingCatalog struct

        cell:SetScript("OnClick", function()
            if not itemID then return end
            CH.Mechanics.SetUITransientView("acquisition", "selectedItemID", itemID)
        end)
        cell:SetScript("OnLeave", function(self_)
            if self_.hoverBg then self_.hoverBg:Hide() end
        end)
        HDG.TooltipEngine:Attach(cell, _acqTileDef)
    end,
})

-- ===== Controller lifecycle ==================================================

-- Filter tag chips: click clears the axis. TAG_RESETS keys from LayoutConfig._activeFilterTags (SSoT).
function AcquisitionController:_wireFilterTags(rootFrame)
    local searchBoxRef = HDG.UI.W(rootFrame, "acquisitionListPanel.search")
    local TAG_RESETS = {
        search    = function()
            CH.Mechanics.SetUITransientView("acquisition", "searchQuery", "")
            if searchBoxRef and searchBoxRef.SetText then searchBoxRef:SetText("") end
        end,
        -- Multi-select axes: dispatch the toggle with value "all" -> reducer clears the set.
        faction   = function() HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_FACTION,   payload = { faction   = "all" } }) end,
        expansion = function() HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_EXPANSION, payload = { expansion = "all" } }) end,
        zone      = function() HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_ZONE,      payload = { zone      = "all" } }) end,
        rep       = function() HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_REP,       payload = { rep       = "all" } }) end,
        -- Preset: re-dispatching the active value toggles it off (reducer contract).
        preset    = function()
            local current = HDG.Selectors:Call("acq.preset", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller method (not a row factory)
            if current then
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.ACQ_SET_PRESET,
                    payload = { value = current },
                })
            end
        end,
        source    = function() HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_SOURCE, payload = { source = "all" } }) end,
        -- Missing tag is only visible when missingOnly is true, so a toggle
        -- dispatch clears it back off.
        missing   = function() HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_MISSING }) end,
    }
    for _, tag in ipairs(HDG.LayoutConfig._activeFilterTags or {}) do
        local reset = TAG_RESETS[tag.axis]
        if reset then
            HDG.UI.OnClick(rootFrame, "acquisitionListPanel.tag_" .. tag.axis, reset)
        end
    end
end

-- Waypoint button: TomTom -> native -> map pin chain via HDG.Waypoints:Set.
function AcquisitionController:_wireWaypointButton(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.waypointBtn", function()
        local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local vendor = HDG.Selectors:Call("acq.selectedVendor", state, {})
        if not (vendor and vendor.mapID and vendor.x and vendor.y) then
            HDG.Log:Warn("waypoints_user", "No coordinates available for this vendor.")
            return
        end
        HDG.Waypoints:Set(vendor.mapID, vendor.x, vendor.y, vendor.name, vendor.factionRaw)
    end)
end

-- Wowhead URL: pops the shared slimline copy field under the clicked logo.
function AcquisitionController:_wireWowheadButtons(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.wowheadBtn", function(btn)
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local url   = HDG.Selectors:Call("acq.selected.wowheadUrl", state, {})
        HDG.UI:UrlCopyPopup():ShowAt(btn, url)
    end)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemWowheadBtn", function(btn)
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local url   = HDG.Selectors:Call("acq.selectedItem.wowheadUrl", state, {})
        HDG.UI:UrlCopyPopup():ShowAt(btn, url)
    end)
end

-- |Hhdgrach:<itemID>|h click/hover: reads achievementID from the baked catalog row
-- (HousingCatalogObserver bakes it via _bakeItemAugmentBackfill). No render-time lookup.
local function _achievementForItem(itemID)
    if not itemID then return nil, nil end
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    if not row then return nil, nil end
    return row.achievementID, row.achievement
end

local function _parseAchLink(link)
    local kind, payload = strsplit(":", link or "", 2)
    if kind ~= "hdgrach" or not payload or payload == "" then return nil end
    return tonumber(payload)
end

function AcquisitionController:_wireAchievementHyperlinks(rootFrame)
    local sourceLine = HDG.UI.W(rootFrame, "acquisitionDetailPanel.itemInfoSource")
    local hyperHost  = sourceLine and sourceLine.GetParent and sourceLine:GetParent()
    if not (hyperHost and hyperHost.SetHyperlinksEnabled) then return end
    hyperHost:EnableMouse(true)
    hyperHost:SetHyperlinksEnabled(true)
    hyperHost:SetScript("OnHyperlinkClick", function(_, link)
        local achID = _achievementForItem(_parseAchLink(link))
        if not achID then return end
        -- ShowUIPanel refuses insecure callers in combat (CheckProtectedFunctionsAllowed)
        -- and blames the addon by name in the red error. Same guard the mapAllBtn uses.
        if InCombatLockdown() then return end
        ShowAchievementFrameForAchievement(achID)  -- canonical Blizzard path (same as SetItemRef)
    end)
    hyperHost:SetScript("OnHyperlinkEnter", function(self, link)
        local _, achName = _achievementForItem(_parseAchLink(link))
        if not achName then return end
        HDG.TooltipEngine:Show(self, {
            anchor     = "ANCHOR_CURSOR",
            extraLines = {
                { text = achName,                             r = 1,   g = 0.82, b = 0   },
                { text = "Click to open Achievement window", r = 0.7, g = 0.7,  b = 0.7 },
            },
        })
    end)
    hyperHost:SetScript("OnHyperlinkLeave", function() HDG.TooltipEngine:Hide() end)
end

-- |Hhdgrdecor:<itemID>|h on the selected item's name (acq.selectedItem.name):
-- click opens the item's Decor entry, where + Cart, notes and the model live.
local function _parseDecorLink(link)
    local kind, payload = strsplit(":", link or "", 2)
    if kind ~= "hdgrdecor" or not payload or payload == "" then return nil end
    return tonumber(payload)
end

function AcquisitionController:_wireDecorHyperlink(rootFrame)
    local nameLabel = HDG.UI.W(rootFrame, "acquisitionDetailPanel.selectedName")
    local hyperHost = nameLabel and nameLabel.GetParent and nameLabel:GetParent()
    if not (hyperHost and hyperHost.SetHyperlinksEnabled) then return end  -- exception(false-positive): mock-fidelity guard (mirrors the hdgrach wiring above)
    hyperHost:EnableMouse(true)
    hyperHost:SetHyperlinksEnabled(true)
    hyperHost:SetScript("OnHyperlinkClick", function(_, link)
        local itemID = _parseDecorLink(link)
        if not itemID then return end
        CH.Mechanics.JumpToDecor(itemID)
    end)
    hyperHost:SetScript("OnHyperlinkEnter", function(self, link)
        if not _parseDecorLink(link) then return end
        HDG.TooltipEngine:Show(self, {
            anchor     = "ANCHOR_CURSOR",
            extraLines = {
                { text = HDG.Locale:Get("ACQ_DECOR_LINK_HINT"), r = 0.7, g = 0.7, b = 0.7 },
            },
        })
    end)
    hyperHost:SetScript("OnHyperlinkLeave", function() HDG.TooltipEngine:Hide() end)
end

-- Show-on-map: open world map + drop pin via HDG.Waypoints.
function AcquisitionController:_wireShowOnMap(rootFrame)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.showOnMapBtn", function()
        local state  = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local vendor = HDG.Selectors:Call("acq.selectedVendor", state, {})
        if not (vendor and vendor.mapID and vendor.x and vendor.y) then return end
        if HDG.Waypoints:ShowOnMap(vendor.mapID, vendor.x, vendor.y, vendor.name) ~= false then  -- hygiene A7
            HDG.Log:Info("waypoints_user", "Showing " .. vendor.name .. " on map")
        end
    end)
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

function AcquisitionController:Wire(rootFrame)
    -- Active-filter chips overflow horizontally (the layout engine has no flow/wrap),
    -- so clip the list panel: chips cut off at its edge instead of bleeding into the
    -- detail panel. Dropdown popups are top-level frames -> clipping never hides them.
    local listPanel = rootFrame.panels and rootFrame.panels["acquisitionListPanel"]
    if listPanel and listPanel.SetClipsChildren then  -- exception(false-positive): mock rootFrame may lack panels / Frame methods
        listPanel:SetClipsChildren(true)
    end

    local itemList = HDG.UI.W(rootFrame, "acquisitionListPanel.itemList")
    if itemList and itemList.WireStoreSelectionSync then
        itemList:WireStoreSelectionSync("session.ui.acquisition.selectedItemID",
            function(ed, id) return id ~= nil and ed.itemID == id end)
    end

    -- Find Decor + Recipes scroll list (shares acq.list cell). Recipe rows wire
    -- selectedRecipeItemID via the acqVendorItemListRow factory; this syncs the
    -- highlight to selectedItemID like the item list.
    local recipeList = HDG.UI.W(rootFrame, "acquisitionListPanel.recipeList")
    if recipeList and recipeList.WireStoreSelectionSync then
        recipeList:WireStoreSelectionSync("session.ui.acquisition.selectedItemID",
            function(ed, id) return id ~= nil and ed.itemID == id end)
    end

    local vendorList = HDG.UI.W(rootFrame, "acquisitionListPanel.vendorList")
    if vendorList and vendorList.WireStoreSelectionSync then
        -- Same identity rule as acq.selectedVendor and the auto-select guard in
        -- Refresh: npcID when set; for npcID-less vendors (catalog-only NPCs,
        -- the synthetic World Vendors groupings) the (name, zone) SelectVendor
        -- stamps. A bare `ed.npcID == id` with a nil id matched the FIRST
        -- npcID-less row -- a wrong highlight, and now a wrong scroll.
        vendorList:WireStoreSelectionSync("session.ui.acquisition.selectedNpcID",
            function(ed, id)
                if id ~= nil then return ed.npcID == id end
                local ui = HDG.Store:GetState().session.ui.acquisition  -- exception(false-positive): top-level controller read, not a row factory
                if ui.selectedVendorName == nil then return false end
                return ed.npcID == nil and ed.name == ui.selectedVendorName
                    and (ed.catalogZone or ed.zone) == ui.selectedVendorZone  -- exception(nullable): catalogZone is the catalog's zone when known, zone the augment's
            end)
    end

    -- Search editbox: every keystroke dispatches. Filters acq.vendors via
    -- the acq.filterQuery selector chain. Same pattern as Decor's search.
    HDG.UI.WireSearchBox(rootFrame, "acquisitionListPanel.search", "acquisition", "searchQuery")

    -- Preset chips (SSoT: ACQ_PRESETS; reducer handles toggle-off on re-click).
    for _, p in ipairs(HDG.Constants.ACQ_PRESETS or {}) do
        local captured = p.value
        HDG.UI.OnClick(rootFrame, "acquisitionListPanel.preset_" .. captured, function()
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.ACQ_SET_PRESET,
                payload = { value = captured },
            })
        end)
    end

    -- Missing toggle: orthogonal to source chips; ANDs with active source filter.
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.missingToggle", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_MISSING })
    end)

    -- Advanced filters toggle: flips the open flag; `visible` binding cascades to children.
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.advancedToggle", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.ACQ_TOGGLE_ADVANCED_FILTERS })
    end)

    -- Reset: atomic clear of all filter axes. Search editbox is user-driven, blank explicitly.
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.resetFilters", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.UI_FILTER_RESET,
            payload = { tab = "acquisition" },
        })
        local searchBox = HDG.UI.W(rootFrame, "acquisitionListPanel.search")
        if searchBox and searchBox.SetText then searchBox:SetText("") end
    end)

    self:_wireFilterTags(rootFrame)
    self:_wireWaypointButton(rootFrame)
    self:_wireWowheadButtons(rootFrame)

    -- Item-view "Add to Cart": no npcID; Shopping selector groups these into "(any vendor)".
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemInfoCartBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local item  = HDG.Selectors:Call("acq.selectedItem", state, {})
        if not item then return end
        if state.account.activeShoppingListId == "" then
            HDG.Log:Warn("shopping",
                "No active shopping list -- open the Shopping tab to create one (item cart)")
            return
        end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.SHOPPING_ITEM_ADD,
            payload = { itemID = item.itemID, qty = 1 },
        })
        HDG.Log:Success("shopping",
            (item.name or "Item") .. " added to shopping list")
    end)

    self:_wireAchievementHyperlinks(rootFrame)
    self:_wireDecorHyperlink(rootFrame)

    -- Items grid/list toggle (account-persisted).
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemsViewGridBtn", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.ACQ_SET_ITEMS_VIEW_MODE,
            payload = { mode = "grid" },
        })
    end)
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.itemsViewListBtn", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.ACQ_SET_ITEMS_VIEW_MODE,
            payload = { mode = "list" },
        })
    end)

    self:_wireShowOnMap(rootFrame)
    self:_wireVendorNoteBox(rootFrame)

    -- Vendor-view "Add to Cart": includes npcID (vendor-scoped).
    HDG.UI.OnClick(rootFrame, "acquisitionDetailPanel.selectedAddToCartBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local item  = HDG.Selectors:Call("acq.selectedItem",   state, {})
        local npcID = HDG.Selectors:Call("acq.selectedNpcID",  state, {})
        if not item then return end
        if state.account.activeShoppingListId == "" then
            HDG.Log:Warn("shopping",
                "No active shopping list -- open the Shopping tab to create one (vendor cart)")
            return
        end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.SHOPPING_ITEM_ADD,
            payload = { itemID = item.itemID, npcID = npcID, qty = 1 },
        })
        HDG.Log:Success("shopping",
            (item.name or "Item") .. " added to shopping list")
    end)

    -- Map All: pin every filtered vendor with coords; open map at the first.
    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.mapAllBtn", function()
        if InCombatLockdown() then return end
        local state   = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local vendors = HDG.Selectors:Call("acq.vendors", state, {})
        local placed  = HDG.Waypoints:SetMultiple(vendors)
        if placed == 0 then
            HDG.Log:Warn("waypoints", "No vendors with coordinates in the current filter.")
            return
        end
        -- Open world map at the first vendor with coords.
        for _, v in ipairs(vendors) do
            if v.mapID and v.x and v.y then
                local uiMapID = (HDG.Waypoints.ZonePctToMap(v.mapID, v.x, v.y))
                if uiMapID then
                    HDG.Waypoints:OpenWorldMapAt(uiMapID)
                    break
                end
            end
        end
        HDG.Log:Info("waypoints_user", string.format("Mapped %d vendor%s.", placed, placed == 1 and "" or "s"))
    end)

    HDG.UI.OnClick(rootFrame, "acquisitionListPanel.clearPinsBtn", function()
        HDG.Waypoints:ClearAllMapPins()
        HDG.Log:Info("waypoints_user", "Map pins cleared.")
    end)
end

function AcquisitionController:Refresh(rootFrame, ctx)
    -- Auto-select first vendor when in vendor mode and selection is nil or stale.
    if _autoSelectPending then
        _autoSelectPending = false
        return
    end
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    local acqUI = state.session.ui.acquisition
    -- Search box reconcile: state is the SSoT (JumpToVendor clears searchQuery
    -- from another window); never clobber mid-typing.
    local sb = HDG.UI.W(rootFrame, "acquisitionListPanel.search")
    if sb and not sb:HasFocus() and sb:GetText() ~= (acqUI.searchQuery or "") then
        sb:SetText(acqUI.searchQuery or "")
    end
    if acqUI.viewMode ~= "vendor" then return end
    local vendors = HDG.Selectors:Call("acq.vendors", state, {})
    if #vendors == 0 then return end
    -- A selection is "still present" if it matches a visible vendor by npcID
    -- (authoritative when set) OR, for npcID-less vendors, by the (name, zone)
    -- the row click stamps. Catalog-only NPCs absent from VendorAugment and
    -- synthetic "World Vendors" groupings have npcID == nil; matching them on
    -- npcID alone never converges -- auto-select would re-stamp nil every pass,
    -- re-triggering Refresh -> Notify -> Refresh until "script ran too long".
    local curID, curName, curZone = acqUI.selectedNpcID, acqUI.selectedVendorName, acqUI.selectedVendorZone
    if curID or curName then
        for _, v in ipairs(vendors) do
            if (curID and v.npcID == curID)
            or (not curID and curName and v.name == curName and (v.catalogZone or v.zone) == curZone) then
                return
            end
        end
    end
    local first = vendors[1]
    if not first then return end
    _autoSelectPending = true
    CH.Mechanics.SelectVendor(first.npcID, first.name, first.catalogZone or first.zone)
end

HDG.Controllers:Register("acquisition", AcquisitionController)
