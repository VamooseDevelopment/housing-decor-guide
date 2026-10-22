-- HDGR_Controller_Blueprints.lua
-- ============================================================================
-- Thin glue for the Blueprints tab: Wire() attaches behavior to the
-- LayoutConfig-declared frames; row factories render the collection + content
-- scrollboxes. No chrome creation here.

HDG = HDG or {}
HDG.Controller_Blueprints = HDG.Controller_Blueprints or {}
local C = HDG.Controller_Blueprints
local A = HDG.Constants.ACTIONS

-- ===== Shared helpers ========================================================

local function _selectedCode()
    return HDG.Store:GetState().session.blueprints.selectedCode  -- exception(false-positive): top-level controller read, not a row factory
end

-- The game's own blueprint-name limits, read from the client rather than
-- guessed. Live 12.1 is 3..50 (Constants.HousingConsts, probed 2026-09-11);
-- HDG's save dialog used to allow 64, so a longer name reached the server and
-- came back as HousingResult 8 "Invalid Blueprint name" with nothing on screen
-- to say which rule it broke.
-- The fields are live on 12.1 but absent from the LS stubs (pinned at 12.0.7),
-- hence the suppressions -- delete them when the stub set regenerates. Same
-- pair as Modules/HDGR_BlueprintObserver.lua's cap read.
---@diagnostic disable-next-line: undefined-field
local function _nameMax() return _G.Constants.HousingConsts.BlueprintNameMaxCharacters end  -- exception(boundary): Blizzard constants table
---@diagnostic disable-next-line: undefined-field
local function _nameMin() return _G.Constants.HousingConsts.BlueprintNameMinCharacters end  -- exception(boundary): Blizzard constants table

local function _targetHouse()
    return HDG.Store:GetState().session.blueprints.targetHouseGUID  -- exception(false-positive): top-level controller read, not a row factory
end

-- The name the two name boxes show and _CommitName edits: the Blizzard catalog
-- name for an own blueprint, the HDG label for a pasted code. ONE reader, so
-- the box, the Escape restore and the commit can never resolve a different
-- entry than the strip's name label and remove verb do.
local function _shownName()
    local entry = HDG.Selectors:Call("blueprints.selectedEntry", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read, not a row factory
    return (entry and (entry.isOwn and entry.name or entry.label)) or ""  -- exception(nullable): nothing selected / unlabelled paste
end

-- Select a code and fetch its manifest unless a FRESH one is already cached OR
-- one is already in flight (design's in-flight dedupe: re-firing a pending
-- request resets requestedAt, silently postponing the escalation copy and the
-- timeout sweep). Failed manifests re-request, and so do received ones the
-- storage observer has marked stale -- selecting a row is the fetch moment,
-- so a manifest fetched before a shopping trip cannot outlive the trip.
local function _selectAndFetch(shareCode)
    HDG.Store:Dispatch({ type = A.BLUEPRINT_SELECT, payload = { shareCode = shareCode } })
    local m = HDG.Store:GetState().session.blueprints.manifests[shareCode]  -- exception(false-positive): top-level controller read
    local fresh = m and (m.status == "pending" or (m.status == "received" and not m.stale))
    if not fresh then
        HDG.BlueprintObserver:RequestContents(shareCode, _targetHouse())
    end
end

-- The Refresh button: re-ask the server for the SELECTED manifest. Lit only
-- while that manifest is stale (LayoutConfig `enabled` binding), so the
-- click never races an in-flight request.
function C:_RefreshManifest()
    local code = _selectedCode()
    if code then HDG.BlueprintObserver:RequestContents(code, _targetHouse()) end
end

-- Library mode (design 2026-09-11): a session-only sub-view; the picker and
-- inspector panels hide and the library panel shows (LayoutConfig `visible`).
function C:_OpenLibrary()
    HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT, payload = { view = "blueprints", key = "subView", value = "library" } })
end
function C:_CloseLibrary()
    HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT, payload = { view = "blueprints", key = "subView", value = "inspect" } })
    -- Drop the clicked-row pin on the way out. The picker selects by CODE and
    -- has no second row to disambiguate, so a pin left behind would outlive the
    -- only screen that can set it.
    HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT, payload = { view = "blueprints", key = "librarySelectedKey", value = nil } })
end

-- Inspect from the Library: fetch the selected code's manifest (cached ones
-- don't re-request) and return to the picker; the selection is shared state,
-- so the picker reveals the row and the inspector fills.
function C:_InspectFromLibrary()
    local code = _selectedCode()
    if code then _selectAndFetch(code) end  -- exception(nullable): nothing selected
    self:_CloseLibrary()
end

