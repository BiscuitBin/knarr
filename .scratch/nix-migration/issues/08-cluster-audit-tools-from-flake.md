# 08: Cluster and audit tools from the flake

**Context:** [07](07-flake-beside-pixi.md) gives the Nix backend the tools the gate needs. The local cluster loop and the audits use more: kind and kubectl from pixi's optional `cluster` environment, kwokctl from `tools.txt`, and grype from the optional `audit` environment ([Decision 0007](../../../docs/decisions/0007-local-cluster.md), [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md)). CI cannot stop installing pixi until these come from the flake too.

**What to build:** Under `KNARR_TOOLS=nix`, `just cluster-install` and `just audit-install` build the flake's cluster and audit groups into their own out-links, and every cluster and audit recipe finds its tools there. The groups stay optional, as the pixi environments are. kind and kubectl are held to the versions the Kubernetes skew rule allows for the pinned 1.35 node image, and kwokctl stays at 0.8.0 to match the pinned kwok images.

Where each comes from is settled by [Decision 0017](../../../docs/decisions/0017-nix-owns-the-toolchain.md) and 01's [prototype](../evidence/01/flake.nix): kind 0.33.0 from the main input; kubectl 1.36.3 from the third input, `nixpkgs-kubectl`, which follows `nixos-26.05` because the main input's 1.37.2 breaks the skew cap; kwokctl 0.8.0 from the main input's `kwok` package, which carries it; and grype from the main input (0.120.0 at the candidate, one patch behind `pixi.toml`). `pins.toml` holds kind and kwokctl exactly and kubectl's minor, and the flake asserts each. On the x86_64 runner [05](05-nix-ci-renovate-spike.md) ran `just cluster-up` and `just cluster-ready` with the group's kind 0.33.0 and kubectl 1.36.3 and brought up `kindest/node:v1.35.8`; kwokctl has not run against a cluster yet. The runner ships its own `kind` and a kubectl 1.37.2, which a recipe finds on `PATH` when the `cluster` group is missing, so the guards must check the group, not the command. What grype logs for a Nix closure is already recorded in 01's [grype.txt](../evidence/01/grype.txt), with the flake's grype: `conda-meta-cataloger` finds nothing, and `nix-cataloger` and `binary-classifier-cataloger` find erlang and openssl.

CI has no Nix until [10](10-nix-becomes-the-gate.md). Every checker test this ticket adds must pass on a runner with no Nix present, and the boxes that need the Nix backend are proved by local transcripts in the hand-back notes.

**Non-goals:** CI. The images. `runtime-scan`'s logic, which is [11](11-runtime-scan-nix-closure.md). Changing the default backend. Changing the pinned node, kwok, KEDA or observability images.

**Blocked by:** 07

**MVP critical path:** no.

**Status:** done on its branch, awaiting a pull request. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** the network, for the Nix fetches and the cluster image pulls.
- [x] Under `KNARR_TOOLS=nix`, `just cluster-up`, `just image-build`, `just image-load`, `just deploy` and `just smoke` pass on kind, and `just cluster-down` cleans up.
- [x] Under `KNARR_TOOLS=nix` with `KNARR_CLUSTER=kwok`, `just cluster-up` and `just cluster-ready` pass.
- [x] kubectl is within one minor of the node image's Kubernetes version, kind is 0.33.0 and kwokctl is 0.8.0. `pins.toml` owns all three, and the environment check compares them when the cluster group is installed.
- [x] Without the optional group installed, a cluster or audit recipe refuses with a message naming the install recipe.
- [x] With no `KNARR_TOOLS` set, the pixi cluster loop still works.
- [x] `just test-checkers-selected cluster environment` passes.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

