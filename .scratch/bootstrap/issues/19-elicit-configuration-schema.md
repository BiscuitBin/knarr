# 19: Elicit: label and annotation configuration schema (§9.1)

**Context:** OVERVIEW §9.1 decides that knarr is a controller configured through labels and annotations on Deployments, installed in one namespace with a Role (§9.18). The schema is open: how a Deployment opts in, how it overrides the endpoint or tuning, how it opts into `safe-to-evict`, and how knarr refuses or warns when pointed at StatefulSets, Jobs or DaemonSets (§3 non-goals).

**What to build:** Allium clauses for the configuration schema, settled with the maintainer: every label and annotation knarr reads, its type, default, validation, and the behaviour on invalid values. Some overrides take values another elicitation ticket owns: the endpoint (18), the thresholds and margin (20), unreachable windows (21), staleness and expiry (23), and poll and write limits (24). For those, the default and valid range come from the owning ticket. If it is not done yet, they stay as open questions that ticket owns.

**Non-goals:** The values of the tuning defaults themselves (18, 20, 21, 23, 24). The `safe-to-evict` policy (25).

**Blocked by:** 17

**MVP critical path:** yes. Users configure the MVP through this schema.

**Status:** needs-human

- [ ] The `elicit` skill is run with the maintainer in a live session.
- [ ] Every open point above is settled and recorded before any clause is written, including the label and annotation key prefix.
- [ ] The clauses cover opt-in, overrides, the per-workload `safe-to-evict` opt-in, invalid values and unsupported workload kinds. `check-specs` and `analyse-specs` report nothing.
- [ ] The hand-back gives the `plan-spec` obligation count and drafts the spec-then-build follow-up ticket.
