# Maintainability Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure-bash test harness, lint, and CI that pin the current behavior of `tmux-agents-inbox`, then remove the duplicated status→presentation and prune logic without regressing.

**Architecture:** Tests first (pin behavior), then refactor under green tests. A dependency-free assert harness runs each `tests/test_*.sh` in its own subshell; assertion results are accumulated in a temp file so counts survive the subshell boundary. External commands (`tmux`, `ps`, `date`) are mocked via `$PATH` shims; transcripts/state are mocked in a `mktemp -d` workspace with `$HOME`/`$CACHE` redirected. Then `_status_presentation` (tab-echo return) and `_prune_state` (newline, exact-line-anchored) are extracted and consumers rewired.

**Tech Stack:** Bash 3.2 (macOS `/bin/bash` is 3.2.57), `jq` 1.7.1 (optional at runtime), `shellcheck` (dev/CI only — NOT installed locally), GitHub Actions.

**Reference spec:** `docs/superpowers/specs/2026-05-29-maintainability-pass-design.md`

---

## File Structure

**New files**
- `tests/_assert.sh` — assertion + portable-mtime helpers, sourced into each test subshell.
- `tests/run.sh` — runner: subshell-per-file, temp-file result accumulation, summary.
- `tests/_shims/` — fake `tmux`/`ps`/`date` used by discovery + golden tests.
- `tests/test_misc.sh` — `_ago` + transcript helpers (`_title_of`, `_last_user_prompt`, `_last_assistant_ends_with_question`).
- `tests/test_paths.sh` — `_proj_sub`.
- `tests/test_status.sh` — `_status_for` (state machine) + `_status_presentation`.
- `tests/test_hook.sh` — `hooks/inbox-hook.sh` writer contract.
- `tests/test_discovery.sh` — `claude_panes` via shims.
- `tests/test_build_list.sh` — `build_list` golden/integration test.
- `tests/fixtures/` — `.jsonl` transcript fixtures (incl. a malformed trailing line).
- `tests/lint.sh` — runs `shellcheck -s bash`.
- `.shellcheckrc` — dialect + intentional disables.
- `.github/workflows/ci.yml` — lint + test + jq matrix.

**Modified files**
- `lib/common.sh` — add `_status_presentation`, `_prune_state`; rewire `build_list`, `prune_dead`.
- `scripts/inbox-preview.sh` — use `_status_presentation`.
- `scripts/inbox-next.sh` — use `_status_presentation` rank + apply rank fix.
- `scripts/inbox-status.sh` — one-line divergence comment.

---

## Task 1: Test harness foundation

**Files:**
- Create: `tests/_assert.sh`
- Create: `tests/run.sh`

- [ ] **Step 1: Write `tests/_assert.sh`**

```bash
#!/usr/bin/env bash
# Pure-bash assertion + fixture helpers. Sourced into each test subshell by run.sh.
# Results are APPENDED to $TAI_RESULTS (a temp file) because a pass/fail counter
# held in a variable cannot cross the subshell-per-file boundary run.sh creates.
: "${TAI_RESULTS:?_assert.sh requires TAI_RESULTS (set by run.sh)}"

# assert_eq <expected> <actual> <message>
assert_eq() {
  if [ "$1" = "$2" ]; then
    printf 'PASS\t%s\n' "$3" >> "$TAI_RESULTS"
  else
    printf 'FAIL\t%s\n\texpected: [%s]\n\tactual:   [%s]\n' "$3" "$1" "$2" >> "$TAI_RESULTS"
  fi
}

# assert_rc <expected_rc> <actual_rc> <message>
assert_rc() {
  if [ "$1" = "$2" ]; then
    printf 'PASS\t%s\n' "$3" >> "$TAI_RESULTS"
  else
    printf 'FAIL\t%s (expected rc %s, got %s)\n' "$3" "$1" "$2" >> "$TAI_RESULTS"
  fi
}

# set_mtime <epoch> <file> — portable across GNU (Linux) and BSD (macOS).
# GNU touch understands -d @<epoch>; BSD does not, so fall back to converting the
# epoch with BSD `date -r` into touch -t's CCYYMMDDhhmm.ss form.
set_mtime() {
  local epoch="$1" file="$2" stamp
  if touch -d "@$epoch" "$file" 2>/dev/null; then return 0; fi
  stamp="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$stamp" "$file"
}

# strip_ansi — filter stdin, removing ANSI SGR escapes (for golden comparisons).
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }
```

- [ ] **Step 2: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Run every tests/test_*.sh in its own subshell so functions/globals can't leak
# between files. Assertion results land in a temp file; the final summary reads it.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export TAI_ROOT="$DIR"
TAI_RESULTS="$(mktemp)"; export TAI_RESULTS
trap 'rm -f "$TAI_RESULTS"' EXIT

