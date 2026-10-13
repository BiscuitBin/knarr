"""scripts/prune_runtime.py, which removes perl from the runtime environment the image ships.

The Dockerfile's build stage runs it with the default environment's Python, so
these tests run the script as a separate process on a fake environment.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import REPOSITORY

SCRIPT = REPOSITORY / "scripts/prune_runtime.py"
PERL = "conda-meta/perl-5.32.1-7_hd590300_perl5.json"
ERLANG = "conda-meta/erlang-29.1.1-h1234567_0.json"


def record(env: Path, relative: str, name: str, files: list[str]) -> None:
    path = env / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"name": name, "version": "1", "files": files}))


@pytest.fixture
def env(tmp_path: Path) -> Path:
    root = tmp_path / "runtime"
    for relative in ["bin/perl", "lib/perl5/5.32/core_perl/strict.pm", "bin/erl"]:
        (root / relative).parent.mkdir(parents=True, exist_ok=True)
        (root / relative).write_text("x")
    (root / "bin/perl5.32.1").symlink_to("perl")
    record(
        root,
        PERL,
        "perl",
        ["bin/perl", "bin/perl5.32.1", "lib/perl5/5.32/core_perl/strict.pm", "man/gone.1"],
    )
    record(root, ERLANG, "erlang", ["bin/erl"])
    return root


def prune(env: Path, *packages: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), str(env), *packages],
        capture_output=True,
        text=True,
        check=False,
    )


def test_a_package_loses_its_files_and_its_record_and_nothing_else(env: Path) -> None:
    result = prune(env, "perl")
    assert result.returncode == 0, result.stderr
    assert not (env / "bin/perl").exists()
    assert not (env / "bin/perl5.32.1").is_symlink()
    assert not (env / "lib/perl5/5.32/core_perl/strict.pm").exists()
    assert not (env / PERL).exists()
    assert (env / "bin/erl").exists()
    assert (env / ERLANG).exists()
    assert "perl" in result.stdout


def test_a_package_with_no_record_is_refused(env: Path) -> None:
    result = prune(env, "zlib")
    assert result.returncode != 0
    assert "zlib" in result.stderr


def test_a_package_with_two_records_is_refused_before_anything_is_deleted(env: Path) -> None:
    record(env, "conda-meta/perl-5.40.0-0_perl5.json", "perl", ["bin/perl"])
    result = prune(env, "perl")
    assert result.returncode != 0
    assert "perl" in result.stderr
    assert (env / "bin/perl").exists()


@pytest.mark.parametrize("escape", ["../outside", "/etc/passwd", "bin/../../outside"])
def test_a_listed_path_outside_the_environment_is_refused_before_anything_is_deleted(
    env: Path, escape: str
) -> None:
    outside = env.parent / "outside"
    outside.write_text("keep")
    record(env, PERL, "perl", ["bin/perl", escape])
    result = prune(env, "perl")
    assert result.returncode != 0
    assert escape in result.stderr
    assert outside.exists()
    assert (env / "bin/perl").exists()


def test_every_package_is_checked_before_any_is_pruned(env: Path) -> None:
    result = prune(env, "perl", "zlib")
    assert result.returncode != 0
    assert (env / "bin/perl").exists()


def test_usage_needs_an_environment_and_a_package(env: Path) -> None:
    result = prune(env)
    assert result.returncode != 0
    assert "usage" in result.stderr


def test_the_image_prunes_perl_from_the_runtime_environment_it_ships() -> None:
    dockerfile = (REPOSITORY / "Dockerfile").read_text().splitlines()
    prune_line = (
        "RUN .pixi/envs/default/bin/python -I scripts/prune_runtime.py .pixi/envs/runtime perl"
    )
    assert prune_line in dockerfile
    install = dockerfile.index("RUN pixi install --locked -e default -e runtime")
    runtime_stage = next(i for i, line in enumerate(dockerfile) if line.endswith(" AS runtime"))
    assert install < dockerfile.index(prune_line) < runtime_stage
    assert "!scripts/prune_runtime.py" in (REPOSITORY / ".dockerignore").read_text().splitlines()
