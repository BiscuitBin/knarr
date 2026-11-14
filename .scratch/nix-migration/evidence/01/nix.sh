#!/bin/sh
# Ticket 01 evidence: run one command in the digest-pinned Nix container.
# Nix is not installed on the host; every Nix fact here comes through this
# wrapper. It never mounts the worktree writable:
#   /nix       named volume knarr-nix-store (the store; persists fetches)
#   /work      named volume knarr-nix-01-work (the clone, HOME and Nix's caches)
#   /evidence  this directory, read-only (the scripts and the prototype flake)
#   /bundle    <worktree>/ai_tmp, read-only (the git bundle the clone is made from)
#   /out       <worktree>/ai_tmp/out, writable (transcripts on their way out)
# Usage: sh nix.sh [--offline] <command> [argument...]
#   --offline runs the container with --network none.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
# nixos/nix:latest on 2026-11-14, the multi-arch index (linux/amd64 and
# linux/arm64). Nix 2.35.6.
image=nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed
network=
if [ "${1:-}" = --offline ]; then
  network=--network=none
  shift
fi
mkdir -p "$root/ai_tmp/out"
# shellcheck disable=SC2086 # $network is empty or one word
exec docker run --rm $network \
  --volume=knarr-nix-store:/nix \
  --volume=knarr-nix-01-work:/work \
  --volume="$here":/evidence:ro \
  --volume="$root/ai_tmp":/bundle:ro \
  --volume="$root/ai_tmp/out":/out \
  --env=HOME=/work/home \
  --env=XDG_CACHE_HOME=/work/home/.cache \
  --env=NIX_CONFIG='experimental-features = nix-command flakes' \
  --workdir=/work \
  "$image" "$@"
