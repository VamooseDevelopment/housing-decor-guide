-- HDG.AltsController
-- ============================================================================
-- Active/Hidden pill wiring + altsRow factory (dispatches on element kind:
-- altsCharHeaderRow / altsGridHeaderRow / altsProfRow / altsSummaryDivider).

HDG = HDG or {}
HDG.Rows = HDG.Rows or {}
HDG.AltsController = HDG.AltsController or {}

local AltsController = HDG.AltsController
local CH = HDG.ControllerHelpers

-- ===== Controller wiring ===================================================

local function SetCharsPopulation(p)
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.ALTS_SET_CHARS_POPULATION,
        payload = { population = p },
    })
end

function AltsController:Wire(rootFrame)
    if not HDG.Log:HasTag("alts_action") then
        HDG.Log:RegisterTags({ alts_action = { user = true, level = "info", duration = 3 } })
    end
    HDG.UI.OnClick(rootFrame, "altsPanel.charsPill_active", function()
        SetCharsPopulation("active")
    end)
    HDG.UI.OnClick(rootFrame, "altsPanel.charsPill_hidden", function()
        SetCharsPopulation("hidden")
    end)
end

function AltsController:Refresh(rootFrame, ctx)
    -- Header text + section visibility flow through bindings + the layout
    -- engine's `visible` evaluation. Nothing imperative here.
end

HDG.Controllers:Register("alts", AltsController)

-- ===== Row factory ==========================================================

local NAME_COL_WIDTH = 96   -- fits "Leatherworking" in caption font without ellipsis
local EXP_COL_WIDTH  = 38   -- 12 * 38 + 96 = 552 inner width (fits 600 panel)

local function classColorHex(classFile)
    local rcc = _G.RAID_CLASS_COLORS
    if rcc and classFile and rcc[classFile] and rcc[classFile].colorStr then
        return "|c" .. rcc[classFile].colorStr
    end
    -- Fall back to theme text.primary when Blizzard's class color isn't
    -- resolvable (test mock, unknown class string).
    return HDG.Theme:ColorCode("text.primary")
end

