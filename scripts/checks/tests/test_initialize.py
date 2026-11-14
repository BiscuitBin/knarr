"""scripts/initialize.sh, the first-run command, with every network step stubbed.

It takes its PATH and the tools.txt destination from scripts/tool-dirs.sh. Each
stub records its call, so the test sees which copy of a tool the script ran and
where the installer was pointed, without pixi, hex or the network.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import _tools
from conftest import REPOSITORY, tool_directory

SCRIPTS = ("initialize.sh", "install-tools.sh", "install-hooks.sh", "tool-dirs.sh")


def stub(directory: Path, name: str, calls: Path, label: str) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / name).write_text(f'#!/bin/sh\nprintf "%s\\n" "{label} $*" >> "{calls}"\n')
    (directory / name).chmod(0o755)


def test_initialize_runs_the_project_tools_and_installs_into_the_last_directory(
    repository: Path, tmp_path: Path
) -> None:
    (repository / "scripts").mkdir()
    for name in SCRIPTS:
        shutil.copy(REPOSITORY / "scripts" / name, repository / "scripts" / name)
    (repository / "tools.txt").write_text("# no pins\n")
    for manifest in ("manifest.toml", "fixtures/fake_worker/manifest.toml"):
        (repository / manifest).parent.mkdir(parents=True, exist_ok=True)
        (repository / manifest).write_text("packages = []\n")
    calls = tmp_path / "calls"
    host = tmp_path / "host"
    # pixi is the one prerequisite on the host. The host's copies of the rest
    # must lose to the checkout's.
    stub(host, "pixi", calls, "pixi")
    for name in ("python3", "gleam", "prek"):
        stub(host, name, calls, f"host-{name}")
        stub(tool_directory(repository), name, calls, name)

    result = subprocess.run(
        ["sh", str(repository / "scripts" / "initialize.sh")],
        cwd=tmp_path,
        env={"PATH": f"{host}:/usr/bin:/bin"},
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert calls.read_text().splitlines() == [
        "pixi install --locked",
        "python3 scripts/checks/manifest_check.py",
        "gleam deps download",
        "python3 scripts/checks/manifest_check.py fixtures/fake_worker",
        "gleam deps download",
        "prek install --overwrite --hook-type pre-commit",
    ]
    # The installer makes its record directory in the directory it is given.
    assert (_tools.directories(repository)[-1] / ".pins").is_dir()
