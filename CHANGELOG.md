# Changelog

Notable changes to Knarr are recorded here, by release. This file follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Knarr is pre-MVP: 0.1.0 is the walking skeleton, published to rehearse the release route. [Decision 0012](docs/decisions/0012-release-and-packaging.md) decides versioning and the release workflow: a release pull request moves the `[Unreleased]` section under `## [X.Y.Z] - YYYY-MM-DD`, and the release workflow refuses a tag whose version has no such heading.

## [Unreleased]

## [0.1.0] - 2026-10-13

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
