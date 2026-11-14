# 12: Renovate reads the flake

**Context:** [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) has Renovate propose every pin move. Its `pixi` manager tracks `pixi.toml` and `pixi.lock`, package rules group and hold the conda pins, and the pin tests assert those rules. [09](09-images-from-flake.md) and [10](10-nix-becomes-the-gate.md) already moved the rules for the build-stage image and the setup action. What is left is the manager itself. [05](05-nix-ci-renovate-spike.md) recorded what Renovate's nix manager extracts.

**What to build:** Renovate proposes moves of the flake's inputs and of each pin in the held-versions file, in place of the pixi ones.

- The nix manager replaces the `pixi` manager, with lock maintenance for `flake.lock` under the same dashboard-approval rule the pixi lock had.
- Each held version has a way to be proposed. Where 05 showed the nix manager cannot read the held-versions file, a regex manager does.
- Erlang and the local-cluster group keep waiting for approval. The Kubernetes 1.35 and etcd 3.6 caps are unchanged.
- The pin tests' conda and local-cluster cases are rewritten for the new rules.
- The contributing guide's pin-move routine names the Nix commands, and Decision 0014 gains an amendment note.

**Non-goals:** Activating the Renovate app, which is bootstrap ticket [44](../../bootstrap/issues/44-renovate-activation.md); that ticket's text is updated where it names the pixi manager. Any automerge.

**Blocked by:** 09, 10

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** the network, for a Renovate dry run. Its transcript shows every flake input and every held pin extracted, and the ticket lists anything that stays a manual move.
- [ ] No `pixi` manager, rule or regex remains in the Renovate configuration.
- [ ] The Kubernetes and etcd cap rules are byte-identical to before.
- [ ] The pin tests assert the approval rules for Erlang and the cluster group.
- [ ] `just test-checkers-selected policy` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
