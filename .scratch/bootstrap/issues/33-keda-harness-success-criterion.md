# 33: KEDA e2e harness and the "fewer busy pods killed" criterion (§3, §9.16)

**Context:** The first §3 success criterion says that on a KEDA-scaled Deployment running a mixed fake-worker load on kind, fewer busy pods are killed on scale-in than in a baseline run without knarr. §9.16 says the testing strategy sets its threshold. Tickets 23 and 24 hand §9.16 the restart and write-budget thresholds; no ticket owns this first criterion or the harness that measures it. Ticket 29 builds the fake worker and names the sink that records a busy kill; it leaves the harness and the run to round 2.

**What to build:** A `just` recipe, outside the aggregate `check`, that runs a KEDA-scaled Deployment of the fake worker on the kind tier from [Decision 0007](../../../docs/decisions/0007-local-cluster.md), drives a mixed load through the control endpoint, scales in, counts busy kills from 29's sink, and compares the count with a baseline run without knarr against a threshold the maintainer sets.

**Non-goals:** The GKE acceptance run ([39](39-gke-production-rollout.md)). Load beyond the v1 scale target from 24. The budget clauses themselves: [46](46-spec-then-build-poll-schedule-and-patcher.md) builds them.

**Blocked by:** 24, 29, 31, 32, 46, 47

**From 17:** [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md), map row for §9.16.

**From 24:** the write-budget threshold for §9.16 is at most 5·W + 10 patches in any W-second window at the defaults (5 per second sustained, burst 10), so 310 in any minute, within one run of knarr: a restart refills the bucket, so a window spanning a restart may see up to 10 more; budget `Threshold` states it and [46](46-spec-then-build-poll-schedule-and-patcher.md) builds the bucket.

**From 23:** the restart threshold for §9.16 has three parts, measured after knarr is stopped and a new process answers `/readyz` 200 (lifecycle `Restart` `Threshold` in [lifecycle.allium](../../../docs/specs/lifecycle.allium), [23's Settled table](23-elicit-cleanup-staleness-restart.md#settled) row 7): (a) for a Deployment whose opt-ins did not change and every worker of which holds a cost whose mapped value equals its applied value through the downtime and the run, the new process's `knarr_patches_total{deployment}` for it stays 0 for 300 s after readiness; (b) a Deployment opted out during the downtime has every owned annotation standing owned removed from its live pods, and the marker of each pod where no record remains, within two list intervals of readiness, 120 s at the defaults; (c) a worker whose cost changed during the downtime so that its mapped value differs from its applied value (cost_mapping `Crossing`) is rewritten within one poll interval plus its jitter plus one patch interval of readiness, about 100 s at the defaults. (b) and (c) are bounds with slack for a run in which no patch is answered 429, so budget's `BackOff` never pauses, and the patches due after readiness fit the bucket within the window; the run keeps its pod count inside that. The harness steps this implies, in one run: deploy at least three Deployments; stop knarr; while it is down, change one Deployment's costs through the fake worker's control endpoint and remove another's opt-in with `kubectl`, leaving the third untouched; start knarr; wait for `/readyz` 200; assert (a) on the untouched Deployment and (b) and (c) on the others from the new process's metrics and the pods' annotations.

**MVP critical path:** yes. The MVP is measured with it.

**Status:** needs-human, round 2. The threshold is the maintainer's call.

- [ ] The maintainer sets the threshold, and it is recorded in OVERVIEW §3 next to the criterion.
- [ ] The run records the patch rate and shows it stayed within the §9.16 write-budget threshold from 24.
- [ ] The run restarts knarr and asserts the three parts of the restart threshold from 23: 0 patches for 300 s for an untouched Deployment, an opt-out made during the downtime cleaned up within two list intervals, and a cost change during the downtime that moves the mapped value rewritten within about 100 s at the defaults, in a run with no 429 and no more patches due than the bucket serves in the window.
- [ ] The recipe installs KEDA at a pinned version on the kind tier, scales the fake worker through a ScaledObject, and runs the same load with and without knarr.
- [ ] Busy kills are counted from the sink 29 named, and the two counts and the threshold are printed in one line the hand-back quotes.
- [ ] The recipe is not in the aggregate `check`, and the testing reference says when to run it.
- [ ] The hand-back records the KEDA version, the kind version and the run time.
