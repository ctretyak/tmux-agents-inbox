#!/usr/bin/env bash
# common.sh — shared spine for tmux-agents-inbox.
# Source this; do not execute. bash 3.2 safe (no associative arrays / mapfile / ${var^^}).

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agents-inbox"

# Resolved plugin root (this file is <root>/lib/common.sh). Used to match THIS
# plugin's hook path in settings; overridable for tests via the env var.
AGENTS_INBOX_DIR="${AGENTS_INBOX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ANSI colors (rendered by `fzf --ansi`).
# Match `claude agents`: needs input = yellow, completed = green, idle = dimmed.
# Working is neutral (agent view shows an animated spinner, not a colored icon).
# Using ANSI names (not hardcoded RGB) makes the terminal theme render them the
# same as agent view does.
C_RESET=$'\033[0m'
C_WAIT=$'\033[33m'    # yellow — needs input
C_DONE=$'\033[32m'    # green  — completed
C_BG=$'\033[36m'      # cyan   — completed-with-background-tasks
C_IDLE=$'\033[90m'    # grey   — idle (dimmed)
C_HDR=$'\033[1m'      # bold default-color (group headers); readable on any selected-line bg

# --- live Claude panes -------------------------------------------------------
# Echo one pane id (%NN) per line for every tmux pane that is currently running
# an INTERACTIVE claude session. This — not state-file presence — is the source
# of truth for which rows the inbox shows, so a session never vanishes while it
# is still alive, and sessions started before the hooks still appear.
# bash 3.2: one `ps` snapshot + awk lookups, no associative arrays.
claude_panes() {
  local ps_snap pane_snap
  ps_snap="$(ps -eo pid=,ppid=,args= 2>/dev/null)"
  [ -n "$ps_snap" ] || return 0
  pane_snap="$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)"
  [ -n "$pane_snap" ] || return 0

  # One awk pass: build the parent map + pane-pid map, flag interactive-claude
  # candidates (exclude agent-view, daemon, --bg workers, sub-commands), then walk
  # each candidate's parent chain to its owning pane. (Was awk-per-hop = slow.)
  # Feed the pane map, a separator, then the ps snapshot into ONE awk. (Passing
  # multi-line data via `awk -v` triggers "awk: newline in string", so we stream
  # both on stdin and switch phase at the separator.)
  { printf '%s\n' "$pane_snap"; printf '===ENDPANES===\n'; printf '%s\n' "$ps_snap"; } | awk '
    phase!=2 {
      if ($0=="===ENDPANES===") { phase=2; next }
      if ($1!="") panepid[$1]=$2
      next
    }
    phase==2 {
      pid=$1; par[pid]=$2
      a=$0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/,"",a)
      split(a,t,/[ \t]+/); exe=t[1]
      isc=(exe ~ /(^|\/)claude$/) || (exe ~ /\/claude\/versions\//)
      if (isc \
          && a !~ /(^| )agents( |$)/ && a !~ /daemon/ && a !~ /( |\/)mcp( |$)/ \
          && a !~ /--bg/ && a !~ /(^| )attach( |$)/ \
          && a !~ /(^| )logs( |$)/ && a !~ /(^| )(stop|kill|rm|respawn|update|doctor)( |$)/)
        cand[pid]=1
    }
    END {
      for (c in cand) {
        p=c; hops=0
        while (p!="" && hops<12) {
          if (p in panepid) { print panepid[p]; break }
          p=par[p]; hops++
        }
      }
    }' | sort -u
}

# Remove $CACHE/pane-* state files whose id is absent from the live set.
# $1 = live pane ids, one per line, WITHOUT the leading '%'. Matching is exact-line
# anchored (grep -qx) so id "1" never matches inside "10".
_prune_state() {
  local live="$1" f fid
  [ -d "$CACHE" ] || return 0
  for f in "$CACHE"/pane-*; do
    [ -e "$f" ] || continue
    fid="${f##*/pane-}"
    printf '%s\n' "$live" | grep -qx "$fid" || rm -f "$f"
  done
}

