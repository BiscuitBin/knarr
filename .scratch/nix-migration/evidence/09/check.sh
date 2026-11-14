#!/bin/sh
# Ticket 09 evidence: the images build.sh made from the flake, checked.
#   1. `just image-check` and `just fake-worker-image-check`, unchanged
#      recipes: the numeric user, the descriptor cap, the OTP comparison with
#      pins.toml, the read-only run with every capability dropped, and for
#      knarr the TLS rerun with the shipped runtime's erlang and openssl.
#   2. The whole OTP version, not only the major image-check compares, in the
#      build stage and in each image, beside pins.toml's, and the store path
#      each runs it from.
#   3. What the runtime closure holds: its store paths, no perl, and the
#      OpenSSL the TLS rerun used.
# Usage (Mac, from the repository root): sh .scratch/nix-migration/evidence/09/check.sh > check.txt
#   Needs Docker and the images build.sh left; pulls nothing.
# The single-quoted scripts run in the image's own shell, which expands them.
# shellcheck disable=SC2016
set -eu
root=$(git rev-parse --show-toplevel)
work=$root/ai_tmp/09
platform=linux/$(docker version --format '{{.Server.Arch}}')
cd "$root"
otp_version='{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:put_chars(V), halt().'
restricted() { # image, entrypoint, arguments...
  image=$1 entrypoint=$2
  shift 2
  docker run --pull=never --platform "$platform" --read-only --cap-drop=ALL --security-opt=no-new-privileges \
    --tmpfs=/tmp:rw,noexec,nosuid,size=16m --rm --entrypoint="$entrypoint" "$image" "$@"
}
# tls_check.escript prints each whole Erlang term; keep the verdict and its head.
trim() {
  sed -E 's/(got \{ok,\[\{protocol,[^}]*\}).*/\1, .../; s/(got \{error,\{tls_alert,\{[a-z_]*,).*/\1 .../'
}

printf 'date: %s\ndocker: %s, %s\nbranch at: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
  "$(docker version --format '{{.Server.Version}}')" "$platform" "$(git log -1 --format='%h %s')"

printf '\n== 1. just image-check knarr-09:nix\n'
status=0
just image-check knarr-09:nix > "$work/image-check.log" 2>&1 || status=$?
trim < "$work/image-check.log" | grep -vE '^python3 ' | sed 's/^/  /'
printf '  exit %s\n' "$status"

printf '\n== 1. just fake-worker-image-check fake-worker-09:nix\n'
status=0
just fake-worker-image-check fake-worker-09:nix > "$work/fake-worker-image-check.log" 2>&1 || status=$?
grep -E '^(image: |memory usage|RuntimeError|Traceback)' "$work/fake-worker-image-check.log" | sed 's/^/  /' || true
printf '  exit %s\n' "$status"

printf '\n== 2. The OTP version\n'
printf '  pins.toml [exact] erlang: %s\n' "$(sed -n 's/^erlang = "\(.*\)"$/\1/p' pins.toml)"
for image in knarr fake-worker; do
  if [ "$image" = knarr ]; then dockerfile=Dockerfile; else dockerfile=fixtures/fake_worker/Dockerfile; fi
  docker build --quiet --platform "$platform" --file "$work/ctx-nix/$dockerfile" --target build \
    --tag "$image-09:nix-build" "$work/ctx-nix" > /dev/null
  printf '  %s build stage: OTP %s, /opt/build-otp %s, erl from %s\n' "$image" \
    "$(docker run --rm --pull=never "$image-09:nix-build" erl -noshell -eval "$otp_version")" \
    "$(docker run --rm --pull=never "$image-09:nix-build" cat /opt/build-otp)" \
    "$(docker run --rm --pull=never "$image-09:nix-build" sh -c 'readlink -f "$(command -v erl)"')"
  printf '  %s image:       OTP %s, /opt/build-otp %s, erl from %s\n' "$image" \
    "$(restricted "$image-09:nix" erl -noshell -eval "$otp_version")" \
    "$(restricted "$image-09:nix" cat /opt/build-otp)" \
    "$(restricted "$image-09:nix" sh -c 'readlink -f "$(command -v erl)"')"
done

printf '\n== 3. The runtime closure in knarr-09:nix\n'
restricted knarr-09:nix sh -c '
  printf "  /opt/knarr/runtime -> %s\n" "$(readlink /opt/knarr/runtime)"
  printf "  PATH=%s\n" "$PATH"
  printf "  bin: %s\n" "$(ls /opt/knarr/runtime/bin | tr "\n" " ")"
  printf "  openssl: %s\n" "$(openssl version)"
  printf "  crypto:info_lib(): %s\n" "$(erl -noshell -eval "io:format(\"~p\", [crypto:info_lib()]), halt().")"
  printf "  store paths under /nix/store: %s (du -sh %s)\n" "$(ls /nix/store | wc -l)" "$(du -sh /nix/store | cut -f1)"
  ls /nix/store | sed "s/^[a-z0-9]*-/    /" | sort
  printf "  perl in the store: %s\n" "$(find /nix/store -maxdepth 1 -name "*perl*" | wc -l)"
  printf "  files named perl* under /nix/store: %s\n" "$(find /nix/store -name "perl*" | wc -l)"
  printf "  files under /opt/knarr outside the shipment: %s\n" "$(ls /opt/knarr | tr "\n" " ")"
'
printf '  the same store paths in fake-worker-09:nix: '
if [ "$(restricted knarr-09:nix sh -c 'ls /nix/store')" = "$(restricted fake-worker-09:nix sh -c 'ls /nix/store')" ]; then
  echo yes
else
  echo no
fi
