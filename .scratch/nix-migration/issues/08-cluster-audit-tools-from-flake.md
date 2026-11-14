# 08: Cluster and audit tools from the flake

**Context:** [07](07-flake-beside-pixi.md) gives the Nix backend the tools the gate needs. The local cluster loop and the audits use more: kind and kubectl from pixi's optional `cluster` environment, kwokctl from `tools.txt`, and grype from the optional `audit` environment ([Decision 0007](../../../docs/decisions/0007-local-cluster.md), [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md)). CI cannot stop installing pixi until these come from the flake too.

**What to build:** Under `KNARR_TOOLS=nix`, `just cluster-install` and `just audit-install` build the flake's cluster and audit groups into their own out-links, and every cluster and audit recipe finds its tools there. The groups stay optional, as the pixi environments are. kind and kubectl are held to the versions the Kubernetes skew rule allows for the pinned 1.35 node image, and kwokctl stays at 0.8.0 to match the pinned kwok images.

CI has no Nix until [10](10-nix-becomes-the-gate.md). Every checker test this ticket adds must pass on a runner with no Nix present, and the boxes that need the Nix backend are proved by local transcripts in the hand-back notes.

**Non-goals:** CI. The images. `runtime-scan`'s logic, which is [11](11-runtime-scan-nix-closure.md). Changing the default backend. Changing the pinned node, kwok, KEDA or observability images.

**Blocked by:** 07

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** the network, for the Nix fetches and the cluster image pulls.
- [ ] Under `KNARR_TOOLS=nix`, `just cluster-up`, `just image-build`, `just image-load`, `just deploy` and `just smoke` pass on kind, and `just cluster-down` cleans up.
- [ ] Under `KNARR_TOOLS=nix` with `KNARR_CLUSTER=kwok`, `just cluster-up` and `just cluster-ready` pass.
- [ ] kubectl is within one minor of the node image's Kubernetes version and kwokctl is 0.8.0. The held-versions file owns both, and the environment check compares them when the cluster group is installed.
- [ ] Without the optional group installed, a cluster or audit recipe refuses with a message naming the install recipe.
- [ ] The ticket records whether grype from the flake still prints the cataloger line `runtime-scan` expects, for 11.
- [ ] With no `KNARR_TOOLS` set, the pixi cluster loop still works.
- [ ] `just test-checkers-selected cluster environment` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
