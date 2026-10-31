-- HDG.TooltipEngine
-- ============================================================================
-- Drives Blizzard's GameTooltip from declarative `tooltip` fields on widgets.
-- NOT a custom rendering surface -- thin shim over GameTooltip's own API.
--
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 17.3.
-- Recipe registry: Core/HDGR_TooltipRecipes.lua (every tooltip in HDG).
-- Migration reference: VamoosesDyeStudio/docs/VDS_TOOLTIP_MIGRATION.md.
--
-- ===== The `tooltip` field shape (from a LayoutConfig widget spec) =========
--
-- The validator in UI/HDGR_Layout.lua (Layout:Validate) accepts:
--
--   tooltip = false                       -- explicit no-tooltip (no-op)
--   tooltip = { recipe = "RecipeName" }   -- look up in HDG.TooltipRecipes
--
-- For ad-hoc / testing / non-LayoutConfig sites, this engine ALSO accepts
-- (bypassing the validator):
--
--   tooltip = { title = "...", body = "...", anchor = "...", ... }   -- inline def
--   tooltip = function(self) return { ... } end                       -- inline function
--
-- All four shapes resolve to a final def table:
--   { title?, body?, anchor?, itemID?, hyperlink?, extraLines?, textFn? }
--
-- ===== The resolved def table shape ========================================
--
--   title      -- string, first line
--   body       -- string, second line (wrap=true)
--   anchor     -- "ANCHOR_RIGHT" (default), "ANCHOR_BOTTOM", "ANCHOR_LEFT", etc.
--   itemID     -- numeric; uses GameTooltip:SetItemByID (Blizzard fills body)
--   hyperlink  -- string; uses GameTooltip:SetHyperlink
--   extraLines -- array of strings OR { text, r?, g?, b?, wrap?, right?, rr?, rg?, rb? }
--                 tables (color channels optional per line; unset = white; wrap
--                 defaults true, opt-out wrap = false). A `right` value is the only
--                 switch: with it the line renders two-column via AddDoubleLine
--                 (label | value, right colors = rr/rg/rb); without it, AddLine.
--   textFn     -- function(widget) -> string | { string, ... }; called at hover
--                 time for dynamic content. LEGACY: prefer making the whole def
--                 a function (above) so the entire def is dynamic, not just text.
--
-- Reference: spec section 1.3 (contract-vs-engines principle). The tooltip
-- TEXT is declarative (contract); the RENDERING is an engine call.

HDG = HDG or {}
HDG.TooltipEngine = HDG.TooltipEngine or {}

local TE = HDG.TooltipEngine

-- ===== Blizzard's tooltip colours ===========================================
-- HDG never re-skins GameTooltip, so its background is always near-black, and
-- the light schemes' dark greens and teals would vanish on it. A line that needs
-- a colour takes Blizzard's own (GlobalColor DB2, live 12.1.0.69814), never the
-- scheme's; everything else stays tooltip white.
TE.COLOR = {
    NORMAL = { r = 1, g = 0.82, b = 0 },   -- NORMAL_FONT_COLOR: the name a tooltip is about
}

-- Resolve a possibly-"locale:KEY"-prefixed tooltip string to localised text at
-- render (hover) time, so recipe defs can carry locale keys and switch live --
-- no /reload, unlike build-time static LayoutConfig text. Plain strings pass through.
local function _loc(s)
    if HDG.Locale then return HDG.Locale:Resolve(s) end  -- exception(boundary): Locale load-order partial in headless tests
    return s
end

