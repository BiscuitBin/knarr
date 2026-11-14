#!/bin/sh
# Ticket 07 evidence: the checker tests under KNARR_TOOLS=nix as a user that is
# not root, with the network off, in the clone setup.sh initialized. Ticket
# 05's runner had two ripsecrets wrapper failures from a read-only store file
# copied and then written; ticket 01's container ran as root and never saw
# them. Started as root, it gives the clone (never the store) to uid 1000 and
# runs the tests as that user; at the end the clone goes back to root.
# Usage (Mac): sh host.sh --offline sh /evidence/nonroot.sh > nonroot.txt
set -eu
clone=/work/clone
uid=1000
home=/work/home-$uid
logs=/work/logs
mkdir -p "$logs" "$home"
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
if getent hosts cache.nixos.org > /dev/null 2>&1; then echo 'network: ON (unexpected)'; else echo 'network: off'; fi
cd "$clone"
printf 'clone at %s\n' "$(git rev-parse --short HEAD)"
# -h changes the out-links themselves and never follows them into the store.
chown -R -h "$uid:$uid" "$clone" "$home" "$logs"
printf 'the pinned ripsecrets: %s, mode %s, owner %s\n' "$(readlink -f .nix/default/bin/ripsecrets)" \
  "$(stat -L -c %a .nix/default/bin/ripsecrets)" "$(stat -L -c %U .nix/default/bin/ripsecrets)"

as_user() {
  setpriv --reuid="$uid" --regid="$uid" --clear-groups \
    env HOME="$home" XDG_CACHE_HOME="$home/.cache" KNARR_TOOLS=nix "$@"
}
printf 'running as: %s\n' "$(as_user id)"

printf '\n== The ripsecrets wrapper tests\n'
status=0
as_user .nix/default/bin/python3 -m pytest -p no:cacheprovider -q \
  scripts/checks/tests/test_ripsecrets_redacted.py > "$logs/nonroot-ripsecrets.log" 2>&1 || status=$?
printf 'exit %s: %s\n' "$status" "$(tail -n 1 "$logs/nonroot-ripsecrets.log")"

printf '\n== KNARR_TOOLS=nix just test-checkers-all\n'
status=0
as_user .nix/default/bin/just test-checkers-all > "$logs/nonroot-all.log" 2>&1 || status=$?
printf 'exit %s: %s\n' "$status" "$(grep -E '^=+ .* in [0-9.]+s' "$logs/nonroot-all.log" | tail -n 1)"
printf 'failures and errors: %s\n' "$(grep -cE '^(FAILED|ERROR) ' "$logs/nonroot-all.log" || true)"
grep -E '^(FAILED|ERROR) ' "$logs/nonroot-all.log" | cut -c1-160 || true
printf 'read-only or permission failures: %s\n' "$(grep -cE 'PermissionError|Permission denied|Read-only' "$logs/nonroot-all.log" || true)"
printf 'git status --short: %s lines\n' "$(as_user git status --short | wc -l)"

chown -R -h 0:0 "$clone"
