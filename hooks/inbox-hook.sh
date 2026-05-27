#!/usr/bin/env bash
# inbox-hook.sh <EventName> — Claude Code hook.
# Reads the hook JSON payload on stdin and writes a one-line state file for this
# tmux pane. Must be fast and must never block the agent. bash 3.2 safe.

event="$1"

# Only track Claude running inside a real tmux pane.
[ -n "$TMUX_PANE" ] || exit 0

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agents-inbox"
file="$CACHE/pane-${TMUX_PANE#%}"

payload="$(cat 2>/dev/null)"

status=""
ev="$event"
case "$event" in
  SessionStart)
    # source=compact => the SAME session just compacted and is still working;
    # startup/clear/resume are genuinely idle (waiting for your next prompt).
    src=""
    command -v jq >/dev/null 2>&1 && src="$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)"
    case "$src" in compact) status="working" ;; *) status="idle" ;; esac
    ev="SessionStart:${src:-startup}" ;;
  UserPromptSubmit|PreToolUse|PostToolUse|PreCompact)
    status="working" ;;
  SubagentStop)
    status="working" ;;          # parent agent is still running
  Notification)
    ntype=""
    if command -v jq >/dev/null 2>&1; then
      ntype="$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null)"
    fi
    # An idle reminder ("Claude is waiting for your input" after sitting a while)
    # is NOT a real request — leave the status untouched so a finished session
    # stays Completed instead of jumping to Needs input. Real prompts still escalate.
    [ "$ntype" = "idle_prompt" ] && exit 0
    status="waiting"
    [ -n "$ntype" ] && ev="Notification:${ntype}" ;;
  Stop)
    running=0
    if command -v jq >/dev/null 2>&1; then
      running="$(printf '%s' "$payload" | jq -r '[.background_tasks[]? | select(.status=="running")] | length' 2>/dev/null)"
    else
      running="$(printf '%s' "$payload" | grep -c '"status"[[:space:]]*:[[:space:]]*"running"' 2>/dev/null)"
    fi
    [ -n "$running" ] || running=0
    if [ "$running" -gt 0 ] 2>/dev/null; then status="working"; else status="done"; fi ;;
  SessionEnd)
    rm -f "$file" "$file.tmp" 2>/dev/null
    exit 0 ;;
  *)
    exit 0 ;;
esac

[ -n "$status" ] || exit 0

# transcript_path lets the list-builder pull this session's ai-title description.
tpath=""
if command -v jq >/dev/null 2>&1; then
  tpath="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
else
  tpath="$(printf '%s' "$payload" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi

mkdir -p "$CACHE" 2>/dev/null
now="$(date +%s)"
printf '%s %s %s %s\n' "$status" "$now" "$ev" "$tpath" > "$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file" 2>/dev/null
exit 0
