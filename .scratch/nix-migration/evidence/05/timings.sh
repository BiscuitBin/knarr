#!/bin/sh
# Ticket 05 evidence: every job and step of one nix-spike.yml run, in seconds,
# from GitHub's jobs API (read-only GETs). The step times are GitHub's own
# started_at and completed_at, to the second.
# Usage: sh timings.sh <run-id>   (needs gh, authenticated)
set -eu
run=${1:?usage: timings.sh <run-id>}
repo=BiscuitBin/knarr
gh api "repos/$repo/actions/runs/$run" \
  --jq '"run \(.id), attempt \(.run_attempt), commit \(.head_sha), \(.event) on \(.head_branch), \(.status) \(.conclusion)\n\(.html_url)"'
gh api "repos/$repo/actions/runs/$run/jobs?per_page=50" --jq '
  def secs(a; b): ((b | fromdateiso8601) - (a | fromdateiso8601));
  .jobs | sort_by(.name)[] |
  "\n\(.name): \(.conclusion), \(secs(.started_at; .completed_at)) s on \(.runner_name // "?")",
  (.steps[] | select(.started_at != null and .completed_at != null) |
    "  \(secs(.started_at; .completed_at) | tostring | (" " * (5 - length)) + .) s  \(.conclusion | .[0:7])  \(.name | .[0:90])")'
