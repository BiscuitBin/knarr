# Ticket 31 evidence

The reconciler proof on kind for [ticket 31](../../issues/31-spec-then-build-reconcile-core.md): knarr's base deployed with discovery on, the fake worker fixture ([ticket 29](../../issues/29-fake-worker-fixture.md)) opted in, one worker's cost driven across the first threshold and back through its control endpoint, and the pod-deletion-cost annotation and the `knarr.io/applied` marker read off the pod after each step. It replaces ticket 14's S1 probe proof, whose scaffolding ticket 31 removed; the TLS evidence and the wrong-CA negative case under [evidence 14](../14/README.md) still run beside it.

**Status:** the script is written and reviewed by reading only. Its CI run is owed: the workflow `.github/workflows/reconcile-proof.yml` runs it on a push to main that changes its inputs, on `workflow_dispatch`, and on a pull request carrying the `cluster-s1` label, on native linux/amd64, because the committed Dockerfile cannot build on the ARM host ([Decision 0013](../../../../docs/decisions/0013-in-cluster-client.md), Emulation). No transcript is committed yet; the first labelled run of ticket 31's pull request cuts it.

## Rerun

```sh
sh .scratch/bootstrap/evidence/31/reconcile-kind.sh "$(pwd)" "$(mktemp -d)"
just cluster-down
```

It needs network, Docker on a host that can build the linux/amd64 images, and the cluster environment (`just cluster-install`). It takes a few minutes: two LIST intervals of 60 s for the write and the removal, plus the builds. Nothing printed holds a token.

## Script

| Script | Transcript | What it shows |
| --- | --- | --- |
| [reconcile-kind.sh](reconcile-kind.sh) `<worktree> <dir>` | owed (see Status) | Builds, checks and deploys knarr's base and the fake workers to the worktree's kind cluster; waits for knarr's rollout, which proves the readiness latch after the first complete discovery cycle; labels the `fake-worker` Deployment `knarr.io/enabled=true`; sets one worker's cost to 1800 through `PUT /control` and waits for `controller.kubernetes.io/pod-deletion-cost=1800` and a marker whose applied record is `"1800"`; sets the cost to 100 and waits for the annotation's removal and the marker's null record; then reads knarr's JSON log for the `discovery` and `token changed` lines (the `patch` line is at debug level, below the Deployment's default info, so it is not read), requires no `error` line and no bearer token, reads `/metrics` through a port-forward to the knarr Deployment and requires the `knarr_targets{kind="pods"}` and `knarr_pods{deployment="fake-worker",tier="0"}` series, and a Ready knarr pod with `restartCount` 0 |

## Notes

- **Timing.** The reconciler polls every target once per LIST interval (60 s by default) and sends a due write at once, so each step lands within about one interval; the script waits up to 150 s per step.
- **The wrong-CA case changed meaning.** With the readiness latch, a knarr that can never complete a LIST cycle answers `/readyz` 503 for its whole life, so [wrong-ca.sh](../14/wrong-ca.sh) now requires the pod to be Running and NotReady with `restartCount` 0, `tls_alert unknown_ca` in the `list failed` error lines, and no `discovery` line.