# Remove state files for panes that are no longer running claude (keeps counts
# honest). Guard: only prune when tmux is reachable, so a transient failure
# doesn't nuke valid state.
prune_dead() {
  [ -d "$CACHE" ] || return 0
  local anypane live
  anypane="$(tmux list-panes -a -F x 2>/dev/null)"
  [ -n "$anypane" ] || return 0
  live="$(claude_panes | tr -d '%')"
  _prune_state "$live"
}

# Relative "ago" string from an epoch.
_ago() {
  local now d
  now="$(date +%s)"
  d=$(( now - ${1:-$now} ))
  [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 60 ];    then printf '%2ds' "$d"
  elif [ "$d" -lt 3600 ];  then printf '%2dm' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%2dh' $(( d / 3600 ))
  else                          printf '%2dd' $(( d / 86400 ))
  fi
}

_TITLE_TAIL=262144

# Portable mtime (epoch): BSD/macOS first, then GNU/Linux.
_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# The session's CURRENT transcript = newest *.jsonl in the cwd's project dir.
# Survives /compact (which switches the session to a new transcript file) and works
# for sessions whose hooks never recorded a transcript_path.
_cur_transcript() {
  local cwd="$1" slug dir
  [ -n "$cwd" ] || return 0
  slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
  dir="$HOME/.claude/projects/$slug"
  [ -d "$dir" ] || return 0
  ls -t "$dir"/*.jsonl 2>/dev/null | head -1
}

# One-line description: the transcript's latest `ai-title`. Reads only the tail (the
# latest title sits within a few KB of EOF) → constant-time, not O(file size).
_title_of() {
  local tp="$1"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  tail -c "$_TITLE_TAIL" "$tp" 2>/dev/null | grep '"type":"ai-title"' | tail -1 | sed -n 's/.*"aiTitle":"\([^"]*\)".*/\1/p'
}

# Does the latest user/assistant exchange end with the assistant asking a
# question? Used to escalate "done" rows to "waiting" — Claude Code doesn't
# fire a Notification for plain-text questions at end-of-turn.
# Looks at the LAST user-or-assistant record: if user, the question was
# already responded to (no escalation); if assistant ending with '?', escalate.
# Requires jq; without jq, returns 1 (no escalation, status stays done).
_last_assistant_ends_with_question() {
  local tp="$1" last
  [ -n "$tp" ] && [ -f "$tp" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  last="$(tail -c "$_TITLE_TAIL" "$tp" 2>/dev/null \
    | jq -rR 'fromjson?
        | select(.type=="user" or .type=="assistant")
        | (if .type=="assistant"
             then ((.message.content | map(select(.type=="text") | .text) | last) // "")
             else "" end)
        | @base64' 2>/dev/null \
    | tail -1 \
    | base64 -d 2>/dev/null \
    | sed 's/[[:space:]]*$//')"
  case "$last" in *\?) return 0 ;; *) return 1 ;; esac
}

# Last user prompt as a single line, truncated to ~60 chars + ellipsis.
# Used by the preview header. Requires jq; without jq, prints nothing.
# Mirrors _last_assistant_ends_with_question: tail-only read, base64
# encoding to survive newlines and quotes inside content.
_last_user_prompt() {
  local tp="$1" raw
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  raw="$(tail -c "$_TITLE_TAIL" "$tp" 2>/dev/null \
    | jq -rR 'fromjson?
        | select(.type=="user")
        | (.message.content
            | if type=="string" then .
              elif type=="array" then (map(select(.type=="text") | .text) | join(" "))
              else "" end)
        | @base64' 2>/dev/null \
    | tail -1 \
    | base64 -d 2>/dev/null \
    | tr '\n\t' '  ' \
    | sed 's/  */ /g; s/^ //; s/ $//')"
  [ -n "$raw" ] || return 0
  if [ "${#raw}" -gt 60 ]; then
    printf '%s…' "${raw:0:60}"
  else
    printf '%s' "$raw"
  fi
}

