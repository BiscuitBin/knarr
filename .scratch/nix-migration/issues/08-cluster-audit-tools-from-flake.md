# 08: Cluster and audit tools from the flake

**Context:** [07](07-flake-beside-pixi.md) gives the Nix backend the tools the gate needs. The local cluster loop and the audits use more: kind and kubectl from pixi's optional `cluster` environment, kwokctl from `tools.txt`, and grype from the optional `audit` environment ([Decision 0007](../../../docs/decisions/0007-local-cluster.md), [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md)). CI cannot stop installing pixi until these come from the flake too.

**What to build:** Under `KNARR_TOOLS=nix`, `just cluster-install` and `just audit-install` build the flake's cluster and audit groups into their own out-links, and every cluster and audit recipe finds its tools there. The groups stay optional, as the pixi environments are. kind and kubectl are held to the versions the Kubernetes skew rule allows for the pinned 1.35 node image, and kwokctl stays at 0.8.0 to match the pinned kwok images.

Where each comes from is settled by [Decision 0017](../../../docs/decisions/0017-nix-owns-the-toolchain.md) and 01's [prototype](../evidence/01/flake.nix): kind 0.33.0 from the main input; kubectl 1.36.3 from the third input, `nixpkgs-kubectl`, which follows `nixos-26.05` because the main input's 1.37.2 breaks the skew cap; kwokctl 0.8.0 from the main input's `kwok` package, which carries it; and grype from the main input (0.120.0 at the candidate, one patch behind `pixi.toml`). `pins.toml` holds kind and kwokctl exactly and kubectl's minor, and the flake asserts each. On the x86_64 runner [05](05-nix-ci-renovate-spike.md) ran `just cluster-up` and `just cluster-ready` with the group's kind 0.33.0 and kubectl 1.36.3 and brought up `kindest/node:v1.35.8`; kwokctl has not run against a cluster yet. The runner ships its own `kind` and a kubectl 1.37.2, which a recipe finds on `PATH` when the `cluster` group is missing, so the guards must check the group, not the command. What grype logs for a Nix closure is already recorded in 01's [grype.txt](../evidence/01/grype.txt), with the flake's grype: `conda-meta-cataloger` finds nothing, and `nix-cataloger` and `binary-classifier-cataloger` find erlang and openssl.

CI has no Nix until [10](10-nix-becomes-the-gate.md). Every checker test this ticket adds must pass on a runner with no Nix present, and the boxes that need the Nix backend are proved by local transcripts in the hand-back notes.

**Non-goals:** CI. The images. `runtime-scan`'s logic, which is [11](11-runtime-scan-nix-closure.md). Changing the default backend. Changing the pinned node, kwok, KEDA or observability images.

**Blocked by:** 07

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** the network, for the Nix fetches and the cluster image pulls.
- [ ] Under `KNARR_TOOLS=nix`, `just cluster-up`, `just image-build`, `just image-load`, `just deploy` and `just smoke` pass on kind, and `just cluster-down` cleans up.
- [ ] Under `KNARR_TOOLS=nix` with `KNARR_CLUSTER=kwok`, `just cluster-up` and `just cluster-ready` pass.
- [ ] kubectl is within one minor of the node image's Kubernetes version, kind is 0.33.0 and kwokctl is 0.8.0. `pins.toml` owns all three, and the environment check compares them when the cluster group is installed.
- [ ] Without the optional group installed, a cluster or audit recipe refuses with a message naming the install recipe.
- [ ] With no `KNARR_TOOLS` set, the pixi cluster loop still works.
- [ ] `just test-checkers-selected cluster environment` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
