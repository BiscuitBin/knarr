---
title: "Testing"
kind: "reference"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["testing_toolkit", "snapshot_workflow", "sans_io_pattern", "coverage_workflow"]
requires: []
---

# Testing

This page covers knarr's unit tests: the tools, the snapshot workflow, and the sans-IO pattern every Kubernetes and worker call follows. The unit suite runs in `just check`; the optional coverage command is described below. The cluster tiers belong to [Decision 0007](../decisions/0007-local-cluster.md#tiers), which [ticket 10](../../.scratch/bootstrap/issues/10-spike-local-cluster.md) settled.

## Tiers known so far

0007's table says what each tier proves, what it cannot prove, and where it runs. In one line each:

- **unit**: gleeunit, qcheck and birdie, through `just test` in `just check`. The rest of this page covers it.
- **kwok**: a real apiserver and real controllers with simulated pods, in its own CI job, outside the read-only gate.
- **kind**: everything kwok gives, plus real pods. 13's smoke test and the e2e job use it, the latter with [the fake worker fixture](fake-worker.md) as its workload.
- **GKE**: run by hand against a short-lived cluster, never on every change.

The gate also runs the diagnostics adapter against local HTTP sockets and
crashes a supervised listener to prove recovery without resetting metrics,
once on an OS-assigned port and once on a fixed port that it must rebind.
These tests need no cluster or external network. Test and
lint recipes select a loopback address and ephemeral application port so concurrent worktrees do
not contend for port 8080 or expose metrics on the LAN. The checker suite also
starts isolated Erlang subprocesses to verify startup failure, exhausted
supervision and normal shutdown exit codes; its recipe builds first. Image and cluster checks are separate recipes in
the [local cluster guide](../how-to/local-cluster.md).

## The toolkit

Every package is a dev dependency. `gleam.toml` gives the range, and `manifest.toml` pins the version and checksum.

| Package | Version | Role |
| --- | --- | --- |
| gleeunit | 1.11.0 | Runs every public function whose name ends in `_test`, in any module under `test/`. |
| qcheck | 1.0.5 | Property tests: generators, shrinking, and 1000 cases by default. |
| birdie | 2.0.2 | File snapshots under `test/birdie_snapshots/`, with review, accept and stale commands. |
| glinter | 2.19.2 | Lints `src/` and `test/` in `just lint-gleam`. |

**Assertions.** A test states what it expects with Gleam's `assert`, such as `assert decode(body) == Ok(version)`. Each expected value comes from somewhere independent of the code under test: a literal, a worked example, or the spec.

**Fixed seeds.** Every property in the gate passes a fixed seed:

```gleam
let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(8))
use version <- qcheck.run(config, versions)
```

`qcheck.given` and `default_config()` draw a random seed, and qcheck never prints it. On failure it prints the original value and the shrunk one, but a failure under a random seed cannot be replayed. To explore further, change the seed or raise the case count, and commit the new value.

**glinter.** `[tools.glinter]` in `gleam.toml` lints `src/` and `test/`, with warnings as errors. Test functions declare `-> Nil`, because `missing_type_annotation` applies to them too. `unused_exports` is off for `*_test.gleam` files only: gleeunit finds those functions by name, so no module ever imports them. Helper modules in `test/` keep the rule. glinter skips a file it cannot read or parse, a directory it cannot read, and a `gleam.toml` it cannot parse, and still exits 0. So `just lint-gleam` runs it through `scripts/checks/run_glinter.sh`, which fails on any such report.

**Compiler warnings.** `just build` runs `gleam build --warnings-as-errors`, which compiles `test/` as well as `src/`. A warning in test code therefore fails the gate. `gleam test` alone only prints it.

## Coverage reports

Run `just coverage` for source-line coverage of application startup and the
existing Gleam test suite. It builds with warnings as errors, preserves the
snapshot workflow, and prints each production source file's covered and total
executable lines plus uncovered line numbers. Gleam and Erlang FFI have separate
totals. A module that is never called still counts; one with no executable lines
shows `n/a`. Tests, dependencies and compiler-generated entrypoints do not count.

When collection and report generation complete, the command prints the fresh
directory under `build/coverage/` containing `coverage.txt` and `coverage.json`.
The JSON lists source-relative paths,
languages, covered and uncovered line numbers, per-file counts, separate totals,
and the test command's exit code. Failed tests still produce useful reports when
collection completes, but the command exits nonzero. Cache or build failures
create no run directory. Missing instrumentation or incomplete collection can
leave an unfinished directory without reports; its path is not printed. These
failures return nonzero even if the test entrypoint exits zero; an old report
cannot satisfy a new run.

