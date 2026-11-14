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
- **The gate from a `PATH` prefix.** In a clone inside the container, never a bind-mounted worktree, with only the prototype environment's directories prefixed:
  - the checker tests run through the interpreter's own pytest;
  - the docs checker's Node finds markdownlint-cli2's bundled markdown-it;
  - the path prek writes into the git hook still resolves after a lock move;
  - a fresh clone with only Nix installed can reach `just`;
  - the whole of `just check` runs with the network off, with timings for the lock and environment checks and a record of anything they write.
- **Version differences.** The list of formatter and linter findings that differ between the pixi versions and the candidate revision's versions, on today's tree.
- **Scanning.** A grype transcript on the prototype's runtime closure: which cataloger it logs, whether erlang and openssl are catalogued, and directory source against image source.

**Non-goals:** Any tracked flake file outside the evidence directory. Anything that needs Nix on the Mac, which is [04](04-nix-host-spike.md): the evidence lists each darwin fact it could only evaluate, not run. Builds on the amd64 runner, which are [05](05-nix-ci-renovate-spike.md). Building hex packages with Nix: they stay with gleam.

**Blocked by:** None (can start immediately)

**MVP critical path:** no.

**Status:** done on aarch64-linux: the evidence is recorded; aarch64-darwin and x86_64-linux were evaluated only, for 04 and 05 to run.

- [x] **Authorization required:** the network, for the container image pull and the Nix cache fetches. The Nix container image is pinned by digest.
- [x] The package table has a row for every line of `pixi.toml` and `tools.txt`, with tilt marked as unused and not carried forward.
- [x] The hold mechanism for OTP, OpenSSL and Gleam is chosen, with a transcript showing whether each held package came from the binary cache.
- [x] Each tool nixpkgs lacks has a named source and a transcript of it running.
- [x] The drift table names the read-only offline lock check, and a transcript shows `flake.lock` byte-identical after running it on a drifted copy.
- [x] The flakes-and-git findings are recorded, including the linked-worktree case.
- [x] The prototype image builds on linux/arm64, and the six TLS cases pass in it under `image-check`'s restrictions.
- [x] Each PATH-prefix case has a transcript from the container.
- [x] A transcript shows the whole gate passing from the scratch prefix with the network off, or lists each failure with its cause.
- [x] The version-difference list is recorded, each entry marked "hold the pixi version" or "accept and fix in 10".
- [x] The evidence lists the darwin facts it evaluated but could not run, for 04 and Decision 0017.
- [x] The grype transcript is recorded.
- [x] This round's `evidence/` directory is added to the evidence excludes the other rounds have in the hook and linter configs.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

- `.scratch/nix-migration/evidence/01/`: the evidence. Its [README](../evidence/01/README.md) states each finding and names the transcript that proves it, and has a table of the scripts. The prototype is `flake.nix`, `flake.lock`, `env-check.sh`, `gate-scratch.patch` and `image/Dockerfile`. No flake file is tracked anywhere else.
- `.pre-commit-config.yaml`: `nix-migration` joins `bootstrap`, `helm-chart` and `org-transfer` in the editorconfig-checker hook's evidence exclude. That is the only exclude the other rounds have. `.pre-commit-fix.yaml`, `taplo.toml`, `ruff.toml` and the gleam-format hook name the bootstrap round alone and were left as they are.
- This ticket.

