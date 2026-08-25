-- frame_buffer.lua — single display buffer owning an ordered list of block_records
--
-- API:
--   M.new(opts)              → initializes buffer and module state; opts: ns, lp, bw, win, cw, ch
--   M.open_block(rec)        → 1 blank separator row (non-first blocks) + header (3 rows);
--                              stores rec.buf_start (first header row)
--   M.append_line(rec, text) → appends one baleia-colored content line with stem extmark
--   M.close_block(rec)       → clears header extmarks, re-renders header (duration chip),
--                              renders footer, recolors stem extmarks, places images;
--                              stores rec.buf_end (footer row)
--   M.buf                    → nvim buffer number (for display in a window)

local M = {}

local renderer = require("lcars.frame_renderer")

local ok_baleia, baleia_mod = pcall(require, "baleia")
local baleia = ok_baleia and baleia_mod.setup({ async = false, strip_ansi_codes = true }) or nil

local STEM_W   = 1
local GUTTER_W = 1
local HL_PRI   = 200

local function stem_hl(state)
  if state == "live"   then return "LcarsTermStemLive"   end
  if state == "failed" then return "LcarsTermStemFailed" end
  return "LcarsTermBar"
end

M.buf    = nil
M.blocks = {}

local _ns  = nil
local _lp  = 6
local _bw  = 60
local _win = nil
local _cw  = nil
local _ch  = nil
local _row = 0

function M.new(opts)
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false

  M.buf    = buf
  M.blocks = {}
  _ns      = opts.ns or vim.api.nvim_create_namespace("lcars_frame_buffer")
  _lp      = opts.lp or 6
  _bw      = opts.bw or 60
  _win     = opts.win
  _cw      = opts.cw
  _ch      = opts.ch
  _row     = 0

  return M
end

-- open_block: 1 blank separator row (all blocks after the first) + header (3 rows).
-- rec.buf_start is set to the first header row (not the separator).
function M.open_block(rec)
  -- Inter-block blank separator (not added before the very first block).
  if #M.blocks > 0 then
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, _row, _row, false, { "" })
    vim.bo[M.buf].modifiable = false
    _row = _row + 1
  end

  rec.buf_start   = _row
  rec._stem_marks = {}
  M.blocks[#M.blocks + 1] = rec

  renderer.render_header(M.buf, _row, rec, { ns = _ns, lp = _lp, bw = _bw })
  _row = _row + 3

  -- Place header images immediately so live blocks also get their elbow/vcap.
  -- place_images skips footer images when state == "live".
  local r_opts = {
    ns  = _ns, lp = _lp, bw = _bw,
    win = _win or vim.api.nvim_get_current_win(),
    cw  = _cw, ch  = _ch,
    image_key_prefix = tostring(M.buf) .. "_" .. tostring(rec.buf_start),
  }
  renderer.place_images(M.buf, rec.buf_start, nil, rec, r_opts)
end

-- append_line: writes one ANSI-colored content line via baleia; adds stem extmark.
-- Extmark ID stored in rec._stem_marks for recoloring in close_block.
function M.append_line(rec, text)
  if not baleia then
    vim.notify("lcars.frame_buffer: baleia.nvim not available", vim.log.levels.WARN)
    return
  end

  local row    = _row
  local prefix = string.rep(" ", _lp + 1)

  vim.bo[M.buf].modifiable = true
  baleia.buf_set_lines(M.buf, row, row, false, { prefix .. text })
  vim.bo[M.buf].modifiable = false

  local mark_id = vim.api.nvim_buf_set_extmark(M.buf, _ns, row, _lp - GUTTER_W, {
    end_col  = _lp - GUTTER_W + STEM_W,
    hl_group = stem_hl(rec.state),
    priority = HL_PRI,
    strict   = false,
  })
  rec._stem_marks[#rec._stem_marks + 1] = mark_id

  rec.lines[#rec.lines + 1] = text
  rec.line_count = rec.line_count + 1
  _row = _row + 1
end

-- close_block: clears header extmarks, re-renders header (final state/duration),
-- writes 1-row footer, recolors content stem extmarks, places images.
function M.close_block(rec)
  local r_opts = {
    ns  = _ns,
    lp  = _lp,
    bw  = _bw,
    win = _win or vim.api.nvim_get_current_win(),
    cw  = _cw,
    ch  = _ch,
    image_key_prefix = tostring(M.buf) .. "_" .. tostring(rec.buf_start),
  }

  -- Clear header extmarks before re-render to avoid duplicate cmd text / chips.
  vim.api.nvim_buf_clear_namespace(M.buf, _ns, rec.buf_start, rec.buf_start + 3)

  renderer.render_header(M.buf, rec.buf_start, rec, r_opts)
  renderer.render_footer(M.buf, _row, rec, r_opts)
  rec.buf_end = _row
  _row = _row + 1

  -- Recolor content stem extmarks to match final state.
  local shl = stem_hl(rec.state)
  for _, id in ipairs(rec._stem_marks or {}) do
    local info = vim.api.nvim_buf_get_extmark_by_id(M.buf, _ns, id, { details = true })
    if info and info[3] then
      vim.api.nvim_buf_set_extmark(M.buf, _ns, info[1], info[2], {
        id       = id,
        end_col  = info[3].end_col,
        hl_group = shl,
        priority = HL_PRI,
        strict   = false,
      })
    end
  end

  -- Clear cached header images so the re-placement uses the final state color.
  renderer.clear_images(M.buf, rec.buf_start, r_opts)
  renderer.place_images(M.buf, rec.buf_start, rec.buf_end, rec, r_opts)
end

return M
