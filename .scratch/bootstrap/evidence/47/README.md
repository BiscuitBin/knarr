# Ticket 47 evidence

The opt-out cleanup proof on kind for [ticket 47](../../issues/47-discovery-cleanup-hand-off.md): on the cluster [evidence 31](../31/README.md)'s script leaves behind, with knarr running and the `fake-worker` Deployment opted in, one worker's cost is driven above the first threshold, the Deployment's `knarr.io/enabled` label is removed, and the pod, knarr's `/metrics` and its log are read until the cleanup has landed and the Deployment's series have retired. It shows lifecycle `Scope` (an opt-out makes the owned annotation due), `Marker` (the annotation and its record go in one patch, and the marker with the last record), `Label` (the cleanup counts on `knarr_patches_total` with purpose `cleanup` and the Deployment's name) and `Done`, and observability `SeriesLife` (the series go only after the cleanup is counted).

**Status:** the script is written and reviewed by reading only. Its CI run is owed: the workflow `.github/workflows/reconcile-proof.yml` runs it straight after ticket 31's script, on the same triggers and the same native linux/amd64 runner. No transcript is committed yet; the first labelled run of ticket 47's pull request cuts it.

## Rerun

```sh
sh .scratch/bootstrap/evidence/31/reconcile-kind.sh "$(pwd)" "$(mktemp -d)"
sh .scratch/bootstrap/evidence/47/cleanup-kind.sh "$(pwd)" "$(mktemp -d)"
just cluster-down
```

The 47 script builds and deploys nothing: it needs the cluster, knarr and the opted-in fake workers that ticket 31's script leaves, and refuses to start when `fake-worker` is not labelled `knarr.io/enabled=true`. It takes up to about seven minutes: one write, then the opt-out, the patch interval and two LIST intervals of 60 s. Nothing printed holds a token.

## Script

| Script | Transcript | What it shows |
| --- | --- | --- |
| [cleanup-kind.sh](cleanup-kind.sh) `<worktree> <dir>` | owed (see Status) | Picks the worker pod ticket 31's script drove, sets its cost to 1800 through `PUT /control` and waits for `controller.kubernetes.io/pod-deletion-cost=1800` and a `knarr.io/applied` marker whose applied record is `"1800"`; opens a port-forward to the knarr Deployment's `/metrics` and requires `fake-worker` series before the opt-out; runs `kubectl label deployment fake-worker knarr.io/enabled-`; then scrapes `/metrics` every second, keeping each scrape as `<dir>/scrapes/NNNN.txt`, and reads the pod every fifth second, until both annotations are absent from the pod and a scrape with no series labelled `deployment="fake-worker"` has followed one carrying `knarr_patches_total` with `deployment="fake-worker"`, `purpose="cleanup"` and `result="accepted"`, for up to 330 s; then requires no `error` line and no bearer token in knarr's log and a Ready knarr pod with `restartCount` 0 |

## Notes

- **Timing.** The opt-out is seen at the next LIST (60 s by default), and the cleanup then waits the patch interval (60 s by default) counted from the write the script just made (budget `PerPod`), so it lands within about two minutes; the series retire about one LIST interval after it is accepted. The script waits up to 330 s for the whole sequence.
- **Why the scrapes start at the opt-out.** The counter's window is about one LIST interval and may close before the pod is seen clean, so one loop scrapes from the moment the label is removed and judges each scrape as it comes: a scrape that did not answer (no `knarr_targets` series) counts as neither the cleanup nor the retirement, and a dropped port-forward is reopened. Every scrape is kept, so the sequence can be read back from the work directory.
- **The marker goes too.** The fixture enables no `knarr.io/safe-to-evict`, so the pod's only record is `pod-deletion-cost`'s; dropping it leaves no record, and the marker annotation is removed with it (lifecycle `Marker`).
