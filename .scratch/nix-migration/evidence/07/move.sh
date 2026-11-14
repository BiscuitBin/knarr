#!/bin/sh
# Ticket 07 evidence: a simulated lock move, then the environment check, a
# fresh `just initialize` and a commit through the hook. Needs the network: the
# moved input and the environment it describes. The move is ticket 01's:
# nixpkgs-unstable at 9ac0edc, a head a few days older than the lock's, where
# every held version is the same and prek is 0.5.7, so its store path moves.
# At the end the clone goes back to the commit and is initialized again.
# Usage (Mac): sh host.sh sh /evidence/move.sh > move.txt
set -eu
clone=/work/clone
moved=9ac0edc06bfb33e6c0000be79d98ef8d89e26503
cd "$clone"
KNARR_TOOLS=nix
export KNARR_TOOLS
just=$clone/.nix/default/bin/just
logs=/work/logs
mkdir -p "$logs"
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
printf 'clone at %s, git status --short: %s lines\n' "$(git rev-parse --short HEAD)" "$(git status --short | wc -l)"
environment() {
  printf '  .nix/default -> %s\n' "$(readlink .nix/default)"
  printf '  its prek: %s (%s)\n' "$(readlink -f .nix/default/bin/prek)" "$(.nix/default/bin/prek --version)"
  printf '  the hook: %s, %s store paths\n' "$(grep '^PREK=' .git/hooks/pre-commit)" "$(grep -c /nix/store/ .git/hooks/pre-commit || true)"
}
printf '\n== Before the move\n'
environment

printf '\n== The lock moves, as a pull that moved it would: nixpkgs to %s\n' "$moved"
nix flake lock --override-input nixpkgs "github:NixOS/nixpkgs/$moved" 2> /dev/null
git diff --stat flake.lock | sed 's/^/  /'
printf '  nixpkgs locked at %s\n' "$(sed -n '/"nixpkgs": {/,/"rev"/s/.*"rev": "\(.*\)".*/\1/p' flake.lock)"

printf '\n== KNARR_TOOLS=nix just env-check\n'
status=0
"$just" env-check > "$logs/move-env-check.log" 2>&1 || status=$?
printf 'exit %s\n' "$status"
grep -v '^python3 ' "$logs/move-env-check.log" | sed 's/^/  /'

printf '\n== KNARR_TOOLS=nix just initialize\n'
"$just" initialize > "$logs/move-initialize.log" 2>&1
grep -E '^(Ready|Nothing has been)' "$logs/move-initialize.log" | sed 's/^/  /'
environment
status=0
"$just" env-check > "$logs/move-env-check.log" 2>&1 || status=$?
printf 'just env-check: exit %s: %s\n' "$status" "$(grep '^env-check' "$logs/move-env-check.log")"

printf '\n== A commit through the hook, with the lock move and one new page staged\n'
printf '# Probe\n\nA page the hooks check.\n' > probe.md
git add probe.md flake.lock
hooked=$(sed -n 's/^PREK="\(.*\)"$/\1/p' .git/hooks/pre-commit)
# The hook falls back to a prek on PATH when its own is not executable; this
# host has none, so a passing commit ran the one the hook names.
printf 'prek on the host PATH: %s\n' "$(command -v prek || echo none)"
printf 'the hook runs %s, which is %s (%s)\n' "$hooked" "$(readlink -f "$hooked")" "$("$hooked" --version)"
status=0
git commit -m 'probe: the moved lock' > "$logs/move-commit.log" 2>&1 || status=$?
printf 'git commit: exit %s\n' "$status"
grep -E 'Passed|Failed|Skipped' "$logs/move-commit.log" | grep -v 'no files to check' | sed 's/^/  /'
git log --oneline -1 | sed 's/^/  /'

printf '\n== Back to the commit, initialized again\n'
git reset --quiet --hard HEAD~1
rm -f probe.md
"$just" initialize > "$logs/move-initialize.log" 2>&1
environment
status=0
"$just" env-check > "$logs/move-env-check.log" 2>&1 || status=$?
printf 'just env-check: exit %s: %s\n' "$status" "$(grep '^env-check' "$logs/move-env-check.log")"
printf 'git status --short: %s lines, at %s\n' "$(git status --short | wc -l)" "$(git rev-parse --short HEAD)"