The command is **report only**, outside `just check`, with no percentage floor.
Its command tests run in the checker suite. Cached packages and the pinned local
toolchain are required; missing or stale cache inventory is refused before Gleam
can fetch. Initialization needs separate network authorization. Runtime artifacts
are ignored, and local HTTP tests use loopback. The command neither accepts
snapshots nor rewrites source files.

Coverage describes execution, not correctness. External declarations can report
uncalled generated Gleam wrappers even when their Erlang functions execute.
Alternatives on the same physical line share one result. Checker subprocesses,
cluster tests, and shutdown after collection are outside this report. See
[Decision 0011](../decisions/0011-coverage.md) for the measured limitations and
the reason for deferring a floor. A snapshot contributes execution counts but
still proves no clause.

## Snapshots

A snapshot test writes a value out as text, a "picture", and compares it with the accepted copy in `test/birdie_snapshots/<title>.accepted`. A snapshot has two uses only:

- to show a reviewer a value that reads better as a picture than as assertions, such as a request as it goes out
- to detect a change cheaply

### A snapshot proves no clause

A snapshot records what the code did when someone accepted it. If they accepted a bug, the snapshot now defends that bug. So every obligation `just plan-spec` lists for a spec module has its own named test, whose assertion states the expected value. No clause-to-test table names a snapshot test.

### Writing a snapshot test

- Write it after the behaviour's own tests are green.
- Name it `snapshot_<subject>_test`.
- Feed it a fixed, deterministic input. Never use a property's generated value: one title holds one picture, and every generated case would overwrite it.
- Render the picture in test code, as [http_picture.gleam](../../test/http_picture.gleam) does. A picture is for reviewers and is not a product format.
- Keep trailing whitespace out of the picture. editorconfig-checker reads the `.accepted` files, and birdie adds the one final newline itself.
- Give each test a unique, literal title. birdie names the file after the title. `review` and `accept` find the test through that literal, and they fail on a duplicate.

### A changed snapshot is a question

A diff in an `.accepted` file is reviewed like code. The pull request that changes a snapshot says why the new picture is right. Accepting is a decision, not a repair.

## Snapshot workflow

| Recipe | In `just check` | Writes | Does |
| --- | --- | --- | --- |
| `just test` | yes | ignored paths only | Removes every `.new`, then runs every test. A new or changed snapshot fails and leaves `<title>.new`. |
| `just snapshots-check` | yes, after `test` | nothing | Fails on a pending `.new`, then on an accepted snapshot the last `just test` did not reference. |
| `just snapshots-stale` | no | ignored paths only | Runs the tests and, if they pass, lists stale snapshots. A test that fails before it snaps would make its snapshot look stale. |
| `just snapshots-review` | no | tracked files, when you accept | Runs the tests (ignoring their failure), then opens birdie's interactive review. |
| `just snapshots-accept` | no | tracked files | Runs the tests, then accepts every pending snapshot without prompting. Read the diff before committing. |
| `just birdie <command>` | no | depends on the command | Any other birdie command, such as `reject` or `stale delete`. |

The usual loop: change the code, run `just test`, and see a snapshot fail with its diff. Run `just snapshots-review`, or `just snapshots-accept` if you are an agent. Then read `git diff test/birdie_snapshots/` and commit the change with its reason.

### birdie has no check mode

birdie 2.0.2 has no mode that only compares: no flag, environment variable or setting. When a snapshot is new or changed, `birdie.snap` always writes `<title>.new` beside the accepted file, prints the picture or diff, and fails the test. The gate's "read-only" means what its runner checks: nothing Git can see may change ([Decision 0004](../decisions/0004-gate-checkers.md)). So `.gitignore` ignores `test/birdie_snapshots/*.new`, just as it ignores `build/`. A failing gate leaves the `.new` that `just snapshots-review` reads next. `just test` removes every `.new` before it runs, so each one left afterwards is a picture from that run, and no accept can take an older one. The [ticket 08 evidence](../../.scratch/bootstrap/evidence/08/README.md) shows each case.

### Each worktree keeps its own referenced list

