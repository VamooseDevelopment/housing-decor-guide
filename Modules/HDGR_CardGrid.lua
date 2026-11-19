-- HDG.CardGrid
-- ============================================================================
-- Card grid backed by CreateScrollBoxListSequenceView. One element per card;
-- SequenceView wraps left-to-right based on each element's declared size.
-- Port of Blizzard_HousingCatalogTemplates ScrollingHousingCatalogMixin:OnLoad.
--
-- SequenceView vs LinearView + row batching:
--   * Flat items[] per element; no BatchIntoRows pre-pass.
--   * Auto-rewraps on container resize without selector / cfg change.
--   * Full-width hook: (0, height) from sizer claims a whole row (section
--     headers mixed with cards). Reserved for future mixed-grid surfaces.
--
-- Public API:
--   HDG.CardGrid:Create(parent, cfg) -> host, scrollBar
--   HDG.CardGrid:SetItems(widget, items, retainScroll?)   -- flat items[]
--   HDG.CardGrid:Clear(widget)
--   HDG.CardGrid:RegisterCellKind(name, { template?, initFunc, resetFunc? })
--   HDG.CardGrid:EnsureDefaultAnatomy(cell, cfg) -- lazy-build helper
--   HDG.CardGrid:PaintIcon / PaintSelected / PaintCollected / PaintBadge /
--                  PaintBand            -- visual helpers for initFunc bodies
--   HDG.CardGrid.BAND_TINT             -- shared band-stripe palette
--
-- Cell kind shape:
--   {
--       template  = "Button",                          -- frame pool key
--       initFunc  = function(cell, elementData, cfg)  -- called per bind;
--                                                       -- handles lazy
--                                                       -- anatomy + paint
--       resetFunc = function(pool, cell)              -- optional; clears
--                                                       -- scripts on pool
--                                                       -- release
--   }

HDG = HDG or {}
HDG.CardGrid = HDG.CardGrid or {}
local M = HDG.CardGrid

M._cellKinds = M._cellKinds or {}

local C = HDG.Constants.STYLE.CARD_GRID
local DEFAULT_CFG = {
    cellSize    = C.CELL_SIZE,
    cellSpacing = C.CELL_SPACING,
    rowSpacing  = C.ROW_SPACING,
    iconInset   = C.ICON_INSET,
}
M.DEFAULT_CFG = DEFAULT_CFG

-- Gallery atlas (Blizzard housing catalog tile). Selection = pure atlas swap, no Theme Skinner.
local CELL_ATLAS_DEFAULT = "house-chest-list-Item-default"
local CELL_ATLAS_ACTIVE  = "house-chest-list-Item-active"
M.CELL_ATLAS_DEFAULT = CELL_ATLAS_DEFAULT
M.CELL_ATLAS_ACTIVE  = CELL_ATLAS_ACTIVE

-- ===== Cell kind registry ==================================================
-- One cellKind per scrollbox. Factory closure binds initFunc with cfg once at
-- construction; pooled frames reuse the same closure (Blizzard pool requires stable ref).
function M:RegisterCellKind(name, def)
    if not (name and def and def.initFunc) then return end
    self._cellKinds[name] = {
        template  = def.template or "Button",
        initFunc  = def.initFunc,
        resetFunc = def.resetFunc,
    }
end

function M:GetCellKind(name) return self._cellKinds[name] end

-- ===== Default cell anatomy ================================================
-- Lazy-built once per pooled frame (_anatomyBuilt short-circuits). Call at top of initFunc.
-- Every pass sizes the cell, its icon and band stripe from cfg, so a grid whose
-- tile size changes live (SetCellSize) re-sizes its pooled cells on re-init.
local function _sizeAnatomy(cell, size, inset)
    cell:SetSize(size, size)
    cell.icon:SetSize(size - 2 * inset, size - 2 * inset)
    cell.bandStripe:SetSize(3, size - 8)
end

