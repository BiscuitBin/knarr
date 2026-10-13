# 21: Elicit: unknown and unreachable policy (§9.6)

**Context:** OVERVIEW §5 ("Unreachable, invalid or absent endpoints") and the §8 failure-mode table propose defaults for an unreachable pod, a timeout or 5xx, a 404 or never-implemented endpoint, an invalid payload, and a pod that has just started. §9.6 leaves open how long to keep the last value (in polls and in time) before the neutral removal 20 fixed, and how to detect an absent contract. It depends on the cost mapping (20).

**What to build:** Allium clauses for every poll outcome other than a valid payload, settled with the maintainer, including when knarr writes neutral and when it treats a pod as unmanaged.

**Non-goals:** Cleanup on uninstall or on leaving scope (23).

**Blocked by:** 20

**From 30:** [observability.allium](../../../docs/specs/observability.allium) states the conventions any signal this ticket settles follows: metric names, labels and series life (`Catalogue` `Naming`, `Labels` and `SeriesLife`), Event reasons and type (`Events` `Conventions`), and log fields and levels (`Logs` `Format` and `Levels`). This ticket adds its own rows there with `tend` when it settles, without reopening 30 (`Catalogue` `LaterRows`). Already fixed: a pod entering the contract-absent state raises one create attempt of a `ContractAbsent` Event on its Deployment by name and uid, with the message `pod <pod>: no knarr status contract at port <port> path <path>; last reading <reading>` (`Events` `ContractAbsent`), counts on `knarr_pods_contract_absent{deployment}` (`Catalogue` `Standing`), and logs one warning line on entry (`Logs` `StateLines`). When a pod enters that state, and whether a restart enters it again, are this ticket's. Every poll outcome already counts on `knarr_polls_total{deployment, reading}` by Reading kind (`Polls`).

**MVP critical path:** yes. Unreachable and invalid pods are routine in production.

**Status:** needs-human

- [ ] The `elicit` skill is run with the maintainer in a live session.
- [ ] Every open point above is settled and recorded before any clause is written.
- [ ] The clauses cover each failure-mode row the §8 table assigns to §9.6. `check-specs` and `analyse-specs` report nothing.
- [ ] Any open question 19 left on the default or valid range of an unreachable-window override is closed.
- [ ] The hand-back gives the `plan-spec` obligation count and drafts the spec-then-build follow-up ticket.
