-- HDG.MenagerieController
-- ============================================================================
-- The Menagerie (House > Pets): thin glue. Every gesture is one UI_SET_TRANSIENT
-- (view="menagerie") -- zero feature actions by design. The one sanctioned
-- imperative moment lives here (plan section 6): playing a phase / voice on the
-- scene widget. Cell kinds for every chip strip and the menagerieRow factory
-- also live here, per house pattern.

HDG = HDG or {}
HDG.MenagerieController = HDG.MenagerieController or {}
local C = HDG.MenagerieController

local A = HDG.Constants.ACTIONS
local _voiceCycle = {}   -- per-voice click cycle (keyed by first kit id); session-local, not state

-- Sound-bar affordance: a thin accent line along the chip's bottom fills over
-- the clip's baked length (OGG durations from the sound pipeline; PlaySound
-- picks a random entry inside the kit, so the length is that kit's weighted
-- mean -- an affordance, not a promise). OnUpdate only runs WHILE playing.
local function _sndTick(chip)
    local frac = (GetTime() - chip._sndStart) / chip._sndDur
    if frac >= 1 then
        chip._sndFill:Hide()
        chip:SetScript("OnUpdate", nil)
        return
    end
    chip._sndFill:SetWidth(math.max(1, (chip:GetWidth() - 8) * frac))
end

local function _startSoundBar(chip, dur)
    if not chip._sndFill then
        local fill = chip:CreateTexture(nil, "OVERLAY")
        fill:SetColorTexture(1, 1, 1, 1)   -- white base; painted from the theme token per play (accentBar pattern)
        fill:SetHeight(2)
        fill:SetPoint("BOTTOMLEFT", 4, 2)
        chip._sndFill = fill
    end
    local accent = HDG.Theme:GetColor("semantic.accent")
    chip._sndFill:SetVertexColor(accent.r, accent.g, accent.b, 0.9)
    chip._sndFill:SetWidth(1)
    chip._sndFill:Show()
    chip._sndStart, chip._sndDur = GetTime(), dur
    chip:SetScript("OnUpdate", _sndTick)
end

local function _stopSoundBar(chip)
    if chip._sndFill then chip._sndFill:Hide() end
    chip:SetScript("OnUpdate", nil)
end

local function _set(key, value)
    HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
        payload = { view = "menagerie", key = key, value = value } })
end

local function _ui()
    return HDG.Store:GetState().session.ui.menagerie  -- exception(false-positive): top-level controller read, not a row factory
end

-- Resolved at CLICK time, not Wire time: the card has two hosts and the active
-- view names whose stage this click drives. HDG.UI:PetStage is the one answer.
local function _stage() return HDG.UI:PetStage() end

-- ===== chip cell kind: every plain chip strip ===============================
-- One kind serves axes / axis values / kind suggestions / scene strip / also --
-- the item's fields say which dispatch it is.
-- Every chip stream stamps its own `group`, so this dispatches on ONE field.
-- It used to fall through a chain of shape guesses -- "a string value with no
-- count that equals one of four axis names" -- which is a rule about what the
-- data happens to look like rather than what it IS, and it broke the moment a
-- value collided.
local function _chipClick(item)
    local g = item.group
    if g == "axis" then
        _set("axis", item.value); _set("axval", "all")

    elseif g == "axval" then
        _set("axval", item.value)

    elseif g == "suggest" then
        -- Fill the box with the picked kind rather than inventing a second
        -- filter concept: search already matches kind, so one control owns the
        -- narrowing and the text always says what the list is doing.
        _set("search", item.value)
        if C._searchBox then
            C._searchBox:SetText(item.value)
            C._searchBox:ClearFocus()
            if C._searchBox._hdgrPlaceholderRefresh then C._searchBox._hdgrPlaceholderRefresh() end
            if C._searchBox._hdgrSearchRefresh then C._searchBox._hdgrSearchRefresh() end
        end

    elseif g == "scene" then
        local scene = _ui().scene
        if item.value == "you" then
            _set("scene", { decorID = scene.decorID, withYou = not scene.withYou })
        else
            _set("scene", { decorID = item.value ~= "none" and item.value or nil,
                            withYou = scene.withYou })
        end

    elseif g == "also" then                       -- play, not state
        local stage = _stage()
        if stage then stage:PlayPhase(item.animID, 0) end
    end
end

