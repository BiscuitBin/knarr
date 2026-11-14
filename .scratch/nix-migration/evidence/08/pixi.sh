#!/bin/sh
# Ticket 08 evidence: the pixi cluster loop on the Mac, in the worktree, with
# no KNARR_TOOLS set, through the same guard and install script as Nix.
# Needs the network: the cluster environment, the node and kwok images, and
# the image build.
# Usage (Mac, worktree root): sh .scratch/nix-migration/evidence/08/pixi.sh > .scratch/nix-migration/evidence/08/pixi.txt
set -eu
unset KNARR_TOOLS
printf '# %s, %s at %s on %s %s, cluster %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
  "$(git branch --show-current)" "$(git rev-parse --short=12 HEAD)" "$(uname -s)" "$(uname -m)" \
  "$(sh scripts/cluster-name.sh . name)"
printf 'backend: %s\n' "$(sh scripts/tool-dirs.sh backend)"
just=$(sh scripts/tool-dirs.sh tool just)
step() {
  printf '\n== %sjust %s\n' "${KNARR_CLUSTER:+KNARR_CLUSTER=$KNARR_CLUSTER }" "$*"
  start=$(date +%s)
  status=0
  "$just" "$@" > ai_tmp/step.log 2>&1 || status=$?
  tail -n 6 ai_tmp/step.log | sed "s|$PWD|.|g"
  printf -- '-> exit %s in %s seconds\n' "$status" "$(($(date +%s) - start))"
  [ "$status" = 0 ] || exit "$status"
}
step cluster-install
printf 'kind: %s; kubectl: %s; kwokctl: %s\n' \
  "$(.pixi/envs/cluster/bin/kind version)" \
  "$(.pixi/envs/cluster/bin/kubectl version --client | head -n 1)" \
  "$(sh scripts/tool-dirs.sh tool kwokctl | sed "s|$PWD|.|")"
step cluster-up
step image-build
step image-load
step deploy
step smoke
step cluster-down
export KNARR_CLUSTER=kwok
step cluster-up
step cluster-ready
step cluster-down
printf '\n== After\n'
printf 'kind clusters: %s\n' "$(.pixi/envs/cluster/bin/kind get clusters 2>&1 | tr '\n' ' ')"
printf '.cluster exists: %s\n' "$([ -e .cluster ] && echo yes || echo no)"
