#!/bin/sh
# Ticket 08 evidence: the flake's grype through `just runtime-scan` and `just
# image-scan`, under KNARR_TOOLS=nix, on the pixi image kind.sh built (09 has
# not moved the image yet). runtime-scan needs the line
# `discovered N packages cataloger=conda-meta-cataloger` in grype's -vv log.
# The vulnerability database is the Mac's own grype cache, copied into the
# work volume, so grype downloads nothing; it is older than grype's age limit,
# so the check of its age is off. Ticket 11 owns runtime-scan's logic.
# Usage (Mac): sh host.sh sh /evidence/grype.sh > grype.txt
set -eu
cd "$WORK/clone"
just=$WORK/clone/.nix/default/bin/just
export KNARR_TOOLS=nix
export GRYPE_DB_CACHE_DIR="$WORK/grype-db/db" GRYPE_DB_AUTO_UPDATE=false GRYPE_DB_VALIDATE_AGE=false
image=knarr:$(sh scripts/cluster-name.sh . name)
printf '# %s, clone at %s on %s, image %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
  "$(git rev-parse --short=12 HEAD)" "$(uname -m)" "$image"
printf 'grype: %s, %s\n' "$(command -v grype || PATH=$(sh scripts/tool-dirs.sh dirs) command -v grype)" \
  "$(.nix/audit/bin/grype version | grep '^Version:' | tr -s ' ')"
.nix/audit/bin/grype db status | grep -E '^(Built|Schema|Status)' || true

printf '\n== KNARR_TOOLS=nix just runtime-scan %s\n' "$image"
status=0
"$just" runtime-scan "$image" > "$WORK/runtime-scan.log" 2>&1 || status=$?
grep -E '^runtime-scan' "$WORK/runtime-scan.log" | sed "s|$WORK|\$WORK|g" || true
printf -- '-> exit %s\n' "$status"
printf 'cataloger lines in build/runtime-scan/grype.log:\n'
grep -oE 'discovered [0-9]+ packages cataloger=[a-z-]+' build/runtime-scan/grype.log | grep -v 'discovered 0 ' | sed 's/^/  /'

printf '\n== KNARR_TOOLS=nix just image-scan %s\n' "$image"
status=0
"$just" image-scan "$image" > "$WORK/image-scan.log" 2>&1 || status=$?
tail -n 5 "$WORK/image-scan.log"
printf -- '-> exit %s\n' "$status"
