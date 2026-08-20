# nvim Terminal Frame — Research Index

<!-- Read this doc when: looking up specific nvim API behaviour, third-party
     plugin capabilities, or open research questions for the terminal frame system.
     Write to this doc when: a spike answers an open research question — add the
     finding under the relevant section and mark the question resolved.
     For *why* a particular approach was chosen over alternatives, see
     docs/architecture-decisions.md instead. -->

Reference for agents and developers implementing the LCARS terminal frame system.
Read the sections relevant to your task; do not read everything at once.

---

## nvim Built-in Docs

All at `/opt/homebrew/Cellar/neovim/0.12.2/share/nvim/runtime/doc/` (nvim 0.12.2).

### `terminal.txt` (707 lines)

| Lines | Topic |
|-------|-------|
| 1–45 | Overview; start methods: `:terminal`, `nvim_open_term()`, `jobstart(…, {term:true})` |
| 46–99 | Terminal-mode input, key mappings (`<C-\><C-N>`, `<C-\><C-O>`), mouse behavior |
| 100–139 | Configuration; `TermOpen` autocmd; `terminal_color_x` variables |
| 141–202 | OSC events via `TermRequest` — OSC 7 (cwd announce), OSC 52 (clipboard write) |
| 203–247 | **OSC 133 shell integration** — A/B/C/D marks, `]]`/`[[` prompt navigation, `nvim_buf_set_extmark()` annotation example |
| 248–270 | Status variables: `b:term_title`, `b:terminal_job_id`, `b:terminal_job_pid` |

Read when: implementing OSC 133 parsing, setting terminal options on open, understanding what events fire.

---

### `job_control.txt` (142 lines)

| Lines | Topic |
|-------|-------|
| 1–66 | `jobstart()` overview; `on_stdout`/`on_stderr`/`on_exit` callback signatures; data format (array of strings, last element always `""`) |
| 67–142 | OO-style callback pattern (self = opts dict); `chansend()` for stdin; `jobstop()`; `chanclose()` |

Read when: wiring up async job callbacks, sending stdin to a running job.

---

### `channel.txt` (264 lines)

| Lines | Topic |
|-------|-------|
| 1–140 | Channel architecture; raw bytes mode; on_stdout/on_stderr/on_exit signatures; **PTY channels** — stderr is merged into stdout by the OS (no separate stderr callback on `pty=true`); `jobresize()` for PTY resize |
| 141–175 | Terminal characteristics (termios) copied from the calling terminal |
| 176–230 | **Prompt buffers** (`buftype=prompt`) — structured input at the bottom of a regular buffer; alternative to `:terminal` for the input panel design |

Read when: designing the PTY session layer; deciding between PTY vs non-PTY for stderr separation; considering prompt-buffer for the input panel.

---

### `api.txt` (4328 lines)

| Lines | Topic |
|-------|-------|
| 574–595 | `nvim_chan_send({chan}, {data})` — send raw bytes to a channel or `nvim_open_term()` instance |
| 1260–1300 | **`nvim_open_term({buf}, {opts})`** — opens a full VT220 terminal emulator on an existing buffer; feed escape sequences with `nvim_chan_send()`; `on_input` callback fires when user types; can be called immediately after buffer creation |

Read when: implementing the "render ANSI into a buffer" path; the `nvim_open_term` + `nvim_chan_send` pattern is how snacks.nvim's `colorize()` works.

---

### `vimfn.txt`

| Lines | Topic |
|-------|-------|
| 866 | `chanclose({id} [, {stream}])` |
| 895–910 | `chansend({id}, {data})` |
| 5451–5460 | `jobresize({job}, {width}, {height})` |
| 5464–5545 | **`jobstart({cmd}, {opts})`** — full options reference: `pty`, `term`, `on_stdout`, `on_stderr`, `on_exit`, `width`, `height`, `env`, `cwd`, `stdin`; stderr unavailable on PTY channels |

Read when: checking exact option names/types for `jobstart`.

---

### `autocmd.txt`

| Lines | Topic |
|-------|-------|
| 1182 | `TermClose` — fires when terminal job ends |
| 1188–1194 | `TermEnter` / `TermLeave` — Terminal-mode entry/exit |
| 1196–1201 | `TermOpen` — fires when terminal job starts; set local options here |
| 1202–1237 | **`TermRequest`** — fires when `:terminal` child emits OSC/DCS/APC; sequence in `v:event.sequence` |

Read when: setting up OSC 133 listeners; hooking lifecycle events.

---

## Key Architecture Findings

### PTY and stderr

`jobstart(…, {pty=true})` merges stderr into stdout at the OS PTY layer — there is no separate `on_stderr` callback. To capture stderr separately:
- Option A: Non-PTY (`pty=false`) — `on_stdout` and `on_stderr` are separate but output is raw (no terminal control codes), so interactive programs break.
- Option B: Shell wrapper — `cmd 2> >(process_stderr_pipe)` redirects stderr through a named pipe that a second `jobstart` reads. Allows interleaved display with separate coloring.
- Option C: Use PTY for display, accept merged streams initially; add stderr separation as a later stage.

### nvim_open_term pattern

