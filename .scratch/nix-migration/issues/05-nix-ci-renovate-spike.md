# 05: CI and Renovate spike

**Context:** Every CI job gets its tools from one composite setup action, which installs pixi, restores a cache that only `main` writes, and runs `just initialize`. Each job has a timeout: 20 minutes for the gate and the kind jobs, 10 for the checker regressions. [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) chose Renovate partly because it can move `pixi.lock`. Before the setup action and the Renovate configuration move to Nix, this ticket measures both on the real runner, from a throwaway branch, using [01](01-nix-container-spike.md)'s prototype flake.

**What to build:** Evidence under `.scratch/nix-migration/evidence/05/` that answers:

- **Installer action and cache.** Which Nix installer action to use, pinned by commit SHA, and which cache strategy. Cold and warm setup times against each job's timeout, and whether the cache can be written from `main` only, as today's is.
- **The runner.** On ubuntu-24.04 under the prototype environment: `just check`, `just test-checkers-all`, the prototype image build for linux/amd64 and the TLS proof in it.
- **Renovate.** A dry run against a repository state that has the prototype flake: which flake inputs and held pins the nix manager extracts, whether lock maintenance moves `flake.lock`, and how the build-stage image is tracked. Bootstrap ticket 27's evidence has the shape to follow.

**Non-goals:** Merging any workflow or Renovate change. Activating the Renovate app, which is bootstrap ticket [44](../../bootstrap/issues/44-renovate-activation.md).

**Blocked by:** 01

**MVP critical path:** no.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** a push of a throwaway branch and the workflow runs on it. The branch is deleted afterwards and the evidence keeps the run URLs and logs.
- [x] **Authorization required:** the network, for the Renovate dry run's lookups.
- [x] The installer action is named with its SHA, and cold and warm timings are recorded for the gate job and one cluster job.
- [x] The gate and all checker tests pass on the runner under the prototype environment, or each failure is listed with its cause.
- [x] The prototype image builds on amd64 inside the kind jobs' 20-minute timeout, or the gap is stated with a number.
- [x] The Renovate dry-run transcript is recorded, with a list of every pin it did not extract.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

- `.scratch/nix-migration/evidence/05/`: the evidence. Its [README](../evidence/05/README.md) states each finding with the run URL or transcript that proves it, and has a table of the files. [nix-spike.yml](../evidence/05/nix-spike.yml) is the throwaway workflow as it ran. [timings.txt](../evidence/05/timings.txt) has every step of the three runs. [run-1.txt](../evidence/05/run-1.txt) and [run-2.txt](../evidence/05/run-2.txt) are the trimmed logs. [renovate.txt](../evidence/05/renovate.txt) is the Renovate dry run and the lock-update simulation.
- This ticket. No other tracked file changed.

The authorizations were used as follows:

