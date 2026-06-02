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
  *'show -gqv @agents-inbox-columns'*) printf '%s\n' "${TAI_COLUMNS:-}" ;;
  *) exit 0 ;;
esac
SH
cp "$TAI_ROOT/tests/_shims/ps" "$ws/bin/ps"
chmod +x "$ws/bin/"*
export TAI_FIX="$ws" TAI_NOW=1000000000
PATH="$ws/bin:$PATH"; export PATH

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

# Header label must flow from _status_presentation, not a hardcoded awk copy.
# Green before and after the single-source refactor: it pins the contract so the
# helper's label and the rendered group header can never drift apart again.
# field 3 of _status_presentation = label; working has a plain (ANSI-free) icon.
wlabel="$(_status_presentation working | cut -f3)"
printf '%s' "$out" | grep -qF "$wlabel (1)"
assert_rc 0 "$?" "build_list: state header label sourced from _status_presentation"

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

# Unknown token -> warning header, valid columns still render (Task 3).
export TAI_COLUMNS="icon bogus project"
oc="$(build_list | strip_ansi)"
printf '%s\n' "$oc" | grep -q 'unknown column(s): bogus'
assert_rc 0 "$?" "columns unknown: warning header lists bad token"
printf '%s\n' "$oc" | grep '^%5' | grep -q 'proj'
assert_rc 0 "$?" "columns unknown: valid columns still render"
unset TAI_COLUMNS