# Resolve a pane's status from the hook state file AND live transcript activity.
# Hooks are precise but go stale when a session compacts or predates the install;
# the transcript is always written by the live session, so its mtime is ground truth
# for "is this active". $1=hook_status $2=hook_updated $3=transcript_mtime $4=now
_status_for() {
  local hs="$1" hu="${2:-0}" tx="${3:-0}" now="$4"
  [ -n "$hu" ] || hu=0; [ -n "$tx" ] || tx=0
  # Trust the hook unconditionally for "endpoint" states where no further hook
  # events are expected before user action:
  #  - working: extended thinking is invisible to hooks AND transcript writes;
  #    transcript-freshness fallback would incorrectly demote a thinking turn.
  #  - background: post-Stop state with running bg work; no more hooks until
  #    the next prompt. The transcript-freshness check otherwise rejects this
  #    when unrelated transcript activity happens in the project dir.
  case "$hs" in
    working|background) printf '%s' "$hs"; return ;;
  esac
  # waiting is trusted ONLY while the transcript hasn't progressed past the
  # Notification. Once the user responds and Claude starts producing tokens,
  # the transcript moves past hu — flip to working so the row doesn't stay
  # stuck on Needs input through the gap to the next PreToolUse.
  if [ "$hs" = "waiting" ]; then
    [ "$tx" -gt $(( hu + 1 )) ] 2>/dev/null && { printf 'working'; return; }
    printf 'waiting'; return
  fi
  # Trust other hook states (done/idle) while fresh relative to the last
  # transcript activity. Done before the transcript-progress rules below so a
  # fresh "done" isn't re-promoted to working by post-Stop file activity
  # (ai-title indexing, telemetry, final flush — anything that touches the
  # transcript a few seconds after Stop).
  if [ -n "$hs" ] && [ "$hu" -ge $(( tx - 60 )) ] 2>/dev/null; then printf '%s' "$hs"; return; fi
  # Hook absent or stale (hu << tx): derive from transcript activity. Covers
  # pre-install sessions (hu=0) and the rare case where the hook is far older
  # than recent transcript writes.
  [ "$tx" -gt $(( hu + 1 )) ] && [ "$(( now - tx ))" -lt 5 ] 2>/dev/null && { printf 'working'; return; }
  [ "$tx" -gt $(( hu + 5 )) ] && [ "$(( now - tx ))" -lt 10 ] 2>/dev/null && { printf 'working'; return; }
  if [ "$tx" -gt 0 ] 2>/dev/null && [ "$(( now - tx ))" -lt 12 ]; then printf 'working'; return; fi
  if [ "$tx" -gt 0 ] 2>/dev/null; then printf 'done'; return; fi
  printf 'idle'
}

# Split a pane's cwd into "project<TAB>subfolder":
#   project   = the git repo name (the MAIN repo for a worktree); nearest folder if
#               not in a git repo.
#   subfolder = the worktree name, or the path within the repo (empty at the root).
# Pure path / .git-file inspection — no git subprocess (keeps the popup snappy).
_proj_sub() {
  local cwd="$1" d root proj sub gd main
  [ -n "$cwd" ] || { printf '\t'; return; }

  # Claude-managed worktree: .../<project>/.claude/worktrees/<wt>[/...]
  case "$cwd" in
    */.claude/worktrees/*)
      proj="${cwd%%/.claude/worktrees/*}"; proj="${proj##*/}"
      sub="${cwd##*/.claude/worktrees/}"
      printf '%s\t%s' "$proj" "$sub"; return ;;
  esac

  # Walk up to the repo root (first dir with a .git entry).
  d="$cwd"; root=""
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -e "$d/.git" ] && { root="$d"; break; }
    d="${d%/*}"
  done
  [ -n "$root" ] || { printf '%s\t' "${cwd##*/}"; return; }

  if [ -f "$root/.git" ]; then
    # linked worktree: .git is a FILE → "gitdir: <main>/.git/worktrees/<name>"
    gd="$(sed -n 's/^gitdir: //p' "$root/.git" 2>/dev/null)"
    main="${gd%/.git/worktrees/*}"
    proj="${main##*/}"; [ -n "$proj" ] || proj="${root##*/}"
    sub="${root##*/}"
  else
    proj="${root##*/}"
    sub="${cwd#"$root"}"; sub="${sub#/}"
  fi
  printf '%s\t%s' "$proj" "$sub"
}

