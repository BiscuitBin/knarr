//// OTP and HTTP adapters. Every server process belongs to the root supervisor.

import gleam/bytes_tree
import gleam/erlang/process.{type Pid}
import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import knarr/diagnostics
import knarr/metrics
import knarr/poller_http
import knarr/s1_probe
import mist

pub type State

pub type Runtime {
  Runtime(pid: Pid, state: State)
}

@external(erlang, "runtime_ffi", "new_state")
fn new_state() -> State

@external(erlang, "runtime_ffi", "ready")
fn ready(state: State) -> Bool

@external(erlang, "runtime_ffi", "mark_ready")
fn mark_ready(state: State) -> Nil

@external(erlang, "runtime_ffi", "set_port")
fn set_port(state: State, port: Int) -> Nil

/// Starts the root supervisor: the listener first, then, with `poller`, the
/// poller's httpc profile, then, with `probe`, the S1 probe under its own
/// supervisor. Child ids count the children present from 0, so the
/// application, which turns `poller` on, has the profile at id 1 and any
/// probe at id 2. The profile is one per VM, since httpc names its tables
/// after it, so a second root in the same VM, as the tests start beside the
/// application, runs without it.
pub fn start(
  port port: Int,
  bind bind: String,
  poller poller: Bool,
  probe probe: Option(s1_probe.Config),
) -> actor.StartResult(Runtime) {
  let state = new_state()
  let child =
    supervision.supervisor(fn() {
      mist.new(fn(request) {
        let result = diagnostics.respond(request, ready(state), metrics.collect)
        response.set_body(
          result,
          mist.Bytes(bytes_tree.from_string(result.body)),
        )
      })
      |> mist.bind(bind)
      |> mist.port(port)
      |> mist.after_start(fn(port, _, _) { set_port(state, port) })
      |> mist.start
    })
  let root =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(intensity: 2, period: 5)
    |> supervisor.add(child)
  let root = case poller {
    True -> supervisor.add(root, poller_http.supervised())
    False -> root
  }
  let root = case probe {
    Some(config) -> supervisor.add(root, s1_probe.supervised(config))
    None -> root
  }
  case supervisor.start(root) {
    Ok(started) -> {
      mark_ready(state)
      Ok(actor.Started(started.pid, Runtime(started.pid, state)))
    }
    Error(error) -> Error(error)
  }
}
