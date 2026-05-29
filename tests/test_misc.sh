#!/usr/bin/env bash
# Misc pure-function tests: _ago and the transcript helpers.
. "$TAI_ROOT/lib/common.sh"

# _ago formats a duration from a past epoch to "now" (date +%s). To make it
# deterministic we cannot inject "now", so freeze the clock by shimming `date`
# via PATH for the duration of these assertions.
_shimdir="$(mktemp -d)"
cat > "$_shimdir/date" <<'SH'
#!/usr/bin/env bash
case "$1" in
  +%s) printf '%s\n' "${TAI_NOW:?}";;
  *) exec /bin/date "$@";;
esac
SH
chmod +x "$_shimdir/date"
PATH="$_shimdir:$PATH"; export PATH TAI_NOW

TAI_NOW=1000

assert_eq " 0s" "$(_ago 1000)" "_ago: 0 seconds"
assert_eq " 5s" "$(_ago 995)"  "_ago: 5 seconds"
assert_eq " 1m" "$(_ago 940)"  "_ago: 60 seconds -> 1m"
assert_eq "59m" "$(_ago $((1000 - 3540)))" "_ago: 3540s -> 59m"
assert_eq " 1h" "$(_ago $((1000 - 3600)))" "_ago: 3600s -> 1h"
assert_eq " 1d" "$(_ago $((1000 - 86400)))" "_ago: 86400s -> 1d"
assert_eq " 0s" "$(_ago 2000)" "_ago: future clamps to 0"

rm -rf "$_shimdir"
