# 20: Elicit: cost mapping, bands, hysteresis and sign convention (§9.5)

**Context:** OVERVIEW §6 explains how `pod-deletion-cost` biases ReplicaSet victim ranking, and the explainer illustrates bands and the sign convention. §9.5 leaves open:

- the sign convention
- the knarr-owned range
- the number of bands and their edges
- hysteresis
- reserved bands
- how `cost` and `accepting` combine (§5 drain states)

The sign convention also fixes what removing an annotation means, which §9.12 depends on (23).

**What to build:** Allium clauses for the reconciler's clamp → band → hysteresis → decide-patch path (OVERVIEW §8), settled with the maintainer.

**Non-goals:** Unknown and unreachable handling (21). Write budgets (24).

**Blocked by:** 18

**MVP critical path:** yes. This is the core MVP mechanism.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] The `elicit` skill is run with the maintainer in a live session.
- [x] Every open point above is settled and recorded before any clause is written, including what an absent annotation means.
- [x] The clauses cover clamping, banding, hysteresis, reserved bands and the cost-accepting combination. `check-specs` and `analyse-specs` report nothing. (Banding is settled as none and hysteresis as a margin below each threshold; the clauses say so.)
- [x] Any open question 19 left on the default or valid range of a band or hysteresis override is closed.
- [x] The hand-back gives the `plan-spec` obligation count and drafts the spec-then-build follow-up ticket.

## Settled

The live session ran on 2026-10-10 in six rounds. The maintainer departed from the recommended option four times, and those choices shape the module: there are no bands and no quantization, the value written is the cost itself, and a write is due only at a configured threshold. Rounds 1 to 4 produced rows 1 to 13; an adversarial review the same day showed that the relative change threshold of round 3 damped nothing for small costs or for a worker toggling between 0 and a positive cost, and rounds 5 and 6 replaced it with rows 5, 6, 8 and 14 to 16 as they stand here. Row 17 closes a gap the pull request review found the same day: it follows from rows 2 and 14 and was not put as a separate question. The module and this table are the record; no decision record is written, as 18 did.

