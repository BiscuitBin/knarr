#!/bin/sh
# Tests for stamp-chart.sh, offline, in the style of lib_test.sh beside it;
# test_release_lib.py runs this file in `just test-checkers-selected release`.
# It stamps the tracked chart with a fixture digest and reads the package back
# with helm, then seeds the failures the release must refuse: a version that
# disagrees with Chart.yaml, an appVersion that disagrees, a malformed digest,
# and a values.yaml the stamp cannot find its keys in.
# Needs helm (the default pixi environment).
# Usage: sh scripts/release/stamp-chart_test.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
chart=$root/charts/knarr
stamp=$here/stamp-chart.sh
pass=0; failed=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { failed=$((failed + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
eq() { # description, actual, expected
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got '$2', want '$3'"; fi
}
has() { # description, text, line that must appear in it exactly
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1" "no line '$3' in: $(printf '%s' "$2" | head -c 600)"; fi
}

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

image=ghcr.io/steven-cutting/knarr
digest=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
version=$(sed -n 's/^version: *//p' "$chart/Chart.yaml")
before=$(cksum < "$chart/values.yaml")$(cksum < "$chart/Chart.yaml")

# The stamp: the fixture digest, the published repository and IfNotPresent.
mkdir "$work/out"
rc=0; package=$(sh "$stamp" "$chart" "$version" "$image" "$digest" "$work/out" 2> "$work/err") || rc=$?
eq 'stamp: a matching version stamps and packages' "$rc" 0
eq 'stamp: prints the package it wrote' "$package" "$work/out/knarr-$version.tgz"
eq 'stamp: the tracked chart is not touched' "$(cksum < "$chart/values.yaml")$(cksum < "$chart/Chart.yaml")" "$before"
if [ "$rc" -eq 0 ] && [ -f "$package" ]; then
  values=$(helm show values "$package")
  has 'values: image.digest is the fixture digest' "$values" "  digest: $digest"
  has 'values: image.repository is the published image' "$values" "  repository: $image"
  has 'values: image.pullPolicy is IfNotPresent' "$values" '  pullPolicy: IfNotPresent'
  has 'values: image.tag is the version, not local' "$values" "  tag: \"$version\""
  shown=$(helm show chart "$package")
  has 'chart: version is the release version' "$shown" "version: $version"
  has 'chart: appVersion is the release version' "$shown" "appVersion: $version"
  has 'chart: the artifacthub.io/images annotation names the digest' "$shown" "      image: $image@$digest"
  render=$(helm template knarr "$package" --namespace knarr)
  has 'render: the image is the stamped digest reference' "$render" "          image: $image@$digest"
  has 'render: imagePullPolicy is IfNotPresent' "$render" '          imagePullPolicy: IfNotPresent'
  eq 'render: no local image remains' "$(printf '%s\n' "$render" | grep -c -e ':local' -e 'imagePullPolicy: Never' || true)" 0
  cleared=$(helm template knarr "$package" --set image.digest=)
  has 'render: a cleared digest falls back to the released tag' "$cleared" "          image: $image:$version"
  eq 'package: the test-only ci/ values stay out' "$(tar -tzf "$package" | grep -c '/ci/' || true)" 0
else
  no 'stamp: the package exists' "$(cat "$work/err")"
fi

# Seeded failures: each refused, and nothing left in the out directory.
refused() { # description, stamp arguments...
  d=$1; shift
  out=$(mktemp -d "$work/refused.XXXXXX")
  rc=0; sh "$stamp" "$@" "$out" > /dev/null 2> "$out.err" || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$(ls -A "$out")" ]; then ok "$d"; else no "$d" "exit $rc, out: $(ls -A "$out"), stderr: $(cat "$out.err")"; fi
}
refused 'refused: a version that disagrees with Chart.yaml' "$chart" 9.9.9 "$image" "$digest"
refused 'refused: a malformed digest' "$chart" "$version" "$image" sha256:abc
refused 'refused: a digest with a tag' "$chart" "$version" "$image" "latest@$digest"
refused 'refused: no image' "$chart" "$version" '' "$digest"
refused 'refused: no chart directory' "$work/missing" "$version" "$image" "$digest"

skewed=$work/skewed
cp -R "$chart" "$skewed"
sed "s/^appVersion: .*/appVersion: \"9.9.9\"/" "$chart/Chart.yaml" > "$skewed/Chart.yaml"
refused 'refused: an appVersion that disagrees with the version' "$skewed" "$version" "$image" "$digest"

nodigest=$work/nodigest
cp -R "$chart" "$nodigest"
grep -v '^  digest:' "$chart/values.yaml" > "$nodigest/values.yaml"
refused 'refused: a values.yaml with no image.digest line to stamp' "$nodigest" "$version" "$image" "$digest"

printf '%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
