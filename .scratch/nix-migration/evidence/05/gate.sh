#!/bin/sh
# Ticket 05 evidence: `just check` or `just test-checkers-all` on the CI runner
# from the prototype environment setup.sh realised. Ticket 01's
# gate-scratch.patch is applied first, without its run_allium.py hunk: that
# hunk maps aarch64 Linux to the linux-64 pin, and the runner is x86_64, where
# tools.txt already has a pin. The patch stays uncommitted, as in ticket 01;
# the gate compares the worktree against its own baseline.
# Usage: sh gate.sh check | test-checkers-all
set -eu
recipe=${1:?usage: gate.sh check | test-checkers-all}
proto=./.scratch/nix-migration/evidence/01
log=${RUNNER_TEMP:-/tmp}/$recipe.log
since() { # start, as date +%s.%N printed it
  echo "$(date +%s.%N) $1" | awk '{ printf "%.1f", $1 - $2 }'
}

git apply --exclude=scripts/checks/run_allium.py "$proto/gate-scratch.patch"
printf 'gate-scratch.patch without its run_allium.py hunk; git status --short:\n'
git status --short | sed 's/^/  /'

just=./.pixi/envs/default/bin/just
# The ripsecrets tests copy .tools/bin/ripsecrets with shutil.copy2, which
# keeps the mode, and then write to the copy. Ticket 01 ran them as root.
printf 'uid %s; .tools/bin/ripsecrets is %s\n' "$(id -u)" \
  "$(stat -L -c '%A, owner %U' .tools/bin/ripsecrets) in $(readlink -f .tools/bin/ripsecrets | cut -c1-11)…"
start=$(date +%s.%N)
status=0
"$just" "$recipe" > "$log" 2>&1 || status=$?
printf '\njust %s: exit %s in %ss\n' "$recipe" "$status" "$(since "$start")"
echo "::group::the whole just $recipe log"
cat "$log"
echo '::endgroup::'
if [ "$recipe" = check ]; then
  grep -E '^==> just ' "$log" | tr '\n' ' ' || true
  printf '\n'
else
  grep -E '^=+ .* in [0-9.]+s' "$log" | tail -n 1 || true
  printf 'failures by file:\n'
  grep -E '^(FAILED|ERROR) ' "$log" | sed -E 's/^[A-Z]+ ([^:]+)::.*/\1/' | sort | uniq -c || echo '  none'
  printf 'skipped:\n'
  grep -E '^SKIPPED' "$log" | sed -E 's/^SKIPPED \[[0-9]+\] ([^:]+):[0-9]+: /\1: /' | sort | uniq -c || echo '  none'
fi
tail -n 1 "$log"
git status --short | sed 's/^/  /'
exit "$status"
