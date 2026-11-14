# 10: Nix becomes the gate

**Context:** After [08](08-cluster-audit-tools-from-flake.md) every tool has a source in the flake, and after [09](09-images-from-flake.md) the images build from it. pixi is still the default backend, and CI still installs it. The default and the CI setup action have to move in the same pull request: other rounds' commits land between tickets, and a tree whose default is Nix while CI installs pixi is red.

**What to build:** A contributor needs Nix, Docker, git and a POSIX shell. `just initialize` and `just check` use the flake with no variable set, locally and in CI.

- **The default.** The seam's tracked default becomes `nix`. `KNARR_TOOLS=pixi` still works until [13](13-delete-pixi.md).
- **The setup action.** It installs Nix with the action and cache strategy Decision 0017 chose, runs `just initialize`, and installs the cluster and audit groups on request. It exports the selected tool directories to the job's `PATH`.
- **The evidence scripts.** `reconcile-proof.yml` runs scripts under `.scratch/bootstrap/evidence/` that prepend pixi's directories and then keep the inherited `PATH`. Evidence is never rewritten ([Decision 0016](../../../docs/decisions/0016-biscuitbin-org.md)'s keep-list). They keep working because the action exports the tool directories. A policy test holds that each script the workflow runs still ends its `PATH` line with the inherited `PATH`.
- **Pin tests and Renovate rules.** The slices that read the setup action and the contributing guide's prerequisite line move to the Nix equivalents.
- **Version differences.** The findings 04 marked "accept and fix in 10" are fixed here.
- **Docs and skills.** The contributing guide's Getting started, pin-move routine and network list; the documentation contract's note on where Node comes from; the `project-check` and `fix-quality` skills; and the `AGENTS.md` authorization line if a recipe name changed. Decisions 0003, 0004, 0005 and 0007 gain amendment notes. `CHANGELOG.md` records the change.

**Non-goals:** Deleting any pixi file or the pixi backend. `runtime-scan` and the Renovate nix manager, which are [11](11-runtime-scan-nix-closure.md) and [12](12-renovate-reads-flake.md). Splitting this across pull requests: if it does not fit one session, the parts share one integration branch and merge together.

**Blocked by:** 08, 09

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** a push. `ci.yml` passes on the pull request, including `cluster-smoke`, `fake-worker-smoke`, `cluster-kwok` and `checker-regressions`.
- [ ] **Authorization required:** the `cluster-s1` label. `reconcile-proof.yml` passes on the pull request before merge, because merging a `Justfile` or setup-action change runs it on `main`.
- [ ] A fresh clone with only Nix, Docker and git reaches a passing `just check` by following the contributing guide, and the gate passes again with the network off.
- [ ] No workflow names an OTP, Gleam or tool version, and every action is still pinned by SHA.
- [ ] The setup action writes its cache from `main` only, or the ticket records why the chosen strategy differs.
- [ ] `just agents-check` and `just docs-check` pass. No new file is added under `.claude/` or `.agents/`.
- [ ] **Authorization required:** the maintainer runs `just initialize` in the primary checkout after the merge, so its git hook resolves to the Nix environment. The hand-back records that a commit there ran the hooks.
- [ ] `just test-checkers-all` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
