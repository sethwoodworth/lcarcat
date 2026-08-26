-- pty_session.lua — PTY job wrapper with OSC 133 parser and carry-buffer
--
-- API:
--   M.start(shell_cmd, opts, callbacks)  start PTY job
--   M.send(text)                         write text + newline to PTY stdin
--   M.stop()                             jobstop
--   M._parse_chunk(carry, bytes)         pure parser, exposed for unit tests
--
-- opts: { width, height }
--
-- callbacks: {
--   on_prompt_start()            OSC 133;A — shell drew prompt
--   on_command_start()           OSC 133;B — end of prompt line
--   on_command_exec()            OSC 133;C — command executing
--   on_command_done(exit_code)   OSC 133;D;N — command finished
--   on_output_line(line)         non-OSC, non-echoed output line
--   on_cwd(path)                 OSC 7 — shell changed directory
--   on_exit(exit_code)           job process exited
-- }
--
-- Carry table (threaded across chunks):
--   buf        string  partial text line accumulator
--   osc        string|nil  accumulating OSC body (nil = text mode)
--   skip_lines bool    true between OSC 133;B and 133;C (suppress echoed input)

local M = {}

local _job_id = nil

-- ── helpers ───────────────────────────────────────────────────────────────

local function percent_decode(s)
  return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

-- A lone \r held in carry across a chunk boundary (e.g. "\r at end of chunk"
-- below) stays attached to buf until the next flush point. If that flush is
-- triggered by a bare \n or an OSC start rather than the paired \r\n case,
-- the \r is still sitting at the end of buf and would otherwise leak into
-- the emitted line as a literal ^M.
local function strip_trailing_cr(s)
  if s:sub(-1) == "\r" then return s:sub(1, -2) end
  return s
end

local function parse_osc(body, carry)
  if body == "133;A" then
    carry.skip_lines = false
    return { kind = "event", type = "prompt_start" }
  elseif body == "133;B" then
    carry.skip_lines = true
    return { kind = "event", type = "command_start" }
  elseif body == "133;C" then
    carry.skip_lines = false
    return { kind = "event", type = "command_exec" }
  else
    local n = body:match("^133;D;(%d+)$")
    if n then
      return { kind = "event", type = "command_done", exit_code = tonumber(n) }
    end
    local path = body:match("^7;file://[^/]*(/.+)$")
    if path then
      return { kind = "event", type = "cwd", path = percent_decode(path) }
    end
  end
  return nil
end

-- ── parse_chunk ───────────────────────────────────────────────────────────

