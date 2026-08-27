# nvim Harness Interaction Guide

How to drive nvim via the kitty remote-control socket from shell scripts (scenario tests, debug sessions, the screenshot harness). This complements `docs/testing.md`, which covers the harness at the scenario level. This document covers the patterns specific to nvim interaction.

---

## Quick reference: which problem needs which pattern

| Problem | Pattern |
|---------|---------|
| Command went to zsh instead of nvim | Send `\x1b` (escape) before the command |
| Landed on wrong tab after `:tabn N` | Use `nvim_set_current_tabpage(list[N])` instead |
| Lua change not reflected after deploy | `package.loaded['lcars.foo'] = nil` before `require` |
| Screenshot shows the wrong state | Check `:messages` before taking the screenshot |
| Image from previous tab still visible | TabEnter re-render with `vim.schedule` — or explicit `img:clear()` sweep |
| E5108 "Invalid 'line': out of range" | Two-pass rule violated — see below |
| Need to know which column something rendered in | Probe the live session with `get_cell_grid.py` — section 11, not a screenshot |

---

## 1. Socket lifecycle

The harness starts kitty in `--detach` mode with `--listen-on`:

```bash
./test/screenshot_harness.sh launch
./test/screenshot_harness.sh teardown   # idempotent
```

All `kitty @` commands take `--to "$SOCK"` where `SOCK="unix:/tmp/lcarcat-test.sock"`.

**PID file:** `teardown` uses `$SOCK.pid` to force-kill if `close-window` doesn't take. The PID file is written by `launch` and removed by `teardown`.

**`LCARCAT_KEEP_ALIVE=1`:** Skip `teardown` on exit so you can inspect the live kitty window manually. Screenshots already on disk remain regardless. Export this variable **before** calling `nvim_harness_setup` — the setup function installs the teardown trap based on the value at call time.

**Window IDs:** Get them once after `launch` via `kitty @ ls`, then reuse `id:N` addressing throughout. Never use `recent:N` — the index shifts on every `focus-window` or `send-text` call.

```bash
WIN=$(kitty @ --to "$SOCK" ls | python3 -c "
import sys, json
for t in json.load(sys.stdin)[0]['tabs']:
    for w in t['windows']:
        if w.get('is_focused'): print(w['id']); exit(0)
")
```

---

## 2. Sending commands to nvim

All commands go through `kitty @ send-text --match "id:$WIN"`.

**Always escape to normal mode first** when you're not certain of the current input mode:

```bash
kitty @ --to "$SOCK" send-text --match "id:$WIN" "\x1b"
sleep 0.1
kitty @ --to "$SOCK" send-text --match "id:$WIN" ":lua require('lcars.block_demo').render_all()\r"
```

The `\x1b` is not visible — it just brings nvim back to normal mode. Skipping it means the `:lua` text gets typed into whatever mode nvim happens to be in (insert, command-line, etc.), producing garbage.

**Tab navigation — do not use `:Ntabn`:**

`:tabn N` means "move forward N tabs" — NOT "go to tab N". Sending `:3tabn\r` from tab 1 lands on tab 4. Use Lua instead:

```bash
kitty @ --to "$SOCK" send-text --match "id:$WIN" \
  ":lua vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[3])\r"
```

This is the only reliable way to jump to a specific tab index.

**Module reload after deploy:**

After running `deploy.sh`, nvim's `require()` cache still holds the old version. Clear it before requiring:

```bash
kitty @ --to "$SOCK" send-text --match "id:$WIN" \
  ":lua package.loaded['lcars.block_demo'] = nil; require('lcars.block_demo').render_all()\r"
```

---

## 3. Checking nvim messages before screenshots (mandatory)

An error in nvim's message area means the Lua command failed silently from the harness's perspective. The screenshot will show incomplete or incorrect rendering. Always check messages before taking a snapshot.

**Shell-file pattern** (reliable, leaves the message text on disk):