function M:EnsureDefaultAnatomy(cell, cfg)
    cfg = cfg or {}
    local size  = cfg.cellSize or DEFAULT_CFG.cellSize
    local inset = cfg.iconInset or DEFAULT_CFG.iconInset
    if cell._anatomyBuilt then
        _sizeAnatomy(cell, size, inset)
        return cell
    end

    cell.bg = cell:CreateTexture(nil, "BACKGROUND")
    cell.bg:SetAllPoints()
    cell.bg:SetAtlas(CELL_ATLAS_DEFAULT)

    cell.hoverBg = cell:CreateTexture(nil, "BACKGROUND", nil, 1)
    cell.hoverBg:SetAllPoints()
    cell.hoverBg:SetAtlas(CELL_ATLAS_DEFAULT)
    cell.hoverBg:SetAlpha(0.75)
    cell.hoverBg:SetBlendMode("ADD")
    cell.hoverBg:Hide()

    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetPoint("CENTER", 0, 0)
    cell.icon:Hide()

    cell.checkmark = cell:CreateTexture(nil, "OVERLAY", nil, 2)
    cell.checkmark:SetSize(12, 12)
    cell.checkmark:SetPoint("BOTTOMLEFT", 4, 4)
    cell.checkmark:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
    cell.checkmark:Hide()

    cell.redX = cell:CreateTexture(nil, "OVERLAY", nil, 2)
    cell.redX:SetSize(12, 12)
    cell.redX:SetPoint("BOTTOMLEFT", 4, 4)
    cell.redX:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    cell.redX:Hide()

    cell.badge = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    cell.badge:SetPoint("BOTTOMRIGHT", -9, 7)
    cell.badge:SetHeight(20)
    cell.badge:Hide()

    cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontWhiteTiny")
    cell.label:SetPoint("TOP", 0, -2)
    cell.label:SetPoint("LEFT", 4, 0)
    cell.label:SetPoint("RIGHT", -4, 0)
    cell.label:SetJustifyH("CENTER")
    cell.label:SetHeight(10)
    cell.label:Hide()

    -- Optional 3-px band stripe (left edge). Hidden by default; PaintBand reveals it.
    cell.bandStripe = cell:CreateTexture(nil, "ARTWORK", nil, 1)
    cell.bandStripe:SetPoint("LEFT", 2, 0)
    cell.bandStripe:Hide()

    _sizeAnatomy(cell, size, inset)
    cell._anatomyBuilt = true
    return cell
end

-- Band stripe tints (shared palette so all consumers paint the same colors).
local _BAND_TINT = {
    signature = { 0.95, 0.78, 0.30, 1 },  -- warm gold
    accent    = { 0.45, 0.78, 0.95, 1 },  -- cool cyan
    clashing  = { 0.95, 0.42, 0.42, 1 },  -- soft red
}
M.BAND_TINT = _BAND_TINT

function M:PaintBand(cell, band)
    if not (cell and cell.bandStripe) then return end
    local tint = _BAND_TINT[band]
    if tint then
        cell.bandStripe:SetColorTexture(tint[1], tint[2], tint[3], tint[4])
        cell.bandStripe:Show()
    else
        cell.bandStripe:Hide()
    end
end

-- The model a tile draws for decor with no icon (Constants.DECOR_TILE_MODEL_SCENE_ID),
-- built on the first cell that needs one: most cells never do. Blizzard's tile
-- camera, and a scene that takes no mouse, so the cell keeps its hover and clicks.
local function _ensureModel(cell)
    if cell.model then return cell.model end
    local scene = CreateFrame("ModelScene", nil, cell, "NonInteractableModelSceneMixinTemplate")
    scene:SetAllPoints(cell.icon)
    scene:TransitionToModelSceneID(HDG.Constants.DECOR_TILE_MODEL_SCENE_ID,
        _G.CAMERA_TRANSITION_TYPE_IMMEDIATE, _G.CAMERA_MODIFICATION_TYPE_MAINTAIN, true)
    cell.model      = scene
    cell.modelActor = scene:GetActorByTag(HDG.Constants.DECOR_TILE_ACTOR_TAG)
    if not cell.modelActor then  -- exception(boundary): the scene's actors are Blizzard's data
        HDG.Log:Warn("model_preview", "tile model scene has no '" .. HDG.Constants.DECOR_TILE_ACTOR_TAG
            .. "' actor; decor with no icon shows the placeholder")
    end
    return scene
end

