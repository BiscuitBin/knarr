---
title: "Decision 0003: Tool manager"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_tool_manager]
requires: []
---

# Decision 0003: Tool manager

Adapted on 2026-10-07 from libpawdoku's [Decision 0011: Tool manager](https://github.com/steven-cutting/libpawdoku/blob/51d8b55ac4f769a6a4d66abacb9642a7d4062127/docs/decisions/0011-tool-manager.md) at commit `51d8b55`. There pixi owned the tools and rustup kept the compiler. Here pixi owns the compiler too.

## Context

knarr is a Gleam application on the BEAM (OVERVIEW §1, §8). Every build, test and image ticket needs one pin set for the Gleam compiler, Erlang/OTP, the repository tools and the local-cluster tools. libpawdoku showed that one pixi manifest and one hashed lockfile can replace several installers. It also showed which traps to test before anyone relies on them: a lock check that rewrites the lock, and a tool whose release cannot be installed the expected way.

conda-forge packages `gleam` and `erlang` and nearly every tool knarr needs. It does not package `rebar3`, which Gleam calls to build Erlang hex dependencies such as `prometheus`. It also lacks a few linters and cluster tools. Gleam has no flag that refuses to rewrite `manifest.toml`. Five questions had to be answered with evidence: TLS in conda-forge's OTP, the owner of the OTP version, the source of rebar3, a source for each missing tool, and how the read-only gate treats `manifest.toml`.

All evidence was gathered on 2026-10-07 with pixi 0.81.0. It ran natively on osx-arm64 and in `ghcr.io/prefix-dev/pixi:0.81.0` as linux/amd64. The scripts and transcripts are in [`.scratch/bootstrap/evidence/01/`](../../.scratch/bootstrap/evidence/01/README.md).

## Decision

pixi owns Gleam, Erlang/OTP and every repository and cluster tool that conda-forge carries, through one manifest, `pixi.toml`, and one lockfile, `pixi.lock`. knarr has no Python project, so the manifest is `pixi.toml`, not a `pyproject.toml` table. If 02 keeps a Python checker, it adds `python` to this manifest. It does not add a second installer.

### The manifest

Ticket 03 writes this file as `pixi.toml` and commits the `pixi.lock` it solves. The same file is in the evidence directory as [`pixi.toml.proposed`](../../.scratch/bootstrap/evidence/01/pixi.toml.proposed), and that copy is the one that was solved and installed.

```toml
[workspace]
name = "knarr"
channels = ["conda-forge"]
# CI is linux-64; the maintainer is osx-arm64. Another platform joins when a
# claim verifies it.
platforms = ["linux-64", "osx-arm64"]
requires-pixi = ">=0.81.0"

# The default feature: the compiler and every repository tool the gate runs.
# Exact pins throughout; pixi.lock holds the hashes.
[dependencies]
# conda-forge's gleam depends on no erlang; the otp feature supplies it.
gleam = "==1.19.0"
just = "==1.58.0"
prek = "==0.5.5"
typos = "==1.51.1"
lychee = "==0.24.2"
taplo = "==0.10.0"
markdownlint-cli2 = "==0.23.3"
actionlint = "==1.7.12"
shellcheck = "==0.11.0"

# The single owner of the OTP version: pixi, CI and both Dockerfile stages read
# this pin through pixi.lock.
[feature.otp.dependencies]
erlang = "==29.1.1"

# Local-cluster tooling, kept out of the default environment so the gate jobs
# do not install it.
[feature.cluster.dependencies]
kubernetes-kind = "==0.33.0"
kubernetes-client = "==1.34.3"
kustomize = "==5.8.2"
tilt = "==0.37.8"
kubernetes-helm = "==4.3.0"

# One solve group: every environment gets the same erlang build and the same
# openssl, so what the default environment proves about TLS holds for the
# runtime image.
[environments]
default = { features = ["otp"], solve-group = "default" }
cluster = { features = ["otp", "cluster"], solve-group = "default" }
runtime = { features = ["otp"], no-default-feature = true, solve-group = "default" }
```

