-- HDGR_CatalogOverlay.lua
-- ============================================================================
-- Marks UNCOLLECTED decor in Blizzard's Housing catalog grid with a small red
-- plus in the top-right corner of the cell -- the collection gaps in your own
-- browser. Companion to the catalog tooltip (which adds sourcing on hover).
--
-- Why this isn't redundant with Blizzard's corner number: that number is the
-- *storage* count only. A decor you own but have PLACED shows no number (Total
-- Owned 1 / Placed 1 / Storage 0), so "no number" does NOT mean uncollected.
-- Total owned (stored + redeemable + placed) is the correct signal, so the plus
-- lands only on decor you genuinely don't have yet.
--
-- Surface: Blizzard_HousingTemplates' HousingCatalogDecorEntryMixin (loads on
-- demand when the catalog opens). Hooks UpdateTypeSpecificVisuals -- the decor
-- cell's own per-cell paint, the SAME method Blizzard uses to toggle the dye
-- palette badge (CustomizeIcon), so it fires reliably for every decor cell, and
-- again whenever the cell's entry data changes. Reads ownership from the cell's
-- own entry data, not HDG's catalog. Gated by CATALOG_DECOR_OVERLAY.

HDG = HDG or {}

local CO = {}
HDG.CatalogOverlay = CO

local MARK_SIZE    = 14
local ATLAS_NEEDED = "common-icon-plus"

local function enabled()
    return HDG.Config:Get("CATALOG_DECOR_OVERLAY") == true
end

-- True for a decor cell the player owns no copy of, read from the cell's own
-- entryInfo -- the live data Blizzard draws this tile's count from -- through
-- Blizzard's own owned math (GetEntryTotalOwned = stored + redeemable + placed).
-- Not HDG's catalog: in the house editor with HDG's window closed, that cache can
-- be built before the game has sent storage data and holds 0 until the window
-- opens, which put the plus on every owned piece (2026-10-08). The tile can't
-- disagree with itself.
local function _needsMark(cell)
    if not cell.entryVariantID then return false end   -- exception(boundary): Blizzard cell field; nil on a bundle cell
    local info = cell.entryInfo
    if not info then return false end   -- exception(boundary): Blizzard cell field; nil between ClearEntryData and the next fill
    return Blizzard_HousingCatalogUtil.GetEntryTotalOwned(info) == 0
end
CO._needsMark = _needsMark   -- exposed for tests

local function _ensureMark(cell)
    local mark = cell._hdgrCatalogMark
    if not mark then
        mark = cell:CreateTexture(nil, "OVERLAY", nil, 7)   -- above icon/border/count
        mark:SetSize(MARK_SIZE, MARK_SIZE)
        mark:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 1, 1)
        mark:SetAtlas(ATLAS_NEEDED, false)
        mark:SetVertexColor(1, 0.10, 0.10)   -- red (gold plus tints to red, pops vs the gold UI)
        cell._hdgrCatalogMark = mark
    end
    return mark
end

-- Runs after every decor cell paint. Blizzard re-paints a cell whenever its entry
-- data changes (a decor collected, placed or destroyed), so the mark follows
-- ownership with no repaint of our own.
local function _onCellPaint(cell)
    if enabled() and _needsMark(cell) then
        _ensureMark(cell):Show()
    elseif cell._hdgrCatalogMark then
        cell._hdgrCatalogMark:Hide()
    end
end
CO._onCellPaint = _onCellPaint   -- exposed for tests

function CO:Install()
    if self._installed then return end
    if not (HousingCatalogDecorEntryMixin and HousingCatalogDecorEntryMixin.UpdateTypeSpecificVisuals) then return end
    self._installed = true
    hooksecurefunc(HousingCatalogDecorEntryMixin, "UpdateTypeSpecificVisuals", _onCellPaint)
end

HDG.Modules:Declare({
    name = "CatalogOverlay",
    dependencies = {},
    onEnable = function()
        -- HousingCatalogDecorEntryMixin lives in Blizzard_HousingTemplates, loaded
        -- on demand when the catalog first opens. Install once it's present (the
        -- cell template is in that addon, so the hook always beats cell creation).
        HDG.BlizzardEvents:_internalSubscribe("ADDON_LOADED", function()
            CO:Install()
        end)
        if HousingCatalogDecorEntryMixin then CO:Install() end   -- already loaded
    end,
})
