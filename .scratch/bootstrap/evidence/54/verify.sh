#!/bin/sh
# Bootstrap ticket 54 evidence, adapted from helm chart ticket 07's verify.sh:
# the install guide's "Verify a release" commands on v0.3.1, the first stable
# release that carries attestations. Changed from 07's: the last section also
# runs the guide's own `helm show values ... | grep 'digest:'` and prints what
# it prints, as an operator following the guide would see it. Each
# digest is verified twice: from GitHub's attestations API (gh's default),
# which the attestations: write scope fed, and with --bundle-from-oci, from
# the copy push-to-registry stored on ghcr.io beside the digest. The chart's
# second read is the one no source checked before the release says ghcr.io
# accepts. Every verify requires release.yml in BiscuitBin/knarr as the
# signer. --signer-workflow matches the certificate's workflow URI with case,
# and the certificate spells the owner BiscuitBin: the lowercase owner fails
# with only 'Error: verifying with issuer "sigstore.dev"'. Registry names stay
# lowercase. Then the chart's stamped image.digest must be the image digest.
# gh and helm read only. Needs an authenticated gh. gh reads an oci://
# subject with the registry credentials docker would use; both packages are
# public, but if a verify fails on authentication, docker login ghcr.io and
# rerun: that failure is not the chart finding. helm is the project's, from
# the pixi environment: put .pixi/envs/default/bin first on PATH.
# Usage: sh verify.sh <image digest> <chart digest> > verify.txt 2>&1
set -eu
usage='usage: verify.sh <image digest> <chart digest>'
image_digest=${1:?$usage}
chart_digest=${2:?$usage}
repo=BiscuitBin/knarr
workflow=BiscuitBin/knarr/.github/workflows/release.yml
image=ghcr.io/biscuitbin/knarr
chart=ghcr.io/biscuitbin/charts/knarr
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for d in "$image_digest" "$chart_digest"; do
  printf '%s\n' "$d" | grep -qE '^sha256:[0-9a-f]{64}$' || fail "'$d' is not sha256:<64 hex>"
done
v=$(gh --version) || fail 'gh --version failed'
h=$(helm version --short) || fail 'helm version failed'
printf 'date: %s\n%s\nhelm %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(printf '%s\n' "$v" | head -n 1)" "$h"

verify() { # label, subject, [gh flags...]
  label=$1; subject=$2; shift 2
  printf '\n== %s: gh attestation verify %s %s\n' "$label" "$subject" "$*"
  gh attestation verify "$subject" --repo "$repo" --signer-workflow "$workflow" "$@" ||
    fail "$label: gh attestation verify $subject $* failed"
  printf 'ok   %s\n' "$label"
}
verify 'image, from GitHub' "oci://$image@$image_digest"
verify 'image, from ghcr.io' "oci://$image@$image_digest" --bundle-from-oci
verify 'chart, from GitHub' "oci://$chart@$chart_digest"
verify 'chart, from ghcr.io' "oci://$chart@$chart_digest" --bundle-from-oci

printf '\n== the chart pins the verified image\n'
values=$(helm show values "oci://$chart@$chart_digest") || fail 'helm show values failed'
stamped=$(printf '%s\n' "$values" | sed -nE 's/^  digest: *"?(sha256:[0-9a-f]{64})"?$/\1/p')
[ "$stamped" = "$image_digest" ] || fail "the chart's image.digest is '$stamped', not $image_digest"
printf 'ok   image.digest: %s\n' "$stamped"

printf '\n== the guide: helm show values oci://%s@%s | grep digest:\n' "$chart" "$chart_digest"
v=$(helm show values "oci://$chart@$chart_digest" | grep 'digest:') || fail "the guide's helm show values | grep 'digest:' failed"
printf '%s\n' "$v"
printf '%s\n' "$v" | grep -qF "$image_digest" || fail "the guide's digest: line does not print $image_digest"
printf 'ok   the guide prints %s\n' "$image_digest"
echo; echo 'verify passed'
