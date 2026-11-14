#!/bin/sh
# Ticket 07 evidence: run one command on ticket 01's stand-in for "a Linux
# machine with Nix installed" (01's host.sh, with this ticket's work volume).
# Nix is not installed on the Mac, so every Nix-backend fact here comes through
# this wrapper, on aarch64-linux. The Nix image itself cannot run the gate: it
# has no /usr/bin and no sed. This is the Ubuntu base the Dockerfile ships,
# pinned by the same digest, with nothing installed into it:
#   /nix       the named volume knarr-nix-store (the store, warm from ticket 01)
#   /work      the named volume knarr-nix-07-work (the clone, HOME and Nix's
#              caches, the same for the online and the offline runs)
#   /evidence  this directory, read-only (the scripts)
#   /bundle    <worktree>/ai_tmp, read-only (the git bundle the clone is made from)
#   PATH       ends with the Nix image's own profile, which supplies nix and git
#   /etc/ssl/certs/ca-certificates.crt links to that profile's CA bundle: the
#              base image has no CA store, which every real machine has.
#   /usr/bin/git links to that profile's git. Git is a host prerequisite
#              (Decision 0017), and the test_initialize cases run the script
#              with PATH=/usr/bin:/bin exactly, where every real host has it.
# The worktree itself is never mounted.
# Usage: sh host.sh [--offline] <command> [argument...]
#   --offline runs the container with --network none.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
image=ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c
network=
if [ "${1:-}" = --offline ]; then
  network=--network=none
  shift
fi
# The Ubuntu image has no nixbld group, and the builds run as root.
config='experimental-features = nix-command flakes
build-users-group =
sandbox = false'
# shellcheck disable=SC2086 # $network is empty or one word
exec docker run --rm $network \
  --volume=knarr-nix-store:/nix \
  --volume=knarr-nix-07-work:/work \
  --volume="$here":/evidence:ro \
  --volume="$root/ai_tmp":/bundle:ro \
  --env=HOME=/work/home \
  --env=XDG_CACHE_HOME=/work/home/.cache \
  --env=NIX_CONFIG="$config" \
  --env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin \
  --workdir=/work \
  "$image" sh -c '
    mkdir -p /etc/ssl/certs
    ln -s /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
    ln -s /nix/var/nix/profiles/default/bin/git /usr/bin/git
    exec "$@"' host "$@"
