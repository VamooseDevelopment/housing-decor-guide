-- HDG.UI (controller-side helpers)
-- Widget access (W/OnClick/WireSearchBox), workflow dialogs (Confirm/ShowMenu),
-- the unified row factory builder (MakeRowFactory), row chrome/badge,
-- chip rendering (GateChips), click wiring, row helpers.
-- Components.lua (loaded first) owns: widget factory methods + _TintTexture + applyFontRole.

HDG = HDG or {}
HDG.UI = HDG.UI or {}

local UI = HDG.UI

-- StaticPopupDialogs / StaticPopup_Show / MenuUtil read from _G inline (test fixtures swap mocks after load).

-- ===== Widget access =====================================================

-- Strict: a controller is wired only onto frames that host its views
-- (Controllers:WireAll), so a missing widget is a typo or a wrong `controllers`
-- list, and it errors instead of leaving a button unwired.
function UI.W(rootFrame, id)
    local w = rootFrame.widgets[id]
    if w == nil then
        error(("widget %q is not on this frame (a typo, or a view's `controllers` list is wrong)")
            :format(tostring(id)), 2)
    end
    return w
end

-- Wire LMB+RMB on a row Button. Either handler may be nil.
-- Both handlers receive the row Button as `self`.
-- One shared OnClick for every wired row, reading the handlers off the frame: rows
-- are rewired on every paint (refills, scrolling), and a closure per paint was
-- garbage each time (memory plan 2026-10-19 sec 6).
local function _onLeftRightClick(self, button)
    if button == "RightButton" then
        if self._rmbHandler then self._rmbHandler(self) end
    elseif self._lmbHandler then
        self._lmbHandler(self)
    end
end

function UI.WireLeftRightClick(row, lmbHandler, rmbHandler)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row._lmbHandler, row._rmbHandler = lmbHandler, rmbHandler
    row:SetScript("OnClick", _onLeftRightClick)
end

function UI.OnClick(rootFrame, widgetId, fn)
    UI.W(rootFrame, widgetId):SetScript("OnClick", fn)
end

-- ===== Vendor navigation ===================================================
-- Waypoint and Show on Map for a vendor { mapID, x, y, name, side }, for the row
-- buttons and detail panels of every tab that offers them. `side` is the vendor's
-- A/H/N allegiance from VendorAugment: Waypoints warns when it is the other
-- faction's.
function UI.WaypointToVendor(v) HDG.Waypoints:Set(v.mapID, v.x, v.y, v.name, v.side) end
function UI.ShowVendorOnMap(v) HDG.Waypoints:ShowOnMap(v.mapID, v.x, v.y, v.name) end

-- A detail panel's Waypoint and Show on Map buttons, for the vendor vendorOf()
-- names at click time. Both are enabled only for a vendor with a location, so it
-- is never nil when one is clicked.
function UI.WireVendorNav(rootFrame, waypointId, mapId, vendorOf)
    UI.OnClick(rootFrame, waypointId, function() UI.WaypointToVendor(vendorOf()) end)
    UI.OnClick(rootFrame, mapId, function() UI.ShowVendorOnMap(vendorOf()) end)
end

-- ===== Hyperlinks in a label ===============================================
-- A label's |H links live on its parent frame: mouse and hyperlinks on there,
-- the click and enter handlers set, and the tooltip hidden on leave.
local function _hideTooltip() HDG.TooltipEngine:Hide() end

function UI.WireHyperlinkHost(rootFrame, labelId, onClick, onEnter)
    local host = UI.W(rootFrame, labelId):GetParent()
    host:EnableMouse(true)
    host:SetHyperlinksEnabled(true)
    host:SetScript("OnHyperlinkClick", onClick)
    host:SetScript("OnHyperlinkEnter", onEnter)
    host:SetScript("OnHyperlinkLeave", _hideTooltip)
end

-- Add a recipe to the craft queue + toast the amount added on the status rail.
-- The single funnel for every "add to queue" site: the Recipes +stepper / Queue
-- Add button and the Goblin / Decor shift-click handlers all route here. `opts`
-- merges extra payload fields (source / sessionKey; opts.qty overrides the
-- default 1). The `queue` log tag is user-visible, so the toast surfaces on the
-- status rail for ~3s regardless of which view dispatched it.
function UI.QueueRecipe(recipeID, itemID, displayName, opts)
    local payload = { recipeID = recipeID, itemID = itemID, qty = 1 }
    local silent
    if opts then
        silent = opts.silent
        for k, v in pairs(opts) do if k ~= "silent" then payload[k] = v end end
    end
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.CRAFT_QUEUE_ADD, payload = payload })
    -- Each add is atomic (+qty); the toast reports THIS add, not the running queue total.
    -- Batch callers pass opts.silent and emit their own one-line summary instead.
    if not silent then
        HDG.Log:Info("queue", "Added " .. (displayName or "recipe") .. " x" .. payload.qty)
    end
end

