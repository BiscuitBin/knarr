#!/bin/sh
# Ticket 07 evidence: the gate under KNARR_TOOLS=nix, with the network off, in
# the clone setup.sh initialized. No tracked file differs from the commit. A
# `result` link from a plain `nix build` is in the tree while the gate runs, to
# show that every tool skips it as it skips .nix/.
# Usage (Mac): sh host.sh --offline sh /evidence/gate.sh > gate.txt
set -eu
clone=/work/clone
cd "$clone"
logs=/work/logs
mkdir -p "$logs"
just=$clone/.nix/default/bin/just
KNARR_TOOLS=nix
export KNARR_TOOLS
seconds() { # start, as date +%s.%N printed it
  echo "$(date +%s.%N) $1" | awk '{ printf "%.2f", $1 - $2 }'
}

# shellcheck disable=SC1091 # the stand-in host's own file
. /etc/os-release
printf 'date: %s\nhost: %s, %s\n%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$PRETTY_NAME" "$(nix --version)"
if getent hosts cache.nixos.org > /dev/null 2>&1; then echo 'network: ON (unexpected)'; else echo 'network: off'; fi
printf 'clone at %s, git status --short: %s lines\n' "$(git rev-parse --short HEAD)" "$(git status --short | wc -l)"
printf 'KNARR_TOOLS=%s; pixi on PATH: %s; .pixi: %s; .tools: %s\n' "$KNARR_TOOLS" \
  "$(command -v pixi || echo absent)" "$(ls -d .pixi 2> /dev/null || echo absent)" "$(ls -d .tools 2> /dev/null || echo absent)"

printf '\n== The lock and environment checks: time, and what they write\n'
stored=$(find /nix/store -maxdepth 1 | wc -l)
touch /work/mark
for run in 1 2 3; do
  start=$(date +%s.%N)
  "$just" lock-check > "$logs/lock-check.log" 2>&1
  lock=$(seconds "$start")
  start=$(date +%s.%N)
  "$just" env-check > "$logs/env-check.log" 2>&1
  printf 'run %s: just lock-check %ss, just env-check %ss\n' "$run" "$lock" "$(seconds "$start")"
done
grep -v '^backend=' "$logs/lock-check.log" | sed 's/^/  lock-check: /' || true
grep '^env-check' "$logs/env-check.log" | sed 's/^/  /'
printf 'new store paths: %s; git status --short: %s lines\n' \
  "$(($(find /nix/store -maxdepth 1 | wc -l) - stored))" "$(git status --short | wc -l)"
printf 'files written outside the clone: %s\n' \
  "$(find "$HOME" /tmp -type f -newer /work/mark 2> /dev/null | sed "s,^$HOME/,~/," | tr '\n' ' ')"

printf '\n== KNARR_TOOLS=nix just check, with a result link left by a nix build without --out-link\n'
nix build --offline --no-update-lock-file .#default 2> /dev/null
printf 'result -> %s; git status --short: %s lines\n' "$(readlink result)" "$(git status --short | wc -l)"
start=$(date +%s.%N)
status=0
"$just" check > "$logs/check.log" 2>&1 || status=$?
printf 'exit %s in %ss\n' "$status" "$(seconds "$start")"
grep -E '^==> just ' "$logs/check.log" | tr '\n' ' '
printf '\n'
grep -E 'allium (check|analyse):|Validated [0-9]+ pages|env-check:' "$logs/check.log" || true
tail -n 1 "$logs/check.log"
printf 'git status --short: %s lines\n' "$(git status --short | wc -l)"
rm result