There are three environments, and one solve group gives all three the same builds:

- `default` holds the compiler, OTP and the gate tools. The gate, CI and every contributor use it.
- `cluster` is `default` plus the local-cluster tools. Only the cluster lanes (10, 13, 15) install it.
- `runtime` is `erlang` and its dependencies, nothing else. The runtime image carries it.

### Pins (conda-forge, confirmed 2026-10-07)

Each version is conda-forge's newest on both platforms on that date ([search.txt](../../.scratch/bootstrap/evidence/01/search.txt)).

| Package | Binary | Pin | Environment |
| --- | --- | --- | --- |
| `gleam` | `gleam` | 1.19.0 | default |
| `erlang` | `erl`, `escript`, `erlc` | 29.1.1 (OTP 29, erts 17.1) | default, cluster, runtime |
| `just` | `just` | 1.58.0 | default |
| `prek` | `prek` | 0.5.5 | default |
| `typos` | `typos` | 1.51.1 | default |
| `lychee` | `lychee` | 0.24.2 | default |
| `taplo` | `taplo` | 0.10.0 | default |
| `markdownlint-cli2` | `markdownlint-cli2` | 0.23.3 | default |
| `actionlint` | `actionlint` | 1.7.12 | default |
| `shellcheck` | `shellcheck` | 0.11.0 | default |
| `kubernetes-kind` | `kind` | 0.33.0 | cluster |
| `kubernetes-client` | `kubectl` | 1.34.3 | cluster |
| `kustomize` | `kustomize` | 5.8.2 | cluster |
| `tilt` | `tilt` | 0.37.8 | cluster |
| `kubernetes-helm` | `helm` | 4.3.0 | cluster |

Two corrections to the ticket's premise:

- `helm` is on conda-forge as `kubernetes-helm` (`helm version` prints `v4.3.0+conda-forge`), so it moves into the manifest.
- conda-forge's `k3d` 3.2.0 is a noarch Python package that depends on `anywidget`, `ipywidgets` and `numpy`. It is not k3d.io's k3d, and the manifest must never name it.

### Escape hatch: checksum-pinned downloads into `.tools/bin`

A tool conda-forge does not carry is downloaded from its upstream release into the gitignored `.tools/bin`, and only if its sha256 matches a committed pin. Each pin line gives the name, version, platform, URL, sha256 and the archive member to extract. The lines below are the pin list [tools.sh](../../.scratch/bootstrap/evidence/01/tools.sh) printed and verified. 03 writes the list as `tools.txt` with the rebar3 lines, along with the recipe that installs it. Each other lane copies its own lines from here when it first uses the tool, so the foundation stays small.

| Tool | Version | Source | sha256 verified against | Added by |
| --- | --- | --- | --- | --- |
| rebar3 | 3.27.1 | `erlang/rebar3` release, one escript for both platforms | GitHub asset digest; the Sigstore bundle verifies against `erlang/rebar3/.github/workflows/publish.yml@refs/tags/3.27.1` | 03 |
| ripsecrets | 0.1.11 | `sirwart/ripsecrets` release, both platforms | nothing upstream (see below) | 03, if 02 keeps it |
| editorconfig-checker | 4.0.2 | release, linux-amd64 and darwin-all | GitHub asset digest and `checksums.txt` | 03, if 02 keeps it |
| hadolint | 2.15.1 | release, linux-x86_64 and macos-arm64 | GitHub asset digest and `checksums.sha256` | 13 |
| kubeconform | 0.8.0 | release, linux-amd64 and darwin-arm64 | GitHub asset digest and `CHECKSUMS` | 13 |
| kwokctl | 0.8.0 | `kubernetes-sigs/kwok` release | GitHub asset digest (no checksum file) | 13, following 10 |
| k3d | 5.9.0 | `k3d-io/k3d` release | GitHub asset digest and `checksums.txt` | 10, if it keeps k3d |
| setup-envtest | 0.25.2 | `kubernetes-sigs/controller-runtime` v0.25.2 release assets | GitHub asset digest (no checksum file) | 10, if it keeps envtest |
| Cluster Autoscaler | 1.35.2 or 1.36.1 | image only (see below) | registry digest | 15 |

