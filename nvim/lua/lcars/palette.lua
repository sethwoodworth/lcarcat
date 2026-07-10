-- LCARS palette — single source of truth for the neovim theme.
-- Values mirror the finalized LCARS set used elsewhere in lcarcat:
--   zsh/prompt_lcars.zsh:25-34  (prompt chips)
--   kitty/lcars.conf:12-37      (terminal 16-color + chrome)
-- Kept in sync with those by hand; there is no cross-language import.

return {
  -- Core canvas
  bg       = "#000000", -- black background (universal LCARS canvas)
  bg_dim   = "#0a0a0a", -- barely-lifted black for CursorLine / subtle fills
  fg       = "#ffffc6", -- pale canary (default foreground, never white)

  -- Accents (semantic roles carried over from the prompt/tab-bar chrome)
  orange   = "#ff9900", -- atomic tangerine — primary bar accent, keywords
  gold     = "#ffcc66", -- git/branch chip, numbers/constants
  lilac    = "#cc99cc", -- venv chip, types/classes
  sky      = "#6699cc", -- python chip, info
  periwinkle = "#9999ff", -- selection bg, function calls
  red      = "#ff3300", -- red-alert — errors, failure LED
  sage     = "#99cc99", -- success LED, diff-add, directories
  str      = "#ffcc99", -- warm white — string literals (color7)
  dim      = "#666699", -- dim gray-violet — comments (color8)
  dim2     = "#78788c", -- dimmer gray — timestamps, non-text/whitespace
  cursor   = "#cc6699", -- magenta cursor (matches kitty)

  -- The vertical "stem": the line-number gutter is painted periwinkle so it
  -- reads as a solid LCARS stem connecting the top buffer bar (active pill is
  -- the same periwinkle) to the bottom statusline — and so a periwinkle elbow
  -- image flows into it later. Orange stays the keyword/accent color elsewhere.
  stem     = "#9999ff", -- == periwinkle; gutter background & active buffer pill
  stem_dim = "#5c5c99", -- recessive number text on the periwinkle stem
  buf_off  = "#6699cc", -- non-selected buffer pills (deep-sky, recessive)
}