| # | Point | Decision | Rejected |
| --- | --- | --- | --- |
| 1 | Sign convention | Idle is 0, busy is above 0. Unannotated pods tie with idle pods. | Idle below 0 with 0 reserved as neutral (recommended); all positive with 0 as unknown. |
| 2 | Absent annotation | Absent means 0 and is the neutral value. For `pod-deletion-cost`, removal, the neutral fallback (21) and cleanup (23) are one operation. | Absent as a state distinct from idle. |
| 3 | Draining | A valid reading with `accepting` false and an idle cost maps to `-1`, below every idle and unannotated pod. With a busy cost the cost rules, draining or not: no override, no floor. Row 15 says what idle means. | Ignoring `accepting` in the mapping; the §5 candidate floor for draining pods. |
| 4 | Idle write | Nothing is written for an idle pod: the annotation is removed. The string `"0"` is never emitted. | Writing `"0"`. |
| 5 | Quantization | None. The written value is the clamped cost itself, taken at the reading that crosses a threshold. Between crossings the applied value stands even as the cost moves. | Two busy bands with edges 1 and 600 (recommended); one busy band; three bands; emitting band ordinals. |
| 6 | Hysteresis | A fixed margin below each threshold on the way down: `config.threshold_margin`, default 60, valid from 0 to one below the first threshold. Upward crossings are immediate. | Descend only after N consecutive polls (recommended twice); a value margin as a percentage; no damping at all. |
| 7 | Clamp | A cost above 2147483647 is 2147483647 for every purpose: tiers are counted against the clamped cost and the clamped cost is written. A negative cost never reaches the mapping (worker_contract `ValidReading`). | Treating it as an invalid reading. |
| 8 | Thresholds | A write is due only when the cost crosses a configured threshold. `config.thresholds` is a strictly increasing list of positive integers with at least one member, default 300, 900, 1800 and 3600, overridable per Deployment (19). Below the first threshold the pod is idle and the annotation is absent. | A relative change threshold, `min_change_percent` default 10, decided in round 3 and withdrawn after review: it wrote on every poll for a 0-to-positive toggle, damped nothing below cost 10, and at 100 let no decrease write. |
| 9 | Canonical string | Signed decimal int32: no plus sign, no leading zeros, `"-1"` for drained, no string for an idle pod. | None. |
| 10 | Module name | `cost_mapping`, in `docs/specs/cost_mapping.allium`, replacing `banding.allium`. | Keeping `banding`. |
| 11 | Follow-up | Ticket [31](31-spec-then-build-reconcile-core.md)'s boxes are amended, as Decision 0009 asks of follow-ups that overlap it. No new ticket. | A new spec-then-build ticket. |
| 12 | Network | `just initialize` was authorized once in this session, to install the gate toolchain. The pushes followed the maintainer's stop hook. A Codex review was asked for and could not run here (no CLI, no credential); the maintainer chose a second independent agent review instead. | Verifying by inspection only; installing the Codex CLI with a supplied key. |
| 13 | Readiness threshold | worker_contract's `ReadinessWarning` is phrased against "a value above 0", which is a tier of at least 1. Ticket 18 rejected `cost > 0` because the threshold was 20's to define, not for its value; with no bands, "above the lowest band" has this one translation, and it excludes a drained `-1` pod. It follows from rows 1, 3 and 8 and was not put as a separate question. | None beyond 18's. |
| 14 | Tier | The tier of an applied value is the count of thresholds at or below it, 0 for absent and `-1`. A reading is due upward when its own tier exceeds the applied tier, and due downward when the cost falls below the applied tier's threshold minus the margin; the new value's own tier then stands, so a drop from 950 to 250 (thresholds 300 and 900, margin 60) removes the annotation rather than writing 250. Nothing but the applied value is needed to continue after a restart (§8). | The marker records the tier, and the descent edge is threshold minus margin for every tier. |
| 15 | Idle and drained | Idle is a cost below the first threshold. Draining and below the first threshold maps to `-1`; at or above it the cost rules, no floor. Entering and leaving `-1` is immediate, with no margin, since accepting is a statement. | `-1` only at cost exactly 0. |
| 16 | Cost meaning | `cost` is intended as the number of seconds the worker's longest-running active task has run so far, 0 when none; a worker may report another non-negative measure, but the default thresholds assume seconds. worker_contract's `Payload` clause now says so, amended by this ticket with a line in 18's hand-back. | Leaving the meaning to the guides. |
| 17 | Tier-0 applied value | An applied value above 0 whose tier is 0, which only a threshold override that raised the first threshold above it leaves behind, counts as 0 in `Crossing`: the next reading maps to the cost at tier 1 or more, to `-1` draining, and to 0 otherwise. No positive value below the first threshold survives a reading. | Keeping the stale value until the cost crosses a threshold above it, which `Absent` already forbade. |

The departure from OVERVIEW §6 was put to the maintainer in full before it was taken: KEP-2255 and the ReplicaSet docs ask for coarse-grained updates and warn against writing a metric value, and Decision 0009 mapped quantization and hysteresis to this module. Writing only at threshold crossings is coarse-grained in the KEP's sense while the value stays the cost itself. Decision 0009 says a ticket that finds the overview wrong amends the overview and the map follows; both are amended here.

Boundaries kept: `cost_mapping` owns the mapped value, its string, the thresholds and the margin. `worker_contract` owns the wire shape, the meaning of `cost` and the `draining` predicate. What reconcile does with a reading other than a valid one, which value stands as applied, and the removal itself are `reconcile` (21, 31); the marker that records the applied value and the recognition of a value knarr did not write are `ownership` (22); expiry and cleanup are `lifecycle` (23); whether a due write may go now is `budget` (24); the override keys for the thresholds and the margin and an invalid override are `config` (19). One sibling edit is a reading rather than a word swap: `safe_to_evict`'s threshold question now speaks of tiers and of a hysteresis wider than cost_mapping's margin where Decision 0008 compared it with the cost banding; 25 settles what that means.

