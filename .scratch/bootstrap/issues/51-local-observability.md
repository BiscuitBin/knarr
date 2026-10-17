# 51: Opt-in local Prometheus and Grafana for the kind cluster

**Context:** The only way to see knarr's metrics on kind is to scrape `/metrics` by hand: `just smoke` and the keda-e2e scraper both do it through a loopback port-forward. The repository has no Prometheus server and no Grafana, and nothing mentions Grafana. The maintainer wants an optional stack that collects and shows the worktree kind cluster's metrics, with one small example dashboard to build on. helm 4.3.0 is pinned in the `cluster` pixi environment ([Decision 0003](../../../docs/decisions/0003-tool-manager.md)) and nothing has used it yet ([Decision 0012](../../../docs/decisions/0012-release-and-packaging.md)).

**What to build:** Four recipes in the `[cluster]` group: `just observability-up`, `observability-down`, `observability-smoke` and `grafana`. They follow the KEDA precedent ([ticket 33](33-keda-harness-success-criterion.md)):

- Each chart `.tgz` is downloaded over https, pinned by sha256 in `fixtures/observability/stack.json`, and cached under `.cluster/observability/`.
- Each chart is rendered locally with `helm template`, with no Helm release state, and every image is pinned by a multi-arch index digest.
- The result is applied server-side with kubectl.

Prometheus scrapes knarr's pods in `default` and kube-state-metrics, with RBAC limited to the `default` namespace. Grafana provisions one Prometheus datasource and the `knarr-overview` dashboard from `fixtures/observability/dashboards/`. `grafana` opens a port-forward on a port the OS chooses. Offline tests pin the pins, the render argv, the layout, the kwok refusal and the dashboard's metric names. A how-to page explains the stack.

**Non-goals:**

- CI wiring: the stack never runs in `just check` or in any workflow.
- Alerting rules.
- Persistence.
- Any non-local cluster.
- keda-e2e integration: `scripts/checks/keda_e2e.py` is unchanged.
- Fake-worker metrics.

**Blocked by:** 29, 50

**MVP critical path:** no. It is a contributor convenience.

