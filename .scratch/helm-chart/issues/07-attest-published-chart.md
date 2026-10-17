# 07: Attest the published chart

**Context:** Bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md) adds `actions/attest-build-provenance` to the publish job for the image, with `push-to-registry`, and documents `gh attestation verify`. [Decision 0015](01-helm-chart-decision.md) defers signing and attestation of the chart until that lands, so that the image and the chart are attested the same way, by one mechanism.

**What to build:** On the publish job from [04](04-release-publishes-chart.md), an `attest-build-provenance` step on the chart's digest that matches 38's image step. The install guide gains `gh attestation verify oci://ghcr.io/steven-cutting/charts/knarr@<digest> --repo steven-cutting/knarr`.

**Non-goals:** cosign keyless signing or a Helm `.prov` file, unless a consumer asks. Any permission beyond those 38 adds.

**Blocked by:** 04, bootstrap 38

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] The publish job attests the chart digest with the same pinned action and the same permissions 38 added, and `test_workflows.py` pins that the chart step exists.
- [ ] **Authorization required:** the next release and the network. `gh attestation verify` passes on the published chart's digest, and the hand-back records the output.
- [ ] The [install guide](../../../docs/how-to/install.md) shows the verify command for the chart beside the image's, and `CHANGELOG.md` says which release first carried a chart attestation.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
