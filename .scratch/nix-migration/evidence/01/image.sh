#!/bin/sh
# Ticket 01 evidence: the prototype image. Built by the host's docker build
# from image/Dockerfile, for the host's architecture, then checked the way
# `just image-check` checks today's image: the same docker run restrictions
# scripts/checks/image.py puts in `common`, the same OTP comparison, the same
# TLS script on the image's own Erlang and OpenSSL, and the same readiness and
# metrics probe. image.py itself is run last, to record where it stops.
# Usage: sh image.sh [baseline-image] > image.txt   (needs Docker and the network)
#   The baseline is today's image, already pulled or built, whose size is
#   printed beside the prototype's: ghcr.io/biscuitbin/knarr:0.3.1 here.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
image=knarr-nix-proto:01
baseline=${1:-}
context=$root/ai_tmp/image-context
prefix=/opt/knarr/runtime

# The staged context: the root .dockerignore is an allowlist that leaves the
# evidence directory out, and a context has no .git.
rm -rf "${context:?}"
mkdir -p "$context/scripts"
cp "$here/flake.nix" "$here/flake.lock" "$root/gleam.toml" "$root/manifest.toml" "$context/"
cp -R "$root/src" "$context/"
cp "$root/scripts/container-entrypoint.sh" "$context/scripts/"

build() { # label, extra docker build flags...
  label=$1
  shift
  start=$(date +%s)
  docker build --quiet --platform "$platform" --file "$here/image/Dockerfile" --tag "$image" "$@" "$context" > /dev/null
  printf '%-52s %4s seconds\n' "$label" "$(($(date +%s) - start))"
}
# tls_check.escript prints each whole Erlang term; keep the verdict and its head.
trim() {
  sed -E 's/(got \{ok,\[\{protocol,[^}]*\}).*/\1, .../; s/(got \{error,\{tls_alert,\{[a-z_]*,).*/\1 .../'
}
megabytes() { echo "$1" | awk '{ printf "%.1f MB", $1 / 1000000 }'; }

platform=linux/$(docker version --format '{{.Server.Arch}}')
printf 'date: %s\ndocker: %s, %s\ncontext: %s files, %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
  "$(docker version --format '{{.Server.Version}}')" "$platform" \
  "$(find "$context" -type f | wc -l | tr -d ' ')" "$(du -sh "$context" | cut -f1)"

printf '\n== Build times (both base images already pulled)\n'
build 'cold (--no-cache: every Nix path fetched again)' --no-cache
build 'warm (nothing changed)'
echo "// ticket 01 probe $(date +%s)" >> "$context/src/knarr.gleam"
build 'after an edit under src/ (flake layers cached)'
cp "$root/src/knarr.gleam" "$context/src/knarr.gleam"
build 'source restored'

printf '\n== The image\n'
docker image inspect "$image" --format 'architecture {{.Architecture}}, user {{.Config.User}}, entrypoint {{json .Config.Entrypoint}}'
printf 'size (docker image inspect .Size): %s\n' "$(megabytes "$(docker image inspect "$image" --format '{{.Size}}')")"
printf 'size (docker images):              %s\n' "$(docker images --format '{{.Size}}' "$image")"
if [ -n "$baseline" ]; then
  printf 'baseline %s (%s):\n' "$baseline" "$(docker image inspect "$baseline" --format '{{.Architecture}}')"
  printf '  size (docker image inspect .Size): %s\n' "$(megabytes "$(docker image inspect "$baseline" --format '{{.Size}}')")"
  printf '  size (docker images):              %s\n' "$(docker images --format '{{.Size}}' "$baseline")"
  printf '  its runtime environment: %s\n' "$(docker run --rm --pull=never --platform="linux/$(docker image inspect "$baseline" --format '{{.Architecture}}')" --entrypoint=du "$baseline" -sh /opt/knarr/.pixi/envs/runtime | cut -f1)"
fi
printf 'layers of the final stage:\n'
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' "$image" | cut -c1-110 | sed 's/^/  /'

