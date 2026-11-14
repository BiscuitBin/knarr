#!/bin/sh
# Ticket 01 evidence: how OTP 29.1.2 with its OpenSSL, Gleam 1.19.0 and
# kubectl 1.36 are held, and whether each hold keeps the binary cache.
# Usage (host): sh nix.sh sh /evidence/holds.sh > holds.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
gleam_rev=$(locked nixpkgs-gleam)
kubectl_rev=$(locked nixpkgs-kubectl)
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)"

attribute() { # revision, system, attribute path, what to print
  quiet nix eval --raw "github:NixOS/nixpkgs/$1#legacyPackages.$2.$3" --apply "$4"
}
# One line per system: the version, the OpenSSL it is built against if it has
# one among its build inputs, the output path and whether the cache has it.
on_each_system() { # revision, attribute path
  for system in $systems; do
    version=$(attribute "$1" "$system" "$2" 'package: package.version')
    # shellcheck disable=SC2016 # a Nix expression, not shell
    ssl=$(attribute "$1" "$system" "$2" 'package: let found = builtins.filter (input: (input.pname or "") == "openssl") (package.buildInputs or [ ]); in if found == [ ] then "" else " (openssl ${(builtins.head found).version})"')
    out=$(attribute "$1" "$system" "$2" 'package: package.outPath')
    printf '  %-15s %s%s  %s  cached=%s\n' "$system" "$version" "$ssl" "$out" "$(cached "$out")"
  done
}

