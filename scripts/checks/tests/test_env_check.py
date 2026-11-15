"""The installed-environment check: the gate refuses tools flake.lock no longer pins.

lock-check compares flake.lock with flake.nix only. After a pull that moves a
pin, the old tools stay on PATH until `just initialize` reruns, and this check
is what fails the gate in the meantime. It asks nix what the flake evaluates
to, read-only and offline, and never writes.

nix is a stand-in on PATH here: it answers from files beside it and records how
it was called, so no case evaluates a flake.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from conftest import run_checker

STORE = "/nix/store/00000000000000000000000000000000-knarr-tools"
MOVED = "/nix/store/11111111111111111111111111111111-knarr-tools"
STUB = """\
#!/bin/sh
here=$(dirname "$0")
{ pwd; printf '%s\\n' "$@"; } > "$here/called"
[ ! -f "$here/error" ] || { cat "$here/error" >&2; exit 1; }
printf '%s' "$(cat "$here/answer")"
"""


@pytest.fixture
def project(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A project whose .nix/tools is the environment its stand-in nix evaluates to."""
    tools = tmp_path / "store" / "knarr-tools"
    (tools / "bin").mkdir(parents=True)
    stub = tmp_path / "stub"
    stub.mkdir()
    (stub / "nix").write_text(STUB)
    (stub / "nix").chmod(0o755)
    (stub / "answer").write_text(str(tools))
    monkeypatch.setenv("PATH", f"{stub}:/usr/bin:/bin")
    checkout = tmp_path / "checkout"
    (checkout / ".nix").mkdir(parents=True)
    (checkout / ".nix" / "tools").symlink_to(tools, target_is_directory=True)
    return checkout


def stub(project: Path) -> Path:
    return project.parent / "stub"


def _tree(directory: Path) -> dict[str, str]:
    return {
        str(path.relative_to(directory)): str(path.readlink()) if path.is_symlink() else "file"
        for path in directory.rglob("*")
        if path.is_symlink() or path.is_file()
    }


def check(directory: Path, *, cli: bool = False) -> subprocess.CompletedProcess[str]:
    before = _tree(directory)
    result = run_checker("env_check", directory, str(directory), cli=cli)
    assert _tree(directory) == before, "the check must never write"
    return result


def test_a_matching_installation_passes(project: Path) -> None:
    result = check(project)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "is the tool environment flake.lock pins" in result.stdout


def test_a_moved_pin_fails_and_names_both_environments(project: Path) -> None:
    installed = (project / ".nix" / "tools").resolve()
    (stub(project) / "answer").write_text(MOVED)
    result = check(project)
    assert result.returncode == 1
    assert f"flake.lock pins {MOVED}" in result.stdout
    assert str(installed) in result.stdout
    assert "just initialize" in result.stdout


def test_nix_is_asked_read_only_offline_and_without_touching_the_lock(project: Path) -> None:
    check(project)
    directory, *arguments = (stub(project) / "called").read_text().splitlines()
    assert directory == str(project)
    assert arguments[-1] == ".#tools"
    assert {"eval", "--raw", "--read-only", "--offline", "--no-update-lock-file"} <= set(arguments)
    # flake.lock is rewritten by a nix that may update it, and by one told only
    # not to write: --no-write-lock-file goes on with a lock it made up.
    assert "--no-write-lock-file" not in arguments


def test_a_checkout_that_was_never_initialized_cannot_decide(project: Path) -> None:
    (project / ".nix" / "tools").unlink()
    result = check(project)
    assert result.returncode == 2
    assert "run just initialize" in result.stderr


def test_a_link_to_a_collected_environment_cannot_decide(project: Path) -> None:
    link = project / ".nix" / "tools"
    link.unlink()
    link.symlink_to(MOVED)
    result = check(project)
    assert result.returncode == 2
    assert "is gone; run just initialize" in result.stderr


def test_a_lock_nix_would_have_to_rewrite_cannot_decide(project: Path) -> None:
    (stub(project) / "error").write_text(
        "error:\n"
        "       … while updating the lock file of flake 'git+file:///checkout'\n"
        "\n"
        "       error: flake 'git+file:///checkout' requires lock file changes but they're not"
        " allowed due to '--no-update-lock-file'\n"
    )
    result = check(project)
    assert result.returncode == 2
    assert "nix could not evaluate the tool environment offline" in result.stderr
    assert "requires lock file changes" in result.stderr


def test_an_answer_that_is_not_a_store_path_cannot_decide(project: Path) -> None:
    (stub(project) / "answer").write_text("")
    result = check(project)
    assert result.returncode == 2
    assert "nix could not evaluate" in result.stderr


def test_a_host_without_nix_cannot_decide(project: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PATH", str(project))
    result = check(project)
    assert result.returncode == 2
    assert "nix cannot run" in result.stderr


@pytest.mark.parametrize("moved", [False, True])
def test_cli_contract(project: Path, moved: bool) -> None:
    if moved:
        (stub(project) / "answer").write_text(MOVED)
    result = check(project, cli=True)
    assert result.returncode == int(moved), result.stdout + result.stderr
    assert ("differ from flake.lock" if moved else "flake.lock pins") in result.stdout


def test_the_stand_in_answers_as_nix_eval_raw_does(project: Path) -> None:
    # `nix eval --raw` prints the path with no newline; the stand-in must too,
    # or the cases above would pass on a reader that forgot to strip.
    answer = subprocess.run(
        [str(stub(project) / "nix"), "eval"], check=True, capture_output=True, text=True
    )
    assert answer.stdout == json.loads(json.dumps((stub(project) / "answer").read_text()))
