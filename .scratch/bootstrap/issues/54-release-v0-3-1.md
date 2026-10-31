# 54: Fix the README's status and release v0.3.1

**Context:** The [README](../../../README.md) still describes the `v0.1.0` walking skeleton: "Status: pre-MVP", a controller that "does not yet read or change Kubernetes objects". That stopped being true at `v0.2.0`, which [ticket 40](40-mvp-release.md) released as the MVP's controller. `SECURITY.md`, `CONTRIBUTING.md`, the handbook index and the first tutorial are stale in the same way, and `SECURITY.md` names no supported release. Separately, `CHANGELOG.md`'s `[Unreleased]` section carries Erlang/OTP 29.1.2, which fixes CVE-2026-94200 (High), from [ticket 52](52-otp-and-base-image-advisories.md), rebar3 3.28.0 from [ticket 53](53-rebar3-hex-core-advisory.md), and the install guide's `--signer-workflow` case fix from [helm-chart 07](../../helm-chart/issues/07-attest-published-chart.md). No published image contains them: `v0.3.1-rc.1` (`b71fd32`) predates ticket 52's `17d16d5`. Releasing `v0.3.1` makes it the first stable release with image and chart attestations, and the first published image on the patched OTP.

**What to build:**

- **The status text.** The README states what the released controller does, from the specifications under `docs/specs/`, and what it never does, that the safe-to-evict policy is deferred, and that the MVP's acceptance on GKE Standard ([ticket 39](39-gke-production-rollout.md)) has not happened. It links the install guide. `CONTRIBUTING.md`, `docs/README.md` and `docs/tutorials/README.md` drop "pre-MVP" and the walking skeleton.
- **The support policy.** `SECURITY.md` supports the latest stable release and current `main`. A fix ships as a new patch release cut from `main`; older releases and prereleases are not supported. The policy lives in `SECURITY.md` only, with no decision record.
- **The release.** `gleam.toml` and `charts/knarr/Chart.yaml` (`version`, `appVersion`) move from 0.3.1-rc.1 to 0.3.1. `CHANGELOG.md` moves `[Unreleased]` under `## [0.3.1] - YYYY-MM-DD`, dated the UTC day the tag is pushed. The install guide names `v0.3.1` as the first stable release with attestations. `v0.3.1` is released through the route [ticket 37](37-first-release-v0-1-0.md) recorded and [org-transfer 05](../../org-transfer/issues/05-first-release-under-org.md) followed, then verified and scanned by digest.

**Non-goals:**

