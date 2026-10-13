# 45: Scan the image's runtime environment

**Context:** [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) scans the knarr image with grype, through `just image-scan`, and that scan reads the image's OS (`deb`) packages only. grype runs syft to catalogue packages, and syft selects 34 package catalogers for an image source and 57 for a directory. `conda-meta-cataloger` runs only on a directory ([grype-probe.txt](../evidence/27/grype-probe.txt), part 3), and grype 0.120.1 has no flag or configuration setting that selects catalogers. The branch's `audit.yml` run shows the result on the real image: six `libssl3t64` rows, all `deb` ([ci-audit.txt](../evidence/27/ci-audit.txt)). So the runtime environment the image ships at `/opt/knarr/.pixi/envs/runtime` is scanned by no job: erlang, the conda-forge openssl the BEAM links, perl 5.32.1 and zlib.

The runtime environment locks 13 packages for linux-64. Ticket 27's probe scanned the 8 of them that have a conda record on the maintainer's host, and did not scan the other 5 (`_openmp_mutex`, `libgcc`, `libgomp`, `libstdcxx` and `libxcrypt`). As an image, those records give 0 conda matches. As a directory, they give 7 conda matches, and the 4 with a fix are all in conda-forge's perl 5.32.1, matched through NVD CPEs:

- CVE-2022-48522, Critical, fixed in 5.35.5;
- CVE-2023-31484 and CVE-2023-31486, High, fixed in 5.38.0;
- CVE-2023-47038, High.

erlang's conda-forge build pins that perl (its build string is `pl5321`), so perl cannot move on its own. [Decision 0003](../../../docs/decisions/0003-tool-manager.md) already contemplated pruning perl from the runtime image, and requires the TLS check to be rerun in the pruned image if it is.

**What to build:**

- `just image-scan`, or a sibling recipe in the `audit` group, also scans the runtime environment as a directory, with the same `--only-fixed --fail-on high`.
- The directory is the linux-64 environment the image ships. Either copy it out of the built image (`docker create`, then `docker cp` of `/opt/knarr/.pixi/envs/runtime` into `build/`), or install it from the lock (`pixi install --locked -e runtime`). The image builds only in CI, on amd64 ([Decision 0012](../../../docs/decisions/0012-release-and-packaging.md)), and a local install on osx-arm64 is that platform's environment, not the one the image ships.
- The recipe fails when `conda-meta-cataloger` catalogues no package. A directory scan of the wrong path, or of a copy without `conda-meta`, otherwise finds nothing and passes. `grype -vv` logs the count, as part 3 of [grype-probe.sh](../evidence/27/grype-probe.sh) reads it.
- `audit.yml` runs it, in the `image-scan` job or one beside it, and the job is not required. It runs even when the OS-package scan fails: the image scan is red on the base image's `libssl3t64` finding until Ubuntu republishes, and a step after a failed one is skipped. Use a job of its own, or `if: ${{ !cancelled() }}` on the step.
- perl is decided, one of:
  - **Pruned** from the runtime image. Then rerun the TLS check 0003 names (`tls_check.escript`) in the pruned image, because pruning breaks the lock's guarantee that what was tested is what ships. The scan then has to read the copy out of the image, since the lock still installs perl.
  - **Accepted** with a dated, documented grype ignore for each CVE, giving the reason and the date it is looked at again.
- The hand-back records what the first run shows.

**Non-goals:**

- The OS-package scan and the base image, which 0014 settles.
- The environments that do not ship (default, cluster and audit) and the `tools.txt` downloads.
- An advisory source for conda-forge: none exists, and 0014's "What would reopen this" covers one appearing.
- Making the job required.

**Blocked by:** 27

