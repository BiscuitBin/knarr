#!/bin/sh
# Ticket 07 evidence: the Nix lock check on a drifted copy, with the network
# off. flake.nix moves away from what flake.lock records, as an edit that
# forgot to relock would; the check must fail and leave flake.lock alone.
# Usage (Mac): sh host.sh --offline sh /evidence/drift.sh > drift.txt
set -eu
clone=/work/clone
copy=/work/drift
just=$clone/.nix/default/bin/just
KNARR_TOOLS=nix
export KNARR_TOOLS
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
if getent hosts cache.nixos.org > /dev/null 2>&1; then echo 'network: ON (unexpected)'; else echo 'network: off'; fi

rm -rf "$copy"
git clone --quiet "$clone" "$copy"
cd "$copy"
printf 'copy of %s at %s\n' "$clone" "$(git rev-parse --short HEAD)"
printf '\n== The copy as committed\n'
status=0
"$just" lock-check > /work/drift-fresh.log 2>&1 || status=$?
printf 'just lock-check: exit %s\n' "$status"

drifted() { # label, then the sed expression that drifts flake.nix
  printf '\n== %s\n' "$1"
  git checkout --quiet flake.nix
  sed -i "$2" flake.nix
  git diff --unified=0 flake.nix | grep '^[-+] ' | sed 's/^/  /'
  before=$(sha256sum flake.lock)
  status=0
  "$just" lock-check > /work/drift.log 2>&1 || status=$?
  printf 'just lock-check: exit %s\n' "$status"
  grep -E "error: |requires lock file changes" /work/drift.log | sed 's/^ */  /'
  after=$(sha256sum flake.lock)
  printf 'flake.lock before: %s\nflake.lock after:  %s\n' "$before" "$after"
  [ "$before" = "$after" ] && echo 'flake.lock is byte-identical'
  printf 'git status --short: %s\n' "$(git status --short | tr '\n' ' ')"
}
drifted 'flake.nix drops an input flake.lock still records' \
  '/nixpkgs-kubectl.url = /d; /^      nixpkgs-kubectl,$/d; s/nixpkgs-kubectl.legacyPackages/nixpkgs.legacyPackages/'
drifted 'An input moves to a channel nothing has fetched: offline, the check cannot even resolve it' \
  's,nixpkgs-kubectl.url = "github:NixOS/nixpkgs/nixos-26.05";,nixpkgs-kubectl.url = "github:NixOS/nixpkgs/nixos-25.11";,'
git checkout --quiet flake.nix
