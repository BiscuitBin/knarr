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

Each `.txt` file is the transcript of the script with the same name, and each script exits non-zero on an unexpected result. [lib.sh](lib.sh) is shared by the container scripts: the image has no `sed`, `awk`, `jq` or `file`, so they take them from the candidate revision.

| Script | Where it runs | What it shows |
| --- | --- | --- |
| [systems.sh](systems.sh) | container | Cross-system evaluation, cache queries and closure sizes |
| [packages.sh](packages.sh), with [packages.nix](packages.nix) | container | The package table on three systems, and each group's build plan |
| [holds.sh](holds.sh), [gleam-override.sh](gleam-override.sh) | container | The held versions, nixpkgs history, and the cost of an override |
| [missing.sh](missing.sh) | container | allium, kwokctl, hadolint and grype from upstream assets and nixpkgs |
| [lock.sh](lock.sh) | container, online and offline | The drift table |
| [git.sh](git.sh) | container | Flakes and git |
| [tls-pairs.sh](tls-pairs.sh) | container | The six TLS cases on both Erlang and OpenSSL pairs |
| [gate-setup.sh](gate-setup.sh) | container | The clone and environment the gate runs in |
| [host-needs.sh](host-needs.sh) | container and stand-in host, offline | What the gate takes from the machine |
| [gate.sh](gate.sh), [differences.sh](differences.sh) | stand-in host ([host.sh](host.sh)), offline | The PATH-prefix cases, the gate, and the version differences |
| [fresh.sh](fresh.sh) | container, on a new store volume | A fresh clone reaching `just` |
| [baseline.sh](baseline.sh), [image.sh](image.sh) | the Mac's Docker | Today's image and the prototype image |
| [grype.sh](grype.sh) | container, offline | The scans |

```sh
sh .scratch/nix-migration/evidence/01/run-all.sh
```

[run-all.sh](run-all.sh) reruns them in that order and rewrites every transcript. It needs Docker and the network. `gate-setup.sh` clones the branch as committed, so a changed script is committed before the scripts after it are rerun. Timings move with the machine's load, and the Mac was shared with other builds on the day.

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
| Node (conda dependency of markdownlint-cli2) | 26.10.0 | `nodejs-slim` | 24.22.2 | yes, yes, yes | Node without npm, which is what markdownlint-cli2's wrapper runs. `nodejs` is a link farm over it that Nix never substitutes and builds locally. |
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
| `default` | 5 built, 145 fetched, 413 MiB down, 1.3 GiB unpacked | 5 built, 154 fetched, 428 MiB, 1.3 GiB | 5 built, 140 fetched, 519 MiB, 2.2 GiB |
| `cluster` | 2 built, 44 fetched, 126 MiB, 486 MiB | 2 built, 44 fetched, 135 MiB, 489 MiB | 2 built, 47 fetched, 105 MiB, 453 MiB |
| `audit` | 2 built, 38 fetched, 59 MiB, 231 MiB | 2 built, 38 fetched, 62 MiB, 223 MiB | 2 built, 40 fetched, 52 MiB, 245 MiB |
| `runtime` | 2 built, 38 fetched, 92 MiB, 285 MiB | 2 built, 38 fetched, 92 MiB, 273 MiB | 2 built, 41 fetched, 82 MiB, 294 MiB |

Nothing compiles. The derivations built locally are the environments themselves (`buildEnv` and its `builder.pl`), the Python environment that joins the interpreter and pytest, and allium's fetch and patch. On aarch64-linux the `default` group built from an empty store in 16 seconds on this machine's network ([fresh.txt](fresh.txt)).

### 3. Held versions

[holds.txt](holds.txt) has every line below; [gleam-override.txt](gleam-override.txt) has the override.

**Erlang/OTP 29.1.2 is held by the candidate itself.** `beam_minimal.interpreters.erlang_29` is 29.1.2 at the candidate, cached on all three systems, and its build inputs are ncurses, openssl and zlib only. The prototype takes Erlang and rebar3 from that one attribute set, so each environment's closure holds one Erlang and the gate and the image run the same store path.

