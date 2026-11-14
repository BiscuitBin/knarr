#!/bin/sh
# Ticket 01 evidence: today's image, built for the host's architecture, as the
# size and build time the prototype image is compared with. The context is a
# clean export of HEAD (git archive), so no scratch or ignored file can reach
# it; the tracked .dockerignore then applies as it does to `just image-build`.
# The build fetches conda packages, hex packages and rebar3 (needs network).
# Usage: sh baseline.sh > baseline.txt
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
image=knarr-nix-proto:pixi-baseline
context=$root/ai_tmp/baseline-context
rm -rf "${context:?}"
mkdir -p "$context"
git -C "$root" archive HEAD | tar -x -C "$context"
platform=linux/$(docker version --format '{{.Server.Arch}}')
printf 'date: %s\ndocker: %s, %s\nHEAD: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
  "$(docker version --format '{{.Server.Version}}')" "$platform" "$(git -C "$root" rev-parse --short HEAD)"

# Pull both base images first, so the cold time is the build alone, as the
# prototype's is.
sed -n 's/^FROM \([^ ]*\).*/\1/p' "$context/Dockerfile" | while read -r base; do
  docker pull --quiet --platform "$platform" "$base" > /dev/null
  printf 'base: %s\n' "$base"
done

build() { # label, extra docker build flags...
  label=$1
  shift
  start=$(date +%s)
  docker build --quiet --platform "$platform" --tag "$image" "$@" "$context" > /dev/null
  printf '%-44s %4s seconds\n' "$label" "$(($(date +%s) - start))"
}
printf '\n== Build times (both base images already pulled)\n'
build 'cold (--no-cache)' --no-cache
build 'warm (nothing changed)'
echo "// ticket 01 probe $(date +%s)" >> "$context/src/knarr.gleam"
build 'after an edit under src/'

printf '\n== The image\n'
docker image inspect "$image" --format 'architecture {{.Architecture}}, user {{.Config.User}}'
printf 'size (docker image inspect .Size): %s\n' "$(docker image inspect "$image" --format '{{.Size}}' | awk '{ printf "%.1f MB", $1 / 1000000 }')"
printf 'size (docker images):              %s\n' "$(docker images --format '{{.Size}}' "$image")"
docker run --rm --pull=never --entrypoint=sh "$image" -c '
  printf "runtime environment: %s\n" "$(du -sh /opt/knarr/.pixi/envs/runtime | cut -f1)"
  printf "  lib/erlang: %s\n" "$(du -sh /opt/knarr/.pixi/envs/runtime/lib/erlang | cut -f1)"
  printf "shipment: %s\n" "$(du -sh /opt/knarr/shipment | cut -f1)"
  erl -noshell -eval "io:format(\"otp_release ~s, erts ~s, ~p~n\", [erlang:system_info(otp_release), erlang:system_info(version), crypto:info_lib()]), halt()."'
printf 'layers of the final stage:\n'
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' "$image" | cut -c1-110 | sed -n '1,10p' | sed 's/^/  /'
