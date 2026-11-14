# Nix migration ticket 07 evidence

Evidence for [ticket 07](../../issues/07-flake-beside-pixi.md): the boxes that need the Nix backend. Nix is not installed on the Mac, so, as the [round README](../../README.md#where-nix-runs-until-04) says, each of those boxes is proved by a transcript from a Linux container.

Gathered on 2026-11-14 on an Apple-silicon Mac's Docker. **Everything here ran on aarch64-linux.** x86_64-linux and aarch64-darwin were only evaluated and planned from Linux ([systems.txt](systems.txt)); nothing was built or run for them.

## How it ran

[host.sh](host.sh) is ticket 01's stand-in for "a Linux machine with Nix installed": the Ubuntu base the Dockerfile ships, pinned by the same digest, with `/nix` on the named volume `knarr-nix-store` that ticket 01 filled and `/work` on a new volume, `knarr-nix-07-work`. `nix` and `git` come from the Nix image's profile in that store, at the end of `PATH`. Three things are added to the bare image, each standing in for something every real host has: the CA store and `/usr/bin/git` are links into that profile, and `NIX_CONFIG` turns on flakes and, because the image has no `nixbld` group, runs builds as root without the sandbox. Nothing is installed into the image.

The worktree is never mounted. The committed branch reached the container as a git bundle (`git bundle create ai_tmp/knarr.bundle 07-flake-beside-pixi`), and [setup.sh](setup.sh) clones it into `/work/clone`, a primary checkout, so `just initialize` installs the hook there. `host.sh --offline` adds `--network none`. `HOME` and Nix's caches are on the work volume and are the same for the online and offline runs.

Each `.txt` file is the transcript of the script with the same name, run in this order from the code commit `4b02ea5`:

| Script | Network | What it shows |
| --- | --- | --- |
| [setup.sh](setup.sh) | on | `KNARR_TOOLS=nix sh scripts/initialize.sh` on a fresh clone: the out-link, the hook, and where each tool resolves |
| [gate.sh](gate.sh) | off | The lock and environment checks' time and writes, then `KNARR_TOOLS=nix just check` |
| [drift.sh](drift.sh) | off | `just lock-check` on two drifted copies, and `flake.lock` afterwards |
| [move.sh](move.sh) | on | A simulated lock move, `just env-check`, a fresh `just initialize`, and a commit through the hook |
| [unknown.sh](unknown.sh) | off | `KNARR_TOOLS=conda` against `just --list`, `just check`, `just initialize` and a hook |
| [nonroot.sh](nonroot.sh) | off | The ripsecrets wrapper tests and `just test-checkers-all` as uid 1000 |
| [systems.sh](systems.sh) | on | Every package for all three systems, and each system's plan for the default group |
| [holds.sh](holds.sh) | off | Each held version read from `pins.toml` and asserted |

```sh
E=.scratch/nix-migration/evidence/07
sh $E/host.sh sh /evidence/setup.sh > $E/setup.txt
sh $E/host.sh --offline sh /evidence/gate.sh > $E/gate.txt
```

## Findings

1. **The gate passes on the flake's tools with the network off.** After `KNARR_TOOLS=nix just initialize`, `KNARR_TOOLS=nix just check` ran every recipe and ended "All checks passed and the worktree is unchanged." in 115 seconds, with no pixi on `PATH` and no `.pixi/` or `.tools/` in the clone ([gate.txt](gate.txt)). No tracked file was patched, so ticket 01's scratch patch is no longer needed: the docs checker reads markdown-it from the module directory, the Allium runner reads `pins.toml`, and `lock-check` and `env-check` dispatch on the backend. Ticket 01's list of formatter and linter differences had nothing to fix, and none appeared.
2. **The lock check refuses drift and leaves the lock alone.** On a copy whose `flake.nix` dropped an input `flake.lock` still records, `just lock-check` exited 1 with `requires lock file changes but they're not allowed due to '--no-update-lock-file'`; on one whose input moved to a channel nothing had fetched, it exited 1 because it cannot resolve the channel offline. In both, `flake.lock`'s sha256 was the same before and after ([drift.txt](drift.txt)). On the committed copy it exits 0 in 0.03 seconds.
3. **The environment check sees a lock move and says what to do.** After the lock moved `nixpkgs` to `9ac0edc`, `just env-check` exited 1 with `… is /nix/store/90lm…-knarr-tools, but this commit describes /nix/store/7pmk…-knarr-tools` and `run just initialize` ([move.txt](move.txt)). On the committed lock it passes in 1.6 seconds, adds no store path, and writes only Nix's own caches under `~/.cache/nix` ([gate.txt](gate.txt)).
4. **The hook follows the out-link.** `just initialize` leaves `PREK="/work/clone/.nix/default/bin/prek"` in the hook and no store path ([setup.txt](setup.txt)). After the move and a fresh `just initialize`, the out-link's prek is 0.5.7 where it was 0.5.10, the host has no other prek, and a commit of the moved lock and a new page passed every hook that applied ([move.txt](move.txt)).
5. **An unknown `KNARR_TOOLS` is refused by name everywhere but `just --list`.** With `KNARR_TOOLS=conda`, `just --list` exits 0; `just check`, `just initialize`, `sh scripts/initialize.sh` and `sh scripts/with-env.sh` exit 2 with `KNARR_TOOLS is 'conda'; set it to pixi or nix, or leave it unset for pixi`; and a commit fails with five hooks each reporting exit code 2 and that message ([unknown.txt](unknown.txt)).
6. **No test trips on a read-only store file.** As uid 1000, the ripsecrets wrapper tests had 14 passed, and `just test-checkers-all` had 916 passed, 14 skipped and no failure ([nonroot.txt](nonroot.txt)). The pinned ripsecrets is mode 555 and owned by root. The skips are the tools.txt installer and pixi initialize cases, which need a host tools.txt has a line for.
7. **The flake reads its holds from `pins.toml`.** Editing one entry of `pins.toml` in a copy, with `flake.nix` and `flake.lock` untouched, makes evaluation fail with `error: held erlang: the locked input has 29.1.2, pins.toml holds 29.1.1`, and the same for Gleam, kind, kwokctl, kubectl's minor and a raised rebar3 floor; a lowered floor evaluates to the same environment ([holds.txt](holds.txt)).
8. **Every package evaluates for all three systems.** `default`, `cluster`, `audit`, `runtime` and `allium` evaluate for aarch64-linux, x86_64-linux and aarch64-darwin, each with Erlang built against OpenSSL 3.5.9. The default group's plan builds four derivations on the other two systems (allium, the Python environment, the environment, and buildEnv's builder script) and fetches the rest from the cache: 425 MiB on x86_64-linux and 518 MiB on aarch64-darwin ([systems.txt](systems.txt)).
9. **perl is in the default group.** `perl` resolves to `.nix/default/bin/perl`, 5.42.3 ([setup.txt](setup.txt)).

## What this does not show

- Anything on aarch64-darwin or x86_64-linux beyond evaluation and the cache's plan. `ci.yml` on the pull request runs the pixi backend only.
- Nix's sandbox and a multi-user daemon: the stand-in host builds as root without them, as ticket 01's did.
- Garbage collection. The store volume is shared with ticket 01's work and was never collected; what a collection would do to an old hook is ticket 01's simulated case, and the hook here never names a store path.
- The cluster and audit groups beyond evaluation: their recipes are ticket 08's.
