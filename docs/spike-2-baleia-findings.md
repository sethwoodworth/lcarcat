# Spike-2 Findings: baleia.nvim + modifiable=false buffer pattern

<!-- Read this doc when: implementing frame_renderer.lua or frame_buffer.lua and
     making decisions about how to write ANSI output into the display buffer.
     Also read when debugging unexpected color extmark behavior from baleia. -->

**Bead:** lcarcat-dk5  
**Date:** 2026-08-20  
**Spike file:** nvim/lua/lcars/spike_baleia.lua  
**Harness:** test/captures/spike_baleia.sh

---

## Results

All three acceptance criteria passed.

| Test | Result |
|------|--------|
| baleia.buf_set_lines() writes through modifiable=false toggle | PASS |
| Pre-existing extmarks survive the toggle | PASS |
| 100-line burst timing | PASS (sync mode) |

---

## How the modifiable toggle works

baleia's `buf_set_lines()` calls `nvim_buf_set_lines()` via `pcall` internally.
It does **not** toggle `modifiable` itself — if the buffer is `modifiable=false`
when called, the pcall catches the error, logs it silently, and writes nothing.

The correct pattern for frame_renderer.lua:

```lua
vim.bo[buf].modifiable = true
baleia.buf_set_lines(buf, row, row, false, { raw_ansi_line })
vim.bo[buf].modifiable = false
```

The toggle must wrap the call. There is no baleia API that handles this
automatically. `buf.with_options` exists internally in baleia but is not
exported.

---

## Extmarks survive the modifiable toggle

`nvim_buf_set_lines()` does not clear extmarks in unaffected rows. A sentinel
extmark placed on row 1 before a burst of writes to rows 4–103 was intact
after all writes completed. LCARS chrome extmarks (stem highlights, bar
backgrounds, image placeholders) placed before content writes will not be
disturbed by subsequent `buf_set_lines` calls to different rows.

**Caveat:** writing to a row that *already has* an extmark will shift
extmarks that were anchored to that row downward if lines are inserted (not
replaced). Use `strict_indexing=false` and replace-mode writes where possible.

---

## Performance

100 lines in sync mode (`async=false`): acceptable, no perceptible lag.

For production use in frame_buffer.lua, set `async=true` (the default). The
async path uses `vim.loop.new_thread` + mpack serialization, keeping SGR
parsing off the main loop entirely. Debouncing high-velocity output (e.g.
`ping`, `tail -f`) is still recommended — see backlog bead lcarcat-z8h.

---

## Known color artifact: highlight endpoint clipping

baleia computes highlight `lastcolumn` as the byte offset of the `\27[0m`
reset code after stripping. For lines where the reset falls at or near the
end of the text, the last 1–2 characters may render in the default fg color
instead of the intended highlight color. This is an off-by-one in baleia's
end-column calculation when `\27[0m` is the final sequence on a line.

**Impact on frame_renderer.lua:** minimal. Real command output rarely ends
a color run at the exact last byte of a line before the newline. The artifact
is visible in synthetic test lines but not in normal shell output. If it
becomes a problem, the workaround is to append a trailing space before the
reset: `color_code .. text .. " \27[0m"` so the endpoint lands one column
past the visible text.

---

## Setup note

baleia.nvim must be installed with `submodules = false` in the lazy.nvim
spec. Its test vendor submodule (`test/vendor/matcher_combinators.lua`) is
not a valid git submodule in the lazy clone context and causes a fatal
checkout error. The Lua runtime files are unaffected; only tests break.

```lua
{ "m00qek/baleia.nvim", version = "v1.4.0", submodules = false }
```
