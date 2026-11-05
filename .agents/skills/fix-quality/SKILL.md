---
name: fix-quality
description: Diagnose and repair a failing quality gate at its root instead of suppressing the finding.
---

# Fix a failing gate

1. Read `AGENTS.md`, then reproduce with the narrowest recipe rather than the whole gate. `just check` names the recipe that failed; run that one alone.
2. Dispatch on which recipe failed:
   - `format-check` or `toml-check`: run `just fix`; never hand-format to match.
   - `build` or `test`: warnings are errors, so fix the code. A test that is already green proves nothing about new behaviour; a failing test is the clause it derives from, not an obstacle.
   - `manifest-check` or a report that gleam rewrote `manifest.toml`: `gleam.toml` and `manifest.toml` disagree. Run `gleam deps download`, read the `manifest.toml` diff, and commit both.
   - `lock-check` or `env-check`: `pixi.lock` disagrees with `pixi.toml`, or the installed tools differ from the pins. A pin move is a manual edit described in `CONTRIBUTING.md`; after a pull, rerun `just initialize`.
   - `docs-check`: a page is unregistered, unreachable, or its frontmatter disagrees with `docs/manifest.yml`. The list comparison is order-sensitive. Hand to the `review-docs` skill.
   - `agents-check`: a bridge under `.claude/skills/` has grown content, a managed file is missing or unexpected, a phrase left `AGENTS.md`, or a vendored file differs from `skills-lock.json`. Vendored bytes are never edited; see `docs/reference/agent-contract.md`.
   - `check-specs` or `analyse-specs`: hand to the `spec-change` skill. A diagnostic is a regression and a finding cannot be waived.
   - `test-checkers`: a checker's own test under `scripts/checks/tests/` fails. Fix the checker, never the fixture it refuses.
   - `lint`: the hook named in the output. typos, markdownlint and ruff findings are fixed by `just fix` where a fixer exists; shellcheck, lychee, actionlint and ripsecrets findings are fixed by hand at the source.
3. Distinguish an unreachable branch from an untested one. Defensive code no input can reach should be removed, not covered by a contrived test.
4. Never disable a gate to make a run green. A suppression is a last resort: one rule, one line, with a stated reason. A vendored path exclusion is never added to a hook config to hide a finding in a house file.
5. If a recipe changed the worktree, that is a defect in the recipe. Checks are read-only. Fix the recipe.
6. Run the narrow recipe, then `just check` to confirm nothing else moved.
