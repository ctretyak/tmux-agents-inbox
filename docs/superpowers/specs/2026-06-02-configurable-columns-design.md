# Configurable columns — design

**Date:** 2026-06-02
**Scope:** Feature — user-configurable popup columns (order, visibility, field selection)
**Status:** Draft for review (rev. 2 — incorporates four-way debate findings)

> **Revision 2** folds in an adversarial design debate (Codex / Gemini / Sonnet / Opus).
> Settled changes: (1) **dim-wrap fix** — the icon must render *outside* the dim-wrapped
> body or its embedded `C_RESET` cancels idle dimming (this is what actually preserves
> byte-identity, the rev-1 renderer did not); (2) unknown tokens emit a **warning header**
> instead of vanishing silently; (3) sanitize `\r\n` as well as `\t`; (4) multibyte
> `length()` is documented as a pre-existing known limitation with a skipped fixture;
> (5) reorder tests use **positional** assertions. The single unresolved point — whether
> `path` belongs in the v1 catalog — is resolved in favor of **keep, opt-in** (it was
> explicitly user-requested); a future per-column max-width setting is noted as the proper
> fix for unbounded width.

## Goal

The popup renders a fixed set of five columns in a hard-coded order — `icon`,
`project`, `subfolder`, `description`, `age` — assembled in `build_list`'s awk `END`
block (`lib/common.sh:383-398`). There is no way for a user to reorder them, hide one,
or surface other data the plugin already has (session, window, pane id, cwd).

This pass adds one tmux option, `@agents-inbox-columns`, holding an **ordered list of
column names**. List order is column order; an omitted name is a hidden column; only
catalog names are valid. When the option is unset the default reproduces today's output
byte-for-byte, so existing users see no change.

The work is two changes: (1) a small config resolver in shell, and (2) generalizing the
awk renderer from "three padded columns + icon prefix + unpadded age" to "N columns, each
auto-sized, last one unpadded." **Critically, the icon stays a raw prefix outside the
dim-wrap** (see §3) — folding it into the dim-wrapped body would let its embedded
`C_RESET` (`lib/common.sh:285`) terminate the dim mid-row, silently un-dimming idle rows,
a regression that `strip_ansi`-based golden tests cannot see.

## Non-goals

- **No change to default appearance.** Unset option → `icon project subfolder description
  age` → byte-identical to current output. The golden test (`tests/test_build_list.sh`) is
  the regression guard.
- **No column width configuration.** Every column stays auto-sized to its widest value, as
  today. No fixed/max-width or truncation knobs. Consequence: free-text columns are
  *unbounded* — this is the **existing contract** (`description` is already an unbounded
  default column). `path` inherits it and is the widest offender; it ships opt-in and
  documented as unbounded (§ Field catalog). A future `@agents-inbox-column-max-width`
  option is the proper fix for all free-text columns at once and is explicitly **deferred**,
  not designed here.
- **No per-column type/format options** (no date formats, no color overrides). The catalog
  fixes each field's rendering.
- **No new config file.** Configuration is a single tmux global option, matching every
  existing `@agents-inbox-*` setting. No JSON/YAML, no jq dependency.
- **No new data collection.** All ten field values already exist in `build_list`'s per-pane
  loop (the `meta` query at `lib/common.sh:316` already pulls session_name, window_index,
  window_name, pane_index, pane_current_path).
- **No change to navigation.** The hidden `pane_id` routing prefix (field 1 of each row,
  consumed by fzf / `jump_to`) is untouched and is independent of any visible `pane` column.
- Bash 3.2 only; no new runtime dependencies.

## Field catalog

Ten valid names. Each maps to a value **already computed** in `build_list`'s loop
(`lib/common.sh:331-373`):

| name | content | source variable | notes |
|---|---|---|---|
| `icon` | colored status symbol | `$icon` (`_status_presentation`) | only ANSI-bearing column; visible width always 1 |
| `project` | repo / nearest-folder name | `$proj` (`_proj_sub`) | |
| `subfolder` | worktree / subpath (empty at root) | `$sub` (`_proj_sub`) | |
| `description` | ai-title, fallback window name | `$desc` (`_title_of`) | |
| `age` | relative elapsed time ("5m", "-") | `$agostr` (`_ago`) | |
| `session` | tmux session name | `$sess` | from `meta` |
| `window` | tmux window name | `$wname` | from `meta`; overlaps `description` fallback |
| `window-index` | tmux window index number | `$win` | from `meta` |
| `pane` | pane id (`%12`) | `$pid` | from `meta`; distinct from the hidden routing prefix |
| `path` | pane working directory (cwd) | `$cwd` | from `meta`; full absolute path — **unbounded width, opt-in** (see Non-goals) |

