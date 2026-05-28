#!/usr/bin/env bash
# common.sh — shared spine for tmux-agents-inbox.
# Source this; do not execute. bash 3.2 safe (no associative arrays / mapfile / ${var^^}).

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agents-inbox"

# ANSI colors (rendered by `fzf --ansi`).
# Match `claude agents`: needs input = yellow, completed = green, idle = dimmed.
# Working is neutral (agent view shows an animated spinner, not a colored icon).
# Using ANSI names (not hardcoded RGB) makes the terminal theme render them the
# same as agent view does.
C_RESET=$'\033[0m'
C_WAIT=$'\033[33m'    # yellow — needs input
C_DONE=$'\033[32m'    # green  — completed
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

# Remove state files for panes that are no longer running claude (keeps counts
# honest). Guard: only prune when tmux is reachable, so a transient failure
# doesn't nuke valid state.
prune_dead() {
  [ -d "$CACHE" ] || return 0
  local anypane pruneset f fid
  anypane="$(tmux list-panes -a -F x 2>/dev/null)"
  [ -n "$anypane" ] || return 0
  pruneset=" $(claude_panes | tr -d '%' | tr '\n' ' ') "
  for f in "$CACHE"/pane-*; do
    [ -e "$f" ] || continue
    fid="${f##*/pane-}"
    case "$pruneset" in *" $fid "*) : ;; *) rm -f "$f" ;; esac
  done
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

# Does the latest assistant message end with a question mark? Used to escalate
# "done" rows to "waiting" — Claude Code doesn't fire a Notification for
# plain-text questions at end-of-turn, so we infer from the transcript.
# Requires jq; without jq, returns 1 (no escalation, status stays done).
_last_assistant_ends_with_question() {
  local tp="$1" last
  [ -n "$tp" ] && [ -f "$tp" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  last="$(tail -c "$_TITLE_TAIL" "$tp" 2>/dev/null \
    | jq -rR 'fromjson? | select(.type=="assistant") | (.message.content | map(select(.type=="text") | .text) | last) | @base64' 2>/dev/null \
    | tail -1 \
    | base64 -d 2>/dev/null \
    | sed 's/[[:space:]]*$//')"
  case "$last" in *\?) return 0 ;; *) return 1 ;; esac
}

