# 41: Spec-then-build: the k8s_client module

**Context:** Spike S1 ([14](14-spike-s1-in-cluster-client.md)) settled TLS, token reload and the verbs in [Decision 0013](../../../docs/decisions/0013-in-cluster-client.md) and left `docs/specs/k8s_client.allium` with a `Client` contract covering list and patch on pods. OVERVIEW §8 also needs get on pods and get and list on Deployments and ReplicaSets, and ticket 22 settled the write mode whose patch preconditions §9.10 asked about in [ownership.allium](../../../docs/specs/ownership.allium): one JSON Patch per write with `test` preconditions, a 422 as a precondition failure and one Event per yield. The S1 probe loop in `src/knarr/s1_probe.gleam` is scaffolding that proved the path; the reconciler ([31](31-spec-then-build-reconcile-core.md)) is its real caller.

**What to build:** The full `k8s_client` module, specification first: the remaining operations and their Role verbs, pagination of a LIST, the error vocabulary callers branch on (RBAC refusal, conflict, not found, transport; a 404 and a 409 from the patch are reported as values and are not precondition failures), and the patch content type and preconditions 22 settled. Then the code, keeping the sans-IO shape 14 established, and the removal of `s1_probe` once 31 has a caller for the client, with the `NoPodEffects` clause and the Deployment's `ERL_FLAGS` updated in the same change.

**Non-goals:** Watch (OVERVIEW §8 defers it). Rate limiting (§9.8, ticket 24). Event reasons and the metrics (ticket 30).

**Blocked by:** 14, 22

**MVP critical path:** yes. Every read and write the reconciler makes goes through this module.

**Status:** ready-for-agent

- [ ] `k8s_client.allium` states every operation the reconciler needs, with the Role verbs each one implies, and `Verbs` names the complete set. `just check-specs` and `just analyse-specs` report nothing.
- [ ] The `Pod` value carries the pod's primary IP (`status.podIP`) and whether its Ready condition is true, which the status poller ([43](43-status-poller.md)) reads.
- [ ] The patch content type is `application/json-patch+json`, and `patch_pod` takes the document ownership's `document` renders and returns the patched pod as the newest view (ownership `WriteMode`, k8s_client `Verbs`).
- [ ] A 422 is a named error value the reconciler branches on as a precondition failure (ownership `Precondition`), beside RBAC refusal, not found and transport.
- [ ] `Pod.uid` is read, and `Pod.annotations` is null when the response carries no annotations map, the case ownership `WriteMode` branches on; the apiserver omits an empty map, so a decoder test is the only place an empty list arises.
- [ ] The create of the conflict Event on the Pod (ownership `Event`), with `create` on `events` in the Role and no other verb added. The AGENTS.md Controller invariant governs what knarr changes on Pod objects, and the conflict Event is knarr's own record; the hand-back says so, or widens the phrase through the agent-contract procedure.
- [ ] A kind check shows that a JSON Patch `test` with value null passes for a missing key under an existing `metadata.annotations` map and for a missing `/metadata/deletionTimestamp`, recorded as evidence because it is a property of the apiserver's patch library, not a clause.
- [ ] Builders and decoders for each operation are pure, tested by value and snapshot as in [the testing reference](../../../docs/reference/testing.md); `send` stays injected.
- [ ] An IPv6 `KUBERNETES_SERVICE_HOST` is bracketed in the URL, or the clause states that only IPv4 service addresses are supported.
- [ ] The S1 probe is removed once the reconciler calls the client, together with its `ERL_FLAGS` switch and the probe wording in `NoPodEffects`; the Role grants exactly what the client uses.
- [ ] Decision 0013 is amended where the full module departs from the spike's findings.
- [ ] The `cluster-s1` CI job is narrowed to the paths it proves, or gated by a label, once its transcripts sit beside the evidence scripts.
