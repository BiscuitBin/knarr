# 33: KEDA e2e harness and the "fewer busy pods killed" criterion (§3, §9.16)

**Context:** The first §3 success criterion says that on a KEDA-scaled Deployment running a mixed fake-worker load on kind, fewer busy pods are killed on scale-in than in a baseline run without knarr. §9.16 says the testing strategy sets its threshold. Tickets 23 and 24 hand §9.16 the restart and write-budget thresholds; no ticket owns this first criterion or the harness that measures it. Ticket 29 builds the fake worker and names the sink that records a busy kill; it leaves the harness and the run to round 2.

**What to build:** A `just` recipe, outside the aggregate `check`, that runs a KEDA-scaled Deployment of the fake worker on the kind tier from [Decision 0007](../../../docs/decisions/0007-local-cluster.md), drives a mixed load through the control endpoint, scales in, counts busy kills from 29's sink, and compares the count with a baseline run without knarr against a threshold the maintainer sets.

**Non-goals:** The GKE acceptance run ([39](39-gke-production-rollout.md)). Load beyond the v1 scale target from 24. The budget clauses themselves: [46](46-spec-then-build-poll-schedule-and-patcher.md) builds them.

**Blocked by:** 24, 29, 31, 32, 46, 47

**From 17:** [Decision 0009](../../../docs/decisions/0009-allium-objective-map.md), map row for §9.16.

**From 24:** the write-budget threshold for §9.16 is at most 5·W + 10 patches in any W-second window at the defaults (5 per second sustained, burst 10), so 310 in any minute, within one run of knarr: a restart refills the bucket, so a window spanning a restart may see up to 10 more; budget `Threshold` states it and [46](46-spec-then-build-poll-schedule-and-patcher.md) builds the bucket.