## Hand-back notes

### What changed

- `docs/specs/cost_mapping.allium` (renamed from `banding.allium`): the seven open questions became the `CostMapping` contract with the signatures `tier`, `map` and `render`, the invariants `Continuous`, `Sign`, `Absent`, `Drained`, `Clamp`, `Tiers`, `Crossing`, `Canonical` and `Pure`, the value type `Mapped`, and a `config` block with `thresholds` and `threshold_margin`. `just plan-spec docs/specs/cost_mapping.allium` reports 7 obligations.
- Sibling modules, each still its owner's: `worker_contract`'s `Payload` clause and `Status` comment state the intended meaning of `cost` (row 16), its header names `cost_mapping`, and its `ReadinessWarning` reads "maps to a value above 0"; `knarr` lists the module; `reconcile`'s transient-failure question names the removal and its duplicate neutral question is gone; `config`'s override question names the thresholds and margin; `safe_to_evict`'s threshold question names tiers and the margin; `lifecycle` and `observability` say cost where they said band.
- `docs/OVERVIEW.md`: §4 step 3, the §5 payload callout, the §5 drain-state table, the §6 bullets and sign-convention paragraph and §9.5 point at the module; the §5 state diagram, the §6 diagram, §7, §8 and §9.6 no longer say band, quantize, hysteresis or an open neutral; the glossary has **Mapped value** and **Threshold**. `docs/overview-explainer.html` section 2 shows the threshold axis with its margin zones and the settled sign convention. `docs/DEFERRED.md` and `docs/explanation/README.md` follow. No page was added, so `docs/manifest.yml` is untouched.
- [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md): the module table and every former `banding` row name `cost_mapping`; the rows keep their 2026-10-08 class and their text follows the amended overview, as 18's rows do; the Consequences record the amendment.
- Tickets: [31](31-spec-then-build-reconcile-core.md) names `cost_mapping`, its readiness, desired-state and patch boxes read value and crossing instead of band, and it gains the `CostMapping` test box; [18](18-elicit-worker-contract.md) records the `Payload` amendment; [19](19-elicit-configuration-schema.md), [21](21-elicit-unknown-unreachable-policy.md), [23](23-elicit-cleanup-staleness-restart.md), [30](30-elicit-observability.md) and [43](43-status-poller.md) say cost, thresholds or the removal where they said band or an open neutral. The [bootstrap README](../README.md) is unchanged: 20's edges did not move.

### What was verified

