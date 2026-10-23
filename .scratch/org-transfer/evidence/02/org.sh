#!/bin/sh
# Org-transfer ticket 02 evidence: what the API shows of the org knarr moves
# to, read before the transfer. It records and does not judge, as settings.sh
# does: the maintainer's membership, the org's base permissions and two-factor
# requirement, its Actions policy and default workflow permissions, its
# rulesets and its app installations. Last, read from this worktree with no
# network, the actions knarr's workflows use, for comparison with the policy.
# What the API does not show, the maintainer reads in the UI, and org.txt
# records it below this script's output. Read-only: every call is a gh GET.
# Needs an authenticated gh, with read:org for the installations, and jq.
# Usage: sh org.sh <org> > org.txt 2>&1
# lib.sh sets status and tmp, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
set -eu
org=${1:?usage: sh org.sh <org>}
# shellcheck source=lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || fail 'not in a git worktree'
header "org: $org"

get 'authenticated user' user .login
[ "$status" = 200 ] || fail 'reading the authenticated user failed'
me=$(jq -r .login "$tmp/body") || fail 'reading the login failed'

get membership "orgs/$org/memberships/$me" '{role, state}'

# members_can_create_public_packages is not a documented field; the package
# keys are kept if GitHub returns any, and the UI answers otherwise.
get org "orgs/$org" '{login, plan: .plan.name, two_factor_requirement_enabled,
  default_repository_permission, members_can_create_repositories,
  members_can_create_public_repositories, members_can_create_private_repositories,
  web_commit_signoff_required} + with_entries(select(.key | test("package")))'
[ "$status" = 200 ] || fail "orgs/$org answered $status, not 200"

get 'actions permissions' "orgs/$org/actions/permissions" scrub
if [ "$status" = 200 ]; then
  allowed=$(jq -r '.allowed_actions // ""' "$tmp/body") || fail 'reading allowed_actions failed'
  if [ "$allowed" = selected ]; then
    get 'allowed actions' "orgs/$org/actions/permissions/selected-actions" \
      'scrub | .patterns_allowed |= sort'
  fi
fi
get 'default workflow permissions' "orgs/$org/actions/permissions/workflow" scrub

get rulesets "orgs/$org/rulesets?per_page=100" \
  '[.[] | {name, target, enforcement, source_type}] | sort_by(.name)'

get 'app installations' "orgs/$org/installations?per_page=100" \
  '[.installations[] | "\(.app_slug): \(.repository_selection)"] | sort | .[]'

printf '\n== actions the workflows use: .github/workflows/ and .github/actions/, read from %s\n' \
  "$(git -C "$root" rev-parse --short HEAD)"
# A pipeline's status is its last command's, so grep is read and checked alone.
v=$(grep -rhoE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]]+([[:space:]]*#.*)?' \
  "$root/.github/workflows" "$root/.github/actions") || fail 'reading the workflows failed'
v=$(printf '%s\n' "$v" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' | sort -u) ||
  fail 'listing the actions failed'
printf '%s\n' "$v"

echo
echo 'org read complete'
