-- HDG.TagData
-- ============================================================================
-- Tag-ID -> category bucket + label lookups for housing catalog filter tags.
-- Verbatim port of HousingDecorGuide/modules/HDG_TagData.lua with the global
-- renamed to HDG.TagData and a GetLabel() addition for tag-name lookups.
--
-- Reads the live group->tag map from C_HousingCatalog.GetAllFilterTagGroups()
-- so we don't maintain hardcoded tag IDs (Blizzard adds tags every patch).
-- Categorisation is anchored to tag IDs (stable across locales); tag NAMES
-- are localized and unsuitable as keys.
--
-- Public API:
--   HDG.TagData.GetCategory(tagID) -> "Sizes"|"Factions"|"Styles"|"Expansions"|"Cultures"|"Themes"|"Other"
--   HDG.TagData.GetLabel(tagID)    -> string|nil  (user-visible tag name; long form)
--   HDG.TagData.GetShortLabel(tagID) -> string|nil  (expansion-shortened where applicable)
--   HDG.TagData.Invalidate()        -- clear the cache (test/diagnostic hook)

HDG = HDG or {}
HDG.TagData = HDG.TagData or {}

-- Map Blizzard's groupName ("Size", "Faction", "Expansion", "Style", "Culture",
-- "Theme") to the internal category keys. Anything else buckets to "Other".
local GROUP_NAME_TO_CATEGORY = {
    Size      = "Sizes",
    Faction   = "Factions",
    Expansion = "Expansions",
    Style     = "Styles",
    -- The Decor tab's Style menu holds Style + Theme, its Culture menu Culture
    -- (Constants.DECOR_FILTER_GROUPS). Before the menus both fell under "Other".
    Culture   = "Cultures",
    Theme     = "Themes",
}

-- Expansion long-name -> short-name map. The catalog API returns localized
-- long names ("Wrath of the Lich King") which blow out the tags-row chip
-- strip at 12 entries. We render the short form in chips; tooltips still
-- show the long form. Keys must match Blizzard's en-US returns; non-enUS
-- locales fall through to long names (acceptable -- chip strip overflow
-- is preferable to a broken display).
local EXPANSION_SHORT = {
    ["Classic"]                  = "Classic",
    ["The Burning Crusade"]      = "TBC",
    ["Burning Crusade"]          = "TBC",
    ["Wrath of the Lich King"]   = "WotLK",
    ["Cataclysm"]                = "Cata",
    ["Mists of Pandaria"]        = "MoP",
    ["Warlords of Draenor"]      = "WoD",
    ["Legion"]                   = "Legion",
    ["Battle for Azeroth"]       = "BfA",
    ["Shadowlands"]              = "SL",
    ["Dragonflight"]             = "DF",
    ["The War Within"]           = "TWW",
    ["War Within"]               = "TWW",
    ["Midnight"]                 = "Midnight",
    ["The Last Titan"]           = "TLT",
}

-- Cached maps, lazy-built on first lookup. Both filled in one pass so the
-- single C_HousingCatalog.GetAllFilterTagGroups call serves both lookups.
local _categoryByID
local _labelByID

-- Index one tagInfo by its real tagID: tagID -> category, and tagID -> tagName
-- when present. Skips entries without a tagID.
local function _indexTagInfo(cat, lbl, category, tagInfo)
    if not (tagInfo and tagInfo.tagID) then return end
    cat[tagInfo.tagID] = category
    if tagInfo.tagName then
        lbl[tagInfo.tagID] = tagInfo.tagName
    end
end

local function buildMaps()
    if _categoryByID and _labelByID then return _categoryByID, _labelByID end
    if not (_G.C_HousingCatalog and _G.C_HousingCatalog.GetAllFilterTagGroups) then
        return nil, nil
    end
    local groups = _G.C_HousingCatalog.GetAllFilterTagGroups()
    -- Empty is "not streamed in yet", not "no tags": the groups read 0 then N a
    -- moment later (HDGR_HousingCatalogObserver.lua:112). Caching that first
    -- empty answer filed every tag under "Other" for the session.
    if not groups or next(groups) == nil then return nil, nil end  -- exception(boundary): tag metadata streams in after login
    local cat, lbl = {}, {}
    for _, group in ipairs(groups) do
        -- groupName is LOCALIZED -> matching it misses off enUS. Use the stable groupID -> canonical
        -- category; fall back to expansion tag-value detection if Blizzard renumbers, then groupName.
        local canonical = HDG.Constants.FILTER_TAG_GROUP_BY_ID[group.groupID]
                       or (HDG.Expansion.IsExpansionTagGroup(group) and "Expansion")
        local category = GROUP_NAME_TO_CATEGORY[canonical or group.groupName or ""] or "Other"
        -- group.tags is an array of { tagID, tagName, anyAssociatedEntries };
        -- keys are sequential indices, not real tagIDs (per HDG_TagData:38), so
        -- _indexTagInfo keys off tagInfo.tagID.
        for _, tagInfo in pairs(group.tags or {}) do
            _indexTagInfo(cat, lbl, category, tagInfo)
        end
    end
    _categoryByID = cat
    _labelByID    = lbl
    return cat, lbl
end

function HDG.TagData.GetCategory(tagID)
    local cat = buildMaps()
    return (cat and cat[tagID]) or "Other"
end

function HDG.TagData.GetLabel(tagID)
    local _, lbl = buildMaps()
    return lbl and lbl[tagID] or nil
end

-- Expansion-aware shortener. Returns the EXPANSION_SHORT mapping when the
-- tagID belongs to the Expansion group; otherwise returns the long label
-- unchanged. Used by decor.tagsForFilter to keep the tags-row chip strip
-- from overflowing on the "expansions" bucket (12 entries with long
-- names like "Wrath of the Lich King" exceed the 912px window).
function HDG.TagData.GetShortLabel(tagID)
    local cat, lbl = buildMaps()
    local name = lbl and lbl[tagID]
    if not name then return nil end
    if cat and cat[tagID] == "Expansions" then
        return EXPANSION_SHORT[name] or name
    end
    return name
end

function HDG.TagData.Invalidate()
    _categoryByID = nil
    _labelByID    = nil
end
