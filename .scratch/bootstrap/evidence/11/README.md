# Ticket 11 evidence

Gathered on 2026-10-08 for [integration](../../issues/11-integration.md), starting at `4f0eca5c342493c7830cf6be77791f2207956115`. GitHub's `main` and the clean `11-integration` worktree both named that commit. No controller, specification, tool pin or gate implementation changed. The [branch-protection read-back](#branch-protection-read-back) was gathered later, at 2026-10-09T03:19Z against `c96e10632be947a4f293cef774cfbc127aac9c1d`.

## Local verification

[Machine-readable results](local-results.json) record commands, statuses and elapsed wall-clock seconds. The host was Darwin arm64 with pixi 0.81.0 and bootstrap just 1.51.0; the initialized environment pins just 1.58.0. Timings use Python's monotonic clock around each subprocess; initialization excludes cloning. Transcripts remove terminal colour and replace the checkout's absolute path with `<worktree>`; other output is retained.

| Run | Seconds | Result | Evidence |
| --- | --- | --- | --- |
| Fresh clone, `just initialize` | 14.950 | Exit 0; primary-clone hook installed; clean | [Transcript](initialize.txt) |
| Fresh clone, `just check` | 91.067 | Exit 0; 13 Gleam tests, 285 checker tests; clean | [Transcript](clone-check.txt) |
| Same clone, `just check` with network denied | 69.711 | Exit 0; all checks passed; clean | [Transcript](clone-offline-check.txt) |
| Linked worktree, `just initialize` | 0.238 | Exit 0; printed hook-skip notice | [Transcript](linked-initialize.txt) |
| Linked worktree, `just check` | 93.423 | Exit 0; 13 Gleam tests, 285 checker tests; baseline unchanged | [Transcript](linked-check.txt) |

The fresh clone was made with `git clone --no-hardlinks --single-branch --branch 11-integration . ai_tmp/integration/clone`. Before initialization, launcher assertions checked that it had no `.pixi`, `.tools` or `build` directory and that `ai_tmp/integration/caches/pixi` did not exist. Those assertions produced no retained standalone output. `PIXI_CACHE_DIR` pointed at that cache path; `PREK_HOME` pointed at `ai_tmp/integration/caches/prek`. No environment or downloaded tool was copied or linked from another checkout. Initialization verified the four downloaded tools' checksums and rebar3's Sigstore bundle. A later [`pixi info --json` read-back](observations.json) confirms the cache override, without pretending to re-establish historical emptiness.

**This is not a fully cold machine measurement.** Gleam reused the existing macOS user cache, as its 28 packages in 0.07 seconds indicate. That shared cache was not moved or cleared. [Ticket 35](../../issues/35-bootstrap-verification-gaps.md) carries 03's stronger cold-cache timing claim. The measurements above establish the fresh-clone checklist item with that limitation stated.

The offline invocation was `sandbox-exec -p '(version 1)(allow default)(deny network*)' just check`, using the same isolated cache environment as initialization. Both DNS-based and direct-IP curl probes failed inside the same profile; [their commands and output](offline-probes.txt) record exits 6 and 7. The successful gate proves the profile could launch processes; a failure to launch `sandbox-exec` was not counted as network-denial evidence. Launcher assertions observed empty `git status --porcelain --untracked-files=all` after each clone gate but did not retain those empty outputs separately. The [later status read-back](observations.json) retains the empty string and unchanged clone HEAD. There is no separate retained status output immediately after initialization; the first gate's unchanged baseline and subsequent empty status support the clean-initialization claim.

The linked worktree's Git directory differs from its common directory, as [recorded](observations.json). All 15 files under the common `hooks` directory have identical SHA-256 values [before](hooks-before.json) and [after](hooks-after.json) initialization, and [after the linked gate](hooks-after-check.json). `core.hooksPath` is unset. The installer printed its linked-worktree skip notice. No hook was installed from this worktree. The linked-worktree gate preserved the in-progress evidence diff; that baseline assertion alone does not mean the changes were already committed. The final clean status is verified after committing.

### Reproduction

Use a new ignored scratch directory for each run; do not reuse the recorded clone or cache paths. With pixi and just already installed, clone the recorded commit locally, set `PIXI_CACHE_DIR` and `PREK_HOME` to fresh absolute scratch paths, and run the commands in the table from the appropriate checkout. Capture elapsed time, exit status and `git status --porcelain --untracked-files=all` after each command. Use the offline profile above on macOS; Linux needs a separately verified network namespace. Keep the user Gleam cache limitation unless the run uses a disposable account or machine with an empty cache.

