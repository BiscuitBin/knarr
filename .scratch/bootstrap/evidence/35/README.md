# Ticket 35 evidence

Evidence for [ticket 35](../../issues/35-bootstrap-verification-gaps.md), gathered on 2026-10-10 (UTC) at `e548efa66770317dd78cd9209b60998ee15d4ee7`, which was `main` and this branch's starting commit. Every run used that commit; the evidence files were untracked while they ran, and each clone was made from the committed branch. The one exception is the later stub check of the primary-hook probe, whose host and commit [its section](#open-the-maintainers-primary-hook) gives.

The host was a disposable Claude Code cloud container: a Firecracker VM, Linux x86_64 (kernel 6.18.44), Ubuntu 24.04.5 LTS, 4 × Intel Xeon @ 2.10GHz, 15.7 GiB, running as uid 0. It is native linux-64: `/proc/cpuinfo` names no Rosetta CPU and `ERL_FLAGS` was unset. Pins: bootstrap pixi 0.81.0 and just 1.58.0 ([checksums](bootstrap.txt)); the locked environment's Gleam 1.19.0, erlang 29.1.1 (`pl5321h8f2c242_0`), openssl 3.6.5 (`h781a0a9_0`), Python 3.14.8 and pytest 9.1.1; rebar3 3.27.1 from `tools.txt`.

