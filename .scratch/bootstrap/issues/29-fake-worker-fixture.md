# 29: Fake-worker fixture

**Context:** A §3 success criterion runs a KEDA-scaled Deployment with a mixed fake-worker load on kind and compares how many busy pods are killed with and without knarr. §9.16 names a fake worker image. The worker contract comes from 18.

**What to build:** A configurable worker image that implements the elicited worker contract. A control endpoint can set its cost, its accepting state and its failure modes at runtime, so the round-2 KEDA e2e harness can drive a realistic mixed load.

**Non-goals:** The KEDA e2e harness and the success-criterion run (round 2). knarr's poller.

**Blocked by:** 13, 18

**MVP critical path:** yes. The MVP success criterion is measured with it.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] The status endpoint matches the clauses from 18 exactly, and tests trace each clause.
- [x] A control endpoint sets cost, accepting or draining, response latency, and failure modes (timeout, 5xx, 404, invalid payload) per pod at runtime.
- [x] On SIGTERM it drains gracefully within a configurable time and records whether it was busy when killed somewhere that outlives the pod (for example a line the harness scrapes before deletion completes, or a push to a collector endpoint), so a test run can count busy kills after the pods are gone. The ticket names the sink: **the collector**, the same image in collector mode as a one-replica Deployment behind the `fake-worker-collector` Service, which keeps one kill record per pod at `GET /kills`.
- [x] The image is built the same way as knarr's (13): non-root, small, and loadable into the cluster from 10.
- [x] A kind smoke test deploys several replicas, sets mixed states through the control endpoint, and reads them back from the status endpoint.

## Hand-back notes

The fake worker's reference page, [docs/reference/fake-worker.md](../../../docs/reference/fake-worker.md), is the user-facing record: configuration, both endpoints, the failure modes and the readings they produce, the drain, the collector, the recipes and the clause-to-test table. These notes record what that page does not.

### What changed

- **A second Gleam project, `fixtures/fake_worker/`.** It cannot live in knarr's package: knarr's erlang-shipment would carry it, and running any module there starts knarr's application first. It locks the same mist, OTP and stdlib versions as knarr (`scripts/checks/tests/test_fake_worker_manifest.py` holds both manifests together). It has no application start module, because `gleam test` and glinter start the package's application and must never boot a worker.
  - Pure modules, in the sans-IO shape of Decision 0002: `config` (the environment), `worker` (the state machine: control patches, SIGTERM, the drain), `status` (the contract surface), `control` (strict decoding), `collector` and `kill_record`.
  - `server` holds the adapters: a rest_for_one tree of the state actor, the status listener, the control listener and the sink actor, with the clock, delivery, stopping the VM and logging injected. `fake_worker_ffi.erl` is the one FFI module. It reads the environment, stops and restarts the status listener for `refused`, PUTs over httpc, and replaces OTP's SIGTERM handler on `erl_signal_server` with one that tells the state actor to drain. If that fails, it falls back to `init:stop()`.
  - `main` installs the handler only in worker mode. It monitors the tree as knarr's `application_ffi:await_shutdown` does, so a dead tree exits the VM with status 1.
