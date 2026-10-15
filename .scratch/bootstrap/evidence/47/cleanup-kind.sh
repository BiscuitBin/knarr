#!/bin/sh
# Ticket 47 evidence: an opt-out cleaned up on this worktree's kind cluster.
# Runs after ../31/reconcile-kind.sh on the same cluster, which leaves knarr
# running and the fake-worker Deployment opted in. Drives the same worker's
# cost back above the first threshold and waits for the pod-deletion-cost
# annotation and knarr's marker, opens a port-forward to knarr's /metrics,
# removes the Deployment's knarr.io/enabled label, and then scrapes /metrics
# about once a second while it waits for the annotation and the marker to
# leave the pod. It requires a scrape that counts the cleanup on
# knarr_patches_total with purpose cleanup and result accepted, then a later
# scrape with no series labelled with the Deployment at all. Every scrape is
# kept under the work directory, numbered, so the sequence can be read back.
# The opt-out is seen at the next LIST (up to 60 s), the cleanup waits the
# patch interval from the write before it (up to 60 s), and the series retire
# about one LIST after the cleanup is accepted, so the wait is 330 s.
# Usage: sh cleanup-kind.sh <worktree> <empty-work-dir>   (after reconcile-kind.sh)
set -eu
worktree=${1:?usage: cleanup-kind.sh <worktree> <work-dir>}
work=${2:?usage: cleanup-kind.sh <worktree> <work-dir>}
mkdir -p "$work/scrapes"
cd "$worktree"
PATH="$worktree/.pixi/envs/default/bin:$worktree/.pixi/envs/cluster/bin:$worktree/.tools/bin:$PATH"
export PATH
KUBECONFIG=$worktree/.cluster/kubeconfig; export KUBECONFIG
printf 'date: %s\nhost: %s\ncommit: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$(git rev-parse --short HEAD)"

knarr=$(kubectl get pod -l app.kubernetes.io/name=knarr --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "knarr pod $knarr"
# The same pod reconcile-kind.sh drove, picked the same way.
worker=$(kubectl get pod -l app.kubernetes.io/name=fake-worker --field-selector=status.phase=Running --sort-by=.metadata.name -o jsonpath='{.items[0].metadata.name}')
echo "worker pod $worker"
enabled=$(kubectl get deployment fake-worker -o jsonpath='{.metadata.labels.knarr\.io/enabled}')
[ "$enabled" = true ] || { echo "FAIL fake-worker is not opted in (knarr.io/enabled=${enabled:-absent}); run reconcile-kind.sh first"; exit 1; }

# A port forward to the worker's control endpoint and one to knarr's
# /metrics, both closed on exit.
forward=''
mforward=''
trap 'kill "$forward" "$mforward" 2>/dev/null || true' EXIT
kubectl port-forward "pod/$worker" 0:8081 > "$work/forward.txt" 2>&1 &
forward=$!
for _ in $(seq 1 50); do
  port=$(sed -n 's/.*127.0.0.1:\([0-9]*\) -> 8081.*/\1/p' "$work/forward.txt" | head -1)
  [ -n "$port" ] && break
  sleep 0.2
done
[ -n "${port:-}" ] || { echo 'FAIL no port forward'; cat "$work/forward.txt"; exit 1; }

# Opens the metrics port forward, or opens it again when it has dropped:
# the scrapes run for minutes, longer than a port forward reliably lives.
open_metrics_forward() {
  kill "$mforward" 2>/dev/null || true
  kubectl port-forward --address=127.0.0.1 deployment/knarr :8080 > "$work/metrics-forward.txt" 2>&1 &
  mforward=$!
  metrics_port=''
  for _ in $(seq 1 50); do
    metrics_port=$(sed -n 's/.*127.0.0.1:\([0-9]*\) -> 8080.*/\1/p' "$work/metrics-forward.txt" | head -1)
    [ -n "$metrics_port" ] && break
    sleep 0.2
  done
  [ -n "$metrics_port" ] || { echo 'FAIL no metrics port forward'; cat "$work/metrics-forward.txt"; exit 1; }
}

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

# Scrapes /metrics into the numbered file given, its first line the epoch
# second of the scrape. A failed scrape leaves the file without knarr_targets
# and reopens the forward, so it never reads as a retirement.
scrape() {
  file=$1
  echo "# at $(date +%s)" > "$file"
  if ! curl -sS --max-time 3 "http://127.0.0.1:$metrics_port/metrics" >> "$file" 2>&1; then
    kill -0 "$mforward" 2>/dev/null || open_metrics_forward
  fi
}

# True when the scrape answered: knarr_targets is always exposed.
answered() { grep -q '^knarr_targets{' "$1"; }

# True when the scrape counts an accepted cleanup for fake-worker, matched by
# label presence, not order.
counts_cleanup() {
  grep '^knarr_patches_total{' "$1" | grep -F 'deployment="fake-worker"' | grep -F 'purpose="cleanup"' | grep -qF 'result="accepted"'
}

# The number of series labelled with fake-worker in the scrape.
fake_worker_series() { grep -c 'deployment="fake-worker"' "$1" || :; }

echo '--- cost 1800 (above the first threshold): the write and the marker ---'
curl -sS -X PUT --data '{"cost":1800,"accepting":true}' "http://127.0.0.1:$port/control" > /dev/null
await_annotation 'controller\.kubernetes\.io/pod-deletion-cost' 1800 'pod-deletion-cost written'
marker=$(kubectl get pod "$worker" -o jsonpath='{.metadata.annotations.knarr\.io/applied}')
case $marker in
  *'"pod-deletion-cost":{"applied":"1800"'*) echo "ok   marker records the write: $marker" ;;
  *) echo "FAIL marker: $marker"; exit 1 ;;
