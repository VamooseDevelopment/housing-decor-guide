-- HDG.ShoppingController -- wirings + heterogeneous row factory for the
-- shopping list view.
--
-- The row factory dispatches on ed.kind. Five row kinds:
--   wishHeader   "Wishlist (N)" toggle row at the top
--   wishItem     individual wishlist item (npcID = nil)
--   zone         "Zone Name (N vendors)" group header
--   vendor       "Vendor Name (N items)" sub-header
--   item         actual item row with qty + right-click context menu
--
-- All collapse-toggle clicks dispatch SHOPPING_TOGGLE_EXPANDED; the reducer
-- flips session.ui.shoppingList.expanded so the selector re-projects + scrollbox
-- re-renders on the next refresh.
--
-- Right-click on item/wishItem rows opens a MenuUtil context menu with
-- Set quantity / Remove / Open vendor (item only).

HDG = HDG or {}
HDG.ShoppingController = HDG.ShoppingController or {}

local ShoppingController = HDG.ShoppingController

-- Register at file load (not Wire()) -- callers push to "shopping" before
-- the user visits the Shopping tab, so Wire() may not have run yet.
if not HDG.Log:HasTag("shopping") then
    HDG.Log:RegisterTags({
        shopping = { user = true, level = "info", duration = 3 },
    })
end

-- ===== Row factory ============================================================
-- Per-kind chrome built ONCE per pooled row; subsequent Configures push state
-- only. Lazy-built because pool rows carry across kinds (item -> zone ->
-- wishHeader) and headers don't need item chrome (and vice versa).
--
-- Item-row anchor budget (right edge inward):
--   delete X       -- right 4,   atlas transmog-icon-remove
--   add (+)        -- right 22,  atlas communities-chat-icon-plus
--   remove (-)     -- right 40,  atlas communities-chat-icon-minus
--   qty "x12"      -- right 60,  caption fontstring
--   chips strip    -- right 92,  inline-colored caption fontstring
--   name fontstring -- left of chips, right-capped at -200
--   icon 16x16     -- left 4
--   name leading-edge -- left 24
-- Zone-row anchor budget:
--   pinBtn         -- right 4, atlas Waypoint-MapPin-ChatIcon
--   ("N vendors")  -- right 22

local A = HDG.Constants.ACTIONS


local function _ensureItemChrome(row)
    if row._shoppingItemChromeBuilt then return end

    -- ARTWORK: above EnsureRowChrome's BACKGROUND fills (zebra/selectedBg).
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- trim default icon border
    row._iconTex = icon

    -- Chips strip -- single inline-colored fontstring; HDG.UI.GateChips
    -- produces the |cffXXXXXX[REP]|r |cffXXXXXX[VENDOR]|r etc. composition.
    local chips = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(chips, "caption")
    chips:SetPoint("RIGHT", row, "RIGHT", -92, 0)
    chips:SetJustifyH("RIGHT")
    row._chipsFs = chips

    -- Cart-minus (qty -1) at RIGHT -40, communities-chat-icon-minus atlas.
    local minus = HDG.UI:AtlasButton(row, "communities-chat-icon-minus", 14)
    minus:SetPoint("RIGHT", row, "RIGHT", -40, 0)
    minus:Hide()
    row._minusBtn = minus

    -- Cart-plus (qty +1) at RIGHT -22, communities-chat-icon-plus atlas.
    local plus = HDG.UI:AtlasButton(row, "communities-chat-icon-plus", 14)
    plus:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    plus:Hide()
    row._plusBtn = plus

    -- Delete X at RIGHT -4, transmog-icon-remove atlas.
    local del = HDG.UI:AtlasButton(row, "transmog-icon-remove", 14)
    del:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    del:Hide()
    row._deleteBtn = del

    row._shoppingItemChromeBuilt = true
end

-- Pin button on zone rows. Walks the zone's vendors and sets waypoints for
-- each one with valid coords.
local function _ensureZonePin(row)
    if row._shoppingZonePinBuilt then return end
    row._zonePinBtn = HDG.UI.RowPinButton(row)
    row._shoppingZonePinBuilt = true
end

local function _hideAllChrome(row)
    if row._shoppingItemChromeBuilt then
        row._iconTex:Hide()
        row._chipsFs:SetText("")
        row._minusBtn:Hide()
        row._plusBtn:Hide()
        row._deleteBtn:Hide()
    end
    if row._shoppingZonePinBuilt then
        row._zonePinBtn:Hide()
    end
    if row._shoppingAhBtnsBuilt then
        row._ahSendBtn:Hide()
        row._ahCraftBtn:Hide()
    end
end

