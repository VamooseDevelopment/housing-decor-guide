-- HDG Scheme Constants
--
-- The composer takes a flat palette (~30 colors) and assembles the full
-- nested scheme (surface / border / text / semantic / button / chip /
-- pin / region / fonts / metrics / atlas). Each theme is therefore just
-- a palette table -- one source of truth for the colors, shared shape
-- for everything else.
--
-- Themes:
--   ColorblindSafe   - WCAG AA, deuteranopia/protanopia/tritanopia safe
--   Mocha            - Catppuccin Mocha (the dark default)
--   TokyonightNight  - Tokyonight Night (the original)
--   RosePineMain     - Rose Pine main (the dark default)
--   GruvboxDarkHard  - Gruvbox dark + hard contrast
--
-- Add a theme: a palette builder in Palettes + its name in HDGR_SchemeMeta.order.
-- Switch at runtime: HDG.Theme:LoadScheme("Mocha").
--
-- Access via Theme APIs:
--   HDG.Theme:GetColor("button.primary.bg.hover")
--   HDG.Theme:GetFont("heading")
--   HDG.Theme:GetMetric("spacing.md")

local function rgba(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end  -- exception(boundary): palette factory optional alpha arg
local function withAlpha(c, a) return { r = c.r, g = c.g, b = c.b, a = a } end

-- Parse "#RRGGBB" (or "#RRGGBBAA") to an rgba table. Lets palette tables
-- mirror the hex strings published by upstream themes -- easier to verify
-- against the source. Hard-errors on malformed input rather than letting
-- a tonumber-failure cascade into `{r=nil}` and a paint-time crash.
local function hex(s, a)
    if type(s) ~= "string" or s:sub(1, 1) ~= "#" or (#s ~= 7 and #s ~= 9) then
        error(("hex(): expected \"#RRGGBB\" or \"#RRGGBBAA\", got %q"):format(tostring(s)), 2)
    end
    local r = tonumber(s:sub(2, 3), 16)
    local g = tonumber(s:sub(4, 5), 16)
    local b = tonumber(s:sub(6, 7), 16)
    if not (r and g and b) then
        error(("hex(): non-hex digits in %q"):format(s), 2)
    end
    if a == nil and #s == 9 then
        a = tonumber(s:sub(8, 9), 16)
        if not a then error(("hex(): non-hex alpha in %q"):format(s), 2) end
        a = a / 255
    end
    return { r = r / 255, g = g / 255, b = b / 255, a = a or 1 }  -- exception(boundary): palette factory optional alpha arg
end

-- Fonts are shared across all themes. We use Blizzard's per-locale STANDARD_TEXT_FONT
-- as the base so we render every glyph the client can. Hardcoding "Fonts\FRIZQT__.TTF"
-- is a LATIN-ONLY file and shows tofu boxes wherever the client points its standard
-- font at a different file (verified against Blizzard_Fonts_Shared/GameFonts.xml):
--   ruRU -> Fonts\FRIZQT___CYR.TTF (Cyrillic -- FRIZQT__ has NO Cyrillic, despite the name)
--   koKR -> 2002.TTF   zhCN -> ARKai_T.ttf   zhTW -> blei00d.TTF   (CJK)
-- On enUS + every Latin locale STANDARD_TEXT_FONT IS Fonts\FRIZQT__.TTF, so the look is
-- unchanged there, and the FRIZQT family (incl. its _CYR sibling) keeps typography
-- unified. (STANDARD_TEXT_FONT is set by Blizzard_Fonts_Shared, before addons load.)
local _baseFont = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"  -- exception(boundary): Blizzard global; FRIZQT fallback if somehow unset
local FONT_HEADING = _baseFont
local FONT_BODY    = _baseFont
local FONT_SMALL   = _baseFont

local DEFAULT_FONTS = {
    heading      = { file = FONT_HEADING, size = 16, flags = "" },
    subheading   = { file = FONT_HEADING, size = 13, flags = "" },
    body         = { file = FONT_BODY,    size = 12, flags = "" },
    body_strong  = { file = FONT_BODY,    size = 12, flags = "OUTLINE" },
    small        = { file = FONT_SMALL,   size = 11, flags = "" },
    caption      = { file = FONT_SMALL,   size = 10, flags = "" },
    button       = { file = FONT_BODY,    size = 12, flags = "" },
    numeric      = { file = FONT_BODY,    size = 12, flags = "" },
}

local DEFAULT_METRICS = {
    radius    = { sm = 2, md = 4, lg = 6 },
    spacing   = {
        xs = 2, sm = 4, md = 6, lg = 8, xl = 10, xxl = 12, huge = 20,
    },
    elevation = { panel = 1, popup = 2, modal = 3 },
}

local DEFAULT_ATLAS = {
    checkmark   = "common-icon-checkmark",
    close       = "communities-icon-redx",
    housingDeed = "housing-map-deed",
}

-- BuildScheme: take a flat palette (~30 named colors) + return a nested
-- scheme matching what Theme.Skinners + LayoutConfig + selectors expect.
-- The shape of the OUTPUT is the contract; the shape of the INPUT is
-- "give me values for every name in PALETTE_KEYS." Missing values error.
local PALETTE_KEYS = {
    -- Surfaces (darkest -> lightest, 7 steps)
    "sunken", "bg", "panel_soft", "panel", "panel_footer", "panel_header", "raised",
    -- Border
    "border",
    -- Text
    "text", "text_header", "text_label", "text_dim", "text_disabled", "text_inverse",
    -- Buttons (default neutral chrome)
    "button_normal", "button_hover", "button_active", "button_disabled",
    -- Semantic (4 channels: accent / success / warning / error)
    "accent", "accent_brighter", "accent_darker",
    "success", "warning", "error", "error_deep",
    -- UI tokens: mined from each scheme's canonical Neovim highlight groups
    -- (TabLineSel, PmenuSel, StatusLine, NormalFloat, DiagnosticError/Warn/Info/Hint).
    -- Lets Skinners pick scheme-canonical colors instead of mechanical blends.
    "tab_active_bg", "tab_active_text",
    "popup_selected_bg", "popup_selected_text",
    "statusline_bg",
    "text_on_accent",
    "float_bg", "float_border",
    "diag_error", "diag_warn", "diag_info", "diag_hint",
}
-- accent_hover removed: surface.hover (accent + 12% alpha) covers hover treatment;
-- selected-row paint comes from RowChrome. Re-add if a Skinner needs "hover-on-selected".

local function BuildScheme(palette)
    -- Validate every key is present. Missing one is a bug; loud error
    -- beats silent nil during paint.
    for _, key in ipairs(PALETTE_KEYS) do
        if palette[key] == nil then
            error(("BuildScheme: palette missing required key %q"):format(key), 2)
        end
    end
    local C = palette

    return {
        -- Propagated so skinners can branch on it (e.g. StatusRail uses panel_footer on light).
        isLight = palette.isLight,
        surface = {
            canvas       = C.bg,
            panel        = C.panel,
            panel_header = C.panel_header,
            panel_footer = C.panel_footer,
            panel_soft   = C.panel_soft,
            raised       = C.raised,
            sunken       = C.sunken,
            hover        = withAlpha(C.accent, 0.12),
            selected     = withAlpha(C.accent, 0.18),
            overlay      = withAlpha(C.bg,     0.60),
            divider      = withAlpha(C.border, 0.55),
            statusline   = C.statusline_bg,   -- Neovim StatusLine.bg
        },

        border = {
            default      = C.border,
            subtle       = withAlpha(C.border, 0.55),
            strong       = C.text_dim,
            focus        = C.accent,
            selected     = withAlpha(C.accent, 0.95),
        },

        text = {
            primary      = C.text,
            heading      = C.text_header,
            subheading   = C.text_dim,
            muted        = C.text_label,
            dim          = C.text_dim,
            disabled     = C.text_disabled,
            -- text.link / text.link_hover: button label colors (links = buttons in WoW UX).
            -- Separate from semantic.accent so a scheme can remap button color independently.
            link         = C.text_link       or C.accent,
            link_hover   = C.text_link_hover or C.accent_brighter,
            -- collected = normal body text (owned rows blend into the list);
            -- uncollected = accent (actionable emphasis). Strict reads: both alias
            -- required tokens; nil must fail loud, not silently resolve.
            collected    = C.text,
            uncollected  = C.accent,
            inverse      = C.text_inverse,
            numeric      = C.warning,
            -- "text on accent chrome" token. Use wherever text sits over
            -- semantic.accent or tab.active.bg (text.inverse breaks on dark schemes).
            on_accent    = C.text_on_accent,
            -- Drop-shadow tokens for headline FontStrings. Always dark (works on all schemes).
            -- TextShadow Skinner reads .shadow + .shadowOffset.
            shadow       = rgba(0, 0, 0, 0.70),
            shadowOffset = { x = 1, y = -1 },
        },

        semantic = {
            accent       = C.accent,
            success      = C.success,
            warning      = C.warning,
            error        = C.error,
            error_deep   = C.error_deep,   -- danger-deep red; Theme TEXT_STATE "error_deep" + Constants.ErrorDeep map here
        },

        -- ===== UI namespaces =====
        -- Tabs: tab.active.bg / tab.active.text -- scheme-canonical active look.
        tab = {
            active = { bg = C.tab_active_bg, text = C.tab_active_text },
        },

        popup = {
            selected = { bg = C.popup_selected_bg, text = C.popup_selected_text },
        },

        float = {
            bg     = C.float_bg,
            border = C.float_border,
        },

        -- NOTE: diag.warn != semantic.warning on some schemes (e.g. Nord uses purple for
        -- diag.warn). Use diag.* for scheme-canonical states, semantic.* for portable colors.
        diag = {
            error = C.diag_error,
            warn  = C.diag_warn,
            info  = C.diag_info,
            hint  = C.diag_hint,
        },

        button = {
            default = {
                bg     = { normal = C.button_normal, hover = C.button_hover, active = C.button_active, disabled = C.button_disabled },
                -- Routed through link tokens (single SSoT for button text across variants).
                text   = { normal   = C.text_link       or C.accent,
                           hover    = C.text_link_hover or C.accent_brighter,
                           disabled = C.text_disabled },
                border = { normal = C.border, hover = withAlpha(C.accent, 0.50), focus = C.accent },
            },
            primary = {
                bg     = { normal = C.accent, hover = C.accent_brighter, active = C.accent_darker, disabled = withAlpha(C.accent, 0.40) },
                text   = { normal = C.text_inverse, hover = C.text_inverse, disabled = C.text_disabled },
                border = { normal = C.accent, hover = C.accent_brighter, focus = C.text_inverse },
            },
            danger = {
                bg     = { normal = C.error_deep, hover = C.error, active = C.error_deep, disabled = withAlpha(C.error_deep, 0.40) },
                text   = { normal = C.text_inverse, hover = C.text_inverse, disabled = C.text_disabled },
                border = { normal = C.error, hover = C.accent_brighter, focus = C.text_inverse },
            },
            ghost = {
                bg     = { normal = rgba(0, 0, 0, 0), hover = withAlpha(C.accent, 0.10), active = withAlpha(C.accent, 0.18), disabled = rgba(0, 0, 0, 0) },
                text   = { normal = C.text, hover = C.accent, disabled = C.text_disabled },
                border = { normal = rgba(0, 0, 0, 0), hover = withAlpha(C.accent, 0.45), focus = C.accent },
            },
            tertiary = {
                atlas = {
                    normal   = "common-button-tertiary-normal",
                    hover    = "common-button-tertiary-hover",
                    pressed  = "common-button-tertiary-pressed",
                    disabled = "common-button-tertiary-disabled",
                },
                -- Routed through link tokens (single SSoT for button text).
                text = {
                    normal   = C.text_link       or C.accent,
                    hover    = C.text_link_hover or C.accent_brighter,
                    disabled = C.text_disabled,
                },
            },
        },

        chip = {
            default = { bg = C.panel_header, border = withAlpha(C.border, 0.65), text = C.text_dim, icon = C.text_dim },
            new     = { bg = withAlpha(C.warning, 0.18), border = C.warning, text = C.warning, icon = C.warning },
            atlas   = { bg = C.panel_header, border = withAlpha(C.border, 0.65), text = C.text_label, icon = C.text_label },
        },

        pin = {
            default  = { fill = C.accent, border = C.text_inverse },
            selected = { fill = C.accent, border = C.text_inverse, glow = withAlpha(C.accent, 0.65) },
            applied  = { fill = C.success, border = C.text_inverse, glow = withAlpha(C.success, 0.55) },
            done     = { fill = C.text_dim, border = C.border },
            invalid  = { fill = C.error, border = C.text_inverse },
        },

        region = {
            a = withAlpha(C.success, 0.22),
            b = withAlpha(C.accent,  0.20),
            c = withAlpha(C.warning, 0.12),
        },

        fonts   = palette.fonts   or DEFAULT_FONTS,
        metrics = palette.metrics or DEFAULT_METRICS,
        atlas   = palette.atlas   or DEFAULT_ATLAS,
        -- chrome: optional atlas-artwork table (housing wood/stone). Present
        -- only on the Housing scheme; nil elsewhere => the atlas-aware Skinners
        -- take the solid/watercolor path. No DEFAULT -- absence IS the signal.
        chrome  = palette.chrome,
        -- nativeButtons: build action buttons as native UIPanelButtonTemplate
        -- (BlizzardUI). nil elsewhere => HDG's hand-built dark-atlas buttons.
        nativeButtons = palette.nativeButtons,
    }
end

-- ===== Palettes =============================================================
--
-- Each palette is ~30 keys (the contract in PALETTE_KEYS above). Hex strings
-- mirror the upstream theme sources for direct comparison.
--
-- Mapping conventions:
--   sunken          -> deepest inset shade (crust / bg_dark / base / bg0_h)
--   bg              -> canvas / outer page (base / bg / base / bg0)
--   panel_soft      -> recessed card chrome (one step darker than panel)
--   panel           -> panel body (surface0 / bg_highlight / surface / bg1)
--   panel_footer    -> footer accent (one step lighter than panel)
--   panel_header    -> header accent
--   raised          -> button base (one step lighter than header)
--   accent          -> primary brand color (blue family in most themes)
--   accent_brighter -> hover state for accent
--   accent_darker   -> pressed / selected state
--   success         -> green channel
--   warning         -> yellow/amber channel
--   error           -> red/magenta channel
--   error_deep      -> darker red for danger button fills

local Palettes = {}

-- ----- ColorblindSafe (original HDG palette) -------------------------------
Palettes.ColorblindSafe = function() return {
    sunken          = hex("#0C1116"),
    bg              = hex("#101418", 0.95),
    panel_soft      = hex("#151D27"),
    panel           = hex("#182029"),
    panel_footer    = hex("#1E2934"),
    panel_header    = hex("#222C36"),
    raised          = hex("#32414D"),
    border          = hex("#46515D"),
    text            = hex("#F1F5F9"),
    text_header     = hex("#FFFFFF"),
    text_label      = hex("#AAB6C3"),
    text_dim        = hex("#7E8B99"),
    text_disabled   = hex("#5F6A75"),
    text_inverse    = hex("#FFFFFF"),
    button_normal   = hex("#32414D"),
    button_hover    = hex("#3C4C59"),
    button_active   = hex("#182029"),
    button_disabled = hex("#32414D", 0.40),
    accent          = hex("#4EA3F1"),                   -- accent blue
    accent_brighter = hex("#93C5FD"),
    accent_darker   = hex("#1D4F75"),
    success         = hex("#00A896"),                   -- teal
    warning         = hex("#F2C94C"),                   -- amber
    error           = hex("#D84C8B"),                   -- magenta
    error_deep      = hex("#8F2D59"),                   -- magenta-deep
    -- Link tokens drive button text in default/tertiary variants. For
    -- ColorblindSafe the inactive/active pair MUST cross the blue-orange
    -- axis (universally distinguishable: differs on BOTH red-green AND
    -- blue-yellow axes). Two shades of blue would collapse for tritanopia
    -- (~0.01% of users) AND read as near-identical on achromatopsia. Blue
    -- (inactive) -> warm orange (active) is the canonical CB-safe pair.
    text_link       = hex("#4EA3F1"),                   -- accent blue (inactive)
    text_link_hover = hex("#FFA552"),                   -- warm orange (active)
    -- UI tokens (ColorblindSafe -- HDG original, derived)
    tab_active_bg       = hex("#182029"),  -- panel
    tab_active_text     = hex("#F1F5F9"),  -- text
    popup_selected_bg   = hex("#3C4C59"),  -- button_hover
    popup_selected_text = hex("#F1F5F9"),  -- text
    statusline_bg       = hex("#1E2934"),  -- panel_footer
    text_on_accent      = hex("#0C1116"),  -- sunken (darkest)
    float_bg            = hex("#151D27"),  -- panel_soft
    float_border        = hex("#4EA3F1"),  -- accent
    diag_error          = hex("#D84C8B"),  -- error (magenta)
    diag_warn           = hex("#F2C94C"),  -- warning (amber)
    diag_info           = hex("#4EA3F1"),  -- accent (blue)
    diag_hint           = hex("#00A896"),  -- success (teal)
} end

-- ----- Catppuccin Mocha -----------------------------------------------------
-- Source: https://github.com/catppuccin/catppuccin#-palette
Palettes.Mocha = function() return {
    sunken          = hex("#11111b"),                   -- crust
    bg              = hex("#1e1e2e", 0.95),             -- base
    panel_soft      = hex("#181825"),                   -- mantle
    panel           = hex("#313244"),                   -- surface0
    panel_footer    = hex("#45475a"),                   -- surface1
    panel_header    = hex("#45475a"),                   -- surface1 (header reuses)
    raised          = hex("#585b70"),                   -- surface2
    border          = hex("#6c7086"),                   -- overlay0
    text            = hex("#cdd6f4"),                   -- text
    text_header     = hex("#cdd6f4"),                   -- text
    text_label      = hex("#bac2de"),                   -- subtext1
    text_dim        = hex("#a6adc8"),                   -- subtext0
    text_disabled   = hex("#6c7086"),                   -- overlay0
    text_inverse    = hex("#1e1e2e"),                   -- base
    button_normal   = hex("#45475a"),                   -- surface1
    button_hover    = hex("#585b70"),                   -- surface2
    button_active   = hex("#313244"),                   -- surface0
    button_disabled = hex("#45475a", 0.40),
    accent          = hex("#89b4fa"),                   -- blue
    accent_brighter = hex("#b4befe"),                   -- lavender
    accent_darker   = hex("#1e66f5"),                   -- darker blue
    success         = hex("#a6e3a1"),                   -- green
    warning         = hex("#f9e2af"),                   -- yellow
    error           = hex("#f38ba8"),                   -- red
    error_deep      = hex("#9d4060"),                   -- darker red
    -- UI tokens (Catppuccin nvim highlights)
    tab_active_bg       = hex("#1e1e2e"),  -- base (TabLineSel)
    tab_active_text     = hex("#cdd6f4"),  -- text
    popup_selected_bg   = hex("#313244"),  -- surface0 (PmenuSel)
    popup_selected_text = hex("#cdd6f4"),  -- text
    statusline_bg       = hex("#181825"),  -- mantle
    text_on_accent      = hex("#1e1e2e"),  -- base (darkest dark, on accent)
    float_bg            = hex("#181825"),  -- mantle
    float_border        = hex("#89b4fa"),  -- blue
    diag_error          = hex("#f38ba8"),  -- red
    diag_warn           = hex("#f9e2af"),  -- yellow
    diag_info           = hex("#89b4fa"),  -- blue
    diag_hint           = hex("#94e2d5"),  -- teal
} end

-- ----- Tokyonight Night ----------------------------------------------------
-- Source: https://github.com/folke/tokyonight.nvim (extras/lua/tokyonight_night.lua)
Palettes.TokyonightNight = function() return {
    sunken          = hex("#16161e"),                   -- bg_dark
    bg              = hex("#1a1b26", 0.95),             -- bg
    panel_soft      = hex("#1f2335"),                   -- bg + slight lift
    panel           = hex("#292e42"),                   -- bg_highlight
    panel_footer    = hex("#3b4261"),                   -- fg_gutter
    panel_header    = hex("#414868"),                   -- terminal_black
    raised          = hex("#545c7e"),                   -- dark3
    border          = hex("#3b4261"),                   -- fg_gutter
    text            = hex("#c0caf5"),                   -- fg
    text_header     = hex("#c0caf5"),                   -- fg
    text_label      = hex("#a9b1d6"),                   -- fg_dark
    text_dim        = hex("#737aa2"),                   -- dark5
    text_disabled   = hex("#565f89"),                   -- comment
    text_inverse    = hex("#1a1b26"),                   -- bg
    button_normal   = hex("#3b4261"),                   -- fg_gutter
    button_hover    = hex("#414868"),                   -- terminal_black
    button_active   = hex("#292e42"),                   -- bg_highlight
    button_disabled = hex("#3b4261", 0.40),
    accent          = hex("#7aa2f7"),                   -- blue
    accent_brighter = hex("#89ddff"),                   -- blue5
    accent_darker   = hex("#3d59a1"),                   -- blue0
    success         = hex("#9ece6a"),                   -- green
    warning         = hex("#e0af68"),                   -- yellow
    error           = hex("#f7768e"),                   -- red
    error_deep      = hex("#db4b4b"),                   -- red1
    -- UI tokens (TokyoNight nvim highlights)
    tab_active_bg       = hex("#7aa2f7"),  -- blue (TabLineSel) -- strong identity!
    tab_active_text     = hex("#0c0e14"),  -- black, dark on blue
    popup_selected_bg   = hex("#2f3549"),  -- fg_gutter blend (PmenuSel)
    popup_selected_text = hex("#c0caf5"),  -- fg
    statusline_bg       = hex("#16161e"),  -- bg_dark
    text_on_accent      = hex("#0c0e14"),  -- darkest bg
    float_bg            = hex("#1a1b26"),  -- bg
    float_border        = hex("#29a2c6"),  -- blue1 blended (cyan-tinted)
    diag_error          = hex("#db4b4b"),  -- red1
    diag_warn           = hex("#e0af68"),  -- yellow
    diag_info           = hex("#0db9d7"),  -- blue2
    diag_hint           = hex("#1abc9c"),  -- teal
} end

-- ----- Rose Pine Main -------------------------------------------------------
-- Source: https://github.com/rose-pine/rose-pine-theme (palette/main.md)
Palettes.RosePineMain = function() return {
    sunken          = hex("#191724"),                   -- base (darkest)
    bg              = hex("#1f1d2e", 0.95),             -- surface
    panel_soft      = hex("#21202e"),                   -- highlightLow
    panel           = hex("#26233a"),                   -- overlay
    panel_footer    = hex("#403d52"),                   -- highlightMed
    panel_header    = hex("#403d52"),                   -- highlightMed
    raised          = hex("#524f67"),                   -- highlightHigh
    border          = hex("#6e6a86"),                   -- muted
    text            = hex("#e0def4"),                   -- text
    text_header     = hex("#e0def4"),                   -- text
    text_label      = hex("#908caa"),                   -- subtle
    text_dim        = hex("#6e6a86"),                   -- muted
    text_disabled   = hex("#524f67"),                   -- highlightHigh
    text_inverse    = hex("#191724"),                   -- base
    button_normal   = hex("#403d52"),                   -- highlightMed
    button_hover    = hex("#524f67"),                   -- highlightHigh
    button_active   = hex("#26233a"),                   -- overlay
    button_disabled = hex("#403d52", 0.40),
    accent          = hex("#9ccfd8"),                   -- foam
    accent_brighter = hex("#ebbcba"),                   -- rose
    accent_darker   = hex("#31748f"),                   -- pine
    success         = hex("#31748f"),                   -- pine
    warning         = hex("#f6c177"),                   -- gold
    error           = hex("#eb6f92"),                   -- love
    error_deep      = hex("#9d4d68"),                   -- darker love
    -- UI tokens (Rose Pine nvim highlights)
    tab_active_bg       = hex("#26233a"),  -- overlay (TabLineSel)
    tab_active_text     = hex("#e0def4"),  -- text
    popup_selected_bg   = hex("#403d52"),  -- highlightMed (PmenuSel)
    popup_selected_text = hex("#e0def4"),  -- text
    statusline_bg       = hex("#1f1d2e"),  -- surface
    text_on_accent      = hex("#191724"),  -- base
    float_bg            = hex("#1f1d2e"),  -- surface
    float_border        = hex("#403d52"),  -- highlightMed (subtle)
    diag_error          = hex("#eb6f92"),  -- love
    diag_warn           = hex("#f6c177"),  -- gold
    diag_info           = hex("#9ccfd8"),  -- foam
    diag_hint           = hex("#c4a7e7"),  -- iris
} end

-- ----- Gruvbox Dark Hard ----------------------------------------------------
-- Source: https://github.com/morhetz/gruvbox (gruvbox-palettes.png)
Palettes.GruvboxDarkHard = function() return {
    sunken          = hex("#1d2021"),                   -- bg0_h (hard contrast)
    bg              = hex("#282828", 0.95),             -- bg0
    panel_soft      = hex("#32302f"),                   -- bg0_s
    panel           = hex("#3c3836"),                   -- bg1
    panel_footer    = hex("#504945"),                   -- bg2
    panel_header    = hex("#504945"),                   -- bg2
    raised          = hex("#665c54"),                   -- bg3
    border          = hex("#7c6f64"),                   -- bg4
    text            = hex("#ebdbb2"),                   -- fg1
    text_header     = hex("#fbf1c7"),                   -- fg0 (brightest)
    text_label      = hex("#d5c4a1"),                   -- fg2
    text_dim        = hex("#bdae93"),                   -- fg3
    text_disabled   = hex("#a89984"),                   -- fg4
    text_inverse    = hex("#282828"),                   -- bg0
    button_normal   = hex("#504945"),                   -- bg2
    button_hover    = hex("#665c54"),                   -- bg3
    button_active   = hex("#3c3836"),                   -- bg1
    button_disabled = hex("#504945", 0.40),
    accent          = hex("#83a598"),                   -- blue (gruvbox's "cool" tone)
    accent_brighter = hex("#8ec07c"),                   -- aqua
    accent_darker   = hex("#458588"),                   -- blue neutral
    success         = hex("#b8bb26"),                   -- green
    warning         = hex("#fabd2f"),                   -- yellow
    error           = hex("#fb4934"),                   -- red bright
    error_deep      = hex("#cc241d"),                   -- red neutral
    -- UI tokens (Gruvbox nvim highlights)
    tab_active_bg       = hex("#3c3836"),  -- bg1 (TabLineSel)
    tab_active_text     = hex("#b8bb26"),  -- green (the gruvbox active accent)
    popup_selected_bg   = hex("#83a598"),  -- blue (PmenuSel) -- inverted treatment
    popup_selected_text = hex("#504945"),  -- bg2 (dark on blue)
    statusline_bg       = hex("#504945"),  -- bg2
    text_on_accent      = hex("#1d2021"),  -- bg0_h (darkest)
    float_bg            = hex("#3c3836"),  -- bg1
    float_border        = hex("#83a598"),  -- accent fallback (gruvbox doesn't define)
    diag_error          = hex("#fb4934"),  -- red bright
    diag_warn           = hex("#fabd2f"),  -- yellow
    diag_info           = hex("#83a598"),  -- blue
    diag_hint           = hex("#8ec07c"),  -- aqua
} end

-- ----- Solarized Dark -------------------------------------------------------
-- Source: https://ethanschoonover.com/solarized/ (base03..base3 + accents)
Palettes.SolarizedDark = function() return {
    sunken          = hex("#002b36"),                   -- base03
    bg              = hex("#002b36", 0.95),             -- base03
    panel_soft      = hex("#03303a"),                   -- between base03/base02
    panel           = hex("#073642"),                   -- base02
    panel_footer    = hex("#0c4250"),                   -- midway up
    panel_header    = hex("#0c4250"),
    raised          = hex("#586e75"),                   -- base01
    border          = hex("#657b83"),                   -- base00
    text            = hex("#839496"),                   -- base0
    text_header     = hex("#93a1a1"),                   -- base1
    text_label      = hex("#839496"),                   -- base0
    text_dim        = hex("#657b83"),                   -- base00
    text_disabled   = hex("#586e75"),                   -- base01
    text_inverse    = hex("#002b36"),                   -- base03
    button_normal   = hex("#073642"),                   -- base02
    button_hover    = hex("#586e75"),                   -- base01
    button_active   = hex("#002b36"),                   -- base03
    button_disabled = hex("#073642", 0.40),
    accent          = hex("#268bd2"),                   -- blue
    accent_brighter = hex("#2aa198"),                   -- cyan
    accent_darker   = hex("#1a6090"),                   -- darker blue
    success         = hex("#859900"),                   -- green
    warning         = hex("#b58900"),                   -- yellow
    error           = hex("#dc322f"),                   -- red
    error_deep      = hex("#993b2d"),                   -- darker red
    -- UI tokens (Solarized canonical mappings)
    tab_active_bg       = hex("#002b36"),  -- base03 (TabLineSel)
    tab_active_text     = hex("#839496"),  -- base0
    popup_selected_bg   = hex("#657b83"),  -- base00 (PmenuSel)
    popup_selected_text = hex("#eee8d5"),  -- base2
    statusline_bg       = hex("#073642"),  -- base02
    text_on_accent      = hex("#002b36"),  -- base03
    float_bg            = hex("#073642"),  -- base02
    float_border        = hex("#93a1a1"),  -- base1
    diag_error          = hex("#dc322f"),  -- red
    diag_warn           = hex("#b58900"),  -- yellow
    diag_info           = hex("#2aa198"),  -- cyan
    diag_hint           = hex("#859900"),  -- green
} end

-- ----- Solarized Light ------------------------------------------------------
-- Source: https://ethanschoonover.com/solarized/ (light variant)
Palettes.SolarizedLight = function() return {
    isLight         = true,                             -- light-canvas theme
    -- Surface ramp: monotonic by lightness (sunken darkest
    -- -> raised lightest/base3) so the depth ramp holds on light schemes too.
    sunken          = hex("#d8cfb0"),                   -- deepest inset (window/wells)
    bg              = hex("#e1d9bf", 0.95),             -- canvas
    panel_soft      = hex("#e8e0c6"),                   -- even-zebra / recessed chrome
    panel           = hex("#efe8d2"),                   -- workhorse panel
    panel_footer    = hex("#f4eede"),                   -- band
    panel_header    = hex("#f4eede"),                   -- band
    raised          = hex("#fdf6e3"),                   -- base3, highest (cards/tiles/buttons)
    border          = hex("#839496"),                   -- base0
    text            = hex("#657b83"),                   -- base00
    text_header     = hex("#586e75"),                   -- base01
    text_label      = hex("#657b83"),                   -- base00
    text_dim        = hex("#839496"),                   -- base0
    text_disabled   = hex("#93a1a1"),                   -- base1
    text_inverse    = hex("#fdf6e3"),                   -- base3
    button_normal   = hex("#eee8d5"),                   -- base2
    button_hover    = hex("#dcd6bf"),
    button_active   = hex("#fdf6e3"),                   -- base3
    button_disabled = hex("#eee8d5", 0.40),
    accent          = hex("#268bd2"),                   -- blue
    accent_brighter = hex("#2aa198"),                   -- cyan
    accent_darker   = hex("#1a6090"),
    success         = hex("#859900"),                   -- green
    warning         = hex("#b58900"),                   -- yellow
    error           = hex("#dc322f"),                   -- red
    error_deep      = hex("#993b2d"),
    -- UI tokens (Solarized Light -- inverted from Dark)
    tab_active_bg       = hex("#fdf6e3"),  -- base3
    tab_active_text     = hex("#586e75"),  -- base01
    popup_selected_bg   = hex("#93a1a1"),  -- base1
    popup_selected_text = hex("#073642"),  -- base02 (dark text)
    statusline_bg       = hex("#eee8d5"),  -- base2
    text_on_accent      = hex("#fdf6e3"),  -- base3 (LIGHT on accent -- light scheme)
    float_bg            = hex("#eee8d5"),  -- base2
    float_border        = hex("#586e75"),  -- base01
    diag_error          = hex("#dc322f"),  -- red
    diag_warn           = hex("#b58900"),  -- yellow
    diag_info           = hex("#2aa198"),  -- cyan
    diag_hint           = hex("#859900"),  -- green
} end

-- ----- Gruvbox Light Hard ---------------------------------------------------
-- Source: https://github.com/morhetz/gruvbox (gruvbox-palettes.png light side)
Palettes.GruvboxLightHard = function() return {
    isLight         = true,                             -- light-canvas theme
    -- Surface ramp: monotonic by lightness (sunken darkest
    -- -> raised lightest) -- Gruvbox bg ramp reordered + interpolated.
    sunken          = hex("#d5c4a1"),                   -- bg2 (deepest inset)
    bg              = hex("#e3d4ad", 0.95),             -- canvas (bg2->bg1)
    panel_soft      = hex("#ebdbb2"),                   -- bg1
    panel           = hex("#f2e5bc"),                   -- bg0_s
    panel_footer    = hex("#f6edca"),                   -- band (bg0_s->bg0)
    panel_header    = hex("#f6edca"),                   -- band
    raised          = hex("#f9f5d7"),                   -- bg0_h, highest
    border          = hex("#a89984"),                   -- bg4
    text            = hex("#3c3836"),                   -- fg1
    text_header     = hex("#282828"),                   -- fg0 (darkest)
    text_label      = hex("#504945"),                   -- fg2
    text_dim        = hex("#665c54"),                   -- fg3
    text_disabled   = hex("#7c6f64"),                   -- fg4
    text_inverse    = hex("#fbf1c7"),                   -- bg0
    button_normal   = hex("#d5c4a1"),                   -- bg2
    button_hover    = hex("#bdae93"),                   -- bg3
    button_active   = hex("#ebdbb2"),                   -- bg1
    button_disabled = hex("#d5c4a1", 0.40),
    accent          = hex("#076678"),                   -- blue (light)
    accent_brighter = hex("#427b58"),                   -- aqua (light)
    accent_darker   = hex("#054a55"),
    success         = hex("#79740e"),                   -- green (light)
    warning         = hex("#b57614"),                   -- yellow (light)
    error           = hex("#9d0006"),                   -- red (light)
    error_deep      = hex("#6b0004"),
    -- UI tokens (Gruvbox Light -- inverted from Dark)
    tab_active_bg       = hex("#ebdbb2"),  -- bg1 (light)
    tab_active_text     = hex("#79740e"),  -- green
    popup_selected_bg   = hex("#076678"),  -- blue (PmenuSel)
    popup_selected_text = hex("#fbf1c7"),  -- bg0
    statusline_bg       = hex("#d5c4a1"),  -- bg2
    text_on_accent      = hex("#fbf1c7"),  -- bg0
    float_bg            = hex("#ebdbb2"),  -- bg1
    float_border        = hex("#076678"),  -- accent fallback
    diag_error          = hex("#9d0006"),  -- red
    diag_warn           = hex("#b57614"),  -- yellow
    diag_info           = hex("#076678"),  -- blue
    diag_hint           = hex("#427b58"),  -- aqua
} end

-- ----- Everforest Dark (Medium contrast) ------------------------------------
-- Source: https://github.com/sainnhe/everforest (palette/dark medium)
Palettes.EverforestDark = function() return {
    sunken          = hex("#272e33"),                   -- bg_dim
    bg              = hex("#2d353b", 0.95),             -- bg0
    panel_soft      = hex("#343f44"),                   -- bg1
    panel           = hex("#3d484d"),                   -- bg2
    panel_footer    = hex("#475258"),                   -- bg3
    panel_header    = hex("#4f585e"),                   -- bg4
    raised          = hex("#56635f"),                   -- bg5
    border          = hex("#7a8478"),                   -- grey0
    text            = hex("#d3c6aa"),                   -- fg
    text_header     = hex("#d3c6aa"),                   -- fg
    text_label      = hex("#9da9a0"),                   -- grey2
    text_dim        = hex("#859289"),                   -- grey1
    text_disabled   = hex("#7a8478"),                   -- grey0
    text_inverse    = hex("#2d353b"),                   -- bg0
    button_normal   = hex("#475258"),                   -- bg3
    button_hover    = hex("#56635f"),                   -- bg5
    button_active   = hex("#3d484d"),                   -- bg2
    button_disabled = hex("#475258", 0.40),
    accent          = hex("#7fbbb3"),                   -- blue
    accent_brighter = hex("#83c092"),                   -- aqua
    accent_darker   = hex("#5a8a83"),
    success         = hex("#a7c080"),                   -- green
    warning         = hex("#dbbc7f"),                   -- yellow
    error           = hex("#e67e80"),                   -- red
    error_deep      = hex("#a64e51"),
    -- UI tokens (Everforest nvim highlights)
    tab_active_bg       = hex("#a7c080"),  -- green (statusline1 -- TabLineSel)
    tab_active_text     = hex("#272e33"),  -- bg_dim (dark on green)
    popup_selected_bg   = hex("#7fbbb3"),  -- blue (PmenuSel)
    popup_selected_text = hex("#272e33"),  -- bg_dim
    statusline_bg       = hex("#3d484d"),  -- bg2
    text_on_accent      = hex("#272e33"),  -- bg_dim
    float_bg            = hex("#272e33"),  -- bg_dim (hard variant)
    float_border        = hex("#859289"),  -- grey1
    diag_error          = hex("#e67e80"),  -- red
    diag_warn           = hex("#dbbc7f"),  -- yellow
    diag_info           = hex("#7fbbb3"),  -- blue
    diag_hint           = hex("#d699b6"),  -- purple
} end

-- ----- Everforest Light (Medium contrast) -----------------------------------
-- Source: https://github.com/sainnhe/everforest (palette/light medium)
Palettes.EverforestLight = function() return {
    isLight         = true,                             -- light-canvas theme
    -- Surface ramp: monotonic by lightness (sunken darkest
    -- -> raised lightest/bg0) -- Everforest bg ramp reordered + interpolated.
    sunken          = hex("#d2cfb6"),                   -- deepest inset (bg4->bg5)
    bg              = hex("#ddd9c2", 0.95),             -- canvas
    panel_soft      = hex("#e6e2cc"),                   -- bg3
    panel           = hex("#efebd4"),                   -- bg2
    panel_footer    = hex("#f4f0d9"),                   -- bg1 band
    panel_header    = hex("#f4f0d9"),                   -- band
    raised          = hex("#fdf6e3"),                   -- bg0, highest
    border          = hex("#a6b0a0"),                   -- grey0
    text            = hex("#5c6a72"),                   -- fg
    text_header     = hex("#4f585e"),                   -- darker fg
    text_label      = hex("#829181"),                   -- grey2
    text_dim        = hex("#939f91"),                   -- grey1
    text_disabled   = hex("#a6b0a0"),                   -- grey0
    text_inverse    = hex("#fdf6e3"),                   -- bg0
    button_normal   = hex("#e6e2cc"),                   -- bg3
    button_hover    = hex("#bdc3af"),                   -- bg5
    button_active   = hex("#efebd4"),                   -- bg2
    button_disabled = hex("#e6e2cc", 0.40),
    accent          = hex("#3a94c5"),                   -- blue
    accent_brighter = hex("#35a77c"),                   -- aqua
    accent_darker   = hex("#266a8b"),
    success         = hex("#8da101"),                   -- green
    warning         = hex("#dfa000"),                   -- yellow
    error           = hex("#f85552"),                   -- red
    error_deep      = hex("#b03b39"),
    -- UI tokens (Everforest Light)
    tab_active_bg       = hex("#8da101"),  -- green
    tab_active_text     = hex("#fdf6e3"),  -- bg0 (light)
    popup_selected_bg   = hex("#3a94c5"),  -- blue
    popup_selected_text = hex("#fdf6e3"),
    statusline_bg       = hex("#e6e2cc"),  -- bg3
    text_on_accent      = hex("#fdf6e3"),  -- LIGHT on accent (light scheme)
    float_bg            = hex("#efebd4"),  -- bg2
    float_border        = hex("#a6b0a0"),  -- grey0
    diag_error          = hex("#f85552"),
    diag_warn           = hex("#dfa000"),
    diag_info           = hex("#3a94c5"),
    diag_hint           = hex("#df69ba"),  -- purple light
} end

-- ----- Kanagawa Wave (dark default) -----------------------------------------
-- Source: https://github.com/rebelot/kanagawa.nvim (lua/kanagawa/colors.lua)
Palettes.KanagawaWave = function() return {
    sunken          = hex("#16161D"),                   -- sumiInk0
    bg              = hex("#1F1F28", 0.95),             -- sumiInk3 (default bg)
    panel_soft      = hex("#181820"),                   -- sumiInk1
    panel           = hex("#2A2A37"),                   -- sumiInk4
    panel_footer    = hex("#363646"),                   -- sumiInk5
    panel_header    = hex("#363646"),                   -- sumiInk5
    raised          = hex("#54546d"),                   -- sumiInk6
    border          = hex("#727169"),                   -- fujiGray
    text            = hex("#DCD7BA"),                   -- fujiWhite
    text_header     = hex("#DCD7BA"),                   -- fujiWhite
    text_label      = hex("#C8C093"),                   -- oldWhite
    text_dim        = hex("#727169"),                   -- fujiGray
    text_disabled   = hex("#54546d"),                   -- sumiInk6
    text_inverse    = hex("#1F1F28"),                   -- sumiInk3
    button_normal   = hex("#363646"),                   -- sumiInk5
    button_hover    = hex("#54546d"),                   -- sumiInk6
    button_active   = hex("#2A2A37"),                   -- sumiInk4
    button_disabled = hex("#363646", 0.40),
    accent          = hex("#7E9CD8"),                   -- crystalBlue
    accent_brighter = hex("#7FB4CA"),                   -- springBlue
    accent_darker   = hex("#658594"),                   -- dragonBlue
    success         = hex("#98BB6C"),                   -- springGreen
    warning         = hex("#E6C384"),                   -- carpYellow
    error           = hex("#E46876"),                   -- waveRed
    error_deep      = hex("#C34043"),                   -- autumnRed
    -- UI tokens (Kanagawa Wave nvim highlights)
    tab_active_bg       = hex("#2A2A37"),  -- sumiInk4 (TabLineSel)
    tab_active_text     = hex("#C8C093"),  -- oldWhite (fg_dim)
    popup_selected_bg   = hex("#2D4F67"),  -- waveBlue2 (PmenuSel)
    popup_selected_text = hex("#DCD7BA"),  -- fujiWhite
    statusline_bg       = hex("#16161D"),  -- sumiInk0 (darkest)
    text_on_accent      = hex("#1F1F28"),  -- sumiInk3
    float_bg            = hex("#16161D"),  -- sumiInk0
    float_border        = hex("#54546D"),  -- sumiInk6
    diag_error          = hex("#E82424"),  -- samuraiRed
    diag_warn           = hex("#FF9E3B"),  -- roninYellow
    diag_info           = hex("#658594"),  -- dragonBlue
    diag_hint           = hex("#6A9589"),  -- waveAqua1
} end

-- ----- Kanagawa Lotus (light variant) ---------------------------------------
-- Source: https://github.com/rebelot/kanagawa.nvim (lotus palette)
Palettes.KanagawaLotus = function() return {
    isLight         = true,                             -- light-canvas theme
    -- Surface ramp: monotonic by lightness (sunken darkest -> raised lightest/lotusWhite3);
    -- footer/header dropped the lotusViolet band to maintain monotonicity.
    sunken          = hex("#cdc69b"),                   -- deepest inset (below lotusWhite0/1)
    bg              = hex("#d7d0a4", 0.95),             -- canvas (~lotusWhite0)
    panel_soft      = hex("#e0d8ac"),                   -- lotusWhite0->2
    panel           = hex("#e5ddb0"),                   -- lotusWhite2
    panel_footer    = hex("#ece5b6"),                   -- band (->lotusWhite3)
    panel_header    = hex("#ece5b6"),                   -- band
    raised          = hex("#f2ecbc"),                   -- lotusWhite3, highest
    border          = hex("#8a8980"),                   -- lotusGray3
    text            = hex("#545464"),                   -- lotusInk1
    text_header     = hex("#43436c"),                   -- lotusInk2
    text_label      = hex("#716e61"),                   -- lotusGray2
    text_dim        = hex("#8a8980"),                   -- lotusGray3
    text_disabled   = hex("#a09cac"),                   -- lotusViolet1
    text_inverse    = hex("#f2ecbc"),                   -- lotusWhite3
    button_normal   = hex("#c9cbd1"),                   -- lotusViolet3
    button_hover    = hex("#a09cac"),                   -- lotusViolet1
    button_active   = hex("#d5c9a0"),                   -- lotusWhite1
    button_disabled = hex("#c9cbd1", 0.40),
    accent          = hex("#4d699b"),                   -- lotusBlue4
    accent_brighter = hex("#6693bf"),                   -- lotusTeal2
    accent_darker   = hex("#5d57a3"),                   -- lotusBlue5
    success         = hex("#6f894e"),                   -- lotusGreen
    warning         = hex("#cc6d00"),                   -- lotusOrange
    error           = hex("#c84053"),                   -- lotusRed
    error_deep      = hex("#e82424"),                   -- lotusRed3
    -- UI tokens (Kanagawa Lotus -- light variant, derived)
    tab_active_bg       = hex("#d5c9a0"),  -- lotusWhite1
    tab_active_text     = hex("#43436c"),
    popup_selected_bg   = hex("#c9cbd1"),  -- lotusViolet3
    popup_selected_text = hex("#43436c"),
    statusline_bg       = hex("#e4d794"),
    text_on_accent      = hex("#f2ecbc"),  -- lotusWhite3 (LIGHT, on accent)
    float_bg            = hex("#e4d794"),
    float_border        = hex("#a09cac"),  -- lotusViolet1
    diag_error          = hex("#c84053"),
    diag_warn           = hex("#cc6d00"),
    diag_info           = hex("#4d699b"),
    diag_hint           = hex("#6f894e"),
} end

-- ----- Nord -----------------------------------------------------------------
-- Source: https://www.nordtheme.com/docs/colors-and-palettes
Palettes.Nord = function() return {
    sunken          = hex("#2e3440"),                   -- nord0 (Polar Night)
    bg              = hex("#2e3440", 0.95),             -- nord0
    panel_soft      = hex("#3b4252"),                   -- nord1
    panel           = hex("#434c5e"),                   -- nord2
    panel_footer    = hex("#4c566a"),                   -- nord3
    panel_header    = hex("#4c566a"),                   -- nord3
    raised          = hex("#4c566a"),                   -- nord3
    border          = hex("#4c566a"),                   -- nord3
    text            = hex("#d8dee9"),                   -- nord4 (Snow Storm)
    text_header     = hex("#eceff4"),                   -- nord6
    text_label      = hex("#e5e9f0"),                   -- nord5
    text_dim        = hex("#d8dee9"),                   -- nord4
    text_disabled   = hex("#4c566a"),                   -- nord3
    text_inverse    = hex("#2e3440"),                   -- nord0
    button_normal   = hex("#434c5e"),                   -- nord2
    button_hover    = hex("#4c566a"),                   -- nord3
    button_active   = hex("#3b4252"),                   -- nord1
    button_disabled = hex("#434c5e", 0.40),
    accent          = hex("#88c0d0"),                   -- nord8 (Frost ice)
    accent_brighter = hex("#8fbcbb"),                   -- nord7 (Frost mint)
    accent_darker   = hex("#5e81ac"),                   -- nord10 (deep blue)
    success         = hex("#a3be8c"),                   -- nord14 (Aurora green)
    warning         = hex("#ebcb8b"),                   -- nord13 (Aurora yellow)
    error           = hex("#bf616a"),                   -- nord11 (Aurora red)
    error_deep      = hex("#8d4147"),
    -- UI tokens (Nord nvim highlights -- TabLine undefined; use accent)
    tab_active_bg       = hex("#5E81AC"),  -- nord10 (accent fallback)
    tab_active_text     = hex("#D8DEE9"),  -- nord4
    popup_selected_bg   = hex("#5E81AC"),  -- nord10 (PmenuSel blue)
    popup_selected_text = hex("#D8DEE9"),  -- nord4
    statusline_bg       = hex("#434C5E"),  -- nord2
    text_on_accent      = hex("#2E3440"),  -- nord0
    float_bg            = hex("#2E3440"),  -- nord0
    float_border        = hex("#D8DEE9"),  -- nord4 (Nord uses fg-on-fg border)
    diag_error          = hex("#BF616A"),  -- nord11
    diag_warn           = hex("#B48EAD"),  -- nord15 (PURPLE per Nord spec, NOT yellow)
    diag_info           = hex("#5E81AC"),  -- nord10
    diag_hint           = hex("#81A1C1"),  -- nord9
} end

-- ----- Dracula --------------------------------------------------------------
-- Source: https://draculatheme.com/contribute (official palette)
Palettes.Dracula = function() return {
    sunken          = hex("#1e1f29"),                   -- darker bg
    bg              = hex("#282a36", 0.95),             -- background
    panel_soft      = hex("#21222c"),
    panel           = hex("#383a47"),                   -- between bg and currentLine
    panel_footer    = hex("#44475a"),                   -- current line
    panel_header    = hex("#44475a"),                   -- current line
    raised          = hex("#6272a4"),                   -- comment
    border          = hex("#6272a4"),                   -- comment
    text            = hex("#f8f8f2"),                   -- foreground
    text_header     = hex("#f8f8f2"),                   -- foreground
    text_label      = hex("#bdbecf"),
    text_dim        = hex("#6272a4"),                   -- comment
    text_disabled   = hex("#44475a"),                   -- current line
    text_inverse    = hex("#282a36"),                   -- background
    button_normal   = hex("#44475a"),                   -- current line
    button_hover    = hex("#6272a4"),                   -- comment
    button_active   = hex("#383a47"),
    button_disabled = hex("#44475a", 0.40),
    accent          = hex("#bd93f9"),                   -- purple
    accent_brighter = hex("#ff79c6"),                   -- pink
    accent_darker   = hex("#8e6bc6"),
    success         = hex("#50fa7b"),                   -- green
    warning         = hex("#f1fa8c"),                   -- yellow
    error           = hex("#ff5555"),                   -- red
    error_deep      = hex("#c93333"),
    -- UI tokens (Dracula nvim highlights -- Mofiqul port)
    tab_active_bg       = hex("#282A36"),  -- bg (TabLineSel)
    tab_active_text     = hex("#F8F8F2"),  -- fg
    popup_selected_bg   = hex("#44475A"),  -- selection (PmenuSel)
    popup_selected_text = hex("#F8F8F2"),  -- fg
    statusline_bg       = hex("#44475A"),  -- selection
    text_on_accent      = hex("#191A21"),  -- black (darkest)
    float_bg            = hex("#282A36"),  -- bg
    float_border        = hex("#F8F8F2"),  -- fg (Dracula uses fg as border)
    diag_error          = hex("#FF5555"),  -- red
    diag_warn           = hex("#F1FA8C"),  -- yellow
    diag_info           = hex("#8BE9FD"),  -- cyan
    diag_hint           = hex("#8BE9FD"),  -- cyan (same as info per Mofiqul)
} end

-- ----- Nightfly -------------------------------------------------------------
-- Source: https://github.com/bluz71/vim-nightfly-colors (palette in plugin)
Palettes.Nightfly = function() return {
    sunken          = hex("#00111b"),                   -- shade (deeper)
    bg              = hex("#011627", 0.95),             -- main bg
    panel_soft      = hex("#01121f"),
    panel           = hex("#0e293f"),                   -- visual sel-ish
    panel_footer    = hex("#1d3b53"),                   -- regal blue (lighter bg)
    panel_header    = hex("#1d3b53"),                   -- regal blue
    raised          = hex("#2c3043"),
    border          = hex("#4b6479"),
    text            = hex("#c3ccdc"),                   -- bright text
    text_header     = hex("#fafafa"),                   -- white
    text_label      = hex("#a1aab8"),
    text_dim        = hex("#7c8f8f"),                   -- dim text
    text_disabled   = hex("#4b6479"),
    text_inverse    = hex("#011627"),                   -- bg
    button_normal   = hex("#1d3b53"),                   -- regal blue
    button_hover    = hex("#2c3043"),
    button_active   = hex("#0e293f"),
    button_disabled = hex("#1d3b53", 0.40),
    accent          = hex("#82aaff"),                   -- blue
    accent_brighter = hex("#7fdbca"),                   -- emerald/cyan
    accent_darker   = hex("#5fb0fc"),                   -- watery blue
    success         = hex("#a1cd5e"),                   -- spring green
    warning         = hex("#ecc48d"),                   -- macaroni yellow
    error           = hex("#ff5874"),                   -- watermelon
    error_deep      = hex("#c93f5a"),
    -- UI tokens (Nightfly nvim -- TabLine undefined; use accent)
    tab_active_bg       = hex("#82aaff"),  -- blue (accent fallback)
    tab_active_text     = hex("#c3ccdc"),  -- white
    popup_selected_bg   = hex("#316394"),  -- cyan_blue (PmenuSel)
    popup_selected_text = hex("#d6deeb"),  -- white_blue
    statusline_bg       = hex("#081e2f"),  -- black_blue
    text_on_accent      = hex("#011627"),  -- black (darkest)
    float_bg            = hex("#09243a"),  -- ink_blue
    float_border        = hex("#334e65"),  -- carbon_blue
    diag_error          = hex("#fc514e"),  -- red
    diag_warn           = hex("#e3d18a"),  -- yellow
    diag_info           = hex("#87bcff"),  -- malibu
    diag_hint           = hex("#7fdbca"),  -- turquoise
} end

-- ----- OneNord --------------------------------------------------------------
-- Source: https://github.com/rmehri01/onenord.nvim (Nord + One Dark blend)
Palettes.OneNord = function() return {
    sunken          = hex("#2a2e3a"),                   -- bg_dark
    bg              = hex("#2e3440", 0.95),             -- bg
    panel_soft      = hex("#2a2e3a"),
    panel           = hex("#3b4252"),                   -- bg_secondary
    panel_footer    = hex("#3e4452"),                   -- bg_visual
    panel_header    = hex("#434c5e"),
    raised          = hex("#4c566a"),                   -- selection
    border          = hex("#6c7a93"),                   -- comment
    text            = hex("#d8dee9"),                   -- fg
    text_header     = hex("#d8dee9"),
    text_label      = hex("#c8d0e0"),
    text_dim        = hex("#6c7a93"),                   -- comment
    text_disabled   = hex("#4c566a"),
    text_inverse    = hex("#2e3440"),
    button_normal   = hex("#3b4252"),
    button_hover    = hex("#4c566a"),
    button_active   = hex("#2e3440"),
    button_disabled = hex("#3b4252", 0.40),
    accent          = hex("#81a1c1"),                   -- blue
    accent_brighter = hex("#88c0d0"),                   -- light blue / frost ice
    accent_darker   = hex("#5e81ac"),                   -- dark blue
    success         = hex("#a3be8c"),                   -- green
    warning         = hex("#ebcb8b"),                   -- yellow
    error           = hex("#bf616a"),                   -- red
    error_deep      = hex("#8d4147"),
    -- UI tokens (OneNord nvim highlights)
    tab_active_bg       = hex("#2E3440"),  -- bg (TabLineSel)
    tab_active_text     = hex("#88C0D0"),  -- cyan
    popup_selected_bg   = hex("#4C566A"),  -- selection (PmenuSel)
    popup_selected_text = hex("#C8D0E0"),  -- fg
    statusline_bg       = hex("#353B49"),  -- active
    text_on_accent      = hex("#2E3440"),  -- bg
    float_bg            = hex("#353B49"),  -- active
    float_border        = hex("#81A1C1"),  -- blue
    diag_error          = hex("#BF616A"),  -- dark_red
    diag_warn           = hex("#D08F70"),  -- orange
    diag_info           = hex("#A3BE8C"),  -- green
    diag_hint           = hex("#B48EAD"),  -- light_purple
} end

-- ----- Badwolf (Steve Losh) -------------------------------------------------
-- Source: https://github.com/sjl/badwolf (colors/badwolf.vim s:bwc dict / HTML
-- palette preview). Gravel ramp = grayscale surfaces; tardis/lime/taffy accents.
Palettes.Badwolf = function() return {
    sunken          = hex("#141413"),                   -- blackestgravel
    bg              = hex("#1c1b1a", 0.95),             -- blackgravel (Normal bg)
    panel_soft      = hex("#242321"),                   -- darkgravel
    panel           = hex("#35322d"),                   -- deepergravel
    panel_footer    = hex("#45413b"),                   -- deepgravel
    panel_header    = hex("#45413b"),                   -- deepgravel (header reuses)
    raised          = hex("#666462"),                   -- mediumgravel
    border          = hex("#857f78"),                   -- gravel
    text            = hex("#f8f6f2"),                   -- plain
    text_header     = hex("#ffffff"),                   -- snow
    text_label      = hex("#d9cec3"),                   -- brightgravel
    text_dim        = hex("#998f84"),                   -- lightgravel
    text_disabled   = hex("#666462"),                   -- mediumgravel
    text_inverse    = hex("#1c1b1a"),                   -- blackgravel
    button_normal   = hex("#35322d"),                   -- deepergravel
    button_hover    = hex("#45413b"),                   -- deepgravel
    button_active   = hex("#242321"),                   -- darkgravel
    button_disabled = hex("#35322d", 0.40),
    accent          = hex("#0a9dff"),                   -- tardis (blue)
    accent_brighter = hex("#60bfff"),                   -- lightened tardis
    accent_darker   = hex("#076eb3"),                   -- darkened tardis
    success         = hex("#aeee00"),                   -- lime
    warning         = hex("#ffa724"),                   -- orange
    error           = hex("#ff2c4b"),                   -- taffy (red)
    error_deep      = hex("#c50048"),                   -- deep red (RedBar)
    -- UI tokens (badwolf highlight groups)
    tab_active_bg       = hex("#1c1b1a"),  -- blackgravel (bg)
    tab_active_text     = hex("#f8f6f2"),  -- plain
    popup_selected_bg   = hex("#45413b"),  -- deepgravel (Visual/PmenuSel)
    popup_selected_text = hex("#f8f6f2"),  -- plain
    statusline_bg       = hex("#242321"),  -- darkgravel (StatusLine)
    text_on_accent      = hex("#141413"),  -- blackestgravel (dark on bright blue)
    float_bg            = hex("#242321"),  -- darkgravel (NormalFloat)
    float_border        = hex("#0a9dff"),  -- tardis (blue)
    diag_error          = hex("#ff2c4b"),  -- taffy (red)
    diag_warn           = hex("#ffa724"),  -- orange
    diag_info           = hex("#0a9dff"),  -- tardis (blue)
    diag_hint           = hex("#8cffba"),  -- saltwatertaffy (green)
} end

-- ----- Housing (the addon's signature theme) --------------------------------
-- A clone of Badwolf -- near-black charcoal + white text, the closest existing
-- match to the donor HDG "Housing Theme" solid palette -- plus 3 donor-signature
-- overrides (Blizzard Gold accent, bronze-wood border, dark-wood header) and the
-- `chrome` atlas table that drives the housing artwork (full-window wood frame,
-- dashboard/stone backgrounds, wood-sign headers, rotated title band).
--
-- The `chrome` table is what flips the atlas-aware Skinners into housing mode;
-- every other scheme leaves chrome=nil and paints solid/watercolor (step 2).
-- Derives from Badwolf by shallow copy so it tracks any Badwolf tweak; do NOT
-- mutate Badwolf (it stays its own selectable theme).
Palettes.Housing = function()
    local p = {}
    for k, v in pairs(Palettes.Badwolf()) do p[k] = v end
    -- Donor-signature overrides (the tokens the atlas does not cover):
    p.accent          = hex("#ffd100")   -- Blizzard Gold (donor accent; Badwolf's was tardis blue)
    p.accent_brighter = hex("#ffe45c")   -- lightened gold
    p.accent_darker   = hex("#c99700")   -- darkened gold
    p.border          = hex("#705c42")   -- bronze-wood (donor border; Badwolf's was warm grey)
    p.panel_header    = hex("#452e1c")   -- dark wood (donor header_bar)
    p.statusline_bg   = hex("#452e1c")   -- dark wood, matching the header band
    -- Chrome atlas table -- the contract the atlas-aware Skinners read (step 2).
    -- All Blizzard atlas strings, confirmed present on 12.0.7. Absent on every
    -- other scheme, so those Skinners fall back to the solid/watercolor path.
    p.chrome = {
        windowBg     = "housing-dashboard-bg-activity",         -- main window background
        windowBorder = "housing-simple-wood-frame",             -- full-window carved-wood frame overlay
        titleBand    = "catalog-nav-bg-primary",                -- title strip (Skinner rotates 90deg)
        headerSign   = "housing-woodsign",                      -- panel-header wood sign
        navPanel     = "housing-basic-panel--stone-background", -- sidebar stone column
        panelBg      = "housing-basic-panel--stone-background", -- content panel stone (cover-cropped)
        rowBeam      = "housing-woodsign",                      -- RowWoodBeam reads this (was hardcoded)
        scrollThumb  = "decor-abilitybar-divider",              -- scrollbar thumb
        foliageLeft  = "housing-decorative-foliage-left",       -- per-view header bookend (left end)
        foliageRight = "housing-decorative-foliage-right",      -- per-view header bookend (right end)
    }
    return p
end

-- ----- Purpura (yassinebridi) -----------------------------------------------
-- Source: https://github.com/yassinebridi/vim-purpura (colors/purpura.vim s:cd*
-- dict). Deep-purple canvas; pink/magenta syntax; surface ramp derived from bg.
Palettes.Purpura = function() return {
    sunken          = hex("#10001a"),                   -- derived (deep void)
    bg              = hex("#1e0030", 0.95),             -- cdBack (Normal bg)
    panel_soft      = hex("#2a003a"),                   -- derived (bg -> tabCurrent)
    panel           = hex("#350043"),                   -- derived
    panel_footer    = hex("#3f004c"),                   -- derived
    panel_header    = hex("#3f004c"),                   -- derived (header reuses)
    raised          = hex("#480275"),                   -- cdLineNumber (bright purple)
    border          = hex("#490e6d"),                   -- derived (bg -> violet)
    text            = hex("#f0f0f0"),                   -- cdFront
    text_header     = hex("#ffffff"),                   -- white
    text_label      = hex("#bbbbbb"),                   -- cdPopupFront
    text_dim        = hex("#898989"),                   -- cdSplitLight
    text_disabled   = hex("#808080"),                   -- cdGray
    text_inverse    = hex("#1e0030"),                   -- cdBack
    button_normal   = hex("#471469"),                   -- cdSelection
    button_hover    = hex("#5e0066"),                   -- cdTabCurrent
    button_active   = hex("#25003d"),                   -- cdCursorDarkDark
    button_disabled = hex("#471469", 0.40),
    accent          = hex("#ff00d4"),                   -- cdPink (signature)
    accent_brighter = hex("#ff59e3"),                   -- lightened pink
    accent_darker   = hex("#8924c9"),                   -- cdViolet
    success         = hex("#acff59"),                   -- cdPinkGreen
    warning         = hex("#ffc363"),                   -- cdVeryLightGreen (orange)
    error           = hex("#f44747"),                   -- cdRed
    error_deep      = hex("#6f1313"),                   -- cdDiffRedLight
    -- UI tokens (purpura highlight groups)
    tab_active_bg       = hex("#5e0066"),  -- cdTabCurrent
    tab_active_text     = hex("#f0f0f0"),  -- cdFront
    popup_selected_bg   = hex("#471469"),  -- cdSelection (PmenuSel)
    popup_selected_text = hex("#f0f0f0"),  -- cdFront
    statusline_bg       = hex("#2a003a"),  -- derived (dark panel)
    text_on_accent      = hex("#1e0030"),  -- cdBack (dark on pink)
    float_bg            = hex("#25003d"),  -- cdCursorDarkDark
    float_border        = hex("#ff00d4"),  -- cdPink (accent)
    diag_error          = hex("#f44747"),  -- red
    diag_warn           = hex("#ffc363"),  -- orange
    diag_info           = hex("#73bbf5"),  -- cdLightBlue
    diag_hint           = hex("#acff59"),  -- green
} end

-- ----- Green (julien) -------------------------------------------------------
-- Source: https://github.com/julien/vim-colors-green (colors/green.vim). Matrix
-- monochrome: black canvas, 3 greens (#448c27 / #5ec435 / #72f13e), red errors.
-- Surface ramp + warning hue derived (palette is near-monochrome).
Palettes.Green = function() return {
    sunken          = hex("#000000"),                   -- black (Normal bg)
    bg              = hex("#030702", 0.95),             -- derived near-black green
    panel_soft      = hex("#070e04"),                   -- derived
    panel           = hex("#0b1606"),                   -- derived
    panel_footer    = hex("#102209"),                   -- derived
    panel_header    = hex("#102209"),                   -- derived (header reuses)
    raised          = hex("#1b3810"),                   -- derived
    border          = hex("#448c27"),                   -- VertSplit green
    text            = hex("#5ec435"),                   -- bright green (Statement)
    text_header     = hex("#72f13e"),                   -- brightest green
    text_label      = hex("#448c27"),                   -- Normal/Comment green
    text_dim        = hex("#356d1e"),                   -- derived dim green
    text_disabled   = hex("#254d15"),                   -- derived
    text_inverse    = hex("#000000"),                   -- black
    button_normal   = hex("#0f1f09"),                   -- derived dark green
    button_hover    = hex("#17300d"),                   -- derived
    button_active   = hex("#081105"),                   -- derived
    button_disabled = hex("#0f1f09", 0.40),
    accent          = hex("#72f13e"),                   -- brightest green (Directory/PmenuSel)
    accent_brighter = hex("#9cf578"),                   -- lightened
    accent_darker   = hex("#448c27"),                   -- Normal green
    success         = hex("#5ec435"),                   -- diffAdded green
    warning         = hex("#c4d62a"),                   -- derived yellow-green (no warning hue upstream)
    error           = hex("#aa3731"),                   -- Error red
    error_deep      = hex("#69221e"),                   -- derived deep red
    -- UI tokens (green highlight groups -- inverted selection style)
    tab_active_bg       = hex("#000000"),  -- black (bg)
    tab_active_text     = hex("#72f13e"),  -- brightest green
    popup_selected_bg   = hex("#448c27"),  -- green (PmenuSel bg, inverted)
    popup_selected_text = hex("#000000"),  -- black
    statusline_bg       = hex("#0a1405"),  -- derived dark green
    text_on_accent      = hex("#000000"),  -- black (dark on green accent)
    float_bg            = hex("#070e04"),  -- derived dark green
    float_border        = hex("#448c27"),  -- VertSplit green
    diag_error          = hex("#aa3731"),  -- red
    diag_warn           = hex("#c4d62a"),  -- derived yellow-green
    diag_info           = hex("#5ec435"),  -- mid green (no blue upstream)
    diag_hint           = hex("#72f13e"),  -- bright green
} end

-- ----- Pumpkin Spice --------------------------------------------------------
-- Source: community brand palette from Madailein Hatter, supplied directly on
-- Discord 2026-07-31 -- their own five hex codes, their own name for it ("I
-- love calling it pumpkin spice"), and their own go-ahead for both addons
-- ("Aegis and HDG would be wonderful").
--
-- THE ONE THEME WITH NO UPSTREAM COLORSCHEME. Every other palette here ports a
-- published vim/neovim theme and mirrors its hex verbatim so it verifies
-- against source. This one has no repo to point at, so the rule is met the
-- other way: the five brand colours below are Madailein's, quoted exactly as
-- given, and every other key is derived from them and marked as such.
--
--   Rose Gold #C69274   Warm Ivory #DAC7B6   Charcoal #222221
--   Deep Forest #333526   Soft Bronze #5D4024
--
-- THREE COLOURS ADDED, because her five have a 36-POINT LIGHTNESS HOLE between
-- Soft Bronze (25.3%) and Rose Gold (61.6%) -- more than double any other gap --
-- and that hole is exactly where autumn lives. Her warm tones also cluster at
-- 22/28.3/29.5 degrees: one hue at three brightnesses, elegant but never orange.
-- The additions fill the gap along her OWN hue line rather than intruding:
--   Pumpkin      #B4642A  26deg / 43%  the missing centre -- borders
--   Deep Pumpkin #6B3A18  25deg / 25%  the same, dark enough to carry ivory text
--   Amber        #D9932F  38deg / 52%  candlelight; the 38deg rung she has none of
--   Oxblood      #7A2E22   8deg / 31%  the red anchor; nothing sat below 20deg
-- Her five are UNCHANGED except Deep Forest, and that one had to move. At
-- 16.5% saturation and 17.8% lightness it was the LEAST saturated tone here,
-- and once the four oranges landed at 62-69% it stopped reading as green at all
-- -- simultaneous contrast hands the hue to the loudest neighbour (owner, live
-- 2026-08-01, "the forest green still isnt quite there"). The deeper cause was a
-- ladder imbalance I created: orange ended up with SIX rungs (25/26/31/44/52/62%
-- lightness), green with ONE. So Deep Forest is lifted to #3A4527 -- her 68deg
-- hue kept and saturation roughly doubled to ~28% -- and Moss fills the middle
-- rung. Green now reads as a family rather than a single dark step.
--
-- SATURATION AND LIGHTNESS ARE SEPARATE DIALS, and only the first one was
-- needed. A first attempt raised BOTH, which made the green read green but also
-- made it advance: luminance is what the eye reads as depth, so every lifted row
-- floated forward and long lists fragmented into a stack of raised bars (owner,
-- live 2026-08-01, "they look raised and discontinuous"). Lightness is now back
-- near her original 17.8% while the new saturation stays. Rule for any future
-- tuning here: reach for SATURATION to make a colour read as itself, and leave
-- LIGHTNESS alone unless you actually intend the surface to advance or recede.
--
-- THE SURFACE RAMP RUNS BACKWARDS, ON PURPOSE. Every other scheme here puts
-- the darkest tone at the canvas and lifts panels off it, so cards read
-- RAISED. Here the deep forest is the FRAME and the charcoal cards sink into
-- it (Madailein: "swap charcoal for the green"; owner: "panels should look
-- inset"). That inversion is the theme's whole character -- it makes every
-- information surface near-black, which is what carries text and swatches --
-- so `panel` is deliberately DARKER than `bg`, and `sunken` sits below both.
-- Anything that assumes panel-is-lighter-than-canvas will read wrong here and
-- is a bug in that skinner, not in this palette.
--
-- WHICH BRAND COLOUR CARRIES THE WINDOW DIFFERS FROM AEGIS, deliberately. The
-- five hexes are identical in both addons; what changed here is which ROLE each
-- one takes, because the two layouts weight their surfaces oppositely. Aegis is
-- frame-dominant (the forest fills the window, charcoal cards are small insets)
-- so it reads warm. HDG is panel-dominant -- the browser list, preview pane and
-- note box cover most of the window -- so putting Charcoal on `panel` made the
-- whole addon read GREY, because Charcoal #222221 is R34 G34 B33: a genuinely
-- neutral tone, 2.9% saturation against 18-28% for every other surface here
-- (owner, live side-by-side 2026-08-01, "brown vs gray for hdg").
--
-- So the surface ramp is derived from SOFT BRONZE, not Deep Forest. That second
-- part is not fussiness: deriving every surface from the forest made the whole
-- window one olive ramp and it read as CAMO (owner, live 2026-08-01, "we are
-- leaning to 'camo' or army"). Charcoal's neutrality had been doing real work as
-- the non-green counterpoint to the frame, and dropping it left nothing to break
-- up the green. The ramp below is brown by construction -- every surface is
-- R > G > B -- so the forest canvas frames warm cards instead of blending into
-- them. Green frame, bronze cards, rose gold accents: autumn, not army.
--
-- BOTH HUES NEED VISIBLE AREA, and that is what settles which key gets which.
-- A bronze-only ramp lost the forest entirely -- it survived on `canvas`, which
-- HDG's panels almost completely cover, so the green had nowhere to show (owner
-- 2026-08-01, "we've lost the olive entirely"). The fix is to give the forest a
-- job with real pixel count rather than a bigger swatch: RowChrome drives zebra
-- alt rows from `panel_soft` and section-header bands from `panel_header`, and
-- in a list-heavy addon those two out-cover every other surface. So the forest
-- family holds those, the bronze family holds the card body and the deep insets,
-- and the two alternate down every list instead of one hue winning outright.
--
-- FINAL ALLOCATION IS BY MEASURED PAINT AREA, not by copying Aegis. Full
-- workings: docs/PUMPKIN_SPICE_SURFACE_ANALYSIS_2026-08-01.md. The headline:
-- `surface.canvas` has ZERO paint sites -- nothing renders it, the Canvas
-- skinner draws from `sunken` -- so Deep Forest sat on a key with no pixels for
-- four tuning passes. That single mis-assignment caused the grey, the camo and
-- the lost-olive rounds in turn. Site counts: panel 19, sunken 9, panel_header
-- 6, panel_soft 4, panel_footer 3, raised 1, canvas 0. Big-area keys take
-- low-chroma bronze; the forest goes on panel_header, whose sites are
-- structural but THIN (every panel title bar, every list section break, the
-- active nav item) so a strong hue reads as identity rather than a wash.
-- No brand hex was altered, the inversion survives (panel L=0.0252 still sits
-- under canvas L=0.0339), and the addon reads warm at the size it is actually
-- seen. Aegis needs none of this -- same palette, different geometry.
Palettes.PumpkinSpice = function() return {
    sunken          = hex("#2E361E"),                   -- DEEP FOREST, SATURATED: the frame. 9 sites
                                                        -- the Canvas skinner paints the whole window
                                                        -- from this, so it is the largest surface.
    bg              = hex("#2E361E", 0.97),             -- DEEP FOREST, SATURATED -- matches the frame
    panel_soft      = hex("#222221"),                   -- CHARCOAL (brand): nav rail + zebra alt rows.
                                                        -- MUST NOT EQUAL `sunken`: RowChrome hides the
                                                        -- zebra texture on odd rows so sunken shows
                                                        -- through, and tints even rows with this key --
                                                        -- so setting both to Deep Forest erased the
                                                        -- striping outright (owner, live 2026-08-01).
                                                        -- Charcoal here alternates the two brand grounds
                                                        -- against each other: 1.27:1 plus a hue step.
    panel           = hex("#222221"),                   -- CHARCOAL (brand): the inset card. Near-
                                                        -- neutral ON PURPOSE -- it is the reading
                                                        -- surface, and text/screenshots/swatches sit
                                                        -- cleanest on a ground with no hue of its own.
    panel_footer    = hex("#6B3A18"),                   -- DEEP PUMPKIN (added)
    panel_header    = hex("#6B3A18"),                   -- DEEP PUMPKIN (added): panel title bars, list
                                                        -- section headers, active nav item. 1.69:1 off
                                                        -- the card -- the strongest step in the ramp,
                                                        -- which is what a band should be.
    raised          = hex("#404C2A"),                   -- MOSS (added): the green family's missing
                                                        -- middle rung -- 33% light between the lifted
                                                        -- forest at 25% and sage at 59%

    border          = hex("#B4642A"),                   -- PUMPKIN (added): borders carry no text, so
                                                        -- they take the new mid-orange at full strength
    text            = hex("#DAC7B6"),                   -- WARM IVORY (brand)
    text_header     = hex("#EFE3D6"),                   -- derived: lifted ivory
    text_label      = hex("#BFAE9B"),                   -- derived: settled ivory
    text_dim        = hex("#A2917F"),                   -- derived: muted ivory
    text_disabled   = hex("#7A6D5E"),                   -- derived
    text_inverse    = hex("#222221"),                   -- charcoal (dark on light)
    button_normal   = hex("#333526"),                   -- deep forest
    button_hover    = hex("#5D4024"),                   -- soft bronze
    button_active   = hex("#C69274"),                   -- rose gold
    button_disabled = hex("#333526", 0.40),
    accent          = hex("#C69274"),                   -- ROSE GOLD (brand)
    accent_brighter = hex("#D9932F"),                   -- AMBER (added): candlelight, the 38deg rung
    accent_darker   = hex("#5D4024"),                   -- soft bronze, the brand's darker partner
    success         = hex("#A3B57A"),                   -- derived: sage
    warning         = hex("#D9932F"),                   -- AMBER (added)
    error           = hex("#D9705A"),                   -- derived: terracotta
    error_deep      = hex("#7A2E22"),                   -- OXBLOOD (added): the red anchor her five
                                                        -- lack -- nothing sat below 20deg hue
    -- UI tokens: no upstream highlight groups to mine (see Purpura/Green for
    -- the same compromise), so these are composed from the brand five.
    tab_active_bg       = hex("#222221"),  -- CHARCOAL (brand): the active tab sinks deepest
    tab_active_text     = hex("#EFE3D6"),  -- lifted ivory
    popup_selected_bg   = hex("#6B3A18"),  -- deep pumpkin
    popup_selected_text = hex("#EFE3D6"),  -- lifted ivory
    statusline_bg       = hex("#6B3A18"),  -- DEEP PUMPKIN: bottom rail, matching the header bands  -- DEEP FOREST: the window's bottom band. Matches
                                                 -- panel_header by design (see StatusRail: "full-bleed
                                                 -- watercolor + gloss, matching PanelHeader") so forest
                                                 -- bookends the window -- a band atop every panel and
                                                 -- one along the base. Dark schemes read surface.
                                                 -- statusline here, NOT panel_footer (light-only).
    text_on_accent      = hex("#222221"),  -- charcoal on rose gold
    float_bg            = hex("#222221"),  -- charcoal card
    float_border        = hex("#B4642A"),  -- pumpkin: floats wear the new mid-orange
    diag_error          = hex("#D9705A"),  -- terracotta
    diag_warn           = hex("#D9932F"),  -- amber (added)
    diag_info           = hex("#8CA6B8"),  -- derived slate: the palette's only cool tone
    diag_hint           = hex("#A3B57A"),  -- sage (the green ladder's top rung)
} end

-- ----- BlizzardUI -----------------------------------------------------------
-- Matches the default Blizzard WoW frame (PortraitFrameTemplate / ButtonFrame-
-- Template -- the frame used by Toy Box, Collections, Encounter Journal, etc.).
--
-- Verified against Blizzard's own source + textures:
--   - SharedXML/SharedUIPanelTemplates.xml (tekkub/wow-ui-source): the frame
--     body is Interface\FrameGeneral\UI-Background-Rock (tiled), insets are
--     UI-Background-Marble, and the gold metal border is sliced from UI-Frame.
--   - Measured fills (Gethe/wow-ui-textures):
--       UI-Background-Rock   avg #332e2a  (warm dark stone-brown -> frame body)
--       UI-Background-Marble avg #0d0d0d  (near-black            -> content insets)
--
-- So the authentic WoW look is a warm stone-brown OUTER frame with near-black
-- content insets and a gold metal border -- NOT a flat pure-black panel. The
-- surface ramp below reproduces those exact fills, so the colours read right on
-- HDG's standard window chrome. (The gold frame itself was dropped -- see the
-- chrome note below Palettes.BlizzardUI for the post-mortem.)
--
--   bg / panel_header  -> Rock-brown frame body (#2b2724 .. #38322d)
--   panel / sunken     -> Marble near-black content insets (#0d0d0d ..)
--   border             -> #5a4a2e bronze-brown (the UI-Frame metal edge tone)
--   accent / headers   -> Blizzard Gold #ffd100 (titles, section labels)
Palettes.BlizzardUI = function() return {
    -- Surface ramp: warm stone-brown frame body + near-black Marble insets,
    -- matching UI-Background-Rock (#332e2a) and UI-Background-Marble (#0d0d0d).
    sunken          = hex("#080808"),                   -- deepest inset well (below Marble)
    bg              = hex("#2b2724"),                   -- canvas: Rock-brown frame body (dark end), OPAQUE
    panel_soft      = hex("#0d0d0d"),                   -- recessed inset (Marble near-black)
    panel           = hex("#111111"),                   -- content panel (Marble inset, hair lighter)
    panel_footer    = hex("#322c28"),                   -- footer band (Rock-brown)
    panel_header    = hex("#38322d"),                   -- header band (Rock-brown, lit end)
    raised          = hex("#473d31"),                   -- raised chrome / button base (warm stone)
    border          = hex("#5a4a2e"),                   -- bronze-brown metal frame edge (UI-Frame tone)
    text            = hex("#f0e6c0"),                   -- WoW warm cream (NORMAL_FONT_COLOR-adjacent)
    text_header     = hex("#ffd100"),                   -- Blizzard Gold titles (real WoW header colour)
    text_label      = hex("#ffd100"),                   -- gold labels (section headers are gold in WoW)
    text_dim        = hex("#b5a98c"),                   -- warm dim parchment (readable on brown)
    text_disabled   = hex("#7a7058"),                   -- muted warm grey-brown
    text_inverse    = hex("#1a160f"),                   -- dark brown (text on gold bg)
    button_normal   = hex("#3d342a"),                   -- warm stone button base
    button_hover    = hex("#4d4234"),                   -- lifted warm stone (hover)
    button_active   = hex("#2a2620"),                   -- depressed warm stone
    button_disabled = hex("#3d342a", 0.40),
    accent          = hex("#ffd100"),                   -- Blizzard Gold (Trim & Accents bright end)
    accent_brighter = hex("#ffe45c"),                   -- lighter gold (hover)
    accent_darker   = hex("#cc9900"),                   -- Trim & Accents dark end (documented)
    success         = hex("#1eff00"),                   -- WoW uncommon-green (status positive)
    warning         = hex("#ffd100"),                   -- gold doubles as warning in WoW chrome
    error           = hex("#ff2020"),                   -- WoW red (error / debuff)
    error_deep      = hex("#a00000"),                   -- deep red (danger fills)
    -- UI tokens (WoW interface canonical conventions)
    tab_active_bg       = hex("#473d31"),  -- raised warm stone (active tab)
    tab_active_text     = hex("#ffd100"),  -- Blizzard Gold on active tab (canonical WoW)
    popup_selected_bg   = hex("#4d4234"),  -- warm stone highlight (selected row)
    popup_selected_text = hex("#ffffff"),  -- white on selection
    statusline_bg       = hex("#0d0d0d"),  -- Marble inset (status strip over content)
    text_on_accent      = hex("#1a160f"),  -- dark brown (legible on #FFD100 gold)
    float_bg            = hex("#0d0d0d"),  -- Marble near-black (tooltip/float bg, OPAQUE)
    float_border        = hex("#ffd100"),  -- Blizzard Gold (tooltip "thin gold border")
    diag_error          = hex("#ff2020"),  -- red
    diag_warn           = hex("#ffd100"),  -- gold
    diag_info           = hex("#4ea3f1"),  -- blue (info channel)
    diag_hint           = hex("#1eff00"),  -- green (hint channel)
    -- nativeButtons: BlizzardUI builds its action buttons as native UIPanelButtonTemplate
    -- (left unskinned -- the real Blizzard button), instead of HDG's hand-built dark
    -- atlas. Read by HDG.UI:Button at build time. Structural (not a repaint), so
    -- switching to/from BlizzardUI needs a /reload to rebuild the buttons.
    nativeButtons       = true,
} end
-- chrome = nil (intentional). A Blizzard nine-slice gold frame was tried (a
-- companion HDGR_BlizzardFrame.lua) but force-fit badly against HDG's OWN title
-- bar: the Blizzard ButtonFrame art assumes a content-inset window with a title
-- margin, so it either covered HDG's title or floated above it as a second bar.
-- Dropped 2026-06-23 -- BlizzardUI is a COLOUR theme (the palette above) on HDG's
-- standard window chrome, like every other non-Housing scheme. Post-mortem:
-- docs/HDG_BLIZZARDUI_FRAME_RESEARCH.md.

-- ===== Scheme exports =======================================================
-- Each scheme is built from its palette on first use and kept. Theme:LoadScheme
-- takes the name; the global table here is the registry. A player uses one of the
-- 22, and building all of them at load held ~0.6 MB (memory census 2026-10-19).
-- pairs() over it sees only the schemes built so far; HDGR_SchemeMeta.order lists
-- them all.
HDGR_SchemeConstants = setmetatable({}, { __index = function(t, name)
    local palette = Palettes[name]
    if not palette then return nil end   -- exception(nullable): not a registered scheme name
    local scheme = BuildScheme(palette())
    rawset(t, name, scheme)
    return scheme
end })

-- Display metadata for the slash command + Config tab buttons.
-- ColorblindSafe first (accessibility default). `order` is the list of every
-- scheme; HDGR_SchemeConstants builds them on demand.
HDGR_SchemeMeta = {
    order = {
        "ColorblindSafe",
        -- Dark family
        "Housing",   -- the addon's signature atlas theme; featured first in the dark family
        "BlizzardUI",  -- Blizzard WoW interface: warm stone-brown + Blizzard Gold
        "Mocha", "TokyonightNight", "RosePineMain", "GruvboxDarkHard",
        "SolarizedDark", "EverforestDark", "KanagawaWave",
        "Nord", "Dracula", "Nightfly", "OneNord", "Badwolf",
        "Purpura", "Green", "PumpkinSpice",
        -- Light family
        "SolarizedLight", "GruvboxLightHard", "EverforestLight", "KanagawaLotus",
    },
    labels = {
        ColorblindSafe   = "Colorblind Safe (default)",
        Mocha            = "Catppuccin Mocha",
        TokyonightNight  = "Tokyonight Night",
        RosePineMain     = "Rose Pine",
        GruvboxDarkHard  = "Gruvbox Dark Hard",
        GruvboxLightHard = "Gruvbox Light Hard",
        SolarizedDark    = "Solarized Dark",
        SolarizedLight   = "Solarized Light",
        EverforestDark   = "Everforest Dark",
        EverforestLight  = "Everforest Light",
        KanagawaWave     = "Kanagawa Wave",
        KanagawaLotus    = "Kanagawa Lotus",
        Nord             = "Nord",
        Dracula          = "Dracula",
        Nightfly         = "Nightfly",
        OneNord          = "OneNord",
        Badwolf          = "Badwolf",
        Housing          = "Housing Decor Guide",
        BlizzardUI       = "Panseit's Blizzard UI",
        Purpura          = "Purpura",
        Green            = "Green",
        PumpkinSpice     = "Pumpkin Spice",
    },
}
