# 25: Elicit: `safe-to-evict` policy (§9.9)

**Context:** OVERVIEW §6 makes `cluster-autoscaler.kubernetes.io/safe-to-evict` opt-in per workload in the MVP. §9.9 leaves open:

- the threshold
- removing the annotation versus writing `"true"`, which matters for pods with emptyDir or hostPath storage
- how to avoid pinning nodes

S2a (15) supplies the upstream CA evidence. S2b (16) may amend the clauses once GKE access exists.

Ticket 22 settled in [ownership.allium](../../../docs/specs/ownership.allium) that `safe-to-evict` is the second owned annotation under its `Adoption`, `Applied` and `Yield` clauses: `standing` is defined for it whatever the Deployment enables, and reconcile asks it on a Deployment that has not opted in only while the marker holds a record for it, so the value an opt-out leaves behind falls to cleanup (23); the opt-in key is config's (19) and what the gate does is this ticket's; its last-applied value is the marker's applied record; and its yield is independent of `pod-deletion-cost`'s.

**What to build:** Allium clauses for when knarr sets, flips and removes `safe-to-evict`, settled with the maintainer, grounded in S2a's findings.

**Non-goals:** Expiry and cleanup of the annotation (23). GKE confirmation (16).

**Blocked by:** 15, 17

**From 15:** [Decision 0008](../../../docs/decisions/0008-safe-to-evict-on-upstream-ca.md) records S2a's findings and a recommended starting position for §9.9. [15's hand-back notes](15-spike-s2a-ca-on-kwok.md#follow-ups-for-25) list the open points this ticket settles, each with the evidence it cites.

**From 19:** the opt-in key is the annotation `knarr.io/safe-to-evict` on the Deployment with the value `"true"` exactly, off when absent, any other value an invalid key under config's `InvalidValue`, carried as `Settings.safe_to_evict` (config `SafeToEvict`). This ticket owns what knarr writes while it is on and at what threshold. [config.allium](../../../docs/specs/config.allium) leaves one open question for this ticket: whether the threshold gains a per-Deployment override, under the same key, syntax and invalid-value rules as every override there; close it either way.

**From 21:** when a pod's reading is unknown or its contract absent, reconcile's `Neutral` in [reconcile.allium](../../../docs/specs/reconcile.allium) removes `safe-to-evict` with every other owned annotation, purpose `apply`; that is the one rule for a protection that ends for lack of data, and `Neutral` says you may replace that one sentence if you settle another value. What ending protection writes on a valid reading is yours.

**From 23:** no owned annotation expires by age, safe-to-evict included: the reading window is the only expiry (lifecycle `Restart` `NoExpiry` in [lifecycle.allium](../../../docs/specs/lifecycle.allium)), and a hold cap, if any, is yours. It is not an expiry, which `NoExpiry` defines as removing a value because it is stale: it is your policy, decided from valid readings and from time counted in memory from when the mark began, reset by a restart like the reading window, and never read from the marker's `at` (`Restart` `Informational`). Your clauses state it and what a restart does to it; `safe_to_evict`'s Pinning open question says so. The leftover an opt-out leaves is cleaned up under lifecycle `Cleanup` `Scope`: when a Deployment removes only the `knarr.io/safe-to-evict` opt-in, that annotation alone is removed with its record, and when it opts out of knarr every owned annotation goes. reconcile `Neutral` may remove the value first, with purpose `apply`, and the null record it leaves still falls to cleanup, a marker-only patch (ownership `Released`). A yielded safe-to-evict is never cleaned up: the record stays, the marker stays, and the operator releases it as lifecycle `Uninstall` `Recovery` says.

**From 30:** [observability.allium](../../../docs/specs/observability.allium) states the conventions any signal this ticket settles follows: metric names, labels and series life (`Catalogue` `Naming`, `Labels` and `SeriesLife`), Event reasons and type (`Events` `Conventions`), and log fields and levels (`Logs` `Format` and `Levels`). This ticket adds its own rows there with `tend` when it settles, without reopening 30 (`Catalogue` `LaterRows`). Already fixed: `knarr_annotations{deployment, annotation, standing}` with `annotation="safe-to-evict"` counts the annotation by ownership's standing on a pod exactly when reconcile asks its standing under ownership's `Adoption`, so a value an opt-out leaves counts until cleanup removes it and a `safe-to-evict` on a pod whose Deployment never enabled it counts nowhere (`Catalogue` `Standing`), and its writes count on `knarr_patches_total` with purpose `apply`, while the removal an opt-out leaves to 23 counts with purpose `cleanup` (`Patches`).

**MVP critical path:** no while the safe-to-evict feature is deferred. This ticket becomes a prerequisite when that opt-in feature resumes.

**Status:** deferred, needs-human. The maintainer deferred this feature on 2026-10-15 while picking up ticket 34. [49](49-safe-to-evict-user-guidance.md) carries the later user guidance; add the implementation follow-up this ticket creates as a blocker of 49 before enablement guidance is published. This ticket no longer blocks 34.

- [ ] The `elicit` skill is run with the maintainer in a live session.
- [ ] Every open point above is settled and recorded before any clause is written. Each one cites the S2a evidence it relies on, and S2b's (16) if that has landed.
- [ ] The clauses cover the threshold, the remove-versus-`"true"` rule, local-storage pods and node-pinning protection. `check-specs` and `analyse-specs` report nothing.
- [ ] The hand-back gives the `plan-spec` obligation count, drafts the spec-then-build follow-up ticket, and, if 16 has not landed, notes which clauses S2b must confirm.