```bash
kitty @ --to "$SOCK" send-text --match "id:$WIN" \
  ":redir! > /tmp/nvim_messages.txt | messages | redir END\r"
sleep 0.4
if grep -qiE 'E[0-9]+:|Error' /tmp/nvim_messages.txt 2>/dev/null; then
  echo "ABORT: nvim reported errors:" >&2
  cat /tmp/nvim_messages.txt >&2
  exit 1
fi
```

**get-text pattern** (no file on disk, uses `kitty @ get-text`):

```bash
MSGS=$(kitty @ --to "$SOCK" get-text --match "id:$WIN" --ansi 2>/dev/null)
if echo "$MSGS" | grep -qiE 'E[0-9]+:|Error'; then
  echo "ABORT: nvim reported errors" >&2
  echo "$MSGS" | grep -iE 'E[0-9]+:|Error' >&2
  exit 1
fi
```

Note: `get-text --ansi` returns the visible screen content, not the full `:messages` log. The redir-to-file pattern is more thorough for multi-line error traces.

**Lua writefile pattern** (for interactive inspection):

```vim
:lua vim.fn.writefile(vim.split(vim.fn.execute('messages'), '\n'), '/tmp/nvim_msg.txt')
```

Then `cat /tmp/nvim_msg.txt` from the shell.

---

## 4. Timing constants

These are empirical minimums at font_size 18 Fantasque Sans Mono on macOS. Add 50% margin if on a slower machine.

| Event | Minimum sleep |
|-------|---------------|
| After `./screenshot_harness.sh launch` | 0s — the harness now sleeps 2.5s internally after the socket appears, waiting for zsh precmd to complete its CSI 16t probe |
| After `nvim` command in shell | 2.5s |
| After `:lua` render command | 1.0–1.5s |
| After tab switch | 0.8–1.2s |
| After focus-window | 0.2s |
| After minor send-text interaction | 0.3–0.5s |
| Before snapshot (additional) | 0.4s (harness does this internally) |

Image rendering via image.nvim needs at least one render frame after the Lua call returns. On a fresh tab switch, the TabEnter autocmd fires asynchronously — `vim.schedule` defers to the next event loop iteration, but the next screenshot may still beat it. If ghost images appear in screenshots after a tab switch, add an extra `sleep 1.0` after the tab-switch command.

---

## 5. Two-pass rule: buffer lines before extmarks

**The rule:** `nvim_buf_set_extmark` requires the target line to already exist in the buffer. Calling it before `buf_set_lines` causes `E5108: Invalid 'line': out of range`.

**The pattern:** builders append text to a shared `lines` table and return a deferred closure. After all builders have run, write all lines to the buffer at once, then call all closures.

```lua
local lines = {}
local closures = {}

local fn, specs = make_block_A(lines, ...)
closures[#closures+1] = fn

local fn2, specs2 = make_block_B(lines, ...)
closures[#closures+1] = fn2

-- Phase 2: write lines
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

-- Phase 3: annotate
for _, fn in ipairs(closures) do fn(buf) end
```

**Never** call highlight or extmark APIs inside a builder while appending lines. Return a closure instead.

---

## 6. Inspecting live nvim state via RPC

When screenshots show unexpected state, use nvim's built-in RPC to query the live instance directly — without sending keystrokes that could change the state you're inspecting.

```bash
# Get the server address (send once, then reuse)
kitty @ --to "$SOCK" send-text --match "id:$WIN" \
  ":call writefile([v:servername], '/tmp/nvim_addr.txt')\r"
sleep 0.3
NVIM_SERVER=$(cat /tmp/nvim_addr.txt)

# Eval any Lua expression
nvim --server "$NVIM_SERVER" --remote-expr "luaeval('vim.inspect(vim.api.nvim_list_tabpages())')"
```

`test/nvim_state.sh` wraps this into a full report: mode, tab list, current buffer (name/line count/buftype), first 10 buffer lines with byte lengths, and window options. Run it whenever you need to confirm what nvim actually contains vs what the screenshot shows.

