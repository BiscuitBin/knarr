#!/bin/sh
# Helm chart ticket 05 evidence: an anonymous pull of the published chart.
# Run with sh -x, the worktree pixi PATH and KUBECONFIG, from the worktree
# root; the transcript beside it has its name.
# An anonymous helm pull of the published chart by version, with empty Helm
# and Docker configuration and HOME, so no stored credential can be used.
anon=$(mktemp -d)
mkdir -p "$anon/home" "$anon/docker" "$anon/helm" "$anon/out"
export HOME="$anon/home" DOCKER_CONFIG="$anon/docker"
export HELM_CONFIG_HOME="$anon/helm" HELM_CACHE_HOME="$anon/helm/cache" HELM_DATA_HOME="$anon/helm/data"
export HELM_REGISTRY_CONFIG="$anon/helm/registry.json"
helm version --short
find "$anon" -type f
helm pull oci://ghcr.io/steven-cutting/charts/knarr --version 0.2.0 --destination "$anon/out"
ls "$anon/out"
tar -tzf "$anon/out/knarr-0.2.0.tgz"
tar -xzOf "$anon/out/knarr-0.2.0.tgz" knarr/Chart.yaml | grep -E '^(version|appVersion):'
tar -xzOf "$anon/out/knarr-0.2.0.tgz" knarr/values.yaml | grep -E 'repository:|tag:|digest:|pullPolicy:'
tar -xzOf "$anon/out/knarr-0.2.0.tgz" knarr/templates/NOTES.txt
tar -xzOf "$anon/out/knarr-0.2.0.tgz" knarr/values.yaml | grep -qF 'sha256:989cb9e44df4b97960e68371c1ae8bddcd29db99d65bbd09b663776665c01bc9'
echo "stamped image digest present: $?"
rm -rf "${anon:?}"