- **`scripts/tool-group.sh`**, new: `install|check cluster|audit`. It asks `tool-dirs.sh` for the backend and the group's prefix, so an unknown `KNARR_TOOLS` is refused there with exit 2. `install` runs `pixi install --locked -e <group>` or `nix build --no-update-lock-file --out-link <prefix> .#<group>` from the checkout, after checking the installer is on `PATH` (the same messages as `initialize.sh`). `check` exits 0 silently when the group's own `bin` holds each member as an executable file, and otherwise exits 2 with `the <backend> <group> group is not installed; run just <group>-install`. It never looks at `PATH`, so a runner's own kind or kubectl cannot pass it. The members: cluster is kind and kubectl under pixi (kwokctl is a `tools.txt` download there, installed by `just initialize`) and kind, kubectl and kwokctl under Nix; audit is grype.
- **`Justfile`.** `cluster-tools` and `audit-tools` run `tool-group.sh check`; `cluster-install` and `audit-install` run `tool-group.sh install`, with descriptions naming both backends. Every cluster and audit recipe already depended on one of the two guards; no recipe runs kind, kubectl, kwokctl or grype without one.
- **`scripts/checks/env_check.py`**, Nix branch: when `.nix/cluster` exists, a second offline `nix eval` of `#cluster` (the same `--apply`) gives the out path; a different target, a target outside the store, or a non-link is drift; then `kind version` and `kwokctl --version` must report `pins.toml`'s exact versions and `kubectl version --client` its minor. Cluster drift exits 1 and says `run just cluster-install`; default-group drift still says `run just initialize`. Without the group it makes the one call it made before. The audit group is not compared: grype is not held. The pixi branch is unchanged.
- **Tests.** New `test_tool_group.py` (environment group): both backends, both groups, the install commands and where they run, the missing installer, the unknown backend, usage errors, and the Justfile's guards refusing with host stand-ins on `PATH` and running nothing past the guard. `test_env_check.py` gains the cluster cases on a stand-in `nix` that answers per group. `test_pins.py` (policy) gains two Nix-free holds: `pixi.toml`'s kind and kubectl minor and `tools.txt`'s kwokctl equal `pins.toml`'s, and `pins.toml`'s kubectl minor is within one minor of every server version `cluster.py` pins (the kind node, the kwok API server image and `KWOK_KUBE_VERSION`). Editing `pins.toml`'s kubectl to 1.37 and kwokctl to 0.8.1 failed both before they were reverted.
- **`checker_suite.py`**: `tool_group` and `scripts/tool-group.sh` join the environment group.
- **`docs/how-to/local-cluster.md`**: install the cluster tools with `just cluster-install`, which builds the flake's groups under `KNARR_TOOLS=nix`.
- **Evidence** in [`../evidence/08/`](../evidence/08/README.md): seven scripts, their transcripts and a README.

### What was verified, and on which system

On **aarch64-linux**, in 07's stand-in host widened with the Mac's Docker socket, host networking and the work volume at the daemon's own path ([README](../evidence/08/README.md#how-it-ran)), on the clone at `2a5b4baf16c1`:

- Box 2: `KNARR_TOOLS=nix` `just cluster-up`, `image-build`, `image-load`, `deploy`, `smoke` and `cluster-down` all exited 0 on kind, and kind listed no cluster afterwards ([kind.txt](../evidence/08/kind.txt)). The image build was served wholly from the daemon's build cache.
- Box 3: with `KNARR_CLUSTER=kwok`, `cluster-up`, `cluster-ready` and `cluster-down` exited 0 ([kwok.txt](../evidence/08/kwok.txt)). The first run of the flake's kwokctl against a cluster.
- Box 4: kind v0.33.0, kubectl v1.36.3 against servers v1.35.8 (kind) and v1.35.5 (kwok), kwokctl v0.8.0; `just env-check` compares the installed cluster group and fails a moved one with `run just cluster-install` ([setup.txt](../evidence/08/setup.txt), [drift.txt](../evidence/08/drift.txt)).
- Box 5: before either group was installed, six cluster and audit recipes exited 2 naming the install recipe, with stand-in host tools on `PATH` that never ran ([setup.txt](../evidence/08/setup.txt)).
- Boxes 7 and 8 on Nix too, offline with both groups installed: 318 passed and 14 skipped, and `KNARR_TOOLS=nix just check` ended "All checks passed and the worktree is unchanged." ([gate.txt](../evidence/08/gate.txt)).