**Float windows:** `vim.api.nvim_list_wins()` + `nvim_win_get_config(w).relative ~= ""` lists all floating windows. Unexpected floats (e.g. narrow column strips with `zindex=1`) are often LCARS chrome (gutter_eob_fill, terminal_frame), not overlays hiding content.

---

## 7. Windowless image placement

image.nvim images can be placed at absolute screen coordinates without a buffer/window:

```lua
local img = require("image").from_file(path, {
  x = dx,   -- column (cells from left edge of screen)
  y = dy,   -- row (cells from top edge of screen, including kitty tab bar)
  width = w,
  height = h,
})
img:render()
```

**These images are viewport-fixed, not buffer-fixed.** They do not scroll with buffer content. After rendering a tab's images, switching tabs and then switching back leaves the previous tab's images visible on screen until the new tab explicitly re-renders its own images.

**TabEnter re-render pattern:**

```lua
vim.api.nvim_create_autocmd("TabEnter", {
  group = vim.api.nvim_create_augroup("LcarsBlockDemoRefresh", { clear = true }),
  callback = function()
    local bufname = vim.api.nvim_buf_get_name(
      vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    )
    if not bufname:find("lcars://demo/", 1, true) then return end
    local demo_name = bufname:match("lcars://demo/(.+)$")
    vim.schedule(function() render_tab(demo_name) end)
  end,
})
```

`vim.schedule` defers to the next event loop iteration to avoid rendering before the tab is fully active. However, if a screenshot immediately follows a tab switch, the schedule callback may not have fired yet — add `sleep 1.0` after the switch command.

**Clearing images:** `img:clear()` removes a placed image. If ghosting is persistent, an explicit sweep of `img:clear()` for all previously-placed images before re-rendering is more reliable than relying on render replacement alone.

**Topline tracking:** images must be placed at `dy = topline_offset + row_in_buffer`. Read `topline` at render time via `vim.fn.line("w0", win) - 1` — do not cache it. If the window has scrolled since last render, stale topline causes misaligned images.

**Buffer-bound placement (`window + buffer + x/y`):** pass `window`, `buffer`, `x`, and `y` to `from_file()` to bind an image to a buffer row. image.nvim registers a `WinScrolled` autocmd internally and recomputes position via `vim.fn.screenpos()` on each scroll — no manual autocmd needed. It also auto-clears the image when the bound window's current buffer no longer matches — switching buffers in a window with a buffer-bound image hides it without any extra wiring.

**Partial viewport clipping is not handled.** When the image's anchor row (`y`) scrolls above `topline`, `vim.fn.screenpos()` returns `{row=0, col=0}` and the image disappears entirely — there is no partial overlap. To get progressive row-by-row clipping (row 0 hides first, rows 1–2 remain visible), place one `from_file()` per image row rather than one call for the full image. For a 3-row elbow this means three 5×1 placements at `y=0`, `y=1`, `y=2`. (The installed image.nvim has since grown its own partial-scroll clipping logic for buffer-bound images — `renderer.lua`'s `is_partial_scroll`/`get_overlap_scroll_position` path — so re-check this before adding per-row placements; it may already work.)

**Off-by-one in buffer-bound vertical placement (lcarcat-382, image.nvim @ `5c6f29a`, 2026-08-19).** For a window+buffer-bound image, `renderer.lua`'s "on topline" branch (`absolute_y = win_info.winrow`) and its normal fully-visible branch (`absolute_y = screen_pos.row`) both assign a 1-indexed `getwininfo`/`screenpos()` row straight to `absolute_y` without the `-1` needed to reach the kitty backend's 0-indexed convention (`backends/kitty/init.lua` does `write_graphics_at(cfg, x + 1, y + 1)`). Net effect: the image renders one row below its bound buffer row, even though horizontal (`x`) placement is fine. The renderer's partial-scroll branch already has an explicit `-1` and isn't affected. Workaround (not a patch to the vendored plugin): pass `render_offset_top = -1` to `from_file()`. That option is added to `absolute_y` in exactly the two buggy branches and is skipped during real partial-scroll clipping, so it corrects the static case without perturbing scroll-edge behavior. Don't try to fix this by shifting the `y` you pass in instead — `y` also drives the `topline`/`botline` branch-selection comparisons inside the renderer, so offsetting it desyncs *those* instead of fixing the output.

