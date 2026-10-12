//// The worker's state and every change to it, as values: what control sets,
//// what SIGTERM starts, and when the drain is over. The server's state actor
//// holds one `State` and applies these functions to it.

import fake_worker/kill_record.{type KillRecord, KillRecord}
import gleam/option.{type Option, None, Some}

/// How the status endpoint misbehaves, and the reading each produces in
/// knarr's poller (worker_contract.allium, `Reading`).
pub type Failure {
  /// Answer 200 with the status: a valid reading.
  NoFailure
  /// Hold the request without answering: timed_out.
  Timeout
  /// Answer 500: invalid.
  ServerError
  /// Answer 404: not_found.
  NotFound
  /// Answer 200 with `invalid_body`: invalid.
  Invalid
  /// Close the status listener, so a connection is refused: refused.
  Refused
}

/// A drain starts at SIGTERM. It ends at the deadline, or earlier once the
/// cost is 0 and the kill record has reached the sink. Until it has, an
/// attempt to deliver the record is due at `next_attempt_ms`.
pub type Drain {
  Drain(deadline_ms: Int, delivered: Bool, next_attempt_ms: Int)
}

pub type State {
  State(
    cost: Int,
    accepting: Bool,
    latency_ms: Int,
    failure: Failure,
    invalid_body: String,
    drain: Option(Drain),
  )
}

/// A control request: each field it names replaces the state's.
pub type Patch {
  Patch(
    cost: Option(Int),
    accepting: Option(Bool),
    latency_ms: Option(Int),
    failure: Option(Failure),
    invalid_body: Option(String),
  )
}

// A cost given as a string: what the `invalid` mode serves unless control
// chooses another body.
const default_invalid_body = "{\"cost\":\"high\",\"accepting\":true}"

/// An idle worker taking work.
pub fn new() -> State {
  State(
    cost: 0,
    accepting: True,
    latency_ms: 0,
    failure: NoFailure,
    invalid_body: default_invalid_body,
    drain: None,
  )
}

pub fn no_change() -> Patch {
  Patch(
    cost: None,
    accepting: None,
    latency_ms: None,
    failure: None,
    invalid_body: None,
  )
}

pub fn apply(state state: State, patch patch: Patch) -> State {
  State(
    cost: option.unwrap(patch.cost, state.cost),
    accepting: option.unwrap(patch.accepting, state.accepting),
    latency_ms: option.unwrap(patch.latency_ms, state.latency_ms),
    failure: option.unwrap(patch.failure, state.failure),
    invalid_body: option.unwrap(patch.invalid_body, state.invalid_body),
    drain: state.drain,
  )
}

/// What the status endpoint reports: false from SIGTERM on, whatever control
/// set (StatusEndpoint.Served).
pub fn accepting(state: State) -> Bool {
  state.accepting && state.drain == None
}

/// SIGTERM: start the drain and say what the worker was doing. A second
/// SIGTERM changes nothing and records nothing. With no sink the record
/// counts as delivered.
pub fn terminate(
  state state: State,
  now_ms now_ms: Int,
  drain_ms drain_ms: Int,
  pod pod: String,
  sink sink: Bool,
) -> #(State, Option(KillRecord)) {
  case state.drain {
    Some(_) -> #(state, None)
    None -> {
      let record =
        KillRecord(
          pod:,
          busy: state.cost > 0,
          cost: state.cost,
          accepting: accepting(state),
        )
      let drain =
        Drain(
          deadline_ms: now_ms + drain_ms,
          delivered: !sink,
          next_attempt_ms: now_ms,
        )
      #(State(..state, drain: Some(drain)), Some(record))
    }
  }
}

/// The sink has the kill record.
pub fn delivered(state: State) -> State {
  case state.drain {
    Some(drain) -> State(..state, drain: Some(Drain(..drain, delivered: True)))
    None -> state
  }
}

/// Whether to try to deliver the kill record now: draining, not yet
/// delivered, the next attempt due, and the deadline not passed.
pub fn attempt_due(state state: State, now_ms now_ms: Int) -> Bool {
  case state.drain {
    Some(drain) ->
      !drain.delivered
      && now_ms >= drain.next_attempt_ms
      && now_ms < drain.deadline_ms
    None -> False
  }
}

/// The next delivery attempt is due at `at_ms`.
pub fn retry_at(state state: State, at_ms at_ms: Int) -> State {
  case state.drain {
    Some(drain) ->
      State(..state, drain: Some(Drain(..drain, next_attempt_ms: at_ms)))
    None -> state
  }
}

pub fn should_stop(state state: State, now_ms now_ms: Int) -> Bool {
  case state.drain {
    None -> False
    Some(drain) ->
      now_ms >= drain.deadline_ms || { state.cost == 0 && drain.delivered }
  }
}

pub fn failure_name(failure: Failure) -> String {
  case failure {
    NoFailure -> "none"
    Timeout -> "timeout"
    ServerError -> "server_error"
    NotFound -> "not_found"
    Invalid -> "invalid"
    Refused -> "refused"
  }
}

pub fn parse_failure(name: String) -> Result(Failure, Nil) {
  case name {
    "none" -> Ok(NoFailure)
    "timeout" -> Ok(Timeout)
    "server_error" -> Ok(ServerError)
    "not_found" -> Ok(NotFound)
    "invalid" -> Ok(Invalid)
    "refused" -> Ok(Refused)
    _ -> Error(Nil)
  }
}
