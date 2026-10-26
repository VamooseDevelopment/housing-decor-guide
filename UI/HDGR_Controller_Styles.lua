-- HDG.Controllers Styles
-- ============================================================================
-- Row factories + controller wiring for the Styles tab surfaces (Landing,
-- Detail, Curator, SmartSet, Import).

HDG = HDG or {}
HDG.Controllers = HDG.Controllers or {}

-- ===== Row factory: stylesLandingRow ========================================
-- Heterogeneous: "header" (collapsible section bar) or "card" (collection
-- card). Dispatches on ed.kind.

-- ===== _layoutLandingRow =====================================================
-- Build all sub-widgets on first paint. Cards carry: 36px icon, name,
-- subtitle/URL area, 6 preview icons, count, progress bar, 3 action buttons.
-- Headers use only _labelFs/_subtitleFs/_countFs.
local _CARD_HEIGHT = 32   -- card row height (bumped from 22 for HDG parity)
local _HDR_HEIGHT  = 28
local _CAT_HEIGHT  = 26   -- category row / loose fold (spec 5.1)

-- Defined in the menus section below (Task 6); forward-declared so the row
-- painters can reference them without reordering the file.
local _openFileIntoMenu, _openAddStylesMenu

-- Rename + trash on a category row: alpha 0 at rest, 1 while the pointer is on
-- the row or on the buttons themselves. Card/header rows keep them hidden anyway.
local function _setCategoryHoverAlpha(row, over)
    local a = over and 1 or 0
    row._catRenameBtn:SetAlpha(a)
    row._catDeleteBtn:SetAlpha(a)
end

-- Cross-kind hygiene on pooled rows: each painter hides the other kinds' widgets,
-- so a row recycled from another kind cannot leave a stray button behind.
local function _hideCardWidgets(row)
    row._iconTex:Hide()
    row._countCardFs:Hide()
    row._pbBg:Hide(); row._pbFill:Hide(); row._pbFrame:Hide()
    row._urlBtn:Hide()
    for i = 1, 6 do row._previewTexs[i]:Hide() end
    for _, ab in pairs(row._actionBtns) do ab:Hide() end
end

local function _hideCategoryWidgets(row)
    row._catAddBtn:Hide()
    row._catRenameBtn:Hide()
    row._catDeleteBtn:Hide()
end

