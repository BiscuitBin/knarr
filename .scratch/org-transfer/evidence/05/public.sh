#!/bin/sh
# Org transfer ticket 05 evidence, adapted from bootstrap ticket 40's
# public.sh: the image ghcr.io/biscuitbin/knarr and the chart
# ghcr.io/biscuitbin/charts/knarr as anyone sees them, with no credentials.
# The image: an anonymous pull token is granted; with it, every tag release.yml
# pushed for this release, and the digest itself, answer 200 with the run's
# digest; `latest` answers 404; tags/list holds exactly this release's three
# tags; and probe_tag reads `present` for the version, the existence guard
# refusing a second push without one made.
# The chart: an anonymous pull token is granted for its own repository; the
# version and the chart digest answer 200 with the run's chart digest;
# tags/list holds exactly the version; the manifest's chart layer, fetched and
# checked against its digest, packages a Chart.yaml and values.yaml that name
# the image digest; and probe_tag reads `present` for the version.
# The packages under steven-cutting: 0.2.0's image and chart still answer at
# 0.2.0's digests, since this release must leave them as they were.
# Changed from 40's: the repositories are under biscuitbin; both packages are
# new, so neither tags/list holds an earlier release; the earlier release is
# checked where it was published, under steven-cutting. An anonymous token
# refused (GHCR answers 403 for a package it will not show) is the
# not-public outcome Decision 0016 leaves open: the script says so and
# stops, and the maintainer makes that package public by hand before a rerun.
# The layer is saved in a temporary directory removed at exit, and only its
# two named members are read, to stdout; nothing is extracted.
# A bare HEAD with no token answers 401 even for a public package; a registry
# client fetches the anonymous token first, and so does this script. No token
# is printed. Exits non-zero on any unexpected answer.
# Usage: sh public.sh <tag> <commit> <sha256:image-digest> <sha256:chart-digest> > public.txt 2>&1
# shellcheck disable=SC2154  # lib.sh's probe_tag and registry_head set code, verdict and verdict_rc; the gate runs without -x
set -eu
usage='usage: public.sh <tag> <commit> <sha256:image-digest> <sha256:chart-digest>'
tag=${1:?$usage}
commit=${2:?$usage}
digest=${3:?$usage}
chart_digest=${4:?$usage}
repo=biscuitbin/knarr
chart_repo=biscuitbin/charts/knarr
base=https://ghcr.io
# Bootstrap ticket 40's release, under the old namespace, which this one must
# leave as it was (Decision 0016).
prior_repo=steven-cutting/knarr
prior_chart_repo=steven-cutting/charts/knarr
prior_version=0.2.0
prior_digest=sha256:989cb9e44df4b97960e68371c1ae8bddcd29db99d65bbd09b663776665c01bc9
prior_chart_digest=sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(git -C "$here" rev-parse --show-toplevel)
# shellcheck source=../../../../scripts/release/lib.sh disable=SC1091  # the gate runs without -x
. "$root/scripts/release/lib.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
printf '%s\n' "$tag" | grep -qE '^v0\.[0-9]+\.[0-9]+$' || fail "tag '$tag' is not v0.Y.Z: the tag set below assumes a 0.x release"
printf '%s\n' "$commit" | grep -qE '^[0-9a-f]{40}$' || fail "commit '$commit' is not 40 hex digits"
version=${tag#v}
short=$(printf '%s' "$commit" | cut -c1-7)
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
mkdir "$work/blob"
manifest_head() { # repo, ref, [curl args...]: the headers to $work/headers; sets code and curl_rc
  r=$1; shift
  registry_head "$base" "$r" "$@" > "$work/headers"
}
content_type() { tr -d '\r' < "$work/headers" | grep -i '^content-type:' | sed 's/^[^:]*: *//'; }
# Neither helper runs in a subshell, so a failure in either stops the script,
# and each sets its answer in the caller.
token_for() { # repo: sets token to an anonymous pull token
  tcode=$(curl -sS --max-time 20 -o "$work/token.json" -w '%{http_code}' \
    "$base/token?scope=repository:$1:pull&service=ghcr.io") || fail "the token request for $1 failed"
  if [ "$tcode" != 200 ]; then
    printf 'info token for %s: http %s, %s\n' "$1" "$tcode" "$(cat "$work/token.json")"
    fail "$1 refuses an anonymous token (http $tcode): it is not public; the maintainer makes it public in its package settings, then this script is rerun"
  fi
  printf 'ok   token for %s: http %s\n' "$1" "$tcode"
  token=$(perl -ne 'print $1 if /"token":"([^"]+)"/' "$work/token.json")
  [ -n "$token" ] || fail "the answer for $1 has no token"
  echo "token for $1: granted (not printed)"
}
tags_list() { # repo, auth header: prints the answer; sets listed to its tags, sorted and comma-joined
  tl=$(curl -sS --max-time 20 -H "$2" "$base/v2/$1/tags/list") || fail "tags/list for $1 failed"
  printf '%s\n' "$tl"
  listed=$(printf '%s' "$tl" | perl -ne 'if (/"tags":\[([^\]]*)\]/) { print join(",", sort map { s/"//gr } split /,/, $1) }')
}
v=$(curl --version | head -n 1) || fail 'curl --version failed'
printf 'date: %s\n%s\nimage: %s/%s\nchart: %s/%s\ntag: %s\ncommit: %s\ndigest: %s\nchart digest: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$v" "${base#https://}" "$repo" "${base#https://}" "$chart_repo" \
  "$tag" "$commit" "$digest" "$chart_digest"

echo; echo "== the image: an anonymous pull token, GET $base/token?scope=repository:$repo:pull&service=ghcr.io"
token_for "$repo"
auth="Authorization: Bearer $token"
manifest_head "$repo" "$version"
printf 'info HEAD %s with no token: http %s\n' "$version" "$code"

not_public() { # repo, auth header: a token granted but the version denied is not public either
  manifest_head "$1" "$version" -H "$2"
  case $code in
    401 | 403) fail "$1 grants an anonymous token but answers http $code for $version: it is not public; the maintainer makes it public in its package settings, then this script is rerun" ;;
  esac
}
not_public "$repo" "$auth"

