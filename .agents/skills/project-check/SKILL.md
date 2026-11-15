---
name: project-check
description: Bring a worktree to the state where the full gate runs, and interpret what it reports.
---

# Run the full gate

1. Read `AGENTS.md`. The `Justfile` is the only supported interface to the checks; do not assemble an equivalent pipeline by hand.
2. Check the prerequisite exists: the Nix tool environment behind `.nix/tools`, whose `bin` holds gleam, erlang, rebar3, just, python, allium and every other tool the gate runs. If it is missing, `just initialize` builds it. It downloads, so it is a network operation and needs explicit authorization before it runs, unless the task already grants it. It never stages, commits or pushes, and in a linked worktree it skips the hook step on its own.
3. Run `just check`. The runner snapshots the worktree, runs each check recipe in order, and fails on the first recipe that changes any tracked or untracked-unignored file, even when that recipe passed.
4. Read only the first failure. The recipes are ordered so that a later failure is often a consequence of an earlier one: `env-check` before the tools run, `docs-check` before `agents-check`, `build` before `test`.
5. A report that a recipe changed the worktree is a defect in that recipe, not in the change under test. Checks are read-only; `just fix` is where mutation belongs.
6. Hand a failing gate to the `fix-quality` skill rather than working around it.
7. Confirm with `git status --short` that the worktree is clean before reporting success. `just check` ends with "All checks passed and the worktree is unchanged." when it is.
