# Architecture Decisions

<!-- Read this doc when:
     - Picking up a bead under any lcarcat epic and wondering why a particular
       library, pattern, or structural call was made
     - About to evaluate an alternative approach — check here before re-litigating
       a settled question
     - Writing post-spike findings that settle an open research question

     Write to this doc when:
     - A meaningful architectural choice has been made and the reasoning should
       survive a conversation reset (i.e., it is not obvious from the code itself)
     - The decision rules out a plausible alternative — record why so it stays ruled out
     - A spike confirms or reverses a prior assumption

     Format: one H2 per decision, with Status, Context, Decision, and Consequences.
     Status: Accepted | Superseded | Under Review
     Keep entries in reverse-chronological order (newest first). -->

---

## ANSI rendering: baleia.nvim over float-per-block or line-copy

**Status:** Accepted (2026-08-20)
**Bead:** lcarcat-dk5, lcarcat-qm0

### Context

The LCARS terminal frame needs to display ANSI-colored PTY output inside a custom nvim buffer that also carries LCARS chrome extmarks (periwinkle bar, stem column, image placeholders). Three approaches were considered:

1. **baleia.nvim** — strip ANSI SGR from PTY bytes, write clean text to the frame buffer, apply color as extmarks alongside LCARS chrome extmarks.
2. **Float-per-block (molten-nvim style)** — each block's output area is a floating window showing a `nvim_open_term()` buffer; the frame buffer holds only header/footer rows.
3. **Line-copy from hidden `:terminal`** — run each command in a hidden `:terminal` buffer, copy lines back via `nvim_buf_get_lines()`.

### Decision

Use **baleia.nvim** (path 1).

### Consequences

**Why not line-copy (path 3):**
`nvim_buf_get_lines()` on a `:terminal` buffer returns plain text with ANSI already stripped by libvterm into extmarks on the source buffer. Copying lines to the frame buffer loses all color — there is no API to bulk-copy extmarks across buffers. Lines are also padded to the terminal's column width (default 80 if the buffer is hidden without a window). This path produces monochrome, fixed-width transcluded text.

**Why not float-per-block (path 2):**
Floats are screen-absolute; they do not scroll with buffer content. Every line appended to a block above repositions every float below it, requiring full recomputation on every height change. image.nvim and floats have documented z-order conflicts. Fold-to-pill (collapsing a block to a single visual row) requires both hiding the float AND inserting a placeholder row in the frame buffer — more coordination than the single-buffer approach. This pattern suits static output (molten-nvim Jupyter cells) but is ill-suited to live streaming output where heights change continuously.

**Why baleia.nvim:**
Everything lives in one buffer. Scroll-with-content is free (the buffer scrolls normally). Fold-to-pill is a buffer edit. Tail-N is handled by not writing older lines. LCARS chrome extmarks and ANSI color extmarks coexist on the same rows. The `modifiable=false` toggle pattern (flip on → write → flip off) is idiomatic for read-only display buffers in nvim.

**Remaining risk:** baleia.nvim performance under high-velocity output (e.g. `ping`, `tail -f`) is unconfirmed. See lcarcat-dk5 (spike-2) for the benchmark. If performance is unacceptable, the escape hatch is `nvim_open_term()` + `nvim_chan_send()` for the content area with LCARS chrome in surrounding extmarks — see lcarcat-xi4 (spike-3).