-- parse_chunk(carry, bytes) → new_carry, items[]
--
-- Pure function — no vim API calls (safe for headless unit tests).
-- `carry` must be a table with fields: buf, osc, skip_lines.
-- Returns a new carry table and an ordered list of items.
function M._parse_chunk(carry, bytes)
  local items = {}
  local buf        = carry.buf        or ""
  local osc        = carry.osc        -- nil | string
  local skip_lines = carry.skip_lines or false

  local i   = 1
  local len = #bytes

  while i <= len do
    local b = bytes:sub(i, i)

    if osc ~= nil then
      -- ── OSC accumulation mode ───────────────────────────────────────────
      -- Check for ST spanning a chunk boundary: if osc ends with \x1b and current byte is \x5c
      if b == "\x5c" and osc:sub(-1) == "\x1b" then
        osc = osc:sub(1, -2)  -- strip the pending \x1b sentinel
        local ev = parse_osc(osc, carry)
        if ev then items[#items + 1] = ev end
        osc = nil
        skip_lines = carry.skip_lines
        i = i + 1
      elseif b == "\x07" then
        -- BEL terminates OSC
        local ev = parse_osc(osc, carry)
        if ev then items[#items + 1] = ev end
        osc = nil
        skip_lines = carry.skip_lines  -- parse_osc may have mutated carry.skip_lines
        i = i + 1
      elseif b == "\x1b" then
        if i == len then
          -- ESC at very end of chunk — may be start of ST (\x1b\x5c); hold in carry
          -- Keep osc alive with a sentinel suffix so the next chunk continues in OSC mode
          -- and can detect \x5c as the ST terminator.
          osc = osc .. "\x1b"
          i = i + 1
        elseif bytes:sub(i + 1, i + 1) == "\x5c" then
          -- ST = ESC \ terminates OSC
          local ev = parse_osc(osc, carry)
          if ev then items[#items + 1] = ev end
          osc = nil
          skip_lines = carry.skip_lines
          i = i + 2
        else
          osc = osc .. b
          i = i + 1
        end
      else
        if #osc > 4096 then
          -- Safety cap: drop runaway OSC sequence
          vim.notify("lcars.pty_session: OSC sequence exceeded 4096 bytes, dropped", vim.log.levels.WARN)
          osc = nil
          buf = ""
          i = i + 1
        else
          osc = osc .. b
          i = i + 1
        end
      end
    else
      -- ── Text mode ──────────────────────────────────────────────────────
      if b == "\x1b" then
        local b2 = bytes:sub(i + 1, i + 1)
        if b2 == "]" then
          -- Start of OSC sequence
          if buf ~= "" and not skip_lines then
            items[#items + 1] = { kind = "line", text = strip_trailing_cr(buf) }
          end
          buf = ""
          osc = ""
          i = i + 2
        elseif i == len then
          -- ESC at very end of chunk — keep in carry (could be start of escape sequence)
          buf = buf .. b
          i = i + 1
        else
          -- Other escape sequence (CSI, etc.) — skip the ESC; the following bytes
          -- will either be consumed as ANSI codes or passed through. For now, skip ESC
          -- and let the rest flow through (baleia handles ANSI in output lines).
          buf = buf .. b
          i = i + 1
        end
      elseif b == "\r" then
        local b2 = bytes:sub(i + 1, i + 1)
        if b2 == "\n" then
          -- \r\n line ending
          if not skip_lines and buf ~= "" then
            items[#items + 1] = { kind = "line", text = buf }
          end
          buf = ""
          i = i + 2
        elseif i == len then
          -- \r at end of chunk — hold in carry (may be \r\n across boundary)
          buf = buf .. b
          i = i + 1
        else
          -- \r not followed by \n → cursor overwrite; drop the partial line
          buf = ""
          i = i + 1
        end
      elseif b == "\n" then
        if not skip_lines and buf ~= "" then
          items[#items + 1] = { kind = "line", text = strip_trailing_cr(buf) }
        end
        buf = ""
        i = i + 1
      else
        buf = buf .. b
        i = i + 1
      end
    end
  end

  return { buf = buf, osc = osc, skip_lines = skip_lines }, items
end

-- ── internal dispatch ─────────────────────────────────────────────────────

local function dispatch(callbacks, item)
  local t = item.type
  if     t == "prompt_start"  and callbacks.on_prompt_start  then callbacks.on_prompt_start()
  elseif t == "command_start" and callbacks.on_command_start then callbacks.on_command_start()
  elseif t == "command_exec"  and callbacks.on_command_exec  then callbacks.on_command_exec()
  elseif t == "command_done"  and callbacks.on_command_done  then callbacks.on_command_done(item.exit_code)
  elseif t == "cwd"           and callbacks.on_cwd           then callbacks.on_cwd(item.path)
  end
end

local function make_on_stdout(callbacks, carry_ref)
  return function(_, data, _)
    -- nvim's on_stdout already splits the raw byte stream on "\n" and strips
    -- it before this callback sees `data` — rejoin with "\n" to restore real
    -- line endings. _parse_chunk detects line boundaries by scanning for
    -- literal \r/\n bytes; without this every chunk lacks the \n it needs and
    -- text just piles into an unflushed carry, never emitting a line.
    local bytes = table.concat(data, "\n")
    if bytes == "" then return end
    local new_carry, items = M._parse_chunk(carry_ref[1], bytes)
    carry_ref[1] = new_carry
    vim.schedule(function()
      for _, item in ipairs(items) do
        if item.kind == "line" then
          if callbacks.on_output_line then callbacks.on_output_line(item.text) end
        else
          dispatch(callbacks, item)
        end
      end
    end)
  end
end

-- ── public API ────────────────────────────────────────────────────────────

function M.start(shell_cmd, opts, callbacks)
  local carry_ref = { { buf = "", osc = nil, skip_lines = false } }
  _job_id = vim.fn.jobstart(shell_cmd, {
    pty       = true,
    width     = (opts and opts.width)  or 220,
    height    = (opts and opts.height) or 50,
    on_stdout = make_on_stdout(callbacks, carry_ref),
    on_exit   = function(_, code, _)
      vim.schedule(function()
        if callbacks.on_exit then callbacks.on_exit(code) end
      end)
    end,
  })
  if _job_id <= 0 then
    error("lcars.pty_session: jobstart failed (code " .. tostring(_job_id) .. ")")
  end
end

function M.send(text)
  if _job_id then vim.fn.chansend(_job_id, text .. "\n") end
end

function M.stop()
  if _job_id then vim.fn.jobstop(_job_id) end
  _job_id = nil
end

return M
