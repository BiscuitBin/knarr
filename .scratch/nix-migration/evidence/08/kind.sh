#!/bin/sh
# Ticket 08 evidence: the kind loop under KNARR_TOOLS=nix, on the Mac's Docker
# daemon through the socket, after setup.sh. Needs the network: the node
# image and the image build's base images and packages.
# Usage (Mac): sh host.sh sh /evidence/kind.sh > kind.txt
set -eu
cd "$WORK/clone"
printf 'date: %s\nclone at %s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git rev-parse --short=12 HEAD)" "$(uname -m)"
just=$WORK/clone/.nix/default/bin/just
export KNARR_TOOLS=nix
printf 'cluster name: %s\n' "$(sh scripts/cluster-name.sh . name)"
step() {
  printf '\n== just %s\n' "$*"
  start=$(date +%s)
  status=0
  "$just" "$@" > "$WORK/step.log" 2>&1 || status=$?
  # The tail of each step, without kubeconfig contents or tokens: no step prints them.
  tail -n 12 "$WORK/step.log" | sed "s|$WORK|\$WORK|g"
  printf -- '-> exit %s in %s seconds\n' "$status" "$(($(date +%s) - start))"
  [ "$status" = 0 ] || exit "$status"
}
step cluster-up
KUBECONFIG=.cluster/kubeconfig .nix/cluster/bin/kubectl version | grep -E '^(Client|Server) Version'
step image-build
step image-load
step deploy
step smoke
step cluster-down
printf '\n== After cluster-down\n'
printf 'kind get clusters: %s\n' "$(.nix/cluster/bin/kind get clusters 2>&1 | tr '\n' ' ')"
printf '.cluster exists: %s\n' "$([ -e .cluster ] && echo yes || echo no)"
printf 'git status --short: %s lines\n' "$(git status --short | wc -l)"
