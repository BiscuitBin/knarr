"""Process-level proof of the fake worker's SIGTERM drain and exit codes.

The fixture's Gleam tests deliver SIGTERM as the message the signal handler
sends. These start the built VM as kubelet starts a container's process, send
it a real SIGTERM, and read the outcome from outside: the status endpoint while
it drains (worker_contract.allium, StatusEndpoint.Served), the kill record a
loopback collector receives, and the exit code (ticket 29).
"""

from __future__ import annotations

import json
import os
import queue
import re
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from conftest import REPOSITORY

EBIN = REPOSITORY / "fixtures" / "fake_worker" / "build" / "dev" / "erlang"
MAIN = "'fake_worker@@main':run(fake_worker)."
# Loopback only, so a proxy in the environment never sees these requests.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class Worker:
    """The fake worker's VM, its output collected line by line."""

    def __init__(self, cwd: Path, environment: dict[str, str], expression: str = MAIN) -> None:
        env = {key: value for key, value in os.environ.items() if key != "ERL_FLAGS"}
        env.update(environment)
        command = ["erl", "-noshell", "-pa", *map(str, sorted(EBIN.glob("*/ebin")))]
        self.process = subprocess.Popen(
            [*command, "-eval", expression],
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.output: list[str] = []
        self.lines: queue.Queue[str] = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.output.append(line)
            self.lines.put(line)

    def wait_for(self, pattern: str, timeout: float = 15) -> re.Match[str]:
        deadline = time.monotonic() + timeout
        while (remaining := deadline - time.monotonic()) > 0:
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                break
            if match := re.search(pattern, line):
                return match
        pytest.fail(f"no line matched {pattern!r}:\n{''.join(self.output)}")

    def port(self, listener: str) -> int:
        return int(self.wait_for(rf"listener={listener} port=(\d+)").group(1))

    def exit_code(self, timeout: float) -> int:
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            pytest.fail(f"the VM did not exit within {timeout} s:\n{''.join(self.output)}")

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()


class Collector:
    """A loopback stand-in for the collector: it keeps every PUT it receives."""

    def __init__(self) -> None:
        received: list[tuple[str, dict]] = []

        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self) -> None:
                length = int(self.headers["content-length"])
                received.append((self.path, json.loads(self.rfile.read(length))))
                self.send_response(204)
                self.end_headers()

            def log_message(self, *_arguments: object) -> None:
                pass

        self.received = received
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def request(method: str, url: str, body: str | None = None) -> tuple[int, str]:
    data = None if body is None else body.encode()
    call = urllib.request.Request(url, data=data, method=method)  # noqa: S310 - loopback http
    try:
        with OPENER.open(call, timeout=5) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def environment(**overrides: str) -> dict[str, str]:
    return {
        "FAKE_WORKER_BIND": "127.0.0.1",
        "FAKE_WORKER_STATUS_PORT": "0",
        "FAKE_WORKER_CONTROL_PORT": "0",
        "POD_NAME": "worker-1",
        **overrides,
    }


@pytest.fixture
def collector() -> object:
    collector = Collector()
    yield collector
    collector.close()


