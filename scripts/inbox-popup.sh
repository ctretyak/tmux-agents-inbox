#!/usr/bin/env bash
# The inbox popup: list tracked Claude panes, auto-refreshing, jump on Enter.
# Optional $1 = a prebuilt snapshot file (from inbox-open.sh) for an instant first paint.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
snap="$1"

# Refresh cadence (seconds between auto-rebuilds); configurable, default 2.
interval="$(tmux show -gqv '@agents-inbox-refresh-interval' 2>/dev/null)"
case "$interval" in ''|*[!0-9.]*) interval=2 ;; esac

# Common fzf flags as positional params (bash 3.2 safe).
set -- --ansi --delimiter=$'\t' --with-nth='2..' --no-sort --layout=reverse \
  --prompt='agents> ' \
  --header='enter: jump   ctrl-s: regroup   esc: close' \
  --bind="ctrl-s:execute-silent(bash '$DIR/scripts/_cycle-view.sh')+reload(bash '$DIR/scripts/_build.sh')" \
  --bind="load:reload(sleep $interval; bash '$DIR/scripts/_build.sh')" \
  --expect=enter

if [ -n "$snap" ] && [ -f "$snap" ]; then
  sel="$(cat "$snap" | fzf "$@" 2>/dev/null)"                          # instant paint from snapshot
else
  sel="$(fzf "$@" --bind="start:reload(bash '$DIR/scripts/_build.sh')" < /dev/null 2>/dev/null)"
fi

[ -n "$sel" ] || exit 0
row="$(printf '%s\n' "$sel" | sed -n '2p')"     # line 1 = pressed key, line 2 = selected row
[ -n "$row" ] || exit 0
paneid="$(printf '%s' "$row" | cut -f1)"
case "$paneid" in
  %[0-9]*) jump_to "$paneid" ;;                 # ignore header rows (__hdr__)
esac
