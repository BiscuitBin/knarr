#!/bin/sh
# Ticket 53 evidence: the pinned rebar3 builds the hex packages that need it.
#
#   1. On just's PATH, rebar3 is .tools/bin/rebar3, its sha256 is the
#      tools.txt pin, and `rebar3 version` names the pin and the OTP it runs on.
#   2. build/dev and build/prod are removed, so `just build` compiles every
#      package again. Each package manifest.toml builds with rebar3 must be
#      compiled, with .beam files in its ebin.
#   3. `just test`.
#
# Needs the pixi default environment and .tools/bin (just initialize), and no
# network. Refuses build inputs that differ from HEAD.
# Usage: sh build.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
wt=$(cd "$here/../../../.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cd "$wt"
git diff --quiet HEAD -- tools.txt manifest.toml gleam.toml src test || fail 'build inputs differ from HEAD'
# The Justfile's PATH, in its order.
envs=$wt/.pixi/envs
PATH=$envs/default/bin:$envs/cluster/bin:$envs/audit/bin:$wt/.tools/bin:$PATH
export PATH
printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
printf 'revision: %s\n' "$(git rev-parse --short HEAD)"

echo '== 1. rebar3 on the PATH'
[ "$(grep -c '^rebar3 [^ ]* linux-64 ' tools.txt)" = 1 ] || fail 'want one rebar3 linux-64 line in tools.txt'
line=$(sed -n 's/^rebar3 \([^ ]*\) linux-64 [^ ]* \([0-9a-f]\{64\}\) rebar3$/\1 \2/p' tools.txt)
[ -n "$line" ] || fail 'the rebar3 linux-64 line has no sha256'
pin=${line%% *} sha=${line#* }
found=$(command -v rebar3)
[ "$found" = "$wt/.tools/bin/rebar3" ] || fail "rebar3 resolves to $found"
got=$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$found")
[ "$got" = "$sha" ] || fail "$found has sha256 $got, not the pin $sha"
printf 'rebar3: .tools/bin/rebar3, sha256 %s, the tools.txt pin\n' "$got"
version=$(rebar3 version)
printf '%s\n' "$version"
case $version in "rebar $pin on "*) ;; *) fail "rebar3 version does not name $pin" ;; esac

echo '== 2. just build, from no compiled packages'
mkdir -p "$wt/ai_tmp"
rm -rf "${wt:?}/build/dev" "${wt:?}/build/prod"
just build > "$wt/ai_tmp/evidence-53-build.log" 2>&1 || { cat "$wt/ai_tmp/evidence-53-build.log" >&2; fail 'just build failed'; }
grep -E '^ *Compil(ing|ed)' "$wt/ai_tmp/evidence-53-build.log" | sed 's/^ */  /'
packages=$wt/ai_tmp/evidence-53-rebar3-packages
sed -n 's/^  { name = "\([^"]*\)", version = "\([^"]*\)", build_tools = \["rebar3"\],.* otp_app = "\([^"]*\)".*/\1 \2 \3/p' manifest.toml > "$packages"
[ -s "$packages" ] || fail 'manifest.toml builds no package with rebar3'
while read -r name version app <&3; do
  beams=$(find "build/dev/erlang/$app/ebin" -name '*.beam' 2> /dev/null | wc -l | tr -d ' ')
  [ "$beams" -gt 0 ] || fail "$name has no compiled .beam files"
  printf 'built with rebar3: %s %s, %s .beam files in build/dev/erlang/%s/ebin\n' "$name" "$version" "$beams" "$app"
done 3< "$packages"

echo '== 3. just test'
just test > "$wt/ai_tmp/evidence-53-test.log" 2>&1 || { tail -n 40 "$wt/ai_tmp/evidence-53-test.log" >&2; fail 'just test failed'; }
grep -E '[0-9]+ (passed|failed)' "$wt/ai_tmp/evidence-53-test.log" | tail -n 1 | sed -e "s/$(printf '\033')\\[[0-9;]*m//g" -e 's/^ */  /'
