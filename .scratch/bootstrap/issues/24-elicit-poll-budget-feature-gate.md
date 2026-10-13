# 24: Elicit: poll interval, concurrency, write budget and feature-gate check (§9.8, §9.11)

**Context:** OVERVIEW §9.8 leaves open:

- numeric defaults
- a v1 scale target (pods, Deployments, interval)
- the LIST cadence
- limits per Deployment and per cluster
- the expected API write rate

The §8 failure-mode table adds API throttling (APF, 429) and poll fan-out. §9.11 offers three ways to handle the `PodDeletionCost` feature-gate prerequisite:

- (i) document only
- (ii) a startup self-test
- (iii) a periodic check

A §3 success criterion requires that the patch rate stays within the configured write budget.

**What to build:** Allium clauses for polling, concurrency, the write budget, back-off and the feature-gate check, settled with the maintainer.

**Non-goals:** Metric names and Events in general (§9.14, round 2).

**Blocked by:** 17

**MVP critical path:** yes. The write budget is an MVP success criterion.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] The `elicit` skill is run with the maintainer in a live session.
- [x] Every open point above is settled and recorded before any clause is written, including the write-budget threshold handed to §9.16.
- [x] The clauses cover the poll schedule, bounded concurrency with jitter, no overlapping polls, the per-pod and global write limits, APF and 429 back-off, and the chosen feature-gate check. `check-specs` and `analyse-specs` report nothing. (The check is settled as none: a bare `@guidance` on `WriteBudget` says so and points at the prerequisite page.)
- [x] Any open question 19 left on the default or valid range of a poll, concurrency or write-limit override is closed.
- [x] The hand-back gives the `plan-spec` obligation count and drafts the spec-then-build follow-up ticket.

## Settled

The live session ran on 2026-10-12 in six rounds. The maintainer departed from the recommendation twice (a 500-pod scale target over 200, and a 30-second poll interval over 10) and withdrew one proposal, a 300-second LIST cadence, after the round-2 check showed the LIST is also where `deletionTimestamp`, the drained `-1` case and overridden thresholds are learned. The feature-gate round needed one correction (the gate is beta, not GA) and its sources were fetched from the network with the maintainer's request for links as the authorization. Rows 9, 14 and 18 record precision fixes made in review rather than questions put. The module and this table are the record; no decision record is written, as 18 and 20 did.

| # | Point | Decision | Rejected |
| --- | --- | --- | --- |
| 1 | Scale target | 500 polled pods across up to 50 opted-in Deployments per install (one namespace, one replica). | 200 pods (recommended); 50 pods. |
| 2 | Poll interval | 30 seconds by default. | 10 seconds (recommended); 5 seconds. |
| 3 | LIST cadence | 60 seconds, its own timer, independent of the poll interval. The maintainer first proposed 300 s (pods matter only past the lowest threshold); withdrawn in round 2 because the LIST is also where `deletionTimestamp`, the drained `-1` case and overridden thresholds are learned. | 300 s; a multiple of the poll interval; 30 s. |
| 4 | Per-poll timeout | 5 seconds, shorter than the interval (§4.2). worker_contract `Served` and `Transport` already refer to it. | 2 s; 10 s. |
| 5 | Jitter | Each pod's schedule starts at a random phase within one interval; each next poll fires at interval plus a random delay of 0 to 10% of the interval. Delay only, never early. | Phase only; ±20%. |
| 6 | Concurrency | 64 in-flight polls per install, no per-Deployment bound. Over the bound polls queue and the effective interval stretches (§8 "costs refresh more slowly"). | 64 + 16 per Deployment; 32 global. |
| 7 | No overlap | A poll due while the pod's previous poll is in flight is skipped; the next fires on schedule. | Run it right after the in-flight one returns. |
| 8 | Per-pod patch interval | 60 seconds between patches to one pod, counted from the last patch attempt whatever its outcome. A change due inside it stays pending and is re-derived from the latest reading when it ends (31). | 30 s; 300 s; counting from the last successful patch. |
| 9 | Global patch budget | Token bucket: 5 patches per second per install, bucket of 10, integer tokens refilled per whole second. The §9.16 threshold handed to 33 follows from the bucket (a precision fix in review, not put as a question): in any window of W seconds at most 5·W + 10 patches, so 310 in a minute. | 10/s burst 20; 2/s burst 5. |
| 10 | 429 back-off | Exponential: the first 429 pauses patching 1 s, doubling per consecutive 429 to a 60 s cap; a Retry-After header raises the pause to at least its value. A successful patch resets it. Pending changes stay pending and are re-derived when the pause lifts. | Fixed 10 s; cap of 5 min. |
| 11 | Pause scope | A 429 pauses every patch of the install; polling and the LIST continue. A 429 on the LIST skips that cycle with the same back-off shape and keeps the previous target set. | Per pod only; pausing polls too. |
| 12 | Pending order | At most one pending change per pod, re-derived from its latest reading when it goes; pods served oldest-due first. No priority for drained or terminating changes. | Round-robin by Deployment; drains first. |
| 13 | Across restart | Per-pod interval and back-off reset on restart; the global bucket alone bounds the startup repair (23). The marker timestamp is not read for budgeting. | Count the per-pod interval from the marker timestamp. |
| 14 | Feature gate | (i) Document only. knarr makes no check and keeps its namespaced Role. The prerequisite page (34) carries: the gate is beta since 1.22, on by default, needed on both kube-apiserver and kube-controller-manager; GKE enables beta gates by default, may disable one per version, and allows changes only on alpha clusters; the check `kubectl get --raw /metrics \| grep 'kubernetes_feature_enabled{name="PodDeletionCost"'` (1.26+, apiserver gate only); the behavioural test (two Ready pods of one Deployment on the same node or on nodes with equal counts of its pods, the older annotated `-1`, scaled down by one: with the gate on the older goes, with it off the newer goes, since ranking then prefers the pod that became Ready more recently; a precision fix in review, replacing "annotate the oldest Ready pod", which left readiness and node spread uncontrolled, criteria ranked before cost and age, so either pod could go whichever way the gate was set); consequences when off (writes harmless but useless; `safe-to-evict` and Karpenter unaffected). Sources: the kubernetes.io feature-gates and ReplicaSet pages, KEP-2255, the GKE feature-gates page. | (ii) a startup read of the apiserver metric, warn only (needs a ClusterRole for `/metrics`, proves only the apiserver gate); (iii) a periodic read. |
| 15 | Per-Deployment overrides | Poll interval (5 s to 300 s, default 30) and per-pod patch interval (0 s to 3600 s, default 60). The timeout stays install-wide. Keys and invalid-value handling are 19's. | Adding a per-Deployment timeout; no overrides. |
| 16 | Install-wide values | Configurable at install through OTP application configuration, the mechanism knarr.allium's `Listening` already uses for the bind address and port, each with a default and valid range: poll interval 5 s to 300 s (30), timeout 1 s to below the poll interval (5 s), LIST 10 s to 600 s (60 s), concurrency 1 to 1024 (64), global rate 1 to 100 per second (5) with bucket 1 to 200 (10), back-off cap 1 s to 600 s (60 s). | Fixed constants in v1. |
| 17 | Rejected patch (non-429) | The per-pod interval from the last attempt is the only bound: at most one attempt per pod per 60 s, re-derived from the latest reading. No per-pod back-off. Event and metric are 30's. | Per-pod exponential back-off on consecutive rejections. |
| 18 | Expected write rate | Recorded in the module header: about 17 status GETs/s on the pod network at 500 pods, one pod LIST and one Deployment LIST per minute, a common-case patch rate under 0.5/s (about two writes per task: one per threshold crossed and one removal on idle), and a worst case of 500 ÷ 60 s ≈ 8.3/s, which the bucket caps at 5·W + 10 patches per W seconds. All durations are integer seconds. | Recording only the cap. |
| 19 | Override floor | A poll-interval override is valid only when greater than the install-wide timeout; otherwise it is an invalid value under config's rule (19). | Clamping the timeout per Deployment; a 10 s override minimum. |
| 20 | Pods leaving | A terminating pod stays on the poll schedule until it leaves the LIST, and its pending change is discarded when `deletionTimestamp` is first seen. A pod that leaves the LIST leaves the schedule and its pending change is dropped. | Stop polling at `deletionTimestamp`. |
| 21 | Retry-After beyond cap | The pause is the greater of the computed back-off and Retry-After, uncapped; the 60 s cap bounds only the exponential growth. | Cap wins. |

Boundaries kept: `budget` owns when a poll and a LIST fire, how many polls are in flight, whether a due patch may go now, and the pause after a 429. What a poll reads is `worker_contract` (18, built by 43); whether a change is due and its re-derivation from the latest reading are `cost_mapping` and `reconcile` (20, 21, 31); the patch itself, the marker and other writers are `ownership` and `k8s_client` (22, 41); the override keys and an invalid override are `config` (19); the metric and Event names are `observability` (30); the prerequisite page is 34's.

## Hand-back notes

### What changed

- `docs/specs/budget.allium`: the seven open questions became the value types `Schedule`, `Pending`, `Bucket` and `Pause`, the `PollSchedule` contract (`phase`, `next`, `admit`, `on_list`; invariants `Interval`, `Timeout`, `Phase`, `Jitter`, `NoOverlap`, `Concurrency`, `ListCadence`, `Leaving`, `Restart`, `Pure`), the `WriteBudget` contract (`refill`, `allow`, `pause`, `order`; invariants `PerPod`, `Bucket`, `Pending`, `BackOff`, `PauseScope`, `Restart`, `Threshold`, `Pure`, and a bare `@guidance` for the feature gate), and a `config` block of ten values. The header records the scale target and the expected write rate (row 18). `just plan-spec docs/specs/budget.allium` reports 26 obligations.
- Sibling modules, each still its owner's: `k8s_client`'s §9.10 open question now also asks for a failed patch and a failed list as values carrying the status and Retry-After, which `BackOff` and `PauseScope` read; `config`'s overrides question names the two budget overrides with default and range; `worker_contract`'s `Transport` and `Served` cite `config.poll_timeout` now it has a value. `knarr.allium` is unchanged (budget was already listed).
- `docs/OVERVIEW.md`: §4 steps 2 and 4, §6 "How Knarr limits update frequency" and the feature-gate table row, the §8 failure-mode rows for API throttling, poll fan-out and the gate, and §9.8 and §9.11 point at the module; the glossary gains **Write budget**. `docs/overview-explainer.html`'s one budget mention (section 2's caption) follows.
- [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md): the `budget` scope and the §8 gate row read "documented prerequisite" with no check; rows keep their 2026-10-08 class; the Consequences record the amendment.
- Tickets: [19](19-elicit-configuration-schema.md) carries the two overrides; [31](31-spec-then-build-reconcile-core.md)'s LIST box names 60 s; [33](33-keda-harness-success-criterion.md) carries the §9.16 threshold and 46 in its Blocked by; [40](40-mvp-release.md) carries 46 in its Blocked by, so the MVP release ships the budget; [34](34-user-guides.md) carries the prerequisite page content; [41](41-k8s-client-spec-then-build.md) gains the failed-patch and failed-list values; [43](43-status-poller.md) names the 5-second timeout and points at 46 for the schedule; [30](30-elicit-observability.md) lists what budget emits. New ticket [46](46-spec-then-build-poll-schedule-and-patcher.md) builds the module; the [bootstrap README](../README.md) graph and waves carry it.

### What was verified

