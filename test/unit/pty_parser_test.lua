-- Headless unit tests for lcars.pty_session._parse_chunk
-- Run with: bash test/unit/run_parser_tests.sh
-- Or directly: nvim --clean --headless \
--   -c "lua package.path=package.path..';nvim/lua/?.lua'" \
--   -c "luafile test/unit/pty_parser_test.lua"
--
-- --clean, not -u NONE: -u NONE still leaves ~/.config/nvim on 'runtimepath',
-- and nvim's package loader searches rtp lua/ dirs before package.path, so the
-- deployed copy of lcars.* silently shadows the repo copy under test.

-- ── minimal test runner ───────────────────────────────────────────────────

local PASS, FAIL = 0, 0

local function eq(label, got, exp)
  if got == exp then
    PASS = PASS + 1
  else
    FAIL = FAIL + 1
    print(string.format("FAIL [%s]: expected %s, got %s",
      label, tostring(exp), tostring(got)))
  end
end

local function deep_eq(label, got, exp)
  local gs = vim.inspect(got)
  local es = vim.inspect(exp)
  if gs == es then
    PASS = PASS + 1
  else
    FAIL = FAIL + 1
    print(string.format("FAIL [%s]:\n  expected: %s\n  got:      %s", label, es, gs))
  end
end

