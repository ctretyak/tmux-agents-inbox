# Last-paragraph question detection — design

**Date:** 2026-06-01
**Scope:** Status classification — broaden the done→needs-input escalation
**Status:** Draft for review

## Goal

A finished turn whose last message **asks a question** should land in **Needs input**, not
**Completed**. Claude Code fires `Stop` both when a turn finishes and when the agent asks a
plain-text question (no `Notification`), so the inbox already escalates `done`/`background`
rows to `waiting` when the last assistant message looks like a question. That escalation is
wired at `lib/common.sh:338-341` and `scripts/inbox-preview.sh:55-58`, backed by
`_last_assistant_ends_with_question` (`lib/common.sh:139-154`).

The current detector is too strict: it requires the **entire last text block to end with
`?`** (after stripping trailing whitespace). Sessions where the question sentence sits in
the last paragraph but the paragraph does **not** end on the `?` slip through to Completed.
Observed case:

```
Should I proceed? Let me know your thoughts.
```

The `?` is mid-paragraph, the paragraph ends on `.`, so the row is misclassified as
Completed even though the agent is clearly waiting on the user.

This pass broadens the rule from "message ends with `?`" to "**any sentence in the last
paragraph ends with `?`**", and renames the helper to match its new contract.

## Non-goals

- No change to how the last message is **fetched.** Reading the transcript tail and pulling
  the last assistant text block out with `jq` is the existing mechanism and stays as-is —
  only the **evaluation** of that text changes. (Claude Code persists each session's
  conversation as a JSONL transcript on disk; that file is the only place the "last message"
  exists, so reading it is unavoidable plumbing, not new behavior.)
- No change to the escalation call sites' structure — both still call one helper and set
  `status="waiting"` on a truthy result.
- No change to the other states, the `_status_for` state machine, or any presentation.
- No new runtime dependencies. Bash 3.2, `jq` (with the existing jq-free fallback), and
  POSIX `awk` only — no GNU-only awk features (notably no regex `RS`).

## Approach

**Broaden the single existing helper and rename it (one source of truth).**

Both call sites want identical new behavior, so keeping one helper is correct. Because the
contract changes from "ends with a question" to "asks a question (anywhere in the last
paragraph)", the name `_last_assistant_ends_with_question` would lie. Rename to
**`_last_assistant_asks_question`** and update both call sites, the tests, and the README
caveat.

### Detection logic

Two parts; only part 2 changes.

1. **Fetch (unchanged):** tail-read the transcript, and with `jq` select the last
   user/assistant record and emit the base64 of the last assistant **text** block (empty for
   a user record). `tail -1 | base64 -d`. If the decoded result is empty — i.e. the most
   recent record is a **user** message — the question was already answered → return 1. This
   preserves today's "answered" guard exactly.

2. **Evaluate (changed):** from the decoded text, isolate the **last paragraph** (the last
   blank-line-separated block) and escalate if it contains a **sentence-final `?`** — a `?`
   followed by whitespace or end-of-paragraph. One portable awk pass does both:

   ```sh
   printf '%s\n' "$decoded" \
     | awk '/^[[:space:]]*$/ { if (cur != "") last = cur; cur = ""; next }
            { cur = cur $0 "\n" }
            END { p = (cur != "" ? cur : last); exit (p ~ /\?[[:space:]]/) ? 0 : 1 }'
   ```

   - `cur` accumulates the current paragraph; a blank line stashes it into `last` and
     starts a new one. At `END` the evaluated paragraph is `cur` (or `last` if the message
     ended on trailing blank lines), so it holds **only the last non-empty paragraph** —
     matching the "last paragraph" rule, not the whole message.
   - Each line is stored with a trailing `\n`, so a paragraph-final `?` becomes `?\n` and
     matches `\?[[:space:]]` alongside a mid-paragraph `? `. One pattern covers both
     "ends with `?`" and "question sentence in the middle".
   - This naturally **excludes** non-sentence `?`: `?.` (optional chaining), `?=`, `?:`,
     and query strings like `?a=b` — none are followed by whitespace.

### Why last paragraph, not whole message

Restricting to the last paragraph keeps the false-positive surface small: a question in an
earlier paragraph followed by a final paragraph that states an action
(`"Should I proceed?\n\nProceeding now."`) is **not** escalated — the agent has moved on.
The user's reported case (question sentence within the final paragraph) is covered; the
"already-decided" case is not falsely escalated.

### jq-free fallback (unchanged)

Without `jq` the helper returns 1 and the row stays `done`. Same as today; consistent with
the other transcript helpers.

## Known limitation (accepted)

Broadening from "ends with `?`" to "any sentence in the last paragraph" admits some false
positives: a rhetorical question or an inline ternary (`a ? b : c`) appearing in the
**final** paragraph would escalate to Needs input. The last-paragraph restriction bounds
this; it is the intended trade for catching real mid-paragraph questions. Best-effort
classification is already documented in the README's "Done vs needs-input" caveat.

## Files

**Edited:**
- `lib/common.sh` — rename `_last_assistant_ends_with_question` →
  `_last_assistant_asks_question` (`:139-154`); replace the `case "$last" in *\?)` check
  with the last-paragraph awk pass; update the function's doc comment and the
  `_last_user_prompt` "Mirrors …" comment (`:158`). Update the escalation call site
  (`:340`).
- `scripts/inbox-preview.sh` — update the call site (`:57`).

**Edited (test):**
- `tests/test_misc.sh` — rename the existing assertions to the new helper name; add
  coverage for the broadened rule.

**Added (fixtures):**
- `tests/fixtures/midquestion.jsonl` — last paragraph contains a non-terminal question
  sentence (`"Should I proceed? Let me know your thoughts."`).
- `tests/fixtures/decided.jsonl` — question in an earlier paragraph, final paragraph is a
  plain statement (`"Should I proceed?\n\nProceeding now."`).

**Edited (docs):**
- `README.md` — the "Done vs needs-input is best-effort" note (`:55-58`) still holds;
  adjust any wording that implies the detector only fires on a trailing `?` if present.

## Test plan

Extend `tests/test_misc.sh`. Existing fixtures keep passing under the new name; add the two
new cases. jq-present branch:

```bash
_last_assistant_asks_question "$F/question.jsonl";    assert_rc 0 "$?" "asks_question: trailing assistant '?' -> 0"
_last_assistant_asks_question "$F/midquestion.jsonl"; assert_rc 0 "$?" "asks_question: question sentence mid last paragraph -> 0"
_last_assistant_asks_question "$F/decided.jsonl";     assert_rc 1 "$?" "asks_question: question in earlier paragraph, last is plain -> 1"
_last_assistant_asks_question "$F/answered.jsonl";    assert_rc 1 "$?" "asks_question: user replied -> 1"
```

jq-absent branch asserts the fallback (rc 1) on `midquestion.jsonl`.

## Success criteria

- `tests/run.sh` passes (green), including the two new fixtures.
- `grep -n '_last_assistant_ends_with_question' lib/ scripts/ tests/` returns nothing — the
  rename is complete across all call sites and tests.
- A live `done` session whose last paragraph reads `"Should I proceed? Let me know."`
  renders under **Needs input** in the popup and the preview status line.
- A `done` session whose last paragraph is a plain statement still renders under
  **Completed**.
- `shellcheck -s bash` stays clean.
- No new runtime dependencies.
