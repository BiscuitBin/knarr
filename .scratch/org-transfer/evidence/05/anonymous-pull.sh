#!/bin/sh
# Org transfer ticket 05 evidence, adapted from helm chart ticket 05's
# 19-published-anonymous-pull.sh: an anonymous helm pull of the first chart
# published under the org, by its digest, with empty Helm and Docker
# configuration and HOME, so no stored credential can be used.
# Changed from 19: the chart is oci://ghcr.io/biscuitbin/charts/knarr, pulled
# by the digest the run summary printed rather than by version; the version,
# the chart digest and the stamped image digest are arguments; set -eu stops
# the script at the first failure, and the stamped values are checked rather
# than only printed. The anonymous pull of the image by digest is pull.sh's.
# Helm 4 names a chart pulled by digest knarr@sha256-<hex>.tgz, so the one
# file the pull wrote is read rather than knarr-<version>.tgz.
# Run with sh -x, the worktree pixi PATH, from the worktree root.
# Usage: sh -x anonymous-pull.sh <version> <sha256:chart-digest> <sha256:image-digest> > anonymous-pull.txt 2>&1
set -eu
usage='usage: anonymous-pull.sh <version> <sha256:chart-digest> <sha256:image-digest>'
version=${1:?$usage}
chart_digest=${2:?$usage}
digest=${3:?$usage}
date -u +%Y-%m-%dT%H:%M:%SZ
anon=$(mktemp -d)
trap 'rm -rf "${anon:?}"' EXIT
mkdir -p "$anon/home" "$anon/docker" "$anon/helm" "$anon/out"
export HOME="$anon/home" DOCKER_CONFIG="$anon/docker"
export HELM_CONFIG_HOME="$anon/helm" HELM_CACHE_HOME="$anon/helm/cache" HELM_DATA_HOME="$anon/helm/data"
export HELM_REGISTRY_CONFIG="$anon/helm/registry.json"
helm version --short
# No file before the pull: no stored credential.
test -z "$(find "$anon" -type f)"
helm pull "oci://ghcr.io/biscuitbin/charts/knarr@$chart_digest" --destination "$anon/out"
ls "$anon/out"
test "$(find "$anon/out" -type f | wc -l)" -eq 1
tgz=$(find "$anon/out" -type f -name '*.tgz')
test -n "$tgz"
tar -tzf "$tgz"
tar -xzOf "$tgz" knarr/Chart.yaml | grep -E '^(version|appVersion|home):'
tar -xzOf "$tgz" knarr/values.yaml | grep -E 'repository:|tag:|digest:|pullPolicy:'
tar -xzOf "$tgz" knarr/templates/NOTES.txt
tar -xzOf "$tgz" knarr/Chart.yaml | grep -qxF "version: $version"
tar -xzOf "$tgz" knarr/Chart.yaml | grep -qxF "appVersion: $version"
tar -xzOf "$tgz" knarr/values.yaml | grep -qxF '  repository: ghcr.io/biscuitbin/knarr'
tar -xzOf "$tgz" knarr/values.yaml | grep -qxF "  digest: $digest"
echo "anonymous pull by digest: chart $version names ghcr.io/biscuitbin/knarr@$digest"
