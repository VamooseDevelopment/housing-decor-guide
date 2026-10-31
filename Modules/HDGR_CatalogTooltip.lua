-- HDG.CatalogTooltip
-- ============================================================================
-- Appends HDG's decor-sourcing block to Blizzard's Housing Dashboard tooltip,
-- under a "Housing Decor Guide - Decor sourcing:" header. Lists the same source
-- data that drives the decor-browser chips -- achievement / quest / reputation /
-- promotion / shop / drop / vendor(s) -- with the cost on the last line.
--
-- Uses Blizzard's own extension event HousingCatalogEntry.TooltipCreated, fired
-- by HousingCatalogEntryMixin:OnEnter right before GameTooltip:Show(). Additive
-- lines on the live GameTooltip -- no hooksecurefunc, no taint. The hovered cell
-- carries entryVariantID.recordID; resolve to an itemID via the catalog observer
-- (O(1) byItemID facade) and read the baked source fields at hover time. Colours
-- are inline because GameTooltip lives outside HDG's Theme registry.

HDG = HDG or {}
HDG.CatalogTooltip = HDG.CatalogTooltip or {}
local M = HDG.CatalogTooltip

local HEAD_R,   HEAD_G,   HEAD_B   = 1.0,  0.82, 0.0   -- HDG-brand gold header
local VENDOR_R, VENDOR_G, VENDOR_B = 0.55, 0.78, 1.0   -- "where to buy" blue (matches companion)
local COST_R,   COST_G,   COST_B   = 0.78, 0.78, 0.6   -- muted gold (matches companion cost line)
local GATE_R,   GATE_G,   GATE_B   = 0.82, 0.82, 0.82  -- achievement / quest / rep / promo / shop / drop

-- "Drop: <source> -- <zone>" for a {source, zone} record (drop/treasure/event); nil if absent.
local function _sourceLine(label, rec)
    if not rec then return nil end   -- exception(nullable): this source kind absent on the row
    local z = (rec.zone and rec.zone ~= "") and (" in " .. rec.zone) or ""
    local act = rec.activity and (" from " .. rec.activity) or ""   -- exception(nullable): the catalog names an activity on a few records only
    return label .. ": " .. rec.source .. z .. act
end

-- Gate lines: achievement / quest / reputation / promo / shop / drop-or-
-- treasure-or-event. `add(text, r, g, b)` appends one colored body line.
local function _appendCatalogGateLines(add, row)
    if row.achievement then add("Achievement: " .. row.achievement, GATE_R, GATE_G, GATE_B) end
    if row.quest       then add("Quest: " .. row.quest, GATE_R, GATE_G, GATE_B) end
    if row.factionGate then
        local fg = row.factionGate
        local s  = (fg.standing and fg.standing ~= "") and (" (" .. fg.standing .. ")") or ""
        add("Reputation: " .. fg.factionName .. s, GATE_R, GATE_G, GATE_B)
    end
    if row.promo then add("Promotion", GATE_R, GATE_G, GATE_B) end
    if row.shop  then add("In-Game Shop", GATE_R, GATE_G, GATE_B) end
    local drop = _sourceLine("Drop", row.drop) or _sourceLine("Treasure", row.treasure) or _sourceLine("Event", row.event)
    if drop then add(drop, GATE_R, GATE_G, GATE_B) end
end

