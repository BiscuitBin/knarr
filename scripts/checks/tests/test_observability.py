"""The opt-in local Prometheus and Grafana stack (ticket 51): its pins, its render,
its layout, its teardown and its example dashboard, all offline.

The live run is `just observability-up` and `just observability-smoke` on kind,
which never runs in `just check`; these pin what the adapter downloads, how it
renders the charts, what it lays out for kustomize, what it deletes, and that
the dashboard queries only metrics something actually exports.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import re
import urllib.parse
from collections.abc import Iterator
from pathlib import Path
from typing import Self

import pytest

import cluster
import keda_e2e
import observability
from conftest import REPOSITORY

FIXTURE = REPOSITORY / "fixtures/observability"
STACK = json.loads((FIXTURE / "stack.json").read_text())
DASHBOARDS = sorted((FIXTURE / "dashboards").glob("*.json"))
# The image lines both charts render at the pinned versions with the values,
# verbatim, quotes and registry prefixes included (ticket 51's Step 0); only
# the indentation differs, which the pin pattern ignores.
RENDERED = """\
        image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0
            image: "quay.io/prometheus/prometheus:v3.15.0"
---
            image: "docker.io/grafana/grafana:13.2.2-distroless"
"""


def test_a_download_whose_hash_differs_from_the_pin_is_refused(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    chart = dict(STACK["charts"][0], sha256=hashlib.sha256(b"pinned").hexdigest())
    monkeypatch.setattr(
        observability.urllib.request, "urlopen", lambda *_, **__: io.BytesIO(b"other")
    )
    with pytest.raises(ValueError, match="sha256 mismatch"):
        observability.fetch_chart(tmp_path, chart)
    assert not list(tmp_path.rglob("*.tgz"))


def test_a_cached_chart_is_reused_only_while_its_hash_matches(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    body = b"chart bytes"
    chart = dict(STACK["charts"][0], sha256=hashlib.sha256(body).hexdigest())
    fetched = []

    def urlopen(url: str, **_: object) -> io.BytesIO:
        fetched.append(url)
        return io.BytesIO(body)

    monkeypatch.setattr(observability.urllib.request, "urlopen", urlopen)
    path = observability.fetch_chart(tmp_path, chart)
    assert path.read_bytes() == body
    assert observability.fetch_chart(tmp_path, chart) == path
    assert fetched == [chart["url"]]
    path.write_bytes(b"tampered")
    assert observability.fetch_chart(tmp_path, chart).read_bytes() == body
    assert fetched == [chart["url"], chart["url"]]


def test_a_chart_url_that_is_not_https_is_refused(tmp_path: Path) -> None:
    chart = dict(STACK["charts"][0], url="http://example.invalid/prometheus-1.0.0.tgz")
    with pytest.raises(ValueError, match="not https"):
        observability.fetch_chart(tmp_path, chart)


def test_the_stack_pins_two_charts_and_every_image_by_digest() -> None:
    assert [chart["release"] for chart in STACK["charts"]] == ["prometheus", "grafana"]
    for chart in STACK["charts"]:
        assert chart["url"].startswith("https://"), chart
        assert chart["url"].endswith(f"/{chart['release']}-{chart['version']}.tgz"), chart
        assert re.fullmatch(r"[0-9a-f]{64}", chart["sha256"]), chart
        assert (FIXTURE / chart["values"]).is_file(), chart
    assert STACK["images"]
    for image in STACK["images"]:
        name, _, digest = image.partition("@")
        assert "/" in name.rpartition(":")[0], image
        assert re.fullmatch(r"sha256:[0-9a-f]{64}", digest), image


def test_every_image_the_charts_render_is_pinned_and_every_pin_is_used() -> None:
    kustomization = keda_e2e.keda_kustomization(STACK["images"], RENDERED, "base")
    assert kustomization.count("    digest: sha256:") == 3
    with pytest.raises(ValueError, match="unpinned image"):
        keda_e2e.keda_kustomization(
            STACK["images"], RENDERED + "        image: quay.io/x/sidecar:1.0\n", "base"
        )


def test_each_chart_renders_from_its_cached_archive_with_no_hooks_into_one_namespace(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    commands: list[tuple[str, ...]] = []

    def output(*args: str) -> str:
        commands.append(args)
        return f"# rendered {args[2]}\n"

    charts = {chart["release"]: tmp_path / f"{chart['release']}.tgz" for chart in STACK["charts"]}
    monkeypatch.setattr(cluster, "output", output)
    renders = observability.render(STACK, charts)
    assert renders == {release: f"# rendered {release}\n" for release in charts}
    assert [command[:4] for command in commands] == [
        ("helm", "template", release, str(path)) for release, path in charts.items()
    ]
    for command in commands:
        release = command[2]
        values = FIXTURE / f"{release}-values.json"
        assert "--no-hooks" in command
        assert command[command.index("--namespace") + 1] == "observability"
        assert command[command.index("--kube-version") + 1] == "v1.35.8"
        assert command[command.index("-f") + 1] == str(values)
        assert not {"repo", "dependency", "install", "upgrade", "pull"} & set(command)
    # A changed scrape configuration rolls the server, which has no reloader.
    prometheus = commands[0]
    digest = hashlib.sha256((FIXTURE / "prometheus-values.json").read_bytes()).hexdigest()
    assert prometheus[prometheus.index("--set-string") + 1] == (
        f"server.podAnnotations.knarr\\.dev/values-sha256={digest}"
    )
    assert "--set-string" not in commands[1]


def test_the_kube_version_is_the_kind_nodes() -> None:
    assert cluster.KIND_NODE.startswith("kindest/node:v1.35.8@")
    assert observability.kube_version() == "v1.35.8"


def test_the_layout_puts_the_renders_beside_the_static_layer_under_one_overlay(
    tmp_path: Path,
) -> None:
    renders = {
        "prometheus": "        image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0\n"
        '          image: "quay.io/prometheus/prometheus:v3.15.0"\n',
        "grafana": '          image: "docker.io/grafana/grafana:13.2.2-distroless"\n',
    }
    overlay = observability.layout(tmp_path, STACK, renders)
    assert overlay == tmp_path / "observability"
    base = overlay / "base"
    assert (base / "prometheus.yaml").read_text() == renders["prometheus"]
    assert (base / "grafana.yaml").read_text() == renders["grafana"]
    for path in FIXTURE.rglob("*"):
        if path.is_file():
            relative = path.relative_to(FIXTURE)
            assert (base / relative).read_bytes() == path.read_bytes(), relative
    text = (overlay / "kustomization.yaml").read_text()
    assert re.findall(r"^resources:\n((?:  - .*\n)+)", text, re.MULTILINE) == ["  - base\n"]
    assert text.count("    digest: sha256:") == len(STACK["images"])
    # A second layout replaces the first rather than mixing with it.
    (base / "stale.yaml").write_text("stale")
    observability.layout(tmp_path, STACK, renders)
    assert not (base / "stale.yaml").exists()


def test_the_static_layer_keeps_its_rbac_in_default_and_its_dashboards_in_observability() -> None:
    text = (FIXTURE / "kustomization.yaml").read_text()
    # A top-level namespace would move the RoleBindings out of default.
    assert not re.search(r"^namespace:", text, re.MULTILINE)
    assert re.findall(r"^  - (\S+)$", text.split("configMapGenerator:")[0], re.MULTILINE) == [
        "namespace.json",
        "pod-reader.json",
        "prometheus.yaml",
        "grafana.yaml",
    ]
    generator = text.split("configMapGenerator:")[1]
    assert "  - name: knarr-dashboards\n    namespace: observability\n" in generator
    assert "disableNameSuffixHash: true" in generator
    listed = re.findall(r"^      - (dashboards/\S+)$", generator, re.MULTILINE)
    assert listed == [f"dashboards/{path.name}" for path in DASHBOARDS]
    assert "knarr.dev/stack: observability" in text
    assert "includeSelectors: false" in text


def test_the_shipped_cluster_role_reads_pods_and_nothing_else() -> None:
    role = json.loads((FIXTURE / "pod-reader.json").read_text())
    assert role["kind"] == "ClusterRole"
    prometheus = json.loads((FIXTURE / "prometheus-values.json").read_text())
    assert role["metadata"]["name"] == prometheus["server"]["useExistingClusterRoleName"]
    assert role["rules"] == [
        {"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list", "watch"]}
    ]


def test_prometheus_scrapes_knarr_and_kube_state_metrics_and_nothing_else() -> None:
    values = json.loads((FIXTURE / "prometheus-values.json").read_text())
    assert values["scrapeConfigs"] is None
    for off in ("alertmanager", "prometheus-node-exporter", "prometheus-pushgateway"):
        assert values[off] == {"enabled": False}, off
    assert values["configmapReload"]["prometheus"]["enabled"] is False
    assert values["server"]["namespaces"] == ["default"]
    assert values["server"]["persistentVolume"]["enabled"] is False
    ksm = values["kube-state-metrics"]
    assert (ksm["namespaces"], ksm["rbac"]["useClusterRole"]) == ("default", False)
    jobs = values["serverFiles"]["prometheus.yml"]["scrape_configs"]
    assert [job["job_name"] for job in jobs] == ["knarr", "kube-state-metrics"]
    knarr, state_metrics = jobs
    assert knarr["kubernetes_sd_configs"] == [
        {"role": "pod", "namespaces": {"names": ["default"]}}
    ]
    keep = {
        rule["source_labels"][0]: rule["regex"]
        for rule in knarr["relabel_configs"]
        if rule.get("action") == "keep"
    }
    assert keep == {
        "__meta_kubernetes_pod_label_app_kubernetes_io_name": "knarr",
        "__meta_kubernetes_pod_container_port_name": "http",
    }
    targets = {rule["target_label"] for rule in knarr["relabel_configs"] if "target_label" in rule}
    assert targets == {"namespace", "pod"}
    assert state_metrics["static_configs"] == [
        {"targets": ["prometheus-kube-state-metrics.observability.svc:8080"]}
    ]


def test_the_knarr_pod_carries_the_label_and_port_the_scrape_keeps() -> None:
    resources = json.loads((REPOSITORY / "deploy/base/resources.json").read_text())
    deployment = next(item for item in resources["items"] if item["kind"] == "Deployment")
    template = deployment["spec"]["template"]
    assert template["metadata"]["labels"]["app.kubernetes.io/name"] == "knarr"
    ports = [port for c in template["spec"]["containers"] for port in c.get("ports", [])]
    assert [port["name"] for port in ports] == ["http"]


def test_grafana_is_local_only_and_calls_neither_home_nor_the_api() -> None:
    values = json.loads((FIXTURE / "grafana-values.json").read_text())
    assert values["automountServiceAccountToken"] is False
    assert values["rbac"] == {"create": False}
    for off in ("testFramework", "initChownData", "persistence"):
        assert values[off]["enabled"] is False, off
    assert {key: part["enabled"] for key, part in values["sidecar"].items()} == dict.fromkeys(
        ("alerts", "dashboards", "datasources", "notifiers", "plugins"), False
    )
    ini = values["grafana.ini"]
    assert ini["analytics"] == {
        "check_for_updates": False,
        "check_for_plugin_updates": False,
        "reporting_enabled": False,
    }
    assert ini["plugins"]["preinstall_disabled"] is True
    assert ini["auth.anonymous"] == {"enabled": True, "org_role": "Viewer"}
    (datasource,) = values["datasources"]["datasources.yaml"]["datasources"]
    assert datasource["uid"] == observability.DATASOURCE
    assert datasource["url"] == "http://prometheus-server.observability.svc:80"
    assert values["dashboardsConfigMaps"] == {"knarr": "knarr-dashboards"}


def test_the_built_stack_names_only_pinned_images() -> None:
    # kustomize drops the tag where it sets a digest.
    built = "".join(
        f"        image: {re.sub(r':[^:/@]+@', '@', image)}\n" for image in STACK["images"]
    )
    observability.check_images(built + "        imagePullPolicy: IfNotPresent\n", STACK["images"])
    with pytest.raises(ValueError, match="not pinned"):
        observability.check_images(
            built + "        image: quay.io/x/sidecar:1.0\n", STACK["images"]
        )
    with pytest.raises(ValueError, match="not pinned"):
        observability.check_images(
            built + '        - {"image": "quay.io/x/sidecar:1.0"}\n', STACK["images"]
        )
    with pytest.raises(ValueError, match="not in the build"):
        observability.check_images(built.split("\n", 1)[1], STACK["images"])


@pytest.mark.parametrize("action", observability.ACTIONS)
def test_every_action_refuses_kwok(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, action: str
) -> None:
    # Before it names the cluster or touches a kubeconfig.
    monkeypatch.setenv("KNARR_CLUSTER", "kwok")
    with pytest.raises(ValueError, match=f"{action} requires kind"):
        cluster.environment(action, tmp_path)


def test_down_deletes_the_labelled_rbac_outside_the_namespace_and_then_the_namespace(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    commands: list[tuple[str, ...]] = []
    monkeypatch.setattr(cluster, "run", lambda *args, **_: commands.append(args))
    observability.down()
    assert commands == [
        (
            "kubectl",
            "delete",
            "role,rolebinding",
            "--namespace=default",
            "--selector=knarr.dev/stack=observability",
            "--ignore-not-found",
        ),
        (
            "kubectl",
            "delete",
            "clusterrole,clusterrolebinding",
            "--selector=knarr.dev/stack=observability",
            "--ignore-not-found",
        ),
        (
            "kubectl",
            "delete",
            "namespace",
            "observability",
            "--ignore-not-found",
            "--wait=true",
            "--timeout=180s",
        ),
    ]


@pytest.mark.parametrize(
    ("body", "up"),
    [
        ('{"status":"success","data":{"result":[{"value":[1,"1"]}]}}', True),
        ('{"status":"success","data":{"result":[{"value":[1,"0"]}]}}', False),
        ('{"status":"success","data":{"result":[]}}', False),
        ("not json", False),
        ('{"data":{"result":[{"value":[]}]}}', False),
        ('{"data":{"result":{"value":[1,"1"]}}}', False),
        ("[]", False),
        ('{"data":null}', False),
        ('{"data":[]}', False),
        ('{"data":0}', False),
    ],
)
def test_a_job_is_up_only_when_prometheus_answers_one(body: str, up: bool) -> None:
    assert observability.answered_one(body) is up


@pytest.mark.parametrize(
    ("body", "healthy"),
    [('{"database":"ok"}', True), ('{"database":"failing"}', False), ("[1]", False), ("x", False)],
)
def test_grafana_is_healthy_only_when_its_database_is_ok(body: str, healthy: bool) -> None:
    assert observability.healthy(body) is healthy


@pytest.mark.parametrize(
    ("body", "found"),
    [
        ('[{"uid":"knarr-overview"}]', True),
        ('[{"uid":"other"}]', False),
        ('{"uid":"knarr-overview"}', False),
        ('["knarr-overview"]', False),
        ("x", False),
    ],
)
def test_the_search_finds_the_dashboard_only_by_its_uid(body: str, found: bool) -> None:
    assert observability.has_dashboard(body) is found


def fake_up(monkeypatch: pytest.MonkeyPatch, built: str) -> list[tuple]:
    """Run up() with every effect replaced: the charts, the renders and the
    build are canned, and each kubectl call is recorded with its input."""
    commands: list[tuple] = []

    def output(*args: str) -> str:
        if args[:2] == ("kustomize", "build"):
            return built
        return RENDERED if args[2] == "prometheus" else ""

    monkeypatch.setattr(observability, "fetch_chart", lambda *_: Path("chart.tgz"))
    monkeypatch.setattr(cluster, "output", output)
    monkeypatch.setattr(
        cluster, "run", lambda *args, **kwargs: commands.append((args, kwargs.get("input")))
    )
    return commands


def pinned_build() -> str:
    return "".join(
        f"        image: {re.sub(r':[^:/@]+@', '@', image)}\n" for image in STACK["images"]
    )


def test_up_applies_exactly_the_checked_build_and_then_waits_for_each_rollout(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    built = pinned_build()
    commands = fake_up(monkeypatch, built)
    observability.up(tmp_path)
    (apply, given), *rollouts = commands
    assert apply == ("kubectl", "apply", "--server-side", "-f", "-")
    assert given == built
    # A rollout, not Available: an old replica stays Available while its
    # replacement fails to start.
    assert [command for command, _ in rollouts] == [
        (
            "kubectl",
            "rollout",
            "status",
            "--namespace=observability",
            f"deployment/{name}",
            "--timeout=300s",
        )
        for name in observability.DEPLOYMENTS
    ]


def test_up_fails_when_a_rollout_does_not_finish(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    fake_up(monkeypatch, pinned_build())
    recorded = cluster.run

    def run(*args: str, **kwargs: object) -> None:
        recorded(*args, **kwargs)
        if args[1:3] == ("rollout", "status"):
            raise observability.subprocess.CalledProcessError(1, args)

    monkeypatch.setattr(cluster, "run", run)
    with pytest.raises(observability.subprocess.CalledProcessError):
        observability.up(tmp_path)


def test_up_applies_nothing_when_the_build_names_an_unpinned_image(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    commands = fake_up(monkeypatch, pinned_build() + "        image: quay.io/x/sidecar:1.0\n")
    with pytest.raises(ValueError, match="not pinned"):
        observability.up(tmp_path)
    assert commands == []


UP = '{"status":"success","data":{"result":[{"value":[1,"1"]}]}}'


def fake_smoke(monkeypatch: pytest.MonkeyPatch, answers: dict[str, str]) -> list[str]:
    """Run smoke() with no wait, each forward on a port named for its target,
    and each GET answered 200 with the first body whose path prefix it starts
    with, or 404. Returns the paths asked, in order."""
    asked: list[str] = []
    ports = {"deployment/prometheus-server": 9090, "deployment/grafana": 3000}

    @contextlib.contextmanager
    def port_forward(_state: Path, target: str, _port: int, namespace: str) -> Iterator[int]:
        assert namespace == "observability"
        yield ports[target]

    def http(method: str, url: str) -> tuple[int, str]:
        assert method == "GET"
        path = url.removeprefix("http://127.0.0.1:")
        asked.append(path)
        return next(
            ((200, body) for prefix, body in answers.items() if path.startswith(prefix)), (404, "")
        )

    monkeypatch.setattr(observability, "SMOKE", 0)
    monkeypatch.setattr(cluster, "port_forward", port_forward)
    monkeypatch.setattr(cluster, "http", http)
    return asked


HEALTHY_GRAFANA = {
    "9090/api/v1/query?": UP,
    "3000/api/health": '{"database":"ok"}',
    "3000/api/search?": '[{"uid":"knarr-overview"}]',
}
THROUGH_GRAFANA = "3000/api/datasources/proxy/uid/knarr-prometheus/api/v1/query?"


def test_the_smoke_reads_knarr_through_grafanas_provisioned_datasource(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    asked = fake_smoke(monkeypatch, {**HEALTHY_GRAFANA, THROUGH_GRAFANA: UP})
    observability.smoke(tmp_path)
    query = "query=" + urllib.parse.quote_plus('up{job="knarr"}')
    assert asked[-1] == THROUGH_GRAFANA + query


def test_the_smoke_fails_when_grafana_cannot_reach_prometheus_through_its_datasource(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Prometheus answers on its own pod and Grafana is healthy with the
    # dashboard, but the Service the datasource names does not route.
    fake_smoke(monkeypatch, HEALTHY_GRAFANA)
    with pytest.raises(RuntimeError, match="knarr-prometheus datasource"):
        observability.smoke(tmp_path)


def test_grafana_forwards_from_loopback_on_the_port_asked_or_one_the_os_picks() -> None:
    assert observability.grafana_command(0) == [
        "kubectl",
        "port-forward",
        "--address=127.0.0.1",
        "--namespace=observability",
        "deployment/grafana",
        ":3000",
    ]
    assert observability.grafana_command(3001)[-1] == "3001:3000"


# PromQL words that are not metric names.
PROMQL = {
    "by",
    "without",
    "on",
    "ignoring",
    "group_left",
    "group_right",
    "offset",
    "bool",
    "and",
    "or",
    "unless",
    "inf",
    "nan",
}


def queries(dashboard: dict) -> list[str]:
    """Every PromQL expression in a dashboard: the targets of its panels and
    of the panels inside its rows, and the templating variables' queries."""
    found = []
    panels = list(dashboard["panels"])
    while panels:
        panel = panels.pop(0)
        found += [target["expr"] for target in panel.get("targets", []) if "expr" in target]
        panels += panel.get("panels", [])
    for variable in dashboard.get("templating", {}).get("list", []):
        query = variable.get("query")
        query = query.get("query") if isinstance(query, dict) else query
        if variable.get("type") == "query" and query:
            found.append(query)
    return found


