# 52: OTP and base-image advisories

**Context:** [Audit run 39896502411](https://github.com/BiscuitBin/knarr/actions/runs/39896502411), which org-transfer ticket 03 dispatched on `main` under `biscuitbin` on 2026-10-23 (UTC), ended in `failure` ([its evidence](../../org-transfer/evidence/03/README.md#workflows-under-the-org)). `External links` passed. The other two jobs failed on two sets of findings.

- **Expected: the base image's libssl.** `Image scan` lists CVE-2026-84782, High, in `libssl3t64` 3.0.13-0ubuntu3.15, fixed in 3.0.13-0ubuntu3.16, as `deb` rows. [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) already records this finding. The image-scan job "stays red until Ubuntu republishes noble" with the fixed package, and the fix is 0014's manual routine for a base image: read the tag's new index digest and move the `FROM` line by hand.
- **New: Erlang/OTP 29.1.1.** `Hex advisories` fails because OSV.dev lists CVE-2026-105236, CVE-2026-42789 (with EEF-CVE-2026-42789) and CVE-2026-96596 against the `OTP-29.1.1` tag. In the image-scan job, both `just image-scan` and `just runtime-scan` list CVE-2026-94200, High, in erlang 29.1.1 as a `binary` package, fixed in 27.3.4.19, 28.5.0.8 and 29.1.2. `just runtime-scan` also lists CVE-2026-105236, Medium, there.

These OTP findings are new. On 2026-10-09 (UTC), ticket 27's probe found no OSV advisory for OTP 29.1.1 (0014's "Today" line, [osv-probe.txt](../evidence/27/osv-probe.txt)). On 2026-10-13, ticket 45's audit run 38354220003 failed on the image scan's libssl rows alone: `Hex advisories` passed, and `just runtime-scan` found no vulnerability with a fix ([ci-runs.txt](../evidence/45/ci-runs.txt), [ticket 45](45-scan-image-runtime-environment.md#hand-back-notes)). When the OTP advisories appeared between then and 2026-10-23 is not established. 0014's rule is to move each pin past its fix or record why it stays, and no ticket covers this one.

**What to build:**

- **Move erlang.** Move `erlang` in `pixi.toml` (`[feature.otp.dependencies]`, `==29.1.1`) past 29.1.2, to a release with no OSV advisory, if conda-forge has a build for both platforms. Relock with `pixi lock` and rebuild the image, as 0014's re-lock routine says.
- **Or record why it stays.** If conda-forge has no such build, record in 0014 why the pin stays and when it is looked at again, as 0014 requires.
- **Rerun the pin-move tripwires** [ticket 42](42-otp-ssl-findings.md) names: `send_sends_the_ip_literal_as_sni_on_this_pin_test` in `test/k8s_http_test.gleam`, the `unknown_ca`, `bad_certificate` and `econnrefused` loopback tests, and Decision 0003's `tls_check.escript` through `just image-check` in CI's kind smoke job.
- **Update what states the pin.** [Decision 0003](../../../docs/decisions/0003-tool-manager.md) gives it at L55 (the snippet), L88 (the table) and L214 (the linux-64 erlang and openssl builds). 0014 gets an "Amended by ticket 52" note in its style, next to the "Today" line at L108 and the base-image finding. L116 says the image scan reads the `deb` packages and not the runtime environment, yet this run's `just image-scan` matched erlang as a `binary` package; the note reconciles the two. `test_the_committed_lock_is_readable_for_each_platform` in `scripts/checks/tests/test_env_check.py` reads the committed `pixi.lock` and expects `erlang-29.1.1-`, so it moves with the pin. The other `29.1.1` strings under `scripts/checks/tests/` are sample data and stay, unless a test turns out to read the real `pixi.toml` or `pixi.lock`. Decision 0011's L20 records what ticket 26 verified, and stays.
- **Check the base image.** Read `ubuntu:24.04`'s current index digest with `docker buildx imagetools inspect`, as `digests.sh` does. If it carries `libssl3t64` 3.0.13-0ubuntu3.16 or later, move the Dockerfile's runtime `FROM` digest (L20). If not, record in 0014 that the image scan is still red on it, with the date checked.
- **Dispatch the audit.** After the change merges, run `audit.yml` once on `main`. The hand-back records the run URL. A run that ends in `success` closes this ticket and the audit box of [org-transfer ticket 03](../../org-transfer/issues/03-transfer-repository.md). If the base image is still red, this ticket's pin work can be done while that box stays open, and the hand-back says so.

**Non-goals:**

- Making the audit required, or changing `--fail-on`.
- Renovate's activation, which is [ticket 44](44-renovate-activation.md).
- The pixi build image (Dockerfile L1), unless the scan flags it.

**Blocked by:** 45. This ticket builds on 45's runtime scan, and 45 is done, so it is ready now.

**From org-transfer 03:** [the ticket's hand-back](../../org-transfer/issues/03-transfer-repository.md#hand-back-notes), [its evidence README](../../org-transfer/evidence/03/README.md) and [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md).

**MVP critical path:** no. It is maintenance hygiene, and the MVP does not need it.

**Status:** in progress. The pin and base-image work is done in [pull request #68](https://github.com/BiscuitBin/knarr/pull/68), and its CI run is green; the audit run on `main` after the merge is pending.

- [x] **Authorization required:** the network, for `pixi lock`. `erlang` in `pixi.toml` moves past 29.1.2 to a release with no OSV advisory, and the lock follows; or 0014 records why the pin stays and when it is looked at again.
- [x] The tripwires ticket 42 names pass on the new pin: the SNI test and the `unknown_ca`, `bad_certificate` and `econnrefused` loopback tests in `just test`, and `tls_check.escript` through `just image-check` in CI's kind smoke job.
- [x] Decision 0003's L55, L88 and L214, and `test_env_check.py`'s committed-lock test, state the new pin. 0014 carries an "Amended by ticket 52" note.
- [x] **Authorization required:** the network, for `docker buildx imagetools inspect` on `ubuntu:24.04`. The Dockerfile's runtime `FROM` digest moves to an index with `libssl3t64` 3.0.13-0ubuntu3.16 or later, or 0014 records the date it was checked and that the image scan is still red on it.
- [x] **Authorization required:** a push and `gh`, for the branch and its pull request.
- [ ] **Authorization required:** one `gh workflow run audit.yml --ref main` after the merge. The hand-back records the run URL and its verdict.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Started on 2026-10-27 (UTC). The maintainer authorized every network action the ticket lists, `pixi search` and pulling the new base index to scan it, and a follow-up pull request that records the audit run after the merge. [The evidence README](../evidence/52/README.md) lists them.

### What changed

- **erlang 29.1.1 → 29.1.2.** All four OTP advisories are fixed in 29.1.2: CVE-2026-105236, CVE-2026-42789 (with EEF-CVE-2026-42789), CVE-2026-96596 and CVE-2026-94200. conda-forge built 29.1.2 for linux-64, osx-arm64 and linux-aarch64 on 2026-10-14, with the same build strings as 29.1.1. It is conda-forge's newest erlang on all three, so "past 29.1.2" is read as "at or past the fix": 29.1.2 is the fixed release, and no record lists it. `pixi lock` moved erlang alone in all three environments, and openssl stays `3.6.5 h781a0a9_0`. erts is now 17.1.1, ssl 11.7.8 and stdlib 8.1.1.
- **The runtime base.** `ubuntu:24.04` now names `sha256:24737cef…`, whose amd64 and arm64 images carry `libssl3t64` 3.0.13-0ubuntu3.16. The runtime `FROM` line moved in `Dockerfile` and in `fixtures/fake_worker/Dockerfile` together, because `test_image.py` holds them equal. That was a second copy the ticket did not name.
- **Tests and docs.** `test_env_check.py`'s committed-lock test expects `erlang-29.1.2-`. Decision 0003's snippet, `erlang` row and solve bullet state the new pin, with a note under the Pins heading. Decision 0014 has "Amended by ticket 52" notes on the base-image digest bullet, the "Today" line, the `tools.txt` gap, the "OS packages only" bullet, the base-image finding and two consequences, plus two Findings rows. Decision 0013's two OTP-pin reopen bullets are amended too, because ssl moved from the 11.7.7 they cite. `CHANGELOG.md` has an `[Unreleased]` Security entry.
- **Evidence:** `.scratch/bootstrap/evidence/52/` holds `probe.sh`, `local-image.sh` and `ci-runs.sh`, with transcripts for the first two.

### What was verified, and what was not

- The committed-lock test failed on the old lock, then passed after the relock. `just lock-check` and `just env-check` pass. `just test` reports 676 passed, among them the SNI test and the `unknown_ca`, `bad_certificate` and `econnrefused` loopback tests.
- `just hex-audit` exits 0 on OTP 29.1.2. As a control, the pin moved back exits 1 naming the three OSV advisories ([probe.txt](../evidence/52/probe.txt)).
- The image built here for linux/arm64 passes `just image-check`, with `tls_check.escript` matching all 6 cases, and both `just image-scan` and `just runtime-scan` exit 0 ([local-image.txt](../evidence/52/local-image.txt)). CI's amd64 build is the ticket's proof: in pull request #68's `ci.yml` run [40470638639](https://github.com/BiscuitBin/knarr/actions/runs/40470638639), at `e7eb105`, every job passed, and the kind smoke job's `just image-check` shows erts 17.1.1 and `tls_check.escript` matching all 6 cases ([ci-runs.txt](../evidence/52/ci-runs.txt)).
- **L116's reconciliation:** syft's `binary-classifier-cataloger` reads `beam.smp` and reports erlang with the CPE `erlang/otp`. That is how an image scan matched erlang as a `binary` package. This was observed on the 29.1.2 image here; run 39896502411's 29.1.1 row is the ticket's account.
- **When the advisories appeared:** three were published on 2026-10-14, the day after ticket 45's run. CVE-2026-42789 was published in May, and its EEF record was last modified on 2026-10-14. When it began to list `OTP-29.1.1` is not shown.

### What later tickets need

- **CVE-2026-94200's OSV record enumerates no tag,** so `just hex-audit` cannot match it against any OTP release. The image scans are what found it. 0014 records this; no change to `hex_audit.py` was made.
- **rebar3 3.27.1 is affected by CVE-2026-96596** (fixed in 3.28.0) through its copy of hex_core's tar module. It is pinned in `tools.txt` and both Dockerfiles' build stages, and no audit job reads it. The runtime image does not carry it. It needs a ticket of its own, which moves both `tools.txt` lines and the `ADD --checksum` lines together (0014's manual routine).
- **Org-transfer 03's audit box** closes on a `success` run of `audit.yml` on `main` after this merges. A follow-up pull request records that run here.
