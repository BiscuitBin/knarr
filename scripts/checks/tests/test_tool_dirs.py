"""scripts/tool-dirs.sh, the one owner of a checkout's tool directories.

The Justfile, the hook wrapper, `just initialize`, the ripsecrets wrapper and,
through `_tools`, the checkers all ask it where the tools are (Decision 0003,
"How recipes reach the environment"). Each case here runs the real script.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

import _tools
from conftest import REPOSITORY, tool_directory

SCRIPT = REPOSITORY / "scripts" / "tool-dirs.sh"
USAGE = "usage: tool-dirs.sh dirs [<checkout>] | tool <name> [<checkout>]\n"
# Decision 0003's four directories, in its order. Written as parts, so the
# script stays the only file under scripts/ that spells the paths out.
DIRECTORIES = (
    (".pixi", "envs", "default", "bin"),
    (".pixi", "envs", "cluster", "bin"),
    (".pixi", "envs", "audit", "bin"),
    (".tools", "bin"),
)


def expected(checkout: Path) -> list[Path]:
    return [checkout.joinpath(*parts) for parts in DIRECTORIES]


def seam(
    *arguments: str, script: Path = SCRIPT, search: str = "/usr/bin:/bin"
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/sh", str(script), *arguments],
        env={"PATH": search},
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


def test_dirs_prints_the_four_directories_in_order(tmp_path: Path) -> None:
    joined = ":".join(str(directory) for directory in expected(tmp_path))
    assert outcome(seam("dirs", str(tmp_path))) == (0, joined + "\n", "")


def test_dirs_defaults_to_the_checkout_the_script_is_in(tmp_path: Path) -> None:
    root = copied(tmp_path)
    result = seam("dirs", script=root / "scripts" / "tool-dirs.sh")
    assert outcome(result) == (0, seam("dirs", str(root)).stdout, "")


def test_dirs_runs_no_tool_on_an_uninitialized_checkout(tmp_path: Path) -> None:
    root = copied(tmp_path)
    nothing = tmp_path / "nothing"
    nothing.mkdir()
    # With nothing on PATH, any command the script ran would fail it.
    result = seam("dirs", script=root / "scripts" / "tool-dirs.sh", search=str(nothing))
    assert outcome(result) == (0, seam("dirs", str(root)).stdout, "")
    assert not (root / DIRECTORIES[0][0]).exists()


def test_just_lists_its_recipes_on_an_uninitialized_checkout(tmp_path: Path) -> None:
    result = subprocess.run(
        [str(_tools.tool(REPOSITORY, "just")), "--list"],
        cwd=copied(tmp_path),
        env={"PATH": "/usr/bin:/bin"},
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert "initialize" in result.stdout


def test_the_justfile_puts_the_directories_first_on_path(tmp_path: Path) -> None:
    root = copied(tmp_path)
    result = subprocess.run(
        [str(_tools.tool(REPOSITORY, "just")), "--evaluate", "PATH"],
        cwd=root,
        env={"PATH": "/usr/bin:/bin"},
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == seam("dirs", str(root)).stdout.strip() + ":/usr/bin:/bin"


def test_tool_prints_the_absolute_path_of_a_tool_in_the_directories(tmp_path: Path) -> None:
    for index, directory in enumerate(expected(tmp_path)):
        tool = plant(directory, f"probe{index}")
        assert outcome(seam("tool", tool.name, str(tmp_path))) == (0, f"{tool}\n", "")


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
    plant(tool_directory(checkout), "other")
    result = seam("tool", "probe", str(checkout), search=f"{elsewhere}:/usr/bin:/bin")
    assert outcome(result) == (2, "", "")


def test_tool_refuses_what_it_could_not_run(tmp_path: Path) -> None:
    directory = tool_directory(tmp_path)
    plant(directory, "data", mode=0o644)
    (directory / "folder").mkdir()
    assert outcome(seam("tool", "data", str(tmp_path))) == (2, "", "")
    assert outcome(seam("tool", "folder", str(tmp_path))) == (2, "", "")


@pytest.mark.parametrize(
    "arguments",
    [
        (),
        ("path",),
        ("dirs", "relative"),
        ("dirs", "/checkout", "extra"),
        ("tool",),
        ("tool", ""),
        ("tool", "probe", "relative"),
        ("tool", "probe", "/checkout", "extra"),
    ],
)
def test_anything_else_is_a_usage_error(arguments: tuple[str, ...]) -> None:
    assert outcome(seam(*arguments)) == (2, "", USAGE)


def test_tool_never_leaves_the_directories_through_the_name(tmp_path: Path) -> None:
    plant(tool_directory(tmp_path).parent, "probe")
    assert outcome(seam("tool", "../probe", str(tmp_path))) == (2, "", USAGE)


def test_the_python_helper_reports_what_the_script_prints(tmp_path: Path) -> None:
    assert _tools.directories(tmp_path) == expected(tmp_path)
    assert tool_directory(tmp_path) == expected(tmp_path)[0]
    tool = plant(expected(tmp_path)[-1], "probe")
    assert _tools.tool(tmp_path, "probe") == tool


def test_the_python_helper_raises_for_a_missing_tool(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="probe"):
        _tools.tool(tmp_path, "probe")
