#!/bin/sh
# Ticket 01 evidence: rerun every container script and rewrite its transcript.
# Needs Docker and the network, and writes only to this directory, to
# <worktree>/ai_tmp/ and to the two named volumes nix.sh mounts.
# Usage: sh .scratch/nix-migration/evidence/01/run-all.sh [script...]
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
mkdir -p "$root/ai_tmp"
# The clone inside the container is made from this bundle, never from a mount
# of the worktree.
git -C "$root" bundle create "$root/ai_tmp/knarr.bundle" HEAD "$(git -C "$root" branch --show-current)" 2> /dev/null
[ "$#" -gt 0 ] || set -- systems packages holds gleam-override missing lock git
for script in "$@"; do
  printf '%s\n' "== $script" >&2
  sh "$here/nix.sh" sh "/evidence/$script.sh" > "$here/$script.txt.new" 2>&1 ||
    { tail -n 20 "$here/$script.txt.new" >&2; exit 1; }
  mv "$here/$script.txt.new" "$here/$script.txt"
done
case " $* " in
  *" lock "*)
    sh "$here/nix.sh" --offline sh /evidence/lock.sh > "$here/lock-offline.txt.new" 2>&1
    mv "$here/lock-offline.txt.new" "$here/lock-offline.txt"
    ;;
esac
