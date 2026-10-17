HDG = HDG or {}
HDG.Constants = {
    ADDON_NAME = "HousingDecorGuide",
    -- HDG->HDGR migration schema. Bumps force the migration to RE-RUN (its steps
    -- are idempotent + self-repairing): v2 = per-char professions skillLevels->skillLines
    -- + name/realm parse; v3 = craft/lumber history ordered oldest-first (newest renders
    -- at top, matching the live *_HISTORY_PUSH append-at-end convention);
    -- v4 = collections transformed to the HDGR style model (curatedItems->items array,
    -- snapshot->snapshot type, query-only->smartset, crates dropped);
    -- v5 = re-key migrated snapshots/smartsets to the "snapshot:"/"smartset:" id prefix
    -- (the landing + Detail route by id prefix, not def.type);
    -- v6 = drop library-type collections (empty curated templates + player saves);
    -- v7 = Furnishings model: crates -> sets, version.rooms -> account.rooms +
    --      layout placements (docs/crate-redesign/10-FINAL-MODEL.md).
    SCHEMA_VERSION = 8,
    -- Standard icon crop (trims the baked border off square item icons).
    -- Consumed via SetTexCoord(unpack(HDG.Constants.ICON_CROP)) (hygiene A6).
    ICON_CROP = { 0.08, 0.92, 0.08, 0.92 },
    -- The player character measured in HDGR_PetSizeDB's units. The pet tooltip
    -- states a height against it, because a number in model units means nothing
    -- until it has something a player already has an eye for beside it.
    PET_CHARACTER_HEIGHT = 2.242,
    -- Generic bullet/blip dot glyph (tone varies per site; the atlas never does).
    BULLET_DOT_ATLAS = "PlayerPartyBlip",
    BLUEPRINT_REQUEST_TIMEOUT = 30,  -- s; big manifests take 5-10s, and some requests are silently dropped (no event at all)
    -- Currencies shown inline on the detail cost badge before "+N more". The
    -- badge shares a 22px band with the fit verdict, and a real build priced in
    -- 11 currencies ran off the panel's right edge; the hover tooltip carries
    -- the full list, so the badge only needs enough to read as "a price".
    BLUEPRINT_COST_BADGE_MAX = 3,
    -- Library (design 2026-09-11): one table drives the chip widgets, the chip
    -- selectors and the controller clicks; likewise for the sortable columns.
    -- Column widths are the header-button widths AND the row anchors.
    -- `firstDir` is the direction a column sorts when it BECOMES the sort column
    -- (text reads ascending, dates newest-first). It lives here so the reducer,
    -- the header selectors and the widgets all read one declaration.
    BLUEPRINT_LIBRARY_CHIPS = {
        { value = "all",    label = "All"     },
        { value = "pasted", label = "Pasted"  },
        { value = "mine",   label = "Mine"    },
        -- "Auto saves", not "Backups": the tick box beside these chips says
        -- "Hide automatic saves" and the picker tags the rows AUTO, so the chip
        -- that shows only them says the same thing. (The picker's own group
        -- header still reads "Backups" -- that string is the server's, not ours.)
        { value = "backup", label = "Auto saves" },
    },
    BLUEPRINT_LIBRARY_COLUMNS = {
        { col = "name",    label = "Name",    width = 320, firstDir = "asc"  },
        { col = "source",  label = "Source",  width = 64,  firstDir = "asc"  },
        { col = "type",    label = "Type",    width = 70,  firstDir = "asc"  },
        { col = "date",    label = "Date",    width = 100, firstDir = "desc" },
        -- Note earns the fifth column because it is the only field a player
        -- cannot read without selecting the row one at a time; name, source,
        -- type and date are all legible at a glance.
        { col = "note",    label = "Note",    width = 250, firstDir = "asc"  },
    },
    -- Catalog row schema version. Bump when the observer row shape changes.
    -- No migration needed -- catalog is fully re-fetched from C_HousingCatalog on every sweep.
    CATALOG_SCHEMA_VERSION = 4,   -- 4 (2026-09-13): dropped the never-read categoryIDs / subcategoryIDs / customizations / dyeIDs / variants / dataTags / dataTagsLabel row fields
    -- Atlas for snapshot ("All Placed Decor") cards -- the decorate-mode house glyph.
    SNAPSHOT_ICON_ATLAS = "decor-controls-decoratemode-active",
    -- Atlas for empty shopping-list cards -- the shopping-cart glyph (matches the
    -- Shopping tab header) instead of the red "?" placeholder.
    SHOPPING_LIST_ICON_ATLAS = "Perks-ShoppingCart",

    -- Default scheme name. SchemeConstants registers it; Theme:Initialize
    -- consumes it on first load. Config.scheme overrides at runtime.
    DEFAULT_SCHEME = "ColorblindSafe",

    -- Professions that produce decor recipes. Alphabetical -- order drives chip visual order.
    -- New professions appear in DecorDB -> append here.
    DECOR_PROFESSIONS = {
        "Alchemy",
        "Blacksmithing",
        "Cooking",
        "Enchanting",
        "Engineering",
        "Inscription",
        "Jewelcrafting",
        "Leatherworking",
        "Tailoring",
    },

    -- ========================================================================
    -- Expansion / Profession / Lumber master tables. DATA ONLY -- consumers
    -- build whatever index they need at their own site.
    -- ========================================================================

    -- Expansion master data. Each entry: display name, api tag, short code, color, localized aliases.
    -- IMPORTANT: DO NOT CHANGE the `abbr` values -- they're keys in cross-tab quote tables and savedvars.
    EXPANSION_DATA = {
        { display = "Classic",              api = "Classic",      abbr = "Classic", short = "CLS", color = { 0.6, 0.6, 0.6 },
          aliases = { "Klassisch", "Clasico", "Classique", "Classico", "Clássico", "Классика", "经典", "经典旧世", "經典", "经典版", "經典版", "클래식" } },
        { display = "The Burning Crusade",  api = "Outland",      abbr = "TBC",     short = "TBC", color = { 0.4, 0.7, 0.4 },
          apiTags = { "Burning Crusade", "Scherbenwelt", "Terrallende", "Outreterre", "Terre Esterne", "Terralém", "Запределье", "外域", "燃烧的远征", "燃燒的遠征", "아웃랜드", "불타는 성전" } },
        { display = "Wrath of the Lich King", api = "Northrend",  abbr = "WotLK",   short = "WLK", color = { 0.4, 0.6, 0.8 },
          aliases = { "WotLK", "Nordend", "Rasganorte", "Norfendre", "Nordania", "Nortúndria", "Нордскол", "诺森德", "巫妖王之怒", "北裂境", "노스렌드", "리치 왕의 분노" } },
        { display = "Cataclysm",            api = "Cataclysm",    abbr = "Cata",    short = "CAT", color = { 0.8, 0.5, 0.2 },
          aliases = { "Cataclysme", "Kataklysmus", "Cataclismo", "Cataclisma", "Катаклизм", "大地的裂变", "浩劫與重生", "대격변" } },
        { display = "Mists of Pandaria",    api = "Pandaria",     abbr = "MoP",     short = "MOP", color = { 0.3, 0.7, 0.5 },
          aliases = { "MoP", "Pandarie", "Pandária", "Пандария", "潘达利亚", "熊猫人之谜", "潘達利亞", "潘達利亞之謎", "판다리아", "판다리아의 안개" } },
        { display = "Warlords of Draenor",  api = "Draenor",      abbr = "WoD",     short = "WOD", color = { 0.7, 0.5, 0.3 },
          aliases = { "WoD", "Дренор", "德拉诺", "德拉诺之王", "德拉諾", "德拉諾之霸", "드레노어", "드레노어의 전쟁군주" } },
        { display = "Legion",               api = "Legion",       abbr = "Legion",  short = "LEG", color = { 0.5, 0.9, 0.3 },
          aliases = { "Légion", "Легион", "军团再临", "軍臨天下", "군단" } },
        { display = "Battle for Azeroth",   api = "BfA",          abbr = "BfA",     short = "BFA", color = { 0.8, 0.7, 0.2 },
          -- esES "Kultirano" + ptBR "Kul Tiraz" were the last Latin-European gap (the
          -- BfA faction expansionName; DB2 SharedString 960/963, wago.tools 12.0.7.68453).
          aliases = { "Kul", "Kul Tiran", "Zandalari", "Zandalar", "Kul Tiras", "Kultirano", "Kul Tiraz", "Культирас", "Кул-Тирас", "Кул-тирас", "Зандалари", "Зандалар", "库尔提拉斯", "争霸艾泽拉斯", "庫爾提拉斯", "決戰艾澤拉斯", "赞达拉", "贊達拉", "쿨 티란", "잔달라", "격전의 아제로스" } },
        { display = "Shadowlands",          api = "Shadowlands",  abbr = "SL",      short = "SL",  color = { 0.6, 0.4, 0.8 },
          aliases = { "Schattenlande", "Ombreterre", "Tierras Sombrías", "Terre Ombrose", "Terras Sombrias", "Темные Земли", "暗影国度", "暗影之境", "暗影界", "어둠땅" } },
        { display = "Dragonflight",         api = "Dragon Isles", abbr = "DF",      short = "DF",  color = { 0.2, 0.6, 1.0 },
          aliases = { "Dragon", "Dracheninseln", "Islas del Dragón", "Islas Dragón", "Îles aux Dragons", "Isole dei Draghi", "Ilhas do Dragão", "Драконьи острова", "巨龙群岛", "巨龙时代", "巨龍群島", "巨龍崛起", "용의 섬", "용군단" } },
        { display = "The War Within",       api = "Khaz Algar",   abbr = "TWW",     short = "TWW", color = { 1.0, 0.5, 0.2 },
          aliases = { "Khaz", "Каз'Алгар", "Каз-Алгар", "Каз-алгар", "Каз Алгар", "卡兹阿加", "地心之战", "卡茲阿爾加", "地心之戰", "카즈 알가르", "내부 전쟁" } },
        { display = "Midnight",             api = "Midnight",     abbr = "MN",      short = "MN",  color = { 0.6, 0.2, 0.8 },
          aliases = { "至暗之夜", "한밤" } },
    },

    -- C_HousingCatalog filter-tag groupID -> canonical category. The API's `groupName` is a
    -- LOCALIZED cstring, so matching it against English ("Expansion"/"Size"/...) empties those
    -- filters on every non-enUS client. groupID is the stable DB2 ID (same on all locales).
    -- Verified in-game 2026-06-15. (No "Faction" group in 12.0.5 -- replaced by Culture/Theme.)
    FILTER_TAG_GROUP_BY_ID = {
        [2] = "Size",
        [3] = "Culture",
        [4] = "Expansion",
        [5] = "Style",
        [6] = "Theme",
    },

    -- Profession master data. Each entry: name, TradeSkillLineID, 2-letter code, atlas, shortLabel.
    -- shortLabel trims the longer names for cramped strips (Goblin filter pills).
    -- First 9 are crafting professions; last 3 are gathering. "Mobile-*" atlases have transparent backgrounds.
    -- `aliases`: localized professionName forms (GetBaseProfessionInfo().professionName)
    -- across de/fr/es/it/pt/ru/ko/zh. Byte-compared against the API return (never
    -- displayed), so a non-enUS client's char.professions key (e.g. "Cocina") maps
    -- back to the stable id. Mirrors EXPANSION_DATA.aliases.
    -- source: DB2 SkillLine.DisplayName_lang, wago.tools, build 12.0.7.68453
    PROFESSION_DATA = {
        { name = "Alchemy",       shortLabel = "Alchemy",      id = 171, code = "AL", atlas = "Mobile-Alchemy",
          aliases = { "Alchemie", "Alchimie", "Alquimia", "Alchimia", "Алхимия", "연금술", "炼金术", "鍊金術" } },
        { name = "Blacksmithing", shortLabel = "Blacksmith",   id = 164, code = "BS", atlas = "Mobile-Blacksmithing",
          aliases = { "Schmiedekunst", "Forge", "Herrería", "Forgiatura", "Ferraria", "Кузнечное дело", "대장기술", "锻造", "鍛造" } },
        { name = "Cooking",       shortLabel = "Cooking",      id = 185, code = "CK", atlas = "Mobile-Cooking",
          aliases = { "Kochkunst", "Cuisine", "Cocina", "Cucina", "Culinária", "Кулинария", "요리", "烹饪", "烹飪" } },
        { name = "Enchanting",    shortLabel = "Enchanting",   id = 333, code = "EN", atlas = "Mobile-Enchanting",
          aliases = { "Verzauberkunst", "Enchantement", "Encantamiento", "Incantamento", "Encantamento", "Наложение чар", "마법부여", "附魔" } },
        { name = "Engineering",   shortLabel = "Engineering",  id = 202, code = "EG", atlas = "Mobile-Enginnering",  -- Blizzard typo preserved
          aliases = { "Ingenieurskunst", "Ingénierie", "Ingeniería", "Ingegneria", "Engenharia", "Инженерное дело", "기계공학", "工程学", "工程學" } },
        { name = "Inscription",   shortLabel = "Inscription",  id = 773, code = "IN", atlas = "Mobile-Inscription",
          aliases = { "Inschriftenkunde", "Calligraphie", "Inscripción", "Runografia", "Escrivania", "Начертание", "주문각인", "铭文", "銘文學" } },
        { name = "Jewelcrafting", shortLabel = "Jewelcraft",   id = 755, code = "JC", atlas = "Mobile-Jewelcrafting",
          aliases = { "Juwelierskunst", "Joaillerie", "Joyería", "Oreficeria", "Joalheria", "Ювелирное дело", "보석세공", "珠宝加工", "珠寶設計" } },
        { name = "Leatherworking",shortLabel = "Leatherwork",  id = 165, code = "LW", atlas = "Mobile-Leatherworking",
          aliases = { "Lederverarbeitung", "Travail du cuir", "Peletería", "Conciatura", "Couraria", "Кожевничество", "가죽세공", "制皮", "製皮" } },
        { name = "Tailoring",     shortLabel = "Tailoring",    id = 197, code = "TL", atlas = "Mobile-Tailoring",
          aliases = { "Schneiderei", "Couture", "Sastrería", "Sartoria", "Alfaiataria", "Портняжное дело", "재봉술", "裁缝", "裁縫" } },
        { name = "Herbalism",     shortLabel = "Herbalism",    id = 182, code = "HB", atlas = "Mobile-Herbalism",
          aliases = { "Kräuterkunde", "Herboristerie", "Herboristería", "Erbalismo", "Herborismo", "Травничество", "약초채집", "草药学", "草藥學" } },
        { name = "Mining",        shortLabel = "Mining",       id = 186, code = "MN", atlas = "Mobile-Mining",
          aliases = { "Bergbau", "Minage", "Minería", "Estrazione", "Mineração", "Горное дело", "채광", "采矿", "採礦" } },
        { name = "Skinning",      shortLabel = "Skinning",     id = 393, code = "SK", atlas = "Mobile-Skinning",
          aliases = { "Kürschnerei", "Dépeçage", "Desuello", "Scuoiatura", "Esfolamento", "Снятие шкур", "무두질", "剥皮", "剝皮" } },
    },

    -- Source-type brand colors. Indexed by sourceType integer ID from AllDecorDB entry[2].
    -- Consumed by Palette.source.<typeName> tokens for HouseTab sourceDonut legend swatches.
    SOURCE_TYPE_COLOR = {
        [0]   = { name = "UNKNOWN",     color = { 0.53, 0.53, 0.53 } },
        [1]   = { name = "ACHIEVEMENT", color = { 1.00, 0.82, 0.29 } },
        [2]   = { name = "QUEST",       color = { 0.45, 0.78, 0.95 } },  -- chip-canonical (SOURCE_KINDS QUEST)
        [3]   = { name = "WORLD_QUEST", color = { 0.24, 0.62, 0.90 } },
        [4]   = { name = "DROP",        color = { 0.91, 0.78, 0.36 } },  -- chip-canonical (SOURCE_KINDS DROP)
        [5]   = { name = "VENDOR",      color = { 0.36, 0.70, 0.41 } },
        [6]   = { name = "CRAFTED",     color = { 0.88, 0.39, 0.24 } },
        [7]   = { name = "LEARNED",     color = { 0.55, 0.75, 0.90 } },
        [8]   = { name = "GATHERING",   color = { 0.61, 0.48, 0.29 } },
        [9]   = { name = "TREASURE",    color = { 0.95, 0.86, 0.30 } },  -- chip-canonical (SOURCE_KINDS TREASURE)
        [10]  = { name = "PROMOTION",   color = { 0.78, 0.43, 0.75 } },
        [11]  = { name = "PROFESSION",  color = { 0.36, 0.66, 0.71 } },
        [12]  = { name = "SHOP",        color = { 0.91, 0.43, 0.62 } },
        [13]  = { name = "REP",         color = { 1.00, 0.69, 0.38 } },  -- chip-canonical; also un-hides the rep donut wedge (was source.13 -> nil)
        [14]  = { name = "EVENT",       color = { 0.30, 0.74, 0.80 } },
        [101] = { name = "ENDEAVOR",    color = { 0.30, 0.70, 0.62 } },
        [102] = { name = "GOLD_ONLY",   color = { 0.95, 0.78, 0.35 } },
    },

    -- Midnight initiative event-vendor NPC IDs. One per HouseTab event card widget.
    EVENT_VENDOR_NPCS = {
        ritualSites  = 255495,   -- Rae'ana (Silvermoon, Voidlight Marl)
        abyssAnglers = 260180,   -- Depthdiver Tu'nakit (Zul'Aman, Angler Pearls)
        decorDuels   = 264056,   -- Disguised Decor Duel Vendor (Silvermoon, Illusionary Coins)
    },

    -- Lumber master data. Each entry: itemID, names, expansion, mounted-harvesting achieveID.
    LUMBER_DATA = {
        { id = 245586, name = "Ironwood Lumber",     shortName = "Ironwood",    expansion = "Classic",                achieveID = 62357 },
        { id = 242691, name = "Olemba Lumber",       shortName = "Olemba",      expansion = "The Burning Crusade",    achieveID = 62358 },
        { id = 251762, name = "Coldwind Lumber",     shortName = "Coldwind",    expansion = "Wrath of the Lich King", achieveID = 62359 },
        { id = 251764, name = "Ashwood Lumber",      shortName = "Ashwood",     expansion = "Cataclysm",              achieveID = 62360 },
        { id = 251763, name = "Bamboo Lumber",       shortName = "Bamboo",      expansion = "Mists of Pandaria",      achieveID = 62361 },
        { id = 251766, name = "Shadowmoon Lumber",   shortName = "Shadowmoon",  expansion = "Warlords of Draenor",    achieveID = 62362 },
        { id = 251767, name = "Fel-Touched Lumber",  shortName = "Fel-Touched", expansion = "Legion",                 achieveID = 62363 },
        { id = 251768, name = "Darkpine Lumber",     shortName = "Darkpine",    expansion = "Battle for Azeroth",     achieveID = 62364 },
        { id = 251772, name = "Arden Lumber",        shortName = "Arden",       expansion = "Shadowlands",            achieveID = 62365 },
        { id = 251773, name = "Dragonpine Lumber",   shortName = "Dragonpine",  expansion = "Dragonflight",           achieveID = 62366 },
        { id = 248012, name = "Dornic Fir Lumber",   shortName = "Dornic Fir",  expansion = "The War Within",         achieveID = 62369 },
        { id = 256963, name = "Thalassian Lumber",   shortName = "Thalassian",  expansion = "Midnight",               achieveID = 62370 },
    },

    -- Essence of Lumber (Midnight): a Soulbound rare byproduct of lumber
    -- harvesting, spent to requisition extra crafting materials. Tracked by the
    -- chrome badge + cross-character hover -- NOT a LUMBER_DATA entry (no
    -- expansion variant, no achievement, no recipe-need math). Soulbound means
    -- it can never be Warband-banked or pooled between characters.
    ESSENCE_OF_LUMBER_ITEMID = 269010,
    ESSENCE_OF_LUMBER_ICON   = 132840,

    -- Housing decor currencies. Hand-curated; iconFileIDs captured live.
    -- Expansion string must match a Palette `expansion.<name>` color key.
    HOUSING_DECOR_CURRENCY_DATA = {
        { id =  823, name = "Apexis Crystal",       icon = 1061300, expansion = "Warlords of Draenor" },
        { id =  824, name = "Garrison Resources",   icon = 1005027, expansion = "Warlords of Draenor" },
        { id = 1155, name = "Ancient Mana",         icon = 1377394, expansion = "Legion"              },
        { id = 1220, name = "Order Resources",      icon = 1397630, expansion = "Legion"              },
        { id = 1508, name = "Veiled Argunite",      icon = 1064188, expansion = "Legion"              },
        { id = 1560, name = "War Resources",        icon = 2032600, expansion = "Battle for Azeroth"  },
        { id = 1710, name = "Seafarer's Dubloon",   icon = 1604167, expansion = "Battle for Azeroth"  },
        { id = 1767, name = "Stygia",               icon = 3743739, expansion = "Shadowlands"         },
        { id = 1792, name = "Honor",                icon = 1455894, expansion = "Classic"             },
        { id = 1803, name = "Echoes of Ny'alotha",  icon = 3069889, expansion = "Battle for Azeroth"  },
        { id = 1813, name = "Reservoir Anima",      icon = 3528288, expansion = "Shadowlands"         },
        { id = 2003, name = "Dragon Isles Supplies",icon = 2065578, expansion = "Dragonflight"        },
        { id = 2118, name = "Elemental Overflow",   icon =  134388, expansion = "Dragonflight"        },
        { id = 2657, name = "Mysterious Fragment",  icon = 1362650, expansion = "Dragonflight"        },
        { id = 2803, name = "Undercoin",            icon =  133858, expansion = "Midnight"            },
        { id = 2815, name = "Resonance Crystals",   icon = 2967113, expansion = "Classic"             },
        { id = 3056, name = "Kej",                  icon = 4549280, expansion = "The War Within"      },
        { id = 3316, name = "Voidlight Marl",       icon = 7137586, expansion = "Midnight"            },
        { id = 3363, name = "Community Coupons",    icon =  134495, expansion = "Midnight"            },
        { id = 3373, name = "Angler Pearls",        icon =  348545, expansion = "Midnight"            },
        { id = 3377, name = "Unalloyed Abundance",  icon = 5041790, expansion = "Midnight"            },
        { id = 3379, name = "Brimming Arcana",      icon =  132849, expansion = "Midnight"            },
        { id = 3392, name = "Remnant of Anguish",   icon = 4554435, expansion = "Midnight"            },
        { id = 3393, name = "Illusionary Coin",     icon = 1717106, expansion = "Midnight"            },
        -- From the 12.1.5 catalog's Cost: lines (2026-10-18); name + icon from DB2 CurrencyTypes.
        { id = 3405, name = "Field Accolade",       icon = 2459456, expansion = "Midnight"            },
        { id = 3448, name = "Corrosive Coin",       icon = 8032876, expansion = "Midnight"            },
    },

    -- ===== Menagerie (House > Pets) =====
    -- Namespaced "menagerie" (selectors, session.ui bucket, view) because the shipped
    -- Decor-tab pets mode already owns the pets.* selector names; the two surfaces
    -- converge at plan phase 5. Player-facing label stays "Pets".
    MENAGERIE = {
        -- Height (PetSizeDB units, player = 2.242) -> furniture-language bucket.
        SIZE_BUCKETS = {
            { max = 0.45, key = "shelf", label = "Shelf-sized" },
            { max = 0.95, key = "table", label = "Table-sized" },
            { max = 99,   key = "floor", label = "Floor-sized" },
        },
        -- Per-clade placement meta: what the card's "It needs" line says, and the
        -- motif join key the clade contributes (spec section 5 rules, v1 subset).
        CLADE_META = {
            beast     = { needs = "open floor",             motif = "nature" },
            rodent    = { needs = "a shelf or branch",      motif = "nature" },
            bird      = { needs = "a perch or rafter",      motif = "nature" },
            -- Bats are NOT birds (owner, 2026-08-25). They read as a different
            -- THEME rather than a different animal -- you hang them in a cellar,
            -- not on a garden perch -- so they take the gothic motif and join the
            -- room query alongside undead rather than alongside songbirds.
            bat       = { needs = "a rafter somewhere dim", motif = "gothic" },
            aquatic   = { needs = "water, or a pond edge",  motif = "water" },
            reptile   = { needs = "a warm flat spot",       motif = "nature" },
            insect    = { needs = "a corner to explore",    motif = "nature" },
            -- Arachnids split from insect (owner, 2026-08-26) on the same
            -- reasoning as bat: a different THEME, not merely a different branch.
            -- A spider is cobwebs and a dark corner; a butterfly is a garden. They
            -- shared "a corner to explore" and the nature motif, which sent
            -- tarantulas to answer a flowerbed.
            arachnid  = { needs = "a beam, or a quiet corner", motif = "gothic" },
            construct = { needs = "a workbench or plinth",  motif = "mechanical" },
            elemental = { needs = "space -- it hovers",     motif = "arcane" },
            undead    = { needs = "somewhere dim",          motif = "gothic" },
            demon     = { needs = "somewhere dim",          motif = "fel" },
            void      = { needs = "somewhere dim",          motif = "void" },
            humanoid  = { needs = "open floor",             motif = "cultural" },
            plant     = { needs = "a planter or garden",    motif = "nature" },
            oddity    = { needs = "wherever it is funniest", motif = "novelty" },
        },
        -- Battle family (petType index) -> extra motif, where the family genuinely
        -- adds one beyond the clade (the Mechanical Squirrel two-facts case).
        FAMILY_MOTIF = { [9] = "mechanical", [8] = "arcane", [6] = "gothic", [2] = "reptilian" },
        -- Identity axes for the By Pet two-row filter (ruling 14).
        -- Kind is NOT an axis. There are 712 kinds -- 239 of them with a single
        -- pet, 71% with four or fewer -- so as a flat chip row it could only ever
        -- show a top-N: the shipped twelve reached 14% of species and left
        -- "squirrel" (12 pets, 40th) unreachable with nothing on screen saying so.
        -- Kind is the SECOND LEVEL of clade instead: pick Rodent, and row two
        -- becomes rat / rabbit / squirrel / porcupine. Every kind is reachable,
        -- and no row ever has to be truncated.
        AXES = { { value = "clade", label = "Clade" },
                 { value = "family", label = "Family" }, { value = "size", label = "Size" },
                 { value = "room", label = "Room" },
                 { value = "mood", label = "Mood" } },

        -- ===== the Room axis ================================================
        -- Pick a room, get the pets that suit it. This is the second attempt at
        -- "room": the first read the room's PLACED DECOR and was removed on
        -- 2026-08-27 because the game only enumerates decor per AREA, and indoors
        -- is one area -- see docs/HDGR_BY_ROOM_SPEC_2026-08-25.md section 7. The
        -- data problem is gone here: nothing is read from the world at all.
        --
        -- Keyed by KIND, not clade, because clades cannot make a shortlist. The
        -- clade table this replaces put 775 species in a kitchen (rodent + bird +
        -- insect) and 1,298 in a garden. Kinds are the fine instrument: 712 of
        -- them, 509 with four species or fewer, and roughly a dozen per room
        -- lands on the ~100 that was asked for.
        --
        -- The weight is the RANKING, and it is a person's judgement rather than a
        -- computed score: 3 = belongs here, 2 = fits, 1 = could work. The removed
        -- version summed five weak signals and produced an order nobody could
        -- argue with; a number someone chose can be disagreed with by name.
        --
        -- Order is a walk through a house, not the alphabet. Every kind here is
        -- checked against the live taxonomy by test_menagerie_selectors -- a typo
        -- is a pet that silently never appears.
        ROOMS = {
            { key = "greathall", label = "Great Hall", kinds = {
                tiger = 3, frostsabre = 3, bear = 2, gryphon = 2, peacock = 2,
                eagle = 2, dragonhawk = 2, boar = 1, deer = 1, raptor = 1,
                gorilla = 1, anubisath = 1, frostwolfpup = 1, phoenix = 1 } },
            { key = "lounge", label = "Lounge", kinds = {
                cat = 3, redpanda = 3, fox = 2, mistfox = 2, capybara = 2,
                otter = 2, peacock = 1, parrot = 1, raccoon = 1, rabbit = 1,
                toucan = 1 } },
            { key = "kitchen", label = "Kitchen", kinds = {
                rat = 3, cockroach = 3, chicken = 3, cat = 2, duck = 2,
                squirrel = 2, pig = 2, goat = 1, crab = 1 } },
            -- The owner's favourite, and the one room here that is a PLACE
            -- rather than a function: the small companionable animals that would
            -- sit on a counter or take the other chair. Deliberately not the
            -- Lounge's list -- no rabbits, and the birds are the talkative ones.
            { key = "coffeeshop", label = "Coffee Shop", kinds = {
                cat = 3, redpanda = 3, raccoon = 2, capybara = 2, squirrel = 2,
                parrot = 2, owl = 1, otter = 1, mistfox = 1, toucan = 1,
                prairiedog = 1, duck = 1 } },
            { key = "tavern", label = "Tavern", kinds = {
                murloc = 3, pig = 2, boar = 2, chicken = 2, rat = 2, cat = 1,
                duck = 1, koboldmale = 1, ogrepet = 1 } },
            { key = "bedroom", label = "Bedroom", kinds = {
                cat = 3, rabbit = 3, fox = 2, otter = 2, redpanda = 2,
                capybara = 2, mistfox = 1, squirrel = 1, owl = 1, raccoon = 1 } },
            { key = "nursery", label = "Nursery", kinds = {
                rabbit = 3, babyturtle = 3, babyhippo = 2, dreamfawn = 2,
                babyhyena = 2, prairiedog = 2, capybara = 1, porcupine = 1,
                beaver = 1, chicken = 1 } },
            { key = "study", label = "Study", kinds = {
                owl = 3, manafiend = 3, flyingbook = 3, manawurm = 2,
                manawyrm = 2, faeriedragon = 2, wisp = 2, cat = 1, lanternpet = 1,
                babyobserver = 1, inquisitoreye = 1, spider = 1 } },
            { key = "library", label = "Library", kinds = {
                owl = 3, flyingbook = 3, cat = 2, spider = 2, manafiend = 2,
                babyobserver = 2, lanternpet = 1, wisp = 1, moth = 1,
                faeriedragon = 1 } },
            { key = "bath", label = "Bath", kinds = {
                frog = 3, toad = 3, otter = 3, babyturtle = 2, goldfish = 2,
                waterstrider = 2, seaslug = 1, babyoctopus = 1, jellyfish = 1,
                snail = 1 } },
            { key = "cellar", label = "Cellar", kinds = {
                bat = 3, giantvampirebat = 3, spider = 3, cockroach = 2, rat = 2,
                bonespider = 1, scorpion = 1, snailrock = 1, shalespider = 1,
                cryptfiend = 1 } },
            -- The Cellar is the damp under your house; the Dungeon is a
            -- deliberate horror set-piece. Crypt fiend and bone spider are in
            -- both on purpose -- kinds belong to as many rooms as suit them,
            -- the way a cat is in the Kitchen, Bedroom, Tavern and Study.
            { key = "dungeon", label = "Dungeon", kinds = {
                abominationsmall = 3, ghoul = 3, gnomeskeleton = 3, cryptfiend = 2,
                skeletonhandpet = 2, skeletonspinepet = 2, boneguard = 2,
                fleshbeast = 2, fleshgolem = 2, minespider = 2,
                nerubianspiderling = 2, bonespider = 1, tarantula = 1, imp = 1,
                felstalker = 1, grell = 1, greaterslime = 1, maldraxxusslime = 1,
                shahaunt = 1, walker = 1, valkierpet = 1, ghostlyskullpet = 1 } },
            { key = "workshop", label = "Workshop", kinds = {
                gnomespidertank = 3, mechagonpet = 3, sapper = 3, golem = 2,
                mechanicalhandpet = 2, fuelrobot = 2, clockworkbeagle = 2,
                robotpet = 2, tripod = 1, balloon = 1, geode = 1, lanternpet = 1,
                golemdwarven = 1, toygorilla = 1, arakkoagolem = 1, encrypted = 1,
                earthelemental = 1, flyingbook = 1 } },
            { key = "laboratory", label = "Laboratory", kinds = {
                manafiend = 3, greaterslime = 3, maldraxxusslime = 2, slime = 2,
                tentacleslime = 2, geode = 2, mechagonpet = 2, babyobserver = 1,
                inquisitoreye = 1, encrypted = 1, sapper = 1, larva = 1 } },
            { key = "armory", label = "Armory", kinds = {
                anubisath = 3, golemdwarven = 3, gnomespidertank = 2, golem = 2,
                boneguard = 2, arakkoagolem = 2, skeletonhandpet = 1, gargoyle = 1,
                tripod = 1, mechagonpet = 1, frostwolfpup = 1, raptor = 1,
                tiger = 1, warpstalker = 1, felstalker = 1 } },
            { key = "garden", label = "Garden", kinds = {
                moth = 3, butterfly = 3, dragonfly = 3, lasherorchid = 2,
                podling = 2, turnippet = 2, rabbit = 2, cricket = 1,
                beecreature = 1, sporecreature = 1, snail = 1 } },
            { key = "greenhouse", label = "Greenhouse", kinds = {
                lasherorchid = 3, podling = 3, turnippet = 3, sporecreature = 2,
                moth = 2, butterfly = 2, dragonfly = 2, fungallasher = 2,
                sporeling = 1, snail = 1, cricket = 1, beecreature = 1,
                silkworm = 1 } },
            { key = "pond", label = "Pond", kinds = {
                hermitcrab = 3, deepseacrab = 3, seaeel = 2, spidercrab = 2,
                dragonturtle = 2, goldfish = 2, babyoctopus = 1, jellyfish = 1,
                seaslug = 1, otter = 1, frog = 1, babyturtle = 1 } },
            { key = "aviary", label = "Aviary", kinds = {
                parrot = 3, toucan = 3, owl = 2, peacock = 2, eagle = 2,
                carrionbird = 2, crane = 1, duck = 1, seagull = 1,
                woodpecker = 1, dragonhawk = 1, phoenix = 1 } },
            { key = "stable", label = "Stable", kinds = {
                protoram = 3, protosheep = 3, babyhorse = 3, goat = 2, boar = 2,
                pig = 2, deer = 2, frostwolfpup = 2, ram = 2, sheep = 2,
                ridinghorse = 2, mammoth2pet = 1, dreamfawn = 1, arathilynx = 1,
                raptor = 1 } },
            { key = "shrine", label = "Shrine", kinds = {
                wisp = 3, ghost = 3, elemental = 2, waterspiritsmall = 2,
                firespiritsmall = 2, forestsprite = 2, manafiend = 2,
                airelemental = 2, gargoyle = 1, crane = 1, babylich = 1,
                waterelemental = 1, wraith = 1, shade = 1, wellofsouls = 1 } },
            { key = "trophy", label = "Trophy Room", kinds = {
                raptor = 3, triceratops = 3, dragonwhelp = 2, komododragon = 2,
                crocodile = 2, mammoth2pet = 2, bear = 1, tiger = 1,
                warpstalker = 1, hydra = 1 } },
        },

        -- ===== the Mood axis ================================================
        -- The same instrument pointed at style instead of function, and the same
        -- vocabulary the Styles tab browses decor with (HDGR_FacetVocab.mood,
        -- via styles.smartset). Build a gothic room over there, come here and
        -- ask for gothic pets.
        --
        -- TWELVE of Blizzard's sixteen moods. Omitted: military, holy, festive
        -- and mysterious -- there is no honest dozen pets for any of them, and a
        -- chip that opens on four rows is worse than a chip that is not there.
        -- (`mysterious` would also just be gothic and void again.)
        --
        -- Deriving these from the clade motif pets already carry was the obvious
        -- shortcut and is the wrong answer for the same reason clades were: nine
        -- motifs over 1,935 pets means "gothic" is the entire undead clade.
        MOODS = {
            { key = "rustic", label = "Rustic", kinds = {
                chicken = 3, pig = 3, goat = 3, duck = 2, boar = 2, squirrel = 2,
                rabbit = 2, deer = 1, prairiedog = 1, beaver = 1, porcupine = 1,
                skunk = 1, protosheep = 1 } },
            { key = "cozy", label = "Cozy", kinds = {
                cat = 3, rabbit = 3, redpanda = 3, capybara = 2, otter = 2,
                mistfox = 2, raccoon = 1, babyturtle = 1, porcupine = 1,
                dreamfawn = 1, squirrel = 1 } },
            { key = "nature", label = "Nature", kinds = {
                moth = 3, butterfly = 3, dragonfly = 3, lasherorchid = 2,
                podling = 2, turnippet = 2, sporecreature = 2, cricket = 1,
                beecreature = 1, snail = 1, fox = 1, deer = 1 } },
            { key = "arcane", label = "Arcane", kinds = {
                manafiend = 3, manawurm = 3, manawyrm = 3, faeriedragon = 2,
                wisp = 2, geode = 2, babyobserver = 1, inquisitoreye = 1,
                flyingbook = 1, lanternpet = 1, elemental = 1 } },
            { key = "scholarly", label = "Scholarly", kinds = {
                owl = 3, flyingbook = 3, babyobserver = 2, manafiend = 2,
                spider = 2, cat = 1, inquisitoreye = 1, lanternpet = 1, moth = 1,
                wisp = 1 } },
            { key = "gothic", label = "Gothic", kinds = {
                bat = 3, giantvampirebat = 3, spider = 3, ghost = 2, gargoyle = 2,
                cryptfiend = 2, bonespider = 2, gnomeskeleton = 1, wraith = 1,
                shade = 1, ghostlyskullpet = 1, valkierpet = 1, scorpion = 1,
                minespider = 1, nerubianspiderling = 1, fleshgolem = 1 } },
            { key = "void", label = "Void", kinds = {
                beholder = 3, beholdereye = 3, eyeofnzothpet = 3, voidcreeper = 3,
                mercilessone = 2, babytentacleface = 2, voidterror = 2,
                voidcaller = 2, devourersmall = 1, devourerswarmer = 1,
                yoggsaron = 1, corruptedtentacle = 1 } },
            { key = "royal", label = "Royal", kinds = {
                peacock = 3, gryphon = 3, phoenix = 3, dragonhawk = 2, tiger = 2,
                frostsabre = 2, crane = 1, babyhawkstrider = 1, eagle = 1,
                anubisath = 1, faeriedragon = 1, toucan = 1 } },
            { key = "industrial", label = "Industrial", kinds = {
                gnomespidertank = 3, mechagonpet = 3, sapper = 2, fuelrobot = 2,
                robotpet = 2, tripod = 2, mechanicalhandpet = 2, golemdwarven = 1,
                clockworkbeagle = 1, encrypted = 1, geode = 1, golem = 1,
                earthelemental = 1, arakkoagolem = 1, progenitoraxolotl = 1 } },
            { key = "seafaring", label = "Seafaring", kinds = {
                murloc = 3, hermitcrab = 3, crab = 3, deepseacrab = 2, seaeel = 2,
                babyoctopus = 2, jellyfish = 1, seagull = 1, parrot = 1,
                spidercrab = 1, seaslug = 1, goldfish = 1 } },
            { key = "whimsical", label = "Whimsical", kinds = {
                toygorilla = 3, balloon = 3, elekkplushie = 3, gnometoypet = 2,
                clockworkbeagle = 2, dragonkite = 2, redpanda = 2, voodoodoll = 1,
                tuskarkite = 1, babyhippo = 1, duck = 1, capybara = 1 } },
            { key = "primitive", label = "Primitive", kinds = {
                triceratops = 3, raptor = 3, komododragon = 2, goren = 2,
                lessergronn = 2, boar = 2, wendigo = 1, ogrepet = 1,
                koboldmale = 1, gnollmelee = 1, warpstalker = 1, babydevilsaur = 1,
                hydra = 1, protoram = 1, mammoth2pet = 1, gorilla = 1 } },
        },

        -- Weight -> the words on the row. Three tiers, because a curated 1-3 is
        -- as fine as a judgement call honestly goes.
        ROOM_FIT = { "MENAGERIE_FIT_COULD", "MENAGERIE_FIT_FITS", "MENAGERIE_FIT_BELONGS" },
        -- "Also knows" whitelist: anim id -> player verb. Only ids a PLAYER would
        -- click for fun belong here -- combat/movement ids are repertoire noise
        -- (Pandaren Monk carries ~40; unfiltered chips overflowed the window).
        -- Ids from the Emotes.db2-adjudicated ANIM_NAMES set.
        -- The scene strip's curated decor (ruled 2026-08-25): one bed, one
        -- plinth. All 10 attachables stay in SceneDecorDB; these are the chips.
        SCENE_CHIP_DECOR = { 12246, 25122 },   -- Paw Pal Bed, Loyal Companion's Plinth
        -- Where a pet actually SITS on each scene decor, in world units.
        --
        -- The stage falls back to the decor's bounding-box top, which is only the
        -- seat when the silhouette is flat. The Paw Pal Bed's box top is the crown
        -- of its backrest (box 0.661 vs the plinth's 0.378 -- 1.75x taller than a
        -- squat pedestal, all of it backrest), so bbox-seating floats the pet above
        -- the cushion and the camera then clips it at the top edge.
        --
        -- A bounding box cannot tell us where the cushion is, so these are EYEBALLED
        -- per decor with `/hdg petseat <z>` and written down here. An entry absent
        -- from this table keeps the bbox-top fallback.
        -- Where a pet's FEET go on each scene decor, in scene units. The box top
        -- IS right for flat-topped decor -- the plinth's mesh ends at 0.378
        -- exactly, read from its M2 -- so the plinth has no entry. The bed's box
        -- top is the crown of its backrest (0.661); its mattress is the large
        -- flat vertex sheet at 0.32-0.34 in the same mesh, and 0.34 is that
        -- sheet, not an eyeball. (A 1.2 once sat here for the plinth: it was
        -- 0.378 / 0.3001, the seat pre-divided by the one pet it was calibrated
        -- with -- the stage now divides by the pet's scale itself; see
        -- _seatAndFrame.)
        SCENE_SEAT_Z = {
            [12246] = 0.34,   -- Paw Pal Bed: the mattress sheet, below the backrest crown
        },
        SHOWABLE_ANIMS = {
            [4] = "walks", [5] = "runs", [38] = "jumps", [42] = "swims",
            [60] = "talks", [61] = "eats", [66] = "bows", [67] = "waves",
            [68] = "cheers", [69] = "dances", [70] = "laughs", [71] = "sleeps",
            [74] = "roars", [78] = "chicken dance", [80] = "applauds",
            [82] = "flexes", [96] = "sits down", [100] = "sleeps",
        },
    },

    -- Top-row filter chip values. SSoT for Selectors, LayoutConfig, Controller_Decor, and the reducer.
    -- Adding or removing a bucket is one edit here.
    TOP_FILTERS = {
        { value = "all",        label = "All"        },
        { value = "crafted",    label = "Crafted"    },
        { value = "sizes",      label = "Size |A:house-decor-budget-icon:12:12|a" },
        { value = "styles",     label = "Styles"     },
        { value = "expansions", label = "Expansions" },
        { value = "other",      label = "Other"      },
        { value = "sources",    label = "Sources"    },
        -- Pets is a MODE, not a narrowing filter: it swaps the browser list from
        -- decor to the player's decor-attachable pets. One row here generates the
        -- chip widget (LayoutConfig_Decor's loop) and decor.topFilter.active_pets
        -- (Selectors_Decor's loop), so there is nothing else to wire.
        { value = "pets",       label = "Pets"       },
    },

    -- Crafting history ring-buffer cap. ~110KB worst case in SV.
    CRAFT_HISTORY_CAP = 500,

    -- Lumber farming history ring-buffer cap. Capped lower than craft history (sessions are richer records).
    LUMBER_HISTORY_CAP = 200,

    -- Decor achievement milestone IDs (Items Acquired achievements).
    DECOR_ACHIEVEMENTS = {
        { id = 61308, threshold = 1   },
        { id = 61309, threshold = 5   },
        { id = 61310, threshold = 25  },
        { id = 61311, threshold = 50  },
        { id = 61312, threshold = 100 },
        { id = 61313, threshold = 150 },
        { id = 61314, threshold = 200 },
        { id = 61315, threshold = 250 },
        { id = 61316, threshold = 300 },
        { id = 61317, threshold = 400 },
        { id = 61318, threshold = 500 },
    },

    -- Community Coupon achievement milestone IDs.
    COUPON_ACHIEVEMENTS = {
        { id = 62371, threshold = 50    }, -- Couponing for Beginners
        { id = 62373, threshold = 250   }, -- Coupon Collector
        { id = 62374, threshold = 500   }, -- You Get The Best Deals Anywhere
        { id = 62375, threshold = 1000  }, -- Buying in Bulk
        { id = 62376, threshold = 2000  }, -- Extreme Couponing
        { id = 62377, threshold = 5000  }, -- A Fist Full of Coupons
        { id = 62378, threshold = 10000 }, -- A Few Coupons More
    },

    -- Recipe knowledge state -- 4-state enum returned by decor.craftableState.
    -- String values are the wire-format; codebase preference is the constant form.
    RECIPE_STATE = {
        KnownByCharacter = "known_self",
        KnownByAlt       = "known_alt",
        UnknownOnAccount = "recipe_exists",
        NotARecipe       = "not_a_recipe",
    },

    -- Closed taxonomy of text-color states. SSoT for collection, recipe-knowledge, and severity states.
    -- Keys match RECIPE_STATE so the same value flows into Theme lookup.
    -- Theme:GetTextStateColor / :GetTextStateColorToken consume these.

    -- Atlas per recipe-state for the craft star. Shape AND color both carry the state (colorblind-safe).
    -- All three atlases are line-art over transparent -- SetVertexColor paints cleanly.
    RECIPE_STATE_STAR_ATLAS = {
        known_self    = "tradeskills-star",
        known_alt     = "tradeskills-star-off",
        recipe_exists = "auctionhouse-icon-favorite-off",
    },

    -- Acquire-tab preset chips. SSoT for Selectors, LayoutConfig, Controller, and the reducer.
    -- Single-select source axis; missingOnly is an orthogonal toggle that ANDs with any preset.
    -- Row 1 is HOW you earn it; row 2 is WHAT YOU CAN JUST GO AND BUY. The two
    -- rows are deliberately different questions -- the second exists because a
    -- new player asking "what can I decorate with today" got no useful answer
    -- from a list of achievement and reputation rewards (ReganB, 2026-08-14).
    -- `row = 2` is read by the LayoutConfig chip generator; see acq.presetStrip2.
    ACQ_PRESETS = {
        { value = "achievement",  label = "Achieve"          },
        { value = "reputation",   label = "Rep"              },
        { value = "endeavor",     label = "Endeavor"         },
        { value = "quest",        label = "Quest"            },
        { value = "recipes",      label = "Recipes"          },  -- vendor-level: sells >=1 recipe
        { value = "neighborhood", label = "Neighborhood",     row = 2 },
        { value = "ungated",      label = "Gold, no unlocks", row = 2 },
    },

    -- ACQ_SOURCES (Advanced Filters > Source dropdown) is DERIVED from SOURCE_KINDS.
    -- See "Acquisition source-filter options" near the bottom of this file.

    -- Views that show the catalog refresh badge and trigger a re-sweep on visit.
    -- NOTE: the INITIAL catalog load is not gated by this set -- it runs on the
    -- first main-window open. View-gating the load left session.catalog.status "idle"
    -- on non-set views until the user happened to visit decor/house.
    -- Keys must match the `view` strings in TABS below.
    CATALOG_CONSUMING_TAB_VIEWS = {
        decor        = true,
        acquisition  = true,
        shoppingList = true,
        zoneScanner  = true,
        houseTab     = true,
        -- Blueprints reads catalog rows for its joins, source chips, cost badge,
        -- dye rows and Route to Shopping. Off this list, a refresh queued while it
        -- showed waited for a switch to another tab, so a build made before the
        -- game's storage data loaded (window open across a /reload) stayed on
        -- screen with pieces reading unowned and undyeable (Vamoose, live 12.1,
        -- 2026-09-19: refreshPending stuck true on Blueprints).
        projectsBlueprints = true,
        -- Audit 2026-09-19: every other tab bound to a selector that reads decor
        -- ownership (quantity / numPlaced / isOwned / ownedDecorIDs, directly or
        -- through `calls`). Each held a pending refresh the same way Blueprints
        -- did. Tabs left off read no ownership (Pets, Trainers, Alts, Architect,
        -- Layouts, Landing, Move Planner, Data, Debug, Config); the floating
        -- lumber window is not a tab and is not covered by this gate.
        styles         = true,
        recipes        = true,
        warehouse      = true,
        mogul          = true,
        projectsPicker = true,
    },

    -- Views that consume house level/favor/reward data (House tab + Projects/Architect
    -- placement caps). HousingObserver only touches the SHARED C_Housing level/favor
    -- async channel (GetCurrentHouseLevelFavor / GetHouseLevelRewardsForLevel) while one
    -- of these is the active view AND the window is shown -- otherwise HDG's fetches
    -- boomerang into Blizzard's housing dashboard, whose reward track re-inits on every
    -- RECEIVED_HOUSE_LEVEL_REWARDS and blanks the level nodes to "0". See HDGR_HousingObserver.
    HOUSE_LEVEL_VIEWS = {
        houseTab          = true,
        projectsLanding   = true,
        projectsArchitect = true,
        projectsLayouts   = true,
    },

    -- Top-level tabs. Each entry maps to a `view` in LayoutConfig.window.views.
    -- Chrome strip generates one button per entry. Adding a tab = one line here + a matching window.views block.
    TABS = {
        { view = "decor",        label = "Decor" },
        { view = "acquisition",  label = "Acquire" },
        { view = "shoppingList", label = "Shopping" },
        { view = "zoneScanner",  label = "Zone" },
        { view = "recipes",      label = "Recipes" },
        { view = "warehouse",    label = "Warehouse" },
        { view = "trainers",     label = "Trainers" },
        { view = "alts",         label = "Alts" },
        { view = "mogul",        label = "Mogul" },
        { view = "styles",       label = "Styles" },
        { view = "houseTab",     label = "House" },
        { view = "projectsLanding",   label = "Projects" },
        { view = "projectsArchitect", label = "Architect" },
        { view = "projectsLayouts",   label = "Layouts" },
        { view = "removalist",        label = "Move Planner" },
        { view = "projectsBlueprints", label = "Blueprints" },
        { view = "menagerie",     label = "Pets" },
        { view = "projectsPicker",    label = "Add Decor" },       -- opened via "+ Add decor"; not in NAV_TREE
        { view = "data",         label = "Your Data" },
        { view = "debug",        label = "Debug" },
        { view = "config",       label = "Config" },
    },

    -- Sidebar nav tree (flat, always-expanded). Generated by LayoutConfig_Nav + wired by Controller_Nav.
    -- Node kinds: home | parent | header | launcher | config | divider.
    -- Child leaf kinds: mode-leaf (dispatches an action, activePath drives highlight) | view-leaf (plain view switch).
    NAV_TREE = {
        -- Blueprints is sub-nav UNDER House, the headline housing feature.
        -- test_nav_tree cross-checks every nav view against TABS, so this child
        -- and the TABS entry above travel together.
        { kind = "home",   view = "houseTab", label = "House", icon = "housing-map-plot-player-house", children = {
            { label = "Blueprints", view = "projectsBlueprints" },
            -- The Menagerie (spec ruling 4): the established slot for a headline
            -- housing feature that does not spend a top-level nav entry.
            { label = "Pets",       view = "menagerie" },
        }},
        { kind = "divider" },
        { kind = "parent", view = "decor",    label = "Decor", icon = "house-decor-budget-icon" },
        { kind = "parent", view = "acquisition", label = "Acquire", icon = "housing-decor-vendor_32", children = {
            { label = "Shop by Vendor", transient = { view = "acquisition", key = "viewMode", value = "vendor" }, activePath = "session.ui.acquisition.viewMode", activeValue = "vendor" },
            { label = "Find Decor",     transient = { view = "acquisition", key = "viewMode", value = "item"   }, activePath = "session.ui.acquisition.viewMode", activeValue = "item"   },
        }},
        { kind = "parent", view = "recipes", label = "Crafting", icon = "Professions-Crafting-Orders-Icon", children = {
            { label = "Recipes",   view = "recipes" },
            { label = "Warehouse", view = "warehouse" },
            { label = "Trainers",  view = "trainers" },
            { label = "Alts",      view = "alts" },
        }},
        { kind = "parent", view = "mogul", label = "Mogul", icon = "housing-map-deed", children = {
            { label = "Goblin",    action = "MOGUL_SET_SUBVIEW", payload = { subView = "goblin" }, activePath = "session.ui.mogul.subView", activeValue = "goblin" },
            { label = "Optimizer", action = "MOGUL_SET_SUBVIEW", payload = { subView = "mogul"  }, activePath = "session.ui.mogul.subView", activeValue = "mogul"  },
        }},
        { kind = "parent", view = "styles",   label = "Styles", icon = "catalog-palette-icon", children = {
            { label = "Browse",        action = "STYLES_SET_VIEW", payload = { view = "landing"  }, activePath = "session.ui.styles.view", activeValue = "landing"  },
            { label = "Style Curator", action = "STYLES_SET_VIEW", payload = { view = "curator"  }, activePath = "session.ui.styles.view", activeValue = "curator"  },
            { label = "Smart Sets",    action = "STYLES_SET_VIEW", payload = { view = "smartset" }, activePath = "session.ui.styles.view", activeValue = "smartset" },
        }},
        { kind = "parent", view = "projectsLanding", label = "Projects",
          icon = "decor-ability-layoutmode-default", iconActive = "decor-ability-layoutmode-active",
          iconPressed = "decor-ability-layoutmode-pressed", children = {
            { label = "Architect", view = "projectsArchitect" },
            { label = "Layouts",   view = "projectsLayouts" },
            { label = "Move Planner", view = "removalist" },
        }},
        { kind = "divider" },
        -- Tools: a collapsible group (like the hubs above) but with NO navigable
        -- view -- collapseKey "tools" backs its collapse state; noNavigate -> the
        -- row has no view, so clicking anywhere on it folds the group (the chevron
        -- does the same on every group row). Children are launcher (dispatch-only)
        -- + config view-switches + the debug-gated row.
        { kind = "parent", collapseKey = "tools", noNavigate = true, label = "Tools",
          icon = "decor-controls-inspect-default", iconActive = "decor-controls-inspect-active",
          iconPressed = "decor-controls-inspect-pressed", children = {
            { label = "Shopping",  launcher = "SHOPPING_WIDGET_TOGGLE" },
            { label = "Zone",      launcher = "ZONE_POPUP_TOGGLE" },
            -- Import: launcher (no hubView under noNavigate Tools) -- the action sets
            -- BOTH the Styles tab and the import sub-view, so one dispatch lands the user there.
            { label = "Import",    launcher = "STYLES_OPEN_IMPORT" },
            { label = "Export",    launcher = "STYLES_OPEN_EXPORT" },
            { label = "Config",    view = "config" },
            { label = "Your Data", view = "data" },
            -- Debug leaf: shown only in debug mode (gatedBy selector -> omitted when false).
            { label = "Debug",     view = "debug", gatedBy = "config.debug" },
        }},
    },

    -- ===== Action types =====
    -- Every dispatched action's `type` must be a value from this table (typos error at load).
    -- Config scope enum (HDG.Config layer). Reducer routes CONFIG_SET to the right SV slot.
    ConfigScope = {
        Profile   = "profile",      -- per-active-profile (default for most settings)
        Character = "character",    -- per-character (keyed by UnitGUID at write time)
        Account   = "account",      -- cross-profile, account-wide (migration flags etc.)
    },

    ACTIONS = {
        CONFIG_SET          = "HDGR_CONFIG_SET",
        CONFIG_SCALE_STEP   = "HDGR_CONFIG_SCALE_STEP",   -- payload: { direction = "inc"|"dec" }
        -- PROFILE_SWITCH triggers a wildcard invalidate (re-keys every Config:Get value).
        PROFILE_CREATE      = "HDGR_PROFILE_CREATE",
        PROFILE_SWITCH      = "HDGR_PROFILE_SWITCH",
        PROFILE_DELETE      = "HDGR_PROFILE_DELETE",
        HARD_RESET          = "HDGR_HARD_RESET",
        COLLECTION_RESET    = "HDGR_COLLECTION_RESET",    -- wipes ownedDecorIDs; triggers fresh sweep
        UI_SET_PERSISTENT   = "HDGR_UI_SET_PERSISTENT",   -- writes account.ui[key]
        UI_SET_TRANSIENT    = "HDGR_UI_SET_TRANSIENT",    -- writes session.ui[key] (or session.ui[view][key] if payload.view)
        REMOVALIST_PICK_PLOT = "HDGR_REMOVALIST_PICK_PLOT", -- Removalist 2-click cycle: source -> target -> restart
        REMOVALIST_SWAP     = "HDGR_REMOVALIST_SWAP",     -- swap source <-> target
        REMOVALIST_CLEAR    = "HDGR_REMOVALIST_CLEAR",    -- clear both picks
        REMOVALIST_SET_LETTER_FILTER = "HDGR_REMOVALIST_SET_LETTER_FILTER", -- filter plot list by A/B/C/D (nil = all)
        REMOVALIST_SET_PLOT = "HDGR_REMOVALIST_SET_PLOT", -- map-click: payload.role "source"/"target" sets that pick
        -- Atomic per-tab filter reset (per ADR-018). payload.tab discriminates which tab.
        UI_FILTER_RESET     = "HDGR_UI_FILTER_RESET",     -- payload: { tab = "decor"|"acquisition"|"recipes" }
        MAIN_WINDOW_TOGGLE  = "HDGR_MAIN_WINDOW_TOGGLE",  -- flips account.ui.mainWindowShown
        NAV_TOGGLE_GROUP    = "HDGR_NAV_TOGGLE_GROUP",     -- payload: { view }; flips account.ui.nav.collapsedGroups[view]
        SESSION_END         = "HDGR_SESSION_END",          -- PLAYER_LOGOUT; reducer closes window
        -- Pet journal collection/list changed. Bumps session.resolvers.pets.tick;
        -- PetObserver's module index is the data, this is only the re-pull signal.
        PETS_LIST_CHANGED   = "HDGR_PETS_LIST_CHANGED",
        -- COMPANION_UPDATE: what is out has changed. Separate from the LIST
        -- action because the collection has not changed, only the summon state.
        PETS_SUMMONED_CHANGED = "HDGR_PETS_SUMMONED_CHANGED",

        -- Combat lifecycle (driven by CombatMiddleware via PLAYER_REGEN_*).
        COMBAT_ENTER        = "HDGR_COMBAT_ENTER",
        COMBAT_EXIT         = "HDGR_COMBAT_EXIT",
        -- Reducer-mediated queuing (not direct middleware mutation). COMBAT_EXIT
        -- drains the queue after snapshotting it.
        COMBAT_QUEUE_ACTION = "HDGR_COMBAT_QUEUE_ACTION",

        -- Vendor-view items area view mode. payload: { mode = "grid"|"list" }.
        ACQ_SET_ITEMS_VIEW_MODE = "HDGR_ACQ_SET_ITEMS_VIEW_MODE",

        -- Source-preset chip strip. Single-select; dispatching the active preset deselects.
        ACQ_SET_PRESET              = "HDGR_ACQ_SET_PRESET",
        ACQ_TOGGLE_ADVANCED_FILTERS = "HDGR_ACQ_TOGGLE_ADVANCED_FILTERS",
        -- Missing toggle is orthogonal to ACQ_SET_PRESET (ANDs with active source).
        ACQ_TOGGLE_MISSING          = "HDGR_ACQ_TOGGLE_MISSING",
        -- Advanced-filter multi-select toggles. payload: { <axis> = value }; value=="all"
        -- clears the axis set (empty set = "All"). Clone of RECIPES_TOGGLE_EXPANSION.
        ACQ_TOGGLE_EXPANSION        = "HDGR_ACQ_TOGGLE_EXPANSION",   -- payload: { expansion }
        ACQ_TOGGLE_ZONE             = "HDGR_ACQ_TOGGLE_ZONE",        -- payload: { zone }
        ACQ_TOGGLE_REP              = "HDGR_ACQ_TOGGLE_REP",         -- payload: { rep }
        ACQ_TOGGLE_SOURCE           = "HDGR_ACQ_TOGGLE_SOURCE",      -- payload: { source }
        ACQ_TOGGLE_FACTION          = "HDGR_ACQ_TOGGLE_FACTION",     -- payload: { faction }
        ACQ_TOGGLE_CURRENCY         = "HDGR_ACQ_TOGGLE_CURRENCY",    -- payload: { currency } (a Format.CostKey)
        -- Current zone button: replaces the whole Zone set at once. payload: { zones = set }
        ACQ_SET_ZONE_FILTER         = "HDGR_ACQ_SET_ZONE_FILTER",

        -- ===== Structured logging =====
        LOG_PUSH            = "HDGR_LOG_PUSH",            -- payload: { tag, level, text, timestamp, duration, metadata }
        LOG_CLEAR           = "HDGR_LOG_CLEAR",           -- payload: { tag? }  (omit = clear all)
        LOG_SET_FILTER      = "HDGR_LOG_SET_FILTER",      -- payload: { tag?, level?, autoScroll? }
        LOG_TOGGLE_AUTOSCROLL = "HDGR_LOG_TOGGLE_AUTOSCROLL",
        LOG_TRACE_TOGGLE    = "HDGR_LOG_TRACE_TOGGLE",    -- payload: { tag, on }  (tag="*" disables all)

        -- ===== Catalog reconciliation =====
        -- Fine-grained mutations dispatched by HousingCatalogObserver (per ADR-012).
        -- Hot UI actions never invalidate the catalog cache.
        COLLECTION_BULK_LOAD           = "HDGR_COLLECTION_BULK_LOAD",           -- payload: { owned, swept_at, clientVer, catalogSchemaVersion }
        COLLECTION_ITEM_LEARNED        = "HDGR_COLLECTION_ITEM_LEARNED",        -- payload: { decorID }
        COLLECTION_ITEM_REMOVED        = "HDGR_COLLECTION_ITEM_REMOVED",        -- payload: { decorID }
        COLLECTION_CATALOG_ROW_ADDED   = "HDGR_COLLECTION_CATALOG_ROW_ADDED",   -- payload: { decorID, entry }
        COLLECTION_CATALOG_ROW_REMOVED = "HDGR_COLLECTION_CATALOG_ROW_REMOVED", -- payload: { decorID }
        -- Mutable count fields changed; static row fields stay. Reducer patches 6 fields in place.
        COLLECTION_CATALOG_ROW_COUNTS_UPDATED = "HDGR_COLLECTION_CATALOG_ROW_COUNTS_UPDATED", -- payload: { decorID, counts = { quantity, numPlaced, numStored, remainingRedeemable, destroyableInstanceCount, firstAcquisitionBonus } }

        -- Pure signal: catalog searcher results hot; BindingEngine re-resolves modelPreview bindings.
        DECOR_CATALOG_READY = "HDGR_DECOR_CATALOG_READY",

        -- ===== Filter + collection actions =====
        DECOR_SET_TOP_FILTER          = "HDGR_DECOR_SET_TOP_FILTER",   -- payload: { value = "all"|... }
        DECOR_SET_TAG                 = "HDGR_DECOR_SET_TAG",           -- payload: { tag = string|nil }
        DECOR_TOGGLE_ONLY_UNCOLLECTED = "HDGR_DECOR_TOGGLE_ONLY_UNCOLLECTED",
        DECOR_TOGGLE_ONLY_STORED      = "HDGR_DECOR_TOGGLE_ONLY_STORED",
        DECOR_SET_SEARCH              = "HDGR_DECOR_SET_SEARCH",        -- payload: { query = string }
        FAVORITE_TOGGLE               = "HDGR_FAVORITE_TOGGLE",         -- payload: { itemID }
        NOTE_SET                      = "HDGR_NOTE_SET",                -- payload: { itemID, text, ts? }
        NOTE_CLEAR                    = "HDGR_NOTE_CLEAR",              -- payload: { itemID }
        VENDOR_NOTE_SET               = "HDGR_VENDOR_NOTE_SET",         -- payload: { npcID, text, ts? }
        VENDOR_NOTE_CLEAR             = "HDGR_VENDOR_NOTE_CLEAR",       -- payload: { npcID }
        -- payload: { entries = { [itemID] = { spellID, selfKnown, altKnown } } }
        RECIPE_KNOWLEDGE_UPDATED   = "HDGR_RECIPE_KNOWLEDGE_UPDATED",

        -- ===== Per-character roster (alts data layer) ===============
        -- account.characters[charKey] holds per-char professions + known recipes.
        -- CHARACTER_PROFESSION_UPDATED payload: { charKey, name, realm, class, classFile, profName,
        --   skillLines = { [expName] = { current, max } }, knownRecipes = { [recipeID] = true } }
        CHARACTER_PROFESSION_UPDATED = "HDGR_CHARACTER_PROFESSION_UPDATED",
        -- RECIPE_DATA_CAPTURED payload: { recipes = { [itemID] = { reagents = {[id]=qty},
        --   profession, spellID } }, subRecipes? = same shape + categoryName }. Ungated capture
        -- of decor-recipe data (+ the sub-recipe craft-graph closure) from ANY opened profession
        -- (own or a guildmate's window). Merges into account.recipeCapture / .subRecipeCapture --
        -- the runtime overrides read over the shipped seed DBs. See docs/RECIPE_CAPTURE_ARCHITECTURE.
        RECIPE_DATA_CAPTURED         = "HDGR_RECIPE_DATA_CAPTURED",
        -- RECIPE_HARVEST_PROGRESS payload: { phase = "headers"|"profession"|"complete"|"error"|"cancelled",
        --   done?, total?, name?, reason? }. Guild recipe harvest choreography state
        -- (session.recipeHarvest) -- drives the Recipes title Scan Guild button label.
        RECIPE_HARVEST_PROGRESS      = "HDGR_RECIPE_HARVEST_PROGRESS",
        CHARACTER_DELETED            = "HDGR_CHARACTER_DELETED",            -- payload: { charKey }
        CHARACTER_HIDDEN             = "HDGR_CHARACTER_HIDDEN",             -- payload: { charKey, hidden }
        CHARACTER_HIDDEN_TOGGLE      = "HDGR_CHARACTER_HIDDEN_TOGGLE",      -- payload: { charKey }
        -- Per-char Essence of Lumber snapshot (chrome badge + alts hover).
        -- payload: { charKey, name, realm, class, classFile, bag, bank }
        CHARACTER_ESSENCE_UPDATED    = "HDGR_CHARACTER_ESSENCE_UPDATED",
        -- Per-char decor-reagent snapshots (cross-character stock in the
        -- MaterialStock hover). Bags and bank are separate actions because bank
        -- counts are unreadable until BANKFRAME_OPENED -- one action would let a
        -- bags sweep on a bank-less alt zero a good bank map.
        -- payload: { charKey, name, realm, class, classFile,
        --            counts = {[itemID]=n}, at = time() }
        CHARACTER_REAGENT_BAGS_UPDATED = "HDGR_CHARACTER_REAGENT_BAGS_UPDATED",
        CHARACTER_REAGENT_BANK_UPDATED = "HDGR_CHARACTER_REAGENT_BANK_UPDATED",

        -- Pure signal; gated modules (CollectionReconciler, BagObserver) catch up after sleeping.
        MAIN_WINDOW_OPENING          = "HDGR_MAIN_WINDOW_OPENING",

        ALTS_SET_CHARS_POPULATION    = "HDGR_ALTS_SET_CHARS_POPULATION",  -- payload: { population = "active"|"hidden" }

        -- ===== HouseTab dashboard =====
        HOUSE_SNAPSHOT_UPDATED          = "HDGR_HOUSE_SNAPSHOT_UPDATED",          -- payload: { snapshot = table }
        HOUSE_CAPACITY_CACHED           = "HDGR_HOUSE_CAPACITY_CACHED",           -- payload: { owned, max } -- persisted last-known decor storage (survives reload for the buy picker)
        HOUSE_LIST_UPDATED              = "HDGR_HOUSE_LIST_UPDATED",              -- payload: { houses = [{houseGUID, neighborhoodName, faction, ...}] }
        HOUSE_LEVEL_UPDATED             = "HDGR_HOUSE_LEVEL_UPDATED",             -- payload: { houseGUID, level, favor, maxLevel, thresholds }
        ACTIVE_NEIGHBORHOOD_UPDATED     = "HDGR_ACTIVE_NEIGHBORHOOD_UPDATED",     -- payload: { neighborhoodGUID = string|nil }
        HOUSE_REWARDS_RECEIVED          = "HDGR_HOUSE_REWARDS_RECEIVED",          -- payload: { level, rewards = {...} }
        DAILY_BESTOWED_UPDATED          = "HDGR_DAILY_BESTOWED_UPDATED",          -- payload: { name, quote, dateKey }
        DAILY_ORC_QUOTE_SET             = "HDGR_DAILY_ORC_QUOTE_SET",             -- payload: { quote = string }
        -- Account-side layout customizations. Persist across sessions; nil = use WIDGET_DEFAULTS.
        HOUSETAB_TOGGLE_WIDGET          = "HDGR_HOUSETAB_TOGGLE_WIDGET",          -- payload: { widgetID = string }
        HOUSETAB_SET_ORDER              = "HDGR_HOUSETAB_SET_ORDER",              -- payload: { widgetID = string, order = number }
        HOUSETAB_SET_ORDERS             = "HDGR_HOUSETAB_SET_ORDERS",             -- payload: { orders = { [widgetID] = number } }  -- bulk replace
        HOUSETAB_REORDER_WIDGET         = "HDGR_HOUSETAB_REORDER_WIDGET",         -- payload: { orderedIDs = {id,...}, srcID, insertIdx }
        HOUSETAB_SET_WIDTH              = "HDGR_HOUSETAB_SET_WIDTH",              -- payload: { widgetID = string, width = "third"|"twoThirds"|"full" }
        HOUSETAB_RESIZE_WIDGET          = "HDGR_HOUSETAB_RESIZE_WIDGET",          -- payload: { widgetID = string, height = number }
        HOUSETAB_RESET_LAYOUT           = "HDGR_HOUSETAB_RESET_LAYOUT",
        HOUSETAB_TOGGLE_PICKER          = "HDGR_HOUSETAB_TOGGLE_PICKER",
        HOUSETAB_TOGGLE_DESIGN_MODE     = "HDGR_HOUSETAB_TOGGLE_DESIGN_MODE",

        -- ===== HouseEditor companion =====
        -- Taint-safe standalone window; parents to HouseEditorFrame for visibility cascade.
        COMPANION_TOGGLE             = "HDGR_COMPANION_TOGGLE",
        COMPANION_SET_MODE           = "HDGR_COMPANION_SET_MODE",           -- payload: { mode = "styles"|"rooms"|"snapshots"|"themes"|"collections"|"recent" }
        COMPANION_SELECT_ITEM        = "HDGR_COMPANION_SELECT_ITEM",        -- payload: { itemID = number|string }
        COMPANION_SET_POSITION       = "HDGR_COMPANION_SET_POSITION",       -- payload: { x, y } -- persists window placement
        COMPANION_TOGGLE_COST        = "HDGR_COMPANION_TOGGLE_COST",        -- flips the cost-badge visibility
        COMPANION_CYCLE_IO           = "HDGR_COMPANION_CYCLE_IO",           -- cycles ioFilter all->indoor->outdoor
        COMPANION_SET_LAUNCHER_POSITION = "HDGR_COMPANION_SET_LAUNCHER_POSITION", -- payload: { x, y }
        COMPANION_TOGGLE_GROUP       = "HDGR_COMPANION_TOGGLE_GROUP",       -- payload: { key = "loose"|"cat:<n>"|"smartsets" } -- folds a sidebar group

        -- Once per session; lets all consumers read strictly instead of calling UnitName/GetRealmName/UnitClass independently.
        SESSION_IDENTITY_SET         = "HDGR_SESSION_IDENTITY_SET",         -- payload: { name, realm, class, classFile }; reducer computes charKey

        -- ===== Trainers tab =====
        TRAINERS_TOGGLE_PROFESSION       = "HDGR_TRAINERS_TOGGLE_PROFESSION",       -- payload: { profession = string }
        TRAINERS_TOGGLE_MIDNIGHT_SECTION = "HDGR_TRAINERS_TOGGLE_MIDNIGHT_SECTION",
        TRAINERS_SELECT_TRAINER          = "HDGR_TRAINERS_SELECT_TRAINER",          -- payload: { npcID = number }

        -- Mogul tab UI state (mode = "profit"|"collection"; viewMode = "char"|"account"; optimizeBy).
        MOGUL_SET_MODE               = "HDGR_MOGUL_SET_MODE",
        MOGUL_SET_VIEW               = "HDGR_MOGUL_SET_VIEW",
        MOGUL_SET_OPTIMIZE_BY        = "HDGR_MOGUL_SET_OPTIMIZE_BY",
        MOGUL_SET_SUBVIEW            = "HDGR_MOGUL_SET_SUBVIEW",           -- payload: { subView = "mogul"|"goblin"|"config" }
        -- Supply Impact: mode = "off"|"smooth"|"cap"
        MOGUL_SET_SUPPLY_MODE        = "HDGR_MOGUL_SET_SUPPLY_MODE",
        MOGUL_SET_SUPPLY_SMOOTH      = "HDGR_MOGUL_SET_SUPPLY_SMOOTH",     -- payload: { pct = number }
        MOGUL_SET_SUPPLY_CAP         = "HDGR_MOGUL_SET_SUPPLY_CAP",        -- payload: { n = number }
        -- Frugal mode: bias planner toward low-lumber crafts.
        MOGUL_TOGGLE_FRUGAL          = "HDGR_MOGUL_TOGGLE_FRUGAL",
        -- ===== Goblin sub-view =====
        GOBLIN_SET_PROFESSION        = "HDGR_GOBLIN_SET_PROFESSION",
        GOBLIN_SET_EXPANSION         = "HDGR_GOBLIN_SET_EXPANSION",
        GOBLIN_SET_SEARCH            = "HDGR_GOBLIN_SET_SEARCH",
        GOBLIN_SET_KNOWLEDGE         = "HDGR_GOBLIN_SET_KNOWLEDGE",        -- payload: { mode = "all"|"known"|"alt" }
        GOBLIN_SET_QUEUE             = "HDGR_GOBLIN_SET_QUEUE",            -- payload: { mode = "all"|"only"|"hide" }
        GOBLIN_TOGGLE_AUCTIONS       = "HDGR_GOBLIN_TOGGLE_AUCTIONS",
        GOBLIN_TOGGLE_HAVE_LUMBER    = "HDGR_GOBLIN_TOGGLE_HAVE_LUMBER",
        GOBLIN_SET_SORT              = "HDGR_GOBLIN_SET_SORT",             -- payload: { col = "name"|"lumber"|... }
        GOBLIN_TOGGLE_ROW_EXPAND     = "HDGR_GOBLIN_TOGGLE_ROW_EXPAND",   -- payload: { itemID }
        PRICES_SET_PREFERRED_SOURCE  = "HDGR_PRICES_SET_PREFERRED_SOURCE", -- payload: { source = "TSM"|"Auctionator"|"Direct"|nil }
        PRICES_SET_TSM_MODE          = "HDGR_PRICES_SET_TSM_MODE",         -- payload: { mode = "min"|"market"|"region" }

        -- ===== Crafting queue + history =====
        -- CRAFT_QUEUE_DECREMENT matches by (position, recipeID) -- both needed for uniqueness.
        CRAFT_QUEUE_ADD       = "HDGR_CRAFT_QUEUE_ADD",       -- payload: { recipeID, itemID, qty }
        CRAFT_QUEUE_REMOVE    = "HDGR_CRAFT_QUEUE_REMOVE",    -- payload: { position }
        CRAFT_QUEUE_CLEAR     = "HDGR_CRAFT_QUEUE_CLEAR",
        CRAFT_QUEUE_DECREMENT = "HDGR_CRAFT_QUEUE_DECREMENT", -- payload: { recipeID, qty, position }
        -- `completed` field guards against phantom entries from multi-craft DECREMENT no-ops.
        CRAFT_HISTORY_PUSH    = "HDGR_CRAFT_HISTORY_PUSH",    -- payload: { eventType, recipeID, itemID, qty, completed, timestamp? }
        LUMBER_HISTORY_PUSH   = "HDGR_LUMBER_HISTORY_PUSH",   -- payload: { lumberID, charKey, startedAt, finalizedAt, sessionTotal, zone?, character?, realm? }

        -- ===== Recipes tab session UI =====
        RECIPES_TOGGLE_PROFESSION  = "HDGR_RECIPES_TOGGLE_PROFESSION",  -- payload: { profession = <name>|"all" }
        RECIPES_TOGGLE_EXPANSION   = "HDGR_RECIPES_TOGGLE_EXPANSION",   -- payload: { expansion = <display>|"all" }
        -- filter chips: "all"|"known"|"ready"
        RECIPES_SET_LIST_FILTER    = "HDGR_RECIPES_SET_LIST_FILTER",    -- payload: { filter }
        RECIPES_SELECT_MATERIAL     = "HDGR_RECIPES_SELECT_MATERIAL",    -- payload: { itemID|nil }
        RECIPES_SET_WH_MAT_SEARCH   = "HDGR_RECIPES_SET_WH_MAT_SEARCH",  -- payload: { query }
        RECIPES_SET_SEARCH         = "HDGR_RECIPES_SET_SEARCH",         -- payload: { query }
        RECIPES_SET_SECTION_EXPAND = "HDGR_RECIPES_SET_SECTION_EXPAND", -- payload: { key, expanded }
        RECIPES_SET_MATERIALS_DEPTH       = "HDGR_RECIPES_SET_MATERIALS_DEPTH",       -- payload: { value = "direct"|"raw" }
        RECIPES_TOGGLE_MATERIALS_GROUPING = "HDGR_RECIPES_TOGGLE_MATERIALS_GROUPING",
        RECIPES_TOGGLE_FILTER      = "HDGR_RECIPES_TOGGLE_FILTER",      -- payload: { filter }
        RECIPES_SELECT_RECIPE      = "HDGR_RECIPES_SELECT_RECIPE",      -- payload: { recipeID }
        -- Queue-row toggle: nil if recipeID matches current, else set. Scopes the materials list when set.
        RECIPES_TOGGLE_QUEUE_SELECTION = "HDGR_RECIPES_TOGGLE_QUEUE_SELECTION", -- payload: { recipeID }
        -- Opened from another window (the shopping list): selects the recipe AND gives it the materials list.
        RECIPES_SHOW_RECIPE        = "HDGR_RECIPES_SHOW_RECIPE",        -- payload: { recipeID }

        -- ===== Cross-feature observer dispatches =====
        -- Bulk payload avoids per-item dispatch spam in debug mode.
        ITEM_INFO_RESOLVED         = "HDGR_ITEM_INFO_RESOLVED",         -- payload: { itemIDs = { [n] = itemID }, count = n }
        QUEST_STATUS_RESOLVED      = "HDGR_QUEST_STATUS_RESOLVED",      -- payload: { questID = N }
        -- First character to record a completion wins; stored account-wide.
        QUEST_COMPLETION_RECORDED  = "HDGR_QUEST_COMPLETION_RECORDED",  -- payload: { completions = { [questID]={name,class} } }
        ACHIEVEMENT_STATUS_RESOLVED = "HDGR_ACHIEVEMENT_STATUS_RESOLVED", -- payload: { achievementID = N }
        BAG_INVENTORY_UPDATED      = "HDGR_BAG_INVENTORY_UPDATED",      -- payload: { tick }

        -- ===== PriceSource =====
        PRICES_CONFIG_CHANGED         = "HDGR_PRICES_CONFIG_CHANGED",
        PRICES_DIRECT_SCAN_STARTED    = "HDGR_PRICES_DIRECT_SCAN_STARTED",  -- payload: { total }
        PRICES_DIRECT_SCAN_PROGRESS   = "HDGR_PRICES_DIRECT_SCAN_PROGRESS", -- payload: { found, total }
        PRICES_DIRECT_SCAN_BATCH      = "HDGR_PRICES_DIRECT_SCAN_BATCH",    -- payload: { prices = { [itemID] = copper } }
        PRICES_DIRECT_SCAN_COMPLETED  = "HDGR_PRICES_DIRECT_SCAN_COMPLETED",-- payload: { neededItems = {[itemID]=true}, now = ts }
        PRICES_DIRECT_CACHE_CLEARED   = "HDGR_PRICES_DIRECT_CACHE_CLEARED",
        PRICES_OWNED_AUCTIONS_UPDATED = "HDGR_PRICES_OWNED_AUCTIONS_UPDATED",-- payload: { auctions = { [itemID] = { qty, buyout } } }
        -- Written on MAIN_WINDOW_OPENING + ToggleMockTSM so Config selectors stay pure.
        PRICES_ADDONS_AVAILABILITY_CHANGED = "HDGR_PRICES_ADDONS_AVAILABILITY_CHANGED",-- payload: { tsm = bool, auctionator = bool }

        -- ===== Styles =====
        STYLES_SET_VIEW              = "HDGR_STYLES_SET_VIEW",              -- payload: { view = "landing"|"detail"|"curator"|"smartset"|"import" }
        STYLES_INVALIDATE_CACHE      = "HDGR_STYLES_INVALIDATE_CACHE",
        STYLES_LANDING_SET_FILTER    = "HDGR_STYLES_LANDING_SET_FILTER",    -- payload: { filter = "all"|"style"|"smartset"|"shopping"|"snapshot"|"concept"|"collection" }
        STYLES_LANDING_TOGGLE_SECTION = "HDGR_STYLES_LANDING_TOGGLE_SECTION", -- payload: { type = string }
        STYLES_LANDING_TOGGLE_CATEGORY = "HDGR_STYLES_LANDING_TOGGLE_CATEGORY", -- payload: { key = "cat:<n>"|"loose" }
        STYLES_LANDING_SET_SEARCH    = "HDGR_STYLES_LANDING_SET_SEARCH",    -- payload: { text = string } -- the Browse list's own search slot
        STYLES_SELECT_COLLECTION     = "HDGR_STYLES_SELECT_COLLECTION",     -- payload: { collectionID = string }
        STYLES_DETAIL_SELECT_ITEM    = "HDGR_STYLES_DETAIL_SELECT_ITEM",    -- payload: { itemID = number }
        STYLES_DETAIL_SET_SEARCH     = "HDGR_STYLES_DETAIL_SET_SEARCH",     -- payload: { text = string }
        STYLES_CURATOR_SET_SOURCE    = "HDGR_STYLES_CURATOR_SET_SOURCE",    -- payload: { mode = "unassigned"|"all"|"style:<id>" }
        STYLES_CURATOR_SET_SEARCH    = "HDGR_STYLES_CURATOR_SET_SEARCH",    -- payload: { text = string } -- card-grid name filter
        STYLES_CURATOR_SET_CATEGORY  = "HDGR_STYLES_CURATOR_SET_CATEGORY",  -- payload: { categoryID = number|nil }
        STYLES_CURATOR_SET_SUBCATEGORY = "HDGR_STYLES_CURATOR_SET_SUBCATEGORY", -- payload: { subcategoryID = number|nil }
        STYLES_CURATOR_TOGGLE_SELECT = "HDGR_STYLES_CURATOR_TOGGLE_SELECT", -- payload: { itemID = number }
        STYLES_CURATOR_CLEAR_SELECT  = "HDGR_STYLES_CURATOR_CLEAR_SELECT",
        STYLES_CURATOR_MOVE          = "HDGR_STYLES_CURATOR_MOVE",          -- payload: { targetID = string, copy? = bool } -- copy=true keeps items in source
        STYLES_CURATOR_UNDO          = "HDGR_STYLES_CURATOR_UNDO",
        STYLES_CURATOR_UNDO_AT       = "HDGR_STYLES_CURATOR_UNDO_AT",       -- payload: { ord = N } -- cascade-undo from top to ord
        STYLES_CURATOR_HOVER         = "HDGR_STYLES_CURATOR_HOVER",         -- payload: { itemID = number? }
        STYLES_CURATOR_SELECT_TARGET = "HDGR_STYLES_CURATOR_SELECT_TARGET", -- payload: { targetID = string? }
        STYLES_CREATE_STYLE          = "HDGR_STYLES_CREATE_STYLE",          -- payload: { displayName = string }
        STYLES_RENAME_STYLE          = "HDGR_STYLES_RENAME_STYLE",          -- payload: { collectionID, displayName }
        STYLES_DUPLICATE_STYLE       = "HDGR_STYLES_DUPLICATE_STYLE",       -- payload: { collectionID }
        STYLES_DELETE_STYLE          = "HDGR_STYLES_DELETE_STYLE",          -- payload: { collectionID }
        -- Export is a controller side-effect; Delete reuses STYLES_DELETE_STYLE.
        STYLES_EDIT_STYLE            = "HDGR_STYLES_EDIT_STYLE",            -- payload: { collectionID }

        -- Style categories (spec HDGR_STYLE_CATEGORIES_SPEC_2026-09-04 s3.1)
        STYLE_CATEGORY_CREATE        = "HDGR_STYLE_CATEGORY_CREATE",        -- payload: { name = string, fileStyleID? = "style:<slug>" } -- name match reuses; fileStyleID files in the same dispatch
        STYLE_CATEGORY_RENAME        = "HDGR_STYLE_CATEGORY_RENAME",        -- payload: { categoryID = "cat:<n>", name = string }
        STYLE_CATEGORY_DELETE        = "HDGR_STYLE_CATEGORY_DELETE",        -- payload: { categoryID = "cat:<n>" } -- members become loose, never deleted
        STYLE_SET_CATEGORY           = "HDGR_STYLE_SET_CATEGORY",           -- payload: { collectionID = "style:<slug>", categoryID? = "cat:<n>" } -- nil = not in a category
        STYLES_SMARTSET_BEGIN          = "HDGR_STYLES_SMARTSET_BEGIN",          -- payload: { id? = string }
        STYLES_SMARTSET_SET_FIELD      = "HDGR_STYLES_SMARTSET_SET_FIELD",      -- payload: { field = "displayName"|"description", value = string }
        STYLES_SMARTSET_SET_AXIS       = "HDGR_STYLES_SMARTSET_SET_AXIS",       -- payload: { axis = string }
        STYLES_SMARTSET_SET_SEVERITY_TAB = "HDGR_STYLES_SMARTSET_SET_SEVERITY_TAB", -- payload: { sev = "all"|"signature"|"accent"|"versatile"|"clashing" }
        STYLES_SMARTSET_TOGGLE_TAG     = "HDGR_STYLES_SMARTSET_TOGGLE_TAG",     -- payload: { axis, tag, severity }
        STYLES_SMARTSET_CLEAR_ALL      = "HDGR_STYLES_SMARTSET_CLEAR_ALL",
        STYLES_SMARTSET_SAVE           = "HDGR_STYLES_SMARTSET_SAVE",
        STYLES_SMARTSET_CANCEL         = "HDGR_STYLES_SMARTSET_CANCEL",
        STYLES_SNAPSHOT_PLACED         = "HDGR_STYLES_SNAPSHOT_PLACED",         -- payload: { items=[itemID...], takenAt, displayName }
        STYLES_PLACED_DECOR_OBSERVED       = "HDGR_STYLES_PLACED_DECOR_OBSERVED",       -- payload: { decorGUID, decorID, itemID?, name? }
        STYLES_PLACED_DECOR_OBSERVED_BATCH = "HDGR_STYLES_PLACED_DECOR_OBSERVED_BATCH", -- payload: { entries = [{decorGUID, decorID, itemID?, name?}] }
        STYLES_PLACED_DECOR_REMOVED        = "HDGR_STYLES_PLACED_DECOR_REMOVED",        -- payload: { decorGUID } -- also appends a "removed" RecentActivity event
        STYLES_PLACED_DECOR_CLEAR          = "HDGR_STYLES_PLACED_DECOR_CLEAR",
        -- Recent Activity: persisted per-house edit-session history.
        RECENT_SESSION_START           = "HDGR_RECENT_SESSION_START",           -- payload: { houseKey }
        RECENT_DECOR_PLACED            = "HDGR_RECENT_DECOR_PLACED",            -- payload: { houseKey, itemID }
        STYLES_IMPORT_SET_URL          = "HDGR_STYLES_IMPORT_SET_URL",          -- payload: { text = string }
        STYLES_IMPORT_PARSE            = "HDGR_STYLES_IMPORT_PARSE",
        STYLES_IMPORT_SET_DESTINATION  = "HDGR_STYLES_IMPORT_SET_DESTINATION",  -- payload: { destination = "style"|"set"|"shopping" }
        STYLES_IMPORT_SET_TITLE        = "HDGR_STYLES_IMPORT_SET_TITLE",        -- payload: { text = string } -- editable import title (seeds the committed name)
        STYLES_IMPORT_COMMIT           = "HDGR_STYLES_IMPORT_COMMIT",           -- payload: { displayName? = string } -- Shopping List
        STYLES_IMPORT_COMMIT_AS_STYLE  = "HDGR_STYLES_IMPORT_COMMIT_AS_STYLE",  -- payload: { displayName? = string } -- My Styles (type=style collection)
        STYLES_IMPORT_COMMIT_AS_SET    = "HDGR_STYLES_IMPORT_COMMIT_AS_SET",    -- payload: { displayName? = string } -- Project Set (account.furnishingSets entry)
        STYLES_IMPORT_RESET            = "HDGR_STYLES_IMPORT_RESET",
        STYLES_OPEN_IMPORT             = "HDGR_STYLES_OPEN_IMPORT",            -- open Import view fresh: sets Styles tab + import sub-view + resets. Used by the in-Styles button AND the Tools > Import nav leaf.
        STYLES_OPEN_EXPORT             = "HDGR_STYLES_OPEN_EXPORT",            -- open Export view fresh: sets Styles tab + export sub-view + resets. Used by the in-Styles button AND the Tools > Export nav leaf.
        STYLES_EXPORT_SELECT           = "HDGR_STYLES_EXPORT_SELECT",          -- payload: { key } -- select a source (vsl:/style:/set:/collection) to encode.
        STYLES_EXPORT_SET_FORMAT       = "HDGR_STYLES_EXPORT_SET_FORMAT",      -- payload: { format = "hdg"|"dd2" }
        STYLES_EXPORT_SET_SEARCH       = "HDGR_STYLES_EXPORT_SET_SEARCH",      -- payload: { text }
        COLLECTION_STYLE_ITEM_ADDED  = "HDGR_COLLECTION_STYLE_ITEM_ADDED",  -- payload: { collectionID, itemID }
        COLLECTION_STYLE_ITEM_REMOVED = "HDGR_COLLECTION_STYLE_ITEM_REMOVED",-- payload: { collectionID, itemID }

        -- ===== Shopping list =====
        -- List IDs are monotonic "L1"/"L2"/... from shoppingListSeq. listID optional on item-scoped actions.
        SHOPPING_LIST_CREATE       = "HDGR_SHOPPING_LIST_CREATE",       -- payload: { name }
        SHOPPING_LIST_DELETE       = "HDGR_SHOPPING_LIST_DELETE",       -- payload: { id }
        SHOPPING_LIST_RENAME       = "HDGR_SHOPPING_LIST_RENAME",       -- payload: { id, name }
        SHOPPING_LIST_DUPLICATE    = "HDGR_SHOPPING_LIST_DUPLICATE",    -- payload: { id, name? }
        SHOPPING_LIST_ACTIVATE     = "HDGR_SHOPPING_LIST_ACTIVATE",     -- payload: { id }
        SHOPPING_LIST_CLEAR        = "HDGR_SHOPPING_LIST_CLEAR",        -- payload: { id }
        SHOPPING_LIST_SET_META     = "HDGR_SHOPPING_LIST_SET_META",     -- payload: { id, key, value }
        SHOPPING_LIST_IMPORT       = "HDGR_SHOPPING_LIST_IMPORT",       -- payload: { encoded }
        SHOPPING_ITEM_ADD          = "HDGR_SHOPPING_ITEM_ADD",          -- payload: { listID?, itemID, npcID?, qty? }
        SHOPPING_TOGGLE_EXPANDED   = "HDGR_SHOPPING_TOGGLE_EXPANDED",   -- payload: { bucket = "zones"|"vendors"|"wishList", key? }
        SHOPPING_ITEM_REMOVE       = "HDGR_SHOPPING_ITEM_REMOVE",       -- payload: { listID?, itemID, npcID? }
        SHOPPING_ITEM_SET_QTY      = "HDGR_SHOPPING_ITEM_SET_QTY",      -- payload: { listID?, itemID, npcID?, qty }  (absolute; EditBox direct entry)
        SHOPPING_ITEM_ADJUST_QTY   = "HDGR_SHOPPING_ITEM_ADJUST_QTY",   -- payload: { listID?, itemID, npcID?, delta }  (relative; +/- buttons, removes at <=0)
        SHOPPING_ITEM_PURCHASED    = "HDGR_SHOPPING_ITEM_PURCHASED",    -- payload: { itemID, qty }  (a merchant buy landed; ACTIVE list, any vendor row)
        DECOR_DESTROY_PROGRESS     = "HDGR_DECOR_DESTROY_PROGRESS",     -- payload: { total, done, name, waiting }  (empty = no run)
        DECOR_PIN_STORED_SORT      = "HDGR_DECOR_PIN_STORED_SORT",      -- payload: { counts = { [variantKey] = stored count } }
        SHOPPING_RESOLVE_VENDORS   = "HDGR_SHOPPING_RESOLVE_VENDORS",   -- payload: { listID, resolutions = {[itemID]=npcID} }
        SHOPPING_SET_NEIGHBORHOOD  = "HDGR_SHOPPING_SET_NEIGHBORHOOD",  -- payload: { value = "alliance"|"horde" }
        SHOPPING_WIDGET_TOGGLE     = "HDGR_SHOPPING_WIDGET_TOGGLE",

        -- ===== Vendor buying (spec docs/HDGR_VENDOR_BUYING_SPEC.md) =====
        -- MerchantObserver dispatches the snapshot; BuyQueue dispatches progress.
        MERCHANT_SET_STATE         = "HDGR_MERCHANT_SET_STATE",         -- payload: { open, npcID?, byItemID? } (observer snapshot)
        MERCHANT_BUY_PROGRESS      = "HDGR_MERCHANT_BUY_PROGRESS",      -- payload: { total?, done? }  (empty = clear)

        -- ===== Zone Scanner =====
        -- ZONE_CHANGED dispatched by ZoneObserver after debouncing ZONE_CHANGED_NEW_AREA.
        ZONE_CHANGED               = "HDGR_ZONE_CHANGED",               -- payload: { mapID }
        ZONE_POPUP_TOGGLE          = "HDGR_ZONE_POPUP_TOGGLE",
        ZONE_TOGGLE_VENDOR         = "HDGR_ZONE_TOGGLE_VENDOR",         -- payload: { npcID }
        ZONE_SET_SEARCH            = "HDGR_ZONE_SET_SEARCH",            -- payload: { text }
        ZONE_TOGGLE_COLLECTED      = "HDGR_ZONE_TOGGLE_COLLECTED",

        -- ===== Lumber Tracker =====
        -- BLIP_GC: periodic sweep that drops blips older than the respawn window.
        LUMBER_HARVESTED            = "HDGR_LUMBER_HARVESTED",            -- payload: { lumberID, qty, x, y, mapID, timestamp }
        LUMBER_SESSION_START        = "HDGR_LUMBER_SESSION_START",        -- payload: { lumberID, timestamp, startCount }
        LUMBER_SESSION_END          = "HDGR_LUMBER_SESSION_END",
        LUMBER_BLIP_GC              = "HDGR_LUMBER_BLIP_GC",              -- payload: { now }
        LUMBER_WINDOW_TOGGLE        = "HDGR_LUMBER_WINDOW_TOGGLE",        -- payload: { visible }
        LUMBER_WINDOW_POSITION_SET  = "HDGR_LUMBER_WINDOW_POSITION_SET",  -- payload: { x, y }
        LUMBER_RADAR_COLLAPSE_TOGGLE = "HDGR_LUMBER_RADAR_COLLAPSE_TOGGLE",
        LUMBER_AUTOSHOW_TOGGLE      = "HDGR_LUMBER_AUTOSHOW_TOGGLE",      -- toggle account.lumber.config.autoShowOnHarvest
        LUMBER_RADAR_SCALE_SET      = "HDGR_LUMBER_RADAR_SCALE_SET",      -- payload: { scale } (0.5..2.0)
        LUMBER_LIST_COLLAPSE_TOGGLE = "HDGR_LUMBER_LIST_COLLAPSE_TOGGLE",
        LUMBER_GOAL_TOGGLE          = "HDGR_LUMBER_GOAL_TOGGLE",            -- denominator: decor-need vs queue-need
        LUMBER_TICK                 = "HDGR_LUMBER_TICK",                 -- 1s heartbeat while farming; bumps session.lumber.tick
        REP_PROGRESS_TICK           = "HDGR_REP_PROGRESS_TICK",           -- UPDATE_FACTION/renown; bumps session.resolvers.rep.tick

        -- ===== Catalog lifecycle =====
        CATALOG_LOAD_REQUESTED    = "HDGR_CATALOG_LOAD_REQUESTED",
        CATALOG_LOAD_COMPLETED    = "HDGR_CATALOG_LOAD_COMPLETED",    -- payload: { rowCount }
        CATALOG_LOAD_FAILED       = "HDGR_CATALOG_LOAD_FAILED",       -- payload: { reason }
        CATALOG_REFRESH_QUEUED    = "HDGR_CATALOG_REFRESH_QUEUED",
        CATALOG_REFRESH_COMPLETED = "HDGR_CATALOG_REFRESH_COMPLETED", -- payload: { rowCount }
        CATALOG_INTRO_SET_PHASE   = "HDGR_CATALOG_INTRO_SET_PHASE",   -- payload: { phase = "hidden"|"loading"|"success" }
        CATALOG_FORCE_RELOAD      = "HDGR_CATALOG_FORCE_RELOAD",      -- loading-overlay Refresh; observer forces a sweep past coalesce
        -- Blizzard category/subcategory nav tree; shared by Style Curator + Projects decor picker.
        CATALOG_CATEGORY_TREE_UPDATED = "HDGR_CATALOG_CATEGORY_TREE_UPDATED", -- payload: { byID, subcatByID, rootIDs }
        CATALOG_VARIANTS_LOADED   = "HDGR_CATALOG_VARIANTS_LOADED",   -- payload: { count }
        CATALOG_VINTAGE_UPDATE    = "HDGR_CATALOG_VINTAGE_UPDATE",    -- payload: { ids = {itemID,...}, build, label, isSeed } -- observer snapshot diff; drives "New in <patch>" chip

        UI_SET_VIEW               = "HDGR_UI_SET_VIEW",  -- payload: { view }

        -- ===== Projects: house topology =====
        -- house -> version -> room model. EDITOR writers carry versionID; CAPTURE writers carry houseID.
        PROJECTS_UPSERT_HOUSE      = "HDGR_PROJECTS_UPSERT_HOUSE",      -- payload: { houseID, fields }
        -- Multi-floor rooms (stairs/tall=2, garden=3) are ONE record; FloorMap derives the
        -- vertical span + projects it up. "Expand stairwell" sets a per-placement `floors` override (LAYOUT_MOVE).
        PROJECTS_SET_ACTIVE_VERSION = "HDGR_PROJECTS_SET_ACTIVE_VERSION", -- payload: { houseID, versionID }
        PROJECTS_CREATE_VERSION    = "HDGR_PROJECTS_CREATE_VERSION",    -- payload: { houseID, versionID, name?, basedOn?, createdAt? }
        PROJECTS_DELETE_VERSION    = "HDGR_PROJECTS_DELETE_VERSION",    -- payload: { houseID, versionID, ts? }
        PROJECTS_CAPTURE_COMMIT    = "HDGR_PROJECTS_CAPTURE_COMMIT",    -- payload: { houseID, rooms, deleteRoomIDs, lastCapturedAt }
        PROJECTS_HOUSE_TICK        = "HDGR_PROJECTS_HOUSE_TICK",        -- payload: { budget?, numFloors?, editorActive? }
        PROJECTS_ROOM_CATALOG_UPDATED = "HDGR_PROJECTS_ROOM_CATALOG_UPDATED", -- payload: { byShapeID, entries }
        PROJECTS_CLEAR_HOUSE       = "HDGR_PROJECTS_CLEAR_HOUSE",       -- payload: { houseID, maxFloor? } (v8 recapture prep: prune capture-owned placements above maxFloor + reset echo; tags survive)
        PROJECTS_SET_VERSION_FLOORS = "HDGR_PROJECTS_SET_VERSION_FLOORS", -- payload: { versionID, numFloors }
        PROJECTS_RENAME_VERSION    = "HDGR_PROJECTS_RENAME_VERSION",    -- payload: { versionID, name }
        PROJECTS_IMPORT_LAYOUT     = "HDGR_PROJECTS_IMPORT_LAYOUT",     -- payload: { houseID, version, houseName? } (controller-built record; reducer mints id + activates; houseName stamps an uncaptured house)
        PROJECTS_FOCUS_HOUSE       = "HDGR_PROJECTS_FOCUS_HOUSE",       -- payload: { houseID } (which house the Architect/Projects views focus)
        PROJECTS_PICKER_SET_SOURCE = "HDGR_PROJECTS_PICKER_SET_SOURCE", -- payload: { source } ("all" | "style:<id>" | "shop:<id>")
        PROJECTS_FURN_TOGGLE_COLLAPSE = "HDGR_PROJECTS_FURN_TOGGLE_COLLAPSE", -- payload: { setID } (fold/unfold a set group in the room detail)

        -- ===== Blueprints tab (12.1; C_HousingBlueprint) =====
        BLUEPRINT_AVAILABLE_SET       = "HDGR_BLUEPRINT_AVAILABLE_SET",       -- payload: { available }
        BLUEPRINT_COLLECTION_RECEIVED = "HDGR_BLUEPRINT_COLLECTION_RECEIVED", -- payload: { groups, slots }
        BLUEPRINT_CONTENTS_REQUESTED  = "HDGR_BLUEPRINT_CONTENTS_REQUESTED",  -- payload: { shareCode, requestedAt }
        BLUEPRINT_CONTENTS_RECEIVED   = "HDGR_BLUEPRINT_CONTENTS_RECEIVED",   -- payload: { shareCode, raw = HousingBlueprintContentInfo }
        BLUEPRINT_CONTENTS_FAILED     = "HDGR_BLUEPRINT_CONTENTS_FAILED",     -- payload: { shareCode, reasonCode = Enum.HousingResult }
        BLUEPRINT_PENDING_TICK        = "HDGR_BLUEPRINT_PENDING_TICK",        -- payload: { now } (observer 1s ticker while pending)
        BLUEPRINT_PASTE_ADD           = "HDGR_BLUEPRINT_PASTE_ADD",           -- payload: { shareCode, blueprintType? } (persisted pasted-library add)
        BLUEPRINT_SELECT              = "HDGR_BLUEPRINT_SELECT",              -- payload: { shareCode }
        BLUEPRINT_SET_TARGET_HOUSE    = "HDGR_BLUEPRINT_SET_TARGET_HOUSE",    -- payload: { houseGUID } (session-scoped "Opaque-N")
        BLUEPRINT_SET_LABEL           = "HDGR_BLUEPRINT_SET_LABEL",           -- payload: { shareCode, label } (persisted)
        BLUEPRINT_FORGET              = "HDGR_BLUEPRINT_FORGET",              -- payload: { shareCode } (HDG-state-only; never touches Blizzard's catalog)
        BLUEPRINT_TOGGLE_SECTION      = "HDGR_BLUEPRINT_TOGGLE_SECTION",      -- payload: { section = "pasted"|"catalog" }; flips account.ui.blueprints.collapsedSections[section]
        BLUEPRINT_LIBRARY_SET_SORT    = "HDGR_BLUEPRINT_LIBRARY_SET_SORT",    -- payload: { col }; same col flips dir, new col resets (text cols asc, date cols desc)
        BLUEPRINT_SET_HIDE_BACKUPS    = "HDGR_BLUEPRINT_SET_HIDE_BACKUPS",    -- payload: { hide } -> account.ui.blueprints.hideBackups (persisted Library preference)
        BLUEPRINT_SET_NOTE            = "HDGR_BLUEPRINT_SET_NOTE",            -- payload: { shareCode, text } (persisted; WireNoteBox shape)
        BLUEPRINT_CLEAR_NOTE          = "HDGR_BLUEPRINT_CLEAR_NOTE",          -- payload: { shareCode }
        BLUEPRINT_EXPORT_SUCCESS      = "HDGR_BLUEPRINT_EXPORT_SUCCESS",      -- payload: { shareCode }
        BLUEPRINT_MANIFESTS_STALE     = "HDGR_BLUEPRINT_MANIFESTS_STALE",     -- payload: none; decor storage changed -> every received manifest's counts are suspect

        -- ===== Projects: shipping crates =====
        -- Whole-house manifest snapshot. Controller builds the record; reducer just writes it.
        SHIPPING_CRATE_PACK        = "HDGR_SHIPPING_CRATE_PACK",        -- payload: { shipID, record }
        SHIPPING_CRATE_DELETE      = "HDGR_SHIPPING_CRATE_DELETE",      -- payload: { shipID }

        -- ===== Furnishings (v7 model: docs/crate-redesign/10-FINAL-MODEL.md) =====
        -- Sets are free-standing quantified plans; rooms are persistent identities;
        -- layouts hold placements. IDs counter-minted reducer-side (set:N / room:N / slot:N).
        FURN_SET_CREATE            = "HDGR_FURN_SET_CREATE",            -- payload: { name, items?, isLocal?, ownerRoom? }
        FURN_SET_RENAME            = "HDGR_FURN_SET_RENAME",            -- payload: { setID, name }
        FURN_SET_DELETE            = "HDGR_FURN_SET_DELETE",            -- payload: { setID } (cascades out of every room's equip list)
        FURN_SET_ITEM_ADD          = "HDGR_FURN_SET_ITEM_ADD",          -- payload: { setID, itemID, count? } (count sets; absent increments)
        FURN_SET_ITEM_REMOVE       = "HDGR_FURN_SET_ITEM_REMOVE",       -- payload: { setID, itemID, all? } (decrement; 0 or all removes)
        FURN_SET_PROMOTE           = "HDGR_FURN_SET_PROMOTE",           -- payload: { setID, name } (local -> library)
        FURN_ROOM_CREATE           = "HDGR_FURN_ROOM_CREATE",           -- payload: { shape, name?, layoutID?, slotKey? } (slotKey: create-in-place from an unassigned slot)
        FURN_ROOM_RENAME           = "HDGR_FURN_ROOM_RENAME",           -- payload: { roomID, name }
        FURN_ROOM_DELETE           = "HDGR_FURN_ROOM_DELETE",           -- payload: { roomID } (cascades placements across ALL layouts; local sets demote to library)
        FURN_ROOM_EQUIP            = "HDGR_FURN_ROOM_EQUIP",            -- payload: { roomID, setID }
        FURN_ROOM_UNEQUIP          = "HDGR_FURN_ROOM_UNEQUIP",          -- payload: { roomID, setID }
        FURN_ROOM_DUPLICATE        = "HDGR_FURN_ROOM_DUPLICATE",        -- payload: { roomID, layoutID?, swap?, ts? } (variant: library sets shared, local pieces cloned; swap takes the source's placement in layoutID)
        LAYOUT_PLACE               = "HDGR_LAYOUT_PLACE",               -- payload: { layoutID, floor, x, y, rotation?, floors?, roomID? | shape? } (roomID places a room; shape places an unassigned slot; floors = planned multi-storey span)
        LAYOUT_MOVE                = "HDGR_LAYOUT_MOVE",                -- payload: { layoutID, key, floor?, x?, y?, rotation? }
        LAYOUT_REMOVE_PLACEMENT    = "HDGR_LAYOUT_REMOVE_PLACEMENT",    -- payload: { layoutID, key }
        LAYOUT_ASSIGN              = "HDGR_LAYOUT_ASSIGN",              -- payload: { layoutID, slotKey, roomID } (tag a slot with a room; multi-assign OK)
        LAYOUT_UNASSIGN            = "HDGR_LAYOUT_UNASSIGN",            -- payload: { layoutID, key } (clear the tag; spot reverts to a bare shape)
        LAYOUT_SWAP_ROOM           = "HDGR_LAYOUT_SWAP_ROOM",           -- payload: { layoutID, fromRoomID, toRoomID } (the placement changes hands; once-per-layout enforced)
    },

    -- ===== UI sizing constants =====
    -- Per CLAUDE.md rule #9: hardcoded sizes / spacing go here, not inlined.
    STYLE = {
        CARD_GRID = {
            CELL_SIZE     = 80,
            CELLS_PER_ROW = 6,
            CELL_SPACING  = 1,
            ROW_SPACING   = 1,
        },
        CARD_GRID_DETAIL  = { CELLS_PER_ROW = 8, CELL_SIZE = 80 },
        CARD_GRID_PREVIEW = { CELLS_PER_ROW = 8, CELL_SIZE = 80 },
        CARD_GRID_BASKET  = { CELLS_PER_ROW = 2, CELL_SIZE = 60 },
        TREE_LIST = {
            INDENT      = 18,    -- px offset per nesting level
            ROW_HEIGHT  = 22,
            ROW_SPACING = 1,
        },
    },
}


-- ===== Source-kind master table =====
-- Canonical source-of-truth for source/gate kinds. Priority-ordered (most-binding first).
-- All lookups (chip color, labels, chipLabels, filter values, donor codes) derive from this.
-- Adding a new kind: one row here. Every consumer picks it up automatically.
-- Schema: key (uppercase), donorCode (HDG compat), filterValue, label, chipLabel, useInFilter.

-- Class color hex ("AARRGGBB"), mirroring GetClassColorObj():GenerateHexColor() -- pure data.
HDG.Constants.CLASS_COLORS = {
    DEATHKNIGHT = "ffc41e3a", DEMONHUNTER = "ffa330c9", DRUID   = "ffff7c0a",
    EVOKER      = "ff33937f", HUNTER      = "ffaad372", MAGE    = "ff3fc7eb",
    MONK        = "ff00ff98", PALADIN     = "fff48cba", PRIEST  = "ffffffff",
    ROGUE       = "fffff468", SHAMAN      = "ff0070dd", WARLOCK = "ff8788ee",
    WARRIOR     = "ffc69b6d",
}

HDG.Constants.SOURCE_KINDS = {
    { key="REP",      donorCode=13, filterValue="reputation",  label="Reputation",   chipLabel="REP",  useInFilter=true },
    { key="CRAFT",    donorCode=6,  filterValue="crafted",     label="Crafted",      chipLabel="PROF", useInFilter=true },
    { key="QUEST",    donorCode=2,  filterValue="quest",       label="Quest",        chipLabel="QUST", useInFilter=true },
    { key="ACH",      donorCode=1,  filterValue="achievement", label="Achievement",  chipLabel="ACH",  useInFilter=true },
    -- PROMO ranks above VENDOR: for promo-reward items also buyable, the promo IS the acquisition.
    { key="PROMO",    donorCode=10, filterValue="promotional", label="Promotional",  chipLabel="PROMO", useInFilter=true },
    { key="VENDOR",   donorCode=5,  filterValue="vendor",      label="Vendor",       chipLabel="VEND", useInFilter=false },
    { key="SHOP",     donorCode=12, filterValue="shop",        label="In-Game Shop", chipLabel="SHOP", useInFilter=true },
    -- EVENT (donor 14): catalog "Event:" prefix; distinct from PROMO (out-of-game promos).
    { key="EVENT",    donorCode=14, filterValue="event",       label="Event",        chipLabel="EVNT", useInFilter=true },
    { key="TREASURE", donorCode=9,  filterValue="treasure",    label="Treasure",     chipLabel="TREA", useInFilter=true },
    { key="DROP",     donorCode=4,  filterValue="drop",        label="Drop",         chipLabel="DROP", useInFilter=true },
    -- Honest fallback when NO source signal exists. donorCode 0 = the existing
    -- [0] UNKNOWN color. Lowest priority so any real signal wins; filterable so
    -- the data gaps surface (never silently default to DROP).
    { key="UNKN",     donorCode=0,  filterValue="unknown",     label="Unknown",      chipLabel="UNKN", useInFilter=true },
}

-- Derived indexes -- built once, O(1) lookup thereafter.
HDG.Constants.SOURCE_KIND_BY_KEY    = {}  -- "CRAFT" → entry
HDG.Constants.SOURCE_KIND_BY_DONOR  = {}  -- 6       → entry
HDG.Constants.SOURCE_KIND_BY_FILTER = {}  -- "crafted" → entry
HDG.Constants.SOURCE_KIND_PRIORITY  = {}  -- {"REP","CRAFT","QUEST",...} priority-order keys
for i, k in ipairs(HDG.Constants.SOURCE_KINDS) do
    HDG.Constants.SOURCE_KIND_BY_KEY[k.key]            = k
    HDG.Constants.SOURCE_KIND_BY_DONOR[k.donorCode]    = k
    HDG.Constants.SOURCE_KIND_BY_FILTER[k.filterValue] = k
    HDG.Constants.SOURCE_KIND_PRIORITY[i]              = k.key
end

-- Catalog sourceText token -> SOURCE_KINDS key. Used by _ParseSourceText.
-- `Profession` ABSENT: CRAFT comes only from the recipe DB, not catalog strings.
-- `Faction`/`Renown` not here -- they feed row.factionGate -> REP.
HDG.Constants.CATALOG_SOURCE_TOKENS = {
    ["Vendor"]       = "VENDOR",
    ["Vendors"]      = "VENDOR",   -- plural variant (catalog emits both)
    ["Quest"]        = "QUEST",
    ["Achievement"]  = "ACH",
    ["Drop"]         = "DROP",
    ["Treasure"]     = "TREASURE",
    ["Event"]        = "EVENT",
    ["Shop"]         = "SHOP",      -- bare line, no colon
    ["In-Game Shop"] = "SHOP",      -- bare line, no colon
    ["Promotion"]    = "PROMO",     -- bare line, no colon
}

-- Acquisition source-filter options. Derived from SOURCE_KINDS where useInFilter.
-- Tail: cost-based pseudo-filters (endeavor/gold) not backed by a kind.
HDG.Constants.ACQ_SOURCES = { { value = "all", label = "All Sources" } }
for _, k in ipairs(HDG.Constants.SOURCE_KINDS) do
    if k.useInFilter then
        HDG.Constants.ACQ_SOURCES[#HDG.Constants.ACQ_SOURCES + 1] =
            { value = k.filterValue, label = k.label }
    end
end
HDG.Constants.ACQ_SOURCES[#HDG.Constants.ACQ_SOURCES + 1] = { value = "endeavor", label = "Endeavor"  }
-- WHAT A NEW PLAYER CAN ACTUALLY BUY (asked for by ReganB, 2026-08-14).
--
-- THESE REPLACE "Gold Only", which is gone rather than kept alongside. It
-- answered a question about COST -- has a price, all of it gold -- and said
-- nothing about whether you can REACH the thing, so it listed promotional and
-- in-game-shop decor that happens to be priced in gold, and stock behind a
-- questline. Nobody wanted the answer to the question it was actually
-- answering, and two filters differing by an invisible axis is worse than one.
--
-- Both of these are about REACH. They sit in the sources dropdown because
-- that is where a player looks for "how do I get this", even though neither is
-- strictly a source -- the precedent Gold Only set is the one thing worth
-- keeping from it.
HDG.Constants.ACQ_SOURCES[#HDG.Constants.ACQ_SOURCES + 1] =
    { value = "neighborhood", label = "Neighborhood" }
HDG.Constants.ACQ_SOURCES[#HDG.Constants.ACQ_SOURCES + 1] =
    { value = "ungated",      label = "Gold, no unlocks" }

-- THE TWO HOUSING NEIGHBORHOODS, by mapID.
--
-- BY ID, NEVER BY NAME. VendorAugment carries both, and the zone STRING is
-- localised -- matching "Razorwind Shores" returns nothing at all on a French
-- client, silently, which is the worst way for a filter to fail. The ID is the
-- same everywhere.
--
-- Vendors standing here are ungated by construction: you are in your own
-- neighborhood, so there is no questline between you and the merchant. That is
-- what makes the `neighborhood` filter exact rather than a good guess.
-- Keyed by the toggle's own value so the shopping preference maps to a uiMapID
-- without a second lookup table drifting from this one.
HDG.Constants.NEIGHBORHOOD_MAP_BY_FACTION = {
    alliance = 2352,   -- Founder's Point
    horde    = 2351,   -- Razorwind Shores
}

-- Both directions derived from the one table above -- a hand-maintained second
-- copy is how the pair goes out of sync the day a third neighborhood ships.
HDG.Constants.NEIGHBORHOOD_MAP_IDS       = {}
HDG.Constants.NEIGHBORHOOD_FACTION_BY_MAP = {}
for faction, mapID in pairs(HDG.Constants.NEIGHBORHOOD_MAP_BY_FACTION) do
    HDG.Constants.NEIGHBORHOOD_MAP_IDS[mapID]        = true
    HDG.Constants.NEIGHBORHOOD_FACTION_BY_MAP[mapID] = faction
end

-- Gold has no Blizzard currency ID; CURRENCY_GOLD sentinel lets cost-entry tables iterate uniformly.
HDG.Constants.COIN_ATLAS    = "|A:auctionhouse-icon-coin-gold:14:14|a"
HDG.Constants.CURRENCY_GOLD = -1   -- sentinel; real currency IDs are positive
HDG.Constants.GOLD_NAME     = "Gold"  -- the sentinel has no C_CurrencyInfo record to take a name from

-- 134400 = INV_Misc_QuestionMark.blp -- canonical "?" placeholder for missing icons.
HDG.Constants.PLACEHOLDER_ICON = 134400

-- Vendor buy queue pacing (spec HDGR_VENDOR_BUYING_SPEC.md s2.1/s2.2/s6).
-- Two constraints: the server rejects >~13-15 rapid buys in a burst, AND items
-- bought faster than storage absorbs them pile up in real bags instead of going
-- straight to decor storage. Live test 2026-07-05: 3-per-tick (a 3-call burst
-- inside one tick) left 7 of 10 in bags -- the burst IS the rapid path. So buy
-- exactly ONE per tick (genuine one-at-a-time = the straight-to-storage path).
-- Functional throttle, NOT a UI transition (outside the no-C_Timer-in-UI rule).
-- Community Coupons: the Midnight neighbourhood-endeavor currency, and the only
-- non-gold cost decor vendors charge. Named here because it was a bare 3363 in
-- the acquisition selectors and is now also the merchant buy path's one
-- recognised currency.
HDG.Constants.COUPON_CURRENCY_ID     = 3363
HDG.Constants.MERCHANT_BUY_TICK_QTY  = 1     -- fixed-timer fallback: BuyMerchantItem calls per tick
-- 0 = EVENT-DRIVEN pacing (buy one, wait for the HOUSING_STORAGE_ENTRY_UPDATED
-- "landed in storage" signal, buy the next -- as fast as the server confirms,
-- one buy in flight so it never outruns the burst cap or strands items in bags).
-- >0 = legacy fixed-interval ticker at that many seconds.
HDG.Constants.MERCHANT_BUY_TICK_SECS    = 0     -- seconds between ticks (0 = event-driven)
-- Stall WATCHDOG, not a pacer. Pacing is purely landing-driven (one buy in flight);
-- this only exists so a genuinely DROPPED landed signal can't hang the picker forever.
-- On fire it STOPS the batch (never advances -- advancing while a buy is still in
-- flight is what stranded an item in bags). Generous so a merely slow-to-start signal
-- (first landings lag 2-3s + a ~500ms catalog settle) never trips it.
HDG.Constants.MERCHANT_BUY_TIMEOUT_SECS = 8
-- How long a merchant buy may take to LAND before its claim on the shopping list
-- lapses. Past this, a count rise is not credited to it: a failed buy must not
-- claim a later, unrelated rise (decor picked back up from a house). Well past
-- the 2-3s first-landing lag the watchdog above allows for.
HDG.Constants.MERCHANT_PURCHASE_CREDIT_SECS = 15

-- Destroy queue (Modules/HDGR_DestroyQueue.lua). The server takes a burst of
-- destroys, then drops the rest without a word until it recovers, and only the
-- item's owned total tells (live 12.1, 2026-09-19: three runs of 101 at 3 in
-- flight each stopped landing at 26-28; the dropped ones never landed).
-- IN_FLIGHT_MAX: destroys waiting on the server at once -- what a drop can cost.
-- DROP_SECS: nothing landed for this long = the server dropped what is in flight.
--   A landing takes ~0.4 s; ten times that keeps a slow connection's late
--   landing from being written off and sent again.
-- RETRY_SECS: the wait before the next single try while the server is paused.
-- RETRY_LIMIT: tries in a row with nothing landing before the run gives up
--   (~1.5 minutes at DROP_SECS + RETRY_SECS each).
HDG.Constants.DESTROY_IN_FLIGHT_MAX = 3
HDG.Constants.DESTROY_DROP_SECS     = 4
HDG.Constants.DESTROY_RETRY_SECS    = 3
HDG.Constants.DESTROY_RETRY_LIMIT   = 12

-- The nine Housing Dye items, one per colour family. A blueprint's dye entries
-- name these item IDs, and they are the only non-decor items a shopping list
-- carries: the housing catalog has no row for them, so without this set the list
-- import dropped a build's dyes on the way in. Live 12.1.0.69814 (wago): the
-- DyeColor table maps all 77 colours onto exactly these nine ItemIDs, and
-- ItemSparse Bonding is 0 on every one -- tradeable, so they shop in the Auction
-- House lane (bought there, or crafted from herbs at the dye station).
HDG.Constants.HOUSING_DYE_ITEM_IDS = {
    [274464] = true,   -- Black
    [274468] = true,   -- Blue
    [274469] = true,   -- Brown
    [274470] = true,   -- Green
    [274471] = true,   -- Orange
    [274472] = true,   -- Purple
    [274473] = true,   -- Red
    [274474] = true,   -- White
    [274475] = true,   -- Yellow
}

-- Guild recipe harvest choreography (ProfessionScanner:StartGuildHarvest; timings
-- ported from VWB RecipeHarvest -- functional throttles, not UI transitions).
HDG.Constants.GUILD_HARVEST_HEADER_TIMEOUT = 5      -- s; QueryGuildRecipes -> GUILD_TRADESKILL_UPDATE wait
HDG.Constants.GUILD_HARVEST_PROF_TIMEOUT   = 10     -- s; per-profession ViewGuildRecipes wait (largest profs load slow)
HDG.Constants.GUILD_HARVEST_PAUSE          = 0.25   -- s; breather between profession loads

-- Outreach URLs (Config tab About section).
HDG.Constants.DISCORD_URL = "https://discord.gg/RWZaxJaHFP"
HDG.Constants.COFFEE_URL  = "https://buymeacoffee.com/vamoose"
HDG.Constants.DISCORD_TEXTURE = "Interface\\AddOns\\HousingDecorGuide\\textures\\discord.tga"
-- Wowhead logo: shopping-list row icon + detail URL-box icon for wowhead-sourced lists.
HDG.Constants.WOWHEAD_TEXTURE = "Interface\\AddOns\\HousingDecorGuide\\textures\\wowhead_logo"

-- REP_FACTIONS: every reputation faction referenced by a row.factionGate.
-- .faction = player faction restriction ("A"/"H"/"N") -- lets _bakeGates skip wrong-side gates.
-- Static map avoids C_Reputation.GetFactionDataByIndex (skips collapsed/legacy factions, taint risk).
HDG.Constants.REP_FACTIONS = {
    -- Alliance-only
    [47]   = { name = "Ironforge",                  faction = "A" },
    [72]   = { name = "Stormwind",                  faction = "A" },
    [1134] = { name = "Gilneas",                    faction = "A" },
    [1174] = { name = "Wildhammer Clan",            faction = "A" },
    [1731] = { name = "Council of Exarchs",         faction = "A" },
    [2160] = { name = "Proudmoore Admiralty",       faction = "A" },
    [2162] = { name = "Storm's Wake",               faction = "A" },

    -- Horde-only
    [922]  = { name = "Tranquillien",               faction = "H" },
    [1708] = { name = "Laughing Skull Orcs",        faction = "H" },
    [2103] = { name = "Zandalari Empire",           faction = "H" },
    [2156] = { name = "Talanji's Expedition",       faction = "H" },
    [2157] = { name = "The Honorbound",             faction = "H" },

    -- Neutral (both factions)
    [1271] = { name = "Order of the Cloud Serpent", faction = "N" },
    [1273] = { name = "Jogu the Drunk",             faction = "N" },
    [1275] = { name = "Ella",                       faction = "N" },
    [1280] = { name = "Tina Mudclaw",               faction = "N" },
    [1283] = { name = "Farmer Fung",                faction = "N" },
    [1345] = { name = "The Lorewalkers",            faction = "N" },
    [1515] = { name = "Arakkoa Outcasts",           faction = "N" },
    [1828] = { name = "Highmountain Tribe",         faction = "N" },
    [1859] = { name = "The Nightfallen",            faction = "N" },
    [1883] = { name = "Dreamweavers",               faction = "N" },
    [2391] = { name = "Rustbolt Resistance",        faction = "N" },
    [2507] = { name = "Dragonscale Expedition",     faction = "N" },
    [2510] = { name = "Valdrakken Accord",          faction = "N" },
    [2669] = { name = "Darkfuse Solutions",         faction = "N" },
    [2671] = { name = "Venture Company",            faction = "N" },
    [2673] = { name = "Bilgewater Cartel",          faction = "N" }, -- TWW Undermine (NOT 1133 Cata Horde-only)
    [2675] = { name = "Blackwater Cartel",          faction = "N" },
    [2677] = { name = "Steamwheedle Cartel",        faction = "N" },
    [2770] = { name = "Slayer's Duellum",           faction = "N" },

    -- Midnight (verified Faction.db2 12.0.5)
    [2699] = { name = "The Singularity",            faction = "N" },
    [2704] = { name = "Hara'ti",                    faction = "N" },
    [2710] = { name = "Silvermoon Court",           faction = "N" },
    [2764] = { name = "Prey: Season 1",             faction = "N" },
    -- Silvermoon Court subsidiaries (friendship reps, MoP-Tillers-style; parent 2710).
    -- friendship=true -> rep gates render as "reputation", not "Renown N".
    [2711] = { name = "Magisters",                  faction = "N", friendship = true },
    [2712] = { name = "Blood Knights",              faction = "N", friendship = true },
    [2713] = { name = "Farstriders",                faction = "N", friendship = true },
    [2714] = { name = "Shades of the Row",          faction = "N", friendship = true },
}

-- Reverse index: name -> factionID. Lowercase aliases absorb catalog casing drift ("the Honorbound").
HDG.Constants.REP_FACTION_BY_NAME = {}
for id, e in pairs(HDG.Constants.REP_FACTIONS) do
    HDG.Constants.REP_FACTION_BY_NAME[e.name] = id
    HDG.Constants.REP_FACTION_BY_NAME[string.lower(e.name)] = id
end

-- ===== Pet decor =============================================================
-- Decor a PET can be placed on -- beds, plinths, cages, nests. It is furniture,
-- not a placed pet, so these are ordinary contentType 3 (Decor) catalog rows.
--
-- Keyed by decorID, which is what a blueprint manifest entry carries directly
-- (entry.recordID for contentType 3) -- so the split survives a catalog miss.
--
-- Source: HouseDecor.db2 `Flags & 0x800` (2048), the bit Blizzard sets for
-- pet-accepting decor. Exactly these 10 of 2911 rows carry it on 12.1.0.69382,
-- with no false positives (Rutaani Bird Perch and Perch of the Dawnfire Phoenix
-- are perch-shaped scenery and correctly unflagged). The runtime catalog API
-- does NOT expose the flag, which is why the list is baked here rather than
-- read live. Regenerate by re-filtering HouseDecor.csv when a patch adds pet
-- furniture; at 10 rows a constant beats a generated table.
HDG.Constants.PET_DECOR_BY_DECOR_ID = {
    [12245] = true,  -- Paw Pal Bed and Blanket
    [12246] = true,  -- Paw Pal Bed
    [15290] = true,  -- Cherished Pet's Rug
    [25101] = true,  -- Westfall Pet Cage
    [25102] = true,  -- Crossroads Pet Cage
    [25103] = true,  -- Crude Pet Cage
    [25105] = true,  -- Silvermoon Dragonhawk Incubator
    [25106] = true,  -- Cozy Lightbloom Lilypad
    [25121] = true,  -- Cozy Bird Nest
    [25122] = true,  -- Loyal Companion's Plinth
}

-- A memoized selector's cached value is dropped after this many dispatches
-- without a hit (Selectors:InvalidateMemos ages them). Every memo used to live
-- for the session whether its view was ever revisited: 70 live memos, ~5 MB
-- (2026-09-13 audit). A hit resets the age; a miss recomputes once.
HDG.Constants.MEMO_IDLE_DISPATCHES = 400
