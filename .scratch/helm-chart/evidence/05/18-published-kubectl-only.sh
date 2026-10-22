#!/bin/sh
# Helm chart ticket 05 evidence: the kubectl-only route with the published
# chart. Run with sh -x, the worktree pixi PATH and KUBECONFIG, from the
# worktree root; the transcript beside it has its name.
E=.scratch/helm-chart/evidence/05
W=ai_tmp/05-published
echo 'Host deviation: this host is arm64 (OrbStack) and the release image amd64 only. Under Rosetta'
echo 'the BEAM needs the JIT single mapping, so the helm template render passes --post-renderer'
echo 'jmsingle, which adds only the env entry ERL_AFLAGS="+JMsingle true" before ERL_FLAGS. The'
echo 'saved file is the post-rendered manifest, and the pod still runs the published image digest.'
export HELM_PLUGINS="$PWD/ai_tmp/helm-plugins"
wait_for() { { set +x; } 2>/dev/null; n=$1; shift; i=0; until "$@"; do if [ "$i" -ge "$n" ]; then echo "timed out after $((i*5)) s waiting for: $*"; exit 1; fi; sleep 5; i=$((i+1)); done; echo "waited $((i*5)) s"; set -x; }
markers() { kubectl get pods -l app.kubernetes.io/name=fake-worker -o jsonpath='{range .items[*]}{.metadata.annotations.knarr\.io/applied}{"\n"}{end}' | grep -c .; }
owned_three() { [ "$(markers)" -ge 3 ] && sh "$E"/metrics.sh | grep -q 'standing="owned"} 3'; }
cleaned() { sh "$E"/metrics.sh | awk -v t="$optout" '
  /^knarr_last_discovery_timestamp_seconds/ { fresh = ($2 > t) }
  /^knarr_targets\{kind="deployments"\}/ { targets = $2 }
  /^knarr_annotations\{.*standing="owned"/ { if ($2 > 0) owned = 1 }
  END { exit !(fresh && targets == 0 && !owned) }'; }
cat ai_tmp/helm-plugins/jmsingle/render.sh
mkdir -p "$W"
# A fresh cluster.
just cluster-down
just cluster-up
# The kubectl-only route: render the published chart by digest once, keep the
# file, apply it.
worker_namespace=default
chart_digest=sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016
kubectl config current-context
rm -f "${W:?}/knarr-rendered.yaml"
helm template knarr "oci://ghcr.io/steven-cutting/charts/knarr@$chart_digest" \
  --namespace "$worker_namespace" --post-renderer jmsingle > "$W/knarr-rendered.yaml"
head -3 "$W/knarr-rendered.yaml"
grep -E '^kind:|image:|ERL_|value:' "$W/knarr-rendered.yaml"
kubectl -n "$worker_namespace" apply -f "$W/knarr-rendered.yaml"
kubectl -n "$worker_namespace" rollout status deployment/knarr
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
helm list --namespace "$worker_namespace"
sh "$E"/state.sh
just smoke
just fake-worker-deploy
# shellcheck disable=SC2046 # the pod names split on purpose
set -- $(kubectl get pods -l app.kubernetes.io/name=fake-worker -o jsonpath='{.items[*].metadata.name}')
foreign=$1
kubectl annotate pod "$foreign" controller.kubernetes.io/pod-deletion-cost=-7
for pod in $2 $3 $4; do sh "$E"/control.sh "$pod" 1800; done
kubectl label deployment fake-worker knarr.io/enabled=true
wait_for 60 owned_three
sh "$E"/state.sh
sh "$E"/metrics.sh
# The operations page's order. 1: opt out.
kubectl -n "$worker_namespace" label deployment -l knarr.io/enabled=true knarr.io/enabled-
optout=$(date +%s)
# 2: the discovery and metric waits.
wait_for 60 cleaned
sh "$E"/metrics.sh
# 3: markers.
kubectl -n "$worker_namespace" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.knarr\.io/applied}{"\n"}{end}'
marked=$(kubectl -n "$worker_namespace" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.knarr\.io/applied}{"\n"}{end}' | awk -F '\t' '$2 != "" { print $1 }')
if [ -n "$marked" ]; then
  for pod in $marked; do kubectl -n "$worker_namespace" get pod "$pod" -o yaml; done
  echo "markers remain on: $marked; manual recovery needed before the delete step"
  exit 1
fi
echo "no marker remains: nothing to recover"
kubectl -n "$worker_namespace" get pod "$foreign" -o jsonpath='{.metadata.annotations}{"\n"}'
# 4: no Helm release to uninstall; delete the saved render.
kubectl -n "$worker_namespace" delete -f "$W/knarr-rendered.yaml"
kubectl -n "$worker_namespace" wait --for=delete pod -l app.kubernetes.io/name=knarr --timeout=120s
sh "$E"/state.sh
kubectl -n "$worker_namespace" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations}{"\n"}{end}'
kubectl -n "$worker_namespace" get deployment,serviceaccount,role,rolebinding -l app.kubernetes.io/name=knarr
absent=$(kubectl -n "$worker_namespace" get serviceaccount/knarr role/knarr rolebinding/knarr deployment/knarr 2>&1 | grep -c "(NotFound)")
echo "knarr resources NotFound: $absent of 4"
test "$absent" -eq 4
