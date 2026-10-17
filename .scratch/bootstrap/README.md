# Bootstrap round: ticket order

The tickets live in [issues/](issues/). Each arrow points from a blocker to the ticket it unblocks, exactly as the ticket's **Blocked by** line states. A dashed orange border marks a `needs-human` ticket (a live session with the maintainer) or an external dependency. A dotted grey border marks a ticket off the MVP critical path.

```mermaid
flowchart TD
    T01["01 Tool manager decision"]
    T02["02 Gate checkers decision"]
    T03["03 Foundation"]
    T04["04 GitHub repository"]
    T05["05 CI"]
    T06["06 Docs contract"]
    T07["07 Allium gate"]
    T08["08 Testing toolkit"]
    T09["09 Agent contract"]
    T10["10 Spike: local cluster"]
    T11["11 Integration"]:::offpath
    T12["12 Maintainer docs"]:::offpath
    T13["13 Walking skeleton"]
    T14["14 Spike S1: in-cluster client"]
    T15["15 Spike S2a: CA on kwok"]
    T16["16 Spike S2b: GKE managed CA"]:::human
    GKE["GKE Standard access<br/>(external)"]:::human
    T17["17 Allium objective map"]
    T18["18 Elicit: worker contract"]:::human
    T19["19 Elicit: configuration schema"]:::human
    T20["20 Elicit: cost mapping"]:::human
    T21["21 Elicit: unknown and unreachable"]:::human
    T22["22 Elicit: ownership and conflicts"]:::human
    T23["23 Elicit: cleanup, staleness, restart"]:::human
    T24["24 Elicit: poll budget, feature gate"]:::human
    T25["25 Elicit: safe-to-evict policy"]:::human
    T26["26 Spike: coverage"]:::offpath
    T27["27 Spike: dependency updates and audit"]:::offpath
    T28["28 Spike: release and packaging"]
    T29["29 Fake-worker fixture"]
    T30["30 Elicit: observability"]:::human
    T31["31 Spec-then-build: reconcile core"]
    T32["32 Spec-then-build: ownership, lifecycle"]
    T33["33 KEDA harness, success criterion"]:::human
    T34["34 User guides"]:::offpath
    T35["35 Bootstrap verification gaps"]:::offpath
    T36["36 Release workflow and overlay"]
    T37["37 First release: v0.1.0"]:::human
    T38["38 Attestations, SBOM, arm64"]:::offpath
    T39["39 GKE production rollout"]:::human
    T40["40 MVP release"]:::human
    T41["41 Spec-then-build: k8s_client"]
    T42["42 OTP and ssl findings"]:::offpath
    T43["43 Spec-then-build: status poller"]
    T44["44 Renovate activation"]:::human
    T45["45 Scan the image's runtime environment"]:::offpath
    T46["46 Spec-then-build: poll schedule, patcher"]
    T47["47 Discovery cleanup hand-off"]
    T48["48 Detect patch on replacement pod"]:::offpath
    T49["49 Deferred safe-to-evict user guidance"]:::offpath
    T50["50 Local arm64 image"]:::offpath
    T51["51 Local Prometheus and Grafana"]:::offpath
    T52["52 Local Observer attach"]:::offpath

    T01 --> T02
    T01 --> T03
    T02 --> T03
    T01 --> T10
    T03 --> T04
    T03 --> T05
    T04 --> T05
    T03 --> T06
    T03 --> T07
    T03 --> T08
    T06 --> T08
    T06 --> T09
    T07 --> T09
    T04 --> T11
    T05 --> T11
    T06 --> T11
    T07 --> T11
    T08 --> T11
    T09 --> T11
    T11 --> T12
    T11 --> T35
    T05 --> T13
    T08 --> T13
    T10 --> T13
    T13 --> T14
    T14 --> T41
    T22 --> T41
    T14 --> T42
    T18 --> T43
    T24 --> T43
    T10 --> T15
    T15 --> T16
    GKE --> T16
    T07 --> T17
    T09 --> T17
    T17 --> T18
    T17 --> T19
    T18 --> T20
    T20 --> T21
    T17 --> T22
    T20 --> T23
    T22 --> T23
    T22 --> T31
    T17 --> T24
    T15 --> T25
    T17 --> T25
    T08 --> T26
    T05 --> T27
    T13 --> T27
    T27 --> T44
    T27 --> T45
    T13 --> T28
    T13 --> T29
    T18 --> T29
    T17 --> T30
    T24 --> T30
    T19 --> T31
    T20 --> T31
    T21 --> T31
    T23 --> T31
    T43 --> T31
    T30 --> T31
    T41 --> T31
    T22 --> T32
    T23 --> T32
    T30 --> T32
    T24 --> T33
    T29 --> T33
    T31 --> T33
    T32 --> T33
    T24 --> T46
    T31 --> T46
    T41 --> T46
    T43 --> T46
    T46 --> T33
    T12 --> T34
    T18 --> T34
    T23 --> T34
    T24 --> T34
    T28 --> T34
    T25 --> T49
    T34 --> T49
    T12 --> T36
    T28 --> T36
    T36 --> T37
    T36 --> T38
    T37 --> T38
    T31 --> T40
    T32 --> T40
    T37 --> T40
    T46 --> T40
    T32 --> T47
    T46 --> T47
    T32 --> T48
    T46 --> T48
    T27 --> T50
    T28 --> T50
    T29 --> T50
    T29 --> T51
    T50 --> T51
    T29 --> T52
    T50 --> T52
    T47 --> T40
    T47 --> T33
    T31 --> T39
    T32 --> T39
    T33 --> T39
    T40 --> T39
    GKE --> T39

    classDef human stroke:#d97706,stroke-width:2px,stroke-dasharray:5 5
    classDef offpath stroke:#9e9e9e,stroke-dasharray:2 2,color:#757575
```

