# 30: Elicit: observability (§9.14)

**Context:** OVERVIEW §9.14 leaves open the metrics (poll results, cost distribution, patch rate, errors), the Events and the logs knarr emits. §5 and the §8 failure-mode table name the points that raise an Event and a metric: an absent contract, a rejected patch, a failed cleanup and a conflict with another writer. Ticket 24 excludes "metric names and Events in general" from its scope, so no ticket in 18–25 owns §9.14. [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md) maps it to the `observability` module, which holds only the open questions.

Ticket 22 fixed the conflict Event's content and message in the `Event` clause of [ownership.allium](../../../docs/specs/ownership.allium): at most one per yield, on the Pod, one create attempt after the yield patch is accepted, with no retry when it fails; this ticket names its reason. This ticket also names the gauge and the log line ownership's `Adoption` requires for a foreign annotation, which raises no Event, and settles the cadence of that log line: on each LIST that shows the foreign value, or on entry.

**What to build:** Allium clauses for the `observability` module, settled with the maintainer: the metric names and labels, the Event reasons and targets, the log fields and levels, and what knarr's own probes report. The emission points stay in the owning modules; this module names what they emit.

**Non-goals:** The metrics library, which 13 picks. The emission conditions themselves (21, 22, 23).

**Blocked by:** 17, 24

**From 17:** [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md) records why §9.14 has no owner in 18–25 and the skeleton module this ticket starts from.

**From 24:** budget emits a patch-rate counter, a gauge of the pending changes the budget holds, a 429 counter and the pause state (paused or not, and its length), the poll queue depth and a counter of polls skipped under `NoOverlap`. The names are this ticket's.

**From 19:** config raises one Event on a Deployment per invalid override key, on entry, whose message config's `message` renders; this ticket names its reason. An unknown key under the `knarr.io/` prefix raises no Event and is logged once per discovery cycle it is present in; this ticket names the log line and confirms the cadence.

**MVP critical path:** no. The MVP runs without named metrics; operators need them to trust it.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] The `elicit` skill is run with the maintainer in a live session.
- [x] Every open question in `docs/specs/observability.allium` is settled and recorded before any clause is written.
- [x] The clauses cover the metrics for poll results, cost distribution, patch rate and errors; the budget's throttled-pending count, 429 count, pause state, poll queue depth and skipped polls; the Event reasons for an absent contract, a rejected patch, a failed cleanup and a conflict; the log fields and what is never logged; and the probes. `check-specs` and `analyse-specs` report nothing.
- [x] The hand-back gives the `plan-spec` obligation count and amends ticket 32's acceptance checks with the Event and metric each invariant emits.

## Settled

The live session ran on 2026-10-12 in seven rounds of four questions; the maintainer took the recommended option every time. The module and this table are the record; no decision record is written, as 18, 20, 22 and 24 did.

