# 36: Release workflow and the digest-pinned release overlay

**Context:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) settles the route: SemVer with `gleam.toml` as the source of truth, a hand-written Keep a Changelog, the maintainer tags and CI publishes to `ghcr.io/steven-cutting/knarr` behind a `release` environment, consumers pin by digest, and §9.15 is kustomize only with a release overlay over `deploy/base`. Ticket 28 drafted the workflow, the guards and the overlay under [evidence/28](../evidence/28/README.md) and dry-ran them against a throwaway registry; none of it is live. This ticket makes it live, without running it.

**What to build:** `release.yml` under `.github/workflows/` from [the draft](../evidence/28/release.yml); the guards it sources in `scripts/release/lib.sh` from [28's lib.sh](../evidence/28/lib.sh), with their tests moved beside them in the shape the checker tests use; `deploy/release/` from [the overlay design](../evidence/28/overlay/kustomization.yaml); and the recipes and checker tests that keep base and overlay in step.

**Non-goals:** Running the workflow (37). Attestations, SBOM, provenance and arm64 (38). The install guide (34). `CHANGELOG.md` itself (12). The Role's verbs and the RoleBinding (14).

**Blocked by:** 12, 28

**From 28:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md); the hand-back notes in [ticket 28](28-spike-release-and-packaging.md#hand-back-notes).

**MVP critical path:** yes. Nothing reaches GKE without a published image.

**Status:** done. Pull request #16 merged on 2026-10-10 (UTC) as `1d9b1ff`, which made `release.yml` live, and [ticket 37](37-first-release-v0-1-0.md)'s `v0.1.0` was its first live trigger. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** before the pull request merges, the `release` environment exists with the maintainer as its required reviewer and "Prevent self-review" off, and the hand-back records it as `gh api repos/steven-cutting/knarr/environments/release` shows it. GitHub creates a referenced environment with no protection rules otherwise, so a `v*` tag pushed before 37 would publish with no approval.
- [x] **Authorization required:** `release.yml` is live once merged. The pull request says so, and the maintainer merges it knowingly. It runs on `v*` tag pushes only, keeps `permissions: {}` at the top, `contents: read` on `verify`, and `contents: read` plus `packages: write` on `publish` behind `environment: release`. Every action is pinned to a full commit SHA. `just lint` runs actionlint on it.
- [x] `scripts/release/lib.sh` carries `version_of_tag`, `tags_for`, `toml_version`, `tag_matches_version`, `changelog_has_version`, the digest readers, `tag_exists_verdict`, `probe_tag` and `ancestor_verdict` from 28's `lib.sh`, and 28's `lib_test.sh` runs against it from `just test-checkers` or a recipe in the `check` group. The existence guard still proceeds only on `absent`; `unknown` stops the run.
- [x] `deploy/release/kustomization.yaml` renders `deploy/base` with the image renamed to `ghcr.io/steven-cutting/knarr`, pinned by digest, and `imagePullPolicy: IfNotPresent`, and changes nothing else; a checker test renders both and asserts the two-line difference, as [overlay-render.sh](../evidence/28/overlay-render.sh) does. `just deployment-check` validates the overlay's render as well as the base's.
- [x] A recipe, outside `check`, replaces the overlay's digest with a given `sha256:…` and prints the rendered image reference, for 37 to use after the first push.
- [x] `just check` ends with "All checks passed and the worktree is unchanged." The hand-back names the workflow's first live trigger (37's tag) and what 37 must still set up before pushing it: the `v*` tag ruleset.

## Hand-back notes

Done on 2026-10-09 (UTC). Nothing here ran the workflow: no tag, no ruleset and no run. Outside the worktree, the `release` environment was created (below), and, each step authorized by the maintainer, the branch was pushed as pull request #16 and [its review](#pull-request-review) answered there.

### What changed

