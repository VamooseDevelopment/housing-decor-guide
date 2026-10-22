-- HDGR_LayoutConfig_Removalist.lua
-- Removalist -- plot-move orientation planner (Projects sub-view).
-- Pick a source + target plot -> each map auto-zooms to it -> the Move panel reads
-- out how far your house & landscaping rotate. Full design: docs/REMOVALIST_DESIGN.md.
--
-- View: removalist (in-window; reached from the Projects hub in NAV_TREE)
--   columns: { 140 list | 280 source | 280 target | 220 info }
--   rows:    { 340 maps  | 150 facing diagrams }
--   cells:   list (rowSpan 2) | srcMap / tgtMap (row 1) | srcDiag / tgtDiag (row 2) | info (rowSpan 2)

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== View =================================================================

LC.window.views.removalist = {
    controllers = { "removalist" },
    width    = "auto",
    height   = "auto",
    columns  = { 140, 280, 280, 240 },   -- list trimmed ("Plot N" is short); maps wide; info column holds the key text
    rows     = { 340, 150 },
    cells = {
        list    = { col = 1, row = 1, colSpan = 1, rowSpan = 2 },
        srcMap  = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
        tgtMap  = { col = 3, row = 1, colSpan = 1, rowSpan = 1 },
        srcDiag = { col = 2, row = 2, colSpan = 1, rowSpan = 1 },
        tgtDiag = { col = 3, row = 2, colSpan = 1, rowSpan = 1 },
        info    = { col = 4, row = 1, colSpan = 1, rowSpan = 2 },
    },
}

-- ===== Panels ===============================================================
-- All six panels are real: list (faction dropdown + scrollbox), source/target maps
-- (removalistMap, auto-zoom), source/target facing (removalistFacing), and the Move
-- & Orientation result. Each binds to a removalist.* selector.

-- Source/Target facing panels: PanelHeader title + a fill body holding the custom
-- "removalistFacing" widget (registered in HDGR_Controller_Removalist), bound to
-- removalist.source/targetFacing -- draws the picked plot's pad rect + arrows.
local function _facingPanel(key, cellName, title, modelSelector)
    LC.panels[key] = {
        kind = "panel",
        cell = { removalist = cellName },
        visibleInViews = { "removalist" },
        slots = {
            header = {
                height = 28, layout = "horizontal", gap = "sm",
                padding = { top = 0, right = "md", bottom = 0, left = "md" },
                chrome = "PanelHeader",
            },
        },
    }
    LC.sections[key .. ".body"] = {
        ["in"] = key, layout = "fill", height = "fill", order = 20,
    }
    LC.widgets[key .. ".title"] = {
        tooltip = false, kind = "label", role = "TextHeading",
        ["in"] = key, slot = "header",
        text = title, font = "heading", height = 16, width = "auto", order = 10,
    }
    LC.widgets[key .. ".facing"] = {
        tooltip = false, kind = "removalistFacing", ["in"] = key .. ".body",
        binding = { model = modelSelector },
        width = "fill", height = "fill", order = 10,
    }
end

_facingPanel("removalistSrcDiagPanel", "srcDiag", "Source Facing", "removalist.sourceFacing")
_facingPanel("removalistTgtDiagPanel", "tgtDiag", "Target Facing", "removalist.targetFacing")

-- ===== List panel (Phase 1) -- faction dropdown + plot scrollbox ============
-- Hand-built (not a _scaffoldPanel placeholder): a single Alliance/Horde dropdown
-- fills the header (no separate title), and a fill body section holds the plot
-- scrollbox bound to removalist.plotListRows. The dropdown dispatches the faction
-- via its declarative setTransient shortcut -- no controller wiring.

LC.panels.removalistListPanel = {
    kind = "panel",
    cell = { removalist = "list" },
    visibleInViews = { "removalist" },
    slots = {
        header = {
            height = 30, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "sm", bottom = 0, left = "sm" },
            chrome = "PanelHeader",
        },
    },
}

-- Colour-coded A/B/C/D filter strip + refresh, between the faction dropdown and the list.
LC.sections["removalistListPanel.filter"] = {
    ["in"] = "removalistListPanel", layout = "fill", height = 28, order = 10,
    padding = { top = "xs", right = "sm", bottom = "xs", left = "sm" },
}
LC.widgets["removalistListPanel.letterStrip"] = {
    tooltip = false, kind = "removalistLetterStrip", ["in"] = "removalistListPanel.filter",
    binding = { active = "removalist.letterFilter" },
    width = "fill", height = 20, order = 10,
}

