#!/bin/sh
# Set a fake worker's cost through its control endpoint, by the API server's
# pod proxy under a short-lived kubectl proxy: control.sh POD COST.
cd "$(dirname "$0")/../../../.." || exit 1
PATH="$PWD/.pixi/envs/default/bin:$PWD/.pixi/envs/cluster/bin:$PATH" KUBECONFIG=$PWD/.cluster/kubeconfig
export PATH KUBECONFIG
kubectl proxy --address=127.0.0.1 --port=18005 >/dev/null 2>&1 &
proxy=$!
trap 'kill $proxy' EXIT
i=0; until curl --noproxy '*' -s -o /dev/null http://127.0.0.1:18005/version || [ $i -ge 50 ]; do sleep 0.1; i=$((i+1)); done
status=0
curl --noproxy '*' --fail -s -X PUT -H 'content-type: application/json' \
  -d "{\"cost\": $2, \"accepting\": true, \"failure\": \"none\", \"latency_ms\": 0}" \
  "http://127.0.0.1:18005/api/v1/namespaces/default/pods/$1:8081/proxy/control" || status=$?
echo
exit "$status"
