# 02: A chart that renders knarr's base, gated

**Context:** [Decision 0015](01-helm-chart-decision.md) puts a Helm chart in this repository and fixes its values surface, schema policy, versioning and gate environment. Until 06 retires it, `deploy/base` stays the input to the local loop and to CI, so for a while the chart and the base both exist. Projects that keep two hand-maintained formats see them drift (KEDA, external-dns), so the gate holds the chart's render to the base for as long as both exist. `test_deployment.py` pins the base's invariants today: the Role rules, no Lease, the token projection, `ERL_FLAGS` exactly `-knarr discovery true`, and the security context.

**What to build:** A chart in the location 0015 names, with:

- Four templates: the ServiceAccount, Role, RoleBinding and Deployment that `deploy/base/resources.json` holds.
- A `_helpers.tpl` that sets the recommended `app.kubernetes.io/*` and `helm.sh/chart` labels.
- `values.yaml`, and a `values.schema.json` that follows 0015's range policy.
- `Chart.yaml`, with `version` and `appVersion` equal to the `gleam.toml` version.
- A `NOTES.txt`, so that the first published chart carries it.

Rendered with local values, the chart matches `kustomize build deploy/base` apart from an explicit allowlist: `metadata.namespace`, the RoleBinding's `subjects[].namespace`, and the `app.kubernetes.io/*` and `helm.sh/chart` labels outside the selector. The base sets no namespace, and the chart sets both namespaces to `.Release.Namespace`, so that `helm template … | kubectl apply -f -` binds the right ServiceAccount. A gate check enforces that match while both exist. The resource names and the Deployment selector stay exactly the base's, because 0015's migration adopts the existing resources and a Deployment selector cannot change. The `-knarr` values render into `ERL_FLAGS` after `-knarr discovery true`. An unset value renders nothing, so the default render's `ERL_FLAGS` is exactly `-knarr discovery true`.

**Non-goals:** The local loop and CI installing the chart (03). Publishing it (04). Retiring `deploy/` (06). Any value 0015 does not list.

**Blocked by:** 01

**MVP critical path:** no.

**Status:** ready-for-agent

- [x] The chart renders the four resources into `.Release.Namespace`. It has no `replicaCount`, ClusterRole, PDB, Service or ServiceMonitor.
- [x] The values and schema are 0015's surface, no more and no less. `additionalProperties: false` rejects an unknown key on the objects knarr defines, and a test proves it; another test proves an arbitrary annotation key such as `knarr.dev/local-image-id` renders, as 0015's open maps allow. If 0015 chose ranges, a checker test pins each range to `config.allium` and `config.gleam`.
- [x] `test_deployment.py`'s invariants hold on the chart's default render, through tests beside the existing ones: the Role rules, no Lease, the token projection, `ERL_FLAGS`, the security context, one replica and `Recreate`. A render with several `-knarr` values set keeps `-knarr discovery true` first.
- [x] A gate check fails when the chart's render with local values and `kustomize build deploy/base` differ outside the allowlist above. A seeded difference proves that it fails, and so does a seeded change to a selector label.
- [x] A render with a non-default `--namespace` puts every resource and the RoleBinding subject in that namespace.
- [x] The resource names are `knarr`, and the Deployment's `selector.matchLabels` is exactly `app.kubernetes.io/name: knarr`. A test pins both.
- [x] `NOTES.txt` prints the namespace, the opt-in label and a pointer to the install guide, and a test checks its render.
- [x] `helm lint --strict` passes, and kubeconform `-strict` validates the render against the vendored schemas. These run in the gate environment 0015 chose.
- [x] A gate check fails when the chart's `version` or `appVersion` differs from the `gleam.toml` version, and its test seeds that difference.
- [x] `CHANGELOG.md` records the chart under Unreleased. Any new handbook page, such as a chart values reference, is registered in `docs/manifest.yml`.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Settled on 2026-10-17 (UTC).

### What changed

