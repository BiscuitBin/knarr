#!/bin/sh
# Ticket 08 evidence: the kwok loop under KNARR_TOOLS=nix with
# KNARR_CLUSTER=kwok, after setup.sh. Needs the network: the kwok images.
# kwokctl's docker runtime bind-mounts files from KWOK_WORKDIR, which is why
# host.sh mounts the work volume at the daemon's own path for it.
# Usage (Mac): sh host.sh sh /evidence/kwok.sh > kwok.txt
set -eu
cd "$WORK/clone"
printf 'date: %s\nclone at %s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git rev-parse --short=12 HEAD)" "$(uname -m)"
just=$WORK/clone/.nix/default/bin/just
export KNARR_TOOLS=nix KNARR_CLUSTER=kwok
step() {
  printf '\n== KNARR_CLUSTER=kwok just %s\n' "$*"
  start=$(date +%s)
  status=0
  "$just" "$@" > "$WORK/step.log" 2>&1 || status=$?
  tail -n 12 "$WORK/step.log" | sed "s|$WORK|\$WORK|g"
  printf -- '-> exit %s in %s seconds\n' "$status" "$(($(date +%s) - start))"
  [ "$status" = 0 ] || exit "$status"
}
step cluster-up
printf 'kwokctl get clusters: %s\n' "$(KWOK_WORKDIR=.cluster/kwok .nix/cluster/bin/kwokctl get clusters 2>&1 | tr '\n' ' ')"
printf 'nodes: %s\n' "$(KUBECONFIG=.cluster/kubeconfig .nix/cluster/bin/kubectl get nodes -o name | tr '\n' ' ')"
KUBECONFIG=.cluster/kubeconfig .nix/cluster/bin/kubectl version | grep -E '^(Client|Server) Version'
step cluster-ready
step cluster-down
printf '\n== After cluster-down\n'
printf 'kwok containers: %s\n' "$(docker ps -a --filter name=kwok- --format '{{.Names}}' | tr '\n' ' ')"
printf '.cluster exists: %s\n' "$([ -e .cluster ] && echo yes || echo no)"
