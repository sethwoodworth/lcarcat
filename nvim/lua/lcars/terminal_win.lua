-- terminal_win.lua — layout manager wiring frame_buffer, pty_session, and
-- term_input into :LcarsTerm.
--
-- Single-session only (multi-session support deferred: lcarcat-3ft). A
-- second :LcarsTerm while a session is live just refocuses the existing
-- input window instead of starting another PTY.
--
-- See "Wiring notes for terminal_win.lua" in docs/nvim-terminal-frame.md for
-- the full callback contract and submission flow this module implements.

local M = {}

local frame_buffer  = require("lcars.frame_buffer")
local pty_session   = require("lcars.pty_session")
local term_input    = require("lcars.term_input")
local block_record  = require("lcars.block_record")
local assets        = require("lcars.assets")

local AUGROUP = "LcarsTerminalWin"

local _next_id = 0
local function next_id()
  _next_id = _next_id + 1
  return _next_id
end

-- Single live session's state. rec is the current in-flight block_record
-- (nil between commands).
local state = {
  display_win = nil,
  input_win   = nil,
  rec         = nil,
}

local function session_active()
  return state.display_win ~= nil and vim.api.nvim_win_is_valid(state.display_win)
end

-- terminal_win.submit: the on_submit wrapper handed to term_input.open().
-- Sets rec.command on the current live block_record before forwarding to
-- the PTY, so the command text is available when frame_buffer re-renders
-- the header on close.
function M.submit(cmd_text)
  if state.rec then
    state.rec.command = cmd_text
  end
  pty_session.send(cmd_text)
end

-- Tail the display window to the newest content, like a real terminal.
-- Images (elbow/cap PNGs from frame_renderer/image_registry) are bound to
-- (window, buffer, buffer-row) via image.nvim's from_file() options, so
-- image.nvim's own internal autocmds keep them in sync with scrolling and
-- buffer switches automatically (lcarcat-382 — fixed at the placement
-- layer, not here).
local function scroll_display_to_end(fb)
  if not (state.display_win and vim.api.nvim_win_is_valid(state.display_win)) then return end
  local last = vim.api.nvim_buf_line_count(fb.buf)
  vim.api.nvim_win_set_cursor(state.display_win, { last, 0 })
end

local function make_callbacks(fb)
  return {
    on_prompt_start = function()
      state.rec = block_record.new(next_id())
      state.rec.state = "live"
      fb.open_block(state.rec)
      scroll_display_to_end(fb)
    end,

    on_command_exec = function()
      if state.rec then
        state.rec.command_start = vim.uv.hrtime() / 1e9
      end
    end,

    on_output_line = function(line)
      if state.rec then
        fb.append_line(state.rec, line)
        scroll_display_to_end(fb)
      end
    end,

    on_command_done = function(exit_code)
      if not state.rec then return end
      state.rec.command_end = vim.uv.hrtime() / 1e9
      state.rec.duration    = state.rec.command_end - state.rec.command_start
      state.rec.state       = (exit_code == 0) and "done" or "failed"
      state.rec.exit_code   = exit_code
      fb.close_block(state.rec)
      scroll_display_to_end(fb)
      state.rec = nil
    end,

    on_cwd = function(path)
      if state.rec then state.rec.cwd = path end
    end,
  }
end

-- Closing either window tears down the whole session: stop the PTY job and
-- close the sibling window too, so a half-open layout is never left behind.
local function on_win_closed(args)
  local closed_win = tonumber(args.match)
  local other = (closed_win == state.display_win) and state.input_win or state.display_win

  pty_session.stop()
  state.rec         = nil
  state.display_win = nil
  state.input_win   = nil

  if other and vim.api.nvim_win_is_valid(other) then
    vim.schedule(function()
      pcall(vim.api.nvim_win_close, other, true)
    end)
  end
end

function M.open()
  if session_active() then
    vim.api.nvim_set_current_win(state.input_win)
    return
  end

  vim.cmd("tabnew")
  local display_win = vim.api.nvim_get_current_win()

  local cw, ch = assets.cell_px()
  local bw     = vim.api.nvim_win_get_width(display_win) - 14
  local ns     = vim.api.nvim_create_namespace("lcars_terminal_win")

  frame_buffer.new({ ns = ns, lp = 6, bw = bw, win = display_win, cw = cw, ch = ch })
  vim.api.nvim_win_set_buf(display_win, frame_buffer.buf)
  vim.api.nvim_buf_set_name(frame_buffer.buf, "lcars://terminal_win/display")

  vim.wo[display_win].number         = false
  vim.wo[display_win].relativenumber = false
  vim.wo[display_win].signcolumn     = "no"
  vim.wo[display_win].foldcolumn     = "0"
  vim.wo[display_win].wrap           = false
  vim.wo[display_win].cursorline     = false
  vim.wo[display_win].list           = false

  vim.cmd("belowright split")
  local input_win = vim.api.nvim_get_current_win()
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype  = "nofile"
  vim.bo[input_buf].swapfile = false
  vim.api.nvim_win_set_buf(input_win, input_buf)
  vim.api.nvim_buf_set_name(input_buf, "lcars://terminal_win/input")

  term_input.open(input_buf, {
    win        = input_win,
    on_submit  = M.submit,
    min_height = 4,
    max_height = 10,
  })

  state.display_win = display_win
  state.input_win    = input_win

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = group,
    pattern  = { tostring(display_win), tostring(input_win) },
    callback = on_win_closed,
  })

  -- Elbow/cap images don't follow horizontal scroll (only WinScrolled's
  -- vertical repositioning is handled upstream), so pin leftcol at 0 to
  -- keep the frame from ever scrolling sideways out from under them.
  -- Long unwrapped output lines can still trigger a scroll attempt
  -- (tracked separately for output-width handling); this just snaps it
  -- back immediately.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group    = group,
    pattern  = { tostring(display_win) },
    callback = function()
      if not vim.api.nvim_win_is_valid(display_win) then return end
      if vim.api.nvim_win_call(display_win, function() return vim.fn.winsaveview().leftcol end) ~= 0 then
        vim.api.nvim_win_call(display_win, function() vim.fn.winrestview({ leftcol = 0 }) end)
      end
    end,
  })

  -- Real window geometry, not pty_session's 220x50 default, so the PTY
  -- matches actual screen size from the start. Dynamic resize on
  -- VimResized is deferred (lcarcat-qm0.5).
  local width  = vim.api.nvim_win_get_width(display_win)
  local height = vim.api.nvim_win_get_height(display_win)

  pty_session.start(
    vim.env.SHELL or "/bin/zsh",
    { width = width, height = height },
    make_callbacks(frame_buffer)
  )

  vim.api.nvim_set_current_win(input_win)
end

vim.api.nvim_create_user_command("LcarsTerm", function() M.open() end, {})

return M
