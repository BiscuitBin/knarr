---
title: "Prepare a worker for Knarr"
kind: "how-to"
audience: ["user", "operator"]
canonical_for: ["worker_integration", "worker_shutdown", "worker_readiness"]
requires: []
---

# Prepare a worker for Knarr

Knarr biases which pod a ReplicaSet removes during scale-down. Workers still need to finish work safely when selected. This guide describes the implemented controller; the published `v0.1.0` image is the walking skeleton, as the [install guide](install.md) explains. Scaling remains the autoscaler's job ([ownership.allium](../specs/ownership.allium), `Ownership` `Objects`; [reconcile.allium](../specs/reconcile.allium), `Loop` `Terminating`).

## Serve the status endpoint

Serve an unauthenticated, read-only HTTP GET on the pod IP at port 8080, path `/knarr/v1/status`, by default. Bind to an address reachable through the pod IP, rather than loopback alone. Knarr reaches each pod directly; it does not discover container ports or use a worker Service. Every target with a pod IP is polled regardless of readiness or phase ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `Pull`, `Discovery`, `Unauthenticated`).

Return status 200 with a JSON object like this. `cost` must be a non-negative JSON integer without a fraction or exponent; `accepting` must be a JSON boolean. Extra members are ignored, Content-Type does not affect decoding, and the default body limit is 4096 bytes. Redirects are never followed ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `ValidReading`, `InvalidReading`, config):

```json
{"cost": 1200, "accepting": true}
```

Report the elapsed seconds of the longest-running active task as `cost`, or 0 when idle; another non-negative cost measure is allowed, but the default thresholds assume seconds. `accepting: false` means the worker has started draining. A busy draining worker keeps its positive cost; a draining worker below the first threshold maps to deletion cost `-1`. The status value is not a replica-count recommendation ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `Payload`; [cost_mapping.allium](../specs/cost_mapping.allium), `CostMapping` `Drained`, `Tiers`).

Keep the endpoint serving throughout the pod's life, including while draining after SIGTERM, and answer within the default five-second poll timeout. See the [configuration reference](../reference/configuration.md) for port and path overrides, and [operations](../operations/controller.md#allow-status-traffic) for restricted networks ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `Served`, `Transport`, `NetworkPolicy`).

## Drain on termination

On SIGTERM, stop accepting new work, report `accepting: false`, finish in-flight work, and exit. Knarr stops patching once the pod is known to be terminating, so this shutdown path must work independently of annotations ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `Payload`, `Served`; [reconcile.allium](../specs/reconcile.allium), `Loop` `Terminating`).

Use an exec-form image entrypoint, for example `ENTRYPOINT ["/app/worker"]`. A shell wrapper should end with `exec /app/worker` so the worker receives the termination signal. Set the pod's `terminationGracePeriodSeconds` to cover the longest job, drain overhead, and any `preStop` hook: the grace-period clock starts before that hook runs. These are worker responsibilities described by [Kubernetes pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination).

For a Service-routed HTTP worker, a short `preStop` sleep can allow endpoint-removal changes to propagate before SIGTERM. For example, on Kubernetes 1.34 or later, merge this fragment into the worker pod spec and choose the duration for your own workload. A sleep delays shutdown and consumes the same grace budget; it does not finish work itself ([Kubernetes lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)):

```yaml
spec:
  terminationGracePeriodSeconds: 660
  containers:
    - name: worker
      lifecycle:
        preStop:
          sleep:
            seconds: 10
```

Long grace periods also hold capacity during scale-down. Upstream Cluster Autoscaler normally waits at most 600 seconds when removing a node, configurable through `--max-graceful-termination-sec`; managed providers may expose different controls. A longer pod grace period alone cannot extend that node-removal deadline. Check the actual provider policy and make long jobs resumable or retryable ([Cluster Autoscaler graceful termination](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md#does-ca-respect-gracefultermination-in-scale-down)).

## Keep readiness meaningful

ReplicaSet victim selection prefers a NotReady pod before comparing deletion costs. Queue consumers should therefore report busy and draining through the status payload, keeping readiness independent of work occupancy. For Service-routed HTTP workers, stay Ready while draining if another mechanism can shed traffic; otherwise go NotReady as late as the drain allows. This is a trade-off, not a promise that a busy pod survives ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` guidance).

Knarr exposes `knarr_pods_not_ready_with_cost` and logs entry into that state when a NotReady pod has a known reading whose applied deletion cost is positive. There is no corresponding Event. The warning helps find workers whose readiness defeats the intended scale-down bias ([worker_contract.allium](../specs/worker_contract.allium), `StatusEndpoint` `ReadinessWarning`; [reconcile.allium](../specs/reconcile.allium), `Fallback` `NotReadyWithCost`).
