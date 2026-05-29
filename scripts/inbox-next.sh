#!/usr/bin/env bash
# Jump straight to the next waiting/done agent (no popup). Cycles on repeat press:
# waiting before done, oldest-first within each bucket.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
prune_dead

# Collect actionable panes as "rank zeropad(epoch) pane_id".
rows=""
for f in "$CACHE"/pane-*; do
  [ -e "$f" ] || continue
  read -r status updated _ < "$f"
  id="${f##*/pane-}"
  case "$status" in
    waiting|done|background) ;;
    *) continue ;;
  esac
  IFS=$'\t' read -r rank _i _l _d <<< "$(_status_presentation "$status")"
  [ -n "$updated" ] || updated=0
  rows="${rows}${rank} $(printf '%010d' "$updated") %${id}
"
done

ordered="$(printf '%s' "$rows" | LC_ALL=C sort | awk 'NF{print $3}')"
set -- $ordered
if [ "$#" -eq 0 ]; then
  tmux display-message "agents-inbox: no waiting agents"
  exit 0
fi

# Cycle: pick the entry after the last-jumped one, else the first (wrap).
cur_file="$CACHE/.next-cursor"
last="$(cat "$cur_file" 2>/dev/null)"
target="$1"
pick=0
for p in "$@"; do
  if [ "$pick" = "1" ]; then target="$p"; break; fi
  [ "$p" = "$last" ] && pick=1
done

printf '%s' "$target" > "$cur_file" 2>/dev/null
jump_to "$target"
