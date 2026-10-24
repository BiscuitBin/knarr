#!/bin/sh
# Org transfer ticket 05 evidence, adapted from bootstrap ticket 40's run.sh:
# the first release under the org, its run of release.yml read back with gh.
# It prints the run and its jobs, who approved the release environment, and
# the lines of each job's log that the hand-back cites, then checks them:
# verify's guard line, the two logins, the image's and the chart's existence
# guards, the tags buildx named and pushed, the digest, the chart's stamp and
# push. It ends with the git tag as this clone and the remote hold it. It
# fails unless the run was the tag's push at the expected commit and both
# jobs succeeded.
# Changed from 40's: the repository is biscuitbin/knarr and the image and the
# chart are ghcr.io/biscuitbin/…. The environment and its reviewer are
# ticket 36's, which carried over the transfer. Every guard still expects
# `absent (http 404)`: both packages are new under the org.
# Each answer is read once, and what it prints and what it checks come from
# that one read. It prints no whole log and no token. gh and git ls-remote
# read only. Needs an authenticated gh and the local tag the maintainer pushed.
# Usage: sh run.sh <run-id> <tag> <commit> > run.txt 2>&1
set -eu
usage='usage: run.sh <run-id> <tag> <commit>'
run=${1:?$usage}
tag=${2:?$usage}
commit=${3:?$usage}
repo=biscuitbin/knarr
image=ghcr.io/biscuitbin/knarr
chart=ghcr.io/biscuitbin/charts/knarr
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
printf '%s\n' "$tag" | grep -qE '^v0\.[0-9]+\.[0-9]+$' || fail "tag '$tag' is not v0.Y.Z: the tag set below assumes a 0.x release"
printf '%s\n' "$commit" | grep -qE '^[0-9a-f]{40}$' || fail "commit '$commit' is not 40 hex digits"
version=${tag#v}
short=$(printf '%s' "$commit" | cut -c1-7)
# X.Y.Z, X.Y and sha-<7>, sorted: a 0.x release has no X tag and none has latest.
tags=$(printf '%s\n' "$version" "${version%.*}" "sha-$short" | LC_ALL=C sort | paste -s -d , -)
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
printf 'date: %s\n%s\nrepository: %s\ntag: %s\ncommit: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(printf '%s\n' "$v" | head -n 1)" "$repo" "$tag" "$commit"

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

echo; echo "== Publish to ghcr.io (job $publish): the chart check, logins, the existence guards, the image push and digest, the chart stamp and push"
publish_log=$(log "$publish")
guard='is absent \(http [0-9]+\)|exists \(http [0-9]+\)|cannot tell whether ghcr\.io'
matching "$publish_log" "^Login Succeeded|$errors|$guard|(naming to|pushing manifest for|pushing) ghcr\.io/biscuitbin/knarr[:@]|^digest=sha256:|^/[^ ]*/chart-check/knarr-|^packaged |^Pushed: |^Digest: |^chart_digest="
echo '-- checks: the image'
expect 'Login Succeeded lines (docker login, helm registry login)' "$(count "$publish_log" '^Login Succeeded$')" 2
v=$(matching "$publish_log" "^ghcr\.io/biscuitbin/knarr:[^ ]+ ($guard)")
expect "the image's existence guard" "$v" "$image:$version is absent (http 404): pushing"
expect 'tags buildx named' "$(listed "$publish_log" "s|^#[0-9]+ naming to $image:([^ ]+) done\$|\\1|p")" "$tags"
expect 'tags buildx pushed' "$(listed "$publish_log" "s|^#[0-9]+ pushing $image:([^ ]+) with docker\$|\\1|p")" "$tags"
expect 'error lines (::error:: or ##[error])' "$(count "$publish_log" "$errors")" 0
digest=$(printf '%s\n' "$publish_log" | sed -n 's/^digest=//p')
expect 'digest= lines' "$(count "$digest" .)" 1
expect 'the digest is sha256: and 64 hex digits' "$(count "$digest" '^sha256:[0-9a-f]{64}$')" 1
echo '-- checks: the chart'
v=$(matching "$publish_log" '^/[^ ]*/chart-check/knarr-[^ ]+\.tgz$')
expect 'the chart packaged with the placeholder digest, before any push' "$(count "$v" "/chart-check/knarr-$version\\.tgz\$")" 1
v=$(matching "$publish_log" "^ghcr\.io/biscuitbin/charts/knarr:[^ ]+ ($guard)")
printf '%s\n' "$v" | sed 's/^/     /'
expect "the chart's existence guards, before the image push and before the chart push" \
  "$(printf '%s\n' "$v" | paste -s -d '|' -)" \
  "$chart:$version is absent (http 404): pushing the image|$chart:$version is absent (http 404): pushing"
v=$(matching "$publish_log" '^packaged ')
expect 'the stamped package names the image digest' "$(count "$v" "^packaged /[^ ]*/knarr-$version\\.tgz with $image@$digest\$")" 1
expect "helm's Pushed: line" "$(matching "$publish_log" '^Pushed: ')" "Pushed: $chart:$version"
chart_digest=$(printf '%s\n' "$publish_log" | sed -n 's/^Digest: //p')
expect 'Digest: lines' "$(count "$chart_digest" .)" 1
expect 'the chart digest is sha256: and 64 hex digits' "$(count "$chart_digest" '^sha256:[0-9a-f]{64}$')" 1
expect 'chart_digest= agrees with the Digest: line' "$(printf '%s\n' "$publish_log" | sed -n 's/^chart_digest=//p')" "$chart_digest"

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

echo; printf 'digest: %s\nchart digest: %s\n' "$digest" "$chart_digest"