local function _layoutLandingRow(row)
    -- Shared text fields (used by both card and header rows).
    local label = row:CreateFontString(nil, "OVERLAY")
    HDG.Theme:Register(label, "Text")
    label:SetJustifyH("LEFT")
    row._labelFs = label

    local sub = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
    row._subtitleFs = sub

    local count = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    row._countFs = count
    -- Right-anchored count for header and category rows. (Never anchored before
    -- this feature, so section counts were painted into the void.)
    count:SetPoint("RIGHT", row, "RIGHT", -10, 0)

    -- Card-only widgets -------------------------------------------------------
    -- 36x36 collection icon (top-left of card).
    local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)
    icon:SetSize(36, 36)
    -- Anchored per-paint in _paintLandingCard: the indent stop under a category
    -- row shifts it, so the painter is the single writer of its position.
    icon:Hide()
    row._iconTex = icon

    -- 6x 24px preview icons, right-anchored (total 6*24 + 5*2 = 154px).
    -- Leave 82px before the 4 action buttons (4*18 + 3*2 + 4 = 82px).
    row._previewTexs = {}
    for i = 1, 6 do
        local tex = row:CreateTexture(nil, "ARTWORK", nil, 2)
        tex:SetSize(24, 24)
        if i == 1 then
            tex:SetPoint("RIGHT", row, "RIGHT", -236, 0)
        else
            tex:SetPoint("LEFT", row._previewTexs[i - 1], "RIGHT", 2, 0)
        end
        tex:Hide()
        row._previewTexs[i] = tex
    end

    -- Count text: right of name area, left of preview icons.
    local countCard = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    countCard:SetWidth(46)
    countCard:SetPoint("RIGHT", row._previewTexs[1], "LEFT", -8, 4)
    countCard:SetShadowOffset(1, -1)
    countCard:SetShadowColor(0, 0, 0, 0.8)
    countCard:Hide()
    row._countCardFs = countCard

    -- Progress bar (renown-style, aligned under count text).
    local pbBg = row:CreateTexture(nil, "ARTWORK", nil, 2)
    pbBg:SetHeight(8)
    pbBg:SetPoint("BOTTOMLEFT",  countCard, "BOTTOMLEFT",  -2, -8)
    pbBg:SetPoint("BOTTOMRIGHT", countCard, "BOTTOMRIGHT",  2, -8)
    pbBg:SetAtlas("UI-Journeys-renown-progressbar-BG")
    pbBg:Hide()
    row._pbBg = pbBg

    local pbFill = row:CreateTexture(nil, "OVERLAY")
    pbFill:SetHeight(8)
    pbFill:SetPoint("BOTTOMLEFT", pbBg, "BOTTOMLEFT", 0, 0)
    pbFill:SetAtlas("UI-Journeys-renown-progressbar-fill")
    pbFill:Hide()
    row._pbFill = pbFill

    local pbFrame = row:CreateTexture(nil, "OVERLAY", nil, 1)
    pbFrame:SetHeight(8)
    pbFrame:SetAllPoints(pbBg)
    pbFrame:SetAtlas("UI-Journeys-renown-progressbar-frame")
    pbFrame:Hide()
    row._pbFrame = pbFrame

    -- Clickable URL button (covers the subtitle area when a URL is present).
    -- Click pops the shared slimline copy field under the row.
    local urlBtn = CreateFrame("Button", nil, row)
    urlBtn:SetFrameLevel(row:GetFrameLevel() + 3)
    urlBtn:Hide()
    urlBtn:SetScript("OnClick", function(self)
        HDG.UI:UrlCopyPopup():ShowAt(self, self._url)
    end)
    HDG.TooltipEngine:Attach(urlBtn, function(self)
        if not self._url then return nil end
        return { anchor = "ANCHOR_TOP", title = "Click to copy URL" }
    end)
    row._urlBtn = urlBtn

    -- Action buttons: Edit, Export, Delete (atlas-icon, right-edge cluster).
    -- Action buttons: wired below in _wireLandingCard.
    local _actionDefs = {
        { key = "category", atlas = "communities-chat-icon-plus", recipe = "StylesCategoryFile" },
        { key = "edit",     atlas = "common-icon-zoomin",         tip = "Edit"   },
        { key = "export",   atlas = "common-icon-forwardarrow",   tip = "Export" },
        { key = "delete",   atlas = "common-icon-delete",         tip = "Delete" },
    }
    row._actionBtns = {}
    local btnSize, btnGap = 18, 2
    for i, ad in ipairs(_actionDefs) do
        local ab = HDG.UI:AtlasButton(row, ad.atlas, btnSize)
        local xOff = -(4 + (#_actionDefs - i) * (btnSize + btnGap))
        ab:SetPoint("TOPRIGHT", row, "TOPRIGHT", xOff, -(_CARD_HEIGHT - btnSize) / 2)
        ab:SetFrameLevel(row:GetFrameLevel() + 5)
        ab:Hide()
        row._actionBtns[ad.key] = ab
        if ad.recipe then HDG.TooltipEngine:Attach(ab, HDG.TooltipRecipes[ad.recipe]) end
    end

    -- Header-only: "+ New Category" sits left of the count on the My Styles bar.
    local newCatBtn = HDG.UI:Button(row, HDG.Locale:Get("STY_LANDING_NEW_CATEGORY"), "small")
    -- _intrinsicWidth is stamped by HDG.UI:Button; the type checker cannot see
    -- through the factory, hence the disable-line (repo convention, not a default).
    newCatBtn:SetSize(newCatBtn._intrinsicWidth, 20)  ---@diagnostic disable-line: undefined-field
    newCatBtn:SetPoint("RIGHT", count, "LEFT", -10, 0)
    newCatBtn:SetFrameLevel(row:GetFrameLevel() + 5)
    newCatBtn:Hide()
    HDG.TooltipEngine:Attach(newCatBtn, HDG.TooltipRecipes.StylesCategoryNew)
    row._newCatBtn = newCatBtn

    -- Category-only cluster, right edge: [trash] [Rename] [+ Add styles].
    -- Add styles is always visible (it is the row's verb); Rename and trash reveal on hover.
    local addBtn = HDG.UI:Button(row, HDG.Locale:Get("STY_LANDING_ADD_STYLES"), "small")
    addBtn:SetSize(addBtn._intrinsicWidth, 20)  ---@diagnostic disable-line: undefined-field
    addBtn:SetPoint("RIGHT", count, "LEFT", -10, 0)
    addBtn:SetFrameLevel(row:GetFrameLevel() + 5)
    addBtn:Hide()
    HDG.TooltipEngine:Attach(addBtn, HDG.TooltipRecipes.StylesCategoryAdd)
    row._catAddBtn = addBtn

    local renameBtn = HDG.UI:Button(row, HDG.Locale:Get("STY_LANDING_RENAME"), "small")
    renameBtn:SetSize(renameBtn._intrinsicWidth, 20)  ---@diagnostic disable-line: undefined-field
    renameBtn:SetPoint("RIGHT", addBtn, "LEFT", -4, 0)
    renameBtn:SetFrameLevel(row:GetFrameLevel() + 5)
    renameBtn:Hide()
    HDG.TooltipEngine:Attach(renameBtn, HDG.TooltipRecipes.StylesCategoryRename)
    row._catRenameBtn = renameBtn

    local delBtn = HDG.UI:AtlasButton(row, "common-icon-delete", 18)
    delBtn:SetPoint("RIGHT", renameBtn, "LEFT", -4, 0)
    delBtn:SetFrameLevel(row:GetFrameLevel() + 5)
    delBtn:Hide()
    HDG.TooltipEngine:Attach(delBtn, HDG.TooltipRecipes.StylesCategoryDelete)
    row._catDeleteBtn = delBtn

    -- Hover-reveal for Rename/trash: the row and both buttons share one handler so
    -- moving from the row onto a button does not flicker (the row's OnLeave fires
    -- when the pointer enters a child; IsMouseOver stays true).
    local function _hover() _setCategoryHoverAlpha(row, row:IsMouseOver()) end
    row:SetScript("OnEnter", _hover)
    row:SetScript("OnLeave", _hover)
    renameBtn:HookScript("OnEnter", _hover)
    renameBtn:HookScript("OnLeave", _hover)
    delBtn:HookScript("OnEnter", _hover)
    delBtn:HookScript("OnLeave", _hover)
end

-- ===== _paintLandingCard =====================================================
local function _paintLandingCard(row, ed)
    local dimCC    = HDG.Theme:ColorCode("text.dim")
    local accentCC = HDG.Theme:ColorCode("semantic.accent")

    HDG.UI.applyFontRole(row._labelFs, "body")
    row._labelFs:ClearAllPoints()
    -- Name on a single, vertically-centered line; the subtitle now follows it
    -- inline (was a second stacked line). LEFT-only anchor lets the name
    -- auto-size so the subtitle can sit immediately after it.
    local inset = ed.indented and 16 or 0   -- one indent stop under a category row / the fold (spec 5.1)
    row._iconTex:ClearAllPoints()
    row._iconTex:SetPoint("TOPLEFT", row, "TOPLEFT", 6 + inset, -(_CARD_HEIGHT - 36) / 2 - 1)
    if ed.hideIcon then
        row._labelFs:SetPoint("LEFT", row, "LEFT", 10 + inset, 0)   -- no icon (rule-based set): name starts at the left
    else
        row._labelFs:SetPoint("LEFT", row._iconTex, "RIGHT", 8, 0)
    end
    -- Data-color: when style carries its own color, paint it directly (no
    -- Theme:Register so ApplyAll doesn't stomp on scheme switch).
    if ed.color then
        local c = ed.color
        local lift = 0.4
        row._labelFs:SetTextColor(  -- data: style's own color, lifted toward white for legibility on wood
            c.r + (1 - c.r) * lift,
            c.g + (1 - c.g) * lift,
            c.b + (1 - c.b) * lift, 1)
    else
        HDG.Theme:Register(row._labelFs, "Text")
    end
    row._labelFs:SetText(ed.displayName or "?")
    row._labelFs:SetWordWrap(false)

    -- Subtitle/URL: inline after name, clamped left of count so long combos
    -- truncate the subtitle rather than overrunning the preview cluster.
    row._subtitleFs:ClearAllPoints()
    row._subtitleFs:SetPoint("LEFT",  row._labelFs, "RIGHT", 6, 0)
    row._subtitleFs:SetPoint("RIGHT", row._countCardFs, "LEFT", -8, 0)
    local desc = ed.subtitle or ""
    row._subtitleFs:SetText(desc ~= "" and (dimCC .. " - " .. desc .. "|r") or "")
    row._subtitleFs:SetShown(desc ~= "")

    -- URL button overlay (only when URL present + desc present).
    local hasUrl = ed.url and ed.url ~= ""
    if hasUrl and desc ~= "" then
        row._urlBtn._url = ed.url
        row._urlBtn:SetPoint("TOPLEFT",  row._subtitleFs, "TOPLEFT",  0, 0)
        row._urlBtn:SetPoint("BOTTOMRIGHT", row._subtitleFs, "BOTTOMRIGHT", 0, 0)
        row._urlBtn:Show()
    else
        row._urlBtn._url = nil
        row._urlBtn:Hide()
    end

    -- Icon (36px). Must clear atlas before painting a file texture or the
    -- prior texcoords bleed onto the new icon (garbled-icon-on-reuse). See UI.PaintIcon.
    if ed.hideIcon then
        row._iconTex:Hide()
    else
        HDG.UI.PaintIcon(row._iconTex, ed.iconAtlas, ed.icon, HDG.Constants.PLACEHOLDER_ICON)
        row._iconTex:Show()
    end

    -- Preview icons (6x 24px, desaturated+0.5 alpha when not owned).
    local previews = ed.previewIcons or {}
    for i = 1, 6 do
        local tex  = row._previewTexs[i]
        local pick = previews[i]
        if pick then
            HDG.UI.PaintIcon(tex, pick.iconAtlas, pick.iconTexture, HDG.Constants.PLACEHOLDER_ICON)
            tex:SetDesaturated(not pick.isOwned)
            tex:SetAlpha(pick.isOwned and 1 or 0.5)
            tex:Show()
        else
            tex:Hide()
        end
    end

    -- Count text.
    row._countFs:SetText("")   -- header count field unused on cards
    local collected = ed.collected
    local total     = ed.total     or 0
    if ed.isSnapshot then
        row._countCardFs:SetText(total .. " placed")
    elseif ed.type == "shopping" then
        row._countCardFs:SetText(total .. " items")
    else
        row._countCardFs:SetText(collected .. "/" .. total)
    end
    row._countCardFs:Show()

    -- Progress bar: fill width proportional to pct; complete -> success (green),
    -- partial -> accent (cyan), themed via ProgressFillTint.
    local pct = ed.pct
    if pct > 0 and not ed.isSnapshot then
        local fillW = math.max(1, (row._countCardFs:GetWidth() or 46) * pct)
        row._pbFill:SetWidth(fillW)
        HDG.Theme:Register(row._pbFill, "ProgressFillTint", { variant = (pct >= 1) and "success" or "accent" })
        row._pbBg:Show()
        row._pbFill:Show()
        row._pbFrame:Show()
    else
        row._pbBg:Hide()
        row._pbFill:Hide()
        row._pbFrame:Hide()
    end

    -- Action buttons: show only on editable types; per ACTION RULE wiring deferred.
    if row._actionBtns.category then row._actionBtns.category:SetShown(ed.canEdit == true) end
    if row._actionBtns.edit   then row._actionBtns.edit:SetShown(ed.canEdit   == true) end
    if row._actionBtns.export then row._actionBtns.export:SetShown(ed.canExport == true) end
    if row._actionBtns.delete then row._actionBtns.delete:SetShown(ed.canDelete == true) end

    _hideCategoryWidgets(row)
    row._newCatBtn:Hide()

    HDG.Theme:Register(row, "RowWoodBeam", { alpha = 0.5 })  -- scheme-invariant: register first
    HDG.Theme:Register(row, "RowChrome",   { selected = ed.isSelected == true })  -- scheme-dependent: must win
end

-- ===== _paintLandingCategory =================================================
-- Category row (or the loose fold). Flat header band, no wood beam, 22px label
-- indent, text-glyph chevron (the nav fold's idiom). Single writer of every
-- category widget; hides the card cluster and the header button.
local function _paintLandingCategory(row, ed)
    HDG.UI.applyFontRole(row._labelFs, "body")
    HDG.Theme:Register(row._labelFs, "Text")
    row._labelFs:ClearAllPoints()
    row._labelFs:SetPoint("LEFT", row, "LEFT", 22, 0)
    local prefix = ed.expanded and "v " or "> "
    if ed.isLoose then
        row._labelFs:SetText(HDG.Theme:ColorCode("text.dim") .. prefix
            .. HDG.Locale:Get("STY_LANDING_LOOSE") .. "|r")
    else
        row._labelFs:SetText(prefix .. ed.label)
    end
    row._labelFs:SetWordWrap(false)
    HDG.UI.ClearRowText(row, "_subtitleFs")
    row._subtitleFs:Hide()
    if ed.matchCount then
        row._countFs:SetText(string.format(HDG.Locale:Get("STY_LANDING_MATCH_FMT"), ed.matchCount, ed.count))
    elseif ed.count == 1 then
        row._countFs:SetText(HDG.Locale:Get("STY_LANDING_COUNT_ONE"))
    else
        row._countFs:SetText(string.format(HDG.Locale:Get("STY_LANDING_COUNT_FMT"), ed.count))
    end
    _hideCardWidgets(row)
    row._newCatBtn:Hide()
    row._catAddBtn:SetShown(ed.canAdd == true)
    row._catRenameBtn:SetShown(not ed.isLoose)
    row._catDeleteBtn:SetShown(not ed.isLoose)
    -- Live pointer state, not false: a repaint under a stationary pointer (the
    -- row's own toggle dispatch, or any invalidate of the landing list) must keep
    -- the reveal -- OnEnter cannot re-fire from inside the frame.
    _setCategoryHoverAlpha(row, row:IsMouseOver())
    -- Beam at alpha 0, not omitted: the skinner only ever SetAlphas the pooled
    -- texture and never hides it, so a row that was a card a moment ago would keep
    -- its woodsign under the flat band. WoodBeam first, RowChrome last (theme rule).
    HDG.Theme:Register(row, "RowWoodBeam", { alpha = 0 })
    HDG.Theme:Register(row, "RowChrome",   { header = true, selected = ed.expanded == true })
end

-- ===== _paintLandingHeader ===================================================
local function _paintLandingHeader(row, ed, accentCC)
    HDG.UI.applyFontRole(row._labelFs, "subheading")
    row._labelFs:ClearAllPoints()
    row._labelFs:SetPoint("LEFT", row, "LEFT", 10, 0)
    local prefix = ed.expanded and "v " or "> "
    row._labelFs:SetText(accentCC .. prefix .. (ed.label or "?") .. "|r")
    row._subtitleFs:ClearAllPoints()
    row._subtitleFs:SetPoint("LEFT", row._labelFs, "RIGHT", 8, 0)
    row._subtitleFs:SetText(ed.subtitle and (" -- " .. ed.subtitle) or "")
    -- Single-writer of subtitle visibility. A pooled row from a description-less
    -- card arrives with _subtitleFs HIDDEN; this branch re-asserts Show().
    row._subtitleFs:SetShown(ed.subtitle ~= nil and ed.subtitle ~= "")
    local suffix = ed.countSuffix or "style"
    row._countFs:SetText(string.format("%d %s", ed.count or 0,
        (ed.count == 1) and suffix or (suffix .. "s")))
    -- Hide the other kinds' widgets (guaranteed present after RowFirstPaint).
    _hideCardWidgets(row)
    _hideCategoryWidgets(row)
    -- "+ New Category" lives on the My Styles bar only, and only while it is open.
    row._newCatBtn:SetShown(ed.type == "style" and ed.expanded == true)
    HDG.Theme:Register(row, "RowWoodBeam", { alpha = 0.6 })  -- scheme-invariant: register first
    HDG.Theme:Register(row, "RowChrome",   { selected = ed.expanded == true })  -- scheme-dependent: must win
end

-- Delete-confirm copy keyed by id prefix. "style:" returns decor to Unassigned;
-- other types just remove the entry.
local _DELETE_NOUN = {
    style      = "style",
    smartset   = "filtered set",
    vsl        = "shopping list",
    snapshot   = "snapshot",
    concept    = "room concept",
    collection = "collection",
}
-- Returns dialog id + text. The id carries the noun because UI.Confirm memoizes
-- a dialog's text per id: one id for every kind meant the first kind deleted in
-- a session set the wording for all of them ("Delete style ...? Items return to
-- Unassigned." on a shopping list). Found 2026-09-11.
local function _deleteConfirm(id)
    local prefix = type(id) == "string" and id:match("^(%w+):") or nil
    local noun   = _DELETE_NOUN[prefix] or "collection"
    local dialogID = "HDGR_DELETE_STYLE_" .. string.upper(prefix or "collection")
    if prefix == "style" then
        return dialogID, 'Delete ' .. noun .. ' "%s"? Items return to Unassigned.'
    end
    return dialogID, 'Delete ' .. noun .. ' "%s"?'
end

-- The ONE accept handler both delete sites (landing card, curator row) hand to
-- UI.Confirm: they share dialog ids per noun, and the memoized dialog keeps the
-- first caller's closure, so the closure must be the same function from both.
local function _dispatchStyleDelete(_, collectionID)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.STYLES_DELETE_STYLE,
        payload = { collectionID = collectionID },
    })
end

-- ===== _wireLandingCard ======================================================
local function _wireLandingCard(row, ed)
    local kind         = ed.kind
    local sectionType  = ed.type
    local forced       = ed.forcedOpen
    local collectionID = ed.collectionID
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function()
        if kind == "card" then
            if not collectionID then return end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_SELECT_COLLECTION,
                payload = { collectionID = collectionID },
            })
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_SET_VIEW,
                payload = { view = "detail" },
            })
        else
            -- The chip force-opens this section; toggling then would write a flag the
            -- user never sees flip. No-op until the override clears.
            if forced then return end
            if not sectionType then return end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_LANDING_TOGGLE_SECTION,
                payload = { type = sectionType },
            })
        end
    end)

    row._newCatBtn:SetScript("OnClick", function()
        HDG.UI.Confirm({
            id         = "HDGR_NEW_CATEGORY",
            text       = HDG.Locale:Get("STY_LANDING_POPUP_NEW"),
            accept     = HDG.Locale:Get("STY_LANDING_CREATE"),
            cancel     = HDG.Locale:Get("STY_LANDING_CANCEL"),
            input      = true,
            maxLetters = 40,
            onAccept   = function(value)
                local name = HDG.Format.Trim(value)
                if name == "" then return end
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.STYLE_CATEGORY_CREATE,
                    payload = { name = name },
                })
            end,
        })
    end)

    -- Action buttons: shown only on editable rows; header rows have no _actionBtns.
    local btns = row._actionBtns
    if not btns then return end
    local isSnapshot = ed.isSnapshot
    if btns.category then
        local displayName, currentCategoryID = ed.displayName, ed.categoryID
        btns.category:SetScript("OnClick", function(self)
            if not collectionID then return end
            _openFileIntoMenu(self, collectionID, displayName, currentCategoryID)
        end)
    end
    if btns.edit then
        btns.edit:SetScript("OnClick", function()
            if not collectionID then return end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_EDIT_STYLE,
                payload = { collectionID = collectionID },
            })
        end)
    end
    if btns.export then
        btns.export:SetScript("OnClick", function()
            if not collectionID then return end
            local def = HDG.Store:GetState().account.collections[collectionID]  -- exception(false-positive): top-level controller read
            if not def then return end
            local encoded = isSnapshot
                and HDG.StyleSerializer:ExportSnapshot(def)
                or  HDG.StyleSerializer:Export(def)
            if encoded then HDG.UI:CopyDialog():Show("Export Style", encoded) end
        end)
    end
    if btns.delete then
        local displayName = ed.displayName or collectionID
        btns.delete:SetScript("OnClick", function()
            if not collectionID then return end
            local dialogID, text = _deleteConfirm(collectionID)
            HDG.UI.Confirm({
                id       = dialogID,
                text     = text,
                textArg1 = displayName,
                accept   = "Delete",
                cancel   = "Cancel",
                data     = collectionID,
                onAccept = _dispatchStyleDelete,
            })
        end)
    end