for f in "$DIR"/tests/test_*.sh; do
  [ -e "$f" ] || continue
  printf '== %s ==\n' "${f##*/}"
  ( . "$DIR/tests/_assert.sh"; . "$f" ) \
    || printf 'FAIL\t%s (file errored, rc=%s)\n' "${f##*/}" "$?" >> "$TAI_RESULTS"
done

passes="$(grep -c '^PASS' "$TAI_RESULTS" 2>/dev/null || true)"; passes="${passes:-0}"
fails="$(grep -c '^FAIL' "$TAI_RESULTS" 2>/dev/null || true)"; fails="${fails:-0}"
printf '\n--- failures ---\n'; grep '^FAIL' "$TAI_RESULTS" 2>/dev/null || printf '(none)\n'
printf '\n%s passed, %s failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
```

Note: `set -u` lives only in `run.sh`. Test files do NOT force `set -u` on the sourced plugin functions (the plugin legitimately tests unset vars), avoiding harness-only failures.

- [ ] **Step 3: Make both executable**

Run: `chmod +x tests/run.sh tests/_assert.sh`

- [ ] **Step 4: Smoke-test the harness with a throwaway file**

Run:
```bash
printf '%s\n' '#!/usr/bin/env bash' '. "$TAI_ROOT/lib/common.sh"' 'assert_eq a a "smoke ok"' > tests/test_zzz_smoke.sh
bash tests/run.sh; echo "rc=$?"
rm -f tests/test_zzz_smoke.sh
```
Expected: output contains `1 passed, 0 failed` and `rc=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/_assert.sh tests/run.sh
git commit -m "test: add pure-bash assertion harness and runner"
```

---

## Task 2: `_ago` tests (validate harness against a real function)

**Files:**
- Create: `tests/test_misc.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Misc pure-function tests: _ago and the transcript helpers.
. "$TAI_ROOT/lib/common.sh"

# _ago formats a duration from a past epoch to "now" (date +%s). To make it
# deterministic we cannot inject "now", so freeze the clock by shimming `date`
# via PATH for the duration of these assertions.
_shimdir="$(mktemp -d)"
cat > "$_shimdir/date" <<'SH'
#!/usr/bin/env bash
case "$1" in
  +%s) printf '%s\n' "${TAI_NOW:?}";;
  *) exec /bin/date "$@";;
esac
SH
chmod +x "$_shimdir/date"
PATH="$_shimdir:$PATH"; export PATH TAI_NOW

TAI_NOW=1000

assert_eq " 0s" "$(_ago 1000)" "_ago: 0 seconds"
assert_eq " 5s" "$(_ago 995)"  "_ago: 5 seconds"
assert_eq " 1m" "$(_ago 940)"  "_ago: 60 seconds -> 1m"
assert_eq "59m" "$(_ago $((1000 - 3540)))" "_ago: 3540s -> 59m"
assert_eq " 1h" "$(_ago $((1000 - 3600)))" "_ago: 3600s -> 1h"
assert_eq " 1d" "$(_ago $((1000 - 86400)))" "_ago: 86400s -> 1d"
assert_eq " 0s" "$(_ago 2000)" "_ago: future clamps to 0"

rm -rf "$_shimdir"
```

- [ ] **Step 2: Run and verify it passes (pins current behavior)**

Run: `bash tests/run.sh`
Expected: failures section shows `(none)`; summary count increases by 7. `_ago` already exists, so these PASS. If any FAIL, the expected string's leading-space padding is wrong — read `lib/common.sh:83-93` (`printf '%2ds'`) and correct the expected value, do NOT change `_ago`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_misc.sh
git commit -m "test: pin _ago duration formatting"
```

---

## Task 3: Transcript helper tests (`_title_of`, `_last_user_prompt`, `_last_assistant_ends_with_question`)

**Files:**
- Create: `tests/fixtures/title.jsonl`
- Create: `tests/fixtures/question.jsonl`
- Create: `tests/fixtures/answered.jsonl`
- Create: `tests/fixtures/malformed.jsonl`
- Modify: `tests/test_misc.sh`

- [ ] **Step 1: Create fixtures**

`tests/fixtures/title.jsonl`:
```
{"type":"user","message":{"content":"hello there friend"}}
{"type":"ai-title","aiTitle":"my generated title"}
{"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}
```

`tests/fixtures/question.jsonl`:
```
{"type":"user","message":{"content":"do the thing"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Which option do you want?"}]}}
```

`tests/fixtures/answered.jsonl`:
```
{"type":"assistant","message":{"content":[{"type":"text","text":"Which option do you want?"}]}}
{"type":"user","message":{"content":"the first one"}}
```