def test_sigterm_drains_until_the_work_is_done(tmp_path: Path, collector: Collector) -> None:
    worker = Worker(
        tmp_path, environment(FAKE_WORKER_DRAIN_SECONDS="30", FAKE_WORKER_SINK_URL=collector.url)
    )
    try:
        status = f"http://127.0.0.1:{worker.port('status')}/knarr/v1/status"
        control = f"http://127.0.0.1:{worker.port('control')}/control"
        worker.wait_for("fake_worker started pod=worker-1")
        if Path("/proc").is_dir():
            # kubelet signals the container's PID 1: the BEAM itself must be
            # the process, with every launcher in between gone by exec.
            assert Path(f"/proc/{worker.process.pid}/exe").resolve().name == "beam.smp"
        assert request("PUT", control, '{"cost":1800}')[0] == 200
        assert request("GET", status) == (200, '{"cost":1800,"accepting":true}')

        worker.process.send_signal(signal.SIGTERM)
        record = {"pod": "worker-1", "busy": True, "cost": 1800, "accepting": True}
        worker.wait_for(re.escape("fake_worker kill " + json.dumps(record, separators=(",", ":"))))
        assert request("GET", status) == (200, '{"cost":1800,"accepting":false}')
        deadline = time.monotonic() + 5
        while not collector.received and time.monotonic() < deadline:
            time.sleep(0.05)
        assert collector.received == [("/kills/worker-1", record)]

        time.sleep(0.5)
        assert worker.process.poll() is None, "the VM stopped while the work was unfinished"
        assert request("GET", status) == (200, '{"cost":1800,"accepting":false}')
        assert request("PUT", control, '{"cost":0}')[0] == 200
        assert worker.exit_code(timeout=5) == 0
    finally:
        worker.stop()


def test_sigterm_drain_ends_at_the_deadline(tmp_path: Path) -> None:
    worker = Worker(tmp_path, environment(FAKE_WORKER_DRAIN_SECONDS="1"))
    try:
        control = f"http://127.0.0.1:{worker.port('control')}/control"
        worker.wait_for("fake_worker started")
        assert request("PUT", control, '{"cost":10}')[0] == 200
        signalled = time.monotonic()
        worker.process.send_signal(signal.SIGTERM)
        worker.wait_for(r'fake_worker kill \{"pod":"worker-1","busy":true,"cost":10,')
        assert worker.exit_code(timeout=5) == 0
        assert time.monotonic() - signalled >= 1
    finally:
        worker.stop()


def test_an_idle_worker_stops_at_once(tmp_path: Path) -> None:
    worker = Worker(tmp_path, environment(FAKE_WORKER_DRAIN_SECONDS="30"))
    try:
        worker.wait_for("fake_worker started")
        worker.process.send_signal(signal.SIGTERM)
        worker.wait_for(r'fake_worker kill \{"pod":"worker-1","busy":false,"cost":0,')
        assert worker.exit_code(timeout=3) == 0
    finally:
        worker.stop()


def test_the_collector_stops_on_sigterm(tmp_path: Path) -> None:
    worker = Worker(tmp_path, environment(FAKE_WORKER_MODE="collector"))
    try:
        port = worker.port("collector")
        worker.wait_for("fake_worker started")
        assert request("GET", f"http://127.0.0.1:{port}/kills") == (200, '{"kills":[]}')
        worker.process.send_signal(signal.SIGTERM)
        assert worker.exit_code(timeout=5) == 0
    finally:
        worker.stop()


def test_a_bad_setting_stops_the_worker_before_it_serves(tmp_path: Path) -> None:
    worker = Worker(tmp_path, environment(FAKE_WORKER_STATUS_PORT="http"))
    try:
        assert worker.exit_code(timeout=10) == 1
        assert "FAKE_WORKER_STATUS_PORT must be" in "".join(worker.output)
        assert "listener=" not in "".join(worker.output)
    finally:
        worker.stop()


def test_a_stopped_tree_stops_the_vm(tmp_path: Path) -> None:
    # A test-only process kills the worker's root supervisor, found by the
    # prefix of the name the server registers it under.
    expression = """
        spawn(fun() ->
            Find = fun Find() ->
                Roots = [Pid || Name <- registered(),
                    lists:prefix("fake_worker_root$", atom_to_list(Name)),
                    Pid <- [whereis(Name)], is_pid(Pid)],
                case Roots of [Root] -> Root; _ -> timer:sleep(10), Find() end
            end,
            Root = Find(),
            timer:sleep(200),
            exit(Root, kill)
        end),
    """
    worker = Worker(tmp_path, environment(), expression + MAIN)
    try:
        assert worker.exit_code(timeout=10) == 1
        assert "the supervision tree stopped" in "".join(worker.output)
    finally:
        worker.stop()
