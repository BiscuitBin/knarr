# 03: Transfer the repository

**Context:** [Decision 0016](01-biscuitbin-decision.md) moves knarr to `github.com/biscuitbin/knarr` by GitHub's repository transfer. [02](02-org-readiness-snapshot.md) recorded the repository's settings before the move. The transfer is expected to keep issues, pull requests, stars, environments, rulesets and secrets, and to redirect the old git and web URLs. This ticket proves it by recording the same settings after the move and diffing them.

Between this ticket and [04](04-rename-live-references.md)'s merge, `release.yml` still names `ghcr.io/steven-cutting/…`, which the org repository's `GITHUB_TOKEN` cannot push to. Nobody pushes a release tag in that window.

**What to build:** The transferred repository, a settings diff that shows nothing was lost, every local remote pointing at the new URL, and a successful run of every workflow under the org.

**Non-goals:** Renaming a reference in a tracked file (04). Any release (05). Creating a repository named `steven-cutting/knarr`, ever: it would break the redirects.

**Blocked by:** 02

**MVP critical path:** no.

**Status:** needs-human

- [x] **Authorization required:** the transfer. The maintainer runs Settings → Transfer ownership → `biscuitbin` on `steven-cutting/knarr`, and the hand-back records the time.
- [x] **Authorization required:** `gh` and the network. 02's `settings.sh`, rerun against `biscuitbin/knarr`, writes `.scratch/org-transfer/evidence/03/settings.txt`, and `settings.diff` beside it is the diff against 02's. These are unchanged, by name: the `release` environment's required reviewers and its deployment branch and tag policy, the tag ruleset, and the required status checks on `main`. Every other difference is explained in the hand-back.
- [x] Anything that did not carry over is restored, for instance private vulnerability reporting or Renovate's access, and a final rerun of `settings.sh` shows it.
- [x] **Authorization required:** the network. `https://github.com/steven-cutting/knarr` and `git ls-remote git@github.com:steven-cutting/knarr.git` both still reach the repository through GitHub's redirect, and `redirect.txt` records it.
- [x] `git remote set-url origin git@github.com:biscuitbin/knarr.git` in the main checkout. The linked worktrees share its `.git`, so that one change covers them all; `git -C <worktree> remote get-url origin` in one of them shows it. Any separate clone is listed in the hand-back with its remote updated.
- [x] **Authorization required:** a push and `gh`. A trivial pull request under the org shows that the required check `check` runs and gates the merge: a merge attempt before it finishes is blocked. The hand-back records the run URL.
- [ ] **Authorization required:** labels, a dispatch and `gh`. Adding the `keda-e2e` and `cluster-s1` labels to that pull request runs `keda-e2e.yml` and `reconcile-proof.yml`, and `gh workflow run audit.yml --ref main` runs the audit. Each run ends in `success`, not `skipped`, and the hand-back records each run URL. `ci.yml`'s path-selected kind jobs are skipped on a trivial pull request by design; the hand-back says so, and the cluster coverage comes from the two labelled workflows.

## Hand-back notes

Done on 2026-10-23 (UTC) with the maintainer, except for the audit run in the last box. [The evidence README](../evidence/03/README.md) indexes the transcripts, summarizes what they show, and lists every network action authorized.

**What changed:** The repository is now `biscuitbin/knarr`. The maintainer transferred it on 2026-10-22, local time, without noting the time; the record shows it happened before 2026-10-23T03:22Z. Secret scanning and push protection were turned back on. `origin` in the main checkout points at `git@github.com:biscuitbin/knarr.git`. In the tree, `.scratch/org-transfer/evidence/03/` was added, holding `redirect.sh`, `redirect.txt`, `settings.txt`, `settings.diff`, `settings-first.diff` and `README.md`, and this ticket was updated. No other tracked file changed. This branch is `ticket/03-transfer-repository`, not `03-transfer-repository`; the maintainer kept the name Supacode gave it.

**What was verified:**

- [settings.diff](../evidence/03/settings.diff) shows that the `release` environment's required reviewers (`User:steven-cutting`, self-review allowed) and its `deployment_branch_policy: null`, the `release tags` ruleset, id included, and `main`'s required check `check` are unchanged. The only other differences are the expected ones: the header, the endpoints, `full_name` and `owner` (now `BiscuitBin`), `owner_type: Organization`, and `orgs/biscuitbin/installations` answering 200 with no app.
- [settings-first.diff](../evidence/03/settings-first.diff) shows what the transfer lost: secret scanning and push protection went from `enabled` to `disabled`. One authorized PATCH turned both back on, and the final run records them `enabled`. Private vulnerability reporting carried over. There was no Renovate access to restore ([Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md)).
- [redirect.txt](../evidence/03/redirect.txt): the old web URL answers `301` to `https://github.com/BiscuitBin/knarr`, and the old and new git URLs give the same `HEAD` and `main`.
- `git remote get-url origin` in this worktree shows `git@github.com:biscuitbin/knarr.git`. No separate clone under `~/projects` or `~/.supacode` named the old URL.
- On #59, `mergeStateStatus` was `BLOCKED` while the gate ran, and `gh pr merge` without `--admin` was refused. `check` then passed in [run 39896360344](https://github.com/BiscuitBin/knarr/actions/runs/39896360344/job/120228341924). The `keda-e2e` label ran [KEDA e2e](https://github.com/BiscuitBin/knarr/actions/runs/39896495875) to `success`, and `cluster-s1` ran [Reconcile proof](https://github.com/BiscuitBin/knarr/actions/runs/39896502403) to `success`. Both labels were then removed. `ci.yml`'s path-selected kind jobs were skipped on this record-only pull request, by design; the two labelled workflows provide the cluster coverage.
- `shellcheck` is clean on `redirect.sh`, with and without `-x`, and the script was run against a stub first.

**Still open:** the [audit run](https://github.com/BiscuitBin/knarr/actions/runs/39896502411) dispatched under the org ended in `failure`, so the last box stays unticked. It ran, and `External links` passed. `Hex advisories` and `Image scan` failed on advisories against the pinned Erlang/OTP 29.1.1, fixed in 29.1.2, and on the image's `libssl3t64`. The libssl finding is the one [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) already records, red until Ubuntu republishes noble. The OTP advisories are new: ticket 45's audit run of 2026-10-13 failed on the libssl rows alone, and its runtime scan found nothing with a fix. When they appeared since is not established. Nothing points at the transfer. Fixing them moves pins in tracked files, which this record-only ticket does not do. [Bootstrap ticket 52](../../bootstrap/issues/52-otp-and-base-image-advisories.md) moves them, and its `gh workflow run audit.yml --ref main` that ends in `success` closes the box.

**What each later ticket needs:**

- **04:** GitHub's canonical login is `BiscuitBin`, and redirects and API answers use that casing. `release.yml` still names `ghcr.io/steven-cutting/…`, so no tag is pushed until 04 merges.
- **05:** nothing from here beyond 04. The `release` environment and the tag ruleset carried over unchanged.
- **Bootstrap 44:** installs the Mend app on `biscuitbin`, limited to `knarr`; `orgs/biscuitbin/installations` lists no app today.
