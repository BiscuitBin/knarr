#!/bin/sh
# Ticket 35 evidence, 03's fully cold initialization. On a disposable Linux
# machine whose pixi, rattler, Gleam, hex, prek and rebar3 caches do not exist,
# this clones the committed branch, then times one `just initialize`, one
# `just check`, and one `just check` with the network denied. Each command's
# transcript, colour removed and the work path replaced by <work>, goes to
# <work>/out/, beside results.json; the summary goes to standard output.
#
# Caches are the defaults, not overridden: the machine is disposable and no
# other session shares them. The script refuses to start if any of them, or any
# variable that relocates one, already exists. offline.sh then denies the
# network and runs the gate again.
#
# Needs network for the clone's initialization, pixi 0.81.0 or later and any
# recent just in <bootstrap-bin-dir>, curl, python3, and unshare.
# Usage: sh cold.sh <bootstrap-bin-dir> <empty-work-dir> > cold.txt 2>&1
set -eu
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
source=$(git -C "$here" rev-parse --show-toplevel)
bootstrap=$(cd "${1:?usage: cold.sh <bootstrap-bin-dir> <empty-work-dir>}" && pwd)
work=${2:?usage: cold.sh <bootstrap-bin-dir> <empty-work-dir>}
mkdir -p "$work"; work=$(cd "$work" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
[ "$(uname -sm)" = 'Linux x86_64' ] || fail "this script is for native linux-64, not $(uname -sm)"
PATH="$bootstrap:$PATH"; export PATH
out=$work/out; mkdir "$out"
clone=$work/clone
branch=$(git -C "$source" rev-parse --abbrev-ref HEAD)

esc=$(printf '\033')
tidy() { sed -e "s/$esc\[[0-9;]*[A-Za-z]//g" -e "s|$work|<work>|g" -e "s|$HOME|~|g"; }
porcelain() { git -C "$clone" status --porcelain --untracked-files=all; }
# timed <label> <command...>: runs the command in the clone, its output to
# <out>/<label>.txt, and appends {label, command, exit, seconds, porcelain}.
timed() {
  label=$1; shift
  set +e
  ( cd "$clone" && python3 -c '
import json, subprocess, sys, time
label, log, results = sys.argv[1:4]
command = sys.argv[4:]
with open(log, "wb") as f:
    start = time.monotonic()
    rc = subprocess.call(command, stdout=f, stderr=subprocess.STDOUT)
    seconds = round(time.monotonic() - start, 3)
with open(results, "a") as f:
    f.write(json.dumps({"label": label, "command": command, "exit": rc, "seconds": seconds}) + "\n")
print(f"{label}: exit {rc} after {seconds} s")
sys.exit(rc)
' "$label" "$work/$label.raw" "$work/results.jsonl" "$@" )
  rc=$?
  set -e
  tidy < "$work/$label.raw" > "$out/$label.txt"
  printf '     porcelain after %s: [%s]\n' "$label" "$(porcelain)"
}

printf 'date: %s\nhost: %s (%s)\nkernel: %s\ncpu: %s x %s\nmemory: %s\nuser: uid %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -sm)" "$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)" \
  "$(uname -r)" "$(nproc)" "$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')" \
  "$(awk '/MemTotal/ {printf "%.1f GiB", $2 / 1048576}' /proc/meminfo)" "$(id -u)"
if grep -q VirtualApple /proc/cpuinfo; then fail 'Rosetta CPU: not native linux-64'; fi
printf 'bootstrap: %s (sha256 %s), %s (sha256 %s)\n' \
  "$(pixi --version)" "$(sha256sum "$bootstrap/pixi" | cut -c1-64)" \
  "$(just --version)" "$(sha256sum "$bootstrap/just" | cut -c1-64)"
printf 'source: %s at %s\n' "$branch" "$(git -C "$source" rev-parse HEAD)"

echo; echo '== the caches are cold'
for var in PIXI_CACHE_DIR RATTLER_CACHE_DIR XDG_CACHE_HOME PREK_HOME HEX_HOME REBAR_CACHE_DIR; do
  eval "value=\${$var:-}"
  [ -z "$value" ] || fail "$var is set ($value): a cache could be relocated"
done
echo 'ok   PIXI_CACHE_DIR, RATTLER_CACHE_DIR, XDG_CACHE_HOME, PREK_HOME, HEX_HOME and REBAR_CACHE_DIR are unset'
caches="$HOME/.cache/rattler $HOME/.cache/gleam $HOME/.cache/prek $HOME/.cache/pre-commit $HOME/.cache/rebar3 $HOME/.cache/hex $HOME/.cache/lychee $HOME/.hex $HOME/.pixi $HOME/.rattler $HOME/.conda $HOME/.local/share/gleam $HOME/.local/share/rattler $HOME/.config/rebar3"
for path in $caches; do
  [ ! -e "$path" ] || fail "$path exists: not a cold machine"
done
printf 'ok   absent: %s\n' "$(echo "$caches" | tidy)"
# Not `pixi info` yet: it creates ~/.pixi. Its read-back comes at the end.
gleam_cache=$HOME/.cache/gleam

echo; echo '== a fresh clone'
git clone -q --no-hardlinks --single-branch --branch "$branch" "$source" "$clone"
for dir in .pixi .tools build; do [ ! -e "$clone/$dir" ] || fail "the clone has $dir"; done
printf 'ok   %s cloned at %s, with no .pixi, .tools or build; porcelain [%s]\n' "$branch" "$(git -C "$clone" rev-parse HEAD)" "$(porcelain)"

echo; echo '== just initialize, cold'
timed initialize just initialize
[ "$rc" -eq 0 ] || { cat "$out/initialize.txt"; fail 'just initialize failed'; }
[ -z "$(porcelain)" ] || fail 'just initialize changed the worktree'
grep -E '^ok |Sigstore|skipped' "$out/initialize.txt" | sed 's/^/     /' || true
printf 'ok   gleam cache after initialize: %s files\n' "$(find "$gleam_cache" -type f | wc -l | tr -d ' ')"

echo; echo '== just check'
timed check just check
[ "$rc" -eq 0 ] || { tail -40 "$out/check.txt"; fail 'just check failed'; }
[ -z "$(porcelain)" ] || fail 'just check changed the worktree'
grep -E '^(All checks|[0-9]+ passed| *[0-9]+ passed|=+ [0-9]+ passed)|passed, no failures' "$out/check.txt" | sed 's/^/     /' || true

echo; echo '== the network denied: offline.sh'
# A log, not a pipe: a pipe would hide offline.sh's failure from set -e.
set +e; sh "$here/offline.sh" "$clone" "$work/offline" > "$work/offline.log" 2>&1; rc=$?; set -e
sed 's/^/  /' "$work/offline.log"
[ "$rc" -eq 0 ] || fail 'offline.sh failed'
cp "$work/offline/offline-check.txt" "$out/offline-check.txt"
python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$work/offline/results.json" >> "$work/results.jsonl"

echo; echo '== the caches afterwards'
pixi_cache=$(pixi info --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["cache_dir"])')
case $pixi_cache in "$HOME"/.cache/rattler/*) ;; *) fail "pixi's cache is $pixi_cache, outside the paths checked as absent" ;; esac
printf 'ok   pixi info names its cache %s, inside a path that was absent\n' "$(echo "$pixi_cache" | tidy)"
pixi_cache_files=$(find "$pixi_cache" -type f | wc -l | tr -d ' ')
printf '     %s: %s files, %s\n' "$(echo "$pixi_cache" | tidy)" "$pixi_cache_files" "$(du -sh "$pixi_cache" | cut -f1)"
printf '     %s: %s files, %s\n' "$(echo "$gleam_cache" | tidy)" "$(find "$gleam_cache" -type f | wc -l | tr -d ' ')" "$(du -sh "$gleam_cache" | cut -f1)"
python3 -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
json.dump({"commit": sys.argv[2], "steps": rows}, open(sys.argv[3], "w"), indent=2)
open(sys.argv[3], "a").write("\n")
' "$work/results.jsonl" "$(git -C "$clone" rev-parse HEAD)" "$out/results.json"
echo; echo 'cold.sh: all steps passed'
