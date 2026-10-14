#!/bin/sh
# Ticket 37 evidence: release.yml's verify guards, run offline on the commit
# the maintainer is about to tag, before the tag exists. Once the v* ruleset
# is active, v0.1.0 cannot move or be deleted, so a wrong commit would burn
# the version. The guards are lib.sh's, called as verify calls them, but they
# read gleam.toml and CHANGELOG.md from the commit with git show instead of a
# checkout. origin/main is whatever the last authorized git fetch left.
# Exits non-zero on any guard that would fail the run.
# Usage: sh preflight.sh <merge-commit-sha> > preflight.txt 2>&1
set -eu
commit=${1:?usage: preflight.sh <merge-commit-sha>}
tag=v0.1.0
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(git -C "$here" rev-parse --show-toplevel)
# shellcheck source=../../../../scripts/release/lib.sh disable=SC1091  # the gate runs without -x
. "$root/scripts/release/lib.sh"
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
cd "$root"
printf 'date: %s\ntag: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$tag"
full=$(git rev-parse --verify --quiet "$commit^{commit}") || fail "$commit is not a commit here"
printf 'commit: %s\n' "$full"
git log -1 --format='parents: %P%nsubject: %s%ncommitted: %cI' "$full"
main=$(git rev-parse --verify --quiet 'origin/main^{commit}') || fail 'no origin/main'
printf 'origin/main: %s\n' "$main"
[ "$main" = "$full" ] && echo 'origin/main is this commit' ||
  echo 'info origin/main is not this commit; the ancestry guard below decides'
# A local v0.1.0 would be pushed instead of the one about to be made.
if git rev-parse --verify --quiet "refs/tags/$tag" > /dev/null; then fail "a local $tag already exists"; fi
echo "no local $tag"

echo; echo '== the guards, as verify runs them'
toml=$(git show "$full:gleam.toml") || fail 'reading gleam.toml failed'
version=$(printf '%s\n' "$toml" | toml_version) || fail 'toml_version failed'
printf 'toml_version: %s\n' "$version"
rc=0; tag_matches_version "$tag" "$version" || rc=$?
printf 'tag_matches_version %s %s: %s\n' "$tag" "$version" "$rc"
[ "$rc" = 0 ] || fail "tag $tag does not match gleam.toml version $version"
rc=0; verdict=$(ancestor_verdict "$full" origin/main) || rc=$?
printf 'ancestor_verdict %s origin/main: %s (%s)\n' "$(printf '%s' "$full" | cut -c1-7)" "$verdict" "$rc"
[ "$rc" = 0 ] || fail "the ancestry of $full against origin/main is $verdict"
changelog=$(git show "$full:CHANGELOG.md") || fail 'reading CHANGELOG.md failed'
rc=0; printf '%s\n' "$changelog" | changelog_has_version "$version" || rc=$?
printf 'changelog_has_version %s: %s\n' "$version" "$rc"
[ "$rc" = 0 ] || fail "CHANGELOG.md has no '## [$version] - YYYY-MM-DD' heading"
printf '%s\n' "$changelog" | grep -nE '^## '
echo; echo "tags_for $tag:"
tags_for "$tag" "$full" | sed 's/^/  /'
echo; echo "preflight passed: tag $full as $tag"
