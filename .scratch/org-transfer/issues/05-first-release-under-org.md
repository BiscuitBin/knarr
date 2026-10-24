# 05: First release under the org, v0.3.0

**Context:** [04](04-rename-live-references.md) points the release at `ghcr.io/biscuitbin/knarr` and `oci://ghcr.io/biscuitbin/charts/knarr`, but neither package exists until a release runs. GHCR packages do not move with a transfer, so `v0.1.0` and `v0.2.0` stay at `ghcr.io/steven-cutting/…` ([Decision 0016](01-biscuitbin-decision.md)). The first push from the org's `GITHUB_TOKEN` creates both packages, linked to the repository. A new package is private by default, yet bootstrap ticket [37](../../bootstrap/issues/37-first-release-v0-1-0.md) found the image public from its first push. Under a new owner neither is assumed: both packages' visibility is checked.

**What to build:** `v0.3.0`, released from `biscuitbin/knarr` through the route 37 recorded, both packages public and pulled anonymously by digest, and a `v0.2.0` install migrated from the old chart reference to the new one on kind.

**Non-goals:** Changing the release workflow (a fix goes through 04's shape). Deleting or changing the `steven-cutting` packages. Attestation (helm chart 07, bootstrap 38). Artifact Hub (helm chart 08, which waits for this ticket).

**Blocked by:** 04

**MVP critical path:** no.

**Status:** done. `v0.3.0` is published as `ghcr.io/biscuitbin/knarr@sha256:a0758098d2e2a28ea528ac8bf4b8f675b61f2a75d375e60995afb6a82d22db84`, with the chart `oci://ghcr.io/biscuitbin/charts/knarr@sha256:1500c5139ff5fbff7c658d2f001d9b7e421ff9435333ad28df7aa5f86d6bb2b7`, both public. The optional `steven-cutting` package descriptions are not done. See [the hand-back notes](#hand-back-notes) and [the evidence](../evidence/05/README.md).

- [x] **Authorization required:** the release pull request, the tag push, the `release` environment approval and the network, through the route 37 recorded. The hand-back records the run URL and the image and chart digests its summary prints, both under `ghcr.io/biscuitbin/…`.
- [x] **Authorization required:** the maintainer's package settings. `ghcr.io/biscuitbin/knarr` and `ghcr.io/biscuitbin/charts/knarr` are each linked to `biscuitbin/knarr` and public. If either is private, the maintainer makes it public by hand. `.scratch/org-transfer/evidence/05/public.txt` and `settings.txt` record both, in the shape of 37's [public.txt](../../bootstrap/evidence/37/public.txt) and [settings.txt](../../bootstrap/evidence/37/settings.txt).
- [x] **Authorization required:** the network. An anonymous pull by digest of the image and of the chart succeeds: helm chart ticket 05's [19-published-anonymous-pull.sh](../../helm-chart/evidence/05/19-published-anonymous-pull.sh), adapted to the new names, writes its transcript beside it here.
- [x] On a fresh kind cluster, a `v0.2.0` install from `oci://ghcr.io/steven-cutting/charts/knarr` is upgraded with `helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr --version 0.3.0`, keeping the release name. The controller rolls onto `ghcr.io/biscuitbin/knarr@<digest>`, keeps patching opted-in pods, and `just smoke`'s checks pass. Helm chart ticket 05's [15-published-install-upgrade.sh](../../helm-chart/evidence/05/15-published-install-upgrade.sh), adapted, writes the transcript here.
- [ ] Optional. **Authorization required:** the maintainer's package settings. The `steven-cutting` packages' descriptions point to the new location.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### Prepared, before any authorized step (2026-10-24 UTC)

- The release commit: `gleam.toml` and `charts/knarr/Chart.yaml` (`version`, `appVersion`) move from 0.2.0 to 0.3.0, and `CHANGELOG.md` moves `[Unreleased]` under `## [0.3.0] - 2026-10-24`, with an empty `[Unreleased]` above. The intro names 0.3.0 as the first release from `github.com/biscuitbin/knarr`, and the kustomize removal entry says 0.3.0, not "the next release", is the first without the overlay. No test pins the version: 40 made `metrics_test` and `reconciler_test` read it from `gleam.toml`. If the tag is not pushed on 2026-10-24 UTC, a pull request re-dates the heading first, as 40's #53 did; `just release-preflight` refuses a stale one.
- [`evidence/05/`](../evidence/05/README.md) holds the scripts for each remaining box, adapted from 40's and helm chart 05's, with no transcript yet. `public.sh` stops with a named not-public outcome on a refused anonymous token, and checks that 0.2.0 still answers under `steven-cutting`. `settings.sh packages` reads each package's visibility and linked repository from the API. The packages check and the refused-token branch were run offline against a stubbed `gh` and `curl`; nothing reached the network.
- TDD had no seam here: the change is a version bump and evidence scripts under `.scratch/`, which no test runs. `just check` ended with "All checks passed and the worktree is unchanged." on the staged tree.
- Next, each step only when the maintainer authorizes it: the release pull request and its merge; `git fetch`; `settings.sh before 25048585`; `just release-preflight v0.3.0 <merge commit>`; the tag push; the `release` approval; `run.sh`, `public.sh`, `settings.sh packages`, `pull.sh`, `anonymous-pull.sh`; then `just fake-worker-image-build` and `upgrade.sh` on kind.

### Released (2026-10-24 UTC)

Every step that left the worktree was authorized by the maintainer: the merge of #61, the fetch, the tag push, the `release` approval, and the network for the evidence. [The evidence README](../evidence/05/README.md) lists each action and each failed attempt.

#### What changed

- Tag `v0.3.0`, annotated with message `v0.3.0` (object `03172b2`), on the merge commit `7c88ec9c982b8eee33cc8d38f34e327c7b2f9acb`, after `settings.sh before 25048585` and `just release-preflight` passed.
- Run [40068527393](https://github.com/BiscuitBin/knarr/actions/runs/40068527393) published the image `ghcr.io/biscuitbin/knarr@sha256:a0758098d2e2a28ea528ac8bf4b8f675b61f2a75d375e60995afb6a82d22db84` (tags `0.3.0`, `0.3`, `sha-7c88ec9`) and the chart `ghcr.io/biscuitbin/charts/knarr:0.3.0` at `sha256:1500c5139ff5fbff7c658d2f001d9b7e421ff9435333ad28df7aa5f86d6bb2b7`.
- Both packages were private from their first push. Under Settings → Member privileges → Package creation, the maintainer allowed org members to create public and internal packages, then made each package public by hand. Ticket 02's UI reading ([org.txt](../evidence/02/org.txt), line 53) recorded that setting as "public allowed", but public visibility was not available here until the maintainer changed it. This evidence cannot tell whether 02's reading was wrong or the setting changed after it. Both are linked to `BiscuitBin/knarr`.
- `anonymous-pull.sh` reads the one file `helm pull` writes: Helm 4 names a chart pulled by digest `knarr@sha256-<hex>.tgz`.
- The transcripts beside each script in `evidence/05/`.
- `.pre-commit-config.yaml`: editorconfig-checker skips `.scratch/org-transfer/evidence/` as it already skips bootstrap's and helm chart's evidence, since transcripts are recorded tool output kept byte for byte. `upgrade.txt` failed it on trailing whitespace from `kubectl` and `helm` tables.

#### What was verified

- `settings.sh before` and the preflight exited 0 with only `ok` and `info` lines. `git ls-remote` shows `v0.3.0^{}` at `7c88ec9`.
- `run.sh`: both jobs green; the approval by user 8365892 on environment `23921538204`; both existence guards `absent (http 404)`; exactly the three image tags; one image digest; the chart stamped with it and pushed; the annotated tag on the remote.
- `public.sh`: every image tag and the digest answer 200 at the run's digest with an anonymous token, `latest` 404; the chart manifest, layer, `Chart.yaml` and `values.yaml` name 0.3.0 and the image digest; 0.2.0 still answers at its digests under `steven-cutting`.
- `settings.sh packages`: `knarr` and `charts/knarr` are public and linked to `BiscuitBin/knarr`.
- `pull.sh`: the image pulled by digest on a fresh daemon with no credentials, labelled version 0.3.0, revision `7c88ec9`, source `https://github.com/biscuitbin/knarr`.
- `anonymous-pull.sh`: the chart pulled by digest with empty Helm and Docker configuration, its stamped values checked.
- `upgrade.sh` on kind: `v0.2.0` from the `steven-cutting` chart upgraded in place to the `biscuitbin` chart 0.3.0 as revision 2 of release `knarr`; the controller pod runs `ghcr.io/biscuitbin/knarr@sha256:a075…`; its metrics count three owned annotations; a worker raised to 3600 got a new pod-deletion-cost; `just smoke` passed `/healthz`, `/readyz` and `/metrics` before and after.
- `just check` ended with "All checks passed and the worktree is unchanged." on the staged tree.

#### For later tickets

- Helm chart 08 (Artifact Hub) can start: the chart is public at `oci://ghcr.io/biscuitbin/charts/knarr`.
- A new package under the org started private here. The next package the release creates needs the same manual visibility step.
- `settings.sh packages` needs a token with `read:packages`.
- The optional box, the `steven-cutting` package descriptions, is left to the maintainer.