**Default** (option unset): `icon project subfolder description age`.

The catalog is defined in exactly one place — a `_is_column` predicate (§1) — so the
resolver and the unknown-token warning (§4) share a single source of truth.

## Approach

### 1. Config resolver (shell)

The catalog lives in **one** predicate so the resolver and the warning scan can't drift:

```bash
# Single source of truth for valid column names.
_is_column() {
  case "$1" in
    icon|project|subfolder|description|age|session|window|window-index|pane|path) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve the ordered, validated column list. Unknown tokens are dropped (and surfaced
# separately as a warning — see §4); an empty or all-unknown list falls back to the
# default so the popup is never blank.
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

# Echo any tokens that are NOT valid column names (for the warning header).
_columns_unknown() {
  local raw out="" tok
  raw="$(tmux show -gqv '@agents-inbox-columns' 2>/dev/null)"
  for tok in $raw; do
    _is_column "$tok" || out="$out $tok"
  done
  printf '%s' "${out# }"
}
```

Word-splitting `$raw` on whitespace is intentional and bash-3.2 safe; the option is a
space-separated list.

### 2. Emit selected column values per row (shell)

`build_list` already computes every needed value. Replace the fixed 10-field row
(`lib/common.sh:371-373`) with a fixed **meta** prefix plus the resolved columns' values in
order. Keep `gkey`/`wkey` as fields 1–2 so the existing `sort -k1,1 -k2,2` is untouched, and
keep `pane_id`, `dim`, and `label` as meta fields (the routing prefix, the idle-dim flag, and
the state-mode header label respectively):

```bash
cols="$(_columns_config)"            # resolved once, before the per-pane loop
...
# per pane, after all values are computed:
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
  v="$(printf '%s' "$v" | tr '\t\r\n' '   ')"   # neutralize row/field separators
  row="$row"$'\t'"$v"
done
printf '%s\n' "$row"
```

`desc` is already tab-neutralized today (`lib/common.sh:359`). Generalize it: every value
gets `\t`, `\r`, **and** `\n` collapsed to spaces before it joins the row. The newline guard
matters now that more free-text fields (`window`, `path`, `session`, `description`) are
selectable — a stray newline in any of them would otherwise split one logical row in two and
corrupt the `sort | awk` pipeline. (Using `tr` keeps this bash-3.2 safe and covers all three
in one pass; `${v//$'\t'/ }` cannot strip `\n`.)

### 3. Generalize the awk renderer

Pass the resolved list into awk (`-v cols="$cols"`). awk splits it into `cn[1..N]`, treats
fields `$6..$(5+N)` as the N column values, sizes each column to its widest value, and renders
them two-space-separated with the last column unpadded.

**The icon must stay outside the dim-wrap.** Today (`lib/common.sh:396-397`) the dim color
brackets *only* the `proj…age` body; the icon is printed separately as a raw prefix. The icon
already carries its own color **and an embedded `C_RESET`** (`:285`: `${C_IDLE}✻${C_RESET}`).
If the icon is folded into the dim-wrapped string, that embedded reset fires mid-row and
**cancels the dim for every column after it** — idle rows silently lose their dimming, and the
`strip_ansi` golden test is blind to the difference. So the renderer dim-wraps each maximal
run of *non-icon* columns and emits the icon raw between runs. For the default (icon first)
this reduces to exactly today's "raw icon, then one dim-wrapped body":

