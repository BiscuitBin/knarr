#!/bin/sh
# Ticket 41 evidence: how the apiserver's JSON Patch `test` treats null, which
# ownership's Precondition and WriteMode rely on. Five cases on pods built
# from the node's preloaded pause image, each a `kubectl patch --type=json`
# whose response status is read from kubectl's -v=6 log:
#   1. no annotations map: test /metadata/deletionTimestamp null, test
#      /metadata/annotations null, add the map            -> 200
#   2. map present: test deletionTimestamp null, test a missing key null,
#      add the key                                         -> 200
#   3. no annotations map: test /metadata/annotations/x null -> 422
#   4. test a key against a value it does not hold, then an add -> 422, and
#      the pod is unchanged
#   5. a pod held by a finalizer and deleted, so deletionTimestamp is set:
#      test deletionTimestamp null, then an add          -> 422; the
#      finalizer is then cleared
# Needs this worktree's kind cluster up (just cluster-up); makes no image
# pull and touches nothing outside its own namespace, which it deletes.
# Usage: sh json-patch-null.sh <worktree>
set -eu
worktree=${1:?usage: json-patch-null.sh <worktree>}
cd "$worktree"
PATH="$worktree/.pixi/envs/default/bin:$worktree/.pixi/envs/cluster/bin:$worktree/.tools/bin:$PATH"
export PATH
KUBECONFIG=$worktree/.cluster/kubeconfig; export KUBECONFIG
work=$(mktemp -d)
ns=knarr-evidence-41

printf 'date: %s\nhost: %s\ncommit: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$(git rev-parse --short HEAD)"
docker version --format 'docker {{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'
kind version
kubectl version --client | head -1
node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
echo "node $node kubelet $(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}') $(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.osImage}')"
echo "apiserver $(kubectl version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
pause=$(docker exec "$node" crictl images -o json | python3 -c '
import json, sys
tags = [t for i in json.load(sys.stdin)["images"] for t in i.get("repoTags") or [] if "/pause:" in t]
print(sorted(tags)[-1])')
echo "pause image $pause (preloaded on the node; imagePullPolicy Never)"

kubectl delete namespace "$ns" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$ns" >/dev/null

pod() {
  # create, not apply: apply adds its last-applied annotation, and cases 1
  # and 3 need a pod with no annotations map.
  kubectl -n "$ns" create -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  automountServiceAccountToken: false
  containers:
  - name: pause
    image: $pause
    imagePullPolicy: Never
EOF
}

failed=0
# case <n> <pod> <expected status> <patch>: sends the patch, prints the
# status kubectl's round tripper logged and the pod's annotations after it.
case_() {
  n=$1; name=$2; want=$3; patch=$4
  echo "--- case $n: $name"
  echo "patch: $patch"
  kubectl -n "$ns" patch pod "$name" --type=json -p "$patch" -v=6 > "$work/out" 2>&1 || true
  got=$(grep -E 'PATCH' "$work/out" | grep -oE '(status="| )[0-9]{3} [A-Z][A-Za-z ]*' | head -1 | sed 's/^status="//; s/^ //')
  grep -vE 'round_trippers|loader.go|cert_rotation|I[0-9]{4} ' "$work/out" | sed 's/^/kubectl: /' || true
  echo "status: $got"
  echo "annotations after: $(kubectl -n "$ns" get pod "$name" -o jsonpath='{.metadata.annotations}')"
  case $got in
    "$want"*) echo "ok   case $n: $want" ;;
    *) echo "FAIL case $n: wanted $want, got ${got:-no status}"; failed=1 ;;
  esac
}

pod bare
pod mapped
pod untouched
pod mismatch
pod terminating

echo "--- pods as created: annotations of each (empty means no map)"
for p in bare mapped untouched mismatch terminating; do
  echo "$p: $(kubectl -n "$ns" get pod "$p" -o jsonpath='{.metadata.annotations}')"
done

case_ 1 bare 200 '[{"op":"test","path":"/metadata/deletionTimestamp","value":null},{"op":"test","path":"/metadata/annotations","value":null},{"op":"add","path":"/metadata/annotations","value":{"knarr.io/x":"1"}}]'

kubectl -n "$ns" annotate pod mapped other=kept >/dev/null
case_ 2 mapped 200 '[{"op":"test","path":"/metadata/deletionTimestamp","value":null},{"op":"test","path":"/metadata/annotations/knarr.io~1x","value":null},{"op":"add","path":"/metadata/annotations/knarr.io~1x","value":"1"}]'

case_ 3 untouched 422 '[{"op":"test","path":"/metadata/annotations/knarr.io~1x","value":null}]'

kubectl -n "$ns" annotate pod mismatch knarr.io/x=1 >/dev/null
# The kubelet writes the pod's status meanwhile, so resourceVersion may move;
# the annotations are what a failed patch must leave alone.
before=$(kubectl -n "$ns" get pod mismatch -o jsonpath='{.metadata.annotations}')
case_ 4 mismatch 422 '[{"op":"test","path":"/metadata/annotations/knarr.io~1x","value":"2"},{"op":"add","path":"/metadata/annotations/knarr.io~1x","value":"3"}]'
after=$(kubectl -n "$ns" get pod mismatch -o jsonpath='{.metadata.annotations}')
if [ "$before" = "$after" ]; then echo "ok   case 4: annotations unchanged, $after"; else echo "FAIL case 4: annotations moved $before -> $after"; failed=1; fi

kubectl -n "$ns" patch pod terminating --type=json -p '[{"op":"add","path":"/metadata/finalizers","value":["knarr.io/evidence"]}]' >/dev/null
kubectl -n "$ns" delete pod terminating --wait=false >/dev/null
deletion=$(kubectl -n "$ns" get pod terminating -o jsonpath='{.metadata.deletionTimestamp}')
if [ -n "$deletion" ]; then echo "ok   case 5: deletionTimestamp set to $deletion, held by the finalizer"; else echo 'FAIL case 5: deletionTimestamp not set'; failed=1; fi
case_ 5 terminating 422 '[{"op":"test","path":"/metadata/deletionTimestamp","value":null},{"op":"add","path":"/metadata/annotations","value":{"knarr.io/x":"1"}}]'
kubectl -n "$ns" patch pod terminating --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null
kubectl -n "$ns" wait --for=delete pod/terminating --timeout=60s >/dev/null && echo 'ok   case 5: finalizer cleared and the pod is gone'

kubectl delete namespace "$ns" --wait=false >/dev/null
rm -rf "$work"
if [ "$failed" = 0 ]; then echo 'json-patch-null: all checks passed'; else echo 'json-patch-null: FAILED'; exit 1; fi
