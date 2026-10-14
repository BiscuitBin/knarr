#!/bin/sh
# Ticket 14 evidence: the negative case, kept by ticket 31 for the
# reconciler. knarr is deployed with a CA the apiserver does not chain to
# (ca-b from 01's generator, never committed). Every discovery cycle must
# fail its first LIST visibly with unknown_ca, nothing may succeed, and the
# process stays up with restartCount 0: a TLS failure is a value, not a
# crash. Readiness never latches, since no cycle completes (observability
# Probes Readiness), so the pod is Running and NotReady by design. Ends by
# redeploying the base. Run after 31's reconcile-kind.sh on the same
# cluster.
# Usage: sh wrong-ca.sh <worktree> <empty-work-dir>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
worktree=${1:?usage: wrong-ca.sh <worktree> <work-dir>}
work=${2:?usage: wrong-ca.sh <worktree> <work-dir>}
mkdir -p "$work"
cd "$worktree"
PATH="$worktree/.pixi/envs/default/bin:$worktree/.pixi/envs/cluster/bin:$worktree/.tools/bin:$PATH"
export PATH
KNARR_CLUSTER=kind; export KNARR_CLUSTER
KUBECONFIG=$worktree/.cluster/kubeconfig; export KUBECONFIG
image="knarr:$(sh scripts/cluster-name.sh . name)"
printf 'date: %s\nhost: %s\ncommit: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$(git rev-parse --short HEAD)"

# Whatever happens, leave the cluster on the base with the ConfigMap gone.
restore() {
  just deploy "$image" base || true
  kubectl delete configmap knarr-wrong-ca --ignore-not-found
}
trap restore EXIT

sh "$here/../01/tls/gen-certs.sh" "$work/certs" > /dev/null
kubectl create configmap knarr-wrong-ca --from-file=ca.crt="$work/certs/ca-b.pem" --dry-run=client -o yaml | kubectl apply -f -
# just deploy waits on kubectl rollout status under check=True, and the wrong-CA pod never latches readiness, so the rollout never completes; the restore trap redeploys the base.
just deploy "$image" wrong-ca || echo 'deploy: the rollout never completes by design (readiness never latches)'
pod=$(kubectl get pod -l app.kubernetes.io/name=knarr --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "pod $pod"
# The variable expands inside the pod, on purpose.
# shellcheck disable=SC2016
kubectl exec "$pod" -- sh -c 'echo "KNARR_CA_FILE=$KNARR_CA_FILE"'

# The first cycle runs at start; then two LIST intervals and a margin.
deadline=$(( $(date +%s) + 180 ))
while :; do
  kubectl logs --timestamps "$pod" > "$work/logs.txt"
  if grep -q 'tls_alert unknown_ca' "$work/logs.txt"; then break; fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo 'FAIL no unknown_ca in the log within 180 s'; grep '"msg"' "$work/logs.txt" | tail; exit 1; }
  sleep 10
done
sleep 65
kubectl logs --timestamps "$pod" > "$work/logs.txt"
echo '--- the reconciler lines ---'
grep '"msg":"list failed"\|"msg":"token changed"\|"msg":"discovery"' "$work/logs.txt" | sed 's/"sha256":"[0-9a-f]*"/"sha256":"..."/'
alerts=$(grep -c '"msg":"list failed".*tls_alert unknown_ca' "$work/logs.txt")
echo "ok   $alerts cycles refused the handshake with unknown_ca"
if grep -q '"msg":"discovery"\|"msg":"patch"' "$work/logs.txt"; then
  echo 'FAIL a request succeeded against the wrong CA'; exit 1
fi
echo 'ok   no LIST or PATCH succeeded: there is no unverified fallback'
phase=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}')
ready=$(kubectl get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
restarts=$(kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
if [ "$phase" = Running ] && [ "$ready" = False ] && [ "$restarts" = 0 ]; then
  echo 'ok   pod Running and NotReady with restartCount 0: the failure is a value, not a crash, and readiness never latched'
else
  echo "FAIL phase=$phase ready=$ready restarts=$restarts"; exit 1
fi

echo 'wrong-ca: all checks passed'
