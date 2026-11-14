"""scripts/with-env.sh, which every prek hook entry runs through.

Git runs hooks without the Justfile's PATH. Without the selected backend's
environment every tool would resolve to an unpinned system copy, so the wrapper
refuses instead, and it refuses an unknown KNARR_TOOLS before any hook runs.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from conftest import REPOSITORY, selected, tool_directory

WRAPPER = REPOSITORY / "scripts" / "with-env.sh"


def checkout(tmp_path: Path, backend: str, *, initialized: bool) -> Path:
    root = tmp_path / "checkout"
    (root / "scripts").mkdir(parents=True)
    for script in (WRAPPER, WRAPPER.with_name("tool-dirs.sh")):
        shutil.copy(script, root / "scripts" / script.name)
    if initialized:
        bin_dir = tool_directory(root, backend)
        bin_dir.mkdir(parents=True)
        (bin_dir / "python3").write_text("#!/bin/sh\n")
        (bin_dir / "python3").chmod(0o755)
        (bin_dir / "probe").write_text('#!/bin/sh\necho "env tool: $PYTHONDONTWRITEBYTECODE"\n')
        (bin_dir / "probe").chmod(0o755)
    return root


def run(root: Path, backend: str, *command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(root / "scripts" / "with-env.sh"), *command],
        cwd=root,
        env=selected(backend),
        check=False,
        capture_output=True,
        text=True,
    )


def test_an_uninitialized_checkout_is_refused(tmp_path: Path, backend: str) -> None:
    result = run(checkout(tmp_path, backend, initialized=False), backend, "true")
    assert result.returncode == 2
    assert f"the {backend} environment is missing" in result.stderr
    assert "run just initialize" in result.stderr


def test_the_environment_comes_first_on_a_bare_path(tmp_path: Path, backend: str) -> None:
    result = run(checkout(tmp_path, backend, initialized=True), backend, "probe")
    assert result.returncode == 0, result.stderr
    assert result.stdout == "env tool: 1\n"


def test_an_unknown_backend_is_refused_by_name_before_the_command_runs(tmp_path: Path) -> None:
    root = checkout(tmp_path, "pixi", initialized=True)
    result = run(root, "conda", "probe")
    assert (result.returncode, result.stdout) == (2, "")
    assert result.stderr == (
        "KNARR_TOOLS is 'conda'; set it to pixi or nix, or leave it unset for pixi\n"
    )
