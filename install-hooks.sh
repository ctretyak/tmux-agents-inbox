#!/usr/bin/env bash
# Merge the tmux-agents-inbox Claude Code hooks into ~/.claude/settings.json.
# Idempotent (re-running does not duplicate) and preserves any existing hooks.
# Override the target with CLAUDE_SETTINGS=/path/to/settings.json.
set -e

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
HOOK="$(cd "$(dirname "$0")" && pwd)/hooks/inbox-hook.sh"

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq is required. Install jq, or paste the manual snippet from README.md." >&2
  exit 1
}

if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

backup="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$backup"

tmp="$(mktemp)"
jq --arg hook "$HOOK" '
  def ensure(ev):
    .hooks[ev] = (
      ((.hooks[ev] // [])
        | map(select( ((.hooks // []) | map(.command // "") | any(test("inbox-hook.sh"))) | not )))
      + [ { "hooks": [ { "type": "command", "command": ("bash " + $hook + " " + ev), "timeout": 5 } ] } ]
    );
  .hooks = (.hooks // {})
  | ensure("SessionStart")
  | ensure("UserPromptSubmit")
  | ensure("PreToolUse")
  | ensure("PostToolUse")
  | ensure("SubagentStop")
  | ensure("PreCompact")
  | ensure("Notification")
  | ensure("Stop")
  | ensure("SessionEnd")
' "$SETTINGS" > "$tmp"

mv "$tmp" "$SETTINGS"
echo "Installed tmux-agents-inbox hooks into $SETTINGS"
echo "Backup written to $backup"
echo "Restart any running Claude Code sessions for the hooks to take effect."
