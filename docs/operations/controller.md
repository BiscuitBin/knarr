---
title: "Operate and remove Knarr"
kind: "operations"
audience: ["operator", "user"]
canonical_for: ["controller_operations", "pod_deletion_cost_prerequisite", "worker_network_policy", "controller_observability", "controller_uninstall"]
requires: []
---

# Operate and remove Knarr

This guide describes the implemented controller; the published `v0.1.0` skeleton does not contain these features. Start with [installation](../how-to/install.md), [worker preparation](../how-to/worker.md), and [configuration](../reference/configuration.md). Knarr writes annotations on live pods, leaves replica counts to the scaler, and never patches a pod once its view shows `deletionTimestamp` ([ownership.allium](../specs/ownership.allium), `Ownership` `Objects`; [reconcile.allium](../specs/reconcile.allium), `Loop` `Terminating`).

## Verify PodDeletionCost

Knarr makes no feature-gate check at startup or periodically. `PodDeletionCost` must be enabled on both kube-apiserver and kube-controller-manager. It is beta and enabled by default since Kubernetes 1.22; if disabled, Knarr's deletion-cost writes are harmless but provide no victim-selection bias. This gate does not affect Cluster Autoscaler safe-to-evict or Karpenter ([budget.allium](../specs/budget.allium), `WriteBudget` `NoGateCheck` and guidance; [Kubernetes feature gates](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/), [ReplicaSet deletion cost](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/#pod-deletion-cost), [KEP-2255](https://github.com/kubernetes/enhancements/tree/master/keps/sig-apps/2255-pod-cost)).

On Kubernetes 1.26 or later, with permission to read the apiserver's metrics, inspect the following. A value of 1 proves the apiserver gate only; it does not establish the controller-manager's state. Do not expand Knarr's Role for this operator check. GKE normally enables beta features, but can disable one in a particular version; feature-gate changes are available only on alpha clusters ([budget.allium](../specs/budget.allium), `WriteBudget` guidance; [GKE feature gates](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/feature-gates)):

```sh
kubectl get --raw /metrics | grep 'kubernetes_feature_enabled{name="PodDeletionCost"'
```

