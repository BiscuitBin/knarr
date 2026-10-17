# 02: A chart that renders knarr's base, gated

**Context:** [Decision 0015](01-helm-chart-decision.md) puts a Helm chart in this repository and fixes its values surface, schema policy, versioning and gate environment. Until 06 retires it, `deploy/base` stays the input to the local loop and to CI, so for a while the chart and the base both exist. Projects that keep two hand-maintained formats see them drift (KEDA, external-dns), so the gate holds the chart's render to the base for as long as both exist. `test_deployment.py` pins the base's invariants today: the Role rules, no Lease, the token projection, `ERL_FLAGS` exactly `-knarr discovery true`, and the security context.

**What to build:** A chart in the location 0015 names, with:

- Four templates: the ServiceAccount, Role, RoleBinding and Deployment that `deploy/base/resources.json` holds.
- A `_helpers.tpl` that sets the recommended `app.kubernetes.io/*` and `helm.sh/chart` labels.
- `values.yaml`, and a `values.schema.json` that follows 0015's range policy.
- `Chart.yaml`, with `version` and `appVersion` equal to the `gleam.toml` version.

Rendered with local values, the chart matches `kustomize build deploy/base` apart from the Helm labels. A gate check enforces that match while both exist. The `-knarr` values render into `ERL_FLAGS` after `-knarr discovery true`. An unset value renders nothing, so the default render's `ERL_FLAGS` is exactly `-knarr discovery true`.

**Non-goals:** The local loop and CI installing the chart (03). Publishing it (04). Retiring `deploy/` (06). Any value 0015 does not list.

**Blocked by:** 01

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] The chart renders the four resources into `.Release.Namespace`. It has no `replicaCount`, ClusterRole, PDB, Service or ServiceMonitor.
- [ ] The values and schema are 0015's surface, no more and no less. `additionalProperties: false` rejects an unknown key, and a test proves it. If 0015 chose ranges, a checker test pins each range to `config.allium` and `config.gleam`.
- [ ] `test_deployment.py`'s invariants hold on the chart's default render, through tests beside the existing ones: the Role rules, no Lease, the token projection, `ERL_FLAGS`, the security context, one replica and `Recreate`. A render with several `-knarr` values set keeps `-knarr discovery true` first.
- [ ] A gate check fails when the chart's render with local values and `kustomize build deploy/base` differ in anything but the Helm labels. A seeded difference proves that it fails.
- [ ] `helm lint --strict` passes, and kubeconform `-strict` validates the render against the vendored schemas. These run in the gate environment 0015 chose.
- [ ] A gate check fails when the chart's `version` or `appVersion` differs from the `gleam.toml` version, and its test seeds that difference.
- [ ] `CHANGELOG.md` records the chart under Unreleased. Any new handbook page, such as a chart values reference, is registered in `docs/manifest.yml`.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
