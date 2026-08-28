# Testing

lcarcat has two complementary test layers:

- **Headless unit tests** (`test/unit/`) — pure-Lua logic tests, no nvim display, no kitty required. Fast, deterministic, CI-runnable. Currently cover `pty_session._parse_chunk` and `block_chips` + `frame_renderer`'s chip fitting.
- **Visual / screenshot tests** — kitty-harness-driven capture scripts and integration tests. Required for anything involving nvim rendering, image placement, or terminal interaction.

This document is the entry point: what exists, and how to run it. The detail
lives in two siblings:

| You need to… | Read |
|--------------|------|
| write or debug a scenario script; drive the detached kitty; timing and scripted-input gotchas | [`docs/test-harness.md`](test-harness.md) |
| answer a question about rendered output — cell colors, cell coordinates, line widths | [`docs/test-tools.md`](test-tools.md) |
| drive nvim itself via the kitty socket (tab nav, messages, image timing) | [`docs/nvim-harness.md`](nvim-harness.md) |

---

## Quick reference: which tool for which question

| Question | Tool |
|----------|------|
| Did nvim actually *set* periwinkle on those cells? | `get_cell_grid.py --expect-bg periwinkle` ← **prefer this for assertions** |
| Did the gutter render as periwinkle on screen? | `analyze_gutter_cells.py --expect-bg periwinkle` |
| Is the elbow image flush with the stem bg cell? | `analyze_left_edge.py` |
| Where is a color in the PNG, exactly? | `analyze_left_edge.py` (raw row scan) |
| Which cell column/row does a rendered element occupy? | `overlay_grid.py` — annotate screenshot with cell boundary grid |
| Something renders wrong but cells look right | rendering bug — check CSI 16t / font size |
| Cells have the wrong color but nvim config looks right | logic bug — check highlight groups in `nvim/colors/lcars.lua` |

Full usage for each of these tools — flags, coordinate systems, caveats — is in
[`docs/test-tools.md`](test-tools.md).

**Prefer the semantic check (`get_cell_grid.py`) for programmatic assertions.** It reads kitty's terminal model directly and does not depend on screenshot timing. The pixel check (`analyze_gutter_cells.py`) is useful for visual confirmation and diagnosing rendering bugs downstream of the terminal model, but screenshot timing makes it unreliable as a pass/fail gate — a screenshot taken a few milliseconds before nvim finishes painting will silently show the wrong color.

A pixel check passing with a semantic check failing means the right color reached the screen despite wrong SGR state (possible with compositor caching, but unlikely). Pixel failing with semantic passing is a rendering or anti-aliasing bug, not a logic bug.

---

## Headless unit tests

> **Run these with `nvim --clean`, never `nvim -u NONE`.** `-u NONE` skips config
> *files* but leaves `~/.config/nvim` on `'runtimepath'`, and nvim's package loader
> searches rtp `lua/` dirs **before** `package.path`. Since `deploy.sh` copies
> `lcars/*.lua` there, `require("lcars.X")` resolves to the *deployed* copy and the
> suite silently tests whatever was last deployed instead of the working tree. This
> bit us: newly added code appeared to do nothing at all. `package.searchpath` still
> reports the repo path, because the rtp loader is a different searcher — so that is
> not a reliable check either.

### test/unit/run_parser_tests.sh

Tests `lcars.pty_session._parse_chunk` — the pure OSC 133 parser and carry-buffer logic.

```bash
bash test/unit/run_parser_tests.sh
```

Runs under `nvim --headless -u NONE`. No kitty, no display, no plugin dependencies. Exit 0 = all pass.

**Test convention** (pattern for future headless tests):
- Minimal pure-Lua runner in `test/unit/<module>_test.lua` — no busted or plenary.

### test/unit/run_chips_tests.sh

```bash
bash test/unit/run_chips_tests.sh
```