-- ===== Click-hint lines (shared: clickHints widget + row tooltips) ==========
-- Build the click-hint display lines from a {leftText/dragText/rightText/shiftText}
-- spec, resolving any "locale:KEY" values at call time. Mouse actions are prefixed
-- with the same housing-hotkey glyphs the header clickHints widget shows (inline
-- atlas markup); Shift-click reads as "Shift-" + the left-click glyph, since the
-- actual input is shift held while left-clicking. One source of truth so the
-- header widget and per-row tooltips never word the same action differently.
local GLYPH_LEFT  = "|A:housing-hotkey-icon-leftclick:14:14|a "
local GLYPH_RIGHT = "|A:housing-hotkey-icon-rightclick:14:14|a "
function TE.ClickHintLines(spec)
    local out = {}
    if spec.leftText  then out[#out + 1] = GLYPH_LEFT  .. _loc(spec.leftText)  end
    if spec.dragText  then out[#out + 1] = GLYPH_LEFT  .. "drag: " .. _loc(spec.dragText) end
    if spec.rightText then out[#out + 1] = GLYPH_RIGHT .. _loc(spec.rightText) end
    if spec.shiftText then out[#out + 1] = "Shift-" .. GLYPH_LEFT .. _loc(spec.shiftText) end
    if spec.ctrlText  then out[#out + 1] = "Ctrl-"  .. GLYPH_LEFT .. _loc(spec.ctrlText)  end
    if spec.ctrlShiftText then out[#out + 1] = "Ctrl-Shift-" .. GLYPH_LEFT .. _loc(spec.ctrlShiftText) end
    return out
end

-- Append click-hint lines (after a blank spacer) to a tooltip `extras` array, in
-- tooltip white: grey hints were hard to read in game (owner 10-31), and the
-- spacer and mouse glyph already set them apart. No-op when spec is nil --
-- pooled rows that don't stamp _clickHints (e.g. recipe/queue rows that share
-- R.RecipeRow with the goblin scanner) get no hints.
function TE.AppendClickHints(extras, spec)
    if not spec then return end  -- exception(nullable): per-row _clickHints stamp is optional
    if #extras > 0 then extras[#extras + 1] = " " end  -- blank spacer above the hints
    for _, line in ipairs(TE.ClickHintLines(spec)) do
        extras[#extras + 1] = { text = line, r = 1, g = 1, b = 1 }
    end
end

-- ===== Internal helpers ===================================================

-- Resolve a tooltip def to a final TE table.
--   false              -> nil          (explicit no-tooltip)
--   { recipe = name }  -> registry[name] resolved recursively (recipe value
--                          may itself be table | function | string-shorthand)
--   table              -> table        (inline def)
--   function           -> call(widget) and recurse on result
--   anything else      -> nil + loud warn
local function resolveDef(widget, def)
    if def == false then return nil end
    if def == nil   then return nil end

    if type(def) == "table" and def.recipe then
        local name = def.recipe
        local recipe = HDG.TooltipRecipes[name]
        if recipe == nil then
            -- Validator should have caught typos at boot; if we hit this at
            -- runtime, the call site bypassed validation or the registry was
            -- mutated after boot. Surface loudly per "no defensive guards" --
            -- but don't crash the hover; just skip the tooltip.
            HDG.Log:Warn("tooltip", string.format(
                "TE:resolveDef recipe %q not found in HDG.TooltipRecipes", tostring(name)))
            return nil
        end
        return resolveDef(widget, recipe)
    end

    if type(def) == "function" then
        -- Strict call (ADR-042): defs are internal registered code; a throwing
        -- def is a bug that must surface through the script-handler error path,
        -- not rot behind a per-def pcall (isolation class removed 2026-06-12).
        return resolveDef(widget, def(widget))
    end

    if type(def) == "table" then return def end

    HDG.Log:Warn("tooltip", string.format(
        "TE:resolveDef unexpected def type %q", type(def)))
    return nil
end

-- Render a resolved def to GameTooltip.
-- Custom extraLines block appended below the Blizzard body. Per-line shape:
-- a string wraps; a table carries optional per-channel colors (default white)
-- and a `right` value switch (AddDoubleLine label|value vs plain AddLine, wrap
-- default-on). Intentional API contract, not defensive drift.
local function _renderTooltipExtraLines(tooltip, lines)
    for _, line in ipairs(lines) do
        if type(line) == "string" then
            tooltip:AddLine(_loc(line), 1, 1, 1, true)
        elseif type(line) == "table" and line.right ~= nil then
            tooltip:AddDoubleLine(_loc(line.text), _loc(line.right),
                line.r or 1, line.g or 1, line.b or 1,
                line.rr or 1, line.rg or 1, line.rb or 1)
        elseif type(line) == "table" then
            tooltip:AddLine(_loc(line.text),
                line.r or 1, line.g or 1, line.b or 1,
                line.wrap ~= false)  -- exception(optional): tooltip line.wrap absent = default-on per extraLines protocol
        end
    end
end

-- LEGACY textFn shape: whole-def function form is preferred (entire def dynamic,
-- not just text). Kept for backward-compat; DELETE when no call sites remain.
local function _renderTooltipLegacyTextFn(tooltip, widget, textFn)
    local dyn = textFn(widget)   -- strict (ADR-042): internal registered code, fail loud
    if type(dyn) == "string" then
        tooltip:AddLine(dyn, 1, 1, 1, true)
    elseif type(dyn) == "table" then
        for _, line in ipairs(dyn) do
            if type(line) == "string" then
                tooltip:AddLine(line, 1, 1, 1, true)
            end
        end
    end
end

local function renderTooltip(widget, t)
    local tooltip = _G.GameTooltip                                            -- exception(boundary): Blizzard global
    if not tooltip then return end

    tooltip:SetOwner(widget, t.anchor or "ANCHOR_RIGHT")

    -- Item / hyperlink: Blizzard fills the body. Custom title/body/extras
    -- are appended below the Blizzard-rendered block.
    if t.itemID then
        tooltip:SetItemByID(t.itemID)
    elseif t.hyperlink then
        tooltip:SetHyperlink(t.hyperlink)
    end

    if t.title then tooltip:AddLine(_loc(t.title)) end
    if t.body  then tooltip:AddLine(_loc(t.body), 1, 1, 1, true) end   -- wrap=true
    if t.extraLines then _renderTooltipExtraLines(tooltip, t.extraLines) end
    if t.textFn     then _renderTooltipLegacyTextFn(tooltip, widget, t.textFn) end

    tooltip:Show()
end

-- ===== Public API =========================================================

-- Attach OnEnter/OnLeave handlers to a widget.
--
-- def shapes accepted (see file header for the full grammar):
--   false                          -> no-op (idiomatic for spec.tooltip = false)
--   { recipe = "Name" }            -> registry lookup
--   { title = ..., body = ..., ... } -> inline def
--   function(self) -> def | nil    -> inline function
--
-- HookScript (not SetScript) so any existing OnEnter/OnLeave wiring (visual
-- hover state, e.g. a row's highlight texture) isn't clobbered.
--
-- Per-widget _hdgrTooltipAttached flag prevents double-wiring when a pooled
-- widget is re-attached (every pool acquire would otherwise add another
-- HookScript callback, leading to N tooltip renders per hover).
function TE:Attach(widget, def)
    if not widget then return end
    if def == false or def == nil then return end                             -- no-op shapes
    if not widget.HookScript then return end                                  -- exception(boundary): Blizzard widget
    -- Stash the def on the widget and read it LIVE in the hook. A re-attach
    -- (pooled widget re-acquired for a different row/item) REFRESHES the def;
    -- the OnEnter/OnLeave hooks still install exactly once. This makes the
    -- "per-acquire closure frozen on the first item a pooled cell ever showed"
    -- stale-tooltip bug structurally impossible -- the idempotent guard below
    -- used to capture the FIRST def forever (acqVendorItemTile, 2026-06-06).
    widget._hdgrTooltipDef = def
    if widget._hdgrTooltipAttached then return end                            -- hook once (def already refreshed above)
    widget._hdgrTooltipAttached = true

    widget:HookScript("OnEnter", function(self)
        TE._enterCount = (TE._enterCount or 0) + 1                            -- diagnostic
        local resolved = resolveDef(self, self._hdgrTooltipDef)
        if resolved then renderTooltip(self, resolved) end
    end)
    widget:HookScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end  -- exception(boundary): GameTooltip is a Blizzard global; nil in headless tests
    end)
end

-- Explicit show (e.g. focus on a widget without hover). Caller is responsible
-- for hiding via GameTooltip:Hide() or TE:Hide().
function TE:Show(widget, def)
    if def == false or def == nil then return end
    local resolved = resolveDef(widget, def)
    if resolved then renderTooltip(widget, resolved) end
end

-- Hide the current tooltip. Convenience over reaching for the global.
function TE:Hide()
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

-- ===== Diagnostics ========================================================
