"""The runtime scan: the image's Nix store, copied out and scanned as a directory.

docker and grype are injected: every test hands main a fake `run`. The log lines
are grype 0.120.0's own, from a `grype -vv dir:` run over a built image's store
on 2026-11-14. The scan fails closed, so a log that shows no store package
catalogued is exit 1, never a pass.
"""

from __future__ import annotations

import io
import subprocess
from pathlib import Path

import pytest

import runtime_scan

IMAGE = "knarr:test"
CONTAINER = "0123456789ab"


def grype_log(store: int | None) -> str:
    lines = [
        "[0000]  INFO grype version: 0.120.0",
        "[0000] DEBUG selected 57 package cataloger tasks from=syft",
        "[0001] DEBUG discovered 0 packages cataloger=python-package-cataloger from=syft",
        "[0001] DEBUG discovered 34 packages cataloger=erlang-otp-application-cataloger from=syft",
    ]
    if store is not None:
        lines.append(f"[0001] DEBUG discovered {store} packages cataloger=nix-cataloger from=syft")
    lines.append("[0001]  INFO task completed elapsed=977.711µs from=syft task=unknowns-labeler")
    return "\n".join(lines) + "\n"


class Docker:
    """A fake `subprocess.run` for docker and grype that records each command."""

    def __init__(
        self, *, store: int | None = 18, grype: int = 0, create: int = 0, copy: int = 0
    ) -> None:
        self.store = store
        self.codes = {"grype": grype, "create": create, "cp": copy}
        self.commands: list[list[str]] = []

    def __call__(self, arguments: list[str], **kwargs: object) -> subprocess.CompletedProcess:
        self.commands.append(arguments)
        if arguments[0] == "grype":
            log = kwargs["stderr"]
            assert isinstance(log, io.TextIOBase)
            log.write(grype_log(self.store))
            return subprocess.CompletedProcess(arguments, self.codes["grype"])
        verb = arguments[1]
        if verb == "create":
            return subprocess.CompletedProcess(
                arguments, self.codes["create"], f"{CONTAINER}\n", "no such image"
            )
        return subprocess.CompletedProcess(arguments, self.codes.get(verb, 0), "", "")


def scan(
    tmp_path: Path, docker: Docker, capsys: pytest.CaptureFixture[str]
) -> tuple[int, str, str]:
    code = runtime_scan.main([IMAGE], run=docker, target=tmp_path / "runtime-scan")
    out, err = capsys.readouterr()
    return code, out, err


def test_a_clean_scan_passes_and_says_how_many_store_packages_it_read(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, _ = scan(tmp_path, Docker(store=18), capsys)
    assert code == 0
    assert "18 store packages" in out


def test_a_finding_is_exit_2_as_image_scan_reports_one(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, _ = scan(tmp_path, Docker(grype=2), capsys)
    assert code == 2
    assert "18 store packages" in out


@pytest.mark.parametrize(
    ("store", "grype"),
    [
        pytest.param(None, 0, id="no nix-cataloger line, clean"),
        pytest.param(0, 0, id="0 store packages, clean"),
        pytest.param(None, 2, id="no nix-cataloger line, a finding"),
        pytest.param(0, 2, id="0 store packages, a finding"),
    ],
)
def test_a_scan_that_catalogued_no_store_package_cannot_decide(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], store: int | None, grype: int
) -> None:
    code, out, err = scan(tmp_path, Docker(store=store, grype=grype), capsys)
    assert code == 1
    assert "catalogued no store package" in err
    assert "cataloger=erlang-otp-application-cataloger" in err
    assert "store packages" not in out


@pytest.mark.parametrize("store", [18, None], ids=["after cataloguing", "before cataloguing"])
def test_a_grype_error_cannot_decide_and_shows_the_log(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], store: int | None
) -> None:
    code, _, err = scan(tmp_path, Docker(grype=1, store=store), capsys)
    assert code == 1
    assert "grype exited 1" in err
    assert "INFO grype version: 0.120.0" in err


def test_the_store_is_copied_out_and_scanned_with_image_scans_thresholds(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    docker = Docker()
    scan(tmp_path, docker, capsys)
    # The copy keeps nix/store in its path, which is how the cataloger knows it.
    copy = tmp_path / "runtime-scan/image"
    assert docker.commands == [
        ["docker", "create", "--pull=never", IMAGE],
        ["docker", "cp", f"{CONTAINER}:/nix", str(copy / "nix")],
        ["docker", "rm", "--force", CONTAINER],
        ["grype", "-vv", f"dir:{copy}", "--only-fixed", "--fail-on", "high"],
    ]
    assert "nix-cataloger" in (tmp_path / "runtime-scan/grype.log").read_text()


def test_the_container_is_removed_when_the_copy_fails(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    docker = Docker(copy=1)
    code, _, err = scan(tmp_path, docker, capsys)
    assert code == 1
    assert "docker cp" in err
    assert docker.commands[-1] == ["docker", "rm", "--force", CONTAINER]
    assert not any(command[0] == "grype" for command in docker.commands)


def test_an_image_it_cannot_create_a_container_from_cannot_decide(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    docker = Docker(create=1)
    code, _, err = scan(tmp_path, docker, capsys)
    assert code == 1
    assert "no such image" in err
    assert docker.commands == [["docker", "create", "--pull=never", IMAGE]]


def test_an_earlier_copy_is_cleared_before_the_scan(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    stale = tmp_path / "runtime-scan/image/nix/store/0000-openssl-3.5.9/bin/openssl"
    stale.parent.mkdir(parents=True)
    stale.write_text("")
    # `docker cp` keeps the store's read-only directory modes.
    stale.parent.chmod(0o555)
    stale.parent.parent.chmod(0o555)
    scan(tmp_path, Docker(), capsys)
    assert not stale.exists()


def test_the_copy_is_left_removable(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    class Copying(Docker):
        def __call__(self, arguments: list[str], **kwargs: object) -> subprocess.CompletedProcess:
            if arguments[:2] == ["docker", "cp"]:
                package = Path(arguments[3]) / "store/0000-zlib-1.3.2"
                package.mkdir(parents=True)
                package.chmod(0o555)
            return super().__call__(arguments, **kwargs)

    scan(tmp_path, Copying(), capsys)
    package = tmp_path / "runtime-scan/image/nix/store/0000-zlib-1.3.2"
    assert package.stat().st_mode & 0o700 == 0o700


def test_usage_needs_exactly_one_image(capsys: pytest.CaptureFixture[str]) -> None:
    assert runtime_scan.main([], run=Docker()) == 1
    assert "usage" in capsys.readouterr().err
