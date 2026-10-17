# 08: List knarr on Artifact Hub

**Context:** Artifact Hub indexes OCI Helm repositories. It reads an `artifacthub.io` metadata layer pushed beside the chart, and the chart's `artifacthub.io/*` annotations ([Artifact Hub Helm repositories](https://artifacthub.io/docs/topics/repositories/helm-charts/)). A listing helps adoption, which is why [Decision 0015](01-helm-chart-decision.md) exists, but it is not needed to install.

**What to build:** The `artifacthub.io` metadata layer pushed with oras to `ghcr.io/steven-cutting/charts/knarr:artifacthub.io`, the repository registered on Artifact Hub, and the static chart annotations it reads: license, links and changes. `artifacthub.io/images` is not static. 04's packaging step stamps it from the pushed digest, so this ticket merges the annotations, then cuts a release that carries them before the repository is registered. That release is part of this ticket's work, not a blocker.

**Non-goals:** Verified-publisher or official status. Any change to the chart's templates or values.

**Blocked by:** 05

**MVP critical path:** no.

**Status:** needs-human

- [ ] The chart's `Chart.yaml` carries the static `artifacthub.io` annotations. 04's stamping test still shows that `artifacthub.io/images` is set from the pushed digest.
- [ ] **Authorization required:** the release that carries these annotations, through the route 37 recorded. Its packaged chart's `artifacthub.io/images` names the digest that run pushed.
- [ ] **Authorization required:** the network and a registry push. The metadata layer is pushed with oras, and an anonymous pull of the `artifacthub.io` tag succeeds.
- [ ] **Authorization required:** an Artifact Hub account. The maintainer registers the repository, and the hand-back records the listing's URL and shows that the first indexed version is the annotated release.
- [ ] The [install guide](../../../docs/how-to/install.md) links the listing, and `CHANGELOG.md` records it.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
