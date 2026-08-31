-- alternate_screen.lua — a real terminal emulator on top of the LCARS frame,
-- for the span of one full-screen program.
--
-- API:
--   M.enter(opts)   opts = { on_input = fn(bytes), on_close = fn() } → columns, rows
--   M.feed(bytes)   push raw PTY bytes into the emulator
--   M.exit()        close the float, close the channel, wipe the buffer
--   M.active()      is a full-screen program on screen right now
--   M.size()        columns, rows of the live float (nil when inactive)
--
-- Why not `:terminal`. The full-screen program is already running on the PTY
-- pty_session owns; `:terminal` would spawn a second, unrelated one. The
-- mechanism that works is nvim_open_term(), which attaches nvim's VT220
-- emulator to a scratch buffer we feed with nvim_chan_send, with on_input
-- routing terminal-mode keystrokes back to the PTY we already have. This is
-- the escape-hatch path sketched in docs/nvim-terminal-frame.md (lcarcat-xi4).
--
-- Why a float and not the display window. Covering the tab leaves the frame,
-- its input split, and every block's extmark state untouched underneath —
-- there is no layout to rebuild on the way out. The cost is that image.nvim
-- does not know it is covered (the display window's buffer never changed), so
-- the caller must hide the frame's elbow/cap images itself; kitty composites
-- graphics over the terminal grid and they would otherwise paint on top of the
-- program. frame_buffer.hide_images()/show_images() do that.

local M = {}

local state = {
  buf     = nil,
  win     = nil,
  channel = nil,
  resumable_chrome = nil,
}

-- The surrounding LCARS chrome — the tabline corner, the window rails, the
-- statusline elbow — is placed at absolute screen coordinates, so a float on
-- top does not disturb it and kitty happily composites it over the program.
-- Both modules expose the same enabled/enable/disable contract, so suspending
-- them is uniform. Only the ones that were actually on get turned back on.
local CHROME_MODULES = { "lcars.chrome", "lcars.terminal_frame" }

local function suspend_chrome()
  local resumable = {}
  for _, name in ipairs(CHROME_MODULES) do
    local ok, module = pcall(require, name)
    if ok and module.enabled then
      resumable[#resumable + 1] = module
      pcall(module.disable)
    end
  end
  return resumable
end

local function resume_chrome(resumable)
  for _, module in ipairs(resumable or {}) do
    pcall(module.enable)
  end
end

function M.active()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.size()
  if not M.active() then return nil end
  return vim.api.nvim_win_get_width(state.win), vim.api.nvim_win_get_height(state.win)
end

-- Open a full-tab float running nvim's terminal emulator, focused and in
-- terminal mode. Returns the emulator's size in columns and rows so the caller
-- can tell the PTY what the program is actually drawing into.
function M.enter(opts)
  opts = opts or {}
  if M.active() then return M.size() end

  state.resumable_chrome = suspend_chrome()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false

  -- nvim sizes the emulator from the window showing the buffer, so the float
  -- must exist before anything is fed in. Cover the whole editor, not the
  -- display window: a full-screen program expects a full screen.
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = 0,
    col       = 0,
    width     = vim.o.columns,
    height    = vim.o.lines - vim.o.cmdheight,
    style     = "minimal",
    border    = "none",
    zindex    = 200,
  })

  state.buf = buf
  state.win = win

  state.channel = vim.api.nvim_open_term(buf, {
    on_input = function(_, _, _, data)
      if opts.on_input then opts.on_input(data) end
    end,
  })

  -- Strip the window down to bare screen, after nvim_open_term rather than
  -- before. Two things paint an LCARS stem down the left of the program
  -- otherwise: nvim_open_win copies window-local options from whatever window
  -- was current — the input panel, whose winhighlight maps SignColumn to the
  -- orange stem — and terminal_frame's TermOpen hook forces signcolumn=yes:1
  -- on every terminal buffer, which fires during nvim_open_term. A full-screen
  -- program gets the full screen: no gutter, no stem, no highlight overrides.
  vim.wo[win].winhighlight   = ""
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].foldcolumn     = "0"
  vim.wo[win].list           = false
  vim.wo[win].cursorline     = false

  -- A float closed by hand (:q, :close, a config that maps <Esc> out of
  -- terminal mode followed by an Ex command) would otherwise strand the
  -- session: chrome still suspended, block images still hidden, and no window
  -- left to show the program that is very much still running. M.exit() clears
  -- state.win before closing, so this only fires for a close we did not start.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function()
      if state.win ~= win then return end
      state.win = nil
      M.exit()
      if opts.on_close then opts.on_close() end
    end,
  })

  -- Terminal mode, so keystrokes reach on_input rather than nvim's normal-mode
  -- commands. <C-\><C-n> still leaves it — that is nvim's own binding and
  -- wants no wiring here.
  vim.cmd("startinsert")

  return M.size()
end

function M.feed(bytes)
  if state.channel then
    vim.api.nvim_chan_send(state.channel, bytes)
  end
end

-- Tear down in the order that avoids nvim complaining about a channel with a
-- live buffer: window first (bufhidden=wipe takes the buffer with it), then
-- the channel.
function M.exit()
  local win, channel, chrome = state.win, state.channel, state.resumable_chrome
  state.buf, state.win, state.channel, state.resumable_chrome = nil, nil, nil, nil

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if channel then
    pcall(vim.fn.chanclose, channel)
  end
  -- After the float is gone, so chrome measures the layout it is drawing into.
  resume_chrome(chrome)
end

return M