During a test run, birdie appends the name of each accepted snapshot it reads to `$TMPDIR/knarr_referenced.txt`, and `stale check` compares the snapshot folder against that list. The file is named after the project only. Without a change, every worktree on a machine would share one list, and one worktree's test run would decide another's stale check. So every recipe that runs birdie sets `TMPDIR` to `build/birdie`, which is ignored.

`TMPDIR` is set per recipe, not exported from the Justfile, because the gate runner's baseline file and pytest's `tmp_path` also read it. `just test` deletes the list first: birdie empties it only when a run reads an accepted snapshot, so a run that read none would leave the old list behind.

Run birdie's other commands through `just birdie`, for example `just birdie stale delete`. A bare `gleam run -m birdie stale delete`, as birdie's own hints suggest, reads the shared list in the system's temporary directory instead.

### Rejecting and deleting

- `just birdie reject` deletes every pending `.new`.
- `just birdie stale delete` deletes every accepted snapshot the last `just test` did not reference. Those are tracked files.

`review`, `accept` and `reject` also rewrite the `file:` and `test_name:` header of an existing `.accepted` file whose test moved or was renamed. That is a tracked change too.

## The sans-IO pattern

[Decision 0002](../decisions/0002-sans-io-boundaries.md) keeps effects behind sans-IO boundaries. An HTTP call is split three ways:

1. **A pure builder** takes values and returns a `Request(String)`.
2. **A pure decoder** takes a `Response(String)` and returns a typed result. Every way it can fail is a named error.
3. **A function that does the I/O** only through a `send` it is given, of type `fn(Request(String)) -> Result(Response(String), e)`. Production passes `k8s_http.send(_, k8s_http.Tls(ca_file))`, the verified-TLS adapter from [Decision 0013](../decisions/0013-in-cluster-client.md); `gleam_httpc` is not used because it cannot carry a CA file. A test passes a closure.

The builder and the decoder are tested by value. The I/O function is tested with a closure fake. The fake asserts the request it was handed and returns a canned response. A second fake returns `Error(_)`, to test the failure path. To snapshot the outgoing request, take the picture inside the fake: it then shows exactly what the function sent, not a request the test built again.

The real client, `src/knarr/k8s_client.gleam` with `test/k8s_client_test.gleam`, follows the same shape for the pod list and the annotation patch. The worked example lives in `test/` only, because it is not part of knarr. It models the apiserver's `GET /version`, a real, read-only call that decides nothing:

- [sans_io_example.gleam](../../test/sans_io_example.gleam): the builder, the decoder and `fetch_version`
- [sans_io_example_test.gleam](../../test/sans_io_example_test.gleam): named tests, the closure fakes, a fixed-seed property, and a snapshot taken inside the fake
- [http_picture.gleam](../../test/http_picture.gleam): renders a request as a picture

These tests prove the pure parts and how they are joined. They prove nothing about real HTTP or a real apiserver. The kwok and kind tiers cover those, as 0002 and 0007 expect.

Gleam has no HTTP mocking library like respx, and this pattern takes its place. Use `http_server_mock` only where a test needs a real socket. It brings in mist and gleam_otp, so it is not a dependency until a ticket needs it. TestContainers is skipped; 0007 says why.

## The loopback TLS test and the OTP pin

[k8s_http_test.gleam](../../test/k8s_http_test.gleam) runs `k8s_http.send` against a loopback TLS responder in [k8s_http_test_ffi.erl](../../test/k8s_http_test_ffi.erl). `public_key:pkix_test_data/1` builds three chains in memory: a server certificate with an `iPAddress` subjectAltName for 127.0.0.1, a certificate from the same CA whose only subjectAltName is a DNS name, and an unrelated CA. Only the CA PEMs are written, under `build/`, so no key is committed. On OTP 29, `pkix_test_data/1` returns the root twice in `cacerts` when the chain has no intermediate. `write_ca` deduplicates it with `lists:usort`, which stays correct if a later pin stops repeating it.

Some of these tests watch OTP 29's `ssl` and `httpc`, not knarr. When the OTP pin moves (ticket 27), a failure in one of them means an OTP term or default changed. [Decision 0013](../decisions/0013-in-cluster-client.md#findings) records what each finding is and what reopens it.

### httpc error shapes

`k8s_http_ffi` turns httpc's error term into a `SendError`. On OTP 29:

| httpc returns | `SendError` | Fails if the mapping changes |
| --- | --- | --- |
| `{failed_connect, [{to_address, _}, {inet, [inet], {tls_alert, {unknown_ca, _}}}]}` | `TlsAlert("unknown_ca")` | `send_refuses_a_wrong_ca_with_no_fallback_test` |
| a `failed_connect` list with a `{tls_alert, {bad_certificate, _}}` entry | `TlsAlert("bad_certificate")` | `send_refuses_a_same_ca_certificate_without_the_ip_san_test` |
| `{failed_connect, [{to_address, _}, {inet, [inet], econnrefused}]}` | `ConnectFailed("econnrefused")` | `send_reports_a_closed_port_test` |

[tls.txt](../../.scratch/bootstrap/evidence/14/tls.txt) holds the first and third terms as httpc returned them. For the second it holds only the raw `ssl:connect` alert, whose text names `hostname_check_failed`; the test is the record of the httpc wrapper.

The FFI does not read the list by position. It walks it and matches each entry by shape:

- `{_, _, {tls_alert, {Alert, _}}}` gives `TlsAlert(Alert)`, and `{_, _, timeout}` gives `Timeout`.
- `{_, _, Reason}` with an atom `Reason` gives `ConnectFailed(Reason)`.
- `{_, [_ | _], Reason}` with any other `Reason` gives `ConnectFailed` with the term rendered and cut at 200 bytes.
- Any other entry, such as `{to_address, _}`, is skipped. An exhausted list gives `ConnectFailed("unknown")`.

On a direct connection the first element is the socket family, `inet` here and `inet6` for IPv6. In inets 9.8, httpc's proxy-tunnel path reports `{tls, TLSOptions, Reason}`, which the same clauses match. So a reordered list or another first element still maps, and fails none of the three tests; [tls/run.sh](../../.scratch/bootstrap/evidence/14/tls/run.sh) prints the raw terms. A new entry shape inside the list is a value, and the named test then fails with the term in its output. Two shapes still raise in the FFI instead: a `failed_connect` reason that is not a list, and an alert that is not an atom. Neither has been seen. No test exercises `timeout`, `inet6` or the tunnel path.

### SNI

`send_sends_the_ip_literal_as_sni_on_this_pin_test` asks the responder's `/sni` path which `server_name` arrived, and expects `"127.0.0.1"`. OTP 29 sends a string IP host as SNI, although RFC 6066 §3 does not permit an IP literal in `HostName`. knarr keeps the default, because on this pin `{server_name_indication, disable}` also turns off the hostname check: with it, the SNI test gets `none` and `send_refuses_a_same_ca_certificate_without_the_ip_san_test` gets a response. ssl sends no SNI for an IP given as a tuple and still checks it against the `iPAddress` SAN, but httpc hands ssl the URL's host as a string. If the SNI test fails after a pin move, its body shows what arrived; read the SNI row of Decision 0013 before changing `k8s_http_ffi`.

### Stopping a bare actor in a test

A gleam_otp 1.3.0 actor started outside a supervisor cannot be stopped with `gen_server:stop`. On OTP 29, `gen_server:stop` calls `proc_lib:stop/3`, which sends the `terminate` system message through `sys:terminate`. gleam_otp's `gleam_otp_external:convert_system_message/1` handles `get_status`, `get_state`, `suspend` and `resume`, and its TODO lists `{terminate, Reason}` among the system messages it does not support yet. The actor logs "Actor discarding unexpected message" and keeps running. So `gen_server:stop/1`, whose timeout is `infinity`, blocks forever, and `gen_server:stop/3` exits the caller with `timeout` and leaves the actor alive.

Stop a bare actor with the signal its supervisor would send: unlink it, then `exit(Pid, shutdown)`, which an actor that does not trap exits dies on. `stop_probe/1` in [s1_probe_test_ffi.erl](../../test/s1_probe_test_ffi.erl) does this. Unlike a supervisor, it does not wait for the actor to exit. A test that reuses a file, a name or a subject straight afterwards should monitor the actor and wait for its `'DOWN'` message. Production is unaffected, because a supervisor stops its children with exit signals. A gleam_otp supervisor runs OTP's `supervisor` behaviour and does take `gen_server:stop`, which `stop_root/1` uses. This is a note, not an upstream report: the gap is already in gleam_otp's own TODO. Recheck it when gleam_otp moves past 1.3.0.
