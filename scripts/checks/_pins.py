"""The held versions, as pins.toml states them (Decision 0017, "The held-versions file").

pins.toml is three flat tables of strings, one per kind of hold: `[exact]`,
`[minor]` and `[floor]`. flake.nix asserts each held package against it, and
the checkers read it here with tomllib, with no Nix present. This is the only
reader of the file under scripts/ outside the tests.

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import re
import tomllib
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path

KINDS = ("exact", "minor", "floor")
VERSION = re.compile(r"\d+(?:\.\d+)*")


class PinsError(Exception):
    """pins.toml is missing, unreadable, or not in Decision 0017's shape."""


def held(project: Path) -> dict[str, dict[str, str]]:
    """Every held version in `project`'s pins.toml, by kind of hold and then by name."""
    try:
        text = (project / "pins.toml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise PinsError(str(error)) from error
    try:
        tables = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise PinsError(f"pins.toml is not TOML: {error}") from error
    for name in tables:
        if name not in KINDS:
            raise PinsError(f"pins.toml: unknown table [{name}]")
    for kind in KINDS:
        if kind not in tables:
            raise PinsError(f"pins.toml: [{kind}] is missing")
        if not isinstance(tables[kind], dict):
            raise PinsError(f"pins.toml: [{kind}] is not a table")
        for name, value in tables[kind].items():
            if not isinstance(value, str):
                raise PinsError(f"pins.toml: [{kind}] {name} is not a string")
            if not VERSION.fullmatch(value):
                raise PinsError(f"pins.toml: [{kind}] {name} {value!r} is not a dotted version")
    return tables


def version(project: Path, kind: str, name: str) -> str:
    """The one version pins.toml holds for `name` under `[kind]`."""
    try:
        return held(project)[kind][name]
    except KeyError as error:
        raise PinsError(f"pins.toml holds no [{kind}] {name}") from error
