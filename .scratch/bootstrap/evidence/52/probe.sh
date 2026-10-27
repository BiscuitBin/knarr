#!/bin/sh
# Ticket 52 evidence: why the erlang pin and the runtime base moved, live.
#
#   1. OSV.dev's records of the advisories audit run 39896502411 named: each
#      one's OTP 29 fix, quoted from its details, and whether its enumerated
#      tags hold OTP-29.1.1 and the pinned tag. A record that lists the pinned
#      tag, or fixes OTP 29 after it, fails the run.
#   2. scripts/checks/hex_audit.py on the committed tree, which must exit 0,
#      and on a control with the pin moved back to 29.1.1, which must exit 1
#      and name the three OSV advisories.
#   3. conda-forge's build of the pinned erlang on each locked platform, and
#      the newest erlang version there.
#   4. The runtime base: the digest ubuntu:24.04 names today against the
#      pinned one, libssl3t64 in the pinned index's amd64 and arm64 images, and
#      grype with just image-scan's flags on the pinned amd64 image, which must
#      exit 0, and on the previous pin as a control, which must exit 2.
#
# Needs network, curl, git, docker with buildx, pixi, and the pixi default and
# audit environments (just initialize). grype downloads its database on first
# use. Every container it starts is removed.
# Usage: sh probe.sh <empty-work-dir>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
wt=$(cd "$here/../../../.." && pwd)
py=$wt/.pixi/envs/default/bin/python3
grype=$wt/.pixi/envs/audit/bin/grype
previous='ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55'
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$py" ] || fail "$py is missing; run just initialize"
[ -x "$grype" ] || fail "$grype is missing; run just initialize"
mkdir -p "${1:?usage: probe.sh <empty-work-dir>}"
work=$(cd "$1" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
printf 'revision: %s\n' "$(git -C "$wt" rev-parse --short HEAD)"
mkdir "$work/head"
git -C "$wt" archive HEAD | tar -x -C "$work/head"
pin=$(sed -n 's/^erlang = "==\([^"]*\)"$/\1/p' "$work/head/pixi.toml")
[ -n "$pin" ] || fail 'no exact erlang pin in pixi.toml'
printf 'erlang pin: %s\n' "$pin"

echo '== 1. OSV.dev records'
for id in CVE-2026-105236 CVE-2026-42789 EEF-CVE-2026-42789 CVE-2026-96596 CVE-2026-94200; do
  curl -fsS --max-time 60 -o "$work/$id.json" "https://api.osv.dev/v1/vulns/$id"
  "$py" -I - "$work/$id.json" "$pin" <<'EOF'
import json
import re
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
pin = sys.argv[2]
tags = {v for a in record.get("affected", []) for v in a.get("versions", [])}
# The details name the fixed releases after "before", with non-breaking spaces.
details = record["details"].replace("\xa0", " ")
fixes = sorted({fix for clause in re.findall(r"before (OTP [^;]*?), corresponding", details)
                for fix in re.findall(r"OTP (29(?:\.[0-9]+)+)", clause)})
print(f"-- {record['id']} ({', '.join(record.get('aliases', []))})")
print(f"  {record['summary']}")
print(f"  published {record['published'][:10]}, modified {record['modified'][:10]}")
print(f"  OTP 29 fixed in: {', '.join(fixes) or 'not stated'}")
print(f"  tags: OTP-29.1.1 {'listed' if 'OTP-29.1.1' in tags else 'not listed'}, "
      f"OTP-{pin} {'listed' if f'OTP-{pin}' in tags else 'not listed'} ({len(tags)} enumerated)")
version = lambda v: tuple(int(n) for n in v.split("."))
if f"OTP-{pin}" in tags:
    sys.exit(f"FAIL: {record['id']} lists OTP-{pin}")
if not fixes:
    sys.exit(f"FAIL: {record['id']} states no OTP 29 fix")
if any(version(fix) > version(pin) for fix in fixes):
    sys.exit(f"FAIL: {record['id']} fixes OTP 29 after {pin}")
EOF
done

echo '== 2. hex_audit.py'
audit() { # label, project: prints the audit's output and sets rc
  echo "-- $1"
  set +e
  "$py" -I "$work/head/scripts/checks/hex_audit.py" "$2" > "$work/out" 2>&1
  rc=$?
  set -e
  sed -e 's/ *$//' -e 's/^/  /' "$work/out"
  echo "  exit $rc"
}
audit 'the committed tree' "$work/head"
[ "$rc" = 0 ] || fail "the audit exited $rc on the committed tree, want 0"
mkdir "$work/control"
cp "$work/head/manifest.toml" "$work/control/"
sed 's/^erlang = "==[^"]*"$/erlang = "==29.1.1"/' "$work/head/pixi.toml" > "$work/control/pixi.toml"
audit 'control: the committed manifest with erlang ==29.1.1' "$work/control"
[ "$rc" = 1 ] || fail "the control exited $rc, want 1"
for id in CVE-2026-105236 CVE-2026-42789 CVE-2026-96596; do
  grep -q "^$id  Erlang/OTP 29.1.1 " "$work/out" || fail "the control does not name $id"
done

echo '== 3. conda-forge erlang builds'
for platform in $(sed -n 's/^platforms = \[\(.*\)\]$/\1/p' "$work/head/pixi.toml" | tr -d '",'); do
  pixi search --platform "$platform" --channel conda-forge "erlang==$pin" > "$work/search" 2>&1 ||
    fail "no erlang $pin for $platform"
  # pixi prints the newest build first, then the other versions and builds.
  build=$(sed -n 's/^Build  *//p' "$work/search" | head -n 1)
  stamp=$(sed -n 's/^Timestamp  *//p' "$work/search" | head -n 1)
  [ -n "$build" ] || fail "no erlang $pin build for $platform"
  grep -q "/$platform/erlang-$pin-$build.conda" "$work/head/pixi.lock" || fail "pixi.lock does not lock erlang-$pin-$build for $platform"
  pixi search --platform "$platform" --channel conda-forge erlang > "$work/newest" 2>&1 ||
    fail "no erlang for $platform"
  newest=$(sed -n 's/^Version  *//p' "$work/newest" | head -n 1)
  printf '%-14s erlang %s %s, %s, locked; newest %s\n' "$platform" "$pin" "$build" "$stamp" "$newest"
done

echo '== 4. the runtime base'
pinned=$(sed -n 's/^FROM \(ubuntu:[^ ]*\) AS runtime$/\1/p' "$work/head/Dockerfile")
[ -n "$pinned" ] || fail 'no ubuntu runtime FROM line'
today=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "${pinned%@*}" |
  "$py" -I -c 'import json, sys; print(json.load(sys.stdin)["digest"])')
