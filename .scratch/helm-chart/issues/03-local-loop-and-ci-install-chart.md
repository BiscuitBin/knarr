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

**Status:** done. Pull request [#50](https://github.com/steven-cutting/knarr/pull/50) is open. See [the hand-back notes](#hand-back-notes).

- [x] `just deploy` installs the chart with `helm upgrade --install --wait`. A second run upgrades the release in place, and `just smoke` reports ok for `/healthz`, `/readyz` and `/metrics`.
- [x] The local image id reaches the pod as the `knarr.dev/local-image-id` annotation through `podAnnotations`, so a reload of the same tag still rolls the pod.
- [x] The e2e-fast values file sets the same intervals as `deploy/e2e-fast`, and `just keda-e2e` passes with it.
- [x] The wrong-ca case applies its patch to the `helm template` output. Its rollout never completes by design, because readiness never latches, so this path does not use `--wait`. Bootstrap ticket 14's `wrong-ca.sh`, which runs `just deploy "$image" wrong-ca`, keeps working unchanged or is updated with it. The reconcile-proof workflow's negative TLS case still fails closed in the same way. Local: evidence transcripts 05 and 06. CI: `wrong-ca.sh` passed in [reconcile-proof run 39019074015](https://github.com/steven-cutting/knarr/actions/runs/39019074015).
- [x] The path filters cover the chart. `checker_suite.py` `CLUSTERS` adds it to both the `kind` and `kwok` tuples, beside `deploy/**`. `reconcile-proof.yml` adds it beside `deploy/base/**` and `deploy/wrong-ca/**`. Each workflow that deploys knarr triggers on a chart-only change, and `test_checker_suite.py` asserts that.
- [x] **Authorization required:** a push, so that cluster-smoke, keda-e2e and reconcile-proof each show a green run against the chart. The hand-back records the run URLs. Green on `f976f3f`: [CI 39019073381](https://github.com/steven-cutting/knarr/actions/runs/39019073381) (Kind smoke, Kind fake worker smoke, Kwok readiness, gate), [KEDA e2e 39019072375](https://github.com/steven-cutting/knarr/actions/runs/39019072375), [Reconcile proof 39019074015](https://github.com/steven-cutting/knarr/actions/runs/39019074015).
- [x] The [local-cluster how-to](../../../docs/how-to/local-cluster.md) and the [KEDA harness reference](../../../docs/reference/keda-e2e.md) describe the chart-based loop. `CHANGELOG.md` records the change.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Settled locally on 2026-10-17 (UTC), and on CI the same day after the branch was pushed with
the review fixes (`f976f3f`, pull request #50).

### What changed

- `scripts/checks/cluster.py`: `just deploy` runs `kind load`, then
  `helm upgrade --install knarr charts/knarr --namespace default --server-side=true --reset-values --wait --timeout 120s`.
  The image goes in as `--set-string image.repository=… image.tag=…`, because `--set` would
  read a tag such as `20261017`, `true` or `null` as a non-string, which the schema refuses or the
  chart drops (review fix). The local image ID goes in as
  `--set-string podAnnotations.knarr\.dev/local-image-id=<id>`. `e2e-fast` adds
  `--values fixtures/chart-values/e2e-fast.yaml`. The rollout wait is gone.
- `wrong-ca` renders the chart with `helm template` and applies `deploy/wrong-ca/patch.json`
  through `chart.canonical`. That function now targets a `.json` patch at its own kind and name,
  so the patch lands in any namespace, and it can mark every resource with the release's
  annotations. The result is applied with `kubectl apply --server-side --field-manager=helm`,
  with no wait. Helm 4 installs by server-side apply as manager `helm`, so the next
  `just deploy` removes the CA env and volume. A client-side apply left them in place, and the
  following upgrade then failed its `--wait`. `.scratch/bootstrap/evidence/14/wrong-ca.sh` is
  updated: the deploy no longer waits, so the script now waits for a Running pod that carries
  `KNARR_CA_FILE`.
- New `fixtures/chart-values/e2e-fast.yaml`. It sits outside the chart package, and
  `test_chart.py` holds its intervals to `deploy/e2e-fast/patch.json`. `keda_e2e.py` still calls
  `cluster.deploy(…, "e2e-fast")` and `"base"`, and only its docstrings changed. KEDA stays
  sha-pinned kustomize YAML.
- Path filters. In `checker_suite.py`, `CLUSTERS` kind gains `charts/**` and
  `scripts/checks/chart.py`, and kwok gains `charts/**`. The cluster group reads the chart and
  the values files. The chart group reads `deploy/e2e-fast/**` and `deploy/wrong-ca/**`, whose
  patches its tests read (review fix). `reconcile-proof.yml` push paths gain `charts/**` and
  `scripts/checks/chart.py`. **`keda-e2e.yml` has no path filter** (it runs on
  `workflow_dispatch` and on labelled, synchronized or reopened PRs), so nothing was added to it.
  ci.yml's cluster-smoke and cluster-kwok follow the suite's `kind` and `kwok` outputs.
- Docs: [local-cluster.md](../../../docs/how-to/local-cluster.md) describes the chart loop and
  says to recreate a kind cluster that still holds the kustomize install (adoption is 05).
  [keda-e2e.md](../../../docs/reference/keda-e2e.md) points at the values file. `CHANGELOG.md`
  has an Unreleased › Changed entry. The `Justfile` `deploy` doc names the three variants.

### What was verified

All of this ran on kind on Darwin arm64 with Helm v4.3.0. The transcripts are in
[evidence/03](../evidence/03/), with the worktree path written as `<worktree>` and trailing
blanks trimmed. `state.sh` printed the state after each step.

- [01-deploy-1.txt](../evidence/03/01-deploy-1.txt) and
  [02-deploy-2.txt](../evidence/03/02-deploy-2.txt): revision 1 installs, and revision 2
  upgrades in place with the same pod UID. [04-smoke.txt](../evidence/03/04-smoke.txt): ok for
  `/healthz`, `/readyz` and `/metrics`.
- [03-same-tag-reload.txt](../evidence/03/03-same-tag-reload.txt): a rebuilt image under the
  same tag rolls a new pod carrying the new `knarr.dev/local-image-id`.
- [07-keda-e2e.txt](../evidence/03/07-keda-e2e.txt): `just keda-e2e` with the e2e-fast values
  reports "keda-e2e: all checks passed", knarr 0 of 9 busy kills against 5 of 9 for the
  baseline.
- [05-wrong-ca-round-trip.txt](../evidence/03/05-wrong-ca-round-trip.txt): the updated
  wrong-ca.sh passes (unknown_ca on every cycle, no LIST or PATCH succeeded, pod Running and
  NotReady). Its restore leaves no `KNARR_CA_FILE` and no `wrong-ca` volume.
  [06-wrong-ca-before-install.txt](../evidence/03/06-wrong-ca-before-install.txt): wrong-ca on a
  cluster with no release, and then `just deploy` adopts the resources.
- Unit tests pin the argv of every deploy path, the patched render, the patch in another
  namespace, a numeric, boolean or `null` tag, the selection rows and the reconcile-proof push
  paths.
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change
  staged, after these notes.
- CI on linux/amd64, all green at `f976f3f`:
  - [CI 39019073381](https://github.com/steven-cutting/knarr/actions/runs/39019073381): the
    gate, Kind smoke, Kind fake worker smoke, Kwok readiness and the selected checker
    regressions.
  - [KEDA e2e 39019072375](https://github.com/steven-cutting/knarr/actions/runs/39019072375),
    dispatched: `keda-e2e.yml` has no path filter.
  - [Reconcile proof 39019074015](https://github.com/steven-cutting/knarr/actions/runs/39019074015),
    dispatched: the TLS check, reconcile and cleanup on kind, and `wrong-ca.sh` failing closed.

### Review

Codex was unavailable (the requested model was not supported on this login), so a five-lens
Claude subagent review ran instead, with two to three adversarial verifiers per finding. Five
findings were confirmed and fixed (the `--set-string` tag, the chart group's inputs, this
paperwork, the `push_paths()` helper and stale docstrings); four were rejected.

### What each later ticket needs

- **04:** nothing. The release publishes the chart that this loop installs.
- **05:** a kind cluster or a user install that holds the kustomize resources has to be
  recreated today. Adoption has to add Helm's `app.kubernetes.io/managed-by: Helm` label and
  the `meta.helm.sh/release-*` annotations. `chart.canonical(annotations=…)` shows the shape.
  Helm 4's field manager is `helm` (operation `Apply`).
- **06:** `deploy/e2e-fast` and `deploy/wrong-ca` stay only as references. The e2e-fast
  parity test and the wrong-ca patch path (`cluster.WRONG_CA`) move when `deploy/` goes, and
  the chart group's `deploy/e2e-fast/**` and `deploy/wrong-ca/**` inputs go with them.
- **Follow-ups outside this ticket:** `.scratch/bootstrap/evidence/14/wrong-ca.txt` is the
  dated record of run 37906694255 and predates the script change. Decision 0013's line "the pod
  stayed Ready" predates ticket 31's NotReady requirement.
