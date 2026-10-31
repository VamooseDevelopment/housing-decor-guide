-- HDG.SessionIdentity
-- ============================================================================
-- Populates session.identity = { name, realm, class, classFile, factionGroup,
-- raceID, classID, charKey } once per session (identity is stable until /reload).
-- All consumers read state.session.identity; none call UnitName/GetRealmName/
-- UnitClass/UnitRace directly. Owns C_CreatureInfo too: the names of races and
-- classes other than the player's, for Decor Quests' "Evoker only".
--
-- Why onEnable not PLAYER_LOGIN: PLAYER_LOGIN is owned by Init.lua's bootstrap;
-- onEnable runs after it drains, guaranteeing UnitName + UnitClass resolve.

HDG.Log:RegisterTags({ identity = { user = false, level = "warn" } })

HDG = HDG or {}
HDG.SessionIdentity = HDG.SessionIdentity or {}

-- Returns nil when identity hasn't dispatched yet (sentinel "" charKey -> nil).
function HDG.SessionIdentity.GetCharKey(state)
    local key = state.session.identity.charKey
    if key == "" then return nil end
    return key
end

-- The whole record, same boot-window contract. Added because three observers
-- had each grown a private copy of exactly this -- EssenceObserver and
-- ProfessionScanner byte-for-byte, ReagentStockObserver reading the Store
-- itself. They existed because the SSoT published the key and nothing else,
-- which is how a single source of truth quietly stops being one.
function HDG.SessionIdentity.GetIdentity(state)
    local id = state.session.identity
    if id.charKey == "" then return nil end
    return id
end

-- A class or race in the client's language, by ID. Synchronous DB2 data; nil for
-- an ID the client does not know.
function HDG.SessionIdentity.ClassName(classID)
    local info = C_CreatureInfo.GetClassInfo(classID)
    return info and info.className   -- exception(boundary): GetClassInfo is nil for an unknown classID
end

function HDG.SessionIdentity.RaceName(raceID)
    local info = C_CreatureInfo.GetRaceInfo(raceID)
    return info and info.raceName   -- exception(boundary): GetRaceInfo is nil for an unknown raceID
end

HDG.Modules:Declare({
    name = "SessionIdentity",
    dependencies = {},
    ownsBlizzardNamespaces = { "C_CreatureInfo" },
    onEnable = function(self)
        local name, realm = _G.UnitName("player")
        if not name then
            -- onEnable is guaranteed to fire after PLAYER_LOGIN drains, so
            -- UnitName MUST resolve. If it doesn't, that's a load-order
            -- regression worth surfacing -- not silently leaving identity
            -- at "" for the whole session (which causes consumers to
            -- silently early-exit).
            HDG.Log:Warn("identity",
                "SessionIdentity: UnitName returned nil at onEnable -- session.identity stays empty")
            return
        end
        if not realm or realm == "" then
            realm = _G.GetRealmName() or ""
        end
        local class, classFile, classID = _G.UnitClass("player")
        local _, _, raceID = _G.UnitRace("player")
        -- factionGroup: normalize UnitFactionGroup -> "A"/"H"/"N" to match
        -- HDGR_VendorDB row[6] convention. Stamped once; selectors read
        -- state.session.identity.factionGroup (never call UnitFactionGroup).
        -- Pandaren faction swap mid-session requires /reload to re-stamp.
        local fg = _G.UnitFactionGroup("player")
        local factionTag = (fg == "Horde" and "H") or (fg == "Alliance" and "A") or "N"
        HDG.Store:Dispatch({
            type    = HDG.Constants.ACTIONS.SESSION_IDENTITY_SET,
            payload = {
                name         = name,
                realm        = realm,
                class        = class     or "",
                classFile    = classFile or "",
                factionGroup = factionTag,
                raceID       = raceID  or 0,   -- exception(boundary): UnitRace may return nothing
                classID      = classID or 0,   -- exception(boundary): UnitClass may return nothing
            },
        })
    end,
})
