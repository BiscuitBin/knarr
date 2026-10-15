"""The installed-environment check: the gate refuses tools the pins no longer name.

lock-check compares pixi.lock with pixi.toml only. After a pull that moves a
pin, the old binaries stay on PATH until `just initialize` reruns, and this
check is what fails the gate in the meantime. It never runs pixi and never
writes.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

import env_check
from conftest import REPOSITORY, run_checker

# The shape pixi 0.81 writes: list items at their key's own indent, and the
# default environment between two others. YAML indents by 2, so the
# indent check is off for the fixture.
# editorconfig-checker-disable
PIXI_LOCK = """\
version: 7
platforms:
- name: linux-64
  virtual-packages:
  - __unix=0=0
- name: osx-arm64
  virtual-packages:
  - __unix=0=0
environments:
  cluster:
    channels:
    - url: https://conda.anaconda.org/conda-forge/
    packages:
      osx-arm64:
      - conda: https://conda.anaconda.org/conda-forge/osx-arm64/kind-0.33.0-h0_0.conda
      - conda: https://conda.anaconda.org/conda-forge/osx-arm64/gleam-1.19.0-h1_0.conda
  default:
    channels:
    - url: https://conda.anaconda.org/conda-forge/
    packages:
      linux-64:
      - conda: https://conda.anaconda.org/conda-forge/linux-64/gleam-1.19.0-h9_0.conda
      osx-arm64:
      - conda: https://conda.anaconda.org/conda-forge/osx-arm64/gleam-1.19.0-h1_0.conda
      - conda: https://conda.anaconda.org/conda-forge/noarch/tzdata-2026a-h0_0.tar.bz2
  runtime:
    channels:
    - url: https://conda.anaconda.org/conda-forge/
    packages:
      osx-arm64:
      - conda: https://conda.anaconda.org/conda-forge/osx-arm64/erlang-29.1.1-h2_0.conda
packages:
- conda: https://conda.anaconda.org/conda-forge/osx-arm64/gleam-1.19.0-h1_0.conda
  sha256: 00
