# Nix migration ticket 08 evidence

Evidence for [ticket 08](../../issues/08-cluster-audit-tools-from-flake.md): the cluster and audit groups from the flake. Nix is not installed on the Mac, so, as the [round README](../../README.md#where-nix-runs-until-04) says, each box that needs the Nix backend is proved by a transcript from a Linux container. The pixi box ran on the Mac in the worktree.

Gathered on 2026-11-14 on an Apple-silicon Mac's Docker. **Everything Nix-backed here ran on aarch64-linux**, with the Mac's Docker daemon (linux/arm64) running the clusters. Nothing was built or run for x86_64-linux or aarch64-darwin.

## How it ran

[host.sh](host.sh) is 07's stand-in host (the Ubuntu base the Dockerfile ships, pinned by digest, with `/nix` on the shared `knarr-nix-store` volume and `nix` and `git` from the Nix image's profile in it), widened for the cluster loop in three ways:

- **The Docker socket and host networking.** kind and kwokctl drive the Mac's daemon through `/var/run/docker.sock`, and the container shares the daemon's network namespace, so the API server each publishes on `127.0.0.1` is reachable at the address the kubeconfig names. A probe first showed a port published on `127.0.0.1` answering a `--network host` container.
- **The work volume at the daemon's own path.** `knarr-nix-08-work` is mounted at `/var/lib/docker/volumes/knarr-nix-08-work/_data`, its mountpoint inside the daemon. kwokctl's docker runtime bind-mounts files from `KWOK_WORKDIR`, which is in the clone, and the daemon resolves a bind source on its own filesystem, so the clone must have the same path in both. A probe first showed a file written there readable through a `docker run -v` of that path. It also gives the clone a unique path, so its cluster and image (`clone-7f423a53`) cannot collide with another ticket's `/work/clone`.
- **A Docker client.** Docker is a host prerequisite (Decision 0017) and the Ubuntu base has none. [setup.sh](setup.sh) builds `docker-client` 29.9.3 and `docker-buildx` 0.38.1 from the flake's locked main input (`nix build --no-update-lock-file --inputs-from .`) into `$WORK/host`, outside the checkout; buildx is needed because the Dockerfile uses BuildKit syntax. No recipe runs that build.

The worktree is never mounted. The branch reached the container as a git bundle and [setup.sh](setup.sh) clones it. Every Nix-backed transcript ran on the clone at `2a5b4baf16c1`, the commit that carries the code change; the commit after it adds only this directory and the ticket's notes. The brief named the `nixos/nix` image; as in 07, that image cannot run the recipes (no `/usr/bin`, no `sed`), so its Nix runs on the Ubuntu stand-in instead, from the same store. After the last runs, the three `ls` listings in [setup.sh](setup.sh) and [gate.sh](gate.sh) became shell globs, which shellcheck prefers; they print the same text.

| Script | Where | Network | What it shows |
| --- | --- | --- | --- |
| [setup.sh](setup.sh) | container | on | Initialize, the guards before the groups exist, `just cluster-install` and `just audit-install`, what each group holds, and `just env-check` |
| [kind.sh](kind.sh) | container | on | `cluster-up`, `image-build`, `image-load`, `deploy`, `smoke` and `cluster-down` on kind |
| [kwok.sh](kwok.sh) | container | on | `cluster-up`, `cluster-ready` and `cluster-down` with `KNARR_CLUSTER=kwok` |
| [grype.sh](grype.sh) | container | on, no download | The flake's grype through `just runtime-scan` and `just image-scan` |
| [gate.sh](gate.sh) | container | off | The selected checker tests and `KNARR_TOOLS=nix just check` with both groups installed |
| [drift.sh](drift.sh) | container | off | `just env-check` on a moved cluster out-link, and `just cluster-install` as the remedy |
| [pixi.sh](pixi.sh) | Mac worktree | on | The same loops on pixi with no `KNARR_TOOLS` |

```sh
E=.scratch/nix-migration/evidence/08
git bundle create ai_tmp/knarr.bundle 08-cluster-audit-tools-from-flake
sh $E/host.sh sh /evidence/setup.sh > $E/setup.txt
sh $E/host.sh sh /evidence/kind.sh > $E/kind.txt
sh $E/host.sh --offline sh /evidence/gate.sh > $E/gate.txt
sh $E/pixi.sh > $E/pixi.txt
```

## Findings

