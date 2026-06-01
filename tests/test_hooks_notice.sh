#!/usr/bin/env bash
# Integration test: build_list prepends a non-selectable yellow banner when the
# plugin's hook isn't detected. Uses empty tmux/ps shims (zero panes) so the
# banner is the only variable in the output.
. "$TAI_ROOT/lib/common.sh"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
mkdir -p "$ws/bin"

# tmux shim: no panes for either format query.
cat > "$ws/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
# ps shim: no processes.
cat > "$ws/bin/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$ws/bin/"*
PATH="$ws/bin:$PATH"; export PATH

export XDG_CACHE_HOME="$ws/cache"
export CACHE="$ws/cache/tmux-agents-inbox"   # common.sh read CACHE at source; override here
mkdir -p "$CACHE"
printf 'state' > "$CACHE/.view-mode"
HOOK="$TAI_ROOT/hooks/inbox-hook.sh"

# absent settings -> banner shown
a="$ws/absent.json"; printf '{"hooks":{}}\n' > "$a"
export CLAUDE_SETTINGS="$a"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: banner shown when hook path absent"

# present (resolved path) -> no banner
p="$ws/present.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash %s Stop"}]}]}}\n' "$HOOK" > "$p"
export CLAUDE_SETTINGS="$p"
build_list | grep -q 'hooks not detected'
assert_rc 1 "$?" "notice: no banner when resolved hook path present"

# stale path -> banner shown (guards resolved-path, not basename)
s="$ws/stale.json"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"bash /old/p/hooks/inbox-hook.sh Stop"}]}]}}\n' > "$s"
export CLAUDE_SETTINGS="$s"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: banner shown for stale path"

# missing settings file -> banner shown
export CLAUDE_SETTINGS="$ws/nope.json"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: banner shown when settings file missing"

# malformed JSON lacking the path -> banner shown (grep is content-based, no parse)
m="$ws/malformed.json"; printf '{"hooks": {"Stop": [ {"hooks": [\n' > "$m"
export CLAUDE_SETTINGS="$m"
build_list | grep -q 'hooks not detected'
assert_rc 0 "$?" "notice: malformed settings without path -> banner"

# zero panes + not detected -> banner is the SOLE output line
export CLAUDE_SETTINGS="$a"
lc="$(build_list | grep -c '')"
assert_eq 1 "$lc" "notice: zero-pane popup shows banner as sole line"

# banner first field is __hdr__ (non-selectable contract)
f1="$(build_list | head -1 | cut -f1)"
assert_eq "__hdr__" "$f1" "notice: banner first field is __hdr__"

# remains __hdr__ on a second build (reload re-runs build_list)
f1b="$(build_list | head -1 | cut -f1)"
assert_eq "__hdr__" "$f1b" "notice: banner stays __hdr__ across reload"
