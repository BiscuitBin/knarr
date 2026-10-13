# 34: User-facing guides for workers, KEDA pairing and operation

**Context:** OVERVIEW carries guidance that is for the people who run workers and clusters, not controller behaviour: workers own graceful shutdown (§5), the readiness trade-off (§5, §9.7), pairing knarr with a KEDA ScaledObject including scale-from-zero and `behavior` tuning (§7), rollouts with `maxUnavailable` and `maxSurge` (§9.13), the `PodDeletionCost` prerequisite (§6, §9.11), NetworkPolicy configuration (§5, §9.4b), and uninstall with manual recovery (§8). Ticket 12 leaves user-facing install and KEDA pairing guides to round 2. [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md) maps each item to a module and assigns the pages here.

**What to build:** Handbook pages for that guidance, each written once the owning elicitation ticket has settled the behaviour it describes, registered in `docs/manifest.yml` and reachable from `docs/README.md` as the documentation contract requires.

**Non-goals:** Controller behaviour. The API reference.

**Blocked by:** 12, 18, 23, 24, 25, 28

**From 17:** [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md), map rows marked guidance.

**From 24:** the `PodDeletionCost` prerequisite page content, row 14 of [ticket 24](24-elicit-poll-budget-feature-gate.md#settled): the gate is beta and on by default since Kubernetes 1.22, and is needed on both kube-apiserver and kube-controller-manager; GKE enables beta gates by default, may disable one per version, and allows gate changes only on alpha clusters; knarr makes no check. The verification is `kubectl get --raw /metrics | grep 'kubernetes_feature_enabled{name="PodDeletionCost"'` on 1.26 or later, which proves only the apiserver's gate. The behavioural test uses two Ready pods of one Deployment on the same node (or on nodes with equal counts of its pods): annotate the older with `controller.kubernetes.io/pod-deletion-cost: "-1"` and scale down by one; with the gate on the older goes, and with it off the newer goes, since ranking then prefers the pod that became Ready more recently. With the gate off knarr's writes are harmless and useless, and `safe-to-evict` and Karpenter are unaffected. The page cites the kubernetes.io feature-gates reference, the ReplicaSet page's pod-deletion-cost section, KEP-2255 and the GKE feature-gates page.

**From 28:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md): a release is installed with `kubectl apply -k` on the digest-pinned overlay 36 adds, one install per namespace, with the digest from the release run's summary (40's hand-back records the MVP's).

**From 30:** the user guides may want a metrics and alerting page from [observability.allium](../../../docs/specs/observability.allium): the metric catalogue in `Catalogue`; an alert on `knarr_last_discovery_timestamp_seconds` going stale, since liveness never restarts on a stalled loop (`Probes` `Liveness`) and `/readyz` latches after the first discovery cycle (`Probes` `Readiness`); the four Event reasons, `AnnotationYielded`, `ContractAbsent`, `PatchRejected` and `CleanupRejected`, and their messages (`Events`), including the `kubectl annotate pod <pod> <key>-` a `CleanupRejected` message names; and the JSON log fields (`Logs` `Format`) with the `log_level` setting, info by default (`Levels`).

**MVP critical path:** no. The MVP runs without them; users need them to adopt it.

**Status:** ready-for-agent, round 2

- [ ] A worker guide covers graceful shutdown (SIGTERM, exec-form entrypoint, `terminationGracePeriodSeconds`, `preStop` sleep, Cluster Autoscaler's termination cap) and the readiness trade-off as 18 settled it (§5, §9.7).
- [ ] A KEDA pairing guide covers scale-from-zero and `behavior` tuning (§7).
- [ ] An operations guide covers rollouts (§9.13), the `PodDeletionCost` prerequisite as 24 settled it (§9.11), NetworkPolicy configuration as 18 settled it (§9.4b), and uninstall with manual recovery as 23 settled it (§8).
- [ ] An install guide covers installing a published release from the digest-pinned release overlay as [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) decides: the digest from the release run's summary, one install per namespace, the `PodDeletionCost` prerequisite, and how an upgrade is a new digest. Written once 36 has landed the overlay.
- [ ] Every page passes `just docs-check`, and each paragraph that states behaviour names the clause it describes.
