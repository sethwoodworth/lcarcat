-- term_input_test.lua — standalone fixture for lcars.term_input (lcarcat-lyz)
--
-- terminal_win.lua (lcarcat-2z9) doesn't exist yet, so this fixture stands in
-- for it: creates the split + buffer itself and wires
-- on_submit = pty_session.send directly, proving the input->PTY path
-- executes in a real shell end-to-end. No framed display here —
-- frame_buffer/block_record aren't wired into this fixture.

for _, mod in ipairs({ 'lcars.term_input', 'lcars.pty_session', 'lcars.palette' }) do
  package.loaded[mod] = nil
end

local term_input  = require('lcars.term_input')
local pty_session = require('lcars.pty_session')

vim.cmd('tabnew')
local display_win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(vim.api.nvim_win_get_buf(display_win), 'lcars://test/term_input_display')

pty_session.start(vim.env.SHELL or '/bin/zsh', { width = 80, height = 24 }, {})

vim.cmd('belowright split')
local input_win = vim.api.nvim_get_current_win()
local input_buf = vim.api.nvim_create_buf(false, true)
vim.bo[input_buf].buftype  = 'nofile'
vim.bo[input_buf].swapfile = false
vim.api.nvim_win_set_buf(input_win, input_buf)
vim.api.nvim_buf_set_name(input_buf, 'lcars://test/term_input')

term_input.open(input_buf, {
  win        = input_win,
  on_submit  = pty_session.send,
  min_height = 4,
  max_height = 10,
})

-- Left in Normal mode deliberately (not startinsert) — the driving test
-- script sends its own explicit Esc+i before typing, so nvim's mode is
-- deterministic when the script's Ex-command helpers (nvim_check_messages)
-- run in between.
vim.api.nvim_set_current_win(input_win)
