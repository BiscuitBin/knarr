//// The adapters over real loopback sockets: the status and control
//// listeners, every failure mode as knarr's poller would see it, and SIGTERM
//// as the signal handler delivers it, with the kill record reaching a real
//// collector. Stopping the VM is injected, so the test observes it.

import fake_worker/config.{type Config, Config}
import fake_worker/kill_record.{KillRecord}
import fake_worker/server
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub type HttpError {
  Refused
  TimedOut
  Other(String)
}

@external(erlang, "fake_worker_test_ffi", "get")
fn http_get(url: String, timeout: Int) -> Result(#(Int, String), HttpError)

@external(erlang, "fake_worker_test_ffi", "put")
fn http_put(
  url: String,
  body: String,
  timeout: Int,
) -> Result(#(Int, String), HttpError)

@external(erlang, "fake_worker_test_ffi", "start_on_free_port")
fn start_on_free_port(
  start: fn(Int) -> Result(server.Running, error),
) -> #(Int, server.Running)

@external(erlang, "fake_worker_test_ffi", "stop_tree")
fn stop_tree(running: process.Pid) -> Nil

@external(erlang, "fake_worker_test_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "fake_worker_test_ffi", "kill_registered")
fn kill_registered(prefix: String) -> Nil

@external(erlang, "fake_worker_test_ffi", "crash_once")
fn crash_once(key: String) -> Nil

const path = "/knarr/v1/status"

fn worker_config() -> Config {
  Config(
    mode: config.Worker,
    bind: "127.0.0.1",
    status_port: 0,
    status_path: path,
    control_port: 0,
    drain_ms: 5000,
    sink_url: None,
    pod: "worker-1",
  )
}

/// Effects that record what the server asks for instead of stopping the VM.
fn effects(stops: Subject(Nil), logs: Subject(String)) -> server.Effects {
  server.Effects(
    ..server.production(),
    stop_vm: fn() { process.send(stops, Nil) },
    log: fn(line) { process.send(logs, line) },
  )
}

fn quiet() -> server.Effects {
  effects(process.new_subject(), process.new_subject())
}

fn status_url(running: server.Running) -> String {
  "http://127.0.0.1:" <> int.to_string(server.status_port(running)) <> path
}

fn control_url(running: server.Running) -> String {
  "http://127.0.0.1:" <> int.to_string(server.control_port(running))
}

fn control(running: server.Running, body: String) -> #(Int, String) {
  http_put(control_url(running) <> "/control", body, 2000) |> should.be_ok
}

// A control write the test expects to succeed.
fn set(running: server.Running, body: String) -> Nil {
  assert control(running, body).0 == 200
}

fn status(running: server.Running) -> Result(#(Int, String), HttpError) {
  http_get(status_url(running), 2000)
}

// StatusEndpoint.Pull and StatusEndpoint.ValidReading over the wire: one
// plain-HTTP GET, and control changes what it reads.
pub fn status_and_control_round_trip_test() -> Nil {
  let running = server.start_worker(worker_config(), quiet()) |> should.be_ok
  assert status(running) == Ok(#(200, "{\"cost\":0,\"accepting\":true}"))
  let #(code, state) = control(running, "{\"cost\":1800,\"accepting\":false}")
  assert code == 200
  assert string.contains(state, "\"cost\":1800,\"accepting\":false")
  assert status(running) == Ok(#(200, "{\"cost\":1800,\"accepting\":false}"))
  assert http_get(control_url(running) <> "/control", 2000) == Ok(#(200, state))
  assert http_get(control_url(running) <> "/healthz", 2000)
    == Ok(#(200, "ok\n"))
  assert control(running, "{\"cost\":-1}").0 == 400
  stop_tree(server.root(running))
}

// StatusEndpoint.Unauthenticated: reads over the wire change nothing.
pub fn status_reads_change_nothing_test() -> Nil {
  let running = server.start_worker(worker_config(), quiet()) |> should.be_ok
  let #(_, state) = control(running, "{\"cost\":5}")
  assert status(running) == Ok(#(200, "{\"cost\":5,\"accepting\":true}"))
  assert status(running) == Ok(#(200, "{\"cost\":5,\"accepting\":true}"))
  assert http_get(status_url(running) <> "?x=1", 2000)
    == Ok(#(200, "{\"cost\":5,\"accepting\":true}"))
  assert http_get(control_url(running) <> "/control", 2000) == Ok(#(200, state))
  stop_tree(server.root(running))
}

// StatusEndpoint.NotFoundReading, InvalidReading and Transport: each failure
// mode as the poller's transport sees it.
pub fn failure_modes_over_the_wire_test() -> Nil {
  let running = server.start_worker(worker_config(), quiet()) |> should.be_ok
  set(running, "{\"failure\":\"not_found\"}")
  assert status(running) == Ok(#(404, "not found\n"))
  set(running, "{\"failure\":\"server_error\"}")
  assert status(running) == Ok(#(500, "server error\n"))
  set(running, "{\"failure\":\"invalid\",\"invalid_body\":\"[]\"}")
  assert status(running) == Ok(#(200, "[]"))
  set(running, "{\"failure\":\"timeout\"}")
  assert http_get(status_url(running), 300) == Error(TimedOut)
  set(running, "{\"failure\":\"none\",\"latency_ms\":300}")
  let before = now_ms()
  assert status(running) == Ok(#(200, "{\"cost\":0,\"accepting\":true}"))
  assert now_ms() - before >= 300
  stop_tree(server.root(running))
}

// StatusEndpoint.Transport: refused closes the status listener while control
// stays up, and leaving it rebinds the same fixed port after it has served.
pub fn refused_closes_and_reopens_the_same_port_test() -> Nil {
  let #(port, running) =
    start_on_free_port(fn(port) {
      server.start_worker(Config(..worker_config(), status_port: port), quiet())
    })
  assert server.status_port(running) == port
  assert status(running) == Ok(#(200, "{\"cost\":0,\"accepting\":true}"))
  assert status(running) == Ok(#(200, "{\"cost\":0,\"accepting\":true}"))
  assert control(running, "{\"failure\":\"refused\"}").0 == 200
  assert status(running) == Error(Refused)
  assert control(running, "{\"cost\":3}").0 == 200
  assert status(running) == Error(Refused)
  assert control(running, "{\"failure\":\"none\"}").0 == 200
  assert server.status_port(running) == port
  assert status(running) == Ok(#(200, "{\"cost\":3,\"accepting\":true}"))
  stop_tree(server.root(running))
}

// With port 0 the OS picks the status port once; leaving refused rebinds it.
pub fn refused_keeps_an_os_chosen_port_test() -> Nil {
  let running = server.start_worker(worker_config(), quiet()) |> should.be_ok
  let port = server.status_port(running)
  set(running, "{\"failure\":\"refused\"}")
  assert status(running) == Error(Refused)
  set(running, "{\"failure\":\"none\"}")
  assert server.status_port(running) == port
  assert status(running) == Ok(#(200, "{\"cost\":0,\"accepting\":true}"))
  stop_tree(server.root(running))
}

// The sink is the last child, so its crash restarts nothing before it: a
// drain in progress survives.
pub fn a_sink_crash_keeps_the_drain_test() -> Nil {
  let stops = process.new_subject()
  let running =
    server.start_worker(worker_config(), effects(stops, process.new_subject()))
    |> should.be_ok
  set(running, "{\"cost\":1800}")
  let sigterm = running.sigterm |> should.be_some
  sigterm()
  kill_registered("fake_worker_sink$")
  assert status(running) == Ok(#(200, "{\"cost\":1800,\"accepting\":false}"))
  set(running, "{\"cost\":0}")
  assert process.receive(stops, 1000) == Ok(Nil)
  stop_tree(server.root(running))
}

// A sink that crashes during its first attempt loses no record: the state
// owns the pending record and sends it again.
pub fn a_sink_crash_mid_delivery_loses_no_record_test() -> Nil {
  let stops = process.new_subject()
  let bodies = process.new_subject()
  let deliver = fn(_url, body, _timeout) {
    crash_once("a_sink_crash_mid_delivery_loses_no_record_test")
    process.send(bodies, body)
    Ok(Nil)
  }
  let running =
    server.start_worker(
      Config(..worker_config(), sink_url: Some("http://collector.invalid")),
      server.Effects(..effects(stops, process.new_subject()), deliver: deliver),
    )
    |> should.be_ok
  set(running, "{\"cost\":1800}")
  let sigterm = running.sigterm |> should.be_some
  sigterm()
  let record =
    KillRecord(pod: "worker-1", busy: True, cost: 1800, accepting: True)
  assert process.receive(bodies, 5000) == Ok(kill_record.encode(record))
  set(running, "{\"cost\":0}")
  assert process.receive(stops, 1000) == Ok(Nil)
  stop_tree(server.root(running))
}

// StatusEndpoint.Served: after SIGTERM the endpoint still answers, with
// accepting false; the kill record reaches the collector, and the VM stops
// only once the work is done and the record delivered.
pub fn sigterm_delivers_the_record_and_drains_test() -> Nil {
  let collector =
    server.start_collector(
      Config(..worker_config(), mode: config.Collector),
      fn(_) { Nil },
    )
    |> should.be_ok
  let stops = process.new_subject()
  let logs = process.new_subject()
  let running =
    server.start_worker(
      Config(..worker_config(), sink_url: Some(control_url(collector))),
      effects(stops, logs),
    )
    |> should.be_ok
  set(running, "{\"cost\":1800}")
  let sigterm = running.sigterm |> should.be_some
  sigterm()
  assert status(running) == Ok(#(200, "{\"cost\":1800,\"accepting\":false}"))
  let record =
    KillRecord(pod: "worker-1", busy: True, cost: 1800, accepting: True)
  assert next_kill_line(logs) == Ok(kill_record.trace_line(record))
  let kills = "{\"kills\":[" <> kill_record.encode(record) <> "]}"
  assert await(fn() {
    http_get(control_url(collector) <> "/kills", 1000) == Ok(#(200, kills))
  })
  assert process.receive(stops, 300) == Error(Nil)
  sigterm()
  set(running, "{\"cost\":0}")
  assert process.receive(stops, 1000) == Ok(Nil)
  assert process.receive(stops, 300) == Error(Nil)
  stop_tree(server.root(running))
  stop_tree(server.root(collector))
}

// The drain ends at the deadline whatever the work, and with no sink an idle
// worker stops at once.
pub fn sigterm_stops_at_the_deadline_test() -> Nil {
  let stops = process.new_subject()
  let busy =
    server.start_worker(
      Config(..worker_config(), drain_ms: 300),
      effects(stops, process.new_subject()),
    )
    |> should.be_ok
  set(busy, "{\"cost\":10}")
  let before = now_ms()
  let sigterm = busy.sigterm |> should.be_some
  sigterm()
  assert process.receive(stops, 2000) == Ok(Nil)
  assert now_ms() - before >= 300
  stop_tree(server.root(busy))

  let idle =
    server.start_worker(worker_config(), effects(stops, process.new_subject()))
    |> should.be_ok
  let sigterm = idle.sigterm |> should.be_some
  sigterm()
  assert process.receive(stops, 500) == Ok(Nil)
  stop_tree(server.root(idle))
}

// The listeners log their ports first; skip to the kill record's line.
fn next_kill_line(logs: Subject(String)) -> Result(String, Nil) {
  case process.receive(logs, 1000) {
    Ok(line) ->
      case string.starts_with(line, "fake_worker kill ") {
        True -> Ok(line)
        False -> next_kill_line(logs)
      }
    Error(Nil) -> Error(Nil)
  }
}

fn await(check: fn() -> Bool) -> Bool {
  await_loop(check, 50)
}

fn await_loop(check: fn() -> Bool, attempts: Int) -> Bool {
  case check(), attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(20)
      await_loop(check, attempts - 1)
    }
  }
}
