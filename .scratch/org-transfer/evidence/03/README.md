# Org-transfer ticket 03 evidence

Evidence for [ticket 03](../../issues/03-transfer-repository.md): the settings of `biscuitbin/knarr` after [Decision 0016](../../../../docs/decisions/0016-biscuitbin-org.md)'s transfer, diffed against [02's record](../02/settings.txt), the old URLs' redirects, and the workflows' first runs under the org. Gathered on 2026-10-23 (UTC) with gh 2.100.0, jq 1.7.1, curl 8.7.1 and git 2.50.1, logged in as `steven-cutting`, the same token as 02. Every step that left the worktree was authorized by the maintainer, one action at a time.

The maintainer transferred the repository on 2026-10-22, local time, and did not note the time. The record can only bound it: the transfer happened before 2026-10-23T03:22Z, when the first settings rerun found `biscuitbin/knarr`.

- [settings.txt](settings.txt) is the final run of 02's [settings.sh](../02/settings.sh) `biscuitbin`, unchanged, at 03:38Z. [settings.diff](settings.diff) is `diff` against 02's `settings.txt`.
- [settings-first.diff](settings-first.diff) is the same diff from the first run, at 03:22Z, before the restore below. Its transcript was overwritten by the final run, which shows the restore.
- [redirect.sh](redirect.sh) `<old owner> <new owner>` records, and does not judge, the old web URL's status line and `location` header, without following the redirect, and `git ls-remote` of `HEAD` and `main` under the old and the new git URLs. Any stderr from a successful `ls-remote` is kept, since that is where GitHub says a repository moved. [redirect.txt](redirect.txt) is its run at 03:36Z.

What the record shows:

- **Unchanged, by name.** The `release` environment still has one rule, required reviewers `User:steven-cutting` with self-review allowed, and `deployment_branch_policy: null`. The `release tags` ruleset is unchanged, id 25048585 included: `refs/tags/v*`, `deletion` and `update`, active, no bypass actors. `main`'s classic protection still requires `check` (app 15368), not strict, with no admin enforcement. Secrets and variables are still empty, Actions permissions and labels are the same, and private vulnerability reporting, Dependabot alerts and code scanning setup match 02.
- **Expected differences.** The header's date and repository line, and every section heading's endpoint. `full_name` and `owner` are now `BiscuitBin`, GitHub's canonical casing of the org login, and `owner_type` is `Organization`. `orgs/<owner>/installations` answered 404 for a user and now answers 200, empty: no app reaches knarr, as before.
- **Lost in the transfer, and restored.** In `settings-first.diff`, `security_and_analysis.secret_scanning` and `secret_scanning_push_protection` went from `enabled` to `disabled`. One authorized `gh api -X PATCH repos/biscuitbin/knarr` turned both back on. Its response showed both `enabled`, but the next `settings.sh` run, at 03:36Z, still read `disabled`. A single GET of `repos/biscuitbin/knarr` straight after read `enabled`, and the final run at 03:38Z records `enabled`. That run's `settings.diff` has only the expected differences.
- **Redirects.** `https://github.com/steven-cutting/knarr` answers `301` with `location: https://github.com/BiscuitBin/knarr`. `git@github.com:steven-cutting/knarr.git` and `git@github.com:biscuitbin/knarr.git` both give `0228be8` for `HEAD` and `refs/heads/main`. The old URL wrote nothing to stderr.
- **Remote.** `origin` in `/Users/scutting/projects/knarr`, whose `.git` all 57 linked worktrees share, is now `git@github.com:biscuitbin/knarr.git`. `git remote get-url origin` in this worktree shows that. A search of `~/projects` and `~/.supacode` found no separate clone with the old URL.

## Workflows under the org

