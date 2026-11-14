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
- **Ignores.** The out-link and Nix's `result` links get ignore entries and the same tool excludes `.pixi/` has, so the read-only gate does not see them as changes. `flake.lock` gets the treatment `pixi.lock` has: excluded from the spelling check, marked generated in the git attributes, and still diffable.

CI has no Nix until [10](10-nix-becomes-the-gate.md). Every checker test this ticket adds must pass on a runner with no Nix present, and the boxes that need the Nix backend are proved by local transcripts in the hand-back notes.

**Non-goals:** CI. The images. The cluster and audit tool groups, which are [08](08-cluster-audit-tools-from-flake.md). Changing the default backend, which is [10](10-nix-becomes-the-gate.md). Fixing formatter differences that 01 marked "accept and fix in 10". Running the Nix backend on the Mac, which waits for [04](04-nix-host-spike.md).

**Blocked by:** 02, 03, 06

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** the network, for `KNARR_TOOLS=nix just initialize`.
- [ ] With no `KNARR_TOOLS` set, the gate passes on pixi and no pixi behaviour has changed.
- [ ] `KNARR_TOOLS=nix just check` passes, or every remaining failure is a formatter or linter difference already on 01's list.
- [ ] After `KNARR_TOOLS=nix just initialize`, the same gate passes with the network off.
- [ ] The Nix lock check exits non-zero on a drifted copy and leaves `flake.lock` byte-identical.
- [ ] The Nix environment check fails after a simulated lock move, with a message that says to run `just initialize`.
- [ ] After a simulated lock move and a fresh `KNARR_TOOLS=nix just initialize`, a commit runs the hooks with the new environment's prek, and the hook names no store path.
- [ ] An unknown `KNARR_TOOLS` value leaves `just --list` working, and `just check`, a hook and `just initialize` each exit 2 with a message naming the variable.
- [ ] A policy test holds `pixi.toml`'s `erlang` pin equal to the held-versions file, and another checks `flake.lock`'s shape with the standard library, so the lock cannot rot while pixi is the default.
- [ ] `flake.nix` passes the spelling, editorconfig and secrets hooks, and `flake.lock` does not trip the spelling or large-file hooks.
- [ ] **Authorization required:** a push. `ci.yml` passes on the pull request with no Nix on the runner.
- [ ] `just test-checkers-selected environment policy allium docs audit packaging` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
