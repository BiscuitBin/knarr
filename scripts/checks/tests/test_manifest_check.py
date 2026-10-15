"""The manifest.toml pre-check (Decision 0003, Verify 5).

gleam rewrites manifest.toml and exits 0 whenever its [requirements] table
disagrees with gleam.toml. The pre-check refuses each such disagreement before
any gleam command runs, and never writes. The cases are 0003's.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from conftest import run_checker

GLEAM_TOML = """\
name = "probe"
version = "1.0.0"

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
prometheus = { version = ">= 6.1.3 and < 7.0.0" }

[dev_dependencies]
gleeunit = ">= 1.11.0 and < 2.0.0"
"""

MANIFEST_TOML = """\
# Do not manually edit this file, it is managed by Gleam.

packages = [
    { name = "gleam_stdlib", version = "1.0.5", build_tools = ["gleam"], requirements = [], otp_app = "gleam_stdlib", source = "hex", outer_checksum = "00" },
]

[requirements]
gleam_stdlib = { version = ">= 1.0.0 and < 2.0.0" }
gleeunit = { version = ">= 1.11.0 and < 2.0.0" }
prometheus = { version = ">= 6.1.3 and < 7.0.0" }
"""


def project(tmp_path: Path, gleam: str = GLEAM_TOML, manifest: str = MANIFEST_TOML) -> Path:
    (tmp_path / "gleam.toml").write_text(gleam)
    (tmp_path / "manifest.toml").write_text(manifest)
    return tmp_path


def check(directory: Path, *, cli: bool = False) -> subprocess.CompletedProcess[str]:
    before = {p.name: p.read_bytes() for p in directory.iterdir()}
    result = run_checker("manifest_check", directory, str(directory), cli=cli)
    after = {p.name: p.read_bytes() for p in directory.iterdir()}
    assert after == before, "the pre-check must never write"
    return result


def test_agreeing_files_pass(tmp_path: Path) -> None:
    result = check(project(tmp_path))
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_hyphenated_dev_table_spelling_is_read(tmp_path: Path) -> None:
    gleam = GLEAM_TOML.replace("[dev_dependencies]", "[dev-dependencies]")
    assert check(project(tmp_path, gleam=gleam)).returncode == 0


@pytest.mark.parametrize(
    ("label", "gleam", "manifest", "named"),
    [
        (
            "widened range",
            GLEAM_TOML.replace(">= 6.1.3 and < 7.0.0", ">= 6.0.0 and < 7.0.0"),
            MANIFEST_TOML,
            "prometheus",
        ),
        (
            "dropped dependency",
            GLEAM_TOML.replace('prometheus = { version = ">= 6.1.3 and < 7.0.0" }\n', ""),
            MANIFEST_TOML,
            "prometheus",
        ),
        (
            "added dependency",
            GLEAM_TOML + 'gleam_json = ">= 3.0.0 and < 4.0.0"\n',
            MANIFEST_TOML,
            "gleam_json",
        ),
        (
            "stale manifest requirements",
            GLEAM_TOML,
            MANIFEST_TOML.replace(
                'prometheus = { version = ">= 6.1.3 and < 7.0.0" }',
                'prometheus = { version = ">= 6.1.0 and < 7.0.0" }',
            ),
            "prometheus",
        ),
    ],
)
def test_every_disagreement_is_refused_without_writing(
    tmp_path: Path, label: str, gleam: str, manifest: str, named: str
) -> None:
    result = check(project(tmp_path, gleam=gleam, manifest=manifest))
    assert result.returncode == 1, label
    assert named in result.stdout
    assert "gleam deps download" in result.stdout


def test_a_dependency_in_both_dev_spellings_is_refused(tmp_path: Path) -> None:
    gleam = GLEAM_TOML + '\n[dev-dependencies]\nqcheck = ">= 1.0.0 and < 2.0.0"\n'
    result = check(project(tmp_path, gleam=gleam))
    assert result.returncode == 2
    assert "dev_dependencies" in result.stderr


def test_a_missing_manifest_is_refused(tmp_path: Path) -> None:
    (tmp_path / "gleam.toml").write_text(GLEAM_TOML)
    result = check(tmp_path)
    assert result.returncode == 2
    assert "manifest.toml" in result.stderr


@pytest.mark.parametrize("broken", [False, True])
def test_cli_contract(tmp_path: Path, broken: bool) -> None:
    root = project(tmp_path)
    if broken:
        (root / "manifest.toml").unlink()
    result = check(root, cli=True)
    assert result.returncode == (2 if broken else 0), result.stderr
    assert "missing" in result.stderr if broken else "matches gleam.toml" in result.stdout
