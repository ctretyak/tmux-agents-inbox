# Maintainability pass — design

**Date:** 2026-05-29
**Scope:** Code quality / maintainability (scope "A + cheap de-dups")
**Status:** Approved for planning (revised after adversarial council review, then a 4-way debate — v3)

## Goal

The codebase (~1,000 lines of Bash across `lib/`, `scripts/`, `hooks/`) is well-built but
has no safety net and a few real duplications that are starting to drift. This pass adds
tests + lint + CI to pin current behavior, then removes the low-risk duplications that the
tests cover. It does **not** restructure the code (no module split — that is over-engineering
for a single cohesive 370-line `common.sh`).

## Non-goals

- No module split of `common.sh` (rejected scope C).
- No reconciliation of the status-line raw-count vs `_status_for` divergence (scope B — it is
  a performance change, not a cleanup; deferred and documented inline instead).
- No runtime dependency additions. The test harness is dependency-free, pure-bash, and
  dev-only. (BATS was considered and rejected — see Council review; a ~30-line assert harness
  for these few pure functions is smaller than vendoring/maintaining BATS.)

## 1. Test harness (`tests/`)

Pure-bash assertion harness — zero dependencies, matching the project's deliberate
dependency-light, bash 3.2-safe ethos. Contributors run tests without installing anything.

- `tests/_assert.sh` — helpers: `assert_eq`, `expect`, a pass/fail counter, non-zero exit on
  any failure.
- `tests/run.sh` — runs every `tests/test_*.sh`. **Each test file is sourced inside its own
  subshell** (`( . "$f" )`) so globals/functions cannot leak between files. Exits non-zero on
  failure. Note (debate): an in-memory pass/fail counter cannot cross the subshell boundary —
  the summary is therefore either **file-level** (per-file exit codes) or backed by a temp
  file each subshell appends a result line to. Pick the temp-file counter so the summary can
  report assertion counts, not just file pass/fail.

### Test isolation & determinism (required for every test)

- `set -u` in the harness; each test file gets a fresh `mktemp -d` workspace with a `trap`
  teardown so fixtures (temp `.git` files, `.claude/` dirs, symlinks, state files) never
  pollute the developer's machine or repo.
- **No wall-clock dependence.** Time-sensitive functions (`_ago`, `_status_for`) are called
  with an explicit `now` argument; tests never read the real clock.
- **Deterministic mtimes.** Fixture transcript/state files have their mtime set explicitly.
  Use a portable helper (GNU `touch -d @<epoch>` vs BSD `touch -t`) — do not rely on one
  platform's `touch` flags.

### Coverage targets

**Pure functions (table-driven):**

- **`_status_for`** (highest value) — table over `(hook_status, hook_updated, tx_mtime,
  now) -> expected`:
  - `working` / `background` trusted unconditionally (no transcript demotion).
  - `waiting` -> `working` flip once the transcript progresses past the Notification epoch.
  - `waiting` stays `waiting` while the transcript has not progressed.
  - fresh `done` is **not** re-promoted to `working` by post-Stop transcript writes.
  - stale-hook transcript-freshness windows: `<5s`, `<10s`, `<12s` -> `working`; older with
    a transcript -> `done`; no transcript -> `idle`.
- **`_proj_sub`** — all branches, each with a `mktemp -d` fixture:
  - Claude-managed worktree path (`.../<project>/.claude/worktrees/<wt>`).
  - linked worktree (`.git` is a file containing `gitdir:`).
  - plain repo + subfolder (`.git` is a dir).
  - no-repo fallback (nearest folder name, empty subfolder).
  - paths containing spaces.
