# 03: Transfer the repository

**Context:** [Decision 0016](01-biscuitbin-decision.md) moves knarr to `github.com/biscuitbin/knarr` by GitHub's repository transfer. [02](02-org-readiness-snapshot.md) recorded the repository's settings before the move. The transfer is expected to keep issues, pull requests, stars, environments, rulesets and secrets, and to redirect the old git and web URLs. This ticket proves it by recording the same settings after the move and diffing them.

Between this ticket and [04](04-rename-live-references.md)'s merge, `release.yml` still names `ghcr.io/steven-cutting/…`, which the org repository's `GITHUB_TOKEN` cannot push to. Nobody pushes a release tag in that window.

**What to build:** The transferred repository, a settings diff that shows nothing was lost, every local remote pointing at the new URL, and a successful run of every workflow under the org.

**Non-goals:** Renaming a reference in a tracked file (04). Any release (05). Creating a repository named `steven-cutting/knarr`, ever: it would break the redirects.

**Blocked by:** 02

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** the transfer. The maintainer runs Settings → Transfer ownership → `biscuitbin` on `steven-cutting/knarr`, and the hand-back records the time.
- [ ] **Authorization required:** `gh` and the network. 02's `settings.sh`, rerun against `biscuitbin/knarr`, writes `.scratch/org-transfer/evidence/03/settings.txt`, and `settings.diff` beside it is the diff against 02's. These are unchanged, by name: the `release` environment's required reviewers and its deployment branch and tag policy, the tag ruleset, and the required status checks on `main`. Every other difference is explained in the hand-back.
- [ ] Anything that did not carry over is restored, for instance private vulnerability reporting or Renovate's access, and a final rerun of `settings.sh` shows it.
- [ ] **Authorization required:** the network. `https://github.com/steven-cutting/knarr` and `git ls-remote git@github.com:steven-cutting/knarr.git` both still reach the repository through GitHub's redirect, and `redirect.txt` records it.
- [ ] `git remote set-url origin git@github.com:biscuitbin/knarr.git` in the main checkout. The linked worktrees share its `.git`, so that one change covers them all; `git -C <worktree> remote get-url origin` in one of them shows it. Any separate clone is listed in the hand-back with its remote updated.
- [ ] **Authorization required:** a push and `gh`. A trivial pull request under the org shows that the required check `check` runs and gates the merge: a merge attempt before it finishes is blocked. The hand-back records the run URL.
- [ ] **Authorization required:** labels, a dispatch and `gh`. Adding the `keda-e2e` and `cluster-s1` labels to that pull request runs `keda-e2e.yml` and `reconcile-proof.yml`, and `gh workflow run audit.yml --ref main` runs the audit. Each run ends in `success`, not `skipped`, and the hand-back records each run URL. `ci.yml`'s path-selected kind jobs are skipped on a trivial pull request by design; the hand-back says so, and the cluster coverage comes from the two labelled workflows.

## Hand-back notes
