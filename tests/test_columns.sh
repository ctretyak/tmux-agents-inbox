#!/usr/bin/env bash
# Unit tests for the column-config resolver helpers. tmux is shimmed so
# `tmux show -gqv '@agents-inbox-columns'` returns $TAI_COLUMNS.
. "$TAI_ROOT/lib/common.sh"

_shimdir="$(mktemp -d)"; trap 'rm -rf "$_shimdir"' EXIT
cat > "$_shimdir/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'show -gqv @agents-inbox-columns'*) printf '%s\n' "${TAI_COLUMNS:-}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_shimdir/tmux"
PATH="$_shimdir:$PATH"; export PATH TAI_COLUMNS

DEF="icon project subfolder description age"

# _is_column: catalog membership
_is_column window-index; assert_rc 0 "$?" "_is_column: window-index is valid"
_is_column path;         assert_rc 0 "$?" "_is_column: path is valid"
_is_column windows;      assert_rc 1 "$?" "_is_column: 'windows' is rejected"

# _columns_config: passthrough, reorder, drop-unknown, default fallbacks
TAI_COLUMNS="icon project age"
assert_eq "icon project age" "$(_columns_config)" "_columns_config: valid passthrough"
TAI_COLUMNS="age icon"
assert_eq "age icon" "$(_columns_config)" "_columns_config: reorder preserved"
TAI_COLUMNS="icon bogus project"
assert_eq "icon project" "$(_columns_config)" "_columns_config: drops unknown token"
TAI_COLUMNS=""
assert_eq "$DEF" "$(_columns_config)" "_columns_config: empty -> default"
TAI_COLUMNS="   "
assert_eq "$DEF" "$(_columns_config)" "_columns_config: blank -> default"
TAI_COLUMNS="bogus nope"
assert_eq "$DEF" "$(_columns_config)" "_columns_config: all-unknown -> default"

# _columns_unknown: only the rejected tokens
TAI_COLUMNS="icon bogus project nope"
assert_eq "bogus nope" "$(_columns_unknown)" "_columns_unknown: lists rejected tokens"
TAI_COLUMNS="icon project"
assert_eq "" "$(_columns_unknown)" "_columns_unknown: empty when all valid"

# KNOWN LIMITATION (pinned, not a bug to silently "fix"): the awk renderer sizes
# columns with length(), which counts BYTES, not display columns. A 2-byte UTF-8
# character therefore reports width 2 and a wide column (path/session/project with
# non-ASCII) can misalign. Fixing it needs wcwidth, a dependency the project rejects.
# If this assertion ever fails, alignment behavior changed — decide deliberately.
bytelen="$(printf 'ä' | awk '{ print length($0) }')"
assert_eq "2" "$bytelen" "known-limitation: awk length() is byte-based (UTF-8 ä = 2)"
