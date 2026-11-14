#!/bin/sh
# Ticket 09 evidence: both images built from the flake, against the pixi
# images of the commit this ticket started from, on the same machine and day.
# Each build context is `git archive` of a commit, so nothing uncommitted and
# nothing outside the allowlists reaches it. For each image and each backend:
# a cold build (--no-cache: every Nix path, conda package, hex package and the
# rebar3 asset fetched again; the base images are already pulled), a warm one
# with nothing changed, and one after an edit under src/.
# Usage (Mac, from the repository root): sh .scratch/nix-migration/evidence/09/build.sh [nix-rev] > build.txt
#   Needs Docker and the network. Leaves the images knarr-09:pixi, knarr-09:nix,
#   fake-worker-09:pixi and fake-worker-09:nix, and their contexts under ai_tmp/09/.
set -eu
root=$(git rev-parse --show-toplevel)
pixi_rev=da7fd81
nix_rev=${1:-HEAD}
work=$root/ai_tmp/09
platform=linux/$(docker version --format '{{.Server.Arch}}')

stage() { # name, rev
  rm -rf "${work:?}/ctx-$1"
  mkdir -p "$work/ctx-$1"
  git -C "$root" archive "$2" | tar -x -C "$work/ctx-$1"
}
build() { # label, dockerfile, tag, context, extra flags...
  label=$1 dockerfile=$2 tag=$3 context=$4
  shift 4
  start=$(date +%s)
  docker build --quiet --platform "$platform" --file "$context/$dockerfile" --tag "$tag" "$@" "$context" > /dev/null
  printf '  %-34s %4s seconds\n' "$label" "$(($(date +%s) - start))"
}
megabytes() { awk '{ printf "%.1f MB", $1 / 1000000 }'; }

printf 'date: %s\ndocker: %s, %s\nhost: %s cores, shared with ticket 08 running concurrently\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" "$(docker version --format '{{.Server.Version}}')" "$platform" "$(sysctl -n hw.ncpu 2> /dev/null || nproc)"
stage pixi "$pixi_rev"
stage nix "$nix_rev"
printf 'pixi: %s\nnix:  %s\n' "$(git -C "$root" log -1 --format='%h %s' "$pixi_rev")" "$(git -C "$root" log -1 --format='%h %s' "$nix_rev")"

for backend in pixi nix; do
  context=$work/ctx-$backend
  for image in knarr fake-worker; do
    if [ "$image" = knarr ]; then
      dockerfile=Dockerfile source=src/knarr.gleam
    else
      dockerfile=fixtures/fake_worker/Dockerfile source=fixtures/fake_worker/src/fake_worker.gleam
    fi
    tag=$image-09:$backend
    printf '\n== %s, %s (%s)\n' "$image" "$backend" "$dockerfile"
    grep '^FROM ' "$context/$dockerfile" | sed 's/^/  /'
    build 'cold (--no-cache)' "$dockerfile" "$tag" "$context" --no-cache
    build 'warm (nothing changed)' "$dockerfile" "$tag" "$context"
    cp "$context/$source" "$work/source.bak"
    echo "// ticket 09 probe $(date +%s)" >> "$context/$source"
    build 'after an edit under src/' "$dockerfile" "$tag" "$context"
    cp "$work/source.bak" "$context/$source"
    build 'source restored' "$dockerfile" "$tag" "$context"
    printf '  size (docker image inspect .Size): %s\n' "$(docker image inspect "$tag" --format '{{.Size}}' | megabytes)"
    printf '  architecture %s, user %s\n' "$(docker image inspect "$tag" --format '{{.Architecture}}')" \
      "$(docker image inspect "$tag" --format '{{.Config.User}}')"
  done
done