`tests/fixtures/malformed.jsonl` (last line is intentionally truncated/invalid JSON — transcripts are append-in-progress):
```
{"type":"ai-title","aiTitle":"good title"}
{"type":"user","message":{"content":"a real prompt here"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"partial line not closed
```

- [ ] **Step 2: Append the failing tests to `tests/test_misc.sh`**

```bash
# --- transcript helpers (jq-dependent; assert the jq path when jq is present) ---
F="$TAI_ROOT/tests/fixtures"
if command -v jq >/dev/null 2>&1; then
  assert_eq "my generated title" "$(_title_of "$F/title.jsonl")" "_title_of: reads aiTitle"
  assert_eq "good title"         "$(_title_of "$F/malformed.jsonl")" "_title_of: survives malformed tail"
  assert_eq "hello there friend" "$(_last_user_prompt "$F/title.jsonl")" "_last_user_prompt: last user text"
  assert_eq "a real prompt here" "$(_last_user_prompt "$F/malformed.jsonl")" "_last_user_prompt: malformed tail ok"

  _last_assistant_ends_with_question "$F/question.jsonl"; assert_rc 0 "$?" "ends_with_question: trailing assistant '?' -> 0"
  _last_assistant_ends_with_question "$F/answered.jsonl"; assert_rc 1 "$?" "ends_with_question: user replied -> 1"
else
  # Document the untested fallback rather than silently skipping.
  assert_eq "" "$(_title_of "$F/title.jsonl")" "_title_of: no-jq returns empty (fallback)"
fi
```

- [ ] **Step 3: Run and verify it passes**

Run: `bash tests/run.sh`
Expected: failures `(none)`. These functions already exist and take the path as `$1`. If `_title_of` FAILs, confirm the fixture's `ai-title`/`aiTitle` keys match `lib/common.sh:117` exactly.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures tests/test_misc.sh
git commit -m "test: pin transcript helpers incl. malformed-tail handling"
```

---

## Task 4: `_proj_sub` tests

**Files:**
- Create: `tests/test_paths.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"

ws="$(mktemp -d)"
trap 'rm -rf "$ws"' EXIT

# Helper: assert "proj<TAB>sub" for a cwd.
check() { assert_eq "$2" "$(_proj_sub "$1")" "$3"; }

# 1) Claude-managed worktree path.
check "/home/me/myproj/.claude/worktrees/feat-x" "myproj	feat-x" "_proj_sub: claude worktree"

# 2) Plain repo (.git is a dir) + subfolder.
mkdir -p "$ws/repo/.git" "$ws/repo/src/inner"
check "$ws/repo/src/inner" "repo	src/inner" "_proj_sub: plain repo + subfolder"
check "$ws/repo" "repo	" "_proj_sub: plain repo root (empty sub)"

# 3) Linked worktree (.git is a FILE with gitdir:).
mkdir -p "$ws/main/.git/worktrees/wt1" "$ws/wt1"
printf 'gitdir: %s/main/.git/worktrees/wt1\n' "$ws" > "$ws/wt1/.git"
check "$ws/wt1" "main	wt1" "_proj_sub: linked worktree"

# 4) No repo -> nearest folder, empty sub.
mkdir -p "$ws/loose/dir"
check "$ws/loose/dir" "dir	" "_proj_sub: no repo fallback"

# 5) Path containing a space.
mkdir -p "$ws/has space/.git"
check "$ws/has space" "has space	" "_proj_sub: path with space"
```

- [ ] **Step 2: Run and verify it passes**

Run: `bash tests/run.sh`
Expected: failures `(none)`. If the linked-worktree case FAILs, re-read `lib/common.sh:237-246` and confirm the fixture `gitdir:` line ends with `/.git/worktrees/<name>`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_paths.sh
git commit -m "test: pin _proj_sub path/worktree parsing"
```

---

## Task 5: `_status_for` tests (the state machine)

**Files:**
- Create: `tests/test_status.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"

# _status_for <hook_status> <hook_updated> <tx_mtime> <now>
NOW=1000

# Endpoint states trusted unconditionally (no transcript demotion).
assert_eq working    "$(_status_for working    900 999 "$NOW")" "status: working trusted"
assert_eq background "$(_status_for background 900 999 "$NOW")" "status: background trusted"

# waiting: stays waiting until transcript progresses past the Notification epoch.
assert_eq waiting "$(_status_for waiting 900 900 "$NOW")" "status: waiting holds (tx not past hu)"
assert_eq working "$(_status_for waiting 900 950 "$NOW")" "status: waiting->working once tx>hu+1"

# done: fresh done not re-promoted by post-Stop transcript writes.
assert_eq done "$(_status_for done 998 999 "$NOW")" "status: fresh done stays done"

# stale hook (hu<<tx): derive from transcript freshness windows.
assert_eq working "$(_status_for '' 0 998 "$NOW")" "status: tx age 2s -> working (<5s)"
assert_eq working "$(_status_for '' 0 992 "$NOW")" "status: tx age 8s -> working (<10s)"
assert_eq working "$(_status_for '' 0 989 "$NOW")" "status: tx age 11s -> working (<12s)"
assert_eq done    "$(_status_for '' 0 980 "$NOW")" "status: tx age 20s -> done"
assert_eq idle    "$(_status_for '' 0 0   "$NOW")" "status: no hook, no transcript -> idle"
```

