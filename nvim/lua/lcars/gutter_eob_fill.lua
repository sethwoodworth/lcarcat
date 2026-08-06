-- Fills the gutter (col 0..textoff-1) on below-end-of-buffer rows with the
-- SignColumn highlight (periwinkle). nvim 0.12 does not evaluate statuscolumn
-- for EOB virtual rows, so a style="minimal" float is the only reliable fix.

local M = {}

-- win_id → fill float win_id
local fills = {}

local function close_fill(win)
  local fw = fills[win]
  if fw and vim.api.nvim_win_is_valid(fw) then
    vim.api.nvim_win_close(fw, true)
  end
  fills[win] = nil
end

local function refresh()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" then return end

  local ok, wi_list = pcall(vim.fn.getwininfo, win)
  if not ok or not wi_list or not wi_list[1] then return end
  local wi = wi_list[1]

  -- How many screen rows within this window are occupied by buffer content?
  -- wi.botline - wi.topline + 1 gives the visible line count regardless of
  -- scroll position. wi.height - wi.botline would work only when topline=1.
  local visible_content = wi.botline - wi.topline + 1
  local eob_rows = wi.height - visible_content
  local float_row = visible_content  -- 0-indexed offset from window top
  local textoff   = wi.textoff or 0

  if eob_rows <= 0 or textoff <= 0 then
    close_fill(win)
    return
  end

  local fw = fills[win]
  if fw and vim.api.nvim_win_is_valid(fw) then
    -- Sync buffer line count to the new height before resizing the window.
    -- A style="minimal" float renders EOB rows with EndOfBuffer highlight
    -- (black), not Normal, so the buffer must have exactly `height` lines.
    local fbuf = vim.api.nvim_win_get_buf(fw)
    local cur_lines = vim.api.nvim_buf_line_count(fbuf)
    if cur_lines < eob_rows then
      local extra = {}
      for _ = 1, eob_rows - cur_lines do extra[#extra + 1] = "" end
      vim.api.nvim_buf_set_lines(fbuf, -1, -1, false, extra)
    elseif cur_lines > eob_rows then
      vim.api.nvim_buf_set_lines(fbuf, eob_rows, -1, false, {})
    end
    vim.api.nvim_win_set_config(fw, {
      relative = "win",
      win      = win,
      row      = float_row,
      col      = 0,
      width    = textoff,
      height   = eob_rows,
    })
  else
    close_fill(win)
    local buf = vim.api.nvim_create_buf(false, true)
    -- Pre-fill with blank lines so every float row is buffer content, not an
    -- EOB virtual row. Without this only 1 row renders with the stem color.
    local blanks = {}
    for _ = 1, eob_rows do blanks[#blanks + 1] = "" end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, blanks)
    local new_win = vim.api.nvim_open_win(buf, false, {
      relative  = "win",
      win       = win,
      row       = float_row,
      col       = 0,
      width     = textoff,
      height    = eob_rows,
      style     = "minimal",
      focusable = false,
      zindex    = 1,
    })
    vim.wo[new_win].winhighlight = "Normal:SignColumn,NormalNC:SignColumn,EndOfBuffer:SignColumn"
    fills[win] = new_win
  end
end

local token = 0
local function schedule_refresh()
  token = token + 1
  local mine = token
  vim.defer_fn(function()
    if mine == token then pcall(refresh) end
  end, 80)
end

function M.setup()
  vim.api.nvim_create_autocmd(
    { "BufEnter", "WinEnter", "WinResized", "WinScrolled" },
    { callback = schedule_refresh }
  )

  vim.api.nvim_create_autocmd("WinClosed", {
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed then close_fill(closed) end
      for w, fw in pairs(fills) do
        if not vim.api.nvim_win_is_valid(w) then
          if fw and vim.api.nvim_win_is_valid(fw) then
            vim.api.nvim_win_close(fw, true)
          end
          fills[w] = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      vim.schedule(schedule_refresh)
    end,
  })
end

return M