# Resolve a pane's status from the hook state file AND live transcript activity.
# Hooks are precise but go stale when a session compacts or predates the install;
# the transcript is always written by the live session, so its mtime is ground truth
# for "is this active". $1=hook_status $2=hook_updated $3=transcript_mtime $4=now
_status_for() {
  local hs="$1" hu="${2:-0}" tx="${3:-0}" now="$4"
  [ -n "$hu" ] || hu=0; [ -n "$tx" ] || tx=0
  # If the hook says working, trust it: the pane is in claude_panes (process alive),
  # and extended thinking is invisible to BOTH hook events and transcript writes —
  # falling back to transcript freshness would incorrectly demote a thinking session
  # to "done". A subsequent Stop event demotes to done.
  [ "$hs" = "working" ] && { printf 'working'; return; }
  # If transcript activity is newer than the hook by more than a few seconds AND
  # happened recently, the session has progressed past the recorded state —
  # typically the user just submitted a new prompt and UserPromptSubmit hasn't
  # been recorded yet, while the hook still shows the previous turn's "done".
  # The "recent" guard keeps background bookkeeping writes (system metadata
  # records 20+ s after Stop) from spuriously promoting an idle session.
  [ "$tx" -gt $(( hu + 5 )) ] && [ "$(( now - tx ))" -lt 10 ] 2>/dev/null && { printf 'working'; return; }
  # Trust other hook states while fresh relative to the last transcript activity.
  if [ -n "$hs" ] && [ "$hu" -ge $(( tx - 60 )) ] 2>/dev/null; then printf '%s' "$hs"; return; fi
  # Hook stale/absent → derive from transcript activity.
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

# Build the inbox rows for fzf.
# Output line: "<pane_id>\t<visible columns>"  (field 1 = hidden jump key).
# Group-header rows use the sentinel pane id "__hdr__" (jump is a no-op on them).
# View mode is read from $CACHE/.view-mode: state (default) | session | flat.
build_list() {
  local mode now live meta liveset pruneset f fid
  local id sf hstatus hupdated cur_tx tx_mtime status updated rank icon dcol desc vis gkey wkey

  mode="$(cat "$CACHE/.view-mode" 2>/dev/null)"
  case "$mode" in state|session|flat) : ;; *) mode="state" ;; esac
  now="$(date +%s)"

  live="$(claude_panes)"
  meta="$(tmux list-panes -a -F '#{pane_id}|#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{pane_current_path}' 2>/dev/null)"

  # prune state files for panes not running claude (only when tmux is alive)
  if [ -n "$meta" ]; then
    pruneset=" $(printf '%s' "$live" | tr -d '%' | tr '\n' ' ') "
    for f in "$CACHE"/pane-*; do
      [ -e "$f" ] || continue
      fid="${f##*/pane-}"
      case "$pruneset" in *" $fid "*) : ;; *) rm -f "$f" ;; esac
    done
  fi

  liveset=" $(printf '%s' "$live" | tr '\n' ' ') "
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
    # Escalate "done" to "waiting" when the last assistant message ended with a
    # question — Claude Code fires no Notification for plain-text questions.
    if [ "$status" = "done" ] && _last_assistant_ends_with_question "$cur_tx"; then
      status="waiting"
    fi
    # "ago" reflects time-in-current-state: prefer the hook epoch (the hook now
    # holds it steady across same-status events). Fall back to transcript mtime
    # only for sessions that have no hook record (predate the install).
    if [ "$hupdated" -gt 0 ] 2>/dev/null; then updated="$hupdated"
    elif [ "$tx_mtime" -gt 0 ] 2>/dev/null; then updated="$tx_mtime"
    else updated=0
    fi
    case "$status" in
      waiting) rank=0; icon="${C_WAIT}✻${C_RESET}"; dcol="" ;;
      done)    rank=1; icon="${C_DONE}✻${C_RESET}"; dcol="" ;;
      working) rank=2; icon="✽"; dcol="" ;;
      *)       rank=3; icon="${C_IDLE}✻${C_RESET}"; dcol="$C_IDLE" ;;
    esac
    desc="$(_title_of "$cur_tx")"
    [ -n "$desc" ] || desc="$wname"
    desc="${desc//$'\t'/ }"
    projsub="$(_proj_sub "$cwd")"
    proj="${projsub%%$'\t'*}"
    sub="${projsub#*$'\t'}"
    if [ "$updated" -gt 0 ] 2>/dev/null; then agostr="$(_ago "$updated")"; else agostr=" -"; fi
    if [ -n "$dcol" ]; then dim=1; else dim=0; fi
    # inv = newest-first within a group (ascending sort of a descending key)
    inv=$(( 9999999999 - ${updated:-0} ))
    case "$mode" in
      session) gkey="$sess"; wkey="$rank$(printf '%010d' "$inv")" ;;
      flat)    gkey=" ";     wkey="$rank$(printf '%010d' "$inv")" ;;
      *)       gkey="$rank";  wkey="$(printf '%010d' "$inv")" ;;
    esac
    # raw fields: gkey  wkey  pane_id  dim  icon  project  subfolder  message  time
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$gkey" "$wkey" "$pid" "$dim" "$icon" "$proj" "$sub" "$desc" "$agostr"
  done | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 \
       | awk -F'\t' -v mode="$mode" -v cw="$C_HDR" -v cr="$C_RESET" -v hr="──" -v dimc="$C_IDLE" '
      {
        gk[NR]=$1; pid[NR]=$3; dim[NR]=$4; icon[NR]=$5
        proj[NR]=$6; sb[NR]=$7; msg[NR]=$8; tm[NR]=$9; cnt[$1]++
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
            lbl=gk[i]
            if (mode=="state") {
              if      (gk[i]=="0") lbl="Needs input"
              else if (gk[i]=="1") lbl="Completed"
              else if (gk[i]=="2") lbl="Working"
              else                 lbl="Idle"
            }
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
