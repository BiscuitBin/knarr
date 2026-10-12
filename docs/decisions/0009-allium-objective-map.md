---
title: "Decision 0009: The Allium objective map"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_allium_objective_map]
requires: []
---

# Decision 0009: The Allium objective map

## Context

[Decision 0001](0001-specs-decide-behaviour.md) makes the specifications under `docs/specs/` the source of behaviour, and [the overview](../OVERVIEW.md) direction for drafting them. §4 to §9 of the overview describe knarr at concept level, marked decided, recommended, unverified or open. Before the elicitation tickets 18 to 25 write a clause, each behaviour needs a module to land in, a class, and an owner. Ticket 17 settles those three things here, drafts the follow-up tickets for anything unowned, and leaves one skeleton module per proposed module, each holding only the open questions its owner settles. It settles no open question and writes no clause.

## Decision

### Modules

`docs/specs/` holds a root module, `knarr.allium`, and ten modules. The header comment of each states its scope, which the `spec-change` skill reads to find the module that owns a behaviour. No module imports another: the skeletons carry only `open question` entries, and an unresolved `use` is a gate diagnostic.

| Module | Scope | Owner |
| --- | --- | --- |
| `worker_contract` | What a worker pod exposes and what each field means: endpoint shape, discovery, auth, NetworkPolicy compatibility, drain-state meaning, readiness guidance | 18 |
| `config` | Every label and annotation knarr reads, its type, default, validation and invalid-value behaviour; unsupported kinds; the target set in one namespace | 19 |
| `cost_mapping` | The pure mapping from cost and `accepting` to the emitted `pod-deletion-cost` value: sign convention, absent, drained, clamp, canonical int32, thresholds and margin. Named `banding` until ticket 20 settled that there are no bands | 20 |
| `reconcile` | The per-pod loop: poll outcome to pod state, desired state against last applied, patch on meaningful change, pending changes, no patches after `deletionTimestamp`, rollouts untouched | 21, then 31 |
| `ownership` | What knarr may write and how: owned annotations only, live Pods, `metadata.annotations` only, never the pod template, never replicas; marker, write mode, conflicts, Event and back-off, rejected patches | 22, then 32 |
| `lifecycle` | Startup reconciliation, marker freshness, expiry and cleanup, crash leftovers, the `Recreate` gap, single replica, uninstall | 23, then 32 |
| `budget` | Poll schedule, LIST cadence, bounded concurrency with jitter, no overlapping polls, per-pod interval, global QPS, APF and 429 back-off, scale target, write rate, feature-gate check | 24 |
| `safe_to_evict` | When knarr writes `"false"`, removes it and never writes `"true"` by default: threshold, hysteresis against the autoscaler's blackout, local storage, pinning caps, best-effort limits | 25, confirmed by 16 |
| `k8s_client` | The in-cluster API boundary: verified TLS with an IP-SAN check, token reload, the verbs used, the minimum Role, the patch content types the write mode needs | 14, amended by 22 |
| `observability` | The catalogue of metrics, Events and log lines; the emission points stay in the owning modules | 30 |

Packaging (§9.15) is not a module. It is a release decision that ticket 28 makes, and no clause follows from it.

### Classes

Each behaviour has one of three classes.

- **Decided.** The overview states it as a rule or marks it decided, and no elicitation is needed. The owner is the elicitation ticket whose acceptance checks already name it, or else a round-2 spec-then-build ticket drafted here.
- **Open.** The overview marks it open, recommended, proposed, a default to be confirmed, or a candidate. All of those are settled with the maintainer, so the owner is the elicitation ticket for the §9 item it belongs to.
- **Blocked on a spike.** The overview marks it unverified and names a spike. S1 is ticket 14. S2 is ticket 15, done in [Decision 0008](0008-safe-to-evict-on-upstream-ca.md), and ticket 16 on GKE.

### Owners

