"""The Allium CLI gate judges reports, including diagnostics hidden by status 0."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

import run_allium
from conftest import run_checker


def install_fake(repository: Path, output: str, status: int = 0, version: str = "3.6.1") -> None:
    """Stand in for the external binary, using its version and report protocol."""
    binary = repository / ".tools/bin/allium"
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        f"if sys.argv[1:] == ['--version']:\n    print('allium {version}')\n"
        f"else:\n    print({output!r})\n    sys.exit({status})\n"
    )
    binary.chmod(0o755)
    (repository / "allium-response.json").write_text(json.dumps([output, status, version]))
    (repository / "tools.txt").write_text(
        "".join(
            f"allium 3.6.1 {platform} https://example.invalid/allium {'a' * 64} allium\n"
            for platform in ("linux-64", "osx-arm64")
        )
    )
    (repository / "checks.toml").write_text('[allium]\nspecs = "specifications"\n')
    specs = repository / "specifications"
    specs.mkdir(exist_ok=True)
    (specs / "root.allium").write_text("-- A skeleton.\n")


def run(
    repository: Path, command: str = "check", *arguments: str, cli: bool = False
) -> subprocess.CompletedProcess[str]:
    if cli:
        return run_checker("run_allium", repository, command, *arguments, cli=True)
    output, status, version = json.loads((repository / "allium-response.json").read_text())

    def execute(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess:
        binary = repository / ".tools/bin/allium"
        assert argv[0] == str(binary)
        if not binary.exists():
            raise FileNotFoundError(binary)
        if argv[1:] == ["--version"]:
            return subprocess.CompletedProcess(argv, 0, f"allium {version}\n", "")
        assert argv[1:] == [command, arguments[0] if arguments else "specifications"]
        stdout, stderr = output + "\n", ""
        if not kwargs.get("text"):
            stdout, stderr = stdout.encode(), stderr.encode()
        return subprocess.CompletedProcess(argv, status, stdout, stderr)

    # Patch this adapter's boundary only; Git root discovery stays real.
    with patch.object(run_allium, "subprocess", SimpleNamespace(run=execute)):
        return run_checker("run_allium", repository, command, *arguments)


def test_info_diagnostic_fails_even_when_allium_exits_zero(repository: Path) -> None:
    install_fake(
        repository,
        json.dumps(
            {
                "spec_file": "specifications/root.allium",
                "diagnostics": [{"severity": "info", "message": "unused field"}],
                "findings": [],
            }
        ),
    )
    result = run(repository)
    assert result.returncode == 1
    assert "1 diagnostic" in result.stderr


def test_plan_reports_the_obligation_count(repository: Path) -> None:
    install_fake(repository, json.dumps({"diagnostics": [], "obligations": [{}, {}]}))
    result = run(repository, "plan", "specifications/root.allium")
    assert result.returncode == 0, result.stderr
    assert "2 obligations" in result.stdout


@pytest.mark.parametrize("command", ["check", "analyse"])
@pytest.mark.parametrize("kind", ["diagnostics", "findings"])
def test_any_reported_issue_fails(repository: Path, command: str, kind: str) -> None:
    report = {"spec_file": "specifications/root.allium", "diagnostics": [], "findings": []}
    report[kind] = [{"message": "broken", "summary": "unreachable"}]
    install_fake(repository, json.dumps(report))
    result = run(repository, command)
    assert result.returncode == 1
    assert "must report none" in result.stderr


@pytest.mark.parametrize(
    ("output", "status"),
    [
        ("", 0),
        ("not JSON", 0),
        ("[]", 0),
        ('{"spec_file": "specifications/root.allium", "diagnostics": []}', 0),
        ('{"spec_file": "specifications/root.allium", "findings": []}', 0),
        (json.dumps({"spec_file": "elsewhere.allium", "diagnostics": [], "findings": []}), 0),
        (
            json.dumps(
                {"spec_file": "specifications/root.allium", "diagnostics": [], "findings": []}
            ),
            2,
        ),
        (
            json.dumps(
                {"spec_file": "specifications/root.allium", "diagnostics": [], "findings": []}
            ),
            1,
        ),
        (
            json.dumps(
                {"spec_file": "specifications/root.allium", "diagnostics": None, "findings": []}
            ),
            0,
        ),
        (
            json.dumps(
                {"spec_file": "specifications/root.allium", "diagnostics": [], "findings": {}}
            ),
            0,
        ),
    ],
)
def test_unjudgeable_reports_fail(repository: Path, output: str, status: int) -> None:
    install_fake(repository, output, status)
    result = run(repository)
    assert result.returncode == 1
    assert "run_allium:" in result.stderr
    assert "Traceback" not in result.stderr


def test_recursive_modules_and_back_to_back_reports_pass(repository: Path) -> None:
    install_fake(
        repository,
        "\n".join(
            json.dumps(
                {
                    "spec_file": name,
                    "diagnostics": [],
                    "findings": [],
                }
            )
            for name in (
                "specifications/root.allium",
                str(repository / "specifications/sub/child.allium"),
            )
        ),
    )
    sub = repository / "specifications/sub"
    sub.mkdir()
    (sub / "child.allium").write_text("-- allium: 3\n")
    assert run(repository).returncode == 0
    (sub / "omitted.allium").write_text("-- allium: 3\n")
    assert run(repository).returncode == 1


@pytest.mark.parametrize("version", ["3.6.0", "missing"])
def test_missing_or_wrong_binary_requires_initialize(repository: Path, version: str) -> None:
    install_fake(repository, "", version=version)
    if version == "missing":
        (repository / ".tools/bin/allium").unlink()
    result = run(repository, cli=True)
    assert result.returncode == 1
    assert "run just initialize" in result.stderr


@pytest.mark.parametrize(
    "report",
    [
        {"obligations": []},
        {"diagnostics": [], "obligations": None},
        {"diagnostics": [{"message": "bad spec"}], "obligations": []},
    ],
)
def test_plan_refuses_invalid_reports(repository: Path, report: dict) -> None:
    install_fake(repository, json.dumps(report))
    result = run(repository, "plan", "specifications/root.allium")
    assert result.returncode == 1
    assert "0 obligations" not in result.stdout


@pytest.mark.parametrize("command", ["check", "analyse", "plan"])
@pytest.mark.parametrize("broken", [False, True])
def test_cli_reports(repository: Path, command: str, broken: bool) -> None:
    report = {
        "spec_file": "specifications/root.allium",
        "diagnostics": [],
        "findings": [],
        "obligations": [{}],
    }
    if broken:
        report["diagnostics"] = [{"message": "broken"}]
    install_fake(repository, json.dumps(report))
    arguments = ("specifications/root.allium",) if command == "plan" else ()
    result = run(repository, command, *arguments, cli=True)
    assert result.returncode == int(broken), result.stdout + result.stderr
    if broken:
        assert ("plan failed" if command == "plan" else "broken") in result.stderr
    else:
        assert "allium" in result.stdout


@pytest.mark.parametrize("arguments", [("plan",), ("check", "extra.allium"), ("unknown",)])
def test_cli_rejects_invalid_arguments(repository: Path, arguments: tuple[str, ...]) -> None:
    result = run_checker("run_allium", repository, *arguments, cli=True)
    assert result.returncode == 2
    assert "usage:" in result.stderr