local function _showItemChrome(row, ed)
    _ensureItemChrome(row)
    -- Icon -- placeholder ? when unresolved (cache will warm + the
    -- session.itemNames.names read re-fires the selector).
    row._iconTex:SetTexture(ed.iconID or HDG.Constants.PLACEHOLDER_ICON)
    row._iconTex:Show()
    -- Chips -- reuse Acquire's exact same renderer (single derivation point).
    row._chipsFs:SetText(HDG.UI.GateChips(ed.itemID))
    -- Wire +/- and X. Only (itemID, npcID) are captured per Configure; qty is NOT
    -- snapshotted -- the buttons dispatch a relative ADJUST_QTY intent so rapid
    -- clicks accumulate against current state (re-render is deferred a frame, so a
    -- captured absolute qty would collide). The reducer removes the row at qty <=0.
    local itemID, npcID = ed.itemID, ed.npcID
    row._plusBtn:SetScript("OnClick", function()
        HDG.Store:Dispatch({
            type = A.SHOPPING_ITEM_ADJUST_QTY,
            payload = { itemID = itemID, npcID = npcID, delta = 1 },
        })
    end)
    row._minusBtn:SetScript("OnClick", function()
        HDG.Store:Dispatch({
            type = A.SHOPPING_ITEM_ADJUST_QTY,
            payload = { itemID = itemID, npcID = npcID, delta = -1 },
        })
    end)
    row._deleteBtn:SetScript("OnClick", function()
        HDG.Store:Dispatch({
            type = A.SHOPPING_ITEM_REMOVE,
            payload = { itemID = itemID, npcID = npcID },
        })
    end)
    row._plusBtn:Show()
    row._minusBtn:Show()
    row._deleteBtn:Show()
end

-- Set a map waypoint for every distinct vendor in `zoneName`. Walks the
-- projected shopping entries (the row factory has no direct vendor list) and
-- de-dups by npcID. `e.npcID/e.vendor` filters the heterogeneous list down to
-- vendor entries; coordless vendors are still marked seen (so a later coorded
-- dupe -- same npcID -- can't double-pin). Returns the pin count for the log.
local function _pinZoneVendors(zoneName)
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    local entries = HDG.Selectors:Call("shopping.activeListEntries", state, {})
    -- RunBatch emits ONE consolidated waypoint message for the whole zone.
    return HDG.Waypoints:RunBatch(function()
        local seen = {}
        for _, e in ipairs(entries) do
            local v = e.vendor
            if e.npcID and v and v.zone == zoneName and not seen[e.npcID] then
                seen[e.npcID] = true
                if v.mapID > 0 and v.x and v.y then
                    HDG.Waypoints:Set(v.mapID, v.x, v.y, v.name)
                end
            end
        end
    end)
end

local function _showZonePin(row, ed)
    _ensureZonePin(row)
    local zoneName = ed.zone
    row._zonePinBtn:SetScript("OnClick", function()
        _pinZoneVendors(zoneName)   -- RunBatch emits the consolidated message
    end)
    row._zonePinBtn:Show()
end

-- Send every Auction House (crafted/BoE) item in the active list to Auctionator as
-- one exact-name search list. Mirrors the Recipes materials "Add All" path.
local function _sendAhToAuctionator()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    local entries = HDG.Selectors:Call("shopping.activeListEntries", state, {})
    local items = {}
    for _, e in ipairs(entries) do
        if (not e.npcID) and e.isTradeable then
            items[#items + 1] = { id = e.itemID, qty = e.qty or 1 }
        end
    end
    local n, present = HDG.UI.SendReagentsToAuctionator("HDG Auction House", items)
    if not present then
        HDG.Log:Warn("shopping", "Auctionator not installed")
    elseif n > 0 then
        HDG.Log:Info("shopping", "Sent " .. n .. " item" .. (n > 1 and "s" or "") .. " to Auctionator")
    else
        HDG.Log:Info("shopping", "No Auction House items to send")
    end
end

-- Send every Auction House (crafted/BoE) item in the active list to the Recipes
-- craft queue. Crafted decor can be made instead of bought; this is the "make them
-- all" counterpart to the Auctionator button. One summary toast (per-item silent).
local function _sendAhToCraftingQueue()
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    local entries = HDG.Selectors:Call("shopping.activeListEntries", state, {})
    local n = 0
    for _, e in ipairs(entries) do
        if (not e.npcID) and e.isTradeable then
            local rid = HDG.StaticData.Recipes:Get(e.itemID) and e.itemID
            if rid then
                HDG.UI.QueueRecipe(rid, e.itemID, nil, { qty = e.qty or 1, silent = true })
                n = n + 1
            end
        end
    end
    if n > 0 then
        HDG.Log:Info("queue", "Added " .. n .. " recipe" .. (n > 1 and "s" or "") .. " to the craft queue")
    else
        HDG.Log:Warn("shopping", "No craftable items to queue")
    end
end

-- Crafting/Auction House header buttons (RIGHT edge): Auctionator (buy) at the very
-- edge, crafting queue (make) to its left. Lazily built per pooled row.
local function _ensureAhButtons(row)
    if row._shoppingAhBtnsBuilt then return end
    local ahBtn = HDG.UI:AtlasButton(row, HDG.Constants.SHOPPING_LIST_ICON_ATLAS, 14)
    ahBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    ahBtn:Hide()
    HDG.TooltipEngine:Attach(ahBtn, { title = "Send all to Auctionator", anchor = "ANCHOR_RIGHT" })
    row._ahSendBtn = ahBtn

    local craftBtn = HDG.UI:AtlasButton(row, "Professions-Crafting-Orders-Icon", 14)
    craftBtn:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    craftBtn:Hide()
    HDG.TooltipEngine:Attach(craftBtn, { title = "Send all to crafting queue", anchor = "ANCHOR_RIGHT" })
    row._ahCraftBtn = craftBtn

    row._shoppingAhBtnsBuilt = true
end

local function _showAhButtons(row)
    _ensureAhButtons(row)
    row._ahSendBtn:SetScript("OnClick", _sendAhToAuctionator)
    row._ahSendBtn:Show()
    row._ahCraftBtn:SetScript("OnClick", _sendAhToCraftingQueue)
    row._ahCraftBtn:Show()
end

-- Mouse-action hints on every item row's tooltip, by where a click takes the
-- item (ed.opens). The header glyphs carry the same words, but the row is where
-- a player hovers when deciding what to do with an item, so the gesture has to
-- be readable there too.
local SHOP_ITEM_HINTS = {
    recipe = { leftText  = "locale:SHOP_HINT_LEFT_RECIPE",
               shiftText = "locale:SHOP_HINT_SHIFT", rightText = "locale:SHOP_HINT_RIGHT" },
    decor  = { leftText  = "locale:SHOP_HINT_LEFT_DECOR",
               shiftText = "locale:SHOP_HINT_SHIFT", rightText = "locale:SHOP_HINT_RIGHT" },
    none   = { shiftText = "locale:SHOP_HINT_SHIFT", rightText = "locale:SHOP_HINT_RIGHT" },
}

-- Item-row tooltip: Blizzard's item body, the resolved vendor when a wishlist
-- row knows one, a crafted item's recipe (profession, materials), then the
-- click hints. Headers stamp no _shopItemID -> no tooltip.
local function _shoppingRowTooltip(self)
    if not self._shopItemID then return nil end  -- exception(nullable): header / non-item rows don't stamp it
    local af = self._shopVendor
    local extraLines = {}
    if af then  -- exception(nullable): only resolved rows know a vendor; the item tooltip shows regardless
        local zone = (af.zone and af.zone ~= "") and (" -- " .. af.zone) or ""
        extraLines[1] = { text = "Available from: " .. (af.name or "?") .. zone,
                          r = 0.6, g = 0.78, b = 0.95 }
    end
    if self._shopOpens == "recipe" then
        HDG.TooltipRecipes.AppendCraftLines(extraLines, self._shopItemID, self._shopQty)
    end
    HDG.TooltipEngine.AppendClickHints(extraLines, SHOP_ITEM_HINTS[self._shopOpens])
    return {
        itemID     = self._shopItemID,
        anchor     = "ANCHOR_RIGHT",
        extraLines = extraLines,
    }
end

-- One-time base layout (pooled rows): name + right FontStrings.
local function _layoutShoppingRow(row)
    HDG.UI:EnsureRowChrome(row)
    local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
    row._nameFs = name

    local right = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    row._rightFs = right

    HDG.TooltipEngine:Attach(row, _shoppingRowTooltip)
end

-- Per-kind row configurers (dispatch-table targets; doc cliff #2). Each owns
-- one ed.kind's height/anchors/text/click.
local function _configureWishHeaderRow(row, ed)
    row:SetHeight(20)
    row._nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    row._nameFs:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    row._rightFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._nameFs:SetText(HDG.Theme:ColorCode("semantic.accent")
        .. HDG.UI.CollapsePrefix(ed.collapsed) .. "Wishlist" .. "|r")
    row._rightFs:SetText("(" .. ed.count .. ")")
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_TOGGLE_EXPANDED,
            payload = { bucket = "wishList" } })
    end)
end

local function _configureZoneRow(row, ed)
    row:SetHeight(22)
    row._nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    -- Leave space for pin button (-22) + right-text (-30).
    row._nameFs:SetPoint("RIGHT", row, "RIGHT", -100, 0)
    row._rightFs:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    row._nameFs:SetText(HDG.Theme:ColorCode("semantic.accent")
        .. HDG.UI.CollapsePrefix(ed.collapsed) .. ed.zone .. "|r")
    row._rightFs:SetText("(" .. ed.vendorCount .. " vendors)")
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_TOGGLE_EXPANDED,
            payload = { bucket = "zones", key = ed.zone } })
    end)
    _showZonePin(row, ed)
end

local function _configureVendorRow(row, ed)
    row:SetHeight(20)
    row._nameFs:SetPoint("LEFT", row, "LEFT", 16, 0)
    row._nameFs:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    row._rightFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._nameFs:SetText(HDG.Theme:ColorCode("semantic.accent")
        .. HDG.UI.CollapsePrefix(ed.collapsed) .. ed.name .. "|r")
    row._rightFs:SetText("(" .. ed.itemCount .. " items)")
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_TOGGLE_EXPANDED,
            payload = { bucket = "vendors", key = ed.npcID } })
    end)
    -- Vendor name is a hyperlink: click jumps to Shop by Vendor; the rest of
    -- the row still toggles collapse (Discord request).
    HDG.UI:ShowNameLink(row, row._nameFs, HDG.TooltipRecipes.VendorJump, function()
        HDG.ControllerHelpers.Mechanics.JumpToVendor(ed.npcID, ed.name, ed.zone)
    end)
end

