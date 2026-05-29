#!/usr/bin/env bash
# Open the inbox popup sized to fit its content. tmux can't auto-fit a popup, so
# we build the list once here, measure it, and open display-popup with computed
# -w/-h clamped to the client. The snapshot is reused for an instant first paint.
#
# Reopen loop: tmux display-popup is one-shot — it can't be resized mid-display.
# So pressing `?` inside the popup writes a marker file and exits fzf; we detect
# the marker and reopen the popup at the new size matching the toggled preview
# state. Brief flicker, but the popup actually fits.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
mkdir -p "$CACHE" 2>/dev/null

snap="$CACHE/.popup-snapshot"
reopen_marker="$CACHE/.popup-reopen"

# Resolve "<N>%" against a base, or pass an integer through unchanged.
_pct() { case "$1" in *%) echo $(( ${1%\%} * $2 / 100 )) ;; *) echo "$1" ;; esac; }

while :; do
  rm -f "$reopen_marker" 2>/dev/null
  build_list > "$snap"

  rows="$(grep -c '' "$snap" 2>/dev/null)"; [ "${rows:-0}" -ge 1 ] || rows=1
  # widest visible width: strip ANSI, drop the hidden "%paneid<TAB>" prefix
  wcols="$(sed $'s/\x1b\\[[0-9;]*m//g' "$snap" | sed $'s/^[^\t]*\t//' | awk '{ if (length > m) m = length } END { print m + 0 }')"
  [ "${wcols:-0}" -ge 1 ] || wcols=40

  ch="$(tmux display -p '#{client_height}' 2>/dev/null)"; [ -n "$ch" ] || ch=40
  cw="$(tmux display -p '#{client_width}'  2>/dev/null)"; [ -n "$cw" ] || cw=120

  fix_w_opt="$(tmux show -gqv '@agents-inbox-popup-width'  2>/dev/null)"
  fix_h_opt="$(tmux show -gqv '@agents-inbox-popup-height' 2>/dev/null)"

  # Preview options. Default off. When on, reserve cells for the preview pane.
  preview_on="$(tmux show -gqv '@agents-inbox-preview' 2>/dev/null)"
  preview_pos="$(tmux show -gqv '@agents-inbox-preview-position' 2>/dev/null)"
  [ -n "$preview_pos" ] || preview_pos='right:55%'
  PREVIEW_CELLS=60   # minimum cells the preview pane wants to look useful

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
    # Preview floor: when preview is on AND positioned on left/right, add PREVIEW_CELLS
    # so the right pane has space to render. Bottom/top positions consume height, not width.
    if [ "$preview_on" = "on" ]; then
      case "$preview_pos" in
        right:*|left:*) w=$(( w + PREVIEW_CELLS )) ;;
      esac
    fi
    [ "$w" -lt "$min_w" ] && w=$min_w
  fi

  # Final cap so any explicit value can't blow past the client.
  [ "$h" -gt "$maxh" ] && h=$maxh
  [ "$w" -gt "$maxw" ] && w=$maxw

  # Narrow-client fallback: if preview is on and side-positioned but the popup
  # couldn't get wide enough to host both list+preview, swap to a bottom layout
  # for this open. Pass through to the popup script via AGENTS_INBOX_PREVIEW_POS.
  effective_pos="$preview_pos"
  if [ "$preview_on" = "on" ]; then
    case "$preview_pos" in
      right:*|left:*)
        list_plus_preview=$(( wcols + 8 + PREVIEW_CELLS ))
        if [ "$list_plus_preview" -gt "$maxw" ]; then
          effective_pos='bottom:40%'
          # Bottom preview wants some extra height too — add ~12 rows if available.
          new_h=$(( h + 12 ))
          [ "$new_h" -gt "$maxh" ] && new_h=$maxh
          h=$new_h
        fi
        ;;
    esac
  fi

  tmux display-popup -E -w "$w" -h "$h" \
    -e "AGENTS_INBOX_PREVIEW=$preview_on" \
    -e "AGENTS_INBOX_PREVIEW_POS=$effective_pos" \
    "bash '$DIR/scripts/inbox-popup.sh' '$snap'"

  # Loop only if the popup was closed because the user toggled preview;
  # any other exit (Enter/jump, Esc, Ctrl-X kill) breaks out.
  [ -f "$reopen_marker" ] || break
done
