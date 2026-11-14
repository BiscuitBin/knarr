# Nix migration ticket 05 evidence

Evidence for [ticket 05](../../issues/05-nix-ci-renovate-spike.md) of the Nix migration round: the Nix installer action and cache strategy measured on the real runner, [ticket 01](../01/README.md)'s prototype environment running the gate there, the prototype image built for linux/amd64, and Renovate's nix manager against the prototype flake. Ticket 06 records the decision from it; ticket 10 writes the setup action; ticket 12 writes the Renovate configuration.

Gathered on 2026-11-14. The runner part ran on GitHub's `ubuntu-24.04` hosted runners (x86_64, Ubuntu 24.04.5, 4 cores, 15 GiB). The Renovate part ran on the Mac's Docker (Docker Desktop, linux/arm64). Nix was not installed on the Mac.

## How it ran

The workflow ran from a throwaway branch, `spike/nix-ci-05`, made from this ticket branch with one added file, `.github/workflows/nix-spike.yml`. Its trigger is a push to that branch only; no other workflow in the repository fires on such a push (`ci.yml` and `reconcile-proof.yml` push only on `main`, the others on schedules, labels, tags or dispatch). It ran three times; the branch was deleted afterwards.

| Run | Spike commit | What it measured |
| --- | --- | --- |
| [43642997847](https://github.com/BiscuitBin/knarr/actions/runs/43642997847) | `a797c38bcb3e0c9d8bb2ed41da401f85582412d2` | Every job cold; the two cached jobs miss and write their keys |
| [43643668469](https://github.com/BiscuitBin/knarr/actions/runs/43643668469) | `cb3cd00877c55572f2defc14ec550d9ceeb6ed03` | Cold jobs again; the cached jobs restore (warm). `gate.sh` gained the uid and mode line |
| [43644038497](https://github.com/BiscuitBin/knarr/actions/runs/43644038497) | `23f498478943b73f65a4a081f5c08d559b60b9d4` | An empty commit: a third cold sample and a second warm one |

The spike commits are unreachable now that the branch is gone; the run pages keep their logs. The scripts the runs called are the ones in this directory, except that run 1 used `gate.sh` without its uid and mode line.

| File | Where it runs | What it is |
| --- | --- | --- |
| [nix-spike.yml](nix-spike.yml) | the runner | The throwaway workflow, byte for byte as it ran |
| [setup.sh](setup.sh) | the runner | Builds the prototype's groups into `.pixi/envs/<group>` (the paths every recipe already reads, as ticket 01's `gate-setup.sh` did), links `.tools/bin`, fetches the hex packages, and prints where each tool resolves |
| [gate.sh](gate.sh) | the runner | Applies ticket 01's `gate-scratch.patch` without its `run_allium.py` hunk, then runs `just check` or `just test-checkers-all` |
| [image.sh](image.sh) | the runner | Pulls the two base images, then runs ticket 01's `image.sh` unchanged |
| [timings.sh](timings.sh) → [timings.txt](timings.txt) | the Mac, `gh api` GETs | Every job and step of the three runs, in seconds, from GitHub's own step timestamps |
| [trim-log.sh](trim-log.sh) → [run-1.txt](run-1.txt), [run-2.txt](run-2.txt) | the Mac, `gh run view --log` | Runs 1 and 2, trimmed to their output lines; run 3's log is on its run page |
| [renovate.sh](renovate.sh) → [renovate.txt](renovate.txt) | the Mac's Docker | The Renovate dry run and the lock-update simulation |

No token was given to Nix, Renovate or any container. In the workflow, `extra_nix_config: access-tokens =` overrides the job token that the installer action writes into `nix.conf` by default, and every job prints `access-tokens: empty (no token)`. The jobs had `contents: read` and nothing else.

## Findings

### 1. The installer: `cachix/install-nix-action`

**Recommended: `cachix/install-nix-action@3dc140bfc76c49fbd4dd958429132e3746bcb086 # v31.11.5`**, with `extra_nix_config: access-tokens =` and `enable_kvm: false`. It installs upstream Nix 2.35.6, which is also the version in ticket 01's container. The repository's Actions settings allow every action (`allowed_actions: all`, `sha_pinning_required: false`), so nothing forced a choice.

Each candidate was read from its repository at its newest release on 2026-11-14:

| Candidate | Newest release, commit | What it installs | Account, token, telemetry | Does a SHA pin fix the Nix version? |
| --- | --- | --- | --- | --- |
| `cachix/install-nix-action` | v31.11.5 (2026-11-11), `3dc140bfc76c49fbd4dd958429132e3746bcb086` | Upstream Nix through the official install script, `https://releases.nixos.org/nix/nix-2.35.6/install`, as a multi-user daemon with the sandbox on | No account. Writes the job's `GITHUB_TOKEN` into `nix.conf` as `access-tokens` unless overridden. No telemetry | **Yes.** `install-nix.sh` names `nix_version=2.35.6`, so the commit fixes the version. The install script is fetched over HTTPS without a checksum, but it carries the sha256 of each system's tarball and refuses a mismatch |
| `DeterminateSystems/nix-installer-action` | v23 (2026-09-09), `3138316df39ed29be04236d7ffc686fa525866aa` | Determinate Nix by default. Upstream Nix with `determinate: false` "isn't a supported configuration … we may remove it" | Sends diagnostics to `install.determinate.systems` by default (`diagnostic-endpoint`). Token defaults to the job's | **No.** Its README: "uses the most recent version of Determinate Nix Installer, even when the Action itself is pinned" |
| `DeterminateSystems/determinate-nix-action` | v3.24.2 (2026-11-05), `16f94ba7aae399b9f9077c254b6719ec6de7e3e3` | Determinate Nix only, one release per tag | FlakeHub features need `id-token: write`; a `diagnostic-endpoint` input | Yes, but not upstream Nix |
| `NixOS/nix-installer-action` | v1.0.0 (2026-07-15), `62c1943b776c509394b550f3f983adc14e9212d6` | Upstream Nix through the NixOS installer | No account | Only through its `installer-version` input, which defaults to `latest`. Its README says "This action is experimental and is currently undergoing testing", and its `action.yml` downloads the installer binary with `curl` and checks no digest |
| The official script in a `run:` step | not an action | Upstream Nix, as above | none | Yes, by the URL's version; the same as `cachix/install-nix-action` without the environment and `nix.conf` set-up |

Installation took **3 to 5 seconds** in every job ([timings.txt](timings.txt)). The resulting configuration, printed by `setup.sh`: `experimental-features = fetch-tree flakes nix-command`, `sandbox = true`, `build-users-group = nixbld`, `max-jobs = 4`, `substituters = https://cache.nixos.org/`, `always-allow-substitutes = true`. So flakes need no `NIX_CONFIG` on the runner, and unlike ticket 01's container, builds ran sandboxed under the daemon's build users.

### 2. The cache: none

**Recommended: no store cache.** Every job substitutes from cache.nixos.org and fetches the three nixpkgs sources from github.com, anonymously. A restored store was no faster than a cold one, because unpacking the cache costs what the download saves.

Two strategies were measured, with the same installer:

- **cold**: no cache step.
- **cached**: `nix-community/cache-nix-action@7df957e333c1e5da7721f60227dbba6d06080569 # v7.0.2`, restoring `/nix`, with `primary-key: knarr-nix-spike05-x86_64-linux-<group>-${{ hashFiles(flake.nix, flake.lock) }}` and `restore-prefixes-first-match` on the same prefix without the hash.

Setup is the install step, plus the restore step, plus `setup.sh` (the `nix build` of each group and both `gleam deps download`). The figures are in seconds, from [timings.txt](timings.txt):

| Shape | Cold, no cache (runs 1, 2, 3) | Cached, first run (miss, then write) | Warm (runs 2, 3) | Timeout |
| --- | --- | --- | --- | --- |
| Gate: the `default` group | 33, 35, 34 (gate job); 34, 35, 40 (checker job) | 33, then 10 to save | 33, 35 (gate job); 38, 30 (restore-only checker job) | 20 min gate, 10 min checker regressions |
| Cluster: `default` and `cluster` | 52, 52, 40 | 45, then 20 to save | 44, 43 | 20 min kind jobs |

- A warm restore took 21 to 29 seconds, and `nix build` then took 2.6 to 4.9 seconds for `default` and 1.3 to 1.4 for `cluster`. Cold, `nix build` took 25.9 to 31.7 seconds for `default` (155 paths fetched, 428.2 MiB down, 1.3 GiB unpacked, 4 derivations built) and 10.6 to 15.9 for `cluster` (7 paths, 100.5 MiB).
- The keys are large. The `default` store is 1.93 GB, saved as a **609 MB** entry; `default` and `cluster` together are 2.51 GB, saved as **766 MB**. Today's pixi cache is 266 MB, and the repository's limit is 10 GB.
- Setup is under a minute in every case. It is under 6% of the gate's timeout and under 9% of the checker job's timeout.

**Writing from `main` only.** For each strategy:

| Strategy | Main-only write | How |
| --- | --- | --- |
| No cache (**recommended**) | Nothing is written | not applicable |
| `nix-community/cache-nix-action` (measured) | yes | `save: ${{ github.ref == 'refs/heads/main' }}`, the same expression as `cache-write` in today's setup action. The restore-only job ran with `save: false`: it hit the key in runs 2 and 3 and its post step was `skipped` in all three runs. A pull request can read a cache written on `main` |
| `actions/cache` on a store export (`nix copy --to file://…`), not measured | yes | `actions/cache/restore` everywhere and `actions/cache/save` with `if: github.ref == 'refs/heads/main'`. It adds an export and an import of the closure to each job, so it cannot beat the restore above |
| Magic Nix Cache (`DeterminateSystems/magic-nix-cache-action` v15, 2026-09-09), not measured | no | It still exists. It uploads during every run through a daemon it downloads from Determinate, with no write switch apart from `use-gha-cache`. Its `diagnostic-endpoint` is on by default. It skips paths the upstream cache (cache.nixos.org) has, which here is everything except the four environment derivations, so it would hold almost nothing |
| FlakeHub Cache (`DeterminateSystems/flakehub-cache-action` v3.24.2), not measured | not applicable | It needs a FlakeHub account (Determinate) and `id-token: write` |

**What "warm" measured, and the shortcut.** The cached jobs wrote their keys from `spike/nix-ci-05` with `save: true`, because the main-only rule cannot be exercised from a branch that is not `main`. That is a measurement shortcut. The two entries it left are scoped to `refs/heads/spike/nix-ci-05`, so no other branch can read them; see [What is left behind](#what-is-left-behind).

**The cost of no cache.** Every job depends on cache.nixos.org and github.com being reachable. Nine cold jobs fetched the nixpkgs sources from github.com with no token, and none was refused. Today's setup has the same dependency on conda-forge whenever its cache misses. If a cache is wanted later, `cache-nix-action` with the `save` expression above is the one measured, and its README says itself that "the action may slow down your workflow".

### 3. The gate on the runner

`just check` from the prototype environment **passed in all six gate jobs**, cold and cached, and ended "All checks passed and the worktree is unchanged." It took 117 to 138 seconds, and all 18 recipes and `check-clean` ran ([run-1.txt](run-1.txt), [run-2.txt](run-2.txt)). The whole gate job took 157 to 177 seconds against its 20 minutes.

- `gate-scratch.patch` was applied without its `run_allium.py` hunk (`git apply --exclude=scripts/checks/run_allium.py`), and `check-specs` and `analyse-specs` passed. That confirms ticket 01's statement that the hunk is not needed on x86_64. The patch stayed uncommitted, as in ticket 01, and the gate compares the worktree against its own baseline.
- On the Justfile's `PATH`, every gate tool resolved into `/nix/store`: gleam 1.19.0, erlang 29.1.2, rebar3 3.28.0, Python 3.14.10, Node 24.22.2, just 1.59.0, prek 0.5.10, lychee, markdownlint-cli2 0.24.0, helm 4.3.1, kubeconform, hadolint 2.14.0 and allium 3.6.1. The runner image ships its own `kind` (`/usr/local/bin`) and `kubectl` (`/usr/bin`, 1.37.2). Those are what a job without the `cluster` group finds. In the cluster jobs, kind 0.33.0, kubectl 1.36.3 and kwokctl 0.8.0 resolved into the store instead.
- **allium on x86_64-linux**, ticket 01's untested derivation, was built under the sandbox: an ELF x86-64 binary whose interpreter is the store's `glibc-2.44-57/lib/ld-linux-x86-64.so.2`. It printed 3.6.1 and ran both spec recipes.

### 4. The checker tests on the runner

`just test-checkers-all` **failed in all six checker jobs** in the same way: **792 passed, 2 failed, none skipped**, in 154 to 193 seconds.

- **The two failures**, in `scripts/checks/tests/test_ripsecrets_redacted.py`: `test_any_other_status_is_kept_and_its_output_suppressed` and `test_a_pinned_path_that_is_not_executable_is_refused`. Both fail with `PermissionError: [Errno 13] Permission denied: …/repository/.tools/bin/ripsecrets`.
- **The cause** is the test fixture, not the tool. The `worktree` fixture copies `.tools/bin/ripsecrets` with `shutil.copy2`, which keeps the source's mode, and both tests then write to the copy. Under Nix the source is a store file, `-r-xr-xr-x, owner root`, and the runner's user is uid 1001 ([run-2.txt](run-2.txt)), so the copy is read-only for that user. Under pixi the file is installed by `install-tools.sh` and is writable. Ticket 01 saw 779 tests pass with the patch because its container ran as root, which ignores the mode.
- **The fix** belongs in ticket 07 or 10. The fixture should copy without the mode (`shutil.copy`, or a `chmod` after the copy), or `.tools/bin` should hold writable copies. No tracked file was changed here.
- **None skipped.** The 13 installer tests that ticket 01 saw skipped on aarch64-linux run on x86_64, because `tools.txt` has a `linux-64` line. The runner collected 794 tests where ticket 01 counted 792; the two extra were not looked into.
- The checker-regressions job runs `test-checkers-selected`, a subset, in 10 minutes. With setup under 40 seconds and every group taking 154 to 193 seconds, the time fits. The two failures would fail that job whenever the ripsecrets group is selected.

### 5. The prototype image on linux/amd64

**It built and passed every check** in all three cluster jobs, by ticket 01's `image.sh` unchanged ([run-1.txt](run-1.txt), the "Cluster shape and amd64 image" section).

| Measure | Runs 1, 2, 3 |
| --- | --- |
| `docker pull` of `nixos/nix@sha256:b49cb33f…` (ubuntu took about 1 s) | 31.9, 30.5, 25.2 s |
| Build with `--no-cache`, base images pulled | 62, 58, 43 s |
| Build after an edit under `src/` | 10, 13, 10 s |
| The whole image step (pulls, four builds, checks) | 112, 109, 85 s |

- **Against the kind jobs' 20 minutes**, the cold image (pull plus `--no-cache` build) took at most **94 seconds**. The cluster job, with setup, the image, and a kind cluster up and down, took 171 to 214 seconds.
- **Every CI image build is cold.** The build stage is the Nix image, which cannot see the runner's `/nix`, so a store cache on the runner would not help it. The stage fetched the nixpkgs sources from github.com with no token, because the image's Nix has none.
- **The image**: amd64, user `10001:10001`. The runtime closure is 19 store paths, 212 MB under `/nix/store`: erlang-29.1.2 134.0 MB, glibc-2.44-57 35.5 MB, gcc-16.2.0-lib 10.4 MB, openssl-3.5.9 9.0 MB, ncurses 8.5 MB. No perl is in it. `docker image inspect .Size` reports 282.1 MB. The runner's Docker 28.0.4 reports an uncompressed size, so this figure cannot be compared with the 114.3 MB ticket 01 recorded on Docker Desktop.
- **The TLS proof**, run under `image-check`'s restrictions (`--read-only`, `--cap-drop=ALL`, `no-new-privileges`, a 16 MB `noexec` `/tmp`, and 256Mi memory and swap, as uid 10001): `tls_check: all 6 cases matched` on `otp_release 29, erts 17.1.1` and `OpenSSL 3.5.9 29 Sep 2026`, with `crypto:info_lib()` reporting 810549392. Through the entrypoint the descriptor limit was 65536. `/readyz` answered `ok`, `/metrics` had `knarr_startups_total 1`, and memory was 49.6 to 52.3 MiB of 256.
- `scripts/checks/image.py`, unchanged, stops at its conda check, `no conda-meta in /opt/knarr/.pixi/envs/runtime`, as on aarch64. That is tickets 03 and 09.

### 6. A kind cluster from the `cluster` group

This goes beyond the ticket and never blocked a job. `just cluster-up` and `just cluster-ready` ran with the `cluster` group's kind 0.33.0 and kubectl 1.36.3 on the Justfile's `PATH`. They created `kindest/node:v1.35.8`, and the node was Ready, in 36 to 39 seconds. `just cluster-down` deleted it. So ticket 01's "cluster tools not exercised" is now true only for kwokctl.

The step itself reports failure. After `cluster-ready` it ran a bare `kubectl version` whose `PATH` lacked the `cluster` group, so the runner's kubectl 1.37.2 answered without a kubeconfig. That command was the workflow's mistake, not a finding.

### 7. Renovate's nix manager

[renovate.sh](renovate.sh) follows bootstrap ticket 27's method: Renovate on the local platform, in Docker, against an export of this branch. **Renovate 44.239.1**, `ghcr.io/renovatebot/renovate:44.239.1@sha256:7dba1a3b916a2cf302ba0df458ddcc8fcbac3c92d0fe9882ac13ba0363de656b`, the newest release on the day. The scratch tree puts ticket 01's `flake.nix` and `flake.lock` at the root and the prototype `image/Dockerfile` as the root `Dockerfile`. It runs on the tracked `.github/renovate.json` with only the nix manager switched on, and `renovate-config-validator --strict` passes it. The nix manager's source was read at the tag 44.239.1: `lib/modules/manager/nix/{index,extract,artifacts}.ts`.

**Switching it on takes two settings.** The manager's default configuration is `enabled: false`. With `"nix"` added to `enabledManagers` alone, Renovate logs `nix is disabled` and `Manager explicitly enabled in "enabledManagers" config, but found no results`. It needs `"nix": {"enabled": true}` as well.

**What it extracts.** It reads the root inputs of `flake.lock`, beside any `flake.nix`, and nothing from `flake.nix`'s expressions. There are three dependencies, each with `datasource=git-refs`, `packageName=https://github.com/NixOS/nixpkgs` and `versioning=nixpkgs`. git-refs runs `git ls-remote` and needs no GitHub API.

| Input | Extracted as | Proposed on the current lock | Proposed on the stale copy |
| --- | --- | --- | --- |
| `nixpkgs` (follows `nixpkgs-unstable`) | `currentValue=nixpkgs-unstable`, `lockedVersion=2074cc67…` | nothing | nothing, though the lock was rolled back to `9ac0edc0…` |
| `nixpkgs-kubectl` (follows `nixos-26.05`) | `currentValue=nixos-26.05`, `lockedVersion=f1e5c356…` | nothing | nothing, though the lock was rolled back to `f7e80437…` |
| `nixpkgs-gleam` (pinned by revision in `flake.nix`) | `currentDigest=8edc0c72…`, no `currentValue` | **a `digest` update to `b19a27bf1d15d5f0883681f86663d015fb1b12d4`, in `renovate/nixpkgs-gleam-digest`** | the same |

- **A channel input moves only through lock file maintenance.** Even with a stale lock, Renovate proposed no update for either channel input.
- **The revision-pinned input is extracted, but tracks the wrong thing.** With no ref, Renovate follows the repository's default branch: `b19a27bf…` is nixpkgs `HEAD`, which is `master`. It is not a channel, and the transcript's `git ls-remote` shows it. Merging that proposal would replace the Gleam hold with an unreleased nixpkgs commit. The flake's `held.gleam` assertion should then fail evaluation; that is an inference, not run. Ticket 12 must switch this dependency off with a rule matching `matchManagers: ["nix"]` and `matchDepNames: ["nixpkgs-gleam"]`, as the configuration already switches off the kwok image.

**Lock file maintenance.** The local platform produces no lock-file branch: neither lookup's branch summary has one, and ticket 27's transcript lists no lock-file branch for pixi either. So nothing here shows Renovate itself moving `flake.lock`. What the manager would run is in `artifacts.ts`:

- for lock maintenance, `nix --extra-experimental-features 'nix-command flakes' flake update`;
- for an input update, `… flake update <input>`;
- in both cases with `--extra-access-tokens github.com=…` added when Renovate holds a GitHub token.

Those exact commands were run on the stale copy in ticket 01's `nixos/nix` 2.35.6 image, with no token:

- **Lock maintenance moved `flake.lock`.** `nixpkgs` went `9ac0edc0… → 2074cc67…` and `nixpkgs-kubectl` `f7e80437… → f1e5c356…`. `nixpkgs-gleam` stayed, because a revision in `flake.nix` is not something `nix flake update` moves.
- `flake update nixpkgs-kubectl` moved that input alone.
- After maintenance, the `default` group still evaluated for x86_64-linux, so every held-version assertion passed.
- On the current lock, maintenance would change nothing today: the locked revisions are the channel heads.

**What it needs to run that.** The command needs a `nix` binary. The default (slim) image has none on `PATH`. Its `install-tool nix 2.35.6`, which takes containerbase's `nix-prebuild` from GitHub releases, installed it anonymously in 1.2 to 1.9 seconds. The `-full` image (`ghcr.io/renovatebot/renovate:44.239.1-full@sha256:4731f8527b03404ab59c1af030a912b1451be7ad7f05f070d619e50603cd19e2`) ships `/usr/local/bin/nix`. The manager declares a `nix` tool constraint, and Renovate's default `binarySource=install` installs that tool on demand.

Two points are unverified. Without a `constraints.nix` setting, Renovate chooses the version through a github-releases lookup, and the dry run shows github-releases lookups refused without a token; whether that lookup would fail is an inference. Setting `"constraints": {"nix": "2.35.6"}` would avoid the question.

**The hosted Mend app.** Renovate's documentation for the hosted apps (`docs/usage/mend-hosted/` at 44.239.1) lists only where the app departs from the CLI. It says nothing about the nix manager or about which tools it installs. So the app has the CLI's defaults: the manager is off until `"nix": {"enabled": true}`. Its lock command is not one of the `allowedUnsafeExecutions` classes (`bazelModDeps`, `goGenerate`, `gradleWrapper`, `mise`), so the app has no switch that gates it. Whether the hosted app has a `nix` binary for the lock update is not stated in those documents. Ticket 44 sees it, once the app is active.

**The build stage's image.** The dockerfile manager extracts the `FROM` line in both forms, with different results:

- Digest alone, as the prototype has it (`nixos/nix@sha256:b49cb33f…`): extracted with a `currentDigest` and no version, and **nothing is ever proposed**.
- Tag plus digest (`nixos/nix:2.35.5@sha256:9305de53…` in the stale copy): it proposes **`patch → 2.35.6@sha256:b49cb33f…`** in `renovate/nixos-nix-2.x`.

`nixos/nix:2.35.6` is the same index digest ticket 01 pinned, so ticket 09 should write `FROM nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed`.

**Every pin it did not extract** ([renovate.txt](renovate.txt), part 6):

| Pin in `flake.nix` | Value |
| --- | --- |
| `held.erlang` | 29.1.2 |
| `held.openssl` | 3.5.9 |
| `held.gleam` | 1.19.0 |
| `held.rebar3` | 3.28.0 |
| `held.allium` | 3.6.1 |
| `held.kwok` | 0.8.0 |
| `held.kind` | 0.33.0 |
| `held.kubectlMinor` | 1.36 |
| the allium asset URL | `https://github.com/juxt/allium-tools/releases/download/v${held.allium}/allium-${asset.triple}.tar.gz` |
| allium sha256, x86_64-linux | `e00c99ae…e970` |
| allium sha256, aarch64-linux | `e5ce9639…3ff4` |
| allium sha256, aarch64-darwin | `ecfae02f…19eb` |

The revision-pinned input `nixpkgs-gleam` *was* extracted, but with the wrong target, as the table above shows. Nothing proposes a move of a held version. A held version moves when an input's revision moves, and the assertions refuse a lock that loses one. A custom regex manager could read `held.allium` against the allium-tools releases, but no bot can rehash its three assets, the same reason the kwok and KEDA pins move by hand today.

**What the anonymous lookups cost.** 16 dependencies were skipped with `github-token-required`: the 15 `github-tags` and 1 `github-releases` lookups of the github-actions manager, which are the workflows' action pins. Nothing in the nix or dockerfile managers was affected, and Docker Hub, ghcr.io, registry.k8s.io, hex.pm and conda-forge answered.

## What is left behind

- **Two Actions cache entries**, written by the measurement shortcut and scoped to `refs/heads/spike/nix-ci-05`. One is `knarr-nix-spike05-x86_64-linux-default-1d42eb97…`, 609,065,668 bytes. The other is `knarr-nix-spike05-x86_64-linux-cluster-1d42eb97…`, 765,719,311 bytes. Together they are 1.37 GB of the repository's 10 GB. No other branch can restore them. GitHub evicts an entry not accessed for 7 days. This ticket was not authorized to delete them; `gh cache delete <key>` does it.
- The images pulled on the Mac: the two Renovate images and `nixos/nix@sha256:b49cb33f…`, which ticket 01 had already pulled. Scratch is under the gitignored `ai_tmp/`.

## Not verified

- **Renovate moving `flake.lock` itself**, through a branch or a pull request. The local platform does not do it; the command it would run was run instead. The hosted app's behaviour is ticket 44's.
- **Whether Renovate without a token can choose a nix version** when no `constraints.nix` is set.
- **Magic Nix Cache, FlakeHub Cache, `actions/cache` on a store export, and the other installers** were read about, not run. With no cache already the fastest, a second measured pair would not have changed the choice.
- **grype on x86_64** (ticket 01's last x86_64 item). The `audit` group was not built on the runner; that is ticket 11's.
- **The main-only write** itself, which needs a push to `main`. The `save: false` job shows the behaviour every other ref would have.
- **cache.nixos.org or github.com being slow or down.** Every cold run here was quick; a bad day was not seen.