| # | Point | Decision | Rejected |
| --- | --- | --- | --- |
| 1 | Labels | Per-workload metrics carry `deployment` (≤ ~50 values) plus small fixed enums; never `pod`, never `namespace` (one install per namespace, §9.18). Per-pod detail lives in Events and logs. | No workload labels; `deployment` and `pod`. |
| 2 | Event conventions | UpperCamelCase reasons; every knarr Event is type Warning; reporting component `knarr`. The API group (core v1 or events.k8s.io) stays 41's. | Mixed Normal/Warning; knarr-prefixed reasons. |
| 3 | Log format | JSON lines on stdout through OTP `logger`: `time`, `level`, `msg` and the line's own fields. | logfmt; plain text. |
| 4 | Metric naming | `knarr_<subject>_<unit>`; counters end `_total`; durations in seconds; timestamps in unix seconds; booleans are 0/1 gauges. `knarr_startups_total` stays; prometheus.erl's VM collectors keep their own names. | A subsystem segment (`knarr_<subsystem>_…`). |
| 5 | Poll results | `knarr_polls_total{deployment, reading}`, reading = worker_contract's six `Reading` kinds verbatim; `knarr_poll_duration_seconds` histogram install-wide (no `deployment`), fixed buckets 0.01…30 s. | Counter only; per-Deployment histogram. |
| 6 | Cost distribution shape | `knarr_pods{deployment, tier}` gauge: tier `drained` or cost_mapping's integer `tier` under the Deployment's own thresholds. | Raw-cost histogram (buckets misalign with overrides); both. |
| 7 | Cost basis | The applied value the marker records (what the ReplicaSet controller ranks); a pod knarr has not written is tier 0; yielded or foreign annotations are excluded (the ownership gauge counts them). | The last valid reading. |
| 8 | Patch outcomes and the 422 | `knarr_patches_total{deployment, purpose, result}` at response time, result = accepted, precondition_failed (422), rejected (400/403), throttled (429), error; purpose = apply, yield, cleanup. `knarr_patch_rejections_total{deployment, purpose}` when a rejection is known: 400/403 at once, a 422 when the next LIST classifies it (ownership `Rejected`). Failed cleanup = rejections with purpose cleanup. | Defer the 422 result to classification (a restart drops it); send-time only (a 422 rejection is invisible). |
| 9 | Pauses and 429s | `knarr_paused{scope}` 0/1 and `knarr_pause_seconds{scope}` (length of the current pause as set, 0 when not paused), scope = patch, list. 429s are result `throttled` on `knarr_patches_total` and on `knarr_lists_total{resource, result}` (resource = pods, deployments), never counted twice. | A dedicated `knarr_throttled_total`; a pause-until timestamp. |
| 10 | Backlog | `knarr_patches_pending{deployment}`; `knarr_patch_pending_oldest_seconds` (install-wide age of the oldest `due_since`); `knarr_poll_queue_depth` install-wide; `knarr_polls_skipped_total{deployment}` (NoOverlap). | Install-wide only; per-Deployment without the age. |
| 11 | Ownership and pod states | `knarr_annotations{deployment, annotation, standing}`, standing = owned, conflict, yielded, foreign (unowned not counted; the foreign gauge Adoption requires); `knarr_yields_total{deployment, annotation}`; `knarr_pods_not_ready_with_cost{deployment}` (ReadinessWarning); `knarr_pods_contract_absent{deployment}`. | A gauge per state; counting unowned too. |
| 12 | Install signals | `knarr_last_discovery_timestamp_seconds` (end of the last cycle with both LISTs succeeding) and `knarr_discovery_duration_seconds`; `knarr_events_total{reason, result}` (created, failed); `knarr_targets{kind}` (deployments, pods, terminating included); `knarr_build_info{version}` = 1. | — (all four taken). |
| 13 | Yield Event reason | `AnnotationYielded`. | `OwnershipConflict`; `AnotherWriter`. |
| 14 | Absent-contract Event | Reason `ContractAbsent`, involvedObject the Deployment, one create attempt each time a pod enters the absent state (when that is, is 21's), message naming the pod and its last reading. | Once per Deployment while any pod is absent; on the Pod. |
| 15 | Rejected-patch Event | Reason `PatchRejected` on the Pod, one create attempt on the first rejection of a run for that pod; an accepted patch ends the run; in memory only, so a restart raises it once more. The counter counts every rejection. | Every rejection; once per pod's life. |
| 16 | Failed-cleanup Event | Own reason `CleanupRejected`, same target and cadence as `PatchRejected`; the message says the stale annotations stay and names them. | `PatchRejected` for every purpose. |
| 17 | Log levels | error: knarr cannot do its job (token or namespace unreadable, a LIST failing, a crash); warning: an operator should act (each Event's cause, foreign annotation, NotReady with cost, a failed Event create); info: knarr's own life (startup, a pause starting and ending, token file changed); debug: per poll and per patch. Default info, set by OTP application configuration. | Default warning; no debug level. |
| 18 | State-line cadence | On entry, in memory: one line when a pod (and annotation) first enters foreign, NotReady-with-cost, absent or rejected in this process; none while it stays; again on re-entry; a restart logs each current state once. Gauges carry "still in it". | Each LIST; foreign on each LIST only. |
| 19 | Never logged | The service-account token and the Authorization header (TokenReload logs only sha256 and expiry); worker response bodies (only reading kind, status, and for valid cost and accepting); apiserver response bodies and whole Pod objects (only status code, pod name, the owned values involved); raw URLs with query strings (poll as pod + path). | — (all four taken). |
| 20 | Events also log | Every Event's cause logs one warning line with the reason and the same fields, whether or not the create succeeds, so a lost Event still leaves a trace. | Log only when the create fails. |
| 21 | Liveness | `/healthz` is process-level only: 200 while the listener serves and the supervision tree is up; never depends on the apiserver or workers (a restart refills the bucket, budget `Restart`). A stalled loop is an alert on `knarr_last_discovery_timestamp_seconds`. | 503 after N × list_interval without discovery. |
| 22 | Readiness | `/readyz` is 503 until the first discovery cycle completes with both LISTs succeeding, then 200 for the life of the process (latched). | While discovery is fresh; as today. |
| 23 | Probe home | Amend knarr.allium `Diagnostics` in place (Readiness gains the first-discovery condition; Metrics points at observability's catalogue); observability names what the probes report and points back. | Move Health/Readiness/Metrics into observability. |
| 24 | Series life | A Deployment leaving the target set removes every series labelled with it, counters included. A terminating pod counts only in `knarr_targets`; the tier, standing and pod-state gauges exclude it. A restart starts counters at 0; gauges are rebuilt from the first discovery cycle. | Keep counters until restart; include terminating pods. |
| 25 | Event messages | ContractAbsent (Deployment): `pod <pod>: no knarr status contract at port <port> path <path>; last reading <reading>`. PatchRejected (Pod): `<keys>: the apiserver rejected knarr's patch with <status>; the previous annotations stay and knarr tries again no sooner than the patch interval`. CleanupRejected (Pod): `<keys>: the apiserver rejected knarr's cleanup with <status>; <key>=<value> stays on the pod until removed, for example kubectl annotate pod <pod> <key>-`. `<keys>` are full annotation keys; a 422 classified as a rejection reports 422. | Shorter messages without the retry note or kubectl hint. |
| 26 | Log fields | Always `time` (RFC 3339 UTC, milliseconds), `level`, `msg`. When they apply: `deployment`, `pod`, `annotation` (owned short name), `reading`, `cost`, `accepting`, `standing`, `purpose`, `status`, `reason`, `applied`, `found`, `retry_after_seconds`, `pause_seconds`, `scope`. Flat, snake_case, same names as metric labels where they overlap. | Nested `pod`/`api` objects. |
| 27 | Later rows | observability states the conventions as invariants; tickets 19, 21, 23 and 25 add their own rows under them with `tend` when they settle, without reopening 30. | Reserve likely names now. |
| 28 | Buckets | `knarr_poll_duration_seconds` and `knarr_discovery_duration_seconds` share fixed buckets 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, +Inf; not derived from config. | Buckets derived from the poll timeout. |

Boundaries kept: `observability` names what is emitted and the conventions; the emission points stay with their owners. When a pod's contract is absent is `reconcile`'s (21); when a patch is rejected or another writer is seen is `ownership`'s (22); when a cleanup is made is `lifecycle`'s (23); the schedule, pending set and pauses are `budget`'s (24); the Event create and its API group are `k8s_client`'s (41); the probe responses are knarr's `Diagnostics`.

## Hand-back notes

### What changed

- `docs/specs/observability.allium`: the four open questions became the value types `Label`, `Series`, `Annotation`, `AbsentEvent`, `RejectedEvent`, `Entry`, `Field` and `LogLine`, the enumerations `ReadingKind`, `Purpose` and `Level`, and five contracts. `Catalogue` (`tier`, `patch_result`, `list_result`, `retire`; invariants `Naming`, `Labels`, `Polls`, `Tiers`, `Patches`, `Budget`, `Standing`, `Install`, `Buckets`, `SeriesLife`, `LaterRows`, `Pure`) names every metric in rows 4–12, 24, 27 and 28. `Events` (`reason`, `rejected_message`, `absent_message`; `Conventions`, `Yielded`, `ContractAbsent`, `Rejected`, `CleanupRejected`, `AlsoLogged`, `Pure`) carries rows 2, 13–16, 20 and 25. `Cadence` (`entered`; `OnEntry`, `Restart`, `Pure`) is the one on-entry rule the Events of rows 14–16 and the state lines of row 18 share. `Logs` (`render`, `enabled`; `Format`, `Levels`, `StateLines`, `NeverLogged`, `Pure`) carries rows 3, 17–19 and 26, with `config.log_level` defaulting to `info`. `Probes` (`Liveness`, `Readiness`) states rows 21–22 and points at knarr's `Diagnostics`. No `use` of another module (Decision 0009); cross-references are by module and clause name.
- `docs/specs/knarr.allium` `Diagnostics`, amended in place (row 23): `Health` depends on the process alone; `Readiness` latches at the first discovery cycle with both LISTs succeeding, and a configuration that runs no discovery cycle, as the gate runs it under `NoPodEffects`, is ready once the supervision tree starts, so today's skeleton still conforms; `Metrics` points at `Catalogue`. No signature changed: `respond` already takes `ready`.
- `docs/specs/k8s_client.allium`: `Verbs` names the four Events the create carries, on a Pod or (ContractAbsent) a Deployment by name and uid, so the Deployment LIST returns uids; the header and the `Pod` comment follow. The Role is unchanged.
- `docs/OVERVIEW.md`: §9 item 14 points at the module as settled; the §8 failure-mode rows and the §5 bullets for an absent contract, a rejected patch or cleanup, another writer and a NetworkPolicy block name their reason and metric.
- Each signal has one emitter: 46 sends every patch, LIST and poll, so it emits `knarr_patches_total`, `knarr_lists_total` and `knarr_poll_duration_seconds`; 31 counts the readings; 32 asserts the patch results and emits the rejection and yield signals.
- Tickets: 32's acceptance checks name the Event and metric each invariant emits; 31, 41 and 46 have their generic observability boxes replaced with the named signals; `**From 30:**` lines in 19, 21, 23, 25, 31, 32, 34, 41 and 46. No new ticket: 31 and 32 already depend on 30, so the [bootstrap README](../README.md) graph is unchanged.

### What was verified

- `just check-specs` and `just analyse-specs`: 11 specifications, no diagnostics and no findings. Before drafting, a scratch module in `ai_tmp/` showed what the pinned checker (Allium 3.6.1) accepts: a named enum as a parameter type and as a config type (`log_level: Level = info`), `Integer?` as a parameter, and a contract with invariants and no signatures; an enum used only as a return type is flagged unused, as a value type is, so `patch_result`, `list_result` and `tier` return the label as `String`.
- `just plan-spec docs/specs/observability.allium`: 30 obligations. `knarr.allium` stays at 11 and `k8s_client.allium` at 8; both amendments are prose.
- `just docs-check` passes, including the links into `docs/specs/observability.allium`.
- `just check` ends with "All checks passed and the worktree is unchanged." Nothing under `src/` or `test/` changed, and nothing ran against a cluster or the network.

### Choices a maintainer may reverse

- `rejected` and `cleanup_rejected` are separate runs in `Cadence`, so a `CleanupRejected` still raises after a `PatchRejected` on the same pod in one run (row 16's "same cadence" read per reason). Any accepted patch ends both. One sentence to change.
- `Tiers` leaves out a pod whose pod-deletion-cost stands `conflict` as well as yielded and foreign (row 7 named the last two): during a conflict the annotation is another writer's value, not the marker's. `knarr_annotations` counts it.
- `knarr_lists_total`'s result is `succeeded`, `throttled` or `error` (row 9 named only `throttled`); a 400 or 403 on a LIST is `error`. `patch_result` maps every status outside 2xx, 400, 403, 422 and 429, 404 and 409 included, and a transport failure to `error`.
- `knarr_pause_seconds` is the pause from the 429 that last set it to its `until`; `knarr_discovery_duration_seconds` observes every cycle sent, failed ones included; `knarr_polls_total` does not count a response budget's `Leaving` discards.
- `AlsoLogged` adds a second warning line when an Event create fails, which row 17 lists at warning; the cause's own line is logged either way (row 20).
- Log field values are JSON text (a string, an integer or a boolean), and `render` writes `time`, `level`, `msg`, then the fields in the order given.
- 30 is not added to the Blocked by of 41, 46 or the elicitation tickets that carry a `**From 30:**` line: 30 lands first, and Decision 0009's rows keep their 2026-10-08 class, as 22's and 24's did.
- Whether a restart re-enters the contract-absent state, and so raises `ContractAbsent` again, is left to 21 rather than fixed here.
- `Readiness` in knarr.allium keeps a configuration with no discovery cycle ready at supervision start, which is what keeps the gate (and every configuration until 31 builds discovery) passing. 31 must keep the gate adapter ready once discovery exists.

### What later tickets need

- **19, 21, 23, 25:** add your own metrics, Events and log lines under `Catalogue` `Naming`, `Labels`, `SeriesLife` and `LaterRows`, `Events` `Conventions` and `Logs` `Format` and `Levels`, with `tend`, without reopening 30. 21 decides when a pod enters the contract-absent state (`ContractAbsent`, `knarr_pods_contract_absent`); 23 what counts as a cleanup (purpose `cleanup`, `CleanupRejected`); 25's annotation is already covered by `knarr_annotations{annotation="safe-to-evict"}`.
- **31:** `knarr_polls_total`, the tier, standing, readiness and absent gauges, discovery freshness and duration, `knarr_targets`, `knarr_build_info`, `retire`, the `/readyz` latch, the JSON formatter with `config.log_level`, and `Cadence` `entered`. The gate adapter must still reach ready.
- **32:** the Events `PatchRejected`, `CleanupRejected` and `AnnotationYielded`, `knarr_patches_total`, `knarr_patch_rejections_total`, `knarr_yields_total`, and the foreign line with no Event, as its amended boxes say.
- **34:** a metrics and alerting page may carry the catalogue, the staleness alert on `knarr_last_discovery_timestamp_seconds`, the four reasons and their messages, and the log fields and level.
- **41:** the Event create on a Pod or a Deployment by name and uid, type Warning, reporting component `knarr`, the API group yours; the Deployment LIST returns uids; `knarr_events_total`; the statuses `patch_result` and `list_result` read.
- **46:** the one emitter of every patch and LIST result and of the poll duration, since it sends them, and the budget signals by name: `knarr_patches_total`, `knarr_patches_pending`, `knarr_patch_pending_oldest_seconds`, `knarr_paused` and `knarr_pause_seconds` by scope, `knarr_lists_total`, `knarr_poll_queue_depth`, `knarr_polls_skipped_total` and `knarr_poll_duration_seconds`.