# Map a status to its presentation fields as ONE tab-delimited line:
#   rank<TAB>icon<TAB>label<TAB>dim   (dim=1 only for idle rows).
# Consume with: IFS=$'\t' read -r rank icon label dim <<< "$(_status_presentation "$s")"
# Echo (not _RET_* globals): build_list's per-pane loop runs in a pipeline subshell,
# where a global-var return is a footgun; command-substitution matches this file's
# existing idiom and IFS=$'\t' read keeps labels-with-spaces intact.
# Canonical rank order (lower = more urgent): waiting<done<background<working<idle.
# Every branch assigns all four fields; the default covers unknown == idle.
_status_presentation() {
  local rank icon label dim
  case "$1" in
    waiting)    rank=0; icon="${C_WAIT}✻${C_RESET}"; label="Needs input"; dim=0 ;;
    done)       rank=1; icon="${C_DONE}✻${C_RESET}"; label="Completed";   dim=0 ;;
    background) rank=2; icon="${C_BG}✢${C_RESET}";   label="Background";  dim=0 ;;
    working)    rank=3; icon="✽";                    label="Working";     dim=0 ;;
    *)          rank=4; icon="${C_IDLE}✻${C_RESET}"; label="Idle";        dim=1 ;;
  esac
  printf '%s\t%s\t%s\t%s' "$rank" "$icon" "$label" "$dim"
}

# True when THIS plugin's hook is wired into the user's Claude Code settings.
# A heuristic, not proof: greps the user settings file (CLAUDE_SETTINGS or
# ~/.claude/settings.json) for the plugin's RESOLVED absolute hook path. Matching
# the full path (not the bare basename) means a stale/relocated install reads as
# NOT detected. Deliberately user-scope + grep-only (no jq) — see the design doc's
# accepted blind spots (project-scope / partial / wrapper installs).
_hooks_detected() {
  local settings
  settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
  [ -r "$settings" ] || return 1
  grep -qF "$AGENTS_INBOX_DIR/hooks/inbox-hook.sh" "$settings" 2>/dev/null
}

