# kitty tab bar — what kitty allows, and how to work on it

What we know about kitty's **custom tab bar** (`tab_bar_style custom`,
`kitty/tab_bar.py`) as a platform: what it can and cannot draw, how it reloads,
and how to test it without breaking your own terminal. What *our* strip looks
like and why is in `docs/dashboard.md` — "The tab bar"; its revert path is in
`docs/deployment.md`.

Verified against kitty **0.48.2** source (tag `v0.48.2`) and kitty `master` as of
2026-09-16, plus a live test, except where marked *source only*.

---

## Images: not possible on the strip

The tab bar **cannot display kitty graphics-protocol images** — not by direct
placement and not by Unicode placeholders. The rounded caps therefore stay as
powerline half-circle glyphs, and block lettering has to come from a font
(lcarcat-6ac), not a PNG.

### Why

kitty creates the tab bar's screen with no window:

```python
# kitty/tab_bar.py, TabBar.apply_options
self.screen = s = Screen(None, 1, 10, 0, self.cell_width, cell_height)   # window_id defaults to 0
```

and refuses to upload a texture for a screen without one:

```c
// kitty/graphics.c, upload_to_gpu
if (!self->context_made_current_for_this_command) {
    if (!self->window_id) return;          // <- the tab bar always stops here
    if (!make_window_context_current(self->window_id)) return;
    ...
```

So a transmission into the tab bar screen is **accepted** (the reply is
`i=N;OK`), placeholder cells are written correctly, and the placement is
computed — but the texture never reaches the GPU and nothing is drawn. A live
test showed exactly that: the strip row was solid black while the prompt
below it rendered normally.

### Everything short of that step works

Worth knowing in case kitty ever changes:

- **Escape codes can be fed into the tab bar screen** from `tab_bar.py`, using
  the same methods kitty's own test suite uses (`parse_bytes` in
  `kitty_tests/__init__.py`):

  ```python
  def feed(screen, data: bytes) -> None:
      view = memoryview(data)
      while view:
          destination = screen.test_create_write_buffer()
          count = screen.test_commit_write_buffer(view, destination)
          view = view[count:]
          screen.test_parse_written_data()
  ```

  Never call `test_create_write_buffer` twice without committing and parsing in
  between — kitty aborts the whole process with *"called with an already
  existing write buffer"*.

- **Placeholder cells draw correctly**: `screen.cursor.fg = as_rgb(image_id)`
  then `screen.draw('\U0010EEEE' + row_diacritic + column_diacritic)` produces
  the expected cells.
- **The renderer handles the tab bar's images**: `draw_cells` and
  `cell_prepare_to_render` run the same image-layer code for the tab bar as for
  a window.

### Upstream status

