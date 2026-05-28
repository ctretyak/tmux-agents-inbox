#!/usr/bin/env bash
# Send SIGTERM to the Claude process(es) running in the given tmux pane (%NN).
# Used by the popup's alt-k bind. No-ops on header rows.
pane="$1"
case "$pane" in
  %[0-9]*) ;;
  *) exit 0 ;;
esac

pane_pid="$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null)"
[ -n "$pane_pid" ] || exit 0

# Every descendant of pane_pid whose argv0 is `claude` — send SIGTERM. The
# SessionEnd hook will remove the state file, and prune_dead drops the row
# on the next refresh.
ps -eo pid=,ppid=,args= 2>/dev/null | awk -v root="$pane_pid" '
  { par[$1]=$2; line[$1]=$0 }
  END {
    for (p in par) {
      q=p; hops=0
      while (q!="" && hops<12) {
        if (q==root) {
          a=line[p]; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", a)
          split(a, t, /[ \t]+/); exe=t[1]
          if (exe ~ /(^|\/)claude$/ || exe ~ /\/claude\/versions\//) print p
          break
        }
        q=par[q]; hops++
      }
    }
  }
' | while read -r kpid; do
  [ -n "$kpid" ] && kill -TERM "$kpid" 2>/dev/null
done
