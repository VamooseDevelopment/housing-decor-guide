-- HDGR_VendorRank -- which of an item's vendors to actually send someone to.
--
-- A catalog row can list several vendors, and until now every consumer took
-- `row.vendors[1]` -- whatever Blizzard's sourceText happened to parse first.
-- That produced two reported bugs:
--
--   * "Flat Boulder x6 -- Vendor: World Vendors" in a copied blueprint list,
--     because the synthetic grouping parses ahead of Trevor Grenner, who is
--     standing in Founder's Point with coordinates.
--   * An Alliance player's shopping list routing them to Razorwind Shores for
--     rugs that Founder's Point sells too -- the same merchant, "High Tides"
--     Ren, who has a row in both neighborhoods.
--
-- Pure, and deliberately not a method on HousingCatalogObserver: it is a rule
-- about a row's shape, not about observer state, and the observer is stubbed
-- out in most of the test suite. Here it loads with the Core engines, so the
-- shipped rule is the one under test.

HDG = HDG or {}
HDG.VendorRank = HDG.VendorRank or {}

-- THE "has a location" test (review 2026-10-15): can we put a pin or a waypoint on
-- this vendor? A VendorAugment row can carry an npcID and a zone with no map point
-- yet (a vendor new to the game), and mapID 0 is the master's "no map" (garrison
-- vendors). Every Map/Wpt gate, greyed button and "Map N" count asks this one
-- question, in zone-pct coords. Here rather than on StaticData for the reason
-- above: the facade is stubbed out in most of the suite.
function HDG.VendorRank.HasLocation(mapID, x, y)
    return mapID ~= nil and mapID > 0 and x ~= nil and y ~= nil
end

-- Rank 0  stands in the preferred neighborhood
-- Rank 1  any other routable vendor
-- Rank 2  the twin neighborhood, when a preference is set
-- Rank 3  unroutable -- no npcID, so nowhere to send anyone
--
-- Rank 3 keys on npcID, NOT on the name. Blizzard's synthetic groupings
-- ("World Vendors", "Draenor World Vendors") have no VendorAugment row and so
-- no npcID -- the same position a real-but-unwalked vendor is in, and we cannot
-- put a pin on either. Matching the NAME would mean matching a localised
-- string, which returns nothing at all on a French client, silently. (The
-- NEIGHBORHOOD_MAP_IDS comment makes the same argument for map IDs.)
--
-- Ranks 0 and 2 exist because 18 merchants stand in BOTH housing neighborhoods.
-- For those, the other faction's vendor and yours are the SAME PERSON, so
-- preferring the near one is a flight saved rather than a different shop.
local function _rank(vendor, preferredMapID)
    if not vendor.npcID then return 3 end  -- exception(nullable): synthetic grouping, or vendor not yet in VendorAugment
    if preferredMapID then
        if vendor.mapID == preferredMapID then return 0 end
        if HDG.Constants.NEIGHBORHOOD_MAP_IDS[vendor.mapID] then return 2 end
    end
    return 1
end

-- The row's best vendor, or nil when it has none.
--
-- preferredMapID is nil at catalog-bake time -- one baked row serves every
-- player, so a neighborhood preference must not be frozen into it -- and set at
-- display time from the shopping toggle. Nil still demotes the unroutable
-- groupings, which is the whole of the "Vendor: World Vendors" fix.
--
-- A linear min-scan rather than table.sort: sort is not stable in Lua 5.1, and
-- ties here must keep the catalog's own order so a row with nothing worth
-- reordering comes out exactly as it went in.
function HDG.VendorRank.Pick(row, preferredMapID)
    local vendors = row and row.vendors  -- exception(nullable): callers pass a catalog lookup that can miss
    if not vendors or #vendors == 0 then return nil end
    local best, bestRank = vendors[1], _rank(vendors[1], preferredMapID)
    for i = 2, #vendors do
        local rank = _rank(vendors[i], preferredMapID)
        if rank < bestRank then best, bestRank = vendors[i], rank end
    end
    return best
end
