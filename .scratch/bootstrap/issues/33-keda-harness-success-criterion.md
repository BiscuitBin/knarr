# 33: KEDA e2e harness and the "fewer busy pods killed" criterion (§3, §9.16)

**Context:** The first §3 success criterion says that on a KEDA-scaled Deployment running a mixed fake-worker load on kind, fewer busy pods are killed on scale-in than in a baseline run without knarr. §9.16 says the testing strategy sets its threshold. Tickets 23 and 24 hand §9.16 the restart and write-budget thresholds; no ticket owns this first criterion or the harness that measures it. Ticket 29 builds the fake worker and names the sink that records a busy kill; it leaves the harness and the run to round 2.

**What to build:** A `just` recipe, outside the aggregate `check`, that runs a KEDA-scaled Deployment of the fake worker on the kind tier from [Decision 0007](../../../docs/decisions/0007-local-cluster.md), drives a mixed load through the control endpoint, scales in, counts busy kills from 29's sink, and compares the count with a baseline run without knarr against a threshold the maintainer sets.

**Non-goals:** The GKE acceptance run ([39](39-gke-production-rollout.md)). Load beyond the v1 scale target from 24. The budget clauses themselves: [46](46-spec-then-build-poll-schedule-and-patcher.md) builds them.

**Blocked by:** 24, 29, 31, 32, 46

**From 17:** [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md), map row for §9.16.

**From 24:** the write-budget threshold for §9.16 is at most 5·W + 10 patches in any W-second window at the defaults (5 per second sustained, burst 10), so 310 in any minute, within one run of knarr: a restart refills the bucket, so a window spanning a restart may see up to 10 more; budget `Threshold` states it and [46](46-spec-then-build-poll-schedule-and-patcher.md) builds the bucket.

**MVP critical path:** yes. The MVP is measured with it.

**Status:** needs-human, round 2. The threshold is the maintainer's call.

- [ ] The maintainer sets the threshold, and it is recorded in OVERVIEW §3 next to the criterion.
- [ ] The run records the patch rate and shows it stayed within the §9.16 write-budget threshold from 24.
- [ ] The recipe installs KEDA at a pinned version on the kind tier, scales the fake worker through a ScaledObject, and runs the same load with and without knarr.
- [ ] Busy kills are counted from the sink 29 named, and the two counts and the threshold are printed in one line the hand-back quotes.
- [ ] The recipe is not in the aggregate `check`, and the testing reference says when to run it.
- [ ] The hand-back records the KEDA version, the kind version and the run time.
