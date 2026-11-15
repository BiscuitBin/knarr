---
title: "Decision 0004: Gate checkers"
kind: "decision"
audience: [maintainer, agent]
canonical_for: [decision_gate_checkers]
requires: []
---

# Decision 0004: Gate checkers

Amended by [Decision 0017](0017-nix-tool-manager.md): the checkers' Python, pytest and ruff, and the Node and markdown-it the docs validator borrows from markdownlint-cli2, now come from the Nix tool environment behind `.nix/tools`, where this record says pixi. Allium, ripsecrets and editorconfig-checker come from it too, where this record says `.tools/bin` and `tools.txt`. `run_allium.py` checks the binary against the version `nix/allium.nix` pins, read from the environment's version record. The choice of checkers and the snapshot contract are unchanged.

Adapted on 2026-10-07 from libpawdoku's [Decision 0004: Hook runner and checkers](https://github.com/steven-cutting/libpawdoku/blob/51d8b55ac4f769a6a4d66abacb9642a7d4062127/docs/decisions/0004-hook-runner-and-checkers.md) at commit `51d8b55`. There the checkers came from the `biscuit-games-tooling` package, pinned as a git dependency. Here that pin is reversed: knarr copies what it keeps, and depends on no package.

## Context

libpawdoku's gate ran six console scripts from [biscuit_games_tooling](https://github.com/steven-cutting/biscuit_games_tooling):

- the gate runner, which snapshots the worktree and aborts if any recipe changes it
- the docs validator
- the agents validator
- the Allium installer
- the Allium runner, which reads JSON because the binary's exit code cannot be trusted
- the ripsecrets wrapper, which keeps matched secrets out of logs

knarr does not depend on that package. This record decides, for each checker, whether knarr copies it, rewrites it or drops it. It also records where each one came from and under what licence, and it tells lanes 03, 06, 07 and 09 what each needs to wire its checker in. [Decision 0003](0003-tool-manager.md) already settled where runtimes come from: one `pixi.toml`, plus `tools.txt` for checksum-pinned downloads into `.tools/bin`, and no second installer. 0003 also left editorconfig-checker to this record.

The evidence was gathered on 2026-10-07 with pixi 0.81.0 on osx-arm64. The scripts and transcripts are in [`.scratch/bootstrap/evidence/02/`](../../.scratch/bootstrap/evidence/02/README.md).

## Decision

Copy four checkers, rewrite one in POSIX shell, drop the installer, and keep editorconfig-checker. Python joins `pixi.toml`'s default feature.

### One row per checker

Paths are at biscuit_games_tooling `v0.3.0`, under `src/biscuit_games_tooling/`.

| Checker | Decision | Runtime | Lane |
| --- | --- | --- | --- |
| `run_project_check.py`, with `root()` from `_project.py` | **Copy.** The snapshot guarantee is kept as is. One adaptation: the recipe list comes from the Justfile as arguments, not from a config file. | pixi Python | 03 |
| `validate_docs.py` | **Copy.** Predicates come from `checks.toml`, not `pyproject.toml`. | pixi Python | 06 |
| `validate_agents.py` | **Copy.** The phrase list, adapters and skill bridges move to `checks.toml`. `runes` is gone. | pixi Python | 09 |
| `install_allium.py` | **Drop.** Two `tools.txt` lines replace it, installed by 0003's recipe. | 0003's `tools.txt` installer | 07 |
| `run_allium.py` | **Copy.** All of its JSON checks are kept. The specs path comes from `checks.toml`, and the version check reads `tools.txt`. | pixi Python | 07 |
| `run_ripsecrets_redacted.py` | **Rewrite** as a 21-line POSIX shell script. shellcheck lints it, and the hook needs no interpreter. | sh | 03 |
| editorconfig-checker (not a biscuit checker) | **Keep.** It enforces 03's `.editorconfig`. | `.tools/bin` | 03 |

The reasons, checker by checker:

