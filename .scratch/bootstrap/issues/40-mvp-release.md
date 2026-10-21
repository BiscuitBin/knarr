# 40: MVP release

**Context:** Ticket 37 publishes `v0.1.0` of the walking skeleton and proves the release route end to end: the existence guard for a new package, the `release` environment's approval, the public package and a pull by digest. That image is pre-MVP; it carries none of the clauses 31, 32, 46 and 47 build. This ticket publishes the first release that does, through the same route, so that 39 installs a digest of the MVP and not of the skeleton. [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) decides the route; 37's hand-back records how it behaved.

**What to build:** The release pull request for the MVP, the tag, the approved run, and a pull by digest, each recorded.

**Non-goals:** Changing the workflow (a fix goes through 36's shape). The repository settings 37 made: the environment, the ruleset and the package's visibility are confirmed here, not changed. Attestations (38). The GKE install (39).

**Blocked by:** 31, 32, 37, 46, 47

**From 28:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md); 37's hand-back for the route as it ran.

**From 37:** the route as it ran, in [37's hand-back](37-first-release-v0-1-0.md#what-each-later-ticket-needs). Date the changelog heading by the UTC day the tag will be pushed. Ruleset `25048585` already exists, and the package's visibility needs no step: it has been public since its first push. The run waits at the `release` environment for as long as the approval takes, and the image's `created` label is stamped when `publish` builds, after the approval, not when the tag is pushed. After the run, `just release-pin <digest>` pins the overlay in a follow-up pull request. From pull request #35's review: rather than copy [preflight.sh](../evidence/37/preflight.sh), promote it into `scripts/release/` behind a `just` recipe that takes the tag and the commit, written test first. 37's scripts and transcripts stay as they ran.

**MVP critical path:** yes. 39 installs this release.

**Status:** done. `v0.2.0` is published as `ghcr.io/steven-cutting/knarr@sha256:989cb9e44df4b97960e68371c1ae8bddcd29db99d65bbd09b663776665c01bc9`, with the first chart, `oci://ghcr.io/steven-cutting/charts/knarr@sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016`. See [the hand-back notes](#hand-back-notes) and [the evidence](../evidence/40/README.md).

- [x] A release pull request bumps `gleam.toml` to the next minor version after the last release, moves `## [Unreleased]` into `## [<version>] - <date>` in `CHANGELOG.md`, and merges like any other. The hand-back records the version and the clauses from 31, 32, 46 and 47 it carries. `0.2.0`, from pull request #52 (merged as `216beac`) with its heading re-dated by #53 (`c917c2e`); [below](#the-release-pull-request).
- [x] The `release` environment and the `v*` tag ruleset are as 37's hand-back recorded them; the hand-back records both as `gh api repos/steven-cutting/knarr/environments/release` and `gh api repos/steven-cutting/knarr/rulesets` show them before the tag is pushed. Unchanged: environment `23921538204`, one required reviewer `User:8365892`, "Prevent self-review" off, and ruleset `25048585` active on `refs/tags/v*` with deletion and update rules and no bypass actors; the only tag was `v0.1.0` ([settings.txt](../evidence/40/settings.txt)).
- [x] **Authorization required:** the maintainer tags the merge commit with an annotated `v<version>` and pushes the tag. The `verify` job passes its three guards. `just release-preflight v0.2.0 c917c2e` passed first ([preflight.txt](../evidence/40/preflight.txt)); the annotated tag was pushed at about 05:44Z on 2026-10-21 and `verify` passed ([run.txt](../evidence/40/run.txt)).
- [x] **Authorization required:** the maintainer approves the `release` deployment. The `publish` job logs in, finds `<version>` absent, pushes `<version>`, its `X.Y` and `sha-<7>` (no `latest`), and prints the digest in its summary. The hand-back records the existence guard's answer (`absent`, HTTP 404) and the run's URL. `absent (http 404)` for the image and for the chart before each push, in [run 39551271680](https://github.com/steven-cutting/knarr/actions/runs/39551271680); tags `0.2.0`, `0.2` and `sha-c917c2e` ([run.txt](../evidence/40/run.txt), [public.txt](../evidence/40/public.txt)).
- [x] From a machine that never built the image (a fresh kind node or a clean container), `docker pull ghcr.io/steven-cutting/knarr@sha256:<digest>` succeeds anonymously, and the labels show `org.opencontainers.image.version=<version>` and the tagged commit. The hand-back records the digest, which 39 installs. A fresh `docker:29.4.0-dind` daemon pulled `sha256:989cb9e4…` with no credentials; version `0.2.0`, revision `c917c2e…`, linux/amd64 ([pull.txt](../evidence/40/pull.txt)).

## Hand-back notes

Done on 2026-10-21 (UTC). Every step that left the worktree was authorized by the maintainer: cutting the release (release pull request, tag, approval), the follow-up pull requests, and the network for the evidence. The maintainer merged each pull request. [The evidence README](../evidence/40/README.md) lists each action.

### The release pull request

The route ran as two pull requests, not one:

- Pull request #52 carried this ticket's preflight recipe and the release commit. The release commit, `7c94e36`, was made in the worktree and gated there but not pushed by that session; it reached the branch, with `9130bd0` (the preflight's date guard reads the exact release heading through a new `lib.sh` `changelog_date`), from outside the session before #52 merged as `216beac`.
- #52 dated the heading 2026-10-20, the UTC day it merged. The tag went out on 2026-10-21 UTC, so #53 re-dated the heading (merged as `c917c2e`, the tagged commit). `just release-preflight` would have refused the stale heading.

The release commit bumps `gleam.toml` and `charts/knarr/Chart.yaml` (`version` and `appVersion`, which `just chart-check` and `stamp-chart.sh` hold together) from 0.1.0 to 0.2.0, the next minor, and moves `[Unreleased]` under `## [0.2.0] - 2026-10-21`. Two tests pinned the app version as a literal and failed on the bump: `metrics_test`'s `knarr_build_info` and `reconciler_test`'s `config.version`. Both now compare with `poller_http.version()`, which `poller_http_test` holds to `gleam.toml`, so the next bump needs no test edit.

0.2.0 carries the MVP clauses of the four blocking tickets, as its changelog lists them:

- 31: discovery by three LISTs matched by owner chain, the reconcile loop, the mapped pod-deletion-cost and the emitted metrics and Events (`reconcile.allium`, `cost_mapping.allium`, `observability.allium`).
- 32: ownership's marker and yield, the rejection signals and lifecycle's pure cleanup contracts (`ownership.allium`, `lifecycle.allium`).
- 46: the poll schedule and the patcher, `budget.allium` `PollSchedule` and `WriteBudget`.
- 47: discovery's cleanup hand-off, wiring lifecycle's contracts to the LISTs.

### What changed

- `scripts/release/preflight.sh`, `preflight_test.sh` and `just release-preflight <tag> <commit>`, promoted from 37's evidence script as "From 37" asked, test first (the test failed with no script, then passed 27 of 27). Beyond 37's guards, it runs `publish`'s first chart stamp on the commit's own chart and refuses a heading not dated the current UTC day. `test_release_lib.py` runs it in `just test-checkers-selected release`; Decision 0012 is amended.
- `deploy/release/kustomization.yaml` pinned to 0.2.0's digest with `just release-pin`, in the follow-up pull request.
- `.scratch/bootstrap/evidence/40/`: `settings.sh` (37's, expecting the tag `v0.1.0`), `preflight.txt`, and `run.sh`, `public.sh` and `pull.sh` adapted from 37's with the chart checks added.

### What was verified

- `just check` ended "All checks passed and the worktree is unchanged." on the preflight branch, on the release commit and on the re-dated heading.
- The run: `verify` passed; the approval went through `gh api -X POST …/pending_deployments` with the maintainer's own login, which "Prevent self-review" off allows; `publish` probed the image and the chart `absent (http 404)`, stamped a placeholder chart before any push, pushed the image, stamped and pushed the chart, and printed both digests.
- Anonymous reads: every image tag and the digest answer 200 at the run's digest, `latest` 404; the chart package `steven-cutting/charts/knarr` was public from its first push like the image, and `0.2.0` answers at the chart digest. An anonymous `helm pull` got the same chart digest, the stamped image digest and `NOTES.txt` (helm chart ticket 05).
- Not run: GKE (39).

### What each later ticket needs

- **39:** install `v0.2.0` with the Helm chart by digest, `oci://ghcr.io/steven-cutting/charts/knarr@sha256:3f29bcac…`, which stamps the image digest above; the install guide is Helm-first. The overlay route remains until helm chart ticket 06, pinned on `main` to the same image digest.
- **Every later release:** run `just release-preflight vX.Y.Z <merge commit>` after `git fetch` and on the UTC day the heading names; if the day rolls over before the tag, re-date the heading in a pull request first.
- **38:** unchanged from 37's notes; the chart's stamped digest follows `DIGEST`, so the index digest flows into the chart.
- **On an arm64 host:** the amd64 release image runs under Rosetta in a kind node only with the BEAM JIT's single mapping, `ERL_AFLAGS="+JMsingle true"`; without it the BEAM dies in `prim_tty` as Decision 0012 records for emulated builds (helm chart ticket 05's evidence).