-- Draws the model in place of the icon. False when the scene has no actor to draw it.
local function _paintModel(cell, iconModel)
    _ensureModel(cell)
    local actor = cell.modelActor
    if not actor then return false end  -- exception(nullable): logged once per cell in _ensureModel
    actor:SetModelByFileID(iconModel)
    actor:SetDesaturation(0)
    actor:SetAlpha(1)
    cell.icon:Hide()
    cell.model:Show()
    return true
end

-- A pooled cell that drew a model before paints an icon now.
local function _hideModel(cell)
    if not cell.model then return end
    cell.model:Hide()
    if cell.modelActor then cell.modelActor:ClearModel() end
end

-- iconModel: the model file of decor with no icon (catalog row iconModel); it
-- wins over the texture, which is then only the "?" placeholder.
function M:PaintIcon(cell, iconTexture, iconAtlas, iconModel)
    if not cell or not cell.icon then return end
    if iconModel and _paintModel(cell, iconModel) then return end
    _hideModel(cell)
    if iconTexture and cell.icon.SetTexture then
        cell.icon:SetTexture(iconTexture)
        cell.icon:SetDesaturated(false)
        cell.icon:SetAlpha(1)
        cell.icon:Show()
    elseif iconAtlas and cell.icon.SetAtlas then
        cell.icon:SetAtlas(iconAtlas)
        cell.icon:SetDesaturated(false)
        cell.icon:SetAlpha(1)
        cell.icon:Show()
    else
        if cell.icon.SetTexture then cell.icon:SetTexture(HDG.Constants.PLACEHOLDER_ICON) end  -- exception(false-positive): Texture always has SetTexture; mock-fidelity guard
        cell.icon:Show()
    end
end

-- Greys the tile's picture, the icon or the model drawn in its place. Call after
-- PaintIcon, which paints both back to full colour.
function M:DimIcon(cell, dimmed)
    local alpha = dimmed and HDG.Constants.TILE_DIM_ALPHA or 1
    cell.icon:SetDesaturated(dimmed)
    cell.icon:SetAlpha(alpha)
    if cell.model and cell.model:IsShown() then
        cell.modelActor:SetDesaturation(dimmed and 1 or 0)
        cell.modelActor:SetAlpha(alpha)
    end
end

function M:PaintSelected(cell, isSelected)
    if not cell or not cell.bg then return end
    cell.bg:SetAtlas(isSelected and CELL_ATLAS_ACTIVE or CELL_ATLAS_DEFAULT)
end

function M:PaintCollected(cell, isCollected)
    if not cell then return end
    if cell.checkmark then cell.checkmark:SetShown(isCollected) end
    if cell.redX      then cell.redX:SetShown(not isCollected) end
end

function M:PaintBadge(cell, text, r, g, b)
    if not (cell and cell.badge) then return end
    if text and text ~= "" then
        cell.badge:SetText(text)
        if r and g and b then cell.badge:SetTextColor(r, g, b) end
        cell.badge:Show()
    else
        cell.badge:Hide()
    end
end

-- Set-membership count badge at TOPLEFT of a curator tile (item 12).
-- Idempotent: creates cell._memberBadge on first call, reuses thereafter.
-- count=0 hides the badge. Accent color applied via Theme at call site.
function M:PaintMemberBadge(cell, count)
    if not cell then return end
    if not cell._memberBadge then
        local fs = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetDrawLayer("OVERLAY", 7)                    -- above the cell's corner-frame chrome
        fs:SetPoint("TOPLEFT", cell, "TOPLEFT", 5, -4)   -- inset clear of the corner bracket (was 2,-2 -> clipped)
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 1)
        HDG.Theme:Register(fs, "TextStatus")  -- accent color (semantic.accent)
        cell._memberBadge = fs
    end
    if count and count > 0 then
        cell._memberBadge:SetText(count >= 5 and "5+" or tostring(count))
        cell._memberBadge:Show()
    else
        cell._memberBadge:Hide()
    end
end

