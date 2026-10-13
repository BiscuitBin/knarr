#!/bin/sh
# Ticket 35 evidence, the network-denied half of 03's cold initialization. In a
# clone where `just initialize` and `just check` have already passed, three
# curl probes inside a fresh network namespace must fail; then `just check`
# runs, timed, inside another. Each namespace (unshare -rn) holds only lo,
# brought up with python's SIOCSIFFLAGS ioctl (iproute2 may be absent) so
# knarr's loopback tests can run; nothing routes out of it. cold.sh calls this
# last; on its own it needs pixi on PATH, as the gate does. The gate's
# transcript, colour removed and paths replaced, goes to
# <work>/offline-check.txt beside results.json; the summary to standard output.
# Usage: sh offline.sh <initialized-clone> <empty-work-dir>
set -eu
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
clone=$(cd "${1:?usage: offline.sh <initialized-clone> <empty-work-dir>}" && pwd)
work=${2:?usage: offline.sh <initialized-clone> <empty-work-dir>}
mkdir -p "$work"; work=$(cd "$work" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
just=$clone/.pixi/envs/default/bin/just
[ -x "$just" ] || fail "$clone has no pixi environment; run just initialize there"
# lock-check runs the host's pixi, which is not in the environment it installs.
command -v pixi > /dev/null || fail 'pixi is not on PATH'

esc=$(printf '\033')
tidy() { sed -e "s/$esc\[[0-9;]*[A-Za-z]//g" -e "s|$clone|<clone>|g" -e "s|$work|<work>|g" -e "s|$HOME|~|g"; }
porcelain() { git -C "$clone" status --porcelain --untracked-files=all; }
lo_up='
import fcntl, os, socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
req = struct.pack("16sH14x", b"lo", 0)
flags = struct.unpack("16sH14x", fcntl.ioctl(s, 0x8913, req))[1]
fcntl.ioctl(s, 0x8914, struct.pack("16sH14x", b"lo", flags | 0x1))
os.execvp(sys.argv[1], sys.argv[1:])
'

printf 'date: %s\nhost: %s\nclone: <clone> at %s, porcelain [%s]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(uname -sm)" "$(git -C "$clone" rev-parse HEAD)" "$(porcelain)"

echo; echo '== the network is denied inside the namespace'
# /proc/net/dev is the namespace's own; /sys/class/net would show the host's.
printf '     interfaces: %s\n' "$(unshare -rn python3 -c "$lo_up" cat /proc/net/dev | awk -F: 'NR > 2 { gsub(/ /, "", $1); printf "%s ", $1 }')"
probe() { # probe <want-exit> <curl argument...>
  want=$1; shift
  set +e; unshare -rn python3 -c "$lo_up" curl -fsS --max-time 10 -o /dev/null "$@" > "$work/probe.raw" 2>&1; got=$?; set -e
  [ "$got" -ne 0 ] || fail "curl $* succeeded inside the namespace"
  printf '%s   curl %s: exit %s (%s)\n' "$( [ "$got" -eq "$want" ] && echo ok || echo note)" "$*" "$got" "$(tidy < "$work/probe.raw")"
}
probe 7 https://github.com
probe 6 --noproxy '*' https://github.com
probe 7 --noproxy '*' https://140.82.112.3

echo; echo '== just check, network denied'
set +e
( cd "$clone" && python3 -c '
import json, subprocess, sys, time
log, results = sys.argv[1:3]
command = sys.argv[3:]
with open(log, "wb") as f:
    start = time.monotonic()
    rc = subprocess.call(command, stdout=f, stderr=subprocess.STDOUT)
    seconds = round(time.monotonic() - start, 3)
row = {"label": "offline-check", "command": ["unshare", "-rn", "<lo up>", "just", "check"], "exit": rc, "seconds": seconds}
with open(results, "w") as f:
    json.dump(row, f, indent=2)
    f.write("\n")
print(f"offline-check: exit {rc} after {seconds} s")
sys.exit(rc)
' "$work/offline-check.raw" "$work/results.json" unshare -rn python3 -c "$lo_up" "$just" check )
rc=$?
set -e
tidy < "$work/offline-check.raw" > "$work/offline-check.txt"
rm "$work/offline-check.raw" "$work/probe.raw"
printf '     porcelain after offline-check: [%s]\n' "$(porcelain)"
[ "$rc" -eq 0 ] || { tail -40 "$work/offline-check.txt"; fail 'just check failed with the network denied'; }
[ -z "$(porcelain)" ] || fail 'the offline just check changed the worktree'
grep -E '^All checks' "$work/offline-check.txt" | sed 's/^/     /'
echo; echo 'offline.sh: the probes failed and the gate passed with the network denied'