-- Standard search editbox wiring: userInput guard prevents dispatch on programmatic SetText.
-- The userInput-guarded OnTextChanged shell every search box shares
-- (hygiene A1). fn receives the current text; programmatic SetText never fires.
function UI.WireTextChanged(widget, fn)
    if not (widget and widget.SetScript) then return end  -- exception(boundary): widget may be absent in this window
    widget:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        fn((self.GetText and self:GetText()) or "")
    end)
    -- A `search = true` box's clear "x" calls SetText(""), which fires OnTextChanged without
    -- userInput -- the guard above skips it, so the state would keep the old needle while the
    -- box reads empty. The x reports itself through the same fn instead, so every search box
    -- wired here clears through its own action.
    widget._hdgrOnClear = function() fn("") end
end

function UI.WireSearchBox(rootFrame, widgetId, tabName, stateKey)
    local box = UI.W(rootFrame, widgetId)
    UI.WireTextChanged(box, function(text)
        HDG.ControllerHelpers.Mechanics.SetUITransientView(tabName, stateKey, text)
    end)
    -- Return the EditBox so callers can imperatively clear it (e.g. the Reset button):
    -- UI_FILTER_RESET zeroes the search state, but nothing pushes that back to the widget.
    return box
end

-- ===== Workflow dialogs ==================================================
-- StaticPopup confirm: id, text, accept, cancel, onAccept, input (bool), maxLetters, data.

-- Resolve a StaticPopup dialog's edit box. Retail 12.0 renamed the frame field
-- (self.editBox -> self.EditBox) and Blizzard's own StaticPopup.lua reaches it
-- through the dialog method instead. One resolver so OnShow and OnAccept can
-- never end up reading different boxes.
local function _popupEditBox(dlg)
    return dlg.EditBox or dlg.editBox or (dlg.GetEditBox and dlg:GetEditBox())  -- exception(boundary): Blizzard renamed the dialog's edit-box field in 12.0
end

