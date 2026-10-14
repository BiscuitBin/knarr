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

**From 30:** [observability.allium](../../../docs/specs/observability.allium) states the conventions any signal this ticket settles follows: metric names, labels and series life (`Catalogue` `Naming`, `Labels` and `SeriesLife`), Event reasons and type (`Events` `Conventions`), and log fields and levels (`Logs` `Format` and `Levels`). This ticket adds its own rows there with `tend` when it settles, without reopening 30 (`Catalogue` `LaterRows`). Already fixed: `knarr_annotations{deployment, annotation, standing}` with `annotation="safe-to-evict"` counts the annotation by ownership's standing on a pod exactly when reconcile asks its standing under ownership's `Adoption`, so a value an opt-out leaves counts until cleanup removes it and a `safe-to-evict` on a pod whose Deployment never enabled it counts nowhere (`Catalogue` `Standing`), and its writes count on `knarr_patches_total` with purpose `apply`, while the removal an opt-out leaves to 23 counts with purpose `cleanup` (`Patches`).

**MVP critical path:** yes, for the opt-in `safe-to-evict` feature only.

**Status:** needs-human

- [ ] The `elicit` skill is run with the maintainer in a live session.
- [ ] Every open point above is settled and recorded before any clause is written. Each one cites the S2a evidence it relies on, and S2b's (16) if that has landed.
- [ ] The clauses cover the threshold, the remove-versus-`"true"` rule, local-storage pods and node-pinning protection. `check-specs` and `analyse-specs` report nothing.
- [ ] The hand-back gives the `plan-spec` obligation count, drafts the spec-then-build follow-up ticket, and, if 16 has not landed, notes which clauses S2b must confirm.
