#!/bin/sh
# Ticket 07 evidence: the flake reads its held versions from pins.toml. Each
# case edits one entry of pins.toml in a copy of the clone, with the network
# off, and evaluates the default group: the assertion must refuse it and name
# the entry. flake.nix and flake.lock are untouched.
# Usage (Mac): sh host.sh --offline sh /evidence/holds.sh > holds.txt
set -eu
clone=/work/clone
copy=/work/holds
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
rm -rf "$copy"
git clone --quiet "$clone" "$copy"
cd "$copy"
printf 'copy of %s at %s\n' "$clone" "$(git rev-parse --short HEAD)"
evaluate() { # group
  nix eval --raw --offline --no-update-lock-file ".#$1.outPath" 2>&1 | grep -E '^/nix/store|error: held|error: erlang' || true
}
printf '\n== pins.toml as committed\n  default %s\n  cluster %s\n' "$(evaluate default)" "$(evaluate cluster)"
held() { # label, group, sed expression on pins.toml
  git checkout --quiet pins.toml
  sed -i "$3" pins.toml
  printf '\n== %s: %s\n  %s %s\n' "$1" "$(git diff --unified=0 pins.toml | grep '^+[a-z]')" "$2" "$(evaluate "$2")"
}
held 'Erlang, exact' default 's/^erlang = "29.1.2"/erlang = "29.1.1"/'
held 'Gleam, exact' default 's/^gleam = "1.19.0"/gleam = "1.19.2"/'
held 'kind, exact' cluster 's/^kind = "0.33.0"/kind = "0.34.0"/'
held 'kwokctl, exact' cluster 's/^kwokctl = "0.8.0"/kwokctl = "0.7.0"/'
held 'kubectl, a minor' cluster 's/^kubectl = "1.36"/kubectl = "1.37"/'
held 'rebar3, a floor raised above the input' default 's/^rebar3 = "3.28.0"/rebar3 = "3.29.0"/'
held 'rebar3, a floor lowered: still met, so the same environment' default 's/^rebar3 = "3.28.0"/rebar3 = "3.27.0"/'
git checkout --quiet pins.toml
printf '\ngit status --short: %s lines\n' "$(git status --short | wc -l)"
