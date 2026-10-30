# 53: rebar3 hex_core advisory

**Context:** [Ticket 52](52-otp-and-base-image-advisories.md#what-later-tickets-need) found that CVE-2026-96596 also affects rebar3 from 3.27.1 before 3.28.0. rebar3 ships its own copy of hex_core's tar module, `r3_hex_erl_tar`, which does not call stdlib's `erl_tar`, so moving OTP did not fix it. rebar3 3.27.1 is pinned in `tools.txt` and in the `ADD --checksum` line of both Dockerfiles' build stages. Gleam calls it to build the hex packages `manifest.toml` builds with rebar3: `prometheus`, `ddskerl` and `hpack_erl`. The runtime image does not carry it. [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) records that the `tools.txt` downloads have no advisory source and that no bot moves them. Ticket 52's amendment there leaves rebar3 "for a ticket of its own", and this is that ticket. 0014's rule is to move each pin past its fix or record why it stays.

**What to build:**

- **Move rebar3.** Move both `tools.txt` rebar3 lines and both Dockerfiles' `ADD --checksum` lines to a release at or past 3.28.0, together, as 0014's manual routine says. Read the sha256 from GitHub's asset digest, and check the release's Sigstore bundle with `install-tools.sh`'s flags. `test_image.py` holds each `ADD` equal to `tools.txt`'s linux-64 line. It fails with the `tools.txt` move alone and passes once the Dockerfiles follow.
- **Or record why it stays.** If no release at or past 3.28.0 is out of OSV's affected range, or its attestation fails, leave the pin and record in 0014 the date and the reason.
- **Exercise it.** Rerun `just initialize`, which reinstalls rebar3 and, where `gh` is authenticated, verifies its Sigstore bundle; CI's image builds check the sha256 alone. Rebuild the rebar3-built packages from nothing on OTP 29.1.2, and run `just test`.
- **Update what states the pin.** [Decision 0003](../../../docs/decisions/0003-tool-manager.md) gives it at L114 (the table row and its Sigstore source ref) and L125-126 (the snippet). 0014 gets an "Amended by ticket 53" note at L114. `CHANGELOG.md` gets an `[Unreleased]` Security entry. The evidence under `.scratch/bootstrap/evidence/` is dated history and stays.
- **Evidence:** a probe of OSV.dev's record and the release, and a transcript of the rebuild, under `.scratch/bootstrap/evidence/53/`.

**Non-goals:**

- Making the `tools.txt` downloads auditable: a job that matches them against advisories.
- Moving any other `tools.txt` tool.
- Renovate's activation, which is [ticket 44](44-renovate-activation.md).

**Blocked by:** 52, whose hand-back names this ticket. 52 is done, so this one is ready now.

**MVP critical path:** no. It is maintenance hygiene, and rebar3 runs only in the build.

**Status:** done. [Pull request #70](https://github.com/BiscuitBin/knarr/pull/70) is open, and its `ci.yml` run [40983365570](https://github.com/BiscuitBin/knarr/actions/runs/40983365570), at `5448fae`, passed every job. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** the network, for `gh api` on erlang/rebar3's releases, downloading the escript and its Sigstore bundle, and OSV.dev's records. rebar3 moves to a release at or past 3.28.0, or 0014 records why it stays.
- [x] `test_image.py`'s rebar3 test fails after the `tools.txt` move and passes after both Dockerfiles move.
- [x] **Authorization required:** `just initialize`, which reinstalls rebar3 and, with `gh` authenticated, verifies its Sigstore bundle. `just env-check` passes, and `rebar3 version` reports the new release.
- [x] With the compiled packages removed, `just build` rebuilds `prometheus`, `ddskerl` and `hpack_erl` with the new rebar3, and `just test` passes.
- [x] Decision 0003's L114 and L125-126 state the new pin. 0014 and 0003 carry "Amended by ticket 53" notes, and `CHANGELOG.md` has the Security entry.
- [x] **Authorization required:** a push and `gh`, for the branch and its pull request. CI builds both images, so `ADD --checksum` accepts the new sha256, and every job passes: run [40983365570](https://github.com/BiscuitBin/knarr/actions/runs/40983365570).
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Started on 2026-10-28 (UTC). The maintainer authorized the reads above, `just initialize` in this worktree, and pushing the branch with its pull request. [The evidence README](../evidence/53/README.md) lists them.

### What changed

- **rebar3 3.27.1 → 3.28.0.** 3.28.0 is erlang/rebar3's newest release, published on 2026-10-21. Its asset digest, `5a28b1cc…`, is the new sha256 in both `tools.txt` lines and in the `ADD --checksum` lines of `Dockerfile` and `fixtures/fake_worker/Dockerfile`.
- **Two more advisories.** The probe asked OSV.dev about the rebar3 tag the way `hex_audit.py` asks about OTP. For 3.27.1 it lists two advisories ticket 52 did not name: CVE-2026-103060, a path traversal through dependency app names, fixed in 3.27.2, and CVE-2026-105274, hex_core decompressing registry and API responses without a size limit, fixed in 3.27.3. 3.28.0 fixes all three, and OSV's querybatch lists no advisory for it. The same querybatch misses CVE-2026-96596 on 3.27.1, so that is not proof that no advisory applies to 3.28.0.
- **Docs.** Decision 0003's `rebar3` row and snippet state the new pin, with a note in the Escape hatch section that keeps the original 3.27.1 record. Decision 0014 has "Amended by ticket 53" notes on three places:
  - The rebar3 `ADD` row: a second copy sits in `fixtures/fake_worker/Dockerfile`.
  - The manual routine: both Dockerfiles move with `tools.txt`.
  - The `tools.txt` advisory gap, plus two Findings rows.

  `CHANGELOG.md` has an `[Unreleased]` Security entry.
- **Evidence:** `.scratch/bootstrap/evidence/53/` holds `probe.sh` and `build.sh`, with their transcripts.

### What was verified, and what was not

- `test_image.py::test_build_fetches_rebar_without_curl_and_matches_tool_pin` failed for both Dockerfiles with only `tools.txt` moved, then passed with both `ADD` lines moved.
- `just initialize` printed "rebar3 3.28.0 Sigstore bundle verified" and installed it. `just env-check` passes.
- [probe.txt](../evidence/53/probe.txt) checks the pin from three directions:
  - It is the newest release.
  - Its download matches GitHub's asset digest and the four pinned lines, and its Sigstore bundle verifies at `refs/tags/3.28.0`.
  - OSV's querybatch lists no advisory for 3.28.0. None of the three records lists 3.28.0, and each states its rebar3 fixes at or before it. Because the querybatch misses CVE-2026-96596, this covers the records the probe read, not every record OSV holds.
- [build.txt](../evidence/53/build.txt): with `build/dev` and `build/prod` removed, `just build` compiled `ddskerl` 0.4.3, `hpack_erl` 0.3.0 and `prometheus` 6.1.3 with `rebar 3.28.0 on Erlang/OTP 29 Erts 17.1.1`. `just test` reports 676 passed.
- **Not established:** why OSV's querybatch does not return CVE-2026-96596 for rebar3 3.27.1, although the record enumerates that tag. Its record joins four repositories in one `affected` entry, while the two it does return name rebar3 alone, which may or may not be the cause.
- **CI:** pull request #70's `ci.yml` run [40780385069](https://github.com/BiscuitBin/knarr/actions/runs/40780385069), at `93c66e9`, passed every job: the repository gate, `check`, the selected checker regressions, kwok readiness, and both kind smoke jobs. In the kind smoke job's `just image-build` and the fake worker job's `just fake-worker-image-build`, the build stage's `ADD --checksum=sha256:5a28b1cc… …/3.28.0/rebar3` step finished. Inside the image builds, rebar3 compiled `ddskerl`, `hpack_erl` and `prometheus` for knarr, and `hpack_erl`, the fake worker's one rebar3-built package. The kind smoke job's `just image-check` reports OTP 29, erts 17.1.1 and `tls_check: all 6 cases matched` on amd64. The run was read back with `gh run view --log`; no transcript of it is committed.
- **A pre-existing flake.** Run [40781561224](https://github.com/BiscuitBin/knarr/actions/runs/40781561224), at `6aa625a`, failed `Selected checker regressions`: `test_ripsecrets_redacted.py::test_a_planted_token_fails_with_the_fixed_message_and_never_prints_it` got `(0, '', '')` where it expected status 1. The `token` fixture drew a random `ghp_` token, and the pinned ripsecrets 0.1.11's randomness test passed over 10 of 2000 such tokens in a local run, so with five tests planting one, about 1 run in 40 failed. Commit `5448fae` makes the fixture redraw, up to 100 times, until the pinned binary exits 1 on the token. That fix is outside this ticket's scope and lands in #70 at the maintainer's direction. The test file then passed 50 local runs in a row, and run [40983365570](https://github.com/BiscuitBin/knarr/actions/runs/40983365570), at `5448fae`, passed every job.

### What later tickets need

- **The `tools.txt` downloads still have no advisory source.** OSV can match a rebar3 tag in the `GIT` ecosystem, so `hex_audit.py` could ask about it the way it asks about OTP. But the CVE-2026-96596 miss shows a querybatch alone would not have caught that advisory. That is a design question for a ticket of its own, not a one-line change.
- Moving a `tools.txt` tool stays manual until a bot can rehash the downloads (0014, ticket 44).
