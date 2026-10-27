# Ticket 52 evidence

Evidence for the "Amended by ticket 52" notes in [Decision 0014: Dependency updates and audit](../../../../docs/decisions/0014-dependency-updates-and-audit.md), [Decision 0003: Tool manager](../../../../docs/decisions/0003-tool-manager.md) and [Decision 0013: In-cluster client](../../../../docs/decisions/0013-in-cluster-client.md). Gathered on 2026-10-27 (UTC) on an Apple M5 Pro (Darwin arm64) with OrbStack's Docker engine, pixi 0.83.0 and grype 0.120.1 from the pixi `audit` environment. The `revision:` line of `probe.txt` and `local-image.txt` is the commit they ran against: the pin move, before these notes. `ci-runs.txt` names its run's commit in its `event:` line.

Each `.txt` file is the transcript of the script with the same name, and each script exits non-zero on an unexpected result.

- **[probe.txt](probe.txt)** shows why both pins moved. OSV.dev's records of the four OTP advisories state each fix as OTP 29.1.2, and none lists `OTP-29.1.2`. CVE-2026-94200's record enumerates no tag, so `just hex-audit` cannot match it. `hex_audit.py` exits 0 on the tree and exits 1 naming the three advisories with the pin moved back to 29.1.1. conda-forge has erlang 29.1.2 for every locked platform, as `pixi.lock` locks it. `ubuntu:24.04` names the pinned index, whose amd64 and arm64 images carry `libssl3t64` 3.0.13-0ubuntu3.16. grype with `just image-scan`'s flags exits 0 on it, and 2 on the previous pin with CVE-2026-84782.
- **[local-image.txt](local-image.txt)** is the knarr image built here, for linux/arm64 (ticket 50), from the same commit. `just image-check` reruns Decision 0003's `tls_check.escript` on erts 17.1.1, and all 6 cases match. `just image-scan` and `just runtime-scan` both exit 0. The image scan finds erlang 29.1.2 through syft's `binary-classifier-cataloger` in `beam.smp`, which is how it matched erlang as a `binary` package in audit run 39896502411.
- **[ci-runs.txt](ci-runs.txt)** reads back pull request #68's `ci.yml` run 40470638639, at `e7eb105`: every job passed, and the kind smoke job's `just image-check` shows erts 17.1.1 and `tls_check.escript` matching all 6 cases in the amd64 image. The follow-up pull request reruns `ci-runs.sh` with the `audit.yml` run on `main` added.

## Network the maintainer authorized for this ticket

On 2026-10-27:

- **Reads:** OSV.dev's records and `just hex-audit`; `pixi search` on conda-forge; `docker buildx imagetools inspect` of `ubuntu:24.04`, and pulling its new index to read `libssl3t64` and scan it with grype, whose database grype downloads.
- **The relock:** `pixi lock` and `pixi install --locked`, and `just initialize` in this worktree.
- **GitHub:** pushing the branch and opening its pull request, and one `gh workflow run audit.yml --ref main` after the merge.

## Rerun

```sh
sh .scratch/bootstrap/evidence/52/probe.sh "$(mktemp -d)"
sh .scratch/bootstrap/evidence/52/local-image.sh "$(mktemp -d)"
sh .scratch/bootstrap/evidence/52/ci-runs.sh <ci-run-id> [<audit-run-id>]
```

`probe.sh` needs network, docker with buildx, pixi and the pixi default and audit environments (`just initialize`). `local-image.sh` needs the same, refuses build inputs that differ from `HEAD`, and leaves the worktree's image tag in place, as `just image-build` does. `ci-runs.sh` needs an authenticated `gh` and only reads.
