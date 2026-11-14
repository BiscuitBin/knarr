#!/bin/sh
# Ticket 01 evidence: what differs between the pixi versions and the prototype
# environment's, on today's tree. Offline, on the stand-in host, in the clone
# gate-setup.sh prepared.
# Usage (host): sh host.sh --offline sh /evidence/differences.sh > differences.txt
set -eu
clone=/work/gate/clone
cd "$clone"
git checkout --quiet .
tools=$clone/.pixi/envs/default
PATH=$tools/bin:$PATH
export PATH
logs=/work/gate/logs
mkdir -p "$logs"
printf 'date: %s\nclone: %s at %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git branch --show-current)" "$(git rev-parse --short HEAD)"

reported() { # the version a tool in the prototype environment reports
  case $1 in
    python) python3 --version | cut -d' ' -f2 ;;
    pytest) python3 -m pytest --version | cut -d' ' -f2 ;;
    erlang) erl -noshell -eval '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:put_chars(string:trim(V)), halt().' ;;
    kubernetes-helm) helm version --template '{{.Version}}' | sed 's/^v//; s/+.*//' ;;
    kustomize) kustomize version | sed 's/^v//' ;;
    markdownlint-cli2) markdownlint-cli2 --version | sed 's/^markdownlint-cli2 v\([^ ]*\).*/\1/' ;;
    shellcheck) shellcheck --version | sed -n 's/^version: //p' ;;
    hadolint) hadolint --version | sed 's/.* //' ;;
    kubeconform) kubeconform -v | sed 's/^v//' ;;
    actionlint | editorconfig-checker) "$1" --version | head -n 1 | sed 's/^v//' ;;
    rebar3) rebar3 --version | cut -d' ' -f2 ;;
    kubernetes-kind | kubernetes-client | kwokctl) echo '(cluster group, not installed here)' ;;
    grype) echo '(audit group, not installed here)' ;;
    tilt) echo '(not carried forward)' ;;
    *) "$1" --version | head -n 1 | sed 's/^[^ ]* //; s/ .*//' ;;
  esac
}

printf '\n== Versions: the pin, and what the prototype environment reports\n'
printf '%-22s %-10s %s\n' tool pinned prototype
{
  sed -n 's/^\([a-z0-9-]*\) = "==\(.*\)"$/\1 \2/p' pixi.toml
  sed -n 's/^\([a-z0-9-]*\) \([0-9.]*\) linux-64 .*/\1 \2/p' tools.txt
} | while read -r tool pinned; do
  have=$(reported "$tool")
  if [ "$have" = "$pinned" ]; then mark=''; else mark='  <- differs'; fi
  case $have in '('*) mark='' ;; esac
  printf '%-22s %-10s %s%s\n' "$tool" "$pinned" "$have" "$mark"
done
printf '%-22s %-10s %s  <- differs\n' openssl 3.6.5 "$(openssl version | cut -d' ' -f2)"
printf '%-22s %-10s %s  <- differs\n' node 26.10.0 "$(node --version | sed 's/^v//')"

printf '\n== The read-only linters and formatters, prototype versions, today'"'"'s tree\n'
for name in format-check toml-check lint packaging-check chart-check; do
  status=0
  just "$name" > "$logs/diff-$name.log" 2>&1 || status=$?
  printf '%-16s exit %s\n' "$name" "$status"
done
grep -E '\.\.\.+(Passed|Failed)$' "$logs/diff-lint.log" | sed 's/^/  /'

printf '\n== The repairing formatters (just fix), prototype versions: what they would rewrite\n'
status=0
just fix > "$logs/diff-fix.log" 2>&1 || status=$?
printf 'just fix: exit %s; git status --short: %s lines\n' "$status" "$(git status --short | wc -l)"
git status --short
git checkout --quiet .

printf '\n== Gleam 1.19.2, the candidate'"'"'s own, in a copy of the clone (not the prototype'"'"'s Gleam)\n'
rm -rf /work/gate/gleam-copy
cp -a "$clone" /work/gate/gleam-copy
cd /work/gate/gleam-copy
PATH=/work/gate/gleam-candidate/bin:$PATH
gleam --version
attempt() { # label, command...
  label=$1
  shift
  status=0
  "$@" > "$logs/diff-gleam.log" 2>&1 || status=$?
  printf '%-44s exit %s  %s\n' "$label" "$status" "$(grep -E '^(warning|error)|passed|failures' "$logs/diff-gleam.log" | sort | uniq -c | sed 's/^ *//' | tr '\n' ';' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-90)"
}
before=$(cksum < manifest.toml)
attempt 'gleam format --check' gleam format --check src test fixtures/fake_worker/src fixtures/fake_worker/test
attempt 'gleam build --warnings-as-errors' gleam build --warnings-as-errors
attempt 'just lint-gleam (glinter)' just lint-gleam
attempt 'just test' just test
if [ "$(cksum < manifest.toml)" = "$before" ]; then echo 'manifest.toml unchanged'; else echo 'manifest.toml REWRITTEN'; fi
printf 'git status --short: %s lines\n' "$(git status --short | wc -l)"
