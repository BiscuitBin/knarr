---
title: "Decision 0014: Dependency updates and audit"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_dependency_updates_and_audit]
requires: []
---

# Decision 0014: Dependency updates and audit

## Context

knarr pins every dependency by version and hash ([Decision 0003](0003-tool-manager.md)). Hex packages are pinned in `gleam.toml` and `manifest.toml`, and conda packages in `pixi.toml` and `pixi.lock`. Actions are pinned by commit SHA. The Dockerfile's base images, the local-cluster images and the pixi version are pinned too, and so are the checksum-pinned downloads in `tools.txt`. Nothing proposed moving any of them, and nothing reported a pinned release with a published advisory.

Ticket 27 is a spike in the shape of libpawdoku's S01. It chooses how updates are proposed and where advisories come from, shows each pin proposing an update or records its gap, and never pushes to `main` unreviewed. Two other tickets hand it work:

- **[Ticket 13](../../.scratch/bootstrap/issues/13-walking-skeleton.md):** `env-check` ignores a tool that stays installed after its `tools.txt` lines are removed.
- **[Decision 0012](0012-release-and-packaging.md):** the base-image digests and any re-lock, including ticket 38's arm64 one.

The maintainer settled two choices in the planning session on 2026-10-09:

- **Activation:** land the Renovate configuration held, prove each manager with a local, lookup-only run, and leave installing the app to a follow-up.
- **Network:** documentation and registry reads, the dry run's lookups, OSV.dev and hex.pm queries, a conda-forge relock, the branch push, and one `audit.yml` run. During the work the maintainer also authorized a read-only `gh` token for Renovate's github.com lookups, installing grype, its vulnerability database, and reading the base image from Docker Hub.

The evidence was gathered on 2026-10-09 and 2026-10-10 (UTC) on an Apple M5 Pro (Darwin arm64) with OrbStack 2.2.3, whose Docker engine is 29.4.0 (linux/arm64) with buildx 0.33.0. It used pixi 0.81.0 and Renovate 44.149.0, in an image pinned by digest. The real knarr image was scanned in the branch's `audit.yml` run. The scripts and transcripts are in [`.scratch/bootstrap/evidence/27/`](../../.scratch/bootstrap/evidence/27/README.md). Nothing installed an app, changed a repository setting, opened an issue or a pull request, or pushed an image.

## Decision

### Renovate, landed held

- **Renovate, through the Mend-hosted app, not Dependabot.** Dependabot cannot cover three of knarr's pins ([sources.txt](../../.scratch/bootstrap/evidence/27/sources.txt)):
  - **Hex:** its Hex support is `mix`, not Gleam.
  - **Conda:** its Conda support "does not include … lock file updates", so it cannot move `pixi.lock`.
  - **Images:** nothing in it can read the image strings in `scripts/checks/cluster.py`.

  Renovate has a manager for each: gleam (hex, with `manifest.toml`), pixi (including the `[feature.*]` tables), github-actions (including `.github/actions/**`), dockerfile, and regex custom managers for the rest. A self-hosted Renovate would need a token stored as a repository secret; the hosted app needs none.
- **One configuration file, [`.github/renovate.json`](../../.github/renovate.json).** It is plain JSON, so the gate's Python can read it, and every rule and custom manager says why it exists in a `description`. It extends `config:recommended`, `docker:pinDigests`, `helpers:pinGitHubActionDigests` and `:dependencyDashboardApproval`. It enables only five managers: `gleam`, `pixi`, `github-actions`, `dockerfile` and `custom.regex`. It ignores `.scratch/**`, which holds a probe `gleam.toml` from ticket 01 and ticket 28's overlay.
- **Nothing merges without the maintainer's review.** `automerge` and `platformAutomerge` are `false`, and no rule turns either on. Branch protection already requires `check` on `main`. Renovate runs weekly, early on Monday (UTC), with lock-file maintenance on.
- **The landing is held.** `:dependencyDashboardApproval` holds every update until the maintainer ticks it on the Dependency Dashboard, and no app is installed. [Ticket 44](../../.scratch/bootstrap/issues/44-renovate-activation.md) installs the Mend app on knarr only (**authorization required**), proves one pull request per manager, and removes that preset. Three holds outlive it:
  - every conda pin and `pixi.lock`'s maintenance, because the hosted relock is unproven;
  - the pixi group;
  - the local-cluster group.

  Renovate's vulnerability-fix pull requests skip dashboard approval by default (`"dependencyDashboardApproval" : false` under `vulnerabilityAlerts`). Once the app is live, a security fix can therefore open unasked. It still never merges itself.
