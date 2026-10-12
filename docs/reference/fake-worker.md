---
title: "The fake worker fixture"
kind: "reference"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["fake_worker_fixture"]
requires: []
---

# The fake worker fixture

The fake worker is a configurable worker that serves knarr's status contract, so tests on kind can drive a realistic mixed load and count the busy pods a scale-down kills ([ticket 29](../../.scratch/bootstrap/issues/29-fake-worker-fixture.md)). It implements the worker side of `StatusEndpoint` in [worker_contract.allium](../specs/worker_contract.allium). Ticket 33's KEDA harness is its first consumer.

It is a second Gleam project, `fixtures/fake_worker/`, with its own `gleam.toml` and `manifest.toml`. It never ships in knarr's image, and running it never starts knarr. The gate builds, tests and lints it (`just fake-worker-build`, `just fake-worker-test`, `just fake-worker-lint`). A checker test holds its locked packages to knarr's versions. The coverage report covers knarr's `src/` only, not the fixture.

## Configuration

Every variable is optional. A value the worker cannot use stops it before it serves anything, with exit status 1 and a line naming the variable.

| Variable | Default | Meaning |
| --- | --- | --- |
| `FAKE_WORKER_MODE` | `worker` | `worker` serves the status and control endpoints; `collector` keeps kill records |
| `FAKE_WORKER_BIND` | `0.0.0.0` | Listen address; set `::` for a pod with an IPv6 address |
| `FAKE_WORKER_STATUS_PORT` | `8080` | The status port, `config.status_port` in the contract |
| `FAKE_WORKER_STATUS_PATH` | `/knarr/v1/status` | The status path, `config.status_path`; absolute, no query or fragment |
| `FAKE_WORKER_CONTROL_PORT` | `8081` | The control port, or the collector's port in collector mode; a worker's must differ from its status port |
| `FAKE_WORKER_DRAIN_SECONDS` | `10` | The longest drain after SIGTERM; at least 1 when a sink is set |
| `FAKE_WORKER_SINK_URL` | unset | The collector's base URL, a host and no path, for example `http://fake-worker-collector:8081` |
| `POD_NAME` | the hostname | The name in the kill record; the manifests set it from the downward API |

Port 0 lets the OS choose, which only tests use; a listener that restarts binds the port chosen the first time. The worker logs one line per listener, `fake_worker listening listener=status port=8080`, and `fake_worker started pod=<name>` once it is ready.

## Status endpoint

`GET` on the status path answers `200` with `{"cost":0,"accepting":true}` until control changes it, as `Content-Type: application/json`. Other paths answer `404`, so a version knarr does not speak reads as `not_found`. Other methods on the path answer `405` with `Allow: GET`. The endpoint needs no header and no credential, and a read never changes the state. The state is read when the request arrives, before any delay.

## Control endpoint

The control endpoint is on its own port. The status endpoint stays read-only, and the `refused` mode can close the status listener while control stays up.

- `GET /healthz` answers `200` with `ok`. The manifests' probes use it, never the status endpoint, so a failure mode cannot make a pod NotReady and so change its rank on scale-down.
- `GET /control` answers the state: `cost`, `accepting`, `latency_ms`, `failure`, `invalid_body` and `terminating`.
- `PUT /control` takes a JSON object naming any of `cost` (an integer, at least 0), `accepting` (a boolean), `latency_ms` (an integer, at least 0), `failure` and `invalid_body` (a string). It answers the new state. An unknown member, a wrong type or a negative number answers `400` and changes nothing.

```sh
curl -X PUT --data '{"cost":1800,"accepting":true}' http://127.0.0.1:8081/control
curl -X PUT --data '{"failure":"timeout"}' http://127.0.0.1:8081/control
```

Each failure mode produces one of the readings the contract names when knarr's poller ([ticket 43](../../.scratch/bootstrap/issues/43-status-poller.md)) decodes the outcome:

