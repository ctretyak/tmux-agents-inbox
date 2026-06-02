# Configurable Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users set popup columns (order, visibility, and which of ten catalog fields appear) via one tmux option `@agents-inbox-columns`, with the unset default reproducing today's output byte-for-byte.

**Architecture:** A small shell resolver validates a space-separated column list against a single-source catalog predicate; `build_list` emits one row field per configured column (with `\t\r\n` sanitization); a generalized awk renderer auto-sizes every column and renders them, keeping the ANSI-bearing `icon` as a raw prefix **outside** the idle dim-wrap so its embedded reset can't cancel the dim.

**Tech Stack:** Pure bash 3.2 + BWK/POSIX awk, tmux global options, fzf. No new dependencies. TDD via the repo's `tests/run.sh` harness (`assert_eq` / `assert_rc` / `strip_ansi`).

**Design spec:** `docs/superpowers/specs/2026-06-02-configurable-columns-design.md` (rev. 2).

**Catalog (10 names):** `icon project subfolder description age session window window-index pane path`. Default: `icon project subfolder description age`.

**Conventions to know before starting:**
- Tests live in `tests/test_*.sh`; `tests/run.sh` sources `tests/_assert.sh` + each file in its own subshell. Each test file sources `lib/common.sh` itself via `. "$TAI_ROOT/lib/common.sh"`.
- Run the whole suite with `bash tests/run.sh` (exit 0 = all green). There is no single-test runner; run the whole file's subshell or the whole suite.
- `assert_eq <expected> <actual> <msg>` and `assert_rc <expected_rc> <actual_rc> <msg>` append PASS/FAIL to `$TAI_RESULTS`. A "failing test" here means the run prints a `FAIL` line for that assertion; "passing" means no FAIL line for it.
- `tmux` is shimmed per-test-file via a `case "$*"` script on `PATH`. `tmux show -gqv '@agents-inbox-columns'` arrives at the shim as `"$*" == "show -gqv @agents-inbox-columns"` (the shell strips the quotes).
- This machine's awk is BWK awk 20200816; `printf "%-*s"` (dynamic width), `split(s, a, " ")` (whitespace-collapsing), and `a[i,j]` (SUBSEP multidim) are all confirmed working.
- **Git:** commit steps are included per TDD discipline. The repo owner requires explicit per-commit approval — obtain it at execution time before each `git commit`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/common.sh` | Column resolver helpers + `build_list` emission & awk renderer | Modify |
| `tests/test_columns.sh` | Unit tests for the resolver helpers + multibyte-limitation pin | Create |
| `tests/test_build_list.sh` | Integration: reorder / omit / new-field / empty-default / unknown-warning rendering | Modify |
| `tests/test_dim_wrap.sh` | Regression guard: idle dim brackets the body, not the icon (raw ANSI) | Create |
| `README.md` | Document `@agents-inbox-columns`, the catalog, examples | Modify |

---

## Task 1: Column resolver helpers

Adds three pure-ish shell helpers to `lib/common.sh`: `_is_column` (single-source catalog predicate), `_columns_config` (ordered, validated list with default fallback), `_columns_unknown` (the dropped tokens, for the warning header).

**Files:**
- Create: `tests/test_columns.sh`
- Modify: `lib/common.sh` (insert after `_hooks_detected`, which ends at line 301, before the `# Build the inbox rows for fzf.` comment at line 303)

- [ ] **Step 1: Write the failing test**