- **Four groups.**
  - **Hex packages,** with `rangeStrategy: update-lockfile`: an in-range update moves `manifest.toml` alone.
  - **GitHub Actions:** the SHAs and their version comments, and the runner labels, in one pull request per update kind, majors apart: Renovate's `separateMajorMinor` puts the runner labels' 24.04 → 26.04 in `renovate/major-github-actions`. The labels' dependency name is `ubuntu`, like the runtime base's, so without this rule they would share its branch.
  - **pixi:** the version in all five places.
  - **Local cluster:** the kind node, kwok's four control-plane images, and kind, kubectl and kustomize. The Kubernetes images are capped at 1.35, because kubectl 1.34 reaches 1.35 at most and the vendored schemas are 1.35. `registry.k8s.io/etcd` is capped at 3.6 beside them, because etcd 3.7 is not what kwok 0.8 and Kubernetes 1.35 were paired with. The kwok controller image, `registry.k8s.io/kwok/kwok`, is switched off in Renovate and moves by hand (below).

### Every pin, and what covers it

Counted from the files by [inventory.txt](../../.scratch/bootstrap/evidence/27/inventory.txt), and extracted by Renovate in [renovate.txt](../../.scratch/bootstrap/evidence/27/renovate.txt):

| Pin | Where | Count | Covered by |
| --- | --- | --- | --- |
| Hex package ranges | `gleam.toml` | 11 | gleam manager, group hex packages |
| Hex package lock | `manifest.toml` | 38 | gleam manager: `update-lockfile` and lock-file maintenance, with Renovate running `gleam` to rewrite the lock |
| Conda pins | `pixi.toml` | 19 | pixi manager, held |
| Conda lock | `pixi.lock` | 106 | pixi lock-file maintenance, held; the hosted relock is unproven (44) |
| Action SHAs | the workflows and the setup action | 7 | github-actions manager, group GitHub Actions |
| Runner labels | the workflows | 7 | github-actions manager (`github-runners` datasource), same group |
| prek remote hook revisions | the two hook configs | 0 | Nothing to cover: every hook is `local` or `builtin` (Decision 0003, "One owner per pin") |
| Base image digests | the Dockerfile's `FROM` lines | 2 | dockerfile manager and `docker:pinDigests` |
| Cluster image digests | `scripts/checks/cluster.py` | 5 | regex manager (docker), group local cluster, held |
| kwok image digest | `scripts/checks/cluster.py` | 1 | **Gap**, manual, with kwokctl's `tools.txt` lines; switched off in Renovate |
| The pixi version | five places, below | 5 | dockerfile manager for the build stage, regex manager for the other four, group pixi, held |
| `tools.txt` sha256 | `tools.txt` | 14 | **Gap**, manual (below) |
| rebar3's `ADD --checksum` | the Dockerfile | 1 | **Gap**, manual, with `tools.txt`'s rebar3 line |
| Kubernetes schema sha256 | `scripts/schemas/kubernetes/sources.json` | 3 | **Gap**, manual |
| Vendored skill hashes | `skills-lock.json` | 7 | **Gap**, manual |

Three corrections to the ticket's list:

- **No prek hook SHA exists.** Every hook is local or builtin.
- **The base image had a tag and no digest.** Ticket 27 adds the digest.
- **The kind node image is one of six.** It sits in `cluster.py` with five kwok images.

