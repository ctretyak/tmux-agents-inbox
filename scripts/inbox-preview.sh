#!/usr/bin/env bash
# inbox-preview.sh <pane_id>
# Render the preview pane for one fzf row. Outputs:
#   <project> · <sub> · "<ai-title>"
#   <icon> <state-label> · <ago> · last prompt: "<60-char snippet…>"
#   ────────...
#   <last N lines of `tmux capture-pane -p -e -t <pane_id>`>
#
# Pure read; never writes state. Header rows (pane id "__hdr__") render a single
# placeholder. A stale / closed pane renders "(pane closed)" in the body.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"

pid="$1"

# Header rows from the fzf list pass __hdr__ as their pane id — no pane to capture.
if [ -z "$pid" ] || [ "$pid" = "__hdr__" ]; then
  printf '—\n'
  exit 0
fi

# Resolve the pane's cwd. If tmux can't find the pane, it's gone.
cwd="$(tmux display -p -t "$pid" '#{pane_current_path}' 2>/dev/null)"
if [ -z "$cwd" ]; then
  printf '(pane closed)\n'
  exit 0
fi

# --- header line 1: project · sub · "title" --------------------------------
projsub="$(_proj_sub "$cwd")"
proj="${projsub%%$'\t'*}"
sub="${projsub#*$'\t'}"
cur_tx="$(_cur_transcript "$cwd")"
title="$(_title_of "$cur_tx")"
[ -n "$title" ] || title="(no title)"

if [ -n "$sub" ]; then
  printf '%s · %s · "%s"\n' "$proj" "$sub" "$title"
else
  printf '%s · "%s"\n' "$proj" "$title"
fi

# --- header line 2: state · age · last prompt -----------------------------
id="${pid#%}"
sf="$CACHE/pane-$id"
hstatus=""; hupdated=0
if [ -f "$sf" ]; then
  read -r hstatus hupdated _ < "$sf"
fi
[ -n "$hupdated" ] || hupdated=0
tx_mtime="$(_mtime "$cur_tx")"; [ -n "$tx_mtime" ] || tx_mtime=0
now="$(date +%s)"
status="$(_status_for "$hstatus" "$hupdated" "$tx_mtime" "$now")"
case "$status" in
  done|background)
    _last_assistant_ends_with_question "$cur_tx" && status="waiting" ;;
esac

case "$status" in
  waiting)    icon="${C_WAIT}✻${C_RESET}";  label="Needs input" ;;
  done)       icon="${C_DONE}✻${C_RESET}";  label="Completed" ;;
  background) icon="${C_BG}✢${C_RESET}";    label="Background" ;;
  working)    icon="✽";                     label="Working" ;;
  *)          icon="${C_IDLE}✻${C_RESET}";  label="Idle" ;;
esac

# "ago": prefer hook epoch (state-stable), else transcript mtime.
if [ "$hupdated" -gt 0 ] 2>/dev/null; then
  agostr="$(_ago "$hupdated")"
elif [ "$tx_mtime" -gt 0 ] 2>/dev/null; then
  agostr="$(_ago "$tx_mtime")"
else
  agostr=" -"
fi

prompt="$(_last_user_prompt "$cur_tx")"
if [ -n "$prompt" ]; then
  printf '%b %s · %s · last prompt: "%s"\n' "$icon" "$label" "$agostr" "$prompt"
else
  printf '%b %s · %s\n' "$icon" "$label" "$agostr"
fi

# --- separator ------------------------------------------------------------
# Match the preview width if fzf told us; otherwise 60.
width="${FZF_PREVIEW_COLUMNS:-60}"
case "$width" in ''|*[!0-9]*) width=60 ;; esac
# Cap absurdly wide previews to keep the separator from wrapping.
[ "$width" -gt 200 ] && width=200
i=0
while [ "$i" -lt "$width" ]; do
  printf '─'
  i=$((i + 1))
done
printf '\n'

# --- body: live capture-pane tail -----------------------------------------
# -p: print to stdout. -e: preserve ANSI for color. -S -200: read up to last
# 200 lines of scrollback (cheap upper bound). Then tail to the preview height
# minus header (3 lines) + a 1-line margin = 4.
lines="${FZF_PREVIEW_LINES:-30}"
case "$lines" in ''|*[!0-9]*) lines=30 ;; esac
body_lines=$(( lines - 4 ))
[ "$body_lines" -lt 1 ] && body_lines=1

# Distinguish "pane gone" (capture-pane fails) from "pane is alive but blank"
# (capture-pane succeeds with empty output). Only the former should show
# "(pane closed)"; the latter just renders empty.
raw_body="$(tmux capture-pane -p -e -t "$pid" -S -2000 2>/dev/null)"
if [ "$?" -ne 0 ]; then
  printf '(pane closed)\n'
else
  # Strip Claude Code TUI chrome. Anchor on the auto-mode hint line (the
  # distinctive ⏵⏵ chevrons appear nowhere else in normal output). The chrome
  # sandwich above the hint is: input-box top border, input area (1-N lines),
  # input-box bottom border, status line. Cutting 5 lines above the hint drops
  # the typical single-line-input chrome cleanly; taller input loses content
  # rather than leaking chrome, which is the right trade-off for a preview.
  # If no ⏵ is found (plain shell pane), keep the capture as-is.
  # After cutting chrome, trim trailing blank lines so `tail -n body_lines`
  # doesn't waste the preview area on whitespace that sat between content and
  # the chrome.
  printf '%s\n' "$raw_body" \
    | awk '
        { lines[NR] = $0 }
        /⏵/ { hint = NR }
        END {
          last = (hint > 0 ? hint - 5 : NR)
          if (last < 1) last = 0
          while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
          for (i = 1; i <= last; i++) print lines[i]
        }
      ' \
    | tail -n "$body_lines"
fi
