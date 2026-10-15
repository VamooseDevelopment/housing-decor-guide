-- HDG.TrainersController
-- (Per-prof aggregates precomputed in selectors; controller reads ed.* fields.)
-- ============================================================================
-- Profession trainer NPCs grouped by profession + expansion. Two responsibilities:
--   1. Wire(rootFrame) -- search box + (no other top-level controls today)
--   2. Heterogeneous row factory "trainersRow" -- dispatches on ed.kind to
--      render five row shapes:
--        profHeader    -- collapsible profession bar
--        expSection    -- expansion divider under expanded profession
--        trainerRow    -- single NPC row with location + faction + waypoint btn
--        midnightHeader -- "Midnight Recipe Sources" collapsible bar
--        midnightRow   -- recipe / source / npc / zone (+ optional waypoint)

HDG = HDG or {}
HDG.Rows = HDG.Rows or {}
HDG.TrainersController = HDG.TrainersController or {}

local TrainersController = HDG.TrainersController
local CH = HDG.ControllerHelpers

-- ===== Controller wiring ===================================================

function TrainersController:Wire(rootFrame)
    HDG.UI.WireSearchBox(rootFrame, "trainersPanel.searchBox", "trainers", "searchQuery")
end

function TrainersController:Refresh(rootFrame, ctx)
    -- All rendering flows through bindings + row factory; nothing imperative.
end

HDG.Controllers:Register("trainers", TrainersController)

-- ===== Helpers =============================================================

-- Format trainer faction sigil: "A" / "H" / "A+H" (or note text appended).
local function factionSigil(faction)
    if faction == "Alliance" then return "A" end
    if faction == "Horde"    then return "H" end
    return "A+H"   -- "Both"
end

local function factionColor(faction)
    -- No faction-specific token decided yet; all render as text.dim.
    return HDG.Theme:ColorCode("text.dim")
end

-- Format coord pair as "x.x, y.y" or "" if missing.
local function formatCoords(x, y)
    if not (x and y) then return "" end
    return string.format("%.1f, %.1f", x, y)
end

-- The Map button: the shared show-on-map action (map + pin, no waypoint). Shown only
-- for rows that resolved a mapID and coords (selector-baked), so all three are set.
local function showTrainerOnMap(trainerRow)
    local label = trainerRow.dbName or ("npc " .. tostring(trainerRow.npcID))
    -- ShowOnMap: coords are zone-pct (0-100); ShowOnMap normalizes to 0-1
    -- (passing x/100 manually landed every waypoint in the corner).
    HDG.Waypoints:ShowOnMap(trainerRow.mapID, trainerRow.x, trainerRow.y,
        label .. " (" .. (trainerRow.profName or "?") .. ")")
end

-- ===== Midnight Recipe Sources columns =====================================
-- Fixed column layout (recipe / source / npc / zone / cost). Widths fit the
-- ~740-wide scrollbox, leaving the right edge for the Map button.
local MN_COLS = {
    name = { x = 10,  w = 175 },
    src  = { x = 190, w = 66  },
    npc  = { x = 262, w = 150 },
    zone = { x = 416, w = 100 },
    cost = { x = 520, w = 168 },
}

-- Anchor a FontString as a fixed, single-line, left-justified column.
local function _layoutCol(row, fs, col)
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
    fs:SetWidth(col.w)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
end

