# 04: The release publishes the chart to ghcr

**Context:** `release.yml`'s publish job builds and pushes the image behind the `release` environment, after an existence guard that probes the tag with `scripts/release/lib.sh` and refuses on `present` or `unknown`. `test_workflows.py` pins the job's shape:

- `probes_before_it_pushes` requires exactly one `probe_tag https://ghcr.io "$repo" "$VERSION"` line, one `case $verdict in` and one line containing `--push`, in that order. A second probe and `case` pair breaks the count at once. A `helm push` line contains no `--push`, so the rule as written would not see the chart push at all, and a chart probe that names a variable other than `"$repo"` would be invisible too.
- The publish job's permissions are pinned exactly. Today they are `{contents: read, packages: write}`, and bootstrap 38 adds `id-token: write` and `attestations: write`. `helm push` to ghcr.io needs nothing beyond `packages: write`.

The recovery comment above the existence guard assumes one push: a run that failed after it is published, and only its digest is missing. With two pushes, a run can stop with the image present and the chart absent, and a rerun then refuses at the image's guard. [Decision 0015](01-helm-chart-decision.md) recovers that by bumping the version.

[Decision 0015](01-helm-chart-decision.md) stamps the pushed image digest into the chart at publish, which removes `release-pin`.

**What to build:**

- A prefactor first. The workflow-guard tests generalise to "each push has its own probe and its own fail-closed `case`, in order". The image's single guarded push still passes, and their seeded failures cover a second push with no probe or no guard.
- Then the publish job, after the image push, packages the chart with `version` = `appVersion` = the tag, and `image.digest` and the `artifacthub.io/images` annotation both set from the pushed digest. It probes `charts/knarr:<version>` with lib.sh's absent, present and unknown semantics, runs `helm push` to `oci://ghcr.io/steven-cutting/charts`, and prints the chart's digest and install command in the run summary.

**Non-goals:** Installing the published chart (05). Attesting it (07). Changing the publish job's scopes. Retiring `release-pin` (06): it stays until the chart is the only install.

**Blocked by:** 02

**From 28:** the loopback dry run in [registry.txt](../../bootstrap/evidence/28/registry.txt) and the guard semantics in [lib.sh](../../../scripts/release/lib.sh) and its [test](../../bootstrap/evidence/28/lib_test.txt).

**From 38:** when bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md) switches the image to an index, the stamped digest becomes the index digest in this same step. Whichever of the two lands second makes that change. If 38 is still open when 04 lands, 04 restates 38's "the overlay pins the index digest" criterion as "the overlay, or after helm-chart 06 the chart's stamped `image.digest`, pins the index digest". That one sentence is the only edit to 38.

**MVP critical path:** no.

**Status:** ready-for-agent

- [x] Prefactor: `test_workflows.py` defines a push as a `--push` line or a `helm push` line, checks every push for its own probe and `case $verdict in`, in order, and still passes on the unchanged `release.yml`. Seeded failures cover a chart push with no probe, a chart push before its guard, and a guard that probes the image's tag in place of the chart's.
- [x] `release.yml` packages the chart after the image push with the pushed digest and the tag's version, and fails if the packaged `Chart.yaml` disagrees with the tag.
- [x] The chart push is guarded the way the image push is: `present` and `unknown` refuse, and only `absent` pushes.
- [x] The stamping step is a script with a test beside it. Given a fixture digest, the packaged chart's `image.digest` and its `artifacthub.io/images` annotation both name that digest, its render has `image: ghcr.io/steven-cutting/knarr@<digest>` and `imagePullPolicy: IfNotPresent` (0015 stamps the repository, pull policy and digest together), and a seeded mismatch fails.
- [x] The recovery comment covers the image-present, chart-absent case: bump the version, as 0015 decides. A seeded test shows a rerun of such a run refusing at the image's guard without pushing the chart.
- [x] The chart push adds no permission: the job's permissions are exactly those on `main` when 04 lands (the two above, plus 38's two if 38 merged first). Every new action is pinned by SHA.
- [x] A loopback `registry:2` dry run, recorded in `.scratch/helm-chart/evidence/04/`, packages, pushes, probes again (now `present`), pulls by digest and templates the chart. The rendered image is the stamped digest reference. **Authorization required:** the network, for the `registry:2` image pull.
- [x] `actionlint` passes, and the run summary shows the chart reference by digest beside the image's.
- [x] `CHANGELOG.md` records that releases publish the chart. Decision 0015 points to this ticket for the publish step.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Settled on 2026-10-17 (UTC).

### What changed