**Buffer-bound images don't track horizontal scroll.** Only `WinScrolled`'s vertical repositioning is handled for buffer-bound images; if a window's `leftcol` changes (long unwrapped lines, sidescroll, a horizontal scroll-wheel binding), the image stays put while the text underneath shifts. If horizontal scroll isn't a feature you need, the simplest fix is to pin `leftcol` at 0 rather than teach images to follow it: a `WinScrolled` autocmd scoped to the window (`pattern = { tostring(win) }` — window-events match pattern against the window ID) that calls `vim.fn.winrestview({ leftcol = 0 })` whenever `vim.fn.winsaveview().leftcol ~= 0`. It's self-limiting — once `leftcol` is back to 0 there's nothing left to correct, so it doesn't loop. See `terminal_win.lua`'s `M.open()` for the applied version.

---

## 8. Elbow and corner pixel anatomy

Verified by pixel sampling the actual PNGs at 19×38px/cell using Pillow. The cell layout in your Lua buffer must match the image's internal row structure — one cell = one buffer row.

### Elbow assets (3 rows × N cols)

Used in all single-bar header/footer frames (demos A, B, C, D, E, F, G).

```
elbow-top-left     row 0: full bar (all cols periwinkle)
                   row 1: full bar + chips region
                   row 2: stub (col 0 only is periwinkle; rest black)

elbow-bottom-left  row 0: stub (col 0 only)
                   row 1: full bar
                   row 2: full bar

elbow-top-right    row 0: full bar
                   row 1: full bar
                   row 2: stub (last col only; rest black)

elbow-bottom-right row 0: stub (last col only)
                   row 1: full bar
                   row 2: full bar
```

**Buffer layout consequence:**

- Header (top): `[row bar][row bar][row stub]` — the stub row is the *last* header row
- Footer (bottom): `[row stub][row bar][row bar]` — the stub row is the *first* footer row

Getting this wrong (e.g. `[stub][bar]` for a header) causes the image to visually misalign with the highlighted cells behind it.

### Corner assets (2 rows × N cols)

Used in two-row header/footer frames (demo A2 style). Corner assets exist in two variants:

- `stem=4` variant: `corner-top-left` has a **6×2-cell** gap notch at cols 4–5 of row 1
- `stem=0` variant: `corner-top-left` has a **2×2-cell** gap notch

The `find_asset_dir` function must probe for BOTH an elbow AND a corner asset to select the directory with the correct corner variant. Probing for elbow only returns the `stem=0` dir, which has the wrong corner width for A2-style blocks.

```
corner-top-left    row 0: full bar
                   row 1: partial bar (gap at cols 4–5 in stem=4 variant)

corner-bottom-left row 0: partial bar (gap at cols 4–5)
                   row 1: full bar
```

**Open question (for frame.lua session):** Is there a case where you'd mix an elbow header with a corner footer, or vice versa? What determines which to use — block height, visual style, number of content lines? This needs to be answered before finalizing the `append_header_*` / `append_footer_*` API surface.

---

## 9. Semantic color checks for bar validation

When validating that block bars rendered correctly, use `get_cell_grid.py --scan-bg periwinkle` to find which rows kitty's terminal model has as periwinkle — without knowing the exact row number in advance.

```bash
python3 "$REPO/test/get_cell_grid.py" \
  --socket "$SOCK" --window "$WIN_ID" \
  --scan-bg periwinkle
```

