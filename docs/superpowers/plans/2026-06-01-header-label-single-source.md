# Header Label Single-Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `build_list`'s popup group-header labels flow from `_status_presentation` instead of a hardcoded copy in awk, eliminating the last status→label drift point.

**Architecture:** Behavior-preserving refactor. `build_list` already computes the label via `_status_presentation` and discards it (`_lbl`). Keep it, emit it as an extra row field, and have the awk header read it in `state` mode — deleting the `if (gk[i]=="0")…"Needs input"` map. Output is byte-identical; the existing golden test (`tests/test_build_list.sh`) is the regression net, plus one new assertion that pins header text to the helper so the two can never drift again.

**Tech Stack:** Bash 3.2 (macOS `/bin/bash` is 3.2.57), `awk`, the pure-bash test harness in `tests/`. No new dependencies.

**Reference spec:** `docs/superpowers/specs/2026-06-01-header-label-single-source-design.md`

---

## File Structure

**Modified files**
- `lib/common.sh` — `build_list`: keep the helper's `label` (`:325`), emit it as a 10th row field (`:340-342`), consume it in the awk header and delete the hardcoded label map (`:344-373`).
- `tests/test_build_list.sh` — add a contract assertion tying the rendered header to `_status_presentation`.

No new files. No interface changes outside `build_list`'s internal row format (an awk-only contract; nothing else reads these rows).

---

## Note on TDD here

This is a refactor that changes **no visible output**. There is therefore no red-first test for the change itself — the discipline is the inverse: the golden test (`test_build_list.sh`) and the new contract assertion must stay **green through every step**. If either goes red mid-refactor, the refactor altered behavior — stop and reconcile. Task 1 adds the contract assertion (green now, documenting the current contract); Task 2 performs the refactor under that net.

---

## Task 1: Add the header-label contract assertion

**Files:**
- Modify: `tests/test_build_list.sh` (append after the existing assertions, currently ending around `:553`)

- [ ] **Step 1: Read the current end of the test to find the insertion point**

Run: `grep -n 'exactly one pane row' tests/test_build_list.sh`
Expected: one match (the last existing assertion line). Append the new assertion immediately after it. The variable `out` (set earlier as `out="$(build_list | strip_ansi)"`) is in scope there.

- [ ] **Step 2: Append the contract assertion**

Add to the end of `tests/test_build_list.sh`:

```bash
# Header label must flow from _status_presentation, not a hardcoded awk copy.
# Green before and after the single-source refactor: it pins the contract so the
# helper's label and the rendered group header can never drift apart again.
# field 3 of _status_presentation = label; working has a plain (ANSI-free) icon.
wlabel="$(_status_presentation working | cut -f3)"
printf '%s' "$out" | grep -qF "$wlabel (1)"
assert_rc 0 "$?" "build_list: state header label sourced from _status_presentation"
```

- [ ] **Step 3: Run the suite and verify the new assertion is GREEN**

Run: `bash tests/run.sh`
Expected: `0 failed`; failures section `(none)`. The assertion passes against current code because awk currently emits the same literal (`Working`) that the helper produces — that is exactly the contract being pinned. If it FAILs, confirm `_status_presentation working | cut -f3` prints `Working` and that the golden test's single working pane yields a `Working (1)` header.

- [ ] **Step 4: Commit** (see "Commits" note at the end of this plan before running)

```bash
git add tests/test_build_list.sh
git commit -m "test: pin build_list header label to _status_presentation"
```

---

## Task 2: Single-source the header label in `build_list`