- **The gate runner** is the one place the read-only guarantee is enforced, and 0003's `manifest.toml` backstop depends on it. It is 151 lines of standard-library Python that already works. A rewrite would have to reproduce its snapshot exactly, and Python's `hashlib.file_digest` and `tomllib` make that easy where POSIX shell does not.
- **The two validators** are 592 lines between them. libpawdoku 0004 found no implementation in any other language, and the docs and agent contracts in 06 and 09 are written against them. They are knarr's only reason to ship Python. That cost (100 MB, below) is accepted rather than paying for two rewrites before the gate can pass.
- **The Allium installer** duplicates 0003's `tools.txt` installer: a pinned version, a sha256 per platform, a single-member extract into `.tools/bin`. Keeping it would make two installers and two places that own a pin.
- **The Allium runner** carries hard-won knowledge of the binary's behaviour: `check` exits 0 on an `info` diagnostic, `analyse` ignores diagnostics, status 2 means no input, and the output is back-to-back JSON objects. Rewriting it would rediscover all of that.
- **The ripsecrets wrapper** is 29 lines whose logic is "run it, discard its output, say one of two things". In shell it needs no Python environment when prek runs it from a hook.
- **editorconfig-checker** is the only thing that checks the `.editorconfig` 03 writes. It is a single Go binary already pinned in 0003.

### Provenance and licence