| `failure` | What the status endpoint does | Reading |
| --- | --- | --- |
| `none` | `200` with the cost and accepting | `valid` |
| `not_found` | `404` | `not_found` |
| `server_error` | `500` | `invalid` |
| `invalid` | `200` with `invalid_body`, by default `{"cost":"high","accepting":true}` | `invalid` |
| `timeout` | holds the request for 120 seconds without answering | `timed_out` |
| `refused` | closes the status listener; leaving the mode reopens it on the same port | `refused` |

`latency_ms` delays every status answer, so a value above knarr's per-poll timeout also reads as `timed_out`. A cost needs no bound on the wire, but one with thousands of digits makes the body longer than the contract's 4096 bytes, and that reads as `invalid`.

## SIGTERM and the kill record

The worker takes over SIGTERM from the Erlang VM, which would otherwise stop at once. From SIGTERM on, the status endpoint keeps answering and reports `accepting` false whatever control set (`Served`). The worker then writes its kill record:

```json
{"pod":"fake-worker-7d9c-x2k4p","busy":true,"cost":1800,"accepting":true}
```

`busy` is true when the cost was above 0 at SIGTERM; `cost` and `accepting` are the values at that moment, so a harness can apply a stricter threshold. The worker prints the record as one line, `fake_worker kill {...}`, and PUTs it to the collector. The worker's state keeps the record until the collector has it, so a crash of the delivering process loses nothing: a failed attempt is retried a quarter of a second after it fails, and one that never answers 2.25 seconds after it started, until the drain ends. Each attempt takes at most two seconds, and never longer than the drain time left. The drain ends, and the VM exits with status 0, once the cost is 0 and the record is delivered, or when `FAKE_WORKER_DRAIN_SECONDS` have passed, whichever is first. An idle worker therefore stops at once; a busy one keeps draining until control sets its cost to 0 or the time runs out. A second SIGTERM changes nothing.

## The collector

The kill-record sink is the collector: the same image with `FAKE_WORKER_MODE=collector`, run as its own one-replica Deployment behind the `fake-worker-collector` Service. It outlives every worker pod, so a run reads it after the pods are gone. The printed line is only a trace for debugging, because a pod's log goes when the pod object goes.

- `PUT /kills/<pod>` stores the record for that pod, `204`. A second delivery for the same pod replaces the first, so a retry never counts twice. A record that names another pod answers `400`.
- `GET /kills` answers `{"kills":[...]}`, one record per pod, sorted by pod name.
- `DELETE /kills` clears every record, `204`. A harness clears it between runs, for example between the runs with and without knarr.
- `GET /healthz` answers `200`.

The collector keeps its records in memory and logs each one as `fake_worker collected {...}`; a restart of its pod loses them.

## Running it

The image builds from the repository root with `fixtures/fake_worker/Dockerfile`. It uses the same stages as knarr's: the locked pixi environments, the checksum-pinned rebar3, an erlang-shipment, and an `ubuntu:24.04` runtime as UID/GID 10001 behind the descriptor-bounding entrypoint. Its `FROM` lines carry the same digests as knarr's, and `test_image.py` fails while the two Dockerfiles differ there or in rebar3's `ADD`, so a base image moves in both. `Dockerfile.dockerignore` beside it is its context allowlist, so knarr's `.dockerignore` and image are unchanged. Like knarr's, it is built and run in CI on linux/amd64.

With the cluster tools installed and a kind cluster up (see the [local cluster guide](../how-to/local-cluster.md)):

