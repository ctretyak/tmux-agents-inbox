#!/usr/bin/env bash
# The inbox popup: list tracked Claude panes, auto-refreshing, jump on Enter.
# Optional $1 = a prebuilt snapshot file (from inbox-open.sh) for an instant first paint.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
snap="$1"

# Refresh cadence (seconds between auto-rebuilds); configurable, default 1.
interval="$(tmux show -gqv '@agents-inbox-refresh-interval' 2>/dev/null)"
case "$interval" in ''|*[!0-9.]*) interval=1 ;; esac

# Preview configuration. Two env vars, set by the .tmux entry point from
# @agents-inbox-preview / @agents-inbox-preview-position. Manually settable
# for testing this script standalone.
preview_pos="${AGENTS_INBOX_PREVIEW_POS:-right:55%}"
case "$AGENTS_INBOX_PREVIEW" in
  on) init_pos="$preview_pos" ;;
  *)  init_pos="hidden" ;;
esac

# Common fzf flags as positional params (bash 3.2 safe).
set -- --ansi --delimiter=$'\t' --with-nth='2..' --no-sort --layout=reverse \
  --prompt='agents> ' \
  --footer='enter: jump   ctrl-x: kill   ?: preview   ctrl-s: regroup   esc: close' \
  --preview="bash '$DIR/scripts/inbox-preview.sh' {1}" \
  --preview-window="$init_pos" \
  --bind="?:change-preview-window(hidden|$preview_pos)" \
  --bind="ctrl-s:execute-silent(bash '$DIR/scripts/_cycle-view.sh')+reload(bash '$DIR/scripts/_build.sh')" \
  --bind="ctrl-x:execute-silent(bash '$DIR/scripts/inbox-kill.sh' {1})+reload(bash '$DIR/scripts/_build.sh')" \
  --bind="load:reload(bash '$DIR/scripts/_build.sh'; sleep $interval)+refresh-preview" \
  --bind='enter:transform:[ {1} = __hdr__ ] && echo ignore || echo accept' \
  --bind='down:down+transform:[ {1} = __hdr__ ] && echo down' \
  --bind='up:up+transform:[ {1} = __hdr__ ] && echo up'

if [ -n "$snap" ] && [ -f "$snap" ]; then
  sel="$(cat "$snap" | fzf "$@" 2>/dev/null)"                          # instant paint from snapshot
else
  sel="$(fzf "$@" --bind="start:reload(bash '$DIR/scripts/_build.sh')" < /dev/null 2>/dev/null)"
fi

[ -n "$sel" ] || exit 0
paneid="$(printf '%s' "$sel" | cut -f1)"
case "$paneid" in
  %[0-9]*) jump_to "$paneid" ;;
esac
