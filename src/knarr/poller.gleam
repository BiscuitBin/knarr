//// The status poller: the StatusEndpoint contract in
//// docs/specs/worker_contract.allium. `request` builds the one GET of a
//// worker's status endpoint, `decode` reads what came back as a `Reading`,
//// and `draining` is the one place the drain state is read. All three are
//// pure; `decode` parses JSON through `poller_ffi`, which does no I/O. `poll`
//// joins them, and its only I/O is the `send` it is given: production passes
//// `poller_http.send`, a test passes a closure.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/string

/// The contract's default path: config.status_path.
pub const status_path = "/knarr/v1/status"

/// The contract's default port: config.status_port.
pub const status_port = 8080

/// The longest body a valid reading may have: config.max_body_bytes.
pub const max_body_bytes = 4096

/// Where one pod is polled: its pod IP, of either family, and the port and
/// path its Deployment's overrides give, else `status_port` and
/// `status_path`.
pub type Endpoint {
  Endpoint(pod_ip: String, port: Int, path: String)
}

/// The v1 payload: the worker's cost to kill it now, and whether it takes
/// new work.
pub type Status {
  Status(cost: Int, accepting: Bool)
}

/// Why a poll produced no response.
pub type Transport {
  /// Nothing accepted the connection, because nothing listens on the port.
  Refused
  /// No response within the per-poll timeout.
  TimedOut
  /// Every other transport failure, a reset connection among them.
  Unreachable
}

/// What one send produced: the response, or the transport failure.
pub type Outcome =
  Result(Response(BitArray), Transport)

/// What one poll meant. reconcile consumes a reading and nothing else.
pub type Reading {
  Valid(Status)
  /// A 404 at the contract path.
  NotFound
  /// Every other response.
  Invalid
  Failed(Transport)
}

/// The GET of `endpoint` over plain HTTP, carrying `User-Agent:
/// knarr/<version>` and no other header. An IPv6 pod IP is bracketed, since
/// `uri.to_string` writes the host as given.
pub fn request(
  endpoint endpoint: Endpoint,
  version version: String,
) -> Request(String) {
  let host = case string.contains(endpoint.pod_ip, ":") {
    True -> "[" <> endpoint.pod_ip <> "]"
    False -> endpoint.pod_ip
  }
  request.new()
  |> request.set_method(http.Get)
  |> request.set_scheme(http.Http)
  |> request.set_host(host)
  |> request.set_port(endpoint.port)
  |> request.set_path(endpoint.path)
  |> request.set_header("user-agent", "knarr/" <> version)
}

/// Reads an outcome as ValidReading, NotFoundReading, InvalidReading and
/// Transport say. A 200 body is parsed as JSON whatever its Content-Type,
/// and only once it is within `max_body_bytes`.
pub fn decode(outcome: Outcome) -> Reading {
  case outcome {
    Error(transport) -> Failed(transport)
    Ok(response.Response(status: 404, ..)) -> NotFound
    Ok(response.Response(status: 200, body:, ..)) ->
      case bit_array.byte_size(body) <= max_body_bytes {
        True -> decode_status(body)
        False -> Invalid
      }
    Ok(_) -> Invalid
  }
}

// `parse_json` keeps a number with a fraction or an exponent as its text, so
// `decode.int`, which accepts an integer term only, rejects a cost so
// written, and an ignored member never fails the parse.
fn decode_status(body: BitArray) -> Reading {
  case parse_json(body) {
    Ok(term) ->
      case decode.run(term, status_decoder()) {
        Ok(Status(cost:, ..) as status) if cost >= 0 -> Valid(status)
        _ -> Invalid
      }
    Error(Nil) -> Invalid
  }
}

@external(erlang, "poller_ffi", "parse_json")
fn parse_json(body: BitArray) -> Result(Dynamic, Nil)

fn status_decoder() -> decode.Decoder(Status) {
  use cost <- decode.field("cost", decode.int)
  use accepting <- decode.field("accepting", decode.bool)
  decode.success(Status(cost:, accepting:))
}

/// True for exactly a valid reading whose `accepting` is false: the worker
/// started a drain itself.
pub fn draining(reading: Reading) -> Bool {
  case reading {
    Valid(Status(accepting: False, ..)) -> True
    Valid(_) | NotFound | Invalid | Failed(_) -> False
  }
}

/// Polls `endpoint` once. The only I/O is the call to `send`.
pub fn poll(
  endpoint endpoint: Endpoint,
  version version: String,
  send send: fn(Request(String)) -> Outcome,
) -> Reading {
  request(endpoint:, version:)
  |> send
  |> decode
}
