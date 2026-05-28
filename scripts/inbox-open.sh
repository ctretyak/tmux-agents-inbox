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

# Resolve "<N>%" against a base, or pass an integer through unchanged.
_pct() { case "$1" in *%) echo $(( ${1%\%} * $2 / 100 )) ;; *) echo "$1" ;; esac; }

fix_w_opt="$(tmux show -gqv '@agents-inbox-popup-width'  2>/dev/null)"
fix_h_opt="$(tmux show -gqv '@agents-inbox-popup-height' 2>/dev/null)"

maxh=$(( ch - 2 )); maxw=$(( cw - 2 ))

# Height: fixed override wins over content-fit + min floor.
if [ -n "$fix_h_opt" ]; then
  h="$(_pct "$fix_h_opt" "$ch")"
else
  min_h_opt="$(tmux show -gqv '@agents-inbox-popup-min-height' 2>/dev/null)"
  [ -n "$min_h_opt" ] || min_h_opt='60%'
  min_h="$(_pct "$min_h_opt" "$ch")"
  [ "$min_h" -gt "$maxh" ] && min_h=$maxh
  h=$(( rows + 5 ))            # top/bottom borders + prompt + info ("N/N") + header
  [ "$h" -lt "$min_h" ] && h=$min_h
fi

# Width: fixed override wins over content-fit + min floor.
if [ -n "$fix_w_opt" ]; then
  w="$(_pct "$fix_w_opt" "$cw")"
else
  min_w_opt="$(tmux show -gqv '@agents-inbox-popup-min-width' 2>/dev/null)"
  [ -n "$min_w_opt" ] || min_w_opt='50%'
  min_w="$(_pct "$min_w_opt" "$cw")"
  [ "$min_w" -gt "$maxw" ] && min_w=$maxw
  w=$(( wcols + 8 ))           # pointer/gutter + scrollbar + borders + margin
  [ "$w" -lt "$min_w" ] && w=$min_w
fi

# Final cap so any explicit value can't blow past the client.
[ "$h" -gt "$maxh" ] && h=$maxh
[ "$w" -gt "$maxw" ] && w=$maxw

tmux display-popup -E -w "$w" -h "$h" "bash '$DIR/scripts/inbox-popup.sh' '$snap'"
