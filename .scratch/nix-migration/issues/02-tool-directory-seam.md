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

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] In the `Justfile` and under `scripts/`, tests included, `git grep` finds `.pixi/envs` and `.tools/bin` only in the new script and in this keep-list: `env_check.py` and its test, which read pixi's own records, and the files that name the prefix inside the image, which [03](03-pin-and-prefix-readers.md) owns (`image.py`, `runtime_scan.py` and the image, prune and runtime-scan tests). The ticket records the command and its output.
- [x] Prose and configuration that name those directories are left alone: the contributing guide, the skills, `.gitignore`, the hook configs' comments and excludes, `tools.txt` and both Dockerfiles. Later tickets own them.
- [x] On a clone that has not been initialized, the directory verb exits 0 and runs no tool, and `just --list` works.
- [x] A missing environment still makes a hook refuse with the "run just initialize" message, as `with-env.sh` does today.
- [x] The tool verb exits 2 for a tool that is not in the project's directories, even when the host has one on `PATH`.
- [x] The script has its own tests in the `environment` group.
- [x] `just test-checkers-selected environment allium docs gate coverage audit` passes.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

- **`scripts/tool-dirs.sh`**, new, is the one owner of the tool directories. It is POSIX `sh` and runs no command but shell builtins.
  - `sh scripts/tool-dirs.sh dirs [<checkout>]` prints the four directories joined with colons, in Decision 0003's order, and exits 0 whether or not they exist.
  - `sh scripts/tool-dirs.sh tool <name> [<checkout>]` prints the absolute path of the first executable file of that name in those directories. With none it prints nothing and exits 2, and the caller prints its own message.
  - `<checkout>` is an absolute path, used as written. Without it the script uses the checkout it is in, found with `cd` and `pwd -P`.
  - A usage error prints one line on stderr and exits 2: an unknown verb, a relative checkout, an extra argument, or a tool name that is empty or holds a `/`.
- **`scripts/checks/_tools.py`**, new, is the Python helper: `directories(checkout)` and `tool(checkout, name)`, each one call to the script. `tool` raises `FileNotFoundError` on exit 2, so the callers' existing `except OSError` branches keep their "run just initialize" messages.
- **`Justfile`**: `export PATH` is now `` `sh scripts/tool-dirs.sh dirs` + ":" + env("PATH") ``. The `check`, `audit-tools` and `cluster-tools` guards call `tool python3`, `tool grype` and `tool kind`, with their three messages unchanged. Two comments no longer name a directory.
- **`scripts/with-env.sh`**, **`scripts/initialize.sh`** and **`scripts/checks/ripsecrets-redacted.sh`** call the script. `initialize.sh` passes the last directory of `dirs` to `install-tools.sh`. The ripsecrets wrapper finds the script beside its own path and passes the Git top level as the checkout.
- **`scripts/checks/run_allium.py`** and **`scripts/checks/validate_docs.py`** take `allium`, `node` and `markdownlint-cli2` from `_tools.tool`.
- **Tests.** `conftest.tool_directory(checkout)` is the shared helper: the first tool directory, where a test plants a stand-in. `test_with_env`, `test_run_allium` and `test_ripsecrets_redacted` use it. `test_coverage` takes `just` from `_tools.tool`. `test_coverage`, `test_lint_cold_build` and `test_with_env` copy the script into their scratch trees. `test_tool_dirs.py` (20 cases) and `test_initialize.py` (1 case) are new.
- **`scripts/checks/checker_suite.py`**: `tool_dirs` and `initialize` join the `environment` group's modules. `scripts/tool-dirs.sh` and `scripts/checks/_tools.py` join that group's inputs and the shared-input list.

Three things differ from before, all inside the same four directories:

- `initialize.sh` used to put three directories on `PATH`, without the audit one. It now gets all four.
- Each guard used to test one path. `with-env.sh` and `just check` looked for `python3` in the default environment, `cluster-tools` for `kind` in the cluster one, `audit-tools` for `grype` in the audit one, the docs checker for `node` and `markdownlint-cli2` in the default one, and the ripsecrets wrapper and the Allium runner in the `tools.txt` directory. Each now accepts the tool from any of the four, first match in order.
- The Justfile's prefix is the script's `pwd -P` of the checkout, where it was `justfile_directory()`. The two were byte-identical here, also when `just` ran from `docs/specs/`.

