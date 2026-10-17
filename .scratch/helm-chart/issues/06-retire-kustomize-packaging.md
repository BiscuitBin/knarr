# 06: Retire the kustomize packaging

**Context:** [Decision 0015](01-helm-chart-decision.md) makes Helm the only supported install. After [03](03-local-loop-and-ci-install-chart.md) the local loop and CI run on the chart, and after [05](05-install-first-published-chart.md) users install the published chart. The kustomize tree and its checks are then a second packaging with no consumer. That tree is `deploy/base`, the `e2e-fast`, `wrong-ca` and `release` variants, `release-pin`, and `deployment.py`'s overlay rules.

**What to build:** Remove the kustomize packaging and move its remaining guarantees onto the chart:

- `deploy/release` goes, with the `release-pin` recipe and its comment block, `scripts/release/pin-digest.sh` and `test_release_pin.py`. `release.yml`'s recovery comment loses its `just release-pin` step: the chart that release published already carries the digest.
- `lifecycle.allium` `Uninstall` `Procedure` and the operations page drop the `kubectl delete -k` route that 05 kept for kustomize installs. This goes through the `spec-change` skill.
- `deploy/base` and the `e2e-fast` variant go. Their content now lives in the chart and its values files.
- The wrong-ca patch from 03 moves out of `deploy/` to `fixtures/`, beside the other test-only inputs. Bootstrap ticket 14's `wrong-ca.sh` and the `reconcile-proof.yml` path filter follow it, and `deploy/` is deleted.
- `deployment.py` loses `RELEASE_VALUES`, the `--render` variants and the `deployment-check` recipe. kubeconform validates the chart's render and the fake worker's resources.
- `test_deployment.py`'s invariants are tested on the chart only, and the drift check from 02 goes.
- Every path filter that names `deploy/**` loses it: `checker_suite.py` `CLUSTERS` and the `deploy/base/**` and `deploy/wrong-ca/**` lines in `reconcile-proof.yml`.
- The handbook drops the kustomize route. It has `helm template` guidance for kubectl-only users. `configuration.md` stops pointing at `deploy/base/resources.json` for the packaged `ERL_FLAGS`, and points at the chart's values.

**Non-goals:** Changing the chart's values surface. Changing what the wrong-ca patch does: it only moves. Rewriting historical tickets or evidence that mention `deploy/`, apart from the one live script, `wrong-ca.sh`.

**Blocked by:** 03, 05

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] `deploy/` no longer exists, and `rg -n "deploy/(base|release|e2e-fast)|release-pin" -g '!.scratch/**' -g '!CHANGELOG.md'` finds no live reference.
- [ ] The chart tests carry every invariant `test_deployment.py` pinned on the base, and that file loses no assertion without a chart counterpart. The hand-back lists the mapping.
- [ ] `just deploy`, `just smoke` and `just keda-e2e` pass on kind. **Authorization required:** a push, so that cluster-smoke, keda-e2e and reconcile-proof each show a green run, and the hand-back records them.
- [ ] Decisions 0012 and 0015 record the retirement. So do the [install guide](../../../docs/how-to/install.md), the [operations page](../../../docs/operations/controller.md), the [local-cluster how-to](../../../docs/how-to/local-cluster.md) and the [configuration reference](../../../docs/reference/configuration.md). `CHANGELOG.md` says which release first ships without the kustomize overlay.
- [ ] `just check-specs` reports no diagnostic and `just analyse-specs` no finding after the `Uninstall` change.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
