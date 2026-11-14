---
title: "Decision 0017: Nix owns the toolchain"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_nix_toolchain]
requires: []
---

# Decision 0017: Nix owns the toolchain

Supersedes [Decision 0003: Tool manager](0003-tool-manager.md).

## Context

[Decision 0003](0003-tool-manager.md) made pixi the owner of Gleam, Erlang/OTP and every repository and cluster tool, through `pixi.toml` and `pixi.lock`, with `tools.txt` for what conda-forge lacks. That is two pin mechanisms, and the shipped image carries a conda environment that a script prunes and a scan has to copy out to see. The maintainer decided on 2026-11-14 to move the toolchain to Nix, and settled the scope in the [round README](../../.scratch/nix-migration/README.md): Nix replaces pixi as a prerequisite; Docker, git and a POSIX shell stay on the host; nothing else on a machine is managed by Nix (no nix-darwin, no home-manager, no global profile); hex packages stay with gleam; the shipped image moves too; and an exact version is held only where evidence or a rule depends on it. A change of tool manager is not among 0003's reopening conditions, so this is a new record.

The evidence is nix-migration ticket [01](../../.scratch/nix-migration/issues/01-nix-container-spike.md)'s, in [`.scratch/nix-migration/evidence/01/`](../../.scratch/nix-migration/evidence/01/README.md). It was gathered on 2026-11-14 with Nix 2.35.6 in a digest-pinned `nixos/nix` container on the maintainer's Mac, so everything it ran, it ran on **aarch64-linux**. x86_64-linux and aarch64-darwin were evaluated from Linux and the binary cache was asked about them; nothing was built or run for either. Nix is not yet installed on the Mac. Ticket [05](../../.scratch/nix-migration/issues/05-nix-ci-renovate-spike.md) measures the CI runner and Renovate, and ticket [04](../../.scratch/nix-migration/issues/04-nix-host-spike.md) confirms this record on the Mac before ticket 10 makes Nix the default.

## Decision

### The choice

