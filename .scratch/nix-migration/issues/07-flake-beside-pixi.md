# 07: Flake beside pixi

**Context:** After [02](02-tool-directory-seam.md) one script owns the tool directories, after [03](03-pin-and-prefix-readers.md) one function reads the OTP pin, and [06](06-nix-decision-record.md) has fixed the flake's layout. This is the expand step: Nix arrives as a second backend while pixi stays the default, so the gate stays green for everyone who has not installed Nix.

**What to build:** A contributor with Nix installed runs `KNARR_TOOLS=nix just initialize` and then `KNARR_TOOLS=nix just check`, and the gate runs on tools from the flake. Without the variable, everything behaves as before.

- **The flake.** `flake.nix` and `flake.lock` at the repository root, with the default tool group: every tool the gate uses, including the `openssl` command the TLS evidence scripts call.
- **The held-versions file.** A small tracked file the flake reads and that stdlib Python can read with no Nix present. It owns the exact versions Decision 0017 holds. The OTP reader from 03 reads it from now on, and the flake fails to evaluate if its Erlang differs from it.
- **The selector.** `KNARR_TOOLS=pixi|nix`, read only by the seam script, with a tracked default of `pixi`. An unknown value exits 2. A backend is selected whole: never default tools from one and cluster tools from the other.
- **Initialize.** Under the Nix backend it builds the environment into a gitignored per-worktree out-link, then does the hex download and the hooks step as today.
- **lock-check.** Under the Nix backend it runs the read-only offline check Decision 0017 names.
- **env-check.** Under the Nix backend it proves three things: the out-link resolves into the store; it is the environment this commit describes; and the held versions match what is installed.
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
- [ ] A policy test holds `pixi.toml`'s `erlang` pin equal to the held-versions file, and another checks `flake.lock`'s shape with the standard library, so the lock cannot rot while pixi is the default.
- [ ] `flake.nix` passes the spelling, editorconfig and secrets hooks, and `flake.lock` does not trip the spelling or large-file hooks.
- [ ] **Authorization required:** a push. `ci.yml` passes on the pull request with no Nix on the runner.
- [ ] `just test-checkers-selected environment policy allium docs audit packaging` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
