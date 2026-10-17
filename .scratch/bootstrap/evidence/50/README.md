# Ticket 50 evidence

The first `just keda-e2e` run on an arm64 kind node, for [ticket 50](../../issues/50-local-arm64-image.md). [The KEDA harness page](../../../../docs/reference/keda-e2e.md) describes each phase, and [ticket 33's evidence](../33/README.md) has the amd64 runs from CI.

**Status:** run. [keda-e2e-arm64.txt](keda-e2e-arm64.txt) is the recipe's full output. Two edits only: the worktree's absolute path becomes `<worktree>`, and the cluster name derived from it, which also tags both images, becomes `<name>`. It ran on 2026-10-16 (local time) on the maintainer's Apple-silicon host: Darwin arm64, with OrbStack's Docker engine 29.4.0 (linux/arm64). It used three rounds and seed 33. Both images were native linux/arm64 builds from `c82e5bd`; the next commit, `e86eeb0`, changes only documentation. The two pinned KEDA digests are indexes with a linux/arm64 manifest, so nothing ran under emulation.

## The result

```text
busy kills: baseline 4 of 9 victims over 3 rounds, knarr 0 of 9; threshold knarr 0 per round and baseline >= 1: PASS
keda-e2e: all checks passed
```

| Criterion | arm64, `c82e5bd` | Bound |
| --- | --- | --- |
| Busy kills, baseline | 1, 2 and 1 of 3 victims per round | at least 1 over the run |
| Busy kills, knarr | 0 of 3 in each of 3 rounds | 0 in each round |
| One knarr process | one pod, 0 restarts, in each phase | a change fails the run |
| Coverage | 51 of 51 and 298 of 298 answered, longest gap 1.0 s | no gap over 30 s |
| (a) untouched | `knarr_patches_total` 0 for 300 s, 297 scrapes | 0 for 300 s |
| (b) opt-out | gone 0.1 s after readiness | 120 s |
| (c) changed | `pod-deletion-cost=1800` 26.6 s after readiness | 93 s |
| Preconditions | no throttled result, `knarr_paused` 0, 298 scrapes | none |
| Patch rate, `deploy/e2e-fast` | peak 13 in 60 s, 51 scrapes | 310 in 60 s, 5·⌈Δt⌉ + 10 in any window |
| Patch rate, after the restart | peak 1 in 60 s, 298 scrapes | the same |

KEDA 2.21.0, kind v0.33.0, node image v1.35.8. Phase times: KEDA 30 s, fixture 9 s, comparison 196 s, restart 391 s, 626 s in all.
