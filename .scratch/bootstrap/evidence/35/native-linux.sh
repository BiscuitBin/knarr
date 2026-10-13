#!/bin/sh
# Ticket 35 evidence, 01's Verify 1 (TLS) and Verify 3 (rebar3) on native
# linux-64, which 01's linux.sh could only run under Rosetta. No container and
# no ERL_FLAGS: the worktree's own locked default and runtime environments run
# 01's probes unchanged. TLS runs in both; the OTP release each one boots must
# be pixi.lock's erlang major; rebar3 is the sha256-pinned one `just
# initialize` put in .tools/bin, and the probe's negative control removes it.
# Needs `pixi install --locked -e runtime` in the worktree beforehand, and
# network for the rebar3 probe's two hex packages. Writes only to <work>.
# Usage: sh native-linux.sh <initialized-worktree> <empty-work-dir>
set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
probes=$(cd "$here/../01" && pwd)
worktree=$(cd "${1:?usage: native-linux.sh <initialized-worktree> <empty-work-dir>}" && pwd)
work=${2:?usage: native-linux.sh <initialized-worktree> <empty-work-dir>}
mkdir -p "$work"; work=$(cd "$work" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
envs=$worktree/.pixi/envs
for env in default runtime; do
  [ -x "$envs/$env/bin/erl" ] || fail "$envs/$env has no erl; run pixi install --locked -e $env in the worktree"
done
[ -x "$worktree/.tools/bin/rebar3" ] || fail "$worktree/.tools/bin has no rebar3; run just initialize"
[ "$(uname -sm)" = 'Linux x86_64' ] || fail "this script is for native linux-64, not $(uname -sm)"

printf 'date: %s\nhost: %s, %s\ncpu: %s\ncommit: %s\npixi: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" \
  "$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)" "$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')" \
  "$(git -C "$worktree" rev-parse HEAD)" "$(pixi --version)"
if grep -q VirtualApple /proc/cpuinfo; then fail 'Rosetta CPU: not native linux-64'; fi
[ -z "${ERL_FLAGS:-}" ] || fail "ERL_FLAGS is set ($ERL_FLAGS); the native run needs no flag"
echo 'native: /proc/cpuinfo names no VirtualApple CPU, and ERL_FLAGS is unset'
for env in default runtime; do
  printf '%s: ' "$env"
  (cd "$worktree" && pixi list --frozen --no-install -e "$env" 2> /dev/null) |
    awk '$1 == "erlang" || $1 == "openssl" { printf "%s %s %s  ", $1, $2, $3 }'
  echo
done
want=$(cd "$worktree" && pixi list --frozen --no-install -e runtime 2> /dev/null | awk '$1 == "erlang" { split($2, v, "."); print v[1] }')
release() { "$envs/$1/bin/erl" -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), io:nl(), halt().'; }
d=$(release default); r=$(release runtime)
echo "otp_release default: $d, runtime: $r, pixi.lock erlang major: $want"
[ -n "$want" ] && [ "$d" = "$want" ] && [ "$r" = "$want" ] || fail 'OTP majors disagree'

echo; echo '== Verify 1, TLS, default environment'
sh "$probes/tls/run.sh" "$envs/default" "$work/tls-default"
echo; echo '== Verify 1, TLS, runtime environment (erlang and its dependencies only)'
sh "$probes/tls/run.sh" "$envs/runtime" "$work/tls-runtime"
echo; echo '== Verify 3, rebar3'
# rebar3 prints its httpc proxy, with every no_proxy entry on its own line,
# when HTTPS_PROXY is set; each such block is folded to its first line here.
set +e; sh "$probes/rebar3/run.sh" "$envs/default" "$worktree/.tools/bin" "$work/probe" > "$work/rebar3.log" 2>&1; rc=$?; set -e
awk '/^Setting httpc proxy:/ { sub(/ no_proxy=.*/, " no_proxy=[...]"); print; skip = 1; next }
     skip && /^ +"/ { next } { skip = 0; print }' "$work/rebar3.log"
[ "$rc" -eq 0 ] || fail "rebar3/run.sh exited $rc"
echo; echo 'native-linux.sh: all checks passed'
