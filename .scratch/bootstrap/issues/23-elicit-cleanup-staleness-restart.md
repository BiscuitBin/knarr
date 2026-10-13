# 23: Elicit: cleanup, staleness, restart and uninstall (§9.12)

**Context:** OVERVIEW §9.12 offers three cleanup options:

- (i) never clean up
- (ii) clean up when a pod or workload leaves scope
- (iii) also clean up on graceful shutdown

It also covers:

- separate expiry for deletion cost and for `safe-to-evict`
- what the marker timestamp means
- conservative behaviour on restart when freshness is unknown
- startup reconciliation of marked pods
- annotations left after a crash
- an uninstall procedure

§8 names the open tension: writes are sparse, so a last-written timestamp cannot tell a steady cost from hours of failed polls. A §3 success criterion requires that a restart does not make annotations flap.

Ticket 22 settled the marker in [ownership.allium](../../../docs/specs/ownership.allium) and hands this over. Cleanup removes the annotations standing owned; a yielded or foreign value stays. `standing` is defined for both owned annotations whatever the Deployment enables, and reconcile asks it for one the Deployment no longer enables only while the marker holds a record for it, so the value an opt-out leaves behind falls to cleanup here; the opt-in key and its parse are config's `SafeToEvict` (19) and the gate's behaviour is 25's. Whether the marker goes with the last owned annotation is yours to settle, since ownership's `Applied` keeps it on the idle removal. The operator releases a yield by removing the marker together with every owned annotation on the pod ([22's Settled row 10](22-elicit-ownership-and-conflicts.md#settled)); removing the marker alone leaves every present value foreign, and the procedure page is 34's. The marker's `at` and each record's `at` are the write times whose meaning this ticket settles, and a `Pod` may carry no annotations map at all (`Pod.annotations` null).

**From 19:** config's `leaving` returns the names of the pods a Deployment's opt-out (label removed or changed) or deletion dropped from the target set at a discovery cycle; what is left on them is this ticket's. [config.allium](../../../docs/specs/config.allium) leaves one open question for this ticket: whether a staleness or expiry value gains a per-Deployment override, under the same key, syntax and invalid-value rules as every override there; close it either way.

**What to build:** Allium clauses for cleanup, staleness, restart and uninstall, settled with the maintainer, consistent with the sign convention (20) and the marker (22).

**Non-goals:** The `safe-to-evict` threshold itself (25).

**Blocked by:** 20, 22

**MVP critical path:** yes. Restart safety is an MVP success criterion.

**Status:** needs-human

- [ ] The `elicit` skill is run with the maintainer in a live session.
- [ ] Every open point above is settled and recorded before any clause is written, including the restart success threshold handed to §9.16.
- [ ] The clauses cover cleanup scope, expiry, marker freshness, startup reconciliation, crash leftovers and the uninstall procedure. `check-specs` and `analyse-specs` report nothing.
- [ ] Any open question 19 left on the default or valid range of a staleness or expiry override is closed.
- [ ] The hand-back gives the `plan-spec` obligation count and drafts the spec-then-build follow-up ticket.
