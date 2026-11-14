#!/bin/sh
# Ticket 01 evidence: grype on the prototype's runtime closure, as a directory
# and as the image. grype is the prototype flake's audit group. The image is
# the archive the host saved first:
#   docker save knarr-nix-proto:01 --output ai_tmp/knarr-nix-proto.tar
# grype would download its vulnerability database on first use. This run made
# no download: it used the database the host's grype had already cached,
# copied to scratch beforehand, and ran with the network off:
#   cp -R ~/Library/Caches/grype/db/6 ai_tmp/grype-db/
# What grype catalogues does not depend on the database's age; what it matches
# does, and the transcript prints the database's build date.
# Usage (host): sh nix.sh sh /evidence/grype.sh prepare   (network: fetches the Nix paths)
#               sh nix.sh --offline sh /evidence/grype.sh > grype.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
links=/work/grype-links
if [ "${1:-}" = prepare ]; then
  mkdir -p "$links"
  fresh_proto "$links/proto"
  nix build "$links/proto#audit" --out-link "$links/audit" 2> /dev/null
  nix build "$links/proto#runtime" --out-link "$links/runtime" 2> /dev/null
  # The control: the same two packages one revision back, at the nixpkgs-gleam
  # input, where Erlang is 29.1.1. Four advisories fixed in 29.1.2 apply to it
  # (Decision 0003), so a scan that can match must match here.
  nix build --out-link "$links/control" --impure --expr "
    with (builtins.getFlake \"github:NixOS/nixpkgs/$(locked nixpkgs-gleam)\").legacyPackages.\${builtins.currentSystem};
    buildEnv { name = \"knarr-runtime-control\"; paths = [ beam_minimal.interpreters.erlang_29 openssl.bin ]; pathsToLink = [ \"/bin\" ]; }" 2> /dev/null
  exit 0
fi
rm -rf /work/grype
mkdir -p /work/grype
PATH=$links/audit/bin:$PATH
cp -R /bundle/grype-db /work/grype/db
GRYPE_CHECK_FOR_APP_UPDATE=false
GRYPE_DB_CACHE_DIR=/work/grype/db
GRYPE_DB_AUTO_UPDATE=false
GRYPE_DB_VALIDATE_AGE=false
export GRYPE_CHECK_FOR_APP_UPDATE GRYPE_DB_CACHE_DIR GRYPE_DB_AUTO_UPDATE GRYPE_DB_VALIDATE_AGE
printf 'date: %s\n%s (pixi.toml pins 0.120.1)\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(grype --version)"
printf 'database: %s\n' "$(jq -r .source /work/grype/db/6/import.json | sed 's/.*vulnerability-db_\(v[0-9.]*\)_\([0-9-]*\)T.*/\1, built \2/')"

# A directory source: a closure's store paths under nix/store, as the image
# carries them and as `docker cp <container>:/nix` would copy them out.
closure() { # name, out-link
  mkdir -p "/work/grype/$1/nix/store"
  nix path-info --recursive "$2" 2> /dev/null > "/work/grype/$1.txt"
  xargs cp --archive --target-directory="/work/grype/$1/nix/store" < "/work/grype/$1.txt"
  printf '%s: %s store paths, %s\n' "$1" "$(wc -l < "/work/grype/$1.txt")" "$(du -sh "/work/grype/$1" | cut -f1)"
}
closure closure "$links/runtime"
closure control "$links/control"

scan() { # label, source
  printf '\n== %s: grype -vv %s --only-fixed --fail-on high\n' "$1" "$2"
  status=0
  grype -vv "$2" --only-fixed --fail-on high -o json > /work/grype/out.json 2> /work/grype/log || status=$?
  printf 'exit %s\n' "$status"
  printf 'the cataloger lines runtime_scan.py reads (it wants conda-meta-cataloger):\n'
  grep -o 'discovered [0-9]* packages cataloger=[a-z0-9-]*' /work/grype/log | grep -v 'discovered 0 ' | sed 's/^/  /'
  printf '  catalogers that discovered nothing: %s\n' "$(grep -c 'discovered 0 packages cataloger=' /work/grype/log)"
  grep -o 'conda-meta-cataloger' /work/grype/log | sort -u | sed 's/^/  named in the log: /'
  printf 'matches: %s; by severity: %s\n' "$(jq '.matches | length' /work/grype/out.json)" \
    "$(jq -r '[.matches[].vulnerability.severity] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' /work/grype/out.json)"
  printf 'matches by package: %s\n' "$(jq -r '[.matches[].artifact | "\(.name) \(.version) (\(.type))"] | group_by(.) | map("\(.[0]): \(length)") | join("; ")' /work/grype/out.json)"
  printf 'advisories matched on erlang: %s\n' "$(jq -r '[.matches[] | select(.artifact.name == "erlang") | "\(.vulnerability.id) \(.vulnerability.severity), fixed in \(.vulnerability.fix.versions | join(" "))"] | unique | join("; ")' /work/grype/out.json | cut -c1-700)"
  # The same source through grype's SBOM output, which lists every catalogued
  # package, matched or not.
  grype "$2" -o cyclonedx-json > /work/grype/sbom.json 2> /dev/null || true
  printf 'catalogued packages: %s\n' "$(jq '[.components[] | select(.type != "file")] | length' /work/grype/sbom.json)"
  printf 'erlang and openssl among them (name, version, cataloger, package URL):\n'
  jq -r '.components[] | select(.type != "file") | select(.name | test("erlang|^erts$|openssl|^crypto$|^ssl$|^public_key$"; "i")) |
    "  \(.name) \(.version)  \([(.properties // [])[] | select(.name == "syft:package:foundBy") | .value] | join(","))  \(.purl // "")"' \
    /work/grype/sbom.json | sort -u | cut -c1-170
  printf 'by package type: %s\n' "$(jq -r '[.components[] | select(.type != "file") | ([(.properties // [])[] | select(.name == "syft:package:type") | .value] | .[0] // "unknown")] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' /work/grype/sbom.json)"
}
scan 'Directory source' dir:/work/grype/closure
scan 'Directory source, the control with OTP 29.1.1' dir:/work/grype/control
if [ -f /bundle/knarr-nix-proto.tar ]; then
  scan 'Image source' docker-archive:/bundle/knarr-nix-proto.tar
else
  printf '\n(no /bundle/knarr-nix-proto.tar: the image source was not scanned)\n'
fi
