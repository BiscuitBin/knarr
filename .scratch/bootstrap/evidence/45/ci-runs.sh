#!/bin/sh
# Ticket 45 evidence: two GitHub runs, read back with gh. From the audit.yml
# run it prints the jobs, the build's perl prune, grype's table for the image
# scan and the runtime scan's verdict. From the ci.yml run of the pull request
# it prints the kind smoke job's just image-check: the perl check's absence of
# output, the TLS check rerun in the pruned image, and the closing line. A
# job's failure is a finding, not a failure of this script; a run that has not
# finished, or a job missing from it, is. gh reads only. Needs an
# authenticated gh.
# Usage: sh ci-runs.sh <audit-run-id> <ci-run-id>
set -eu
audit=${1:?usage: ci-runs.sh <audit-run-id> <ci-run-id>}
ci=${2:?usage: ci-runs.sh <audit-run-id> <ci-run-id>}
repo=steven-cutting/knarr
header() { # run-id
  gh run view "$1" -R "$repo" --json status,conclusion,event,headBranch,headSha,createdAt,url \
    --jq '"run: \(.url)\nevent: \(.event) on \(.headBranch) at \(.headSha[0:7]), \(.createdAt)\nstatus: \(.status), \(.conclusion)"'
  [ "$(gh run view "$1" -R "$repo" --json status --jq .status)" = completed ] ||
    { echo "run $1 has not finished" >&2; exit 1; }
}
job() { # run-id name: the job's id, or a failure
  id=$(gh run view "$1" -R "$repo" --json jobs --jq ".jobs[] | select(.name == \"$2\") | .databaseId")
  [ -n "$id" ] || { echo "run $1 has no $2 job" >&2; exit 1; }
  echo "$id"
}
# gh prints each log line as job<TAB>step<TAB>timestamp text. The log is read
# whole before it is filtered, so a failed or empty read fails the script
# instead of printing an empty section. grep finding no line is not a failure.
lines() { # run-id job-id pattern: the job's log lines that match, without gh's prefix
  log=$(gh run view "$1" -R "$repo" --log --job "$2") || exit 1
  [ -n "$log" ] || { echo "job $2 has an empty log" >&2; exit 1; }
  printf '%s\n' "$log" | sed -n 's/^[^	]*	[^	]*	[^ ]* //p' | { grep -E "$3" || [ "$?" -eq 1 ]; }
}
echo '== audit.yml'
header "$audit"
echo '-- jobs'
gh run view "$audit" -R "$repo" --json jobs \
  --jq '.jobs[] | "\(.name): \(.conclusion), \(.startedAt) to \(.completedAt)"'
scan_job=$(job "$audit" 'Image scan')
echo '-- Image scan: steps'
gh run view "$audit" -R "$repo" --json jobs \
  --jq '.jobs[] | select(.name == "Image scan") | .steps[] | "\(.name): \(.conclusion)"'
echo '-- Image scan: just image-build (the perl prune), just image-scan, just runtime-scan'
lines "$audit" "$scan_job" 'prune_runtime: |^(grype |NAME +INSTALLED|[a-z0-9][a-z0-9.+_-]* +[^ ]+ +[^ ]+ +(deb|binary|conda|python|go-module|java-archive|erlang-otp|hex|rpm|apk) |error: recipe|No vulnerabilities found|runtime-scan: )'
echo '== ci.yml'
header "$ci"
smoke_job=$(job "$ci" 'Kind smoke (non-required)')
echo '-- Kind smoke: conclusion'
gh run view "$ci" -R "$repo" --json jobs \
  --jq '.jobs[] | select(.name == "Kind smoke (non-required)") | .conclusion'
echo '-- Kind smoke: just image-check (the TLS check in the pruned image)'
lines "$ci" "$smoke_job" '^(date|host|env|openssl|escript): |^server(-dns)?\.pem: |^otp_release |^ssl:versions|^(ok|BAD) +(right|wrong) CA|^tls_check|^image: |RuntimeError|prune_runtime: '
