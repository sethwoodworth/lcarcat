-- LCARS command buffer: submit and auto-resize logic.
-- Loaded via `-c "lua require('lcars.command_buffer')"` when kitty launches the
-- command buffer panel (identified by LCARCAT_COMMAND_BUFFER=1 in the environment).
-- No-op when that var is absent so requiring from a normal nvim is safe.

if vim.env.LCARCAT_COMMAND_BUFFER ~= "1" then return {} end

-- LCARS input-panel theming: orange stem marks this as an active input panel,
-- distinct from the periwinkle display-panel stem in the shell pane above.
-- All overrides are window-local via winhighlight — no bleed into normal nvim.
local p = require("lcars.palette")

local function _apply_cmd_highlights()
  vim.api.nvim_set_hl(0, "LcarsCmdStem",       { fg = p.bg,     bg = p.orange })
  vim.api.nvim_set_hl(0, "LcarsCmdStemDim",    { fg = p.bg_dim, bg = p.orange })
  vim.api.nvim_set_hl(0, "LcarsCmdCursorNr",   { fg = p.bg, bg = p.orange, bold = true })
  vim.api.nvim_set_hl(0, "LcarsCmdCursorLine", { bg = "#120800" })
end
_apply_cmd_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { buffer = 0, callback = _apply_cmd_highlights })

vim.wo.winhighlight = table.concat({
  "LineNr:LcarsCmdStem",
  "LineNrAbove:LcarsCmdStemDim",
  "LineNrBelow:LcarsCmdStemDim",
  "CursorLineNr:LcarsCmdCursorNr",
  "SignColumn:LcarsCmdStem",
  "CursorLineSign:LcarsCmdStem",
  "CursorLine:LcarsCmdCursorLine",
}, ",")

-- Pin signcolumn so the orange stem is always visible (never collapses).
if vim.wo.signcolumn == "auto" or vim.wo.signcolumn:match("^auto:") then
  vim.wo.signcolumn = "yes:1"
end

local M = {}

local MINIMUM_LINES = 4

-- Find the kitty window ID of the pane directly above this split.
-- neighbors.top contains group IDs, not window IDs — must resolve via tab.groups.
local function target_window_id()
  local my_id = tonumber(vim.env.KITTY_WINDOW_ID)
  local raw = vim.fn.system("kitty @ ls 2>/dev/null")
  if vim.v.shell_error ~= 0 or raw == "" then return nil end
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then return nil end
  for _, os_win in ipairs(data) do
    for _, tab in ipairs(os_win.tabs or {}) do
      -- Build group_id -> window_id map; neighbors use group IDs, not window IDs.
      local group_to_win = {}
      for _, group in ipairs(tab.groups or {}) do
        if group.windows and group.windows[1] then
          group_to_win[group.id] = group.windows[1]
        end
      end
      for _, w in ipairs(tab.windows or {}) do
        if w.id == my_id then
          local top = (w.neighbors or {}).top
          if top and top ~= vim.NIL and type(top) == "table" and top[1] then
            return group_to_win[top[1]]
          end
          -- Fallback: first sibling window in the same tab.
          for _, sibling in ipairs(tab.windows or {}) do
            if sibling.id ~= my_id then return sibling.id end
          end
          return nil
        end
      end
    end
  end
  return nil
end

-- Resize the kitty panel so its height matches the buffer line count,
-- with a floor of MINIMUM_LINES. Uses `resize-window --self` with a
-- signed cell increment so kitty handles the layout math.
function M.resize()
  local line_count = vim.api.nvim_buf_line_count(0)
  local target_height = math.max(MINIMUM_LINES, line_count)
  local current_height = vim.api.nvim_win_get_height(0)
  local delta = target_height - current_height
  if delta == 0 then return end
  vim.fn.jobstart({
    "kitty", "@", "resize-window", "--self",
    "--axis", "vertical",
    "--increment", tostring(delta),
  }, { detach = true })
end

-- Send the buffer's content to the target kitty pane as a shell command.
-- Strips trailing blank lines; appends a newline to submit the command.
function M.submit()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then return end

  local target = target_window_id()
  if not target then
    vim.notify("lcars.command_buffer: no sibling kitty window found", vim.log.levels.WARN)
    return
  end

  -- Write content to a temp file and pipe via --stdin to handle arbitrary text.
  local tmp = vim.fn.tempname()
  local fh = io.open(tmp, "w")
  if not fh then
    vim.notify("lcars.command_buffer: could not write temp file", vim.log.levels.ERROR)
    return
  end
  fh:write(table.concat(lines, "\n") .. "\n")
  fh:close()

  vim.fn.system("kitty @ send-text --match id:" .. tostring(target) .. " --stdin < " .. vim.fn.shellescape(tmp))
  os.remove(tmp)
end

-- Resize on every text change, debounced by the nvim scheduler.
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  buffer = 0,
  callback = function() vim.schedule(M.resize) end,
})

-- Also resize once on load in case the initial bias is smaller than MINIMUM_LINES.
vim.schedule(M.resize)

-- <CR> in normal mode submits the buffer.
vim.keymap.set("n", "<CR>", M.submit, { buffer = true, desc = "Submit command buffer to shell" })

return M
