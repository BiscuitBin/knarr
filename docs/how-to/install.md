---
title: "Install a published Knarr release"
kind: "how-to"
audience: ["user", "operator"]
canonical_for: ["release_installation", "release_upgrade"]
requires: []
---

# Install a published Knarr release

Knarr installs with its Helm chart, published to `oci://ghcr.io/biscuitbin/charts/knarr` with the release's image digest stamped in. `v0.2.0` is the first release that publishes a chart, and the first that contains the controller behavior described by the worker, configuration, KEDA, and operations guides ([ticket 40](../../.scratch/bootstrap/issues/40-mvp-release.md) released it, and [ticket 05](../../.scratch/helm-chart/issues/05-install-first-published-chart.md) records its install). Use the Helm procedure for a release whose successful run summary prints a chart. `v0.1.0`, the walking skeleton, has no chart; an install of it, or of any release through the retired kustomize overlay, follows [installs from the kustomize overlay](#installs-from-the-kustomize-overlay). Select a release whose changelog actually includes the controller features you need ([Decision 0015](../decisions/0015-helm-chart.md), publishing and end state; [Decision 0012](../decisions/0012-release-and-packaging.md), release route).

From `v0.3.0`, images and charts publish under `ghcr.io/biscuitbin/…` ([Decision 0016](../decisions/0016-biscuitbin-org.md)). The `v0.1.0` and `v0.2.0` images remain at `ghcr.io/steven-cutting/knarr`; the `v0.2.0` chart remains at `oci://ghcr.io/steven-cutting/charts/knarr`. Those published packages stay unchanged. Use the old chart path when installing `v0.2.0`; `v0.1.0` has no chart. The commands below use the new path for `v0.3.0` onward.

## Prerequisites