Ticket 27 changed four things so that the managers read every pin:

- **`gleam.toml` spells its dev table `[dev-dependencies]`.** Renovate's gleam manager reads only that spelling: with `[dev_dependencies]` it extracted 6 of the 11 packages. Gleam and `manifest_check.py` accept both, and `manifest.toml` did not change.
- **Both base images are pinned by the digest of their OCI index.** They are `ghcr.io/prefix-dev/pixi:0.81.0@sha256:788ae451…` and `ubuntu:24.04@sha256:534baea6…`. Each index has a linux/amd64 and a linux/arm64 manifest ([digests.txt](../../.scratch/bootstrap/evidence/27/digests.txt)), so ticket 38's arm64 build pins the same lines. hadolint stays clean.
- **setup-pixi's `pixi-version` input is read by the regex manager.** Renovate reads that input natively, as `prefix-dev/pixi` on GitHub releases with conda versioning. From 0.80.0, with 0.81.0 released, it found the releases and proposed nothing ([renovate.txt](../../.scratch/bootstrap/evidence/27/renovate.txt), part 4). A rule switches the native reading off. The regex manager now reads all four places outside the Dockerfile — the floor, the input, the cache key and the README's prerequisite — against the pixi image's tags, the same tags the build stage's `FROM` uses. The group cannot then propose a version in some places that the image does not have yet.
- **[`test_dependency_pins.py`](../../scripts/checks/tests/test_dependency_pins.py) holds the shapes in the gate.** It checks:
  - every `FROM` carries a digest;
  - every remote action is a full SHA with a version comment, which Renovate needs;
  - each regex manager, translated from RE2, matches every pin it covers;
  - the five pixi versions agree;
  - the dev table keeps its spelling, and nothing automerges;
  - etcd stays on 3.6, and the kwok image is the only local-cluster dependency switched off.

  It also checks which holds and groups each kind of dependency ends up with, using a small model of `packageRules`. Lookup mode stops before branches, so Renovate itself never shows a hold here.

### The manual routines for the gaps

- **`tools.txt` and rebar3's `ADD`.** No bot recomputes a download's sha256. To move a tool, replace both platforms' lines with the new URL and sha256 from the release's checksum file or asset digest, and move the Dockerfile's `ADD` with rebar3 (`test_image.py` enforces that). Then rerun `just initialize`. To drop a tool, delete its lines: `just env-check` now fails, and `just initialize` removes the binary and its record. A binary that `install-tools.sh` never installed is left alone (ticket 13's hand-back).
- **The kwok image** is switched off in Renovate, because no bot can rehash kwokctl's `tools.txt` lines. Move its tag and digest in `scripts/checks/cluster.py` by hand, together with those lines.
- **The Kubernetes schemas and `skills-lock.json`** are re-vendored through their existing procedures: `scripts/schemas/kubernetes/sources.json`, and [the agent contract](../reference/agent-contract.md).
- **A base image while the app is not installed.** Nothing proposes the new digest. When the image scan flags a fixed vulnerability in the base and the tag names a new index, read that index's digest with `docker buildx imagetools inspect`, as `digests.sh` does, and move the `FROM` line by hand.

### Advisory sources