Pull request [#59](https://github.com/BiscuitBin/knarr/pull/59), this ticket's record, is the trivial pull request.

- **`check` gates the merge.** At 03:41:40Z, with `Repository gate` in progress, `gh pr view 59 --json mergeStateStatus,statusCheckRollup` read `BLOCKED`. At 03:41:45Z, `gh pr merge 59 --merge`, without `--admin`, refused: "Pull request biscuitbin/knarr#59 is not mergeable: the base branch policy prohibits the merge." The pull request stayed `OPEN` and `BLOCKED`. `check` then passed in [CI run 39896360344](https://github.com/BiscuitBin/knarr/actions/runs/39896360344), job [`check`](https://github.com/BiscuitBin/knarr/actions/runs/39896360344/job/120228341924). After the labels below were removed, the state was `CLEAN`.
- **The kind jobs in `ci.yml` were skipped by design.** `Kind smoke`, `Kind fake worker smoke`, `Kwok readiness` and `Selected checker regressions` are path-selected, and a record-only pull request touches none of their paths. The two labelled workflows below provide the cluster coverage.
- **`keda-e2e`.** Adding the label ran [KEDA e2e 39896495875](https://github.com/BiscuitBin/knarr/actions/runs/39896495875): `success`, job `Kind KEDA e2e (non-required)` `success`. Adding `cluster-s1` afterwards queued KEDA e2e 39896502487, which the job's label filter skipped, as designed.
- **`cluster-s1`.** Adding the label ran [Reconcile proof 39896502403](https://github.com/BiscuitBin/knarr/actions/runs/39896502403): `success`, job `Kind reconciler proof (non-required)` `success`, in 9m3s. The `keda-e2e` label event had queued Reconcile proof 39896495850, which was skipped, as designed.
- **`audit.yml` ran under the org and failed on findings, not on the transfer.** [Audit 39896502411](https://github.com/BiscuitBin/knarr/actions/runs/39896502411), from `gh workflow run audit.yml --ref main`, ended in `failure`. `External links` passed. `Hex advisories` failed because OSV.dev lists CVE-2026-105236, CVE-2026-42789 (with EEF-CVE-2026-42789) and CVE-2026-96596 against Erlang/OTP 29.1.1. `Image scan` failed because grype finds fixable high vulnerabilities: CVE-2026-94200 in erlang 29.1.1, fixed in 29.1.2, and CVE-2026-84782 in libssl3t64 `3.0.13-0ubuntu3.15`, fixed in `3.0.13-0ubuntu3.16`. The audit was already failing before the transfer: the scheduled runs of 2026-10-12 and 2026-10-19 and the dispatch of 2026-10-13 all ended in `failure`. Moving those pins changes tracked files outside this record, so it is left to its own change. The ticket's audit box stays open until an audit run succeeds.
- `release.yml` was not run. No tag is pushed until [04](../../issues/04-rename-live-references.md) merges.

## Network the maintainer authorized for this ticket

On 2026-10-23 (UTC), each separately: `just initialize`, run by the maintainer. One `settings.sh biscuitbin` run and one `redirect.sh steven-cutting biscuitbin` run. One `gh api -X PATCH repos/biscuitbin/knarr` for the two secret scanning settings. A second run of each script: the redirect rerun because `redirect.sh` was changed to drop the trailing space after GitHub's status code, which editorconfig-checker rejects. One GET of `repos/biscuitbin/knarr`, made before asking, to check whether the PATCH had taken effect. A third `settings.sh` run. `git remote set-url` in the main checkout, which is local but shared. The push of this branch and `gh pr create`. `gh pr view` and `gh pr merge` without `--admin` on #59. Adding the `keda-e2e` label, then the `cluster-s1` label, in two calls. `gh workflow run audit.yml --ref main`. Watching the runs with `gh pr checks`, `gh run list` and `gh run view`. Removing both labels. The final push.

`redirect.sh` was first run against a stub `curl` and `git` in `ai_tmp/`. The stub covered a redirect, a curl failure, an `ls-remote` failure, a missing argument, stderr on a successful `ls-remote`, and a status line with a trailing space. That stub is scratch and is not part of the change. `shellcheck` is clean, with and without `-x`.

## Rerun

Every run reaches the network and needs authorization:

```sh
E=.scratch/org-transfer/evidence/02
T=.scratch/org-transfer/evidence/03
sh $E/settings.sh biscuitbin >| $T/settings.txt 2>&1
diff $E/settings.txt $T/settings.txt >| $T/settings.diff
sh $T/redirect.sh steven-cutting biscuitbin >| $T/redirect.txt 2>&1
```
