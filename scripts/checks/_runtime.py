"""The Erlang runtime the images ship: which OTP version, and at which prefix.

Each has one owner here, so a checker never parses the pin or spells the prefix
itself:

- `otp_pin` is the only reader of the OTP version, the `[exact]` `erlang` entry
    in pins.toml (Decision 0017), which flake.nix asserts its Erlang against.
    `image-check` compares the image's OTP release with it and `hex-audit` asks
    OSV.dev about it. Until ticket 13 a policy test holds pixi.toml's `erlang`
    pin equal to it.
- `PREFIX` is where both Dockerfiles copy pixi's `runtime` environment.
    `image-check` inspects it there and `runtime-scan` copies it out from there.

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import _pins

if TYPE_CHECKING:
    from pathlib import Path

PREFIX = "/opt/knarr/.pixi/envs/runtime"


class OtpPinError(Exception):
    """The OTP pin is missing, unreadable, or not one exact version."""


def otp_pin(project: Path) -> str:
    """The OTP version `project`'s pins.toml holds exactly, as a bare dotted version."""
    try:
        return _pins.version(project, "exact", "erlang")
    except _pins.PinsError as error:
        raise OtpPinError(str(error)) from error
