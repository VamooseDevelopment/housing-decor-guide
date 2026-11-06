-- HDG.HolidayObserver
-- ============================================================================
-- Whether the Feast of Winter Veil is on now, for the Winter Veil theme offer
-- (UI/HDGR_Controller_WinterVeilOffer.lua), from its fixed dates
-- (HDG.Constants.WINTER_VEIL_UTC) against the server clock.
--
-- It used to read today's events from the calendar. In chat-messaging lockdown
-- those events come back with secret fields -- the event table itself is not
-- secret, so issecretvalue(e) let it through -- and comparing calendarType was a
-- taint error (themindboggle, Discord 2026-11-03). Winter Veil's dates don't
-- move, so HDG no longer asks the calendar.
--
-- Read at enable and on each loading screen. HOLIDAY_SET goes out only on a change.

HDG = HDG or {}
HDG.HolidayObserver = HDG.HolidayObserver or {}
local HO = HDG.HolidayObserver

-- A UTC time as one comparable number within its year, MMDDhh
local function _stamp(month, day, hour)
    return (month * 100 + day) * 100 + hour
end

-- The start year of the Winter Veil on now, or 0 when none is. It runs across the
-- new year: from its start in December it is this year's, and in January before
-- its end it is last year's.
function HO:TodaysWinterVeil()
    local now = date("!*t", GetServerTime())
    local wv  = HDG.Constants.WINTER_VEIL_UTC
    local stamp = _stamp(now.month, now.day, now.hour)
    if stamp >= _stamp(wv.startMonth, wv.startDay, wv.hour) then return now.year end
    if stamp <  _stamp(wv.endMonth,   wv.endDay,   wv.hour) then return now.year - 1 end
    return 0
end

function HO:Scan()
    local year = self:TodaysWinterVeil()
    if year == self._last then return end
    self._last = year
    HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.HOLIDAY_SET, payload = { winterVeil = year } })
end

-- ===== Module registration ===================================================
HDG.Modules:Declare({
    name = "HolidayObserver",
    dependencies = {},
    blizzardEvents = {
        -- A session that runs into Winter Veil picks it up at the next loading screen.
        PLAYER_ENTERING_WORLD = { handler = "OnLoadingScreen" },
    },
    onEnable = function(self)
        HO:Scan()
    end,
    OnLoadingScreen = function(self)
        HO:Scan()
    end,
})
