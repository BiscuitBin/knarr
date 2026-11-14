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
# Usage (host): sh nix.sh --offline sh /evidence/grype.sh > grype.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
rm -rf /work/grype
mkdir -p /work/grype/closure/nix/store /work/grype/proto
fresh_proto /work/grype/proto
nix build /work/grype/proto#audit --out-link /work/grype/audit 2> /dev/null
nix build /work/grype/proto#runtime --out-link /work/grype/runtime 2> /dev/null
PATH=/work/grype/audit/bin:$PATH
cp -R /bundle/grype-db /work/grype/db
GRYPE_CHECK_FOR_APP_UPDATE=false
GRYPE_DB_CACHE_DIR=/work/grype/db
GRYPE_DB_AUTO_UPDATE=false
GRYPE_DB_VALIDATE_AGE=false
export GRYPE_CHECK_FOR_APP_UPDATE GRYPE_DB_CACHE_DIR GRYPE_DB_AUTO_UPDATE GRYPE_DB_VALIDATE_AGE
printf 'date: %s\n%s (pixi.toml pins 0.120.1)\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(grype --version)"
printf 'database: %s\n' "$(jq -r .source /work/grype/db/6/import.json | sed 's/.*vulnerability-db_\(v[0-9.]*\)_\([0-9-]*\)T.*/\1, built \2/')"

# The directory source: the closure's store paths under nix/store, as the image
# carries them and as `docker cp <container>:/nix` would copy them out.
nix path-info --recursive /work/grype/runtime > /work/grype/closure.txt
xargs cp --archive --target-directory=/work/grype/closure/nix/store < /work/grype/closure.txt
printf 'runtime closure: %s store paths, %s\n' "$(wc -l < /work/grype/closure.txt)" "$(du -sh /work/grype/closure | cut -f1)"

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
  printf 'matched packages: %s\n' "$(jq -r '[.matches[].artifact | "\(.name) \(.version) (\(.type))"] | unique | join("; ")' /work/grype/out.json | cut -c1-400)"
  # The same source through grype's SBOM output, which lists every catalogued
  # package, matched or not.
  grype "$2" -o cyclonedx-json > /work/grype/sbom.json 2> /dev/null || true
  printf 'catalogued packages: %s\n' "$(jq '.components | length' /work/grype/sbom.json)"
  printf 'erlang and openssl among them:\n'
  jq -r '.components[] | select(.name | test("erlang|^erts$|openssl|^otp|^crypto$|^ssl$|^public_key$"; "i")) |
    "  \(.name) \(.version) [\(.type)] \((.properties // []) | map(select(.name | test("foundBy|cataloger|package:type"))) | map(.value) | join(","))  \(.purl // "")"' \
    /work/grype/sbom.json | sort -u | cut -c1-170
  printf 'by package type: %s\n' "$(jq -r '[.components[] | ((.properties // []) | map(select(.name == "syft:package:type")) | .[0].value // .type)] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' /work/grype/sbom.json)"
}
scan 'Directory source' dir:/work/grype/closure
if [ -f /bundle/knarr-nix-proto.tar ]; then
  scan 'Image source' docker-archive:/bundle/knarr-nix-proto.tar
else
  printf '\n(no /bundle/knarr-nix-proto.tar: the image source was not scanned)\n'
fi