Create `tests/test_columns.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for the column-config resolver helpers. tmux is shimmed so
# `tmux show -gqv '@agents-inbox-columns'` returns $TAI_COLUMNS.
. "$TAI_ROOT/lib/common.sh"

_shimdir="$(mktemp -d)"; trap 'rm -rf "$_shimdir"' EXIT
cat > "$_shimdir/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'show -gqv @agents-inbox-columns'*) printf '%s\n' "${TAI_COLUMNS:-}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_shimdir/tmux"
PATH="$_shimdir:$PATH"; export PATH TAI_COLUMNS

DEF="icon project subfolder description age"

# _is_column: catalog membership
_is_column window-index; assert_rc 0 "$?" "_is_column: window-index is valid"
_is_column path;         assert_rc 0 "$?" "_is_column: path is valid"
_is_column windows;      assert_rc 1 "$?" "_is_column: 'windows' is rejected"

# _columns_config: passthrough, reorder, drop-unknown, default fallbacks
TAI_COLUMNS="icon project age"
assert_eq "icon project age" "$(_columns_config)" "_columns_config: valid passthrough"
TAI_COLUMNS="age icon"
assert_eq "age icon" "$(_columns_config)" "_columns_config: reorder preserved"
TAI_COLUMNS="icon bogus project"
assert_eq "icon project" "$(_columns_config)" "_columns_config: drops unknown token"
TAI_COLUMNS=""
assert_eq "$DEF" "$(_columns_config)" "_columns_config: empty -> default"
TAI_COLUMNS="   "
assert_eq "$DEF" "$(_columns_config)" "_columns_config: blank -> default"
TAI_COLUMNS="bogus nope"
assert_eq "$DEF" "$(_columns_config)" "_columns_config: all-unknown -> default"

# _columns_unknown: only the rejected tokens
TAI_COLUMNS="icon bogus project nope"
assert_eq "bogus nope" "$(_columns_unknown)" "_columns_unknown: lists rejected tokens"
TAI_COLUMNS="icon project"
assert_eq "" "$(_columns_unknown)" "_columns_unknown: empty when all valid"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 'test_columns'`
Expected: FAIL lines (the helpers `_is_column` / `_columns_config` / `_columns_unknown` don't exist yet, so the subshell errors or assertions mismatch).

- [ ] **Step 3: Write minimal implementation**

In `lib/common.sh`, insert after `_hooks_detected` (line 301) and before `# Build the inbox rows for fzf.` (line 303):

```bash
# --- column configuration -----------------------------------------------------
# Single source of truth for valid column names (the catalog).
_is_column() {
  case "$1" in
    icon|project|subfolder|description|age|session|window|window-index|pane|path) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve the ordered, validated column list from @agents-inbox-columns.
# Unknown tokens are dropped (surfaced separately by _columns_unknown); an
# empty or all-unknown list falls back to the default so the popup is never blank.
_columns_config() {
  local def="icon project subfolder description age" raw out="" tok
  raw="$(tmux show -gqv '@agents-inbox-columns' 2>/dev/null)"
  [ -n "$raw" ] || raw="$def"
  for tok in $raw; do
    _is_column "$tok" && out="$out $tok"
  done
  out="${out# }"
  [ -n "$out" ] || out="$def"
  printf '%s' "$out"
}

# Echo any configured tokens that are NOT valid column names (for the warning header).
_columns_unknown() {
  local raw out="" tok
  raw="$(tmux show -gqv '@agents-inbox-columns' 2>/dev/null)"
  for tok in $raw; do
    _is_column "$tok" || out="$out $tok"
  done
  printf '%s' "${out# }"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep 'test_columns'`
Expected: the `== test_columns.sh ==` banner appears and the final `N passed, 0 failed` count includes the new assertions with no FAIL lines for them.

- [ ] **Step 5: Commit** (get explicit approval first)

```bash
git add lib/common.sh tests/test_columns.sh
git commit -m "feat: add column-config resolver helpers"
```

---

## Task 2: Per-column emission + generalized awk renderer

Wires the resolver into `build_list`: emit one row field per configured column (sanitized), and replace the fixed 3-column awk formatter with an N-column renderer that keeps `icon` a raw prefix outside the dim-wrap. The existing golden assertions in `test_build_list.sh` are the regression guard for the default; the new reorder/omit/new-field/empty assertions drive the feature.

**Files:**
- Modify: `lib/common.sh` (`build_list`: locals line 308-309; resolve `cols` after line 313; emission block lines 371-373; awk pipeline lines 374-399)
- Modify: `tests/test_build_list.sh` (extend the tmux shim case; append new assertions)

- [ ] **Step 1: Write the failing tests**

In `tests/test_build_list.sh`, first extend the tmux shim. Find this block (lines 14-22):

```bash
cat > "$ws/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_pid} #{pane_id}'*)     cat "$TAI_FIX/panes_pidmap" ;;
  *'#{pane_id}|#{session_name}'*) cat "$TAI_FIX/panes_meta" ;;
  *'list-panes -a -F x'*)         printf 'x\n' ;;
  *) exit 0 ;;
esac
SH
```

Add the `@agents-inbox-columns` branch (before the `*)` default):

```bash
cat > "$ws/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_pid} #{pane_id}'*)     cat "$TAI_FIX/panes_pidmap" ;;
  *'#{pane_id}|#{session_name}'*) cat "$TAI_FIX/panes_meta" ;;
  *'list-panes -a -F x'*)         printf 'x\n' ;;
  *'show -gqv @agents-inbox-columns'*) printf '%s\n' "${TAI_COLUMNS:-}" ;;
  *) exit 0 ;;
esac
SH
```

Then append at the END of `tests/test_build_list.sh` (after the existing final assertion at line 63):

```bash
# --- configurable columns (Task 2) -------------------------------------------
# TAI_COLUMNS must be EXPORTED so the tmux shim subprocess sees it.
export TAI_COLUMNS

# Reorder: 'age description project' -> age before title before project, no icon glyph.
TAI_COLUMNS="age description project"
oc="$(build_list | strip_ansi)"
printf '%s\n' "$oc" | grep -qE '5s.*my task.*proj'
assert_rc 0 "$?" "columns reorder: age<description<project order"
printf '%s\n' "$oc" | grep '^%5' | grep -q '[✻✢✽]'
assert_rc 1 "$?" "columns reorder: status icon omitted from row"

# Omit: 'icon description' -> project column gone, description stays.
TAI_COLUMNS="icon description"
oc="$(build_list | strip_ansi)"
printf '%s\n' "$oc" | grep '^%5' | grep -q 'proj'
assert_rc 1 "$?" "columns omit: project column absent"
printf '%s\n' "$oc" | grep -q 'my task'
assert_rc 0 "$?" "columns omit: description still rendered"

# New field: 'icon session description' -> shows the tmux session name.
TAI_COLUMNS="icon session description"
oc="$(build_list | strip_ansi)"
printf '%s\n' "$oc" | grep -q 'sess1'
assert_rc 0 "$?" "columns new-field: session name rendered"

# Empty option -> identical to the default render.
TAI_COLUMNS=""
oc_empty="$(build_list | strip_ansi)"
unset TAI_COLUMNS
oc_def="$(build_list | strip_ansi)"
assert_eq "$oc_def" "$oc_empty" "columns empty option -> default render"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh 2>&1 | grep -E 'columns (reorder|omit|new-field|empty)'`
Expected: FAIL lines for the reorder/omit/new-field assertions (build_list ignores `@agents-inbox-columns` today, so it always renders the default order). The "empty -> default" case may already pass (default both ways); that's fine.

- [ ] **Step 3a: Resolve `cols` and widen locals**

In `lib/common.sh` `build_list`, change the locals declaration (lines 308-309) from:

```bash
  local mode now live meta liveset
  local id sf hstatus hupdated cur_tx tx_mtime status updated rank icon label desc vis gkey wkey
```

to:

```bash
  local mode now live meta liveset cols tok v row
  local id sf hstatus hupdated cur_tx tx_mtime status updated rank icon label desc vis gkey wkey
```

Then add the resolve call right after `now="$(date +%s)"` (line 313):

```bash
  now="$(date +%s)"
  cols="$(_columns_config)"
```

- [ ] **Step 3b: Replace the emission block**

Replace lines 371-373:

```bash
    # raw fields: gkey  wkey  pane_id  dim  icon  project  subfolder  message  time  label
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$gkey" "$wkey" "$pid" "$dim" "$icon" "$proj" "$sub" "$desc" "$agostr" "$label"
```

with:

```bash
    # raw fields: gkey  wkey  pane_id  dim  label  then one field per configured column
    row="$gkey"$'\t'"$wkey"$'\t'"$pid"$'\t'"$dim"$'\t'"$label"
    for tok in $cols; do
      case "$tok" in
        icon)         v="$icon" ;;
        project)      v="$proj" ;;
        subfolder)    v="$sub" ;;
        description)  v="$desc" ;;
        age)          v="$agostr" ;;
        session)      v="$sess" ;;
        window)       v="$wname" ;;
        window-index) v="$win" ;;
        pane)         v="$pid" ;;
        path)         v="$cwd" ;;
      esac
      v="$(printf '%s' "$v" | tr '\t\r\n' '   ')"
      row="$row"$'\t'"$v"
    done
    printf '%s\n' "$row"
```

- [ ] **Step 3c: Replace the awk renderer**

Replace the whole pipeline tail, lines 374-399:

```bash
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
```

with:

```bash
  done | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 \
       | awk -F'\t' -v mode="$mode" -v cw="$C_HDR" -v cr="$C_RESET" -v hr="──" -v dimc="$C_IDLE" -v cols="$cols" '
      BEGIN { ncol = split(cols, cn, " ") }
      {
        gk[NR]=$1; pid[NR]=$3; dim[NR]=$4; lblf[NR]=$5; cnt[$1]++
        # column values live in $6..$(5+ncol); size every non-icon column to its widest
        for (c=1; c<=ncol; c++) {
          val[NR,c] = $(5+c)
          if (cn[c]!="icon" && length($(5+c)) > w[c]) w[c] = length($(5+c))
        }
      }
      END {
        have=0
        for (i=1;i<=NR;i++) {
          if (mode!="flat" && (have==0 || gk[i]!=prev)) {
            # state mode groups by rank; the row carries the canonical label from
            # _status_presentation. session mode groups by session name (gk).
            lbl = (mode=="state" ? lblf[i] : gk[i])
            printf "__hdr__\t%s%s %s (%d) %s%s\n", cw, hr, lbl, cnt[gk[i]], hr, cr
            prev=gk[i]; have=1
          }
          # Render columns in order. icon is emitted RAW (its 1-glyph visible width
          # needs no padding) and OUTSIDE any dim span (its embedded C_RESET would
          # otherwise cancel the dim for the rest of the row). Each maximal run of
          # non-icon columns is dim-wrapped as one span on idle rows.
          out=""; indim=0
          for (c=1; c<=ncol; c++) {
            sep = (c==1 ? "" : "  ")
            if (cn[c]=="icon") {
              if (indim) { out=out cr; indim=0 }     # close dim before the icon
              out = out sep val[i,c]
            } else {
              cell = (c==ncol ? val[i,c] : sprintf("%-*s", w[c], val[i,c]))
              if (dim[i]=="1" && !indim) { out = out sep dimc cell; indim=1 }
              else                       { out = out sep cell }
            }
          }
          if (indim) out=out cr                       # close trailing dim span
          printf "%s\t%s\n", pid[i], out
        }
      }'
```

Also update the `# raw fields:` comment text was already replaced in Step 3b.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh 2>&1 | tail -5`
Expected: `... passed, 0 failed`. Specifically the original `test_build_list.sh` golden assertions ("Working header present", "project column rendered", "ai-title as description", "exactly one pane row", "state header label sourced from _status_presentation") stay green AND the four new `columns …` assertions pass.

- [ ] **Step 5: Commit** (get explicit approval first)

```bash
git add lib/common.sh tests/test_build_list.sh
git commit -m "feat: render popup columns from @agents-inbox-columns"
```

---

## Task 3: Unknown-token warning header

When the option contains an invalid name, render a non-selectable `⚠` header listing the dropped tokens — reusing the exact pattern the hooks-notice already uses — instead of letting the column silently vanish.

**Files:**
- Modify: `lib/common.sh` (`build_list`: add `unknown` local; emit header after the hooks-notice at lines 328-329)
- Modify: `tests/test_build_list.sh` (append one assertion)

- [ ] **Step 1: Write the failing test**

Append at the END of `tests/test_build_list.sh`:

```bash
# Unknown token -> warning header, valid columns still render (Task 3).
export TAI_COLUMNS="icon bogus project"
oc="$(build_list | strip_ansi)"
printf '%s\n' "$oc" | grep -q 'unknown column(s): bogus'
assert_rc 0 "$?" "columns unknown: warning header lists bad token"
printf '%s\n' "$oc" | grep '^%5' | grep -q 'proj'
assert_rc 0 "$?" "columns unknown: valid columns still render"
unset TAI_COLUMNS
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep 'columns unknown'`
Expected: FAIL for "warning header lists bad token" (no warning is emitted yet; `bogus` is silently dropped by Task 1's resolver).

- [ ] **Step 3: Write minimal implementation**

In `lib/common.sh` `build_list`, add `unknown` to the locals line (the one edited in Task 2):

```bash
  local mode now live meta liveset cols tok v row unknown
```

Then, immediately after the hooks-notice block (lines 328-329, which ends with the `... install-hooks.sh%s\n' ... "$C_RESET"` printf), add:

```bash
  unknown="$(_columns_unknown)"
  [ -z "$unknown" ] || printf '__hdr__\t%s⚠ unknown column(s): %s%s\n' "$C_WAIT" "$unknown" "$C_RESET"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -E 'columns unknown|passed,'`
Expected: both "columns unknown" assertions pass; overall `... passed, 0 failed`.

- [ ] **Step 5: Commit** (get explicit approval first)

```bash
git add lib/common.sh tests/test_build_list.sh
git commit -m "feat: warn on unknown column names in the popup"
```

---

## Task 4: Idle dim-wrap regression guard

A dedicated raw-ANSI test proving the idle dim span brackets the body and **excludes** the icon — the regression the rev-1 renderer introduced and that `strip_ansi` golden tests cannot detect.

**Files:**
- Create: `tests/test_dim_wrap.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_dim_wrap.sh`:

```bash
#!/usr/bin/env bash
# Regression guard: on an idle (dimmed) row the dim ANSI span must wrap the BODY
# only, NOT the status icon. The idle icon carries its own C_IDLE + C_RESET; if it
# is folded inside the dim span, its embedded reset cancels the dim for the rest of
# the row. strip_ansi cannot see this, so we assert on the RAW (un-stripped) output.
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT

mkdir -p "$ws/bin"
cat > "$ws/bin/date" <<'SH'
#!/usr/bin/env bash
case "$1" in +%s) printf '%s\n' "${TAI_NOW:?}";; *) exec /bin/date "$@";; esac
SH
cat > "$ws/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_pid} #{pane_id}'*)     cat "$TAI_FIX/panes_pidmap" ;;
  *'#{pane_id}|#{session_name}'*) cat "$TAI_FIX/panes_meta" ;;
  *'list-panes -a -F x'*)         printf 'x\n' ;;
  *'show -gqv @agents-inbox-columns'*) printf '%s\n' "${TAI_COLUMNS:-}" ;;
  *) exit 0 ;;
esac
SH
cp "$TAI_ROOT/tests/_shims/ps" "$ws/bin/ps"
chmod +x "$ws/bin/"*
export TAI_FIX="$ws" TAI_NOW=1000000000
PATH="$ws/bin:$PATH"; export PATH

export XDG_CACHE_HOME="$ws/cache"; export HOME="$ws/home"
export CACHE="$ws/cache/tmux-agents-inbox"
mkdir -p "$CACHE" "$ws/home"

# One idle pane %5 (shell pid 500, claude pid 510), cwd /proj.
printf '500 %%5\n' > "$ws/panes_pidmap"
printf '%%5|sess1|0|win1|0|%s\n' "$ws/proj" > "$ws/panes_meta"
printf '500 1 -bash\n510 500 /usr/local/bin/claude\n' > "$ws/ps_snap"
mkdir -p "$ws/proj/.git"

slug="$(printf '%s' "$ws/proj" | sed 's/[/.]/-/g')"
mkdir -p "$HOME/.claude/projects/$slug"
TX="$HOME/.claude/projects/$slug/sess.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"my task"}' > "$TX"
set_mtime $((TAI_NOW - 100)) "$TX"

# State file: idle, updated 100s ago -> _status_for trusts the hook -> idle -> dim=1.
printf 'idle %s idle %s\n' $((TAI_NOW - 100)) "$TX" > "$CACHE/pane-5"
printf 'state' > "$CACHE/.view-mode"

raw="$(build_list)"   # NOTE: NOT stripped — we assert on the escape sequences.

# Sanity: the row is idle/dimmed at all (body carries the C_IDLE span).
printf '%s' "$raw" | grep -qF $'\033[90m'
assert_rc 0 "$?" "dim-wrap: idle row carries a C_IDLE span"

# The dim span opens AFTER the icon: icon's own reset, two-space gap, then dim open.
printf '%s' "$raw" | grep -qF $'\033[0m  \033[90m'
assert_rc 0 "$?" "dim-wrap: dim span opens after the icon (body only)"

# Regression: the dim color must NOT immediately precede the icon glyph.
printf '%s' "$raw" | grep -qF $'\033[90m\033[90m✻'
assert_rc 1 "$?" "dim-wrap: icon is NOT inside the dim span"
```

- [ ] **Step 2: Run test to verify it passes**

Because Task 2 already implemented the correct (icon-outside-dim) renderer, this guard should pass immediately. Run:

Run: `bash tests/run.sh 2>&1 | grep 'dim-wrap'`
Expected: three PASS, zero FAIL. If "icon is NOT inside the dim span" FAILS, the renderer folded the icon into the dim span — re-check Task 2 Step 3c (the `if (cn[c]=="icon") { if (indim) {out=out cr; indim=0} ... }` branch).

> This task's test passing on first run is intentional — it is a guard locking in Task 2's behavior. If you are doing strict red-green and want to see it fail first, temporarily change the renderer to wrap the icon (`out = out sep dimc cell` for the icon branch), watch the third assertion FAIL, then revert.

- [ ] **Step 3: Commit** (get explicit approval first)

```bash
git add tests/test_dim_wrap.sh
git commit -m "test: guard idle dim-wrap excludes the status icon"
```

---

## Task 5: Pin the multibyte width limitation

A small executable-documentation test recording that awk `length()` is byte-based (the known, accepted alignment limitation). If a future change makes it display-width-aware, this test fails and forces a conscious decision.

**Files:**
- Modify: `tests/test_columns.sh` (append)

- [ ] **Step 1: Write the test**

Append at the END of `tests/test_columns.sh`:

```bash
# KNOWN LIMITATION (pinned, not a bug to silently "fix"): the awk renderer sizes
# columns with length(), which counts BYTES, not display columns. A 2-byte UTF-8
# character therefore reports width 2 and a wide column (path/session/project with
# non-ASCII) can misalign. Fixing it needs wcwidth, a dependency the project rejects.
# If this assertion ever fails, alignment behavior changed — decide deliberately.
bytelen="$(printf 'ä' | awk '{ print length($0) }')"
assert_eq "2" "$bytelen" "known-limitation: awk length() is byte-based (UTF-8 ä = 2)"
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep 'known-limitation'`
Expected: PASS (BWK awk reports byte length 2 for `ä`).

- [ ] **Step 3: Commit** (get explicit approval first)

```bash
git add tests/test_columns.sh
git commit -m "test: pin byte-based awk length() as a known limitation"
```

---

## Task 6: Document `@agents-inbox-columns` in the README

**Files:**
- Modify: `README.md` (options table at line 116; the "Each row shows" paragraph at lines 126-128)

- [ ] **Step 1: Add the option to the settings table**

In `README.md`, after the `@agents-inbox-preview-position` row (line 116), add:

```markdown
| `@agents-inbox-columns` | `icon project subfolder description age` | Ordered, space-separated list of popup columns. List order is column order; omit a name to hide that column; unknown names are ignored (a `⚠` header lists them). Catalog: `icon` (status symbol), `project`, `subfolder`, `description` (ai-title), `age` (relative), `session`, `window` (name), `window-index`, `pane` (`%id`), `path` (cwd — **unbounded width**, no truncation). |
```

- [ ] **Step 2: Add a worked example below the table**

After the TPM "Heads-up" blockquote (ends line 120) and before the "In the popup:" paragraph (line 122), add:

```markdown
**Columns example.** Show the session name and drop the subfolder:

```tmux
set -g @agents-inbox-columns 'icon session description age'
```

Leave the option unset to keep the default layout. `path` is available but unbounded —
a long working directory will widen the popup.
```

- [ ] **Step 3: Update the "Each row shows" sentence**

In `README.md`, the sentence at lines 126-128 currently reads:

```markdown
most-urgent first, newest-first within each group. (**Background** is a finished turn with a still-running
`background_tasks` entry — monitors, watches, long-running shells.) Each row shows: a colored status icon, project,
subfolder (the worktree name or path within the repo, blank at the repo root), the session's
`ai-title` description, and how long ago the session was last active.
```

Change the last sentence to note configurability:

```markdown
most-urgent first, newest-first within each group. (**Background** is a finished turn with a still-running
`background_tasks` entry — monitors, watches, long-running shells.) By default each row shows: a colored status icon,
project, subfolder (the worktree name or path within the repo, blank at the repo root), the session's
`ai-title` description, and how long ago the session was last active — configurable via `@agents-inbox-columns`.
```

- [ ] **Step 4: Verify the docs render and match reality**

Run: `grep -n 'agents-inbox-columns' README.md`
Expected: at least the table row + the example `set -g` line + the "configurable via" mention. Confirm the default string in the README exactly equals `_columns_config`'s `def` (`icon project subfolder description age`).

- [ ] **Step 5: Commit** (get explicit approval first)

```bash
git add README.md
git commit -m "docs: document @agents-inbox-columns option"
```

---

## Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the whole suite**

Run: `bash tests/run.sh`
Expected: final line `N passed, 0 failed`; the `--- failures ---` section prints `(none)`.

- [ ] **Step 2: Lint**

Run: `bash tests/lint.sh`
Expected: either `shellcheck not installed — skipping lint` (acceptable) or clean shellcheck output with no warnings on `lib/common.sh`. If shellcheck flags `_columns_config`/`_columns_unknown` locals as unused (SC2034) or word-splitting (SC2086) on `for tok in $raw`/`for tok in $cols`, confirm the word-splitting is intentional — add `# shellcheck disable=SC2086` on those `for` lines only if shellcheck is present and complains.

- [ ] **Step 3: Manual smoke test (live tmux)**

In a tmux session with at least one Claude pane:

```bash
tmux set -g @agents-inbox-columns 'icon session description age'   # reordered/new field
# open the popup (prefix + I) — verify the columns
tmux set -g @agents-inbox-columns 'icon project foo'              # unknown token
# open the popup — verify the ⚠ unknown column(s): foo header
tmux set -gu @agents-inbox-columns                                # back to default
# open the popup — verify default layout AND idle rows are dimmed (icon + greyed body)
```

Expected: reorder/new-field render correctly; the `⚠` header appears for `foo`; the default is visually unchanged with idle rows properly dimmed.

- [ ] **Step 4: Final spec-coverage check**

Confirm each spec section maps to a task: resolver+catalog (Task 1), emission+renderer+default-equivalence (Task 2), unknown-token warning (Task 3), dim-wrap (Task 4), multibyte limitation (Task 5), docs (Task 6). No commit.

---

## Self-Review notes (author)

- **Spec coverage:** every §1-§4 item, Files, Test plan case (1 reorder, 2 omit, 3 unknown-warning, 4 empty-default, 5 new-field, 6 dim-bracket, 7 multibyte-skip) maps to a task above. Test-plan case 6 (dim) → Task 4; case 7 (multibyte) → Task 5.
- **Type/name consistency:** helper names `_is_column` / `_columns_config` / `_columns_unknown`, env var `TAI_COLUMNS`, option `@agents-inbox-columns`, and awk locals (`cn`, `ncol`, `val`, `w`, `indim`, `out`) are used identically across tasks.
- **No placeholders:** every code step shows full code; every run step shows the command and expected result.