end

-- ===== _wireLandingCategory ==================================================
local function _wireLandingCategory(row, ed)
    local key, forced = ed.categoryID, ed.forcedOpen
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function()
        -- Search / chip force-open this row; toggling then would write a flag the
        -- user never sees flip. No-op until the override clears.
        if forced then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_LANDING_TOGGLE_CATEGORY,
            payload = { key = key },
        })
    end)
    -- Clear before the loose-fold return: a row recycled from a category into
    -- the loose fold would otherwise keep the previous category's closures.
    row._catAddBtn:SetScript("OnClick", nil)
    row._catRenameBtn:SetScript("OnClick", nil)
    row._catDeleteBtn:SetScript("OnClick", nil)
    if ed.isLoose then return end
    local name = ed.label
    row._catAddBtn:SetScript("OnClick", function(self)
        _openAddStylesMenu(self, key, name)
    end)
    row._catRenameBtn:SetScript("OnClick", function()
        HDG.UI.Confirm({
            id         = "HDGR_RENAME_CATEGORY",
            text       = HDG.Locale:Get("STY_LANDING_POPUP_RENAME"),
            textArg1   = name,
            accept     = HDG.Locale:Get("STY_LANDING_RENAME"),
            cancel     = HDG.Locale:Get("STY_LANDING_CANCEL"),
            input      = true,
            maxLetters = 40,
            data       = { categoryID = key, prefill = name },
            onAccept   = function(value, data)
                local trimmed = HDG.Format.Trim(value)
                if trimmed == "" then return end
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.STYLE_CATEGORY_RENAME,
                    payload = { categoryID = data.categoryID, name = trimmed },
                })
            end,
        })
    end)
    row._catDeleteBtn:SetScript("OnClick", function()
        local n = ed.count
        -- Two popup ids: UI.Confirm memoizes `text` per id on first use, and the
        -- empty / non-empty wordings are different format strings.
        HDG.UI.Confirm({
            id       = (n == 0) and "HDGR_DELETE_CATEGORY_EMPTY" or "HDGR_DELETE_CATEGORY",
            text     = HDG.Locale:Get((n == 0) and "STY_LANDING_POPUP_DELETE_EMPTY" or "STY_LANDING_POPUP_DELETE"),
            textArg1 = name,
            textArg2 = (n == 1) and HDG.Locale:Get("STY_LANDING_ITS_ONE_STYLE")
                       or string.format(HDG.Locale:Get("STY_LANDING_ITS_N_STYLES_FMT"), n),
            accept   = HDG.Locale:Get("STY_LANDING_DELETE"),
            cancel   = HDG.Locale:Get("STY_LANDING_CANCEL"),
            data     = { categoryID = key },
            onAccept = function(_, data)
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.STYLE_CATEGORY_DELETE,
                    payload = { categoryID = data.categoryID },
                })
            end,
        })
    end)
end

-- ===== _resetLandingRow ======================================================
local function _resetLandingRow(row)
    row:SetScript("OnClick", nil)
    if row._labelFs    then row._labelFs:SetText("")    end
    HDG.UI.ClearRowText(row, "_subtitleFs")
    if row._countFs    then row._countFs:SetText("")    end
    if row._countCardFs then row._countCardFs:Hide() end
    if row._iconTex     then row._iconTex:Hide() end
    for i = 1, 6 do
        if row._previewTexs and row._previewTexs[i] then row._previewTexs[i]:Hide() end
    end
    if row._pbBg then row._pbBg:Hide() row._pbFill:Hide() row._pbFrame:Hide() end
    if row._urlBtn      then row._urlBtn:Hide() end
    if row._actionBtns then
        if row._actionBtns.edit   then row._actionBtns.edit:Hide()   end
        if row._actionBtns.export then row._actionBtns.export:Hide() end
        if row._actionBtns.delete then row._actionBtns.delete:Hide() end
        if row._actionBtns.category then row._actionBtns.category:Hide() end
    end
    if row._catAddBtn then _hideCategoryWidgets(row) end
    if row._newCatBtn then row._newCatBtn:Hide() end
end

local function _landingRowFactory(template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_stylesLandingLaidOut",
                function() _layoutLandingRow(row) end)
            if ed.kind == "card" then
                _paintLandingCard(row, ed)
            elseif ed.kind == "category" then
                _paintLandingCategory(row, ed)
            else
                _paintLandingHeader(row, ed, HDG.Theme:ColorCode("semantic.accent"))
            end
            row:SetHeight((ed.kind == "card" and _CARD_HEIGHT)
                       or (ed.kind == "category" and _CAT_HEIGHT)
                       or _HDR_HEIGHT)
            if ed.kind == "category" then
                _wireLandingCategory(row, ed)
            else
                _wireLandingCard(row, ed)
            end
        end,
        Reset = _resetLandingRow,
    }
end

HDG.Rows:Register("stylesLandingRow", {
    font    = "subheading",
    height  = function(_index, ed)
        if ed and ed.kind == "card"     then return _CARD_HEIGHT end
        if ed and ed.kind == "category" then return _CAT_HEIGHT  end
        return _HDR_HEIGHT
    end,
    factory = _landingRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        if ed.kind == "card"     then return "card:" .. tostring(ed.collectionID or "?") end
        if ed.kind == "category" then return "cat:"  .. tostring(ed.categoryID   or "?") end
        return "hdr:" .. tostring(ed.type or "?")
    end,
})

-- Shared name-only tooltip def for pooled CardGrid tiles (reads the per-init
-- self._tooltipName stamp). Shown from WITHIN OnEnter (re-wired every init) -- NOT
-- via TooltipEngine:Attach, whose once-installed HookScript gets clobbered by the
-- per-init OnEnter SetScript on pooled re-acquire (the stale-tooltip class).
local function _stylesNameTipDef(self_)
    local n = self_._tooltipName
    return n and { title = n } or nil
end

