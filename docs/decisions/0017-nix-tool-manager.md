---
title: "Decision 0017: Nix owns the tools and the images"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_nix_tool_manager]
requires: []
---

# Decision 0017: Nix owns the tools and the images

Supersedes [Decision 0003: Tool manager](0003-tool-manager.md). It amends Decisions [0004](0004-gate-checkers.md), [0005](0005-project-managed-allium-cli.md), [0007](0007-local-cluster.md), [0012](0012-release-and-packaging.md) and [0014](0014-dependency-updates-and-audit.md) where they name pixi, `tools.txt` or the Ubuntu runtime image.

## Context

Decision 0003 gave pixi the compiler, OTP and the tools, and it worked. It also left knarr with two pin systems and an image built a third way:

- `pixi.toml` and `pixi.lock` pinned what conda-forge carries.
- `tools.txt` pinned seven downloads conda-forge lacks, installed by a script of knarr's own, for two host platforms only.
- The image was an Ubuntu base with a conda environment copied into it at a fixed prefix, pruned of a perl nothing ran, and scanned twice because no scanner reads conda records inside an image.

The maintainer asked for Nix to own all three: local development on Linux and Apple-silicon macOS, CI, and the container image. Decision 0003 never weighed Nix; its premise came from libpawdoku. This record does, and replaces it.