```text
rebar3 3.27.1 linux-64 https://github.com/erlang/rebar3/releases/download/3.27.1/rebar3 708407032479514dd68b581a0b09a68b5a781fb6f53dcf4ad81ce4ef6b92940f rebar3
rebar3 3.27.1 osx-arm64 https://github.com/erlang/rebar3/releases/download/3.27.1/rebar3 708407032479514dd68b581a0b09a68b5a781fb6f53dcf4ad81ce4ef6b92940f rebar3
```

The other tools' lines, for both platforms, are at the end of [tools.txt](../../.scratch/bootstrap/evidence/01/tools.txt).

Notes on individual tools:

- **rebar3** has no checksum file. GitHub records an asset digest, and the release carries a Sigstore bundle. The pin is the sha256. Where `gh` is authenticated, the installer can also run `gh attestation verify` with the bundle. Without `gh` the sha256 alone is the check.
- **ripsecrets** v0.1.11 (2025-05-27) predates GitHub's asset digests and publishes no checksum file. Its sha256 is a first-use pin computed on 2026-10-07. It still comes from a release binary rather than a prek hook: the upstream hook is `language: rust`, which would build it with a Rust toolchain that knarr does not have.
- **Cluster Autoscaler** publishes no binaries, only images. The pins are by digest. CA's minor version must match the cluster's Kubernetes minor, so 10 picks the minor and 15 pins the digest:
  - `registry.k8s.io/autoscaling/cluster-autoscaler:v1.35.2@sha256:aac369dc283927a623deb1af54696efcc722ae79255aa07788422e495bab887d`
  - `registry.k8s.io/autoscaling/cluster-autoscaler:v1.36.1@sha256:461388d03eb5b55db58941ee7a81d9a619dd15302b01cbab9f5a9946715994b4`

  If 15 needs a binary instead, the fallback is a source build with conda-forge's `go` in the `cluster` feature.
- **Amended by ticket 13: the standalone `kwok` binary is not installed.** This bullet originally read "No tool is dropped. Each one in the ticket has a source above, or a conda-forge pin." Every tool ticket 01 investigated still has a source in its evidence. `tools.txt` installs only the tools a recipe uses, and the simulated cluster runs `kwokctl` with the kwok controller as an image.

### One owner per pin; prek never double-owns a tool

The hook configs never install their own copy of a tool. A tool that pixi or `.tools/bin` provides runs as a `repo: local`, `language: system` hook, or from a Justfile recipe. A remote hook pinned to a commit SHA is allowed only for a tool with no pixi or `.tools` source. Today there is none.

### The OTP owner (Verify 2)

The OTP version has one owner: the `erlang` pin in `pixi.toml`, resolved in `pixi.lock`.

- **pixi and contributors** get it from `pixi install --locked`.
- **CI** gets it from the same lock through setup-pixi with `locked: true`. No workflow names an OTP version.
- **Dockerfile build stage.** Amended by ticket 13: this bullet originally said the stage runs the `tools.txt` installer for rebar3. The stage installs the locked `default` environment, which supplies gleam and erlang. It fetches rebar3 into `.tools/bin` with Docker's checksum-verified `ADD`, then runs `gleam export erlang-shipment`. The pixi base has no curl, so this stage does not run the host `tools.txt` installer. `tools.txt` owns the rebar3 pin; the Dockerfile duplicates its linux-64 URL and sha256, and `test_build_fetches_rebar_without_curl_and_matches_tool_pin` in `scripts/checks/tests/test_image.py` rejects drift. A pin update changes both locations. The image build verifies the checksum; it does not perform the host installer's optional Sigstore verification. It also installs the locked `runtime` environment.
- **Dockerfile runtime stage** copies the `runtime` environment from the build stage to the same absolute prefix (conda environments are not relocatable), and puts its `bin` on `PATH`. No `ARG`, tag or base image names an OTP version. The one solve group makes the runtime environment's erlang and openssl the same builds that Verify 1 tested.

