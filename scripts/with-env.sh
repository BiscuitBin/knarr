#!/bin/sh
# Run a command with the Justfile's PATH. Git runs hooks without it, so every
# prek hook entry goes through this script to reach the Nix tool environment
# behind .nix/tools.
# Usage: sh scripts/with-env.sh <command> [argument...]
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# Without the environment every tool would resolve to whatever unpinned copy
# the system has, and a hook would check different rules from the gate.
[ -x "$root/.nix/tools/bin/python3" ] ||
  { printf '%s\n' "the Nix tool environment is missing in $root; run just initialize" >&2; exit 2; }
PATH="$root/.nix/tools/bin:$PATH"
PYTHONDONTWRITEBYTECODE=1
export PATH PYTHONDONTWRITEBYTECODE
exec "$@"
