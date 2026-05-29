#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
export CACHE="$ws/cache"; mkdir -p "$CACHE"

: > "$CACHE/pane-1"; : > "$CACHE/pane-10"; : > "$CACHE/pane-2"

# Live set has only pane 1 and 10 (note: exact-line anchoring must NOT let "1"
# match inside "10", and must keep 10 while dropping 2).
_prune_state "$(printf '1\n10\n')"

[ -f "$CACHE/pane-1" ];  assert_rc 0 "$?" "_prune_state: keeps live pane 1"
[ -f "$CACHE/pane-10" ]; assert_rc 0 "$?" "_prune_state: keeps live pane 10 (no 1-in-10 collision)"
[ -f "$CACHE/pane-2" ];  assert_rc 1 "$?" "_prune_state: drops dead pane 2"