local function _chipLabel(item)
    if item.count then return (item.label or "?") .. " (" .. item.count .. ")" end
    return item.label or "?"
end

HDG.ChipStrip:RegisterCellKind("menagerieChip", {
    constructor = function(parent, cfg)
        return HDG.ChipStrip:DefaultChipConstructor(parent, cfg)
    end,
    binder = function(chip, item, cfg)
        if not item then chip:Hide(); chip:SetScript("OnClick", nil); return end
        HDG.UI:EnsureChipChrome(chip)
        chip:Show()
        chip:SetText(_chipLabel(item))
        HDG.Theme:Register(chip, "Button", { variant = "chip", active = item.active == true })
        chip:RegisterForClicks("LeftButtonUp")
        chip:SetScript("OnClick", function() _chipClick(item) end)
    end,
    sizer = function(item, cfg)
        return HDG.ChipStrip:DefaultChipSizer({ label = _chipLabel(item) }, cfg)
    end,
})

-- ===== flow node cell kind ==================================================
-- The behaviour flowchart's nodes (ruling 10): "label  NN% - N.Ns" for phases,
-- "word -- cadence" for the voice. Unverified labels carry the amber "?".
-- Clicking a phase drives the scene actor; clicking the voice plays a kit.
local function _flowLabel(item)
    if item.nodeType == "voice" then
        local txt = "Sounds -- " .. item.cadence
        -- sharedWith counts the OTHER species on this voice. Zero is a voice of
        -- its own and says nothing; anything above it is the surprise -- your
        -- bunny borrowed a crab's throat.
        local n = item.sharedWith
        if n == 1 then return txt .. ", shared with 1 other" end
        if n > 1 then return txt .. ", shared with " .. n .. " others" end
        return txt
    end
    local txt = string.format("%s  %d%% - %.1fs", item.label, item.pct or 0, item.seconds or 0)
    if item.unverified then txt = txt .. " ?" end
    return txt
end

HDG.ChipStrip:RegisterCellKind("menagerieFlowNode", {
    constructor = function(parent, cfg)
        return HDG.ChipStrip:DefaultChipConstructor(parent, cfg)
    end,
    binder = function(chip, item, cfg)
        _stopSoundBar(chip)   -- pooled: a bar mid-fill must not survive a rebind
        if not item then chip:Hide(); chip:SetScript("OnClick", nil); return end
        HDG.UI:EnsureChipChrome(chip)
        chip:Show()
        chip:SetText(_flowLabel(item))
        HDG.Theme:Register(chip, "Button",
            { variant = "chip", active = item.nodeType == "voice" })
        chip:RegisterForClicks("LeftButtonUp")
        chip:SetScript("OnClick", function()
            if item.nodeType == "voice" then
                -- Imperative moment: playing is not state. The kit set is
                -- sorted, so a fixed kits[1] was often the ambient LOOP -- near
                -- silent as a one-shot. Cycle instead: every click plays the
                -- NEXT sound in the pet's set.
                if item.kits and #item.kits > 0 then
                    local key = item.kits[1]
                    local i = (_voiceCycle[key] or 0) % #item.kits + 1
                    _voiceCycle[key] = i
                    -- PlaySound IS C_Sound.PlaySound (Blizzard_SharedXML/Mainline/
                    -- Sound.lua: `PlaySound = C_Sound.PlaySound`), whose contract is
                    -- `success, handle = PlaySound(kitID, ...)`. It REPORTS a kit it
                    -- would not play; it does not raise. The pcall that used to wrap
                    -- this caught an error that cannot happen and discarded the one
                    -- signal worth having -- so a refused kit still drew a bar
                    -- filling over silence. Every voice in the DB carries one
                    -- duration per kit (513/513, verified), so durs[i] is a strict read.
                    local played = PlaySound(item.kits[i])
                    local dur = item.durs[i]
                    if played and dur > 0 then _startSoundBar(chip, dur) end
                end
            else
                local stage = _stage()
                if stage then stage:PlayPhase(item.animID, item.variation)
                elseif HDG.Store:GetState().account.config.debug then
                    _G.print("[HDG petscene] flow-node click: stage widget NOT FOUND (mainFrame=" .. tostring(HDG.mainFrame ~= nil) .. ")")
                end
            end
        end)
    end,
    sizer = function(item, cfg)
        return HDG.ChipStrip:DefaultChipSizer({ label = _flowLabel(item) }, cfg)
    end,
})