13 writes the Dockerfile. Its check that "the build and runtime stages use the same OTP major" runs `erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().'` in both stages and compares the output with `pixi.lock`.

If 13 picks an `erlang:<tag>` base image instead, the fallback is a gate check. It reads the tag from the Dockerfile's `ARG` and fails unless the tag's OTP major equals the erlang version in `pixi.lock`. That path loses the TLS evidence, because the base image brings its own OpenSSL build. 13 then reruns Verify 1 against that image.

### How recipes reach the environment

The Justfile exports `PATH` with these directories first, in this order:

1. `.pixi/envs/default/bin`
2. `.pixi/envs/cluster/bin`
3. `.pixi/envs/audit/bin`, added by ticket 27
4. `.tools/bin`

Every recipe then calls each tool by name. No recipe runs `pixi run` or `pixi shell`. This follows libpawdoku 0011, and the evidence adds three reasons:

- On a stale lock, `pixi run` silently re-solves and rewrites `pixi.lock`, then exits 0 ([solve.txt](../../.scratch/bootstrap/evidence/01/solve.txt), drift section). A gate recipe that wrote the lock would break the read-only gate.
- The environments have no `etc/conda/activate.d` scripts. Apart from `PATH` and pixi's own bookkeeping, activation sets only `PS1`. So a bare `PATH` export is equivalent to activation for every tool here, OTP and openssl included.
- It avoids nested activation. Recipes call recipes.

The cluster directory comes after the default one, so `gleam` and the other shared binaries always resolve from `default`. A cluster tool resolves only if the `cluster` environment is installed. Cluster recipes check for it first and print the install command if it is missing. Amended by ticket 27: the `audit` environment, which holds grype alone, follows the cluster one on the same terms, and `just image-scan` checks for it the same way ([Decision 0014](0014-dependency-updates-and-audit.md)).

### pixi commands

| Purpose | Command | Evidence |
| --- | --- | --- |
| Install (first run, CI) | `pixi install --locked`, which installs `default` only. Cluster lanes add `pixi install --locked -e cluster`. | It installs only `default`. On drift it exits 1 and leaves `pixi.lock` unchanged. |
| Lock check (gate) | `pixi lock --check --offline --dry-run` | On drift it exits 1 and leaves `pixi.lock` unchanged. On a fresh lock it passes offline. |
| Move transitives within the pins | `pixi update`, or `pixi update <package>`, then commit `pixi.lock` | |
| Move a pin | Edit its `==` line, run `pixi update <package>`, read the lockfile diff, commit both files | |

Plain `pixi lock --check` is not the lock check. On drift it exits 1, but it has already rewritten `pixi.lock`. The `--dry-run` flag is what keeps the lock unchanged, as libpawdoku found. `pixi install --frozen` is not the install command either: it installs a stale lock without complaint.

### pixi version

- **Locally:** pixi 0.81.0, with `requires-pixi = ">=0.81.0"` in the manifest as the floor.
- **In CI:** `prefix-dev/setup-pixi` with `pixi-version: v0.81.0` and `locked: true`. setup-pixi v0.11.0 (commit `9dabb60412d3d2d967a8d682f7ce01317af40514`) is the current release. It was published on 2026-10-06, one day before this record. libpawdoku runs v0.10.2. 05 pins one of the two by SHA and records which.

