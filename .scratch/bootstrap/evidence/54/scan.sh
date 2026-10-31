#!/bin/sh
# Bootstrap ticket 54 evidence: the published v0.3.1 image scanned by digest,
# with v0.3.1-rc.1's image as a control. rc.1 (b71fd32) predates ticket 52, so
# it ships Erlang/OTP 29.1.1, and both scans should still list CVE-2026-94200
# (High) in erlang as a binary package, as ticket 52's audit run did. v0.3.1
# ships 29.1.2, which fixes it, so neither scan should list it there.
#
# For each digest: docker pull --platform linux/amd64 (the release image is
# amd64 only, and runtime-scan creates its container with --pull=never), then
# just image-scan (grype over the OS packages) and just runtime-scan (grype
# over the conda runtime environment copied out of the image). Both use
# --only-fixed --fail-on high. image-scan exits grype's own status: 0, 2 when
# --fail-on trips and 1 on an error. runtime-scan exits 0 for nothing that
# qualifies, 2 for a finding and 1 when it cannot decide. A scan can print a
# table and still exit 1, so the control counts only when it lists the CVE and
# exits 2. Each exit status is printed, and every scan runs before any check,
# so the transcript is whole even when a check fails.
#
# rebar3 runs only in the build stage and is not in the runtime image, so
# neither scan ever matched rebar3: ticket 53's fix is in the build, not in
# anything these scans read.
#
# Needs network for the pulls and grype's database, docker, and the pixi
# default and audit environments (just initialize, just audit-install).
# Usage: sh scan.sh <v0.3.1 image digest> <rc.1 image digest> > scan.txt 2>&1
set -eu
usage='usage: scan.sh <v0.3.1 image digest> <rc.1 image digest>'
release=${1:?$usage}
control=${2:?$usage}
here=$(cd "$(dirname "$0")" && pwd)
wt=$(cd "$here/../../../.." && pwd)
just=$wt/.pixi/envs/default/bin/just
grype=$wt/.pixi/envs/audit/bin/grype
image=ghcr.io/biscuitbin/knarr
cve=CVE-2026-94200
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for d in "$release" "$control"; do
  printf '%s\n' "$d" | grep -qE '^sha256:[0-9a-f]{64}$' || fail "'$d' is not sha256:<64 hex>"
done
[ -x "$grype" ] || fail "$grype is missing; run just audit-install"
cd "$wt"
v=$("$grype" version) || fail 'grype version failed'
printf 'date: %s\n%s\n%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
  "$(printf '%s\n' "$v" | grep -E '^(Version|Application):' | paste -s -d ' ' -)" \
  "$(docker version --format 'docker {{.Server.Version}}')"

scan() { # label, digest: pulls, runs both scans, keeps each table and status
  ref=$image@$2
  printf '\n== %s: docker pull --platform linux/amd64 %s\n' "$1" "$ref"
  docker pull --quiet --platform linux/amd64 "$ref" || fail "docker pull $ref failed"
  printf '\n== %s: just image-scan %s\n' "$1" "$ref"
  rc=0; out=$("$just" image-scan "$ref" 2>&1) || rc=$?
  printf '%s\n' "$out"
  printf 'info image-scan exit: %s\n' "$rc"
  eval "${3}_image_rc=\$rc; ${3}_image_out=\$out"
  printf '\n== %s: just runtime-scan %s\n' "$1" "$ref"
  rc=0; out=$("$just" runtime-scan "$ref" 2>&1) || rc=$?
  printf '%s\n' "$out"
  printf 'info runtime-scan exit: %s\n' "$rc"
  eval "${3}_runtime_rc=\$rc; ${3}_runtime_out=\$out"
}
scan 'v0.3.1' "$release" release
scan 'v0.3.1-rc.1, the control' "$control" control
printf '\n== grype db status, the database both scans read\n'
"$grype" db status 2>&1 || true

has() { printf '%s\n' "$1" | grep -c -- "$cve" || true; }
echo; echo '== checks'
# shellcheck disable=SC2154 # set by scan's eval
{
  [ "$(has "$control_image_out")" -gt 0 ] || fail "the control's image-scan does not list $cve"
  [ "$control_image_rc" = 2 ] || fail "the control's image-scan exited $control_image_rc, not 2"
  printf 'ok   the control: image-scan lists %s (exit %s)\n' "$cve" "$control_image_rc"
  [ "$(has "$control_runtime_out")" -gt 0 ] || fail "the control's runtime-scan does not list $cve"
  [ "$control_runtime_rc" = 2 ] || fail "the control's runtime-scan exited $control_runtime_rc, not 2"
  printf 'ok   the control: runtime-scan lists %s (exit %s)\n' "$cve" "$control_runtime_rc"
  [ "$(has "$release_image_out")" = 0 ] || fail "v0.3.1's image-scan lists $cve"
  printf 'ok   v0.3.1: image-scan does not list %s\n' "$cve"
  [ "$(has "$release_runtime_out")" = 0 ] || fail "v0.3.1's runtime-scan lists $cve"
  printf 'ok   v0.3.1: runtime-scan does not list %s\n' "$cve"
  [ "$release_image_rc" = 0 ] || fail "v0.3.1's image-scan exited $release_image_rc"
  printf 'ok   v0.3.1: image-scan exit 0\n'
  [ "$release_runtime_rc" = 0 ] || fail "v0.3.1's runtime-scan exited $release_runtime_rc"
  printf 'ok   v0.3.1: runtime-scan exit 0\n'
}
echo; echo 'scan passed'
