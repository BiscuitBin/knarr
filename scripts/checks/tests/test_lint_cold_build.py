"""Lint must work before any application modules have been compiled."""

import os
import shutil
import subprocess
from pathlib import Path

from conftest import REPOSITORY


def project(tmp_path: Path) -> Path:
    for name in ["src", "test", "scripts/checks"]:
        shutil.copytree(REPOSITORY / name, tmp_path / name)
    for name in ["Justfile", "gleam.toml", "manifest.toml"]:
        shutil.copy2(REPOSITORY / name, tmp_path / name)
    shutil.copy2(REPOSITORY / "scripts/cluster-name.sh", tmp_path / "scripts/cluster-name.sh")
    # Reuse downloaded source packages, never compiled application artifacts.
    shutil.copytree(REPOSITORY / "build/packages", tmp_path / "build/packages")
    return tmp_path


def lint(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["just", "lint-gleam"],
        cwd=root,
        env={**os.environ, "ERL_FLAGS": ""},
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def test_lint_builds_application_from_cold_dependencies(tmp_path: Path) -> None:
    root = project(tmp_path)
    before = (root / "manifest.toml").read_bytes()
    result = lint(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "No issues found." in result.stdout
    assert (root / "manifest.toml").read_bytes() == before


def test_build_failure_stops_before_linter_runs(tmp_path: Path) -> None:
    root = project(tmp_path)
    shutil.copytree(REPOSITORY / "build/dev", root / "build/dev")
    (root / "src/broken.gleam").write_text("pub fn broken() { missing_function() }\n")
    result = lint(root)
    assert result.returncode != 0
    assert "missing_function" in result.stderr
    assert "run_glinter.sh" not in result.stderr
