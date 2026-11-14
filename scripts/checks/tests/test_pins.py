"""pins.toml, the held versions, and the flake files that must not rot while pixi is the default.

Decision 0017 makes pins.toml the one owner of each held version: flake.nix
asserts each against what its inputs carry, and the checkers read it with
tomllib through `_pins`. Until ticket 10 no runner has Nix, so these tests read
pins.toml, pixi.toml, flake.nix and flake.lock with the standard library alone.
"""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path

import pytest

import _pins
from conftest import REPOSITORY

PINS = """\
[exact]
erlang = "29.1.1"
gleam = "1.19.0"

[minor]
kubectl = "1.36"

[floor]
rebar3 = "3.28.0"
"""
INPUTS = {
    "nixpkgs": {"ref": "nixpkgs-unstable"},
    "nixpkgs-gleam": {"rev": None},
    "nixpkgs-kubectl": {"ref": "nixos-26.05"},
}
HEX40 = re.compile(r"[0-9a-f]{40}")
# A Nix command a recipe or script runs: a shell word `nix <subcommand>`, or a
# Python argument list that starts "nix", "<subcommand>".
NIX_COMMAND = re.compile(r"""(?:^|[\s;|&(`"'])nix(?:"\s*,\s*"|\s+)([a-z][\w-]*)""")


def written(tmp_path: Path, text: str) -> Path:
    (tmp_path / "pins.toml").write_text(text)
    return tmp_path


def test_the_held_versions_are_three_flat_tables_of_strings(tmp_path: Path) -> None:
    assert _pins.held(written(tmp_path, PINS)) == {
        "exact": {"erlang": "29.1.1", "gleam": "1.19.0"},
        "minor": {"kubectl": "1.36"},
        "floor": {"rebar3": "3.28.0"},
    }


@pytest.mark.parametrize(
    ("text", "message"),
    [
        pytest.param(
            PINS.replace('[minor]\nkubectl = "1.36"\n\n', ""), "[minor] is missing", id="no minor"
        ),
        pytest.param(PINS.replace("[minor]", "[minors]"), "unknown table [minors]", id="a typo"),
        pytest.param(PINS + "[other]\n", "unknown table [other]", id="an extra table"),
        pytest.param('exact = "1"\n[minor]\n[floor]\n', "[exact] is not a table", id="a string"),
        pytest.param(
            PINS.replace('"1.36"', "1.36"), "[minor] kubectl is not a string", id="a float"
        ),
        pytest.param(
            PINS.replace('"3.28.0"', '{ version = "3.28.0" }'),
            "[floor] rebar3 is not a string",
            id="a nested table",
        ),
        pytest.param(
            PINS.replace('"29.1.1"', '">=29.1.1"'),
            "[exact] erlang '>=29.1.1' is not a dotted version",
            id="a range",
        ),
        pytest.param(
            PINS.replace('"29.1.1"', '"29.1.*"'),
            "[exact] erlang '29.1.*' is not a dotted version",
            id="a wildcard",
        ),
        pytest.param("[exact\n", "pins.toml is not TOML", id="not TOML"),
    ],
)
def test_anything_else_is_refused(tmp_path: Path, text: str, message: str) -> None:
    with pytest.raises(_pins.PinsError, match=re.escape(message)):
        _pins.held(written(tmp_path, text))


def test_a_missing_file_is_refused_by_its_path(tmp_path: Path) -> None:
    with pytest.raises(_pins.PinsError, match=re.escape(str(tmp_path / "pins.toml"))):
        _pins.held(tmp_path)


def test_a_file_that_is_not_text_is_refused(tmp_path: Path) -> None:
    (tmp_path / "pins.toml").write_bytes(b"\xff\xfe")
    with pytest.raises(_pins.PinsError, match="utf-8"):
        _pins.held(tmp_path)


def test_one_held_version_is_read_by_kind_and_name(tmp_path: Path) -> None:
    project = written(tmp_path, PINS)
    assert _pins.version(project, "floor", "rebar3") == "3.28.0"
    with pytest.raises(_pins.PinsError, match=re.escape("pins.toml holds no [exact] allium")):
        _pins.version(project, "exact", "allium")


