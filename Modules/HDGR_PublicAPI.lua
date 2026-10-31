-- ============================================================================
-- HDGR -- Public API
-- ============================================================================
-- THE ONLY SURFACE ANOTHER ADDON MAY TOUCH. Everything else in HDG is internal
-- and moves without notice; what is declared here is a contract, versioned, and
-- changed by adding rather than by editing.
--
-- WHY IT EXISTS. Aegis's guild blueprint library can tell a member they are
-- missing 35 pieces of a build, and it deliberately knows nothing about where
-- decor comes from -- that is a catalog, a vendor table and a routing engine,
-- all of which live here. Rather than copy any of that into Aegis, Aegis hands
-- over what the SERVER told it and HDG does the part it owns.
--
-- THE CALLER IS NOT TRUSTED TO BE CORRECT, only to be well-meaning. Every
-- argument is checked at this boundary, because a wrong shape from another
-- addon must produce a refusal rather than an error inside HDG's store -- the
-- player would see a HDG error and blame HDG.
--
-- CONSUMERS MUST DEGRADE. HDG is not a dependency of anything that calls this:
-- the calling addon is expected to check `HousingDecorGuide.API` exists and to
-- carry on without it, so nothing here may be required for that addon to work.

-- HDG IS A GLOBAL HERE, not a varargs table -- the convention every other HDGR
-- module follows (`HDG = HDG or {}` with no `local`). Taking the varargs table
-- instead shadowed it with an empty one, so every HDG.* read inside this file
-- came back nil and the first live click threw on HousingCatalogObserver.
HDG = HDG or {}

local API = { version = 1 }
HDG.API = API

-- PUBLISHED UNDER THE FULL NAME, not the terse `HDG` global. Another addon
-- reaching for a two-letter global is asking for a collision, and this handle
-- says whose API it is. Aegis reads exactly this.
_G.HousingDecorGuide = _G.HousingDecorGuide or {}
_G.HousingDecorGuide.API = API

-- Blueprint manifest content types. The SAME numbers mean different things in
-- Enum.HousingBlueprintType, which is why they are never called `type` here.
local CT_DECOR, CT_DYE = 3, 4

-- ============================================================================
-- ROUTE A BLUEPRINT'S MISSING PIECES TO A SHOPPING LIST
-- ============================================================================
-- req = {
--   shareCode = "<24 base64 chars>",   -- identity; re-routing UPSERTS its list
--   name      = "Lakeside Retreat",    -- what the list is called
--   entries   = {                      -- straight off the game's own manifest
--     { contentType = 3, recordID = 12345, numMissing = 7 }, ...
--   },
-- }
--
-- Returns  routed, skipped   on success -- how many items landed on the list,
--                            and how many could not be resolved to something
--                            buyable (not in the catalog yet, or structural).
-- Returns  nil, reason       when it will not run: "bad-request", "not-ready".
--
-- IDENTITY IS THE SHARE CODE, matching HDG's own blueprint routing: the list is
-- keyed `blueprint:<shareCode>`, so a member who routes the same build twice
-- refreshes one list instead of collecting duplicates.
--
-- NOT EVERY MISSING PIECE IS BUYABLE. Rooms, house types and fixtures are
-- structural -- there is no vendor for them -- and a decor row the catalog has
-- not baked yet has no itemID. Both are counted as `skipped` and reported to
-- the caller rather than silently dropped, because "35 missing" turning into a
-- list of 23 with no explanation is the kind of arithmetic players screenshot.
function API.RouteBlueprintToShopping(req)
    if type(req) ~= "table" then return nil, "bad-request" end
    local code, name, entries = req.shareCode, req.name, req.entries
    if type(code) ~= "string" or code == "" then return nil, "bad-request" end
    if type(name) ~= "string" or name == "" then return nil, "bad-request" end
    if type(entries) ~= "table" then return nil, "bad-request" end

    -- The catalog is what turns a recordID into something with a vendor. Before
    -- it is ready every lookup would miss and the list would come out empty,
    -- which reads as "this build needs nothing" -- the opposite of the truth.
    if not HDG.HousingCatalogObserver:IsReady() then return nil, "not-ready" end

    local items, skipped = {}, 0
    for _, e in ipairs(entries) do
        local need = type(e) == "table" and e.numMissing or 0
        if type(need) == "number" and need > 0 then
            local ct = e.contentType
            -- npcID 0: the vendor is resolved at routing time from the item,
            -- which is how HDG's own blueprint routing builds these rows.
            local itemID = (ct == CT_DECOR or ct == CT_DYE)
                and HDG.HousingCatalogObserver:ItemIDForEntry(e) or nil
            if itemID then
                items[#items + 1] = { itemID = itemID, npcID = 0, qty = need }
            else
                skipped = skipped + 1
            end
        end
    end

    local encoded = HDG.ShoppingCodec.Encode({
        name = name, items = items,
        meta = { source = "blueprint", url = "blueprint:" .. code, desc = name },
    })
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_LIST_IMPORT,
                         payload = { encoded = encoded } })
    -- The import makes its list the active one. Count what landed there, not what
    -- was sent: the decoder drops entries the catalog can't match.
    local account = HDG.Store:GetState().account
    local landed  = #account.vendorShoppingLists[account.activeShoppingListId].items

    -- SHOW THE RESULT. A list that lands silently in a closed window is a
    -- click that appeared to do nothing -- same reasoning as HDG's own routing.
    if HDG.Store:GetState().account.ui.shoppingWidgetShown ~= true then
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.SHOPPING_WIDGET_TOGGLE })
    end

    -- TAG "blueprints", NOT "api". Log tags are a closed taxonomy -- Push errors
    -- on an unregistered one -- and they are declared by registered Modules via
    -- `logTags`. This file is deliberately not a Module (no events, no lifecycle,
    -- nothing to initialise), so inventing a tag here would mean declaring one
    -- purely to own a string. The operation IS blueprint routing, and it is what
    -- HDG's own Route to Shopping logs under, so the honest tag already exists.
    HDG.Log:Info("blueprints", ("routed %q via the API: %d item(s), %d skipped")
        :format(name, landed, skipped))
    return landed, skipped
end