**Its OpenSSL cannot be both exact and current.** pixi.lock has OpenSSL 3.6.5, though conda-forge's Erlang was compiled against 3.5 headers: in today's image `crypto:info_lib()` reports the header number 810549392, which is 3.5.9, beside the library text `OpenSSL 3.6.5` ([baseline.txt](baseline.txt)). The candidate builds Erlang against OpenSSL 3.5.9, the long-term-support line, and has removed `openssl_3_6` with the message `'openssl_3_6' has been removed, due to upstream end of life on 2026-11-01`. The options:

| Option | OTP | OpenSSL | Cached (three systems) | Cost |
| --- | --- | --- | --- | --- |
| The candidate's Erlang (**the prototype**) | 29.1.2 | 3.5.9 | yes, yes, yes | OpenSSL differs from pixi.lock's. The six TLS cases were rerun on it and pass; see [the image](#9-the-image-and-tls). |
| Erlang from a second input at nixos-26.05 `f1e5c35` | 29.1.2 | 3.6.5 | yes, yes, yes | The exact pair pixi.lock has, and cached. It ships an OpenSSL line nixpkgs unstable has already dropped as end of life, and brings a second glibc into every closure. |
| The candidate's Erlang with `.override { openssl = … }` | 29.1.2 | any | no, no, no | Forfeits the cache on all three systems: Erlang compiles from source wherever it is installed. |

**Gleam 1.19.0 needs a second pinned input.** The candidate has 1.19.2. No nixpkgs revision has both Gleam 1.19.0 and OTP 29.1.2: Gleam was 1.19.0 in the unstable channels only between releases `1086391` and `1088030` (about 2026-10-05 to 2026-10-08), when Erlang was still 29.1.1, and Erlang reached 29.1.2 at release `1092923`, when Gleam was already 1.19.2. The options:

| Option | Gleam | Cached (three systems) | Cost |
| --- | --- | --- | --- |
| A second input, `nixpkgs-gleam`, at `8edc0c72e3a38faf5434e40d1f19431125fe4b30` (**the prototype**) | 1.19.0 | yes, yes, yes | One more nixpkgs source to fetch, and a second glibc in the tools closure (not in the runtime closure: the shipment does not contain gleam). That commit is `nixpkgs-26.11pre1088030`, the last nixpkgs-unstable head that carried 1.19.0, so Hydra built it. |
| The candidate's recipe with 1.19.0's source and crates (`overrideAttrs`) | 1.19.0 | no, no, no | Compiles from source: 103 seconds on 18 cores here, with the Rust toolchain already fetched. Every machine and every CI job without a warm store pays it, and the toolchain download with it. One later rerun, on a loaded machine, failed in `cargo-auditable` instead; its transcript was not kept. |
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

**grype** is 0.120.0 in nixpkgs against the pin's 0.120.1; see [Scanning](#10-scanning).

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

**The read-only, offline lock check is `nix flake lock --no-update-lock-file --offline`.** On drift it exits 1 with `requires lock file changes but they're not allowed due to '--no-update-lock-file'` and leaves `flake.lock` byte-identical (sha256 `2fb8733b442340b1a47c81b346d714af439712e002918b356d3b4c7e16be61f1` before and after). On a fresh lock it exits 0 in 0.02 seconds, with the network off too. It also refuses a lock that still has an input `flake.nix` no longer names, and a lock whose revision was edited by hand.

Three traps, the same shape as pixi's:

- Every plain command rewrites a drifted lock and exits 0, `nix eval` and `nix build` included. Any recipe that touches the flake must pass `--no-update-lock-file`.
- `--no-write-lock-file` is not the check. It leaves the file alone but builds from the re-resolved lock and exits 0, as `pixi install --frozen` installs a stale lock.
- The lock check does not evaluate, so it does not see a held version. The assertions in the flake run at the first `nix eval` or `nix build`.

Outside the flake directory the check writes one file, Nix's own `fetcher-cache-v4.sqlite` under `$XDG_CACHE_HOME/nix`, and no store path.

### 6. Flakes and git

[git.txt](git.txt), in a clone of this branch with the prototype flake copied to the root.

- **An untracked `flake.nix` is invisible.** `nix eval` exits 1: `Path 'flake.nix' in the repository "/work/git/clone" is not tracked by Git`. Staging it is enough (`git add`, or `git add -N`); it need not be committed. Every file the flake reads follows the same rule: `builtins.pathExists ./probe.txt` is `false` for an untracked file and `true` once it is tracked. A held-versions file must be tracked before the flake can read it.
- **A dirty tree evaluates, with a warning** on stderr: `warning: Git tree '…' is dirty`. Evaluating the `default` group's output path takes about 1.2 seconds, dirty or clean.
- **Nothing is copied to the store on evaluation.** Nix 2.35.6 reads a git flake in place. `nix flake metadata` names a store path for the source, but the path does not exist, and the store's path count is the same after metadata, two evaluations and an edit. The source is copied only when the flake uses it in a derivation (`"${self}"`): then all 792 tracked files are copied (8.5 MB), ignored and untracked files are not, `.git` is not, and each edit to a tracked file makes another copy. The prototype never refers to `self`, and ticket 07's flake should not either.
- **A linked worktree works.** `.git` there is a file naming the main checkout's `worktrees/` directory. `nix eval`, `nix build --out-link`, the lock check and a dirty tree all behave as in the main checkout, and the flake is `git+file:///work/git/linked` on that worktree's branch.
- **A worktree whose `.git` file points at a missing path does not evaluate.** That is a linked worktree bind-mounted into a container. git fails with `fatal: not a git repository`, and Nix with `opening Git repository …: failed to resolve path '/Users/somebody/repo/.git/worktrees/linked'`. Nix does not fall back to reading the directory as a plain path.
- **A flake in a subdirectory is still the whole repository's flake.** This prototype resolves as `git+file:///work/git/clone?dir=.scratch/nix-migration/evidence/01`, and the same tracking rule applies.
- **With no `.git`, the directory is a `path:` flake and all of it is copied.** In an export of the tree, every file went to the store on the first evaluation, a 20 MB untracked file included (793 files, 28 MB), and again after each edit. A Docker build context has no `.git`, so the build stage should `COPY` only `flake.nix`, `flake.lock` and the files the flake reads before it runs Nix: with those two files alone, two files are copied.

### 7. The gate from a PATH prefix

[gate-setup.txt](gate-setup.txt) prepares the clone with the network on; [gate.txt](gate.txt) is the run with the network off; [host-needs.txt](host-needs.txt) and [fresh.txt](fresh.txt) are the two side cases. All of it ran on aarch64-linux.

**Where it ran.** Not in the Nix image: that image is not a POSIX machine. It has no `/usr/bin`, and no `sed`, `awk`, `diff` or `perl`, and every recipe stops there with `sed: command not found`, because the `Justfile` runs `scripts/cluster-name.sh` when it loads ([host-needs.txt](host-needs.txt)). So the gate ran on a stand-in for "a Linux machine with only Nix installed", [host.sh](host.sh): the Ubuntu 24.04 base the Dockerfile ships, by the same digest, with the store volume at `/nix`, the Nix image's profile last on `PATH` (it supplies `nix` and `git`), and a link from `/etc/ssl/certs/ca-certificates.crt` to that profile's CA bundle. Nothing was installed into it, and without the prefix it has no `python3` and no `node`.

**How the prefix was put in place.** Six readers name pixi's directories: the `Justfile`'s `PATH` and its `check` guard, `scripts/with-env.sh`, `scripts/initialize.sh`, the docs checker, the Allium runner and the ripsecrets wrapper. So the prototype environment was built straight into the path they name: `nix build <flake>#default --out-link .pixi/envs/default`, and `.tools/bin` is a link to its `bin`. Both paths are gitignored, so `git status --short` stays empty and no tracked file changes. Ticket 02's seam removes the need for this: with one script owning the directories, the out-link gets a name of its own.

**What the machine still has to supply.** These are facts about the repository, not about Nix, and each was hidden by pixi or by the host:

- `sed`, `awk`, `find` and `diff`, and `/usr/bin:/bin` holding the usual utilities: two checker test files run their cases with exactly that `PATH`.
- `perl`, for `scripts/release/stamp-chart.sh` and `scripts/release/lib.sh`. Today the recipes find conda's perl in `.pixi/envs/default/bin`, where Erlang's conda package puts it. The Nix environment has none, so those scripts use the machine's perl unless the flake adds one.
- A system CA store, with the network off too. Without it `just lint` fails 12 times with `No CA certificates were loaded from the system` (lychee builds its client before it knows it is offline), and the Erlang HTTP tests fail with `FailedLoadCacerts(NoCacertsFound)`.

**The four cases.**

1. **The checker tests run through the interpreter's own pytest: yes.** `sys.executable` is `.pixi/envs/default/bin/python3`, the out-link path, and `pytest 9.1.1` loads from the Python environment in the store. `just test-checkers` passes (168 tests). `just test-checkers-all` has 714 passing, 65 failing and 13 skipped; the 65 are cases 2 and the Allium gap below, and with the scratch patch all 779 pass. The 13 skipped are the installer tests, which skip because `tools.txt` has no line for this host.
2. **The docs checker's Node does not find markdown-it where the checker looks.** nixpkgs' `bin/markdownlint-cli2` is a wrapper script that runs `node …/lib/node_modules/markdownlint-cli2/markdownlint-cli2-bin.mjs`; conda's is a link to that file. The checker resolves `markdown-it` from the real path of `bin/markdownlint-cli2`, so under Nix it searches beside the wrapper and fails with `Cannot find module 'markdown-it'`, and `just docs-check` reports `Markdown parser unavailable`. Given the module's own entry script, `<prefix>/lib/node_modules/markdownlint-cli2/markdownlint-cli2-bin.mjs`, the same command renders. The prototype's environments link `lib/node_modules` beside `bin` for this. The fix is one path in the checker, which ticket 02 moves behind its Python helper. The bundled markdown-it is 15.0.3 (pixi: 15.0.1) under Node 24.22.2 (pixi: 26.10.0).
3. **The path prek writes into the git hook does not follow a lock move.** prek 0.5.10 writes its resolved store path, `PREK="/nix/store/…-prek-0.5.10/bin/prek"`, not the out-link it was started through. After the out-link moved to an environment with prek 0.5.7, the hook still ran 0.5.10. Once the old path is garbage-collected the hook falls back to `prek` on `PATH`, which git's hook environment does not have: the commit fails with `exec: prek: not found`. That last step was simulated by renaming the path in a copy of the hook, because other roots held the real one. With the out-link path written into the hook instead (`PREK="<checkout>/.pixi/envs/default/bin/prek"`), commits pass before and after the move. Under pixi the binary is a real file in the worktree, so the question never arose. Ticket 07's hook step has to write the out-link path, or the hook has to be reinstalled after every lock move.
4. **A fresh clone with only Nix reaches `just`.** On a new store volume and a new `HOME`, `nix build <flake>#default --no-update-lock-file --out-link .pixi/envs/default` took 16 seconds, copied 147 paths from the cache and built five trivial derivations, and `.pixi/envs/default/bin/just --list` then ran. `nix shell <flake>#default --no-update-lock-file --command just --version` works without an out-link. The store grew from 813 MB to 3.2 GB, which counts the three nixpkgs sources as well as the 871 MiB environment closure.

**The whole gate.** With no tracked file changed, each recipe of `just check` was run on its own:

| Recipe | Result | Cause of a failure |
| --- | --- | --- |
| `lock-check` | fails, exit 127 | Reads pixi: `pixi: not found`. |
| `env-check` | fails, exit 2 | Reads pixi: `.pixi/envs/default/conda-meta/pixi is missing`. |
| `docs-check` | fails, exit 1 | Case 2: the markdown-it path. |
| `check-specs`, `analyse-specs` | fail, exit 1 | An aarch64-linux gap, not a Nix one: `tools.txt pins no Allium for this platform`. `tools.txt` has no linux-aarch64 line and the runner's host map no entry for it. The binary itself runs. |
| `manifest-check`, `agents-check`, `format-check`, `lint-gleam`, `test`, `snapshots-check`, `fake-worker-lint`, `fake-worker-test`, `test-checkers`, `packaging-check`, `chart-check`, `toml-check`, `lint` | pass | |

`just check` itself stops at `lock-check`. Then [gate-scratch.patch](gate-scratch.patch) was applied in the clone only. It changes three tracked files, 11 lines in and 7 out, and is what tickets 02 and 07 do properly:

- `Justfile`: `lock-check` runs `nix flake lock --no-update-lock-file --offline <flake>`, and `env-check` runs [env-check.sh](env-check.sh);
- `scripts/checks/validate_docs.py`: the module directory instead of `bin/markdownlint-cli2`;
- `scripts/checks/run_allium.py`: Linux on aarch64 reads the `linux-64` pin's version.

With the patch and the network off, `just check` ran all 18 recipes and `check-clean` and ended with `All checks passed and the worktree is unchanged.` in 106 seconds, of which `just test` is 95. `just test-checkers-all` then passed too.

**The lock and environment checks.** The lock check takes 0.02 seconds. [env-check.sh](env-check.sh) is a prototype of the environment check ticket 07 writes: the out-link resolves into the store, it equals the output path this commit's flake evaluates to, and gleam, erlang, openssl, rebar3 and allium report the held versions. It takes 1.5 seconds, 1.2 of them evaluating the output path, and refuses a moved out-link with `… but this commit describes …`. Neither check writes in the clone or adds a store path. Outside the clone they write only Nix's own caches under `~/.cache/nix` (`fetcher-cache-v4.sqlite` and one `eval-cache-v6` file).

### 8. Version differences

[differences.txt](differences.txt), on today's tree, with the prototype's versions. "Hold the pixi version" means the flake pins it; "accept" means the candidate's version is taken and ticket 10 fixes whatever it finds.

| Tool | pixi | Prototype | What differs on today's tree | Mark |
| --- | --- | --- | --- | --- |
| gleam | 1.19.0 | 1.19.0 (candidate: 1.19.2) | Nothing with the hold. With the candidate's 1.19.2 the format check, the build with warnings as errors, glinter and all 676 tests also pass, and `manifest.toml` is not rewritten. | Hold the pixi version. |
| erlang | 29.1.2 | 29.1.2 | Nothing. | Hold the pixi version. |
| OpenSSL | 3.6.5 | 3.5.9 | No finding: the six TLS cases and every test pass. | Accept and fix in 10: nothing in the tree to fix. Ticket 06 records the choice, or picks the nixos-26.05 pair. |
| kubectl | 1.36.0 | 1.36.3 (candidate: 1.37.2) | Not run: no cluster in the container. | Hold the pixi minor. |
| kind, kwokctl | 0.33.0, 0.8.0 | the same | Not run: no cluster in the container. | Hold the pixi version. |
| just | 1.58.0 | 1.59.0 | No finding. | Accept and fix in 10: nothing to fix. |
| prek | 0.5.5 | 0.5.10 | No finding in any of the 17 hooks. The hook path is case 3 above. | Accept and fix in 10: nothing to fix. |
| typos | 1.51.1 | 1.52.0 | No finding. | Accept and fix in 10: nothing to fix. |
| markdownlint-cli2 | 0.23.3 | 0.24.0 | No finding (markdownlint 0.42.0 against 0.41.1). The package layout is case 2 above. | Accept and fix in 10: nothing to fix. |
| python | 3.14.8 | 3.14.10 | No finding; all 779 checker tests pass. | Accept and fix in 10: nothing to fix. |
| ruff | 0.16.10 | 0.17.4 | No finding from `ruff check` or `ruff format --check`. | Accept and fix in 10: nothing to fix. |
| helm | 4.3.0 | 4.3.1 | No finding: `just chart-check` and the chart tests pass. | Accept and fix in 10: nothing to fix. |
| kustomize | 5.8.2 | 5.8.3 | No finding: the chart tests pass. | Accept and fix in 10: nothing to fix. |
| hadolint | 2.15.1 | 2.14.0 | No finding: `just packaging-check` passes. nixpkgs is behind the pin here. | Accept and fix in 10: nothing to fix. |
| grype | 0.120.1 | 0.120.0 | See [Scanning](#10-scanning). | Accept and fix in 11. |
| Node | 26.10.0 | 24.22.2 | No finding. | Accept and fix in 10: nothing to fix. |

lychee, taplo, actionlint, shellcheck, pytest, rebar3, ripsecrets, editorconfig-checker, allium and kubeconform are the same version in both.

The repairing formatters (`just fix`) rewrite nothing through gleam format, taplo or ruff. The one hook that rewrites files is `trailing-whitespace`, on 12 transcripts under the evidence directories of this round, helm-chart and org-transfer. That is not a version difference: prek 0.5.5 from pixi rewrites the same 12, because `.pre-commit-fix.yaml` excludes only the bootstrap round's evidence.

### 9. The image and TLS

[image/Dockerfile](image/Dockerfile) is the prototype, [image.sh](image.sh) builds and checks it with the host's `docker build`, and [image.txt](image.txt) is the transcript. [tls-pairs.txt](tls-pairs.txt) repeats the TLS cases outside the image on both Erlang and OpenSSL pairs of [Held versions](#3-held-versions).

**The shape.** The build stage is the pinned Nix image. It copies `flake.nix` and `flake.lock` alone into a directory of their own and builds the `default` group for gleam, erlang and rebar3 and the `runtime` group for what ships. It then lays the runtime closure out for the final stage: `nix path-info --recursive` lists the store paths, they are copied under `/out/nix/store`, and `/out/opt/knarr/runtime` is a link to the environment. After that it runs `gleam deps download` and `gleam export erlang-shipment` as today. The final stage is the Ubuntu base by today's digest and takes that tree with one `COPY --from=build /out/ /`.

**The fixed prefix is `/opt/knarr/runtime`**, a link to `/nix/store/…-knarr-runtime`. Store paths are not relocatable, so the closure keeps its paths under `/nix/store` and the prefix is the one stable name: it is what `PATH` and the checkers' runtime-prefix constant use.

**The build context is staged**, because the root `.dockerignore` is an allowlist that leaves the evidence directory out. It holds the two flake files, `gleam.toml`, `manifest.toml`, `src/` and the entrypoint script: 32 files. A context has no `.git`, so the flake is read as a `path:` flake; see [Flakes and git](#6-flakes-and-git).

| Measure | Prototype | Today's image |
| --- | --- | --- |
| Build, `--no-cache`, base images already pulled | 51 seconds; 30 to 51 over seven runs | 21 seconds; 21 to 78 over three runs |
| Build, nothing changed | 1 second | 1 second |
| Build after an edit under `src/` | 9 seconds; 6 to 15 over five runs | 4 seconds |
| Image size, `docker image inspect` `.Size` | 114.3 MB | 103.6 MB |
| Image size, `docker images` | 461 MB | 401 MB |
| Runtime | 19 store paths, 223 MB under `/nix/store` | the conda environment, 176 MB with perl pruned |
| Largest paths | erlang 131 MB, glibc 47 MB, gcc-lib 10 MB, ncurses 9 MB, openssl 9 MB | `lib/erlang` 120 MB |
| Shipment | 2.7 MB | 2.7 MB |

Both are linux/arm64. Today's image is [baseline.txt](baseline.txt): the tracked `Dockerfile` built from a clean `git archive` of HEAD, tagged `knarr-nix-proto:pixi-baseline`. The prototype is about 11 MB larger compressed and 60 MB larger on disk. Most of that is the closure's own glibc, which the conda environment takes from Ubuntu instead, with bash, coreutils, gawk and gnused.

The build times are an order of magnitude, no more. The Mac was shared with other builds while they ran, and the same command took between 21 and 78 seconds from one run to the next; the first number in each cell is the one in the transcript. Two runs that stalled outright, a prototype cold build of 382 seconds and a baseline rebuild of 953 seconds, are left out. The prototype's flake layers and its copy of the closure sit before the sources in the Dockerfile, so an edit under `src/` reruns only `gleam export`.

**perl is not in Erlang's closure.** No store path in the closure is perl and no file under `/nix/store` is named `perl*`. `scripts/prune_runtime.py`, its test and `image-check`'s perl assertions have nothing left to do. The closure does carry bash, coreutils, gawk and gnused, which Erlang's own scripts refer to.

**The six TLS cases pass in the prototype image under `image-check`'s restrictions.** [image.sh](image.sh) repeats the `docker run` arguments `scripts/checks/image.py` builds in `common`: `--pull=never`, `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--tmpfs=/tmp:rw,noexec,nosuid,size=16m`, and `--memory` and `--memory-swap` at the chart's limit, 256Mi, as user `10001:10001`. With them:

- `tls/run.sh /opt/knarr/runtime /tmp/tls` from bootstrap ticket 01, unchanged, ends `tls_check: all 6 cases matched`, on `otp_release 29, erts 17.1.1` and `OpenSSL 3.5.9 29 Sep 2026`, with certificates made by the `openssl` command in the same prefix;
- the entrypoint bounds the descriptor limit to 65536, and `/opt/build-otp` and the runtime both say OTP 29;
- the container starts, `/readyz` answers `ok`, `/metrics` has `knarr_startups_total 1`, and memory is 72 MiB of 256 MiB (72 to 100 MiB over the runs).

Outside the image, the same six cases pass on both pairs: the candidate's OTP 29.1.2 with OpenSSL 3.5.9, and nixos-26.05's OTP 29.1.2 with OpenSSL 3.6.5.

`scripts/checks/image.py` itself, unchanged, stops on this image at its conda check, `no conda-meta in /opt/knarr/.pixi/envs/runtime`. Ticket 03's prefix constant and ticket 09's removal of the conda checks are what it needs.

### 10. Scanning

[grype.txt](grype.txt). grype is the prototype's `audit` group: 0.120.0, one patch behind the pin. The vulnerability database is v6.1.10, built 2026-10-30. It is the one the host's grype had already cached, copied to scratch, and the scans ran with the network off, so nothing was downloaded. What grype catalogues does not depend on the database's age; what it matches does.

| Source | Catalogers that found packages | erlang and openssl | `--only-fixed --fail-on high` |
| --- | --- | --- | --- |
| Directory: the runtime closure's store paths under `nix/store` | `nix-cataloger` 18, `erlang-otp-application-cataloger` 34, `binary-classifier-cataloger` 3 | erlang 29.1.2 and openssl 3.5.9, each by `nix-cataloger` (`pkg:nix/…`) and by `binary-classifier-cataloger` (`pkg:generic/…`); the OTP applications too (ssl 11.7.8, crypto 5.10, public_key 1.21.8, erts 17.1.1) | exit 0, no match |
| Image: `docker save` of the prototype image, as `docker-archive:` | `nix-cataloger` 18, `binary-classifier-cataloger` 6, `dpkg-db-cataloger` 92, `elf-binary-package-cataloger` 3 | erlang 29.1.2 and openssl 3.5.9, by the same two catalogers; no OTP applications | exit 0, no match |
| Control, directory: the same two packages at the `nixpkgs-gleam` revision, OTP 29.1.1 and OpenSSL 3.5.8 | `nix-cataloger` 14, `erlang-otp-application-cataloger` 34, `binary-classifier-cataloger` 3 | erlang 29.1.1 and openssl 3.5.8 | exit 2: 42 matches, 13 of them high |

What that means for `just runtime-scan` (ticket 11):

- **`conda-meta-cataloger` finds nothing in a Nix closure.** `scripts/checks/runtime_scan.py` reads the line `discovered N packages cataloger=conda-meta-cataloger`, so today's script answers "cannot decide" for any Nix image, as the round README expects.
- **grype does catalogue the closure**, and the line has the same shape for the catalogers that do: `discovered 18 packages cataloger=nix-cataloger` and `discovered 3 packages cataloger=binary-classifier-cataloger`. `nix-cataloger` works from the store path names; the image has no Nix database.
- **The image source sees the closure too.** conda records were invisible in an image, which is why `runtime-scan` copies the environment out. Store paths are not: `grype <image>`, which is `just image-scan`, catalogues the Nix Erlang and OpenSSL beside Ubuntu's packages. Ticket 11 can scan either source.
- **Erlang's advisories match through one cataloger only.** In the control, the three Erlang matches (CVE-2026-94200 high, CVE-2026-105236 and CVE-2026-96596, all fixed in 29.1.2) are on the `binary-classifier-cataloger` package. `nix-cataloger`'s `erlang` and the 34 OTP application packages matched nothing. OpenSSL matched through both the binary and the nix package. So the fail-closed test is not "some cataloger found something": it is that `binary-classifier-cataloger` catalogued `erlang`, and that `openssl` was catalogued.

Not shown: a control on the image source, and anything grype 0.120.1 does differently from 0.120.0.

## What was evaluated but not run

Everything above ran on aarch64-linux. For the other two systems the flake was evaluated and the cache was asked; nothing was fetched, built or run.

### aarch64-darwin, for ticket 04 and Decision 0017

1. **Every package's darwin output is in the binary cache.** All rows of the package table, the held gleam 1.19.0, erlang 29.1.2 with openssl 3.5.9, rebar3 3.28.0 and kubectl 1.36.3 answered `cached=yes`. None was downloaded, so no darwin signature or content was checked.
2. **The plan for each group**: `default` builds 5 derivations locally and fetches about 519 MiB (2.2 GiB unpacked); `cluster`, `audit` and `runtime` build 2 each. The locally built derivations (the environments, the Python environment, allium) have never been built on darwin.
3. **allium's darwin asset** has the sha256 `tools.txt` pins and is a Mach-O arm64 executable. Its derivation evaluates for darwin, where it does no patching. Whether the unpatched binary runs from the store there was not tried.
4. **Erlang on darwin**: OTP 29.1.2 built against OpenSSL 3.5.9, by evaluation. `crypto:info_lib()`, the six TLS cases, and gleam 1.19.0 and rebar3 against it were not run.
5. **The closure sizes differ.** By the cache's own numbers ([systems.txt](systems.txt)), `python314`'s closure is 1366 MiB on darwin against 229 MiB on aarch64-linux, and markdownlint-cli2's is 1507 MiB against 377 MiB. The `default` group unpacks to 2.2 GiB against 1.3 GiB. What the extra is was not looked into.
6. **The four PATH-prefix cases, the offline gate, and the lock and environment check timings** were run on Linux only. Case 2 (the wrapper script) and case 3 (prek's store path) come from how nixpkgs packages those tools, so they should hold on darwin; that is an inference.
7. **A linked worktree** was a `git worktree add` inside the container. The maintainer's worktrees on the Mac were not used.
8. **What the machine supplies** differs on darwin: `sed`, `awk`, `find`, `diff` and `perl` are the BSD and system ones in `/usr/bin`, and the CA store is the keychain. Nix-built lychee and Erlang were not checked against it.
9. **Nix itself**: the installer, flakes without machine configuration (here it was `NIX_CONFIG` in the container's environment and nothing else), the daemon and the sandbox (the container ran single-user as root with `sandbox = false`), the out-link as a garbage-collection root, and the store shared between worktrees. All of that is ticket 04's.
10. **grype on darwin** was not run; the scan runs on Linux in CI.

### x86_64-linux, for ticket 05

1. Every package's x86_64-linux output is in the binary cache, the held ones included, and each group's plan is the same shape as on aarch64-linux.
2. allium's x86_64 asset has the sha256 `tools.txt` pins and is dynamically linked like the aarch64 one, so it needs the same patching. That derivation was evaluated, not built.
3. The gate, the image for linux/amd64, the six TLS cases in it and grype were not run on x86_64.
