#!/usr/bin/env bash
# Runs install-hooks.sh against a throwaway settings.json (CLAUDE_SETTINGS) and
# asserts every event the handler acts on is actually registered. The handler
# (hooks/inbox-hook.sh) has branches for PostToolUse and SubagentStop; if the
# installer omits them those branches are dead and a "waiting" row never clears
# when the user answers an AskUserQuestion and Claude then keeps thinking.
command -v jq >/dev/null 2>&1 || { echo "(skip test_install_hooks: jq missing)"; return 0; }

ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
export CLAUDE_SETTINGS="$ws/settings.json"

bash "$TAI_ROOT/install-hooks.sh" >/dev/null 2>&1

# True when event $1 has an entry whose command invokes inbox-hook.sh with $1.
has_event() {
  jq -r --arg e "$1" '.hooks[$e] // [] | .[].hooks[]?.command // empty' \
    "$CLAUDE_SETTINGS" 2>/dev/null | grep -q "inbox-hook.sh $1\$"
}

for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse \
          PreCompact Notification Stop SessionEnd; do
  has_event "$ev"; assert_rc 0 "$?" "install-hooks registers $ev"
done

# Idempotent: a second run must not duplicate the PostToolUse entry.
bash "$TAI_ROOT/install-hooks.sh" >/dev/null 2>&1
n="$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command // empty
            | select(test("inbox-hook.sh"))] | length' "$CLAUDE_SETTINGS" 2>/dev/null)"
assert_eq 1 "$n" "install-hooks does not duplicate PostToolUse on re-run"
