-- spike_baleia.lua — spike-2 (lcarcat-dk5)
-- Confirms three things about the baleia.nvim + modifiable=false pattern:
--   1. baleia.buf_set_lines() writes ANSI-colored text to a buffer toggled
--      from modifiable=false (flip on → write → flip off)
--   2. Pre-existing extmarks on the buffer survive the modifiable toggle
--   3. A burst of 100 ANSI lines completes without blocking the main loop
--
-- :LcarsSpikeBaleia   run the spike (opens a scratch tab)

local M = {}

local ok_baleia, baleia_mod = pcall(require, "baleia")
local p = require("lcars.palette")

-- Sync mode so timing is deterministic and errors surface immediately.
local baleia = ok_baleia and baleia_mod.setup({ async = false, strip_ansi_codes = true }) or nil

local ANSI_LINES = {
  "\27[31mred output line\27[0m",
  "\27[32mgreen output line\27[0m",
  "\27[33myellow output line\27[0m",
  "\27[34mblue output line\27[0m",
  "\27[1;36mbold cyan output line\27[0m",
  "\27[38;5;208morange 256-color line\27[0m",
  "\27[38;2;153;153;255mtruecolor periwinkle line\27[0m",
  "plain line (no ANSI codes)",
}

local ns = vim.api.nvim_create_namespace("lcars_spike_baleia")

-- Write a single ANSI line to buf at row `row` using the modifiable toggle.
-- Returns true on success.
local function write_line(buf, row, raw_line)
  vim.bo[buf].modifiable = true
  baleia.buf_set_lines(buf, row, row, false, { raw_line })
  vim.bo[buf].modifiable = false
  -- Verify the line was written (baleia silently no-ops if modifiable=false was missed)
  local written = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
  return written[1] ~= nil and written[1] ~= ""
end

-- Place a sentinel extmark BEFORE any writes, then verify it still exists after.
local function place_sentinel(buf, row)
  return vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { " [LCARS STEM] ", "LcarsBlockStem" } },
    virt_text_pos = "overlay",
    priority = 200,
  })
end

local function extmark_survives(buf, id)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = false })
  for _, m in ipairs(marks) do
    if m[1] == id then return true end
  end
  return false
end

function M.run()
  if not ok_baleia or not baleia then
    vim.notify("spike_baleia: baleia.nvim not available — run :Lazy install", vim.log.levels.ERROR)
    return
  end

  -- ── setup scratch buffer ──────────────────────────────────────────────────
  local buf_name = "lcars://spike/baleia"
  local buf, win
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_get_name(b) == buf_name then
        vim.api.nvim_set_current_tabpage(t)
        buf, win = b, w
        break
      end
    end
    if buf then break end
  end
  if not buf then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_buf_set_name(buf, buf_name)
  end

  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].swapfile   = false
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap       = false
  vim.api.nvim_set_hl(0, "LcarsBlockStem", { bg = p.periwinkle, fg = p.periwinkle })

  -- Start clean
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modifiable = false

  local results = {}

  -- ── test 1: write a single ANSI line through the modifiable toggle ────────
  local ok1 = write_line(buf, 0, "\27[1;35m=== spike-2: baleia + modifiable=false ===\27[0m")
  results[#results + 1] = "test1 (single write): " .. (ok1 and "PASS" or "FAIL")

  -- ── test 2: extmarks survive the toggle ───────────────────────────────────
  -- Write a header row, place a sentinel extmark on it, then write more lines,
  -- then check the sentinel is still there.
  write_line(buf, 1, "")  -- spacer row for the sentinel
  local sentinel_id = place_sentinel(buf, 1)
  -- Write a line after the sentinel row (should not disturb it)
  write_line(buf, 2, "\27[32mline written after sentinel extmark\27[0m")
  local survived = extmark_survives(buf, sentinel_id)
  results[#results + 1] = "test2 (extmarks survive toggle): " .. (survived and "PASS" or "FAIL")

  -- ── test 3: burst of 100 ANSI lines — measure wall time ──────────────────
  local burst_lines = {}
  for i = 1, 100 do
    local colors = { "\27[31m", "\27[32m", "\27[33m", "\27[34m", "\27[35m", "\27[36m" }
    local c = colors[(i % #colors) + 1]
    burst_lines[i] = c .. string.format("burst line %03d: some output text here", i) .. "\27[0m"
  end

  local t0 = vim.uv.hrtime()
  local base_row = 4
  for i, line in ipairs(burst_lines) do
    write_line(buf, base_row + i - 1, line)
  end
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6

  local lag_ok = elapsed_ms < 500  -- 100 lines in under 500ms is acceptable
  results[#results + 1] = string.format(
    "test3 (100-line burst): %.1fms — %s", elapsed_ms, lag_ok and "PASS" or "SLOW")

  -- ── summary ───────────────────────────────────────────────────────────────
  local summary_row = base_row + 100 + 1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, summary_row, summary_row, false, { "" })
  for _, r in ipairs(results) do
    summary_row = summary_row + 1
    local color = r:find("FAIL") and "\27[31m" or r:find("SLOW") and "\27[33m" or "\27[32m"
    baleia.buf_set_lines(buf, summary_row, summary_row, false,
      { color .. r .. "\27[0m" })
  end
  vim.bo[buf].modifiable = false

  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local all_pass = not table.concat(results, " "):find("FAIL")
  vim.notify(
    "spike_baleia: " .. (all_pass and "all tests passed" or "some tests FAILED")
    .. string.format(" (burst: %.1fms)", elapsed_ms),
    all_pass and vim.log.levels.INFO or vim.log.levels.ERROR
  )
end

vim.api.nvim_create_user_command("LcarsSpikeBaleia", function()
  M.run()
end, { desc = "spike-2: test baleia.nvim + modifiable=false buffer pattern" })

return M
