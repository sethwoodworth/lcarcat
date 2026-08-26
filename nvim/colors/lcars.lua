-- lcars — a dark LCARS colorscheme for neovim.
--
-- Pure-black canvas, pale-canary text, and the lcarcat accent vocabulary
-- (orange keywords, periwinkle functions, lilac types, warm-white strings,
-- gold numbers, dim comments). Maps both legacy syntax groups and treesitter
-- @-captures, since treesitter highlighting is active in this config.
--
-- Palette lives in lua/lcars/palette.lua (shared with the lualine theme).

vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end

vim.o.background = "dark"
vim.o.termguicolors = true
vim.g.colors_name = "lcars"

-- Terminal 16-color palette (matches kitty/lcars.conf color0-15 by hand — see
-- lua/lcars/palette.lua's header comment). baleia.nvim (used by
-- lcars.frame_buffer to render PTY output) reads vim.g.terminal_color_N
-- before falling back to its own generic default theme; without this, ANSI
-- colors inside :LcarsTerm (e.g. `ls`'s directory blue) don't match what the
-- same command shows in a real kitty pane and can be unreadably dark.
local terminal_colors = {
  "#000000", "#cc6666", "#88bb88", "#cc9966",
  "#9966ff", "#cc6699", "#99ccff", "#ffcc99",
  "#666699", "#ff3300", "#99cc99", "#ffcc66",
  "#9999ff", "#cc99cc", "#cceeff", "#ccccff",
}
for i, hex in ipairs(terminal_colors) do
  vim.g["terminal_color_" .. (i - 1)] = hex
end

local p = require("lcars.palette")

local function hi(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

-- ---------------------------------------------------------------------------
-- Editor UI
-- ---------------------------------------------------------------------------
hi("Normal",        { fg = p.fg, bg = p.bg })
hi("NormalFloat",   { fg = p.fg, bg = p.bg })
hi("NormalNC",      { fg = p.fg, bg = p.bg })
hi("FloatBorder",   { fg = p.orange, bg = p.bg })
hi("FloatTitle",    { fg = p.orange, bg = p.bg, bold = true })
hi("Cursor",        { fg = p.bg, bg = p.cursor })
hi("CursorLine",    { bg = p.bg_dim })
hi("CursorColumn",  { bg = p.bg_dim })
hi("ColorColumn",   { bg = p.bg_dim })
-- Number gutter = the LCARS vertical stem (orange), recessive numbers, current
-- line in solid black. signcolumn='number' merges signs into this column, so
-- SignColumn shares the stem too.
hi("LineNr",        { fg = p.stem_dim, bg = p.stem })
hi("LineNrAbove",   { fg = p.stem_dim, bg = p.stem })
hi("LineNrBelow",   { fg = p.stem_dim, bg = p.stem })
hi("CursorLineNr",  { fg = p.bg, bg = p.stem, bold = true })
hi("SignColumn",    { fg = p.stem_dim, bg = p.stem })
hi("CursorLineSign",{ fg = p.stem_dim, bg = p.stem })
hi("FoldColumn",    { fg = p.dim, bg = p.bg })
hi("Folded",        { fg = p.sky, bg = p.bg_dim })
-- Solid periwinkle separators (fg = bg so the whole cell fills, matching the
-- number-gutter stem) so splits read as LCARS rails the corner elbows merge into.
hi("VertSplit",     { fg = p.stem, bg = p.stem })
hi("WinSeparator",  { fg = p.stem, bg = p.stem })
-- EOB rows get no LineNr cell unless statuscolumn is set; without it the gutter
-- goes black below the last line. statuscolumn forces %#LineNr# on every row.
hi("EndOfBuffer",   { fg = p.bg, bg = p.bg })
vim.opt.fillchars:append({ eob = " " })
vim.opt.statuscolumn = "%#LineNr#%=%l%#LineNr# "
require("lcars.gutter_eob_fill").setup()
require("lcars.terminal_frame")
require("lcars.terminal_win")
require("lcars.spike_placeholder")
require("lcars.spike_baleia")
hi("Visual",        { fg = p.bg, bg = p.periwinkle })
hi("VisualNOS",     { fg = p.bg, bg = p.periwinkle })
hi("Search",        { fg = p.bg, bg = p.gold })
hi("IncSearch",     { fg = p.bg, bg = p.orange })
hi("CurSearch",     { fg = p.bg, bg = p.orange })
hi("MatchParen",    { fg = p.orange, bold = true, underline = true })
hi("NonText",       { fg = p.dim2 })
hi("Whitespace",    { fg = p.dim2 })
hi("SpecialKey",    { fg = p.dim2 })
hi("Conceal",       { fg = p.dim })
hi("Directory",     { fg = p.sage })
hi("Title",         { fg = p.orange, bold = true })
hi("Question",      { fg = p.sage })
hi("MoreMsg",       { fg = p.sage })
hi("ModeMsg",       { fg = p.fg, bold = true })
hi("WarningMsg",    { fg = p.gold })
hi("ErrorMsg",      { fg = p.red, bold = true })
hi("WildMenu",      { fg = p.bg, bg = p.orange })

-- Popup menu
hi("Pmenu",         { fg = p.fg, bg = p.bg_dim })
hi("PmenuSel",      { fg = p.bg, bg = p.orange, bold = true })
hi("PmenuSbar",     { bg = p.bg_dim })
hi("PmenuThumb",    { bg = p.dim })
hi("PmenuKind",     { fg = p.lilac, bg = p.bg_dim })
hi("PmenuKindSel",  { fg = p.bg, bg = p.orange })
hi("PmenuExtra",    { fg = p.dim, bg = p.bg_dim })
hi("PmenuExtraSel", { fg = p.bg, bg = p.orange })

-- Statusline / tabline (bridge to the lualine phase; sane defaults meanwhile)
hi("StatusLine",    { fg = p.bg, bg = p.orange })
hi("StatusLineNC",  { fg = p.fg, bg = p.bg_dim })
hi("TabLine",       { fg = p.bg, bg = p.periwinkle })
hi("TabLineSel",    { fg = p.bg, bg = p.orange, bold = true })
hi("TabLineFill",   { fg = p.fg, bg = p.bg })
hi("WinBar",        { fg = p.fg, bg = p.bg })
hi("WinBarNC",      { fg = p.dim, bg = p.bg })
hi("LcarsTermBar",          { fg = p.periwinkle, bg = p.periwinkle })
hi("LcarsTermFrameLive",   { fg = p.sage,        bg = p.sage })
hi("LcarsTermStemLive",    { fg = p.sage,        bg = p.sage })
hi("LcarsTermFrameFailed", { fg = p.red,         bg = p.red })
hi("LcarsTermStemFailed",  { fg = p.red,         bg = p.red })

-- ---------------------------------------------------------------------------
-- Legacy syntax groups
-- ---------------------------------------------------------------------------
hi("Comment",       { fg = p.dim, italic = true })

hi("Constant",      { fg = p.gold })
hi("String",        { fg = p.str })
hi("Character",     { fg = p.str })
hi("Number",        { fg = p.gold })
hi("Float",         { fg = p.gold })
hi("Boolean",       { fg = p.gold })

hi("Identifier",    { fg = p.fg })
hi("Function",      { fg = p.periwinkle })

hi("Statement",     { fg = p.orange })
hi("Conditional",   { fg = p.orange })
hi("Repeat",        { fg = p.orange })
hi("Label",         { fg = p.orange })
hi("Operator",      { fg = p.fg })
hi("Keyword",       { fg = p.orange })
hi("Exception",     { fg = p.red })

hi("PreProc",       { fg = p.orange })
hi("Include",       { fg = p.orange })
hi("Define",        { fg = p.orange })
hi("Macro",         { fg = p.lilac })
hi("PreCondit",     { fg = p.orange })

hi("Type",          { fg = p.lilac })
hi("StorageClass",  { fg = p.lilac })
hi("Structure",     { fg = p.lilac })
hi("Typedef",       { fg = p.lilac })

hi("Special",       { fg = p.sky })
hi("SpecialChar",   { fg = p.sky })
hi("Tag",           { fg = p.sky })
hi("Delimiter",     { fg = p.fg })
hi("SpecialComment",{ fg = p.dim, bold = true })
hi("Debug",         { fg = p.red })

hi("Underlined",    { fg = p.sky, underline = true })
hi("Ignore",        { fg = p.dim })
hi("Error",         { fg = p.red, bold = true })
hi("Todo",          { fg = p.bg, bg = p.gold, bold = true })

-- ---------------------------------------------------------------------------
-- Treesitter captures
-- ---------------------------------------------------------------------------
hi("@variable",              { fg = p.fg })
hi("@variable.builtin",      { fg = p.sky })
hi("@variable.parameter",    { fg = p.fg })
hi("@variable.member",       { fg = p.fg })

hi("@constant",              { fg = p.gold })
hi("@constant.builtin",      { fg = p.gold })
hi("@constant.macro",        { fg = p.lilac })

hi("@module",                { fg = p.lilac })
hi("@label",                 { fg = p.orange })

hi("@string",                { fg = p.str })
hi("@string.escape",         { fg = p.sky })
hi("@string.special",        { fg = p.sky })
hi("@string.regexp",         { fg = p.sky })
hi("@character",             { fg = p.str })
hi("@character.special",     { fg = p.sky })

hi("@number",                { fg = p.gold })
hi("@number.float",          { fg = p.gold })
hi("@boolean",               { fg = p.gold })

hi("@function",              { fg = p.periwinkle })
hi("@function.builtin",      { fg = p.periwinkle })
hi("@function.call",         { fg = p.periwinkle })
hi("@function.macro",        { fg = p.lilac })
hi("@function.method",       { fg = p.periwinkle })
hi("@function.method.call",  { fg = p.periwinkle })
hi("@constructor",           { fg = p.lilac })

hi("@keyword",               { fg = p.orange })
hi("@keyword.function",      { fg = p.orange })
hi("@keyword.operator",      { fg = p.orange })
hi("@keyword.import",        { fg = p.orange })
hi("@keyword.return",        { fg = p.orange })
hi("@keyword.conditional",   { fg = p.orange })
hi("@keyword.repeat",        { fg = p.orange })
hi("@keyword.exception",     { fg = p.red })
hi("@conditional",           { fg = p.orange })
hi("@repeat",                { fg = p.orange })

hi("@type",                  { fg = p.lilac })
hi("@type.builtin",          { fg = p.lilac })
hi("@type.definition",       { fg = p.lilac })
hi("@attribute",             { fg = p.sky })
hi("@property",              { fg = p.fg })
hi("@field",                 { fg = p.fg })

hi("@operator",              { fg = p.fg })
hi("@punctuation.delimiter", { fg = p.fg })
hi("@punctuation.bracket",   { fg = p.fg })
hi("@punctuation.special",   { fg = p.sky })

hi("@comment",               { fg = p.dim, italic = true })
hi("@comment.error",         { fg = p.bg, bg = p.red, bold = true })
hi("@comment.warning",       { fg = p.bg, bg = p.gold, bold = true })
hi("@comment.todo",          { fg = p.bg, bg = p.gold, bold = true })
hi("@comment.note",          { fg = p.bg, bg = p.sky, bold = true })

hi("@tag",                   { fg = p.orange })
hi("@tag.attribute",         { fg = p.gold })
hi("@tag.delimiter",         { fg = p.dim })

hi("@markup.heading",        { fg = p.orange, bold = true })
hi("@markup.strong",         { fg = p.gold, bold = true })
hi("@markup.italic",         { fg = p.lilac, italic = true })
hi("@markup.link",           { fg = p.sky, underline = true })
hi("@markup.link.url",       { fg = p.sky, underline = true })
hi("@markup.raw",            { fg = p.str })
hi("@markup.list",           { fg = p.orange })
hi("@markup.quote",          { fg = p.dim, italic = true })

hi("@diff.plus",             { fg = p.sage })
hi("@diff.minus",            { fg = p.red })
hi("@diff.delta",            { fg = p.gold })

-- ---------------------------------------------------------------------------
-- LSP / diagnostics
-- ---------------------------------------------------------------------------
hi("DiagnosticError",        { fg = p.red })
hi("DiagnosticWarn",         { fg = p.gold })
hi("DiagnosticInfo",         { fg = p.sky })
hi("DiagnosticHint",         { fg = p.lilac })
hi("DiagnosticOk",           { fg = p.sage })
hi("DiagnosticUnderlineError", { undercurl = true, sp = p.red })
hi("DiagnosticUnderlineWarn",  { undercurl = true, sp = p.gold })
hi("DiagnosticUnderlineInfo",  { undercurl = true, sp = p.sky })
hi("DiagnosticUnderlineHint",  { undercurl = true, sp = p.lilac })
hi("DiagnosticVirtualTextError", { fg = p.red, bg = p.bg_dim })
hi("DiagnosticVirtualTextWarn",  { fg = p.gold, bg = p.bg_dim })
hi("DiagnosticVirtualTextInfo",  { fg = p.sky, bg = p.bg_dim })
hi("DiagnosticVirtualTextHint",  { fg = p.lilac, bg = p.bg_dim })

hi("LspReferenceText",       { bg = p.bg_dim })
hi("LspReferenceRead",       { bg = p.bg_dim })
hi("LspReferenceWrite",      { bg = p.bg_dim, underline = true })
hi("LspSignatureActiveParameter", { fg = p.orange, bold = true })
hi("LspInlayHint",           { fg = p.dim, bg = p.bg_dim, italic = true })

-- ---------------------------------------------------------------------------
-- Diffs
-- ---------------------------------------------------------------------------
hi("DiffAdd",       { fg = p.sage, bg = p.bg_dim })
hi("DiffChange",    { fg = p.gold, bg = p.bg_dim })
hi("DiffDelete",    { fg = p.red, bg = p.bg_dim })
hi("DiffText",      { fg = p.bg, bg = p.gold })
hi("diffAdded",     { fg = p.sage })
hi("diffRemoved",   { fg = p.red })
hi("diffChanged",   { fg = p.gold })
hi("diffFile",      { fg = p.orange })
hi("diffLine",      { fg = p.sky })

-- ---------------------------------------------------------------------------
-- Plugins already in this config
-- ---------------------------------------------------------------------------
-- gitsigns.nvim
-- A git sign in the gutter drops the periwinkle stem back to solid black for
-- that cell, so the sage/gold/red +/~/_ glyphs read at full contrast instead of
-- washing out against the periwinkle. The stem stays periwinkle everywhere else.
hi("GitSignsAdd",      { fg = p.sage, bg = p.bg })
hi("GitSignsChange",   { fg = p.gold, bg = p.bg })
hi("GitSignsDelete",   { fg = p.red,  bg = p.bg })
-- signcolumn='number' merges signs into the number column; the *Nr variants
-- carry the same black-cell treatment so the colored glyph sits on black there too.
hi("GitSignsAddNr",    { fg = p.sage, bg = p.bg, bold = true })
hi("GitSignsChangeNr", { fg = p.gold, bg = p.bg, bold = true })
hi("GitSignsDeleteNr", { fg = p.red,  bg = p.bg, bold = true })

-- telescope.nvim
hi("TelescopeBorder",        { fg = p.orange, bg = p.bg })
hi("TelescopeTitle",         { fg = p.orange, bold = true })
hi("TelescopePromptBorder",  { fg = p.orange, bg = p.bg })
hi("TelescopePromptPrefix",  { fg = p.orange })
hi("TelescopeSelection",     { fg = p.fg, bg = p.bg_dim })
hi("TelescopeSelectionCaret",{ fg = p.orange })
hi("TelescopeMatching",      { fg = p.gold, bold = true })

-- aerial.nvim (outline)
hi("AerialLine",             { fg = p.fg, bg = p.bg_dim })
hi("AerialGuide",            { fg = p.dim })
hi("AerialNormal",           { fg = p.fg })

-- Spelling
hi("SpellBad",   { undercurl = true, sp = p.red })
hi("SpellCap",   { undercurl = true, sp = p.gold })
hi("SpellRare",  { undercurl = true, sp = p.lilac })
hi("SpellLocal", { undercurl = true, sp = p.sky })
