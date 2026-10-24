#!/bin/sh
# Org transfer ticket 05 evidence, adapted from bootstrap ticket 40's
# settings.sh. Two modes.
# `before` reads the repository settings the first release under the org
# rests on, before the tag is pushed. It prints the release environment as
# GitHub returns it, and fails unless ticket 36's environment carried over the
# transfer unchanged (org transfer ticket 03's settings.diff): the same id, one
# required-reviewers rule whose one reviewer is the maintainer, and "Prevent
# self-review" off. It expects the one v* tag ruleset by its id and prints it
# whole, since the list endpoint returns only summaries. The list leaves out
# the org's own rulesets, which 40's personal repository had none of. It expects exactly the
# tags v0.1.0 and v0.2.0 and no GitHub release.
# `packages` reads the two packages the first push created, after the run:
# each must be public and linked to the repository. It prints each package as
# GitHub returns it.
# Changed from 40's: the repository is biscuitbin/knarr, the ruleset id is
# required, the tags expected are v0.1.0 and v0.2.0, and the packages mode is
# new. Read-only: every call is a gh GET. Needs an authenticated gh; the
# packages mode needs a token with read:packages.
# Usage: sh settings.sh before <ruleset-id> > settings.txt 2>&1
#        sh settings.sh packages > packages.txt 2>&1
set -eu
usage='usage: settings.sh before <ruleset-id> | settings.sh packages'
mode=${1:?$usage}
repo=biscuitbin/knarr
org=biscuitbin
env_id=23921538204 # ticket 36 created it on 2026-10-09; it carried over the transfer
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

case $mode in
  before) ruleset=${2:?$usage} ;;
  packages)
    # GitHub answers with the org's canonical login, BiscuitBin (ticket 03).
    for name in knarr charts%2Fknarr; do
      echo; echo "== the package: gh api orgs/$org/packages/container/$name"
      stamp
      raw=$(gh api "orgs/$org/packages/container/$name") || fail "reading package $name failed"
      printf '%s\n' "$raw"
      echo
      # Read from the one answer printed above, not a second GET.
      v=$(printf '%s' "$raw" | python3 -c '
import json, sys
p = json.load(sys.stdin)
print(" | ".join([p["name"], p["visibility"], (p.get("repository") or {}).get("full_name", "none")]))') ||
        fail "reading package $name's answer failed"
      expect "package name, visibility, repository" "$v" "$(printf '%s' "$name" | sed 's/%2F/\//') | public | BiscuitBin/knarr"
    done
    echo; echo 'packages as expected'
    exit 0
    ;;
  *) fail "$usage" ;;
esac

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

echo; echo "== rulesets: gh api repos/$repo/rulesets?includes_parents=false"
stamp
raw=$(gh api "repos/$repo/rulesets?includes_parents=false") || fail 'reading rulesets failed'
printf '%s\n' "$raw"
echo
v=$(gh api "repos/$repo/rulesets?includes_parents=false" --jq '[.[].id | tostring] | join(",")') || fail 'reading rulesets failed'
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

echo; echo "== tags and releases"
stamp
v=$(gh api "repos/$repo/tags" --jq '[.[].name] | sort | join(",")') || fail 'reading tags failed'
expect tags "$v" v0.1.0,v0.2.0
v=$(gh api "repos/$repo/releases" --jq length) || fail 'reading releases failed'
expect releases "$v" 0
echo; echo 'settings as expected'