function UI.Confirm(opts)
    if type(opts) ~= "table" then return end
    local popupDialogs = _G.StaticPopupDialogs
    local popupShow    = _G.StaticPopup_Show
    if not (popupDialogs and popupShow) then return end
    local id = opts.id or "HDGR_CONFIRM"
    popupDialogs[id] = popupDialogs[id] or {
        text       = opts.text   or "Confirm?",
        button1    = opts.accept or "OK",
        button2    = opts.cancel or "Cancel",
        hasEditBox = opts.input == true,
        maxLetters = opts.maxLetters or 64,  -- exception(boundary): opts API default
        OnAccept   = function(self, data)
            if opts.input then
                local box = _popupEditBox(self)
                local val = box and box.GetText and box:GetText() or ""
                if opts.onAccept then opts.onAccept(val, data) end
            else
                if opts.onAccept then opts.onAccept(nil, data) end
            end
        end,
        EditBoxOnEnterPressed = opts.input and function(self)
            -- Enter must do exactly what the accept button does, data included:
            -- the dialog frame carries the per-show data StaticPopup_Show stored.
            local dlg = self:GetParent()
            local val = self:GetText() or ""
            if opts.onAccept then opts.onAccept(val, dlg.data) end
            dlg:Hide()
        end or nil,
        EditBoxOnEscapePressed = opts.input and function(self)
            self:GetParent():Hide()
        end or nil,
        OnShow = opts.input and function(self, data)
            local box = _popupEditBox(self)
            -- HighlightText() selects the whole prefill: SetText leaves the caret
            -- at the end, so without it typing a new name APPENDS to the old one.
            if box and data and data.prefill then box:SetText(data.prefill); box:HighlightText() end  -- exception(optional): prefill is an optional field of the caller's data table
        end or nil,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    popupShow(id, opts.textArg1, opts.textArg2, opts.data)
end

-- Modern MenuUtil-based context menu. Auto-scroll cap at 20 items (480px default).
-- items: { text, callback } | { isTitle } | { isDivider } | { kind="radio", text, value, selected, callback }
--        | { kind="checkbox", text, isSelected=fn, callback=fn }
-- opts: maxHeight (explicit cap), noAutoScroll.
local SCROLL_AUTO_THRESHOLD  = 20
local SCROLL_AUTO_MAX_HEIGHT = 480
function UI.ShowMenu(owner, items, opts)
    local menuUtil = _G.MenuUtil
    if not (menuUtil and menuUtil.CreateContextMenu) then return end
    opts = opts or {}
    menuUtil.CreateContextMenu(owner, function(_, root)
        for _, item in ipairs(items or {}) do
            if item.isDivider then
                root:CreateDivider()
            elseif item.isTitle then
                root:CreateTitle(item.text or "")
            elseif item.kind == "checkbox" then
                -- Stays open across toggles; isSelected is polled live (MenuUtil re-asks).
                root:CreateCheckbox(item.text or "", item.isSelected, item.callback)
            elseif item.kind == "radio" and root.CreateRadio then
                root:CreateRadio(item.text or "",
                    function() return item.selected == true end,
                    item.callback or function() end,
                    item.value)
            else
                local btn = root:CreateButton(item.text or "", item.callback or function() end)
                if item.disabled and btn and btn.SetEnabled then btn:SetEnabled(false) end
            end
        end
        if root.SetScrollMode then  -- exception(boundary): SetScrollMode only on WowScrollBox frames; root varies by caller
            local maxH = opts.maxHeight
            if not maxH and not opts.noAutoScroll
                and items and #items > SCROLL_AUTO_THRESHOLD then
                maxH = SCROLL_AUTO_MAX_HEIGHT
            end
            if maxH then root:SetScrollMode(maxH) end
        end
    end)
end

-- ===== Item links ========================================================

-- Shift-click an item row: hand the link to Blizzard's own link chain.
--
-- ChatFrameUtil.InsertLink walks its listeners in order -- a focused macro
-- editor, the professions search, a Communities chat box, the active chat
-- window -- and ends at AuctionHouseFrame:SetSearchText when the AH is open on
-- a Buy tab. That last hop is how a material row searches the auction house.
-- HDG never touches the search box itself, so the gesture keeps working when
-- Blizzard moves it (HDG classic poked SearchBar.SearchBox directly).
--
-- Returns false when the item has no link yet OR nothing was listening, so a
-- caller whose whole point is the auction house can say so instead of looking
-- broken. The AH is not a Vamoose surface: a no-op there is indistinguishable
-- from a dead button.
function UI.LinkItem(itemID)
    local _, link = C_Item.GetItemInfo(itemID)  -- exception(boundary): itemLink nil on cold item cache
    if not link then return false end
    return _G.ChatFrameUtil.InsertLink(link) and true or false
end

-- The material-list flavour: same link, plus the notice when it goes nowhere.
-- Both materials lists (Warehouse and Recipes) use this so the gesture reads
-- the same in either place. Named for the surface, not the mechanism -- decor
-- and acquisition rows link too, but silently, because linking a piece of
-- decor to chat is the point there and the auction house rarely is.
function UI.LinkMaterial(itemID, name)
    if UI.LinkItem(itemID) then return true end
    HDG.Log:Notify("warn", HDG.Locale:Get("MAT_LINK_NO_TARGET"):format(name or "this material"))
    return false
end

-- ===== Row factory builders ==============================================

-- Create + theme a row FontString in one call (create-role-register triple).
-- Anchoring/width/wrap stay at call site; justify is optional 4th arg.
function UI.RowText(row, fontRole, themeRole, justify)
    local fs = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(fs, fontRole)
    HDG.Theme:Register(fs, themeRole)
    if justify then fs:SetJustifyH(justify) end
    return fs
end

-- Blank N row FontStrings by field key. Nil-guarded (pooled row may be Reset before layout).
function UI.ClearRowText(row, ...)
    for i = 1, select("#", ...) do
        local fs = row[select(i, ...)]
        if fs then fs:SetText("") end
    end
end

-- SetAtlas silently no-ops on an invalid name. GetAtlasInfo returns nil; warn once.
-- Memoized per name (at most one C_Texture call per unique atlas, always-on).
local _atlasChecked = {}
function UI.WarnIfBadAtlas(name)
    if not (name and name ~= "") or _atlasChecked[name] then return end
    _atlasChecked[name] = true
    local CT = _G.C_Texture
    if CT and CT.GetAtlasInfo and CT.GetAtlasInfo(name) == nil and HDG.Log then  -- exception(boundary): CT = _G.C_Texture, Blizzard global; may be absent in headless tests
        HDG.Log:Warn("layout", "invalid atlas (SetAtlas is a silent no-op): " .. tostring(name))
    end
end

-- Atlas-or-texture icon with a clean switch: SetAtlas stamps texcoords that crop a later SetTexture
-- on the same pooled texture; always clear the atlas before switching to a file path.
function UI.PaintIcon(tex, atlas, texture, fallback)
    if atlas and atlas ~= "" then
        UI.WarnIfBadAtlas(atlas)
        tex:SetAtlas(atlas)           -- SetAtlas resets texcoords + replaces any prior file
    elseif texture and texture ~= "" then
        tex:SetAtlas("")              -- drop a prior atlas so its texcoords don't crop the file
        tex:SetTexture(texture)
    elseif fallback then
        tex:SetAtlas("")
        tex:SetTexture(fallback)
    end
end

-- ===== MakeRowFactory: the unified row-lifecycle builder ====================
-- Every simple list row is the same skeleton: idempotent first-paint laydown ->
-- RowChrome (zebra/hover/selected) -> per-paint writes -> optional click wire,
-- with a Reset that clears scripts + text. This builder OWNS that lifecycle, so
-- a factory declares only what is UNIQUE to it: its column layout + paint, plus
-- a few per-row bits. Heterogeneous kind-dispatch rows (header-OR-card,
-- multi-shape) stay BESPOKE -- they are not "the same skeleton".
--
-- opts:
--   layout       fn(row)               first-paint laydown (REQUIRED)
--   paint        fn(row, ed, template)  per-paint writes    (REQUIRED)
--   laidOutTag   string                 first-paint flag (default "_rowLaidOut")
--   selectable   bool                   true -> selection driven by ed.selected
--   selectedFn   fn(ed) -> bool         custom selection predicate (e.g. ed.isActive) for
--                                        envelopes whose selection field isn't `selected`.
--                                        Use INSTEAD of selectable; omit both -> never selected.
--   clicks       string                 RegisterForClicks arg (e.g. "LeftButtonUp")
--   wire         fn(row, ed)            per-paint click/script wiring
--   resetText    {string,...}           FontString keys to blank on Reset
--   reset        fn(row)                extra Reset cleanup (e.g. row._id = nil)
function UI.MakeRowFactory(opts)
    if type(opts) ~= "table" then error("MakeRowFactory: opts table required", 2) end
    if type(opts.layout) ~= "function" then error("MakeRowFactory: opts.layout required", 2) end
    if type(opts.paint)  ~= "function" then error("MakeRowFactory: opts.paint required", 2) end
    local tag = opts.laidOutTag or "_rowLaidOut"

    return function(template)
        return {
            Configure = function(row, ed)
                HDG.UI:RowFirstPaint(row, tag, opts.layout)
                local selected = false
                if opts.selectedFn then selected = opts.selectedFn(ed) and true or false
                elseif opts.selectable then selected = ed.selected and true or false end
                HDG.UI.PaintRowChrome(row, selected)
                if opts.clicks then row:RegisterForClicks(opts.clicks) end
                opts.paint(row, ed, template)
                row:SetHeight(template.height)
                if opts.wire then opts.wire(row, ed) end
            end,
            Reset = function(row)
                if row.SetScript then row:SetScript("OnClick", nil) end  -- exception(false-positive): Frame/Button rows always have SetScript; mock-fidelity guard
                if opts.resetText then HDG.UI.ClearRowText(row, unpack(opts.resetText)) end
                if opts.reset then opts.reset(row) end
            end,
        }
    end
end

-- Craftable-state star paint via atlas swap. White vertex reset for pooled rows.
-- defaultState: UnknownOnAccount (Recipes) or NotARecipe (Decor).
function UI:PaintCraftStar(star, state, defaultState)
    local cs    = state or defaultState
    local atlas = HDG.Constants.RECIPE_STATE_STAR_ATLAS[cs]
    if not atlas then star:Hide(); return end
    star:SetAtlas(atlas)
    star:SetVertexColor(1, 1, 1, 1)
    star:Show()
end

-- ===== Row chrome + badge paint facades ==================================
-- Construction in Components; paint in Theme.Skinners. Wrappers stash state + register.

function UI.PaintRowChrome(row, selected)
    if not row then return end
    HDG.UI:EnsureRowChrome(row)
    HDG.Theme:Register(row, "RowChrome", { selected = selected and true or false })
end

-- ===== Source-type chip strip =============================================
-- Delegates to HDG.Format.SourceChip (Palette-backed SSoT). `dimmed` fades not-met gate chips.
-- questDone/achEarned/repMet = false fades the matching chip; nil = full brightness.
function UI.GateChips(itemID, questDone, achEarned, repMet)
    if not itemID then return "" end
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    if not row or not row.sourceTags then return "" end
    local out = {}
    for _, tag in ipairs(row.sourceTags) do
        local dimmed = (tag.kind == "QUEST" and questDone == false)
                    or (tag.kind == "ACH"   and achEarned == false)
                    or (tag.kind == "REP"   and repMet    == false)
        out[#out+1] = HDG.Format.SourceChip(tag.kind, dimmed)
    end
    return table.concat(out, " ")
end

-- Housing lumber is Bind-on-Pickup -- it's farmed via mounted harvest, never sold
-- on the Auction House -- so it must never land in an Auctionator buy-list. Set
-- built once from Constants.LUMBER_DATA (the 12 lumber types).
local _lumberIDSet
local function _isLumber(itemID)
    if not _lumberIDSet then
        _lumberIDSet = {}
        for _, l in ipairs(HDG.Constants.LUMBER_DATA) do _lumberIDSet[l.id] = true end
    end
    return _lumberIDSet[itemID] == true
end

-- Resolve a reagent's name for an Auctionator search term. Auctionator searches by
-- NAME, so an unresolved "item <id>" placeholder finds nothing. Live cache first
-- (authoritative, exact AH name), then the curated ReagentsDB name (always present
-- for housing reagents -- it's what the Materials panel shows), then the placeholder.
local function _reagentSearchName(itemID)
    local name = HDG.ItemNameResolver:ResolveName(itemID)
    if (not name or name == "") and C_Item and C_Item.GetItemInfo then  -- exception(boundary): uncached item
        name = (C_Item.GetItemInfo(itemID))
    end
    if not name or name == "" then
        local _, reagentName = HDG.StaticData.Reagents:Get(itemID)   -- exception(nullable): not every item is a known reagent
        name = reagentName
    end
    if not name or name == "" then name = "item:" .. tostring(itemID) end
    return name
end

-- Send a reagent buy-list to Auctionator as a shopping list. Each reagent is
-- { id = itemID, qty = stillNeeded } (qty = the gap between what's needed and held).
-- BoP lumber is dropped (can't be AH-bought). When Auctionator exposes
-- ConvertToSearchString we emit an exact-name search that carries that quantity, so
-- the list reflects the buy gap (not a fuzzy name search) -- parity with HDG v2.45.
-- Bare-name fallback (older Auctionator). Returns (count, present).
function UI.SendReagentsToAuctionator(listName, reagents)
    local API = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1  -- exception(boundary): optional addon
    if not (API and API.CreateShoppingList) then return 0, false end
    local callerID = HDG.Constants.ADDON_NAME
    local hasQty   = API.ConvertToSearchString ~= nil
    local terms = {}
    for _, mat in ipairs(reagents) do
        if not _isLumber(mat.id) then   -- BoP: farmed, never on the AH
            local name = _reagentSearchName(mat.id)
            if hasQty then
                terms[#terms + 1] = API.ConvertToSearchString(callerID, {
                    searchString = name,
                    isExact      = true,
                    quantity     = (mat.qty and mat.qty > 0) and mat.qty or nil,
                })
            else
                terms[#terms + 1] = name
            end
        end
    end
    if #terms > 0 then
        API.CreateShoppingList(callerID, listName, terms)
    end
    return #terms, true
end

-- ===== Composer primitives =====================================================

-- "+ " / "- " collapse-glyph prefix for a collapsible group-header label.
function UI.CollapsePrefix(collapsed)
    return collapsed and "+ " or "- "
end

-- { accent, dim, success } ColorCode set. Fresh table per call.
function UI.SemanticCC()
    return {
        accent  = HDG.Theme:ColorCode("semantic.accent"),
        dim     = HDG.Theme:ColorCode("text.dim"),
        success = HDG.Theme:ColorCode("semantic.success"),
    }
end

-- Square icon texture with standard 0.08-0.92 crop. Caller sets :SetTexture and :SetPoint.
function UI.MakeCellIcon(parent, size)
    local s = size or 18
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(s, s)
    icon:SetTexCoord(unpack(HDG.Constants.ICON_CROP))
    return icon
end

-- Right-anchored [- nn +] stepper. Stamps _minusBtn/_qtyFs/_plusBtn; caller wires clicks.
-- opts: rightInset(-4), size(16), qtyWidth(22), qtyFont("caption"), plusAtlas, minusAtlas.
function UI.WireStepperCluster(row, opts)
    opts = opts or {}
    local size = opts.size or 16  -- exception(optional): option default
    local plus = HDG.UI:AtlasButton(row, opts.plusAtlas or "communities-chat-icon-plus", size)
    plus:SetPoint("RIGHT", row, "RIGHT", opts.rightInset or -4, 0)
    local qty = UI.RowText(row, opts.qtyFont or "caption", "Text", "CENTER")
    qty:SetPoint("RIGHT", plus, "LEFT", -3, 0)
    qty:SetWidth(opts.qtyWidth or 22)  -- exception(optional): option default
    qty:SetWordWrap(false)
    local minus = HDG.UI:AtlasButton(row, opts.minusAtlas or "communities-chat-icon-minus", size)
    minus:SetPoint("RIGHT", qty, "LEFT", -3, 0)
    row._plusBtn, row._qtyFs, row._minusBtn = plus, qty, minus
    return plus, qty, minus
end

-- Two-column name LEFT / meta dim RIGHT. Stamps _nameFs/_metaFs.
-- opts: nameRole("body"), metaRole("caption"), leftInset(10), rightInset(-8), gap(6).
function UI.LayoutNameMetaRow(row, opts)
    opts = opts or {}
    local meta = UI.RowText(row, opts.metaRole or "caption", opts.metaTheme or "TextDim", "RIGHT")
    meta:SetPoint("RIGHT", row, "RIGHT", opts.rightInset or -8, 0)
    meta:SetWordWrap(false)
    local name = UI.RowText(row, opts.nameRole or "body", opts.nameTheme or "Text", "LEFT")
    name:SetPoint("LEFT", row, "LEFT", opts.leftInset or 10, 0)  -- exception(optional): option default
    name:SetPoint("RIGHT", meta, "LEFT", -(opts.gap or 6), 0)  -- exception(optional): option default
    name:SetWordWrap(false)
    row._nameFs, row._metaFs = name, meta
    return name, meta
end

-- Resolved item name with "item N" fallback (uncached items).
function UI.ItemName(itemID)
    local n = HDG.ItemNameResolver:ResolveName(itemID)
    return (n and n ~= "") and n or ("item " .. tostring(itemID))
end

-- Full-cover theme border overlay for top-level windows (hygiene A24 --
-- MainFrame + Window shared this verbatim). Mouse-transparent; the
-- WindowFrameBorder skinner shows/hides it per scheme.
function UI.AttachWindowFrameBorder(frame)
    local border = CreateFrame("Frame", nil, frame)
    border:SetAllPoints(frame)
    border:SetFrameLevel(frame:GetFrameLevel() + 50)
    border:EnableMouse(false)
    frame._hdgrBorder = border
    HDG.Theme:Register(border, "WindowFrameBorder")
    return border
end

-- ===== Window decorations: a seasonal theme's art over the title bar ========
-- Main window only. The WindowDecorations skinner shows the overlay while the
-- scheme names a decorations set (Winter Veil) and the Theme decorations setting
-- is on; everything here builds and lays the art out. The textures are the
-- mockup's own drawing (docs/mockups/winter_veil_lab/export_art.js, 2 texels a
-- unit), and these numbers are where that script put the window's edges inside
-- each one. Game units from the window's top-left corner; +y is up.
local WV_ART = "Interface\\AddOns\\HousingDecorGuide\\textures\\winterveil\\"
local DECO = {
    frameLift = 60,  -- above the title bar's widgets and the window border overlay (+50)
    layer     = "OVERLAY",
    sublevel  = { swag = 1, bauble = 2, snow = 3, holly = 4 },   -- draw order, bottom to top
    snowRise  = 8,   -- every snow texture's top sits this far above the window's top edge
    snowH     = 32,
    capW      = 32,
    capIn     = 28,  -- a cap covers 28 inside the window and the rest past its edge
    tileW     = 256, -- the snow tile's period: its waves repeat every 256
    hollyW    = 64, hollyH = 32,
    hollyX    = 30,  -- each sprig's centre: 30 in from its corner,
    hollyY    = 3,   -- 3 above the top edge
    swagW     = 64, swagH = 8,    -- the swag's dip spans hookGap; the rest of the texture is clear
    baubleW   = 16, baubleH = 32,
    hookY     = 7,   -- the garland's hooks hang 7 below the top edge,
    hookInArt = 1,   -- 1 down the bauble and swag textures
    hookGap   = 48,
    clear     = 16,  -- a bauble's edge keeps this clear of the title bar's empty middle
    -- The ".png" is required: a path with no extension finds only .blp and .tga,
    -- and draws nothing (round7.png and disc10.png are named the same way).
    tex = {
        snowTile = WV_ART .. "snow_tile.png",
        capLeft  = WV_ART .. "snow_cap_left.png",
        capRight = WV_ART .. "snow_cap_right.png",
        holly    = WV_ART .. "holly.png",
        swag     = WV_ART .. "swag.png",
        baubles  = { WV_ART .. "bauble_red.png", WV_ART .. "bauble_gold.png", WV_ART .. "bauble_blue.png" },
    },
}
-- The setting the overlay follows (CONFIG_SET invalidates account.config.<key>).
local DECO_WATCH = { "account.config.themeDecorations" }

local function _decoTexture(host, sublevel, file)
    local tex = host:CreateTexture(nil, DECO.layer, nil, sublevel)
    tex:SetTexture(file)
    return tex
end

local function _cornerPiece(overlay, sublevel, file, w, h, relPoint, x, y)
    local tex = _decoTexture(overlay, sublevel, file)
    tex:SetSize(w, h)
    tex:SetPoint("TOPLEFT", overlay, relPoint, x, y)
    return tex
end

-- Snow caps and holly sprigs, anchored to the window's top corners so they follow
-- its width with no relayout. Built on the first show, which other schemes never reach.
local function _buildCorners(overlay)
    local s, hollyTop = DECO.sublevel, DECO.hollyY + DECO.hollyH / 2
    _cornerPiece(overlay, s.snow, DECO.tex.capLeft, DECO.capW, DECO.snowH,
        "TOPLEFT", DECO.capIn - DECO.capW, DECO.snowRise)
    _cornerPiece(overlay, s.snow, DECO.tex.capRight, DECO.capW, DECO.snowH,
        "TOPRIGHT", -DECO.capIn, DECO.snowRise)
    _cornerPiece(overlay, s.holly, DECO.tex.holly, DECO.hollyW, DECO.hollyH,
        "TOPLEFT", DECO.hollyX - DECO.hollyW / 2, hollyTop)
    local right = _cornerPiece(overlay, s.holly, DECO.tex.holly, DECO.hollyW, DECO.hollyH,
        "TOPRIGHT", -(DECO.hollyX + DECO.hollyW / 2), hollyTop)
    -- Mirrored. The generated docs name the args (left, right, bottom, top), but
    -- Blizzard's own flips read (left, right, top, bottom): (1, 0, 0, 1) is horizontal.
    right:SetTexCoord(1, 0, 0, 1)
    overlay._decoBuilt = true
end

-- Pool factories (UI.AcquirePooled): one texture per slot, kept for the session.
local function _newSnowTile(host) return _decoTexture(host, DECO.sublevel.snow, DECO.tex.snowTile) end
local function _newSwag(host) return _decoTexture(host, DECO.sublevel.swag, DECO.tex.swag) end
local function _newBauble(host) return host:CreateTexture(nil, DECO.layer, nil, DECO.sublevel.bauble) end

-- A whole number of tiles between the caps, each stretched a little: the tile's
-- waves are periodic and both caps are drawn phased to a tile boundary, so the
-- joins line up. A frame narrower than its two caps has no run between them:
-- no tiles, rather than one of negative width.
local function _layoutSnow(overlay, width)
    local run = width - 2 * DECO.capIn
    UI.BeginPoolPass(overlay, "_decoTiles")
    if run > 0 then
        local n = math.max(1, math.floor(run / DECO.tileW + 0.5))
        local tileW = run / n
        for i = 0, n - 1 do
            local tile = UI.AcquirePooled(overlay, "_decoTiles", i, _newSnowTile)
            tile:SetSize(tileW, DECO.snowH)
            tile:SetPoint("TOPLEFT", overlay, "TOPLEFT", DECO.capIn + i * tileW, DECO.snowRise)
            tile:Show()
        end
    end
    UI.EndPoolPass(overlay, "_decoTiles")
end

-- Hook i of the garland at x: its bauble, colours cycling red, gold, blue.
local function _placeBauble(overlay, i, x)
    local bauble = UI.AcquirePooled(overlay, "_decoBaubles", i, _newBauble)
    bauble:SetTexture(DECO.tex.baubles[i % #DECO.tex.baubles + 1])
    bauble:SetSize(DECO.baubleW, DECO.baubleH)
    bauble:SetPoint("TOPLEFT", overlay, "TOPLEFT", x - DECO.baubleW / 2, DECO.hookInArt - DECO.hookY)
    bauble:Show()
end

-- The swag from hook i (at x) to hook i + 1.
local function _placeSwag(overlay, i, x)
    local swag = UI.AcquirePooled(overlay, "_decoSwags", i, _newSwag)
    swag:SetSize(DECO.swagW, DECO.swagH)
    swag:SetPoint("TOPLEFT", overlay, "TOPLEFT", x, DECO.hookInArt - DECO.hookY)
    swag:Show()
end

-- Hooks hookGap apart, centred in [x0, x1] (the mockup's garlandHooks): n + 1
-- hooks, n swags. A span under one gap holds one bauble; a negative one, none.
local function _layoutGarland(overlay, x0, x1)
    local n = math.floor((x1 - x0) / DECO.hookGap)
    local first = x0 + ((x1 - x0) - n * DECO.hookGap) / 2
    UI.BeginPoolPass(overlay, "_decoBaubles")
    UI.BeginPoolPass(overlay, "_decoSwags")
    for i = 0, n do
        local x = first + i * DECO.hookGap
        _placeBauble(overlay, i, x)
        if i < n then _placeSwag(overlay, i, x) end
    end
    UI.EndPoolPass(overlay, "_decoBaubles")
    UI.EndPoolPass(overlay, "_decoSwags")
end

-- The garland's span: the lane across the title bar's empty middle, inset so a
-- bauble's edge keeps `clear` off each end. Read, not assumed: the lane's right end
-- moves with the window's width and the version text's (font face, version string).
-- Lane and overlay share the window's scale, so the difference is in window units.
local function _garlandSpan(overlay)
    local lane, origin = overlay._decoLane, overlay:GetLeft()
    local left = lane:GetLeft()
    if not (left and origin) then return nil end  -- exception(boundary): rects are unresolved until the client first lays the window out; the lane's OnSizeChanged lays the garland out then
    local inset = DECO.clear + DECO.baubleW / 2
    return left - origin + inset, lane:GetRight() - origin - inset
end

-- The one layout path: on show (a scheme switch, the setting, the window opening)
-- and on a size change of the window or of the title bar's empty middle (the lane).
local function _layoutDecorations(overlay)
    if not overlay:IsShown() then return end   -- another scheme, or the setting off
    if not overlay._decoBuilt then _buildCorners(overlay) end
    _layoutSnow(overlay, overlay:GetWidth())
    local x0, x1 = _garlandSpan(overlay)
    if x0 then _layoutGarland(overlay, x0, x1) end
end

-- A title-bar widget the lane hangs off. The ids are the chrome strip's own
-- (HDGR_LayoutConfig.lua); a renamed one must fail here, not anchor to the window.
local function _chromeWidget(frame, id)
    return frame.widgets[id] or error("AttachWindowDecorations: the window has no " .. id .. " widget", 3)
end

-- The garland's lane: an undrawn frame across a title strip's empty middle, from
-- `left`'s right edge to `right`'s left. Its size changing is the garland's
-- relayout: the strip's first layout, a resize, a version string of another width.
local function _garlandLane(frame, overlay, left, right)
    local lane = CreateFrame("Frame", nil, frame)
    lane:SetPoint("LEFT", left, "RIGHT")
    lane:SetPoint("RIGHT", right, "LEFT")
    lane:SetHeight(1)
    lane:SetScript("OnSizeChanged", function() _layoutDecorations(overlay) end)
    return lane
end

-- The art's overlay on `frame`, its garland in the lane from `left` to `right`.
-- Mouse-transparent, because the snow and holly reach above the top edge and must
-- not grow the frame's hit area. Born shown: whoever attaches it decides when it hides.
local function _decorate(frame, left, right)
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame:GetFrameLevel() + DECO.frameLift)
    overlay:EnableMouse(false)
    overlay._decoLane = _garlandLane(frame, overlay, left, right)
    overlay:SetScript("OnShow", _layoutDecorations)
    overlay:SetScript("OnSizeChanged", _layoutDecorations)
    frame._hdgrDecorations = overlay
    return overlay
end

-- The main window's title bar. Its empty middle is the chrome.spacer section, which
-- is layout only (it has no frame), so the lane hangs off the logo and the version
-- text either side of it. Built with the window (never in combat: CreateMainWindow
-- waits it out). The skinner runs at Register, and again on every scheme switch
-- (ApplyAll) and every change to the setting (SetState below).
-- The closing layout covers a window already open and laid out when this runs (a
-- build deferred past combat, or one made for a window restored open): the overlay
-- is born shown there, so no OnShow comes, and an unchanged layout fires no
-- OnSizeChanged.
function UI.AttachWindowDecorations(frame)
    local overlay = _decorate(frame, _chromeWidget(frame, "chromePanel.title"),
        _chromeWidget(frame, "chromePanel.version"))
    HDG.Theme:Register(overlay, "WindowDecorations", { enabled = HDG.Store:GetConfig("themeDecorations") })
    HDG.Store:Subscribe(function(_, invalidation)
        if HDG.Paths.MatchesAny(DECO_WATCH, invalidation) then
            HDG.Theme:SetState(overlay, { enabled = HDG.Store:GetConfig("themeDecorations") })
        end
    end)
    _layoutDecorations(overlay)
    return overlay
end

-- A pop-up's title strip (the Winter Veil theme offer): the same art whatever the
-- scheme, since it previews the theme, so no skinner hides it. The garland runs from
-- `title`'s right edge to the right-hand holly sprig; the lane ends `clear` short
-- of the sprig's inner edge because _garlandSpan insets the baubles by that again.
function UI.AttachTitleDecorations(frame, title)
    local stop = CreateFrame("Frame", nil, frame)
    stop:SetSize(1, 1)
    stop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(DECO.hollyX + DECO.hollyW / 2 - DECO.clear), 0)
    local overlay = _decorate(frame, title, stop)
    _layoutDecorations(overlay)
    return overlay
end

-- Waypoint-pin AtlasButton at a row's right edge, hidden until shown by the
-- painter (hygiene A12 -- Zone + Shopping shared this verbatim).
function UI.RowPinButton(row)
    local pin = HDG.UI:AtlasButton(row, "housing-decor-vendor_32", 14)
    pin:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    pin:Hide()
    return pin
end

-- "Map" left of a row's waypoint pin -- a Map beside every Waypoint (owner 10-30): the
-- world map with HDG's pin, where the pin sets a waypoint. Hidden until shown by the painter.
function UI.RowMapButton(row, pin)
    local b = HDG.UI.RowButton(row, HDG.Locale:Get("COMMON_MAP"))
    b:SetPoint("RIGHT", pin, "LEFT", -4, 0)
    b:Hide()
    return b
end

-- ===== Decor Quests text in parts ==========================================
-- The selectors' runs = { { tone, text }, ... } -> one colour-coded string, the tab's and the
-- Quest Tracker's alike (review 2026-10-31 L2): one tone map, so a tone either paints, the
-- other does too, and one it doesn't know errors.
local RUN_TONE = {
    text    = "text.primary",
    dim     = "text.dim",
    accent  = "semantic.accent",
    success = "semantic.success",
    warn    = "semantic.warning",
    error   = "semantic.error",
    sunken  = "surface.sunken",   -- the number on the tracker's disc for the step to head for
    mark    = "semantic.warning", -- a who line's quest "!" and "?": each theme's gold
}

function UI.Toned(tone, text)
    local token = RUN_TONE[tone] or error(("UI.Toned: no tone %q"):format(tostring(tone)), 2)
    return HDG.Theme:ColorCode(token) .. text .. "|r"
end

function UI.RunsText(runs)
    local out = {}
    for i, r in ipairs(runs) do out[i] = UI.Toned(r[1], r[2]) end
    return table.concat(out)
end

-- ===== Keyed mark/sweep frame pools (hygiene A8) =============================
-- BeginPoolPass marks everything unused; AcquirePooled revives-or-creates by
-- key; EndPoolPass hides whatever the render didn't touch. Shared by the
-- Layouts thumbnails and the Projects canvas (byte-identical copies before).
function UI.BeginPoolPass(host, pool)
    local p = host[pool]
    if p then for _, f in pairs(p) do f._used = false end end
end
function UI.EndPoolPass(host, pool)
    local p = host[pool]
    if p then for _, f in pairs(p) do if not f._used then f:Hide() end end end
end
function UI.AcquirePooled(host, pool, key, factory)
    host[pool] = host[pool] or {}
    local f = host[pool][key]
    if not f then f = factory(host); host[pool][key] = f end
    f._used = true
    return f
end
