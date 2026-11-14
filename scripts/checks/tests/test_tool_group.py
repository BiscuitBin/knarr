"""scripts/tool-group.sh, which installs and guards the optional tool groups.

The cluster group (kind, kubectl and, under Nix, kwokctl) and the audit group
(grype) stay out of `just initialize`, as pixi's optional environments do
(Decisions 0007, 0014 and 0017). `just cluster-install` and `just
audit-install` install one into the selected backend's prefix, and every
cluster and audit recipe's guard asks whether it is there. A CI runner ships
its own kind and kubectl, so the guard looks in the group, never on PATH.
Each case runs the real script with stand-in installers and tools.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

import _tools
import checker_suite
from conftest import REPOSITORY, selected

SCRIPTS = ("tool-group.sh", "tool-dirs.sh", "cluster-name.sh")
GROUPS = ("cluster", "audit")
# What each backend's group must hold. Under pixi, kwokctl is a tools.txt
# download that `just initialize` installs, so the cluster environment has none.
MEMBERS = {
    ("pixi", "cluster"): ("kind", "kubectl"),
    ("nix", "cluster"): ("kind", "kubectl", "kwokctl"),
    ("pixi", "audit"): ("grype",),
    ("nix", "audit"): ("grype",),
}
PREFIX = {"pixi": (".pixi", "envs"), "nix": (".nix",)}
USAGE = "usage: tool-group.sh install|check cluster|audit\n"
REFUSAL = "KNARR_TOOLS is 'conda'; set it to pixi or nix, or leave it unset for pixi\n"


def checkout(tmp_path: Path) -> Path:
    """A checkout with the Justfile and the scripts the group recipes run."""
    root = (tmp_path / "checkout").resolve()
    (root / "scripts").mkdir(parents=True)
    shutil.copy(REPOSITORY / "Justfile", root / "Justfile")
    for name in SCRIPTS:
        shutil.copy(REPOSITORY / "scripts" / name, root / "scripts" / name)
    return root


def prefix(root: Path, backend: str, group: str) -> Path:
    return root.joinpath(*PREFIX[backend], group)


def stub(directory: Path, name: str, calls: Path | None = None) -> None:
    """An executable that records its working directory and arguments."""
    directory.mkdir(parents=True, exist_ok=True)
    record = f'printf "%s\\n" "$(pwd -P): {name} $*" >> "{calls}"\n' if calls else ""
    (directory / name).write_text(f"#!/bin/sh\n{record}")
    (directory / name).chmod(0o755)


def host(tmp_path: Path, *names: str, calls: Path | None = None) -> dict[str, str]:
    """The environment with stand-ins for `names` on the host's PATH, after /usr/bin:/bin."""
    directory = tmp_path / "host"
    directory.mkdir(exist_ok=True)
    for name in names:
        stub(directory, name, calls)
    return {"PATH": f"/usr/bin:/bin:{directory}"}


def group(
    root: Path, *arguments: str, backend: str | None, environment: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    env = {**selected(backend), **(environment or {})}
    if backend is None:
        env.pop("KNARR_TOOLS", None)
    return subprocess.run(
        ["sh", str(root / "scripts" / "tool-group.sh"), *arguments],
        cwd="/",
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )


def just(
    root: Path, *arguments: str, backend: str, environment: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(_tools.tool(REPOSITORY, "just")), *arguments],
        cwd=root,
        env={**environment, "KNARR_TOOLS": backend},
        check=False,
        capture_output=True,
        text=True,
    )


# ---------------------------------------------------------------- check ---


@pytest.mark.parametrize("name", GROUPS)
def test_check_passes_silently_once_the_group_holds_its_tools(
    tmp_path: Path, backend: str, name: str
) -> None:
    root = checkout(tmp_path)
    for tool in MEMBERS[backend, name]:
        stub(prefix(root, backend, name) / "bin", tool)
    result = group(root, "check", name, backend=backend)
    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")


@pytest.mark.parametrize("name", GROUPS)
def test_check_refuses_a_missing_group_whatever_the_host_has(
    tmp_path: Path, backend: str, name: str
) -> None:
    """A CI runner has kind and kubectl of its own; they never stand in for the group."""
    root = checkout(tmp_path)
    environment = host(tmp_path, "kind", "kubectl", "kwokctl", "grype")
    result = group(root, "check", name, backend=backend, environment=environment)
    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr == f"the {backend} {name} group is not installed; run just {name}-install\n"
    )


@pytest.mark.parametrize(("backend", "name"), list(MEMBERS))
def test_check_refuses_a_group_missing_any_one_tool(
    tmp_path: Path, backend: str, name: str
) -> None:
    root = checkout(tmp_path)
    members = MEMBERS[backend, name]
    for missing in members:
        bin_dir = prefix(root, backend, name) / "bin"
        shutil.rmtree(bin_dir, ignore_errors=True)
        bin_dir.mkdir(parents=True)
        for tool in members:
            if tool != missing:
                stub(bin_dir, tool)
        # Present but not executable is missing too.
        (bin_dir / missing).write_text("#!/bin/sh\n")
        result = group(root, "check", name, backend=backend)
        assert result.returncode == 2, missing
        assert f"run just {name}-install" in result.stderr


