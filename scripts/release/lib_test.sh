#!/bin/sh
# Tests for the release guards in lib.sh, offline, in the command-line style of
# ticket 15's lib_test.sh. Moved from ticket 28's evidence without the tests of
# the helpers only that evidence used; test_release_lib.py runs this file in
# `just test-checkers-selected release`. The canned inputs are copied from real output:
# buildx's --metadata-file, `curl -sI` against registry:2 and ghcr.io, and
# `docker buildx imagetools inspect`.
#   version_of_tag, tags_for, toml_version, tag_matches_version,
#   changelog_has_version   the release guards and the tag set
#   digest_of_headers, digest_of_metadata, digest_of_inspect
#                           one digest read three ways
#   tag_exists_verdict      absent, present or unknown: a refused, denied or
#                           failed request is never read as "absent"
#   probe_tag               through a stub curl: the request it makes, and
#                           only a 404 is "absent"
#   ancestor_verdict        through a stub git, then on a throwaway repository
# Usage: sh scripts/release/lib_test.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh disable=SC1091  # the gate runs without -x
. "$here/lib.sh"
pass=0; failed=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { failed=$((failed + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
eq() { # description, actual, expected
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got '$2', want '$3'"; fi
}
status() { rc=0; "$@" > /dev/null 2>&1 || rc=$?; echo "$rc"; }
said() { rc=0; out=$("$@" 2> /dev/null) || rc=$?; printf '%s; exit %s\n' "$out" "$rc"; } # output and status
lines() { printf '%s\n' "$@"; } # one argument per line, for multi-line expectations

# The stub commands that go on PATH: curl for probe_tag, git for
# ancestor_verdict.
stub=$(mktemp -d)
trap 'rm -rf "${stub:?}"' EXIT

# version_of_tag: a SemVer tag with a leading v and, for a prerelease, only
# -rc.N; anything else is nothing and exit 1
eq 'version_of_tag: v0.1.0 is 0.1.0' "$(said version_of_tag v0.1.0)" '0.1.0; exit 0'
eq 'version_of_tag: v0.1.0-rc.1 keeps its prerelease' "$(said version_of_tag v0.1.0-rc.1)" '0.1.0-rc.1; exit 0'
eq 'version_of_tag: v1.2.3 is 1.2.3' "$(said version_of_tag v1.2.3)" '1.2.3; exit 0'
eq 'version_of_tag: 0.1.0 has no v' "$(said version_of_tag 0.1.0)" '; exit 1'
eq 'version_of_tag: v1.0 has two parts' "$(said version_of_tag v1.0)" '; exit 1'
eq 'version_of_tag: latest is not a version' "$(said version_of_tag latest)" '; exit 1'
eq 'version_of_tag: v01.0.0 has a leading zero' "$(said version_of_tag v01.0.0)" '; exit 1'
eq 'version_of_tag: build metadata cannot be an image tag' "$(said version_of_tag v1.0.0+build.1)" '; exit 1'
eq 'version_of_tag: an empty tag' "$(said version_of_tag '')" '; exit 1'
eq 'version_of_tag: v1.0.0-rc.0 is a prerelease' "$(said version_of_tag v1.0.0-rc.0)" '1.0.0-rc.0; exit 0'
eq 'version_of_tag: v1.0.0-rc.10 is a prerelease' "$(said version_of_tag v1.0.0-rc.10)" '1.0.0-rc.10; exit 0'
eq 'version_of_tag: v1.2.3-01 has a leading zero' "$(said version_of_tag v1.2.3-01)" '; exit 1'
eq 'version_of_tag: v1.2.3-. has an empty identifier' "$(said version_of_tag v1.2.3-.)" '; exit 1'
eq 'version_of_tag: v1.2.3-alpha..1 has an empty identifier' "$(said version_of_tag v1.2.3-alpha..1)" '; exit 1'
eq 'version_of_tag: v1.2.3-alpha.1 is not an rc' "$(said version_of_tag v1.2.3-alpha.1)" '; exit 1'
eq 'version_of_tag: v1.2.3-rc has no number' "$(said version_of_tag v1.2.3-rc)" '; exit 1'
eq 'version_of_tag: v1.2.3-rc. has an empty number' "$(said version_of_tag v1.2.3-rc.)" '; exit 1'
eq 'version_of_tag: v1.2.3-rc.01 has a leading zero' "$(said version_of_tag v1.2.3-rc.01)" '; exit 1'

# tags_for <tag> <sha>: the image tags one release pushes, one per line
eq 'tags_for: v0.1.0 gets 0.1.0, 0.1 and the short sha' \
  "$(tags_for v0.1.0 abc1234def5678901234567890abcdef12345678)" "$(lines 0.1.0 0.1 sha-abc1234)"
eq 'tags_for: v1.2.3 also gets the major' \
  "$(tags_for v1.2.3 0123456789abcdef0123456789abcdef01234567)" "$(lines 1.2.3 1.2 1 sha-0123456)"
eq 'tags_for: a prerelease gets no floating tag' \
  "$(tags_for v0.2.0-rc.1 abc1234def5678901234567890abcdef12345678)" "$(lines 0.2.0-rc.1 sha-abc1234)"
eq 'tags_for: a 7-character sha is accepted as it is' "$(tags_for v0.1.0 abc1234)" "$(lines 0.1.0 0.1 sha-abc1234)"
eq 'tags_for: never latest' "$(tags_for v1.2.3 abc1234 | grep -c latest || true)" 0
eq 'tags_for: a malformed tag is refused' "$(said tags_for 0.1.0 abc1234)" '; exit 1'
eq 'tags_for: a short sha is refused' "$(said tags_for v0.1.0 abc12)" '; exit 1'

# toml_version: gleam.toml on stdin
toml='name = "knarr"
version = "0.1.0"
description = "A controller."
target = "erlang"'
eq 'toml_version: reads the top-level version' "$(printf '%s\n' "$toml" | said toml_version)" '0.1.0; exit 0'
eq 'toml_version: no version line is a failure' "$(printf 'name = "knarr"\n' | said toml_version)" '; exit 1'
eq 'toml_version: two version lines are a failure' "$(printf '%s\nversion = "0.2.0"\n' "$toml" | said toml_version)" '; exit 1'
eq 'toml_version: an indented or commented line does not count' \
  "$(printf '# version = "9.9.9"\n  version = "8.8.8"\nversion = "0.1.0"\n' | said toml_version)" '0.1.0; exit 0'

# tag_matches_version <tag> <version>: 0 match, 1 mismatch, 2 malformed
eq 'tag_matches_version: v0.1.0 matches 0.1.0' "$(status tag_matches_version v0.1.0 0.1.0)" 0
eq 'tag_matches_version: v0.1.0 does not match 0.2.0' "$(status tag_matches_version v0.1.0 0.2.0)" 1
eq 'tag_matches_version: v0.1.0-rc.1 does not match 0.1.0' "$(status tag_matches_version v0.1.0-rc.1 0.1.0)" 1
eq 'tag_matches_version: a malformed tag is 2, not a mismatch' "$(status tag_matches_version 0.1.0 0.1.0)" 2
eq 'tag_matches_version: an empty version is 2' "$(status tag_matches_version v0.1.0 '')" 2

# changelog_has_version <version>: CHANGELOG.md on stdin, exactly the Keep a
# Changelog release heading "## [<version>] - YYYY-MM-DD"
changelog='# Changelog

## [Unreleased]

## [0.1.0] - 2026-10-20

### Added

- The walking skeleton.'
eq 'changelog_has_version: finds the released heading' "$(printf '%s\n' "$changelog" | status changelog_has_version 0.1.0)" 0
eq 'changelog_has_version: Unreleased alone is not a release' "$(printf '## [Unreleased]\n' | status changelog_has_version 0.1.0)" 1
eq 'changelog_has_version: a longer version is not a prefix match' "$(printf '## [0.1.01] - 2026-10-20\n' | status changelog_has_version 0.1.0)" 1
eq 'changelog_has_version: dots are literal' "$(printf '## [0x1x0] - 2026-10-20\n' | status changelog_has_version 0.1.0)" 1
eq 'changelog_has_version: a prerelease heading' "$(printf '## [0.2.0-rc.1] - 2026-11-01\n' | status changelog_has_version 0.2.0-rc.1)" 0
eq 'changelog_has_version: a heading with no date' "$(printf '## [0.1.0]\n' | status changelog_has_version 0.1.0)" 1
eq 'changelog_has_version: a draft suffix' "$(printf '## [0.1.0] - 2026-10-20 draft\n' | status changelog_has_version 0.1.0)" 1
eq 'changelog_has_version: a date without leading zeros' "$(printf '## [0.1.0] - 2026-1-5\n' | status changelog_has_version 0.1.0)" 1
eq 'changelog_has_version: a [YANKED] suffix' "$(printf '## [0.1.0] - 2026-10-20 [YANKED]\n' | status changelog_has_version 0.1.0)" 1
eq 'changelog_has_version: no " - " before the date' "$(printf '## [0.1.0] 2026-10-20\n' | status changelog_has_version 0.1.0)" 1

# One digest, three readings. The canned text is from the probe run against
# registry:2 (HEAD with the manifest Accept header) and buildx 0.33.
d=sha256:dfac0f04ce4e8ed2d1e4ce5947678797723e3b5f83d91010b31d8a8b00d831bc
headers=$(printf 'HTTP/1.1 200 OK\r\nContent-Length: 498\r\nContent-Type: application/vnd.docker.distribution.manifest.v2+json\r\nDocker-Content-Digest: %s\r\nX-Content-Type-Options: nosniff\r\n\r\n' "$d")
eq 'digest_of_headers: Docker-Content-Digest, CRLF stripped' "$(printf '%s' "$headers" | said digest_of_headers)" "$d; exit 0"
eq 'digest_of_headers: the header name is case-insensitive (ghcr.io sends lower case)' \
  "$(printf 'HTTP/2 200 \r\ndocker-content-digest: %s\r\n' "$d" | said digest_of_headers)" "$d; exit 0"
eq 'digest_of_headers: no digest header is a failure' "$(printf 'HTTP/1.1 404 Not Found\r\n' | said digest_of_headers)" '; exit 1'
eq 'digest_of_headers: a malformed digest is a failure' "$(printf 'Docker-Content-Digest: sha256:abc\r\n' | said digest_of_headers)" '; exit 1'
metadata='{
  "buildx.build.ref": "orbstack/orbstack/djktz2rq43ie3omsrgrbkstkq",
  "containerimage.config.digest": "sha256:4e3fd0095353d3e2d7cf6903189f5b15e3b28011e0240cfded11ee04f999a46e",
  "containerimage.descriptor": {
    "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    "digest": "sha256:dfac0f04ce4e8ed2d1e4ce5947678797723e3b5f83d91010b31d8a8b00d831bc",
    "size": 498
  },
  "containerimage.digest": "sha256:dfac0f04ce4e8ed2d1e4ce5947678797723e3b5f83d91010b31d8a8b00d831bc",
  "image.name": "localhost:32770/knarr:0.1.0,localhost:32770/knarr:0.1"
}'
eq 'digest_of_metadata: containerimage.digest, not the config digest' "$(printf '%s\n' "$metadata" | said digest_of_metadata)" "$d; exit 0"
eq 'digest_of_metadata: compact JSON' "$(printf '{"containerimage.digest":"%s"}' "$d" | said digest_of_metadata)" "$d; exit 0"
eq 'digest_of_metadata: no digest is a failure' "$(printf '{"image.name":"x"}\n' | said digest_of_metadata)" '; exit 1'
inspect="Name:      localhost:32770/knarr:0.1.0
MediaType: application/vnd.docker.distribution.manifest.v2+json
Digest:    $d"
eq 'digest_of_inspect: the Digest line' "$(printf '%s\n' "$inspect" | said digest_of_inspect)" "$d; exit 0"
eq 'digest_of_inspect: no Digest line is a failure' "$(printf 'Name: x\n' | said digest_of_inspect)" '; exit 1'

# tag_exists_verdict <curl exit status> <http code>: the pre-push guard. Only
# a 404 is "absent"; a 200 refuses; everything else fails closed as unknown.
eq 'tag_exists_verdict: 404 is absent, 0' "$(said tag_exists_verdict 0 404)" 'absent; exit 0'
eq 'tag_exists_verdict: 200 is present, 1 (refuse to push)' "$(said tag_exists_verdict 0 200)" 'present; exit 1'
eq 'tag_exists_verdict: 401 is unknown, 2' "$(said tag_exists_verdict 0 401)" 'unknown; exit 2'
eq 'tag_exists_verdict: 403 is unknown, 2 (ghcr.io answers denied for absent and private alike)' "$(said tag_exists_verdict 0 403)" 'unknown; exit 2'
eq 'tag_exists_verdict: 500 is unknown, 2' "$(said tag_exists_verdict 0 500)" 'unknown; exit 2'
eq 'tag_exists_verdict: 301 is unknown, 2' "$(said tag_exists_verdict 0 301)" 'unknown; exit 2'
eq 'tag_exists_verdict: a failed connection (curl 7, code 000) is unknown, 2' "$(said tag_exists_verdict 7 000)" 'unknown; exit 2'
eq 'tag_exists_verdict: a timeout (curl 28) is unknown, 2' "$(said tag_exists_verdict 28 000)" 'unknown; exit 2'
eq 'tag_exists_verdict: no code at all is unknown, 2' "$(said tag_exists_verdict 0 '')" 'unknown; exit 2'

# probe_tag <base url> <repo> <tag> [curl args...], through a stub curl on PATH
# that answers as `curl -sS -I -w '\n%{http_code}'` does: the headers, then the
# code on a line of its own, then CURL_STUB's exit status. The verdict is
# tag_exists_verdict's, so only a 404 lets the release workflow push.
cat > "$stub/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CURL_LOG"
code=${CURL_STUB% *}
[ "$code" = 000 ] || printf 'HTTP/2 %s \r\ncontent-type: application/json\r\n\r\n' "$code"
printf '\n%s' "$code"
exit "${CURL_STUB#* }"
EOF
chmod +x "$stub/curl"
CURL_LOG=$stub/curl.log; export CURL_LOG
PATH=$stub:$PATH
# shellcheck disable=SC2154  # probe_tag sets all four; the gate runs shellcheck without -x
probe() { # http code, curl exit status: the verdict, its status, the code and curl's status
  CURL_STUB="$1 $2"; export CURL_STUB
  probe_tag https://ghcr.io steven-cutting/knarr 0.1.0 -H 'Authorization: Bearer stub'
  printf '%s; %s; %s; %s\n' "$verdict" "$verdict_rc" "$code" "$curl_rc"
}
eq 'probe_tag: 404 is absent, 0 (the only verdict that pushes)' "$(probe 404 0)" 'absent; 0; 404; 0'
eq 'probe_tag: 200 is present, 1' "$(probe 200 0)" 'present; 1; 200; 0'
eq 'probe_tag: 403 is unknown, 2' "$(probe 403 0)" 'unknown; 2; 403; 0'
eq 'probe_tag: a failed connection (curl 7, code 000) is unknown, 2' "$(probe 000 7)" 'unknown; 2; 000; 7'
# Every probe above makes the same request; the log holds the last one's.
# shellcheck disable=SC2154  # manifest_accept is lib.sh's
eq 'probe_tag: one HEAD with the manifest Accept header and the extra curl args' "$(cat "$CURL_LOG")" \
  "$(lines -sS -I --max-time 20 -w '\n%{http_code}' -H "$manifest_accept" -H 'Authorization: Bearer stub' https://ghcr.io/v2/steven-cutting/knarr/manifests/0.1.0)"
PATH=${PATH#"$stub":}; unset CURL_STUB CURL_LOG

# ancestor_verdict <ref> <base>, first through a stub git on PATH. GIT_STUB
# picks the answer: ancestor, not-ancestor, unknown-ref (rev-parse fails) or
# error (merge-base fails with 128). A failed command is never read as
# "not an ancestor".
cat > "$stub/git" <<'EOF'
#!/bin/sh
case $1 in
  rev-parse)
    [ "$GIT_STUB" != unknown-ref ] || exit 1
    echo 0123456789abcdef0123456789abcdef01234567 ;;
  merge-base)
    case $GIT_STUB in ancestor) exit 0 ;; not-ancestor) exit 1 ;; *) echo 'fatal: stub' >&2; exit 128 ;; esac ;;
  *) echo "stub git: $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$stub/git"