- **The gate.** New `check` recipes `fake-worker-manifest-check`, `fake-worker-build`, `fake-worker-test` and `fake-worker-lint`. `format-check` covers the fixture and `test-checkers` builds it first. `packaging-check` lints its Dockerfile and validates its manifests. `just initialize` downloads its packages. `taplo.toml` and `.pre-commit-fix.yaml` skip its `manifest.toml` and `build/`, which `just toml-check` otherwise fails on. knarr's own recipes do not depend on any of it, because the cold-build and coverage tests copy only the root project.
- **The image.** `fixtures/fake_worker/Dockerfile` has the root Dockerfile's stages, with `Dockerfile.dockerignore` beside it as its context allowlist. The root `.dockerignore` and knarr's image are unchanged. `scripts/checks/image.py` gains a `--fake-worker` profile.
- **Ticket 27, merged from `main`.** It pinned knarr's base images by digest and spelled `gleam.toml`'s dev table `[dev-dependencies]`, the only spelling Renovate's gleam manager reads. The fixture follows both: its `FROM` lines are knarr's, which `test_image.py` holds equal, and `test_fake_worker_manifest.py` now requires the hyphenated table. Renovate's dockerfile and gleam managers therefore find the fixture's pins too, and its pixi, ubuntu and hex groups move both projects in one pull request.
- **The cluster.** `fixtures/fake_worker/deploy/` holds four workers and the collector. It sits outside `deploy/`, whose directories `deployment.py` treats as knarr variants. `scripts/schemas/kubernetes/service-v1.json` is vendored from the recorded upstream revision, with its sha256 in `sources.json`. `cluster.py` gains a `port_forward` helper, which knarr's `smoke` now uses too, and the actions `fake-worker-deploy` and `fake-worker-smoke`. The Justfile gains `fake-worker-image-build`, `fake-worker-image-check`, `fake-worker-deploy` and `fake-worker-smoke`. `ci.yml` gains the non-required "Kind fake worker smoke" job, outside `check.needs`.
- **Documentation.** The reference page above, linked from `docs/README.md`, `docs/reference/testing.md` and `docs/how-to/local-cluster.md`. `AGENTS.md`'s project map gains `fixtures/`, and `README.md`'s "Moving a pin" covers the fixture's `gleam.toml`.

### What was verified

