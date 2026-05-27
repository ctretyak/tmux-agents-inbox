#!/usr/bin/env bash
# TPM entry point for tmux-agents-inbox.
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$CURRENT_DIR/scripts"

get_opt() {
  local v
  v="$(tmux show -gqv "$1" 2>/dev/null)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

popup_key="$(get_opt '@agents-inbox-popup-key' 'I')"
next_key="$(get_opt '@agents-inbox-next-key' 'N')"
popup_w="$(get_opt '@agents-inbox-popup-width' '80%')"
popup_h="$(get_opt '@agents-inbox-popup-height' '70%')"
auto_status="$(get_opt '@agents-inbox-auto-status' 'off')"

# prefix + I  -> open the inbox popup (launcher sizes it to fit the content)
tmux bind-key "$popup_key" run-shell "bash '$SCRIPTS/inbox-open.sh'"

# prefix + N  -> jump to the next waiting agent
tmux bind-key "$next_key" run-shell "bash '$SCRIPTS/inbox-next.sh'"

# Optional: append the summary to status-right (off by default; idempotent).
if [ "$auto_status" = "on" ]; then
  cur="$(tmux show -gqv status-right 2>/dev/null)"
  case "$cur" in
    *inbox-status.sh*) : ;;
    *) tmux set -g status-right "$cur #($SCRIPTS/inbox-status.sh)" ;;
  esac
fi