- [ ] **Step 2: Run and verify it passes**

Run: `bash tests/run.sh`
Expected: failures `(none)`. These assertions encode the current logic in `lib/common.sh:175-210`. If one FAILs, trace the exact branch in `_status_for` and fix the EXPECTED value to match current behavior — do not change `_status_for` in this task.

- [ ] **Step 3: Commit**

```bash
git add tests/test_status.sh
git commit -m "test: pin _status_for state machine"
```

---

## Task 6: `inbox-hook.sh` writer-contract tests

**Files:**
- Create: `tests/test_hook.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Drives hooks/inbox-hook.sh with synthetic payloads and asserts the state-file
# line shape: "<status> <epoch> <event> <tpath>". TMUX_PANE + CACHE point at a
# temp workspace. The SessionStart parent-walk (ownership lock) is out of scope.
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
export XDG_CACHE_HOME="$ws/cache"
export TMUX_PANE="%99"
HOOK="$TAI_ROOT/hooks/inbox-hook.sh"
SF="$ws/cache/tmux-agents-inbox/pane-99"

run_hook() { printf '%s' "$2" | bash "$HOOK" "$1"; }
field() { awk -v n="$1" '{print $n; exit}' "$SF"; }   # field n of the state line

# UserPromptSubmit -> working
run_hook UserPromptSubmit '{"session_id":"s1","transcript_path":"/t/s1.jsonl"}'
assert_eq working "$(field 1)" "hook: UserPromptSubmit -> working"
assert_eq "/t/s1.jsonl" "$(field 4)" "hook: records transcript_path"

# Notification (real) -> waiting
run_hook Notification '{"session_id":"s1","transcript_path":"/t/s1.jsonl","notification_type":"permission"}'
assert_eq waiting "$(field 1)" "hook: Notification -> waiting"

# Notification idle_prompt -> leaves state untouched (still waiting from above)
run_hook Notification '{"session_id":"s1","transcript_path":"/t/s1.jsonl","notification_type":"idle_prompt"}'
assert_eq waiting "$(field 1)" "hook: idle_prompt does not overwrite"

# Stop with running background_tasks -> background
run_hook Stop '{"session_id":"s1","transcript_path":"/t/s1.jsonl","background_tasks":[{"status":"running"}]}'
assert_eq background "$(field 1)" "hook: Stop + running bg -> background"

# Stop clean -> done
run_hook Stop '{"session_id":"s1","transcript_path":"/t/s1.jsonl","background_tasks":[]}'
assert_eq done "$(field 1)" "hook: clean Stop -> done"

# SessionEnd -> file removed
run_hook SessionEnd '{"session_id":"s1","transcript_path":"/t/s1.jsonl"}'
[ -f "$SF" ]; assert_rc 1 "$?" "hook: SessionEnd removes state file"
```

- [ ] **Step 2: Run and verify it passes**

Run: `bash tests/run.sh`
Expected: failures `(none)`. The foreign-session lock (`lib`/hook lines 97-100) keys on the transcript filename's session id; all payloads above share `s1.jsonl`, so writes are accepted. If the first write is rejected, confirm no stale `$SF` exists (the temp workspace guarantees this).

- [ ] **Step 3: Commit**

```bash
git add tests/test_hook.sh
git commit -m "test: pin inbox-hook.sh writer contract"
```

---

## Task 7: `claude_panes` discovery test (PATH shims)

**Files:**
- Create: `tests/_shims/tmux`
- Create: `tests/_shims/ps`
- Create: `tests/test_discovery.sh`

- [ ] **Step 1: Create the shims**

`tests/_shims/tmux`:
```bash
#!/usr/bin/env bash
# Fake tmux: dispatch on the -F format requested by the code under test.
case "$*" in
  *'#{pane_pid} #{pane_id}'*)              cat "$TAI_FIX/panes_pidmap" ;;
  *'#{pane_id}|#{session_name}'*)          cat "$TAI_FIX/panes_meta" ;;
  *'list-panes -a -F x'*)                  printf 'x\n' ;;
  *) exit 0 ;;
esac
```

`tests/_shims/ps`:
```bash
#!/usr/bin/env bash
# Fake ps: only the -eo pid=,ppid=,args= snapshot is used.
cat "$TAI_FIX/ps_snap"
```

