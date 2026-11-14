"""Shared fixtures for the gate checkers' tests.

The checkers run as `python3 scripts/checks/<name>.py` and import `_project` as
a sibling module, so the tests put that directory on the import path the same
way. Most cases call main directly; CLI smoke tests retain the interpreter boundary.
"""

from __future__ import annotations

import importlib
import io
import os
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import pytest

CHECKS = Path(__file__).resolve().parent.parent
REPOSITORY = CHECKS.parent.parent
sys.path.insert(0, str(CHECKS))


# The two values of KNARR_TOOLS while both backends exist (Decision 0017).
BACKENDS = ("pixi", "nix")


def selected(backend: str | None) -> dict[str, str]:
    """The environment a scratch-checkout test runs a script with: a bare PATH and a backend.

    Without a backend the test inherits the caller's, as the gate's checkers do.
    """
    environment = {"PATH": "/usr/bin:/bin"}
    if backend is not None:
        environment["KNARR_TOOLS"] = backend
    elif "KNARR_TOOLS" in os.environ:
        environment["KNARR_TOOLS"] = os.environ["KNARR_TOOLS"]
    return environment


def tool_directory(checkout: Path, backend: str | None = None) -> Path:
    """Where a test plants a stand-in tool: the first of the checkout's tool directories.

    Without a backend it is the caller's, so a stand-in lands where the checker
    under test, which inherits the caller's environment, will look.
    """
    if backend is None:
        return importlib.import_module("_tools").directories(checkout)[0]
    result = subprocess.run(
        ["sh", str(CHECKS.parent / "tool-dirs.sh"), "dirs", str(checkout)],
        env=selected(backend),
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(result.stdout.split(":", 1)[0])


@pytest.fixture(params=BACKENDS)
def backend(request: pytest.FixtureRequest) -> str:
    """Each backend in turn, for a test that pins the one its scripts run under."""
    return request.param


def git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments], check=True, capture_output=True, text=True
    )
    return result.stdout


@pytest.fixture
def repository(tmp_path: Path) -> Path:
    """An empty Git repository with an identity, so tests can commit in it."""
    path = tmp_path / "repository"
    path.mkdir()
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.name", "test")
    git(path, "config", "user.email", "test@example.invalid")
    git(path, "config", "commit.gpgsign", "false")
    return path


def run_checker(
    name: str, directory: Path, *arguments: str, cli: bool = False
) -> subprocess.CompletedProcess[str]:
    """Exercise an entrypoint with isolated argv, cwd and captured diagnostics."""
    command = [sys.executable, str(CHECKS / f"{name}.py"), *arguments]
    if cli:
        return subprocess.run(command, cwd=directory, capture_output=True, text=True, check=False)
    stdout, stderr = io.StringIO(), io.StringIO()
    with pytest.MonkeyPatch.context() as patch, redirect_stdout(stdout), redirect_stderr(stderr):
        patch.chdir(directory)
        patch.setattr(sys, "argv", command[1:])
        patch.setattr(sys, "dont_write_bytecode", True)
        module = importlib.import_module(name)
        try:
            status = module.main()
        except SystemExit as error:
            if error.code is None or isinstance(error.code, int):
                status = error.code or 0
            else:
                print(error.code, file=sys.stderr)
                status = 1
    return subprocess.CompletedProcess(command, status, stdout.getvalue(), stderr.getvalue())
