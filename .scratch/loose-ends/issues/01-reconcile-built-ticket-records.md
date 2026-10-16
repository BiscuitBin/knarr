# 01: Reconcile evidence and completion records for tickets 31, 32, 46 and 47

**What to build:** An evidence-backed completion record for bootstrap tickets 31, 32, 46 and 47: preserve the successful reconcile proof, reconcile stale checkboxes and status lines, and give every remaining verification gap an explicit owner. This ticket handles evidence and bookkeeping; it does not change controller behaviour or build the admission-webhook rejection harness.

**Blocked by:** None (can start immediately). The relevant implementation has landed; the real-apiserver rejection proof remains deferred to bootstrap ticket 35 and does not block this reconciliation.

**Status:** done. Evidence recovered, records reconciled and full gate passed; the remaining verification belongs to bootstrap ticket 35.

- [x] **31 — preserve the reconcile proof.** Inspect the successful CI run recorded by ticket 47 (run 38820393121), recover the reconcile step's transcript, and commit it with the run URL, tested commit and result. Verify that it establishes ticket 31's proof before correcting the stale ticket and evidence status. If the transcript is unavailable or insufficient, obtain explicit authorization for a new labelled PR run or workflow dispatch, then preserve that run's evidence instead. A successful cleanup transcript alone is not the reconcile transcript.
- [x] **32 — reconcile both unticked criteria.** Check the rejection-counter assertions supplied by 46 and the cleanup, retry and rejection-cadence evidence supplied by 47 against the first criterion. Audit the separate downtime, restart and stalled-loop criterion against its own evidence. Mark only demonstrated claims complete; retain any unproven portion as explicit outstanding work with an owner. Preserve the historical hand-back and append the correction with evidence references.
- [x] **32 → 35 — assign the rejection proof.** Add an explicit acceptance item to bootstrap ticket 35 for an admission-webhook rejection on a real apiserver, and cross-reference it from 32. Its eventual proof must demonstrate the applicable Event, warning, metrics, unchanged annotations and absence of rapid retries. Keep this obligation unchecked; this ticket neither builds the harness nor claims the proof passed.
- [x] **46 — verify the final box.** Audit the recorded full-gate result and obligation counts against the revision and modules they describe. The hand-back records budget 26 and reconcile 18; verify rather than assume these discharge the criterion. Run any missing validation, record its revision and results, and check the final box only when both the gate and obligation-count requirements are supported. Distinguish historical evidence from fresh verification.
- [x] **47 — correct the status.** Verify PR #41's merge against local history and reconcile the status line with the completed criteria and hand-back evidence. Preserve the documented residual risks rather than treating a built status as proof that they disappeared.
- [x] **Hand-back.** Record what was corrected, the evidence and validation used, and each remaining obligation's owning ticket. Run `just check` and record its result; finish with the repository's required clean worktree. Obtain authorization separately for any network access or hosted action needed while carrying out this ticket.

## Hand-back notes

Worked on branch `01-reconcile-built-ticket-records`, from `299da31`, on 2026-10-15. No controller, specification, dependency, workflow or handbook changes.

- **31:** recovered the successful reconcile step from run 38820393121, job 116715288745, with separately authorized read-only GitHub access. The committed transcript and evidence README distinguish tested PR merge `2a02f23` from head `a457d02`. No dispatch, label change or cluster operation was needed.
- **32:** inspected the integrated rejection assertions and cleanup tests; recorded 46 and 47's completed contributions while retaining both composite boxes as unchecked. Bootstrap ticket 35 now explicitly owns the real-apiserver rejection proof and the remaining downtime/startup/stalled-loop observations. No missing evidence was inferred from a green gate.
- **46:** the old hand-back explicitly says the full gate was not run. Recorded fresh integrated verification instead. Fresh `plan-spec` counts: budget 26, config 24, reconcile 18, lifecycle 8, observability 30; all match the historical counts.
- **47:** local Git history confirms PR #41's merge at `b6e3c06`; corrected its status and kept every residual risk.
- **Later work:** 35 must provide its new proof items before 32's corresponding composite criteria can close. Ticket 33 retains the KEDA and restart-threshold harness; 48 retains replacement-pod detection. No new blocking edge is introduced by recording these evidence obligations.

### Validation

`just check` on 2026-10-15, against `299da31` plus these evidence and ticket corrections, ended with "All checks passed and the worktree is unchanged." It passed 676 controller tests, 58 fake-worker tests and 113 checker tests, specification checks and analysis, and all documentation, packaging and lint checks. The gate used local escalation because its loopback listeners are denied by the agent sandbox; no network audit ran. The final status and this validation note were added afterwards and checked by the read-only lint recipe and commit hooks.