1. **The install recipes build the groups into their out-links.** `KNARR_TOOLS=nix just cluster-install` made `.nix/cluster` (kind, kubectl, kwokctl, and the `kwok` package's other binaries) and `just audit-install` made `.nix/audit` (grype), with `git status` clean. Under Nix, `kind`, `kubectl`, `kwokctl` and `grype` resolve to those out-links and `helm` and `kustomize` to the default group ([setup.txt](setup.txt)).
2. **The held versions.** kind v0.33.0, kubectl v1.36.3 (Kustomize v5.8.1), kwokctl v0.8.0, as `pins.toml` holds them. The kind cluster's server is v1.35.8 and the kwok cluster's v1.35.5, each one minor below kubectl ([kind.txt](kind.txt), [kwok.txt](kwok.txt)). grype is 0.120.0 with Syft v1.54.0.
3. **The guards check the group, not the command.** Before either group was installed, with stand-in `kind`, `kubectl`, `kwokctl` and `grype` on `PATH` after the tool directories (as a CI runner has its own), `just cluster-up`, `cluster-ready`, `deploy`, `smoke`, `image-scan` and `runtime-scan` each exited 2 with `the nix cluster group is not installed; run just cluster-install` or the audit equivalent, and no stand-in ran ([setup.txt](setup.txt)).
4. **The kind loop passes on the flake's tools.** `cluster-up` (24 s), `image-build`, `image-load`, `deploy`, `smoke` (`ok /healthz`, `ok /readyz`, `ok /metrics`) and `cluster-down` each exited 0; afterwards kind lists no cluster and `.cluster` is gone ([kind.txt](kind.txt)). The image build's layers all came from the daemon's BuildKit cache, because the Dockerfile and its context were unchanged since an earlier build of the same commit's tree; the build itself is Docker's, which neither backend changes.
5. **The kwok loop passes on the flake's tools.** With `KNARR_CLUSTER=kwok`, `cluster-up` made a one-node cluster from the pinned kwok images in 7 s (an earlier run of the same script had pulled them), `cluster-ready` passed, and `cluster-down` deleted it and its containers ([kwok.txt](kwok.txt)). This is the first time kwokctl from the flake ran against a cluster.
6. **The environment check compares the cluster group when it is installed.** With both groups installed, `just env-check` reports the default and the cluster out-links each matching, in 2 seconds ([setup.txt](setup.txt)). Moved by hand to another store path, the cluster out-link fails with `… but this commit describes …` and `run just cluster-install`; `just cluster-install`, offline because the group is already in the store, restores it and the check passes ([drift.txt](drift.txt)). The audit group's grype is not held, so it is not compared.
7. **The Nix gate still passes with both groups installed**, offline: `just test-checkers-selected cluster environment` 318 passed and 14 skipped (the pixi installer cases, which need a host `tools.txt` has a line for), and `KNARR_TOOLS=nix just check` ended "All checks passed and the worktree is unchanged." in 119 seconds ([gate.txt](gate.txt)).
8. **The flake's grype prints the cataloger line `runtime-scan` reads.** On today's pixi image, the -vv log has `discovered 12 packages cataloger=conda-meta-cataloger`, beside `erlang-otp-application-cataloger` (33) and `binary-classifier-cataloger` (2); `just runtime-scan` exited 0 with "grype catalogued 12 conda packages … and found no fixable high or critical vulnerability", and `just image-scan` exited 0 with "No vulnerabilities found" ([grype.txt](grype.txt)). The database was the Mac's own grype cache (schema v6.1.10, built 2026-10-30), copied into the work volume, so grype downloaded nothing; its age check was off because the copy is older than grype's limit.
9. **The pixi loop is unchanged.** On the Mac, with no `KNARR_TOOLS`, `just cluster-install` installed pixi's `cluster` environment through the same script, and the kind loop (`cluster-up` to `cluster-down`) and the kwok loop (`cluster-up`, `cluster-ready`, `cluster-down`) all exited 0 with pixi's kind v0.33.0, kubectl v1.36.0 and `tools.txt`'s kwokctl ([pixi.txt](pixi.txt)).

## What this does not show

- Anything on x86_64-linux or aarch64-darwin. 05 ran the cluster group's kind and kubectl on the x86_64 runner; kwokctl and grype from the flake have run on aarch64-linux only.
- A cold image build: the daemon's build cache served every layer in both backends' runs.
- grype with a fresh database: the copied one was 15 days old. A newer database can only add findings, which is `runtime-scan`'s and `image-scan`'s job, not this ticket's.
- `keda-e2e`, the fake-worker recipes and the observability recipes under Nix. They go through the same guard and the same `PATH`, and use only the tools proved here plus helm and kustomize from the default group.
