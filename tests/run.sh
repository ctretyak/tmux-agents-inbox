#!/usr/bin/env bash
# Run every tests/test_*.sh in its own subshell so functions/globals can't leak
# between files. Assertion results land in a temp file; the final summary reads it.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export TAI_ROOT="$DIR"
TAI_RESULTS="$(mktemp)"; export TAI_RESULTS
trap 'rm -f "$TAI_RESULTS"' EXIT

for f in "$DIR"/tests/test_*.sh; do
  [ -e "$f" ] || continue
  printf '== %s ==\n' "${f##*/}"
  ( . "$DIR/tests/_assert.sh"; . "$f" ) \
    || printf 'FAIL\t%s (file errored, rc=%s)\n' "${f##*/}" "$?" >> "$TAI_RESULTS"
done

passes="$(grep -c '^PASS' "$TAI_RESULTS" 2>/dev/null || true)"; passes="${passes:-0}"
fails="$(grep -c '^FAIL' "$TAI_RESULTS" 2>/dev/null || true)"; fails="${fails:-0}"
printf '\n--- failures ---\n'; grep '^FAIL' "$TAI_RESULTS" 2>/dev/null || printf '(none)\n'
printf '\n%s passed, %s failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