-- ===== Cell kind: stylesDetailTile =========================================
-- Item tile for the Detail surface's items grid. Selection highlight = active-
-- atlas swap; rule-based items get a band stripe via HDG.CardGrid:PaintBand.
HDG.CardGrid:RegisterCellKind("stylesDetailTile", {
    template = "Button",
    initFunc = function(cell, ed, cfg)
        HDG.CardGrid:EnsureDefaultAnatomy(cell, cfg)
        cell:Show()
        HDG.CardGrid:PaintIcon(cell, ed.iconTexture, ed.iconAtlas)
        local isSelected = ed.isSelected == true
        HDG.CardGrid:PaintSelected(cell, isSelected)
        -- Detail-jump landing animation: when this tile transitions from
        -- not-selected to selected, fire a brief scale pulse. Pulse
        -- only on the actual transition (not on scroll-back-in or
        -- redundant rebinds) -- tracked via cell._wasSelected. Reset
        -- to nil on pool release so a recycled cell doesn't inherit
        -- prior selection state.
        if isSelected and not cell._wasSelected then
            if not cell._selectionPulse then
                local ag = cell:CreateAnimationGroup()
                local up = ag:CreateAnimation("Scale")
                up:SetScaleTo(1.15, 1.15)
                up:SetDuration(0.1)
                up:SetOrigin("CENTER", 0, 0)
                up:SetSmoothing("OUT")
                local down = ag:CreateAnimation("Scale")
                down:SetScaleTo(0.8696, 0.8696)  -- 1/1.15 to undo
                down:SetDuration(0.15)
                down:SetOrigin("CENTER", 0, 0)
                down:SetSmoothing("IN")
                down:SetStartDelay(0.1)
                cell._selectionPulse = ag
            end
            cell._selectionPulse:Stop()
            cell._selectionPulse:Play()
        end
        cell._wasSelected = isSelected
        HDG.CardGrid:PaintCollected(cell, ed.isOwned == true)
        HDG.CardGrid:PaintBand(cell, ed.band)
        if cell.label then cell.label:Hide() end
        cell:RegisterForClicks("LeftButtonUp")
        local itemID = ed.itemID
        local name   = ed.name
        cell:SetScript("OnClick", function()
            if not itemID then return end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_DETAIL_SELECT_ITEM,
                payload = { itemID = itemID },
            })
            -- Detail-jump: navigate to Detail view so the SmartSet
            -- click actually surfaces the selected item rather than
            -- mutating off-screen state. The landing animation fires
            -- on the destination tile via stylesDetailTile's isSelected
            -- transition tracker (cell._wasSelected diff).
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_SET_VIEW,
                payload = { view = "detail" },
            })
        end)
        cell._tooltipName = name
        cell:SetScript("OnEnter", function(self_)
            if self_.hoverBg then self_.hoverBg:Show() end
            HDG.TooltipEngine:Show(self_, _stylesNameTipDef)
        end)
        cell:SetScript("OnLeave", function(self_)
            if self_.hoverBg then self_.hoverBg:Hide() end
            HDG.TooltipEngine:Hide()
        end)
    end,
    resetFunc = function(_pool, cell)
        cell:SetScript("OnClick", nil)
        cell:SetScript("OnEnter", nil)
        cell:SetScript("OnLeave", nil)
        if cell.hoverBg then cell.hoverBg:Hide() end
        -- Reset selection-pulse tracker so a recycled cell doesn't
        -- inherit "was selected" from a previous element binding.
        cell._wasSelected = nil
    end,
})

-- ===== Row factory: stylesCuratorTargetRow ==================================
-- "FILE INTO" target list row: displayName + count. Also renders the inline
-- actions sub-row (kind = "stylesCuratorTargetActionsRow" -- Rename/Dup/Delete)
-- injected by the selector after the selected target.
local function _buildActionsRowChildren(row)
    if row._actionsBuilt then return end
    row._actionsBuilt = true
    local function mkBtn(text, order)
        local b = HDG.UI:Button(row, text, "small")
        if b and b.SetHeight then b:SetHeight(18) end
        if b and b.SetPoint then
            local frac = (order - 1) / 3
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT",  row, "TOPLEFT",  2 + frac * (row:GetWidth() - 6), 0)
            b:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2 + frac * (row:GetWidth() - 6), 0)
            b:SetWidth(math.max(40, (row:GetWidth() - 8) / 3))
        end
        return b
    end
    row._btnRename    = mkBtn("Rename", 1)
    row._btnDuplicate = mkBtn("Duplicate", 2)
    row._btnDelete    = mkBtn("Delete", 3)
end

local function _hideActions(row)
    if row._btnRename    then row._btnRename:Hide()    end
    if row._btnDuplicate then row._btnDuplicate:Hide() end
    if row._btnDelete    then row._btnDelete:Hide()    end
end

-- Click closures: rebuilt per Configure so pooled rows track the current target.
local function _onRenameClick(targetID, displayName)
    return function()
        HDG.UI.Confirm({
            id         = "HDGR_RENAME_STYLE",
            text       = 'Rename style "%s":',
            textArg1   = displayName,
            accept     = "Rename",
            cancel     = "Cancel",
            input      = true,
            maxLetters = 64,
            -- prefill: the box opens on the current name (UI.Confirm's OnShow reads
            -- data.prefill); a bare id here left it empty, unlike the category rename.
            data       = { collectionID = targetID, prefill = displayName },
            onAccept   = function(value, data)
                local name = HDG.Format.Trim(value)
                if name == "" then return end
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.STYLES_RENAME_STYLE,
                    payload = { collectionID = data.collectionID, displayName = name },
                })
            end,
        })
    end
end

local function _onDuplicateClick(targetID)
    return function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_DUPLICATE_STYLE,
            payload = { collectionID = targetID },
        })
    end
end

local function _onDeleteClick(targetID, displayName)
    return function()
        local dialogID, text = _deleteConfirm(targetID)
        HDG.UI.Confirm({
            id       = dialogID,
            text     = text,
            textArg1 = displayName,
            accept   = "Delete",
            cancel   = "Cancel",
            data     = targetID,
            onAccept = _dispatchStyleDelete,
        })
    end
end

local function _onSelectTargetClick(targetID)
    return function()
        if not targetID then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_CURATOR_SELECT_TARGET,
            payload = { targetID = targetID },
        })
    end
end

-- Reanchor one action button; hoisted out of Configure to avoid per-Configure closure.
local function _reanchorActionBtn(row, btn, order)
    if not (btn and btn.SetPoint) then return end
    local w = row:GetWidth() or 200  -- exception(boundary): frame geometry nil before first layout
    local frac = (order - 1) / 3
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT",    row, "TOPLEFT",    2 + frac * (w - 6), 0)
    btn:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2 + frac * (w - 6), 0)
    btn:SetWidth(math.max(40, (w - 8) / 3))
end

-- Actions sub-row: 3 inline buttons (Rename/Dup/Delete), hides name/count.
local function _configureActionsRow(row, ed)
    _hideActions(row)
    _buildActionsRowChildren(row)
    _reanchorActionBtn(row, row._btnRename,    1)
    _reanchorActionBtn(row, row._btnDuplicate, 2)
    _reanchorActionBtn(row, row._btnDelete,    3)
    if row._btnRename    then row._btnRename:Show()    end
    if row._btnDuplicate then row._btnDuplicate:Show() end
    if row._btnDelete    then row._btnDelete:Show()    end
    if row._nameFs  then row._nameFs:SetText("")  end
    HDG.UI.ClearRowText(row, "_countFs")
    HDG.Theme:Register(row, "RowChrome", { selected = false })
    row:SetHeight(22)
    row:SetScript("OnClick", nil)
    local targetID    = ed.collectionID
    local displayName = ed.displayName or "?"
    if row._btnRename and row._btnRename.SetScript then
        row._btnRename:SetScript("OnClick", _onRenameClick(targetID, displayName))
    end
    if row._btnDuplicate and row._btnDuplicate.SetScript then
        row._btnDuplicate:SetScript("OnClick", _onDuplicateClick(targetID))
    end
    if row._btnDelete and row._btnDelete.SetScript then
        row._btnDelete:SetScript("OnClick", _onDeleteClick(targetID, displayName))
    end
end

-- First-paint: name + count. Idempotent via RowFirstPaint sentinel.
local function _layoutTargetRow(row)
    HDG.UI:RowFirstPaint(row, "_stylesCuratorTargetLaidOut", function()
        local name = HDG.UI.RowText(row, "body", "Text", "LEFT")
        name:SetPoint("LEFT",  row, "LEFT",  6, 0)
        name:SetPoint("RIGHT", row, "RIGHT", -32, 0)
        row._nameFs = name
        local count = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
        count:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row._countFs = count
    end)
end

-- Default target row: empty-state placeholder OR selectable target.
local function _configureTargetRow(row, ed, template)
    _layoutTargetRow(row)
    _hideActions(row)
    if ed.empty then
        HDG.Theme:Register(row._nameFs, "TextDim")
        row._nameFs:SetText(ed.label or "No styles yet")
        row._countFs:SetText("")
        HDG.Theme:Register(row, "RowWoodBeam", { alpha = 0.4 })  -- scheme-invariant: register first
        HDG.Theme:Register(row, "RowChrome",    { selected = false })  -- scheme-dependent: must win the registry
        row:SetHeight((template.height or 20) * 2)
        row:SetScript("OnClick", nil)
        return
    end
    HDG.Theme:Register(row._nameFs, "Text")
    row._nameFs:SetText(ed.displayName or "?")
    row._countFs:SetText(tostring(ed.count or 0))
    HDG.Theme:Register(row, "RowWoodBeam", { alpha = 0.4 })  -- scheme-invariant: register first
    HDG.Theme:Register(row, "RowChrome",    { selected = ed.isSelected == true })  -- scheme-dependent: must win the registry
    row:SetHeight(template.height)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", _onSelectTargetClick(ed.collectionID))
end

local function _curatorTargetRowFactory(template)
    return {
        Configure = function(row, ed)
            if ed.kind == "stylesCuratorTargetActionsRow" then
                _configureActionsRow(row, ed)
            else
                _configureTargetRow(row, ed, template)
            end
        end,
        Reset = function(row)
            row:SetScript("OnClick", nil)
            if row._nameFs  then row._nameFs:SetText("")  end
            HDG.UI.ClearRowText(row, "_countFs")
            _hideActions(row)
        end,
    }
end