The source is [github.com/steven-cutting/biscuit_games_tooling](https://github.com/steven-cutting/biscuit_games_tooling) at tag `v0.3.0`, commit `6c5c07f6bec86e86b3930dfa41392e4b440e8c85` (2026-09-22). Upstream `main` (`6245d5d`) changes only `README.md` and `CHANGELOG.md` after the tag, so `v0.3.0` is the newest source ([provenance.txt](../../.scratch/bootstrap/evidence/02/provenance.txt)).

| Source file | sha256 at `v0.3.0` | Lines | Becomes |
| --- | --- | --- | --- |
| `_project.py` | `f03dac86…4be62c0a` | 64 | `scripts/checks/_project.py`, reduced (below) |
| `run_project_check.py` | `aef50384…ab3faaac` | 151 | `scripts/checks/run_project_check.py` |
| `validate_docs.py` | `3a3af978…b18795eb` | 332 | `scripts/checks/validate_docs.py` |
| `validate_agents.py` | `24c59cae…4807d350` | 260 | `scripts/checks/validate_agents.py` |
| `run_allium.py` | `e0c5d7fc…da93ad19` | 213 | `scripts/checks/run_allium.py` |
| `run_ripsecrets_redacted.py` | `a9852cdd…0ff2039e` | 29 | `scripts/checks/ripsecrets-redacted.sh`, rewritten |
| `install_allium.py` | `3d4c8f24…56549a4b` | 238 | nothing; only its checksums are carried |

The full digests are in [provenance.txt](../../.scratch/bootstrap/evidence/02/provenance.txt).

**Licence.** Upstream has no `LICENSE`, `NOTICE` or `COPYING` file, and its `pyproject.toml` declares no licence. GitHub reports none either. knarr's maintainer is the copyright holder of biscuit_games_tooling. As copyright holder, the maintainer licenses every file this record copies or rewrites to knarr under Apache-2.0, knarr's own licence. This record is that grant. A `NOTICE` file is not needed, because the copyright holder is the same.

### The snapshot guarantee is kept as is

`run_project_check.py` is copied without changing what it compares. 03 shows that the copy keeps each point of this contract:

- **Paths.** The path set is `git ls-files -z --cached --others --exclude-standard`: every tracked path and every untracked path that is not ignored.
- **Digests.** Each path is hashed by what it is:
  - a regular file is `<mode in octal>:<sha256 of its content>`
  - a symlink is `symlink:<sha256 of its target>`, never followed
  - a path that has gone is `missing`, and anything else is `special`
- **Status.** The output of `git status --porcelain=v1 -z --untracked-files=all` is part of the snapshot, so a change to the index or to what Git sees as untracked counts as a change.
- **When.** The runner snapshots once before the first recipe. It compares after every recipe, `check-clean` included, and aborts on the first change, naming each changed path. A changed worktree fails even when the recipe exited 0. A recipe that fails without changing anything returns its own status.
- **Modes.** `run <recipe>...` runs the gate. The standalone `clean [baseline]` mode is kept: with a baseline file it compares against it, and without one it asserts that `git status` is empty (or accepts a repository with no commit yet).
- **Locking.** The runner's own git calls run with `GIT_OPTIONAL_LOCKS=0`, so taking a snapshot never refreshes the index. The recipes it runs do not inherit this setting.
- **Dependents.** 0003's `manifest.toml` backstop relies on this runner to catch any rewrite the pre-check misses.

The one adaptation is the recipe list. Upstream read it from `[tool.biscuit-games-tooling] recipes` in `pyproject.toml`, with a default list from another project. The copy takes it from its arguments instead: the Justfile's `check` recipe runs `python3 scripts/checks/run_project_check.py run <recipe>...`, and the runner appends `check-clean`. The list lives once, in the Justfile, beside the recipes it names. `run` with no recipes refuses with status 2, so a gate that ran nothing cannot pass.

The runner calls the last step as `just check-clean <baseline.json>`. So the Justfile's `check-clean` recipe takes one optional parameter, `baseline`, with an empty default, and passes it on as `run_project_check.py clean <baseline>`. A recipe without the parameter makes every `just check` fail at its last step. A recipe that drops the argument asserts that `git status` is empty instead, so `just check` would fail on any uncommitted work.

### `checks.toml`

The copied checkers read one root file, `checks.toml`, with Python's `tomllib`. `_project.py` keeps `root()` and gains one loader, `table(root, name)`. It fails closed:

- a missing `checks.toml` is an error, never an empty default
- a missing table that a checker asks for is an error

Each checker then refuses its own empty values. validate_agents refuses an empty `required_guidance`. Upstream's `settings()` returned `{}` for a missing `pyproject.toml`, which would let the agents validator pass with no phrases at all.

03 writes the loader and `checks.toml`, though no checker of 03's reads it. 03's tests cover both refusals, so the loader is proven before 06, 07 and 09 depend on it. That way no two of those lanes write it in parallel.

Each lane writes its own table. This is the shape all four agree on:

```toml
# Configuration for the copied gate checkers in scripts/checks/ (Decision 0004).
# Every table a checker reads is required; nothing defaults to empty.

[docs]
# The predicates a page's `requires` may name, each true when enabled. Only the
# boolean true enables one. An empty table is valid: knarr has no feature
# toggles yet. (06)
predicates = {}

[agents]
# Phrases AGENTS.md must contain, compared case-insensitively. Must not be
# empty. 09 owns the final list. (09)
required_guidance = ["untrusted", "just check", "explicit authorization", "ai_tmp/"]
# Committed files under a managed directory that are neither skills nor
# adapters, permitted without being required. Upstream tolerated
# .claude/settings.json; 09 lists what knarr commits.
tolerated = [".claude/settings.json"]

# Each agent runtime that gets skill bridges, and the directory its bridges
# live in. The bridge body's relative path to .agents/skills/ is derived from
# this directory's depth. (09)
[agents.bridges]
claude = ".claude/skills"

# Byte-pinned adapter files: path = exact content. (09)
[agents.adapters]
"CLAUDE.md" = "@AGENTS.md\n"
".github/copilot-instructions.md" = """..."""

[allium]
# What `allium check` and `allium analyse` are given; also where run_allium
# looks for the modules the report must cover. (07)
specs = "docs/specs/"
```

How each checker changes to read it:

- **validate_docs** reads `[docs] predicates` in place of `[tool.biscuit-games-tooling] predicates`, through `_project.predicates(root)`. That function is kept, rewritten to read `checks.toml`. It still returns the declared predicates and the subset that is enabled, and only the boolean `true` enables one. A quoted `"false"` must not count as enabled. Ticket 06 adds the HTML exception: `.html` and `.htm` pages use manifest-only metadata, join discovery and reachability through `<a href>` links, and leave HTML fragments and resources to lychee. Markdown frontmatter, heading, word-count, and content-marker rules do not apply to HTML. Adversarial review of 06 also led to strict manifest field types, file-read diagnostics, an explicit navigation-root requirement, and recognition of scheme-qualified and protocol-relative URLs. Markdown navigation and headings are parsed through `render_markdown.mjs`, using the `markdown-it` package and Node runtime already shipped in the pinned markdownlint-cli2 environment. This replaces raw-text regex extraction, which admitted links in comments and code while refusing valid reference links and anchors; it adds no package installer or independent version pin.
- **validate_agents** reads four things from `[agents]`, each of which was a constant upstream:
  - `required_guidance` replaces `REQUIRED_GUIDANCE`
  - `adapters` replaces `ADAPTERS`
  - `bridges` replaces `PROVIDERS`
  - `tolerated` replaces `TOLERATED`

  Upstream's `PROVIDERS` (`claude`, `codex`) was two things at once: the bridge directories (`.claude/skills`) and the managed directories (`.claude`, the whole provider directory). Both now derive from `bridges`. A bridge directory is the value as given. Its managed directory is the value's first path component, so `.claude/skills` manages all of `.claude/`, as upstream did. `.agents` stays managed whatever `bridges` says. Any committed file there that is neither a bridge nor listed in `tolerated` still fails the gate. A committed `.claude/settings.json` therefore goes in `tolerated`, as it was upstream. A Copilot adapter (`.github/copilot-instructions.md`) is an adapter, not a bridge. Where Copilot's skill bridges live, if anywhere, is 09's call. The `CODEX.md is forbidden` check goes, because knarr supports no Codex runtime. Ticket 09 added what upstream never had: a skill named in `skills-lock.json` is vendored, exempt from the house body and two-key rules, and every file under it is hashed against the lock in both directions; a read-only `lock` mode prints the lock. The [agent contract](../reference/agent-contract.md) is the record of those rules.
- **run_allium** reads `[allium] specs` in place of its `SPECS` constant.

**A starting phrase list for 09.** Upstream's list was `untrusted`, `just check`, `explicit authorization`, `ai_tmp/`, `docs/specs/` and `runes`. `runes` named the Svelte games' reactivity rule and is gone. The first four carry over unchanged. 09's invariants suggest these:

- `sans-IO` (effects behind sans-IO boundaries)
- `FFI` (confined to named modules)
- `supervised` (every process supervised)
- `annotations it owns` and `replica counts` (the controller rule)
- `worktree` (one ticket per worktree)
- the specs directory, once 07 fixes it

09 owns the final list, and records it in `checks.toml`. So does its choice of adapters and bridges. The ticket names Claude and Copilot, not Codex.

### Allium: the installer is dropped, the runner reads `tools.txt`

`install_allium.py` goes. allium-tools 3.6.1 joins `tools.txt` with these two lines. The checksums are the ones v0.3.0 carried. Both match GitHub's recorded asset digests, and each archive holds a single member, `allium` ([allium.txt](../../.scratch/bootstrap/evidence/02/allium.txt)):

```text
allium 3.6.1 linux-64 https://github.com/juxt/allium-tools/releases/download/v3.6.1/allium-x86_64-unknown-linux-gnu.tar.gz e00c99ae234b10207719257a70e7c2dcad73060864468cd293fb7ad40524e970 allium
allium 3.6.1 osx-arm64 https://github.com/juxt/allium-tools/releases/download/v3.6.1/allium-aarch64-apple-darwin.tar.gz ecfae02fcf8e60475a014944183158ccde4104f6f0223e1bf91f98519fcb19eb allium
```

The release's `SHA256SUMS.txt` covers only the editor extension and the language server, which is why v0.3.0 hashed the binaries itself. 3.6.1 is still the newest release. 07 may move the version, and must then rehash both assets.

`run_allium.py` keeps all of its checks:

- it reads the JSON report, never the exit code
- status 2 (`NO_INPUTS`) means no specification was resolved, and fails the gate
- a block missing `diagnostics` or `findings` is refused, because absence is not emptiness
- the modules the report names must equal the `.allium` files under the specs path
- an empty report with a non-zero status is refused

Two things change:

- The specs path comes from `[allium] specs`.
- Its pre-run version check no longer imports `install_allium`. It reads the `allium` line for the host platform from `tools.txt` and takes the version column. It then compares that with the second field of `<root>/.tools/bin/allium --version` (which prints `allium 3.6.1 (language versions: 1, 2, 3)`). It runs that binary by path, never from `PATH`. A mismatch or a missing binary fails with "run just initialize". So the pin has one owner, `tools.txt`, and the runner only reads it.

### The ripsecrets wrapper, rewritten

[ripsecrets-redacted.sh](../../.scratch/bootstrap/evidence/02/ripsecrets-redacted.sh) is the proposed rewrite, and 03 copies it to `scripts/checks/`. It keeps the original's behaviour:

- output suppressed, exit status kept
- a fixed message on status 1, and another naming the status on any other non-zero
- a refusal when the binary is missing

[ripsecrets.txt](../../.scratch/bootstrap/evidence/02/ripsecrets.txt) shows each case against 0003's pinned ripsecrets 0.1.11. A planted token gives status 1 and the fixed message, and the token appears in neither stream.

Four deliberate differences from the Python original:

- **Status 2 for a refusal.** The original's refusal exits 1, the same as a finding. A refusal now exits 2 so it never reads as a finding.
- **Only the pinned binary.** The original took ripsecrets from `PATH`. The wrapper runs `<root>/.tools/bin/ripsecrets` and nothing else, and the case with another ripsecrets on `PATH` shows that. This also settles how the hook reaches the binary. Hooks run without the Justfile's `PATH`, so the wrapper finds the binary itself and the hook entry needs no `PATH`.
- **Every argument is a path.** The wrapper passes `--` before the paths, so a staged file named `-x` is scanned, not read as a flag. The wrapper itself passes ripsecrets no flags. A flag the hook needs, such as `--strict-ignore`, goes inside the wrapper before `--`, not in the hook entry.
- **The refusal message** says "run just initialize", knarr's first-run command, not `just install-hooks`.

### editorconfig-checker is kept

It enforces the `.editorconfig` 03 writes, and nothing else checks that file. It runs from `.tools/bin` as a `repo: local`, `language: system` hook, or as a recipe inside `just check`. 03 adds both platforms' lines from [0003's evidence](../../.scratch/bootstrap/evidence/01/tools.txt), along with ripsecrets' lines.

