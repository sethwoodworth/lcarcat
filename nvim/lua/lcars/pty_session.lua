-- pty_session.lua — PTY job wrapper with OSC 133 parser and carry-buffer
--
-- API:
--   M.start(shell_cmd, opts, callbacks)  start PTY job
--   M.send(text)                         write text + newline to PTY stdin
--   M.send_raw(bytes)                    write bytes verbatim to PTY stdin
--   M.resize(width, height)              jobresize (SIGWINCH to the child)
--   M.leave_alternate_screen()           force the parser back to text mode
--   M.stop()                             jobstop
--   M._parse_chunk(carry, bytes)         pure parser, exposed for unit tests
--
-- opts: { width, height, term }
--
-- callbacks: {
--   on_prompt_start()            OSC 133;A — shell drew prompt
--   on_command_start()           OSC 133;B — end of prompt line
--   on_command_exec()            OSC 133;C — command executing
--   on_command_done(exit_code)   OSC 133;D;N — command finished
--   on_output_line(line)         non-OSC, non-echoed output line
--   on_cwd(path)                 OSC 7 — shell changed directory
--   on_chips(chips, version)     OSC 7447 — semantic prompt chips
--   on_alternate_screen_enter()  ESC[?1049h — full-screen program took over
--   on_alternate_screen_exit()   ESC[?1049l — primary screen restored
--   on_passthrough(bytes)        raw bytes while the alternate screen is up
--   on_exit(exit_code)           job process exited
-- }
--
-- Carry table (threaded across chunks):
--   buf                    string      partial text line accumulator
--   osc                    string|nil  accumulating OSC body (nil = not in OSC)
--   csi                    string|nil  accumulating CSI parameters (nil = not in CSI)
--   escape_pending         bool        a lone ESC landed on a chunk boundary
--   skip_lines             bool        true between OSC 133;B and 133;C (suppress echoed input)
--   alternate_screen       bool        true between ESC[?1049h and ESC[?1049l
--   alternate_screen_tail  string      partial escape held back during passthrough

local M = {}

local _job_id = nil

-- Boxed so make_on_stdout can swap the carry table each chunk while
-- leave_alternate_screen can still reach the current one.
local _carry_ref = nil

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

-- parse_chips: decode an OSC 7447 chip payload — flat ";"-separated
-- <kind>;<label> pairs, with ";" and "%" percent-encoded inside labels.
-- Wire format is specified in docs/osc-7447.md; zsh/prompt_lcars.zsh's
-- _lcars_emit_chips is the emitting side.
-- Returns { { kind = "git", label = "main" }, ... } in emission order.
local function parse_chips(payload)
  local fields = {}
  for f in (payload .. ";"):gmatch("([^;]*);") do
    fields[#fields + 1] = f
  end
  local out = {}
  -- Pairs only: a trailing odd field is a truncated chip, so drop it.
  for i = 1, #fields - 1, 2 do
    if fields[i] ~= "" then
      out[#out + 1] = { kind = fields[i], label = percent_decode(fields[i + 1]) }
    end
  end
  return out
end

-- The OSC 7447 protocol version this parser speaks. See docs/osc-7447.md.
-- It is diagnostic, not gating: a mismatch warns and still renders, because a
-- skewed deploy should be visible, not fatal.
local PROTOCOL_VERSION = 1

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
    -- Versioned envelope: 7447;lcars;<version>;<message>[;<field>]...
    -- The version precedes the message type deliberately — after "chips" the
    -- fields are kind/label pairs read two at a time, so a version there would
    -- be read by a pre-version parser as a kind and the first real kind as its
    -- label. In front, a pre-version parser's ^7447;lcars;chips match simply
    -- fails and it ignores the message, which is the required behaviour for an
    -- unrecognised message rather than a silent misparse.
    local ver, msg = body:match("^7447;lcars;(%d+);(.*)$")
    if ver then
      local version = tonumber(ver)
      -- An empty chip set is a bare "...;chips" (no trailing ";"), and must
      -- still fire so a stale chip list gets cleared.
      if msg == "chips" then
        return { kind = "event", type = "chips", chips = {}, version = version }
      end
      local payload = msg:match("^chips;(.*)$")
      if payload then
        return { kind = "event", type = "chips", chips = parse_chips(payload), version = version }
      end
      -- Known version, unrecognised message type: ignore, per the spec.
      return nil
    end

    -- Unversioned legacy form, from a shell half deployed before the version
    -- existed. Parsed rather than dropped, and reported as version 0, so the
    -- reader can say "your zsh prompt is stale" instead of showing nothing —
    -- which would be indistinguishable from a shell that never emitted chips
    -- at all. That ambiguity is the failure this whole version field exists for.
    if body == "7447;lcars;chips" then
      return { kind = "event", type = "chips", chips = {}, version = 0 }
    end
    local legacy = body:match("^7447;lcars;chips;(.*)$")
    if legacy then
      return { kind = "event", type = "chips", chips = parse_chips(legacy), version = 0 }
    end
  end
  return nil
end

-- ── alternate screen ──────────────────────────────────────────────────────

-- The private DEC modes that swap the terminal to its alternate screen. 1049
-- (save cursor + switch + clear) is what every modern program emits; 1047 and
-- 47 are the older forms still present in some terminfo entries.
local ALTERNATE_SCREEN_MODES = { ["1049"] = true, ["1047"] = true, ["47"] = true }

-- parameters_select_alternate_screen("25;1049") → true
--
-- The membership test is not optional. Full-screen programs emit ESC[?25l
-- (hide cursor) constantly, and a naive "private mode ending in l" match would
-- read every one of those as an alternate-screen exit.
local function parameters_select_alternate_screen(parameters)
  for parameter in parameters:gmatch("[^;]+") do
    if ALTERNATE_SCREEN_MODES[parameter] then return true end
  end
  return false
end

-- Runaway-sequence cap for CSI, the analogue of the 4096-byte OSC cap. A real
-- CSI is a handful of bytes; anything past this is a desynced stream.
local CSI_MAX_LENGTH = 256

-- A CSI ends at its final byte, 0x40..0x7E. Everything before that is
-- parameter bytes (0x30..0x3F) and intermediates (0x20..0x2F).
local function is_csi_final_byte(b)
  local c = b:byte()
  return c >= 0x40 and c <= 0x7E
end

-- Append to the last passthrough item when there is one, so a chunk that
-- produces several adjacent slices becomes a single nvim_chan_send.
local function emit_passthrough(items, bytes)
  if bytes == "" then return end
  local last = items[#items]
  if last and last.kind == "passthrough" then
    last.bytes = last.bytes .. bytes
  else
    items[#items + 1] = { kind = "passthrough", bytes = bytes }
  end
end

-- ── parse_chunk ───────────────────────────────────────────────────────────

local function flush_line(state, items)
  if state.buf ~= "" and not state.skip_lines then
    items[#items + 1] = { kind = "line", text = strip_trailing_cr(state.buf) }
  end
  state.buf = ""
end

-- scan_text: the byte-at-a-time scanner for ordinary shell output. Returns ""
-- when it consumed the whole string, or the unconsumed remainder at the point
-- it switched to alternate-screen passthrough.
local function scan_text(state, bytes, items, carry)
  local i   = 1
  local len = #bytes

  while i <= len do
    local b = bytes:sub(i, i)

    if state.osc ~= nil then
      -- ── OSC accumulation mode ───────────────────────────────────────────
      -- Check for ST spanning a chunk boundary: if osc ends with \x1b and current byte is \x5c
      if b == "\x5c" and state.osc:sub(-1) == "\x1b" then
        state.osc = state.osc:sub(1, -2)  -- strip the pending \x1b sentinel
        local ev = parse_osc(state.osc, carry)
        if ev then items[#items + 1] = ev end
        state.osc = nil
        state.skip_lines = carry.skip_lines
        i = i + 1
      elseif b == "\x07" then
        -- BEL terminates OSC
        local ev = parse_osc(state.osc, carry)
        if ev then items[#items + 1] = ev end
        state.osc = nil
        state.skip_lines = carry.skip_lines  -- parse_osc may have mutated carry.skip_lines
        i = i + 1
      elseif b == "\x1b" then
        if i == len then
          -- ESC at very end of chunk — may be start of ST (\x1b\x5c); hold in carry
          -- Keep osc alive with a sentinel suffix so the next chunk continues in OSC mode
          -- and can detect \x5c as the ST terminator.
          state.osc = state.osc .. "\x1b"
          i = i + 1
        elseif bytes:sub(i + 1, i + 1) == "\x5c" then
          -- ST = ESC \ terminates OSC
          local ev = parse_osc(state.osc, carry)
          if ev then items[#items + 1] = ev end
          state.osc = nil
          state.skip_lines = carry.skip_lines
          i = i + 2
        else
          state.osc = state.osc .. b
          i = i + 1
        end
      else
        if #state.osc > 4096 then
          -- Safety cap: drop runaway OSC sequence
          vim.notify("lcars.pty_session: OSC sequence exceeded 4096 bytes, dropped", vim.log.levels.WARN)
          state.osc = nil
          state.buf = ""
          i = i + 1
        else
          state.osc = state.osc .. b
          i = i + 1
        end
      end

    elseif state.csi ~= nil then
      -- ── CSI accumulation mode ───────────────────────────────────────────
      -- Only here to spot the alternate-screen switch. Every other CSI is
      -- reassembled byte-identical into buf, because baleia consumes SGR
      -- codes out of the line text downstream — this state must be invisible
      -- to it.
      if #state.csi > CSI_MAX_LENGTH then
        vim.notify("lcars.pty_session: CSI sequence exceeded " .. CSI_MAX_LENGTH .. " bytes, dropped",
          vim.log.levels.WARN)
        state.csi = nil
      elseif b:byte() < 0x20 then
        -- A C0 control inside a CSI means the sequence was never a CSI (or the
        -- stream desynced). Put the raw bytes back and reprocess this byte as
        -- ordinary text rather than swallowing a line ending.
        state.buf = state.buf .. "\x1b[" .. state.csi
        state.csi = nil
      elseif is_csi_final_byte(b) then
        local parameters = state.csi
        state.csi = nil
        local private = parameters:match("^%?([%d;]*)$")
        if private and (b == "h" or b == "l") and parameters_select_alternate_screen(private) then
          flush_line(state, items)
          if b == "h" then
            items[#items + 1] = { kind = "event", type = "alternate_screen_enter" }
            state.alternate_screen = true
            -- Forward the switch itself so the emulator downstream sees a
            -- faithful stream and manages its own screen state.
            emit_passthrough(items, "\x1b[" .. parameters .. b)
            return bytes:sub(i + 1)
          end
          -- A restore with no matching switch — a program that only ever ran
          -- its terminfo "te" string, or a stream we joined mid-flight. Report
          -- it so the reader can resync; there is nothing to tear down here.
          items[#items + 1] = { kind = "event", type = "alternate_screen_exit" }
        else
          state.buf = state.buf .. "\x1b[" .. parameters .. b
        end
        i = i + 1
      else
        state.csi = state.csi .. b
        i = i + 1
      end

    elseif state.escape_pending then
      -- ── ESC seen, introducer byte not yet ───────────────────────────────
      -- Held as a flag rather than parked in buf so an ESC landing on a chunk
      -- boundary still introduces the OSC/CSI that follows it in the next
      -- chunk (lcarcat-biv).
      state.escape_pending = false
      if b == "]" then
        flush_line(state, items)
        state.osc = ""
        i = i + 1
      elseif b == "[" then
        state.csi = ""
        i = i + 1
      else
        -- Some other escape form (ESC ( B, ESC =, ESC 7 …). Preserve the ESC
        -- verbatim and reprocess this byte as ordinary text — same output the
        -- parser produced before CSI handling existed.
        state.buf = state.buf .. "\x1b"
      end

    else
      -- ── Text mode ──────────────────────────────────────────────────────
      if b == "\x1b" then
        state.escape_pending = true
        i = i + 1
      elseif b == "\r" then
        local b2 = bytes:sub(i + 1, i + 1)
        if b2 == "\n" then
          -- \r\n line ending
          if not state.skip_lines and state.buf ~= "" then
            items[#items + 1] = { kind = "line", text = state.buf }
          end
          state.buf = ""
          i = i + 2
        elseif i == len then
          -- \r at end of chunk — hold in carry (may be \r\n across boundary)
          state.buf = state.buf .. b
          i = i + 1
        else
          -- \r not followed by \n → cursor overwrite; drop the partial line
          state.buf = ""
          i = i + 1
        end
      elseif b == "\n" then
        flush_line(state, items)
        i = i + 1
      else
        state.buf = state.buf .. b
        i = i + 1
      end
    end
  end

  return ""
end

-- scan_passthrough: while the alternate screen is up, every byte belongs to
-- the full-screen program's emulator. The per-byte scanner is both wrong here
-- (there are no "lines") and far too slow — one full-screen redraw is tens of
-- kilobytes and `buf = buf .. b` is quadratic. Search for the restore sequence
-- and forward everything else in whole slices.
--
-- Returns "" when it consumed the whole string, or the remainder after the
-- restore sequence, which belongs to the text scanner again (the shell's
-- post-program prompt redraw and its OSC 133;A live there).
local function scan_passthrough(state, bytes, items)
  local chunk = state.alternate_screen_tail .. bytes
  state.alternate_screen_tail = ""

  local search = 1
  while true do
    local first, last, parameters = chunk:find("\x1b%[%?([%d;]*)l", search)
    if not first then break end
    if parameters_select_alternate_screen(parameters) then
      emit_passthrough(items, chunk:sub(1, last))
      items[#items + 1] = { kind = "event", type = "alternate_screen_exit" }
      state.alternate_screen = false
      return chunk:sub(last + 1)
    end
    search = last + 1
  end

  -- No restore in this chunk. Hold back a trailing partial escape so a restore
  -- split across chunks is still matched — ESC, ESC[, ESC[?, ESC[?10 and so on
  -- are all prefixes the next chunk can complete.
  local tail_start = chunk:find("\x1b%[?%??[%d;]*$")
  if tail_start then
    emit_passthrough(items, chunk:sub(1, tail_start - 1))
    state.alternate_screen_tail = chunk:sub(tail_start)
  else
    emit_passthrough(items, chunk)
  end
  return ""
end

-- parse_chunk(carry, bytes) → new_carry, items[]
--
-- Pure function — no vim API calls (safe for headless unit tests).
-- `carry` must be a table with fields: buf, osc, skip_lines.
-- Returns a new carry table and an ordered list of items.
function M._parse_chunk(carry, bytes)
  local items = {}
  local state = {
    buf                    = carry.buf        or "",
    osc                    = carry.osc,        -- nil | string
    csi                    = carry.csi,        -- nil | string
    escape_pending         = carry.escape_pending  or false,
    skip_lines             = carry.skip_lines      or false,
    alternate_screen       = carry.alternate_screen or false,
    alternate_screen_tail  = carry.alternate_screen_tail or "",
  }

  -- Alternate-screen transitions can happen mid-chunk in either direction, so
  -- the two scanners hand the unconsumed remainder back and forth.
  local rest = bytes
  while rest ~= "" do
    if state.alternate_screen then
      rest = scan_passthrough(state, rest, items)
    else
      rest = scan_text(state, rest, items, carry)
    end
  end
  return {
    buf                   = state.buf,
    osc                   = state.osc,
    csi                   = state.csi,
    escape_pending        = state.escape_pending,
    skip_lines            = state.skip_lines,
    alternate_screen      = state.alternate_screen,
    alternate_screen_tail = state.alternate_screen_tail,
  }, items
end

-- ── internal dispatch ─────────────────────────────────────────────────────

local function dispatch(callbacks, item)
  local t = item.type
  if     t == "prompt_start"  and callbacks.on_prompt_start  then callbacks.on_prompt_start()
  elseif t == "command_start" and callbacks.on_command_start then callbacks.on_command_start()
  elseif t == "command_exec"  and callbacks.on_command_exec  then callbacks.on_command_exec()
  elseif t == "command_done"  and callbacks.on_command_done  then callbacks.on_command_done(item.exit_code)
  elseif t == "cwd"           and callbacks.on_cwd           then callbacks.on_cwd(item.path)
  elseif t == "chips"         and callbacks.on_chips         then callbacks.on_chips(item.chips, item.version)
  elseif t == "alternate_screen_enter" and callbacks.on_alternate_screen_enter then
    callbacks.on_alternate_screen_enter()
  elseif t == "alternate_screen_exit"  and callbacks.on_alternate_screen_exit  then
    callbacks.on_alternate_screen_exit()
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
        elseif item.kind == "passthrough" then
          if callbacks.on_passthrough then callbacks.on_passthrough(item.bytes) end
        else
          dispatch(callbacks, item)
        end
      end
    end)
  end
end

-- ── public API ────────────────────────────────────────────────────────────

-- The OSC 7447 version this build speaks. terminal_win compares it against the
-- version on the wire to detect a half-deployed pair.
M.PROTOCOL_VERSION = PROTOCOL_VERSION

function M.start(shell_cmd, opts, callbacks)
  local carry_ref = { {
    buf                   = "",
    osc                   = nil,
    csi                   = nil,
    escape_pending        = false,
    skip_lines            = false,
    alternate_screen      = false,
    alternate_screen_tail = "",
  } }
  _carry_ref = carry_ref
  _job_id = vim.fn.jobstart(shell_cmd, {
    pty       = true,
    env       = {
      -- The reverse direction of the handshake. The shell cannot ask "is anyone
      -- listening?" over a pty without request/response machinery, but it does
      -- not have to: we spawned it, so we can just tell it in the environment.
      -- zsh/lcars_prompt_data.zsh reads this into _LCARS_OSC_PEER.
      LCARS_TERM_PROTO = tostring(PROTOCOL_VERSION),
      -- nvim defaults a pty job's TERM to "ansi", whose terminfo entry has no
      -- smcup — so no program would ever switch to the alternate screen and
      -- alternate-screen passthrough could never fire (lcarcat-biv). xterm-256color
      -- is what nvim's own :terminal uses and what the libvterm emulator behind
      -- nvim_open_term renders, so the two halves agree.
      TERM = (opts and opts.term) or "xterm-256color",
    },
    clear_env = false,
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

-- Keystrokes from a full-screen program's emulator: no trailing newline, no
-- interpretation. The alternate-screen float feeds its on_input straight here.
function M.send_raw(bytes)
  if _job_id then vim.fn.chansend(_job_id, bytes) end
end

-- Retell the child its terminal size (SIGWINCH). Used when handing the PTY to
-- a full-screen program sized to its own window, and by VimResized handling
-- (lcarcat-qm0.5).
function M.resize(width, height)
  if _job_id then vim.fn.jobresize(_job_id, width, height) end
end

-- Force the parser out of passthrough when a program died without restoring
-- the primary screen. Returns true if it was actually in passthrough.
-- Deliberately does not touch the child: this resyncs our view, it does not
-- kill anything.
function M.leave_alternate_screen()
  local carry = _carry_ref and _carry_ref[1]
  if not (carry and carry.alternate_screen) then return false end
  carry.alternate_screen      = false
  carry.alternate_screen_tail = ""
  return true
end

function M.stop()
  if _job_id then vim.fn.jobstop(_job_id) end
  _job_id = nil
  _carry_ref = nil
end

return M