LC.sections["removalistListPanel.body"] = {
    ["in"] = "removalistListPanel", layout = "fill", height = "fill",
    order = 20, chrome = "inset",
}

LC.widgets["removalistListPanel.factionDropdown"] = {
    tooltip = false,
    kind = "dropdown", ["in"] = "removalistListPanel", slot = "header",
    width = "fill", height = 25, order = 10,
    placeholder     = "locale:REMV_FACTION_PLACEHOLDER",
    binding      = { menu = "removalist.factionMenuItems", current = "removalist.faction" },
    setTransient = { view = "removalist", key = "faction" },
}
LC.widgets["removalistListPanel.list"] = {
    tooltip = false, kind = "scrollbox", ["in"] = "removalistListPanel.body",
    binding = "removalist.plotListRows", rowKind = "removalistPlotRow",
    spacing = 1, order = 10,
}

-- ===== Source / Target map panels (Phase 2) -- neighborhood map canvas =======
-- Each: PanelHeader title + a fill body holding the custom "removalistMap" widget
-- (registered in HDGR_Controller_Removalist), bound to removalist.mapModel (the
-- faction's neighborhood uiMap; RenderMap tiles it via HDG.MapRenderer). Both
-- share the model for now -- they split (zoom-to-plot) once selection lands.

local function _mapPanel(key, cellName, title, modelSelector, plotTitleSelector)
    LC.panels[key] = {
        kind = "panel",
        cell = { removalist = cellName },
        visibleInViews = { "removalist" },
        slots = {
            header = {
                height = 28, layout = "horizontal", gap = "sm",
                padding = { top = 0, right = "md", bottom = 0, left = "md" },
                chrome = "PanelHeader",
            },
        },
    }
    LC.sections[key .. ".body"] = {
        ["in"] = key, layout = "fill", height = "fill", order = 20,
    }
    LC.widgets[key .. ".title"] = {
        tooltip = false, kind = "label", role = "TextHeading",
        ["in"] = key, slot = "header",
        text = title, font = "heading", height = 16, width = "auto", order = 10,
    }
    -- Fill spacer right-pushes the picked plot's "Plot N (L)" (tinted to the blip).
    LC.widgets[key .. ".hsp"] = {
        tooltip = false, kind = "spacer", ["in"] = key, slot = "header",
        width = "fill", height = 1, order = 15,
    }
    LC.widgets[key .. ".plot"] = {
        tooltip = false, kind = "label", role = "Text",
        ["in"] = key, slot = "header",
        binding = { text = plotTitleSelector },
        font = "body", height = 16, width = "auto", justifyH = "RIGHT", order = 20,
    }
    LC.widgets[key .. ".canvas"] = {
        tooltip = false, kind = "removalistMap", ["in"] = key .. ".body",
        binding = { model = modelSelector },
        width = "fill", height = "fill", order = 10,
    }
end

_mapPanel("removalistSrcMapPanel", "srcMap", "Source Plot", "removalist.sourceMapModel", "removalist.sourcePlotTitle")
_mapPanel("removalistTgtMapPanel", "tgtMap", "Target Plot", "removalist.targetMapModel", "removalist.targetPlotTitle")

-- ===== Move & Orientation panel -- the rotation result =======================
-- Bound to removalist.rotationText (computed from source/target letters). The
-- community-key art + facing diagrams come later; this is the headline number.

LC.panels.removalistInfoPanel = {
    kind = "panel",
    cell = { removalist = "info" },
    visibleInViews = { "removalist" },
    slots = {
        header = {
            height = 28, layout = "horizontal", gap = "sm",
            padding = { top = 0, right = "md", bottom = 0, left = "md" },
            chrome = "PanelHeader",
        },
    },
}
LC.sections["removalistInfoPanel.body"] = {
    ["in"] = "removalistInfoPanel", layout = "vertical", padding = "lg", gap = "xs", order = 20, height = "fill",
}
LC.widgets["removalistInfoPanel.title"] = {
    tooltip = false, kind = "label", role = "TextHeading",
    ["in"] = "removalistInfoPanel", slot = "header",
    text = "locale:REMV_ORIENTATION_TITLE", font = "heading", height = 16, width = "auto", order = 10,
}

-- Swap / Clear action strip (panel content top, above the result).
LC.sections["removalistInfoPanel.actions"] = {
    ["in"] = "removalistInfoPanel", layout = "horizontal", gap = "sm",
    padding = { top = "md", right = "lg", bottom = 0, left = "lg" }, height = 24, order = 10,
}
LC.widgets["removalistInfoPanel.swapBtn"] = {
    tooltip = false, kind = "button", ["in"] = "removalistInfoPanel.actions",
    text = "locale:REMV_SWAP", width = "auto", height = 22, order = 10, variant = "tertiary", font = "small",
}
LC.widgets["removalistInfoPanel.clearBtn"] = {
    tooltip = false, kind = "button", ["in"] = "removalistInfoPanel.actions",
    text = "locale:COMMON_CLEAR", width = "auto", height = 22, order = 20, variant = "tertiary", font = "small",
}

-- Result card: chrome="cardBorder" = the card fill (surface.hover) + a 1px border, NO
-- accent stripe. Holds the big rotation number + direction + move pair. Each line binds a
-- removalist.resultCard* field (empty string in the idle states).
LC.sections["removalistInfoPanel.resultCard"] = {
    ["in"] = "removalistInfoPanel.body", layout = "vertical", chrome = "cardBorder",
    height = 140, gap = "xs",
    padding = { top = "md", right = "md", bottom = "md", left = "md" }, order = 10,
}
LC.widgets["removalistInfoPanel.resultLead"] = {
    tooltip = false, kind = "label", role = "TextDim", ["in"] = "removalistInfoPanel.resultCard",
    binding = { text = "removalist.resultCardLead" },
    font = "caption", width = "fill", height = 24, wrap = true, justifyH = "CENTER", order = 10,
}
LC.widgets["removalistInfoPanel.resultDegrees"] = {
    tooltip = false, kind = "label", role = "TextDim", ["in"] = "removalistInfoPanel.resultCard",
    binding = { text = "removalist.resultCardDegrees" },
    font = "heading", width = "fill", height = 26, wrap = true, justifyH = "CENTER", order = 20,
}
LC.widgets["removalistInfoPanel.resultDirection"] = {
    tooltip = false, kind = "label", role = "Text", ["in"] = "removalistInfoPanel.resultCard",
    binding = { text = "removalist.resultCardDirection" },
    font = "body", width = "fill", height = 30, wrap = true, justifyH = "CENTER", order = 30,
}
LC.widgets["removalistInfoPanel.resultPair"] = {
    tooltip = false, kind = "label", role = "TextDim", ["in"] = "removalistInfoPanel.resultCard",
    binding = { text = "removalist.resultCardPair" },
    font = "small", width = "fill", height = 32, wrap = true, justifyH = "CENTER", order = 40,
}
-- Community rotation key: small heading + the 2x2 A/B/C/D chip grid (custom widget).
LC.widgets["removalistInfoPanel.keyHeading"] = {
    tooltip = false, kind = "label", role = "TextDim",
    ["in"] = "removalistInfoPanel.body",
    text = "locale:REMV_ROTATION_KEY_HEADING", font = "caption", height = 14, width = "fill", order = 20,
}
LC.widgets["removalistInfoPanel.keyGrid"] = {
    tooltip = false, kind = "removalistRotationKey",
    ["in"] = "removalistInfoPanel.body",
    width = "fill", height = 72, order = 30,
}
-- The "how a move reads" notes under the chips (re-added at the user's request).
LC.widgets["removalistInfoPanel.keyNotes"] = {
    tooltip = false, kind = "label", role = "Text",
    ["in"] = "removalistInfoPanel.body",
    binding = { text = "removalist.rotationNotes" },
    font = "caption", width = "fill", height = 148, wrap = true, justifyV = "TOP", order = 35,
}
-- Fill spacer pushes the credit to the very bottom of the column.
LC.widgets["removalistInfoPanel.keySpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "removalistInfoPanel.body",
    width = "fill", height = "fill", order = 40,
}
LC.widgets["removalistInfoPanel.credit"] = {
    tooltip = false, kind = "label", role = "Text",
    ["in"] = "removalistInfoPanel.body",
    -- "Blue" tinted to her Discord name colour (inline |c -- a specific person's colour, not a theme token).
    text = "locale:REMV_CREDIT", font = "caption", height = 16, width = "fill", wrap = true, order = 50,
}
