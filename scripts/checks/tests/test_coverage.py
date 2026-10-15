"""Coverage's public command, using real Gleam compilation and OTP cover."""

import json
import os
import shutil
import subprocess
import tempfile
import tomllib
from collections.abc import Iterator
from pathlib import Path

import pytest

from conftest import git

ROOT = Path(__file__).resolve().parents[3]


def prepare(project: Path) -> None:
    """Copy command wiring and pins, without copying the controller or its tests."""
    (project / "scripts/checks").mkdir(parents=True)
    for name in ("coverage.py", "coverage_ffi.erl", "manifest_check.py"):
        shutil.copyfile(ROOT / "scripts/checks" / name, project / "scripts/checks" / name)
    for name in ("gleam.toml", "manifest.toml", "Justfile", ".gitignore"):
        shutil.copyfile(ROOT / name, project / name)
    shutil.copyfile(ROOT / "scripts/cluster-name.sh", project / "scripts/cluster-name.sh")
    for name in (".pixi", ".tools"):
        (project / name).symlink_to(ROOT / name, target_is_directory=True)


def track(project: Path) -> None:
    git(project, "init", "-q")
    (project / ".git/info/exclude").write_text(".pixi\n.tools\n")
    git(project, "add", ".")


@pytest.fixture(scope="session")
def coverage_template() -> Iterator[Path]:
    scratch = ROOT / "ai_tmp"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="coverage-template-", dir=scratch) as directory:
        project = Path(directory)
        prepare(project)
        make_probe(project)
        shutil.copytree(ROOT / "build/packages", project / "build/packages")
        shutil.copytree(ROOT / "build/dev", project / "build/dev")
        # Reuse compiled dependencies, but compile only the tiny probe application.
        shutil.rmtree(project / "build/dev/erlang/knarr")
        result = subprocess.run(
            [str(ROOT / ".pixi/envs/default/bin/just"), "build"],
            cwd=project,
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        yield project


def make_probe(project: Path) -> None:
    (project / "src").mkdir()
    (project / "test/birdie_snapshots").mkdir(parents=True)
    config = project / "gleam.toml"
    config.write_text(
        config.read_text().replace('application_start_module = "application_ffi"\n', "")
    )
    (project / "src/knarr.gleam").write_text("pub fn main() -> Nil { Nil }\n")
    (project / "test/knarr_test.gleam").write_text(
        "import gleeunit\npub fn main() -> Nil { gleeunit.main() }\n"
    )
    (project / "src/coverage_probe.gleam").write_text(
        "pub fn choose(value: Bool) -> Int {\n"
        "  case value {\n"
        "    True -> 11\n"
        "    False -> 22\n"
        "  }\n"
        "}\n"
        "\n"
        '@external(erlang, "probe_ffi", "value")\n'
        "pub fn ffi_value() -> Int\n",
    )
    (project / "src/probe_ffi.erl").write_text(
        "-module(probe_ffi).\n"
        "-export([value/0, unused/0]).\n"
        "value() ->\n"
        "    33.\n"
        "unused() ->\n"
        "    44.\n",
    )
    (project / "test/coverage_probe_test.gleam").write_text(
        "import coverage_probe\n"
        "pub fn exercised_test() {\n"
        "  assert coverage_probe.choose(True) == 11\n"
        "  assert coverage_probe.ffi_value() == 33\n"
        "}\n",
    )

    (project / "test/snapshot_test.gleam").write_text(
        "import birdie\npub fn snapshot_test() {\n"
        '  "application/json" |> birdie.snap(title: "coverage probe")\n}\n'
    )
    manifest = tomllib.loads((project / "manifest.toml").read_text())
    birdie = next(
        package["version"] for package in manifest["packages"] if package["name"] == "birdie"
    )
    (project / "test/birdie_snapshots/coverage_probe.accepted").write_text(
        f"---\nversion: {birdie}\ntitle: coverage probe\n"
        "file: ./test/snapshot_test.gleam\ntest_name: snapshot_test\n---\napplication/json\n"
    )


@pytest.fixture
def coverage_project(coverage_template: Path) -> Iterator[Path]:
    with tempfile.TemporaryDirectory(prefix="coverage-test-", dir=ROOT / "ai_tmp") as directory:
        project = Path(directory)
        shutil.copytree(coverage_template, project, dirs_exist_ok=True, symlinks=True)
        track(project)
        yield project


def forbid_compiler(project: Path) -> None:
    # An executable boundary fake makes any attempted compiler invocation an
    # observable failure, without ever permitting a dependency download.
    tools = project / "fake-bin"
    tools.mkdir()
    gleam = tools / "gleam"
    gleam.write_text("#!/bin/sh\necho UNEXPECTED_COMPILER >&2\nexit 91\n")
    gleam.chmod(0o755)
    text = (project / "Justfile").read_text()
    (project / "Justfile").write_text(
        text.replace(
            "export PATH := ", 'export PATH := justfile_directory() / "fake-bin" + ":" + '
        ),
    )


@pytest.fixture
def preflight_project() -> Iterator[Path]:
    scratch = ROOT / "ai_tmp"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="coverage-preflight-", dir=scratch) as directory:
        project = Path(directory)
        prepare(project)
        packages = project / "build/packages"
        packages.mkdir(parents=True)
        shutil.copyfile(ROOT / "build/packages/packages.toml", packages / "packages.toml")
        manifest = tomllib.loads((project / "manifest.toml").read_text())
        for package in manifest["packages"]:
            (packages / package["name"]).mkdir()
        forbid_compiler(project)
        track(project)
        yield project


