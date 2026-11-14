#!/bin/sh
# Ticket 01 evidence: a fresh clone on a machine with only Nix reaches just.
# The store volume is new, so it holds the Nix image's own paths and nothing
# else, and HOME is new, so Nix has no fetch cache.
# Usage (host): KNARR_NIX_STORE=knarr-nix-01-fresh sh nix.sh sh /evidence/fresh.sh > fresh.txt
#               docker volume rm knarr-nix-01-fresh
set -eu
HOME=/work/fresh/home
XDG_CACHE_HOME=$HOME/.cache
export HOME XDG_CACHE_HOME
rm -rf /work/fresh
mkdir -p "$HOME"
git config --global advice.detachedHead false
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)"
printf 'store before: %s paths, %s\n' "$(find /nix/store -maxdepth 1 | wc -l)" "$(du -sh /nix/store | cut -f1)"
printf 'just on PATH: %s\n' "$(command -v just || echo absent)"

git clone --quiet --branch 01-nix-container-spike /bundle/knarr.bundle /work/fresh/clone
cd /work/fresh/clone
proto=./.scratch/nix-migration/evidence/01
printf '\n== The one command a fresh clone runs before it has just\n'
printf '$ nix build %s#default --no-update-lock-file --out-link .pixi/envs/default\n' "$proto"
start=$(date +%s)
nix build "$proto#default" --no-update-lock-file --out-link .pixi/envs/default 2> /work/fresh/build.log
printf 'cold: %s seconds\n' "$(($(date +%s) - start))"
# The Nix image has no sed or awk, so these lines use grep, cut and tr only.
printf '%s paths copied from cache.nixos.org\n' "$(grep -E -c "^copying path .* from 'https://cache.nixos.org'" /work/fresh/build.log)"
printf 'built here: %s\n' "$(grep -E "^building '" /work/fresh/build.log | cut -d- -f2- | cut -d"'" -f1 | tr '\n' ' ')"
start=$(date +%s)
nix build "$proto#default" --no-update-lock-file --out-link .pixi/envs/default 2> /dev/null
printf 'again, nothing to do: %s seconds\n' "$(($(date +%s) - start))"
printf 'store after: %s paths, %s\n' "$(find /nix/store -maxdepth 1 | wc -l)" "$(du -sh /nix/store | cut -f1)"
printf 'environment closure: %s\n' "$(nix path-info -Sh .pixi/envs/default | cut -f2- | tr -d ' ')"
printf 'git status --short: %s lines\n' "$(git status --short | wc -l)"

printf '\n== just, from the out-link\n'
.pixi/envs/default/bin/just --version
.pixi/envs/default/bin/just --list 2>&1 | head -n 4
printf '\n== just without an out-link\n'
printf '$ nix shell %s#default --no-update-lock-file --command just --version\n' "$proto"
nix shell "$proto#default" --no-update-lock-file --command just --version
