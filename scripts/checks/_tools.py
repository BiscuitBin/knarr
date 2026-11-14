"""Where a checkout's tools are, as scripts/tool-dirs.sh states it.

The script owns the tool directories (Decision 0003, "How recipes reach the
environment"). The checkers and their tests ask it through this module, so
none of them names a directory.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tool-dirs.sh"


def directories(checkout: Path) -> list[Path]:
    """The checkout's tool directories, in PATH order, whether or not they exist yet."""
    result = subprocess.run(
        ["sh", str(SCRIPT), "dirs", str(checkout)], check=True, capture_output=True, text=True
    )
    return [Path(directory) for directory in result.stdout.rstrip("\n").split(":")]


def tool(checkout: Path, name: str) -> Path:
    """The named tool from the checkout's tool directories, never one from PATH."""
    result = subprocess.run(
        ["sh", str(SCRIPT), "tool", name, str(checkout)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise FileNotFoundError(f"{name} is not in the tool directories of {checkout}")
    return Path(result.stdout.rstrip("\n"))
