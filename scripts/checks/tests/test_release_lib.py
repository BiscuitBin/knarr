"""The release scripts' own shell tests run in the gate: the guards
(scripts/release/lib_test.sh) and the chart stamp (stamp-chart_test.sh)."""

import re
import subprocess

from conftest import REPOSITORY

SCRIPT = REPOSITORY / "scripts/release/lib_test.sh"
STAMP = REPOSITORY / "scripts/release/stamp-chart_test.sh"


def test_the_release_guards_pass_their_shell_tests():
    result = subprocess.run(["sh", str(SCRIPT)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.fullmatch(r"\d+ passed, 0 failed", result.stdout.splitlines()[-1]), result.stdout


def test_the_chart_stamp_passes_its_shell_tests():
    result = subprocess.run(["sh", str(STAMP)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.fullmatch(r"\d+ passed, 0 failed", result.stdout.splitlines()[-1]), result.stdout