-- ===== menagerieRow =========================================================
-- Name + kind ONLY (ruling 13: scale lives in the scene, not on rows).
local function _layoutMenagerieRow(row)
    local name = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(name, "body")
    name:SetPoint("LEFT", 6, 0)
    name:SetJustifyH("LEFT")
    HDG.Theme:Register(name, "Text")
    row._nameFs = name

    local kind = row:CreateFontString(nil, "OVERLAY")
    HDG.UI.applyFontRole(kind, "small")
    kind:SetPoint("RIGHT", -6, 0)
    kind:SetJustifyH("RIGHT")
    HDG.Theme:Register(kind, "TextInfo")
    row._kindFs = kind

    name:SetPoint("RIGHT", kind, "LEFT", -8, 0)
end

local function _paintMenagerieRow(row, ed)
    row._nameFs:SetText(ed.displayName)
    -- Under the Room axis the row says how well it fits BEFORE what it is: that
    -- is the question the room asked. Every other axis shows the kind alone.
    row._kindFs:SetText(ed.fit and (ed.fit .. "  " .. ed.kindLabel) or ed.kindLabel)
    row._speciesID = ed.speciesID
end

local function _wireMenagerieRowClicks(row, ed)
    local speciesID = ed.speciesID
    row:SetScript("OnClick", function()
        HDG.Store:Dispatch({ type = A.UI_SET_TRANSIENT,
            payload = { view = "menagerie", key = "selectedSpeciesID", value = speciesID } })
    end)
end

local function _resetMenagerieRow(row)
    row._speciesID = nil
end

HDG.Rows:Register("menagerieRow", {
    font    = "body",
    height  = 22,
    key     = function(ed) return "sp" .. ed.speciesID end,
    factory = HDG.UI.MakeRowFactory({
        layout     = _layoutMenagerieRow,
        paint      = _paintMenagerieRow,
        laidOutTag = "_menagerieLaidOut",
        selectable = true,
        clicks     = "LeftButtonUp",
        wire       = _wireMenagerieRowClicks,
        resetText  = { "_nameFs", "_kindFs" },
        reset      = _resetMenagerieRow,
    }),
})

-- ===== Wire =================================================================
-- Nothing is wired at Wire() time. The rootFrame handed in here proved to be a
-- DIFFERENT frame whose .widgets never held these ids (the same discovery that
-- moved _stage onto HDG.mainFrame), so anything looked up from it silently
-- returns nil and the handler is never attached. Wiring is LAZY against
-- HDG.mainFrame on first Refresh instead, where the widget table is populated.
local LAZY = {
    -- Selection highlight is owned by the list's SelectionBehaviorMixin and
    -- re-applied from the Store after any re-push; the rows selector no longer
    -- bakes it (2026-09-13 allocation audit), so without this a search or a
    -- pets tick would drop the highlight. Same wiring as the Decor list.
    list = { id = "menagerieListPanel.list", attach = function(w)
        if w.WireStoreSelectionSync then
            w:WireStoreSelectionSync("session.ui.menagerie.selectedSpeciesID",
                function(ed, id) return id ~= nil and ed.speciesID == id end)
        end
    end },
    search = { id = "menagerieListPanel.search", attach = function(w)
        local function set(text)
            HDG.ControllerHelpers.Mechanics.SetUITransientView("menagerie", "search", text)
        end
        C._searchBox = w          -- a suggestion click writes the picked kind back into it
        HDG.UI.WireTextChanged(w, set)
        -- The clear "x" calls SetText(""), which fires OnTextChanged WITHOUT
        -- userInput -- so the guarded handler above ignores it and the state
        -- would keep the old needle while the box read empty. The x reports
        -- itself instead.
        w._hdgrOnClear = function() set("") end
    end },
}

function C:Wire(_rootFrame)
    -- Chips and rows wire themselves in their cell binders; the two frame-level
    -- widgets wire lazily below. Required by the Controllers registry contract.
end

function C:Refresh(_rootFrame, _ctx)
    if not HDG.mainFrame then return end   -- exception(boundary): no frame before first open
    self._wired = self._wired or {}
    for key, spec in pairs(LAZY) do
        if not self._wired[key] then
            local w = HDG.mainFrame.widgets[spec.id]   -- exception(nullable): not in this window's layout
            if w then
                spec.attach(w)
                self._wired[key] = true
            end
        end
    end
end

HDG.Controllers:Register("menagerie", C)
