#!/usr/bin/env bash
# _toggle-preview.sh
# Flip the @agents-inbox-preview tmux option AND set a marker so the outer
# loop in inbox-open.sh reopens the popup at the new size. Called from the
# popup's `?` bind via `execute-silent`. Has no stdout — the bind chain
# follows with `+become(true)` to actually close fzf.
#
# Persisting to the tmux option means the next popup-open inherits the user's
# last choice for BOTH the popup state AND the opener's width sizing — single
# source of truth.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
mkdir -p "$CACHE" 2>/dev/null

cur="$(tmux show -gqv '@agents-inbox-preview' 2>/dev/null)"
case "$cur" in
  on) next="off" ;;
  *)  next="on"  ;;
esac
tmux set -g '@agents-inbox-preview' "$next" 2>/dev/null
touch "$CACHE/.popup-reopen" 2>/dev/null