**Status:** done. Pull request [#46](https://github.com/steven-cutting/knarr/pull/46) is open.

- [x] **Authorization required:** Step 0 discovery downloads, which the maintainer authorized on 2026-10-16. The chart homes, versions, sha256s, rendered images, index digests, determinism and RBAC are recorded in [the evidence](../evidence/51/README.md).
- [x] `fixtures/observability/` holds the pins, both values files, the Namespace, the pod-reader ClusterRole, the dashboard, the exporter inventory and the static kustomization.
- [x] `scripts/checks/observability.py` implements `observability-up`, `observability-down`, `observability-smoke` and `grafana`. kwok refuses all four.
- [x] `scripts/checks/tests/test_observability.py` covers the pins, the render argv, the layout, the kwok refusal and the dashboard's integrity. Each test was seen failing first.
- [x] Renovate turns every pinned image off, and `test_dependency_pins.py` proves it. helm joins the "local cluster" group.
- [x] The how-to page and its registration, AGENTS.md, Decisions 0003, 0007, 0012 and 0014, `docs/DEFERRED.md` and `CHANGELOG.md` carry the change.
- [x] **Authorization required:** the live run on this worktree's kind cluster, which the maintainer authorized on 2026-10-16. It covers `observability-up`, `observability-smoke`, the dashboard with live data, `observability-down`, and a cached rerun.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."
- [x] **Authorization required:** a push and a pull request, which the maintainer authorized on 2026-10-16. The branch is pushed, and [#46](https://github.com/steven-cutting/knarr/pull/46) is open against `main`.

## Hand-back notes

Done on 2026-10-16. The maintainer authorized three things that day: the network for Step 0 and for the live run, the local branch rename to `51-local-observability`, and the four Codex reviews. They later authorized the push and pull request [#46](https://github.com/steven-cutting/knarr/pull/46). Evidence: [evidence/51](../evidence/51/README.md).

### What changed

- **`fixtures/observability/`:**
  - `stack.json` pins two charts by sha256: prometheus 29.34.0 from prometheus-community, and grafana 13.2.6 from grafana-community, the chart's new home. It also pins three multi-arch image indexes by digest.
  - The values are JSON. helm reads JSON as YAML, and the offline tests can parse it without a YAML library, which the checkers lack.
  - The Namespace, and the `knarr-observability-pod-reader` ClusterRole with get, list and watch on pods.
  - The static kustomization: no top-level namespace, a `knarr-dashboards` generator in `observability`, and the label `knarr.dev/stack: observability` on every object, selectors untouched.
  - The `knarr-overview` dashboard with 9 panels, and `exporters.json`.
- **`scripts/checks/observability.py`:**
  - `up` downloads or reuses each archive, refused on a hash mismatch and written atomically. It renders each chart with `helm template --no-hooks --namespace observability --kube-version v1.35.8`; for Prometheus it adds a values-hash pod annotation, since the server runs without its reloader.
  - It lays out `.cluster/observability/base/` and the `keda_kustomization` overlay, refuses any build that names an image that is not a pinned digest, applies server-side, and waits for each Deployment's rollout to finish.
  - `down` deletes the labelled RBAC in `default`, then the labelled cluster-scoped objects, then the namespace.
  - `smoke` polls `up` for both jobs, Grafana health, the dashboard, and knarr's `up` read through Grafana's data proxy to the `knarr-prometheus` datasource, so a broken `prometheus-server` Service fails it (Codex adversarial review, 2026-10-16).
  - `grafana` forwards to 127.0.0.1 on an OS-chosen port by default, prints the URL, and exits 0 on Ctrl-C.
- **`cluster.py`:**
  - The four actions join `KIND_ONLY`.
  - `port_forward` takes an optional `namespace`, which existing callers leave unset.
  - Its image pins are unchanged, still exactly 6.
- **The Justfile:** four `[cluster]` recipes, none of them in `check`.
- **The checker suite:** the `cluster` group owns the new test, the script and the fixtures.
- **Renovate:** the three images are `enabled: false`, and `kubernetes-helm` joins the "local cluster" group. `test_observability_moves_only_by_hand` covers both.
- **Docs:**
  - The how-to `docs/how-to/local-observability.md`, with its registration and links.
  - The network lists in AGENTS.md and CONTRIBUTING.md.
  - Amendments to Decisions 0003, 0007, 0012 and 0014. 0014 also gains the missing `keda.json` row.
  - `docs/DEFERRED.md`, `CHANGELOG.md` and the index.

### Departures from the plan

- **No top-level `namespace:` in the kustomization.** Step 0 found both charts can render namespaced RBAC, so the scrape RBAC lives in `default`, where a top-level `namespace:` would move it. The generator carries its own namespace.
- **`down` deletes by `knarr.dev/stack=observability`,** not by `app.kubernetes.io/instance in (prometheus,grafana)`, and it deletes the RBAC in `default` too.
- **The dashboard has 9 panels:** patch rate and pending count are split, after review 3.
- **The metric-name test reads an explicit inventory,** `exporters.json`, instead of allowing `erlang_vm_*` and `kube_*` by prefix. The live run showed the prefix rule letting a wrong name through.
- **The grafana chart lives at grafana-community.** The `grafana/helm-charts` index marks its last entry deprecated.

### Corrections after adversarial review

The four Codex reviews ran on gpt-6-astra, statically and without sockets.

- **Review 1 (design):**
  - Accepted:
    - turn off Grafana's pod token;
    - add a values-hash annotation, since Step 0 had wrongly claimed a checksum rolled Prometheus;
    - check the image pins structurally in the `kustomize build` output;
    - turn off plugin update checks, plugin preinstall and the news feed;
    - give `port_forward` a namespace and use Deployment container ports;
    - refuse kwok for all four actions;
    - add a stack ownership label.
  - Documented: in-cluster reachability of anonymous Grafana, as the local trust assumption.
- **Review 2 (install script and tests):**
  - Accepted:
    - atomic cache writes;
    - tests that drive `up()`, where deleting its image check fails one, checked by mutation;
    - answer parsing that survives malformed JSON;
    - an explicit exporter inventory;
    - a literal kube-version assertion;
    - RBAC deleted before the namespace in `down`.
  - Rejected: a private snapshot of the verified archive. Exploiting the race needs a same-user local process that could equally edit the script.
  - Rejected: parsing ConfigMap text in the image check, which fails closed.
- **Review 3 (dashboard and docs):**
  - Accepted:
    - refuse `__name__` matchers;
    - walk panels nested in rows;
    - refuse bare histogram names;
    - allow more dashboards than the example;
    - drop the custom All value, which leaked every Deployment in `default` into the replica panel;
    - split patch rate from pending count.
- **Review 4 (whole branch):** Accepted:
  - `up` waited on `condition=Available`, which an old replica satisfies while its replacement fails, so it now runs `kubectl rollout status` per Deployment, with a test for a failed rollout;
  - `answered_one` still raised on a `data` that is not an object, so it now returns false, with three more cases.
- **Copilot's review of #46:** Accepted: the dashboard-integrity test reads `docs/specs/observability.allium` and `src/knarr/metrics_ffi.erl`, but neither selected the `cluster` checker group in CI, so a change to either alone skipped the check. Both are now inputs of that group, with two selection cases that failed before the fix.

### What was verified

- **Offline tests:**
  - `test_observability.py`: 53 passed, the last two added after the Codex review; both failed before the datasource check. The tests over code failed against a stub module, and the tests over fixtures failed under a mutation of each fixture they guard. Each later regression test failed before its fix.
  - `test_dependency_pins.py`: passed. Its new assertions fail when the Renovate rule or the helm grouping is removed.
  - `checker_suite.py selected cluster`: 122 passed before review 3's additions.
- **The gate:** `git add -A`, then `just check` ended with "All checks passed and the worktree is unchanged."
- **The live run** is in the evidence. In summary:
  - `observability-up` from an empty cache took 48 s, and `observability-smoke` passed.
  - A rerun reused the cache and left the Grafana pod in place, and a third build was byte-identical.
  - Every image ran by its pinned digest, and the RBAC grants nothing outside `default`.
  - No Helm state exists on the cluster.
  - Every panel returned data through Grafana's datasource once the fake worker was opted in.
  - `observability-down` left nothing behind and is idempotent.
  - kwok is refused.
  - `just smoke` passed without the stack.
  - `just keda-e2e` (three rounds, seed 33) passed in 638 s with the `cluster.py` change: 5 of 9 victims busy for the baseline and 0 of 9 with knarr, and the restart and patch-rate criteria held.
- **Not verified:**
  - Nobody viewed the dashboard in a browser: the Chrome extension was not connected. The panels were checked through `/api/ds/query` instead.
  - No outbound request was blocked: the run only showed that nothing was logged. Egress was not denied.
  - The panel split and the All change from review 3 were checked offline only, and through a re-apply. See the evidence.
  - The smoke's datasource-proxy check from the Codex review is tested offline only; no live `observability-smoke` has run with it.

### What later tickets need

- **Bumping a pin:** it moves by hand, as the how-to describes. Recapture `exporters.json` whenever an exporter moves.
- **Out of scope here:** CI wiring, alerting rules, persistence and fake-worker metrics.
