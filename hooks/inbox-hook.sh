#!/usr/bin/env bash
# inbox-hook.sh <EventName> — Claude Code hook.
# Reads the hook JSON payload on stdin and writes a one-line state file for
# this tmux pane. Must be fast and must never block the agent. bash 3.2 safe.
#
# Ownership lock: each pane's state file is bound to ONE claude session_id.
# A subagent claude (e.g. a Stop-hook coach, `claude --print` invoked from
# inside the primary agent) inherits TMUX_PANE and would otherwise overwrite
# the primary's state. We detect it via a parent-process walk on SessionStart
# (no other `claude` between us and the pane shell ⇒ primary) and via a
# session_id match on every other event.

event="$1"

# Only track Claude running inside a real tmux pane.
[ -n "$TMUX_PANE" ] || exit 0

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agents-inbox"
file="$CACHE/pane-${TMUX_PANE#%}"

payload="$(cat 2>/dev/null)"

status=""
ev="$event"
tpath=""
sid=""

# Opt-in debug logging: appends one line per hook call to $CACHE/hooks.log.
# Enable:  touch ~/.cache/tmux-agents-inbox/hooks.log
# Disable: rm ~/.cache/tmux-agents-inbox/hooks.log
# Disabled by default → zero overhead beyond a stat check per hook.
trap '
  logf="$CACHE/hooks.log"
  if [ -e "$logf" ]; then
    snippet=$(printf "%s" "$payload" | tr "\n" " " | head -c 500)
    printf "%s | %-22s pane=%s status=%-24s tx=%s | %s\n" \
      "$(date +%Y-%m-%dT%H:%M:%S)" "$ev" "$TMUX_PANE" "${status:-no-write}" "${tpath:-}" "$snippet" \
      >> "$logf" 2>/dev/null
  fi
' EXIT

# Extract transcript_path and session_id from the payload up-front (needed for
# the ownership check below). The session_id is also encoded in the transcript
# filename ("<sid>.jsonl"); we fall back to that if .session_id is absent.
if command -v jq >/dev/null 2>&1; then
  tpath="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
  sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
else
  tpath="$(printf '%s' "$payload" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi
if [ -z "$sid" ] && [ -n "$tpath" ]; then
  sid="${tpath##*/}"; sid="${sid%.jsonl}"
fi

# Read the lock currently held on this pane (the session_id of whoever last
# wrote the file). Derived from the recorded transcript_path's filename.
prev_sid=""
if [ -f "$file" ]; then
  prev_tpath="$(awk '{print $4; exit}' "$file" 2>/dev/null)"
  prev_sid="${prev_tpath##*/}"; prev_sid="${prev_sid%.jsonl}"
fi

# Walk parents from $PPID. Return 0 (subagent) if we encounter another claude
# process before reaching the pane's owning shell; return 1 (primary) otherwise.
# Used only on SessionStart — it's the only event where a brand-new session_id
# is legitimate, so we have to look beyond the file to tell ownership.
_is_subagent() {
  local pp p hops me args exe ebase
  pp="$(tmux display -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null)"
  [ -z "$pp" ] && return 1   # can't determine — assume primary, write through
  me="$PPID"
  p="$me"
  hops=0
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$hops" -lt 12 ]; do
    [ "$p" = "$pp" ] && return 1   # reached the pane shell — we're primary
    if [ "$p" != "$me" ]; then     # don't count the calling claude itself
      args="$(ps -p "$p" -o args= 2>/dev/null)"
      exe="$(printf '%s' "$args" | awk '{print $1}')"
      ebase="${exe##*/}"
      case "$ebase" in claude) return 0 ;; esac
      case "$exe" in */claude/versions/*) return 0 ;; esac
    fi
    p="$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')"
    hops=$((hops + 1))
  done
  return 1   # walked off the top without finding another claude → primary
}

# Ownership enforcement: short-circuit foreign writers before they can touch
# the state file (including the SessionEnd of a coach that would otherwise
# delete the primary's state).
if [ "$event" = "SessionStart" ]; then
  if _is_subagent; then
    status="rejected:subagent"   # debug log only; never written to state file
    exit 0
  fi
elif [ -n "$prev_sid" ] && [ -n "$sid" ] && [ "$prev_sid" != "$sid" ]; then
  status="rejected:foreign-session"
  exit 0
fi

case "$event" in
  SessionStart)
    # source=compact => the SAME session just compacted and is still working;
    # startup/clear/resume are genuinely idle (waiting for your next prompt).
    src=""
    command -v jq >/dev/null 2>&1 && src="$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)"
    case "$src" in compact) status="working" ;; *) status="idle" ;; esac
    ev="SessionStart:${src:-startup}" ;;
  PreToolUse)
    # AskUserQuestion blocks on the user (multiple-choice popup) but emits no
    # Notification — its PreToolUse is the only signal, so surface it as a real
    # request. PostToolUse fires once answered and clears this back to working.
    tname=""
    command -v jq >/dev/null 2>&1 && tname="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    case "$tname" in AskUserQuestion) status="waiting" ;; *) status="working" ;; esac ;;
  UserPromptSubmit|PostToolUse|PreCompact)
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
    [ "$ntype" = "idle_prompt" ] && { status="ignored"; ev="Notification:idle_prompt"; exit 0; }
    status="waiting"
    [ -n "$ntype" ] && ev="Notification:${ntype}" ;;
  Stop)
    # Agent finished its turn. If there are still running background_tasks,
    # surface that with a dedicated "background" status so the user can see
    # at-a-glance that the session has ongoing passive work (monitor, watch
    # process, long-running shell) — distinct from a clean Completed.
    running=0
    if command -v jq >/dev/null 2>&1; then
      running="$(printf '%s' "$payload" | jq -r '[.background_tasks[]? | select(.status=="running")] | length' 2>/dev/null)"
    else
      running="$(printf '%s' "$payload" | grep -c '"status"[[:space:]]*:[[:space:]]*"running"' 2>/dev/null)"
    fi
    [ -n "$running" ] || running=0
    if [ "$running" -gt 0 ] 2>/dev/null; then status="background"; else status="done"; fi ;;
  SessionEnd)
    rm -f "$file" "$file.tmp" 2>/dev/null
    status="removed"          # for the debug log only; not a displayed status
    exit 0 ;;
  *)
    exit 0 ;;
esac

[ -n "$status" ] || exit 0

mkdir -p "$CACHE" 2>/dev/null
now="$(date +%s)"
# Keep the previous epoch when the status hasn't changed, so the popup's "ago"
# column tracks "how long in this state" instead of resetting on every tool use.
prev_status=""
prev_epoch=0
if [ -f "$file" ]; then
  read -r prev_status prev_epoch _ < "$file" 2>/dev/null
fi
if [ "$prev_status" = "$status" ] && [ "${prev_epoch:-0}" -gt 0 ] 2>/dev/null; then
  now="$prev_epoch"
fi
printf '%s %s %s %s\n' "$status" "$now" "$ev" "$tpath" > "$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file" 2>/dev/null
exit 0
