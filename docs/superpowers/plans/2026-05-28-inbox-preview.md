# Inbox preview pane — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-row preview pane to the `prefix + I` popup that shows a transcript-derived header over a live `tmux capture-pane` tail of the agent's actual TUI — so users can triage Claude sessions without jumping to the pane.

**Architecture:** A new standalone `inbox-preview.sh` reads only the highlighted pane id (passed by fzf as `{1}`) and prints header + separator + body. The popup script wires it in via fzf's `--preview` / `--preview-window`, with a `?` bind to toggle visibility. The opener computes width with a preview floor and falls back to bottom layout on narrow clients. The `.tmux` entry point exposes two new options. No daemon, no new cache, no changes to the hot `build_list` path.

**Tech Stack:** bash 3.2 (macOS-safe), tmux ≥ 3.2, fzf, jq (optional, with graceful degradation), no new dependencies.

**Scope note:** The working tree at plan-write time has unrelated modifications to `install-hooks.sh`, `hooks/inbox-hook.sh`, `lib/common.sh`, `scripts/inbox-next.sh`, `scripts/inbox-popup.sh`, `scripts/inbox-status.sh`, `README.md`, and a new `scripts/inbox-kill.sh`. These pre-existing diffs are unrelated to this feature and should be committed, stashed, or reverted **before** starting this plan, so each task's commit is clean. The plan assumes a clean working tree on `main`.

**Authorization gate:** The user's global rules require explicit per-commit authorization. Every `git commit` step in this plan is gated — when the step is reached, ask "OK to commit?" with the proposed message and wait for explicit approval before running.

---

## File Structure

| Path | Purpose | Status |
|---|---|---|
| `lib/common.sh` | Shared helpers. Adds `_last_user_prompt`. | Modify |
| `scripts/inbox-preview.sh` | NEW. Renders the preview for one pane id. Pure read; no state writes. | Create |
| `scripts/inbox-popup.sh` | Existing fzf launcher. Adds `--preview`, `--preview-window`, `?` toggle, `+refresh-preview` on `load`, updated `--footer`. | Modify |
| `scripts/inbox-open.sh` | Existing popup sizer. Adds preview-aware width floor and narrow-client fallback to `bottom:40%`. | Modify |
| `tmux-agents-inbox.tmux` | TPM entry point. Reads `@agents-inbox-preview` / `@agents-inbox-preview-position` and exports as env vars on the bind-key. | Modify |
| `README.md` | Documents the two new options, the `?` toggle, and updates the popup keys/footer/ASCII diagram. | Modify |

Each task below produces a self-contained commit. Tasks are ordered bottom-up: helper → preview script → popup wiring → opener sizing → entry point → docs → end-to-end verification.

---

## Task 1: Add `_last_user_prompt` helper to `lib/common.sh`

**Why this task:** The preview header needs the most recent user prompt (truncated). This is a pure-read helper that belongs next to the existing `_last_assistant_ends_with_question` (same tail-of-transcript pattern). Doing it first means later tasks can use it directly.

**Files:**
- Modify: `lib/common.sh` (add helper after `_last_assistant_ends_with_question`, around line 141)

- [ ] **Step 1: Pick a real transcript to test against**

Run:
```bash
ls -t ~/.claude/projects/*-tmux-agents-inbox/*.jsonl 2>/dev/null | head -1
```

Expected: at least one `.jsonl` path printed. Note the path — call it `$TP` for the rest of this task.

If no transcript exists for this repo, pick any other project's transcript:
```bash
ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1
```

- [ ] **Step 2: Write the failing manual test**

Run:
```bash
bash -c 'source ./lib/common.sh; _last_user_prompt "<TP>"'
```

(Replace `<TP>` with the transcript path from Step 1.)

Expected: error `bash: _last_user_prompt: command not found` — confirms the helper does not yet exist.

- [ ] **Step 3: Add the helper to `lib/common.sh`**

In `lib/common.sh`, add this function immediately **after** the existing `_last_assistant_ends_with_question` function (which ends around line 141). Use the exact same structure / jq-fallback discipline as that function — readers should see it as a sibling.

