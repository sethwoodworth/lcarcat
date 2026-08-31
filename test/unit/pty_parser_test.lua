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

-- ── test 18: OSC 7447 chip payload ───────────────────────────────────────

-- The wire form is versioned: ESC ] 7447 ; lcars ; <ver> ; chips [...] ST.
-- V is the version this parser speaks; tests below use it unless they are
-- deliberately exercising a mismatch.
local V = 1
local function chips_osc(payload, ver)
  return ESC .. "]7447;lcars;" .. (ver or V) .. ";chips" .. (payload or "") .. ST
end
local function ev_chips(c, ver)
  return { kind = "event", type = "chips", chips = c, version = ver or V }
end

do
  local _, items = parse(fresh(), chips_osc(";git;main;venv;lcarcat"))
  deep_eq("18a chips", items, { ev_chips({
    { kind = "git",  label = "main" },
    { kind = "venv", label = "lcarcat" },
  }) })
end

-- ── test 19: empty chip set still fires (clears a stale list) ─────────────

do
  local _, items = parse(fresh(), chips_osc())
  deep_eq("19a chips", items, { ev_chips({}) })
end

-- ── test 20: percent-decoding of ";" and "%" inside a chip label ──────────

do
  local _, items = parse(fresh(), chips_osc(";git;feat%3Ba;venv;v%25x"))
  deep_eq("20a chips", items, { ev_chips({
    { kind = "git",  label = "feat;a" },
    { kind = "venv", label = "v%x" },
  }) })
end

-- ── test 21: truncated trailing field is dropped, not half-emitted ────────

do
  local _, items = parse(fresh(), chips_osc(";git;main;venv"))
  deep_eq("21a chips", items, { ev_chips({ { kind = "git", label = "main" } }) })
end

-- ── test 22: chip payload split across a chunk boundary ──────────────────

do
  local c1, i1 = parse(fresh(), ESC .. "]7447;lcars;" .. V .. ";chi")
  deep_eq("22a items", i1, {})
  local _, i2 = parse(c1, "ps;git;main" .. ST)
  deep_eq("22b items", i2, { ev_chips({ { kind = "git", label = "main" } }) })
end

-- ── test 23: an empty label survives as an empty string, kind intact ─────

do
  local _, items = parse(fresh(), chips_osc(";err;;git;main"))
  deep_eq("23a chips", items, { ev_chips({
    { kind = "err", label = "" },
    { kind = "git", label = "main" },
  }) })
end

-- ── test 24: the version reaches the consumer ────────────────────────────
-- It is diagnostic, not gating: parsing must succeed for a version we do not
-- speak, so a skewed deploy still renders while the reader warns about it.

do
  local _, items = parse(fresh(), chips_osc(";git;main", 99))
  deep_eq("24a a future version still parses", items,
    { ev_chips({ { kind = "git", label = "main" } }, 99) })
end

-- ── test 25: the unversioned legacy form reports version 0 ───────────────
-- A shell half deployed before versioning existed. Parsed rather than dropped,
-- so the reader can say "your zsh prompt is stale" instead of showing nothing —
-- which would look exactly like a shell that never emitted chips at all. That
-- ambiguity is the failure the version field exists to remove.

do
  local _, items = parse(fresh(), ESC .. "]7447;lcars;chips;git;main" .. ST)
  deep_eq("25a legacy payload parses as version 0", items,
    { ev_chips({ { kind = "git", label = "main" } }, 0) })
end

do
  local _, items = parse(fresh(), ESC .. "]7447;lcars;chips" .. ST)
  deep_eq("25b legacy empty set parses as version 0", items, { ev_chips({}, 0) })
end

-- ── test 26: unknown message type on a known version is ignored ──────────
-- Message-type-as-version survives alongside the envelope version: a future
-- message this build does not know must vanish, not misparse.

do
  local _, items = parse(fresh(), ESC .. "]7447;lcars;" .. V .. ";sparklines;1;2;3" .. ST)
  deep_eq("26a unknown message ignored", items, {})
end

-- A foreign namespace is ignored regardless of version.
do
  local _, items = parse(fresh(), ESC .. "]7447;notlcars;" .. V .. ";chips;git;main" .. ST)
  deep_eq("26b foreign namespace ignored", items, {})
end

-- ── alternate-screen passthrough (lcarcat-biv) ───────────────────────────
--
-- While a full-screen program owns the screen the parser stops building lines
-- and forwards raw bytes to a real emulator instead. These cases pin the two
-- transitions, which arrive in a byte stream that can split them anywhere.

local function pt(bytes)  return { kind = "passthrough", bytes = bytes } end

-- A carry already inside passthrough, as the next chunk would find it.
local function in_alternate_screen()
  return { buf = "", osc = nil, skip_lines = false,
           alternate_screen = true, alternate_screen_tail = "" }
end

-- ── test 27: entering flushes the pending line, then forwards the switch ──
-- The switch sequence itself goes downstream so the emulator sees a faithful
-- stream and manages its own screen state.

do
  local carry, items = parse(fresh(), "hello" .. ESC .. "[?1049h")
  deep_eq("27a enter", items, {
    line("hello"),
    ev("alternate_screen_enter"),
    pt(ESC .. "[?1049h"),
  })
  eq("27b carry is in passthrough", carry.alternate_screen, true)
