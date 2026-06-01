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

# --- transcript helpers ---
F="$TAI_ROOT/tests/fixtures"

# _title_of uses tail|grep|sed (NOT jq), so it works regardless of jq presence.
assert_eq "my generated title" "$(_title_of "$F/title.jsonl")" "_title_of: reads aiTitle"
assert_eq "good title"         "$(_title_of "$F/malformed.jsonl")" "_title_of: survives malformed tail"

# _last_user_prompt and _last_assistant_asks_question require jq; assert the
# jq path when present, otherwise assert the documented no-jq fallback (empty / rc 1).
if command -v jq >/dev/null 2>&1; then
  assert_eq "hello there friend" "$(_last_user_prompt "$F/title.jsonl")" "_last_user_prompt: last user text"
  assert_eq "a real prompt here" "$(_last_user_prompt "$F/malformed.jsonl")" "_last_user_prompt: malformed tail ok"

  _last_assistant_asks_question "$F/question.jsonl";    assert_rc 0 "$?" "asks_question: trailing assistant '?' -> 0"
  _last_assistant_asks_question "$F/midquestion.jsonl"; assert_rc 0 "$?" "asks_question: question sentence mid last paragraph -> 0"
  _last_assistant_asks_question "$F/decided.jsonl";     assert_rc 1 "$?" "asks_question: question in earlier paragraph, last is plain -> 1"
  _last_assistant_asks_question "$F/answered.jsonl";    assert_rc 1 "$?" "asks_question: user replied -> 1"
else
  assert_eq "" "$(_last_user_prompt "$F/title.jsonl")" "_last_user_prompt: no-jq returns empty (fallback)"
  _last_assistant_asks_question "$F/midquestion.jsonl"; assert_rc 1 "$?" "asks_question: no-jq returns 1 (fallback)"
fi