-- Remove the selected entry the way its source allows: pasted -> forget (HDG
-- state only), own catalog -> delete (Blizzard catalog), backup -> nothing.
-- Both confirms are the existing ones. The source comes from libraryDetail,
-- which follows the row the player clicked -- the same code can sit in both
-- populations, and the two rows do NOT mean the same thing here.
function C:_RemoveSelected()
    local d = HDG.Selectors:Call("blueprints.libraryDetail", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read, not a row factory
    if not d or d.src == "backup" then return end  -- exception(nullable): no selection / read-only backup
    if d.src == "pasted" then
        self:_ConfirmForget(d.shareCode, d.name)
    else
        self:_ConfirmDelete(d.blueprintID, d.name)
    end
end

-- ===== Row factory: blueprintCollectionRow ==================================
-- Three shapes (ed.kind): "fold" section fold row (glyph + label + count + cap
-- text, click toggles the section) / "header" group label / "row" blueprint
-- entry with selected chrome, AUTO/type tag, and a remove `x` on pasted rows
-- (Forget) and own manual catalog rows (Delete). Both confirm.
-- SAFETY: Forget dispatches BLUEPRINT_FORGET (HDG-state-only) -- it never
-- touches Blizzard's blueprint catalog; Delete is the real catalog delete.

local function _layoutCollectionRow(row)
    HDG.UI:EnsureRowChrome(row)
    local headerFs = HDG.UI.RowText(row, "caption", "TextStatus", "LEFT")
    headerFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    headerFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    headerFs:SetWordWrap(false)   -- long names truncate, never wrap into the next row
    row._headerFs = headerFs

    local forgetBtn = CreateFrame("Button", nil, row)
    forgetBtn:SetSize(16, 16)
    forgetBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    local x = HDG.UI.RowText(forgetBtn, "body", "TextDim", "CENTER")
    x:SetAllPoints()
    x:SetText("x")
    forgetBtn._x = x
    forgetBtn:SetAlpha(0.4)  -- quiet until hovered; always present on pasted rows (visible affordance)
    forgetBtn:SetScript("OnEnter", function(self) self:SetAlpha(1) end)
    forgetBtn:SetScript("OnLeave", function(self) self:SetAlpha(0.4) end)
    -- Hover tooltip names WHICH remove this is BEFORE the click: catalog rows
    -- delete permanently, pasted rows forget the code (UX review #4).
    -- Attach hooks (doesn't clobber the alpha scripts above).
    HDG.TooltipEngine:Attach(forgetBtn, function(self)
        if self._deleteBID then
            return { title = HDG.Locale:Get("TIP_BP_DELETE_TITLE"), body = HDG.Locale:Get("TIP_BP_DELETE_BODY") }
        end
        return { title = HDG.Locale:Get("TIP_BP_FORGET_TITLE"), body = HDG.Locale:Get("TIP_BP_FORGET_BODY") }
    end)
    forgetBtn:SetScript("OnClick", function(self)
        if self._deleteBID then
            HDG.Controller_Blueprints:_ConfirmDelete(self._deleteBID, self._rowName)
        elseif self._shareCode then
            HDG.Controller_Blueprints:_ConfirmForget(self._shareCode, self._rowName)
        end
    end)
    row._forgetBtn = forgetBtn

    local tagFs = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    tagFs:SetPoint("RIGHT", forgetBtn, "LEFT", -4, 0)
    tagFs:SetWordWrap(false)
    row._tagFs = tagFs

    local nameFs = HDG.UI.RowText(row, "body", "Text", "LEFT")
    nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    nameFs:SetPoint("RIGHT", tagFs, "LEFT", -4, 0)
    nameFs:SetWordWrap(false)
    row._nameFs = nameFs

    row._laidOut = true
end

local function _paintCollectionRow(row, ed)
    if ed.kind == "fold" then
        -- Section fold row: "- Pasted codes  (4)" with the cap text right-aligned
        -- ("no limit" / "48 slots free", warning tone near the cap). Same glyph
        -- idiom as the content-group headers beside it.
        row._nameFs:Hide()
        row._forgetBtn:Hide()
        row._headerFs:Show()
        row._tagFs:Show()
        local count = ed.countMax and (ed.count .. " / " .. ed.countMax) or tostring(ed.count)
        row._headerFs:SetText(HDG.UI.CollapsePrefix(ed.collapsed) .. ed.label .. "  (" .. count .. ")")
        row._tagFs:SetText(ed.capText)
        HDG.Theme:Register(row._tagFs, ed.capWarn and "TextWarning" or "TextDim")
        HDG.Theme:Register(row._headerFs, "TextStatus")  -- a pooled frame can arrive from a warning group header
        HDG.Theme:Register(row, "RowChrome", { header = true })
    elseif ed.kind == "header" then
        row._headerFs:Show()
        row._nameFs:Hide()
        row._tagFs:Hide()
        row._forgetBtn:Hide()
        row._headerFs:SetText(ed.label)
        -- ed.warn is unused today (the auto-save cap is no longer shown); the
        -- carries the tone, so the role is re-registered either way -- a pooled
        -- frame that last painted a full Backups header must not keep the
        -- warning on a plain group name.
        HDG.Theme:Register(row._headerFs, ed.warn and "TextWarning" or "TextStatus")
        HDG.Theme:Register(row, "RowChrome", { header = true })
    else
        row._headerFs:Hide()
        row._nameFs:Show()
        row._tagFs:Show()
        row._nameFs:SetText(ed.name)
        -- Faction tint (House/Exterior blueprints, once inspected): Alliance-blue
        -- / Horde-red name; everything else keeps the default text color.
        HDG.Theme:Register(row._nameFs,
            (ed.faction == "Alliance" and "TextAlliance")
            or (ed.faction == "Horde" and "TextHorde") or "Text")
        row._tagFs:SetText(ed.isAuto and "AUTO" or (ed.typeLabel or (ed.isPasted and "shared" or "")))
        HDG.Theme:Register(row._tagFs, "TextDim")  -- a pooled frame can arrive from a fold row wearing TextWarning
        -- Row remove `x`: pasted rows FORGET (HDG-list-only); own MANUAL
        -- blueprints DELETE from the catalog. Both confirm -- the dialog names
        -- the row, so the name is stamped for either kind.
        -- Auto-backups are read-only, so they get no `x`.
        local canForget = ed.isPasted == true
        local canDelete = (not ed.isPasted) and ed.blueprintID ~= nil and ed.isAuto ~= true
        row._forgetBtn:SetShown(canForget or canDelete)
        row._forgetBtn._shareCode  = canForget and ed.shareCode or nil
        row._forgetBtn._deleteBID  = canDelete and ed.blueprintID or nil
        row._forgetBtn._rowName    = ed.name
        HDG.Theme:Register(row, "RowChrome", { selected = ed.isSelected })
    end
    row._edKind    = ed.kind
    row._shareCode = ed.shareCode
    row._section   = ed.section
end

local function _wireCollectionRow(row)
    row:SetScript("OnClick", function(self)
        if self._edKind == "fold" then
            HDG.Store:Dispatch({ type = A.BLUEPRINT_TOGGLE_SECTION, payload = { section = self._section } })
            return
        end
        if self._edKind ~= "row" or not self._shareCode then return end
        _selectAndFetch(self._shareCode)
    end)
end

local function _resetCollectionRow(row)
    HDG.UI.ClearRowText(row, "_headerFs", "_nameFs", "_tagFs")
    row._forgetBtn:Hide()
    row._forgetBtn._shareCode, row._forgetBtn._deleteBID, row._forgetBtn._rowName = nil, nil, nil
    row._edKind, row._shareCode, row._section = nil, nil, nil
end

local function _collectionRowFactory(_def)
    return {
        Configure = function(rowFrame, ed)
            if not rowFrame._laidOut then _layoutCollectionRow(rowFrame) end
            _paintCollectionRow(rowFrame, ed)
            _wireCollectionRow(rowFrame)
        end,
        Reset = function(rowFrame) _resetCollectionRow(rowFrame) end,
    }
end

HDG.Rows:Register("blueprintCollectionRow", {
    font = "body", height = 24,
    factory = _collectionRowFactory,
    key = function(ed)
        -- Keys use the INTERNAL identity, not the shareCode: the same code can
        -- legitimately appear as a pasted row AND an own-collection row (both
        -- are real entries; PTR key-collision 2026-07-12). Collection rows key
        -- on blueprintID (unique numeric); pasted rows on the code.
        if not ed then return "bpColl:?" end
        -- Fold + header rows carry no shareCode/blueprintID; they must not fall
        -- through to "bpColl:nil" and collide with each other.
        if ed.kind == "fold" then return "bpCollFold:" .. tostring(ed.section) end
        if ed.kind == "header" then return "bpCollHdr:" .. tostring(ed.label) end
        if ed.isPasted then return "bpPasted:" .. tostring(ed.shareCode) end
        return "bpColl:" .. tostring(ed.blueprintID or ed.shareCode)  -- exception(nullable): blueprintID nil on pre-68569 rows
    end,
})

-- ===== Row factory: blueprintLibraryRow =====================================
-- One flat row per entry: name | source | type | date | note | x. Column
-- x-offsets come from HDG.Constants.BLUEPRINT_LIBRARY_COLUMNS (the header
-- buttons use the same widths, gap "sm" = 4) so the text lines up under its
-- header.
local LIB_COL_X = {}
do
    local x = 8
    for _, c in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_COLUMNS) do
        LIB_COL_X[c.col] = { x = x, w = c.width - 8 }
        x = x + c.width + 4
    end
end
local LIB_SRC_ROLE = { pasted = "TextInfo", mine = "TextSuccess", backup = "TextDim" }

-- One line of the note for the table cell. A note is free text and may carry
-- newlines, which a single-line FontString renders as a break that bursts the
-- 22px row -- so collapse every run of whitespace. The detail strip below shows
-- the note in full.
local function _notePreview(note)
    return HDG.Format.Trim((note:gsub("%s+", " ")))
end

local function _layoutLibraryRow(row)
    HDG.UI:EnsureRowChrome(row)
    local function col(name, fontRole, textRole)
        local fs = HDG.UI.RowText(row, fontRole, textRole, "LEFT")
        fs:SetPoint("LEFT", row, "LEFT", LIB_COL_X[name].x, 0)
        fs:SetWidth(LIB_COL_X[name].w)
        fs:SetWordWrap(false)
        return fs
    end
    row._nameFs    = col("name",    "body",    "Text")
    row._srcFs     = col("source",  "caption", "TextDim")
    row._typeFs    = col("type",    "small",   "TextMuted")
    row._dateFs    = col("date",    "small",   "TextDim")
    row._noteFs    = col("note",    "small",   "TextMuted")
    local removeBtn = CreateFrame("Button", nil, row)
    removeBtn:SetSize(16, 16)
    removeBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    local x = HDG.UI.RowText(removeBtn, "body", "TextDim", "CENTER")
    x:SetAllPoints()
    x:SetText("x")
    removeBtn:SetAlpha(0.4)  -- quiet until hovered; always present on removable rows (visible affordance)
    removeBtn:SetScript("OnEnter", function(self) self:SetAlpha(1) end)
    removeBtn:SetScript("OnLeave", function(self) self:SetAlpha(0.4) end)
    -- The row `x` acts on THIS ROW's source, never through the detail strip: an
    -- own blueprint pasted back in renders two rows for one code, and reading
    -- the verb off the selection would offer Delete on the pasted one.
    removeBtn:SetScript("OnClick", function(self)
        if self._src == "pasted" then
            HDG.Controller_Blueprints:_ConfirmForget(self._shareCode, self._name)
        elseif self._src == "mine" then
            HDG.Controller_Blueprints:_ConfirmDelete(self._blueprintID, self._name)
        end
    end)
    row._removeBtn = removeBtn
    row._laidOut = true
end

local function _paintLibraryRow(row, ed)
    row._nameFs:SetText(ed.name)
    HDG.UI.applyFontRole(row._nameFs, ed.hasLabel and "body" or "small")
    HDG.Theme:Register(row._nameFs,
        (ed.faction == "Alliance" and "TextAlliance") or (ed.faction == "Horde" and "TextHorde")
        or (ed.hasLabel and "Text" or "TextDim"))
    row._srcFs:SetText(ed.srcLabel)
    HDG.Theme:Register(row._srcFs, LIB_SRC_ROLE[ed.src])
    row._typeFs:SetText(ed.typeLabel or "")  -- exception(nullable): pre-stamp pastes have no type
    row._dateFs:SetText(HDG.Format.ShortDate(ed.date) or "--")  -- exception(nullable): undated paste; the strip's meta line says pasted/saved
    -- Blank, not "--": an absent note is nothing to report, where an undated
    -- paste (the "--" above) is a fact we genuinely do not have.
    row._noteFs:SetText(_notePreview(ed.note))
    -- Same rule as blueprints.libraryCanRemove, which gates the strip's button:
    -- backups are read-only, and a catalog row with no id has nothing to delete BY.
    row._removeBtn:SetShown(ed.src == "pasted" or (ed.src == "mine" and ed.blueprintID ~= nil))  -- exception(nullable): blueprintID nil on pre-68569 catalog rows
    row._removeBtn._shareCode   = ed.shareCode
    row._removeBtn._src         = ed.src
    row._removeBtn._blueprintID = ed.blueprintID  -- exception(nullable): pasted rows carry no catalog id
    row._removeBtn._name        = ed.name
    HDG.Theme:Register(row, "RowChrome", { selected = ed.isSelected })
    row._shareCode = ed.shareCode
    row._entryKey  = ed.key
end

-- Clicking a row selects its CODE (shared with the picker and inspector) and
-- pins WHICH of that code's rows the detail strip follows -- the two are
-- different facts whenever a code sits in both populations.
local function _selectLibraryRow(row)
    HDG.Store:Dispatch({ type = A.BLUEPRINT_SELECT, payload = { shareCode = row._shareCode } })
    HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
        payload = { view = "blueprints", key = "librarySelectedKey", value = row._entryKey } })
