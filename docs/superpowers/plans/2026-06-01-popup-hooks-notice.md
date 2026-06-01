# Popup "hooks not detected" notice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a non-selectable, honestly-worded warning banner at the top of the inbox popup when this plugin's Claude Code hook isn't detected in the user's settings.

**Architecture:** A new `_hooks_detected()` helper in `lib/common.sh` greps the user settings file (`$CLAUDE_SETTINGS` or `~/.claude/settings.json`) for this plugin's *resolved absolute* hook path. `build_list` prepends a yellow `__hdr__` banner line (non-selectable by the existing popup contract) when detection fails. Detection is a cheap, jq-free heuristic scoped to user settings; its blind spots are documented and tested as accepted.

**Tech Stack:** bash 3.2 (macOS-safe), the existing `tests/` shim harness (no framework), shellcheck via `tests/lint.sh`.

---

## File Structure

- `lib/common.sh` — **modify**: add `AGENTS_INBOX_DIR` resolution (top) + `_hooks_detected()` helper + banner emission inside `build_list`.
- `tests/test_hooks_detected.sh` — **create**: unit tests for `_hooks_detected()` (rc-based).
- `tests/test_hooks_notice.sh` — **create**: integration tests for the banner in `build_list` output.
- `README.md` — **modify**: one caveat line documenting the notice + user-settings-only scope.

Detection lives in `common.sh` because `build_list` is the single render source for both the first-paint snapshot (`inbox-open.sh`) and the ~1 s refresh (`_build.sh`). No new scripts.

---

## Task 1: `_hooks_detected()` helper + plugin-dir resolution

**Files:**
- Modify: `lib/common.sh` (add `AGENTS_INBOX_DIR` after the `CACHE=` line ~`lib/common.sh:5`; add `_hooks_detected()` near the other small helpers)
- Test: `tests/test_hooks_detected.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_hooks_detected.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for _hooks_detected(): greps the user settings file for THIS
# plugin's resolved absolute hook path. User-scope + grep-only by design.
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
HOOK="$TAI_ROOT/hooks/inbox-hook.sh"   # the resolved path _hooks_detected looks for

# present: settings contains the resolved hook path -> detected (rc 0)
p="$ws/present.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash %s Stop"}]}]}}\n' "$HOOK" > "$p"
export CLAUDE_SETTINGS="$p"; _hooks_detected
assert_rc 0 "$?" "_hooks_detected: true when resolved hook path present"

# absent: no hook entry -> not detected (rc 1)
a="$ws/absent.json"; printf '{"hooks":{}}\n' > "$a"
export CLAUDE_SETTINGS="$a"; _hooks_detected
assert_rc 1 "$?" "_hooks_detected: false when hook path absent"

# stale/relocated: basename matches but full path differs -> not detected
s="$ws/stale.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash /old/p/hooks/inbox-hook.sh Stop"}]}]}}\n' > "$s"
export CLAUDE_SETTINGS="$s"; _hooks_detected
assert_rc 1 "$?" "_hooks_detected: false for stale path (resolved-path, not basename)"

# missing file -> not detected
export CLAUDE_SETTINGS="$ws/nope.json"; _hooks_detected
assert_rc 1 "$?" "_hooks_detected: false when settings file missing"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 hooks_detected`
Expected: FAIL — `_hooks_detected` is undefined, so the test file errors (`rc != 0`) or assertions fail.

- [ ] **Step 3: Add the plugin-dir resolution**

In `lib/common.sh`, immediately after the `CACHE=...` line (`lib/common.sh:5`), add:

```bash
# Resolved plugin root (this file is <root>/lib/common.sh). Used to match THIS
# plugin's hook path in settings; overridable for tests via the env var.
AGENTS_INBOX_DIR="${AGENTS_INBOX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
```

- [ ] **Step 4: Add the `_hooks_detected` helper**

