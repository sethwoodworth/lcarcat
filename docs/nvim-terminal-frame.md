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

---

## Block state machine

OSC 133 marks (emitted by kitty shell integration) drive the block lifecycle:

```
A (prompt start)
  → create block_record, render header in sage (live)

B (command start)
  → record command text from PTY bytes until C

C (command exec)
  → open content region; start appending output lines

D;N (command done, exit code N)
  → finalize: re-render header in periwinkle (N=0) or red (N≠0)
  → write footer hcap line
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
| `term_input.lua` | Orange-stem input split. `submit()` → `pty_session.send()`. Telescope history. Does not touch `command_buffer.lua`. |
| `terminal_win.lua` | Layout: display split (top) + input split (bottom). Wires pty_session callbacks to frame_buffer. `:LcarsTerm` command. |

Reuse from `block_demo.lua`: `chips_block()` pattern, `capcols()` math, chip/bar
highlight logic. Do not delete `block_demo.lua` — it is the visual reference and
is removed only from `deploy.sh`.

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
