# 05: Install the first published chart from ghcr

**Context:** [04](04-release-publishes-chart.md) teaches the release to publish the chart, but nothing has been published until a release runs. Bootstrap ticket [37](../../bootstrap/issues/37-first-release-v0-1-0.md) found the image package public from its first push, although ghcr packages are private by default. The chart package must be checked, not assumed. Bootstrap ticket [40](../../bootstrap/issues/40-mvp-release.md) is not edited for this. If 40's MVP release is tagged after 04 merges, it publishes the first chart. Otherwise a patch release does.

**What to build:** The chart's first published version, a verified anonymous pull, a `helm install` by digest on a fresh kind cluster, and the user-facing install path:

- The install guide is rewritten Helm-first: install, upgrade, migration from kustomize, and uninstall. Uninstall keeps the order that the [operations page](../../../docs/operations/controller.md) and `lifecycle.allium` `Uninstall` `Procedure` state: opt out, wait for cleanup, inspect and recover markers, and only then `helm uninstall`. Deleting a running controller first leaves its owned annotations standing.
- The `Uninstall` `Procedure` clause and the operations page name the install's delete command: `helm uninstall`; `kubectl delete -f` on the manifest saved at install for `helm template … | kubectl apply -f -` installs, which leave no Helm release for `helm uninstall` to find; and `kubectl delete -k` for kustomize installs until 06. This is a `spec-change` to the clause's prose, made with the `spec-change` skill.
- The migration from 0015: an existing install from the release overlay is adopted into a Helm release.

**Non-goals:** Writing `NOTES.txt`, which 02 does so that the first published chart carries it. Changing the release workflow (a fix goes through 04's shape). Retiring kustomize (06). Attestation (07). Artifact Hub (08).

**Blocked by:** 04, and the next release after 04 merges (40's MVP release, or a patch).

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** the release that carries 04, through the route 37 recorded: the release pull request, the tag and the approved run. The hand-back records the run URL and the chart digest its summary prints.
- [ ] **Authorization required:** the network. An anonymous `helm pull oci://ghcr.io/steven-cutting/charts/knarr --version X.Y.Z` succeeds, and the hand-back records the digest it reports. If the package is private, the maintainer makes it public once, by hand, and the hand-back records that.
- [ ] `helm install knarr oci://ghcr.io/steven-cutting/charts/knarr@sha256:<digest>` on a fresh kind cluster rolls out, the pod runs the image digest that release pushed, and `just smoke`'s checks pass against it.
  - Rehearsed locally from `charts/knarr` with the worktree image, not the published chart: install, rollout and `just smoke` ([01-install-upgrade.txt](../evidence/05/01-install-upgrade.txt)). Needs the published chart.
- [ ] `helm upgrade` to the same version with one changed value rolls the pod.
  - Rehearsed locally: `knarr.log_level=debug` rolled the pod to a new uid ([01-install-upgrade.txt](../evidence/05/01-install-upgrade.txt)). Needs the published chart.
- [ ] Uninstall, on a cluster with opted-in workers that carry owned annotations and a foreign `pod-deletion-cost` value, runs in the specified order: opt out, then the discovery and metric waits, then marker inspection and recovery, and only then `helm uninstall`. Afterwards no knarr-owned annotation or marker remains, and the foreign value is preserved.
  - Rehearsed locally on a Helm install ([03-uninstall-order.txt](../evidence/05/03-uninstall-order.txt)) and on a migrated one ([11-uninstall-after-migration.txt](../evidence/05/11-uninstall-after-migration.txt)): three owned values and a foreign `-7`; after opt-out, waits and marker listing, `helm uninstall` left no owned value or marker and kept `-7`. Needs the published chart.
- [ ] Migration: on a fresh kind cluster, a checkout of the previous tag, with `just release-pin` set to that release's own digest from its run summary, installs knarr through `kubectl apply -k deploy/release`, and its rollout completes on that digest. An unmodified tag checkout carries the digest before it ([install guide](../../../docs/how-to/install.md#select-the-tag-and-digest-together)), so it is not used. The four resources get the adoption label and annotations, and `helm upgrade --install` at this release adopts them. A pod watch across the adoption shows no two knarr pods running at once; the `Recreate` gap is allowed (`lifecycle.allium` `Restart` `Replica`). One Ready replica runs once the rollout completes, and upgrade and uninstall then work as above. The install guide documents the procedure, and the hand-back records the run.
  - Rehearsed locally with `deploy/base` and a stand-in image, since the previous tag's image is amd64 on ghcr and this host is arm64 and offline. The bare adoption conflicts under Helm 4's server-side apply ([04](../evidence/05/04-migration-conflict.txt), [05](../evidence/05/05-migration-force-conflicts.txt), [06](../evidence/05/06-migration-ssa-handover.txt)); the guide's handover then adoption works, one pod at a time ([07](../evidence/05/07-migration-ssa-handover-forced.txt), [09](../evidence/05/09-pod-watch-recount.txt), [10](../evidence/05/10-migration-recovery.txt)). Needs the published chart and the previous tag.
- [ ] The kubectl-only route: on a fresh kind cluster, the `helm template` render is saved to a file and applied with `kubectl apply -f`, and it rolls out. After the same opt-out, waits and marker recovery as above, `kubectl delete -f` on that file removes every knarr resource.
  - Rehearsed locally from `charts/knarr`: render saved, applied, rolled out, cleaned up, and `kubectl delete -f` removed all four resources, keeping the foreign value ([12-kubectl-only.txt](../evidence/05/12-kubectl-only.txt)). Needs the published chart.
- [x] `lifecycle.allium` `Uninstall` `Procedure` and the operations page name `helm uninstall`, and `kubectl delete -f` on the saved render for kubectl-only installs, as the delete step. `just check-specs` reports no diagnostic, and `just analyse-specs` no finding.
- [x] The [install guide](../../../docs/how-to/install.md) is Helm-first, with install, upgrade and uninstall. It states that `helm template … | kubectl apply -f -` is the route for kubectl-only installs, and that those installs keep the rendered manifest, because removing them is `kubectl delete -f` on it. The kustomize route stays documented, as deprecated, until 06.
- [ ] The `helm pull`ed chart carries 02's `NOTES.txt`, and `helm install` prints it.
  - The local chart's `helm install` printed `NOTES.txt` ([01-install-upgrade.txt](../evidence/05/01-install-upgrade.txt)). Needs the pulled chart.
- [ ] `CHANGELOG.md` names the release that first published the chart.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Offline part and local rehearsal on 2026-10-19 (UTC). The status stays `needs-human`: no chart is published, because only `v0.1.0` is tagged and it predates 04.

### What changed

- `docs/specs/lifecycle.allium` `Uninstall` `Procedure`: the delete step names each route's command, `helm uninstall`, `kubectl delete -f` on the manifest saved at install for a `helm template` render applied with kubectl, and `kubectl delete -k` for kustomize until 06, with a provenance line. Prose only: no rule, trigger or behaviour changed, so no test or code follows.
- `docs/operations/controller.md` "Uninstall and recover": the three delete commands in that order, and the skeleton's direct-removal link repointed to `install.md#remove-the-skeleton`.
- `docs/how-to/install.md`, rewritten Helm-first: install by version or chart digest with a pod image check, upgrade (with `--reuse-values` evidence), the kubectl-only route that keeps the render, migration by adoption with a field-ownership handover, uninstall pointing at the operations page, and the kustomize route as deprecated, keeping `#select-the-tag-and-digest-together`. `docs/README.md`'s line follows.
- Decision 0015 "Migration by adoption": amended with the server-side apply finding below.
- `CHANGELOG.md` `[Unreleased]` `Changed`: the Helm-first guide and the delete commands.
- `.scratch/helm-chart/evidence/05/`: `state.sh`, `metrics.sh` and `control.sh` (pod proxy helpers) and twelve transcripts, traced with `sh -x`.

### What was verified

- `just check-specs` and `just analyse-specs`: no diagnostic or finding. `just plan-spec docs/specs/lifecycle.allium`: 8 obligations before (HEAD's specs copied out) and after, and the two plans are byte-identical.
- `just docs-check` and `just lint` pass.
- On this worktree's kind cluster (`kindest/node` v1.35.8, Helm 4.3.0, arm64), from `charts/knarr` with the worktree image (network authorized for `just image-build` only):
  - Install, rollout, `NOTES.txt` and `just smoke`; an upgrade with one changed value rolled the pod (01).
  - `--reuse-values` keeps the previous chart's built-in image, and `--reset-then-reuse-values` and a plain upgrade take the new chart's (02).
  - The ordered uninstall: three owned values and a foreign `-7`; opt-out, a discovery later than it with 0 Deployment targets and no owned series, no marker left, then `helm uninstall`; `-7` preserved and no knarr resource left (03; after migration, 11).
  - The kubectl-only route, from the saved render to `kubectl delete -f` on it (12).
- **Finding: adoption as 0015 wrote it fails under Helm 4.** Label and annotations, then `helm upgrade --install`, conflicted with `kubectl-client-side-apply` on the image, the RoleBinding's subjects and the projected token volume. The release was marked failed and the kustomize controller kept running unchanged (04). `--force-conflicts` adopted, but the next ordinary upgrade conflicted on a field kubectl still co-owned (05). Clearing `managedFields` handed every field to `before-first-apply`, with the same conflicts (that transcript was not kept). An unforced same-value apply as manager `helm` moved the RBAC objects but not the Deployment's projected sources (06). The forced same-value apply as `helm`, then the label and annotations, then a plain `helm upgrade --install` adopted with Helm as sole server-side manager. A later upgrade applied with no conflict, owned annotations survived, and at most one knarr pod ran at once (07; recounted in 09). The same handover after a failed bare adoption recovers (10). Client-side adoption (`--server-side=false`) also worked but leaves the release client-side for good (08). The maintainer chose the handover on 2026-10-19 after research: Kubernetes documents ownership transfer by same-value apply, and Helm's HIP-0023 says Helm "won't support ownership transfer of fields".
- Codex's static review of the first docs draft found three issues, all fixed: the spec clause was not yet changed, the guide claimed a release order the ticket does not fix, and the image check read only the template.
- A Helm upgrade with no values flag keeps the previous release's own overrides and takes the new chart's image, and one `--set` drops all the earlier overrides (13), so the guide passes one values file on every upgrade. Before the handover, `kubectl diff -k` is silent on an untouched install and shows a hand edit, which the forced apply would revert (14).
- The branch's `code-review` pass (medium) found eight issues. Seven were fixed: the gate rerun after the last edits, the drift check before the forced handover, "sole manager" narrowed to the server-side manager in 0015, the upgrade values wording, pruning in the kubectl-only upgrade, the provenance date, and the recount covering 06 and 10. The eighth stands as a disclosed gap: the `oci://` commands were never run (below).
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes.
- Not run: every guide command with an `oci://` reference (install and upgrade by version, install by `@sha256:` digest, `helm template` of the remote chart). All rehearsals used `charts/knarr` on disk. Ticket 04's loopback `registry:2` dry run could check their syntax before the release, behind one network ask for the image.
- Not done, all needing the published chart: the release, visibility and anonymous pull, install by digest, the real migration from the previous tag's own digest, the pulled chart's `NOTES.txt`, and the CHANGELOG line naming the release. The migration stand-in was `deploy/base` with the local image re-tagged `knarr:local`, because the previous release's image is amd64 on ghcr and this host is arm64.

### What each later ticket needs

- **The human finishing 05:** run the release that carries 04 (release pull request, tag, approved run), record the run URL and chart digest, check the package's visibility and an anonymous `helm pull`, then repeat 01, 03, 07 and 12 on a fresh kind cluster against `oci://ghcr.io/steven-cutting/charts/knarr@<digest>` (amd64, or a host that can run it). For the migration, start from a checkout of the previous tag with `just release-pin` set to its own digest, and follow the guide's handover exactly. Then name the release in `CHANGELOG.md`, replace the install guide's opening sentence that no recorded release has published a chart with that release, and tick the boxes.
- **06:** retiring kustomize removes the guide's handover step and the deprecated section. The Helm-only route needs neither. Keep a pointer to this procedure in the changelog for anyone still on the overlay.
