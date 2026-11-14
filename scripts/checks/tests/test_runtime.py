"""The one reader of the OTP pin, and the one prefix the images ship their runtime at.

`image-check` and `hex-audit` both ask `_runtime.otp_pin` for the OTP version, so
a pin it cannot read as one exact version stops both with a named error.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import _runtime
from conftest import REPOSITORY

PIXI_TOML = """\
[dependencies]
gleam = "==1.19.0"

[feature.otp.dependencies]
erlang = "==29.1.1"
"""


def project(tmp_path: Path, pixi_toml: str) -> Path:
    (tmp_path / "pixi.toml").write_text(pixi_toml)
    return tmp_path


def test_the_otp_pin_is_the_exact_erlang_pin(tmp_path: Path) -> None:
    assert _runtime.otp_pin(project(tmp_path, PIXI_TOML)) == "29.1.1"


@pytest.mark.parametrize(
    "pin",
    [
        '">=29.1.1"',
        '"29.1.*"',
        '"==29.1.1,<30"',
        '"29.1.1"',
        '"==29.1.1 "',
        '"==29.x"',
        '""',
        "29",
        '{ version = "==29.1.1" }',
    ],
)
def test_an_erlang_pin_that_is_not_exact_is_refused(tmp_path: Path, pin: str) -> None:
    written = project(tmp_path, PIXI_TOML.replace('"==29.1.1"', pin))
    with pytest.raises(
        _runtime.OtpPinError, match=r"^the erlang pin .+ is not one exact version$"
    ):
        _runtime.otp_pin(written)


@pytest.mark.parametrize(
    "pixi_toml",
    [
        pytest.param('[dependencies]\ngleam = "==1.19.0"\n', id="no otp feature"),
        pytest.param('[feature.otp.dependencies]\ngleam = "==1.19.0"\n', id="no erlang key"),
        pytest.param('[dependencies]\nerlang = "==29.1.1"\n', id="pinned outside the otp feature"),
        pytest.param('feature = "otp"\n', id="a feature that is not a table"),
        pytest.param("[feature.otp.dependencies", id="not TOML"),
    ],
)
def test_a_missing_erlang_pin_is_refused(tmp_path: Path, pixi_toml: str) -> None:
    with pytest.raises(
        _runtime.OtpPinError, match=r"^pixi\.toml has no erlang pin in \[feature\.otp\]: "
    ):
        _runtime.otp_pin(project(tmp_path, pixi_toml))


def test_a_project_without_pixi_toml_is_refused_by_its_path(tmp_path: Path) -> None:
    with pytest.raises(_runtime.OtpPinError, match=re.escape(str(tmp_path / "pixi.toml"))):
        _runtime.otp_pin(tmp_path)


def test_a_pixi_toml_that_is_not_text_is_refused(tmp_path: Path) -> None:
    (tmp_path / "pixi.toml").write_bytes(b"\xff\xfe")
    with pytest.raises(_runtime.OtpPinError, match="utf-8"):
        _runtime.otp_pin(tmp_path)


def test_the_committed_pin_is_one_exact_otp_29_version() -> None:
    assert re.fullmatch(r"29\.\d+(\.\d+)*", _runtime.otp_pin(REPOSITORY))


@pytest.mark.parametrize("dockerfile", ["Dockerfile", "fixtures/fake_worker/Dockerfile"])
def test_both_images_ship_the_runtime_at_the_prefix(dockerfile: str) -> None:
    lines = (REPOSITORY / dockerfile).read_text().splitlines()
    assert f"COPY --from=build {_runtime.PREFIX} {_runtime.PREFIX}" in lines
