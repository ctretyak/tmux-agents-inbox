# Last-Paragraph Question Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Escalate a finished session to **Needs input** when its last message's last paragraph contains a question sentence — not only when the whole message ends with `?`.

**Architecture:** One helper in `lib/common.sh` reads the transcript tail, extracts the last assistant text block via `jq` (unchanged), then evaluates it with a single portable awk pass: isolate the last non-empty paragraph and escalate if it contains a `?` followed by whitespace or end-of-paragraph. The helper is renamed to reflect its broadened contract; both call sites and the tests follow the rename.

**Tech Stack:** Bash 3.2, `jq` (with jq-free fallback), POSIX `awk`. No new dependencies.

---

## Background for the implementer

- **Where the text lives.** Each Claude Code session's conversation is persisted as a JSONL transcript file (one JSON record per line). The "last message" only exists there, so the helper reads the tail of that file and pulls the last assistant text out with `jq`. This fetch is the *existing* mechanism — you are not changing it.
- **Current behavior.** `_last_assistant_ends_with_question` (`lib/common.sh:139-154`) decodes the last assistant text block, strips trailing whitespace, and returns 0 only if it ends with `?`. The escalation happens at `lib/common.sh:338-341` (popup list) and `scripts/inbox-preview.sh:55-58` (preview status line): a `done`/`background` row whose helper returns 0 becomes `waiting`, which renders as **Needs input**.
- **What changes.** Only the *evaluation*: from "message ends with `?`" to "any sentence in the **last paragraph** ends with `?`". Because the contract changes, the helper is renamed `_last_assistant_ends_with_question` → `_last_assistant_asks_question`.
- **Test harness.** `tests/run.sh` sources each `tests/test_*.sh` in its own subshell and prints `N passed, M failed`. Assertions use `assert_rc <expected_rc> <actual_rc> <msg>` and `assert_eq`. Fixtures live in `tests/fixtures/*.jsonl`. A test for a transcript helper feeds it a fixture path and asserts the return code.
- **The awk rule, line by line:**
  ```awk
  /^[[:space:]]*$/ { if (cur != "") last = cur; cur = ""; next }  # blank line: stash & reset
  { cur = cur $0 "\n" }                                          # content line: append (with \n)
  END { p = (cur != "" ? cur : last); exit (p ~ /\?[[:space:]]/) ? 0 : 1 }
  ```
  `p` is the last non-empty paragraph. Appending `\n` per line makes a paragraph-final `?` match `\?[[:space:]]` (the newline counts as whitespace), so one pattern covers both mid-paragraph (`? `) and end-of-paragraph (`?\n`) questions. `?.`, `?=`, `?:`, and query strings like `?a=b` are not followed by whitespace, so they don't match.

---

## Task 1: Add fixtures and rewrite the tests for the new contract (red)

This task writes the new fixtures and switches the test block to the renamed helper with the two new cases. The helper does not exist under the new name yet, so the tests fail — that is the red state.

**Files:**
- Create: `tests/fixtures/midquestion.jsonl`
- Create: `tests/fixtures/decided.jsonl`
- Modify: `tests/test_misc.sh:38-49`

- [ ] **Step 1: Create `tests/fixtures/midquestion.jsonl`**

