#!/bin/sh
# Ticket 05 evidence: ticket 01's prototype image on the CI runner, for
# linux/amd64. The two base images are pulled first and timed, because ticket
# 01's image.sh times its builds with both already pulled; then image.sh runs
# unchanged: four builds (--no-cache, nothing changed, a source edit, the
# source restored), the closure, image-check's docker run restrictions, the six
# TLS cases, readiness and metrics, and image.py where it stops. The build
# stage cannot see the runner's /nix, so every CI build of it fetches the
# closure again, whatever the runner's store cache holds.
# Usage: sh image.sh   (at the repository root, after setup.sh default)
set -eu
here=./.scratch/nix-migration/evidence/01
since() { # start, as date +%s.%N printed it
  echo "$(date +%s.%N) $1" | awk '{ printf "%.1f", $1 - $2 }'
}
mkdir -p ai_tmp/out
sed -n 's/^FROM \([^ ]*\).*/\1/p' "$here/image/Dockerfile" | while read -r base; do
  start=$(date +%s.%N)
  docker pull --quiet --platform linux/amd64 "$base" > /dev/null
  printf 'docker pull %s: %ss\n' "${base%%@*}" "$(since "$start")"
done
start=$(date +%s.%N)
sh "$here/image.sh"
printf '\nimage.sh, all of it: %ss\n' "$(since "$start")"