One flake, `flake.nix`, and its `flake.lock`, both at the repository root, own every tool the repository runs and the Erlang runtime both images ship. Hex packages stay with gleam: `gleam.toml` and `manifest.toml` pin them, `just initialize` runs one `gleam deps download`, and Nix never writes `manifest.toml`. Docker, git and a POSIX shell environment stay host prerequisites ([Host prerequisites](#host-prerequisites)).

### Three nixpkgs inputs

The flake has three locked nixpkgs inputs, not one:

| Input | Follows | Locked at (2026-11-14) | Supplies |
| --- | --- | --- | --- |
| `nixpkgs` | `nixpkgs-unstable` | `2074cc672349f14240fb7ea90d509e0b643e9dd4` (2026-11-12) | Every tool but two, and Erlang, rebar3 and OpenSSL. |
| `nixpkgs-gleam` | nothing: pinned by revision | `8edc0c72e3a38faf5434e40d1f19431125fe4b30` | Gleam 1.19.0 alone. It is the last nixpkgs-unstable channel head that carried 1.19.0, so Hydra built it. |
| `nixpkgs-kubectl` | `nixos-26.05` | `f1e5c356f35d07e7b71a6b5e6c9338e0b029e0c0` | kubectl 1.36 alone. |

The main input follows `nixpkgs-unstable` because nixos-26.05 fails two floors (Helm 3.20.2 against major 4, kwok 0.7.0 against 0.8.0), and the unstable head has OTP 29.1.2, Python 3.14.10 and pytest 9.1.1 ([holds.txt](../../.scratch/nix-migration/evidence/01/holds.txt)). Every package the flake takes from any of the three is in the binary cache for aarch64-linux, x86_64-linux and aarch64-darwin ([packages.txt](../../.scratch/nix-migration/evidence/01/packages.txt), [systems.txt](../../.scratch/nix-migration/evidence/01/systems.txt)). The cost of the second and third inputs is two more nixpkgs sources to fetch, and a second glibc in the tools closure. Neither reaches the runtime closure, which holds Erlang and OpenSSL only.

### Held versions

A held version is one the flake refuses to change silently. The hold is three things together, as in 01's [prototype flake](../../.scratch/nix-migration/evidence/01/flake.nix): `flake.lock` pins each input's commit and content hash; a tracked file names each held version; and each held package passes through an assertion, so a lock move that loses a held version fails evaluation instead of changing it. [holds.txt](../../.scratch/nix-migration/evidence/01/holds.txt) shows both directions: `error: held gleam: the locked input has 1.19.2, the hold is 1.19.0` and `error: held erlang: the locked input has 29.1.1, the hold is 29.1.2`.

| Held | How | Source | What depends on it |
| --- | --- | --- | --- |
| Erlang/OTP | exactly 29.1.2 | `beam_minimal.interpreters.erlang_29`, main input | Four OTP advisories fixed in 29.1.2 ([Decision 0014](0014-dependency-updates-and-audit.md), bootstrap ticket 52), and the TLS proof, which was run on this build ([Verify 1](#verification)). |
| Gleam | exactly 1.19.0 | `gleam`, `nixpkgs-gleam` | The round's rule names the compiler: a compiler move is a reviewed pin move, never a side effect of a lock move. The format check's output, the build with warnings as errors and 0003's `manifest.toml` findings were recorded on 1.19.0. 01 found the candidate's 1.19.2 passes all of them too ([differences.txt](../../.scratch/nix-migration/evidence/01/differences.txt)), so no failing check depends on 1.19.0 today. |
| rebar3 | 3.28.0 or later | `beam_minimal.packages.erlang_29.rebar3`, main input | Three advisories fixed by 3.28.0 (bootstrap ticket 53). A floor, not an exact version: the main input may move it forward. It is built with the held Erlang; the top-level `rebar3` is built with OTP 28. |
| allium | exactly 3.6.1 | upstream release asset, fixed hash | [Decision 0005](0005-project-managed-allium-cli.md)'s project-managed Allium binary at its agreed version, and the Allium runner, which refuses any other version. |
| kind | exactly 0.33.0 | `kind`, main input | The Kubernetes skew cap: kind 0.33 publishes the pinned `kindest/node:v1.35.8` image ([Decision 0007](0007-local-cluster.md)). |
| kubectl | minor 1.36 | `kubectl`, `nixpkgs-kubectl` | The skew cap: kubectl reaches servers one minor either side, and 1.36 reaches the 1.35 cluster. The main input has 1.37.2, which does not. Patches within 1.36 move with the input. |
| kwokctl | exactly 0.8.0 | `kwok`, main input, which carries `kwokctl` | The pinned kwok cluster images, `v0.8.0-k8s.v1.35.5`. |

Every other tool takes whatever the main input carries. The floors 01 marked for those (Python 3.14 or later, pytest 9, Helm major 4, markdownlint-cli2's bundled markdown-it under Node) are met at the candidate and are not held. Nothing asserts them, so a move of the main input is reviewed against them.

### The held-versions file

The held versions live in `pins.toml` at the repository root, a small tracked TOML file. The flake reads it with `builtins.fromTOML`, which is built into Nix and needs no import-from-derivation. The checkers read it with `tomllib`, with no Nix present, as they already read other TOML. taplo already formats and checks the repository's TOML. JSON would read as easily in both but takes no comments, and the file needs one line saying what owns each entry. The shape is flat tables of strings, one table per kind of hold:

```toml
# Decision 0017's held versions. flake.nix asserts each; the checkers read
# them with tomllib. Move one by moving the input that carries it.
[exact]
erlang = "29.1.2"
gleam = "1.19.0"
allium = "3.6.1"
kind = "0.33.0"
kwokctl = "0.8.0"

[minor]
kubectl = "1.36"

[floor]
rebar3 = "3.28.0"
```

That the flake reads this file is a requirement on ticket 07, not something 01 ran: the prototype holds the same versions as an attribute set inside `flake.nix`. What 01 did show is that the file must be tracked before the flake can see it ([git.txt](../../.scratch/nix-migration/evidence/01/git.txt)). From ticket 07, `pins.toml` is the one owner of the OTP version: the flake asserts its Erlang against it, ticket 03's OTP reader reads it, and a temporary test holds `pixi.toml`'s `erlang` pin equal to it until ticket 13 deletes `pixi.toml`.

### Erlang/OTP and its OpenSSL

The toolchain's Erlang is OTP 29.1.2 from the main input's `beam_minimal`, built against **OpenSSL 3.5.9**, the long-term-support line, and the flake takes OpenSSL from that same input. **This is a change from `pixi.lock`, which has OpenSSL 3.6.5.** Of the choices this record makes, it is the one the maintainer is most likely to want to revisit.

The hold is: **OTP exact; OpenSSL is whatever the held Erlang is built against, asserted in the flake.** `pins.toml` does not name an OpenSSL version. The flake fails evaluation unless the OpenSSL among Erlang's build inputs is the OpenSSL the environments ship, `openssl` command included. The environment check reports the installed OpenSSL and compares it with that evaluated value. So an OpenSSL patch release can arrive with a move of the main input, as conda-forge's builds could with a re-lock; `image-check`'s TLS rerun runs on every change after ticket 09 and is what catches a regression.

What proves 3.5.9 is safe: the six TLS cases from bootstrap ticket 01's proof pass on OTP 29.1.2 with OpenSSL 3.5.9, outside an image ([tls-pairs.txt](../../.scratch/nix-migration/evidence/01/tls-pairs.txt)) and inside the prototype image under `image-check`'s restrictions ([image.txt](../../.scratch/nix-migration/evidence/01/image.txt)), and the whole gate passes on it ([gate.txt](../../.scratch/nix-migration/evidence/01/gate.txt)). conda-forge's own Erlang was compiled against 3.5 headers: in today's image `crypto:info_lib()` reports the header number of 3.5.9 beside the library text `OpenSSL 3.6.5` ([baseline.txt](../../.scratch/nix-migration/evidence/01/baseline.txt)).

The alternatives, with what 01 measured ([holds.txt](../../.scratch/nix-migration/evidence/01/holds.txt)):

- **Keep the exact pixi pair, OTP 29.1.2 with OpenSSL 3.6.5, from a nixos-26.05 input.** Cached on all three systems, the six TLS cases pass on it, and its runtime closure is the same size (202 MiB against 205). Rejected because it ships an OpenSSL line that nixpkgs unstable has already removed, with the message `'openssl_3_6' has been removed, due to upstream end of life on 2026-11-01`. Holding it would mean shipping a runtime whose OpenSSL line gets no further fixes. Its tools closure was not measured.
- **Override the candidate's Erlang with another OpenSSL.** Forfeits the binary cache on all three systems: Erlang compiles from source on every machine and every cold CI job.

### Gleam

Gleam 1.19.0 comes from `nixpkgs-gleam`, cached on all three systems. No nixpkgs revision has both Gleam 1.19.0 and OTP 29.1.2, so the hold needs its own input ([holds.txt](../../.scratch/nix-migration/evidence/01/holds.txt)). An `overrideAttrs` with 1.19.0's source forfeits the cache: it compiled from source in 103 seconds on 18 cores, with the Rust toolchain already fetched, and failed once on a loaded machine ([gleam-override.txt](../../.scratch/nix-migration/evidence/01/gleam-override.txt)). Calling the 1.19.0 recipe on the candidate's toolchain does not build. Gleam leaves the input only when a move of the hold finds a revision that carries both the new Gleam and a cached build.

### Ordinary tools

Every other tool takes the main input's version, even where that is behind `tools.txt`: hadolint is 2.14.0 against 2.15.1, and grype 0.120.0 against 0.120.1. Neither difference changed a result ([differences.txt](../../.scratch/nix-migration/evidence/01/differences.txt)), and an upstream fetch for each would be two more hashes for no measured gain. allium is the only upstream fetch: nixpkgs does not carry it. It is a fixed-hash `fetchurl` of the release asset `tools.txt` names, installed with mode 0755 in a small derivation, with `autoPatchelfHook` on Linux, because both Linux binaries expect a loader at `/lib` that a store does not provide ([missing.txt](../../.scratch/nix-migration/evidence/01/missing.txt)). The hash is the upstream sha256, not a NAR hash. The aarch64-linux asset, which `tools.txt` never pinned, joins with GitHub's recorded digest.

Python comes as `python314.withPackages` with pytest inside, because the checker suite runs `sys.executable -m pytest`. Node is `nodejs-slim`, the one markdownlint-cli2's wrapper runs.

### What is dropped

**tilt.** It is pinned in `pixi.toml` and used by no recipe, script or page; outside `pixi.toml`, `pixi.lock` and Decision 0003's record of the pin, no tracked file names it ([README](../../.scratch/nix-migration/evidence/01/README.md#2-packages)). The flake does not carry it.

### Layout: tool groups, out-links and PATH

The flake's packages are four groups, each a `buildEnv` for aarch64-darwin, aarch64-linux and x86_64-linux:

- `default`: every tool the gate runs, Erlang and rebar3, the `openssl` command, and `perl` ([Host prerequisites](#host-prerequisites)).
- `cluster`: kind, kubectl and kwokctl. Optional, as pixi's `cluster` environment is.
- `audit`: grype. Optional.
- `runtime`: Erlang and the `openssl` command, nothing else. The images ship it.

Each environment links `lib/node_modules` beside `bin`. nixpkgs' `bin/markdownlint-cli2` is a wrapper script, so the docs checker must find the bundled markdown-it from the module directory, not from the real path of `bin/markdownlint-cli2` ([gate.txt](../../.scratch/nix-migration/evidence/01/gate.txt), case 2).

`just initialize` builds each installed group into a gitignored out-link of its own in the worktree, one per group. An out-link is also what keeps a group's store paths from garbage collection. Recipes reach the tools by a `PATH` prefix, exactly as 0003's "How recipes reach the environment" did: the tool-directory seam from ticket 02, `scripts/tool-dirs.sh`, prints the ordered directories (`dirs`) and finds one tool in them (`tool <name>`), and nothing else spells out a directory. The default group comes first, so shared binaries always resolve from it. The docs checker also needs markdownlint-cli2's module directory, not only a tool path, so the seam gains a way to give it that.

No recipe runs `nix develop`, `nix shell` or `nix run`. This is the reason 0003 refused `pixi run`: a wrapper command rewrites a drifted lock and exits 0. 01's drift table shows it for `nix shell`, `nix eval`, `nix build`, `nix flake metadata` and `nix flake show` ([lock.txt](../../.scratch/nix-migration/evidence/01/lock.txt)); `nix develop` and `nix run` were not in the table, and the rule covers them because they resolve the lock the same way. **Every Nix command a recipe runs carries `--no-update-lock-file`.** `--no-write-lock-file` is not a substitute: it leaves the file alone but builds from the re-resolved lock and exits 0.

The flake never refers to `self`, so evaluation copies nothing into the store; and every file the flake reads must be tracked, or the flake does not see it ([git.txt](../../.scratch/nix-migration/evidence/01/git.txt)).

### The selector while both backends exist

From ticket 07 to ticket 13, `KNARR_TOOLS=pixi|nix` selects a backend for a whole command. Only `scripts/tool-dirs.sh` reads it. A backend is selected whole: never default tools from one and cluster tools from the other.

| Stage | Tracked default |
| --- | --- |
| Ticket 07 to ticket 10 | `pixi` |
| Ticket 10 to ticket 13 | `nix` |
| From ticket 13 | No selector: ticket 13 removes it with the pixi backend. |

An unknown value never reaches a tool, but the refusal cannot live in `dirs`. The `Justfile` evaluates `dirs` when it loads, before any recipe, so a `dirs` that exits non-zero breaks `just --list` and every recipe's error message. `dirs` also must not print an empty string, because an empty `PATH` entry is the current directory. So:

- `dirs` always exits 0. For an unknown value it prints the tracked default's directories.
- `tool <name>` exits 2 for an unknown value, with a message naming `KNARR_TOOLS` and its two values.
- `scripts/with-env.sh`, `scripts/initialize.sh` and the `Justfile`'s `check` guard refuse with exit 2 and the same message. The `check`, `cluster-tools` and `audit-tools` guards already go through `tool`, so they inherit it.

Every hook goes through `with-env.sh` and every gate run through the `check` guard, so an unknown value cannot pass the gate or a commit.

### The lock and environment checks

- **Lock check:** `nix flake lock --no-update-lock-file --offline`. On drift it exits 1 with `requires lock file changes but they're not allowed due to '--no-update-lock-file'`, and `flake.lock` is byte-identical before and after. On a fresh lock it exits 0 in 0.02 seconds with the network off. It also refuses a lock that keeps an input `flake.nix` no longer names, and a revision edited by hand ([lock.txt](../../.scratch/nix-migration/evidence/01/lock.txt), [lock-offline.txt](../../.scratch/nix-migration/evidence/01/lock-offline.txt)). It does not evaluate, so it does not see a held version; the assertions run at the first evaluation.
- **Environment check:** three things, as 01's [env-check.sh](../../.scratch/nix-migration/evidence/01/env-check.sh) prototype proves them. The out-link resolves into the store; it is the output path this commit's flake and lock evaluate to; and gleam, erlang, rebar3 and allium report the versions `pins.toml` holds, and openssl the version the flake built Erlang against. A moved out-link is refused with `… but this commit describes …`. It takes 1.5 seconds, 1.2 of them evaluating. From ticket 08, when the cluster group is installed, it also compares kind, kubectl and kwokctl.
- **Policy tests that need no Nix:** standard-library Python checks `flake.lock`'s shape and `pins.toml`'s, and, until ticket 13, that `pixi.toml`'s `erlang` pin equals `pins.toml`'s. They run on a machine without Nix, so the lock cannot rot while pixi is the default.

Neither check writes in the worktree or adds a store path. Outside the worktree they write only Nix's own caches under `~/.cache/nix`.

### What carries over from Decision 0003

A superseded record decides nothing, so these rules from 0003 are restated here and stay in force:

- **`manifest.toml` is never rewritten by the gate.** Gleam has no frozen manifest mode. The gate keeps 0003's two checks: the pre-check that compares `gleam.toml`'s dependency tables with `manifest.toml`'s `[requirements]` without writing, before any gleam command, and the backstop that fails any gate recipe that changes a file.
- **One owner per pin; prek never double-owns a tool.** A tool the flake provides runs as a `repo: local`, `language: system` hook, or from a recipe. A remote hook pinned by SHA is allowed only for a tool with no flake source. Today there is none.
- **Recipes reach tools by `PATH`, never by a wrapper command** (above).

### The prek hook

prek writes its resolved store path into the git hook, `PREK="/nix/store/…-prek-0.5.10/bin/prek"`, not the out-link it was started through. After a lock move the hook keeps running the old prek, and once that path is garbage-collected a commit fails with `exec: prek: not found` ([gate.txt](../../.scratch/nix-migration/evidence/01/gate.txt), case 3; the collection step was simulated). With the out-link path written into the hook, commits pass before and after the move.

So the initialize step must make the hook resolve through the out-link, never a store path. This is a requirement on ticket 07, which writes the step, and on ticket 10, which makes it the default. Linked worktrees share `.git/hooks`, and hooks are installed only from the primary checkout, so the hook resolves through the primary checkout's out-link.

### The image

The shape is 01's prototype, [image/Dockerfile](../../.scratch/nix-migration/evidence/01/image/Dockerfile):

- The build stage is the Nix image, pinned by the digest of its multi-arch index. It copies `flake.nix`, `flake.lock` and `pins.toml` alone into a directory of their own, so the flake is a `path:` flake of three files, and builds the `default` group for gleam, erlang and rebar3 and the `runtime` group for what ships.
- It lays the runtime closure out for the final stage: the store paths under `/out/nix/store`, and `/out/opt/knarr/runtime` a link to the `runtime` environment.
- It then runs `gleam deps download` and `gleam export erlang-shipment` as today. The closure is laid out before the sources are copied, so an edit under `src/` reruns only the export.
- The final stage is the Ubuntu base by today's digest and takes the tree with one `COPY --from=build /out/ /`.

**The runtime prefix is `/opt/knarr/runtime`**, a link to `/nix/store/…-knarr-runtime`. Store paths are not relocatable, so the closure keeps its paths and the prefix is the one stable name `PATH` and the checkers use. `docker build` locally and the release workflow's `docker buildx build` are unchanged.

perl is not in Erlang's closure, so the prune script and `image-check`'s conda and perl checks have nothing left to do. The prototype image is 114.3 MB against today's 103.6 MB (`docker image inspect`), most of the difference being the closure's own glibc. Its cold build took 51 seconds against 21, and a build after a source edit 9 seconds against 4, on a shared machine where the same build varied from 21 to 78 seconds ([image.txt](../../.scratch/nix-migration/evidence/01/image.txt), [baseline.txt](../../.scratch/nix-migration/evidence/01/baseline.txt)).

### CI

The setup action installs Nix with an action pinned by commit SHA, restores a Nix store cache that only `main` writes, runs `just initialize`, installs the cluster and audit groups on request, and exports the selected tool directories to the job's `PATH`. No workflow names an OTP, Gleam or tool version. Exporting the directories keeps the bootstrap evidence scripts that `reconcile-proof.yml` runs working, since they prepend their own directories and keep the inherited `PATH`.

The Nix image cannot run the gate: it has no `/usr/bin`, `sed`, `awk`, `diff` or `perl`, and every recipe stops at `sed: command not found` when the `Justfile` loads ([host-needs.txt](../../.scratch/nix-migration/evidence/01/host-needs.txt)). The gate runs on the runner's own userland with the tool directories prefixed.

PENDING-05: the installer action's name and SHA, the cache strategy and whether it can be written from `main` only, and cold and warm setup times for the gate job and one cluster job against their 20-minute timeouts.

PENDING-05: x86_64-linux results. 01 ran nothing on x86_64. Whether `just check` and `just test-checkers-all` pass on ubuntu-24.04 under the flake, whether the image builds for linux/amd64 inside the kind jobs' timeout, and whether the six TLS cases pass in it.

### Dependency updates

A held version moves by moving the revision of the input that carries it, then editing `pins.toml`, and the assertions refuse a move that loses one. Nothing proposes such a move automatically: the assertions only refuse a wrong version. 01 found Gleam's hold by reading the channel releases on releases.nixos.org ([holds.txt](../../.scratch/nix-migration/evidence/01/holds.txt)). Ordinary tools move with the main input's lock.

PENDING-05: what Renovate's nix manager extracts from the flake (which inputs, and whether it reads `pins.toml`), whether its lock maintenance moves `flake.lock`, how it tracks the build-stage image, and which pins stay a manual move.

### Host prerequisites

A contributor needs Nix, Docker, git and a POSIX shell environment. 01 found the gate uses more of the machine than pixi made visible ([host-needs.txt](../../.scratch/nix-migration/evidence/01/host-needs.txt)). Each item, and who supplies it:

| Need | Supplied by | Why |
| --- | --- | --- |
| `sed`, `awk`, `find`, `diff`, and `/usr/bin:/bin` with the usual utilities | the host, as part of "a POSIX shell environment" | macOS and the runner both have them. Two checker test files run cases with `PATH=/usr/bin:/bin` exactly. GNU versions first on `PATH` would change how scripts behave on the Mac. |
| `perl` | the flake's `default` group | Conda's Erlang package brings perl into pixi's environment today, and `scripts/release/lib.sh` and `stamp-chart.sh` use it. Their test, `test_release_lib.py`, runs in the gate, so the gate's perl comes from the lock rather than the machine. Not prototyped: the flake must add it. |
| A CA store, with the network off too | the host | Without one, `just lint` fails 12 times because lychee builds its client before it knows it is offline, and the Erlang HTTP tests fail with `FailedLoadCacerts(NoCacertsFound)`. On Linux the store at `/etc/ssl/certs/ca-certificates.crt` satisfied both; every real machine and the runner have one. Taking `cacert` from the flake would need an exported variable, and recipes set only `PATH`. On the Mac the store is the keychain, which is unverified. |
| git | the host | Nix reads the flake through git; a linked worktree works ([git.txt](../../.scratch/nix-migration/evidence/01/git.txt)). |

### The `.nix` formatter

The gate formats Nix files. Every other language the repository writes by hand has a format check in the gate (`gleam format --check`, `ruff format --check`, `taplo fmt --check`) and a repairing form under `just fix`, and `flake.nix` should not be the exception. The formatter is `nixfmt` from the main input, as a local `language: system` hook, so it has one owner like every other tool.

It arrives in ticket 10. Before that the default backend is pixi, which has no Nix formatter, and the gate must pass on the default. Until then `flake.nix` passes the spelling, editorconfig and secrets hooks only. 01 ran no Nix formatter: that the attribute is cached and that the flake is formatted cleanly are for ticket 10 to show.

## Verification

0003's five questions, answered for Nix. Each answer is from aarch64-linux; none claims the Mac or x86_64.

**Verify 1, TLS on the toolchain's OTP.** Bootstrap ticket 01's six TLS cases all match on OTP 29.1.2 with OpenSSL 3.5.9, outside an image ([tls-pairs.txt](../../.scratch/nix-migration/evidence/01/tls-pairs.txt)) and in the prototype image run read-only, with all capabilities dropped and as user 10001, with certificates made by the `openssl` command in the same prefix ([image.txt](../../.scratch/nix-migration/evidence/01/image.txt)): `tls_check: all 6 cases matched`.

**Verify 2, one owner of the OTP version.** `pins.toml`'s `erlang` entry, asserted by the flake, which builds the dev environment, CI's environment and both image stages from one `flake.lock`. In the prototype, the build stage and the runtime both report OTP 29 and erts 17.1.1 from the same store path ([image.txt](../../.scratch/nix-migration/evidence/01/image.txt): `OTP: build stage 29, runtime 29`), and the assertion refuses a lock move to 29.1.1 ([holds.txt](../../.scratch/nix-migration/evidence/01/holds.txt)). That the held version is read from `pins.toml` rather than the flake's own attribute set is ticket 07's to show.

**Verify 3, where rebar3 comes from.** `beam_minimal.packages.erlang_29.rebar3` in the main input, 3.28.0, built with the held Erlang: `rebar 3.28.0 on Erlang/OTP 29 Erts 17.1.1` ([gate-setup.txt](../../.scratch/nix-migration/evidence/01/gate-setup.txt)). It came from the binary cache with a `cache.nixos.org-1` signature ([holds.txt](../../.scratch/nix-migration/evidence/01/holds.txt)). The offline gate, whose `just test` builds the rebar3-built hex dependencies, and the prototype image build both pass with it. No negative control without rebar3 was run here; 0003's showed the build fails without it.

**Verify 4, a source for every tool.** Every line of `pixi.toml` and `tools.txt` has a row: every tool but allium is in the main input, cached on all three systems, and allium is the fixed-hash upstream fetch, which runs from the store ([packages.txt](../../.scratch/nix-migration/evidence/01/packages.txt), [missing.txt](../../.scratch/nix-migration/evidence/01/missing.txt)). tilt is dropped. With the scratch patch that tickets 02 and 07 replace, `just check` passes from the prototype prefix with the network off: `All checks passed and the worktree is unchanged.` ([gate.txt](../../.scratch/nix-migration/evidence/01/gate.txt)).

**Verify 5, `manifest.toml` never rewritten.** Nix does not touch hex packages. In the prototype environment, the requirements pre-check passes, `gleam deps download` runs, and `manifest.toml` is unchanged ([gate-setup.txt](../../.scratch/nix-migration/evidence/01/gate-setup.txt)); the offline gate ends with the worktree unchanged ([gate.txt](../../.scratch/nix-migration/evidence/01/gate.txt)). With the candidate's Gleam 1.19.2 too, `manifest.toml` is not rewritten ([differences.txt](../../.scratch/nix-migration/evidence/01/differences.txt)).

## Unverified on darwin

Each of these was evaluated from Linux, or inferred, and not run on aarch64-darwin. Ticket 04 confirms or corrects each on the Mac, and adds a dated note to this record where a fact changes; this body is not rewritten.

1. **The binary cache has every darwin output**, the held Gleam, Erlang with OpenSSL 3.5.9, rebar3 and kubectl included. The cache answered; nothing was downloaded, so no darwin signature or content was checked.
2. **Each group's plan.** `default` builds five derivations locally and fetches about 519 MiB (2.2 GiB unpacked); the other groups build two each. The locally built ones (the environments, the Python environment, allium) have never been built on darwin.
3. **allium's darwin asset** has the sha256 `tools.txt` pins and is a Mach-O arm64 executable. Whether it runs unpatched from the store was not tried.
4. **Erlang on darwin:** OTP 29.1.2 against OpenSSL 3.5.9 by evaluation only. `crypto:info_lib()`, the six TLS cases, and gleam and rebar3 against it were not run.
5. **Closure sizes.** By the cache's numbers, `python314`'s closure is 1366 MiB on darwin against 229 on aarch64-linux, and markdownlint-cli2's 1507 MiB against 377. What the extra is was not examined.
6. **The four PATH-prefix cases, the offline gate, and the lock and environment check timings.** The markdown-it path and prek's store path come from how nixpkgs packages those tools, so they should hold on darwin; that is an inference.
7. **A linked worktree** was a `git worktree add` in the container, not the maintainer's worktrees.
8. **What the host supplies:** BSD `sed`, `awk`, `find` and `diff`, the system perl if the flake's is not first, and the keychain as the CA store. Nix-built lychee and Erlang were not checked against the keychain.
9. **Nix itself:** the installer, flakes with no machine configuration (01 used `NIX_CONFIG` in the container's environment and nothing else), the daemon and the sandbox (01 ran single-user as root with `sandbox = false`), the out-link as a garbage-collection root, and the store shared between worktrees.
10. **grype on darwin.** The scans run on Linux in CI.

The list is 01's ([README](../../.scratch/nix-migration/evidence/01/README.md#what-was-evaluated-but-not-run)).

## Consequences

The round's tickets carry this out in expand–contract order ([round README](../../.scratch/nix-migration/README.md)): 07 adds the flake beside pixi behind `KNARR_TOOLS`; 08 and 09 move the cluster and audit tools and the images; 10 makes Nix the default in the gate and CI together, after 04 has confirmed this record on the Mac; 11 moves the runtime scan; 12 moves Renovate; 13 deletes `pixi.toml`, `pixi.lock`, `tools.txt` and the installer.

- **One pin mechanism.** `flake.lock` pins every tool by content hash, and `pins.toml` names what is held. `tools.txt` and its installer go. allium's hashes move into the flake.
- **The runtime scan changes shape.** grype's `conda-meta-cataloger` finds nothing in a Nix closure, so today's `runtime-scan` cannot decide on a Nix image. grype does catalogue the closure, through `nix-cataloger` and `binary-classifier-cataloger`, from the image as well as from a directory; Erlang's advisories match only through `binary-classifier-cataloger` ([grype.txt](../../.scratch/nix-migration/evidence/01/grype.txt)). Ticket 11 rebuilds the scan on that. Nobody pushes a release tag between ticket 09's merge and 11's.
- **Store size.** A machine with an empty store fetches about 413 MiB for the `default` group on aarch64-linux and unpacks 1.3 GiB; the store grew from 813 MB to 3.2 GB on a fresh clone, which counts the three nixpkgs sources ([fresh.txt](../../.scratch/nix-migration/evidence/01/fresh.txt)). The store is shared between worktrees, where pixi's environments were per worktree.
- **The first run needs the network** for the Nix fetches, allium's asset and the hex packages. After `just initialize` the gate runs offline.
- **A move of the main input is a review.** It can move every ordinary tool, OpenSSL's patch level and rebar3 at once. The assertions stop it only at a held version.

## What would reopen this

- **nixpkgs carries allium.** It moves from the fixed-hash fetch to the main input. That is a source change, not a new decision.
- **One revision carries every held version.** If a nixpkgs revision has the held Gleam with the held OTP, or kubectl inside the skew cap, the extra input goes. That is a lock move.
- **The OpenSSL choice is revisited.** If the maintainer wants OpenSSL exact, or a TLS case fails on a later 3.5 patch, the held pair changes and Verify 1 is rerun on it.
- **Nix changes the lock-check behaviour.** If `--no-update-lock-file` stops refusing a drifted lock, or starts writing, the lock check changes.
- **Gleam gains a frozen manifest mode.** It would replace the requirements pre-check.
- **The Mac or the runner disagrees.** If ticket 04 or ticket 05 gives a different result from Linux for TLS, rebar3, the gate or the hook, this record is reopened.
- **The runtime closure is too large.** If the image cannot meet its size target, the closure's glibc is the first place to look, and the image shape is reopened.

## Related pages

- [Decision 0003: Tool manager](0003-tool-manager.md), which this record supersedes
- [Decision 0014: Dependency updates and audit](0014-dependency-updates-and-audit.md), for the scans and Renovate
- [The Nix migration round](../../.scratch/nix-migration/README.md) and [ticket 06](../../.scratch/nix-migration/issues/06-nix-decision-record.md)
- [Evidence for this record](../../.scratch/nix-migration/evidence/01/README.md)