```awk
BEGIN { ncol = split(cols, cn, " ") }
{
  gk[NR]=$1; pid[NR]=$3; dim[NR]=$4; lblf[NR]=$5; cnt[$1]++
  for (c=1; c<=ncol; c++) {
    val[NR,c] = $(5+c)
    if (cn[c]!="icon" && length($(5+c)) > w[c]) w[c] = length($(5+c))
  }
}
END {
  for (i=1;i<=NR;i++) {
    if (mode!="flat" && (have==0 || gk[i]!=prev)) {
      lbl = (mode=="state" ? lblf[i] : gk[i])
      printf "__hdr__\t%s%s %s (%d) %s%s\n", cw, hr, lbl, cnt[gk[i]], hr, cr
      prev=gk[i]; have=1
    }
    out=""; indim=0
    for (c=1; c<=ncol; c++) {
      sep = (c==1 ? "" : "  ")
      if (cn[c]=="icon") {                 # raw, never padded, never inside the dim span
        if (indim) { out=out cr; indim=0 } # close any open dim BEFORE the icon
        out = out sep val[i,c]
      } else {
        cell = (c==ncol ? val[i,c] : sprintf("%-*s", w[c], val[i,c]))
        if (dim[i]=="1" && !indim) { out = out sep dimc cell; indim=1 }  # open dim (sep stays outside)
        else                       { out = out sep cell }               # extend run / no dim
      }
    }
    if (indim) out=out cr               # close trailing dim span
    printf "%s\t%s\n", pid[i], out
  }
}
```

Why `icon` is special-cased twice (no padding, and dim-exclusion): it is the only column
carrying ANSI escapes. `length()`/`%-*s` would mis-measure its width (so it is emitted raw,
relying on its invariant 1-glyph visible width), and its embedded `C_RESET` would break a
surrounding dim span (so the dim is closed before it and reopened after).

**Default-output equivalence** (`cols="icon project subfolder description age"`):
- non-idle row → `icon  project_pad  subfolder_pad  description_pad  age` — character-identical
  to today's `printf "%s\t%s  %s", pid, icon, sprintf(fmt, …)`.
- idle row → `icon  ` + `dimc` + `project_pad  subfolder_pad  description_pad  age` + `cr` —
  the icon (raw, with its own color) precedes a single dim span over the body, exactly matching
  `lib/common.sh:396-397`. The byte-identity claim now holds **because** the icon is excluded
  from the dim span. The golden test must additionally assert the dim brackets the body and
  **not** the icon (it cannot via `strip_ansi`; see Test plan).

### 4. Edge cases & known limitations

- **Unknown tokens → warning header, not silence.** A typo (`windwo`) should not make a column
  vanish with no feedback. `build_list` calls `_columns_unknown`; if non-empty it prepends a
  non-selectable yellow `__hdr__` row, reusing the exact mechanism the hooks-notice already uses
  (`lib/common.sh:328-329`):

  ```bash
  unknown="$(_columns_unknown)"
  [ -z "$unknown" ] || printf '__hdr__\t%s⚠ unknown column(s): %s%s\n' "$C_WAIT" "$unknown" "$C_RESET"
  ```

  The valid columns still render (the resolver dropped the bad tokens); the user just sees what
  was ignored. Hard-failing the popup was rejected as disproportionate for a display preference.
- **Empty / all-unknown list → default.** `_columns_config` falls back to the default set, so the
  popup is never blank. (`@agents-inbox-columns ''` and `@agents-inbox-columns ' '` both resolve
  to the default.)
- **Unavailable values render blank.** A field with no value for a given pane renders empty (its
  column collapses to width 0), exactly as `subfolder` already does at a repo root.
- **Known limitation — multibyte width.** Column widths use awk `length()`, which is not display
  width for multibyte/CJK/emoji values. This is **pre-existing** (`lib/common.sh:379` already
  sizes `project` with `length()`); the new free-text fields (`path`, `session`, `window`) merely
  make it easier to hit. Fixing it correctly needs `wcwidth`, a dependency the project rejects, so
  it stays a documented limitation — pinned by a *skipped* non-ASCII fixture (see Test plan) so a
  future change to this behavior is a conscious choice, not an accident.

## Files

**Edited:**
- `lib/common.sh`
  - Add `_is_column`, `_columns_config`, and `_columns_unknown` helpers (near the other small
    resolvers). The catalog name list lives only in `_is_column`.
  - In `build_list`: resolve `cols` once; emit the unknown-token warning header alongside the
    existing hooks-notice (`:328-329`); replace the fixed 10-field `printf` (`:371-373`) with the
    meta-prefix + per-column value loop (with the `\t\r\n` guard); pass `-v cols` into awk and
    replace the fixed-width `fmt`/body block (`:375-398`) with the generalized N-column renderer
    that keeps the icon outside the dim-wrap. Update the `# raw fields:` comment (`:371`).

