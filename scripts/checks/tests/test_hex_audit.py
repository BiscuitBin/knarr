"""The hex advisory audit: manifest.toml's hex packages and the OTP pin against OSV.dev.

The network is injected: every test here hands main a fake `post`, and the
responses are copies of what api.osv.dev answered on 2026-10-09 (UTC). The
audit fails closed, so anything it cannot read is exit 2, never a pass.
"""

from __future__ import annotations

import http.client
import urllib.error
from pathlib import Path

import pytest

import _runtime
import hex_audit
from conftest import REPOSITORY

# editorconfig-checker-disable
MANIFEST = """\
packages = [
  { name = "hpack_erl", version = "0.3.0", build_tools = ["rebar3"], requirements = [], otp_app = "hpack", source = "hex", outer_checksum = "D6" },
  { name = "mist", version = "6.0.3", build_tools = ["gleam"], requirements = [], otp_app = "mist", source = "hex", outer_checksum = "1B" },
  { name = "local_thing", version = "0.1.0", build_tools = ["gleam"], requirements = [], source = "local", path = "../local_thing" },
  { name = "forked", version = "1.0.0", build_tools = ["gleam"], requirements = [], source = "git", repo = "https://example.invalid/forked", commit = "abc" },
]

[requirements]
mist = { version = ">= 6.0.3 and < 7.0.0" }
"""
# editorconfig-checker-enable

PIXI_TOML = """\
[dependencies]
gleam = "==1.19.0"

[feature.otp.dependencies]
erlang = "==29.1.1"
"""

SUBJECTS = [
    hex_audit.Subject("Hex", "hpack_erl", "0.3.0"),
    hex_audit.Subject("Hex", "mist", "6.0.3"),
    hex_audit.Subject("GIT", "https://github.com/erlang/otp", "OTP-29.1.1"),
]

# api.osv.dev's querybatch answers, trimmed to the subjects above. A query
# with no advisory comes back as an empty object.
CLEAN = {"results": [{}, {}, {}]}
# plug 1.3.0, the control: GitHub's advisories for the erlang ecosystem list
# GHSA-2q6v-32mr-8p8x (CVE-2017-1000052) against it.
CONTROL = [hex_audit.Subject("Hex", "plug", "1.3.0")]
CONTROL_ANSWER = {
    "results": [
        {
            "vulns": [
                {"id": "EEF-CVE-2026-56813", "modified": "2026-09-24T21:45:02.546503Z"},
                {"id": "GHSA-2q6v-32mr-8p8x", "modified": "2025-12-10T00:32:28.218425Z"},
            ]
        }
    ]
}


@pytest.fixture
def project(tmp_path: Path) -> Path:
    (tmp_path / "manifest.toml").write_text(MANIFEST)
    (tmp_path / "pixi.toml").write_text(PIXI_TOML)
    return tmp_path


def test_only_hex_packages_are_audited_by_their_hex_name() -> None:
    # hpack_erl's OTP application is hpack; Hex and OSV know it as hpack_erl.
    assert hex_audit.hex_packages(MANIFEST) == [("hpack_erl", "0.3.0"), ("mist", "6.0.3")]


@pytest.mark.parametrize(
    "manifest",
    [
        pytest.param('packages = ["mist"]\n', id="an entry that is not a table"),
        pytest.param('[packages]\nmist = "6.0.3"\n', id="a table, not a list"),
        pytest.param('packages = [{ name = "mist", source = "hex" }]\n', id="no version"),
        pytest.param("packages = [", id="not TOML"),
    ],
)
def test_a_manifest_it_cannot_read_cannot_be_audited(manifest: str) -> None:
    with pytest.raises(hex_audit.CannotDecideError, match=r"manifest\.toml"):
        hex_audit.hex_packages(manifest)


def test_the_subjects_end_with_the_otp_pin_the_shared_reader_returns(project: Path) -> None:
    assert hex_audit.subjects(project) == SUBJECTS


@pytest.mark.parametrize("pin", ['">=29.1.1"', '"29.1.*"', '"==29.1.1,<30"'])
def test_an_erlang_pin_that_is_not_exact_cannot_be_audited(project: Path, pin: str) -> None:
    (project / "pixi.toml").write_text(PIXI_TOML.replace('"==29.1.1"', pin))
    with pytest.raises(
        hex_audit.CannotDecideError, match=r"^the erlang pin .+ is not one exact version$"
    ) as refused:
        hex_audit.subjects(project)
    assert isinstance(refused.value.__cause__, _runtime.OtpPinError)


def _never_asked(_body: object) -> object:
    raise AssertionError("the audit asked OSV.dev without an OTP pin")


@pytest.mark.parametrize(
    ("pixi_toml", "reason"),
    [
        pytest.param(
            PIXI_TOML.replace("==29.1.1", ">=29.1.1"),
            "the erlang pin '>=29.1.1' is not one exact version",
            id="not exact",
        ),
        pytest.param(
            '[dependencies]\ngleam = "==1.19.0"\n',
            "pixi.toml has no erlang pin in [feature.otp]: 'feature'",
            id="missing",
        ),
        pytest.param(None, "pixi.toml'", id="no pixi.toml"),
    ],
)
def test_main_cannot_decide_without_an_exact_otp_pin(
    project: Path, capsys: pytest.CaptureFixture[str], pixi_toml: str | None, reason: str
) -> None:
    if pixi_toml is None:
        (project / "pixi.toml").unlink()
    else:
        (project / "pixi.toml").write_text(pixi_toml)
    code = hex_audit.main([str(project)], post=_never_asked)
    out, err = capsys.readouterr()
    assert code == 2
    assert out == ""
    assert err.startswith("hex-audit: cannot decide: ")
    assert err.rstrip().endswith(reason)


