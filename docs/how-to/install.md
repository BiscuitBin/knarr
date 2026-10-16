---
title: "Install a published Knarr release"
kind: "how-to"
audience: ["user", "operator"]
canonical_for: ["release_installation", "release_upgrade"]
requires: []
---

# Install a published Knarr release

The only release recorded in this checkout is `v0.1.0`, the walking skeleton. It does not contain the controller behavior described by the worker, configuration, KEDA, and operations guides. [Ticket 40](../../.scratch/bootstrap/issues/40-mvp-release.md) owns the first MVP release and its digest. Select a release whose changelog actually includes the controller features you need; the procedure below also explains how to reproduce the skeleton install ([Decision 0012](../decisions/0012-release-and-packaging.md), release route; [ticket 37 hand-back](../../.scratch/bootstrap/issues/37-first-release-v0-1-0.md#what-each-later-ticket-needs)).

## Prerequisites

Use an amd64 Linux cluster, kubectl access to the intended namespace, Git, Pixi, and just. The recorded release image is amd64 only and public, so it needs no `imagePullSecrets`. Install one Knarr replica per namespace, in the same namespace as its worker Deployments; the packaged Role is namespaced. Check [PodDeletionCost](../operations/controller.md#verify-poddeletioncost) before expecting any bias ([Decision 0012](../decisions/0012-release-and-packaging.md), packaging and architectures; [lifecycle.allium](../specs/lifecycle.allium), `Restart` `Replica`; [config.allium](../specs/config.allium), `Configuration` `Discovery`).

## Select the tag and digest together

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

`just release-pin` changes the local overlay and checks its render with the cluster environment's standalone kustomize. `kubectl apply -k` uses kubectl's bundled kustomize; the recorded tools are 5.8.2 and 5.7.1 respectively. Both rendered the same pinned image in ticket 37's evidence. Keep the checkout and digest for later removal. Before applying, inspect the context and rendered resources above: the image must be exactly the chosen `ghcr.io/steven-cutting/knarr@sha256:` reference. Stop if the context or image is wrong; printing them does not enforce a match ([Decision 0012](../decisions/0012-release-and-packaging.md), release-overlay amendment; [install-at-tag evidence](../../.scratch/bootstrap/evidence/37/install-at-tag.txt)):

```sh
kubectl -n "$worker_namespace" apply -k deploy/release
kubectl -n "$worker_namespace" rollout status deployment/knarr
kubectl -n "$worker_namespace" get deployment knarr \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

For a release containing the controller, prepare the [worker endpoint](worker.md), allow [status traffic](../operations/controller.md#allow-status-traffic), then [opt the Deployment in](../reference/configuration.md#opt-in). Inspect discovery freshness, polling, and annotations using the [operations guide](../operations/controller.md#observe-the-controller); readiness alone does not prove continued discovery ([config.allium](../specs/config.allium), `Configuration` `OptIn`, `Discovery`; [observability.allium](../specs/observability.allium), `Probes` `Readiness`).

## Upgrade or remove

Upgrade using a separate checkout of the new release tag, its own run's digest, `just release-pin`, and the same namespace-scoped `kubectl apply -k deploy/release`. The packaged Deployment uses `Recreate` and one replica; do not create a second install to overlap it. Existing annotations survive restart and are reconciled by the normal loop, without age-based expiry ([Decision 0012](../decisions/0012-release-and-packaging.md), digest-pinned installs; `deploy/base/resources.json`; [lifecycle.allium](../specs/lifecycle.allium), `Restart` `Replica`, `NoStartupStep`, `NoExpiry`).

For a fresh `v0.1.0` skeleton install, with no annotations left by an earlier controller in the namespace, delete the packaged resources directly from the retained operator checkout of that release. The skeleton runs no discovery loop and writes no worker annotations, so there is no controller cleanup to await and no discovery or target metrics to check ([tagged startup](https://github.com/steven-cutting/knarr/blob/v0.1.0/src/knarr/application_ffi.erl), [tagged runtime](https://github.com/steven-cutting/knarr/blob/v0.1.0/src/knarr/runtime.gleam)):

```sh
kubectl -n "$worker_namespace" delete -k deploy/release
```

For a release running the controller, follow [uninstall and recovery](../operations/controller.md#uninstall-and-recover) before deleting the packaged resources. Deleting the controller first leaves its annotations behind. If the skeleton replaced an earlier controller, or the controller is unavailable, remove Deployment opt-in labels and use [manual recovery](../operations/controller.md#manual-recovery) to inspect and remove confirmed leftovers before deleting the install; do not wait for discovery metrics from the skeleton or an unavailable controller ([lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`, `Recovery`, `Restart` `Leftovers`).