-- recipeSource.type -> a valid SOURCE_TYPE_COLOR name for the Palette token.
-- discovery/trainer have no own swatch -> reuse the nearest semantic color.
local _MN_SRC_TOKEN = {
    vendor = "VENDOR", drop = "DROP", quest = "QUEST",
    discovery = "LEARNED", trainer = "PROFESSION",
    event = "EVENT",   -- world-event vendor recipes (Hallow's End), 2026-10-15
}
local function _midnightSourceColor(srcType)
    return HDG.Palette:ColorCode("source." .. (_MN_SRC_TOKEN[srcType] or "UNKNOWN"))
end

-- ===== Row factory: single registered kind, dispatches on ed.kind =========

local function _rowFirstPaint(row)
    -- Allocate all FontStrings/buttons for every kind; show/hide per Configure.
    -- Keeps the pool homogeneous so recycling is safe.
    HDG.UI:RowFirstPaint(row, "_trainersLaidOut", function()
        -- applyFontRole at first-paint makes Reset's SetText("") safe on released
        -- frames. Configure re-applies per-kind roles; this is a font-not-set guard.
        local label = HDG.UI.RowText(row, "body", "Text", "LEFT")
        label:SetPoint("LEFT", row, "LEFT", 10, 0)
        label:SetWordWrap(false)
        row._labelFs = label

        -- Secondary label (zone name / annotation / count)
        local sub = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
        sub:SetPoint("LEFT", label, "RIGHT", 8, 0)
        row._subFs = sub

        -- Right-aligned annotation (coords / "needs training" tail / trainer count)
        local right = HDG.UI.RowText(row, "small", "TextDim", "RIGHT")
        right:SetPoint("RIGHT", row, "RIGHT", -40, 0)  -- leave room for Map button
        row._rightFs = right

        -- Map button (only used on trainerRow + midnightRow with coords)
        local mapBtn = HDG.UI.RowButton(row, "Map")
        mapBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        mapBtn:Hide()
        row._mapBtn = mapBtn

        -- Midnight-only columns (Source / NPC / Zone / Cost). Allocated for every
        -- row to keep the pool homogeneous; non-midnight kinds blank them in reset.
        -- Recipe reuses _labelFs (re-anchored per paint). Anchored once, never move.
        row._srcFs  = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
        row._npcFs  = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
        row._zoneFs = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
        row._costFs = HDG.UI.RowText(row, "small", "TextDim", "LEFT")
        _layoutCol(row, row._srcFs,  MN_COLS.src)
        _layoutCol(row, row._npcFs,  MN_COLS.npc)
        _layoutCol(row, row._zoneFs, MN_COLS.zone)
        _layoutCol(row, row._costFs, MN_COLS.cost)
    end)
end

-- Click handlers (captured-key/captured-source closures rebuilt per
-- Configure so recycled rows track the current item).
local function _onProfHeaderClick(profName)
    return function()
        if not profName then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.TRAINERS_TOGGLE_PROFESSION,
            payload = { profession = profName },
        })
    end
end

local function _onTrainerRowClick(npcID)
    return function()
        if not npcID then return end
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.TRAINERS_SELECT_TRAINER,
            payload = { npcID = npcID },
        })
    end
end

local function _onMidnightHeaderClick()
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.TRAINERS_TOGGLE_MIDNIGHT_SECTION,
        payload = {},
    })
end

local function _onMidnightShowOnMap(mapID, x, y, title)
    return function()
        -- Show-on-map (standard "Map" action). Coords are zone-pct (0-100).
        HDG.Waypoints:ShowOnMap(mapID, x, y, title)
    end
end

-- Per-kind handlers. `cc` is { accent, dim, success } theme color codes
-- pre-fetched in Configure -- the standard token trio used by most
-- handlers. midnightHeader fetches its expansion brand color directly.

local function _configureProfHeader(row, ed, cc)
    HDG.UI.applyFontRole(row._labelFs, "subheading")
    local prefix = ed.expanded and "v " or "> "
    local nameColor = ed.knownByCurrent and cc.success or cc.accent
    row._labelFs:SetText(prefix .. nameColor .. (ed.profName or "?") .. "|r")
    local tail = string.format("%d %s", ed.trainerCount,
        (ed.trainerCount == 1) and "trainer" or "trainers")
    if ed.topCrafter then
        tail = tail .. cc.dim .. "  -- top: " .. ed.topCrafter.charName
            .. string.format(" (%d/%d)", ed.topCrafter.knownCount, ed.topCrafter.totalCount)
            .. "|r"
    end
    row._rightFs:SetText(tail)
    HDG.Theme:Register(row, "RowChrome", { selected = ed.expanded == true })
    row:SetScript("OnClick", _onProfHeaderClick(ed.profName))
end

