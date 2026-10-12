# 18: Elicit: worker contract (§9.4a, §9.4b) and readiness guidance (§9.7)

**Context:** OVERVIEW §5 drafts worker contract v1. It is pull-based, and the payload is a worker-supplied cost plus an accepting/drain state, nothing else. The open questions are:

- **§9.4a:** the endpoint shape: path, port, schema, field types, versioning and timeouts.
- **§9.4b:** how knarr discovers the endpoint on a pod, auth (if any), and compatibility with NetworkPolicies.
- **§9.7:** how to document the readiness trade-off (NotReady pods are deleted first), and whether knarr warns on "high cost while NotReady".

**What to build:** Allium clauses for the worker contract and the readiness guidance, settled with the maintainer, that the fake worker (29) and the poller can be built against.

**Non-goals:** Cost-to-band mapping (20). Unreachable-pod policy (21). Implementation.

**Blocked by:** 17

**MVP critical path:** yes. The contract is the MVP's external interface, and 20 and 29 depend on it.

**Status:** done. See [the hand-back notes](#hand-back-notes).

- [x] The `elicit` skill is run with the maintainer in a live session.
- [x] Every open point above is settled and recorded before any clause is written.
- [x] The clauses cover the endpoint shape, discovery, auth, network compatibility, the drain states and readiness guidance. `check-specs` and `analyse-specs` report nothing.
- [x] Any open question 19 left on the default or valid values of an endpoint override is closed.
- [x] The hand-back gives the `plan-spec` obligation count and drafts the spec-then-build follow-up ticket.

## Settled

The live session ran on 2026-10-09 in seven rounds. The maintainer took the recommended option every time. The module and this table are the record; no decision record is written, the shape 19 to 25 can take as well.

| # | Point | Decision | Rejected |
| --- | --- | --- | --- |
| 1 | Versioning | A path segment. knarr v1 polls a `v1` path; a later contract is a new path; a worker without that version answers 404. | A response header; the media type with a matching `Accept`; no marker in v1. |
| 2 | Default path | `/knarr/v1/status`, method GET. An override is an absolute path starting with `/`, no query or fragment. | `/knarr/v1`; `/.well-known/knarr/v1/status`. |
| 3 | Discovery | The address is the pod's primary IP from pod status, IPv4 or IPv6 (bracketed in the URL). Port and path come from Deployment annotations 19 defines, over the defaults. knarr reads nothing from the pod spec's container ports. | A named container port on the pod; annotation, else named port, else default. |
| 4 | Default port | 8080. Override range 1 to 65535. | No default, the port required; a distinctive default such as 9797. |
| 5 | Valid response | Status 200 only. Content-Type ignored; the body decides. 3xx never followed and not valid. Body over 4096 bytes is invalid. | Any 2xx; `application/json` required; one same-host redirect followed; a 65536-byte cap; no cap. |
| 6 | Fields | `cost` and `accepting`, names unchanged. Top level is a JSON object. `cost` is a JSON integer, no fraction or exponent, not negative; no unit and no upper bound on the wire. `accepting` is a JSON boolean. Missing, null or wrongly typed members are invalid. Other members are ignored. | Renaming the fields; any JSON number truncated toward zero; a float with zero fraction accepted; a negative cost accepted and clamped by 20; unknown members invalid. |
| 7 | Auth | None. The GET is unauthenticated, read-only and side-effect free; access control is a NetworkPolicy. | A shared bearer token from a Secret. |
| 8 | Request headers | `User-Agent: knarr/<version>` is promised; nothing else. | No header promised. |
| 9 | NetworkPolicy | A restricting worker namespace allows TCP ingress to the status port from pods labelled `app.kubernetes.io/name: knarr` in the same namespace (one install per namespace, §9.18). knarr does not detect a policy block. | A dedicated knarr label beyond the app name. |
| 10 | Readiness warning | A gauge of pods NotReady while their last valid reading maps to a band above the lowest band 20 defines, plus a log line on entry. No Event. Names are 30's. | Document only; metric, log and a Kubernetes Event; `cost > 0` as the threshold; the threshold left to 20 as an open question. |
| 11 | Readiness guidance | Two audiences, trade-off stated, no mandate: queue consumers never signal busy or draining through readiness; Service-routed HTTP workers stay Ready while draining where traffic can be shed another way and go NotReady as late as the drain allows. | The trade-off only, no advice for HTTP workers. |
| 12 | NotReady pods | Polled. Any pod with a pod IP is polled, whatever its phase or readiness; a pod without one cannot be. Pod IPs of either family. | Only Ready pods polled; IPv4 only in v1. |
| 13 | Follow-up | New ticket [43](43-status-poller.md), the status poller, blocked by 18 and 24. 31 gains 43 as a blocker, since the loop consumes readings; 43 is wave 7 and 31 stays at 9. | Folding the poller into 31. |
| 14 | Pod fields | Ticket [41](41-k8s-client-spec-then-build.md) gains a box: `Pod` carries the pod IP and the Ready condition. `k8s_client.allium` is not edited here. | Adding the fields to `k8s_client.allium` in this ticket. |

Boundaries kept: `worker_contract` owns the wire shape of `cost`; `banding` (20) owns the clamp, the bands and the drain-state handling. The per-poll timeout, jitter and concurrency are `budget` (24). What knarr does over time with an invalid, absent or unreachable reading is `reconcile` (21); 18 owns the decode of one response and what the namespace must allow. Event and metric names are `observability` (30); 18 owns whether knarr warns and through which channel class.

## Hand-back notes

### What changed

- `docs/specs/worker_contract.allium`: the eight open questions became the `StatusEndpoint` contract with the signatures `endpoint`, `request`, `send`, `decode` and `draining`, the invariants `Pull`, `Versioning`, `Discovery`, `RequestHeaders`, `Transport`, `ValidReading`, `NotFoundReading`, `InvalidReading`, `Payload`, `Unauthenticated`, `NetworkPolicy`, `Served` and `ReadinessWarning`, a `@guidance` block for the readiness trade-off, the value types `Endpoint`, `Header`, `Request`, `Response`, `Outcome`, `Status` and `Reading`, and a `config` block with `status_path`, `status_port` and `max_body_bytes`. `just plan-spec docs/specs/worker_contract.allium` reports 22 obligations.
- `docs/specs/reconcile.allium`: the "§9.6 Just started" question no longer asks whether NotReady pods are polled; it asks whether Pending pods, which have no pod IP, are tracked at all.
- Amended by ticket 20 on 2026-10-10: the `Payload` clause and the `Status` comment state the intended meaning of `cost`, the seconds the worker's longest-running active task has run so far, which cost_mapping's default thresholds assume.
- `docs/OVERVIEW.md`: the §5 payload callout, the §5 readiness bullet and §9 items 4 and 7 point at the module. No new handbook page, so `docs/manifest.yml` is untouched.
- Tickets: [43](43-status-poller.md) is drafted and in the [bootstrap README](../README.md) graph and waves; [31](31-spec-then-build-reconcile-core.md) is blocked by 30 and 43 and gains the polling-selection and readiness-warning boxes; [41](41-k8s-client-spec-then-build.md) gains the `Pod` fields box.

### What was verified

- `just check-specs` and `just analyse-specs`: 11 specifications, no diagnostics and no findings.
- `just plan-spec docs/specs/worker_contract.allium`: 22 obligations (seven value types at two each, five contract signatures, three config defaults).
- Codex (gpt-6-astra) reviewed the staged diff adversarially and reported seven findings: `send` could not carry a transport failure, a 404 with an oversized body matched two clauses, "a Pending pod has no IP" was false, an override path could drop the version segment, the worker's lifetime obligation sat in non-normative guidance, 43 and 31 lacked hand-offs, and OVERVIEW called settled points undecided. Every finding was applied, two of them narrowed where the evidence said so; the next section records the choices that produced.
- `just docs-check` validates 26 pages and 30 canonical topics, including the three new links into `docs/specs/`.
- `just check` ends with "All checks passed and the worktree is unchanged." Nothing under `src/` or `test/` changed, and nothing ran against a cluster.

### Choices a maintainer may reverse

- `draining` is in the contract because the pinned Allium 3.6.1 reports `allium.definition.unused` for a value type that appears only as a bare return type, whatever the type (a value, an enum, an optional). Parameter types, field types and a `List<T>` return count as references; `k8s_client` passes only because `list_pods` returns `List<Pod>`. A cross-module reference also counts, but the referencing declaration in `reconcile` would be flagged in turn unless it were a contract signature, which is 21's and 31's work. `draining` is honest: it is the §5 drain-state meaning the module's scope already claims, and it can go when the checker counts return types. `send` was first added for the same reason and now earns its place: it returns `Outcome`, the transport result 43's adapter must produce.
- `Outcome` is 18's answer to transport failures: four kinds (responded, refused, timed_out, unreachable) and no thresholds. The §5 diagram routes a refused connection toward `ContractAbsent` and a timeout toward `TransientFailure`, so the kinds stay apart; how many of each matter is 21's.
- An override path aliases the v1 contract. The session's recommended option read "a path containing `v1`"; the `Versioning` clause instead says the override names where the pod serves the v1 contract and knarr speaks v1 whatever the path says, because a required segment in a user-chosen path would add a validation rule to 19 for no gain. Reverse it by having 19 reject an override without a `v1` segment.
- 30 is a blocker of 31, because 31 builds `ReadinessWarning` with 30's names. 41 is not: 41 removes the S1 probe only once 31's caller exists, so a 41 to 31 edge would deadlock; 31's box names the interlock instead.
- Decision 12's option text said a Pending pod has no IP. That premise is false, since a pod running init containers has one, so the records say "a pod without a pod IP" and never name a phase. The decision, every pod with a pod IP is polled, is unchanged.
- No decision record. The module and this table are the record; say so if a Decision 0014 is wanted instead.
- 31 gains 43 as a blocker. It costs no wave; strike the edge in the README and 31's line if the loop should not wait for the poller.

### What later tickets need

- **19:** the defaults are `config.status_path` (`/knarr/v1/status`) and `config.status_port` (8080). A path override is absolute, starts with `/`, and has no query or fragment; a port override is 1 to 65535. What happens on an invalid override value is 19's.
- **19 to 25:** every value type that appears only as a bare return type in a contract is flagged by the pinned checker; give it a parameter position or a `List<T>` return that is true, never a fake one.
- **20:** `cost` arrives as a non-negative integer of unbounded magnitude; the clamp is yours. A lowest band must exist, because `ReadinessWarning` is phrased against it. `draining` tells you a worker-started drain; what to do with it is yours.
- **21:** every pod with a pod IP is polled, whatever its phase or readiness. `Reading` is the whole input your state machine consumes: `valid`, `not_found`, `invalid`, `refused`, `timed_out` and `unreachable`. A 404 is one `not_found` reading and a refused connection one `refused` reading; your `ContractAbsent` and `TransientFailure` states are reached after however many of each you decide.
- **24:** `timed_out` is defined against your per-poll timeout, and `Served` asks the worker to answer within it.
- **29:** build the status endpoint against `StatusEndpoint`: `GET /knarr/v1/status` on 8080, a 200 JSON object with `cost` and `accepting`, and `Served` is the clause the fake worker must satisfy: the endpoint stays up for the pod's whole life including after SIGTERM, reporting `accepting` false while it drains. The control endpoint's failure modes map to `not_found`, `invalid`, `refused` and `timed_out` readings.
- **30:** one gauge (pods NotReady with a last valid reading above the lowest band) and one log line (entry into that state) to name. No Event.
- **31:** you own the selection rule "every pod with a pod IP is polled, whatever its phase or readiness" and the `ReadinessWarning` clause; both are boxes on your ticket. 30 is now your blocker for the names; 41's `Pod` fields land together with your caller, since 41's probe removal waits for it. 43 builds only the builder, sender and decoder.
- **34:** the `@guidance` block is the readiness page's content, and the `NetworkPolicy` and `Unauthenticated` clauses are the network page's.
- **36:** the `NetworkPolicy` clause makes `app.kubernetes.io/name=knarr` a contract promise. A change to that label in `deploy/base` is a change to the clause first, as Decision 0013 says of the Role verbs.
- **41:** the `Pod` fields box: `status.podIP` and the Ready condition.
- **43:** the poller ticket, drafted from this contract. It takes the pod IP as a string and does not depend on 41.