end

local function _wireLibraryRow(row)
    row:SetScript("OnClick", function(self) _selectLibraryRow(self) end)
    row:SetScript("OnDoubleClick", function(self)
        _selectLibraryRow(self)
        HDG.Controller_Blueprints:_InspectFromLibrary()
    end)
end

local function _resetLibraryRow(row)
    HDG.UI.ClearRowText(row, "_nameFs", "_srcFs", "_typeFs", "_dateFs", "_noteFs")
    row._removeBtn:Hide()
    row._removeBtn._shareCode, row._removeBtn._src = nil, nil
    row._removeBtn._blueprintID, row._removeBtn._name = nil, nil
    row._shareCode, row._entryKey = nil, nil
end

local function _libraryRowFactory(_def)
    return {
        Configure = function(rowFrame, ed)
            if not rowFrame._laidOut then _layoutLibraryRow(rowFrame) end
            _paintLibraryRow(rowFrame, ed)
            _wireLibraryRow(rowFrame)
        end,
        Reset = function(rowFrame) _resetLibraryRow(rowFrame) end,
    }
end

HDG.Rows:Register("blueprintLibraryRow", {
    font = "body", height = 22,
    factory = _libraryRowFactory,
    key = function(ed) return "bpLib:" .. ed.key end,
})

-- ===== Row factory: blueprintContentRow =====================================
-- Two shapes (ed.kind): "header" collapsible group bar / "item" manifest entry
-- (name | have/total | need-badge | source chip). Chip colors come from the
-- existing SOURCE_KINDS system via Format.SourceChip -- no new roles.

local function _toggleGroupCollapse(ct)
    -- Immutable copy-update: never mutate the table a selector handed out.
    local cur = HDG.Store:GetState().session.ui.blueprints.collapsedGroups  -- exception(false-positive): top-level controller read
    local next_ = {}
    for k, v in pairs(cur) do next_[k] = v end
    next_[ct] = not next_[ct] or nil
    HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
        payload = { view = "blueprints", key = "collapsedGroups", value = next_ } })
end

