#!/bin/sh
# Ticket 01 evidence: which Nix commands rewrite a flake.lock that has drifted
# from flake.nix, and which is a read-only check that works offline.
# The drift: flake.nix names another revision for the nixpkgs-gleam input than
# flake.lock holds. The other revision is the candidate, already fetched, so
# every command can resolve it with the network off too.
# Usage (host): sh nix.sh sh /evidence/lock.sh > lock.txt
#               sh nix.sh --offline sh /evidence/lock.sh > lock-offline.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
gleam_rev=$(locked nixpkgs-gleam)
if curl -fsS --max-time 5 -o /dev/null https://cache.nixos.org/nix-cache-info 2> /dev/null; then
  network=on
else
  network=off
fi
printf 'date: %s\n%s on %s\nnetwork: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)" "$network"

work=/work/lock
drifted() {
  fresh_proto "$work"
  sed -i "s/$gleam_rev/$rev/" "$work/flake.nix"
}
# Run one command in a copy, and say what it did to flake.lock.
try() {
  before=$(cksum < "$work/flake.lock")
  status=0
  start=$(date +%s.%N)
  (cd "$work" && "$@") > "$work/.out" 2>&1 || status=$?
  seconds=$(echo "$(date +%s.%N) $start" | awk '{ printf "%.2f", $1 - $2 }')
  if [ "$(cksum < "$work/flake.lock")" = "$before" ]; then lock='flake.lock unchanged'; else lock='flake.lock REWRITTEN'; fi
  printf '%-58s exit %s  %-20s %5ss\n' "$*" "$status" "$lock" "$seconds"
}

printf '\n== Drifted: flake.nix names a revision flake.lock does not hold\n'
drifted
grep -n 'nixpkgs-gleam.url' "$work/flake.nix"
for command in \
  'nix flake lock' \
  'nix flake update' \
  'nix flake metadata' \
  'nix flake show' \
  'nix eval .#held.erlang' \
  'nix build --no-link .#runtime' \
  'nix shell .#runtime --command true' \
  'nix build --no-link .#runtime --no-write-lock-file' \
  'nix eval .#held.erlang --no-write-lock-file' \
  'nix build --no-link .#runtime --no-update-lock-file' \
  'nix eval .#held.erlang --no-update-lock-file' \
  'nix flake metadata --no-update-lock-file' \
  'nix flake lock --no-update-lock-file' \
  'nix flake lock --no-update-lock-file --offline'; do
  drifted
  # shellcheck disable=SC2086 # the command is a list of words
  try $command
done
printf '\nWhat the read-only check prints on drift:\n'
drifted
(cd "$work" && nix flake lock --no-update-lock-file --offline) 2>&1 | sed 's/^/  /' || true
cmp "$work/flake.lock" "$flake/flake.lock" && printf 'flake.lock is byte-identical to the committed one after the check: %s\n' "$(sha256sum < "$work/flake.lock" | cut -d' ' -f1)"

printf '\n== Fresh: flake.lock agrees with flake.nix\n'
for command in \
  'nix flake lock --no-update-lock-file --offline' \
  'nix flake lock --no-update-lock-file' \
  'nix flake lock' \
  'nix build --no-link .#runtime --no-update-lock-file' \
  'nix build --no-link .#runtime'; do
  fresh_proto "$work"
  # shellcheck disable=SC2086
  try $command
done

printf '\n== A lock with an input removed from flake.nix (stale entry), and one hand-edited\n'
fresh_proto "$work"
sed -i '/nixpkgs-kubectl.url/d; /nixpkgs-kubectl,/d' "$work/flake.nix"
# shellcheck disable=SC2016 # Nix's ${system}, not shell's
sed -i 's/nixpkgs-kubectl.legacyPackages.${system}.kubectl/pkgs.kubectl/' "$work/flake.nix"
try nix flake lock --no-update-lock-file --offline
fresh_proto "$work"
sed -i 's/"rev": "'"$gleam_rev"'"/"rev": "'"$rev"'"/' "$work/flake.lock"
try nix flake lock --no-update-lock-file --offline
try nix build --no-link .#runtime --no-update-lock-file --offline
sed -n '1,4p' "$work/.out" | sed 's/^/  /'

printf '\n== What the read-only check writes outside the flake directory\n'
fresh_proto "$work"
paths=$(find /nix/store -maxdepth 1 | wc -l)
try nix flake lock --no-update-lock-file --offline
try nix flake lock --no-update-lock-file --offline
printf 'new store paths: %s\n' "$(($(find /nix/store -maxdepth 1 | wc -l) - paths))"
printf 'files written under %s: %s\n' "$XDG_CACHE_HOME/nix" "$(find "$XDG_CACHE_HOME/nix" -type f -newer "$work/flake.lock" | sed "s,$XDG_CACHE_HOME/nix/,," | tr '\n' ' ')"
printf 'files in the flake directory: %s\n' "$(find "$work" -mindepth 1 -printf '%f ')"
