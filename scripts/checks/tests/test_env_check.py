"""The installed-environment check: the gate refuses tools the pins no longer name.

lock-check compares the lock with its manifest only. After a pull that moves a
pin, the old binaries stay on PATH until `just initialize` reruns, and this
check is what fails the gate in the meantime. It never runs pixi and never
writes. Under KNARR_TOOLS=nix it asks Nix, offline and without touching
flake.lock, what this commit's flake describes, and compares the out-link and
the tools' own versions with that and with pins.toml (Decision 0017); a
stand-in `nix` answers here, so these cases need no Nix.
"""

from __future__ import annotations

import json
import os
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


@pytest.fixture(autouse=True)
def pixi_backend(monkeypatch: pytest.MonkeyPatch) -> None:
    """The pixi cases run under pixi whichever backend the gate was started with."""
    monkeypatch.setenv("KNARR_TOOLS", "pixi")


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
    assert any(name.startswith("erlang-29.1.2-") for name in locked)


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


# ---------------------------------------------------------------- nix ---

PINS = """\
[exact]
erlang = "29.1.2"
gleam = "1.19.0"
allium = "3.6.1"
kind = "0.33.0"
kwokctl = "0.8.0"

[minor]
kubectl = "1.36"

[floor]
rebar3 = "3.28.0"
"""
# What each tool in the default group prints, as the versions in PINS have it.
REPORTS = {
    "gleam": "gleam 1.19.0",
    "erl": "29.1.2",
    "rebar3": "rebar 3.28.0 on Erlang/OTP 29 Erts 17.1.1",
    "allium": "allium 3.6.1",
    "openssl": "OpenSSL 3.5.9 30 Sep 2025 (Library: OpenSSL 3.5.9 30 Sep 2025)",
}


def report(directory: Path, name: str, text: str) -> None:
    (directory / name).write_text(f"#!/bin/sh\nprintf '%s\\n' '{text}'\n")
    (directory / name).chmod(0o755)


