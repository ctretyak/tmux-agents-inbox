#!/usr/bin/env bash
# Pure-bash assertion + fixture helpers. Sourced into each test subshell by run.sh.
# Results are APPENDED to $TAI_RESULTS (a temp file) because a pass/fail counter
# held in a variable cannot cross the subshell-per-file boundary run.sh creates.
: "${TAI_RESULTS:?_assert.sh requires TAI_RESULTS (set by run.sh)}"

# assert_eq <expected> <actual> <message>
assert_eq() {
  if [ "$1" = "$2" ]; then
    printf 'PASS\t%s\n' "$3" >> "$TAI_RESULTS"
  else
    printf 'FAIL\t%s\n\texpected: [%s]\n\tactual:   [%s]\n' "$3" "$1" "$2" >> "$TAI_RESULTS"
  fi
}

# assert_rc <expected_rc> <actual_rc> <message>
assert_rc() {
  if [ "$1" = "$2" ]; then
    printf 'PASS\t%s\n' "$3" >> "$TAI_RESULTS"
  else
    printf 'FAIL\t%s (expected rc %s, got %s)\n' "$3" "$1" "$2" >> "$TAI_RESULTS"
  fi
}

# set_mtime <epoch> <file> — portable across GNU (Linux) and BSD (macOS).
# GNU touch understands -d @<epoch>; BSD does not, so fall back to converting the
# epoch with BSD `date -r` into touch -t's CCYYMMDDhhmm.ss form.
set_mtime() {
  local epoch="$1" file="$2" stamp
  if touch -d "@$epoch" "$file" 2>/dev/null; then return 0; fi
  stamp="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$stamp" "$file"
}

# strip_ansi — filter stdin, removing ANSI SGR escapes (for golden comparisons).
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }
