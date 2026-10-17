# Ticket 51 evidence

The discovery, design checks and live run for [ticket 51](../../issues/51-local-observability.md), the opt-in local Prometheus and Grafana. [The how-to](../../../../docs/how-to/local-observability.md) describes the recipes.

**Status:** run on 2026-10-16 (local time) on the maintainer's Apple-silicon host, Darwin arm64, with OrbStack's Docker engine 29.4.0 (linux/arm64). The cluster was this worktree's kind cluster, kind v0.33.0 on node image v1.35.8, with helm v4.3.0 from the `cluster` pixi environment. The maintainer authorized the network for discovery and for the live run.

## Discovery (Step 0)

### Chart homes

- **prometheus:** `https://prometheus-community.github.io/helm-charts/index.yaml`. Each version is an https `.tgz` on GitHub releases.
- **grafana:** the `grafana/helm-charts` index marks its last entry, 10.5.15 of 2026-01-30, `deprecated: true`. The chart now lives at `https://grafana-community.github.io/helm-charts/index.yaml`, again as https `.tgz` files on GitHub releases.

Neither chart is OCI-only.

### Versions

The pick was the newest version at least about two weeks old, not the newest one. grafana 14.0.x is a major version that appeared on 2026-10-15 and 2026-10-16.

| Chart | Version | appVersion | Created | sha256, equal to the index `digest` |
| --- | --- | --- | --- | --- |
| prometheus | 29.34.0 | v3.15.0 | 2026-09-26 | `e0dc3d372c6db2f055578594eb78c96646671fec4b4e5d3613aa6f66556b4955` |
| grafana | 13.2.6 | 13.2.2 | 2026-09-27 | `051e7f9787d70a144e41f4b53e5dcc57e682b1305ca21b54abc81521b1a37201` |

The prometheus `.tgz` vendors `charts/kube-state-metrics/` (8.6.0), along with alertmanager, node-exporter and pushgateway. Its `Chart.yaml` names `oci://ghcr.io/prometheus-community/charts` as their repository. `helm template` on the archive uses the vendored copies and never contacts that repository. The grafana `.tgz` has no subcharts.

### Images

The renders name these images, verbatim:

```text
image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0
image: "quay.io/prometheus/prometheus:v3.15.0"
image: "docker.io/grafana/grafana:13.2.2-distroless"
```

Each name carries a registry and a `/`, so `keda_kustomization`'s pin pattern accepts it. No registry value had to be set.

With grafana's `testFramework`, `initChownData` and every sidecar off, and prometheus's `configmapReload` off, no helper image is left. `docker buildx imagetools inspect` reports each pin as a manifest list with a linux/amd64 and a linux/arm64 entry:

```text
registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0@sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b
quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e
docker.io/grafana/grafana:13.2.2-distroless@sha256:69a5d2d957ca0bba434c160dcd4f2d07de9d6c756a0ba10ae7f52b72ced1e4cc
```

### Determinism

Each chart was rendered twice with the same values, and `cmp` reported the outputs identical. The fixed `adminPassword` keeps the grafana Secret stable.

### RBAC

The default renders would grant cluster-wide access:

- **prometheus:** a ClusterRole over nodes, services, endpoints, pods, ingresses, configmaps and endpointslices, plus `/metrics`.
- **kube-state-metrics:** a ClusterRole over about 30 resource types.

Both charts can be narrowed, and the values do so:

- **prometheus:** `server.namespaces: [default]` with `server.useExistingClusterRoleName` renders only a RoleBinding in `default`. Its `roleRef` is the shipped ClusterRole `knarr-observability-pod-reader`, which allows get, list and watch on pods.
- **kube-state-metrics:** `rbac.useClusterRole: false`, `namespaces: default` and three collectors render a Role and a RoleBinding in `default`. The Role allows list and watch on deployments, pods and replicasets.
- **grafana:** `rbac.create: false` and `automountServiceAccountToken: false`.

Neither chart renders a cluster-scoped object. That is why the kustomization has no top-level `namespace:`, which would move the `default` objects.

## Adversarial reviews

Codex reviewed each checkpoint statically, without sockets.

### Review 1: design

Accepted:

- Grafana's pod still mounted a token.
- A scrape-config change would not roll Prometheus, so a values hash is now a pod annotation.
- `kustomize build` output gets a structural image check.
- Plugin update checks, plugin preinstall and the news feed are off.
- `port_forward` takes a namespace, and the stack forwards to Deployment container ports.
- The four actions refuse kwok.
- `down` deletes by a stack label rather than the generic `instance` label.

Kept as noted, with no change:

- The in-cluster reachability of anonymous Grafana is documented as the local trust assumption.
- The scrape selection was already right.

