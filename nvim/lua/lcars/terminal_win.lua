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
local block_chips   = require("lcars.block_chips")
local assets        = require("lcars.assets")

local AUGROUP = "LcarsTerminalWin"

-- Frame geometry, in window cols from window-left (0-indexed, gutter included —
-- same convention as frame_renderer).
--
--   lp .. lp+bw-1     the header/footer bar
--   lp+2 .. lp+bw-1   content text (frame_buffer writes an lp+1-space prefix in
--                     buffer cols, which is lp+2 in window cols)
--
-- BAR_MARGIN is the slice of the window the bar does not use, reserving room
-- for the header elbow + right cap images.
local LP         = 6
local BAR_MARGIN = 14

-- geometry(win) → lp, bw, content_width
--
-- content_width is what the PTY must be told (COLUMNS / TIOCGWINSZ): the number
-- of columns a content line can occupy before it runs past the bar's right edge.
-- The display window has wrap=false, so anything wider is clipped off-screen
-- rather than wrapping (lcarcat-wve).
local function geometry(win)
  local bw = vim.api.nvim_win_get_width(win) - BAR_MARGIN
  return LP, bw, bw - 2
end

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
    -- OSC 133;A. The record is created here — on_cwd and on_chips both arrive
    -- while the prompt is drawing, before the command is known — but the block
    -- is deliberately NOT rendered yet. See on_command_exec (lcarcat-ba0).
    on_prompt_start = function()
      state.rec = block_record.new(next_id())
      state.rec.state = "live"
    end,

    -- OSC 133;C. This, not 133;A, is where the block appears.
    --
    -- Opening at prompt time left an empty header sitting on screen for as long
    -- as you took to type, and — since M.submit() sets rec.command after the
    -- header had already rendered — with a blank command line for the whole run
    -- of the command, filled in only at close_block. Deferring to 133;C means
    -- rec.command and rec.chips are both populated by the time render_header
    -- runs, so the header is drawn once, correct. A prompt that never runs a
    -- command (bare Enter, Ctrl-C) now leaves no orphan frame behind.
    on_command_exec = function()
      if not state.rec then return end
      state.rec.command_start = vim.uv.hrtime() / 1e9
      fb.open_block(state.rec)
      scroll_display_to_end(fb)
    end,

    -- rec.buf_start is set by open_block, so it doubles as "the block is on
    -- screen" — output arriving before 133;C has nowhere to go.
    on_output_line = function(line)
      if state.rec and state.rec.buf_start then
        fb.append_line(state.rec, line)
        scroll_display_to_end(fb)
      end
    end,

    on_command_done = function(exit_code)
      if not state.rec then return end
      if not state.rec.buf_start then
        -- 133;D with no preceding 133;C: nothing was ever rendered, so there is
        -- no frame to close. Drop the record rather than closing a phantom.
        state.rec = nil
        return
      end
      state.rec.command_end = vim.uv.hrtime() / 1e9
      state.rec.duration    = state.rec.command_end - state.rec.command_start
      state.rec.state       = (exit_code == 0) and "done" or "failed"
      state.rec.exit_code   = exit_code
      -- Duration and exit code are drawn as footer chips, built from the
      -- record by block_chips.outcome() inside render_footer — nothing to
      -- attach here.
      fb.close_block(state.rec)
      scroll_display_to_end(fb)
      state.rec = nil
    end,

    -- OSC 7 carries an absolute path. Shorten $HOME to "~" via fnamemodify
    -- rather than a hardcoded prefix, so the hole chip stays correct for any
    -- user on any machine.
    on_cwd = function(path)
      if state.rec then state.rec.cwd = vim.fn.fnamemodify(path, ":~") end
    end,

    -- OSC 7447 — branch/venv/py/aws chips computed by the shell's precmd.
    on_chips = function(chips)
      if state.rec then state.rec.chips = block_chips.from_osc(chips) end
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
  local lp, bw, content_width = geometry(display_win)
  local ns     = vim.api.nvim_create_namespace("lcars_terminal_win")

  frame_buffer.new({ ns = ns, lp = lp, bw = bw, win = display_win, cw = cw, ch = ch })
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

  local shell_cmd  = vim.env.SHELL or "/bin/zsh"
  local shell_name = vim.fn.fnamemodify(shell_cmd, ":t")

  term_input.open(input_buf, {
    win        = input_win,
    on_submit  = M.submit,
    min_height = 4,
    max_height = 10,
    filetype   = (shell_name == "zsh" or shell_name == "bash") and shell_name or "sh",
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

  -- Real frame geometry, not pty_session's 220x50 default, so the PTY matches
  -- actual screen size from the start. Width is the frame's content width, not
  -- the raw window width: tools that size their output from COLUMNS (`ls`
  -- columns, `git log --graph` wrapping) must fit between the stem and the
  -- bar's right edge. Height stays the raw window height — the frame's chrome
  -- eats rows too, but nothing scrolls the PTY's own screen yet, and a short
  -- height would only shrink full-screen apps we don't support (lcarcat-wve).
  -- Dynamic resize on VimResized is deferred (lcarcat-qm0.5).
  local height = vim.api.nvim_win_get_height(display_win)

  pty_session.start(
    shell_cmd,
    { width = content_width, height = height },
    make_callbacks(frame_buffer)
  )

  vim.api.nvim_set_current_win(input_win)
end

vim.api.nvim_create_user_command("LcarsTerm", function() M.open() end, {})

return M
