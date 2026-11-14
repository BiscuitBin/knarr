# 12: Renovate reads the flake

**Context:** [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) has Renovate propose every pin move. Its `pixi` manager tracks `pixi.toml` and `pixi.lock`, package rules group and hold the conda pins, and the pin tests assert those rules. [09](09-images-from-flake.md) and [10](10-nix-becomes-the-gate.md) already moved the rules for the build-stage image and the setup action. What is left is the manager itself. [05](05-nix-ci-renovate-spike.md) recorded what Renovate's nix manager extracts.

**What to build:** Renovate proposes moves of the flake's channel inputs, in place of the pixi pins, and at most notices a newer release of a held version in `pins.toml`. It never proposes a held version as an update.

[01](01-nix-container-spike.md) and [05](05-nix-ci-renovate-spike.md) settled what Renovate can do here ([Decision 0017](../../../docs/decisions/0017-nix-owns-the-toolchain.md#dependency-updates), [05's README](../evidence/05/README.md#7-renovates-nix-manager), Renovate 44.239.1):

- A held version is not a free-standing pin. It is the version the locked revision of its input carries, and the flake only asserts it against `pins.toml`. A bump of `pins.toml` alone fails evaluation until someone moves the input to a revision that carries the new version, and no bot finds that revision. 01 found Gleam's by reading the channel releases on releases.nixos.org ([holds.txt](../evidence/01/holds.txt)). So a held version can at best be noticed, never proposed.
- The nix manager is off by default: it needs `"nix": {"enabled": true}` as well as `enabledManagers`. It extracts the three inputs from `flake.lock` through git-refs, with no token.
- A channel input's locked revision moves only through lock-file maintenance, which runs `nix flake update` and needs a `nix` binary (the `-full` image ships one; the slim image installs it on demand). In 05's simulation it moved both channel inputs and every hold still evaluated. Renovate moving `flake.lock` through a branch was not seen, because the local platform makes none.
- The revision-pinned `nixpkgs-gleam` is extracted and proposed to move to nixpkgs `master` `HEAD`, which would replace the Gleam hold with an unreleased commit.
- A release channel's name is proposed to move: `nixos-25.11` drew `major → nixos-26.05`. When nixos-26.11 is released, `nixpkgs-kubectl` would be proposed onto a channel carrying kubectl 1.37.
- Not extracted: the held versions, the allium asset URL and its three sha256.

The configuration:

- The nix manager replaces the `pixi` manager: `"nix"` in `enabledManagers` and `"nix": {"enabled": true}`. Lock-file maintenance for `flake.lock` runs under the same dashboard-approval rule the pixi lock had. `"constraints": {"nix": "2.35.6"}` fixes the Nix version Renovate installs, since its default lookup was refused without a token in 05's dry run.
- A rule switches off `nixpkgs-gleam` (`matchManagers: ["nix"]`, `matchDepNames: ["nixpkgs-gleam"]`), as the configuration already switches off the kwok image. Any later input pinned by revision gets the same rule.
- A rule holds `nixpkgs-kubectl` to its release channel, for example with `allowedVersions`, as the configuration holds the kind node to 1.35.
- Erlang and the local-cluster group keep waiting for approval. The Kubernetes 1.35 and etcd 3.6 caps are unchanged.
- Held versions are manual moves. A regex manager may notice a newer release of one (allium names an upstream release directly), but its proposal cannot pass the gate on its own. The contributing guide's pin-move routine says how to complete one: find a revision that carries the version, move the input, edit `pins.toml`, rerun the gate; and for allium, rehash its three assets by hand, as the kwok and KEDA pins move today.
- The pin tests' conda and local-cluster cases are rewritten for the new rules.
- The contributing guide's pin-move routine names the Nix commands, and Decision 0014 gains an amendment note.

**Non-goals:** Activating the Renovate app, which is bootstrap ticket [44](../../bootstrap/issues/44-renovate-activation.md); that ticket's text is updated where it names the pixi manager. Any automerge.

**Blocked by:** 09, 10

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** the network, for a Renovate dry run. Its transcript shows the three flake inputs extracted, no proposal for `nixpkgs-gleam`, and no proposal moving `nixpkgs-kubectl` off its channel, and the ticket lists every pin that stays a manual move, every held version among them.
- [ ] The build-stage `FROM` lines are proposed as tag-and-digest updates, as 09 wrote them.
- [ ] No `pixi` manager, rule or regex remains in the Renovate configuration.
- [ ] The Kubernetes and etcd cap rules are byte-identical to before.
- [ ] The pin tests assert the approval rules for Erlang and the cluster group, the rule that switches off `nixpkgs-gleam`, and the channel hold on `nixpkgs-kubectl`.
- [ ] `just test-checkers-selected policy` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
