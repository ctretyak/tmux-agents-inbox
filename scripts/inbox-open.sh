#!/usr/bin/env bash
# Open the inbox popup sized to fit its content. tmux can't auto-fit a popup, so
# we build the list once here, measure it, and open display-popup with computed
# -w/-h clamped to the client. The snapshot is reused for an instant first paint.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
mkdir -p "$CACHE" 2>/dev/null

snap="$CACHE/.popup-snapshot"
build_list > "$snap"

rows="$(grep -c '' "$snap" 2>/dev/null)"; [ "${rows:-0}" -ge 1 ] || rows=1
# widest visible width: strip ANSI, drop the hidden "%paneid<TAB>" prefix
wcols="$(sed $'s/\x1b\\[[0-9;]*m//g' "$snap" | sed $'s/^[^\t]*\t//' | awk '{ if (length > m) m = length } END { print m + 0 }')"
[ "${wcols:-0}" -ge 1 ] || wcols=40

ch="$(tmux display -p '#{client_height}' 2>/dev/null)"; [ -n "$ch" ] || ch=40
cw="$(tmux display -p '#{client_width}'  2>/dev/null)"; [ -n "$cw" ] || cw=120

h=$(( rows + 5 ))     # top/bottom borders + prompt + info ("N/N") + header line
w=$(( wcols + 8 ))    # pointer/gutter + scrollbar + borders + a little margin
maxh=$(( ch - 2 )); maxw=$(( cw - 2 ))
[ "$h" -gt "$maxh" ] && h=$maxh
[ "$w" -gt "$maxw" ] && w=$maxw
[ "$h" -lt 3 ]  && h=3
[ "$w" -lt 30 ] && w=30

tmux display-popup -E -w "$w" -h "$h" "bash '$DIR/scripts/inbox-popup.sh' '$snap'"
