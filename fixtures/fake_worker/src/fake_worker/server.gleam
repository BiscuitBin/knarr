//// The adapters around the pure modules: the state, sink and collector
//// actors, the mist listeners, and their supervision. The effects a test
//// needs to observe (the clock, delivering a kill record, stopping the VM and
//// logging) are injected through `Effects`.
////
//// Worker mode is one rest_for_one tree, in this order: the state actor, the
//// status listener, the control listener and the sink actor. A restart of the
//// state resets it and restarts everything after it, so the status listener
//// is never closed for a `refused` mode the new state no longer has. The sink
//// comes last, so its crash restarts nothing else and a drain survives it.

import fake_worker/collector
import fake_worker/config.{type Config}
import fake_worker/control
import fake_worker/kill_record.{type KillRecord}
import fake_worker/status
import fake_worker/worker.{type Patch, type State}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import mist

pub type Effects {
  Effects(
    now_ms: fn() -> Int,
    /// PUT a body to a URL within a timeout in milliseconds.
    deliver: fn(String, String, Int) -> Result(Nil, DeliveryError),
    stop_vm: fn() -> Nil,
    log: fn(String) -> Nil,
  )
}

/// The real effects: the monotonic clock, httpc, init:stop() and stdout.
pub fn production() -> Effects {
  Effects(now_ms: now_ms, deliver: deliver, stop_vm: stop_vm, log: io.println)
}

/// Why a kill record did not reach the collector on one attempt.
pub type DeliveryError {
  DeliveryError(reason: String)
}

// Why the status listener could not be closed or reopened.
type ListenerError {
  ListenerError(reason: String)
}

/// A started tree. `sigterm` is what the SIGTERM handler calls in worker
/// mode; the collector has none and stops as OTP's default handler stops it.
pub type Running {
  Running(root: Pid, ports: Ports, sigterm: Option(fn() -> Nil))
}

/// The ports the listeners bound, which differ from the configured ones only
/// when those are 0.
pub type Ports

pub fn root(running: Running) -> Pid {
  running.root
}

pub fn status_port(running: Running) -> Int {
  get_port(running.ports, status_slot)
}

pub fn control_port(running: Running) -> Int {
  get_port(running.ports, control_slot)
}

type Message {
  Get(reply: Subject(State))
  Apply(patch: Patch, reply: Subject(Result(State, ListenerError)))
  Terminate
  Delivered
  AttemptFailed
  Tick
}

type SinkMessage {
  Deliver(url: String, record: KillRecord, deadline_ms: Int)
}

type CollectorMessage {
  Handle(request: Request(String), reply: Subject(Response(String)))
}

type Context {
  Context(
    config: Config,
    effects: Effects,
    state: Name(Message),
    sink: Name(SinkMessage),
    root: Name(Nil),
  )
}

