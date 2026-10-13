# 43: Spec-then-build: the status poller

**Context:** Ticket [18](18-elicit-worker-contract.md) settled the worker contract in `docs/specs/worker_contract.allium`: one GET of `http://<podIP>:<port>/knarr/v1/status` over plain HTTP, a 200 JSON object with `cost` and `accepting` as valid, 404 as not found, everything else invalid. Nothing fetches or decodes it yet, and neither [31](31-spec-then-build-reconcile-core.md) nor [32](32-spec-then-build-ownership-lifecycle.md) covers that adapter. The per-poll timeout is budget's `config.poll_timeout`, 5 seconds by default and install-configurable (budget `Timeout`); jitter, the concurrency bound and the no-overlap rule are [46](46-spec-then-build-poll-schedule-and-patcher.md)'s.

**What to build:** The poller module from the `StatusEndpoint` contract: a pure request builder (URL from a pod IP of either family, port and path; the User-Agent header), a pure decoder from an outcome (a response, or a refused, timed-out or unreachable transport) to a reading, with the body cap, the `draining` predicate over a reading, and a sending function injected as in `k8s_client`. Tests derived with `propagate` first, then the code, in the order the `gleam-change` skill sets. The builder takes the pod IP as a string; reading it off the `Pod` value [41](41-k8s-client-spec-then-build.md) extends, and the Ready condition, are 31's.

**Non-goals:** The schedule and concurrency ([46](46-spec-then-build-poll-schedule-and-patcher.md)); the timeout's value is 24's and is injected here. What knarr does with a reading over time (21, 31). The fake worker (29).

**Blocked by:** 18, 24

**From 18:** the hand-back notes of [ticket 18](18-elicit-worker-contract.md) and the `StatusEndpoint` contract.

**From 24:** the timeout `send` enforces is budget `config.poll_timeout`, 5 seconds by default and valid from 1 second to below the install-wide poll interval, install-wide with no per-Deployment override; the poller takes it as a parameter rather than hard-coding the default.

**MVP critical path:** yes. Every reading the reconciler maps comes from it.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] The builder and decoder clauses of `StatusEndpoint` (`Pull`, `Versioning`, `RequestHeaders`, `ValidReading`, `NotFoundReading`, `InvalidReading`, `Payload`) each have a test that traces to them. The decoder is tested by value for each case the contract names: a valid object with extra members, a 404, a 3xx, a 500, a body over 4096 bytes, a non-object, a missing member, a null, a string boolean, a fractional cost, a negative cost, a 404 with an HTML body and a 404 over 4096 bytes (both `not_found`), and a refused, a timed_out and an unreachable outcome (each the reading of the same name). `draining` is tested by value for a valid reading with `accepting` false, a valid reading with `accepting` true, a `not_found` reading and an `invalid` reading. `Discovery`'s "every pod with a pod IP is polled" and `ReadinessWarning` are 31's, which selects pods and holds the mapped value; `Served` is the worker's, which 29 tests.
- [x] The request builder brackets an IPv6 pod IP and sends `User-Agent: knarr/<version>`.
- [x] `send` returns an `Outcome` and stays injected; the per-poll timeout is a parameter of the adapter, 5 seconds by default; the HTTP adapter maps its errors to refused, timed_out and unreachable over plain HTTP (`Transport`); any FFI is a named `*_ffi.erl` module; the poller runs under a supervisor.
- [x] `just check` passes and the hand-back gives the `plan-spec` obligation count.

## Hand-back notes

### What changed

