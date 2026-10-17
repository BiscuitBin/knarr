# 03: The local loop and CI install the chart

**Context:** `just deploy` renders a `deploy/` variant through `cluster.py`, which adds the `knarr.dev/local-image-id` pod annotation, and then waits for the rollout. The `e2e-fast` variant shortens the intervals for the KEDA harness. The `wrong-ca` variant breaks the CA for the negative TLS case (ticket 14). The cluster-smoke, keda-e2e and reconcile-proof workflows all deploy through these variants. Once the chart from [02](02-chart-renders-base.md) exists, the real gain is that CI installs the same artifact a user installs.

**What to build:**

- `just deploy` runs `helm upgrade --install --wait` with the chart. The image override goes in through `--set`, the local image id through `podAnnotations`, and `--wait` replaces the rollout wait.
- `e2e-fast` becomes a values file, because its intervals are user knobs.
- `wrong-ca` stays a test-only patch, never a chart value. It is applied to the `helm template` output through kustomize, because Helm 4's post-renderers are plugins.
- `just smoke`, `just keda-e2e`, and the cluster-smoke, keda-e2e and reconcile-proof workflows run against the chart.
- KEDA itself stays sha-pinned YAML. Its chart lives in a separate gh-pages repository, so switching it to Helm gains nothing.

**Non-goals:** Removing `deploy/` (06): the drift check from 02 still holds the base to the chart. Publishing the chart (04). Installing KEDA with Helm.

**Blocked by:** 02

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] `just deploy` installs the chart with `helm upgrade --install --wait`. A second run upgrades the release in place, and `just smoke` reports ok for `/healthz`, `/readyz` and `/metrics`.
- [ ] The local image id reaches the pod as the `knarr.dev/local-image-id` annotation through `podAnnotations`, so a reload of the same tag still rolls the pod.
- [ ] The e2e-fast values file sets the same intervals as `deploy/e2e-fast`, and `just keda-e2e` passes with it.
- [ ] The wrong-ca case applies its patch to the `helm template` output. Its rollout never completes by design, because readiness never latches, so this path does not use `--wait`. Bootstrap ticket 14's `wrong-ca.sh`, which runs `just deploy "$image" wrong-ca`, keeps working unchanged or is updated with it. The reconcile-proof workflow's negative TLS case still fails closed in the same way.
- [ ] The path filters cover the chart. `checker_suite.py` `CLUSTERS` adds it to both the `kind` and `kwok` tuples, beside `deploy/**`. `reconcile-proof.yml` adds it beside `deploy/base/**` and `deploy/wrong-ca/**`. Each workflow that deploys knarr triggers on a chart-only change, and `test_checker_suite.py` asserts that.
- [ ] **Authorization required:** a push, so that cluster-smoke, keda-e2e and reconcile-proof each show a green run against the chart. The hand-back records the run URLs.
- [ ] The [local-cluster how-to](../../../docs/how-to/local-cluster.md) and the [KEDA harness reference](../../../docs/reference/keda-e2e.md) describe the chart-based loop. `CHANGELOG.md` records the change.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