- [ ] **Step 2: Write the failing test**

```bash
#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
export TAI_FIX="$ws"
PATH="$TAI_ROOT/tests/_shims:$PATH"; export PATH
chmod +x "$TAI_ROOT/tests/_shims/tmux" "$TAI_ROOT/tests/_shims/ps"

# pane %5 shell pid 500 runs an interactive claude (pid 510, parent 500).
# pane %6 shell pid 600 runs `claude agents` (must be EXCLUDED).
cat > "$ws/panes_pidmap" <<'EOF'
500 %5
600 %6
EOF
cat > "$ws/ps_snap" <<'EOF'
500 1 -bash
510 500 /usr/local/bin/claude
600 1 -bash
610 600 /usr/local/bin/claude agents
EOF

out="$(claude_panes)"
assert_eq "%5" "$out" "claude_panes: resolves interactive claude to its pane, excludes 'agents'"
```

- [ ] **Step 3: Run and verify it passes**

Run: `bash tests/run.sh`
Expected: failures `(none)`. `claude_panes` output is `sort -u`'d, so a single `%5` line is expected. If `%6` leaks in, confirm the exclusion regex at `lib/common.sh:50-52` matches ` agents ` (note the surrounding spaces in the fixture argv).

- [ ] **Step 4: Commit**

```bash
git add tests/_shims tests/test_discovery.sh
git commit -m "test: cover claude_panes discovery via ps/tmux shims"
```

---

## Task 8: `build_list` golden test (pins assembled output BEFORE refactor)

**Files:**
- Create: `tests/test_build_list.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Golden/integration test for build_list. Composes the tmux/ps shims (Task 7)
# with a frozen clock, a temp CACHE of state files, and a temp HOME holding the
# transcript the title/age columns read. Asserts the visible (ANSI-stripped) rows.
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT

# Frozen clock shim (date +%s -> $TAI_NOW; everything else real).
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
  *) exit 0 ;;
esac
SH
cp "$TAI_ROOT/tests/_shims/ps" "$ws/bin/ps"
chmod +x "$ws/bin/"*
PATH="$ws/bin:$PATH"; export PATH TAI_FIX TAI_NOW
export TAI_FIX="$ws" TAI_NOW=1000000000

# Redirect CACHE + HOME into the workspace.
export XDG_CACHE_HOME="$ws/cache"; export HOME="$ws/home"
export CACHE="$ws/cache/tmux-agents-inbox"   # common.sh already read CACHE at source;
mkdir -p "$CACHE" "$ws/home"

# One pane: %5 (shell pid 500, claude pid 510), cwd /proj.
printf '500 %%5\n' > "$ws/panes_pidmap"
printf '%%5|sess1|0|win1|0|%s\n' "$ws/proj" > "$ws/panes_meta"
printf '500 1 -bash\n510 500 /usr/local/bin/claude\n' > "$ws/ps_snap"
mkdir -p "$ws/proj/.git"

# Transcript for the title + a frozen mtime so the age column is deterministic.
slug="$(printf '%s' "$ws/proj" | sed 's/[/.]/-/g')"
mkdir -p "$HOME/.claude/projects/$slug"
TX="$HOME/.claude/projects/$slug/sess.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"my task"}' > "$TX"
set_mtime $((TAI_NOW - 5)) "$TX"

# State file: working, updated 5s ago.
printf 'working %s done %s\n' $((TAI_NOW - 5)) "$TX" > "$CACHE/pane-5"

# Default (state) view: expect a "Working (1)" header and one row showing proj+title.
printf 'state' > "$CACHE/.view-mode"
out="$(build_list | strip_ansi)"
printf '%s' "$out" | grep -q 'Working (1)'        ; assert_rc 0 "$?" "build_list: Working header present"
printf '%s' "$out" | grep -q 'proj'               ; assert_rc 0 "$?" "build_list: project column rendered"
printf '%s' "$out" | grep -q 'my task'            ; assert_rc 0 "$?" "build_list: ai-title as description"
rows="$(printf '%s\n' "$out" | grep -c '^%5')"    ; assert_eq 1 "$rows" "build_list: exactly one pane row"
```

- [ ] **Step 2: Run and verify it passes**

Run: `bash tests/run.sh`
Expected: failures `(none)`. This pins current assembled output. If the header text differs, read `lib/common.sh:342-348` for the exact label strings and align the `grep` patterns to current behavior. NOTE: this test must remain green through Tasks 9–11 — it is the regression guard for the refactor.

- [ ] **Step 3: Commit**

```bash
git add tests/test_build_list.sh
git commit -m "test: golden test pinning build_list assembled output"
```

---

## Task 9: Extract `_status_presentation` and rewire `build_list` + preview

