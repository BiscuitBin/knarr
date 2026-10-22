# The release guards (Decision 0012), sourced by .github/workflows/release.yml
# and preflight.sh; not run on its own. Moved from ticket 28's evidence, where
# the dry run exercised them against a throwaway registry and ghcr.io.
# lib_test.sh beside it tests every helper offline, probe_tag through a stub
# curl, and runs in `just test-checkers-selected release`.
#
#   version_of_tag <tag>       v0.1.0 -> 0.1.0; the one prerelease form is
#                              -rc.N (N without a leading zero); anything else
#                              fails (1)
#   tags_for <tag> <sha>       the image tags one release pushes, one per line:
#                              X.Y.Z, X.Y, X (major > 0 only), sha-<7>; a
#                              prerelease gets only X.Y.Z-rc.N and sha-<7>;
#                              never latest
#   toml_version               gleam.toml on stdin: its one top-level version
#   tag_matches_version <tag> <version>
#                              0 match, 1 mismatch, 2 malformed
#   changelog_has_version <version>
#                              CHANGELOG.md on stdin: a line that is exactly
#                              "## [<version>] - YYYY-MM-DD"
#   changelog_date <version>   CHANGELOG.md on stdin: the date of the first
#                              such line; fails (1) when there is none
#   digest_of_headers          `curl -sI` output on stdin: Docker-Content-Digest
#   digest_of_metadata         buildx --metadata-file JSON on stdin
#   digest_of_inspect          `buildx imagetools inspect` output on stdin
#   tag_exists_verdict <curl status> <http code>
#                              absent (0) only on 404; present (1) on 200;
#                              unknown (2) for anything else: fail closed
#   probe_tag <base url> <repo> <tag> [curl args...]
#                              the HEAD request, then tag_exists_verdict; sets
#                              verdict, verdict_rc, code and curl_rc in the
#                              caller (no subshell, so the caller can show them)
#   ancestor_verdict <ref> <base>
#                              ancestor (0), not-ancestor (1), unknown (2)

# This file is sourced, so it has no shebang. shellcheck 0.11.0 misreads a
# function called inside a pipeline or an arithmetic expansion as defined later
# (SC2218, as in 15); every function here is defined before its use.
# shellcheck shell=sh disable=SC2218

digest_re='sha256:[0-9a-f]{64}'
# Without an Accept header that lists the modern media types, registry:2
# answers a HEAD with a schema1 digest that matches nothing buildx reports.
manifest_accept='Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

version_of_tag() { # tag
  printf '%s\n' "${1:-}" | grep -qE '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$' || return 1
  printf '%s\n' "${1#v}"
}

tags_for() { # tag, commit sha (7 to 40 hex)
  v=$(version_of_tag "$1") || return 1
  printf '%s\n' "${2:-}" | grep -qE '^[0-9a-f]{7,40}$' || return 1
  printf '%s\n' "$v"
  case $v in
    *-*) ;; # a prerelease gets no floating tag
    *)
      major=${v%%.*}; rest=${v#*.}; minor=${rest%%.*}
      printf '%s.%s\n' "$major" "$minor"
      [ "$major" = 0 ] || printf '%s\n' "$major" ;;
  esac
  printf 'sha-%s\n' "$(printf '%s' "$2" | cut -c1-7)"
}

toml_version() { # gleam.toml on stdin
  tv=$(grep -E '^version = "[^"]+"$' | sed -E 's/^version = "([^"]+)"$/\1/')
  [ -n "$tv" ] || { echo 'toml_version: no top-level version line' >&2; return 1; }
  [ "$(printf '%s\n' "$tv" | wc -l | tr -d ' ')" -eq 1 ] || { echo 'toml_version: more than one version line' >&2; return 1; }
  printf '%s\n' "$tv"
}

tag_matches_version() { # tag, version
  tmv=$(version_of_tag "$1") || return 2
  [ -n "${2:-}" ] || return 2
  [ "$tmv" = "$2" ]
}

changelog_has_version() { # version; CHANGELOG.md on stdin
  changelog_date "$1" > /dev/null
}
changelog_date() { # version; CHANGELOG.md on stdin: the release heading's date
  # The literal prefix through index (dots are not wildcards), then a date and
  # nothing after it. The digit classes are spelled out: mawk and BSD awk
  # disagree on {4} intervals. The first such heading wins.
  awk -v v="$1" '
    BEGIN { p = "## [" v "] - " }
    !found && index($0, p) == 1 && substr($0, length(p) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { found = 1; print substr($0, length(p) + 1) }
    END { exit !found }'
}

digest_of_headers() { # `curl -sI` output on stdin
  d=$(tr -d '\r' | grep -iE "^docker-content-digest: *$digest_re *$" | head -1 | sed -E 's/^[^:]*: *//; s/ *$//')
  [ -n "$d" ] && printf '%s\n' "$d"
}
digest_of_metadata() { # buildx --metadata-file JSON on stdin
  perl -0777 -ne 'if (/"containerimage\.digest"\s*:\s*"(sha256:[0-9a-f]{64})"/) { print "$1\n"; exit 0 } exit 1'
}
digest_of_inspect() { # `docker buildx imagetools inspect` output on stdin
  d=$(grep -E "^Digest: *$digest_re *$" | head -1 | sed -E 's/^Digest: *//; s/ *$//')
  [ -n "$d" ] && printf '%s\n' "$d"
}

tag_exists_verdict() { # curl exit status, http code
  if [ "${1:-}" = 0 ]; then
    case ${2:-} in
      404) echo absent; return 0 ;;
      200) echo present; return 1 ;;
    esac
  fi
  echo unknown; return 2
}
# The HEAD request behind probe_tag. Prints the headers; the status code goes
# to $code and curl's status to $curl_rc, never to set -e.
registry_head() { # base url, repo, ref, [curl args...]
  rh_base=$1; rh_repo=$2; rh_ref=$3; shift 3
  curl_rc=0; code=''
  out=$(curl -sS -I --max-time 20 -w '\n%{http_code}' -H "$manifest_accept" "$@" "$rh_base/v2/$rh_repo/manifests/$rh_ref" 2> /dev/null) || curl_rc=$?
  code=$(printf '%s\n' "$out" | tail -1)
  printf '%s\n' "$out" | sed '$d'
}
probe_tag() { # base url, repo, tag, [curl args...]
  registry_head "$@" > /dev/null
  # shellcheck disable=SC2034  # both are read by the caller
  verdict_rc=0
  # shellcheck disable=SC2034
  verdict=$(tag_exists_verdict "$curl_rc" "$code") || verdict_rc=$?
}

ancestor_verdict() { # ref, base
  c=$(git rev-parse --verify --quiet "$1^{commit}" 2> /dev/null) || { echo unknown; return 2; }
  b=$(git rev-parse --verify --quiet "$2^{commit}" 2> /dev/null) || { echo unknown; return 2; }
  av=0; git merge-base --is-ancestor "$c" "$b" 2> /dev/null || av=$?
  case $av in
    0) echo ancestor; return 0 ;;
    1) echo not-ancestor; return 1 ;;
    *) echo unknown; return 2 ;;
  esac
}
