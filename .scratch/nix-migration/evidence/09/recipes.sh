#!/bin/sh
# Ticket 09 evidence: the four recipes the ticket names, run as a contributor
# runs them, from the worktree, after build.sh: `just image-build` and
# `just fake-worker-image-build` (into the tags check.sh used), then
# `just image-check` and `just fake-worker-image-check` on what they built.
# Usage (Mac, from the repository root): sh .scratch/nix-migration/evidence/09/recipes.sh > recipes.txt
set -eu
root=$(git rev-parse --show-toplevel)
log=$root/ai_tmp/09/recipes.log
cd "$root"
printf 'date: %s\nworktree at: %s, %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git log -1 --format='%h %s')" \
  "$(if git diff --quiet HEAD -- Dockerfile .dockerignore fixtures/fake_worker flake.nix flake.lock pins.toml gleam.toml manifest.toml src scripts/container-entrypoint.sh; then echo 'every admitted file as committed'; else echo 'admitted files differ from HEAD'; fi)"
run() {
  status=0
  start=$(date +%s)
  just "$@" > "$log" 2>&1 || status=$?
  printf '\n$ just %s\nexit %s after %s seconds\n' "$*" "$status" "$(($(date +%s) - start))"
  grep -E '^(image: |tls_check: |RuntimeError|error: )|naming to ' "$log" | sed 's/^#[0-9]* /  /; s/^/  /' || true
}
run image-build knarr-09:nix
run fake-worker-image-build fake-worker-09:nix
run image-check knarr-09:nix
run fake-worker-image-check fake-worker-09:nix
