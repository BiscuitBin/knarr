# 07: Flake beside pixi

**Context:** After [02](02-tool-directory-seam.md) one script owns the tool directories, after [03](03-pin-and-prefix-readers.md) one function reads the OTP pin, and [06](06-nix-decision-record.md) has fixed the flake's layout. This is the expand step: Nix arrives as a second backend while pixi stays the default, so the gate stays green for everyone who has not installed Nix.

**What to build:** A contributor with Nix installed runs `KNARR_TOOLS=nix just initialize` and then `KNARR_TOOLS=nix just check`, and the gate runs on tools from the flake. Without the variable, everything behaves as before.

- **The flake.** `flake.nix` and `flake.lock` at the repository root, with Decision 0017's three nixpkgs inputs and the default tool group: every tool the gate uses, including the `openssl` command the TLS evidence scripts call and `perl` for the release scripts. 01's [prototype](../evidence/01/flake.nix) is the starting point: Erlang and rebar3 from `beam_minimal`, Python as `python314.withPackages` with pytest, the allium derivation with `autoPatchelfHook` on Linux, and `lib/node_modules` linked beside `bin`. The flake never refers to `self`. The flake and every file it reads must be tracked (staged is enough) before it evaluates: an untracked file is invisible to it.
- **The held-versions file.** `pins.toml` at the repository root, in the shape Decision 0017 gives: flat `[exact]`, `[minor]` and `[floor]` tables of strings. The flake reads it with `builtins.fromTOML` and asserts each held package against it, and stdlib Python reads it with `tomllib` with no Nix present. 01's prototype kept these as an attribute set in `flake.nix`, so reading the file is new here. The OTP reader from 03 (`otp_pin` in `scripts/checks/_runtime.py`) reads it from now on, and the flake fails to evaluate if its Erlang differs from it.
- **The selector.** `KNARR_TOOLS=pixi|nix`, read only by the seam script, with a tracked default of `pixi`. A backend is selected whole: never default tools from one and cluster tools from the other. The `Justfile` evaluates the `dirs` verb when it loads, so `dirs` never refuses and never prints an empty string: for an unknown value it prints the tracked default's directories and exits 0, and `just --list` still works. The refusal, exit 2 with a message naming `KNARR_TOOLS` and its two values, lives in the `tool` verb, `scripts/with-env.sh`, `scripts/initialize.sh` and the `Justfile`'s `check` guard.
- **The seam and the docs checker.** Under Nix `bin/markdownlint-cli2` is a wrapper script, so the docs checker cannot find markdown-it from its real path. The seam gives the checker markdownlint-cli2's module directory, `lib/node_modules/markdownlint-cli2`, not only a tool path.
- **The Allium runner.** Under the Nix backend it reads its expected version from `pins.toml`, not `tools.txt`, which has no aarch64-linux line.
- **Initialize.** Under the Nix backend it builds the default group into a gitignored per-worktree out-link, then does the hex download. The hooks step cannot be as today: prek writes its resolved store path into the git hook, and that path does not follow a lock move. The step makes the hook resolve through the out-link instead, by writing the out-link's path into it or another way that survives a lock move and garbage collection.
- **Nix commands.** Every Nix command a recipe or script runs carries `--no-update-lock-file`; without it a drifted lock is rewritten and the command exits 0. No recipe runs `nix develop`, `nix shell` or `nix run`.
- **lock-check.** Under the Nix backend it runs `nix flake lock --no-update-lock-file --offline`, the check Decision 0017 names.
- **env-check.** Under the Nix backend it proves three things, as 01's [env-check.sh](../evidence/01/env-check.sh) does: the out-link resolves into the store; it is the environment this commit describes; and the versions `pins.toml` holds match what is installed, with openssl compared against the OpenSSL the flake built Erlang with.
- **Tests that copy a store file.** On the x86_64 runner [05](05-nix-ci-renovate-spike.md) saw two ripsecrets wrapper tests fail under the Nix environment ([README](../evidence/05/README.md#4-the-checker-tests-on-the-runner)): their `worktree` fixture copies `.tools/bin/ripsecrets` with `shutil.copy2`, which keeps a store file's read-only mode, and then writes to the copy as a non-root user. The fixture copies without the mode (`shutil.copy`, or a `chmod` after the copy), and any other test that copies a tool and writes to the copy does the same.
- **Ignores.** The out-link and Nix's `result` links get ignore entries and the same tool excludes `.pixi/` has, so the read-only gate does not see them as changes. `flake.lock` gets the treatment `pixi.lock` has: excluded from the spelling check, marked generated in the git attributes, and still diffable.

CI has no Nix until [10](10-nix-becomes-the-gate.md). Every checker test this ticket adds must pass on a runner with no Nix present, and the boxes that need the Nix backend are proved by local transcripts in the hand-back notes.

**Non-goals:** CI. The images. The cluster and audit tool groups, which are [08](08-cluster-audit-tools-from-flake.md). Changing the default backend, which is [10](10-nix-becomes-the-gate.md). Fixing formatter differences that 01 marked "accept and fix in 10". Running the Nix backend on the Mac, which waits for [04](04-nix-host-spike.md).

**Blocked by:** 02, 03, 06

**MVP critical path:** no.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** the network, for `KNARR_TOOLS=nix just initialize`.
- [x] With no `KNARR_TOOLS` set, the gate passes on pixi and no pixi behaviour has changed.
- [x] `KNARR_TOOLS=nix just check` passes, or every remaining failure is a formatter or linter difference already on 01's list.
- [x] After `KNARR_TOOLS=nix just initialize`, the same gate passes with the network off.
- [x] The Nix lock check exits non-zero on a drifted copy and leaves `flake.lock` byte-identical.
- [x] The Nix environment check fails after a simulated lock move, with a message that says to run `just initialize`.
- [x] After a simulated lock move and a fresh `KNARR_TOOLS=nix just initialize`, a commit runs the hooks with the new environment's prek, and the hook names no store path.
- [x] Under `KNARR_TOOLS=nix`, run as a non-root user, the ripsecrets wrapper tests pass, and `just test-checkers-all` has no failure from a read-only store file.
- [x] An unknown `KNARR_TOOLS` value leaves `just --list` working, and `just check`, a hook and `just initialize` each exit 2 with a message naming the variable.
- [x] A policy test holds `pixi.toml`'s `erlang` pin equal to the held-versions file, and another checks `flake.lock`'s shape with the standard library, so the lock cannot rot while pixi is the default.
- [x] `flake.nix` passes the spelling, editorconfig and secrets hooks, and `flake.lock` does not trip the spelling or large-file hooks.
- [ ] **Authorization required:** a push. `ci.yml` passes on the pull request with no Nix on the runner.
- [x] `just test-checkers-selected environment policy allium docs audit packaging` passes.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

- **`flake.nix`, `flake.lock`, `pins.toml`** at the root. The flake is 01's prototype with Decision 0017's changes: it reads `pins.toml` with `builtins.fromTOML (builtins.readFile ./pins.toml)` and asserts each hold by kind (exact for erlang, gleam, kind and kwokctl, allium's version taken from it, a minor for kubectl, a floor for rebar3 with `lib.versionAtLeast`); the `held` attribute set and the `held` output are gone; `perl` joins the default group; the outputs never bind `self`. Each environment carries `passthru.opensslVersion`, the OpenSSL its Erlang is built against, which the environment check reads because `pins.toml` names no OpenSSL. The cluster, audit and runtime groups are defined as in the prototype, with no recipe. `flake.lock` is 01's, byte for byte. `pins.toml` is exactly the record's sample.
- **`scripts/tool-dirs.sh`** reads `KNARR_TOOLS`, with `default=pixi` the one tracked default (ticket 10 flips that line). Under Nix the directories are `.nix/default/bin`, `.nix/cluster/bin` and `.nix/audit/bin`, with no `tools.txt` directory. New verbs: `backend` prints the backend; `prefix default|cluster|audit` prints where a group is installed (pixi's environment, or the Nix out-link); `module <name>` prints a Node module beside the default group's `bin`. `dirs` never refuses: an unknown value prints pixi's directories and exits 0. Every other verb refuses an unknown value with exit 2 and `KNARR_TOOLS is '<value>'; set it to pixi or nix, or leave it unset for pixi`. `_tools.py` gains `backend`, `prefix` and `module`, and raises `SelectorError` with the script's message instead of hiding the refusal as a missing tool.
- **`scripts/with-env.sh`**, **`scripts/initialize.sh`** and the `Justfile`'s `check` guard ask `backend` first, so each refuses with that message and exit 2; their "environment is missing" messages name the backend. `initialize.sh` under Nix runs `nix build --no-update-lock-file --out-link <prefix default> .#default` instead of pixi and `install-tools.sh`, and requires `nix` where it required `pixi`.
- **The hook.** `scripts/install-hooks.sh` takes an optional prek path. Given one, after `prek install` it rewrites the hook's one `PREK=` line to it and fails if there is not exactly one such line or a `/nix/store/` path remains. `initialize.sh` passes `<prefix default>/bin/prek` under Nix and nothing under pixi, so pixi's hook is as before.
- **`Justfile`.** `lock-check` dispatches: pixi's command, or `nix flake lock --no-update-lock-file --offline`. `env-check` is unchanged; `env_check.py` dispatches. `links-audit` skips `.nix` and `result` links. Comments and the `initialize`, `lock-check` and `env-check` descriptions name both backends.
- **`scripts/checks/env_check.py`** under Nix: the out-link must be a link whose target has a `bin/` (else exit 2, "run just initialize"); one `nix eval --json --offline --no-update-lock-file <checkout>#default --apply …` gives the out path and `opensslVersion`; a different out path is drift; then gleam, erlang (from `OTP_VERSION`), allium exactly, rebar3 at or above its floor, and openssl against the flake's value. Drift exits 1 with "run just initialize". The pixi path is unchanged.
- **`scripts/checks/_pins.py`**, new, is the one reader of `pins.toml`: `held(project)` refuses anything but three flat tables of dotted-version strings, and `version(project, kind, name)`. **`_runtime.otp_pin`** reads `[exact] erlang` through it; its messages now name `pins.toml`. `hex_audit.py`'s docstring follows.
- **`run_allium.py`** takes its expected version from `pins.toml` under Nix and from `tools.txt`'s platform line under pixi, as before. **`validate_docs.py`** passes `<module markdownlint-cli2>/markdownlint-cli2-bin.mjs` to the renderer on both backends; under pixi `bin/markdownlint-cli2` is a link to that same file.
- **Ignores and excludes.** `.gitignore`: `.nix/`, `result`, `result-*`. `.nix/` and the `result` links beside `.pixi/` in `_typos.toml`, `taplo.toml`, `.markdownlint-cli2.jsonc`, both prek configs' `exclude` and `links-audit`. `flake.lock`: excluded from typos, marked `merge=binary linguist-language=JSON linguist-generated=true` like `pixi.lock`, and excluded from the fix config. It is not in the read-only config's global exclude, so the large-file, JSON and merge-conflict hooks still see it.
- **Tests.** New: `test_pins.py` (policy: `_pins`, the committed file, `pixi.toml`'s `erlang` pin equal to `pins.toml`'s, `flake.lock`'s shape with `json`, the flake's input URLs against the lock, `builtins.fromTOML`, no `self`, and every `nix` command in the `Justfile` and `scripts/` carrying `--no-update-lock-file` with none of `develop`, `shell` or `run`). Extended: `test_tool_dirs.py` (both backends, the selector, the new verbs, the Justfile's `check` and `lock-check` refusals, `just --list` with an unknown value), `test_with_env.py` and `test_initialize.py` (both backends and the refusal; the pixi case skips on a host `tools.txt` has no line for, as `test_install_tools.py` does), `test_install_hooks.py` (the rewrite and its refusals), `test_env_check.py` (the Nix branch against a stand-in `nix`), `test_run_allium.py`, `test_validate_docs.py`, `test_runtime.py`, `test_hex_audit.py`, `test_image.py`, `test_checker_suite.py`. `conftest.py` gains `BACKENDS`, `selected()` and a `backend` argument to `tool_directory`, so a scratch-checkout test pins its backend on both sides. `test_coverage.py` links `.nix` too.
- **The ripsecrets fixture** copies with `shutil.copyfile` and then `chmod 0o755`. The ticket's `shutil.copy` would not have fixed it: `shutil.copy` is `copyfile` plus `copymode`, and both it and `copy2` keep a 0555 source's mode (checked on the Mac). A new case copies a 0555 file and asserts 0755. No other test copies a tool and writes to the copy.
- **Text that named `pixi.toml` as the OTP owner**: `pixi.toml`'s comment and `audit.yml`'s comment now name `pins.toml`, and the contributing guide's pin-move routine says Erlang's `[exact]` entry in `pins.toml` moves with the pin.
- **`checker_suite.py`**: `pins` joins the `policy` group; `pins.toml`, `flake.*` and `scripts/checks/_pins.py` join `SHARED`.
- **Evidence** in [`../evidence/07/`](../evidence/07/README.md): eight scripts, their transcripts and a README.

### What was verified, and what was not

On the Mac, on pixi, with no `KNARR_TOOLS`:

- Red first: `test_pins.py` failed on the missing flake and Nix commands; the moved `otp_pin` cases failed 16 times before `_runtime.py` changed; the seam tests failed 33 times before the script did; the with-env, initialize, install-hooks, env-check, Allium and docs cases each failed before their code changed.
- The seam gives byte-identical answers to the base commit's for `dirs` and `tool` python3, ripsecrets, kind and gleam, compared by running both scripts on this checkout.
- `just lint` passes with every file tracked, `flake.nix` and `flake.lock` included. `just test-checkers-selected environment policy allium docs audit packaging`: 536 passed. With `gate coverage` added earlier in the work: 589 passed.
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes.

On **aarch64-linux**, in ticket 01's stand-in host with the warm store, on the branch at `3ebae67`, which already carries the evidence scripts and these notes, so the Nix gate linted them too (transcripts in [evidence/07](../evidence/07/README.md)). The commit after it adds only the transcripts and the notes' final form:

- Box 3 and 4: after `KNARR_TOOLS=nix sh scripts/initialize.sh` online, `KNARR_TOOLS=nix just check` with `--network none` ran every recipe and ended "All checks passed and the worktree is unchanged." in 114 seconds, with no pixi, `.pixi/` or `.tools/` present and a `result` link from a plain `nix build` in the tree. Nothing remained from 01's formatter and linter list: the list had no entry that needed a fix, and no new difference appeared.
- Box 5: offline, a copy whose `flake.nix` drops an input the lock records fails `just lock-check` with exit 1 and "requires lock file changes but they're not allowed due to '--no-update-lock-file'"; a copy whose input moves to an unfetched channel fails with exit 1 on the fetch. `flake.lock`'s sha256 is unchanged in both.
- Box 6: after `nix flake lock --override-input nixpkgs` to 01's `9ac0edc`, `just env-check` exits 1 with "… but this commit describes …" and "run just initialize".
- Box 7: after the move, `just initialize` rebuilt the out-link (prek 0.5.10 to 0.5.7); the hook still says `PREK="/work/clone/.nix/default/bin/prek"` with no store path; the host has no other prek; a commit of the moved lock and a new page passed every applicable hook. The clone was then reset and initialized back.
- Box 8: as uid 1000, with the store's ripsecrets mode 555 and owned by root, the wrapper tests had 14 passed and `just test-checkers-all` had 916 passed, 14 skipped, no failure. A first run failed in `test_initialize.py`: the stand-in host had no `/usr/bin/git`, which the tests' `PATH=/usr/bin:/bin` needs, and the pixi case reached `install-tools.sh`, which refuses aarch64-linux. `host.sh` now links git where every real host has it, and the pixi case skips on that host.
- Box 9: `KNARR_TOOLS=conda`: `just --list` exit 0; `just check`, `just initialize`, `sh scripts/initialize.sh` and `sh scripts/with-env.sh typos` exit 2 with the message; a commit fails with five hooks each at exit code 2 with the message. `test_tool_dirs.py`, `test_with_env.py` and `test_initialize.py` hold the same on both backends without Nix.
- Each of the five exact holds, kubectl's minor and a raised rebar3 floor, edited in `pins.toml` alone, fails evaluation with `held <name>: the locked input has …, pins.toml holds …` ([holds.txt](../evidence/07/holds.txt)).
- Every package evaluates for aarch64-linux, x86_64-linux and aarch64-darwin, all with Erlang on OpenSSL 3.5.9; the default group plans four local builds and a 425 MiB (x86_64-linux) or 518 MiB (aarch64-darwin) fetch.
- `just lock-check` takes 0.03 seconds and `just env-check` 1.5; together they add no store path and write only under `~/.cache/nix`.

Not verified:

- **Box 12, the push.** Not authorized; left open for the lead. Every test added here passes on the Mac with no Nix present, which is what the runner will be.
- Anything Nix-backed on aarch64-darwin or x86_64-linux beyond evaluation and the plan, so nothing of Decision 0017's darwin list is closed here.
- The sandbox and a daemon: the stand-in host builds as root without them.
- Garbage collection of an old environment: not run, because the store volume holds other tickets' work. The hook never names a store path, so there is nothing for a collection to break.
- The cluster and audit groups past evaluation, and `just cluster-install`, `just audit-install` or any cluster recipe under Nix.

Left on the Mac's Docker, on purpose: the volume `knarr-nix-07-work` (the clone, the drift and holds copies, logs, and Nix's caches), and in the shared `knarr-nix-store` the new paths this ticket built or fetched: the default group with perl, perl itself, and the environment the lock move described (prek 0.5.7). Nothing was garbage-collected, and nothing was installed on the host.

### What later tickets need

- **08.** The out-links are `.nix/cluster` and `.nix/audit`; ask `sh scripts/tool-dirs.sh prefix cluster`, as `initialize.sh` does for `default`. Both are already on `dirs` under Nix, after `default`. The flake already defines both groups with their holds asserted (kind, kwokctl, kubectl's minor). Still pixi-only: the `cluster-install` and `audit-install` recipes and the `cluster-tools` guard's message (`run pixi install --locked -e cluster`). `env_check.py`'s Nix branch checks the default group only.
- **09.** The `runtime` group is defined, untested. `_runtime.otp_pin` already reads `pins.toml`, so `image-check`'s OTP comparison is against `pins.toml` from this ticket; 09's bullet for it has only the prefix left. `PREFIX` is still pixi's.
- **10.** Flip `default=pixi` in `scripts/tool-dirs.sh`; `test_tool_dirs.py`'s `DEFAULT` and `REFUSAL` and the refusal strings in `test_with_env.py`, `test_initialize.py` and `test_env_check.py` follow it. The setup action can export `KNARR_TOOLS=nix sh scripts/tool-dirs.sh dirs`. Until the flip, hooks follow the `KNARR_TOOLS` of the commit, not the backend the hook was installed with: `with-env.sh` reads it at hook time. The hook is installed from the primary checkout only, so the primary checkout must be initialized with Nix for its hook to name an out-link. `flake.nix` has not been through `nixfmt`. Checker tests run scripts with `PATH=/usr/bin:/bin` and need `git` there; the runner has it.
- **13.** Removing the selector is the `case $backend` in `tool-dirs.sh` (whose `backend`, `module` and `prefix` verbs refuse an unknown value as `tool` does, beyond the four places 13 lists), the `backend` calls in `with-env.sh`, `initialize.sh` and the `Justfile` (`check`, `lock-check`), the pixi branches of `env_check.py` and `run_allium.py`, `install-tools.sh`'s call, `test_pins.py`'s `pixi.toml` case, and `BACKENDS` in `conftest.py`.
- **04.** On the Mac: `KNARR_TOOLS=nix just initialize` needs flakes enabled in the machine's Nix configuration (no script passes `--extra-experimental-features`); the hook rewrite uses the host's `sed` (BSD on the Mac, unverified); the out-link is `.nix/default` in each worktree.
- **12.** `pins.toml` is the one file a regex manager would read for held versions.

Against Decision 0017 and the ticket:

- The ticket's fix for the ripsecrets fixture, `shutil.copy`, keeps the read-only mode too; `copyfile` and a `chmod` is what works.
- 0017 says the lock check on drift prints "requires lock file changes …". Offline, it does when the drift needs no fetch; when `flake.nix` names a source nothing has fetched, it fails on the fetch instead. Both exit 1 and leave `flake.lock` byte-identical.
- 0017's environment check has rebar3 "report the version `pins.toml` holds"; `pins.toml` holds it as a floor, so the check compares at-or-above.
- The flake carries an `opensslVersion` passthru on each environment, which 0017 does not name.
