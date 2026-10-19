#!/bin/sh
# Helm chart ticket 05 evidence helper, run between the steps of the local
# rehearsal (the transcripts beside it; the worktree path is written as
# <worktree>). Print the releases, knarr's resources with their Helm ownership
# metadata and field managers, knarr's pods, and every worker pod's deletion
# cost and knarr.io/applied marker.
cd "$(dirname "$0")/../../../.." || exit 1
PATH="$PWD/.pixi/envs/default/bin:$PWD/.pixi/envs/cluster/bin:$PATH" KUBECONFIG=$PWD/.cluster/kubeconfig
export PATH KUBECONFIG
echo "== helm releases"
helm list --namespace default
echo "== knarr resources"
for resource in serviceaccount/knarr role/knarr rolebinding/knarr deployment/knarr; do
  json=$(kubectl get "$resource" -o json --show-managed-fields 2>/dev/null) && printf "%s" "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
m = o["metadata"]
print(o["kind"], m["name"],
      "managed-by=" + str(m.get("labels", {}).get("app.kubernetes.io/managed-by")),
      "release=" + str(m.get("annotations", {}).get("meta.helm.sh/release-name")),
      "managers=" + ",".join(f["manager"] + "/" + f["operation"] for f in m.get("managedFields", [])))' \
    || echo "$resource absent"
done
kubectl get deploy knarr -o jsonpath='deployment image: {.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null
echo "== knarr pods"
kubectl get pods -l app.kubernetes.io/name=knarr -o jsonpath='{range .items[*]}{.metadata.name} uid {.metadata.uid} phase {.status.phase} ready {.status.containerStatuses[0].ready} image {.spec.containers[0].image}{"\n"}{end}'
echo "== worker annotations (pod, pod-deletion-cost, knarr.io/applied)"
kubectl get pods -l app.kubernetes.io/name=fake-worker -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}{"\t"}{.metadata.annotations.knarr\.io/applied}{"\n"}{end}'
