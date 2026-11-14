#!/bin/sh
# Ticket 08 evidence: with the cluster and audit groups installed, the Nix
# gate, offline: the selected checker tests, then the whole gate, whose
# env-check now compares the cluster group too.
# Usage (Mac): sh host.sh --offline sh /evidence/gate.sh > gate.txt
set -eu
cd "$WORK/clone"
just=$WORK/clone/.nix/default/bin/just
export KNARR_TOOLS=nix
printf '# %s, clone at %s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git rev-parse --short=12 HEAD)" "$(uname -m)"
printf '.nix: %s\n' "$(cd .nix && printf '%s ' *)"

printf '\n== KNARR_TOOLS=nix just test-checkers-selected cluster environment\n'
"$just" test-checkers-selected cluster environment 2>&1 | tail -n 1

printf '\n== KNARR_TOOLS=nix just env-check\n'
"$just" env-check 2>&1 | grep '^env-check' | sed "s|$WORK|\$WORK|g"

printf '\n== KNARR_TOOLS=nix just check\n'
start=$(date +%s)
status=0
"$just" check > "$WORK/gate.log" 2>&1 || status=$?
tail -n 2 "$WORK/gate.log"
printf -- '-> exit %s in %s seconds\n' "$status" "$(($(date +%s) - start))"