### What was verified, and what was not

Box 1. After `git add -A`, on the committed tree:

```console
$ git grep -n -e '\.pixi/envs' -e '\.tools/bin' -- Justfile scripts
scripts/checks/env_check.py:11:    beside the binary in .tools/bin/.pins/, and each pin recorded there with a
scripts/checks/env_check.py:128:            drift.append(f"  {name}: tools.txt pins {version}, .tools/bin holds {have}")
scripts/checks/env_check.py:140:            drift.append(f"  {stamp.name}: tools.txt pins nothing, .tools/bin holds {have}")
scripts/checks/env_check.py:150:        print(f"the {ENVIRONMENT} environment and .tools/bin match the pins ({platform})")
scripts/checks/image.py:26:RUNTIME_ENV = "/opt/knarr/.pixi/envs/runtime"
scripts/checks/runtime_scan.py:5:ticket 45). So this copies /opt/knarr/.pixi/envs/runtime out of the image into
scripts/checks/runtime_scan.py:34:RUNTIME = "/opt/knarr/.pixi/envs/runtime"
scripts/checks/tests/test_env_check.py:75:    """A project whose default environment and .tools/bin match its pins on osx-arm64."""
scripts/checks/tests/test_env_check.py:201:    assert "fake: tools.txt pins 1.1, .tools/bin holds 1.0" in result.stdout
scripts/checks/tests/test_env_check.py:215:    assert ".tools/bin holds nothing" in result.stdout
scripts/checks/tests/test_env_check.py:232:    assert "fake: tools.txt pins nothing, .tools/bin holds 1.0" in result.stdout
scripts/checks/tests/test_env_check.py:242:    assert "fake: tools.txt pins nothing, .tools/bin holds 1.0" in result.stdout
scripts/checks/tests/test_env_check.py:257:    assert "orphan: tools.txt pins nothing, .tools/bin holds an unreadable pin" in result.stdout
scripts/checks/tests/test_env_check.py:263:        (project / ".tools/bin/fake").unlink()
scripts/checks/tests/test_image.py:201:RUNTIME_ENV = "/opt/knarr/.pixi/envs/runtime"
scripts/checks/tests/test_prune_runtime.py:144:        "RUN .pixi/envs/default/bin/python -I scripts/prune_runtime.py .pixi/envs/runtime perl"
scripts/checks/tests/test_runtime_scan.py:125:        ["docker", "cp", f"{CONTAINER}:/opt/knarr/.pixi/envs/runtime", str(copy)],
scripts/tool-dirs.sh:51:tool_dirs=$root/.pixi/envs/default/bin:$root/.pixi/envs/cluster/bin:$root/.pixi/envs/audit/bin:$root/.tools/bin
```

Eight files: the new script, `env_check.py` and its test, and the image-prefix files ticket 03 owns. `test_tool_dirs.py` holds the expected four directories as path parts, such as `(".pixi", "envs", "default", "bin")`, so the pattern does not match it and the script is the only place that spells them out.

