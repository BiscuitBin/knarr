#!/bin/sh
# Ticket 01 evidence: the gate from a PATH prefix, with the network off.
# It runs on the stand-in host (host.sh), in the clone gate-setup.sh prepared:
# .pixi/envs/default is the prototype environment's out-link and .tools/bin a
# link to its bin, so the directories every recipe and hook already prefixes
# hold the Nix tools and nothing else. No tracked file differs until part 6.
# Usage (host): sh host.sh --offline sh /evidence/gate.sh > gate.txt
set -eu
clone=/work/gate/clone
proto=./.scratch/nix-migration/evidence/01
cd "$clone"
git checkout --quiet .
tools=$clone/.pixi/envs/default
just=$tools/bin/just
mkdir -p /work/gate/logs
logs=/work/gate/logs

seconds() { # start, as date +%s.%N printed it
  echo "$(date +%s.%N) $1" | awk '{ printf "%.2f", $1 - $2 }'
}
recipe() { # name: run it through just, print pass or fail and the time
  start=$(date +%s.%N)
  status=0
  "$just" "$1" > "$logs/$1.log" 2>&1 || status=$?
  if [ "$status" = 0 ]; then verdict=pass; else verdict="FAIL (exit $status)"; fi
  printf '%-22s %-16s %7ss\n' "$1" "$verdict" "$(seconds "$start")"
}

# shellcheck disable=SC1091 # the stand-in host's own file
. /etc/os-release
printf 'date: %s\nhost: %s, %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$PRETTY_NAME"
printf '%s\nPATH: %s\n' "$(nix --version)" "$PATH"
if getent hosts cache.nixos.org > /dev/null 2>&1; then echo 'network: ON (unexpected)'; else echo 'network: off'; fi
printf 'clone: %s at %s, git status --short: %s lines\n' "$(git branch --show-current)" "$(git rev-parse --short HEAD)" "$(git status --short | wc -l)"
printf '.pixi/envs/default -> %s\n.tools/bin -> %s\n' "$(readlink .pixi/envs/default)" "$(readlink .tools/bin)"
printf 'on this host without the prefix: python3 %s, node %s, perl %s, sed %s\n' \
  "$(command -v python3 || echo absent)" "$(command -v node || echo absent)" "$(command -v perl)" "$(command -v sed)"

printf '\n== 1. The checker tests run through the interpreter'"'"'s own pytest\n'
PATH=$tools/bin:$PATH python3 -c 'import sys, pytest; print("sys.executable", sys.executable); print("pytest", pytest.__version__, "from", pytest.__file__)'
recipe test-checkers
tail -n 1 "$logs/test-checkers.log"
recipe test-checkers-all
grep -E '^=+ .* in [0-9.]+s' "$logs/test-checkers-all.log" | tail -n 1
printf 'failures by file:\n'
grep -E '^(FAILED|ERROR) ' "$logs/test-checkers-all.log" | sed -E 's/^[A-Z]+ ([^:]+)::.*/\1/' | sort | uniq -c
printf 'the reason in each file:\n'
grep -E -m 1 'Markdown parser unavailable' "$logs/test-checkers-all.log" | cut -c1-150
grep -E -m 1 'tools.txt pins no Allium' "$logs/test-checkers-all.log"
printf 'skipped: %s\n' "$(grep -E '^SKIPPED' "$logs/test-checkers-all.log" | sed -E 's/^SKIPPED \[[0-9]+\] ([^:]+):[0-9]+: /\1: /' | sort | uniq -c | sed 's/^ *//')"

printf '\n== 2. The docs checker'"'"'s Node and markdownlint-cli2'"'"'s bundled markdown-it\n'
recipe docs-check
cut -c1-100 "$logs/docs-check.log" | grep 'docs validation'
printf 'bin/markdownlint-cli2 is %s:\n' "$(readlink -f "$tools/bin/markdownlint-cli2")"
sed -n 2p "$tools/bin/markdownlint-cli2" | sed 's/^/  /'
printf 'the checker'"'"'s command, node render_markdown.mjs <prefix>/bin/markdownlint-cli2:\n'
printf '%s\n' '{"a.md":"# Heading\n"}' | "$tools/bin/node" scripts/checks/render_markdown.mjs "$tools/bin/markdownlint-cli2" 2>&1 |
  grep -E "^Error|code:" | sed 's/^/  /' || true
module=$tools/lib/node_modules/markdownlint-cli2
printf 'the same with <prefix>/lib/node_modules/markdownlint-cli2/markdownlint-cli2-bin.mjs:\n  '
printf '%s\n' '{"a.md":"# Heading\n"}' | "$tools/bin/node" scripts/checks/render_markdown.mjs "$module/markdownlint-cli2-bin.mjs"
printf '\nmarkdown-it %s, markdownlint %s, node %s\n' \
  "$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$module/node_modules/markdown-it/package.json")" \
  "$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$module/node_modules/markdownlint/package.json")" "$("$tools/bin/node" --version)"

