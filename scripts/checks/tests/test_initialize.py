"""scripts/initialize.sh, the first-run command, with every network step stubbed.

It takes its PATH, the tools.txt destination and the Nix out-link from
scripts/tool-dirs.sh. Each stub records its call, so the test sees which copy
of a tool the script ran, what it built and where, without pixi, Nix, hex or
the network.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from conftest import REPOSITORY, selected, tool_directory

SCRIPTS = ("initialize.sh", "install-tools.sh", "install-hooks.sh", "tool-dirs.sh")
HEX = [
    "python3 scripts/checks/manifest_check.py",
    "gleam deps download",
    "python3 scripts/checks/manifest_check.py fixtures/fake_worker",
    "gleam deps download",
    "prek install --overwrite --hook-type pre-commit",
]
MISSING = {"pixi": "pixi is not installed", "nix": "Nix is not installed"}


def stub(directory: Path, name: str, calls: Path, label: str, extra: str = "") -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / name).write_text(f'#!/bin/sh\nprintf "%s\\n" "{label} $*" >> "{calls}"\n{extra}')
    (directory / name).chmod(0o755)


def prepared(repository: Path) -> Path:
    (repository / "scripts").mkdir()
    for name in SCRIPTS:
        shutil.copy(REPOSITORY / "scripts" / name, repository / "scripts" / name)
    (repository / "tools.txt").write_text("# no pins\n")
    for manifest in ("manifest.toml", "fixtures/fake_worker/manifest.toml"):
        (repository / manifest).parent.mkdir(parents=True, exist_ok=True)
        (repository / manifest).write_text("packages = []\n")
    return repository


def initialize(
    repository: Path, tmp_path: Path, environment: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(repository / "scripts" / "initialize.sh")],
        cwd=tmp_path,
        env={**environment, "PATH": f"{tmp_path / 'host'}:{environment['PATH']}"},
        check=False,
        capture_output=True,
        text=True,
    )


def test_pixi_installs_the_lock_and_the_downloads_into_the_last_directory(
    repository: Path, tmp_path: Path
) -> None:
    prepared(repository)
    calls = tmp_path / "calls"
    host = tmp_path / "host"
    # pixi is the one prerequisite on the host. The host's copies of the rest
    # must lose to the checkout's.
    stub(host, "pixi", calls, "pixi")
    for name in ("python3", "gleam", "prek"):
        stub(host, name, calls, f"host-{name}")
        stub(tool_directory(repository, "pixi"), name, calls, name)

    result = initialize(repository, tmp_path, selected("pixi"))

    assert result.returncode == 0, result.stdout + result.stderr
    assert calls.read_text().splitlines() == ["pixi install --locked", *HEX]
    # The installer makes its record directory in the directory it is given.
    assert (repository / ".tools" / "bin" / ".pins").is_dir()


def test_nix_builds_the_default_group_into_the_out_link_and_hooks_through_it(
    repository: Path, tmp_path: Path
) -> None:
    prepared(repository)
    calls = tmp_path / "calls"
    host = tmp_path / "host"
    # Nix is the one prerequisite on the host, and pixi must never run.
    stub(host, "nix", calls, "nix")
    stub(host, "pixi", calls, "pixi")
    bin_dir = tool_directory(repository, "nix")
    for name in ("python3", "gleam"):
        stub(host, name, calls, f"host-{name}")
        stub(bin_dir, name, calls, name)
    # A prek that writes the hook Nix's prek writes: its own store path.
    store = "/nix/store/00000000000000000000000000000000-prek-0.5.10/bin/prek"
    writes_hook = (
        "hook=$(git rev-parse --path-format=absolute --git-path hooks/pre-commit)\n"
        f"printf '%s\\n' '#!/bin/sh' 'PREK=\"{store}\"' 'exec \"$PREK\" hook-impl' > \"$hook\"\n"
    )
    stub(bin_dir, "prek", calls, "prek", writes_hook)

    result = initialize(repository, tmp_path, selected("nix"))

    assert result.returncode == 0, result.stdout + result.stderr
    outlink = repository.resolve() / ".nix" / "default"
    assert calls.read_text().splitlines() == [
        f"nix build --no-update-lock-file --out-link {outlink} .#default",
        *HEX,
    ]
    assert not (repository / ".tools").exists()
    hook = (repository / ".git" / "hooks" / "pre-commit").read_text().splitlines()
    assert [line for line in hook if line.startswith("PREK=")] == [f'PREK="{outlink}/bin/prek"']


@pytest.mark.parametrize("backend", ["pixi", "nix"])
def test_without_the_backends_installer_it_says_what_to_install(
    repository: Path, tmp_path: Path, backend: str
) -> None:
    prepared(repository)
    (tmp_path / "host").mkdir()
    result = initialize(repository, tmp_path, selected(backend))
    assert result.returncode == 2
    assert result.stderr.startswith(MISSING[backend])


def test_an_unknown_backend_is_refused_by_name_before_anything_runs(
    repository: Path, tmp_path: Path
) -> None:
    prepared(repository)
    calls = tmp_path / "calls"
    for name in ("pixi", "nix"):
        stub(tmp_path / "host", name, calls, name)
    result = initialize(repository, tmp_path, selected("conda"))
    assert result.returncode == 2
    assert result.stderr == (
        "KNARR_TOOLS is 'conda'; set it to pixi or nix, or leave it unset for pixi\n"
    )
    assert not calls.exists()
