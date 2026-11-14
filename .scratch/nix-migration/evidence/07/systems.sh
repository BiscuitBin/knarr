#!/bin/sh
# Ticket 07 evidence: every package of the committed flake evaluates for all
# three systems from aarch64-linux, and what a machine with that store would
# build or fetch for the default group (asking the binary cache, so online).
# Nothing for another system is built.
# Usage (Mac): sh host.sh sh /evidence/systems.sh <clone> > systems.txt
set -eu
clone=${1:?usage: systems.sh <clone>}
cd "$clone"
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
printf 'clone at %s\n' "$(git rev-parse --short HEAD)"
for system in aarch64-linux x86_64-linux aarch64-darwin; do
  printf '\n== %s\n' "$system"
  for group in default cluster audit runtime allium; do
    printf '%-8s %s\n' "$group" "$(nix eval --raw --offline --no-update-lock-file ".#packages.$system.$group.outPath" 2>&1)"
  done
  printf 'opensslVersion %s\n' "$(nix eval --raw --offline --no-update-lock-file ".#packages.$system.default.opensslVersion")"
  printf 'default, nix build --dry-run:\n'
  nix build --dry-run --no-update-lock-file ".#packages.$system.default" 2>&1 |
    grep -E 'will be (built|fetched)|\.drv$' | sed 's/^/  /' || echo '  (nothing to build or fetch)'
done