- **Hex packages and OTP: OSV.dev, through `just hex-audit`.** [`scripts/checks/hex_audit.py`](../../scripts/checks/hex_audit.py) sends OSV one `querybatch` request. It asks about every hex package `manifest.toml` locks, in OSV's `Hex` ecosystem. It also asks about the `erlang` pin, as the `OTP-<version>` tag of `github.com/erlang/otp` in OSV's `GIT` ecosystem, where OSV records the OTP advisories.
  - **Exit status:** 0 when there is no advisory, 1 on advisories, and 2 when it cannot decide.
  - **It fails closed:** an answer of the wrong length, one with a further page, a truncated response, and a manifest whose packages list has the wrong shape are each "cannot decide", never a pass.
  - **Today:** no advisory for 38 hex packages or OTP 29.1.1. The control `plug 1.3.0` is flagged with GHSA-2q6v-32mr-8p8x, and OTP 27.3.2 with CVE-2025-32433 ([osv-probe.txt](../../.scratch/bootstrap/evidence/27/osv-probe.txt)).
  - **Build:** the script uses only the standard library and injects the network. Its tests run on answers copied from the live API.

  osv-scanner is not used, because it reads `mix.lock` but not Gleam's `manifest.toml`. Renovate's OSV alerts are experimental, cover direct dependencies only, and run only once the app does; `osvVulnerabilityAlerts` is on for that day. One residual risk: OSV matches an OTP tag against the tags it enumerated for each record, so an open advisory may miss a tag cut after OSV last processed it.
- **GitHub's Dependabot alerts,** on since ticket 04. The dependency graph reads the workflow files and lists no Hex, Conda or Docker ecosystem, so for knarr the alerts cover the actions only. Renovate also reads them once the app is installed.
- **The conda-forge packages have no authoritative advisory source.** OSV has no conda ecosystem, and Renovate's OSV alerts skip the conda datasource. grype matches conda records against NVD's CPEs, but only when it scans them as a directory, and no job does that yet: the image scan below does not read them, and [ticket 45](../../.scratch/bootstrap/issues/45-scan-image-runtime-environment.md) adds the directory scan. Until then the runtime environment the image ships is scanned by no job: erlang, the conda-forge openssl the BEAM links, perl 5.32.1 and zlib. OTP itself is checked through OSV's `GIT` records, and the weekly proposals keep the rest fresh once the app is live. Amended by ticket 45: the image's conda records are now scanned, as a directory copied out of the image, by `just runtime-scan` in the image-scan job (below).
- **The `tools.txt` downloads have no advisory source.** Nothing matches a checksum-pinned download against advisories, and no bot moves them (the manual routine above).
- **The image: grype, through `just image-scan`.** grype 0.120.1 comes from a pixi `audit` environment that holds only grype; the relock added grype's two records and changed nothing else. `--only-fixed --fail-on high` fails on a high or critical vulnerability that has a fix. In `audit.yml` it scans the linux/amd64 image that `just image-build` builds, and the job is not required.
  - **OS packages only:** grype runs syft to catalogue packages, and syft selects 34 package catalogers for an image source and 57 for a directory. `conda-meta-cataloger` runs only on a directory, and grype 0.120.1 has no flag or configuration setting that selects catalogers. The same runtime-environment records give 0 conda matches as an image, and 7 conda matches, 4 with a fix, as a directory ([grype-probe.txt](../../.scratch/bootstrap/evidence/27/grype-probe.txt), part 3). So the scan reads the image's `deb` packages and not its runtime environment. Amended by ticket 45: [`scripts/checks/runtime_scan.py`](../../scripts/checks/runtime_scan.py), through `just runtime-scan`, runs `docker create` on the image and `docker cp` of `/opt/knarr/.pixi/envs/runtime` into `build/runtime-scan/`, then `grype -vv dir:` over the copy with the same `--only-fixed --fail-on high`. It exits 0 when nothing qualifies and 2 on a finding, as `just image-scan` does. It exits 1 when it cannot decide: when grype's log shows `conda-meta-cataloger` catalogued no package, whatever grype returned, or on a docker or grype error. In `audit.yml` it is a step of the image-scan job, after the image scan, with an `if:` that runs it unless the run is cancelled and only when the `just image-build` step succeeded, so it runs when the image scan is red but not without an image.
  - **The runtime environment, scanned as a directory,** matches fixed vulnerabilities in conda-forge's perl 5.32.1 through NVD CPEs, and those four are all of part 3's matches with a fix: CVE-2022-48522 (Critical, fixed in 5.35.5), CVE-2023-31484 and CVE-2023-31486 (High, fixed in 5.38.0), and CVE-2023-47038 (High). erlang's conda-forge build pins that perl (its build string is `pl5321`), and Decision 0003 already contemplated pruning perl from the runtime image. Ticket 45 scans the environment in `audit.yml` and decides perl. Amended by ticket 45: perl is pruned. The Dockerfile's build stage runs [`scripts/prune_runtime.py`](../../scripts/prune_runtime.py), which deletes every file perl's conda-meta record lists and then the record, before the runtime stage copies the environment. Nothing in erlang's `lib/erlang` or `bin` has a perl shebang. openssl's `bin/c_rehash` is a `#!/usr/bin/env perl` script, so it now finds the base image's own perl-base, which the image scan reads; nothing runs it. `just image-check`, in CI's kind smoke job, checks that the image has no `bin/perl` and no perl record, and reruns Decision 0003's `tls_check.escript` with the pruned environment's own erlang and openssl.
  - **Not Trivy:** GHSA-69fq-xp46-6x23 (CVE-2026-33634) records a malicious Trivy release in March 2026, with 76 of 77 `trivy-action` tags force-pushed.
  - **Not osv-scanner:** it is on conda-forge too, but OSV has no conda ecosystem, so it would not close the conda gap, and grype already reads the OS packages.
