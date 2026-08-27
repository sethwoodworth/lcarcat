-- block_chips.lua — semantic shell chips → frame_renderer chip entries.
--
-- The shell (zsh/prompt_lcars.zsh) emits OSC 7337 naming what each chip
-- *means* — err, venv, py, aws, awsdep, git, gitstate — and pty_session parses
-- that into { kind = , label = } records. This module is the one place that
-- turns a kind into a color, so the LCARS palette stays a neovim concern and
-- the shell never has to know a highlight group name.
--
-- Header chips describe the environment the command ran in and come from the
-- shell. Footer chips describe the command itself — exit code, how long it took
-- — and are derived here from the finished block_record.
--
-- API:
--   M.from_osc(chips)         → { { label, hl_group, kind }, ... } header chips
--   M.duration_label(seconds) → short LCARS duration string, or nil
--   M.outcome(rec)            → footer chips for a finished block

local M = {}

-- Colors mirror the swoop bar's chip palette (see prompt_lcars.zsh:57-63) so a
-- block header and the standalone kitty prompt read as the same system.
local HL = {
  err      = "LcarsTermChipErr",
  venv     = "LcarsTermChipVenv",
  py       = "LcarsTermChipPy",
  aws      = "LcarsTermChipAws",
  awsdep   = "LcarsTermChipAwsDep",
  git      = "LcarsTermChipGit",
  gitstate = "LcarsTermChipGit",
  dur      = "LcarsTermChipDur",
}

-- An unknown kind still renders — a newer shell emitting a chip this nvim
-- doesn't know about should show up plainly, not vanish silently.
local FALLBACK_HL = "LcarsTermChipGit"

-- from_osc: pty_session chip records → frame_renderer chip_list entries.
-- Labels carry no padding; chips_block() adds its own single-space cushion.
-- The kind is kept as the third field: frame_renderer.fit_chips uses it as the
-- drop group when the bar is too narrow to hold every chip.
function M.from_osc(chips)
  local out = {}
  for _, c in ipairs(chips or {}) do
    if c.label and c.label ~= "" then
      out[#out + 1] = { c.label, HL[c.kind] or FALLBACK_HL, c.kind }
    end
  end
  return out
end

-- Below this, a command is not worth a duration chip: fast commands are the
-- overwhelming majority of prompts, and a chip on every one of them is noise.
--
-- Same knob and same default as the swoop bar's end-of-command timestamp line
-- (`CMD_DURATION_THRESHOLD`, in milliseconds — see prompt_lcars.zsh), so the two
-- surfaces agree on what counts as slow. Read from nvim's environment at load;
-- assign M.duration_threshold_ms directly to override at runtime.
M.duration_threshold_ms = tonumber(vim.env.CMD_DURATION_THRESHOLD) or 2000

-- duration_label: seconds → "12.4S" / "03-20M" / "01-05H", or nil when the
-- command finished faster than duration_threshold_ms.
function M.duration_label(sec)
  if not sec or sec * 1000 < M.duration_threshold_ms then return nil end
  if sec < 60 then
    return string.format("%.1fS", sec)
  elseif sec < 3600 then
    return string.format("%02d-%02dM", math.floor(sec / 60), math.floor(sec % 60))
  end
  return string.format("%02d-%02dH", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

-- outcome: the footer chip list for a block — what the command did, as opposed
-- to the header's "where it ran".
--
-- Order is left-to-right as drawn; footer_chips places them right-aligned, so
-- the ERR chip lands nearest the closing cap where the eye ends up.
--
-- A nonzero exit gets a red ERR chip rather than repainting the whole frame
-- red (see frame_hl in frame_renderer.lua). Exit code 0 gets no chip at all —
-- success is the default and needs no decoration. The duration chip appears
-- only past duration_threshold_ms, so a quick successful command yields an
-- empty footer, which is the point.
function M.outcome(rec)
  local out = {}
  if not rec then return out end

  local dur = M.duration_label(rec.duration)
  if dur then out[#out + 1] = { dur, HL.dur, "dur" } end

  if rec.exit_code and rec.exit_code ~= 0 then
    out[#out + 1] = { string.format("ERR-%02d", rec.exit_code), HL.err, "err" }
  end

  return out
end

return M
