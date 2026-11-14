# 04: Host spike: Nix on the Mac

**Context:** [01](01-nix-container-spike.md) answers the Linux questions from inside a container. The maintainer's machine is an Apple-silicon Mac with no Nix installed, and the round's premise is that Nix is the only new thing on it: no nix-darwin, no home-manager, no global profile. This ticket installs Nix there and checks that knarr's whole gate can run from a Nix-built environment reached by a `PATH` prefix, which is how [Decision 0003](../../../docs/decisions/0003-tool-manager.md) says recipes reach tools.

**What to build:** Evidence under `.scratch/nix-migration/evidence/04/`, gathered on aarch64-darwin with 01's candidate nixpkgs revision and prototype flake. It answers:

- **The install.** Which installer was used, everything it changed on the machine (volumes, daemons, users, shell profiles, configuration files), and how to remove it.
- **Flakes without machine configuration.** Whether the project can turn on what it needs per command or per repository, or what machine-level setting is unavoidable.
- **The out-link.** Whether a gitignored per-worktree out-link keeps its store paths alive across garbage collection, how much store is shared between two worktrees, and cold and warm initialize times. Decision 0003 records today's per-worktree sizes for comparison.
- **PATH-prefix sufficiency.** With only the prototype environment's directories prefixed:
  - the checker tests run through the interpreter's own pytest;
  - the docs checker's Node finds markdownlint-cli2's bundled markdown-it;
  - the path prek writes into the git hook still resolves after a lock move;
  - a fresh clone with only Nix installed can reach `just`.
- **The gate, offline.** The whole of `just check` run from that prefix with the network off, with timings for the lock and environment checks and a record of anything they write.
- **Version differences.** The list of formatter and linter findings that differ between the pixi versions and the candidate revision's versions, on today's tree.

**Non-goals:** Any tracked flake file. Changing how the gate finds its tools: the run uses a scratch prefix. Linux and CI facts.

**Blocked by:** 01

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** the maintainer installs Nix on the Mac. The evidence names the installer and its version, lists what it changed, and gives the uninstall steps.
- [ ] **Authorization required:** the network, for cache fetches.
- [ ] The evidence states whether flakes work with no machine-level configuration, or names the setting that is needed.
- [ ] The out-link, sharing and timing findings are recorded.
- [ ] Each PATH-prefix case has a transcript.
- [ ] A transcript shows the whole gate passing from the scratch prefix with the network off, or lists each failure with its cause.
- [ ] The version-difference list is recorded, each entry marked "hold the pixi version" or "accept and fix in 10".
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
