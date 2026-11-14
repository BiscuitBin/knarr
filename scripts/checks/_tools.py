"""Where a checkout's tools are, as scripts/tool-dirs.sh states it.

The script owns the tool directories and is the only reader of KNARR_TOOLS
(Decision 0017, "Layout: tool groups, out-links and PATH"). The checkers and
their tests ask it through this module, so none of them names a directory or
reads the selector. Each call passes this process's environment through, so the
script sees the backend the recipe or hook was run with.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tool-dirs.sh"


class SelectorError(RuntimeError):
    """KNARR_TOOLS names neither backend; the message is the script's own."""


def _ask(*arguments: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["sh", str(SCRIPT), *arguments], check=False, capture_output=True, text=True
    )
    # The script prints on stderr only to refuse, either a usage error or an
    # unknown KNARR_TOOLS; a tool or module it cannot find is a silent exit 2.
    if result.returncode != 0 and "KNARR_TOOLS" in result.stderr:
        raise SelectorError(result.stderr.strip())
    if result.returncode != 0 and result.stderr:
        raise ValueError(result.stderr.strip())
    return result


def _path(result: subprocess.CompletedProcess[str]) -> Path:
    return Path(result.stdout.rstrip("\n"))


def backend() -> str:
    """The selected backend, `pixi` or `nix`."""
    return _ask("backend").stdout.strip()


def directories(checkout: Path) -> list[Path]:
    """The checkout's tool directories, in PATH order, whether or not they exist yet."""
    result = _ask("dirs", str(checkout))
    return [Path(directory) for directory in result.stdout.rstrip("\n").split(":")]


def prefix(checkout: Path, group: str) -> Path:
    """Where a tool group is installed: pixi's environment directory or Nix's out-link."""
    return _path(_ask("prefix", group, str(checkout)))


def tool(checkout: Path, name: str) -> Path:
    """The named tool from the checkout's tool directories, never one from PATH."""
    result = _ask("tool", name, str(checkout))
    if result.returncode != 0:
        raise FileNotFoundError(f"{name} is not in the tool directories of {checkout}")
    return _path(result)


def module(checkout: Path, name: str) -> Path:
    """The named Node module beside the default group's bin directory."""
    result = _ask("module", name, str(checkout))
    if result.returncode != 0:
        raise FileNotFoundError(f"the {name} module is not in the default group of {checkout}")
    return _path(result)