echo; echo '== the manifest by each tag release.yml pushed, and by digest'
for ref in "$version" "${version%.*}" "sha-$short" "$digest"; do
  manifest_head "$repo" "$ref" -H "$auth"
  d=$(digest_of_headers < "$work/headers") || d=''
  expect "HEAD $ref: http, Docker-Content-Digest" "$code $d" "200 $digest"
  printf '     content-type: %s\n' "$(content_type)"
done
manifest_head "$repo" latest -H "$auth"
expect 'HEAD latest: http' "$code" 404

echo; echo "== GET $base/v2/$repo/tags/list"
tags_list "$repo" "$auth"
want=$(printf '%s\n' "$version" "${version%.*}" "sha-$short" | LC_ALL=C sort | paste -s -d , -)
expect tags "$listed" "$want"

echo; echo "== a second push of $tag, reasoned dry: the image's existence guard against the real registry"
probe_tag "$base" "$repo" "$version" -H "$auth"
expect "probe_tag $version" "$verdict ($verdict_rc, http $code)" 'present (1, http 200)'

echo; echo "== the chart: an anonymous pull token, GET $base/token?scope=repository:$chart_repo:pull&service=ghcr.io"
token_for "$chart_repo"
cauth="Authorization: Bearer $token"
manifest_head "$chart_repo" "$version"
printf 'info HEAD %s with no token: http %s\n' "$version" "$code"

not_public "$chart_repo" "$cauth"

echo; echo '== the chart manifest by version, and by digest'
for ref in "$version" "$chart_digest"; do
  manifest_head "$chart_repo" "$ref" -H "$cauth"
  d=$(digest_of_headers < "$work/headers") || d=''
  expect "HEAD $ref: http, Docker-Content-Digest" "$code $d" "200 $chart_digest"
  printf '     content-type: %s\n' "$(content_type)"
done
manifest_head "$chart_repo" latest -H "$cauth"
expect 'HEAD latest: http' "$code" 404

echo; echo "== GET $base/v2/$chart_repo/tags/list"
tags_list "$chart_repo" "$cauth"
expect tags "$listed" "$version"

