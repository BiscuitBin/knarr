#!/bin/sh
# Ticket 01 evidence: run one command on a stand-in for "a Linux machine with
# only Nix installed". The Nix image itself is not one: it has no /usr/bin, and
# no sed, awk, find, diff or perl, which the repository's scripts and tests
# take from the machine. This is the Ubuntu base the Dockerfile ships, pinned
# by the same digest, with three additions and no package installed into it:
#   /nix   the store volume nix.sh populated (knarr-nix-store)
#   PATH   ends with the Nix image's own profile, which supplies nix and git
#   /etc/ssl/certs/ca-certificates.crt links to that profile's CA bundle. The
#          base image has no CA store, which every real machine has; lychee and
#          the Erlang HTTP tests load the system store even when offline.
# Ubuntu's base image has no git, python, node or curl of its own.
# Usage: sh host.sh [--offline] <command> [argument...]
#   KNARR_HOST_NO_CA=1 leaves the CA link out; host-needs.sh uses it to show
#   what then fails.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
image=ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c
network=
if [ "${1:-}" = --offline ]; then
  network=--network=none
  shift
fi
mkdir -p "$root/ai_tmp/out"
# The Ubuntu image has no nixbld group, and the builds run as root.
config='experimental-features = nix-command flakes
build-users-group =
sandbox = false'
# shellcheck disable=SC2086 # $network is empty or one word
exec docker run --rm $network \
  --volume=knarr-nix-store:/nix \
  --volume=knarr-nix-01-work:/work \
  --volume="$here":/evidence:ro \
  --volume="$root/ai_tmp":/bundle:ro \
  --volume="$root/ai_tmp/out":/out \
  --env=HOME=/work/home \
  --env=XDG_CACHE_HOME=/work/home/.cache \
  --env=NIX_CONFIG="$config" \
  --env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin \
  --workdir=/work \
  --env=KNARR_HOST_NO_CA="${KNARR_HOST_NO_CA:-}" \
  "$image" sh -c '
    if [ -z "$KNARR_HOST_NO_CA" ]; then
      mkdir -p /etc/ssl/certs
      ln -s /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
    fi
    exec "$@"' host "$@"