The version appears twice, once exact (CI) and once as a floor (the manifest), because nothing else can install pixi. Amended by ticket 27: it now appears in five places. They are the floor, setup-pixi's `pixi-version`, the setup action's cache key, the Dockerfile build stage's `FROM ghcr.io/prefix-dev/pixi:<version>@sha256:…`, and the README's prerequisite. `scripts/checks/tests/test_dependency_pins.py` fails unless all five agree, and Renovate moves them in one pull request ([Decision 0014](0014-dependency-updates-and-audit.md)).

### `manifest.toml` (Verify 5)

Gleam 1.19.0 cannot refuse to rewrite `manifest.toml`:

- No locked, frozen or offline option exists on `build`, `check`, `deps download`, `update`, `test` or `run`.
- No changelog up to v1.19.0 mentions `--frozen`, `--locked`, `--offline` or `--no-update`.
- Whenever `gleam.toml` and `manifest.toml` disagree, `gleam check`, `gleam build` and `gleam deps download` all rewrite `manifest.toml` and exit 0. The test covered four disagreements: a widened range, a dropped dependency, an added dependency and a stale `[requirements]` table. Agreeing files are left alone, including when the dev table is spelled `[dev-dependencies]`.

So the gate uses two checks:

1. **A pre-check that never writes**, before any gleam command. `taplo get -o json` extracts `gleam.toml`'s `[dependencies]` and its dev table, which gleam accepts as either `[dev_dependencies]` or `[dev-dependencies]`, and `manifest.toml`'s `[requirements]`. A small comparison then fails on any difference: [requirements_check.escript](../../.scratch/bootstrap/evidence/01/manifest/requirements_check.escript) normalises a bare version string to `{version = ...}`. It refused all four disagreements without writing. It accepted the agreeing pair under both spellings of the dev table. This is what makes drift fail "rather than being rewritten" (03).
2. **The backstop:** the snapshot runner from 02 aborts if any gate recipe changes a file. The gleam recipes also end with `git diff --exit-code manifest.toml`. Together they catch any rewrite the pre-check cannot predict, for example an edited `[packages]` entry.

## Verification

Each script exits non-zero on an unexpected result. [README](../../.scratch/bootstrap/evidence/01/README.md) gives the commands to rerun them.

**Search and solve.** [search.txt](../../.scratch/bootstrap/evidence/01/search.txt) shows all fifteen packages on both platforms at the pinned versions. It also shows the eight tools absent from conda-forge and the k3d mismatch. [solve.txt](../../.scratch/bootstrap/evidence/01/solve.txt) shows these results:

- Both platforms solve. `pixi install --locked --all` installs all three environments.
- Every environment on a platform has the same erlang and openssl build. On linux-64 that is `erlang 29.1.1 pl5321h8f2c242_0` and `openssl 3.6.5 h781a0a9_0`.
- No cluster binary is in `default`, and there is no `gleam` in `runtime`.
- Every tool runs through a `PATH` export alone.
- The drift table:

```text
pixi lock --check                            exit 1   pixi.lock REWRITTEN
pixi lock --check --offline --dry-run        exit 1   pixi.lock unchanged
pixi install --locked                        exit 1   pixi.lock unchanged
pixi install --frozen                        exit 0   pixi.lock unchanged
pixi run true                                exit 0   pixi.lock REWRITTEN
pixi run --frozen true                       exit 0   pixi.lock unchanged
```

**Verify 1, TLS.** [tls/tls_check.escript](../../.scratch/bootstrap/evidence/01/tls/tls_check.escript) runs an Erlang `ssl:listen` server and client from the same OTP. It uses two unrelated CAs and two server certificates, one with SAN `DNS:localhost, IP:127.0.0.1` and one with `DNS:localhost` only. The client passes `verify_peer`, an explicit `cacertfile` and `customize_hostname_check` with the https match fun. All six cases matched on osx-arm64 ([tls.txt](../../.scratch/bootstrap/evidence/01/tls.txt)). On linux-64 they matched with both the `default` and the `runtime` environment ([linux.txt](../../.scratch/bootstrap/evidence/01/linux.txt)):

