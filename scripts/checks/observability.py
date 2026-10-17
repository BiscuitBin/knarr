"""Ticket 51's opt-in local Prometheus and Grafana on this worktree's kind
cluster, run by `just observability-up`, `observability-down`,
`observability-smoke` and `grafana`, and never by `just check`.

It follows the KEDA install in keda_e2e.py. Each chart .tgz that
fixtures/observability/stack.json pins by sha256 is downloaded once to
.cluster/observability/charts/ and rendered locally with `helm template`:
there is no Helm repository, dependency build or release, so the cluster
holds no Helm state. The renders sit beside the static layer under
.cluster/observability/base/, and an overlay pins every image they name to
its digest. The stack is applied server-side.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import cluster
from keda_e2e import fetch_pinned, keda_kustomization

FIXTURE = cluster.ROOT / "fixtures/observability"
NAMESPACE = "observability"
# What the static layer labels every object with, and what `down` deletes by
# outside the namespace: the scrape RBAC in default and the pod-reader role.
STACK_LABEL = "knarr.dev/stack=observability"
ACTIONS = ("observability-up", "observability-down", "observability-smoke", "grafana")
# The datasource UID the values provision and every dashboard names.
DATASOURCE = "knarr-prometheus"
DASHBOARD = "knarr-overview"
# The values key a release takes its pod annotations at, where that release's
# pod would not otherwise roll when its configuration changes: Prometheus runs
# without its config reloader.
ANNOTATED = {"prometheus": "server.podAnnotations"}
DEPLOYMENTS = ("prometheus-server", "prometheus-kube-state-metrics", "grafana")
# Seconds the smoke waits for both scrape jobs and the dashboard: two scrape
# intervals of 15 s after a pod start, with room for discovery.
SMOKE = 120


def kube_version():
    """The Kubernetes version the charts render for: the kind node's."""
    return cluster.KIND_NODE.split("@")[0].rpartition(":")[2]


def fetch_chart(state, chart):
    """The chart archive under .cluster/observability/charts/."""
    return fetch_pinned(state / NAMESPACE / "charts", chart["url"], chart["sha256"])


def render(stack, charts):
    """Each release rendered from its cached archive: no hooks, one namespace,
    the kind node's Kubernetes version and the fixture's values."""
    renders = {}
    for chart in stack["charts"]:
        release = chart["release"]
        values = FIXTURE / chart["values"]
        command = [
            "helm",
            "template",
            release,
            str(charts[release]),
            "--no-hooks",
            "--namespace",
            NAMESPACE,
            "--kube-version",
            kube_version(),
            "-f",
            str(values),
        ]
        if release in ANNOTATED:
            digest = hashlib.sha256(values.read_bytes()).hexdigest()
            key = f"{ANNOTATED[release]}.knarr\\.dev/values-sha256"
            command += ["--set-string", f"{key}={digest}"]
        renders[release] = cluster.output(*command)
    return renders


def layout(state, stack, renders):
    """Write .cluster/observability/base/, the static layer with each render
    beside it, and the overlay over it that pins the images both renders name.
    Returns the overlay's directory."""
    overlay = state / NAMESPACE
    base = overlay / "base"
    if base.exists():
        shutil.rmtree(base)
    shutil.copytree(FIXTURE, base)
    for release, text in renders.items():
        (base / f"{release}.yaml").write_text(text)
    kustomization = keda_kustomization(stack["images"], "".join(renders.values()), "base")
    (overlay / "kustomization.yaml").write_text(kustomization)
    return overlay


def check_images(built, pins):
    """Refuse a build that names an image other than a pinned digest, or that
    leaves a pin unused. kustomize writes block YAML, so an image is an
    `image:` line; any other spelling of the key is refused too."""
    pinned = {re.sub(r":[^:/@]+@", "@", pin) for pin in pins}
    lines = re.findall(r"^[ \t]*(?:-[ \t]+)?image:[ \t]*(\S+)[ \t]*$", built, re.MULTILINE)
    keys = re.findall(r"""["']?\bimage["']?[ \t]*:""", built)
    if len(keys) != len(lines):
        raise ValueError("an image in the build is not pinned: an image key outside an image line")
    if unpinned := sorted(set(lines) - pinned):
        raise ValueError(f"an image in the build is not pinned: {unpinned[0]}")
    if unused := sorted(pinned - set(lines)):
        raise ValueError(f"pinned image not in the build: {unused[0]}")


def up(state):
    stack = json.loads((FIXTURE / "stack.json").read_text())
    charts = {chart["release"]: fetch_chart(state, chart) for chart in stack["charts"]}
    overlay = layout(state, stack, render(stack, charts))
    built = cluster.output("kustomize", "build", str(overlay))
    check_images(built, stack["images"])
    cluster.run(
        "kubectl", "apply", "--server-side", "-f", "-", input=built, stdout=subprocess.DEVNULL
    )
    # A rollout, not Available: an old replica stays Available while its
    # replacement fails to start.
    for name in DEPLOYMENTS:
        cluster.run(
            "kubectl",
            "rollout",
            "status",
            f"--namespace={NAMESPACE}",
            f"deployment/{name}",
            "--timeout=300s",
        )
    versions = ", ".join(f"{chart['release']} {chart['version']}" for chart in stack["charts"])
    print(f"ok   {versions} applied to {NAMESPACE}, images pinned by digest")


