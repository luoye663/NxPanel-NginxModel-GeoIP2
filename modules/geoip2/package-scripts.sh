#!/bin/sh
set -eu
source_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
mkdir -p "$1"
for action in install uninstall; do
    cat "$source_dir/lifecycle.sh" "$source_dir/$action.sh" > "$1/$action.sh"
    sh -n "$1/$action.sh"
done
