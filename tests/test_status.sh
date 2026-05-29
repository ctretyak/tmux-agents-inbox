#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"

# _status_for <hook_status> <hook_updated> <tx_mtime> <now>
NOW=1000

# Endpoint states trusted unconditionally (no transcript demotion).
assert_eq working    "$(_status_for working    900 999 "$NOW")" "status: working trusted"
assert_eq background "$(_status_for background 900 999 "$NOW")" "status: background trusted"

# waiting: stays waiting until transcript progresses past the Notification epoch.
assert_eq waiting "$(_status_for waiting 900 900 "$NOW")" "status: waiting holds (tx not past hu)"
assert_eq working "$(_status_for waiting 900 950 "$NOW")" "status: waiting->working once tx>hu+1"

# done: fresh done not re-promoted by post-Stop transcript writes.
assert_eq done "$(_status_for done 998 999 "$NOW")" "status: fresh done stays done"

# stale hook (hu<<tx): derive from transcript freshness windows.
assert_eq working "$(_status_for '' 0 998 "$NOW")" "status: tx age 2s -> working (<5s)"
assert_eq working "$(_status_for '' 0 992 "$NOW")" "status: tx age 8s -> working (<10s)"
assert_eq working "$(_status_for '' 0 989 "$NOW")" "status: tx age 11s -> working (<12s)"
assert_eq done    "$(_status_for '' 0 980 "$NOW")" "status: tx age 20s -> done"
assert_eq idle    "$(_status_for '' 0 0   "$NOW")" "status: no hook, no transcript -> idle"

# --- _status_presentation: tab-delimited "rank<TAB>icon<TAB>label<TAB>dim" ---
sp() { IFS=$'\t' read -r r i l d <<< "$(_status_presentation "$1")"; printf '%s|%s|%s' "$r" "$l" "$d"; }
assert_eq "0|Needs input|0" "$(sp waiting)"    "_status_presentation: waiting"
assert_eq "1|Completed|0"   "$(sp done)"       "_status_presentation: done"
assert_eq "2|Background|0"  "$(sp background)" "_status_presentation: background"
assert_eq "3|Working|0"     "$(sp working)"    "_status_presentation: working"
assert_eq "4|Idle|1"        "$(sp idle)"       "_status_presentation: idle"
assert_eq "4|Idle|1"        "$(sp bogus)"      "_status_presentation: unknown -> idle defaults"