def down():
    """Delete what the stack put outside its namespace, by its label, and then
    the namespace: a slow namespace deletion cannot leave the RBAC behind."""
    cluster.run(
        "kubectl",
        "delete",
        "role,rolebinding",
        "--namespace=default",
        f"--selector={STACK_LABEL}",
        "--ignore-not-found",
    )
    cluster.run(
        "kubectl",
        "delete",
        "clusterrole,clusterrolebinding",
        f"--selector={STACK_LABEL}",
        "--ignore-not-found",
    )
    cluster.run(
        "kubectl",
        "delete",
        "namespace",
        NAMESPACE,
        "--ignore-not-found",
        "--wait=true",
        "--timeout=180s",
    )


def parsed(body):
    try:
        return json.loads(body)
    except ValueError:
        return None


def answered_one(body):
    """Whether an instant query's answer holds a sample whose value is 1."""
    data = parsed(body)
    data = data.get("data") if isinstance(data, dict) else None
    result = data.get("result") if isinstance(data, dict) else None
    if not isinstance(result, list):
        return False
    return any(
        isinstance(sample, dict)
        and isinstance(sample.get("value"), list)
        and sample["value"][1:2] == ["1"]
        for sample in result
    )


def healthy(body):
    """Whether Grafana's /api/health answer reports its database ok."""
    data = parsed(body)
    return isinstance(data, dict) and data.get("database") == "ok"


def has_dashboard(body):
    """Whether a Grafana search answer lists the example dashboard's UID."""
    data = parsed(body)
    return isinstance(data, list) and any(
        isinstance(item, dict) and item.get("uid") == DASHBOARD for item in data
    )


def up_query(job):
    """The query string of an instant query for `job`'s up series."""
    return urllib.parse.urlencode({"query": f'up{{job="{job}"}}'})


def answered(url, judge):
    """Whether a loopback GET answers 200 with a body `judge` accepts."""
    status, body = cluster.http("GET", url)
    return status == 200 and judge(body)


def poll(what, check):
    deadline = time.monotonic() + SMOKE
    while not (got := check()) and time.monotonic() < deadline:
        time.sleep(1)
    if not got:
        raise RuntimeError(f"{what} within {SMOKE} s")
    print(f"ok   {what}")


def smoke(state):
    """Both scrape jobs up in Prometheus, Grafana healthy, the example
    dashboard provisioned, and knarr's series read through Grafana's
    provisioned datasource. knarr must be deployed: `just deploy`."""
    with cluster.port_forward(
        state, "deployment/prometheus-server", 9090, namespace=NAMESPACE
    ) as port:
        for job in ("knarr", "kube-state-metrics"):
            url = f"http://127.0.0.1:{port}/api/v1/query?{up_query(job)}"
            poll(
                f'Prometheus reads up{{job="{job}"}} == 1',
                lambda url=url: answered(url, answered_one),
            )
    with cluster.port_forward(state, "deployment/grafana", 3000, namespace=NAMESPACE) as port:
        health = f"http://127.0.0.1:{port}/api/health"
        poll(
            "Grafana /api/health reports its database ok",
            lambda: answered(health, healthy),
        )
        search = f"http://127.0.0.1:{port}/api/search?" + urllib.parse.urlencode(
            {"query": "", "type": "dash-db"}
        )
        poll(
            f"Grafana serves the {DASHBOARD} dashboard",
            lambda: answered(search, has_dashboard),
        )
        # Through Grafana's data proxy to the Service its datasource names: the
        # path every panel takes, which the forward to the Prometheus pod skips.
        proxied = (
            f"http://127.0.0.1:{port}/api/datasources/proxy/uid/{DATASOURCE}"
            f"/api/v1/query?{up_query('knarr')}"
        )
        poll(
            f'Grafana reads up{{job="knarr"}} == 1 through the {DATASOURCE} datasource',
            lambda: answered(proxied, answered_one),
        )


def grafana_command(port):
    """The port-forward to Grafana from loopback: on `port`, or on one the OS
    picks when it is 0, since worktree clusters run side by side."""
    return [
        "kubectl",
        "port-forward",
        "--address=127.0.0.1",
        f"--namespace={NAMESPACE}",
        "deployment/grafana",
        f"{port or ''}:3000",
    ]


def grafana(port):
    """Forward Grafana in the foreground, print its URL, and run until the
    forward ends or Ctrl-C."""
    with subprocess.Popen(
        grafana_command(port), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    ) as forward:
        try:
            for line in forward.stdout:
                print(line, end="", flush=True)
                if match := re.match(r"Forwarding from 127\.0\.0\.1:(\d+) -> 3000", line):
                    print(f"Grafana: http://127.0.0.1:{match[1]}/d/{DASHBOARD}", flush=True)
        except KeyboardInterrupt:
            # The user's stop, not a failure of the forward.
            forward.terminate()
            return 0
    return forward.returncode


def main():
    action, checkout = sys.argv[1:3]
    if action not in ACTIONS:
        raise ValueError(f"unknown observability action: {action}")
    _, _, state = cluster.environment(action, Path(checkout).resolve())
    if action == "observability-up":
        up(state)
    elif action == "observability-down":
        down()
    elif action == "observability-smoke":
        smoke(state)
    else:
        port = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        if not 0 <= port <= 65535:
            raise ValueError(f"port must be 0 to 65535, not {port}")
        return grafana(port)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"observability: {error}", file=sys.stderr)
        sys.exit(1)