- [`release.yml`](../../../.github/workflows/release.yml) is [28's draft](../evidence/28/release.yml) with three edits made in the move (a header for a live file, the "Ticket 36 moves …" comment removed, and the environment comment saying what must exist before merge) and four from [the pull request review](#pull-request-review). `verify` refuses a checkout that is not the tag's commit, runs the ancestry guard on that commit and hands it to `publish`. `publish` fetches the tag again and stops unless the tag and the checkout are still that commit, then tags and labels the image from it. The ancestry error reads as an ancestry result. Comments now say that the concurrency group does not order runs by version, and how to recover after a partial push. The triggers, permissions, environment, concurrency settings, `--provenance=false --sbom=false`, the existence guard and the pinned checkout SHA are as drafted.
- [`scripts/release/lib.sh`](../../../scripts/release/lib.sh) is 28's `lib.sh` without the helpers only the evidence used (`fail`, `work_dir`, `sha256_of`, `head_digest`, `tag_moved_verdict`, `iso_seconds`, `step_seconds`, `median`). [`lib_test.sh`](../../../scripts/release/lib_test.sh) beside it keeps 71 of 28's 91 tests and adds five for `probe_tag` through a stub `curl`: 404 is `absent`, 200 is `present`, 403 and a failed connection (curl 7, code `000`) are `unknown`, and the manifest Accept header and the extra curl arguments reach curl. `test_release_lib.py` runs it in `just test-checkers`. [evidence/28](../evidence/28/README.md) is unchanged.
- [`deploy/release/`](https://github.com/steven-cutting/knarr/blob/v0.2.0/deploy/release/kustomization.yaml) is [28's overlay](../evidence/28/overlay/kustomization.yaml) over `../base`, with the placeholder digest until 37 pins it.
- `scripts/checks/deployment.py --render`, which `just deployment-check` runs, now renders and validates every variant under `deploy/` (since the merge with main, `base`, `release` and ticket 14's `wrong-ca`), then fails unless the overlay changes exactly two lines of one container: its image, to `ghcr.io/steven-cutting/knarr@sha256:<64 hex>`, and its pull policy, on the next line, to `IfNotPresent`. The offline path `packaging-check` runs, and main's `--render <variant>`, are unchanged. `test_deployment.py` holds that rule against canned real renders, reads the committed overlay line by line, and runs `--render` end to end with a fake kustomize and kubeconform.
- `test_workflows.py` reads the workflows line by line: every remote `uses:` under `.github/` is pinned to a full commit SHA with a version comment, and `release.yml` triggers on the two version-tag patterns only, grants nothing at the top, `contents: read` to `verify`, `contents: read` and `packages: write` to `publish` behind `environment: release`, probes `$VERSION` and reads the verdict before its one push, and pushes only on `absent`. `verify` outputs the commit it checked, and `publish` fetches the tag again and stops unless the tag and HEAD are both that commit, before its one push, and tags and labels from it. Each rule has negative cases on inline text.
- `just release-pin <sha256:…>`, in a new `release` group outside `check`, runs [`pin-digest.sh`](https://github.com/steven-cutting/knarr/blob/v0.2.0/scripts/release/pin-digest.sh). It refuses anything but one line of `sha256:` and 64 lower-case hex digits, and requires exactly one digest line in the overlay. It replaces that line with sed (`kustomize edit set image` would drop the comments) in a copy of `deploy/` first, renders the copy, and writes the overlay only if the render is `ghcr.io/steven-cutting/knarr@<digest>`; a failed render or a wrong reference leaves the overlay as it was. `test_release_pin.py` tests it in a copy with a fake kustomize; its one-line test runs on the committed overlay and on one already pinned, so it still holds once 37 commits a real digest. The Justfile header, the README and AGENTS.md list it among the recipes that write tracked files.
- The [local cluster guide](../../../docs/how-to/local-cluster.md) says what `just deployment-check` now validates, and `CHANGELOG.md` has the release workflow under Added.

### The `release` environment

**Authorization required**, granted for this ticket. On 2026-10-09 at 22:44 UTC a GET of the environment answered 404, then `gh api -X PUT repos/steven-cutting/knarr/environments/release` created it with the maintainer (user id 8365892) as its one required reviewer and `prevent_self_review` false, and no wait timer. `gh api repos/steven-cutting/knarr/environments/release` then showed:

```json
{"id":23921538204,"node_id":"EN_kwDOVAMqy88AAAAFkdW0nA","name":"release","url":"https://api.github.com/repos/steven-cutting/knarr/environments/release","html_url":"https://github.com/steven-cutting/knarr/deployments/activity_log?environments_filter=release","created_at":"2026-10-09T22:44:50Z","updated_at":"2026-10-09T22:44:50Z","can_admins_bypass":true,"protection_rules":[{"id":68296717,"node_id":"GA_kwDOVAMqy84EEiAN","type":"required_reviewers","prevent_self_review":false,"reviewers":[{"type":"User","reviewer":{"login":"steven-cutting","id":8365892,"node_id":"MDQ6VXNlcjgzNjU4OTI=","avatar_url":"https://avatars.githubusercontent.com/u/8365892?v=4","gravatar_id":"","url":"https://api.github.com/users/steven-cutting","html_url":"https://github.com/steven-cutting","followers_url":"https://api.github.com/users/steven-cutting/followers","following_url":"https://api.github.com/users/steven-cutting/following{/other_user}","gists_url":"https://api.github.com/users/steven-cutting/gists{/gist_id}","starred_url":"https://api.github.com/users/steven-cutting/starred{/owner}{/repo}","subscriptions_url":"https://api.github.com/users/steven-cutting/subscriptions","organizations_url":"https://api.github.com/users/steven-cutting/orgs","repos_url":"https://api.github.com/users/steven-cutting/repos","events_url":"https://api.github.com/users/steven-cutting/events{/privacy}","received_events_url":"https://api.github.com/users/steven-cutting/received_events","type":"User","user_view_type":"public","site_admin":false}}]}],"deployment_branch_policy":null}
```

`can_admins_bypass: true` and `deployment_branch_policy: null` are GitHub's defaults, left as they are because Decision 0012 decides neither. With one maintainer who is also the administrator, the bypass lets only that maintainer deploy without the approval click. With no branch policy any ref may deploy, which a tag-triggered workflow needs; the tag ruleset (37) is what restricts tags.

### What was verified, and what was not

- `sh scripts/release/lib_test.sh`: 76 passed, 0 failed, under macOS `sh` and under dash, CI's `sh`. Against a `lib.sh` without `probe_tag` it reported 71 passed, 5 failed.
- Every new test of new or fixed behaviour was watched failing first, then passing: in `test_deployment.py` 14 of its 15 new tests (the 15th pins a container that is not the first, which the first version already allowed), in `test_release_pin.py` all 14, in `test_workflows.py` the 5 that read `release.yml` before it existed (the 27 others test the rules on inline text and the existing workflows, and passed from the start), and `test_release_lib.py`. `just test-checkers`: 387 passed.
- With the cluster environment installed (`just cluster-install`, kustomize v5.8.2), `just deployment-check` validated both renders, 3 of 3 resources each, and printed the overlay's image. The canned renders in `test_deployment.py` equal the live renders byte for byte, the release one with the placeholder digest. A real overlay with an added `namePrefix` is refused. `just release-pin sha256:72d620f2…137b`, the digest 28's dry run pushed, changed only the digest line, kept the comments and the file mode, printed `ghcr.io/steven-cutting/knarr@sha256:72d620f2…137b`, and `just deployment-check` passed on that render. `just release-pin sha256:abc` was refused. The overlay was restored byte for byte.
- `just lint` (actionlint with shellcheck on `release.yml`, shellcheck, ruff, editorconfig-checker, typos), `just agents-check` and `just docs-check` pass, and `just check` ended with "All checks passed and the worktree is unchanged."
- After the merge with main, `just deployment-check` validated the three variants, 4 of 4 resources each, and printed the overlay's image: the two-line difference holds on the merged base. `BASE_RENDER` was regenerated from that base; it and `RELEASE_RENDER`, with the placeholder digest, equal the live renders byte for byte.
- After the review fixes, `sh scripts/release/lib_test.sh`: 76 passed, 0 failed. Each new test was watched failing first: the two `test_workflows.py` tests that read `release.yml` (its `verify` outputs and the moved-tag order) against the reviewed file, and the pinned case of the one-line pin test against the hard-coded placeholder. The six new inline cases test the moved-tag rule itself. `just test-checkers`: 402 passed. `just lint` and `just check` pass as above.
- Not verified, by design: any run of `release.yml`, a push to ghcr.io, the existence guard against ghcr.io for a package that does not exist yet, and the approval flow. They are 37's.

### Code review

`/code-review` on the staged diff reported 15 findings. Fixed here, each test first:

- `pin-digest.sh` wrote the overlay before rendering it, so a failed render left a new digest behind. It now pins and renders a copy.
- `overlay_difference` accepted the image changed on one container and the pull policy on another, as a sidecar ahead of knarr would make the overlay's `containers/0` patch do. It now requires both lines on one container.
- `test_workflows.py` skipped `.yaml` files and did not check that the guard runs before the push.

Left for the maintainer at first, because this ticket kept `release.yml` to 28's draft. [The pull request review](#pull-request-review) raised three of them again:

- Fixed: `publish` built `refs/tags/$TAG` without comparing it with the commit `verify` checked, so a tag moved while the run waited for approval could be built unchecked. It now builds only that commit, and only while the tag still names it.
- Fixed: the ancestry error read "is unknown of origin/main" when `origin/main` could not be resolved. It now reads as an ancestry result.
- Documented: tags are pushed before the digest is read, so if the step fails after the push, a re-run meets `present`. The recovery is beside the existence guard in `release.yml` and under 37 below.

Still left for the maintainer, because Decision 0012 settled the workflow's shape:

- The token exchange `curl -sSf … | perl` runs without `pipefail`, so a failed exchange shows up as `unknown` (HTTP 401) instead of its real cause. It still fails closed. The derived bearer is not passed to `::add-mask::`.
- `tags_for` is called twice in one step, and `DIGEST` goes to `$GITHUB_ENV` for 38's step only.

Also noted, not changed:

- The difference rule runs on real renders only in `just deployment-check`, which runs in the non-required kind and kwok jobs (the gate has no kustomize). The gate's line-by-line overlay test catches a base whose first container's image is not `knarr`.
- The placeholder digest passes every check until 37 pins a real one, so a later revert to it would too.
- The image name is spelled in five places, which the tests hold together.
- Since the merge, `release` is a `deploy/` variant, so `just deploy <image> release` is accepted. It would deploy the overlay's pinned image, the placeholder until 37 pins one, which kind cannot pull. Nothing runs it; the kind loop deploys `base` or `wrong-ca`.

### Pull request review

Copilot and Codex reviewed `03b44e5` on pull request #16 and left six inline findings; recovery after a partial push came from both. Each thread has a reply.

- **Copilot, high: `publish` resolves the mutable tag again** after `verify` approved it, so a tag moved during the approval wait could be built unchecked. Fixed as above: `verify` outputs the tag's commit, and `publish` fetches the tag again, stops unless the tag and the checkout are still that commit, and builds and labels that commit. `test_workflows.py` holds the order of those lines before the push, with five negative cases.
- **Copilot, medium, and Codex, P2: a re-run after a completed push meets `present`** and cannot finish. Documented, not automated: `present` still stops the run, as Decision 0012 decides. An automatic path would let `present` proceed, and nothing can test that before 37. The recovery is beside the guard and under 37 below.
- **Copilot, medium: the one-line pin test hard-codes the placeholder,** so it would fail once 37 commits a real digest. Fixed: the test reads the old line from the overlay, runs on the committed overlay and on one already pinned, and pins a different digest when the overlay already holds the test's.
- **Copilot, low: the ancestry error reads "is unknown of origin/main".** Fixed: "the ancestry of tag … against origin/main is unknown, not ancestor: release only what main carries".
- **Codex, P2: serialized runs can still move `X.Y` and `X` backward** when an older release runs after a newer one in its line, as a re-run of a cancelled pending run does. The mechanism is right, and the comment overclaimed. `release.yml`'s concurrency comment and Decision 0012's workflow paragraph now say the group does not order runs by version, and 0012's backport reopen bullet covers the re-run. No monotonic guard: no install follows `X.Y` or `X`, which 0012 already accepts for backports.

### What each later ticket needs

- **This ticket's pull request: authorization required.** Merging it makes `release.yml` live: every pushed `vX.Y.Z` or `vX.Y.Z-rc.N` tag runs it, and `publish` pushes to ghcr.io once the maintainer approves the `release` environment. The pull request must say so, and the maintainer merges it knowingly; the second box stays unticked until it does.
- **37:** the workflow's first live trigger is 37's annotated `v0.1.0` tag. Before pushing it, 37 creates the `v*` tag ruleset that restricts updates and deletions (**authorization required**) and confirms the environment above is unchanged. After the run, `just release-pin <digest from the run summary>` pins `deploy/release`, and `just deployment-check` confirms the render. The run is the first to exercise `verify`'s commit output and `publish`'s moved-tag refusal. If it fails after its push, a re-run stops at `present`: the release is published and only the digest is missing. To recover:
  1. Read the digest from the `Digest:` line of `docker buildx imagetools inspect ghcr.io/steven-cutting/knarr:0.1.0` (`digest_of_inspect` in `lib.sh` parses it).
  2. Pull `ghcr.io/steven-cutting/knarr@<digest>`.
  3. Check that `docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' ghcr.io/steven-cutting/knarr@<digest>` prints the tagged commit.
  4. Run `just release-pin <digest>`.
- **38:** an attested push makes the pinned digest an index's; `overlay_difference` accepts any `sha256:` digest, so only the pin changes. `id-token: write` and `attestations: write` on `publish` mean changing the scopes `test_workflows.py` allows.
- **14:** merged into this branch from main. Its Role rules, RoleBinding, projected token volume and env are in `deploy/base`, and the overlay inherits them with the same two-line difference. The canned base render in `test_deployment.py` was regenerated from the merged base, but it is a fixture for the difference rule, not a copy the base must match, so it need not follow later changes to the base.
- **34:** the install guide installs `deploy/release` at the release tag.
