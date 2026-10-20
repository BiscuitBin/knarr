#!/bin/sh
# Print knarr's uninstall-wait series from its pod's /metrics through the API
# server's pod proxy: discovery time, Deployment targets and owned annotations.
cd "$(dirname "$0")/../../../.." || exit 1
PATH="$PWD/.pixi/envs/default/bin:$PWD/.pixi/envs/cluster/bin:$PATH" KUBECONFIG=$PWD/.cluster/kubeconfig
export PATH KUBECONFIG
pod=$(kubectl get pods -l app.kubernetes.io/name=knarr -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw "/api/v1/namespaces/default/pods/$pod:8080/proxy/metrics" \
  | grep -E '^(knarr_last_discovery_timestamp_seconds|knarr_targets|knarr_annotations)\b' || true