The evidence was gathered on 2026-11-14 on Linux x86_64 and is in [`.scratch/nix/evidence/01/`](../../.scratch/nix/evidence/01/README.md). [Verification](#verification) says what it does not cover.

## Decision

A flake owns every tool and both images. `flake.nix` has one input, nixpkgs, and `flake.lock` pins its revision and hash. The logic is in `nix/`.

### One pin

Every tool takes the version the pinned nixpkgs revision carries. Nothing in the repository writes a tool's version except the three exceptions below, so a pin move is one command, `nix flake update`, and its diff names a nixpkgs revision and no tool. `just tool-versions` prints what the installed environment holds; run it before and after.

The input is the `nixos-unstable` channel tarball, `https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz`. The channel answers with an immutable link, and the lock records that release URL, its `narHash` and the nixpkgs revision. The channel moves only when Hydra has built it, and locking it needs no GitHub API call. `github:NixOS/nixpkgs/nixos-unstable` names the same tree and is a one-line change if a tool wants that form.

The pin at this decision is nixpkgs `d4f25a3e`, 2026-11-11. Against what pixi pinned, OTP 29.1.2, rebar3 3.28.0, kind 0.33.0 and pytest 9.1.1 are unchanged, Gleam moves from 1.19.0 to 1.19.2, and OpenSSL moves from 3.6.5 to 3.5.9, nixpkgs' long-term-support line. hadolint is 2.14.0 where pixi had 2.15.1, and grype 0.120.0 where it had 0.120.1. [`pins.json`](../../.scratch/nix/evidence/01/pins.json) has the rest. No lint finding changed with the tools.

### What the flake packages itself

| Tool | Version | Why nixpkgs does not own it |
| --- | --- | --- |
| Allium | 3.6.1 | Not in nixpkgs. `nix/allium.nix` takes the release binary per host, by sha256 ([Decision 0005](0005-project-managed-allium-cli.md)) |
| kubectl | 1.36.0 | nixpkgs follows the newest Kubernetes, 1.37 at this pin, and kubectl supports one minor either side of the API server. `nix/kubectl.nix` takes the upstream binary, by the sha256 `dl.k8s.io` publishes |

kwokctl comes from nixpkgs, which carries 0.8.0, the release the controller image in `scripts/checks/cluster.py` is from. A test in `test_dependency_pins.py` fails when the two disagree, and another holds kubectl within one minor of the node images. tilt, which no recipe ran, is gone.

No bot rehashes these two files, as none rehashed `tools.txt`. To move one, change its version and take each platform's sha256 from the release.

### One Erlang

`nix/default.nix` binds one Erlang derivation, `beamMinimal29Packages.erlang`, and the rebar3 built with it. The tool environment, both shipment builds and the image runtime all receive that binding. Decision 0003 had one solve group, so that every environment got the same erlang build; this is the same store path, which is a stronger form of the same guarantee. The minimal build has no wx or systemd support, and Hydra builds it, so no host compiles Erlang.

The OTP version has one owner, the nixpkgs pin. `hex_audit.py` and `image.py` read it from the installed environment's version record instead of from `pixi.toml`.

### How recipes reach the tools

`just initialize` builds the flake's `tools` output behind an out-link, `.nix/tools`, which is gitignored and is a garbage-collector root. The Justfile and `scripts/with-env.sh` put `.nix/tools/bin` first on `PATH`. That is Decision 0003's arrangement with one directory where there were four.

Recipes never call `nix develop` or `nix run`, for the reason 0003 gave for `pixi run`: on a stale lock they rewrite `flake.lock` as they run. Every Nix call in a recipe, a script or a Dockerfile passes `--no-update-lock-file`, which refuses instead. `--no-write-lock-file` is the wrong flag: it carries on with a lock it made up.

The environment is one. Decision 0003 kept the cluster tools and grype out of the default environment because each pixi environment was installed per worktree, 836 MB for the cluster one. The Nix store is shared, so a worktree costs a symlink, and `just cluster-install` and `just audit-install` are gone.

`devShells.default` and a committed `.envrc` are conveniences. The `.envrc` only adds `.nix/tools/bin` to `PATH`; it does not evaluate the flake, so entering the directory fetches nothing.

The environment carries `share/knarr/pins.json`, the version of each tool a checker depends on. It names the nixpkgs source too, which keeps that source in the environment's closure, so a store collection cannot take what the offline gate evaluates.

### The gate

| Recipe | What it runs | What it refuses |
| --- | --- | --- |
| `lock-check` | `nix flake metadata --no-update-lock-file --offline`, then `nix flake check --no-build --all-systems` with the same two flags | A `flake.lock` that disagrees with `flake.nix`, and an output that does not evaluate, on any system |
| `env-check` | Compares `nix eval --raw --read-only --offline --no-update-lock-file .#tools` with the store path `.nix/tools` points at | Tools installed from an older pin |

Both are offline and write nothing in the worktree. The second command in `lock-check` is why a Linux CI run still proves the macOS tool set and both image roots evaluate. `env-check` now covers kind, kubectl and grype, which it never did.

Nix sees only files Git tracks. A new file under `nix/` must be staged before the flake can read it.

### The images

`nix/image.nix` decides everything an image holds. `nix/gleam-shipment.nix` builds the shipment, and each Dockerfile only runs the build and copies the result:

- **The shipment** is a derivation with no network. `manifest.toml` is its lock: each hex package is a fixed-output fetch keyed on the manifest's `outer_checksum`, unpacked where `gleam deps download` would put it, and `gleam export erlang-shipment` then downloads nothing. There is no second lock file to drift.
- **The root filesystem** is the closure of the runtime (Erlang, bash, coreutils and the openssl CLI), the shipment, `container-entrypoint.sh` and `/opt/build-otp`. The paths the chart and `image.py` name are unchanged.
- **Each Dockerfile** has a build stage, `nixos/nix` pinned by tag and index digest, that runs `nix build` on the rootfs, and a second stage that is `FROM scratch` with one `COPY`. The first `RUN` builds the toolchain, so only a pin move invalidates that layer.

The Ubuntu base is gone, and with it the perl prune, `scripts/prune_runtime.py` and the checks that perl stayed out. An image is 215 MB and holds 19 store paths.

Docker stays the builder because the local kind loop needs a `linux/arm64` image on an Apple-silicon host, and Nix on macOS cannot build a Linux derivation without a Linux builder. With Docker, the Dockerfile works unchanged there, and `just image-build`, hadolint and the release workflow's `docker buildx build` keep working as they did.

Docker's build stage runs Nix without its sandbox. So the kind smoke job first builds both roots with plain `nix build`, sandboxed; a build that reached for the network would fail there.

### The scans

An image has no OS package database, so `just image-scan` is grype's reading of the image as a whole. `just runtime-scan` keeps ticket 45's shape: it copies `/nix` out of the image, scans the copy as a directory, and fails closed unless grype's log shows `nix-cataloger` catalogued at least one package. The catalogue is 18 store packages, 34 OTP applications and 3 binaries.

### CI and Renovate

The setup action installs Nix with `cachix/install-nix-action`, restores the store with `nix-community/cache-nix-action` keyed on `flake.nix`, `flake.lock` and `nix/**`, saves it from `main` only, and runs `scripts/initialize.sh`. Neither action needs an account. Without a cache hit the tools come from `cache.nixos.org`.

Renovate's `nix` manager replaces the `pixi` manager and the five-place pixi version. The nixpkgs pin is held for approval, because it moves every tool and both images at once. The `nixos/nix` build image moves through the dockerfile manager as a routine update.

## What stays in force from Decision 0003

- The `manifest.toml` pre-check and the `cksum` backstop around every gleam command. The shipment derivation applies the same backstop.
- One owner per pin, and no hook that installs its own copy of a tool.
- The TLS check: `just image-check` reruns it inside the image with the image's own Erlang and openssl.
- Recipes reach tools through `PATH`, never through the tool manager's `run`.

## Alternatives considered

- **Stay on pixi.** It works, but it keeps two pin systems, a per-worktree install, a download script with two host platforms, and an image whose contents no single file decides.
- **Require `nix develop`.** Git hooks, agents and editors run outside any shell, and wrapping each hook in `nix develop -c` costs an evaluation per hook and can rewrite `flake.lock`. The out-link gives them a stable path and confines Nix evaluation to `initialize`, `lock-check` and `env-check`.
- **Exact per-tool pins through overrides.** An overridden package is built from source on every host and in every image build, and each bump is a hand-edited version and hash. The maintainer chose one pin.
- **A Gleam packaging helper as a second flake input.** It would be a second pin, and the build it wraps is short enough to own.
- **Network inside the Dockerfile for the gleam build.** The image would then be only partly decided by the flake, and not reproducible from the lock.

## Recorded for future exploration

The maintainer chose the Dockerfile that wraps a Nix build, and asked that the two alternatives be kept on record:

- **Pure `dockerTools.streamLayeredImage`, no Dockerfile.** The flake would output the image itself, with reproducible layers that deduplicate across releases, and hadolint and the build-stage image pin would have nothing left to check. It needs a Nix Linux builder on macOS for the kind loop. The release workflow would push with skopeo instead of `docker buildx build`, so its labels, its digest capture and the tests in `test_workflows.py` that pin its text would all be rewritten, and a release cannot be rehearsed without a tag.
- **`dockerTools` with Nix inside Docker on macOS.** The same flake-built image, with `just image-build` running the Nix build in a `nixos/nix` container on macOS and piping the result to `docker load`. No Linux builder is needed, but there are two build paths to keep working, a persistent `/nix` volume to manage, and the same release rewrite.

Either becomes attractive if the image needs reproducible layers, or once a Linux builder on macOS is something contributors already have.

## Verification

Verified on Linux x86_64 ([evidence](../../.scratch/nix/evidence/01/README.md)):

1. Every tool is in the binary cache for x86_64-linux, aarch64-linux and aarch64-darwin; nothing builds from source.
2. `just initialize` builds the environment, and every gate recipe passes with it except `just test`, where 671 of 676 tests pass and the other five need IPv6, which the container's kernel lacks.
3. `lock-check` and `env-check` refuse a stale lock and leave `flake.lock` unchanged.
4. Both shipments build in Nix's sandbox with no network, the three rebar3 packages included.
5. Both Dockerfiles build in Docker, and `scripts/checks/image.py` passes for both images: the numeric user, the read-only root, the TLS check and, for the fake worker, the SIGTERM drain.
6. `runtime_scan.py` copies the store out of the real image and grype catalogues it.

Not verified, and the first run of each will say:

- **macOS on Apple silicon.** The darwin outputs evaluate and are in the cache. Nothing was run there, the Allium binary's signature under Nix included.
- **Linux arm64,** as a host and as an image architecture.
- **kind and kwok clusters,** the KEDA harness and the reconcile proof.
- **grype's matching** against store packages. It was run without its database, so the catalogue is known and the findings are not. Store packages are matched by CPE, and nixpkgs patches some CVEs without a version change, so false positives are possible.
- **The descriptor cap above 65536** inside Docker: the container's own limit was 20000.
- **GitHub Actions:** the two actions, the store cache, and the release workflow. An `-rc` tag before the next stable release would rehearse the last.
- **Renovate's `nix` manager** on a channel-tarball input. Lock-file maintenance runs `nix flake update` for any input; whether it also proposes updates outside maintenance is unknown.

## Consequences

- Contributors need Nix with flakes, git and a POSIX shell, and Docker for images and clusters. pixi and the download script are gone.
- Tools no longer move one at a time. A nixpkgs update can change a linter's findings, and the pull request that moves the pin absorbs them.
- The tool environment's closure is 1.5 GB, shared between worktrees, where pixi installed 521 MB or more in each.
- The image is `FROM scratch` with nixpkgs' glibc. It has no package manager and no shell beyond bash and coreutils.
- NixOS hosts are not claimed: the checker tests assume `/usr/bin:/bin`.
- Linux arm64 hosts can now run the tools, which `tools.txt` never allowed. That is untested.

## What would reopen this

- **Hydra stops building `beamMinimal29Packages.erlang`,** or nixpkgs drops OTP 29 before knarr moves. A source build in every cold image build is a cost to weigh again.
- **A tool the gate needs leaves nixpkgs,** or its nixpkgs version cannot be used. Package it in the flake, as kubectl is.
- **nixpkgs' kwok moves off the controller image's release.** Move the image by hand, or package kwokctl in the flake.
- **The runtime scan's findings are mostly false positives.** Scan an SBOM of the closure, such as sbomnix writes, instead of the directory.
- **Cold image builds are too slow in CI.** Add a BuildKit cache for the build stage.
- **A Linux builder on macOS becomes ordinary.** Revisit the two image alternatives above.
