"""Ticket 52's attach to knarr on this worktree's kind cluster, run by
`just observer`, `observer-cli`, `observer-cli-install` and `remsh`, and never
by `just check`.

knarr must run the deploy/observer variant, which turns Erlang distribution on
inside the pod: one port, bound to the pod's loopback, with no epmd. Each
recipe forwards that port with `cluster.port_forward` and starts a hidden local
node that dials it. The host node listens nowhere and runs no epmd either:
`-erl_epmd_port` names the forwarded port as the one every node listens on, so
no lookup is made. The node, cookie and port are read from the overlay, so the
two sides cannot drift.

observer_cli runs on the target, through an rpc, so its modules and recon's are
compiled on the host and loaded into the pod's memory over distribution for the
session, then purged. Nothing enters the image or gleam.toml.
"""

from __future__ import annotations

import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import cluster
from keda_e2e import fetch_pinned

OVERLAY = cluster.ROOT / "deploy/observer/patch.json"
PACKAGES = cluster.ROOT / "fixtures/observer/packages.json"
HOW_TO = "docs/how-to/local-observer.md"
# The three that attach need the kind cluster; the install only downloads and
# compiles, so it runs before cluster-up too.
ATTACH = ("observer", "observer-cli", "remsh")
ACTIONS = (*ATTACH, "observer-cli-install")
# The OTP major of the pod's runtime environment: a node of another major may
# not speak to it, and observer_cli's beams are compiled on the host.
OTP_MAJOR = "29"


def overlay():
    """The pod's node name, cookie and distribution port, from the overlay."""
    container = json.loads(OVERLAY.read_text())["spec"]["template"]["spec"]["containers"][0]
    (flags,) = (env["value"].split() for env in container["env"] if env["name"] == "ERL_ZFLAGS")
    (port,) = (port["containerPort"] for port in container["ports"])
    return flags[flags.index("-name") + 1], flags[flags.index("-setcookie") + 1], port


NODE, COOKIE, DIST_PORT = overlay()


def host_flags(local_port):
    """A hidden node that never listens and dials the target on `local_port`. knarr
    holds one connection per node name, so each session names itself by its
    process id, and two at once do not collide."""
    return [
        "-name",
        f"observer-{os.getpid()}@127.0.0.1",
        "-hidden",
        "-start_epmd",
        "false",
        "-dist_listen",
        "false",
        "-erl_epmd_port",
        str(local_port),
        "-setcookie",
        COOKIE,
    ]


def observer_command(erl, local_port):
    """The GUI Observer on knarr, from a wx-capable `erl`, until its window closes."""
    return [
        erl,
        *host_flags(local_port),
        "-noshell",
        "-eval",
        f"observer:start_and_wait('{NODE}'), halt().",
    ]


