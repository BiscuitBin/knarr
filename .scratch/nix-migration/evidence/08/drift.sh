#!/bin/sh
# Ticket 08 evidence: env-check sees a cluster group this commit does not
# describe, and `just cluster-install` is the remedy it names. The out-link is
# pointed at another store path by hand, as an old install would leave it.
# Usage (Mac): sh host.sh --offline sh /evidence/drift.sh > drift.txt
set -eu
cd "$WORK/clone"
just=$WORK/clone/.nix/default/bin/just
export KNARR_TOOLS=nix
printf '# %s, clone at %s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git rev-parse --short=12 HEAD)" "$(uname -m)"
good=$(readlink .nix/cluster)
ln -sfn "$(readlink .nix/audit)" .nix/cluster
printf '\n== .nix/cluster moved to %s; KNARR_TOOLS=nix just env-check\n' "$(readlink .nix/cluster)"
status=0
"$just" env-check > "$WORK/drift.log" 2>&1 || status=$?
sed "s|$WORK|\$WORK|g" "$WORK/drift.log" | grep -v '^python3'
printf -- '-> exit %s\n' "$status"

printf '\n== KNARR_TOOLS=nix just cluster-install (offline: the group is in the store)\n'
"$just" cluster-install 2>&1 | grep -v '^sh scripts' || true
printf '.nix/cluster -> %s (before the move: %s)\n' "$(readlink .nix/cluster)" "$good"
status=0
"$just" env-check > "$WORK/drift.log" 2>&1 || status=$?
grep '^env-check' "$WORK/drift.log" | sed "s|$WORK|\$WORK|g"
printf -- '-> exit %s\n' "$status"
