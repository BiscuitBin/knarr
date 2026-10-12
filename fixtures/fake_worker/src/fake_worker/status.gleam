//// The status endpoint, the worker side of `StatusEndpoint` in
//// docs/specs/worker_contract.allium. It reads the state and never changes
//// it (Unauthenticated); the server sleeps for the answer's delay, then sends
//// its response.

import fake_worker/worker.{type State}
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json

/// A response and how long to wait before sending it.
pub type Answer {
  Answer(delay_ms: Int, response: Response(String))
}

/// How long the timeout mode holds a request: past any per-poll timeout knarr
/// could use, so the poll is timed_out.
pub const hold_ms = 120_000

pub fn respond(
  request request: Request(body),
  path path: String,
  state state: State,
) -> Answer {
  case request.path == path, request.method {
    False, _ -> Answer(0, text(404, "not found\n"))
    True, Get -> answer(state)
    True, _ ->
      Answer(
        0,
        text(405, "method not allowed\n") |> response.set_header("allow", "GET"),
      )
  }
}

// The v1 payload, and nothing else (Payload, ValidReading).
fn body(cost: Int, accepting: Bool) -> String {
  json.object([#("cost", json.int(cost)), #("accepting", json.bool(accepting))])
  |> json.to_string
}

fn answer(state: State) -> Answer {
  case state.failure {
    worker.NoFailure ->
      Answer(
        state.latency_ms,
        json_response(body(state.cost, worker.accepting(state))),
      )
    worker.Invalid ->
      Answer(state.latency_ms, json_response(state.invalid_body))
    worker.NotFound -> Answer(state.latency_ms, text(404, "not found\n"))
    worker.ServerError -> Answer(state.latency_ms, text(500, "server error\n"))
    worker.Timeout -> Answer(hold_ms, text(503, "held\n"))
    // The listener is closed in this mode; only a request accepted just
    // before it closed can get here.
    worker.Refused -> Answer(0, text(503, "refused\n"))
  }
}

fn json_response(body: String) -> Response(String) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(body)
}

fn text(status: Int, body: String) -> Response(String) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(body)
}