- `just check-specs` and `just analyse-specs`: 11 specifications, no diagnostics and no findings. The pinned checker (Allium 3.6.1) accepts `Duration` config defaults written as `30.seconds` and `1.second`, and `Timestamp`, `Duration`, `Boolean`, `Timestamp?`, `Duration?`, `List<String>` and `List<Schedule>` as signature parameter types; a bare `@guidance` on a contract passes, as worker_contract's does.
- `just plan-spec docs/specs/budget.allium`: 26 obligations (four value types at two each, eight contract signatures, ten config defaults).
- `just docs-check` validates 28 pages and 32 canonical topics, including the links into `docs/specs/budget.allium`.
- `just check` ends with "All checks passed and the worktree is unchanged." Nothing under `src/` or `test/` changed, and nothing ran against a cluster.
- An adversarial review by Codex (gpt-6-astra, session 01a132e2) reported ten findings, all valid and all applied: `Threshold` holds within one run; 46 blocks 40; a passed due time is skipped on the ladder, not pulled to now; the two LISTs form one discovery cycle with one pause; a pause is never shortened; a `patch_interval` override of 0 stays valid with its consequence stated; `on_list` takes the joining schedules the caller phased per pod; the per-pod interval is budget's only hold and ownership's longer hold sits on top; the gate test uses two pods on one node; and the header states the workload model behind the common-case rate (the review plan's figure of 15 such completions a second was an arithmetic slip; 15 a minute follows from 0.5 patches/s at two writes per task). Two were decisions put to the maintainer, who chose that 46 blocks 40 and that the 0 override stays. `plan-spec` still reports 26 obligations.

### Choices a maintainer may reverse

- `Jitter` reads row 7's "on schedule" as a ladder: each pod's due times climb from its phase by interval plus a fresh draw, a rung already past is skipped, and the next poll is due on the first rung after now, never right after a late return. The rejected reading, a passed due time becoming due now, was in the first draft and the review removed it. One sentence to change.
- `ListCadence` and `PauseScope` treat the pod LIST and the Deployment LIST as one discovery cycle: a failure or 429 on either skips the whole cycle, and the LIST run ends only when both succeed in one cycle. Two independent LISTs is one sentence to change.
- `BackOff` reads row 10's "a successful patch resets it" strictly: a 2xx resets the run and leaves `until` as it is, a non-429 rejection leaves the Pause as it is, and no call ever shortens `until`. `PauseScope` keeps two pauses under one rule, one for patches and one for the cycle, so a short patch pause never suppresses a LIST tick (row 11). Each is one sentence to change.
- `PerPod` keeps 0 as a valid `patch_interval` override, as row 15's range says, and states the consequence: the bucket alone bounds that Deployment's pods, after a rejection too, with no floor. The review asked whether 0 should be refused; the maintainer kept it.
- `Schedule` carries `outstanding` for a poll queued or sent, so `NoOverlap` covers the queue as well as the wire. If queued polls should be collapsed differently, split the flag.
- `WriteBudget` has `refill` as its own signature so `Bucket` sits in a parameter position and the whole-second refill is testable alone; it could fold into `allow` if 46 prefers one call.
- `pause` takes the status and Retry-After as plain values. k8s_client's contract returns only `Pod` today, so 41 decides the error value's shape; the clause reads the status and the header, nothing else.
- The pending set is served oldest-due first with no priority (row 12). If drains should jump the queue, `order` is the one place to change.
- The threshold handed to 33 is stated at the defaults (5·W + 10). A harness that changes the rate or burst restates it.
- Decision 0009's rows keep their 2026-10-08 class, as 18's and 20's do.
- No decision record for choosing (i) document only on the gate; the module's `@guidance`, OVERVIEW §6 and this ticket are the record.

### What later tickets need

- **19:** two overrides, `poll_interval` (whole seconds, 5 to 300, default 30, valid only when greater than the install-wide `poll_timeout`) and `patch_interval` (whole seconds, 0 to 3600, default 60; 0 is valid and leaves the global bucket as the only bound on that Deployment's pods, after a rejection too, with no floor applied). The timeout has no override. The key syntax and what happens on an invalid override are yours.
- **21:** the per-poll timeout is 5 seconds; a `timed_out` reading arrives at most once per effective poll interval per pod, and a queue under load stretches that interval, so a window counted in polls and one counted in time differ under load.
- **23:** the bucket alone bounds the startup repair: at most 5·W + 10 patches in any W seconds, and every pod is patchable at once after a restart. The marker timestamp is not read for budgeting.
- **30:** budget emits a patch-rate counter, a gauge of pending changes held by the budget, a 429 counter and the pause state (paused or not, and its length), the poll queue depth, and a counter of skipped polls under `NoOverlap`. The names are yours.
- **31:** the LIST runs every 60 seconds on its own timer, and a throttled change is re-derived from the latest reading when its pod's turn comes, as your box already says.
- **33:** the write-budget threshold is at most 5·W + 10 patches in any W-second window, 310 in a minute, within one run of knarr: a restart refills the bucket, so a window spanning a restart may see up to 10 more. 46 builds the budget and is in your Blocked by.
- **34:** the prerequisite page content is row 14.
- **40:** 46 is in your Blocked by: the MVP release carries the schedule and the patcher, so the write budget 33 measures is the one it ships.
- **41:** the client surfaces a failed patch and a failed list as values carrying the response status and the Retry-After header, in seconds; budget reads those two fields.
- **43:** the per-poll timeout is 5 seconds, injected to `send`; the schedule, jitter, concurrency and no-overlap rule are 46's, not yours.
- **46:** build `PollSchedule` and `WriteBudget` with tests from `propagate`, a scheduler and a patcher under supervision, FFI only for the clock if one is needed. Blocked by 24, 31 and 43; 40 and 33 wait for you.
