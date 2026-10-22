---
title: "Install a published Knarr release"
kind: "how-to"
audience: ["user", "operator"]
canonical_for: ["release_installation", "release_upgrade"]
requires: []
---

# Install a published Knarr release

Knarr installs with its Helm chart, published to `oci://ghcr.io/steven-cutting/charts/knarr` with the release's image digest stamped in. `v0.2.0` is the first release that publishes a chart, and the first that contains the controller behavior described by the worker, configuration, KEDA, and operations guides ([ticket 40](../../.scratch/bootstrap/issues/40-mvp-release.md) released it, and [ticket 05](../../.scratch/helm-chart/issues/05-install-first-published-chart.md) records its install). Use the Helm procedure for a release whose successful run summary prints a chart. `v0.1.0`, the walking skeleton, has no chart and is installable only through the deprecated [kustomize route](#kustomize-route-deprecated). Select a release whose changelog actually includes the controller features you need ([Decision 0015](../decisions/0015-helm-chart.md), publishing and end state; [Decision 0012](../decisions/0012-release-and-packaging.md), release route).

## Prerequisites

Use an amd64 Linux cluster, kubectl access to the intended namespace, and Helm 4. The chart is tested with Helm 4 and uses no Helm-4-only feature; Helm expects such charts to install with Helm 3, which knarr does not test. The release image is amd64 only and public, so it needs no `imagePullSecrets`. Install one Knarr release per namespace, in the same namespace as its worker Deployments; the packaged Role is namespaced. Check [PodDeletionCost](../operations/controller.md#verify-poddeletioncost) before expecting any bias ([Decision 0015](../decisions/0015-helm-chart.md), Helm 3 and Helm 4; [lifecycle.allium](../specs/lifecycle.allium), `Restart` `Replica`; [config.allium](../specs/config.allium), `Configuration` `Discovery`).

## Install with Helm

The successful release workflow run's summary for the chosen tag prints the chart by digest, `oci://ghcr.io/steven-cutting/charts/knarr@sha256:…`, the image digest stamped into it, and the `helm install` command. Set `chart_version` to the release version and `worker_namespace` to an existing namespace you intend to manage. Installing changes your selected cluster; check the context first ([Decision 0015](../decisions/0015-helm-chart.md), publishing):

```sh
chart_version=X.Y.Z   # the release version from its run summary
worker_namespace=workers
kubectl config current-context
helm install knarr oci://ghcr.io/steven-cutting/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" --wait
```

The release never pushes a chart version that already exists, but a version is a registry tag, not a content address. To install exactly the chart the summary recorded, install by its digest instead, copying the part after `@` from the summary's chart line:

```sh
chart_digest=sha256:...   # the chart digest from the run summary
helm install knarr "oci://ghcr.io/steven-cutting/charts/knarr@$chart_digest" \
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
helm upgrade knarr oci://ghcr.io/steven-cutting/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" \
  --values knarr-values.yaml --wait
```

## Install with kubectl only

For a cluster where Helm must not hold a release, render the chart with `helm template` and apply the render with kubectl. Keep the rendered file for as long as the install exists: no Helm release exists for `helm uninstall` to find, and removal is `kubectl delete -f` on that file. Upgrade by rendering the new chart to a new file and applying it. `kubectl apply` never deletes, so first delete any resource the old render lists and the new one does not; then keep the new file in place of the old one ([Decision 0015](../decisions/0015-helm-chart.md), end state; [lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`):

```sh
helm template knarr oci://ghcr.io/steven-cutting/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" > knarr-rendered.yaml
kubectl -n "$worker_namespace" apply -f knarr-rendered.yaml
kubectl -n "$worker_namespace" rollout status deployment/knarr
```

## Migrate from the kustomize release overlay

An install made with `kubectl apply -k deploy/release` moves to Helm by adoption, in place. The chart keeps the overlay's four resource names, all `knarr`, and its Deployment selector, so Helm takes the same objects over rather than installing a second controller. Opted-in Deployments stay opted in, and owned annotations survive: the pod is replaced under `Recreate`, a gap with no Knarr pod is allowed, and two Knarr pods never run at once ([Decision 0015](../decisions/0015-helm-chart.md), migration by adoption; [lifecycle.allium](../specs/lifecycle.allium), `Restart` `Replica`, `NoStartupStep`).

Helm 4 writes by server-side apply as field manager `helm`, which refuses to change a field another manager owns. `kubectl apply -k` left every field it set owned by `kubectl-client-side-apply`, so a bare `helm upgrade --install` fails on the image and other fields, and forcing it once leaves kubectl co-owning the rest, so every later upgrade conflicts again. First hand the fields to Helm's manager: from the retained operator checkout, whose overlay still pins the installed digest, apply the same overlay server-side as `helm`. The force overwrites live values, so check first that the install still matches the overlay: `kubectl diff` must print nothing. If it prints a difference, someone changed the install by hand; carry that change into your values file, `knarr-values.yaml`, or accept losing it, before you continue ([drift check evidence](../../.scratch/helm-chart/evidence/05/14-handover-drift-check.txt)). Applying unchanged values under a second manager is the [Kubernetes ownership transfer](https://kubernetes.io/docs/reference/using-api/server-side-apply/#transferring-ownership-between-managers); `--force-conflicts` covers the fields kubectl's last-applied record cannot account for, and writes the values they already hold ([migration evidence](../../.scratch/helm-chart/evidence/05/07-migration-ssa-handover-forced.txt); [from `v0.1.0` to the published `v0.2.0` chart](../../.scratch/helm-chart/evidence/05/17-published-migration.txt)):

```sh
kubectl config current-context
kubectl -n "$worker_namespace" diff -k deploy/release
kubectl -n "$worker_namespace" apply --server-side --field-manager=helm --force-conflicts -k deploy/release
```

Then mark each resource as belonging to the release, and upgrade into it with the same release name and namespace. Pass the values file here as on every later [upgrade](#upgrade): an adoption without it installs the chart's defaults over any change you carried into it. With no overrides, the file can be empty:

```sh
for resource in serviceaccount/knarr role/knarr rolebinding/knarr deployment/knarr; do
  kubectl -n "$worker_namespace" label "$resource" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl -n "$worker_namespace" annotate "$resource" --overwrite \
    meta.helm.sh/release-name=knarr meta.helm.sh/release-namespace="$worker_namespace"
done
helm upgrade --install knarr oci://ghcr.io/steven-cutting/charts/knarr \
  --version "$chart_version" --namespace "$worker_namespace" \
  --values knarr-values.yaml --wait
```

Helm refuses a resource missing that label or either annotation as one that "exists and cannot be imported into the current release"; mark it and run the upgrade again. A `conflict occurred while applying` error names a field still owned by another manager: the handover above was skipped or ran from a different overlay. Helm then marks the release `failed`, and the kustomize controller keeps running unchanged; run the handover and the upgrade again. Do not delete the kustomize install first: deleting the running controller before cleanup leaves its owned annotations standing. After the migration, later upgrades are the plain [upgrade](#upgrade) above, and the operator checkout of the overlay is no longer needed ([conflict evidence](../../.scratch/helm-chart/evidence/05/04-migration-conflict.txt); [recovery evidence](../../.scratch/helm-chart/evidence/05/10-migration-recovery.txt)).

## Uninstall

Uninstalling keeps the order of [uninstall and recovery](../operations/controller.md#uninstall-and-recover): opt every Deployment out, wait for the running controller's cleanup, inspect and recover markers, and only then delete the install with the command matching how it was installed. A kubectl-only install keeps its rendered manifest because its removal is `kubectl delete -f` on that file ([lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`, `Recovery`).

## Kustomize route (deprecated)

The kustomize release overlay stays documented until [Decision 0015](../decisions/0015-helm-chart.md)'s ticket 06 retires it, and it is the only route for `v0.1.0`. It needs Git, Pixi, and just as well as kubectl, and a separate operator checkout of the release tag ([Decision 0012](../decisions/0012-release-and-packaging.md), release route; [ticket 37 hand-back](../../.scratch/bootstrap/issues/37-first-release-v0-1-0.md#what-each-later-ticket-needs)).

### Select the tag and digest together

Obtain the immutable image digest from the successful release workflow run's summary for the chosen tag. The summary prints `ghcr.io/steven-cutting/knarr@sha256:…`; pass the part after `@` to `just release-pin`. The argument must be exactly `sha256:` followed by 64 lowercase hexadecimal digits; from a run log's `digest=` line, copy only the value after `=`. Do not apply an unmodified tag checkout: the overlay there still contains the previous digest, since each pin lands after publication ([Decision 0012](../decisions/0012-release-and-packaging.md), release-overlay amendment from 37).

In a separate operator checkout, the following reproduces the recorded skeleton release. Cluster-tool installation downloads dependencies; apply changes your selected cluster. Set `worker_namespace` to an existing namespace you intend to manage. For a later release, replace both the tag and digest using that release's own summary ([ticket 37](../../.scratch/bootstrap/issues/37-first-release-v0-1-0.md#what-each-later-ticket-needs)):

```sh
git clone https://github.com/steven-cutting/knarr.git knarr-install
cd knarr-install
git checkout v0.1.0
just cluster-install
export PATH="$PWD/.pixi/envs/cluster/bin:$PATH"
release_digest='sha256:97262e02b6326b73ac414fa1bb01b6f557b1c352b7d647a30d7835e4a59e22c7'
just release-pin "$release_digest"
worker_namespace=workers
kubectl config current-context
kubectl kustomize deploy/release
```

`just release-pin` changes the local overlay and checks its render with the cluster environment's standalone kustomize. `kubectl apply -k` uses kubectl's bundled kustomize; ticket 37 recorded 5.8.2 and 5.7.1 respectively, and both rendered the same pinned image in its evidence. The cluster environment's kubectl is now 1.36.0, which bundles kustomize 5.8.1. Keep the checkout and digest for later removal. Before applying, inspect the context and rendered resources above: the image must be exactly the chosen `ghcr.io/steven-cutting/knarr@sha256:` reference. Stop if the context or image is wrong; printing them does not enforce a match ([Decision 0012](../decisions/0012-release-and-packaging.md), release-overlay amendment; [install-at-tag evidence](../../.scratch/bootstrap/evidence/37/install-at-tag.txt)):

```sh
kubectl -n "$worker_namespace" apply -k deploy/release
kubectl -n "$worker_namespace" rollout status deployment/knarr
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Upgrade a kustomize install by [migrating it to Helm](#migrate-from-the-kustomize-release-overlay) at the new release. To stay on kustomize until ticket 06, upgrade using a separate checkout of the new release tag, its own run's digest, `just release-pin`, and the same namespace-scoped `kubectl apply -k deploy/release`. A kustomize install that runs the controller is removed by following [uninstall and recovery](../operations/controller.md#uninstall-and-recover), with `kubectl delete -k` from the retained checkout as its delete step.

### Remove the skeleton

For a fresh `v0.1.0` skeleton install, with no annotations left by an earlier controller in the namespace, delete the packaged resources directly from the retained operator checkout of that release. The skeleton runs no discovery loop and writes no worker annotations, so there is no controller cleanup to await and no discovery or target metrics to check ([tagged startup](https://github.com/steven-cutting/knarr/blob/v0.1.0/src/knarr/application_ffi.erl), [tagged runtime](https://github.com/steven-cutting/knarr/blob/v0.1.0/src/knarr/runtime.gleam)):

```sh
kubectl -n "$worker_namespace" delete -k deploy/release
```

If the skeleton replaced an earlier controller, or the controller is unavailable, remove Deployment opt-in labels and use [manual recovery](../operations/controller.md#manual-recovery) to inspect and remove confirmed leftovers before deleting the install; do not wait for discovery metrics from the skeleton or an unavailable controller ([lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`, `Recovery`, `Restart` `Leftovers`).
