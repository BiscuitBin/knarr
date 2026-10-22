# 06: Retire the kustomize packaging

**Context:** [Decision 0015](01-helm-chart-decision.md) makes Helm the only supported install. After [03](03-local-loop-and-ci-install-chart.md) the local loop and CI run on the chart, and after [05](05-install-first-published-chart.md) users install the published chart. The kustomize tree and its checks are then a second packaging with no consumer. That tree is `deploy/base`, the `e2e-fast`, `wrong-ca` and `release` variants, `release-pin`, and `deployment.py`'s overlay rules.

**What to build:** Remove the kustomize packaging and move its remaining guarantees onto the chart:

- `deploy/release` goes, with the `release-pin` recipe and its comment block, `scripts/release/pin-digest.sh` and `test_release_pin.py`. `release.yml`'s recovery comment loses its `just release-pin` step: the chart that release published already carries the digest.
- `lifecycle.allium` `Uninstall` `Procedure` and the operations page drop the `kubectl delete -k` route that 05 kept for kustomize installs. The `helm uninstall` route and the saved-render `kubectl delete -f` route for kubectl-only installs stay. This goes through the `spec-change` skill.
- `deploy/base` and the `e2e-fast` variant go. Their content now lives in the chart and its values files.
- The wrong-ca patch from 03 moves out of `deploy/` to `fixtures/`, beside the other test-only inputs. Bootstrap ticket 14's `wrong-ca.sh` and the `reconcile-proof.yml` path filter follow it, and `deploy/` is deleted.
- `deployment.py` loses `RELEASE_VALUES`, the `--render` variants and the `deployment-check` recipe. kubeconform validates the chart's render and the fake worker's resources.
- `test_deployment.py`'s invariants are tested on the chart only, and the drift check from 02 goes.
- Every path filter that names `deploy/**` loses it: `checker_suite.py` `CLUSTERS` and the `deploy/base/**` and `deploy/wrong-ca/**` lines in `reconcile-proof.yml`.
- The handbook drops the kustomize route. It has `helm template` guidance for kubectl-only users, including keeping the render to remove the install with `kubectl delete -f`. `configuration.md` stops pointing at `deploy/base/resources.json` for the packaged `ERL_FLAGS`, and points at the chart's values.

**Non-goals:** Changing the chart's values surface. Changing what the wrong-ca patch does: it only moves. Rewriting historical tickets or evidence that mention `deploy/`, apart from the one live script, `wrong-ca.sh`.

**Blocked by:** 03, 05

**MVP critical path:** no.

