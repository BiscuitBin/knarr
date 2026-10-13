"""Process-level proof of the generated entrypoint and OTP application callback."""

import os
import socket
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]


def test_restart_exhaustion_exits_vm():
    # A test-only process injects crashes into the real application-owned tree.
    expression = """
        spawn(fun() ->
            Await = fun Wait() ->
                case lists:keymember(knarr, 1, application:which_applications()) of
                    true -> {ok, Pid} = application:get_supervisor(knarr), Pid;
                    false -> timer:sleep(10), Wait()
                end
            end,
            Root = Await(),
            timer:sleep(100),
            Crash = fun Again(0, _) -> ok;
                Again(N, Previous) ->
                    case catch lists:keyfind(0, 1, supervisor:which_children(Root)) of
                        {0, Pid, supervisor, _} when is_pid(Pid), Pid =/= Previous ->
                            exit(Pid, kill), Again(N - 1, Pid);
                        _ -> timer:sleep(10), Again(N, Previous)
                    end
            end,
            Crash(3, undefined)
        end),
        'knarr@@main':run(knarr).
    """
    try:
        result = subprocess.run(
            [
                "erl",
                "-noshell",
                "-pa",
                *map(str, (ROOT / "build/dev/erlang").glob("*/ebin")),
                "-eval",
                expression,
            ],
            env={**os.environ, "ERL_FLAGS": "-knarr port 0 bind '\"127.0.0.1\"'"},
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        assert b"reached_max_restart_intensity" in (error.stdout or b"")
        pytest.fail("VM stayed alive after application supervision was exhausted")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "reached_max_restart_intensity" in result.stdout


def test_occupied_port_exits_vm():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        result = subprocess.run(
            [
                "erl",
                "-noshell",
                "-pa",
                *map(str, (ROOT / "build/dev/erlang").glob("*/ebin")),
                "-eval",
                "'knarr@@main':run(knarr).",
            ],
            env={**os.environ, "ERL_FLAGS": f"-knarr port {port} bind '\"127.0.0.1\"'"},
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Eaddrinuse" in result.stdout


def test_normal_vm_shutdown_exits_successfully():
    expression = """
        spawn(fun() ->
            Await = fun Wait() ->
                case lists:keymember(knarr, 1, application:which_applications()) of
                    true -> timer:sleep(100), init:stop();
                    false -> timer:sleep(10), Wait()
                end
            end,
            Await()
        end),
        'knarr@@main':run(knarr).
    """
    result = subprocess.run(
        [
            "erl",
            "-noshell",
            "-pa",
            *map(str, (ROOT / "build/dev/erlang").glob("*/ebin")),
            "-eval",
            expression,
        ],
        env={**os.environ, "ERL_FLAGS": "-knarr port 0 bind '\"127.0.0.1\"'"},
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
