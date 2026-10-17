# 01: Decision 0015: knarr ships a Helm chart

**Context:** Today knarr installs from a clone at a tag: `just cluster-install`, `just release-pin <digest>`, then `kubectl apply -k deploy/release` ([install guide](../../../docs/how-to/install.md)). That is a heavy path for a new user. [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) packages knarr with kustomize only. Under "Helm is deferred" it says to reopen the question when "a second consumer wants values", and [DEFERRED.md §8](../../../docs/DEFERRED.md#8-other-future-targets) and OVERVIEW §9.15 say the same. The maintainer now wants a chart **for ease of adoption**. That is a different goal, not the arrival of a second consumer. 0012's reasoning was sound for the goal it had. The new record says that the goal changed, and it does not invent a consumer.

The maintainer settled these points on 2026-10-16: the chart is published to OCI on ghcr.io; Helm becomes the only supported install, and kubectl-only users run `helm template` themselves; the `deploy/` kustomize tree and `release-pin` retire at the end; and the values surface is the agent's call within the constraints below.

**What to build:** A new decision record, `docs/decisions/0015-helm-chart.md`, registered in the docs manifest and the decisions index. It amends 0012's §9.15 bullet and its "Helm is deferred" bullet, DEFERRED §8's Helm entry, and OVERVIEW §9.15 with its status-table row, each with a pointer to 0015. It decides:

- **Location.** The chart lives in this repository, as cert-manager's and Kyverno's do. A separate charts repository is how KEDA's chart and YAML drift apart.
- **Reference.** `oci://ghcr.io/steven-cutting/charts/knarr`. `helm push` publishes `ghcr.io/steven-cutting/charts/knarr:<version>`, and a chart also installs by digest.
- **Versioning.** Chart `version` = `appVersion` = the `gleam.toml` version = the tag without `v`, in lockstep. A gate check enforces it.
- **Digest stamping.** The release workflow packages the chart after the image push, with `image.digest` set to the pushed digest. `helm install … --version X.Y.Z` therefore installs exactly the released image, and `release-pin` and its tracked-file edit go. When 38 switches to an index digest, that switch lands in the same step.
- **Partial publication.** The image and the chart are two pushes, so a run can stop with the image present and the chart absent. 0012 publishes a release once, and the record keeps that rule: such a run is recovered by bumping the version, never by a chart-only push of an existing version. 04 carries it into `release.yml`'s recovery comment and its tests.
- **Values surface v1.** The values are:
  - `image`: `repository`, `tag`, `digest`, `pullPolicy` and `pullSecrets`.
  - the install-wide `-knarr` settings that `config.allium` `Installed` names (`status_port`, `status_path`, `max_body_bytes`, `thresholds`, `threshold_margin`, `unknown_polls`, `absent_after`, `poll_interval`, `poll_timeout`, `patch_interval`, `list_interval`, `poll_concurrency`, `poll_jitter_percent`, `patch_rate_per_second`, `patch_burst`, `backoff_initial`, `backoff_cap` and `log_level`, as read in `application_ffi.erl`). `discovery`, `port` and `bind` are left out because the chart owns them: the probes and discovery depend on them.
  - `resources`, `nodeSelector`, `tolerations`, `affinity`, `priorityClassName`, `podAnnotations` and `podLabels`.

  The chart has no `replicaCount`: one replica, `Recreate` and no Lease are pinned by `test_deployment.py` and DEFERRED §4. It has no ClusterRole toggle, because the install is one namespace (§9.18) and the Role and RoleBinding go in `.Release.Namespace`. It has no PDB, ServiceMonitor or Service, because knarr has no Service.
- **Schema.** `values.schema.json` with `additionalProperties: false` throughout. The record also decides the range policy, one of two:
  - The schema carries ranges, and a checker test pins each range to `config.allium` and `config.gleam`. [Decision 0001](../../../docs/decisions/0001-specs-decide-behaviour.md) says the specifications decide.
  - The schema checks types only, and knarr's own startup refusal stays the one range check.
- **The gate.** Whether `kubernetes-helm` joins the `default` environment, so that the required `check` job lints and renders the chart. Today the gate has neither helm nor a standalone kustomize: `deployment.py --render` runs in the cluster environment, outside `check`.
- **Helm 3 and 4.** The chart uses `apiVersion: v2` and no Helm-4-only feature, and it is rendered with the pinned 4.3.x. Helm 3 gets security fixes until 2027-02-10, and Helm says charts that deploy with Helm 3 should deploy with Helm 4.
- **Migration.** An existing kustomize install moves to Helm by adoption: the four resources get the `app.kubernetes.io/managed-by: Helm` label and the `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` annotations, then `helm upgrade --install` takes them over. The chart therefore keeps the base's resource names and its immutable Deployment selector, `app.kubernetes.io/name: knarr`, exactly. 05 proves and documents the procedure.
- **Uninstall.** The `lifecycle.allium` `Uninstall` `Procedure` order stands: opt out, wait for cleanup, inspect and recover markers, and only then delete the install. `helm uninstall` replaces `kubectl delete -k` as that last step, and 05 changes the clause and the operations page together.
- **End state.** Helm is the only supported install. The kustomize tree, `release-pin` and the overlay checks retire in 06. kubectl-only users pipe `helm template` into `kubectl apply`.
- **Deferred.** Signing and attesting the chart wait for 38's image attestation and are ticket 07. An Artifact Hub listing is ticket 08.

**Non-goals:** Writing the chart (02). Changing a workflow (03, 04). Any change under `src/` or `deploy/`.

**Blocked by:** None (can start immediately).

**From the planning session (2026-10-16):** the sources below were read during planning. This ticket fetches them again and records them.

- [cert-manager's Helm install](https://cert-manager.io/docs/installation/helm/): the chart is pushed to OCI at `quay.io/jetstack/charts` ("OCI charts are the source of truth"), version and appVersion move in lockstep, and the chart has an `image.digest` value. Its [manifests.mk](https://github.com/cert-manager/cert-manager/blob/master/make/manifests.mk) builds the static YAML with `helm template`.
- [Kyverno's helm-release workflow](https://github.com/kyverno/kyverno/blob/main/.github/workflows/helm-release.yaml): `helm push` to `ghcr.io/kyverno/charts/<name>`, cosign signing, and a `check-codegen` job that fails on drift.
- [KEDA's separate charts repository](https://github.com/kedacore/charts): the chart and the kustomize YAML are maintained by hand in two places.
- [prometheus-community's release workflow](https://github.com/prometheus-community/helm-charts/blob/main/.github/workflows/release.yaml): Helm v4.3.1 and `helm push oci://ghcr.io/<owner>/charts`.
- [Helm 4 released](https://helm.sh/blog/helm-4-released) and [Helm v3 end of life](https://helm.sh/blog/helm-v3-end-of-life): 4.0.0 shipped on 2025-11-12, with server-side apply on new installs and post-renderers as plugins. v4.3.1 and v3.22.1 were released on 2026-10-15.
- [Helm OCI registries](https://helm.sh/docs/topics/registries/): the push reference, install by digest, and `.prov` upload.
- [Helm label best practices](https://helm.sh/docs/chart_best_practices/labels/): the `app.kubernetes.io/*` and `helm.sh/chart` labels.
- [GitHub container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry): new packages are private by default. Yet [37's hand-back](../../bootstrap/issues/37-first-release-v0-1-0.md) found the image public from its first push, so 05 verifies the chart's visibility rather than assuming it.
- [Artifact Hub Helm repositories](https://artifacthub.io/docs/topics/repositories/helm-charts/): OCI repositories plus an `artifacthub.io` metadata layer.
- The tooling the chart will use: chart-testing v3.15.0 (`ct lint`, `ct install`), helm-unittest v1.2.1, kubeconform on `helm template`, and `values.schema.json` as cert-manager, KEDA and external-dns ship it.

**MVP critical path:** no. The MVP installs through 0012's kustomize route.

**Status:** done. Pull request [#50](https://github.com/steven-cutting/knarr/pull/50) is open. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** the network, for the fetch. `.scratch/helm-chart/evidence/01/sources.txt` records every source above with its HTTP status, size and sha256, and the phrase each claim rests on, found or not found. It has the shape of ticket 28's [sources.txt](../../bootstrap/evidence/28/sources.txt), with a `sources.sh` beside it.
- [x] Optional. **Authorization required:** the network, for the `registry:2` image pull. A loopback `registry:2` dry run in `.scratch/helm-chart/evidence/01/` packages a scratch chart with a stamped digest, pushes it, pulls it by digest and templates it, and shows that the rendered image is the stamped reference.
  Done by ticket 04's loopback dry run rather than here, as Decision 0015's Findings hand it on, because the real stamping script exists there: [registry.txt](../evidence/04/registry.txt), run on 2026-10-17 (UTC).
- [x] Decision 0015 records each decision above with its evidence, and says plainly that 0012's reasoning was sound for its goal and that the goal has changed.
- [x] 0012, DEFERRED §8, OVERVIEW §9.15 and its status-table row point to 0015. Nothing they say contradicts it.
- [x] The record names the tickets that carry it out: 02 to 08 in this directory, and bootstrap ticket 38 for the index digest.
- [x] `CHANGELOG.md` records the decision under Unreleased.
- [x] `just docs-check` passes, and `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Settled on 2026-10-17 (UTC). The maintainer's choices (OCI on ghcr.io, Helm as the only install, kustomize and `release-pin` retiring, types-only schema, helm and kustomize in the default environment) were made in the planning session on 2026-10-16; this ticket records them.

### What changed

- New [Decision 0015](../../../docs/decisions/0015-helm-chart.md), registered in `docs/manifest.yml`, the [decisions index](../../../docs/decisions/README.md) and the [docs index](../../../docs/README.md). It records every decision above, says 0012 was sound for its goal and that the goal changed, and names 02 to 08 and bootstrap 38.
- Amended to point at 0015: [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) (§9.15, "Helm is deferred", and "What would reopen this"), [DEFERRED §8](../../../docs/DEFERRED.md#8-other-future-targets) (Helm no longer deferred; helm moves to the default environment), and [OVERVIEW](../../../docs/OVERVIEW.md) §9.15 and its status-table row. All of them name one milestone: Helm becomes the only supported install when ticket 06 retires the kustomize route.
- `CHANGELOG.md` records the decision under Unreleased, Changed.
- Evidence: [sources.sh](../evidence/01/sources.sh) and [sources.txt](../evidence/01/sources.txt), in ticket 28's shape.
- Review fixes, applied after the first green gate: the schema rule closes only the objects knarr defines, and leaves the user's maps and the Kubernetes objects open. The release stamps `image.repository`, `image.pullPolicy: IfNotPresent` and `image.digest` together. Ticket 07 attests the chart the way 38 attests the image. The 0012 quote is attributed to the right bullet. 02's and 04's boxes were tightened to match.

### What was verified, and what was not

- `sources.sh` fetched 25 pages, each HTTP 200; 41 phrases found, 0 not found ([sources.txt](../evidence/01/sources.txt)).
- `just docs-check` passes, and `just check` ends with "All checks passed and the worktree is unchanged."
- Not done: the optional `registry:2` dry run (ticket 04 carries it). Nothing pushed a chart, logged in to a registry or changed a repository setting.

### Review

Codex was unavailable (the requested model was not supported on this login), so a five-lens Claude subagent review ran instead, with two to three adversarial verifiers per finding. Six findings were confirmed and fixed (the review fixes above); six were rejected, among them the kubectl-only delete route, chart checks before the image push (raised for 04 below) and Helm 4 server-side apply over kustomize-applied resources (05's migration run would surface it).

### What each later ticket needs

- **02:** the chart goes at `charts/knarr/`, with `apiVersion: v2`, and `version` = `appVersion` = the `gleam.toml` version, enforced by a gate check. Tracked `values.yaml` holds the local values of `deploy/base` (`knarr`, `local`, `Never`). The schema checks types only. `additionalProperties: false` applies to the top level, `image` and the `-knarr` settings object. `podAnnotations`, `podLabels` and `nodeSelector` are string maps. `resources`, `affinity`, `tolerations` and `pullSecrets` stay open. Test both an unknown key being refused and an arbitrary annotation key rendering. `kubernetes-helm` (4.3.0) and `kustomize` move to the default environment. Chart tests are pytest over `helm template`, with no helm-unittest or chart-testing. Keep the resource names and the selector `app.kubernetes.io/name: knarr` exactly.
- **03:** the kind loop and CI install the chart; `--set-string podAnnotations.knarr\.dev/local-image-id=<id>` relies on 02's open annotation map.
- **04:** stamp `image.repository: ghcr.io/steven-cutting/knarr`, `image.pullPolicy: IfNotPresent` and `image.digest` together, and assert the rendered `image:` line and `imagePullPolicy`. Give the chart push its own existence guard. Recover a run that left the image present and the chart absent by bumping the version, never by a chart-only push. Run the loopback `registry:2` dry run this ticket left optional. Hardening worth considering: run the chart checks that need no digest before the image push.
- **05:** prove adoption (the managed-by label and the two release annotations), verify the package's visibility, and change the `Uninstall` clause and the operations page. The kustomize route stays documented, as deprecated, until 06.
- **06:** retire `deploy/`, `release-pin` and the overlay checks; Helm is then the only supported install.
- **07:** attest the chart's digest with GitHub artifact attestations, as 38 does for the image. cosign and `.prov` stay deferred.
- **08:** the Artifact Hub listing.
- **Bootstrap 38:** when the release switches to an index digest, the chart stamps that digest in the same step.