Use an amd64 Linux cluster, kubectl access to the intended namespace, and Helm 4. The chart is tested with Helm 4 and uses no Helm-4-only feature; Helm expects such charts to install with Helm 3, which knarr does not test. The release image is amd64 only and public, so it needs no `imagePullSecrets`. Install one Knarr release per namespace, in the same namespace as its worker Deployments; the packaged Role is namespaced. Check [PodDeletionCost](../operations/controller.md#verify-poddeletioncost) before expecting any bias ([Decision 0015](../decisions/0015-helm-chart.md), Helm 3 and Helm 4; [lifecycle.allium](../specs/lifecycle.allium), `Restart` `Replica`; [config.allium](../specs/config.allium), `Configuration` `Discovery`).

## Verify a release

Releases after `v0.3.0` attest the image and the chart they push with GitHub artifact attestations, and push each attestation to ghcr.io beside its digest; `v0.3.0` and earlier carry none. Before installing, check that each digest was attested by knarr's release workflow. The successful release workflow run's summary for the chosen tag prints the image digest and the chart by digest, `oci://ghcr.io/biscuitbin/charts/knarr@sha256:…`; copy the part after each `@`. `gh` must be authenticated (`gh auth status`). Each command fails unless it finds an attestation for that digest signed by `release.yml` in `biscuitbin/knarr` ([Decision 0012](../decisions/0012-release-and-packaging.md), cosign, SBOM and build provenance; [Decision 0015](../decisions/0015-helm-chart.md), publishing):

```sh
image_digest=sha256:...   # the image digest from the run summary
chart_digest=sha256:...   # the chart digest from the run summary
gh attestation verify "oci://ghcr.io/biscuitbin/knarr@$image_digest" --repo biscuitbin/knarr \
  --signer-workflow biscuitbin/knarr/.github/workflows/release.yml
gh attestation verify "oci://ghcr.io/biscuitbin/charts/knarr@$chart_digest" --repo biscuitbin/knarr \
  --signer-workflow biscuitbin/knarr/.github/workflows/release.yml
helm show values "oci://ghcr.io/biscuitbin/charts/knarr@$chart_digest" | grep 'digest:'
```

The last line must print `$image_digest`: the chart installs the image by the digest stamped into it, so that is the image you verified. Then install by the chart digest you verified, as below, so the chart installed is the one checked.

## Install with Helm

The successful release workflow run's summary for the chosen tag prints the chart by digest, `oci://ghcr.io/biscuitbin/charts/knarr@sha256:…`, the image digest stamped into it, and the `helm install` command. Set `chart_version` to the release version and `worker_namespace` to an existing namespace you intend to manage. Installing changes your selected cluster; check the context first ([Decision 0015](../decisions/0015-helm-chart.md), publishing):

```sh
chart_version=X.Y.Z   # the release version from its run summary
worker_namespace=workers
kubectl config current-context
helm install knarr oci://ghcr.io/biscuitbin/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" --wait
```

The release never pushes a chart version that already exists, but a version is a registry tag, not a content address. To install exactly the chart the summary recorded, install by its digest instead, copying the part after `@` from the summary's chart line:

```sh
chart_digest=sha256:...   # the chart digest from the run summary
helm install knarr "oci://ghcr.io/biscuitbin/charts/knarr@$chart_digest" \
  --namespace "$worker_namespace" --wait
```

`helm install` prints the chart's notes: the namespace, the exact opt-in label, and a link to this guide. Confirm that the Deployment names the image digest the summary records, and that its one pod is Ready and running that image; the pod's `imageID` is the digest the node pulled:

```sh
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n "$worker_namespace" get pods -l app.kubernetes.io/name=knarr \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```

The chart's values set the install-wide `-knarr` settings, resources, scheduling, and pod metadata; `helm show values` on the same reference lists them, and `values.schema.json` rejects an unknown key. The image values are stamped by the release; leave them unset. Then prepare the [worker endpoint](worker.md), allow [status traffic](../operations/controller.md#allow-status-traffic), and [opt the Deployment in](../reference/configuration.md#opt-in). Inspect discovery freshness, polling, and annotations using the [operations guide](../operations/controller.md#observe-the-controller); readiness alone does not prove continued discovery ([Decision 0015](../decisions/0015-helm-chart.md), values surface v1; [config.allium](../specs/config.allium), `Configuration` `OptIn`, `Discovery`, `Installed`; [observability.allium](../specs/observability.allium), `Probes` `Readiness`).

## Upgrade

Upgrade the release in place to the new release's chart, by version or by digest as above. An upgrade with no values flag keeps the previous release's own overrides and takes everything else, including the image, from the new chart; an upgrade with any `--values` or `--set` replaces all the previous overrides with the ones it passes. Keep your overrides in one values file and pass it on every upgrade, as below ([upgrade values evidence](../../.scratch/helm-chart/evidence/05/13-upgrade-values.txt)). Do not use `--reuse-values`: that flag replaces the new chart's defaults with the previous release's values, including the image digest the previous release stamped in, so the upgrade would keep the old image. `--reset-then-reuse-values` starts from the new chart's defaults and keeps the previous release's own overrides ([reuse-values evidence](../../.scratch/helm-chart/evidence/05/02-reuse-values.txt)). The packaged Deployment uses `Recreate` and one replica, so the old pod stops before the new one starts; do not create a second release to overlap it. Existing annotations survive restart and are reconciled by the normal loop, without age-based expiry ([Decision 0015](../decisions/0015-helm-chart.md), values surface v1; [lifecycle.allium](../specs/lifecycle.allium), `Restart` `Replica`, `NoStartupStep`, `NoExpiry`):

```sh
helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" \
  --values knarr-values.yaml --wait
```

To move an existing `v0.2.0` Helm install to the org’s first release, keep the same release name (`knarr` below) and namespace. After `v0.3.0` is published, run:

```sh
helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr \
  --version 0.3.0 --namespace "$worker_namespace" \
  --values knarr-values.yaml --wait
```

Use your existing overrides file, leaving image values unset as above. The stamped chart supplies the new `ghcr.io/biscuitbin/knarr` image repository and release digest; keeping the release name upgrades the existing installation in place ([Decision 0016](../decisions/0016-biscuitbin-org.md), registry paths).

## Install with kubectl only

For a cluster where Helm must not hold a release, render the chart with `helm template` and apply the render with kubectl. Keep the rendered file for as long as the install exists: no Helm release exists for `helm uninstall` to find, and removal is `kubectl delete -f` on that file. Upgrade by rendering the new chart to a new file and applying it. `kubectl apply` never deletes, so first delete any resource the old render lists and the new one does not; then keep the new file in place of the old one ([Decision 0015](../decisions/0015-helm-chart.md), end state; [lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`):

```sh
helm template knarr oci://ghcr.io/biscuitbin/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" > knarr-rendered.yaml
kubectl -n "$worker_namespace" apply -f knarr-rendered.yaml
kubectl -n "$worker_namespace" rollout status deployment/knarr
```

## Uninstall

Uninstalling keeps the order of [uninstall and recovery](../operations/controller.md#uninstall-and-recover): opt every Deployment out, wait for the running controller's cleanup, inspect and recover markers, and only then delete the install with the command matching how it was installed. A kubectl-only install keeps its rendered manifest because its removal is `kubectl delete -f` on that file ([lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`, `Recovery`).

## Installs from the kustomize overlay

Helm is the only supported install from the release after `v0.2.0` ([Decision 0015](../decisions/0015-helm-chart.md), end state). `v0.2.0` is the last release whose tag carries the kustomize release overlay; [helm-chart ticket 06](../../.scratch/helm-chart/issues/06-retire-kustomize-packaging.md) removed it from `main` with the rest of the kustomize packaging. An install still made from that overlay moves to Helm by adoption, in place, with the [migration procedure in the `v0.2.0` install guide](https://github.com/biscuitbin/knarr/blob/v0.2.0/docs/how-to/install.md#migrate-from-the-kustomize-release-overlay): it runs from the retained operator checkout whose overlay pins the installed digest, so it needs nothing from `main`. A fresh `v0.1.0` skeleton install is removed with [the `v0.2.0` guide's direct removal](https://github.com/biscuitbin/knarr/blob/v0.2.0/docs/how-to/install.md#remove-the-skeleton), from the retained checkout of `v0.1.0` ([migration from `v0.1.0` to the published `v0.2.0` chart](../../.scratch/helm-chart/evidence/05/17-published-migration.txt)).
