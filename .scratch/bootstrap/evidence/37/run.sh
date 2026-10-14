#!/bin/sh
# Ticket 37 evidence: the first live run of release.yml, read back with gh.
# It prints the run and its jobs, who approved the release environment, and
# the lines of each job's log that the hand-back cites: verify's guard line,
# the existence guard's verdict, the build's pushes and the digest. It ends
# with the git tag as this clone and the remote hold it. It fails unless the
# run was the v0.1.0 push at the expected commit and both jobs succeeded. It
# prints no whole log and no token. gh and git ls-remote read only. Needs an
# authenticated gh and the local v0.1.0 the maintainer pushed.
# Usage: sh run.sh <run-id> > run.txt 2>&1
set -eu
run=${1:?usage: run.sh <run-id>}
repo=steven-cutting/knarr
tag=v0.1.0
commit=283a7d489d07d81bd3a9c393ce10be11ad71303f # PR #33's merge commit
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
job() { # name: the job's id, or a failure
  id=$(gh run view "$run" -R "$repo" --json jobs --jq ".jobs[] | select(.name == \"$1\") | .databaseId") ||
    fail "reading run $run failed"
  [ -n "$id" ] || fail "run $run has no $1 job"
  echo "$id"
}
# gh prints each log line as job<TAB>step<TAB>timestamp text. The log is read
# whole before it is filtered, so a failed or empty read fails the script
# instead of printing an empty section. grep finding no line is not a failure.
lines() { # job-id pattern: the job's log lines that match, without gh's prefix
  log=$(gh run view "$run" -R "$repo" --log --job "$1") || fail "reading job $1's log failed"
  [ -n "$log" ] || fail "job $1 has an empty log"
  printf '%s\n' "$log" | sed -n 's/^[^	]*	[^	]*	[^ ]* //p' | { grep -E "$2" || [ "$?" -eq 1 ]; }
}
v=$(gh --version | head -n 1) || fail 'gh --version failed'
printf 'date: %s\n%s\nrepository: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$v" "$repo"

echo; echo "== run $run"
v=$(gh run view "$run" -R "$repo" --json url,event,headBranch,headSha,createdAt,status,conclusion,workflowName \
  --jq '[.url, .workflowName, .event, .headBranch, .headSha, .createdAt, .status, .conclusion] | join("\n")') ||
  fail "reading run $run failed"
printf 'url: %s\n' "$(printf '%s\n' "$v" | sed -n 1p)"
printf 'created: %s\n' "$(printf '%s\n' "$v" | sed -n 6p)"
expect workflow "$(printf '%s\n' "$v" | sed -n 2p)" Release
expect event "$(printf '%s\n' "$v" | sed -n 3p)" push
expect ref "$(printf '%s\n' "$v" | sed -n 4p)" "$tag"
expect 'head sha' "$(printf '%s\n' "$v" | sed -n 5p)" "$commit"
expect 'status, conclusion' "$(printf '%s\n' "$v" | sed -n 7,8p | paste -s -d ' ' -)" 'completed success'
echo '-- jobs'
gh run view "$run" -R "$repo" --json jobs \
  --jq '.jobs[] | "\(.name): \(.conclusion), \(.startedAt) to \(.completedAt)"' || fail "reading run $run failed"
v=$(gh run view "$run" -R "$repo" --json jobs --jq '[.jobs[] | "\(.name)=\(.conclusion)"] | sort | join(", ")') ||
  fail "reading run $run failed"
expect 'job conclusions' "$v" 'Publish to ghcr.io=success, Verify the tag=success'

echo; echo "== the release environment's approval: gh api repos/$repo/actions/runs/$run/approvals"
v=$(gh api "repos/$repo/actions/runs/$run/approvals" \
  --jq '.[] | "\(.state) by \(.user.login) (user \(.user.id)) for \([.environments[] | "\(.name) (\(.id))"] | join(", ")), comment: \(.comment | tojson)"') ||
  fail 'reading the approvals failed'
printf '%s\n' "$v"
v=$(gh api "repos/$repo/actions/runs/$run/approvals" --jq '[.[] | "\(.state):\(.user.id):\([.environments[].id] | join("+"))"] | join(",")') ||
  fail 'reading the approvals failed'
expect 'approvals (state:user:environment)' "$v" approved:8365892:23921538204

verify=$(job 'Verify the tag')
publish=$(job 'Publish to ghcr.io')
echo; echo "== Verify the tag (job $verify): the guards' line"
lines "$verify" '^tag v[0-9.]+ at [0-9a-f]{40}: '
echo; echo "== Publish to ghcr.io (job $publish): login, the moved-tag refusal, the existence guard, the push, the digest"
lines "$publish" '^Login Succeeded|^::error::|^##\[error\]|is absent \(http [0-9]+\)|exists \(http [0-9]+\)|cannot tell whether ghcr\.io|(naming to|pushing manifest for|pushing) ghcr\.io/steven-cutting/knarr[:@]|^digest=sha256:'
digest=$(lines "$publish" '^digest=sha256:[0-9a-f]{64}$' | sed 's/^digest=//')
[ "$(printf '%s\n' "$digest" | grep -cE '^sha256:[0-9a-f]{64}$')" = 1 ] || fail "the publish log has no single digest= line: '$digest'"

echo; echo "== the git tag"
v=$(git cat-file -t "refs/tags/$tag") || fail "no local $tag"
expect "git cat-file -t $tag" "$v" tag
v=$(git rev-parse "refs/tags/$tag^{commit}") || fail "no local $tag"
expect "$tag^{commit}" "$v" "$commit"
local_obj=$(git rev-parse "refs/tags/$tag") || fail "no local $tag"
remote=$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}") || fail 'git ls-remote failed'
printf '%s\n' "$remote"
expect "remote $tag object" "$(printf '%s\n' "$remote" | awk -v r="refs/tags/$tag" '$2 == r { print $1 }')" "$local_obj"
expect "remote $tag^{}" "$(printf '%s\n' "$remote" | awk -v r="refs/tags/$tag^{}" '$2 == r { print $1 }')" "$commit"

echo; printf 'digest: %s\n' "$digest"
