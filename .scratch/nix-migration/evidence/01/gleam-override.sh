#!/bin/sh
# Ticket 01 evidence: the cost of holding Gleam 1.19.0 by override instead of
# by a second input. Neither output is in the binary cache, so both compile
# here with the candidate revision's Rust toolchain:
#   1. the 1.19.0 recipe from the nixpkgs-gleam input, called on the candidate;
#   2. the candidate's own recipe with 1.19.0's source and vendored crates.
# Usage (host): sh nix.sh sh /evidence/gleam-override.sh > gleam-override.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
held=$(locked nixpkgs-gleam)
native=$(nix config show system)
prelude() { # system
  printf '%s' "
    candidate = (builtins.getFlake \"github:NixOS/nixpkgs/$rev\").legacyPackages.$1;
    old = builtins.getFlake \"github:NixOS/nixpkgs/$held\";"
}
recipe() { # system
  printf '%s' "let $(prelude "$1") in
    candidate.callPackage (old.outPath + \"/pkgs/by-name/gl/gleam/package.nix\") { }"
}
override() { # system
  printf '%s' "let $(prelude "$1") held = old.legacyPackages.$1.gleam; in
    candidate.gleam.overrideAttrs (_: { inherit (held) version src cargoDeps; })"
}
printf 'date: %s\n%s on %s, %s cores\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)" "$(nproc)"

attempt() { # title, expression function
  printf '\n== %s\n' "$1"
  for system in $systems; do
    out=$(quiet nix eval --raw --impure --expr "($("$2" "$system")).outPath")
    printf '%-15s %s  cached=%s\n' "$system" "$out" "$(cached "$out")"
  done
  expression=$("$2" "$native")
  # A rerun must compile again, so an output left by an earlier run goes first.
  nix store delete "$(quiet nix eval --raw --impure --expr "($expression).outPath")" > /dev/null 2>&1 || true
  nix build --dry-run --impure --expr "$expression" 2>&1 | grep -E 'will be (built|fetched)|gleam.*\.drv$' || true
  start=$(date +%s)
  if out=$(nix build --no-link --print-out-paths --impure --expr "$expression" 2> /work/gleam-override.log); then
    printf 'built %s in %s seconds\n' "$out" "$(($(date +%s) - start))"
    "$out/bin/gleam" --version
    printf 'signatures: %s\n' "$(nix path-info --sigs "$out" | cut -f2- | cut -d: -f1)"
  else
    printf 'the build failed after %s seconds:\n' "$(($(date +%s) - start))"
    grep -E 'panicked|AWS_LC|^error' /work/gleam-override.log | head -n 6
  fi
}
attempt "1. The 1.19.0 recipe on the candidate's toolchain" recipe
attempt "2. The candidate's recipe with 1.19.0's source and crates" override
