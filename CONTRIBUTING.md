# Contributing to Knarr

Knarr is early and pre-1.0; the [README](README.md) states what the released controller does. Humans and agents work from local tickets, with one ticket per branch and worktree. Read [AGENTS.md](AGENTS.md) before starting: it is the canonical repository instruction file. The [handbook](docs/README.md) links the documentation, testing and agent contracts.

## Pick a ticket from the frontier

The [bootstrap index](.scratch/bootstrap/README.md) shows dependencies and execution waves; the tickets live in [.scratch/bootstrap/issues/](.scratch/bootstrap/issues/). The frontier is the set of unfinished tickets whose blockers have been completed with the evidence their acceptance criteria require. A wave describes the earliest possible start, so check the actual blockers before taking a ticket.

Read the ticket's context, non-goals, acceptance criteria, named decision records and every blocker's hand-back notes. Those notes can carry limitations or instructions that the dependency diagram does not show. If a **Blocked by** line changes, update both the diagram and the execution-wave table in the bootstrap index.

The existing status labels describe different states:

- **ready-for-agent** means an agent can do the work once the blockers are satisfied. It does not prove the blockers are complete.
- **needs-human** means the ticket needs a live maintainer session or an external prerequisite. Arrange that session before making the decisions the ticket reserves for it.
- **implemented** records completed implementation; read its qualifications and hand-back notes for verification still outstanding.
- **done**, **verified**, or **implemented and verified** records completion supported by the ticket's checked acceptance criteria and evidence. Read any stated limitations before relying on the result.
- **round 2** qualifies a ticket as later work; it is not permission to start it during bootstrap.

Keep progress and blockers in the ticket as work proceeds. Tick acceptance boxes as evidence lands. Do not mark a ticket complete while required verification remains open.

## Create the ticket worktree

Use one ticket per worktree. Name its branch after the ticket file without `.md`: `.scratch/bootstrap/issues/12-maintainer-docs.md` uses `12-maintainer-docs`.

Before creating a branch, confirm local `main` includes the completed blockers. If it needs refreshing from the remote, obtain authorization for `git fetch` or `git pull` first. For a ticket whose branch and worktree do not yet exist, run this example from the primary checkout:

```sh
git worktree add -b 12-maintainer-docs ../knarr-12-maintainer-docs main
cd ../knarr-12-maintainer-docs
```

Check `git worktree list` first. If the ticket already has a worktree, use that worktree and branch. Preserve changes you did not author.

