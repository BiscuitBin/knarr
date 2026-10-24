# 05: First release under the org, v0.3.0

**Context:** [04](04-rename-live-references.md) points the release at `ghcr.io/biscuitbin/knarr` and `oci://ghcr.io/biscuitbin/charts/knarr`, but neither package exists until a release runs. GHCR packages do not move with a transfer, so `v0.1.0` and `v0.2.0` stay at `ghcr.io/steven-cutting/…` ([Decision 0016](01-biscuitbin-decision.md)). The first push from the org's `GITHUB_TOKEN` creates both packages, linked to the repository. A new package is private by default, yet bootstrap ticket [37](../../bootstrap/issues/37-first-release-v0-1-0.md) found the image public from its first push. Under a new owner neither is assumed: both packages' visibility is checked.

**What to build:** `v0.3.0`, released from `biscuitbin/knarr` through the route 37 recorded, both packages public and pulled anonymously by digest, and a `v0.2.0` install migrated from the old chart reference to the new one on kind.

**Non-goals:** Changing the release workflow (a fix goes through 04's shape). Deleting or changing the `steven-cutting` packages. Attestation (helm chart 07, bootstrap 38). Artifact Hub (helm chart 08, which waits for this ticket).

**Blocked by:** 04

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** the release pull request, the tag push, the `release` environment approval and the network, through the route 37 recorded. The hand-back records the run URL and the image and chart digests its summary prints, both under `ghcr.io/biscuitbin/…`.
- [ ] **Authorization required:** the maintainer's package settings. `ghcr.io/biscuitbin/knarr` and `ghcr.io/biscuitbin/charts/knarr` are each linked to `biscuitbin/knarr` and public. If either is private, the maintainer makes it public by hand. `.scratch/org-transfer/evidence/05/public.txt` and `settings.txt` record both, in the shape of 37's [public.txt](../../bootstrap/evidence/37/public.txt) and [settings.txt](../../bootstrap/evidence/37/settings.txt).
- [ ] **Authorization required:** the network. An anonymous pull by digest of the image and of the chart succeeds: helm chart ticket 05's [19-published-anonymous-pull.sh](../../helm-chart/evidence/05/19-published-anonymous-pull.sh), adapted to the new names, writes its transcript beside it here.
- [ ] On a fresh kind cluster, a `v0.2.0` install from `oci://ghcr.io/steven-cutting/charts/knarr` is upgraded with `helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr --version 0.3.0`, keeping the release name. The controller rolls onto `ghcr.io/biscuitbin/knarr@<digest>`, keeps patching opted-in pods, and `just smoke`'s checks pass. Helm chart ticket 05's [15-published-install-upgrade.sh](../../helm-chart/evidence/05/15-published-install-upgrade.sh), adapted, writes the transcript here.
- [ ] Optional. **Authorization required:** the maintainer's package settings. The `steven-cutting` packages' descriptions point to the new location.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### Prepared, before any authorized step (2026-10-24 UTC)

- The release commit: `gleam.toml` and `charts/knarr/Chart.yaml` (`version`, `appVersion`) move from 0.2.0 to 0.3.0, and `CHANGELOG.md` moves `[Unreleased]` under `## [0.3.0] - 2026-10-24`, with an empty `[Unreleased]` above. The intro names 0.3.0 as the first release from `github.com/biscuitbin/knarr`, and the kustomize removal entry says 0.3.0, not "the next release", is the first without the overlay. No test pins the version: 40 made `metrics_test` and `reconciler_test` read it from `gleam.toml`. If the tag is not pushed on 2026-10-24 UTC, a pull request re-dates the heading first, as 40's #53 did; `just release-preflight` refuses a stale one.
- [`evidence/05/`](../evidence/05/README.md) holds the scripts for each remaining box, adapted from 40's and helm chart 05's, with no transcript yet. `public.sh` stops with a named not-public outcome on a refused anonymous token, and checks that 0.2.0 still answers under `steven-cutting`. `settings.sh packages` reads each package's visibility and linked repository from the API. The packages check and the refused-token branch were run offline against a stubbed `gh` and `curl`; nothing reached the network.
- TDD had no seam here: the change is a version bump and evidence scripts under `.scratch/`, which no test runs. `just check` ended with "All checks passed and the worktree is unchanged." on the staged tree.
- Next, each step only when the maintainer authorizes it: the release pull request and its merge; `git fetch`; `settings.sh before 25048585`; `just release-preflight v0.3.0 <merge commit>`; the tag push; the `release` approval; `run.sh`, `public.sh`, `settings.sh packages`, `pull.sh`, `anonymous-pull.sh`; then `just fake-worker-image-build` and `upgrade.sh` on kind.
