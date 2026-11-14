#!/bin/sh
# Ticket 01 evidence: every pixi.toml and tools.txt pin as the candidate
# nixpkgs revision carries it, on each system, and whether cache.nixos.org has
# the output. The held packages are then read from the inputs that hold them.
# Usage (host): sh nix.sh sh /evidence/packages.sh > packages.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)"

table() { # revision, system
  quiet nix eval --raw --impure --expr "
    let pkgs = (builtins.getFlake \"github:NixOS/nixpkgs/$1\").legacyPackages.$2;
    in builtins.concatStringsSep \"\n\" (map
      (row: \"\${row.pin}|\${row.pinned}|\${row.attr}|\${row.version}|\${toString row.out}|\${row.floor}\")
      (import /evidence/packages.nix pkgs))"
  echo
}

for system in $systems; do
  printf '\n== nixpkgs %s, %s\n' "$rev" "$system"
  printf '%-42s %-14s %-42s %-12s %-6s %s\n' pin pinned attribute version cached floor
  table "$rev" "$system" > /work/packages.rows
  while IFS='|' read -r pin pinned attr version out floor; do
    [ -n "$pin" ] || continue
    if [ -n "$out" ]; then have=$(cached "$out"); else have=-; fi
    printf '%-42s %-14s %-42s %-12s %-6s %s\n' "$pin" "$pinned" "$attr" "$version" "$have" "$floor"
  done < /work/packages.rows
done

printf '\n== The prototype flake: each group, what a fresh machine builds and what it fetches\n'
fresh_proto /work/packages
cd /work/packages || exit 1
for system in $systems; do
  for group in default cluster audit runtime; do
    printf -- '-- %s %s\n' "$system" "$group"
    plan ".#packages.$system.$group"
  done
done
