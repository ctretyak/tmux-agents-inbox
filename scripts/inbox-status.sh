#!/usr/bin/env bash
# Compact status-line summary, e.g.  ⚡2 ⏳1 ✓3  (working / waiting / done).
# Prints nothing when no agents are tracked. Uses tmux #[fg=..] markup for color.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"

# NOTE: counts use the RAW hook status from each state file, not _status_for's
# transcript-reconciled status (which the popup uses). The status line can thus
# briefly disagree with the popup after a /compact or for pre-install sessions.
# Reconciling would require a per-pane transcript read on every status-interval
# tick — a performance change deferred out of this maintainability pass.
prune_dead
w=0; a=0; b=0; d=0
for f in "$CACHE"/pane-*; do
  [ -e "$f" ] || continue
  read -r status _ < "$f"
  case "$status" in
    working)    w=$((w + 1)) ;;
    waiting)    a=$((a + 1)) ;;
    background) b=$((b + 1)) ;;
    done)       d=$((d + 1)) ;;
  esac
done

out=""
[ "$w" -gt 0 ] && out="${out}#[fg=yellow]⚡${w} "
[ "$a" -gt 0 ] && out="${out}#[fg=magenta]⏳${a} "
[ "$b" -gt 0 ] && out="${out}#[fg=cyan]✢${b} "
[ "$d" -gt 0 ] && out="${out}#[fg=green]✓${d} "
[ -n "$out" ] && printf '%s#[default]' "$out"
