-- LCARS tab-navigation row.
--
-- Rendered as a native `tabline` expression (not lualine's buffers component) so
-- we get full control: flat rectangular chips (no rounded caps) with 1-col gaps
-- on the periwinkle bar, and the LCARS `NN NAME` house style — zero-padded
-- ordinal + space + name (e.g. `01 views.py`). Loaded for its side effects by
-- lcars.statusline.
--
-- Enumerates nvim *tab pages* (matching gt / gT) not all listed buffers.
-- Active chip = orange (LCARS "active" accent), non-selected = deep-sky.

local p = require("lcars.palette")
-- Corner elbow (on by default; toggle via :LcarsCorner). Loading it registers the
-- command; render() below asks it for the left prefix only when it's active.
local chrome_ok, chrome = pcall(require, "lcars.chrome")

-- The bar itself is solid periwinkle (the swoop body). Chips are flat rectangles
-- on the periwinkle bar — no rounded caps.
local function set_hl()
  vim.api.nvim_set_hl(0, "LcarsBuf",      { fg = p.bg, bg = p.buf_off })
  vim.api.nvim_set_hl(0, "LcarsBufSel",   { fg = p.bg, bg = p.orange, bold = true })
  vim.api.nvim_set_hl(0, "LcarsTabFill",  { fg = p.bg, bg = p.stem })
  -- Black negative space behind the experimental corner elbow: the elbow PNG's
  -- outer curve is transparent, so it needs a black (not periwinkle) backdrop.
  vim.api.nvim_set_hl(0, "LcarsCornerBg", { fg = p.bg, bg = p.bg })
end
set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

local M = {}

-- Click handler: tabpagenr (1-based) arrives as the click region's minwid.
function M.goto_tab(tabnr)
  if tabnr >= 1 and tabnr <= vim.fn.tabpagenr("$") then
    vim.cmd(tabnr .. "tabnext")
  end
end

function M.render()
  local curtab = vim.fn.tabpagenr()
  local wi = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local pad = (wi and wi.textoff) or 0
  local chips = {}
  for tabnr = 1, vim.fn.tabpagenr("$") do
    local tabwin = vim.fn.tabpagewinnr(tabnr)
    local bufnr  = vim.fn.tabpagebuflist(tabnr)[tabwin]
    local name   = vim.fn.bufname(bufnr)
    name = (name ~= "" and vim.fn.fnamemodify(name, ":t")) or "[No Name]"
    local modified = vim.fn.getbufvar(bufnr, "&modified") == 1 and " ●" or ""
    local label = string.format(" %02d %s%s ", tabnr, name, modified)
    local sel = tabnr == curtab
    local hl = sel and "LcarsBufSel" or "LcarsBuf"
    chips[#chips + 1] = table.concat({
      string.format("%%%d@v:lua.require'lcars.tabline'.goto_tab@", tabnr),
      "%#", hl, "#", label,
      "%X",
    })
  end
  -- Left edge: when the elbow is active, the corner's column span is BLACK negative
  -- space so the elbow (which sits on screen row 0) shows its rounded outer edge;
  -- periwinkle only resumes at the chips. Otherwise a plain gutter-width periwinkle
  -- pad so the first chip clears the number-gutter. Chips join with a 1-col gap.
  local left
  if chrome_ok and chrome.active() then
    left = "%#LcarsCornerBg#" .. string.rep(" ", chrome.width())
  else
    left = "%#LcarsTabFill#" .. string.rep(" ", pad)
  end
  return left
    .. table.concat(chips, "%#LcarsTabFill# ")
    .. "%#LcarsTabFill#%="
end

vim.o.showtabline = 2
vim.o.tabline = "%!v:lua.require'lcars.tabline'.render()"

return M
