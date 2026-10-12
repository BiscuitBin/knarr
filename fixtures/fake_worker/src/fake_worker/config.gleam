//// Configuration from the environment. Every variable is optional; the
//// defaults are the contract's (worker_contract.allium, `config`). A bad value
//// is an error naming the variable, and the worker does not start.

import gleam/bool
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Mode {
  /// Serve the status and control endpoints.
  Worker
  /// Keep the kill records workers send.
  Collector
}

pub type Config {
  Config(
    mode: Mode,
    bind: String,
    status_port: Int,
    status_path: String,
    control_port: Int,
    drain_ms: Int,
    sink_url: Option(String),
    pod: String,
  )
}

/// A variable whose value the worker cannot use.
pub type ConfigError {
  ConfigError(variable: String, wanted: String, got: String)
}

pub fn describe(error: ConfigError) -> String {
  error.variable
  <> " must be "
  <> error.wanted
  <> ", not \""
  <> error.got
  <> "\""
}

/// `lookup` reads one environment variable; `hostname` names the pod when
/// POD_NAME is unset, as a pod's hostname does by default.
pub fn parse(
  lookup: fn(String) -> Result(String, Nil),
  hostname hostname: String,
) -> Result(Config, ConfigError) {
  let read = fn(name) {
    case lookup(name) {
      Ok("") | Error(Nil) -> None
      Ok(value) -> Some(value)
    }
  }
  use mode <- result.try(mode(read("FAKE_WORKER_MODE")))
  use status_port <- result.try(port("FAKE_WORKER_STATUS_PORT", read, 8080))
  use status_path <- result.try(path(read("FAKE_WORKER_STATUS_PATH")))
  use control_port <- result.try(port("FAKE_WORKER_CONTROL_PORT", read, 8081))
  use drain_seconds <- result.try(drain(read("FAKE_WORKER_DRAIN_SECONDS")))
  use sink_url <- result.try(sink(read("FAKE_WORKER_SINK_URL")))
  use Nil <- result.try(distinct_ports(
    mode:,
    status: status_port,
    control: control_port,
  ))
  use Nil <- result.try(drain_for_sink(sink_url, drain_seconds))
  Ok(Config(
    mode:,
    bind: option.unwrap(read("FAKE_WORKER_BIND"), "0.0.0.0"),
    status_port:,
    status_path:,
    control_port:,
    drain_ms: drain_seconds * 1000,
    sink_url:,
    pod: option.unwrap(read("POD_NAME"), hostname),
  ))
}

fn mode(value: Option(String)) -> Result(Mode, ConfigError) {
  case value {
    None | Some("worker") -> Ok(Worker)
    Some("collector") -> Ok(Collector)
    Some(other) ->
      Error(ConfigError("FAKE_WORKER_MODE", "worker or collector", other))
  }
}

// Port 0 lets the OS choose, which only tests want.
fn port(
  name: String,
  read: fn(String) -> Option(String),
  default: Int,
) -> Result(Int, ConfigError) {
  case read(name) {
    None -> Ok(default)
    Some(value) ->
      case int.parse(value) {
        Ok(number) if number >= 0 && number <= 65_535 -> Ok(number)
        _ -> Error(ConfigError(name, "an integer from 0 to 65535", value))
      }
  }
}

// The rule worker_contract.allium's Discovery gives an override path.
fn path(value: Option(String)) -> Result(String, ConfigError) {
  case value {
    None -> Ok("/knarr/v1/status")
    Some(path) ->
      case
        string.starts_with(path, "/")
        && !string.contains(path, "?")
        && !string.contains(path, "#")
      {
        True -> Ok(path)
        False ->
          Error(ConfigError(
            "FAKE_WORKER_STATUS_PATH",
            "an absolute path with no query or fragment",
            path,
          ))
      }
  }
}

fn drain(value: Option(String)) -> Result(Int, ConfigError) {
  case value {
    None -> Ok(10)
    Some(text) ->
      case int.parse(text) {
        Ok(seconds) if seconds >= 0 -> Ok(seconds)
        _ ->
          Error(ConfigError(
            "FAKE_WORKER_DRAIN_SECONDS",
            "a whole number of seconds",
            text,
          ))
      }
  }
}

// The collector's base URL, over plain HTTP like the status contract. The
// worker appends /kills/<pod>, so it names a host and nothing after it.
fn sink(value: Option(String)) -> Result(Option(String), ConfigError) {
  case value {
    None -> Ok(None)
    Some(url) -> {
      let base = trim_slashes(url)
      case uri.parse(base) {
        Ok(uri.Uri(
          scheme: Some("http"),
          host: Some(host),
          path: "",
          query: None,
          fragment: None,
          ..,
        ))
          if host != ""
        -> Ok(Some(base))
        _ ->
          Error(ConfigError(
            "FAKE_WORKER_SINK_URL",
            "an http:// URL naming a host and no path",
            url,
          ))
      }
    }
  }
}

// Two listeners cannot share a port; port 0 lets the OS give each its own, and
// a collector serves no status endpoint.
fn distinct_ports(
  mode mode: Mode,
  status status: Int,
  control control: Int,
) -> Result(Nil, ConfigError) {
  case mode, status == control && status != 0 {
    Worker, True ->
      Error(ConfigError(
        "FAKE_WORKER_CONTROL_PORT",
        "a port other than FAKE_WORKER_STATUS_PORT",
        int.to_string(control),
      ))
    _, _ -> Ok(Nil)
  }
}

// The kill record needs time to reach the collector before the VM stops.
fn drain_for_sink(
  sink: Option(String),
  seconds: Int,
) -> Result(Nil, ConfigError) {
  case sink, seconds {
    Some(_), 0 ->
      Error(ConfigError(
        "FAKE_WORKER_DRAIN_SECONDS",
        "at least 1 when FAKE_WORKER_SINK_URL is set",
        "0",
      ))
    _, _ -> Ok(Nil)
  }
}

fn trim_slashes(url: String) -> String {
  use <- bool.guard(!string.ends_with(url, "/"), url)
  trim_slashes(string.drop_end(url, 1))
}
