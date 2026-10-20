#!/bin/sh
# Tests for preflight.sh, offline, in the style of lib_test.sh beside it;
# test_release_lib.py runs this file in `just test-checkers-selected release`.
# Each case builds a throwaway repository from the tracked chart and release
# scripts, with a gleam.toml, a CHANGELOG.md and an origin/main ref, and runs
# the preflight in it with the real git, isolated from the user's
# configuration. The passing commit is checked first, then each guard the
# release would fail on: a tag that disagrees with gleam.toml, a commit main
# does not carry, a missing or stale changelog heading, a chart that disagrees
# with the version, a local tag that already exists, and a missing commit.
# Needs helm (the default pixi environment).
# Usage: sh scripts/release/preflight_test.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
preflight=$here/preflight.sh
pass=0; failed=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { failed=$((failed + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
eq() { # description, actual, expected
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got '$2', want '$3'"; fi
}
has() { # description, text, line that must appear in it exactly
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1" "no line '$3' in: $(printf '%s' "$2" | tail -c 600)"; fi
}

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null; export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
today=$(date -u +%Y-%m-%d)

# fixture <dir> <gleam version> <chart version> <changelog heading line>:
# a repository whose one commit is main and origin/main.
fixture() {
  r=$1
  git init -q -b main "$r"
  mkdir -p "$r/charts" "$r/scripts"
  cp -R "$root/charts/knarr" "$r/charts/knarr"
  cp -R "$root/scripts/release" "$r/scripts/release"
  sed -e "s/^version: .*/version: $3/" -e "s/^appVersion: .*/appVersion: \"$3\"/" "$root/charts/knarr/Chart.yaml" > "$r/charts/knarr/Chart.yaml"
  printf 'name = "knarr"\nversion = "%s"\n' "$2" > "$r/gleam.toml"
  printf '# Changelog\n\n## [Unreleased]\n\n%s\n\n### Added\n\n- Something.\n' "$4" > "$r/CHANGELOG.md"
  g "$r" add -A
  g "$r" commit -q -m release
  g "$r" update-ref refs/remotes/origin/main HEAD
}
g() { r=$1; shift; git -C "$r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
run() { # repo, preflight arguments...: sets out and rc
  r=$1; shift
  rc=0; out=$(cd "$r" && sh "$preflight" "$@" 2>&1) || rc=$?
}

# The passing commit: every guard passes, and the tag set is printed.
good=$work/good
fixture "$good" 0.2.0 0.2.0 "## [0.2.0] - $today"
head=$(git -C "$good" rev-parse HEAD)
run "$good" v0.2.0 "$head"
eq 'pass: a matching tag, version, chart and heading dated today exit 0' "$rc" 0
has 'pass: names the commit' "$out" "commit: $head"
has 'pass: the version is the tag'"'"'s' "$out" 'toml_version: 0.2.0'
has 'pass: origin/main carries it' "$out" "ancestor_verdict $(printf '%s' "$head" | cut -c1-7) origin/main: ancestor (0)"
has 'pass: the heading is dated today (UTC)' "$out" "changelog heading: ## [0.2.0] - $today"
has 'pass: the chart stamps and packages' "$out" 'stamp-chart: knarr-0.2.0.tgz'
has 'pass: the tag set lists X.Y.Z' "$out" '  0.2.0'
has 'pass: the tag set lists X.Y' "$out" '  0.2'
has 'pass: the tag set lists sha-<7>' "$out" "  sha-$(printf '%s' "$head" | cut -c1-7)"
has 'pass: the last line says what to tag' "$out" "preflight passed: tag $head as v0.2.0"
eq 'pass: the worktree is unchanged' "$(git -C "$good" status --porcelain)" ''
eq 'pass: no tag was made' "$(git -C "$good" tag -l)" ''

# A tag that disagrees with gleam.toml.
run "$good" v0.3.0 "$head"
eq 'refused: a tag that disagrees with gleam.toml' "$rc" 1
has 'refused: says the tag does not match' "$out" 'FAIL: tag v0.3.0 does not match gleam.toml version 0.2.0'

# A commit origin/main does not carry.
g "$good" checkout -q -b side
echo side > "$good/side"; g "$good" add side; g "$good" commit -q -m side
side=$(git -C "$good" rev-parse HEAD)
g "$good" checkout -q main
run "$good" v0.2.0 "$side"
eq 'refused: a commit origin/main does not carry' "$rc" 1
has 'refused: says it is not an ancestor' "$out" "FAIL: the ancestry of $side against origin/main is not-ancestor"

# A changelog with no heading for the version.
none=$work/none
fixture "$none" 0.2.0 0.2.0 '## [0.1.0] - 2026-10-14'
run "$none" v0.2.0 "$(git -C "$none" rev-parse HEAD)"
eq 'refused: no changelog heading for the version' "$rc" 1
has 'refused: says the heading is missing' "$out" "FAIL: CHANGELOG.md has no '## [0.2.0] - YYYY-MM-DD' heading"

# A heading dated another day: the tag is pushed on the heading's UTC day.
stale=$work/stale
fixture "$stale" 0.2.0 0.2.0 '## [0.2.0] - 2000-01-01'
run "$stale" v0.2.0 "$(git -C "$stale" rev-parse HEAD)"
eq 'refused: a heading not dated today (UTC)' "$rc" 1
has 'refused: says which day it should be' "$out" "FAIL: the heading is dated 2000-01-01, and today (UTC) is $today"

# A chart that disagrees with the version: publish's first stamp would refuse.
skew=$work/skew
fixture "$skew" 0.2.0 0.1.0 "## [0.2.0] - $today"
run "$skew" v0.2.0 "$(git -C "$skew" rev-parse HEAD)"
eq 'refused: a Chart.yaml that disagrees with the version' "$rc" 1
has 'refused: says the stamp refused' "$out" 'FAIL: stamp-chart.sh refused the chart at this commit'

# A local tag of that name, which a push would send instead.
g "$good" tag -a v0.2.0 -m v0.2.0 "$head"
run "$good" v0.2.0 "$head"
eq 'refused: a local tag that already exists' "$rc" 1
has 'refused: says the tag exists' "$out" 'FAIL: a local v0.2.0 already exists'
g "$good" tag -d v0.2.0 > /dev/null

# A commit that does not exist, and a missing argument.
run "$good" v0.2.0 0123456789abcdef0123456789abcdef01234567
eq 'refused: a commit that does not exist' "$rc" 1
has 'refused: says it is not a commit' "$out" 'FAIL: 0123456789abcdef0123456789abcdef01234567 is not a commit here'
run "$good" v0.2.0
eq 'refused: a missing argument' "$rc" 2
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

printf '%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