Follow [Getting started](#getting-started), below, for prerequisites and `just initialize`, then run `just check`. Obtain the first-run network grant before initialization. Rerunning initialization after a pin change also needs authorization for its network access.

Never install hooks from a linked worktree: all worktrees share `.git/hooks`. `just initialize` detects linked worktrees and skips hook installation with a notice. A maintainer installs hooks by initializing the primary checkout; agents need explicit authorization before acting there on the shared hooks or using the network. A linked worktree can run the gate without installing hooks.

Tracked bootstrap tickets and evidence belong in `.scratch/bootstrap/`. Temporary experiments and review output go in `ai_tmp/`, which is ignored and never committed.

## Getting started

You need [pixi](https://pixi.sh) 0.81.0 or later, git, curl and a POSIX shell. pixi installs everything else from `pixi.lock`: Gleam, Erlang/OTP, `just`, Python and every gate tool ([Decision 0003](docs/decisions/0003-tool-manager.md)).

From a fresh clone, run one command:

```sh
just initialize
```

Any recent `just` works; 1.51 and the pinned 1.58 are known to. Without one, run `sh scripts/initialize.sh`, which is exactly what the recipe runs. Afterwards the pinned `just` is at `.pixi/envs/default/bin/just`. `just initialize` is the one first-run command:

- It installs the pixi environment, exactly as `pixi.lock` pins it.
- It downloads the tools conda-forge lacks into `.tools/bin`, refusing any whose sha256 differs from `tools.txt`.
- It downloads Gleam's hex packages.
- In the primary checkout, it installs the pre-commit hook.

It never formats, stages, commits or pushes, and it is safe to rerun. Rerun it after a pull that moves a pin in `pixi.lock` or `tools.txt`. Until you do, `just check` fails at `env-check` rather than running the old tools.

**Repository initialization needs network; `just check` runs offline.** An agent needs an explicit network grant before the first run of `just initialize`. Each later network action needs its own authorization; see [Authorization](#authorization).

Then run the gate:

```sh
just check
```

`just --list` shows every recipe in seven groups: setup, develop, format, check, audit, cluster and release.
The [local cluster guide](docs/how-to/local-cluster.md) builds the controller's image and deploys its chart on kind.

## The gate

`just check` is read-only. It runs each recipe in the check group through `scripts/checks/run_project_check.py`, which snapshots every tracked and untracked-unignored file first. The gate fails on the first recipe that changes any of them, even when that recipe passed ([Decision 0004](docs/decisions/0004-gate-checkers.md)).

Recipes may write ignored paths, such as `build/` and the `<title>.new` a failing snapshot test leaves; `just initialize` writes nothing else. Four recipes change tracked files on purpose, all outside the gate:

- `just fix` repairs formatting and lint findings.
- `just snapshots-review` and `just snapshots-accept` accept snapshot changes into `test/birdie_snapshots/`.
- `just birdie` runs any other birdie command. `just birdie reject` and `just birdie stale delete` can change tracked snapshot files.

The pre-commit hook runs the read-only config, `.pre-commit-config.yaml`. `just fix` runs `.pre-commit-fix.yaml`. The [testing reference](docs/reference/testing.md) covers the snapshot recipes and how `just check` stays read-only around them.

[CI](.github/workflows/ci.yml) runs `just check` on every pull request and
every push to `main`, using the same locked environment and `just initialize`
as contributors. Its aggregate `check` fails if any gate job fails, is cancelled,
or is skipped. `check` is the only required status check on `main`.
Administrators are exempt, so it binds pull requests but not an owner's
direct push.
Add only required gate jobs to the aggregate's `needs` list. The initial kind
and kwok jobs stay outside it; the kind smoke job must demonstrate stability
for a stated period before becoming required (tickets 10 and 13).

## Audits and pins

The separate [audit](.github/workflows/audit.yml) runs on Mondays at 06:00 UTC
and on manual dispatch, outside the required gate:

- `just links-audit` checks that remote links still resolve.
- `just hex-audit` checks the hex packages and the OTP pin against OSV.dev
  advisories.
- `just image-scan` runs grype over the OS packages of the image
  `just image-build` builds. It does not read the image's conda runtime
  environment.
- `just runtime-scan` copies that runtime environment out of the image and
  runs grype over its conda packages as a directory. It fails when grype
  catalogues no conda package.

Remote availability and published advisories change without a commit
([Decision 0014](docs/decisions/0014-dependency-updates-and-audit.md)).

Moving a pin is a manual edit, never a recipe. Renovate is configured to
propose most of these edits as pull requests, held until ticket 44 activates
it ([Decision 0014](docs/decisions/0014-dependency-updates-and-audit.md)). A
proposal lands like any other change, and a reviewer checks the same steps:

- **A conda package:** edit its `==` line in `pixi.toml`, run `pixi update <package>`, read the `pixi.lock` diff, commit both files, and rerun `just initialize`.
- **A tools.txt download:** replace both platforms' lines with the new URL and sha256, and rerun `just initialize`.
- **A Gleam dependency:** edit `gleam.toml`, run `gleam deps download` (or `gleam deps update`), read the `manifest.toml` diff, and commit both. The gate fails while the two disagree. The fake worker fixture is a second Gleam project, so a package it shares with knarr moves in `fixtures/fake_worker/gleam.toml` and its `manifest.toml` too, through `gleam deps download` there; `test_fake_worker_manifest.py` fails while the two projects lock different versions.

## Specifications

Allium modules live in [docs/specs/](docs/specs/knarr.allium), configured by
`[allium] specs` in `checks.toml`. The root module is a skeleton; later tickets
add behaviour clauses. `just initialize` installs Allium 3.6.1 from the
checksum pins in `tools.txt`.

- `just check-specs` fails on every diagnostic, including informational ones.
- `just analyse-specs` fails on every finding or diagnostic.
- `just plan-spec docs/specs/knarr.allium` prints the module's test plan and obligation count.

Both checks run inside `just check`. They read the JSON reports because
Allium's exit status alone does not establish that a spec is clean. Planning
is a development command and is not part of the gate.

## Authorization

[AGENTS.md](AGENTS.md#invariants) requires explicit authorization for each action that leaves the worktree. Approval for one action does not authorize the next. In particular, obtain authorization before:

- Network access, including `git fetch`, `git pull`, `just initialize`, `gleam deps download`, `just links-audit`, `just hex-audit`, `just image-scan`, `just runtime-scan`, `just audit-install`, `just observability-up` and image or tool downloads.
- Pushing a branch or tag, or running any `gh` command, including reads.
- Registry operations or operations against a non-local cluster.
- Opening, updating or merging a pull request, or changing repository settings.

The local gate runs offline. Permission to run it or to commit locally does not authorize a push, a pull request, or a cluster deployment. If an agent sandbox blocks the gate's local sockets, request the execution permission needed for that local check and record the limitation; do not weaken checks to make them pass.

## Make and verify the change

Stay within the ticket's acceptance criteria and non-goals. Specifications under [docs/specs/](docs/specs/knarr.allium) decide controller behaviour. A new behaviour starts with the specification; changing Gleam code requires a failing test first and the checks named in AGENTS.md. The [testing reference](docs/reference/testing.md) covers test boundaries and snapshots.

For handbook changes, follow the [documentation contract](docs/reference/documentation-contract.md) and [how-to guide](docs/how-to/README.md). Each Markdown or HTML page under `docs/` needs matching manifest metadata and navigation from the docs index. Root maintainer documents and bootstrap evidence are excluded from the handbook manifest.

Use `just --list` to find supported recipes. Run the relevant narrow checks while working, then the full `just check` before handing back. A check reports problems without repairing files. When it fails, rerun the named recipe, fix the first failure at its source, and confirm the full gate passes. Review the whole diff, including accepted snapshots if any, before committing.

Finish the ticket with hand-back notes recording what changed, the checks and evidence gathered, any remaining limitations, and what downstream tickets need. Commit the completed change on the ticket branch. Hand back only when `just check` ends with "All checks passed and the worktree is unchanged." and `git status --short` is empty.

## Get the change merged

After separate authorization to push and open a pull request, submit the ticket branch against `main`. Push the ticket branch named in the authorization; permission to push that branch does not authorize pushing directly to `main`. Describe the resulting behaviour, validation and material limitations, and link the local ticket and relevant decisions. Keep security reports in the private channel described in [SECURITY.md](SECURITY.md).

Pull requests to `main` require the aggregate CI status `check` to pass. External link audits and the initial cluster jobs are outside that required gate; [The gate](#the-gate) explains the CI setup. Maintainers review the change and merge it with authorization. Administrators can bypass protection under the existing repository policy, so the contributor workflow uses a pull request and the passing required check.

[Decision 0012](docs/decisions/0012-release-and-packaging.md) decides release versioning, publishing and the changelog's release headings; tickets 36 to 40 carry it out. User-facing worker, KEDA and operations guides belong to [ticket 34](.scratch/bootstrap/issues/34-user-guides.md).
