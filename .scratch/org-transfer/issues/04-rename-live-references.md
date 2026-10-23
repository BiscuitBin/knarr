# 04: Rename the live references

**Context:** After [03](03-transfer-repository.md), the repository is `biscuitbin/knarr`, but its tracked files still name `steven-cutting/knarr` and `ghcr.io/steven-cutting/…`. The release would push to a namespace the org's `GITHUB_TOKEN` cannot write, the chart's links lean on GitHub's redirect, and the install guide points new users at the old chart. [Decision 0016](01-biscuitbin-decision.md) says which references change and which stay. No release tag is pushed until this ticket merges.

**What to build:** Every live reference renamed, `steven-cutting/knarr` to `biscuitbin/knarr` and `ghcr.io/steven-cutting` to `ghcr.io/biscuitbin`, test first:

- `.github/workflows/release.yml`: `IMAGE`, `CHART`, the OCI `org.opencontainers.image.source` label, and the recovery and attestation comments.
- `scripts/release/preflight.sh` (`image=`), `scripts/release/stamp-chart_test.sh` (`image=`) and `scripts/release/lib_test.sh` (the probe repository and URL).
- `scripts/checks/tests/test_chart.py` and `scripts/checks/tests/test_workflows.py`: the pinned strings.
- `charts/knarr/Chart.yaml` (`home`, `sources`) and `charts/knarr/templates/NOTES.txt` (the install guide URL).
- `SECURITY.md` (the private vulnerability reporting URL), `docs/how-to/install.md`, `docs/OVERVIEW.md` §9.15, and `docs/DEFERRED.md`.
- The text of helm chart ticket [07](../../helm-chart/issues/07-attest-published-chart.md) (`gh attestation verify … --repo biscuitbin/knarr`), helm chart ticket [08](../../helm-chart/issues/08-artifact-hub-listing.md) (the oras target) and bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md) (the verify command).

The install guide gains the new chart reference, a note that `v0.1.0` and `v0.2.0` are published at the old path, and an upgrade path from a `v0.2.0` install: `helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr --version 0.3.0 …` keeps the same release name, and the stamped chart supplies the new image repository.

**Non-goals:** Evidence under `.scratch/**/evidence/`, the hand-back notes of done tickets, historical `CHANGELOG.md` entries, the provenance links to `steven-cutting/libpawdoku` and `steven-cutting/biscuit_games_tooling`, the "Copied from" headers in `scripts/checks/*.py`, and the bodies of Decisions 0012 and 0015: they record what was true and stay. Publishing anything (05).

**Blocked by:** 01, 03

**MVP critical path:** no.

**Status:** done

- [x] Tests first: the pinned strings in `test_chart.py`, `test_workflows.py`, `stamp-chart_test.sh` and `lib_test.sh` name `biscuitbin`, and the hand-back records them failing before the code changes.
- [x] `release.yml`, `preflight.sh`, `Chart.yaml` and `NOTES.txt` name `biscuitbin`, and those tests pass.
- [x] `SECURITY.md`, the install guide, OVERVIEW §9.15 and DEFERRED name `biscuitbin`. The install guide carries the old-path note and the `v0.2.0` upgrade path above.
- [x] Helm chart tickets 07 and 08 and bootstrap ticket 38 use the new names.
- [x] `CHANGELOG.md` records the rename under Unreleased, and says `v0.3.0` is the first release under `ghcr.io/biscuitbin/…`.
- [x] The guard: `rg -n --hidden -g '!.git/**' -g '!.scratch/**' steven-cutting` leaves only the provenance links and the historical `CHANGELOG.md`, decision and install-guide lines kept on purpose. `.scratch/org-transfer/evidence/04/guard.txt` records the output, each remaining line with its reason.
- [x] `just format-check`, then the touched checker tests, then `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Implemented on 2026-10-23 (UTC), on `04-rename-live-references`.

### What changed

- Release image/chart destinations, OCI source label, preflight, chart metadata and notes, security reporting, current guides and the three follow-up tickets now use `biscuitbin`.
- The guard also found two live links in the operations guide; they now point to the same historical tags under the org. Historical changelog entries, decision bodies, existing evidence and completed hand-back notes were retained.
- The install guide distinguishes the retained `v0.1.0`/`v0.2.0` packages from `v0.3.0` onward and documents upgrading the existing release name with the new stamped chart. No version was bumped and nothing was published.
- [guard.txt](../evidence/04/guard.txt) records the requested search, with a reason for every remaining match.

### Verification and review

- Tests were edited before production files. `just test-checkers-selected chart policy release` then reported **3 failed, 211 passed**: the chart notes still linked the old repository, the packaged chart still had the old home/source, and the release workflow still published to the old namespace. The chart shell test reported **22 passed, 2 failed** on its home/source assertions.
- The probe helper's renamed input and expected URL in `lib_test.sh` stayed green: it accepts arbitrary repository names and has no production namespace constant. Likewise, changing stamp inputs alone would not fail; the added packaged home/source assertions supply the regression evidence. No artificial failure was introduced into those generic helpers.
- After implementation: `just format-check` passed; the same selected groups reported **214 passed**. `just docs-check` validated 37 pages and 49 canonical topics.
- The first full gate hit the sandbox's local-listener `Eperm` in `lint-gleam`, reproduced with that recipe alone. The local lint and gate were rerun with the permissions needed for loopback listeners. Cached pinned tools and copied package caches were used; no network initialization was needed.
- The final lint step required the now-shorter Python URL assertion to fit on one line; `just lint` reproduced it and `just fix` applied the formatter.
- `just check` completed with "All checks passed and the worktree is unchanged."
- Reviewed the full diff using the repository's `review-change` procedure (the requested `code-review` skill was not installed). No outstanding findings; controller behavior, specifications, pins, chart defaults and workflow permissions are unchanged.

### What later tickets need

- **05:** merge this change before pushing a release tag. Bump to `v0.3.0`, publish both packages under the org, verify visibility and anonymous pulls, and prove the `v0.2.0` upgrade on kind. This ticket does not claim that the new packages exist yet.
- **Helm chart 07/08 and bootstrap 38:** their attestation and Artifact Hub commands now name the org; their publishing work remains in those tickets.
