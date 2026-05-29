#!/usr/bin/env bash
# Run shellcheck over the shell sources. Lint is the gate; behavioral fixes are
# scoped to files this pass touches (see spec). Skips cleanly if shellcheck is absent.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed — skipping lint (install: brew install shellcheck)"
  exit 0
fi
cd "$DIR" || exit 1
files="$(find lib scripts hooks -name '*.sh' -type f) tmux-agents-inbox.tmux"
# shellcheck disable=SC2086
shellcheck $files
