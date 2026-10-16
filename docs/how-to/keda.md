---
title: "Pair Knarr with KEDA"
kind: "how-to"
audience: ["user", "operator"]
canonical_for: ["keda_pairing", "scale_from_zero"]
requires: []
---

# Pair Knarr with KEDA

KEDA and its generated HPA decide how many replicas to run. Knarr changes only pod annotations, biasing ReplicaSet victim selection within each ReplicaSet. Prepare the [worker](worker.md), [install the controller](install.md), and apply the [Deployment opt-in](../reference/configuration.md#opt-in) before pairing them. These guides describe implemented behavior beyond the published `v0.1.0` skeleton ([ownership.allium](../specs/ownership.allium), `Ownership` `Objects`; [reconcile.allium](../specs/reconcile.allium), `Loop` `Rollout`).

## Choose a demand signal that exists at zero

At zero replicas there are no worker status endpoints for Knarr to poll. Wake-up therefore needs an external demand source, such as queue depth exported independently of the worker pods. A Knarr cost or pod-count metric cannot supply that demand. KEDA performs activation and deactivation; its HPA handles scaling between one and multiple replicas ([config.allium](../specs/config.allium), `Configuration` `Discovery`; [KEDA scaling concepts](https://keda.sh/docs/2.18/concepts/scaling-deployments/)).

The example assumes KEDA is installed, a Deployment named `worker` in namespace `workers` already serves the contract, and a Prometheus service in that namespace exposes a queue-exporter metric named `queue_messages`. Replace the endpoint, metric, and thresholds with your environment's values. Keep that exporter running when the worker has zero replicas. This is illustrative configuration for the [KEDA Prometheus scaler](https://keda.sh/docs/2.18/scalers/prometheus/), not a service or metric Knarr installs.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker
  namespace: workers
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 20
  pollingInterval: 30
  cooldownPeriod: 300
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300
          policies:
            - type: Pods
              value: 1
              periodSeconds: 60
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus.workers.svc:9090
        query: sum(queue_messages{queue="work"})
        threshold: "10"
        activationThreshold: "0"
        ignoreNullValues: "false"
```

The query must return one scalar or one vector element. Here demand above zero activates the scaler, and a target of ten messages per replica drives HPA scaling. An empty query result is treated as a scaler error rather than silently ignored; arrange for the exporter to report zero for an empty queue. Configure authentication through KEDA if Prometheus requires it ([KEDA Prometheus scaler](https://keda.sh/docs/2.18/scalers/prometheus/)).

## Tune scale-down and test the complete path

The example sets a 300-second scale-down stabilization window and limits HPA scale-down to one pod per 60 seconds. These are starting values, not drain guarantees. Configure them through `spec.advanced.horizontalPodAutoscalerConfig.behavior`, rather than editing the generated HPA. `cooldownPeriod` governs the return to zero; it does not pace ordinary HPA scale-down and is not extended by a busy worker's deletion cost ([KEDA ScaledObject specification](https://keda.sh/docs/2.18/reference/scaledobject-spec/)).

Knarr has its own polling and write budgets; a new cost may not have reached the API or the ReplicaSet cache when scaling happens. Test with mixed idle and busy workers, inspect pod annotations, and verify that shutdown completes when a busy pod is selected. Costs bias selection; they do not prevent scale-down when all candidates are busy ([budget.allium](../specs/budget.allium), `PollSchedule` `Phase`, `Jitter`, `Concurrency`, `WriteBudget` `PerPod`, `Bucket`; [Kubernetes pod deletion cost](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/#pod-deletion-cost)).

In a test namespace, verify activation from zero after adding queue demand, HPA scale-down while replicas remain above zero, and eventual deactivation after demand disappears. Include long-running in-flight jobs after the queue empties: the trigger must represent the demand you want KEDA to preserve, and graceful shutdown must handle a final scale-to-zero. See [worker shutdown](worker.md#drain-on-termination) and [operational checks](../operations/controller.md) for the remaining prerequisites.
