# Changelog

Notable changes to Knarr are recorded here. This file follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Knarr is pre-MVP; the entries below are unreleased. [Decision 0012](docs/decisions/0012-release-and-packaging.md) decides versioning and the release workflow: a release pull request moves this section under `## [X.Y.Z] - YYYY-MM-DD`, and the release workflow refuses a tag whose version has no such heading.

## [Unreleased]

### Added

- A supervised walking skeleton with health, readiness and Prometheus metrics endpoints, plus local Kubernetes test resources.
- Pinned repository tools, an offline quality gate and CI, Allium specifications, and the contributor handbook.
- Contribution instructions for the ticket and worktree workflow, private security reporting with support for current `main`, and this changelog.
- Dependency update proposals from Renovate, held until they are activated, and a weekly audit of hex and Erlang/OTP advisories from OSV.dev and of the container image with grype.
- A release workflow: a pushed version tag publishes the image to `ghcr.io/steven-cutting/knarr` once the maintainer approves the `release` environment, and `deploy/release` installs it pinned by digest.

### Changed

- The Dockerfile's base images are pinned by digest.
- The image no longer ships perl, which only erlang's conda package pulled in, and the weekly audit also scans the image's conda runtime environment with grype.
