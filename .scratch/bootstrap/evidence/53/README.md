# Ticket 53 evidence

Evidence for the "Amended by ticket 53" notes in [Decision 0003: Tool manager](../../../../docs/decisions/0003-tool-manager.md) and [Decision 0014: Dependency updates and audit](../../../../docs/decisions/0014-dependency-updates-and-audit.md). Gathered on 2026-10-28 (UTC) on an Apple M5 Pro (Darwin arm64), with gh authenticated and the worktree's pixi environments. The `revision:` line of each transcript is the commit it ran against: the pin move, before these notes.

Each `.txt` file is the transcript of the script with the same name, and each script exits non-zero on an unexpected result.

- **[probe.txt](probe.txt)** shows why the pin moved. OSV.dev's `GIT` querybatch for `github.com/erlang/rebar3` lists no advisory for 3.28.0, and CVE-2026-103060 and CVE-2026-105274 for 3.27.1. It does not return CVE-2026-96596 for 3.27.1, although that record enumerates the tag, so the probe reads that record too. The three records state the rebar3 fixes as 3.28.0, 3.27.2 and 3.27.3, each record's numeric range agrees with its details, and none lists 3.28.0. 3.28.0 is erlang/rebar3's newest release. The downloaded escript's sha256 is GitHub's asset digest and the pin in `tools.txt` and both Dockerfiles, and its Sigstore bundle verifies with `install-tools.sh`'s flags at `refs/tags/3.28.0`. 3.27.1's digest is the control.
- **[build.txt](build.txt)** shows the new rebar3 at work. On just's PATH, `rebar3` is `.tools/bin/rebar3`, whose sha256 is the pin, and it reports 3.28.0 on OTP 29 (erts 17.1.1). With `build/dev` and `build/prod` removed, `just build` compiles every package. `ddskerl`, `hpack_erl` and `prometheus`, the three that `manifest.toml` builds with rebar3, each have `.beam` files. `just test` passes.

## Network the maintainer authorized for this ticket

On 2026-10-28:

- **Reads:** `gh api` on erlang/rebar3's releases, the 3.28.0 escript and its Sigstore bundle, `gh attestation verify`, and OSV.dev's records and querybatch.
- **The reinstall:** `just initialize` in this worktree, which fetched 3.28.0 and verified its Sigstore bundle.
- **GitHub:** pushing the branch and opening its pull request.

## Rerun

```sh
sh .scratch/bootstrap/evidence/53/probe.sh "$(mktemp -d)"
sh .scratch/bootstrap/evidence/53/build.sh
```

`probe.sh` needs network, an authenticated `gh` and the pixi default environment (`just initialize`). `build.sh` needs no network. It refuses build inputs that differ from `HEAD`, removes `build/dev` and `build/prod`, and leaves its logs in `ai_tmp/`.
