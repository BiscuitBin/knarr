# 01: Decision 0016: knarr's home is biscuitbin

**Context:** knarr lives at `github.com/steven-cutting/knarr`. [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) publishes its image to `ghcr.io/steven-cutting/knarr`, and [Decision 0015](../../../docs/decisions/0015-helm-chart.md) publishes its chart to `oci://ghcr.io/steven-cutting/charts/knarr`. The maintainer wants `github.com/biscuitbin/knarr` to be knarr's home, with future releases published under `ghcr.io/biscuitbin/…`.

The maintainer settled these points in the planning session on 2026-10-21:

- **Mechanism.** GitHub's own repository transfer. It is expected to keep issues, pull requests, stars, environments, rulesets and secrets, and to redirect the old git and web URLs. Nothing here assumes it: the snapshot in [02](02-org-readiness-snapshot.md) and the diff in [03](03-transfer-repository.md) are what prove it.
- **Published packages.** GHCR packages do not move with a transfer. `v0.1.0` and `v0.2.0` stay at `ghcr.io/steven-cutting/…` as history. The next release, `v0.3.0`, is the first one published under `ghcr.io/biscuitbin/…`.
- **No release between 03 and 04.** After the transfer, `release.yml` still names `ghcr.io/steven-cutting/…`, and the org repository's `GITHUB_TOKEN` cannot push there. Nobody pushes a tag until [04](04-rename-live-references.md) merges.
- **Provenance links stay.** The links to `steven-cutting/libpawdoku` and `steven-cutting/biscuit_games_tooling`, in the decision records and in the headers of copied scripts, are not changed.

**What to build:** A new decision record, `docs/decisions/0016-biscuitbin-org.md`, registered in the docs manifest, the decisions index and the docs index. It decides:

- **The move.** The repository moves by GitHub's transfer, not by a new repository and a push, so its history, issues, pull requests and settings travel with it, and the old URLs redirect.
- **Registry paths.** `ghcr.io/biscuitbin/knarr` and `oci://ghcr.io/biscuitbin/charts/knarr` from `v0.3.0`. `v0.1.0` and `v0.2.0` stay at the old paths, unchanged and never deleted.
- **The old name is never reused.** Nobody ever creates a new `steven-cutting/knarr`, because that would break GitHub's redirects.
- **What changes and what stays.** The live references change in 04. Evidence, the hand-back notes of done tickets, historical `CHANGELOG.md` entries, the provenance links and the bodies of 0012 and 0015 stay. 0012 and 0015 gain "Amended by 0016" notes rather than being rewritten.
- **Sequencing.** 02, 03, 04, then 05. Helm chart ticket 08 (Artifact Hub) waits for 05, so the listing is registered once, under the org. Helm chart ticket 07 and bootstrap ticket 38 use the new names, which 04 writes into their text.

**Non-goals:** Any GitHub-side action (02, 03, 05). Renaming a live reference (04). Changing a workflow, a script, the chart or a test.

**Blocked by:** None (can start immediately).

**MVP critical path:** no.

**Status:** done. The record is written and registered, and the gate passes. See [the hand-back notes](#hand-back-notes).

- [ ] Optional. **Authorization required:** the network, for the fetch. `.scratch/org-transfer/evidence/01/sources.txt` records GitHub's pages on transferring a repository and on the container registry, with each page's HTTP status, size and sha256 and the phrase each claim rests on, in the shape of helm chart ticket 01's [sources.txt](../../helm-chart/evidence/01/sources.txt), with a `sources.sh` beside it.
- [x] Decision 0016 records each decision above. It says plainly that the transfer's effects are expected, not assumed, and that 02's snapshot and 03's diff prove them.
- [x] 0012's "Registry and name" and "Digest" bullets and 0015's "The reference is" and "The release stamps the image" bullets each carry an "Amended by Decision 0016" note. Their bodies are unchanged.
- [x] 0016 is registered in `docs/manifest.yml`, the [decisions index](../../../docs/decisions/README.md) and the [docs index](../../../docs/README.md).
- [x] Helm chart ticket 08's **Blocked by** line names this round's 05, and the [helm chart round's README](../../helm-chart/README.md) diagram and waves table say the same.
- [x] The record names the tickets that carry it out: 02 to 05 in this directory.
- [x] `CHANGELOG.md` records the decision under Unreleased.
- [x] `just docs-check` passes, and `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Written on 2026-10-21 (UTC), from the maintainer's choices in that day's planning session.

### What changed

- New [Decision 0016](../../../docs/decisions/0016-biscuitbin-org.md), registered in `docs/manifest.yml`, the [decisions index](../../../docs/decisions/README.md) and the [docs index](../../../docs/README.md).
- Amendment notes, appended to the bullets and leaving their bodies unchanged: [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) "Registry and name" and "Digest", and [Decision 0015](../../../docs/decisions/0015-helm-chart.md) "The reference is" and "The release stamps the image".
- Helm chart ticket [08](../../helm-chart/issues/08-artifact-hub-listing.md) is blocked by this round's 05, and the [helm chart round's README](../../helm-chart/README.md) diagram and text say so. Its waves table is unchanged, since 05 is an external dependency there.
- This round's [README](../README.md) and tickets 02 to 05.
- `CHANGELOG.md` records the decision under Unreleased, Changed.

### What was verified, and what was not

- `validate_docs.py` (what `just docs-check` runs), run from this worktree with the main checkout's tools on `PATH`: "Validated 37 pages and 49 canonical topics." markdownlint-cli2 on every changed Markdown file: 0 issues.
- `just check` ends with "All checks passed and the worktree is unchanged.", run after the maintainer ran `just initialize` in this worktree.
- Not done: the optional sources fetch. 0016 states the transfer's effects as expected and leaves the proof to 02 and 03. Nothing moved the repository, changed a setting or pushed a package.

### What each later ticket needs

- **02:** the snapshot script takes the owner as a parameter, so 03 reruns it unchanged.
- **03:** diff by name the `release` environment's reviewers and branch and tag policy, the tag ruleset and `main`'s required checks. No release tag is pushed from here until 04 merges.
- **04:** the surfaces and the keep-list are in 0016's "What changes and what stays". The guard's remaining lines each need a reason in `guard.txt`.
- **05:** check both packages' visibility; neither is assumed public. Helm chart 08 unblocks when it is done.
