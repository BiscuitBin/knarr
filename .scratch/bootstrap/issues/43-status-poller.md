# 43: Spec-then-build: the status poller

**Context:** Ticket [18](18-elicit-worker-contract.md) settled the worker contract in `docs/specs/worker_contract.allium`: one GET of `http://<podIP>:<port>/knarr/v1/status` over plain HTTP, a 200 JSON object with `cost` and `accepting` as valid, 404 as not found, everything else invalid. Nothing fetches or decodes it yet, and neither [31](31-spec-then-build-reconcile-core.md) nor [32](32-spec-then-build-ownership-lifecycle.md) covers that adapter. The per-poll timeout, jitter, concurrency bound and no-overlap rule are 24's.

**What to build:** The poller module from the `StatusEndpoint` contract: a pure request builder (URL from a pod IP of either family, port and path; the User-Agent header), a pure decoder from an outcome (a response, or a refused, timed-out or unreachable transport) to a reading, with the body cap, the `draining` predicate over a reading, and a sending function injected as in `k8s_client`. Tests derived with `propagate` first, then the code, in the order the `gleam-change` skill sets. The builder takes the pod IP as a string; reading it off the `Pod` value [41](41-k8s-client-spec-then-build.md) extends, and the Ready condition, are 31's.

**Non-goals:** The schedule, timeout and concurrency (24). What knarr does with a reading over time (21, 31). The fake worker (29).

**Blocked by:** 18, 24

**From 18:** the hand-back notes of [ticket 18](18-elicit-worker-contract.md) and the `StatusEndpoint` contract.

**MVP critical path:** yes. Every reading the reconciler maps comes from it.

**Status:** ready-for-agent

- [ ] The builder and decoder clauses of `StatusEndpoint` (`Pull`, `Versioning`, `RequestHeaders`, `ValidReading`, `NotFoundReading`, `InvalidReading`, `Payload`) each have a test that traces to them. The decoder is tested by value for each case the contract names: a valid object with extra members, a 404, a 3xx, a 500, a body over 4096 bytes, a non-object, a missing member, a null, a string boolean, a fractional cost, a negative cost, a 404 with an HTML body and a 404 over 4096 bytes (both `not_found`), and a refused, a timed_out and an unreachable outcome (each the reading of the same name). `draining` is tested by value for a valid reading with `accepting` false, a valid reading with `accepting` true, a `not_found` reading and an `invalid` reading. `Discovery`'s "every pod with a pod IP is polled" and `ReadinessWarning` are 31's, which selects pods and holds the mapped value; `Served` is the worker's, which 29 tests.
- [ ] The request builder brackets an IPv6 pod IP and sends `User-Agent: knarr/<version>`.
- [ ] `send` returns an `Outcome` and stays injected; the HTTP adapter maps its errors to refused, timed_out and unreachable over plain HTTP (`Transport`); any FFI is a named `*_ffi.erl` module; the poller runs under a supervisor.
- [ ] `just check` passes and the hand-back gives the `plan-spec` obligation count.
