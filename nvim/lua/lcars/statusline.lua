-- LCARS statusline (lualine).
-- Flat blocks + pipe-separated right cluster, all-caps, no nerd-font icons —
-- matching the mockup's `UNIX | UTF-8 | PYTHON | LINE 76/586, COL 000` and the
-- lcarcat house style (spell words out, geometric not iconographic).

local lualine = require("lualine")
local p = require("lcars.palette")

-- LCARS buffer-navigation row (native tabline; sets vim.o.tabline itself).
require("lcars.tabline")
-- Experimental corner elbow: when active, the bottom-left elbow occupies a slightly
-- wider column span than the raw gutter, so the mode pill must clear that instead.
local chrome_ok, chrome = pcall(require, "lcars.chrome")

-- LINE cur/total, COL nnn — LCARS long-form, leading-zero column.
local location = function()
  return string.format(
    "LINE %d/%d, COL %03d",
    vim.fn.line("."),
    vim.fn.line("$"),
    vim.fn.col(".")
  )
end

-- Left-pad the bar past the number-gutter (same width the tabline uses) so the
-- mode pill aligns under the first buffer pill and the bottom-left corner stays
-- clear periwinkle bar for the eventual elbow/swoop.
local gutter_pad = function()
  if chrome_ok and chrome.active() then
    return string.rep(" ", chrome.width())
  end
  local wi = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  return string.rep(" ", (wi and wi.textoff) or 4)
end

lualine.setup({
  options = {
    theme = "lcars",
    icons_enabled = false,
    globalstatus = true,
    component_separators = { left = "|", right = "|" },
    section_separators = { left = "", right = "" },
    disabled_filetypes = { statusline = { "aerial" } },
  },
  sections = {
    lualine_a = {
      { gutter_pad, color = { fg = p.stem, bg = p.stem }, padding = 0 },
      { "mode", fmt = string.upper },
    },
    lualine_b = {
      { "branch", icon = "" },
      { "diff", symbols = { added = "+", modified = "~", removed = "-" } },
    },
    lualine_c = {
      { "filename", path = 1 },
      {
        "diagnostics",
        symbols = { error = "E", warn = "W", info = "I", hint = "H" },
      },
    },
    lualine_x = {
      { "fileformat", fmt = string.upper },
      { "encoding", fmt = string.upper },
      { "filetype", fmt = string.upper },
    },
    lualine_y = {},
    lualine_z = { location },
  },
  inactive_sections = {
    lualine_a = {},
    lualine_b = {},
    lualine_c = { { "filename", path = 1 } },
    lualine_x = { location },
    lualine_y = {},
    lualine_z = {},
  },
  extensions = { "aerial", "fugitive", "lazy" },
})
