#!/bin/sh
# Run a command with the Justfile's PATH. Git runs hooks without it, so every
# prek hook entry goes through this script to reach the tool directories
# scripts/tool-dirs.sh names. markdownlint-cli2 is a `#!/usr/bin/env node`
# script, so even a tool called by its path needs them on PATH.
# Usage: sh scripts/with-env.sh <command> [argument...]
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# Without the environment every tool would resolve to whatever unpinned copy
# the system has, and a hook would check different rules from the gate.
sh "$root/scripts/tool-dirs.sh" tool python3 "$root" > /dev/null ||
  { printf '%s\n' "the pixi environment is missing in $root; run just initialize" >&2; exit 2; }
PATH="$(sh "$root/scripts/tool-dirs.sh" dirs "$root"):$PATH"
PYTHONDONTWRITEBYTECODE=1
export PATH PYTHONDONTWRITEBYTECODE
exec "$@"
