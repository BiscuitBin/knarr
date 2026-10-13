"""The runtime environment scan: the image's conda records, copied out and scanned as a directory.

docker and grype are injected: every test hands main a fake `run`. The log lines
are grype 0.120.1's own, from `grype -vv dir:` runs on 2026-10-12. The scan fails
closed, so a log that shows no conda package catalogued is exit 1, never a pass.
"""

from __future__ import annotations

import io
import subprocess
from pathlib import Path

import pytest

import runtime_scan

IMAGE = "knarr:test"
CONTAINER = "0123456789ab"


def grype_log(conda: int | None) -> str:
    lines = [
        "[0000]  INFO grype version: 0.120.1",
        "[0000] DEBUG selected 57 package cataloger tasks from=syft",
        "[0002] DEBUG discovered 0 packages cataloger=python-package-cataloger from=syft",
        "[0002] DEBUG discovered 33 packages cataloger=erlang-otp-application-cataloger from=syft",
    ]
    if conda is not None:
        lines.append(
            f"[0002] DEBUG discovered {conda} packages cataloger=conda-meta-cataloger from=syft"
        )
    lines.append(
        "[0002]  INFO task completed elapsed=40.998083ms from=syft task=conda-meta-cataloger"
    )
    return "\n".join(lines) + "\n"


class Docker:
    """A fake `subprocess.run` for docker and grype that records each command."""

    def __init__(
        self, *, conda: int | None = 12, grype: int = 0, create: int = 0, copy: int = 0
    ) -> None:
        self.conda = conda
        self.codes = {"grype": grype, "create": create, "cp": copy}
        self.commands: list[list[str]] = []

    def __call__(self, arguments: list[str], **kwargs: object) -> subprocess.CompletedProcess:
        self.commands.append(arguments)
        if arguments[0] == "grype":
            log = kwargs["stderr"]
            assert isinstance(log, io.TextIOBase)
            log.write(grype_log(self.conda))
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


def test_a_clean_scan_passes_and_says_how_many_conda_packages_it_read(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, _ = scan(tmp_path, Docker(conda=12), capsys)
    assert code == 0
    assert "12 conda packages" in out


def test_a_finding_is_exit_2_as_image_scan_reports_one(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, _ = scan(tmp_path, Docker(grype=2), capsys)
    assert code == 2
    assert "12 conda packages" in out


@pytest.mark.parametrize(
    ("conda", "grype"),
    [
        pytest.param(None, 0, id="no conda-meta line, clean"),
        pytest.param(0, 0, id="0 conda packages, clean"),
        pytest.param(None, 2, id="no conda-meta line, a finding"),
        pytest.param(0, 2, id="0 conda packages, a finding"),
    ],
)
def test_a_scan_that_catalogued_no_conda_package_cannot_decide(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], conda: int | None, grype: int
) -> None:
    code, out, err = scan(tmp_path, Docker(conda=conda, grype=grype), capsys)
    assert code == 1
    assert "catalogued no conda package" in err
    assert "cataloger=erlang-otp-application-cataloger" in err
    assert "conda packages" not in out


@pytest.mark.parametrize("conda", [12, None], ids=["after cataloguing", "before cataloguing"])
def test_a_grype_error_cannot_decide_and_shows_the_log(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], conda: int | None
) -> None:
    code, _, err = scan(tmp_path, Docker(grype=1, conda=conda), capsys)
    assert code == 1
    assert "grype exited 1" in err
    assert "INFO grype version: 0.120.1" in err


def test_the_runtime_environment_is_copied_out_and_scanned_with_image_scans_thresholds(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    docker = Docker()
    scan(tmp_path, docker, capsys)
    copy = tmp_path / "runtime-scan/runtime"
    assert docker.commands == [
        ["docker", "create", "--pull=never", IMAGE],
        ["docker", "cp", f"{CONTAINER}:/opt/knarr/.pixi/envs/runtime", str(copy)],
        ["docker", "rm", "--force", CONTAINER],
        ["grype", "-vv", f"dir:{copy}", "--only-fixed", "--fail-on", "high"],
    ]
    assert "conda-meta-cataloger" in (tmp_path / "runtime-scan/grype.log").read_text()


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
    stale = tmp_path / "runtime-scan/runtime/conda-meta/perl-5.32.1-7_hd590300_perl5.json"
    stale.parent.mkdir(parents=True)
    stale.write_text("{}")
    scan(tmp_path, Docker(), capsys)
    assert not stale.exists()


def test_usage_needs_exactly_one_image(capsys: pytest.CaptureFixture[str]) -> None:
    assert runtime_scan.main([], run=Docker()) == 1
    assert "usage" in capsys.readouterr().err