def test_check_follows_the_tracked_default(tmp_path: Path) -> None:
    root = checkout(tmp_path)
    for tool in MEMBERS["pixi", "cluster"]:
        stub(prefix(root, "pixi", "cluster") / "bin", tool)
    assert group(root, "check", "cluster", backend=None).returncode == 0
    assert group(root, "check", "cluster", backend="nix").returncode == 2


# -------------------------------------------------------------- install ---


@pytest.mark.parametrize("name", GROUPS)
def test_pixi_installs_the_locked_environment(tmp_path: Path, name: str) -> None:
    root = checkout(tmp_path)
    calls = tmp_path / "calls"
    environment = host(tmp_path, "pixi", "nix", calls=calls)
    result = group(root, "install", name, backend="pixi", environment=environment)
    assert result.returncode == 0, result.stderr
    assert calls.read_text().splitlines() == [f"{root}: pixi install --locked -e {name}"]


@pytest.mark.parametrize("name", GROUPS)
def test_nix_builds_the_group_into_its_out_link_without_touching_the_lock(
    tmp_path: Path, name: str
) -> None:
    root = checkout(tmp_path)
    calls = tmp_path / "calls"
    environment = host(tmp_path, "pixi", "nix", calls=calls)
    result = group(root, "install", name, backend="nix", environment=environment)
    assert result.returncode == 0, result.stderr
    outlink = prefix(root, "nix", name)
    assert calls.read_text().splitlines() == [
        f"{root}: nix build --no-update-lock-file --out-link {outlink} .#{name}"
    ]
    # Nix makes the link, not its directory.
    assert outlink.parent.is_dir()


@pytest.mark.parametrize("name", GROUPS)
def test_without_the_backends_installer_it_says_what_to_install(
    tmp_path: Path, backend: str, name: str
) -> None:
    root = checkout(tmp_path)
    result = group(root, "install", name, backend=backend, environment=host(tmp_path))
    assert result.returncode == 2
    installer = {"pixi": "pixi is not installed", "nix": "Nix is not installed"}[backend]
    assert result.stderr.startswith(installer)


# ------------------------------------------------------------- refusals ---


@pytest.mark.parametrize("verb", ["install", "check"])
def test_an_unknown_backend_is_refused_by_name_before_anything_runs(
    tmp_path: Path, verb: str
) -> None:
    root = checkout(tmp_path)
    calls = tmp_path / "calls"
    environment = host(tmp_path, "pixi", "nix", calls=calls)
    result = group(root, verb, "cluster", backend="conda", environment=environment)
    assert (result.returncode, result.stderr) == (2, REFUSAL)
    assert not calls.exists()


@pytest.mark.parametrize(
    "arguments",
    [
        (),
        ("check",),
        ("check", "default"),
        ("check", "runtime"),
        ("build", "cluster"),
        ("check", "cluster", "extra"),
    ],
)
def test_anything_else_is_a_usage_error(tmp_path: Path, arguments: tuple[str, ...]) -> None:
    result = group(checkout(tmp_path), *arguments, backend="pixi")
    assert (result.returncode, result.stdout, result.stderr) == (2, "", USAGE)


# ------------------------------------------------------------- Justfile ---


@pytest.mark.parametrize(
    ("recipe", "name"),
    [
        ("cluster-up", "cluster"),
        ("cluster-ready", "cluster"),
        ("cluster-down", "cluster"),
        ("deploy", "cluster"),
        ("smoke", "cluster"),
        ("image-load", "cluster"),
        ("image-scan", "audit"),
        ("runtime-scan", "audit"),
    ],
)
def test_the_recipes_refuse_without_the_group_naming_the_install_recipe(
    tmp_path: Path, backend: str, recipe: str, name: str
) -> None:
    root = checkout(tmp_path)
    calls = tmp_path / "calls"
    environment = host(tmp_path, "kind", "kubectl", "kwokctl", "grype", "python3", calls=calls)
    result = just(root, recipe, backend=backend, environment=environment)
    assert result.returncode != 0
    assert f"run just {name}-install" in result.stderr
    assert not calls.exists(), "nothing past the guard may run"


@pytest.mark.parametrize("name", GROUPS)
def test_the_install_recipes_go_through_the_script(
    tmp_path: Path, backend: str, name: str
) -> None:
    root = checkout(tmp_path)
    calls = tmp_path / "calls"
    environment = host(tmp_path, "pixi", "nix", calls=calls)
    result = just(root, f"{name}-install", backend=backend, environment=environment)
    assert result.returncode == 0, result.stderr
    (call,) = calls.read_text().splitlines()
    assert call.startswith(f"{root}: {'pixi install' if backend == 'pixi' else 'nix build'}")


def test_the_selection_owns_the_script() -> None:
    assert "tool_group" in checker_suite.GROUPS["environment"][0].split()
    assert "scripts/tool-group.sh" in checker_suite.GROUPS["environment"][1]