```text
otp_release 29, erts 17.1
crypto:info_lib() [{<<"OpenSSL">>,810549376,<<"OpenSSL 3.6.5 29 Sep 2026">>}]
ssl:versions() ['tlsv1.3','tlsv1.2']
ok   right CA, by name localhost                  want ok         got {ok,[{protocol,'tlsv1.3'}, ...
ok   right CA, by IP tuple (IP SAN)               want ok         got {ok,[{protocol,'tlsv1.3'}, ...
ok   wrong CA (ca-b), by name                     want unknown_ca got {error,{tls_alert,{unknown_ca,...
ok   wrong CA (ca-b), by IP tuple                 want unknown_ca got {error,{tls_alert,{unknown_ca,...
ok   right CA, wrong name (SNI wrong.example)     want hostname   got {error,{tls_alert,{bad_certificate,... {hostname_check_failed, {requested,"wrong.example"}, ...
ok   right CA, IP tuple, cert has no IP SAN       want hostname   got {error,{tls_alert,{bad_certificate,... {hostname_check_failed,{requested,{127,0,0,1}}, ...
```

OTP 29 reports a failed hostname check as a `bad_certificate` alert that carries `{bad_cert, {hostname_check_failed, ...}}`, not as `handshake_failure`. S1 (14) should match on that. Connecting with an IP tuple checks the certificate's IP SAN, and it fails when the SAN is missing. That is the behaviour OVERVIEW §8 marks unverified for `KUBERNETES_SERVICE_HOST`. The local case now holds. S1 still has to prove it against a real apiserver certificate.

**Verify 2, OTP.** `erlang:system_info(otp_release)` prints `29` from the `default` environment on osx-arm64 ([solve.txt](../../.scratch/bootstrap/evidence/01/solve.txt)). It prints `29` from both `default` and `runtime` on linux-64 ([linux.txt](../../.scratch/bootstrap/evidence/01/linux.txt)).

**Verify 3, rebar3.** [rebar3/fetch.sh](../../.scratch/bootstrap/evidence/01/rebar3/fetch.sh) refuses an escript whose sha256 differs from the pin and verifies the Sigstore bundle. It also checks that the bundle refuses a copy with one byte appended. [rebar3/run.sh](../../.scratch/bootstrap/evidence/01/rebar3/run.sh) builds the [probe](../../.scratch/bootstrap/evidence/01/rebar3/probe/) on both platforms. The probe is a Gleam project that depends on `prometheus` 6.1.3 and `ddskerl` 0.4.3, and both have `build_tools = ["rebar3"]`. `===> Compiling prometheus` shows that rebar3 compiled them, and the probe's counter reads 2 after two increments. With rebar3 removed from `PATH`, the same build fails.

**Verify 4, missing tools.** [tools.txt](../../.scratch/bootstrap/evidence/01/tools.txt) has, for each tool, both platform assets downloaded and hashed. Each hash matches the GitHub asset digest and the publisher's checksum file where one exists. ripsecrets is the exception, as noted above. Each macOS binary runs and prints its version, except setup-envtest, which has no version flag and prints its usage. The autoscaler releases have zero assets, and the image digests are resolved.

**Verify 5, manifest.toml.** [manifest.txt](../../.scratch/bootstrap/evidence/01/manifest.txt) shows the flag survey, the rewrite table, the `git diff --exit-code` backstop catching a rewrite, and the pre-check refusing every disagreement without writing.

**Emulation caveat.** The linux-64 runs used Docker on Apple silicon, so they ran under Rosetta. There the BEAM JIT's dual-mapped code memory fails, and every node, including the official `erlang:29` image, dies at boot in `prim_tty`. [linux.sh](../../.scratch/bootstrap/evidence/01/linux.sh) records that control and sets `ERL_FLAGS="+JMsingle true"` only when it detects the Rosetta CPU. Native linux-64 (CI, production) needs no flag. The first native confirmation will come from 05's CI run.

## Consequences