- The branch `spike/nix-ci-05` was pushed three times, and its workflow ran: [43642997847](https://github.com/BiscuitBin/knarr/actions/runs/43642997847), [43643668469](https://github.com/BiscuitBin/knarr/actions/runs/43643668469) and [43644038497](https://github.com/BiscuitBin/knarr/actions/runs/43644038497), on spike commits `a797c38`, `cb3cd00` and `23f4984`. The remote and local branches were then deleted.
- The repository's Actions permissions and cache usage were read with `gh api` GETs.
- The network was used, read-only: the candidates' repositories, the Nix 2.35.6 install script, Renovate's source and documentation at 44.239.1, the Renovate and `nixos/nix` image pulls, Renovate's anonymous lookups, and the nixpkgs fetches in the lock simulation.
- No token reached Nix, Renovate or any container.

Left behind: two Actions cache entries scoped to the deleted branch's ref, 1.37 GB together. They are listed in the README's [What is left behind](../evidence/05/README.md#what-is-left-behind) and expire after 7 days unused; this ticket was not authorized to delete them. The two Renovate images are on the Mac's Docker.

### What was verified, and what was not

Everything on the runner ran on **x86_64-linux**, on GitHub's `ubuntu-24.04`, under upstream Nix 2.35.6 as a multi-user daemon with the sandbox on. The Renovate part ran on the Mac's Docker (linux/arm64).

- **Installer:** `cachix/install-nix-action@3dc140bfc76c49fbd4dd958429132e3746bcb086 # v31.11.5`, with `extra_nix_config: access-tokens =` and `enable_kvm: false`. It took 3 to 5 seconds. The Determinate actions were rejected: Determinate Nix by default, a pin that does not fix the version, and diagnostics on by default. `NixOS/nix-installer-action` calls itself experimental.
- **Cache:** none. Cold setup took 33 to 40 seconds for the gate shape and 40 to 52 for the cluster shape. With `nix-community/cache-nix-action@7df957e333c1e5da7721f60227dbba6d06080569 # v7.0.2`, warm setup took 30 to 38 and 43 to 44, for a 609 MB and a 766 MB cache entry. Each is under 9% of the shortest timeout. The main-only rule maps to `save: ${{ github.ref == 'refs/heads/main' }}`, and a `save: false` job showed restore without write. The cache was written from the spike branch as a measurement shortcut.
- **Gate:** `just check` passed in all six gate jobs, in 117 to 138 seconds, and ended "All checks passed and the worktree is unchanged.". `gate-scratch.patch` was applied without its `run_allium.py` hunk, which confirms that hunk is not needed on x86_64. allium's patched derivation was built and runs on x86_64.
- **Checker tests:** `just test-checkers-all` had 792 passed, 2 failed and none skipped, in all six checker jobs. The two are the ripsecrets wrapper tests. Their fixture copies `.tools/bin/ripsecrets` with `shutil.copy2`, which keeps the store file's read-only mode, and then writes to the copy as uid 1001. Ticket 01 ran as root and did not see it.
- **Image:** the prototype built for linux/amd64, with the pull and a `--no-cache` build taking at most 94 seconds. The six TLS cases passed under `image-check`'s restrictions on OTP 29 and OpenSSL 3.5.9. `/readyz` answered and memory was about 50 MiB.
- **kind**, beyond the ticket: `just cluster-up` and `just cluster-ready` with the `cluster` group's kind 0.33.0 and kubectl 1.36.3 brought up `kindest/node:v1.35.8` in 36 to 39 seconds.
- **Renovate 44.239.1:**
  - The nix manager needs `"nix": {"enabled": true}` as well as `enabledManagers`.
  - It extracts the three flake inputs from `flake.lock` through git-refs, and needs no token for that.
  - It proposes nothing for the two channel inputs, even on a stale lock.
  - It proposes moving the revision-pinned `nixpkgs-gleam` to nixpkgs `master` `HEAD`.
  - It tracks the build-stage image only when the `FROM` line has a tag as well as a digest.
  - The lock commands from its source, run in `nixos/nix` 2.35.6, moved both channel inputs, and the holds still evaluated. The slim image installs `nix` anonymously; the `-full` image ships it.
  - It did not extract the eight held versions, the allium URL or allium's three sha256.

Not verified:

- Renovate moving `flake.lock` through a branch: the local platform does not, and the hosted app is ticket 44's.
- How Renovate picks a nix version with no `constraints.nix` and no token.
- Whether the hosted app has a `nix` binary.
- The cache strategies and installers that were only read about.
- grype on x86_64.
- An actual write from `main`.
- A day when cache.nixos.org or github.com is slow.

### What later tickets need

- **06 (Decision 0017):** the installer and "no store cache" above, with the reasons in the README's sections 1 and 2.
  - The installer writes the job token into `nix.conf` unless told otherwise. `access-tokens =` turned that off, and nine cold jobs fetched the nixpkgs sources from github.com without it.
  - The runner's Nix is sandboxed under a daemon, unlike ticket 01's container.
  - If a cache is ever wanted, `cache-nix-action` with the `save` expression is the measured one. Magic Nix Cache would hold almost nothing here, because it skips what cache.nixos.org has.
- **07:** fix the ripsecrets test fixture, or copy `.tools/bin` writable. A store file is read-only, and any test that copies a tool with `shutil.copy2` and then writes to the copy fails for every user but root.
- **09:** write the build stage as `FROM nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed`, tag and digest. With the digest alone, Renovate never proposes anything. Every CI image build fetches the closure afresh, about a minute on the runner.
- **10 (the setup action):**
  - Replace `prefix-dev/setup-pixi` with `cachix/install-nix-action@3dc140bfc76c49fbd4dd958429132e3746bcb086 # v31.11.5`, with `extra_nix_config: access-tokens =` and `enable_kvm: false`, followed by `nix build <flake>#<group> --no-update-lock-file --out-link …` per group.
  - Drop the cache step and its main-only expression, or carry the expression over to `cache-nix-action`'s `save` if 06 decides on a cache.
  - The runner image ships its own `kind` and `kubectl` (1.37.2), which a job without the `cluster` group finds on `PATH`.
  - The checker-regressions job will fail whenever the ripsecrets group is selected, until 07's fixture fix.
- **12 (Renovate):**
  - Add `"nix"` to `enabledManagers` and `"nix": {"enabled": true}`.
  - Add a rule switching off `nixpkgs-gleam`, or any input pinned by revision (`matchManagers: ["nix"]`, `matchDepNames`).
  - Expect channel inputs to move only through `lockFileMaintenance`.
  - Consider `"constraints": {"nix": "2.35.6"}`.
  - The held attribute set and the allium asset are not extracted. A held version moves by moving an input, and the flake's assertions refuse a lock that loses one.
- **44:** whether the hosted app runs the nix lock update, and with which binary.

Against tickets 06 to 13 as drafted:

- **10**'s box "writes its cache from `main` only, or the ticket records why the chosen strategy differs" is met by recording "no cache" and its numbers.
- **12** asks that "each held version has a way to be proposed", and that its dry run show "every held pin extracted". This evidence makes that harder than the wording suggests. A held version is not a free-standing pin: it is whatever version the locked input revision carries, and the flake's assertions only check it. A regex manager can read `held.gleam` and propose 1.19.2 from a datasource. The flake would then refuse evaluation until someone moves `nixpkgs-gleam` to a revision that carries that version, which no bot finds. The same holds for erlang, openssl, kind, kwok and kubectl's minor. Only `held.allium` names an upstream release directly, and its three sha256 still need a hand rehash. 12 should expect those proposals to be notices of a move to make by hand, not updates, and should say so where it lists manual moves.
