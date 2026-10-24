#!/bin/sh
# Org transfer ticket 05 evidence, adapted from helm chart ticket 05's
# 15-published-install-upgrade.sh: on a fresh kind cluster, a v0.2.0 install
# from the old chart reference, oci://ghcr.io/steven-cutting/charts/knarr,
# upgraded in place to the first release under the org with
# `helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr --version 0.3.0`,
# keeping the release name. The controller rolls onto
# ghcr.io/biscuitbin/knarr@<digest>, keeps patching opted-in workers, and
# `just smoke` passes before and after.
# Changed from 15: the upgrade crosses chart references and versions instead
# of changing one value; fake workers are deployed and opted in before the
# upgrade, as 15's sibling 16 does, so the new controller is seen patching
# them; one worker's cost changes after the upgrade, and its
# pod-deletion-cost must follow; set -eu stops the script at the first
# failure. It reuses helm chart ticket 05's state.sh, metrics.sh and
# control.sh, and installs its jmsingle post-renderer into ai_tmp/.
# Needs the fake worker image built (`just fake-worker-image-build`, its own
# authorized network step) and the network for both charts and both images.
# Run with sh -x from the worktree root; it sets the worktree pixi PATH and
# KUBECONFIG itself.
# Usage: sh -x upgrade.sh <sha256:image-digest> > upgrade.txt 2>&1
set -eu
digest=${1:?usage: upgrade.sh <sha256:image-digest>}
H=.scratch/helm-chart/evidence/05
W=ai_tmp/org-05-upgrade
# Every kubectl and helm call goes to this worktree's kind cluster, never the
# caller's default context.
PATH="$PWD/.pixi/envs/default/bin:$PWD/.pixi/envs/cluster/bin:$PATH" KUBECONFIG=$PWD/.cluster/kubeconfig
export PATH KUBECONFIG
date -u +%Y-%m-%dT%H:%M:%SZ
echo 'Host deviation, as in helm chart ticket 05: this host is arm64 (OrbStack) and the release image'
echo 'amd64 only. Under Rosetta the BEAM needs the JIT single mapping, so every helm install and'
echo 'upgrade passes --post-renderer jmsingle, which adds only the env entry ERL_AFLAGS="+JMsingle true"'
echo 'before ERL_FLAGS. Helm still owns every field, and the pod still runs the published image digest.'
mkdir -p "$W" ai_tmp/helm-plugins
rm -rf ai_tmp/helm-plugins/jmsingle
cp -R "$H/jmsingle" ai_tmp/helm-plugins/
export HELM_PLUGINS="$PWD/ai_tmp/helm-plugins"
cat ai_tmp/helm-plugins/jmsingle/render.sh
worker_namespace=default
old_digest=sha256:989cb9e44df4b97960e68371c1ae8bddcd29db99d65bbd09b663776665c01bc9
old_chart_digest=sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016
# wait_for N CMD: rerun CMD every 5 s, without tracing each try, until it
# succeeds; after N retries, exit so nothing after the wait runs unconfirmed.
wait_for() { { set +x; } 2>/dev/null; n=$1; shift; i=0; until "$@"; do if [ "$i" -ge "$n" ]; then echo "timed out after $((i*5)) s waiting for: $*"; exit 1; fi; sleep 5; i=$((i+1)); done; echo "waited $((i*5)) s"; set -x; }
markers() { kubectl get pods -l app.kubernetes.io/name=fake-worker -o jsonpath='{range .items[*]}{.metadata.annotations.knarr\.io/applied}{"\n"}{end}' | grep -c . || true; }
owned_three() { [ "$(markers)" -ge 3 ] && sh "$H"/metrics.sh | grep -q 'standing="owned"} 3'; }
cost_of() { kubectl get pod "$1" -o jsonpath='{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}'; }
cost_moved() { now=$(cost_of "$1"); [ -n "$now" ] && [ "$now" != "$2" ]; }
knarr_pods() {
  kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
}

# A fresh cluster.
just cluster-down
just cluster-up
kubectl config current-context

# v0.2.0 from the old reference, by the chart digest its run summary printed
# (https://github.com/steven-cutting/knarr/actions/runs/39551271680).
helm install knarr "oci://ghcr.io/steven-cutting/charts/knarr@$old_chart_digest" \
  --namespace "$worker_namespace" --wait --post-renderer jmsingle
kubectl -n "$worker_namespace" rollout status deployment/knarr
image=$(kubectl -n "$worker_namespace" get deployment knarr -o jsonpath='{.spec.template.spec.containers[0].image}')
test "$image" = "ghcr.io/steven-cutting/knarr@$old_digest"
knarr_pods
just smoke

# Four fake workers; three report busy, and the Deployment opts in.
just fake-worker-deploy
# shellcheck disable=SC2046 # the pod names split on purpose
set -- $(kubectl get pods -l app.kubernetes.io/name=fake-worker -o jsonpath='{.items[*].metadata.name}')
for pod in "$2" "$3" "$4"; do sh "$H"/control.sh "$pod" 1800; done
kubectl label deployment fake-worker knarr.io/enabled=true
wait_for 60 owned_three
sh "$H"/state.sh
sh "$H"/metrics.sh

# The upgrade, as the install guide gives it: the same release name and
# namespace, the new reference and version.
before=$(kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr -o jsonpath='{.items[0].metadata.name}')
helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr \
  --version 0.3.0 --namespace "$worker_namespace" --wait --post-renderer jmsingle
kubectl -n "$worker_namespace" rollout status deployment/knarr
# The 0.2.0 pod is gone before anything reads a knarr pod, so every read
# below, metrics.sh's included, is the 0.3.0 controller's.
kubectl -n "$worker_namespace" wait --for=delete "pod/$before" --timeout=120s
after=$(kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr -o jsonpath='{.items[*].metadata.name}')
test -n "$after" && test "$before" != "$after"
echo "pod rolled: $before -> $after"
helm history knarr --namespace "$worker_namespace"
helm list --namespace "$worker_namespace" -o json
test "$(helm list --namespace "$worker_namespace" -q)" = knarr
test "$(helm history knarr --namespace "$worker_namespace" -o json | python3 -c 'import json, sys; print(",".join(r["chart"] + ":" + r["status"] for r in json.load(sys.stdin)))')" = 'knarr-0.2.0:superseded,knarr-0.3.0:deployed'
image=$(kubectl -n "$worker_namespace" get deployment knarr -o jsonpath='{.spec.template.spec.containers[0].image}')
test "$image" = "ghcr.io/biscuitbin/knarr@$digest"
knarr_pods
knarr_pods | grep -qF "@$digest"

# The new controller keeps patching: its own metrics count the three owned
# annotations, and a worker whose cost rises to a higher tier gets a new,
# non-empty pod-deletion-cost that only knarr writes.
wait_for 60 owned_three
was=$(cost_of "$2")
test -n "$was"
sh "$H"/control.sh "$2" 3600
wait_for 60 cost_moved "$2" "$was"
test -n "$(cost_of "$2")"
echo "$2 pod-deletion-cost: $was -> $(cost_of "$2")"
sh "$H"/state.sh
sh "$H"/metrics.sh
just smoke
echo "upgraded in place from v0.2.0 to 0.3.0 at ghcr.io/biscuitbin/knarr@$digest, still patching"
