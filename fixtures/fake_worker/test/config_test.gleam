//// Configuration from the environment: the defaults are the contract's, and
//// a bad value stops the worker before it serves anything.

import fake_worker/config
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result

fn parse(
  pairs: List(#(String, String)),
) -> Result(config.Config, config.ConfigError) {
  let environment = dict.from_list(pairs)
  config.parse(dict.get(environment, _), hostname: "host-1")
}

// StatusEndpoint.Discovery: the defaults are config.status_port and
// config.status_path from worker_contract.allium.
pub fn defaults_test() -> Nil {
  assert parse([])
    == Ok(config.Config(
      mode: config.Worker,
      bind: "0.0.0.0",
      status_port: 8080,
      status_path: "/knarr/v1/status",
      control_port: 8081,
      drain_ms: 10_000,
      sink_url: None,
      pod: "host-1",
    ))
}

// StatusEndpoint.Discovery: the port and path a Deployment's overrides name.
pub fn overrides_test() -> Nil {
  assert parse([
      #("FAKE_WORKER_MODE", "collector"),
      #("FAKE_WORKER_BIND", "::"),
      #("FAKE_WORKER_STATUS_PORT", "9797"),
      #("FAKE_WORKER_STATUS_PATH", "/custom/v1/status"),
      #("FAKE_WORKER_CONTROL_PORT", "0"),
      #("FAKE_WORKER_DRAIN_SECONDS", "3"),
      #("FAKE_WORKER_SINK_URL", "http://collector:8081//"),
      #("POD_NAME", "worker-abc"),
    ])
    == Ok(config.Config(
      mode: config.Collector,
      bind: "::",
      status_port: 9797,
      status_path: "/custom/v1/status",
      control_port: 0,
      drain_ms: 3000,
      sink_url: Some("http://collector:8081"),
      pod: "worker-abc",
    ))
}

pub fn empty_values_mean_the_default_test() -> Nil {
  assert parse([#("FAKE_WORKER_SINK_URL", ""), #("POD_NAME", "")]) == parse([])
}

pub fn bad_values_are_refused_by_name_test() -> Nil {
  list.each(
    [
      #("FAKE_WORKER_MODE", "both"),
      #("FAKE_WORKER_STATUS_PORT", "65536"),
      #("FAKE_WORKER_STATUS_PORT", "-1"),
      #("FAKE_WORKER_CONTROL_PORT", "http"),
      #("FAKE_WORKER_STATUS_PATH", "knarr/v1/status"),
      #("FAKE_WORKER_STATUS_PATH", "/status?x=1"),
      #("FAKE_WORKER_STATUS_PATH", "/status#x"),
      #("FAKE_WORKER_DRAIN_SECONDS", "-1"),
      #("FAKE_WORKER_DRAIN_SECONDS", "1.5"),
      #("FAKE_WORKER_SINK_URL", "https://collector"),
    ],
    fn(pair) {
      let #(variable, value) = pair
      let refused = parse([pair])
      assert result.map_error(refused, fn(error) {
          #(error.variable, error.got)
        })
        == Error(#(variable, value))
    },
  )
}

pub fn describe_names_the_variable_and_the_value_test() -> Nil {
  assert config.describe(config.ConfigError("FAKE_WORKER_MODE", "worker", "x"))
    == "FAKE_WORKER_MODE must be worker, not \"x\""
}

pub fn the_control_port_must_differ_from_the_status_port_test() -> Nil {
  let same = [
    #("FAKE_WORKER_STATUS_PORT", "9000"),
    #("FAKE_WORKER_CONTROL_PORT", "9000"),
  ]
  assert result.map_error(parse(same), fn(error) { error.variable })
    == Error("FAKE_WORKER_CONTROL_PORT")
  // Port 0 lets the OS choose each, and a collector serves no status port.
  assert result.is_ok(
    parse([
      #("FAKE_WORKER_STATUS_PORT", "0"),
      #("FAKE_WORKER_CONTROL_PORT", "0"),
    ]),
  )
  assert result.is_ok(parse([#("FAKE_WORKER_MODE", "collector"), ..same]))
}

// A record needs time to reach the collector before the VM stops.
pub fn a_sink_needs_a_drain_test() -> Nil {
  let sink = #("FAKE_WORKER_SINK_URL", "http://collector:8081")
  let no_drain = #("FAKE_WORKER_DRAIN_SECONDS", "0")
  assert result.map_error(parse([sink, no_drain]), fn(error) { error.variable })
    == Error("FAKE_WORKER_DRAIN_SECONDS")
  assert result.is_ok(parse([no_drain]))
}

// The worker appends /kills/<pod> to the URL, so it names a host and no path.
pub fn the_sink_url_names_only_a_host_test() -> Nil {
  list.each(
    [
      "http://", "http://collector:8081/sink", "http://collector?x=1",
      "http://collector#x", "http://collector:http",
    ],
    fn(url) {
      assert result.map_error(
          parse([#("FAKE_WORKER_SINK_URL", url)]),
          fn(error) { error.variable },
        )
        == Error("FAKE_WORKER_SINK_URL")
    },
  )
  assert result.map(
      parse([#("FAKE_WORKER_SINK_URL", "http://c.ns:8081")]),
      fn(config) { config.sink_url },
    )
    == Ok(Some("http://c.ns:8081"))
}