printf '\n== 3. The path prek writes into the git hook, and a lock move\n'
locked=$(readlink .pixi/envs/default)
moved=$(readlink /work/gate/moved)
PATH=$tools/bin:$PATH sh scripts/install-hooks.sh 2>&1 | sed 's/^/  /'
grep '^PREK=' .git/hooks/pre-commit | sed 's/^/  /'
hooked=$(sed -n 's/^PREK="\(.*\)"$/\1/p' .git/hooks/pre-commit)
commit() { # label: make an empty commit through the hook, then take it back
  status=0
  git commit --quiet --allow-empty -m 'hook probe' > "$logs/commit.log" 2>&1 || status=$?
  printf '%s: git commit exit %s %s\n' "$1" "$status" "$(grep -E 'not found|No such file' "$logs/commit.log" | head -n 1)"
  [ "$status" != 0 ] || git reset --quiet --soft HEAD~1
}
commit 'locked environment'
printf 'the lock moves: the out-link now names %s\n' "$moved"
ln -sfn "$moved" .pixi/envs/default
printf '  the prefix has  %s (%s)\n' "$(readlink -f .pixi/envs/default/bin/prek)" "$(.pixi/envs/default/bin/prek --version)"
printf '  the hook runs   %s (%s)\n' "$hooked" "$("$hooked" --version)"
commit 'after the move, old store path still present'
printf 'after garbage collection the old path is gone; simulated by renaming it in a copy of the hook:\n'
sed "s,^PREK=.*,PREK=\"${hooked%/bin/prek}-collected/bin/prek\"," .git/hooks/pre-commit > /work/gate/hook-collected
cp .git/hooks/pre-commit /work/gate/hook-installed
cp /work/gate/hook-collected .git/hooks/pre-commit
commit '  hook naming a collected path'
printf 'with the out-link written into the hook instead:\n'
sed "s,^PREK=.*,PREK=\"$clone/.pixi/envs/default/bin/prek\"," /work/gate/hook-installed > .git/hooks/pre-commit
grep '^PREK=' .git/hooks/pre-commit | sed 's/^/  /'
commit '  moved environment'
ln -sfn "$locked" .pixi/envs/default
commit '  locked environment again'

printf '\n== 4. The gate, every recipe of just check on its own, tracked files untouched\n'
for name in lock-check env-check manifest-check docs-check agents-check check-specs analyse-specs \
  format-check lint-gleam test snapshots-check fake-worker-lint fake-worker-test test-checkers \
  packaging-check chart-check toml-check lint; do
  recipe "$name"
done
printf 'why each one failed:\n'
for name in lock-check env-check docs-check check-specs analyse-specs; do
  printf '  %-14s %s\n' "$name" "$(grep -E 'not found|is missing|unavailable|pins no' "$logs/$name.log" | head -n 1 | cut -c1-120)"
done
printf 'git status --short after them: %s lines\n' "$(git status --short | wc -l)"
printf 'just check itself stops at the first:\n'
status=0
"$just" check > "$logs/check-unpatched.log" 2>&1 || status=$?
printf '  exit %s: %s\n' "$status" "$(grep -E 'not found' "$logs/check-unpatched.log" | head -n 1)"

printf '\n== 5. The Nix lock and environment checks: time, and what they write\n'
stored=$(find /nix/store -maxdepth 1 | wc -l)
touch /work/gate/mark
for run in 1 2 3; do
  start=$(date +%s.%N)
  nix flake lock --no-update-lock-file --offline "$proto" 2> /dev/null
  lock=$(seconds "$start")
  start=$(date +%s.%N)
  sh "$proto/env-check.sh" "$proto" .pixi/envs/default > "$logs/env-check-nix.log" 2>&1
  printf 'run %s: lock check %ss, environment check %ss\n' "$run" "$lock" "$(seconds "$start")"
done
tail -n 1 "$logs/env-check-nix.log"
printf 'git status --short: %s lines; new store paths: %s\n' "$(git status --short | wc -l)" "$(($(find /nix/store -maxdepth 1 | wc -l) - stored))"
printf 'files written outside the clone: %s\n' "$(find "$HOME" /tmp -type f -newer /work/gate/mark 2> /dev/null | sed "s,^$HOME/,~/," | tr '\n' ' ')"
printf 'a drifted environment is refused:\n'
ln -sfn "$moved" .pixi/envs/default
status=0
sh "$proto/env-check.sh" "$proto" .pixi/envs/default > "$logs/env-check-drift.log" 2>&1 || status=$?
printf '  exit %s: %s\n' "$status" "$(grep '^env-check' "$logs/env-check-drift.log" | cut -c1-200)"
ln -sfn "$locked" .pixi/envs/default

printf '\n== 6. The whole gate, with the scratch patch for the pixi-shaped parts\n'
git apply /evidence/gate-scratch.patch
git status --short
start=$(date +%s.%N)
status=0
"$just" check > "$logs/check.log" 2>&1 || status=$?
printf 'just check: exit %s in %ss\n' "$status" "$(seconds "$start")"
grep -E '^==> just ' "$logs/check.log" | tr '\n' ' '
printf '\n'
tail -n 1 "$logs/check.log"
git status --short
recipe test-checkers-all
grep -E '^=+ .* in [0-9.]+s' "$logs/test-checkers-all.log" | tail -n 1
git checkout --quiet .
printf 'git status --short after removing the patch: %s lines\n' "$(git status --short | wc -l)"
