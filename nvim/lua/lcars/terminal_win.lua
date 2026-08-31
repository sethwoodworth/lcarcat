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

local frame_buffer     = require("lcars.frame_buffer")
local pty_session      = require("lcars.pty_session")
local term_input       = require("lcars.term_input")
local block_record     = require("lcars.block_record")
local block_chips      = require("lcars.block_chips")
local assets           = require("lcars.assets")
local alternate_screen = require("lcars.alternate_screen")

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

-- deploy.sh copies the zsh half to ~/.config/zsh and the nvim half to
-- ~/.config/nvim, and nothing makes you update both. A stale pair used to be
-- invisible: an old nvim just shows no chips, which looks exactly like a shell
-- that never emitted any. The version on the wire makes the two cases
-- distinguishable, so say so — once per session, and then render anyway,
-- because a skewed deploy should be visible rather than fatal.
local _warned_skew = false
local function warn_once_on_protocol_skew(version)
  if _warned_skew or version == nil then return end
  local mine = pty_session.PROTOCOL_VERSION
  if version == mine then return end
  _warned_skew = true
  local detail
  if version == 0 then
    detail = ("the shell prompt predates OSC 7447 versioning (this nvim speaks v%d)"):format(mine)
  elseif version < mine then
    detail = ("the shell prompt speaks OSC 7447 v%d, this nvim speaks v%d"):format(version, mine)
  else
    detail = ("the shell prompt speaks OSC 7447 v%d, newer than this nvim's v%d"):format(version, mine)
  end
  vim.notify(
    "lcars: " .. detail .. ". The zsh and nvim halves are out of sync — re-run deploy.sh. "
      .. "Chips will still render, best-effort.",
    vim.log.levels.WARN
  )
end

-- True from the moment the frame's images come down for a full-screen program
-- until they go back up. The guard is what makes restoring idempotent: the
-- escape-hatch command, a real ESC[?1049l arriving afterwards, and session
-- teardown can all call restore_frame_view() and only the first one acts.
local _frame_hidden = false

local function restore_frame_view()
  alternate_screen.exit()
  if not _frame_hidden then return end
  _frame_hidden = false
  if not session_active() then return end

  local _, _, content_width = geometry(state.display_win)
  pty_session.resize(content_width, vim.api.nvim_win_get_height(state.display_win))
  frame_buffer.show_images()
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.api.nvim_set_current_win(state.input_win)
  end
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
    on_chips = function(chips, version)
      warn_once_on_protocol_skew(version)
      if state.rec then state.rec.chips = block_chips.from_osc(chips) end
    end,

    -- ESC[?1049h — a full-screen program (vim, less, fzf) took the screen.
    -- Hide the frame's images before the float goes up: kitty draws graphics
    -- over the terminal grid, and image.nvim cannot tell it has been covered
    -- because the display window's buffer never changed.
    on_alternate_screen_enter = function()
      fb.hide_images()
      _frame_hidden = true
      local columns, rows = alternate_screen.enter({
        on_input = pty_session.send_raw,
        -- The float was closed by hand while the program still owns the PTY.
        -- Put the frame back so the session is not left headless, but stay in
        -- passthrough: dropping the program's bytes is silent and reversible,
        -- whereas letting its redraws into the frame would write escape
        -- sequences into the block history for good.
        on_close = function()
          restore_frame_view()
          vim.notify(
            "lcars: the alternate-screen window was closed while the program was still running. "
              .. "Its output is being discarded — run :LcarsTermExitAlternateScreen once it has "
              .. "exited to resync the session.",
            vim.log.levels.WARN
          )
        end,
      })
      -- The PTY was sized to the frame's narrow content width; the program is
      -- drawing into a full-tab float. Tell it so, or it formats to a screen
      -- that isn't there.
      if columns and rows then pty_session.resize(columns, rows) end
    end,

    -- Raw bytes while the alternate screen is up. A no-op once the float is
    -- gone, which is what makes :LcarsTermExitAlternateScreen safe to use on a
    -- program that is still alive — its output is dropped, not dumped into
    -- the frame as garbage lines.
    on_passthrough = function(bytes)
      if alternate_screen.active() then alternate_screen.feed(bytes) end
    end,

    -- ESC[?1049l — primary screen restored. Idempotent: the escape-hatch
    -- command may have already closed the float.
    on_alternate_screen_exit = function()
      restore_frame_view()
    end,

    -- The shell itself died (exit, kill). Anything on the alternate screen
    -- died with it, so don't leave its float on top of a dead session.
    on_exit = function()
      restore_frame_view()
    end,
  }
end

-- Closing either window tears down the whole session: stop the PTY job and
-- close the sibling window too, so a half-open layout is never left behind.
local function on_win_closed(args)
  local closed_win = tonumber(args.match)
  local other = (closed_win == state.display_win) and state.input_win or state.display_win

  -- A full-screen program's float must never outlive the session that feeds
  -- it — it would sit there taking keystrokes with nowhere to send them.
  alternate_screen.exit()
  _frame_hidden = false

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

-- Escape hatch for a full-screen program that died without restoring the
-- primary screen (a crash, a kill -9) — without this the session is stuck
-- behind a float, swallowing every byte the shell writes.
--
-- It resyncs our view only; it does not signal the child. If the program is in
-- fact still running, its output resumes flowing into the frame as raw escape
-- sequences, so say so rather than letting that look like a new bug.
vim.api.nvim_create_user_command("LcarsTermExitAlternateScreen", function()
  local was_passthrough = pty_session.leave_alternate_screen()
  restore_frame_view()
  if was_passthrough then
    vim.notify(
      "lcars: left alternate-screen passthrough. The program was never told to quit — "
        .. "if it is still running, its output will now land in the frame as raw escapes.",
      vim.log.levels.WARN
    )
  else
    vim.notify("lcars: no alternate-screen program was active.", vim.log.levels.INFO)
  end
end, {})

return M
