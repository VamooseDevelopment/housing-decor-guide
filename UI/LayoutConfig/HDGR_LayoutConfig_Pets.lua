-- HDGR_LayoutConfig_Pets.lua
-- ============================================================================
-- Pets browser: a top-filter MODE of the decor view, so it borrows that view's
-- `body` and `detail` cells rather than declaring a view of its own.
--
-- Sibling panels gated by `visible`, NOT a re-used scrollbox: `rowKind` is
-- consumed at build time to pick the row factory and the element extent, and each
-- scrollbox owns its own frame pool, so swapping the kind live would mean tearing
-- that pool down mid-paint. The decor body cell already holds four gated siblings
-- (decorPanel / Loading / Error / Blank); these are the fifth and sixth.

HDG = HDG or {}
local LC = HDG.LayoutConfig

-- ===== Panels ================================================================

LC.panels.petPanel = {
    kind = "panel",
    cell = { decor = "body" },
    visibleInViews = { "decor" },
    visible = "decor.showPetBrowser",
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- Blank overlay: pets mode with no matches (search or family narrowed to nothing).
-- Same body cell; showPetBrowser goes false at the same moment this goes true.
LC.panels.petBlankPanel = {
    kind = "panel",
    cell = { decor = "body" },
    visibleInViews = { "decor" },
    visible = "pets.isBlank",
}

LC.panels.petDetailPanel = {
    kind = "panel",
    cell = { decor = "detail" },
    visibleInViews = { "decor" },
    visible = "pets.isMode",
    slots = {
        header = {
            height = 34, layout = "horizontal", gap = "md",
            padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
            chrome = "PanelHeader",
        },
    },
}

-- ===== Sections ==============================================================

LC.sections["pets.body"] = {
    ["in"] = "petPanel", layout = "vertical", padding = "lg", gap = "sm", order = 10,
}
LC.sections["pets.list"] = {
    ["in"] = "pets.body", layout = "fill", order = 10, chrome = "inset",
}
LC.sections["pets.statusRail"] = {
    ["in"] = "pets.body", layout = "horizontal", height = 16, order = 20,
}
LC.sections["pets.detailBody"] = {
    ["in"] = "petDetailPanel", layout = "vertical", padding = "lg", gap = "md", order = 10,
}
-- 330h: stage 300 -- the SAME stage height as the Menagerie host -- plus the
-- scene strip. The card underneath affords it by running facts and flowchart
-- SIDE BY SIDE: four short fact lines were burning full-width rows in a 540px
-- panel (owner, 2026-08-25 -- "wasted space, don't take it from the preview").
LC.sections["pets.previewSlot"] = {
    ["in"] = "pets.detailBody", layout = "vertical", gap = "xs", height = 330, order = 10,
}
LC.sections["pets.detailCard"] = {
    ["in"]  = "pets.detailBody", layout = "vertical", padding = "md",
    gap = "sm", width = "fill", order = 20, chrome = "inset",
}
LC.sections["pets.cardCols"] = {
    ["in"] = "pets.detailCard", layout = "horizontal", gap = "md", height = 138, order = 18,
}
LC.sections["pets.cardFacts"] = {
    ["in"] = "pets.cardCols", layout = "vertical", gap = "xs", width = 220, order = 10,
}
LC.sections["pets.cardFlow"] = {
    ["in"] = "pets.cardCols", layout = "vertical", gap = "xs", width = "fill", order = 20,
}

-- ===== Widgets ===============================================================

LC.widgets["petPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "petPanel", slot = "header",
    text = "locale:PETS_BROWSER_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
}
LC.widgets["petPanel.headerSpacer"] = {
    tooltip = false, kind = "spacer", ["in"] = "petPanel", slot = "header",
    width = "fill", height = 14, order = 50,
}
LC.widgets["petPanel.list"] = {
    tooltip = false,
    kind = "scrollbox", ["in"] = "pets.list",
    binding = "pets.items",
    rowKind = "petRow",
    spacing = 1,
    selection = { deselectable = false },
    order = 10,
}
LC.widgets["petPanel.count"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "pets.statusRail",
    text = "", font = "small", justifyH = "LEFT",
    width = "fill", height = 14, order = 10,
    binding = "pets.headerLabel",
}
LC.widgets["petBlankPanel.icon"] = {
    tooltip = false,
    kind = "atlas", ["in"] = "petBlankPanel",
    atlas = HDG.Constants.BULLET_DOT_ATLAS, tone = "text.dim",
    width = 24, height = 24, order = 5,
}
LC.widgets["petBlankPanel.label"] = {
    tooltip = false,
    kind = "label", ["in"] = "petBlankPanel", role = "TextDim",
    text = "locale:PETS_BLANK",
    font = "body", justifyH = "CENTER",
    width = "fill", height = 22, order = 10,
}

-- Pets search sibling. The decor search box lives in the shared
-- decor.filterRowBottom section and its placeholder names decor, so pets gets its
-- own gated twin: one widget with two identities reads worse than two widgets with
-- one each. Both write the same transient, so the query survives a mode switch.
LC.widgets["petPanel.search"] = {
    tooltip = false,
    kind = "editbox", ["in"] = "decor.filterRowBottom", font = "body",
    height = 22, width = 240, order = 10,
    multiline = false,
    placeholder = "locale:PETS_SEARCH_PLACEHOLDER",
    binding = { text = "decor.filterQuery" },   -- same state as decorPanel.search
    visible = "pets.isMode",
}

-- ===== Detail pane ===========================================================
-- The SHARED CARD (ruling 9): the same stage / scene strip / facts / flowchart
-- the Menagerie shows, bound to this host's selection through the pets.* card
-- family. The old modelPreview large display is gone -- one component, two
-- hosts, one behaviour surface (ruling 10).

LC.widgets["petDetailPanel.title"] = {
    tooltip = false,
    kind = "label", ["in"] = "petDetailPanel", slot = "header",
    text = "locale:MENAGERIE_DETAIL_TITLE", font = "heading",
    height = 18, width = "auto", order = 10,
    binding = "pets.card.title",
}
LC.widgets["petDetailPanel.stage"] = {
    tooltip = false,
    kind = "petScene", ["in"] = "pets.previewSlot",
    binding = "pets.scene",
    width = "fill", height = 300, order = 10,
}
LC.widgets["petDetailPanel.sceneChips"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "pets.previewSlot",
    binding = "pets.sceneChips", cellKind = "menagerieChip",
    chipHeight = 20, order = 20, height = 24,
}
LC.widgets["petDetailPanel.family"] = {
    tooltip = false,
    kind = "label", ["in"] = "pets.cardFacts", font = "small",
    text = "", height = 14, order = 10,
    binding = "pets.card.family",
}
LC.widgets["petDetailPanel.howBig"] = {
    tooltip = false,
    kind = "label", ["in"] = "pets.cardFacts", font = "small", justifyH = "LEFT",
    text = "", width = "fill", height = 14, order = 12,
    binding = "pets.card.howBig",
}
LC.widgets["petDetailPanel.needs"] = {
    tooltip = false,
    kind = "label", ["in"] = "pets.cardFacts", font = "small", justifyH = "LEFT",
    text = "", width = "fill", height = 14, order = 14,
    binding = "pets.card.needs",
}
LC.widgets["petDetailPanel.light"] = {
    tooltip = false,
    kind = "label", role = "TextInfo", ["in"] = "pets.cardFacts", font = "small",
    justifyH = "LEFT", text = "", width = "fill", height = 14, order = 16,
    binding = "pets.card.light",
}
LC.widgets["petDetailPanel.flowHeader"] = {
    tooltip = false,
    kind = "label", ["in"] = "pets.cardFlow", font = "heading", justifyH = "LEFT",
    text = "locale:MENAGERIE_FLOW_HEADER", width = "fill", height = 18, order = 20,
}
LC.widgets["petDetailPanel.flow"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "pets.cardFlow",
    binding = "pets.flowChips", cellKind = "menagerieFlowNode",
    chipHeight = 34, order = 22, height = 72,
}
LC.widgets["petDetailPanel.also"] = {
    tooltip = false,
    kind = "chipStrip", ["in"] = "pets.cardFlow",
    binding = "pets.alsoChips", cellKind = "menagerieChip",
    chipHeight = 18, order = 24, height = 36,
}
-- Summon / Dismiss. ONE button whose label flips, matching VPP: two buttons would
-- mean one is always dead, and the state is binary. `enabled` is bound because the
-- client refuses a summon in a pet battle, on a vehicle or in a restricted area --
-- and the button widget fades a disabled control, so it reads at a glance.
LC.widgets["petDetailPanel.summonBtn"] = {
    tooltip = false,
    kind = "button", ["in"] = "pets.detailCard", font = "small",
    text = "locale:PETS_SUMMON", width = "auto", height = 22, order = 30, variant = "tertiary",
    binding = { text = "pets.summonLabel", enabled = "pets.summonEnabled" },
    visible = "pets.hasSelection",
}


