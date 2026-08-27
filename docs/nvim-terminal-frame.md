# nvim Terminal Frame — Design
<!-- Read this doc when: implementing any file in nvim/lua/lcars/ that is part
     of the terminal frame system (block_record, image_registry, frame_renderer,
     frame_buffer, pty_session, term_input, terminal_win), when understanding
     why a particular architectural call was made, or when picking up a bead
     under epic lcarcat-qm0. -->

The terminal frame system wraps real shell output in LCARS chrome inside nvim.
Each command's output gets a header (elbow PNG + periwinkle bar + chip pills),
a stem column alongside output lines, and a footer hcap — the same visual
language as block_demo tabs A/D/E, but live.

---

## Why custom buffer, not `:terminal`

`:terminal` uses nvim's built-in VT220 emulator — we can't insert synthetic
header/footer lines into it, and images placed on it are absolute-positioned
(they don't scroll with content). A custom buffer lets us own every line.

**Escape hatch:** if baleia.nvim performance is unacceptable, `nvim_open_term(buf)`
+ `nvim_chan_send` runs nvim's VT220 emulator on a hidden buffer. Settled lines
can be copied back via `nvim_buf_get_lines` + `nvim_buf_get_extmarks`. This is
viable for linear output (ls, git) but "when is a line settled" is ambiguous for
line-rewriting commands (htop, watch). See spike-3 bead `lcarcat-xi4` for the
investigation task. Default path: custom buffer + baleia.

## Why images are bound to (window, buffer, row), not absolute placement

`chrome.lua` and `terminal_frame.lua` place images at absolute screen
coordinates via image.nvim — they must be repositioned on every scroll event.
The zsh prompt instead uses the kitty Unicode placeholder protocol: `U+10EEEE`
+ row/col combining diacritics are emitted as real text cells that live in the
buffer, so they scroll automatically because they *are* text.

The terminal frame doesn't use literal Unicode placeholder cells for its
elbow/cap images (that would mean redrawing the PNG-as-glyph pipeline the zsh
prompt uses). Instead `image_registry.lua`/`frame_renderer.lua` pass
`window`/`buffer` plus buffer-relative `x`/`y` to image.nvim's `from_file()`.
That gets the same property — images move and disappear with the buffer, not
the screen — because image.nvim's own internal autocmds (`WinScrolled`,
`BufLeave`/`WinClosed`/`TabEnter`) reposition and hide window+buffer-bound
images automatically; no reconciliation loop needed on our side. See
`docs/nvim-harness.md` "Buffer-bound placement" for the mechanism and a
known off-by-one gotcha in the installed image.nvim version (lcarcat-382).
`chrome.lua` stays on absolute placement deliberately — its images are fixed
chrome pinned to layout geometry, not buffer content, so there's no buffer
row to bind to.

## Why `term_input.lua` is separate from `command_buffer.lua`

`command_buffer.lua` submits commands via `kitty @ send-text` to the sibling
kitty pane above it — it does not own a PTY. The terminal frame owns its own PTY
via `jobstart`, so submission must go through `chansend(job_id, text)` instead.
Sharing the file would entangle two different submission paths. `command_buffer.lua`
is preserved unchanged for the kitty send-text workflow.

## Why `term_input.lua` takes a callback, not a module reference

`term_input.M.open(buf, opts)` calls `opts.on_submit(cmd_text)` rather than
requiring `pty_session` or `terminal_win` by name. Two reasons:

1. **Ordering.** Submission must set `rec.command` on the live `block_record`
   *before* the PTY executes the command (otherwise the header can't show
   command text) — but `rec` and `block_record` are owned by
   `terminal_win.lua`, not `term_input.lua` or `pty_session.lua`. A plain
   callback lets `terminal_win.lua` do `rec.command = cmd_text` then call
   `pty_session.send(cmd_text)`, without `term_input.lua` needing to know
   `block_record` exists.
