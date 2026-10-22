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

-- Waypoint-pin AtlasButton at a row's right edge, hidden until shown by the
-- painter (hygiene A12 -- Zone + Shopping shared this verbatim).
function UI.RowPinButton(row)
    local pin = HDG.UI:AtlasButton(row, "housing-decor-vendor_32", 14)
    pin:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    pin:Hide()
    return pin
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