-- A plain click on an item opens where its question is answered: a crafted
-- item's recipe (which profession, what materials), else its Decor entry.
local function _openItem(ed)
    if ed.opens == "recipe" then
        HDG.ControllerHelpers.Mechanics.JumpToRecipe(ed.itemID)
    elseif ed.opens == "decor" then
        HDG.ControllerHelpers.Mechanics.JumpToDecor(ed.itemID)
    end
end

local function _configureItemRow(row, ed)
    row:SetHeight(20)
    -- Item-shape chrome: icon 16 on left, name after icon, name right-capped at
    -- -200 (chips + qty + 3 btns budget).
    row._nameFs:SetPoint("LEFT", row, "LEFT", 24, 0)
    row._nameFs:SetPoint("RIGHT", row, "RIGHT", -200, 0)
    row._rightFs:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    row._nameFs:SetText(HDG.UI.ItemName(ed.itemID))
    row._rightFs:SetText("x" .. ed.qty)
    -- Stamp itemID on EVERY item row so the tooltip shows Blizzard's full item
    -- body, incl. the native "Total Owned: N (Placed/Storage)" line. The vendor
    -- hint is optional -- only resolved rows know a "where to buy".
    row._shopItemID = ed.itemID
    row._shopVendor = ed.availableFrom  -- exception(nullable): AH-only / unresolved items have no vendor
    row._shopOpens  = ed.opens
    row._shopQty    = ed.qty
    _showItemChrome(row, ed)
    -- Shift-click links the item, which lands in the Auction House search bar
    -- when the AH is open on a Buy tab -- the Warehouse and Recipes materials
    -- gesture. The Crafting / Auction House section is where a player goes to
    -- buy what they cannot make, so its rows carry it (owner, 2026-09-07);
    -- wishlist and vendor items take it too so one gesture reads the same on
    -- every row. A plain left click opens the item (_openItem); right-click
    -- owns the menu.
    HDG.UI.WireLeftRightClick(row, function()
        if IsShiftKeyDown() then
            HDG.UI.LinkMaterial(ed.itemID, HDG.UI.ItemName(ed.itemID))
            return
        end
        _openItem(ed)
    end, function()
        ShoppingController:_OpenItemContextMenu(row, ed)
    end)
end

local function _configureAhHeaderRow(row, ed)
    row:SetHeight(22)
    row._nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    -- Leave space for two buttons (-4 Auctionator, -22 crafting queue) + count (-40).
    row._nameFs:SetPoint("RIGHT", row, "RIGHT", -120, 0)
    row._rightFs:SetPoint("RIGHT", row, "RIGHT", -40, 0)
    row._nameFs:SetText(HDG.Theme:ColorCode("semantic.accent")
        .. HDG.UI.CollapsePrefix(ed.collapsed) .. "Crafting / Auction House" .. "|r")
    row._rightFs:SetText("(" .. ed.count .. ")")
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_TOGGLE_EXPANDED,
            payload = { bucket = "ahList" } })
    end)
    _showAhButtons(row)
end

local _CONFIGURE_SHOPPING_BY_KIND = {
    wishHeader = _configureWishHeaderRow,
    ahHeader   = _configureAhHeaderRow,
    zone       = _configureZoneRow,
    vendor     = _configureVendorRow,
    wishItem   = _configureItemRow,
    ahItem     = _configureItemRow,
    item       = _configureItemRow,
}

local function _shoppingRowFactory(template)
    return {
        Configure = function(row, ed)
            if not row._shoppingLaidOut then
                _layoutShoppingRow(row)
                row._shoppingLaidOut = true
            end
            -- Reset shared state (pooled rows).
            row._nameFs:SetText("")
            row._rightFs:SetText("")
            if row._nameLinkBtn then row._nameLinkBtn:Hide() end
            row._nameFs:ClearAllPoints()
            row._rightFs:ClearAllPoints()
            row:SetScript("OnClick", nil)
            row:RegisterForClicks("LeftButtonUp")
            -- Tooltip stamps (item rows only; _shopVendor on resolved wishItems only).
            row._shopItemID, row._shopVendor, row._shopOpens, row._shopQty = nil, nil, nil, nil
            _hideAllChrome(row)

            local handler = _CONFIGURE_SHOPPING_BY_KIND[ed.kind]
            if handler then handler(row, ed) end

            -- zone + wishlist headers get the panel-header band; vendor sub-headers
            -- rely on accent text alone (sub-tier); item rows stay plain.
            local isTopHeader = ed.kind == "zone" or ed.kind == "wishHeader" or ed.kind == "ahHeader"
            HDG.Theme:Register(row, "RowChrome", { selected = false, header = isTopHeader })
        end,
        Reset = function(row)
            if row._nameFs  then row._nameFs:SetText("")  end
            HDG.UI.ClearRowText(row, "_rightFs")
            row:SetScript("OnClick", nil)
            _hideAllChrome(row)
        end,
    }
end

HDG.Rows:Register("shoppingRow", {
    font    = "body",
    height  = 20,
    factory = _shoppingRowFactory,
    key     = function(ed)
        if ed.kind == "wishHeader" then return "wh" end
        if ed.kind == "wishItem"   then return "wi_" .. tostring(ed.itemID) end
        if ed.kind == "ahHeader"   then return "ah" end
        if ed.kind == "ahItem"     then return "ai_" .. tostring(ed.itemID) end
        if ed.kind == "zone"       then return "z_"  .. tostring(ed.zone) end
        if ed.kind == "vendor"     then return "v_"  .. tostring(ed.npcID) end
        if ed.kind == "item"       then return "i_"  .. tostring(ed.npcID) .. "_" .. tostring(ed.itemID) end
        return "?"
    end,
})