HDG.Rows:Register("stylesCuratorTargetRow", {
    font    = "body",
    height  = 20,
    factory = _curatorTargetRowFactory,
    key     = function(ed)
        -- Disambiguate target rows vs the injected actions sub-row so
        -- pooling doesn't collide on the same collectionID (both rows
        -- share collectionID for the selected target).
        local prefix = (ed and ed.kind == "stylesCuratorTargetActionsRow")
            and "tgt-act:" or "tgt:"
        return prefix .. tostring(ed and ed.collectionID or "?")
    end,
})

-- ===== Cell kinds: Curator chip strips (FlowContainer) ====================
-- Icon-only cells (atlas already state-resolved by the selector). Name + count
-- live in the hover tooltip. Category + subcategory cells share one factory.
local function _iconCellLabel(item)
    return item.atlas and ("|A:" .. item.atlas .. ":32:32|a") or item.name
end
local function _registerCuratorIconCell(cellName, actionType, payloadKey)
    HDG.ChipStrip:RegisterCellKind(cellName, {
        constructor = function(parent, cfg)
            return HDG.ChipStrip:IconChipConstructor(parent, cfg)
        end,
        binder = function(chip, item, cfg)
            if not item then
                chip:Hide()
                chip:SetScript("OnClick", nil)
                -- Do NOT clear OnEnter/OnLeave: the chip is hidden (no hover), and
                -- clearing them would clobber TooltipEngine:Attach's once-installed
                -- HookScript -> no tooltip after the chip is re-shown (pooled).
                return
            end
            chip:Show()
            chip:SetText(_iconCellLabel(item))  -- atlas glyph IS the cell; _active suffix IS the selection indicator
            if chip.SetScript then  -- exception(false-positive): Frame always has SetScript; mock-fidelity guard
                chip:RegisterForClicks("LeftButtonUp")
                -- isAll clears to nil. Must be a real branch, not `isAll and nil or id`
                -- (Lua 5.1: nil or id returns id; id is 0 = Uncategorized bucket).
                local id; if not item.isAll then id = item.id end
                local itemName, count = item.name, item.count
                chip:SetScript("OnClick", function()
                    HDG.Store:Dispatch({ type = actionType, payload = { [payloadKey] = id } })
                end)
                chip._tooltipName  = itemName
                chip._tooltipCount = count
                HDG.TooltipEngine:Attach(chip, function(self)
                    local n = self._tooltipName
                    if not n then return nil end
                    local c = self._tooltipCount
                    local def = { anchor = "ANCHOR_TOP", title = n }
                    if c then def.extraLines = { { text = c .. " items", r = 0.7, g = 0.7, b = 0.7 } } end
                    return def
                end)
            end
        end,
        sizer = function(item, cfg)
            return HDG.ChipStrip:DefaultChipSizer({ label = _iconCellLabel(item) }, cfg)
        end,
    })
end
_registerCuratorIconCell("curatorCategoryIcon",
    HDG.Constants.ACTIONS.STYLES_CURATOR_SET_CATEGORY, "categoryID")
_registerCuratorIconCell("curatorSubcategoryIcon",
    HDG.Constants.ACTIONS.STYLES_CURATOR_SET_SUBCATEGORY, "subcategoryID")

-- ===== Cell kind: stylesCuratorTile =========================================
-- Icon-only multi-select tile inside HDG.CardGrid.
-- Rich hover tooltip (name + Indoor/Outdoor + Stored/Placed), mirroring
-- acqVendorItemTile. Module-level def + per-init self._tip* stamps: Attach hooks
-- OnEnter once, so a per-acquire closure capturing locals would freeze on a
-- pooled cell's first item (the 2026-06-06 vendor-tile stale-tooltip class).
local function _curatorTileDef(self_)
    if not self_._tipName then return nil end   -- exception(nullable): cell not yet painted
    local th = HDG.Theme:GetColor("text.heading")
    local td = HDG.Theme:GetColor("text.dim")
    local lines = { { text = self_._tipName, r = th.r, g = th.g, b = th.b } }
    if self_._tipPlace ~= "" then lines[#lines+1] = { text = self_._tipPlace, r = td.r, g = td.g, b = td.b } end
    lines[#lines+1] = { text = "Stored: " .. self_._tipStored, r = td.r, g = td.g, b = td.b }
    lines[#lines+1] = { text = "Placed: " .. self_._tipPlaced, r = td.r, g = td.g, b = td.b }
    return { anchor = "ANCHOR_RIGHT", extraLines = lines }
end

HDG.CardGrid:RegisterCellKind("stylesCuratorTile", {
    template = "Button",
    initFunc = function(cell, ed, cfg)
        HDG.CardGrid:EnsureDefaultAnatomy(cell, cfg)
        cell:Show()
        HDG.CardGrid:PaintIcon(cell, ed.iconTexture, ed.iconAtlas)
        HDG.CardGrid:PaintSelected(cell, ed.isSelected == true)
        HDG.CardGrid:PaintMemberBadge(cell, ed.memberCount)  -- set-membership count badge (TOPLEFT)
        -- Label hidden; TooltipEngine carries the name (tile is 80px square).
        if cell.label then cell.label:Hide() end
        cell:RegisterForClicks("LeftButtonUp")
        local itemID = ed.itemID
        local name   = ed.name
        cell:SetScript("OnClick", function()
            if not itemID then return end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_CURATOR_TOGGLE_SELECT,
                payload = { itemID = itemID },
            })
        end)
        -- Rich tooltip stamps (read by _curatorTileDef on hover). Indoor/Outdoor
        -- mirrors acqVendorItemTile's _placementLabel; stored/placed = live catalog.
        local indoor, outdoor = ed.isAllowedIndoors, ed.isAllowedOutdoors
        cell._tipName   = name
        cell._tipPlace  = (indoor and outdoor) and "Indoor / Outdoor"
                          or indoor and "Indoor" or outdoor and "Outdoor" or ""
        cell._tipStored = ed.numStored or 0
        cell._tipPlaced = ed.numPlaced or 0
        -- Show the tooltip from WITHIN OnEnter rather than TooltipEngine:Attach:
        -- this tile re-SetScripts OnEnter every init (hover-bg + CURATOR_HOVER
        -- dispatch), which clobbers the once-installed Attach HookScript on pooled
        -- re-acquire -> no tooltip. Doing it here is re-wired + fires every init.
        cell:SetScript("OnEnter", function(self_)
            if self_.hoverBg then self_.hoverBg:Show() end
            if itemID then
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.STYLES_CURATOR_HOVER,
                    payload = { itemID = itemID },
                })
            end
            HDG.TooltipEngine:Show(self_, _curatorTileDef)
        end)
        cell:SetScript("OnLeave", function(self_)
            if self_.hoverBg then self_.hoverBg:Hide() end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_CURATOR_HOVER,
                payload = { itemID = nil },
            })
            HDG.TooltipEngine:Hide()
        end)
    end,
    resetFunc = function(_pool, cell)
        cell:SetScript("OnClick", nil)
        cell:SetScript("OnEnter", nil)
        cell:SetScript("OnLeave", nil)
        if cell.hoverBg then cell.hoverBg:Hide() end
    end,
})

-- ===== Row factory: stylesCuratorRecentRow ==================================
-- One line per Recent (Undo) entry. Click dispatches STYLES_CURATOR_UNDO_AT.
local function _wireRowChromeHover(row)
    row:SetScript("OnEnter", function(self_)
        local hover = self_._hdgrChrome and self_._hdgrChrome.hover
        if hover and hover.Show then hover:Show() end
    end)
    row:SetScript("OnLeave", function(self_)
        local hover = self_._hdgrChrome and self_._hdgrChrome.hover
        if hover and hover.Hide then hover:Hide() end
    end)
end

local function _layoutCuratorRecentRow(row)
    local label = HDG.UI.RowText(row, "caption", "Text", "LEFT")
    label:SetPoint("LEFT",  row, "LEFT",  6, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._labelFs = label
end

local function _paintCuratorRecentRow(row, ed)
    row._labelFs:SetText(ed.label or "")
end

-- Click undoes the curator action at this ordinal; hover chrome on top.
local function _wireCuratorRecentRow(row, ed)
    local ord = ed.ord
    row:SetScript("OnClick", function()
        if not ord then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_CURATOR_UNDO_AT,
            payload = { ord = ord },
        })
    end)
    _wireRowChromeHover(row)
end

HDG.Rows:Register("stylesCuratorRecentRow", {
    font    = "caption",   -- 10px (was "small" 11px) -- per Vamoose
    height  = 14,          -- tighter row to match smaller font (was 16)
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutCuratorRecentRow,
        paint      = _paintCuratorRecentRow,
        laidOutTag = "_stylesCuratorRecentLaidOut",
        clicks     = "LeftButtonUp",
        wire       = _wireCuratorRecentRow,
        resetText  = { "_labelFs" },
        reset      = function(row)
            row:SetScript("OnEnter", nil)
            row:SetScript("OnLeave", nil)
        end,
    }),
    key     = function(ed) return "rec:" .. tostring(ed and ed.ord or "?") end,
})

-- ===== Row factory: stylesCuratorMembershipRow ==============================
-- One line per collection the hovered item belongs to.
local _layoutCuratorMembershipRow = _layoutCuratorRecentRow  -- hygiene A17: byte-identical layout

local function _paintCuratorMembershipRow(row, ed)
    -- Placeholder ("(unassigned)") dims; real memberships use Text.
    HDG.Theme:Register(row._labelFs, ed.isPlaceholder and "TextDim" or "Text")
    row._labelFs:SetText(ed.label or "")
end

HDG.Rows:Register("stylesCuratorMembershipRow", {
    font    = "caption",   -- 10px (was "small" 11px) -- match Recent rows for right-column consistency
    height  = 14,          -- tighter row to match smaller font (was 16)
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutCuratorMembershipRow,
        paint      = _paintCuratorMembershipRow,
        laidOutTag = "_stylesCuratorMembershipLaidOut",
        resetText  = { "_labelFs" },
    }),
    key     = function(ed)
        if not ed then return "?" end
        return "mem:" .. tostring(ed.collectionID or ed.label or "?")
    end,
})