- **58 Gleam tests** (`just fake-worker-test`), each naming the clause it traces. 49 are pure, by value. 9 run the server over loopback sockets:
  - every failure mode as the poller's transport sees it, `refused` as a real `econnrefused` and `timeout` as a client timeout;
  - `refused` reopening the same fixed port after the listener has served, and the same OS-chosen port;
  - SIGTERM (as the handler's message) keeping status served with `accepting` false;
  - the record reaching a real collector, and the VM stopping only once the cost is 0, or at the deadline;
  - a killed sink actor leaving the drain in place, and a sink that crashes mid-delivery losing no record.

  Each test was seen failing before its code: missing modules for the first batch, and the expected assertion for the review fixes.
- **6 process tests** (`scripts/checks/tests/test_fake_worker_process.py`) send the built VM a real SIGTERM. They also assert that the spawned pid is `beam.smp` itself, so every launcher in between has exec'd. The first ran against a `main` that did not yet install the handler. It failed as expected: OTP logged "SIGTERM received - shutting down" and exited at once. With the handler installed, all six passed five runs in a row.
- **The image**, built with `just fake-worker-image-build` (40 s here):
  - 479 MB, against 480 MB for knarr's image built from the same commit; a test holds the two Dockerfiles to the same `FROM`, `pixi install` and `USER` lines;
  - OTP 29 in both stages;
  - 48 to 50 MiB in use under the 256 MiB limit;
  - under the restricted `docker run`, a real SIGTERM to PID 1 left status answering `accepting` false, and setting the cost to 0 stopped the container with status 0 inside 10 s of a 60 s drain, with the kill line in its log.

  The descriptor-cap step could not run as written here: this sandbox's hard limit is 20,000 descriptors, below the check's 131,072, so `docker run --ulimit` was refused. The other steps ran through the check's own functions with the sandbox's limit. In this sandbox only, the build stage ran on the pinned pixi image with the session's egress-proxy CA added, under the same tag, because the build container must trust that proxy. Neither the Dockerfile nor CI is affected.
- **The first CI kind run found a bug the local tests could not.** The image check passed, every worker's state read back exactly, and the busy worker answered `accepting` false while it drained. But its kill record never reached the collector. Reproduced with two containers on a Docker network: OTP 29's `httpc` builds its default TLS options for every request, even plain HTTP, by loading the OS CA store. The `ubuntu:24.04` runtime has none, so each delivery crashed the sink actor with `no_cacerts_found`. This sandbox's host has CA certificates, so neither the Gleam nor the process tests could see it.
  - The fix passes `{ssl, []}` on the delivery, which stops that load, and turns any other exception into a failed attempt, so the sink retries rather than crashing.
  - `just fake-worker-image-check` now starts a collector from the same image on a private network and requires the worker to deliver its record there by name. Run here against the old image, it failed with that same error. Against the fixed image it passed three runs out of three.
- **kind, in CI.** CI's "Kind fake worker smoke" job passed on `4b34dcc` (run 38043564445), on native linux/amd64.
  - `just fake-worker-image-check` took 5 s: `image: OTP 29, numeric user and read-only runtime verified`, 54 MiB of the 256 MiB limit, with its collector on a private network.
  - `just fake-worker-smoke` took 8 s. It printed `ok idle … 200 {"cost":0,"accepting":true}`, `ok busy … 200 {"cost":1800,"accepting":true}`, `ok draining … 200 {"cost":500,"accepting":false}` and `ok absent … 404 not found`. After SIGTERM it printed `ok draining after SIGTERM … {"cost":1800,"accepting":false}`, then `ok kill record … busy=true` and `ok kill record … busy=false`.
  - The image build took 18 s. The other jobs passed on the same head, knarr's own kind smoke among them, so the port-forward helper it now shares works.
  - This sandbox cannot run kind: the pinned node starts, but `runc` refuses nested containers on `/proc/self/oom_score_adj`, after a first failure on the host's cgroup v1. `scripts/checks/tests/test_fake_worker_cluster.py` covers the smoke's logic against a fake cluster: a second run resets the first's states and skips the pods the first deleted while they drain, a mismatched status fails, and a dropped connection is retried.
- **Checker tests:** 497 passed, with `main` merged in. `just docs-check` validates 28 pages, `just agents-check` passes, and `just check` ends with "All checks passed and the worktree is unchanged."
- **Review:** `/code-review high` over the branch reported ten findings, all fixed with a test where behaviour changed:
  - the smoke failed when run twice on one cluster;
  - a sink crash reset a drain;
  - transport errors escaped the smoke's retries;
  - the image check passed on the drain deadline alone;
  - a zero drain with a sink lost the record;
  - equal ports and a sink URL with a path were accepted;
  - port 0 changed when leaving `refused`;
  - the status child's index was unpinned;
  - knarr's smoke duplicated the port-forward helper.

  Copilot's review of PR #20 found two more, both fixed test-first:
  - a sink actor that crashed mid-delivery lost the record, because only its own mailbox held it; the state actor now keeps the pending record and hands the sink one attempt at a time;
  - a smoke run straight after another could pick a pod the first had deleted, still Running while it drained; the smoke now waits for four Ready workers that are not terminating, and ends once the Deployment has rolled out again.

### Choices a maintainer may reverse

- **No Allium module for the control API.** Decision 0009 maps the fake worker to no module, and the fixture is not knarr. Its worker-side obligations are `worker_contract`'s, traced by tests. The control API and the collector are documented on the reference page.
- **`busy` is a cost above 0 at SIGTERM.** The record also carries the cost, so 33 can count against a stricter threshold, such as the lowest band 20 settles, without changing the fixture.
- **The drain ends early** once the cost is 0 and the record is delivered. A busy worker drains until control sets its cost to 0 or the time runs out, and an idle one stops at once.
- **`refused` is included** beyond the four modes this ticket lists, because 18's hand-back maps the failure modes onto `refused` too and 21's `ContractAbsent` is reached from it.
- **The default bind is IPv4.** A pod with an IPv6 address sets `FAKE_WORKER_BIND=::`.
- **The collector keeps records in memory, one per pod.** A restart of its pod loses them, and `DELETE /kills` clears them.

### What later tickets need

- **33:** count busy kills from the collector. Run `DELETE /kills` before each run, read `GET /kills` after the pods are gone, and count records with `busy: true`, or apply your own cost threshold. Records are keyed by pod name, so a retried delivery or a re-sent SIGTERM never counts twice. Give workers a `terminationGracePeriodSeconds` at least 10 s longer than `FAKE_WORKER_DRAIN_SECONDS`, and drive busy workers to cost 0 when their simulated work ends. The collector Deployment must not be the KEDA target. `fixtures/fake_worker/deploy/` is a starting point: replace the worker Deployment's replica count with a ScaledObject.
- **31:** no switch makes a fake worker NotReady at runtime. The `ReadinessWarning` end-to-end test needs one: a control member that fails `/healthz` would do, with the probes kept on the control port.
- **43:** the poller's adapter can be tested against the fake worker over loopback. Every reading its decoder names except `unreachable` has a failure mode.
- **36 and later image work:** the fake worker image is built and checked only in CI's fake worker job, never published.
