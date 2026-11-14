"""scripts/tool-dirs.sh, the one owner of a checkout's tool directories.

The Justfile, the hook wrapper, `just initialize`, the ripsecrets wrapper and,
through `_tools`, the checkers all ask it where the tools are (Decision 0017,
"Layout: tool groups, out-links and PATH"). It is also the only reader of
KNARR_TOOLS, which selects the pixi or the Nix backend for a whole command.
Each case here runs the real script.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

import _tools
from conftest import BACKENDS, REPOSITORY, tool_directory

SCRIPT = REPOSITORY / "scripts" / "tool-dirs.sh"
USAGE = (
    "usage: tool-dirs.sh backend | dirs [<checkout>] | tool <name> [<checkout>]"
    " | module <name> [<checkout>] | prefix default|cluster|audit [<checkout>]\n"
)
# Each backend's group prefixes, and then its directories in PATH order. Written
# as parts, so the script stays the only file under scripts/ that spells the
# paths out. pixi's tools.txt downloads come last; Nix has no such directory.
PREFIXES = {
    "pixi": {group: (".pixi", "envs", group) for group in ("default", "cluster", "audit")},
    "nix": {group: (".nix", group) for group in ("default", "cluster", "audit")},
}
DIRECTORIES = {
    "pixi": (*((*parts, "bin") for parts in PREFIXES["pixi"].values()), (".tools", "bin")),
    "nix": tuple((*parts, "bin") for parts in PREFIXES["nix"].values()),
}
DEFAULT = "pixi"
REFUSAL = "KNARR_TOOLS is {value!r}; set it to pixi or nix, or leave it unset for pixi\n"


def expected(checkout: Path, backend: str = DEFAULT) -> list[Path]:
    return [checkout.joinpath(*parts) for parts in DIRECTORIES[backend]]


def joined(checkout: Path, backend: str = DEFAULT) -> str:
    return ":".join(str(directory) for directory in expected(checkout, backend)) + "\n"


def seam(
    *arguments: str,
    script: Path = SCRIPT,
    search: str = "/usr/bin:/bin",
    tools: str | None = None,
) -> subprocess.CompletedProcess[str]:
    environment = {"PATH": search}
    if tools is not None:
        environment["KNARR_TOOLS"] = tools
    return subprocess.run(
        ["/bin/sh", str(script), *arguments],
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )


def outcome(result: subprocess.CompletedProcess[str]) -> tuple[int, str, str]:
    return result.returncode, result.stdout, result.stderr


def plant(directory: Path, name: str, mode: int = 0o755) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    tool = directory / name
    tool.write_text("#!/bin/sh\n")
    tool.chmod(mode)
    return tool


def copied(tmp_path: Path) -> Path:
    """An uninitialized checkout: the Justfile and what it reads when it is parsed."""
    root = (tmp_path / "checkout").resolve()
    (root / "scripts").mkdir(parents=True)
    shutil.copy(REPOSITORY / "Justfile", root / "Justfile")
    for name in ("tool-dirs.sh", "cluster-name.sh"):
        shutil.copy(REPOSITORY / "scripts" / name, root / "scripts" / name)
    return root


def just(
    root: Path, *arguments: str, tools: str | None = None
) -> subprocess.CompletedProcess[str]:
    environment = {"PATH": "/usr/bin:/bin"}
    if tools is not None:
        environment["KNARR_TOOLS"] = tools
    return subprocess.run(
        [str(_tools.tool(REPOSITORY, "just")), *arguments],
        cwd=root,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )


@pytest.mark.parametrize("tools", [None, "", "pixi"])
def test_the_tracked_default_is_pixi(tmp_path: Path, tools: str | None) -> None:
    assert outcome(seam("backend", tools=tools)) == (0, "pixi\n", "")
    assert outcome(seam("dirs", str(tmp_path), tools=tools)) == (0, joined(tmp_path), "")


def test_nix_selects_the_out_links_and_nothing_of_pixis(tmp_path: Path) -> None:
    assert outcome(seam("backend", tools="nix")) == (0, "nix\n", "")
    assert outcome(seam("dirs", str(tmp_path), tools="nix")) == (0, joined(tmp_path, "nix"), "")


@pytest.mark.parametrize("value", ["conda", "Nix", "pixi nix", "nix:pixi"])
def test_dirs_never_refuses_an_unknown_value_and_prints_the_defaults(
    tmp_path: Path, value: str
) -> None:
    """The Justfile evaluates dirs when it loads, so a refusal here would break `just --list`."""
    assert outcome(seam("dirs", str(tmp_path), tools=value)) == (0, joined(tmp_path), "")


@pytest.mark.parametrize(
    "arguments",
    [
        ("backend",),
        ("tool", "probe", "/checkout"),
        ("module", "probe", "/checkout"),
        ("prefix", "default", "/checkout"),
    ],
)
def test_every_other_verb_refuses_an_unknown_value_by_name(arguments: tuple[str, ...]) -> None:
    assert outcome(seam(*arguments, tools="conda")) == (2, "", REFUSAL.format(value="conda"))


def test_dirs_defaults_to_the_checkout_the_script_is_in(tmp_path: Path) -> None:
    root = copied(tmp_path)
    result = seam("dirs", script=root / "scripts" / "tool-dirs.sh")
    assert outcome(result) == (0, seam("dirs", str(root)).stdout, "")


@pytest.mark.parametrize("backend", BACKENDS)
def test_dirs_runs_no_tool_on_an_uninitialized_checkout(tmp_path: Path, backend: str) -> None:
    root = copied(tmp_path)
    nothing = tmp_path / "nothing"
    nothing.mkdir()
    # With nothing on PATH, any command the script ran would fail it.
    script = root / "scripts" / "tool-dirs.sh"
    result = seam("dirs", script=script, search=str(nothing), tools=backend)
    assert outcome(result) == (0, joined(root, backend), "")
    assert not (root / DIRECTORIES[backend][0][0]).exists()


@pytest.mark.parametrize("tools", [None, "nix", "conda"])
def test_just_lists_its_recipes_on_an_uninitialized_checkout(
    tmp_path: Path, tools: str | None
) -> None:
    result = just(copied(tmp_path), "--list", tools=tools)
    assert result.returncode == 0, result.stderr
    assert "initialize" in result.stdout


@pytest.mark.parametrize("backend", BACKENDS)
def test_the_justfile_puts_the_directories_first_on_path(tmp_path: Path, backend: str) -> None:
    root = copied(tmp_path)
    result = just(root, "--evaluate", "PATH", tools=backend)
    assert result.returncode == 0, result.stderr
    assert result.stdout == joined(root, backend).strip() + ":/usr/bin:/bin"


@pytest.mark.parametrize("backend", BACKENDS)
def test_tool_prints_the_absolute_path_of_a_tool_in_the_directories(
    tmp_path: Path, backend: str
) -> None:
    for index, directory in enumerate(expected(tmp_path, backend)):
        tool = plant(directory, f"probe{index}")
        result = seam("tool", tool.name, str(tmp_path), tools=backend)
        assert outcome(result) == (0, f"{tool}\n", "")


def test_a_backend_never_finds_the_others_tools(tmp_path: Path) -> None:
    """A backend is selected whole: never default tools from one and cluster tools from the other."""
    plant(expected(tmp_path, "pixi")[1], "pixi-only")
    plant(expected(tmp_path, "nix")[1], "nix-only")
    assert outcome(seam("tool", "pixi-only", str(tmp_path), tools="nix")) == (2, "", "")
    assert outcome(seam("tool", "nix-only", str(tmp_path), tools="pixi")) == (2, "", "")


def test_tool_takes_the_earliest_directory_that_holds_it(tmp_path: Path) -> None:
    first, *_, last = expected(tmp_path)
    plant(last, "probe")
    assert seam("tool", "probe", str(tmp_path)).stdout == f"{last / 'probe'}\n"
    plant(first, "probe")
    assert seam("tool", "probe", str(tmp_path)).stdout == f"{first / 'probe'}\n"


def test_tool_refuses_a_tool_only_the_host_has(tmp_path: Path) -> None:
    elsewhere = tmp_path / "elsewhere"
    plant(elsewhere, "probe")
    checkout = tmp_path / "checkout"
    plant(tool_directory(checkout, DEFAULT), "other")
    result = seam("tool", "probe", str(checkout), search=f"{elsewhere}:/usr/bin:/bin")
    assert outcome(result) == (2, "", "")


def test_tool_refuses_what_it_could_not_run(tmp_path: Path) -> None:
    directory = tool_directory(tmp_path, DEFAULT)
    plant(directory, "data", mode=0o644)
    (directory / "folder").mkdir()
    assert outcome(seam("tool", "data", str(tmp_path))) == (2, "", "")
    assert outcome(seam("tool", "folder", str(tmp_path))) == (2, "", "")


@pytest.mark.parametrize("backend", BACKENDS)
def test_prefix_names_where_each_group_is_installed(tmp_path: Path, backend: str) -> None:
    for group, parts in PREFIXES[backend].items():
        result = seam("prefix", group, str(tmp_path), tools=backend)
        assert outcome(result) == (0, f"{tmp_path.joinpath(*parts)}\n", "")


@pytest.mark.parametrize("backend", BACKENDS)
def test_module_finds_a_node_module_beside_the_default_groups_bin(
    tmp_path: Path, backend: str
) -> None:
    """Under Nix bin/markdownlint-cli2 is a wrapper script, so the docs checker needs the module."""
    module = tmp_path.joinpath(*PREFIXES[backend]["default"], "lib", "node_modules", "probe")
    assert outcome(seam("module", "probe", str(tmp_path), tools=backend)) == (2, "", "")
    module.mkdir(parents=True)
    result = seam("module", "probe", str(tmp_path), tools=backend)
    assert outcome(result) == (0, f"{module}\n", "")


@pytest.mark.parametrize(
    "arguments",
    [
        (),
        ("path",),
        ("backend", "/checkout"),
        ("dirs", "relative"),
        ("dirs", "/checkout", "extra"),
        ("tool",),
        ("tool", ""),
        ("tool", "probe", "relative"),
        ("tool", "probe", "/checkout", "extra"),
        ("module", "../probe"),
        ("prefix",),
        ("prefix", "runtime"),
        ("prefix", "default", "relative"),
    ],
)
def test_anything_else_is_a_usage_error(arguments: tuple[str, ...]) -> None:
    assert outcome(seam(*arguments)) == (2, "", USAGE)


def test_tool_never_leaves_the_directories_through_the_name(tmp_path: Path) -> None:
    plant(tool_directory(tmp_path, DEFAULT).parent, "probe")
    assert outcome(seam("tool", "../probe", str(tmp_path))) == (2, "", USAGE)


def test_the_python_helper_reports_what_the_script_prints(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("KNARR_TOOLS", "nix")
    assert _tools.backend() == "nix"
    assert _tools.directories(tmp_path) == expected(tmp_path, "nix")
    assert tool_directory(tmp_path) == expected(tmp_path, "nix")[0]
    assert _tools.prefix(tmp_path, "cluster") == tmp_path.joinpath(*PREFIXES["nix"]["cluster"])
    tool = plant(expected(tmp_path, "nix")[-1], "probe")
    assert _tools.tool(tmp_path, "probe") == tool
    module = _tools.prefix(tmp_path, "default") / "lib" / "node_modules" / "probe"
    module.mkdir(parents=True)
    assert _tools.module(tmp_path, "probe") == module


def test_the_python_helper_raises_for_a_missing_tool(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="probe"):
        _tools.tool(tmp_path, "probe")
    with pytest.raises(FileNotFoundError, match="probe"):
        _tools.module(tmp_path, "probe")


def test_the_python_helper_carries_the_refusal(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("KNARR_TOOLS", "conda")
    message = REFUSAL.format(value="conda").strip()
    for call in (
        _tools.backend,
        lambda: _tools.tool(tmp_path, "probe"),
        lambda: _tools.module(tmp_path, "probe"),
        lambda: _tools.prefix(tmp_path, "default"),
    ):
        with pytest.raises(_tools.SelectorError, match=message):
            call()
    # dirs never refuses: the Justfile and the tests' stand-ins rely on it.
    assert _tools.directories(tmp_path) == expected(tmp_path, DEFAULT)


@pytest.mark.parametrize("recipe", ["check", "lock-check"])
def test_the_gate_refuses_an_unknown_value_by_name(tmp_path: Path, recipe: str) -> None:
    result = just(copied(tmp_path), recipe, tools="conda")
    assert result.returncode == 2
    assert REFUSAL.format(value="conda") in result.stderr


@pytest.mark.parametrize("backend", BACKENDS)
def test_the_gate_names_the_backend_whose_environment_is_missing(
    tmp_path: Path, backend: str
) -> None:
    result = just(copied(tmp_path), "check", tools=backend)
    assert result.returncode == 2
    assert f"the {backend} environment is missing; run just initialize" in result.stderr
