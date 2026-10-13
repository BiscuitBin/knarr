import gleam/option.{None}
import gleeunit/should
import knarr/runtime

@external(erlang, "runtime_test_ffi", "recover")
fn recover(root: runtime.Runtime, same_port same_port: Bool) -> Bool

pub fn listener_recovers_and_preserves_metrics_test() -> Nil {
  let started =
    runtime.start(port: 0, bind: "127.0.0.1", poller: False, probe: None)
    |> should.be_ok
  assert recover(started.data, same_port: False)
}

@external(erlang, "runtime_test_ffi", "start_on_free_port")
fn start_on_free_port(start: fn(Int) -> result) -> runtime.Runtime

pub fn fixed_port_listener_recovers_on_the_same_port_test() -> Nil {
  let started =
    start_on_free_port(fn(port) {
      runtime.start(port: port, bind: "127.0.0.1", poller: False, probe: None)
    })
  assert recover(started, same_port: True)
}

@external(erlang, "runtime_test_ffi", "occupied_port")
fn occupied_port(start: fn(Int) -> result) -> Bool

pub fn occupied_port_fails_startup_test() -> Nil {
  assert occupied_port(fn(port) {
    runtime.start(port: port, bind: "127.0.0.1", poller: False, probe: None)
  })
}

@external(erlang, "runtime_test_ffi", "application_runs_the_poller_profile")
fn application_runs_the_poller_profile() -> Bool

// The application `gleam test` starts is the production tree: its root runs
// the poller's httpc profile as child id 1, under the name `send` uses.
pub fn application_runs_the_poller_profile_as_child_one_test() -> Nil {
  assert application_runs_the_poller_profile()
}
