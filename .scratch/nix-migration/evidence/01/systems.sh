#!/bin/sh
# Ticket 01 evidence: the container, and proof that aarch64-linux can evaluate
# the other two systems and ask the binary cache about them.
# Usage (host): sh nix.sh sh /evidence/systems.sh > systems.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
printf 'date: %s\nhost: %s\n%s\nsystem: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$(nix --version)" "$(nix config show system)"
printf 'substituters: %s\nsandbox: %s\n' "$(nix config show substituters)" "$(nix config show sandbox)"
printf 'candidate nixpkgs revision: %s (%s)\n' "$rev" \
  "$(quiet nix eval --raw "github:NixOS/nixpkgs/$rev#lib.trivial.version")"

printf '\n== One attribute evaluated for each system; the cache asked about each output path\n'
for system in $systems; do
  out=$(quiet nix eval --raw "github:NixOS/nixpkgs/$rev#legacyPackages.$system.beam_minimal.interpreters.erlang_29.outPath")
  printf '%-15s %s  cached=%s\n' "$system" "$out" "$(cached "$out")"
done

printf '\n== nix build --dry-run on a foreign system says what would be built and what fetched\n'
fresh_proto /work/systems
cd /work/systems || exit 1
for system in $systems; do
  printf -- '-- %s default\n' "$system"
  plan ".#packages.$system.default"
done

printf '\n== A foreign-system derivation cannot be built here\n'
if nix build --no-link --impure --expr \
  'derivation { name = "darwin-probe"; system = "aarch64-darwin"; builder = "/bin/sh"; }' > /work/systems/.out 2>&1; then
  echo 'UNEXPECTED: an aarch64-darwin derivation built on aarch64-linux'
  exit 1
fi
grep -v '^warning' /work/systems/.out
printf '(the build was refused, as expected)\n'
