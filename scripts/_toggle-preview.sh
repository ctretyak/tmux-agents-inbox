#!/usr/bin/env bash
# _toggle-preview.sh <preview-position>
# Flip the @agents-inbox-preview tmux option and emit the fzf action that
# updates the preview window to match. Called from inbox-popup.sh's `?` bind
# via fzf's `transform:` action — the stdout becomes the next fzf binding to
# execute.
#
# Persisting to the tmux option (not a state file) means the next popup-open
# inherits the user's last choice for BOTH the popup state AND the opener's
# width sizing — single source of truth.

pos="$1"
[ -n "$pos" ] || pos='right:55%'

cur="$(tmux show -gqv '@agents-inbox-preview' 2>/dev/null)"
case "$cur" in
  on) next="off"; window="hidden" ;;
  *)  next="on";  window="$pos" ;;
esac
tmux set -g '@agents-inbox-preview' "$next" 2>/dev/null
printf 'change-preview-window:%s' "$window"