### Review 2: install script and tests

Accepted:

- Atomic cache writes.
- Tests that drive `up()`, including one that applies nothing when an image is unpinned.
- Answer parsing that survives malformed JSON.
- An explicit exporter inventory in place of `kube_*` and `erlang_vm_*` prefixes.
- A literal kube-version assertion.
- `down` deletes the RBAC before the namespace.

Rejected:

- **A private snapshot of the verified chart.** The race needs a same-user local process that could equally edit the script.
- **Parsing ConfigMap text before the image check.** The check fails closed, never open.

Reviews 3, on the dashboard and the docs, and 4, on the whole branch, are in the [ticket's hand-back notes](../../issues/51-local-observability.md#hand-back-notes).

## Live run

1. `just cluster-up`, `just image-build`, `just deploy` and `just smoke` passed.
2. `just observability-up` took 48 s from an empty cache, with Prometheus, kube-state-metrics and Grafana Available.
3. `just observability-smoke` reported:

   ```text
   ok   Prometheus reads up{job="knarr"} == 1
   ok   Prometheus reads up{job="kube-state-metrics"} == 1
   ok   Grafana /api/health reports its database ok
   ok   Grafana serves the knarr-overview dashboard
   ```

4. **Rerun.** A second `up` reused both cached archives, whose mtimes did not change. The Grafana pod kept its UID: the dashboard ConfigMap is read live, so Grafana did not restart. A third `up` produced a `kustomize build` byte-identical to the second.
5. **On the cluster:**
   - Every image is the pinned digest.
   - The Prometheus pod carries `knarr.dev/values-sha256`, and Grafana's pod has `automountServiceAccountToken: false`.
   - All 13 namespaced objects, the Namespace, the ClusterRole and the three `default` RBAC objects carry `knarr.dev/stack=observability`. knarr's own Role and RoleBinding in `default` carry no such label.
   - The Deployment selectors are the charts' own.
   - No Secret with the label `owner=helm` exists, so there is no Helm release state.
6. **`kubectl auth can-i`:**

   | ServiceAccount | Check | `default` | `kube-system` |
   | --- | --- | --- | --- |
   | Prometheus | list pods | yes | no |
   | kube-state-metrics | list deployments | yes | no |
   | Grafana | list pods | no | not checked |

7. **The Grafana log** shows no outbound URL fetch. The rendered `grafana.ini` carries:
   - `check_for_updates`, `check_for_plugin_updates` and `reporting_enabled` all false;
   - `preinstall_disabled = true`;
   - `news_feed_enabled = false`.

   Egress was not denied during the run, so this shows only that nothing was logged.
8. **Dashboard data.** Every panel query was evaluated through Prometheus. "BEAM memory" returned no series: `erlang_vm_memory_bytes_total` does not exist, and knarr exports `erlang_vm_memory_bytes{kind}`. The query was corrected, and `fixtures/observability/exporters.json` records every `erlang_vm_` and `kube_` name the stack held, so the dashboard test now catches such a name. The prefix allowance had let it through.

   After `just fake-worker-deploy`, the fake worker was labelled `knarr.io/enabled=true` and `just fake-worker-smoke` ran. Every panel's query, run through Grafana's `/api/ds/query` as the anonymous viewer against the provisioned datasource, then returned data. The Claude-in-Chrome extension was not connected, so nobody looked at the dashboard in a browser.
9. **Stopping `just grafana`.** It printed `Grafana: http://127.0.0.1:52502/d/knarr-overview` on an OS-chosen port. A SIGINT left no forward behind, but exited 241. It now exits 0 on Ctrl-C, and a test covers this.
10. **`just observability-down`** deleted the three `default` RBAC objects, the ClusterRole and then the namespace. Afterwards no namespace, labelled object, or cluster-scoped prometheus, grafana or kube-state-metrics object remained, and knarr's Role and RoleBinding were untouched. A second `down` succeeded with "No resources found". `just smoke` still passed.
11. **kwok.** Each of the four recipes, run with `KNARR_CLUSTER=kwok`, failed with `<action> requires kind; kwok pods do not run containers`.
12. **After reviews 3 and 4.** `just keda-e2e` (three rounds, seed 33) passed in 638 s: 5 of 9 victims were busy for the baseline and 0 of 9 with knarr, and the restart and patch-rate criteria held. With the revised dashboard re-applied, `just observability-smoke` passed again. The dashboard served 9 panels with no custom All value, and every panel's query returned data through Grafana for the two opted-in Deployments keda-e2e leaves behind. `up` now waits on `kubectl rollout status`; a final `up` printed `successfully rolled out` for all three Deployments, `observability-smoke` passed, and `observability-down` left no namespace and no labelled object.