Searched 2026-09-16: no kitty issue or GitHub Discussion asks for images in the
tab bar. "Share your tab bar style" (discussion #4447) is all glyphs and color.
The `window_id` guard predates commit `354d7c2` (2021-01-31), which only
restructured an existing `if (self->window_id && …)`. It exists because a
screen with no window has no GPU context to activate. Nobody asked for tab bar
images and nobody decided against them. The gap is a side effect, which makes
it a reasonable thing to propose upstream.

### The ways around it

1. **An upstream kitty change** letting the tab bar upload through its OS
   window's context. The only clean fix.
2. **Monkeypatching** the tab bar screen to borrow a real window's id. Not
   recommended: it depends on kitty internals, breaks when that window closes,
   and a mistake blanks the strip in every kitty window.
3. **Glyphs** — powerline caps now, a remapped block-letter font later (lcarcat-6ac).

---

## Reloading `tab_bar.py`: press `ctrl+a>f` twice

kitty ≥ 0.45 (commit `83f0d6b`, discussion #9221) clears the cached `tab_bar.py`
module on `load_config_file`. But `Boss.load_config_file` calls
`apply_new_options()` — which reads the **still-cached** `draw_tab` back into
`TabBar.draw_func` — *before* it calls `tab_bar.clear_caches()`:

```python
self.apply_new_options(opts)      # TabBar.apply_options -> load_custom_draw_tab()  (cached: old code)
...
from .tab_bar import clear_caches
clear_caches()                    # too late for this reload
```

So the first reload keeps the old `draw_tab`, and a **second** reload picks
up the edit. That explains the earlier observation that `ctrl+a>f` "does not
reliably" reload the tab bar. **Confirmed live on 0.48.2** (2026-09-17): in a
test kitty whose `draw_tab` logged a version marker, the marker was edited and
`kitty @ load-config` run twice. The log read VERSION-1 after the first reload
and VERSION-2 only after the second. The fix is to call
`tab_bar.clear_caches()` before `apply_new_options()`.

Upstream status (searched 2026-09-17): the only related thread is discussion
#9221. Its sole reply is the maintainer's link to `83f0d6b`, and nobody followed
up. No issue reports the double reload. The order was already wrong in
`83f0d6b` itself and is unchanged on `master`. `TabBar.draw_func` is assigned
only in `apply_options`, so nothing re-reads the module later.

Reloading your own kitty is only for code that already works. Try untested code
in the sandbox (below): a `tab_bar.py` that raises takes the strip down in every
window that loaded it.

---

## `draw_tab` must respect kitty's budget

kitty draws the strip in two passes. The **measuring pass**
(`extra_data.for_layout`) calls `draw_tab` for each tab from column 0 with an
unlimited budget. kitty then shares the strip out as `max_title_length` per tab
and gives any spare width to the active tab. During the **drawing pass** it
stops, and paints a red `…`, as soon as the next tab's budget no longer fits.

Two consequences, both learned from a bug where the right-most tab vanished
whenever it was active:

- **Stay within `max_title_length`.** A tab that ignores its budget pushes the
  right-most tabs off the strip.
- **Draw nothing extra in the measuring pass.** Our last tab also draws the
  right-aligned status readout. Counted during measurement, that made the last
  tab measure as the whole strip; once it was active, kitty handed it that
  width, and the check before drawing it concluded it could not fit.

Also, the rail stub is chrome, so it is not charged to the first tab's budget.
`test/unit/tab_bar_test.py` covers all three.

## Testing without touching your own kitty

| Need | Run |
|------|-----|
| Does every tab still draw, whichever is active? | `kitty +runpy "import runpy; runpy.run_path('test/unit/tab_bar_test.py', run_name='__main__')"` |
| Try `tab_bar.py` by hand | `bash test/tab_bar_sandbox.sh [TAB_COUNT]` — re-run after each edit; `stop` to close |
| Reference screenshots at 1/2/3 tabs | `bash test/captures/tab_bar.sh` |
| Call tab bar code directly, with no window | `kitty +runpy "import runpy; runpy.run_path('probe.py', run_name='__main__')"` (not `exec(open(...).read())`: functions defined that way cannot see the probe's imports) |

Both scripts build an isolated config directory (`test/tab_bar_config.sh`) and
never touch the deployed copy. See `docs/testing.md`.

**Probing with `kitty +runpy`.** This runs code inside kitty's own Python, so
`kitty.fast_data_types.Screen` and `kitty.tab_bar` are importable. To see
graphics-protocol replies, which the real tab bar discards, pass a fake child as
the eighth argument:

```python
from kitty.fast_data_types import Screen

class Child:
    def write(self, data):
        print('REPLY', bytes(data))

screen = Screen(None, 1, 20, 0, 19, 38, 0, Child())
```

`str(screen.line(0))` and `screen.line(0).as_ansi()` show what was drawn.

**A blank strip does not mean `draw_tab` raised.** `kitty/lcars.conf` sets
the active and inactive tab foreground *and* background to black, because our
`tab_bar.py` paints every cell itself. Anything that falls back to kitty's stock
`draw_tab_with_*` functions draws black on black. To tell the difference, log
from `draw_tab` to a file; kitty's own error goes to stderr as *"Failed to load
custom tab_bar.py module"*.
