"""Attaching Observer, observer_cli and a remote shell to knarr on kind (ticket 52),
all offline.

The live attach is `just observer`, `just observer-cli` and `just remsh` against
the deploy/observer variant, which never runs in `just check`; these pin the
flags each host node starts with, what it checks of the erl it is given, what
`observer-cli-install` downloads and compiles, and the forward each one opens.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import re
import subprocess
import tarfile
from collections.abc import Iterator
from pathlib import Path

import pytest

import cluster
import keda_e2e
import observer
from conftest import REPOSITORY

PATCH = json.loads((REPOSITORY / "deploy/observer/patch.json").read_text())
PACKAGES = json.loads((REPOSITORY / "fixtures/observer/packages.json").read_text())
HOST = [
    "-name",
    f"observer-{os.getpid()}@127.0.0.1",
    "-hidden",
    "-start_epmd",
    "false",
    "-dist_listen",
    "false",
    "-erl_epmd_port",
    "54321",
    "-setcookie",
    "knarr-dev-only",
]


def test_the_node_cookie_and_port_are_the_overlays() -> None:
    container = PATCH["spec"]["template"]["spec"]["containers"][0]
    flags = container["env"][0]["value"].split()
    assert observer.NODE == flags[flags.index("-name") + 1] == "knarr@127.0.0.1"
    assert observer.COOKIE == flags[flags.index("-setcookie") + 1] == "knarr-dev-only"
    assert observer.DIST_PORT == container["ports"][0]["containerPort"] == 4370


def test_the_host_node_is_hidden_listens_nowhere_and_dials_the_forward() -> None:
    # No epmd on the host either: -start_epmd false, and -erl_epmd_port names the
    # forwarded port as the one every node listens on, so no lookup is made. The
    # name carries the process id: knarr holds one connection per node name, so
    # two sessions at once must not share one.
    assert observer.host_flags(54321) == HOST


def test_observer_opens_the_gui_on_knarr_and_halts_when_it_closes() -> None:
    assert observer.observer_command("/opt/otp/bin/erl", 54321) == [
        "/opt/otp/bin/erl",
        *HOST,
        "-noshell",
        "-eval",
        "observer:start_and_wait('knarr@127.0.0.1'), halt().",
    ]


def test_observer_cli_loads_its_modules_onto_knarr_and_removes_them_after() -> None:
    ebin = Path("/work/.cluster/observer/ebin")
    command = observer.observer_cli_command("erl", 54321, ebin)
    assert command[: 1 + len(HOST) + 4] == ["erl", *HOST, "-noshell", "-pa", str(ebin), "-eval"]
    (script,) = command[1 + len(HOST) + 4 :]
    assert 'filelib:wildcard("*.beam", "/work/.cluster/observer/ebin")' in script
    assert "rpc:call(N, code, load_binary, [M, F, B])" in script
    assert "observer_cli:start(N, 'knarr-dev-only')" in script
    # Old code is purged before a load and after the delete, so a session that
    # ended early leaves nothing a second one trips over.
    loads, removes = script.index("load_binary"), script.index("code, delete")
    assert script.index("code, purge") < loads < removes < script.rindex("code, purge")
    assert script.index("after") < removes
    # Only observer_cli's own quit is a clean exit; a failed rpc exits 1.
    assert "quit -> halt();" in script
    assert "halt(1)" in script[script.index("quit -> halt();") :]
    assert script.endswith("end.")


def test_an_ebin_path_is_a_literal_erlang_string_not_a_pattern() -> None:
    script = observer.observer_cli_command("erl", 1, Path('/a "b"\\c[2]{x}'))[-1]
    assert 'filelib:wildcard("*.beam", "/a \\"b\\"\\\\c[2]{x}")' in script


def test_remsh_opens_a_shell_on_knarr() -> None:
    assert observer.remsh_command("erl", 54321) == ["erl", *HOST, "-remsh", "knarr@127.0.0.1"]


def fake_erl(monkeypatch: pytest.MonkeyPatch, answer: str) -> list[list[str]]:
    calls: list[list[str]] = []

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=answer)

    monkeypatch.setattr(observer.subprocess, "run", run)
    return calls


def test_check_erl_accepts_the_pods_major_with_a_wx_driver(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = fake_erl(monkeypatch, "29 true\n")
    observer.check_erl("/opt/otp/bin/erl", gui=True)
    assert calls[0][:2] == ["/opt/otp/bin/erl", "-noshell"]


@pytest.mark.parametrize(
    ("answer", "gui", "problem"),
    [
        ("28 true\n", True, "OTP 28, not the pod's 29"),
        ("28 false\n", False, "OTP 28, not the pod's 29"),
        ("29 false\n", True, "no wx driver"),
        ("", False, "answered no OTP release"),
        ("a banner\n", False, "answered no OTP release"),
    ],
)
def test_check_erl_refuses_another_major_or_a_gui_without_wx(
    monkeypatch: pytest.MonkeyPatch, answer: str, gui: bool, problem: str
) -> None:
    fake_erl(monkeypatch, answer)
    with pytest.raises(ValueError, match=problem) as refused:
        observer.check_erl("/opt/otp/bin/erl", gui=gui)
    assert "docs/how-to/local-observer.md" in str(refused.value)


def test_check_erl_takes_the_terminal_side_without_wx(monkeypatch: pytest.MonkeyPatch) -> None:
    fake_erl(monkeypatch, "29 false\n")
    observer.check_erl("erl", gui=False)


def test_check_erl_reads_the_probes_line_after_a_banner(monkeypatch: pytest.MonkeyPatch) -> None:
    fake_erl(monkeypatch, "a banner\n29 true\n")
    observer.check_erl("erl", gui=True)


def test_the_packages_pin_recon_and_observer_cli_on_hex_by_sha256() -> None:
    names = [package["name"] for package in PACKAGES["packages"]]
    # recon first: observer_cli needs it on the code path to compile.
    assert names == ["recon", "observer_cli"]
    for package in PACKAGES["packages"]:
        assert package["url"] == (
            f"https://repo.hex.pm/tarballs/{package['name']}-{package['version']}.tar"
        )
        assert re.fullmatch(r"[0-9a-f]{64}", package["sha256"]), package


def hex_tarball(members: dict[str, bytes | str]) -> bytes:
    """A hex package: an outer tar whose contents.tar.gz holds `members`, each a
    file's bytes or, as a string, the target of a symbolic link."""
    inner = io.BytesIO()
    with tarfile.open(fileobj=inner, mode="w:gz") as archive:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            if isinstance(data, str):
                info.type, info.linkname = tarfile.SYMTYPE, data
                archive.addfile(info)
            else:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
    outer = io.BytesIO()
    with tarfile.open(fileobj=outer, mode="w") as archive:
        for name, data in {"VERSION": b"3", "contents.tar.gz": inner.getvalue()}.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return outer.getvalue()


