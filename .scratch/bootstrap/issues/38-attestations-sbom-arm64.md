# 38: Attestations, SBOM, provenance and the arm64 image

**Context:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) adopts GitHub artifact attestations for later, turns BuildKit's SBOM and provenance off for the first release because they change the pushed object from one manifest to an index, defers cosign, and prices arm64: `linux-aarch64` in the lock, one more build job on an `ubuntu-24.04-arm` runner, and an `imagetools create` to merge. Each of these changes the digest an install pins, so they come after 37 has proved the plain pull path.

**What to build:** On the live workflow from 36, after 37's first release: `actions/attest-build-provenance` on the publish job with `push-to-registry`, `--provenance=mode=min --sbom=true` on the build, `gh attestation verify oci://…` in the install guide and in a checker, and the overlay pinning the index digest. Then, with 27, the arm64 lane: `linux-aarch64` in `pixi.toml` and a re-lock, an arm64 build job, and the merged index, if a target node pool needs it.

**Non-goals:** cosign keyless signing, unless a consumer asks for a Sigstore signature. The native arm64 runtime verification on real hardware beyond what CI's arm runner shows (13 left it unverified).

**Blocked by:** 36, 37

**From 28:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md), "cosign, SBOM and build provenance" and "Architectures"; [registry.txt](../evidence/28/registry.txt) part 2 for what an attested push looks like; [arm64-probe.txt](../evidence/28/arm64-probe.txt) for the arm64 cost.

**From 27:** the arm64 re-lock is an ordinary pull request through [Decision 0014's re-lock route](../../../docs/decisions/0014-dependency-updates-and-audit.md#re-locks-ticket-38s-arm64-among-them), and both base-image digests are already indexes with an arm64 manifest ([digests.txt](../evidence/27/digests.txt)).

**MVP critical path:** no. The MVP pulls a plain amd64 manifest.

**Status:** ready-for-agent, round 2

- [x] The publish job gains `id-token: write` and `attestations: write` and nothing else; `actions/attest-build-provenance` is pinned by SHA and attests the pushed digest with `push-to-registry: true`. Done by [helm-chart 07](../../helm-chart/issues/07-attest-published-chart.md), with `create-storage-record: false`, since a storage record needs `artifact-metadata: write` too. Open here: whether the org wants storage records, which would take that third permission and a decision.
- [x] `gh attestation verify oci://ghcr.io/biscuitbin/knarr@<digest> --repo biscuitbin/knarr` passes on the next release, and the install guide shows the command. Done by [helm-chart 07](../../helm-chart/issues/07-attest-published-chart.md) on `v0.3.1-rc.1` ([evidence](../../helm-chart/evidence/07/README.md)): it passes from GitHub and from ghcr.io. The guide's `--signer-workflow` must spell the owner `BiscuitBin`, as the certificate does; the lowercase owner fails. The checker this ticket names remains.
- [ ] With `--provenance=mode=min --sbom=true`, the overlay, or after helm-chart 06 the chart's stamped `image.digest`, pins the index digest, `imagetools inspect` shows the attestation manifest, and the install guide says which digest to pin.
- [ ] arm64, only if a target node pool needs it: `linux-aarch64` added and the lock re-solved with 27's process, an `ubuntu-24.04-arm` build job, `imagetools create` merging the two manifests under the release tags, and the kind-on-arm64 runtime smoke 13 could not run. The re-lock and the kind-on-arm64 smoke are done by [50](50-local-arm64-image.md), which moved kubectl to 1.36.0 because 1.34.3 has no linux-aarch64 build; the runner job and the merged index remain here.
- [x] For attestations, the extra time is recorded and `CHANGELOG.md` says which release first carried them. The prerelease 0.3.1-rc.1 first carried them: its attest steps took 11 s (image) and 8 s (chart), and its publish job 79 s against 0.3.0's 58 s ([evidence](../../helm-chart/evidence/07/README.md)). 0.3.1 is the first stable release to carry them, as `CHANGELOG.md`'s intro says. Its attest steps took 20 s and 7 s, and its publish job 72 s ([ticket 54](54-release-v0-3-1.md), [run.txt](../evidence/54/run.txt)). Split by ticket 54 on 2026-10-30.
- [ ] For SBOM, provenance and arm64, the hand-back records the extra time each change adds to the release run, and `CHANGELOG.md` says which release first carried each.
