#!/bin/sh
# Ticket 37 evidence: the first live run of release.yml, read back with gh.
# It prints the run and its jobs, who approved the release environment, and
# the lines of each job's log that the hand-back cites, then checks them:
# verify's guard line, one login, the existence guard's verdict, the tags
# buildx named and pushed, no error annotation, and one digest. It ends with
# the git tag as this clone and the remote hold it. It fails unless the run
# was the v0.1.0 push at the expected commit and both jobs succeeded. Each
# answer is read once, and what it prints and what it checks come from that
# one read. It prints no whole log and no token. gh and git ls-remote read
# only. Needs an authenticated gh and the local v0.1.0 the maintainer pushed.
# Usage: sh run.sh <run-id> > run.txt 2>&1
set -eu
run=${1:?usage: run.sh <run-id>}
repo=steven-cutting/knarr
tag=v0.1.0
version=0.1.0
commit=283a7d489d07d81bd3a9c393ce10be11ad71303f # PR #33's merge commit
image=ghcr.io/steven-cutting/knarr
tags="0.1,0.1.0,sha-$(printf '%s' "$commit" | cut -c1-7)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
# gh prints each log line as job<TAB>step<TAB>timestamp text. A job's log is
# read once, whole, so a failed or empty read fails the script instead of
# printing an empty section, and is then filtered as often as needed. The log
# also echoes each step's script, every line after a colour escape. Each
# pattern below is anchored at a line's start or needs a value where the
# script has a variable, so none matches the script. grep finding no line is
# not a failure.
log() { # job-id: the job's log, without gh's prefix
  out=$(gh run view "$run" -R "$repo" --log --job "$1") || fail "reading job $1's log failed"
  [ -n "$out" ] || fail "job $1 has an empty log"
  printf '%s\n' "$out" | sed -n 's/^[^	]*	[^	]*	[^ ]* //p'
}
matching() { # text pattern: the lines that match
  printf '%s\n' "$1" | { grep -E "$2" || [ "$?" -eq 1 ]; }
}
count() { # text pattern: how many lines match
  printf '%s\n' "$1" | grep -cE "$2" || true
}
listed() { # text sed-expression: what it extracts, sorted and comma-joined
  printf '%s\n' "$1" | sed -nE "$2" | LC_ALL=C sort | paste -s -d , -
}
v=$(gh --version) || fail 'gh --version failed'
printf 'date: %s\n%s\nrepository: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(printf '%s\n' "$v" | head -n 1)" "$repo"

echo; echo "== run $run"
# Eight lines of the run's fields, then one line per job: name, id,
# conclusion, start and end, separated by tabs.
v=$(gh run view "$run" -R "$repo" --json url,event,headBranch,headSha,createdAt,status,conclusion,workflowName,jobs \
  --jq '([.url, .workflowName, .event, .headBranch, .headSha, .createdAt, .status, .conclusion] | join("\n")),
    (.jobs[] | [.name, (.databaseId | tostring), .conclusion, .startedAt, .completedAt] | join("\t"))') ||
  fail "reading run $run failed"
field() { printf '%s\n' "$v" | sed -n "$1p"; }
jobs=$(printf '%s\n' "$v" | sed -n '9,$p')
printf 'url: %s\n' "$(field 1)"
printf 'created: %s\n' "$(field 6)"
expect workflow "$(field 2)" Release
expect event "$(field 3)" push
expect ref "$(field 4)" "$tag"
expect 'head sha' "$(field 5)" "$commit"
expect 'status, conclusion' "$(field 7) $(field 8)" 'completed success'
echo '-- jobs'
printf '%s\n' "$jobs" | awk -F '\t' '{ printf "%s (job %s): %s, %s to %s\n", $1, $2, $3, $4, $5 }'
expect 'job conclusions' "$(printf '%s\n' "$jobs" | awk -F '\t' '{ print $1 "=" $3 }' | LC_ALL=C sort | paste -s -d , -)" \
  'Publish to ghcr.io=success,Verify the tag=success'
job() { # name: the job's id, or a failure
  id=$(printf '%s\n' "$jobs" | awk -F '\t' -v n="$1" '$1 == n { print $2 }')
  [ "$(count "$id" '^[0-9]+$')" = 1 ] || fail "run $run has no single $1 job: '$id'"
  echo "$id"
}
verify=$(job 'Verify the tag')
publish=$(job 'Publish to ghcr.io')

echo; echo "== the release environment's approval: gh api repos/$repo/actions/runs/$run/approvals"
# One line per approval, then the state:user:environment key of all of them.
v=$(gh api "repos/$repo/actions/runs/$run/approvals" \
  --jq '(.[] | "\(.state) by \(.user.login) (user \(.user.id)) for \([.environments[] | "\(.name) (\(.id))"] | join(", ")), comment: \(.comment | tojson)"),
    ([.[] | "\(.state):\(.user.id):\([.environments[].id] | join("+"))"] | join(","))') ||
  fail 'reading the approvals failed'
printf '%s\n' "$v" | sed '$d'
expect 'approvals (state:user:environment)' "$(printf '%s\n' "$v" | sed -n '$p')" approved:8365892:23921538204

errors='^::error::|^##\[error\]'
echo; echo "== Verify the tag (job $verify): the guards' line"
verify_log=$(log "$verify")
v=$(matching "$verify_log" '^tag v[0-9.]+ at [0-9a-f]{40}: ')
printf '%s\n' "$v"
expect "verify's line" "$v" "tag $tag at $commit: version $version, an ancestor of origin/main, in the changelog"
expect 'error lines (::error:: or ##[error])' "$(count "$verify_log" "$errors")" 0

echo; echo "== Publish to ghcr.io (job $publish): login, the moved-tag refusal, the existence guard, the push, the digest"
publish_log=$(log "$publish")
guard='is absent \(http [0-9]+\)|exists \(http [0-9]+\)|cannot tell whether ghcr\.io'
matching "$publish_log" "^Login Succeeded|$errors|$guard|(naming to|pushing manifest for|pushing) ghcr\.io/steven-cutting/knarr[:@]|^digest=sha256:"
echo '-- checks'
expect 'Login Succeeded lines' "$(count "$publish_log" '^Login Succeeded$')" 1
v=$(matching "$publish_log" "$guard")
expect "the existence guard's line" "$v" "$image:$version is absent (http 404): pushing"
expect 'tags buildx named' "$(listed "$publish_log" "s|^#[0-9]+ naming to $image:([^ ]+) done\$|\\1|p")" "$tags"
expect 'tags buildx pushed' "$(listed "$publish_log" "s|^#[0-9]+ pushing $image:([^ ]+) with docker\$|\\1|p")" "$tags"
expect 'error lines (::error:: or ##[error])' "$(count "$publish_log" "$errors")" 0
digest=$(printf '%s\n' "$publish_log" | sed -n 's/^digest=//p')
expect 'digest= lines' "$(count "$digest" .)" 1
expect 'the digest is sha256: and 64 hex digits' "$(count "$digest" '^sha256:[0-9a-f]{64}$')" 1

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
