-- HDG.Format
-- ============================================================================
-- Presentation render-primitives. Pure functions; no data of its own.
-- Loads after Constants; consumed by the observer bake and by selectors.
-- FormatCurrency's C_CurrencyInfo fallback is a legitimate boundary call (observer bake, not selector).

HDG = HDG or {}
HDG.Format = HDG.Format or {}

local F = HDG.Format

-- Scheme-invariant brand prefix (shaman class blue, |cff0070dd). The universal
-- chat tag: every HDG chat line from any source opens with it. Single
-- definition -- Log.lua and Init.lua reference this so the token can never
-- drift between surfaces.
F.BRAND_PREFIX = "|cff0070dd[HDG]|r"

-- Import dates arrive as a unix timestamp (wowdb: 1777074521) or an already-
-- formatted string (wowhead: "2026-03-10"). Render both as YYYY-MM-DD; a string
-- date (has dashes -> tonumber nil) passes through unchanged. nil/empty -> nil.
function F.FriendlyDate(d)
    if d == nil or d == "" then return nil end
    local n = tonumber(d)
    if n and n > 1000000000 and _G.date then  -- exception(boundary): unix ts rendered through WoW's `date` global (os.date alias)
        return _G.date("%Y-%m-%d", n)
    end
    return tostring(d)
end

-- Returns "" for zero/nil. FormatGoldZero is the zero-visible variant (column-aligned tables).
--   FormatAmount(n)              -> "1,234"  (commas, suppress zero)
--   FormatCurrency(amount, cid)  -> "1,234 <icon>"
--   CurrencyName(cid)            -> "Ancient Mana" / "Gold" / nil
--   FormatGold(copper)           -> FormatCurrency(gold, CURRENCY_GOLD)
--   FormatCost(amount, e)        -> "1,234 <icon>" for a currency OR item-token cost entry
--   CostName(e)                  -> "Mark of Honor" / "Ancient Mana" / "Gold" / nil
--   CostKey(e)                   -> "item:137642" / "currency:3363" / "currency:-1"
--   FormatRecipeCost(source)     -> "1 Secret of Draenor Tailoring" / "400 <icon>" (recipe source price)

function F.FormatAmount(n)
    if not n or n <= 0 then return "" end
    return _G.BreakUpLargeNumbers and _G.BreakUpLargeNumbers(n) or tostring(n)
end

-- One ladder for anything that describes a currency by ID: the curated housing
-- table first (name + icon, no client call), then the live client for IDs the
-- table does not track. Returns { name, icon } or nil for an ID neither source
-- knows -- callers render the raw id at that seam so a missing entry is visible
-- rather than blank.
local _trackedCurrency
local function _currencyInfo(currencyID)
    if not _trackedCurrency then
        _trackedCurrency = {}
        for _, c in ipairs(HDG.Constants.HOUSING_DECOR_CURRENCY_DATA) do
            _trackedCurrency[c.id] = { name = c.name, icon = c.icon }
        end
    end
    local tracked = _trackedCurrency[currencyID]
    if tracked then return tracked end
    if not (_G.C_CurrencyInfo and _G.C_CurrencyInfo.GetCurrencyInfo) then return nil end  -- exception(boundary): C_CurrencyInfo absent in headless tests
    local info = _G.C_CurrencyInfo.GetCurrencyInfo(currencyID)
    if not info then return nil end  -- exception(boundary): GetCurrencyInfo nil for unknown currencyIDs
    return { name = info.name, icon = info.iconFileID }
end

function F.FormatCurrency(amount, currencyID, iconOverride)
    local n = F.FormatAmount(amount)
    if n == "" then return "" end
    if currencyID == HDG.Constants.CURRENCY_GOLD then
        return n .. " " .. HDG.Constants.COIN_ATLAS
    end
    -- Catalog icon wins (always correct). Curated table + live API are fallbacks for ItemAugment costs.
    local icon = iconOverride
    if not icon then
        local info = _currencyInfo(currencyID)
        icon = info and info.icon  -- exception(nullable): untracked and unknown to the client
    end
    if icon then return n .. " |T" .. icon .. ":14:14|t" end
    -- Final fallback: bare number with the raw id so missing tracking is
    -- visible at the UI seam instead of silently rendering as "1234".
    return n .. " (#" .. tostring(currencyID) .. ")"
end

-- Display name for a cost line. Gold is the sentinel, not a client currency.
-- nil when neither the curated table nor the client knows the ID; the caller
-- prints "#<id>" there for the same reason FormatCurrency does.
function F.CurrencyName(currencyID)
    if currencyID == HDG.Constants.CURRENCY_GOLD then return HDG.Constants.GOLD_NAME end
    local info = _currencyInfo(currencyID)
    return info and info.name  -- exception(nullable): untracked and unknown to the client
end

-- A cost entry is EITHER a currency ({ currencyID, amount, icon }; gold is the -1
-- sentinel) OR an item token ({ itemID, amount, icon }). The catalog prices some
-- decor in items (1 Mark of Honor, 500 Dreamsurge Coalescence), and an item ID is
-- not a currency ID, so the two never share a field. These three helpers are the
-- only place that distinction is read; every consumer goes through them.