printf 'pinned:    %s\n' "${pinned#*@}"
printf 'tag today: %s\n' "$today"
for platform in linux/amd64 linux/arm64; do
  libssl=$(docker run --rm --platform "$platform" "$pinned" dpkg-query -W -f '${Version}' libssl3t64)
  printf 'libssl3t64 %s: %s\n' "$platform" "$libssl"
done
scan() { # label, image: grype with just image-scan's flags on the amd64 image; sets rc
  echo "-- grype $1"
  set +e
  "$grype" --platform linux/amd64 "$2" --only-fixed --fail-on high > "$work/out" 2> "$work/err"
  rc=$?
  set -e
  sed -e 's/ *$//' -e 's/^/  /' "$work/out"
  grep 'severity threshold' "$work/err" | sed -e "s/$(printf '\033')\\[[0-9;]*m//g" -e 's/^/  /' || true
  echo "  exit $rc"
}
scan 'the pinned base' "$pinned"
[ "$rc" = 0 ] || fail "grype exited $rc on the pinned base, want 0"
scan 'control: the previous pin' "$previous"
[ "$rc" = 2 ] || fail "grype exited $rc on the previous pin, want 2"
grep -q '^libssl3t64 .* CVE-2026-84782 *High' "$work/out" || fail 'the control does not list CVE-2026-84782'
"$grype" db status | sed -n 's/^Built: */grype database built: /p'