```bash
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
  # Truncate to 60 chars + ellipsis if longer.
  if [ "${#raw}" -gt 60 ]; then
    printf '%s…' "${raw:0:60}"
  else
    printf '%s' "$raw"
  fi
}
```

- [ ] **Step 4: Syntax-check the modified file**

Run:
```bash
bash -n ./lib/common.sh
```

Expected: no output (exit 0). If there's a syntax error, fix it before continuing.

- [ ] **Step 5: Re-run the manual test from Step 2 — must now succeed**

Run:
```bash
bash -c 'source ./lib/common.sh; _last_user_prompt "<TP>"'
```

Expected: a single line of plain text (the most recent user prompt from the transcript, possibly with trailing `…`). No errors. If the transcript happens to have no user messages, output is empty (exit 0) — pick a different transcript and retry.

- [ ] **Step 6: Verify the jq-absent fallback**

Run:
```bash
PATH=/usr/bin:/bin bash -c '
  # Pretend jq is missing by removing it from PATH (jq lives in /usr/bin on macOS; if
  # it actually is in /usr/bin on this machine, run the alternative below instead).
  command -v jq >/dev/null && { echo "jq still on PATH — try alt"; exit 1; }
  source ./lib/common.sh
  _last_user_prompt "<TP>"
  echo "exit=$?"
'
```

