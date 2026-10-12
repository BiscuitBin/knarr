# 30: Elicit: observability (§9.14)

**Context:** OVERVIEW §9.14 leaves open the metrics (poll results, cost distribution, patch rate, errors), the Events and the logs knarr emits. §5 and the §8 failure-mode table name the points that raise an Event and a metric: an absent contract, a rejected patch, a failed cleanup and a conflict with another writer. Ticket 24 excludes "metric names and Events in general" from its scope, so no ticket in 18–25 owns §9.14. [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md) maps it to the `observability` module, which holds only the open questions.

**What to build:** Allium clauses for the `observability` module, settled with the maintainer: the metric names and labels, the Event reasons and targets, the log fields and levels, and what knarr's own probes report. The emission points stay in the owning modules; this module names what they emit.

**Non-goals:** The metrics library, which 13 picks. The emission conditions themselves (21, 22, 23).

**Blocked by:** 17, 24

**From 17:** [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md) records why §9.14 has no owner in 18–25 and the skeleton module this ticket starts from.

**MVP critical path:** no. The MVP runs without named metrics; operators need them to trust it.

**Status:** needs-human

- [ ] The `elicit` skill is run with the maintainer in a live session.
- [ ] Every open question in `docs/specs/observability.allium` is settled and recorded before any clause is written.
- [ ] The clauses cover the metrics for poll results, cost distribution, patch rate and errors; the Event reasons for an absent contract, a rejected patch, a failed cleanup and a conflict; the log fields and what is never logged; and the probes. `check-specs` and `analyse-specs` report nothing.
- [ ] The hand-back gives the `plan-spec` obligation count and amends ticket 32's acceptance checks with the Event and metric each invariant emits.
