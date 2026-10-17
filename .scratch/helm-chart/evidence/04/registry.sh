#!/bin/sh
# Helm chart ticket 04 evidence: the chart's half of the release rehearsed end
# to end against a throwaway registry:2 on loopback, with the scripts the
# release workflow runs. In order:
#   1. a stand-in image pushed with buildx, and its digest read from the
#      --metadata-file as release.yml reads it
#   2. stamp-chart.sh stamps that digest into a copy of the chart and packages
#      it; the same script refuses a version that disagrees with Chart.yaml
#   3. the chart's existence guard (probe_tag from scripts/release/lib.sh):
#      absent before the push
#   4. helm push, and the chart digest read from its output as release.yml
#      reads it (digest_of_inspect)
#   5. the guard again: present, and the registry's Docker-Content-Digest is
#      the digest helm push printed
#   6. helm pull by that digest into an empty directory, then helm template of
#      the pulled package: the rendered image is the stamped digest reference
#      with IfNotPresent
# The stamped repository is ghcr.io/steven-cutting/knarr, as in the workflow;
# only the chart goes to the loopback registry, and nothing installs it, so the
# image is never pulled from ghcr.io. The image is a stand-in (FROM scratch, one
# file), as in bootstrap ticket 28's registry.sh: none of the mechanics here
# depends on what is in it. Nothing here touches ghcr.io.
# Needs docker (buildx), helm, curl, perl and the registry:2 image (pulled on
# first use). Run it through the default environment for helm:
# Usage: sh scripts/with-env.sh sh .scratch/helm-chart/evidence/04/registry.sh <empty-work-dir>
# The gate runs shellcheck without -x, so it cannot see that probe_tag in lib.sh
# sets verdict, verdict_rc, code and curl_rc.
# shellcheck disable=SC2154
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
# work_dir, fail and head_digest come from 28's evidence library; the guards
# are the release's own, sourced after it so they are the ones that run.
# shellcheck source=../../../bootstrap/evidence/28/lib.sh disable=SC1091  # the gate runs without -x
. "$root/.scratch/bootstrap/evidence/28/lib.sh"
# shellcheck source=../../../../scripts/release/lib.sh disable=SC1091
. "$root/scripts/release/lib.sh"
work=${1:?usage: registry.sh <empty-work-dir>}
work=$(work_dir "$work")
# One registry per worktree, named like the worktree's clusters.
name=knarr-h04-reg-$(sh "$root/scripts/cluster-name.sh" "$root" name)
image=ghcr.io/steven-cutting/knarr
say() { printf '%s\n' "$*"; }
# Helm's registry config and cache stay in the work directory.
export HELM_CONFIG_HOME="$work/helm/config" HELM_CACHE_HOME="$work/helm/cache" HELM_DATA_HOME="$work/helm/data"
port=0
cleanup() {
  docker rm -f "$name" > /dev/null 2>&1 || true
  # shellcheck disable=SC2046  # image ids, one per word
  docker image rm -f $(docker image ls -q "localhost:$port/knarr" 2> /dev/null) > /dev/null 2>&1 || true
}
trap cleanup EXIT

printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
say "$(helm version --template 'helm {{.Version}}'), docker $(docker version --format '{{.Server.Version}}'), $(docker buildx version | cut -d' ' -f1-2)"
version=$(toml_version < "$root/gleam.toml")
say "gleam.toml version: $version; charts/knarr/Chart.yaml: $(grep -E '^(version|appVersion):' "$root/charts/knarr/Chart.yaml" | paste -sd ' ' -)"

docker run -d --name "$name" -p 127.0.0.1::5000 registry:2 > /dev/null
port=$(docker port "$name" 5000/tcp | head -1 | sed 's/.*://')
reg=http://127.0.0.1:$port
i=0; until [ "$(curl -s -o /dev/null -w '%{http_code}' "$reg/v2/")" = 200 ]; do
  i=$((i + 1)); [ "$i" -lt 40 ] || fail 'registry:2 never answered /v2/'; sleep 0.5
done
say "registry:2 $(docker image inspect registry:2 --format '{{index .RepoDigests 0}}' | sed 's/^registry@//') on $reg (loopback only)"