def serve(
    monkeypatch: pytest.MonkeyPatch, bodies: dict[str, bytes], pin: bool = True
) -> list[list[str]]:
    """Serve `bodies` by package name, pin the fixture to their hashes unless told
    not to, and record each erlc instead of running it."""
    packages = [
        dict(package, sha256=hashlib.sha256(bodies[package["name"]]).hexdigest())
        if pin
        else package
        for package in PACKAGES["packages"]
    ]
    monkeypatch.setattr(observer, "packages", lambda: packages)
    by_url = {package["url"]: bodies[package["name"]] for package in packages}
    monkeypatch.setattr(
        keda_e2e.urllib.request, "urlopen", lambda url, **_: io.BytesIO(by_url[url])
    )
    compiled: list[list[str]] = []

    def run(*args: str, **_: object) -> None:
        compiled.append(list(args))
        Path(args[args.index("-o") + 1], "built.beam").write_bytes(b"")

    monkeypatch.setattr(cluster, "run", run)
    return compiled


def test_install_compiles_each_package_into_one_ebin(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    compiled = serve(
        monkeypatch,
        {
            "recon": hex_tarball({"src/recon.erl": b"-module(recon)."}),
            "observer_cli": hex_tarball(
                {"src/observer_cli.erl": b"-module(observer_cli).", "include/x.hrl": b""}
            ),
        },
    )
    ebin = observer.install(tmp_path)
    assert ebin == tmp_path / "observer/ebin"
    assert (ebin / "built.beam").is_file()
    assert not (tmp_path / "observer/ebin.partial").exists()
    work = tmp_path / "observer/build"
    partial = str(tmp_path / "observer/ebin.partial")
    assert compiled == [
        ["erlc", "-o", partial, "-pa", partial, "-I", str(work / name / "include"), source]
        for name, source in [
            ("recon", str(work / "recon/src/recon.erl")),
            ("observer_cli", str(work / "observer_cli/src/observer_cli.erl")),
        ]
    ]


def test_install_refuses_a_package_whose_hash_is_not_the_pin(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    serve(monkeypatch, {"recon": b"other", "observer_cli": b"other"}, pin=False)
    with pytest.raises(ValueError, match="sha256 mismatch"):
        observer.install(tmp_path)
    assert not list(tmp_path.rglob("*.tar"))
    assert not (tmp_path / "observer/ebin").exists()


@pytest.mark.parametrize(
    "member", [{"../escape.erl": b"x"}, {"src/link.erl": "../../../escape.erl"}]
)
def test_install_refuses_a_member_outside_its_directory(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, member: dict[str, bytes | str]
) -> None:
    unsafe = hex_tarball(member)
    serve(monkeypatch, {"recon": unsafe, "observer_cli": unsafe})
    with pytest.raises(ValueError, match="unsafe archive"):
        observer.install(tmp_path)
    assert not (tmp_path / "escape.erl").exists()
    assert not (tmp_path / "observer/ebin").exists()


def test_a_cached_package_is_reused_only_while_its_hash_matches(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    body = b"package bytes"
    package = dict(PACKAGES["packages"][0], sha256=hashlib.sha256(body).hexdigest())
    fetched = []

    def urlopen(url: str, **_: object) -> io.BytesIO:
        fetched.append(url)
        return io.BytesIO(body)

    monkeypatch.setattr(keda_e2e.urllib.request, "urlopen", urlopen)
    assert observer.fetch(tmp_path, package) == body
    assert observer.fetch(tmp_path, package) == body
    assert fetched == [package["url"]]
    next((tmp_path / "observer/packages").iterdir()).write_bytes(b"tampered")
    assert observer.fetch(tmp_path, package) == body
    assert fetched == [package["url"], package["url"]]


@pytest.mark.parametrize("action", observer.ATTACH)
def test_every_attach_refuses_kwok(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, action: str
) -> None:
    monkeypatch.setenv("KNARR_CLUSTER", "kwok")
    with pytest.raises(ValueError, match=f"{action} requires kind"):
        cluster.environment(action, tmp_path)


@pytest.fixture
def attach(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> dict[str, list[object]]:
    """main with the cluster, the forward, the erl check and the node faked."""
    seen: dict[str, list[object]] = {"forwards": [], "checked": [], "argv": []}
    monkeypatch.setattr(cluster, "environment", lambda *_: ("kind", "name", tmp_path))

    @contextlib.contextmanager
    def port_forward(state: Path, target: str, port: int) -> Iterator[int]:
        seen["forwards"].append((state, target, port))
        yield 54321

    monkeypatch.setattr(cluster, "port_forward", port_forward)
    monkeypatch.setattr(observer, "check_erl", lambda erl, gui: seen["checked"].append((erl, gui)))

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        seen["argv"].append(argv)
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(observer.subprocess, "run", run)
    return seen


def test_remsh_forwards_the_distribution_port_and_dials_the_port_kubectl_picked(
    attach: dict[str, list[object]], tmp_path: Path
) -> None:
    assert observer.main(["remsh", str(tmp_path)]) == 0
    assert attach["forwards"] == [(tmp_path, "deployment/knarr", 4370)]
    assert attach["checked"] == [("erl", False)]
    assert attach["argv"] == [observer.remsh_command("erl", 54321)]


def test_observer_uses_the_erl_it_is_given_and_checks_it_for_wx(
    attach: dict[str, list[object]], tmp_path: Path
) -> None:
    assert observer.main(["observer", str(tmp_path), "/opt/otp/bin/erl"]) == 0
    assert attach["checked"] == [("/opt/otp/bin/erl", True)]
    assert attach["argv"] == [observer.observer_command("/opt/otp/bin/erl", 54321)]


def test_observer_without_an_erl_names_the_how_to(
    attach: dict[str, list[object]], tmp_path: Path
) -> None:
    with pytest.raises(ValueError, match=re.escape("docs/how-to/local-observer.md")):
        observer.main(["observer", str(tmp_path), ""])
    assert attach["forwards"] == []


def test_observer_cli_needs_the_install_first(
    attach: dict[str, list[object]], tmp_path: Path
) -> None:
    with pytest.raises(ValueError, match="just observer-cli-install"):
        observer.main(["observer-cli", str(tmp_path)])
    assert attach["forwards"] == []
    (tmp_path / "observer/ebin").mkdir(parents=True)
    assert observer.main(["observer-cli", str(tmp_path)]) == 0
    ebin = tmp_path / "observer/ebin"
    assert attach["argv"] == [observer.observer_cli_command("erl", 54321, ebin)]


@pytest.mark.usefixtures("attach")
@pytest.mark.parametrize("during", ["the attach", "the forward's wait"])
def test_ctrl_c_is_a_clean_stop(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, during: str
) -> None:
    def interrupted(*_: object, **__: object) -> None:
        raise KeyboardInterrupt

    if during == "the attach":
        monkeypatch.setattr(observer.subprocess, "run", interrupted)
    else:
        monkeypatch.setattr(cluster, "port_forward", interrupted)
    assert observer.main(["remsh", str(tmp_path)]) == 0


def test_the_install_needs_no_cluster(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # It only downloads and compiles, so it runs before cluster-up and under kwok.
    monkeypatch.setenv("KNARR_CLUSTER", "kwok")
    installed = []
    monkeypatch.setattr(observer, "install", installed.append)
    assert observer.main(["observer-cli-install", str(tmp_path)]) == 0
    state = tmp_path.resolve() / ".cluster"
    assert installed == [state]
    # The state directory later holds the kubeconfig, so the install creates it
    # private, as cluster-up does.
    assert state.stat().st_mode & 0o777 == 0o700


def test_an_unknown_action_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="unknown observer action"):
        observer.main(["observer-gui", str(tmp_path)])
