-- LCARS buffer-navigation row.
--
-- Rendered as a native `tabline` expression (not lualine's buffers component) so
-- we get full control: independent capped pills with black gaps like the kitty
-- tab bar, and the LCARS `NN-WORD` house style — zero-padded ordinal + dash +
-- name (e.g. `01-views.py`). Loaded for its side effects by lcars.statusline.
--
-- Active pill = periwinkle (matches the number-gutter stem so they connect),
-- non-selected = deep-sky, black text; rounded half-circle caps (U+E0B6 /
-- U+E0B4) drawn in the pill color on the black strip so the ends read as caps.

local p = require("lcars.palette")
-- Corner elbow (on by default; toggle via :LcarsCorner). Loading it registers the
-- command; render() below asks it for the left prefix only when it's active.
local chrome_ok, chrome = pcall(require, "lcars.chrome")

local CAP_L = "" -- U+E0B6 left half-circle cap
local CAP_R = "" -- U+E0B4 right half-circle cap

-- The bar itself is solid periwinkle (the swoop body). The selected buffer is
-- an orange chip (the LCARS "active" accent, matching the kitty active tab and
-- the statusline mode pill); non-selected buffers are deep-sky chips. Caps are
-- drawn in the chip color on the periwinkle bar so the ends read as caps.
local function set_hl()
  vim.api.nvim_set_hl(0, "LcarsBuf",       { fg = p.bg, bg = p.buf_off })
  vim.api.nvim_set_hl(0, "LcarsBufCap",    { fg = p.buf_off, bg = p.stem })
  vim.api.nvim_set_hl(0, "LcarsBufSel",    { fg = p.bg, bg = p.orange, bold = true })
  vim.api.nvim_set_hl(0, "LcarsBufSelCap", { fg = p.orange, bg = p.stem })
  vim.api.nvim_set_hl(0, "LcarsTabFill",   { fg = p.bg, bg = p.stem })
  -- Black negative space behind the experimental corner elbow: the elbow PNG's
  -- outer curve is transparent, so it needs a black (not periwinkle) backdrop or
  -- the rounded edge is invisible against the bar. Periwinkle resumes at the pills.
  vim.api.nvim_set_hl(0, "LcarsCornerBg",  { fg = p.bg, bg = p.bg })
end
set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

local M = {}

-- Click handler: bufnr arrives as the click region's minwid.
function M.goto_buf(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_set_current_buf(bufnr)
  end
end

function M.render()
  local cur = vim.api.nvim_get_current_buf()
  -- Start the first pill after the number-gutter of the current window, so the
  -- top-left strip (above the gutter) stays clear periwinkle bar for the elbow.
  local wi = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local pad = (wi and wi.textoff) or 0
  local pills = {}
  local ordinal = 0
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    ordinal = ordinal + 1
    local name = info.name ~= "" and vim.fn.fnamemodify(info.name, ":t") or "[No Name]"
    local modified = info.changed == 1 and " ●" or ""
    local label = string.format(" %02d-%s%s ", ordinal, name, modified)
    local sel = info.bufnr == cur
    local hl = sel and "LcarsBufSel" or "LcarsBuf"
    local cap = sel and "LcarsBufSelCap" or "LcarsBufCap"
    pills[#pills + 1] = table.concat({
      string.format("%%%d@v:lua.require'lcars.tabline'.goto_buf@", info.bufnr),
      "%#", cap, "#", CAP_L,
      "%#", hl, "#", label,
      "%#", cap, "#", CAP_R,
      "%X",
    })
  end
  -- Left edge: when the elbow is active, the corner's column span is BLACK negative
  -- space so the elbow (which sits on screen row 0) shows its rounded outer edge;
  -- periwinkle only resumes at the pills. Otherwise a plain gutter-width periwinkle
  -- pad so the first pill clears the number-gutter. Pills join with a 1-col
  -- periwinkle gap, rest of the strip filled with the bar color.
  local left
  if chrome_ok and chrome.active() then
    left = "%#LcarsCornerBg#" .. string.rep(" ", chrome.width())
  else
    left = "%#LcarsTabFill#" .. string.rep(" ", pad)
  end
  return left
    .. table.concat(pills, "%#LcarsTabFill# ")
    .. "%#LcarsTabFill#%="
end

vim.o.showtabline = 2
vim.o.tabline = "%!v:lua.require'lcars.tabline'.render()"

return M
