#!/bin/sh
# Ticket 37 evidence: the published digest, pulled by a Docker daemon that
# never built the image, never pulled it and holds no credentials. That daemon
# is a fresh docker:29.4.0-dind container, started here and removed at exit;
# its image store starts empty, so every layer comes from ghcr.io. The host is
# arm64 and the image amd64 only (Decision 0012), so the pull names the
# platform, and nothing runs the image. Inspect then shows the labels
# release.yml set. Needs docker:29.4.0-dind on the host already: pulling it
# from Docker Hub is its own authorized step. Exits non-zero on any unexpected
# result.
# Usage: sh pull.sh <sha256:digest> <commit> > pull.txt 2>&1
set -eu
usage='usage: pull.sh <sha256:digest> <commit>'
digest=${1:?$usage}
commit=${2:?$usage}
image=ghcr.io/steven-cutting/knarr
dind=docker:29.4.0-dind
name=knarr37-pull-$$
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
inner() { docker exec "$name" "$@"; }
trap 'docker rm -fv "$name" > /dev/null 2>&1 || true' EXIT
printf 'date: %s\nimage: %s@%s\ncommit: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$image" "$digest" "$commit"
v=$(docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}') || fail 'the host daemon did not answer'
printf 'host daemon: %s\n' "$v"
v=$(docker image inspect --format '{{.Id}} {{join .RepoDigests ","}}' "$dind") || fail "$dind is not on the host"
printf '%s: %s\n' "$dind" "$v"

echo; echo "== a fresh daemon: docker run -d --privileged $dind"
docker run -d --privileged --name "$name" "$dind" > /dev/null || fail 'starting dind failed'
i=0
until inner docker info > /dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'the inner daemon did not start in 60 s'
  sleep 1
done
v=$(inner docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}') || fail 'the inner daemon did not answer'
printf 'inner daemon: %s, up after %s s\n' "$v" "$i"
# Each list is read first and counted after, so a failed command fails here
# instead of counting as an empty list.
out=$(inner docker images -q) || fail 'listing inner images failed'
v=$(printf '%s' "$out" | grep -c . || true)
expect 'inner images before the pull' "$v" 0
# shellcheck disable=SC2016  # expanded by the inner shell, not this one
v=$(inner sh -c 'ls -A "${DOCKER_CONFIG:-$HOME/.docker}" 2> /dev/null | wc -l | tr -d " "') || fail 'reading the inner docker config failed'
expect 'inner docker config files (no credentials)' "$v" 0

echo; echo "== docker pull --platform linux/amd64 $image@$digest"
inner docker pull --platform linux/amd64 "$image@$digest" || fail 'the pull failed'

echo; echo '== docker image inspect'
v=$(inner docker image inspect --format '{{json .Config.Labels}}' "$image@$digest") || fail 'inspect failed'
printf 'labels: %s\n' "$v"
label() { inner docker image inspect --format "{{index .Config.Labels \"org.opencontainers.image.$1\"}}" "$image@$digest"; }
v=$(label version) || fail 'inspect failed'
expect 'org.opencontainers.image.version' "$v" 0.1.0
v=$(label revision) || fail 'inspect failed'
expect 'org.opencontainers.image.revision' "$v" "$commit"
v=$(label source) || fail 'inspect failed'
expect 'org.opencontainers.image.source' "$v" https://github.com/steven-cutting/knarr
v=$(label created) || fail 'inspect failed'
printf 'info org.opencontainers.image.created: %s\n' "$v"
v=$(inner docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image@$digest") || fail 'inspect failed'
expect 'platform' "$v" linux/amd64
v=$(inner docker image inspect --format '{{join .RepoDigests ","}}' "$image@$digest") || fail 'inspect failed'
expect 'repo digests' "$v" "$image@$digest"
inner docker images --digests

echo; echo "== docker rm -fv"
docker rm -fv "$name" > /dev/null || fail 'removing the container failed'
out=$(docker ps -aq --filter "name=^$name\$") || fail 'listing containers failed'
v=$(printf '%s' "$out" | grep -c . || true)
expect 'containers left' "$v" 0
echo; echo 'pulled by digest on a daemon that never built it; labels match 0.1.0 and the tagged commit'