**Edited (docs):**
- `README.md` — add `@agents-inbox-columns` to the settings table (`README.md:107-115`),
  document the catalog and order/visibility semantics, and add a usage example.

**Edited (test):**
- `tests/test_build_list.sh` — keep the existing golden assertions (they prove the default is
  unchanged), extend the tmux shim to echo `@agents-inbox-columns`, and add cases for reorder
  (positional), omission, unknown-token warning, empty→default, a new-field column (`session`),
  and an idle-row dim-bracket check. Add a `skip`-marked non-ASCII alignment case pinning the
  multibyte limitation.

## Test plan

The existing golden assertions in `test_build_list.sh` run with the option unset and must
stay green — that is the "default output unchanged" guarantee. New assertions drive
`@agents-inbox-columns` via the tmux shim. Because the shim currently ignores
`show -gqv`, extend it to echo a fixture-provided option value:

```sh
*'show -gqv @agents-inbox-columns'*) printf '%s\n' "${TAI_COLUMNS:-}" ;;
```

Then assert, with the single fixture pane (`%5|sess1|0|win1|0|<cwd>`):

1. **Reorder (positional)** — `TAI_COLUMNS='age description project'`: assert the *order*, not
   mere presence. A bare `grep -q` would pass even if columns were mis-ordered, so match the
   sequence — e.g. the stripped row matches a regex anchoring `age` before the title before
   `proj` (`... 5s.*my task.*proj`), and `grep -qv '✻\|✢\|✽'` confirms no icon column.
2. **Omit** — `TAI_COLUMNS='icon description'`: project/subfolder/age absent from the row.
3. **Unknown token → warning header** — `TAI_COLUMNS='icon bogus project'`: the row renders
   icon + project, *and* a `⚠ unknown column(s): bogus` header is present
   (`grep -q 'unknown column(s): bogus'`).
4. **Empty → default** — `TAI_COLUMNS=' '` *and* `TAI_COLUMNS=''`: both equal the default render.
5. **New field** — `TAI_COLUMNS='icon session description'`: the row shows `sess1`.
6. **Idle dim brackets body, not icon** — drive an idle pane and assert on the *raw* (un-stripped)
   output that the dim color opens **after** the icon: e.g. the row matches
   `icon…<ESC>[0m  <ESC>[90m…proj` (icon's own reset, then the body's dim span), and does **not**
   match `<ESC>[90m<ESC>[…icon`. This is the regression guard `strip_ansi` cannot provide; assert
   it against the literal escape sequences.
7. **Multibyte limitation (skipped)** — a `skip`-marked case with a non-ASCII `path`/`project`
   documenting that `length()`-based alignment is byte-based; present as executable documentation,
   not a gating assertion.

Cases 1–5 run `build_list | strip_ansi` and grep the visible row; case 6 greps the **raw** output;
all follow the file's existing `assert_rc` / `assert_eq` style.

## Success criteria

- `tests/run.sh` is green, including the unchanged golden assertions and the new cases.
- With the option unset, `build_list` output is byte-identical to before across all three
  view modes (`state` / `session` / `flat`) in a live tmux session — **including** the ANSI
  bytes of idle rows (icon outside the dim span, body dim-wrapped).
- Setting `@agents-inbox-columns` reorders, hides, and adds columns from the ten-name catalog;
  unknown names are dropped from the layout **and surfaced via a `⚠` warning header**; an
  empty/all-unknown value falls back to the default.
- Idle dimming is preserved for every column order: the dim span never includes the icon, so its
  embedded `C_RESET` cannot un-dim the row.
- Free-text values containing `\t`, `\r`, or `\n` cannot split or corrupt a row.
- The multibyte `length()` limitation is documented and pinned by a skipped fixture; no `wcwidth`
  dependency is introduced.
- The hidden `pane_id` routing prefix and popup navigation are unaffected; a visible `pane`
  column is independent of it.
- `shellcheck -s bash` stays clean; no new runtime dependencies; bash 3.2 compatible.