1. `just fake-worker-image-build` builds `fake-worker:<cluster name>`.
2. `just fake-worker-image-check` runs the image as `just image-check` runs knarr's: the numeric user, OTP ownership, the descriptor cap and a read-only root under the Deployment's memory limit. It then starts a collector from the same image on a private Docker network, sets a cost, sends a real SIGTERM to the worker, and checks the drain. Status answers `accepting` false, and the kill record reaches the collector by name, as it does on kind. Once control sets the cost to 0, the worker exits with status 0 within 10 seconds of a 60-second drain, with the kill record in its log.
3. `just fake-worker-deploy` loads the image and applies `fixtures/fake_worker/deploy/`: four workers, with a five-second drain and a twenty-second grace period, and the collector. It waits for CoreDNS, because workers reach the collector by name, and for both rollouts.
4. `just fake-worker-smoke` waits up to two minutes for four workers that are Ready and not terminating, so a run straight after another never picks a pod the first deleted while it drains. It clears the collector and sets those four to idle, busy, draining and `not_found` through control, naming every member so a second run resets the first's. It reads each back from its status endpoint byte for byte, retrying for up to 15 seconds over a fresh port forward. It then deletes the busy worker, reads `accepting` false from it while it drains, deletes the idle worker, and finds both kill records at the collector by pod name. It ends once the Deployment has rolled out their replacements.

The manifests live outside `deploy/`, which holds knarr's variants, and `just packaging-check` validates them against the pinned local schemas. CI's non-required "Kind fake worker smoke" job runs all four steps.

## Clauses and tests

Every test names the `StatusEndpoint` clause it traces in a comment. The Gleam tests are under `fixtures/fake_worker/test/`; the process tests, which send the VM a real SIGTERM, are `scripts/checks/tests/test_fake_worker_process.py`.

| Clause | Tests |
| --- | --- |
| `Pull` | `status_test`: `pull_other_methods_are_not_allowed_test`; `server_test`: `status_and_control_round_trip_test` |
| `Versioning` | `status_test`: `versioning_other_paths_are_not_found_test` |
| `Discovery` | `status_test`: `discovery_override_path_test`; `config_test`: `defaults_test`, `overrides_test`. Which pods knarr polls is ticket 31's. |
| `RequestHeaders` | `status_test`: `request_headers_are_not_required_test`. The `User-Agent` knarr sends is ticket 43's. |
| `Transport` | `status_test`: `latency_and_timeout_delay_the_answer_test`; `server_test`: `failure_modes_over_the_wire_test`, `refused_closes_and_reopens_the_same_port_test`, `refused_keeps_an_os_chosen_port_test` |
| `ValidReading` | `status_test`: `valid_reading_for_a_new_worker_test`, `valid_reading_cost_is_a_plain_integer_test` |
| `NotFoundReading` | `status_test`: `not_found_reading_test`; `server_test`: `failure_modes_over_the_wire_test` |
| `InvalidReading` | `status_test`: `invalid_reading_server_error_test`, `invalid_reading_default_body_test`, `invalid_reading_chosen_bodies_test` |
| `Payload` | `status_test`: `payload_reflects_control_test`, `served_while_draining_reports_not_accepting_test`; `worker_test`: `control_cannot_resume_accepting_while_draining_test` |
| `Unauthenticated` | `status_test`: `request_headers_are_not_required_test`, `unauthenticated_reads_are_repeatable_test`; `server_test`: `status_reads_change_nothing_test` |
| `NetworkPolicy` | None: knarr's side. The manifests install no NetworkPolicy, and the worker accepts TCP on its status port from any pod. |
| `Served` | `status_test`: `served_while_draining_reports_not_accepting_test`; `server_test`: `sigterm_delivers_the_record_and_drains_test`, `a_sink_crash_keeps_the_drain_test`, `a_sink_crash_mid_delivery_loses_no_record_test`; `test_fake_worker_process.py`: `test_sigterm_drains_until_the_work_is_done`; the SIGTERM step of `just fake-worker-image-check` and of `just fake-worker-smoke` |
| `ReadinessWarning` | None: knarr's gauge and log line, tickets 30 and 31. |
| `@guidance` | `test_fake_worker_manifests.py`: `test_probes_never_read_the_status_endpoint` |

## Limits

- The default bind is IPv4. A pod with an IPv6 address needs `FAKE_WORKER_BIND=::`.
- The pod name goes into the collector's path, so it must be a DNS name, as every Kubernetes pod name is.
- No switch makes a pod NotReady at runtime. Ticket 31's readiness warning would need one in its end-to-end test.
