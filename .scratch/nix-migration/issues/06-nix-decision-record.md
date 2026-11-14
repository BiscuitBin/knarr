# 06: Decision 0017: Nix owns the toolchain

**Context:** [Decision 0003](../../../docs/decisions/0003-tool-manager.md) makes pixi the owner of Gleam, OTP and every tool, with `tools.txt` for what conda-forge lacks. The maintainer decided on 2026-11-14 to replace it with Nix (see the [round README](../README.md) for what was settled). A change of tool manager is not among 0003's reopening conditions, so this is a new record that supersedes it. [01](01-nix-container-spike.md) and [05](05-nix-ci-renovate-spike.md) hold the evidence. Nix is not installed on the maintainer's Mac yet, so [04](04-nix-host-spike.md) confirms the record on aarch64-darwin later, before [10](10-nix-becomes-the-gate.md).

**What to build:** A new decision record, `docs/decisions/0017-…md`, registered in the docs manifest, the decisions index and the docs index. It records:

- **The choice.** One flake and one `flake.lock` own every tool and the image runtime. Hex packages stay with gleam. Docker, git and a POSIX shell stay host prerequisites.
- **Verify 1 to 5, answered for Nix**, each citing an evidence file: TLS on the toolchain's OTP; one owner of the OTP version, read by the dev environment, CI and both image stages; where rebar3 comes from; a source for every tool; `manifest.toml` never rewritten.
- **The layout.** The tool groups (default, cluster, audit, runtime), the per-worktree out-link and how recipes reach it by `PATH`.
- **The selector** used while both backends exist, and its default at each stage.
- **The checks.** The exact read-only offline lock check, and what the environment check proves.
- **The image shape**, chosen from 01's prototype.
- **The held versions**, each with the evidence or rule that needs it, and the file that owns them.
- **What is dropped.** tilt, which is pinned today and used by nothing.
- **The `.nix` formatter question:** whether the gate formats Nix files, or that it does not and why.
- **What is unverified on darwin.** Each fact that was evaluated from Linux but not run on the Mac, named one by one, with 04 as the ticket that confirms it. Decision bodies are never rewritten, so 04 adds dated notes.
- **What would reopen it.**

Where the evidence changes a later ticket in this round, this ticket corrects that ticket's text and the round README.

**Non-goals:** Amending Decisions 0004, 0005, 0007, 0012 and 0014. Each is amended by the ticket that changes the fact it records. Any flake, recipe or workflow change.

**Blocked by:** 01, 05

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] Decision 0017 exists with the house frontmatter and sections, and each Verify answer links an evidence file.
- [ ] It is registered in `docs/manifest.yml`, `docs/decisions/README.md` and `docs/README.md`, and `CHANGELOG.md` has an Unreleased entry.
- [ ] Decision 0003 gains one "superseded by Decision 0017" note. Its body is unchanged.
- [ ] The record lists every fact not yet run on aarch64-darwin, and no Verify answer claims the Mac.
- [ ] The held-version list names, for each entry, what depends on the exact version.
- [ ] Tickets 07 to 13 and the round README agree with the record. Any **Blocked by** line that changed is reflected in the diagram and the waves table.
- [ ] `just docs-check` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
