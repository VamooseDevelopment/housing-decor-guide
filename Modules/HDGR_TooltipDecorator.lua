-- HDG.TooltipDecorator
-- ============================================================================
-- per ADR-014: hook TooltipDataProcessor to append HDG lines to item tooltips.
-- Selectors stay pure; state reads happen inside the post-call hook boundary.
--
-- Four line families appended (best-effort; each skipped if data missing):
--   1. Decor catalog row -> "HDG: Decor (<expansion>) - <source>"
--   2. Queue presence    -> "HDG: In craft queue (Nx remaining)"
--   3. Reagent usage     -> "HDG: Used in N decor recipes"
--   4. Quantity picker   -> "Right-click to open Housing Decor Guide auto-buy assistant" (vendor item buttons)
-- Work per item: O(1) table lookups + O(queue-length) walk (queue caps ~30).

HDG = HDG or {}
HDG.TooltipDecorator = HDG.TooltipDecorator or {}
local TD = HDG.TooltipDecorator

-- HDG-branded prefix for tooltip lines: the addon icon inline (same glyph as the
-- bag-slot decor-reagent badge), replacing the old "HDG:" text tag. 14px matches
-- the COIN_ATLAS inline-icon convention. Kept as a function for call-site parity.
local HDG_ICON_INLINE = "|TInterface\\AddOns\\HousingDecorGuide\\textures\\Vamoose_HDG_400_trans:14:14|t "
local function ACCENT_PREFIX()
    return HDG_ICON_INLINE
end

-- Decor catalog line. row.vendors[1].name = first vendor (empty if none).
-- Expansion via GetExpansionForItem; a decor the catalog tags with no expansion
-- (the plain interior walls and doorways) still gets the line, without it.
local function decorLine(itemID)
    local row = HDG.HousingCatalogObserver:GetRow(itemID)
    if not row then return nil end
    local exp = HDG.HousingCatalogObserver:GetExpansionForItem(itemID)
    local head = exp and ("Decor (" .. exp .. ")") or "Decor"   -- exception(nullable): a decor tagged with no expansion
    local src = (row.vendors and row.vendors[1] and row.vendors[1].name) or ""
    if src ~= "" then
        return string.format("%s%s - %s", ACCENT_PREFIX(), head, src)
    end
    return ACCENT_PREFIX() .. head
end

-- At a vendor, on an item the quantity picker takes: how to open it. Gated on
-- the same check as the right-click itself, so an X'd visit shows no hint.
local function pickerLine(tooltip, itemID)
    local owner = tooltip:GetOwner()
    if not (owner and HDG.MerchantObserver:PickerHint(owner, itemID)) then return nil end   -- exception(nullable): a tooltip can have no owner
    return ACCENT_PREFIX() .. HDG.Locale:Get("QTYPICKER_HINT")
end

-- Queue presence line. Walks queue once; first match wins.
local function queueLine(itemID)
    local state = HDG.Store:GetState()
    local queue = state.account.craft.queue
    if not queue then return nil end
    for _, row in ipairs(queue) do
        if row.itemID == itemID and (row.remaining or 0) > 0 then  -- exception(boundary): queue row from SVars may lack remaining
            return string.format("%sIn craft queue (%dx remaining)",
                ACCENT_PREFIX(), row.remaining)
        end
    end
    return nil
end

