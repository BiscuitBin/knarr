#!/bin/sh
# Helm chart ticket 05 evidence: the published chart installed by digest,
# then upgraded by version. Run with sh -x, the worktree pixi PATH and
# KUBECONFIG, from the worktree root; the transcript beside it has its name.
E=.scratch/helm-chart/evidence/05
W=ai_tmp/05-published
echo 'Host deviation: this host is arm64 (OrbStack) and the release image amd64 only. Under Rosetta'
echo 'the BEAM needs the JIT single mapping, so every helm install, upgrade and template passes'
echo '--post-renderer jmsingle, which adds only the env entry ERL_AFLAGS="+JMsingle true" before'
echo 'ERL_FLAGS. Helm still owns every field, and the pod still runs the published image digest.'
export HELM_PLUGINS="$PWD/ai_tmp/helm-plugins"
cat ai_tmp/helm-plugins/jmsingle/render.sh
mkdir -p "$W"
# A fresh cluster.
just cluster-down
just cluster-up
# Install by the chart digest the v0.2.0 run summary printed
# (https://github.com/steven-cutting/knarr/actions/runs/39551271680).
worker_namespace=default
chart_version=0.2.0
chart_digest=sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016
kubectl config current-context
helm install knarr "oci://ghcr.io/steven-cutting/charts/knarr@$chart_digest" \
  --namespace "$worker_namespace" --wait --post-renderer jmsingle
kubectl -n "$worker_namespace" rollout status deployment/knarr
# The guide's image check: the Deployment's image and the pod's imageID.
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'
sh "$E"/state.sh
just smoke
# Upgrade to the same chart version with one changed value, from one values
# file, as the guide's upgrade passes it.
printf 'knarr:\n  log_level: debug\n' >| "$W/knarr-values.yaml"
cat "$W/knarr-values.yaml"
before=$(kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr -o jsonpath='{.items[0].metadata.uid}')
helm upgrade knarr oci://ghcr.io/steven-cutting/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" \
  --values "$W/knarr-values.yaml" --wait --post-renderer jmsingle
kubectl -n "$worker_namespace" rollout status deployment/knarr
after=$(kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr -o jsonpath='{.items[0].metadata.uid}')
test "$before" != "$after" && echo "pod rolled: $before -> $after"
helm history knarr --namespace "$worker_namespace"
helm list --namespace "$worker_namespace" -o json
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'
kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
sh "$E"/state.sh
just smoke
