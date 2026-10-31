-- HDG.ReagentStockObserver
-- ============================================================================
-- Per-character decor-reagent snapshot. Sweeps the reagent set through
-- BagObserver and dispatches CHARACTER_REAGENT_BAGS_UPDATED /
-- CHARACTER_REAGENT_BANK_UPDATED so the reducer persists it under
-- account.characters[charKey].reagentStock. Those snapshots feed the
-- characters.reagentStock selector and the MaterialStock hover.
--
-- Cross-character truth: WoW cannot read another character's bags remotely, so
-- alts sit at their last-login snapshot and only the logged-in char is live.
-- This is the same bargain HDGR_EssenceObserver makes for one item.
--
-- Two rules this module exists to enforce:
--
--   1. Warband is DISCARDED. That stash is shared across the account, so a
--      per-character copy would report one pile once per character. Essence
--      dodges this by being soulbound; general reagents do not.
--   2. Bank is only ever written after BANKFRAME_OPENED. Blizzard's bank counts
--      come from a cache that is empty until the bank frame opens, so an ungated
--      sweep would zero a good bank map on every bankless alt login.

HDG = HDG or {}
HDG.ReagentStockObserver = HDG.ReagentStockObserver or {}
local RS = HDG.ReagentStockObserver

-- ===== The reagent ID set ===================================================
-- Sourced from the recipes.db selector, not the raw HDGR_DecorDB table, so 12.1
-- capture corrections in account.recipeCapture are covered. Unioned with
-- quality-variant siblings because a recipe names one tier and the player may
-- hold another. Rebuilt only when the merged db table identity changes.
local _idsCache, _idsSource

local function _collectReagentIDs(db)
    local seen = {}
    for _, entry in pairs(db) do
        for itemID in pairs(entry.reagents or {}) do   -- exception(nullable): materialized capture rows can be reagent-less
            seen[itemID] = true
            for _, sib in ipairs(HDG.StaticData.Professions:GetQualityVariants(itemID) or {}) do  -- exception(nullable): most reagents are not tiered
                seen[sib] = true
            end
        end
    end
    local out = {}
    for itemID in pairs(seen) do out[#out + 1] = itemID end
    table.sort(out)   -- stable order: LuaJIT's pairs() is nondeterministic
    return out
end

function RS:ReagentIDs()
    local db = HDG.Selectors:Call("recipes.db", HDG.Store:GetState())
    if _idsSource ~= db then
        _idsCache, _idsSource = _collectReagentIDs(db), db
    end
    return _idsCache
end

-- ===== Sweeps ===============================================================

-- Two sparse maps are equal when they hold the same keys at the same counts.
local function _sameCounts(a, b)
    if not a then return false end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function _dispatch(actionType, ident, counts)
    HDG.Store:Dispatch({
        type    = actionType,
        payload = {
            charKey   = ident.charKey,
            name      = ident.name,
            realm     = ident.realm,
            class     = ident.class,
            classFile = ident.classFile,
            counts    = counts,
            at        = (_G.time and _G.time()) or 0,   -- exception(boundary): time() absent in headless tests
        },
    })
end

-- Sweep one stash. `read` returns this stash's count for an itemID; zero counts
-- are left out so the persisted map stays sparse. Dedup is per (charKey, stash):
-- BAG_UPDATE fires on every slot change, and an unchanged sweep must not reach
-- the store or a decor craft would spam it.
function RS:_sweep(stashKey, actionType, read)
    local ident = HDG.SessionIdentity.GetIdentity(HDG.Store:GetState())
    if not ident then return end
    local counts = {}
    for _, itemID in ipairs(self:ReagentIDs()) do
        local n = read(itemID)
        if n > 0 then counts[itemID] = n end
    end
    local lastKey, last = self["_lastKey" .. stashKey], self["_last" .. stashKey]
    if lastKey == ident.charKey and _sameCounts(last, counts) then return end
    self["_lastKey" .. stashKey], self["_last" .. stashKey] = ident.charKey, counts
    _dispatch(actionType, ident, counts)
end

function RS:ScanBags()
    self:_sweep("Bag", HDG.Constants.ACTIONS.CHARACTER_REAGENT_BAGS_UPDATED,
        function(itemID) return HDG.BagObserver:GetBagCount(itemID) end)
end

-- Refuses to run until the bank has been opened this session -- see rule 2 above.
function RS:ScanBank()
    if not self._bankSeen then return end
    self:_sweep("Bank", HDG.Constants.ACTIONS.CHARACTER_REAGENT_BANK_UPDATED,
        function(itemID)
            local _, bank = HDG.BagObserver:GetSplit(itemID)   -- warband return dropped, deliberately (rule 1)
            return bank
        end)
end

function RS:OnBankOpened()
    self._bankSeen = true
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "ReagentStockObserver",
    dependencies = { "BagObserver" },
    -- No ownsBlizzardNamespaces: counts come through BagObserver (ADR-011).
    -- Deliberately NOT requiresMainWindow. BagObserver gates its scans that way
    -- because live counts only matter while the UI is open; this snapshot exists
    -- for characters that never open HDG at all, so the gate would defeat it.
    blizzardEvents = {
        BAG_UPDATE              = { handler = "OnBags", debounce = 2.0 },
        BANKFRAME_OPENED        = { handler = "OnBankOpen", debounce = 0.5 },
        PLAYERBANKSLOTS_CHANGED = { handler = "OnBank", debounce = 0.5 },
        BANK_TABS_CHANGED       = { handler = "OnBank", debounce = 0.5 },
    },
    OnBags     = function(self) RS:ScanBags() end,
    OnBank     = function(self) RS:ScanBank() end,
    OnBankOpen = function(self) RS:OnBankOpened(); RS:ScanBank() end,
})