printf '\n== The runtime closure in the image\n'
docker run --rm --pull=never --entrypoint=sh "$image" -c "
  printf '%s -> %s\n' $prefix \"\$(readlink $prefix)\"
  printf '%s store paths, %s under /nix/store\n' \"\$(wc -l < /opt/knarr/runtime-closure.txt)\" \"\$(du -sh /nix/store | cut -f1)\"
  sed 's,^/nix/store/[a-z0-9]*-,  ,' /opt/knarr/runtime-closure.txt | sort | tr '\n' ' '
  printf '\nperl in the closure: %s\n' \"\$(grep -c -- '-perl' /opt/knarr/runtime-closure.txt)\"
  printf 'perl files under /nix/store: %s\n' \"\$(find /nix/store -name 'perl*' | wc -l)\"
  printf 'bin: %s\n' \"\$(ls $prefix/bin | tr '\n' ' ')\"
  printf 'largest paths:\n'; du -s /nix/store/* | sort -rn | head -n 5 | sed 's,/nix/store/[a-z0-9]*-,,' | awk '{ printf \"  %6.1f MB  %s\n\", \$1 / 1024, \$2 }'
  printf 'shipment: %s\n' \"\$(du -sh /opt/knarr/shipment | cut -f1)\"
"

# What image.py computes: the chart's memory limit, in bytes.
limit=$(sed -n '/^resources:/,/^[a-z]/p' "$root/charts/knarr/values.yaml" | sed -n '/^  limits:/,$p' | sed -n 's/^    memory: *\([0-9]*\)Mi.*/\1/p' | head -n 1)
budget=$((limit * 1024 * 1024))
restricted() { # extra docker run arguments..., then the image's command
  docker run --pull=never --platform="$platform" --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --tmpfs=/tmp:rw,noexec,nosuid,size=16m \
    --memory="$budget" --memory-swap="$budget" "$@"
}
printf '\n== image-check'"'"'s restrictions, applied by hand\n'
printf 'docker run --pull=never --platform=%s --read-only --cap-drop=ALL --security-opt=no-new-privileges\n' "$platform"
printf '  --tmpfs=/tmp:rw,noexec,nosuid,size=16m --memory=%s --memory-swap=%s (the chart limit, %sMi)\n' "$budget" "$budget" "$limit"
printf 'ulimit -Sn through the entrypoint: %s\n' \
  "$(restricted --rm --ulimit=nofile=131072:131072 --entrypoint=/opt/knarr/container-entrypoint.sh "$image" sh -c 'ulimit -Sn')"
printf 'OTP: build stage %s, runtime %s\n' "$(restricted --rm --entrypoint=cat "$image" /opt/build-otp)" \
  "$(restricted --rm --entrypoint=erl "$image" -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().')"
printf 'id: %s\n' "$(restricted --rm --entrypoint=id "$image")"

printf '\n== The six TLS cases (bootstrap ticket 01'"'"'s tls/run.sh) on the image'"'"'s Erlang and OpenSSL\n'
restricted --rm --volume="$root/.scratch/bootstrap/evidence/01/tls":/opt/tls-check:ro --entrypoint=sh \
  "$image" /opt/tls-check/run.sh "$prefix" /tmp/tls 2>&1 | trim

printf '\n== The restricted container starts and serves\n'
container=$(restricted --ulimit=nofile=131072:131072 --detach --publish=127.0.0.1::8080 "$image")
port=$(docker port "$container" 8080/tcp | sed 's/.*://')
ready=
for attempt in $(seq 1 120); do
  ready=$(curl --noproxy '*' --fail --silent --max-time 2 "http://127.0.0.1:$port/readyz" || true)
  [ "$ready" != ok ] || break
  sleep 0.25
done
printf '/readyz: %s (after %s probes)\n' "$ready" "$attempt"
printf '/metrics: %s\n' "$(curl --noproxy '*' --fail --silent --max-time 5 "http://127.0.0.1:$port/metrics" | grep '^knarr_startups_total')"
docker stats --no-stream --format 'memory usage / limit: {{.MemUsage}}' "$container"
docker rm --force "$container" > /dev/null
[ "$ready" = ok ]

printf '\n== scripts/checks/image.py on this image, unchanged\n'
status=0
(cd "$root" && sh scripts/with-env.sh python3 scripts/checks/image.py "$image") > "$root/ai_tmp/out/image-check.log" 2>&1 || status=$?
printf 'exit %s\n' "$status"
grep -E '^no conda-meta|^RuntimeError|verified' "$root/ai_tmp/out/image-check.log" | cut -c1-160 | sed 's/^/  /'
