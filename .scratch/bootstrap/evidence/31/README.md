# Ticket 31 evidence

The reconciler proof on kind for [ticket 31](../../issues/31-spec-then-build-reconcile-core.md): knarr's base deployed with discovery on, the fake worker fixture ([ticket 29](../../issues/29-fake-worker-fixture.md)) opted in, one worker's cost driven across the first threshold and back through its control endpoint, and the pod-deletion-cost annotation and the `knarr.io/applied` marker read off the pod after each step. It replaces ticket 14's S1 probe proof, whose scaffolding ticket 31 removed; the TLS evidence and the wrong-CA negative case under [evidence 14](../14/README.md) still run beside it.

**Status:** run successfully. [reconcile-kind.txt](reconcile-kind.txt) is the reconcile step from [run 38820393121, job 116715288745](https://github.com/steven-cutting/knarr/actions/runs/38820393121/job/116715288745), ticket 47's labelled PR #41 run on native Linux x86_64 on 2026-10-15. The tested checkout is PR merge commit `2a02f23dc400b8133939479fff8b3bedb0bf19c0`, merging head `a457d02253b21878a98cbbc2ac45a74a727a9d21` into `aee82f3cbac86f9fdab58c45936b70f45c3d02d6`; the Actions metadata's head SHA is not the tested merge SHA. The step and job both concluded success. The transcript was recovered on 2026-10-15 with authorized read-only `gh run view` calls, selecting this step alone and removing the job/step prefixes, runner timestamps, setup preamble and trailing whitespace. Build and proof output remain; no new CI or cluster run was dispatched.

## Rerun

```sh
sh .scratch/bootstrap/evidence/31/reconcile-kind.sh "$(pwd)" "$(mktemp -d)"
just cluster-down
```

It needs network, Docker on a host that can build the linux/amd64 images, and the cluster environment (`just cluster-install`). It takes a few minutes: two LIST intervals of 60 s for the write and the removal, plus the builds. Nothing printed holds a token.

## Script

| Script | Transcript | What it shows |
| --- | --- | --- |
| [reconcile-kind.sh](reconcile-kind.sh) `<worktree> <dir>` | [reconcile-kind.txt](reconcile-kind.txt) | Builds, checks and deploys knarr's base and the fake workers to the worktree's kind cluster; waits for knarr's rollout, which proves the readiness latch after the first complete discovery cycle; labels the `fake-worker` Deployment `knarr.io/enabled=true`; sets one worker's cost to 1800 through `PUT /control` and waits for `controller.kubernetes.io/pod-deletion-cost=1800` and a marker whose applied record is `"1800"`; sets the cost to 100 and waits for the annotation's removal and the marker's null record; then reads knarr's JSON log for the `discovery` and `token changed` lines (the `patch` line is at debug level, below the Deployment's default info, so it is not read), requires no `error` line and no bearer token, reads `/metrics` through a port-forward to the knarr Deployment and requires the `knarr_targets{kind="pods"}` and `knarr_pods{deployment="fake-worker",tier="0"}` series, and a Ready knarr pod with `restartCount` 0 |

## Notes

- **Timing.** The reconciler polls every target once per LIST interval (60 s by default) and sends a due write at once, so each step lands within about one interval; the script waits up to 150 s per step.
- **The wrong-CA case changed meaning.** With the readiness latch, a knarr that can never complete a LIST cycle answers `/readyz` 503 for its whole life, so [wrong-ca.sh](../14/wrong-ca.sh) now requires the pod to be Running and NotReady with `restartCount` 0, `tls_alert unknown_ca` in the `list failed` error lines, and no `discovery` line.

## Recovered result

The transcript shows cost 1800 written and recorded in the marker at 22:58:39Z, cost 100 removing the annotation and leaving a null marker record at 22:59:39Z, three logged discovery cycles, the token-change line, no error line or bearer token, the target and tier metrics, and knarr Ready with restartCount 0. It ends `reconcile-kind: all checks passed`. This is the original reconcile proof preceding 47's cleanup proof on the same cluster, not an inference from the cleanup result. The timing note above describes the original driver; the recovered run includes 46's independent poll scheduler and patcher.
