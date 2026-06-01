#!/usr/bin/env bash
# Unit tests for _hooks_detected(): greps the user settings file for THIS
# plugin's resolved absolute hook path. User-scope + grep-only by design.
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
HOOK="$TAI_ROOT/hooks/inbox-hook.sh"   # the resolved path _hooks_detected looks for

# present: settings contains the resolved hook path -> detected (rc 0)
p="$ws/present.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash %s Stop"}]}]}}\n' "$HOOK" > "$p"
export CLAUDE_SETTINGS="$p"; _hooks_detected
assert_rc 0 "$?" "_hooks_detected: true when resolved hook path present"

# absent: no hook entry -> not detected (rc 1)
a="$ws/absent.json"; printf '{"hooks":{}}\n' > "$a"
export CLAUDE_SETTINGS="$a"; _hooks_detected
assert_rc 1 "$?" "_hooks_detected: false when hook path absent"

# stale/relocated: basename matches but full path differs -> not detected
s="$ws/stale.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash /old/p/hooks/inbox-hook.sh Stop"}]}]}}\n' > "$s"
export CLAUDE_SETTINGS="$s"; _hooks_detected
assert_rc 1 "$?" "_hooks_detected: false for stale path (resolved-path, not basename)"

# missing file -> not detected
export CLAUDE_SETTINGS="$ws/nope.json"; _hooks_detected
assert_rc 1 "$?" "_hooks_detected: false when settings file missing"
