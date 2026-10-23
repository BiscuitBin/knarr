#!/bin/sh
# Org-transfer ticket 03 evidence: whether the old URLs of knarr still reach
# the repository after the transfer. It records and does not judge: the web
# URL's status line and location header, then the old and the new git URLs'
# answers for HEAD and main, so a reader can see the two match. Read-only: one
# curl HEAD request and two git ls-remote calls. Needs curl, git and an SSH
# key GitHub accepts.
# Usage: sh redirect.sh <old owner> <new owner> > redirect.txt 2>&1
set -eu
old=${1:?usage: sh redirect.sh <old owner> <new owner>}
new=${2:?usage: sh redirect.sh <old owner> <new owner>}
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

tmp=$(mktemp -d) || fail 'mktemp failed'
trap 'rm -rf "${tmp:?}"' EXIT

c=$(curl --version) || fail 'curl --version failed'
c=$(printf '%s\n' "$c" | head -n 1)
g=$(git --version) || fail 'git --version failed'
printf 'date: %s\n%s\n%s\nold: %s/knarr\nnew: %s/knarr\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" "$c" "$g" "$old" "$new"

# The web URL: no redirect is followed, so the answer is the old URL's own.
url=https://github.com/$old/knarr
printf '\n== web: curl -sSI %s\n' "$url"
curl -sSI "$url" >"$tmp/head" 2>"$tmp/err" ||
  fail "curl $url: $(cat "$tmp/err")"
# GitHub ends the status line with a space after the code; the record drops it.
tr -d '\r' <"$tmp/head" >"$tmp/h"
sed -n '1s/[[:space:]]*$//p' "$tmp/h"
grep -i '^location:' "$tmp/h" || printf 'location: (none)\n'

# ls_remote <owner>: HEAD and main as the git URL under that owner answers.
ls_remote() {
  u=git@github.com:$1/knarr.git
  printf '\n== git: git ls-remote %s HEAD refs/heads/main\n' "$u"
  git ls-remote "$u" HEAD refs/heads/main >"$tmp/refs" 2>"$tmp/err" ||
    fail "git ls-remote $u: $(cat "$tmp/err")"
  cat "$tmp/refs"
  # GitHub says a repository moved on stderr, so a success keeps it too.
  if [ -s "$tmp/err" ]; then
    sed 's/^/stderr: /' "$tmp/err"
  fi
}
ls_remote "$old"
ls_remote "$new"

printf '\nredirect check complete\n'