-- Stable identity for grouping / dedup. Sorts gold < currencies < items, total.
function F.CostKey(e)
    if e.itemID then return "item:" .. e.itemID end
    return "currency:" .. e.currencyID
end

-- "1,234 <icon>" for either identity. Amount is a parameter, not read off `e`, so
-- a per-currency AGGREGATE ({ currencyID, total }) renders through the same path.
function F.FormatCost(amount, e)
    if not e.itemID then return F.FormatCurrency(amount, e.currencyID, e.icon) end
    local n = F.FormatAmount(amount)
    if n == "" then return "" end
    -- The catalog link always carries the token's icon; a missing one is drift,
    -- shown as the raw id so it is visible rather than blank.
    if e.icon then return n .. " |T" .. e.icon .. ":14:14|t" end
    return n .. " (item #" .. tostring(e.itemID) .. ")"
end

-- Display name for either identity. Items go through the resolver boundary
-- (placeholder + async kick on a cold cache); a currency is nil when neither the
-- curated table nor the client knows the ID.
function F.CostName(e)
    if e.itemID then return (HDG.ItemNameResolver:ResolveName(e.itemID)) end
    return F.CurrencyName(e.currencyID)
end

function F.FormatGold(copper)
    return F.FormatCurrency(
        math.floor((copper or 0) / 10000),
        HDG.Constants.CURRENCY_GOLD)
end

-- Like FormatGold but renders ZERO as "0 <coin>" for column-aligned tables (Mogul).
function F.FormatGoldZero(copper)
    if not copper or copper <= 0 then return "0 " .. HDG.Constants.COIN_ATLAS end
    return F.FormatGold(copper)
end

-- Relative-time label from a PRE-COMPUTED elapsed-seconds value (impure subtraction stays at call site).
-- Returns "just now" / "Nm ago" / "Nh ago" / "Nd ago".
function F.RelativeTime(elapsedSeconds)
    local d = elapsedSeconds or 0
    if d < 60    then return "just now" end
    if d < 3600  then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

-- "|cAARRGGBBName|r" in the class color (Constants.CLASS_COLORS, keyed by classFile).
-- Pure data, so it works headless too.
function F.ClassName(name, classFile)
    local hex = HDG.Constants.CLASS_COLORS[classFile] or "ffffffff"   -- exception(nullable): legacy roster records predate classFile capture
    return "|c" .. hex .. name .. "|r"
end

-- "(Name)" in the class color, for the Acquisition source lines.
function F.ClassColorName(name, class)
    return "(" .. F.ClassName(name, class) .. ")"
end