esac

echo '--- metrics through a port-forward: the series before the opt-out ---'
open_metrics_forward
scrape "$work/scrapes/0000.txt"
answered "$work/scrapes/0000.txt" || { echo 'FAIL the first scrape did not answer'; cat "$work/scrapes/0000.txt"; exit 1; }
before=$(fake_worker_series "$work/scrapes/0000.txt")
[ "$before" -gt 0 ] || { echo 'FAIL no fake-worker series before the opt-out'; grep '^knarr_' "$work/scrapes/0000.txt"; exit 1; }
echo "ok   $before fake-worker series before the opt-out"

echo '--- opt-out: the cleanup, its count and the series retirement ---'
kubectl label deployment fake-worker knarr.io/enabled-
# One loop scrapes every second and reads the pod every fifth: it ends when
# both annotations are gone and a scrape with no fake-worker series has
# followed one that counts the accepted cleanup, or at the deadline. The
# scrape that counts the cleanup may come before the annotations are seen
# gone, so the scrapes start with the opt-out, not after the cleanup.
deadline=$(( $(date +%s) + 330 ))
n=0; counted=''; retired=''; cleaned=''; cost=''
while :; do
  n=$((n + 1))
  file=$work/scrapes/$(printf '%04d' "$n").txt
  scrape "$file"
  if answered "$file"; then
    if [ -z "$counted" ] && counts_cleanup "$file"; then
      counted=$n
      echo "ok   scrape $n $(head -1 "$file" | cut -c3-): $(grep '^knarr_patches_total{' "$file" | grep -F 'purpose="cleanup"' | grep -F 'deployment="fake-worker"' | grep -F 'result="accepted"')"
    elif [ -n "$counted" ] && [ -z "$retired" ] && [ "$(fake_worker_series "$file")" = 0 ]; then
      retired=$n
      echo "ok   scrape $n $(head -1 "$file" | cut -c3-): no series labelled deployment=\"fake-worker\""
    fi
  fi
  if [ -z "$cleaned" ] && [ $((n % 5)) = 0 ]; then
    cost=$(kubectl get pod "$worker" -o jsonpath='{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}')
    marker=$(kubectl get pod "$worker" -o jsonpath='{.metadata.annotations.knarr\.io/applied}')
    if [ -z "$cost" ] && [ -z "$marker" ]; then
      cleaned=$n
      echo "ok   by scrape $n: controller.kubernetes.io/pod-deletion-cost and knarr.io/applied absent"
    fi
  fi
  [ -n "$cleaned" ] && [ -n "$retired" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    [ -n "$cleaned" ] || echo "FAIL annotations: pod-deletion-cost=${cost:-absent} knarr.io/applied=${marker:-absent}"
    [ -n "$counted" ] || echo 'FAIL no scrape counted knarr_patches_total with deployment="fake-worker", purpose="cleanup", result="accepted"'
    if [ -n "$counted" ] && [ -z "$retired" ]; then
      echo "FAIL fake-worker series still exposed after scrape $counted counted the cleanup:"
      grep 'deployment="fake-worker"' "$file" || :
    fi
    kubectl logs "$knarr" | tail -20
    exit 1
  fi
  sleep 1
done
kill "$mforward" 2>/dev/null || true
kubectl get pod "$worker" -o jsonpath='{.metadata.annotations}' > "$work/annotations.txt"
echo "ok   $n scrapes kept under $work/scrapes"

echo '--- knarr log and pod ---'
kubectl logs "$knarr" > "$work/logs.txt"
if grep -q '"level":"error"' "$work/logs.txt"; then echo 'FAIL an error line was logged:'; grep '"level":"error"' "$work/logs.txt"; exit 1; fi
if grep -q 'Bearer ' "$work/logs.txt"; then echo 'FAIL a log line carries an Authorization header'; exit 1; fi
echo 'ok   no error line and no bearer token in the log'
restarts=$(kubectl get pod "$knarr" -o jsonpath='{.status.containerStatuses[0].restartCount}')
ready=$(kubectl get pod "$knarr" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [ "$restarts" = 0 ] && [ "$ready" = True ]; then echo 'ok   knarr Ready with restartCount 0'; else echo "FAIL ready=$ready restarts=$restarts"; exit 1; fi
echo 'cleanup-kind: all checks passed'