**Files:**
- Modify: `lib/common.sh` (add helper near top of the status section; edit `build_list:301-315`)
- Modify: `scripts/inbox-preview.sh:60-66`
- Modify: `tests/test_status.sh`

- [ ] **Step 1: Add the failing test for the new helper to `tests/test_status.sh`**

```bash
# --- _status_presentation: tab-delimited "rank<TAB>icon<TAB>label<TAB>dim" ---
sp() { IFS=$'\t' read -r r i l d <<< "$(_status_presentation "$1")"; printf '%s|%s|%s' "$r" "$l" "$d"; }
assert_eq "0|Needs input|0" "$(sp waiting)"    "_status_presentation: waiting"
assert_eq "1|Completed|0"   "$(sp done)"       "_status_presentation: done"
assert_eq "2|Background|0"  "$(sp background)" "_status_presentation: background"
assert_eq "3|Working|0"     "$(sp working)"    "_status_presentation: working"
assert_eq "4|Idle|1"        "$(sp idle)"       "_status_presentation: idle"
assert_eq "4|Idle|1"        "$(sp bogus)"      "_status_presentation: unknown -> idle defaults"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh`
Expected: FAILs on the `_status_presentation:` assertions with empty values (function not defined yet).

- [ ] **Step 3: Add the helper to `lib/common.sh`** (insert immediately before `build_list`, around line 250)

```bash
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
```

- [ ] **Step 4: Run to verify the helper tests pass**

Run: `bash tests/run.sh`
Expected: the six `_status_presentation:` assertions PASS. Golden test still green.

- [ ] **Step 5: Rewire `build_list`** — replace the per-pane status case block (`lib/common.sh:301-307`) and the later `dcol`→`dim` derivation (`lib/common.sh:315`).

Replace:
```bash
    case "$status" in
      waiting)    rank=0; icon="${C_WAIT}✻${C_RESET}"; dcol="" ;;
      done)       rank=1; icon="${C_DONE}✻${C_RESET}"; dcol="" ;;
      background) rank=2; icon="${C_BG}✢${C_RESET}";   dcol="" ;;
      working)    rank=3; icon="✽";                    dcol="" ;;
      *)          rank=4; icon="${C_IDLE}✻${C_RESET}"; dcol="$C_IDLE" ;;
    esac
```
with:
```bash
    IFS=$'\t' read -r rank icon _lbl dim <<< "$(_status_presentation "$status")"
```
Then delete the now-redundant line `if [ -n "$dcol" ]; then dim=1; else dim=0; fi` (`dim` now comes straight from the helper). Remove `dcol` from the `local` declaration on `lib/common.sh:256`.

- [ ] **Step 6: Rewire `scripts/inbox-preview.sh`** — replace the status case block (`inbox-preview.sh:60-66`).

Replace:
```bash
case "$status" in
  waiting)    icon="${C_WAIT}✻${C_RESET}";  label="Needs input" ;;
  done)       icon="${C_DONE}✻${C_RESET}";  label="Completed" ;;
  background) icon="${C_BG}✢${C_RESET}";    label="Background" ;;
  working)    icon="✽";                     label="Working" ;;
  *)          icon="${C_IDLE}✻${C_RESET}";  label="Idle" ;;
esac
```
with:
```bash
IFS=$'\t' read -r _rank icon label _dim <<< "$(_status_presentation "$status")"
```

- [ ] **Step 7: Run the full suite (golden test is the regression guard)**

Run: `bash tests/run.sh`
Expected: `0 failed`. The golden test confirms `build_list` output (icon, rank order, dim) is unchanged.

- [ ] **Step 8: Commit**

```bash
git add lib/common.sh scripts/inbox-preview.sh tests/test_status.sh
git commit -m "refactor: single-source status presentation via _status_presentation"
```

---

## Task 10: Extract `_prune_state` and rewire `prune_dead` + `build_list`

**Files:**
- Modify: `lib/common.sh` (add `_prune_state`; edit `prune_dead:69-80` and the inline prune at `build_list:266-273`)
- Create: `tests/test_prune.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
export CACHE="$ws/cache"; mkdir -p "$CACHE"

: > "$CACHE/pane-1"; : > "$CACHE/pane-10"; : > "$CACHE/pane-2"

# Live set has only pane 1 and 10 (note: exact-line anchoring must NOT let "1"
# match inside "10", and must keep 10 while dropping 2).
_prune_state "$(printf '1\n10\n')"

[ -f "$CACHE/pane-1" ];  assert_rc 0 "$?" "_prune_state: keeps live pane 1"
[ -f "$CACHE/pane-10" ]; assert_rc 0 "$?" "_prune_state: keeps live pane 10 (no 1-in-10 collision)"
[ -f "$CACHE/pane-2" ];  assert_rc 1 "$?" "_prune_state: drops dead pane 2"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `_prune_state: command not found` (file errors, reported as a FAIL line).

- [ ] **Step 3: Add `_prune_state` to `lib/common.sh`** (insert just above `prune_dead`, around line 66)

```bash
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
```

- [ ] **Step 4: Rewire `prune_dead`** — replace its body (`lib/common.sh:69-80`) so it delegates:

```bash
prune_dead() {
  [ -d "$CACHE" ] || return 0
  local anypane live
  anypane="$(tmux list-panes -a -F x 2>/dev/null)"
  [ -n "$anypane" ] || return 0
  live="$(claude_panes | tr -d '%')"
  _prune_state "$live"
}
```

- [ ] **Step 5: Rewire the inline prune in `build_list`** — replace `lib/common.sh:266-273`:

```bash
  if [ -n "$meta" ]; then
    _prune_state "$(printf '%s' "$live" | tr -d '%')"
  fi