2. **Buildable before `terminal_win.lua` exists.** `term_input.lua`
   (`lcarcat-lyz`) and `terminal_win.lua` (`lcarcat-2z9`) are separate beads;
   `2z9` depends on `lyz`. A callback means `term_input.lua` can be built and
   capture-tested standalone by passing `on_submit = pty_session.send`
   directly — proving the input→PTY path end-to-end — without a stub
   `terminal_win.lua` module needing to exist first.

---

## Block state machine

OSC 133 marks (emitted by kitty shell integration) drive the block lifecycle:

```
A (prompt start)
  → create block_record — but do NOT render anything yet (see below)

7 (cwd) / 7337 (chips)
  → populate rec.cwd and rec.chips while the prompt draws

B (command start)
  → note: command text comes from term_input.submit(), NOT from PTY bytes
  → pty_session suppresses echoed input lines between B and C (skip_lines=true)

C (command exec)
  → frame_buffer.open_block(rec) — header renders here, in sage (live)
  → open content region; start appending output lines via frame_buffer.append_line
  → record rec.command_start = vim.uv.hrtime()

D;N (command done, exit code N)
  → record rec.command_end, rec.duration = command_end - command_start
  → set rec.state = (N==0) and "done" or "failed", rec.exit_code = N
  → append the duration chip (block_chips.append_duration)
  → frame_buffer.close_block(rec) — re-renders header, writes 1-row footer
```

### Why the block renders at C, not A (lcarcat-ba0)

The obvious place to open the block is A — the prompt is drawing, a new block is
beginning. It renders badly in practice:

- The command text is not known at A. `term_input.submit()` sets `rec.command`
  *after* the header has already been drawn, and nothing re-renders until
  `close_block`. So the header sat there with a blank command line for the
  entire run of the command, filling in only once it finished.
- An empty header sat on screen for however long you took to type.
- A prompt that never runs a command — bare Enter, Ctrl-C — left an orphan
  header with no command and no footer.

By C, `rec.command` and `rec.chips` are both populated, so the header is drawn
once and correct. `rec.buf_start` is nil until `open_block` runs, which is what
`on_output_line` and `on_command_done` test to know whether a frame exists.

State → chrome color:

| state  | header / footer | stem        |
|--------|-----------------|-------------|
| live   | sage            | sage        |
| done   | periwinkle      | periwinkle  |
| failed | periwinkle      | periwinkle  |

`failed` is deliberately identical to `done` — see "Footer: what the block did"
below for why, and where the failure actually shows.

---

## OSC 7337 — semantic chip payload

Block headers carry the same chips as the kitty swoop bar (branch, venv, python,
AWS profile, git state). The shell already computes all of it in
`_lcars_swoop_precmd`, so nvim asks for the values rather than recomputing them
— no duplicate `git status` per prompt, and no blocking the UI on a subprocess.

Inside `:LcarsTerm` there are no kitty graphics, so `_lcars_graphics_ok` is
false and the prompt takes its plain-text fallback path. The chip payload is
emitted on *both* paths, right after `OSC 133;A`:

```
ESC ] 7337 ; lcars ; chips [ ; <kind> ; <label> ]... ST
```

- **Flat pairs.** Everything after `chips` is alternating kind/label separated
  by `;`. An empty chip set is the bare `7337;lcars;chips` with no trailing
  `;` — it still fires, so a stale chip list gets cleared.
- **Percent-encoding.** `;` is the field separator, so `;` and `%` are
  percent-encoded in labels (git branch names may legally contain either).
- **Kinds, not colors.** The shell names what a chip *means* (`venv`, `py`,
  `aws`, `awsdep`, `git`, `gitstate`); `block_chips.lua` maps kind →
  highlight group. The palette stays a neovim concern. An unrecognized kind
  still renders, in the default chip color, rather than vanishing.
- **No `err` chip.** The swoop bar has one, but the payload does not:
  `precmd` runs *after* a command, so its `$?` belongs to the command that just
  finished — while these chips attach to the block about to open, i.e. the next
  one. Exit status is reported on the correct block's own footer instead.
- **Safe to emit anywhere.** Terminals that don't know OSC 7337 ignore it, so
  the sequence goes out unconditionally, kitty included.

