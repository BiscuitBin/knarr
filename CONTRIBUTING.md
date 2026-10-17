# Contributing to Knarr

Knarr is pre-MVP. Humans and agents work from local tickets, with one ticket per branch and worktree. Read [AGENTS.md](AGENTS.md) before starting: it is the canonical repository instruction file. The [handbook](docs/README.md) links the documentation, testing and agent contracts.

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

Follow the README's [getting started instructions](README.md#getting-started) for prerequisites and `just initialize`, then run `just check`. Obtain the first-run network grant before initialization. Rerunning initialization after a pin change also needs authorization for its network access.

Never install hooks from a linked worktree: all worktrees share `.git/hooks`. `just initialize` detects linked worktrees and skips hook installation with a notice. A maintainer installs hooks by initializing the primary checkout; agents need explicit authorization before acting there on the shared hooks or using the network. A linked worktree can run the gate without installing hooks.

Tracked bootstrap tickets and evidence belong in `.scratch/bootstrap/`. Temporary experiments and review output go in `ai_tmp/`, which is ignored and never committed.

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

Pull requests to `main` require the aggregate CI status `check` to pass. External link audits and the initial cluster jobs are outside that required gate; the README's [gate section](README.md#the-gate) explains the CI setup. Maintainers review the change and merge it with authorization. Administrators can bypass protection under the existing repository policy, so the contributor workflow uses a pull request and the passing required check.

[Decision 0012](docs/decisions/0012-release-and-packaging.md) decides release versioning, publishing and the changelog's release headings; tickets 36 to 40 carry it out. User-facing worker, KEDA and operations guides belong to [ticket 34](.scratch/bootstrap/issues/34-user-guides.md).
