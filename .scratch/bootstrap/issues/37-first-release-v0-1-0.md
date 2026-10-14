# 37: First release run: `v0.1.0`

**Context:** Ticket 36 makes the release route live. Nothing has run it. [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) leaves three things unverified that only a real run can settle: the authenticated existence guard's answer for a package that does not exist yet, the `release` environment's approval flow with one maintainer, and a pull of the published digest from a machine that never built the image. This run publishes `v0.1.0` of the walking skeleton as the first release: a rehearsal of the route on a pre-MVP image, so that [40](40-mvp-release.md) publishes the MVP through a route that has run once.

**What to build:** The repository settings the route needs, the release pull request, the tag, the approved run, the package made public, and a pull by digest, each recorded.

**Non-goals:** Changing the workflow beyond what the run shows is wrong (a fix goes through 36's shape and this ticket records it). Attestations (38). The GKE install (39).

**Blocked by:** 36

**From 28:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md), "Not run here"; [ghcr-probe.txt](../evidence/28/ghcr-probe.txt) for the settings as they were on 2026-10-09.

**MVP critical path:** yes. The MVP installs a published release.

**Status:** done. `v0.1.0` is published as `ghcr.io/steven-cutting/knarr@sha256:97262e02b6326b73ac414fa1bb01b6f557b1c352b7d647a30d7835e4a59e22c7`. See [the hand-back notes](#hand-back-notes) and [the evidence](../evidence/37/README.md).

- [x] The `release` environment 36 created still has the maintainer as its required reviewer and "Prevent self-review" **off**; the hand-back records the settings as `gh api repos/steven-cutting/knarr/environments/release` shows them before the tag is pushed. [settings.txt](../evidence/37/settings.txt), at 03:30Z.
- [x] **Authorization required:** a tag ruleset on `v*` restricts updates and deletions. The hand-back records it as `gh api repos/steven-cutting/knarr/rulesets` shows it. Ruleset `25048585`, in [settings.txt](../evidence/37/settings.txt) and [ruleset-response.json](../evidence/37/ruleset-response.json).
- [x] A release pull request moves `## [Unreleased]` into `## [0.1.0] - <date>` in `CHANGELOG.md`, leaves `gleam.toml` at `0.1.0`, and merges like any other. Pull request #33, merged as `283a7d4`; [preflight.txt](../evidence/37/preflight.txt).
- [x] **Authorization required:** the maintainer tags the merge commit with an annotated `v0.1.0` and pushes the tag. The `verify` job passes its three guards. [run.txt](../evidence/37/run.txt).
- [x] **Authorization required:** the maintainer approves the `release` deployment. The `publish` job logs in, finds `0.1.0` absent, pushes `0.1.0`, `0.1` and `sha-<7>` (no `latest`), and prints the digest in its summary. The hand-back records what the existence guard answered for the package that did not exist yet (0012 expects `absent`, HTTP 404) and the run's URL. `absent (http 404)`, in [run 38506839202](https://github.com/steven-cutting/knarr/actions/runs/38506839202); [run.txt](../evidence/37/run.txt).
- [x] **Authorization required:** the package is made public once, by hand. The hand-back records that an anonymous `curl -sI` of the manifest answers 200 with the same `Docker-Content-Digest`. No hand change was needed: the package was public from the workflow's first push. With an anonymous token, every tag and the digest answer 200 with the run's digest ([public.txt](../evidence/37/public.txt); [below](#visibility-and-the-anonymous-check)).
- [x] From a machine that never built the image (a fresh kind node or a clean container), `docker pull ghcr.io/steven-cutting/knarr@sha256:<digest>` succeeds, and the labels show `org.opencontainers.image.version=0.1.0` and the tagged commit. The hand-back records the digest as the rehearsal's evidence; 39 installs 40's, not this one. A fresh `docker:29.4.0-dind` daemon; [pull.txt](../evidence/37/pull.txt).
- [x] A second push of the same tag is not attempted; instead the hand-back quotes the workflow's existence guard refusing in a dry reasoning line, or, if the maintainer wants it proven, a `workflow_dispatch` rerun that fails on `present` is recorded and the trigger removed again. The dry line, [below](#a-second-push-reasoned-dry); [public.txt](../evidence/37/public.txt).

## Hand-back notes

Done on 2026-10-14 (UTC). Every step that left the worktree was authorized by the maintainer, one action at a time. [The evidence README](../evidence/37/README.md) lists each one.

### What changed

- Pull request #33, the release pull request, merged as `283a7d489d07d81bd3a9c393ce10be11ad71303f`. `CHANGELOG.md` moved its entries unchanged under `## [0.1.0] - 2026-10-14`, with an empty `## [Unreleased]` above. Its intro and the changelog links in `README.md` and `docs/README.md` stopped calling the entries unreleased. The heading first said 2026-10-13, the local date. UTC had already reached 2026-10-14, the only day the tag could be pushed, so a second commit moved it before the merge. `gleam.toml` stayed at `0.1.0`.
- This pull request pins [`deploy/release`](../../../deploy/release/kustomization.yaml) to 0.1.0's digest with `just release-pin`, and its comment no longer calls the digest a placeholder: it says the pin lands on `main` after the tag, so at a release's own tag the overlay still holds the previous digest, and that an install checks out the tag, runs `just release-pin <digest from the run>` there, and applies the overlay. The `release-pin` recipe's comment says each release runs it. `CHANGELOG.md` records the pin under `[Unreleased]`. [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) carries "Amended by ticket 37" notes, ticket 36's second box is ticked, and [`evidence/37/`](../evidence/37/README.md) holds the scripts and transcripts. `_typos.toml` ignores a 12-hex layer id followed by one of docker's progress statuses, as `docker pull` prints it in `pull.txt` (`61f70ba02274: Pull complete`).
- `release.yml` and `scripts/release/lib.sh` are unchanged. The run showed no defect in either.

### The settings

Before the tag, at 03:30Z, [settings.txt](../evidence/37/settings.txt) read ticket 36's `release` environment unchanged: id `23921538204`, one `required_reviewers` rule whose one reviewer is the maintainer (user `8365892`), `prevent_self_review` false, no wait timer, and GitHub's defaults `can_admins_bypass: true` and `deployment_branch_policy: null`. It read no tag and no release.

The tag ruleset was created with [ruleset.json](../evidence/37/ruleset.json) as ruleset `25048585`, "release tags". It is active, targets tags matching `refs/tags/v*`, and restricts updates and deletions. It has no creation rule, which would have refused the first tag push. It has no bypass actors, so GitHub answered `"current_user_can_bypass": "never"`: the maintainer cannot move or delete a `v*` tag either. As an administrator, the maintainer can still edit or disable the ruleset.

### The run

- The maintainer tagged `283a7d4` with an annotated `v0.1.0` and pushed it. [Run 38506839202](https://github.com/steven-cutting/knarr/actions/runs/38506839202) started at 03:33:10Z. `git cat-file -t v0.1.0` prints `tag`, and `git ls-remote` shows the same tag object on the remote, peeled to `283a7d4`.
- `verify` passed in 4 s: `tag v0.1.0 at 283a7d489d07d81bd3a9c393ce10be11ad71303f: version 0.1.0, an ancestor of origin/main, in the changelog`.
- The run waited at the `release` environment for 43 minutes. The approvals endpoint reads `approved by steven-cutting (user 8365892) for release (23921538204)`: the maintainer approved their own tag's deployment, which "Prevent self-review" off allows. The approval comment was "test".
- `publish` ran from 04:16:55Z to 04:17:36Z. It logged in (`Login Succeeded`), and its moved-tag step passed, the first live run of that step. The existence guard then printed `ghcr.io/steven-cutting/knarr:0.1.0 is absent (http 404): pushing`. That is 0012's expected answer for a package that did not exist yet, from a push-scope token taken after login.
- buildx named and pushed `0.1.0`, `0.1` and `sha-283a7d4`, and no `latest`. The digest is `sha256:97262e02b6326b73ac414fa1bb01b6f557b1c352b7d647a30d7835e4a59e22c7`.

### Visibility and the anonymous check

0012 expected a package that does not inherit the repository's visibility, made public once by hand. It was public from the workflow's first push, and nobody changed it.

- At 04:33:15Z, before anyone had opened the package's settings, [public-private.txt](../evidence/37/public-private.txt) asked ghcr.io for an anonymous pull token, expecting the 403 that ticket 28 saw for a package it could not see. ghcr.io answered 200, and the script stopped there.
- At about 04:43Z the maintainer opened `github.com/users/steven-cutting/packages/container/knarr/settings`, changed nothing, and saw the package public and linked to `steven-cutting/knarr`.
- At 04:47:31Z, [public.txt](../evidence/37/public.txt), with no credentials: a bare `curl -sI` of the manifest answers 401, as it does for any ghcr.io package, because a registry client fetches an anonymous token first. With that token, `0.1.0`, `0.1`, `sha-283a7d4` and the digest itself each answer 200 with `Docker-Content-Digest: sha256:97262e02…22c7` and content type `application/vnd.docker.distribution.manifest.v2+json`, one manifest and not an index. `latest` answers 404, and `tags/list` holds exactly `0.1.0`, `0.1` and `sha-283a7d4`.

Why GHCR created the package public is not established here. [sources.txt](../evidence/28/sources.txt) records what GitHub's documentation said on 2026-10-09, and this run observed something else. Pinning the cause would take one authorized fetch of that page. Nothing depends on it now: the package exists, and its visibility persists across later pushes.

### The pull

[pull.txt](../evidence/37/pull.txt), at 06:31:44Z, rerun after [the pull request review](#pull-request-review) so that its counts are checked; the first run, at 04:47:33Z, observed the same: a fresh `docker:29.4.0-dind` container (`sha256:a6dd5322…3489`), its daemon 29.4.0, with 0 images and no docker config before the pull. `docker pull --platform linux/amd64 ghcr.io/steven-cutting/knarr@sha256:97262e02…22c7` downloaded all six layers from ghcr.io. The image's labels read `org.opencontainers.image.version=0.1.0`, `revision=283a7d489d07d81bd3a9c393ce10be11ad71303f`, `source=https://github.com/steven-cutting/knarr` and `created=2026-10-14T04:17:00Z`, on `linux/amd64`. Then `docker rm -fv` left no container. The host is arm64, so the pull names the platform, and nothing ran the image.

### A second push, reasoned dry

A second run for `v0.1.0` cannot start from a push. Pushing the same tag object again changes nothing, and moving or deleting the tag is refused by ruleset `25048585`. That leaves a re-run from the Actions page, which repeats `publish`'s existence guard. The guard's own function, run against the real registry with an anonymous token in [public.txt](../evidence/37/public.txt), reads `present (1, http 200)` for `0.1.0`, so the workflow would stop the run with:

```text
::error::ghcr.io/steven-cutting/knarr:0.1.0 exists (http 200): a release is published once; bump the version
```

The workflow asks with a push-scope token taken after login, not an anonymous one. For a public package both see the same manifest. No re-run was attempted, and no `workflow_dispatch` trigger was added.

### What was verified, and what was not

- Verified: the release guards on the merge commit before the tag; the environment and the ruleset before the tag; `verify` and `publish` green on the first live run; the guard's `absent` (404); exactly three tags and no `latest`; each log line the hand-back cites, which `run.sh` now checks as well as prints; an install at the tag, offline on a copy, where the overlay renders the placeholder as tagged and 0.1.0's digest once `pin-digest.sh` has pinned it, with both kustomize builds ([install-at-tag.txt](../evidence/37/install-at-tag.txt)); one digest agreeing across buildx's `--metadata-file`, every tag's `Docker-Content-Digest` and a pull by digest; anonymous reads of every tag; a pull by digest on a daemon that never built the image, with the labels; `just release-pin` and `just deployment-check` on the real digest, and `test_deployment.py` and `test_release_pin.py` (37 passed) on the pinned overlay; and `just check`, which ended with "All checks passed and the worktree is unchanged." on this pull request's tree, with lychee checking the evidence's links and their fragments.
- Not verified: the ruleset refusing a moved or deleted tag (it was not attempted; ruleset `25048585` as GitHub returned it is the evidence); the guard's `present` inside the workflow, only its function against the registry; the step summary's text, which the API does not return (the log's `digest=` line carries the same digest); why the package was created public; a pull from a GKE node (39); the image running, since nothing runs the amd64 image on this host; attestations (38).

### Pull request review

Before the pull request opened, `/code-review` on the hand-back reported 9 findings, and 6 were applied: the overlay comment's claim about the tag, "public from the first push" resting on what was observed, the dry `present` line naming its anonymous token, two more amendments in 0012, ticket 40 copying the scripts rather than editing 37's, and the `release-pin` recipe's comment. Three were declined then: the repository-wide typos pattern, the `private` branch of `public.sh`, and a `fail` lost in `run.sh`'s digest read. The review below raised the first and the third again, and both are fixed.

Copilot reviewed `4800001` on pull request #35 and left two inline findings, and `/code-review high` on the same commit found six more. Each Copilot thread has a reply.

- **Copilot: `public.sh`'s header said the maintainer changes the visibility between its two modes.** Nobody did. Fixed in the comment only: `private` was written for a package before a visibility change, and it failed its first expectation because the package was already public. No command changed, so `public-private.txt` and `public.txt` still come from the committed script.
- **Copilot: the overlay comment and 0012 said an install at the release tag takes the run's digest, which nothing does.** `kubectl apply -k` at the tag reads the previous digest, which for `v0.1.0` is the all-zero placeholder. Fixed: an install checks out the tag, runs `just release-pin <digest from the run>` there, then applies the overlay. The overlay comment and an amendment to 0012 say so, and [install-at-tag.txt](../evidence/37/install-at-tag.txt) shows it offline, on a copy of the tag's `deploy/` and `scripts/release/`.
- **Review 1: `pull.sh` piped `docker images -q` and `docker ps -aq` into `wc -l`,** so a failed command counted as an empty list. Fixed: each list is read and its status checked, then counted. `pull.txt` was rerun.
- **Review 2: `run.sh` printed verify's line, the guard's line and the pushes without checking them.** Fixed: it checks verify's exact line, one `Login Succeeded`, the guard's exact `absent (http 404)` line, the tags buildx named and pushed (`0.1`, `0.1.0` and `sha-283a7d4`, both times), no `::error::` or `##[error]` line in either job, and one digest. `run.txt` was rerun. What it read is unchanged, since the run was not redone: it gains the check lines, the job ids on the job lines and a new read time.
- **Review 3: `run.sh` and `settings.sh` print one read and check later ones.** Fixed in `run.sh`: the run with its jobs, the approvals and each job's log are each read once, and what it prints and what it checks come from that read. That also fixes the digest read, whose `fail` was lost in a subshell. Declined for `settings.sh`: its record from before the tag cannot be retaken, its reads were seconds apart, and the only change to the settings that morning was the ruleset, made by the `POST` just before the run it records.
- **Review 4: `preflight.sh` hard-codes `v0.1.0`,** and a check every release needs belongs in the release tooling rather than in a script each release copies. Agreed and deferred: ticket 40's "From 37" line asks for it in `scripts/release/` behind a `just` recipe that takes the tag and the commit, test first. `preflight.sh` stays as it ran.
- **Review 5: the `_typos.toml` pattern ignored any 12-hex word before a colon, anywhere in the repository.** Fixed: it ignores the id only when one of docker's progress statuses follows it. `typos` passes on `pull.txt`. A probe line holding a misspelled word and an id followed by other text still reports both: the word, and the two letters inside the id that typos reads as a misspelling.
- **Review 6: the scripts each define `fail` and `expect`, and write their failures to different streams.** Declined: a shared helper would change `preflight.sh` and `settings.sh`, whose transcripts cannot be retaken.

`/code-review` on this round's own diff reported 14 findings. Fixed:

- The run summary prints the whole reference, `ghcr.io/steven-cutting/knarr@sha256:…`, and `just release-pin` takes only the bare `sha256:` digest. The `release-pin` recipe's comment, the overlay comment, 0012 and ticket 34 now name that form.
- The overlay comment no longer names 0.1.0 as the pinned release, which the next pin would make wrong.
- `install-at-tag.sh` reports whether the worktree's `pin-digest.sh` still matches the tag's instead of refusing to run, since it runs the archived copy.
- This section and the evidence README no longer say that only `run.txt`'s read time changed.

Left for the maintainer, because each changes the release design or a file this round keeps as it ran:

- With a real digest pinned on `main`, an install at a later tag that skips `just release-pin` runs the previous release without an error, where the all-zero placeholder failed to pull. Keeping `main` on a placeholder, or attaching the rendered overlay to each release, would make the skip loud or unnecessary. Either changes 0012.
- `CHANGELOG.md`'s `[0.1.0]` says `deploy/release` installs the release pinned by digest, which it does not at the tag, and the `[Unreleased]` pin entry will ship in 0.2.0's notes naming 0.1.0's digest.
- `pin-digest.sh`'s header still says ticket 37 runs it, with the digest from the run summary.
- `run.sh` checks the log digest's shape, not that it equals the digest the other scripts were given. The transcripts show the two equal.
- `public.sh` prints the manifest's content type without checking it.

Declined: the "public from the first push" amendment resting on a 403 baseline taken for a missing package, since ticket 28 saw the same 403 for a private one and the settings page showed the package public; a shared `fail` and `expect` for the new script; and a typos pattern for image ids in `docker images` output, which no transcript needs yet.

### What each later ticket needs

- **34:** the install guide installs `deploy/release` at a release tag. At `v0.1.0`'s commit the overlay still holds the placeholder. The real pin landed after the tag, on `main`, as every pin will: the digest exists only once the run has pushed. So an install checks out the tag, runs `just release-pin <digest from the run>` there, and applies `deploy/release` with `kubectl apply -k` ([install-at-tag.txt](../evidence/37/install-at-tag.txt)). `just release-pin` takes the bare `sha256:` digest, the log's `digest=` line or the part after `@` in the summary's reference, and needs `just cluster-install`. The package is public, so the overlay needs no `imagePullSecrets`.
- **38:** this run pushed with buildx's docker driver ("pushing … with docker") and stored one Docker schema 2 manifest. With attestations on, the pinned digest becomes an index's, and `just release-pin` and `test_deployment.py` already accept any `sha256:` digest. The attestation goes to the same public package.
- **39:** installs 40's digest, not this one. GKE nodes pull anonymously, since the package is public. A pull from a GKE node is still unverified.
- **40:** the route has now run once, with each step above. Date the changelog heading by the UTC day the tag is pushed. Before tagging, run `verify`'s guards offline on the merge commit, as [preflight.sh](../evidence/37/preflight.sh) did here. Promote it into `scripts/release/` behind a `just` recipe that takes the tag and the commit, test first, rather than copying it. 37's scripts and transcripts stay as they ran. The ruleset already exists, and the package's visibility needs no step. `settings.sh` expects no tag, so 40's copy needs that expectation changed before it can record 40's settings. After the run, `just release-pin <digest>` pins the overlay in a follow-up pull request, as here. The run waits at the environment for as long as the approval takes (43 minutes here), and the image's `created` label is stamped when `publish` builds, after the approval, not when the tag is pushed: 04:17:00Z against 03:33Z here.
