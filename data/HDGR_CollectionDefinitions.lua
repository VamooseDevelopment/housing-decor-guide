-- HDGR_CollectionDefinitions.lua
-- Useful Collections: auto-resolved item groups from AllDecorDB name patterns
-- Each collection uses string.find() on item names (case-sensitive, substring match)
-- namePatterns = OR logic (match any), excludePatterns = override (exclude if any match)

HDGR_CollectionDefinitions = {

    -- ========================================================================
    -- FURNITURE
    -- ========================================================================

    ["chairs-seating"] = {
        displayName = "Chairs & Seating",
        icon = "Interface\\Icons\\INV_Misc_Bag_Chair",
        tier = "collection",
        color = { r = 0.72, g = 0.53, b = 0.33 },
        description = "All types of chairs, benches, stools, thrones, and seating furniture for your home.",
        namePatterns = { "Chair", "Bench", "Stool", "Throne", "Bean Bag" },
        excludePatterns = { "Grindstone", "Workbench" },
    },

    ["tables-desks"] = {
        displayName = "Tables & Desks",
        icon = "Interface\\Icons\\INV_Misc_Desecrated_PlateBoots",
        tier = "collection",
        color = { r = 0.65, g = 0.50, b = 0.35 },
        description = "Tables, desks, counters, and flat work surfaces of every shape and culture.",
        namePatterns = { "Table", "Desk" },
        excludePatterns = { "Stable", "Adjustable", "Turntable", "Notable" },
    },

    ["beds-bedding"] = {
        displayName = "Beds & Bedding",
        icon = "Interface\\Icons\\INV_Misc_Bed_02",
        tier = "collection",
        color = { r = 0.55, g = 0.45, b = 0.65 },
        description = "Beds, cots, hammocks, bunk beds, and sleeping furniture.",
        namePatterns = { " Bed", "Bunkbed", "Hammock", "Cot ", "Sleeping Cot", "Divan", "Couch" },
    },

    ["shelves-storage"] = {
        displayName = "Shelves & Bookcases",
        icon = "Interface\\Icons\\INV_Misc_Book_09",
        tier = "collection",
        color = { r = 0.58, g = 0.44, b = 0.30 },
        description = "Shelving, bookcases, cabinets, dressers, wardrobes, and display storage.",
        namePatterns = { "Shelf", "Shelves", "Bookcase", "Cabinet", "Dresser", "Wardrobe", "Armoire", "Hutch" },
    },

    ["barrels-crates"] = {
        displayName = "Barrels & Crates",
        icon = "Interface\\Icons\\INV_Crate_02",
        tier = "collection",
        color = { r = 0.60, g = 0.45, b = 0.28 },
        description = "Barrels, crates, kegs, and bulk storage containers.",
        namePatterns = { "Barrel", "Crate", "Keg" },
    },

    ["cushions-pillows"] = {
        displayName = "Cushions & Pillows",
        icon = "Interface\\Icons\\INV_Fabric_Linen_01",
        tier = "collection",
        color = { r = 0.70, g = 0.55, b = 0.70 },
        description = "Throw pillows, seat cushions, blankets, and other soft furnishings.",
        namePatterns = { "Cushion", "Pillow", "Blanket" },
    },

    -- ========================================================================
    -- LIGHTING
    -- ========================================================================

    ["candles-braziers"] = {
        displayName = "Candles & Braziers",
        icon = "Interface\\Icons\\INV_Misc_Candle_01",
        tier = "collection",
        color = { r = 0.90, g = 0.65, b = 0.20 },
        description = "Candles, braziers, torches, candelabras, and open-flame light sources.",
        namePatterns = { "Candle", "Brazier", "Torch", "Candelabra" },
    },

    ["lamps-lanterns"] = {
        displayName = "Lamps & Lanterns",
        icon = "Interface\\Icons\\INV_Offhand_Stratholme_A_02",
        tier = "collection",
        color = { r = 0.85, g = 0.75, b = 0.40 },
        description = "Lamps, lanterns, sconces, lampposts, and enclosed light sources.",
        namePatterns = { "Lamp", "Lantern", "Sconce", "Lamppost" },
    },

    ["chandeliers"] = {
        displayName = "Chandeliers",
        icon = "Interface\\Icons\\INV_Misc_Chandelier_01",
        tier = "collection",
        color = { r = 0.80, g = 0.70, b = 0.50 },
        description = "Overhead chandeliers and hanging light fixtures.",
        namePatterns = { "Chandelier" },
    },

    -- ========================================================================
    -- TEXTILES
    -- ========================================================================

    ["rugs-carpets"] = {
        displayName = "Rugs & Carpets",
        icon = "Interface\\Icons\\INV_Misc_Rug_01",
        tier = "collection",
        color = { r = 0.72, g = 0.28, b = 0.28 },
        description = "Floor rugs, carpets, mats, and textile floor coverings.",
        namePatterns = { "Rug", "Carpet" },
    },

    ["banners-flags"] = {
        displayName = "Banners & Flags",
        icon = "Interface\\Icons\\INV_Banner_03",
        tier = "collection",
        color = { r = 0.75, g = 0.35, b = 0.25 },
        description = "Wall banners, flags, standards, pennants, and hanging displays.",
        namePatterns = { "Banner", "Flag", "Standard", "Pennant" },
    },

    ["curtains-drapes"] = {
        displayName = "Curtains & Drapes",
        icon = "Interface\\Icons\\INV_Fabric_Silk_01",
        tier = "collection",
        color = { r = 0.50, g = 0.40, b = 0.60 },
        description = "Window curtains, drapes, and hanging fabric dividers.",
        namePatterns = { "Curtain", "Drape" },
    },

    -- ========================================================================
    -- KNOWLEDGE & ART
    -- ========================================================================

    ["books-scrolls"] = {
        displayName = "Books & Scrolls",
        icon = "Interface\\Icons\\INV_Misc_Book_09",
        tier = "collection",
        color = { r = 0.50, g = 0.55, b = 0.70 },
        description = "Books, scrolls, tomes, manuscripts, scriptures, and written works.",
        namePatterns = { "Book", "Scroll", "Tome", "Manuscript", "Scripture", "Literature" },
        excludePatterns = { "Bookcase", "Bookshelf" },
    },

    ["paintings-art"] = {
        displayName = "Paintings & Portraits",
        icon = "Interface\\Icons\\INV_Misc_PaperBundle_02",
        tier = "collection",
        color = { r = 0.60, g = 0.45, b = 0.55 },
        description = "Paintings, portraits, tapestries, and wall-mounted artwork.",
        namePatterns = { "Painting", "Portrait", "Tapestry" },
    },

    -- ========================================================================
    -- NATURE & OUTDOOR
    -- ========================================================================

    ["plants-trees"] = {
        displayName = "Plants & Trees",
        icon = "Interface\\Icons\\INV_Misc_Herb_AncientLichen",
        tier = "collection",
        color = { r = 0.35, g = 0.70, b = 0.35 },
        description = "Living plants, trees, bushes, vines, ferns, flowers, cacti, and greenery.",
        namePatterns = { "Plant", "Tree", "Bush", "Shrub", "Vine", "Fern",
            "Flower", "Cactus", " Ivy", "Palm", "Moss", "Sapling" },
        excludePatterns = { "Treeline" },
    },

    ["rocks-stone"] = {
        displayName = "Rocks & Stone",
        icon = "Interface\\Icons\\INV_Ore_Mithril_01",
        tier = "collection",
        color = { r = 0.55, g = 0.55, b = 0.55 },
        description = "Natural rocks, boulders, stone formations, and geological features.",
        namePatterns = { "Rock", "Stone", "Boulder" },
        excludePatterns = { "Fireplace", "Fountain", "Grindstone", "Keystone",
            "Bookcase", "Stonework Fireplace", "Hearthstone" },
    },

    ["fountains-water"] = {
        displayName = "Fountains & Water",
        icon = "Interface\\Icons\\INV_Elemental_Mote_Water01",
        tier = "collection",
        color = { r = 0.30, g = 0.55, b = 0.80 },
        description = "Fountains, water basins, wells, and decorative water features.",
        namePatterns = { "Fountain", "Basin" },
    },

    ["garden-planting"] = {
        displayName = "Garden Features",
        icon = "Interface\\Icons\\INV_Misc_Herb_08",
        tier = "collection",
        color = { r = 0.45, g = 0.65, b = 0.35 },
        description = "Planters, garden fixtures, hedges, trellises, and topiary.",
        namePatterns = { "Planter", "Garden", "Hedge", "Trellis", "Topiary" },
    },

    -- ========================================================================
    -- FUNCTIONAL
    -- ========================================================================

    ["fireplaces"] = {
        displayName = "Fireplaces & Hearths",
        icon = "Interface\\Icons\\Spell_Fire_Incinerate",
        tier = "collection",
        color = { r = 0.85, g = 0.45, b = 0.20 },
        description = "Fireplaces, hearths, and indoor heating fixtures.",
        namePatterns = { "Fireplace", "Hearth" },
    },

    ["food-drink"] = {
        displayName = "Food & Drink",
        icon = "Interface\\Icons\\INV_Drink_10",
        tier = "collection",
        color = { r = 0.75, g = 0.55, b = 0.25 },
        description = "Platters, mugs, goblets, bottles, cheese, fruit, and food displays.",
        namePatterns = { "Platter", "Mug", "Goblet", "Bottle", "Cheese", "Fruit", "Takeout", "Snack", "Pie", "Brew" },
    },

    ["weapon-displays"] = {
        displayName = "Weapon Displays",
        icon = "Interface\\Icons\\INV_Sword_04",
        tier = "collection",
        color = { r = 0.60, g = 0.30, b = 0.30 },
        description = "Weapon racks, weapon stands, shield mounts, and martial displays.",
        namePatterns = { "Weapon Rack", "Weapon Stand", "Shield Mount", "Sword" },
    },

    ["workshop-craft"] = {
        displayName = "Workshop & Craft",
        icon = "Interface\\Icons\\Trade_BlackSmithing",
        tier = "collection",
        color = { r = 0.60, g = 0.50, b = 0.40 },
        description = "Anvils, forges, workbenches, looms, and profession-themed furniture.",
        namePatterns = { "Anvil", "Forge", "Workbench", "Loom", "Grinding" },
    },

    -- ========================================================================
    -- DECOR & THEMATIC
    -- ========================================================================

    ["signs-plaques"] = {
        displayName = "Signs & Plaques",
        icon = "Interface\\Icons\\INV_Misc_Note_01",
        tier = "collection",
        color = { r = 0.65, g = 0.60, b = 0.50 },
        description = "Signs, plaques, notice boards, and informational displays.",
        namePatterns = { "Sign", "Plaque", "Notice" },
        excludePatterns = { "Design", "Insignia", "Signed" },
    },

    ["walls-dividers"] = {
        displayName = "Walls & Dividers",
        icon = "Interface\\Icons\\Garrison_Building_Barracks",
        tier = "collection",
        color = { r = 0.50, g = 0.50, b = 0.50 },
        description = "Interior walls, room dividers, partitions, and structural screens.",
        namePatterns = { "Wall", "Partition", "Divider", "Room Screen" },
        excludePatterns = { "Sconce", "Drape" },
    },

    ["spooky-macabre"] = {
        displayName = "Spooky & Macabre",
        icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
        tier = "collection",
        color = { r = 0.45, g = 0.55, b = 0.35 },
        description = "Skulls, coffins, bones, skeletons, graves, and eerie decor.",
        namePatterns = { "Skull", "Coffin", "Bone", "Skeleton", "Grave", "Tombstone" },
        excludePatterns = { "Backbone" },
    },

    -- ========================================================================
    -- SPECIAL
    -- ========================================================================

    ["dyeable"] = {
        displayName = "Dyeable Items",
        icon = "Interface\\Icons\\INV_Inscription_Pigment_Bug",
        tier = "collection",
        color = { r = 0.40, g = 0.80, b = 1.00 },
        description = "All decor items that can be customized with dyes at the Dye Studio.",
        resolver = "dyeable",
    },

    ["trophies"] = {
        displayName = "Trophies",
        icon = "Interface\\Icons\\Achievement_Boss_Generic",
        tier = "collection",
        color = { r = 1.00, g = 0.78, b = 0.30 },
        description = "Unique-trophy decor and Preyseeker effigies -- the rare trophies earned through hard PVE content (raids, dungeons, prey hunts).",
        resolver = "trophies",
    },

    ["neighborhood"] = {
        displayName = "Neighborhood Decor",
        icon = "Interface\\Icons\\Garrison_Building_Barracks",
        tier = "collection",
        color = { r = 0.55, g = 0.80, b = 0.45 },
        description = "Decor sold by vendors in the housing neighborhoods, Founder's Point and Razorwind Shores.",
        resolver = "neighborhood",
    },

    ["recently-learned"] = {
        displayName = "Recently Learned",
        icon = "Interface\\Icons\\INV_Misc_Book_09",
        tier = "collection",
        color = { r = 0.9, g = 0.7, b = 0.2 },
        description = "Decor items recently added to your house chest.",
        resolver = "recently-learned",
    },
}

-- Display order for minicard grid
HDGR_CollectionOrder = {
    -- Special (most useful first)
    "recently-learned", "dyeable", "trophies", "neighborhood",
    -- Furniture
    "chairs-seating", "tables-desks", "beds-bedding",
    "shelves-storage", "barrels-crates", "cushions-pillows",
    -- Lighting
    "candles-braziers", "lamps-lanterns", "chandeliers",
    -- Textiles
    "rugs-carpets", "banners-flags", "curtains-drapes",
    -- Knowledge & Art
    "books-scrolls", "paintings-art",
    -- Nature & Outdoor
    "plants-trees", "rocks-stone", "fountains-water", "garden-planting",
    -- Functional
    "fireplaces", "food-drink", "weapon-displays", "workshop-craft",
    -- Decor & Thematic
    "signs-plaques", "walls-dividers", "spooky-macabre",
}
