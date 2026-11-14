#!/bin/sh
# Ticket 01 evidence: rerun every container script and rewrite its transcript.
# Needs Docker and the network, and writes only to this directory, to
# <worktree>/ai_tmp/, to the two named volumes nix.sh mounts and to the
# knarr-nix-proto:01 image. The order matters: gate-setup clones the branch as
# committed, so commit a changed script before rerunning what follows it.
# Usage: sh .scratch/nix-migration/evidence/01/run-all.sh [script...]
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
mkdir -p "$root/ai_tmp"
# The clone inside the container is made from this bundle, never from a mount
# of the worktree.
git -C "$root" bundle create "$root/ai_tmp/knarr.bundle" HEAD "$(git -C "$root" branch --show-current)" 2> /dev/null
[ "$#" -gt 0 ] || set -- systems packages holds gleam-override missing lock git tls-pairs \
  gate-setup host-needs gate differences fresh image grype
transcript() { # name, command...: rewrite <name>.txt only if the command succeeds
  name=$1
  shift
  printf '%s\n' "== $name" >&2
  "$@" > "$here/$name.txt.new" 2>&1 || { tail -n 20 "$here/$name.txt.new" >&2; exit 1; }
  mv "$here/$name.txt.new" "$here/$name.txt"
}
both_hosts() {
  sh "$here/nix.sh" --offline sh /evidence/host-needs.sh
  KNARR_HOST_NO_CA=1 sh "$here/host.sh" --offline sh /evidence/host-needs.sh
}
for script in "$@"; do
  case $script in
    lock)
      transcript lock sh "$here/nix.sh" sh /evidence/lock.sh
      transcript lock-offline sh "$here/nix.sh" --offline sh /evidence/lock.sh
      ;;
    host-needs)
      # Both halves need the clone gate-setup makes, and the network off.
      transcript host-needs both_hosts
      ;;
    gate | differences)
      # On the stand-in host, in the clone gate-setup makes, with the network off.
      transcript "$script" sh "$here/host.sh" --offline sh "/evidence/$script.sh"
      ;;
    fresh)
      # A store volume of its own, removed afterwards.
      transcript fresh env KNARR_NIX_STORE=knarr-nix-01-fresh sh "$here/nix.sh" sh /evidence/fresh.sh
      docker volume rm knarr-nix-01-fresh > /dev/null
      ;;
    image)
      # On the host; the baseline is the released image, pulled beforehand.
      transcript image sh "$here/image.sh" ghcr.io/biscuitbin/knarr:0.3.1
      ;;
    grype)
      docker save knarr-nix-proto:01 --output "$root/ai_tmp/knarr-nix-proto.tar"
      transcript grype sh "$here/nix.sh" sh /evidence/grype.sh
      ;;
    *)
      transcript "$script" sh "$here/nix.sh" sh "/evidence/$script.sh"
      ;;
  esac
done
