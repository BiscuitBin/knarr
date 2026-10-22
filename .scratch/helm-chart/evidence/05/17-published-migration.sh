#!/bin/sh
# Helm chart ticket 05 evidence: the migration from the v0.1.0 overlay to
# the published chart. Run with sh -x, the worktree pixi PATH and
# KUBECONFIG, from the worktree root; the transcript beside it has its name.
# shellcheck disable=SC2164 # a failed cd shows in the transcript, as it ran
E=$PWD/.scratch/helm-chart/evidence/05
W=$PWD/ai_tmp/05-published
wt=$PWD
echo 'Host deviation: this host is arm64 (OrbStack) and both release images amd64 only. Under Rosetta'
echo 'the BEAM needs the JIT single mapping. The v0.1.0 operator checkout copy carries one extra'
echo 'kustomize patch, jmsingle.yaml, adding only the env entry ERL_AFLAGS="+JMsingle true" before'
echo 'ERL_FLAGS; every helm install, upgrade and template passes --post-renderer jmsingle, which adds'
echo 'the same entry. Helm still owns every field, and each pod runs its release image digest.'
export HELM_PLUGINS="$wt/ai_tmp/helm-plugins"
wait_for() { { set +x; } 2>/dev/null; n=$1; shift; i=0; until "$@" || [ $i -ge "$n" ]; do sleep 5; i=$((i+1)); done; echo "waited $((i*5)) s"; set -x; }
markers() { kubectl get pods -l app.kubernetes.io/name=fake-worker -o jsonpath='{range .items[*]}{.metadata.annotations.knarr\.io/applied}{"\n"}{end}' | grep -c .; }
owned_three() { [ "$(markers)" -ge 3 ] && sh "$E"/metrics.sh | grep -q 'standing="owned"} 3'; }
cleaned() { sh "$E"/metrics.sh | awk -v t="$optout" '
  /^knarr_last_discovery_timestamp_seconds/ { fresh = ($2 > t) }
  /^knarr_targets\{kind="deployments"\}/ { targets = $2 }
  /^knarr_annotations\{.*standing="owned"/ { if ($2 > 0) owned = 1 }
  END { exit !(fresh && targets == 0 && !owned) }'; }
images() {
  kubectl -n "$worker_namespace" get deployment knarr \
    -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
}
cat ai_tmp/helm-plugins/jmsingle/render.sh
mkdir -p "$W"
# A fresh cluster.
just cluster-down
just cluster-up
# The operator checkout of the previous tag, pinned to that release's own
# digest from its run summary, as just release-pin does at v0.1.0.
op=$W/v010-op
rm -rf "${op:?}"
mkdir -p "$op"
git archive v0.1.0 deploy scripts/release | tar -x -C "$op"
release_digest='sha256:97262e02b6326b73ac414fa1bb01b6f557b1c352b7d647a30d7835e4a59e22c7'
grep -n 'digest:' "$op/deploy/release/kustomization.yaml"
sh "$op/scripts/release/pin-digest.sh" "$release_digest"
grep -n 'digest:' "$op/deploy/release/kustomization.yaml"
# The host patch, beside the pin.
cat > "$op/deploy/release/jmsingle.yaml" <<'EOF'
# Host workaround only (arm64 host, amd64 image under Rosetta).
- op: add
  path: /spec/template/spec/containers/0/env/1
  value:
    name: ERL_AFLAGS
    value: "+JMsingle true"
EOF
printf '  - path: jmsingle.yaml\n    target:\n      kind: Deployment\n      name: knarr\n' >> "$op/deploy/release/kustomization.yaml"
cat "$op/deploy/release/kustomization.yaml" "$op/deploy/release/jmsingle.yaml"
# Install v0.1.0 by the guide's kustomize route, from the operator checkout.
cd "$op"
worker_namespace=default
kubectl config current-context
kubectl kustomize deploy/release
kubectl -n "$worker_namespace" apply -k deploy/release
kubectl -n "$worker_namespace" rollout status deployment/knarr
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
images
cd "$wt"
sh "$E"/state.sh
# Opted-in workers before the migration, one with a foreign value written
# before opt-in. The v0.1.0 skeleton runs no discovery and writes nothing.
just fake-worker-deploy
# shellcheck disable=SC2046 # the pod names split on purpose
set -- $(kubectl get pods -l app.kubernetes.io/name=fake-worker -o jsonpath='{.items[*].metadata.name}')
foreign=$1
kubectl annotate pod "$foreign" controller.kubernetes.io/pod-deletion-cost=-7
for pod in $2 $3 $4; do sh "$E"/control.sh "$pod" 1800; done
kubectl label deployment fake-worker knarr.io/enabled=true
sh "$E"/state.sh
# The pod watch across the whole migration.
kubectl get pods -l app.kubernetes.io/name=knarr --watch --output-watch-events \
  -o custom-columns='EVENT:.type,NAME:.object.metadata.name,PHASE:.object.status.phase,READY:.object.status.containerStatuses[0].ready,DELETING:.object.metadata.deletionTimestamp' \
  > "$W/17-watch.txt" 2>&1 &
watch=$!
sleep 2
# The guide's migration, from the operator checkout. Drift check first: it
# must print nothing.
cd "$op"
kubectl config current-context
kubectl -n "$worker_namespace" diff -k deploy/release
drift=$?
echo "kubectl diff exit=$drift"
if [ "$drift" -ne 0 ]; then kill $watch; echo "drift found: stop"; exit 1; fi
kubectl -n "$worker_namespace" apply --server-side --field-manager=helm --force-conflicts -k deploy/release
sh "$E"/state.sh
: > knarr-values.yaml
wc -c knarr-values.yaml
chart_version=0.2.0
chart_digest=sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016
for resource in serviceaccount/knarr role/knarr rolebinding/knarr deployment/knarr; do
  kubectl -n "$worker_namespace" label "$resource" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl -n "$worker_namespace" annotate "$resource" --overwrite \
    meta.helm.sh/release-name=knarr meta.helm.sh/release-namespace="$worker_namespace"
done
helm upgrade --install knarr "oci://ghcr.io/steven-cutting/charts/knarr@$chart_digest" \
  --namespace "$worker_namespace" \
  --values knarr-values.yaml --wait --post-renderer jmsingle
adopt=$?
echo "helm upgrade --install exit=$adopt"
kubectl -n "$worker_namespace" rollout status deployment/knarr
sleep 5
kill $watch
cat "$W/17-watch.txt"
# At most one knarr pod Running at any event: a pod counts from its first
# Running line until its DELETED event.
awk 'NR > 1 { if ($3 == "Running") run[$2] = 1; if ($1 == "DELETED") delete run[$2];
  n = 0; for (p in run) n++; if (n > max) max = n }
  END { print "most knarr pods Running at once:", max; exit max > 1 }' "$W/17-watch.txt"
if [ "$adopt" -ne 0 ]; then echo "adoption failed: stop"; exit 1; fi
helm history knarr --namespace "$worker_namespace"
kubectl -n "$worker_namespace" get deployment knarr -o jsonpath='{.status.replicas} replicas, {.status.readyReplicas} ready{"\n"}'
images
cd "$wt"
sh "$E"/state.sh
just smoke
# The adopted 0.2.0 controller acts on the Deployment that stayed opted in.
wait_for 60 owned_three
sh "$E"/state.sh
sh "$E"/metrics.sh
# A later ordinary upgrade, the guide's, with one changed value in the values
# file: no conflict, and the pod rolls.
cd "$op"
printf 'knarr:\n  log_level: debug\n' >| knarr-values.yaml
cat knarr-values.yaml
before=$(kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr -o jsonpath='{.items[0].metadata.uid}')
helm upgrade knarr oci://ghcr.io/steven-cutting/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" \
  --values knarr-values.yaml --wait --post-renderer jmsingle
echo "helm upgrade exit=$?"
kubectl -n "$worker_namespace" rollout status deployment/knarr
after=$(kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr -o jsonpath='{.items[0].metadata.uid}')
test "$before" != "$after" && echo "pod rolled: $before -> $after"
helm history knarr --namespace "$worker_namespace"
images
cd "$wt"
wait_for 60 owned_three
sh "$E"/state.sh
sh "$E"/metrics.sh
# The ordered uninstall, as in 16. 1: opt out.
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
# 4: helm uninstall.
helm -n "$worker_namespace" uninstall knarr
kubectl -n "$worker_namespace" wait --for=delete pod -l app.kubernetes.io/name=knarr --timeout=120s
sh "$E"/state.sh
kubectl -n "$worker_namespace" get deployment,serviceaccount,role,rolebinding -l app.kubernetes.io/name=knarr
absent=$(kubectl -n "$worker_namespace" get serviceaccount/knarr role/knarr rolebinding/knarr deployment/knarr 2>&1 | grep -c "(NotFound)")
echo "knarr resources NotFound: $absent of 4"
test "$absent" -eq 4
