#!/usr/bin/env bash
# nvim_harness_helpers.sh — composable helpers for screenshot scenario scripts.
#
# Source this file from a scenario script:
#   source "$REPO/test/nvim_harness_helpers.sh"
#
# All helpers take explicit arguments — no env var reads inside helper bodies.
# See docs/nvim-harness.md for usage guide and patterns.

# ── window lookup ─────────────────────────────────────────────────────────────

# _nvim_focused_window_id SOCK
#   Print the kitty window ID of the currently focused window.
_nvim_focused_window_id() {
    local sock="$1"
    kitty @ --to "$sock" ls 2>/dev/null | python3 -c "
import sys, json
tabs = json.load(sys.stdin)[0]['tabs']
for t in tabs:
    for w in t['windows']:
        if w.get('is_focused'):
            print(w['id']); sys.exit(0)
sys.exit(1)
"
}

# ── setup and teardown ────────────────────────────────────────────────────────

# nvim_harness_setup H SOCK SHOT_DIR
#   Create SHOT_DIR and install a teardown trap (unless LCARCAT_KEEP_ALIVE=1).
#   Call this before "$H" launch so the trap covers the full scenario.
nvim_harness_setup() {
    local harness="$1"
    local sock="$2"
    local shot_dir="$3"
    mkdir -p "$shot_dir"
    if [ "${LCARCAT_KEEP_ALIVE:-0}" != "1" ]; then
        trap "\"$harness\" teardown >/dev/null 2>&1 || true" EXIT INT TERM
    fi
}

# ── single-screenshot helpers ─────────────────────────────────────────────────

# nvim_open SOCK WIN_ID [FILE]
#   Send "nvim [FILE]\n" to WIN_ID and wait for nvim to load.
nvim_open() {
    local sock="$1"
    local win_id="$2"
    local file="${3:-}"
    kitty @ --to "$sock" send-text --match "id:$win_id" "nvim${file:+ $file}"$'\r'
    sleep 2.5
}

# nvim_reload_module SOCK WIN_ID NAME
#   Reload a Lua module by clearing package.loaded and re-requiring it.
nvim_reload_module() {
    local sock="$1"
    local win_id="$2"
    local name="$3"
    kitty @ --to "$sock" send-text --match "id:$win_id" \
        ":lua package.loaded['$name']=nil; require('$name')"$'\r'
    sleep 1.0
}

# nvim_goto_tab SOCK WIN_ID N
#   Navigate to the Nth tab (1-indexed) in nvim.
nvim_goto_tab() {
    local sock="$1"
    local win_id="$2"
    local n="$3"
    kitty @ --to "$sock" send-text --match "id:$win_id" \
        ":lua vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[$n])"$'\r'
    sleep 1.0
}

# nvim_run_cmd SOCK WIN_ID CMD
#   Send a bare ex command (no leading colon) to nvim; wait 0.5s.
nvim_run_cmd() {
    local sock="$1"
    local win_id="$2"
    local cmd="$3"
    kitty @ --to "$sock" send-text --match "id:$win_id" ":$cmd"$'\r'
    sleep 0.5
}

# nvim_check_messages SOCK WIN_ID LABEL
#   Redirect nvim :messages to /tmp/nvim_messages_LABEL.txt and abort if any
#   errors (E[0-9]+: or ^Error) are found.
nvim_check_messages() {
    local sock="$1"
    local win_id="$2"
    local label="$3"
    local outfile="/tmp/nvim_messages_${label}.txt"
    kitty @ --to "$sock" send-text --match "id:$win_id" \
        ":redir! > $outfile | messages | redir END"$'\r'
    sleep 0.4
    if grep -qiE '^E[0-9]+:|^Error' "$outfile" 2>/dev/null; then
        echo "ABORT: nvim reported errors in $label:" >&2
        cat "$outfile" >&2
        exit 1
    fi
}

# ── multi-state sequence helpers ──────────────────────────────────────────────

# nvim_render_all_tabs SOCK H WIN_ID SHOT_DIR PREFIX
#   Call render_all() then iterate each tab, capturing PREFIX-tab-N.png per tab.
#   Useful for verifying images don't bleed across tabs.
nvim_render_all_tabs() {
    local sock="$1"
    local harness="$2"
    local win_id="$3"
    local shot_dir="$4"
    local prefix="$5"
    kitty @ --to "$sock" send-text --match "id:$win_id" \
        ":lua require('lcars.chrome').render_all()"$'\r'
    sleep 1.0
    local tab_count
    tab_count=$(kitty @ --to "$sock" ls 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data[0]['tabs']))
")
    for i in $(seq 1 "$tab_count"); do
        nvim_goto_tab "$sock" "$win_id" "$i"
        LCARCAT_SHOT_DIR="$shot_dir" "$harness" snapshot "${prefix}-tab-${i}"
    done
}

# nvim_tab_sequence SOCK H WIN_ID SHOT_DIR PREFIX TAB_INDICES...
#   Navigate through a list of tab indices, sleeping and snapshotting each.
nvim_tab_sequence() {
    local sock="$1"
    local harness="$2"
    local win_id="$3"
    local shot_dir="$4"
    local prefix="$5"
    shift 5
    local index=1
    for tab in "$@"; do
        nvim_goto_tab "$sock" "$win_id" "$tab"
        LCARCAT_SHOT_DIR="$shot_dir" "$harness" snapshot "${prefix}-tab-${tab}-step-${index}"
        index=$((index + 1))
    done
}

# nvim_split_then_render SOCK H WIN_ID SHOT_DIR PREFIX
#   Open a vsplit, render in the left pane, switch to the right pane, snapshot both.
#   Verifies images don't appear in the wrong pane.
nvim_split_then_render() {
    local sock="$1"
    local harness="$2"
    local win_id="$3"
    local shot_dir="$4"
    local prefix="$5"
    kitty @ --to "$sock" send-text --match "id:$win_id" ":vsplit"$'\r'
    sleep 1.0
    kitty @ --to "$sock" send-text --match "id:$win_id" \
        ":lua require('lcars.chrome').render_all()"$'\r'
    sleep 1.0
    LCARCAT_SHOT_DIR="$shot_dir" "$harness" snapshot "${prefix}-left-rendered"
    kitty @ --to "$sock" send-text --match "id:$win_id" $'\x0f'
    sleep 0.5
    LCARCAT_SHOT_DIR="$shot_dir" "$harness" snapshot "${prefix}-right-after-switch"
}