local function _layoutContentRow(row)
    HDG.UI:EnsureRowChrome(row)
    local headerFs = HDG.UI.RowText(row, "body", "TextStatus", "LEFT")
    headerFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    headerFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    headerFs:SetWordWrap(false)   -- long names truncate, never wrap into the next row
    row._headerFs = headerFs

    local chipFs = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    chipFs:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    chipFs:SetWidth(190)
    chipFs:SetWordWrap(false)
    row._chipFs = chipFs

    local needFs = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    needFs:SetPoint("RIGHT", chipFs, "LEFT", -6, 0)
    needFs:SetWidth(52)
    needFs:SetWordWrap(false)
    row._needFs = needFs

    -- 56 fits a four-figure build total ("1043/1128"): one captured
    -- blueprint used 1128 dyes.
    local ownFs = HDG.UI.RowText(row, "caption", "TextDim", "RIGHT")
    ownFs:SetPoint("RIGHT", needFs, "LEFT", -6, 0)
    ownFs:SetWidth(56)
    ownFs:SetWordWrap(false)
    row._ownFs = ownFs

    local nameFs = HDG.UI.RowText(row, "body", "Text", "LEFT")
    nameFs:SetPoint("LEFT", row, "LEFT", 16, 0)
    nameFs:SetPoint("RIGHT", ownFs, "LEFT", -4, 0)
    nameFs:SetWordWrap(false)
    row._nameFs = nameFs

    -- Attached once per pooled frame; the recipe reads the ed stamped on paint,
    -- so a re-acquired row can never show the previous entry's hover.
    HDG.TooltipEngine:Attach(row, HDG.TooltipRecipes.BlueprintEntry)

    row._laidOut = true
end

local function _paintContentRow(row, ed)
    if ed.kind == "header" then
        row._headerFs:Show()
        row._nameFs:Hide(); row._ownFs:Hide(); row._needFs:Hide(); row._chipFs:Hide()
        -- Entry count + piece sum, same shape as the counts label above the list.
        local suffix = (ed.missing > 0)
            and ("  --  %d missing (%d piece%s)"):format(ed.missing, ed.missingPieces, ed.missingPieces == 1 and "" or "s")
            or ""
        row._headerFs:SetText(HDG.UI.CollapsePrefix(ed.collapsed) .. ed.label .. "  (" .. ed.count .. ")" .. suffix)
        -- Headers carrying missing items escalate so a scroll down the group
        -- bars alone shows where the gaps are (UX review #12).
        HDG.Theme:Register(row._headerFs, (ed.missing > 0) and "TextWarning" or "TextStatus")
        HDG.Theme:Register(row, "RowChrome", { header = true })
    else
        row._headerFs:Hide()
        row._nameFs:Show(); row._ownFs:Show(); row._needFs:Show(); row._chipFs:Show()
        row._nameFs:SetText(ed.name)
        HDG.Theme:Register(row._nameFs, ed.invalid and "TextError" or (ed.need > 0 and "Text" or "TextDim"))
        row._ownFs:SetText(ed.have .. "/" .. ed.total)
        if ed.need > 0 then
            row._needFs:SetText("need " .. ed.need)
            HDG.Theme:Register(row._needFs, "TextWarning")
        else
            -- Owned: the same green check the Decor/Acquire collected marks use.
            row._needFs:SetText("|A:common-icon-checkmark:12:12|a")
            HDG.Theme:Register(row._needFs, "TextDim")
        end
        if ed.srcKind then
            row._chipFs:SetText(HDG.Format.SourceChip(ed.srcKind, ed.need == 0) .. " " .. (ed.srcName or ""))
        elseif ed.need > 0 and ed.itemID then
            row._chipFs:SetText("resolves at vendor")
        else
            row._chipFs:SetText("")
        end
        HDG.Theme:Register(row, "RowChrome", {})
    end
    row._edKind = ed.kind
    row._ct     = ed.ct
    row._tipEd  = (ed.kind == "item") and ed or nil
end

local function _wireContentRow(row)
    -- OnClick only: hover belongs to the TooltipEngine hooks from layout, and a
    -- SetScript("OnEnter") here would wipe them on every repaint.
    row:SetScript("OnClick", function(self)
        if self._edKind == "header" and self._ct then _toggleGroupCollapse(self._ct) end
    end)
end

local function _resetContentRow(row)
    HDG.UI.ClearRowText(row, "_headerFs", "_nameFs", "_ownFs", "_needFs", "_chipFs")
    row._edKind, row._ct, row._tipEd = nil, nil, nil
end

local function _contentRowFactory(_def)
    return {
        Configure = function(rowFrame, ed)
            if not rowFrame._laidOut then _layoutContentRow(rowFrame) end
            _paintContentRow(rowFrame, ed)
            _wireContentRow(rowFrame)
        end,
        Reset = function(rowFrame) _resetContentRow(rowFrame) end,
    }
end

HDG.Rows:Register("blueprintContentRow", {
    font = "body", height = 22,
    factory = _contentRowFactory,
    key = function(ed)
        if not ed then return "bpRow:?" end
        if ed.kind == "header" then return "bpHdr:" .. tostring(ed.ct) end
        return "bpItem:" .. tostring(ed.ct) .. ":" .. tostring(ed.name)
    end,
})

-- ===== Paste flow ============================================================
-- Structure check via the observer's sync wrapper (controllers never touch
-- C_HousingBlueprint); a structurally-valid code then goes through the normal
-- select+fetch path. pasteError drives the inline field state.

-- Returns true when the code was accepted, so the caller can empty the box:
-- the code now lives in the collection and leaving it behind meant the next
-- paste appended to it (Soul, 2026-09-15). A rejected code stays put so it
-- can be corrected next to the error line.
function C:_SubmitPaste(text)
    local code = HDG.Format.Trim(text)
    if code == "" then return false end
    if not HDG.BlueprintObserver:IsShareCodeValid(code) then
        HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
            payload = { view = "blueprints", key = "pasteError", value = true } })
        return false
    end
    HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
        payload = { view = "blueprints", key = "pasteError", value = false } })
    HDG.Store:Dispatch({ type = A.BLUEPRINT_PASTE_ADD, payload = {
        shareCode = code,
        blueprintType = HDG.BlueprintObserver:GetBlueprintTypeForCode(code),
        pastedAt = HDG.ControllerHelpers.Mechanics.Now(),  -- exception(boundary): time()
    } })
    _selectAndFetch(code)
    return true
end

-- Target-house change (picker dispatch) -> re-fetch the selected code against
-- the new target. Named method so the seam is directly testable.
function C:_OnTargetChanged()
    local code = _selectedCode()
    if code then
        HDG.BlueprintObserver:RequestContents(code, _targetHouse())
    end
end

