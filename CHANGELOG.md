# Changelog

Notable changes to Knarr are recorded here, by release. This file follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Knarr is pre-MVP: 0.1.0 is the walking skeleton, published to rehearse the release route. [Decision 0012](docs/decisions/0012-release-and-packaging.md) decides versioning and the release workflow: a release pull request moves the `[Unreleased]` section under `## [X.Y.Z] - YYYY-MM-DD`, and the release workflow refuses a tag whose version has no such heading.

## [Unreleased]

### Added

- The poll schedule and the patcher: every target pod polls on its own ladder, a random phase then its Deployment's interval plus 0 to `poll_jitter_percent` of it, with at most `poll_concurrency` polls in flight, an oldest-due queue and no overlapping polls of one pod; due patches wait in a pending set served oldest-due first through a token bucket of `patch_rate_per_second` and `patch_burst`, one attempt per pod per patch interval, and a 429 pauses patching exponentially from `backoff_initial` to `backoff_cap` or Retry-After, with the discovery LISTs paused separately under the same rule. The five remaining install-wide values are read at start, and `knarr_patches_total`, `knarr_lists_total`, `knarr_poll_duration_seconds`, `knarr_patches_pending`, `knarr_patch_pending_oldest_seconds`, `knarr_paused`, `knarr_pause_seconds`, `knarr_poll_queue_depth` and `knarr_polls_skipped_total` are emitted. A reading lands only on the pod, by name and uid, its poll was sent for: a pod relisted under a new uid joins from a fresh phase with fresh memory, and its predecessor's poll, reading, pending patch and patch interval are discarded.
- The reconcile loop: discovery of opted-in Deployments by three LISTs matched by owner chain, the mapped pod-deletion-cost against the marker's applied value, the JSON Patch write mode with ownership's marker and yield, the ContractAbsent, InvalidOverride and AnnotationYielded Events, JSON log lines through OTP logger, the discovery, cost, standing and pod-state metrics, and `/readyz` latching after the first complete discovery cycle. Discovery is turned on with `-knarr discovery true`; a bad install-wide value fails the start naming the key.
- `max_body_bytes` enforced on the poll path: the install-wide value reaches the poller, and a 200 whose body is longer than it is an invalid reading.
- The rejection signals: a patch the apiserver rejects with 400 or 403, or a 422 the next LIST classifies as a rejection, counts on `knarr_patch_rejections_total{deployment, purpose}`, raises one `PatchRejected` Event on the Pod per rejection run (`CleanupRejected` for a cleanup, in a run of its own) and logs a warning line; a foreign annotation logs one warning line on entry and raises no Event.
- The pure cleanup contracts: ownership's `cleanup` builds the patch that releases owned annotations and drops their records, removing the marker when none remains, and the new `lifecycle` module derives what each pod's View makes due and when a Deployment's cleanup is done.
- Cleanup after an opt-out, a deleted Deployment or a removed safe-to-evict opt-in: every complete discovery cycle builds a View for each listed pod and hands each due cleanup to the patcher, which sends one patch per pod releasing every owned annotation that is no longer enabled, removing the marker with the last record, counted on `knarr_patches_total` with purpose `cleanup` under the pod's Deployment. A rejected cleanup is retried after the patch interval and raises `CleanupRejected` once per run. A Deployment's series retire only once it is out of the target set and its cleanup is done, so an opt-out's cleanup is counted before its series go, and `knarr_annotations` counts the owned annotations a pod outside the target set still carries.
- A JSON log formatter that never emits a non-JSON line: a report it cannot render becomes a fixed `unformattable` error line, and truncation is by character, not byte.

### Changed

- `deploy/release` pins the digest of 0.1.0, the first published release.

### Removed

- The S1 probe and its `knarr.io/s1-probe` annotation, replaced by the reconciler as the client's first caller.

## [0.1.0] - 2026-10-14

### Added

- A supervised walking skeleton with health, readiness and Prometheus metrics endpoints, plus local Kubernetes test resources.
- Pinned repository tools, an offline quality gate and CI, Allium specifications, and the contributor handbook.
- Contribution instructions for the ticket and worktree workflow, private security reporting with support for current `main`, and this changelog.
- Dependency update proposals from Renovate, held until they are activated, and a weekly audit of hex and Erlang/OTP advisories from OSV.dev and of the container image with grype.
- A release workflow: a pushed version tag publishes the image to `ghcr.io/steven-cutting/knarr` once the maintainer approves the `release` environment, and `deploy/release` installs it pinned by digest.
- The status poller: a pure builder and decoder for a worker's `GET /knarr/v1/status`, and a supervised plain-HTTP adapter with a per-poll timeout.

### Changed

- The Dockerfile's base images are pinned by digest.
- The image's runtime environment no longer ships conda-forge's perl 5.32.1, which only erlang's conda package pulled in, and the weekly audit also scans that environment with grype.