- `src/knarr/poller.gleam`, pure with no FFI: the config defaults `status_path`, `status_port` and `max_body_bytes`; the types `Endpoint`, `Status`, `Transport` (`Refused`, `TimedOut`, `Unreachable`), `Outcome = Result(Response(BitArray), Transport)` and `Reading` (`Valid(Status)`, `NotFound`, `Invalid`, `Failed(Transport)`); `request(endpoint:, version:)`, which brackets an IPv6 pod IP and sets `user-agent: knarr/<version>` and no other header; `decode`, which checks the 4096-byte cap before parsing and reads a 404 as `NotFound` whatever its body; `draining`; and `poll(endpoint:, version:, send:)`, whose only I/O is the injected `send`.
- `src/knarr/poller_http.gleam` and `poller_http_ffi.erl`: `send(request:, timeout_ms:)` and `default_timeout_ms = 5000`. It makes one synchronous `httpc:request` through a stand-alone profile registered as `knarr_poller_httpc`. httpc's `timeout` and `connect_timeout` are set to the timeout, and on expiry httpc cancels the request. A synchronous call answers to an alias that httpc releases afterwards, so a late answer is dropped and nothing is left behind in the caller; the asynchronous form the plan named left an alias per call. Three httpc defaults are overridden, each with a test:
  - `{autoredirect, false}`: a 3xx is returned, never followed.
  - `{autoretry, 0}`: a 503 with Retry-After is returned at once. httpc's retry goes through a registered manager name that a stand-alone profile lacks, so without this the poll timed out.
  - `{ipv6_host_with_brackets, true}`: an IPv6 poll's Host header is `[addr]:port`.

  The FFI sets the family per request with `{socket_opts, [{ipfamily, inet | inet6}]}`. A bare `inet6` in `socket_opts` loses to the profile's `inet`, and `ipfamily inet6fb4` would first try an IPv4 literal over inet6, which is a resolver lookup of the address. Every poll therefore gets its own connection, which httpc closes after the response. `supervised()` starts the profile under its own supervisor, which allows three restarts a minute as the S1 probe's does, so a crashing profile cannot use up the root's two-in-five-seconds tolerance. A poll in flight when the profile dies is answered at once as `Unreachable`. `version()` reads the `.app` `vsn`.
- `src/knarr/runtime.gleam`: `start` takes `poller: Bool`. The application (`application_ffi.erl`) turns it on, so its root has the listener at id 0, the profile's supervisor at id 1 and any S1 probe at id 2. httpc names the profile's ETS tables after the profile, so there can be only one profile per VM. `gleam test` starts the application, so the tests' own roots run with `poller: False`, and the adapter tests send through the application's profile. This changes how the tests use the agreed shape, not the shape: the profile is stand-alone and registered by name.
- `test/runtime_test_ffi.erl` and `scripts/checks/tests/test_application.py` now select the listener by child id 0 rather than as the root's only child. `scripts/checks/tests/test_coverage.py` now picks a snapshot that contains `application/json` rather than the first one globbed, because the new snapshot has no such header.
- Tests: `test/poller_test.gleam` (pure, with closure fakes and one snapshot, `status_request_sent_by_poll`), `test/poller_http_test.gleam` with `poller_http_test_ffi.erl` (a `gen_tcp` responder on 127.0.0.1 and ::1), and a runtime test that the application's root runs the profile's supervisor as child 1.
- `docs/reference/testing.md`: the poller in the sans-IO section, and a table of the poller's httpc error terms. `CHANGELOG.md`: one Added line.

### What was verified

- Each clause test traces to its clause (`// StatusEndpoint.<Clause>`): `Pull`, `Versioning`, `RequestHeaders`, `ValidReading`, `NotFoundReading`, `InvalidReading`, `Transport` and `Payload`. That covers every case this ticket lists, plus a body of exactly 4096 bytes, `1.0`, `1e2`, a big integer and a wrong or missing Content-Type.
- `just plan-spec docs/specs/worker_contract.allium` reports 22 obligations, unchanged. Each has a named test or a comment naming the test that discharges it. `just check-specs` reports no diagnostic.
- On the adapter: a 200 over IPv4 and IPv6; a 404; a 302 returned rather than followed; a 503 with Retry-After returned within a second; a bracketed Host header over IPv6; a closed port is `Refused` over both families; a silent accept with a 200 ms timeout is `TimedOut` within 200 to 1500 ms; an RST is `Unreachable` (httpc returns `socket_closed_remotely`); exactly one `User-Agent: knarr/0.1.0` reaches the worker; `version()` equals `gleam.toml`'s version line; and when the profile is killed, a poll in flight returns `Unreachable` within a second, its supervisor restarts it under the same name, and a later send succeeds.
- `just format-check`, `just build`, `just test` (109 tests) and `just check` all pass.
- A code review of the branch reported 14 findings. These were fixed: the 503 retry, the per-call alias, the unbracketed IPv6 Host header, the profile sitting directly under the root, the doc that said an in-flight poll times out when the profile dies (it is answered as `Unreachable`), and `version()` crashing with a bare `case_clause` on an unloadable `.app`. The rest are under the choices and risks below.

