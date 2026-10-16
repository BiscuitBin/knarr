# 50: Build the local images natively on an arm64 host

**Context:** On the maintainer's Apple-silicon host the local loop stopped at `just image-build`. The recipe forced `--platform linux/amd64`, and OTP 29's amd64 BEAM dies under Rosetta in `prim_tty` at `gleam export erlang-shipment` ([Decision 0012](../../../docs/decisions/0012-release-and-packaging.md), [amd64-probe.txt](../evidence/28/amd64-probe.txt)). A native `linux/arm64` build failed at `pixi install --locked`, because `pixi.lock` had no `linux-aarch64` entries ([arm64-probe.txt](../evidence/28/arm64-probe.txt)). Both base images are already indexes with an arm64 manifest ([digests.txt](../evidence/27/digests.txt)). So `just deploy`, `just smoke` and the fake-worker recipes could not run on a local kind cluster there.

**What to build:** `linux-aarch64` in `pixi.toml` and a re-lock through [Decision 0014's re-lock route](../../../docs/decisions/0014-dependency-updates-and-audit.md#re-locks-ticket-38s-arm64-among-them). `just image-build` and `just fake-worker-image-build` build for the host architecture, with the platform as a defaulted parameter. `just image-check` runs an image at its own architecture.

**Non-goals:** The release image, which stays linux/amd64 in `release.yml`. CI's jobs, which run on x86_64 and still build amd64. Ticket 38's `ubuntu-24.04-arm` build job and the merged index.

**Blocked by:** 27, 28, 29

**MVP critical path:** no. CI proves the amd64 image; this is the maintainer's local loop.

**Status:** done, except the CI confirmation, which needs a push.

- [x] `linux-aarch64` is in `platforms`, and the lock is re-solved. Every environment in the `default` solve group solves for it. The diff only adds entries, except for the kubectl move below.
- [x] `just image-build` and `just fake-worker-image-build` build linux/arm64 on an aarch64 host and linux/amd64 elsewhere, and `just image-build` with no arguments still works.
- [x] `scripts/checks/image.py` runs the image at the `Architecture` its `docker image inspect` reports. Its tests cover amd64 and arm64.
- [x] On the arm64 host: `just image-check`, `just deploy`, `just smoke`, and the four fake-worker recipes pass.
- [x] Decisions 0003, 0007, 0012 and 0014, the install guide, the local-cluster how-to, the Renovate cap's description, ticket 38 and `CHANGELOG.md` carry the change.
- [ ] **Authorization required:** a push, so that `ci.yml`, `keda-e2e.yml` and `audit.yml` show the amd64 builds unchanged.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Done on 2026-10-16. The maintainer authorized the network for `pixi lock`, `pixi install --locked` and both image builds. On the same day they also approved the kubectl bump below and the branch name `50-local-arm64-image`.

### What changed

- **kubectl moved from 1.34.3 to 1.36.0.** The first `pixi lock` failed with `No candidates were found for kubernetes-client ==1.34.3`. conda-forge's linux-aarch64 channel has kubernetes-client 1.24.3, 1.36.0 and 1.37.1 only, with no 1.34 or 1.35. The other 18 pins all have linux-aarch64 builds. kubectl 1.36 reaches servers 1.35 to 1.37, so the 1.35 kind node and kwok images stay within its skew. Its bundled kustomize is 5.8.1, up from 5.7.1. The vendored 1.35 schemas now hold the Renovate cap on their own.
- **The lock.** `pixi.lock` gained 816 lines and lost 14. The 14 are the two old kubernetes-client records and their environment references. On linux-64 and osx-arm64 nothing else moved.
- **`justfile`.** `image_platform` maps `arch()` to `linux/arm64` on aarch64 and `linux/amd64` otherwise. Both build recipes take it as a second parameter, `platform=image_platform`.
- **`image.py`** passes `--platform=linux/<Architecture>` from the inspect output it already reads.

### What was verified

- `just lock-check` and `just env-check` pass, and `pixi install --locked -e default -e cluster` passes on osx-arm64. `kubectl version --client` reports v1.36.0 with kustomize v5.8.1.
- `test_image.py`: 12 passed. The arm64 assertion fails against the old `image.py`.
- `just image-build` built an image whose `docker image inspect` reports `arm64`. `just image-check` reported OTP 29 (erts 17.1), OpenSSL 3.6.5 and all 6 TLS cases, then "OTP 29, numeric user and read-only runtime verified". This is the native arm64 BEAM run that ticket 13 left unverified.
- `just deploy` rolled out, and `just smoke` reported ok for `/healthz`, `/readyz` and `/metrics`. In `just cluster-diagnostics` the knarr pod was Running with 0 restarts.
- `just fake-worker-image-build`, `fake-worker-image-check`, `fake-worker-deploy` and `fake-worker-smoke` passed: the idle, busy, draining and absent states, the drain after SIGTERM, and both kill records.

### What later tickets need

- **38:** the re-lock is done, so the arm64 lane needs only the `ubuntu-24.04-arm` job, `imagetools create`, and the overlay pinning the index digest. The image itself is proven to run natively on arm64.
- **CI is unconfirmed.** The amd64 paths are unchanged by construction: CI runners are x86_64, and `release.yml` names its own platform. No pushed run shows it yet.
- **An amd64 image on this host** still needs a CI build. `just image-build <tag> linux/amd64` fails under Rosetta, as before.