In `lib/common.sh`, add this helper (place it just above `build_list()`, i.e. before `lib/common.sh:283`):

```bash
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep hooks_detected`
Expected: 4 `PASS` lines, no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh tests/test_hooks_detected.sh
git commit -m "feat: add _hooks_detected helper (resolved-path, user-scope)"
```

---

## Task 2: Emit the banner in `build_list`

**Files:**
- Modify: `lib/common.sh` (inside `build_list`, after `liveset=...` at `lib/common.sh:299`, before the `printf '%s\n' "$meta" | while ...` pipeline at `lib/common.sh:300`)
- Test: `tests/test_hooks_notice.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_hooks_notice.sh`:

```bash
#!/usr/bin/env bash
# Integration test: build_list prepends a non-selectable yellow banner when the
# plugin's hook isn't detected. Uses empty tmux/ps shims (zero panes) so the
# banner is the only variable in the output.
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
mkdir -p "$ws/bin"

# tmux shim: no panes for either format query.
cat > "$ws/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
# ps shim: no processes.
cat > "$ws/bin/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$ws/bin/"*
PATH="$ws/bin:$PATH"; export PATH

export XDG_CACHE_HOME="$ws/cache"
export CACHE="$ws/cache/tmux-agents-inbox"   # common.sh read CACHE at source; override here
mkdir -p "$CACHE"
printf 'state' > "$CACHE/.view-mode"
HOOK="$TAI_ROOT/hooks/inbox-hook.sh"

# absent settings -> banner shown
a="$ws/absent.json"; printf '{"hooks":{}}\n' > "$a"
export CLAUDE_SETTINGS="$a"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: banner shown when hook path absent"

# present (resolved path) -> no banner
p="$ws/present.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash %s Stop"}]}]}}\n' "$HOOK" > "$p"
export CLAUDE_SETTINGS="$p"
build_list | grep -q 'hooks not detected'
assert_rc 1 "$?" "notice: no banner when resolved hook path present"

# stale path -> banner shown (guards resolved-path, not basename)
s="$ws/stale.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash /old/p/hooks/inbox-hook.sh Stop"}]}]}}\n' > "$s"
export CLAUDE_SETTINGS="$s"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: banner shown for stale path"

# missing settings file -> banner shown
export CLAUDE_SETTINGS="$ws/nope.json"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: banner shown when settings file missing"

# malformed JSON lacking the path -> banner shown (grep is content-based, no parse)
m="$ws/malformed.json"; printf '{"hooks": {"Stop": [ {"hooks": [\n' > "$m"
export CLAUDE_SETTINGS="$m"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: malformed settings without path -> banner"

# zero panes + not detected -> banner is the SOLE output line
export CLAUDE_SETTINGS="$a"
lc="$(build_list | grep -c '')"
assert_eq 1 "$lc" "notice: zero-pane popup shows banner as sole line"

# banner first field is __hdr__ (non-selectable contract)
f1="$(build_list | head -1 | cut -f1)"
assert_eq "__hdr__" "$f1" "notice: banner first field is __hdr__"

