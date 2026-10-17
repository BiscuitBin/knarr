#!/bin/sh
# Helm chart ticket 03 evidence helper, run after each step of the local proof
# (the transcripts beside it; the worktree path is written as <worktree>).
# Print the release, the Deployment's env/volumes/managers and each pod's.
cd "$(dirname "$0")/../../../.." || exit 1
PATH="$PWD/.pixi/envs/default/bin:$PWD/.pixi/envs/cluster/bin:$PATH" KUBECONFIG=$PWD/.cluster/kubeconfig
export PATH KUBECONFIG
helm list --namespace default
kubectl get deploy knarr -o jsonpath='deployment env: {.spec.template.spec.containers[0].env[*].name}{"\n"}deployment volumes: {.spec.template.spec.volumes[*].name}{"\n"}deployment annotations: {.metadata.annotations}{"\n"}pod-template local-image-id: {.spec.template.metadata.annotations.knarr\.dev/local-image-id}{"\n"}'
kubectl get deploy knarr -o json --show-managed-fields | python3 -c 'import json,sys; print("managers:", ", ".join(m["manager"]+"/"+m["operation"] for m in json.load(sys.stdin)["metadata"]["managedFields"]))'
kubectl get pods -l app.kubernetes.io/name=knarr -o jsonpath='{range .items[*]}pod {.metadata.name} uid {.metadata.uid} phase {.status.phase} ready {.status.conditions[?(@.type=="Ready")].status} env {.spec.containers[0].env[*].name} volumes {.spec.volumes[*].name}{"\n"}{end}'
