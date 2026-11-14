#!/bin/sh
# Ticket 01 evidence: the six TLS cases, outside the image, on each Erlang and
# OpenSSL pair the hold could choose: the candidate's (OpenSSL 3.5.9) and
# nixos-26.05's (OpenSSL 3.6.5, the version pixi.lock has). image.txt has the
# run that counts, in the prototype image.
# Usage (host): sh nix.sh sh /evidence/tls-pairs.sh > tls-pairs.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
other=$(locked nixpkgs-kubectl)
rm -rf /work/tls
mkdir -p /work/tls
git clone --quiet --branch 01-nix-container-spike /bundle/knarr.bundle /work/tls/clone
for revision in "$rev" "$other"; do
  printf '\n== nixpkgs %s\n' "$revision"
  environment=$(nix build --no-link --print-out-paths --impure --expr "
    with (builtins.getFlake \"github:NixOS/nixpkgs/$revision\").legacyPackages.\${builtins.currentSystem};
    buildEnv { name = \"tls-pair\"; paths = [ beam_minimal.interpreters.erlang_29 openssl.bin ]; pathsToLink = [ \"/bin\" ]; }" 2> /dev/null)
  printf 'closure: %s store paths, %s; glibc in it: %s\n' "$(nix path-info --recursive "$environment" | wc -l)" \
    "$(nix path-info --closure-size --human-readable "$environment" | cut -f2- | tr -d ' ')" \
    "$(nix path-info --recursive "$environment" | grep -E -c -- '-glibc-[0-9.-]*$')"
  sh /work/tls/clone/.scratch/bootstrap/evidence/01/tls/run.sh "$environment" "/work/tls/$revision" 2>&1 |
    sed -E 's/(got \{ok,\[\{protocol,[^}]*\}).*/\1, .../; s/(got \{error,\{tls_alert,\{[a-z_]*,).*/\1 .../'
done
