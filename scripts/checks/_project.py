"""Where the repository is, and what its checks.toml asks of the checkers.

Copied from github.com/steven-cutting/biscuit_games_tooling at v0.3.0
(6c5c07f6bec86e86b3930dfa41392e4b440e8c85), src/biscuit_games_tooling/_project.py,
and reduced as Decision 0004 records: `root()` is kept, the pyproject.toml
reader and the default recipe list are gone, and every setting now comes from
checks.toml through `table()`, which fails closed. `pins()` is knarr's own: it
reads the tool versions the installed Nix environment records (Decision 0017).

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import json
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any, NoReturn

CHECKS_FILE = "checks.toml"
# The out-link `just initialize` builds, and the record nix/tools.nix writes
# into it: the version of each tool a checker depends on.
TOOLS = ".nix/tools"
PINS_FILE = f"{TOOLS}/share/knarr/pins.json"


class PinsError(RuntimeError):
    """The installed tool environment's version record is missing or unreadable."""


def pins(project_root: Path) -> dict[str, str]:
    """The tool versions the installed Nix environment was built with."""
    path = project_root / PINS_FILE
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PinsError(f"{PINS_FILE} is missing or unreadable; run just initialize") from error
    if not isinstance(record, dict) or not all(isinstance(v, str) for v in record.values()):
        raise PinsError(f"{PINS_FILE} is not a table of versions; run just initialize")
    return record


def pin(project_root: Path, tool: str) -> str:
    """One tool's version from `pins()`; a tool the record does not name is an error."""
    version = pins(project_root).get(tool)
    if not version:
        raise PinsError(f"{PINS_FILE} names no {tool} version; run just initialize")
    return version


def root() -> Path:
    """The top level of the Git worktree the current directory is inside."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], check=False, capture_output=True, text=True
    )
    if result.returncode != 0:
        _refuse("run this from inside a Git worktree")
    return Path(result.stdout.strip())


def table(project_root: Path, name: str) -> dict[str, Any]:
    """The `[name]` table of checks.toml. A missing file or table is an error."""
    path = project_root / CHECKS_FILE
    if not path.is_file():
        _refuse(f"{CHECKS_FILE} is missing at {project_root}")
    try:
        with path.open("rb") as stream:
            settings = tomllib.load(stream)
    except tomllib.TOMLDecodeError as error:
        _refuse(f"{CHECKS_FILE} is not valid TOML: {error}")
    if name not in settings:
        _refuse(f"{CHECKS_FILE} has no [{name}] table")
    value = settings[name]
    if not isinstance(value, dict):
        _refuse(f"{CHECKS_FILE}: [{name}] must be a table")
    return value


def _refuse(message: str) -> NoReturn:
    print(f"checks: {message}", file=sys.stderr)
    raise SystemExit(2)


def predicates(project_root: Path) -> tuple[set[str], set[str]]:
    """Every predicate `[docs] predicates` declares, and the subset it enables.

    Only the boolean `true` enables one. A quoted `"false"` is truthy, and reading it
    as enabled would let a page that requires the predicate pass.
    """
    docs = table(project_root, "docs")
    if "predicates" not in docs:
        _refuse(f"{CHECKS_FILE}: [docs] has no predicates key")
    declared = docs["predicates"]
    if not isinstance(declared, dict):
        _refuse(f"{CHECKS_FILE}: [docs] predicates must be a table")
    return set(declared), {name for name, enabled in declared.items() if enabled is True}
