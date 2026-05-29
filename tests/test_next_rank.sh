#!/usr/bin/env bash
# inbox-next ranks actionable panes; after the fix the order is waiting<done<background.
. "$TAI_ROOT/lib/common.sh"

rank_of() { IFS=$'\t' read -r r _i _l _d <<< "$(_status_presentation "$1")"; printf '%s' "$r"; }

# The approved order: done must rank LOWER (more urgent) than background.
[ "$(rank_of done)" -lt "$(rank_of background)" ]; assert_rc 0 "$?" "rank: done before background"
[ "$(rank_of waiting)" -lt "$(rank_of done)" ];     assert_rc 0 "$?" "rank: waiting before done"