-- ===== Row factories: Smart Set Builder =====================================
-- Lazy chrome: axis label (fill, body) + tag count (right, small).
local function _layoutSmartsetAxisRow(row)
    local label = HDG.UI.RowText(row, "body", "Text", "LEFT")
    label:SetPoint("LEFT",  row, "LEFT",  8, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    row._labelFs = label
    local count = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    count:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._countFs = count
end

local function _paintSmartsetAxisRow(row, ed)
    row._labelFs:SetText(ed.label or ed.axis or "?")
    row._countFs:SetText(ed.tagCount and ed.tagCount > 0 and tostring(ed.tagCount) or "")
end

-- Click sets the active smart-set axis.
local function _wireSmartsetAxisRow(row, ed)
    local axis = ed.axis
    row:SetScript("OnClick", function()
        if not axis then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_SMARTSET_SET_AXIS,
            payload = { axis = axis },
        })
    end)
end

HDG.Rows:Register("stylesAxisRow", {
    font    = "body",
    height  = 22,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutSmartsetAxisRow,
        paint      = _paintSmartsetAxisRow,
        laidOutTag = "_smartsetAxisLaidOut",
        selectedFn = function(ed) return ed.isActive end,
        clicks     = "LeftButtonUp",
        wire       = _wireSmartsetAxisRow,
        resetText  = { "_labelFs", "_countFs" },
    }),
    key     = function(ed) return "axis:" .. tostring(ed and ed.axis or "?") end,
})


-- Tag row: name + tally + affinity hint (green >=40% / red <=5% co-occurrence).
-- Click toggles signature membership. Bands are per-item, not per-tag.
local _AFFINITY_HIGH, _AFFINITY_LOW = 40, 5

-- Lazy chrome: label (fill) + count, both "small".
local function _layoutSmartsetTagRow(row)
    local label = HDG.UI.RowText(row, "small", "Text", "LEFT")
    label:SetPoint("LEFT",  row, "LEFT",  6, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    row._labelFs = label
    local count = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    count:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row._countFs = count
end

-- Selected (signature) tags get the selected highlight; unselected tags colour
-- by affinity. affinityPct is optional (nil = insufficient data).
local function _paintSmartsetTagRow(row, ed)
    local selected = ed.severity ~= nil
    row._labelFs:SetText(ed.label)
    row._countFs:SetText(ed.count > 0 and tostring(ed.count) or "")
    local labelRole = "Text"
    if not selected then
        local pct = ed.affinityPct  -- exception(boundary): optional co-occurrence data
        if pct and pct >= _AFFINITY_HIGH then labelRole = "TextSuccess"
        elseif pct and pct <= _AFFINITY_LOW then labelRole = "TextError" end
    end
    HDG.Theme:Register(row._labelFs, labelRole)
end

-- Click toggles signature membership. axis threaded at refresh time.
local function _wireSmartsetTagRow(row, ed)
    local axis = ed._axis
    local tag  = ed.tag
    row:SetScript("OnClick", function()
        if not tag then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_SMARTSET_TOGGLE_TAG,
            payload = { axis = axis, tag = tag, severity = "signature" },
        })
    end)
end

HDG.Rows:Register("stylesTagRow", {
    font    = "small", height = 20,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutSmartsetTagRow,
        paint      = _paintSmartsetTagRow,
        laidOutTag = "_smartsetTagLaidOut",
        selectedFn = function(ed) return ed.severity ~= nil end,
        clicks     = "LeftButtonUp",
        wire       = _wireSmartsetTagRow,
        resetText  = { "_labelFs", "_countFs" },
    }),
    key = function(ed) return "tag:" .. tostring(ed and (ed.tag or ed.label) or "?") end,
})

-- ===== Cell kind: stylesPreviewTile =========================================
-- SmartSet centre preview via CardGrid. Band stripe + click-through to
-- STYLES_DETAIL_SELECT_ITEM. The basket column was removed: a Smart Set is a
-- live facet query; the centre IS the result.
HDG.CardGrid:RegisterCellKind("stylesPreviewTile", {
    template = "Button",
    initFunc = function(cell, ed, cfg)
        HDG.CardGrid:EnsureDefaultAnatomy(cell, cfg)
        cell:Show()
        HDG.CardGrid:PaintIcon(cell, ed.iconTexture, ed.iconAtlas)
        HDG.CardGrid:PaintBand(cell, ed.band)
        if cell.label then cell.label:Hide() end
        cell:RegisterForClicks("LeftButtonUp")
        local itemID = ed.itemID
        local name   = ed.name
        cell:SetScript("OnClick", function()
            if not itemID then return end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_DETAIL_SELECT_ITEM,
                payload = { itemID = itemID },
            })
            -- Detail-jump: navigate to Detail view so the SmartSet
            -- click actually surfaces the selected item rather than
            -- mutating off-screen state. The landing animation fires
            -- on the destination tile via stylesDetailTile's isSelected
            -- transition tracker (cell._wasSelected diff).
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_SET_VIEW,
                payload = { view = "detail" },
            })
        end)
        cell._tooltipName = name
        cell:SetScript("OnEnter", function(self_)
            if self_.hoverBg then self_.hoverBg:Show() end
            HDG.TooltipEngine:Show(self_, _stylesNameTipDef)
        end)
        cell:SetScript("OnLeave", function(self_)
            if self_.hoverBg then self_.hoverBg:Hide() end
            HDG.TooltipEngine:Hide()
        end)
    end,
    resetFunc = function(_pool, cell)
        cell:SetScript("OnClick", nil)
        cell:SetScript("OnEnter", nil)
        cell:SetScript("OnLeave", nil)
        if cell.hoverBg then cell.hoverBg:Hide() end
    end,
})

-- ===== Row factory: stylesImportPreviewRow ==================================
-- One row per parsed itemID. Dim "unknown" tail for items not in the catalog.
local function _layoutImportPreviewRow(row)
    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row._iconTex = icon
    local name = HDG.UI.RowText(row, "small", "Text", "LEFT")
    name:SetPoint("LEFT",  icon, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    row._nameFs = name
    local tail = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    tail:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row._tailFs = tail
end

-- Paint icon from ed.iconTexture (preferred) OR ed.iconAtlas; Hide() when
-- neither is set. Used by import-preview rows where the catalog data may
-- ship one form or the other.
local function _paintIconTextureOrAtlas(icon, ed)
    if not icon then return end
    if ed.iconTexture and icon.SetTexture then
        icon:SetTexture(ed.iconTexture)
        icon:Show()
    elseif ed.iconAtlas and icon.SetAtlas then
        icon:SetAtlas(ed.iconAtlas)
        icon:Show()
    else
        icon:SetTexture(nil)
        icon:Hide()
    end
end

local function _importPreviewRowFactory(template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_stylesImportPreviewLaidOut",
                function() _layoutImportPreviewRow(row) end)
            HDG.Theme:Register(row, "RowChrome", { selected = false })
            _paintIconTextureOrAtlas(row._iconTex, ed)
            row._nameFs:SetText(ed.name or "?")
            row._tailFs:SetText(ed.isKnown and ("#" .. tostring(ed.itemID)) or "unknown")
            row:SetHeight(template.height)
        end,
        Reset = function(row)
            if row._nameFs  then row._nameFs:SetText("") end
            if row._tailFs  then row._tailFs:SetText("") end
            if row._iconTex then row._iconTex:Hide()    end
        end,
    }
end

HDG.Rows:Register("stylesImportPreviewRow", {
    font    = "small", height = 18, factory = _importPreviewRowFactory,
    key = function(ed) return "imp:" .. tostring(ed and ed.itemID or "?") end,
})

-- ===== Row factory: stylesExportSourceRow ===================================
-- "header" rows (group label + count, non-interactive) and "item" rows (name +
-- count hint, click -> STYLES_EXPORT_SELECT). Selection highlight via ed.isSelected.
local function _layoutExportSourceRow(row)
    local label = HDG.UI.RowText(row, "small", "Text", "LEFT")
    label:SetPoint("LEFT",  row, "LEFT", 10, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -70, 0)
    row._exLabel = label
    local tail = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    tail:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._exTail = tail
end

local function _paintExportHeader(row, ed)
    HDG.UI.applyFontRole(row._exLabel, "subheading")
    row._exLabel:ClearAllPoints()
    row._exLabel:SetPoint("LEFT",  row, "LEFT", 8, 0)
    row._exLabel:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    -- Accent-coloured label = the same distinction the landing headers use.
    row._exLabel:SetText(HDG.Theme:ColorCode("semantic.accent") .. ed.label .. "|r")
    row._exTail:SetText(ed.count and tostring(ed.count) or "")
    row:SetScript("OnClick", nil)
    row:EnableMouse(false)
    HDG.Theme:Register(row, "RowWoodBeam", { alpha = 0.7 })            -- scheme-invariant: register first
    HDG.Theme:Register(row, "RowChrome",   { selected = false })        -- scheme-dependent: must win
end

local function _paintExportItem(row, ed)
    HDG.UI.applyFontRole(row._exLabel, "small")
    row._exLabel:ClearAllPoints()
    row._exLabel:SetPoint("LEFT",  row, "LEFT", 22, 0)   -- indent under the group header
    row._exLabel:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    row._exLabel:SetText(ed.name or "?")
    row._exTail:SetText(ed.countHint and (ed.countHint .. " items") or "")
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_EXPORT_SELECT, payload = { key = ed.key } })
    end)
    HDG.Theme:Register(row, "RowWoodBeam", { alpha = 0.2 })            -- scheme-invariant: register first
    HDG.Theme:Register(row, "RowChrome",   { selected = ed.isSelected == true })  -- scheme-dependent: must win
end

local function _exportSourceRowFactory(template)
    return {
        Configure = function(row, ed)
            HDG.UI:RowFirstPaint(row, "_stylesExportRowLaidOut", function() _layoutExportSourceRow(row) end)
            if ed.kind == "header" then _paintExportHeader(row, ed) else _paintExportItem(row, ed) end
            row:SetHeight(template.height)
        end,
        Reset = function(row)
            if row._exLabel then row._exLabel:SetText("") end  -- exception(nullable): fields absent until first layout
            if row._exTail  then row._exTail:SetText("")  end  -- exception(nullable): fields absent until first layout
            row:SetScript("OnClick", nil)
        end,
    }
end

HDG.Rows:Register("stylesExportSourceRow", {
    font = "small", height = 20, factory = _exportSourceRowFactory,
    key = function(ed) return "exp:" .. tostring(ed and (ed.key or ed.label) or "?") end,
})

