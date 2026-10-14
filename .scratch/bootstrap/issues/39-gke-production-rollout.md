# 39: Production rollout and acceptance on GKE Standard

**Context:** The MVP bar is a real production workload on GKE Standard (OVERVIEW §1). Tickets 31 and 32 build the MVP clauses, [40](40-mvp-release.md) publishes the release that carries them (37's `v0.1.0` of the walking skeleton was the rehearsal of the route), 33 sets the threshold the acceptance is judged against, and [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) decides how a release is installed: `kubectl apply -k` on the digest-pinned release overlay, one install per namespace, the Role in the base. This ticket installs a published release on a GKE Standard cluster, runs the production workload against it, and records the acceptance.

**What to build:** An installed knarr on GKE Standard from a published release, a real production workload opted in, the evidence that knarr biased its scale-down, and either the teardown or the handover to whoever runs it next.

**Non-goals:** The measurement harness and its threshold (33). Changing the release (a fix is a new patch version through 36's shape). GKE Autopilot ([DEFERRED §8](../../../docs/DEFERRED.md#8-other-future-targets)).

**Blocked by:** 31, 32, 33, 40, GKE Standard access (external)

**From 28:** [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md); 40's hand-back for the digest.

**From 37:** the install box means: check out 40's tag, run `just release-pin <40's digest>` there (it needs `just cluster-install`), then `kubectl apply -k deploy/release`. At a release's own tag the overlay still holds the previous digest ([37's hand-back](37-first-release-v0-1-0.md#what-each-later-ticket-needs), [install-at-tag.txt](../evidence/37/install-at-tag.txt)). The package is public, so GKE nodes pull anonymously. A pull from a GKE node is still unverified.

**MVP critical path:** yes. This is the acceptance.

**Status:** needs-human, round 2. Every cloud action below needs the maintainer's explicit approval, one action at a time, and GKE Standard access that no ticket provides.

- [ ] **Authorization required:** the cluster, its channel and version, the node pools and their machine families, and the namespace knarr runs in are recorded before anything is applied.
- [ ] **Authorization required:** knarr is installed with `kubectl apply -k` on the release overlay at the release tag, with the digest 40 recorded, into one namespace. The install guide (34) is followed as written, and every gap found in it is recorded for 34.
- [ ] **Authorization required:** a real production workload, a Deployment with the worker contract 18 settled and a KEDA ScaledObject or equivalent scaler, is opted in through the labels and annotations 19 settled. The workload, its owner and the opt-in are recorded.
- [ ] The acceptance evidence: over a period that includes scale-in, knarr's annotations on live pods, the Events it emitted, and the pods the ReplicaSet chose, showing that busy pods were chosen last, against the criterion 33 measures and the threshold OVERVIEW §3 records. The GKE version, the release digest, the install time and the period are in the hand-back.
- [ ] **Authorization required:** teardown (knarr uninstalled as 23 settled, with annotations cleaned up, and the cluster deleted if it was created for this) or handover (who runs it, where the alerts go, how it is upgraded) is recorded, and nothing is left running that no one owns.