**From 23:** the restart threshold for §9.16 has three parts, measured after knarr is stopped and a new process answers `/readyz` 200 (lifecycle `Restart` `Threshold` in [lifecycle.allium](../../../docs/specs/lifecycle.allium), [23's Settled table](23-elicit-cleanup-staleness-restart.md#settled) row 7): (a) for a Deployment whose opt-ins did not change and every worker of which holds a cost whose mapped value equals its applied value through the downtime and the run, the new process's `knarr_patches_total{deployment}` for it stays 0 for 300 s after readiness; (b) a Deployment opted out during the downtime has every owned annotation standing owned removed from its live pods, and the marker of each pod where no record remains, within two list intervals of readiness, 120 s at the defaults; (c) a worker whose cost changed during the downtime so that its mapped value differs from its applied value (cost_mapping `Crossing`) is rewritten within one poll interval plus its jitter plus one patch interval of readiness, about 100 s at the defaults. (b) and (c) are bounds with slack for a run in which no patch is answered 429, so budget's `BackOff` never pauses, and the patches due after readiness fit the bucket within the window; the run keeps its pod count inside that. The harness steps this implies, in one run: deploy at least three Deployments; stop knarr; while it is down, change one Deployment's costs through the fake worker's control endpoint and remove another's opt-in with `kubectl`, leaving the third untouched; start knarr; wait for `/readyz` 200; assert (a) on the untouched Deployment and (b) and (c) on the others from the new process's metrics and the pods' annotations.

**MVP critical path:** yes. The MVP is measured with it.

**Status:** done, round 2. The maintainer set the threshold on 2026-10-15, and the harness's first run on kind passed it on 2026-10-16 ([evidence 33](../evidence/33/README.md)).

- [x] The maintainer sets the threshold, and it is recorded in OVERVIEW §3 next to the criterion.
- [x] The run records the patch rate and shows it stayed within the §9.16 write-budget threshold from 24.
- [x] The run restarts knarr and asserts the three parts of the restart threshold from 23: 0 patches for 300 s for an untouched Deployment, an opt-out made during the downtime cleaned up within two list intervals, and a cost change during the downtime that moves the mapped value rewritten within about 100 s at the defaults, in a run with no 429 and no more patches due than the bucket serves in the window.
- [x] The recipe installs KEDA at a pinned version on the kind tier, scales the fake worker through a ScaledObject, and runs the same load with and without knarr.
- [x] Busy kills are counted from the sink 29 named, and the two counts and the threshold are printed in one line the hand-back quotes.
- [x] The recipe is not in the aggregate `check`, and the testing reference says when to run it.
- [x] The hand-back records the KEDA version, the kind version and the run time.

## Hand-back notes

Built on 2026-10-15 in the worktree `33-keda-harness-success-criterion`, and run on kind on 2026-10-16 in the `keda-e2e` workflow, because this host cannot run the amd64 images. The line this ticket owes, from run [38841125203](https://github.com/steven-cutting/knarr/actions/runs/38841125203/job/116781200596) at `01125a8`:

```text
busy kills: baseline 4 of 9 victims over 3 rounds, knarr 0 of 9; threshold knarr 0 per round and baseline >= 1: PASS
```

KEDA 2.21.0, kind v0.33.0 with node image v1.35.8. The harness ran for 672 s and the job for 12 min 40 s. Restart (a) held for 300 s, (b) landed at readiness against a bound of 120 s, and (c) landed at 25.7 s against 93 s, with no throttled result and no pause. The patch rate peaked at 15 in 60 s under `deploy/e2e-fast` and at 1 after the restart, against 310. [Evidence 33](../evidence/33/README.md) has the transcript and why (b) reads 0.0 s.

### The maintainer's decisions (2026-10-15)

- **Threshold:** with knarr, 0 busy kills in every round where the idle pods are at least the scale-in step. The baseline must kill at least 1 busy pod over the run, or the run is void. Recorded in [OVERVIEW §3](../../../docs/OVERVIEW.md#success-criteria-v1-thresholds-set-in-916).
- **Scale-in:** the harness patches the ScaledObject's `minReplicaCount` and `maxReplicaCount`, and KEDA's HPA scales the Deployment. The fixture does not change.
- **Intervals:** `deploy/e2e-fast` shortens knarr's intervals for the comparison. The restart phase runs `deploy/base` at the defaults.
- **Where it runs:** the gated, non-required `keda-e2e` workflow.

### What changed

- `scripts/checks/keda_e2e.py`: the harness. Its pure judges are `verify_download`, `keda_kustomization`, `scaled_object_bounds`, `pick_busy`, `busy_kills`, `verdict`, `parse_metrics` and `total`, `rate_violations`, `worst_window` and `peak_count`, `judge_untouched`, `judge_cleanup`, `judge_rewrite`, `judge_preconditions` and `restart_deployments`. Around them, an orchestration runs KEDA, the fixture, the baseline and knarr rounds, the verdict line, the restart, the patch rate and a summary. [The KEDA harness page](../../../docs/reference/keda-e2e.md) describes each phase.
- `scripts/checks/cluster.py`: `environment(action, checkout)`, `deploy(...)` and `fake_worker_deploy(...)`, taken out of `main()` unchanged in order, so the harness runs under the same worktree kubeconfig. `keda-e2e` joins `KIND_ONLY`. No image literal was added.
- `fixtures/keda_e2e/keda.json`: KEDA 2.21.0. Its compatibility table covers Kubernetes 1.34 to 1.36. The core YAML is pinned by sha256 `e682084c…5927`, hashed on download because the release publishes none, and the two image indexes by digest, read with `docker buildx imagetools inspect`.
- `fixtures/keda_e2e/scaledobject.json`: targets `fake-worker`, with equal bounds of 6, a cron trigger open one minute a year, and HPA behaviour of 100 % per 15 s with no stabilization window.
- `deploy/e2e-fast/`: list 10 s, poll 5 s, poll timeout 4 s, patch 10 s. Rate and burst stay at the defaults.
- `Justfile` `keda-e2e rounds="3" seed="33"`, outside `check`. `.github/workflows/keda-e2e.yml`, on `workflow_dispatch` and on a pull request labelled `keda-e2e`, with a 60-minute limit.
- `.github/renovate.json`: KEDA's two images disabled, since they move by hand with the YAML's hash. `checker_suite.py`: `keda_e2e` in the `cluster` group, with its script and fixtures as inputs.
- Docs: the new [reference page](../../../docs/reference/keda-e2e.md), registered and linked from `docs/README.md`. Also the testing reference's tiers, the local-cluster how-to, the KEDA row in Decision 0007's pins, and OVERVIEW §3. Decision 0009's row for this threshold stays `open`, as 23's and 24's rows did when their thresholds were set. No CHANGELOG entry, as for 29 and 47's test infrastructure.

### What was verified

- `python3 -m pytest scripts/checks/tests/test_keda_e2e.py`: 43 passed. Each seam's test failed before its code: on a missing function, on its assertion, or, for the two worked patch-rate examples, on a corrected expectation.
- `just test-checkers-selected cluster`: 63 passed. `just docs-check`, `just agents-check` and `just packaging-check` passed.
- `just check` on 2026-10-15 at the staged tree: All checks passed and the worktree is unchanged.
- `just deployment-check`, after `just cluster-install`: every variant renders and validates, `e2e-fast` included, and the release overlay still differs by its two lines. `kustomize build` over the downloaded 2.21.0 core YAML and `keda_kustomization`'s output names both KEDA images by their pinned digest.
- The harness on kind: the `keda-e2e` job of pull request #43's labelled run, above, passed every check. The same push's CI run passed every job, the kind smoke and the fake worker smoke included.
- Not run: `just links-audit` and `just hex-audit`.

### Corrections after review

A `/code-review high` pass on 2026-10-15 found these, each fixed test-first where a judge changed:

- The patch rate summed `knarr_patches_total` over its series and refused a sum that fell. knarr retires a departed Deployment's counters once its cleanup is done (observability `SeriesLife`, `quiet` in `reconciler.gleam`), so the restart phase's opt-out would have failed a correct knarr. `cumulative_patches` now adds each series' rise, and a new series counts from 0.
- `verdict` reported a knarr busy kill as `VOID` when the baseline was void too. `FAIL` now wins.
- The image scan missed `- image:` written as a list item.
- One unreadable scrape line aborted the run after its phases. Such a scrape now counts as failed.
- The scraper thread died silently on any error but `RuntimeError`. It now keeps the error and raises it when the phase ends.
- The restart watch could stop just short of the 300 s scrape (a) needs. It now runs until a scrape at or past 300 s has answered, up to 60 s more.
- The liveness rule is now shared, as `cluster.live`, and the clones' opt-in uses `OPT_IN`.

Not changed: one port forward per settle poll and per control request. The settle loop scrapes only once the annotations have settled, so the cost is small.

### Corrections after adversarial review

A Codex adversarial review on `gpt-6-astra` on 2026-10-15 found two ways a run could pass without the evidence it claims. Each was fixed test-first: every new test failed before its code.

- A pod replaced during a round made its victims four, and `verdict` exempted any round with fewer idle pods than victims, so a busy kill in it passed. The threshold compares the idle pods with the scale-in step, which the split always covers. `round_victims` now fails the run when a survivor was not in the cohort or a kill record names a pod that is not a victim, and `verdict` refuses a round with fewer idle pods than victims instead of exempting it.
- The patch rate passed a segment with fewer than two answered scrapes, printing `ok` beside `no two scrapes`, and a 200 with no samples counted as an answered scrape. `judge_coverage` now requires at least two answered scrapes and no gap over 30 s between them or at either end of the segment, and fails the run with `INVALID` otherwise. `parse_metrics` counts a scrape without `knarr_build_info`, which knarr sets at startup, as failed.

These landed after the recorded run at `01125a8`. Its transcript shows three victims in every round and 78 and 299 answered scrapes, but it kept no kill records or scrape times, so it cannot show that no extra kill or long gap occurred, and the harness that produced it was the older one. The 30 s bound is the time a port forward has to come up, not a measured gap: the recorded run kept no scrapes.

Verified: `python3 -m pytest scripts/checks/tests/test_keda_e2e.py`, 57 passed; `just test-checkers-selected cluster`, 80 passed; `just docs-check`; and `just check` at the staged tree: All checks passed and the worktree is unchanged. The harness has not been rerun on kind since.

### Corrections after PR review

Copilot's review of pull request #43 at `c8a3bf8` found three more ways a run could pass without the evidence it claims. Each was fixed test-first: every new test failed before its code, except the one that pins a body's own failure over the continuity check, which guards the new check rather than an old defect.

- `judge_untouched` checked counts only up to 300 s but took the duration from the last answered scrape, so a patch first seen by the scrape that closes the window, at 300.1 s, passed. It now walks the answered scrapes up to and including the first at or past 300 s, and every one of them must read 0. An outage across the deadline is closed by the next answered scrape, whose count is judged too.
- The scraper's forward reopens to whichever pod `deployment/knarr` resolves to, so a knarr restart with a scrape gap under 30 s passed coverage, though budget `Threshold` holds within one run of the process and (a) reads the new process's counter. `process_identity` and `process_change` are new pure functions: the scraper reads the live knarr pods' names, UIDs and container restart counts when it opens and again when it closes. Any change, or other than one live pod, raises a `RuntimeError` like a churned round, unless the phase already failed. A UID is never reused and a restart count only rises, so the check at the end covers every reconnect.
- The restart watch stamped each pod read before `kubectl get` ran, so a slow read could date a late cleanup or rewrite under its bound. `stamped` is new: it runs the read and stamps the time it returned. Scrapes were already stamped after the response.

Not changed: `t_ready` still lags true readiness by up to a second or two, which gives the bounds that much slack, as the residual risks below record.

Verified: `python3 -m pytest scripts/checks/tests/test_keda_e2e.py`, 72 passed; `just test-checkers-selected cluster`, 95 passed; `just docs-check`; and `just check` at the staged tree: All checks passed and the worktree is unchanged. The harness has not been rerun on kind since.

### Residual risks and open questions

- The first run settled the HPA's scale-down timing and KEDA's behaviour with an inactive cron trigger. Equal bounds held the replica count, and each round's scale-in finished within 18 s.
- CI uploads no scrapes, so the committed transcript shows each judge's verdict but not the counts behind (b)'s cleanup.
- The seeded split is deterministic over the pod names, which are random per run. The baseline's chance of 0 busy kills is about 1 in 20 per round if the ReplicaSet's choice is independent of the load, about 1 in 8000 over three rounds. A void run is rerun with another seed.
- `t_ready` lags true readiness by up to a second or two, which gives (b) and (c) that much slack.

### What later tickets need

- **39:** this harness is the kind-tier proof of the three criteria. GKE repeats the comparison at production scale.
- **40:** run the `keda-e2e` workflow before tagging, and quote its verdict line. That run is the first of the harness with the cohort and coverage checks from the adversarial review and the continuity check from the PR review. Quote its two coverage lines too, and its two continuity lines, which begin `ok   one knarr process through the comparison scrapes` and `ok   one knarr process through the restart scrapes`.
- **35:** 32's owed admission-webhook rejection proof is still owed. This harness installs no webhook, and KEDA's core YAML carries none.
- **35:** the `keda-e2e` workflow uploads nothing. An `actions/upload-artifact` of `build/keda-e2e/` under `always()` would keep the scrapes, pod reads and kill records, so a reader could check (b)'s cleanup count rather than infer it from the readiness latch.
