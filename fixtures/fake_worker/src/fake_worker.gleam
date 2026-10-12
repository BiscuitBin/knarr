//// The fake worker (ticket 29): a configurable worker that serves knarr's
//// status contract, for tests on kind. `main` reads the environment, starts
//// the tree for the mode, takes over SIGTERM in worker mode so it drains
//// instead of stopping at once, and waits on the tree.

import fake_worker/config.{type ConfigError}
import fake_worker/server
import gleam/erlang/process.{type Pid}
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result

/// Why the worker did not start. Each stops the VM with status 1.
type StartFailure {
  BadConfig(ConfigError)
  NotStarted(actor.StartError)
  NoSigterm(SignalError)
}

type SignalError {
  SignalError(reason: String)
}

pub fn main() -> Nil {
  case start() {
    Ok(running) -> await_shutdown(server.root(running))
    Error(failure) -> {
      io.println_error("fake_worker: " <> describe(failure))
      halt(1)
    }
  }
}

fn start() -> Result(server.Running, StartFailure) {
  use config <- result.try(
    config.parse(getenv, hostname: hostname()) |> result.map_error(BadConfig),
  )
  use running <- result.try(
    case config.mode {
      config.Worker -> server.start_worker(config, server.production())
      config.Collector -> server.start_collector(config, io.println)
    }
    |> result.map_error(NotStarted),
  )
  use Nil <- result.try(handle_sigterm(running) |> result.map_error(NoSigterm))
  io.println("fake_worker started pod=" <> config.pod)
  Ok(running)
}

// Only main installs the handler, never server.start_worker, so a test VM
// that starts a worker keeps OTP's own SIGTERM handling.
fn handle_sigterm(running: server.Running) -> Result(Nil, SignalError) {
  case running.sigterm {
    Some(notify) -> install_sigterm(notify)
    None -> Ok(Nil)
  }
}

fn describe(failure: StartFailure) -> String {
  case failure {
    BadConfig(error) -> config.describe(error)
    NotStarted(actor.InitTimeout) -> "could not start: timed out"
    NotStarted(actor.InitFailed(reason)) -> "could not start: " <> reason
    NotStarted(actor.InitExited(reason)) ->
      "could not start: " <> format(reason)
    NoSigterm(SignalError(reason)) -> "could not take over SIGTERM: " <> reason
  }
}

@external(erlang, "fake_worker_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "fake_worker_ffi", "hostname")
fn hostname() -> String

@external(erlang, "fake_worker_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "fake_worker_ffi", "install_sigterm")
fn install_sigterm(notify: fn() -> Nil) -> Result(Nil, SignalError)

@external(erlang, "fake_worker_ffi", "await_shutdown")
fn await_shutdown(root: Pid) -> Nil

// The exit reason, as Erlang prints it, for the one line a failed start logs.
@external(erlang, "fake_worker_ffi", "format")
fn format(term: process.ExitReason) -> String
