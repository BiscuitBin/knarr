# Ticket 14 evidence

**Retired in part by ticket 31.** The S1 probe this evidence proved was scaffolding; ticket 31 removed it when the reconciler became the client's first caller, so [s1-kind.sh](s1-kind.sh), [s1_logs.py](s1_logs.py) and [run-all.sh](run-all.sh) no longer run against the tree (they read `s1_probe` log lines that no longer exist) and stay as the record of the transcripts beside them. [tls/run.sh](tls/run.sh) and [wrong-ca.sh](wrong-ca.sh) still run, from `.github/workflows/reconcile-proof.yml` beside [ticket 31's proof](../31/README.md); `wrong-ca.sh` now reads the reconciler's `list failed` lines and expects a NotReady pod, since readiness never latches without a complete LIST cycle.

Evidence for [Decision 0013: In-cluster Kubernetes client](../../../../docs/decisions/0013-in-cluster-client.md). The local transcripts were gathered on 2026-10-09 (UTC) on an Apple M5 Pro (Darwin arm64) with the pinned toolchain: Gleam 1.19.0, OTP 29 (erts 17.1) and OpenSSL 3.6.5 from the pixi default environment, OrbStack 2.2.3 with its Docker engine 29.4. The kind transcripts come from the `cluster-s1` CI job, run [37906694255](https://github.com/steven-cutting/knarr/actions/runs/37906694255/job/113741757594) on ubuntu-24.04 (native linux/amd64, Docker 28.0.4) on 2026-10-09, because the committed Dockerfile cannot build on this host ([emulation.txt](emulation.txt)). Each is the job's log with the runner preamble and BuildKit progress lines removed.

Each script exits non-zero on an unexpected result and prints `ok` or `FAIL` per case. Nothing printed holds a token: the kind transcript shows the token file's sha256 prefix and the JWT's `exp` claim only.

## Rerun

[run-all.sh](run-all.sh) is retired with the probe. The live rerun is the workflow `.github/workflows/reconcile-proof.yml`, or the two scripts by hand, each `<worktree> <dir>`, with `wrong-ca.sh` run after [ticket 31's reconcile-kind.sh](../31/reconcile-kind.sh) on the same cluster:

```sh
sh .scratch/bootstrap/evidence/14/tls/run.sh "$(pwd)" "$(mktemp -d)"
sh .scratch/bootstrap/evidence/31/reconcile-kind.sh "$(pwd)" "$(mktemp -d)"
sh .scratch/bootstrap/evidence/14/wrong-ca.sh "$(pwd)" "$(mktemp -d)"
just cluster-down
```

The kind scripts need network and Docker on a host that can build the linux/amd64 image; `tls/run.sh` needs the pinned OTP only. Nothing rewrites the committed transcripts: `tls.txt`, `s1-kind.txt`, `wrong-ca.txt` and `version.json` are the record of the runs above, and `emulation.txt` is the hand-run record of the ARM-host attempt.

## Scripts

| Script | Transcript | What it shows |
| --- | --- | --- |
| [tls/run.sh](tls/run.sh) `<worktree> <dir>` with [tls/tls_check.escript](tls/tls_check.escript) | [tls.txt](tls.txt) (this Mac), [tls-native.txt](tls-native.txt) (CI, native linux/amd64) | Eight cases on the pinned OTP: `ssl:connect` to the string `"127.0.0.1"` passes against an IP-SAN certificate, fails `unknown_ca` against an unrelated CA and `hostname_check_failed` against a DNS-only certificate, and the listener's `sni_fun` shows OTP sends the IP literal as SNI; `httpc:request` over the same options round-trips a 200 and returns the full error terms for a wrong CA and a closed port; a PATCH with the content type as httpc's own argument reaches the server with one `content-type` header; `public_key:pkix_test_data/1` builds a chain whose leaf carries an `iPAddress` SAN. Uses [01's certificate generator](../01/tls/gen-certs.sh) |
| (hand run) | [emulation.txt](emulation.txt) | The amd64 runtime and `just image-build` both fail under Rosetta in `prim_tty`; `ERL_FLAGS='+JMsingle true'` fixes the runtime but not the committed build stage, so the kind proof runs in CI |
| [s1-kind.sh](s1-kind.sh) `<worktree> <dir>` with [s1_logs.py](s1_logs.py) | [s1-kind.txt](s1-kind.txt) | Builds, checks and deploys the base to the worktree's kind cluster; captures `/version` into `version.json` and checks its field types against the 08 fixture; shows the token mount as UID 10001 sees it; then reads the pod's log until it holds the first token's hash with an `exp` about 600 s after the pod started, a changed hash, and a LIST and PATCH after that `exp`, from one process (`restartCount` 0, same UID), and the `knarr.io/s1-probe` annotation on the pod |
| [wrong-ca.sh](wrong-ca.sh) `<worktree> <dir>` | [wrong-ca.txt](wrong-ca.txt) | Creates the `knarr-wrong-ca` ConfigMap from 01's `ca-b`, deploys the `wrong-ca` variant, requires `tls_alert unknown_ca` on every cycle, no LIST or PATCH success and a Running, NotReady pod with `restartCount` 0, then redeploys the base |
| [run-all.sh](run-all.sh) `<worktree> <root>` | | The three scripts in order, then `just cluster-down` |
| (hand run, pre-flight) | [version.json](version.json) | `kubectl get --raw /version` from this worktree's kind cluster (kindest/node v1.35.8, linux/arm64), captured on 2026-10-09: `major`, `minor` and `gitVersion` are strings, as the 08 fixture in `test/sans_io_example_test.gleam` assumes, and `minor` carries no suffix on kind. The same local cluster accepted both variants with `kubectl apply --dry-run=server` and the scripts' jsonpath forms |

## Notes

- **CI is the source of the kind transcripts.** The `cluster-s1` job, then in `.github/workflows/s1-proof.yml` and now in `reconcile-proof.yml`, ran the three scripts on a push to main that changed its inputs, on `workflow_dispatch`, or on a pull request carrying the `cluster-s1` label (added by ticket 41); `s1-kind.txt`, `wrong-ca.txt` and `tls-native.txt` are its log from the run above. The kind run found the token file mode 0600 owned by UID 10001, rotation at +512 s, and the first success after the first expiry 2 s later.
- **Ticket 35.** [tls-native.txt](tls-native.txt) is native-Linux TLS evidence for the default environment, and [version.json](version.json) is the captured `/version` its fixture item asks for, from the kind version ticket 10 chose; the managed-cluster `minor` suffix claim is not established by it. The runtime environment's TLS probe and the rebar3 probe are not run here.
