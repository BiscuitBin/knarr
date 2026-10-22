---
title: "Decision 0016: knarr's home is the biscuitbin org"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_biscuitbin_org]
requires: []
---

# Decision 0016: knarr's home is the biscuitbin org

## Context

knarr lives at `github.com/steven-cutting/knarr`, under the maintainer's personal account. [Decision 0012](0012-release-and-packaging.md) publishes its image to `ghcr.io/steven-cutting/knarr`, and [Decision 0015](0015-helm-chart.md) publishes its chart to `oci://ghcr.io/steven-cutting/charts/knarr`. `v0.1.0` and `v0.2.0` are published there. The maintainer wants `github.com/biscuitbin/knarr` to be knarr's home, with future releases published under `ghcr.io/biscuitbin/…`.

The maintainer settled the choices below in the planning session on 2026-10-21. Nothing here moved the repository, changed a setting, pushed a package or fetched a page. What a transfer carries over is stated as expected, as the maintainer and the agent understood it in the planning session, where no GitHub page was fetched, and is proven by the round's own evidence: [ticket 02](../../.scratch/org-transfer/issues/02-org-readiness-snapshot.md) records the repository's settings before the move, and [ticket 03](../../.scratch/org-transfer/issues/03-transfer-repository.md) records them after it and diffs the two.

## Decision

### The move

- **The repository moves by GitHub's repository transfer** to the `biscuitbin` org, not by creating a new repository and pushing to it. A transfer is expected to keep the history, issues, pull requests, stars, environments, rulesets and secrets, and to redirect the old web and git URLs to the new ones. A new repository would keep only the history. Ticket 03's settings diff is what shows the `release` environment's reviewers and branch and tag policy, the tag ruleset and `main`'s required checks survived; anything that did not is restored there.
- **The old name is never reused.** Nobody ever creates a new repository named `steven-cutting/knarr`. GitHub's redirects from the old URLs hold only while that name is free, and a clone, a link or a GHCR package link that still names it depends on them.

### Registry paths

- **From `v0.3.0`, releases publish to `ghcr.io/biscuitbin/knarr` and `oci://ghcr.io/biscuitbin/charts/knarr`.** GHCR packages belong to their owner's namespace and do not move with a repository transfer, and the org repository's `GITHUB_TOKEN` cannot push to the maintainer's personal namespace. The first release from the org creates both packages, linked to the repository by the image's `org.opencontainers.image.source` label and by the push. A new package is private by default, and bootstrap ticket 37 found the image public from its first push anyway, so [ticket 05](../../.scratch/org-transfer/issues/05-first-release-under-org.md) checks both packages' visibility rather than assuming either.
- **`v0.1.0` and `v0.2.0` stay where they are.** Their image and chart at `ghcr.io/steven-cutting/…` are left unchanged and are never deleted, because 0012 publishes a release once and an install pinned to their digests must keep pulling. Nothing pushes to the old namespace again.
- **A `v0.2.0` install moves by `helm upgrade`.** `helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr --version 0.3.0` keeps the release name, and the stamped chart supplies the new image repository. Ticket 05 proves it on kind, and ticket 04 documents it in the install guide.

### No release between the transfer and the rename

After ticket 03's transfer, `release.yml` still names `ghcr.io/steven-cutting/…`, which the org's `GITHUB_TOKEN` cannot write. A tag pushed in that window would fail at the image push. Nobody pushes a release tag until [ticket 04](../../.scratch/org-transfer/issues/04-rename-live-references.md) merges.

### What changes and what stays

- **Ticket 04 renames the live references:** the release workflow and scripts, their tests, the chart's `home`, `sources` and `NOTES.txt`, `SECURITY.md`'s reporting link, the install guide, [OVERVIEW §9.15](../OVERVIEW.md#9-open-questions-candidate-tickets), [DEFERRED §8](../DEFERRED.md#8-other-future-targets), and the open tickets that name the old namespace.
- **What stays, on purpose:** everything under `.scratch/**/evidence/` and the hand-back notes of done tickets, because a recorded fact is not rewritten; the historical `CHANGELOG.md` entries; the provenance links to `steven-cutting/libpawdoku` and `steven-cutting/biscuit_games_tooling`, in the decision records and in the headers of copied scripts, which name where the code came from and are not knarr's; and the bodies of 0012 and 0015. Those two records carry an "Amended by Decision 0016" note on the bullets that name the old paths rather than being rewritten.

### Sequencing

Tickets 01 to 05 in [`.scratch/org-transfer/issues/`](../../.scratch/org-transfer/README.md) run in order: 02 and 03 before 04, and 04 before 05. Helm chart ticket [08](../../.scratch/helm-chart/issues/08-artifact-hub-listing.md) waits for 05, so the Artifact Hub listing is registered once, under the org. Helm chart ticket [07](../../.scratch/helm-chart/issues/07-attest-published-chart.md) and bootstrap ticket [38](../../.scratch/bootstrap/issues/38-attestations-sbom-arm64.md) verify attestations with `--repo biscuitbin/knarr`, and ticket 04 writes the new names into their text. No attestation is live yet, so none is invalidated by the move.

## Verification

- `just docs-check` and `just check` pass on the change that adds this record.
- The transfer's effects are verified by ticket 03's settings diff against ticket 02's snapshot, and by ticket 03's runs under the org: the required `check` on a pull request, and successful (not skipped) `keda-e2e`, `reconcile-proof` and `audit` runs.
- The new registry paths are verified by ticket 05's release run summary, the anonymous pulls by digest and the `helm upgrade` from a `v0.2.0` install on kind.

## Consequences

The tickets that carry this record out are in [`.scratch/org-transfer/issues/`](../../.scratch/org-transfer/README.md):

- **[02](../../.scratch/org-transfer/issues/02-org-readiness-snapshot.md)** records the repository's settings and checks that the org lets the workflows run and publish.
- **[03](../../.scratch/org-transfer/issues/03-transfer-repository.md)** transfers the repository, diffs the settings, updates the remotes and runs every workflow under the org.
- **[04](../../.scratch/org-transfer/issues/04-rename-live-references.md)** renames the live references, test first, and documents the move in the install guide.
- **[05](../../.scratch/org-transfer/issues/05-first-release-under-org.md)** releases `v0.3.0` under the org, makes both packages public, and migrates a `v0.2.0` install.

Risks the round accepts: the old packages stay linked to a repository that now belongs to the org, and their repository-link permissions can drift, but nothing pushes to them again. Remotes in other clones keep working through the redirect, and ticket 03 updates them anyway.

## What would reopen this

- **Someone creates `steven-cutting/knarr`,** breaking the redirects: every remaining reference to the old URLs must then be found and changed.
- **GHCR starts moving packages with a transfer,** or offers a way to move them: the old releases could then move with the repository.
- **knarr moves again:** a new record, in the shape of this one.

## Related pages

- [Decision 0012: Release and packaging](0012-release-and-packaging.md), whose registry path this record changes from `v0.3.0`
- [Decision 0015: knarr ships a Helm chart](0015-helm-chart.md), whose chart reference this record changes from `v0.3.0`
- [The org transfer round](../../.scratch/org-transfer/README.md) and [ticket 01](../../.scratch/org-transfer/issues/01-biscuitbin-decision.md)