-- ===== Per-cell tooltip ====================================================
-- Hit frames over each cell (FontStrings can't receive mouse events).
-- Tooltip shows per-char skill levels + "(known/total)" decor recipe suffix.
-- Reads alts.decorRecipeIndex (memoized selector) for the recipeSet + total.
local function collectDecorRecipesFor(profName, expDisplay)
    if not (profName and expDisplay) then return {}, 0 end
    local state = HDG.Store:GetState()  -- exception(false-positive): top-level controller method (not a row factory)
    local index = state and HDG.Selectors:Call("alts.decorRecipeIndex", state, {})
    local bucket = index and index[profName] and index[profName][expDisplay]
                   or { recipeSet = {}, total = 0 }
    return bucket.recipeSet, bucket.total
end

-- Count how many decor recipes from `recipeSet` this prof knows.
local function _countKnownForRecipeSet(prof, recipeSet)
    if not prof.knownRecipes then return 0 end
    local n = 0
    for recipeID in pairs(prof.knownRecipes) do
        if recipeSet[recipeID] then n = n + 1 end
    end
    return n
end

-- One tooltip-line entry for a char + (profID, idx) cell. Returns nil if hidden / no data.
local function _buildCharStatLine(char, profID, idx, recipeSet, total)
    if char.hidden then return nil end
    local prof = HDG.Profession.RecordOf(char, profID)
    if not (prof and prof.skillLines) then return nil end
    local NormalizeAlias = HDG.Expansion.NormalizeAlias
    local GetIndex       = HDG.Expansion.GetIndex
    for key, sl in pairs(prof.skillLines) do
        local canon = NormalizeAlias and NormalizeAlias(key)
        local kidx  = canon and GetIndex and GetIndex(canon)
        if kidx == idx then
            return {
                name      = char.name or "?",
                classFile = char.classFile,
                current   = sl.current,    -- scanner stamps skillLine.current/max (numeric)
                max       = sl.max,
                known     = total > 0 and _countKnownForRecipeSet(prof, recipeSet) or 0,
            }
        end
    end
    return nil
end

-- Collect tooltip lines for all chars for this (prof, idx) cell, alpha-sorted.
local function _collectTooltipLinesForCell(chars, profID, idx, recipeSet, total)
    local lines = {}
    for _, char in pairs(chars) do
        local entry = _buildCharStatLine(char, profID, idx, recipeSet, total)
        if entry then lines[#lines + 1] = entry end
    end
    table.sort(lines, function(a, b) return a.name < b.name end)
    return lines
end

-- Color the "(known/total)" suffix: full = success, partial = warning, zero = dim.
local function _knownSuffixColor(known, total)
    if known >= total then return HDG.Theme:GetTextStateColorToken("success") end
    if known > 0       then return HDG.Theme:GetTextStateColorToken("warning") end
    return HDG.Theme:ColorCode("text.dim")
end

-- A char-stat line as a TooltipEngine two-column extraLine ({ left | right }).
local function _charStatTooltipLine(line, total)
    local nameStr = classColorHex(line.classFile) .. line.name .. "|r"
    if total > 0 then
        nameStr = nameStr .. ("  %s(%d/%d)|r"):format(
            _knownSuffixColor(line.known, total), line.known, total)
    end
    local maxed = line.max > 0 and line.current >= line.max
    local valueColor = maxed and HDG.Theme:GetTextStateColorToken("success")
                              or HDG.Theme:GetTextStateColorToken("warning")
    return { text = nameStr, right = ("%s%d/%d|r"):format(valueColor, line.current, line.max) }
end

-- TooltipEngine def (function form): the per-expansion char-stat breakdown for a
-- grid cell. Reads hit._cellIdx (stamped once) + row._profName (set per-Configure)
-- live at hover; returns nil when there's no data so the engine renders nothing.
local function _altsCellTooltipDef(hit)
    local row = hit:GetParent()
    local profName = row and row._profName
    local profID   = row and row._profID
    local idx      = hit._cellIdx
    if not (profName and idx) then return nil end
    -- HDG.Expansion has no GetByIndex helper; the ordered EXPANSION_DATA
    -- is the canonical sort, indexed 1..N by ipairs (mirrors Each()).
    local exp = HDG.Constants.EXPANSION_DATA[idx]
    if not exp then return nil end

    local recipeSet, total = collectDecorRecipesFor(profName, exp.display)
    local chars = HDG.Store:GetState().account.characters  -- exception(false-positive): view-global; account.characters is factory-seeded + strict-read by every Alts selector
    local lines = _collectTooltipLinesForCell(chars, profID, idx, recipeSet, total)

    local extraLines = {}
    if #lines == 0 then
        extraLines[1] = { text = "No char data for this expansion", r = 0.6, g = 0.6, b = 0.6 }
    else
        for _, line in ipairs(lines) do
            extraLines[#extraLines + 1] = _charStatTooltipLine(line, total)
        end
    end
    return {
        anchor     = "ANCHOR_RIGHT",
        title      = ("%s - %s"):format(profName, exp.short or "?"),
        extraLines = extraLines,
    }
end

-- Lazy shape builders: create FontStrings once; toggled visible/hidden per kind to avoid bleed.

local function ensureCharHeader(row)
    if row._charLaidOut then return end
    local name = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(name, "heading")
    name:SetPoint("LEFT", row, "LEFT", 4, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    -- Hide/Show button (eye atlas): dispatches CHARACTER_HIDDEN_TOGGLE.
    local hideBtn = HDG.UI:AtlasButton(row, "transmog-icon-hidden", 14)
    hideBtn:SetPoint("LEFT", name, "RIGHT", 6, 0)
    hideBtn._icon = hideBtn._iconTex  -- alias used by _applyEyeButton (SetDesaturated / SetAlpha)
    -- Delete button: confirms via StaticPopup then dispatches CHARACTER_DELETED (irreversible).
    local delBtn = CreateFrame("Button", nil, row)
    delBtn:SetSize(14, 14)
    delBtn:SetPoint("LEFT", hideBtn, "RIGHT", 4, 0)
    delBtn._icon = delBtn:CreateTexture(nil, "OVERLAY")
    delBtn._icon:SetAllPoints()
    delBtn._icon:SetAtlas("common-icon-redx")  -- 12.0.5 atlas; fallback to common-icon-delete in older clients
    delBtn._icon:SetVertexColor(0.85, 0.35, 0.35, 0.85)
    delBtn:SetScript("OnEnter", function(self) self._icon:SetVertexColor(1.0, 0.30, 0.30, 1.0) end)
    delBtn:SetScript("OnLeave", function(self) self._icon:SetVertexColor(0.85, 0.35, 0.35, 0.85) end)
    local meta = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
    meta:SetWordWrap(false)
    -- Find Lumber indicator: spell icon (right) + label (left).
    -- known -> success + full-color; not known -> error + desaturated.
    local lumberIcon = row:CreateTexture(nil, "OVERLAY")
    lumberIcon:SetSize(14, 14)
    lumberIcon:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    -- Spell ID 1256697 = "Find Lumber" (matches HDG_Data.lua:2137).
    if _G.C_Spell and _G.C_Spell.GetSpellTexture then
        local tex = _G.C_Spell.GetSpellTexture(1256697)
        if tex then lumberIcon:SetTexture(tex) end
    end
    local lumber = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(lumber, "small")
    lumber:SetPoint("RIGHT", lumberIcon, "LEFT", -4, 0)
    lumber:SetJustifyH("RIGHT")
    lumber:SetWordWrap(false)
    meta:SetPoint("RIGHT", lumber, "LEFT", -8, 0)
    row._charNameFs     = name
    row._charMetaFs     = meta
    row._charLumberFs   = lumber
    row._charLumberIcon = lumberIcon
    row._charHideBtn    = hideBtn
    row._charDelBtn     = delBtn
    row._charLaidOut    = true
end

local function ensureGrid(row)
    if row._gridLaidOut then return end
    local prof = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(prof, "caption")
    prof:SetSize(NAME_COL_WIDTH, 14)
    prof:SetPoint("LEFT", row, "LEFT", 4, 0)
    prof:SetJustifyH("LEFT")
    prof:SetWordWrap(false)
    row._gridProfFs = prof

    row._gridCellFs  = {}
    row._gridCellHit = {}   -- invisible mouse-hit frames per cell (for tooltips)
    local prev = prof
    for i = 1, 12 do
        local cell = row:CreateFontString(nil, "OVERLAY")
        HDG.UI.applyFontRole(cell, "caption")
        cell:SetSize(EXP_COL_WIDTH, 14)
        cell:SetPoint("LEFT", prev, "RIGHT", 0, 0)
        cell:SetJustifyH("CENTER")
        cell:SetWordWrap(false)
        row._gridCellFs[i] = cell
        prev = cell
        -- Invisible hit frame (FontStrings can't receive mouse events).
        -- _cellIdx stamped once; row._profName supplies the profession per Configure.
        local hit = CreateFrame("Frame", nil, row)
        hit:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, 0)
        hit:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 0, 0)
        hit:EnableMouse(true)
        hit._cellIdx = i
        HDG.TooltipEngine:Attach(hit, _altsCellTooltipDef)
        row._gridCellHit[i] = hit
    end
    -- Per-cell header backdrops: hidden by default; shown in altsGridHeaderRow branch.
    row._gridHeaderBgs = {}
    row._gridHeaderBgs[1] = HDG.UI.makeColumnHeaderBg(row, prof)
    for i = 1, 12 do
        row._gridHeaderBgs[i + 1] = HDG.UI.makeColumnHeaderBg(row, row._gridCellFs[i])
    end
    row._gridLaidOut = true
end

local function ensureDivider(row)
    if row._dividerTex then return end
    local tex = row:CreateTexture(nil, "ARTWORK")   -- exception(false-positive): chrome-less divider row, no EnsureRowChrome (ARTWORK-0 fine)
    tex:SetPoint("LEFT",  row, "LEFT",   8, 0)
    tex:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    tex:SetHeight(1)
    local c = HDG.Theme:GetColor("border.subtle")
    tex:SetColorTexture(c.r, c.g, c.b, c.a)
    row._dividerTex = tex
end

local function hideShape(row, shape)
    if shape == "charHeader" or shape == nil then
        if row._charNameFs     then row._charNameFs:Hide()     end
        if row._charMetaFs     then row._charMetaFs:Hide()     end
        if row._charLumberFs   then row._charLumberFs:Hide()   end
        if row._charLumberIcon then row._charLumberIcon:Hide() end
        if row._charHideBtn    then row._charHideBtn:Hide()    end
        if row._charDelBtn     then row._charDelBtn:Hide()     end
    end
    if shape == "grid" or shape == nil then
        if row._gridProfFs then row._gridProfFs:Hide() end
        if row._gridCellFs then
            for _, c in ipairs(row._gridCellFs) do c:Hide() end
        end
        if row._gridHeaderBgs then
            for _, bg in ipairs(row._gridHeaderBgs) do
                bg:Hide()
            end
        end
        -- Hide hit frames when not rendering grid content (tooltips would fire over wrong kind).
        if row._gridCellHit then
            for _, hit in ipairs(row._gridCellHit) do hit:Hide() end
        end
    end
    if shape == "divider" or shape == nil then
        if row._dividerTex then row._dividerTex:Hide() end
    end
end

local function showShape(row, shape)
    if shape == "charHeader" then
        if row._charNameFs   then row._charNameFs:Show()   end
        if row._charMetaFs   then row._charMetaFs:Show()   end
        if row._charHideBtn  then row._charHideBtn:Show()  end
        if row._charDelBtn   then row._charDelBtn:Show()   end
        -- lumber visibility is opt-in per Configure branch
    end
    if shape == "grid" then
        if row._gridProfFs then row._gridProfFs:Show() end
        if row._gridCellFs then
            for _, c in ipairs(row._gridCellFs) do c:Show() end
        end
    end
    if shape == "divider" then
        if row._dividerTex then row._dividerTex:Show() end
    end
end

-- Format a skill cell by state:
--   no data -> text.disabled "-"  | 0 decor recipes -> dim
--   known >= total -> success     | current >= threshold -> accent  | else -> warning
-- decorThreshold from HDGR_ProfessionThresholds; fallback 80.
local FALLBACK_THRESHOLD = 80
local function formatCell(sl)
    if not sl then
        return HDG.Theme:ColorCode("text.disabled") .. "-|r"
    end
    local current = sl.current       -- slotData stamps current/decorTotal/decorKnown (all numeric)
    local total   = sl.decorTotal
    local known   = sl.decorKnown
    local threshold = sl.decorThreshold or FALLBACK_THRESHOLD
    if total == 0 then
        return HDG.Theme:ColorCode("text.dim") .. current .. "|r"
    end
    if known >= total then
        return HDG.Theme:ColorCode("semantic.success") .. current .. "|r"
    end
    if current >= threshold then
        return HDG.Theme:ColorCode("semantic.accent")  .. current .. "|r"
    end
    return HDG.Theme:ColorCode("semantic.warning") .. current .. "|r"
end

-- Per-kind row heights (SSoT: one table entry, two consumers).
local _ROW_HEIGHT = {
    altsCharHeaderRow  = 22,
    altsGridHeaderRow  = 14,
    altsSummaryDivider = 6,
}
local _ROW_HEIGHT_DEFAULT = 18  -- altsProfRow

-- Eye-button click: captures charKey via closure (recycled rows read current state).
local function _onCharHideClick(capturedKey)
    return function()
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.CHARACTER_HIDDEN_TOGGLE,
            payload = { charKey = capturedKey },
        })
    end
end

-- Delete-button click handler. Name + key travel as textArg1 + data: UI.Confirm
-- memoizes the dialog per id, so a text or closure baked at the first call is
-- what every later show runs -- the second deletion in a session named and
-- deleted the FIRST character (found 2026-09-11).
local function _onCharDelClick(capturedKey, displayName)
    return function()
        local label = displayName or capturedKey  -- exception(nullable): a character with no resolved display name falls back to its key
        HDG.UI.Confirm({
            id   = "HDGR_ALTS_DELETE_CHAR",
            text = "Delete |cffffd200%s|r from the alts list?\nThis removes saved professions + lumber awareness. Cannot be undone.",
            accept = "Delete",
            cancel = "Cancel",
            textArg1 = label,
            data     = { charKey = capturedKey, label = label },
            onAccept = function(_, d)
                HDG.Store:Dispatch({
                    type    = HDG.Constants.ACTIONS.CHARACTER_DELETED,
                    payload = { charKey = d.charKey },
                })
                HDG.Log:Info("alts_action", "Removed " .. d.label .. " from the alts list")
            end,
        })
    end
end

-- Apply Find Lumber indicator state (known vs not).
local function _applyLumberIndicator(row, knows)
    local lumber = row._charLumberFs
    local icon   = row._charLumberIcon
    if not (lumber and icon) then return end
    if knows then
        lumber:SetText(HDG.Theme:ColorCode("semantic.success") .. "Find Lumber known|r")
        icon:SetDesaturated(false)
        icon:SetAlpha(1.0)
    else
        lumber:SetText(HDG.Theme:ColorCode("semantic.error") .. "Find Lumber not learned|r")
        icon:SetDesaturated(true)
        icon:SetAlpha(0.55)
    end
    lumber:Show()
    icon:Show()
end

-- Apply eye-button state (shown, click handler, desaturation when hidden).
local function _applyEyeButton(row, ed)
    local showEye = ed.canUnhide ~= false  -- exception(nullable): canUnhide tri-state: nil=show (default), false=suppress; ~= false is the correct pattern
    if row._charHideBtn then
        row._charHideBtn:SetShown(showEye)
    end
    if not (row._charHideBtn and showEye) then return end
    if row._charHideBtn._icon then
        row._charHideBtn._icon:SetDesaturated(ed.hidden and true or false)
        row._charHideBtn._icon:SetAlpha(ed.hidden and 0.6 or 1.0)
    end
    row._charHideBtn:SetScript("OnClick", _onCharHideClick(ed.charKey))
end

-- Char-header row: class-colored name + realm/prof meta + eye/trash + Find Lumber.
local function _configureCharHeader(row, ed)
    hideShape(row, "grid")
    ensureCharHeader(row)
    showShape(row, "charHeader")
    local color = classColorHex(ed.classFile or ed.class)
    local label = string.format("%s%s|r", color, ed.name or "?")
    if ed.isCurrent then
        label = label .. " " .. HDG.Theme:ColorCode("semantic.accent") .. "(you)|r"
    end
    row._charNameFs:SetText(label)
    local meta
    if ed.profCount and ed.profCount > 0 then
        meta = string.format("%s - %d profession%s",
            ed.realm or "", ed.profCount,
            ed.profCount == 1 and "" or "s")
    else
        meta = (ed.realm or "") .. " - no professions scanned"
    end
    row._charMetaFs:SetText(meta)
    _applyEyeButton(row, ed)
    if row._charDelBtn then
        row._charDelBtn:SetScript("OnClick", _onCharDelClick(ed.charKey, ed.name))
    end
    _applyLumberIndicator(row, ed.knowsFindLumber)
end

-- Divider row: thin horizontal rule.
local function _configureSummaryDivider(row, _ed)
    hideShape(row, "charHeader")
    hideShape(row, "grid")
    ensureDivider(row)
    showShape(row, "divider")
end

-- Grid-header row: "Profession" + 12 expansion shorts + backdrops. Hit frames hidden.
local function _configureGridHeader(row, ed)
    hideShape(row, "charHeader")
    hideShape(row, "divider")
    ensureGrid(row)
    showShape(row, "grid")
    HDG.Theme:Register(row._gridProfFs, "TextHeading")
    row._gridProfFs:SetText("Profession")
    local exps = ed.exps or {}
    for i = 1, 12 do
        local cell = row._gridCellFs[i]
        HDG.Theme:Register(cell, "TextHeading")
        cell:SetText(exps[i] and exps[i].short or "")
    end
    if row._gridHeaderBgs then
        for _, bg in ipairs(row._gridHeaderBgs) do bg:Show() end
    end
    if row._gridCellHit then
        for _, hit in ipairs(row._gridCellHit) do hit:Hide() end
    end
end

-- Prof-data row: profession name + 12 formatted skill cells.
local function _configureProfRow(row, ed)
    hideShape(row, "charHeader")
    hideShape(row, "divider")
    ensureGrid(row)
    showShape(row, "grid")
    HDG.Theme:Register(row._gridProfFs, "Text")
    row._gridProfFs:SetText(ed.profName or "?")
    local cells = ed.cells or {}
    for i = 1, 12 do
        row._gridCellFs[i]:SetText(formatCell(cells[i]))
    end
    if row._gridHeaderBgs then
        for _, bg in ipairs(row._gridHeaderBgs) do bg:Hide() end
    end
    row._profName = ed.profName
    row._profID   = ed.profID
    if row._gridCellHit then
        for _, hit in ipairs(row._gridCellHit) do hit:Show() end
    end
end

-- Dispatch: ed.kind -> handler. Missing entry falls through to _configureProfRow.
local _CONFIGURE_BY_KIND = {
    altsCharHeaderRow  = _configureCharHeader,
    altsSummaryDivider = _configureSummaryDivider,
    altsGridHeaderRow  = _configureGridHeader,
}

local function _altsRowFactory(_template)
    return {
        Configure = function(row, ed)
            local handler = _CONFIGURE_BY_KIND[ed.kind] or _configureProfRow
            handler(row, ed)
            row:SetHeight(_ROW_HEIGHT[ed.kind] or _ROW_HEIGHT_DEFAULT)
        end,
        Reset = function(row)
            hideShape(row, nil)
        end,
    }
end

HDG.Rows:Register("altsRow", {
    font    = "body",
    height  = function(_index, ed)
        if not ed then return _ROW_HEIGHT_DEFAULT end
        return _ROW_HEIGHT[ed.kind] or _ROW_HEIGHT_DEFAULT
    end,
    factory = _altsRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        local kind = ed.kind
        if kind == "altsCharHeaderRow" then
            return "ach:" .. tostring(ed.charKey or "?")
        end
        if kind == "altsGridHeaderRow" then
            return "gh:" .. tostring(ed.tag or "?")
        end
        if kind == "altsSummaryDivider" then
            return "div:" .. tostring(ed.tag or "?")
        end
        return "pr:" .. tostring(ed.tag or "?")
    end,
})