`nvim_open_term(buf, {})` + `nvim_chan_send(chan, raw_bytes)` renders a full VT220 terminal into a buffer. This can be used to:
- Display ANSI-colored output in a regular (non-`:terminal`) buffer.
- Read back rendered lines via `nvim_buf_get_lines()` — but lines are rendered text, losing ANSI codes.
- Feed bytes captured from a separate `jobstart(pty=true)` into the display buffer.

### OSC 133 via TermRequest

`TermRequest` autocmd fires for OSC sequences from `:terminal` buffers. `v:event.sequence` contains the raw sequence. Parse `\x1b]133;A`, `B`, `C`, `D` marks here. The `]]`/`[[` motions use these marks natively — they are already wired up via kitty shell integration.

If using `jobstart` without `:terminal`, OSC 133 sequences arrive as raw bytes in `on_stdout`; parse them manually.

---

## Third-Party Plugins

### ANSI Parsing / Colorizing

**[baleia.nvim](https://github.com/m00qek/baleia.nvim)** — best library option.
- Exposes `buf_set_lines()` and `buf_set_text()` wrappers that strip ANSI SGR codes and apply highlights.
- Supports 8/16/256/truecolor.
- Async-capable; suitable for high-velocity output.
- Read when: adding ANSI color rendering to the frame buffer.

**snacks.nvim `colorize()` pattern** (not a standalone library):
```lua
local chan = vim.api.nvim_open_term(buf, {})
vim.api.nvim_chan_send(chan, ansi_text)
```
Renders ANSI into a buffer using nvim's built-in terminal emulator.

### Terminal Session Management

**[toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim)**
- Uses `fn.termopen()` internally (Vimscript alias for `jobstart term=true`).
- Tracks sessions in a Lua table by ID; `M.next_id()` finds sequence gaps.
- `on_stdout`/`on_stderr` exposed as callbacks via `__make_output_handler()`.
- Read source when: designing the multi-session session table.

**[snacks.nvim terminal](https://github.com/folke/snacks.nvim)**
- `vim.fn.termopen(cmd, {term=true})`.
- Session IDs based on `cmd + cwd + env + count`; table uses weak values for GC.
- Read source when: designing session identity hashing.

**[terminal.nvim](https://github.com/rebelot/terminal.nvim)**
- Simple multi-session: `Terminal` class with `new()`, `open()`, `toggle()`, `kill()`, `send()`.
- `cycle()`, `set_target()` for navigation between sessions.
- Read source when: designing the session cycle/target API.

### Structured Output Display

**[molten-nvim](https://github.com/benlubas/molten-nvim)** — best reference for block-framed output.
- Uses extmarks to delimit cell boundaries dynamically.
- Floating windows below cells for output display.
- image.nvim for inline images.
- Architecture closely mirrors what LCARS terminal frame needs.
- Read source when: designing the block extmark boundary system; image placement relative to output.

**[overseer.nvim](https://github.com/stevearc/overseer.nvim)**
- `jobstart` with `pty`, `on_stdout`/`on_stderr` merged into same handler.
- No timestamping; no stdout/stderr separation.
- Good reference for structured task list UI around job output.
- Read `lua/overseer/strategy/jobstart.lua` when: designing the job strategy layer.

### stdout/stderr Interleaving

No reviewed plugin separates stdout/stderr with timestamps. All use PTY (merged) or accept non-PTY (separate but raw). Custom implementation required for interleaved-with-timestamps display. Named pipe approach is the most viable path.

### Full-Screen / Alternate Screen Passthrough

No reviewed plugin handles alternate screen detection (`ESC[?1049h`). Custom detection in the `on_stdout` parser is needed; hand off to a raw `:terminal` buffer for interactive programs (vim, less, fzf, etc.).

### Images Scrolling With Output

- molten-nvim: images via image.nvim on floats that follow cell positions — not true scroll-with-content.
- **Unicode placeholder protocol** (as used in lcarcat's zsh prompt): placeholder cells are real text, so they scroll naturally with the buffer. Correct approach for LCARS header/footer elbow images.

---

## Open Research Questions

These should be prototyped before committing to an implementation path:

1. **Can `nvim_open_term()` + `jobstart(pty=true)` be composed?** Feed PTY bytes into `nvim_open_term` for rendering AND intercept OSC 133 marks before forwarding. Need to verify `TermRequest` fires in this path.

2. **Does `TermRequest` fire for OSC 133 when using `jobstart+pty` vs `nvim_open_term`?** The doc says `TermRequest` fires for `:terminal` child processes — does that include buffers opened with `nvim_open_term`?

3. **Named pipe for stderr**: Does zsh interactive mode support `2>(process substitution)` for stderr redirection? Needs shell-level testing.

4. ~~**baleia.nvim performance under high-velocity output**~~ **Resolved (lcarcat-dk5):** sync mode is acceptable for bursts; use `async=true` (default) in production. Debounce still recommended for very high velocity — see lcarcat-z8h. Full findings in `docs/spike-2-baleia-findings.md`.

5. **Multiple sessions in same nvim**: Standard pattern works (table of session objects). Test: two `LcarsTerm` splits open simultaneously, both receiving output.
