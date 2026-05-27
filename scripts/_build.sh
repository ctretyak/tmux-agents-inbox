#!/usr/bin/env bash
# Emit the inbox rows. Standalone so fzf's ctrl-r reload can call it.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/common.sh"
build_list