"""
# editorconfig-checker-enable

INSTALLED = ("gleam-1.19.0-h1_0", "tzdata-2026a-h0_0")

TOOLS_TXT = """\
# name version platform url sha256 member
fake 1.0 osx-arm64 https://example.invalid/fake-1.0 {digest} fake
fake 2.0 linux-64 https://example.invalid/fake-2.0 {digest} fake
"""
DIGEST = "a" * 64
STAMP = f"fake 1.0 osx-arm64 https://example.invalid/fake-1.0 {DIGEST} fake\n"


@pytest.fixture
def project(tmp_path: Path) -> Path:
    """A project whose default environment and .tools/bin match its pins on osx-arm64."""
    meta = tmp_path / ".pixi" / "envs" / "default" / "conda-meta"
    meta.mkdir(parents=True)
    (meta / "pixi").write_text(json.dumps({"resolved_platform": {"subdir": "osx-arm64"}}))
    for record in INSTALLED:
        (meta / f"{record}.json").write_text("{}")
    (meta / "history").write_text("")
    (tmp_path / "pixi.lock").write_text(PIXI_LOCK)
    (tmp_path / "tools.txt").write_text(TOOLS_TXT.format(digest=DIGEST))
    tools = tmp_path / ".tools" / "bin"
    (tools / ".pins").mkdir(parents=True)
    (tools / "fake").write_text("#!/bin/sh\n")
    (tools / "fake").chmod(0o755)
    (tools / ".pins" / "fake").write_text(STAMP)
    return tmp_path


def _tree(directory: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(directory)): path.read_bytes()
        for path in directory.rglob("*")
        if path.is_file()
    }


def check(directory: Path, *, cli: bool = False) -> subprocess.CompletedProcess[str]:
    before = _tree(directory)
    result = run_checker("env_check", directory, str(directory), cli=cli)
    assert _tree(directory) == before, "the check must never write"
    return result


def meta(project: Path) -> Path:
    return project / ".pixi" / "envs" / "default" / "conda-meta"


def test_a_matching_installation_passes(project: Path) -> None:
    result = check(project)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "osx-arm64" in result.stdout


def test_an_installed_package_the_lock_moved_off_fails(project: Path) -> None:
    (project / "pixi.lock").write_text(
        PIXI_LOCK.replace("osx-arm64/gleam-1.19.0-h1_0", "osx-arm64/gleam-1.20.0-h1_0")
    )
    result = check(project)
    assert result.returncode == 1
    assert "gleam-1.20.0-h1_0: pinned by pixi.lock, not installed" in result.stdout
    assert "gleam-1.19.0-h1_0: installed, not pinned by pixi.lock" in result.stdout
    assert "just initialize" in result.stdout


def test_an_installed_package_the_lock_dropped_fails(project: Path) -> None:
    (meta(project) / "ruff-0.16.10-h0_0.json").write_text("{}")
    result = check(project)
    assert result.returncode == 1
    assert "ruff-0.16.10-h0_0: installed, not pinned" in result.stdout


def test_other_environments_and_platforms_are_ignored(project: Path) -> None:
    # The cluster, runtime and linux-64 sections name packages osx-arm64's
    # default environment does not install, so reading them would fail here.
    assert env_check.locked(project / "pixi.lock", "osx-arm64") == set(INSTALLED)
    assert env_check.locked(project / "pixi.lock", "linux-64") == {"gleam-1.19.0-h9_0"}


@pytest.mark.parametrize("platform", ["linux-64", "osx-arm64"])
def test_the_committed_lock_is_readable_for_each_platform(platform: str) -> None:
    locked = env_check.locked(REPOSITORY / "pixi.lock", platform)
    assert any(name.startswith("gleam-1.19.0-") for name in locked)
    assert any(name.startswith("erlang-29.1.1-") for name in locked)


@pytest.mark.parametrize(
    ("label", "lock", "named"),
    [
        ("another lock version", PIXI_LOCK.replace("version: 7", "version: 6", 1), "version 7"),
        (
            "a pypi entry",
            PIXI_LOCK.replace(
                "      - conda: https://conda.anaconda.org/conda-forge/noarch/tzdata",
                "      - pypi: https://files.pythonhosted.org/x.whl\n"
                "      - conda: https://conda.anaconda.org/conda-forge/noarch/tzdata",
            ),
            "cannot check",
        ),
        (
            "an unknown archive",
            PIXI_LOCK.replace("tzdata-2026a-h0_0.tar.bz2", "tzdata-2026a-h0_0.zip"),
            "archive",
        ),
        (
            "no packages for the platform",
            PIXI_LOCK.replace(
                "      osx-arm64:\n      - conda: https://conda.anaconda.org/"
                "conda-forge/osx-arm64/gleam-1.19.0-h1_0.conda\n      - conda: https://conda."
                "anaconda.org/conda-forge/noarch/tzdata-2026a-h0_0.tar.bz2\n",
                "",
            ),
            "pins no packages",
        ),
    ],
)
def test_a_lock_the_reader_cannot_read_is_refused(
    project: Path, label: str, lock: str, named: str
) -> None:
    (project / "pixi.lock").write_text(lock)
    result = check(project)
    assert result.returncode == 2, label
    assert named in result.stderr


def test_a_missing_pixi_record_is_refused(project: Path) -> None:
    (meta(project) / "pixi").unlink()
    result = check(project)
    assert result.returncode == 2
    assert "run just initialize" in result.stderr


def test_a_moved_tools_pin_fails(project: Path) -> None:
    (project / "tools.txt").write_text(
        TOOLS_TXT.format(digest=DIGEST).replace("fake 1.0 osx-arm64", "fake 1.1 osx-arm64")
    )
    result = check(project)
    assert result.returncode == 1
    assert "fake: tools.txt pins 1.1, .tools/bin holds 1.0" in result.stdout


def test_a_missing_tool_binary_fails(project: Path) -> None:
    (project / ".tools" / "bin" / "fake").unlink()
    result = check(project)
    assert result.returncode == 1
    assert "fake: tools.txt pins 1.0" in result.stdout


def test_a_tool_without_a_recorded_pin_fails(project: Path) -> None:
    (project / ".tools" / "bin" / ".pins" / "fake").unlink()
    result = check(project)
    assert result.returncode == 1
    assert ".tools/bin holds nothing" in result.stdout


def test_a_malformed_tools_line_is_refused(project: Path) -> None:
    with (project / "tools.txt").open("a") as stream:
        stream.write("broken 1.0 osx-arm64\n")
    result = check(project)
    assert result.returncode == 2
    assert "broken" in result.stderr


def test_a_tool_tools_txt_no_longer_pins_fails(project: Path) -> None:
    # Dropping a tool's lines leaves its binary on PATH until something
    # removes it; install-tools.sh does, from the stamp it left.
    (project / "tools.txt").write_text("# name version platform url sha256 member\n")
    result = check(project)
    assert result.returncode == 1
    assert "fake: tools.txt pins nothing, .tools/bin holds 1.0" in result.stdout
    assert "just initialize" in result.stdout


def test_a_tool_pinned_only_for_another_platform_fails(project: Path) -> None:
    (project / "tools.txt").write_text(
        f"fake 2.0 linux-64 https://example.invalid/fake-2.0 {DIGEST} fake\n"
    )
    result = check(project)
    assert result.returncode == 1
    assert "fake: tools.txt pins nothing, .tools/bin holds 1.0" in result.stdout


def test_a_hidden_file_among_the_pins_is_not_a_stamp(project: Path) -> None:
    # install-tools.sh reads the stamps through a `*` glob, which skips hidden
    # files, so a .DS_Store there names no tool and is never removed.
    (project / ".tools" / "bin" / ".pins" / ".DS_Store").write_bytes(b"\x00\x05\x16\x07\xff")
    result = check(project)
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_stamp_that_is_not_text_is_an_unreadable_pin(project: Path) -> None:
    (project / ".tools" / "bin" / ".pins" / "orphan").write_bytes(b"\xff\xfe")
    result = check(project)
    assert result.returncode == 1, result.stderr
    assert "orphan: tools.txt pins nothing, .tools/bin holds an unreadable pin" in result.stdout


@pytest.mark.parametrize("broken", [False, True])
def test_cli_contract(project: Path, broken: bool) -> None:
    if broken:
        (project / ".tools/bin/fake").unlink()
    result = check(project, cli=True)
    assert result.returncode == int(broken), result.stdout + result.stderr
    assert "fake" in result.stdout if broken else "match the pins" in result.stdout