Ticket 17 defines an owner as an elicitation ticket, 18 to 25, or a follow-up drafted by 17. Some rows name an owner outside that definition on purpose, so that no ticket is drafted twice and nothing already settled is reopened. The in-cluster client, TLS, token reload and RBAC (§8) are owned by spike S1, ticket 14, whose acceptance already promises the client module's spec-then-build pair and a decision record for §9.2. The spike S2 rows are owned by ticket 15, done in Decision 0008, and by ticket 16 for GKE; if 16 never runs, its rows stay blocked and ticket 25 notes which clauses are unconfirmed, as its acceptance already requires. Packaging (§9.15) and the Role manifest are owned by ticket 28, whose acceptance already decides them. The kind substitute for envtest is settled by Decision 0007, and deferred items are owned by DEFERRED.md.

Tickets 18 to 25 are not edited. Each ends by drafting its own spec-then-build follow-up; those follow-ups amend tickets 31 and 32 where they overlap rather than duplicate them. Tickets 31 and 32 carry only the decided behaviours that no acceptance check in 18 to 25 names.

The follow-ups drafted by this record are [30](../../.scratch/bootstrap/issues/30-elicit-observability.md), an elicitation ticket for §9.14; [31](../../.scratch/bootstrap/issues/31-spec-then-build-reconcile-core.md) and [32](../../.scratch/bootstrap/issues/32-spec-then-build-ownership-lifecycle.md), round-2 spec-then-build tickets for the decided loop and the decided invariants; [33](../../.scratch/bootstrap/issues/33-keda-harness-success-criterion.md), the KEDA harness that measures the first §3 success criterion; and [34](../../.scratch/bootstrap/issues/34-user-guides.md), the user-facing guides that ticket 12 leaves to round 2.

### What counts as a behaviour

A behaviour is something knarr does or refuses to do. Kubernetes facts in the overview, such as the victim ranking steps, the official caveats and the feature state of `pod-deletion-cost`, are context and have no row. The supervision tree and the choice of `gleam_otp` (§8) are implementation under [Decision 0002](0002-sans-io-boundaries.md). Future targets (§9.17) are deferred. Advice for workers and cluster operators is guidance: it maps to the module it describes and is owned by ticket 34, which writes the page once the owning elicitation ticket has settled the behaviour.

## The map

Each row names one behaviour, its module, its class and its owner. Where the overview states two behaviours in one sentence, for example a rule and the page that explains it, they are two rows. "§8 table" is the failure-mode table in §8. A module of "none" means the row is a page, a package or a test rather than a clause.

### §4 How it works

| Behaviour | § | Module | Class | Owner |
| --- | --- | --- | --- | --- |
| Discover opted-in pods by a periodic LIST scoped to one namespace and selector | §4.1 | `config` | decided | 31 |
| The LIST runs on its own cadence, slower than polling | §4.1 | `budget` | decided | 24 |
| Poll with jitter, no overlapping polls of one pod, and bounded concurrency | §4.2 | `budget` | decided | 24 |
| The per-poll timeout, shorter than the poll interval | §4.2, §9.8 | `budget` | open | 24 |
| Treat cost as untrusted: clamp, combine with `accepting`, write at threshold crossings | §4.3 | `cost_mapping` | open | 20 |
| Derive the desired state: cost value, opt-in `safe-to-evict`, marker | §4.3 | `reconcile` | decided | 31 |
| Patch only when desired differs from last applied, covering a threshold crossing, first annotation, startup repair, cleanup and flips | §4.4 | `reconcile` | decided | 31 |
| One rate-limited patcher: per-pod minimum interval plus global QPS | §4.4 | `budget` | decided | 24 |
| Throttled changes stay pending and are not dropped | §4.4 | `reconcile` | decided | 31 |
| No patches once `deletionTimestamp` is set; polling may continue | §4.5 | `reconcile` | decided | 31 |
| Annotate live Pod objects, never the Deployment's pod template | §4 | `ownership` | decided | 32 |
| No "annotate before scale-down": costs stay fresh all the time | §4, §7 | `reconcile` | decided | 31 |

### §5 Worker contract