-- ===== Export code generation ================================================
-- Controller-side: codecs + the catalog observer are non-store singletons, so
-- the export string can't be a selector. Routed by source-key prefix + format.
local function _exportNativeCode(key, st)
    if key == "collection" then
        local obs, items = HDG.HousingCatalogObserver, {}
        obs:RequestLoad("export-collection")
        obs:IterateRows(function(itemID, row)
            if row.decorID and obs:IsOwned(row) then
                items[#items + 1] = { itemID = itemID,
                    qty = (row.quantity or 0) + (row.remainingRedeemable or 0) + (row.numPlaced or 0) }  -- exception(boundary): catalog struct fields sparse
            end
        end)
        return HDG.ShoppingCodec.Encode({ name = "My Decor Collection", items = items, meta = { source = "hdg" } })
    end
    if key:match("^vsl:") then
        local list = st.account.vendorShoppingLists[key:sub(5)]  -- exception(nullable): stale UI key
        if not list then return "" end
        return HDG.ShoppingCodec.Encode(list)
    end
    if key:match("^set:") then
        local set = st.account.furnishingSets[key]  -- exception(nullable): stale UI key
        if not set then return "" end
        return HDG.Projects.CrateCodec.Encode({ name = set.name, decor = set.items })
    end
    local rec = HDG.StyleResolve.RecordFor(key, st)  -- style: / concept: / collection:
    if not rec then return "" end
    return HDG.StyleSerializer:Export(rec)
end

local function _exportCaption(fmt, key, count)
    if fmt ~= "dd2" then return HDG.Locale:Get("STY_EXPORT_HDG_HINT") end
    if key == "collection"  then return string.format(HDG.Locale:Get("STY_EXPORT_DD2_COLLECTION"), count) end
    if key:match("^style:") then return HDG.Locale:Get("STY_EXPORT_DD2_STYLE_LOSSY") end
    return HDG.Locale:Get("STY_EXPORT_DD2_OWNED_WARN")
end