@pytest.fixture
def controller_project() -> Iterator[Path]:
    scratch = ROOT / "ai_tmp"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="coverage-controller-", dir=scratch) as directory:
        project = Path(directory)
        prepare(project)
        for name in ("src", "test", "build/packages", "build/dev"):
            shutil.copytree(ROOT / name, project / name)
        track(project)
        yield project


def run_coverage(project: Path, **environment: str) -> subprocess.CompletedProcess[str]:
    baseline = git(project, "status", "--porcelain", "--untracked-files=all")
    diff = git(project, "diff")
    result = subprocess.run(
        [str(ROOT / ".pixi/envs/default/bin/just"), "coverage"],
        cwd=project,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", **environment},
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert git(project, "diff") == diff
    assert git(project, "status", "--porcelain", "--untracked-files=all") == baseline
    return result


def read_report(project: Path) -> dict:
    reports = list((project / "build/coverage").glob("*/coverage.json"))
    assert len(reports) == 1
    return json.loads(reports[0].read_text())


def test_reports_source_lines_and_ffi(coverage_project: Path) -> None:
    result = run_coverage(coverage_project)
    assert result.returncode == 0, result.stdout + result.stderr
    report = read_report(coverage_project)
    files = {entry["path"]: entry for entry in report["files"]}
    probe = files["src/coverage_probe.gleam"]
    assert 3 in probe["covered_lines"]
    assert 4 in probe["uncovered_lines"]
    # Gleam compiles calls to the external directly. Its generated wrapper
    # remains uncalled even though the assertion exercised the FFI below.
    assert 9 in probe["uncovered_lines"]
    assert files["src/probe_ffi.erl"]["covered_lines"] == [4]
    assert files["src/probe_ffi.erl"]["uncovered_lines"] == [6]
    assert all(path.startswith("src/") for path in files)
    assert set(report["totals"]) == {"gleam", "erlang"}
    assert "src/coverage_probe.gleam" in result.stdout


@pytest.mark.parametrize("cache_state", ["missing-directory", "missing-index", "wrong-version"])
def test_missing_cache_fails_before_gleam_can_fetch(
    preflight_project: Path,
    cache_state: str,
) -> None:
    index = preflight_project / "build/packages/packages.toml"
    if cache_state == "missing-directory":
        shutil.rmtree(preflight_project / "build/packages/gleeunit")
    elif cache_state == "missing-index":
        index.unlink()
    else:
        index.write_text(index.read_text().replace('gleeunit = "1.11.0"', 'gleeunit = "0.0.0"'))
    result = run_coverage(preflight_project)
    assert result.returncode != 0
    assert "UNEXPECTED_COMPILER" not in result.stdout + result.stderr
    assert "cached package" in result.stderr


def test_cold_uncalled_and_empty_modules(coverage_project: Path) -> None:
    shutil.rmtree(coverage_project / "build/dev")
    (coverage_project / "src/never_called.gleam").write_text(
        "pub fn unused() -> Int {\n  99\n}\n",
    )
    (coverage_project / "src/types_only.gleam").write_text("pub type Token { Token }\n")
    result = run_coverage(coverage_project)
    assert result.returncode == 0, result.stdout + result.stderr
    files = {entry["path"]: entry for entry in read_report(coverage_project)["files"]}
    assert files["src/never_called.gleam"]["uncovered_lines"] == [2]
    assert files["src/types_only.gleam"]["executable"] == 0
    assert "0/0 (n/a)" in result.stdout


def test_real_controller_startup(controller_project: Path) -> None:
    result = run_coverage(controller_project)
    assert result.returncode == 0, result.stdout + result.stderr
    files = {entry["path"]: entry for entry in read_report(controller_project)["files"]}
    # Instrumentation must begin before the real OTP application callback runs.
    assert 11 in files["src/knarr/application_ffi.erl"]["covered_lines"]


@pytest.mark.parametrize("failure", ["assertion", "snapshot"])
def test_failed_tests_keep_failure_and_report(coverage_project: Path, failure: str) -> None:
    if failure == "assertion":
        source = coverage_project / "test/coverage_probe_test.gleam"
        source.write_text(source.read_text().replace("== 11", "== 12"))
    else:
        # Only some snapshots carry the header, so pick one that does.
        source = next(
            path
            for path in sorted((coverage_project / "test/birdie_snapshots").glob("*.accepted"))
            if "application/json" in path.read_text()
        )
        source.write_text(source.read_text().replace("application/json", "application/jsom"))
    result = run_coverage(coverage_project)
    assert result.returncode != 0
    assert read_report(coverage_project)["test_exit_code"] != 0
    assert "Reports: build/coverage/" in result.stdout


def test_missing_collection_cannot_reuse_a_successful_report(coverage_project: Path) -> None:
    first = run_coverage(coverage_project)
    assert first.returncode == 0, first.stdout + first.stderr
    original = read_report(coverage_project)
    # This valid entrypoint exits zero without running EUnit or its reporters.
    (coverage_project / "test/knarr_test.gleam").write_text("pub fn main() { Nil }\n")
    second = run_coverage(coverage_project)
    assert second.returncode != 0
    assert "collection did not complete" in second.stderr
    assert read_report(coverage_project) == original


def test_repeat_runs_are_isolated_and_leave_git_unchanged(coverage_project: Path) -> None:
    # Comparing to the index also detects untracked/unignored reports.
    baseline = git(coverage_project, "status", "--porcelain", "--untracked-files=all")
    first = run_coverage(coverage_project)
    assert first.returncode == 0, first.stdout + first.stderr
    first_report = read_report(coverage_project)
    second = run_coverage(coverage_project)
    assert second.returncode == 0, second.stdout + second.stderr
    reports = list((coverage_project / "build/coverage").glob("*/coverage.json"))
    assert len(reports) == 2
    assert all(json.loads(path.read_text()) == first_report for path in reports)
    assert git(coverage_project, "diff") == ""
    assert git(coverage_project, "status", "--porcelain", "--untracked-files=all") == baseline


def test_missing_debug_information_fails_collection(coverage_project: Path) -> None:
    (coverage_project / "src/opaque_ffi.erl").write_text(
        "-module(opaque_ffi).\n-compile(no_debug_info).\n-export([value/0]).\nvalue() -> 1.\n",
    )
    # Gleam overrides no_debug_info. Strip the built module at the build
    # command boundary to reproduce a BEAM without cover's required metadata.
    justfile = coverage_project / "Justfile"
    justfile.write_text(
        justfile.read_text().replace(
            "\n# A new or changed snapshot",
            "\n    erl -noshell -eval '{ok, _} = beam_lib:strip(\"build/dev/erlang/knarr/ebin/opaque_ffi.beam\"), halt().'\n"
            "\n# A new or changed snapshot",
            1,
        ),
    )
    result = run_coverage(coverage_project)
    assert result.returncode != 0
    assert "no_abstract_code" in result.stdout + result.stderr
    assert "collection did not complete" in result.stderr
    assert not list((coverage_project / "build/coverage").glob("*/coverage.json"))


def test_drifted_manifest_is_refused_without_rewriting(preflight_project: Path) -> None:
    manifest = preflight_project / "manifest.toml"
    manifest.write_text(
        manifest.read_text().replace(
            'gleeunit = { version = ">= 1.11.0 and < 2.0.0" }',
            'gleeunit = { version = ">= 1.10.0 and < 2.0.0" }',
        )
    )
    result = run_coverage(preflight_project)
    assert result.returncode != 0
    assert "manifest.toml disagrees with gleam.toml" in result.stdout + result.stderr
    assert "UNEXPECTED_COMPILER" not in result.stdout + result.stderr


def test_existing_eunit_options_and_paths_with_spaces(coverage_project: Path) -> None:
    moved = coverage_project / "checkout with spaces"
    moved.mkdir()
    for child in list(coverage_project.iterdir()):
        if child != moved:
            child.rename(moved / child.name)
    result = run_coverage(moved, EUNIT="[{scale_timeouts, 10}]")
    assert result.returncode == 0, result.stdout + result.stderr
    assert read_report(moved)["test_exit_code"] == 0


def test_alternatives_on_one_source_line_count_once(coverage_project: Path) -> None:
    (coverage_project / "src/shared_line.gleam").write_text(
        "pub fn choose(value: Bool) -> Int {\n  case value { True -> 1 False -> 2 }\n}\n",
    )
    (coverage_project / "test/shared_line_test.gleam").write_text(
        "import shared_line\npub fn one_alternative_test() {\n"
        "  assert shared_line.choose(True) == 1\n}\n",
    )
    result = run_coverage(coverage_project)
    assert result.returncode == 0, result.stdout + result.stderr
    files = {entry["path"]: entry for entry in read_report(coverage_project)["files"]}
    assert files["src/shared_line.gleam"]["covered_lines"] == [2]
    assert files["src/shared_line.gleam"]["executable"] == 1