| Behaviour | § | Module | Class | Owner |
| --- | --- | --- | --- | --- |
| Pull model: knarr polls, workers do not push | §5 | `worker_contract` | decided | 18 |
| The payload carries only `cost` and `accepting`; more fields are out of scope | §5 | `worker_contract` | decided | 18 |
| Type, range and units of `cost` | §5, §9.5 | `cost_mapping` | open | 20 |
| Plain HTTP to pod IPs, no mTLS, no service mesh | §5 | `worker_contract` | decided | 18 |
| NetworkPolicy configuration a worker namespace needs | §5, §9.4b | `worker_contract` | open | 18 |
| The NetworkPolicy page | §5, §9.4b | none | open | 34 |
| Path, port, field names, types, auth, versioning; any version marker lives outside the body | §5, §9.4a | `worker_contract` | open | 18 |
| Whether knarr warns on high cost while NotReady | §5, §9.7 | `worker_contract` | open | 18 |
| The readiness trade-off page | §5, §9.7 | none | open | 34 |
| `accepting: false` matters only for a drain the worker starts itself | §5 | `worker_contract` | decided | 18 |
| A terminating pod gets no patches; the worker's graceful shutdown applies | §5 | `reconcile` | decided | 31 |
| Handling per drain state; a floor for draining pods was a candidate and is rejected | §5, §9.5 | `cost_mapping` | open | 20 |
| knarr never overrides a positive cost | §5 | `cost_mapping` | decided | 20 |
| Never treat missing data as busy; keep any fallback bounded | §5 | `reconcile` | decided | 21 |
| Transient failure: keep the last value for bounded polls and time, then neutral | §5, §9.6 | `reconcile` | open | 21 |
| Contract absent: unmanaged, remove owned annotations, raise an Event and metric | §5, §9.6 | `reconcile` | open | 21 |
| The names of that Event and metric | §5, §9.14 | `observability` | open | 30 |
| Just started: unannotated until a valid poll | §5, §9.6 | `reconcile` | decided | 31 |
| Every owned annotation has an expiry and a cleanup attempt; a rejected cleanup raises an Event and metric | §5, §9.12 | `lifecycle` | open | 23 |
| The names of that Event and metric | §5, §9.14 | `observability` | open | 30 |
| Workers own graceful shutdown: SIGTERM, exec-form entrypoint, grace period, `preStop`, autoscaler termination cap | §5 | `worker_contract` | decided | 34 |

### §6 Annotation semantics

| Behaviour | § | Module | Class | Owner |
| --- | --- | --- | --- | --- |
| Whether knarr checks the `PodDeletionCost` feature gate, and how | §6, §9.11 | `budget` | open | 24 |
| The prerequisite page | §6, §9.11 | none | open | 34 |
| Emit canonical signed decimal int32 strings only | §6 | `cost_mapping` | decided | 31 |
| Write the cost itself at threshold crossings, no bands; a worker reports elapsed seconds | §6, §9.5 | `cost_mapping` | open | 20 |
| A margin below each threshold on the way down, and its width | §6, §9.5 | `cost_mapping` | open | 20 |
| Patch only on desired-state change | §6 | `reconcile` | decided | 31 |
| Per-pod minimum interval, global QPS budget, documented expected write rate | §6, §9.8 | `budget` | open | 24 |
| Patch only `metadata.annotations` | §6 | `ownership` | decided | 32 |
| Merge patch or conditional write | §6, §9.10 | `ownership` | open | 22 |
| Sign convention and what an absent annotation means | §6, §9.5 | `cost_mapping` | open | 20 |
| No values reserved for knarr's own states | §6, §9.5 | `cost_mapping` | open | 20 |
| `safe-to-evict` is off by default, enabled per workload | §6 | `config` | decided | 19 |
| knarr manages only `"false"` or removes the annotation | §6, §9.9 | `safe_to_evict` | open | 25 |
| `"false"` above a threshold, removal below; local-storage pods | §6, §9.9 | `safe_to_evict` | open | 25 |
| Mark only high-cost pods so nodes still scale down | §6, §9.9 | `safe_to_evict` | open | 25 |
| Whether the autoscaler re-checks before evicting; whether a flip resets the unneeded timer | §6 | `safe_to_evict` | blocked on S2 | 15 (done), 16 (GKE) |
| S2 must run on GKE's managed autoscaler | §6 | `safe_to_evict` | blocked on S2 | 16 |

### §7 Scaling ownership

