"""Drive birdie's interactive review through a pseudo-terminal (ticket 35).

Usage: python3 review_pty.py <log> <answer> <command...>

Runs the command with a pseudo-terminal as its standard input, output and
error, so `birdie review` reads its choice from a terminal, as it does for a
person. Each time its menu ends at the "> " prompt, this types <answer> and
Enter. The whole session goes to <log>, with terminal escape sequences removed
and carriage returns made newlines. Exits with the command's status, or 2 if
the command has not finished within ten minutes.
"""

from __future__ import annotations

import os
import pty
import re
import select
import subprocess
import sys
import time
from pathlib import Path

TIMEOUT_SECONDS = 600
ESCAPE = re.compile(rb"\x1b(?:\[[0-9;?]*[A-Za-z]|[@-~])")
MENU = b"accept the new snapshot"


def plain(data: bytes) -> bytes:
    """Return terminal output without escape sequences or carriage returns."""
    return ESCAPE.sub(b"", data).replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def main() -> int:
    """Run the command, answer every review prompt, and return its status."""
    log, answer, *command = sys.argv[1:]
    primary, secondary = pty.openpty()
    child = subprocess.Popen(  # noqa: S603 - the command is the caller's argv
        command, stdin=secondary, stdout=secondary, stderr=secondary, close_fds=True
    )
    os.close(secondary)
    output = bytearray()
    since = 0  # where the output after the last answer starts
    answers = 0
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        ready, _, _ = select.select([primary], [], [], 1.0)
        if not ready:
            if child.poll() is not None:
                break
            continue
        try:
            chunk = os.read(primary, 4096)
        except OSError:  # EIO: every process holding the terminal has exited
            break
        if not chunk:
            break
        output += chunk
        segment = ESCAPE.sub(b"", bytes(output[since:]))
        if MENU in segment and segment.endswith(b"> "):
            os.write(primary, answer.encode() + b"\r")
            answers += 1
            since = len(output)
    else:
        child.kill()
        child.wait()
        Path(log).write_bytes(plain(bytes(output)))
        print(f"review_pty: timed out after {TIMEOUT_SECONDS} s; {answers} prompt(s) answered")
        return 2
    status = child.wait()
    os.close(primary)
    Path(log).write_bytes(plain(bytes(output)))
    print(f"review_pty: answered {answers} prompt(s) with {answer!r}; exit {status}")
    return status


if __name__ == "__main__":
    sys.exit(main())
