# Nix migration ticket 01 evidence

Evidence for [ticket 01](../../issues/01-nix-container-spike.md) of the Nix migration round, and for Decision 0017, which ticket 06 writes. It answers [Decision 0003](../../../../docs/decisions/0003-tool-manager.md)'s questions again for Nix, on Linux only.

Gathered on 2026-11-14 on an Apple-silicon Mac with Docker Desktop 29.6.1 (linux/arm64). Nix is not installed on the Mac. Every Nix command ran in `nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed`, which is `nixos/nix:latest` on that date and holds Nix 2.35.6. The digest is the multi-arch index, so the same reference works on an amd64 runner; its linux/arm64 manifest is `sha256:aca6983e5cefd9936445840fc1c59780f313b3974401305acb56d562ec73f3a0` and its linux/amd64 manifest `sha256:a3b3e3eb3883e5af5327757c5304c0093426a0d11c58a9056df46cfefe30319e`.

Everything here ran on **aarch64-linux**. x86_64-linux and aarch64-darwin were evaluated from Linux and the binary cache was asked about their output paths; nothing was built or run for them. [What was only evaluated](#what-was-evaluated-but-not-run) lists each such fact.

## How it ran

[nix.sh](nix.sh) is the only way a Nix command ran. It starts the pinned image with:

- `/nix` on the named volume `knarr-nix-store`, so fetches persist;
- `/work` on the named volume `knarr-nix-01-work`, which holds the clone, `HOME` and Nix's caches;
- this directory read-only at `/evidence`, the worktree's `ai_tmp/` read-only at `/bundle`, and `ai_tmp/out/` writable at `/out`;
- `NIX_CONFIG='experimental-features = nix-command flakes'`, which is the whole of the Nix configuration: nothing in `/etc/nix` or the user's configuration was changed.

`sh nix.sh --offline …` adds `--network none`. The worktree is never mounted writable, and no gate recipe ran on a mount of it. The repository reached the container as a git bundle (`git bundle create ai_tmp/knarr.bundle HEAD 01-nix-container-spike`), cloned into the work volume.

Each script below runs inside the container as `sh nix.sh sh /evidence/<script>`, and each `.txt` file is the transcript of the script with the same name. [lib.sh](lib.sh) is shared: the image has no `sed`, `awk`, `jq` or `file`, so the scripts take them from the candidate revision. [run-all.sh](run-all.sh) reruns everything.

## Findings

### 1. The candidate revision

The candidate is **nixpkgs-unstable at `2074cc672349f14240fb7ea90d509e0b643e9dd4`** (2026-11-12, `nixpkgs-26.11pre1118975.2074cc672349`). [holds.txt](holds.txt) has the three channel heads on 2026-11-14:

| Channel | Head | Why it is or is not the candidate |
| --- | --- | --- |
| nixpkgs-unstable | `2074cc6` | The candidate. OTP 29.1.2, Helm 4.3.1, kwok 0.8.0, pytest 9.1.1, Python 3.14.10. This channel advances only when its Linux and darwin jobs have built. |
| nixos-unstable | `d4f25a3` | The same versions one day earlier. It is gated on NixOS tests, which are Linux only. |
| nixos-26.05 | `f1e5c35` | Fails two floors: Helm is 3.20.2 and kwok is 0.7.0. It is the source of two holds below. |

Cross-system evaluation works from aarch64-linux, and that is how the other two columns of every table here were filled ([systems.txt](systems.txt)): `nix eval` gives the output path for any system, `nix path-info --store https://cache.nixos.org` says whether the cache has it, and `nix build --dry-run .#packages.<system>.<group>` lists what would be built and what fetched. Building for another system is refused with `Reason: platform mismatch`.

### 2. Packages

One row for every line of `pixi.toml` and `tools.txt`, at the candidate. [packages.nix](packages.nix) holds the rows and [packages.txt](packages.txt) the result for each system. "Cached" is the answer for aarch64-linux, x86_64-linux and aarch64-darwin, in that order.

| Pin (source) | Pinned | nixpkgs attribute | Candidate | Cached | Floor or note |
| --- | --- | --- | --- | --- | --- |
| `gleam` (pixi) | 1.19.0 | `gleam` | 1.19.2 | yes, yes, yes | **Held at 1.19.0.** The candidate differs; see [Held versions](#3-held-versions). |
| `just` (pixi) | 1.58.0 | `just` | 1.59.0 | yes, yes, yes | |
| `prek` (pixi) | 0.5.5 | `prek` | 0.5.10 | yes, yes, yes | |
| `typos` (pixi) | 1.51.1 | `typos` | 1.52.0 | yes, yes, yes | |
| `lychee` (pixi) | 0.24.2 | `lychee` | 0.24.2 | yes, yes, yes | |
| `taplo` (pixi) | 0.10.0 | `taplo` | 0.10.0 | yes, yes, yes | |
| `markdownlint-cli2` (pixi) | 0.23.3 | `markdownlint-cli2` | 0.24.0 | yes, yes, yes | **Floor: its bundled markdown-it, under Node.** Met, but not at the path the docs checker looks in; see [the PATH prefix](#7-the-gate-from-a-path-prefix). |
| Node (conda dependency of markdownlint-cli2) | 26.10.0 | `nodejs` | 24.22.2 | yes, yes, yes | `nodejs` is a link farm over `nodejs-slim` that Nix always builds locally, in under a second. |
| `actionlint` (pixi) | 1.7.12 | `actionlint` | 1.7.12 | yes, yes, yes | |
| `shellcheck` (pixi) | 0.11.0 | `shellcheck` | 0.11.0 | yes, yes, yes | |
| `python` (pixi) | 3.14.8 | `python314` | 3.14.10 | yes, yes, yes | **Floor: 3.14 or later.** Met. |
| `pytest` (pixi) | 9.1.1 | `python314Packages.pytest` | 9.1.1 | yes, yes, yes | **Floor: major 9.** Met. It must be inside the interpreter: `python314.withPackages`. |
| `ruff` (pixi) | 0.16.10 | `ruff` | 0.17.4 | yes, yes, yes | |
| `kubernetes-helm` (pixi) | 4.3.0 | `kubernetes-helm` | 4.3.1 | yes, yes, yes | **Floor: major 4.** Met. |
| `kustomize` (pixi) | 5.8.2 | `kustomize` | 5.8.3 | yes, yes, yes | |
| `erlang` (pixi) | 29.1.2 | `beam_minimal.interpreters.erlang_29` | 29.1.2 | yes, yes, yes | **Held at 29.1.2.** The candidate has it. `beam.interpreters.erlang_29` is also 29.1.2 and cached, but adds wxWidgets and systemd. |
| OpenSSL (conda dependency of erlang) | 3.6.5 | `openssl` | 3.5.9 | yes, yes, yes | **Held with Erlang.** The candidate differs, and `openssl_3_6` was removed from it; see [Held versions](#3-held-versions). |
| `kubernetes-kind` (pixi) | 0.33.0 | `kind` | 0.33.0 | yes, yes, yes | **Skew cap.** Met. |
| `kubernetes-client` (pixi) | 1.36.0 | `kubectl` | 1.37.2 | yes, yes, yes | **Skew cap: 1.34 to 1.36 for the 1.35 cluster.** The candidate breaks it; see [Held versions](#3-held-versions). |
| `tilt` (pixi) | 0.37.8 | `tilt` | 0.37.7 | yes, yes, yes | **Unused; not carried forward.** No recipe, script or workflow runs tilt. |
| `grype` (pixi) | 0.120.1 | `grype` | 0.120.0 | yes, yes, yes | One patch older than the pin. |
| `rebar3` (tools.txt) | 3.28.0 | `beam_minimal.packages.erlang_29.rebar3` | 3.28.0 | yes, yes, yes | **Floor: 3.28.0 or later.** Met. The top-level `rebar3` is built with OTP 28. |
| `ripsecrets` (tools.txt) | 0.1.11 | `ripsecrets` | 0.1.11 | yes, yes, yes | |
| `editorconfig-checker` (tools.txt) | 4.0.2 | `editorconfig-checker` | 4.0.2 | yes, yes, yes | |
| `allium` (tools.txt) | 3.6.1 | none | absent | not applicable | **Floor: exactly 3.6.1.** Not in nixpkgs; see [Missing tools](#4-missing-tools). |
| `kubeconform` (tools.txt) | 0.8.0 | `kubeconform` | 0.8.0 | yes, yes, yes | |
| `hadolint` (tools.txt) | 2.15.1 | `hadolint` | 2.14.0 | yes, yes, yes | One minor older than the pin; see [Missing tools](#4-missing-tools). |
| `kwokctl` (tools.txt) | 0.8.0 | `kwok` | 0.8.0 | yes, yes, yes | **Floor: 0.8.0.** Met. The `kwok` package carries `kwokctl`. |

pixi itself has no row: nothing replaces it but Nix. The `openssl` command, which conda's `openssl` package brings and the TLS evidence scripts call, is `openssl.bin` in nixpkgs, a separate output from the library.

What a machine with an empty store builds and fetches for each group of the prototype, from `nix build --dry-run` against an empty store ([packages.txt](packages.txt), last section). The counts include build-time tools, so they are larger than the closures:

| Group | aarch64-linux | x86_64-linux | aarch64-darwin |
| --- | --- | --- | --- |
| `default` | 6 built, 146 fetched, 413 MiB down, 1.3 GiB unpacked | 6 built, 155 fetched, 428 MiB, 1.3 GiB | 6 built, 141 fetched, 519 MiB, 2.2 GiB |
| `cluster` | 2 built, 44 fetched, 126 MiB, 486 MiB | 2 built, 44 fetched, 135 MiB, 489 MiB | 2 built, 47 fetched, 105 MiB, 453 MiB |
| `audit` | 2 built, 38 fetched, 59 MiB, 231 MiB | 2 built, 38 fetched, 62 MiB, 223 MiB | 2 built, 40 fetched, 52 MiB, 245 MiB |
| `runtime` | 2 built, 38 fetched, 92 MiB, 285 MiB | 2 built, 38 fetched, 92 MiB, 273 MiB | 2 built, 41 fetched, 82 MiB, 294 MiB |

Nothing compiles. The derivations built locally are the environments themselves (`buildEnv` and its `builder.pl`), the Python environment that joins the interpreter and pytest, the `nodejs` link farm, and allium's fetch and patch. On aarch64-linux the `default` group built from an empty store in 15 seconds on this machine's network.

### 3. Held versions

[holds.txt](holds.txt) has every line below; [gleam-override.txt](gleam-override.txt) has the override.

**Erlang/OTP 29.1.2 is held by the candidate itself.** `beam_minimal.interpreters.erlang_29` is 29.1.2 at the candidate, cached on all three systems, and its build inputs are ncurses, openssl and zlib only. The prototype takes Erlang and rebar3 from that one attribute set, so each environment's closure holds one Erlang and the gate and the image run the same store path.

**Its OpenSSL cannot be both exact and current.** pixi.lock has OpenSSL 3.6.5. The candidate builds Erlang against OpenSSL 3.5.9, the long-term-support line, and has removed `openssl_3_6` with the message `'openssl_3_6' has been removed, due to upstream end of life on 2026-11-01`. The options:

| Option | OTP | OpenSSL | Cached (three systems) | Cost |
| --- | --- | --- | --- | --- |
| The candidate's Erlang (**the prototype**) | 29.1.2 | 3.5.9 | yes, yes, yes | OpenSSL differs from pixi.lock's. The six TLS cases were rerun on it and pass; see [the image](#8-the-image-and-tls). |
| Erlang from a second input at nixos-26.05 `f1e5c35` | 29.1.2 | 3.6.5 | yes, yes, yes | The exact pair pixi.lock has, and cached. It ships an OpenSSL line nixpkgs unstable has already dropped as end of life, and brings a second glibc into every closure. |
| The candidate's Erlang with `.override { openssl = … }` | 29.1.2 | any | no, no, no | Forfeits the cache on all three systems: Erlang compiles from source wherever it is installed. |

**Gleam 1.19.0 needs a second pinned input.** The candidate has 1.19.2. No nixpkgs revision has both Gleam 1.19.0 and OTP 29.1.2: Gleam was 1.19.0 in the unstable channels only between releases `1086391` and `1088030` (about 2026-10-05 to 2026-10-08), when Erlang was still 29.1.1, and Erlang reached 29.1.2 at release `1092923`, when Gleam was already 1.19.2. The options:

| Option | Gleam | Cached (three systems) | Cost |
| --- | --- | --- | --- |
| A second input, `nixpkgs-gleam`, at `8edc0c72e3a38faf5434e40d1f19431125fe4b30` (**the prototype**) | 1.19.0 | yes, yes, yes | One more nixpkgs source to fetch, and a second glibc in the tools closure (not in the runtime closure: the shipment does not contain gleam). That commit is `nixpkgs-26.11pre1088030`, the last nixpkgs-unstable head that carried 1.19.0, so Hydra built it. |
| The candidate's recipe with 1.19.0's source and crates (`overrideAttrs`) | 1.19.0 | no, no, no | Compiles from source: 103 seconds on 18 cores here, with the Rust toolchain already fetched. Every machine and every CI job without a warm store pays it, and the toolchain download with it. |
| The 1.19.0 recipe called on the candidate's toolchain | 1.19.0 | no, no, no | Does not build: the newer toolchain sets `AWS_LC_SYS_USE_SYSTEM=1`, which the older recipe does not satisfy. |
| Accept the candidate's Gleam | 1.19.2 | yes, yes, yes | Not the held version. |

**kubectl needs a hold too.** The candidate has kubectl 1.37.2, which does not reach the 1.35 cluster. The prototype takes kubectl from a third input, `nixpkgs-kubectl`, following `nixos-26.05` and locked at `f1e5c35`: 1.36.3, cached on all three systems. kind 0.33.0 and kwok 0.8.0 are the candidate's own.

**The mechanism.** The hold is three things together, all in [flake.nix](flake.nix):

1. `flake.lock` pins each input's commit and content hash.
2. A `held` attribute set names each exact version (`erlang`, `openssl`, `gleam`, `rebar3`, `allium`, `kwok`, `kind`) and kubectl's minor.
3. Each held package passes through an assertion, so a lock move that loses a held version fails evaluation instead of changing it silently. The transcript shows both directions: `error: held gleam: the locked input has 1.19.2, the hold is 1.19.0` and `error: held erlang: the locked input has 29.1.1, the hold is 29.1.2`. A further assertion fails unless the OpenSSL among Erlang's build inputs is the held one.

**Each held package came from the binary cache.** In the environments built on aarch64-linux, `nix path-info --sigs` shows a `cache.nixos.org-1` signature on erlang 29.1.2, openssl 3.5.9 and its `bin` output, gleam 1.19.0, rebar3 3.28.0, python 3.14.10, pytest 9.1.1, kubectl 1.36.3, kind 0.33.0 and kwok 0.8.0. The paths marked `ultimate`, built locally, are allium, the Python environment and the environments themselves.

### 4. Missing tools

[missing.txt](missing.txt). Every digest was computed in the container from the fetched asset.

**allium 3.6.1** is the only tool nixpkgs lacks. Its source is the upstream release asset `tools.txt` names, `https://github.com/juxt/allium-tools/releases/download/v3.6.1/allium-<triple>.tar.gz`:

| System | Triple | sha256 | Pinned by |
| --- | --- | --- | --- |
| x86_64-linux | `x86_64-unknown-linux-gnu` | `e00c99ae234b10207719257a70e7c2dcad73060864468cd293fb7ad40524e970` | `tools.txt` |
| aarch64-darwin | `aarch64-apple-darwin` | `ecfae02fcf8e60475a014944183158ccde4104f6f0223e1bf91f98519fcb19eb` | `tools.txt` |
| aarch64-linux | `aarch64-unknown-linux-gnu` | `e5ce96393db198b4f7d23ccd2494573e753936cc7b03ca1ecbac3cb20f993ff4` | GitHub's asset digest; `tools.txt` has no line for this system |

A plain fixed-hash fetch does not run on Linux. Both Linux binaries are dynamically linked against glibc with the loader at `/lib/ld-linux-aarch64.so.1` or `/lib64/ld-linux-x86-64.so.2`, which a Nix store does not provide: the fetched aarch64-linux binary fails with `cannot execute: required file not found`. So the source is a small derivation in the flake: `fetchurl` with the same sha256, then `autoPatchelfHook` rewrites the loader to the store's glibc. That prints `allium 3.6.1 (language versions: 1, 2, 3)` from the store, and it ran `just check-specs` and `just analyse-specs` in the gate. The darwin asset is a Mach-O binary and takes no patching.

**kwokctl 0.8.0** is in nixpkgs: the `kwok` package is 0.8.0 and carries `kwokctl`, which runs from the store. The upstream asset is also usable as fetched, because it is a statically linked Go binary: `kwokctl-linux-arm64`, sha256 `5a642b27d3e975f36040d215640cd90fb4a63cb6fca0ad5865a61bcd9c81051b`, printed `kwokctl version v0.8.0`. The prototype uses nixpkgs'.

**hadolint** is 2.14.0 in nixpkgs against `tools.txt`'s 2.15.1. The upstream 2.15.1 asset is statically linked and runs as fetched (`hadolint-linux-arm64`, sha256 `f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d`). The prototype uses nixpkgs' 2.14.0, and `just packaging-check` passes with it.

**grype** is 0.120.0 in nixpkgs against the pin's 0.120.1; see [Scanning](#9-scanning).

One trap for a fetched executable: a store file carries its executable bit only when it is hashed as a NAR, so `fetchurl { executable = true; }` takes a Nix-only hash that is not the upstream sha256. To keep the upstream digest as the pin, fetch the plain file and install it with mode 0755 in a derivation, as the allium derivation does.

### 5. Lock behaviour

[lock.txt](lock.txt), and [lock-offline.txt](lock-offline.txt) for the same script under `--network none`. The drift: `flake.nix` names another revision for an input than `flake.lock` holds. Nix 2.35.6:

```text
nix flake lock                                             exit 0  flake.lock REWRITTEN
nix flake update                                           exit 0  flake.lock REWRITTEN
nix flake metadata                                         exit 0  flake.lock REWRITTEN
nix flake show                                             exit 0  flake.lock REWRITTEN
nix eval .#held.erlang                                     exit 0  flake.lock REWRITTEN
nix build --no-link .#runtime                              exit 0  flake.lock REWRITTEN
nix shell .#runtime --command true                         exit 0  flake.lock REWRITTEN
nix build --no-link .#runtime --no-write-lock-file         exit 0  flake.lock unchanged
nix eval .#held.erlang --no-write-lock-file                exit 0  flake.lock unchanged
nix build --no-link .#runtime --no-update-lock-file        exit 1  flake.lock unchanged
nix eval .#held.erlang --no-update-lock-file               exit 1  flake.lock unchanged
nix flake metadata --no-update-lock-file                   exit 1  flake.lock unchanged
nix flake lock --no-update-lock-file                       exit 1  flake.lock unchanged
nix flake lock --no-update-lock-file --offline             exit 1  flake.lock unchanged
```

**The read-only, offline lock check is `nix flake lock --no-update-lock-file --offline`.** On drift it exits 1 with `requires lock file changes but they're not allowed due to '--no-update-lock-file'` and leaves `flake.lock` byte-identical (sha256 `2fb8733b442340b1a47c81b346d714af439712e002918b356d3b4c7e16be61f1` before and after). On a fresh lock it exits 0 in 0.03 seconds, with the network off too. It also refuses a lock that still has an input `flake.nix` no longer names, and a lock whose revision was edited by hand.

Three traps, the same shape as pixi's:

- Every plain command rewrites a drifted lock and exits 0, `nix eval` and `nix build` included. Any recipe that touches the flake must pass `--no-update-lock-file`.
- `--no-write-lock-file` is not the check. It leaves the file alone but builds from the re-resolved lock and exits 0, as `pixi install --frozen` installs a stale lock.
- The lock check does not evaluate, so it does not see a held version. The assertions in the flake run at the first `nix eval` or `nix build`.

Outside the flake directory the check writes one file, Nix's own `fetcher-cache-v4.sqlite` under `$XDG_CACHE_HOME/nix`, and no store path.

### 6. Flakes and git

[git.txt](git.txt), in a clone of this branch with the prototype flake copied to the root.

- **An untracked `flake.nix` is invisible.** `nix eval` exits 1: `Path 'flake.nix' in the repository "/work/git/clone" is not tracked by Git`. Staging it is enough (`git add`, or `git add -N`); it need not be committed. Every file the flake reads follows the same rule: `builtins.pathExists ./probe.txt` is `false` for an untracked file and `true` once it is tracked. A held-versions file must be tracked before the flake can read it.
- **A dirty tree evaluates, with a warning** on stderr: `warning: Git tree '…' is dirty`. Evaluating the `default` group's output path takes about 1.2 seconds, dirty or clean.
- **Nothing is copied to the store on evaluation.** Nix 2.35.6 reads a git flake in place. `nix flake metadata` names a store path for the source, but the path does not exist, and the store's path count is the same after metadata, two evaluations and an edit. The source is copied only when the flake uses it in a derivation (`"${self}"`): then all 755 tracked files are copied (8.3 MB), ignored and untracked files are not, `.git` is not, and each edit to a tracked file makes another copy. The prototype never refers to `self`, and ticket 07's flake should not either.
- **A linked worktree works.** `.git` there is a file naming the main checkout's `worktrees/` directory. `nix eval`, `nix build --out-link`, the lock check and a dirty tree all behave as in the main checkout, and the flake is `git+file:///work/git/linked` on that worktree's branch.
- **A worktree whose `.git` file points at a missing path does not evaluate.** That is a linked worktree bind-mounted into a container. git fails with `fatal: not a git repository`, and Nix with `opening Git repository …: failed to resolve path '/Users/somebody/repo/.git/worktrees/linked'`. Nix does not fall back to reading the directory as a plain path.
- **A flake in a subdirectory is still the whole repository's flake.** This prototype resolves as `git+file:///work/git/clone?dir=.scratch/nix-migration/evidence/01`, and the same tracking rule applies.
- **With no `.git`, the directory is a `path:` flake and all of it is copied.** In an export of the tree, every file went to the store on the first evaluation, a 20 MB untracked file included (756 files, 28 MB), and again after each edit. A Docker build context has no `.git`, so the build stage should `COPY` only `flake.nix`, `flake.lock` and the files the flake reads before it runs Nix: with those two files alone, two files are copied.

### 7. The gate from a PATH prefix

Not yet recorded.

### 8. The image and TLS

Not yet recorded.

### 9. Scanning

Not yet recorded.

## What was evaluated but not run

Not yet recorded.
