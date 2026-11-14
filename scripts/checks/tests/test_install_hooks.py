"""Hooks install only from the primary checkout (ticket 03).

Every linked worktree shares the primary checkout's .git/hooks, and prek writes
a shim that names an absolute path into whichever worktree ran it. A hook
installed from a linked worktree would break every commit once that worktree
is deleted, so a linked worktree skips the step with a notice and succeeds.

Under Nix that path is a store path, which a lock move leaves behind, so
`just initialize` passes the out-link's prek and the hook is rewritten to run
it (Decision 0017, "The prek hook").
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from conftest import REPOSITORY, git

SCRIPT = REPOSITORY / "scripts" / "install-hooks.sh"


@pytest.fixture
def prek(tmp_path: Path) -> tuple[Path, Path]:
    """A stand-in prek that records each call, and the file it records to."""
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    calls = tmp_path / "prek-calls"
    (stubs / "prek").write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{calls}"\n')
    (stubs / "prek").chmod(0o755)
    return stubs, calls


def install(directory: Path, stubs: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(SCRIPT), *arguments],
        cwd=directory,
        env={**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}"},
        check=False,
        capture_output=True,
        text=True,
    )


@pytest.fixture
def committed(repository: Path) -> Path:
    (repository / "README.md").write_text("seed\n")
    git(repository, "add", ".")
    git(repository, "commit", "-qm", "seed")
    return repository


def test_the_primary_checkout_installs_the_hooks(committed: Path, prek: tuple[Path, Path]) -> None:
    stubs, calls = prek
    result = install(committed, stubs)
    assert result.returncode == 0, result.stderr
    assert calls.read_text().splitlines() == ["install --overwrite --hook-type pre-commit"]


def test_a_subdirectory_of_the_primary_checkout_installs_the_hooks(
    committed: Path, prek: tuple[Path, Path]
) -> None:
    stubs, calls = prek
    (committed / "sub").mkdir()
    assert install(committed / "sub", stubs).returncode == 0
    assert calls.exists()


def test_a_linked_worktree_skips_with_a_notice_and_succeeds(
    committed: Path, prek: tuple[Path, Path], tmp_path: Path
) -> None:
    stubs, calls = prek
    linked = tmp_path / "linked"
    git(committed, "worktree", "add", "-q", "-b", "99-linked", str(linked))
    result = install(linked, stubs)
    assert result.returncode == 0, result.stderr
    assert not calls.exists(), "prek must not run from a linked worktree"
    assert "linked worktree" in result.stderr
    assert "primary checkout" in result.stderr


# What prek 0.5.10 writes, trimmed: the resolved path of the prek that ran,
# which under Nix is a store path that does not follow a lock move
# (Decision 0017, "The prek hook").
STORE_PREK = "/nix/store/00000000000000000000000000000000-prek-0.5.10/bin/prek"


@pytest.fixture
def storing_prek(tmp_path: Path) -> Path:
    """A stand-in prek that writes a hook naming its store path, as Nix's does."""
    stubs = tmp_path / "storing"
    stubs.mkdir()
    (stubs / "prek").write_text(
        "#!/bin/sh\n"
        "hook=$(git rev-parse --path-format=absolute --git-path hooks/pre-commit)\n"
        'mkdir -p "${hook%/*}"\n'
        f"printf '%s\\n' '#!/bin/sh' 'PREK=\"{STORE_PREK}\"' "
        "'if [ ! -x \"$PREK\" ]; then' '    PREK=\"prek\"' 'fi' "
        '\'exec "$PREK" hook-impl --hook-type=pre-commit -- "$@"\' > "$hook"\n'
        'chmod 0755 "$hook"\n'
    )
    (stubs / "prek").chmod(0o755)
    return stubs


def hook(repository: Path) -> Path:
    return repository / ".git" / "hooks" / "pre-commit"


def test_without_a_path_the_hook_is_left_as_prek_wrote_it(
    committed: Path, storing_prek: Path
) -> None:
    assert install(committed, storing_prek).returncode == 0
    assert f'PREK="{STORE_PREK}"' in hook(committed).read_text().splitlines()


def test_given_a_path_the_hook_runs_that_prek_and_names_no_store_path(
    committed: Path, storing_prek: Path
) -> None:
    outlink = committed / ".nix" / "default" / "bin" / "prek"
    result = install(committed, storing_prek, str(outlink))
    assert result.returncode == 0, result.stderr
    lines = hook(committed).read_text().splitlines()
    assert [line for line in lines if line.startswith("PREK=")] == [f'PREK="{outlink}"']
    assert "/nix/store/" not in hook(committed).read_text()
    assert lines[-1] == 'exec "$PREK" hook-impl --hook-type=pre-commit -- "$@"'
    assert os.access(hook(committed), os.X_OK)


@pytest.mark.parametrize("prek_lines", [0, 2])
def test_a_hook_without_exactly_one_prek_line_is_refused(
    committed: Path, storing_prek: Path, prek_lines: int
) -> None:
    script = (storing_prek / "prek").read_text()
    written = {0: "'# no prek line'", 2: f"'PREK=\"{STORE_PREK}\"' 'PREK=\"{STORE_PREK}\"'"}
    (storing_prek / "prek").write_text(
        script.replace(f"'PREK=\"{STORE_PREK}\"'", written[prek_lines])
    )
    result = install(committed, storing_prek, "/checkout/.nix/default/bin/prek")
    assert result.returncode == 1
    assert "PREK=" in result.stderr
