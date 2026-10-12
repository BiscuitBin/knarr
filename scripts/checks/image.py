"""Verify an already-built image without pulling anything from a registry.

Usage: image.py <image> for knarr's image, or image.py --fake-worker <image> for
the fake worker fixture's (ticket 29). Both share the checks on the numeric
user, the descriptor-bounding entrypoint, OTP ownership and the restricted
runtime; each then proves its own image starts and behaves.
"""

from __future__ import annotations

import json
import re
import secrets
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Session:
    """What a profile sets up around the started container: its extra `docker run`
    arguments, the check of the running container, and the teardown."""

    arguments: tuple[str, ...]
    verify: Callable[[str], None]
    cleanup: Callable[[], None]


@dataclass(frozen=True)
class Profile:
    """What differs between the two images this script checks."""

    entrypoint: list[str]
    # The resources.json whose Deployment's memory limit is the run's budget.
    resources: Path
    deployment: str
    ports: tuple[str, ...]
    # Given the image and the restricted `docker run` prefix.
    prepare: Callable[[str, list[str]], Session]


def output(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def curl(*arguments):
    return ["curl", "--noproxy", "*", "--silent", "--max-time", "5", *arguments]


def verify_running(container):
    port = output("docker", "port", container, "8080/tcp").rsplit(":", 1)[1]
    deadline = time.monotonic() + 30
    while True:
        probe = subprocess.run(
            [
                "curl",
                "--noproxy",
                "*",
                "--fail",
                "--silent",
                "--max-time",
                "2",
                f"http://127.0.0.1:{port}/readyz",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if probe.returncode == 0 and probe.stdout == "ok\n":
            break
        if time.monotonic() >= deadline:
            raise RuntimeError("restricted image did not become ready")
        time.sleep(0.25)
    metrics = output(
        "curl",
        "--noproxy",
        "*",
        "--fail",
        "--silent",
        "--max-time",
        "5",
        f"http://127.0.0.1:{port}/metrics",
    )
    if not re.search(r"^knarr_startups_total 1(?:\.0)?$", metrics, re.MULTILINE):
        raise RuntimeError("startup metric missing")


def verify_knarr(container):
    verify_running(container)
    report_memory(container)


def prepare_knarr(_image, _common):
    return Session(arguments=(), verify=verify_knarr, cleanup=lambda: None)


def prepare_fake_worker(image, common):
    """A collector from the same image on a private network, so the check sees the
    worker deliver its kill record to the collector by name, as it does on kind.
    The drain runs 60 s, so a stop within the check's 10 s is the work being
    done, not the deadline."""
    suffix = secrets.token_hex(4)
    network = f"fake-worker-check-{suffix}"
    collector = f"fake-worker-collector-{suffix}"

    def cleanup():
        subprocess.run(["docker", "rm", "--force", collector], check=False)
        subprocess.run(["docker", "network", "rm", network], check=False)

    def verify(container):
        try:
            verify_fake_worker(container, collector)
        except Exception:
            subprocess.run(["docker", "logs", collector], check=False)
            raise

    output("docker", "network", "create", network)
    try:
        output(
            *common,
            "--detach",
            f"--network={network}",
            f"--name={collector}",
            "--publish=127.0.0.1::8081",
            "--env=FAKE_WORKER_MODE=collector",
            image,
        )
    except Exception:
        cleanup()
        raise
    return Session(
        arguments=(
            f"--network={network}",
            "--env=FAKE_WORKER_DRAIN_SECONDS=60",
            f"--env=FAKE_WORKER_SINK_URL=http://{collector}:8081",
        ),
        verify=verify,
        cleanup=cleanup,
    )


def report_memory(container):
    subprocess.run(
        [
            "docker",
            "stats",
            "--no-stream",
            "--format=memory usage / limit: {{.MemUsage}}",
            container,
        ],
        check=False,
    )


def verify_fake_worker(container, collector):
    """The status endpoint answers, and a real SIGTERM to PID 1 drains the worker:
    status still answers with accepting false (StatusEndpoint.Served), the kill
    record reaches the collector and the log, and the container exits 0 once
    control sets cost 0."""
    status_port = output("docker", "port", container, "8080/tcp").rsplit(":", 1)[1]
    control_port = output("docker", "port", container, "8081/tcp").rsplit(":", 1)[1]
    status = f"http://127.0.0.1:{status_port}/knarr/v1/status"
    control = f"http://127.0.0.1:{control_port}/control"

    def await_status(wanted):
        deadline = time.monotonic() + 30
        while True:
            probe = subprocess.run(curl(status), check=False, capture_output=True, text=True)
            if probe.returncode == 0 and probe.stdout == wanted:
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(f"status never answered {wanted}: {probe.stdout!r}")
            time.sleep(0.25)

    def put(body):
        output(*curl("--fail", "--request", "PUT", "--data", body, control))

    await_status('{"cost":0,"accepting":true}')
    put('{"cost":1800}')
    await_status('{"cost":1800,"accepting":true}')
    report_memory(container)
    output("docker", "kill", "--signal=TERM", container)
    await_status('{"cost":1800,"accepting":false}')
    collector_port = output("docker", "port", collector, "8081/tcp").rsplit(":", 1)[1]
    kills = []
    deadline = time.monotonic() + 10
    while not kills and time.monotonic() < deadline:
        listed = subprocess.run(
            curl(f"http://127.0.0.1:{collector_port}/kills"),
            check=False,
            capture_output=True,
            text=True,
        )
        kills = json.loads(listed.stdout)["kills"] if listed.returncode == 0 else []
        time.sleep(0.25)
    if [(kill["busy"], kill["cost"], kill["accepting"]) for kill in kills] != [(True, 1800, True)]:
        raise RuntimeError(f"the collector did not get the busy kill record: {kills}")
    put('{"cost":0}')
    deadline = time.monotonic() + 10
    while output("docker", "inspect", "--format={{.State.Running}}", container) == "true":
        if time.monotonic() >= deadline:
            raise RuntimeError("the worker did not stop once its work was done")
        time.sleep(0.25)
    code = output("docker", "inspect", "--format={{.State.ExitCode}}", container)
    if code != "0":
        raise RuntimeError(f"the worker exited {code} after SIGTERM")
    logs = output("docker", "logs", container)
    if not re.search(
        r'^fake_worker kill \{"pod":"[^"]+","busy":true,"cost":1800,', logs, re.MULTILINE
    ):
        raise RuntimeError("the kill record is missing from the logs")


KNARR = Profile(
    entrypoint=["/opt/knarr/container-entrypoint.sh", "/opt/knarr/shipment/entrypoint.sh"],
    resources=ROOT / "deploy/base/resources.json",
    deployment="knarr",
    ports=("8080",),
    prepare=prepare_knarr,
)
FAKE_WORKER = Profile(
    entrypoint=[
        "/opt/fake_worker/container-entrypoint.sh",
        "/opt/fake_worker/shipment/entrypoint.sh",
    ],
    resources=ROOT / "fixtures/fake_worker/deploy/resources.json",
    deployment="fake-worker",
    ports=("8080", "8081"),
    prepare=prepare_fake_worker,
)


def main():
    arguments = sys.argv[1:]
    profile = KNARR
    if arguments[:1] == ["--fake-worker"]:
        profile = FAKE_WORKER
        arguments = arguments[1:]
    if len(arguments) != 1:
        raise ValueError("usage: image.py [--fake-worker] <image>")
    image = arguments[0]
    pin = tomllib.loads((ROOT / "pixi.toml").read_text())["feature"]["otp"]["dependencies"][
        "erlang"
    ]
    expected = pin.removeprefix("==").split(".")[0]
    config = json.loads(output("docker", "image", "inspect", image))[0]["Config"]
    if config["User"] != "10001:10001":
        raise RuntimeError("image must declare USER 10001:10001")
    if config.get("Entrypoint") != profile.entrypoint:
        raise RuntimeError("image must use the descriptor-bounding entrypoint")
    resources = json.loads(profile.resources.read_text())
    deployment = next(
        item
        for item in resources["items"]
        if item["kind"] == "Deployment" and item["metadata"]["name"] == profile.deployment
    )
    memory = deployment["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"][
        "memory"
    ]
    if not memory.endswith("Mi"):
        raise RuntimeError("image check expects the deployment memory limit in Mi")
    budget = int(memory.removesuffix("Mi")) * 1024 * 1024
    common = [
        "docker",
        "run",
        "--pull=never",
        "--platform=linux/amd64",
        "--read-only",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--tmpfs=/tmp:rw,noexec,nosuid,size=16m",
        f"--memory={budget}",
        f"--memory-swap={budget}",
    ]
    descriptors = output(
        *common,
        "--rm",
        "--ulimit=nofile=131072:131072",
        f"--entrypoint={profile.entrypoint[0]}",
        image,
        "sh",
        "-c",
        "ulimit -Sn",
    )
    if descriptors != "65536":
        raise RuntimeError(f"container did not bound its descriptor limit: {descriptors}")
    build = output(*common, "--rm", "--entrypoint=cat", image, "/opt/build-otp")
    runtime = output(
        *common,
        "--rm",
        "--entrypoint=erl",
        image,
        "-noshell",
        "-eval",
        "io:put_chars(erlang:system_info(otp_release)), halt().",
    )
    if build != expected or runtime != expected:
        raise RuntimeError(f"OTP mismatch: owner={expected}, build={build}, runtime={runtime}")
    session = profile.prepare(image, common)
    try:
        container = output(
            *common,
            "--ulimit=nofile=131072:131072",
            "--detach",
            *(f"--publish=127.0.0.1::{port}" for port in profile.ports),
            *session.arguments,
            image,
        )
        try:
            session.verify(container)
            print(f"image: OTP {expected}, numeric user and read-only runtime verified")
        except Exception:
            subprocess.run(
                ["docker", "inspect", "--format={{json .State}}", container], check=False
            )
            subprocess.run(["docker", "logs", container], check=False)
            raise
        finally:
            subprocess.run(["docker", "rm", "--force", container], check=False)
    finally:
        session.cleanup()


if __name__ == "__main__":
    main()
