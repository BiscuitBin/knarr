"""Shared fixtures for the gate checkers' tests.

The checkers run as `python3 scripts/checks/<name>.py` and import `_project` as
a sibling module, so the tests put that directory on the import path the same
way. Most cases call main directly; CLI smoke tests retain the interpreter boundary.
"""

from __future__ import annotations

import importlib
import io
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import pytest

CHECKS = Path(__file__).resolve().parent.parent
REPOSITORY = CHECKS.parent.parent
sys.path.insert(0, str(CHECKS))


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