-- Vendor lines: list every vendor once (catalog + override can list one 2-3x).
-- "world vendor" names sort last so the named vendor leads.
local function _appendCatalogVendorLines(add, vendors)
    local named, world, seen = {}, {}, {}
    for _, v in ipairs(vendors) do
        local label = "Vendor: " .. v.name .. ((v.zone and v.zone ~= "") and (" in " .. v.zone) or "")
        if not seen[label] then
            seen[label] = true
            if v.name:lower():find("world vendor", 1, true) then
                world[#world + 1] = label
            else
                named[#named + 1] = label
            end
        end
    end
    for _, l in ipairs(named) do add(l, VENDOR_R, VENDOR_G, VENDOR_B) end
    for _, l in ipairs(world) do add(l, VENDOR_R, VENDOR_G, VENDOR_B) end
end

-- The dyed line, under the sourcing, for THE TILE UNDER THE CURSOR: every dyed
-- variant is its own tile in Blizzard's catalog, so the hover names that one
-- variant's dyes -- each NAME painted in its own swatch colour (the Companion's
-- droplets read the same swatchColorStart) -- and its stored count. Listing
-- every owned variant here was wrong (3.29.0: a player with hundreds of one
-- table dyed got the whole inventory on every hover). The tile's "Total Owned"
-- is the aggregate across colours; the count here is this colour's own.
local function _dyeNameMarkup(Obs, dyeColorID)
    local info = Obs:GetDyeColorInfo(dyeColorID)
    if not info then return nil end   -- exception(boundary): C_DyeColor returns nil for an unknown id
    local r, g, b = info.swatchColorStart:GetRGB()
    return ("|cff%02x%02x%02x%s|r"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), info.name)
end

local function _appendCatalogDyeLine(add, Obs, dyedVariants, variantIdentifier)
    for _, dv in ipairs(dyedVariants) do
        if dv.variantIdentifier == variantIdentifier then
            local names = {}
            for _, id in ipairs(dv.dyeColorIDs) do
                names[#names + 1] = _dyeNameMarkup(Obs, id) or dv.label
            end
            add(("Dyed: %s x%d"):format(table.concat(names, ", "), dv.numStored), GATE_R, GATE_G, GATE_B)
            return
        end
    end
end

-- Cost line (last of the sourcing): every price the vendors take, as the detail
-- shows it (30 coupons OR 500g). The head vendor's price alone hid the others.
local function _appendCatalogCostLine(add, row)
    local variants = row.costVariants
    if #variants == 0 then return end   -- exception(nullable): item has no vendor cost
    add("Cost: " .. table.concat(variants, "  or  "), COST_R, COST_G, COST_B)
end

local function _onTooltipCreated(_, entry, tooltip)
    if not HDG.Store:GetConfig("catalogTooltip") then return end   -- Helpers toggle: user disabled the sourcing tooltip
    local vid = entry.entryVariantID   -- exception(boundary): Blizzard cell mixin field; nil on non-decor entries
    local recordID = vid and vid.recordID
    if not recordID then return end    -- exception(boundary): bundle/non-decor cell carries no recordID
    local Obs = HDG.HousingCatalogObserver
    -- Warm the catalog if the main window hasn't opened yet (idempotent cold-start,
    -- no-op unless idle). First hover kicks the sweep; data fills in on later hovers.
    Obs:RequestLoad("catalog-tooltip")
    local itemID = Obs:GetItemIDByDecorID(recordID)
    if not itemID then return end      -- exception(nullable): decor not mapped in HDG's catalog
    local row = Obs:GetRow(itemID)
    if not row then return end         -- exception(nullable): row not swept yet

    -- Collect the sourcing lines first so the header only prints when there's content.
    local body = {}   -- { {text, r, g, b}, ... }
    local function add(text, r, g, b) body[#body + 1] = { text = text, r = r, g = g, b = b } end

    _appendCatalogGateLines(add, row)
    if row.vendors and #row.vendors > 0 then   -- exception(nullable): item has no vendor source
        _appendCatalogVendorLines(add, row.vendors)
    end
    _appendCatalogCostLine(add, row)
    -- variantIdentifier 0 is the undyed base tile: nothing to name.
    if row.dyedVariants and vid.variantIdentifier ~= 0 then   -- exception(nullable): non-customizable decor bakes no variants
        _appendCatalogDyeLine(add, Obs, row.dyedVariants, vid.variantIdentifier)
    end

    if #body == 0 then return end   -- nothing HDG can add -> leave Blizzard's tooltip untouched
    tooltip:AddLine("Housing Decor Guide - Decor sourcing:", HEAD_R, HEAD_G, HEAD_B)
    for _, l in ipairs(body) do tooltip:AddLine(l.text, l.r, l.g, l.b) end
end

-- Register at file-load: the callback fires at hover time, when the observer is warm.
EventRegistry:RegisterCallback("HousingCatalogEntry.TooltipCreated", _onTooltipCreated, M)