local function _configureExpSection(row, ed, cc)
    HDG.UI.applyFontRole(row._labelFs, "body")
    HDG.Theme:Register(row, "RowChrome", { selected = false })  -- before the no-needs early return
    row._labelFs:ClearAllPoints()
    row._labelFs:SetPoint("LEFT", row, "LEFT", 20, 0)  -- indent under profHeader
    row._labelFs:SetText(cc.dim .. (ed.expName or "?") .. "|r")
    local needs = ed.charsNeeding
    if not (needs and #needs > 0) then return end
    local parts = {}
    for i, c in ipairs(needs) do
        if i > 3 then break end  -- cap to 3 to avoid overflow
        parts[#parts + 1] = string.format("%s (%d/%d)", c.charName, c.current, c.max)
    end
    local tail = table.concat(parts, ", ")
    if #needs > 3 then tail = tail .. " +" .. (#needs - 3) end
    row._rightFs:SetText("needs: " .. tail)
end

local function _configureTrainerRow(row, ed, cc)
    HDG.UI.applyFontRole(row._labelFs, "body")
    HDG.Theme:Register(row, "RowChrome", { selected = false })
    row._labelFs:ClearAllPoints()
    row._labelFs:SetPoint("LEFT", row, "LEFT", 32, 0)  -- deeper indent
    local resolvedName = HDG.NPCNameResolver
        and HDG.NPCNameResolver:ResolveName(ed.npcID, ed.dbName)
        or (ed.dbName or "?")
    local noteSuffix = ed.note and (cc.dim .. " (" .. ed.note .. ")|r") or ""
    row._labelFs:SetText(factionColor(ed.faction) .. "[" .. factionSigil(ed.faction) .. "]|r  "
        .. resolvedName .. noteSuffix)
    local zoneLoc = ed.zoneEnUS
        and (HDG.ZoneNameResolver:Localize(ed.zoneEnUS) or ed.zoneEnUS)
        or ""
    row._subFs:SetText(cc.dim .. zoneLoc .. "|r")
    row._rightFs:SetText(formatCoords(ed.x, ed.y))
    if ed.mapID and ed.x and ed.y then
        row._mapBtn:Show()
        local capture = ed
        row._mapBtn:SetScript("OnClick", function() showTrainerOnMap(capture) end)
    end
    row:SetScript("OnClick", _onTrainerRowClick(ed.npcID))
end

local function _configureMidnightHeader(row, ed)
    HDG.UI.applyFontRole(row._labelFs, "subheading")
    local prefix = ed.expanded and "v " or "> "
    -- Midnight brand color via Palette (scheme-invariant). per ADR-023.
    local mnCC = HDG.Palette:ColorCode("expansion.Midnight")
    row._labelFs:SetText(prefix .. mnCC .. "Midnight Recipe Sources|r")
    HDG.Theme:Register(row, "RowChrome", { selected = ed.expanded == true })
    row:SetScript("OnClick", _onMidnightHeaderClick)
end

-- Midnight section profession sub-header (e.g. "Alchemy") -- accent name,
-- slight indent under the section header.
local function _configureMidnightProfHeader(row, ed, cc)
    HDG.UI.applyFontRole(row._labelFs, "subheading")
    row._labelFs:ClearAllPoints()
    row._labelFs:SetPoint("LEFT", row, "LEFT", 16, 0)
    row._labelFs:SetText(cc.accent .. (ed.profName or "?") .. "|r")
    HDG.Theme:Register(row, "RowChrome", { selected = false })
end

-- Column header (Recipe / Source / NPC / Zone / Cost) above each profession's
-- recipes -- dim labels at the same x-offsets as the data rows below.
local function _configureMidnightColumnHeader(row, ed, cc)
    HDG.UI.applyFontRole(row._labelFs, "small")
    _layoutCol(row, row._labelFs, MN_COLS.name)
    HDG.Theme:Register(row, "RowChrome", { selected = false })
    row._labelFs:SetText(cc.dim .. "Recipe|r")
    row._srcFs:SetText(cc.dim .. "Source|r")
    row._npcFs:SetText(cc.dim .. "NPC / Origin|r")
    row._zoneFs:SetText(cc.dim .. "Zone|r")
    row._costFs:SetText(cc.dim .. "Cost / Method|r")
end

-- Columnar recipe row: Recipe | Source(type, colored) | NPC/Origin | Zone | Cost,
-- plus a Map button when the (vendor) source resolved coords.
local function _configureMidnightRow(row, ed, cc)
    HDG.UI.applyFontRole(row._labelFs, "body")
    _layoutCol(row, row._labelFs, MN_COLS.name)
    HDG.Theme:Register(row, "RowChrome", { selected = false })

    local primaryCC = HDG.Theme:ColorCode("text.primary")
    row._labelFs:SetText(primaryCC .. ed.recipeName .. "|r")

    local typeLabel = ed.sourceType:sub(1, 1):upper() .. ed.sourceType:sub(2)
    row._srcFs:SetText(_midnightSourceColor(ed.sourceType) .. typeLabel .. "|r")
    row._npcFs:SetText(primaryCC .. ed.npcOrigin .. "|r")
    row._zoneFs:SetText(cc.dim .. ed.zone .. "|r")
    row._costFs:SetText(ed.costLine ~= "" and ed.costLine or (cc.dim .. "--|r"))

    if ed.mapID and ed.x and ed.y then
        row._mapBtn:Show()
        row._mapBtn:SetScript("OnClick",
            _onMidnightShowOnMap(ed.mapID, ed.x, ed.y, ed.recipeName))
    end
end

-- Dispatch: ed.kind -> handler. Missing entry falls through to a no-op
-- (empty row label) so the row pool stays consistent for unknown kinds.
local _CONFIGURE_BY_KIND = {
    profHeader           = _configureProfHeader,
    expSection           = _configureExpSection,
    trainerRow           = _configureTrainerRow,
    midnightHeader       = _configureMidnightHeader,
    midnightProfHeader   = _configureMidnightProfHeader,
    midnightColumnHeader = _configureMidnightColumnHeader,
    midnightRow          = _configureMidnightRow,
}

local function _resetRowFields(row)
    row._labelFs:SetText("")
    -- Restore the label indent to the header baseline. The pool shares one row
    -- kind across header (10) + child (expSection 20 / trainerRow 32) kinds; a
    -- recycled deep child must not keep its child indent or headers cascade.
    -- Deeper kinds re-anchor in their own handler.
    row._labelFs:ClearAllPoints()
    row._labelFs:SetPoint("LEFT", row, "LEFT", 10, 0)
    row._labelFs:SetWidth(0)   -- clear any midnight column width from reuse
    row._subFs:SetText("")
    row._rightFs:SetText("")
    -- Midnight columns blank for every non-midnight kind (first-paint guarantees
    -- these exist by the time Configure calls reset).
    row._srcFs:SetText("")
    row._npcFs:SetText("")
    row._zoneFs:SetText("")
    row._costFs:SetText("")
    row._mapBtn:Hide()
    row._mapBtn:SetScript("OnClick", nil)
    row:SetScript("OnClick", nil)
    row:RegisterForClicks("LeftButtonUp")
end

local function _trainersRowFactory(_template)
    return {
        Configure = function(row, ed)
            _rowFirstPaint(row)
            _resetRowFields(row)
            local handler = _CONFIGURE_BY_KIND[ed.kind]
            if handler then
                local cc = HDG.UI.SemanticCC()
                handler(row, ed, cc)
            end
            row:SetHeight(28)
        end,
        Reset = function(row)
            row:SetScript("OnClick", nil)
            HDG.UI.ClearRowText(row, "_labelFs")
            if row._subFs   then row._subFs:SetText("")   end
            HDG.UI.ClearRowText(row, "_rightFs")
            if row._srcFs   then row._srcFs:SetText("")   end
            if row._npcFs   then row._npcFs:SetText("")   end
            if row._zoneFs  then row._zoneFs:SetText("")  end
            if row._costFs  then row._costFs:SetText("")  end
            if row._mapBtn then
                row._mapBtn:Hide()
                row._mapBtn:SetScript("OnClick", nil)
            end
        end,
    }
end

HDG.Rows:Register("trainersRow", {
    font    = "body",
    height  = 28,
    factory = _trainersRowFactory,
    key     = function(ed)
        if not ed then return "?" end
        if ed.kind == "profHeader"     then return "ph:"  .. tostring(ed.profName or "?") end
        if ed.kind == "expSection"     then return "es:"  .. tostring(ed.profName or "?") .. ":" .. tostring(ed.expName or "?") end
        -- Tree path: the SAME npcID can appear in multiple (prof, exp) sections, so
        -- npcID alone collides. prof:exp:npcID is unique per tree position. Faction
        -- is omitted -- within one (prof, exp) factions carry distinct npcIDs.
        if ed.kind == "trainerRow"     then return "tr:"  .. tostring(ed.profName or "?") .. ":" .. tostring(ed.expName or "?") .. ":" .. tostring(ed.npcID or "?") end
        if ed.kind == "midnightHeader"       then return "mh" end
        if ed.kind == "midnightProfHeader"   then return "mp:" .. tostring(ed.profName or "?") end
        if ed.kind == "midnightColumnHeader" then return "mc:" .. tostring(ed.profName or "?") end
        if ed.kind == "midnightRow"          then return "mr:" .. tostring(ed.itemID or "?") end
        return "?"
    end,
})