- arm64, SBOM and provenance ([ticket 38](38-attestations-sbom-arm64.md)'s open boxes).
- Artifact Hub ([helm-chart 08](../../helm-chart/issues/08-artifact-hub-listing.md)).
- Renovate's activation ([ticket 44](44-renovate-activation.md)).
- Any change to controller behaviour.
- The GKE rollout ([ticket 39](39-gke-production-rollout.md)).

**Blocked by:** 52, 53. Both are done.

**MVP critical path:** no. It is a documentation fix and a patch release.

**Status:** done once its evidence pull request merges. `v0.3.1` is published as `ghcr.io/biscuitbin/knarr@sha256:8b89fd1c08c5170bec456df522d48e7b78431859d7c135993fc14327533ea385`, with the chart `oci://ghcr.io/biscuitbin/charts/knarr@sha256:1c4d28f935009f6306450b13758fb60866a596cc4b1c4f0d02359a69343ae013`, both attested. The last box stays open until that pull request merges. See [the hand-back notes](#hand-back-notes) and [the evidence](../evidence/54/README.md).

- [x] The status text is fixed in `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `docs/README.md` and `docs/tutorials/README.md`.
- [x] `gleam.toml` and `charts/knarr/Chart.yaml` name 0.3.1, and `CHANGELOG.md` moves `[Unreleased]` under `## [0.3.1]`.
- [x] The install guide names `v0.3.1` as the first stable release with attestations, and its upgrade from `v0.2.0` names `--version 0.3.1`.
- [x] `just check` ends with "All checks passed and the worktree is unchanged.", and `git status --short` is empty.
- [x] **Authorization required:** push the branch.
- [x] **Authorization required:** open the release pull request with `gh`.
- [x] **Authorization required:** merge it.
- [x] **Authorization required:** `git fetch`, then `just release-preflight v0.3.1 <merge commit>` exits 0, with its transcript in `evidence/54/preflight.txt`.
- [x] **Authorization required:** push the annotated tag `v0.3.1` on the merge commit.
- [x] **Authorization required:** the maintainer approves the `release` environment in GitHub.
- [x] **Authorization required:** `gh run view` reads the run: both jobs green, the tags `0.3.1`, `0.3` and `sha-` with the merge commit's first seven characters, and the image and chart digests from its summary.
- [x] **Authorization required:** the install guide's `gh attestation verify` commands pass for both digests, and the chart's stamped digest is the image's.
- [x] **Authorization required:** `just audit-install`, then `just image-scan` and `just runtime-scan` on the published digest, with `v0.3.1-rc.1`'s digest as a control.
- [x] Ticket 38's last box is split, and its attestation half names 0.3.1-rc.1 as the first prerelease and 0.3.1 as the first stable release to carry attestations.
- [ ] **Authorization required:** push, open and merge the evidence pull request.

## Hand-back notes

### Prepared, before any authorized step (2026-10-30 UTC)

- **Worktree.** Branch `54-release-v0-3-1`, created with Supacode from `main` at `3c225c7`.
- **Status text.** `README.md`'s opening is in the present tense, and its status paragraph, "Status: early, pre-1.0", draws each claim from a specification:
  - discovery of the Deployments labelled `knarr.io/enabled=true` in knarr's namespace (config `OptIn`, `Discovery`);
  - the poll of `GET /knarr/v1/status` (worker_contract);
  - the `pod-deletion-cost` mapping (cost_mapping);
  - the JSON Patch and the `knarr.io/applied` marker (ownership);
  - cleanup on opt-out (lifecycle `Cleanup`);
  - the probes and metrics (knarr `Diagnostics`, observability);
  - no replica or pod-template change and no patch of a terminating pod (ownership `Objects`, reconcile `Terminating`).

  The README links the install guide, and its local cluster line says the guide deploys the chart on kind.
- **A deviation from the plan.** The plan had the README say the controller writes "the optional `safe-to-evict`". It does not: [the configuration reference](../../../docs/reference/configuration.md#deferred-safe-to-evict-feature) and `OVERVIEW.md` record that policy as deferred, and `safe_to_evict.allium` holds only open questions for ticket 25. The README now says the opt-in is reserved and that knarr writes no protection, and its opening sentence no longer names `safe-to-evict`.
- **SECURITY.md.** It states the maintainer's policy and lists 0.3.1 as the latest stable release. 0.3.1 does not exist until the tag is pushed. That is deliberate: this is the release commit, as the changelog heading is.
- **Also stale, and fixed here:** `CONTRIBUTING.md`'s first line, `docs/README.md`'s description of the local cluster guide and of the README, and `docs/tutorials/README.md`'s opening and closing sentences.
- **Left as it is:** `docs/how-to/local-cluster.md`'s title, "Run the walking skeleton locally". Renaming it touches `docs/manifest.yml`, the page's frontmatter, `docs/README.md` and Decision 0013's link text, so it is later work. The README's Specifications section still calls the root module a skeleton, which is true of `knarr.allium`. Three records stay, because each states what was decided at the time: Decision 0016's `--version 0.3.0` upgrade, Decision 0012's deferral of attestations to ticket 38, and `docs/DEFERRED.md`'s note on signing, SBOM and provenance.
- **The release commit.** `gleam.toml` and `charts/knarr/Chart.yaml` move to 0.3.1, and nothing else pins the version: a search for `0.3.1-rc.1` outside `CHANGELOG.md` and `.scratch/` found only those three lines. `CHANGELOG.md` moves `[Unreleased]` under `## [0.3.1] - 2026-10-30`, adding a Changed entry for the support policy and the install guide's upgrade example, and a Fixed entry for the status text. The intro names 0.3.1 as the first stable release with attestations and the first published image with OTP 29.1.2 and rebar3 3.28.0. If the tag is not pushed on 2026-10-30 UTC, a pull request re-dates the heading first, as 40's #53 did; `just release-preflight` refuses a stale one.
- **The install guide.** Its Verify section names `v0.3.1-rc.1` as the first prerelease and `v0.3.1` as the first stable release with attestations. Its upgrade from a `v0.2.0` Helm install names `--version 0.3.1`: recommending 0.3.0 would install CVE-2026-94200.
- **The bootstrap index** gains ticket 54, blocked by 52 and 53, in wave 10.
- **Verified.** The maintainer authorized `just initialize` in this worktree. It verified rebar3 3.28.0's Sigstore bundle and installed every pin. `just docs-check` validated 37 pages. `just format-check` and `just build` passed, and `just test` reports 676 passed with no failures, so the tests that read the version from `gleam.toml` accept 0.3.1. Before the merge, `just release-preflight` stops at its ancestry check against `origin/main`, so its version guards were run by hand from `scripts/release/lib.sh` on this branch: `changelog_has_version 0.3.1` returned 0, `changelog_date 0.3.1` printed `2026-10-30`, `tag_matches_version v0.3.1 0.3.1` returned 0, and `tags_for` gives `0.3.1`, `0.3` and `sha-` with the commit's first seven characters. TDD had no seam here: the change is prose, a version bump and the changelog. `just check` ended with "All checks passed and the worktree is unchanged." on the staged tree.
- **Next,** each step only when the maintainer authorizes it: push the branch; open the pull request; merge it; `git fetch`; `just release-preflight v0.3.1 <merge commit>`; push the tag; the `release` approval; then the run, the verification and the scans under `evidence/54/`, and the evidence pull request.

### Released (2026-10-30 UTC)

Every step that left the worktree was authorized by the maintainer, one at a time, except one read-only `git fetch --tags` for the `git diff v0.3.0 v0.3.1` below, which fetched nothing new; [the evidence README](../evidence/54/README.md) lists each action and the one failed attempt.

#### What changed

- Pull request [#72](https://github.com/BiscuitBin/knarr/pull/72) passed every job of `ci.yml` run [41008705513](https://github.com/BiscuitBin/knarr/actions/runs/41008705513), and the maintainer merged it as `6e2428ced066ebb05b9b73a0be12825550f3488e` at 05:52 UTC.
- Tag `v0.3.1`, annotated with message `v0.3.1` (object `95b0b89`), on that merge commit at 06:46 UTC, after `just release-preflight` passed.
- Run [41016018897](https://github.com/BiscuitBin/knarr/actions/runs/41016018897) waited for the `release` approval until 23:40 UTC, then published the image `ghcr.io/biscuitbin/knarr@sha256:8b89fd1c08c5170bec456df522d48e7b78431859d7c135993fc14327533ea385` (tags `0.3.1`, `0.3`, `sha-6e2428c`) and the chart `ghcr.io/biscuitbin/charts/knarr:0.3.1` at `sha256:1c4d28f935009f6306450b13758fb60866a596cc4b1c4f0d02359a69343ae013`. It attested both: [61979711](https://github.com/BiscuitBin/knarr/attestations/61979711) and [61979733](https://github.com/BiscuitBin/knarr/attestations/61979733).
- The `0.3` tag moved from `v0.3.0`'s image to this one. No package was new, so no visibility step was needed.
- Ticket 38's last box is split. The attestation half is ticked with 0.3.1's timings, and the SBOM, provenance and arm64 half stays open.
- `evidence/54/` holds `run.sh`, `verify.sh` and `scan.sh`, each with its transcript, and `preflight.txt`.

#### What was verified

- [preflight.txt](../evidence/54/preflight.txt): the tag matches `gleam.toml`, the commit is `origin/main`, the changelog heading is `## [0.3.1] - 2026-10-30`, and the chart stamps as `knarr-0.3.1.tgz`.
- [run.txt](../evidence/54/run.txt):
  - both jobs green;
  - the approval by user 8365892 on environment `23921538204`;
  - every existence guard `absent (http 404)`;
  - exactly the three image tags, and one image digest;
  - the chart stamped with that digest and pushed;
  - both attest steps green, 20 s for the image and 7 s for the chart, in a 72 s publish job;
  - their `Attestation created for` lines name exactly the two published digests;
  - the annotated tag on the remote.
- [verify.txt](../evidence/54/verify.txt): `gh attestation verify` passes for the image and the chart, from GitHub and from ghcr.io, with the guide's `--signer-workflow BiscuitBin/knarr/.github/workflows/release.yml`. The guide's `helm show values … | grep 'digest:'` prints the image digest.
- [scan.txt](../evidence/54/scan.txt), on grype 0.120.1 with a database built 2026-10-30T06:23Z:
  - **v0.3.1:** `just image-scan` finds no vulnerabilities and exits 0. `just runtime-scan` catalogues 12 conda packages, finds no fixable high or critical vulnerability, and exits 0.
  - **The control, `v0.3.1-rc.1`:** both scans exit 2. `image-scan` lists CVE-2026-94200 (High) in erlang 29.1.1, CVE-2026-84782 (High) in `libssl3t64` 3.0.13-0ubuntu3.15, and lower findings in libssl and zlib. `runtime-scan` lists CVE-2026-94200, CVE-2026-105236 and CVE-2026-96596 in erlang 29.1.1.
  - **rebar3:** it is not in the runtime image, so neither scan reads it. Ticket 53's fix is in the build stage, not in anything scanned here.
- **Not done:** an install or upgrade of `v0.3.1` on a cluster. `git diff v0.3.0 v0.3.1` changes only `version` and `appVersion` under `charts/` and nothing under `src/`, so the release differs from `v0.3.0` in the image's build only, and 05's upgrade from `v0.2.0` covered the route.

#### What later tickets need

- **SECURITY.md names the supported release by hand.** Its table says "0.3.1, the latest stable release", and nothing holds that row equal to `gleam.toml` the way `just chart-check` holds `Chart.yaml`. Every release pull request has to update it. A check could hold it, or the row could say "the latest stable release" with no version.
- **The local cluster guide's title**, "Run the walking skeleton locally", is still stale. Renaming it touches `docs/manifest.yml`, the page's frontmatter, `docs/README.md` and Decision 0013's link text.
- **Ticket 38** keeps the SBOM, provenance and arm64 boxes, and the storage-record question.
- **Ticket 39**, the GKE Standard rollout, can now install a stable release with OTP 29.1.2 and verifiable attestations.
