# Ticket 45 evidence

Evidence for the "Amended by ticket 45" notes in [Decision 0014: Dependency updates and audit](../../../../docs/decisions/0014-dependency-updates-and-audit.md) and [Decision 0003: Tool manager](../../../../docs/decisions/0003-tool-manager.md). Gathered on 2026-10-12 and 2026-10-13 (UTC). The real knarr image builds only in CI, on amd64 (Decision 0012), so both proofs are GitHub runs read back with `gh`. `ci-runs.txt` is the transcript of `ci-runs.sh`, which only reads.

- **The audit run** of `audit.yml` was dispatched once on the branch. Its image-scan job builds the image, which prunes conda-forge's perl, and runs `just image-scan`, then `just runtime-scan` on the copy of the runtime environment.
- **The pull request's `ci.yml` run** includes the kind smoke job. Its `just image-check` checks the image has no `bin/perl` and no perl record, and reruns Decision 0003's `tls_check.escript` with the pruned environment.

## Network the maintainer authorized for this ticket

On 2026-10-12: `just audit-install` and grype's vulnerability database locally, one push of the branch and one `audit.yml` dispatch on it. During the work, also a draft pull request, which runs `ci.yml`, and a second push for the hand-back.

## Rerun

```sh
sh .scratch/bootstrap/evidence/45/ci-runs.sh <audit-run-id> <ci-run-id>
```
