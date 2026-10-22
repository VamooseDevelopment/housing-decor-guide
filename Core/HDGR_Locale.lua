-- HDG.Locale
-- ============================================================================
-- Key-value locale registry with enUS fallback chain. Used by `binding = "locale:KEY"` widgets.
-- Missing keys return the literal key (visible to translators; never error).

HDG = HDG or {}
HDG.Locale = HDG.Locale or {
    _locale = "enUS",
    _tables = {},   -- [locale] = { [key] = text }
}

local L = HDG.Locale

-- Developer pseudolocale: a synthetic locale that wraps every enUS value in
-- [brackets] so a translator (or the author on an English client) can see at a
-- glance which on-screen strings are keyed (localisable) vs still hard-coded
-- (they render plain, un-bracketed). Derived live from enUS in :Get -- no table
-- to keep in sync. Picked via the Config > Advanced "Language" dropdown.
local PSEUDO_LOCALE = "enXX"

-- Initialize from persisted state or GetLocale(). Installs a Store subscriber for CONFIG_SET locale
-- so the dropdown's pure-dispatch click path works (Iron Invariant section 6).
function L:Initialize()
    -- Prefer the persisted locale slot if it's been set; fall back to the
    -- client locale, then enUS for headless tests. Empty-string default
    -- ("not yet set by user") routes to the client locale.
    local persisted = HDG.Store
        and HDG.Store.state
        and HDG.Store.state.account
        and HDG.Store.state.account.config
        and HDG.Store.state.account.config.locale
    if type(persisted) == "string" and persisted ~= "" then
        self._locale = persisted
    else
        self._locale = (_G.GetLocale and _G.GetLocale()) or "enUS"
    end
    self:_InstallLocaleSubscriber()
end

function L:_InstallLocaleSubscriber()
    if self._localeSubscriberInstalled then return end
    if not (HDG.Store and HDG.Store.Subscribe) then return end  -- exception(boundary): tests partial
    self._localeSubscriberInstalled = true
    local A = HDG.Constants.ACTIONS
    HDG.Store:Subscribe(function(actionType, invalidation)
        if actionType ~= A.CONFIG_SET then return end
        if not HDG.Paths.MatchesAny({ "account.config.locale" }, invalidation) then return end
        local loc = HDG.Store:GetState().account.config.locale
        if type(loc) ~= "string" or loc == "" then return end
        if self._locale == loc then return end   -- idempotent
        self._locale = loc
        -- locale:KEY bindings pull from in-memory table, not state -- force a full refresh to repaint.
        if HDG.RefreshMainWindow then HDG:RefreshMainWindow("*") end  -- exception(boundary): load-order partial in tests
        HDG.Log:Info("theme", "Locale set to " .. loc)
    end)
end

function L:SetLocale(loc)
    self._locale = loc or "enUS"
end

function L:GetLocale()
    return self._locale
end

-- Resolve a possibly-"locale:KEY"-prefixed display string to its localised text.
-- Plain strings (and non-strings) pass through untouched. The widget factory
-- (HDG.Layout build chokepoint) calls this so static LayoutConfig fields
-- (text/label/placeholder/...) accept "locale:KEY" exactly like bindings do.
function L:Resolve(s)
    if type(s) == "string" and s:sub(1, 7) == "locale:" then
        return self:Get(s:sub(8))
    end
    return s
end

-- Ordered {key,label} list for the Config > Advanced "Language" dropdown:
-- Auto (client locale), every registered locale table, then the dev pseudolocale.
function L:GetAvailableLocales()
    local LABELS = {
        enUS = "English (US)", esMX = "Espanol (MX)", esES = "Espanol (ES)",
        ptBR = "Portugues (BR)", frFR = "Francais (FR)", deDE = "Deutsch",
        ruRU = "Russian", koKR = "Korean", zhCN = "Chinese (Simplified)",
        zhTW = "Chinese (Traditional)", itIT = "Italiano",
    }
    local keys = {}
    for loc in pairs(self._tables) do keys[#keys + 1] = loc end
    -- Stable order: enUS first, the rest alphabetically.
    table.sort(keys, function(a, b)
        if a == "enUS" then return true end
        if b == "enUS" then return false end
        return a < b
    end)
    local out = { { key = "", label = "Auto (client locale)" } }
    for _, loc in ipairs(keys) do
        out[#out + 1] = { key = loc, label = LABELS[loc] or loc }
    end
    out[#out + 1] = { key = PSEUDO_LOCALE, label = "Pseudo [brackets] (dev)" }
    return out
end

-- Register a locale table. Multiple calls merge (later keys win). Modules ship their own keys.
function L:Register(loc, t)
    if type(loc) ~= "string" or type(t) ~= "table" then return end
    self._tables[loc] = self._tables[loc] or {}
    for k, v in pairs(t) do
        self._tables[loc][k] = v
    end
end

-- Look up a key. Order: current locale -> enUS -> key string (loud-fail per ADR-006).
function L:Get(key)
    if type(key) ~= "string" or key == "" then return tostring(key or "") end
    -- Pseudolocale: bracket the enUS value (or the raw key if untranslated) so
    -- keyed strings are visually distinct from hard-coded ones on any client.
    if self._locale == PSEUDO_LOCALE then
        local enUS = self._tables.enUS
        return "[" .. ((enUS and enUS[key]) or key) .. "]"
    end
    local t = self._tables[self._locale]
    if t and t[key] ~= nil then return t[key] end
    local enUS = self._tables.enUS
    if enUS and enUS[key] ~= nil then return enUS[key] end
    return key
end

-- Every locale falls back to enUS, so a key enUS holds always resolves to text.
-- Layout:Validate checks the config's "locale:" keys with it.
function L:Has(key)
    return self._tables.enUS[key] ~= nil
end

-- Test helper -- wipe between cases.
function L:_Reset()
    self._tables = {}
    self._locale = "enUS"
end