// `pending` is the kill record and its collector URL while the drain owes the
// sink a delivery. The state owns it, so a sink that crashes mid-attempt loses
// nothing: the next attempt falls due again and is sent again.
type Worker {
  Worker(state: State, stopped: Bool, pending: Option(#(String, KillRecord)))
}

const status_slot = 1

const control_slot = 2

/// The status listener's child id in the worker tree: children are numbered
/// from 0 in the order they are added. server_test's refused tests fail if
/// it names another child.
const status_child = 1

/// How often a drain checks whether it is over.
const tick_ms = 100

/// The longest one delivery attempt may take, and the pause before the next
/// after a failed one. An attempt with no answer at all, because the sink
/// crashed, is due again after both.
const attempt_ms = 2000

const retry_ms = 250

/// The largest control or collector request body read.
const body_limit = 1_048_576

pub fn start_worker(
  config config: Config,
  effects effects: Effects,
) -> Result(Running, actor.StartError) {
  let context =
    Context(
      config:,
      effects:,
      state: process.new_name("fake_worker_state"),
      sink: process.new_name("fake_worker_sink"),
      root: process.new_name("fake_worker_root"),
    )
  let ports = new_ports()
  use started <- result.try(
    supervisor.new(supervisor.RestForOne)
    |> supervisor.add(supervision.worker(fn() { start_state(context) }))
    |> supervisor.add(listener(
      status_handler(context),
      config,
      config.status_port,
      ports,
      status_slot,
      "status",
      effects.log,
    ))
    |> supervisor.add(listener(
      control_handler(context),
      config,
      config.control_port,
      ports,
      control_slot,
      "control",
      effects.log,
    ))
    |> supervisor.add(supervision.worker(fn() { start_sink(context) }))
    |> supervisor.start,
  )
  case process.register(started.pid, context.root) {
    Ok(Nil) ->
      Ok(Running(
        root: started.pid,
        ports:,
        sigterm: Some(fn() {
          process.send(process.named_subject(context.state), Terminate)
        }),
      ))
    Error(Nil) -> Error(actor.InitFailed("the worker tree has no name"))
  }
}

pub fn start_collector(
  config: Config,
  log: fn(String) -> Nil,
) -> Result(Running, actor.StartError) {
  let name = process.new_name("fake_worker_collector")
  let ports = new_ports()
  supervisor.new(supervisor.RestForOne)
  |> supervisor.add(supervision.worker(fn() { start_records(name, log) }))
  |> supervisor.add(listener(
    collector_handler(name),
    config,
    config.control_port,
    ports,
    control_slot,
    "collector",
    log,
  ))
  |> supervisor.start
  |> result.map(fn(started) {
    Running(root: started.pid, ports:, sigterm: None)
  })
}

fn start_state(context: Context) -> actor.StartResult(Subject(Message)) {
  actor.new(Worker(state: worker.new(), stopped: False, pending: None))
  |> actor.named(context.state)
  |> actor.on_message(fn(current, message) {
    handle_state(context:, current:, message:)
  })
  |> actor.start
}

fn handle_state(
  context context: Context,
  current current: Worker,
  message message: Message,
) -> actor.Next(Worker, Message) {
  case message {
    Get(reply) -> {
      process.send(reply, current.state)
      actor.continue(current)
    }
    Apply(patch, reply) -> {
      let next = worker.apply(current.state, patch)
      case
        toggle_listener(context:, from: current.state.failure, to: next.failure)
      {
        Ok(Nil) -> {
          process.send(reply, Ok(next))
          actor.continue(Worker(..current, state: next))
        }
        Error(reason) -> {
          process.send(reply, Error(reason))
          actor.continue(current)
        }
      }
    }
    Terminate -> terminate(context, current)
    Delivered ->
      actor.continue(Worker(..current, state: worker.delivered(current.state)))
    AttemptFailed -> {
      let at_ms = context.effects.now_ms() + retry_ms
      actor.continue(
        Worker(..current, state: worker.retry_at(state: current.state, at_ms:)),
      )
    }
    Tick -> tick(context, current)
  }
}

fn terminate(context: Context, current: Worker) -> actor.Next(Worker, Message) {
  let now = context.effects.now_ms()
  let config = context.config
  case
    worker.terminate(
      current.state,
      now_ms: now,
      drain_ms: config.drain_ms,
      pod: config.pod,
      sink: option.is_some(config.sink_url),
    )
  {
    #(_, None) -> actor.continue(current)
    #(state, Some(record)) -> {
      context.effects.log(kill_record.trace_line(record))
      let pending =
        option.map(config.sink_url, fn(url) {
          #(url <> "/kills/" <> record.pod, record)
        })
      tick(context, Worker(..current, state:, pending:))
    }
  }
}

fn tick(context: Context, current: Worker) -> actor.Next(Worker, Message) {
  let now = context.effects.now_ms()
  let current = attempt(context:, current:, now:)
  let stop = worker.should_stop(current.state, now_ms: now)
  case current.stopped, stop {
    True, _ -> actor.continue(current)
    False, True -> {
      case current.state.drain {
        Some(worker.Drain(delivered: False, ..)) ->
          context.effects.log(
            "fake_worker kill record not delivered before the drain ended",
          )
        _ -> Nil
      }
      context.effects.stop_vm()
      actor.continue(Worker(..current, stopped: True))
    }
    False, False -> {
      process.send_after(process.named_subject(context.state), tick_ms, Tick)
      actor.continue(current)
    }
  }
}

// Hand the sink one delivery attempt when one is due. If the sink is between
// restarts, nothing is sent and the attempt falls due again.
fn attempt(
  context context: Context,
  current current: Worker,
  now now: Int,
) -> Worker {
  case current.pending, worker.attempt_due(state: current.state, now_ms: now) {
    Some(#(url, record)), True -> {
      let deadline = case current.state.drain {
        Some(drain) -> drain.deadline_ms
        None -> now
      }
      case process.named(context.sink) {
        Ok(_) ->
          process.send(
            process.named_subject(context.sink),
            Deliver(url, record, deadline),
          )
        Error(Nil) -> Nil
      }
      let at_ms = now + attempt_ms + retry_ms
      Worker(..current, state: worker.retry_at(state: current.state, at_ms:))
    }
    _, _ -> current
  }
}

// Entering refused closes the status listener; leaving it reopens it.
fn toggle_listener(
  context context: Context,
  from from: worker.Failure,
  to to: worker.Failure,
) -> Result(Nil, ListenerError) {
  case from == worker.Refused, to == worker.Refused {
    False, True -> set_status_listening(context, False)
    True, False -> set_status_listening(context, True)
    _, _ -> Ok(Nil)
  }
}

fn set_status_listening(
  context: Context,
  running: Bool,
) -> Result(Nil, ListenerError) {
  case process.named(context.root) {
    Ok(root) -> set_child_running(root, status_child, running)
    Error(Nil) -> Error(ListenerError("the worker tree is not registered"))
  }
}

fn start_sink(context: Context) -> actor.StartResult(Subject(SinkMessage)) {
  actor.new(Nil)
  |> actor.named(context.sink)
  |> actor.on_message(fn(_, message) {
    deliver_record(context, message)
    actor.continue(Nil)
  })
  |> actor.start
}

// One attempt, within what is left of the drain; the state decides on the
// next one.
fn deliver_record(context: Context, message: SinkMessage) -> Nil {
  let remaining = message.deadline_ms - context.effects.now_ms()
  case remaining > 0 {
    False -> Nil
    True ->
      case
        context.effects.deliver(
          message.url,
          kill_record.encode(message.record),
          int.min(attempt_ms, remaining),
        )
      {
        Ok(Nil) -> process.send(process.named_subject(context.state), Delivered)
        Error(DeliveryError(reason)) -> {
          context.effects.log(
            "fake_worker kill record delivery failed: " <> reason,
          )
          process.send(process.named_subject(context.state), AttemptFailed)
        }
      }
  }
}

fn start_records(
  name: Name(CollectorMessage),
  log: fn(String) -> Nil,
) -> actor.StartResult(Subject(CollectorMessage)) {
  actor.new(dict.new())
  |> actor.named(name)
  |> actor.on_message(fn(records, message) {
    let Handle(request, reply) = message
    let #(answer, next) = collector.respond(request, records)
    case request.method, answer.status {
      http.Put, 204 -> log("fake_worker collected " <> request.body)
      _, _ -> Nil
    }
    process.send(reply, answer)
    actor.continue(next)
  })
  |> actor.start
}

// The state is read when the request arrives; the answer's delay follows.
fn status_handler(
  context: Context,
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let state = process.named_subject(context.state)
  fn(request) {
    let answer =
      status.respond(
        request,
        context.config.status_path,
        process.call(state, 1000, Get),
      )
    process.sleep(answer.delay_ms)
    to_mist(answer.response)
  }
}

fn control_handler(
  context: Context,
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let state = process.named_subject(context.state)
  fn(request) {
    let reply = case read_text(request) {
      Error(reply) -> reply
      Ok(request) ->
        case control.route(request) {
          control.Reply(reply) -> reply
          control.Read -> control.state_response(process.call(state, 1000, Get))
          control.Update(patch) ->
            case process.call(state, 5000, Apply(patch, _)) {
              Ok(next) -> control.state_response(next)
              Error(ListenerError(reason)) ->
                text(
                  500,
                  "could not change the failure mode: " <> reason <> "\n",
                )
            }
        }
    }
    to_mist(reply)
  }
}

fn collector_handler(
  name: Name(CollectorMessage),
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let records = process.named_subject(name)
  fn(request) {
    case read_text(request) {
      Error(reply) -> reply
      Ok(request) -> process.call(records, 1000, Handle(request, _))
    }
    |> to_mist
  }
}

fn listener(
  handler: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
  config: Config,
  port: Int,
  ports: Ports,
  slot: Int,
  label: String,
  log: fn(String) -> Nil,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() {
    // Port 0 lets the OS choose once; a restart, as leaving `refused` does,
    // binds the port chosen then.
    let port = case port {
      0 -> get_port(ports, slot)
      _ -> port
    }
    mist.new(handler)
    |> mist.bind(config.bind)
    |> mist.port(port)
    |> mist.after_start(fn(bound, _, _) {
      set_port(ports, slot, bound)
      log(
        "fake_worker listening listener="
        <> label
        <> " port="
        <> int.to_string(bound),
      )
    })
    |> mist.start
  })
}