**Status:** done. Pull request [#56](https://github.com/steven-cutting/knarr/pull/56) is open. See [the hand-back notes](#hand-back-notes).

- [x] `deploy/` no longer exists, and `rg -n "deploy/(base|release|e2e-fast)|release-pin" -g '!.scratch/**' -g '!CHANGELOG.md'` finds no live reference.
- [x] The chart tests carry every invariant `test_deployment.py` pinned on the base, and that file loses no assertion without a chart counterpart. The hand-back lists the mapping.
- [x] `just deploy`, `just smoke` and `just keda-e2e` pass on kind. **Authorization required:** a push, so that cluster-smoke, keda-e2e and reconcile-proof each show a green run, and the hand-back records them. All three passed on pull request #56 at `ac888c2` ([CI](#ci)).
- [x] Decisions 0012 and 0015 record the retirement. So do the [install guide](../../../docs/how-to/install.md), the [operations page](../../../docs/operations/controller.md), the [local-cluster how-to](../../../docs/how-to/local-cluster.md) and the [configuration reference](../../../docs/reference/configuration.md). `CHANGELOG.md` says which release first ships without the kustomize overlay.
- [x] `just check-specs` reports no diagnostic and `just analyse-specs` no finding after the `Uninstall` change.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Offline part and the local kind run on 2026-10-21 (UTC). The maintainer ran `just initialize` in this worktree and authorized the network for `just cluster-install`, `just image-build` and `just keda-e2e`. On 2026-10-22 (UTC) the maintainer authorized the push, pull request #56 and its `keda-e2e` and `cluster-s1` labels.

### What changed

- **Deleted:** `deploy/` (the base, `e2e-fast`, `release`, and `wrong-ca`'s kustomization), `scripts/release/pin-digest.sh`, `scripts/checks/tests/test_release_pin.py`, and the `release-pin` and `deployment-check` recipes with their comment blocks.
- **Moved:** `deploy/wrong-ca/patch.json` to `fixtures/wrong-ca/patch.json`, byte for byte. Its kustomization's comment now sits beside `WRONG_CA` in `cluster.py`, since JSON takes none. `wrong-ca.sh` reads no `deploy/` path (its `just deploy … base` and `wrong-ca` are `cluster.py`'s variant names), so it is unchanged.
- **Checkers.** `chart.py` loses the drift check (`drift`, `paths`, `allowed`, `LABEL`, `BASE`); its checks are lint, render and version. `deployment.py` loses `RELEASE_VALUES`, the variants, `--render` and `overlay_difference`; with no argument it validates the fake worker's resources, and `chart.py render` validates the chart's render through the same `validate()`. `image.py` reads knarr's memory budget from the `resources.limits.memory` line of `charts/knarr/values.yaml`, by line as `stamp-chart.sh` reads the chart, because a helm render there would run through the `subprocess.run` that `test_image.py` replaces; `Profile` takes a memory-limit callable. `keda_e2e.py` labels the comparison segment `e2e-fast`.
- **Selection.** `checker_suite.py` drops every `deploy/**` input. `packaging` gains `charts/knarr/values.yaml`, `chart` and `cluster` gain `fixtures/wrong-ca/**`, `release` is `release_lib` alone, and `CLUSTERS` kind loses `deploy/**`. kwok's patterns are gone: they served `deployment-check`, its only step that read files, so only the shared paths and `cluster.py` select kwok now. kind keeps `deployment.py`, which `cluster.py` imports through `chart.py`. `reconcile-proof.yml` swaps `deploy/base/**` and `deploy/wrong-ca/**` for `fixtures/wrong-ca/**`, and a test asserts the filter matches the patch.
- **Workflows.** `ci.yml` loses both `just deployment-check` steps. `release.yml`'s recovery comment loses step 4, and the summary's "Pin this in deploy/release" line names the digest as the one stamped into the run's chart.
- **Spec, prose only.** `lifecycle.allium` `Uninstall` `Procedure` drops `kubectl delete -k`, keeps `helm uninstall` and `kubectl delete -f` on the saved render, and gains a provenance line. `Restart` `Replica` and `ownership.allium` `Ownership` `Objects` cite `test_chart.py` for what `test_deployment.py` proved on the base.
- **Docs.** The install guide drops "Migrate from the kustomize release overlay" and "Kustomize route (deprecated)", and gains "Installs from the kustomize overlay", which sends an overlay install to the `v0.2.0` guide's migration procedure and a `v0.1.0` skeleton to its direct removal. Both anchors exist at the tag. The operations page drops the `delete -k` command. An install still made from the overlay is deleted from its retained checkout, as the `v0.2.0` operations page describes, without moving it to Helm first. The page links there and repoints its skeleton link to the `v0.2.0` guide. `local-cluster.md`, `configuration.md` (the chart's `knarr` values in place of the base's `ERL_FLAGS` and an overlay), `fake-worker.md`, `keda-e2e.md`, `docs/README.md`, `OVERVIEW.md` and `DEFERRED.md` follow. Decisions 0003, 0012 and 0015 gain "Amended by ticket 06" lines and keep their original record. `CHANGELOG.md` `[Unreleased]` `Removed` names what went and says 0.2.0 is the last release whose tag carries the overlay and the next release the first without it, with a pointer to the `v0.2.0` migration procedure; the "`deploy/release` pins the digest of 0.2.0" line is gone.
- **Comments.** `AGENTS.md` and `README.md` drop `just release-pin` from the recipes that rewrite tracked files (it was not an `[agents]` phrase), and the `Justfile` header now counts four. `values.yaml`, `templates/deployment.yaml`, `fixtures/chart-values/e2e-fast.yaml`, `pixi.toml` and `lib.sh` no longer cite `deploy/` or `pin-digest.sh`. kustomize stays pinned: it canonicalises the render for the chart tests and patches it for the wrong-CA case.

### Invariant mapping

Every assertion `test_deployment.py` made on the base, and where the chart tests now hold it:

| `test_deployment.py` on `deploy/base` | `test_chart.py` on the chart's render |
| --- | --- |
| four kinds; no Lease, nothing in `coordination.k8s.io` | `test_the_chart_renders_the_four_resources_and_nothing_else` |
| one replica, strategy `Recreate` | `test_one_replica_under_recreate` |
| automount off on the ServiceAccount and the pod; projected token (600 s), CA and namespace; read-only mount | `test_the_token_is_projected_with_the_shortest_expiry_and_read_only`, which now asserts `automountServiceAccountToken: false` on the ServiceAccount document and on the Deployment's pod spec (each found by kind), not a count of 2 |
| `runAsNonRoot`, read-only root, no privilege escalation, drop `ALL` | `test_the_security_contexts_hold` |
| `imagePullPolicy: Never`; env exactly `ERL_FLAGS=-knarr discovery true` | `test_erl_flags_is_exactly_discovery_by_default` |
| Role rules exact, `roleRef`, subjects; the only writes are pods `patch` and events `create` | `test_the_role_grants_exactly_the_verbs_the_client_uses` (exact rules fix the write set) |
| readiness `/readyz`, liveness `/healthz` | **new** `test_the_probes_are_readyz_and_healthz` |
| the wrong-ca patch only redirects the CA file | **moved** `test_the_wrong_ca_patch_only_redirects_the_ca_file`, which also refuses any other key in the patch |
| the e2e-fast patch only shortens the intervals | **rewritten** `test_the_e2e_fast_values_only_shorten_the_intervals`: the values file's `ERL_FLAGS` equals the exact string, each interval once, in `application_ffi.erl`'s key order, with rate and burst unset |
| the release overlay's two-line difference, the variants list, `--render` with fakes, the committed overlay | retired with the overlay; the published image is `stamp-chart_test.sh`'s |
| vendored schemas are upstream JSON; a changed schema is refused | kept in `test_deployment.py` (they test `deployment.verify`) |

`test_observability.py` reads the pod label and port from the chart's canonical render, and `test_fake_worker_manifests.py` expects `deployment.py` to validate the fake worker only.

### What was verified

- `rg -n "deploy/(base|release|e2e-fast)|release-pin" -g '!.scratch/**' -g '!CHANGELOG.md'` (run as the equivalent `git grep`, because `rg` from the worktree root walked ignored directories for minutes) finds only decision records 0003, 0012 and 0015. The maintainer decided their historical text stays; each now carries an amendment recording the retirement.
- `pytest` on every touched test file: `test_chart`, `test_deployment`, `test_image`, `test_observability`, `test_fake_worker_manifests`, `test_checker_suite`, `test_keda_e2e`, `test_cluster_commands` and `test_workflows`, 329 passed. The new chart tests pass at once, because the chart already held what they pin; they are counterparts, not new behaviour.
- `just chart-check` (lint, render, version), `just packaging-check` (kubeconform: 3 fake worker resources valid), `just docs-check` (36 pages, 48 topics), `just agents-check`, `just check-specs` and `just analyse-specs` (11 specifications, no diagnostic and no finding).
- `just plan-spec`: `lifecycle.allium` 8 obligations and `ownership.allium` 29, before (HEAD's modules copied out) and after; the plans are identical apart from the module path.
- On this worktree's kind cluster (arm64): `just cluster-up`, `just image-build`, `just image-check` (the 256 MiB budget, now from the chart's values: `memory usage / limit: 64.12MiB / 256MiB`), `just deploy` and `just smoke` (`/healthz`, `/readyz`, `/metrics`). `wrong-ca.sh` from `fixtures/wrong-ca/patch.json`: 2 cycles refused with `unknown_ca`, no LIST or PATCH succeeded, the pod Running and NotReady with restartCount 0, then the restore redeployed the base and deleted the ConfigMap.
- `just keda-e2e` (3 rounds, seed 33) on the same cluster, with the comparison phase installed from `fixtures/chart-values/e2e-fast.yaml`: "keda-e2e: all checks passed". Baseline rounds killed 2 of 3 busy workers each and knarr rounds 0 of 3; patch rate e2e-fast peak 13 of 310 in 60 s; after the restart, untouched 0 patches over 300 s, opt-out cleaned 0.1 s after readiness, changed patched 6.4 s after. The first attempt stopped at `kind load` because the fake worker image had not been built (the guide's prerequisite `just fake-worker-image-build`); the rerun after building it is the result above.
- `just image-check` was rerun after the review changed `image.py`'s parse: `memory usage / limit: 65.81MiB / 256MiB`.
- The branch's `code-review` pass (medium) found seven issues, all fixed: the operations page now keeps a delete route for overlay installs, by link to `v0.2.0`, rather than forcing a migration mid-uninstall; kwok no longer selects on paths it never reads; `packaging` selects on `values.yaml` only; `image.py`'s parse accepts other keys under `limits`, a quoted value and a comment (checked against such a layout); the e2e-fast test pins the exact string; the pod-level automount check finds the Deployment by kind; and the release runbook's last sentence belongs to step 3. `lifecycle.allium` still drops `delete -k`, as this ticket requires.
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes.

- Links in earlier tickets to what this ticket removed now point at the `v0.2.0` tag, with their text unchanged: [05](05-install-first-published-chart.md)'s migration box linked `install.md#select-the-tag-and-digest-together`, and bootstrap [36](../../bootstrap/issues/36-release-workflow-and-overlay.md) and [37](../../bootstrap/issues/37-first-release-v0-1-0.md) linked `deploy/release/kustomization.yaml` and `pin-digest.sh`. lychee checks local links offline and failed on all four.

### CI

Pull request [#56](https://github.com/steven-cutting/knarr/pull/56), at `ac888c2`, on 2026-10-22 (UTC). keda-e2e and reconcile-proof run on a pull request only while it carries their label, so the `keda-e2e` and `cluster-s1` labels were added after it opened:

- cluster-smoke ("Kind smoke"): [run 39724409647](https://github.com/steven-cutting/knarr/actions/runs/39724409647/job/119645672286), success, 1m51s. The same CI run passed the repository gate, the selected checker regressions, the fake worker smoke and kwok readiness.
- keda-e2e: [run 39724848650](https://github.com/steven-cutting/knarr/actions/runs/39724848650/job/119646299983), success, 12 minutes.
- reconcile-proof: [run 39724848306](https://github.com/steven-cutting/knarr/actions/runs/39724848306/job/119646298737), success, 9 minutes.

Adding each label also started a run of the other workflow, which skipped because its own label was not the one added (runs 39724848294 and 39724848927). `gh pr checks` shows those skipped runs, the latest for each name.

### What each later ticket needs

- **07 and 08:** the chart is knarr's only packaging. `fixtures/wrong-ca/patch.json` is the one install input outside the chart, a test-only patch the reconcile proof applies. A change to `charts/knarr/values.yaml` also selects the `packaging` checker group, because `image.py` reads knarr's memory limit from it.
- **Anyone still on the overlay:** the `v0.2.0` install guide's migration procedure, linked from the current guide and the changelog.