### The Python stack

These three join `pixi.toml`'s default feature, after `shellcheck`. 03 writes them:

```toml
python = "==3.14.8"
pytest = "==9.1.1"
ruff = "==0.16.10"
```

- **python** is pinned to 3.14, not the newest. conda-forge's newest python is 3.15.0rc3, a release candidate. The checkers were written for 3.14 (upstream `requires-python = ">=3.14"`, ruff `target-version = "py314"`), and 3.14.8 is the newest 3.14 on both platforms.
- **pytest** 9.1.1 is the version upstream tested with.
- **ruff** 0.16.10 is newer than upstream's 0.16.2.

All three solve with 0003's manifest on both platforms. They grow the osx-arm64 `default` environment from 521 MB to 622 MB. `python3` resolves through the `PATH` export alone, and `tomllib` and `hashlib.file_digest` import ([python.txt](../../.scratch/bootstrap/evidence/02/python.txt)). The checkers use the standard library only, so the environment needs no PyPI package. The `runtime` environment and image are unaffected, because python is in the default feature only.

pytest and ruff come in because knarr now ships `.py` files. Each lane proves its copied checker with a pytest test that includes a failing fixture: a tree the checker must refuse. ruff checks every copied file. knarr has no `pyproject.toml`, so ruff's configuration goes in `ruff.toml`, starting from upstream's rule selection, and 03 picks pytest's configuration file.