### Header layout, and where the cwd goes

The header bar mirrors the swoop bar's arrangement — `chips + fill + path` —
so a block header and the standalone kitty prompt read as one system:

```
[elbow][blk][chip][blk][chip][blk] ... bar fill ... [~/cwd][2 bar cols][cap]
```

Colored chips are **left-aligned** from the elbow; each chip's trailing black
gap combs with the next one's leading gap, so N chips draw N+1 gaps (the same
rule as `_lcars_chips` in zsh). The cwd is a **hole chip** punched in the right
end of the bar: black on both rows, Normal-colored text, never dropped — it is
the block's address.

`on_cwd` collapses `$HOME` to `~` with `fnamemodify(path, ":~")` rather than a
hardcoded prefix, so the hole chip stays correct for any user on any machine.

### Footer: what the block did

The header describes *where* a command ran; the single-row footer describes
*what it did*, as chips left-aligned from the footer elbow — same run geometry
as the header, via the shared `chip_run()`:

```
[felbow][blk][2.5S][blk][ERR-01][blk] ... bar fill ... [cap]
```

- **duration** — only past `CMD_DURATION_THRESHOLD` (milliseconds, default
  2000). This is the same knob and default the swoop bar uses for its
  end-of-command timestamp line, so both surfaces agree on what "slow" means.
  Read from nvim's environment at load; `block_chips.duration_threshold_ms` can
  be reassigned at runtime.
- **`ERR-NN`** — only on a nonzero exit. Success is the default and gets no
  chip.

A quick successful command therefore has an empty footer, which is the point.

Both are derived from the finished `block_record` by `block_chips.outcome()`,
not stored on it.

A failed block **keeps normal periwinkle chrome**. Painting the whole frame red
for every `grep` that matched nothing drowns out the blocks that actually went
wrong, so the red `ERR-NN` chip carries the signal alone.
`LcarsTermFrameFailed`/`LcarsTermStemFailed` still exist in the colorscheme if
the loud treatment is ever wanted back.

### Overflow