- New chart at `charts/knarr/`: `Chart.yaml` (`apiVersion: v2`, `version` = `appVersion` = `0.1.0`), `values.yaml` holding `deploy/base`'s local values, a types-only `values.schema.json` with `additionalProperties: false` on the top level, `image` and `knarr`, `_helpers.tpl` (Helm's recommended labels, the image by digest else tag else `appVersion`, and `ERL_FLAGS`), the ServiceAccount, Role, RoleBinding and Deployment templates, `NOTES.txt`, `.helmignore`, and a test-only `ci/every-value.yaml` that `.helmignore` keeps out of the package.
- The eighteen `-knarr` settings live under `knarr`, with keys verbatim from `application_ffi.erl` (`--set knarr.poll_interval=5` renders `-knarr poll_interval 5`). An unset setting is an absent key. `knarr.status_path` and `knarr.log_level` refuse `'`, `"` and `\`, naming the key, so a value cannot break out of its quoting in `ERL_FLAGS`.
- `podLabels` join the pod template only, never the Deployment metadata or the selector; the chart's own labels win a clash.
- New checker `scripts/checks/chart.py` (modes `lint`, `render`, `drift`, `version`), run by a new `just chart-check` recipe in `just check`, and a new `chart` group in `checker_suite.py`. The drift allowlist matches each inserted line by content and YAML context; any changed or removed line fails.
- `kubernetes-helm` 4.3.0 and `kustomize` 5.8.2 move from the cluster feature to the default environment (`pixi.toml`, `pixi.lock`). The cluster environment still includes them through the default feature.
- `.pre-commit-config.yaml`: `check-yaml` skips `charts/*/templates/`, which are Go templates, not YAML.
- `CHANGELOG.md` records the chart under Unreleased, Added. Decision 0003 carries an "Amended by Decision 0015" note on its helm bullet, and `docs/how-to/local-observability.md` now places helm in the default environment. No handbook page was added, so `docs/manifest.yml` is unchanged.

### What was verified

- `scripts/checks/tests/test_chart.py` was written first and failed at collection (`No module named 'chart'`) before the checker existed. Each review fix's test was run first and failed for the expected reason.
- `just test-checkers-selected chart deployment policy`: 195 passed, before the review fixes.
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after the review fixes and these notes.
- Not done: no cluster install of the chart (03), and no publish (04).

### Review

Codex was unavailable (the requested model was not supported on this login), so a five-lens Claude subagent review ran instead, with two to three adversarial verifiers per finding. Five findings were confirmed and fixed: the `ERL_FLAGS` quoting guard, `podLabels: null` crashing the render, `chart-check` hiding helm's stderr, the stale environment sentence in the observability how-to, and the missing amendment on Decision 0003. Ten were rejected, two of them raised for 03 and 04 below.

### What each later ticket needs

- **03:** reuse `chart.canonical(rendered, patches=())` from `scripts/checks/chart.py`. It writes `rendered` and each patch file into a temporary kustomization and returns `kustomize build`'s output as a string, so `chart.canonical(chart.render(namespace="default"), patches=[ROOT / "deploy/wrong-ca/patch.json"])` gives the wrong-ca render. `chart.render(*arguments, namespace="default")` runs `helm template knarr charts/knarr` and raises `CalledProcessError` carrying helm's stderr. The patches only line up in the namespace the patch names (`default` today), so harden that if 03 renders patches anywhere else. The release name is `knarr`. The e2e-fast values file is `knarr: {list_interval: 10, poll_interval: 5, poll_timeout: 4, patch_interval: 10}`. `--set-string podAnnotations.knarr\.dev/local-image-id=<id>` renders, and a test proves it. Add `charts/**` to the `CLUSTERS` inputs in `checker_suite.py`; 02 left the chart-only change selecting the `chart` group alone. Setting `knarr.<key>: null` to delete a setting is refused by the schema; settle the layering case if 03 needs it.
- **04:** stamp `image.repository`, `image.pullPolicy: IfNotPresent` and `image.digest` together. With a digest the render is `image: <repo>@<digest>`, which `test_the_image_is_the_digest_else_the_tag_else_app_version` pins. The published chart keeps `image.tag: local`, so a user who clears `image.digest` gets `:local`; decide whether the stamp also sets the tag. `chart.py version` holds `version` and `appVersion` to `gleam.toml`, so a release bumps all three together.
- **05:** the chart's resources keep the base's names and the selector `app.kubernetes.io/name: knarr`, so adoption over the kustomize-applied resources is possible. `NOTES.txt` links to `docs/how-to/install.md` at the `v<appVersion>` tag, so that page must exist at every published tag.
- **06:** retiring `deploy/base` also retires `chart.py drift`, its test and the `deploy/base/**` input of the `chart` group. `release-pin`, `pin-digest.sh` and the install guide still credit the cluster environment's kustomize; that stays true until they are retired.
