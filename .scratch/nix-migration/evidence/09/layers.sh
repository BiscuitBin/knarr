#!/bin/sh
# Ticket 09 evidence: which steps a source edit reruns in knarr's Nix image.
# After build.sh, in its staged context: append a comment to a source file and
# rebuild with plain progress, then restore the file and rebuild. Every step
# before `COPY src src`, the Nix builds and the closure's layout among them,
# and the final stage's copy of /out should be CACHED.
# Usage (Mac, from the repository root): sh .scratch/nix-migration/evidence/09/layers.sh > layers.txt
set -eu
root=$(git rev-parse --show-toplevel)
context=$root/ai_tmp/09/ctx-nix
platform=linux/$(docker version --format '{{.Server.Arch}}')
printf 'date: %s\ncontext: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git -C "$root" log -1 --format='%h %s')"
cp "$context/src/knarr.gleam" "$root/ai_tmp/09/source.bak"
echo "// ticket 09 layers probe $(date +%s)" >> "$context/src/knarr.gleam"
docker build --progress=plain --platform "$platform" --tag knarr-09:nix "$context" 2>&1 \
  | grep -E '^#[0-9]+ (\[(build|runtime) |CACHED|DONE)' | grep -v '^#[0-9]* DONE 0.0s$' \
  | sed -E 's/ {2,}/ /g; s/^#[0-9]+ //'
cp "$root/ai_tmp/09/source.bak" "$context/src/knarr.gleam"
docker build --quiet --platform "$platform" --tag knarr-09:nix "$context" > /dev/null
echo 'source restored and rebuilt'
