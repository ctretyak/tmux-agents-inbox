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
