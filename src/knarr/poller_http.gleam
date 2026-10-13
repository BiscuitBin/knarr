//// The plain-HTTP adapter behind the StatusEndpoint contract: `send` has the
//// type `poller.poll`'s `send` argument expects, with the per-poll timeout
//// bound in. It carries each poll over httpc through knarr's own profile,
//// which `supervised` starts apart from the apiserver client's, so poll
//// connections never share its pool. The only Erlang here is
//// `poller_http_ffi`.

import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import gleam/uri
import knarr/poller.{type Outcome, type Transport}

/// Budget's `config.poll_timeout` default (budget `Timeout`), for when the
/// install sets none.
pub const default_timeout_ms = 5000

/// Sends `request`, a GET, over plain HTTP and returns what came back. A
/// redirect is never followed and a Retry-After never retried. No response
/// within `timeout_ms` of the call, the wait for the profile to take the
/// request and the connect included, is `TimedOut`. A send while no profile
/// is registered, as between a crash and its restart, is `Unreachable`. The
/// body is read whole; only `poller.decode` applies the contract's cap.
/// A poll that timed out before the profile took it may still be sent once
/// the profile resumes, and its answer is discarded. Another method is a
/// programming error and crashes the caller.
pub fn send(
  request request: Request(String),
  timeout_ms timeout_ms: Int,
) -> Outcome {
  let url = uri.to_string(request.to_uri(request))
  let ipv6 = string.starts_with(request.host, "[")
  case
    do_request(
      http.method_to_string(request.method),
      url,
      request.headers,
      ipv6,
      timeout_ms,
    )
  {
    Ok(#(status, headers, body)) ->
      Ok(response.Response(status:, headers:, body:))
    Error(transport) -> Error(transport)
  }
}

@external(erlang, "poller_http_ffi", "request")
fn do_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  ipv6: Bool,
  timeout_ms: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), Transport)

/// The poller's httpc profile, registered by name so `send` can find it,
/// under its own supervisor: three restarts a minute before the root sees
/// one failure, so a crashing profile cannot take the listener down with it
/// inside the root's two-in-five-seconds tolerance. A poll in flight when
/// the profile dies, or sent before it is back, is `Unreachable`.
pub fn supervised() -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  |> supervisor.add(supervision.worker(start_profile))
  |> supervisor.supervised
}

@external(erlang, "poller_http_ffi", "start_profile")
fn start_profile() -> Result(actor.Started(Nil), actor.StartError)

/// knarr's own version, the `vsn` Gleam writes into the `.app` from
/// `gleam.toml`, for the User-Agent header.
@external(erlang, "poller_http_ffi", "version")
pub fn version() -> String