-- Library mode wiring: header search, chips, sort headers, detail actions.
function C:_wireLibrary(root)
    HDG.UI.WireSearchBox(root, "blueprintsLibraryPanel.search", "blueprints", "libraryQuery")
    HDG.UI.OnClick(root, "blueprintsLibraryPanel.backBtn", function() C:_CloseLibrary() end)
    for _, chip in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_CHIPS) do
        local value = chip.value
        HDG.UI.OnClick(root, "blueprintsLibraryPanel.chip_" .. value, function()
            HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT, payload = { view = "blueprints", key = "libraryChip", value = value } })
        end)
    end
    for _, c in ipairs(HDG.Constants.BLUEPRINT_LIBRARY_COLUMNS) do
        local col = c.col
        HDG.UI.OnClick(root, "blueprintsLibraryPanel.col_" .. col, function()
            HDG.Store:Dispatch({ type = A.BLUEPRINT_LIBRARY_SET_SORT, payload = { col = col } })
        end)
    end
    HDG.UI.OnClick(root, "blueprintsLibraryPanel.hideBackups", function()
        local hide = HDG.Selectors:Call("blueprints.libraryHideBackups", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read, not a row factory
        HDG.Store:Dispatch({ type = A.BLUEPRINT_SET_HIDE_BACKUPS, payload = { hide = not hide } })
    end)
    -- The code itself is the copy affordance -- no separate Copy button to
    -- crowd the 130px action column. Same contract as the inspector's box:
    -- click selects all, Ctrl+C copies, user edits revert (no clipboard API --
    -- see the inspector's codeBox comment).
    local libCodeBox = HDG.UI.W(root, "blueprintsLibraryPanel.code")
    libCodeBox:HookScript("OnEditFocusGained", function(box) box:HighlightText() end)
    libCodeBox:HookScript("OnTextChanged", function(box, userInput)
        if userInput then
            box:SetText(HDG.Selectors:Call("blueprints.libraryDetailCode", HDG.Store:GetState(), {}))  -- exception(false-positive): top-level controller read, not a row factory
            box:HighlightText()
        end
    end)
    HDG.UI.OnClick(root, "blueprintsLibraryPanel.inspectBtn", function() C:_InspectFromLibrary() end)
    HDG.UI.OnClick(root, "blueprintsLibraryPanel.linkBtn",    function() C:_LinkInChat() end)
    HDG.UI.OnClick(root, "blueprintsLibraryPanel.removeBtn",  function() C:_RemoveSelected() end)
    -- Name box: same commit contract as the inspector's (focus-lost commits
    -- user-typed edits via _CommitName; Escape restores). Text is pushed in
    -- Refresh, never bound, so a re-render cannot clobber typing.
    local nameBox = HDG.UI.W(root, "blueprintsLibraryPanel.nameBox")
    nameBox:HookScript("OnTextChanged", function(box, userInput)
        if userInput then box._dirty = true end
    end)
    nameBox:HookScript("OnEditFocusLost", function(box) C:_CommitName(box) end)
    nameBox:SetScript("OnEscapePressed", function(box)
        box._dirty = nil
        box:SetText(_shownName())
        box:ClearFocus()
    end)
    -- Note box: bound text in, user edits out. WireNoteBox keys its race guard
    -- on THIS container -- the frame the binding calls SetText on -- so an edit
    -- arriving while the box still holds the previous code's text is dropped
    -- rather than saved onto the newly selected code.
    HDG.ControllerHelpers.Mechanics.WireNoteBox(
        HDG.UI.W(root, "blueprintsLibraryPanel.noteBox"),
        _selectedCode, "shareCode", "BLUEPRINT_CLEAR_NOTE", "BLUEPRINT_SET_NOTE")
end

-- ===== Controller contract ===================================================

function C:Wire(root)
    self.root = root

    -- One collection request per session, not per re-mount.
    if not self._collectionRequested then
        self._collectionRequested = true
        HDG.BlueprintObserver:RequestCollection()
    end

    -- Paste: Enter in the box or the Inspect button.
    local pasteBox = HDG.UI.W(root, "blueprintsListPanel.pasteBox")
    pasteBox:SetScript("OnEnterPressed", function(box)
        if C:_SubmitPaste(box:GetText()) then box:SetText("") end
        box:ClearFocus()
    end)
    HDG.UI.OnClick(root, "blueprintsListPanel.inspectBtn", function()
        if C:_SubmitPaste(pasteBox:GetText()) then pasteBox:SetText("") end
    end)
    HDG.UI.OnClick(root, "blueprintsDetailPanel.refreshBtn", function() C:_RefreshManifest() end)

    -- House-picker changes re-fetch the selection against the new target.
    if not self._targetSub then
        self._targetSub = true
        HDG.Store:Subscribe(function(_, invalidation)
            if HDG.Paths.MatchesAny({ "session.blueprints.targetHouseGUID" }, invalidation) then
                C:_OnTargetChanged()
            end
        end)
    end

    -- Missing-only segmented pair: explicit value set (not a flip), so both
    -- buttons stay truthful to state via their `active` bindings.
    HDG.UI.OnClick(root, "blueprintsDetailPanel.filterAll", function()
        HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
            payload = { view = "blueprints", key = "missingOnly", value = false } })
    end)
    HDG.UI.OnClick(root, "blueprintsDetailPanel.filterMissing", function()
        HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
            payload = { view = "blueprints", key = "missingOnly", value = true } })
    end)

    -- Name commit: Enter (or focus-out) labels the selected code. Shared codes
    -- arrive nameless; the label is the only persisted blueprint state.
    -- Focus-lost is the ONLY commit path (Enter just clears focus -- committing
    -- in OnEnterPressed double-fired via ClearFocus -> OnEditFocusLost), and it
    -- commits only USER-typed edits (_dirty), so Escape can genuinely cancel.
    -- HookScript, NOT SetScript: the editbox factory already hooked
    -- OnTextChanged/OnEditFocus* for the placeholder overlay + focus ring, and
    -- SetScript wiped that chain (PTR 2026-07-13: "Name this blueprint..."
    -- ghosting under real text). Enter already ClearFocus()es via the factory.
    -- Both name boxes stop at the game's maximum, so an over-long name cannot
    -- be typed at all rather than being refused by the server after the fact.
    for _, id in ipairs({ "blueprintsDetailPanel.nameBox", "blueprintsLibraryPanel.nameBox" }) do
        HDG.UI.W(root, id):SetMaxLetters(_nameMax())
    end

    local nameBox = HDG.UI.W(root, "blueprintsDetailPanel.nameBox")
    nameBox:HookScript("OnTextChanged", function(box, userInput)
        if userInput then box._dirty = true end
    end)
    nameBox:HookScript("OnEditFocusLost", function(box) C:_CommitName(box) end)
    nameBox:SetScript("OnEscapePressed", function(box)
        box._dirty = nil                -- discard the typed edit...
        box:SetText(_shownName())       -- ...and restore the shown name
        box:ClearFocus()
    end)

    -- Share-code box: read-only, click-to-select-all, Ctrl+C to copy. There is
    -- NO addon-callable clipboard API: `CopyToClipboard` is declared
    -- HasRestrictions in OsDocumentation, so an addon calling it -- even from a
    -- click -- takes ADDON_ACTION_FORBIDDEN (live 12.1, 2026-09-11). Blizzard's
    -- own blueprint UI calls it because their code is untainted, which is not a
    -- path we can borrow. Programmatic SetText happens in Refresh; user edits
    -- revert instantly.
    local codeBox = HDG.UI.W(root, "blueprintsDetailPanel.codeBox")
    codeBox:HookScript("OnEditFocusGained", function(box) box:HighlightText() end)  -- hook: keep the factory's focus ring
    codeBox:HookScript("OnTextChanged", function(box, userInput)
        if userInput then
            box:SetText(_selectedCode() or "")
            box:HighlightText()
        end
    end)

    -- Link in chat: insert the blueprint's chat hyperlink (players link builds
    -- like items). Blizzard's own LinkItem pattern -- insert if a chat editbox
    -- is active, else open one prefilled.
    HDG.UI.OnClick(root, "blueprintsListPanel.linkBtn", function() C:_LinkInChat() end)

    -- Import (pasted rows): open Blizzard's Import dialog prefilled with the
    -- code (its preview + confirm own the destructive apply).
    HDG.UI.OnClick(root, "blueprintsDetailPanel.importBtn", function()
        local code = _selectedCode()
        if code then HDG.BlueprintObserver:OpenImport(code) end
    end)

    -- Action row: the four seams.
    HDG.UI.OnClick(root, "blueprintsDetailPanel.routeBtn", function() C:_RouteMissingToShopping() end)
    HDG.UI.OnClick(root, "blueprintsDetailPanel.setBtn", function() C:_ImportAsSet() end)
    HDG.UI.OnClick(root, "blueprintsDetailPanel.architectBtn", function(btn) C:_OpenInArchitect(btn) end)
    HDG.UI.OnClick(root, "blueprintsListPanel.saveBtn", function(btn) C:_SaveBlueprint(btn) end)
    HDG.UI.OnClick(root, "blueprintsListPanel.libraryBtn", function() C:_OpenLibrary() end)
    HDG.UI.OnClick(root, "blueprintsDetailPanel.copyReqsBtn", function() C:_CopyRequirements() end)

    self:_wireLibrary(root)

    if not self._popupsRegistered then
        self._popupsRegistered = true
        HDG.UI:RegisterInputDialog("HDGR_BLUEPRINT_SAVE", {
            text       = "Name this blueprint:",
            accept     = "Save",
            maxLetters = _nameMax(),
            onAccept   = function(value, data)
                if not (value and value ~= "" and data and data.blueprintType) then return end
                HDG.BlueprintObserver:Export(data.blueprintType, value)
            end,
        })
    end