Last assistant paragraph has a question sentence that is **not** at the end of the paragraph (the user's reported case).

```json
{"type":"user","message":{"content":"do the thing"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Should I proceed? Let me know your thoughts."}]}}
```

- [ ] **Step 2: Create `tests/fixtures/decided.jsonl`**

Question lives in an **earlier** paragraph; the last paragraph is a plain statement. Locks the "last paragraph only" boundary. The `\n\n` inside the JSON string becomes two real newlines (a blank line) after `jq` decodes it.

```json
{"type":"user","message":{"content":"do the thing"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Should I proceed?\n\nProceeding now."}]}}
```

- [ ] **Step 3: Rewrite the test block in `tests/test_misc.sh`**

Replace lines 38-49 (the comment plus the whole `if … else … fi`) with the version below. It renames every reference to `_last_assistant_asks_question` and adds the `midquestion`/`decided` assertions.

```bash
# _last_user_prompt and _last_assistant_asks_question require jq; assert the
# jq path when present, otherwise assert the documented no-jq fallback (empty / rc 1).
if command -v jq >/dev/null 2>&1; then
  assert_eq "hello there friend" "$(_last_user_prompt "$F/title.jsonl")" "_last_user_prompt: last user text"
  assert_eq "a real prompt here" "$(_last_user_prompt "$F/malformed.jsonl")" "_last_user_prompt: malformed tail ok"

  _last_assistant_asks_question "$F/question.jsonl";    assert_rc 0 "$?" "asks_question: trailing assistant '?' -> 0"
  _last_assistant_asks_question "$F/midquestion.jsonl"; assert_rc 0 "$?" "asks_question: question sentence mid last paragraph -> 0"
  _last_assistant_asks_question "$F/decided.jsonl";     assert_rc 1 "$?" "asks_question: question in earlier paragraph, last is plain -> 1"
  _last_assistant_asks_question "$F/answered.jsonl";    assert_rc 1 "$?" "asks_question: user replied -> 1"
else
  assert_eq "" "$(_last_user_prompt "$F/title.jsonl")" "_last_user_prompt: no-jq returns empty (fallback)"
  _last_assistant_asks_question "$F/midquestion.jsonl"; assert_rc 1 "$?" "asks_question: no-jq returns 1 (fallback)"
fi
```

- [ ] **Step 4: Run the suite and verify the new assertions fail**

Run: `bash tests/run.sh 2>&1 | grep -E 'asks_question|test_misc'`
Expected: the `asks_question:` lines report `FAIL` (the function `_last_assistant_asks_question` is undefined, so `$?` is 127, not the expected 0/1). This confirms the tests exercise the not-yet-renamed helper.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/midquestion.jsonl tests/fixtures/decided.jsonl tests/test_misc.sh
git commit -m "test: cover last-paragraph question detection (red)"
```

---

## Task 2: Rename and broaden the helper (green)

**Files:**
- Modify: `lib/common.sh:133-154` (the helper and its doc comment)
- Modify: `lib/common.sh:158` (the `_last_user_prompt` "Mirrors …" comment that names the old helper)

- [ ] **Step 1: Replace the helper and its doc comment**

Replace `lib/common.sh:133-154` (the comment block starting `# Does the latest user/assistant exchange end with…` through the closing `}` of `_last_assistant_ends_with_question`) with:

```bash
# Does the agent's last message ASK a question — i.e. does its LAST paragraph
# contain a question sentence? Used to escalate "done"/"background" rows to
# "waiting"; Claude Code fires no Notification for plain-text questions at
# end-of-turn. Looks at the LAST user-or-assistant record: a trailing user
# record means the question was already answered (decoded text empty -> no
# escalation). For an assistant record the rule is "any sentence in the last
# paragraph ends with '?'" — a '?' followed by whitespace or end-of-paragraph.
# Catches mid-paragraph questions ("Should I proceed? Let me know.") while
# excluding non-sentence '?' such as '?.', '?=', and query strings (none are
# followed by whitespace). Requires jq; without jq, returns 1 (status stays done).
_last_assistant_asks_question() {
  local tp="$1" decoded
  [ -n "$tp" ] && [ -f "$tp" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  decoded="$(tail -c "$_TITLE_TAIL" "$tp" 2>/dev/null \
    | jq -rR 'fromjson?
        | select(.type=="user" or .type=="assistant")
        | (if .type=="assistant"
             then ((.message.content | map(select(.type=="text") | .text) | last) // "")
             else "" end)
        | @base64' 2>/dev/null \
    | tail -1 \
    | base64 -d 2>/dev/null)"
  [ -n "$decoded" ] || return 1
  printf '%s\n' "$decoded" \
    | awk '/^[[:space:]]*$/ { if (cur != "") last = cur; cur = ""; next }
           { cur = cur $0 "\n" }
           END { p = (cur != "" ? cur : last); exit (p ~ /\?[[:space:]]/) ? 0 : 1 }'
}
```

- [ ] **Step 2: Fix the cross-reference comment in `_last_user_prompt`**

`lib/common.sh:158` reads `# Mirrors _last_assistant_ends_with_question: tail-only read, base64`. Change the name:

```bash
# Mirrors _last_assistant_asks_question: tail-only read, base64
```

- [ ] **Step 3: Run the suite — the new assertions now pass**

Run: `bash tests/run.sh 2>&1 | grep -E 'asks_question'`
Expected: all `asks_question:` lines report `PASS` (trailing `?` → 0, mid-paragraph question → 0, earlier-paragraph-only → 1, user-replied → 1).

- [ ] **Step 4: Commit**

```bash
git add lib/common.sh
git commit -m "feat: detect a question anywhere in the last paragraph"
```

---

## Task 3: Update the two escalation call sites

The popup list and the preview still call the old name; after Task 2 they reference an undefined function. Repoint both and refresh the popup comment that says "ended with a question".

**Files:**
- Modify: `lib/common.sh:334-341` (comment + call)
- Modify: `scripts/inbox-preview.sh:55-58` (call)

- [ ] **Step 1: Update the popup-list call site and its comment**

Replace `lib/common.sh:334-341` with:

```bash
    # Escalate "done"/"background" to "waiting" when the last assistant message
    # asks a question (any question sentence in its last paragraph) — Claude Code
    # fires no Notification for plain-text questions. Skipped if a more recent
    # user record means the question was already answered.
    case "$status" in
      done|background)
        _last_assistant_asks_question "$cur_tx" && status="waiting" ;;
    esac
```

- [ ] **Step 2: Update the preview call site**

In `scripts/inbox-preview.sh`, replace line 57:

```bash
    _last_assistant_ends_with_question "$cur_tx" && status="waiting" ;;
```

with:

```bash
    _last_assistant_asks_question "$cur_tx" && status="waiting" ;;
```

- [ ] **Step 3: Verify no reference to the old name survives**

Run: `grep -rn '_last_assistant_ends_with_question' lib scripts tests`
Expected: no output (exit 1). Every call site and test now uses `_last_assistant_asks_question`.

- [ ] **Step 4: Run the full suite and shellcheck**

Run: `bash tests/run.sh`
Expected: ends with `N passed, 0 failed`.

Run: `shellcheck -s bash lib/common.sh scripts/inbox-preview.sh`
Expected: no output (clean).

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh scripts/inbox-preview.sh
git commit -m "refactor: repoint escalation call sites to _last_assistant_asks_question"
```

---

## Task 4: Verify the README caveat still holds (idempotence check)

The "Done vs needs-input is best-effort" note (`README.md:55-58`) is generic and does not claim the detector fires only on a trailing `?`, so it likely needs no edit. Confirm this rather than assume.

**Files:**
- Modify (only if needed): `README.md:55-58`

- [ ] **Step 1: Re-read the caveat and check for trailing-`?` wording**

Run: `sed -n '55,58p' README.md`
Expected: a generic best-effort note about `Stop` covering both finished turns and plain-text questions. If no sentence implies "only when the message ends with `?`", make **no change** and skip to Task 5. If such wording exists, soften it to "asks a question" in Step 2.

- [ ] **Step 2 (only if Step 1 found trailing-`?` wording): edit and commit**

Adjust the offending sentence to describe "asks a question" without the trailing-`?` implication, then:

```bash
git add README.md
git commit -m "docs: align needs-input caveat with last-paragraph detection"
```

---

## Task 5: Final verification

- [ ] **Step 1: Full suite green**

Run: `bash tests/run.sh`
Expected: `N passed, 0 failed`.

- [ ] **Step 2: Lint clean**

Run: `bash tests/lint.sh`
Expected: no shellcheck findings (matches CI's lint gate).

- [ ] **Step 3: Manual smoke test in a live tmux session (optional but recommended)**

In a real Claude session, end a turn with a message whose last paragraph reads `Should I proceed? Let me know.` Open the inbox popup (`prefix` + the bound key). Expected: the row appears under **Needs input**, not **Completed**. End another turn with a plain statement → it stays under **Completed**.
