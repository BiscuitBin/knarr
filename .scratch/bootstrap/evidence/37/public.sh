#!/bin/sh
# Ticket 37 evidence: ghcr.io/steven-cutting/knarr as anyone sees it, with no
# credentials. Two modes. `private` was written for the package before a
# visibility change, expecting Decision 0012's account. Nobody changed the
# visibility, and `private` failed its first expectation because the package
# was already public (public-private.txt). `public` reads the package as it is.
#   private: expects the anonymous pull token refused (403), and lib.sh's
#            probe_tag reading `unknown` (401), as 28's ghcr-probe.txt saw for
#            a package it could not see.
#   public:  an anonymous pull token is granted; with it, every tag release.yml
#            pushed, and the digest itself, answer 200 with the run's digest;
#            `latest` answers 404; tags/list holds exactly the three tags; and
#            probe_tag reads `present` for 0.1.0, which is the existence guard
#            refusing a second push of v0.1.0 without one being made. The
#            workflow asks with a push-scope token after logging in; for a
#            public package a pull token sees the same manifest.
# A bare HEAD with no token answers 401 even for a public package; a registry
# client fetches the anonymous token first, and so does this script. The
# token is never printed. Exits non-zero on any unexpected answer.
# Usage: sh public.sh <sha256:digest> <commit> private|public > public.txt 2>&1
# shellcheck disable=SC2154  # lib.sh's probe_tag and registry_head set code, verdict and verdict_rc; the gate runs without -x
set -eu
usage='usage: public.sh <sha256:digest> <commit> private|public'
digest=${1:?$usage}
commit=${2:?$usage}
mode=${3:?$usage}
case $mode in private | public) ;; *) echo "$usage" >&2; exit 2 ;; esac
repo=steven-cutting/knarr
base=https://ghcr.io
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(git -C "$here" rev-parse --show-toplevel)
# shellcheck source=../../../../scripts/release/lib.sh disable=SC1091  # the gate runs without -x
. "$root/scripts/release/lib.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
short=$(printf '%s' "$commit" | cut -c1-7)
manifest_head() { # ref, [curl args...]: the headers to $work/headers; sets code and curl_rc
  registry_head "$base" "$repo" "$@" > "$work/headers"
}
v=$(curl --version | head -n 1) || fail 'curl --version failed'
printf 'date: %s\n%s\nimage: %s/%s\ndigest: %s\ncommit: %s\nmode: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$v" "${base#https://}" "$repo" "$digest" "$commit" "$mode"

echo; echo "== an anonymous pull token: GET $base/token?scope=repository:$repo:pull&service=ghcr.io"
tcode=$(curl -sS --max-time 20 -o "$work/token.json" -w '%{http_code}' \
  "$base/token?scope=repository:$repo:pull&service=ghcr.io") || fail 'the token request failed'
manifest_head 0.1.0
bare=$code

if [ "$mode" = private ]; then
  expect 'token: http' "$tcode" 403
  printf 'token: body %s\n' "$(cat "$work/token.json")"
  echo; echo '== the manifest, with no token'
  expect 'HEAD 0.1.0: http' "$bare" 401
  probe_tag "$base" "$repo" 0.1.0
  expect 'probe_tag 0.1.0' "$verdict ($verdict_rc, http $code)" 'unknown (2, http 401)'
  echo; echo 'private: anonymous reads cannot see the package'
  exit 0
fi

expect 'token: http' "$tcode" 200
token=$(perl -ne 'print $1 if /"token":"([^"]+)"/' "$work/token.json")
[ -n "$token" ] || fail 'the answer has no token'
echo 'token: granted (not printed)'
auth="Authorization: Bearer $token"
printf 'info HEAD 0.1.0 with no token: http %s\n' "$bare"

echo; echo '== the manifest by each tag release.yml pushed, and by digest'
for ref in 0.1.0 0.1 "sha-$short" "$digest"; do
  manifest_head "$ref" -H "$auth"
  d=$(digest_of_headers < "$work/headers") || d=''
  expect "HEAD $ref: http, Docker-Content-Digest" "$code $d" "200 $digest"
  printf '     content-type: %s\n' "$(tr -d '\r' < "$work/headers" | grep -i '^content-type:' | sed 's/^[^:]*: *//')"
done
manifest_head latest -H "$auth"
expect 'HEAD latest: http' "$code" 404

echo; echo "== GET $base/v2/$repo/tags/list"
v=$(curl -sS --max-time 20 -H "$auth" "$base/v2/$repo/tags/list") || fail 'tags/list failed'
printf '%s\n' "$v"
v=$(printf '%s' "$v" | perl -ne 'if (/"tags":\[([^\]]*)\]/) { print join(",", sort map { s/"//gr } split /,/, $1) }')
expect tags "$v" "0.1,0.1.0,sha-$short"

echo; echo '== a second push of v0.1.0, reasoned dry: the existence guard against the real registry'
probe_tag "$base" "$repo" 0.1.0 -H "$auth"
expect 'probe_tag 0.1.0' "$verdict ($verdict_rc, http $code)" 'present (1, http 200)'
printf "the workflow's guard would stop the run with:\n  ::error::%s/%s:0.1.0 exists (http %s): a release is published once; bump the version\n" \
  "${base#https://}" "$repo" "$code"
echo; echo 'public: every tag pulls anonymously at the run digest'