@pytest.fixture
def flake(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A project under the Nix backend whose out-link is the environment its flake describes."""
    monkeypatch.setenv("KNARR_TOOLS", "nix")
    project = tmp_path / "project"
    project.mkdir()
    (project / "pins.toml").write_text(PINS)
    environment = tmp_path / "store" / "0000-knarr-tools"
    (environment / "bin").mkdir(parents=True)
    for name, text in REPORTS.items():
        report(environment / "bin", name, text)
    (project / ".nix").mkdir()
    (project / ".nix" / "default").symlink_to(environment)
    describes(tmp_path, environment)
    monkeypatch.setenv("PATH", f"{tmp_path / 'host'}:{os.environ['PATH']}")
    return project


def describes(
    tmp_path: Path,
    out: Path | str,
    openssl: str = "3.5.9",
    status: int = 0,
    cluster: Path | str = "",
) -> None:
    """The stand-in nix: records its arguments and answers with what the flake describes,
    for the default group or, asked for `#cluster`, the cluster group."""
    host = tmp_path / "host"
    host.mkdir(exist_ok=True)
    answer = json.dumps({"out": str(out), "openssl": openssl})
    cluster_answer = json.dumps({"out": str(cluster), "openssl": openssl})
    (host / "nix").write_text(
        "#!/bin/sh\n"
        f'printf "%s\\n" "$*" >> "{tmp_path / "nix-calls"}"\n'
        f"[ {status} = 0 ] || {{ echo 'error: cannot fetch input' >&2; exit {status}; }}\n"
        f"case \"$*\" in *'#cluster '*) printf '%s' '{cluster_answer}' ;;"
        f" *) printf '%s' '{answer}' ;; esac\n"
    )
    (host / "nix").chmod(0o755)


def environment_of(project: Path) -> Path:
    return (project / ".nix" / "default").readlink()


def test_nix_a_matching_out_link_passes(flake: Path, tmp_path: Path) -> None:
    result = check(flake)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "the held versions match" in result.stdout
    assert str(environment_of(flake)) in result.stdout
    (call,) = (tmp_path / "nix-calls").read_text().splitlines()
    assert call.startswith("eval --json --offline --no-update-lock-file ")
    assert f"{flake.resolve()}#default" in call


def test_nix_a_moved_lock_fails_and_says_to_initialize(flake: Path, tmp_path: Path) -> None:
    describes(tmp_path, tmp_path / "store" / "1111-knarr-tools")
    result = check(flake)
    assert result.returncode == 1
    assert f"but this commit describes {tmp_path / 'store' / '1111-knarr-tools'}" in result.stdout
    assert "run just initialize" in result.stdout


def test_nix_a_flake_it_cannot_evaluate_offline_fails_and_says_to_initialize(
    flake: Path, tmp_path: Path
) -> None:
    describes(tmp_path, "", status=1)
    result = check(flake)
    assert result.returncode == 1
    assert "error: cannot fetch input" in result.stdout
    assert "run just initialize" in result.stdout


@pytest.mark.parametrize(
    ("tool", "text", "drift"),
    [
        ("gleam", "gleam 1.19.2", "gleam reports 1.19.2, pins.toml holds 1.19.0"),
        ("erl", "29.1.1", "erlang reports 29.1.1, pins.toml holds 29.1.2"),
        ("allium", "allium 3.6.0", "allium reports 3.6.0, pins.toml holds 3.6.1"),
        ("rebar3", "rebar 3.27.9 on Erlang/OTP 29", "rebar3 reports 3.27.9, below 3.28.0"),
        (
            "openssl",
            "OpenSSL 3.5.8 1 Jul 2025",
            "openssl reports 3.5.8, Erlang is built with 3.5.9",
        ),
    ],
)
def test_nix_a_tool_that_differs_from_its_hold_fails(
    flake: Path, tool: str, text: str, drift: str
) -> None:
    report(environment_of(flake) / "bin", tool, text)
    result = check(flake)
    assert result.returncode == 1
    assert drift in result.stdout
    assert "run just initialize" in result.stdout


def test_nix_rebar3_is_a_floor_not_an_exact_version(flake: Path) -> None:
    report(environment_of(flake) / "bin", "rebar3", "rebar 3.29.0 on Erlang/OTP 29")
    result = check(flake)
    assert result.returncode == 0, result.stdout + result.stderr


def test_nix_a_missing_tool_fails(flake: Path) -> None:
    (environment_of(flake) / "bin" / "allium").unlink()
    result = check(flake)
    assert result.returncode == 1
    assert "allium cannot run" in result.stdout


@pytest.mark.parametrize("state", ["absent", "a directory", "dangling"])
def test_nix_without_an_out_link_into_the_store_it_refuses(
    flake: Path, tmp_path: Path, state: str
) -> None:
    link = flake / ".nix" / "default"
    link.unlink()
    if state == "a directory":
        link.mkdir()
    elif state == "dangling":
        link.symlink_to(tmp_path / "store" / "collected")
    result = check(flake)
    assert result.returncode == 2
    assert "run just initialize" in result.stderr
    assert not (tmp_path / "nix-calls").exists()


# What each tool in the cluster group prints, as the versions in PINS have it.
CLUSTER_REPORTS = {
    "kind": "kind v0.33.0 go1.27.3 linux/arm64",
    "kubectl": "Client Version: v1.36.3",
    "kwokctl": "kwokctl version v0.8.0 go1.27.3 (linux/arm64)",
}


@pytest.fixture
def cluster(flake: Path, tmp_path: Path) -> Path:
    """The flake project with its cluster group installed as this commit describes it."""
    group = tmp_path / "store" / "2222-knarr-cluster-tools"
    (group / "bin").mkdir(parents=True)
    for name, text in CLUSTER_REPORTS.items():
        report(group / "bin", name, text)
    (flake / ".nix" / "cluster").symlink_to(group)
    describes(tmp_path, environment_of(flake), cluster=group)
    return flake


def cluster_of(project: Path) -> Path:
    return (project / ".nix" / "cluster").readlink()


def test_nix_without_the_cluster_group_asks_about_the_default_group_alone(
    flake: Path, tmp_path: Path
) -> None:
    result = check(flake)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "#cluster" not in (tmp_path / "nix-calls").read_text()


def test_nix_an_installed_cluster_group_that_matches_passes(cluster: Path, tmp_path: Path) -> None:
    result = check(cluster)
    assert result.returncode == 0, result.stdout + result.stderr
    assert str(cluster_of(cluster)) in result.stdout
    default, group = (tmp_path / "nix-calls").read_text().splitlines()
    assert f"{cluster.resolve()}#default" in default
    assert group.startswith("eval --json --offline --no-update-lock-file ")
    assert f"{cluster.resolve()}#cluster " in group


def test_nix_a_moved_cluster_group_fails_and_says_to_reinstall_it(
    cluster: Path, tmp_path: Path
) -> None:
    moved = tmp_path / "store" / "3333-knarr-cluster-tools"
    describes(tmp_path, environment_of(cluster), cluster=moved)
    result = check(cluster)
    assert result.returncode == 1
    assert f"{cluster_of(cluster)}, but this commit describes {moved}" in result.stdout
    assert "run just cluster-install" in result.stdout


@pytest.mark.parametrize(
    ("tool", "text", "drift"),
    [
        ("kind", "kind v0.32.0 go1.26 linux/arm64", "kind reports 0.32.0, pins.toml holds 0.33.0"),
        (
            "kubectl",
            "Client Version: v1.37.2",
            "kubectl reports 1.37.2, pins.toml holds minor 1.36",
        ),
        (
            "kwokctl",
            "kwokctl version v0.7.0 go1.26 (linux/arm64)",
            "kwokctl reports 0.7.0, pins.toml holds 0.8.0",
        ),
    ],
)
def test_nix_a_cluster_tool_that_differs_from_its_hold_fails(
    cluster: Path, tool: str, text: str, drift: str
) -> None:
    report(cluster_of(cluster) / "bin", tool, text)
    result = check(cluster)
    assert result.returncode == 1
    assert drift in result.stdout
    assert "run just cluster-install" in result.stdout


def test_nix_kubectl_may_move_within_its_minor(cluster: Path) -> None:
    report(cluster_of(cluster) / "bin", "kubectl", "Client Version: v1.36.9")
    result = check(cluster)
    assert result.returncode == 0, result.stdout + result.stderr


def test_nix_a_missing_cluster_tool_fails(cluster: Path) -> None:
    (cluster_of(cluster) / "bin" / "kwokctl").unlink()
    result = check(cluster)
    assert result.returncode == 1
    assert "kwokctl cannot run" in result.stdout
    assert "run just cluster-install" in result.stdout


def test_nix_a_collected_cluster_group_fails_and_says_to_reinstall_it(
    cluster: Path, tmp_path: Path
) -> None:
    link = cluster / ".nix" / "cluster"
    link.unlink()
    link.symlink_to(tmp_path / "store" / "collected")
    result = check(cluster)
    assert result.returncode == 1
    assert "which is not in the store" in result.stdout
    assert "run just cluster-install" in result.stdout
    assert "#cluster" not in (tmp_path / "nix-calls").read_text()


def test_nix_a_default_group_drift_still_says_to_initialize(cluster: Path, tmp_path: Path) -> None:
    describes(tmp_path, tmp_path / "store" / "1111-knarr-tools", cluster=cluster_of(cluster))
    result = check(cluster)
    assert result.returncode == 1
    assert "run just initialize" in result.stdout


def test_an_unknown_backend_is_refused_by_name(
    project: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("KNARR_TOOLS", "conda")
    result = check(project)
    assert result.returncode == 2
    assert "KNARR_TOOLS is 'conda'" in result.stderr
