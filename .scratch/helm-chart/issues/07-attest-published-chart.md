# 07: Attest the published chart

**Context:** Bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md) adds `actions/attest-build-provenance` to the publish job for the image, with `push-to-registry`, and documents `gh attestation verify`. [Decision 0015](01-helm-chart-decision.md) defers signing and attestation of the chart until that lands, so that the image and the chart are attested the same way, by one mechanism.

**What to build:** On the publish job from [04](04-release-publishes-chart.md), an `attest-build-provenance` step on the chart's digest that matches 38's image step. The install guide gains `gh attestation verify oci://ghcr.io/biscuitbin/charts/knarr@<digest> --repo biscuitbin/knarr`.

**Non-goals:** cosign keyless signing or a Helm `.prov` file, unless a consumer asks. Any permission beyond those 38 adds.

**Blocked by:** 04, bootstrap 38

**MVP critical path:** no.

**Status:** done: `v0.3.1-rc.1` attested both, and both verify.

- [x] The publish job attests the chart digest with the same pinned action and the same permissions 38 added, and `test_workflows.py` pins that the chart step exists.
- [x] **Authorization required:** the next release and the network. `gh attestation verify` passes on the published chart's digest, and the hand-back records the output.
- [x] The [install guide](../../../docs/how-to/install.md) shows the verify command for the chart beside the image's, and `CHANGELOG.md` says which release first carried a chart attestation.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

Bootstrap 38 had not started, so, by the maintainer's decision, this branch carries 38's attestation slice too: both permissions, the image's attest step and the image's verify command. 38's SBOM and provenance flags, the index digest, its checker and arm64 stay in 38.

- `.github/workflows/release.yml`: `publish` gains `id-token: write` and `attestations: write`. The stub comment after "Build and push linux/amd64" is gone. "Push the chart" writes `CHART_DIGEST` to `$GITHUB_ENV`, and after it come two `actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2` steps: on `${{ env.IMAGE }}` and `${{ env.DIGEST }}`, then on `${{ env.CHART }}` and `${{ env.CHART_DIGEST }}`. Both set `push-to-registry: true` and `create-storage-record: false`. The image's step was planned right after the image push; the review moved it after the chart push, so a failed attestation (Sigstore or the OIDC exchange down) never leaves an image with no chart, which only a version bump recovers. The recovery comment gains the case of a failed attest step (the release is whole and unattested; bump the version), the header names the attestations, and the build comment says 38 turns on BuildKit's SBOM and provenance, not "attestations".
- `scripts/checks/tests/test_workflows.py`: the publish scopes are exactly the four, and a new rule, `attests_each_push`, holds that after the last push come exactly one attest step per push, in push order, on that push's name and digest with `push-to-registry: true` and `create-storage-record: false`, all at one pin. Its reader finds a step whether `uses:` opens it or follows `- name:`. Thirteen seeded refusals, two acceptances, two reader cases and the rule on the real file.
- `docs/how-to/install.md`: "Verify a release", before "Install with Helm": `gh attestation verify oci://ghcr.io/biscuitbin/knarr@<digest> --repo biscuitbin/knarr --signer-workflow biscuitbin/knarr/.github/workflows/release.yml`, the same for the chart's `oci://ghcr.io/biscuitbin/charts/knarr@<digest>`, and `helm show values` on the chart digest to check that its stamped digest is the verified image's. `--signer-workflow` narrows `--repo` from any workflow in the repository to `release.yml`; its format is from `gh attestation verify --help`.
- `CHANGELOG.md` `[Unreleased]` `Added`: the attestations, the first release to carry them, and the storage-record setting. The release pull request moves it under its version.
- Amendment notes on Decision 0012 (the attestation bullet) and Decision 0015 (Deferred), and `docs/DEFERRED.md` §8.
- Bootstrap 38: box 1 ticked as done here, and a note on box 2.

### What was verified

