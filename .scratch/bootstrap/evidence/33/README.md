# Ticket 33 evidence

The KEDA end-to-end run on kind for [ticket 33](../../issues/33-keda-harness-success-criterion.md). `just keda-e2e` measures the three OVERVIEW §3 success criteria in one run. It counts busy kills under KEDA scale-in with and without knarr against the maintainer's threshold. It judges lifecycle's `Restart` `Threshold` (a), (b) and (c) at the defaults, and budget's `Threshold` over every scrape of `/metrics`. [The KEDA harness page](../../../../docs/reference/keda-e2e.md) describes each phase.

**Status:** run. [keda-e2e.txt](keda-e2e.txt) is the `keda-e2e` job's log of the `just keda-e2e` step, with the runner's step preamble and the log timestamps removed. It comes from the labelled run of ticket 33's pull request [#43](https://github.com/steven-cutting/knarr/pull/43): run [38841125203](https://github.com/steven-cutting/knarr/actions/runs/38841125203/job/116781200596), on ubuntu-24.04 on 2026-10-16 UTC, at `01125a8`, with three rounds and seed 33. The step took 672 s and the job 12 min 40 s, setup and both image builds included. Nothing rewrites the committed transcript.

## The result

```text
busy kills: baseline 4 of 9 victims over 3 rounds, knarr 0 of 9; threshold knarr 0 per round and baseline >= 1: PASS
```

| Criterion | Measured | Bound |
| --- | --- | --- |
| Busy kills, baseline | 1, 2 and 1 of 3 victims per round | at least 1 over the run |
| Busy kills, knarr | 0 of 3 in each of 3 rounds | 0 in each round whose idle pods cover the step |
| (a) untouched | `knarr_patches_total` 0 for 300 s, 298 scrapes | 0 for 300 s |
| (b) opt-out | annotation and marker gone at the first read after readiness | 120 s |
| (c) changed | `pod-deletion-cost=1800` 25.7 s after readiness | 93 s |
| Preconditions | no throttled result, `knarr_paused` 0, 299 scrapes | none |
| Patch rate, `deploy/e2e-fast` | peak 15 in 60 s, 78 scrapes | 310 in 60 s, 5·⌈Δt⌉ + 10 in any window |
| Patch rate, after the restart | peak 1 in 60 s, 299 scrapes | the same |

KEDA 2.21.0, kind v0.33.0, node image v1.35.8. Phase times: KEDA 28 s, fixture 21 s, comparison 224 s, restart 399 s.

## Rerun

On a host that runs linux/amd64 images:

```sh
just cluster-up
just image-build
just fake-worker-image-build
just keda-e2e          # or: just keda-e2e <rounds> <seed>
just cluster-down
```

Or dispatch the `keda-e2e` workflow, whose `rounds` and `seed` inputs default to 3 and 33, or add the `keda-e2e` label to a pull request. The scrapes, the pod reads and the kill records of a run are kept under `build/keda-e2e/`. CI does not upload them, so this transcript is the committed record.

## Notes

- **Why (b) reads 0.0 s.** Readiness latches at the end of the first discovery cycle in which every LIST succeeded (observability `Probes` `Readiness`; `discovered` in `src/knarr/reconciler.gleam`). The first pod read after the harness saw `/readyz` 200 already found both annotations gone, so the new process's cleanup landed at readiness or before it, from its first cycle. The bound is an upper bound from readiness, so a cleanup that lands at readiness meets it. CI keeps no scrapes, so this transcript does not show the cleanup's count; [47's evidence](../47/README.md) shows that count and the series' retirement on kind.
- **The restart was quick.** knarr's pod was gone within about a second and a half of the scale to 0, and the new one answered `/readyz` 200 1.2 s after the scale to 1, with its image already on the node. The downtime changes were made in between, while no knarr process ran.
- **Residual risk the run settled.** The plan feared that KEDA's HPA might not follow equal bounds with a cron trigger that is never active, or that its scale-down might be slow. From the bounds patch to 3 to the round's line, which also covers the kill count and the survivors' reset, each round took 5 to 18 s. The fallback of lowering `maxReplicaCount` first was not needed.