-- Recompute code box + caption when the export selection or format changes.
-- Dirty-check skips redundant re-encodes on unrelated rebinds.
local _exportLast = {}
local function _refreshExportCode(rootFrame)
    local st = HDG.Store:GetState()  -- exception(false-positive): top-level controller refresh, not a row factory
    if st.session.ui.styles.view ~= "export" then _exportLast.key = nil; return end
    local exp = st.session.ui.styles.export
    local key, fmt = exp.selectedKey, exp.format

    local codeBox = HDG.UI.W(rootFrame, "stylesPanel.exportCode")
    local caption = HDG.UI.W(rootFrame, "stylesPanel.exportCaption")
    if codeBox.EditBox then  -- exception(boundary): inner EditBox absent in mock template
        codeBox.EditBox:SetMaxLetters(0)
        codeBox.EditBox:SetMaxBytes(0)
    end

    -- Collection needs a warm catalog; retry (don't cache) until ready.
    if key == "collection" and not HDG.HousingCatalogObserver:IsReady() then
        HDG.HousingCatalogObserver:RequestLoad("export-collection")
        codeBox:SetText(""); caption:SetText(HDG.Locale:Get("STY_EXPORT_LOADING"))
        _exportLast.key = nil
        return
    end

    if _exportLast.key == key and _exportLast.fmt == fmt then return end
    _exportLast.key, _exportLast.fmt = key, fmt

    if not key then codeBox:SetText(""); caption:SetText(""); return end

    local code, cap
    if fmt == "dd2" then
        local entries = HDG.ExportAdapter.Entries(key, st)
        code = HDG.DecorDumpCodec.Encode(entries, {})
        cap  = _exportCaption("dd2", key, #entries)
    else
        code = _exportNativeCode(key, st)
        cap  = _exportCaption("hdg", key, 0)
    end
    codeBox:SetText(code or ""); caption:SetText(cap or "")
end

-- ===== Landing menus (spec HDGR_STYLE_CATEGORIES_SPEC_2026-09-04 s5.3) ==========
-- Both are MenuUtil menus built at click time from the two small landing
-- selectors; both dispatch the one reducer that writes categoryID.

-- A: per-style radio menu. The ONLY place a style moves between categories or
-- leaves one. "New category..." creates and files in a single dispatch.
_openFileIntoMenu = function(anchor, collectionID, displayName, currentCategoryID)
    local A = HDG.Constants.ACTIONS
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller read
    local choices = HDG.Selectors:Call("styles.landing.categoryChoices", state, {})
    local items = { { isTitle = true, text = HDG.Locale:Get("STY_LANDING_FILE_INTO") } }
    for _, c in ipairs(choices) do
        local catID = c.id
        items[#items + 1] = { kind = "radio", text = c.name, value = catID,
            selected = (currentCategoryID == catID),
            callback = function()
                HDG.Store:Dispatch({ type = A.STYLE_SET_CATEGORY,
                    payload = { collectionID = collectionID, categoryID = catID } })
            end }
    end
    items[#items + 1] = { kind = "radio", text = HDG.Locale:Get("STY_LANDING_NO_CATEGORY"), value = "",
        selected = (currentCategoryID == nil),
        callback = function()
            HDG.Store:Dispatch({ type = A.STYLE_SET_CATEGORY,
                payload = { collectionID = collectionID, categoryID = nil } })
        end }
    items[#items + 1] = { isDivider = true }
    items[#items + 1] = { text = HDG.Locale:Get("STY_LANDING_NEW_CATEGORY_MENU"), callback = function()
        HDG.UI.Confirm({
            id         = "HDGR_NEW_CATEGORY_FILE",
            text       = HDG.Locale:Get("STY_LANDING_POPUP_NEW_FILE"),
            textArg1   = displayName,
            accept     = HDG.Locale:Get("STY_LANDING_CREATE"),
            cancel     = HDG.Locale:Get("STY_LANDING_CANCEL"),
            input      = true,
            maxLetters = 40,
            data       = { fileStyleID = collectionID },
            onAccept   = function(value, data)
                local name = HDG.Format.Trim(value)
                if name == "" then return end
                HDG.Store:Dispatch({ type = A.STYLE_CATEGORY_CREATE,
                    payload = { name = name, fileStyleID = data.fileStyleID } })
            end,
        })
    end }
    HDG.UI.ShowMenu(anchor, items)
end

-- B: per-category checkbox menu over the styles NOT in any category (list fixed
-- at open time). Tick = filed now; untick before closing = unfiled. The poll
-- reads the live record, not the loose list, or every tick would bounce back.
_openAddStylesMenu = function(anchor, categoryID, categoryName)
    local A = HDG.Constants.ACTIONS
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller read
    local loose = HDG.Selectors:Call("styles.landing.looseStyles", state, {})
    local countLine = string.format(HDG.Locale:Get("STY_LANDING_LOOSE_COUNT_FMT"), #loose)
    if #loose > 20 then countLine = countLine .. HDG.Locale:Get("STY_LANDING_SCROLLS_HINT") end
    local items = {
        { isTitle = true, text = string.format(HDG.Locale:Get("STY_LANDING_ADD_TO_FMT"), categoryName) },
        { isTitle = true, text = countLine },
    }
    for _, s in ipairs(loose) do
        local id = s.collectionID
        items[#items + 1] = { kind = "checkbox", text = s.displayName,
            isSelected = function()
                return HDG.Store:GetState().account.collections[id].categoryID == categoryID  -- exception(false-positive): top-level controller read (menu poll)
            end,
            callback = function()
                local filedHere = HDG.Store:GetState().account.collections[id].categoryID == categoryID  -- exception(false-positive): top-level controller read
                HDG.Store:Dispatch({ type = A.STYLE_SET_CATEGORY,
                    payload = { collectionID = id, categoryID = (not filedHere) and categoryID or nil } })
            end }
    end
    HDG.UI.ShowMenu(anchor, items)
end

local StylesController = {}

function StylesController:Wire(rootFrame)
    if not HDG.Log:HasTag("styles_action") then
        HDG.Log:RegisterTabTags("styles")
    end

    -- ===== Landing surface =====
    -- Filter chips (All + 6 collection types). Active-state via enum selectors.
    local FILTER_CHIPS = {
        "all", "style", "smartset", "shopping", "snapshot", "concept", "collection",
    }
    for _, value in ipairs(FILTER_CHIPS) do
        local v = value
        HDG.UI.OnClick(rootFrame, "stylesPanel.filter_" .. v, function()
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_LANDING_SET_FILTER,
                payload = { filter = v },
            })
        end)
    end

    -- Landing search: dedicated action. The generic WireSearchBox writes
    -- session.ui.styles.search, which nothing reads; the list reads
    -- session.ui.styles.landing.search (same shape as the detail box below).
    HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, "stylesPanel.landingSearch"), function(text)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_LANDING_SET_SEARCH, payload = { text = text } })
    end)

    -- Back button: consolidated single handler, always dispatches view=landing.
    HDG.UI.OnClick(rootFrame, "stylesPanel.headerBack", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_SET_VIEW,
            payload = { view = "landing" },
        })
    end)

    -- Source button: pop the shared slimline URL copy field under it.
    HDG.UI.OnClick(rootFrame, "stylesPanel.detailSourceLink", function(btn)
        local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
        local url   = HDG.Selectors:Call("styles.detail.sourceUrl", state, {})
        HDG.UI:UrlCopyPopup():ShowAt(btn, url)
    end)

    -- ===== Detail surface =====
    -- Dedicated action STYLES_DETAIL_SET_SEARCH: generic WireSearchBox writes
    -- session.ui.<tab>.<key> which doesn't reach the nested detail.search slot.
    HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, "stylesPanel.detailSearch"), function(text)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_DETAIL_SET_SEARCH, payload = { text = text } })
    end)

    -- ===== Curator surface =====
    -- Source-mode picker self-wires via kind="dropdown".
    -- Card-grid search: dedicated action (nested curator.searchQuery slot, like detail).
    HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, "stylesPanel.curatorSearch"), function(text)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_CURATOR_SET_SEARCH, payload = { text = text } })
    end)

    -- Move / Copy: reducer guards reject missing target/items. Move removes from the
    -- source style; Copy (payload.copy) keeps the items in their source.
    local function _curatorFile(copy)
        local state = HDG.Store:GetState()  -- exception(false-positive): OnClick handler, not a row factory
        local targetID = state.session.ui.styles.curator.selectedTargetID
        if not targetID then return end
        local targetColl = state.account.collections[targetID]  -- nil for invalid ID (handled by reducer)
        local targetName = (targetColl and targetColl.displayName) or targetID
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_CURATOR_MOVE,
            payload = { targetID = targetID, copy = copy },
        })
        HDG.Log:Info("styles_action",
            (copy and "Copied selected items to " or "Moved selected items to ") .. targetName)
    end
    HDG.UI.OnClick(rootFrame, "stylesPanel.curatorMove", function() _curatorFile(false) end)
    HDG.UI.OnClick(rootFrame, "stylesPanel.curatorCopy", function() _curatorFile(true) end)

    HDG.UI.OnClick(rootFrame, "stylesPanel.curatorNewStyle", function()
        HDG.UI.Confirm({
            id         = "HDGR_NEW_STYLE",
            text       = "Name the new style:",
            accept     = "Create",
            cancel     = "Cancel",
            input      = true,
            maxLetters = 64,
            onAccept   = function(value)
                local name = HDG.Format.Trim(value)
                if name == "" then return end
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.STYLES_CREATE_STYLE,
                    payload = { displayName = name },
                })
                HDG.Log:Info("styles_action", "Created style: " .. name)
            end,
        })
    end)

    HDG.UI.OnClick(rootFrame, "stylesPanel.curatorClearSelection", function()
        HDG.Store:Dispatch({
            type = HDG.Constants.ACTIONS.STYLES_CURATOR_CLEAR_SELECT,
        })
    end)
    HDG.UI.OnClick(rootFrame, "stylesPanel.curatorUndoBtn", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_CURATOR_UNDO })
        HDG.Log:Info("styles_action", "Undid last move")
    end)

    -- ===== Smart Set Builder =====
    HDG.UI.OnClick(rootFrame, "stylesPanel.smartsetCancel", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_SMARTSET_CANCEL })
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_SET_VIEW,
            payload = { view = "landing" },
        })
    end)

    HDG.UI.OnClick(rootFrame, "stylesPanel.smartsetSave", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_SMARTSET_SAVE })
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_SET_VIEW,
            payload = { view = "landing" },
        })
        HDG.Log:Info("styles_action", "Saved smart set")
    end)

    HDG.UI.OnClick(rootFrame, "stylesPanel.smartsetClear", function()
        -- Confirm before discarding accumulated rules. When the draft has
        -- no rules yet the dispatch is a no-op anyway, so skip the prompt.
        local state = HDG.Store:GetState()  -- exception(false-positive): OnClick handler, not a row factory
        local hasRules = false
        for _, axisTags in pairs(state.session.ui.styles.smartset.rules) do
            for _ in pairs(axisTags) do hasRules = true; break end
            if hasRules then break end
        end
        if not hasRules then return end
        HDG.UI.Confirm({
            id       = "HDGR_SMARTSET_CLEAR",
            text     = "Discard all rules for this smart set?",
            accept   = "Clear",
            cancel   = "Keep",
            onAccept = function()
                HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_SMARTSET_CLEAR_ALL })
            end,
        })
    end)

    -- Severity chips: each dispatches STYLES_SMARTSET_SET_SEVERITY_TAB.
    local SEVERITY_CHIPS = { "all", "signature", "accent", "versatile", "clashing" }
    for _, value in ipairs(SEVERITY_CHIPS) do
        local v = value
        HDG.UI.OnClick(rootFrame, "stylesPanel.smartsetSeverity_" .. v, function()
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_SMARTSET_SET_SEVERITY_TAB,
                payload = { sev = v },
            })
        end)
    end

    -- Name/description editboxes: dispatch STYLES_SMARTSET_SET_FIELD.
    local function wireField(widgetId, fieldName)
        HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, widgetId), function(text)
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_SMARTSET_SET_FIELD,
                payload = { field = fieldName, value = text },
            })
        end)
    end
    wireField("stylesPanel.smartsetNameEdit", "displayName")
    wireField("stylesPanel.smartsetDescEdit", "description")

    -- ===== Snapshot + Import =====
    HDG.UI.OnClick(rootFrame, "stylesPanel.saveSnapshot", function()
        -- Scan catalog for placed items (numPlaced>0). Only taint-safe full-placed-decor
        -- path (GetAllPlacedDecor / editor hooks taint). Reducer stays pure.
        local items = {}
        HDG.HousingCatalogObserver:IterateRows(function(itemID, row)
            if (row.numPlaced or 0) > 0 then items[#items + 1] = itemID end  -- exception(boundary): catalog struct field sparse
        end)
        if #items == 0 then
            HDG.Log:Warn("styles_action", "Save Placed Decor: nothing placed (or catalog not ready)")
            return
        end
        local ts = HDG.ControllerHelpers.Mechanics.Now()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_SNAPSHOT_PLACED,
            payload = { items = items, takenAt = ts,
                        displayName = "Placed Decor - " .. ((date and date("%b %d %H:%M", ts)) or tostring(ts)) } })  -- exception(boundary): date()
        HDG.Log:Info("styles_action", "Saved placed-decor snapshot (" .. #items .. " items)")
    end)

    HDG.UI.OnClick(rootFrame, "stylesPanel.openImport", function()
        -- One action sets the Styles tab + import sub-view + clean slate (same as Tools > Import).
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_OPEN_IMPORT })
    end)

    HDG.UI.OnClick(rootFrame, "stylesPanel.importBack", function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.STYLES_SET_VIEW,
            payload = { view = "landing" },
        })
    end)
    HDG.UI.OnClick(rootFrame, "stylesPanel.importReset", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_IMPORT_RESET })
    end)
    HDG.UI.OnClick(rootFrame, "stylesPanel.importCommit", function()
        local A    = HDG.Constants.ACTIONS
        local imp  = HDG.Store:GetState().session.ui.styles.import  -- exception(false-positive): top-level commit handler reads view-global import state, not a row factory
        local dest = imp.destination
        -- Default destination is "style" (My Styles); see the import factory + radio.
        local commit = (dest == "set"      and A.STYLES_IMPORT_COMMIT_AS_SET)
                    or (dest == "shopping" and A.STYLES_IMPORT_COMMIT)
                    or A.STYLES_IMPORT_COMMIT_AS_STYLE
        -- Snapshot count + name BEFORE committing -- the commit reducer resets import state.
        local count    = #(imp.previewItems or {})
        local destName = (dest == "set" and "Project Sets")
                      or (dest == "shopping" and "Shopping List")
                      or "My Styles"
        local name     = imp.parseDisplayName
        HDG.Store:Dispatch({ type = commit })
        if dest == "set" then
            -- Project Sets live in Projects -- jump there so the user sees the new set.
            HDG.Store:Dispatch({ type = A.UI_SET_PERSISTENT, payload = { key = "view", value = "projectsLanding" } })
        else
            HDG.Store:Dispatch({ type = A.STYLES_SET_VIEW, payload = { view = "landing" } })
        end
        -- styles_action is a user-tag -> this toasts the status rail for ~2s (ADR-013).
        if name and name ~= "" then
            HDG.Log:Info("styles_action", ("Imported \"%s\" to %s (%d items)"):format(name, destName, count))
        else
            HDG.Log:Info("styles_action", ("Imported %d items to %s"):format(count, destName))
        end
    end)

    -- URL editbox: captures the text and auto-parses it (no separate Parse step).
    -- userInput guard skips the binding's own SetText echo, so no feedback loop.
    HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, "stylesPanel.importUrlEdit"), function(text)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_IMPORT_SET_URL, payload = { text = text } })
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_IMPORT_PARSE })
    end)


    -- Title editbox: player can rename the parsed build before importing.
    -- userInput guard skips the binding's own SetText echo (parser-seeded value).
    local titleBox = HDG.UI.W(rootFrame, "stylesPanel.importTitleEdit")
    if titleBox and titleBox.SetScript then
        titleBox:SetScript("OnTextChanged", function(self_, userInput)
            if not userInput then return end
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.STYLES_IMPORT_SET_TITLE,
                payload = { text = (self_.GetText and self_:GetText()) or "" },
            })
        end)
    end

    -- ===== Export surface =====
    HDG.UI.OnClick(rootFrame, "stylesPanel.openExport", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_OPEN_EXPORT })
    end)
    HDG.UI.OnClick(rootFrame, "stylesPanel.exportBack", function()
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_SET_VIEW, payload = { view = "landing" } })
    end)
    -- Copy: WoW can't write the clipboard, so focus + highlight all and the user
    -- hits Ctrl+C (same trick as the shared CopyDialog).
    HDG.UI.OnClick(rootFrame, "stylesPanel.exportCopy", function()
        local codeBox = HDG.UI.W(rootFrame, "stylesPanel.exportCode")
        codeBox:SetFocus()
        if codeBox.EditBox then codeBox.EditBox:HighlightText() end  -- exception(boundary): inner EditBox absent in mock template
    end)
    -- Search editbox: dispatch SET_SEARCH on user input (userInput guard skips
    -- the binding's own SetText echo).
    HDG.UI.WireTextChanged(HDG.UI.W(rootFrame, "stylesPanel.exportSearch"), function(text)
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.STYLES_EXPORT_SET_SEARCH, payload = { text = text } })
    end)
    -- Code box: highlight-all on focus so Ctrl+C grabs everything.
    local exportCode = HDG.UI.W(rootFrame, "stylesPanel.exportCode")
    if exportCode and exportCode.EditBox then
        exportCode.EditBox:SetScript("OnEditFocusGained", function(self_) self_:HighlightText() end)
    end
    -- URL box (single-line): highlight-all on focus so the link is one Ctrl+C away.
    local exportUrl = HDG.UI.W(rootFrame, "stylesPanel.exportUrl")
    if exportUrl and exportUrl.SetScript then
        exportUrl:SetScript("OnEditFocusGained", function(self_) self_:HighlightText() end)
    end
end

function StylesController:Refresh(rootFrame, ctx)
    -- Chip strips are binding-engine-driven. Export code box is imperative
    -- (codecs + observer are non-store singletons) -- recompute on rebind.
    _refreshExportCode(rootFrame)
end

HDG.Controllers:Register("styles", StylesController)