This is the right tool when you know a bar should exist somewhere but don't know its row offset. For assertions on a specific row, use `--row N --expect-bg periwinkle`.

**What `--scan-bg` cannot catch:** rows that appear periwinkle to the eye but are actually the bar-colored region of an image rather than a highlighted terminal cell. Image pixels are invisible to `get-text` — kitty reports the placeholder glyph, not the rendered color. Use `analyze_gutter_cells.py` on the screenshot PNG when you need to validate image-rendered colors.

---

---

## 10. Composable helper library (`test/nvim_harness_helpers.sh`)

`test/nvim_harness_helpers.sh` wraps the patterns from sections 1–3 into named functions. Source it from any scenario that opens nvim.

**When to source:** scenarios that open nvim, run Lua commands, navigate tabs, or test split/render isolation. Skip it for shell-only scenarios (no nvim involved).

**All helpers take explicit arguments** — no env var reads inside helper bodies. Scenarios set `SOCK`, `H`, `SHOT_DIR` as local variables and pass them as arguments.

### Setup

```bash
source "$REPO/test/nvim_harness_helpers.sh"
nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"   # mkdir + trap
"$H" launch && sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"
```

`nvim_harness_setup` installs `trap "$H teardown" EXIT INT TERM` (suppressed when `LCARCAT_KEEP_ALIVE=1`) and creates `$SHOT_DIR`. Call it before `"$H" launch`.

### Single-screenshot helpers

| Function | Args | What it does |
|----------|------|--------------|
| `_nvim_focused_window_id` | `SOCK` | Print focused window ID; use once after launch |
| `nvim_open` | `SOCK WIN_ID [FILE]` | Send `nvim FILE`, sleep 2.5 s |
| `nvim_run_cmd` | `SOCK WIN_ID CMD` | Send `:CMD`, sleep 0.5 s |
| `nvim_reload_module` | `SOCK WIN_ID NAME` | Clear package.loaded + require, sleep 1.0 s |
| `nvim_goto_tab` | `SOCK WIN_ID N` | Jump to Nth tab (1-indexed), sleep 1.0 s |
| `nvim_check_messages` | `SOCK WIN_ID LABEL` | Redir :messages to `/tmp/nvim_messages_LABEL.txt`; abort on errors |

### Multi-state sequence helpers

| Function | Args | What it does |
|----------|------|--------------|
| `nvim_render_all_tabs` | `SOCK H WIN_ID SHOT_DIR PREFIX` | render_all() + iterate tabs, snapshot `PREFIX-tab-N` |
| `nvim_tab_sequence` | `SOCK H WIN_ID SHOT_DIR PREFIX TABS...` | Navigate tab list, snapshot each |
| `nvim_split_then_render` | `SOCK H WIN_ID SHOT_DIR PREFIX` | vsplit + render left, switch right, snapshot both |

### Minimal example

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-/tmp/lcarcat-screenshots}"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"
"$H" launch && sleep 1.5

