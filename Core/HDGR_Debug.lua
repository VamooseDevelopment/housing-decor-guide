-- HDG.Debug
-- ============================================================================
-- Dev half of the /hdgr slash REPL. Explicit multi-line dumps; prints raw (not Log:Notify).
-- Each command is a named function so it's callable directly, not only via the slash string.

HDG = HDG or {}
HDG.Debug = HDG.Debug or {}

local D = HDG.Debug

-- Header: "[HDG] <line>". Detail/code-gen lines print bare (tables stay aligned / copy-pasteable).
local function _print(line) _G.print("|cff666666[HDG]|r " .. line) end

-- /hdgr help -- SSoT for the slash surface. Keep in sync when commands are added/removed.
local function _cmd(cmd, desc) _G.print(("  |cffcdd6f4%-24s|r |cff999999%s|r"):format(cmd, desc)) end
function D:Help()
    _print("commands -- user:")
    _cmd("/hdgr",              "open / close the main window")
    _cmd("/hdgr help",         "this listing (also /hdgr ?)")
    _cmd("/hdgr theme [name]", "list themes / switch theme (case-insensitive prefix)")
    _cmd("/hdgr view [name]",  "list views / switch the main window's active view")
    _cmd("/hdgr minimap",      "toggle the minimap button")
    _cmd("/hdgr resetlayout",  "reset the HouseTab dashboard layout to defaults")
    _cmd("/hdgr hardreset",    "wipe all saved HDG data (full reset)")
    _cmd("/hdgr refresh",      "force a fresh housing-catalog sweep")
    _G.print("|cff666666[HDG]|r commands -- developer:")
    _cmd("/hdgr debug",            "toggle debug logging mode (the dispatch firehose etc.)")
    _cmd("/hdgr mocktsm",          "toggle Mock TSM (flat 100g prices, no TSM) -- same as the Advanced checkbox")
    _cmd("/hdgr trace [tag/off]",  "list active traces / toggle a log-tag trace / disable all")
    _cmd("/hdgr log [tag/clear]",  "last 10 log entries (opt. filtered by tag) / clear the log")
    _cmd("/hdgr house",            "dump the HouseTab dashboard runtime state (widget/data chain)")
    _cmd("/hdgr petscene",         "dump the ACTIVE pet stage's runtime state (camera/actors/keys)")
    _cmd("/hdgr petseat <z>",      "eyeball a scene decor's seat height, to bake into SCENE_SEAT_Z")
    _cmd("/hdgr dashtaint",        "audit WHO tainted the Blizzard dashboard's teleport chain")
    _cmd("/hdgr dashdump",         "visibility + data state of the stranded dashboard, layer by layer")
    _cmd("/hdgr dashsync",         "test whether a warm house-list request replies synchronously")
    _cmd("/hdgr costdump [id]",    "a row's parsed cost + sourceTags; no id: the picked vendor's tiles")
    _cmd("/hdgr dumpdecor <ids>",  "emit AllDecorDB-ready Lua rows for decorIDs (copy-paste)")
    _cmd("/hdgr tipdump [ids]",    "dump C_TooltipInfo line types for itemIDs (finds gates the catalog omits)")
    _cmd("/hdgr tipdump bags",     "  same, sweeping carried items -- control for 'can we see gates at all'")
    _cmd("/hdgr tipdump merch [n]","  the OPEN vendor: all slots, or one slot in full")
    _cmd("/hdgr tipdump gt",       "  arm, hover anything, re-run: rendered lines VS readable data")
    _cmd("/hdgr sl <cmd>",         "selector call-count profiler: start / stop / dump / clear")
    _cmd("/hdgr perf [on/off/reset]", "performance profiler (bare opens the window)")
    _cmd("/hdgr doors",            "door audit for the OPEN Architect canvas (ShapeAtlas verify)")
    _cmd("/hdgr winterveil",       "show the Winter Veil theme offer now (closing it uses up nothing)")
end

-- The window's first build waits for combat end, so the pop-up would have no
-- window to sit on.
function D:WinterVeil()
    if InCombatLockdown() then  -- exception(boundary): Blizzard combat lockdown
        _print("/hdgr winterveil: out of combat only")
        return
    end
    if not HDG.Store:GetState().account.ui.mainWindowShown then HDG:ToggleMainWindow() end
    HDG.WinterVeilOffer.Preview(HDG.mainFrame)
end

-- ===== Config toggles =======================================================

function D:Toggle()
    local cfg = HDG.Store:GetState().account.config
    HDG.Store:Dispatch({
        type = HDG.Constants.ACTIONS.CONFIG_SET,
        payload = { key = "debug", value = not cfg.debug },
    })
end

function D:MockTSM()
    -- Flat 100g prices; exercises the TSM code path without installing TSM.
    local on = HDG.PriceSource:ToggleMockTSM()
    HDG.Log:Notify("info", ("mock TSM = %s"):format(on and "on" or "off"))
end

-- ===== Trace toggling =======================================================
-- /hdgr trace            -- list active traces
-- /hdgr trace <tag>      -- toggle trace for tag
-- /hdgr trace off        -- disable all traces
function D:Trace(rest)
    local arg = (rest or ""):gsub("%s", "")
    if arg == "" then
        local active = HDG.Store:GetState().session.log.activeTraces or {}
        local any = false
        for tag, on in pairs(active) do
            if on then
                if not any then _print("Active traces:"); any = true end
                _G.print(("  |cff14b8a6%s|r"):format(tag))
            end
        end
        if not any then _print("no active traces") end
        _G.print("|cff666666Usage: /hdgr trace <tag>  -  /hdgr trace off|r")
    elseif arg == "off" then
        HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.LOG_TRACE_TOGGLE, payload = { tag = "*" } })
        _print("all traces disabled")
    else
        if not HDG.Log:HasTag(arg) then
            _print(("unknown tag %q -- registered tags:"):format(arg))
            for name in pairs(HDG.Log.TAGS) do _G.print(("  |cff14b8a6%s|r"):format(name)) end
        else
            HDG.Store:Dispatch({
                type    = HDG.Constants.ACTIONS.LOG_TRACE_TOGGLE,
                payload = { tag = arg },   -- omitting `on` toggles
            })
            local nowActive = HDG.Store:GetState().session.log.activeTraces[arg]
            _print(("trace %q -> %s"):format(arg, nowActive and "on" or "off"))
        end
    end