def test_the_query_asks_for_each_hex_release_and_the_otp_tag() -> None:
    assert hex_audit.batch_query(SUBJECTS) == {
        "queries": [
            {"package": {"ecosystem": "Hex", "name": "hpack_erl"}, "version": "0.3.0"},
            {"package": {"ecosystem": "Hex", "name": "mist"}, "version": "6.0.3"},
            {
                "package": {"ecosystem": "GIT", "name": "https://github.com/erlang/otp"},
                "version": "OTP-29.1.1",
            },
        ]
    }


def test_a_clean_answer_has_no_finding() -> None:
    assert hex_audit.findings(SUBJECTS, CLEAN) == []


def test_each_advisory_is_reported_with_its_release_and_link() -> None:
    assert hex_audit.findings(CONTROL, CONTROL_ANSWER) == [
        "EEF-CVE-2026-56813  plug 1.3.0  https://osv.dev/vulnerability/EEF-CVE-2026-56813",
        "GHSA-2q6v-32mr-8p8x  plug 1.3.0  https://osv.dev/vulnerability/GHSA-2q6v-32mr-8p8x",
    ]


@pytest.mark.parametrize(
    "answer",
    [
        pytest.param({"results": [{}, {}]}, id="one result short"),
        pytest.param({"results": [{}, {}, {}, {}]}, id="one result over"),
        pytest.param({"results": [{}, {"next_page_token": "x"}, {}]}, id="a further page"),
        pytest.param({}, id="no results"),
        pytest.param(["results"], id="not an object"),
        pytest.param({"results": [{}, [], {}]}, id="a result that is not an object"),
        pytest.param({"results": [{}, {"vulns": {}}, {}]}, id="vulns that are not a list"),
        pytest.param({"results": [{}, {"vulns": [{"modified": "x"}]}, {}]}, id="no id"),
        pytest.param({"results": [{}, {"vulns": [{"id": 7}]}, {}]}, id="an id that is not text"),
    ],
)
def test_an_answer_it_cannot_read_is_never_a_pass(answer: object) -> None:
    with pytest.raises(hex_audit.CannotDecideError):
        hex_audit.findings(SUBJECTS, answer)


def _tree(directory: Path) -> dict[str, bytes]:
    return {str(p.relative_to(directory)): p.read_bytes() for p in directory.rglob("*")}


def run(project: Path, post: object, capsys: pytest.CaptureFixture[str]) -> tuple[int, str, str]:
    before = _tree(project)
    sent: list[object] = []

    def recorded(body: object) -> object:
        sent.append(body)
        return post(body) if callable(post) else post

    code = hex_audit.main([str(project)], post=recorded)
    assert _tree(project) == before, "the audit must never write"
    assert sent == [hex_audit.batch_query(SUBJECTS)]
    out, err = capsys.readouterr()
    return code, out, err


def test_main_passes_a_clean_answer(project: Path, capsys: pytest.CaptureFixture[str]) -> None:
    code, out, _ = run(project, CLEAN, capsys)
    assert code == 0
    assert "no advisory" in out
    assert "2 hex packages" in out
    assert "Erlang/OTP 29.1.1" in out


def test_main_fails_on_an_advisory(project: Path, capsys: pytest.CaptureFixture[str]) -> None:
    answer = {"results": [{}, CONTROL_ANSWER["results"][0], {}]}
    code, out, _ = run(project, answer, capsys)
    assert code == 1
    assert (
        "GHSA-2q6v-32mr-8p8x  mist 6.0.3  https://osv.dev/vulnerability/GHSA-2q6v-32mr-8p8x" in out
    )
    assert "2 advisories" in out


def _refused(_body: object) -> object:
    raise urllib.error.URLError("connection refused")


def _truncated(_body: object) -> object:
    partial = b"{"
    raise http.client.IncompleteRead(partial)


def _server_error(_body: object) -> object:
    raise urllib.error.HTTPError("https://api.osv.dev/v1/querybatch", 503, "unavailable", {}, None)


@pytest.mark.parametrize(
    "post",
    [_refused, _server_error, _truncated, {"results": [{}]}],
    ids=["refused", "503", "truncated", "short"],
)
def test_main_cannot_decide_without_a_whole_answer(
    project: Path, post: object, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, err = run(project, post, capsys)
    assert code == 2
    assert out == ""
    assert "cannot decide" in err


def test_the_committed_project_audits_every_hex_package_and_the_otp_pin() -> None:
    manifest = (REPOSITORY / "manifest.toml").read_text()
    audited = hex_audit.subjects(REPOSITORY)
    assert len(audited) == manifest.count('source = "hex"') + 1
    assert hex_audit.Subject("Hex", "mist", "6.0.3") in audited
    assert audited[-1].ecosystem == "GIT"
    assert audited[-1].version.startswith("OTP-29.")
