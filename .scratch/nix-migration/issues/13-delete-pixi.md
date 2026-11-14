# 13: Delete pixi

**Context:** After [10](10-nix-becomes-the-gate.md) nothing uses pixi by default, after [11](11-runtime-scan-nix-closure.md) the runtime scan reads the Nix closure, and after [12](12-renovate-reads-flake.md) Renovate no longer tracks it. The pixi backend, its lock and the `tools.txt` installer are still in the tree. This is the contract step of the round.

**What to build:** The repository has one way to get its tools.

- `pixi.toml`, `pixi.lock`, `tools.txt`, the installer script and its tests are deleted, with their git attributes, ignore entries and tool excludes.
- The seam loses the pixi backend and the `KNARR_TOOLS` selector. `lock-check` and `env-check` lose their pixi halves, and the Allium runner reads its expected version from the held-versions file.
- The temporary test that held `pixi.toml`'s `erlang` pin equal to the held-versions file is deleted.
- The checker suite's groups and shared-input list stop naming the deleted files.
- `just initialize` refuses when a leftover `.pixi/` or `.tools/` directory exists, and says to remove it. The bootstrap evidence scripts CI runs prepend those directories, so a stale copy would shadow the Nix tools.
- A last sweep of live text: comments, recipe descriptions, hook-config headers and any handbook page still naming pixi.

Recorded facts are not rewritten: everything under `.scratch/**/evidence/`, the hand-back notes of done tickets, historical changelog entries and the bodies of decision records keep their pixi text.

**Non-goals:** Uninstalling pixi from anyone's machine: older worktrees and branches still need it. Rewriting history or evidence. Any change to tool versions.

**Blocked by:** 10, 11, 12

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] A `git grep` for `pixi`, `conda` and `tools.txt`, with a written keep-list (evidence, done hand-backs, changelog history, decision bodies and amendment notes), finds nothing outside the list. The ticket records the command, the keep-list and the output.
- [ ] Every link to a deleted file is repointed or removed, and the offline link check passes.
- [ ] `just initialize` exits non-zero with a clear message when `.pixi/` or `.tools/` exists, and a test covers it.
- [ ] No recipe, script or workflow reads `KNARR_TOOLS`.
- [ ] `CHANGELOG.md` records the removal, and the round README's "Two backends until 13" section is marked as ended.
- [ ] **Authorization required:** a push. `ci.yml` passes on the pull request.
- [ ] `just test-checkers-all` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
