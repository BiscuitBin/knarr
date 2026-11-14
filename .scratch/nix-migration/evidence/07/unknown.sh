#!/bin/sh
# Ticket 07 evidence: an unknown KNARR_TOOLS, with the network off, in the
# clone setup.sh initialized. `just --list` must still work; `just check`, a
# hook and `just initialize` must each refuse with exit 2 and the variable's
# name. The commit is attempted and refused, so nothing is left behind.
# Usage (Mac): sh host.sh --offline sh /evidence/unknown.sh > unknown.txt
set -eu
clone=/work/clone
cd "$clone"
just=$clone/.nix/default/bin/just
logs=/work/logs
mkdir -p "$logs"
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
printf 'clone at %s, git status --short: %s lines\n' "$(git rev-parse --short HEAD)" "$(git status --short | wc -l)"
KNARR_TOOLS=conda
export KNARR_TOOLS
run() { # label, command...
  label=$1
  shift
  status=0
  "$@" > "$logs/unknown.log" 2>&1 || status=$?
  printf '\n== KNARR_TOOLS=conda %s: exit %s\n' "$label" "$status"
}
run 'just --list' "$just" --list
head -n 3 "$logs/unknown.log" | sed 's/^/  /'
run 'just check' "$just" check
sed 's/^/  /' "$logs/unknown.log"
run 'just initialize' "$just" initialize
sed 's/^/  /' "$logs/unknown.log"
run 'sh scripts/initialize.sh' sh scripts/initialize.sh
sed 's/^/  /' "$logs/unknown.log"
run 'sh scripts/with-env.sh typos (what every hook entry runs)' sh scripts/with-env.sh typos
sed 's/^/  /' "$logs/unknown.log"

printf '# Probe\n' > probe.md
git add probe.md
run 'git commit (the installed hook)' git commit -m 'probe: never made'
grep -E 'Failed|exit code|KNARR_TOOLS' "$logs/unknown.log" | sort | uniq -c | sed 's/^/  /'
git reset --quiet probe.md
rm probe.md
printf '\ngit status --short: %s lines, at %s\n' "$(git status --short | wc -l)" "$(git rev-parse --short HEAD)"
