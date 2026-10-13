//// Tests for the StatusEndpoint contract's builder, decoder and predicate
//// (docs/specs/worker_contract.allium). They are pure, so each passes values
//// in and reads values out; `poll` goes through closure fakes. Each test
//// names the clause or plan obligation it traces to.

import birdie
import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import http_picture
import knarr/poller.{
  Endpoint, Failed, Invalid, NotFound, Refused, Status, TimedOut, Unreachable,
  Valid,
}

const version = "0.1.0"

const endpoint =
  Endpoint(
    pod_ip: "10.1.2.3",
    port: poller.status_port,
    path: poller.status_path,
  )

fn respond(status: Int, body: String) -> poller.Outcome {
  Ok(response.Response(status:, headers: [], body: bit_array.from_string(body)))
}

fn read(body: String) -> poller.Reading {
  poller.decode(respond(200, body))
}

fn url(request: request.Request(String)) -> String {
  uri.to_string(request.to_uri(request))
}

// A valid object of exactly `size` bytes: the members, then spaces, then `}`.
fn padded(size: Int) -> String {
  let members = "{\"cost\":1,\"accepting\":true"
  members <> string.repeat(" ", size - string.byte_size(members) - 1) <> "}"
}

// ------------------------------------------------------------------ Pull ---

// StatusEndpoint.Pull: one GET of http://<pod_ip>:<port><path>, plain HTTP.
pub fn request_gets_the_status_url_over_plain_http_test() -> Nil {
  let request = poller.request(endpoint:, version:)

  assert request.method == http.Get
  assert request.scheme == http.Http
  assert request.body == ""
  assert url(request) == "http://10.1.2.3:8080/knarr/v1/status"
}

// StatusEndpoint.Pull: an IPv6 pod_ip is bracketed in the URL.
pub fn request_brackets_an_ipv6_pod_ip_test() -> Nil {
  let request =
    poller.request(endpoint: Endpoint(..endpoint, pod_ip: "fd00::1"), version:)

  assert url(request) == "http://[fd00::1]:8080/knarr/v1/status"
}

// StatusEndpoint.Pull: send is the one effect. poll hands it exactly the
// built request and decodes what it returns.
pub fn poll_sends_the_built_request_and_decodes_the_outcome_test() -> Nil {
  let send = fn(sent) {
    assert sent == poller.request(endpoint:, version:)
    respond(200, "{\"cost\":7,\"accepting\":true}")
  }

  assert poller.poll(endpoint:, version:, send:)
    == Valid(Status(cost: 7, accepting: True))
}

// ------------------------------------------------------------ Versioning ---

// StatusEndpoint.Versioning: the default path is config.status_path.
pub fn request_uses_the_default_status_path_test() -> Nil {
  assert poller.request(endpoint:, version:).path == "/knarr/v1/status"
}

// StatusEndpoint.Versioning: an override path is used verbatim.
pub fn request_uses_an_override_path_verbatim_test() -> Nil {
  let request =
    poller.request(
      endpoint: Endpoint(..endpoint, port: 9000, path: "/internal/knarr"),
      version:,
    )

  assert request.path == "/internal/knarr"
  assert request.query == None
  assert url(request) == "http://10.1.2.3:9000/internal/knarr"
}

// StatusEndpoint.Versioning: a worker that does not serve the path answers
// 404, which is not_found.
pub fn poll_of_an_unserved_path_is_not_found_test() -> Nil {
  let send = fn(_) { respond(404, "") }

  assert poller.poll(
      endpoint: Endpoint(..endpoint, path: "/knarr/v2/status"),
      version:,
      send:,
    )
    == NotFound
}

// -------------------------------------------------------- RequestHeaders ---

