#!/usr/bin/env bash
# nvim_state.sh — query the state of a live nvim in the test kitty instance.
#
# Uses nvim's built-in RPC (--remote-expr / --server) rather than sending
# keystrokes through kitty, so it works regardless of nvim's input mode.
#
# Usage:
#   bash test/nvim_state.sh              # full state report
#
# Requires a running test kitty (bash test/screenshot_harness.sh launch).

set -euo pipefail

SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"

# ── find the nvim server address ──────────────────────────────────────────────
# nvim writes its socket to v:servername. We ask kitty to echo it to a file.
NVIM_ADDR_FILE="/tmp/nvim_state_addr.txt"
rm -f "$NVIM_ADDR_FILE"

WIN=$(kitty @ --to "$SOCK" ls 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for os_win in d:
    for tab in os_win['tabs']:
        for w in tab['windows']:
            print(w['id']); sys.exit(0)
sys.exit(1)
")

if [ -z "$WIN" ]; then
  echo "ERROR: no kitty window found on $SOCK" >&2
  exit 1
fi

# Ask nvim to write its server address to a file we can read.
kitty @ --to "$SOCK" send-text --match "id:$WIN" \
  ":call writefile([v:servername], '$NVIM_ADDR_FILE')"$'\r'
sleep 0.3

if [ ! -f "$NVIM_ADDR_FILE" ] || [ ! -s "$NVIM_ADDR_FILE" ]; then
  echo "ERROR: could not read nvim server address" >&2
  exit 1
fi

NVIM_SERVER=$(cat "$NVIM_ADDR_FILE")
echo "nvim server: $NVIM_SERVER"
echo "kitty win:   $WIN"
echo ""

# ── helper: eval a Lua expression via nvim RPC ───────────────────────────────
neval() {
  nvim --server "$NVIM_SERVER" --remote-expr "$1" 2>/dev/null
}

# ── report ────────────────────────────────────────────────────────────────────
echo "=== mode ==="
neval "mode()"

echo ""
echo "=== tabs ==="
neval "luaeval('(function() local r={} for i,t in ipairs(vim.api.nvim_list_tabpages()) do local wins=vim.api.nvim_tabpage_list_wins(t) local bufs=\"\" for _,w in ipairs(wins) do local b=vim.api.nvim_win_get_buf(w) local n=vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b),\":t\") bufs=bufs..(n==\"\" and \"[No Name]\" or n)..\" \" end local cur=t==vim.api.nvim_get_current_tabpage() r[#r+1]=string.format(\"tab %d (id=%d): %s%s\",i,t,bufs,cur and \"<CURRENT>\" or \"\") end return table.concat(r,\"\\n\") end)()')"

echo ""
echo "=== current buffer ==="
neval "luaeval('(function() local buf=vim.api.nvim_get_current_buf() local name=vim.api.nvim_buf_get_name(buf) local lc=vim.api.nvim_buf_line_count(buf) local bt=vim.bo[buf].buftype local mod=tostring(vim.bo[buf].modifiable) return string.format(\"id=%d  name=%s\\nlines=%d  buftype=%s  modifiable=%s\",buf,name==\"\" and \"[No Name]\" or name,lc,bt,mod) end)()')"

echo ""
echo "=== first 10 buffer lines (byte-length + preview) ==="
neval "luaeval('(function() local buf=vim.api.nvim_get_current_buf() local lc=vim.api.nvim_buf_line_count(buf) local ls=vim.api.nvim_buf_get_lines(buf,0,math.min(10,lc),false) local r={} for i,l in ipairs(ls) do local p=l:gsub(\"[%c\\128-\\255]\",\"·\"):sub(1,60) r[#r+1]=string.format(\"[%02d] %d bytes: %s\",i,#l,p) end return table.concat(r,\"\\n\") end)()')"

echo ""
echo "=== window options ==="
neval "luaeval('(function() local win=vim.api.nvim_get_current_win() return string.format(\"showtabline=%s  number=%s  signcolumn=%s\",vim.o.showtabline,tostring(vim.wo[win].number),vim.wo[win].signcolumn) end)()')"