If jq is in `/usr/bin` (so the trim above doesn't actually hide it), use the alternative:

```bash
bash -c '
  jq() { command -v /no/such/jq; }   # shadow with a broken stub
  export -f jq
  source ./lib/common.sh
  command -v jq    # confirm shadow is in effect
'
```

Actually simpler: temporarily disable jq with a `PATH` override that excludes `/usr/bin`:

```bash
PATH=/bin:/usr/local/bin bash -c '
  command -v jq && { echo "jq still found, adjust PATH"; exit 1; }
  source ./lib/common.sh
  out="$(_last_user_prompt "<TP>")"
  echo "out=[$out] exit=$?"
'
```

Expected: `out=[] exit=0` — function silently returns nothing when jq is missing. No error message, no non-zero exit.

- [ ] **Step 7: Request commit authorization**

Propose to the user:
> Ready to commit Task 1. Proposed message:
> ```
> feat: add _last_user_prompt helper for preview header
> ```
> OK to commit `lib/common.sh`?

Wait for explicit "yes". Then run:

```bash
git add lib/common.sh
git commit -m "feat: add _last_user_prompt helper for preview header"
```

---

## Task 2: Create `scripts/inbox-preview.sh`

**Why this task:** The renderer is a self-contained script — building and testing it standalone (with an env-controlled `FZF_PREVIEW_LINES` substitute) means we can verify it works before wiring it into fzf, where debugging is harder.

**Files:**
- Create: `scripts/inbox-preview.sh`

- [ ] **Step 1: Pick a live pane id to test against**

Run:
```bash
bash -c '
  source ./lib/common.sh
  claude_panes | head -1
'
```

Expected: a pane id like `%18`. Note it as `$PID` for the rest of the task. If empty, start a `claude` session in any tmux pane first.

- [ ] **Step 2: Write the failing manual test**

Run:
```bash
bash ./scripts/inbox-preview.sh "<PID>"
```

Expected: `bash: ...: No such file or directory` — confirms the script does not yet exist.

- [ ] **Step 3: Create the script**

Create `scripts/inbox-preview.sh` with this exact content:

```bash
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

body="$(tmux capture-pane -p -e -t "$pid" -S -200 2>/dev/null | tail -n "$body_lines")"
if [ -z "$body" ]; then
  printf '(pane closed)\n'
else
  printf '%s\n' "$body"
fi
```

- [ ] **Step 4: Make it executable**

Run:
```bash
chmod +x ./scripts/inbox-preview.sh
```

Expected: no output. Verify:
```bash
ls -la ./scripts/inbox-preview.sh
```
Expected: leading `-rwxr-xr-x`.

- [ ] **Step 5: Syntax-check**

Run:
```bash
bash -n ./scripts/inbox-preview.sh
```

Expected: no output (exit 0).

- [ ] **Step 6: Smoke test against the live pane**

Run:
```bash
FZF_PREVIEW_LINES=30 FZF_PREVIEW_COLUMNS=80 \
  bash ./scripts/inbox-preview.sh "<PID>"
```

(Replace `<PID>` with the pane id from Step 1.)

Expected: 3+ lines of output:
1. `<project> · <sub> · "<title>"` (or `<project> · "<title>"` if `sub` is empty)
2. `<icon> <state> · <Ns> [· last prompt: "..."]`
3. A row of `─` characters (~80 of them)
4. Several lines of actual TUI content from the pane (the live tail).

If you see `(pane closed)` for the body, the pane id is wrong or stale — re-run Step 1.

- [ ] **Step 7: Smoke test for `__hdr__`**

Run:
```bash
bash ./scripts/inbox-preview.sh __hdr__
```

Expected: a single line `—` and exit 0.

- [ ] **Step 8: Smoke test for a bogus pane id**

Run:
```bash
bash ./scripts/inbox-preview.sh '%99999'
```

Expected: a single line `(pane closed)` and exit 0.

- [ ] **Step 9: Request commit authorization**

Propose to the user:
> Ready to commit Task 2. Proposed message:
> ```
> feat: add inbox-preview.sh — per-row preview renderer
> ```
> OK to commit `scripts/inbox-preview.sh`?

Wait for explicit "yes". Then:

```bash
git add scripts/inbox-preview.sh
git commit -m "feat: add inbox-preview.sh — per-row preview renderer"
```

---

## Task 3: Wire preview into `scripts/inbox-popup.sh`

**Why this task:** This is where the preview becomes user-visible inside the popup. It reads two env vars (`AGENTS_INBOX_PREVIEW`, `AGENTS_INBOX_PREVIEW_POS`) — populated in Task 5 by the `.tmux` entry point but settable manually for testing here.

**Files:**
- Modify: `scripts/inbox-popup.sh`

- [ ] **Step 1: Read current popup script**

Open `scripts/inbox-popup.sh`. Currently it sets `set -- --ansi --delimiter=$'\t' --with-nth='2..' ...` with `--footer='enter: jump   ctrl-x: kill   ctrl-s: regroup   esc: close'` and several `--bind` lines.

- [ ] **Step 2: Modify the script — replace lines 12 to 21 (the `set --` block) with the preview-aware version**

Replace this block (currently lines 12-21):

```bash
# Common fzf flags as positional params (bash 3.2 safe).
set -- --ansi --delimiter=$'\t' --with-nth='2..' --no-sort --layout=reverse \
  --prompt='agents> ' \
  --footer='enter: jump   ctrl-x: kill   ctrl-s: regroup   esc: close' \
  --bind="ctrl-s:execute-silent(bash '$DIR/scripts/_cycle-view.sh')+reload(bash '$DIR/scripts/_build.sh')" \
  --bind="ctrl-x:execute-silent(bash '$DIR/scripts/inbox-kill.sh' {1})+reload(bash '$DIR/scripts/_build.sh')" \
  --bind="load:reload(bash '$DIR/scripts/_build.sh'; sleep $interval)" \
  --bind='enter:transform:[ {1} = __hdr__ ] && echo ignore || echo accept' \
  --bind='down:down+transform:[ {1} = __hdr__ ] && echo down' \
  --bind='up:up+transform:[ {1} = __hdr__ ] && echo up'
```

with:

```bash
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
```

Changes:
- New `preview_pos` / `init_pos` block at the top (reads env vars).
- Updated `--footer` to include `?: preview`.
- New `--preview` and `--preview-window` flags.
- New `?` bind to cycle between hidden and the configured position.
- Added `+refresh-preview` to the existing `load` bind so the preview tail refreshes with the list.

- [ ] **Step 3: Syntax-check**

Run:
```bash
bash -n ./scripts/inbox-popup.sh
```

Expected: no output (exit 0).

- [ ] **Step 4: Manual test — preview off by default**

From any tmux pane:

```bash
AGENTS_INBOX_PREVIEW=off \
  bash ./scripts/inbox-popup.sh
```

Expected: the popup opens looking exactly like before — no preview pane visible. Footer reads `enter: jump   ctrl-x: kill   ?: preview   ctrl-s: regroup   esc: close`. Press `?` — preview pane appears on the right. Press `?` again — it disappears. Press Esc to close.

- [ ] **Step 5: Manual test — preview on by default**

```bash
AGENTS_INBOX_PREVIEW=on \
  bash ./scripts/inbox-popup.sh
```

Expected: popup opens with preview already visible on the right at 55%. Arrow up/down — preview content changes per row. On a group-header row, preview shows `—`. Press `?` — preview hides. Press `?` — preview returns.

- [ ] **Step 6: Manual test — alternate preview position**

```bash
AGENTS_INBOX_PREVIEW=on AGENTS_INBOX_PREVIEW_POS=bottom:40% \
  bash ./scripts/inbox-popup.sh
```

Expected: popup opens with preview at the bottom occupying ~40% of the popup height.

- [ ] **Step 7: Manual test — live refresh**

```bash
AGENTS_INBOX_PREVIEW=on \
  bash ./scripts/inbox-popup.sh
```

Navigate to a "working" row. In another tmux pane, type something in that claude session (or watch it produce output). Within ~1 s, the preview body should update to show the new tail. (If it doesn't update until you move the cursor, the `+refresh-preview` step failed — re-check Step 2.)

- [ ] **Step 8: Request commit authorization**

Propose:
> Ready to commit Task 3. Proposed message:
> ```
> feat: wire preview pane into inbox popup with ? toggle
> ```
> OK to commit `scripts/inbox-popup.sh`?

Wait for "yes", then:

```bash
git add scripts/inbox-popup.sh
git commit -m "feat: wire preview pane into inbox popup with ? toggle"
```

---

## Task 4: Update `scripts/inbox-open.sh` for preview-aware sizing

**Why this task:** The popup currently sizes width to fit the list content (`wcols+8`). With preview on, that's too narrow — the preview gets squeezed. We need to add a floor for preview width and fall back to bottom layout on narrow clients.

**Files:**
- Modify: `scripts/inbox-open.sh`

- [ ] **Step 1: Read current opener**

Open `scripts/inbox-open.sh`. Note the width computation around lines 41-50:

```bash
if [ -n "$fix_w_opt" ]; then
  w="$(_pct "$fix_w_opt" "$cw")"
else
  min_w_opt="$(tmux show -gqv '@agents-inbox-popup-min-width' 2>/dev/null)"
  [ -n "$min_w_opt" ] || min_w_opt='50%'
  min_w="$(_pct "$min_w_opt" "$cw")"
  [ "$min_w" -gt "$maxw" ] && min_w=$maxw
  w=$(( wcols + 8 ))           # pointer/gutter + scrollbar + borders + margin
  [ "$w" -lt "$min_w" ] && w=$min_w
fi
```

Final cap is at lines 52-54.

- [ ] **Step 2: Add preview-aware sizing**

After line 23 (`fix_w_opt="$(tmux show -gqv '@agents-inbox-popup-width'  2>/dev/null)"`), add a new block that reads the preview options and computes the preview-cell floor:

Find the line:
```bash
fix_h_opt="$(tmux show -gqv '@agents-inbox-popup-height' 2>/dev/null)"
```

**Immediately after** that line, insert:

```bash
# Preview options. Default off. When on, reserve cells for the preview pane.
preview_on="$(tmux show -gqv '@agents-inbox-preview' 2>/dev/null)"
preview_pos="$(tmux show -gqv '@agents-inbox-preview-position' 2>/dev/null)"
[ -n "$preview_pos" ] || preview_pos='right:55%'
PREVIEW_CELLS=60   # minimum cells the preview pane wants to look useful
```

- [ ] **Step 3: Modify the width-fit block to add the preview floor**

Find the width-fit block (the `else` branch that computes `w=$(( wcols + 8 ))`). Modify it so when preview is on AND the position starts with `right` or `left`, we add `PREVIEW_CELLS` to the content-fit width.

Replace this block:

```bash
if [ -n "$fix_w_opt" ]; then
  w="$(_pct "$fix_w_opt" "$cw")"
else
  min_w_opt="$(tmux show -gqv '@agents-inbox-popup-min-width' 2>/dev/null)"
  [ -n "$min_w_opt" ] || min_w_opt='50%'
  min_w="$(_pct "$min_w_opt" "$cw")"
  [ "$min_w" -gt "$maxw" ] && min_w=$maxw
  w=$(( wcols + 8 ))           # pointer/gutter + scrollbar + borders + margin
  [ "$w" -lt "$min_w" ] && w=$min_w
fi
```

with:

```bash
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
```

- [ ] **Step 4: Add narrow-client fallback right before the `tmux display-popup` call**

The current final cap is:

```bash
[ "$h" -gt "$maxh" ] && h=$maxh
[ "$w" -gt "$maxw" ] && w=$maxw

tmux display-popup -E -w "$w" -h "$h" "bash '$DIR/scripts/inbox-popup.sh' '$snap'"
```

Replace with:

```bash
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

AGENTS_INBOX_PREVIEW="$preview_on" \
AGENTS_INBOX_PREVIEW_POS="$effective_pos" \
  tmux display-popup -E -w "$w" -h "$h" -e "AGENTS_INBOX_PREVIEW=$preview_on" -e "AGENTS_INBOX_PREVIEW_POS=$effective_pos" "bash '$DIR/scripts/inbox-popup.sh' '$snap'"
```

The `-e KEY=VALUE` flags on `display-popup` forward environment variables into the popup's shell — `tmux display-popup` does **not** inherit the parent shell's environment by default. Both forms (the leading env assignment and the `-e` flags) are kept; the leading ones are harmless and self-document intent.

- [ ] **Step 5: Syntax-check**

Run:
```bash
bash -n ./scripts/inbox-open.sh
```

Expected: no output.

- [ ] **Step 6: Set tmux options manually and test**

Run:
```bash
tmux set -g @agents-inbox-preview on
tmux set -g @agents-inbox-preview-position 'right:55%'
bash ./scripts/inbox-open.sh
```

Expected: popup opens wider than before (enough to fit list + preview side by side); preview is visible on the right.

Then:
```bash
tmux set -g @agents-inbox-preview off
bash ./scripts/inbox-open.sh
```

Expected: popup opens at its previous narrower size, no preview visible.

- [ ] **Step 7: Test narrow-client fallback**

Resize the tmux client to ~70 cols (drag the terminal window narrow, or run `tmux split-window -h` a couple of times to shrink). Then:

```bash
tmux set -g @agents-inbox-preview on
bash ./scripts/inbox-open.sh
```

Expected: preview appears at the **bottom** (because list + 60-cell preview wouldn't fit on the right). Popup height is taller than usual.

Restore client width afterward.

- [ ] **Step 8: Reset the tmux options for a clean slate**

```bash
tmux set -gu @agents-inbox-preview
tmux set -gu @agents-inbox-preview-position
```

- [ ] **Step 9: Request commit authorization**

Propose:
> Ready to commit Task 4. Proposed message:
> ```
> feat: preview-aware popup sizing with narrow-client fallback
> ```
> OK to commit `scripts/inbox-open.sh`?

Wait for "yes", then:

```bash
git add scripts/inbox-open.sh
git commit -m "feat: preview-aware popup sizing with narrow-client fallback"
```

---

## Task 5: Expose options in `tmux-agents-inbox.tmux`

**Why this task:** Currently the user sets `@agents-inbox-preview` via tmux options, but `inbox-open.sh` (Task 4) already reads them via `tmux show -gqv`. So the entry point doesn't strictly *need* changes — but we should still verify, since the README will tell users they set these options the same way as the existing ones. This task is mostly a sanity check / doc-aligned no-op.

**Files:**
- Modify: `tmux-agents-inbox.tmux` (verify-only; likely no code change)

- [ ] **Step 1: Re-read the entry point**

Open `tmux-agents-inbox.tmux`. Note that it reads `@agents-inbox-popup-key`, `@agents-inbox-next-key`, `@agents-inbox-auto-status` via `get_opt`, and only `auto-status` actually has side effects at plugin-load time. The popup-open script (Task 4) reads its options at *popup-open* time, so they're picked up fresh on every keypress — no plugin reload needed.

- [ ] **Step 2: Confirm no entry-point change is needed**

Verify by reading `scripts/inbox-open.sh` (post-Task-4) — `tmux show -gqv '@agents-inbox-preview'` is called inside the script. So setting `tmux set -g @agents-inbox-preview on` and immediately pressing `prefix + I` works without re-sourcing the plugin.

Test (with the plugin loaded normally):

```bash
tmux set -g @agents-inbox-preview on
tmux set -g @agents-inbox-preview-position 'right:55%'
```

Then press `prefix + I` (or whatever `@agents-inbox-popup-key` is bound to). Expected: popup opens with preview on.

```bash
tmux set -g @agents-inbox-preview off
```

Then press `prefix + I` again. Expected: popup opens without preview.

If both work as expected, **no code change** to `tmux-agents-inbox.tmux` is required. Mark this task as no-op and move on. There is nothing to commit.

- [ ] **Step 3: Skip commit**

This task makes no file changes. No commit. Proceed to Task 6.

---

## Task 6: Update `README.md`

**Why this task:** Two new options, one new key, an updated footer string — users need to know they exist.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the two options to the options table**

Find the options table in `README.md` (currently around lines 103-112). Append two new rows after the last existing row (`@agents-inbox-auto-status`):

```markdown
| `@agents-inbox-preview` | `off` | Show a preview pane in the popup with the agent's live tmux output + transcript-derived header. Toggleable inside the popup with `?`. |
| `@agents-inbox-preview-position` | `right:55%` | Passed straight to fzf `--preview-window`. Accepts e.g. `right:50%`, `bottom:40%`, `left:60%`. |
```

- [ ] **Step 2: Document the `?` key**

Find the paragraph starting "In the popup: **Enter** jumps, **Ctrl-S** switches grouping..." (currently around line 118). Replace it with:

```markdown
In the popup: **Enter** jumps, **Ctrl-X** kills the agent in that pane, **?** toggles the preview pane, **Ctrl-S** switches grouping (state → session → flat), **Esc** closes. Type to fuzzy-filter. The list **auto-refreshes** every 2 s by default (`@agents-inbox-refresh-interval` to change). Group headers (the `── Needs input (N) ──` lines) are **non-selectable** — Enter on them is a no-op, and Up/Down skip past them.
```

(The original was missing `Ctrl-X` and `?` from the in-popup keys description; this fixes both.)

- [ ] **Step 3: Add a preview note to the layout section**

After the existing paragraph about popup sizing (around line 128-130, "The popup is **sized to fit its content**..."), insert a new paragraph:

```markdown
With `@agents-inbox-preview` set to `on`, the popup reserves additional width (or, on narrow clients, additional height at the bottom) for a preview pane. The preview shows for the currently-highlighted row: a header with project / subfolder / `ai-title` and the row's state / age / most-recent user prompt, then a live tail of the agent's tmux pane. Press `?` inside the popup to toggle the preview on or off for that session.
```

- [ ] **Step 4: Syntax-sanity (no script to lint — just inspect)**

Run:
```bash
head -135 ./README.md | tail -50
```

Expected: the options table now contains the two new rows; the in-popup keys paragraph mentions `?` and `Ctrl-X`; the preview-pane paragraph follows the sizing paragraph.

- [ ] **Step 5: Request commit authorization**

Propose:
> Ready to commit Task 6. Proposed message:
> ```
> docs: document preview pane options and ? toggle
> ```
> OK to commit `README.md`?

Wait for "yes", then:

```bash
git add README.md
git commit -m "docs: document preview pane options and ? toggle"
```

---

## Task 7: End-to-end verification (no code change)

**Why this task:** Walk through every scenario in the spec's verification plan, in order, and document the results. Catches any integration issue that the per-task smoke tests missed.

**Files:** none modified.

- [ ] **Step 1: Default-off path**

```bash
tmux set -gu @agents-inbox-preview
tmux set -gu @agents-inbox-preview-position
```

Press `prefix + I`. Expected: popup looks exactly like before (no preview visible). Press `?` — preview appears on the right at 55%. Press `?` again — preview hides. Press Esc.

- [ ] **Step 2: Default-on path**

```bash
tmux set -g @agents-inbox-preview on
```

Press `prefix + I`. Expected: popup opens with preview visible on the right. Cycle up/down through every row, confirming:
- A `waiting` row → header shows `✻ Needs input · Ns · last prompt: "..."`. Body shows the pane's TUI (likely the question text).
- A `done` row → header shows `✻ Completed`. Body shows the post-Stop pane.
- A `working` row → header shows `✽ Working`. Body shows live in-progress output.
- A group-header row (the `── ... ──` lines) → preview shows a single `—`.
- An `idle` row (if present) → header shows dimmed `✻ Idle`.

- [ ] **Step 3: Live refresh of working row**

While paused on a `working` row, watch the preview body for ~5 seconds. Expected: body updates as the agent emits new lines (because `+refresh-preview` fires with the 1 s `load` reload).

- [ ] **Step 4: Narrow-client fallback**

Shrink the tmux client (e.g. via terminal window resize) to < 80 cols. Press `prefix + I`. Expected: preview appears at the bottom, not on the right. Restore client width.

- [ ] **Step 5: Custom position**

```bash
tmux set -g @agents-inbox-preview-position 'bottom:50%'
```

Press `prefix + I`. Expected: preview at the bottom, 50% of popup height. Reset:

```bash
tmux set -gu @agents-inbox-preview-position
```

- [ ] **Step 6: jq-absent fallback**

Temporarily hide jq:
```bash
sudo mv /usr/bin/jq /usr/bin/jq.bak
```

(Or use a PATH override; on macOS jq is typically in `/opt/homebrew/bin` — adjust accordingly.)

Press `prefix + I`. Expected: header line 2 still appears but without the `· last prompt: "..."` suffix. No errors in the preview body.

Restore:
```bash
sudo mv /usr/bin/jq.bak /usr/bin/jq
```

- [ ] **Step 7: Pane-closed mid-popup**

With preview on and a row highlighted, in another tmux pane: kill the corresponding claude process (`ctrl-c` twice in the claude TUI, or `tmux kill-pane -t <id>`). Watch the popup. Expected: preview body shows `(pane closed)` until the next `load` reload, after which the row vanishes entirely.

- [ ] **Step 8: `prefix + N` unaffected**

Press `prefix + N` (or whatever `@agents-inbox-next-key` is bound to). Expected: jumps to the next waiting agent exactly as before. No popup, no preview involvement.

- [ ] **Step 9: Reset state**

```bash
tmux set -gu @agents-inbox-preview
tmux set -gu @agents-inbox-preview-position
```

- [ ] **Step 10: Report results to user**

Tell the user which steps passed and which failed. If any failed, do NOT mark the plan complete — fix the issue and re-run from the failing step. If all passed, the plan is done. No final commit (nothing changed).

---

## Self-review summary

**Spec coverage** — every section of `2026-05-28-inbox-preview-design.md` is implemented:
- UX layout (right:55% default, bottom fallback) → Task 4
- Default state (`off`) → Task 3 (init_pos handling) + Task 6 (docs)
- Toggle (`?`) → Task 3
- Tmux options → Task 4 (read) + Task 6 (docs); Task 5 confirms entry point needs no change
- Data sources (header lines + body) → Task 1 (`_last_user_prompt`) + Task 2 (renderer)
- Refresh model (`+refresh-preview` on `load`) → Task 3
- Files touched table → covered by Tasks 1–4, 6 (Task 5 is intentionally a no-op)
- All 5 risks → mitigated in Tasks 2 (stale pane id, jq fallback, header-row), 4 (narrow-client), with ANSI bleed observable in Task 7

**No placeholders** — every step has either exact code, an exact command, or an exact expected output.

**Type/name consistency** — `_last_user_prompt`, `inbox-preview.sh`, `AGENTS_INBOX_PREVIEW`, `AGENTS_INBOX_PREVIEW_POS`, `PREVIEW_CELLS`, `@agents-inbox-preview`, `@agents-inbox-preview-position` — all referenced identically across tasks.

**Commit gate** — every commit step explicitly asks for authorization per the user's global rules.