end

-- ── test 28: the switch split at every byte boundary still lands ─────────
-- The reason ESC is carried as a flag rather than parked in buf: a chunk that
-- ends on the ESC must still introduce the CSI that follows it.

do
  local splits = { 1, 2, 3, 5, 7 }  -- after ESC, ESC[, ESC[?, ESC[?10, ESC[?1049
  local whole  = ESC .. "[?1049h"
  for _, at in ipairs(splits) do
    local carry, items = parse(fresh(), whole:sub(1, at))
    deep_eq("28 split at " .. at .. " emits nothing yet", items, {})
    local _, rest = parse(carry, whole:sub(at + 1))
    deep_eq("28 split at " .. at .. " completes", rest, {
      ev("alternate_screen_enter"),
      pt(ESC .. "[?1049h"),
    })
  end
end

-- ── test 29: ESC[?25l is not an exit ─────────────────────────────────────
-- Full-screen programs hide the cursor constantly. A "private mode ending in
-- l" match would read every one of those as a restore and drop out of
-- passthrough mid-program.

do
  local carry, items = parse(in_alternate_screen(), ESC .. "[?25l" .. "drawing")
  deep_eq("29a hide-cursor forwarded, no exit", items, { pt(ESC .. "[?25l" .. "drawing") })
  eq("29b still in passthrough", carry.alternate_screen, true)
end

-- ── test 30: exiting hands the remainder back to the text scanner ────────
-- The shell's post-program prompt redraw — including its OSC 133;A — arrives
-- in the same chunk as the restore, and must be parsed, not forwarded.

do
  local carry, items = parse(in_alternate_screen(),
    ESC .. "[?1049l" .. ESC .. "]133;A" .. ST .. "back\n")
  deep_eq("30a exit", items, {
    pt(ESC .. "[?1049l"),
    ev("alternate_screen_exit"),
    ev("prompt_start"),
    line("back"),
  })
  eq("30b carry left passthrough", carry.alternate_screen, false)
end

-- ── test 31: a restore split across chunks is held back, not forwarded ───
-- Forwarding a partial escape would hand the emulator half a sequence and
-- leave us in passthrough forever.

do
  local carry, items = parse(in_alternate_screen(), "abc" .. ESC .. "[?10")
  deep_eq("31a partial restore held back", items, { pt("abc") })
  eq("31b tail carried", carry.alternate_screen_tail, ESC .. "[?10")

  local carry2, items2 = parse(carry, "49l")
  deep_eq("31c completes on the next chunk", items2, {
    pt(ESC .. "[?1049l"),
    ev("alternate_screen_exit"),
  })
  eq("31d tail cleared", carry2.alternate_screen_tail, "")
end

-- ── test 32: the older alternate-screen modes count too ──────────────────
-- 1047 and 47 predate 1049 and still appear in some terminfo entries.

do
  local _, items = parse(fresh(), ESC .. "[?1047h")
  deep_eq("32a 1047 enters", items, { ev("alternate_screen_enter"), pt(ESC .. "[?1047h") })

  local _, items47 = parse(fresh(), ESC .. "[?47h")
  deep_eq("32b 47 enters", items47, { ev("alternate_screen_enter"), pt(ESC .. "[?47h") })

  -- Combined with another private mode in one sequence.
  local _, both = parse(fresh(), ESC .. "[?1049;25h")
  deep_eq("32c a combined parameter list still enters", both,
    { ev("alternate_screen_enter"), pt(ESC .. "[?1049;25h") })
end

-- ── test 33: every other CSI reaches the line text byte-identical ────────
-- The regression guard for the whole CSI-scanning change. baleia consumes SGR
-- codes out of the line text downstream, so the new parser state has to be
-- invisible to it.

do
  local _, items = parse(fresh(), ESC .. "[1;31mred" .. ESC .. "[0m" .. "\n")
  deep_eq("33a SGR preserved", items, { line(ESC .. "[1;31mred" .. ESC .. "[0m") })

  -- Cursor addressing, erase, and a non-private h/l are all just text here.
  local _, moves = parse(fresh(), ESC .. "[2J" .. ESC .. "[10;5H" .. ESC .. "[4hx\n")
  deep_eq("33b other CSI preserved", moves,
    { line(ESC .. "[2J" .. ESC .. "[10;5H" .. ESC .. "[4hx") })

  -- A CSI split across chunks is reassembled, not dropped.
  local carry, none = parse(fresh(), "a" .. ESC .. "[1;3")
  deep_eq("33c nothing emitted mid-CSI", none, {})
  local _, rest = parse(carry, "1mb\n")
  deep_eq("33d reassembled across the boundary", rest, { line("a" .. ESC .. "[1;31mb") })
end

-- ── test 34: a C0 control inside a CSI aborts it ─────────────────────────
-- Guards against a desynced stream swallowing a line ending forever: the raw
-- bytes go back into the line and the control byte is handled normally.

do
  local _, items = parse(fresh(), "x" .. ESC .. "[12\nrest\n")
  deep_eq("34a newline ends the line rather than feeding the CSI", items,
    { line("x" .. ESC .. "[12"), line("rest") })
end

-- ── summary ───────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", PASS, FAIL))
if FAIL > 0 then
  vim.cmd("cq 1")
else
  vim.cmd("qa!")
end
