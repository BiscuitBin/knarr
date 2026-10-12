---
title: "Knarr: Deferred Options and Research"
kind: "project"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["deferred_options"]
requires: []
---

# Knarr: Deferred Options and Research

> **Status:** Not in the MVP. This file holds options, alternatives and research notes that were cut from [OVERVIEW.md](OVERVIEW.md) when it was scoped to the MVP. Most of the text is moved verbatim. Section and item references such as §7 or §9.3 point to OVERVIEW.md; "old §…" names where moved text came from in the pre-MVP version of OVERVIEW.md (commit 284dca7).

## 1. Scaling option (b): quick follow

The MVP uses option (a), annotations only (OVERVIEW §7). Option (b) is the planned quick follow. The option table below is from old §7.

### Scaling ownership options

Who sets the replica count? The primary mechanism works under every option, because HPA, KEDA, `kubectl scale` and Knarr all end up at the ReplicaSet's victim ranking. The options differ in **when Knarr can know a scale-down is coming**, and so in how much API write load it generates.

| | (a) Annotations only | (b) Feed KEDA; KEDA owns replicas | (c) Knarr owns replicas |
| --- | --- | --- | --- |
| Who sets replicas | HPA / KEDA | KEDA (HPA), using Knarr's metric | Knarr (`/scale` subresource) |
| Knarr adds | Cost annotations | Annotations plus a per-workload aggregate (for example busy count or headroom) | Annotations plus scaling logic |
| "Annotate before scale-down" (KEP pattern) | **Not possible.** Costs must stay fresh all the time, so threshold crossings and the write budget are essential. | Partly. Knarr can refresh costs when its own metric implies scale-in, but HPA still controls timing. | **Yes.** Annotate, then scale (Windmill's pattern). Fewest writes. |
| Fixes "backlog hides in-flight work" | No | Can, with a suitable aggregate metric and scaling policy. The MVP `cost` is an arbitrary estimate, not an in-flight count, so the aggregation is an open question (below) | Can, with the same caveat |
| Complexity | Lowest. Works with any scaler. | Moderate. Transport choices: **(b1)** KEDA Metrics API (HTTP/JSON); **(b2)** External Scaler (gRPC; no native Gleam library found, so likely Erlang FFI such as `grpcbox`); **(b3)** Prometheus gauges | High. Reimplements stabilization, rate policies, scale-to-zero and fallback. Must never run alongside an HPA or ScaledObject on the same Deployment. |
| Config surface | Labels or annotations may be enough | Needs per-workload settings; leans toward a CRD | Needs per-workload settings; leans toward a CRD |

Earlier recommendation (old §7): design the internal per-workload aggregate so that **(b1)** is a cheap next step. Defer (b2) until the dependency stance is settled. Treat (c) as out of scope unless (a) and (b) prove inadequate.

### Open question (from old §9.3)

If (b) or (c) is chosen, define the aggregate signal built from the two-field contract, how it behaves with unknown data, and how it interacts with KEDA activation, which can scale to zero independently of the scaling metric. (b2) depends on the client choice (§3 below).

### Spike note: Little's Law autotuning (to be validated later)

- Workers expose **Prometheus-style counters** for task count and task latency.
- From these, Knarr derives the total and per-pod arrival rate (λ) and the mean time in system (W), then estimates concurrency with **Little's Law: L = λW**.
- From that, Knarr estimates per-pod capacity and the number of concurrent tasks across the fleet, and scales on that signal (fed to KEDA under (b)).
- Explore **AIMD** (additive increase, multiplicative decrease) to search for the equilibrium replica count or per-pod concurrency target.
- None of this is validated. It needs a spike before it becomes a design.

References: [KEDA: External scalers](https://keda.sh/docs/2.20/concepts/external-scalers/) (the (b2) transport).

## 2. Scaling option (c): Knarr owns replicas

Knarr sets replicas itself through the `/scale` subresource: annotate, then scale (Windmill's pattern). This gives the fewest writes and allows the KEP's "annotate before scale-down" pattern. It reimplements stabilization, rate policies, scale-to-zero and fallback, and it must never run alongside an HPA or ScaledObject on the same Deployment. At zero replicas Knarr would need its own demand source to wake up.

Extra RBAC under (c) (from old §8):

- `apps` `deployments/scale`: get, patch/update

Prior art: [Windmill pod-deletion-cost on scale-in](https://www.windmill.dev/changelog/k8s-scale-in-pod-deletion-cost).

## 3. Kubernetes client alternatives

The MVP uses option (A): pure Gleam plus a thin Erlang FFI over `httpc`/`ssl`/`public_key` and a hand-written, minimal typed layer (OVERVIEW §8, §9.2). Revisit these if (A) gets too complex.

- **(B)** Wrap the Elixir `k8s` library through untyped externals, which needs the Elixir toolchain and runtime.
- **(C)** Existing Erlang clients, which are stale or immature.

**Spike S3 (only if option (B) becomes live):** check whether `gleam export erlang-shipment` bundles Elixir's runtime apps, and whether the OTP apps of Elixir dependencies start.

## 4. HA and leader election

The MVP runs a single replica with no leader election (OVERVIEW §8). Notes for a later HA model:

- **Leader election:** under option (A), a Lease-based elector would likely be hand-written, since no Gleam leader-election library was found. This interacts with ownership detection. If Knarr spots third-party writers by comparing against "the value Knarr last wrote", that record must belong to Knarr as one logical writer (stored in a marker annotation, not per replica). Otherwise two replicas will treat each other as foreign writers and the values will flap. A shared identity alone does not stop two replicas from applying stale decisions. That needs leader election or conditional writes (§9.10).
- **Failure mode (from old §8):**

  | Scenario | Knarr behavior (proposed) | Effect on scale-down | Ticket |
  | --- | --- | --- | --- |
  | Two replicas running (split-brain) | Must share one logical writer identity | Extra load; values may flap if not | §9.19, §9.10 |

- **Extra RBAC:** `coordination.k8s.io` `leases`: get, create, update.
- **Open question (old §9.19), HA model.** Options: (i) a single replica (chosen for the MVP); (ii) Lease-based leader election. Depends on §9.10.

## 5. Install scope and configuration alternatives

The MVP is a controller configured through labels and annotations on Deployments, installed into one namespace with a Role (OVERVIEW §9.1, §9.18). Alternatives, from old §9.1 and §9.18:

- **Configuration surface:** a CRD, which in practice makes Knarr an operator; or a ConfigMap or flags.
- **Install scope:** cluster-wide with a namespace selector (ClusterRole); or a list of watched namespaces. Scope drives RBAC, packaging and the poll budget.

## 6. Watch-based discovery

The MVP discovers pods with a periodic LIST (OVERVIEW §4). A watch is a later optimization. With a hand-written client, streaming and 410-Gone handling are the hardest part. Adopting it adds `watch` to the pods, Deployments and ReplicaSets RBAC rules.

## 7. Karpenter

Karpenter is not an MVP target.

- `karpenter.sh/do-not-disrupt` is a possible future addition. `safe-to-evict` does not affect Karpenter.
- Karpenter already reads `pod-deletion-cost` when scoring consolidation, so Knarr's values can affect Karpenter clusters indirectly.
- kubernetes-sigs/karpenter #2894 (merged 2026-10-01; the first release containing it is unverified) adds a `PodDeletionCostManagement` gate. With the gate off (the default), Karpenter reads its new `karpenter.sh/disruption-cost` and falls back to `pod-deletion-cost`. With the gate on, Karpenter **writes** `pod-deletion-cost` itself, which would conflict with Knarr (§9.10).

References:

- [Karpenter: Disruption](https://karpenter.sh/docs/concepts/disruption/), [kubernetes-sigs/karpenter #2894](https://github.com/kubernetes-sigs/karpenter/pull/2894)

## 8. Other future targets

- **Busy-label PDBs:** an opt-in PDB driven by a busy label. This would add Path B protection beyond `safe-to-evict`.
- **Other workload kinds:** StatefulSets, Jobs and DaemonSets ignore `pod-deletion-cost`, so supporting them needs a different mechanism.
- **CA `"on-completion"`:** recent CA adds `"on-completion"` as a `safe-to-evict` value (autoscaler PR #9355, merged 2026-04; first in cluster-autoscaler 1.36.0, not in 1.35.2, per ticket 15's [`source.txt`](../.scratch/bootstrap/evidence/15/source.txt)). That value suits pods that finish on their own, not long-lived Deployment workers.
- **Service meshes and mTLS:** Knarr polls over plain HTTP and presents no client certificate. Pods in a mesh that enforces mTLS (Istio `PeerAuthentication` in `STRICT` mode, Linkerd) reject or drop that traffic, and the failure looks like an absent contract (the [OVERVIEW §8 failure modes](OVERVIEW.md#failure-modes-proposed-v1-defaults-all-to-be-confirmed-in-tickets) table). Support would need Knarr to join the mesh, through a sidecar or ambient mode, or to speak mTLS itself. Deferred because the first target clusters run no in-cluster mTLS.
- **GKE Autopilot:** for Autopilot-mode workloads, `"false"` enables [extended-duration Pods](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/extended-duration-pods). These are protected from scale-down and auto-upgrade eviction for up to 7 days, with placement and limit rules of their own (see the link). The effect of changing the annotation at runtime there is undocumented, so GKE Autopilot is unverified.
- **Helm chart:** [Decision 0012](decisions/0012-release-and-packaging.md) packages knarr with kustomize only: `deploy/base` for the kind loop and a release overlay that pins the published image by digest. A chart would add a second packaging to keep in step with the base, for one consumer in one namespace with nothing to template. Reopen when a second consumer needs values; `kubernetes-helm` stays pinned in the cluster environment, unused.
- **arm64 image:** the lock covers `linux-64` and `osx-arm64` only, so a `linux/arm64` build fails at `pixi install --locked` (ticket 28's [`arm64-probe.txt`](../.scratch/bootstrap/evidence/28/arm64-probe.txt)). Arm64 needs `linux-aarch64` in `pixi.toml` and a re-lock (ticket 27's domain), one more build job on an `ubuntu-24.04-arm` runner, and an `imagetools create` that merges the two manifests into one index. No target node pool is arm64, and the native arm64 BEAM runtime is unverified (ticket 13). Ticket 38 picks it up.
- **cosign signing, SBOM and build provenance:** the first release pushes one plain manifest with `--provenance=false --sbom=false`, so the digest every install pins is the image manifest's ([Decision 0012](decisions/0012-release-and-packaging.md)). Ticket 38 adds GitHub artifact attestations (`actions/attest-build-provenance`, verified with `gh attestation verify oci://…`) and turns BuildKit's SBOM and provenance on, after which the overlay pins the index digest. cosign keyless signing is deferred until a consumer asks for a Sigstore signature; the attestations carry the same provenance claim.

## 9. Background notes

**Victim-ranking tie-break.** In `ActivePodsWithRanks.Less` (OVERVIEW §6), steps 6 and 8 compare ages in logarithmic buckets, not exact timestamps, and break ties by pod UID. A UID tie-break can therefore decide the order before restart count does. Knarr only controls step 4, so this detail does not change its design.