end

-- ===== Seams =================================================================

-- Missing decor+dye entries -> { {itemID, npcID=0, qty}, ... } + a skipped
-- count for catalog misses (no itemID = can't route; surfaces via Log).
function C:_BuildMissingItems()
    local insp = HDG.Selectors:Call("blueprints.inspector", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read
    if not insp or insp.status ~= "received" then return nil end
    local items, skipped = {}, 0
    for _, g in ipairs(insp.groups) do
        if g.ct == 3 or g.ct == 4 then
            for _, it in ipairs(g.items) do
                if it.need > 0 and it.itemID then
                    items[#items + 1] = { itemID = it.itemID, npcID = 0, qty = it.need }
                elseif it.need > 0 then
                    skipped = skipped + 1  -- no itemID: can't route
                end
            end
        end
    end
    return items, skipped
end

-- Route missing -> a NAMED shopping list via the SHOPPING_LIST_IMPORT upsert:
-- identity = "blueprint:<shareCode>" (meta.url), so re-routing the same
-- blueprint refreshes its list in place; name collisions auto-number.
function C:_RouteMissingToShopping()
    local items, skipped = self:_BuildMissingItems()
    if not items then return end
    local code = _selectedCode()
    local name = HDG.Selectors:Call("blueprints.displayName", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read
    local encoded = HDG.ShoppingCodec.Encode({
        name = name, items = items,
        meta = { source = "blueprint", url = "blueprint:" .. code, desc = name },
    })
    HDG.Store:Dispatch({ type = A.SHOPPING_LIST_IMPORT, payload = { encoded = encoded } })
    if skipped > 0 then
        HDG.Log:Info("blueprints", skipped .. " item(s) not in the catalog yet were skipped")
    end
    -- Entries AND pieces, the tab's vocabulary: one routed line may carry six copies.
    local pieces = 0
    for _, it in ipairs(items) do pieces = pieces + it.qty end
    HDG.Log:Info("blueprints", ("Shopping list %q updated: %d missing item(s), %d piece(s)"):format(name, #items, pieces))
    -- Show the result: open the shopping widget on the routed list (design doc
    -- seams: "Widget switches to the list"; UX review #9). Toggle-only when closed.
    if HDG.Store:GetState().account.ui.shoppingWidgetShown ~= true then
        HDG.Store:Dispatch({ type = A.SHOPPING_WIDGET_TOGGLE })
    end
end

-- Import ALL decor (full quantities) as a furnishing set: encode an HDGRCRATE
-- code and land the player on the unified Import-a-Build view, parsed and
-- titled -- one Commit click away (the flow owns naming/dedupe).
function C:_ImportAsSet()
    -- blueprints.setDecor, not the inspector: the inspector's groups honour the
    -- Missing-only filter, and a set built from that view dropped every piece
    -- the player already owned.
    local src = HDG.Selectors:Call("blueprints.setDecor", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read
    if not src then return end
    local decor, skipped = src.decor, src.skipped
    if #decor == 0 then
        HDG.Log:Warn("blueprints", "No catalog-resolvable decor in this blueprint yet")
        return
    end
    local name = HDG.Selectors:Call("blueprints.displayName", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read
    local code = HDG.Projects.CrateCodec.Encode({ name = name, decor = decor })
    HDG.Store:Dispatch({ type = A.STYLES_IMPORT_RESET })
    HDG.Store:Dispatch({ type = A.STYLES_IMPORT_SET_DESTINATION, payload = { destination = "set" } })
    HDG.Store:Dispatch({ type = A.STYLES_IMPORT_SET_URL, payload = { text = code } })
    HDG.Store:Dispatch({ type = A.STYLES_IMPORT_PARSE })
    HDG.Store:Dispatch({ type = A.STYLES_IMPORT_SET_TITLE, payload = { text = name } })
    HDG.Store:Dispatch({ type = A.STYLES_SET_VIEW, payload = { view = "import" } })
    HDG.Store:Dispatch({ type = A.UI_SET_PERSISTENT, payload = { key = "view", value = "styles" } })
    if skipped > 0 then
        HDG.Log:Info("blueprints", skipped .. " uncatalogued item(s) left out of the set")
    end
end

-- Rooms from a received blueprint manifest -> a slot-src map for AutoLayout.
-- Shapes resolve from the RAW manifest (recordID lives on raw entries, not the
-- projected inspector rows). Returns the room map, room count, and the count of
-- unrecognized (unknown-shape) rooms.
local function _extractBlueprintRooms(m)
    local rooms, n, unknown = {}, 0, 0
    for _, g in ipairs(m.raw.contentGroups) do
        if g.contentType == 2 then
            for _, e in ipairs(g.entries) do
                local shape = HDG.Projects.ShapeAtlas.ShapeForRecordID(e.recordID)  -- exception(nullable): unknown room record
                if shape then
                    for _ = 1, e.total do
                        n = n + 1
                        rooms["slotsrc:" .. n] = { shape = shape, captureIndex = n }
                    end
                else
                    unknown = unknown + e.total
                end
            end
        end
    end
    return rooms, n, unknown
end

-- Slot-keyed placements from the auto-packed layout (floor 1; blueprints carry
-- no floor/position data -- AutoLayout arranges them).
local function _buildArchitectPlacements(rooms, packed)
    local placements, slotSeq = {}, 0
    for id, room in pairs(rooms) do
        local p = packed.layout[id]
        if p then
            slotSeq = slotSeq + 1
            placements["slot:" .. slotSeq] = {
                floor = 1, x = p.cell.x, y = p.cell.y,
                rotation = p.rotation or 0, shape = room.shape,
            }
        end
    end
    return placements, slotSeq
end

-- Rooms -> a new Architect layout: shapes via ShapeAtlas, positions via the
-- AutoLayout grid-pack ("arranged for you" -- share codes carry no positions).
function C:_OpenInArchitect(ownerBtn)
    local sb = HDG.Store:GetState().session.blueprints  -- exception(false-positive): top-level controller read
    local m = sb.selectedCode and sb.manifests[sb.selectedCode]
    if not (m and m.status == "received") then return end
    local rooms, n, unknown = _extractBlueprintRooms(m)
    if n == 0 then
        HDG.Log:Warn("blueprints", "No recognizable rooms in this blueprint")
        return
    end
    local packed = HDG.Projects.AutoLayout.compute({ rooms = rooms })
    local name = HDG.Selectors:Call("blueprints.displayName", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read

    local function commitTo(houseID, houseName)
        local placements, slotSeq = _buildArchitectPlacements(rooms, packed)
        HDG.Store:Dispatch({ type = A.PROJECTS_IMPORT_LAYOUT, payload = {
            houseID = houseID, houseName = houseName,
            version = {
                houseID = houseID, name = name .. " (blueprint)",
                createdAt = HDG.ControllerHelpers.Mechanics.Now(),  -- exception(boundary): time()
                basedOn = nil, placements = placements, slotSeq = slotSeq, numFloors = 1,
            },
        } })
        HDG.Store:Dispatch({ type = A.UI_SET_PERSISTENT, payload = { key = "view", value = "projectsArchitect" } })
        if unknown > 0 then
            HDG.Log:Info("blueprints", unknown .. " room(s) with unknown shapes were left out")
        end
    end

    -- House targeting mirrors the Layouts importer: the only house, or a menu.
    if not HDG.ControllerHelpers.Mechanics.PromptHouseTarget(
            ownerBtn, "Open in Architect for which house?", commitTo) then
        HDG.Log:Warn("blueprints", "No Projects house yet -- visit a house first")
    end
end

-- Save the current location as a blueprint into Blizzard's catalog. This is
-- "Save Blueprint" (the House menu's own verb), NOT an export of what's
-- inspected. A type menu (House/Room/Interior/Exterior) -> a name prompt ->
-- ExportBlueprint(type, name); the fresh code is auto-selected on success and
-- a failure toasts Blizzard's reason (OnExportFailure). Availability is
-- location-based and single-valued, so all four are offered; the server
-- rejects the ones that don't fit where you stand.
function C:_SaveBlueprint(ownerBtn)
    local avail = HDG.BlueprintObserver:GetExportAvailability()
    if avail ~= Enum.HousingResult.Success then  -- exception(boundary): Blizzard enum
        local map = _G.HousingResultToErrorText  -- exception(boundary): Blizzard global map
        HDG.Log:Warn("blueprints", (map and map[avail]) or "Saving unavailable here -- be at your house first")  -- exception(boundary): not every value mapped
        return
    end
    local BT = Enum.HousingBlueprintType  -- exception(boundary): Blizzard enum
    local items = {
        { isTitle = true, text = "Save as..." },
        { text = "Full House", callback = function() _G.StaticPopup_Show("HDGR_BLUEPRINT_SAVE", nil, nil, { blueprintType = BT.House }) end },
        { text = "This Room",  callback = function() _G.StaticPopup_Show("HDGR_BLUEPRINT_SAVE", nil, nil, { blueprintType = BT.Room }) end },
        { text = "Interior",   callback = function() _G.StaticPopup_Show("HDGR_BLUEPRINT_SAVE", nil, nil, { blueprintType = BT.Interior }) end },
        { text = "Exterior",   callback = function() _G.StaticPopup_Show("HDGR_BLUEPRINT_SAVE", nil, nil, { blueprintType = BT.Exterior }) end },
    }
    HDG.UI.ShowMenu(ownerBtn, items)
end

-- Meter fill variants (state-driven paint; ProgressBarFill takes { variant, dim }).
local METER_VARIANT = {
    na   = { variant = "success", dim = true },
    fit  = { variant = "success" },
    full = { variant = "warning" },
    over = { variant = "error" },
}
local METER_BAR_IDS = {
    room        = "blueprintsDetailPanel.meterRoomBar",
    interior    = "blueprintsDetailPanel.meterIntBar",
    exterior    = "blueprintsDetailPanel.meterExtBar",
    interiorPet = "blueprintsDetailPanel.meterIntPetBar",
    exteriorPet = "blueprintsDetailPanel.meterExtPetBar",
}

function C:Refresh(rootFrame, _ctx)
    local codeBox = HDG.UI.W(rootFrame, "blueprintsDetailPanel.codeBox")

    -- Bindings render everything textual; the two imperative reconciles are the
    -- meter fill colors (state-driven skinner re-registration) and the
    -- programmatic share-code text (editboxes have no binding channel).
    local b = HDG.Selectors:Call("blueprints.budgetFit", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read
    for _, m in ipairs(b.meters) do
        local bar = HDG.UI.W(rootFrame, METER_BAR_IDS[m.key])
        HDG.Theme:Register(bar._hdgrBarFill, "ProgressBarFill", METER_VARIANT[m.state])
    end
    -- Verdict badge text: green when it fits, red when blocked (the band's
    -- card chrome stays accent; only the text role tones -- UX review #14).
    local verdictFs = HDG.UI.W(rootFrame, "blueprintsDetailPanel.verdict")
    HDG.Theme:Register(verdictFs, b.fits and "TextSuccess" or "TextError")
    if not codeBox:HasFocus() then
        codeBox:SetText(_selectedCode() or "")
    end
    -- Name boxes (inspector + library detail) show the SELECTED entry's name
    -- (own -> Blizzard catalog name; pasted -> HDG label), per-row not
    -- last-typed. Never clobber mid-edit. Same commit contract on both.
    local shownName = _shownName()
    for _, id in ipairs({ "blueprintsDetailPanel.nameBox", "blueprintsLibraryPanel.nameBox" }) do
        local box = HDG.UI.W(rootFrame, id)
        if not box:HasFocus() then
            box:SetText(shownName)
            -- Programmatic SetText: poke the placeholder overlay (OnTextChanged-
            -- via-SetText isn't guaranteed; same belt the binding dispatch wears).
            if box._hdgrPlaceholderRefresh then box._hdgrPlaceholderRefresh() end
        end
    end
end

-- Delete an OWN manual blueprint from Blizzard's catalog, with a confirm. This
-- is a real catalog delete (never wired into Forget, which is HDG-list-only);
-- the row `x` only exposes it on own manual blueprints, never auto-backups.
--
-- name + id travel as textArg1 + data, never baked into the closure: UI.Confirm
-- memoizes the dialog per id, so the FIRST call's text and onAccept are the
-- ones every later show runs.
--
-- All three callers stamp a non-nil id and a name. The picker row gates on
-- `ed.blueprintID ~= nil` itself; the Library's two (the strip's Remove and the
-- row `x`) are gated by blueprints.libraryCanRemove and the matching
-- `_removeBtn:SetShown` condition, which both require src == "mine" AND an id.
function C:_ConfirmDelete(blueprintID, name)
    HDG.UI.Confirm({
        id       = "HDGR_BLUEPRINT_DELETE",
        text     = "Delete blueprint \"%s\" from your catalog? This can't be undone.",
        accept   = "Delete", cancel = "Cancel",
        textArg1 = name, data = blueprintID,
        onAccept = function(_, bid)
            HDG.BlueprintObserver:Delete(bid)
        end,
    })
end

-- Forget a PASTED code, with a confirm. HDG-state-only (the code keeps working
-- and can be pasted again), but the private label the player typed goes with
-- it and the list is the only place the code string lives -- one mis-click on
-- a code pasted from a Discord message weeks ago is unrecoverable (Soul,
-- Discord 2026-09-10). Own id: the dialog text is memoized per id.
function C:_ConfirmForget(shareCode, name)
    HDG.UI.Confirm({
        id       = "HDGR_BLUEPRINT_FORGET_CODE",
        text     = "Forget pasted code \"%s\"? It leaves your list and its name is lost. The code itself keeps working -- paste it again any time.",
        accept   = "Forget", cancel = "Cancel",
        textArg1 = name, data = shareCode,
        onAccept = function(_, code)
            HDG.Store:Dispatch({ type = A.BLUEPRINT_FORGET, payload = { shareCode = code } })
        end,
    })
end

-- Commit a USER-typed name for the selected code: own saved blueprint -> rename
-- in Blizzard's catalog; pasted code -> HDG display-label overlay. Runs on
-- focus-lost only, which fires BEFORE a new row's OnClick -- so clicking
-- another row still lands the commit on the code selected while typing. The
-- _dirty flag (stamped by OnTextChanged(userInput)) makes the commit both
-- once-only (review finding: Enter double-fired) and Escape-cancellable.
function C:_CommitName(box)
    if not box._dirty then return end
    box._dirty = nil
    local code = _selectedCode()
    if not code then return end
    local text = HDG.Format.Trim(box:GetText())
    if text == "" then return end
    local entry = HDG.Selectors:Call("blueprints.selectedEntry", HDG.Store:GetState(), {})  -- exception(false-positive): top-level controller read
    if entry and entry.isOwn then
        if entry.isAuto then
            -- Auto-backups are read-only: say so and revert instead of the old
            -- silent no-op-then-revert (UX review #3).
            if text ~= entry.name then
                HDG.Log:Warn("blueprints", "Auto-backups can't be renamed")
                box:SetText(entry.name or "")
            end
        elseif entry.blueprintID and text ~= entry.name then
            -- Own saved blueprint: rename in Blizzard's catalog. Too short and
            -- the server refuses with HousingResult 8, which surfaces as a bare
            -- "Invalid Blueprint name" toast -- name the rule here instead and
            -- keep the old name. (A PASTED code's label is HDG's own, so the
            -- branch below is deliberately unbounded.)
            if #text < _nameMin() then
                HDG.Log:Warn("blueprints", ("A blueprint name needs at least %d characters"):format(_nameMin()))
                box:SetText(entry.name or "")  -- exception(nullable): own entries always carry the catalog name
                return
            end
            HDG.BlueprintObserver:Rename(entry.blueprintID, text)
        end
    elseif text ~= (entry and entry.label) then
        -- Pasted/shared code: HDG display label overlay.
        HDG.Store:Dispatch({ type = A.BLUEPRINT_SET_LABEL, payload = { shareCode = code, label = text } })
    end
end

-- Link in chat (mirrors ChatFrameUtil.LinkItem's active-editbox / open-chat split).
-- Copy requirements: the manifest as publishable plain text, in the shared copy
-- dialog. WoW addons cannot write files, so "export" here means the player
-- copies and saves it themselves -- which is why the button says Copy, not
-- Export, and nobody goes hunting on disk for a file that was never written.
-- The switch's caption. Short: the exported TEXT carries the full
-- "Vendors listed for: Alliance (Founder's Point)" line, so the window only has
-- to name the side.
local EXPORT_SWITCH_LABEL = { alliance = "Alliance", horde = "Horde" }

function C:_CopyRequirements()
    -- Hoisted: the title's name and the body must come from the same state, or
    -- the dialog could be headed with a different blueprint than it lists.
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    local text  = HDG.Selectors:Call("blueprints.manifestText", state, {})
    if not text then return end  -- exception(nullable): button is gated on hasManifest; a race gets a no-op
    local name    = HDG.Selectors:Call("blueprints.displayName", state, {})
    local faction = HDG.Selectors:Call("blueprints.exportNeighborhood", state, {})

    -- The switch belongs on THIS window rather than the tab behind it: the
    -- choice is about the artefact being copied, not a standing preference, so
    -- it is session state and never writes back to the shopping toggle.
    HDG.UI:CopyDialog():Open(HDG.Locale:Get("BP_COPY_REQS_TITLE"):format(name), text, {
        faction = faction and {
            current = faction,
            label   = EXPORT_SWITCH_LABEL[faction],
            onChange = function(nextFaction)
                HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT, payload = {
                    view = "blueprints", key = "exportNeighborhood", value = nextFaction } })
                local newText = HDG.Selectors:Call("blueprints.manifestText", HDG.Store:GetState(), {})
                return newText, EXPORT_SWITCH_LABEL[nextFaction]
            end,
        } or nil,   -- exception(nullable): a neutral character expresses no neighborhood, so no switch
    })
    HDG.Log:Success("blueprints", ("Copied requirements for %q"):format(name))
end

function C:_LinkInChat()
    local code = _selectedCode()
    if not code then return end  -- exception(nullable): nothing selected
    local link = HDG.BlueprintObserver:GetHyperlink(code)
    if not link then return end  -- exception(nullable): hyperlink may be unavailable
    local CFU = _G.ChatFrameUtil
    if CFU and CFU.GetActiveWindow and CFU.GetActiveWindow() then  -- exception(boundary): Blizzard chat API
        CFU.InsertLink(link)
    elseif CFU and CFU.OpenChat then
        CFU.OpenChat(link)
    end
end

HDG.Controllers:Register("blueprints", C)