- **The first finding: the pinned base already has a High with a fix.** CVE-2026-84782 is in `libssl3t64` 3.0.13-0ubuntu3.15 and fixed in 3.0.13-0ubuntu3.16 ([grype-probe.txt](../../.scratch/bootstrap/evidence/27/grype-probe.txt)). The branch's `audit.yml` run found exactly that on the real knarr image: the same six `libssl3t64` rows, all `deb` ([ci-audit.txt](../../.scratch/bootstrap/evidence/27/ci-audit.txt)). That is Ubuntu's libssl, not the BEAM's: erlang links conda-forge's openssl from the runtime environment (Decision 0003).
  - **No digest update exists yet.** The `ubuntu:24.04` tag still names the pinned index ([digests.txt](../../.scratch/bootstrap/evidence/27/digests.txt)), and HEAD's only proposal for the base is the 24.04 → 26.04 major ([renovate.txt](../../.scratch/bootstrap/evidence/27/renovate.txt)).
  - **The image-scan job stays red** until Ubuntu republishes noble with `libssl3t64` 3.0.13-0ubuntu3.16 or later. Then Renovate proposes the digest once ticket 44 activates it, or the maintainer moves the `FROM` line by hand (the manual routine above).
  - **While it is red,** the job's table still lists every finding, so a new one is visible in the run. That is the audit working, so `--fail-on` stays at high.

### Re-locks, ticket 38's arm64 among them

A re-lock is an ordinary pull request:

1. Edit `pixi.toml`; for arm64, add `linux-aarch64` to `platforms`.
2. Run `pixi lock`, which needs network.
3. Read the `pixi.lock` diff. Adding grype here added 24 lines and removed none, so anything else in a diff is a question for the pull request.
4. Run `just lock-check`, then `just env-check`. The second may need `pixi install --locked` first.
5. Run the gate.

Until ticket 44 shows the hosted app relocking, a Renovate pixi proposal takes the same route by hand on the bot's branch.

## Findings

Every row but the last was observed by `run-all.sh`'s scripts, against the commit each transcript's `revision:` line names; `sources.txt` carries only its date. The last is the branch's `audit.yml` run on GitHub, read back with `gh` by `ci-audit.sh`, which `run-all.sh` does not run.

