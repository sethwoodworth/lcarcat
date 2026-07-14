-- lualine theme: lcars
-- Auto-discovered by lualine at lua/lualine/themes/lcars.lua on runtimepath.
-- The bar is a solid periwinkle strip (matching the buffer bar and number-gutter
-- stem, for the eventual swoop). The mode pill (section a, mirrored to z) is the
-- one accent: black text on the mode's color. Section b holds the git status
-- (branch + diff); it drops to a solid black notch so the branch/diff glyphs read
-- at full contrast instead of washing out on the periwinkle. Section c (filename)
-- stays black-on-periwinkle.

local p = require("lcars.palette")

local pill = function(accent) return { fg = p.bg, bg = accent, gui = "bold" } end
local b_seg = { fg = p.gold, bg = p.bg }
local c_seg = { fg = p.bg, bg = p.stem }

local function mode(accent)
  return { a = pill(accent), b = b_seg, c = c_seg }
end

return {
  normal   = mode(p.orange),
  insert   = mode(p.sage),
  visual   = mode(p.lilac),
  replace  = mode(p.red),
  command  = mode(p.gold),
  inactive = {
    a = { fg = p.dim, bg = p.bg_dim, gui = "bold" },
    b = { fg = p.dim, bg = p.bg },
    c = { fg = p.dim, bg = p.bg },
  },
}