-- Stub vim.notify so safety-cap test doesn't crash in headless
local notify_calls = {}
vim.notify = function(msg, _) notify_calls[#notify_calls + 1] = msg end

-- ── load module ───────────────────────────────────────────────────────────

local ps    = require("lcars.pty_session")
local parse = ps._parse_chunk

local function fresh() return { buf = "", osc = nil, skip_lines = false } end

-- ── helpers ───────────────────────────────────────────────────────────────

local ESC = "\x1b"
local BEL = "\x07"
local ST  = "\x1b\x5c"  -- ESC \

local function line(t)  return { kind = "line",  text = t } end
local function ev(t)    return { kind = "event", type = t } end
local function ev_done(n) return { kind = "event", type = "command_done", exit_code = n } end
local function ev_cwd(p)  return { kind = "event", type = "cwd", path = p } end

-- ── test 1: single complete line, no OSC ─────────────────────────────────

do
  local carry, items = parse(fresh(), "hello\r\n")
  deep_eq("1a items", items, { line("hello") })
  eq("1b buf",        carry.buf,        "")
  eq("1c skip_lines", carry.skip_lines, false)
end

-- ── test 2: line split across two chunks ─────────────────────────────────

do
  local c1, i1 = parse(fresh(), "hel")
  deep_eq("2a items", i1, {})
  eq("2b carry.buf", c1.buf, "hel")

  local c2, i2 = parse(c1, "lo\r\n")
  deep_eq("2c items", i2, { line("hello") })
  eq("2d carry.buf", c2.buf, "")
end

-- ── test 3: OSC 133;A with BEL terminator ────────────────────────────────

do
  local _, items = parse(fresh(), ESC .. "]133;A" .. BEL)
  deep_eq("3 items", items, { ev("prompt_start") })
end

-- ── test 4: OSC 133;A with ST terminator ─────────────────────────────────

do
  local _, items = parse(fresh(), ESC .. "]133;A" .. ST)
  deep_eq("4 items", items, { ev("prompt_start") })
end

-- ── test 5: OSC spanning chunk boundary ──────────────────────────────────

do
  local c1, i1 = parse(fresh(), ESC .. "]133;")
  deep_eq("5a items", i1, {})
  -- carry.osc should be accumulating "133;" (started, not finished)
  eq("5b carry.osc non-nil", c1.osc ~= nil, true)

  local c2, i2 = parse(c1, "A" .. BEL)
  deep_eq("5c items", i2, { ev("prompt_start") })
  eq("5d carry.osc nil", c2.osc, nil)
end

-- ── test 6: ESC alone at end of chunk (partial ST) ───────────────────────

do
  local c1, i1 = parse(fresh(), ESC .. "]133;A" .. ESC)
  deep_eq("6a items", i1, {})
  -- The partial sequence should be held in carry
  eq("6b carry non-empty", c1.buf ~= "" or c1.osc ~= nil, true)

  -- On next chunk, ST completes the sequence
  local _, i2 = parse(c1, "\x5c")
  deep_eq("6c items", i2, { ev("prompt_start") })
end

-- ── test 7: OSC 133;D;0 → command_done exit_code=0 ───────────────────────

do
  local _, items = parse(fresh(), ESC .. "]133;D;0" .. BEL)
  deep_eq("7 items", items, { ev_done(0) })
end

-- ── test 8: OSC 133;D;127 → command_done exit_code=127 ───────────────────

do
  local _, items = parse(fresh(), ESC .. "]133;D;127" .. BEL)
  deep_eq("8 items", items, { ev_done(127) })
end

-- ── test 9: OSC 7 cwd, plain path ────────────────────────────────────────

do
  local _, items = parse(fresh(), ESC .. "]7;file://mymac/Users/seth/code" .. BEL)
  deep_eq("9 items", items, { ev_cwd("/Users/seth/code") })
end

-- ── test 10: OSC 7 with percent-encoded space ────────────────────────────

do
  local _, items = parse(fresh(), ESC .. "]7;file://mymac/Users/seth/my%20project" .. BEL)
  deep_eq("10 items", items, { ev_cwd("/Users/seth/my project") })
end

-- ── test 11: mixed OSC + text in one chunk ────────────────────────────────

do
  local input = ESC .. "]133;C" .. BEL      -- command_exec
                .. "output line\r\n"         -- output line (skip_lines=false after C)
                .. "another\r\n"             -- output line
                .. ESC .. "]133;D;0" .. BEL  -- command_done
  local _, items = parse(fresh(), input)
  deep_eq("11 items", items, {
    ev("command_exec"),
    line("output line"),
    line("another"),
    ev_done(0),
  })
end

-- ── test 12: \r\n normalization — no \r in emitted text ──────────────────

do
  local _, items = parse(fresh(), "foo\r\nbar\r\n")
  deep_eq("12 items", items, { line("foo"), line("bar") })
end

-- ── test 13: bare \n (no \r) ─────────────────────────────────────────────

do
  local _, items = parse(fresh(), "foo\nbar\n")
  deep_eq("13 items", items, { line("foo"), line("bar") })
end

-- ── test 14: skip_lines between 133;B and 133;C ──────────────────────────

do
  -- 133;B sets skip_lines; echoed text "ls\r\n" should NOT appear as output
  local input = ESC .. "]133;B" .. BEL  -- command_start, skip_lines=true
                .. "ls\r\n"              -- echoed keystrokes — must be suppressed
                .. ESC .. "]133;C" .. BEL -- command_exec, skip_lines=false
                .. "file.txt\r\n"        -- real output — must appear
  local _, items = parse(fresh(), input)
  deep_eq("14 items", items, {
    ev("command_start"),
    ev("command_exec"),
    line("file.txt"),
  })
end

-- ── test 15: OSC safety cap (>4096 bytes body) ───────────────────────────

do
  notify_calls = {}
  local huge_osc = ESC .. "]" .. string.rep("x", 5000)
  local c1, i1 = parse(fresh(), huge_osc)
  -- Should not hang or accumulate unbounded carry; notify should have fired
  eq("15a no items",      #i1, 0)
  eq("15b notify fired",  #notify_calls > 0, true)
  -- Carry should be in a recoverable state (osc nil or buf short)
  eq("15c osc nil",       c1.osc, nil)
end

-- ── test 16: trailing \r held across a chunk boundary, then a bare \n ────
-- (the \r must not leak into the emitted line as a literal ^M)

do
  local c1, i1 = parse(fresh(), "foo\r")
  deep_eq("16a items", i1, {})
  eq("16b carry.buf", c1.buf, "foo\r")

  local _, i2 = parse(c1, "\n")
  deep_eq("16c items", i2, { line("foo") })
end

-- ── test 17: trailing \r held across a chunk boundary, then an OSC start ──

do
  local c1, i1 = parse(fresh(), "foo\r")
  deep_eq("17a items", i1, {})

  local _, i2 = parse(c1, ESC .. "]133;C" .. BEL)
  deep_eq("17b items", i2, { line("foo"), ev("command_exec") })
end

-- ── test 18: OSC 7337 chip payload ───────────────────────────────────────

local function ev_chips(c) return { kind = "event", type = "chips", chips = c } end

do
  local _, items = parse(fresh(), ESC .. "]7337;lcars;chips;git;main;venv;lcarcat" .. ST)
  deep_eq("18a chips", items, { ev_chips({
    { kind = "git",  label = "main" },
    { kind = "venv", label = "lcarcat" },
  }) })
end

-- ── test 19: empty chip set still fires (clears a stale list) ─────────────

do
  local _, items = parse(fresh(), ESC .. "]7337;lcars;chips" .. ST)
  deep_eq("19a chips", items, { ev_chips({}) })
end

-- ── test 20: percent-decoding of ";" and "%" inside a chip label ──────────

do
  local _, items = parse(fresh(), ESC .. "]7337;lcars;chips;git;feat%3Ba;venv;v%25x" .. ST)
  deep_eq("20a chips", items, { ev_chips({
    { kind = "git",  label = "feat;a" },
    { kind = "venv", label = "v%x" },
  }) })
end

-- ── test 21: truncated trailing field is dropped, not half-emitted ────────

do
  local _, items = parse(fresh(), ESC .. "]7337;lcars;chips;git;main;venv" .. ST)
  deep_eq("21a chips", items, { ev_chips({ { kind = "git", label = "main" } }) })
end

-- ── test 22: chip payload split across a chunk boundary ──────────────────

do
  local c1, i1 = parse(fresh(), ESC .. "]7337;lcars;chi")
  deep_eq("22a items", i1, {})
  local _, i2 = parse(c1, "ps;git;main" .. ST)
  deep_eq("22b items", i2, { ev_chips({ { kind = "git", label = "main" } }) })
end

-- ── test 23: an empty label survives as an empty string, kind intact ─────

do
  local _, items = parse(fresh(), ESC .. "]7337;lcars;chips;err;;git;main" .. ST)
  deep_eq("23a chips", items, { ev_chips({
    { kind = "err", label = "" },
    { kind = "git", label = "main" },
  }) })
end

-- ── summary ───────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", PASS, FAIL))
if FAIL > 0 then
  vim.cmd("cq 1")
else
  vim.cmd("qa!")
end
