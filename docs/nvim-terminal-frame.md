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

## Why Unicode placeholder images, not absolute placement

`chrome.lua` and `terminal_frame.lua` place images at absolute screen
coordinates via image.nvim — they must be repositioned on every scroll event.
The zsh prompt instead uses the kitty Unicode placeholder protocol: `U+10EEEE`
+ row/col combining diacritics are emitted as real text cells that live in the
buffer. Because they are text, they scroll automatically. The terminal frame
uses the same approach for all header/footer images — elbow and hcap PNG cells
are part of the synthetic header/footer lines, not floats.

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
  → create block_record, render header in sage (live) via frame_buffer.open_block

B (command start)
  → note: command text comes from term_input.submit(), NOT from PTY bytes
  → pty_session suppresses echoed input lines between B and C (skip_lines=true)

C (command exec)
  → open content region; start appending output lines via frame_buffer.append_line
  → record rec.command_start = vim.uv.hrtime()

D;N (command done, exit code N)
  → record rec.command_end, rec.duration = command_end - command_start
  → set rec.state = (N==0) and "done" or "failed", rec.exit_code = N
  → frame_buffer.close_block(rec) — re-renders header, writes 1-row footer
```

State → chrome color:

| state  | header / footer | stem        |
|--------|-----------------|-------------|
| live   | sage            | sage        |
| done   | periwinkle      | periwinkle  |
| failed | red             | red         |

---

## File map

| File | Responsibility |
|------|---------------|
| `block_record.lua` | Data model for one A→D block. No rendering, no I/O. |
| `image_registry.lua` | Transmit elbow/hcap PNGs once per session via APC escape; cache `(asset, cw, ch)` → kitty image ID. |
| `frame_renderer.lua` | Pure render: given `(buf, start_row, rec)` write lines and return row count. Calls image_registry for placeholder cells. Uses baleia for content lines. |
| `frame_buffer.lua` | Owns the display buffer (`modifiable=false` except during writes). `open_block`, `append_line`, `close_block`. |
| `pty_session.lua` | `jobstart(shell, {pty=true})`. Carry-buffer for split chunks. OSC 133 state machine. `M.send(text)` → `chansend`. |
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

**Window layout:** Display buffer in top split (`modifiable=false`, `signcolumn=no`). Input split below (fixed height, `signcolumn=yes:1` for orange stem). Pass actual window `width` and `height` to `pty_session.start()` via `opts`.

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