Left on the Mac's Docker, on purpose: the volumes `knarr-nix-store` (the Nix store) and `knarr-nix-01-work` (the clones and Nix's caches), and the images `knarr-nix-proto:01` (the prototype) and `knarr-nix-proto:pixi-baseline` (today's Dockerfile for linux/arm64). Nothing was installed on the host.

### What was verified, and what was not

Everything ran on **aarch64-linux**: Nix 2.35.6 in `nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed` on the Mac's Docker, and the gate on the Ubuntu 24.04 base image with that store mounted. x86_64-linux and aarch64-darwin were evaluated and the binary cache asked about them, nothing more.

- **Candidate:** nixpkgs-unstable `2074cc672349f14240fb7ea90d509e0b643e9dd4` (2026-11-12). nixos-26.05 fails two floors (Helm 3.20.2, kwok 0.7.0).
- **Packages:** every `pixi.toml` and `tools.txt` line has a row. Everything nixpkgs carries is cached on all three systems. Only allium is absent. hadolint (2.14.0) and grype (0.120.0) are behind their pins. tilt is marked unused and not carried forward.
- **Holds:** OTP 29.1.2 is the candidate's own `beam_minimal.interpreters.erlang_29`, built against OpenSSL 3.5.9, not pixi.lock's 3.6.5. Gleam 1.19.0 needs a second input at `8edc0c72e3a38faf5434e40d1f19431125fe4b30`, and kubectl 1.36 a third, nixos-26.05 at `f1e5c356f35d07e7b71a6b5e6c9338e0b029e0c0`. Each is cached on all three systems and carries a `cache.nixos.org-1` signature in the built environment. An override forfeits the cache on all three. Assertions in the flake fail evaluation when a lock move loses a held version.
- **allium:** a fixed-hash fetch of the upstream asset plus `autoPatchelfHook`. It runs from the store; the asset as fetched does not.
- **Lock:** `nix flake lock --no-update-lock-file --offline` is the read-only offline check. On a drifted copy it exits 1 and `flake.lock` is byte-identical.
- **Flakes and git:** recorded. A linked worktree works. A worktree whose `.git` file points at a missing path does not evaluate.
- **Image:** builds on linux/arm64; the six TLS cases pass under `image-check`'s restrictions; perl is not in the closure. It is 114.3 MB against today's 103.6 MB.
- **PATH prefix:** each of the four cases has a transcript. Two answers are "no": the docs checker does not find markdown-it through `bin/markdownlint-cli2`, and the path prek writes into the hook does not follow a lock move.
- **The gate:** with the network off and no tracked file changed, 13 of the 18 recipes pass and 5 fail, each with its cause. With `gate-scratch.patch`, three files, `just check` ends "All checks passed and the worktree is unchanged." and `just test-checkers-all` passes.
- **Version differences:** no formatter or linter finding differs on today's tree. Each entry is marked.
- **grype:** it catalogues erlang and openssl in the closure from a directory and from the image, and matches a known-vulnerable control.
- `just check` on the Mac, on pixi, ends with "All checks passed and the worktree is unchanged.", with every change staged.

Not verified:

- Anything on aarch64-darwin or x86_64-linux beyond evaluation and the cache's answer. The README's last section lists each fact.
- The cluster tools beyond their version output: no cluster ran in the container.
- prek's fallback after garbage collection, which was simulated by renaming the path in a copy of the hook.
- grype against a current database: the scans used the database the host had cached, built 2026-10-30, with the network off. No control was run on the image source.
- Build times beyond their order of magnitude: the Mac was shared with other builds, and the same build took 21 to 78 seconds.
- Whether the gate formats `.nix` files. No Nix formatter was run on the prototype.

### What later tickets need

- **02 (the seam):** the readers of pixi's directories are the `Justfile`'s `PATH` and its `check` guard, `with-env.sh`, `initialize.sh`, the docs checker, the Allium runner and the ripsecrets wrapper; pointing those two directories at the Nix environment was enough for every other recipe. The docs checker needs more than a tool's path: under Nix it needs the module directory, `<environment>/lib/node_modules/markdownlint-cli2/markdownlint-cli2-bin.mjs`, because `bin/markdownlint-cli2` is a wrapper script there. `perl` reaches the release scripts today from conda's environment.
- **03:** the runtime prefix becomes `/opt/knarr/runtime`, a link into `/nix/store`.
- **04:** the README's darwin list. The points most likely to differ: the darwin closures are much larger (`python314` 1366 MiB against 229), the CA store is the keychain, and the hook path. On Linux a cold `nix build` of the default group took 16 seconds and fetched 413 MiB. The only Nix configuration used was `NIX_CONFIG='experimental-features = nix-command flakes'`.
- **05:** the image digest above is the multi-arch index. The prototype is `./.scratch/nix-migration/evidence/01`: `nix build ./.scratch/nix-migration/evidence/01#default --no-update-lock-file --out-link <dir>`, and the groups are `default`, `cluster`, `audit` and `runtime`. The gate needs `gate-scratch.patch` until 07 lands; on x86_64 its `run_allium.py` hunk is not needed. The Nix image itself cannot run the gate (no `sed`, no `/usr/bin`), so the runner's own userland is needed. For Renovate: three inputs, one following `nixpkgs-unstable`, one pinned by revision, one following `nixos-26.05`; the held versions are an attribute set in `flake.nix`.
- **06:** the choices this evidence leaves open are OpenSSL 3.5.9 (the candidate's, current) against 3.6.5 (a nixos-26.05 input, cached, already dropped by unstable as end of life); and whether hadolint and grype take nixpkgs' older versions or the upstream assets. It should also record what the machine supplies beyond "a POSIX shell": `sed`, `awk`, `find`, `diff`, `perl` and a CA store. The `.nix` formatter question was not examined here.
- **07:** the flake and every file it reads must be tracked before it evaluates; it should not refer to `self`; every Nix command in a recipe needs `--no-update-lock-file`, or it rewrites a drifted lock. The hook step must write the out-link path into the hook, because prek writes its store path. The environment needs `lib/node_modules` linked beside `bin`, Python as `python314.withPackages`, Erlang and rebar3 from `beam_minimal`, and the allium derivation. `env-check.sh` is a working prototype of the environment check (1.5 seconds). The Allium runner refuses aarch64-linux until it stops reading `tools.txt`.
- **08:** kubectl 1.36.3 comes from the nixos-26.05 input; kind 0.33.0 and kwok 0.8.0 are the candidate's, and `kwokctl` is inside the `kwok` package. None was exercised against a cluster.
- **09:** `image/Dockerfile` is the shape, with the closure laid out before the sources so a source edit reuses it. The context allowlists must admit `flake.nix`, `flake.lock` and the held-versions file. The perl prune script, its test and `image-check`'s conda and perl checks have nothing left to do. The `runtime` group carries the `openssl` command for the TLS rerun.
- **10:** nothing on the version-difference list needs a fix in the tree. The prerequisite line needs the machine's utilities named.
- **11:** `conda-meta-cataloger` finds nothing, so today's script cannot decide. grype catalogues the closure through `nix-cataloger` and `binary-classifier-cataloger`, from the image as well as from a directory, so the copy out of the image is no longer needed. Erlang's advisories match only through `binary-classifier-cataloger`'s `erlang` package, so that is what the fail-closed test must require.
- **12:** a held version is moved by moving an input's revision, and the README shows how one was found (the channel releases on releases.nixos.org). Nothing proposes that automatically; the held attribute set only refuses a wrong version.
