---
title: "Decision 0008: safe-to-evict on upstream Cluster Autoscaler"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_safe_to_evict_upstream_ca]
requires: []
---

# Decision 0008: safe-to-evict on upstream Cluster Autoscaler

## Context

OVERVIEW §6 makes `cluster-autoscaler.kubernetes.io/safe-to-evict` an opt-in, per-workload policy for the MVP, and §9.9 leaves three things open: the threshold, removing the annotation versus writing `"true"`, and how to avoid pinning nodes. Two questions about Cluster Autoscaler (CA) decide them. Does CA re-check `safe-to-evict` just before it evicts? Does a flip reset a node's unneeded timer? The core mechanism, `pod-deletion-cost` with ReplicaSet scale-down, does not involve CA, so this record gates only the opt-in policy.

Ticket 15 answers both on upstream CA `cluster-autoscaler-1.35.2`, the 1.35 release pinned in [Decision 0003](0003-tool-manager.md), running its kwok cloud provider against a kwokctl cluster as [Decision 0007](0007-local-cluster.md) set it up. Each behaviour is observed in a script and explained by CA source at that tag. The flags are shortened (5s scan, 40s unneeded time, 15s recheck timeout) and recorded in every transcript; the [evidence README](../../.scratch/bootstrap/evidence/15/README.md) lists them beside the upstream defaults.

All evidence was gathered on 2026-10-08 (UTC) on an Apple M5 Pro (Darwin arm64), with OrbStack 2.2.3 and its Docker engine 29.4. The scripts and transcripts are in [`.scratch/bootstrap/evidence/15/`](../../.scratch/bootstrap/evidence/15/README.md). This is upstream CA. GKE's is a different build (see "Versions and GKE"), and ticket 16 confirms there.

## Decision

The recommended starting position for §9.9, for ticket 25 to settle with the maintainer:

- **Threshold.** Write `"false"` only for the top cost band or bands, with hysteresis wider than the cost banding, so a pod near a band edge does not flip back and forth. A spell of `"false"` that a scale-down simulation sees takes the node out of scale-down for between max(F, R) and F + R in all, and then the node needs a full unneeded time U again. R is CA's `--unremovable-node-recheck-timeout`. F runs from the first loop that finds the node blocked, not from when the annotation is written, until the annotation is removed. After the removal only the rest of that span is left, at most R. With upstream defaults (R = 5m, U = 10m) the node cannot be removed until at least 15 minutes after that first block, and 10 to 15 minutes after the removal. Only a spell that a loop sees costs this: CA reads the annotation once per loop, and simulates only nodes that are scale-down candidates, so a spell between two loops, or on a node above the utilization threshold, sets no recheck timeout. A flip once eviction has started is ignored (see Pinning).
- **Remove, never write `"true"` by default.** To end protection, delete the annotation. Absent and `"true"` keep the unneeded timer alike, but `"true"` also skips every later drain rule in CA's simulation: the PDB rule, the replicated, system and local-storage rules. A PDB-covered `"true"` pod still gets its node tainted and cordoned and its drain attempted, which only the Eviction API then refuses. For pods with disk-backed `emptyDir`, prefer the user-set `cluster-autoscaler.kubernetes.io/safe-to-evict-local-volumes` naming the volumes over `"true"`. When protecting, write exactly `"false"`: any other value counts as absent.
- **Pinning.** CA does not cordon a node it keeps for a `"false"` pod, so new pods keep landing there. Bound the share of a workload's pods that may be marked at once and how long one mark may be held; expiry and cleanup belong to ticket 23 (ticket 23 settled no expiry by age on 2026-10-13, in the `Restart` `NoExpiry` clause of [lifecycle.allium](../specs/lifecycle.allium); a hold cap stays 25's, and cleanup is its `Cleanup` contract). Treat the mark as best-effort: CA honours it up to its one re-check after the taint delay, and ignores it once eviction has started.

## Findings

Every row was observed on CA 1.35.2. Transcripts are in the evidence directory; `source.txt` asserts each cited excerpt on its line range at the tag, and the link goes to that range.