Running Python in the worktree writes `__pycache__/`, `.pytest_cache/` and `.ruff_cache/`. If Git could see them, the snapshot runner would abort the gate on its own first run. 03 gitignores all three. The Justfile also exports `PYTHONDONTWRITEBYTECODE=1`.

### Copy conventions

- Copies go in `scripts/checks/`. The Justfile runs each one as `python3 scripts/checks/<name>.py`, and each imports `_project` as a sibling module.
- Each copied or rewritten file starts with a header comment naming three things: the source repository, the commit, and the original path. It also carries `SPDX-License-Identifier: Apache-2.0`.
- `_project.py` keeps `root()`, gains the `checks.toml` loader, and keeps `predicates()` rewritten to read `[docs]`. `DEFAULT_RECIPES`, `settings()` and `recipes()` go.
- Each lane copies only its own checker, so no checker arrives before the lane that runs it. The exception is the shared `_project.py`, which 03 writes whole.
- Tests live beside the checkers in `scripts/checks/tests/`.

## Verification

Each script exits non-zero on an unexpected result. The [README](../../.scratch/bootstrap/evidence/02/README.md) gives the command to rerun them all.

- **Provenance.** [provenance.txt](../../.scratch/bootstrap/evidence/02/provenance.txt) shows that `v0.3.0` is `6c5c07f` locally and on the remote, and that nothing under `src/` changed after it. It also shows that no licence file or field exists, and gives each source file's sha256 and line count.
- **Python.** [python.txt](../../.scratch/bootstrap/evidence/02/python.txt) shows the three pins on both platforms, the solve with and without them, the 100 MB difference, and the imports.
- **Allium.** [allium.txt](../../.scratch/bootstrap/evidence/02/allium.txt) shows both checksums matching v0.3.0 and GitHub, the single-member archives, `allium 3.6.1` running on macOS, and the two `tools.txt` lines.
- **ripsecrets.** [ripsecrets.txt](../../.scratch/bootstrap/evidence/02/ripsecrets.txt) shows thirteen cases, among them a control that proves bare ripsecrets prints the planted token. The wrapper was built test-first against these cases, and shellcheck 0.11.0 passes it.