On the **Mac** (aarch64-darwin), on pixi with no `KNARR_TOOLS`:

- Box 6: `just cluster-install` through the new script, then the kind loop and the kwok loop all exited 0 ([pixi.txt](../evidence/08/pixi.txt)).
- Box 7: `just test-checkers-selected cluster environment` passed. Box 8: `just check` ended "All checks passed and the worktree is unchanged." with every change staged, after these notes.
- Red first: the 50 cases of `test_tool_group.py` failed before the script and recipes existed, and the seven cluster cases of `test_env_check.py` before `env_check.py` changed.

Not verified: anything on x86_64-linux or aarch64-darwin under Nix; a cold image build; grype with a database newer than the Mac's cached copy; `keda-e2e`, the fake-worker and observability recipes under Nix (same guard, same `PATH`, no other tool).

Left on the Mac's Docker, on purpose: the volume `knarr-nix-08-work` (the clone with its three out-links, the stand-in Docker client, a 3.1 GB copy of the Mac's grype database, logs and Nix's caches), and in the shared `knarr-nix-store` the cluster and audit groups, `docker-client` 29.9.3, `docker-buildx` 0.38.1 and `docker-compose` 5.7.0. The images `knarr:clone-7f423a53` and `knarr:08-cluster-audit-tools-76cc9e7c` (the two builds), the kind node and kwok images the loops pulled, and BuildKit's cache stay in the daemon. No cluster or container from this ticket remains; the `kind` Docker network, which kind creates once and keeps for every cluster, is still there. Nothing was installed on the host.

### What later tickets need

- **10.** CI's setup action can keep calling `just cluster-install` and `just audit-install`: under `KNARR_TOOLS=nix` they build the flake's groups. The guards no longer accept the runner's own kind or kubectl. When the default flips, the refusal strings in `test_tool_group.py` (`REFUSAL`) and `test_check_follows_the_tracked_default` follow it. `env-check` under Nix runs a second evaluation, about a second, only where the cluster group is installed. kwokctl and grype from the flake have not run on x86_64-linux.
- **11.** The flake's grype 0.120.0 prints the line `runtime_scan.py` reads, `discovered N packages cataloger=conda-meta-cataloger`, on a conda directory: 12 on today's image ([grype.txt](../evidence/08/grype.txt)). For a Nix closure that line is absent, as 01's [grype.txt](../evidence/01/grype.txt) showed; the packages arrive as `nix-cataloger` and `binary-classifier-cataloger`, which is what 11 must read instead.
- **13.** Deleting pixi removes `tool-group.sh`'s pixi arms, its `pixi:cluster` member list, the pixi cases in `test_tool_group.py`, and `test_pins.py`'s `pixi.toml` and `tools.txt` hold for the cluster tools.
- **12.** kind, kwokctl and kubectl's minor are in `pins.toml`, read by the flake and by `test_pins.py`, which also holds kubectl's minor within one of `cluster.py`'s server versions, so a Renovate move of the node or kwok images to 1.37 or later fails that test until `pins.toml` and the kubectl input move too.

Against the ticket and Decision 0017:

- The brief asked for Nix in the `nixos/nix` image; as in 07, the recipes ran on the Ubuntu stand-in using that image's Nix from the shared store, because the Nix image cannot run them.
- The environment check's cluster comparison is Nix-only. Under pixi, `pins.toml`'s ownership of the three is held by the policy test instead, since `pixi.lock` already pins the cluster environment.
- 0017 says `just initialize` builds "each installed group"; `initialize.sh` still builds the default group only, and a drifted cluster group is reported with `run just cluster-install`, the recipe that rebuilds it.