# Build the inbox rows for fzf.
# Output line: "<pane_id>\t<visible columns>"  (field 1 = hidden jump key).
# Group-header rows use the sentinel pane id "__hdr__" (jump is a no-op on them).
# View mode is read from $CACHE/.view-mode: state (default) | session | flat.
build_list() {
  local mode now live meta liveset
  local id sf hstatus hupdated cur_tx tx_mtime status updated rank icon label desc vis gkey wkey

  mode="$(cat "$CACHE/.view-mode" 2>/dev/null)"
  case "$mode" in state|session|flat) : ;; *) mode="state" ;; esac
  now="$(date +%s)"

  live="$(claude_panes)"
  meta="$(tmux list-panes -a -F '#{pane_id}|#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{pane_current_path}' 2>/dev/null)"

  # prune state files for panes not running claude (only when tmux is alive)
  if [ -n "$meta" ]; then
    _prune_state "$(printf '%s' "$live" | tr -d '%')"
  fi

  liveset=" $(printf '%s' "$live" | tr '\n' ' ') "

  # When this plugin's hook isn't detected in the user settings, prepend a
  # NON-selectable (__hdr__) yellow warning. States below are transcript-
  # approximated without hooks; this explains an empty or inaccurate popup.
  _hooks_detected || printf '__hdr__\t%s⚠ hooks not detected in %s — status may be approximate — run: bash %s/install-hooks.sh%s\n' \
    "$C_WAIT" "${CLAUDE_SETTINGS:-~/.claude/settings.json}" "$AGENTS_INBOX_DIR" "$C_RESET"

  printf '%s\n' "$meta" | while IFS='|' read -r pid sess win wname pidx cwd; do
    [ -n "$pid" ] || continue
    case "$liveset" in *" $pid "*) : ;; *) continue ;; esac
    id="${pid#%}"
    sf="$CACHE/pane-$id"
    if [ -f "$sf" ]; then read -r hstatus hupdated _ < "$sf"; else hstatus=""; hupdated=0; fi
    [ -n "$hupdated" ] || hupdated=0
    cur_tx="$(_cur_transcript "$cwd")"
    tx_mtime="$(_mtime "$cur_tx")"; [ -n "$tx_mtime" ] || tx_mtime=0
    status="$(_status_for "$hstatus" "$hupdated" "$tx_mtime" "$now")"
    # Escalate "done"/"background" to "waiting" when the last assistant message
    # ended with a question — Claude Code fires no Notification for plain-text
    # questions. Skipped if a more recent user record means the question was
    # already answered.
    case "$status" in
      done|background)
        _last_assistant_ends_with_question "$cur_tx" && status="waiting" ;;
    esac
    # "ago" reflects time-in-current-state: prefer the hook epoch (the hook now
    # holds it steady across same-status events). Fall back to transcript mtime
    # only for sessions that have no hook record (predate the install).
    if [ "$hupdated" -gt 0 ] 2>/dev/null; then updated="$hupdated"
    elif [ "$tx_mtime" -gt 0 ] 2>/dev/null; then updated="$tx_mtime"
    else updated=0
    fi
    IFS=$'\t' read -r rank icon label dim <<< "$(_status_presentation "$status")"
    desc="$(_title_of "$cur_tx")"
    [ -n "$desc" ] || desc="$wname"
    desc="${desc//$'\t'/ }"
    projsub="$(_proj_sub "$cwd")"
    proj="${projsub%%$'\t'*}"
    sub="${projsub#*$'\t'}"
    if [ "$updated" -gt 0 ] 2>/dev/null; then agostr="$(_ago "$updated")"; else agostr=" -"; fi
    # inv = newest-first within a group (ascending sort of a descending key)
    inv=$(( 9999999999 - ${updated:-0} ))
    case "$mode" in
      session) gkey="$sess"; wkey="$rank$(printf '%010d' "$inv")" ;;
      flat)    gkey=" ";     wkey="$rank$(printf '%010d' "$inv")" ;;
      *)       gkey="$rank";  wkey="$(printf '%010d' "$inv")" ;;
    esac
    # raw fields: gkey  wkey  pane_id  dim  icon  project  subfolder  message  time  label
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$gkey" "$wkey" "$pid" "$dim" "$icon" "$proj" "$sub" "$desc" "$agostr" "$label"
  done | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 \
       | awk -F'\t' -v mode="$mode" -v cw="$C_HDR" -v cr="$C_RESET" -v hr="──" -v dimc="$C_IDLE" '
      {
        gk[NR]=$1; pid[NR]=$3; dim[NR]=$4; icon[NR]=$5
        proj[NR]=$6; sb[NR]=$7; msg[NR]=$8; tm[NR]=$9; lblf[NR]=$10; cnt[$1]++
        if (length($6)>wp) wp=length($6)
        if (length($7)>ws) ws=length($7)
        if (length($8)>wm) wm=length($8)
      }
      END {
        # size each column to its widest value -> aligned, never truncated
        fmt = sprintf("%%-%ds  %%-%ds  %%-%ds  %%s", wp, ws, wm)
        have=0
        for (i=1;i<=NR;i++) {
          if (mode!="flat" && (have==0 || gk[i]!=prev)) {
            # state mode groups by rank; the row carries the canonical label from
            # _status_presentation. session mode groups by session name (gk).
            lbl = (mode=="state" ? lblf[i] : gk[i])
            printf "__hdr__\t%s%s %s (%d) %s%s\n", cw, hr, lbl, cnt[gk[i]], hr, cr
            prev=gk[i]; have=1
          }
          body=sprintf(fmt, proj[i], sb[i], msg[i], tm[i])
          if (dim[i]=="1") body=dimc body cr
          printf "%s\t%s  %s\n", pid[i], icon[i], body
        }
      }'
}

# Jump the current client to a pane id (e.g. %42). Resolves session/window live,
# so renames and window moves are handled correctly.
jump_to() {
  local pid loc sess win
  pid="$1"
  [ -n "$pid" ] || return 1
  loc="$(tmux display-message -p -t "$pid" '#{session_name}|#{window_index}' 2>/dev/null)"
  if [ -z "$loc" ]; then
    tmux display-message "agents-inbox: pane $pid is gone"
    return 1
  fi
  sess="${loc%%|*}"
  win="${loc#*|}"
  tmux switch-client -t "$sess" \; select-window -t "$sess:$win" \; select-pane -t "$pid"
}