def erlang_string(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


# Loads every module in the ebin onto the target, runs observer_cli there, and
# then removes them. A purge before each load clears what an interrupted session
# left, since load_binary refuses while old code remains. observer_cli returns
# quit when the user quits; anything else is a failed rpc or connection.
OBSERVER_CLI = """\
N = '{node}',
case net_kernel:hidden_connect_node(N) of
    true ->
        Ms = [list_to_atom(filename:basename(F, ".beam"))
            || F <- filelib:wildcard("*.beam", {ebin})],
        Result = try
            [{{module, M}} = begin
                rpc:call(N, code, purge, [M]),
                rpc:call(N, code, load_binary, [M, F, B])
            end
                || M <- Ms, {{M, B, F}} <- [code:get_object_code(M)]],
            observer_cli:start(N, '{cookie}')
        after
            [{{rpc:call(N, code, delete, [M]), rpc:call(N, code, purge, [M])}} || M <- Ms]
        end,
        case Result of
            quit -> halt();
            _ ->
                io:format(standard_error, "observer_cli failed: ~p~n", [Result]),
                halt(1)
        end;
    _ ->
        io:format(standard_error, "cannot connect to ~s: is deploy/observer deployed?~n", [N]),
        halt(1)
end."""


def observer_cli_command(erl, local_port, ebin):
    """observer_cli on knarr, its modules loaded from `ebin` for the session."""
    script = OBSERVER_CLI.format(node=NODE, cookie=COOKIE, ebin=erlang_string(str(ebin)))
    return [erl, *host_flags(local_port), "-noshell", "-pa", str(ebin), "-eval", script]


def remsh_command(erl, local_port):
    """A shell on knarr. Ctrl-G then q leaves it; q() would stop knarr."""
    return [erl, *host_flags(local_port), "-remsh", NODE]


# Prints the OTP major and whether wx has its driver: conda-forge's OTP ships
# wx without one, so it cannot open the GUI.
PROBE = (
    "Wx = case code:priv_dir(wx) of"
    ' {error, _} -> false; Dir -> filelib:wildcard("wxe_driver*", Dir) =/= [] end,'
    ' io:format("~s ~p~n", [erlang:system_info(otp_release), Wx]), halt().'
)


def check_erl(erl, gui):
    """Refuse an `erl` of another OTP major than the pod's, or, for the GUI,
    one whose wx has no driver."""
    answer = subprocess.run(
        [erl, "-noshell", "-eval", PROBE], capture_output=True, text=True, check=True
    ).stdout
    # The probe's line is the last; an erl may print a banner before it.
    found = re.search(r"^(\d+) (true|false)$", answer.strip().rpartition("\n")[2])
    if not found:
        raise ValueError(f"{erl} answered no OTP release: {answer.strip()!r}; see {HOW_TO}")
    major, wx = found.groups()
    if major != OTP_MAJOR:
        raise ValueError(f"{erl} is OTP {major}, not the pod's {OTP_MAJOR}; see {HOW_TO}")
    if gui and wx != "true":
        raise ValueError(f"{erl} has no wx driver, so it cannot open Observer; see {HOW_TO}")


def packages():
    return json.loads(PACKAGES.read_text())["packages"]


def fetch(state, package):
    """The package tarball's bytes, cached under .cluster/observer/packages/."""
    return fetch_pinned(
        state / "observer" / "packages", package["url"], package["sha256"]
    ).read_bytes()


def unpack(body, target):
    """A hex package's sources: its contents.tar.gz, extracted under `target`
    by tarfile's data filter, which refuses a member that would land outside."""
    try:
        with tarfile.open(fileobj=io.BytesIO(body)) as outer:
            contents = outer.extractfile("contents.tar.gz").read()
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
            inner.extractall(target, filter="data")
    except (tarfile.TarError, KeyError, AttributeError) as error:
        raise ValueError(f"unsafe archive {target.name}: {error}") from error


def install(state):
    """Download, check and compile recon and observer_cli into
    .cluster/observer/ebin/, which replaces the previous one only once every
    module has compiled."""
    work = state / "observer"
    build, partial, ebin = work / "build", work / "ebin.partial", work / "ebin"
    for directory in (build, partial):
        if directory.exists():
            shutil.rmtree(directory)
    partial.mkdir(parents=True)
    for package in packages():
        source = build / package["name"]
        unpack(fetch(state, package), source)
        cluster.run(
            "erlc",
            "-o",
            str(partial),
            "-pa",
            str(partial),
            "-I",
            str(source / "include"),
            *sorted(str(path) for path in (source / "src").glob("*.erl")),
        )
    if ebin.exists():
        shutil.rmtree(ebin)
    partial.replace(ebin)
    shutil.rmtree(build)
    return ebin


def main(argv):
    action, checkout = argv[:2]
    if action not in ACTIONS:
        raise ValueError(f"unknown observer action: {action}")
    if action == "observer-cli-install":
        # Private, as cluster-up makes it: the kubeconfig lands here later.
        state = Path(checkout).resolve() / ".cluster"
        state.mkdir(mode=0o700, exist_ok=True)
        print(f"ok   observer_cli compiled into {install(state)}")
        return 0
    _, _, state = cluster.environment(action, Path(checkout).resolve())
    if action == "observer":
        erl = argv[2] if len(argv) > 2 else ""
        if not erl:
            raise ValueError(f"name a wx-capable OTP {OTP_MAJOR} erl; see {HOW_TO}")
        check_erl(erl, gui=True)
        command = observer_command
    elif action == "observer-cli":
        ebin = state / "observer" / "ebin"
        if not ebin.is_dir():
            raise ValueError("observer_cli is not compiled; run just observer-cli-install")
        erl = "erl"
        check_erl(erl, gui=False)

        def command(erl, port):
            return observer_cli_command(erl, port, ebin)

    else:
        erl = "erl"
        check_erl(erl, gui=False)
        command = remsh_command
    try:
        with cluster.port_forward(state, "deployment/knarr", DIST_PORT) as port:
            return subprocess.run(command(erl, port), check=False).returncode
    except KeyboardInterrupt:
        # The user's stop, while the forward starts or the node runs, is not a
        # failure. Ctrl-C also stops kubectl, so an observer_cli session ends
        # without removing its modules; the next session's purge clears them.
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"observer: {error}", file=sys.stderr)
        sys.exit(1)
