---
title: "See the local cluster's metrics in Grafana"
kind: "how-to"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["local_observability"]
requires: []
---

# See the local cluster's metrics in Grafana

An optional Prometheus and Grafana stack collects and shows the metrics of
this worktree's kind cluster, with one example dashboard to build on. It is a
contributor convenience: it never runs in `just check` or in any workflow, it
has no alerting and no persistence, and it never touches a non-local cluster.
All four recipes refuse kwok, whose pods run no containers.

## Opting in

Start from a running kind loop, as [the local cluster page](local-cluster.md)
describes: `just cluster-up`, `just image-build` and `just deploy`. knarr then
exports its startup and VM metrics, but its per-Deployment series appear only
once it has targets. For those, also run `just fake-worker-image-build` and
`just fake-worker-deploy` from [the fake worker page](../reference/fake-worker.md),
and label the worker Deployment `knarr.io/enabled=true`.

Then run, in order:

1. `just observability-up` installs the stack into the `observability`
   namespace and waits up to 300 s for each rollout of the
   `prometheus-server`, `prometheus-kube-state-metrics` and `grafana`
   Deployments to finish.
   The first run downloads the two chart archives, so it needs network; agents
   need explicit authorization for it. A rerun uses the cached archives while
   their hashes still match.
2. `just observability-smoke` checks that Prometheus reads `up == 1` for both
   scrape jobs, that Grafana's `/api/health` reports its database ok, that
   Grafana serves the `knarr-overview` dashboard, and that Grafana reads
   `up{job="knarr"} == 1` through its provisioned `knarr-prometheus`
   datasource, the path every panel takes. Each check waits up to 120 s. It needs knarr deployed, or the `knarr` job never comes up.
3. `just grafana` forwards Grafana to a loopback port and prints
   `http://127.0.0.1:<port>/d/knarr-overview`. It runs in the foreground
   until Ctrl-C. By default the OS chooses the port, because worktree
   clusters run side by side; `just grafana 3000` asks for a fixed one.

## How the stack is built

`fixtures/observability/stack.json` pins two charts by sha256: prometheus
29.34.0 from prometheus-community, and grafana 13.2.6 from grafana-community,
the chart's home since grafana/helm-charts deprecated it. Each `.tgz` is
downloaded over https once, refused unless its hash matches, and cached under
`.cluster/observability/charts/`. Each is rendered locally:

```sh
helm template <release> <archive> --no-hooks --namespace observability \
  --kube-version v1.35.8 -f <values>
```

There is no `helm repo`, dependency build or install, so the cluster holds no
Helm release state. The Kubernetes version is the kind node's. The renders sit
beside the static layer from `fixtures/observability/` under
`.cluster/observability/base/`, and an overlay pins every image they name to a
multi-arch index digest with amd64 and arm64 entries: kube-state-metrics
v2.20.0, prometheus v3.15.0 and grafana 13.2.2-distroless. `up` refuses a
build that names any other image or leaves a pin unused, then applies it
server-side. Every object carries the label `knarr.dev/stack=observability`.

Prometheus runs without its config reloader, so `up` sets a
`knarr.dev/values-sha256` pod annotation from the values file: changing the
values rolls the Prometheus pod. It scrapes every 15 s and keeps 6 h of
samples on no persistent volume, so a restart loses them.

## What is scraped

Prometheus scrapes exactly two jobs:

- `knarr`: pod discovery in `default`, keeping pods labelled
  `app.kubernetes.io/name=knarr` on their port named `http`, and adding
  `namespace` and `pod` labels. These are the series the
  [observability specification](../specs/observability.allium) defines, plus
  the `erlang_vm_` metrics.
- `kube-state-metrics`: the static target
  `prometheus-kube-state-metrics.observability.svc:8080`, with only the
  deployments, pods and replicasets collectors, watching `default` alone.
  It supplies the replica counts knarr does not export.

