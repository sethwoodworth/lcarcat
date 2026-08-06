#!/usr/bin/env bash
# lcars_history.sh — write and query the lcarcat command history database.
#
# Subcommands:
#   insert  <preexec_timestamp> <command> <current_working_directory> <exit_code> <duration_ms>
#   query   — print ANSI-colored rows formatted for fzf (most recent first, deduplicated)
#   backfill <histfile_path>  — seed the database from a zsh history file (one-time)
#
# Database: $XDG_DATA_HOME/lcarcat/history.db  (default: ~/.local/share/lcarcat/history.db)

set -uo pipefail

DB="${XDG_DATA_HOME:-$HOME/.local/share}/lcarcat/history.db"

_init_db() {
  mkdir -p "$(dirname "$DB")"
  sqlite3 "$DB" 'CREATE TABLE IF NOT EXISTS history (
    id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    preexec_timestamp         INTEGER NOT NULL,
    command                   TEXT    NOT NULL,
    current_working_directory TEXT    NOT NULL,
    exit_code                 INTEGER NOT NULL,
    duration_ms               INTEGER NOT NULL
  );'
}

case "${1:-}" in

  insert)
    preexec_timestamp="$2"
    command="$3"
    current_working_directory="$4"
    exit_code="$5"
    duration_ms="$6"
    _init_db
    cmd_esc=$(printf '%s' "$command"               | sed "s/'/''/g")
    cwd_esc=$(printf '%s' "$current_working_directory" | sed "s/'/''/g")
    sqlite3 "$DB" "INSERT INTO history (preexec_timestamp, command, current_working_directory, exit_code, duration_ms) VALUES (${preexec_timestamp}, '${cmd_esc}', '${cwd_esc}', ${exit_code}, ${duration_ms});"
    ;;

  query)
    _init_db
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[90m'; RESET=$'\033[0m'
    query="SELECT command, current_working_directory,
                  datetime(preexec_timestamp, 'unixepoch'), exit_code, duration_ms
           FROM history
           WHERE id IN (SELECT MAX(id) FROM history GROUP BY command)
           ORDER BY preexec_timestamp DESC"
    while IFS=$'\t' read -r cmd cwd started_at exit_code duration_ms; do
      if (( exit_code == 0 )); then
        status="${GREEN}✓${RESET}"
      elif (( exit_code < 0 )); then
        status="${DIM}-${RESET}"
      else
        status="${RED}✗${exit_code}${RESET}"
      fi
      dur="${duration_ms}ms"
      (( duration_ms == 0 )) && dur="-"
      cwd_display="${cwd/#$HOME/\~}"
      printf '%s  %s  %-8s  %-40s  │ %s\n' "$started_at" "$status" "$dur" "$cwd_display" "$cmd"
    done < <(sqlite3 -separator $'\t' "$DB" "$query")
    ;;

  backfill)
    histfile="${2:-$HOME/.histfile}"
    _init_db
    count=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local_ts=0
      local_cmd="$line"
      if [[ "$line" =~ ^:\ ([0-9]+):[0-9]+\;(.+)$ ]]; then
        local_ts="${BASH_REMATCH[1]}"
        local_cmd="${BASH_REMATCH[2]}"
      fi
      cmd_esc=$(printf '%s' "$local_cmd" | sed "s/'/''/g")
      sqlite3 "$DB" "INSERT INTO history (preexec_timestamp, command, current_working_directory, exit_code, duration_ms)
        SELECT ${local_ts}, '${cmd_esc}', '', -1, 0
        WHERE NOT EXISTS (
          SELECT 1 FROM history WHERE preexec_timestamp=${local_ts} AND command='${cmd_esc}'
        );"
      (( count++ )) || true
    done < "$histfile"
    printf 'Backfill complete: %d entries processed from %s\n' "$count" "$histfile"
    ;;

  *)
    printf 'Usage: lcars_history.sh {insert|query|backfill}\n' >&2
    exit 1
    ;;

esac