Contributors need pixi (0.81.0 or later), git, curl and a POSIX shell. `just` comes from the environment. A fresh clone can run `pixi install --locked` and then `.pixi/envs/default/bin/just initialize`, or use a `just` installed some other way. 03 documents one of these paths.

The first run needs network for four things: the conda packages, the `.tools` downloads, hex packages for `manifest.toml`, and prek hook environments if any exist. Afterwards the gate is meant to run offline. The lock check passing with `--offline` is shown here. That gleam builds offline from its package cache is not, and 03 proves it as part of an offline `just check`.

The environments are large and per worktree. On osx-arm64, `default` is 521 MB and `cluster` 836 MB. `runtime` is 215 MB on osx-arm64 and 257 MB on linux-64, of which `lib/erlang` is 122 MB and conda's `perl` dependency of `erlang` is 56 MB. The runtime size matters for 13's "small image". 13 may prune the copied environment, for example `perl` and the OTP docs and sources. If it does, it reruns `tls_check.escript` in the pruned runtime image, because pruning breaks the lock's guarantee that what was tested is what ships. Amended by ticket 45: the Dockerfile's build stage prunes perl from the runtime environment, for its fixable CVEs ([Decision 0014](0014-dependency-updates-and-audit.md)). `just image-check` checks the prune and reruns `tls_check.escript` in the pruned image, in CI's kind smoke job on every change.

kubectl 1.34.3 is conda-forge's newest `kubernetes-client`. kubectl supports servers one minor version either side, 1.33 to 1.35. kind 0.33's default node image is v1.37.0, which is outside that range. So 10 picks a node image no newer than 1.35 (kind 0.33 publishes `kindest/node:v1.35.8`), or moves kubectl to `.tools/bin` with the reason recorded. kwok 0.8.0 ships cluster images for 1.35 (`v0.8.0-k8s.v1.35.5`), and CA has a 1.35.2 release. That makes 1.35 the one minor that kind, kwok, CA and kubectl all support today.

There are two pin mechanisms: `pixi.lock` for conda packages and `tools.txt` for upstream downloads. Every pin is still a hash, and one recipe owns each. Dependency automation (27) has to cover both, as well as `manifest.toml`. Amended by ticket 27: [Decision 0014](0014-dependency-updates-and-audit.md) covers `pixi.lock` and `manifest.toml` with Renovate. `tools.txt` stays a manual routine, because no bot can rehash a download. The Dockerfile's base images, which had a tag only, are pinned by the digest of their OCI index.

## What would reopen this

- **A tool reaches conda-forge.** If conda-forge packages rebar3, ripsecrets, editorconfig-checker, hadolint, kubeconform, kwokctl, k3d or setup-envtest, it moves from `tools.txt` into the manifest. That is a pin move, not a new decision.
- **conda-forge's kubectl falls behind the cluster.** If its `kubernetes-client` stays more than one minor behind the cluster version 10 picks, kubectl moves to `.tools/bin`.
- **The runtime environment is too large.** If 13 cannot meet its image-size target without pruning, and pruning cannot be verified, the runtime stage moves to an `erlang` base image. The fallback OTP check above then applies, and Verify 1 is rerun.
- **Gleam gains a frozen manifest mode.** A flag that refuses to rewrite `manifest.toml` would replace the pre-check.
- **pixi changes the lock-check behaviour.** If `pixi lock --check` stops writing on drift, or `--dry-run` starts writing, the lock-check command changes.
- **Native linux-64 disagrees.** If 05's first CI run gives a different TLS or rebar3 result from the emulated one, this record is reopened.

## Related pages

- [Project overview](../OVERVIEW.md), §1 and §8
- [Evidence for this record](../../.scratch/bootstrap/evidence/01/README.md)
- libpawdoku [Decision 0011: Tool manager](https://github.com/steven-cutting/libpawdoku/blob/51d8b55ac4f769a6a4d66abacb9642a7d4062127/docs/decisions/0011-tool-manager.md)