WIN="$(_nvim_focused_window_id "$SOCK")"
nvim_open "$SOCK" "$WIN" "$REPO/test/fixtures/short_file.py"
nvim_check_messages "$SOCK" "$WIN" "my-scenario"
"$H" snapshot "01-initial"
```

The helpers do **not** launch kitty, take screenshots, or run teardown — those remain `"$H" launch`, `"$H" snapshot LABEL`, and the trap installed by `nvim_harness_setup`.

---

## 11. Style-B chip rendering in extmarks

Chips span both bar rows (full 2-row height). Per the LCARS design and `zsh/prompt_lcars.zsh _lcars_chips()`:

```
[1-col black gap] [chip bg full height] [1-col trailing black gap]
```

Adjacent chips share (comb) a single gap column, so N chips draw N+1 gaps total.

**Rules for correct extmark implementation:**

1. **Gaps must be explicit `virt_text`** with `LcarsBlockBg` (black bg), not a bare column skip.
   A column skip leaves the `LcarsBlockBar` highlight visible, turning the gap periwinkle instead of black.
2. Place on **both** `r_top` (blank spaces with chip bg color) and `r_text` (label with chip bg color)
   to fill the full 2-row bar height.
3. Use `virt_text_pos = "overlay"` so the chip's highlight group wins over the bar extmark beneath it.

Reference implementation: `nvim/lua/lcars/block_demo.lua chips_block()` and `zsh/prompt_lcars.zsh _lcars_chips()`.

---

## 12. Stub row highlight convention

The elbow image (ELBOW_W=5, ELBOW_H=3) occupies cols `lp` to `lp+4` across all 3 rows including the stub row (header h0+2 or footer f0).

On the stub row, behind the elbow image:

- **Col `lp` only:** paint `LcarsBlockStem` (periwinkle) — matches the image's 1-cell-wide stem (STEM_COLS=1).
- **Cols `lp+1` to `lp+4`:** leave as `LcarsBlockBg` (black) — the elbow image paints the concave inner fillet arc here; black behind the transparent fillet pixels is correct and lets the fillet show clearly.
- **Do not** extend `LcarsBlockBar` onto the stub row — bars only cover the 2 bar rows.

The cmd text on the stub row (`mark_at`) must start at `lp + ELBOW_W` (col `lp+5`) to clear the entire fillet region. Starting it earlier covers fillet cols with the `LcarsBlockBg` virt_text background, hiding the fillet.

---

## 11. Probing a live session without screenshots

Screenshots are the expensive way to answer a geometry question: capture, then
overlay a grid, then have a subagent read the PNG. For "which column does this
land in?" the terminal model answers directly, in text, for ~200 tokens — and it
works when `screencapture` has no Screen Recording permission.

Keep kitty up after the scenario, then query it:

```bash
LCARCAT_KEEP_ALIVE=1 LCARCAT_SKIP_SCREENSHOTS=1 bash test/integration/foo.sh
```

`LCARCAT_KEEP_ALIVE=1` suppresses the teardown trap in `nvim_harness_setup`, so
the socket stays live for follow-up queries.

```bash
SOCK=unix:/tmp/lcarcat-test.sock
WIN=$(kitty @ --to "$SOCK" ls | python3 -c 'import sys,json;d=json.load(sys.stdin);print([w["id"] for o in d for t in o["tabs"] for w in t["windows"]][-1])')

# which rows in this column are not background?
python3 test/get_cell_grid.py --socket "$SOCK" --window "$WIN" --col 172 --verbose \
  | awk 'NF>=3 && $NF!="black" {print}'

# sweep a few columns to find an edge — where does content stop?
for col in 170 171 172 173; do
  n=$(python3 test/get_cell_grid.py --socket "$SOCK" --window "$WIN" --col $col --verbose \
      | grep -c "'#'")
  echo "col $col: $n"
done
```

The `awk`/`grep -c` filters are the point: they keep a 57-row dump from landing
in the main loop's context. Filter to the question, not the table — see the
"Context discipline" section in `AGENTS.md`.

Two gotchas:

- Quote the char you grep for (`"'#'"`), not the bare character. The verbose
  output prints chars quoted, and bare `#` also matches every `#rrggbb` color.
- Row 0 is usually the tabline and the last row the statusline, so stray
  periwinkle/orange hits there are chrome, not your frame.

Remember the display auto-scrolls to the newest block: after a command with long
output, an earlier block is off-screen and the grid cannot see it. Re-run the
thing you want to inspect so it is the last thing drawn.

---

## Related docs

- `docs/testing.md` — full harness reference, scenario template, pixel tools
- `docs/nvim-chrome.md` — image.nvim integration, chrome.lua architecture
- `docs/asset-pipeline.md` — PNG filename contract, gen_swoops.py, cache layout
- `docs/nvim-terminal-frame.md` — "Why images are bound to (window, buffer, row)" for how the terminal frame uses buffer-bound placement
