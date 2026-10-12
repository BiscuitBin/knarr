"""The fake worker fixture runs the same Gleam packages as knarr (ticket 29).

The fixture is its own Gleam project, so its gleam.toml and manifest.toml are a
second record of the shared dependencies. These tests keep that record from
drifting: a pin moves in both projects or in neither.
"""

from __future__ import annotations

import tomllib

from conftest import REPOSITORY

FIXTURE = REPOSITORY / "fixtures" / "fake_worker"


def load(path: str) -> dict:
    return tomllib.loads((REPOSITORY / path).read_text())


def locked(manifest: dict) -> dict[str, tuple[str, str]]:
    return {
        package["name"]: (package["version"], package["outer_checksum"])
        for package in manifest["packages"]
    }


def test_every_fixture_package_is_locked_as_knarr_locks_it():
    knarr = locked(load("manifest.toml"))
    fixture = locked(load("fixtures/fake_worker/manifest.toml"))
    assert fixture
    assert {name: knarr.get(name) for name in fixture} == fixture


def test_shared_dependency_ranges_match():
    knarr = load("gleam.toml")
    fixture = load("fixtures/fake_worker/gleam.toml")
    for table in ("dependencies", "dev-dependencies"):
        for name, wanted in fixture[table].items():
            assert knarr[table].get(name) == wanted, (table, name)


def test_the_dev_dependencies_use_the_spelling_renovate_reads():
    # As test_dependency_pins.py holds knarr's: Renovate's gleam manager reads
    # [dev-dependencies] only, so [dev_dependencies] would hide the fixture's
    # dev dependencies from the group that moves both projects together.
    fixture = load("fixtures/fake_worker/gleam.toml")
    assert "dev_dependencies" not in fixture
    assert fixture["dev-dependencies"]