fn read_text(
  request: Request(mist.Connection),
) -> Result(Request(String), Response(String)) {
  case mist.read_body(request, body_limit) {
    Error(_) -> Error(text(413, "the body is too large or unreadable\n"))
    Ok(request) ->
      case bit_array.to_string(request.body) {
        Ok(body) -> Ok(request.set_body(request, body))
        Error(Nil) -> Error(text(400, "the body is not UTF-8\n"))
      }
  }
}

fn to_mist(reply: Response(String)) -> Response(mist.ResponseData) {
  response.set_body(reply, mist.Bytes(bytes_tree.from_string(reply.body)))
}

fn text(status: Int, body: String) -> Response(String) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(body)
}

@external(erlang, "fake_worker_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "fake_worker_ffi", "deliver")
fn deliver(
  url: String,
  body: String,
  timeout: Int,
) -> Result(Nil, DeliveryError)

@external(erlang, "fake_worker_ffi", "stop_vm")
fn stop_vm() -> Nil

@external(erlang, "fake_worker_ffi", "new_ports")
fn new_ports() -> Ports

@external(erlang, "fake_worker_ffi", "set_port")
fn set_port(ports: Ports, slot: Int, port: Int) -> Nil

@external(erlang, "fake_worker_ffi", "get_port")
fn get_port(ports: Ports, slot: Int) -> Int

@external(erlang, "fake_worker_ffi", "set_child_running")
fn set_child_running(
  supervisor: Pid,
  child: Int,
  running: Bool,
) -> Result(Nil, ListenerError)