echo; echo "== GET the chart manifest by digest, and its chart layer"
mcode=$(curl -sS --max-time 20 -o "$work/manifest.json" -w '%{http_code}' -H "$cauth" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$base/v2/$chart_repo/manifests/$chart_digest") ||
  fail 'the manifest request failed'
expect 'GET manifest: http' "$mcode" 200
cat "$work/manifest.json"; echo
v=$(shasum -a 256 "$work/manifest.json" | cut -d ' ' -f 1) || fail 'hashing the manifest failed'
expect "the manifest's sha256" "sha256:$v" "$chart_digest"
# The config's media type, then each layer as mediaType<TAB>digest.
v=$(perl -MJSON::PP -0777 -ne '$m = decode_json($_); print "$m->{config}{mediaType}\n"; print "$_->{mediaType}\t$_->{digest}\n" for @{$m->{layers}}' "$work/manifest.json") ||
  fail 'reading the manifest failed'
expect 'config media type' "$(printf '%s\n' "$v" | sed -n 1p)" application/vnd.cncf.helm.config.v1+json
layers=$(printf '%s\n' "$v" | sed -n '2,$p')
expect 'layer media types' "$(printf '%s\n' "$layers" | cut -f 1 | paste -s -d , -)" application/vnd.cncf.helm.chart.content.v1.tar+gzip
layer=$(printf '%s\n' "$layers" | cut -f 2)
printf '%s\n' "$layer" | grep -qE '^sha256:[0-9a-f]{64}$' || fail "the chart layer's digest '$layer' is not sha256:<64 hex>"
# ghcr.io answers a blob GET with a redirect to its storage; curl drops the
# Authorization header on the redirect to another host.
bcode=$(curl -sS -L --max-time 60 -o "$work/blob/chart.tgz" -w '%{http_code}' -H "$cauth" "$base/v2/$chart_repo/blobs/$layer") ||
  fail 'the blob request failed'
expect 'GET chart layer: http (after redirects)' "$bcode" 200
v=$(shasum -a 256 "$work/blob/chart.tgz" | cut -d ' ' -f 1) || fail 'hashing the chart layer failed'
expect "the chart layer's sha256" "sha256:$v" "$layer"

echo; echo '== the packaged Chart.yaml and values.yaml, read from the layer'
chart_yaml=$(tar -xzOf "$work/blob/chart.tgz" knarr/Chart.yaml) || fail 'reading knarr/Chart.yaml from the layer failed'
printf '%s\n' "$chart_yaml"
values=$(tar -xzOf "$work/blob/chart.tgz" knarr/values.yaml) || fail 'reading knarr/values.yaml from the layer failed'
echo '-- values.yaml, the image block'
printf '%s\n' "$values" | sed -n '/^image:/,/^[^ ]/p' | sed '$d'
has() { # label text exact-line
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then printf 'ok   %s: %s\n' "$1" "$3"; else fail "$1: no line '$3'"; fi
}
has 'Chart.yaml' "$chart_yaml" "version: $version"
has 'Chart.yaml' "$chart_yaml" "appVersion: $version"
has 'Chart.yaml' "$chart_yaml" "      image: ${base#https://}/$repo@$digest"
has 'values.yaml' "$values" "  repository: ${base#https://}/$repo"
has 'values.yaml' "$values" "  tag: \"$version\""
has 'values.yaml' "$values" "  digest: $digest"
has 'values.yaml' "$values" '  pullPolicy: IfNotPresent'

echo; echo "== a second push of the chart, reasoned dry: the chart's existence guard against the real registry"
probe_tag "$base" "$chart_repo" "$version" -H "$cauth"
expect "probe_tag $version" "$verdict ($verdict_rc, http $code)" 'present (1, http 200)'
echo; echo "== the packages under steven-cutting: $prior_version as bootstrap ticket 40 published it"
token_for "$prior_repo"
manifest_head "$prior_repo" "$prior_version" -H "Authorization: Bearer $token"
d=$(digest_of_headers < "$work/headers") || d=''
expect "HEAD $prior_repo:$prior_version: http, Docker-Content-Digest" "$code $d" "200 $prior_digest"
token_for "$prior_chart_repo"
manifest_head "$prior_chart_repo" "$prior_version" -H "Authorization: Bearer $token"
d=$(digest_of_headers < "$work/headers") || d=''
expect "HEAD $prior_chart_repo:$prior_version: http, Docker-Content-Digest" "$code $d" "200 $prior_chart_digest"
echo; echo "public: every image tag pulls anonymously at the run digest, and chart $version at the chart digest names it"