**From 27:** [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md); the hand-back notes in [ticket 27](27-spike-dependency-updates-and-audit.md#hand-back-notes); [grype-probe.txt](../evidence/27/grype-probe.txt), part 3, and [ci-audit.txt](../evidence/27/ci-audit.txt).

**MVP critical path:** no. It is maintenance hygiene, and the MVP does not need it.

**Status:** done. See the [amendments to Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) and the [evidence](../evidence/45/README.md).

- [x] A recipe in the `audit` group scans the linux-64 runtime environment as a directory with `--only-fixed --fail-on high`. It exits 0 when nothing qualifies and 2 on a finding, as `just image-scan` does, and fails when it catalogues no conda package.
- [x] `audit.yml` runs it even when the OS-package scan fails, and the job is not required.
- [x] perl is pruned from the runtime image, with `tls_check.escript` rerun in the pruned image, or accepted with a dated, documented grype ignore for each CVE. 0014 carries an "Amended by ticket 45" note saying which, and that the image's conda records are scanned.
- [x] **Authorization required:** the network, for `pixi install`, grype's vulnerability database and any image pull.
- [x] **Authorization required:** one `audit.yml` dispatch on the branch. The hand-back records the run, the matches with a fix and the job's verdict.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Settled on 2026-10-12 and 2026-10-13 (UTC). On 2026-10-12 the maintainer chose to prune perl, not accept it. They also authorized the network for `just audit-install` and grype's database, one push and one `audit.yml` dispatch. During the work they also authorized a draft pull request, [#26](https://github.com/steven-cutting/knarr/pull/26), because `ci.yml` runs only on pull requests, and a second push for these notes.

### What changed

- **perl is pruned.** [`scripts/prune_runtime.py`](../../../scripts/prune_runtime.py) runs in the Dockerfile's build stage, after the gleam export. It deletes every file perl's conda-meta record lists, then the record. It refuses a package with no record or several. It also refuses a listed path outside the environment, directly or through a symlinked directory, and a file another record lists. It checks every package before it deletes anything. Ubuntu's own perl-base stays in the image, and the image scan reads it. openssl's `c_rehash` (`#!/usr/bin/env perl`) now finds that perl; nothing runs it.
- **`just image-check` proves the prune.** In [`image.py`](../../../scripts/checks/image.py), knarr's profile, not the fake worker's, checks that the image has no `bin/perl` and no perl record. Then it reruns Decision 0003's [`run.sh`](../evidence/01/tls/run.sh) in the image, mounted read-only from `.scratch/bootstrap/evidence/01/tls`, with the runtime environment's own openssl and escript, writing only to the `/tmp` tmpfs.
- **`just runtime-scan`** ([`runtime_scan.py`](../../../scripts/checks/runtime_scan.py)) sits in the `audit` group. It runs `docker create`, then `docker cp` of `/opt/knarr/.pixi/envs/runtime` into `build/runtime-scan/`, then `grype -vv dir:` with `--only-fixed --fail-on high`. It exits 0 when nothing qualifies and 2 on a finding. It exits 1 when it cannot decide: a docker or grype error, or a log that shows `conda-meta-cataloger` catalogued no package, whatever grype returned. On exit 1 it prints the log lines that explain it.
- **`audit.yml`** runs `just runtime-scan` in the image-scan job, after `just image-scan`. The step runs unless the run is cancelled, and only when `just image-build` succeeded. The job is still not required.
- **Docs.** Decision 0014 and Decision 0003 carry "Amended by ticket 45" notes, and 0014 has a new "What would reopen" bullet: erlang dropping perl retires the prune. The network lists in `AGENTS.md` and `CONTRIBUTING.md` add `just runtime-scan`. The README and the `CHANGELOG.md` are updated.

### What was verified

- **The tests came first and failed first.** `test_runtime_scan.py` and `test_prune_runtime.py` are new, and `test_image.py` and `test_workflows.py` have new cases. `just check` ends with "All checks passed and the worktree is unchanged."
- **Real grype 0.120.1, locally,** ran `runtime_scan.main` with only docker faked:
  - an empty directory exits 1 with "catalogued no conda package";
  - `.pixi/envs/default` catalogues 51 conda packages and exits 2, on rust-crate findings in its tools.

  The log line the regex reads is grype's own: `[0002] DEBUG discovered 51 packages cataloger=conda-meta-cataloger from=syft`.
- **The first audit run,** [38354220003](https://github.com/steven-cutting/knarr/actions/runs/38354220003), was dispatched once, at `937c8d3` ([ci-runs.txt](../evidence/45/ci-runs.txt)):
  - the build removed perl (`perl-5.32.1-10_h7cc23a3_perl5.json`, 2458 files);
  - `just image-scan` failed with exit 2 on the six known base `libssl3t64` rows;
  - `just runtime-scan` still ran, catalogued 12 conda packages (the 13 the lock lists for linux-64, less perl) and passed: grype listed no vulnerability with a fix at any severity.

  So the 5 packages ticket 27's probe never scanned (`_openmp_mutex`, `libgcc`, `libgomp`, `libstdcxx`, `libxcrypt`) have no match with a fix today. The job's verdict is failure, from the image scan alone.
- **The pruned image on amd64:** PR #26's `ci.yml` run [38354554080](https://github.com/steven-cutting/knarr/actions/runs/38354554080), at `937c8d3`. The kind smoke job's `just image-check` passed the perl check, and `tls_check.escript` matched all 6 cases with the pruned environment's OpenSSL 3.6.5 and OTP 29. Every check on the PR passed.

### What later tickets need

- **The TLS rerun runs only in the non-required kind smoke job,** not in the gate or in `release.yml`. So a release can ship a pruned image that fails it, unless someone acts on that job going red.
- **`image-check` runs code from `.scratch/bootstrap/evidence/01/tls`.** Retiring `.scratch/bootstrap` means moving those three files next to the checkers first.
- **The prune leaves perl's empty directories behind.** They hold no files and change no scan.
- **`just runtime-scan` without the audit environment exits 2,** from the shared `audit-tools` guard, as `just image-scan` does. Exit 2 is also a finding's code.
