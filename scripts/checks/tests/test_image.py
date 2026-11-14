"""A failed startup must retain its diagnostics and its original failure."""

import dataclasses
import json
import subprocess

import pytest

import image

ENTRYPOINT = ["/opt/knarr/container-entrypoint.sh", "/opt/knarr/shipment/entrypoint.sh"]


def test_startup_failure_retains_logs_and_cleans_container(monkeypatch):
    commands = []

    def output(*arguments):
        commands.append((list(arguments), {}))
        if arguments[-1] == "ulimit -Sn":
            return "65536"
        if arguments[1:3] == ("image", "inspect"):
            config = {"User": "10001:10001", "Entrypoint": ENTRYPOINT}
            return json.dumps([{"Architecture": "amd64", "Config": config}])
        if arguments[1] == "port":
            return "127.0.0.1:49152"
        if "--detach" in arguments:
            return "test-container"
        return "29"

    def run(arguments, **kwargs):
        commands.append((arguments, kwargs))
        return subprocess.CompletedProcess(arguments, 7 if arguments[0] == "curl" else 0, "", "")

    ticks = iter([0, 31])
    monkeypatch.setattr(image, "output", output)
    monkeypatch.setattr(image.subprocess, "run", run)
    monkeypatch.setattr(image.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(image.sys, "argv", ["image.py", "knarr:test"])
    with pytest.raises(RuntimeError, match="did not become ready"):
        image.main()
    detached = next(args for args, _ in commands if "--detach" in args)
    assert "--rm" not in detached
    # The deployment's 256 MiB limit in bytes, independently calculated.
    assert "--memory=268435456" in detached
    assert "--memory-swap=268435456" in detached
    assert "--ulimit=nofile=131072:131072" in detached
    # The run uses the image's own architecture, not a fixed one.
    assert "--platform=linux/amd64" in detached
    assert ["docker", "logs", "test-container"] in [args for args, _ in commands]
    assert commands[-1] == (["docker", "rm", "--force", "test-container"], {"check": False})


def test_optional_stats_failure_does_not_fail_a_healthy_image(monkeypatch):
    def output(*arguments):
        if arguments[-1] == "ulimit -Sn":
            return "65536"
        if arguments[1:3] == ("image", "inspect"):
            config = {"User": "10001:10001", "Entrypoint": ENTRYPOINT}
            return json.dumps([{"Architecture": "amd64", "Config": config}])
        if arguments[1] == "stats":
            raise subprocess.CalledProcessError(1, arguments)
        return "29"

    monkeypatch.setattr(image, "output", output)
    monkeypatch.setattr(image, "verify_running", lambda _: None)
    monkeypatch.setattr(
        image.subprocess,
        "run",
        lambda args, **_kwargs: subprocess.CompletedProcess(args, 1),
    )
    monkeypatch.setattr(image.sys, "argv", ["image.py", "knarr:test"])
    image.main()


def test_image_cannot_bypass_the_descriptor_wrapper(monkeypatch):
    monkeypatch.setattr(
        image,
        "output",
        lambda *_: json.dumps([{"Config": {"User": "10001:10001", "Entrypoint": ENTRYPOINT[1:]}}]),
    )
    monkeypatch.setattr(image.sys, "argv", ["image.py", "knarr:test"])
    with pytest.raises(RuntimeError, match="image must use the descriptor-bounding entrypoint"):
        image.main()


DOCKERFILES = {
    "Dockerfile": (image.KNARR, "knarr-rootfs"),
    "fixtures/fake_worker/Dockerfile": (image.FAKE_WORKER, "fake-worker-rootfs"),
}


@pytest.mark.parametrize("dockerfile", DOCKERFILES)
def test_an_image_is_only_the_root_filesystem_the_flake_builds(dockerfile):
    # The flake decides what an image holds (nix/image.nix); a Dockerfile that
    # installed or copied anything else would ship what no pin names.
    _, rootfs = DOCKERFILES[dockerfile]
    lines = (image.ROOT / dockerfile).read_text().splitlines()
    runtime = lines[lines.index("FROM scratch AS runtime") + 1 :]
    assert [line for line in runtime if line.startswith(("COPY", "ADD", "RUN"))] == [
        "COPY --from=build /rootfs/ /"
    ]
    builds = [line for line in lines if " build " in line and line.lstrip().startswith("RUN nix ")]
    assert [line.rsplit(" .#", 1)[1].split()[0] for line in builds] == ["image-toolchain", rootfs]
    # A nix that may update flake.lock would build from a lock nobody reviewed.
    assert all("--no-update-lock-file" in line for line in builds)


@pytest.mark.parametrize("dockerfile", DOCKERFILES)
def test_an_image_declares_the_entrypoint_its_check_expects(dockerfile):
    profile, _ = DOCKERFILES[dockerfile]
    lines = (image.ROOT / dockerfile).read_text().splitlines()
    assert f"ENTRYPOINT {json.dumps(profile.entrypoint)}" in lines
    assert "USER 10001:10001" in lines


def test_fake_worker_images_build_as_knarrs_does():
    # The same pinned Nix and the same toolchain layer, so one OTP owner for both.
    knarr = (image.ROOT / "Dockerfile").read_text().splitlines()
    fixture = (image.ROOT / "fixtures/fake_worker/Dockerfile").read_text().splitlines()
    shared = [
        line
        for line in knarr
        if line.startswith(("FROM ", "USER ", "ENV ")) or ".#image-toolchain" in line
    ]
    assert len(shared) == 5
    for line in shared:
        assert line in fixture


FAKE_WORKER_ENTRYPOINT = [
    "/opt/fake_worker/container-entrypoint.sh",
    "/opt/fake_worker/shipment/entrypoint.sh",
]


def test_fake_worker_profile_runs_its_own_image_checks(monkeypatch):
    commands = []
    verified = []
    cleaned = []

    def output(*arguments):
        commands.append(list(arguments))
        if arguments[-1] == "ulimit -Sn":
            return "65536"
        if arguments[1:3] == ("image", "inspect"):
            config = {"User": "10001:10001", "Entrypoint": FAKE_WORKER_ENTRYPOINT}
            return json.dumps([{"Architecture": "arm64", "Config": config}])
        if "--detach" in arguments:
            return "worker-container"
        return "29"

    def prepare(name, common):
        assert name == "fake-worker:test"
        assert "--read-only" in common
        return image.Session(("--env=PREPARED=1",), verified.append, lambda: cleaned.append(1))

    monkeypatch.setattr(image, "output", output)
    monkeypatch.setattr(
        image, "FAKE_WORKER", dataclasses.replace(image.FAKE_WORKER, prepare=prepare)
    )
    monkeypatch.setattr(
        image.subprocess, "run", lambda args, **_: subprocess.CompletedProcess(args, 0)
    )
    monkeypatch.setattr(image.sys, "argv", ["image.py", "--fake-worker", "fake-worker:test"])
    image.main()
    assert verified == ["worker-container"]
    assert cleaned == [1]
    descriptors = next(args for args in commands if args[-1] == "ulimit -Sn")
    assert "--entrypoint=/opt/fake_worker/container-entrypoint.sh" in descriptors
    detached = next(args for args in commands if "--detach" in args)
    # The fake worker Deployment's 256 MiB limit, from its own resources.json.
    assert "--memory=268435456" in detached
    assert "--publish=127.0.0.1::8080" in detached
    assert "--publish=127.0.0.1::8081" in detached
    assert "--env=PREPARED=1" in detached
    # An arm64 image, as an Apple-silicon host builds, runs as arm64.
    assert "--platform=linux/arm64" in detached
    assert "--platform=linux/arm64" in descriptors


def test_fake_worker_session_runs_a_collector_on_a_private_network(monkeypatch):
    commands = []
    monkeypatch.setattr(image, "output", lambda *arguments: commands.append(list(arguments)))
    monkeypatch.setattr(
        image.subprocess,
        "run",
        lambda args, **_: commands.append(list(args)) or subprocess.CompletedProcess(args, 0),
    )
    session = image.prepare_fake_worker("fake-worker:test", ["docker", "run", "--read-only"])
    network = commands[0][-1]
    assert commands[0][:3] == ["docker", "network", "create"]
    collector_run = commands[1]
    assert collector_run[:3] == ["docker", "run", "--read-only"]
    assert f"--network={network}" in collector_run
    assert "--env=FAKE_WORKER_MODE=collector" in collector_run
    collector = next(
        argument.removeprefix("--name=")
        for argument in collector_run
        if argument.startswith("--name=")
    )
    # The worker reaches the collector by name, as on kind, and drains far longer
    # than the check waits, so its exit proves the early stop.
    assert session.arguments == (
        f"--network={network}",
        "--env=FAKE_WORKER_DRAIN_SECONDS=60",
        f"--env=FAKE_WORKER_SINK_URL=http://{collector}:8081",
    )
    session.cleanup()
    assert commands[-2:] == [
        ["docker", "rm", "--force", collector],
        ["docker", "network", "rm", network],
    ]
    # The runtime environment checks are knarr's: the fixture does not ship.
    assert not any("/opt/tls-check" in " ".join(command) for command in commands)


def test_the_knarr_entrypoint_does_not_pass_as_the_fake_workers(monkeypatch):
    monkeypatch.setattr(
        image,
        "output",
        lambda *_: json.dumps([{"Config": {"User": "10001:10001", "Entrypoint": ENTRYPOINT}}]),
    )
    monkeypatch.setattr(image.sys, "argv", ["image.py", "--fake-worker", "fake-worker:test"])
    with pytest.raises(RuntimeError, match="descriptor-bounding entrypoint"):
        image.main()


COMMON = ["docker", "run", "--read-only", "--tmpfs=/tmp:rw,noexec,nosuid,size=16m"]
RUNTIME_ENV = "/opt/knarr/runtime"


def test_knarr_profile_reruns_the_tls_check_in_the_image(monkeypatch):
    commands = []

    def output(*arguments):
        commands.append(list(arguments))
        return "tls_check: all 6 cases matched"

    monkeypatch.setattr(image, "output", output)
    image.prepare_knarr("knarr:test", COMMON)
    (tls,) = commands
    assert tls[: len(COMMON)] == COMMON
    evidence = image.ROOT / ".scratch/bootstrap/evidence/01/tls"
    assert (evidence / "tls_check.escript").is_file()
    assert f"--volume={evidence}:/opt/tls-check:ro" in tls
    assert "--entrypoint=sh" in tls
    assert tls[-4:] == ["knarr:test", "/opt/tls-check/run.sh", RUNTIME_ENV, "/tmp/tls"]


def test_knarr_profile_fails_on_a_tls_mismatch(monkeypatch, capsys):
    def output(*arguments):
        if "/opt/tls-check/run.sh" in arguments:
            raise subprocess.CalledProcessError(1, arguments, output="what the check printed")
        return ""

    monkeypatch.setattr(image, "output", output)
    with pytest.raises(RuntimeError, match="TLS check failed"):
        image.prepare_knarr("knarr:test", COMMON)
    assert "what the check printed" in capsys.readouterr().out
