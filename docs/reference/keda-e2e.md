---
title: "The KEDA end-to-end harness"
kind: "reference"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["keda_e2e_harness"]
requires: []
---

# The KEDA end-to-end harness

`just keda-e2e` measures all three v1 success criteria of [OVERVIEW §3](../OVERVIEW.md#success-criteria-v1-thresholds-set-in-916) in one run on this worktree's kind cluster ([ticket 33](../../.scratch/bootstrap/issues/33-keda-harness-success-criterion.md)). It counts busy kills under KEDA scale-in with and without knarr. It restarts knarr and judges lifecycle's `Restart` `Threshold` in [lifecycle.allium](../specs/lifecycle.allium). It judges budget's `Threshold` in [budget.allium](../specs/budget.allium) over every scrape of `/metrics`. Its workload is [the fake worker fixture](fake-worker.md), and its busy kills come from that fixture's collector.

The harness is `scripts/checks/keda_e2e.py`. Its judges are pure functions over recorded values, tested in `scripts/checks/tests/test_keda_e2e.py` with one scale-in round driven against a fake cluster. The orchestration drives the cluster through `cluster.py`'s helpers, under the same worktree kubeconfig as every other cluster recipe.

## When to run it

It needs the network, because it downloads the pinned KEDA release, and it needs linux/amd64 images, so it runs in CI. It is never part of `just check`. Run it:

- before a release ([ticket 40](../../.scratch/bootstrap/issues/40-mvp-release.md));
- on a change to the reconciler, the patcher, the budget, the cost mapping, or the fake worker fixture.

Start it with the `keda-e2e` label on a pull request, which runs it again on each push while the label stays, or with a dispatch of the `keda-e2e` workflow, whose `rounds` and `seed` inputs default to 3 and 33. Locally, on a host that runs amd64 images, it runs after `just cluster-up`, `just image-build` and `just fake-worker-image-build`. `just keda-e2e 5 34` runs five rounds with seed 34; the defaults are three rounds and seed 33.

## Phases

Every phase prints `ok` or `FAIL` lines. If a phase fails, the harness prints the `keda` namespace's pods, the operator's log, the ScaledObject and the HPA, then exits 1.

1. **KEDA.** It downloads the core release YAML into `.cluster/keda/`, and reuses it while its sha256 matches the pin. A mismatch refuses the download. A kustomization beside it replaces each image the YAML names with its pinned digest. An image the YAML names without a pin, or a pin the YAML does not use, refuses the install. It applies the result server-side, then waits for `keda-operator`, `keda-metrics-apiserver` and the `v1beta1.external.metrics.k8s.io` APIService to be Available.
2. **Fixture.** It deletes what an earlier run left: knarr, the ScaledObject, and the worker Deployments, with foreground deletion so their pods are gone too. Then it deploys the fake worker and the ScaledObject in `fixtures/keda_e2e/scaledobject.json`, and waits for the ScaledObject to be `Ready`. knarr is not running yet, so no pod can carry an annotation knarr wrote.
3. **Baseline.** Each round patches the ScaledObject's `minReplicaCount` and `maxReplicaCount` to 6 and waits for exactly six Ready workers. It clears the collector. A shuffle seeded with the seed and the round number then sets three workers busy (cost 1800) and three idle (cost 0) through control. After a 30 s pause, no pod may carry `controller.kubernetes.io/pod-deletion-cost` or `knarr.io/applied`. Then the bounds go to 3, and the harness waits for exactly three Ready workers. The victims are the six before less the three after. Each victim must have a kill record, and the busy ones are counted. The survivors go back to cost 0.
4. **knarr.** It deploys `deploy/e2e-fast` and opts `fake-worker` in, then runs the same rounds with the same seed. Where the baseline pauses, it waits instead until every busy pod carries `pod-deletion-cost=1800` and no idle pod carries one. A timeout fails the round. A thread scrapes `/metrics` about once a second for the whole phase.
5. **Verdict.** One line, which the hand-back quotes: `busy kills: baseline B of V victims over R rounds, knarr K of V; threshold knarr 0 per round and baseline >= 1: PASS`. The outcome is `FAIL` if a knarr round with at least as many idle pods as victims killed a busy pod. It is `VOID` if the baseline killed no busy pod over the run. Either fails the run.
6. **Restart, at the defaults.** It deletes the ScaledObject and `fake-worker` and deploys the base. It applies three clones of the worker, `fake-worker-untouched`, `fake-worker-changed` and `fake-worker-optout`. Each has two replicas, its own `app.kubernetes.io/name` in its selector and template, and the opt-in label. Each clone's first worker is set to 1800 and its second to 0, and the harness waits until the first carries the annotation and the marker, the second neither, and `knarr_patches_pending` reads 0 for all three. Then it scales knarr to 0 and waits for its pod to go. While knarr is down, it sets `-changed`'s second worker to 1800 and removes `-optout`'s opt-in label. It scales knarr back to 1 and polls `/readyz` once a second. Readiness is the first 200. For the next 300 s it scrapes `/metrics` and reads the three Deployments' pods once a second, then judges:
   - (a) `knarr_patches_total{deployment="fake-worker-untouched"}` is absent or 0 throughout, with a scrape at or past 300 s;
   - (b) `-optout`'s pods lose the annotation and the marker within 120 s, two list intervals, and keep them off;
   - (c) `-changed`'s second worker carries `pod-deletion-cost=1800` within 93 s, one poll interval, its 10 % jitter and one patch interval, and keeps it;
   - the preconditions (b) and (c) are bounds for: no series with `result="throttled"` above 0 and `knarr_paused` 0 in every scrape. A breach prints `INVALID` and fails the run rather than passing it.
7. **Patch rate.** For each knarr process scraped, `deploy/e2e-fast`'s and the one after the restart, every pair of scrapes must count at most 5 · ⌈Δt⌉ + 10 more patches (budget `Threshold`). The count adds each `knarr_patches_total` series' rise since the scrape before, and a new series counts from 0. knarr retires a departed Deployment's counters once its cleanup is done (observability `SeriesLife`), as the opt-out does, so the sum of the series can fall while the patches it counted still count. The line names the window with the least headroom, and the peak count in 60 s against 310.
8. **Summary.** The KEDA version, the kind version and node image, each phase's time, and the total.

`t_ready` is the first 200 the harness sees, polled once a second through a port forward, so it lags true readiness by up to a second or two. Every bound is measured from it, which gives the bounds that much slack, never less.

## What it keeps

Everything is under `build/keda-e2e/`, which the gate ignores, and is replaced on each run:

| Path | Contents |
| --- | --- |
| `baseline-round-N.json`, `knarr-round-N.json` | The round's busy and idle pods, survivors, victims and the collector's kill records |
| `scrapes/comparison/`, `scrapes/restart/` | Every scrape, numbered, its first line the time it was taken; a failed scrape keeps only a `# scrape failed` line |
| `restart-pods.jsonl` | Each read of the restart Deployments' pod annotations, its time relative to readiness |

## Settings and pins

| What | Where | Value |
| --- | --- | --- |
| KEDA | `fixtures/keda_e2e/keda.json` | 2.21.0: the `keda-2.21.0-core.yaml` release asset by sha256, which the release does not publish, so it was hashed on download, and the `keda` and `keda-metrics-apiserver` image indexes by digest. 2.21 supports Kubernetes 1.34 to 1.36, which includes kind's 1.35 node |
| ScaledObject | `fixtures/keda_e2e/scaledobject.json` | Targets `fake-worker`, never the collector. Equal bounds, so replicas follow the bounds alone. Its one cron trigger opens for a minute a year, on 1 January at 00:00 UTC. The HPA behaviour allows 100 % per 15 s each way with no stabilization window |
| knarr, comparison | `deploy/e2e-fast` | List interval 10 s, poll interval 5 s, poll timeout 4 s, patch interval 10 s. Rate and burst stay at the defaults, 5 per second and 10 |
| knarr, restart | `deploy/base` | The defaults the restart threshold names: list 60 s, poll 30 s with 10 % jitter, patch 60 s |
| Timings | `keda_e2e.py` | 6 pods, a step of 3, a 30 s baseline pause, a 180 s gate, 300 s for a scale-out or scale-in and for the restart settle, 180 s for readiness |

KEDA moves only by hand: the YAML's hash and the two digests move together, and a rule in `.github/renovate.json` keeps any bot off them. To move it, pick a release whose compatibility table includes the kind node's Kubernetes minor. Hash its core YAML, take each image's index digest (`docker buildx imagetools inspect`), and rerun the harness. The ScaledObject is not in `just packaging-check`, because kubeconform has no schema for KEDA's CRD. `kubectl apply` checks it against KEDA's CRD, and the harness then waits for its `Ready` condition, where the operator reports a trigger it refuses, since the core YAML installs no admission webhook.
