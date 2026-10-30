"""The ripsecrets wrapper (Decision 0004, "The ripsecrets wrapper, rewritten").

Ported from the cases in .scratch/bootstrap/evidence/02/ripsecrets.sh. Each case
runs the wrapper in a throwaway worktree holding the pinned binary that
`just initialize` installs. The planted token is made at run time, so no
committed file carries one. ripsecrets 0.1.11's randomness test passes over about
1 random token in 200, so the fixture redraws until the pinned binary flags one.
"""

from __future__ import annotations

import os
import secrets
import shutil
import string
import subprocess
from pathlib import Path

import pytest

from conftest import CHECKS, REPOSITORY

WRAPPER = CHECKS / "ripsecrets-redacted.sh"
PINNED = REPOSITORY / ".tools" / "bin" / "ripsecrets"
FOUND = "ripsecrets found credential material; the matched values are suppressed"
UNAVAILABLE = "ripsecrets is unavailable; run just initialize"


@pytest.fixture(scope="module")
def pinned() -> Path:
    if not os.access(PINNED, os.X_OK):
        pytest.fail(f"{PINNED} is missing; run just initialize")
    return PINNED


@pytest.fixture
def worktree(repository: Path, pinned: Path) -> Path:
    (repository / ".tools" / "bin").mkdir(parents=True)
    (repository / ".gitignore").write_text(".tools/\n")
    (repository / "clean.txt").write_text("nothing to see\n")
    shutil.copy2(pinned, repository / ".tools" / "bin" / "ripsecrets")
    return repository


@pytest.fixture
def token(pinned: Path, tmp_path: Path) -> str:
    alphabet = string.ascii_letters + string.digits
    draw = tmp_path / "draw.py"
    for _ in range(100):
        candidate = "ghp_" + "".join(secrets.choice(alphabet) for _ in range(36))
        draw.write_text(f'token = "{candidate}"\n')
        result = subprocess.run(
            [str(pinned), "--", str(draw)], check=False, capture_output=True, text=True
        )
        if result.returncode == 1:
            return candidate
    pytest.fail("the pinned ripsecrets flagged none of 100 fresh tokens")


@pytest.fixture
def planted(worktree: Path, token: str) -> Path:
    (worktree / "config.py").write_text(f'token = "{token}"\n')
    return worktree


def wrap(directory: Path, *arguments: str, **environment: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(WRAPPER), *arguments],
        cwd=directory,
        env={**os.environ, **environment},
        check=False,
        capture_output=True,
        text=True,
    )


def outcome(result: subprocess.CompletedProcess[str]) -> tuple[int, str, str]:
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def test_a_clean_worktree_passes_silently(worktree: Path) -> None:
    assert outcome(wrap(worktree)) == (0, "", "")


def test_a_missing_path_argument_passes_as_ripsecrets_itself_does(worktree: Path) -> None:
    assert outcome(wrap(worktree, "no-such-file")) == (0, "", "")


def test_the_control_bare_ripsecrets_prints_the_token(
    planted: Path, pinned: Path, token: str
) -> None:
    result = subprocess.run(
        [str(pinned)], cwd=planted, check=False, capture_output=True, text=True
    )
    assert result.returncode == 1
    assert token in result.stdout + result.stderr


def test_a_planted_token_fails_with_the_fixed_message_and_never_prints_it(
    planted: Path, token: str
) -> None:
    result = wrap(planted)
    assert outcome(result) == (1, FOUND, "")
    assert token not in result.stdout + result.stderr


def test_a_planted_file_named_as_an_argument_is_found(planted: Path) -> None:
    assert outcome(wrap(planted, "config.py")) == (1, FOUND, "")


def test_a_clean_file_named_as_an_argument_passes_with_a_token_elsewhere(planted: Path) -> None:
    assert outcome(wrap(planted, "clean.txt")) == (0, "", "")


def test_a_path_starting_with_a_dash_is_scanned_not_read_as_a_flag(planted: Path) -> None:
    shutil.copy(planted / "config.py", planted / "-planted.py")
    assert outcome(wrap(planted, "-planted.py")) == (1, FOUND, "")


def test_a_flag_shaped_argument_is_a_path(planted: Path) -> None:
    (planted / "config.py").unlink()
    assert outcome(wrap(planted, "--no-such-flag")) == (0, "", "")


def test_any_other_status_is_kept_and_its_output_suppressed(worktree: Path, token: str) -> None:
    stand_in = worktree / ".tools" / "bin" / "ripsecrets"
    stand_in.write_text(f'#!/bin/sh\necho "{token}"; echo "{token}" >&2; exit 3\n')
    result = wrap(worktree)
    assert outcome(result) == (3, "ripsecrets failed with status 3; output suppressed", "")
    assert token not in result.stdout + result.stderr


def test_without_the_pinned_binary_another_on_path_is_never_used(
    worktree: Path, tmp_path: Path
) -> None:
    (worktree / ".tools" / "bin" / "ripsecrets").unlink()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "ripsecrets").write_text("#!/bin/sh\nexit 0\n")
    (elsewhere / "ripsecrets").chmod(0o755)
    result = wrap(worktree, PATH=f"{elsewhere}:{os.environ['PATH']}")
    assert outcome(result) == (2, "", UNAVAILABLE)


def test_a_pinned_path_that_is_not_executable_is_refused(worktree: Path) -> None:
    (worktree / ".tools" / "bin" / "ripsecrets").write_text("not a binary\n")
    (worktree / ".tools" / "bin" / "ripsecrets").chmod(0o644)
    assert outcome(wrap(worktree)) == (2, "", UNAVAILABLE)


def test_outside_a_git_worktree_the_wrapper_refuses(tmp_path: Path) -> None:
    outside = tmp_path / "not-a-repo"
    outside.mkdir()
    result = wrap(outside, GIT_CEILING_DIRECTORIES=str(tmp_path))
    assert outcome(result) == (
        2,
        "",
        "ripsecrets-redacted: run this from inside a Git worktree",
    )


def test_the_wrapper_finds_its_binary_from_a_subdirectory(planted: Path) -> None:
    (planted / "sub").mkdir()
    assert outcome(wrap(planted / "sub", "../config.py")) == (1, FOUND, "")
