//// The status endpoint against the worker side of `StatusEndpoint` in
//// docs/specs/worker_contract.allium. Each test names the clause it traces.

import fake_worker/status
import fake_worker/worker
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string

const path = "/knarr/v1/status"

fn get(target: String) -> request.Request(String) {
  request.new() |> request.set_path(target)
}

fn with(patch: worker.Patch) -> worker.State {
  worker.apply(worker.new(), patch)
}

fn set_cost(cost: Int, accepting: Bool) -> worker.Patch {
  worker.Patch(
    ..worker.no_change(),
    cost: Some(cost),
    accepting: Some(accepting),
  )
}

fn set_failure(failure: worker.Failure) -> worker.Patch {
  worker.Patch(..worker.no_change(), failure: Some(failure))
}

// The decoder half of ValidReading, as knarr's poller (ticket 43) will apply
// it: a JSON object with an integer cost that is not negative and a boolean
// accepting. Other members are ignored.
fn valid_reading(answer: status.Answer) -> Result(#(Int, Bool), Nil) {
  let reading = {
    use cost <- decode.field("cost", decode.int)
    use accepting <- decode.field("accepting", decode.bool)
    decode.success(#(cost, accepting))
  }
  case answer.response.status, string.byte_size(answer.response.body) <= 4096 {
    200, True ->
      case json.parse(answer.response.body, reading) {
        Ok(#(cost, accepting)) if cost >= 0 -> Ok(#(cost, accepting))
        _ -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

// StatusEndpoint.ValidReading and StatusEndpoint.Payload: the default state
// is an idle worker taking work, encoded exactly.
pub fn valid_reading_for_a_new_worker_test() -> Nil {
  let answer = status.respond(get(path), path, worker.new())
  assert answer.delay_ms == 0
  assert answer.response.status == 200
  assert answer.response.body == "{\"cost\":0,\"accepting\":true}"
  assert response.get_header(answer.response, "content-type")
    == Ok("application/json")
  assert valid_reading(answer) == Ok(#(0, True))
}

// StatusEndpoint.Payload: cost and accepting are what control set, and the
// payload carries nothing else.
pub fn payload_reflects_control_test() -> Nil {
  list.each([#(0, True), #(1800, True), #(500, False), #(0, False)], fn(pair) {
    let #(cost, accepting) = pair
    let answer =
      status.respond(get(path), path, with(set_cost(cost, accepting)))
    assert valid_reading(answer) == Ok(#(cost, accepting))
    assert answer.response.body
      == json.to_string(
        json.object([
          #("cost", json.int(cost)),
          #("accepting", json.bool(accepting)),
        ]),
      )
  })
}

// StatusEndpoint.ValidReading: a cost is a JSON integer, never a float or an
// exponent, however large.
pub fn valid_reading_cost_is_a_plain_integer_test() -> Nil {
  let answer =
    status.respond(get(path), path, with(set_cost(123_456_789_012, True)))
  assert answer.response.body == "{\"cost\":123456789012,\"accepting\":true}"
}

// StatusEndpoint.Payload and StatusEndpoint.Served: once SIGTERM arrives the
// worker still answers, and reports accepting false whatever control set.
pub fn served_while_draining_reports_not_accepting_test() -> Nil {
  let #(state, _) =
    with(set_cost(1800, True))
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "p", sink: False)
  let answer = status.respond(get(path), path, state)
  assert valid_reading(answer) == Ok(#(1800, False))
}

// StatusEndpoint.Versioning and StatusEndpoint.Discovery: the worker serves
// the v1 contract at the configured path only, so another version is a 404.
pub fn versioning_other_paths_are_not_found_test() -> Nil {
  list.each(
    ["/knarr/v2/status", "/knarr/v1", "/", "/knarr/v1/status/"],
    fn(other) {
      assert status.respond(get(other), path, worker.new()).response.status
        == 404
    },
  )
}

// StatusEndpoint.Discovery: an override path is served instead of the default.
pub fn discovery_override_path_test() -> Nil {
  let custom = "/custom/status"
  assert status.respond(get(custom), custom, worker.new()).response.status
    == 200
  assert status.respond(get(path), custom, worker.new()).response.status == 404
}

// StatusEndpoint.Pull: one GET reads the status; other methods are refused.
pub fn pull_other_methods_are_not_allowed_test() -> Nil {
  list.each([http.Post, http.Put, http.Delete, http.Head], fn(method) {
    let answer =
      status.respond(
        get(path) |> request.set_method(method),
        path,
        worker.new(),
      )
    assert answer.response.status == 405
    assert response.get_header(answer.response, "allow") == Ok("GET")
  })
}

// StatusEndpoint.RequestHeaders and StatusEndpoint.Unauthenticated: the worker
// requires no Accept, no User-Agent and no credential.
pub fn request_headers_are_not_required_test() -> Nil {
  let bare = status.respond(get(path), path, worker.new())
  let dressed =
    get(path)
    |> request.set_header("user-agent", "knarr/0.1.0")
    |> request.set_header("accept", "text/html")
    |> request.set_header("authorization", "Bearer ignored")
    |> status.respond(path, worker.new())
  assert bare == dressed
  assert valid_reading(bare) == Ok(#(0, True))
}

// StatusEndpoint.NotFoundReading: the not_found failure mode answers 404.
pub fn not_found_reading_test() -> Nil {
  let answer =
    status.respond(get(path), path, with(set_failure(worker.NotFound)))
  assert answer.response.status == 404
}

// StatusEndpoint.InvalidReading: a 5xx is invalid.
pub fn invalid_reading_server_error_test() -> Nil {
  let answer =
    status.respond(get(path), path, with(set_failure(worker.ServerError)))
  assert answer.response.status == 500
  assert valid_reading(answer) == Error(Nil)
}

// StatusEndpoint.InvalidReading: the invalid mode answers 200 with a body the
// decoder refuses, by default a string cost.
pub fn invalid_reading_default_body_test() -> Nil {
  let answer =
    status.respond(get(path), path, with(set_failure(worker.Invalid)))
  assert answer.response.status == 200
  assert answer.response.body == "{\"cost\":\"high\",\"accepting\":true}"
  assert valid_reading(answer) == Error(Nil)
}

// StatusEndpoint.InvalidReading: control chooses the invalid body, so every
// case the clause lists can be served.
pub fn invalid_reading_chosen_bodies_test() -> Nil {
  list.each(
    [
      "not json",
      "[]",
      "{\"cost\":1}",
      "{\"cost\":null,\"accepting\":true}",
      "{\"cost\":1.5,\"accepting\":true}",
      "{\"cost\":1e3,\"accepting\":true}",
      "{\"cost\":-1,\"accepting\":true}",
      "{\"cost\":1,\"accepting\":\"true\"}",
      "{\"cost\":1,\"accepting\":true,\"pad\":\""
        <> string.repeat("x", 4096)
        <> "\"}",
    ],
    fn(body) {
      let state =
        with(
          worker.Patch(..set_failure(worker.Invalid), invalid_body: Some(body)),
        )
      let answer = status.respond(get(path), path, state)
      assert answer.response.body == body
      assert valid_reading(answer) == Error(Nil)
    },
  )
}

// StatusEndpoint.Transport and StatusEndpoint.Served: latency delays every
// answer, and the timeout mode holds the request past any poll timeout.
pub fn latency_and_timeout_delay_the_answer_test() -> Nil {
  let slow =
    with(worker.Patch(..worker.no_change(), latency_ms: Some(250)))
    |> status.respond(get(path), path, _)
  assert slow.delay_ms == 250
  assert valid_reading(slow) == Ok(#(0, True))
  let held = status.respond(get(path), path, with(set_failure(worker.Timeout)))
  assert held.delay_ms == status.hold_ms
  assert status.hold_ms >= 120_000
}

// StatusEndpoint.Unauthenticated: answering returns no new state, so a read
// cannot change one; server_test proves the same over the wire.
pub fn unauthenticated_reads_are_repeatable_test() -> Nil {
  let state = with(set_cost(7, True))
  assert status.respond(get(path), path, state)
    == status.respond(get(path), path, state)
}