-- A recipe source's price (HDGR_RecipeSourceAugment: `copper` plus `currency` =
-- { {"c", currencyID, n}, {"i", itemID, n} }) as one line: "10 <coin>",
-- "400 <icon>", "1 Secret of Draenor Tailoring". Gold and currencies render through
-- FormatCost like any cost entry. An item token is written out by name: the augment
-- ships no icon for it, and it is no catalog item whose link would carry one.
-- CostName goes through ItemNameResolver, so a selector calling this declares
-- session.itemNames.names.
-- Copper renders gold, silver and copper: FormatGold floors to whole gold, and a
-- trainer fee is often under one (500 copper, 40 silver), which showed blank.
-- The silver/copper coins stay here, on the one recipe-price path, so Mogul and
-- the vendor columns keep FormatGold's whole-gold reading.
function F.FormatRecipeCost(source)
    local parts = {}
    if source.copper then  -- exception(optional): a source priced only in currencies or items has no copper
        local coins = { F.FormatGold(source.copper) }
        local silver, copper = math.floor(source.copper % 10000 / 100), source.copper % 100
        if silver > 0 then coins[#coins + 1] = silver .. " " .. HDG.Constants.COIN_SILVER_ATLAS end
        if copper > 0 then coins[#coins + 1] = copper .. " " .. HDG.Constants.COIN_COPPER_ATLAS end
        if coins[1] == "" then table.remove(coins, 1) end
        parts[#parts + 1] = table.concat(coins, " ")
    end
    if source.currency then  -- exception(optional): a gold-only or free source has no currency list
        for _, c in ipairs(source.currency) do
            if c[1] == "i" then
                parts[#parts + 1] = F.FormatAmount(c[3]) .. " " .. F.CostName({ itemID = c[2] })
            else
                parts[#parts + 1] = F.FormatCost(c[3], { currencyID = c[2] })
            end
        end
    end
    return table.concat(parts, "  +  ")
end

-- Profession display name -> atlas (PROFESSION_DATA). Lazy reverse map. nil when unknown.
local _profAtlasByName
function F.ProfessionAtlas(name)
    if not _profAtlasByName then
        _profAtlasByName = {}
        for _, p in ipairs(HDG.Constants.PROFESSION_DATA) do
            if p.name and p.atlas then _profAtlasByName[p.name] = p.atlas end
        end
    end
    return name and _profAtlasByName[name] or nil
end

-- ===== Icon totality ========================================================
-- Coerce (iconTexture, iconAtlas) to a total pair (at least one non-nil).
-- Empty strings treated as nil (Blizzard catalog returns "" for ungenerated preview renders).
-- NOT a defensive guard -- totality is the selector's data contract, not the painter's job.
function F.CoerceIconPair(iconTexture, iconAtlas)
    local hasIcon  = iconTexture and iconTexture ~= ""
    local hasAtlas = iconAtlas   and iconAtlas   ~= ""
    if hasIcon then  return iconTexture, hasAtlas and iconAtlas or nil end
    if hasAtlas then return nil,         iconAtlas end
    return HDG.Constants.PLACEHOLDER_ICON, nil
end

-- Rep-gate progress suffix for the detail-panel gate line. Returns nil when progress is nil.
local _REP_CHECK_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t"
local _REP_CROSS_ICON = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t"
function F.ComposeRepProgressSuffix(progress)
    if not progress then return nil end
    local glyph = progress.met and _REP_CHECK_ICON or _REP_CROSS_ICON
    if progress.met or progress.isMax then
        return string.format("%s %s", glyph, progress.label)
    end
    return string.format("%s %s (%d/%d)",
        glyph, progress.label, progress.current or 0, progress.max or 0)
end

-- "|cffRRGGBB[LABEL]|r" chip. `dimmed` halves RGB (WoW ignores |c alpha byte; darkening RGB is the only option).
-- Strict Palette read: nil means a donorCode gap -- a real bug, not something to paper over.
function F.SourceChip(key, dimmed)
    local kind = HDG.Constants.SOURCE_KIND_BY_KEY[key]
    if not kind then return "[" .. tostring(key) .. "]" end
    local c = HDG.Palette:GetColor("source." .. kind.donorCode)
    local r, g, b = c.r, c.g, c.b
    if dimmed then r, g, b = r * 0.5, g * 0.5, b * 0.5 end
    return string.format("|cff%02x%02x%02x[%s]|r",
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), kind.chipLabel)
end

-- ===== Log level color + line ===============================================
-- Fixed / scheme-invariant: error must read red everywhere, and Debug rows are
-- in a PURE selector (can't read mutable Theme state).
--   LogColor(level) -> r, g, b   (for SetTextColor)
--   LogLine(entry)  -> string    ("[tag] text" with color escape)
-- (The numeric color and the "|cff" text escape are the same color in the two
-- forms WoW's two APIs need; the escape is internal to LogLine, not exposed.)
local LOG_LEVEL_COLOR = {
    debug   = { 0.53, 0.53, 0.53 },  -- muted gray (~text.dim)
    info    = { 0.31, 0.64, 0.95 },  -- accent blue
    warn    = { 0.95, 0.79, 0.30 },  -- amber
    error   = { 0.85, 0.30, 0.55 },  -- magenta
    success = { 0.00, 0.66, 0.59 },  -- teal
}
function F.LogColor(level)
    local c = LOG_LEVEL_COLOR[level] or LOG_LEVEL_COLOR.info
    return c[1], c[2], c[3]
end
-- Private: level color as "|cffRRGGBB" escape. Text surfaces use LogLine, not bare color codes.
local function logColorCode(level)
    local c = LOG_LEVEL_COLOR[level] or LOG_LEVEL_COLOR.info
    return string.format("|cff%02x%02x%02x",
        math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

-- Canonical "log entry -> colored line". Shared by chat + Debug-tab rows. Surface chrome prepended by caller.
function F.LogLine(entry)
    local body = entry.text or ""
    local payload = entry.metadata and entry.metadata.payloadStr
    if type(payload) == "string" and payload ~= "" then
        body = body .. "  " .. payload
    end
    return logColorCode(entry.level) .. "[" .. (entry.tag or "?") .. "] " .. body .. "|r"
end

-- Trim surrounding whitespace (hygiene review A5 -- 7 hand-rolled copies).
function F.Trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Resolve an item's LOCALIZED name with a baked-English fallback: resolved
-- live name wins, else the baked DB name, else the placeholder the resolver
-- returned (hygiene A16 -- shared by Mogul/Recipes selectors). Callers declare
-- reads on session.resolvers.itemNames-adjacent ticks as usual.
function F.LocalItemName(itemID, baked)
    if not itemID then return baked or "?" end
    local name, resolved = HDG.ItemNameResolver:ResolveName(itemID)
    return (resolved and name) or baked or name
end

-- Day month year ("09 Sep 2026") for list rows: the year matters once a
-- library holds codes from more than one season. nil in, nil out: `date` with
-- no timestamp renders TODAY, and an undated blueprint (pasted before the
-- stamp existed) showing today's date is invented data, not a blank.
function F.ShortDate(ts)
    if ts == nil then return nil end
    return _G.date("%d %b %Y", ts)  -- exception(boundary): WoW's `date` global
end
