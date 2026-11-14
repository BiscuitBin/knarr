"""The one reader of the OTP pin, and the one prefix the images ship their runtime at.

`image-check` and `hex-audit` both ask `_runtime.otp_pin` for the OTP version, so
a pin it cannot read as one exact version stops both with a named error. The
version is the `[exact]` `erlang` entry in pins.toml (Decision 0017).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import _runtime
from conftest import REPOSITORY

PINS_TOML = """\
[exact]
erlang = "29.1.1"
gleam = "1.19.0"

[minor]

[floor]
"""


def project(tmp_path: Path, pins_toml: str) -> Path:
    (tmp_path / "pins.toml").write_text(pins_toml)
    return tmp_path


def test_the_otp_pin_is_the_exact_erlang_version_pins_toml_holds(tmp_path: Path) -> None:
    assert _runtime.otp_pin(project(tmp_path, PINS_TOML)) == "29.1.1"


@pytest.mark.parametrize(
    "pin",
    ['">=29.1.1"', '"29.1.*"', '"==29.1.1"', '"29.1.1 "', '"29.x"', '""', "29", '{ v = "29" }'],
)
def test_an_erlang_version_that_is_not_exact_is_refused(tmp_path: Path, pin: str) -> None:
    written = project(tmp_path, PINS_TOML.replace('"29.1.1"', pin))
    with pytest.raises(_runtime.OtpPinError, match=r"^pins\.toml: \[exact\] erlang "):
        _runtime.otp_pin(written)


@pytest.mark.parametrize(
    "pins_toml",
    [
        pytest.param('[exact]\ngleam = "1.19.0"\n[minor]\n[floor]\n', id="no erlang key"),
        pytest.param('[exact]\n[minor]\nerlang = "29.1"\n[floor]\n', id="held as a minor"),
    ],
)
def test_a_missing_erlang_version_is_refused(tmp_path: Path, pins_toml: str) -> None:
    with pytest.raises(_runtime.OtpPinError, match=r"^pins\.toml holds no \[exact\] erlang$"):
        _runtime.otp_pin(project(tmp_path, pins_toml))


@pytest.mark.parametrize(
    "pins_toml",
    [
        pytest.param('[exact]\nerlang = "29.1.1"\n', id="no minor or floor table"),
        pytest.param('exact = "otp"\n', id="exact is not a table"),
        pytest.param("[exact", id="not TOML"),
    ],
)
def test_a_file_not_in_the_held_versions_shape_is_refused(tmp_path: Path, pins_toml: str) -> None:
    with pytest.raises(_runtime.OtpPinError, match=r"^pins\.toml"):
        _runtime.otp_pin(project(tmp_path, pins_toml))


def test_a_project_without_pins_toml_is_refused_by_its_path(tmp_path: Path) -> None:
    with pytest.raises(_runtime.OtpPinError, match=re.escape(str(tmp_path / "pins.toml"))):
        _runtime.otp_pin(tmp_path)


def test_a_pins_toml_that_is_not_text_is_refused(tmp_path: Path) -> None:
    (tmp_path / "pins.toml").write_bytes(b"\xff\xfe")
    with pytest.raises(_runtime.OtpPinError, match="utf-8"):
        _runtime.otp_pin(tmp_path)


def test_the_committed_pin_is_one_exact_otp_29_version() -> None:
    assert re.fullmatch(r"29\.\d+(\.\d+)*", _runtime.otp_pin(REPOSITORY))


@pytest.mark.parametrize("dockerfile", ["Dockerfile", "fixtures/fake_worker/Dockerfile"])
def test_both_images_ship_the_runtime_at_the_prefix(dockerfile: str) -> None:
    # The build stage links the prefix to the runtime environment inside the
    # tree it lays out under /out, beside the closure's store paths, and the
    # final stage takes that tree whole (Decision 0017).
    text = (REPOSITORY / dockerfile).read_text()
    lines = text.splitlines()
    assert _runtime.PREFIX == "/opt/knarr/runtime"
    assert "COPY --from=build /out/ /" in lines
    assert re.search(rf'ln -s "\$\(readlink [^)]+\)" /out{_runtime.PREFIX}$', text, re.MULTILINE)
    assert "xargs cp --archive --target-directory=/out/nix/store" in text
    assert f'ENV PATH="{_runtime.PREFIX}/bin:${{PATH}}" \\' in lines