For a behavioral check, use a disposable Deployment that is not opted into Knarr and has no other scaler or annotation writer. Bring up one Ready pod, wait, then scale it to two so the older pod also became Ready earlier. Keep both Running and Ready, with equal restart counts, on the same node, or on nodes with equal counts of related pods. These controls keep earlier ranking steps and later tie-breakers from obscuring the cost comparison ([budget.allium](../specs/budget.allium), `WriteBudget` guidance; [KEP-2255](https://github.com/kubernetes/enhancements/tree/master/keps/sig-apps/2255-pod-cost)).

In that test namespace, annotate the older pod with `-1` and scale down by one. Substitute the actual names below. With the gate enabled, the older pod should be removed; with it disabled, the more recently Ready pod should be removed. Repeat under controlled conditions if the outcome is unclear: ordering is best-effort ([budget.allium](../specs/budget.allium), `WriteBudget` guidance; [ReplicaSet deletion cost](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/#pod-deletion-cost)):

```sh
kubectl -n workers annotate pod older-probe-pod \
  controller.kubernetes.io/pod-deletion-cost=-1 --overwrite
kubectl -n workers scale deployment/cost-probe --replicas=1
kubectl -n workers get pods -w
```

## Allow status traffic

The status endpoint is plain HTTP, unauthenticated, read-only, and reached directly at each pod IP. In an ingress-restricted worker namespace, allow TCP to the effective status port from pods labelled `app.kubernetes.io/name: knarr` in that same namespace. This example assumes worker pods carry `app: worker` and use port 8080; adapt the selector and port to the worker. A pod selector without a namespace selector selects sources within the policy's namespace ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `Pull`, `Unauthenticated`, `NetworkPolicy`; [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: worker-status-from-knarr
  namespace: workers
spec:
  podSelector:
    matchLabels:
      app: worker
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: knarr
      ports:
        - protocol: TCP
          port: 8080
```

Applying this policy makes selected workers ingress-isolated if they were not already. Preserve separate rules for application traffic and existing clients. If Knarr's own egress is restricted, also permit its worker-status traffic and apiserver access in that egress policy; this ingress example alone cannot grant egress ([Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)).

A policy drop typically appears as `timed_out`, not a refused connection. Knarr cannot diagnose the policy itself and raises no policy-block Event. Inspect `knarr_polls_total{reading="timed_out"}` and the network configuration; repeated timeouts follow the unknown window below, not the contract-absent rule ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `NetworkPolicy`; [reconcile.allium](../specs/reconcile.allium), `Fallback` `Window`, `Absent`).

## Understand missing readings and restarts

The install-wide `unknown_polls` defaults to 3 and accepts 1–100. Until that many consecutive readings are not valid, the last applied value stands. At the threshold, the desired state becomes removal of every Knarr-owned annotation, including a drained deletion cost of `-1`; the marker stays. Removal follows the write budget and can fail, so reaching the window does not prove cleanup reached the API. Skipped polls do not count as readings, and the window stretches with effective polling cadence ([reconcile.allium](../specs/reconcile.allium), `Fallback` `Readings`, `Window`, `Neutral`; [budget.allium](../specs/budget.allium), `WriteBudget` `PerPod`, `Bucket`).

The separate install-wide `absent_after` defaults to 300 seconds and accepts 30–3600. An uninterrupted run of 404 or connection-refused readings enters contract-absent at the first such reading at least that long after the run began. A timeout, invalid payload, or other reading breaks the run before entry. Entry attempts one `ContractAbsent` Event on the Deployment, naming the effective port and path, and requests neutral removal. Polling continues; the next valid reading resumes management. Once absent, only a valid reading leaves that state ([reconcile.allium](../specs/reconcile.allium), `Fallback` `Absent`, `Neutral`; [observability.allium](../specs/observability.allium), `Events` `ContractAbsent`).

`knarr_pods_unknown` counts unknown pods and `knarr_pods_contract_absent` counts absent pods; these gauges are disjoint and rebuilt at discovery cycles, rather than immediately on each reading. Neither window has a Deployment override. A restarting controller resets both windows, performs no special startup cleanup, and reconciles marked pods through its normal loop. Annotation values do not expire by age, and marker `at` timestamps are informational; a found value can remain until the window elapses again or a valid reading corrects it ([reconcile.allium](../specs/reconcile.allium), `Fallback` `Gauges`, `Restart`; [config.allium](../specs/config.allium), `Configuration` `Keys`; [lifecycle.allium](../specs/lifecycle.allium), `Restart` `NoExpiry`, `Informational`, `NoStartupStep`).

## Plan worker rollouts

Knarr follows both old and new ReplicaSets during a Deployment rollout, but deletion cost ranks pods only within one ReplicaSet. It cannot preserve an old ReplicaSet against the Deployment's decision to retire it. Choose `maxUnavailable` and `maxSurge` for worker capacity and drain duration; for example, `maxUnavailable: 0` and `maxSurge: 1` keep available capacity while allowing one surge pod, but do not guarantee that a busy old pod survives. Every old worker still needs graceful shutdown ([config.allium](../specs/config.allium), `Configuration` `Discovery`; [reconcile.allium](../specs/reconcile.allium), `Loop` `Rollout`; [Kubernetes rolling updates](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment)).

## Observe the controller

Forward the controller's diagnostics port to inspect `/metrics`, `/healthz`, and `/readyz`. Liveness checks the process, not discovery progress; readiness latches after the first completely successful discovery cycle. Either may remain healthy while discovery has stalled ([knarr.allium](../specs/knarr.allium), `Diagnostics` `Health`, `Readiness`, `Metrics`; [observability.allium](../specs/observability.allium), `Probes` `Liveness`, `Readiness`):

```sh
kubectl -n workers port-forward deployment/knarr 18080:8080
```

Scrape the metrics endpoint with your monitoring system and alert on discovery age independently of probes. For the default 60-second cadence, `time() - knarr_last_discovery_timestamp_seconds > 180` sustained for two minutes is an illustrative stale-discovery alert. Add a separate scrape-target-down or absent-metric alert, since missing series cannot satisfy that expression. Adjust timing if discovery cadence changes, and attach namespace/cluster identity through scrape labels; Knarr metrics have no namespace or pod label ([observability.allium](../specs/observability.allium), `Catalogue` `Install`, `Labels`, `Probes` `Liveness`).

The controller metric catalogue below groups the signals by task. Per-Deployment series are retired after that Deployment leaves management and its pending work and cleanup finish; counters are in memory and reset on restart. Histogram bucket boundaries are fixed, not derived from configuration ([observability.allium](../specs/observability.allium), `Catalogue` `SeriesLife`, `Buckets`, `Naming`):

| Task | Metrics | Catalogue clauses |
| --- | --- | --- |
| Poll health | `knarr_polls_total{deployment,reading}`, `knarr_poll_duration_seconds`, `knarr_polls_skipped_total{deployment}`, `knarr_poll_queue_depth` | `Polls` |
| Applied cost tiers | `knarr_pods{deployment,tier}`; tier is `drained` or the number of thresholds at or below the applied value, not the annotation value | `Tiers` |
| Writes and rejections | `knarr_patches_total{deployment,purpose,result}`, `knarr_patch_rejections_total{deployment,purpose}` | `Patches` |
| API pressure | `knarr_lists_total{resource,result}`, `knarr_paused{scope}`, `knarr_pause_seconds{scope}`, `knarr_patches_pending{deployment}`, `knarr_patch_pending_oldest_seconds` | `Budget` |
| Ownership and worker state | `knarr_annotations{deployment,annotation,standing}`, `knarr_yields_total{deployment,annotation}`, `knarr_pods_not_ready_with_cost{deployment}`, `knarr_pods_unknown{deployment}`, `knarr_pods_contract_absent{deployment}` | `Standing` |
| Install health | `knarr_last_discovery_timestamp_seconds`, `knarr_discovery_duration_seconds`, `knarr_events_total{reason,result}`, `knarr_targets{kind}`, `knarr_build_info{version}`, `knarr_startups_total` | `Install`, `Naming` |

Events are Warning Events with reporting component `knarr`. Use their messages and pod/deployment identities to investigate; an Event create is attempted once, not retried. All Event causes are also logged ([observability.allium](../specs/observability.allium), `Events` `Conventions`, `AlsoLogged`):

| Reason | Meaning and action | Events clause |
| --- | --- | --- |
| `AnnotationYielded` | Another writer changed an owned value; Knarr yields that annotation for the pod's life. Inspect the applied and found values before releasing ownership. | `Yielded`; [ownership](../specs/ownership.allium), `Ownership` `Yield`, `Event` |
| `InvalidOverride` | A Deployment key used its fallback; correct the named value. | `InvalidOverride` |
| `ContractAbsent` | Repeated 404/refused readings reached the absent window; verify the named port and path. | `ContractAbsent` |
| `PatchRejected` | The API rejected an apply or yield patch; previous annotations remain. Inspect status, keys, and authorization. | `Rejected` |
| `CleanupRejected` | Cleanup was rejected; use the message's per-key removal command when supplied, preserving other writers' values. | `CleanupRejected` |

Logs are one JSON object per stdout line with `time` (RFC 3339 UTC with milliseconds), `level`, and `msg`, followed by applicable flat fields such as `deployment`, `pod`, `annotation`, `reading`, `purpose`, `status`, and `reason`. Install-wide OTP `log_level` defaults to `info`; debug adds individual polls and patches. A field appears only when applicable, and logs provide pod identities that metrics omit ([observability.allium](../specs/observability.allium), `Logs` `Format`, `Levels`):

```sh
kubectl -n workers logs deployment/knarr --follow
kubectl -n workers get events --field-selector type=Warning
```

## Uninstall and recover

Keep Knarr running while removing the exact opt-in label from every managed Deployment. Cleanup begins from the next discovery cycle, on live pods, oldest-due first within the write budget; it is not an immediate synchronous operation. The following commands use namespace `workers`, matching the examples above ([config.allium](../specs/config.allium), `Configuration` `OptIn`, `Effective`; [lifecycle.allium](../specs/lifecycle.allium), `Cleanup` `Scope`, `Order`, `Uninstall` `Procedure`):

```sh
kubectl -n workers label deployment -l knarr.io/enabled=true knarr.io/enabled-
```

Wait until the install's `knarr_annotations{standing="owned"}` series are all 0 or absent. Series disappear after a Deployment's cleanup finishes. Check the actual install's fresh metrics, rather than treating a stopped scrape or dead controller as successful cleanup. Then list remaining markers: yield, conflict, edited markers, and marker-only pending cleanup can leave one even after the owned count is zero ([lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`; [observability.allium](../specs/observability.allium), `Catalogue` `Standing`, `SeriesLife`):

```sh
kubectl -n workers get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.knarr\.io/applied}{"\n"}{end}'
```

Inspect each marked pod and release its marker together with the owned keys. This includes the safe-to-evict key for recovery of existing annotations, not as an available feature to enable. The full release command also removes another writer's value if one is present: where another writer is known, or a `CleanupRejected` message identifies values to preserve, remove only Knarr's keys one at a time as the message renders them. A marker-only rejection message supplies no removal command; do not erase records for values that still need ownership tracking ([lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`, `Recovery`; [observability.allium](../specs/observability.allium), `Events` `CleanupRejected`):

```sh
kubectl -n workers annotate pod worker-pod \
  knarr.io/applied- \
  controller.kubernetes.io/pod-deletion-cost- \
  cluster-autoscaler.kubernetes.io/safe-to-evict-
```

Once cleanup and marker inspection are complete, delete the install from the operator checkout used for installation. Deleting Knarr before that wait leaves every owned annotation as a leftover. Manual recovery after a dead install uses the same inspected per-pod release command above, with the same warning about other writers ([lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Procedure`, `Recovery`):

```sh
kubectl -n workers delete -k deploy/release
```

A pod carrying a value without a marker is foreign, and the uninstall procedure leaves it alone. If someone removed the marker by hand, inspect both keys using the following inventory and remove only confirmed Knarr leftovers, one key at a time. Removing just the marker does not release annotations: a running Knarr treats those values as foreign for that pod's life ([ownership.allium](../specs/ownership.allium), `Ownership` `Adoption`; [lifecycle.allium](../specs/lifecycle.allium), `Uninstall` `Recovery`):

```sh
kubectl -n workers get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}{"\t"}{.metadata.annotations.cluster-autoscaler\.kubernetes\.io/safe-to-evict}{"\n"}{end}'
kubectl -n workers annotate pod worker-pod controller.kubernetes.io/pod-deletion-cost-
```