```
Remove `pruneset` and the now-unused `f`/`fid` from `build_list`'s `local` declaration (`lib/common.sh:254-255`) ONLY if no longer referenced — verify with `grep -n 'pruneset\|fid' lib/common.sh` after editing.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: `0 failed`. `_prune_state` tests PASS; golden test still green (pruning behavior unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh tests/test_prune.sh
git commit -m "refactor: single-source state pruning via _prune_state"
```

---

## Task 11: `inbox-next.sh` rank fix (done before background)

**Files:**
- Modify: `scripts/inbox-next.sh:13-22`
- Create: `tests/test_next_rank.sh`

- [ ] **Step 1: Write the failing test** (asserts the ordering function, not the tmux jump)

```bash
#!/usr/bin/env bash
# inbox-next ranks actionable panes; after the fix the order is waiting<done<background.
. "$TAI_ROOT/lib/common.sh"

rank_of() { IFS=$'\t' read -r r _i _l _d <<< "$(_status_presentation "$1")"; printf '%s' "$r"; }

# The approved order: done must rank LOWER (more urgent) than background.
[ "$(rank_of done)" -lt "$(rank_of background)" ]; assert_rc 0 "$?" "rank: done before background"
[ "$(rank_of waiting)" -lt "$(rank_of done)" ];     assert_rc 0 "$?" "rank: waiting before done"
```

- [ ] **Step 2: Run and verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — `_status_presentation` already encodes the canonical order. This test documents the contract that `inbox-next.sh` must now follow.

- [ ] **Step 3: Edit `scripts/inbox-next.sh`** — replace the rank case block (`inbox-next.sh:13-22`).

Replace:
```bash
  read -r status updated _ < "$f"
  id="${f##*/pane-}"
  case "$status" in
    waiting)    rank=0 ;;
    background) rank=1 ;;
    done)       rank=2 ;;
    *)          continue ;;
  esac
  [ -n "$updated" ] || updated=0
```
with:
```bash
  read -r status updated _ < "$f"
  id="${f##*/pane-}"
  case "$status" in
    waiting|done|background) ;;
    *) continue ;;
  esac
  IFS=$'\t' read -r rank _i _l _d <<< "$(_status_presentation "$status")"
  [ -n "$updated" ] || updated=0
```
(`inbox-next.sh` already sources `lib/common.sh` at line 5, so `_status_presentation` is in scope.)

- [ ] **Step 4: Manually verify the produced order**

Run:
```bash
tmpc="$(mktemp -d)"; CACHE="$tmpc"
printf 'done 100 x\n' > "$tmpc/pane-1"; printf 'background 100 x\n' > "$tmpc/pane-2"
# Emulate the sort key build: rank + zero-padded epoch
for f in "$tmpc"/pane-*; do read -r s u _ < "$f"; . lib/common.sh
  IFS=$'\t' read -r r _i _l _d <<< "$(_status_presentation "$s")"; printf '%s %s %s\n' "$r" "$u" "${f##*/}"; done | LC_ALL=C sort
rm -rf "$tmpc"
```
Expected: the `pane-1` (done, rank 1) line sorts before `pane-2` (background, rank 2).

- [ ] **Step 5: Run the full suite + commit**

Run: `bash tests/run.sh` → Expected `0 failed`.
```bash
git add scripts/inbox-next.sh tests/test_next_rank.sh
git commit -m "fix: align inbox-next jump order with popup (done before background)"
```

---

## Task 12: `inbox-status.sh` divergence comment

**Files:**
- Modify: `scripts/inbox-status.sh:6-8`

- [ ] **Step 1: Add the comment** — insert after `. "$DIR/lib/common.sh"` (line 5):

```bash
# NOTE: counts use the RAW hook status from each state file, not _status_for's
# transcript-reconciled status (which the popup uses). The status line can thus
# briefly disagree with the popup after a /compact or for pre-install sessions.
# Reconciling would require a per-pane transcript read on every status-interval
# tick — a performance change deferred out of this maintainability pass.
```

