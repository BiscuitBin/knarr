# 05: Install the first published chart from ghcr

**Context:** [04](04-release-publishes-chart.md) teaches the release to publish the chart, but nothing has been published until a release runs. Bootstrap ticket [37](../../bootstrap/issues/37-first-release-v0-1-0.md) found the image package public from its first push, although ghcr packages are private by default. The chart package must be checked, not assumed. Bootstrap ticket [40](../../bootstrap/issues/40-mvp-release.md) is not edited for this. If 40's MVP release is tagged after 04 merges, it publishes the first chart. Otherwise a patch release does.

**What to build:** The chart's first published version, a verified anonymous pull, a `helm install` by digest on a fresh kind cluster, and the user-facing install path:

- The install guide is rewritten Helm-first: install, upgrade, migration from kustomize, and uninstall. Uninstall keeps the order that the [operations page](../../../docs/operations/controller.md) and `lifecycle.allium` `Uninstall` `Procedure` state: opt out, wait for cleanup, inspect and recover markers, and only then `helm uninstall`. Deleting a running controller first leaves its owned annotations standing.
- The `Uninstall` `Procedure` clause and the operations page name the install's delete command: `helm uninstall`, with `kubectl delete -k` for kustomize installs until 06. This is a `spec-change` to the clause's prose, made with the `spec-change` skill.
- The migration from 0015: an existing install from the release overlay is adopted into a Helm release.

**Non-goals:** Writing `NOTES.txt`, which 02 does so that the first published chart carries it. Changing the release workflow (a fix goes through 04's shape). Retiring kustomize (06). Attestation (07). Artifact Hub (08).

**Blocked by:** 04, and the next release after 04 merges (40's MVP release, or a patch).

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** the release that carries 04, through the route 37 recorded: the release pull request, the tag and the approved run. The hand-back records the run URL and the chart digest its summary prints.
- [ ] **Authorization required:** the network. An anonymous `helm pull oci://ghcr.io/steven-cutting/charts/knarr --version X.Y.Z` succeeds, and the hand-back records the digest it reports. If the package is private, the maintainer makes it public once, by hand, and the hand-back records that.
- [ ] `helm install knarr oci://ghcr.io/steven-cutting/charts/knarr@sha256:<digest>` on a fresh kind cluster rolls out, the pod runs the image digest that release pushed, and `just smoke`'s checks pass against it.
- [ ] `helm upgrade` to the same version with one changed value rolls the pod.
- [ ] Uninstall, on a cluster with opted-in workers that carry owned annotations and a foreign `pod-deletion-cost` value, runs in the specified order: opt out, then the discovery and metric waits, then marker inspection and recovery, and only then `helm uninstall`. Afterwards no knarr-owned annotation or marker remains, and the foreign value is preserved.
- [ ] Migration: on a fresh kind cluster, `kubectl apply -k deploy/release` at the previous tag installs knarr. The four resources get the adoption label and annotations, and `helm upgrade --install` at this release adopts them. Exactly one knarr pod runs throughout, with no second controller, and upgrade and uninstall then work as above. The install guide documents the procedure, and the hand-back records the run.
- [ ] `lifecycle.allium` `Uninstall` `Procedure` and the operations page name `helm uninstall` as the delete step. `just check-specs` reports no diagnostic, and `just analyse-specs` no finding.
- [ ] The [install guide](../../../docs/how-to/install.md) is Helm-first, with install, upgrade and uninstall. It states that `helm template … | kubectl apply -f -` is the route for kubectl-only installs. The kustomize route stays documented, as deprecated, until 06.
- [ ] The `helm pull`ed chart carries 02's `NOTES.txt`, and `helm install` prints it.
- [ ] `CHANGELOG.md` names the release that first published the chart.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