| Behaviour | Transcript | Source (`source.txt` line, then the cited range) | Verdict |
| --- | --- | --- | --- |
| Exp1: `"false"` on an otherwise removable node blocks it: `cannot be removed: pod annotated as not safe to evict present`, no soft or hard taint in 4 × the unneeded time. Without it the node is removed | [exp1](../../.scratch/bootstrap/evidence/15/exp1-false-blocks.txt) L15 (control), L20-L24 | L43 [notsafetoevict/rule.go#L42-L46](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/simulator/drainability/rules/notsafetoevict/rule.go#L42-L46), L28 [drain.go#L149-L153](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/utils/drain/drain.go#L149-L153) | Confirmed. Exact string `"false"` |
| Exp2 (b): a flip to `"false"` inside the taint delay is caught by one re-check on a fresh pod list. CA aborts (`couldn't delete node … not safe to evict present`), emits `ScaleDownFailed`, and removes the taint and cordon | [exp2](../../.scratch/bootstrap/evidence/15/exp2-recheck.txt) L18 (control), L23-L31 | L71 [actuator.go#L295-L298](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/actuation/actuator.go#L295-L298), L74 [#L333-L339](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/actuation/actuator.go#L333-L339), L76 [delete_in_batch.go#L194-L210](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/actuation/delete_in_batch.go#L194-L210) | Confirmed. One re-check, after the taint delay |
| Exp2 (c): once eviction has started, the annotation is not re-read. A `"true"` pod under a PDB with `maxUnavailable: 0` still gets its node tainted (risky nodes are sorted last, not dropped); the evictions get 429, the pod is flipped to `"false"`, and once the PDB is gone the next retry evicts it | [exp2](../../.scratch/bootstrap/evidence/15/exp2-recheck.txt) L35-L42 | L42 [safetoevict/rule.go#L40-L44](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/simulator/drainability/rules/safetoevict/rule.go#L40-L44), L68 [planner.go#L438-L449](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/planner/planner.go#L438-L449), L79 [actuation/drain.go#L239-L256](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/actuation/drain.go#L239-L256) | Confirmed. `"true"` skips the PDB rule, which makes the node risky |
| Exp3 legs A and B: absent → `"true"` and `"true"` → absent keep the node's `since`; removal comes at the original since + U | [exp3](../../.scratch/bootstrap/evidence/15/exp3-timer.txt) L12-L14, L19-L21 | L49 [unneeded/nodes.go#L132-L150](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/unneeded/nodes.go#L132-L150) | Confirmed. Timer kept |
| Exp3 leg C: a spell of `"false"` drops the node from the unneeded set. It stays out after the annotation is gone, until CA's logged recheck time, and only then starts a new `since`; removal comes U after that | [exp3](../../.scratch/bootstrap/evidence/15/exp3-timer.txt) L26-L41 | L53 [planner.go#L315-L318](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/planner/planner.go#L315-L318), L54 [eligibility.go#L83-L88](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/eligibility/eligibility.go#L83-L88), L58 [unremovable/nodes.go#L62-L65](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/unremovable/nodes.go#L62-L65), L59 [#L109-L112](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/unremovable/nodes.go#L109-L112) | Confirmed. Timer reset, after a blackout of max(F, R) to F + R from the first block |
| Exp4: a disk-backed `emptyDir` with no annotation blocks (`pod with local storage present`); `"true"` or `safe-to-evict-local-volumes` naming the volume unblocks | [exp4](../../.scratch/bootstrap/evidence/15/exp4-local-storage.txt) L12-L13, L18-L19, L24-L25 | L44 [localstorage/rule.go#L42-L46](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/simulator/drainability/rules/localstorage/rule.go#L42-L46), L30 [drain.go#L116-L139](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/utils/drain/drain.go#L116-L139) | Confirmed. Removing the annotation is not enough for such a pod |

### The blackout after a spell of `"false"`

When CA's simulation finds a node blocked, it records the node with a timeout of that loop's time plus R ([planner.go#L315-L318](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/planner/planner.go#L315-L318)) and logs `will re-check them at <time>`. Until then the node is skipped as recently unremovable, whatever its pods now say: `IsRecent` reads only the timeout ([unremovable/nodes.go#L109-L112](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/unremovable/nodes.go#L109-L112)), and skipping it adds no new one ([planner.go#L283-L285](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.35.2/cluster-autoscaler/core/scaledown/planner/planner.go#L283-L285)). At the timeout the node is simulated again. If it is still blocked it gets a fresh timeout, so rechecks fall at about t₀ + k·R, where t₀ is the loop that first logged the block. That is not when the annotation was written: it is the next loop, or a later one if the node was not yet a scale-down candidate. A loop reads the annotation as it is at that moment, so a spell that falls between two loops is never seen and sets no timeout. With F the time from t₀ until the mark is removed, the node returns at the first recheck after that: out of the unneeded set for between max(F, R) and F + R in all, plus up to one scan interval, then a full U. Once the mark is gone, only the wait to that recheck is left, at most R.

Leg C measured the F < R case. The mark was removed as soon as CA logged the block, so CA saw it gone two loops before the recheck time. Both of those loops still logged `ignoring 1 nodes unremovable in the last 15s`, and the node came back on the first loop at the recheck time ([exp3](../../.scratch/bootstrap/evidence/15/exp3-timer.txt) L28-L37). The F ≥ R case follows from the fresh timeout on each blocked recheck; it was not run.

## Versions and GKE

This section is public-source research as of 2026-10-07, not script evidence.

- **GKE does not run upstream CA.** Google states that the "GKE cluster autoscaler is different from Cluster autoscaler of the open source Kubernetes project" and that its parameters "depend on the cluster configuration and are subject to change" ([concepts](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler)). GKE publishes no CA version and documents no way to set CA flags.
- **Matching minor.** Upstream CA versions match Kubernetes minors exactly, per the autoscaler README. GKE's default for new clusters is 1.35 in Regular (1.35.8-gke.1225000) and Stable (1.35.6-gke.1250001), and 1.36 in Rapid (1.36.4-gke.1495000) and Extended (1.36.4-gke.1247000) (release notes for [Regular](https://docs.cloud.google.com/kubernetes-engine/docs/release-notes-regular), [Stable](https://docs.cloud.google.com/kubernetes-engine/docs/release-notes-stable), [Rapid](https://docs.cloud.google.com/kubernetes-engine/docs/release-notes-rapid) and [Extended](https://docs.cloud.google.com/kubernetes-engine/docs/release-notes-extended); [release schedule](https://docs.cloud.google.com/kubernetes-engine/docs/release-schedule)). So 1.35.2 is the upstream minor for Regular and Stable. It is not a known match for what GKE runs.
- **1.36.1.** `source.txt` fetches every cited file again at `cluster-autoscaler-1.36.1`. Each excerpt is still present, only moved (L114-L169). The drain rule order is the same except that `oncompletion` is added after `terminal` (L170-L171). `"on-completion"` (autoscaler PR #9355) first shipped in 1.36.0 and is not in 1.35.2 (L175-L177).
- **GKE's documented differences that touch §9.9.** On control plane 1.22 or later, "Pods with local storage no longer block scaling down" ([concepts](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler)), which would change Exp4's first row on GKE. The balanced profile removes a node after about 10 minutes underutilized ([troubleshooting](https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/cluster-autoscaler-scale-down)), the upstream default U. GKE's recheck timeout is not documented. Its visibility events include `no.scale.down.node.pod.not.safe.to.evict.annotation` ([visibility](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cluster-autoscaler-visibility)).

## Verification

Each script exits non-zero on an unexpected result. The [README](../../.scratch/bootstrap/evidence/15/README.md) gives the command that reruns them all, which ends by checking that the run left no container behind.

**Helpers ([lib_test.txt](../../.scratch/bootstrap/evidence/15/lib_test.txt)).** Sixteen tests cover the pure helpers the verdicts rest on, on log lines copied from a CA 1.35.2 run: `since_of`, `recheck_of`, `timer_verdict` (kept, reset and four unclear cases) and `klog_epoch`. Twenty-eight more drive the API helpers through a stub `kubectl` and show that a refused or Forbidden request is never read as a deleted pod or node, as a missing taint or as an eviction count: `exists`, `wait_gone`, `has_taint`, `refute_taint`, `evictions` and `wait_evictions`.

**Source ([source.txt](../../.scratch/bootstrap/evidence/15/source.txt)).** Every cited file is fetched at the tag with its sha256, and every cited excerpt is found on its cited lines.

**Experiments.** [exp1](../../.scratch/bootstrap/evidence/15/exp1-false-blocks.txt), [exp2](../../.scratch/bootstrap/evidence/15/exp2-recheck.txt), [exp3](../../.scratch/bootstrap/evidence/15/exp3-timer.txt) and [exp4](../../.scratch/bootstrap/evidence/15/exp4-local-storage.txt) each start a fresh CA per leg and fail if CA kept a node for a reason other than the one under test. Times come from CA's own log, on one clock. Leg C, the row the threshold advice rests on, from exp3 L28-L41:

```text
  02:00:53.926574 1 nodes found to be unremovable in simulation, will re-check them at 2026-10-08 02:01:08.925553184 +0000 UTC m=+50.866619714
  flip false -> absent seen by the loop at since0 +25.1 s; CA's recheck time is since0 +35.1 s
  every loop from the flip back to the return:
  02:00:58.951426 Starting main loop
  02:00:58.951804 Scale-down calculation: ignoring 1 nodes unremovable in the last 15s
  02:01:03.964795 Starting main loop
  02:01:03.970936 Scale-down calculation: ignoring 1 nodes unremovable in the last 15s
  02:01:08.988746 Starting main loop
  02:01:08.992838 ng-a-zt6tl is unneeded since 2026-10-08 02:01:08.988715183 +0000 UTC m=+50.929781755 duration 0s
  ng-a-zt6tl unneeded again: since1 02:01:08.989 (since0 +35.1 s, recheck time +0.1 s, +10.0 s after the loop that saw the flip back)
  removal 02:01:49.158: since0 +75.3 s, since1 +40.2 s (unneeded time 40 s)
  removal is +35.3 s later than since0 + 40 s
ok   leg C: timer reset
ok   leg C: the node stayed out after the loops that saw the annotation gone, and came back on the first loop at CA's recheck time (block + 15 s)
```

**Not run here.** GKE (ticket 16). The F ≥ R case of the blackout. Any CA other than 1.35.2: 1.36.1 is compared by source only.

## Consequences

- **The opt-in policy is viable on upstream CA,** with the limits above: the mark holds through simulation and the one post-taint re-check, and not through eviction.
- **Every spell of `"false"` that CA sees has a cost in scale-down,** which the threshold and hysteresis in 25 must price in. A cheap way to spend it is a pod that crosses a band edge often.
- **`"true"` is never a default.** It changes CA's PDB handling, which 25 should state in the clause rather than leave to the reader.
- **Ticket 16 has a test plan.** It is in [15's hand-back notes](../../.scratch/bootstrap/issues/15-spike-s2a-ca-on-kwok.md#follow-ups-for-16).

## What would reopen this

- **GKE behaves differently.** Ticket 16's results amend this record.
- **The CA pin moves.** `source.sh` and the experiments rerun on every CA pin move; a changed excerpt or verdict reopens the matching row.
- **CA changes how blocked nodes are rechecked,** for example by re-simulating a node whose pods changed. The blackout row and the threshold advice would change.
- **`"on-completion"` becomes relevant.** It is deferred ([DEFERRED.md §8](../DEFERRED.md#8-other-future-targets)) and needs CA 1.36.0 or later.

## Related pages

- [Project overview](../OVERVIEW.md), §6 and §9.9
- [Decision 0007: Local cluster and test tiers](0007-local-cluster.md), for the kwok tier and CA's kwok provider
- [Decision 0003: Tool manager](0003-tool-manager.md), for the CA pin
- [Evidence for this record](../../.scratch/bootstrap/evidence/15/README.md)
- [Ticket 15](../../.scratch/bootstrap/issues/15-spike-s2a-ca-on-kwok.md), with the follow-ups for 16 and 25
- [Deferred items](../DEFERRED.md), §8