Not verified here:

- No linux-64 binary ran. Linux is covered by conda-forge solves and release-asset hashes only.
- The copied Python checkers were not run in knarr. Each lane proves its own with the pytest tests above.

## Consequences

knarr ships Python: the original five checker files were about 1,000 lines before tests, with standard-library imports only. The adapted docs checker also invokes a small JavaScript bridge to the parser bundled with the already-pinned markdownlint-cli2 tool; there is no separate npm installation. Contributors need nothing new, because pixi provides python, pytest and ruff. The default environment is 100 MB larger on osx-arm64.

Upstream fixes no longer arrive as a moved pin. A fix in biscuit_games_tooling after `v0.3.0` reaches knarr only if someone copies it, and the header comment says what to compare against. In return, knarr can adapt its copies freely.

Every checker's configuration is in `checks.toml`, so moving a phrase or a predicate is a one-line change that the gate checks. The pins stay where 0003 put them: `pixi.toml` for the Python stack, `tools.txt` for allium, ripsecrets and editorconfig-checker.

## What would reopen this

- **Upstream ships a fix knarr needs.** If biscuit_games_tooling fixes a bug in a copied checker, knarr copies the fix. If that happens often, the copy-and-adapt choice is reopened.
- **The validators become cheap to rewrite.** If Gleam or shell versions of the docs and agents validators become simpler than carrying Python, knarr drops Python. The runner and the Allium runner would follow.
- **conda-forge carries ripsecrets, editorconfig-checker or allium.** Each moves from `tools.txt` into the manifest, as 0003 already says. That is a pin move, not a new decision.
- **allium's exit code becomes trustworthy.** If `check` and `analyse` both exit non-zero exactly when the JSON reports something, `run_allium` could shrink to an exit-code check.

## Related pages

- [Decision 0003: Tool manager](0003-tool-manager.md)
- [Evidence for this record](../../.scratch/bootstrap/evidence/02/README.md)
- libpawdoku [Decision 0004: Hook runner and checkers](https://github.com/steven-cutting/libpawdoku/blob/51d8b55ac4f769a6a4d66abacb9642a7d4062127/docs/decisions/0004-hook-runner-and-checkers.md)
- [biscuit_games_tooling at v0.3.0](https://github.com/steven-cutting/biscuit_games_tooling/tree/6c5c07f6bec86e86b3930dfa41392e4b440e8c85)