def test_the_committed_file_holds_what_decision_0017_names() -> None:
    held = _pins.held(REPOSITORY)
    assert sorted(held["exact"]) == ["allium", "erlang", "gleam", "kind", "kwokctl"]
    assert sorted(held["minor"]) == ["kubectl"]
    assert sorted(held["floor"]) == ["rebar3"]


def test_pixi_toml_pins_the_erlang_pins_toml_holds() -> None:
    """One owner of the OTP version until ticket 13 deletes pixi.toml."""
    pixi = tomllib.loads((REPOSITORY / "pixi.toml").read_text(encoding="utf-8"))
    pin = pixi["feature"]["otp"]["dependencies"]["erlang"]
    assert pin == "==" + _pins.version(REPOSITORY, "exact", "erlang")


def test_the_flake_lock_locks_the_three_inputs_and_nothing_else() -> None:
    lock = json.loads((REPOSITORY / "flake.lock").read_text(encoding="utf-8"))
    assert lock["version"] == 7
    assert lock["root"] == "root"
    nodes = lock["nodes"]
    assert nodes["root"] == {"inputs": {name: name for name in INPUTS}}
    assert sorted(nodes) == sorted([*INPUTS, "root"])
    for name, original in INPUTS.items():
        node = nodes[name]
        assert sorted(node) == ["locked", "original"], name
        locked = node["locked"]
        assert sorted(locked) == ["lastModified", "narHash", "owner", "repo", "rev", "type"], name
        assert (locked["type"], locked["owner"], locked["repo"]) == ("github", "NixOS", "nixpkgs")
        assert HEX40.fullmatch(locked["rev"]), name
        assert re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", locked["narHash"]), name
        assert isinstance(locked["lastModified"], int), name
        want = {"type": "github", "owner": "NixOS", "repo": "nixpkgs"}
        want.update({key: value or locked["rev"] for key, value in original.items()})
        assert node["original"] == want, name


def test_the_flake_names_the_locked_inputs_and_reads_pins_toml() -> None:
    flake = (REPOSITORY / "flake.nix").read_text(encoding="utf-8")
    lock = json.loads((REPOSITORY / "flake.lock").read_text(encoding="utf-8"))
    urls = dict(re.findall(r"^\s*([\w-]+)\.url = \"([^\"]+)\";$", flake, re.MULTILINE))
    expected = {}
    for name in INPUTS:
        original = lock["nodes"][name]["original"]
        expected[name] = f"github:NixOS/nixpkgs/{original.get('ref') or original['rev']}"
    assert urls == expected
    assert "builtins.fromTOML (builtins.readFile ./pins.toml)" in flake
    # Evaluation copies nothing into the store while the flake never names itself.
    code = "\n".join(line.split("#", 1)[0] for line in flake.splitlines())
    assert not re.search(r"\bself\b", code)


def nix_commands(text: str) -> list[tuple[str, str]]:
    """Each Nix command in a file, with the line it is on, comments left out."""
    commands = []
    for line in text.splitlines():
        code = line.strip()
        if code.startswith("#"):
            continue
        commands.extend((match[1], code) for match in NIX_COMMAND.finditer(code))
    return commands


@pytest.mark.parametrize(
    ("text", "commands"),
    [
        ("nix build --no-update-lock-file .#default\n", ["build"]),
        ("    x=$(nix eval --raw .#a)\n", ["eval"]),
        ('NIX = ("nix", "eval", "--offline")\n', ["eval"]),
        ("# nix develop is never run\n", []),
        ("echo phoenix shell\n", []),
    ],
)
def test_the_nix_command_reader_itself(text: str, commands: list[str]) -> None:
    assert [command for command, _ in nix_commands(text)] == commands


def test_every_nix_command_keeps_the_lock_and_none_wraps_a_shell() -> None:
    """Without --no-update-lock-file a drifted lock is rewritten and the command exits 0."""
    files = [
        REPOSITORY / "Justfile",
        *(REPOSITORY / "scripts").rglob("*.sh"),
        *(path for path in (REPOSITORY / "scripts").rglob("*.py") if "tests" not in path.parts),
    ]
    found = [
        (path.relative_to(REPOSITORY), command, line)
        for path in files
        for command, line in nix_commands(path.read_text(encoding="utf-8"))
    ]
    assert found, "no recipe or script runs nix"
    assert [entry for entry in found if entry[1] in ("develop", "shell", "run")] == []
    assert [entry for entry in found if "--no-update-lock-file" not in entry[2]] == []