## Branches

Each ticket is worked on its own branch, in its own git worktree. The branch name is the ticket's file name without `.md`, so [03](issues/03-foundation.md) is worked on `03-foundation`. Ticket 03 fixed this convention, and the root [README](../../README.md#branches-and-worktrees) states it with the worktree rules.

## Execution waves

A wave is the earliest point a ticket can start if every lane runs in parallel: one step after its latest blocker. `needs-human` tickets also wait for a maintainer session.

| Wave | Tickets |
| --- | --- |
| 0 | [01](issues/01-tool-manager-decision.md) |
| 1 | [02](issues/02-gate-checkers-decision.md), [10](issues/10-spike-local-cluster.md) |
| 2 | [03](issues/03-foundation.md), [15](issues/15-spike-s2a-ca-on-kwok.md) |
| 3 | [04](issues/04-github-repository.md), [06](issues/06-docs-contract-and-decisions.md), [07](issues/07-allium-gate.md), [16](issues/16-spike-s2b-gke-managed-ca.md) |
| 4 | [05](issues/05-ci.md), [08](issues/08-testing-toolkit.md), [09](issues/09-agent-contract.md) |
| 5 | [11](issues/11-integration.md), [13](issues/13-walking-skeleton.md), [17](issues/17-allium-objective-map.md), [26](issues/26-spike-coverage.md) |
| 6 | [12](issues/12-maintainer-docs.md), [14](issues/14-spike-s1-in-cluster-client.md), [18](issues/18-elicit-worker-contract.md), [19](issues/19-elicit-configuration-schema.md), [22](issues/22-elicit-ownership-and-conflicts.md), [24](issues/24-elicit-poll-budget-feature-gate.md), [25](issues/25-elicit-safe-to-evict-policy.md), [27](issues/27-spike-dependency-updates-and-audit.md), [28](issues/28-spike-release-and-packaging.md), [35](issues/35-bootstrap-verification-gaps.md) |
| 7 | [20](issues/20-elicit-cost-mapping.md), [29](issues/29-fake-worker-fixture.md), [30](issues/30-elicit-observability.md), [36](issues/36-release-workflow-and-overlay.md), [41](issues/41-k8s-client-spec-then-build.md), [42](issues/42-otp-ssl-findings.md), [43](issues/43-status-poller.md), [44](issues/44-renovate-activation.md), [45](issues/45-scan-image-runtime-environment.md) |
| 8 | [21](issues/21-elicit-unknown-unreachable-policy.md), [23](issues/23-elicit-cleanup-staleness-restart.md), [37](issues/37-first-release-v0-1-0.md), [50](issues/50-local-arm64-image.md) |
| 9 | [31](issues/31-spec-then-build-reconcile-core.md), [32](issues/32-spec-then-build-ownership-lifecycle.md), [34](issues/34-user-guides.md), [38](issues/38-attestations-sbom-arm64.md), [51](issues/51-local-observability.md), [52](issues/52-local-observer.md) |
| 10 | [46](issues/46-spec-then-build-poll-schedule-and-patcher.md), [49](issues/49-safe-to-evict-user-guidance.md) |
| 11 | [47](issues/47-discovery-cleanup-hand-off.md), [48](issues/48-detect-patch-on-replacement-pod.md) |
| 12 | [33](issues/33-keda-harness-success-criterion.md), [40](issues/40-mvp-release.md) |
| 13 | [39](issues/39-gke-production-rollout.md) |

The longest chains are fourteen tickets: 01, 02, 03, 06 or 07, 09, 17, 18, 20, 21, 31, 46, 47, then 33 or 40, then 39. Tickets 30 to 34 are the follow-ups ticket 17 drafted; 31 to 34 are round 2. Tickets 36 to 40 are the follow-ups ticket 28 drafted, all round 2; 37, 39 and 40 also wait for a maintainer session, and 39 for GKE Standard access. Tickets 41 and 42 are the follow-ups ticket 14 drafted. Ticket 43 is the follow-up ticket 18 drafted. Tickets 44 and 45 are the follow-ups ticket 27 drafted, both off the MVP path; 44 waits for a maintainer session, and 45 needs none. Ticket 46 is the follow-up ticket 24 drafted. Ticket 47 is the follow-up ticket 31 drafted after merging 23. Ticket 48 is the follow-up ticket 32 drafted when it settled the pod-identity question, off the MVP path. Ticket 50 makes the local images build natively on an arm64 host, off the MVP path. Ticket 51 adds an opt-in local Prometheus and Grafana for the kind cluster, off the MVP path. Ticket 52 attaches Erlang's Observer to knarr on kind through a dev-only overlay, off the MVP path.

When a ticket's **Blocked by** line changes, update both the diagram and this table.

Ticket 49 carries the safe-to-evict guidance deferred from 34 on 2026-10-15. Its wave records the currently named blockers; it remains deferred until 25 settles the feature and its implementation follow-up lands. Ticket 25 adds that follow-up as a blocker of 49 when it is assigned.
