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
import gleam/otp/supervision
import gleam/string
import gleam/uri
import knarr/poller.{type Outcome, type Transport}

/// Budget's `config.poll_timeout` default (budget `Timeout`), for when the
/// install sets none.
pub const default_timeout_ms = 5000

/// Sends `request` over plain HTTP and returns what came back. A redirect is
/// never followed. No response within `timeout_ms` of the call, connect
/// included, is `TimedOut`, and the request is cancelled. The body is read
/// whole; only `poller.decode` applies the contract's cap. The profile must
/// be running: sending without it is a programming error and crashes the
/// caller.
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

/// The poller's httpc profile as a supervised worker, registered by name so
/// `send` can find it. It is linked to its supervisor, which restarts it
/// under the same name; a poll in flight when it dies gets no answer and
/// times out.
pub fn supervised() -> supervision.ChildSpecification(Nil) {
  supervision.worker(start_profile)
}

@external(erlang, "poller_http_ffi", "start_profile")
fn start_profile() -> Result(actor.Started(Nil), actor.StartError)

/// knarr's own version, the `vsn` Gleam writes into the `.app` from
/// `gleam.toml`, for the User-Agent header.
@external(erlang, "poller_http_ffi", "version")
pub fn version() -> String
