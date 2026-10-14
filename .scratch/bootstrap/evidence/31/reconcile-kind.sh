#!/bin/sh
# Ticket 31 evidence: the reconciler on this worktree's kind cluster. Builds
# and deploys knarr's base with discovery on and the fake worker fixture,
# opts the fake-worker Deployment in, drives one worker's cost above the
# first threshold through its control endpoint and waits for knarr's marker
# and the pod-deletion-cost annotation on that pod, then drives the cost
# below the first threshold less the margin and waits for the removal with
# the marker's null record. Reads knarr's JSON log for the discovery and
# token lines and /metrics through a port-forward for the targets and the
# applied tier. Nothing printed holds a token: the token line carries the
# file's sha256 prefix and the expiry claim only.
# Usage: sh reconcile-kind.sh <worktree> <empty-work-dir>   (needs network, docker)
set -eu
worktree=${1:?usage: reconcile-kind.sh <worktree> <work-dir>}
work=${2:?usage: reconcile-kind.sh <worktree> <work-dir>}
mkdir -p "$work"
cd "$worktree"
PATH="$worktree/.pixi/envs/default/bin:$worktree/.pixi/envs/cluster/bin:$worktree/.tools/bin:$PATH"
export PATH
KNARR_CLUSTER=kind; export KNARR_CLUSTER
printf 'date: %s\nhost: %s\ncommit: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$(git rev-parse --short HEAD)"
docker version --format 'docker {{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'

just cluster-up
just image-build
just image-check
just deploy
just fake-worker-image-build
just fake-worker-deploy
KUBECONFIG=$worktree/.cluster/kubeconfig; export KUBECONFIG

# The reconciler marks readiness at the end of its first complete discovery
# cycle, which it runs at once on start, so the pod is Ready within the
# readiness probe's period.
kubectl rollout status deployment/knarr --timeout=120s
knarr=$(kubectl get pod -l app.kubernetes.io/name=knarr --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "knarr pod $knarr"

kubectl label deployment fake-worker knarr.io/enabled=true --overwrite
worker=$(kubectl get pod -l app.kubernetes.io/name=fake-worker --field-selector=status.phase=Running --sort-by=.metadata.name -o jsonpath='{.items[0].metadata.name}')
echo "worker pod $worker"

# A port forward to the worker's control endpoint, closed on exit.
kubectl port-forward "pod/$worker" 0:8081 > "$work/forward.txt" 2>&1 &
forward=$!
trap 'kill $forward 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  port=$(sed -n 's/.*127.0.0.1:\([0-9]*\) -> 8081.*/\1/p' "$work/forward.txt" | head -1)
  [ -n "$port" ] && break
  sleep 0.2
done
[ -n "${port:-}" ] || { echo 'FAIL no port forward'; cat "$work/forward.txt"; exit 1; }

# Waits until the pod's annotation equals the value given, or "" for absent,
# polling for up to the LIST interval and a margin.
await_annotation() {
  key=$1; wanted=$2; what=$3
  deadline=$(( $(date +%s) + 150 ))
  while :; do
    value=$(kubectl get pod "$worker" -o jsonpath="{.metadata.annotations.$key}")
    if [ "$value" = "$wanted" ]; then echo "ok   $what: $key=${value:-absent}"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL $what: $key=${value:-absent}, wanted ${wanted:-absent}"
      kubectl logs "$knarr" | tail -20
      return 1
    fi
    sleep 5
  done
}

echo '--- cost 1800 (above the first threshold): the write and the marker ---'
curl -sS -X PUT --data '{"cost":1800,"accepting":true}' "http://127.0.0.1:$port/control" > /dev/null
await_annotation 'controller\.kubernetes\.io/pod-deletion-cost' 1800 'pod-deletion-cost written'
marker=$(kubectl get pod "$worker" -o jsonpath='{.metadata.annotations.knarr\.io/applied}')
case $marker in
  *'"pod-deletion-cost":{"applied":"1800"'*) echo "ok   marker records the write: $marker" ;;
  *) echo "FAIL marker: $marker"; exit 1 ;;
esac

echo '--- cost 100 (below the first threshold less the margin): the removal ---'
curl -sS -X PUT --data '{"cost":100,"accepting":true}' "http://127.0.0.1:$port/control" > /dev/null
await_annotation 'controller\.kubernetes\.io/pod-deletion-cost' '' 'pod-deletion-cost removed'
marker=$(kubectl get pod "$worker" -o jsonpath='{.metadata.annotations.knarr\.io/applied}')
case $marker in
  *'"pod-deletion-cost":{"applied":null'*) echo "ok   marker keeps a null record: $marker" ;;
  *) echo "FAIL marker after removal: $marker"; exit 1 ;;
esac

echo '--- knarr log: the discovery and token lines ---'
kubectl logs "$knarr" > "$work/logs.txt"
grep -c '"msg":"discovery"' "$work/logs.txt" | sed 's/^/ok   discovery cycles logged: /'
grep '"msg":"token changed"' "$work/logs.txt" | head -1
if grep -q '"level":"error"' "$work/logs.txt"; then echo 'FAIL an error line was logged:'; grep '"level":"error"' "$work/logs.txt"; exit 1; fi
if grep -q 'Bearer ' "$work/logs.txt"; then echo 'FAIL a log line carries an Authorization header'; exit 1; fi
echo 'ok   no error line and no bearer token in the log'

echo '--- metrics through a port-forward: the targets and the applied tier ---'
# The patch line is at debug level, below the Deployment's default info, so
# the metrics are the proof that the cycle counted the pods it handled.
kubectl port-forward --address=127.0.0.1 deployment/knarr :8080 > "$work/metrics-forward.txt" 2>&1 &
mforward=$!
trap 'kill "$forward" "$mforward" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  metrics_port=$(sed -n 's/.*127.0.0.1:\([0-9]*\) -> 8080.*/\1/p' "$work/metrics-forward.txt" | head -1)
  [ -n "$metrics_port" ] && break
  sleep 0.2
done
[ -n "${metrics_port:-}" ] || { echo 'FAIL no metrics port forward'; cat "$work/metrics-forward.txt"; exit 1; }
curl -sS "http://127.0.0.1:$metrics_port/metrics" > "$work/metrics.txt"
for series in 'knarr_targets{kind="pods"}' 'knarr_pods{deployment="fake-worker",tier="0"}'; do
  if grep -qF "$series" "$work/metrics.txt"; then
    echo "ok   series present: $(grep -F "$series" "$work/metrics.txt" | head -1)"
  else
    echo "FAIL series absent: $series"; grep '^knarr_' "$work/metrics.txt"; exit 1
  fi
done
kill "$mforward" 2>/dev/null || true
restarts=$(kubectl get pod "$knarr" -o jsonpath='{.status.containerStatuses[0].restartCount}')
ready=$(kubectl get pod "$knarr" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [ "$restarts" = 0 ] && [ "$ready" = True ]; then echo 'ok   knarr Ready with restartCount 0'; else echo "FAIL ready=$ready restarts=$restarts"; exit 1; fi
echo 'reconcile-kind: all checks passed'
