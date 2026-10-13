# 41: Spec-then-build: the k8s_client module

**Context:** Spike S1 ([14](14-spike-s1-in-cluster-client.md)) settled TLS, token reload and the verbs in [Decision 0013](../../../docs/decisions/0013-in-cluster-client.md) and left `docs/specs/k8s_client.allium` with a `Client` contract covering list and patch on pods. OVERVIEW §8 also needs get on pods and get and list on Deployments and ReplicaSets, and ticket 22 decides the write mode whose patch preconditions §9.10 asks about. The S1 probe loop in `src/knarr/s1_probe.gleam` is scaffolding that proved the path; the reconciler ([31](31-spec-then-build-reconcile-core.md)) is its real caller.

**What to build:** The full `k8s_client` module, specification first: the remaining operations and their Role verbs, pagination of a LIST, the error vocabulary callers branch on (RBAC refusal, conflict, not found, transport), and the patch content type and preconditions 22 chooses. Then the code, keeping the sans-IO shape 14 established, and the removal of `s1_probe` once 31 has a caller for the client, with the `NoPodEffects` clause and the Deployment's `ERL_FLAGS` updated in the same change.

**Non-goals:** Watch (OVERVIEW §8 defers it). Rate limiting (§9.8, ticket 24, built by [46](46-spec-then-build-poll-schedule-and-patcher.md)). Events (ticket 30).

**Blocked by:** 14, 22

**From 24:** budget's `BackOff` and `PauseScope` read the response status and the Retry-After header, in seconds, of a failed patch and a failed list; this ticket shapes the values that carry them, and [46](46-spec-then-build-poll-schedule-and-patcher.md) consumes them.

**MVP critical path:** yes. Every read and write the reconciler makes goes through this module.

**Status:** ready-for-agent

- [ ] `k8s_client.allium` states every operation the reconciler needs, with the Role verbs each one implies, and `Verbs` names the complete set. `just check-specs` and `just analyse-specs` report nothing.
- [ ] The `Pod` value carries the pod's primary IP (`status.podIP`) and whether its Ready condition is true, which the status poller ([43](43-status-poller.md)) reads.
- [ ] Builders and decoders for each operation are pure, tested by value and snapshot as in [the testing reference](../../../docs/reference/testing.md); `send` stays injected.
- [ ] An IPv6 `KUBERNETES_SERVICE_HOST` is bracketed in the URL, or the clause states that only IPv4 service addresses are supported.
- [ ] The S1 probe is removed once the reconciler calls the client, together with its `ERL_FLAGS` switch and the probe wording in `NoPodEffects`; the Role grants exactly what the client uses.
- [ ] Decision 0013 is amended where the full module departs from the spike's findings.
- [x] The `cluster-s1` CI job is narrowed to the paths it proves, or gated by a label, once its transcripts sit beside the evidence scripts. Done ahead of this ticket in pull request #25: the job moved to `.github/workflows/s1-proof.yml` with a `paths:` filter and `workflow_dispatch`.
- [ ] A failed patch and a failed list are returned as values carrying the response status and the Retry-After header in seconds, which budget's `BackOff` and `PauseScope` read ([46](46-spec-then-build-poll-schedule-and-patcher.md)); the §9.10 open question names it.
