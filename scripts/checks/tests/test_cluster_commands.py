"""Cluster commands must never use the caller's Kubernetes context."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
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
    for tool in ["kind", "kwokctl", "kubectl", "docker", "kustomize"]:
        executable = binaries / tool
        executable.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "if sys.argv[1:3] == ['image', 'inspect']: print('sha256:changed-image')\n"
            "stdin = sys.stdin.read() if sys.argv[1:] == ['apply', '-f', '-'] else None\n"
            "with open(os.environ['CALL_LOG'], 'a') as f:\n"
            "    f.write(json.dumps([sys.argv, os.environ.get('KUBECONFIG'), os.environ.get('KWOK_WORKDIR'), os.environ.get('KUBERNETES_SERVICE_HOST'), os.environ.get('KUBERNETES_SERVICE_PORT'), stdin]) + '\\n')\n"
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
    arguments, kubeconfig, workdir, _, _, _ = calls[0]
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


def test_deploy_records_image_identity_for_rollout(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kind", "deploy", configured=True)
    assert result.returncode == 0, result.stderr
    render = tmp_path / "work tree/.cluster/render/base"
    data = json.loads((render / "resources.json").read_text())
    deployment = next(item for item in data["items"] if item["kind"] == "Deployment")
    template = deployment["spec"]["template"]
    assert (
        template["metadata"]["annotations"]["knarr.dev/local-image-id"] == "sha256:changed-image"
    )
    assert template["spec"]["containers"][0]["image"].startswith("knarr:work-tree-")
    assert all(call[1] == str(tmp_path / "work tree/.cluster/kubeconfig") for call in calls)
    build = next(call[0] for call in calls if call[0][0].endswith("kustomize"))
    assert build[1:] == ["build", str(render)]


def test_deploy_variant_layers_on_the_rendered_base(tmp_path: Path) -> None:
    result, calls = run_fake(
        tmp_path, "kind", "deploy", configured=True, extra=("knarr:probe", "wrong-ca")
    )
    assert result.returncode == 0, result.stderr
    render = tmp_path / "work tree/.cluster/render/wrong-ca"
    assert (render / "kustomization.yaml").read_text() == (
        Path(SCRIPT).parents[2] / "deploy/wrong-ca/kustomization.yaml"
    ).read_text()
    assert (render / "patch.json").is_file()
    # The variant's kustomization names ../base, so the patched base sits beside it.
    data = json.loads((render / "../base/resources.json").read_text())
    deployment = next(item for item in data["items"] if item["kind"] == "Deployment")
    assert deployment["spec"]["template"]["spec"]["containers"][0]["image"] == "knarr:probe"
    build = next(call[0] for call in calls if call[0][0].endswith("kustomize"))
    assert build[1:] == ["build", str(render)]


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
    assert all(call[3:5] == [None, None] for call in calls)


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


def test_voyager_deploy_applies_the_cookie_secret_before_the_variant(tmp_path: Path) -> None:
    result, calls = run_fake(
        tmp_path, "kind", "deploy", configured=True, extra=("knarr:probe", "voyager")
    )
    assert result.returncode == 0, result.stderr
    cookie_file = tmp_path / "work tree/.cluster/voyager-cookie"
    assert cookie_file.stat().st_mode & 0o777 == 0o600
    cookie = cookie_file.read_text()
    # The cookie reaches kubectl only through stdin: any host user can read argv.
    assert not any(cookie in argument for call in calls for argument in call[0])
    applied = next(index for index, call in enumerate(calls) if call[5] and "Secret" in call[5])
    assert calls[applied][0][1:] == ["apply", "-f", "-"]
    assert json.loads(calls[applied][5]) == {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": "knarr-voyager"},
        "type": "Opaque",
        "stringData": {"erl_zflags": f"-setcookie {cookie}"},
    }
    build = next(index for index, call in enumerate(calls) if call[0][0].endswith("kustomize"))
    assert applied < build
    assert all(call[1] == str(tmp_path / "work tree/.cluster/kubeconfig") for call in calls)


def test_base_deploy_creates_no_cookie_or_secret(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kind", "deploy", configured=True)
    assert result.returncode == 0, result.stderr
    assert not (tmp_path / "work tree/.cluster/voyager-cookie").exists()
    assert not any("secret" in call[0] for call in calls)


def test_voyager_cookie_is_private_and_reused(tmp_path: Path) -> None:
    cookie = cluster.voyager_cookie(tmp_path)
    # Hex: a cookie that began with "-" would read as another erl flag.
    assert len(cookie) == 64
    assert int(cookie, 16) >= 0
    assert (tmp_path / "voyager-cookie").stat().st_mode & 0o777 == 0o600
    assert cluster.voyager_cookie(tmp_path) == cookie


@pytest.mark.parametrize(
    ("content", "mode"), [("a" * 64, 0o644), ("", 0o600), ("-not-hex", 0o600)]
)
def test_voyager_cookie_refuses_a_loose_or_malformed_file(
    tmp_path: Path, content: str, mode: int
) -> None:
    cookie_file = tmp_path / "voyager-cookie"
    cookie_file.write_text(content)
    cookie_file.chmod(mode)
    with pytest.raises(ValueError, match="voyager-cookie"):
        cluster.voyager_cookie(tmp_path)


def test_voyager_cookie_refuses_a_symlink(tmp_path: Path) -> None:
    target = tmp_path / "elsewhere"
    target.write_text("a" * 64)
    target.chmod(0o600)
    (tmp_path / "voyager-cookie").symlink_to(target)
    with pytest.raises(ValueError, match="voyager-cookie"):
        cluster.voyager_cookie(tmp_path)


def test_voyager_cookie_keeps_a_cookie_another_caller_published(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Another caller publishes between this one's check and its link: this one
    # keeps theirs and leaves no temporary file behind.
    real_link = os.link

    def raced(source: str, destination: str) -> None:
        winner = Path(destination)
        winner.write_text("b" * 64)
        winner.chmod(0o600)
        real_link(source, destination)

    monkeypatch.setattr(cluster.os, "link", raced)
    assert cluster.voyager_cookie(tmp_path) == "b" * 64
    assert [path.name for path in tmp_path.iterdir()] == ["voyager-cookie"]


def test_kwok_refuses_voyager_forward(tmp_path: Path) -> None:
    result, calls = run_fake(tmp_path, "kwok", "voyager-forward", configured=True)
    assert result.returncode != 0
    assert "kind" in result.stderr
    assert not calls


def test_taken_ports_names_a_bound_loopback_port() -> None:
    with socket.socket() as held:
        held.bind(("127.0.0.1", 0))
        held.listen()
        port = held.getsockname()[1]
        assert cluster.taken_ports((port,)) == [port]
    assert cluster.taken_ports((port,)) == []
    # A port nothing listens on is free, even while a socket holds it, as the
    # last forward's TIME_WAIT connections do; kubectl binds it regardless.
    with socket.socket() as held:
        held.bind(("127.0.0.1", 0))
        assert cluster.taken_ports((held.getsockname()[1],)) == []


def fake_voyager_tools(tmp_path: Path, env: list) -> tuple[Path, Path]:
    """A kubectl that answers `get deployment` with `env` and forwards once, and
    an erl_call that answers the node probe. Both log their arguments."""
    binaries = tmp_path / "bin"
    binaries.mkdir()
    log = tmp_path / "calls.jsonl"
    deployment = {"spec": {"template": {"spec": {"containers": [{"name": "knarr", "env": env}]}}}}
    kubectl = binaries / "kubectl"
    kubectl.write_text(
        f"#!{sys.executable}\n"
        "import json, sys, time\n"
        f"open({str(log)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
        "if sys.argv[1] == 'get':\n"
        f"    print(json.dumps({deployment!r}))\n"
        "elif sys.argv[1] == 'port-forward':\n"
        "    for mapping in sys.argv[4:]:\n"
        "        local, remote = mapping.split(':')\n"
        "        print(f'Forwarding from 127.0.0.1:{local} -> {remote}', flush=True)\n"
        "    time.sleep(1)\n"
    )
    kubectl.chmod(0o755)
    erl_call = binaries / "erl_call"
    erl_call.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys\n"
        "home = os.environ['HOME'] + '/.erlang.cookie'\n"
        "cookie = [open(home).read(), oct(os.stat(home).st_mode & 0o777)]\n"
        f"open({str(log)!r}, 'a').write(json.dumps(sys.argv[1:] + cookie) + '\\n')\n"
        "print(\"'knarr@127.0.0.1'\")\n"
    )
    erl_call.chmod(0o755)
    return binaries, log


VOYAGER_ENV = [
    {"name": "ERL_FLAGS", "value": "-knarr discovery true -name knarr@127.0.0.1"},
    {"name": "ERL_ZFLAGS", "valueFrom": {"secretKeyRef": {"name": "knarr-voyager"}}},
]


def free_ports(count: int) -> tuple[int, ...]:
    sockets = [socket.socket() for _ in range(count)]
    try:
        for sock in sockets:
            sock.bind(("127.0.0.1", 0))
        return tuple(sock.getsockname()[1] for sock in sockets)
    finally:
        for sock in sockets:
            sock.close()


def test_voyager_forward_maps_the_fixed_ports_probes_and_reports(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    binaries, log = fake_voyager_tools(tmp_path, VOYAGER_ENV)
    monkeypatch.setenv("PATH", f"{binaries}:{os.environ['PATH']}")
    monkeypatch.setattr(cluster, "ERL_CALL", binaries / "erl_call")
    epmd, dist = free_ports(2)
    monkeypatch.setattr(cluster, "VOYAGER_PORTS", (epmd, dist))
    probe_homes = tmp_path / "tmp"
    probe_homes.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(probe_homes))
    cookie = cluster.voyager_cookie(tmp_path)
    # The fake forward ends after a second, as a redeploy's Recreate would end it.
    with pytest.raises(RuntimeError, match="port-forward ended"):
        cluster.voyager_forward(tmp_path)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert [
        "port-forward",
        "--address=127.0.0.1",
        "deployment/knarr",
        f"{epmd}:{epmd}",
        f"{dist}:{dist}",
    ] in calls
    # erl_call reads the cookie from a private HOME, never from its arguments.
    assert ["-name", "knarr@127.0.0.1", "-a", "erlang node", cookie, "0o400"] in calls
    assert not any(probe_homes.iterdir())
    printed = capsys.readouterr().out
    assert "knarr@127.0.0.1" in printed
    assert "long" in printed
    assert cookie in printed
    assert (tmp_path / "port-forward-voyager.log").read_text().startswith("Forwarding from")


def test_voyager_forward_bounds_a_stalled_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binaries, _ = fake_voyager_tools(tmp_path, VOYAGER_ENV)
    (binaries / "erl_call").write_text(f"#!{sys.executable}\nimport time\ntime.sleep(60)\n")
    (binaries / "kubectl").write_text(
        (binaries / "kubectl").read_text().replace("time.sleep(1)", "time.sleep(60)")
    )
    monkeypatch.setenv("PATH", f"{binaries}:{os.environ['PATH']}")
    monkeypatch.setattr(cluster, "ERL_CALL", binaries / "erl_call")
    monkeypatch.setattr(cluster, "VOYAGER_PORTS", free_ports(2))
    monkeypatch.setattr(cluster, "PROBE_SECONDS", 2)
    cluster.voyager_cookie(tmp_path)
    started = time.monotonic()
    with pytest.raises(RuntimeError, match="did not answer"):
        cluster.voyager_forward(tmp_path)
    assert time.monotonic() - started < 15


def test_voyager_forward_refuses_a_deployment_without_distribution(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binaries, log = fake_voyager_tools(
        tmp_path, [{"name": "ERL_FLAGS", "value": "-knarr discovery true"}]
    )
    monkeypatch.setenv("PATH", f"{binaries}:{os.environ['PATH']}")
    monkeypatch.setattr(cluster, "VOYAGER_PORTS", free_ports(2))
    cluster.voyager_cookie(tmp_path)
    with pytest.raises(ValueError, match="voyager-deploy"):
        cluster.voyager_forward(tmp_path)
    assert not any(json.loads(line)[0] == "port-forward" for line in log.read_text().splitlines())


def test_voyager_forward_refuses_a_taken_port(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binaries, log = fake_voyager_tools(tmp_path, VOYAGER_ENV)
    monkeypatch.setenv("PATH", f"{binaries}:{os.environ['PATH']}")
    cluster.voyager_cookie(tmp_path)
    with socket.socket() as held:
        held.bind(("127.0.0.1", 0))
        held.listen()
        port = held.getsockname()[1]
        monkeypatch.setattr(cluster, "VOYAGER_PORTS", (port, free_ports(1)[0]))
        with pytest.raises(ValueError, match=rf"127\.0\.0\.1:{port}.*epmd -kill"):
            cluster.voyager_forward(tmp_path)
    assert not log.exists() or not any(
        json.loads(line)[0] == "port-forward" for line in log.read_text().splitlines()
    )


def test_voyager_forward_stops_kubectl_on_sigterm(tmp_path: Path) -> None:
    # SIGTERM must unwind through the forward's cleanup: a kubectl left behind
    # would keep the distribution ports bound with no one watching.
    binaries, _ = fake_voyager_tools(tmp_path, VOYAGER_ENV)
    kubectl = binaries / "kubectl"
    kubectl.write_text(
        kubectl.read_text()
        .replace("import json, sys, time", "import json, os, sys, time")
        .replace(
            "    time.sleep(1)\n",
            f"    open({str(tmp_path / 'kubectl.pid')!r}, 'w').write(str(os.getpid()))\n"
            "    time.sleep(60)\n",
        )
    )
    state = tmp_path / "state"
    state.mkdir()
    script = (
        "import sys, pathlib\n"
        f"sys.path.insert(0, {str(Path(cluster.__file__).parent)!r})\n"
        "import cluster\n"
        f"cluster.ERL_CALL = pathlib.Path({str(binaries / 'erl_call')!r})\n"
        f"cluster.VOYAGER_PORTS = {free_ports(2)!r}\n"
        "cluster.exit_on_sigterm()\n"
        f"cluster.voyager_cookie(pathlib.Path({str(state)!r}))\n"
        f"cluster.voyager_forward(pathlib.Path({str(state)!r}))\n"
    )
    wrapper = subprocess.Popen(
        [sys.executable, "-c", script],
        stdout=subprocess.PIPE,
        text=True,
        env={**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}"},
    )
    try:
        assert wrapper.stdout is not None
        while "Ctrl-C to stop" not in (line := wrapper.stdout.readline()):
            assert line, "the forward never reported it was holding"
        pid = int((tmp_path / "kubectl.pid").read_text())
        wrapper.send_signal(signal.SIGTERM)
        assert wrapper.wait(timeout=15) == 128 + signal.SIGTERM
    finally:
        wrapper.kill()
        wrapper.wait()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    pytest.fail("kubectl port-forward outlived the wrapper")
