# 40: MVP release

**Context:** Ticket 37 publishes `v0.1.0` of the walking skeleton and proves the release route end to end: the existence guard for a new package, the `release` environment's approval, the public package and a pull by digest. That image is pre-MVP; it carries none of the clauses 31, 32, 46 and 47 build. This ticket publishes the first release that does, through the same route, so that 39 installs a digest of the MVP and not of the skeleton. [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) decides the route; 37's hand-back records how it behaved.

**What to build:** The release pull request for the MVP, the tag, the approved run, and a pull by digest, each recorded.

**Non-goals:** Changing the workflow (a fix goes through 36's shape). The repository settings 37 made: the environment, the ruleset and the package's visibility are confirmed here, not changed. Attestations (38). The GKE install (39).

**Blocked by:** 31, 32, 37, 46, 47

**From 28:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md); 37's hand-back for the route as it ran.

**From 37:** the route as it ran, in [37's hand-back](37-first-release-v0-1-0.md#what-each-later-ticket-needs). Date the changelog heading by the UTC day the tag will be pushed. Ruleset `25048585` already exists, and the package's visibility needs no step: it has been public since its first push. The run waits at the `release` environment for as long as the approval takes, and the image's `created` label is stamped when `publish` builds, after the approval, not when the tag is pushed. After the run, `just release-pin <digest>` pins the overlay in a follow-up pull request. From pull request #35's review: rather than copy [preflight.sh](../evidence/37/preflight.sh), promote it into `scripts/release/` behind a `just` recipe that takes the tag and the commit, written test first. 37's scripts and transcripts stay as they ran.

**MVP critical path:** yes. 39 installs this release.

**Status:** needs-human, round 2. Every step below that changes something outside the worktree needs the maintainer's explicit approval, one action at a time.

- [ ] A release pull request bumps `gleam.toml` to the next minor version after the last release, moves `## [Unreleased]` into `## [<version>] - <date>` in `CHANGELOG.md`, and merges like any other. The hand-back records the version and the clauses from 31, 32, 46 and 47 it carries.
- [ ] The `release` environment and the `v*` tag ruleset are as 37's hand-back recorded them; the hand-back records both as `gh api repos/steven-cutting/knarr/environments/release` and `gh api repos/steven-cutting/knarr/rulesets` show them before the tag is pushed.
- [ ] **Authorization required:** the maintainer tags the merge commit with an annotated `v<version>` and pushes the tag. The `verify` job passes its three guards.
- [ ] **Authorization required:** the maintainer approves the `release` deployment. The `publish` job logs in, finds `<version>` absent, pushes `<version>`, its `X.Y` and `sha-<7>` (no `latest`), and prints the digest in its summary. The hand-back records the existence guard's answer (`absent`, HTTP 404) and the run's URL.
- [ ] From a machine that never built the image (a fresh kind node or a clean container), `docker pull ghcr.io/steven-cutting/knarr@sha256:<digest>` succeeds anonymously, and the labels show `org.opencontainers.image.version=<version>` and the tagged commit. The hand-back records the digest, which 39 installs.
