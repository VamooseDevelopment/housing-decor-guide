-- HDG.ProfessionScanner
-- ============================================================================
-- Per-character profession scanner. Snapshots skill ladder + learned recipes
-- on TRADE_SKILL_LIST_UPDATE and dispatches CHARACTER_PROFESSION_UPDATED so
-- the reducer upserts account.characters[charKey].professions[profName].
--
-- Coverage: only the OPENED profession is scanned; both professions require
-- two visits (WoW doesn't expose alt profession data cross-character).
--
-- Debounce: TRADE_SKILL_LIST_UPDATE bursts 3-5 times during initial load;
-- 0.5s coalesces cleanly. Scan walk is ~1ms for a full profession (~900 recipes).

HDG = HDG or {}
HDG.ProfessionScanner = HDG.ProfessionScanner or {}
local PS = HDG.ProfessionScanner

-- Set equality for knownRecipes ({[id]=true}) -- knowledge idempotency diff.
local function sameSet(a, b)
    if not a or not b then return false end  -- exception(nullable): profession not recorded yet
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

-- skillLines equality ({[expName]={current,max}}).
local function sameSkillLines(a, b)
    if not a or not b then return false end  -- exception(nullable): profession not recorded yet
    for k, v in pairs(a) do
        local w = b[k]
        if not w or w.current ~= v.current or w.max ~= v.max then return false end
    end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- Returns nil if SessionIdentity hasn't dispatched yet (boot window).

-- True if the player PERSONALLY OWNS this profession -- its skillLineID is one of
-- their GetProfessions() slots. The ownership gate for Scan: without it, opening a
-- GUILD / LINKED / inspected profession window (e.g. VGC's guild crafter opens
-- professions you don't know) records that profession against THIS character at
-- skill 0 -- the "professions you don't know" rows. This is old HDG's GetProfessions
-- gate (HDG_Data.lua `charHasProfession`) that the Lattice rewrite dropped.
-- base.professionID and GetProfessionInfo's 7th return (skillLine) share an ID space.
local function playerOwnsProfession(professionID)
    if not professionID then return false end
    -- exception(boundary): legacy GetProfessions absent (headless tests) -> can't
    -- verify ownership, so don't block recording.
    if not (_G.GetProfessions and _G.GetProfessionInfo) then return true end
    local function slotOwns(idx)
        if not idx then return false end
        local _, _, _, _, _, _, skillLine = _G.GetProfessionInfo(idx)
        return skillLine == professionID
    end
    local p1, p2, arch, fish, cook = _G.GetProfessions()
    return slotOwns(p1) or slotOwns(p2) or slotOwns(cook) or slotOwns(arch) or slotOwns(fish)
end

-- Pull {current, max} skill levels per expansion child of the open root profession.
local function readSkillLines()
    local out = {}
    local CT = _G.C_TradeSkillUI
    if not (CT and CT.GetChildProfessionInfos) then return out end
    local children = CT.GetChildProfessionInfos()
    if type(children) ~= "table" then return out end
    for _, info in ipairs(children) do
        local expName = info.expansionName or info.professionName
        if expName then
            out[expName] = {
                current = info.skillLevel    or 0,  -- exception(boundary): Blizz C_TradeSkillUI struct
                max     = info.maxSkillLevel or 0,  -- exception(boundary): Blizz C_TradeSkillUI struct
            }
        end
    end
    return out
end

-- Collect learned recipe IDs for the open profession. O(recipes); no memoization needed.
local function readKnownRecipes()
    local out = {}
    local CT = _G.C_TradeSkillUI
    if not (CT and CT.GetAllRecipeIDs and CT.GetRecipeInfo) then return out end
    local ids = CT.GetAllRecipeIDs()
    if type(ids) ~= "table" then return out end
    for _, recipeID in ipairs(ids) do
        local info = CT.GetRecipeInfo(recipeID)
        if info and info.learned then
            out[recipeID] = true
        end
    end
    return out
end

-- ===== Ungated decor-recipe reagent capture =================================
-- Reagents are universal, so ANY opened profession window (own or a guildmate's, via the
-- guild scan) is a valid source. This runs BEFORE the knowledge scan's ownership gate and
-- writes to a SEPARATE store (account.recipeCapture) -- never account.characters. Records the
-- LOWEST-quality reagent variant (decor has no craft quality). Feeds the runtime override the
-- recipe resolver reads over the shipped seed DB (docs/RECIPE_CAPTURE_ARCHITECTURE).

-- Lowest-quality itemID among a slot's reagent variants (nil quality = non-tiered reagent).
local function lowestQualityReagent(slot, CT)
    local best, bestQ
    for _, r in ipairs(slot.reagents or {}) do
        if r.itemID then
            local q = CT.GetItemReagentQualityByItemInfo(r.itemID)  -- exception(boundary): nil for non-quality reagents
            if q and (not bestQ or q < bestQ) then best, bestQ = r.itemID, q end
        end
    end
    return best or (slot.reagents and slot.reagents[1] and slot.reagents[1].itemID)
end

-- Record a tiered slot's quality group into `groups` ([memberID] = sorted sibling list).
-- Recipes store the LOWEST tier, but ANY tier satisfies the slot -- bag counting sums
-- across the group via GetQualityVariants, which reads these captured groups over the
-- seed's (frozen-at-12.0) variant data. Every member maps to its siblings.
local function captureVariantGroup(slot, groups)
    local ids = {}
    for _, r in ipairs(slot.reagents or {}) do
        if r.itemID then ids[#ids + 1] = r.itemID end
    end
    if #ids < 2 then return end   -- non-tiered slot: no group
    table.sort(ids)
    for i, id in ipairs(ids) do
        local sibs = {}
        for j, other in ipairs(ids) do
            if j ~= i then sibs[#sibs + 1] = other end
        end
        groups[id] = sibs
    end
end

-- Order-insensitive sibling-list equality (both sides sorted at build time).
local function sameSiblings(a, b)
    if not a or #a ~= #b then return false end  -- exception(nullable): id not in store yet
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- "This tradeskill session isn't mine": guild recipe view or a guildmate's book.
-- Blizzard's own Professions.lua uses this exact pair (donor: VWB KnownRecipes).
-- Gates the KNOWLEDGE dispatch -- guild-aggregate `learned` flags are the guild's,
-- not this character's -- and the harvest window guards. Capture always runs
-- (reagents are universal regardless of whose book is open).
local function isForeignTradeSkill(CT)
    return CT.IsTradeSkillGuild() or CT.IsTradeSkillGuildMember()
end

-- Full-record equality: profession, spellID, categoryName (sub-recipes only; nil==nil for
-- decor), outputQtyMin, AND the reagent {id=qty} set. A change in ANY (12.1 reduced-lumber
-- reagents, a profession move, a new recipe, a spellID backfill, a yield the store predates)
-- counts as changed -> re-dispatch. nil `a` = itemID not in the store yet = new recipe = changed.
local function sameRecord(a, b)
    if not a then return false end
    if a.profession ~= b.profession then return false end
    if a.spellID ~= b.spellID then return false end
    if a.categoryName ~= b.categoryName then return false end
    if a.expansion ~= b.expansion then return false end
    if a.name ~= b.name then return false end
    if a.outputQtyMin ~= b.outputQtyMin then return false end
    for id, qty in pairs(a.reagents) do if b.reagents[id] ~= qty then return false end end
    for id in pairs(b.reagents) do if a.reagents[id] == nil then return false end end
    return true
end

-- Top-level category name for a recipe: walk parentCategoryID to the root. In the
-- profession book that root is the expansion skill-line ("Midnight Enchanting") --
-- the exact string DecorDB's `expansion` field carries, which Expansion.FromSkillLine
-- normalizes for the UI's expansion filter. Ported from VWB RecipeHarvest.
local function topCategoryName(categoryID, CT)
    local top
    for _ = 1, 10 do  -- depth cap (category trees are 2-3 deep; guard against loops)
        if not categoryID then break end
        local info = CT.GetCategoryInfo(categoryID)  -- exception(boundary): category tree can be stale
        if not info then break end
        if info.name then top = info.name end
        categoryID = info.parentCategoryID
    end
    return top
end

-- The profession a recipe belongs to, asked of the RECIPE, never the open window.
-- The capture used to stamp GetBaseProfessionInfo's name on every recipe of a walk, and
-- during a guild scan the window and GetAllRecipeIDs' list were one profession apart:
-- one account saved all of Leatherworking's recipes as "Mining" and Mining's smelting as
-- "Skinning" (2026-10-25; the scan queue is alphabetical). GetProfessionInfoByRecipeID
-- describes the recipe's own skill line whatever is open -- Blizzard's InspectRecipe
-- calls it for chat-linked recipes with no profession window at all.
-- Called for kept records only (decor + the sub-recipe closure, and the spellbook pass's
-- newly learned spells), not every recipe in the book: each call builds a table.
-- Returns the root profession's (professionID, localized name).
local function recipeRootProfession(recipeID, CT)
    local info = CT.GetProfessionInfoByRecipeID(recipeID)
    -- A recipe sits on an expansion child line ("Dragon Isles Leatherworking"); the root
    -- profession is its parent. Blizzard's own display name takes the parent, else the
    -- line itself (Professions.GetProfessionInfo).
    return info.parentProfessionID or info.professionID,     -- exception(boundary): parentProfessionID is nil on a root skill line
           info.parentProfessionName or info.professionName  -- exception(boundary): parentProfessionName is nil on a root skill line
end

local function recipeProfessionName(recipeID, CT)
    local _, name = recipeRootProfession(recipeID, CT)
    return name
end

-- Diff a freshly-scanned record set against a store slot; returns only the records
-- that are new or changed (shared by the decor + sub-recipe capture paths).
local function diffAgainstStore(scanned, store)
    local changed, n = {}, 0
    for itemID, rec in pairs(scanned) do
        if not sameRecord(store[itemID], rec) then changed[itemID] = rec; n = n + 1 end
    end
    return changed, n
end

-- Sub-recipe closure: BFS from the reagent ids decor recipes need (this walk's + the
-- accumulated store's) through allByOutput -- every profession-book recipe indexed by
-- output itemID. Keeps producers of wanted reagents, then wants THEIR reagents, so
-- intermediate chains (ore -> bar -> part) capture whole. Cross-profession chains
-- (a Blacksmithing decor needing Mining-smelted bars) converge because the wanted set
-- is store-seeded -- a later profession's scan sees the earlier one's needs. Depth cap
-- mirrors PowerCrafter.MAX_DEPTH. categoryName is captured for the kept records only
-- (PowerCrafter's Mass Milling/Prospecting leaf-stop reads it).
local function subRecipeClosure(allByOutput, decorRecipes, CT)
    local state = HDG.Store:GetState()
    local wanted = {}
    local function wantReagents(rec)
        for rid in pairs(rec.reagents) do wanted[rid] = true end
    end
    for _, rec in pairs(decorRecipes) do wantReagents(rec) end
    for _, rec in pairs(state.account.recipeCapture) do wantReagents(rec) end
    for _, rec in pairs(state.account.subRecipeCapture) do wantReagents(rec) end
    -- Frontier is an ARRAY snapshot of the wanted set: inserting into `wanted`
    -- while pairs()-iterating it is Lua 5.1 undefined behavior (keys get skipped
    -- or revisited after a rehash) -- the set is membership-only from here.
    local kept, frontier = {}, {}
    for rid in pairs(wanted) do frontier[#frontier + 1] = rid end
    for _ = 1, 6 do  -- PowerCrafter.MAX_DEPTH parity
        local nextFrontier = {}
        for _, rid in ipairs(frontier) do
            local producer = allByOutput[rid]  -- exception(nullable): most reagents are gathered/vendor leaves
            if producer and not kept[rid] and not decorRecipes[rid] then
                local info = CT.GetRecipeInfo(producer.spellID)  -- exception(boundary): nil for stale recipeID
                local cat  = info and info.categoryID and CT.GetCategoryInfo(info.categoryID)  -- exception(boundary): category tree can be stale
                producer.categoryName = cat and cat.name
                producer.profession   = recipeProfessionName(producer.spellID, CT)
                kept[rid] = producer
                for rrid in pairs(producer.reagents) do
                    if not wanted[rrid] then
                        wanted[rrid] = true
                        nextFrontier[#nextFrontier + 1] = rrid
                    end
                end
            end
        end
        if #nextFrontier == 0 then break end
        frontier = nextFrontier
    end
    return kept
end

-- Walk every recipe in the open profession book once: index ALL craft outputs
-- (closure source), collect decor recipes (catalog-classified, with name/expansion/
-- profession), and record tiered slots' quality groups. Profession is stamped where a
-- record is kept (here for decor, subRecipeClosure for intermediates).
local function _walkProfessionBook(CT, catalog, ids)
    local BASIC = (_G.Enum and _G.Enum.CraftingReagentType and _G.Enum.CraftingReagentType.Basic) or 0  -- exception(boundary): enum absent headless; Basic = 0
    local SALVAGE = (_G.Enum and _G.Enum.TradeskillRecipeType and _G.Enum.TradeskillRecipeType.Salvage) or 2  -- exception(boundary): enum absent headless; Salvage = 2
    local recipes, n = {}, 0
    local allByOutput = {}   -- [outItemID] = { reagents, spellID } -- transient closure index (profession stamped on the kept ones)
    local variantGroups = {} -- [reagentID] = sorted sibling ids -- quality groups seen this walk
    for _, recipeID in ipairs(ids) do
        local schematic = CT.GetRecipeSchematic(recipeID, false)  -- exception(boundary): nil until recipe data caches
        local itemID = schematic and schematic.outputItemID
        if itemID then
            local reagents = {}
            for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
                if slot.reagentType == BASIC then
                    local rid = lowestQualityReagent(slot, CT)
                    if rid then reagents[rid] = slot.quantityRequired or 1 end
                    captureVariantGroup(slot, variantGroups)
                end
            end
            if next(reagents) then
                -- recipeID IS the recipe spell ID (GetRecipeSchematic(recipeSpellID, ...)); store it
                -- so the resolver can materialize a full entry (spellID drives IsSpellKnown) for
                -- recipes the seed DB doesn't ship. Capture is the source of truth; seed is fallback.
                local rec = { reagents = reagents, spellID = recipeID }
                -- Per-craft yield for multi-output recipes (bolts make 2, Imbued Silkweave
                -- 10): PowerCrafter divides demand by it. Salvage schematics report the
                -- INPUT consumed in quantityMin (Reference gotcha), so they are skipped.
                -- 1 is the default and is not stored -- sparse, like the seed's outputQtyMin.
                local yield = schematic.quantityMin or 1  -- exception(boundary): schematic field, documented as number but read defensively
                if schematic.recipeType ~= SALVAGE and yield > 1 then
                    rec.outputQtyMin = yield
                end
                allByOutput[itemID] = rec
                local row = catalog:GetRow(itemID)  -- exception(nullable): non-decor products
                if row then  -- decor products (catalog-recognized)
                    -- Expansion skill-line via the category-tree walk (decor only: it feeds
                    -- the Recipes tab's expansion filter for seed-absent 12.1 recipes).
                    local info = CT.GetRecipeInfo(recipeID)  -- exception(boundary): nil for stale recipeID
                    rec.expansion = info and topCategoryName(info.categoryID, CT)
                    rec.profession = recipeProfessionName(recipeID, CT)
                    -- Catalog display name: instant text for materialized recipes + makes the
                    -- SV capture self-contained for offline diffs/reports.
                    rec.name = row.name
                    recipes[itemID] = rec
                    n = n + 1
                end
            end
        end
    end
    return recipes, allByOutput, variantGroups, n
end

-- Diff all three capture sets against their stores and dispatch ONLY the deltas.
-- Idempotent: the double-fire and unchanged re-opens produce empty diffs ->
-- no dispatch, no re-invalidate.
local function _dispatchCaptureDiffs(profName, n, recipes, subRecipes, variantGroups)
    local state = HDG.Store:GetState()
    local changed,    changedN    = diffAgainstStore(recipes, state.account.recipeCapture)
    local changedSub, changedSubN = diffAgainstStore(subRecipes, state.account.subRecipeCapture)
    -- Quality groups: UNION with the store before diffing -- a recipe slot listing a
    -- partial sibling set (legitimate per-recipe subset) must never shrink a group
    -- already captured whole (same "keep the largest group seen" rule as the seed's
    -- builder).
    local vStore = state.account.reagentVariants
    local changedVar, changedVarN = {}, 0
    for id, sibs in pairs(variantGroups) do
        local existing = vStore[id]  -- exception(nullable): first capture of this group
        if existing then
            local set = {}
            for _, sib in ipairs(existing) do set[sib] = true end
            for _, sib in ipairs(sibs) do set[sib] = true end
            local merged = {}
            for sib in pairs(set) do merged[#merged + 1] = sib end
            table.sort(merged)
            sibs = merged
        end
        if not sameSiblings(vStore[id], sibs) then changedVar[id] = sibs; changedVarN = changedVarN + 1 end
    end
    if changedN > 0 or changedSubN > 0 or changedVarN > 0 then
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.RECIPE_DATA_CAPTURED,
            payload = {
                recipes         = changed,
                subRecipes      = changedSubN > 0 and changedSub or nil,
                reagentVariants = changedVarN > 0 and changedVar or nil,
            },
        })
    end
    -- All-zero passes (debounce twin, re-opens, craft ticks) log at Debug so the
    -- user-visible log carries only real changes.
    local msg = string.format("%s: %d decor recipes (%d new/changed), sub-recipes (%d new/changed)",
        profName or "?", n, changedN, changedSubN)
    if changedN > 0 or changedSubN > 0 or changedVarN > 0 then
        HDG.Log:Info("recipe_capture", msg)
    else
        HDG.Log:Debug("recipe_capture", msg)
    end
end

-- profName is the open window's profession and labels the log line only: records take
-- each recipe's own profession (recipeProfessionName), because the window can disagree
-- with the list it hands back.
function PS.CaptureRecipeData(profName)   -- no self; called as PS.CaptureRecipeData
    local CT = _G.C_TradeSkillUI
    local catalog = HDG.HousingCatalogObserver
    -- Catalog cold -> can't classify products as decor. Request the sweep (idempotent)
    -- and re-scan on DECOR_CATALOG_READY (subscription below) -- otherwise an alt that
    -- opens its profession book without ever opening HDG silently captures NOTHING
    -- while the knowledge scan (no catalog dependency) still populates Alts.
    if not catalog:IsReady() then
        catalog:RequestLoad("recipeCapture")
        return
    end
    local ids = CT.GetAllRecipeIDs()
    if type(ids) ~= "table" then return end
    local recipes, allByOutput, variantGroups, n = _walkProfessionBook(CT, catalog, ids)
    -- Sub-recipe closure: the intermediates decor recipes need, walked to their roots
    -- (PowerCrafter's captured craft graph -- the path to dropping ProfessionsDB).
    local subRecipes = subRecipeClosure(allByOutput, recipes, CT)
    _dispatchCaptureDiffs(profName, n, recipes, subRecipes, variantGroups)
end

function PS:Scan()
    local CT = _G.C_TradeSkillUI
    if not (CT and CT.IsTradeSkillReady and CT.IsTradeSkillReady()) then return end  -- exception(boundary): profession window not open
    if not (CT.GetBaseProfessionInfo) then return end
    local base = CT.GetBaseProfessionInfo()
    if not (base and base.professionName and base.professionName ~= "") then return end
    -- Ungated recipe-DATA capture FIRST -- reagents are universal, so a guildmate's window
    -- (or any linked profession) is a valid source. Separate store; runs before the gate.
    PS.CaptureRecipeData(base.professionName)
    -- Foreign session (guild view -- ours OR player-opened via the roster, or a
    -- guildmate's book): capture only. Its `learned` flags reflect the GUILD's
    -- crafters, not this character -- recording them would pollute knownRecipes
    -- even when the player happens to own the same profession.
    if isForeignTradeSkill(CT) then return end
    -- Ownership gate (old HDG parity): only record professions THIS character
    -- actually owns. Skips guild/linked/inspected profession windows -- otherwise
    -- viewing someone else's profession records it against the player at skill 0.
    if not playerOwnsProfession(base.professionID) then return end
    local ident = HDG.SessionIdentity.GetIdentity(HDG.Store:GetState())
    if not ident then return end
    -- Find Lumber awareness stamped here (profession-window context) to avoid
    -- a dedicated SPELLS_CHANGED listener for a single spell. Stale until the
    -- next scan if learned after the last profession open. Spell ID 1256697.
    local knowsFindLumber = false
    if _G.C_SpellBook and _G.C_SpellBook.IsSpellKnown then
        knowsFindLumber = _G.C_SpellBook.IsSpellKnown(1256697) or false
    end
    -- Knowledge idempotency (same cure as the capture diff): the LIST_UPDATE +
    -- DATA_SOURCE_CHANGED debounce pair and every craft tick re-fire Scan with an
    -- identical book -- skip the full-payload re-dispatch (and the downstream
    -- recipes.knowledge recompute downstream) when nothing changed.
    local skillLines   = readSkillLines()
    local knownRecipes = readKnownRecipes()
    local existingChar = HDG.Store:GetState().account.characters[ident.charKey]
    local existingProf = existingChar and existingChar.professions
                         and existingChar.professions[base.professionName]  -- exception(nullable): first record of this profession
    if existingProf
        and existingProf.knowsFindLumber == knowsFindLumber
        and sameSet(existingProf.knownRecipes, knownRecipes)
        and sameSkillLines(existingProf.skillLines, skillLines) then
        return
    end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.CHARACTER_PROFESSION_UPDATED,
        payload = {
            charKey         = ident.charKey,
            name            = ident.name,
            realm           = ident.realm,
            class           = ident.class,
            classFile       = ident.classFile,
            profName        = base.professionName,
            professionID    = base.professionID,   -- stable TradeSkillLineID; locale-invariant join key
            skillLines      = skillLines,
            knownRecipes    = knownRecipes,
            knowsFindLumber = knowsFindLumber,
        },
    })
end

-- ===== Spellbook pass: the logged-in character's decor recipes ===============
-- Brings the logged-in character's decor recipes in line with the spellbook. The window
-- scan above writes a profession's whole list, but only when that window opens; a recipe
-- learned with it shut reaches the list here. Decor spells only (recipes.spellToItem),
-- both ways: adds what the spellbook knows and no list holds, removes what a list holds
-- and the spellbook no longer knows (a dropped profession). The rest of each list, the
-- record and its skillLines stay the window scan's. Every reader asks recipes.knowledge,
-- which derives from these lists -- there is no second copy of "known" to drift.

-- Whether any of the character's records lists spellID.
local function _isListed(char, spellID)
    for _, prof in pairs(char.professions) do
        if prof.knownRecipes[spellID] then return true end
    end
    return false
end

-- File a newly learned spell under its root profession (asked of the recipe itself --
-- stored profession labels have been wrong, see recipeProfessionName).
local function _noteAdd(add, spellID, CT)
    local professionID, name = recipeRootProfession(spellID, CT)
    local entry = add[professionID]
    if not entry then
        entry = { name = name, spells = {} }
        add[professionID] = entry
    end
    entry.spells[spellID] = true
end

-- Remove a spell from every record that lists it (keyed by record, so an id-less legacy
-- record can be named too). Two records can list one spell -- an id-less legacy record
-- beside its profession's stamped one -- and both lose it in the same pass.
local function _noteRemove(remove, char, spellID)
    for key, prof in pairs(char.professions) do
        if prof.knownRecipes[spellID] then
            remove[key] = remove[key] or {}   -- exception(nullable): the first spell removed from this record
            remove[key][spellID] = true
        end
    end
end

-- The delta between the spellbook and the character's lists, over every decor spell,
-- and how many of those spells the spellbook knows. char is nil before the character's
-- first roster record.
local function _spellbookDelta(char, spellToItem, CT)
    local add, remove, moved, knownCount = {}, {}, false, 0
    local bank = _G.Enum.SpellBookSpellBank.Player
    for spellID in pairs(spellToItem) do
        -- exception(boundary): Blizzard bool; the bank is passed because a Reference note says omitting it returns nil
        local known = _G.C_SpellBook.IsSpellKnown(spellID, bank) == true
        local listed = char and _isListed(char, spellID)  -- exception(nullable): no roster record yet
        if known then knownCount = knownCount + 1 end
        if known and not listed then
            _noteAdd(add, spellID, CT)
            moved = true
        elseif listed and not known then
            _noteRemove(remove, char, spellID)
            moved = true
        end
    end
    return add, remove, moved, knownCount
end

-- The session's first pass is announced on the rail; later ones (every recipe learned,
-- decor or not, and every capture) go to the Debug tab only (review 2026-10-15). The
-- first also runs the one-shot drift check: recipe vendors missing from VendorAugment
-- (generated tables out of step). The facade computes; this logs, and the selectors
-- that join the two skip such vendors silently.
function PS:_AnnouncePass(knownCount)
    local line = string.format("Recipe check complete -- %d decor recipes known on this character", knownCount)
    if self._announced then
        HDG.Log:Debug("recipes_rescanned", line)
        return
    end
    self._announced = true
    HDG.Log:Success("recipes_scanned", line)
    local n, sample = HDG.StaticData.RecipeSources:VendorAugmentGaps()
    if n > 0 then
        HDG.Log:Warn("data_drift", ("%d recipe vendor(s) missing from VendorAugment: %s%s")
            :format(n, table.concat(sample, ", "), n > 8 and ", ..." or ""))
    end
end

-- One code path for every trigger (login catalog-ready, a recipe learned, a capture):
-- read the spellbook, dispatch only when something moved. Returns whether it dispatched.
function PS:SyncKnownDecorRecipes()
    local state = HDG.Store:GetState()
    local ident = HDG.SessionIdentity.GetIdentity(state)
    if not ident then return false end  -- exception(nullable): boot window, identity not dispatched yet
    local spellToItem = HDG.Selectors:Call("recipes.spellToItem", state)
    local char = state.account.characters[ident.charKey]  -- exception(nullable): no roster record before the first snapshot
    local add, remove, moved, knownCount = _spellbookDelta(char, spellToItem, _G.C_TradeSkillUI)
    PS:_AnnouncePass(knownCount)
    if not moved then return false end
    HDG.Store:Dispatch({
        type    = HDG.Constants.ACTIONS.CHARACTER_RECIPES_SYNCED,
        payload = {
            charKey = ident.charKey, name = ident.name, realm = ident.realm,
            class = ident.class, classFile = ident.classFile,
            add = add, remove = remove,
        },
    })
    return true
end

-- ===== Guild recipe harvest ==================================================
-- "Scan Guild" (Recipes title): walks every guild profession via the legacy guild
-- tradeskill globals (QueryGuildRecipes -> GUILD_TRADESKILL_UPDATE headers ->
-- ViewGuildRecipes per profession) and lets the EXISTING capture pipeline record
-- each one -- ViewGuildRecipes opens a normal tradeskill window, so the standing
-- debounced TRADE_SKILL_LIST_UPDATE -> Scan() -> CaptureRecipeData path fires
-- unchanged; this block is pure choreography (queue/open/wait/close/next).
-- Guildmates do NOT need to be online (guild-aggregated data). Traps ported from
-- VWB RecipeHarvest: player filter state silently truncates GetAllRecipeIDs
-- (snapshot/force/restore), own-open SetAlpha(0) window guard, combat abort,
-- per-profession timeout, cancellation token.

PS._harvest = PS._harvest or {
    active = false, token = 0, queue = {}, queueIndex = 0, total = 0,
    loadingProfession = nil, openedTradeSkill = false, headersReceived = false,
    filterSnapshot = nil, startCount = 0,
}

local function harvestProgress(payload)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.RECIPE_HARVEST_PROGRESS, payload = payload })
end

local function captureStoreCount()
    local n = 0
    for _ in pairs(HDG.Store:GetState().account.recipeCapture) do n = n + 1 end
    return n
end

-- The guild view inherits the player's own profession-window list filters (Show
-- Unlearned / source types), which silently truncates GetAllRecipeIDs. Snapshot +
-- force-show-all + restore (Blizzard's Professions.ResetFilters does the same).
local function snapshotRecipeFilters()
    local CT = _G.C_TradeSkillUI
    return {
        showLearned    = CT.GetShowLearned(),
        showUnlearned  = CT.GetShowUnlearned(),
        onlyMakeable   = CT.GetOnlyShowMakeableRecipes(),
        onlySkillUp    = CT.GetOnlyShowSkillUpRecipes(),
        onlyFirstCraft = CT.GetOnlyShowFirstCraftRecipes(),
        sourceType     = CT.GetSourceTypeFilter(),
    }
end

local function forceShowAllRecipes()
    local CT = _G.C_TradeSkillUI
    CT.SetShowLearned(true)
    CT.SetShowUnlearned(true)
    CT.SetOnlyShowMakeableRecipes(false)
    CT.SetOnlyShowSkillUpRecipes(false)
    CT.SetOnlyShowFirstCraftRecipes(false)
    CT.ClearRecipeSourceTypeFilter()
end

-- The snapshot has to outlive the session. These flags PERSIST across sessions and are
-- inherited by the guild view, so a /reload or logout mid-harvest used to leave the
-- player's own profession window permanently forced to show-everything with their
-- filters cleared, and nothing would ever put it back (review 2026-08-23).
-- Parked on account.ui through the generic persisted setter rather than minting an
-- action for one recovery latch; it is read back on the next profession window open.
local FILTER_RESTORE_KEY = "professionFilterRestore"

local function parkFilterSnapshot(snap)
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.UI_SET_PERSISTENT,
                         payload = { key = FILTER_RESTORE_KEY, value = snap } })
end

local function restoreRecipeFilters(snap)
    if not snap then return end  -- exception(nullable): no snapshot when harvest never started
    local CT = _G.C_TradeSkillUI
    CT.SetShowLearned(snap.showLearned)
    CT.SetShowUnlearned(snap.showUnlearned)
    CT.SetOnlyShowMakeableRecipes(snap.onlyMakeable)
    CT.SetOnlyShowSkillUpRecipes(snap.onlySkillUp)
    CT.SetOnlyShowFirstCraftRecipes(snap.onlyFirstCraft)
    if not snap.sourceType or snap.sourceType == 0 then
        CT.ClearRecipeSourceTypeFilter()  -- exception(boundary): Set(0) validity unverified; Clear is the safe no-filter
    else
        CT.SetSourceTypeFilter(snap.sourceType)
    end
end

-- Close OUR guild tradeskill window + unhide the frame. Never touches a
-- player-opened session (openedTradeSkill gates every call). CloseTradeSkill is a
-- protected UIPanel close and every harvest path reaches here from a timer stack --
-- NEVER call it in combat (repo rule); the guild window is left open + visible for
-- the player instead. SetAlpha is a non-secure attribute, safe either way.
local function restoreProfessionsFrame()
    local h = PS._harvest
    if h.openedTradeSkill then
        h.openedTradeSkill = false
        if not _G.InCombatLockdown() then
            _G.C_TradeSkillUI.CloseTradeSkill()
        end
    end
    if _G.ProfessionsFrame then _G.ProfessionsFrame:SetAlpha(1) end  -- exception(boundary): Blizzard_Professions may never have loaded
end


local function harvestTeardown()
    local h = PS._harvest
    h.token = h.token + 1   -- invalidate every pending timer closure
    restoreProfessionsFrame()
    restoreRecipeFilters(h.filterSnapshot)
    parkFilterSnapshot(nil)   -- clean teardown: nothing left to recover
    h.filterSnapshot = nil
    h.active = false
    h.loadingProfession = nil
end

local function harvestFinish(errorReason)
    local h = PS._harvest
    harvestTeardown()
    if errorReason then
        harvestProgress({ phase = "error" })
        HDG.Log:Warn("recipe_capture", "Guild scan: " .. errorReason)
        return
    end
    harvestProgress({ phase = "complete", done = h.total, total = h.total })
    HDG.Log:Success("guild_harvest", string.format(
        "Guild scan complete -- %d professions scanned, %d decor recipes on file (+%d)",
        h.total, captureStoreCount(), captureStoreCount() - h.startCount))
end

function PS:CancelGuildHarvest()
    if not PS._harvest.active then return end
    harvestTeardown()
    harvestProgress({ phase = "cancelled" })
end

local function harvestCanStart()
    local h = PS._harvest
    if h.active then return false, "already scanning" end
    if _G.InCombatLockdown() then return false, "cannot scan in combat" end
    if not _G.IsInGuild() then return false, "you are not in a guild" end
    if not HDG.HousingCatalogObserver:IsReady() then return false, "decor catalog still loading -- try again shortly" end
    if _G.ProfessionsFrame and _G.ProfessionsFrame:IsShown() then return false, "close your profession window first" end  -- exception(boundary): Blizzard_Professions may not be loaded
    if _G.C_TradeSkillUI.IsNPCCrafting() then return false, "cannot scan while crafting at an NPC" end
    return true
end

-- Chain to the next queued profession (or finish). ViewGuildRecipes opens the
-- guild view; the standing TRADE_SKILL_LIST_UPDATE debounce fires Scan() ->
-- capture -> _HarvestOnListUpdate below chains onward.
-- Hide OUR guild-opened window (SetAlpha, never Hide -- Hide tears down tradeskill
-- state). The provenance check keeps a player's OWN crafting window visible even if
-- they open it mid-harvest (VGC 1.4.2 bug class).
function PS:_HideOurGuildWindow()
    if PS._harvest.openedTradeSkill and _G.ProfessionsFrame
        and isForeignTradeSkill(_G.C_TradeSkillUI) then
        _G.ProfessionsFrame:SetAlpha(0)
    end
end

-- A harvest that died mid-flight (reload, logout, disconnect) never ran its teardown,
-- so the player's filters are still forced open. Put them back the next time a
-- profession window appears, then clear the latch. Never runs during a live harvest --
-- teardown owns the restore there.
function PS:_RecoverParkedFilters()
    if PS._harvest.active then return end
    local parked = HDG.Store:GetState().account.ui[FILTER_RESTORE_KEY]
    if not parked then return end  -- exception(nullable): no interrupted harvest to recover
    restoreRecipeFilters(parked)
    parkFilterSnapshot(nil)
    HDG.Log:Debug("recipe_capture", "restored profession filters parked by an interrupted guild scan")
end

-- Idempotent: ADDON_LOADED and the onEnable catch-up both call it.
function PS:_InstallProfessionsFrameHook()
    if PS._pfHooked or not _G.ProfessionsFrame then return end  -- exception(boundary): LoD frame
    PS._pfHooked = true
    _G.ProfessionsFrame:HookScript("OnShow", function() PS:_HideOurGuildWindow() end)
end

local function harvestLoadNext()
    local h = PS._harvest
    -- Combat abort at the chain boundary (PLAYER_REGEN_DISABLED is CombatMiddleware-owned,
    -- FORBIDDEN_MODULE_EVENTS -- modules poll at their own step boundaries instead).
    if _G.InCombatLockdown() then
        PS:CancelGuildHarvest()
        HDG.Log:Warn("recipe_capture", "Guild scan aborted: entered combat")
        return
    end
    local token = h.token
    h.queueIndex = h.queueIndex + 1
    local prof = h.queue[h.queueIndex]
    if not prof then
        harvestFinish()
        return
    end
    -- Blizzard gates its own "All Recipes" button on CanViewGuildRecipes. Without the
    -- same check a rank that cannot view simply never opens a window, and the chain
    -- waits out the full per-profession timeout instead -- twelve professions of that
    -- is two minutes of nothing, reported as success.
    if _G.CanViewGuildRecipes and not _G.CanViewGuildRecipes(prof.id) then  -- exception(boundary): bare FrameXML global
        HDG.Log:Debug("recipe_capture", "Guild scan: rank cannot view " .. tostring(prof.name) .. ", skipping")
        -- Advance immediately: nothing was opened, so there is nothing to wait for or
        -- restore. Bounded by the queue length (one pass per profession), not recursion depth.
        harvestLoadNext()
        return
    end
    h.loadingProfession = prof.id
    h.openedTradeSkill = true
    harvestProgress({ phase = "profession", done = h.queueIndex - 1, total = h.total, name = prof.name })
    _G.ViewGuildRecipes(prof.id)
    -- Timeout: profession never loaded (huge prof / server hiccup) -> skip it.
    _G.C_Timer.After(HDG.Constants.GUILD_HARVEST_PROF_TIMEOUT, function()
        if PS._harvest.token ~= token then return end
        if PS._harvest.loadingProfession == prof.id then
            HDG.Log:Debug("recipe_capture", "Guild scan: timeout on " .. prof.name .. ", skipping")
            PS._harvest.loadingProfession = nil
            restoreProfessionsFrame()
            _G.C_Timer.After(HDG.Constants.GUILD_HARVEST_PAUSE, function()
                if PS._harvest.token ~= token then return end
                harvestLoadNext()
            end)
        end
    end)
end

-- GUILD_TRADESKILL_UPDATE after QueryGuildRecipes: build the profession queue from
-- the header rows (GetGuildTradeSkillInfo is headers-only in modern WoW; numPlayers
-- filters headers with no crafters). One-shot per run -- ignores strays mid-harvest.
function PS._HarvestOnHeaders()
    local h = PS._harvest
    if not h.active or h.headersReceived then return end
    h.headersReceived = true
    local queue = {}
    for i = 1, (_G.GetNumGuildTradeSkill() or 0) do  -- exception(boundary): legacy guild tradeskill API
        local skillID, _, _, headerName, _, _, numPlayers = _G.GetGuildTradeSkillInfo(i)
        if headerName and headerName ~= "" and numPlayers and numPlayers > 0 then
            queue[#queue + 1] = { id = skillID, name = headerName }
        end
    end
    table.sort(queue, function(a, b) return a.name < b.name end)
    h.queue, h.queueIndex, h.total = queue, 0, #queue
    if #queue == 0 then
        harvestFinish("no guild profession data with active crafters")
        return
    end
    harvestLoadNext()
end

-- Called after every Scan() (see OnListUpdate): when the loaded window is OURS,
-- capture has already run inside Scan -- close it and chain to the next profession.
function PS._HarvestOnListUpdate()
    local h = PS._harvest
    if not (h.active and h.loadingProfession and h.openedTradeSkill) then return end
    -- Combat began during the debounce wait: abort. restoreProfessionsFrame (via
    -- teardown) skips the protected CloseTradeSkill in combat.
    if _G.InCombatLockdown() then
        PS:CancelGuildHarvest()
        HDG.Log:Warn("recipe_capture", "Guild scan aborted: entered combat")
        return
    end
    -- A NON-guild window loaded mid-harvest = the player opened their own book;
    -- they win. Cancel without ever closing/unhiding their session.
    if not isForeignTradeSkill(_G.C_TradeSkillUI) then
        h.openedTradeSkill = false
        PS:CancelGuildHarvest()
        HDG.Log:Info("recipe_capture", "Guild scan cancelled: profession window in use")
        return
    end
    local token = h.token
    h.loadingProfession = nil
    restoreProfessionsFrame()
    _G.C_Timer.After(HDG.Constants.GUILD_HARVEST_PAUSE, function()
        if PS._harvest.token ~= token then return end
        harvestLoadNext()
    end)
end

function PS:StartGuildHarvest()
    local ok, reason = harvestCanStart()
    if not ok then
        HDG.Log:Info("recipe_capture", "Guild scan: " .. reason)
        return
    end
    if not _G.C_AddOns.IsAddOnLoaded("Blizzard_Communities") then
        _G.C_AddOns.LoadAddOn("Blizzard_Communities")  -- exception(boundary): QueryGuildRecipes lives in the guild UI addon
    end
    local h = PS._harvest
    h.token = h.token + 1
    local token = h.token
    h.active = true
    h.queue, h.queueIndex, h.total = {}, 0, 0
    h.headersReceived = false
    h.startCount = captureStoreCount()
    h.filterSnapshot = snapshotRecipeFilters()
    parkFilterSnapshot(h.filterSnapshot)
    forceShowAllRecipes()
    harvestProgress({ phase = "headers" })
    -- Timeout: guild data never arrived.
    _G.C_Timer.After(HDG.Constants.GUILD_HARVEST_HEADER_TIMEOUT, function()
        if PS._harvest.token ~= token then return end
        if PS._harvest.active and PS._harvest.total == 0 then
            harvestFinish("no guild profession data received")
        end
    end)
    _G.QueryGuildRecipes()
end

-- ===== Recipe acquisition text ===============================================
-- Where an unlearned recipe comes from, per the profession book's own hover.
--
-- Lives HERE because this module is the declared sole owner of C_TradeSkillUI
-- (ADR-011, boot-validated disjoint) -- the parse itself is a pure Core file.
--
-- The getter is SYNCHRONOUS and answers cold: the first call already returns the
-- answer, so there is NO tick and NO dispatch here. The first cut copied
-- ItemNameResolver's resolve-and-tick shape -- which exists because item info
-- arrives ASYNCHRONOUSLY -- and fired a store action on every first fill. Since
-- this is read from a selector and from a tooltip build, that put an
-- invalidate-and-repaint in the middle of a paint, once per newly-seen recipe,
-- nested (Store:Dispatch has no reentrancy guard). Shipped in 3.31.0 and
-- reported as the window being laggy. Memoised per spellID, and MISSES TOO
-- (as `false`): about 1 recipe in 20 has no acquisition data, and without a
-- negative entry those would re-ask the API on every repaint forever.
--
-- Lazy by design -- no walk at login. 325 decor recipes fill as they are looked
-- at, which is a handful per session, not a sweep.
local _recipeSource = {}

function PS:GetRecipeSource(spellID)
    if not spellID then return nil end  -- exception(nullable): non-crafted rows have none
    local hit = _recipeSource[spellID]
    if hit ~= nil then
        return hit or nil   -- false is the memoised miss
    end
    -- exception(boundary): undocumented Blizzard getter; nil OR "" when the
    -- server has no acquisition data, and "" is truthy in Lua.
    local raw = _G.C_TradeSkillUI and _G.C_TradeSkillUI.GetRecipeSourceText
        and _G.C_TradeSkillUI.GetRecipeSourceText(spellID) or nil
    local parsed = HDG.RecipeSourceParse.Parse(raw)
    _recipeSource[spellID] = parsed or false
    return parsed
end

-- The same answer, keyed by the CRAFTED ITEM rather than the recipe spell.
--
-- Every surface that wants this holds an itemID, and HDG's own row envelopes
-- call that id `recipeID` ("recipeID == produced itemID", Selectors_Recipes) --
-- which reads exactly like the spell id this API needs and is not. Passing one
-- for the other returns nil forever and looks like an item with no data, so the
-- conversion lives HERE and no call site has to know the difference.
function PS:GetRecipeSourceForItem(itemID)
    if not itemID then return nil end  -- exception(nullable): header rows carry no item
    local recipe = HDG.StaticData.Recipes:Get(itemID)  -- exception(nullable): not every crafted item is in DecorDB
    if not recipe then return nil end
    return self:GetRecipeSource(recipe.spellID)
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "ProfessionScanner",
    dependencies = { "HousingCatalogObserver" },
    -- per ADR-011: sole owner of C_TradeSkillUI, and of C_SpellBook.IsSpellKnown --
    -- the spellbook pass and the Find Lumber read; one module writes knownRecipes.
    -- Guild tradeskill globals (QueryGuildRecipes/ViewGuildRecipes/
    -- GetGuildTradeSkillInfo) are legacy non-C_ APIs -- no namespace claim.
    ownsBlizzardNamespaces = { "C_TradeSkillUI", "C_SpellBook.IsSpellKnown" },
    logTags = {
        guild_harvest     = { user = true, level = "success", duration = 4 },
        recipes_scanned   = { user = true, level = "success", duration = 3 },
        recipes_rescanned = { user = false, level = "debug" },
        data_drift        = { user = false, level = "warn" },
    },
    blizzardEvents = {
        -- Initial list ready + recipe-learned updates.
        TRADE_SKILL_LIST_UPDATE         = { handler = "OnListUpdate", debounce = 0.5 },
        -- Expansion sub-tab switch inside one profession; re-scan so skill
        -- ladder reflects the active child.
        TRADE_SKILL_DATA_SOURCE_CHANGED = { handler = "OnListUpdate", debounce = 0.5 },
        -- Guild harvest choreography (all no-op unless a harvest is active).
        -- Combat abort polls InCombatLockdown at chain boundaries -- PLAYER_REGEN_*
        -- is FORBIDDEN_MODULE_EVENTS (CombatMiddleware-owned).
        GUILD_TRADESKILL_UPDATE         = { handler = "OnGuildTradeSkill" },
        TRADE_SKILL_SHOW                = { handler = "OnTradeSkillShow" },
        -- Trainer, recipe scroll and skill-up learns all fire it, window open or not.
        -- Debounced: "learn all" bursts coalesce into one spellbook pass.
        NEW_RECIPE_LEARNED              = { handler = "OnRecipeLearned", debounce = 0.5 },
    },
    OnListUpdate = function(self)
        PS:Scan()
        PS._HarvestOnListUpdate()
    end,
    OnRecipeLearned = function(self)
        PS:SyncKnownDecorRecipes()
    end,
    onEnable = function(self)
        -- ProfessionsFrame OnShow is the RELIABLE hook. TRADE_SKILL_SHOW alone was not:
        -- Blizzard_Professions is load-on-demand and is loaded BY that event, so on the
        -- first guild profession of a session `_G.ProfessionsFrame` was still nil when we
        -- looked, the alpha never applied, and the window opened full-size over the screen.
        -- The sibling ProfessionButtons module already uses this ADDON_LOADED shape.
        HDG.BlizzardEvents:_internalSubscribe("ADDON_LOADED", function(name)
            if name ~= "Blizzard_Professions" then return end
            PS:_InstallProfessionsFrameHook()
        end)
        -- Covers the case where Blizzard_Professions loaded before onEnable ran.
        PS:_InstallProfessionsFrameHook()

        -- DECOR_CATALOG_READY: the session's spellbook pass (the sweep that dispatches it
        -- is lazy and runs after SESSION_IDENTITY_SET), and a re-scan while the profession
        -- window is still open, so a capture that skipped a cold catalog lands.
        -- RECIPE_DATA_CAPTURED: a capture can materialize a decor recipe this character
        -- already knows; the pass is diffed, so an unchanged spellbook costs no dispatch.
        self._storeToken = HDG.Store:Subscribe(function(actionType)
            if actionType == HDG.Constants.ACTIONS.DECOR_CATALOG_READY then
                local CT = _G.C_TradeSkillUI
                if CT and CT.IsTradeSkillReady and CT.IsTradeSkillReady() then  -- exception(boundary): profession window not open
                    PS:Scan()
                end
                PS:SyncKnownDecorRecipes()
            elseif actionType == HDG.Constants.ACTIONS.RECIPE_DATA_CAPTURED then
                PS:SyncKnownDecorRecipes()
            end
        end)
    end,
    onShutdown = function(self)
        if self._storeToken then
            HDG.Store:Unsubscribe(self._storeToken)
            self._storeToken = nil
        end
    end,
    OnGuildTradeSkill = function(self)
        PS._HarvestOnHeaders()
    end,
    OnTradeSkillShow = function(self)
        PS:_HideOurGuildWindow()
        PS:_RecoverParkedFilters()
    end,
})
