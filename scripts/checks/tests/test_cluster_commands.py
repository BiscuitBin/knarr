"""Cluster commands must never use the caller's Kubernetes context."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

import cluster

SCRIPT = Path(__file__).resolve().parents[1] / "cluster.py"


def run_fake(
    tmp_path: Path,
    runner: str,
    action: str,
    *,
    configured: bool = False,
    extra: tuple[str, ...] = (),
) -> tuple[subprocess.CompletedProcess[str], list]:
    checkout = tmp_path / "work tree"
    checkout.mkdir()
    if configured:
        state = checkout / ".cluster"
        state.mkdir(mode=0o700)
        (state / "kubeconfig").write_text("local fake context")
    binaries = tmp_path / "bin"
    binaries.mkdir()
    log = tmp_path / "calls.jsonl"
    for tool in ["kind", "kwokctl", "kubectl", "docker", "kustomize", "helm"]:
        executable = binaries / tool
        executable.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "if sys.argv[1:3] == ['image', 'inspect']: print('sha256:changed-image')\n"
            "with open(os.environ['CALL_LOG'], 'a') as f:\n"
            "    f.write(json.dumps([sys.argv, os.environ.get('KUBECONFIG'), os.environ.get('KWOK_WORKDIR'), os.environ.get('KUBERNETES_SERVICE_HOST'), os.environ.get('KUBERNETES_SERVICE_PORT')]) + '\\n')\n"
            # A test names one fake that then refuses, after recording its call.
            f"if os.environ.get('FAKE_REFUSES') == {tool!r}: sys.exit({tool!r} + ' refused: values do not match')\n"
        )
        executable.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{binaries}:{os.environ['PATH']}",
        "CALL_LOG": str(log),
        "KNARR_CLUSTER": runner,
        "KUBECONFIG": "/wrong/context",
        "KUBERNETES_SERVICE_HOST": "production.invalid",
        "KUBERNETES_SERVICE_PORT": "443",
    }
    result = subprocess.run(
        [sys.executable, str(SCRIPT), action, str(checkout), *extra],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return result, calls


def test_kind_down_scopes_every_command(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kind", "down")
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1
    arguments, kubeconfig, workdir, _, _ = calls[0]
    assert arguments[1:3] == ["delete", "cluster"]
    assert "--name" in arguments
    assert kubeconfig == str(tmp_path / "work tree/.cluster/kubeconfig")
    assert workdir == str(tmp_path / "work tree/.cluster/kwok")


def test_kwok_refuses_endpoint_smoke(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kwok", "smoke")
    assert result.returncode != 0
    assert "kind" in result.stderr
    assert not calls


def test_unknown_runner_refused(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "production", "up")
    assert result.returncode != 0
    assert not calls


def test_failed_delete_keeps_state(tmp_path: Path) -> None:
    checkout = tmp_path / "work tree"
    state = checkout / ".cluster"
    state.mkdir(parents=True)
    (state / "kubeconfig").write_text("keep this")
    binaries = tmp_path / "bin"
    binaries.mkdir()
    executable = binaries / "kind"
    executable.write_text("#!/bin/sh\nexit 7\n")
    executable.chmod(0o755)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "down", str(checkout)],
        env={**os.environ, "KNARR_CLUSTER": "kind", "PATH": f"{binaries}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert (state / "kubeconfig").read_text() == "keep this"


def test_changing_runner_refuses_to_overwrite_state(tmp_path: Path) -> None:
    checkout = tmp_path / "work tree"
    state = checkout / ".cluster"
    state.mkdir(parents=True)
    (state / "runner").write_text("kind")
    binaries = tmp_path / "bin"
    binaries.mkdir()
    executable = binaries / "kwokctl"
    executable.write_text("#!/bin/sh\nexit 7\n")
    executable.chmod(0o755)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "up", str(checkout)],
        env={**os.environ, "KNARR_CLUSTER": "kwok", "PATH": f"{binaries}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert "cluster-down" in result.stderr
    assert (state / "runner").read_text() == "kind"


def helm_install(image_tag: str, *extra: str) -> list[str]:
    return [
        "upgrade",
        "--install",
        "knarr",
        str(cluster.chart.CHART),
        "--namespace",
        "default",
        "--server-side=true",
        "--reset-values",
        "--wait",
        "--timeout",
        "120s",
        "--set-string",
        "image.repository=knarr",
        "--set-string",
        f"image.tag={image_tag}",
        "--set-string",
        "podAnnotations.knarr\\.dev/local-image-id=sha256:changed-image",
        *extra,
    ]


def test_deploy_installs_the_chart_with_the_image_identity(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kind", "deploy", configured=True, extra=("knarr:probe",))
    assert result.returncode == 0, result.stderr
    assert all(call[1] == str(tmp_path / "work tree/.cluster/kubeconfig") for call in calls)
    commands = [(Path(call[0][0]).name, call[0][1:]) for call in calls]
    assert commands[0][0] == "kind"
    assert commands[0][1][:2] == ["load", "docker-image"]
    # --wait replaces the rollout wait; the image ID rolls a rebuilt tag.
    assert commands[-1] == ("helm", helm_install("probe"))
    assert not any(tool == "kubectl" for tool, _ in commands)


def test_deploy_e2e_fast_adds_its_values_file(tmp_path: Path) -> None:
    result, calls = run_fake(
        tmp_path, "kind", "deploy", configured=True, extra=("knarr:probe", "e2e-fast")
    )
    assert result.returncode == 0, result.stderr
    values = str(cluster.ROOT / "fixtures/chart-values/e2e-fast.yaml")
    assert calls[-1][0][1:] == helm_install("probe", "--values", values)


def test_deploy_wrong_ca_applies_the_patched_render_as_helm_without_waiting(
    tmp_path: Path,
) -> None:
    result, calls = run_fake(
        tmp_path, "kind", "deploy", configured=True, extra=("knarr:probe", "wrong-ca")
    )
    assert result.returncode == 0, result.stderr
    commands = [(Path(call[0][0]).name, call[0][1:]) for call in calls]
    tools = [tool for tool, _ in commands]
    assert tools == ["kind", "docker", "helm", "kustomize", "kubectl"]
    assert commands[2][1][:3] == ["template", "knarr", str(cluster.chart.CHART)]
    assert "--namespace" in commands[2][1]
    assert "podAnnotations.knarr\\.dev/local-image-id=sha256:changed-image" in commands[2][1]
    # Helm 4 installs by server-side apply as field manager helm, so the next
    # `just deploy` owns, and removes, what this apply adds.
    assert commands[-1][1] == [
        "apply",
        "--server-side",
        "--field-manager=helm",
        "-f",
        str(tmp_path / "work tree/.cluster/render/wrong-ca.yaml"),
    ]
    assert not any(tool == "helm" and "upgrade" in arguments for tool, arguments in commands)


def test_deploy_wrong_ca_shows_why_the_render_failed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("FAKE_REFUSES", "helm")
    result, calls = run_fake(
        tmp_path, "kind", "deploy", configured=True, extra=("knarr:probe", "wrong-ca")
    )
    assert result.returncode != 0
    assert "helm refused: values do not match" in result.stderr
    assert not any(Path(call[0][0]).name == "kubectl" for call in calls)


def test_the_wrong_ca_render_is_the_patched_chart_owned_by_the_release() -> None:
    rendered = cluster.wrong_ca(cluster.chart_values("knarr:probe", "sha256:probe"))
    assert rendered.count("    meta.helm.sh/release-name: knarr\n") == 4
    assert rendered.count("    meta.helm.sh/release-namespace: default\n") == 4
    assert "        - name: KNARR_CA_FILE\n" in rendered
    assert "        name: wrong-ca\n" in rendered
    assert "        image: knarr:probe\n" in rendered
    assert "        knarr.dev/local-image-id: sha256:probe\n" in rendered


@pytest.mark.parametrize("tag", ["20261017", "true", "null"])
def test_a_tag_helm_would_coerce_still_names_the_image(tag: str) -> None:
    # --set would read these as a number, a boolean or null; the schema wants a string.
    rendered = cluster.wrong_ca(cluster.chart_values(f"knarr:{tag}", "sha256:probe"))
    assert f"        image: knarr:{tag}\n" in rendered


@pytest.mark.parametrize("image", ["knarr", "localhost:5000/knarr"])
def test_deploy_refuses_an_image_without_a_tag(image: str) -> None:
    with pytest.raises(ValueError, match="repository:tag"):
        cluster.chart_values(image, "sha256:probe")


def test_deploy_refuses_an_unknown_variant(tmp_path: Path) -> None:
    result, calls = run_fake(
        tmp_path, "kind", "deploy", configured=True, extra=("knarr:probe", "production")
    )
    assert result.returncode != 0
    assert "unknown deployment variant" in result.stderr
    assert not calls


def test_deploy_requires_local_kubeconfig(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kind", "deploy")
    assert result.returncode != 0
    assert "cluster-up" in result.stderr
    assert not calls


def test_deploy_cannot_inherit_in_cluster_configuration(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kind", "deploy", configured=True)
    assert result.returncode == 0, result.stderr
    assert all(call[3:] == [None, None] for call in calls)


def test_diagnostics_include_pod_termination_and_previous_logs(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kind", "diagnostics", configured=True)
    assert result.returncode == 0, result.stderr
    arguments = [call[0][1:] for call in calls]
    assert ["describe", "pods", "-l", "app.kubernetes.io/name=knarr"] in arguments
    assert [
        "logs",
        "deployment/knarr",
        "--all-containers",
        "--previous",
        "--tail=100",
    ] in arguments


def test_port_forward_yields_the_local_port_and_stops_the_forward(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binaries = tmp_path / "bin"
    binaries.mkdir()
    pid_file = tmp_path / "kubectl.pid"
    kubectl = binaries / "kubectl"
    kubectl.write_text(
        f"#!{sys.executable}\n"
        "import os, sys, time\n"
        f"open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
        "assert sys.argv[1:] == ['port-forward', '--address=127.0.0.1', 'pod/w-1', ':8081']\n"
        "print('Forwarding from 127.0.0.1:43210 -> 8081', flush=True)\n"
        "time.sleep(60)\n"
    )
    kubectl.chmod(0o755)
    monkeypatch.setenv("PATH", f"{binaries}:{os.environ['PATH']}")
    with cluster.port_forward(tmp_path, "pod/w-1", 8081) as port:
        assert port == 43210
        pid = int(pid_file.read_text())
    # Stopped and reaped: no process has that pid any more.
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    assert (tmp_path / "port-forward-pod-w-1-8081.log").read_text().startswith("Forwarding from")
