#!/bin/sh
# Run ripsecrets without copying any matched credential into the log: output
# suppressed, exit status kept. Only the binary 0003 pins runs, the one
# scripts/tool-dirs.sh finds in this worktree's tool directories, never one
# found elsewhere on PATH, and a refusal exits 2 so it never reads as a finding
# (1). Every argument is a path, never a flag.
# Rewritten from github.com/steven-cutting/biscuit_games_tooling at v0.3.0
# (6c5c07f6bec86e86b3930dfa41392e4b440e8c85),
# src/biscuit_games_tooling/run_ripsecrets_redacted.py, as Decision 0004 records.
# SPDX-License-Identifier: Apache-2.0
set -u
root=$(git rev-parse --show-toplevel 2> /dev/null) ||
  { echo 'ripsecrets-redacted: run this from inside a Git worktree' >&2; exit 2; }
bin=$(sh "$(dirname -- "$0")/../tool-dirs.sh" tool ripsecrets "$root") ||
  { echo 'ripsecrets is unavailable; run just initialize' >&2; exit 2; }
"$bin" -- "$@" > /dev/null 2>&1
status=$?
case $status in
  0) ;;
  1) echo 'ripsecrets found credential material; the matched values are suppressed' ;;
  *) echo "ripsecrets failed with status $status; output suppressed" ;;
esac
exit "$status"