-- ===== Context menu (item right-click) =======================================

function ShoppingController:_OpenItemContextMenu(anchor, ed)
    local A = HDG.Constants.ACTIONS
    local items = {
        { isTitle = true, text = HDG.UI.ItemName(ed.itemID) },
        { text = "Set quantity...", callback = function()
            -- Save context for the popup's OnAccept to read.
            local listID = HDG.Store:GetState().account.activeShoppingListId  -- exception(false-positive): top-level controller read
            _G.StaticPopup_Show("HDGR_SHOPPING_SET_QTY", nil, nil, {
                listID = listID, itemID = ed.itemID, npcID = ed.npcID,
            })
        end },
        { text = "Remove from list", callback = function()
            HDG.Store:Dispatch({
                type    = A.SHOPPING_ITEM_REMOVE,
                payload = { itemID = ed.itemID, npcID = ed.npcID },
            })
        end },
    }
    -- Open on world map: stored cart vendor (npcID), or the catalog-resolved vendor
    -- for a wishlist item (availableFrom; mapID present only when waypointable).
    if ed.npcID then
        items[#items + 1] = { text = "Open vendor on map", callback = function()
            local aug = HDG.StaticData.VendorAugment:Get(ed.npcID)
            if aug and aug.mapID and aug.mapID > 0 then
                HDG.Waypoints:Set(aug.mapID, aug.x, aug.y, aug.name)
            end
        end }
    elseif ed.availableFrom and ed.availableFrom.mapID then
        local af = ed.availableFrom
        items[#items + 1] = { text = "Open vendor on map", callback = function()
            HDG.Waypoints:Set(af.mapID, af.x, af.y, af.name)
        end }
    elseif ed.kind == "ahItem" then
        items[#items + 1] = { text = "Search on Auctionator", callback = function()
            local _, present = HDG.UI.SendReagentsToAuctionator("HDG Auction House",
                { { id = ed.itemID, qty = ed.qty or 1 } })
            if not present then HDG.Log:Warn("shopping", "Auctionator not installed") end
        end }
    end
    HDG.UI.ShowMenu(anchor, items)
end

-- ===== Controller lifecycle ====================================================

