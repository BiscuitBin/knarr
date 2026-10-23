#!/bin/sh
# Org-transfer ticket 02 evidence: the settings of <owner>/knarr, read so that
# ticket 03 can read them again after the transfer and diff the two. It
# records and does not judge: each section is a GitHub answer, projected to
# the fields that describe the setting, and a 403 or 404 is recorded with
# GitHub's message rather than treated as a failure. Secrets and variables are
# recorded by name only. Read-only: every call is a gh GET. Needs an
# authenticated gh and jq.
# Usage: sh settings.sh <owner> > settings.txt 2>&1
# lib.sh sets status and tmp, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
set -eu
owner=${1:?usage: sh settings.sh <owner>}
repo=$owner/knarr
# shellcheck source=lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
header "repository: $repo"

get repository "repos/$repo" '{full_name, owner: .owner.login, owner_type: .owner.type,
  visibility, default_branch, archived, has_issues, has_projects, has_wiki, has_discussions,
  allow_merge_commit, allow_squash_merge, allow_rebase_merge, allow_auto_merge,
  allow_update_branch, delete_branch_on_merge, use_squash_pr_title_as_default,
  squash_merge_commit_title, squash_merge_commit_message,
  merge_commit_title, merge_commit_message, web_commit_signoff_required,
  topics: (.topics | sort), security_and_analysis}'
# Every later answer means something only if the repository itself answered.
[ "$status" = 200 ] || fail "repos/$repo answered $status, not 200"

get rulesets "repos/$repo/rulesets?per_page=100" \
  '[.[] | {name, target, enforcement, source_type}] | sort_by(.name)'
if [ "$status" = 200 ]; then
  ids=$(jq -r '.[].id' "$tmp/body") || fail 'reading ruleset ids failed'
  for id in $ids; do
    get "ruleset $id" "repos/$repo/rulesets/$id" '{name, target, enforcement,
      conditions, rules: (.rules | sort_by(.type)),
      bypass_actors: (.bypass_actors | sort_by(.actor_type, .actor_id))}'
  done
fi

get 'branch protection on main' "repos/$repo/branches/main/protection" \
  'scrub | if .required_status_checks then .required_status_checks.contexts |= sort else . end'

get 'release environment' "repos/$repo/environments/release" '{can_admins_bypass,
  deployment_branch_policy,
  protection_rules: [(.protection_rules // [])[] | {type, prevent_self_review, wait_timer,
    reviewers: (if .reviewers then [.reviewers[] | "\(.type):\(.reviewer.login // .reviewer.slug)"] | sort else null end)}]
  | sort_by(.type)}'
if [ "$status" = 200 ]; then
  custom=$(jq -r '.deployment_branch_policy.custom_branch_policies // false' "$tmp/body") ||
    fail 'reading the deployment branch policy failed'
  if [ "$custom" = true ]; then
    get 'release deployment branch and tag policies' \
      "repos/$repo/environments/release/deployment-branch-policies?per_page=100" \
      '[.branch_policies[] | "\(.type): \(.name)"] | sort | .[]'
  fi
fi

# Names only. The secrets endpoints never return a value; the variables
# endpoints do, and the projection drops it.
get 'repository secret names' "repos/$repo/actions/secrets?per_page=100" '[.secrets[].name] | sort | .[]'
get 'repository variable names' "repos/$repo/actions/variables?per_page=100" '[.variables[].name] | sort | .[]'
get 'release secret names' "repos/$repo/environments/release/secrets?per_page=100" '[.secrets[].name] | sort | .[]'
get 'release variable names' "repos/$repo/environments/release/variables?per_page=100" '[.variables[].name] | sort | .[]'

get 'actions permissions' "repos/$repo/actions/permissions" scrub
if [ "$status" = 200 ]; then
  allowed=$(jq -r '.allowed_actions // ""' "$tmp/body") || fail 'reading allowed_actions failed'
  if [ "$allowed" = selected ]; then
    get 'allowed actions' "repos/$repo/actions/permissions/selected-actions" \
      'scrub | .patterns_allowed |= sort'
  fi
fi
get 'default workflow permissions' "repos/$repo/actions/permissions/workflow" scrub

# Secret scanning and push protection are in security_and_analysis above.
get 'private vulnerability reporting' "repos/$repo/private-vulnerability-reporting" scrub
get 'dependabot alerts (204 on, 404 off)' "repos/$repo/vulnerability-alerts" scrub
get 'dependabot security updates' "repos/$repo/automated-security-fixes" scrub
get 'code scanning default setup' "repos/$repo/code-scanning/default-setup" \
  'scrub | .languages |= sort'

# No token gh holds can list every app on a repository. The org listing
# answers for an org owner (404 for a user account); the user listing answers
# only to a GitHub App's user token, and its status records that.
get 'app installations on the owner' "orgs/$owner/installations?per_page=100" \
  '[.installations[] | "\(.app_slug): \(.repository_selection)"] | sort | .[]'
get 'app installations the user can reach' 'user/installations?per_page=100' \
  '[.installations[] | "\(.app_slug) on \(.account.login): \(.repository_selection)"] | sort | .[]'
if [ "$status" = 200 ]; then
  pairs=$(jq -r '.installations[] | select(.repository_selection == "selected") | "\(.id):\(.app_slug)"' "$tmp/body") ||
    fail 'reading installations failed'
  # Owner logins are case-insensitive, and GitHub answers with the canonical case (BiscuitBin).
  for pair in $pairs; do
    get "app ${pair#*:}: does it reach $repo" "user/installations/${pair%%:*}/repositories?per_page=100" \
      "if any(.repositories[].full_name; ascii_downcase == (\"$repo\" | ascii_downcase)) then \"yes\" else \"no\" end"
  done
fi

get labels "repos/$repo/labels?per_page=100" '[.[].name] | sort | .[]'

echo
echo 'snapshot complete'