The RBAC is namespaced to `default`. kube-state-metrics gets a Role there with
list and watch on deployments, pods and replicasets. Prometheus gets a
RoleBinding there to the shipped ClusterRole `knarr-observability-pod-reader`,
which grants get, list and watch on pods; bound by a RoleBinding, it grants
nothing outside `default`. Grafana has no RBAC and no ServiceAccount token
mounted.

## The example dashboard

Grafana provisions one Prometheus datasource, uid `knarr-prometheus`, at
`http://prometheus-server.observability.svc:80`, and the `knarr overview`
dashboard in the `knarr` folder. The dashboard is read-only, refreshes every
30 s over the last 30 minutes, and has a multi-select `Deployment` variable
read from `label_values(knarr_pods, deployment)`; All means every Deployment
knarr reports, so the replica panel leaves out the rest of `default`. Its panels:

| Panel | What it shows |
| --- | --- |
| Discovery age | Seconds since `knarr_last_discovery_timestamp_seconds` |
| Targets | `knarr_targets` |
| Pods by tier | `knarr_pods` for the selected Deployments |
| Poll rate by reading | `knarr_polls_total` rate, by reading |
| Patch rate | `knarr_patches_total` rate, by purpose and result |
| Patches pending | `knarr_patches_pending` for the selected Deployments |
| Poll duration p95 | The 95th percentile of `knarr_poll_duration_seconds` |
| Replicas, desired and available | kube-state-metrics' `kube_deployment_spec_replicas` and `kube_deployment_status_replicas_available` |
| BEAM memory | `erlang_vm_memory_bytes` by kind |

## Adding a dashboard

1. Save the dashboard's JSON in `fixtures/observability/dashboards/`. Its
   `uid` is the file name without `.json`, and every `datasource` it names is
   `{"type": "prometheus", "uid": "knarr-prometheus"}`.
2. List the file under the `knarr-dashboards` `configMapGenerator` entry's
   `files` in `fixtures/observability/kustomization.yaml`.
3. Run `just observability-up` again, which reapplies the ConfigMap.

`scripts/checks/tests/test_observability.py` holds every dashboard to this.
It also reads each query's metric names, in rows too. It refuses a
`__name__` matcher, a bare histogram name, and any name that is not a knarr
metric in `docs/specs/observability.allium` and `src/knarr/metrics_ffi.erl`
or in `fixtures/observability/exporters.json`, the inventory of `erlang_vm_`
and kube-state-metrics names captured from the live stack. A panel on a name
nothing exports would otherwise stay empty without failing.

## Bumping a pin by hand

Every pin in `stack.json` moves by hand, and they move together: Renovate has
`enabled: false` on the three images, and no manager reads the file.

1. Pick the chart version, and record its `.tgz` URL and sha256. The sha256
   equals the `digest` in the chart repository's `index.yaml`.
2. Render the chart with its values and list every `image:` line.
3. Look up each image's multi-arch index digest with
   `docker buildx imagetools inspect`, and check it has amd64 and arm64
   entries.
4. Run `just observability-up` and `just observability-smoke`, then recapture
   `exporters.json` from the live Prometheus if an exporter moved.
5. If an image name changes, update the list of disabled packages in
   `.github/renovate.json`.

helm itself is in the default pixi environment, where it also lints and
renders knarr's chart ([Decision 0015](../decisions/0015-helm-chart.md)), and
moves with the "local cluster" Renovate group.

## Teardown

`just observability-down` deletes the labelled Role and RoleBindings in
`default`, then the labelled cluster-scoped objects, then the `observability`
namespace, waiting up to 180 s. The RBAC goes first, so a slow namespace
deletion cannot leave it behind. The chart cache stays under `.cluster/`;
`just cluster-down` removes it with the rest of the cluster state.

## Local only

The stack assumes a disposable, trusted cluster. Grafana lets anonymous users
in as Viewers, and its admin password is the fixed `knarr-local-only`, which
is published here and is not a secret. Any pod in the cluster can reach
Grafana's Service. The port-forward listens on 127.0.0.1 only. Grafana's update
checks, plugin preinstall and news feed are off, and ticket 51's live run
found no outbound fetch in Grafana's log, but egress from the cluster was not
verified as denied.
