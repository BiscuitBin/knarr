#!/bin/sh
# Ticket 52 evidence: the knarr image built here, for the host's architecture
# (linux/arm64 on Apple silicon, ticket 50), from the committed tree. CI builds
# and scans amd64; this is the same Dockerfile and lock before that run.
#
#   1. just image-check: OTP and erts in the image, and Decision 0003's
#      tls_check.escript in the pruned runtime environment.
#   2. just image-scan and just runtime-scan, which must both exit 0.
#   3. How the image scan sees OTP: the cataloger, type and file syft reports
#      for erlang in the image, read from grype's CycloneDX output.
#
# It builds the worktree's own image tag and leaves it in place, as
# just image-build does. Needs network for the build and grype's database,
# docker, and the pixi default and audit environments (just initialize).
# Usage: sh local-image.sh <empty-work-dir>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
wt=$(cd "$here/../../../.." && pwd)
py=$wt/.pixi/envs/default/bin/python3
grype=$wt/.pixi/envs/audit/bin/grype
just=$wt/.pixi/envs/default/bin/just
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$grype" ] || fail "$grype is missing; run just initialize"
mkdir -p "${1:?usage: local-image.sh <empty-work-dir>}"
work=$(cd "$1" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
[ -z "$(git -C "$wt" status --porcelain -- Dockerfile .dockerignore pixi.toml pixi.lock gleam.toml manifest.toml src scripts)" ] ||
  fail 'the build inputs differ from HEAD'
printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
printf 'revision: %s\n' "$(git -C "$wt" rev-parse --short HEAD)"
image=knarr:$(sh "$wt/scripts/cluster-name.sh" "$wt" name)
printf 'image: %s, %s\n' "$image" "$(uname -m)"
cd "$wt"
"$just" image-build > "$work/build" 2>&1 || { tail -20 "$work/build"; fail 'just image-build failed'; }

echo '== 1. just image-check'
"$just" image-check > "$work/check" 2>&1 || { cat "$work/check"; fail 'just image-check failed'; }
grep -E '^(openssl: |otp_release |ssl:versions|ok +|BAD +|tls_check: |image: )' "$work/check" | awk '!seen[$0]++' |
  sed -E 's/(want [a-z_]+) +got .*/\1/'
grep -q '^tls_check: all 6 cases matched$' "$work/check" || fail 'tls_check did not match all 6 cases'

echo '== 2. just image-scan and just runtime-scan'
for recipe in image-scan runtime-scan; do
  set +e
  "$just" "$recipe" > "$work/$recipe" 2>&1
  rc=$?
  set -e
  grep -E '^(No vulnerabilities found|NAME |runtime-scan: )|^[a-z0-9][a-z0-9.+_-]* +[^ ]+ +[^ ]+ +[a-z-]+ +(CVE|GHSA)' "$work/$recipe" |
    sed -e 's/ *$//' -e 's/^/  /'
  echo "  $recipe exit $rc"
  [ "$rc" = 0 ] || fail "just $recipe exited $rc, want 0"
done

echo '== 3. erlang in the image scan'
"$grype" "$image" -o cyclonedx-json > "$work/sbom.json" 2> /dev/null
"$py" -I - "$work/sbom.json" <<'EOF'
import json
import sys

found = False
for component in json.load(open(sys.argv[1], encoding="utf-8")).get("components", []):
    if component.get("name") != "erlang":
        continue
    props = {p["name"]: p["value"] for p in component.get("properties", [])}
    path = next((v for k, v in props.items() if k.startswith("syft:location:") and k.endswith(":path")), "")
    print(f"  {component['name']} {component.get('version')}: {props.get('syft:package:foundBy')}, "
          f"type {props.get('syft:package:type')}, {component.get('cpe')}")
    print(f"  from {path}")
    found = True
if not found:
    sys.exit("FAIL: the image scan catalogued no erlang")
EOF
