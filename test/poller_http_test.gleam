//// The plain-HTTP adapter against a gen_tcp loopback responder that stands
//// in for a worker's status endpoint, over 127.0.0.1 and ::1. The responder
//// answers by path (see `poller_http_test_ffi`); `closed_port` is a port
//// nothing listens on. Every send goes through the poller's httpc profile
//// that the knarr application `gleam test` starts already runs: the profile
//// is one per VM, so a test cannot start a second.

import gleam/erlang/process.{type Pid}
import gleam/http/response
import gleeunit/should
import knarr/poller.{Endpoint, Refused, TimedOut, Unreachable}
import knarr/poller_http

@external(erlang, "poller_http_test_ffi", "start_responder")
fn start_responder(family: String) -> #(Int, Pid)

@external(erlang, "poller_http_test_ffi", "stop_responder")
fn stop_responder(responder: #(Int, Pid)) -> Nil

@external(erlang, "poller_http_test_ffi", "closed_port")
fn closed_port() -> Int

@external(erlang, "poller_http_test_ffi", "restart_profile")
fn restart_profile() -> Bool

@external(erlang, "poller_http_test_ffi", "timed")
fn timed(body: fn() -> a) -> #(a, Int)

@external(erlang, "poller_http_test_ffi", "gleam_toml_version")
fn gleam_toml_version() -> String

const version = "0.1.0"

fn get(
  pod_ip pod_ip: String,
  port port: Int,
  path path: String,
) -> poller.Outcome {
  poller.request(endpoint: Endpoint(pod_ip:, port:, path:), version:)
  |> poller_http.send(timeout_ms: 2000)
}

fn served(
  family family: String,
  pod_ip pod_ip: String,
  path path: String,
) -> poller.Outcome {
  let responder = start_responder(family)
  let outcome = get(pod_ip:, port: responder.0, path:)
  stop_responder(responder)
  outcome
}

// StatusEndpoint.Transport: a response is responded with the response, over
// an IPv4 pod IP.
pub fn send_returns_the_response_over_ipv4_test() -> Nil {
  let response =
    served(family: "inet", pod_ip: "127.0.0.1", path: "/status") |> should.be_ok

  assert response.status == 200
  assert response.body == <<"{\"cost\":5,\"accepting\":true}">>
  assert response.get_header(response, "content-type") == Ok("application/json")
}

// StatusEndpoint.Pull and Transport: an IPv6 pod IP is bracketed and
// reached.
pub fn send_returns_the_response_over_ipv6_test() -> Nil {
  let response =
    served(family: "inet6", pod_ip: "::1", path: "/status") |> should.be_ok

  assert response.status == 200
  assert response.body == <<"{\"cost\":5,\"accepting\":true}">>
}

// StatusEndpoint.NotFoundReading: a 404 comes back as a response for decode
// to read.
pub fn send_returns_a_404_as_a_response_test() -> Nil {
  let response =
    served(family: "inet", pod_ip: "127.0.0.1", path: "/missing")
    |> should.be_ok

  assert response.status == 404
}

// StatusEndpoint.InvalidReading: a 3xx is never followed.
pub fn send_does_not_follow_a_redirect_test() -> Nil {
  let response =
    served(family: "inet", pod_ip: "127.0.0.1", path: "/redirect")
    |> should.be_ok

  assert response.status == 302
  assert response.get_header(response, "location") == Ok("/status")
}

// StatusEndpoint.Transport: refused when nothing listens on the port.
pub fn send_reports_a_closed_port_as_refused_test() -> Nil {
  let port = closed_port()

  assert get(pod_ip: "127.0.0.1", port:, path: "/status") == Error(Refused)
}

// StatusEndpoint.Transport: refused over IPv6 too.
pub fn send_reports_a_closed_ipv6_port_as_refused_test() -> Nil {
  let port = closed_port()

  assert get(pod_ip: "::1", port:, path: "/status") == Error(Refused)
}

// StatusEndpoint.Transport: timed_out when no response arrives within the
// per-poll timeout, and send returns once it has passed.
pub fn send_reports_a_silent_worker_as_timed_out_test() -> Nil {
  let responder = start_responder("inet")
  let #(outcome, elapsed) =
    timed(fn() {
      poller.request(
        endpoint: Endpoint(
          pod_ip: "127.0.0.1",
          port: responder.0,
          path: "/silent",
        ),
        version:,
      )
      |> poller_http.send(timeout_ms: 200)
    })
  stop_responder(responder)

  assert outcome == Error(TimedOut)
  assert elapsed >= 200
  assert elapsed < 1500
}

// StatusEndpoint.Transport: unreachable for every other failure, a reset
// connection among them.
pub fn send_reports_a_reset_as_unreachable_test() -> Nil {
  assert served(family: "inet", pod_ip: "127.0.0.1", path: "/reset")
    == Error(Unreachable)
}

// StatusEndpoint.RequestHeaders: exactly one User-Agent knarr/<version>
// reaches the worker; httpc adds none of its own.
pub fn send_carries_exactly_one_user_agent_test() -> Nil {
  let response =
    served(family: "inet", pod_ip: "127.0.0.1", path: "/user-agent")
    |> should.be_ok

  assert response.body == <<"knarr/0.1.0">>
}

// Budget Timeout: the per-poll timeout is 5 seconds unless the install sets
// another.
pub fn default_timeout_is_five_seconds_test() -> Nil {
  assert poller_http.default_timeout_ms == 5000
}

// StatusEndpoint.RequestHeaders: the version in User-Agent is knarr's own,
// the vsn Gleam writes into the .app from gleam.toml.
pub fn version_is_the_gleam_toml_version_test() -> Nil {
  assert poller_http.version() == gleam_toml_version()
}

// The poller's httpc profile runs under the application's root supervisor,
// registered by name, and comes back under the same name when it dies, so a
// later send goes through.
pub fn profile_is_restarted_under_its_name_test() -> Nil {
  let responder = start_responder("inet")
  assert restart_profile()
  let outcome = get(pod_ip: "127.0.0.1", port: responder.0, path: "/status")
  stop_responder(responder)

  let response = outcome |> should.be_ok
  assert response.status == 200
}
