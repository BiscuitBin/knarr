"""The Erlang runtime the images ship: which OTP version, and at which prefix.

Each has one owner here, so a checker never parses the pin or spells the prefix
itself:

- `otp_pin` is the only reader of the OTP version, the exact `erlang` pin in
    pixi.toml (Decision 0003). `image-check` compares the image's OTP release with
    it and `hex-audit` asks OSV.dev about it.
- `PREFIX` is where both Dockerfiles copy pixi's `runtime` environment.
    `image-check` inspects it there and `runtime-scan` copies it out from there.

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import re
import tomllib
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path

PREFIX = "/opt/knarr/.pixi/envs/runtime"


class OtpPinError(Exception):
    """The OTP pin is missing, unreadable, or not one exact version."""


def otp_pin(project: Path) -> str:
    """The OTP version the exact `erlang` pin in `project`'s pixi.toml names."""
    try:
        pixi_text = (project / "pixi.toml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise OtpPinError(str(error)) from error
    try:
        pin = tomllib.loads(pixi_text)["feature"]["otp"]["dependencies"]["erlang"]
    except (tomllib.TOMLDecodeError, KeyError, TypeError) as error:
        raise OtpPinError(f"pixi.toml has no erlang pin in [feature.otp]: {error}") from error
    match = re.fullmatch(r"==(\d+(?:\.\d+)*)", pin) if isinstance(pin, str) else None
    if match is None:
        raise OtpPinError(f"the erlang pin {pin!r} is not one exact version")
    return match[1]
