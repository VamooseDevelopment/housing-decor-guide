-- HDGR_LayoutConfig_Menagerie.lua
-- ============================================================================
-- The Menagerie (House > Pets) -- its own view, a nav child under House beside
-- Blueprints. Spec rulings 9-14; plan HDGR_MENAGERIE_LATTICE_PLAN_2026-08-24.
--
-- Shape: list column (search, the two-row identity filter, the pet list) +
-- detail column (the scene with its strip, the four card facts, the behaviour
-- flowchart, the hidden Described block).
-- Behaviours render EXACTLY ONCE (ruling 10) -- the flowchart is the surface.

HDG = HDG or {}
local LC = HDG.LayoutConfig

LC.window.views.menagerie = {
    controllers = { "menagerie" },
    width    = "auto",
    height   = "auto",
    columns  = { 300, 540 },
    rows     = { 680 },
    cells    = {
        list   = { col = 1, row = 1, colSpan = 1, rowSpan = 1 },
        detail = { col = 2, row = 1, colSpan = 1, rowSpan = 1 },
    },
}

-- ===== Panels ================================================================

LC.panels.menagerieListPanel = {
    kind = "panel",
    cell = { menagerie = "list" },
    visibleInViews = { "menagerie" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

LC.panels.menagerieDetailPanel = {
    kind = "panel",
    cell = { menagerie = "detail" },
    visibleInViews = { "menagerie" },
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections: list column ================================================

LC.sections["menagerie.body"] = {
    ["in"] = "menagerieListPanel", layout = "vertical", padding = "lg", gap = "sm", order = 10,
}
-- The one control that reaches every pet, above the standing filter.
LC.sections["menagerie.searchRow"] = {
    ["in"] = "menagerie.body", layout = "vertical", order = 7, height = 26,
}

-- Kind suggestions, directly under the search box. Gated on having any, so the
-- row COLLAPSES when the box is empty -- hidden children are excluded from the
-- layout index, so the list keeps the height rather than staring at a gap.
LC.sections["menagerie.suggestRow"] = {
    ["in"] = "menagerie.body", layout = "vertical", order = 8,
    height = 56, chrome = "inset", padding = "sm",
    visible = "menagerie.hasKindSuggestions",
}

-- A hair of air between the suggestions and the Clade/Family/Size row. Without
-- it the two chip rows read as one block and the eye cannot tell which chips
-- belong to the typing and which are the standing filter.
LC.sections["menagerie.suggestGap"] = {
    ["in"] = "menagerie.body", layout = "vertical", order = 9, height = 6,
    visible = "menagerie.hasKindSuggestions",
}

-- The two-row identity filter: Clade / Family / Size, then that axis's values.
-- Height is MEASURED, not declared. ChipStrip is a FlowContainer: it wraps its
-- chips to the panel width and publishes the height it actually used
-- (`_intrinsicHeight` + HDG:RequestReflow, HDGR_ChipStrip.lua:148-160), and the
-- Layout engine resolves `height = "auto"` from exactly that intrinsic
-- (HDGR_Layout.lua:126). So the strip asks for the room it needs and this
-- section sums its children with `height = "content"`.
--
-- It was a fixed number until 2026-08-27 and went stale twice in one day: at 140
-- it was sized for 5 rows of clade chips, and splitting arachnid off insect made
-- 6 -- so Void drew on top of the pet list. Bumping it to fit 23 room chips then
-- spent a third of a 680px column on chips that the Size axis (four of them)
-- does not need. A measured height is tall for Room, short for Size, and cannot
-- drift when a room, a clade or a translated label changes.
LC.sections["menagerie.byPetFilters"] = {
    ["in"] = "menagerie.body", layout = "vertical", gap = "xs", order = 10, height = "content",
}
LC.sections["menagerie.list"] = {
    ["in"] = "menagerie.body", layout = "fill", order = 20, chrome = "inset",
}
LC.sections["menagerie.statusRail"] = {
    ["in"] = "menagerie.body", layout = "horizontal", height = 16, order = 30,
}

-- ===== Sections: detail column ==============================================

LC.sections["menagerie.detailBody"] = {
    ["in"] = "menagerieDetailPanel", layout = "vertical", padding = "lg", gap = "sm", order = 10,
}
LC.sections["menagerie.stageSlot"] = {
    ["in"] = "menagerie.detailBody", layout = "vertical", height = 300, order = 10, chrome = "inset",
}
LC.sections["menagerie.sceneStrip"] = {
    ["in"] = "menagerie.detailBody", layout = "vertical", order = 20, height = 28,
}
LC.sections["menagerie.facts"] = {
    ["in"] = "menagerie.detailBody", layout = "vertical", gap = "xs", order = 30, chrome = "inset",
    padding = "md", height = 96,
}
LC.sections["menagerie.flowBlock"] = {
    ["in"] = "menagerie.detailBody", layout = "vertical", gap = "xs", order = 40,
}
LC.sections["menagerie.describedBlock"] = {
    ["in"] = "menagerie.detailBody", layout = "vertical", order = 50,
    visible = "menagerie.hasDescription",   -- ruling: Described ships HIDDEN in v1
}

-- ===== Widgets: list column =================================================

LC.widgets["menagerieListPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "menagerieListPanel", slot = "header",
    text = "locale:MENAGERIE_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["menagerieListPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "menagerieListPanel", slot = "header",
    width = "fill", height = 14, order = 50,
}
-- Reaches the kind tail a chip row cannot: 712 kinds, 509 of them with four pets
-- or fewer. Matches the pet's name AND its kind, and the row shows the kind, so
-- the thing you can read is the thing you can type.
LC.widgets["menagerieListPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "menagerie.searchRow", font = "body",
    height = 22, width = "fill", order = 10,
    multiline = false, search = true,
    placeholder = "locale:MENAGERIE_SEARCH_PLACEHOLDER",
}

LC.widgets["menagerieListPanel.suggest"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "menagerie.suggestRow",
    binding = "menagerie.kindSuggestions", cellKind = "menagerieChip",
    chipHeight = 20, order = 10, height = 44,   -- two rows: long kind names wrap
    visible = "menagerie.hasKindSuggestions",
}

LC.widgets["menagerieListPanel.axes"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "menagerie.byPetFilters",
    binding = "menagerie.axes", cellKind = "menagerieChip",
    chipHeight = 20, order = 10, height = 24,
}
LC.widgets["menagerieListPanel.axisValues"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "menagerie.byPetFilters",
    binding = "menagerie.axisValues", cellKind = "menagerieChip",
    chipHeight = 20, order = 20, height = "auto",   -- as many rows as it wraps to
}
LC.widgets["menagerieListPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "menagerie.list",
    binding = "menagerie.items",
    rowKind = "menagerieRow",
    spacing = 1,
    selection = { deselectable = false },
    order = 10,
}
LC.widgets["menagerieListPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "menagerie.statusRail",
    text = "", font = "small", justifyH = "LEFT",
    width = "fill", height = 14, order = 10,
    binding = "menagerie.headerLabel",
}

-- ===== Widgets: detail column ===============================================

LC.widgets["menagerieDetailPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "menagerieDetailPanel", slot = "header",
    text = "locale:MENAGERIE_DETAIL_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "menagerie.card.title",
}
LC.widgets["menagerieDetailPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "menagerieDetailPanel", slot = "header",
    width = "fill", height = 14, order = 40,
}
LC.widgets["menagerieDetailPanel.family"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "menagerieDetailPanel", slot = "header",
    text = "", font = "small", justifyH = "RIGHT",
    height = 14, width = "auto", order = 50,
    binding = "menagerie.card.family",
}
LC.widgets["menagerieDetailPanel.stage"] = {
    tooltip = false,
    kind = "petScene", ["in"] = "menagerie.stageSlot",
    binding = "menagerie.scene",
    width = "fill", height = 300, order = 10,
}
LC.widgets["menagerieDetailPanel.sceneChips"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "menagerie.sceneStrip",
    binding = "menagerie.sceneChips", cellKind = "menagerieChip",
    chipHeight = 20, order = 10, height = 24,
}
-- The four card facts (ruling 10 shrank the grid to these).
LC.widgets["menagerieDetailPanel.howBig"] = {
    tooltip = false,
    kind = "label", ["in"] = "menagerie.facts", font = "body", justifyH = "LEFT",
    text = "", width = "fill", height = 16, order = 10,
    binding = "menagerie.card.howBig",
}
LC.widgets["menagerieDetailPanel.needs"] = {
    tooltip = false,
    kind = "label", ["in"] = "menagerie.facts", font = "body", justifyH = "LEFT",
    text = "", width = "fill", height = 16, order = 20,
    binding = "menagerie.card.needs",
}
LC.widgets["menagerieDetailPanel.matches"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "menagerie.facts", font = "body",
    justifyH = "LEFT", text = "", width = "fill", height = 16, order = 30,
    binding = "menagerie.card.matches",
}
LC.widgets["menagerieDetailPanel.light"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "menagerie.facts", font = "body",
    justifyH = "LEFT", text = "", width = "fill", height = 16, order = 40,
    binding = "menagerie.card.light",
}
LC.widgets["menagerieDetailPanel.flowHeader"] = {
    tooltip = false,
    kind = "label", ["in"] = "menagerie.flowBlock", font = "heading", justifyH = "LEFT",
    text = "locale:MENAGERIE_FLOW_HEADER", width = "fill", height = 18, order = 10,
}
LC.widgets["menagerieDetailPanel.flow"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "menagerie.flowBlock",
    binding = "menagerie.flowChips", cellKind = "menagerieFlowNode",
    chipHeight = 34, order = 20, height = 72,
}
LC.widgets["menagerieDetailPanel.also"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "menagerie.flowBlock",
    binding = "menagerie.alsoChips", cellKind = "menagerieChip",
    chipHeight = 18, order = 30, height = 36,
}
-- Described: hidden until a description DB exists (v1 ruling); no layout change
-- needed to light it up.
LC.widgets["menagerieDetailPanel.described"] = {
    tooltip = false,
    kind = "label", role = "TextDim", ["in"] = "menagerie.describedBlock",
    font = "body", justifyH = "LEFT", text = "",
    width = "fill", height = 40, order = 10,
}
