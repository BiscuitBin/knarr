#!/bin/sh
# Run release.yml's verify guards, and publish's first chart stamp, offline on
# the commit about to be tagged, before the tag exists. The v* tag ruleset
# makes a pushed tag permanent, so a wrong commit would burn the version.
# Promoted from ticket 37's evidence (.scratch/bootstrap/evidence/37/
# preflight.sh) by ticket 40. The guards are lib.sh's, called as verify calls
# them, but they read gleam.toml and CHANGELOG.md from the commit with
# git show instead of a checkout; the chart and stamp-chart.sh are the
# commit's own, from git archive, stamped with an all-zero placeholder digest
# as publish does before it pushes anything. It also refuses a changelog
# heading not dated today (UTC): the heading names the day the tag is pushed.
# It runs in the repository at the current directory, and origin/main is
# whatever the last git fetch left. preflight_test.sh beside it tests it
# offline. Nothing is tagged or pushed.
# Needs git, helm, perl, sed and grep.
# Usage: sh scripts/release/preflight.sh <tag> <merge-commit-sha>
# Exits 0 when every guard passes, 1 on a guard the run would fail, 2 on usage.
set -eu
[ "$#" -eq 2 ] || { echo 'usage: preflight.sh <tag> <merge-commit-sha>' >&2; exit 2; }
tag=$1; commit=$2
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=lib.sh disable=SC1091  # the gate runs without -x
. "$here/lib.sh"
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
image=ghcr.io/biscuitbin/knarr
placeholder=sha256:0000000000000000000000000000000000000000000000000000000000000000
today=$(date -u +%Y-%m-%d)

printf 'date: %s\ntag: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$tag"
full=$(git rev-parse --verify --quiet "$commit^{commit}") || fail "$commit is not a commit here"
printf 'commit: %s\n' "$full"
git log -1 --format='parents: %P%nsubject: %s%ncommitted: %cI' "$full"
main=$(git rev-parse --verify --quiet 'origin/main^{commit}') || fail 'no origin/main'
printf 'origin/main: %s\n' "$main"
[ "$main" = "$full" ] && echo 'origin/main is this commit' ||
  echo 'info origin/main is not this commit; the ancestry guard below decides'
# A local tag of this name would be pushed instead of the one about to be made.
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
dated=$(printf '%s\n' "$changelog" | changelog_date "$version") || fail 'changelog_date failed'
printf 'changelog heading: ## [%s] - %s\n' "$version" "$dated"
[ "$dated" = "$today" ] || fail "the heading is dated $dated, and today (UTC) is $today"

echo; echo '== the chart, as publish stamps it first'
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
git archive "$full" charts/knarr scripts/release | tar -x -C "$work" || fail 'git archive of the chart and the release scripts failed'
mkdir "$work/out"
package=$(sh "$work/scripts/release/stamp-chart.sh" "$work/charts/knarr" "$version" "$image" "$placeholder" "$work/out") ||
  fail 'stamp-chart.sh refused the chart at this commit'
printf 'stamp-chart: %s\n' "$(basename "$package")"

echo; echo "tags_for $tag:"
tags_for "$tag" "$full" | sed 's/^/  /'
echo; echo "preflight passed: tag $full as $tag"
