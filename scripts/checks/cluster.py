"""Per-worktree cluster adapters, invoked only through the Justfile."""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KIND_NODE = (
    "kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"
)
KWOK_IMAGES = {
    "kube-apiserver": "registry.k8s.io/kube-apiserver:v1.35.5@sha256:51f1971bebe13f376d648e8e42d6949a05d1f2cacbafae50245d0c58bc84997f",
    "kube-controller-manager": "registry.k8s.io/kube-controller-manager:v1.35.5@sha256:4c8d90d21b29e25486d8d33be40416de0f121f63a316ca620e9cca2ac7ec5ebd",
    "kube-scheduler": "registry.k8s.io/kube-scheduler:v1.35.5@sha256:c8e2abd96d0206ac5d863ac1f61f8bd0067e9b001ee5b1de768a68f1b9f187ff",
    "etcd": "registry.k8s.io/etcd:3.6.10-0@sha256:f65c61039e7b7fd6e651f7ec2459b880589892cb13cf79c2f71c92aa08fc5144",
    "kwok-controller": "registry.k8s.io/kwok/kwok:v0.8.0@sha256:6d25aa8fbdfe78845423160bf125b5513f9522e2770981f0945c2a250c2b26f0",
}
# The fake worker fixture (ticket 29): its manifests, its workers' label, and the
# actions that need real pods.
FAKE_WORKER = ROOT / "fixtures/fake_worker/deploy"
WORKERS = "app.kubernetes.io/name=fake-worker"
KIND_ONLY = {"deploy", "smoke", "image-load", "fake-worker-deploy", "fake-worker-smoke"}
# What the smoke sets on four workers through control, and what each one's status
# endpoint must then answer, byte for byte (worker_contract.allium). Every body
# names every member, so a second run resets what the first set.
MIXED = [
    ("idle", (0, True, "none"), (200, '{"cost":0,"accepting":true}')),
    ("busy", (1800, True, "none"), (200, '{"cost":1800,"accepting":true}')),
    ("draining", (500, False, "none"), (200, '{"cost":500,"accepting":false}')),
    ("absent", (0, True, "not_found"), (404, "not found\n")),
]
# How long the smoke repeats a request before it takes the answer as final.
ANSWER_SECONDS = 15
# How long the smoke waits for four Ready workers: a run straight after another
# starts while the replacements for the pods that run deleted still start.
WORKER_SECONDS = 120
# Loopback only: a proxy in the environment never sees the smoke's requests.
LOOPBACK = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return run(*args, capture_output=True).stdout.strip()