end

-- ===== Log dump / clear =====================================================
-- /hdgr log                -- last 10 entries
-- /hdgr log <tag>          -- last 10 of that tag
-- /hdgr log clear [<tag>]  -- clear all or one tag
function D:Log(rest)
    local arg = HDG.Format.Trim(rest)
    if arg:match("^clear") then
        local tag = arg:match("^clear%s+(%S+)$")
        if tag then
            HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.LOG_CLEAR, payload = { tag = tag } })
            _print(("cleared log entries tagged %q"):format(tag))
        else
            HDG.Store:Dispatch({ type = HDG.Constants.ACTIONS.LOG_CLEAR })
            _print("log cleared")
        end
        return
    end
    local tagFilter = arg ~= "" and arg or nil
    local entries = HDG.Store:GetState().session.log.entries or {}
    local matched = {}
    for _, e in ipairs(entries) do
        if not tagFilter or e.tag == tagFilter then matched[#matched + 1] = e end
    end
    local start = math.max(1, #matched - 9)
    _print(("log (last %d of %d%s):"):format(
        math.min(10, #matched), #matched, tagFilter and (" tagged " .. tagFilter) or ""))
    for i = start, #matched do
        local e = matched[i]
        _G.print(("  |cff666666%.1f|r |cff14b8a6%-12s|r |cff999999%-7s|r %s"):format(
            e.timestamp or 0, e.tag, e.level, e.text))  -- migration (legacy log entries)
    end
end

-- Dump dashboard runtime state (selector empty? widget not built? data not pushed?).
-- Eyeball a decor's seat height live. A bounding box cannot say where a bed's
-- cushion is, so the two scene decors get their seat measured by eye, ONCE, and
-- written into Constants.MENAGERIE.SCENE_SEAT_Z. This is that measuring stick:
-- nudge until the pet sits right, then read the number back and bake it.
--
-- The override is widget-local and dies with a /reload -- it calibrates, it does
-- not persist. Baking the value is a deliberate second step.
function D:PetSeat(rest)
    local w = HDG.UI:PetStage()
    if not w then _print("no stage widget built -- open the pet card first") return end
    local spec = w._sceneSpec
    if not (spec and spec.decor) then
        _print("no decor on the stage -- click a scene chip (bed / plinth) first")
        return
    end
    local arg = rest and rest:match("^%s*(%S+)")
    if not arg then
        _print(("seat for decor %d (%s):"):format(spec.decor.decorID, spec.decor.name))
        _G.print(("  bbox top:   %.4f   (the fallback -- right only if flat-topped)"):format(w._decorTopZ))
        _G.print(("  baked:      %s"):format(tostring(spec.decor.seatZ)))
        _G.print(("  override:   %s"):format(tostring(w._seatOverride)))
        _G.print("  usage: /hdg petseat <z>   |   /hdg petseat clear")
        return
    end
    if arg == "clear" then
        w._seatOverride = nil
        _print("seat override cleared")
    else
        local z = tonumber(arg)
        if not z then _print("seat must be a number, or 'clear'") return end
        w._seatOverride = z
        _print(("seat override %.4f on decor %d (%s) -- bake it into SCENE_SEAT_Z when it looks right")
            :format(z, spec.decor.decorID, spec.decor.name))
    end
    w:Reframe()
end

function D:PetScene()
    -- The ACTIVE host's stage. Hardcoding the Menagerie's made this dump answer
    -- "no stage widget built" from the Decor tab -- the one host a scene bug had
    -- actually been reported in.
    local w = HDG.UI:PetStage()
    if not w then _print("no stage widget built") return end
    _print("petscene diagnostic dump:")
    local cx, cy, cz = w._scene:GetCameraPosition()
    _G.print(("  camera:      %.2f, %.2f, %.2f  (build default = 6, 0, 1.2)"):format(cx, cy, cz))
    _G.print(("  decorTopZ:   %s"):format(tostring(w._decorTopZ)))
    local k = w._sceneKeys or {}
    _G.print(("  keys:        decor=%s pet=%s you=%s"):format(tostring(k.decor), tostring(k.pet), tostring(k.you)))
    local spec = w._sceneSpec
    if spec then
        _G.print(("  spec:        sid=%s display=%s h=%s scale=%s lift=%s you=%s"):format(
            tostring(spec.speciesID), tostring(spec.petDisplayID), tostring(spec.petHeight),
            tostring(spec.petScale), tostring(spec.petLift), tostring(spec.withYou)))
    else
        _G.print("  spec:        nil")
    end
    local pet = w._petActor
    if pet then
        local px, py, pz = pet:GetPosition()
        _G.print(("  pet actor:   loaded=%s scale=%.4f requested=%s pos=%.2f,%.2f,%.2f"):format(
            tostring(pet:IsLoaded()), pet:GetScale(), tostring(pet:GetRequestedScale()), px, py, pz))
        -- WHERE ARE ITS FEET. SetPosition places the model ORIGIN at pos x scale
        -- (the position is in the actor's scaled frame), and a mesh authored
        -- above or below its own origin lands off the seat by minZ x scale on
        -- top of that -- which is what seatLift is generated to cancel. Printing the box is
        -- the only way to see whether the generated number matches this model:
        -- one pet standing correctly and another floating at the SAME seat means
        -- the two disagree about where their origin is.
        --
        -- Caveat, and it is a big one: for a creature this box is a union over
        -- the whole animation set, so a travelling idle inflates it (the recorded
        -- Gill'dan case, 8x). Read minZ as "the lowest this model ever goes",
        -- not "where it stands".
        local minX, minY, minZ, maxX, maxY, maxZ = pet:GetActiveBoundingBox()
        if minZ then
            local sc = pet:GetScale()
            _G.print(("   pet box:    z %.4f..%.4f  x %.4f..%.4f  y %.4f..%.4f"):format(
                minZ, maxZ, minX, maxX, minY, maxY))
            _G.print(("   feet at:    %.4f   ((pos %.4f + minZ %.4f) x scale %.4f)"):format(
                (pz + minZ) * sc, pz, minZ, sc))
        else
            _G.print("   pet box:    nil -- model not streamed")
        end
    else
        _G.print("  pet actor:   nil")
    end
    -- The decor actor, which the dump used to omit entirely -- and the composed
    -- seat is computed from ITS bounding box, so a wrong-looking composition
    -- cannot be diagnosed without it.
    local dec = w._decorActor
    if dec then
        local dx, dy, dz = dec:GetPosition()
        local ok, _, _, _, _, _, maxZ = pcall(dec.GetActiveBoundingBox, dec)  -- exception(boundary): nil until streamed
        _G.print(("  decor actor: loaded=%s pos=%.2f,%.2f,%.2f boxMaxZ=%s"):format(
            tostring(dec:IsLoaded()), dx, dy, dz, tostring(ok and maxZ)))
    else
        _G.print("  decor actor: nil")
    end
    _G.print(("  you actor:   %s"):format(
        w._youActor and tostring(w._youActor:IsLoaded()) or "nil"))
    _G.print(("  portrait:    %s  (no decor AND no You = portrait framing)"):format(
        tostring(w._sceneSpec ~= nil and not w._sceneSpec.decor and not w._sceneSpec.withYou)))
    _G.print(("  scene shown: %s  widget %dx%d"):format(
        tostring(w._scene:IsVisible()), w:GetWidth(), w:GetHeight()))  -- exception(boundary): debug print, WoW API
end

function D:DashTaint()
    -- issecurevariable(tbl, key) -> secure, taintingAddon: names WHO tainted each
    -- link of the dashboard's house-list -> teleport chain. Ground truth for the
    -- ADDON_ACTION_FORBIDDEN TeleportHome blame.
    local dash = _G.HousingDashboardFrame
    if not dash then _print("dashboard not loaded") return end
    local function probe(label, tbl, key)
        if not tbl then _G.print(("  %s: FRAME MISSING"):format(label)) return end
        local secure, tainter = _G.issecurevariable(tbl, key)
        _G.print(("  %s.%s: %s%s  (value: %s)"):format(label, key,
            secure and "SECURE" or "TAINTED",
            tainter and (" by " .. tostring(tainter)) or "",
            tostring(tbl[key])))
    end
    _print("dashboard taint audit:")
    -- Bracket-indexed: HouseDropdown is a 12.1 parentKey; wowlua-ls stubs are 12.0.7.
    local dd = dash["HouseDropdown"]
    probe("HouseDropdown", dd, "playerHouseList")
    probe("HouseDropdown", dd, "selectedHouseInfo")
    local info = dash.HouseInfoFrame or dash.HouseInfoContent  -- exception(boundary): parentKey name per Blizzard XML
    local content = info and info.ContentFrame
    local upg = content and content.HouseUpgradeFrame
    probe("HouseUpgradeFrame", upg, "houseList")
    probe("HouseUpgradeFrame", upg, "houseInfo")
    local tp = upg and upg.TeleportToHouseButton
    probe("TeleportToHouseButton", tp, "houseInfo")
    probe("TeleportToHouseButton", tp, "teleportToPlot")
end

function D:DashDump()
    -- Visibility + data-chain state of every layer of the stranded dashboard.
    local dash = _G.HousingDashboardFrame
    if not dash then _print("dashboard not loaded") return end
    local function line(label, v) _G.print(("  %s: %s"):format(label, tostring(v))) end
    local function shown(label, f) line(label, f and (f:IsShown() and "SHOWN" or "hidden") or "MISSING") end
    _print("dashboard state dump:")
    local info = dash["HouseInfoContent"]
    shown("HouseInfoContent", info)
    if not info then return end
    shown("LoadingSpinner", info["LoadingSpinner"])
    shown("DashboardNoHousesFrame", info["DashboardNoHousesFrame"])
    shown("HouseFinderButton", info["HouseFinderButton"])
    local content = info["ContentFrame"]
    shown("ContentFrame", content)
    if content then
        line("tabsInitialized", content["tabsInitialized"])
        shown("HouseUpgradeFrame", content["HouseUpgradeFrame"])
        shown("InitiativesFrame", content["InitiativesFrame"])
        local init = content["InitiativesFrame"]
        line("InitiativesFrame.playerHouseList", init and init.playerHouseList and ("table n=" .. #init.playerHouseList))
        local upg = content["HouseUpgradeFrame"]
        line("HouseUpgradeFrame.houseList", upg and upg.houseList and ("table n=" .. #upg.houseList))
        line("HouseUpgradeFrame.houseInfo", upg and tostring(upg["houseInfo"]))
    end
    local dd = dash["HouseDropdown"]
    line("HouseDropdown.playerHouseList", dd and dd.playerHouseList and ("table n=" .. #dd.playerHouseList))
    -- Who is actually registered on the EventRegistry for the dropdown's
    -- broadcasts? Read-only walk of callbackTables[type][event][owner].
    for _, ev in ipairs({ "HouseDropdown.HouseListUpdated", "HouseDropdown.HouseListLoading",
                          "HouseDropdown.HouseSelected" }) do
        local n, paneIn = 0, false
        for _, byEvent in pairs(_G.EventRegistry:GetCallbackTables()) do
            local owners = byEvent[ev]
            if owners then
                for owner in pairs(owners) do
                    n = n + 1
                    if owner == info then paneIn = true end
                end
            end
        end
        line(ev, ("%d registered%s"):format(n, paneIn and " (PANE REGISTERED)" or "  -- PANE MISSING"))
    end
end

function D:DashSync()
    -- Does C_Housing.GetPlayerOwnedHouses reply SYNCHRONOUSLY when the client
    -- cache is warm? If yes, the dashboard's dropdown broadcasts its house list
    -- DURING its own OnLoad -- before the House Info pane exists -- and the pane
    -- strands deaf for the session (the /reload blank-dashboard bug).
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("PLAYER_HOUSE_LIST_UPDATED")
    local fired = false
    f:SetScript("OnEvent", function() fired = true end)
    _G.C_Housing.GetPlayerOwnedHouses()
    f:UnregisterAllEvents()
    _print(("PLAYER_HOUSE_LIST_UPDATED fired synchronously inside the call: %s"):format(tostring(fired)))
end

function D:House()
    local root = HDG.mainFrame
    _print("house diagnostic dump:")
    _G.print(("  view:           %s"):format(tostring(HDG.Store:GetState().account.ui.view)))
    _G.print(("  mainFrame:      %s"):format(root and "exists" or "MISSING"))
    if root then
        local pnl = root.panels and root.panels["houseTabPanel"]
        local pkr = root.widgets and root.widgets["houseTabPanel.pickerBtn"]
        local dsn = root.widgets and root.widgets["houseTabPanel.designBtn"]
        local lst = root.widgets and root.widgets["houseTabPanel.list"]
        _G.print(("  panel frame:    %s"):format(pnl and "built" or "MISSING"))
        _G.print(("  pickerBtn:      %s"):format(pkr and "built" or "MISSING"))
        _G.print(("  designBtn:      %s"):format(dsn and "built" or "MISSING"))
        _G.print(("  list widget:    %s"):format(lst and "built" or "MISSING"))
        if lst then
            _G.print(("    bound:        %s"):format(lst._hdgrBound and "yes" or "NO"))
            _G.print(("    rowKind:      %s"):format(tostring(lst.rowKind)))
            _G.print(("    parent type:  %s"):format(lst:GetParent() and lst:GetParent():GetName() or "?"))
            _G.print(("    visible:      %s, sz=%dx%d"):format(
                tostring(lst:IsVisible()), lst:GetWidth() or 0, lst:GetHeight() or 0))  -- exception(boundary): debug print, WoW API
            _G.print(("    provider sz:  %d"):format(lst.provider and lst.provider:GetSize() or -1))
        end
        if root.widgets then
            local count = 0
            for id in pairs(root.widgets) do
                if id:match("^houseTabPanel") then count = count + 1 end
            end
            _G.print(("  houseTab widgets in rootFrame.widgets: %d"):format(count))
        end
    end
    local snap = HDG.Store:GetState().session.house and HDG.Store:GetState().session.house.snapshot or nil
    _G.print(("  snapshotChangeSeq:   %s"):format(tostring(HDG.Store:GetState().session.house and HDG.Store:GetState().session.house.snapshotChangeSeq)))
    _G.print(("  snapshot keys:  %s"):format(snap and tostring(next(snap) or "EMPTY") or "nil"))
    local items = HDG.Selectors:Call("house.widgetList", HDG.Store:GetState(), {})  -- exception(false-positive): debug dump function, not a row factory
    _G.print(("  widgetList:     %d items"):format(#items))
    if #items > 0 then
        _G.print(("    [1] id=%s height=%s data=%s"):format(
            tostring(items[1].id), tostring(items[1].height),
            items[1].data and tostring(next(items[1].data) or "empty-data-table") or "nil"))
    end
    local placements = root and root.placements or {}
    local p = placements["houseTabPanel"]
    _G.print(("  panel placed:   %s"):format(p and ("%dx%d at (%d,%d)"):format(p.width or 0, p.height or 0, p.x or 0, p.y or 0) or "(not placed)"))
    local pl = placements["houseTabPanel.list"]
    _G.print(("  list placed:    %s"):format(pl and ("%dx%d at (%d,%d)"):format(pl.width or 0, pl.height or 0, pl.x or 0, pl.y or 0) or "(not placed)"))
end

-- Dump row's parsed cost + source table for an itemID. Diagnostic for endeavor/gold.
-- /hdg costdump with no itemID: the tiles of the vendor picked in Shop by Vendor,
-- each with the cost text its tooltip shows and the catalog row's cost line.
-- Probe for "no Cost line on any tile" (owner 10-31), which the recorded catalog
-- does not reproduce: 2,457 of 2,519 tiles carry one headless.
local function _dumpVendorTiles()
    local st = HDG.Store:GetState()
    local ui = st.session.ui.acquisition
    _print(("costdump tiles: vendor %s (npcID %s), catalog ready %s"):format(
        tostring(ui.selectedVendorName), tostring(ui.selectedNpcID),
        tostring(HDG.HousingCatalogObserver:IsReady())))
    local tiles, priced = HDG.Selectors:Call("acq.selected.items", st, {}), 0
    for i, ed in ipairs(tiles) do
        if ed.costText ~= "" then priced = priced + 1 end
        if i <= 6 then
            local row = HDG.HousingCatalogObserver:GetRow(ed.itemID)
            _G.print(("  %d %s | tile %q | row %q | variants %d"):format(ed.itemID, tostring(ed.name),
                tostring(ed.costText), tostring(row and row.costLine), row and #row.costVariants or -1))  -- exception(nullable): probe prints a miss as -1
        end
    end
    _G.print(("  %d tiles, %d with a cost"):format(#tiles, priced))
end

function D:CostDump(rest)
    local id = tonumber((rest or ""):match("%d+"))
    if not id then return _dumpVendorTiles() end
    local row = HDG.HousingCatalogObserver:GetRow(id)
    if not row then
        _print(("no catalog row for %d (catalog ready? item matches searcher?)"):format(id))
        return
    end
    local function ceStr(list)
        if not list or #list == 0 then return "EMPTY" end
        local s = ""
        for _, e in ipairs(list) do s = s .. ("[%s x%s]"):format(HDG.Format.CostKey(e), tostring(e.amount)) end
        return s
    end
    _print(("costdump %d: %s"):format(id, row.name or "?"))
    _G.print(("  vendors: %d"):format(row.vendors and #row.vendors or 0))  -- exception(nullable): vendors list optional
    for i, v in ipairs(row.vendors or {}) do
        -- ZONE + npcID per entry. Two records that resolved to the SAME zone are
        -- the signature of a vendor missing one of its per-zone augment rows:
        -- the second zone falls back to the first's npcID and gets its zone
        -- stamped over the catalog's (see the multi-zone vendor note in
        -- _flushVendor). Without these two fields the duplicate is invisible.
        _G.print(("    [%d] %s | zone=%s | npcID=%s | cost=%q | costEntries=%s"):format(
            i, tostring(v.name), tostring(v.zone), tostring(v.npcID),
            tostring(v.cost), ceStr(v.costEntries)))
    end
    _G.print("  row.costEntries: " .. ceStr(row.costEntries))
    _G.print("  row.costLine: " .. tostring(row.costLine))
    _G.print("  row.shop: " .. tostring(row.shop))
    local tags = ""
    for _, t in ipairs(row.sourceTags or {}) do tags = tags .. "[" .. tostring(t.kind) .. "]" end
    _G.print("  sourceTags: " .. (tags ~= "" and tags or "none"))
    -- THE RAW STRING, last and unabridged. Everything above is HDG's own parse,
    -- which reports our bugs back as if they were Blizzard's data -- so a
    -- vendor-attribution question can only be settled against this line.
    -- |n is the WoW escape, not a newline; rendered as " // " to keep it on one
    -- chat line.
    local e = _G.C_HousingCatalog and row.decorID
        and _G.C_HousingCatalog.GetCatalogEntryInfoByRecordID(1, row.decorID)  -- exception(boundary): live catalog getter; nil pre-sweep
    local raw = e and e.sourceText
    _G.print("  RAW sourceText: " .. (raw and raw ~= "" and raw:gsub("|n", " // ") or "(empty)"))
    local info = row.decorID and _G.C_HousingCatalog
             and _G.C_HousingCatalog.GetCatalogEntryInfoByRecordID(1, row.decorID)
    if info and info.sourceText and info.sourceText ~= "" then
        local st = info.sourceText
        _G.print("  live sourceText: " .. (st:gsub("|", "||")))
        _G.print("  find 'Cost:': " .. tostring(st:find("Cost:") ~= nil))
        _G.print("  amt  Cost:[^digit]*(digits): " .. tostring(st:match("Cost:[^%d]*([%d,]+)")))
        _G.print("  curr currency:(digits): " .. tostring(st:match("currency:(%d+)")))
    else
        _G.print("  live sourceText: (empty / unavailable)")
    end
end

-- Emit AllDecorDB-ready Lua rows for decorIDs. Code lines print bare (paste into HDG_AllDecorDB.lua).
function D:DumpDecor(rest)
    rest = rest or ""
    if rest == "" then _G.print("|cff666666Usage: /hdgr dumpdecor <id1>,<id2>,...|r"); return end
    local ids = {}
    for s in rest:gmatch("%d+") do ids[#ids + 1] = tonumber(s) end
    if #ids == 0 then _G.print("|cff666666Usage: /hdgr dumpdecor <id1>,<id2>,...|r"); return end
    _print(("Dumping %d decorID rows -- copy lines into HDG_AllDecorDB.lua:"):format(#ids))
    local exp = "Midnight"   -- caller can re-tag per row as needed
    local now = time()
    for _, decorID in ipairs(ids) do
        local info = _G.C_HousingCatalog
                 and _G.C_HousingCatalog.GetCatalogEntryInfoByRecordID
                 and _G.C_HousingCatalog.GetCatalogEntryInfoByRecordID(1, decorID)
        if info and info.itemID then
            local subcat = (info.subcategoryIDs and info.subcategoryIDs[1]) or 0
            _G.print(("    [%d] = {%d, 12, \"Blizzard Shop\", \"\", %d, exp = %q, name = %q, placementCost = 0, quality = %d, subcats = {%d}, ver = 120001},"):format(
                info.itemID, decorID, now, exp,
                info.name or "?", info.quality or 1, subcat))  -- exception(boundary): debug print, info from cold cache
        else
            _G.print(("    -- decorID %d: GetCatalogEntryInfoByRecordID returned nil"):format(decorID))
        end
    end
    _G.print("|cff666666(sourceType=12 = Shop is the default guess; adjust per item if it came from elsewhere.)|r")
end

-- ===== Tooltip gate probe ===================================================
-- The housing catalog omits some gates outright: the Brawl'gar rank items carry
-- a red "Requires Brawl'gar Arena - Rank N" on the tooltip and NOTHING in
-- sourceText, so every filter that asks "can I just go and buy this" says yes.
-- Enum.TooltipDataLineType.UsageRequirement (43) marks those lines structurally
-- and lineData.requirementType names why (Reputation / Achievement / Level / ...),
-- which would make the gate readable without matching localized text.
-- This dumps raw line types so that claim can be checked against real items
-- before anything is built on it.

local TIPDUMP_DEFAULT_IDS = { 263026, 259071, 255840, 248337 }  -- 3 Brawl'gar rank-gated + 1 plain gold control (Round-Top Boulder)
local USAGE_REQUIREMENT = 43   -- Enum.TooltipDataLineType.UsageRequirement

local _enumNames = {}   -- [enumTable] = { [value] = name }, built on first use
local function _enumName(enumTable, value)
    if value == nil then return "-" end
    local byValue = _enumNames[enumTable]
    if not byValue then
        byValue = {}
        for name, v in pairs(enumTable) do byValue[v] = name end
        _enumNames[enumTable] = byValue
    end
    return ("%s(%s)"):format(byValue[value] or "?", tostring(value))
end

-- exception(boundary): C_TooltipInfo hands back secret-string-backed tables under
-- taint and indexing them throws, so structure and text are probed in SEPARATE
-- pcalls -- the numeric type/requirementType fields survive a secret leftText,
-- and they are the signal we actually want.
local function _probeLines(getter)
    local ok, result = pcall(function()
        local data = getter()
        if not (data and data.lines) then return nil end
        local out = {}
        for i, line in ipairs(data.lines) do
            out[i] = { lineType = line.type, reqType = line.requirementType, raw = line }
        end
        return out
    end)
    if not ok then return nil, tostring(result) end
    return result, nil
end

-- Requirement-type names for every UsageRequirement line present, in order.
local function _gateNames(lines)
    local names = {}
    for _, e in ipairs(lines or {}) do   -- exception(nullable): a getter with no data returns nil lines
        if e.lineType == USAGE_REQUIREMENT then
            names[#names + 1] = _enumName(_G.Enum.TooltipDataUsageRequirementType, e.reqType)
        end
    end
    return names
end

local function _gateSuffix(lines)
    local names = _gateNames(lines)
    if #names == 0 then return "" end
    return (" |cffe06c75GATE [%s]|r"):format(table.concat(names, ", "))
end

-- exception(boundary): same secret-string hazard, isolated per line so one tainted
-- string does not cost us the whole dump.
local function _safeLeftText(line)
    local ok, shown = pcall(function()
        local text = line.leftText
        if text == nil then return "" end
        return (text:gsub("|", "||"))
    end)
    return ok and shown or "|cffe06c75<secret string -- unreadable>|r"
end

local function _safeRightText(line)
    local ok, shown = pcall(function()
        local text = line.rightText
        if text == nil then return "" end
        return (" |cff888888// " .. text:gsub("|", "||") .. "|r")
    end)
    return ok and shown or " |cffe06c75<secret rightText>|r"
end

-- TooltipDataArg carries the structured payload behind a line. If a requirement
-- rides along as data rather than as a line type, it is in here.
local function _argValue(a)
    if a.stringVal ~= nil then return a.stringVal end
    if a.intVal    ~= nil then return a.intVal end
    if a.floatVal  ~= nil then return a.floatVal end
    if a.boolVal   ~= nil then return a.boolVal end
    if a.guidVal   ~= nil then return a.guidVal end
    return nil
end

local function _argsStr(line)
    local ok, shown = pcall(function()
        if not line.args then return "" end
        local parts = {}
        for _, a in ipairs(line.args) do
            parts[#parts + 1] = ("%s=%s"):format(tostring(a.field), tostring(_argValue(a)))
        end
        if #parts == 0 then return "" end
        return "\n        args{ " .. table.concat(parts, " | ") .. " }"
    end)
    return ok and shown or "\n        args{<unreadable>}"
end

local function _printLines(lines)
    for i, e in ipairs(lines) do
        local isGate = (e.lineType == USAGE_REQUIREMENT)
        _G.print(("   %s[%2d] %-28s req=%-24s %s%s%s"):format(
            isGate and "|cffe06c75>>|r " or "   ", i,
            _enumName(_G.Enum.TooltipDataLineType, e.lineType),
            _enumName(_G.Enum.TooltipDataUsageRequirementType, e.reqType),
            _safeLeftText(e.raw), _safeRightText(e.raw), _argsStr(e.raw)))
    end
end

-- GetItemByID renders a context-free tooltip; the hyperlink and owned-item paths
-- can carry player-conditional lines it drops. Probing all three separates
-- "this item has no gate" from "this getter cannot see gates".
local function _tipDumpOne(itemID)
    C_Item.RequestLoadItemDataByID(itemID)   -- idempotent; a cold item needs a second run
    local getters = {
        { name = "GetItemByID",      fn = function() return C_TooltipInfo.GetItemByID(itemID) end },
        { name = "GetHyperlink",     fn = function() return C_TooltipInfo.GetHyperlink("item:" .. itemID) end },
        { name = "GetOwnedItemByID", fn = function() return C_TooltipInfo.GetOwnedItemByID(itemID) end },
    }
    _print(("item %d"):format(itemID))
    local richest = nil
    for _, g in ipairs(getters) do
        local lines, err = _probeLines(g.fn)
        if err then
            _G.print(("  |cffe06c75%-18s threw -- %s|r"):format(g.name, err))
        else
            _G.print(("  %-18s %d lines%s"):format(g.name, lines and #lines or 0, _gateSuffix(lines)))
            if lines and (not richest or #lines > #richest) then richest = lines end
        end
    end
    if not richest or #richest <= 1 then
        _G.print("  |cffe5c07b(no usable lines -- item data cold, run the command again)|r")
        return
    end
    _printLines(richest)
end

-- Sweep the player's own bags. This is the CONTROL: if nothing the player carries
-- produces a UsageRequirement line either, the line type is not readable from
-- addon code at all and the whole approach is dead -- not just for decor.
local function _tipDumpBags()
    local scanned, gated = 0, 0
    for bag = 0, 5 do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do   -- exception(boundary): nil for a bag the player has not equipped
            local lines = _probeLines(function() return C_TooltipInfo.GetBagItem(bag, slot) end)
            if lines and #lines > 0 then
                scanned = scanned + 1
                if #_gateNames(lines) > 0 then
                    gated = gated + 1
                    _G.print(("  |cffcdd6f4bag %d slot %d|r %s%s"):format(
                        bag, slot, _safeLeftText(lines[1].raw), _gateSuffix(lines)))
                end
            end
        end
    end
    _print(("bags: %d items scanned, %d carrying a UsageRequirement line"):format(scanned, gated))
end

-- MerchantItemInfo is the structured vendor-side state MerchantFrame itself uses
-- (MerchantFrame.lua:362 tints the button on `not info.isPurchasable`).
local function _merchantStateStr(slot)
    local ok, s = pcall(function()
        local info = _G.C_MerchantFrame.GetItemInfo(slot)
        if not info then return " (no MerchantItemInfo)" end
        return (" purchasable=%s usable=%s avail=%s extCost=%s"):format(
            tostring(info.isPurchasable), tostring(info.isUsable),
            tostring(info.numAvailable), tostring(info.hasExtendedCost))
    end)
    return ok and s or " (MerchantItemInfo threw)"
end

-- Sweep the OPEN merchant window. Bare = one summary row per slot; with a slot
-- number = every line of that slot in full.
local function _tipDumpMerchant(slotArg)
    local count = _G.GetMerchantNumItems() or 0   -- exception(boundary): nil with no merchant open
    if count == 0 then
        _print("merchant: no merchant open (walk to the vendor, then run this)")
        return
    end
    local first, last = 1, count
    if slotArg then first, last = slotArg, slotArg end
    _print(("merchant: %d slots%s"):format(count, slotArg and (", dumping slot " .. slotArg) or ""))
    for slot = first, last do
        local lines = _probeLines(function() return C_TooltipInfo.GetMerchantItem(slot) end)
        _G.print(("  |cffcdd6f4[%2d]|r %-40s %d lines%s%s"):format(
            slot, lines and lines[1] and _safeLeftText(lines[1].raw) or "?",
            lines and #lines or 0, _gateSuffix(lines), _merchantStateStr(slot)))
        if lines and (slotArg or #_gateNames(lines) > 0) then _printLines(lines) end
    end
end

-- ===== Rendered-vs-data dump ================================================
-- The only honest comparison: the SAME tooltip instance, read both ways --
-- the rendered FontStrings (what the player sees, Blizzard's own
-- TooltipUtil.DebugCopyGameTooltip path) beside GameTooltip:GetTooltipData()
-- (what addon code can read). Any line present in one and absent in the other
-- is the answer, and it is observed rather than inferred from a line count.

local _gtArmed, _gtSnapshot, _gtHooked = false, nil, false

local function _safeFontText(fs)
    local ok, shown = pcall(function()
        local text = fs:GetText()
        if text == nil then return "" end
        return (text:gsub("|", "||"))
    end)
    return ok and shown or "|cffe06c75<secret>|r"
end

-- Capture at Show: every Lua post-call (ours included) has already run by then,
-- so the FontStrings hold the finished tooltip.
local function _captureGameTooltip()
    if not _gtArmed or _gtSnapshot then return end   -- first tooltip after arming wins
    local gt = _G.GameTooltip
    local snap = { rendered = {}, data = nil }
    local ok = pcall(function()
        for i = 1, (gt:NumLines() or 0) do
            local l, r = _G["GameTooltipTextLeft" .. i], _G["GameTooltipTextRight" .. i]
            snap.rendered[i] = {
                left  = l and _safeFontText(l) or "",
                right = r and _safeFontText(r) or "",
            }
        end
        snap.data = gt:GetTooltipData()
    end)
    if not ok or #snap.rendered == 0 then return end
    _gtSnapshot = snap
end

local function _printSnapshotRendered(snap)
    _G.print(("  |cff98c379RENDERED (%d lines -- what you see)|r"):format(#snap.rendered))
    for i, l in ipairs(snap.rendered) do
        _G.print(("   [%2d] %s%s"):format(i, l.left,
            l.right ~= "" and (" |cff888888// " .. l.right .. "|r") or ""))
    end
end

local function _printSnapshotData(snap)
    local lines = _probeLines(function() return snap.data end)
    _G.print(("  |cff98c379TOOLTIPDATA (%d lines -- what addon code can read)|r")
        :format(lines and #lines or 0))
    if lines then _printLines(lines) end
end

local function _tipDumpGameTooltip()
    if not _gtHooked then
        hooksecurefunc(_G.GameTooltip, "Show", _captureGameTooltip)
        _gtHooked = true
    end
    if not _gtArmed then
        _gtArmed, _gtSnapshot = true, nil
        _print("gt ARMED -- hover the thing you want dumped (the FIRST tooltip is captured),")
        _G.print("      then run |cffcdd6f4/hdgr tipdump gt|r again to print it.")
        return
    end
    _gtArmed = false
    if not _gtSnapshot then
        _print("gt: nothing captured (no tooltip shown while armed)")
        return
    end
    _print("gt: same tooltip, both ways --")
    _printSnapshotRendered(_gtSnapshot)
    _printSnapshotData(_gtSnapshot)
end

-- Dump C_TooltipInfo line types. Bare = the Brawl'gar set + a control; "bags" =
-- control sweep of carried items; "merchant [slot]" = the open vendor;
-- "gt" = arm, hover, re-run to compare rendered vs data on one tooltip.
function D:TipDump(rest)
    rest = rest or ""
    local mode = rest:match("^%s*(%a+)")
    if mode == "bags" then return _tipDumpBags() end
    if mode == "gt" then return _tipDumpGameTooltip() end
    if mode == "merchant" then return _tipDumpMerchant(tonumber(rest:match("%d+"))) end
    local ids = {}
    for s in rest:gmatch("%d+") do ids[#ids + 1] = tonumber(s) end
    if #ids == 0 then
        ids = TIPDUMP_DEFAULT_IDS
        _print("tipdump (no ids) -- 3 Brawl'gar rank-gated items + 1 plain gold control")
    end
    for _, id in ipairs(ids) do _tipDumpOne(id) end
end

-- ===== petscale: does the legacy Model frame know the world scale? ===========
-- Chasing the ~73 species whose mesh measures absurdly tall (Merriment 28.143 on
-- a creature that stands ankle-high beside a 2.242 player). Eleven candidates
-- eliminated -- see the RESIDUAL section in vpp-tools/build_sizedb.py.
--
-- THIS probe tries the one surface never looked at: the LEGACY Model frame. All
-- the earlier work went through ModelScene, the modern API. SimpleModel carries
-- two getters ModelScene has no equivalent for:
--
--     Model:GetWorldScale()   -- and there is NO SetWorldScale
--     Model:GetModelScale()
--
-- A getter with no matching setter is engine-computed, not a value we handed it,
-- which is exactly the shape of the number we are missing. Paired with
-- CharacterModelBase:SetDisplayInfo(displayID) it can be asked per species.
--
-- If GetWorldScale returns ~0.025 for Merriment and ~1.0 for the hares, that is
-- the missing factor and it is readable at runtime -- which would mean shipping
-- the raw mesh extent and multiplying by this instead of guessing at DB2 columns.
local PETSCALE_PROBE = {
    -- sid, what we currently ship (nil = dropped as implausible), the DB2 CMS
    { sid = 4733, ship = "dropped", cms = 1.00 },  -- Merriment      mesh 28.143
    { sid = 2591, ship = "dropped", cms = 1.00 },  -- Happiness      mesh 28.143 (ShaPet)
    { sid = 2815, ship = "dropped", cms = 1.00 },  -- Rampage        mesh 20.306 (GorillaBossDead)
    { sid = 3217, ship = "dropped", cms = 1.00 },  -- Aurelid Floater mesh 9.542
    { sid = 1364, ship = "0.795",   cms = 0.65 },  -- Murkalot       (MurlocCrusader, GeoBox-clamped)
    { sid =  730, ship = "0.289",   cms = 0.50 },  -- Tolai Hare Pup (correct)
    { sid =  641, ship = "0.578",   cms = 1.00 },  -- Arctic Hare    (correct)
    { sid =  441, ship = "0.722",   cms = 1.25 },  -- Alpine Hare    (correct)
    { sid = 4257, ship = "1.111",   cms = 0.70 },  -- Gill'dan       (correct)
}

local _petScaleModel
local _petScaleBusy = false

local function _petScaleFrame()
    if _petScaleModel then return _petScaleModel end
    local f = _G.CreateFrame("PlayerModel", nil, _G.UIParent)
    f:SetSize(200, 200)
    f:SetPoint("CENTER")
    _petScaleModel = f
    return f
end

-- Sequential with a settle delay: SetDisplayInfo loads asynchronously and the
-- legacy Model frame has no load callback, so the scale is not meaningful on the
-- same frame. A dev probe may use a timer; UI code may not.
local function _petScaleStep(f, i, acc, done)
    if i > #PETSCALE_PROBE then return done(acc) end
    local e = PETSCALE_PROBE[i]
    -- exception(false-positive): dev surface. PetObserver declares sole ownership of
    -- C_PetJournal for the PRODUCTION path; /hdg petscale is a probe that wants raw
    -- species data the observer deliberately does not expose, and adding an observer
    -- method for one debug command would be the worse trade.
    local info = _G.C_PetJournal.GetPetInfoTableBySpeciesID(e.sid)
    if not (info and info.displayID) then
        acc[i] = { name = ("sid %d (not owned)"):format(e.sid) }
        return _petScaleStep(f, i + 1, acc, done)
    end
    f:ClearModel()
    f:SetDisplayInfo(info.displayID)
    _G.C_Timer.After(0.35, function()
        acc[i] = {
            name  = info.name,
            sid   = e.sid,
            ship  = e.ship,
            cms   = e.cms,
            disp  = info.displayID,
            world = f.GetWorldScale and f:GetWorldScale() or nil,
            model = f.GetModelScale and f:GetModelScale() or nil,
            fid   = f.GetModelFileID and f:GetModelFileID() or nil,
        }
        _petScaleStep(f, i + 1, acc, done)
    end)
end

-- /hdgr petscale
function D:PetScale()
    if _petScaleBusy then return _print("petscale: already running") end
    if not _G.C_PetJournal then return _print("petscale: C_PetJournal unavailable") end
    _petScaleBusy = true
    local f = _petScaleFrame()
    f:Show()
    _petScaleStep(f, 1, {}, function(acc)
        local out = {
            "Model:GetWorldScale / GetModelScale per pet display.",
            "GetWorldScale has NO setter, so it is engine-computed -- if it varies",
            "with true pet size, it is the factor 11 other candidates did not explain.",
            "",
            "name                 sid  ships    DB2cms  worldScale  modelScale  displayID  fileID",
        }
        for _, r in ipairs(acc) do
            if r and r.sid then
                out[#out + 1] = ("%-18s %5d  %-8s %6.2f  %10s  %10s  %9s  %s"):format(
                    tostring(r.name), r.sid, r.ship, r.cms,
                    tostring(r.world), tostring(r.model), tostring(r.disp), tostring(r.fid))
            elseif r then
                out[#out + 1] = r.name
            end
        end
        out[#out + 1] = ""
        out[#out + 1] = "READ IT: the four 'dropped' rows are the unexplained ones. If their"
        out[#out + 1] = "worldScale is far below the hares' and Gill'dan's, we have the answer."
        local dialog = HDG.UI and HDG.UI.CopyDialog and HDG.UI:CopyDialog()
        if dialog and dialog.Open then dialog:Open("petscale", table.concat(out, "\n"))
        else for _, l in ipairs(out) do _print(l) end end
        -- Hide the probe model. It is a 200x200 PlayerModel anchored to the centre of
        -- UIParent, so leaving it shown parked the last probed pet over the world for
        -- the rest of the session with /reload the only cure.
        f:Hide()
        _petScaleBusy = false
    end)
end