-- Decode + import an exported list blob (HDG or HDG "HDGVL:1:" format), then
-- log an HDG-style summary. Shared by the Import dialog's onAccept. The codec
-- resolves decorID<->itemID against the catalog observer (Wowhead exports use
-- decorID; HDG exports use decor itemID), so mixed / 3rd-party blobs import clean.
local function _importShoppingList(value)
    local preview = HDG.ShoppingCodec.Decode(value)
    -- Same source collection already present? The import replaces it in place
    -- (dedupe by meta.url) rather than stacking a duplicate -- reflect that in the log.
    local replaced = false
    local url = preview and preview.meta and preview.meta.url
    if url and url ~= "" then
        for _, list in pairs(HDG.Store:GetState().account.vendorShoppingLists) do
            if list.meta and list.meta.url == url then replaced = true; break end
        end
    end
    HDG.Store:Dispatch({ type = A.SHOPPING_LIST_IMPORT, payload = { encoded = value } })
    if preview then
        local src  = (preview.meta and preview.meta.source) or "unknown"
        local desc = (preview.meta and preview.meta.desc)   or preview.name or ""
        local date = HDG.Format.FriendlyDate(preview.meta and preview.meta.date) or ""
        local trailer = desc ~= "" and (" | " .. desc) or ""
        if date ~= "" then trailer = trailer .. " (" .. date .. ")" end
        HDG.Log:Success("shopping",
            ("Imported: %d items | Source: %s%s | %s"):format(
                #preview.items, src, trailer, replaced and "Updated existing list" or "Created as new list"))
        -- Resolve + persist vendor npcIDs on the freshly-imported list (the import
        -- carries the blob's npcIDs verbatim; this fills in the ones it left at 0).
        ShoppingController:_EnrichListVendors(HDG.Store:GetState().account.activeShoppingListId)
    else
        HDG.Log:Warn("shopping",
            "Import failed -- unrecognised format (expected HDGVL:1:...)")
    end
end

-- True when moving an entry from one vendor to another only changes WHICH
-- housing neighborhood you walk into -- both ends stand in Founder's Point or
-- Razorwind Shores.
--
-- This is the whole safety rule for re-resolving a list that already has
-- vendors on it. An entry pointing at a vendor anywhere else was either bought
-- deliberately from that merchant or is only sold there, and the neighborhood
-- toggle has no business moving it. Inside the pair, moving is free: 18
-- merchants stand in both, so it is usually the same person and always the
-- same stock.
local function _isNeighborhoodMove(fromNpc, toNpc)
    local Aug  = HDG.StaticData.VendorAugment
    local from, to = Aug:Get(fromNpc), Aug:Get(toNpc)
    if not (from and to) then return false end  -- exception(nullable): vendor not in VendorAugment -- unroutable, so not ours to move
    local N = HDG.Constants.NEIGHBORHOOD_MAP_IDS
    return N[from.mapID] == true and N[to.mapID] == true
end

-- Resolve + persist vendor npcIDs for a list's entries, so vendor-buyable items
-- leave the Wishlist, bucket under their vendor, and carry the npcID into
-- Export. Items with no catalog vendor (crafted / drops / quests / achievements)
-- resolve to nothing and correctly stay in the Wishlist. No-op until the catalog
-- has swept (sweepGeneration 0 = no baked vendors yet).
--
-- Runs for entries that ALREADY have a vendor too, not only blanks: flipping the
-- neighborhood toggle has to move a list that was resolved under the old
-- preference. `_isNeighborhoodMove` is what keeps that from touching anything
-- else on the list.
function ShoppingController:_EnrichListVendors(listID)
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    if state.session.resolvers.catalog.tick == 0 then return end  -- exception(nullable): catalog not swept yet
    local list = listID and state.account.vendorShoppingLists[listID] or nil
    if not list then return end  -- exception(nullable): list may be missing/empty
    local prefFaction  = HDG.Selectors:Call("shopping.neighborhood", state, {})
    local preferredMap = prefFaction
        and HDG.Constants.NEIGHBORHOOD_MAP_BY_FACTION[prefFaction] or nil
    local res, n = {}, 0
    for _, entry in ipairs(list.items) do
        local row = HDG.HousingCatalogObserver:GetRow(entry.itemID)
        local best = HDG.VendorRank.Pick(row, preferredMap)
        local npc  = best and best.npcID
        if npc and npc ~= entry.npcID
           and (not entry.npcID or _isNeighborhoodMove(entry.npcID, npc)) then
            res[entry.itemID] = npc; n = n + 1
        end
    end
    if n > 0 then
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_RESOLVE_VENDORS,
            payload = { listID = listID, resolutions = res } })
        HDG.Log:Info("shopping", "Resolved vendors for " .. n .. " item" .. (n > 1 and "s" or ""))
    end
end

-- Every action that leaves the active list holding entries whose vendor is not
-- resolved yet, or resolved under a preference that no longer applies:
--   DECOR_CATALOG_READY     -- the sweep that makes resolution possible at all
--   SHOPPING_ITEM_ADD       -- an item wishlisted from any surface while we're open
--   SHOPPING_LIST_IMPORT    -- an import/re-import REPLACES the list record, so
--                              entries arrive unresolved (npcID 0 decodes to nil)
--   SHOPPING_SET_NEIGHBORHOOD -- re-resolve under the new preference
--   SHOPPING_LIST_ACTIVATE  -- enrich only runs on the ACTIVE list
-- Miss one and its entries sit in the Wishlist with no vendor header until the
-- window is closed and reopened, which is the only other enrich trigger (OnShow).
-- IMPORT was the miss Soul reported 2026-09-21: routing a blueprint's missing
-- decor twice dropped every NPC header on the second press, because the first
-- press opened the window (OnShow enriched) and the second had nothing to fire.
local ENRICH_ON = {
    DECOR_CATALOG_READY       = true,
    SHOPPING_ITEM_ADD         = true,
    SHOPPING_LIST_IMPORT      = true,
    SHOPPING_SET_NEIGHBORHOOD = true,
    SHOPPING_LIST_ACTIVATE    = true,
}

-- Subscribe once (Wire may run per window rebuild).
function ShoppingController:_SubscribeEnrich()
    if self._enrichSubscribed then return end
    self._enrichSubscribed = true
    local triggers = {}
    for name in pairs(ENRICH_ON) do triggers[A[name]] = true end
    HDG.Store:Subscribe(function(actionType)
        if triggers[actionType] then
            self:_EnrichListVendors(HDG.Store:GetState().account.activeShoppingListId)
        end
    end)
end

function ShoppingController:Wire(rootFrame)
    local A = HDG.Constants.ACTIONS

    -- Refresh the housing catalog when the shopping window opens (mirrors the
    -- house editor -- HouseEditorCompanion:_onEditorShown). RequestLoad is
    -- idempotent: it only sweeps when the catalog is cold (status == "idle").
    -- The sweep populates byItemID + bumps sweepGeneration, so the decor-only
    -- filter in shopping.activeListEntries resolves on open instead of waiting
    -- for an incidental sweep from another surface (tabbing the main window).
    rootFrame:HookScript("OnShow", function()
        HDG.HousingCatalogObserver:RequestLoad("shopping")
        -- Enrich now if the catalog's already warm (re-open); a cold open no-ops
        -- here and the DECOR_CATALOG_READY subscription below catches the sweep.
        ShoppingController:_EnrichListVendors(HDG.Store:GetState().account.activeShoppingListId)
    end)

    ShoppingController:_SubscribeEnrich()

    -- Window chrome close [X]. Dismisses the shopping floating window by
    -- flipping account.ui.shoppingWidgetShown off. HDG.Window's reconciler
    -- owns the resulting Hide() via visibilityBinding.
    HDG.UI.OnClick(rootFrame, "shoppingHeaderPanel.close", function()
        HDG.Store:Dispatch({ type = A.SHOPPING_WIDGET_TOGGLE })
    end)

    -- Flip the neighborhood preference. Reads the RESOLVED side, not the stored
    -- value: until the player picks one it is stored "" and shown as their own
    -- faction, so flipping the STORED value would write back the side the knob
    -- is already sitting on and the first click would appear to do nothing.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.neighborhoodToggle", function()
        local state   = HDG.Store:GetState()  -- exception(false-positive): top-level controller wire, not a row factory
        local current = HDG.Selectors:Call("shopping.neighborhood", state, {})
        HDG.Store:Dispatch({ type = A.SHOPPING_SET_NEIGHBORHOOD,
            payload = { value = (current == "alliance") and "horde" or "alliance" } })
    end)

    -- Rename the active list. Pre-filled with the current name and opened with
    -- it selected, so the common case (a blueprint import landing as "Aneyiah"
    -- when you wanted "Bedroom") is type-over-and-Enter. PromptInput trims and
    -- drops an empty string, so a cleared box cancels rather than blanking the
    -- name. Asked for by moondazze, who could not tell her imported lists apart.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.renameListBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller wire, not a row factory
        local id    = state.account.activeShoppingListId
        local list  = state.account.vendorShoppingLists[id]
        if not list then
            HDG.Log:Warn("shopping", "No active list to rename")
            return
        end
        HDG.UI:PromptInput(HDG.Locale:Get("SHOP_RENAME_PROMPT"):format(list.name), {
            initialText = list.name,
            acceptText  = HDG.Locale:Get("SHOP_RENAME_LIST"),
            hint        = HDG.Locale:Get("SHOP_RENAME_HINT"),
            onAccept    = function(value)
                HDG.Store:Dispatch({ type = A.SHOPPING_LIST_RENAME,
                    payload = { id = id, name = value } })
                HDG.Log:Success("shopping", "Renamed shopping list to '" .. value .. "'")
            end,
        })
    end)

    -- New list -- StaticPopup prompts for the name. EditBox text on Accept
    -- gets dispatched as SHOPPING_LIST_CREATE { name }.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.newListBtn", function()
        _G.StaticPopup_Show("HDGR_SHOPPING_NEW_LIST")
    end)

    -- Delete active list (confirmed). The button is hidden at 1 list (visible =
    -- shopping.hasMultipleLists), so a delete always leaves >=1 -> the reducer
    -- re-points activeShoppingListId to a remaining list. UI.Confirm memoizes the
    -- dialog by id, so the per-list name/id flow through textArg1 + data, NOT a
    -- captured closure (which would go stale on the 2nd delete).
    HDG.UI.OnClick(rootFrame, "shoppingPanel.deleteListBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local id    = state.account.activeShoppingListId
        local list  = state.account.vendorShoppingLists[id]
        if not list then
            HDG.Log:Warn("shopping", "No active list to delete")
            return
        end
        HDG.UI.Confirm({
            id       = "HDGR_SHOPPING_DELETE_LIST",
            text     = "Delete shopping list \"%s\"? This cannot be undone.",
            textArg1 = list.name,   -- every list factory stamps a name
            data     = id,
            accept   = "Delete",
            cancel   = "Cancel",
            onAccept = function(_, listId)
                HDG.Store:Dispatch({ type = A.SHOPPING_LIST_DELETE, payload = { id = listId } })
                HDG.Log:Info("shopping", "Deleted shopping list")
            end,
        })
    end)

    -- Clear -- empties the active list (no-op when no active list). Confirms,
    -- like Delete beside it: the items are gone for good either way, and two
    -- adjacent buttons where one asks and the other doesn't reads as a bug.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.clearBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller read
        local id    = state.account.activeShoppingListId
        local list  = state.account.vendorShoppingLists[id]
        if not list then  -- exception(nullable): "" (no active list) or a stale id -- same shape as Delete above
            HDG.Log:Warn("shopping", "No active list to clear")
            return
        end
        HDG.UI.Confirm({
            id       = "HDGR_SHOPPING_CLEAR_LIST",
            text     = "Clear every item from shopping list \"%s\"? This cannot be undone.",
            textArg1 = list.name,
            data     = id,
            accept   = "Clear",
            cancel   = "Cancel",
            onAccept = function(_, listId)
                HDG.Store:Dispatch({ type = A.SHOPPING_LIST_CLEAR, payload = { id = listId } })
                HDG.Log:Info("shopping", "Cleared all items from active list")
            end,
        })
    end)

    -- Export -- encode active list + show in CopyDialog for user to copy.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.exportBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local id = state.account.activeShoppingListId
        local list = state.account.vendorShoppingLists[id]
        if not list then
            HDG.Log:Warn("shopping", "No active list to export")
            return
        end
        local encoded = HDG.ShoppingCodec.Encode(list)
        local dialog = HDG.UI:CopyDialog()
        if dialog and dialog.Open then
            dialog:Open("Export: " .. (list.name or "?"), encoded)
            HDG.Log:Info("shopping", "Export ready -- copy the text from the dialog")
        end
    end)

    -- Import -- themed multi-line InputDialog (matches Export's CopyDialog look,
    -- unlike Blizzard's single-line StaticPopup). Codec validates + sanitizes;
    -- bad input no-ops. _importShoppingList does the decode + dispatch + summary.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.importBtn", function()
        HDG.UI:PromptInput("Import Shopping List", {
            hint       = "Paste an exported list (HDG or HDG), then Import.",
            acceptText = "Import",
            onAccept   = _importShoppingList,
        })
    end)

    -- Waypoint All -- chain a waypoint per vendor in the active list.
    -- Walks the tree projection (already grouped by vendor) so we visit
    -- each vendor once even if it sells multiple list items.
    -- Buy All: at a stocked vendor, one summary confirm replaces Blizzard's
    -- per-item non-refundable nag; while a buy runs the same button cancels.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.buyAllBtn", function()
        if HDG.BuyQueue:IsRunning() then HDG.BuyQueue:Cancel("cancelled") return end
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local rows  = HDG.Selectors:Call("merchant.purchasableFromList", state, {})
        local s     = HDG.Selectors:Call("merchant.buyAllSummary", state, {})
        -- Currency/token-priced list items here can't bulk-buy yet -- say so rather
        -- than silently buying only the gold ones (or nothing at an all-currency vendor).
        if s.skippedCount > 0 then
            HDG.Log:Info("merchant_buy", ("%d item%s here sold for a currency -- skipped (gold only for now)")
                :format(s.skippedCount, s.skippedCount == 1 and "" or "s"))
        end
        if #rows == 0 then return end
        _G.StaticPopup_Show("HDGR_BUY_ALL_CONFIRM", tostring(s.totalQty),
            HDG.Format.FormatGold(s.totalCost), rows)
    end)

    HDG.UI.OnClick(rootFrame, "shoppingPanel.waypointAllBtn", function()
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local rows = HDG.Selectors:Call("shopping.entriesByZone", state, {})
        -- RunBatch emits ONE consolidated chat line for the whole batch (via the
        -- central Waypoints:PrintResult), not one per vendor.
        HDG.Waypoints:RunBatch(function()
            for _, r in ipairs(rows) do
                if r.kind == "vendor" then
                    local aug = HDG.StaticData.VendorAugment:Get(r.npcID)
                    if aug and aug.mapID and aug.mapID > 0 then
                        HDG.Waypoints:Set(aug.mapID, aug.x, aug.y, aug.name)
                    end
                end
            end
        end)
    end)

    -- Attribution Open -- pop the shared slimline URL copy field under the
    -- button so the user can ctrl+C + paste into a browser (no native
    -- URL-opener in WoW). attr.url is the imported list's source URL;
    -- attr.source is just the site tag ("wowdb"), shown in the banner text.
    HDG.UI.OnClick(rootFrame, "shoppingPanel.attributionOpenBtn", function(btn)
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local attr = HDG.Selectors:Call("shopping.attribution", state, {})
        HDG.UI:UrlCopyPopup():ShowAt(btn, attr.url)
    end)

    -- StaticPopups -- register once per session.
    self:_RegisterPopups()
