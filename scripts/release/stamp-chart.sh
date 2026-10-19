#!/bin/sh
# Stamp the released image into a copy of the chart and package it (Decision
# 0015), for .github/workflows/release.yml's publish job after the image push.
# The tracked chart keeps its local values; only the copy is stamped, with
#   image.repository  <image>, the published repository
#   image.pullPolicy  IfNotPresent
#   image.digest      <digest>, the digest the image push printed
#   image.tag         <version>, so a user who clears image.digest gets the
#                     released tag, never the local build's `local`
# and the artifacthub.io/images annotation <image>@<digest> in Chart.yaml. It
# refuses unless Chart.yaml's version and appVersion both equal <version>, and
# then reads the package back with helm: the values and the annotation name the
# digest, and the render's image is <image>@<digest> with IfNotPresent.
# Nothing is left in <out-dir> unless every check passed. stamp-chart_test.sh
# beside it tests it offline.
# Needs helm, perl, sed and grep.
# Usage: sh stamp-chart.sh <chart-dir> <version> <image> <digest> <out-dir>
# Prints the path of the package it wrote.
set -eu
fail() { printf 'stamp-chart: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 5 ] || fail 'usage: stamp-chart.sh <chart-dir> <version> <image> <digest> <out-dir>'
chart=$1; version=$2; image=$3; digest=$4; out=$5
[ -f "$chart/Chart.yaml" ] && [ -f "$chart/values.yaml" ] || fail "$chart has no Chart.yaml and values.yaml"
printf '%s\n' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$' || fail "version '$version' is not X.Y.Z or X.Y.Z-rc.N"
printf '%s\n' "$image" | grep -qE '^[a-z0-9.:-]+(/[a-z0-9._-]+)+$' || fail "image '$image' is not a repository with no tag or digest"
printf '%s\n' "$digest" | grep -qE '^sha256:[0-9a-f]{64}$' || fail "digest '$digest' is not sha256:<64 hex>"

chart_version=$(sed -n 's/^version: *//p' "$chart/Chart.yaml" | tr -d '"')
app_version=$(sed -n 's/^appVersion: *//p' "$chart/Chart.yaml" | tr -d '"')
[ "$chart_version" = "$version" ] || fail "Chart.yaml version is '$chart_version', not the release's $version"
[ "$app_version" = "$version" ] || fail "Chart.yaml appVersion is '$app_version', not the release's $version"
! grep -q '^annotations:' "$chart/Chart.yaml" || fail 'Chart.yaml already has annotations; the stamp writes them'

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
copy=$work/knarr
cp -R "$chart" "$copy"

# Each image key sits once, two spaces in, under image:. Replace the whole line
# so the stamp never depends on the local value it replaces.
for key in repository tag digest pullPolicy; do
  [ "$(grep -c "^  $key:" "$copy/values.yaml")" -eq 1 ] || fail "values.yaml needs exactly one '  $key:' line under image"
done
STAMP_IMAGE=$image STAMP_DIGEST=$digest STAMP_VERSION=$version perl -i -pe '
  s/^  repository:.*$/  repository: $ENV{STAMP_IMAGE}/;
  s/^  tag:.*$/  tag: "$ENV{STAMP_VERSION}"/;
  s/^  digest:.*$/  digest: $ENV{STAMP_DIGEST}/;
  s/^  pullPolicy:.*$/  pullPolicy: IfNotPresent/;
' "$copy/values.yaml"
cat >> "$copy/Chart.yaml" << EOF
annotations:
  artifacthub.io/images: |
    - name: knarr
      image: $image@$digest
EOF

mkdir "$work/package"
helm package "$copy" --destination "$work/package" > "$work/package.log" 2>&1 || { cat "$work/package.log" >&2; fail 'helm package failed'; }
package=$work/package/knarr-$version.tgz
[ -f "$package" ] || fail "helm package wrote $(ls "$work/package"), not knarr-$version.tgz"

# Read the package back, as an installer would.
must() { # what, text, exact line
  printf '%s\n' "$2" | grep -qxF -- "$3" || fail "the packaged $1 has no line '$3'"
}
shown=$(helm show chart "$package")
must Chart.yaml "$shown" "version: $version"
must Chart.yaml "$shown" "appVersion: $version"
must Chart.yaml "$shown" "      image: $image@$digest"
values=$(helm show values "$package")
must values.yaml "$values" "  repository: $image"
must values.yaml "$values" "  digest: $digest"
must values.yaml "$values" '  pullPolicy: IfNotPresent'
render=$(helm template knarr "$package")
must render "$render" "          image: $image@$digest"
must render "$render" '          imagePullPolicy: IfNotPresent'

mkdir -p "$out"
mv "$package" "$out/"
printf '%s\n' "$out/knarr-$version.tgz"