| Transcript | What it shows | Verdict |
| --- | --- | --- |
| [inventory.txt](../../.scratch/bootstrap/evidence/27/inventory.txt) | 226 pins in 15 kinds, counted from the files; 26 in the five manual kinds, the kwok image digest among them; no remote prek hook among 4 hook repositories | Every pin has a manager or a recorded gap |
| [renovate.txt](../../.scratch/bootstrap/evidence/27/renovate.txt) | The configuration validates with `--strict`. HEAD extracts 57 dependencies in 10 files across five managers, with 18 proposals pending today in 8 branches; etcd's is 3.6.10-0 → 3.6.15-0. Two are switched off, both skipped as `disabled`: setup-pixi's `pixi-version` input and the kwok image. A stale copy, with real older pins rolled back, has 30 proposals in 11 branches and shows each of 9 expected proposals in its group's branch. The native `pixi-version` reading proposes nothing. No dependency skipped but the two switched off, no etcd proposal past 3.6, no digest-pin proposal, and the token in no log | Each covered pin is shown proposing an update |
| [osv-probe.txt](../../.scratch/bootstrap/evidence/27/osv-probe.txt) | `hex_audit.py`: exit 0 on the committed tree, exit 1 naming GHSA-2q6v-32mr-8p8x for `plug 1.3.0` and CVE-2025-32433 for OTP 27.3.2; OSV records CVE-2025-32433 as a `GIT` range on `github.com/erlang/otp` | The hex and OTP source works, and the controls fail it |
| [grype-probe.txt](../../.scratch/bootstrap/evidence/27/grype-probe.txt) | grype 0.120.1 from the audit environment on the pinned ubuntu:24.04, amd64: 75 matches, 6 with a fix, 1 of them High (`libssl3t64`); the recipe's flags exit 2. Part 3, the runtime environment's records: 8 of the 13 packages it locks for linux-64 have a record on this host, and the other 5 are not scanned. As an image, 34 catalogers, conda-meta not run, 0 conda matches; as a directory, 57 catalogers, conda-meta 8 packages, 7 conda matches, 4 with a fix. All four are perl 5.32.1 through NVD CPEs: CVE-2022-48522 (Critical), CVE-2023-31484, CVE-2023-31486 and CVE-2023-47038 (High) | The scan works, and its first finding is in the base. It does not read the image's conda records (ticket 45) |
| [digests.txt](../../.scratch/bootstrap/evidence/27/digests.txt) | Both pinned digests are OCI indexes with amd64 and arm64 manifests, and both tags still name them | Confirmed; no ubuntu digest update exists yet |
| [sources.txt](../../.scratch/bootstrap/evidence/27/sources.txt) | Twenty vendor pages fetched with their sha256; 37 cited phrases found and 3 expected absences; conda-forge carries grype 0.120.1, trivy 0.75.0 and osv-scanner 2.6.0 | Public-source research, as of 2026-10-09 |
| [ci-audit.txt](../../.scratch/bootstrap/evidence/27/ci-audit.txt) | Run 38015514089 of `audit.yml`, dispatched on the branch at `d5c7178` on 2026-10-10. Hex advisories: success, no advisory for 38 hex packages or Erlang/OTP 29.1.1. Image scan: failure, exit 2, on the real linux/amd64 knarr image, with the six `libssl3t64` 3.0.13-0ubuntu3.15 rows, all `deb`, and CVE-2026-84782 High, fixed in 3.0.13-0ubuntu3.16. External links: failure, from three keda.sh URLs refusing connections; those links were already in the docs, and that job reports remote availability, so it is unrelated to this ticket | Both new jobs run in CI; the image scan's finding is exactly the base image's |

## Sources

Public-source research as of 2026-10-09; [sources.txt](../../.scratch/bootstrap/evidence/27/sources.txt) records each page's sha256 and each phrase.