def metric_names(expression: str) -> set[str]:
    """The metric names an expression reads: what is left once strings, label
    matchers, grouping clauses, ranges, variables and function calls are gone.
    A `__name__` matcher would hide a name inside a selector, so it is refused."""
    if "__name__" in expression:
        raise ValueError(f"a __name__ matcher is not read: {expression}")
    text = re.sub(r'"(?:[^"\\]|\\.)*"', "", expression)
    text = re.sub(r"\{[^}]*\}", "", text)
    text = re.sub(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", "", text)
    text = re.sub(r"\[[^\]]*\]", "", text)
    text = re.sub(r"\$\{?\w+\}?", "", text)
    # label_values(metric, label): the label is no metric.
    text = re.sub(r"\blabel_values\s*\(\s*(\w+)\s*,\s*\w+\s*\)", r"\1", text)
    text = re.sub(r"\b[a-zA-Z_]\w*\s*\(", "(", text)
    return {
        word for word in re.findall(r"\b[a-zA-Z_:][\w:]*\b", text) if word.lower() not in PROMQL
    }


def exported() -> tuple[set[str], set[str]]:
    """knarr's metric names, from the specification and cross-checked against
    the collector's declarations, and the histograms among them."""
    spec = (REPOSITORY / "docs/specs/observability.allium").read_text()
    names = set(re.findall(r"\bknarr_[a-z0-9_]+\b", spec))
    declared = (REPOSITORY / "src/knarr/metrics_ffi.erl").read_text()
    pattern = r"\{(counter|gauge|histogram), (knarr_[a-z0-9_]+)"
    kinds = {name: kind for kind, name in re.findall(pattern, declared)}
    assert names == kinds.keys()
    return names, {name for name, kind in kinds.items() if kind == "histogram"}


def allowed(name: str, names: set[str], histograms: set[str]) -> bool:
    for suffix in ("_bucket", "_sum", "_count"):
        if name.endswith(suffix) and name.removesuffix(suffix) in histograms:
            return True
    exporters = json.loads((FIXTURE / "exporters.json").read_text())
    return (
        name in names - histograms
        or name in exporters["erlang_vm"]
        or name in exporters["kube-state-metrics"]
        or name == "up"
    )


def test_the_metric_name_reading_skips_functions_labels_and_variables() -> None:
    assert metric_names(
        "histogram_quantile(0.95, sum by (le) (rate(knarr_poll_duration_seconds_bucket"
        '{deployment=~"$deployment"}[$__rate_interval])))'
    ) == {"knarr_poll_duration_seconds_bucket"}
    assert metric_names("label_values(knarr_pods, deployment)") == {"knarr_pods"}
    assert metric_names("time() - knarr_last_discovery_timestamp_seconds") == {
        "knarr_last_discovery_timestamp_seconds"
    }
    names, histograms = exported()
    assert allowed("knarr_poll_duration_seconds_bucket", names, histograms)
    assert not allowed("knarr_pods_bucket", names, histograms)
    assert not allowed("knarr_pod", names, histograms)
    assert allowed("erlang_vm_memory_bytes", names, histograms)
    assert not allowed("erlang_vm_memory_bytes_total", names, histograms)
    assert not allowed("kube_deployment_nonexistent", names, histograms)
    # A histogram exports only its suffixed series.
    assert not allowed("knarr_poll_duration_seconds", names, histograms)


def test_a_name_matcher_is_refused_rather_than_read_past() -> None:
    with pytest.raises(ValueError, match="__name__"):
        metric_names('knarr_pods + {__name__="knarr_typo"}')


def test_the_queries_include_panels_nested_in_rows() -> None:
    dashboard = {
        "panels": [
            {"targets": [{"expr": "up"}]},
            {"type": "row", "panels": [{"targets": [{"expr": "knarr_typo"}]}]},
        ]
    }
    assert queries(dashboard) == ["up", "knarr_typo"]


def test_the_exporter_inventory_is_what_the_pinned_exporters_name() -> None:
    exporters = json.loads((FIXTURE / "exporters.json").read_text())
    assert all(name.startswith("erlang_vm_") for name in exporters["erlang_vm"])
    assert all(name.startswith("kube_") for name in exporters["kube-state-metrics"])
    # Only the collectors the values enable.
    collectors = json.loads((FIXTURE / "prometheus-values.json").read_text())[
        "kube-state-metrics"
    ]["collectors"]
    families = {name.split("_")[1] for name in exporters["kube-state-metrics"]}
    assert families == {collector.removesuffix("s") for collector in collectors}


def test_there_is_an_example_dashboard() -> None:
    assert "knarr-overview.json" in [path.name for path in DASHBOARDS]


@pytest.mark.parametrize("path", DASHBOARDS, ids=lambda path: path.name)
def test_every_dashboard_reads_the_provisioned_datasource_and_exported_metrics(
    path: Path,
) -> None:
    dashboard = json.loads(path.read_text())
    assert dashboard["uid"] == path.stem
    assert dashboard["title"]
    assert dashboard["panels"]
    datasources = []

    def collect(value: object) -> None:
        if isinstance(value, dict):
            if "datasource" in value:
                datasources.append(value["datasource"])
            for item in value.values():
                collect(item)
        elif isinstance(value, list):
            for item in value:
                collect(item)

    collect(dashboard)
    assert datasources
    for datasource in datasources:
        assert datasource == {"type": "prometheus", "uid": observability.DATASOURCE}, datasource
    names, histograms = exported()
    expressions = queries(dashboard)
    assert expressions
    for expression in expressions:
        read = metric_names(expression)
        assert read, expression
        assert {name for name in read if not allowed(name, names, histograms)} == set(), expression


class Forward:
    """A stand-in for the kubectl port-forward: its output lines, then a
    Ctrl-C or an exit of its own."""

    def __init__(self, interrupted: bool, returncode: int) -> None:
        self.interrupted, self.returncode, self.terminated = interrupted, returncode, False

    def lines(self):
        yield "Forwarding from 127.0.0.1:43123 -> 3000\n"
        if self.interrupted:
            raise KeyboardInterrupt

    def __enter__(self) -> Self:
        self.stdout = self.lines()
        return self

    def __exit__(self, *_: object) -> None:
        if self.terminated:
            self.returncode = -15

    def terminate(self) -> None:
        self.terminated = True


@pytest.mark.parametrize(
    ("interrupted", "returncode", "status"), [(True, 0, 0), (False, 1, 1), (False, 0, 0)]
)
def test_grafana_prints_its_url_and_a_ctrl_c_is_a_clean_stop(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    interrupted: bool,
    returncode: int,
    status: int,
) -> None:
    forward = Forward(interrupted, returncode)
    monkeypatch.setattr(observability.subprocess, "Popen", lambda *_, **__: forward)
    assert observability.grafana(0) == status
    assert forward.terminated is interrupted
    assert "Grafana: http://127.0.0.1:43123/d/knarr-overview\n" in capsys.readouterr().out