// StatusEndpoint.RequestHeaders: User-Agent knarr/<version>, and no other
// header.
pub fn request_carries_only_the_user_agent_test() -> Nil {
  let request = poller.request(endpoint:, version:)

  assert request.get_header(request, "user-agent") == Ok("knarr/0.1.0")
  assert request.headers == [#("user-agent", "knarr/0.1.0")]
}

// --------------------------------------------------------- ValidReading ---

// StatusEndpoint.ValidReading: members other than cost and accepting are
// ignored.
pub fn decode_ignores_extra_members_test() -> Nil {
  assert read(
      "{\"cost\":12,\"accepting\":true,\"queue\":\"emails\",\"tasks\":[1,2]}",
    )
    == Valid(Status(cost: 12, accepting: True))
}

// StatusEndpoint.ValidReading: 0 is the floor and is valid.
pub fn decode_accepts_a_zero_cost_test() -> Nil {
  assert read("{\"cost\":0,\"accepting\":false}")
    == Valid(Status(cost: 0, accepting: False))
}

// StatusEndpoint.Payload: cost has no upper bound on the wire.
pub fn decode_accepts_a_big_integer_cost_test() -> Nil {
  assert read("{\"cost\":123456789012345678901234567890,\"accepting\":true}")
    == Valid(Status(
      cost: 123_456_789_012_345_678_901_234_567_890,
      accepting: True,
    ))
}

// StatusEndpoint.ValidReading: a body of exactly config.max_body_bytes is
// within the cap.
pub fn decode_accepts_a_body_of_exactly_the_cap_test() -> Nil {
  let body = padded(poller.max_body_bytes)

  assert string.byte_size(body) == 4096
  assert read(body) == Valid(Status(cost: 1, accepting: True))
}

// StatusEndpoint.ValidReading: the body is parsed as JSON whatever the
// Content-Type says, or when there is none.
pub fn decode_ignores_the_content_type_test() -> Nil {
  let body = bit_array.from_string("{\"cost\":3,\"accepting\":true}")
  let with = fn(headers) {
    poller.decode(Ok(response.Response(status: 200, headers:, body:)))
  }

  assert with([#("content-type", "text/plain")])
    == Valid(Status(cost: 3, accepting: True))
  assert with([]) == Valid(Status(cost: 3, accepting: True))
}

// ------------------------------------------------------ NotFoundReading ---

// StatusEndpoint.NotFoundReading: a 404 is not_found whatever its body
// carries, an HTML page or more than config.max_body_bytes among them.
pub fn decode_reads_every_404_as_not_found_test() -> Nil {
  assert poller.decode(respond(404, "")) == NotFound
  assert poller.decode(respond(
      404,
      "<html><body><h1>404 Not Found</h1></body></html>",
    ))
    == NotFound
  assert poller.decode(respond(404, string.repeat("x", 5000))) == NotFound
}

// ------------------------------------------------------- InvalidReading ---

// StatusEndpoint.InvalidReading: a status other than 200 or 404 is invalid,
// a 3xx included, even with a valid body.
pub fn decode_reads_other_statuses_as_invalid_test() -> Nil {
  let body = "{\"cost\":1,\"accepting\":true}"

  assert poller.decode(respond(302, body)) == Invalid
  assert poller.decode(respond(500, body)) == Invalid
}

// StatusEndpoint.InvalidReading: a 200 longer than config.max_body_bytes is
// invalid, however valid the JSON.
pub fn decode_reads_a_body_over_the_cap_as_invalid_test() -> Nil {
  let body = padded(poller.max_body_bytes + 1)

  assert string.byte_size(body) == 4097
  assert read(body) == Invalid
}

// StatusEndpoint.InvalidReading: the body must be a JSON object.
pub fn decode_reads_a_non_object_as_invalid_test() -> Nil {
  assert read("[{\"cost\":1,\"accepting\":true}]") == Invalid
  assert read("5") == Invalid
}

// StatusEndpoint.InvalidReading: a missing cost or accepting is invalid.
pub fn decode_reads_a_missing_member_as_invalid_test() -> Nil {
  assert read("{\"accepting\":true}") == Invalid
  assert read("{\"cost\":1}") == Invalid
}

// StatusEndpoint.InvalidReading: a null cost or accepting is invalid.
pub fn decode_reads_a_null_member_as_invalid_test() -> Nil {
  assert read("{\"cost\":null,\"accepting\":true}") == Invalid
  assert read("{\"cost\":1,\"accepting\":null}") == Invalid
}

// StatusEndpoint.InvalidReading: a string where a number or boolean is due
// is invalid.
pub fn decode_reads_a_string_member_as_invalid_test() -> Nil {
  assert read("{\"cost\":\"5\",\"accepting\":true}") == Invalid
  assert read("{\"cost\":5,\"accepting\":\"true\"}") == Invalid
}

// StatusEndpoint.InvalidReading: a cost with a fraction or an exponent is
// invalid, even when its value is whole.
pub fn decode_reads_a_fractional_or_exponent_cost_as_invalid_test() -> Nil {
  assert read("{\"cost\":1.5,\"accepting\":true}") == Invalid
  assert read("{\"cost\":1.0,\"accepting\":true}") == Invalid
  assert read("{\"cost\":1e2,\"accepting\":true}") == Invalid
}

// StatusEndpoint.InvalidReading: a negative cost is invalid.
pub fn decode_reads_a_negative_cost_as_invalid_test() -> Nil {
  assert read("{\"cost\":-1,\"accepting\":true}") == Invalid
}

// StatusEndpoint.InvalidReading: a body that is not JSON is invalid.
pub fn decode_reads_a_non_json_body_as_invalid_test() -> Nil {
  assert read("ok") == Invalid
  assert read("") == Invalid
}

// ------------------------------------------------------------- Transport ---

// StatusEndpoint.Transport: decode maps each failure to the reading of the
// same name.
pub fn decode_maps_each_transport_failure_to_its_reading_test() -> Nil {
  assert poller.decode(Error(Refused)) == Failed(Refused)
  assert poller.decode(Error(TimedOut)) == Failed(TimedOut)
  assert poller.decode(Error(Unreachable)) == Failed(Unreachable)
}

// StatusEndpoint.Transport: poll passes a failed send through decode.
pub fn poll_of_a_failed_send_is_the_failure_test() -> Nil {
  assert poller.poll(endpoint:, version:, send: fn(_) { Error(TimedOut) })
    == Failed(TimedOut)
}

// --------------------------------------------------------------- Payload ---

// StatusEndpoint.Payload: draining is true for a valid reading whose
// accepting is false.
pub fn draining_is_true_when_a_valid_reading_is_not_accepting_test() -> Nil {
  assert poller.draining(Valid(Status(cost: 40, accepting: False)))
}

// StatusEndpoint.Payload: draining is false for every other reading.
pub fn draining_is_false_for_every_other_reading_test() -> Nil {
  assert !poller.draining(Valid(Status(cost: 40, accepting: True)))
  assert !poller.draining(NotFound)
  assert !poller.draining(Invalid)
  assert !poller.draining(Failed(Refused))
  assert !poller.draining(Failed(TimedOut))
  assert !poller.draining(Failed(Unreachable))
}

// ----------------------------------------------------------- Obligations ---

// config-default.status_path
pub fn config_default_status_path_test() -> Nil {
  assert poller.status_path == "/knarr/v1/status"
}

// config-default.status_port
pub fn config_default_status_port_test() -> Nil {
  assert poller.status_port == 8080
}

// config-default.max_body_bytes
pub fn config_default_max_body_bytes_test() -> Nil {
  assert poller.max_body_bytes == 4096
}

// contract-signature.StatusEndpoint.endpoint: (pod_ip, port, path) -> Endpoint.
// entity-fields.Endpoint and value-equality.Endpoint.
pub fn endpoint_is_built_from_three_values_and_compares_by_value_test() -> Nil {
  let built = Endpoint(pod_ip: "10.1.2.3", port: 8080, path: "/knarr/v1/status")

  assert built.pod_ip == "10.1.2.3"
  assert built.port == 8080
  assert built.path == "/knarr/v1/status"
  assert built == endpoint
  assert built != Endpoint(..built, port: 8081)
}

// contract-signature.StatusEndpoint.request: (endpoint) -> Request, with the
// version the adapter supplies. value-equality.Request: equal endpoints give
// equal requests. entity-fields.Request: method, url and headers.
pub fn request_is_a_value_of_its_endpoint_test() -> Nil {
  let request = poller.request(endpoint:, version:)

  assert request
    == poller.request(
      endpoint: Endpoint(
        pod_ip: "10.1.2.3",
        port: 8080,
        path: poller.status_path,
      ),
      version:,
    )
  assert request
    != poller.request(
      endpoint: Endpoint(..endpoint, pod_ip: "10.1.2.4"),
      version:,
    )
  assert http.method_to_string(request.method) == "GET"
  assert url(request) == "http://10.1.2.3:8080/knarr/v1/status"
  assert request.headers == [#("user-agent", "knarr/0.1.0")]
}

// value-equality.Header and entity-fields.Header: a header is a name and a
// value, compared by value.
pub fn header_is_a_name_and_a_value_test() -> Nil {
  let header: #(String, String) = #("user-agent", "knarr/0.1.0")

  assert header.0 == "user-agent"
  assert header.1 == "knarr/0.1.0"
  assert header == #("user-agent", "knarr/0.1.0")
  assert header != #("user-agent", "knarr/0.2.0")
}

// value-equality.Response and entity-fields.Response: status, headers and
// body, compared by value.
pub fn response_is_a_status_headers_and_body_test() -> Nil {
  let built =
    response.Response(
      status: 200,
      headers: [#("content-type", "application/json")],
      body: <<"{}">>,
    )

  assert built.status == 200
  assert built.headers == [#("content-type", "application/json")]
  assert built.body == <<"{}">>
  assert built
    == response.Response(
      status: 200,
      headers: [#("content-type", "application/json")],
      body: <<"{}">>,
    )
  assert built != response.Response(..built, status: 404)
}

// contract-signature.StatusEndpoint.send: (request) -> Outcome, exercised
// through poll with a fake. value-equality.Outcome and entity-fields.Outcome:
// the kind is Ok (responded) or the Transport error, and only responded
// carries a response.
pub fn outcome_is_a_response_or_a_transport_failure_test() -> Nil {
  let send = fn(_) -> poller.Outcome { respond(200, "{}") }
  let outcome = send(poller.request(endpoint:, version:))
  let response_of = fn(outcome: poller.Outcome) { option.from_result(outcome) }

  assert outcome == respond(200, "{}")
  assert outcome != respond(500, "{}")
  assert outcome != Error(Refused)
  assert response_of(outcome)
    == Some(response.Response(status: 200, headers: [], body: <<"{}">>))
  assert response_of(Error(Refused)) == None
  assert response_of(Error(TimedOut)) == None
  assert response_of(Error(Unreachable)) == None
}

// value-equality.Status and entity-fields.Status: cost and accepting,
// compared by value.
pub fn status_is_a_cost_and_accepting_test() -> Nil {
  let status = Status(cost: 5, accepting: True)

  assert status.cost == 5
  assert status.accepting
  assert status == Status(cost: 5, accepting: True)
  assert status != Status(cost: 5, accepting: False)
}

// contract-signature.StatusEndpoint.decode: (outcome) -> Reading.
// value-equality.Reading and entity-fields.Reading: the kind is the
// constructor, and only Valid carries a status.
pub fn reading_is_a_kind_and_an_optional_status_test() -> Nil {
  let status = fn(reading) {
    case reading {
      Valid(status) -> Some(status)
      NotFound | Invalid | Failed(_) -> None
    }
  }

  let one = read("{\"cost\":1,\"accepting\":true}")

  assert one == Valid(Status(cost: 1, accepting: True))
  assert one != Valid(Status(cost: 2, accepting: True))
  assert poller.decode(Error(Refused)) != poller.decode(Error(TimedOut))
  assert status(one) == Some(Status(cost: 1, accepting: True))
  assert status(poller.decode(respond(404, ""))) == None
  assert status(poller.decode(Error(Unreachable))) == None
}

// contract-signature.StatusEndpoint.draining: (reading) -> Boolean. The
// Payload tests above discharge it.

// ------------------------------------------------------------- Snapshots ---

// The picture is taken inside the fake, so it is exactly the request poll
// handed to send. The named tests above are what prove it.
pub fn snapshot_status_request_test() -> Nil {
  let send = fn(request) {
    http_picture.request(request)
    |> birdie.snap(title: "status request sent by poll")
    respond(404, "")
  }

  assert poller.poll(endpoint:, version:, send:) == NotFound
}
