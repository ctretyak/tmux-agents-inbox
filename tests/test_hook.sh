#!/usr/bin/env bash
# Drives hooks/inbox-hook.sh with synthetic payloads and asserts the state-file
# line shape: "<status> <epoch> <event> <tpath>". TMUX_PANE + CACHE point at a
# temp workspace. The SessionStart parent-walk (ownership lock) is out of scope.
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
export XDG_CACHE_HOME="$ws/cache"
export TMUX_PANE="%99"
HOOK="$TAI_ROOT/hooks/inbox-hook.sh"
SF="$ws/cache/tmux-agents-inbox/pane-99"

run_hook() { printf '%s' "$2" | bash "$HOOK" "$1"; }
field() { awk -v n="$1" '{print $n; exit}' "$SF"; }   # field n of the state line

# UserPromptSubmit -> working
run_hook UserPromptSubmit '{"session_id":"s1","transcript_path":"/t/s1.jsonl"}'
assert_eq working "$(field 1)" "hook: UserPromptSubmit -> working"
assert_eq "/t/s1.jsonl" "$(field 4)" "hook: records transcript_path"

# PreToolUse (ordinary tool) -> working
run_hook PreToolUse '{"session_id":"s1","transcript_path":"/t/s1.jsonl","tool_name":"Bash"}'
assert_eq working "$(field 1)" "hook: PreToolUse ordinary tool -> working"

# PreToolUse AskUserQuestion -> waiting (the tool blocks on the user; no other
# hook event fires while the popup is open, so this is the only signal)
run_hook PreToolUse '{"session_id":"s1","transcript_path":"/t/s1.jsonl","tool_name":"AskUserQuestion"}'
assert_eq waiting "$(field 1)" "hook: PreToolUse AskUserQuestion -> waiting"

# PostToolUse -> working (clears a prior "waiting" the moment a tool — e.g.
# AskUserQuestion — returns, before Claude resumes thinking)
run_hook PostToolUse '{"session_id":"s1","transcript_path":"/t/s1.jsonl"}'
assert_eq working "$(field 1)" "hook: PostToolUse -> working"

# Notification (real) -> waiting
run_hook Notification '{"session_id":"s1","transcript_path":"/t/s1.jsonl","notification_type":"permission"}'
assert_eq waiting "$(field 1)" "hook: Notification -> waiting"

# Notification idle_prompt -> leaves state untouched (still waiting from above)
run_hook Notification '{"session_id":"s1","transcript_path":"/t/s1.jsonl","notification_type":"idle_prompt"}'
assert_eq waiting "$(field 1)" "hook: idle_prompt does not overwrite"

# Stop with running background_tasks -> background
run_hook Stop '{"session_id":"s1","transcript_path":"/t/s1.jsonl","background_tasks":[{"status":"running"}]}'
assert_eq background "$(field 1)" "hook: Stop + running bg -> background"

# Stop clean -> done
run_hook Stop '{"session_id":"s1","transcript_path":"/t/s1.jsonl","background_tasks":[]}'
assert_eq done "$(field 1)" "hook: clean Stop -> done"

# SessionEnd -> file removed
run_hook SessionEnd '{"session_id":"s1","transcript_path":"/t/s1.jsonl"}'
[ -f "$SF" ]; assert_rc 1 "$?" "hook: SessionEnd removes state file"