- `just check-specs` and `just analyse-specs`: 11 specifications, no diagnostics and no findings. The pinned checker accepts `List<Integer>` as a signature parameter type and as a config type with a list-literal default.
- `just plan-spec docs/specs/cost_mapping.allium`: 7 obligations (one value type at two, three contract signatures, two config defaults).
- `just docs-check` validates 26 pages and 30 canonical topics, including the links into `docs/specs/cost_mapping.allium`.
- `just check` ends with "All checks passed and the worktree is unchanged." Nothing under `src/` or `test/` changed, and nothing ran against a cluster.
- Two adversarial agent reviews of the diff. The first reported seventeen points on the round-3 module; sixteen were applied (equality precedence in the threshold rule, the applied-value baseline, "never overrides a positive cost", `Absent` scoped to `pod-deletion-cost`, the readiness threshold and the `safe_to_evict` reading recorded as decisions, OVERVIEW §9.6's neutral, band words in tickets 19, 21, 23 and 30, the floor row in Decision 0009, the explainer's label overlaps and "±10%") and the cosmetic one, the explainer's band-named CSS variables, was left. The second, against the brief in `ai_tmp/codex-review-request.md` written for a Codex review that could not run here, reported fifteen findings: the high one, that the relative threshold damped neither small costs nor a 0-to-positive toggle, was put to the maintainer and produced rows 8 and 14 to 16; eleven more were applied (the hand-offs to 22, 24 and 25, the pending-write rule for 31, the marker surviving the idle removal, one class convention in Decision 0009, row 13's account of 18, the boundaries paragraph, reconcile's duplicate question, `render` and `map` defined on `Mapped`'s values only, "written" where "applied" was meant, the explainer's repeated label, 31's test list); two were superseded by the new design (the one-sided percentage at 100, integer overflow in the percentage product); one, the 24 hand-off, stands in reduced form because the toggle no longer writes. The pull request review then reported five findings, all applied: a positive applied value left below the first threshold by an override was stuck (row 17 and 31's override cases), the 24 hand-off omitted the `accepting` toggle, OVERVIEW §4 and the explainer said crossings were the only writes, and the pull request body was stale.

### Choices a maintainer may reverse

- The tier of a pod is derived from the applied value alone (row 14). The alternative, the marker carrying the tier, is path-consistent on the way down but leaves a pod whose marker is lost unplaceable.
- `map` takes the applied value and returns the desired one, and reconcile's existing "desired differs from last applied" rule decides the write. A separate `due` signature was dropped with the percentage; add one back if 31 wants the comparison named in the contract.
- The margin default of 60 and the thresholds 300, 900, 1800 and 3600 are defaults for a worker that reports seconds; neither is grounded in a measurement. 33's harness is the first place to tune them.
- `render` returns `String?`, with null as the removal. If a later pin rejects the optional return, split it into `render: (mapped: Mapped) -> String` and `removes: (mapped: Mapped) -> Boolean`.
- Decision 0009's rows for 20 keep their 2026-10-08 class, as 18's do, and only their text follows the amended overview. Mark them settled instead if the map should show state rather than origin.
- No decision record for the departure from OVERVIEW §6's bands; the module header, OVERVIEW §6 and this ticket are the record. Say so if a Decision 0014 is wanted.
- 31 is amended rather than a new ticket drafted.

### What later tickets need

- **19:** two overrides, `thresholds`, a strictly increasing list of positive integers with at least one member and default `config.thresholds` (300, 900, 1800, 3600), and `threshold_margin`, an Integer from 0 to one below the first threshold with default `config.threshold_margin` (60). The key syntax for a list and what happens on an invalid override are yours. No band, hysteresis or percentage override exists.
- **21:** the neutral value is the removed annotation, which `render` spells as no string. Only a valid reading reaches `map`; which reading kinds keep the applied value and for how long is yours, and the fallback write is a removal.
- **22:** `map` takes the value knarr's own marker records as last applied, including "absent", so the marker must record a removal and the idle removal must not strip the marker. A value on the pod that knarr did not apply (a human's `"0"`, the lablabs or zepellin controllers, Karpenter with `PodDeletionCostManagement`) is yours to recognise and is never passed to `map` as applied; with a continuous value the marker is the only ownership signal, since knarr's values have no shape of their own.
- **23:** for `pod-deletion-cost`, cleanup is the same removal, and the marker survives it when the pod stays managed. Writes are sparse by the thresholds instead of by banding, so the marker-freshness tension in §8 stands with "the same cost reported for hours".
- **24:** the worst case is one write per pod per poll, on two paths: a cost that crosses a threshold on one poll and falls back past the margin on the next, or a pod below the first threshold whose `accepting` toggles on every poll, since entering and leaving `-1` has no margin. The per-pod minimum interval and the global QPS are the only bound on either; the thresholds bound the common case, since a non-draining pod whose cost stays below the first threshold never writes.
- **25:** the `safe-to-evict` threshold is a `cost_mapping` tier, read off the applied value, so your flips are gated by the same crossings. Decision 0008's "hysteresis wider than the cost banding" reads as your own enter and leave tiers and a time dwell, wider than cost_mapping's margin and independent of it.
- **30:** the readiness gauge counts NotReady pods whose last valid reading maps to a value above 0; the distribution metric is of the mapped value or its tier, not of bands.
- **31:** build `CostMapping` with the tests your box lists; the desired state carries the mapped value, `map` compares against the last applied value the marker records, a throttled change is re-derived from the latest reading when it goes, and `render`'s null is a removal patch.
- **43:** its first box now says 31 holds the mapped value, not the band; nothing else in the poller changes.
