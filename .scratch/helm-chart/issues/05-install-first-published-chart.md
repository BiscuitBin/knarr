# 05: Install the first published chart from ghcr

**Context:** [04](04-release-publishes-chart.md) teaches the release to publish the chart, but nothing has been published until a release runs. Bootstrap ticket [37](../../bootstrap/issues/37-first-release-v0-1-0.md) found the image package public from its first push, although ghcr packages are private by default. The chart package must be checked, not assumed. Bootstrap ticket [40](../../bootstrap/issues/40-mvp-release.md) is not edited for this. If 40's MVP release is tagged after 04 merges, it publishes the first chart. Otherwise a patch release does.

**What to build:** The chart's first published version, a verified anonymous pull, a `helm install` by digest on a fresh kind cluster, and the user-facing install path:

- The install guide is rewritten Helm-first: install, upgrade and uninstall. Uninstall is `helm uninstall` plus the annotation recovery commands that the [operations page](../../../docs/operations/controller.md) owns.
- The chart gains a `NOTES.txt`.

**Non-goals:** Changing the release workflow (a fix goes through 04's shape). Retiring kustomize (06). Attestation (07). Artifact Hub (08).

**Blocked by:** 04, and the next release after 04 merges (40's MVP release, or a patch).

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** the release that carries 04, through the route 37 recorded: the release pull request, the tag and the approved run. The hand-back records the run URL and the chart digest its summary prints.
- [ ] **Authorization required:** the network. An anonymous `helm pull oci://ghcr.io/steven-cutting/charts/knarr --version X.Y.Z` succeeds, and the hand-back records the digest it reports. If the package is private, the maintainer makes it public once, by hand, and the hand-back records that.
- [ ] `helm install knarr oci://ghcr.io/steven-cutting/charts/knarr@sha256:<digest>` on a fresh kind cluster rolls out, the pod runs the image digest that release pushed, and `just smoke`'s checks pass against it.
- [ ] `helm upgrade` to the same version with one changed value rolls the pod, and `helm uninstall` followed by the operations page's recovery commands leaves no knarr annotation on a worker pod.
- [ ] The [install guide](../../../docs/how-to/install.md) is Helm-first, with install, upgrade and uninstall. It states that `helm template … | kubectl apply -f -` is the route for kubectl-only installs. The kustomize route stays documented, as deprecated, until 06.
- [ ] `NOTES.txt` prints the namespace, the opt-in label and a pointer to the install guide, and a test checks its render.
- [ ] `CHANGELOG.md` names the release that first published the chart.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
