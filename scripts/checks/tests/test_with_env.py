"""scripts/with-env.sh, which every prek hook entry runs through.

Git runs hooks without the Justfile's PATH. Without the pixi environment every
tool would resolve to an unpinned system copy, so the wrapper refuses instead.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from conftest import REPOSITORY, tool_directory

WRAPPER = REPOSITORY / "scripts" / "with-env.sh"


def checkout(tmp_path: Path, *, initialized: bool) -> Path:
    root = tmp_path / "checkout"
    (root / "scripts").mkdir(parents=True)
    for script in (WRAPPER, WRAPPER.with_name("tool-dirs.sh")):
        shutil.copy(script, root / "scripts" / script.name)
    if initialized:
        bin_dir = tool_directory(root)
        bin_dir.mkdir(parents=True)
        (bin_dir / "python3").write_text("#!/bin/sh\n")
        (bin_dir / "python3").chmod(0o755)
        (bin_dir / "probe").write_text('#!/bin/sh\necho "env tool: $PYTHONDONTWRITEBYTECODE"\n')
        (bin_dir / "probe").chmod(0o755)
    return root


def run(root: Path, *command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(root / "scripts" / "with-env.sh"), *command],
        cwd=root,
        env={"PATH": "/usr/bin:/bin"},
        check=False,
        capture_output=True,
        text=True,
    )


def test_an_uninitialized_checkout_is_refused(tmp_path: Path) -> None:
    result = run(checkout(tmp_path, initialized=False), "true")
    assert result.returncode == 2
    assert "run just initialize" in result.stderr


def test_the_environment_comes_first_on_a_bare_path(tmp_path: Path) -> None:
    result = run(checkout(tmp_path, initialized=True), "probe")
    assert result.returncode == 0, result.stderr
    assert result.stdout == "env tool: 1\n"
