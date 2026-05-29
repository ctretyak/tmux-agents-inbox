#!/usr/bin/env bash
. "$TAI_ROOT/lib/common.sh"

ws="$(mktemp -d)"
trap 'rm -rf "$ws"' EXIT

# Helper: assert "proj<TAB>sub" for a cwd.
check() { assert_eq "$2" "$(_proj_sub "$1")" "$3"; }

# 1) Claude-managed worktree path.
check "/home/me/myproj/.claude/worktrees/feat-x" "myproj	feat-x" "_proj_sub: claude worktree"

# 2) Plain repo (.git is a dir) + subfolder.
mkdir -p "$ws/repo/.git" "$ws/repo/src/inner"
check "$ws/repo/src/inner" "repo	src/inner" "_proj_sub: plain repo + subfolder"
check "$ws/repo" "repo	" "_proj_sub: plain repo root (empty sub)"

# 3) Linked worktree (.git is a FILE with gitdir:).
mkdir -p "$ws/main/.git/worktrees/wt1" "$ws/wt1"
printf 'gitdir: %s/main/.git/worktrees/wt1\n' "$ws" > "$ws/wt1/.git"
check "$ws/wt1" "main	wt1" "_proj_sub: linked worktree"

# 4) No repo -> nearest folder, empty sub.
mkdir -p "$ws/loose/dir"
check "$ws/loose/dir" "dir	" "_proj_sub: no repo fallback"

# 5) Path containing a space.
mkdir -p "$ws/has space/.git"
check "$ws/has space" "has space	" "_proj_sub: path with space"
