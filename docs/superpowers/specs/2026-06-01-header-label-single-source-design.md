# Header label single-source — design

**Date:** 2026-06-01
**Scope:** Code quality / de-dup follow-up to the maintainability pass
**Status:** Draft for review

## Goal

The maintainability pass single-sourced status→presentation in `_status_presentation`
(`lib/common.sh:267`) and rewired `build_list`'s per-pane row and `inbox-preview.sh` to
consume it. It **missed the popup group headers.** `build_list`'s awk `END` block
(`lib/common.sh:359-365`) re-derives the human labels from the numeric rank digit:

```awk
if      (gk[i]=="0") lbl="Needs input"
else if (gk[i]=="1") lbl="Completed"
else if (gk[i]=="2") lbl="Background"
else if (gk[i]=="3") lbl="Working"
else                 lbl="Idle"
```

These five strings are an independent fourth copy of the `label` field that
`_status_presentation` already produces, coupled to the helper only by the unwritten
convention "rank 0 == Needs input". Rename a label in the helper and the popup headers
silently keep the old text. This is the exact popup-vs-presentation drift class the
maintainability pass set out to kill; it stopped at the row icons and left the headers.

Compounding it: `build_list` **already computes** the correct label and throws it away —
`lib/common.sh:325` reads it into `_lbl` and discards it. The discarded value is precisely
what the awk block re-derives by hand.

This pass routes the header label through `_status_presentation` so there is a single
source of truth, and adds a test assertion tying header text to the helper.

## Non-goals

- No change to visible output. Header text, icons, rank order, column alignment, dim
  markers, and all three view modes stay byte-identical. The golden test
  (`tests/test_build_list.sh`) is the regression guard.
- No change to `_status_presentation` itself, to the status state machine, or to
  `inbox-status.sh` (its glyph set is a deliberately separate compact presentation, not
  this map — see the maintainability spec, scope B).
- No new runtime dependencies. Bash 3.2 only.

## Approach

**Thread the helper's `label` through to the header (Approach A).**

`build_list` emits one tab-delimited row per pane and pipes it through `sort | awk`. The
awk `END` block prints a group header when a new group key starts. In `state` mode the
group key *is* the rank, and rank↔status↔label is bijective — so every row within a
state-mode group carries the identical label, and the header can simply use the label of
the first row in that group instead of looking it up from the rank digit.

In `session` mode the header is the session name (`lbl=gk[i]`) and multiple statuses share
a group, so there is no single status-label per group — that branch is unchanged. In
`flat` mode there are no headers. So the label-from-row only feeds the `state`-mode branch,
which is exactly where the hardcoded map lives today.

### Changes

1. **Stop discarding the label** (`lib/common.sh:325`). Rename `_lbl` → `label` in the
   `IFS=$'\t' read` so the value is kept.

2. **Add `label` as a row field** in the emitted line (`lib/common.sh:341-342`). Append it
   as the 10th field so existing awk field indices ($1–$9) and the `sort -k1,1 -k2,2` keys
   are untouched:

   ```bash
   # raw fields: gkey wkey pane_id dim icon project subfolder message time label
   printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
     "$gkey" "$wkey" "$pid" "$dim" "$icon" "$proj" "$sub" "$desc" "$agostr" "$label"
   ```
   Update the `# raw fields:` comment on `lib/common.sh:340` to include the new field.

3. **Capture and use it in awk** (`lib/common.sh:344-373`). Store the label per row
   (`lblf[NR]=$10`) alongside the other captured fields, and replace the hardcoded
   rank-digit chain with the row's label:

   ```awk
   {
     gk[NR]=$1; pid[NR]=$3; dim[NR]=$4; icon[NR]=$5
     proj[NR]=$6; sb[NR]=$7; msg[NR]=$8; tm[NR]=$9; lblf[NR]=$10; cnt[$1]++
     ...
   }
   END {
     ...
     if (mode!="flat" && (have==0 || gk[i]!=prev)) {
       lbl = (mode=="state" ? lblf[i] : gk[i])
       printf "__hdr__\t%s%s %s (%d) %s%s\n", cw, hr, lbl, cnt[gk[i]], hr, cr
       prev=gk[i]; have=1
     }
     ...
   }
   ```
   The `if (mode=="state") { if (gk[i]=="0") ... }` block is deleted entirely.

### Rejected alternative (Approach B)

Build a rank→label map in shell from `_status_presentation` (ranks 0–4) and pass it into
awk via `-v l0=... l1=...`. Rejected: awk still holds a parallel keyed structure (just
populated from outside), it adds five extra `_status_presentation` calls per `build_list`,
and it is strictly more code than letting the label ride along on the row that already
carries it.

## Files

**Edited:**
- `lib/common.sh` — keep the `label` field (`:325`), emit it as the 10th row field
  (`:340-342`), consume it in the awk header and delete the hardcoded label map
  (`:344-373`).

**Edited (test):**
- `tests/test_build_list.sh` — add an assertion that the rendered group header text is
  *derived from* `_status_presentation`, not a literal, so the two can never drift again.

## Test plan

The golden test stays green (output unchanged). Add one assertion that pins the header to
the helper rather than to a literal string:

```bash
# Header label must come from _status_presentation, not a hardcoded awk copy.
wlabel="$(_status_presentation working | cut -f3)"   # field 3 = label
printf '%s' "$out" | grep -qF "$wlabel (1)"
assert_rc 0 "$?" "build_list: state header label is sourced from _status_presentation"
```

Because the existing golden assertions already grep the literal `Working (1)`, the suite
proves both that the text is unchanged **and** that it now flows from the single source.

## Success criteria

- `tests/run.sh` passes (green), including the existing golden assertions and the new
  helper-sourced-header assertion.
- The `if (gk[i]=="0") ... ` hardcoded label chain no longer exists in `lib/common.sh`
  (`grep -n 'Needs input' lib/common.sh` returns only the `_status_presentation` line).
- `_lbl` is gone — the label read from the helper is used, not discarded
  (`grep -n '_lbl' lib/common.sh` returns nothing).
- Popup headers, row icons, rank order, and all three view modes render identically to
  before in a live tmux session.
- `shellcheck -s bash` stays clean.
- No new runtime dependencies.
