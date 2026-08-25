-- frame_buffer_test.lua — visual test for lcars.frame_buffer
--
-- Three blocks rendered in sequence:
--   block 1 (done)   — 4 lines, with duration chip in re-rendered header
--   block 2 (live)   — 2 lines, no footer (open block, never closed)
--   block 3 (failed) — 3 lines, re-rendered header shows failure color

-- Reload modules so edits take effect without restarting nvim
for _, mod in ipairs({
  'lcars.frame_buffer', 'lcars.frame_renderer',
  'lcars.block_record', 'lcars.image_registry', 'lcars.assets',
}) do
  package.loaded[mod] = nil
end

local fb     = require('lcars.frame_buffer')
local br     = require('lcars.block_record')
local assets = require('lcars.assets')
local ir     = require('lcars.image_registry')
local p      = require('lcars.palette')

-- ── highlight groups ─────────────────────────────────────────────────────────
vim.api.nvim_set_hl(0, 'LcarsTermFrameLive',   { bg = p.sage,       fg = p.sage })
vim.api.nvim_set_hl(0, 'LcarsTermFrameFailed', { bg = p.red,        fg = p.red  })
vim.api.nvim_set_hl(0, 'LcarsTermBar',         { bg = p.periwinkle, fg = p.periwinkle })
vim.api.nvim_set_hl(0, 'LcarsTermStemLive',    { bg = p.sage,       fg = p.sage })
vim.api.nvim_set_hl(0, 'LcarsTermStemFailed',  { bg = p.red,        fg = p.red  })
vim.api.nvim_set_hl(0, 'LcarsBlockChipGo',     { bg = p.gold,       fg = p.bg   })
vim.api.nvim_set_hl(0, 'LcarsBlockChipSk',     { bg = p.sky,        fg = p.bg   })
vim.api.nvim_set_hl(0, 'LcarsBlockChipOr',     { bg = p.orange,     fg = p.bg, bold = true })

-- ── open/reuse tab ───────────────────────────────────────────────────────────
vim.cmd('tabnew')
local win = vim.api.nvim_get_current_win()

local cw, ch = assets.cell_px()
ir.current_cw = cw
ir.current_ch = ch

local bw = vim.api.nvim_win_get_width(win) - 14
local ns = vim.api.nvim_create_namespace('lcars_frame_buffer_test')

fb.new({ ns = ns, lp = 6, bw = bw, win = win, cw = cw, ch = ch })

-- Display the frame_buffer's buffer in this window
vim.api.nvim_win_set_buf(win, fb.buf)
vim.api.nvim_buf_set_name(fb.buf, 'lcars://test/frame_buffer')
vim.wo[win].number         = false
vim.wo[win].relativenumber = false
vim.wo[win].signcolumn     = 'no'
vim.wo[win].foldcolumn     = '0'
vim.wo[win].wrap           = false
vim.wo[win].cursorline     = false
vim.wo[win].list           = false

-- ── block 1: done ─────────────────────────────────────────────────────────
local rec1 = br.new(1)
rec1.state   = 'live'
rec1.command = 'tree ~/code/lcarcat'
rec1.chips   = { { 'main', 'LcarsBlockChipGo' }, { '~/code', 'LcarsBlockChipSk' } }
rec1.cwd     = '~/code/lcarcat'

fb.open_block(rec1)
fb.append_line(rec1, '\27[32m.\27[0m')
fb.append_line(rec1, '\27[32m├── nvim/\27[0m')
fb.append_line(rec1, '\27[33m│   └── lua/lcars/\27[0m')
fb.append_line(rec1, '\27[32m└── deploy.sh\27[0m')

-- Finalize: mark done and close
rec1.state         = 'done'
rec1.command_start = 1000
rec1.command_end   = 1002
rec1.duration      = 2.0
fb.close_block(rec1)

-- ── block 2: live (no close) ──────────────────────────────────────────────
local rec2 = br.new(2)
rec2.state   = 'live'
rec2.command = 'ping 8.8.8.8'
rec2.chips   = { { 'main', 'LcarsBlockChipGo' } }
rec2.cwd     = '~/code/lcarcat/nvim'

fb.open_block(rec2)
fb.append_line(rec2, 'PING 8.8.8.8: 56 data bytes')
fb.append_line(rec2, '\27[36m64 bytes icmp_seq=0 ttl=118 time=12.4 ms\27[0m')

-- ── block 3: failed ───────────────────────────────────────────────────────
local rec3 = br.new(3)
rec3.state   = 'live'
rec3.command = 'npm test'
rec3.chips   = { { 'feat/fix', 'LcarsBlockChipSk' } }
rec3.cwd     = '~/code/lcarcat'

fb.open_block(rec3)
fb.append_line(rec3, '> jest --runInBand')
fb.append_line(rec3, '\27[31mFAIL src/index.test.js\27[0m')
fb.append_line(rec3, '\27[31m  ● test suite failed to run\27[0m')

rec3.state         = 'failed'
rec3.command_start = 1000
rec3.command_end   = 1003
rec3.duration      = 3.1
fb.close_block(rec3)

-- ── position cursor ───────────────────────────────────────────────────────
vim.api.nvim_win_set_cursor(win, { 1, 0 })
