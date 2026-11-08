-- HDG.CategoryNav
-- ============================================================================
-- Pure builders for the Blizzard category/subcategory icon nav, shared by the
-- Style Curator (horizontal icon row) and the Projects decor picker (vertical
-- rail). Consumes the session.house.categoryTree snapshot produced by
-- HousingCatalogObserver. NO Blizzard API, NO Store access -- callers pass the
-- tree + focus + storedOnly so the per-surface selectors stay pure (Inv 1).
--
-- The observer stripped Blizzard's baked atlas state suffix to iconBase; we
-- re-append the per-state suffix here (pure string concat). Render states:
--   selected                 -> _active
--   parent-of-focused-subcat -> _active-parent
--   default                  -> _inactive
-- (_pressed is a frame-local OnMouseDown swap in the row factory, not a render
-- state, so it's not produced here.)
--
-- "All" is a SYNTHETIC row (id = 0). Blizzard's nav synthesizes it rather than
-- returning it from SearchCatalogCategories, so we prepend our own. Atlas = `category-icons_all`.

HDG = HDG or {}
local M = {}
HDG.CategoryNav = M

M.ALL_ID = 0   -- sentinel id for the synthetic "All" category / subcategory row

local function _atlasFor(iconBase, suffix)
    if not iconBase then return nil end   -- exception(boundary): API icon field is nilable
    return iconBase .. suffix
end

-- "All" reuses the same atlas on BOTH strips -- the category "All" icon and the
-- subcategory "All <Cat>" row show the identical glyph (not text).
local ALL_ATLAS_BASE = "category-icons_all"
local function _allAtlas(active) return ALL_ATLAS_BASE .. (active and "_active" or "_inactive") end

-- Top-level category rows in orderIndex order, with a synthetic "All" first.
-- storedOnly drops categories the player owns nothing in (anyStoredEntries
-- false). countByID (optional) maps catID -> item count for tooltip/badge;
-- countByID[ALL_ID] is the grand total.
function M.BuildCategories(tree, focusedCatID, focusedSubID, storedOnly, countByID)
    local allActive = (focusedCatID == nil)
    local rows = {
        {
            id       = M.ALL_ID,
            name     = "All",
            isAll    = true,
            atlas    = _allAtlas(allActive),
            isActive = allActive,
            owned    = true,
            count    = countByID and countByID[M.ALL_ID] or nil,
        },
    }
    for _, catID in ipairs(tree.rootIDs) do
        local c = tree.byID[catID]
        if c and ((not storedOnly) or c.anyStoredEntries) then
            local isActive = (catID == focusedCatID)
            local isParent = isActive and (focusedSubID ~= nil)
            local suffix   = isParent and "_active-parent" or (isActive and "_active") or "_inactive"
            rows[#rows + 1] = {
                id       = catID,
                name     = c.name,
                atlas    = _atlasFor(c.iconBase, suffix),
                isActive = isActive,
                isParent = isParent,
                owned    = c.anyStoredEntries == true,
                count    = countByID and countByID[catID] or nil,
            }
        end
    end
    return rows
end

-- Subcategory rows for the FOCUSED category (empty when none focused or it has
-- no subcategories). Prepends a synthetic "All <Category>" row (id = ALL_ID) that
-- clears focusedSubcategoryID. Subcategories DO carry an icon atlas (same
-- category-icons sheet, _active/_inactive states -- they're leaves, so no
-- _active-parent); the "All" row has none and renders as text.
function M.BuildSubcategories(tree, focusedCatID, focusedSubID, storedOnly)
    if not focusedCatID then return {} end
    local cat = tree.byID[focusedCatID]
    if not (cat and cat.subcategoryIDs and #cat.subcategoryIDs > 0) then return {} end
    local subs = {}
    for _, subID in ipairs(cat.subcategoryIDs) do
        local s = tree.subcatByID[subID]
        if s and ((not storedOnly) or s.anyStoredEntries) then
            subs[#subs + 1] = s
        end
    end
    if #subs == 0 then return {} end
    table.sort(subs, function(a, b) return (a.orderIndex or 0) < (b.orderIndex or 0) end)
    local allSubActive = (focusedSubID == nil)
    local rows = {
        { id = M.ALL_ID, name = "All " .. (cat.name or ""), isAll = true,
          isActive = allSubActive, atlas = _allAtlas(allSubActive) },
    }
    for _, s in ipairs(subs) do
        local active = (s.id == focusedSubID)
        rows[#rows + 1] = {
            id       = s.id,
            name     = s.name,
            atlas    = _atlasFor(s.iconBase, active and "_active" or "_inactive"),
            isActive = active,
            owned    = s.anyStoredEntries == true,
        }
    end
    return rows
end

-- ===== Decor-picker vertical rail (mirrors Blizzard's HousingCatalogCategoriesMixin) ======
-- IN-SITU drill-down: top-level icons normally; when a category with >1 subcategories
-- is focused, replaces the rail with BACK + "All <Cat>" + subcategory icons. <=1
-- filter-passing subcategories = highlight only, no drill (Blizzard's rule).
-- Rows carry `level` ("category"|"subcategory"|"back") for OnCategoryClicked dispatch.

-- Count filter-passing subcategories, short-circuiting at 2 (Blizzard's >1 rule).
local function _showsSubcategories(tree, catID, storedOnly)
    local cat = tree.byID[catID]
    if not (cat and cat.subcategoryIDs) then return false end
    local n = 0
    for _, subID in ipairs(cat.subcategoryIDs) do
        local s = tree.subcatByID[subID]
        if s and ((not storedOnly) or s.anyStoredEntries) then
            n = n + 1
            if n > 1 then return true end
        end
    end
    return false
end

M.ShowsSubcategories = _showsSubcategories   -- the companion's Catalog picker opens a category by the same rule

function M.BuildPickerRail(tree, focusedCatID, focusedSubID, storedOnly)
    if focusedCatID and _showsSubcategories(tree, focusedCatID, storedOnly) then
        -- Subcategory view: BACK + ("All <Cat>" + subcategory icons), in place.
        local rows = { { isBack = true, name = "Back", level = "back" } }
        for _, r in ipairs(M.BuildSubcategories(tree, focusedCatID, focusedSubID, storedOnly)) do
            r.level = "subcategory"
            rows[#rows + 1] = r
        end
        return rows
    end
    -- Category view: top-level icons (a focused leaf category shows active).
    local rows = M.BuildCategories(tree, focusedCatID, focusedSubID, storedOnly)
    for _, r in ipairs(rows) do r.level = "category" end
    return rows
end
