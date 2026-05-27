#!/usr/bin/env bash
# Rotate the inbox grouping mode: state -> session -> flat -> state.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
mkdir -p "$CACHE" 2>/dev/null
cur="$(cat "$CACHE/.view-mode" 2>/dev/null)"
case "$cur" in
  state)   next=session ;;
  session) next=flat ;;
  flat)    next=state ;;
  *)       next=session ;;   # default (unset == state) -> session
esac
printf '%s' "$next" > "$CACHE/.view-mode"
