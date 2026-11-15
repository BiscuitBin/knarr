#!/bin/sh
# Ticket 14 evidence: the TLS cases ticket 01 left open for the client. The
# host is given to ssl and httpc as the string "127.0.0.1", the form the
# client builds from KUBERNETES_SERVICE_HOST, and the listener records the SNI
# that arrives. It also probes public_key:pkix_test_data/1 with an IP SAN, the
# chain the in-gate loopback test uses. Uses 01's cert generator.
# Usage: sh tls/run.sh <worktree> <empty-work-dir>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
worktree=${1:?usage: run.sh <worktree> <work-dir>}
work=${2:?usage: run.sh <worktree> <work-dir>}
env=$worktree/.nix/tools
PATH="$env/bin:$PATH"; export PATH
printf 'date: %s\nhost: %s\nopenssl: %s\nescript: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" "$(openssl version)" "$(command -v escript)"
sh "$here/../../01/tls/gen-certs.sh" "$work"
escript "$here/tls_check.escript" "$work"
