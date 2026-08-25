package.loaded['lcars.frame_renderer'] = nil
package.loaded['lcars.block_record'] = nil
package.loaded['lcars.image_registry'] = nil
local fr = require('lcars.frame_renderer')
local br = require('lcars.block_record')
local ir = require('lcars.image_registry')
local assets = require('lcars.assets')

vim.cmd('tabnew')
local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_buf_set_name(buf, 'lcars://test/frame_renderer')
vim.wo[win].number = false
vim.wo[win].relativenumber = false
vim.wo[win].signcolumn = 'no'
vim.wo[win].foldcolumn = '0'
vim.wo[win].wrap = false
vim.wo[win].cursorline = false
vim.wo[win].list = false

local p = require('lcars.palette')
vim.api.nvim_set_hl(0, 'LcarsBlockChipGo', { bg = p.gold,   fg = p.bg })
vim.api.nvim_set_hl(0, 'LcarsBlockChipSk', { bg = p.sky,    fg = p.bg })
vim.api.nvim_set_hl(0, 'LcarsBlockChipOr', { bg = p.orange, fg = p.bg, bold = true })

vim.bo[buf].modifiable = true
local empty = {}
for i = 1, 80 do empty[i] = '' end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, empty)
vim.bo[buf].modifiable = false

local cw, ch = assets.cell_px()
ir.current_cw = cw
ir.current_ch = ch
local bw = vim.api.nvim_win_get_width(win) - 14
local opts = { lp = 6, bw = bw, win = win, cw = cw, ch = ch }

local rec1 = br.new(1)
rec1.state = 'done'
rec1.command = 'tree ~/code/lcarcat'
rec1.chips = { { 'main', 'LcarsBlockChipGo' }, { '~/code', 'LcarsBlockChipSk' } }
rec1.cwd = '~/code/lcarcat'
rec1.lines = { '.', '├── nvim/', '│   └── lua/lcars/', '└── deploy.sh' }
rec1.command_start = 1000; rec1.command_end = 1002; rec1.duration = 2.0
opts.image_key_prefix = 'done'
local r1 = fr.render_block(buf, 2, rec1, opts)

local rec2 = br.new(2)
rec2.state = 'live'
rec2.command = 'ping 8.8.8.8'
rec2.chips = { { 'main', 'LcarsBlockChipGo' } }
rec2.cwd = '~/code/lcarcat/nvim'
rec2.lines = { 'PING 8.8.8.8: 56 data bytes', '64 bytes icmp_seq=0 ttl=118 time=12.4 ms' }
opts.image_key_prefix = 'live'
local r2 = fr.render_block(buf, 2 + r1 + 1, rec2, opts)

local rec3 = br.new(3)
rec3.state = 'failed'
rec3.command = 'npm test'
rec3.chips = { { 'feat/fix', 'LcarsBlockChipSk' } }
rec3.cwd = '~/code/lcarcat'
rec3.lines = { '> jest --runInBand', 'FAIL src/index.test.js', '  ● test suite failed' }
rec3.command_start = 1000; rec3.command_end = 1003; rec3.duration = 3.1
opts.image_key_prefix = 'failed'
fr.render_block(buf, 2 + r1 + 1 + r2 + 1, rec3, opts)

vim.api.nvim_win_set_cursor(win, { 1, 0 })