# remains __hdr__ on a second build (reload re-runs build_list)
f1b="$(build_list | head -1 | cut -f1)"
assert_eq "__hdr__" "$f1b" "notice: banner stays __hdr__ across reload"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 hooks_notice`
Expected: FAIL — no banner is emitted yet, so the "banner shown" / sole-line / `__hdr__` assertions fail.

- [ ] **Step 3: Add the banner emission**

In `lib/common.sh`, inside `build_list`, insert between the `liveset=...` line (`lib/common.sh:299`) and the `printf '%s\n' "$meta" | while ...` line (`lib/common.sh:300`):

```bash
  # When this plugin's hook isn't detected in the user settings, prepend a
  # NON-selectable (__hdr__) yellow warning. States below are transcript-
  # approximated without hooks; this explains an empty or inaccurate popup.
  _hooks_detected || printf '__hdr__\t%s⚠ hooks not detected in %s — status may be approximate — run: bash %s/install-hooks.sh%s\n' \
    "$C_WAIT" "${CLAUDE_SETTINGS:-~/.claude/settings.json}" "$AGENTS_INBOX_DIR" "$C_RESET"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep hooks_notice`
Expected: 8 `PASS` lines, no `FAIL`.

- [ ] **Step 5: Run the FULL suite to check for regressions**

Run: `bash tests/run.sh`
Expected: final line `N passed, 0 failed`. (Note: `test_build_list.sh` sets no `CLAUDE_SETTINGS` and a hookless temp `HOME`, so its `build_list` output now includes the banner line — its assertions count `^%5` rows and grep specific labels, all unaffected by an `__hdr__` banner. Confirm it still passes.)

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh tests/test_hooks_notice.sh
git commit -m "feat: warn in popup when hooks not detected"
```

---

## Task 3: Document the notice + lint

**Files:**
- Modify: `README.md` (the `## Caveats` section)

- [ ] **Step 1: Add the caveat**

In `README.md`, under `## Caveats`, add this bullet:

```markdown
- **Hook-detection notice is user-scope only.** When the popup can't find this plugin's hook path in
  your user settings (`$CLAUDE_SETTINGS` or `~/.claude/settings.json`), it shows a yellow
  `hooks not detected` banner at the top. It's a cheap grep for the plugin's resolved hook path, so it
  won't see hooks wired into a *project* `.claude/settings.json`, and a partial install (path present
  but not all events) reads as detected. Run `install-hooks.sh` (the documented path) and it clears.
```

- [ ] **Step 2: Run shellcheck lint**

Run: `bash tests/lint.sh`
Expected: exits 0 (no new findings). If `lint.sh` flags the new `grep -qF` or `printf` lines, fix per `.shellcheckrc` conventions; do not add new `# shellcheck disable` unless an existing pattern in the file already does so.

- [ ] **Step 3: Run the full suite once more**

Run: `bash tests/run.sh`
Expected: `N passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document the popup hooks-not-detected notice"
```

---

## Self-Review

**Spec coverage:**
- Honest "not detected" wording → Task 2 Step 3 banner text. ✓
- `_hooks_detected` rename/concept → Task 1. ✓
- Resolved absolute path (not basename) → Task 1 helper + Task 1/2 stale-path tests. ✓
- User-scope only (Option A) → Task 1 `settings=` resolution. ✓
- jq-free, single grep → Task 1 (`grep -qF`). ✓
- Distinct warning color (`$C_WAIT`) → Task 2 Step 3. ✓
- Non-selectable via `__hdr__` → Task 2 banner + tests. ✓
- Show even with zero panes → Task 2 sole-line test. ✓
- Single source (`build_list`, both paint + refresh) → emission inside `build_list`. ✓
- Cost: one grep/sec, no caching → helper is a single grep; no cache added. ✓
- Error handling: missing/unreadable → not detected → banner → Task 1/2 missing-file tests. ✓
- Tests: present/absent/stale/missing/malformed/zero-pane/`__hdr__`/reload → Task 1+2. ✓
- README caveat (user-scope + partial-install blind spots) → Task 3. ✓

**Placeholder scan:** none — every code/test step has complete content.

**Type/name consistency:** `_hooks_detected` (Tasks 1, 2), `AGENTS_INBOX_DIR` (Tasks 1, 2), `$C_WAIT`/`$C_RESET` (defined `lib/common.sh:13,11`), banner marker `__hdr__` matches the popup contract (`scripts/inbox-popup.sh:35-37`), needle `$AGENTS_INBOX_DIR/hooks/inbox-hook.sh` matches the test fixture path `$TAI_ROOT/hooks/inbox-hook.sh` (`$TAI_ROOT` == plugin root == `AGENTS_INBOX_DIR` when sourced under the test runner). Consistent.
