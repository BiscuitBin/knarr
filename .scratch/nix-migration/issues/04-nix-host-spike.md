# 04: Host spike: Nix on the Mac

**Context:** [01](01-nix-container-spike.md) answers the Linux questions from inside a container, including the gate run from a `PATH` prefix. The maintainer's machine is an Apple-silicon Mac with no Nix installed, and the round's premise is that Nix is the only new thing on it: no nix-darwin, no home-manager, no global profile. The maintainer chose on 2026-11-14 to let the round go ahead in containers and CI before installing Nix, so this ticket no longer gates the decision record. It gates [10](10-nix-becomes-the-gate.md), the point where the Mac needs Nix to run the gate at all. It installs Nix there and confirms on aarch64-darwin what 01 found on Linux.

**What to build:** Evidence under `.scratch/nix-migration/evidence/04/`, gathered on aarch64-darwin with the flake the repository tracks by then (01's prototype if [07](07-flake-beside-pixi.md) has not landed). It answers:

- **The install.** Which installer was used, everything it changed on the machine (volumes, daemons, users, shell profiles, configuration files), and how to remove it.
- **Flakes without machine configuration.** Whether the project can turn on what it needs per command or per repository, or what machine-level setting is unavoidable.
- **The out-link.** Whether a gitignored per-worktree out-link keeps its store paths alive across garbage collection, how much store is shared between two worktrees, and cold and warm initialize times. Decision 0003 records today's per-worktree sizes for comparison.
- **PATH-prefix sufficiency.** The four cases 01 ran on Linux, repeated on the Mac with only the Nix environment's directories prefixed:
  - the checker tests run through the interpreter's own pytest;
  - the docs checker's Node finds markdownlint-cli2's bundled markdown-it;
  - the path prek writes into the git hook still resolves after a lock move;
  - a fresh clone with only Nix installed can reach `just`.
- **The gate, offline.** The whole of `just check` run from that prefix with the network off, with timings for the lock and environment checks and a record of anything they write.
- **Differences from Linux.** Every place the Mac disagrees with 01's evidence or with what Decision 0017 recorded as unverified on darwin: a package missing from the binary cache, a tool that behaves differently, or a finding that is not on 01's version-difference list.

Where a finding contradicts Decision 0017, this ticket adds a dated note to the record and corrects ticket 10.

**Non-goals:** Linux and CI facts. Changing the default backend, which is 10.

**Blocked by:** 01

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** the maintainer installs Nix on the Mac. The evidence names the installer and its version, lists what it changed, and gives the uninstall steps.
- [ ] **Authorization required:** the network, for cache fetches.
- [ ] The evidence states whether flakes work with no machine-level configuration, or names the setting that is needed.
- [ ] The out-link, sharing and timing findings are recorded.
- [ ] Each PATH-prefix case has a transcript from the Mac.
- [ ] A transcript shows the whole gate passing from the Nix prefix on the Mac with the network off, or lists each failure with its cause.
- [ ] Each fact Decision 0017 lists as unverified on darwin is confirmed or corrected, with a dated note on the record where it changed.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
