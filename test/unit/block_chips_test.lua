-- Headless unit tests for lcars.block_chips and frame_renderer's chip fitting.
-- Run with: bash test/unit/run_chips_tests.sh

local PASS, FAIL = 0, 0

local function eq(label, got, exp)
  if got == exp then PASS = PASS + 1 else
    FAIL = FAIL + 1
    print(string.format("FAIL [%s]: expected %s, got %s", label, tostring(exp), tostring(got)))
  end
end

local function deep_eq(label, got, exp)
  local gs, es = vim.inspect(got), vim.inspect(exp)
  if gs == es then PASS = PASS + 1 else
    FAIL = FAIL + 1
    print(string.format("FAIL [%s]:\n  expected: %s\n  got:      %s", label, es, gs))
  end
end

local bc = require("lcars.block_chips")
local fr = require("lcars.frame_renderer")

-- ── from_osc: kind → highlight group, kind retained as drop group ─────────

do
  local out = bc.from_osc({
    { kind = "git",  label = "main" },
    { kind = "venv", label = "lcarcat" },
  })
  deep_eq("1a mapping", out, {
    { "main",    "LcarsTermChipGit",  "git"  },
    { "lcarcat", "LcarsTermChipVenv", "venv" },
  })
end

-- An unknown kind must still render rather than vanish.
do
  local out = bc.from_osc({ { kind = "quantum", label = "flux" } })
  deep_eq("1b unknown kind", out, { { "flux", "LcarsTermChipGit", "quantum" } })
end

-- Empty labels are dropped: a chip with nothing to say takes bar space anyway.
do
  deep_eq("1c empty label", bc.from_osc({ { kind = "git", label = "" } }), {})
  deep_eq("1d nil input",   bc.from_osc(nil), {})
end

-- ── duration_label ────────────────────────────────────────────────────────

-- Pin the threshold rather than inheriting CMD_DURATION_THRESHOLD from whatever
-- environment the suite happens to run in.
bc.duration_threshold_ms = 2000

eq("2a under threshold",   bc.duration_label(1.9), nil)
eq("2b nil in nil out",    bc.duration_label(nil), nil)
eq("2c at threshold",      bc.duration_label(2.0), "2.0S")
eq("2d seconds",           bc.duration_label(12.44), "12.4S")
eq("2e minutes",           bc.duration_label(200),   "03-20M")
eq("2f hours",             bc.duration_label(3900),  "01-05H")

-- The threshold is a live knob, not a load-time constant.
do
  bc.duration_threshold_ms = 0
  eq("2m threshold 0 shows everything", bc.duration_label(0.2), "0.2S")
  bc.duration_threshold_ms = 2000
  eq("2n threshold restored", bc.duration_label(0.2), nil)
end

-- ── outcome: footer chips derived from a finished block ──────────────────

do
  -- Success, slow enough to be worth a duration chip.
  deep_eq("2g ok slow", bc.outcome({ exit_code = 0, duration = 90 }),
    { { "01-30M", "LcarsTermChipDur", "dur" } })

  -- Success, under the threshold: an empty footer. That is the common case.
  deep_eq("2h ok fast", bc.outcome({ exit_code = 0, duration = 0.2 }), {})

  -- Failure always reports, however brief. ERR is listed last, so it draws
  -- rightmost in the left-aligned footer run.
  deep_eq("2i failed", bc.outcome({ exit_code = 1, duration = 2.5 }), {
    { "2.5S",   "LcarsTermChipDur", "dur" },
    { "ERR-01", "LcarsTermChipErr", "err" },
  })
  deep_eq("2j failed fast", bc.outcome({ exit_code = 130, duration = 0.1 }),
    { { "ERR-130", "LcarsTermChipErr", "err" } })

  -- A live block has neither yet.
  deep_eq("2k live", bc.outcome({ exit_code = nil, duration = nil }), {})
  deep_eq("2l nil rec", bc.outcome(nil), {})
end

-- ── chips_width: must mirror header_chips's placement arithmetic ─────────

-- No chips, no gaps.
eq("3a empty",     fr.chips_width({}), 0)
eq("3b nil",       fr.chips_width(nil), 0)
-- 1 leading gap + (4 label + 2 cushion + 1 trailing gap).
eq("3c one chip",  fr.chips_width({ { "main" } }), 1 + 7)
-- Gaps comb: 2 chips draw 3 gaps, not 4.
eq("3d two chips", fr.chips_width({ { "main" }, { "uv" } }), 1 + 7 + 5)

-- ── fit_chips: sheds whole groups in priority order ──────────────────────

local function labels(list)
  local out = {}
  for _, c in ipairs(list) do out[#out + 1] = c[1] end
  return out
end

do
  local full = bc.from_osc({
    { kind = "venv",     label = "lcarcat" },
    { kind = "py",       label = "py 3.11" },
    { kind = "aws",      label = "AWS|dep" },
    { kind = "git",      label = "main" },
    { kind = "gitstate", label = "01-MODIFIED" },
    { kind = "gitstate", label = "03-UNTRACKED" },
  })

  local wide = fr.chips_width(full)
  deep_eq("4a nothing dropped", labels(fr.fit_chips(full, wide)), labels(full))

  -- One column short: the lowest-priority group (aws) goes first.
  deep_eq("4b sheds aws", labels(fr.fit_chips(full, wide - 1)),
    { "lcarcat", "py 3.11", "main", "01-MODIFIED", "03-UNTRACKED" })

  -- Nothing fits at all.
  deep_eq("4c all shed", labels(fr.fit_chips(full, 2)), {})

  -- fit_chips must not mutate its input.
  eq("4d input untouched", #full, 6)

  -- Whole gitstate group sheds together, not one chip at a time.
  local narrow = fr.fit_chips(full, 30)
  local n_state = 0
  for _, c in ipairs(narrow) do if c[3] == "gitstate" then n_state = n_state + 1 end end
  eq("4e gitstate is all-or-nothing", n_state == 0 or n_state == 2, true)

  -- Branch outranks git state: whatever survives longest is the branch.
  deep_eq("4f branch is last to go", labels(fr.fit_chips(full, 8)), { "main" })
end

-- Untagged chips (block_demo's fixed lists) still fit and still shed.
do
  local demo = { { "main", "LcarsBlockChipGo" }, { "~/code", "LcarsBlockChipSk" } }
  deep_eq("5a untagged fit", labels(fr.fit_chips(demo, 100)), { "main", "~/code" })
  deep_eq("5b untagged shed", labels(fr.fit_chips(demo, 5)), {})
end

-- ── chips_avail: the cwd hole chip is charged against the budget ─────────

-- bar region = (60-2) - (5-1) = 54; minus the elbow-overlap col and the 2
-- pre-cap cols = 51.
eq("6a no cwd", fr.chips_avail(60, nil), 51)
eq("6b empty cwd", fr.chips_avail(60, ""), 51)
-- minus the hole chip ("~/code/lcarcat" + 2 cushion) and its 1-col separator.
eq("6c with cwd", fr.chips_avail(60, "~/code/lcarcat"), 51 - 16 - 1)

print(string.format("\n%d passed, %d failed", PASS, FAIL))
if FAIL > 0 then vim.cmd("cq 1") else vim.cmd("qa!") end
