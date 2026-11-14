# 01: Container spike: Nix facts on Linux

**Context:** The maintainer decided on 2026-11-14 to move knarr's toolchain from pixi to Nix (see the [round README](../README.md)). [Decision 0003](../../../docs/decisions/0003-tool-manager.md) chose pixi from evidence gathered by bootstrap ticket [01](../../bootstrap/issues/01-tool-manager-decision.md), and its Verify 1 to 5 must be answered again for Nix. Nothing about nixpkgs has been checked yet. This ticket gathers the facts that need no host install: it runs Nix inside a digest-pinned container on the host's Docker.

**What to build:** Evidence under `.scratch/nix-migration/evidence/01/` (a `README.md`, the scripts and their transcripts), in the shape of bootstrap ticket 01's evidence. A prototype `flake.nix` and `flake.lock` live in the evidence directory only. The evidence answers:

- **Packages.** At one candidate nixpkgs revision, a table with a row for every tool `pixi.toml` and `tools.txt` pin: the attribute, the version, and whether the binary cache has it for aarch64-linux, x86_64-linux and aarch64-darwin. The table marks each floor the repository depends on: Python 3.14 or later, pytest 9, allium exactly 3.6.1, rebar3 3.28.0 or later, Helm major 4, kwokctl 0.8.0, and Node with markdownlint-cli2's bundled markdown-it.
- **Held versions.** How OTP 29.1.2 with its OpenSSL, and Gleam 1.19.0, are held exactly. Whether an override forfeits the binary cache, and whether a second pinned nixpkgs input keeps it.
- **Missing tools.** For each tool nixpkgs lacks (allium and kwokctl are the likely ones), whether a fixed-hash fetch of the upstream asset `tools.txt` names today runs from the store on Linux.
- **Lock behaviour.** A drift table like Decision 0003's: which commands rewrite `flake.lock`, and which command is a read-only, offline check that exits non-zero on drift.
- **Flakes and git.** Whether untracked files are invisible to a flake, what is copied to the store on each evaluation, and what happens in a linked worktree and in a Docker build context with no `.git`.
- **Image.** A prototype image built by `docker build` with Nix in a pinned build stage. Nix supplies gleam, erlang and rebar3, the build stage runs `gleam deps download` and `gleam export erlang-shipment` as today, and the final Ubuntu stage receives the runtime closure at a fixed prefix. The record states whether perl is in Erlang's closure, the image size against today's, and cold and warm build times.
- **TLS.** Bootstrap ticket 01's TLS proof passes all six cases in that prototype image, run with the restrictions `image-check` applies (read-only, all capabilities dropped).
- **Scanning.** A grype transcript on the prototype's runtime closure: which cataloger it logs, whether erlang and openssl are catalogued, and directory source against image source.

**Non-goals:** Any tracked flake file outside the evidence directory. Facts about macOS or the amd64 runner, which are [04](04-nix-host-spike.md) and [05](05-nix-ci-renovate-spike.md). Building hex packages with Nix: they stay with gleam.

**Blocked by:** None (can start immediately)

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** the network, for the container image pull and the Nix cache fetches. The Nix container image is pinned by digest.
- [ ] The package table has a row for every line of `pixi.toml` and `tools.txt`, with tilt marked as unused and not carried forward.
- [ ] The hold mechanism for OTP, OpenSSL and Gleam is chosen, with a transcript showing whether each held package came from the binary cache.
- [ ] Each tool nixpkgs lacks has a named source and a transcript of it running.
- [ ] The drift table names the read-only offline lock check, and a transcript shows `flake.lock` byte-identical after running it on a drifted copy.
- [ ] The flakes-and-git findings are recorded, including the linked-worktree case.
- [ ] The prototype image builds on linux/arm64, and the six TLS cases pass in it under `image-check`'s restrictions.
- [ ] The grype transcript is recorded.
- [ ] This round's `evidence/` directory is added to the evidence excludes the other rounds have in the hook and linter configs.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