For linked-worktree verification, hash all files in `git rev-parse --path-format=absolute --git-common-dir`'s `hooks` directory before and after initialization and compare the complete inventories. Initialization needs network authorization even if an already-initialized worktree happens to reuse everything.

## GitHub verification

[Recorded API results](ci.json) associate `main` at the audited SHA with [CI run 37745546445](https://github.com/steven-cutting/knarr/actions/runs/37745546445). Both `Repository gate` and aggregate `check` completed successfully on the same SHA. The [log excerpt](ci-excerpt.txt) shows all gate recipes, 13 Gleam tests, 285 checker tests and the unchanged-worktree success message on Ubuntu 24.04. It also records installation of the pinned Linux binaries. It does not show the standalone TLS/rebar3 probes from ticket 01.

The read-only calls were:

```sh
gh api repos/steven-cutting/knarr/branches/main
gh api repos/steven-cutting/knarr/branches/main/protection
gh api repos/steven-cutting/knarr/rulesets
gh api 'repos/steven-cutting/knarr/actions/workflows/ci.yml/runs?branch=main&event=push&per_page=5'
gh api repos/steven-cutting/knarr/actions/runs/37745546445/jobs
gh run view 37745546445 --repo steven-cutting/knarr --log
gh api 'repos/steven-cutting/knarr/actions/workflows/audit.yml/runs?per_page=5'
```

The audit workflow had zero runs. No workflow was dispatched. All GitHub observations are point-in-time evidence, not a promise about later commits or settings.

### Prepared branch-protection change

[Protection before any change](protection.json) has `strict: false`, an empty required-check list, pull requests required with zero approvals, administrators exempt, and force pushes and deletions disabled. [The rulesets response](rulesets.json) is empty. At the time of the audit the protection acceptance criterion was therefore **not yet met**; the [read-back below](#branch-protection-read-back) records how it was met.

The exact mutation proposed at the time was:

```sh
gh api --method PATCH repos/steven-cutting/knarr/branches/main/protection/required_status_checks \
  --input .scratch/bootstrap/evidence/11/required-check.json
```

[The payload](required-check.json) requires only `check`, explicitly bound to GitHub Actions app `15368`. The [app observation](check-source.json) records the source of the audited check run. The [GitHub API documentation](https://docs.github.com/en/rest/branches/branch-protection#update-status-check-protection) supports `checks` entries with `context` and `app_id`; the status-check PATCH endpoint leaves unrelated protection settings untouched. Omitting `strict` preserves its current value.

The prepared procedure, kept as history, was: before applying it, reread protection and require that the current contexts and checks are still empty; if settings changed, prepare a new request for review. After authorization and execution, run `sh .scratch/bootstrap/evidence/04/state.sh check`, reusing 04's tested projection and rulesets check, and retain the full protection response. That script checks names but not app identity, so also run this read-only assertion and require exit zero:

```sh
source_matches=$(gh api repos/steven-cutting/knarr/branches/main/protection/required_status_checks \
  --jq '.contexts == ["check"] and .checks == [{"context":"check","app_id":15368}]') &&
  test "$source_matches" = true
```

It went on: compare every other protection field against the fresh pre-change response, excluding only `required_status_checks.contexts` and `required_status_checks.checks`; preserve `strict: false`, the administrator exemption and all other settings; record the mutation and read-back before checking off 11's criterion or updating 05's pending status. This audit made no mutation, and the request will not be run: the setting is already in place.

### Branch-protection read-back

The maintainer applied the required check through GitHub's branch-protection settings page, not through this audit. The prepared `PATCH` above was never run, and no session observed the pre-change reread it called for. The comparison below is therefore against the audit's [pre-change response](protection.json) from 2026-10-08, not a fresh one; an intermediate change that was later reverted would not show. What was verified is the state afterwards. The read-only calls below ran at 2026-10-09T03:19Z, when GitHub's `main` was `c96e10632be947a4f293cef774cfbc127aac9c1d`:

```sh
gh api repos/steven-cutting/knarr/branches/main/protection
gh api repos/steven-cutting/knarr/branches/main/protection/required_status_checks
gh api repos/steven-cutting/knarr/rulesets
sh .scratch/bootstrap/evidence/04/state.sh check
gh api 'repos/steven-cutting/knarr/actions/workflows/ci.yml/runs?branch=main&event=push&per_page=3'
gh api repos/steven-cutting/knarr/branches/main --jq .commit.sha
```

- **Required checks:** [the status-check response](required-status-checks-after.json) has `strict: false`, `contexts: ["check"]` and `checks: [{"context": "check", "app_id": 15368}]`, matching [the prepared payload](required-check.json). The app-identity assertion above evaluates to `true` against it. The `required_status_checks` object inside [the full protection response](protection-after.json) is identical.
- **Everything else unchanged:** with `required_status_checks.contexts` and `required_status_checks.checks` removed from both, [the full protection response](protection-after.json) and [the pre-change response](protection.json) are identical. `strict` is still `false`, administrators are still exempt, and force pushes and deletions are still disabled. [The rulesets response](rulesets-after.json) is still `[]`.
- **04's script:** [`state.sh check`](state-after.txt) exited 0 with `strict=false checks=check admins=false` and zero rulesets. Its `main on GitHub is ahead with 84668a5…` line compares GitHub's `main` with the commit ticket 04 pushed; its `info remote main` line, `c96e106…`, is the current `main`.
- **CI on current `main`:** [the recorded runs query and branch SHA](ci-after.json) show [run 37877497805](https://github.com/steven-cutting/knarr/actions/runs/37877497805) completed successfully at `c96e106`. Only the projected fields were retained; no log excerpt was kept for this run.

Administrators remain exempt by 04's decision, so `check` is required for pull requests but not for a direct push by the owner. The protection acceptance criterion is met.

### PR review disposition

[Copilot's finding](https://github.com/steven-cutting/knarr/pull/9#discussion_r4224228609) correctly identifies missing explicit source selection and verification in the prepared request. The API can infer the app from recent checks, so the claim that a bare context necessarily accepts any publisher is too strong. The revised payload removes that ambiguity and the read-back checks the source as well as the name. On 2026-10-08, a read-only query of the audited commit's check runs confirmed app `15368`, slug `github-actions`:

```sh
gh api repos/steven-cutting/knarr/commits/4f0eca5c342493c7830cf6be77791f2207956115/check-runs \
  --jq '.check_runs[] | select(.name == "check") | {id,name,head_sha,html_url,app: {id: .app.id,slug: .app.slug}}'
```

## Inventory of unverified claims

The inventory covers hand-backs 01–09 and the evidence/decision caveats they reference. Existing evidence is cited where a later lane already closed an earlier claim; ordinary future feature work is distinguished from unverified bootstrap claims.

| Source | Claim or limitation | Disposition |
| --- | --- | --- |
| 01 | Hook execution without the Justfile's PATH; bootstrap entry command | Closed by [03's hook and bootstrap evidence](../03/README.md); this run again initializes from host `just` alone. |
| 01 | Entire gate offline after initialization | Closed by [the network-denied gate](clone-offline-check.txt), including all integrated lanes. |
| 01 | First native Linux run confirms TLS and rebar3 probe results | **Follow-up 35.** Native CI executes the gate, not those probes. No TLS result is inferred from CI. Closed by [35's native run](../35/native-linux.txt): six TLS cases in both environments, OTP 29 in both, rebar3 and its negative control. |
| 02 | No Linux binaries ran; copied Python checkers not run in knarr | Closed by [native CI](ci.json), its [gate excerpt](ci-excerpt.txt), and 285 passing checker tests. Historical claims about which scripts ran in 02 remain historical. |
| 03 | Linux gate not run | Closed by current-main CI at the audited SHA. |
| 03 | Cold initialization timing not measured | **Follow-up 35.** This run has an empty pixi cache but a reused Gleam cache. Closed by [35's cold run](../35/README.md#03-fully-cold-initialization) on a disposable Linux machine with every cache absent. |
| 03 | Maintainer's primary checkout hook not installed/exercised | **Follow-up 35.** Fresh-clone installation and linked-worktree non-installation are proven separately. Still open: 35 gives [a tested probe](../35/README.md#open-the-maintainers-primary-hook) for the maintainer's checkout. |
| 04 | Required `check` not added | Closed by the [branch-protection read-back](#branch-protection-read-back): `check` from GitHub Actions app `15368` is the only required status check. |
| 04 | One unidentified checker failure, followed by five passing runs | **Follow-up 35.** Passing current gates does not identify the intermittent failure. Still open: [35's bounded repeat](../35/README.md#04-intermittent-checker-test) of 20 green runs, 8,040 test executions, does not identify it; leads for the Mac are recorded there. |
| 05 | Required-check authorization pending | Closed by the [branch-protection read-back](#branch-protection-read-back), not inferred from a green CI job. The maintainer applied the setting; this audit made no mutation. |
| 05, 06 | Taplo fails under the restricted macOS agent sandbox | **Follow-up 35.** `toml-check` passed with local escalation and in the network-denying profile; that does not prove compatibility with the stricter agent sandbox. Still open in [35](../35/README.md#open-the-restricted-agent-sandbox-and-copilot): it needs a Mac. |
| 06 | GitHub-hosted execution not claimed | Validator and shared setup closed by current-main CI. Hosted external-link audit has zero runs: **follow-up 35**. Still open: [35's authorized dispatch](../35/README.md#06-hosted-audit) was refused with a 403, and no run on `main` exists yet. |
| 07 | Only the macOS Allium download and real gate were observed | Linux installation, checksum check, `check-specs` and `analyse-specs` closed by current-main CI. The root still has zero behaviour clauses; no new obligation count is claimed. |
| 08 | Nothing ran on Linux | Integrated build, tests, glinter and snapshot gate closed by current-main CI. This does not claim Linux execution of the separate mutation evidence script. |
| 08 | Interactive review, reject and stale delete only dry-run | **Follow-up 35**, with real pending/orphan fixtures and byte-level assertions. Closed by [35's snapshot run](../35/snapshots.txt). |
| 08 | `/version` example is hand-written; string fields and `+` suffix recalled from memory | **Follow-up 35**, feeding captured/provenanced evidence to 14. Closed by [35](../35/README.md#08-version-fixture): 14's captures match the fixture's types, and Kubernetes v1.35.8's build script establishes the `+`; no correction for 14. |
| 09 | Copilot native discovery documented but unexercised | **Follow-up 35.** Codex's discovery in this session is not Copilot evidence. Still open in [35](../35/README.md#open-the-restricted-agent-sandbox-and-copilot). |
| 09 | No Codex runtime directory or plugin added | Deliberate non-goal, not an execution claim. The current Codex session exposes the canonical project skills; no new provider adapter is needed for this audit. |

[Follow-up 35](../../issues/35-bootstrap-verification-gaps.md) supplies independently checkable acceptance criteria for each remaining verification gap. Follow-ups already assigned to 10, 13–15, 17–29 remain with those feature/spike tickets; integration does not implement them. Requested code-review skills unavailable to earlier sessions are historical process limitations, not evidence of failed implementation; ticket 11 requests Claude Code's adversarial review separately.

## Adversarial review

Claude Code 2.1.294 was invoked with `--model opus --effort medium`, the CLI's latest-Opus alias, and only Read, Glob and Grep tools. The [review](review.txt) identifies itself as Opus 5.5 (`claude-opus-5-5`); [invocation/result metadata](review-metadata.json) records the effort argument and model usage. The reviewer did not execute tests or mutate files. Its runtime also accounted for auxiliary Fable usage; the reviewing model was Opus.

No high-severity defect was reported. Dispositions of its two medium and five low findings:

1. **Staging before validation:** the first linked gate was before new files were staged. `just lint` subsequently passed with every new evidence file staged; the final full gate runs on the committed tree. The earlier transcript remains labelled as an in-progress baseline.
2. **Follow-up discovery:** 35 now appears in the bootstrap dependency graph and execution waves, blocked by 11, with direct coordination notes in 13 and 14. Those MVP tickets gain no new hard blocker.
3. **Just versions:** distinguish bootstrap 1.51.0 from the environment's pinned 1.58.0.
4. **Unretained observations:** explicitly identify launcher assertions without standalone output, and retain later cache/status read-backs without claiming they prove historical cache emptiness.
5. **Protection read-back:** require 04's existing `state.sh check` as well as comparison of the complete protection response.
6. **Hooks after the gate:** retain a third hash inventory and the unset `core.hooksPath` observation.
7. **Taplo sandbox caveat:** add the limitation to the claim inventory and follow-up 35.

The terminal-colour residue the reviewer mentioned was removed from the CI excerpt. Branch-protection execution was pending authorization at review time; neither the review nor a green gate authorized it. The maintainer later applied it, and the [read-back](#branch-protection-read-back) verifies the result.

The merge from `main` renumbered this branch's verification follow-up from 30 to 35 because ticket 17 had allocated 30–34. The archived review retains the ticket numbers used at review time.