- **`_ago`** — boundaries: 59s, 60s, 3599s, 3600s, 86399s, 86400s.
- **`_title_of`, `_last_user_prompt`, `_last_assistant_ends_with_question`** — fed synthetic
  `.jsonl` fixtures under `tests/fixtures/`. These functions **already accept the transcript
  path as `$1`** (verified), so no refactor is needed to inject fixtures. Fixtures include a
  **malformed / truncated trailing line** (Claude transcripts are append-in-progress) to
  assert the `fromjson?` guard degrades gracefully. The jq-absent path is covered by a
  dedicated CI leg (below), not by local skips alone.

**State writer (new — council finding):**

- **`hooks/inbox-hook.sh`** is the single source of truth for the state-file format. Add a
  contract test: feed synthetic hook JSON payloads on stdin for each event
  (`SessionStart`/`source=compact`, `UserPromptSubmit`, `Notification`/`idle_prompt`,
  `Stop` with and without running `background_tasks`, `SessionEnd`) and assert the written
  state line shape (`<status> <epoch> <event> <tpath>`) and the same-status epoch-stability
  behavior. This guards against reader/writer format drift (tests-pass-but-plugin-fails).
  `TMUX_PANE` and `$CACHE` are pointed at the temp workspace; the ownership-lock parent walk
  is out of scope (needs live process state).

**Discovery (new — council finding):**

- **`claude_panes`** — mock `ps` and `tmux` via 5-line shims prepended to `$PATH`, feeding a
  synthetic process tree + pane map; assert it resolves candidate claude PIDs to the correct
  owning pane and excludes agent-view/daemon/`--bg`/sub-commands. This is the backbone of
  discovery and is cheaply mockable, so it is no longer treated as an untestable gap.