- [ ] **Step 2: Verify the script still runs**

Run: `bash scripts/inbox-status.sh; echo "rc=$?"`
Expected: `rc=0` (prints nothing or the summary; no errors).

- [ ] **Step 3: Commit**

```bash
git add scripts/inbox-status.sh
git commit -m "docs: note intentional status-line vs popup count divergence"
```

---

## Task 13: shellcheck config + lint script

**Files:**
- Create: `.shellcheckrc`
- Create: `tests/lint.sh`

- [ ] **Step 1: Write `.shellcheckrc`**

```
# shellcheck has no bash-3.2 dialect; -s bash assumes modern bash. Running it is
# still the safety net that flags accidental bash-4+ features (assoc arrays,
# namerefs) that would break macOS /bin/bash 3.2.
shell=bash
# SC2155: declare+assign on one line — pervasive, intentional style here.
disable=SC2155
# SC1091: shellcheck can't follow sourced lib/common.sh from every entry point.
disable=SC1091
```

- [ ] **Step 2: Write `tests/lint.sh`**

```bash
#!/usr/bin/env bash
# Run shellcheck over the shell sources. Lint is the gate; behavioral fixes are
# scoped to files this pass touches (see spec). Skips cleanly if shellcheck is absent.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed — skipping lint (install: brew install shellcheck)"
  exit 0
fi
cd "$DIR" || exit 1
files="$(find lib scripts hooks -name '*.sh' -type f) tmux-agents-inbox.tmux"
# shellcheck disable=SC2086
shellcheck $files
```

- [ ] **Step 3: Run it (locally shellcheck is absent — expect the skip)**

Run: `bash tests/lint.sh; echo "rc=$?"`
Expected: prints the "shellcheck not installed — skipping" line and `rc=0`.

- [ ] **Step 4: (If shellcheck available) triage findings**

If `shellcheck` IS installed, run `bash tests/lint.sh` and fix only findings in files this pass already modified (`lib/common.sh`, the three `scripts/*.sh`, `hooks/inbox-hook.sh` if touched). For pre-existing findings in untouched files, add a targeted `# shellcheck disable=SCxxxx` with a one-line reason rather than rewriting working code. Do NOT mass-rewrite.

- [ ] **Step 5: Commit**

```bash
git add .shellcheckrc tests/lint.sh
git commit -m "chore: add shellcheck config and lint runner"
```

---

## Task 14: CI workflow (lint + test + jq matrix)

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: ci
on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: bash tests/lint.sh

  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        jq: [ "with-jq", "without-jq" ]
    steps:
      - uses: actions/checkout@v4
      - name: Ensure jq present (with-jq leg)
        if: matrix.jq == 'with-jq'
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Mask jq (without-jq leg)
        if: matrix.jq == 'without-jq'
        run: |
          # Remove jq and clear bash's command hash so the fallback paths run.
          sudo rm -f "$(command -v jq)" || true
          hash -r
          ! command -v jq >/dev/null 2>&1 && echo "jq masked OK"
      - run: bash tests/run.sh
```

- [ ] **Step 2: Validate YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"`
Expected: `yaml ok`.

- [ ] **Step 3: Run the suite once more locally before pushing**

Run: `bash tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: lint + test with jq present/masked matrix"
```

---

## Final verification

- [ ] **Run the complete suite**

Run: `bash tests/run.sh`
Expected: `0 failed`, and the failures section reads `(none)`.

- [ ] **Confirm no `_RET_*` globals leaked in**

Run: `grep -rn '_RET_' lib scripts || echo "clean: no _RET_ globals"`
Expected: `clean: no _RET_ globals`.

- [ ] **Confirm behavior parity** — open tmux, install hooks, open the popup (`prefix + I`), toggle preview (`?`), cycle views (`ctrl-s`), press `prefix + N`. Verify icons, grouping, and that next-jump now visits `done` before `background`.

---

## Notes for the executor

- **Bash 3.2 only.** No associative arrays, no `mapfile`, no `${var^^}`, no namerefs. `<<<` herestrings and `IFS=$'\t' read` are fine in 3.2.
- **The golden test (Task 8) is the regression guard** for Tasks 9–11. If it goes red during a refactor, the refactor changed visible output — stop and reconcile before continuing.
- **`CACHE` is read once when `common.sh` is sourced** (`lib/common.sh:5`). Tests that need a temp cache must `export CACHE=...` AFTER sourcing, or set `XDG_CACHE_HOME` BEFORE sourcing. The provided tests do the former.
- **Commits:** the plan commits per task. Per repo convention, get the user's go-ahead before the first commit if they have not already authorized commits for this session.