| Behaviour | § | Module | Class | Owner |
| --- | --- | --- | --- | --- |
| HPA or KEDA sets replicas; knarr only writes annotations | §7, §9.3 | `ownership` | decided | 32 |
| Scale-from-zero needs an external KEDA trigger; tuning through `behavior` | §7 | none | decided | 34 |
| A documented guide for pairing knarr with a KEDA ScaledObject | §7 | none | decided | 34 |
| Scaling option (b) | §7 | none | deferred | [DEFERRED.md §1](../DEFERRED.md#1-scaling-option-b-quick-follow) |

### §8 Architecture sketch

| Behaviour | § | Module | Class | Owner |
| --- | --- | --- | --- | --- |
| A small client module: get, list, patch on pods; get, list on Deployments and ReplicaSets | §8, §9.2 | `k8s_client` | blocked on S1 | 14 |
| Explicit ssl options, the service-account CA, a hostname check, OTP 26 or later; IP-SAN verification unverified | §8 | `k8s_client` | blocked on S1 | 14 |
| Re-read the token periodically; never cache it for the process lifetime | §8 | `k8s_client` | blocked on S1 | 14 |
| The verbs the minimum Role grants | §8 | `k8s_client` | blocked on S1 | 14 |
| The Role manifest in the package | §8, §9.15 | none | open | 28 |
| Single replica, `Recreate`, no leader election, a short gap during upgrades | §8, §9.19 | `lifecycle` | decided | 32 |
| The marker annotation that holds the last-written value and a timestamp | §8, §9.10 | `ownership` | open | 22 |
| Derive state from the poll, the annotations and the marker, with no in-memory counters; reconcile marked pods on startup | §8, §9.12 | `lifecycle` | open | 23 |
| The uninstall procedure and manual recovery | §8, §9.12 | `lifecycle` | open | 23 |
| The uninstall page | §8, §9.12 | none | open | 34 |
| §8 table: unreachable, 404, invalid payload, just started | §8, §9.6 | `reconcile` | open | 21 |
| §8 table: restart, reconcile marked pods without flapping | §8, §9.12 | `lifecycle` | open | 23 |
| §8 table: knarr down, no updates; upgrade, a short gap | §8, §9.12 | `lifecycle` | decided | 32 |
| §8 table: API throttling, poll fan-out | §8, §9.8 | `budget` | open | 24 |
| §8 table: patch rejected; log, Event, metric, no rapid retries | §8, §9.12 | `ownership` | decided | 32 |
| The names of that Event and metric | §8, §9.14 | `observability` | open | 30 |
| §8 table: another writer changed the value; Event, back off, the other writer wins | §8, §9.10 | `ownership` | open | 22 |
| §8 table: rollout, no special handling | §8, §9.13 | `reconcile` | decided | 31 |
| §8 table: gate disabled, documented prerequisite, optional self-test | §8, §9.11 | `budget` | open | 24 |
| §8 table: a NetworkPolicy block looks like an absent contract and raises an Event | §8, §9.6 | `reconcile` | open | 21 |

### §9 Open questions

| Item | Module | Class | Owner |
| --- | --- | --- | --- |
| S1 in-cluster client | `k8s_client` | blocked on S1 | 14 |
| S2 autoscaler behaviour on flips | `safe_to_evict` | blocked on S2 | 15 (done), 16 |
| 9.1 Configured through labels and annotations on Deployments | `config` | decided | 19 |
| 9.1 The label and annotation schema | `config` | open | 19 |
| 9.2 Client option (A), pure Gleam plus FFI | `k8s_client` | blocked on S1 | 14 |
| 9.3 Scaling ownership (a) | `ownership` | decided | 32 |
| 9.4a Endpoint shape | `worker_contract` | open | 18 |
| 9.4b Discovery, auth, network | `worker_contract` | open | 18 |
| 9.5 Cost mapping | `cost_mapping` | open | 20 |
| 9.6 Unknown and unreachable | `reconcile` | open | 21 |
| 9.7 Readiness interaction | `worker_contract` | open | 18 |
| 9.8 Poll, concurrency, write budget | `budget` | open | 24 |
| 9.9 `safe-to-evict` policy on upstream CA | `safe_to_evict` | open | 25 |
| 9.9 The same policy on GKE's managed CA | `safe_to_evict` | blocked on S2 | 16 |
| 9.10 Ownership and conflicts | `ownership` | open | 22 |
| 9.11 Feature-gate prerequisite | `budget` | open | 24 |
| 9.12 Cleanup, staleness, freshness | `lifecycle` | open | 23 |
| 9.13 Rollouts: no special handling | `reconcile` | decided | 31 |
| 9.13 Rollouts: guidance on `maxUnavailable` and `maxSurge` | none | open | 34 |
| 9.14 Observability | `observability` | open | 30 |
| 9.15 Packaging | none | open | 28 |
| 9.16 Testing strategy: unit tests for the cost mapping | `cost_mapping` | decided | 20, through `propagate` in its spec-then-build |
| 9.16 Testing strategy: the kind substitute for envtest | none | decided | [Decision 0007](0007-local-cluster.md) |
| 9.16 Testing strategy: end-to-end tests on kind with a fake worker image | none | decided | 29 (the image), 33 (the harness) |
| 9.16 Thresholds: restart does not flap | `lifecycle` | open | 23 |
| 9.16 Thresholds: patch rate within the write budget | `budget` | open | 24 |
| 9.16 Thresholds: fewer busy pods killed | none | open | 33 |
| 9.17 Future targets | none | deferred | [DEFERRED.md](../DEFERRED.md) |
| 9.18 One install per namespace | `config` | decided | 31 |
| 9.18 With a namespaced Role | none | decided | 28 |
| 9.19 Single replica, no leader election | `lifecycle` | decided | 32 |

## Verification

`just check-specs` and `just analyse-specs` report no diagnostic and no finding across the eleven modules, and `just plan-spec` reports 0 obligations for each, as ticket 17's hand-back notes record. The pinned Allium 3.6.1 binary emits nothing for an `open question`, although the vendored language reference says the checker should warn on one. A later pin that starts to warn would fail the gate on every skeleton until its owner settles the questions, which is the intended pressure.

## Consequences

- Every elicitation ticket starts from a module the gate accepts and deletes open questions as it settles them. A module whose questions are all gone and whose clauses are all in is done.
- Ticket 30 is a new elicitation ticket, and 31 to 34 are round 2. The bootstrap README's graph and waves table carry them, and the longest chain grows from nine tickets to eleven.
- Tickets 14, 15, 16 and 28, Decision 0007 and DEFERRED.md own rows that 17's definition of an owner does not cover. If any is reshaped, the rows here move with it.
- The class of a row is a reading of the overview on 2026-10-08. A ticket that finds the overview wrong amends the overview, and this map follows. Ticket 20 did so on 2026-10-10: it renamed `banding` to `cost_mapping`, settled quantization and reserved bands as none and hysteresis as a margin below each threshold, and amended OVERVIEW §4, §5 and §6 to match; the rows above keep their 2026-10-08 class and follow the amended text, as 18's rows do.

## What would reopen this

- An elicitation ticket finds that a behaviour belongs in a different module than the one mapped here, for example a drain-state rule that is better placed in `worker_contract` than in `cost_mapping`.
- The Allium pin moves and the gate starts to warn on `open question`, which changes what a skeleton may hold.
- A follow-up ticket is merged into another or split, which changes an owner.

## Related pages

- [Project overview](../OVERVIEW.md), §4 to §9
- [Decision 0001: Specifications decide behaviour](0001-specs-decide-behaviour.md)
- [Decision 0002: Effects live behind sans-IO boundaries](0002-sans-io-boundaries.md)
- [Decision 0005: A project-managed Allium binary](0005-project-managed-allium-cli.md)
- [Decision 0007: Local cluster and test tiers](0007-local-cluster.md)
- [Decision 0008: safe-to-evict on upstream Cluster Autoscaler](0008-safe-to-evict-on-upstream-ca.md)
- [Ticket 17](../../.scratch/bootstrap/issues/17-allium-objective-map.md) and the [bootstrap ticket order](../../.scratch/bootstrap/README.md)
