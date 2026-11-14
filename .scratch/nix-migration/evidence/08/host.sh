#!/bin/sh
# Ticket 08 evidence: run one command on ticket 07's stand-in for "a Linux
# machine with Nix installed" (07's host.sh), widened for the cluster loop.
# Nix is not installed on the Mac, so every Nix-backend fact here comes
# through this wrapper, on aarch64-linux. The Ubuntu base the Dockerfile
# ships, pinned by the same digest, with nothing installed into it:
#   /nix       the named volume knarr-nix-store (the store, warm from 01 and 07)
#   $work      the named volume knarr-nix-08-work, mounted at the path the
#              Docker daemon itself gives it. kwokctl's docker runtime
#              bind-mounts files from KWOK_WORKDIR into its containers, and
#              the daemon resolves a bind source on its own filesystem, so the
#              clone must have the same path here and there. The clone,
#              HOME and Nix's caches live in it.
#   /evidence  this directory, read-only (the scripts)
#   /bundle    <worktree>/ai_tmp, read-only (the git bundle the clone is made from)
#   /var/run/docker.sock  the Mac's Docker daemon, which kind, kwokctl and
#              `docker build` drive, as they drive a host's daemon.
#   --network host  the daemon's network namespace, so the API server port
#              kind and kwokctl publish on 127.0.0.1 is reachable here as it
#              is on a host.
#   PATH       ends with the Nix image's own profile (nix and git), then
#              $work/host/bin: the Docker client and its buildx plugin, built
#              from the flake's locked main input by setup.sh. Docker is a host
#              prerequisite (Decision 0017); this stands in for the host's.
#   /etc/ssl/certs/ca-certificates.crt and /usr/bin/git link into that
#              profile, as in 07: every real host has both.
# The worktree itself is never mounted.
# Usage: sh host.sh [--offline] <command> [argument...]
#   --offline runs the container with --network none, and without the socket.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
image=ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c
work=/var/lib/docker/volumes/knarr-nix-08-work/_data
network='--network=host --volume=/var/run/docker.sock:/var/run/docker.sock'
if [ "${1:-}" = --offline ]; then
  network=--network=none
  shift
fi
# The Ubuntu image has no nixbld group, and the builds run as root.
config='experimental-features = nix-command flakes
build-users-group =
sandbox = false'
# shellcheck disable=SC2086 # $network is a fixed list of words
exec docker run --rm $network \
  --volume=knarr-nix-store:/nix \
  --volume=knarr-nix-08-work:"$work" \
  --volume="$here":/evidence:ro \
  --volume="$root/ai_tmp":/bundle:ro \
  --env=WORK="$work" \
  --env=HOME="$work/home" \
  --env=XDG_CACHE_HOME="$work/home/.cache" \
  --env=NIX_CONFIG="$config" \
  --env=PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin:$work/host/bin" \
  --workdir="$work" \
  "$image" sh -c '
    mkdir -p /etc/ssl/certs
    ln -s /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
    ln -s /nix/var/nix/profiles/default/bin/git /usr/bin/git
    exec "$@"' host "$@"
