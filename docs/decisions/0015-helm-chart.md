---
title: "Decision 0015: knarr ships a Helm chart"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_helm_chart]
requires: []
---

# Decision 0015: knarr ships a Helm chart

## Context

knarr installs today from a clone at a release tag: `just cluster-install`, `just release-pin <digest>`, then `kubectl apply -k deploy/release` ([install guide](../how-to/install.md)). That is a heavy path for a new user. [Decision 0012](0012-release-and-packaging.md) packages knarr with kustomize only. Under "Helm is deferred" it keeps helm unused "until a second consumer asks for values", its "What would reopen this" lists "a second consumer wants values", and [DEFERRED.md §8](../DEFERRED.md#8-other-future-targets) said the same.

0012's reasoning was sound for the goal it had: one consumer, one namespace, two differences from the base and nothing to template, so a chart would have been a second packaging to keep in step for nothing that consumer needed. **The goal has changed.** The maintainer now wants a chart **for ease of adoption**: a new user should install knarr with one `helm install` and no clone. This is not the arrival of the second consumer 0012 named, and this record does not invent one. It records a different goal, which 0012's reopening conditions did not cover.

The maintainer settled four points in the planning session on 2026-10-16:

- the chart is published to OCI on ghcr.io;
- Helm becomes the only supported install, and a kubectl-only user runs `helm template` themselves;
- the `deploy/` kustomize tree and `release-pin` retire at the end;
- the values surface is the agent's call, within the constraints below. In the same session the maintainer chose the schema's range policy (types only) and put helm and kustomize in the gate's environment.

The sources were read during planning and fetched again for this record on 2026-10-17 (UTC). [sources.txt](../../.scratch/helm-chart/evidence/01/sources.txt) records each page's HTTP status, size and sha256, and each phrase a claim below rests on: 41 of 41 were found. Nothing here pushed a chart, logged in to a registry or changed a repository setting.

## Decision

### Location and reference

- **The chart lives in this repository,** at `charts/knarr/`, as cert-manager's and Kyverno's do. cert-manager builds its static YAML from its own chart with `$(HELM) template` in the same repository, and Kyverno pushes its charts from its main repository. KEDA keeps its chart in a separate repository, and each chart release updates "the CRDs & Kubernetes resources based on the release artifact (YAML)" by hand, while the main repository builds that YAML with kustomize: two packagings in two places, which is how they drift. One repository, one gate.
- **The reference is `oci://ghcr.io/steven-cutting/charts/knarr`.** `helm push` of the packaged chart to `oci://ghcr.io/steven-cutting/charts` publishes `ghcr.io/steven-cutting/charts/knarr:<version>`; Helm requires the `oci://` prefix and takes the chart name from the package. A chart also installs by digest (`…/knarr@sha256:…`), which Helm's documentation calls "more secure than a tag because digests are immutable". cert-manager names its OCI charts "the source of truth"; Kyverno and prometheus-community push to `ghcr.io/<owner>/charts` the same way.

### Versioning and digest stamping

- **Lockstep.** The chart's `version` and `appVersion` both equal the `gleam.toml` version, which is the release tag without `v`, as cert-manager packages with `--app-version=$(VERSION) --version=$(VERSION)`. A gate check enforces it, so a release pull request that bumps `gleam.toml` and not the chart fails `just check` (ticket 02).
- **The release stamps the image.** The chart's tracked `values.yaml` keeps the local values that match `deploy/base` (`image.repository: knarr`, `tag: local`, `pullPolicy: Never`), so the drift check (ticket 02) and the local loop (ticket 03) render the base. The release workflow packages the chart after the image push and stamps three values together in the packaged chart: `image.repository: ghcr.io/steven-cutting/knarr`, `image.pullPolicy: IfNotPresent` and `image.digest` set to the digest that push printed. These are the overlay's image name, digest pin and pull-policy patch (0012), which go with the overlay. Ticket 04 also stamps `image.tag` to the version, so a user who clears `image.digest` installs the released tag rather than the local build's `local`. The stamped chart renders `image: ghcr.io/steven-cutting/knarr@sha256:<digest>` with `imagePullPolicy: IfNotPresent`, so `helm install … --version X.Y.Z` installs exactly the released image, by digest, with no tracked-file edit after the run. Ticket 04's stamping test asserts that rendered `image:` line and `imagePullPolicy`, not only `image.digest`. `just release-pin` and the overlay's digest pin, which exist only because the overlay at a release's own tag cannot hold that release's digest (0012, amended by ticket 37), go with the overlay (ticket 06). When bootstrap ticket 38 switches the release to an index digest, the digest it stamps switches in the same step.
- **Partial publication is recovered by a version bump.** The image and the chart are two pushes, so a run can stop with the image present and the chart absent. 0012 publishes a release once, and this record keeps that rule: such a run is recovered by bumping the version and releasing again, never by a chart-only push of an existing version. A rerun of the same tag already stops at the image's existence guard, before any chart push. Ticket 04 carries this into `release.yml`'s recovery comment and its tests, and gives the chart push its own existence guard, which runs before the image push as well as before `helm push`, so a chart version that exists or cannot be probed stops the run with nothing published.

### Values surface v1

The values are:

- **`image`:** `repository`, `tag`, `digest`, `pullPolicy` and `pullSecrets`. A set `digest` wins over `tag`; an unset `tag` falls back to the chart's `appVersion`.
- **The install-wide `-knarr` settings** that `config.allium` `Installed` names, as `application_ffi.erl` reads them: `status_port`, `status_path`, `max_body_bytes`, `thresholds`, `threshold_margin`, `unknown_polls`, `absent_after`, `poll_interval`, `poll_timeout`, `patch_interval`, `list_interval`, `poll_concurrency`, `poll_jitter_percent`, `patch_rate_per_second`, `patch_burst`, `backoff_initial`, `backoff_cap` and `log_level`. All eighteen default to unset, so knarr's own defaults apply. `discovery`, `port` and `bind` are left out: the chart owns them, because the probes and the discovery the install exists for depend on them.
- **Scheduling and metadata:** `resources`, `nodeSelector`, `tolerations`, `affinity`, `priorityClassName`, `podAnnotations` and `podLabels`.

Left out on purpose:

- **No `replicaCount`.** One replica under `Recreate` with no Lease is pinned by `scripts/checks/tests/test_deployment.py` and [DEFERRED §4](../DEFERRED.md#4-ha-and-leader-election). A value that offered more replicas would offer a configuration knarr does not support.
- **No ClusterRole toggle.** The install is one namespace (OVERVIEW §9.18), and the Role and RoleBinding go in `.Release.Namespace`.
- **No PodDisruptionBudget,** because one replica under `Recreate` has nothing to keep available during a disruption.
- **No ServiceMonitor or Service,** because knarr has no Service.

### The schema: types only

- **`values.schema.json` with `additionalProperties: false` on every object knarr defines:** the top level, `image`, and the object holding the eighteen `-knarr` settings. A misspelt key there fails `helm install` and `helm template` instead of being ignored. The maps whose keys the user chooses, `podAnnotations`, `podLabels` and `nodeSelector`, are `type: object` with `additionalProperties: {type: string}`. The Kubernetes objects are left open: `resources` and `affinity` are `type: object`, and `tolerations` and `image.pullSecrets` are `type: array`, because kubeconform `-strict` on the render (below) already validates their shapes against the vendored schemas. Ticket 02 tests both sides: an unknown top-level key is rejected, and an arbitrary annotation key such as `knarr.dev/local-image-id` renders. cert-manager, KEDA and external-dns ship a `values.schema.json`; cert-manager's and KEDA's set `additionalProperties: false`.
- **The schema checks types only, and knarr's startup refusal stays the one range check.** `config.allium` `Installed` already states each key's range by its owning module, and knarr refuses to start on a value outside it, naming the key. A schema that carried the ranges too would be a second statement of them, to be kept equal to the specification by a checker test. [Decision 0001](0001-specs-decide-behaviour.md) says the specifications decide; one range check, in the code the specifications govern, keeps that true without a copy to drift. The cost is that a bad range fails at pod start rather than at `helm install`, which `--wait` surfaces.

### The gate

- **`kubernetes-helm` and `kustomize` join the `default` environment,** so the required `check` job lints and renders the chart. Today the gate has neither helm nor a standalone kustomize: both are pinned in the cluster environment, and `deployment.py --render` runs there, outside `check`. Ticket 02 moves the pins and adds the chart checks: `helm lint --strict`, `helm template` through kubeconform `-strict` against the vendored schemas, the version lockstep, and a drift check of the render against `deploy/base` while the base exists.
- **The chart's tests are pytest over `helm template`,** like `test_deployment.py` over the base, not the helm-unittest plugin (v1.2.1 exists). That keeps the repository's one test pattern for the checkers and needs no Helm plugin under Helm 4, whose plugin system is new. chart-testing (v3.15.0) is not adopted either: the checks above cover its `ct lint`, and the kind loop of ticket 03 installs the chart.

### Helm 3 and Helm 4

- **The chart uses `apiVersion: v2` and no Helm-4-only feature.** It is rendered and tested with the Helm the environment pins, 4.3.0 today; 4.3.1 and 3.22.1 were released on 2026-10-15, and moving the pin is [Decision 0014](0014-dependency-updates-and-audit.md)'s routine, not this record's. Helm 4.0.0 shipped on 2025-11-12, with server-side apply and post-renderers as plugins. Helm 3 gets security fixes until 2027-02-10. Helm says Helm 4 is "expected to be compatible with the majority of existing Helm 3 charts" and that "v2 charts continue to work unchanged", so a chart that installs with Helm 4 and uses nothing newer is expected to install with Helm 3. That is a statement of Helm's, not a test of knarr's.

### Labels

- Every resource carries Helm's recommended labels, `app.kubernetes.io/name`, `instance`, `version` and `managed-by`, and `helm.sh/chart`. The Deployment's selector `matchLabels` stays exactly `app.kubernetes.io/name: knarr`, because the selector is immutable (below). The pod template carries that label. Helm's labels go on every resource's metadata and on the pod template; `podLabels` go on the pod template only, where the chart's own labels win a clash; neither ever goes on the selector.

### Migration by adoption

- An existing kustomize install moves to Helm by adoption. Each of the four resources (the ServiceAccount, Role, RoleBinding and Deployment, all named `knarr`) gets the label `app.kubernetes.io/managed-by: Helm` and the annotations `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace`; then `helm upgrade --install` takes them over. Helm 4.3.1 checks exactly that label and those two annotations, and refuses a resource without them as one that "exists and cannot be imported into the current release" (`pkg/action/validate.go`). Amended by ticket 05: the label and annotations are necessary, not sufficient. Helm 4 installs by server-side apply as field manager `helm`, and `kubectl apply -k` left the fields it set owned by `kubectl-client-side-apply`, so the adopting `helm upgrade --install` failed on the image, the RoleBinding's subjects and the projected token volume ([conflict](../../.scratch/helm-chart/evidence/05/04-migration-conflict.txt)). `--force-conflicts` adopted, but kubectl kept co-owning every field it had set to the chart's value, and the next ordinary upgrade conflicted again ([forced](../../.scratch/helm-chart/evidence/05/05-migration-force-conflicts.txt)). Helm "won't support ownership transfer of fields" (HIP-0023), and its client-side-to-server-side upgrade migrates only its own manager (`upgradeClientSideFieldManager`, `pkg/kube/client.go` at v4.3.0). The guide therefore hands the fields over first by the Kubernetes ownership transfer, applying the installed overlay unchanged with `kubectl apply --server-side --field-manager=helm --force-conflicts`, after which the adoption and later upgrades applied with no conflict and Helm as the only server-side manager; `kubectl label` and `kubectl annotate` still co-own the ownership label and annotations, at the values the chart sets ([handover](../../.scratch/helm-chart/evidence/05/07-migration-ssa-handover-forced.txt)). Adopting by client-side apply (`--server-side=false`) also worked, but leaves the release client-side for good, unlike every fresh install ([client-side](../../.scratch/helm-chart/evidence/05/08-migration-client-side.txt)).
- **The chart therefore keeps the base's resource names and its Deployment selector, `app.kubernetes.io/name: knarr`, exactly.** A changed name would install a second controller beside the first; a changed selector cannot be applied to an existing Deployment at all. Ticket 05 proves the procedure on a real install and documents it.

### Uninstall

- The `lifecycle.allium` `Uninstall` `Procedure` order stands: opt every Deployment out, wait for cleanup, inspect and recover markers, and only then delete the install. `helm uninstall` replaces `kubectl delete -k` as that last step. Ticket 05 changes the clause and the [operations page](../operations/controller.md#uninstall-and-recover) together.

### End state

- **Helm is the only supported install.** Ticket 06 retires the kustomize tree under `deploy/`, `just release-pin` and the overlay checks once the chart has installed a release (ticket 05) and the local loop and CI run on it (ticket 03). A kubectl-only user pipes `helm template` into `kubectl apply`. Amended by [ticket 06](../../.scratch/helm-chart/issues/06-retire-kustomize-packaging.md) on 2026-10-21: done. `deploy/`, `just release-pin`, `pin-digest.sh`, `deployment.py --render`, `just deployment-check` and the drift check are gone. The base's invariants are tested on the chart's render in `test_chart.py`, the wrong-CA patch moved to `fixtures/wrong-ca/`, and `v0.2.0` is the last release whose tag carries the overlay. The kubectl-only route keeps the render, since `kubectl delete -f` on it is the route's uninstall.

### Deferred

- **Signing and attesting the chart** wait for bootstrap ticket 38's image attestations and are ticket 07. Ticket 07 attests the chart's digest with GitHub artifact attestations (`actions/attest-build-provenance`, verified with `gh attestation verify`), the mechanism 38 uses for the image, so the image and the chart are attested one way. Kyverno's `cosign sign` and a Helm `.prov` file stay deferred until a consumer asks, as [DEFERRED §8](../DEFERRED.md#8-other-future-targets) says of the image.
- **An Artifact Hub listing** is ticket 08. Artifact Hub lists OCI chart repositories by their `oci://registry/namespace/chart-name` URL, with an `artifacthub.io` metadata layer.

## Findings

- **The ticket's sources hold, with three refinements.** Kyverno's drift check is its own workflow, `check-codegen.yaml` ("Verify codegen is up to date"), not a job of `helm-release.yaml`. cert-manager's lockstep shows in its `manifests.mk` packaging line, not on its install page. Helm's compatibility statement is an expectation ("expected to be compatible with the majority"), not a promise.
- **A new GHCR package is private by default** ("When you first publish a package, the default visibility is private"), yet bootstrap ticket 37 found the knarr image public from its first push ([public.txt](../../.scratch/bootstrap/evidence/37/public.txt)). Ticket 05 therefore verifies the chart package's visibility rather than assuming either.
- **The optional registry dry run is ticket 04's.** Ticket 01's optional box, a loopback `registry:2` push and pull of a chart with a stamped digest, is carried out by ticket 04's dry run, where the real stamping script exists to run it. It ran on 2026-10-17 ([registry.txt](../../.scratch/helm-chart/evidence/04/registry.txt)): the chart probed absent, was pushed, probed present at the digest `helm push` printed, and, pulled by that digest, rendered the stamped image reference with `IfNotPresent`.

## Sources

Public-source research as of 2026-10-17; [sources.txt](../../.scratch/helm-chart/evidence/01/sources.txt) records each page's sha256 and each phrase, and [sources.sh](../../.scratch/helm-chart/evidence/01/sources.sh) refetches them.

- cert-manager: [Helm install](https://cert-manager.io/docs/installation/helm/) (OCI charts as the source of truth, `oci://quay.io/jetstack/charts/cert-manager`), [manifests.mk](https://github.com/cert-manager/cert-manager/blob/master/make/manifests.mk) (lockstep packaging, static YAML from `helm template`), and its `values.schema.json` (an image `digest`, `additionalProperties: false`).
- Kyverno: [helm-release.yaml](https://github.com/kyverno/kyverno/blob/main/.github/workflows/helm-release.yaml) (`helm push` to `ghcr.io/<owner>/charts`, `cosign sign`) and [check-codegen.yaml](https://github.com/kyverno/kyverno/blob/main/.github/workflows/check-codegen.yaml) (the drift check).
- KEDA: the [separate charts repository](https://github.com/kedacore/charts), its CONTRIBUTING (resources updated by hand from the release YAML), the main repository's Makefile (that YAML built with kustomize), and its `values.schema.json`.
- prometheus-community: [release.yaml](https://github.com/prometheus-community/helm-charts/blob/main/.github/workflows/release.yaml) (Helm v4.3.1, `helm push` to `oci://ghcr.io/<owner>/charts`).
- Helm: [Helm 4 released](https://helm.sh/blog/helm-4-released), [Helm v3 end of life](https://helm.sh/blog/helm-v3-end-of-life), the [Helm 4 overview](https://helm.sh/docs/overview/), [OCI registries](https://helm.sh/docs/topics/registries/), [label best practices](https://helm.sh/docs/chart_best_practices/labels/), [charts](https://helm.sh/docs/topics/charts/) (`values.schema.json`), and `pkg/action/validate.go` at v4.3.1 (adoption). The v4.3.1 and v3.22.1 release dates come from the GitHub releases API.
- Tooling: the chart-testing v3.15.0 and helm-unittest v1.2.1 releases, and the [kubeconform](https://github.com/yannh/kubeconform) README (`-strict`).
- external-dns: its chart's `values.schema.json`.
- [GitHub Container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) (a new package is private) and [Artifact Hub Helm repositories](https://artifacthub.io/docs/topics/repositories/helm-charts/) (OCI repositories and the metadata layer).

## Verification

- `sh .scratch/helm-chart/evidence/01/sources.sh <empty-dir>`: 25 pages, each HTTP 200; 41 phrases found, 0 not found ([sources.txt](../../.scratch/helm-chart/evidence/01/sources.txt)).
- `just docs-check` and `just check` pass on the change that adds this record.
- The publish step: `sh scripts/with-env.sh sh .scratch/helm-chart/evidence/04/registry.sh <empty-dir>` stamps, packages, probes, pushes, probes again, pulls by digest and templates the chart against a loopback `registry:2` ([registry.txt](../../.scratch/helm-chart/evidence/04/registry.txt)), and `scripts/release/stamp-chart_test.sh` tests the stamp (ticket 04).

## Consequences

The tickets that carry this record out are in [`.scratch/helm-chart/issues/`](../../.scratch/helm-chart/README.md):

- **[02](../../.scratch/helm-chart/issues/02-chart-renders-base.md)** writes the chart, moves helm and kustomize into the default environment, and gates it: lint, render, schema, version lockstep and drift against the base.
- **[03](../../.scratch/helm-chart/issues/03-local-loop-and-ci-install-chart.md)** moves the kind loop and the CI clusters onto the chart.
- **[04](../../.scratch/helm-chart/issues/04-release-publishes-chart.md)** stamps the digest and publishes the chart from `release.yml`, with its own existence guard and the version-bump recovery, and dry-runs it against a loopback registry ([registry.txt](../../.scratch/helm-chart/evidence/04/registry.txt)).
- **[05](../../.scratch/helm-chart/issues/05-install-first-published-chart.md)** installs the first published chart, verifies the package's visibility, proves adoption of a kustomize install, and changes the `Uninstall` clause and the operations page.
- **[06](../../.scratch/helm-chart/issues/06-retire-kustomize-packaging.md)** retires `deploy/`, `release-pin` and the overlay checks.
- **[07](../../.scratch/helm-chart/issues/07-attest-published-chart.md)** signs and attests the chart, after bootstrap ticket 38.
- **[08](../../.scratch/helm-chart/issues/08-artifact-hub-listing.md)** lists the chart on Artifact Hub.
- **Bootstrap [38](../../.scratch/bootstrap/issues/38-attestations-sbom-arm64.md)** switches the release to an index digest; the chart stamps whichever digest the release pins.

Until 04 publishes a chart and 05 installs it, 0012's kustomize route remains the documented install, and the MVP installs through it. From 05 it stays documented, as deprecated, beside the Helm-first guide, and Helm becomes the only supported install when 06 retires it. Amended by 06: retired, and the guide points an overlay install at the `v0.2.0` guide's migration procedure.

## What would reopen this

- **Helm 3 compatibility is needed as a tested guarantee** rather than Helm's expectation: add a Helm 3 render to the gate.
- **A user needs a value outside v1** (another Role scope, more replicas): each is a product decision first, and more replicas reopens DEFERRED §4.
- **The startup refusal proves too late in practice** for a bad range: reopen the schema policy, with ranges pinned to the specifications by a checker test.
- **GHCR or Helm changes how OCI charts are referenced or adopted:** revisit the reference and the migration.

## Related pages

- [Decision 0012: Release and packaging](0012-release-and-packaging.md), whose kustomize-only choice this record changes
- [Decision 0001: Specifications decide behaviour](0001-specs-decide-behaviour.md), for the schema's range policy
- [Decision 0014: Dependency updates and audit](0014-dependency-updates-and-audit.md), for the helm pin
- [DEFERRED.md §8](../DEFERRED.md#8-other-future-targets) and [OVERVIEW §9.15](../OVERVIEW.md#9-open-questions-candidate-tickets)
- [The helm chart round](../../.scratch/helm-chart/README.md) and [ticket 01](../../.scratch/helm-chart/issues/01-helm-chart-decision.md)
- [Evidence for this record](../../.scratch/helm-chart/evidence/01/sources.txt)
