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
