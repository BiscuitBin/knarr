# 02: Tool-directory seam, on pixi

**Context:** Recipes and hooks reach every tool through a `PATH` prefix ([Decision 0003](../../../docs/decisions/0003-tool-manager.md), "How recipes reach the environment"). That prefix, four directories under `.pixi/envs/` and `.tools/bin`, is written out separately in the `Justfile`, `scripts/with-env.sh` and `scripts/initialize.sh`. Several callers also name a tool by its full path: the Allium runner, the ripsecrets wrapper, the docs checker's Node, and the recipes that guard on a binary being present. A second backend cannot be added while each of those knows where pixi puts things. This is the prefactor that makes the later change easy, and it lands entirely on pixi.

**What to build:** One POSIX shell script that owns the tool directories, with two verbs:

- one prints the ordered, colon-joined tool directories for a checkout. It only computes a string and never refuses, because the `Justfile` evaluates it before `just initialize` has run;
- one prints a named tool's absolute path from those directories only, or exits 2.

It stays an ordered list, not one directory, because the cluster and audit tools are optional. It is shell because `with-env.sh` runs before Python is located.

Everything that builds the prefix or names a tool by path goes through it: the `Justfile`'s exported `PATH` and its presence guards, `with-env.sh`, `initialize.sh`, the ripsecrets wrapper, and the Allium runner and docs checker through one small Python helper. The tests that copy the `Justfile` or the wrapper into a scratch tree copy the script too, and the tests that plant fake binaries take the directory from one shared helper. The script joins the `environment` checker group's inputs and the shared-input list in the checker suite.

The script prints the same four directories as today, in the same order, so behaviour does not change.

**Non-goals:** Nix, or a backend selector. `lock-check`, `env-check`, the installer and their tests, which still read pixi's own files. The Dockerfiles. The evidence scripts under `.scratch/`, which are never rewritten.

**Blocked by:** None (can start immediately)

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] In the `Justfile` and under `scripts/`, tests included, `git grep` finds `.pixi/envs` and `.tools/bin` only in the new script and in this keep-list: `env_check.py` and its test, which read pixi's own records, and the files that name the prefix inside the image, which [03](03-pin-and-prefix-readers.md) owns (`image.py`, `runtime_scan.py` and the image, prune and runtime-scan tests). The ticket records the command and its output.
- [ ] Prose and configuration that name those directories are left alone: the contributing guide, the skills, `.gitignore`, the hook configs' comments and excludes, `tools.txt` and both Dockerfiles. Later tickets own them.
- [ ] On a clone that has not been initialized, the directory verb exits 0 and runs no tool, and `just --list` works.
- [ ] A missing environment still makes a hook refuse with the "run just initialize" message, as `with-env.sh` does today.
- [ ] The tool verb exits 2 for a tool that is not in the project's directories, even when the host has one on `PATH`.
- [ ] The script has its own tests in the `environment` group.
- [ ] `just test-checkers-selected environment allium docs gate coverage audit` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
