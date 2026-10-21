#!/bin/sh
# Ticket 40 evidence, copied from ticket 37's settings.sh with its tag
# expectation changed: the repository settings the MVP release rests on, read
# before the tag is pushed. It prints the release environment as GitHub
# returns it, and fails unless ticket 36's environment is unchanged: the same
# id, one required-reviewers rule whose one reviewer is the maintainer, and
# "Prevent self-review" off. Without an argument it expects no ruleset; with
# the id of the v* tag ruleset it expects that one ruleset and prints it whole,
# since the list endpoint returns only summaries. Either way it expects exactly
# the tag v0.1.0, ticket 37's, and no GitHub release. Read-only: every call is a gh GET. Needs an authenticated gh.
# Usage: sh settings.sh [ruleset-id] > settings.txt 2>&1
set -eu
ruleset=${1:-}
repo=steven-cutting/knarr
env_id=23921538204 # ticket 36 created it on 2026-10-09
maintainer=8365892 # steven-cutting
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
stamp() { printf 'read at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
# A command substitution's failure does not stop `set -e` when it is an
# argument, so every read is assigned first and checked.
v=$(gh --version | head -n 1) || fail 'gh --version failed'
printf 'date: %s\n%s\nrepository: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$v" "$repo"

echo; echo "== the release environment: gh api repos/$repo/environments/release"
stamp
raw=$(gh api "repos/$repo/environments/release") || fail 'reading the environment failed'
printf '%s\n' "$raw"
echo
v=$(gh api "repos/$repo/environments/release" --jq '.id') || fail 'reading the environment failed'
expect 'environment id' "$v" "$env_id"
v=$(gh api "repos/$repo/environments/release" --jq '[.protection_rules[].type] | join(",")') || fail 'reading the environment failed'
expect 'protection rules' "$v" required_reviewers
v=$(gh api "repos/$repo/environments/release" \
  --jq '.protection_rules[] | select(.type == "required_reviewers") | [.reviewers[] | "\(.type):\(.reviewer.id)"] | join(",")') ||
  fail 'reading the environment failed'
expect 'required reviewers' "$v" "User:$maintainer"
v=$(gh api "repos/$repo/environments/release" \
  --jq '.protection_rules[] | select(.type == "required_reviewers") | .prevent_self_review | tostring') ||
  fail 'reading the environment failed'
expect 'prevent self-review' "$v" false
v=$(gh api "repos/$repo/environments/release" --jq '[.can_admins_bypass, .deployment_branch_policy] | map(tostring) | join(" ")') ||
  fail 'reading the environment failed'
printf 'info can_admins_bypass, deployment_branch_policy: %s (GitHub defaults; 0012 decides neither)\n' "$v"

echo; echo "== rulesets: gh api repos/$repo/rulesets"
stamp
raw=$(gh api "repos/$repo/rulesets") || fail 'reading rulesets failed'
printf '%s\n' "$raw"
echo
if [ -z "$ruleset" ]; then
  v=$(gh api "repos/$repo/rulesets" --jq length) || fail 'reading rulesets failed'
  expect rulesets "$v" 0
else
  v=$(gh api "repos/$repo/rulesets" --jq '[.[].id | tostring] | join(",")') || fail 'reading rulesets failed'
  expect 'ruleset ids' "$v" "$ruleset"
  echo; echo "== the tag ruleset: gh api repos/$repo/rulesets/$ruleset"
  stamp
  raw=$(gh api "repos/$repo/rulesets/$ruleset") || fail 'reading the ruleset failed'
  printf '%s\n' "$raw"
  echo
  v=$(gh api "repos/$repo/rulesets/$ruleset" --jq '[.name, .target, .enforcement] | join(" | ")') || fail 'reading the ruleset failed'
  expect 'name, target, enforcement' "$v" 'release tags | tag | active'
  v=$(gh api "repos/$repo/rulesets/$ruleset" --jq '.conditions.ref_name | "include=\(.include | join(",")) exclude=\(.exclude | join(","))"') ||
    fail 'reading the ruleset failed'
  expect 'ref names' "$v" 'include=refs/tags/v* exclude='
  v=$(gh api "repos/$repo/rulesets/$ruleset" --jq '[.rules[].type] | sort | join(",")') || fail 'reading the ruleset failed'
  expect rules "$v" deletion,update
  v=$(gh api "repos/$repo/rulesets/$ruleset" --jq '.bypass_actors | length') || fail 'reading the ruleset failed'
  expect 'bypass actors' "$v" 0
fi

echo; echo "== tags and releases"
stamp
v=$(gh api "repos/$repo/tags" --jq '[.[].name] | join(",")') || fail 'reading tags failed'
expect tags "$v" v0.1.0
v=$(gh api "repos/$repo/releases" --jq length) || fail 'reading releases failed'
expect releases "$v" 0
echo; echo 'settings as expected'
