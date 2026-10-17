# 04: The release publishes the chart to ghcr

**Context:** `release.yml`'s publish job builds and pushes the image behind the `release` environment, after an existence guard that probes the tag with `scripts/release/lib.sh` and refuses on `present` or `unknown`. `test_workflows.py` pins the job's shape:

- `probes_before_it_pushes` requires exactly one `probe_tag https://ghcr.io "$repo" "$VERSION"` line, one `case $verdict in` and one line containing `--push`, in that order. A second probe and `case` pair breaks the count at once. A `helm push` line contains no `--push`, so the rule as written would not see the chart push at all, and a chart probe that names a variable other than `"$repo"` would be invisible too.
- The publish job's permissions must be exactly `{contents: read, packages: write}`. `helm push` to ghcr.io needs nothing more.

[Decision 0015](01-helm-chart-decision.md) stamps the pushed image digest into the chart at publish, which removes `release-pin`.

**What to build:**

- A prefactor first. The workflow-guard tests generalise to "each push has its own probe and its own fail-closed `case`, in order". The image's single guarded push still passes, and their seeded failures cover a second push with no probe or no guard.
- Then the publish job, after the image push, packages the chart with `version` = `appVersion` = the tag and `image.digest` = the pushed digest. It probes `charts/knarr:<version>` with lib.sh's absent, present and unknown semantics, runs `helm push` to `oci://ghcr.io/steven-cutting/charts`, and prints the chart's digest and install command in the run summary.

**Non-goals:** Installing the published chart (05). Attesting it (07). Changing the publish job's scopes. Retiring `release-pin` (06): it stays until the chart is the only install.

**Blocked by:** 02

**From 28:** the loopback dry run in [registry.txt](../../bootstrap/evidence/28/registry.txt) and the guard semantics in [lib.sh](../../../scripts/release/lib.sh) and its [test](../../bootstrap/evidence/28/lib_test.txt).

**From 38:** when bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md) switches the image to an index, the stamped digest becomes the index digest in this same step. Whichever of the two lands second makes that change.

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] Prefactor: `test_workflows.py` defines a push as a `--push` line or a `helm push` line, checks every push for its own probe and `case $verdict in`, in order, and still passes on the unchanged `release.yml`. Seeded failures cover a chart push with no probe, a chart push before its guard, and a guard that probes the image's tag in place of the chart's.
- [ ] `release.yml` packages the chart after the image push with the pushed digest and the tag's version, and fails if the packaged `Chart.yaml` disagrees with the tag.
- [ ] The chart push is guarded the way the image push is: `present` and `unknown` refuse, and only `absent` pushes.
- [ ] The publish job's permissions are still exactly `{contents: read, packages: write}`, and every new action is pinned by SHA.
- [ ] A loopback `registry:2` dry run, recorded in `.scratch/helm-chart/evidence/04/`, packages, pushes, probes again (now `present`), pulls by digest and templates the chart. The rendered image is the stamped digest reference. **Authorization required:** the network, for the `registry:2` image pull.
- [ ] `actionlint` passes, and the run summary shows the chart reference by digest beside the image's.
- [ ] `CHANGELOG.md` records that releases publish the chart. Decision 0015 points to this ticket for the publish step.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