-- Reagent-usage line. Shows count of housing-decor recipes using this item,
-- regardless of whether learned (flags useful bag reagents before recipe known).
-- Counted from recipes.reagentUsers (shipped recipes plus the player's own scans).
local function reagentLine(itemID)
    local byReagent = HDG.Selectors:Call("recipes.reagentUsers", HDG.Store:GetState(), {})
    local seen, n = {}, 0
    local function count(id)
        local users = byReagent[id]
        if not users then return end  -- exception(nullable): most items are no decor reagent
        for _, r in ipairs(users) do
            if not seen[r] then seen[r] = true; n = n + 1 end
        end
    end
    count(itemID)
    -- Tiered reagents: recipes list one quality tier, the player may hold another --
    -- union across the quality group so any tier shows the count (e.g. Dawn Crystal).
    local variants = HDG.StaticData.Professions:GetQualityVariants(itemID)
    if variants then for _, v in ipairs(variants) do count(v) end end
    if n == 0 then return nil end
    return string.format("%sUsed in %d decor recipe%s", ACCENT_PREFIX(), n, n == 1 and "" or "s")
end

-- ===== Debug: icon marker inspector =========================================
-- When debug mode is on, list every ADDON marker stuck to an item button by its
-- /framestack-style name, so overlapping overlays (HDG's own mark, CanIMogIt's
-- CIMIOverlayFrame, ...) are identifiable inline without opening /fstack. We show
-- the raw fsobj name -- the name already identifies the addon (CIMI... = CanIMogIt,
-- _hdgr... = HDG); no translation table needed. Blizzard's own button regions are
-- filtered by key/name so only foreign (addon) markers remain.
local NATIVE_KEYS = {
    icon = true, IconTexture = true, IconBorder = true, IconOverlay = true,
    IconOverlay2 = true, NormalTexture = true, HighlightTexture = true,
    PushedTexture = true, Count = true, count = true, stock = true, Stock = true,
    searchOverlay = true, SearchOverlay = true, ItemContextOverlay = true,
    Cooldown = true, cooldown = true, ProfessionQualityOverlay = true,
    UpgradeIcon = true, JunkIcon = true, NewActionTexture = true, flash = true,
    Name = true, name = true, ItemLevel = true, BattlepayItemTexture = true,
}

local function _isVisualObject(v)
    return type(v) == "table" and type(v.GetObjectType) == "function"
        and type(v.IsShown) == "function"
end

-- Addon markers shown on `button`, each { name = <fsobj key/global name>, obj }.
-- Keyed overlays use their key (HDG's _hdgrMerchantMark, EnhanceQoL's
-- MerchantKnownOverlay); named siblings use their global name (CanIMogIt's
-- CIMIOverlayFrame_<button>). Blizzard names its own sub-regions "<button><suffix>",
-- so a global name that starts with the button name is native and skipped.
local function _iconMarkers(button)
    local buttonName = button.GetName and button:GetName() or nil
    local out, seen = {}, {}
    local function add(obj, name)
        if seen[obj] then return end
        seen[obj] = true
        out[#out + 1] = { name = name, obj = obj }
    end
    for key, v in pairs(button) do
        if type(key) == "string" and not NATIVE_KEYS[key]
           and _isVisualObject(v) and v:IsShown() then
            add(v, key)
        end
    end
    local function scanNamed(list)
        for _, obj in ipairs(list) do
            local n = obj.GetName and obj:GetName()
            if n and obj:IsShown()
               and (not buttonName or n:sub(1, #buttonName) ~= buttonName) then
                add(obj, n)
            end
        end
    end
    scanNamed({ button:GetChildren() })
    scanNamed({ button:GetRegions() })
    return out
end

-- fsobj -> owning addon, fully automatic (no maintained list). Two signals:
--   1. the fsobj name contains a loaded addon's folder name (CanIMogItOverlay -> CanIMogIt)
--   2. the marker's texture is a file under Interface/AddOns/<Addon>/
-- Returns the addon name, or nil when neither fires -- the caller then shows the raw
-- fsobj name, which usually identifies the addon on its own (_hdgr..., MerchantKnown...).
local _loadedAddons   -- cached folder names, longest-first (specific wins)
local function _loadedAddonList()
    if _loadedAddons then return _loadedAddons end
    _loadedAddons = {}
    local api = _G.C_AddOns
    local num = (api and api.GetNumAddOns and api.GetNumAddOns()) or 0   -- exception(boundary): C_AddOns API
    for i = 1, num do
        if api.IsAddOnLoaded(i) then
            local name = api.GetAddOnInfo(i)
            if name and #name >= 4 then _loadedAddons[#_loadedAddons + 1] = name end
        end
    end
    table.sort(_loadedAddons, function(a, b) return #a > #b end)
    return _loadedAddons
end

-- Addon folder from a custom texture path on the object (or its child regions).
local function _addonFromTexture(obj)
    local function fromPath(t)
        return type(t) == "string" and t:match("[Aa][Dd][Dd][Oo][Nn][Ss][/\\]([^/\\]+)") or nil
    end
    if obj.GetTexture then local a = fromPath(obj:GetTexture()); if a then return a end end
    if obj.GetRegions then
        for _, r in ipairs({ obj:GetRegions() }) do
            if r.GetTexture then local a = fromPath(r:GetTexture()); if a then return a end end
        end
    end
    return nil
end

local function _resolveAddon(name, obj)
    for _, addon in ipairs(_loadedAddonList()) do
        if name:find(addon, 1, true) then return addon end
    end
    return _addonFromTexture(obj)   -- may be nil (caller shows raw fsobj name)
end

function TD:DecorateItemTooltip(tooltip, tooltipData)
    if not (tooltip and tooltipData and tooltipData.id) then return end
    if not tooltip.AddLine then return end
    local itemID = tooltipData.id
    local lines = {}
    -- Decor + reagent lines gated on TOOLTIP_DECOR_TAG config.
    -- Queue line is a live craft helper and is always shown.
    if HDG.Config:Get("TOOLTIP_DECOR_TAG") then
        local d = decorLine(itemID);   if d then lines[#lines + 1] = d end
        local r = reagentLine(itemID); if r then lines[#lines + 1] = r end
    end
    local q = queueLine(itemID); if q then lines[#lines + 1] = q end
    local p = pickerLine(tooltip, itemID); if p then lines[#lines + 1] = p end
    for _, line in ipairs(lines) do
        tooltip:AddLine(line, 1, 1, 1, false)   -- white, no wrap
    end

    -- Debug only: name every addon marker sitting on the item's button, so
    -- overlapping overlays across addons are identifiable inline. Gated on the
    -- Button owner (skips UIParent/link-hover tooltips with no button).
    if HDG.Config:Get("DEBUG") then
        local owner = tooltip.GetOwner and tooltip:GetOwner()
        if owner and owner ~= _G.UIParent and owner.GetObjectType
           and owner:GetObjectType() == "Button" then
            local markers = _iconMarkers(owner)
            if #markers > 0 then
                -- Roll up fsobj -> addon: one line per addon, listing its markers.
                local order, groups = {}, {}
                for _, m in ipairs(markers) do
                    local addon = _resolveAddon(m.name, m.obj)
                    local key = addon or m.name   -- unresolved: its own raw-name line
                    local g = groups[key]
                    if not g then g = { addon = addon, names = {} }; groups[key] = g; order[#order + 1] = key end
                    g.names[#g.names + 1] = m.name
                end
                tooltip:AddLine("HDG debug -- icon markers:", 0.55, 0.75, 1.0, false)
                for _, key in ipairs(order) do
                    local g = groups[key]
                    local text = g.addon and (g.addon .. " (" .. table.concat(g.names, ", ") .. ")") or g.names[1]
                    tooltip:AddLine("  - " .. text, 0.7, 0.7, 0.7, false)
                end
            end
        end
    end
end

function TD:Install()
    if self._installed then return end
    local tdp  = _G.TooltipDataProcessor
    local enum = _G.Enum and _G.Enum.TooltipDataType
    if not (tdp and tdp.AddTooltipPostCall and enum and enum.Item) then return end
    tdp.AddTooltipPostCall(enum.Item, function(tooltip, data)
        -- Gotcha: C_TooltipInfo can leak secret-string taint in 12.0.5;
        -- string-ops on tainted data poison the caller. pcall isolates us.
        local ok, err = pcall(function() TD:DecorateItemTooltip(tooltip, data) end)
        if not ok then HDG.Log:Warn("tooltip", tostring(err)) end
    end)
    self._installed = true
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "TooltipDecorator",
    dependencies = {},
    onEnable = function(self)
        TD:Install()
    end,
})
