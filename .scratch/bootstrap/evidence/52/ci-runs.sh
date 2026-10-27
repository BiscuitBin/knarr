#!/bin/sh
# Ticket 52 evidence: GitHub runs, read back with gh. From the pull request's
# ci.yml run it prints the kind smoke job's just image-check: OTP in the amd64
# image and Decision 0003's TLS check rerun on the new pin. From the audit.yml
# run on main, when its id is given, it prints the jobs, the hex audit's
# verdict, grype's table for the image scan and the runtime scan's verdict. A
# job's failure is a finding, not a failure of this script; a run that has not
# finished, or a job missing from it, is. gh reads only. Needs an
# authenticated gh.
# Usage: sh ci-runs.sh <ci-run-id> [<audit-run-id>]
set -eu
ci=${1:?usage: ci-runs.sh <ci-run-id> [<audit-run-id>]}
audit=${2:-}
repo=BiscuitBin/knarr
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
list_jobs() { # run-id
  gh run view "$1" -R "$repo" --json jobs \
    --jq '.jobs[] | "\(.name): \(.conclusion), \(.startedAt) to \(.completedAt)"'
}
# gh prints each log line as job<TAB>step<TAB>timestamp text. The log is read
# whole before it is filtered, so a failed or empty read fails the script
# instead of printing an empty section. grep finding no line is not a failure.
lines() { # run-id job-id pattern: the job's log lines that match, without gh's prefix
  log=$(gh run view "$1" -R "$repo" --log --job "$2") || exit 1
  [ -n "$log" ] || { echo "job $2 has an empty log" >&2; exit 1; }
  printf '%s\n' "$log" | sed -n 's/^[^	]*	[^	]*	[^ ]* //p' | { grep -E "$3" || [ "$?" -eq 1 ]; }
}
echo '== ci.yml'
header "$ci"
echo '-- jobs'
list_jobs "$ci"
smoke_job=$(job "$ci" 'Kind smoke (non-required)')
echo '-- Kind smoke: just image-check (the TLS check on the new pin)'
lines "$ci" "$smoke_job" '^(openssl|escript): |^otp_release |^ssl:versions|^(ok|BAD) +(right|wrong) CA|^tls_check|^image: |RuntimeError'
[ -z "$audit" ] && exit 0
echo '== audit.yml'
header "$audit"
echo '-- jobs'
list_jobs "$audit"
hex_job=$(job "$audit" 'Hex advisories')
echo '-- Hex advisories'
lines "$audit" "$hex_job" '^hex-audit: |^(CVE|GHSA|EEF)-'
scan_job=$(job "$audit" 'Image scan')
echo '-- Image scan: steps'
gh run view "$audit" -R "$repo" --json jobs \
  --jq '.jobs[] | select(.name == "Image scan") | .steps[] | "\(.name): \(.conclusion)"'
echo '-- Image scan: just image-scan, just runtime-scan'
lines "$audit" "$scan_job" '^(NAME +INSTALLED|[a-z0-9][a-z0-9.+_-]* +[^ ]+ +[^ ]+ +(deb|binary|conda|python|go-module|java-archive|erlang-otp|hex|rpm|apk) |error: recipe|No vulnerabilities found|runtime-scan: )'
