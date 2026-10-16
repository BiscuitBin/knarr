# 35: Close the remaining bootstrap verification gaps

**Context:** [Ticket 11's audit](../evidence/11/README.md) distinguishes evidence from the claims tickets 01–09 left unverified. The integrated gate is exercised locally and in native Linux CI, but that does not exercise every probe or agent runtime those tickets discussed.

**What to build:** Evidence for the remaining claims below. Record commands, platform, pins, commit, exit status and limitations. Each item can be closed independently.

**Non-goals:** New validators, dependencies, controller behaviour, or changing branch-protection policy. Do not weaken a check to obtain evidence. A substantive defect gets its own ticket.

**Blocked by:** 11

**MVP critical path:** no. The native TLS evidence should be available to 14 before its client relies on it.

**Status:** partly verified. 01, 03's cold initialization and both 08 items are closed with [evidence](../evidence/35/README.md); 03's primary hook, 04, 06, 05/06 and 09 stay open, each with what it needs in [the hand-back notes](#hand-back-notes). Ticket 32’s rejection proof and remaining downtime/stalled-loop verification are also open below.

- [x] **03, fully cold initialization:** On a disposable machine or account with empty pixi and Gleam package caches, time one `just initialize`, then `just check`, then the gate with network denied. Record how cache emptiness and the network denial were established. Ticket 11 isolated pixi's cache, but Gleam reused the macOS user cache; do not report its time as fully cold. Do not clear or relocate another session's shared cache.
- [x] **01, native Linux TLS and rebar3:** Run the existing TLS probes in both locked default and runtime environments on native linux-64 without the Rosetta flag. Record all six TLS outcomes, matching OTP majors, and the rebar3 dependency compilation and missing-rebar3 negative control. Reuse `evidence/01/tls/run.sh` and `evidence/01/rebar3/run.sh`; ordinary CI does not run these probes. Coordinate the evidence with 13 and 14 rather than introducing a new required CI job here.
- [ ] **03, maintainer's primary hook:** With authorization for that checkout, verify its installed pre-commit hook invokes the intended checkout's environment and rejects an unformatted staged file in a disposable probe. Ticket 03 proved the hook in a throwaway clone; ticket 11 proves the linked worktree leaves shared hooks untouched. Neither claims to have installed or exercised the maintainer's primary hook.
- [ ] **04, intermittent checker test:** Identify the test behind the historical `1 failed, 86 passed` run. Recover an old log if available; otherwise repeat the current checker suite with durable failure output and record the bounded attempt count. A run of green tests alone does not identify or fix it. Once identified, preserve a reproducer and open a focused repair ticket if more than a one-line correction is needed.
- [ ] **06, hosted audit:** Observe a scheduled run of `audit.yml`, or request authorization for one manual dispatch. Record the run URL, commit and result; investigate any failed external links separately. The API reported zero runs during ticket 11. The audit remains outside the required `check` aggregate.
- [ ] **05/06, restricted agent sandbox:** Reproduce and classify the macOS Taplo system-configuration failure under the agent sandbox, recording the supported invocation and required local access. Ticket 11's `toml-check` passes under a network-denying profile and with local escalation; neither proves compatibility with the stricter agent sandbox. Any repair beyond documentation or a one-line correction is a separate ticket, not grounds to weaken the gate or sandbox.
- [x] **08, snapshot commands:** In a disposable clone, exercise `just snapshots-review` through its interactive review step on a real pending change, `just birdie reject` on a pending change, and `just birdie stale delete` on an orphan. Assert the expected accepted-file bytes, pending-file removal, orphan removal and worktree isolation. The earlier `just -n` output is not runtime evidence.
- [x] **08, version fixture:** Capture `/version` from the local kind version chosen by 10 and compare the relevant field types with the hand-written example. Verify the managed-cluster `minor` suffix claim from an authoritative versioned source or an explicitly authorized cluster; a local reply alone does not establish it. Hand any fixture correction to 14 with provenance.
- [ ] **09, Copilot discovery:** Exercise native discovery of `.agents/skills/` in an actual Copilot session. Record the runtime version and a harmless skill invocation. Reading GitHub documentation, or discovering the skills in Codex, does not demonstrate Copilot execution.

- [ ] **32, admission-webhook rejection proof:** On kind, reject knarr's patch through an admission webhook and preserve the run and tested commit, transcript, previous and resulting annotations, the applicable Pod Event and warning, rejection metrics, and attempt timing proving no rapid retries. Cover apply and cleanup rejection reporting, including the annotations left by a refused cleanup. Obtain authorization for network and hosted actions separately. This obligation was assigned here by the loose-ends follow-up; the scripted-apiserver tests in 46 and 47 do not discharge it.
- [ ] **32, downtime and stalled-loop verification:** Verify the remaining parts of 32's downtime criterion with process evidence: no writes or Events while stopped, readiness before a first successful discovery after startup, and a deliberately stalled running loop exposing an unchanged discovery timestamp while liveness stays healthy. Distinguish the existing restart/counter-reset tests from these observations. Record any specification ambiguity or substantive defect for a focused follow-up rather than changing controller behaviour in this evidence ticket.

## Hand-back requirements

Link each result from ticket 11's inventory. Keep raw working material under `ai_tmp/` and durable, reviewed evidence under `.scratch/bootstrap/evidence/35/`. Request authorization separately for network use, hosted dispatch, or access outside the ticket worktree. Record any remaining item as open rather than inferring success from an unrelated green gate.

## Hand-back notes

The [evidence](../evidence/35/README.md) was gathered on 2026-10-10 at `e548efa66770317dd78cd9209b60998ee15d4ee7`, `main` at the time, in a disposable Claude Code cloud container. That container is native Linux x86_64 (Ubuntu 24.04.5, 4 vCPU) and runs as root behind a TLS-re-terminating egress proxy. Ticket 11's [inventory](../evidence/11/README.md#inventory-of-unverified-claims) links each result. No controller code, specification, pin, validator or gate recipe changed. The new files are evidence scripts and their transcripts.

### What was verified

- **03, fully cold initialization.** Every default pixi, rattler, Gleam, hex, prek and rebar3 cache path was absent, and no variable relocated one. In a fresh clone, all three runs exited 0 with the worktree clean:
  - `just initialize` took 16.676 s; Gleam downloaded 38 packages into its empty cache;
  - `just check` took 183.112 s, with 57 Gleam tests and 402 checker tests;
  - `just check` with the network denied took 200.367 s.

  The network was denied by a fresh `unshare -rn` namespace holding only `lo`, brought up for knarr's loopback tests. Inside it, curl through the proxy, by name and by IP failed with exits 7, 6 and 7. A script fault stopped the first offline attempt before it ran anything; the evidence README records the fault and how the offline gate was then run on the same clone.
- **01, native TLS and rebar3.** 01's unchanged probes ran in the locked default and runtime environments, with no Rosetta CPU and no `ERL_FLAGS`:
  - all six TLS cases matched in both environments;
  - `otp_release` was 29 in both, which is `pixi.lock`'s erlang 29.1.1;
  - rebar3 3.27.1 compiled ddskerl and prometheus, and the probe's counter read 2;
  - with rebar3 off `PATH`, the build fails.
- **08, snapshot commands.** In a disposable, network-denied clone:
  - `just snapshots-review` went through birdie's interactive prompt, driven by a pseudo-terminal that typed `a`. It restored the committed bytes (sha256 `1427495…`) and removed the `.new`;
  - `just birdie reject` removed a pending `.new` and kept the edited accepted bytes;
  - `just birdie stale delete` removed an orphan and left the other three snapshots byte for byte.

  This checkout, its birdie list and `$TMPDIR` stayed untouched.
- **08, version fixture.** 14 captured `/version` from kindest/node v1.35.8 locally on arm64 and in CI on amd64. The fixture's five fields have the same JSON types in both captures, and the same values apart from `platform`. Kubernetes v1.35.8, whose commit `1c2e10a…` is the captures' `gitCommit`, appends `+` to `gitMinor` whenever the version carries a `-…` part. Its own lines turn GKE's documented example `1.35.6-gke.1638000` into `minor=35+`. [gke-versioning.sh](../evidence/35/gke-versioning.sh) shows that GKE's versioning page states the `X.Y.Z-gke.N` form and gives that example. `version.Info` declares `Major` and `Minor` as strings. The fixture is correct; no correction goes to 14.

### What stays open

- **03, the maintainer's primary hook.** This needs the maintainer's checkout and authorization to use it. The [probe](../evidence/35/README.md#open-the-maintainers-primary-hook) is now `primary-hook.sh`, and it must run in the primary checkout itself, because `with-env.sh` resolves the environment from the checkout being committed in. It checks that the hook names that checkout's `prek` and that gleam format, not some other failure, refuses the commit. It never leaves a commit: if the hook accepts, it resets HEAD to the recorded commit and fails. Its verdicts and cleanup were checked against stub hooks in seven cases. The container ran the earlier inline form on its own primary checkout, where `gleam-format` refused the commit. Neither is the maintainer's hook.
- **04, the intermittent test.** The historical output was never kept, and no log exists here. The current 402-test suite ran 20 times in sequence on native Linux, 8,040 test executions, and every one passed; that bounded repeat does not identify the test. A read-only review of the 04-era suite found no deterministic defect. It leaves two unverified leads for a rerun on the Mac beside another worktree's gate, both in the [evidence](../evidence/35/README.md#04-intermittent-checker-test): the ripsecrets tests, which launch a freshly copied binary each time, and the process-heavy runner tests.
- **06, hosted audit.** The authorized dispatch on `main` was refused with `403 Resource not accessible by integration`, and it was not retried. No scheduled run exists until Monday 2026-10-12 06:00 UTC. Ticket 27's branch dispatch ([run 38015514089](https://github.com/steven-cutting/knarr/actions/runs/38015514089)) failed its links job on three keda.sh "Connection failed" errors. That run is neither `main` nor scheduled; its links are for a separate investigation. Since #18 merged, `main`'s `audit.yml` has 27's jobs too, so Monday's run will include them.
- **05/06, Taplo under the macOS agent sandbox,** and **09, Copilot discovery.** They need a Mac and a Copilot session respectively. Nothing here observes either.

### Process notes

- The maintainer authorized each network action listed in the [evidence README](../evidence/35/README.md#network-and-authorization), plus pushing this branch and opening its pull request. Before that, one `gh auth status` ran during exploration; it reached GitHub and failed on the container's invalid token. The same invalid token made `install-tools.sh` skip rebar3's Sigstore check, leaving the sha256 pin as the check.
- Raw working material stayed under `ai_tmp/35/`.
- This checkout's own `just initialize` installed its pre-commit hook. This is a primary checkout, not a linked worktree.
- The Codex adversarial review found the inline primary-hook probe's cleanup unsafe: had the hook accepted the commit, the commit would have stayed and the index been left dirty. `primary-hook.sh` and its stub check are the fix.
- Copilot's review of #22 found two faults. The GKE premise rested on an unscripted fetch of GKE's versioning page. `cold-results.json` said the network-denied gate ran "straight afterwards", which contradicted the README's 36-minute gap. `gke-versioning.sh`, with its transcript, and the corrected note are the fixes.

### For later tickets

- **13 and 14:** native linux-64 now has both of 01's probes in both environments, alongside 14's own eight-case client probe. Nothing in 01's emulated results changes. The runtime environment's TLS is the same OTP and openssl build as the default.
- **The maintainer:** to close the open items:
  - run the primary-hook probe;
  - run `gh workflow run audit.yml --ref main`, or check Monday's scheduled run;
  - run the Taplo sandbox reproduction on the Mac;
  - run one Copilot session.

  Record each result in this ticket.
- **Whoever runs the audit next:** reproduce the keda.sh failures before treating them as dead links. They may be a transient or a firewall problem; the run reported "Connection failed", not 404.