**Files:**
- Modify: `lib/common.sh:285` (add `label` to the loop's `local` declaration)
- Modify: `lib/common.sh:325` (keep the label instead of discarding it)
- Modify: `lib/common.sh:340-342` (emit `label` as the 10th row field + update the comment)
- Modify: `lib/common.sh:344-373` (capture and use the label in awk; delete the hardcoded map)

- [ ] **Step 1: Add `label` to the loop locals**

In `build_list`, change the second `local` line (`lib/common.sh:285`):

```bash
  local id sf hstatus hupdated cur_tx tx_mtime status updated rank icon desc vis gkey wkey
```
to:
```bash
  local id sf hstatus hupdated cur_tx tx_mtime status updated rank icon label desc vis gkey wkey
```

- [ ] **Step 2: Keep the helper's label instead of discarding it**

Change `lib/common.sh:325`:

```bash
    IFS=$'\t' read -r rank icon _lbl dim <<< "$(_status_presentation "$status")"
```
to:
```bash
    IFS=$'\t' read -r rank icon label dim <<< "$(_status_presentation "$status")"
```

- [ ] **Step 3: Emit `label` as the 10th row field**

Change `lib/common.sh:340-342` from:

```bash
    # raw fields: gkey  wkey  pane_id  dim  icon  project  subfolder  message  time
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$gkey" "$wkey" "$pid" "$dim" "$icon" "$proj" "$sub" "$desc" "$agostr"
```
to:
```bash
    # raw fields: gkey  wkey  pane_id  dim  icon  project  subfolder  message  time  label
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$gkey" "$wkey" "$pid" "$dim" "$icon" "$proj" "$sub" "$desc" "$agostr" "$label"
```

- [ ] **Step 4: Capture the label in awk and use it for the header; delete the hardcoded map**

Change the awk block (`lib/common.sh:344-373`). Capture `lblf[NR]=$10` in the per-line action, and replace the `if (mode=="state") { if (gk[i]=="0") … }` chain with a single ternary.

Replace:
```awk
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
              else if (gk[i]=="2") lbl="Background"
              else if (gk[i]=="3") lbl="Working"
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
```
with:
```awk
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

- [ ] **Step 5: Run the full suite — golden test + contract assertion must stay GREEN**

Run: `bash tests/run.sh`
Expected: `0 failed`; failures `(none)`. The golden test proves the assembled output (headers, icons, rank order, columns) is unchanged across all three view modes; the Task 1 assertion proves the header now flows from `_status_presentation`. If the golden test goes red, the refactor altered visible output — re-check Step 3 (field count must be exactly 10) and Step 4 (`$10` index).

- [ ] **Step 6: Verify the hardcoded map is gone and no label is discarded**

Run: `grep -n 'Needs input' lib/common.sh`
Expected: exactly one match — the `_status_presentation` definition line (`waiting) … label="Needs input"`). No match inside `build_list`/awk.

Run: `grep -n '_lbl' lib/common.sh`
Expected: no output (the discarded throwaway is gone).

- [ ] **Step 7: (If shellcheck installed) lint stays clean**

Run: `bash tests/lint.sh; echo "rc=$?"`
Expected: `rc=0` (clean, or the "shellcheck not installed — skipping" line locally).

- [ ] **Step 8: Commit** (see "Commits" note below)

```bash
git add lib/common.sh
git commit -m "refactor: single-source popup header labels via _status_presentation"
```

---

## Final verification

- [ ] **Run the complete suite**

Run: `bash tests/run.sh`
Expected: `0 failed`, failures section `(none)`.

- [ ] **Confirm no hardcoded label map remains**

Run: `grep -nE 'Completed|Background|Needs input' lib/common.sh`
Expected: matches only inside the `_status_presentation` function body — none inside the awk block.

- [ ] **Confirm behavior parity in a live tmux session** — install hooks, open the popup (`prefix + I`), confirm the group headers still read `Needs input` / `Completed` / `Background` / `Working` / `Idle` with correct counts; cycle views (`ctrl-s`) through `state` → `session` → `flat` and confirm session headers show session names and flat has no headers.

---

## Notes for the executor

- **Bash 3.2 only.** The awk ternary (`mode=="state" ? lblf[i] : gk[i]`) is POSIX awk and fine. No bash 4+ features introduced.
- **The golden test is the regression guard.** It must stay green through Task 2. A red golden test means visible output changed — stop and reconcile rather than adjusting the test.
- **Field count is load-bearing.** The row printf must emit exactly 10 tab-separated fields and awk must read the label from `$10`. An off-by-one here silently blanks the headers.
- **Commits:** this plan commits per task. Per repo convention and the user's global rule, the user has NOT authorized commits for this session — get an explicit go-ahead before running the first `git commit`. If commits are declined, complete the edits and leave them staged/unstaged for the user to commit.
