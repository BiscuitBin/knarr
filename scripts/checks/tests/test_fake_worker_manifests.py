"""The fake worker's kind manifests (ticket 29), independent of a running cluster."""

import json
import os
import subprocess
import sys

from conftest import REPOSITORY

FIXTURE = REPOSITORY / "fixtures/fake_worker/deploy"


def items() -> dict[tuple[str, str], dict]:
    data = json.loads((FIXTURE / "resources.json").read_text())
    return {(item["kind"], item["metadata"]["name"]): item for item in data["items"]}


def container(name: str) -> dict:
    return items()["Deployment", name]["spec"]["template"]["spec"]["containers"][0]


def env(name: str) -> dict[str, dict]:
    return {variable["name"]: variable for variable in container(name)["env"]}


def test_workers_and_their_collector():
    assert set(items()) == {
        ("Deployment", "fake-worker"),
        ("Deployment", "fake-worker-collector"),
        ("Service", "fake-worker-collector"),
    }
    assert items()["Deployment", "fake-worker"]["spec"]["replicas"] >= 4
    assert items()["Deployment", "fake-worker-collector"]["spec"]["replicas"] == 1
    assert env("fake-worker-collector")["FAKE_WORKER_MODE"]["value"] == "collector"


def test_pods_run_restricted_from_the_loaded_image():
    for name in ("fake-worker", "fake-worker-collector"):
        pod = items()["Deployment", name]["spec"]["template"]["spec"]
        assert pod["automountServiceAccountToken"] is False
        assert pod["securityContext"]["runAsNonRoot"] is True
        assert pod["securityContext"]["runAsUser"] == 10001
        security = pod["containers"][0]["securityContext"]
        assert security["readOnlyRootFilesystem"] is True
        assert security["allowPrivilegeEscalation"] is False
        assert security["capabilities"]["drop"] == ["ALL"]
        assert pod["containers"][0]["imagePullPolicy"] == "Never"


def test_the_contract_port_and_a_separate_control_port():
    ports = {port["name"]: port["containerPort"] for port in container("fake-worker")["ports"]}
    # worker_contract.allium, config.status_port.
    assert ports == {"status": 8080, "control": 8081}


def test_probes_never_read_the_status_endpoint():
    # A failure mode on the status endpoint must not make the pod NotReady,
    # which would change its rank on scale-down (the readiness guidance).
    for name in ("fake-worker", "fake-worker-collector"):
        for probe in ("readinessProbe", "livenessProbe"):
            assert container(name)[probe]["httpGet"] == {"path": "/healthz", "port": "control"}


def test_the_grace_period_outlasts_the_drain():
    pod = items()["Deployment", "fake-worker"]["spec"]["template"]["spec"]
    drain = int(env("fake-worker")["FAKE_WORKER_DRAIN_SECONDS"]["value"])
    assert pod["terminationGracePeriodSeconds"] >= drain + 10


def test_workers_name_themselves_and_reach_the_collector():
    variables = env("fake-worker")
    assert variables["POD_NAME"]["valueFrom"] == {"fieldRef": {"fieldPath": "metadata.name"}}
    service = items()["Service", "fake-worker-collector"]["spec"]
    assert service["selector"] == {"app.kubernetes.io/name": "fake-worker-collector"}
    (port,) = service["ports"]
    assert variables["FAKE_WORKER_SINK_URL"]["value"] == (
        f"http://fake-worker-collector:{port['port']}"
    )
    assert port["targetPort"] == "control"


def test_packaging_check_validates_the_fixture_beside_the_base(tmp_path):
    binaries = tmp_path / "bin"
    binaries.mkdir()
    kubeconform = binaries / "kubeconform"
    kubeconform.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        "with open(os.environ['CALL_LOG'], 'a') as f:\n"
        "    f.write(sys.stdin.read() + '\\0')\n"
    )
    kubeconform.chmod(0o755)
    log = tmp_path / "calls"
    subprocess.run(
        [sys.executable, str(REPOSITORY / "scripts/checks/deployment.py")],
        env={**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}", "CALL_LOG": str(log)},
        check=True,
    )
    validated = log.read_text().split("\0")[:-1]
    assert validated == [
        (REPOSITORY / "deploy/base/resources.json").read_text(),
        (FIXTURE / "resources.json").read_text(),
    ]
