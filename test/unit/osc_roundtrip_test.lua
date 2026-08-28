-- Parses bytes produced by the real zsh emitter (see run_osc_roundtrip_tests.sh)
-- and asserts on what comes out. Neither side's idea of the wire format is
-- hand-written here: the shell wrote the bytes, this parses them.

local PASS, FAIL = 0, 0

local function deep_eq(label, got, exp)
  local gs, es = vim.inspect(got), vim.inspect(exp)
  if gs == es then PASS = PASS + 1 else
    FAIL = FAIL + 1
    print(string.format("FAIL [%s]:\n  expected: %s\n  got:      %s", label, es, gs))
  end
end

local function eq(label, got, exp)
  if got == exp then PASS = PASS + 1 else
    FAIL = FAIL + 1
    print(string.format("FAIL [%s]: expected %s, got %s", label, tostring(exp), tostring(got)))
  end
end

-- Any error below would otherwise leave headless nvim running forever, since
-- the qa! at the bottom never executes. Bail loudly instead.
local function bail(msg)
  print("FAIL: " .. msg)
  vim.cmd("cq 1")
end

local pty = require("lcars.pty_session")
if type(pty._parse_chunk) ~= "function" then bail("pty_session._parse_chunk missing") end

local f = assert(io.open(vim.g.lcars_wire_file, "rb"))
local bytes = f:read("*a")
f:close()

local carry = { buf = "", osc = nil, skip_lines = false }
local _, items = pty._parse_chunk(carry, bytes)

-- Exactly one chips event came out of the shell's single emit call.
eq("1a one event parsed from the emitted bytes", #items, 1)

local ev = items[1] or {}
eq("1b it is a chips event", ev.type, "chips")

-- The emitter and this parser must agree on the protocol version. If this
-- fails, the two halves of the repo disagree with each other — which is the
-- exact condition the version field was added to surface.
eq("1c version matches what this parser speaks", ev.version, pty.PROTOCOL_VERSION)

deep_eq("2a labels survive the round trip intact", ev.chips, {
  { kind = "venv",     label = "lcarcat" },
  { kind = "py",       label = "py 3.12" },      -- a space is not a separator
  { kind = "awsdep",   label = "AWS|dep" },
  { kind = "git",      label = "feat;semi" },    -- %3B decoded back to ";"
  { kind = "gitstate", label = "02-MODIFIED" },
  { kind = "err",      label = "" },             -- empty label, kind intact
  { kind = "git",      label = "100%done" },     -- %25 decoded back to "%"
  { kind = "git",      label = "%3B" },          -- literal %3B, NOT ";"
})

-- The last case is the one that fails if % is not encoded before ";": the
-- emitter would write "%3B" unescaped, and this parser would decode it to ";",
-- silently turning a label into a field separator.
eq("2b percent was encoded before semicolon",
   (ev.chips[8] or {}).label, "%3B")

print(string.format("\nosc_roundtrip: %d passed, %d failed", PASS, FAIL))
if FAIL > 0 then
  vim.cmd("cq 1")
else
  vim.cmd("qa!")
end
