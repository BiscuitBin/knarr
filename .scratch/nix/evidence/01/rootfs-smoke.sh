#!/bin/sh
# Decision 0017 evidence: what `just image-check` asks of knarr's image, asked
# of the root filesystem the flake builds, in a chroot and without Docker. It
# copies the rootfs, adds what a container runtime adds (/tmp, /proc, /dev and
# an /etc/hosts), and runs every command as uid 10001 with the image's
# environment. Needs root on Linux and a private mount namespace:
#   nix build --no-update-lock-file --out-link result .#knarr-rootfs
#   unshare --mount sh .scratch/nix/evidence/01/rootfs-smoke.sh result "$PWD"
set -eu
rootfs=${1:?usage: rootfs-smoke.sh <rootfs> <repository>}
repository=${2:?usage: rootfs-smoke.sh <rootfs> <repository>}
root=$(mktemp -d)
cp -a "$rootfs/." "$root/"
chmod u+w "$root" "$root/opt" "$root/etc"
mkdir -p "$root/proc" "$root/dev" "$root/opt/tls-check"
mkdir -m 1777 "$root/tmp"
printf '127.0.0.1 localhost\n' > "$root/etc/hosts"
mount -t proc proc "$root/proc"
mount --rbind /dev "$root/dev"
mount --bind -o ro "$repository/.scratch/bootstrap/evidence/01/tls" "$root/opt/tls-check"

inside() {
  chroot --userspec=10001:10001 "$root" \
    /usr/bin/env -i PATH=/bin HOME=/ ERL_CRASH_DUMP=/tmp/erl_crash.dump "$@"
}

printf 'date: %s\nhost: %s\nrootfs: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$(readlink -f "$rootfs")"
printf 'store paths: %s\n' "$(find "$root/nix/store" -mindepth 1 -maxdepth 1 | wc -l)"
printf 'size: %s\n' "$(du -sh "$root" 2> /dev/null | cut -f1)"
printf 'descriptor limit through the wrapper: %s\n' \
  "$(inside /opt/knarr/container-entrypoint.sh sh -c 'ulimit -Sn')"
printf 'build-otp: %s\n' "$(inside cat /opt/build-otp)"
printf 'runtime otp: %s\n' \
  "$(inside erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().')"
inside sh /opt/tls-check/run.sh /opt/knarr/runtime /tmp/tls | grep -E '^(openssl|otp_release|crypto|tls_check)'

chroot --userspec=10001:10001 "$root" \
  /usr/bin/env -i PATH=/bin HOME=/ ERL_CRASH_DUMP=/tmp/erl_crash.dump \
  /opt/knarr/container-entrypoint.sh /opt/knarr/shipment/entrypoint.sh run \
  > "$root/tmp/knarr.log" 2>&1 &
pid=$!
ready=no
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if [ "$(curl --noproxy '*' --silent --max-time 2 http://127.0.0.1:8080/readyz)" = ok ]; then
    ready=yes
    break
  fi
  sleep 1
done
printf 'readyz: %s\n' "$ready"
curl --noproxy '*' --silent --max-time 2 http://127.0.0.1:8080/metrics | grep '^knarr_startups_total'
printf 'process %s is: %s\n' "$pid" "$(cat "/proc/$pid/comm")"
kill -TERM "$pid"
status=0
wait "$pid" || status=$?
printf 'exit status after SIGTERM: %s\n' "$status"
tail -n 2 "$root/tmp/knarr.log"