Covers `lcars.block_chips` (OSC 7447 chip kind → highlight group, duration
formatting and its `CMD_DURATION_THRESHOLD` knob, footer outcome chips) and
`frame_renderer`'s chip geometry (`chips_width`, `chips_avail`, `fit_chips`
drop-priority).

Note the standing gap: `chips_width()` asserts against hand-computed numbers, not
against `chip_run()`'s actual placement. The two are documented as mirrors and
nothing enforces it — see `lcarcat-qm0.10`.
- Call `vim.cmd("cq 1")` on any failure so nvim exits nonzero.
- Expose the function under test as `M._function_name` in the module (Lua convention for semi-private testable functions).

---

## Test hierarchy

Scripts are split into two directories based on whether they have machine-verifiable exit codes.

### test/integration/ — pass/fail, CI-runnable

Each script exits 0 on pass, 1 on failure. Safe to run in CI or as a pre-commit gate.

| Script | What it asserts |
|--------|-----------------|
| `nvim_eob_gutter.sh` | Column 0 is periwinkle for all rows (short file, no scroll) |
| `nvim_eob_gutter_scrolled.sh` | Column 0 stays periwinkle after `G`+`zt` scroll to EOF |
| `cmd_buffer_target_pane.sh` | Submitted text reaches RIGHT pane; LEFT pane is clean (regression: lcarcat-08g.1) |
| `terminal_win.sh` | `:LcarsTerm` round-trips real commands through the PTY; session reuse and teardown (lcarcat-2z9) |
| `terminal_win_pty_width.sh` | PTY `COLUMNS` equals the frame's content width; wide output stays inside the bar (regression: lcarcat-wve) |

Run all integration tests:
```bash
for f in test/integration/*.sh; do echo "--- $f ---"; bash "$f" && echo PASS || echo FAIL; done
```

### test/captures/ — reference screenshots, human-evaluated

These produce PNGs in `test/screenshots/<name>/` but have no programmatic assertion. Run them when you want a reference capture or are evaluating a visual change.

| Script | What it captures |
|--------|-----------------|
| `block_demo.sh` | LCARS block frame styles in a scratch buffer |
| `frame_buffer.sh` | frame_buffer lifecycle: done/live/failed blocks via open_block→append_line→close_block |
| `cmd_buffer_theme.sh` | Orange gutter in command buffer; periwinkle above |
| `prompt_elbow_alignment.sh` | Elbow image aligned with stem bg cell |
| `prompt_left_edge_pixel.sh` | Sub-pixel left edge (feed to `analyze_left_edge.py`) |
| `prompt_resize_regen.sh` | Alignment at baseline, larger, and restored font size |
| `rich_demo.sh` | Full 3-pane README hero layout |
| `terminal_frame.sh` | LCARS swoop prompt inside a full-window nvim `:terminal` |
| `trivial_image_alignment.sh` | 1-cell image vs plain bg cell (uses `test/fixtures/trivial_align_test.py`) |
| `vsplit_nvim_command_buffer.sh` | Side-by-side nvim + command buffer layout |

---

## Verification after asset changes

When changing cell dimensions, font, or `gen_swoops.py` output:

1. Run `prompt_left_edge_pixel.sh` → feed the PNG to `analyze_left_edge.py` to verify zero sub-cell inset.
2. Run `prompt_resize_regen.sh` → confirm alignment survives a mid-session font zoom.
3. Run `nvim_eob_gutter.sh` → confirm the gutter assertion still passes at the new cell dims.
4. Inspect screenshots manually against the checklist in `docs/lcars-design.md`.

Pass `--cellw` and `--cellh` explicitly to `analyze_gutter_cells.py` if you've changed the test font size:

```bash
python3 test/analyze_gutter_cells.py /tmp/lcarcat-screenshots/01-eob-gutter.png \
  --cellw 20 --cellh 40 --expect-bg periwinkle --verbose
```

The defaults (19×38) match `test/kitty_test.conf` at font_size 18 Fantasque Sans Mono. Any other font or size requires explicit values from a CSI 16t probe.