- **Red, then green.** With the helper written and the script not yet, the new and edited modules gave 51 failures and 12 errors. With the script and its callers in place they pass. Two cases describe behaviour that did not change and so passed against the old `Justfile` too: `just --list` on an uninitialized copy, and `just --evaluate PATH` beginning with `dirs`.
- **Same directories, same order.** `just --evaluate PATH` was saved before any edit and again after, and `cmp` found no difference.
- **Box 2.** `git diff --stat a798406 HEAD` is empty for `CONTRIBUTING.md`, `.gitignore`, both hook configs, `tools.txt`, both Dockerfiles, `.agents/`, `.claude/`, `docs/` and `.github/`.
- **Boxes 3 and 4, on a real clone.** A `git clone` of this branch into `ai_tmp/`, never initialized, with no `.pixi` or `.tools`: `PATH=<an empty directory> /bin/sh scripts/tool-dirs.sh dirs` printed the four directories under the clone and exited 0. `just --list` listed the recipes. `sh scripts/with-env.sh true` printed "the pixi environment is missing in `<clone>`; run just initialize" and exited 2. `just check` printed "the pixi environment is missing; run just initialize" and exited 2. `test_tool_dirs.py` and `test_with_env.py` hold the same cases.
- **Box 5.** In that clone, `sh scripts/tool-dirs.sh tool git` printed nothing and exited 2, with `/usr/bin/git` on `PATH`. `test_tool_refuses_a_tool_only_the_host_has` holds it.
- **Shells.** The script gives the same output under `/bin/dash`, `/bin/bash` and `/bin/zsh`, and shellcheck 0.11.0 has no finding.
- **`initialize.sh`.** `test_initialize.py` runs it on a scratch repository with `pixi`, `python3`, `gleam` and `prek` stubbed. It checks that the checkout's copies run, not the host's, and that the installer is given the last directory. Pointing the installer at the first directory, or dropping the `PATH` line, each fails it.
- **Box 7.** `just test-checkers-selected environment allium docs gate coverage audit`: 276 passed, and again on the committed tree with the same result. `just test-checkers-selected policy`: 169 passed. `just lint`: every hook passed.
- **Box 8.** `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes.

Not verified:

- `just initialize` itself was not run: it needs the network, and nothing authorized that. Only the stubbed test above covers the edited script.
- The cluster and audit guards were only read against the script's tests. Neither environment is installed in this worktree, so `just cluster-up` and `just image-scan` were not run with the tool present.
- Nothing ran on Linux. CI will be the first run there.
- No evidence script under `.scratch/` copies the `Justfile` or `with-env.sh` into another tree without `scripts/`: `fresh-clone.sh` clones the whole repository. This was read with `git grep`, and no evidence script was run.

### What later tickets need

- **07, the selector.** The backend is one assignment in `scripts/tool-dirs.sh`: the line `tool_dirs=$root/...` under the comment "The only list of the directories". Wrap it in `case ${KNARR_TOOLS:-pixi} in pixi) ... ;; nix) ... ;; *) exit 2 ;; esac`, with the Nix branch naming the out-link's `bin`. Both verbs read `$tool_dirs`, and every consumer reads the verbs, so nothing else changes for `PATH` or for a tool's path. Keep the Nix branch to builtins: `test_dirs_runs_no_tool_on_an_uninitialized_checkout` runs `dirs` with an empty `PATH`.
- **07, an unknown value.** `dirs` exiting 2 on a bad `KNARR_TOOLS` makes the `Justfile` fail to evaluate, `just --list` included. That is the first time `dirs` can refuse, so the header comment and the ticket's "never refuses" need the exception stated.
- **07, the environment reaches the script.** `with-env.sh`, the wrapper and `_tools.py` pass their environment through, so `KNARR_TOOLS` reaches the script from a recipe or a hook. The tests' `seam()` helper and `test_with_env` pass only `PATH`, so they run the default backend whatever the caller set.
- **07, what still knows pixi.**
  - `initialize.sh` runs `pixi install --locked` and gives `install-tools.sh` the last directory of `dirs`. Under Nix there is no `tools.txt` directory, so that step needs a backend branch.
  - The guards' messages still say "the pixi environment is missing", `run pixi install --locked -e cluster` and `run just audit-install`.
  - `test_coverage.py` links `.pixi` and `.tools` into its scratch projects by name and lists them in `.git/info/exclude`.
  - `test_tool_dirs.py` holds the four pixi directories as its expected value, and `test_initialize.py` expects `pixi install --locked` as the first call.
  - `run_allium.py` reads the expected Allium version from `tools.txt`. Ticket 13 names that.
- **07, where a stand-in goes.** `conftest.tool_directory` returns the first directory. Under pixi that is the default environment's `bin`, not the `tools.txt` directory the Allium and ripsecrets tests used before. The ripsecrets test writes its `.gitignore` from that directory's first path component, so it follows whatever the backend returns.
- **03.** This branch did not touch `image.py`, `hex_audit.py`, `runtime_scan.py` or their tests. The only overlap is `checker_suite.py`, where this branch changed the `environment` group and the shared-input list.
- **10.** The setup action can export `sh scripts/tool-dirs.sh dirs` to the job's `PATH`. The script takes the checkout from its own location, so it needs no argument there.
- **A shellcheck trap.** The first draft defined its functions at the top and called two of them inside `$(...)` in the `case` branches. shellcheck 0.11.0 reported SC2218, "this function is only defined later", on the calls in the second branch. The cause was not isolated further. The script now has no function but `usage` and sets its variables in line, and a change that adds a function called in a substitution may meet the report again.