- Renovate managers: [gleam](https://docs.renovatebot.com/modules/manager/gleam/) (only `dev-dependencies`; the `gleam` program rewrites `manifest.toml`), [pixi](https://docs.renovatebot.com/modules/manager/pixi/) (feature tables; the relock is an unsafe execution, and without it `pixi.lock` is left unchanged), [github-actions](https://docs.renovatebot.com/modules/manager/github-actions/) (setup-pixi's input; a bare SHA is skipped), [regex](https://docs.renovatebot.com/modules/manager/regex/) (RE2, per file), [pre-commit](https://docs.renovatebot.com/modules/manager/pre-commit/) (beta, opt-in), and the [github-runners](https://docs.renovatebot.com/modules/datasource/github-runners/) datasource.
- Renovate options: [configuration options](https://docs.renovatebot.com/configuration-options/) (`update-lockfile` for gleam; OSV alerts for hex and direct dependencies only; `vulnerabilityAlerts` skips dashboard approval), [`allowedUnsafeExecutions`](https://docs.renovatebot.com/self-hosted-configuration/) (pixi is a value), the [Mend-hosted app](https://docs.renovatebot.com/mend-hosted/hosted-apps-config/) (which does not document it), the app's [permissions](https://docs.renovatebot.com/security-and-permissions/), the [local platform](https://docs.renovatebot.com/modules/platform/local/) (experimental, lookup only, no branches), and the [default](https://docs.renovatebot.com/presets-default/), [docker](https://docs.renovatebot.com/presets-docker/) and [helpers](https://docs.renovatebot.com/presets-helpers/) presets.
- Dependabot: [supported ecosystems](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories) (Hex is `mix`; no conda lock updates) and the [dependency graph](https://docs.github.com/en/code-security/reference/supply-chain-security/dependency-graph-supported-package-ecosystems) (Actions workflows).
- OSV: [querybatch](https://google.github.io/osv.dev/post-v1-querybatch/) (per-query pages), the [schema](https://ossf.github.io/osv-schema/) (`Hex`; enumerated `GIT` tags), [osv-scanner's lockfiles](https://google.github.io/osv-scanner/supported-languages-and-lockfiles/) (`mix.lock`, nothing Gleam), and [CVE-2026-33634](https://osv.dev/vulnerability/CVE-2026-33634) (Trivy).

## Verification

Each script exits non-zero on an unexpected result and writes only to the work directory it is given, apart from the probe image `grype-probe.sh` builds for part 3 and removes; every container a script starts is removed. `ci-audit.sh` only reads, through `gh`. The [evidence README](../../.scratch/bootstrap/evidence/27/README.md) gives the command that reruns everything.

**The gate.** `test_dependency_pins.py` has 30 tests over the committed files. `test_hex_audit.py` has 28 tests on copies of OSV's answers, failing closed on malformed answers, a truncated response and a manifest whose packages list has the wrong shape. `test_env_check.py` and `test_install_tools.py` gained the removed-pin cases, and `test_env_check.py` also a hidden file and an unreadable stamp among the stamps. The tests came before the code and were watched failing. The guards over files that already complied, such as the action pins, show their rule rejecting bad input in cases of their own. `just check` passes with them.

**Renovate ([renovate.txt](../../.scratch/bootstrap/evidence/27/renovate.txt)).** The stale copy's expected proposals:

```text
-- each manager proposes from the stale copy
  yes  gleam          birdie                   gleam.toml                         renovate/hex-packages
  yes  pixi           just                     pixi.toml                          renovate/just-1.x
  yes  github-actions actions/checkout         .github/workflows/ci.yml           renovate/github-actions
  yes  dockerfile     ubuntu                   Dockerfile                         digest
  yes  regex          kindest/node             scripts/checks/cluster.py          renovate/local-cluster
  yes  dockerfile     ghcr.io/prefix-dev/pixi  Dockerfile                         renovate/pixi
  yes  regex          ghcr.io/prefix-dev/pixi  pixi.toml                          renovate/pixi
  yes  regex          ghcr.io/prefix-dev/pixi  .github/actions/setup/action.yml   renovate/pixi
  yes  regex          ghcr.io/prefix-dev/pixi  README.md                          renovate/pixi
```

**Not run here.** These are ticket 44's proof:

- installing the Mend app;
- a real Renovate pull request, and the Dependency Dashboard;
- the holds as Renovate applies them, since lookup mode stops before branches;
- the hosted relock of `pixi.lock`, and the hosted rewrite of `manifest.toml`;
- Renovate's OSV and Dependabot alerts.

**Run in CI.** The real knarr image builds only in CI, on amd64 (Decision 0012), so its scan is the branch's `audit.yml` run ([ci-audit.txt](../../.scratch/bootstrap/evidence/27/ci-audit.txt)): the hex advisories job passed, and the image scan failed on the base image's `libssl3t64` finding.

## Consequences

- **Ticket 44 activates Renovate,** each step authorized by the maintainer:
  1. install the app;
  2. prove each manager with one approved pull request, including whether the hosted app rewrites `manifest.toml` and relocks `pixi.lock` (relocking by hand on the bot's branch is the passing path if it does not);
  3. remove `:dependencyDashboardApproval`;
  4. write the maintainer's how-to.

  No ubuntu digest update exists to show on the first dashboard yet. It appears once Ubuntu republishes noble with `libssl3t64` 3.0.13-0ubuntu3.16 or later, and it clears the image scan's finding.
- **Every pin change arrives as a pull request the maintainer reviews.** The gate fails one that leaves a pin in a shape Renovate cannot read.
- **`audit.yml` has three jobs, none required:** links, hex advisories and the image scan. The image scan is red until Ubuntu republishes noble with the fixed `libssl3t64` and the `FROM` line moves, through Renovate once ticket 44 activates it or by hand (the manual routine above). While it is red, its table still lists every finding, so a new one is visible in the run. Once it is green, it still says nothing of the runtime environment, which it does not read, until ticket 45 lands. Amended by ticket 45: the image-scan job also runs `just runtime-scan`, and that step runs when the image scan is red.
- **[Ticket 45](../../.scratch/bootstrap/issues/45-scan-image-runtime-environment.md) scans the runtime environment** the image ships, which the image scan does not read. It also decides perl: pruned from the runtime image with Decision 0003's TLS check rerun, or accepted with a dated, documented grype ignore. Amended by ticket 45: done, and perl is pruned, with the TLS check in `just image-check`.
- **Ticket 38's arm64 lane** re-locks through the route above.
- **The network lists** in `AGENTS.md` and `CONTRIBUTING.md` name `just hex-audit`, `just image-scan` and `just audit-install`. Amended by ticket 45: and `just runtime-scan`.

## What would reopen this

- **A remote prek hook appears.** Pin it as `rev: <40 hex> # frozen: vX.Y.Z`, widen `test_hook_configs.py`'s pattern to accept that comment, and enable Renovate's `pre-commit` manager.
- **Ticket 44 shows the hosted app relocking `pixi.lock`.** Drop the pixi manager's own hold.
- **conda-forge gains an advisory source,** or OSV a conda ecosystem. Add it to the audit.
- **grype or syft gains a way to catalogue conda records in an image.** The image scan then reads the runtime environment itself, and ticket 45's directory scan can retire.
- **conda-forge's erlang stops depending on perl.** The Dockerfile's prune step and `just image-check`'s perl check can then retire (ticket 45).
- **Renovate's native `pixi-version` reading starts proposing.** [renovate.txt](../../.scratch/bootstrap/evidence/27/renovate.txt) part 4 says so when it does; drop the rule and the fourth match string.
- **Renovate's OSV alerts leave experimental status and cover locked dependencies.** `just hex-audit` may then retire.

## Related pages

- [Decision 0003: Tool manager](0003-tool-manager.md), for the pins and the escape hatch
- [Decision 0012: Release and packaging](0012-release-and-packaging.md), for the image and arm64
- [Evidence for this record](../../.scratch/bootstrap/evidence/27/README.md)
- [Ticket 27](../../.scratch/bootstrap/issues/27-spike-dependency-updates-and-audit.md), with the hand-back notes, and tickets [44](../../.scratch/bootstrap/issues/44-renovate-activation.md) and [45](../../.scratch/bootstrap/issues/45-scan-image-runtime-environment.md)