-- ===== Scrollbox build =====================================================
-- Returns (host, scrollBar). scrollBox lives on host._scrollBox for SetItems.
function M:Create(parent, cfg)
    cfg = cfg or {}
    local merged = {}
    for k, v in pairs(DEFAULT_CFG) do merged[k] = v end
    for k, v in pairs(cfg) do merged[k] = v end

    local kindDef = merged.cellKind and self:GetCellKind(merged.cellKind)
    if not kindDef then
        error("CardGrid:Create requires a registered cellKind; got " ..
              tostring(merged.cellKind), 2)
    end

    -- fixedGutter: constant-width scrollbar gutter. A grid that holds an exact
    -- column count needs it (see M:SetColumns); default off (other grids want
    -- the reclaim). See CreateScrollBoxSkeleton.
    local host, scrollBox, scrollBar = HDG.UI:CreateScrollBoxSkeleton(parent, {
        fixedGutter = merged.fixedGutter,
    })
    local view = CreateScrollBoxListSequenceView(
        0, 0, 0, 0,
        merged.cellSpacing, merged.rowSpacing
    )

    -- Bind cfg into a stable closure ONCE (fresh closure per call would defeat Blizzard's pool).
    local boundInit = function(frame, elementData)
        kindDef.initFunc(frame, elementData, merged)
    end

    view:SetElementFactory(function(factory, _elementData)
        factory(kindDef.template, boundInit)
    end)

    view:SetElementSizeCalculator(function(_dataIndex, elementData)
        -- Full-width hook: { fullWidth=true, height=N } claims a whole row (reserved for mixed grids).
        if elementData.fullWidth then
            return 0, elementData.height or 20  -- exception(boundary): caller should stamp height
        end
        return merged.cellSize, merged.cellSize
    end)

    -- Resetter is load-bearing: hide + ClearAllPoints prevents stale cells from lingering
    -- at old positions when SetDataProvider shrinks the dataset. resetFunc runs after.
    view:SetFrameFactoryResetter(function(pool, frame, new)
        frame:Hide()
        frame:ClearAllPoints()
        if not new and kindDef.resetFunc then kindDef.resetFunc(pool, frame) end
    end)

    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    host._cardGridCfg  = merged
    host._cardGridView = view
    return host, scrollBar
end

-- SetItems: flat items[] -> DataProvider. retainScroll preserves position for in-place tweaks.
function M:SetItems(widget, items, retainScroll)
    local flag = retainScroll
        and ScrollBoxConstants.RetainScrollPosition
        or  ScrollBoxConstants.DiscardScrollPosition
    widget._scrollBox:SetDataProvider(CreateDataProvider(items or {}), flag)
    HDG.UI.RestoreListScroll(widget, widget._scrollBox)   -- refilled after the window closed
end

-- Live tile size: the size calculator and every cell init read the merged cfg,
-- so the next provider set lays the grid out at the new size.
function M:SetCellSize(widget, size)
    widget._cardGridCfg.cellSize = size
end

-- Exact column count, centred: pad both sides so the view's visible width holds
-- `columns` cells and no more (the sequence view wraps on visible width, and
-- GetVisibleWidth = box width - left - right padding). Returns true when the
-- padding moved.
local function _fitColumns(widget)
    local cols = widget._cardGridColumns
    local cfg  = widget._cardGridCfg
    local used = cols * cfg.cellSize + (cols - 1) * cfg.cellSpacing
    local side = math.max(0, math.floor((widget._scrollBox:GetWidth() - used) / 2))
    if side == widget._cardGridSide then return false end
    widget._cardGridSide = side
    widget._cardGridView:SetPadding(0, 0, side, side, cfg.cellSpacing, cfg.rowSpacing)
    return true
end

-- The window width follows the column setting, so the box only learns its new
-- width after the layout pass that follows the push; refit on every resize too.
-- An exact-columns grid must be built with fixedGutter: with the reclaim, the
-- bar's first show narrows the box from inside Blizzard's FullUpdateInternal,
-- which has OnSizeChanged switched off, so the refit never hears of it and the
-- old padding leaves room for one column fewer (companion, XL x 4 showed 3).
function M:SetColumns(widget, columns)
    widget._cardGridColumns = columns
    if not widget._cardGridFitHooked then
        widget._cardGridFitHooked = true
        widget._scrollBox:RegisterCallback(BaseScrollBoxEvents.OnSizeChanged, function()
            if _fitColumns(widget) then
                widget._scrollBox:FullUpdate(ScrollBoxConstants.UpdateImmediately)
            end
        end, widget)
    end
    _fitColumns(widget)
end

function M:Clear(widget)
    widget._scrollBox:SetDataProvider(CreateDataProvider({}))
end
