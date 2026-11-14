# 05: CI and Renovate spike

**Context:** Every CI job gets its tools from one composite setup action, which installs pixi, restores a cache that only `main` writes, and runs `just initialize`. Each job has a timeout: 20 minutes for the gate and the kind jobs, 10 for the checker regressions. [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) chose Renovate partly because it can move `pixi.lock`. Before the setup action and the Renovate configuration move to Nix, this ticket measures both on the real runner, from a throwaway branch, using [01](01-nix-container-spike.md)'s prototype flake.

**What to build:** Evidence under `.scratch/nix-migration/evidence/05/` that answers:

- **Installer action and cache.** Which Nix installer action to use, pinned by commit SHA, and which cache strategy. Cold and warm setup times against each job's timeout, and whether the cache can be written from `main` only, as today's is.
- **The runner.** On ubuntu-24.04 under the prototype environment: `just check`, `just test-checkers-all`, the prototype image build for linux/amd64 and the TLS proof in it.
- **Renovate.** A dry run against a repository state that has the prototype flake: which flake inputs and held pins the nix manager extracts, whether lock maintenance moves `flake.lock`, and how the build-stage image is tracked. Bootstrap ticket 27's evidence has the shape to follow.

**Non-goals:** Merging any workflow or Renovate change. Activating the Renovate app, which is bootstrap ticket [44](../../bootstrap/issues/44-renovate-activation.md).

**Blocked by:** 01

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** a push of a throwaway branch and the workflow runs on it. The branch is deleted afterwards and the evidence keeps the run URLs and logs.
- [ ] **Authorization required:** the network, for the Renovate dry run's lookups.
- [ ] The installer action is named with its SHA, and cold and warm timings are recorded for the gate job and one cluster job.
- [ ] The gate and all checker tests pass on the runner under the prototype environment, or each failure is listed with its cause.
- [ ] The prototype image builds on amd64 inside the kind jobs' 20-minute timeout, or the gap is stated with a number.
- [ ] The Renovate dry-run transcript is recorded, with a list of every pin it did not extract.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
