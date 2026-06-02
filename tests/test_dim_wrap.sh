#!/usr/bin/env bash
# Regression guard: on an idle (dimmed) row the dim ANSI span must wrap the BODY
# only, NOT the status icon. The idle icon carries its own C_IDLE + C_RESET; if it
# is folded inside the dim span, its embedded reset cancels the dim for the rest of
# the row. strip_ansi cannot see this, so we assert on the RAW (un-stripped) output.
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT

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

export XDG_CACHE_HOME="$ws/cache"; export HOME="$ws/home"
export CACHE="$ws/cache/tmux-agents-inbox"
mkdir -p "$CACHE" "$ws/home"

# One idle pane %5 (shell pid 500, claude pid 510), cwd /proj.
printf '500 %%5\n' > "$ws/panes_pidmap"
printf '%%5|sess1|0|win1|0|%s\n' "$ws/proj" > "$ws/panes_meta"
printf '500 1 -bash\n510 500 /usr/local/bin/claude\n' > "$ws/ps_snap"
mkdir -p "$ws/proj/.git"

slug="$(printf '%s' "$ws/proj" | sed 's/[/.]/-/g')"
mkdir -p "$HOME/.claude/projects/$slug"
TX="$HOME/.claude/projects/$slug/sess.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"my task"}' > "$TX"
set_mtime $((TAI_NOW - 100)) "$TX"

# State file: idle, updated 100s ago -> _status_for trusts the hook -> idle -> dim=1.
printf 'idle %s idle %s\n' $((TAI_NOW - 100)) "$TX" > "$CACHE/pane-5"
printf 'state' > "$CACHE/.view-mode"

raw="$(build_list)"   # NOTE: NOT stripped — we assert on the escape sequences.

# Sanity: the row is idle/dimmed at all (body carries the C_IDLE span).
printf '%s' "$raw" | grep -qF $'\033[90m'
assert_rc 0 "$?" "dim-wrap: idle row carries a C_IDLE span"

# The dim span opens AFTER the icon: icon's own reset, two-space gap, then dim open.
printf '%s' "$raw" | grep -qF $'\033[0m  \033[90m'
assert_rc 0 "$?" "dim-wrap: dim span opens after the icon (body only)"

# Regression: the dim color must NOT immediately precede the icon glyph.
printf '%s' "$raw" | grep -qF $'\033[90m\033[90m✻'
assert_rc 1 "$?" "dim-wrap: icon is NOT inside the dim span"
