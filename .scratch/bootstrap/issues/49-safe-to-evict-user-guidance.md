# 49: Add user guidance for the deferred safe-to-evict feature

**Context:** The maintainer deferred the safe-to-evict feature while picking up [34](34-user-guides.md). Ticket 34 documents the implemented deletion-cost controller without presenting the reserved `knarr.io/safe-to-evict` parse as an available protection. [25](25-elicit-safe-to-evict-policy.md) still owns policy elicitation; config's `SafeToEvict` owns the existing key and parse. The new guides preserve settled ownership and uninstall instructions for existing annotations.

**What to build:** Extend the existing user guides after 25 settles the policy and its implementation is available. Document enablement, the effective threshold and any override, when the value is removed or set to `"true"`, local-storage implications, node-pinning protection and restart behavior, and the signals the policy adds. Every behavior paragraph names its owning Allium clause.

**Non-goals:** Settling the policy or implementing it. Rewriting the deletion-cost guides. Repeating the canonical uninstall procedure.

**Blocked by:** 25, 34

**Availability:** Deferred until ticket 25 has settled the policy and its spec-then-build follow-up has implemented it. That follow-up's number is not assigned yet; add it as a blocker here, and update the bootstrap graph and wave, when 25 creates it. Do not publish enablement guidance from the parser alone.

**From 34:** [Deployment configuration](../../../docs/reference/configuration.md) owns keys, parsing and enablement; [operations](../../../docs/operations/controller.md) owns NetworkPolicy, metrics, Events, restart and uninstall; [worker preparation](../../../docs/how-to/worker.md) owns shutdown and readiness; [KEDA pairing](../../../docs/how-to/keda.md) owns scaler integration. Use those owners rather than creating parallel pages. The [install guide](../../../docs/how-to/install.md) must identify the release that actually contains the feature before giving an install example for it. Existing recovery commands include the safe-to-evict key under lifecycle `Uninstall` `Procedure` and `Recovery`; retaining them does not advertise a supported policy.

**MVP critical path:** no. The feature and its user guidance are deferred.

**Status:** deferred, round 2

- [ ] Ticket 25 is settled, its implementation follow-up is linked as a blocker here and has landed, and the guide's availability statement matches a real implementation and release.
- [ ] The configuration reference explains enablement, defaults, ranges, and any new override without inventing policy.
- [ ] The operations guide covers threshold behavior, removal versus `"true"`, local-storage pods, node-pinning protection, restart behavior, and any added metrics, Events, and logs.
- [ ] Examples preserve Deployment-level opt-in and overrides, worker shutdown duties, and the distinction between ReplicaSet scale-down and node eviction.
- [ ] Each behavior paragraph names its owning clause, `just docs-check` and `just lint` pass, and the full `just check` ends with the unchanged-worktree success message.
- [ ] Hand-back notes record what changed, validation, and remaining provider-specific limits.