def eventually(command, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            return
        time.sleep(0.5)
    raise RuntimeError(f"Timed out: {command}")


def ready():
    eventually(["kubectl", "get", "nodes", "-o", "name", "--request-timeout=5s"])
    run("kubectl", "wait", "--for=condition=Ready", "node", "--all", "--timeout=180s")
    eventually(
        ["kubectl", "get", "serviceaccount", "default", "-o", "name", "--request-timeout=5s"]
    )


def smoke(state):
    with port_forward(state, "deployment/knarr", 8080) as port:
        for endpoint in ["healthz", "readyz", "metrics"]:
            body = output(
                "curl",
                "--noproxy",
                "*",
                "--fail",
                "--silent",
                "--show-error",
                "--max-time",
                "5",
                f"http://127.0.0.1:{port}/{endpoint}",
            )
            if endpoint == "metrics":
                if not re.search(r"^knarr_startups_total 1(?:\.0)?$", body, re.MULTILINE):
                    raise RuntimeError("startup counter missing or incorrect")
                if "erlang_vm_" not in body:
                    raise RuntimeError("VM collectors missing")
            elif body != "ok":
                raise RuntimeError(f"unexpected /{endpoint} response: {body!r}")
            print(f"ok /{endpoint}")


@contextlib.contextmanager
def port_forward(state, target, port):
    """Forward a loopback port to `port` on `target`, and yield it. kubectl asks
    the OS to allocate the port, avoiding a probe/bind race. Each forward logs
    to its own file under .cluster/."""
    log_path = state / f"port-forward-{re.sub(r'[^A-Za-z0-9.-]', '-', target)}-{port}.log"
    with log_path.open("w+") as log:
        forward = subprocess.Popen(
            ["kubectl", "port-forward", "--address=127.0.0.1", target, f":{port}"],
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            deadline = time.monotonic() + 30
            local = None
            while local is None and time.monotonic() < deadline and forward.poll() is None:
                log.seek(0)
                match = re.search(rf"Forwarding from 127\.0\.0\.1:(\d+) -> {port}\b", log.read())
                if match:
                    local = int(match[1])
                else:
                    time.sleep(0.1)
            if local is None:
                raise RuntimeError(f"port-forward to {target} failed; see {log_path}")
            yield local
        finally:
            forward.terminate()
            try:
                forward.wait(timeout=5)
            except subprocess.TimeoutExpired:
                forward.kill()
                forward.wait()


def http(method, url, body=None):
    """One plain-HTTP request over loopback: its status and body, errors included.
    A transport failure is status 0 with the error, for the caller to retry."""
    data = None if body is None else body.encode()
    request = urllib.request.Request(url, data=data, method=method)  # noqa: S310 - loopback http
    try:
        with LOOPBACK.open(request, timeout=5) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()
    except (urllib.error.URLError, OSError) as error:
        return 0, str(error)


def answer(method, url, body=None, *, accept, what):
    """Repeat a request for up to ANSWER_SECONDS until `accept` takes its answer: a
    fresh port-forward can drop a connection, and a worker takes a moment to see
    its own SIGTERM."""
    deadline = time.monotonic() + ANSWER_SECONDS
    while not accept(got := http(method, url, body)) and time.monotonic() < deadline:
        time.sleep(0.2)
    if not accept(got):
        raise RuntimeError(f"{what}: got {got!r}")
    return got


def exactly(wanted):
    return lambda got: got == wanted


def expect(got, wanted, what):
    if got != wanted:
        raise RuntimeError(f"{what}: wanted {wanted!r}, got {got!r}")


def ready_workers():
    """The worker pods the smoke may use: Ready and not terminating. A pod an
    earlier run deleted stays Running while it drains, so phase alone would
    pick it."""
    pods = json.loads(output("kubectl", "get", "pods", "-l", WORKERS, "-o", "json"))["items"]
    return sorted(
        pod["metadata"]["name"]
        for pod in pods
        if "deletionTimestamp" not in pod["metadata"]
        and any(
            condition.get("type") == "Ready" and condition.get("status") == "True"
            for condition in pod.get("status", {}).get("conditions", [])
        )
    )


def await_workers(count):
    deadline = time.monotonic() + WORKER_SECONDS
    while len(pods := ready_workers()) < count and time.monotonic() < deadline:
        time.sleep(1)
    if len(pods) < count:
        raise RuntimeError(f"{count} ready fake workers needed, found {len(pods)}")
    return pods[:count]


def fake_worker_smoke(state):
    """Set mixed states on four workers through control and read each back from
    its status endpoint; then delete a busy and an idle worker, read the busy one
    while it drains, and find both kill records at the collector by pod name.
    It ends with the Deployment rolled out again, so a next run finds four."""
    pods = await_workers(len(MIXED))
    with port_forward(state, "service/fake-worker-collector", 8081) as collector:
        kills = f"http://127.0.0.1:{collector}/kills"
        answer("DELETE", kills, accept=exactly((204, "")), what="clearing the collector")
        for pod, (label, (cost, accepting, failure), wanted) in zip(pods, MIXED, strict=True):
            with (
                port_forward(state, f"pod/{pod}", 8081) as control,
                port_forward(state, f"pod/{pod}", 8080) as status,
            ):
                body = json.dumps(
                    {"cost": cost, "accepting": accepting, "failure": failure, "latency_ms": 0}
                )
                url = f"http://127.0.0.1:{control}/control"
                answer("PUT", url, body, accept=lambda got: got[0] == 200, what=f"{pod} control")
                url = f"http://127.0.0.1:{status}/knarr/v1/status"
                got = answer("GET", url, accept=exactly(wanted), what=f"{pod} status")
                print(f"ok {label} {pod}: {got[0]} {got[1].strip()}")
        idle, busy = pods[0], pods[1]
        # StatusEndpoint.Served in the cluster: the busy worker answers while it drains.
        with port_forward(state, f"pod/{busy}", 8080) as status:
            run("kubectl", "delete", "pod", busy, "--wait=false")
            url = f"http://127.0.0.1:{status}/knarr/v1/status"
            draining = (200, '{"cost":1800,"accepting":false}')
            got = answer("GET", url, accept=exactly(draining), what=f"{busy} draining")
            print(f"ok draining after SIGTERM {busy}: {got[1]}")
        run("kubectl", "delete", "pod", idle, "--wait=true", "--timeout=60s")
        run("kubectl", "wait", "--for=delete", f"pod/{busy}", "--timeout=60s")
        status_code, listed = http("GET", kills)
        expect(status_code, 200, "listing kills")
        records = {record["pod"]: record for record in json.loads(listed)["kills"]}
        for pod, busy_flag, cost in [(busy, True, 1800), (idle, False, 0)]:
            wanted = {"pod": pod, "busy": busy_flag, "cost": cost, "accepting": True}
            expect(records.get(pod), wanted, f"{pod} kill record")
            print(f"ok kill record {pod}: busy={str(busy_flag).lower()}")
    run("kubectl", "rollout", "status", "deployment/fake-worker", "--timeout=120s")


def render_fake_worker(state, image):
    """Write the fake worker's manifests, pointed at the local image and marked with
    its ID so a rebuilt image rolls out, to .cluster/render/fake-worker/."""
    target = state / "render" / "fake-worker"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    data = json.loads((FAKE_WORKER / "resources.json").read_text())
    image_id = output("docker", "image", "inspect", "--format={{.Id}}", image)
    for item in data["items"]:
        if item["kind"] == "Deployment":
            template = item["spec"]["template"]
            template["spec"]["containers"][0]["image"] = image
            template["metadata"].setdefault("annotations", {})["knarr.dev/local-image-id"] = (
                image_id
            )
    (target / "resources.json").write_text(json.dumps(data))
    shutil.copyfile(FAKE_WORKER / "kustomization.yaml", target / "kustomization.yaml")
    return target


def render(state, image, variant):
    """Write the base, pointed at the local image and marked with its ID so a rebuilt
    image rolls out, to .cluster/render/base/, and a variant beside it, where its
    kustomization's `../base` resolves. Returns the directory to build."""
    render_root = state / "render"
    base = render_root / "base"
    if base.exists():
        shutil.rmtree(base)
    base.mkdir(parents=True)
    data = json.loads((ROOT / "deploy/base/resources.json").read_text())
    deployment = next(item for item in data["items"] if item["kind"] == "Deployment")
    deployment["spec"]["template"]["spec"]["containers"][0]["image"] = image
    deployment["spec"]["template"]["metadata"].setdefault("annotations", {})[
        "knarr.dev/local-image-id"
    ] = output("docker", "image", "inspect", "--format={{.Id}}", image)
    (base / "resources.json").write_text(json.dumps(data))
    shutil.copyfile(ROOT / "deploy/base/kustomization.yaml", base / "kustomization.yaml")
    if variant == "base":
        return base
    target = render_root / variant
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(ROOT / "deploy" / variant, target)
    return target


def main():
    action, checkout = sys.argv[1:3]
    checkout = Path(checkout).resolve()
    runner = os.environ.get("KNARR_CLUSTER", "kind")
    if runner not in {"kind", "kwok"}:
        raise ValueError("KNARR_CLUSTER must be kind or kwok")
    if runner != "kind" and action in KIND_ONLY:
        raise ValueError(f"{action} requires kind; kwok pods do not run containers")
    name = output("sh", str(ROOT / "scripts/cluster-name.sh"), str(checkout), "name")
    state = checkout / ".cluster"
    marker = state / "runner"
    if marker.exists() and marker.read_text().strip() != runner:
        raise ValueError(
            "run cluster-down with the previous KNARR_CLUSTER before changing runners"
        )
    if action not in {"up", "down"} and not (state / "kubeconfig").is_file():
        raise ValueError("local kubeconfig missing; run cluster-up first")
    os.environ.pop("KUBERNETES_SERVICE_HOST", None)
    os.environ.pop("KUBERNETES_SERVICE_PORT", None)
    os.environ["KUBECONFIG"] = str(state / "kubeconfig")
    os.environ["KWOK_WORKDIR"] = str(state / "kwok")
    os.environ["KWOK_KUBE_VERSION"] = "v1.35.5"
    default = "fake-worker" if action.startswith("fake-worker") else "knarr"
    image = sys.argv[3] if len(sys.argv) > 3 else f"{default}:{name}"
    variant = sys.argv[4] if len(sys.argv) > 4 else "base"
    if not (ROOT / "deploy" / variant / "kustomization.yaml").is_file():
        raise ValueError(f"unknown deployment variant: {variant}")
    if action == "down":
        run(
            "kind" if runner == "kind" else "kwokctl",
            "delete",
            "cluster",
            "--name",
            name,
            "--kubeconfig",
            os.environ["KUBECONFIG"],
        )
        if state.exists():
            shutil.rmtree(state)
    elif action == "up":
        state.mkdir(exist_ok=True, mode=0o700)
        marker.write_text(runner)
        if runner == "kind":
            existing = output("kind", "get", "clusters").splitlines()
            if name not in existing:
                run(
                    "kind",
                    "create",
                    "cluster",
                    "--name",
                    name,
                    "--image",
                    KIND_NODE,
                    "--kubeconfig",
                    os.environ["KUBECONFIG"],
                    "--wait",
                    "180s",
                )
            else:
                run(
                    "kind",
                    "export",
                    "kubeconfig",
                    "--name",
                    name,
                    "--kubeconfig",
                    os.environ["KUBECONFIG"],
                )
        else:
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = str(sock.getsockname()[1])
            images = [
                argument
                for key, value in KWOK_IMAGES.items()
                for argument in (f"--{key}-image", value)
            ]
            run(
                "kwokctl",
                "create",
                "cluster",
                "--name",
                name,
                "--runtime",
                "docker",
                "--kubeconfig",
                os.environ["KUBECONFIG"],
                "--kube-apiserver-port",
                port,
                "--wait",
                "180s",
                *images,
            )
            run("kwokctl", "scale", "node", "--name", name, "--replicas", "1")
        ready()
    elif action == "ready":
        ready()
    elif action == "image-load":
        run("kind", "load", "docker-image", image, "--name", name)
    elif action == "deploy":
        run("kind", "load", "docker-image", image, "--name", name)
        rendered = output("kustomize", "build", str(render(state, image, variant)))
        run("kubectl", "apply", "-f", "-", input=rendered)
        run("kubectl", "rollout", "status", "deployment/knarr", "--timeout=120s")
    elif action == "smoke":
        smoke(state)
    elif action == "fake-worker-deploy":
        run("kind", "load", "docker-image", image, "--name", name)
        rendered = output("kustomize", "build", str(render_fake_worker(state, image)))
        run("kubectl", "apply", "-f", "-", input=rendered)
        # Workers reach the collector by its Service name, so DNS must answer.
        run(
            "kubectl",
            "rollout",
            "status",
            "--namespace=kube-system",
            "deployment/coredns",
            "--timeout=120s",
        )
        for deployment in ("fake-worker-collector", "fake-worker"):
            run("kubectl", "rollout", "status", f"deployment/{deployment}", "--timeout=120s")
    elif action == "fake-worker-smoke":
        fake_worker_smoke(state)
    elif action == "diagnostics":
        for args in [
            ("get", "pods", "-o", "wide"),
            ("describe", "deployment/knarr"),
            ("describe", "pods", "-l", "app.kubernetes.io/name=knarr"),
            ("logs", "deployment/knarr", "--all-containers", "--tail=100"),
            ("logs", "deployment/knarr", "--all-containers", "--previous", "--tail=100"),
            ("describe", "pods", "-l", "app.kubernetes.io/part-of=knarr-fixtures"),
            ("logs", "-l", "app.kubernetes.io/part-of=knarr-fixtures", "--tail=100"),
            ("get", "events", "--sort-by=.lastTimestamp"),
        ]:
            subprocess.run(["kubectl", *args], check=False)
    else:
        raise ValueError(f"unknown cluster action: {action}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"cluster: {error}", file=sys.stderr)
        sys.exit(1)