end

function ShoppingController:_RegisterPopups()
    local A = HDG.Constants.ACTIONS

    HDG.UI:RegisterInputDialog("HDGR_SHOPPING_NEW_LIST", {
        text = "Name for new shopping list:",
        maxLetters = 60,
        onAccept = function(value)
            if value == "" then return end
            HDG.Store:Dispatch({ type = A.SHOPPING_LIST_CREATE, payload = { name = value } })
            HDG.Log:Success("shopping", "Created shopping list '" .. value .. "'")
        end,
    })

    -- (Import moved off StaticPopup to HDG.UI:InputDialog -- see Wire's import
    --  button handler + the module-local _importShoppingList.)

    HDG.UI:RegisterInputDialog("HDGR_SHOPPING_SET_QTY", {
        text = "Quantity:",
        maxLetters = 4,
        -- Opens on "1", selected, so Enter is the common case and typing a
        -- different number replaces it. An empty box made the dialog a
        -- two-keystroke minimum and gave no hint what it wanted.
        initialText = "1",
        onAccept = function(value, data)
            local n = tonumber(value) or 1  -- exception(boundary): user input
            HDG.Store:Dispatch({
                type    = A.SHOPPING_ITEM_SET_QTY,
                payload = { listID = data.listID, itemID = data.itemID,
                            npcID = data.npcID, qty = n },
            })
        end,
    })

    -- Buy All summary confirm. text args: 1 = totalQty, 2 = gold string; data =
    -- the purchasable rows (passed to the paced BuyQueue on accept).
    _G.StaticPopupDialogs["HDGR_BUY_ALL_CONFIRM"] = {   -- exception(boundary): StaticPopupDialogs is a Blizzard global
        text         = "Buy %s item(s) for %s?",
        button1      = _G.ACCEPT,
        button2      = _G.CANCEL,
        timeout      = 0, whileDead = false, hideOnEscape = true,
        OnAccept     = function(self, data)
            local ok, why = HDG.BuyQueue:Enqueue(data)
            if not ok then HDG.Log:Warn("merchant_buy", why) end
        end,
    }
end

function ShoppingController:Refresh(rootFrame, ctx)
    -- Bindings handle every paint surface; nothing imperative.
end

HDG.Controllers:Register("shopping", ShoppingController)
