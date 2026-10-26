-- HDG.Profession
-- ============================================================================
-- Single source of truth for profession lookups by stable numeric
-- TradeSkillLineID. Built over HDG.Constants.PROFESSION_DATA (the authoritative
-- ordered list; each entry: name (English), shortLabel, id, code, atlas).
-- Mirrors HDG.Expansion -- Constants owns the data, this file owns the indexing.
--
-- WHY IDs: char.professions records and captured recipes must NOT key/join on the
-- LOCALIZED profession name -- C_TradeSkillUI.GetBaseProfessionInfo().professionName
-- is "Cocina" on an esES client, "Cooking" on enUS. Any cross-reference against the
-- curated English seed data (decor buckets, thresholds, PROFESSION_DATA columns)
-- then silently misses on every non-enUS client. professionID (185 = Cooking) is
-- locale-invariant, so it is the correct join key.
--
-- API:
--   HDG.Profession.Each()          iterator over PROFESSION_DATA (canonical order)
--   HDG.Profession.GetByID(id)     entry table or nil
--   HDG.Profession.GetByName(name) entry table or nil (English name -> entry;
--                                   used by the SV backfill to recover the ID)
--   HDG.Profession.NameOf(id)      canonical English display name or nil
--   HDG.Profession.RecordOf(char, id) the character's record for that profession, or nil
--   HDG.Profession.NamesOf(char)   the character's professions as { [English name] = true }

HDG = HDG or {}
HDG.Profession = HDG.Profession or {}
local P = HDG.Profession

-- ===== Lazy index builders ==================================================

local _byID    -- [id]   = entry
local _byName  -- [name] = entry (English)

local function ensureIndexes()
    if _byID then return end
    _byID, _byName = {}, {}
    for _, e in ipairs(HDG.Constants.PROFESSION_DATA) do
        _byID[e.id]     = e
        _byName[e.name] = e
        if e.aliases then                                   -- localized professionName forms
            for _, a in ipairs(e.aliases) do _byName[a] = e end
        end
    end
end

-- ===== Public API ===========================================================

function P.Each() return ipairs(HDG.Constants.PROFESSION_DATA) end

function P.GetByID(id)
    if not id then return nil end
    ensureIndexes()
    return _byID[id]
end

function P.GetByName(name)
    if not name then return nil end
    ensureIndexes()
    return _byName[name]
end

function P.NameOf(id)
    local entry = P.GetByID(id)
    return entry and entry.name or nil
end

-- ===== Character records ====================================================
-- char.professions is keyed by the client's language ("Schneiderei"), so every join
-- against the English data goes through the professionID each record carries.

function P.RecordOf(char, profID)
    if profID == nil then return nil end   -- exception(nullable): an un-stamped record's profession has no id, and nil must not match other id-less records
    for _, prof in pairs(char.professions) do
        if prof.professionID == profID then return prof end
    end
    return nil
end

function P.NamesOf(char)
    local out = {}
    for _, prof in pairs(char.professions) do
        local entry = P.GetByID(prof.professionID)   -- exception(boundary): SV migration -- a non-enUS record from before ID-stamping has no professionID until its next scan
        if entry then out[entry.name] = true end
    end
    return out
end