real_git=$(command -v git)
PATH=$stub:$PATH; export GIT_STUB=ancestor
eq 'ancestor_verdict: an ancestor is ancestor, 0' "$(said ancestor_verdict v0.1.0 origin/main)" 'ancestor; exit 0'
GIT_STUB=not-ancestor
eq 'ancestor_verdict: not an ancestor is not-ancestor, 1' "$(said ancestor_verdict v0.1.0 origin/main)" 'not-ancestor; exit 1'
GIT_STUB=unknown-ref
eq 'ancestor_verdict: an unknown ref is unknown, 2' "$(said ancestor_verdict v9.9.9 origin/main)" 'unknown; exit 2'
GIT_STUB=error
eq 'ancestor_verdict: a failed merge-base is unknown, 2, not "not an ancestor"' "$(said ancestor_verdict v0.1.0 origin/main)" 'unknown; exit 2'
PATH=${PATH#"$stub":}; unset GIT_STUB

# Then on a throwaway repository with the real git, isolated from the user's
# configuration: an annotated tag on a side branch is not an ancestor of main
# until the branch is merged.
repo=$stub/repo
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null; export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
g() { "$real_git" -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
"$real_git" init -q -b main "$repo"
echo one > "$repo/f"; g add f; g commit -q -m one
g checkout -q -b side; echo two > "$repo/f"; g commit -q -am two; g tag -a v0.1.0 -m 'v0.1.0'
g checkout -q main
eq 'throwaway: an annotated tag on an unmerged branch is not-ancestor, 1' "$(cd "$repo" && said ancestor_verdict v0.1.0 main)" 'not-ancestor; exit 1'
g merge -q --no-ff -m merge side
eq 'throwaway: once merged it is ancestor, 0' "$(cd "$repo" && said ancestor_verdict v0.1.0 main)" 'ancestor; exit 0'
eq 'throwaway: the tag object itself is peeled to its commit' "$(cd "$repo" && said ancestor_verdict refs/tags/v0.1.0 main)" 'ancestor; exit 0'
eq 'throwaway: a missing tag is unknown, 2' "$(cd "$repo" && said ancestor_verdict v9.9.9 main)" 'unknown; exit 2'
eq 'throwaway: a missing base is unknown, 2' "$(cd "$repo" && said ancestor_verdict v0.1.0 nonexistent)" 'unknown; exit 2'
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

printf '%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
