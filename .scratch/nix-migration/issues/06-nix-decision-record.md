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

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] Decision 0017 exists with the house frontmatter and sections, and each Verify answer links an evidence file.
- [x] It is registered in `docs/manifest.yml`, `docs/decisions/README.md` and `docs/README.md`, and `CHANGELOG.md` has an Unreleased entry.
- [x] Decision 0003 gains one "superseded by Decision 0017" note. Its body is unchanged.
- [x] The record lists every fact not yet run on aarch64-darwin, and no Verify answer claims the Mac.
- [x] The held-version list names, for each entry, what depends on the exact version.
- [x] Tickets 07 to 13 and the round README agree with the record. Any **Blocked by** line that changed is reflected in the diagram and the waves table.
- [x] `just docs-check` passes.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

- `docs/decisions/0017-nix-owns-the-toolchain.md`, new: Decision 0017, "Nix owns the toolchain", superseding 0003. It records one flake and `flake.lock` at the root with three nixpkgs inputs, the held versions and their owner `pins.toml`, OTP 29.1.2 with the OpenSSL it is built against (3.5.9, a change from `pixi.lock`'s 3.6.5), Gleam 1.19.0 from a second input, kubectl 1.36 from a third, ordinary tools at the main input's versions, tilt dropped, the four tool groups and per-worktree out-links reached by `PATH` through `scripts/tool-dirs.sh`, the `KNARR_TOOLS` selector and where an unknown value is refused, the lock and environment checks, the rules carried over from 0003, the prek hook requirement, the image shape, CI (the installer, no store cache, the x86_64 results), Renovate, the host prerequisites, the `nixfmt` decision, Verify 1 to 5, the darwin list and the reopening conditions.
- `docs/decisions/0003-tool-manager.md`: one "Superseded by Decision 0017" paragraph under its provenance line. The body is unchanged.
- `docs/manifest.yml`, `docs/decisions/README.md`, `docs/README.md`: the record is registered and linked; the decisions index marks 0003 superseded.
- `CHANGELOG.md`: an Unreleased entry.
- Tickets corrected from 01's and 05's evidence: 07 (`pins.toml` and its shape, the selector's refusals, the hook through the out-link, the docs checker's module directory, the Allium runner off `tools.txt`, tracked flake files, `--no-update-lock-file`, perl, the ripsecrets fixture; three new boxes), 08 (where kind, kubectl, kwokctl and grype come from, 05's kind run, the runner's own kind and kubectl; the grype box removed as answered), 09 (the image shape, `FROM nixos/nix:2.35.6@sha256:…` with tag and digest, the allowlists, the prune script and conda and perl checks retired, `/opt/knarr/runtime`, no further 0003 notes), 10 (host prerequisites, the installer and no cache, the `nixfmt` hook and box, the hook, nothing to fix from 01's list, the cache box rewritten), 11 (rewritten around `nix-cataloger` and `binary-classifier-cataloger`, an image-source control first, fail-closed on the classifier's `erlang`), 12 (rewritten: held versions are noticed, never proposed; `nixpkgs-gleam` switched off; `nixpkgs-kubectl` held to its channel; boxes to match), 13 (the selector's refusals and the Allium overlap with 07), 04 (what the host supplies on the Mac). The round README names the three inputs and `pins.toml`.
- Ticket 05's branch was merged in so the record can cite its evidence.

### What was verified, and what was not

- `just docs-check`, `just lint` and `just check` pass on the final commit, with every change staged, and `git status --short` is empty.
- Every **Blocked by** line was compared with the round README's diagram, waves table and longest-chain sentence. None changed, and all three agree.
- Each Verify answer cites an evidence file. Verify 1, 2 and 4 claim aarch64-linux (01) and x86_64-linux (05); 3 and 5 claim aarch64-linux only. None claims the Mac.
- The record's facts were read from the evidence READMEs and checked against the transcripts they cite where a line is quoted (`gate-setup.txt`, `image.txt`, `tls-pairs.txt`, `host-needs.txt`, 05's `run-1.txt`).

Not established by any evidence, and stated as such in the record:

- That the flake reads `pins.toml`: 01's prototype held the versions in `flake.nix`. Ticket 07 shows it.
- `nix develop` and `nix run` rewriting a drifted lock: inferred from `nix shell`, `nix eval` and `nix build`, which 01 measured.
- `perl` in the flake's `default` group, and `nixfmt`'s attribute and output: neither was prototyped.
- Anything on aarch64-darwin, listed one by one for 04.

Choices the maintainer may want to revisit:

- **OpenSSL 3.5.9 in place of 3.6.5.** The record holds OTP exactly and OpenSSL as whatever the held Erlang is built against.
- **Gleam's exact hold.** 01 found 1.19.2 passes every check, so the hold and its second input rest on the round's rule rather than a failing check.
- **rebar3 as a floor (3.28.0 or later)**, where the prototype held it exactly.

### What later tickets need

- **07:** `pins.toml` in the record's shape, read by the flake with `builtins.fromTOML` and by `otp_pin`; the selector's refusals in `tool`, `with-env.sh`, `initialize.sh` and the `check` guard, with `dirs` never refusing; the hook through the out-link; the ripsecrets fixture fix.
- **09:** the tag-and-digest `FROM`; no amendment note on 0003, which is superseded.
- **10:** the installer at its SHA with `access-tokens =` and `enable_kvm: false`, no store cache, the `nixfmt` hook, and the host prerequisite line.
- **11:** the image-source control before choosing between scanning the image and copying the closure out.
- **12:** the nix manager switched on, `nixpkgs-gleam` off, `nixpkgs-kubectl` held to its channel, held versions as manual moves.
- **04:** the record's "Unverified on darwin" list; a finding that changes a fact gets a dated note on 0017, not a body edit.