- `scripts/checks/tests/test_workflows.py`: the prefactor. `push_target` treats a `--push` line as a push of `"$repo"` and a `helm push` line as a push of `"$chart_repo"`, and `probes_before_it_pushes` requires the job's probe, `case $verdict in` and push lines to be exactly that triple repeated, each probe naming its own push's repository. `test_release_pushes_only_when_the_tag_is_absent` checks the arms of every guard, and the moved-tag check must precede the first push of either kind. Seeded failures: a chart push with no probe, before its guard, or with no verdict; a chart guard that probes the image and an image guard that probes the chart; a chart push before the image push; no push at all. The rule passed on the unchanged `release.yml` before the workflow was edited.
- New `scripts/release/stamp-chart.sh` `<chart-dir> <version> <image> <digest> <out-dir>`, with `scripts/release/stamp-chart_test.sh` beside it (22 checks), run from `test_release_lib.py` in the `release` group. The script refuses a `Chart.yaml` whose `version` or `appVersion` differs from the tag rather than overriding it, stamps `image.repository`, `image.tag`, `image.digest` and `image.pullPolicy: IfNotPresent` into a temporary copy, adds the `artifacthub.io/images` annotation, packages it, and reads the package back to require `image: <image>@<digest>` and `imagePullPolicy: IfNotPresent` before it writes anything to `<out-dir>`. The tracked chart is never touched.
- `.github/workflows/release.yml`: the publish job installs helm through the local setup action and checks that the chart packages for this version before the image push, so a chart failure leaves nothing published. After the image push it stamps and packages the chart with the pushed digest, probes `charts/knarr:<version>` with `lib.sh`'s absent, present and unknown arms, runs `helm push` to `oci://ghcr.io/steven-cutting/charts`, and writes the chart reference by digest, the stamped image and the install command to the run summary. The recovery comment covers the image-present, chart-absent run: bump the version. Permissions are unchanged and no remote action was added.
- `scripts/checks/checker_suite.py`: the `release` group gains `charts/**`, because the stamp test packages the tracked chart (test first in `test_checker_suite.py`).
- `.scratch/helm-chart/evidence/04/registry.sh` and `registry.txt`: the loopback dry run.
- `CHANGELOG.md` records that releases publish the chart and drops 02's "not published yet". Decision 0015 records the `image.tag` stamp and points to this ticket's step and dry run. Bootstrap 38's criterion now reads "the overlay, or after helm-chart 06 the chart's stamped `image.digest`, pins the index digest", its only edit. Ticket 01's optional `registry:2` box is ticked, pointing at this ticket's `registry.txt`.

### What was verified

- Each new test was red before its code: the workflow rules on the seeded jobs, the stamp test with no script, and the suite-selection rows.
- `just test-checkers-selected release policy chart`: 208 passed.
- `actionlint` passes on `release.yml`, directly and through `just lint`.
- The loopback `registry:2` dry run ([registry.txt](../evidence/04/registry.txt), 2026-10-17T07:27Z, network authorized for the image pull) refused a `v9.9.9` tag against the 0.1.0 chart, probed the chart absent (404), pushed it, probed it present (200) at the digest `helm push` printed, equal to `Docker-Content-Digest`, pulled it by that digest, and rendered `image: ghcr.io/steven-cutting/knarr@sha256:f7612c…` with `IfNotPresent`.
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes.
- Not done: nothing ran against ghcr.io. The token exchange for the new `charts/knarr` package on its first push is assumed to behave like the image's (bootstrap 28: 404 means absent); the first real release proves it.

### Review

Codex was unavailable (the requested model was not supported on this login), so a five-lens Claude subagent review ran instead, with two to three adversarial verifiers per finding. No finding was confirmed; all eight were rejected.

### What each later ticket needs

- **05:** the first release after 04 merges pushes `charts/knarr` for the first time. Check the package's visibility (ghcr packages default to private) and that the ghcr token exchange answered the first probe with 404. The run summary carries the install command and `oci://ghcr.io/steven-cutting/charts/knarr@<digest>`.
- **06:** the chart already carries the stamped digest, so retiring `release-pin` needs no release change. Bootstrap 38's criterion now names the chart's stamped `image.digest` after 06. `stamp-chart.sh` expects exactly one `repository:`, `tag:`, `digest:` and `pullPolicy:` line in `values.yaml`; keep that shape or change the script with its test.
- **07:** the "Push the chart" step prints `chart_digest=<digest>`; attest that digest the same way 38 attests the image. Attestation adds `id-token: write` and `attestations: write` to the job, which 38 brings and `test_release_jobs_get_only_the_scopes_they_need` pins.
- **08:** the packaged chart carries only the `artifacthub.io/images` annotation. The Artifact Hub metadata layer and any further annotations belong in `stamp-chart.sh` and its test.
- **Bootstrap 38:** when the image becomes an index, `DIGEST` becomes the index digest and the stamp step needs no change; release.yml's ticket 38 comment says so.
