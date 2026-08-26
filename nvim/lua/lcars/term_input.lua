-- term_input.lua — orange-stem input panel that submits to a PTY session.
--
-- API:
--   M.open(buf, opts)   opts = { win, on_submit, min_height, max_height, filetype }
--   M.submit()          reads buf, strips trailing blanks, calls on_submit(text), clears buf
--   M.resize()          nvim_win_set_height(win, clamp(line_count, min_height, max_height))
--   M.history_search()  Telescope picker over ~/.histfile, replaces buf with selection
--
-- New file — does NOT touch command_buffer.lua (preserved for the kitty
-- send-text workflow). Reuses its winhighlight/signcolumn/resize/history
-- patterns, but talks to a caller-supplied on_submit callback instead of
-- kitty @ send-text or pty_session directly. The caller (terminal_win.lua)
-- owns the split/buffer and passes a callback that sets rec.command before
-- forwarding to pty_session.send — see "Wiring notes" in
-- docs/nvim-terminal-frame.md.

local pickers      = require("telescope.pickers")
local finders      = require("telescope.finders")
local conf         = require("telescope.config").values
local actions      = require("telescope.actions")
local action_state = require("telescope.actions.state")

local p = require("lcars.palette")

local M = {}

local DEFAULT_MIN_HEIGHT = 4
local DEFAULT_MAX_HEIGHT = 10

local _buf        = nil
local _win        = nil
local _on_submit  = nil
local _min_height = DEFAULT_MIN_HEIGHT
local _max_height = DEFAULT_MAX_HEIGHT

-- Namespaced separately from command_buffer.lua's LcarsCmdStem* groups so
-- the two independent input surfaces (kitty-pane command buffer vs. the
-- in-nvim terminal frame) don't share global highlight state.
local function _apply_highlights()
  vim.api.nvim_set_hl(0, "LcarsTermInputStem",       { fg = p.bg,     bg = p.orange })
  vim.api.nvim_set_hl(0, "LcarsTermInputStemDim",    { fg = p.bg_dim, bg = p.orange })
  vim.api.nvim_set_hl(0, "LcarsTermInputCursorNr",   { fg = p.bg, bg = p.orange, bold = true })
  vim.api.nvim_set_hl(0, "LcarsTermInputCursorLine", { bg = "#120800" })
end

-- Resize the input split to match its buffer's line count, clamped to
-- [min_height, max_height] so a multi-line paste can't swallow the display
-- split above it.
function M.resize()
  if not _win or not vim.api.nvim_win_is_valid(_win) then return end
  local line_count = vim.api.nvim_buf_line_count(_buf)
  local target = math.max(_min_height, math.min(_max_height, line_count))
  if vim.api.nvim_win_get_height(_win) == target then return end
  vim.api.nvim_win_set_height(_win, target)
end

-- Submit the buffer's contents via the caller-supplied on_submit callback,
-- then clear the buffer for the next command (fresh-prompt UX — differs
-- from command_buffer.lua, which leaves submitted text in place).
function M.submit()
  local lines = vim.api.nvim_buf_get_lines(_buf, 0, -1, false)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then return end

  _on_submit(table.concat(lines, "\n"))

  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, { "" })
  vim.schedule(M.resize)
end

-- Deduplicate history lines (last occurrence wins) and reverse so index 1 is
-- most recent. Pure logic, exposed for headless unit testing.
function M._dedupe_reversed(lines)
  local ordered = {}
  local seen = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      if seen[line] then
        for i, v in ipairs(ordered) do
          if v == line then table.remove(ordered, i); break end
        end
      end
      table.insert(ordered, line)
      seen[line] = true
    end
  end

  local reversed = {}
  for i = #ordered, 1, -1 do
    table.insert(reversed, ordered[i])
  end
  return reversed
end

-- Open a telescope picker over ~/.histfile, most-recent first, and populate
-- the input buffer with the selected entry.
function M.history_search()
  local histfile = vim.env.HOME .. "/.histfile"
  local fh = io.open(histfile, "r")
  if not fh then
    vim.notify("lcars.term_input: cannot read " .. histfile, vim.log.levels.WARN)
    return
  end

  local lines = {}
  for line in fh:lines() do
    table.insert(lines, line)
  end
  fh:close()

  local entries = M._dedupe_reversed(lines)
  local buf = _buf
  local win = _win

  pickers.new({}, {
    prompt_title = "Zsh History",
    finder = finders.new_table({ results = entries }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr_inner)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr_inner)
        if selection then
          local sel_lines = vim.split(selection[1], "\n", { plain = true })
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, sel_lines)
          vim.schedule(function()
            if win and vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_set_current_win(win)
            end
            vim.cmd("startinsert!")
          end)
        end
      end)
      return true
    end,
  }):find()
end

-- Configure a buffer (created and split into a window by the caller —
-- term_input never calls nvim_open_win itself) as the orange-stem PTY
-- input panel. opts.on_submit(cmd_text) is called with the buffer's full
-- contents (lines joined by "\n") on submit.
function M.open(buf, opts)
  opts = opts or {}
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    error("lcars.term_input: M.open requires a valid buffer")
  end
  if type(opts.on_submit) ~= "function" then
    error("lcars.term_input: opts.on_submit is required")
  end

  _buf        = buf
  _win        = opts.win
  _on_submit  = opts.on_submit
  _min_height = opts.min_height or DEFAULT_MIN_HEIGHT
  _max_height = opts.max_height or DEFAULT_MAX_HEIGHT

  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  _apply_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { buffer = buf, callback = _apply_highlights })

  if _win then
    vim.api.nvim_set_option_value("winhighlight", table.concat({
      "LineNr:LcarsTermInputStem",
      "LineNrAbove:LcarsTermInputStemDim",
      "LineNrBelow:LcarsTermInputStemDim",
      "CursorLineNr:LcarsTermInputCursorNr",
      "SignColumn:LcarsTermInputStem",
      "CursorLineSign:LcarsTermInputStem",
      "CursorLine:LcarsTermInputCursorLine",
    }, ","), { win = _win })

    -- Pin signcolumn so the orange stem is always visible (never collapses).
    local signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = _win })
    if signcolumn == "auto" or signcolumn:match("^auto:") then
      vim.api.nvim_set_option_value("signcolumn", "yes:1", { win = _win })
    end
  end

  -- Resize on every text change, debounced by the nvim scheduler.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function() vim.schedule(M.resize) end,
  })
  vim.schedule(M.resize)

  vim.keymap.set("n", "<CR>",      M.submit,         { buffer = buf, desc = "Submit term_input to PTY" })
  vim.keymap.set("n", "<leader>r", M.history_search, { buffer = buf, desc = "Search zsh history" })
  vim.keymap.set("i", "<leader>r", M.history_search, { buffer = buf, desc = "Search zsh history" })

  return M
end

return M