printf '\n== The channel heads on 2026-11-14 (aarch64-linux versions)\n'
for channel in nixpkgs-unstable nixos-unstable nixos-26.05; do
  head=$(git ls-remote https://github.com/NixOS/nixpkgs "refs/heads/$channel" | cut -f1)
  printf '%-17s %s  ' "$channel" "$head"
  # shellcheck disable=SC2016 # a Nix expression, not shell
  attribute "$head" aarch64-linux '' 'pkgs: "erlang_29 ${pkgs.beam_minimal.interpreters.erlang_29.version}, openssl ${pkgs.openssl.version}, gleam ${pkgs.gleam.version}, helm ${pkgs.kubernetes-helm.version}, kwok ${pkgs.kwok.version}, kubectl ${pkgs.kubectl.version}, python314 ${pkgs.python314.version}, pytest ${pkgs.python314Packages.pytest.version}"'
  echo
done

printf '\n== nixpkgs history: the unstable channel releases around Gleam 1.19.0\n'
printf '(releases.nixos.org lists each channel head; the version lines are read from that commit)\n'
for prefix in nixpkgs/nixpkgs-26.11pre nixos/unstable/nixos-26.11pre; do
  curl -fsSL "https://nix-releases.s3.amazonaws.com/?delimiter=/&prefix=$prefix" |
    tr '<' '\n' | sed -n "s,^Prefix>\(${prefix}[0-9]*\.[0-9a-f]*\)/\$,\1,p"
done | awk -F'pre' '{ split($2, part, "."); if (part[1] >= 1085700 && part[1] <= 1093000) print part[1], $0 }' |
  sort -n | cut -d' ' -f2 | while read -r release; do
  commit=${release##*.}
  raw=https://raw.githubusercontent.com/NixOS/nixpkgs/$commit
  gleam=$(curl -fsSL "$raw/pkgs/by-name/gl/gleam/package.nix" | sed -n 's/^ *version = "\(.*\)";/\1/p' | head -n 1)
  erlang=$(curl -fsSL "$raw/pkgs/development/interpreters/erlang/29.nix" | sed -n 's/^ *version = "\(.*\)";/\1/p' | head -n 1)
  printf '%-52s gleam %-7s erlang_29 %s\n' "$release" "$gleam" "$erlang"
done
printf 'nixpkgs-26.11pre1088030.8edc0c72e3a3 is commit %s\n' \
  "$(curl -fsSL https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1088030.8edc0c72e3a3/git-revision)"

printf '\n== Erlang/OTP and its OpenSSL\n'
printf 'candidate %s, beam_minimal.interpreters.erlang_29 (the prototype uses this):\n' "$rev"
on_each_system "$rev" beam_minimal.interpreters.erlang_29
printf 'candidate, beam_minimal.packages.erlang_29.rebar3:\n'
on_each_system "$rev" beam_minimal.packages.erlang_29.rebar3
printf 'candidate, beam.interpreters.erlang_29 (with wxWidgets and systemd):\n'
on_each_system "$rev" beam.interpreters.erlang_29
printf 'candidate, openssl:\n'
on_each_system "$rev" openssl
printf 'candidate, openssl_3_6: %s\n' \
  "$(nix eval --raw "github:NixOS/nixpkgs/$rev#legacyPackages.aarch64-linux.openssl_3_6.version" 2>&1 | grep '^ *error:' | tail -n 1)"
printf 'nixos-26.05 %s, beam_minimal.interpreters.erlang_29 (OpenSSL 3.6.5, as pixi.lock has):\n' "$kubectl_rev"
on_each_system "$kubectl_rev" beam_minimal.interpreters.erlang_29
printf 'candidate erlang overridden to build against the nixos-26.05 openssl:\n'
for system in $systems; do
  out=$(quiet nix eval --raw --impure --expr "
    let candidate = (builtins.getFlake \"github:NixOS/nixpkgs/$rev\").legacyPackages.$system;
        other = (builtins.getFlake \"github:NixOS/nixpkgs/$kubectl_rev\").legacyPackages.$system;
    in (candidate.beam_minimal.interpreters.erlang_29.override { inherit (other) openssl; }).outPath")
  printf '  %-15s %s  cached=%s\n' "$system" "$out" "$(cached "$out")"
done

printf '\n== Gleam\n'
printf 'candidate %s, gleam:\n' "$rev"
on_each_system "$rev" gleam
printf 'nixpkgs-gleam input %s, gleam (the prototype uses this):\n' "$gleam_rev"
on_each_system "$gleam_rev" gleam
printf '(gleam-override.txt has the override: not cached on any system)\n'

printf '\n== kubectl\n'
printf 'candidate %s, kubectl:\n' "$rev"
on_each_system "$rev" kubectl
printf 'nixpkgs-kubectl input %s, kubectl (the prototype uses this):\n' "$kubectl_rev"
on_each_system "$kubectl_rev" kubectl

printf '\n== The built environments on this system: where each held package came from\n'
fresh_proto /work/holds
cd /work/holds || exit 1
nix build .#default --out-link /work/holds/default 2> /dev/null
nix build .#cluster --out-link /work/holds/cluster 2> /dev/null
nix build .#runtime --out-link /work/holds/runtime 2> /dev/null
printf '(a cache.nixos.org-1 signature means the path was substituted; a path built here has none)\n'
for link in default cluster; do
  nix path-info -r "/work/holds/$link" |
    grep -E -- '-(erlang|openssl|gleam|rebar3|kubectl|kind|kwok|allium|python3|nodejs|knarr)[-.0-9a-z]*$' |
    while read -r stored; do
      printf '%-9s %-66s %s\n' "$link" "$stored" "$(nix path-info --sigs "$stored" | cut -f2- | cut -d: -f1)"
    done
done

printf '\n== One Erlang and one OpenSSL in each closure\n'
for link in default runtime; do
  printf '%s: ' "$link"
  nix path-info -r "/work/holds/$link" | grep -E -c -- '-erlang-[0-9]' | tr '\n' ' '
  printf 'erlang, '
  nix path-info -r "/work/holds/$link" | grep -E -c -- '-openssl-[0-9.]*$' | tr '\n' ' '
  printf 'openssl library\n'
done
PATH=/work/holds/default/bin:$PATH
gleam --version
rebar3 --version
erl -noshell -eval 'io:format("otp_release ~s, erts ~s~ncrypto:info_lib() ~p~n", [erlang:system_info(otp_release), erlang:system_info(version), crypto:info_lib()]), halt().'
openssl version
printf 'erl resolves to %s\n' "$(readlink -f "$(command -v erl)")"
printf 'runtime erl resolves to %s\n' "$(readlink -f /work/holds/runtime/bin/erl)"
/work/holds/cluster/bin/kubectl version --client 2> /dev/null | head -n 1
/work/holds/cluster/bin/kind version
/work/holds/cluster/bin/kwokctl --version

printf '\n== A lock move that loses a held version fails evaluation\n'
# Each override makes one held package the wrong version; both must fail.
for override in "nixpkgs-gleam github:NixOS/nixpkgs/$rev" "nixpkgs github:NixOS/nixpkgs/$gleam_rev"; do
  # shellcheck disable=SC2086 # an input name and a flake reference
  if nix eval .#packages.aarch64-linux.default.outPath --no-write-lock-file \
    --override-input $override > /work/holds/.out 2>&1; then
    echo "UNEXPECTED: evaluation passed with --override-input $override"
    exit 1
  fi
  grep -E '^ *error: held' /work/holds/.out
done