**Integration / golden test (new — debate's biggest-gap finding):**

- **`build_list`** — the assembled output is the real user-visible surface where status
  presentation, rank sorting, dimming, path columns, stale pruning, and formatting all meet,
  and it is the only place the approved `inbox-next.sh` rank change and the `_status_presentation`
  refactor are observable end-to-end. Add a golden test: a `mktemp -d` workspace with
  synthetic `$CACHE/pane-*` state files + fixtured pane metadata (via the same `tmux`/`ps`
  PATH shims as the discovery test) + fixtured transcripts, run `build_list`, and assert the
  exact emitted rows — group headers, rank order, icons, dim markers, and column alignment.
  Run it for each view mode (`state`/`session`/`flat`). This is the single most valuable test
  for catching regressions from the de-dup refactors.

### Remaining acknowledged gap

The `inbox-kill.sh` awk process-tree walk and the hook's `_is_subagent` parent walk are not
unit-tested (live-process state, low marginal value once `claude_panes` is covered by shims).
Noted in `tests/run.sh` output.

## 2. De-duplications (single-source in `lib/common.sh`)

- **status -> presentation.** Add `_status_presentation <status>` that **echoes a single
  tab-delimited line** `rank<TAB>icon<TAB>label<TAB>dim`, consumed by callers via
  `IFS=$'\t' read -r rank icon label dim <<< "$(_status_presentation "$s")"`. `build_list`
  (`common.sh:301-307`) and `inbox-preview.sh` (`inbox-preview.sh:60-66`) both consume it,
  removing the copied case block and guaranteeing popup and preview never drift.
  - Rationale (debate, reversing the v2 global-var decision): v2 proposed setting globals
    `_RET_*` to dodge `read`'s space-splitting. But `build_list`'s per-pane loop runs inside a
    pipeline subshell (`printf | while ...; done | sort | awk`), so a global-var return is a
    footgun — it happens to work at this call site (globals persist within the same subshell
    iteration) but silently breaks for any future `x=$(_status_presentation ...)` caller. The
    space-splitting objection that motivated globals is fully solved by `IFS=$'\t' read`
    (only tab is a separator, so labels with spaces survive and empty trailing fields are
    fine). This also matches the file's existing idiom — `build_list` already calls 5-6
    helpers via `$(...)` per iteration.
  - The helper **must assign all four fields on every code path**, including the unknown/
    default status, so no stale or empty value can leak.
  - The status->rank mapping and the rank ordering are **documented as an explicit contract**
    in a comment block above the helper (single canonical order).

- **Prune loop.** `build_list` (`common.sh:266-273`) re-implements the prune loop from
  `prune_dead()` (`common.sh:69-80`). Extract one helper with a defined contract: it takes
  the **live pane-id set as a single newline-delimited string argument** (pane ids only — no
  paths, no metadata, so whitespace in cwd cannot corrupt it; bash 3.2 has no namerefs, so no
  array passing). It removes `$CACHE/pane-*` files whose id is absent from the set. Both
  `prune_dead()` and `build_list` call it; `build_list` passes its already-computed live set
  so no second `claude_panes` invocation is added.
  - **Matching must be exact-line anchored** (debate, Codex). The existing code uses a
    space-padded glob (`case " $live " in *" $fid "*)`) which already prevents the `%1` vs
    `%10` collision; the newline-delimited helper must preserve that anchoring — use
    `grep -qx "$fid"` or a per-line `case`, **never** a substring `grep`/glob that could match
    `1` inside `10`.

- **Rank inconsistency fix.** `inbox-next.sh` (`inbox-next.sh:14-19`) ranks
  `background=1, done=2`; the popup ranks `done=1, background=2`. Align `inbox-next.sh` to the
  popup order — **waiting -> done -> background** — by deriving its rank from
  `_status_presentation` (`inbox-next.sh` already sources `lib/common.sh`, so no new
  dependency). Rationale (council, unanimous after debate): `done` = agent idle and blocked on
  the user = the actual workflow bottleneck; `background` is still progressing on its own, and
  jumping to it first interrupts active work. **This changes next-jump order (approved):**
  background now comes after done. The semantic contract is documented alongside
  `_status_presentation`.

## 3. Lint + CI

- `.shellcheckrc` — note: shellcheck has **no bash-3.2 dialect**; it offers `-s bash`
  (assumes modern bash). bash-3.2 safety is enforced by (a) running the real test/lint suite
  under bash 3.2 in CI where feasible, and (b) targeted `# shellcheck disable=` directives for
  the intentional portability idioms. Running `shellcheck -s bash` is itself the safety net
  that catches accidental bash-4+ features (associative arrays, namerefs) that would break
  macOS.
- `tests/lint.sh` — run `shellcheck -s bash` over `lib/`, `scripts/`, `hooks/`. **Lint is the
  gate; fixes are scoped.** Only behavioral fixes to files touched by this pass are applied
  and reviewed individually; pre-existing findings in untouched files may be silenced with
  directives or left as reported warnings rather than rewritten en masse (avoids an unbounded
  refactor that could itself regress quoting/globbing).
- `.github/workflows/ci.yml` — minimal GitHub Actions on push/PR:
  - lint leg: install shellcheck, run `tests/lint.sh`.
  - test leg: run `tests/run.sh`.
  - **jq matrix:** one leg with `jq` installed, one with `jq` masked from `$PATH`, so both the
    jq and jq-fallback code paths are exercised. The masked leg must also defeat shell command
    hashing (run `hash -r`, or run tests in a fresh shell) — otherwise a previously-hashed
    `jq` path is still found and the fallback never executes (debate, Codex).
  - run the test leg under a real **bash 3.2** where the runner image allows; otherwise
    document that 3.2 is validated locally on macOS and CI validates behavior on modern bash.

## Files

**New:**
- `tests/_assert.sh`
- `tests/run.sh`
- `tests/test_status.sh` (`_status_for`)
- `tests/test_paths.sh` (`_proj_sub`)
- `tests/test_misc.sh` (`_ago`, title/prompt/question helpers)
- `tests/test_hook.sh` (`inbox-hook.sh` writer contract)
- `tests/test_discovery.sh` (`claude_panes` via PATH shims)
- `tests/test_build_list.sh` (`build_list` golden/integration test, all view modes)
- `tests/fixtures/*.jsonl` (incl. a malformed-trailing-line fixture)
- `tests/lint.sh`
- `.shellcheckrc`
- `.github/workflows/ci.yml`

**Edited:**
- `lib/common.sh` — add `_status_presentation` (tab-echo return, consumed via
  `IFS=$'\t' read`), extract the prune helper (newline-delimited, exact-line-anchored
  pane-id contract).
- `scripts/inbox-preview.sh` — use `_status_presentation`.
- `scripts/inbox-next.sh` — use `_status_presentation` rank + apply the rank fix.
- `scripts/inbox-status.sh` — one-line comment noting the intentional raw-count divergence.

## Success criteria

- `tests/run.sh` passes (green) locally and in CI, including the writer-contract,
  `claude_panes` shim, **`build_list` golden** tests, and the malformed-fixture case.
- `_status_presentation` returns via tab-echo (no `_RET_*` globals); every call site uses
  `IFS=$'\t' read`.
- `shellcheck -s bash` is clean (or intentionally directive-silenced) across `lib/`,
  `scripts/`, `hooks/`; no en-masse behavioral rewrites of untouched files.
- Both the jq and jq-absent CI legs pass.
- Popup, preview, and status-line behavior unchanged **except** the deliberate next-jump rank
  fix (background after done).
- No new runtime dependencies.

## Council review (2026-05-29)

Adversarial deep council — claude (chair, code-reviewer), codex (red-team), gemini
(pragmatic maintainer). Two rounds (independent advice + cross-critique/revision).

- **Resolved in favor of this spec:** done-before-background rank order (both members
  conceded after debate); pure-bash harness over BATS (chair + codex; see dissent below).
- **Folded in as revisions:** global-var return for `_status_presentation`; writer-contract +
  `claude_panes` shim tests; test isolation/determinism + jq matrix + malformed fixture;
  shellcheck scoping and bash-3.2-dialect correction; explicit prune data-passing contract.
- **Corrected (adversary claims that were factually wrong):** fixture injection is possible
  (functions already take `tp="$1"`); `inbox-next.sh` already sources `common.sh` (no new
  cost); the per-pane subshell cost is marginal (`build_list` already does 5-6 substitutions
  per pane).
- **Minority report (unresolved):** gemini dissents on the harness choice, arguing BATS is a
  dev-only, bash-3.2-compliant, vendorable dependency and the hand-rolled runner is NIH. The
  author chose pure-bash deliberately; recorded as dissent.
- **Final confidence:** members at MEDIUM (gemini up from LOW after corrections); chair
  assesses MEDIUM-HIGH with the above revisions folded in.

## Debate review (2026-05-29) — v2 → v3

4-way adversarial debate (2 rounds): gemini, codex, sonnet (round 1), claude/opus
(moderator). It reviewed the council-revised spec (v2) and **reversed one v2 decision**:

- **`_status_presentation` return mechanism reverted:** v2's `_RET_*` global-var return is a
  footgun (`build_list`'s per-pane loop is inside a pipeline subshell). v3 ships tab-echo +
  `IFS=$'\t' read` instead — which also solves the council's original space-splitting concern.
  Unanimous after round 2.
- **Added the `build_list` golden/integration test** — the debate's consensus "biggest gap":
  the assembled output is the only place the refactors + rank change are observable.
- **Prune matching must be exact-line anchored** (`grep -qx`), preserving the existing
  `%1`-vs-`%10` safety.
- **`_status_presentation` must init all four fields on every path**; **jq-masked CI leg must
  `hash -r`**; **subshell-per-file harness counter** must use a temp file, not an in-memory var.
- **Effort:** sonnet's grounded estimate ~7–8 days (the "pass" framing under-sells it).
- **Confidence with v3 fixes:** HIGH (both external advisors); chair concurs.
- Transcript: `~/.claude-octopus/debates/local/001-maintainability-spec-review/`.
