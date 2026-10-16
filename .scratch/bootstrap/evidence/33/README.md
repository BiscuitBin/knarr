# Ticket 33 evidence

The KEDA end-to-end run on kind for [ticket 33](../../issues/33-keda-harness-success-criterion.md). `just keda-e2e` measures the three OVERVIEW §3 success criteria in one run. It counts busy kills under KEDA scale-in with and without knarr against the maintainer's threshold. It judges lifecycle's `Restart` `Threshold` (a), (b) and (c) at the defaults, and budget's `Threshold` over every scrape of `/metrics`. [The KEDA harness page](../../../../docs/reference/keda-e2e.md) describes each phase.

**Status:** run. [keda-e2e.txt](keda-e2e.txt) is the `keda-e2e` job's log of the `just keda-e2e` step, with the runner's step preamble and the log timestamps removed. It comes from the labelled run of ticket 33's pull request [#43](https://github.com/steven-cutting/knarr/pull/43): run [38841125203](https://github.com/steven-cutting/knarr/actions/runs/38841125203/job/116781200596), on ubuntu-24.04 on 2026-10-16 UTC, at `01125a8`, with three rounds and seed 33. The step took 672 s and the job 12 min 40 s, setup and both image builds included.

The label stayed on, so the run repeated on each push. [keda-e2e-f9da061.txt](keda-e2e-f9da061.txt) is the same step's log from run [38852252385](https://github.com/steven-cutting/knarr/actions/runs/38852252385/job/116815839782) at `f9da061`, trimmed the same way. It is the first kind run of the harness with every correction in the ticket's hand-back: the cohort and coverage checks, the closing scrape, the continuity check and the read stamps. The step took 652 s and the job 12 min 30 s. Run [38847326962](https://github.com/steven-cutting/knarr/actions/runs/38847326962) at `c8a3bf8`, between the two, passed too, with a baseline of 5 of 9 and knarr 0 of 9; its transcript is not committed. Nothing rewrites a committed transcript.

## The result

```text
01125a8: busy kills: baseline 4 of 9 victims over 3 rounds, knarr 0 of 9; threshold knarr 0 per round and baseline >= 1: PASS
f9da061: busy kills: baseline 6 of 9 victims over 3 rounds, knarr 0 of 9; threshold knarr 0 per round and baseline >= 1: PASS
```

| Criterion | `01125a8` | `f9da061` | Bound |
| --- | --- | --- | --- |
| Busy kills, baseline | 1, 2 and 1 of 3 victims per round | 3, 1 and 2 of 3 | at least 1 over the run |
| Busy kills, knarr | 0 of 3 in each of 3 rounds | the same | 0 in each round whose idle pods cover the step |
| One knarr process | not checked | one pod, 0 restarts, in each phase | a change fails the run |
| Coverage | not checked | 61 of 61 and 299 of 299 answered, longest gap 1.0 s | no gap over 30 s |
| (a) untouched | `knarr_patches_total` 0 for 300 s, 298 scrapes | the same, 299 scrapes | 0 for 300 s |
| (b) opt-out | gone at the first read after readiness, 0.0 s | the same, 0.2 s | 120 s |
| (c) changed | `pod-deletion-cost=1800` 25.7 s after readiness | 16.2 s | 93 s |
| Preconditions | no throttled result, `knarr_paused` 0, 299 scrapes | the same | none |
| Patch rate, `deploy/e2e-fast` | peak 15 in 60 s, 78 scrapes | peak 11, 61 scrapes | 310 in 60 s, 5·⌈Δt⌉ + 10 in any window |
| Patch rate, after the restart | peak 1 in 60 s, 299 scrapes | the same | the same |

KEDA 2.21.0, kind v0.33.0, node image v1.35.8 in both. Phase times at `01125a8`: KEDA 28 s, fixture 21 s, comparison 224 s, restart 399 s. At `f9da061`: KEDA 30 s, fixture 25 s, comparison 205 s, restart 392 s. The baselines differ with the same seed because the busy split is seeded over pod names, which are random per run.

## Rerun

On a host that runs linux/amd64 images:

```sh
just cluster-up
just image-build
just fake-worker-image-build
just keda-e2e          # or: just keda-e2e <rounds> <seed>
just cluster-down
```

Or dispatch the `keda-e2e` workflow, whose `rounds` and `seed` inputs default to 3 and 33, or add the `keda-e2e` label to a pull request. The scrapes, the pod reads and the kill records of a run are kept under `build/keda-e2e/`. CI does not upload them, so these transcripts are the committed record.

## Notes

- **Why (b) reads 0.0 s, and 0.2 s in the rerun.** Readiness latches at the end of the first discovery cycle in which every LIST succeeded (observability `Probes` `Readiness`; `discovered` in `src/knarr/reconciler.gleam`). The first pod read after the harness saw `/readyz` 200 already found both annotations gone, so the new process's cleanup landed at readiness or before it, from its first cycle. The bound is an upper bound from readiness, so a cleanup that lands at readiness meets it. The rerun's harness stamps each read when it returns rather than when it starts, so its first read after readiness is dated 0.2 s. CI keeps no scrapes, so neither transcript shows the cleanup's count; [47's evidence](../47/README.md) shows that count and the series' retirement on kind.
- **The restart was quick.** knarr's pod was gone within about a second and a half of the scale to 0, and the new one answered `/readyz` 200 1.2 s after the scale to 1, with its image already on the node. The downtime changes were made in between, while no knarr process ran.
- **Residual risk the run settled.** The plan feared that KEDA's HPA might not follow equal bounds with a cron trigger that is never active, or that its scale-down might be slow. From the bounds patch to 3 to the round's line, which also covers the kill count and the survivors' reset, each round took 5 to 18 s. The fallback of lowering `maxReplicaCount` first was not needed.
