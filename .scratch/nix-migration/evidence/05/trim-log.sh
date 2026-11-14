#!/bin/sh
# Ticket 05 evidence: one nix-spike.yml run's log, trimmed to the lines that
# carry a finding. GitHub's timestamps and each step's echoed command and
# environment are dropped, as is the whole `just` log each gate.sh step prints
# inside a group; the run URL keeps the rest. Store hashes are elided.
# Usage: sh trim-log.sh <run-id>   (needs gh, authenticated; read-only)
set -eu
run=${1:?usage: trim-log.sh <run-id>}
gh run view "$run" --repo BiscuitBin/knarr --log | awk -F '\t' '
  {
    job = $1; step = $2; line = $3
    sub(/^[^0-9]*[0-9-]+T[0-9:.]+Z ?/, "", line)
    if (line ~ /^##\[group\]the whole just/) { skipping = 1; next }
    if (skipping && line ~ /^##\[endgroup\]/) { skipping = 0; next }
    if (skipping) next
    if (line ~ /^##\[group\]/) { header = 1; next }
    if (header) { if (line ~ /^##\[endgroup\]/) header = 0; next }
    if (step ~ /^(Set up job|Complete job|Run actions\/checkout|Post Run actions\/checkout)/) next
    if (step ~ /install-nix-action/ && line !~ /^(installer options|Installation finished|nix \(Nix\)|Downloading Nix)/) next
    if (step ~ /cache-nix-action/ && line !~ /(cache|Cache|key|store size|Sent|Received|Restored|restored|Saved|Merg|hit)/) next
    if (job != last_job) { printf "\n=== %s\n", job; last_job = job; last_step = "" }
    if (step != last_step) { printf "--- %s\n", step; last_step = step }
    gsub(/\/nix\/store\/[a-z0-9]{32}-/, "/nix/store/…-", line)
    print "  " line
  }'
