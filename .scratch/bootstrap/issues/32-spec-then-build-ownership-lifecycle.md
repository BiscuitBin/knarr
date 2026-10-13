# 32: Spec-then-build: the ownership and lifecycle invariants

**Context:** AGENTS.md states knarr's controller invariants: it writes only the annotations it owns, on live Pod objects, never changes replica counts, never touches a Deployment's pod template, and stops patching a pod once `deletionTimestamp` is set. OVERVIEW §4, §6, §7, §8 and §9.3 and §9.19 decide them, and no elicitation ticket's acceptance checks name them. [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md) assigns them here, in the `ownership` and `lifecycle` modules, next to the clauses 22 and 23 elicit. Those tickets draft their own spec-then-build follow-ups; they amend this ticket rather than duplicate it. Ticket 30 adds the Event and metric each invariant emits.

**What to build:** Clauses for each decided behaviour below, written with the `tend` skill without a live session because OVERVIEW already decides them, then tests derived with `propagate` and the controller code that passes them, in the order the `gleam-change` skill sets.

**Non-goals:** Any open question 22 or 23 owns. The `deletionTimestamp` safeguard, which 31 builds with the loop.

**Blocked by:** 22, 23, 30

**From 17:** [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md), map rows for §4, §6, §7, §8 and §9.

**MVP critical path:** yes. These are the safeguards the MVP promises.

**Status:** ready-for-agent, round 2

- [ ] knarr writes only the annotations it owns, on live Pod objects (§4), which the `Ownership` contract states as `Adoption` and `may_write`.
- [ ] knarr never patches a Deployment's pod template (§4).
- [ ] Every patch touches `metadata.annotations` only (§6), which the `Ownership` contract states as `WriteMode`.
- [ ] knarr never changes a replica count; HPA or KEDA owns scaling (§7, §9.3).
- [ ] A patch rejected with 400, 403 or by an admission webhook is logged and reported with an Event and a metric, with no rapid retries, and the previous annotations stay (§8 failure modes). A 422 is first a precondition failure and is classified by the next LIST with ownership `rejected`: true when every test of the failed patch passes against that view, so the patch was refused for its content (ownership `Rejected`).
- [ ] The `Ownership` contract of [ownership.allium](../../../docs/specs/ownership.allium) is built with a test per signature and per clause: `read` and `render` round trip and the canonical order (`Recorded`); `standing` and `may_write` for every state, unowned, owned, conflict, yielded and foreign (`Adoption`); `patch` with annotations null and with a list, its operation order, a write `may_write` forbids being dropped, a null write on an absent annotation being dropped, and the no-op patch that sends nothing (`WriteMode`); `yield`'s operations (`Yield`); `document`'s encoding; `rejected` passing and failing (`Rejected`); `event` from the pre-yield view with a value and with absent, and `message` for both (`Event`); and `Pure` by repeated application.
- [ ] knarr runs as a single replica with no leader election; a `Recreate` upgrade leaves a short gap with no updates and nothing else (§8, §9.19).
- [ ] While knarr is down or crashlooping it makes no updates, and the clauses state that annotations go stale (§8 failure modes).
- [ ] Each clause has a test that traces to it, `just check` passes, and the hand-back gives the `plan-spec` obligation count of each module touched.
