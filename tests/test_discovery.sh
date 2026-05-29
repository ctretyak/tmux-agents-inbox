#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
export TAI_FIX="$ws"
PATH="$TAI_ROOT/tests/_shims:$PATH"; export PATH
chmod +x "$TAI_ROOT/tests/_shims/tmux" "$TAI_ROOT/tests/_shims/ps"

# pane %5 shell pid 500 runs an interactive claude (pid 510, parent 500).
# pane %6 shell pid 600 runs `claude agents` (must be EXCLUDED).
cat > "$ws/panes_pidmap" <<'EOF'
500 %5
600 %6
EOF
cat > "$ws/ps_snap" <<'EOF'
500 1 -bash
510 500 /usr/local/bin/claude
600 1 -bash
610 600 /usr/local/bin/claude agents
EOF

out="$(claude_panes)"
assert_eq "%5" "$out" "claude_panes: resolves interactive claude to its pane, excludes 'agents'"