- The pin: `git ls-remote` gives `v4.2.2` = `4d101475d8b20a2381f78447822ac1eab6504dd8`, the commit `v4^{}` names. Its `action.yml` is a composite wrapper on `actions/attest` v4.2.1 with the inputs `subject-name`, `subject-digest`, `push-to-registry` and `create-storage-record`, the last defaulting to true.
- **Finding: storage records need a third permission.** `actions/attest`'s README at that commit says a storage record is created when `push-to-registry` is true, for organization-owned repositories only, and needs `artifact-metadata: write`. biscuitbin is an organization, and the non-goal forbids any permission beyond 38's two, so both steps turn storage records off. The attestation itself is still pushed to ghcr.io and still verifies with `gh attestation verify`.
- Red then green: before the workflow changed, the scopes test and `test_release_attests_the_image_and_then_the_chart` failed and the 78 other tests passed (run with the primary checkout's interpreter, before this worktree's `just initialize`); after it, they passed. After the review's reorder, `just test-checkers-selected policy release`: 171 passed. The existing push, guard and rerun rules hold unchanged: `push-to-registry` is not a push line, and the attest steps carry no `if:` or `continue-on-error`.
- actionlint on `release.yml` (`just lint`): no findings. `just docs-check` passes.
- The branch's `code-review` pass (medium) found nine issues. Fixed: the image attested before the chart push (moved after it), the guide's verify after the install (moved before it), `--repo` alone trusting any workflow in the repository (`--signer-workflow` added), no check that the chart's stamped digest is the verified image's (`helm show values` added), the reader missing a step under `- name:` (it reads both now), and 38's box 1 not naming the storage-record choice as open (noted there). Reworded: the job-level `id-token: write` comment, since any step of the job could mint a token; a separate attest job would narrow it, and needs the digests passed as outputs and `packages: write` again, so it is left for a later change. Not changed: a trailing comment or quoted value in an attest input fails the rule closed, which is the strict reading wanted; and the chart's attestation is unproven against ghcr.io, which is box 2.
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes.
- Not verified here, and box 2 is open for it: whether the action's registry push and `gh attestation verify oci://…` accept a Helm chart's OCI artifact, which no source checked here states either way, and the attestations on ghcr.io.

### What each later ticket needs

- **The next release (box 2), with authorization for the network:** after the run, record in `.scratch/helm-chart/evidence/07/` the output of both `gh attestation verify` commands on the summary's digests, and that both attest steps succeeded. If the chart's step or its verify fails because ghcr.io or `gh` does not take a Helm OCI artifact, that is a finding for Decision 0015; the image's attestation stands on its own. The release pull request moves the changelog entry under its version, which is then the first release with attestations; check that the install guide's "after `v0.3.0`" still holds.
- **Bootstrap 38:** box 1 is done. Turning on `--provenance=mode=min --sbom=true` changes `DIGEST` to the index digest, which both the image's attest step and the chart's stamp take with no further change. Its checker for `gh attestation verify` and its timing note remain. Any storage record needs `artifact-metadata: write`, a new decision.

### Box 2: the prerelease

Box 2 runs on `v0.3.1-rc.1`, a prerelease cut for it, so that if ghcr.io or `gh` refuses the chart's attestation, a prerelease takes the version bump and no stable release does. A prerelease pushes the image tags `0.3.1-rc.1` and `sha-<7>` only, and moves no `0.3`. Its release pull request bumps `gleam.toml` and the chart, dates the changelog heading, and adds [verify.sh](../evidence/07/verify.sh). After the run, `verify.sh <image digest> <chart digest>` verifies each digest from GitHub's attestations API and, with `--bundle-from-oci`, from ghcr.io, and checks the chart's stamped `image.digest`, into `verify.txt` beside it.

The run, on 2026-10-27 with the maintainer's authorization for the tag, the `release` environment and the network ([the evidence](../evidence/07/README.md)): release run 40437088789 pushed the image `sha256:747f9fc7…b8b004c` and the chart `sha256:4870df80…349a6b2`, and both attest steps uploaded to GitHub, Rekor and ghcr.io. `verify.sh` passed: each digest verifies from GitHub and from ghcr.io with `--bundle-from-oci`, signed by `release.yml`, and the chart's stamped `image.digest` is the image's. ghcr.io and `gh` take an attestation on a Helm chart's OCI artifact, so Decision 0015 needs no change.

**Finding: the guide's verify failed as written.** `--signer-workflow` matches the certificate's workflow URI with case, and the certificate spells the owner `BiscuitBin`, so the lowercase `biscuitbin/knarr/.github/workflows/release.yml` this ticket put in the guide (see "What changed") failed with only `Error: verifying with issuer "sigstore.dev"`; `--repo` alone passed. The evidence pull request spells the owner `BiscuitBin` in the guide and `verify.sh`, and adds an `[Unreleased]` `Fixed` entry; 0.3.1-rc.1's own changelog entry, already tagged, keeps the lowercase command. [signer-case.txt](../evidence/07/signer-case.txt) has both spellings and the certificate's URI. The run also showed that `helm show values` first prints the chart's own `Digest:`, beside the stamped `digest:` the guide checks, so the guide now says which is which. The publish job ran 79 s against 0.3.0's 58 s; the attest steps took 11 s and 8 s.