### What later tickets need

- **46:** call `poller.poll(endpoint:, version: poller_http.version(), send: poller_http.send(_, timeout_ms: <budget poll_timeout>))` from a process in the VM where the application's profile, `knarr_poller_httpc`, is registered. Read `version()` once rather than on every poll. A poll with no profile registered crashes the caller. The concurrency bound, jitter and no-overlap are still yours. `send` blocks its caller for up to the timeout, so run polls in worker processes.
- **31:** `Reading` is `Valid(Status(cost:, accepting:))`, `NotFound`, `Invalid` or `Failed(Refused | TimedOut | Unreachable)`. `poll` takes the pod IP as the string 41's `Pod` will carry, and the port and path come from config (19) or the defaults.
- **21:** `Failed(Transport)` keeps refused, timed_out and unreachable distinct, as the contract names them.
- **29:** the adapter test's responder imitates the fake worker's endpoint: a status object on 200, and 404 for a path it does not serve. The fake worker's own tests are what prove `Served`.

### Choices a maintainer may reverse

- A poll that starts while the profile is being restarted crashes its caller, as the plan settled for a missing profile. A poll already in flight when the profile dies gets `Unreachable` instead. Returning `Unreachable` for the restart window too would make the two consistent; it is one clause in `poller_http_ffi:profile/0`.
- `send` crashes on a method other than GET, since the contract polls only with GET and `Transport` has no value for a refused method.
- `runtime.start` takes `poller: Bool` only because the profile is one per VM and the tests start roots beside the application. The production tree with the probe on (listener, profile supervisor, probe) is not tested as a whole; the probe test runs with `poller: False`.
- Three obligation tests, the value-equality and entity-fields tests for `Header`, `Response` and `Outcome`, exercise gleam_http's types and a Gleam `Result`, because the module maps the contract's values onto those. They cannot fail on a change to `poller.gleam`.

### Residual risks

- The adapter does not bound the body. httpc reads every response whole, a large 404 included, before `decode` applies the 4096-byte cap, so a misbehaving worker can make knarr buffer an arbitrarily large body.
- On CI, IPv6 has been tested only on loopback (`::1`, present on ubuntu-24.04 and macOS). A pod network without IPv6 support gives `Unreachable` or `Refused` for an IPv6 pod IP, which reconcile then handles.
- No test exercises a connect that times out (`failed_connect` with `timeout`, the NetworkPolicy drop). It maps to `TimedOut` by shape only.
- Each poll opens and closes its own TCP connection. At poll intervals of seconds this costs little, and no poll can reuse a stale connection to a recycled pod IP.
- The per-poll timeout starts once httpc's manager has accepted the request. That call to the one profile manager has no bound, so under 46's concurrency a backed-up manager could hold a poll past `timeout_ms`. 46 may need to bound it from outside, for example by killing a poll process at the timeout.
- `test/poller_http_test_ffi.erl`'s `closed_port/0` repeats the helper in `k8s_http_test_ffi.erl`, and `poller_http_ffi`'s `failed_connect` walk and header conversion repeat `k8s_http_ffi`'s. Each module keeps its own, as the existing test FFIs do.