**Limitations that apply throughout.** Every download went through the session's egress proxy, which re-terminates TLS, so timings include it. The container's `gh` holds an invalid token, so `install-tools.sh` skipped rebar3's Sigstore check; the sha256 pin was the check, and [11's run](../11/README.md#local-verification) is the one that verified the bundle. Network denial on Linux is a user and network namespace (`unshare -rn`) whose only interface, `lo`, is brought up with a `SIOCSIFFLAGS` ioctl from Python, because knarr's tests connect to 127.0.0.1 and iproute2 is absent. Nothing routes out of it, as the probes show.

## Results

| Ticket 35 item | Result | Evidence |
| --- | --- | --- |
| 03, fully cold initialization | **Closed.** Cold `just initialize` 16.676 s, `just check` 183.112 s, network-denied `just check` 200.367 s; all exit 0, worktree clean | [cold.txt](cold.txt), [cold-initialize.txt](cold-initialize.txt), [cold-check.txt](cold-check.txt), [offline.txt](offline.txt), [offline-check.txt](offline-check.txt), [cold-results.json](cold-results.json), [caches-after.txt](caches-after.txt) |
| 01, native Linux TLS and rebar3 | **Closed.** All six TLS cases in the default and the runtime environment; OTP 29 in both, matching `pixi.lock`; rebar3 compiles both dependencies and the build fails without it | [native-linux.txt](native-linux.txt) |
| 03, maintainer's primary hook | **Open.** Needs the maintainer's checkout. The probe, [primary-hook.sh](primary-hook.sh), is [below](#open-the-maintainers-primary-hook); its verdicts and cleanup are checked against stub hooks | [primary-hook-stubs.txt](primary-hook-stubs.txt) |
| 04, intermittent checker test | **Open.** 20 sequential runs of the current 402-test suite all passed, 8,040 test executions with no failure; green runs do not identify it. Static leads are recorded for the Mac | [checkers.txt](checkers.txt) |
| 06, hosted audit | **Open.** The authorized dispatch was refused, `403 Resource not accessible by integration`; no scheduled run exists yet | [audit.json](audit.json) |
| 05/06, restricted agent sandbox | **Open.** macOS only; nothing here observes it | — |
| 08, snapshot commands | **Closed.** Interactive review accepted through a pseudo-terminal, reject and stale delete, with byte-level and isolation assertions | [snapshots.txt](snapshots.txt) |
| 08, version fixture | **Closed.** The fixture's types match both of 14's captured replies; the `+` suffix is established from Kubernetes v1.35.8's build script and GKE's version format | [version-fixture.txt](version-fixture.txt), [kubernetes-v1.35.8.txt](kubernetes-v1.35.8.txt) |
| 09, Copilot discovery | **Open.** Needs a Copilot session | — |

## 03: fully cold initialization

```sh
sh .scratch/bootstrap/evidence/35/cold.sh <dir-holding-pixi-and-just> "$(mktemp -d)"
```

[cold.sh](cold.sh) refuses to start unless every default cache path is absent: `~/.cache/` `rattler`, `gleam`, `prek`, `pre-commit`, `rebar3`, `hex` and `lychee`; `~/.hex`, `~/.pixi`, `~/.rattler` and `~/.conda`; `~/.local/share/gleam`, `~/.local/share/rattler` and `~/.config/rebar3`. It also refuses if any variable that relocates one is set (`PIXI_CACHE_DIR`, `RATTLER_CACHE_DIR`, `XDG_CACHE_HOME`, `PREK_HOME`, `HEX_HOME`, `REBAR_CACHE_DIR`). The defaults were used on purpose: the machine was disposable and no other session shared its caches, so nothing was cleared or relocated. `pixi info` is deferred to the end because it creates `~/.pixi`; its read-back names `~/.cache/rattler/cache`, inside a path that was absent. pixi and just came from their GitHub releases into a scratch directory, never through a cache.

In a fresh `git clone --no-hardlinks --single-branch` with no `.pixi`, `.tools` or `build`:

| Run | Seconds | Result |
| --- | --- | --- |
| `just initialize` | 16.676 | Exit 0. 38 Gleam packages downloaded in 0.52 s into an empty cache; seven `tools.txt` pins installed, each matching its sha256; hook installed in the clone |
| `just check` | 183.112 | Exit 0. 57 Gleam tests and 402 checker tests; "All checks passed and the worktree is unchanged." |
| `just check`, network denied | 200.367 | Exit 0, the same counts and message |

The porcelain status was empty after each run. Monotonic-clock seconds exclude cloning. For comparison, 11's initialization with a warm Gleam cache on Darwin arm64 took 14.950 s.

Inside the namespace, `/proc/net/dev` lists only `lo`, and three probes fail: through the session proxy (exit 7, nothing listens on its loopback port there); by name with `--noproxy '*'` (exit 6, no resolver); and to a GitHub address directly (exit 7). [offline.sh](offline.sh) runs those probes and then the gate. To rerun it alone, on a clone that has already passed `just check`, use `sh offline.sh <clone> "$(mktemp -d)"` with pixi on `PATH`.

**How the run went.** [cold.txt](cold.txt) is the unedited transcript of `cold.sh`'s first version. That version ran the network-denied gate inline and passed a shell function name to Python's `subprocess`, so the step failed to start (`FileNotFoundError: 'offline'`) without running anything. It also listed interfaces from `/sys/class/net`, which shows the host's sysfs, not the new namespace. The caches were warm by then, so the cold half could not be repeated. The network-denied step moved into `offline.sh` with both faults fixed, and ran on the same clone at 19:13Z. That was about 36 minutes after its networked gate ended, a gap that spans a session restart; nothing touched the clone in between. One earlier `offline.sh` attempt, also at 19:13Z, stopped at `lock-check` because the session restart had dropped the bootstrap pixi from `PATH`; `offline.sh` now refuses to start without one. The committed `cold.sh` calls `offline.sh` in place of the inline step. Its only other change from the version that produced `cold.txt` reads `PRETTY_NAME` with `sed` instead of sourcing `/etc/os-release`, for shellcheck.

## 01: native Linux TLS and rebar3

```sh
pixi install --locked -e runtime
sh .scratch/bootstrap/evidence/35/native-linux.sh "$PWD" "$(mktemp -d)"
```

[native-linux.sh](native-linux.sh) is the native counterpart of [01's linux.sh](../01/linux.sh), without a container or a JIT flag. It runs [01's tls/run.sh](../01/tls/run.sh) and [rebar3/run.sh](../01/rebar3/run.sh) unchanged against this checkout's locked environments. In [the transcript](native-linux.txt):

- Both environments carry the same erlang 29.1.1 and openssl 3.6.5 builds. Each boots `otp_release` 29, which is `pixi.lock`'s erlang major.
- In both the default and the runtime environment, all six TLS cases match: the right CA by name and by IP SAN; the wrong CA by name and by IP; the wrong name; and the missing IP SAN.
- rebar3 compiles `ddskerl` 0.4.3 and `prometheus` 6.1.3, and the probe's counter reads 2. With rebar3 removed from `PATH`, `gleam build` fails with "The program `rebar3` was not found".

rebar3 prints its httpc proxy setting, with each `no_proxy` entry on its own line; the script folds each such block to its first line. Ticket 14's [tls-native.txt](../14/tls-native.txt) is a different, eight-case probe, of the client's own ssl and httpc options, and it covered the default environment only.

## 08: snapshot commands

```sh
sh .scratch/bootstrap/evidence/35/snapshots.sh "$(mktemp -d)"
```

[snapshots.sh](snapshots.sh) follows [08's birdie-check.sh](../08/birdie-check.sh). Its disposable clone borrows this checkout's `.pixi` and `.tools` and copies `build/packages`, and every `just` command runs with the network denied. In [the transcript](snapshots.txt):

- **Review.** With one character of `version_request_sent_by_fetch_version.accepted` changed, `just snapshots-review` runs the tests, which fail, and opens birdie's review. [review_pty.py](review_pty.py) gives the recipe a pseudo-terminal, waits for the menu's `>` prompt and types `a`. The session shows "Reviewing 1st out of 1", the diff of the changed line, `> a` and "Reviewed one snapshot". Afterwards the accepted file's sha256 is the committed `1427495…d079`, no `.new` remains and the worktree is clean.
- **Reject.** With the same edit, `just test` leaves a `.new` whose bytes are the committed file without its `file:` and `test_name:` lines, which accepting adds. `just birdie reject` removes the `.new` and leaves the edited bytes (`b6f0c12…756f`) in place; Git sees only the edit.
- **Stale delete.** With an `orphan.accepted` no test refers to, `just test` passes and `just birdie stale delete` removes the orphan. The other three accepted files hash as before, the worktree is clean, and `just snapshots-check` then passes.
- **Isolation.** birdie's referenced list is the clone's `build/birdie/knarr_referenced.txt`. Neither this checkout's list nor `$TMPDIR/knarr_referenced.txt` changed during the run, and this checkout's status and accepted snapshots are unchanged.

birdie 2.0.2 reads the review choice with `io:get_line("> ")` after printing the menu, so the driver answers a line, not a keypress. The first attempt failed its own wrong assumption, that a `.new` is byte for byte the accepted file; the assertion now states the real relation, shown above.

## 08: version fixture

```sh
python3 .scratch/bootstrap/evidence/35/version_fixture.py .
sh .scratch/bootstrap/evidence/35/kubernetes-source.sh "$(mktemp -d)"
```

**Capture.** Ticket 14 captured `/version` from kindest/node v1.35.8, the version ticket 10 chose, twice. [version.json](../14/version.json) is the local kind cluster on linux/arm64; the one-line reply in [s1-kind.txt](../14/s1-kind.txt) is the `cluster-s1` CI job on native linux/amd64. No cluster ran here, because the container has no Docker daemon. [version_fixture.py](version_fixture.py) reads `kind_version_body` out of `test/sans_io_example_test.gleam` and compares each of its five fields with both captures ([output](version-fixture.txt)). Every field is a JSON string in all three, and every value matches except `platform`, which follows the machine. The fixture needs no correction, so nothing goes back to 14.

**The `+` suffix.** [kubernetes-source.sh](kubernetes-source.sh) fetches two files at tag `v1.35.8` (tag object `0222da4…`, commit `1c2e10a…20d9fb`). That commit is the `gitCommit` both captures report, so it is the source of the server that answered. [The excerpt](kubernetes-v1.35.8.txt) shows:

- `hack/lib/version.sh` (blob `65595e6…`, lines 98–107) matches `KUBE_GIT_VERSION` against `^v([0-9]+)\.([0-9]+)(\.[0-9]+)?([-].*)?([+].*)?$`. It sets `KUBE_GIT_MINOR+="+"` whenever the `-…` group is present.
- Lines 177–178 pass that value into the binary as the `gitMinor` ldflag.
- `version.Info` in apimachinery's `pkg/version/types.go` (blob `6a18f9e…`) declares `Major`, `Minor` and `GitVersion` as `string`.
- Evaluating version.sh's own lines gives `minor=35` for `v1.35.8` and `minor=35+` for `v1.35.6-gke.1638000`.

[GKE's versioning page](https://docs.cloud.google.com/kubernetes-engine/versioning), "Last updated 2026-10-09 UTC" when fetched (sha256 `d0ecdac…b2c4`), says "GKE appends a GKE patch version number to the Kubernetes version (X.Y.Z-gke.N)". `1.35.6-gke.1638000` is its own example. So a GKE control plane built by this script from such a version reports `minor` as `"35+"`, as 08 recalled, and `minor` must stay a string. **Limitation:** this is the build script plus the published version format, not a reply from a managed cluster. A vendor that sets `KUBE_GIT_VERSION_FILE` supplies its own values. No managed cluster was authorized or observed.

## 04: intermittent checker test

```sh
sh .scratch/bootstrap/evidence/35/checkers.sh <initialized-clone> 20 "$(mktemp -d)"
```

The historical failure ran on the maintainer's Mac in 04's worktree, and its output was not kept: "Its name was lost with the output". No log of it exists in the repository or in this container. The only remaining source would be the maintainer's local session transcripts from 04. So [checkers.sh](checkers.sh) repeats the current suite, the 402 tests `just test-checkers` runs (87 at 04's time), in sequence in the cold clone. It keeps each run's JUnit XML and output so that a failure's name and message survive.

[The transcript](checkers.txt) shows all 20 runs, from 19:17Z to 20:14Z, exiting 0. Each run had 402 tests, 0 failed, 0 errors and 0 skipped, and took 160.9–173.5 s. That is 8,040 test executions without a failure. Runs 01–03 overlapped the native probes, the snapshot exercise and the Kubernetes fetch above. Run 05 overlapped a pre-commit hook run in this checkout, at 19:30Z. The rest ran alongside file edits and read-only git. **This does not identify the test, so the item stays open.** The bound was 20 runs, about 55 minutes, against roughly one failure in six recorded runs on the Mac. A Linux VM without concurrent worktrees may simply not reproduce it.

A read-only review of the 04-era suite at `0de7899` found no deterministic defect. That suite's test files, `conftest.py` and the checkers they exercise are unchanged at HEAD. The suite has no sleeps, clock comparisons, subprocess timeouts, ports or network access, and its random `ghp_` token always matches ripsecrets' built-in pattern. A "failed", rather than "error", outcome also puts the failure in a test body, not a fixture. Its leads, unverified, are for a rerun on the maintainer's Mac:

- **ripsecrets.** Every test in `test_ripsecrets_redacted.py` copies the pinned binary into a fresh temporary repository, at `0de7899` line 40 and still so at HEAD, then runs it there. So each test launches a binary at a path macOS has not seen before. The tests also require an exact exit status and output.
- **Load.** `test_run_project_check.py` starts about fifteen processes per test, so a transient process failure while other worktrees run their gates would surface there.

The next step is `checkers.sh` on the Mac, beside another worktree's `just check`, keeping the JUnit XML. If a run fails, keep a reproducer, and open a focused ticket if the fix is more than one line.

## 06: hosted audit

`audit.yml` reached `main` on 2026-10-08, so its first scheduled run is Monday 2026-10-12 06:00 UTC; none had happened. The maintainer authorized one manual dispatch on `main`. The GitHub connector's `POST …/actions/workflows/audit.yml/dispatches` returned `403 Resource not accessible by integration`, and it was not retried ([audit.json](audit.json)).

The one audit run on record is ticket 27's own dispatch on its branch at `d5c7178`, [run 38015514089](https://github.com/steven-cutting/knarr/actions/runs/38015514089). That branch's `audit.yml` adds hex and image jobs. Its External links job failed on three keda.sh URLs, all "Connection failed": `docs/DEFERRED.md:44` and two at `docs/OVERVIEW.md:560`. Its image scan also failed. It is neither `main` nor a scheduled run, so it does not close this item. Since 27's pull request #18 merged (`2de96a4`, after this evidence was gathered), `main`'s `audit.yml` carries those jobs too, so the first scheduled run will include them. The keda.sh failures are for whoever next runs the audit to reproduce, separately from this ticket. To close the item, either:

- the maintainer runs `gh workflow run audit.yml --ref main`, or
- someone records Monday's scheduled run.

In either case, record the run URL, commit and result.

## Open: the maintainer's primary hook

This needs the maintainer's own primary checkout, and authorization to use it. The installed hook is a prek shim that names an absolute `prek`, and every hook entry goes through `scripts/with-env.sh`, which resolves the environment from the checkout being committed in. A linked worktree would therefore check against its own `.pixi`, or fail for want of one, rather than exercise the primary's. The probe runs from the primary checkout, with its transcript written outside it:

```sh
sh .scratch/bootstrap/evidence/35/primary-hook.sh > <outside-path>/primary-hook.txt 2>&1
```

[primary-hook.sh](primary-hook.sh) touches nothing, and exits 2, unless every precondition holds:

- it runs in a primary checkout, by the test `scripts/install-hooks.sh` uses;
- the hook git would run, from `git rev-parse --git-path hooks/pre-commit`, which honours `core.hooksPath`, is executable;
- the hook's `PREK` is `<checkout>/.pixi/envs/default/bin/prek`, and that file is executable;
- the index is clean, no tracked file has unstaged changes, so prek has nothing to stash, and `src/hook_probe.gleam` does not exist.

It then stages `pub fn probe( ) { Nil }` as `src/hook_probe.gleam` and commits it under `env -i HOME="$HOME" PATH=/usr/bin:/bin`, the bare environment of [03's probe](../03/fresh-clone.sh), with signing off. It passes only if gleam format refused the commit: the output must carry the `gleam format check…Failed` line and name the file. Afterwards HEAD, the index and `git status` must be as they were and the file must be gone. A refusal for any other reason fails the run (exit 1). That includes a shim that falls back to a `prek` not on the bare `PATH` (exit 127) and an identity or signing error.

**It never leaves a commit.** A trap unstages and removes the file on every exit, including an interrupt. If the hook accepts the commit, the run fails and the trap resets HEAD to its recorded value with `git reset --soft`, then checks HEAD, the index and the status itself. It resets only when HEAD is the probe's own commit, by its message, directly on top of the recorded HEAD. Any other move of HEAD fails the run and is left, with the staged file, for the maintainer to inspect.

The container ran an earlier inline form of this probe on its own primary checkout. That form used the same file and the same refusal path, but neither `env -i` nor `-c commit.gpgsign=false`. `gleam-format` refused the commit, reporting "These files have not been formatted: src/hook_probe.gleam", and HEAD was unchanged. Its cleanup was unsafe, which the Codex adversarial review found: had the hook accepted, `git rm --cached` would have left the commit in place and a staged deletion behind. The script replaces it.

[primary-hook-stubs.sh](primary-hook-stubs.sh) checks the script's verdicts and cleanup against stub hooks. Each throwaway repository gets a prek-shaped shim, written as prek writes it, and a stub `prek` ([transcript](primary-hook-stubs.txt)):

- a stub that refuses with gleam format's output passes, exit 0;
- an accepting stub fails the run, exit 1, after the trap undoes its commit;
- a stub that exits 127 with no output fails the run, exit 1, as "not by gleam format";
- a missing hook, a shim naming another checkout's `prek`, and a linked worktree each stop the run before it touches anything, exit 2;
- a stub that moves HEAD to a commit of its own fails the run, exit 1, and HEAD and the staged file are left as they are.

In the first six cases, HEAD, the index and the status end as they began, and no probe file is left. No case sends an interrupt; the accepting case takes the same EXIT trap. The stubs ran on 2026-10-13 (UTC) on a Mac, Darwin arm64 with Apple Git 2.50.1. They ran in this branch's linked worktree at `c2f0449`, with both scripts untracked; the transcript records each script's sha256, which the committed files match. Neither the container's run nor the stubs exercised the maintainer's hook, so the item stays open.

## Open: the restricted agent sandbox and Copilot

- **05/06, Taplo under the macOS agent sandbox.** The failure is in macOS's system-configuration framework, under the agent runtime's own sandbox profile, and needs a Mac. Here `toml-check` passed inside the Linux namespace above, which is not that sandbox and is not counted.
- **09, Copilot discovery.** This needs an actual Copilot session, with its runtime version and one harmless skill invocation. This session is Claude Code, and its discovery of `.agents/skills/` is not Copilot evidence.

## Network and authorization

The maintainer authorized, for this session, each of the following:

- the pixi and just release downloads;
- `just initialize` in the cold clone and in this checkout;
- `pixi install --locked -e runtime` and the rebar3 probe's four hex packages, which Gleam reported in 0.02 s, evidently from its cache;
- the Kubernetes source at `v1.35.8` and GKE's versioning page;
- read-only GitHub queries;
- one `audit.yml` dispatch;
- bringing `lo` up inside the namespace;
- pushing this branch and opening its pull request.

Before any of that was authorized, one `gh auth status` ran during exploration. It reached GitHub and failed on the invalid token. Nothing else left the container before authorization.