`header_chips()` has no width limit of its own, and a full set (branch + three
git-state chips + venv + py + aws) overruns a default 60-column bar once the
cwd hole chip has taken its share. `frame_renderer.fit_chips` sheds whole
groups, lowest value first — `aws, awsdep, py, gitstate, venv, git` —
mirroring the swoop bar's own drop order in `prompt_lcars.zsh`. Kinds not in
that list shed after them; untagged chips (`block_demo`'s fixed lists) shed
last. The cwd is charged against the budget by `chips_avail()` rather than
competing for it, so it never drops.

`chips_width()` mirrors `header_chips()`'s placement arithmetic exactly — if
you change one, change the other.

---

## Frame geometry and coordinate systems

Three coordinate spaces are in play, and mixing them is the single most common
source of off-by-one bugs in this subsystem. Read this before touching
`frame_renderer.lua`, `frame_buffer.lua`, or `terminal_win.lua`.

| Space | 0 is at | Used by |
|-------|---------|---------|
| **kitty terminal col** | left edge of the kitty window | `test/get_cell_grid.py`, `test/overlay_grid.py` |
| **nvim window col** | left edge of the nvim window, **gutter included** | `lp`, `bar_x0`, `cap_x`, `virt_text_win_col`, image placement |
| **buffer byte col** | first byte of the buffer line | `nvim_buf_set_lines`, byte-based extmarks |

`window col = buffer byte col + GUTTER_W`, with `GUTTER_W = 1`.

That gutter is **not** the sign column — `terminal_win.lua` sets
`signcolumn = "no"`. It comes from the global `statuscolumn` in
`nvim/colors/lcars.lua` (`"%#LineNr#%=%l%#LineNr# "`), which is set once and
never varies, so the code hardcodes `GUTTER_W = 1` rather than reading
`textoff`. See the comment at `block_demo.lua:681`.

Consequences worth memorizing:

- `nvim_win_get_width()` **includes** the gutter.
- Byte-based `hl_group` extmarks subtract `GUTTER_W` once (`frame_renderer.hl`).
- `virt_text_win_col` is already a window col — **no** subtraction.
- `registry.place()` subtracts `GUTTER_W` for image placement.

### Derived geometry

With `lp = 6` (left pad) and `BAR_MARGIN = 14` (the slice the bar does not use,
reserving room for the elbow and cap images):

| Element | Window cols | Notes |
|---------|-------------|-------|
| stem | `lp` | 1 col, solid `hl_group`, no glyph |
| header/footer bar | `lp` .. `lp+bw-1` | `bw = win_width - BAR_MARGIN` |
| header bar *fill* (colored) | `lp+ELBOW_W-1` .. `cap_x-1` | stops where the vcap image starts |
| header vcap image | `lp+bw-CAP_W` .. `lp+bw-1` | `CAP_W = 2`, spans both bar rows |
| footer cap image | `lp+bw-FCAP_W` | `FCAP_W = 1` |
| content text | `lp+2` .. `lp+bw-1` | see below |

Content text starts at `lp+2`, not `lp+1`: `render_content` and
`append_line` write an `lp+1`-space prefix in **buffer** cols, which is window
col `lp+2`. So:

```
content_width = bw - 2
```

That is what `terminal_win.geometry()` returns and what must be handed to
`pty_session.start()` as the PTY width — see "Wiring notes" below.

Two subtleties that look like bugs but are not:

- The **colored** bar stops one or two cols short of the bar's right edge,
  because the last `CAP_W`/`FCAP_W` cols are left uncolored for the cap image
  to occupy. The frame's visual right edge is the cap, at `lp+bw-1`.
- Header/footer **buffer lines** are `lp+bw` chars long — one char longer than a
  full-width content line — because `pad(lp) .. bar(bw)` carries a trailing
  uncolored space just past the bar's right edge.

### Worked example (verified)

At `win_width = 181`, measured live via `test/get_cell_grid.py`:

```
bw            = 181 - 14 = 167
content_width = 167 - 2  = 165      <- `tput cols` inside the PTY reports this
stem          = window col 6
content text  = window cols 8 .. 172
header vcap   = window cols 171-172   footer cap = window col 172
visible text  = 180 cols (win_width - GUTTER_W)
```

A line of exactly `$COLUMNS` chars puts its last char at terminal col 172 —
flush with the frame's right edge — and col 173 is empty. Regression-tested by
`test/integration/terminal_win_pty_width.sh`.

## File map

| File | Responsibility |
|------|---------------|
| `block_record.lua` | Data model for one A→D block. No rendering, no I/O. |
| `image_registry.lua` | Transmit elbow/hcap PNGs once per session via APC escape; cache `(asset, cw, ch)` → kitty image ID. |
| `frame_renderer.lua` | Pure render: given `(buf, start_row, rec)` write lines and return row count. Calls image_registry for placeholder cells. Uses baleia for content lines. |
| `frame_buffer.lua` | Owns the display buffer (`modifiable=false` except during writes). `open_block`, `append_line`, `close_block`. |
| `pty_session.lua` | `jobstart(shell, {pty=true})`. Carry-buffer for split chunks. OSC 133 / 7 / 7337 state machine. `M.send(text)` → `chansend`. |
| `block_chips.lua` | Chip kind → highlight group; duration label formatting. The one place shell chip semantics become LCARS colors. |
| `term_input.lua` | Orange-stem input split. `M.open(buf, opts)` configures a buffer/window created by the caller (does not call `nvim_open_win` itself). `opts.on_submit(cmd_text)` is a plain callback — term_input never requires `pty_session` or `terminal_win` by name. Telescope history. Does not touch `command_buffer.lua`. |
| `terminal_win.lua` | Layout: display split (top) + input split (bottom). Wires pty_session callbacks to frame_buffer. `:LcarsTerm` command. |

Reuse from `block_demo.lua`: `chips_block()` pattern, `capcols()` math, chip/bar
highlight logic. Do not delete `block_demo.lua` — it is the visual reference and
is removed only from `deploy.sh`.

---

## Wiring notes for terminal_win.lua (lcarcat-2z9)

`terminal_win.lua` connects the three completed layers. Key contract details:

**pty_session callbacks → frame_buffer calls:**

```lua
local rec = nil  -- current live block_record

callbacks = {
  on_prompt_start = function()
    rec = block_record.new(next_id())
    rec.state = "live"
    -- cwd set by on_cwd if OSC 7 fires before A, or left nil
    fb.open_block(rec)
  end,

  on_command_start = function()
    -- command text not available here; set after term_input.submit() fires
    -- pty_session is suppressing echoed input (skip_lines=true)
  end,

  on_command_exec = function()
    -- rec.command was set by terminal_win before calling pty_session.send()
    rec.command_start = vim.uv.hrtime() / 1e9  -- epoch seconds
  end,

  on_output_line = function(line)
    if rec then fb.append_line(rec, line) end
  end,

  on_command_done = function(exit_code)
    rec.command_end = vim.uv.hrtime() / 1e9
    rec.duration    = rec.command_end - rec.command_start
    rec.state       = (exit_code == 0) and "done" or "failed"
    rec.exit_code   = exit_code
    fb.close_block(rec)
    rec = nil
  end,

  on_cwd = function(path)
    if rec then rec.cwd = path end
  end,
}
```

**Command submission flow** (term_input → on_submit callback → pty_session):
1. `terminal_win.lua` opens the input split/buffer itself, then calls
   `term_input.open(buf, { win = input_win, on_submit = terminal_win.submit })`.
2. `term_input.submit()` reads the nvim buffer contents, strips trailing
   blanks, and calls `opts.on_submit(cmd_text)` — i.e. `terminal_win.submit(cmd_text)`.
3. `terminal_win.submit` sets `rec.command = cmd_text` on the current (live) `block_record`.
4. Then calls `pty_session.send(cmd_text)` — PTY executes it.
5. `term_input.submit()` clears the input buffer to a blank line for the next command.

`term_input.lua` never requires `pty_session` or `terminal_win` by name — see
"Why `term_input.lua` takes a callback, not a module reference" above.

**Window layout:** Display buffer in top split (`modifiable=false`, `signcolumn=no`). Input split below (fixed height, `signcolumn=yes:1` for orange stem). Pass the frame's **content width** — not the raw window width — plus the window `height` to `pty_session.start()` via `opts`. With `lp = 6` and `bw = win_width - 14`, content text runs from window col `lp+2` to the bar's right edge, so the PTY gets `bw - 2` columns. Handing it the raw window width makes `ls` and friends format to space the frame does not have, and `wrap=false` clips the overflow invisibly (lcarcat-wve).

**opts for frame_buffer.new():** Pass `win`, `cw`, `ch` from the display split so images are placed correctly from the start. `cw`/`ch` from `require("lcars.assets").cell_px()`.

---

## What is intentionally out of scope (backlog beads)

These are child beads under `lcarcat-qm0`. Do not add them to the minimal demo.

| Feature | Bead |
|---------|------|
| Stderr separation (different stem color) | `lcarcat-80m` |
| Fold/unfold blocks to pill row | `lcarcat-ubk` |
| Block navigation keymaps (`[b`/`]b`, `zf`/`zo`) | `lcarcat-014` |
| Alternate screen passthrough (vim, less, fzf) | `lcarcat-biv` |
| Multiple concurrent sessions | `lcarcat-3ft` |
| Command-in-header notch (Tab C style) | `lcarcat-e0d` |
| Live update debounce | `lcarcat-z8h` |

---

## Key external references

- `docs/nvim-terminal-research.md` — nvim doc line ranges, third-party plugin
  survey, open research questions (baleia performance, TermRequest scope, etc.)
- `docs/terminal-block-terminology.md` — canonical names (block, frame, stem,
  header, footer, gap, live block, history block)
- `docs/kitty-graphics.md` — Unicode placeholder protocol details
- `block_demo.lua` — visual reference; `make_A`, `make_D`, `make_E` are the
  target geometries for done, live, and folded states respectively