say '-- 1. a stand-in image, pushed as release.yml pushes it'
ctx=$work/stand-in
mkdir -p "$ctx"
printf 'FROM scratch\nCOPY stand-in.txt /knarr-stand-in\n' > "$ctx/Dockerfile"
echo 'knarr helm chart ticket 04 dry run' > "$ctx/stand-in.txt"
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  --label "org.opencontainers.image.version=$version" \
  --metadata-file "$work/metadata.json" --tag "localhost:$port/knarr:$version" --push "$ctx" > "$work/build.log" 2>&1 ||
  { tail -20 "$work/build.log"; fail 'buildx build --push failed'; }
digest=$(digest_of_metadata < "$work/metadata.json") || fail 'no digest in metadata.json'
say "image digest (--metadata-file): $digest"
[ "$(head_digest "$reg" knarr "$version")" = "$digest" ] || fail 'the registry disagrees with --metadata-file'
say 'the registry serves knarr:'"$version"' at that digest'

say '-- 2. stamp and package'
rc=0; sh "$root/scripts/release/stamp-chart.sh" "$root/charts/knarr" 9.9.9 "$image" "$digest" "$work/refused" 2> "$work/refused.err" || rc=$?
say "a tag of v9.9.9 against this chart: exit $rc: $(cat "$work/refused.err")"
[ "$rc" -ne 0 ] || fail 'a version that disagrees with Chart.yaml must be refused'
package=$(sh "$root/scripts/release/stamp-chart.sh" "$root/charts/knarr" "$version" "$image" "$digest" "$work/chart")
say "packaged $(basename "$package"), sha256 $(sha256_of < "$package")"
say "stamped values: $(helm show values "$package" | sed -n '/^image:/,/^$/p' | grep -E '^  (repository|tag|digest|pullPolicy):' | sed 's/^  //' | paste -sd ' ' -)"
say "annotation: $(helm show chart "$package" | grep -E '^      image:' | sed 's/^ *//')"

say '-- 3. the chart guard before the push'
probe_tag "$reg" charts/knarr "$version"
say "HEAD charts/knarr:$version: $verdict (exit $verdict_rc, http $code): the workflow would push"
[ "$verdict" = absent ] || fail "expected absent, got $verdict"

say '-- 4. helm push'
out=$(helm push --plain-http "$package" "oci://127.0.0.1:$port/charts" 2>&1) || { say "$out"; fail 'helm push failed'; }
say "$out" | sed 's/^/  /'
chart_digest=$(printf '%s\n' "$out" | digest_of_inspect) || fail 'no Digest: line in the helm push output'
say "chart digest (digest_of_inspect on that output): $chart_digest"

say '-- 5. the chart guard after the push'
probe_tag "$reg" charts/knarr "$version"
say "HEAD charts/knarr:$version: $verdict (exit $verdict_rc, http $code): a rerun would refuse"
[ "$verdict" = present ] || fail "expected present, got $verdict"
served=$(head_digest "$reg" charts/knarr "$version") || fail 'no Docker-Content-Digest for the chart'
say "Docker-Content-Digest: $served"
[ "$served" = "$chart_digest" ] || fail 'the registry digest is not the one helm push printed'
say "config and layer media types: $(curl -s -H "$manifest_accept" "$reg/v2/charts/knarr/manifests/$version" | perl -ne 'print join(" ", /"mediaType":\s*"([^"]+)"/g)')"

say '-- 6. pull by digest and template'
mkdir "$work/pulled"
helm pull --plain-http "oci://127.0.0.1:$port/charts/knarr@$chart_digest" --destination "$work/pulled" > "$work/pull.log" 2>&1 ||
  { cat "$work/pull.log"; fail 'helm pull by digest failed'; }
pulled=$(ls "$work/pulled")
say "pulled $pulled by digest, sha256 $(sha256_of < "$work/pulled/$pulled")"
helm template knarr "$work/pulled/$pulled" --namespace workers > "$work/render.yaml"
grep -E '^ +(image|imagePullPolicy):' "$work/render.yaml" | sed 's/^ */  /'
grep -qxF "          image: $image@$digest" "$work/render.yaml" || fail 'the rendered image is not the stamped digest reference'
grep -qxF '          imagePullPolicy: IfNotPresent' "$work/render.yaml" || fail 'the rendered pull policy is not IfNotPresent'
say "the rendered image is $image@$digest, the stand-in's digest, with IfNotPresent"
say "chart=oci://127.0.0.1:$port/charts/knarr@$chart_digest"
